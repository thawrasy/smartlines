#!/usr/bin/env bash
# Database CI: checks the model, confirms the generated DDL is current, deploys it to SQL Server,
# compares what was deployed with the DDL, and runs the trigger, tenant-isolation, account-security and
# operator-and-support tests.
#
# Environment:
#   SA_PASSWORD   password of the sa login (required)
#   SQL_SERVER    server name, default localhost,1433
#   SQLCMD        sqlcmd command, default sqlcmd
# Exit code 0 only when every step passes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
: "${SA_PASSWORD:?set SA_PASSWORD to the sa password}"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
export SQLCMDPASSWORD="$SA_PASSWORD"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sq() { "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b "$@"; }

echo "== 0. waiting for SQL Server at $SQL_SERVER"
for i in $(seq 1 60); do
    if sq -Q "SELECT 1" >/dev/null 2>&1; then
        echo "SQL Server answers"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "SQL Server did not answer after 180 seconds"
        exit 1
    fi
    sleep 3
done

echo "== 1. model check"
python3 tools/dbgen/dbgen.py check db/model/*.model

echo "== 2. generated DDL is current with the model"
python3 tools/dbgen/dbgen.py build db/model/*.model --out "$TMP/generated" --docs "$TMP/docs" >/dev/null
if ! diff -r "$TMP/generated" db/generated; then
    echo "db/generated is stale: run tools/dbgen/dbgen.py build and commit the result"
    exit 1
fi
echo "generated DDL matches the model"

echo "== 3. every foreign key is indexed or flagged noidx; static grant rules R1-R10"
python3 tools/dbgen/check_fk_indexes.py
python3 tools/dbgen/check_grants.py

echo "== 4. deploy db/deploy.sql to a fresh BankFas database"
sq -Q "IF DB_ID(N'BankFas') IS NOT NULL BEGIN ALTER DATABASE [BankFas] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [BankFas]; END" >/dev/null
# The same wrapper that users run: it changes to db/ and runs deploy.sql unchanged.
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/deploy.sh

echo "== 4b. the platform seed can run again without changing anything (DOC-B05 section 6)"
seed_state() { sq -d BankFas -h -1 -W -Q "SET NOCOUNT ON; SELECT CONCAT(COUNT(*), '/', COUNT(UpdatedAt), '/', CONVERT(VARCHAR(30), MAX(CreatedAt), 126)) FROM cfg.SettingDefinition"; }
seed_before="$(seed_state)"
sq -d BankFas -i db/seed/100_platform_global.sql >/dev/null
seed_after="$(seed_state)"
if [ "$seed_before" != "$seed_after" ] || [ "${seed_before%%/*}" -lt 6 ]; then
    echo "platform seed is not safe to run again, or incomplete: before $seed_before, after $seed_after"
    exit 1
fi
echo "platform seed unchanged on a second run ($seed_after)"

echo "== 5. deployed objects against the generated DDL"
python3 tools/dbgen/check_deployed.py --sqlcmd "$SQLCMD" --server "$SQL_SERVER" --database BankFas

echo "== 6. trigger tests (db/tests/fac_share_rule_tests.sql)"
sq -i db/tests/fac_share_rule_tests.sql > "$TMP/tests.out" 2>&1 || {
    cat "$TMP/tests.out"
    echo "test run failed"
    exit 1
}
cat "$TMP/tests.out"
if grep -q '^FAIL' "$TMP/tests.out"; then
    echo "a trigger test failed"
    exit 1
fi
passed=$(grep -c '^PASS' "$TMP/tests.out" || true)
if [ "$passed" -ne 6 ]; then
    echo "expected 6 PASS lines, found $passed"
    exit 1
fi
echo "== 7. tenant-isolation tests (db/tests/tenant_isolation_tests.sql)"
sq -i db/tests/tenant_isolation_tests.sql > "$TMP/isolation.out" 2>&1 || {
    cat "$TMP/isolation.out"
    echo "isolation test run failed"
    exit 1
}
cat "$TMP/isolation.out"
if grep -q '^FAIL' "$TMP/isolation.out"; then
    echo "a tenant-isolation test failed"
    exit 1
fi
iso_pass=$(grep -c '^PASS' "$TMP/isolation.out" || true)
# 48 cases: T1-T38 and T40-T46 (there is no T39), with T8b, T16b and T16c (T32-T37 cover login and sessions, O-17; T38 the platform audit read;
# T40-T46 the tenant-status access, mandatory MFA and the O-19/O-24 closures). A case that stops printing PASS fails the build.
if [ "$iso_pass" -ne 48 ]; then
    echo "expected 48 PASS, found $iso_pass"
    exit 1
fi
echo "tenant-isolation tests: $iso_pass passed"
echo "== 8. account-security flow tests (db/tests/auth_flow_tests.sql)"
sq -i db/tests/auth_flow_tests.sql > "$TMP/auth.out" 2>&1 || {
    cat "$TMP/auth.out"
    echo "account-security test run failed"
    exit 1
}
cat "$TMP/auth.out"
if grep -q '^FAIL' "$TMP/auth.out"; then
    echo "an account-security test failed"
    exit 1
fi
auth_pass=$(grep -c '^PASS' "$TMP/auth.out" || true)
# 20 cases: A1-A14 (ADR 0003: invitation, MFA enrolment and checks, recovery codes, passwords, administrator actions,
# sessions) and S1-S6 (tenant security settings within the platform bounds, DQ-S03-6, DQ-S04-14).
if [ "$auth_pass" -ne 20 ]; then
    echo "expected 20 PASS, found $auth_pass"
    exit 1
fi
echo "account-security tests: $auth_pass passed"
echo "== 9. operator and support tests (db/tests/operator_support_tests.sql)"
sq -i db/tests/operator_support_tests.sql > "$TMP/operator.out" 2>&1 || {
    cat "$TMP/operator.out"
    echo "operator and support test run failed"
    exit 1
}
cat "$TMP/operator.out"
if grep -q '^FAIL' "$TMP/operator.out"; then
    echo "an operator or support test failed"
    exit 1
fi
op_pass=$(grep -c '^PASS' "$TMP/operator.out" || true)
# 10 cases: P1-P10 (ADR 0004: operator bootstrap, login, MFA, lockout, reset, status, direct rights; the support binding).
if [ "$op_pass" -ne 10 ]; then
    echo "expected 10 PASS, found $op_pass"
    exit 1
fi
echo "operator and support tests: $op_pass passed"
echo "all database checks passed"

#!/usr/bin/env bash
# Database CI: checks the model, confirms the generated DDL is current, deploys it to SQL Server,
# compares what was deployed with the DDL, and runs the trigger tests.
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

echo "== 3. every foreign key is indexed or flagged noidx"
python3 tools/dbgen/check_fk_indexes.py

echo "== 4. deploy db/deploy.sql to a fresh BankFas database"
sq -Q "IF DB_ID(N'BankFas') IS NOT NULL BEGIN ALTER DATABASE [BankFas] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [BankFas]; END" >/dev/null
# The same wrapper that users run: it changes to db/ and runs deploy.sql unchanged.
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/deploy.sh

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
# 40 cases: T1-T37 with T8b, T16b and T16c (T32-T37 cover login and sessions, O-17). A case that stops printing PASS fails the build.
if [ "$iso_pass" -ne 40 ]; then
    echo "expected 40 PASS, found $iso_pass"
    exit 1
fi
echo "tenant-isolation tests: $iso_pass passed"
echo "all database checks passed"

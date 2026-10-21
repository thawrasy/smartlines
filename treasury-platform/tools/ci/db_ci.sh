#!/usr/bin/env bash
# Database CI: checks the model, confirms the generated DDL is current, deploys it to SQL Server,
# compares what was deployed with the DDL, and runs the trigger, tenant-isolation, account-security,
# operator-and-support, job-binding, tenant-onboarding, document-numbering (one of them with concurrent connections),
# KYC history, reference data, audit trail and data export tests, the service logins of the deployment, and the SQL
# Server Audit of the server with its AL-18 alerts, and the monitoring login that runs the post-deployment check.
#
# Environment:
#   SA_PASSWORD   password of the sa login (required)
#   SQL_SERVER    server name, default localhost,1433; another host only with BANKFAS_CI_THROWAWAY_SERVER=1
#   SQLCMD        sqlcmd command, default sqlcmd
# Exit code 0 only when every step passes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
: "${SA_PASSWORD:?set SA_PASSWORD to the sa password}"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
export SQLCMDPASSWORD="$SA_PASSWORD"
# The tools in tools/deploy and check_deployed.py verify the server certificate by default (DQ-S05-7). The throwaway
# container of CI has a self-signed one, so CI alone trusts it, here and for every script it runs. The same tools
# refuse -C, and the administrator scripts refuse sa, unless these two allowances are set (DQ-S11-6, ADR 0014); only CI
# sets them.
export SQLCMD_OPTS=-C BANKFAS_ALLOW_TRUST_CERT=1 BANKFAS_ALLOW_SA=1
# CI drops and builds BankFas again, as sa: tools/ci/ci_guard.sh, which every script of tools/ci sources, lets it reach
# only a server on this machine, unless BANKFAS_CI_THROWAWAY_SERVER=1 says that another one is a throwaway server too
# (self-review E8), and never a BankFas that holds real tenants (internal review v6, D9, D10).
# shellcheck source=tools/ci/ci_guard.sh
. "$ROOT/tools/ci/ci_guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sq() { "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b "$@"; }
# A test prints one line per case: "PASS <id>: ..." or "FAIL <id>: ...". The lines are matched anywhere, not only at
# the start, and each case is counted once: an older sqlcmd can print a fragment of its input before a result line,
# and an anchored match would miss a FAIL printed that way (self-review C9).
FAIL_RE='FAIL [A-Za-z]+[0-9]+[a-z]?[: ]'
PASS_RE='PASS [A-Za-z]+[0-9]+[a-z]?:'

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
# The permission catalogue is generated from the readiness documents and the specs' role matrices (DQ-F07-1, DQ-F09-1).
python3 tools/dbgen/gen_permission_seed.py "$TMP/102_permissions.sql" >/dev/null
if ! diff -q "$TMP/102_permissions.sql" db/seed/102_permissions.sql >/dev/null; then
    echo "db/seed/102_permissions.sql is stale: run tools/dbgen/gen_permission_seed.py and commit the result"
    exit 1
fi
echo "permission seed matches the documents"
# The tenant pack CORE.ROLES and its procedure 057 are generated from the role matrices of the specs (ADR 0035).
python3 tools/dbgen/core_roles_pack.py --out "$TMP/roles" > "$TMP/roles.out"
if ! diff -r "$TMP/roles/db/seed/packs/CORE.ROLES" db/seed/packs/CORE.ROLES >/dev/null \
   || ! diff -q "$TMP/roles/db/static/057_core_roles.sql" db/static/057_core_roles.sql >/dev/null; then
    echo "the pack CORE.ROLES or db/static/057_core_roles.sql is stale: run tools/dbgen/core_roles_pack.py and commit the result"
    exit 1
fi
echo "the pack CORE.ROLES matches the role matrices ($(cat "$TMP/roles.out"))"
# The credit assessment methodology seed is generated from tools/dbgen/credit_scorecard.json (docs/35, ADR 0017).
# Its tables in docs/35 come from the same file (--doc-check changes nothing and fails on a difference).
python3 tools/dbgen/gen_credit_seed.py "$TMP/104_credit_scorecard.sql" --doc-check > "$TMP/credit_seed.out" || {
    tail -1 "$TMP/credit_seed.out"
    exit 1
}
if ! diff -q "$TMP/104_credit_scorecard.sql" db/seed/104_credit_scorecard.sql >/dev/null; then
    echo "db/seed/104_credit_scorecard.sql is stale: run tools/dbgen/gen_credit_seed.py and commit the result"
    exit 1
fi
echo "credit methodology seed and the tables of docs/35 match tools/dbgen/credit_scorecard.json"
# The cases that check the T-SQL engine against the Python reference are generated from the same file (ADR 0018).
python3 tools/dbgen/gen_credit_cases.py "$TMP/credit_engine_cases.sql" >/dev/null
if ! diff -q "$TMP/credit_engine_cases.sql" db/tests/credit_engine_cases.sql >/dev/null; then
    echo "db/tests/credit_engine_cases.sql is stale: run tools/dbgen/gen_credit_cases.py and commit the result"
    exit 1
fi
echo "credit engine cases match tools/dbgen/credit_scorecard.json and tools/dbgen/credit_reference.py"

echo "== 3. every foreign key is indexed or flagged noidx; static grant and cascade rules R1-R11"
python3 tools/dbgen/check_fk_indexes.py
python3 tools/dbgen/check_grants.py
python3 tools/dbgen/check_review_fixes.py | tail -1   # the design-review fixes in the generated DDL (C-12, O-15)
python3 tools/dbgen/ntf_pack.py   # the tenant pack NTF.BASE: columns, placeholders, templates and rules (ADR 0028)
# The stress cases of the independent credit review fall within the reviewer's grade ranges (docs/35 section 13).
python3 tools/dbgen/credit_stress.py > "$TMP/stress.out" || {
    cat "$TMP/stress.out"
    echo "a stress case of the credit review falls outside the reviewer's range: see docs/35 section 13"
    exit 1
}
tail -1 "$TMP/stress.out"
# No deployment tool trusts any certificate by itself; only CI passes -C (DQ-S05-7, ADR 0013).
# A default of -C, or -C written into a command, in the shell, Python and PowerShell tools. A missing file would make
# grep end with code 2 and the check pass unseen, so the files are required first (self-review C8). Other spellings of
# a weaker connection are refused at run time by the options allowlist (tools/deploy/preflight.sh, PF7).
for f in tools/deploy/preflight.sh tools/deploy/deploy.sh tools/deploy/deploy.ps1 tools/dbgen/check_deployed.py; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
done
if grep -n 'SQLCMD_OPTS--C' tools/deploy/*.sh \
   || grep -nE "'-C',|, '-C'[])]|SQLCMD_OPTS', '[^']*-C" tools/dbgen/check_deployed.py tools/deploy/deploy.ps1; then
    echo "a deployment tool passes -C by default"
    exit 1
fi
echo "no deployment tool trusts the server certificate by default"
# The SQL files the deployment and the tools read use no sqlcmd command but :r, :setvar and :on error: no !! (a shell
# command), :ED, :OUT, :CONNECT or :SERVERLIST. sqlcmd -X would refuse them, but it also stops sqlcmd from reading
# SQLCMDPASSWORD, so they are refused here (self-review E11).
if grep -rnE '^[[:space:]]*(!!|:!!|:[Ee][Dd]([[:space:]]|$)|:[Oo][Uu][Tt]|:[Cc][Oo][Nn][Nn][Ee][Cc][Tt]|:[Ss][Ee][Rr][Vv][Ee][Rr][Ll][Ii][Ss][Tt]|:[Pp][Ee][Rr][Ff][Tt][Rr][Aa][Cc][Ee]|:[Ee][Rr][Rr][Oo][Rr])' \
       db --include='*.sql'; then
    echo "a SQL file uses a sqlcmd command that runs a shell, an editor or another connection"
    exit 1
fi
echo "the SQL files use no shell, editor or connection command of sqlcmd"
# CI runs the SQL Server image of the release register (DQ-B01-2, FR-PLT-045); the deployment preflight compares the
# server's build with the same register (gate G4).
python3 - <<'PY'
import json, re, sys
db_host = json.load(open('versions.json', encoding='utf-8'))['database_host']
want = f"{db_host['ci_image']}@{db_host['ci_image_digest']}"
flow = open('../.github/workflows/treasury-db-ci.yml', encoding='utf-8').read()
got = re.findall(r'^\s*image:\s*(mcr\.microsoft\.com/mssql/\S+)', flow, re.M)
if got != [want]:
    sys.exit(f'the CI image {got} is not the one of versions.json ({want})')
print(f'CI runs the SQL Server image of the release register: {want}')
PY

echo "== 4. deploy db/deploy.sql to a fresh BankFas database the way production does (DOC-S11, ADR 0010, ADR 0012)"
audit_since="$(sq -h -1 -W -Q "SET NOCOUNT ON; SELECT CONVERT(VARCHAR(19), SYSUTCDATETIME(), 126);")"
sq -Q "$(ci_guard_drop_sql)
IF DB_ID(N'BankFas') IS NOT NULL BEGIN ALTER DATABASE [BankFas] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [BankFas]; END" >/dev/null
# The administrator (sa here) starts the server audit first, so everything after it is recorded, then prepares the
# empty database and the deployment login and opens the window; the deployment runs as bankfas_migrator, a member of
# db_owner and of no server role, through the same wrapper users run; the administrator adds the database audit
# specification inside the window, and the window closes. Each step declares itself in the audit (change CI).
# In production the audit folder is a volume made by DOC-S10 section 3; the CI container has none, so it is made here.
sq -Q "EXEC master.sys.xp_create_subdir N'/var/opt/mssql/audit';" >/dev/null
export BANKFAS_CHANGE_REF=CI
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/server_audit.sh apply
mkdir -m 700 "$TMP/migrator"
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" BANKFAS_SECRETS_DIR="$TMP/migrator" bash tools/deploy/prepare_database.sh prepare --generate
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/prepare_database.sh open
SQL_SERVER="$SQL_SERVER" SQL_USER=bankfas_migrator SQLCMDPASSWORD="$(cat "$TMP/migrator/bankfas_migrator.secret")" SQLCMD="$SQLCMD" \
    bash tools/deploy/deploy.sh
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/server_audit.sh apply
mkdir -m 700 "$TMP/monitor"
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" BANKFAS_SECRETS_DIR="$TMP/monitor" bash tools/deploy/provision_monitor.sh --generate
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/prepare_database.sh close
unset BANKFAS_CHANGE_REF
deploy_state="$(sq -d BankFas -h -1 -W -Q "SET NOCOUNT ON; SELECT CONCAT(
    (SELECT SUSER_SNAME(owner_sid) FROM sys.databases WHERE name = N'BankFas'), '/',
    (SELECT is_disabled FROM sys.server_principals WHERE name = N'bankfas_owner'), '/',
    (SELECT is_disabled FROM sys.server_principals WHERE name = N'bankfas_migrator'), '/',
    (SELECT COUNT(*) FROM sys.server_role_members AS m JOIN sys.server_principals AS p ON p.principal_id = m.member_principal_id WHERE p.name = N'bankfas_migrator'), '/',
    IS_ROLEMEMBER(N'db_owner', N'bankfas_migrator'), '/',
    (SELECT COUNT(*) FROM sys.schemas AS s WHERE s.schema_id BETWEEN 5 AND 16383 AND s.principal_id <> 1), '/',
    (SELECT COUNT(*) FROM sys.objects WHERE principal_id IS NOT NULL), '/',
    (SELECT COUNT(*) FROM sys.database_principals WHERE type = 'R' AND name LIKE N'tp[_]%' AND owning_principal_id <> 1), '/',
    CAST(DATABASEPROPERTYEX(N'BankFas', 'Collation') AS NVARCHAR(128)));")"
expected_state="bankfas_owner/1/1/0/1/0/0/0/Arabic_100_CI_AS_SC"
if [ "$deploy_state" != "$expected_state" ]; then
    echo "deployment as bankfas_migrator: owner/owner disabled/migrator disabled/server roles/db_owner/schemas not dbo/objects not dbo/roles not dbo/collation = $deploy_state (expected $expected_state)"
    exit 1
fi
if SQLCMDPASSWORD="$(cat "$TMP/migrator/bankfas_migrator.secret")" "$SQLCMD" -S "$SQL_SERVER" -U bankfas_migrator -C -Q "SELECT 1" >/dev/null 2>&1; then
    echo "the deployment login still connects after the window closed"
    exit 1
fi
echo "deployed as bankfas_migrator (db_owner only); the owner login and the deployment login are disabled, everything is owned by dbo ($deploy_state)"

echo "== 4b. the platform seed is complete and can run again without changing anything (DOC-B05 section 6)"
# The query is read from a file: an older sqlcmd garbles a -Q text of this length.
cat > "$TMP/seed_state.sql" <<'SQL'
SET NOCOUNT ON;
SELECT CONCAT((SELECT COUNT(*) FROM cfg.SettingDefinition), '/', (SELECT COUNT(*) FROM cfg.JobDefinition), '/', (SELECT COUNT(*) FROM plat.[Plan]), '/', (SELECT COUNT(*) FROM plat.PlanModule), '/', (SELECT COUNT(*) FROM plat.ReservedSubdomain), '/', (SELECT COUNT(*) FROM ref.Country), '/', (SELECT COUNT(*) FROM ref.Currency), '/', (SELECT COUNT(*) FROM sec.Permission), '/', (SELECT COUNT(*) FROM ref.Incoterm), '/', (SELECT COUNT(*) FROM ref.UcpArticle WHERE TenantId IS NULL AND VerificationStatus = 'UNVERIFIED'), '/', (SELECT COUNT(*) FROM fin.RatingGrade), '/', (SELECT COUNT(*) FROM fin.CreditMetric), '/', (SELECT COUNT(*) FROM fin.Scorecard WHERE Status = 'APPROVED'), '/', (SELECT COUNT(*) FROM fin.ScorecardMetric) + (SELECT COUNT(*) FROM fin.ScorecardItemRule) + (SELECT COUNT(*) FROM fin.ScorecardAdjustment), '/', (SELECT COUNT(UpdatedAt) FROM cfg.SettingDefinition) + (SELECT COUNT(UpdatedAt) FROM cfg.JobDefinition) + (SELECT COUNT(UpdatedAt) FROM plat.[Plan]) + (SELECT COUNT(UpdatedAt) FROM ref.Incoterm) + (SELECT COUNT(UpdatedAt) FROM ref.UcpArticle) + (SELECT COUNT(UpdatedAt) FROM fin.Scorecard) + (SELECT COUNT(UpdatedAt) FROM fin.ScorecardMetric));
SQL
seed_state() { sq -d BankFas -h -1 -W -i "$TMP/seed_state.sql"; }
seed_before="$(seed_state)"
sq -d BankFas -i db/seed/100_platform_global.sql >/dev/null
sq -d BankFas -i db/seed/101_iso_reference.sql >/dev/null
sq -d BankFas -i db/seed/102_permissions.sql >/dev/null
sq -d BankFas -i db/seed/103_lc_reference.sql >/dev/null
sq -d BankFas -i db/seed/104_credit_scorecard.sql >/dev/null
seed_after="$(seed_state)"
if [ "$seed_before" != "$seed_after" ] || [ "$seed_before" != "11/34/1/9/23/249/157/144/16/39/21/112/16/3130/0" ]; then
    echo "platform seed is not safe to run again, or incomplete: settings/jobs/plans/plan modules/reserved/countries/currencies/permissions/Incoterms/unverified UCP articles/grades/credit metrics/approved scorecards/scorecard rows/updated before $seed_before, after $seed_after (expected 11/34/1/9/23/249/157/144/16/39/21/112/16/3130/0)"
    exit 1
fi
echo "platform seed unchanged on a second run ($seed_after)"
# The Arabic text of the seeds arrives as written: the SHA-256 of the 249 Arabic country names in BankFas, in UTF-16
# as SQL Server stores them, equals that of the names in db/seed/101_iso_reference.sql (self-review D3). A file read
# in the wrong code page would store other characters.
want_ar="$(python3 -c 'import re, hashlib, sys
t = open(sys.argv[1], encoding="utf-8").read()
rows = sorted(re.findall(r"\(\x27([A-Z]{2})\x27, \x27[A-Z]{3}\x27, N\x27((?:[^\x27]|\x27\x27)*)\x27", t))
assert len(rows) == 249, len(rows)
print(hashlib.sha256("|".join(n.replace("\x27\x27", "\x27") for _, n in rows).encode("utf-16-le")).hexdigest().upper())' db/seed/101_iso_reference.sql)"
got_ar="$(sq -d BankFas -h -1 -W -Q "SET NOCOUNT ON; SELECT CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', STRING_AGG(CAST(NameAr AS NVARCHAR(MAX)), N'|') WITHIN GROUP (ORDER BY Iso2)), 2) FROM ref.Country;" | grep -oE '[0-9A-F]{64}' | head -1)"
if [ "$want_ar" != "$got_ar" ]; then
    echo "the Arabic country names in BankFas differ from db/seed/101_iso_reference.sql (SHA-256 $got_ar, expected $want_ar)"
    exit 1
fi
echo "the Arabic seed text arrived as written (SHA-256 of the 249 country names)"

echo "== 5. the post-deployment check against the generated DDL and the static scripts, run by the monitoring login (DOC-S11 section 8.2)"
SQL_USER=bankfas_monitor SQLCMDPASSWORD="$(cat "$TMP/monitor/bankfas_monitor.secret")" \
    python3 tools/dbgen/check_deployed.py --sqlcmd "$SQLCMD" --server "$SQL_SERVER" --database BankFas

echo "== 6. trigger tests (db/tests/fac_share_rule_tests.sql)"
sq -i db/tests/fac_share_rule_tests.sql > "$TMP/tests.out" 2>&1 || {
    cat "$TMP/tests.out"
    echo "test run failed"
    exit 1
}
cat "$TMP/tests.out"
if grep -qaE "$FAIL_RE" "$TMP/tests.out"; then
    echo "a trigger test failed"
    exit 1
fi
passed=$(grep -oaE "$PASS_RE" "$TMP/tests.out" | sort -u | wc -l)
# 7 checks: T1-T6 and T2b (the share rule with the freeze of 044 switched off).
if [ "$passed" -ne 7 ]; then
    echo "expected 7 PASS lines, found $passed"
    exit 1
fi
echo "== 7. tenant-isolation tests (db/tests/tenant_isolation_tests.sql)"
sq -i db/tests/tenant_isolation_tests.sql > "$TMP/isolation.out" 2>&1 || {
    cat "$TMP/isolation.out"
    echo "isolation test run failed"
    exit 1
}
cat "$TMP/isolation.out"
if grep -qaE "$FAIL_RE" "$TMP/isolation.out"; then
    echo "a tenant-isolation test failed"
    exit 1
fi
iso_pass=$(grep -oaE "$PASS_RE" "$TMP/isolation.out" | sort -u | wc -l)
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
if grep -qaE "$FAIL_RE" "$TMP/auth.out"; then
    echo "an account-security test failed"
    exit 1
fi
auth_pass=$(grep -oaE "$PASS_RE" "$TMP/auth.out" | sort -u | wc -l)
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
if grep -qaE "$FAIL_RE" "$TMP/operator.out"; then
    echo "an operator or support test failed"
    exit 1
fi
op_pass=$(grep -oaE "$PASS_RE" "$TMP/operator.out" | sort -u | wc -l)
# 11 cases: P1-P11 (ADR 0004: operator bootstrap, login, MFA, lockout, reset, status, direct rights; the support binding
# and its audit row, ADR 0007).
if [ "$op_pass" -ne 11 ]; then
    echo "expected 11 PASS, found $op_pass"
    exit 1
fi
echo "operator and support tests: $op_pass passed"
echo "== 10. job binding tests (db/tests/job_context_tests.sql)"
sq -i db/tests/job_context_tests.sql > "$TMP/jobs.out" 2>&1 || {
    cat "$TMP/jobs.out"
    echo "job binding test run failed"
    exit 1
}
cat "$TMP/jobs.out"
if grep -qaE "$FAIL_RE" "$TMP/jobs.out"; then
    echo "a job binding test failed"
    exit 1
fi
job_pass=$(grep -oaE "$PASS_RE" "$TMP/jobs.out" | sort -u | wc -l)
# 7 cases: J1-J7 (ADR 0004: job catalogue, service account, tenant status, tenant list, the real job binding and its
# audit row, ADR 0007).
if [ "$job_pass" -ne 7 ]; then
    echo "expected 7 PASS, found $job_pass"
    exit 1
fi
echo "job binding tests: $job_pass passed"
echo "== 11. tenant onboarding tests (db/tests/tenant_onboarding_tests.sql)"
sq -i db/tests/tenant_onboarding_tests.sql > "$TMP/onboarding.out" 2>&1 || {
    cat "$TMP/onboarding.out"
    echo "tenant onboarding test run failed"
    exit 1
}
cat "$TMP/onboarding.out"
if grep -qaE "$FAIL_RE" "$TMP/onboarding.out"; then
    echo "a tenant onboarding test failed"
    exit 1
fi
onb_pass=$(grep -oaE "$PASS_RE" "$TMP/onboarding.out" | sort -u | wc -l)
# 5 cases: O1-O5 (ADR 0004: tenant creation, first administrator invitation, status changes, daily status jobs).
if [ "$onb_pass" -ne 5 ]; then
    echo "expected 5 PASS, found $onb_pass"
    exit 1
fi
echo "tenant onboarding tests: $onb_pass passed"
echo "== 12. document numbering tests (db/tests/numbering_tests.sql)"
sq -i db/tests/numbering_tests.sql > "$TMP/numbering.out" 2>&1 || {
    cat "$TMP/numbering.out"
    echo "document numbering test run failed"
    exit 1
}
cat "$TMP/numbering.out"
if grep -qaE "$FAIL_RE" "$TMP/numbering.out"; then
    echo "a document numbering test failed"
    exit 1
fi
num_pass=$(grep -oaE "$PASS_RE" "$TMP/numbering.out" | sort -u | wc -l)
# 8 cases: N1-N8 (O-12: patterns, AC-PLT-3, rollback, widening, fiscal year, company scope, direct rights, isolation).
if [ "$num_pass" -ne 8 ]; then
    echo "expected 8 PASS, found $num_pass"
    exit 1
fi
echo "document numbering tests: $num_pass passed"
echo "== 13. document numbering with concurrent connections (tools/ci/numbering_concurrency.sh)"
SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" bash tools/ci/numbering_concurrency.sh > "$TMP/concurrency.out" 2>&1 || {
    cat "$TMP/concurrency.out"
    echo "document numbering concurrency run failed"
    exit 1
}
cat "$TMP/concurrency.out"
if grep -qaE "$FAIL_RE" "$TMP/concurrency.out"; then
    echo "a document numbering concurrency check failed"
    exit 1
fi
conc_pass=$(grep -oaE "$PASS_RE" "$TMP/concurrency.out" | sort -u | wc -l)
# 2 checks: C1 (concurrent connections, rollbacks, no duplicate and no gap) and C2 (outside a transaction).
if [ "$conc_pass" -ne 2 ]; then
    echo "expected 2 PASS, found $conc_pass"
    exit 1
fi
echo "document numbering concurrency: $conc_pass passed"
echo "== 14. KYC history and cascade tests (db/tests/kyc_history_tests.sql)"
sq -i db/tests/kyc_history_tests.sql > "$TMP/kyc.out" 2>&1 || {
    cat "$TMP/kyc.out"
    echo "KYC history test run failed"
    exit 1
}
cat "$TMP/kyc.out"
if grep -qaE "$FAIL_RE" "$TMP/kyc.out"; then
    echo "a KYC history test failed"
    exit 1
fi
kyc_pass=$(grep -oaE "$PASS_RE" "$TMP/kyc.out" | sort -u | wc -l)
# 4 cases: K1-K4 (O-13: no cascade on KYC financial data; completeness profiles change only as drafts).
if [ "$kyc_pass" -ne 4 ]; then
    echo "expected 4 PASS, found $kyc_pass"
    exit 1
fi
echo "KYC history tests: $kyc_pass passed"
echo "== 15. platform reference data tests (db/tests/reference_data_tests.sql)"
sq -i db/tests/reference_data_tests.sql > "$TMP/reference.out" 2>&1 || {
    cat "$TMP/reference.out"
    echo "reference data test run failed"
    exit 1
}
cat "$TMP/reference.out"
if grep -qaE "$FAIL_RE" "$TMP/reference.out"; then
    echo "a reference data test failed"
    exit 1
fi
ref_pass=$(grep -oaE "$PASS_RE" "$TMP/reference.out" | sort -u | wc -l)
# 4 cases: R1-R4 (a tenant reads the global lists and the platform UCP articles, writes none of them; seed hygiene).
if [ "$ref_pass" -ne 4 ]; then
    echo "expected 4 PASS, found $ref_pass"
    exit 1
fi
echo "reference data tests: $ref_pass passed"
echo "== 16. audit rows written by the database (db/tests/audit_trail_tests.sql)"
sq -i db/tests/audit_trail_tests.sql > "$TMP/audit.out" 2>&1 || {
    cat "$TMP/audit.out"
    echo "audit trail test run failed"
    exit 1
}
cat "$TMP/audit.out"
if grep -qaE "$FAIL_RE" "$TMP/audit.out"; then
    echo "an audit trail test failed"
    exit 1
fi
aud_pass=$(grep -oaE "$PASS_RE" "$TMP/audit.out" | sort -u | wc -l)
# 7 cases: AU1-AU7 (ADR 0007: logins, administrator and self-service actions, operators, tenant life, visibility).
# The support and job bindings are checked in steps 9 (P11) and 10 (J7).
if [ "$aud_pass" -ne 7 ]; then
    echo "expected 7 PASS, found $aud_pass"
    exit 1
fi
echo "audit trail tests: $aud_pass passed"
echo "== 17. data export in every status that allows it (db/tests/data_export_tests.sql)"
sq -i db/tests/data_export_tests.sql > "$TMP/export.out" 2>&1 || {
    cat "$TMP/export.out"
    echo "data export test run failed"
    exit 1
}
cat "$TMP/export.out"
if grep -qaE "$FAIL_RE" "$TMP/export.out"; then
    echo "a data export test failed"
    exit 1
fi
exp_pass=$(grep -oaE "$PASS_RE" "$TMP/export.out" | sort -u | wc -l)
# 7 cases: X1-X6 (ADR 0008: request rules, approval of restricted data, SUSPENDED, the CLOSED window, sensitive access
# log, expiry) and X7 (self-review A10: a package type marked sensitive).
if [ "$exp_pass" -ne 7 ]; then
    echo "expected 7 PASS, found $exp_pass"
    exit 1
fi
echo "data export tests: $exp_pass passed"
echo "== 18. service logins (tools/deploy/provision_logins.sh, tools/ci/service_logins_check.sh)"
SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" bash tools/ci/service_logins_check.sh > "$TMP/logins.out" 2>&1 || {
    cat "$TMP/logins.out"
    echo "service login check run failed"
    exit 1
}
cat "$TMP/logins.out"
if grep -qaE "$FAIL_RE" "$TMP/logins.out"; then
    echo "a service login check failed"
    exit 1
fi
log_pass=$(grep -oaE "$PASS_RE" "$TMP/logins.out" | sort -u | wc -l)
# 6 checks: LG1-LG6 (ADR 0009: one login per process, role rights, rotation, the pair, weak or exposed secrets, guards).
if [ "$log_pass" -ne 6 ]; then
    echo "expected 6 PASS, found $log_pass"
    exit 1
fi
echo "service login checks: $log_pass passed"
echo "== 19. fixes of the design-review findings (db/tests/review_fixes_tests.sql, O-15, ADR 0011)"
sq -i db/tests/review_fixes_tests.sql > "$TMP/review.out" 2>&1 || {
    cat "$TMP/review.out"
    echo "review fixes test run failed"
    exit 1
}
cat "$TMP/review.out"
if grep -qaE "$FAIL_RE" "$TMP/review.out"; then
    echo "a review fixes test failed"
    exit 1
fi
rf_pass=$(grep -oaE "$PASS_RE" "$TMP/review.out" | sort -u | wc -l)
# 43 cases: RF1 list columns, RF2-RF9 the S0 tables (DR-11 to DR-18), RF10 codes in capitals (DR-48), RF11-RF16
# the S1 tables (DR-19, DR-21, DR-23, DR-24, DR-29, DR-47), RF17-RF18 collateral kinds, agreement text and proformas
# (DR-40, DR-31, DR-41), RF19-RF21 the S1 entry conditions (DR-30, DR-16, DR-25), RF22 the S1-b entry condition
# (DR-22), RF23-RF27 the S2 entry conditions (DR-27, DR-28, DR-31, DR-36, DR-38), RF28-RF29 the S2-b entry condition
# (DR-39), RF30-RF33 the S3 entry conditions (DR-41, DR-49, DR-44, DR-46), RF34 the S4 one (DR-41), and SR1-SR9 the
# guards of the self-review of 2026-10-18 (docs/34). The declarative fixes are checked on the DDL in step 3
# (check_review_fixes.py).
if [ "$rf_pass" -ne 43 ]; then
    echo "expected 43 PASS, found $rf_pass"
    exit 1
fi
echo "review fixes tests: $rf_pass passed"
echo "== 19b. the financial statements module (db/tests/financial_statements_tests.sql, 045, ADR 0016)"
sq -i db/tests/financial_statements_tests.sql > "$TMP/fin.out" 2>&1 || {
    cat "$TMP/fin.out"
    echo "financial statements test run failed"
    exit 1
}
cat "$TMP/fin.out"
if grep -qaE "$FAIL_RE" "$TMP/fin.out"; then
    echo "a financial statements test failed"
    exit 1
fi
fs_pass=$(grep -oaE "$PASS_RE" "$TMP/fin.out" | sort -u | wc -l)
# 11 cases: FS1-FS3 consolidated and standalone statements and their life, FS4-FS5 the statements a test read and the
# breach report, FS6-FS8 liquidity routed to the bank and its performance, FS9-FS10 analysis measures and revenue
# estimates, FS11 the units of a consolidated statement (owner request of 2026-10-18).
if [ "$fs_pass" -ne 11 ]; then
    echo "expected 11 PASS, found $fs_pass"
    exit 1
fi
echo "financial statements tests: $fs_pass passed"
echo "== 19c. the credit assessment on the Moody's scale through the tables (db/tests/credit_assessment_tests.sql, 046, 047, ADR 0017 to ADR 0026)"
sq -i db/tests/credit_assessment_tests.sql > "$TMP/crd.out" 2>&1 || {
    cat "$TMP/crd.out"
    echo "credit assessment test run failed"
    exit 1
}
cat "$TMP/crd.out"
if grep -qaE "$FAIL_RE" "$TMP/crd.out"; then
    echo "a credit assessment test failed"
    exit 1
fi
ca_pass=$(grep -oaE "$PASS_RE" "$TMP/crd.out" | sort -u | wc -l)
# 31 cases: CA1 the continuum, its inverse and the item levels, CA2 the worked example through the tables equal to
# tools/dbgen/credit_reference.py, CA3 coverage, indicative grades and sub-factors, CA4 the data requested, CA5-CA6 the
# adjustments, group support and the override, CA7 the life of an assessment and what the application cannot write,
# CA8 the report, CA9 covenants, breaches and bank flows, CA10 the methodology fixed once approved, CA11 isolation,
# CA12 the seed, CA13 facilities, collateral, guarantors and the bureau report, CA14 activity, products, scenarios and
# strengthening plans, CA15 the hash of what was read, CA16 the market country and city and the detailed activity
# (owner requests of 2026-10-18 and 2026-10-19, ADR 0019), CA17 the lender's actual decision on a facility (ADR 0021), CA18 the trial assessment of a statement before
# its approval (ADR 0022), CA19 the presentation versions of a statement (ADR 0023),
# CA20 the readiness file, its timeline and the early warning (ADR 0024), CA21 the budget statements (ADR 0025),
# CA22 the ratings a lender communicated (ADR 0026), CA23 the early warning job and its notification requests (ADR 0027),
# CA24 the message templates of the tenant pack NTF.BASE (ADR 0028), CA25 the endorsement for use outside the company and
# CA26 the calibration against the lenders' ratings (ADR 0029), CA27 to CA30 the confirmed monthly figures, the evidence
# pack, the calibration in the readiness and the provision matrix (ADR 0030), CA31 the close of the periods (ADR 0031).
if [ "$ca_pass" -ne 31 ]; then
    echo "expected 31 PASS, found $ca_pass"
    exit 1
fi
echo "credit assessment tests: $ca_pass passed"
echo "== 19d. the T-SQL credit engine equals the Python reference, number for number (db/tests/credit_engine_cases.sql, 047, ADR 0018)"
sq -i db/tests/credit_engine_cases.sql > "$TMP/cre.out" 2>&1 || {
    cat "$TMP/cre.out"
    echo "credit engine case run failed"
    exit 1
}
grep -aE "$FAIL_RE" "$TMP/cre.out" && { echo "a credit engine case differs from the reference"; exit 1; }
ce_pass=$(grep -oaE "$PASS_RE" "$TMP/cre.out" | sort -u | wc -l)
ce_want=$(grep -c "^/\* C[EV][0-9]*:" db/tests/credit_engine_cases.sql)
# a floor, so a generator that loses cases does not lower what is expected with them (review B2): 74 cases, CE and CV
if [ "$ce_want" -lt 148 ]; then
    echo "db/tests/credit_engine_cases.sql holds $ce_want cases, fewer than the 148 expected"
    exit 1
fi
# each stress case and variant twice: the core (CE) and the whole evaluation with scenarios, remedies and plans (CV)
if [ "$ce_pass" -ne "$ce_want" ]; then
    echo "expected $ce_want PASS, found $ce_pass"
    exit 1
fi
echo "credit engine cases: $ce_pass passed"
echo "== 20. SQL Server Audit and its AL-18 alerts (tools/deploy/server_audit.sh, tools/ci/server_audit_check.sh, ADR 0012)"
SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" AUDIT_SINCE="$audit_since" MIGRATOR_SECRET="$TMP/migrator/bankfas_migrator.secret" \
    bash tools/ci/server_audit_check.sh > "$TMP/server_audit.out" 2>&1 || {
    cat "$TMP/server_audit.out"
    echo "server audit check run failed"
    exit 1
}
cat "$TMP/server_audit.out"
if grep -qaE "$FAIL_RE" "$TMP/server_audit.out"; then
    echo "a server audit check failed"
    exit 1
fi
sa_pass=$(grep -oaE "$PASS_RE" "$TMP/server_audit.out" | sort -u | wc -l)
# 9 checks: SA1-SA9 (DOC-S08 section 10, DQ-S08-10: the audit in place, the deployment inside its window, service
# logins, dbo on the audit tables, the AL-18 rules outside a window, a reader without administrator rights, a stopped
# audit; self-review E1: a window declared by a login that cannot open one; E2 and E6: server settings, logins and
# the migrator stopping the audit specification).
if [ "$sa_pass" -ne 9 ]; then
    echo "expected 9 PASS, found $sa_pass"
    exit 1
fi
echo "server audit checks: $sa_pass passed"
echo "== 21. the monitoring login (tools/deploy/provision_monitor.sh, tools/ci/monitor_login_check.sh, ADR 0013)"
SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" MONITOR_SECRETS="$TMP/monitor" \
    bash tools/ci/monitor_login_check.sh > "$TMP/monitor.out" 2>&1 || {
    cat "$TMP/monitor.out"
    echo "monitoring login check run failed"
    exit 1
}
cat "$TMP/monitor.out"
if grep -qaE "$FAIL_RE" "$TMP/monitor.out"; then
    echo "a monitoring login check failed"
    exit 1
fi
mn_pass=$(grep -oaE "$PASS_RE" "$TMP/monitor.out" | sort -u | wc -l)
# 6 checks: MN1-MN6 (DQ-S12-6: the view rights, what it runs, what it cannot read, the post-deployment check finding
# a disabled policy, the guards against added rights, rotation).
if [ "$mn_pass" -ne 6 ]; then
    echo "expected 6 PASS, found $mn_pass"
    exit 1
fi
echo "monitoring login checks: $mn_pass passed"
echo "== 22. the deployment preflight (db/ops/deploy_preflight.sql, tools/deploy/preflight.sh, tools/ci/deploy_preflight_check.sh, ADR 0014)"
SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" MIGRATOR_SECRET="$TMP/migrator/bankfas_migrator.secret" MONITOR_SECRETS="$TMP/monitor" \
    bash tools/ci/deploy_preflight_check.sh > "$TMP/preflight.out" 2>&1 || {
    cat "$TMP/preflight.out"
    echo "deployment preflight check run failed"
    exit 1
}
cat "$TMP/preflight.out"
if grep -qaE "$FAIL_RE" "$TMP/preflight.out"; then
    echo "a deployment preflight check failed"
    exit 1
fi
pf_pass=$(grep -oaE "$PASS_RE" "$TMP/preflight.out" | sort -u | wc -l)
# 8 checks: PF1-PF8 (DQ-S11-6: a database that is not empty, sa and a sysadmin, -C outside CI, sa in the
# administrator scripts outside CI, the release register; self-review A7: RECURSIVE_TRIGGERS ON; E7: the options
# allowlist; E4 and E9: a database made ready by someone else, server-wide rights).
if [ "$pf_pass" -ne 8 ]; then
    echo "expected 8 PASS, found $pf_pass"
    exit 1
fi
echo "deployment preflight checks: $pf_pass passed"
echo "== 22b. the key guard and the audit hash chain (db/tests/integrity_tests.sql, 054, 055, ADR 0032, ADR 0033)"
sq -i db/tests/integrity_tests.sql > "$TMP/integrity.out" 2>&1 || {
    cat "$TMP/integrity.out"
    echo "integrity test run failed"
    exit 1
}
cat "$TMP/integrity.out"
if grep -qaE "$FAIL_RE" "$TMP/integrity.out"; then
    echo "an integrity test failed"
    exit 1
fi
in_pass=$(grep -oaE "$PASS_RE" "$TMP/integrity.out" | sort -u | wc -l)
# 17 cases: KG1-KG7 (DR-20: new rows on an ACTIVE key only, the key lifecycle, retirement only when unused, revocation
# at once, every key column guarded, the key itself) and AC1-AC10 (FR-PLT-025: the chain, the anchors, changed, removed
# and unchained rows, the job's rights, the daily check from the anchor, chaining later, two chains at once, the
# store's anchors and the operators' rows; internal review v6).
if [ "$in_pass" -ne 17 ]; then
    echo "expected 17 PASS, found $in_pass"
    exit 1
fi
echo "integrity tests: $in_pass passed"
echo "== 22c. the anchors of the audit chain kept outside the database (tools/deploy/audit_anchor.sh, tools/ci/audit_anchor_check.sh)"
SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" bash tools/ci/audit_anchor_check.sh > "$TMP/anchor.out" 2>&1 || {
    cat "$TMP/anchor.out"
    echo "audit anchor check run failed"
    exit 1
}
cat "$TMP/anchor.out"
if grep -qaE "$FAIL_RE" "$TMP/anchor.out"; then
    echo "an audit anchor check failed"
    exit 1
fi
aa_pass=$(grep -oaE "$PASS_RE" "$TMP/anchor.out" | sort -u | wc -l)
# 7 checks: AA1 (the store's mark, a new read-only file per run), AA2 (each chain verified against its latest anchor),
# AA3 (an old row changed passes the daily check, fails the full check, and passes once put back), AA4 (a rewritten
# chain is never anchored), AA5 (the store decides what moved), AA6 (stale and missing anchors), AA7 (a restore).
if [ "$aa_pass" -ne 7 ]; then
    echo "expected 7 PASS, found $aa_pass"
    exit 1
fi
echo "audit anchor checks: $aa_pass passed"
echo "== 22d. incremental schema changes (tools/deploy/migrate.sh, tools/ci/migration_check.sh, 056, ADR 0034)"
SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" MIGRATOR_SECRET="$TMP/migrator/bankfas_migrator.secret" \
    bash tools/ci/migration_check.sh > "$TMP/migration.out" 2>&1 || {
    cat "$TMP/migration.out"
    echo "migration check run failed"
    exit 1
}
cat "$TMP/migration.out"
if grep -qaE "$FAIL_RE" "$TMP/migration.out"; then
    echo "a migration check failed"
    exit 1
fi
mg_pass=$(grep -oaE "$PASS_RE" "$TMP/migration.out" | sort -u | wc -l)
# 12 checks: MG1 (deploy.sh journals the baseline), MG2 (nothing pending), MG3 (the repeatable scripts run again with
# the fingerprint unchanged), MG4 (a versioned script once), MG5 (edited, removed, early, duplicate, misnamed and
# transaction-ending scripts refused), MG6 (a failing script rolls back), MG7 (a table, a member, a grant or a DDL
# trigger outside the journal stops apply), MG8 (the window: backup first, sa refused), MG9 (a failed repeatable run
# is taken up again), MG10 (the baseline journals the versioned scripts), MG11 (the change reference), MG12 (clean-up).
if [ "$mg_pass" -ne 12 ]; then
    echo "expected 12 PASS, found $mg_pass"
    exit 1
fi
echo "migration checks: $mg_pass passed"
echo "== 22e. the system roles of the pack CORE.ROLES (db/tests/core_roles_tests.sql, 057, ADR 0035)"
sq -i db/tests/core_roles_tests.sql > "$TMP/roles_tests.out" 2>&1 || {
    cat "$TMP/roles_tests.out"
    echo "core roles test run failed"
    exit 1
}
cat "$TMP/roles_tests.out"
if grep -qaE "$FAIL_RE" "$TMP/roles_tests.out"; then
    echo "a core roles test failed"
    exit 1
fi
cr_pass=$(grep -oaE "$PASS_RE" "$TMP/roles_tests.out" | sort -u | wc -l)
# 9 cases: CR1 (the 8 roles and 393 links), CR2 (a second run keeps the tenant's changes), CR3 (per role, and the locked
# permissions on TM and FO only), CR4 (RK endorses from outside the preparing line, E2), CR5 (rights), CR6 (stages B and C),
# CR7 (an open tenant only), CR8 (the catalogue complete), CR9 (a role made before the pack).
if [ "$cr_pass" -ne 9 ]; then
    echo "expected 9 PASS, found $cr_pass"
    exit 1
fi
echo "core roles tests: $cr_pass passed"
echo "== 22f. the actors of the financial records and what a closed period freezes (db/tests/finance_controls_tests.sql, 058, ADR 0037)"
sq -i db/tests/finance_controls_tests.sql > "$TMP/fin_controls.out" 2>&1 || {
    cat "$TMP/fin_controls.out"
    echo "finance controls test run failed"
    exit 1
}
grep -av 'Null value is eliminated' "$TMP/fin_controls.out"
if grep -qaE "$FAIL_RE" "$TMP/fin_controls.out"; then
    echo "a finance controls test failed"
    exit 1
fi
fc_pass=$(grep -oaE "$PASS_RE" "$TMP/fin_controls.out" | sort -u | wc -l)
# 14 cases: FC1-FC3 the preparer, approver and chooser are the bound user with the permission of the act; FC4-FC6
# monthly figures, revenue estimates and loss rates; FC7 a closed period frozen indirectly; FC8 ratings and product lines
# once used; FC9 calibration and early warnings; FC10 the evidence pack; FC11 the platform data in the hash; FC12 group
# support; FC13 the provision matrix; FC14 the endorser's independence.
if [ "$fc_pass" -ne 14 ]; then
    echo "expected 14 PASS, found $fc_pass"
    exit 1
fi
echo "finance controls tests: $fc_pass passed"
echo "== 23. nothing the tests switched off is left off, and no test data is left (self-review C10)"
# The tests switch constraints and triggers off only inside their transactions, and make users without logins that
# each test drops at its end: none may be left (counted before anything is dropped; internal review v6, B9). Then every
# key and check is trusted, every trigger and row filter is on, and no tenant is left behind.
test_users="$(sq -d BankFas -h -1 -W -Q "SET NOCOUNT ON; SELECT CONCAT('users:', COUNT(*)) FROM sys.database_principals WHERE name LIKE N'tp[_]test[_]%' OR name LIKE N'ci[_]%' OR name LIKE N'mg[_]%';" | grep -oE '^users:[0-9]+$' | tail -1)"
if [ "$test_users" != "users:0" ]; then
    echo "the tests left database users behind ($test_users): $(sq -d BankFas -h -1 -W -Q "SET NOCOUNT ON; SELECT STRING_AGG(name, ', ') FROM sys.database_principals WHERE name LIKE N'tp[_]test[_]%' OR name LIKE N'ci[_]%' OR name LIKE N'mg[_]%';" | tail -1)"
    exit 1
fi
sq -d BankFas -Q "SET NOCOUNT ON; DECLARE @s NVARCHAR(MAX) = N''; SELECT @s += N'DROP USER ' + QUOTENAME(name) + N';' FROM sys.database_principals WHERE name LIKE N'tp[_]test[_]%' AND type = 'S'; EXEC (@s);" >/dev/null
left="$(sq -d BankFas -h -1 -W -Q "SET NOCOUNT ON; SELECT CONCAT((SELECT COUNT(*) FROM sys.foreign_keys WHERE is_disabled = 1 OR is_not_trusted = 1), '/', (SELECT COUNT(*) FROM sys.check_constraints WHERE is_disabled = 1 OR is_not_trusted = 1), '/', (SELECT COUNT(*) FROM sys.triggers WHERE is_disabled = 1), '/', (SELECT COUNT(*) FROM sys.security_policies WHERE is_enabled = 0), '/', (SELECT COUNT(*) FROM sys.database_principals WHERE name LIKE N'tp[_]test[_]%'), '/', (SELECT COUNT(*) FROM plat.Tenant));" | grep -oE '^[0-9]+(/[0-9]+){5}$' | tail -1)"
if [ "$left" != "0/0/0/0/0/0" ]; then
    echo "the tests left something behind: untrusted keys/checks/disabled triggers/disabled policies/test users/tenants $left (expected 0/0/0/0/0/0)"
    exit 1
fi
echo "every key and check is trusted, every trigger and row filter is on, and no test user or tenant is left ($left)"
echo "== 24. the performance scripts at small sizes (tools/perf/run_perf.sh, ADR 0036); it builds BankFas again, so it runs last"
# The full measurement (300 tenants, three at the volume of NFR-SCL-02) takes about 25 minutes and is run by hand
# (docs/40); here the same scripts run on 1 full and 3 light tenants, so a change of the schema cannot break them unseen.
SA_PASSWORD="$SA_PASSWORD" SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" PERF_FULL=1 PERF_LIGHT=3 PERF_COMPANIES=10 PERF_YEARS=2 \
    PERF_AUDIT=2000 PERF_SESSIONS=1000 PERF_LIGHT_AUDIT=200 PERF_ITER=5 PERF_BIND=5 PERF_WRITERS=2 PERF_WRITES=50 \
    PERF_OUT="$TMP/perf-run.txt" PERF_REPORT="$TMP/perf-results.md" bash tools/perf/run_perf.sh > "$TMP/perf.out" 2>&1 || {
    tail -30 "$TMP/perf.out"
    echo "the performance scripts failed"
    exit 1
}
perf_n=$(grep -c '^RESULT|' "$TMP/perf-run.txt" || true)
# the chain after the two writers holds at least their rows, and the J2 and J4 checks of the measured chain are OK (B9)
c1_rows="$(grep -oE '^INFO\|C1\|chain after the concurrent writers\|[0-9]+ OK$' "$TMP/perf-run.txt" | grep -oE '[0-9]+ OK$' | cut -d' ' -f1 || true)"
if [ "$perf_n" -ne 18 ] || [ -z "$c1_rows" ] || [ "$c1_rows" -lt 100 ] \
   || ! grep -qE '^INFO\|J2\|.*OK' "$TMP/perf-run.txt" || ! grep -qE '^INFO\|J4\|.*OK' "$TMP/perf-run.txt"; then
    tail -30 "$TMP/perf-run.txt"
    echo "the performance run gave $perf_n results (expected 18), or a chain check was not OK (C1 rows ${c1_rows:-none}, J2, J4)"
    exit 1
fi
echo "performance scripts: $perf_n results, the chain OK after the concurrent writers"
echo "all database checks passed"

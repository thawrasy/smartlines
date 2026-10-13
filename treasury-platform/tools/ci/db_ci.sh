#!/usr/bin/env bash
# Database CI: checks the model, confirms the generated DDL is current, deploys it to SQL Server,
# compares what was deployed with the DDL, and runs the trigger, tenant-isolation, account-security,
# operator-and-support, job-binding, tenant-onboarding, document-numbering (one of them with concurrent connections),
# KYC history, reference data, audit trail and data export tests, the service logins of the deployment, and the SQL
# Server Audit of the server with its AL-18 alerts, and the monitoring login that runs the post-deployment check.
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
# The tools in tools/deploy and check_deployed.py verify the server certificate by default (DQ-S05-7). The throwaway
# container of CI has a self-signed one, so CI alone trusts it, here and for every script it runs. The same tools
# refuse -C, and the administrator scripts refuse sa, unless these two allowances are set (DQ-S11-6, ADR 0014); only CI
# sets them.
export SQLCMD_OPTS=-C BANKFAS_ALLOW_TRUST_CERT=1 BANKFAS_ALLOW_SA=1
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
# The permission catalogue is generated from the readiness documents and the specs' role matrices (DQ-F07-1, DQ-F09-1).
python3 tools/dbgen/gen_permission_seed.py "$TMP/102_permissions.sql" >/dev/null
if ! diff -q "$TMP/102_permissions.sql" db/seed/102_permissions.sql >/dev/null; then
    echo "db/seed/102_permissions.sql is stale: run tools/dbgen/gen_permission_seed.py and commit the result"
    exit 1
fi
echo "permission seed matches the documents"

echo "== 3. every foreign key is indexed or flagged noidx; static grant and cascade rules R1-R11"
python3 tools/dbgen/check_fk_indexes.py
python3 tools/dbgen/check_grants.py
python3 tools/dbgen/check_review_fixes.py | tail -1   # the design-review fixes in the generated DDL (C-12, O-15)
# No deployment tool trusts any certificate by itself; only CI passes -C (DQ-S05-7, ADR 0013).
# A default of -C, or -C written into a command, in the shell, Python and PowerShell tools.
if grep -n 'SQLCMD_OPTS--C' tools/deploy/*.sh \
   || grep -nE "'-C',|, '-C'[])]|SQLCMD_OPTS', '[^']*-C" tools/dbgen/check_deployed.py tools/deploy/deploy.ps1; then
    echo "a deployment tool passes -C by default"
    exit 1
fi
echo "no deployment tool trusts the server certificate by default"
# CI runs the SQL Server image of the release register (DQ-B01-2, FR-PLT-045); the deployment preflight compares the
# server's build with the same register (gate G4).
python3 - <<'PY'
import json, re, sys
want = json.load(open('versions.json', encoding='utf-8'))['database_host']['ci_image']
flow = open('../.github/workflows/treasury-db-ci.yml', encoding='utf-8').read()
got = re.findall(r'^\s*image:\s*(mcr\.microsoft\.com/mssql/\S+)', flow, re.M)
if got != [want]:
    sys.exit(f'the CI image {got} is not the one of versions.json ({want})')
print(f'CI runs the SQL Server image of the release register: {want}')
PY

echo "== 4. deploy db/deploy.sql to a fresh BankFas database the way production does (DOC-S11, ADR 0010, ADR 0012)"
audit_since="$(sq -h -1 -W -Q "SET NOCOUNT ON; SELECT CONVERT(VARCHAR(19), SYSUTCDATETIME(), 126);")"
sq -Q "IF DB_ID(N'BankFas') IS NOT NULL BEGIN ALTER DATABASE [BankFas] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [BankFas]; END" >/dev/null
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
seed_state() { sq -d BankFas -h -1 -W -Q "SET NOCOUNT ON; SELECT CONCAT((SELECT COUNT(*) FROM cfg.SettingDefinition), '/', (SELECT COUNT(*) FROM cfg.JobDefinition), '/', (SELECT COUNT(*) FROM plat.[Plan]), '/', (SELECT COUNT(*) FROM plat.PlanModule), '/', (SELECT COUNT(*) FROM plat.ReservedSubdomain), '/', (SELECT COUNT(*) FROM ref.Country), '/', (SELECT COUNT(*) FROM ref.Currency), '/', (SELECT COUNT(*) FROM sec.Permission), '/', (SELECT COUNT(*) FROM ref.Incoterm), '/', (SELECT COUNT(*) FROM ref.UcpArticle WHERE TenantId IS NULL AND VerificationStatus = 'UNVERIFIED'), '/', (SELECT COUNT(UpdatedAt) FROM cfg.SettingDefinition) + (SELECT COUNT(UpdatedAt) FROM cfg.JobDefinition) + (SELECT COUNT(UpdatedAt) FROM plat.[Plan]) + (SELECT COUNT(UpdatedAt) FROM ref.Incoterm) + (SELECT COUNT(UpdatedAt) FROM ref.UcpArticle))"; }
seed_before="$(seed_state)"
sq -d BankFas -i db/seed/100_platform_global.sql >/dev/null
sq -d BankFas -i db/seed/101_iso_reference.sql >/dev/null
sq -d BankFas -i db/seed/102_permissions.sql >/dev/null
sq -d BankFas -i db/seed/103_lc_reference.sql >/dev/null
seed_after="$(seed_state)"
if [ "$seed_before" != "$seed_after" ] || [ "$seed_before" != "9/32/1/9/23/249/157/138/16/39/0" ]; then
    echo "platform seed is not safe to run again, or incomplete: settings/jobs/plans/plan modules/reserved/countries/currencies/permissions/Incoterms/unverified UCP articles/updated before $seed_before, after $seed_after (expected 9/32/1/9/23/249/157/138/16/39/0)"
    exit 1
fi
echo "platform seed unchanged on a second run ($seed_after)"

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
if grep -q '^FAIL' "$TMP/jobs.out"; then
    echo "a job binding test failed"
    exit 1
fi
job_pass=$(grep -c '^PASS' "$TMP/jobs.out" || true)
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
if grep -q '^FAIL' "$TMP/onboarding.out"; then
    echo "a tenant onboarding test failed"
    exit 1
fi
onb_pass=$(grep -c '^PASS' "$TMP/onboarding.out" || true)
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
if grep -q '^FAIL' "$TMP/numbering.out"; then
    echo "a document numbering test failed"
    exit 1
fi
num_pass=$(grep -c '^PASS' "$TMP/numbering.out" || true)
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
if grep -q '^FAIL' "$TMP/concurrency.out"; then
    echo "a document numbering concurrency check failed"
    exit 1
fi
conc_pass=$(grep -c '^PASS' "$TMP/concurrency.out" || true)
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
if grep -q '^FAIL' "$TMP/kyc.out"; then
    echo "a KYC history test failed"
    exit 1
fi
kyc_pass=$(grep -c '^PASS' "$TMP/kyc.out" || true)
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
if grep -q '^FAIL' "$TMP/reference.out"; then
    echo "a reference data test failed"
    exit 1
fi
ref_pass=$(grep -c '^PASS' "$TMP/reference.out" || true)
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
if grep -q '^FAIL' "$TMP/audit.out"; then
    echo "an audit trail test failed"
    exit 1
fi
aud_pass=$(grep -c '^PASS' "$TMP/audit.out" || true)
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
if grep -q '^FAIL' "$TMP/export.out"; then
    echo "a data export test failed"
    exit 1
fi
exp_pass=$(grep -c '^PASS' "$TMP/export.out" || true)
# 6 cases: X1-X6 (ADR 0008: request rules, approval of restricted data, SUSPENDED, the CLOSED window, sensitive access
# log, expiry).
if [ "$exp_pass" -ne 6 ]; then
    echo "expected 6 PASS, found $exp_pass"
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
if grep -q '^FAIL' "$TMP/logins.out"; then
    echo "a service login check failed"
    exit 1
fi
log_pass=$(grep -c '^PASS' "$TMP/logins.out" || true)
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
# The older sqlcmd of the development container can print a fragment of its input before a result line; the cases
# are therefore matched anywhere on the line and counted once each.
if grep -qE 'FAIL RF[0-9]+:' "$TMP/review.out"; then
    echo "a review fixes test failed"
    exit 1
fi
rf_pass=$(grep -oE 'PASS RF[0-9]+:' "$TMP/review.out" | sort -u | wc -l)
# 34 cases: RF1 list columns, RF2-RF9 the S0 tables (DR-11 to DR-18), RF10 codes in capitals (DR-48), RF11-RF16
# the S1 tables (DR-19, DR-21, DR-23, DR-24, DR-29, DR-47), RF17-RF18 collateral kinds, agreement text and proformas
# (DR-40, DR-31, DR-41), RF19-RF21 the S1 entry conditions (DR-30, DR-16, DR-25), RF22 the S1-b entry condition
# (DR-22), RF23-RF27 the S2 entry conditions (DR-27, DR-28, DR-31, DR-36, DR-38), RF28-RF29 the S2-b entry condition
# (DR-39), RF30-RF33 the S3 entry conditions (DR-41, DR-49, DR-44, DR-46) and RF34 the S4 one (DR-41). The declarative
# fixes are checked on the DDL in step 3 (check_review_fixes.py).
if [ "$rf_pass" -ne 34 ]; then
    echo "expected 34 PASS, found $rf_pass"
    exit 1
fi
echo "review fixes tests: $rf_pass passed"
echo "== 20. SQL Server Audit and its AL-18 alerts (tools/deploy/server_audit.sh, tools/ci/server_audit_check.sh, ADR 0012)"
SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" AUDIT_SINCE="$audit_since" MIGRATOR_SECRET="$TMP/migrator/bankfas_migrator.secret" \
    bash tools/ci/server_audit_check.sh > "$TMP/server_audit.out" 2>&1 || {
    cat "$TMP/server_audit.out"
    echo "server audit check run failed"
    exit 1
}
cat "$TMP/server_audit.out"
if grep -q '^FAIL' "$TMP/server_audit.out"; then
    echo "a server audit check failed"
    exit 1
fi
sa_pass=$(grep -c '^PASS' "$TMP/server_audit.out" || true)
# 7 checks: SA1-SA7 (DOC-S08 section 10, DQ-S08-10: the audit in place, the deployment inside its window, service
# logins, dbo on the audit tables, the AL-18 rules outside a window, a reader without administrator rights, a stopped
# audit).
if [ "$sa_pass" -ne 7 ]; then
    echo "expected 7 PASS, found $sa_pass"
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
if grep -q '^FAIL' "$TMP/monitor.out"; then
    echo "a monitoring login check failed"
    exit 1
fi
mn_pass=$(grep -c '^PASS' "$TMP/monitor.out" || true)
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
if grep -q '^FAIL' "$TMP/preflight.out"; then
    echo "a deployment preflight check failed"
    exit 1
fi
pf_pass=$(grep -c '^PASS' "$TMP/preflight.out" || true)
# 5 checks: PF1-PF5 (DQ-S11-6: a database that is not empty, sa and a sysadmin, -C outside CI, sa in the
# administrator scripts outside CI, the release register).
if [ "$pf_pass" -ne 5 ]; then
    echo "expected 5 PASS, found $pf_pass"
    exit 1
fi
echo "deployment preflight checks: $pf_pass passed"
echo "all database checks passed"

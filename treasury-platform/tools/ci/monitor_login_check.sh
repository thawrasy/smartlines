#!/usr/bin/env bash
# The monitoring login (tools/deploy/provision_monitor.sh, db/ops/monitor_login.sql; ADR 0013, DQ-S12-6): step 4 made
# it inside the deployment window with exactly its view rights; it runs the post-deployment check, the audit check
# and alerts and the health queries without any administrator right; it reads no row and runs nothing; the
# post-deployment check it runs finds a disabled security policy; a right added by hand stops the next provisioning;
# a new secret rotates it. Prints PASS or FAIL lines like the .sql tests.
#
# Environment: SQLCMDPASSWORD (sa), SQL_SERVER (default localhost,1433), SQLCMD (default sqlcmd), SQLCMD_OPTS (as for
#              tools/deploy, -C in CI), MONITOR_SECRETS (the folder of bankfas_monitor.secret from step 4)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
SA_PW="${SQLCMDPASSWORD:?set SQLCMDPASSWORD to the sa password}"
SEC="${MONITOR_SECRETS:?set MONITOR_SECRETS to the folder of bankfas_monitor.secret}"
export SQL_SERVER SQLCMD
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sa_run() { printf '%s\n' "$1" > "$TMP/sa.sql"; SQLCMDPASSWORD="$SA_PW" "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -h -1 -W -i "$TMP/sa.sql"; }
secret() { head -n 1 "$SEC/bankfas_monitor.secret"; }
as_monitor() {   # statement [secret]; fails when the login or the statement fails
    printf '%s\n' "$1" > "$TMP/m.sql"
    SQLCMDPASSWORD="${2:-$(secret)}" "$SQLCMD" -S "$SQL_SERVER" -U bankfas_monitor -C -I -b -h -1 -W -i "$TMP/m.sql" 2>&1
}
provision() { SQLCMDPASSWORD="$SA_PW" SQL_USER=sa BANKFAS_SECRETS_DIR="$SEC" BANKFAS_CHANGE_REF=CI-monitor \
                  bash "$ROOT/tools/deploy/provision_monitor.sh" > "$TMP/provision.out" 2>&1; }
deployed_check() { SQL_USER=bankfas_monitor SQLCMDPASSWORD="$(secret)" \
                       python3 "$ROOT/tools/dbgen/check_deployed.py" --sqlcmd "$SQLCMD" --server "$SQL_SERVER" --database BankFas 2>&1; }
audit_as_monitor() { SQL_USER=bankfas_monitor SQLCMDPASSWORD="$(secret)" bash "$ROOT/tools/deploy/server_audit.sh" "$@" 2>&1; }
rights="$(cat <<'SQL'
SET NOCOUNT ON; SELECT CONCAT(
  (SELECT STRING_AGG(permission_name, N',') WITHIN GROUP (ORDER BY permission_name) FROM sys.server_permissions
   WHERE grantee_principal_id = SUSER_ID(N'bankfas_monitor') AND state = N'G'), N'/',
  (SELECT COUNT(*) FROM sys.server_role_members WHERE member_principal_id = SUSER_ID(N'bankfas_monitor')), N'/',
  (SELECT STRING_AGG(p.permission_name, N',') WITHIN GROUP (ORDER BY p.permission_name) FROM BankFas.sys.database_permissions AS p
   JOIN BankFas.sys.database_principals AS u ON u.principal_id = p.grantee_principal_id WHERE u.name = N'bankfas_monitor'), N'/',
  (SELECT COUNT(*) FROM BankFas.sys.database_role_members AS m JOIN BankFas.sys.database_principals AS u
   ON u.principal_id = m.member_principal_id WHERE u.name = N'bankfas_monitor'), N'/',
  (SELECT STRING_AGG(RTRIM(CONCAT(p.permission_name, N' ', OBJECT_NAME(p.major_id, DB_ID(N'msdb')))), N',')
          WITHIN GROUP (ORDER BY OBJECT_NAME(p.major_id, DB_ID(N'msdb')), p.permission_name)
   FROM msdb.sys.database_permissions AS p JOIN msdb.sys.database_principals AS u ON u.principal_id = p.grantee_principal_id
   WHERE u.name = N'bankfas_monitor'));
SQL
)"

# MN1: step 4 made the login inside the deployment window with exactly its view rights, no role, and a private secret.
got="$(sa_run "$rights")"
want="CONNECT SQL,VIEW ANY SECURITY DEFINITION,VIEW SERVER PERFORMANCE STATE,VIEW SERVER SECURITY AUDIT,VIEW SERVER SECURITY STATE/0/CONNECT,VIEW DEFINITION/0/CONNECT,SELECT backupmediafamily,SELECT backupset"
mode="$(stat -c '%a' "$SEC/bankfas_monitor.secret")"
if [ "$got" = "$want" ] && [ "$mode" = "600" ]; then
    echo "PASS MN1: bankfas_monitor holds its four view rights, VIEW DEFINITION in BankFas and the backup history in msdb, no role, and a private secret"
else
    echo "FAIL MN1: rights [$got] (expected [$want]), secret mode $mode"
fi

# MN2: without any administrator right it runs the post-deployment check, the audit check and alerts, and the health
# queries of DOC-S10 section 9 (log space, sessions, backup history, audit status).
post="$(deployed_check || true)"
audit_check="$(audit_as_monitor check || true)"
audit_alerts="$(audit_as_monitor alerts || true)"
health="$(as_monitor "SET NOCOUNT ON; USE [BankFas];
SELECT CONCAT((SELECT COUNT(*) FROM sys.dm_db_log_space_usage), '/', SIGN((SELECT COUNT(*) FROM sys.dm_exec_sessions)), '/',
              (SELECT COUNT(*) FROM msdb.dbo.backupset WHERE 1 = 0), '/',
              (SELECT COUNT(*) FROM sys.dm_server_audit_status WHERE name = N'BankFas_Audit' AND status_desc = N'STARTED'));" | tail -n 1 || true)"
if ! grep -q '^DIFF' <<< "$post" && [ "$(grep -c '^ok ' <<< "$post")" -eq 14 ] \
   && [[ "$audit_check" == "audit in place and writing"* ]] && grep -q '^AL-18 alerts since' <<< "$audit_alerts" \
   && [ "$health" = "1/1/0/1" ]; then
    echo "PASS MN2: the monitoring login runs the post-deployment check (14 checks), the audit check and alerts, and the health queries"
else
    echo "FAIL MN2: post-deployment [$post], audit check [$audit_check], alerts [$(tail -n 1 <<< "$audit_alerts")], health [$health]"
fi

# MN3: it reads no row, writes nothing, runs no procedure and sees no password hash.
refused=0
for q in "SELECT TOP 1 1 FROM plat.Tenant;" "SELECT TOP 1 1 FROM aud.AuditLog;" "SELECT TOP 1 1 FROM sec.AppUser;" \
         "SELECT TOP 1 1 FROM org.Company;" "DELETE FROM cfg.JobRun WHERE 1 = 0;" "EXEC sec.usp_SetSessionContext @TenantId = 1;"; do
    out="$(as_monitor "USE [BankFas]; $q" || true)"
    if grep -q "Msg 229" <<< "$out"; then refused=$((refused + 1)); else echo "  not refused: $q [$out]"; fi
done
hashes="$(as_monitor "SET NOCOUNT ON; SELECT CONCAT(COUNT(*), '/', COUNT(password_hash)) FROM sys.sql_logins;" | tail -n 1 || true)"
if [ "$refused" -eq 6 ] && [[ "$hashes" =~ ^[1-9][0-9]*/0$ ]]; then
    echo "PASS MN3: the monitoring login reads no row, deletes nothing, runs no procedure and sees no password hash ($hashes)"
else
    echo "FAIL MN3: $refused of 6 refused, logins/hashes seen $hashes"
fi

# MN4: the post-deployment check it runs finds a disabled security policy and a disabled trigger (self-review C6), and
# passes again once both are enabled.
policy="$(sa_run "SET NOCOUNT ON; USE [BankFas]; SELECT TOP 1 QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(name) FROM sys.security_policies ORDER BY name;" | tail -n 1)"
sa_run "USE [BankFas]; ALTER SECURITY POLICY $policy WITH (STATE = OFF); ALTER TABLE fac.Limit DISABLE TRIGGER TR_Limit_ApprovedFrozen;" >/dev/null
rc_off=0; off="$(deployed_check)" || rc_off=$?
sa_run "USE [BankFas]; ALTER SECURITY POLICY $policy WITH (STATE = ON); ALTER TABLE fac.Limit ENABLE TRIGGER TR_Limit_ApprovedFrozen;" >/dev/null
rc_on=0; deployed_check >/dev/null || rc_on=$?
if [ "$rc_off" -eq 1 ] && grep -q '^DIFF disabled policies .*deployed=    1' <<< "$off" \
   && grep -q '^DIFF disabled triggers .*deployed=    1' <<< "$off" && [ "$rc_on" -eq 0 ]; then
    echo "PASS MN4: the post-deployment check finds a disabled security policy and a disabled trigger, and passes once they are enabled again"
else
    echo "FAIL MN4: with the policy and the trigger off exit $rc_off [$(grep 'disabled' <<< "$off" | tr '\n' ' ')], after enabling exit $rc_on"
fi

# MN5: a right added by hand stops the next provisioning: a row right in BankFas (50131), a server role or a broader
# server right (50130), another msdb table (50132). Each is removed again after its run.
codes=""
try() {   # grant, revoke, expected error
    sa_run "$1" >/dev/null
    if provision; then codes="$codes ok"; else codes="$codes $(grep -o 'Msg 501[0-9][0-9]' "$TMP/provision.out" | head -n 1 | cut -c5-)"; fi
    sa_run "$2" >/dev/null
}
try "USE [BankFas]; GRANT SELECT ON plat.Tenant TO [bankfas_monitor];" "USE [BankFas]; REVOKE SELECT ON plat.Tenant FROM [bankfas_monitor];"
try "USE [BankFas]; ALTER ROLE [tp_readonly] ADD MEMBER [bankfas_monitor];" "USE [BankFas]; ALTER ROLE [tp_readonly] DROP MEMBER [bankfas_monitor];"
try "ALTER SERVER ROLE [processadmin] ADD MEMBER [bankfas_monitor];" "ALTER SERVER ROLE [processadmin] DROP MEMBER [bankfas_monitor];"
try "GRANT VIEW SERVER STATE TO [bankfas_monitor];" "REVOKE VIEW SERVER STATE FROM [bankfas_monitor];"
try "USE [msdb]; GRANT SELECT ON dbo.sysjobs TO [bankfas_monitor];" "USE [msdb]; REVOKE SELECT ON dbo.sysjobs FROM [bankfas_monitor];"
clean=0; provision || clean=$?
if [ "$codes" = " 50131 50131 50130 50130 50132" ] && [ "$clean" -eq 0 ] && [ "$(sa_run "$rights")" = "$want" ]; then
    echo "PASS MN5: a row right, a role, a server role, a broader server right or another msdb table stops the provisioning (50131, 50130, 50132)"
else
    echo "FAIL MN5: errors [$codes] (expected [ 50131 50131 50130 50130 50132]), clean run exit $clean"; cat "$TMP/provision.out"; echo
fi

# MN6: a new secret rotates the login: the old one is refused, the new one connects, and the rights stay the same.
old="$(secret)"
mv "$SEC/bankfas_monitor.secret" "$TMP/old.secret"
rot=0
SQLCMDPASSWORD="$SA_PW" SQL_USER=sa BANKFAS_SECRETS_DIR="$SEC" BANKFAS_CHANGE_REF=CI-monitor \
    bash "$ROOT/tools/deploy/provision_monitor.sh" --generate > "$TMP/provision.out" 2>&1 || rot=$?
with_old="$(as_monitor "SELECT 1;" "$old" || true)"
with_new="$(as_monitor "SET NOCOUNT ON; SELECT SUSER_SNAME();" | tail -n 1 || true)"
if [ "$rot" -eq 0 ] && [ "$(secret)" != "$old" ] && grep -q "Login failed" <<< "$with_old" && [ "$with_new" = "bankfas_monitor" ] \
   && [ "$(sa_run "$rights")" = "$want" ]; then
    echo "PASS MN6: a new secret rotates the monitoring login; the old one is refused and the rights are unchanged"
else
    echo "FAIL MN6: rotation exit $rot, old secret [$with_old], new secret [$with_new]"; cat "$TMP/provision.out"; echo
fi

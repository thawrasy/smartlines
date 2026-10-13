#!/usr/bin/env bash
# SQL Server Audit (tools/deploy/server_audit.sh, db/ops/server_audit.sql, db/ops/server_audit_alerts.sql; ADR 0012,
# DOC-S08 section 10, DOC-S12 section 3.5): the audit is in place and a second apply changes nothing; the deployment of
# step 4 is recorded inside its window and raises no alert; a service login is recorded only when it fails; dbo and
# sysadmin are recorded on the audit tables; each AL-18 rule fires outside a window; a reader needs no administrator;
# a stopped audit is alerted and restarted. Prints PASS or FAIL lines like the .sql tests. The logins and the
# database it creates are dropped at the end.
#
# Environment: SQLCMDPASSWORD (sa), SQL_SERVER (default localhost,1433), SQLCMD (default sqlcmd),
#              BANKFAS_AUDIT_DIR (default /var/opt/mssql/audit), AUDIT_SINCE (the server's UTC time before step 4),
#              MIGRATOR_SECRET (the file of the deployment login's secret from step 4)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
SA_PW="${SQLCMDPASSWORD:?set SQLCMDPASSWORD to the sa password}"
DIR="${BANKFAS_AUDIT_DIR:-/var/opt/mssql/audit}"
DEPLOYED="${AUDIT_SINCE:?set AUDIT_SINCE to the time step 4 started}"
MIGRATOR_SECRET="${MIGRATOR_SECRET:?set MIGRATOR_SECRET to the secret file of bankfas_migrator}"
export SQL_SERVER SQLCMD
TMP="$(mktemp -d)"
SEC="$TMP/secrets"
mkdir -m 700 "$SEC"
trap 'rm -rf "$TMP"' EXIT
READER_PW="Rd-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-30)9a"
BG_PW="Bg-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-30)9a"

sa_run() { printf '%s\n' "$1" > "$TMP/sa.sql"; SQLCMDPASSWORD="$SA_PW" "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -h -1 -W -i "$TMP/sa.sql"; }
as_login() {   # login, secret, statement; fails when the login fails
    printf '%s\n' "$3" > "$TMP/login.sql"
    SQLCMDPASSWORD="$2" "$SQLCMD" -S "$SQL_SERVER" -U "$1" -C -I -b -h -1 -W -i "$TMP/login.sql" 2>/dev/null
}
audit() {   # ADIR replaces the audit folder for one call
    SQLCMDPASSWORD="$SA_PW" SQL_USER=sa BANKFAS_AUDIT_DIR="${ADIR:-$DIR}" BANKFAS_CHANGE_REF=CI-audit bash "$ROOT/tools/deploy/server_audit.sh" "$@"
}
reader() { SQLCMDPASSWORD="$READER_PW" SQL_USER=ci_audit_reader BANKFAS_AUDIT_DIR="$DIR" bash "$ROOT/tools/deploy/server_audit.sh" "$@"; }
now() { sa_run "SET NOCOUNT ON; SELECT CONVERT(VARCHAR(27), SYSUTCDATETIME(), 126);"; }   # to the 100 ns: what the case before did in the same second stays out
written() { sleep 3; }   # the audit writes within a second (QUEUE_DELAY = 1000); a slow runner gets more
records() {   # since, condition on sys.fn_get_audit_file: the number of records
    sa_run "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.fn_get_audit_file(N'$DIR/BankFas_Audit_*.sqlaudit', DEFAULT, DEFAULT)
            WHERE event_time >= '$1' AND ($2);"
}
alerts() { audit alerts "$1" > "$TMP/alerts.out" 2>&1 || true; }   # exit code 3 when there are alerts
rules() { grep -v '^rule|\|^AL-18 alerts' "$TMP/alerts.out" | cut -d'|' -f1 | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'; }
act() { sa_run "$1" > "$TMP/act.out" 2>&1 || true; }   # the actions of a case; their output is shown when it fails
cleanup_sql="SET NOCOUNT ON;
IF DB_ID(N'BankFasAuditProbe') IS NOT NULL DROP DATABASE [BankFasAuditProbe];
IF SUSER_ID(N'breakglass') IS NOT NULL DROP LOGIN [breakglass];
IF EXISTS (SELECT 1 FROM BankFas.sys.database_principals WHERE name = N'ci_audit_reader') EXEC (N'USE [BankFas]; DROP USER [ci_audit_reader];');
IF SUSER_ID(N'ci_audit_reader') IS NOT NULL DROP LOGIN [ci_audit_reader];
IF EXISTS (SELECT 1 FROM BankFas.sys.database_principals WHERE name = N'ci_audit_probe') EXEC (N'USE [BankFas]; DROP ROLE [ci_audit_probe];');
USE [BankFas];
DECLARE @n SYSNAME, @sql NVARCHAR(300);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.database_principals WHERE name LIKE N'bankfas[_]%[_][ab]' AND type = 'S';
OPEN c; FETCH NEXT FROM c INTO @n;
WHILE @@FETCH_STATUS = 0 BEGIN SET @sql = N'DROP USER ' + QUOTENAME(@n); EXEC sys.sp_executesql @sql; FETCH NEXT FROM c INTO @n; END;
CLOSE c; DEALLOCATE c;
DECLARE l CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.server_principals WHERE name LIKE N'bankfas[_]%[_][ab]' AND type = 'S';
OPEN l; FETCH NEXT FROM l INTO @n;
WHILE @@FETCH_STATUS = 0 BEGIN SET @sql = N'DROP LOGIN ' + QUOTENAME(@n); EXEC master.sys.sp_executesql @sql; FETCH NEXT FROM l INTO @n; END;
CLOSE l; DEALLOCATE l;"
sa_run "$cleanup_sql" >/dev/null

# SA1: the audit, its server specification and its database specification are in place and writing; a second apply
# changes nothing; the predicate leaves out the successful logins of the eight service logins only; a missing folder
# stops apply.
second="$(audit apply 2>&1 || true)"
checked="$(audit check 2>&1 || true)"
missing="$(ADIR=/var/opt/mssql/no-such-audit-folder audit apply 2>&1 || true)"
svc_in_pred="$(sa_run "SET NOCOUNT ON; DECLARE @p NVARCHAR(MAX) = (SELECT predicate FROM sys.server_audits WHERE name = N'BankFas_Audit');
    SELECT COUNT(*) FROM (VALUES (N'app'), (N'jobs'), (N'platform'), (N'support')) AS p(n) CROSS JOIN (VALUES (N'a'), (N'b')) AS s(x)
    WHERE @p LIKE N'%[[]server_principal_name]=''bankfas[_]' + p.n + N'[_]' + s.x + N'''%'
      AND (LEN(@p) - LEN(REPLACE(@p, N'[server_principal_name]=', N''))) / LEN(N'[server_principal_name]=') = 8;")"
groups="$(sa_run "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.server_audit_specification_details AS d
                  JOIN sys.server_audit_specifications AS s ON s.server_specification_id = d.server_specification_id
                  WHERE s.name = N'BankFas_Audit_Server';")"
if [ "$second" = "server audit BankFas_Audit: unchanged; server specification BankFas_Audit_Server: unchanged; database specification BankFas_Audit_Database: unchanged" ] \
   && [[ "$checked" == "audit in place and writing"* ]] && [[ "$missing" == *"Msg 50120"* ]] \
   && [ "$svc_in_pred" -eq 8 ] && [ "$groups" -eq 23 ]; then
    echo "PASS SA1: the audit is in place and writing with 23 groups and 8 audited actions, a second apply changes nothing, a missing folder stops it"
else
    echo "FAIL SA1: second apply [$second], check [$checked], missing folder [$missing], service logins in the predicate $svc_in_pred, groups $groups"
fi

# SA2: step 4 is recorded inside its declared window: the window opened and closed, the deployment login connected and
# created the schema; its work raises no alert, and only its refused login after the close does.
windows="$(audit windows "$DEPLOYED" 2>&1 || true)"
mig_login=$(records "$DEPLOYED" "action_id = 'LGIS' AND server_principal_name = N'bankfas_migrator'")
mig_tables=$(records "$DEPLOYED" "action_id = 'CR' AND class_type = 'U' AND server_principal_name = N'bankfas_migrator' AND database_name = N'BankFas'")
alerts "$DEPLOYED"
mig_alerts="$(grep '|bankfas_migrator|' "$TMP/alerts.out" | cut -d'|' -f1,3 | sort | uniq -c | tr -s ' ' | sed 's/^ //' | tr '\n' ';' || true)"
if grep -q '^DEPLOYMENT|.*|closed|sa|BankFas deployment window opened; change CI$' <<< "$windows" \
   && grep -q '^CHANGE|.*|closed|sa|BankFas prepare_database prepare started; change CI$' <<< "$windows" \
   && [ "$mig_login" -ge 1 ] && [ "$mig_tables" -ge 150 ] && [[ "$mig_alerts" =~ ^[0-9]+\ MIGRATOR\|LGIF\;$ ]]; then
    echo "PASS SA2: the deployment is recorded inside its declared window ($mig_tables tables created by bankfas_migrator) and raises no alert; its refused login after the close does"
else
    echo "FAIL SA2: migrator logins $mig_login, tables $mig_tables, alerts on the migrator [$mig_alerts], windows:"; echo "$windows"
fi

# SA3: a service login provisioned inside its declared change raises no alert; its successful logins are not recorded,
# its failed login is; its DELETE on cfg.JobRun (the retention job) is recorded and raises no alert.
t3="$(now)"
if SQLCMDPASSWORD="$SA_PW" SQL_USER=sa BANKFAS_SECRETS_DIR="$SEC" BANKFAS_LOGIN_SET=a BANKFAS_CHANGE_REF=CI-audit \
       bash "$ROOT/tools/deploy/provision_logins.sh" --generate > "$TMP/provision.out" 2>&1; then
    jobs_pw="$(cat "$SEC/bankfas_jobs_a.secret")"
    as_login bankfas_jobs_a "$jobs_pw" "SELECT 1;" >/dev/null || true
    as_login bankfas_jobs_a "$jobs_pw" "USE [BankFas]; DELETE FROM cfg.JobRun WHERE 1 = 0;" >/dev/null || true
    as_login bankfas_jobs_a "wrong-$jobs_pw" "SELECT 1;" >/dev/null || true
    written
    ok_logins=$(records "$t3" "action_id = 'LGIS' AND server_principal_name = N'bankfas_jobs_a'")
    bad_logins=$(records "$t3" "action_id = 'LGIF' AND server_principal_name = N'bankfas_jobs_a'")
    deletes=$(records "$t3" "action_id = 'DL' AND object_name = N'JobRun' AND session_server_principal_name = N'bankfas_jobs_a'")
    members=$(records "$t3" "action_id = 'APRL' AND database_name = N'BankFas'")
    alerts "$t3"
    if [ "$ok_logins" -eq 0 ] && [ "$bad_logins" -ge 1 ] && [ "$deletes" -eq 1 ] && [ "$members" -ge 4 ] \
       && [ "$(rules)" = "" ]; then
        echo "PASS SA3: a service login is recorded only when it fails; its retention delete and its provisioning ($members role members) raise no alert"
    else
        echo "FAIL SA3: successful $ok_logins, failed $bad_logins, deletes $deletes, members $members, rules [$(rules)]"; cat "$TMP/alerts.out"
    fi
else cat "$TMP/provision.out"; echo "FAIL SA3: provisioning failed"; fi

# SA4: dbo and sysadmin are recorded on the audit tables (BY public), even for a statement that changes no row and is
# rolled back.
t4="$(now)"
act "SET NOCOUNT ON; USE [BankFas];
BEGIN TRAN;
DELETE FROM aud.AuditLog WHERE 1 = 0;
UPDATE aud.SensitiveAccessLog SET AccessKind = AccessKind WHERE 1 = 0;
UPDATE sec.KeyEvent SET EventType = EventType WHERE 1 = 0;
DELETE FROM sec.LoginAttempt WHERE 1 = 0;
ROLLBACK;"
written
alerts "$t4"
rows=$(grep -c '^AUDIT_ROWS|' "$TMP/alerts.out" || true)
if [ "$rows" -eq 4 ] && [ "$(rules)" = "AUDIT_ROWS" ]; then
    echo "PASS SA4: sysadmin, as dbo, is recorded and alerted on aud.AuditLog, aud.SensitiveAccessLog, sec.KeyEvent and sec.LoginAttempt"
else
    echo "FAIL SA4: $rows AUDIT_ROWS alerts, rules [$(rules)]"; cat "$TMP/act.out" "$TMP/alerts.out"
fi

# SA5: outside a window each privileged action raises its AL-18 rule; index and statistics maintenance does not.
t5="$(now)"
policy="$(sa_run "SET NOCOUNT ON; USE [BankFas]; SELECT TOP 1 QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(name) FROM sys.security_policies ORDER BY name;")"
policy="$(tail -n 1 <<< "$policy")"
act "SET NOCOUNT ON;
CREATE LOGIN [breakglass] WITH PASSWORD = N'$BG_PW', CHECK_POLICY = OFF;
ALTER LOGIN [breakglass] DISABLE;
ALTER LOGIN [sa] ENABLE;
ALTER LOGIN [bankfas_migrator] ENABLE;
CREATE LOGIN [ci_audit_reader] WITH PASSWORD = N'$READER_PW', CHECK_POLICY = OFF;
ALTER SERVER ROLE [processadmin] ADD MEMBER [ci_audit_reader];
ALTER SERVER ROLE [processadmin] DROP MEMBER [ci_audit_reader];
CREATE DATABASE [BankFasAuditProbe];
DROP DATABASE [BankFasAuditProbe];
USE [BankFas];
CREATE ROLE [ci_audit_probe];
GRANT SELECT ON plat.Tenant TO [ci_audit_probe];
REVOKE SELECT ON plat.Tenant FROM [ci_audit_probe];
DROP ROLE [ci_audit_probe];
ALTER SECURITY POLICY $policy WITH (STATE = ON);
ENABLE TRIGGER doc.TR_Document_SensitivityFloor ON doc.Document;
ALTER INDEX ALL ON cfg.JobRun REBUILD;
UPDATE STATISTICS cfg.JobRun;"
as_login breakglass "$BG_PW" "SELECT 1;" >/dev/null || true
as_login bankfas_migrator "$(cat "$MIGRATOR_SECRET")" "SELECT 1;" >/dev/null || true
sa_run "ALTER LOGIN [bankfas_migrator] DISABLE;" >/dev/null
written
alerts "$t5"
maintenance=$(grep -c '|ALTER INDEX\||UPDATE STATISTICS' "$TMP/alerts.out" || true)
expected="BREAKGLASS DROP_DB GRANT MIGRATOR SA SCHEMA SERVER_RIGHTS"
if [ "$(rules)" = "$expected" ] && [ "$maintenance" -eq 0 ] \
   && [ "$(grep -c '^MIGRATOR|' "$TMP/alerts.out")" -eq 2 ] && [ "$(grep -c '^GRANT|' "$TMP/alerts.out")" -ge 3 ]; then
    echo "PASS SA5: outside a window, breakglass, sa, the migrator, server roles, grants, policies, triggers and a dropped database each raise their alert; maintenance does not"
else
    echo "FAIL SA5: rules [$(rules)] (expected [$expected]), maintenance alerts $maintenance"; cat "$TMP/act.out" "$TMP/alerts.out"
fi

# SA6: a reader needs no administrator: VIEW SERVER SECURITY AUDIT alone reads the alerts and the windows;
# check needs VIEW SERVER SECURITY STATE, VIEW ANY SECURITY DEFINITION and, in BankFas, VIEW DEFINITION on the
# schemas of the audited tables, with no right on their rows. Without VIEW SERVER SECURITY AUDIT nothing is read.
before="$(reader alerts "$t5" 2>&1 || true)"
sa_run "SET NOCOUNT ON; GRANT VIEW SERVER SECURITY AUDIT TO [ci_audit_reader];" >/dev/null
read_alerts="$(reader alerts "$t5" 2>&1 | tail -n 1 || true)"
read_windows="$(reader windows "$DEPLOYED" 2>&1 | grep -c '^DEPLOYMENT|' || true)"
sa_run "SET NOCOUNT ON; GRANT VIEW SERVER SECURITY STATE, VIEW ANY SECURITY DEFINITION TO [ci_audit_reader];
USE [BankFas]; CREATE USER [ci_audit_reader] FOR LOGIN [ci_audit_reader];
GRANT VIEW DEFINITION ON SCHEMA::aud TO [ci_audit_reader]; GRANT VIEW DEFINITION ON SCHEMA::sec TO [ci_audit_reader];
GRANT VIEW DEFINITION ON SCHEMA::cfg TO [ci_audit_reader];" >/dev/null
read_check="$(reader check 2>&1 || true)"
read_rows="$(as_login ci_audit_reader "$READER_PW" "SET NOCOUNT ON; USE [BankFas]; SELECT COUNT(*) FROM aud.AuditLog;" || echo refused)"
if [[ "$before" == *"permission"* ]] && [[ "$before" != *"AL-18 alerts since"* ]] && [[ "$read_alerts" == "AL-18 alerts since"* ]] \
   && [ "$read_windows" -ge 1 ] && [[ "$read_check" == "audit in place and writing"* ]] && [[ "$read_rows" == *"Msg 229"*refused ]]; then
    echo "PASS SA6: a reader with view permissions only reads the alerts, the windows and the check, and no audit row"
else
    echo "FAIL SA6: without the permission [$before], alerts [$read_alerts], windows $read_windows, check [$read_check], rows [$read_rows]"
fi

# SA7: a stopped audit is alerted (AUDIT_STOP, and AUDIT outside a window), check fails while it is stopped, and apply
# starts it again.
t7="$(now)"
act "ALTER SERVER AUDIT [BankFas_Audit] WITH (STATE = OFF);"
stopped="$(audit check 2>&1 || true)"
restarted="$(audit apply 2>&1 || true)"
written
alerts "$t7"
if [[ "$stopped" == *"Msg 50121"*"not started"* ]] && [[ "$restarted" == "server audit BankFas_Audit: started;"* ]] \
   && [ "$(rules)" = "AUDIT AUDIT_STOP" ] && [[ "$(audit check 2>&1 || true)" == "audit in place and writing"* ]]; then
    echo "PASS SA7: stopping the audit is alerted, check fails while it is stopped, and apply starts it again"
else
    echo "FAIL SA7: check while stopped [$stopped], apply [$restarted], rules [$(rules)]"; cat "$TMP/alerts.out"
fi

sa_run "$cleanup_sql" >/dev/null

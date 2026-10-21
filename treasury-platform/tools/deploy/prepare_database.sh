#!/usr/bin/env bash
# The database administrator's part of a deployment (DOC-S11 sections 5 and 6.1, DOC-S08; docs/adr/0010-deployment-as-db-owner.md).
#   prepare [--generate]  once per server: the empty BankFas database, its owner login bankfas_owner (disabled, no
#                         known password) and the deployment login bankfas_migrator in db_owner, left disabled.
#                         Its secret is BANKFAS_SECRETS_DIR/bankfas_migrator.secret (owned by the caller, mode 600 or
#                         400, 32 to 128 characters of [A-Za-z0-9_-] with upper, lower and digit; --generate makes it).
#                         BANKFAS_DATA_DIR and BANKFAS_LOG_DIR place the files of a new database (DOC-S10 section 3).
#   open                  opens a deployment window: checks that the server audit runs (50151), that no service login
#                         has a session (50152), and that a database holding tables has a full backup within
#                         BANKFAS_BACKUP_MAX_AGE_HOURS, default 24 (50153); declares the window in SQL Server Audit
#                         and enables bankfas_migrator (internal review v6, D7, D14).
#   close                 disables it again, ends its sessions and declares the window closed.
# A deployment (DOC-S11): server_audit.sh apply (first time) -> prepare (first time) -> open
#               -> SQL_USER=bankfas_migrator tools/deploy/deploy.sh -> server_audit.sh apply -> provision_logins.sh -> close.
# Each run declares itself in the audit with BANKFAS_CHANGE_REF (audit_declare.sh): prepare as an administrative
# change, open and close as the deployment window. The alerts on the migrator, grants and schema changes fire only
# outside a declared window (db/ops/server_audit_alerts.sql, docs/adr/0012-server-audit.md).
# Run with an administrator's own login (SQL_USER and SQLCMDPASSWORD): sa is refused outside CI (50144, preflight.sh),
# and so is -C (DQ-S11-6). The secret goes
# to sqlcmd in a private temporary copy of db/ops/prepare_database.sql, never on a command line.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$(cd "$HERE/../../db/ops" && pwd)/prepare_database.sql"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-sa}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS-}"
ACTION="${1:-}"
GENERATE=0
[ "${2:-}" = "--generate" ] && GENERATE=1

fail() { echo "prepare_database: $*" >&2; exit 1; }
# shellcheck source=tools/deploy/audit_declare.sh
. "$HERE/audit_declare.sh"
# shellcheck source=tools/deploy/preflight.sh
. "$HERE/preflight.sh"
if [ -n "$SQL_USER" ]; then
    : "${SQLCMDPASSWORD:?set SQLCMDPASSWORD for the login $SQL_USER}"
    AUTH=(-U "$SQL_USER")
else
    AUTH=(-E)
fi
WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
run() { ( umask 077; { sa_guard_sql; printf '%s\n' "$1"; } > "$WORK/stmt.sql" ); "$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -I -b $SQLCMD_OPTS -i "$WORK/stmt.sql"; }

strong() { [[ "$1" =~ ^[A-Za-z0-9_-]{32,128}$ && "$1" =~ [A-Z] && "$1" =~ [a-z] && "$1" =~ [0-9] ]]; }
new_secret() {
    local s
    while :; do
        s="$(head -c 64 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' | cut -c1-48)"
        if strong "$s"; then printf '%s' "$s"; return; fi
    done
}

case "$ACTION" in
prepare)
    DIR="${BANKFAS_SECRETS_DIR:?set BANKFAS_SECRETS_DIR to the folder of the secret files}"
    [ -d "$DIR" ] || fail "no folder $DIR"
    file="$DIR/bankfas_migrator.secret"
    if [ ! -e "$file" ]; then
        [ "$GENERATE" -eq 1 ] || fail "no secret file $file (use --generate to create it)"
        ( umask 077; new_secret > "$file" )
    fi
    [ "$(stat -c '%u' "$file")" = "$(id -u)" ] || fail "$file is not owned by the caller"
    case "$(stat -c '%a' "$file")" in 600|400) ;; *) fail "$file must have mode 600 or 400" ;; esac
    secret="$(head -n 1 "$file" | tr -d '\r\n')"
    strong "$secret" || fail "$file: the secret must be 32 to 128 characters of [A-Za-z0-9_-] with upper, lower and digit"
    data="${BANKFAS_DATA_DIR:-}"; log="${BANKFAS_LOG_DIR:-}"
    for d in "$data" "$log"; do
        [ -z "$d" ] || [[ "$d" =~ ^/[A-Za-z0-9/_.-]+$ ]] || fail "data and log folders must be absolute paths of [A-Za-z0-9/_.-]"
    done
    { [ -z "$data" ] && [ -z "$log" ]; } || { [ -n "$data" ] && [ -n "$log" ]; } || fail "set both BANKFAS_DATA_DIR and BANKFAS_LOG_DIR, or neither"
    sql="$(cat "$TEMPLATE")"
    sql="${sql//\$(BANKFAS_MIGRATOR_PASSWORD)/$secret}"
    sql="${sql//\$(BANKFAS_DATA_DIR)/$data}"
    sql="${sql//\$(BANKFAS_LOG_DIR)/$log}"
    # The end of the change is declared even when the run fails, so the window never outlives the run.
    rc=0
    run "$(declare_sql 1103 "prepare_database prepare started")
$sql" || rc=$?
    run "$(declare_sql 1104 "prepare_database prepare finished")" >/dev/null || true
    exit "$rc"
    ;;
open)
    # A window opens only when it can be audited and the database can be put back (internal review v6, D7, D14): the
    # server audit is running, no service login has a session (the application and the job worker are stopped), and a
    # database that holds tables (an upgrade through migrate.sh) has a full backup within BANKFAS_BACKUP_MAX_AGE_HOURS.
    max_age="${BANKFAS_BACKUP_MAX_AGE_HOURS:-24}"
    [[ "$max_age" =~ ^[0-9]{1,4}$ ]] || fail "BANKFAS_BACKUP_MAX_AGE_HOURS is a number of hours"
    run "SET NOCOUNT ON;
DECLARE @msg NVARCHAR(2048), @tables INT = 0, @who NVARCHAR(1000);
IF NOT EXISTS (SELECT 1 FROM sys.dm_server_audit_status WHERE name = N'BankFas_Audit' AND status_desc = N'STARTED')
    THROW 50151, 'The server audit BankFas_Audit is not running: a deployment window opens only when it is recorded (server_audit.sh apply)', 1;
SET @who = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(login_name, N' (', session_id, N')')), N', ') FROM sys.dm_exec_sessions
            WHERE login_name LIKE N'bankfas[_]app[_]%' OR login_name LIKE N'bankfas[_]jobs[_]%'
               OR login_name LIKE N'bankfas[_]platform[_]%' OR login_name LIKE N'bankfas[_]support[_]%');
IF @who IS NOT NULL
BEGIN
    SET @msg = CONCAT(N'Stop the application, the job worker and the operator panel before the window: sessions of ', @who);
    THROW 50152, @msg, 1;
END;
IF DB_ID(N'BankFas') IS NOT NULL
    EXEC [BankFas].sys.sp_executesql N'SELECT @n = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0', N'@n INT OUTPUT', @n = @tables OUTPUT;
IF @tables > 0 AND NOT EXISTS (SELECT 1 FROM msdb.dbo.backupset WHERE database_name = N'BankFas' AND type = 'D'
                                   AND backup_finish_date >= DATEADD(HOUR, -$max_age, GETDATE()))
    THROW 50153, 'BankFas holds tables and has no full backup within BANKFAS_BACKUP_MAX_AGE_HOURS: back it up before an upgrade (DOC-S09)', 1;
GO
$(declare_sql 1101 "deployment window opened")
ALTER LOGIN [bankfas_migrator] ENABLE;"
    echo "deployment window open: bankfas_migrator enabled"
    ;;
close)
    # The login is disabled first, so no session starts after it; a session that ends by itself between the list
    # and its KILL is no error (self-review E3). The close is declared even when a step fails, so the window never
    # outlives the run, and the run fails when a session of the deployment login is left.
    rc=0
    run "SET NOCOUNT ON;
ALTER LOGIN [bankfas_migrator] DISABLE;
DECLARE @s INT, @sql NVARCHAR(40);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT session_id FROM sys.dm_exec_sessions WHERE login_name = N'bankfas_migrator';
OPEN c; FETCH NEXT FROM c INTO @s;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = CONCAT(N'KILL ', @s);
    BEGIN TRY EXEC (@sql); END TRY BEGIN CATCH IF ERROR_NUMBER() <> 6106 THROW; END CATCH;   -- 6106: the session has ended
    FETCH NEXT FROM c INTO @s;
END;
CLOSE c; DEALLOCATE c;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'bankfas_migrator' AND is_disabled = 0)
    THROW 50112, 'bankfas_migrator is still enabled after the close', 1;" || rc=$?
    run "$(declare_sql 1102 "deployment window closed")" >/dev/null || rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    echo "deployment window closed: bankfas_migrator disabled"
    ;;
*)
    fail "usage: prepare_database.sh prepare [--generate] | open | close"
    ;;
esac

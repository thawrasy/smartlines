#!/usr/bin/env bash
# The database administrator's part of a deployment (DOC-S11 sections 5 and 6.1, DOC-S08; docs/adr/0010-deployment-as-db-owner.md).
#   prepare [--generate]  once per server: the empty BankFas database, its owner login bankfas_owner (disabled, no
#                         known password) and the deployment login bankfas_migrator in db_owner, left disabled.
#                         Its secret is BANKFAS_SECRETS_DIR/bankfas_migrator.secret (owned by the caller, mode 600 or
#                         400, 32 to 128 characters of [A-Za-z0-9_-] with upper, lower and digit; --generate makes it).
#                         BANKFAS_DATA_DIR and BANKFAS_LOG_DIR place the files of a new database (DOC-S10 section 3).
#   open                  enables bankfas_migrator for a deployment window.
#   close                 disables it again and ends its sessions.
# A deployment: prepare (first time) -> open -> SQL_USER=bankfas_migrator tools/deploy/deploy.sh -> close
#               -> tools/deploy/provision_logins.sh.
# Run with an administrator's own login (SQL_USER and SQLCMDPASSWORD), as for tools/deploy/deploy.sh. The secret goes
# to sqlcmd in a private temporary copy of db/ops/prepare_database.sql, never on a command line.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$(cd "$HERE/../../db/ops" && pwd)/prepare_database.sql"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-sa}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS--C}"
ACTION="${1:-}"
GENERATE=0
[ "${2:-}" = "--generate" ] && GENERATE=1

fail() { echo "prepare_database: $*" >&2; exit 1; }
if [ -n "$SQL_USER" ]; then
    : "${SQLCMDPASSWORD:?set SQLCMDPASSWORD for the login $SQL_USER}"
    AUTH=(-U "$SQL_USER")
else
    AUTH=(-E)
fi
WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
run() { ( umask 077; printf '%s\n' "$1" > "$WORK/stmt.sql" ); "$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -I -b $SQLCMD_OPTS -i "$WORK/stmt.sql"; }

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
    run "$sql"
    ;;
open)
    run "ALTER LOGIN [bankfas_migrator] ENABLE;"
    echo "deployment window open: bankfas_migrator enabled"
    ;;
close)
    run "SET NOCOUNT ON;
ALTER LOGIN [bankfas_migrator] DISABLE;
DECLARE @s INT, @sql NVARCHAR(40);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT session_id FROM sys.dm_exec_sessions WHERE login_name = N'bankfas_migrator';
OPEN c; FETCH NEXT FROM c INTO @s;
WHILE @@FETCH_STATUS = 0 BEGIN SET @sql = CONCAT(N'KILL ', @s); EXEC (@sql); FETCH NEXT FROM c INTO @s; END;
CLOSE c; DEALLOCATE c;"
    echo "deployment window closed: bankfas_migrator disabled"
    ;;
*)
    fail "usage: prepare_database.sh prepare [--generate] | open | close"
    ;;
esac

#!/usr/bin/env bash
# Creates or updates the monitoring login bankfas_monitor (DQ-S12-6; db/ops/monitor_login.sql;
# docs/adr/0013-monitor-login-and-deployment-checks.md): server and database state and definitions, the audit files
# and the backup history, and no row of any table. The monitoring agent, tools/deploy/server_audit.sh check and alerts,
# and tools/dbgen/check_deployed.py run with it.
# Run it after tools/deploy/deploy.sh, inside the deployment window, with an administrator's own login. Running it
# again with a new secret rotates it (DOC-S08 section 6). It declares itself in SQL Server Audit as an administrative
# change with BANKFAS_CHANGE_REF (audit_declare.sh).
#
# Secret: BANKFAS_SECRETS_DIR/bankfas_monitor.secret, owned by the caller, mode 0600 or 0400, one line of 32 to 128
# characters from [A-Za-z0-9_-] with an upper-case letter, a lower-case letter and a digit. --generate creates a
# missing file from /dev/urandom. The monitoring agent reads the same secret from its own store (DOC-S08 section 5).
# The secret reaches sqlcmd in a private temporary copy of the template, never on a command line.
#
# Usage: BANKFAS_SECRETS_DIR=/etc/bankfas/db-secrets tools/deploy/provision_monitor.sh [--generate]
# Environment: SQL_SERVER, SQL_USER, SQLCMDPASSWORD, SQLCMD and SQLCMD_OPTS as for tools/deploy/deploy.sh; sa and -C
# are refused outside CI (tools/deploy/preflight.sh, DQ-S11-6).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$(cd "$HERE/../../db/ops" && pwd)/monitor_login.sql"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-sa}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS-}"
DIR="${BANKFAS_SECRETS_DIR:?set BANKFAS_SECRETS_DIR to the folder of the secret files}"
GENERATE=0
[ "${1:-}" = "--generate" ] && GENERATE=1

fail() { echo "provision_monitor: $*" >&2; exit 1; }
# shellcheck source=tools/deploy/audit_declare.sh
. "$HERE/audit_declare.sh"
# shellcheck source=tools/deploy/preflight.sh
. "$HERE/preflight.sh"
[ -d "$DIR" ] || fail "no folder $DIR"
if [ -n "$SQL_USER" ]; then
    : "${SQLCMDPASSWORD:?set SQLCMDPASSWORD for the login $SQL_USER}"
    AUTH=(-U "$SQL_USER")
else
    AUTH=(-E)
fi

strong() {   # 32 to 128 characters of [A-Za-z0-9_-], with upper, lower and digit (SQL Server's CHECK_POLICY)
    [[ "$1" =~ ^[A-Za-z0-9_-]{32,128}$ && "$1" =~ [A-Z] && "$1" =~ [a-z] && "$1" =~ [0-9] ]]
}
new_secret() {
    local s
    while :; do
        s="$(head -c 64 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' | cut -c1-48)"
        if strong "$s"; then printf '%s' "$s"; return; fi
    done
}
file="$DIR/bankfas_monitor.secret"
if [ ! -e "$file" ]; then
    [ "$GENERATE" -eq 1 ] || fail "no secret file $file (use --generate to create it)"
    ( umask 077; new_secret > "$file" )
fi
[ "$(stat -c '%u' "$file")" = "$(id -u)" ] || fail "$file is not owned by the caller"
case "$(stat -c '%a' "$file")" in 600|400) ;; *) fail "$file must have mode 600 or 400" ;; esac
secret="$(head -n 1 "$file" | tr -d '\r\n')"
strong "$secret" || fail "$file: the secret must be 32 to 128 characters of [A-Za-z0-9_-] with upper, lower and digit"

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
sql="$(cat "$TEMPLATE")"
sql="${sql//\$(BANKFAS_MONITOR_PASSWORD)/$secret}"
( umask 077; { sa_guard_sql; declare_sql 1103 "provision_monitor started"; printf '%s\n' "$sql"; } > "$WORK/monitor_login.sql" )
declare_sql 1104 "provision_monitor finished" > "$WORK/end.sql"
# The end of the change is declared even when the run fails, so the window never outlives the run.
rc=0
"$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -I -b $SQLCMD_OPTS -i "$WORK/monitor_login.sql" || rc=$?
"$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -I -b $SQLCMD_OPTS -i "$WORK/end.sql" >/dev/null || true
exit "$rc"

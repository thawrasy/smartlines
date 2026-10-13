#!/usr/bin/env bash
# Creates or updates the SQL logins of the service processes and maps each to its database role (DOC-S08 section 3,
# DQ-S08-1; docs/adr/0009-service-logins.md):
#     bankfas_app_<set> -> tp_app, bankfas_jobs_<set> -> tp_jobs, bankfas_platform_<set> -> tp_platform,
#     bankfas_support_<set> -> tp_support
# Run it after tools/deploy/deploy.sh, with the same deploying login. <set> is a or b, the two accounts of each pair
# used to rotate a secret without downtime (DOC-S08 section 6).
#
# Secrets: one file per login in BANKFAS_SECRETS_DIR, named <login>.secret (bankfas_app_a.secret, ...). Each file is
# owned by the caller, has mode 0600 or 0400, and holds one line of 32 to 128 characters from [A-Za-z0-9_-] with an
# upper-case letter, a lower-case letter and a digit. With --generate, a missing file is created from /dev/urandom.
# The process that uses a login reads the same secret from its own secret store (DOC-S08 section 5).
# The secrets reach sqlcmd in a private temporary copy of db/ops/service_logins.sql, deleted at the end, never on a
# command line or in the environment.
#
# Usage: BANKFAS_SECRETS_DIR=/etc/bankfas/db-secrets [BANKFAS_LOGIN_SET=a] tools/deploy/provision_logins.sh [--generate]
# Environment: SQL_SERVER, SQL_USER, SQLCMDPASSWORD, SQLCMD and SQLCMD_OPTS as for tools/deploy/deploy.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$(cd "$HERE/../../db/ops" && pwd)/service_logins.sql"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-sa}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS--C}"
SET="${BANKFAS_LOGIN_SET:-a}"
DIR="${BANKFAS_SECRETS_DIR:?set BANKFAS_SECRETS_DIR to the folder of the secret files}"
GENERATE=0
[ "${1:-}" = "--generate" ] && GENERATE=1

fail() { echo "provision_logins: $*" >&2; exit 1; }
case "$SET" in a|b) ;; *) fail "BANKFAS_LOGIN_SET must be a or b" ;; esac
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
read_secret() {   # prints the secret of one login after checking its file
    local file="$DIR/$1.secret" mode owner value
    if [ ! -e "$file" ]; then
        [ "$GENERATE" -eq 1 ] || fail "no secret file $file (use --generate to create it)"
        ( umask 077; new_secret > "$file" )
    fi
    mode="$(stat -c '%a' "$file")"; owner="$(stat -c '%u' "$file")"
    [ "$owner" = "$(id -u)" ] || fail "$file is not owned by the caller"
    case "$mode" in 600|400) ;; *) fail "$file has mode $mode; use 600 or 400" ;; esac
    value="$(head -n 1 "$file" | tr -d '\r\n')"
    strong "$value" || fail "$file: the secret must be 32 to 128 characters of [A-Za-z0-9_-] with upper, lower and digit"
    printf '%s' "$value"
}

APP="$(read_secret "bankfas_app_$SET")"
JOBS="$(read_secret "bankfas_jobs_$SET")"
PLATFORM="$(read_secret "bankfas_platform_$SET")"
SUPPORT="$(read_secret "bankfas_support_$SET")"

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
sql="$(cat "$TEMPLATE")"
sql="${sql//\$(BANKFAS_LOGIN_SET)/$SET}"
sql="${sql//\$(BANKFAS_APP_PASSWORD)/$APP}"
sql="${sql//\$(BANKFAS_JOBS_PASSWORD)/$JOBS}"
sql="${sql//\$(BANKFAS_PLATFORM_PASSWORD)/$PLATFORM}"
sql="${sql//\$(BANKFAS_SUPPORT_PASSWORD)/$SUPPORT}"
( umask 077; printf '%s\n' "$sql" > "$WORK/service_logins.sql" )

"$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -I -b $SQLCMD_OPTS -i "$WORK/service_logins.sql"
echo "service logins of set $SET provisioned"

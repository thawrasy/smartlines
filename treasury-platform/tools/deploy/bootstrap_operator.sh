#!/usr/bin/env bash
# The first operator administrator of a new platform (ADR 0004, DQ-F07-3; docs/54 step D-10): plat.usp_BootstrapOperator
# creates them once, as an invitation, so no password is ever in a script. Run it once, after deploy.sh, inside the
# deployment window, as the deployment login bankfas_migrator (db_owner; the procedure is granted to nobody else).
# The link token is 32 random bytes; it reaches sqlcmd in a private temporary file, never on a command line, the
# database keeps only its SHA-256, and the link is shown once on the terminal: give it to the operator by a channel
# of its own (not the e-mail it names). It is valid for 48 hours; a second run is refused (50023).
#
# Usage: SQL_USER=bankfas_migrator SQLCMDPASSWORD=... BANKFAS_DOMAIN=<domain> tools/deploy/bootstrap_operator.sh <e-mail> <display name>
# BANKFAS_PANEL_URL gives the panel's address when it is not https://admin.<domain>: the private trial by address
# (docs/62) uses https://admin.localhost:8443, through the SSH tunnel.
# Environment: SQL_SERVER, SQL_USER, SQLCMDPASSWORD, SQLCMD and SQLCMD_OPTS as for tools/deploy/deploy.sh; sa and -C
# are refused outside CI (tools/deploy/preflight.sh, DQ-S11-6).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-bankfas_migrator}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS-}"
DOMAIN="${BANKFAS_DOMAIN:?set BANKFAS_DOMAIN to the platform domain (the operator panel is admin.<domain>)}"
EMAIL="${1:?the operator administrator e-mail}"
NAME="${2:?the operator administrator display name}"

fail() { echo "bootstrap_operator: $*" >&2; exit 1; }
# shellcheck source=tools/deploy/preflight.sh
. "$HERE/preflight.sh"
[[ "$EMAIL" =~ ^[^[:space:]\'@]+@[^[:space:]\'@]+\.[^[:space:]\'@]+$ ]] || fail "the e-mail is not valid"
[[ "$NAME" != *"'"* && ${#NAME} -le 200 ]] || fail "the display name has a quote or is longer than 200 characters"
[[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || fail "BANKFAS_DOMAIN is a host name"
PANEL="${BANKFAS_PANEL_URL:-https://admin.$DOMAIN}"
[[ "$PANEL" =~ ^https://[a-z0-9.-]+(:[0-9]{2,5})?/?$ ]] || fail "BANKFAS_PANEL_URL is https://<host>[:port]"
if [ -n "$SQL_USER" ]; then
    : "${SQLCMDPASSWORD:?set SQLCMDPASSWORD for the login $SQL_USER}"
    AUTH=(-U "$SQL_USER")
else
    AUTH=(-E)
fi

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
( umask 077; head -c 32 /dev/urandom > "$WORK/token.bin" )
hex="$(od -An -tx1 -v "$WORK/token.bin" | tr -d ' \n')"
link_token="$(base64 -w0 < "$WORK/token.bin" | tr '+/' '-_' | tr -d '=')"
( umask 077; { sa_guard_sql; printf "SET NOCOUNT ON;\nEXEC plat.usp_BootstrapOperator @Email = N'%s', @DisplayName = N'%s', @Token = 0x%s;\nGO\n" \
    "$EMAIL" "$NAME" "$hex"; } > "$WORK/bootstrap.sql" )
"$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -d BankFas -I -b $SQLCMD_OPTS -i "$WORK/bootstrap.sql" > "$WORK/out" 2>&1 || {
    grep -q 50023 "$WORK/out" && fail "an operator already exists: an operator administrator invites the next ones from the panel"
    cat "$WORK/out" >&2; fail "the bootstrap failed"; }
echo "The first operator administrator is invited ($EMAIL). Their link, valid for 48 hours, shown this once:"
echo "  ${PANEL%/}/setup#token=$link_token"

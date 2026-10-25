#!/usr/bin/env bash
# Prepares the application host from /opt/bankfas/site.conf (docs/54 H-04, H-05, H-08; docs/55): the folders with
# their owners and modes, the master key (created once, never overwritten), api.env, worker.env, compose.yml and the
# Caddyfile written from the templates of tools/host, the database login secrets and the SMTP password put in place,
# and the DNS token of Caddy. Safe to run again: what exists is kept, what is written from site.conf is written again
# (the previous file kept as .bak). Run as root from treasury-platform/; it starts nothing.
#
# Usage: sudo tools/host/provision_app_host.sh [--db-secrets <tar from the database server>]
#             [--smtp-password-file <file>] [--dns-token-file <file>]
# Without the files it asks for the SMTP password and the DNS token on the terminal, unless they are already in place.
# BANKFAS_ROOT (default /) puts every path under another folder, for a dry run.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="${BANKFAS_ROOT:-}"; R="${R%/}"
SITE="${BANKFAS_SITE:-$R/opt/bankfas/site.conf}"
DB_SECRETS="" SMTP_FILE="" DNS_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --db-secrets) DB_SECRETS="$2"; shift 2 ;;
        --smtp-password-file) SMTP_FILE="$2"; shift 2 ;;
        --dns-token-file) DNS_FILE="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 1 ;;
    esac
done
fail() { echo "provision_app_host: $*" >&2; exit 1; }
step() { echo "== $*"; }
[ "$(id -u)" = 0 ] || fail "run it as root"
[ -f "$SITE" ] || fail "no $SITE: copy tools/host/site.conf.example there and fill it in"
[ "$(stat -c '%a' "$SITE")" = 600 ] || fail "$SITE must have mode 600"

# The values: KEY=VALUE lines only, never sourced as a script.
declare -A V
while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z_]+$ ]] || continue
    V[$k]="$v"
done < <(grep -E '^[A-Z_]+=' "$SITE")
for k in DOMAIN DB_HOST SMTP_HOST SMTP_PORT SMTP_FROM SMTP_USER OPS_MAILBOX SECURITY_MAILBOX DNS_PROVIDER DNS_TOKEN_VAR API_IMAGE WORKER_IMAGE CLAMAV_VERSION KEY_NAME; do
    [ -n "${V[$k]:-}" ] || fail "$k is empty in $SITE"
    [[ "${V[$k]}" =~ ^[A-Za-z0-9@._:/-]+$ ]] || fail "$k has a character outside [A-Za-z0-9@._:/-]"
done
[[ "${V[DOMAIN]}" != *example.com* ]] || fail "DOMAIN is still the example"
[[ "${V[SMTP_PORT]}" =~ ^[0-9]{2,5}$ ]] || fail "SMTP_PORT is a port number"
[[ "${V[KEY_NAME]}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "KEY_NAME is a file name"

render() {   # render <template> <target> <mode>: every <NAME> of the values replaced, the old target kept as .bak
    local src="$1" dst="$2" mode="$3" text k
    text="$(cat "$src")"
    for k in "${!V[@]}"; do text="${text//<$k>/${V[$k]}}"; done
    text="${text//<FROM_ADDRESS>/${V[SMTP_FROM]}}"
    text="${text//<REGISTRY>\/bankfas-api:<VERSION>/${V[API_IMAGE]}}"
    text="${text//<REGISTRY>\/bankfas-worker:<VERSION>/${V[WORKER_IMAGE]}}"
    text="${text//<DNS_TOKEN_ENV>/\{env.${V[DNS_TOKEN_VAR]}\}}"
    text="$(printf '%s\n' "$text" | sed -E "s/^Mail__Smtp__Port=.*/Mail__Smtp__Port=${V[SMTP_PORT]}/")"
    # Only the comments may keep a <...>; a value left unreplaced is a mistake.
    if printf '%s\n' "$text" | grep -v '^[[:space:]]*#' | sed 's/#.*//' | grep -qE '<[A-Z_]+>'; then
        fail "$(basename "$src") still has a placeholder after rendering: $(printf '%s\n' "$text" | grep -v '^[[:space:]]*#' | grep -oE '<[A-Z_]+>' | sort -u | tr '\n' ' ')"
    fi
    [ -f "$dst" ] && cp -p "$dst" "$dst.bak"
    ( umask 077; printf '%s\n' "$text" > "$dst.tmp" )
    chmod "$mode" "$dst.tmp"; mv "$dst.tmp" "$dst"
    echo "   wrote $dst"
}

step "folders"
install -d -m 700 "$R/opt/bankfas"
install -d -m 750 -o root -g 10001 "$R/opt/bankfas/secrets"
install -d -m 700 -o 10001 -g 10001 "$R/opt/bankfas/secrets/master-keys" "$R/opt/bankfas/secrets/db"
install -d -m 750 -o 10001 -g 10001 "$R/srv/bankfas/files" "$R/srv/bankfas/dataprotection"
install -d -m 755 "$R/srv/bankfas/breached"

step "master key"
key="$R/opt/bankfas/secrets/master-keys/${V[KEY_NAME]}.key"
if [ -e "$key" ]; then
    echo "   kept $key"
else
    ( umask 077; head -c 32 /dev/urandom | base64 > "$key" )
    chown 10001:10001 "$key"; chmod 400 "$key"
    echo "   created $key"
    echo "   COPY IT OFF THIS HOST NOW (docs/54 A-06): without it nothing encrypted opens again."
fi
echo "   fingerprint (compare with the offline copy): $(sha256sum "$key" | cut -c1-16)"

step "settings"
render "$HERE/api.env.example" "$R/opt/bankfas/api.env" 600
render "$HERE/worker.env.example" "$R/opt/bankfas/worker.env" 600
render "$HERE/compose.yml" "$R/opt/bankfas/compose.yml" 644
install -d -m 755 "$R/etc/caddy"
render "$HERE/Caddyfile" "$R/etc/caddy/Caddyfile" 644

step "database login secrets"
if [ -n "$DB_SECRETS" ]; then
    tar -C "$R/opt/bankfas/secrets/db" -xf "$DB_SECRETS" bankfas_app_a.secret bankfas_jobs_a.secret bankfas_platform_a.secret bankfas_support_a.secret
    shred -u "$DB_SECRETS" 2>/dev/null || rm -f "$DB_SECRETS"
    echo "   taken from the archive, which is deleted"
fi
for n in app jobs platform support; do
    f="$R/opt/bankfas/secrets/db/bankfas_${n}_a.secret"
    if [ -f "$f" ]; then chown 10001:10001 "$f"; chmod 400 "$f"; echo "   bankfas_${n}_a: in place"
    else echo "   bankfas_${n}_a: MISSING (docs/54 D-04, then --db-secrets)"; fi
done

step "SMTP password"
smtp="$R/opt/bankfas/secrets/smtp.secret"
if [ -n "$SMTP_FILE" ]; then ( umask 077; tr -d '\r\n' < "$SMTP_FILE" > "$smtp" ); shred -u "$SMTP_FILE" 2>/dev/null || true
elif [ ! -s "$smtp" ] && [ -t 0 ]; then read -rsp "   SMTP password for ${V[SMTP_USER]}: " p; echo; ( umask 077; printf '%s' "$p" > "$smtp" ); unset p; fi
if [ -s "$smtp" ]; then chown 10001:10001 "$smtp"; chmod 400 "$smtp"; echo "   in place"; else echo "   MISSING"; fi

step "DNS token of Caddy"
dns="$R/etc/caddy/dns.env"
if [ -n "$DNS_FILE" ]; then ( umask 077; printf '%s=%s\n' "${V[DNS_TOKEN_VAR]}" "$(tr -d '\r\n' < "$DNS_FILE")" > "$dns" ); shred -u "$DNS_FILE" 2>/dev/null || true
elif [ ! -s "$dns" ] && [ -t 0 ]; then read -rsp "   ${V[DNS_PROVIDER]} API token: " p; echo; ( umask 077; printf '%s=%s\n' "${V[DNS_TOKEN_VAR]}" "$p" > "$dns" ); unset p; fi
if [ -s "$dns" ]; then
    chmod 600 "$dns"
    install -d -m 755 "$R/etc/systemd/system/caddy.service.d"
    printf '[Service]\nEnvironmentFile=/etc/caddy/dns.env\n' > "$R/etc/systemd/system/caddy.service.d/dns.conf"
    echo "   in place (systemctl daemon-reload && systemctl restart caddy)"
else echo "   MISSING"; fi

echo "done: now tools/host/check_ready.sh"

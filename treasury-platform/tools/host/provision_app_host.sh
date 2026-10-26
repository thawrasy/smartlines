#!/usr/bin/env bash
# Prepares the application host from /opt/bankfas/site.conf (docs/54 H-04, H-05, H-08; docs/55): the folders with
# their owners and modes, the master key (created once, never overwritten), api.env, worker.env, compose.yml and the
# Caddyfile written from the templates of tools/host, the database login secrets and the SMTP password put in place,
# and the DNS token of Caddy. With ACCESS=ip (docs/62) it writes the trial by address instead: Caddyfile.ip, the
# portal of IP_TENANT on SERVER_IP, the operator panel on admin.localhost, the host's certificate authorities given to
# both containers, and the mail kept in /srv/bankfas/mail when SMTP_HOST is empty. Safe to run again: what exists is kept, what is written from site.conf is written again
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
ACCESS="${V[ACCESS]:-domain}"
[[ "$ACCESS" =~ ^(domain|ip)$ ]] || fail "ACCESS is domain or ip"
MAIL_KEPT=0
required=(DOMAIN DB_HOST OPS_MAILBOX SECURITY_MAILBOX API_IMAGE WORKER_IMAGE CLAMAV_VERSION KEY_NAME)
if [ "$ACCESS" = domain ]; then required+=(SMTP_HOST SMTP_PORT SMTP_FROM SMTP_USER DNS_PROVIDER DNS_TOKEN_VAR)
else
    required+=(SERVER_IP IP_TENANT)
    if [ -n "${V[SMTP_HOST]:-}" ]; then required+=(SMTP_PORT SMTP_FROM SMTP_USER); else MAIL_KEPT=1; V[SMTP_HOST]=none; V[SMTP_PORT]=587; V[SMTP_FROM]="${V[SMTP_FROM]:-no-reply@localhost}"; V[SMTP_USER]="${V[SMTP_USER]:-none}"; fi
fi
for k in "${required[@]}"; do
    [ -n "${V[$k]:-}" ] || fail "$k is empty in $SITE"
    [[ "${V[$k]}" =~ ^[A-Za-z0-9@._:/-]+$ ]] || fail "$k has a character outside [A-Za-z0-9@._:/-]"
done
[[ "${V[DOMAIN]}" != *example.com* ]] || fail "DOMAIN is still the example"
[[ "${V[SMTP_PORT]:-587}" =~ ^[0-9]{2,5}$ ]] || fail "SMTP_PORT is a port number"
if [ "$ACCESS" = ip ]; then
    [[ "${V[SERVER_IP]}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "SERVER_IP is the server's IPv4 address"
    [[ "${V[IP_TENANT]}" =~ ^[a-z0-9-]{2,30}$ ]] || fail "IP_TENANT is a tenant code: 2 to 30 small letters, digits or hyphens"
fi
[[ "${V[KEY_NAME]}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "KEY_NAME is a file name"
DB_ADDRESS="${V[DB_ADDRESS]:-}"
[ -z "$DB_ADDRESS" ] || [[ "$DB_ADDRESS" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "DB_ADDRESS is an IPv4 address, or empty"

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
[ "$MAIL_KEPT" = 1 ] && install -d -m 750 -o 10001 -g 10001 "$R/srv/bankfas/mail"

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
if [ -n "$DB_ADDRESS" ]; then
    # One server (docs/58): both containers reach SQL Server on this host through the network's gateway, under the
    # name of its certificate; the host's own tools reach it on the loopback under the same name.
    python3 - "$R/opt/bankfas/compose.yml" "${V[DB_HOST]}" "$DB_ADDRESS" <<'PY'
import sys
p, host, addr = sys.argv[1:]
out, service = [], None
for line in open(p).read().split("\n"):
    out.append(line)
    if line.startswith("  ") and not line.startswith("    ") and line.strip().endswith(":"):
        service = line.strip()[:-1]
    if service in ("api", "worker") and line == "    restart: unless-stopped":
        out.append(f'    extra_hosts: ["{host}:{addr}"]   # the database on this host (docs/58)')
open(p, "w").write("\n".join(out))
PY
    echo "   compose.yml: ${V[DB_HOST]} is $DB_ADDRESS in the api and worker containers"
    hosts="$R/etc/hosts"
    if ! grep -qE "^127\.0\.0\.1[[:space:]]+${V[DB_HOST]//./\\.}([[:space:]]|$)" "$hosts" 2>/dev/null; then
        printf '127.0.0.1 %s   # the database on this host (docs/58)\n' "${V[DB_HOST]}" >> "$hosts"
        echo "   /etc/hosts: ${V[DB_HOST]} is 127.0.0.1 on this host"
    fi
fi
if [ "$ACCESS" = ip ]; then
    # The trial by address (docs/62): the portal of IP_TENANT on SERVER_IP, the operator panel on admin.localhost
    # (the SSH tunnel), the mail kept on this host without SMTP, and the host's certificate authorities (with the
    # trial's own, tools/host/trial_db_cert.sh) given to both containers so they trust the database's certificate.
    for f in api.env worker.env; do
        python3 - "$R/opt/bankfas/$f" "${V[SERVER_IP]}" "${V[IP_TENANT]}" "$MAIL_KEPT" <<'PY'
import sys
p, ip, tenant, kept = sys.argv[1:]
out = []
for line in open(p).read().split("\n"):
    if kept == "1" and line.startswith("Mail__Smtp__"):
        continue
    if line.startswith("Hosts__Operator="):
        line = "Hosts__Operator=admin.localhost"
    out.append(line)
    if line.startswith("Portal__Domain="):
        out += [f"Portal__Address={ip}", f"Portal__AddressTenant={tenant}"]
if kept == "1":
    out.append("Mail__DropDirectory=/srv/bankfas/mail")
open(p, "w").write("\n".join(out))
PY
    done
    python3 - "$R/opt/bankfas/compose.yml" "$MAIL_KEPT" <<'PY'
import sys
p, kept = sys.argv[1:]
out, service = [], None
for line in open(p).read().split("\n"):
    out.append(line)
    if line.startswith("  ") and not line.startswith("    ") and line.strip().endswith(":"):
        service = line.strip()[:-1]
    if service in ("api", "worker") and line == "    volumes:":
        out.append("      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro   # the host's authorities (docs/62)")
        if kept == "1":
            out.append("      - /srv/bankfas/mail:/srv/bankfas/mail   # the mail kept on this host (docs/62)")
open(p, "w").write("\n".join(out))
PY
    echo "   the trial by address: https://${V[SERVER_IP]} is the tenant ${V[IP_TENANT]}; the operator panel is https://admin.localhost:8443 (SSH tunnel)"
    [ "$MAIL_KEPT" = 1 ] && echo "   no SMTP: the mail is kept in /srv/bankfas/mail (tools/host/show_mail.sh)"
fi
install -d -m 755 "$R/etc/caddy"
if [ "$ACCESS" = ip ]; then render "$HERE/Caddyfile.ip" "$R/etc/caddy/Caddyfile" 644
else render "$HERE/Caddyfile" "$R/etc/caddy/Caddyfile" 644; fi

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
if [ "$MAIL_KEPT" = 1 ]; then echo "   not needed: the mail is kept on this host"; else
if [ -n "$SMTP_FILE" ]; then ( umask 077; tr -d '\r\n' < "$SMTP_FILE" > "$smtp" ); shred -u "$SMTP_FILE" 2>/dev/null || true
elif [ ! -s "$smtp" ] && [ -t 0 ]; then read -rsp "   SMTP password for ${V[SMTP_USER]}: " p; echo; ( umask 077; printf '%s' "$p" > "$smtp" ); unset p; fi
if [ -s "$smtp" ]; then chown 10001:10001 "$smtp"; chmod 400 "$smtp"; echo "   in place"; else echo "   MISSING"; fi
fi

step "DNS token of Caddy"
dns="$R/etc/caddy/dns.env"
if [ "$ACCESS" = ip ]; then echo "   not needed: the certificates come from Caddy's own authority"; else
if [ -n "$DNS_FILE" ]; then ( umask 077; printf '%s=%s\n' "${V[DNS_TOKEN_VAR]}" "$(tr -d '\r\n' < "$DNS_FILE")" > "$dns" ); shred -u "$DNS_FILE" 2>/dev/null || true
elif [ ! -s "$dns" ] && [ -t 0 ]; then read -rsp "   ${V[DNS_PROVIDER]} API token: " p; echo; ( umask 077; printf '%s=%s\n' "${V[DNS_TOKEN_VAR]}" "$p" > "$dns" ); unset p; fi
if [ -s "$dns" ]; then
    chmod 600 "$dns"
    install -d -m 755 "$R/etc/systemd/system/caddy.service.d"
    printf '[Service]\nEnvironmentFile=/etc/caddy/dns.env\n' > "$R/etc/systemd/system/caddy.service.d/dns.conf"
    echo "   in place (systemctl daemon-reload && systemctl restart caddy)"
else echo "   MISSING"; fi
fi

echo "done: now tools/host/check_ready.sh"

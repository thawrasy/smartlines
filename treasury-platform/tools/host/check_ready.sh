#!/usr/bin/env bash
# The application host's readiness before the first `docker compose up` and after every change (docs/54, docs/55).
# It only reads: one PASS, WARN or FAIL line per check, and exit code 1 when any check fails. Run as root from
# treasury-platform/ after provision_app_host.sh; keep its output in the provisioning record.
# BANKFAS_ROOT (default /) reads every path under another folder, for a dry run; BANKFAS_SKIP_NETWORK=1 skips the
# checks that reach the network (DNS, the database server, the mail relay).
set -uo pipefail
R="${BANKFAS_ROOT:-}"; R="${R%/}"
SITE="${BANKFAS_SITE:-$R/opt/bankfas/site.conf}"
fails=0 warns=0
pass() { echo "PASS  $*"; }
warn() { echo "WARN  $*"; warns=$((warns + 1)); }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
mode_owner() { stat -c '%a %u' "$1" 2>/dev/null; }
expect() {   # expect <path> <mode> <uid> <what>
    local got; got="$(mode_owner "$1")"
    if [ -z "$got" ]; then fail "$4: $1 is missing"
    elif [ "$got" = "$2 $3" ]; then pass "$4"
    else fail "$4: $1 is mode/owner $got, expected $2 $3"; fi
}
[ "$(id -u)" = 0 ] || { echo "run it as root"; exit 1; }
[ -f "$SITE" ] || { echo "no $SITE (tools/host/site.conf.example)"; exit 1; }
declare -A V
while IFS='=' read -r k v; do [[ "$k" =~ ^[A-Z_]+$ ]] && V[$k]="$v"; done < <(grep -E '^[A-Z_]+=' "$SITE")

echo "== files and permissions"
expect "$SITE" 600 0 "site.conf is root-only"
expect "$R/opt/bankfas/api.env" 600 0 "api.env is root-only"
expect "$R/opt/bankfas/worker.env" 600 0 "worker.env is root-only"
expect "$R/opt/bankfas/secrets" 750 0 "the secrets folder is root's, readable by the application group"
expect "$R/opt/bankfas/secrets/master-keys" 700 10001 "the master key folder is the application user's only"
key="$R/opt/bankfas/secrets/master-keys/${V[KEY_NAME]:-none}.key"
expect "$key" 400 10001 "the current master key file (${V[KEY_NAME]:-?}) is owner-only"
if [ -f "$key" ] && [ "$(base64 -d < "$key" 2>/dev/null | wc -c)" = 32 ]; then pass "the master key holds 32 bytes"; else fail "the master key is not the base64 of 32 bytes"; fi
grep -q "^Keys__File__Current=file:${V[KEY_NAME]:-none}$" "$R/opt/bankfas/api.env" 2>/dev/null \
    && grep -q "^Keys__File__Current=file:${V[KEY_NAME]:-none}$" "$R/opt/bankfas/worker.env" 2>/dev/null \
    && pass "both processes name the current master key" || fail "api.env or worker.env does not name file:${V[KEY_NAME]:-?}"
for n in app platform support jobs; do expect "$R/opt/bankfas/secrets/db/bankfas_${n}_a.secret" 400 10001 "the database secret of bankfas_${n}_a"; done
expect "$R/opt/bankfas/secrets/smtp.secret" 400 10001 "the SMTP password"
expect "$R/srv/bankfas/files" 750 10001 "the document store"
expect "$R/srv/bankfas/dataprotection" 750 10001 "the data protection keys folder"
for f in api.env worker.env compose.yml; do
    if grep -v '^[[:space:]]*#' "$R/opt/bankfas/$f" 2>/dev/null | sed 's/#.*//' | grep -qE '<[A-Z_]+>'; then fail "$f still has a placeholder"; else pass "$f has no placeholder"; fi
done
if grep -qE '^ASPNETCORE_ENVIRONMENT=Production$' "$R/opt/bankfas/api.env" && grep -qE '^DOTNET_ENVIRONMENT=Production$' "$R/opt/bankfas/worker.env"; then
    pass "both processes run as Production"; else fail "api.env or worker.env is not Production"; fi
if grep -qiE 'TrustServerCertificate|RateLimits__Scale|AllowMissingRanges|Scanning__Provider=test|Mail__DropDirectory' "$R/opt/bankfas/api.env" "$R/opt/bankfas/worker.env"; then
    fail "a development or test setting is in api.env or worker.env"; else pass "no development or test setting"; fi
if [ -e "$R/etc/caddy/dns.env" ]; then expect "$R/etc/caddy/dns.env" 600 0 "Caddy's DNS token is root-only"; else fail "no /etc/caddy/dns.env (the DNS token of the wildcard certificate)"; fi

echo "== the leaked-password list"
n="$(find "$R/srv/bankfas/breached" -maxdepth 1 -name '?????.txt' 2>/dev/null | wc -l)"
if [ "$n" -eq 1048576 ]; then pass "the leaked-password list is complete"
else fail "the leaked-password list has $n of 1048576 ranges (tools/host/download_breached.sh)"; fi

echo "== the services of the host"
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    pass "Docker runs"
    for img in "${V[API_IMAGE]:-}" "${V[WORKER_IMAGE]:-}"; do
        if docker image inspect "$img" >/dev/null 2>&1; then
            [ "$(docker image inspect --format '{{.Config.User}}' "$img")" = bankfas ] && pass "image $img is present and runs as bankfas" || fail "image $img does not run as bankfas"
        else fail "image $img is not on this host (docs/54 R-01)"; fi
    done
    (cd "$R/opt/bankfas" 2>/dev/null && docker compose -f compose.yml config --quiet 2>/dev/null) && pass "compose.yml is valid" || fail "docker compose config fails on compose.yml"
else fail "Docker does not run"; fi
if command -v caddy >/dev/null; then
    caddy validate --config "$R/etc/caddy/Caddyfile" >/dev/null 2>&1 && pass "the Caddyfile is valid" || fail "caddy validate fails"
    caddy list-modules 2>/dev/null | grep -q "^dns.providers.${V[DNS_PROVIDER]:-none}$" && pass "Caddy has the ${V[DNS_PROVIDER]:-?} DNS module" || fail "Caddy lacks dns.providers.${V[DNS_PROVIDER]:-?} (xcaddy build --with github.com/caddy-dns/${V[DNS_PROVIDER]:-?})"
else fail "Caddy is not installed"; fi
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then pass "the firewall is active"; else fail "the firewall is not active (tools/host/ufw.sh)"; fi
[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && pass "the clock is synchronised" || warn "the clock is not reported synchronised"
avail="$(df -Pk "$R/srv" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')"
[ "${avail:-0}" -ge 20 ] && pass "${avail} GB free under /srv" || warn "only ${avail:-?} GB free under /srv"

if [ "${BANKFAS_SKIP_NETWORK:-0}" != 1 ]; then
    echo "== the network"
    me="$(hostname -I 2>/dev/null)"
    for h in "${V[DOMAIN]:-}" "admin.${V[DOMAIN]:-}" "check-$RANDOM.${V[DOMAIN]:-}"; do
        ip="$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1 {print $1}')"
        if [ -z "$ip" ]; then fail "$h does not resolve"; else pass "$h resolves to $ip"; fi
    done
    [ -n "$me" ] && echo "      (this host's addresses: $me; behind a NAT the public address differs)"
    tcp() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
    tcp "${V[DB_HOST]:-}" 1433 && pass "the database server answers on ${V[DB_HOST]:-?}:1433" || fail "no answer from ${V[DB_HOST]:-?}:1433 (its firewall allows this host?)"
    tcp "${V[SMTP_HOST]:-}" "${V[SMTP_PORT]:-587}" && pass "the mail relay answers on ${V[SMTP_HOST]:-?}:${V[SMTP_PORT]:-587}" || fail "no answer from the mail relay"
fi

echo "== $fails failed, $warns warnings"
[ "$fails" -eq 0 ]

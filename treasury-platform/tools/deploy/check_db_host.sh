#!/usr/bin/env bash
# The database server's readiness before the first deployment (docs/54 part B, DOC-S10 sections 4 to 6): what the
# operating system shows, read only. One PASS, WARN or FAIL line per check, exit code 1 when any fails; keep the
# output in the provisioning record. The checks inside SQL Server (sa disabled, the server audit, the release
# register) are the deployment preflight's and server_audit.sh check's.
# Run as root from treasury-platform/. BANKFAS_ROOT (default /) reads the files under another folder, for a dry run.
set -uo pipefail
R="${BANKFAS_ROOT:-}"; R="${R%/}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0 warns=0
pass() { echo "PASS  $*"; }
warn() { echo "WARN  $*"; warns=$((warns + 1)); }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
reg() { python3 -c "import json,sys; d=json.load(open('$ROOT/versions.json'))['database_host']; print($1)"; }

echo "== the release register (versions.json)"
want_os="$(reg "d['os_release']")" want_sql="$(reg "d['sqlserver']['product_version']")"
os="$(. "$R/etc/os-release" 2>/dev/null; echo "${VERSION_ID:-?}")"
[ "$os" = "$want_os" ] && pass "Ubuntu $os" || fail "Ubuntu $os, the register says $want_os"
if command -v dpkg-query >/dev/null && dpkg-query -W -f '${Version}' mssql-server >/dev/null 2>&1; then
    v="$(dpkg-query -W -f '${Version}' mssql-server)"
    [[ "$v" == "$want_sql"* ]] && pass "mssql-server $v" || fail "mssql-server $v, the register says $want_sql"
    apt-mark showhold 2>/dev/null | grep -qx mssql-server && pass "mssql-server is held" || fail "mssql-server is not held (apt-mark hold mssql-server)"
    systemctl is-enabled mssql-server >/dev/null 2>&1 && systemctl is-active mssql-server >/dev/null 2>&1 && pass "the service is enabled and running" || fail "mssql-server is not enabled and running"
else fail "mssql-server is not installed"; fi

echo "== mssql-conf (DOC-S10 section 5.2)"
conf="$R/var/opt/mssql/mssql.conf"
get() { awk -F' *= *' -v s="$1" -v k="$2" '/^\[/{sec=substr($0,2,length($0)-2)} sec==s && $1==k {print $2}' "$conf" 2>/dev/null; }
[ "$(get network forceencryption)" = 1 ] && pass "the server forces encryption" || fail "network.forceencryption is not 1"
cert="$(get network tlscert)" key="$(get network tlskey)"
if [ -n "$cert" ] && [ -f "$R$cert" ]; then pass "a TLS certificate is set ($cert)"
    if command -v openssl >/dev/null; then
        end="$(openssl x509 -enddate -noout -in "$R$cert" 2>/dev/null | cut -d= -f2)"
        openssl x509 -checkend 2592000 -noout -in "$R$cert" >/dev/null 2>&1 && pass "the certificate is valid for 30 days or more ($end)" || fail "the certificate expires within 30 days ($end)"
    fi
else fail "network.tlscert is not set or its file is missing"; fi
if [ -n "$key" ] && [ -f "$R$key" ]; then
    [ "$(stat -c '%a %U' "$R$key")" = "600 mssql" ] && pass "the TLS key is mssql's, mode 600" || fail "the TLS key $key is $(stat -c '%a %U' "$R$key"), expected 600 mssql"
else fail "network.tlskey is not set or its file is missing"; fi
for d in data tlog backup audit; do
    p="$R/var/opt/mssql/$d"
    if [ -d "$p" ]; then [ "$(stat -c '%U' "$p")" = mssql ] && pass "/var/opt/mssql/$d is mssql's" || fail "/var/opt/mssql/$d is not owned by mssql"
    else fail "/var/opt/mssql/$d is missing (DOC-S10 section 3)"; fi
done
[ "$(get filelocation defaultlogdir)" = /var/opt/mssql/tlog ] && pass "the log files go to /var/opt/mssql/tlog" || warn "filelocation.defaultlogdir is not /var/opt/mssql/tlog"

echo "== the host (DOC-S10 section 6)"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    pass "the firewall is active"
    ufw status 2>/dev/null | grep -E '^1433' | grep -q 'Anywhere' && fail "1433 is open to Anywhere: only the application host may reach it" || pass "1433 is not open to everyone"
else fail "the firewall is not active"; fi
if command -v sshd >/dev/null; then
    t="$(sshd -T 2>/dev/null)"
    grep -qx 'passwordauthentication no' <<<"$t" && pass "SSH refuses passwords" || fail "SSH accepts passwords"
    grep -qx 'permitrootlogin no' <<<"$t" && pass "SSH refuses root" || fail "SSH accepts root"
else warn "sshd not found"; fi
[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && pass "the clock is synchronised" || warn "the clock is not reported synchronised"
systemctl is-enabled unattended-upgrades >/dev/null 2>&1 && pass "security updates are automatic" || warn "unattended-upgrades is not enabled (DOC-S10 section 6.4)"

echo "== $fails failed, $warns warnings"
[ "$fails" -eq 0 ]

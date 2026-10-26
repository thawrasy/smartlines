#!/usr/bin/env bash
# The application host's firewall (ADR 0047, DOC-S16 section 4). Run once as root, then keep `ufw status verbose` in
# the provisioning record. ADMIN_CIDRS is the list of the administrators' addresses, for example "203.0.113.10/32";
# DB_ON_THIS_HOST=1 when SQL Server runs on this host too (docs/58). WEB_CIDRS, when set, is the list of the only
# addresses that may open the site (the private trial by address, docs/62): then port 80 stays closed and 443 opens to
# those addresses alone; empty, the site is open to everyone (a public platform).
set -euo pipefail
: "${ADMIN_CIDRS:?set ADMIN_CIDRS to the addresses of the administrators, separated by spaces}"
SSH_PORT="${SSH_PORT:-22}"
HTTPS_PER_ADDRESS="${HTTPS_PER_ADDRESS:-300}"  # new connections to 443 a minute from one address (a company behind one NAT address counts once)

ufw --force reset
ufw default deny incoming
ufw default allow outgoing          # narrowed to a list once the outbound hosts are known (DQ-S10-3)
for cidr in $ADMIN_CIDRS; do ufw allow from "$cidr" to any port "$SSH_PORT" proto tcp comment 'SSH from the admins'; done
if [ -n "${WEB_CIDRS:-}" ]; then
  for cidr in $WEB_CIDRS; do
    ufw allow from "$cidr" to any port 443 proto tcp comment 'HTTPS from the testers (docs/62)'
    ufw allow from "$cidr" to any port 443 proto udp comment 'HTTP/3 from the testers (docs/62)'
  done
else
  ufw allow 80/tcp comment 'HTTP: certificate challenge and the redirect to HTTPS'
  ufw allow 443/tcp comment 'HTTPS'
  ufw allow 443/udp comment 'HTTP/3'
fi
# One server for the trial (docs/58, DB_ON_THIS_HOST=1): SQL Server on this host is reached by the containers' network
# only, never from outside.
if [ "${DB_ON_THIS_HOST:-0}" = 1 ]; then
  ufw allow from 172.30.0.0/24 to any port 1433 proto tcp comment 'SQL Server from the containers (docs/58)'
fi

# ICMP echo (ping) is answered, but at most 5 a second with a burst of 10; floods are dropped. Edited in before.rules
# because ufw has no command for it; the original file is kept next to it.
rules=/etc/ufw/before.rules
cp -n "$rules" "$rules.orig"
sed -i 's/^-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT$/-A ufw-before-input -p icmp --icmp-type echo-request -m limit --limit 5\/second --limit-burst 10 -j ACCEPT\n-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' "$rules"
# New TCP connections to 443 from one address are limited, and one address may hold at most 200 at once (Caddy has no
# per-address connection limit of its own). Added once, before the COMMIT of the filter table.
if ! grep -q 'bankfas-https-limit' "$rules"; then
  python3 - "$rules" "$HTTPS_PER_ADDRESS" <<'PY'
import sys
p, n = sys.argv[1], sys.argv[2]
s = open(p).read()
block = f"""# bankfas-https-limit (tools/host/ufw.sh)
-A ufw-before-input -p tcp --dport 443 --syn -m connlimit --connlimit-above 200 --connlimit-mask 32 -j DROP
-A ufw-before-input -p tcp --dport 443 --syn -m hashlimit --hashlimit-name https --hashlimit-mode srcip --hashlimit-above {n}/minute --hashlimit-burst {n} -j DROP
"""
i = s.rindex("COMMIT")
open(p, "w").write(s[:i] + block + s[i:])
PY
fi
ufw logging low
ufw --force enable
ufw status verbose

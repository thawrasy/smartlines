#!/usr/bin/env bash
# Trial installation on a fresh Ubuntu 22.04 / 24.04 server, run as root from the extracted release or a checkout:
#   sudo ./deploy/trial.sh --email you@example.com [--domain trial.example.com]
#
# Installs with demo data, simulated payments and the demo accounts of deploy/README.md (deploy/install.sh --demo).
# Without --domain no domain is needed: the site is published as <server IP>.sslip.io, a public name that resolves
# to the server's own address (203-0-113-10.sslip.io is 203.0.113.10), so the certificate is issued as for any
# domain. --email receives the certificate notices and becomes the first administrator's sign-in.
#
# Never on a server with real users: the demo accounts share a published password.
set -euo pipefail
cd "$(dirname "$0")/.."
email="" domain=""
while [ $# -gt 0 ]; do
  case "$1" in
    --email) email="$2"; shift 2 ;;
    --domain) domain="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$email" ] || { echo "usage: $0 --email <your e-mail address> [--domain <domain pointing at this server>]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

if [ -z "$domain" ]; then
  ip=""
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4 -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
    ip=""
  done
  [ -n "$ip" ] || { echo "could not find this server's public IPv4 address; give a domain with --domain" >&2; exit 1; }
  domain="${ip//./-}.sslip.io"
  echo "No domain given: the site will be https://$domain"
fi

./deploy/install.sh --demo --domain "$domain" --email "$email" --admin-email "$email"

cat <<EOF

Trial site:   https://$domain
Demo sign-in: https://$domain/login  (password for every demo account: Masslak-Demo-2026)
  passenger@masslak.test   passenger (wallet 500,000 SYP)
  owner@carrier.test       carrier
  agency@agency.test       agency
  driver@carrier.test      driver
  admin@masslak.test       platform administration
If the browser warns about the certificate, wait a minute and reload: it is issued on the first visit after start.
EOF

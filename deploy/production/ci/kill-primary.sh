#!/usr/bin/env bash
# The failover drill's --kill in CI (job "Production with two database hosts"): the database host that is the primary
# now loses its database at once, as a host that fails does: its Patroni container (PostgreSQL inside it) is killed.
# Prints and records which one (/tmp/masslak-killed), so the job can start it again and watch it rejoin.
set -euo pipefail
ca="${MASSLAK_CI_CA:-deploy/production/tls/ca.crt}"
for h in 10.77.0.11:db1 10.77.0.12:db2; do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --cacert "$ca" "https://${h%%:*}:8008/primary")" = 200 ]; then
    echo "${h##*:}" > /tmp/masslak-killed
    exec sudo docker kill "masslak-${h##*:}-patroni-1"
  fi
done
echo "no primary to kill" >&2
exit 1

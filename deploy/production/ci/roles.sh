#!/usr/bin/env bash
# Which database host is the primary and which its synchronous standby, from their Patroni REST APIs (CI job
# "Production with two database hosts"): prints shell assignments for eval, e.g.
#   roles="$(./deploy/production/ci/roles.sh 120)"; eval "$roles"   # wait up to 120 s for both roles
#   PRIMARY=db1 PRIMARY_ADDR=10.77.0.11 STANDBY=db2 STANDBY_ADDR=10.77.0.12
set -euo pipefail
wait_s="${1:-0}"
ca="${MASSLAK_CI_CA:-deploy/production/tls/ca.crt}"
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 --cacert "$ca" "https://$1:8008$2" || true; }
deadline=$((SECONDS + wait_s))
while :; do
  primary="" standby=""
  for h in 10.77.0.11:db1 10.77.0.12:db2; do
    [ "$(code "${h%%:*}" /primary)" = 200 ] && primary="$h"
    [ "$(code "${h%%:*}" /sync)" = 200 ] && standby="$h"
  done
  if [ -n "$primary" ] && [ -n "$standby" ]; then
    echo "PRIMARY=${primary##*:} PRIMARY_ADDR=${primary%%:*} STANDBY=${standby##*:} STANDBY_ADDR=${standby%%:*}"
    exit 0
  fi
  [ "$SECONDS" -lt "$deadline" ] || { echo "no primary with a synchronous standby (primary: ${primary:-none}, standby: ${standby:-none})" >&2; exit 1; }
  sleep 2
done

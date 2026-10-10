#!/bin/sh
# HAProxy in front of the two database hosts (reviews of October 2026, H-01; deploy/production/ha). The application
# host runs it from this image under the names the stack already uses, so PgBouncer, the API, the migration and the
# operator's scripts keep connecting to db and db-replica:
#   masslak-db-proxy primary   port 5432 reaches whichever host is the primary now
#   masslak-db-proxy replica   port 5432 reaches a standby at most 16 MB behind, or the primary when no standby is
#                              (reports slow the primary rather than stop)
# Patroni's REST API answers 200 on /primary only on the primary and on /replica only on a streaming standby; HAProxy
# asks every second over TLS, checking the certificate against the internal authority. A host that loses the role
# is marked down within 3 s and its connections are cut, so clients reconnect to the new primary rather than wait on
# a server that can no longer write. TLS to PostgreSQL itself passes through untouched: clients check the
# database's certificate (verify-full) under the name db or db-replica, which the cluster's certificate carries.
#   MASSLAK_DB_HOSTS   the database hosts' addresses on the private network, comma-separated
set -eu
mode="${1:-primary}"
hosts="${MASSLAK_DB_HOSTS:?MASSLAK_DB_HOSTS names the database hosts (deploy/.env)}"
ca="${MASSLAK_DB_CA:-/tls-src/ca.crt}"
[ -s "$ca" ] || { echo "masslak-db-proxy: $ca is missing: run deploy/production/init.sh" >&2; exit 1; }
cfg=/tmp/haproxy.cfg
servers() {
  i=0
  for h in $(echo "$hosts" | tr ',' ' '); do
    i=$((i + 1))
    echo "    server db$i $h:5432 check port 8008 check-ssl verify required ca-file $ca"
  done
}
{
  cat <<EOT
global
    maxconn 4000

defaults
    mode tcp
    timeout connect 3s
    timeout client 1h
    timeout server 1h
    timeout check 2s
    option clitcpka
    option srvtcpka
    default-server inter 1s fall 3 rise 2 on-marked-down shutdown-sessions

backend primary
    option httpchk GET /primary
    http-check expect status 200
$(servers)
EOT
  case "$mode" in
    primary)
      printf '\nfrontend writes\n    bind :5432\n    default_backend primary\n' ;;
    replica)
      printf '\nfrontend reads\n    bind :5432\n    use_backend standbys if { nbsrv(standbys) gt 0 }\n    default_backend primary\n'
      printf '\nbackend standbys\n    balance roundrobin\n    option httpchk GET /replica?lag=16MB\n    http-check expect status 200\n'
      servers ;;
    *) echo "masslak-db-proxy: primary or replica, not $mode" >&2; exit 2 ;;
  esac
} > "$cfg"
chmod 0644 "$cfg"
exec su-exec haproxy haproxy -W -db -f "$cfg"

#!/bin/sh
# Start of the production database containers (deploy/production): the primary (db) and the read replica
# (db-replica) of the single host, or Patroni on each database host of the layout with two (H-01,
# deploy/production/ha/db-host.yml). As root, it installs the TLS files where only postgres reads the key and writes
# pg_hba.conf, then starts the given command: the image's own entrypoint for the primary, deploy/postgres/replica.sh
# or patroni (as postgres) otherwise.
#
# pg_hba.conf (reviews of October 2026, H-05 and H-10): inside the container the socket is trusted; on the network
# only TLS, with scram-sha-256, from the network the database is attached to: the container network (samenet), or on
# a database host the private network between the hosts (MASSLAK_DB_NETWORK, an address range; samenet by default,
# the host's own networks). The warehouse login signs in only from MASSLAK_WAREHOUSE_ADDRESS with a client
# certificate issued to masslak_cdc, and is refused anywhere else. Anything without TLS is refused.
set -eu
src=/tls-src dst=/var/lib/postgresql/tls
for f in ca.crt server.crt server.key; do
  [ -s "$src/$f" ] || { echo "masslak-db-entry: $src/$f is missing: run deploy/production/init.sh" >&2; exit 1; }
done
mkdir -p "$dst"
cp "$src/ca.crt" "$src/server.crt" "$src/server.key" "$dst/"
chown -R postgres:postgres "$dst"
chmod 0644 "$dst/ca.crt" "$dst/server.crt"
chmod 0600 "$dst/server.key"

hba=/var/lib/postgresql/pg_hba.conf
net="${MASSLAK_DB_NETWORK:-samenet}"
{
  echo "# Written by masslak-db-entry at each start (deploy/production/db/entry.sh); edits here are lost."
  echo "# TYPE    DATABASE     USER         ADDRESS        METHOD"
  echo "local     all          all                         trust"
  if [ -n "${MASSLAK_WAREHOUSE_ADDRESS:-}" ]; then
    echo "hostssl   all          masslak_cdc  ${MASSLAK_WAREHOUSE_ADDRESS}  scram-sha-256  clientcert=verify-full"
  fi
  echo "host      all          masslak_cdc  all            reject"
  echo "hostssl   replication  replicator   ${net}        scram-sha-256"
  echo "host      replication  all          all            reject"
  echo "hostssl   all          all          ${net}        scram-sha-256"
  echo "host      all          all          all            reject"
} > "$hba"
chown postgres:postgres "$hba"
chmod 0640 "$hba"

if [ "${1:-}" = patroni ]; then
  # Patroni creates the cluster in an empty data directory (or copies it from the other host) as postgres
  data="${PGDATA:-/var/lib/postgresql/data}"
  mkdir -p "$data"; chown postgres:postgres "$data"; chmod 0700 "$data"
  # the host's watchdog, when passed in: Patroni keeps it fed while it holds the leader key (patroni.yml)
  [ ! -c /dev/watchdog ] || chown postgres /dev/watchdog
fi

case "${1:-}" in
  # the image's own entrypoint initialises an empty data directory, then runs the server as postgres, with the
  # settings guard added to its shared_preload_libraries (db/guard/entry.sh)
  docker-entrypoint.sh) exec masslak-guard-entry "$@" ;;
  postgres) exec masslak-guard-entry docker-entrypoint.sh "$@" ;;
  *) exec su-exec postgres "$@" ;;
esac

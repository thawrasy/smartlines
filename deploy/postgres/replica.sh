#!/bin/sh
# Read replica (hot standby) of the db service: reports and exports read here, never on the primary (architecture
# review of design 3.9). On first start it copies the primary with pg_basebackup through a replication slot; afterwards
# it streams. It also serves as the failover candidate: docker compose exec -u postgres db-replica pg_ctl promote
#
# In the production profile (MASSLAK_DB_TLS set, deploy/production) it copies and streams over TLS, checking the
# primary's certificate (sslmode=verify-full), and serves its own clients over TLS with the pg_hba.conf that
# masslak-db-entry wrote. The connection to the primary is given on the command line at every start, so a replica
# copied before TLS was turned on streams over TLS from its next start too.
set -eu
export PGPASSWORD="${MASSLAK_REPLICATION_PASSWORD:?MASSLAK_REPLICATION_PASSWORD is not set}"
SLOT=replica1
tls="${MASSLAK_DB_TLS:-}"
primary="host=db port=5432 user=replicator"
server_tls=""
if [ -n "$tls" ]; then
  primary="$primary sslmode=verify-full sslrootcert=$tls/ca.crt"
  server_tls="-c ssl=on -c ssl_cert_file=$tls/server.crt -c ssl_key_file=$tls/server.key -c ssl_ca_file=$tls/ca.crt
              -c ssl_min_protocol_version=TLSv1.3 -c hba_file=/var/lib/postgresql/pg_hba.conf"
else
  server_tls="-c hba_file=/etc/postgresql/pg_hba.conf"
fi
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  until pg_isready -d "$primary" -q; do echo "waiting for the primary"; sleep 2; done
  # a slot left by an earlier copy of this replica would keep WAL forever: start from a fresh one
  psql -d "$primary dbname=postgres" -Atc "SELECT pg_drop_replication_slot('$SLOT') FROM pg_replication_slots WHERE slot_name = '$SLOT' AND NOT active" > /dev/null
  pg_basebackup -d "$primary" -D "$PGDATA" -X stream -R -C -S "$SLOT" --checkpoint=fast
  chmod 0700 "$PGDATA"
fi
# the password for streaming stays in a file only postgres reads, not on the command line
passfile="$PGDATA/../.pgpass-replica"
printf 'db:5432:replication:replicator:%s\n' "$PGPASSWORD" > "$passfile"
chmod 0600 "$passfile"
# cluster_name is the name the primary sees (application_name): the standby named by deploy/durability.sh when every
# commit must wait for a copy (MASSLAK_ZERO_DATA_LOSS=on)
# shellcheck disable=SC2086  # server_tls is a list of options
exec postgres $server_tls -c hot_standby=on -c max_standby_streaming_delay=30s -c max_connections=200 \
     -c "primary_conninfo=$primary passfile=$passfile application_name=replica1" -c primary_slot_name=$SLOT \
     -c cluster_name=replica1 -c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track_utility=off \
     -c track_io_timing=on -c log_min_duration_statement=1000 -c log_parameter_max_length=0

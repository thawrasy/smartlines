#!/bin/sh
# Read replica (hot standby) of the db service: reports and exports read here, never on the primary (architecture
# review of design 3.9). On first start it copies the primary with pg_basebackup through a replication slot; afterwards
# it streams. It also serves as the failover candidate: docker compose exec -u postgres db-replica pg_ctl promote
set -eu
export PGPASSWORD="${MASSLAK_REPLICATION_PASSWORD:?MASSLAK_REPLICATION_PASSWORD is not set}"
SLOT=replica1
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  until pg_isready -h db -q; do echo "waiting for the primary"; sleep 2; done
  # a slot left by an earlier copy of this replica would keep WAL forever: start from a fresh one
  psql -h db -U replicator -d postgres -Atc "SELECT pg_drop_replication_slot('$SLOT') FROM pg_replication_slots WHERE slot_name = '$SLOT' AND NOT active" > /dev/null
  pg_basebackup -h db -U replicator -D "$PGDATA" -X stream -R -C -S "$SLOT" --checkpoint=fast
  chmod 0700 "$PGDATA"
fi
# cluster_name is the name the primary sees (application_name): the standby named by deploy/durability.sh when every
# commit must wait for a copy (MASSLAK_ZERO_DATA_LOSS=on)
exec postgres -c hba_file=/etc/postgresql/pg_hba.conf -c hot_standby=on -c max_standby_streaming_delay=30s -c max_connections=200 \
     -c cluster_name=replica1 -c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track_utility=off \
     -c track_io_timing=on -c log_min_duration_statement=1000 -c log_parameter_max_length=0

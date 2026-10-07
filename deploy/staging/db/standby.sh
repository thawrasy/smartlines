#!/bin/sh
# Streaming standby: on first start copy the primary with pg_basebackup (-R writes primary_conninfo and standby.signal),
# then run as a hot standby. Promote with: docker compose exec -u postgres db-standby pg_ctl promote
set -eu
export PGPASSWORD="${MASSLAK_REPLICATION_PASSWORD:?MASSLAK_REPLICATION_PASSWORD is not set}"
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  until pg_isready -h db -U replicator -q; do sleep 2; done
  pg_basebackup -h db -U replicator -D "$PGDATA" -X stream -R -C -S standby1 --checkpoint=fast
  chmod 0700 "$PGDATA"
fi
exec postgres -c hot_standby=on -c max_standby_streaming_delay=30s

#!/bin/sh
# Primary only: the replication role the standby connects with, and the matching pg_hba rule
set -eu
[ -n "${MASSLAK_REPLICATION_PASSWORD:-}" ] || { echo "MASSLAK_REPLICATION_PASSWORD is not set" >&2; exit 1; }
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -v pw="$MASSLAK_REPLICATION_PASSWORD" <<'SQL'
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'pw';
SQL
echo "host replication replicator samenet scram-sha-256" >> "$PGDATA/pg_hba.conf"

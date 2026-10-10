#!/usr/bin/env bash
# Structural validation of the generated model on a real PostgreSQL engine (NOT the deliverable: the deliverable is SQL Server).
# Usage: tools/dbgen/pg_validate.sh <generated/pg/000_all.sql>
set -euo pipefail
SQL="$(readlink -f "$1")"
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | tail -1)
D=$(mktemp -d /tmp/pgval.XXXXXX); chown postgres "$D"; chmod 755 "$D"
cp "$SQL" "$D/model.sql"; chmod 644 "$D/model.sql"
PORT=54329
su postgres -c "$PGBIN/initdb -D $D/data -A trust >/dev/null"
su postgres -c "$PGBIN/pg_ctl -D $D/data -o '-p $PORT -k $D' -l $D/log -w start >/dev/null"
trap 'su postgres -c "$PGBIN/pg_ctl -D $D/data -m immediate stop >/dev/null" || true; rm -rf "$D"' EXIT
su postgres -c "$PGBIN/createdb -h $D -p $PORT valdb"
set +e
OUT=$(su postgres -c "psql -h $D -p $PORT -d valdb -v ON_ERROR_STOP=1 -q -f $D/model.sql" 2>&1)
RC=$?
set -e
if [ $RC -ne 0 ]; then echo "$OUT" | head -30; echo "PG VALIDATION FAILED"; exit 1; fi
su postgres -c "psql -h $D -p $PORT -d valdb -At -c \"select 'tables='||count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')\""
su postgres -c "psql -h $D -p $PORT -d valdb -At -c \"select 'foreign_keys='||count(*) from information_schema.table_constraints where constraint_type='FOREIGN KEY'\""
su postgres -c "psql -h $D -p $PORT -d valdb -At -c \"select 'unique_or_pk='||count(*) from information_schema.table_constraints where constraint_type in ('UNIQUE','PRIMARY KEY')\""
echo "PG VALIDATION OK"

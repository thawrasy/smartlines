#!/bin/sh
# Patroni's post_bootstrap (deploy/production/ha/patroni.yml): run once, on the first primary of the cluster, with a
# connection string as its argument. It makes the application's database, as the PostGIS image's entrypoint does for
# the single-host profile; the migration then builds the schema in it.
set -eu
db="${POSTGRES_DB:-masslak}"
psql "$1" -v ON_ERROR_STOP=1 -qc "CREATE DATABASE \"$db\""
echo "masslak-patroni-bootstrap: created the database $db"

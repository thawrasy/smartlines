#!/bin/sh
# One-shot database setup, run by the "migrate" service before the API starts.
#   1. builds the schema on an empty database, or applies newer schema files to an existing one
#   2. creates or updates the API and audit login roles
#   3. optionally loads demo data (test servers only)
set -eu
export PGHOST="${PGHOST:-db}" PGUSER="${POSTGRES_USER:-postgres}" PGPASSWORD="${POSTGRES_PASSWORD:?}"
DB="${POSTGRES_DB:-masslak}"

until pg_isready -q -d "$DB"; do echo "waiting for the database"; sleep 2; done

if [ "$(psql -d "$DB" -Atc "SELECT to_regclass('sys.schema_migration') IS NOT NULL")" = "f" ]; then
  echo "building the schema"
  /app/db/build.sh "$DB"
else
  echo "schema present: $(psql -d "$DB" -Atc "SELECT string_agg(version, ', ' ORDER BY applied_at) FROM sys.schema_migration")"
  /app/db/upgrade.sh "$DB"
fi

psql -d "$DB" -v ON_ERROR_STOP=1 -q -v api_password="${MASSLAK_API_PASSWORD:?}" -v audit_password="${MASSLAK_AUDIT_PASSWORD:?}" \
     -f /app/db/create_login_roles.sql

if [ "${MASSLAK_SEED_DEMO:-false}" = "true" ]; then
  MASSLAK_OWNER_URL="postgresql://$PGUSER:$PGPASSWORD@$PGHOST/$DB" python /app/backend/scripts/seed_demo.py
fi
echo "database ready"

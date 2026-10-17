#!/bin/sh
# One-shot database setup, run by the "migrate" service before the API starts.
#   1. builds the schema on an empty database, or applies newer schema files to an existing one
#   2. creates or updates the API and audit login roles
#   3. optionally loads demo data (test servers only)
set -eu
export PGHOST="${PGHOST:-db}" PGUSER="${POSTGRES_USER:-postgres}" PGPASSWORD="${POSTGRES_PASSWORD:?}"
# the read replica starts after this step: schema changes never wait for it, even when every commit of the platform
# must (MASSLAK_ZERO_DATA_LOSS=on, deploy/durability.sh)
export PGOPTIONS="${PGOPTIONS:-} -c synchronous_commit=local"
DB="${POSTGRES_DB:-masslak}"

until pg_isready -q -d "$DB"; do echo "waiting for the database"; sleep 2; done

# A production server changes nothing until the database is set up as the production profile requires: TLS only, WAL
# archived to a repository off this host (proven now), the warehouse login by certificate, pgoutput only (reviews of
# October 2026, package 2; backend/app/tools/preflight.py)
if [ "${MASSLAK_ENVIRONMENT:-}" = production ]; then
  (cd /app/backend && python -m app.tools.preflight) || { echo "migration refused: the production preflight failed" >&2; exit 1; }
fi

if [ "$(psql -d "$DB" -Atc "SELECT to_regclass('sys.schema_migration') IS NOT NULL")" = "f" ]; then
  echo "building the schema"
  /app/db/build.sh "$DB"
else
  echo "schema present: $(psql -d "$DB" -Atc "SELECT string_agg(version, ', ' ORDER BY applied_at) FROM sys.schema_migration")"
  /app/db/upgrade.sh "$DB"
fi

# which environment this server is: launch gate evidence (db/tools/gate_run.py) is filed under it, and the volume
# generator refuses to run on production
case "${MASSLAK_ENVIRONMENT:-}" in
  development|staging|production)
    psql -d "$DB" -v ON_ERROR_STOP=1 -q -v env="$MASSLAK_ENVIRONMENT" <<'SQL'
INSERT INTO sys.setting (key, value, description)
VALUES ('deploy.environment', to_jsonb(:'env'::text), 'development, staging or production (MASSLAK_ENVIRONMENT in deploy/.env)')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
SQL
    ;;
  "") ;;
  *) echo "MASSLAK_ENVIRONMENT must be development, staging or production" >&2; exit 1 ;;
esac

# Passwords and keys reach psql through its environment (\getenv), never its command line, which every process on the
# host can read (reviews of release 1.49.0).
: "${MASSLAK_API_PASSWORD:?}" "${MASSLAK_AUDIT_PASSWORD:?}" "${MASSLAK_REPLICATION_PASSWORD:?}"
# the key that signs request contexts (1080), derived from MASSLAK_SIGNING_SECRET exactly as the API derives it
MASSLAK_CONTEXT_KEY_HEX="$(cd /app/backend && python -m app.tools.context_key)"
export MASSLAK_CONTEXT_KEY_HEX
{
  echo '\getenv api_password MASSLAK_API_PASSWORD'
  echo '\getenv audit_password MASSLAK_AUDIT_PASSWORD'
  echo '\getenv context_key MASSLAK_CONTEXT_KEY_HEX'
  # the data warehouse's replication login (deploy/warehouse), only where one is configured
  if [ -n "${MASSLAK_CDC_PASSWORD:-}" ]; then echo '\getenv cdc_password MASSLAK_CDC_PASSWORD'; fi
  echo '\i /app/db/create_login_roles.sql'
} | psql -d "$DB" -v ON_ERROR_STOP=1 -q
unset MASSLAK_CONTEXT_KEY_HEX

# replication role of the read replica (db-replica); created on existing servers too, password kept in step with deploy/.env
psql -d "$DB" -v ON_ERROR_STOP=1 -q <<'SQL'
\getenv pw MASSLAK_REPLICATION_PASSWORD
SELECT format('CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') \gexec
SELECT format('ALTER ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'pw') \gexec
SQL

# On a production server the API and the worker open the data keys with the key service only: every key not wrapped
# yet is wrapped now, adopting a key deploy/.env still gives, so what it sealed stays readable (H-06)
if [ "${MASSLAK_ENVIRONMENT:-}" = production ]; then
  (cd /app/backend && python -m app.tools.keys bootstrap) || { echo "migration stopped: the data keys could not be wrapped" >&2; exit 1; }
fi

# the telemetry database of vehicle positions (deploy/telemetry), only where one is configured
if [ -n "${MASSLAK_TELEMETRY_OWNER_URL:-}" ]; then
  until pg_isready -q -d "$MASSLAK_TELEMETRY_OWNER_URL"; do echo "waiting for the telemetry database"; sleep 2; done
  : "${MASSLAK_TELEMETRY_PASSWORD:?}" "${MASSLAK_TELEMETRY_UPKEEP_PASSWORD:?set MASSLAK_TELEMETRY_UPKEEP_PASSWORD in deploy/.env (C-02)}"
  printf '%s\n' '\getenv writer_password MASSLAK_TELEMETRY_PASSWORD' '\getenv upkeep_password MASSLAK_TELEMETRY_UPKEEP_PASSWORD' \
                 '\i /app/db/telemetry/schema.sql' | psql "$MASSLAK_TELEMETRY_OWNER_URL" -v ON_ERROR_STOP=1 -q > /dev/null
  echo "telemetry database ready"
fi

if [ "${MASSLAK_SEED_DEMO:-false}" = "true" ]; then
  # demo data brings accounts with a shared, published password: never on a server that is not a sandbox (R-26)
  if [ "${MASSLAK_SANDBOX:-false}" != "true" ] || [ "${MASSLAK_ENVIRONMENT:-}" = "production" ]; then
    echo "MASSLAK_SEED_DEMO=true is refused: demo data loads only with MASSLAK_SANDBOX=true on a development or staging" \
         "server (here MASSLAK_SANDBOX=${MASSLAK_SANDBOX:-false}, MASSLAK_ENVIRONMENT=${MASSLAK_ENVIRONMENT:-unset})" >&2
    exit 1
  fi
  MASSLAK_OWNER_URL="postgresql://$PGUSER:$PGPASSWORD@$PGHOST/$DB" python /app/backend/scripts/seed_demo.py
  MASSLAK_OWNER_URL="postgresql://$PGUSER:$PGPASSWORD@$PGHOST/$DB" python /app/backend/scripts/seed_modules.py
fi
echo "database ready"

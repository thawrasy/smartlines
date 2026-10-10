#!/usr/bin/env bash
# Applies schema files that an existing database has not run yet: ./db/upgrade.sh <database> [psql connection args]
#
# Files are applied in name order, each in its own transaction, and recorded in sys.schema_file. Upgrade files
# (980 onwards) must be idempotent (IF NOT EXISTS, ON CONFLICT DO NOTHING, DROP POLICY IF EXISTS ...).
# A database built before file tracking existed is assumed to have every file up to the baseline below.
#
# An applied file whose content changed since (its SHA-256 differs from the recorded one) stops the upgrade before
# anything is applied: the database no longer matches the files, and the next files may build on the difference.
# Restore the file from the release the database was built with and add a new file for the change. On a development
# database only, MASSLAK_SCHEMA_DRIFT=warn turns this back into a warning (review of October 2026, stage A5).
set -euo pipefail
# Idempotent files print NOTICEs ("already exists, skipping"); show warnings and errors only
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning} -c masslak.migrating=on"   # schema changes are logged as migrations (1047)
# A live database: a migration waits at most MASSLAK_LOCK_TIMEOUT for a lock and gives up (bookings keep flowing) rather
# than queueing every request behind it; a statement that runs past MASSLAK_STATEMENT_TIMEOUT is stopped (audit T3-08).
# The failed file rolls back on its own; rerun it off-peak or split it (runbook section 4).
PGOPTIONS="$PGOPTIONS -c lock_timeout=${MASSLAK_LOCK_TIMEOUT:-5s} -c statement_timeout=${MASSLAK_STATEMENT_TIMEOUT:-30min}"
# psql substitutes :'variables' only in scripts, not in -c, so the statement goes through stdin
record() { echo "INSERT INTO sys.schema_file (file, sha256) VALUES (:'file', :'sha') ON CONFLICT (file) DO NOTHING" |
           psql "${PSQL_ARGS[@]}" -d "$DB" -v ON_ERROR_STOP=1 -q -v file="$1" -v sha="$2" -f -; }
DB="${1:?database name}"; shift || true
PSQL_ARGS=("$@")
DIR="$(cd "$(dirname "$0")" && pwd)"
# Schema files in numeric order of their prefix (000 ... 990, 1000 ...), so numbering can grow past three digits
schema_files() { ls "$DIR"/schema/[0-9]*_*.sql | awk -F/ '{ n = $NF; sub(/_.*/, "", n); print n "\t" $0 }' | sort -n | cut -f2-; }
BASELINE="970"

# The drift override is for development databases (review of October 2026, M-07): a server declared production, in its
# environment or in the database itself (deploy.environment, written by deploy/migrate.sh), refuses it
if [ "${MASSLAK_SCHEMA_DRIFT:-fail}" = warn ]; then
  declared="$(psql "$@" -d "$DB" -Atqc "SELECT CASE WHEN to_regclass('sys.setting') IS NULL THEN '' ELSE coalesce((SELECT value #>> '{}' FROM sys.setting WHERE key = 'deploy.environment'), '') END" 2>/dev/null || true)"
  if [ "${MASSLAK_ENVIRONMENT:-}" = production ] || [ "$declared" = production ]; then
    echo "upgrade refused: MASSLAK_SCHEMA_DRIFT=warn is not allowed on a production server. Nothing was applied." >&2
    exit 5
  fi
fi

# "tracked" only once at least one file is recorded, so an interrupted first run is safe to repeat
tracked="$(psql "$@" -d "$DB" -Atqc "SELECT to_regclass('sys.schema_file') IS NOT NULL AND EXISTS (SELECT 1 FROM sys.schema_file)")"
psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$DIR/schema_file.sql"

# The record of applied files must still match the last release manifest (1058): a row added or removed by hand would
# make this upgrade skip or repeat files
if [ "$tracked" = "t" ] && [ "$(psql "$@" -d "$DB" -Atqc "SELECT to_regproc('sys.current_release') IS NOT NULL")" = "t" ]; then
  matches="$(psql "$@" -d "$DB" -Atqc "SELECT hash_matches FROM sys.current_release()")"
  if [ "$matches" = "f" ]; then
    echo "the record of applied schema files (sys.schema_file) differs from the last release manifest of $DB" >&2
    if [ "${MASSLAK_SCHEMA_DRIFT:-fail}" = warn ]; then
      echo "warning: continuing because MASSLAK_SCHEMA_DRIFT=warn (development databases only)" >&2
    else
      echo "upgrade refused: compare sys.schema_file with sys.release_manifest before going on. Nothing was applied." >&2
      exit 4
    fi
  fi
fi

# Drift check first, so a refused upgrade has changed nothing
if [ "$tracked" = "t" ]; then
  drift=""
  while IFS='|' read -r name done_sha; do
    f="$DIR/schema/$name"
    [ -f "$f" ] || continue                       # a file retired from the repository is not drift
    sha="$(sha256sum "$f" | cut -d' ' -f1)"
    [ "$done_sha" = "$sha" ] || drift="$drift $name"
  done < <(psql "$@" -d "$DB" -Atq -c "SELECT file || '|' || sha256 FROM sys.schema_file ORDER BY file")
  if [ -n "$drift" ]; then
    echo "schema files changed after they were applied to $DB:$drift" >&2
    if [ "${MASSLAK_SCHEMA_DRIFT:-fail}" = warn ]; then
      echo "warning: continuing because MASSLAK_SCHEMA_DRIFT=warn (development databases only)" >&2
    else
      echo "upgrade refused: restore these files from the release this database was built with and put the change in a" \
           "new file (db/README.md, Upgrades). Nothing was applied." >&2
      exit 3
    fi
  fi
fi

# a PostGIS the database image preloaded into public is moved out of the way of 1045 (see the file); no-op once 1045 ran
psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$DIR/postgis_prepare.sql"
for f in $(schema_files); do
  name="$(basename "$f")"; sha="$(sha256sum "$f" | cut -d' ' -f1)"
  if [ "$tracked" = "f" ] && [ "$((10#${name%%_*}))" -le "$BASELINE" ]; then
    record "$name" "$sha"
    continue
  fi
  done_sha="$(echo "SELECT sha256 FROM sys.schema_file WHERE file = :'file'" | psql "$@" -d "$DB" -Atq -v file="$name" -f -)"
  [ -n "$done_sha" ] && continue                 # applied before (any change to it was checked above)
  echo ">> $name"
  psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$f"
  record "$name" "$sha"
done
# constraints added NOT VALID are validated now, each in its own transaction (1082, H-09); one that old rows break stays
# NOT VALID, is named here, and /api/ready reports "constraints": false until the rows are fixed
psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -c "CALL sys.validate_constraints()"
left="$(psql "$@" -d "$DB" -Atq -c "SELECT string_agg(table_name || '.' || constraint_name, ', ') FROM sys.unvalidated_constraints()")"
[ -z "$left" ] || echo "warning: constraints not validated (existing rows break them): $left" >&2
commit="${MASSLAK_RELEASE_COMMIT:-$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo unknown)}"
echo "SELECT 1 FROM sys.record_release('UPGRADE', :'commit')" | psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -At -v commit="$commit" -f - >/dev/null
echo "OK: $DB is up to date"

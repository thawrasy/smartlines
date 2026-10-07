#!/usr/bin/env bash
# Applies schema files that an existing database has not run yet: ./db/upgrade.sh <database> [psql connection args]
#
# Files are applied in name order, each in its own transaction, and recorded in sys.schema_file. Upgrade files
# (980 onwards) must be idempotent (IF NOT EXISTS, ON CONFLICT DO NOTHING, DROP POLICY IF EXISTS ...).
# A database built before file tracking existed is assumed to have every file up to the baseline below.
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

# "tracked" only once at least one file is recorded, so an interrupted first run is safe to repeat
tracked="$(psql "$@" -d "$DB" -Atqc "SELECT to_regclass('sys.schema_file') IS NOT NULL AND EXISTS (SELECT 1 FROM sys.schema_file)")"
psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$DIR/schema_file.sql"
for f in $(schema_files); do
  name="$(basename "$f")"; sha="$(sha256sum "$f" | cut -d' ' -f1)"
  if [ "$tracked" = "f" ] && [ "$((10#${name%%_*}))" -le "$BASELINE" ]; then
    record "$name" "$sha"
    continue
  fi
  done_sha="$(echo "SELECT sha256 FROM sys.schema_file WHERE file = :'file'" | psql "$@" -d "$DB" -Atq -v file="$name" -f -)"
  if [ -n "$done_sha" ]; then
    [ "$done_sha" = "$sha" ] || echo "warning: $name changed after it was applied (upgrade files are never edited; add a new file)"
    continue
  fi
  echo ">> $name"
  psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$f"
  record "$name" "$sha"
done
echo "OK: $DB is up to date"

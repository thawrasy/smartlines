#!/usr/bin/env bash
# Builds the Masslak database from scratch: ./db/build.sh <database> [psql connection args]
# Every applied file is recorded in sys.schema_file, so ./db/upgrade.sh later applies only newer files.
set -euo pipefail
# Idempotent files print NOTICEs ("already exists, skipping"); show warnings and errors only
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning} -c masslak.migrating=on"   # schema changes are logged as migrations (1047)
# psql substitutes :'variables' only in scripts, not in -c, so the statement goes through stdin
record() { echo "INSERT INTO sys.schema_file (file, sha256) VALUES (:'file', :'sha') ON CONFLICT (file) DO NOTHING" |
           psql "${PSQL_ARGS[@]}" -d "$DB" -v ON_ERROR_STOP=1 -q -v file="$1" -v sha="$2" -f -; }
DB="${1:?database name}"; shift || true
PSQL_ARGS=("$@")
DIR="$(cd "$(dirname "$0")" && pwd)"
# Schema files in numeric order of their prefix (000 ... 990, 1000 ...), so numbering can grow past three digits
# MASSLAK_BUILD_UNTIL=<prefix> stops after that file, to build an older release (migration rehearsals, db/tools)
schema_files() { ls "$DIR"/schema/[0-9]*_*.sql | awk -F/ -v until="${MASSLAK_BUILD_UNTIL:-999999}" \
                   '{ n = $NF; sub(/_.*/, "", n); if (n + 0 <= until + 0) print n "\t" $0 }' | sort -n | cut -f2-; }
# a PostGIS the database image preloaded into public is moved out of the way of 1045 (see the file)
psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$DIR/postgis_prepare.sql"
for f in $(schema_files); do
  echo ">> $(basename "$f")"
  psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f"
done
psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$DIR/schema_file.sql"
for f in $(schema_files); do
  record "$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
done
# the release manifest (1058): version, commit and the hash of the applied files; older builds (MASSLAK_BUILD_UNTIL) skip it
commit="${MASSLAK_RELEASE_COMMIT:-$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo unknown)}"
if [ "$(psql "$@" -d "$DB" -Atqc "SELECT to_regproc('sys.record_release') IS NOT NULL")" = t ]; then
  echo "SELECT 1 FROM sys.record_release('BUILD', :'commit')" | psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -At -v commit="$commit" -f - >/dev/null
fi
echo "OK: schema built in $DB"

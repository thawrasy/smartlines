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
schema_files() { ls "$DIR"/schema/[0-9]*_*.sql | awk -F/ '{ n = $NF; sub(/_.*/, "", n); print n "\t" $0 }' | sort -n | cut -f2-; }
for f in $(schema_files); do
  echo ">> $(basename "$f")"
  psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f"
done
psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$DIR/schema_file.sql"
for f in $(schema_files); do
  record "$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
done
echo "OK: schema built in $DB"

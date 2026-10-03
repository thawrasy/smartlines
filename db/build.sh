#!/usr/bin/env bash
# يبني قاعدة بيانات مسلك من الصفر: ./db/build.sh <database> [psql connection args]
set -euo pipefail
DB="${1:?database name}"; shift || true
DIR="$(cd "$(dirname "$0")" && pwd)/schema"
for f in "$DIR"/[0-9][0-9][0-9]_*.sql; do
  echo ">> $(basename "$f")"
  psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f"
done
echo "OK: schema built in $DB"

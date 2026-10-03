#!/usr/bin/env bash
# Builds a fresh test database and runs the tests: ./db/tests/run.sh [psql connection args]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB="masslak_test_$$"
psql "$@" -q -c "CREATE DATABASE $DB" >/dev/null || exit 1
trap 'psql "$@" -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
"$ROOT/build.sh" "$DB" "$@" >/dev/null || { echo "=== BUILD FAILED ==="; exit 1; }
OUT="$(psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$ROOT/tests/run_tests.sql" 2>&1 >/dev/null)"; rc=$?
echo "$OUT" | sed -E 's/^(psql:[^ ]+ )?(NOTICE|ERROR): +//'
if [ $rc -eq 0 ]; then echo "=== ALL TESTS PASSED ($(echo "$OUT" | grep -c 'PASS ') checks) ==="; else echo "=== TESTS FAILED ==="; exit 1; fi

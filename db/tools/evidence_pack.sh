#!/usr/bin/env bash
# Raw evidence for the auditors (audit T3 recheck): everything they need to verify the candidate build themselves.
#   db/tools/evidence_pack.sh <database> <output dir> --db-log <db tests output> --api-log <pytest output> \
#                             [--tested <commit the logs come from>] [--junit <JUnit report>] [--coverage <coverage.json>]
#                             [--reviewer] [psql connection args]
# The pack holds:
#   source/       the commit, its tree hash and whether the working tree was clean; TESTED.txt proves the test logs belong to
#                 this commit: either the same commit, or every file changed since the tested commit is documentation
#   audit_pack/   schema, roles, grants, policies, functions, inventories, OpenAPI (db/tools/audit_pack.sh)
#   tests/        the full console output of the database checks and the API tests of this build, every test with its
#                 result (api_results.csv from the JUnit report), the coverage summary, and the test sources
#   critical/     the critical controls quoted from the code of this commit with the result of the tests that prove each
#                 (db/tools/critical_excerpts.py, docs/operations/evidence/critical_controls.json)
#   evidence/     restore drill, migration rehearsal, load tests (docs/operations/evidence) and the verification summary
#   monitoring/   alert rules, their unit tests and the promtool result
#   docs/         the audit responses, runbooks, SLOs, migration plans, release map, event contract, threat model
# plus SHA256SUMS over every file and a .tar.gz of the whole directory. No business rows, secrets or key material.
# --reviewer builds the edition handed to an independent reviewer without access to the repository (owner's decision,
# October 2026): no source files (test sources and the database checks' script are left out); the quoted excerpts of
# the critical controls, the test names and results, the logs and the measurements stay.
set -euo pipefail
DB="${1:?database}"; OUT="${2:?output directory}"; shift 2
DB_LOG=""; API_LOG=""; TESTED=""; JUNIT=""; COVERAGE=""; REVIEWER=0; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --db-log) DB_LOG="$2"; shift 2 ;;
    --api-log) API_LOG="$2"; shift 2 ;;
    --tested) TESTED="$2"; shift 2 ;;
    --junit) JUNIT="$2"; shift 2 ;;
    --coverage) COVERAGE="$2"; shift 2 ;;
    --reviewer) REVIEWER=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ -f "$DB_LOG" ] && [ -f "$API_LOG" ] || { echo "give --db-log and --api-log: the console output of this build's test runs" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
rm -rf "$OUT"; mkdir -p "$OUT"/{source,tests,evidence,monitoring,docs,critical}

# source: which code this is
{
  echo "commit: $(git -C "$ROOT" rev-parse HEAD)"
  echo "tree:   $(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
  echo "branch: $(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  if [ -z "$(git -C "$ROOT" status --porcelain)" ]; then echo "working tree: clean"; else echo "working tree: CHANGED (pack is not of a commit)"; fi
  echo "schema files: $(ls "$ROOT"/db/schema/[0-9]*_*.sql | wc -l), last: $(ls "$ROOT"/db/schema/[0-9]*_*.sql | awk -F/ '{n=$NF; sub(/_.*/,"",n); print n" "$NF}' | sort -n | tail -1 | cut -d' ' -f2)"
} > "$OUT/source/SOURCE.txt"

# an evidence pack is of a commit, never of uncommitted files
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || { echo "refusing: commit or stash the changes first" >&2; exit 4; }
# the logs must come from this code: the tested commit is HEAD, or nothing but documentation changed since
HEAD_C="$(git -C "$ROOT" rev-parse HEAD)"; TESTED_C="$(git -C "$ROOT" rev-parse "${TESTED:-HEAD}^{commit}")"
CHANGED="$(git -C "$ROOT" diff --name-only "$TESTED_C" "$HEAD_C")"
NOT_DOCS="$(printf '%s\n' "$CHANGED" | grep -v '^$' | grep -Ev '^docs/|\.md$' || true)"
{
  echo "tested commit: $TESTED_C"
  echo "pack commit:   $HEAD_C"
  if [ -z "$CHANGED" ]; then echo "verdict: SAME CODE (no file differs)"
  elif [ -z "$NOT_DOCS" ]; then echo "verdict: DOCUMENTATION ONLY since the tested commit"
  else echo "verdict: CODE CHANGED since the tested commit (the logs do not cover this pack)"; fi
  echo "files changed since the tested commit ($(printf '%s' "$CHANGED" | grep -c . || true)):"
  printf '%s\n' "$CHANGED" | grep -v '^$' | sed 's/^/  /' || true
} > "$OUT/source/TESTED.txt"
if [ -n "$NOT_DOCS" ]; then cat "$OUT/source/TESTED.txt" >&2; echo "refusing: run the tests on this commit" >&2; exit 3; fi

# structure and security of the built database (and the API's OpenAPI when it runs)
"$ROOT/db/tools/audit_pack.sh" "$DB" "$OUT/audit_pack" "${ARGS[@]}" > /dev/null

# tests: the raw output of this build, and the sources that produced it
cp "$DB_LOG" "$OUT/tests/db_tests.log"; cp "$API_LOG" "$OUT/tests/api_tests.log"
if [ "$REVIEWER" = 0 ]; then
  cp "$ROOT/db/tests/run_tests.sql" "$OUT/tests/"
  mkdir -p "$OUT/tests/api"; cp "$ROOT"/backend/tests/test_*.py "$OUT/tests/api/"
fi
grep -c '^PASS ' "$DB_LOG" > "$OUT/tests/db_checks_passed.txt" || true
# every API test with its result, and the coverage of this run
if [ -n "$JUNIT" ] && [ -f "$JUNIT" ]; then
  cp "$JUNIT" "$OUT/tests/api_junit.xml"
  python3 - "$JUNIT" "$OUT/tests/api_results.csv" <<'PY'
import csv, sys, xml.etree.ElementTree as ET
rows = []
for c in ET.parse(sys.argv[1]).getroot().iter("testcase"):
    status = "failed" if c.find("failure") is not None or c.find("error") is not None else "skipped" if c.find("skipped") is not None else "passed"
    rows.append((c.get("classname"), c.get("name"), status, c.get("time")))
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f); w.writerow(["file", "test", "result", "seconds"]); w.writerows(rows)
PY
fi
if [ -n "$COVERAGE" ] && [ -f "$COVERAGE" ]; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); json.dump({"totals": d["totals"], "files": {k: round(v["summary"]["percent_covered"], 1) for k, v in d["files"].items()}}, open(sys.argv[2], "w"), indent=1)' \
    "$COVERAGE" "$OUT/tests/coverage_summary.json"
fi

# the critical controls: their code as it is in this commit, and the result of the tests that prove each
python3 "$ROOT/db/tools/critical_excerpts.py" --out "$OUT/critical" --db-log "$DB_LOG" ${JUNIT:+--junit "$JUNIT"}

# measurements
cp "$ROOT"/docs/operations/evidence/*.json "$OUT/evidence/"
[ -f "$ROOT/docs/database/build/verification.json" ] && cp "$ROOT/docs/database/build/verification.json" "$OUT/evidence/"

# monitoring: rules, their unit tests, and promtool's verdict when promtool is installed
cp "$ROOT"/deploy/monitoring/*.yml "$ROOT"/deploy/monitoring/*.json "$OUT/monitoring/"
if command -v promtool > /dev/null; then
  (cd "$ROOT/deploy/monitoring" && promtool check rules alerts.yml && promtool test rules alerts_test.yml) > "$OUT/monitoring/promtool.txt" 2>&1 || true
fi

# documents the evidence refers to
for f in docs/database/DESIGN_AUDIT_T3.md docs/database/DESIGN_AUDIT_T3_RECHECK.md docs/database/THIRD_PARTY_AUDIT.md \
         docs/database/MIGRATION_PLANS.md docs/database/STANDARDS.md docs/operations/RUNBOOKS.md docs/operations/SLO.md \
         docs/operations/PERFORMANCE_BASELINE.md docs/operations/RELEASE_MAP.md docs/integration/EVENTS.md \
         docs/architecture/AI_ASSISTANT_THREAT_MODEL_DPIA.md docs/operations/LAUNCH_GATES.md docs/operations/STAGING.md docs/operations/CAPACITY_MODEL.md \
         docs/security/PENETRATION_TEST_SCOPE.md docs/database/ARCHITECTURE_REVIEW_RESPONSE.md \
         docs/database/SCHEMA_DEPENDENCIES.md db/schema_dependencies.json deploy/egress/squid.conf deploy/pitr/postgresql.pitr.conf deploy/pitr/pgbackrest.conf \
         deploy/staging/docker-compose.staging.yml deploy/staging/alertmanager.yml; do
  [ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$OUT/docs/"
done

( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "evidence pack: $OUT ($(find "$OUT" -type f | wc -l) files), archive $OUT.tar.gz, sha256 $(sha256sum "$OUT.tar.gz" | cut -d' ' -f1)"

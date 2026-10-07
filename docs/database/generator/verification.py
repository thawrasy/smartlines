"""Collects the verification evidence of a build into ../build/verification.json, so the design document states only numbers
that came from the run itself (audit T3-17): the test counts, the source commit, the last migration and schema file, a hash of
the schema, and the server and extension versions.

Usage (from this directory):
    python3 verification.py <database> --db-log <db tests output> --api-log <pytest output> [psql connection args...]

The logs are the console output of db/tests/run.sh ("=== ALL TESTS PASSED (N checks) ===") and of pytest -q ("N passed");
in CI they are the job logs of the same commit.
"""
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
BUILD = os.path.join(HERE, "..", "build")


def psql(db, args, sql):
    return subprocess.run(["psql", *args, "-d", db, "-At", "-c", sql], check=True, capture_output=True, text=True).stdout.strip()


def count(path, pattern, what):
    text = open(path, encoding="utf-8").read()
    found = re.findall(pattern, text)
    if not found:
        sys.exit(f"{path}: no {what} result found; pass the console output of the test run")
    return int(found[-1])


def main():
    argv = sys.argv[1:]
    if not argv or argv[0].startswith("-"):
        sys.exit(__doc__)
    db, rest, opts = argv[0], [], {}
    i = 1
    while i < len(argv):
        if argv[i] in ("--db-log", "--api-log"):
            opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            rest.append(argv[i])
            i += 1
    if set(opts) != {"--db-log", "--api-log"}:
        sys.exit(__doc__)
    if re.search(r"FAIL|TESTS FAILED", open(opts["--db-log"], encoding="utf-8").read()):
        sys.exit("the database test log reports failures")
    if re.search(r"\d+ failed", open(opts["--api-log"], encoding="utf-8").read()):
        sys.exit("the API test log reports failures")
    dump = subprocess.run(["pg_dump", *rest, "--schema-only", "--no-owner", "--no-privileges", "-d", db],
                          check=True, capture_output=True, text=True).stdout
    # the dump header names the tool version; the hash covers the schema only
    schema = "\n".join(line for line in dump.splitlines() if not line.startswith("-- Dumped "))
    files = sorted(os.listdir(os.path.join(ROOT, "db", "schema")), key=lambda f: int(f.split("_", 1)[0]))
    v = {
        "db_checks": count(opts["--db-log"], r"ALL TESTS PASSED \((\d+) checks\)", "database check"),
        "api_tests": count(opts["--api-log"], r"(\d+) passed", "pytest"),
        "source_commit": subprocess.run(["git", "-C", ROOT, "rev-parse", "--short=12", "HEAD"], check=True, capture_output=True,
                                        text=True).stdout.strip(),
        "migration": psql(db, rest, "SELECT version FROM sys.schema_migration ORDER BY string_to_array(version, '.')::int[] DESC LIMIT 1"),
        "last_schema_file": files[-1],
        "schema_files": len(files),
        "schema_sha256": hashlib.sha256(schema.encode()).hexdigest(),
        "postgres": psql(db, rest, "SHOW server_version"),
        "postgis": psql(db, rest, "SELECT extversion FROM pg_extension WHERE extname = 'postgis'") or None,
        "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
    }
    os.makedirs(BUILD, exist_ok=True)
    json.dump(v, open(os.path.join(BUILD, "verification.json"), "w"), indent=1)
    print(json.dumps(v, indent=1))


if __name__ == "__main__":
    main()

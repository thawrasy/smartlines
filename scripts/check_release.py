#!/usr/bin/env python3
"""One version for each release (independent review, round 9, MAN P1).

The repository's VERSION file names the release being built. This check fails when it is not a plain version, when the
highest version a schema file records in sys.schema_migration differs from it (the database would call the build by
another name: sys.record_release reads that table), or, given --tag, when the tag is not v<VERSION>.

    python3 scripts/check_release.py [--tag v1.51.0]
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
# a version written into sys.schema_migration by a schema file: INSERT ... (version, ...) ... '1.2.3'
RECORDED = re.compile(r"INSERT INTO sys\.schema_migration\b.*?;", re.S | re.I)
QUOTED = re.compile(r"'(\d+\.\d+\.\d+)'")


def key(v: str) -> tuple:
    return tuple(int(p) for p in v.split("."))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag")
    a = ap.parse_args()
    version = (ROOT / "VERSION").read_text().strip()
    problems = []
    if not SEMVER.match(version):
        problems.append(f"VERSION is {version!r}, not a version like 1.51.0")
    recorded = {}
    for f in sorted((ROOT / "db" / "schema").glob("*.sql")):
        for stmt in RECORDED.findall(f.read_text()):
            for v in QUOTED.findall(stmt):
                recorded.setdefault(v, f.name)
    if not recorded:
        problems.append("no schema file records a version in sys.schema_migration")
    elif SEMVER.match(version):
        top = max(recorded, key=key)
        if top != version:
            problems.append(f"the highest version a schema file records is {top} ({recorded[top]}), VERSION says {version}: "
                            "record the release in a schema file (as 1140 does) or correct VERSION")
    if a.tag and a.tag != f"v{version}":
        problems.append(f"the tag {a.tag} is not v{version} (VERSION)")
    for p in problems:
        print("release:", p, file=sys.stderr)
    if not problems:
        print(f"release {version}: VERSION, the schema files" + (f" and the tag {a.tag}" if a.tag else "") + " agree")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

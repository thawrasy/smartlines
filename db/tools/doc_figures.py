"""The figures the documents quote, from one source (independent review of 18 October 2026, plan item A1: no number in a
document unless a generator made it). Prints JSON; the generators of the study, the database design and the readiness
register read it instead of carrying numbers typed by hand.

    python3 db/tools/doc_figures.py [--verification <verification.json>] [--commit <commit>] [--coverage <coverage.json>]

From the verification of a test run (docs/database/generator/verification.py, or an evidence pack's
evidence/verification.json): the commit, database checks, API tests, schema files and the last one. From the built model
(docs/database/build/model.json): schemas, tables, columns, foreign keys. From the interface baseline
(docs/api/openapi-baseline.json): the operations. From git, at the same commit: the lines of each part of the code, all
lines of the tracked files under it. From the coverage report of the same run (--coverage): the line coverage.
"""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PARTS = {   # part -> (directory, file suffixes); every tracked file under the directory with one of the suffixes
    "server": ("backend/app", (".py",)),
    "server_tests": ("backend/tests", (".py",)),
    "schema": ("db/schema", (".sql",)),
    "db_checks": ("db/tests", (".sql", ".sh")),
    "web": ("frontend/src", (".ts", ".tsx", ".css")),
    "mobile": ("mobile/src", (".ts", ".tsx")),
}


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def lines_at(commit: str, directory: str, suffixes: tuple[str, ...]) -> tuple[int, int]:
    files = [f for f in git("ls-tree", "-r", "--name-only", commit, "--", directory).splitlines() if f.endswith(suffixes)]
    total = sum(git("show", f"{commit}:{f}").count("\n") for f in files)
    return total, len(files)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verification", default=str(ROOT / "docs/database/build/verification.json"))
    ap.add_argument("--commit", help="defaults to the verification's commit")
    ap.add_argument("--coverage", help="coverage.json (or an evidence pack's coverage_summary.json) of the same run")
    a = ap.parse_args()
    v = json.loads(Path(a.verification).read_text(encoding="utf-8"))
    commit = git("rev-parse", a.commit or v["source_commit"]).strip()
    model = json.loads((ROOT / "docs/database/build/model.json").read_text(encoding="utf-8"))
    api = json.loads((ROOT / "docs/api/openapi-baseline.json").read_text(encoding="utf-8"))
    tables = model["tables"]
    out = {
        "commit": commit, "commit_short": commit[:7],
        "db_checks": v["db_checks"], "api_tests": v["api_tests"], "schema_files": v["schema_files"],
        "last_schema_file": v["last_schema_file"].split("_")[0], "schema_sha256": v["schema_sha256"],
        "schemas": len({t["schema"] for t in tables}), "tables": len(tables),
        "columns": sum(len(t["columns"]) for t in tables), "foreign_keys": sum(len(t.get("fks") or []) for t in tables),
        "operations_app": len(api["app"]), "operations_partner": len(api["v1"]),
        "lines": {},
    }
    if a.coverage:
        out["coverage"] = json.loads(Path(a.coverage).read_text(encoding="utf-8"))["totals"]["percent_covered_display"]
    for part, (directory, suffixes) in PARTS.items():
        n, files = lines_at(commit, directory, suffixes)
        out["lines"][part] = {"lines": n, "files": files}
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()

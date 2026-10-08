#!/usr/bin/env python3
"""Renders docs/database/INVARIANTS.md from docs/database/invariants.json (expert review of October 2026, stage C5).

Usage:
    python3 db/tools/gen_invariants.py           writes the file
    python3 db/tools/gen_invariants.py --check   fails when the file is out of date (CI)
The names in the matrix are checked against the code, the tests and the built database by
backend/tests/test_invariants.py.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(ROOT, "docs", "database", "invariants.json")
TARGET = os.path.join(ROOT, "docs", "database", "INVARIANTS.md")


def cell(items: list) -> str:
    return "<br>".join(f"`{i}`" for i in items) or "-"


def render(matrix: dict) -> str:
    rules = matrix["rules"]
    counts = {o: sum(r["owner"] == o for r in rules) for o in matrix["owners"]}
    out = [
        "# Business rules and who keeps them",
        "",
        "Generated from `invariants.json` by `db/tools/gen_invariants.py`; edit the JSON, not this file.",
        "",
        matrix["about"],
        "",
        "| Owner | Meaning | Rules |",
        "|---|---|---|",
    ]
    out += [f"| {o} | {meaning} | {counts[o]} |" for o, meaning in matrix["owners"].items()]
    out += ["", "## Summary", "", "| Rule | Owner | Database tests | API tests |", "|---|---|---|---|"]
    out += [f"| [{r['id']}](#{r['id'].lower()}) | {r['owner']} | {len(r['tests']['db'])} | {len(r['tests']['api'])} |"
            for r in rules]
    for r in rules:
        out += ["", f"## {r['id']}", "", r["rule"], "", f"**Owner:** {r['owner']}. {r['why']}", "",
                "| Kept by | Names |", "|---|---|",
                f"| Database | {cell(r['database'])} |",
                f"| Application | {cell(r['application'])} |",
                f"| Database tests (`db/tests/run_tests.sql`) | {'<br>'.join(r['tests']['db']) or '-'} |",
                f"| API tests (`backend/`) | {cell(r['tests']['api'])} |"]
    return "\n".join(out) + "\n"


def main() -> int:
    with open(SOURCE, encoding="utf-8") as f:
        text = render(json.load(f))
    if "--check" in sys.argv[1:]:
        current = open(TARGET, encoding="utf-8").read() if os.path.exists(TARGET) else ""
        if current != text:
            print(f"{os.path.relpath(TARGET, ROOT)} is out of date: run python3 db/tools/gen_invariants.py", file=sys.stderr)
            return 1
        print("OK: INVARIANTS.md matches invariants.json")
        return 0
    with open(TARGET, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {os.path.relpath(TARGET, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

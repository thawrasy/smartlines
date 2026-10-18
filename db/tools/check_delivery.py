"""Checks a delivery to the independent reviewer before it is handed over (independent review of 18 October 2026: one number
per measure, one commit in every file): each Word document must name the commit of the evidence pack's verification and
state its figures, and the pack's own files must agree with each other.

    python3 db/tools/check_delivery.py <unpacked evidence pack> <document.docx>...

From the pack: evidence/verification.json (the commit the tests ran at, database checks, API tests, schema files) and
critical/critical_controls.json (its commit). Each document must contain the short commit and the database check, API test
and schema file counts of the verification. Exits 1 and lists what is missing; a document may also cite earlier figures
(a history of versions), so only the presence of the current ones is required.
"""
from __future__ import annotations

import json
import re
import sys
import zipfile
from pathlib import Path


def docx_text(path: Path) -> str:
    xml = zipfile.ZipFile(path).read("word/document.xml").decode("utf-8")
    return re.sub(r"<[^>]+>", "", xml)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    pack, docs = Path(argv[0]), [Path(p) for p in argv[1:]]
    v = json.loads((pack / "evidence" / "verification.json").read_text(encoding="utf-8"))
    crit = json.loads((pack / "critical" / "critical_controls.json").read_text(encoding="utf-8"))
    commit = v["source_commit"][:7]
    problems = []
    if not crit["commit"].startswith(commit):
        problems.append(f"pack: critical controls are of {crit['commit'][:12]}, the verification of {v['source_commit']}")
    if crit.get("problems"):
        problems.append(f"pack: critical controls report {len(crit['problems'])} problem(s)")
    want = {"commit": commit, "database checks": str(v["db_checks"]), "API tests": str(v["api_tests"]),
            "schema files": str(v["schema_files"])}
    for d in docs:
        text = docx_text(d)
        for what, value in want.items():
            if value not in text:
                problems.append(f"{d.name}: does not state the {what} of the pack ({value})")
    for p in problems:
        print(p, file=sys.stderr)
    print(f"delivery check: {len(docs)} document(s) against commit {commit}, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""Checks a delivery to the independent reviewer before it is handed over (independent review of 18 October 2026: one number
per measure, one commit in every file): each Word document must name the commit of the evidence pack's verification and
state its figures, and the pack's own files must agree with each other.

    python3 db/tools/check_delivery.py <unpacked evidence pack> <document.docx>...

From the pack: evidence/verification.json (the commit the tests ran at, database checks, API tests, schema files) and
critical/critical_controls.json (its commit). Each document must contain the short commit and the database check, API test
and schema file counts of the verification. Exits 1 and lists what is missing.

A document may also cite earlier figures, but only as history (independent review, round 8, T-01 to T-03): a figure of
database checks, API tests, schema files or tables that differs from the pack's must sit in a historical chapter (one
whose first paragraph begins "Historical record", or a "Changes in version" chapter after the newest one) or in a
paragraph that dates it (an earlier schema file, another commit, a release, a study or design version, a delivery).
Anywhere else it reads as the present, and the delivery is refused.
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


FIGURES = [   # (what, pattern whose first group is the figure)
    ("database checks", r"(\d[\d,]*) database checks"), ("API tests", r"(\d[\d,]*) API tests"),
    ("schema files", r"(\d[\d,]*) schema files"), ("tables", r"[Rr]ow-level security on (?:all |every )?(\d[\d,]*) tables"),
    ("tables", r"(\d[\d,]*) tables in \d+ schemas"), ("tables", r"\d+ schemas and (\d[\d,]*) tables"),
    ("database checks", r"(\d[\d,]*) \u0641\u062d\u0635(?:\u0627\u064b)? (?:\u0644\u0644\u0642\u0627\u0639\u062f\u0629|\u0642\u0627\u0639\u062f\u0629)"), ("API tests", r"(\d[\d,]*) \u0627\u062e\u062a\u0628\u0627\u0631(?:\u0627\u064b)? \u0644\u0644\u062e\u0627\u062f\u0645"),
    ("schema files", r"(\d[\d,]*) \u0645\u0644\u0641(?:\u0627\u064b)? (?:\u0644\u0644\u0642\u0627\u0639\u062f\u0629|\u0645\u062e\u0637\u0637)"), ("tables", r"(\d[\d,]*) \u062c\u062f\u0648\u0644(?:\u0627\u064b)? \u0641\u064a \d+ \u0645\u062e\u0637\u0637"),
]


def paragraphs(path: Path) -> list[tuple[bool, str]]:
    """(is a level-1 heading, text) of each paragraph of a Word document."""
    xml = zipfile.ZipFile(path).read("word/document.xml").decode("utf-8")
    out = []
    for p in re.findall(r"<w:p[ >].*?</w:p>", xml, flags=re.S):
        heading = bool(re.search(r'<w:pStyle w:val="(?:Heading1|heading1|1)"', p)) or '<w:outlineLvl w:val="0"/>' in p
        out.append((heading, re.sub(r"<[^>]+>", "", p)))
    return out


def current_figures_misstated(path: Path, want: dict[str, str], commit: str, last_file: str) -> list[str]:
    """Figures stated as the present that differ from the pack's (see the module's description)."""
    paras = paragraphs(path)
    problems, historical, seen_changes, chapter = [], False, False, ""
    dated = re.compile(r"schema file (\d{3,4})|\u0645\u0644\u0641 (?:\u0627\u0644\u0642\u0627\u0639\u062f\u0629|\u0627\u0644\u0645\u062e\u0637\u0637) (\d{3,4})|commit ([0-9a-f]{7})|\u0627\u0644\u0627\u0644\u062a\u0632\u0627\u0645 ([0-9a-f]{7})|"
                       r"release \d+\.\d+|(?:study|design|version|register) \d+\.\d+|delivery \d|\u0627\u0644\u0625\u0635\u062f\u0627\u0631 \d|\u0627\u0644\u062a\u0633\u0644\u064a\u0645 (?:\u0627\u0644\u0623\u0648\u0644|\u0627\u0644\u062b\u0627\u0646\u064a|\u0627\u0644\u062b\u0627\u0644\u062b|\d)|"
                       r"(?:\u0627\u0644\u062f\u0631\u0627\u0633\u0629|\u062a\u0635\u0645\u064a\u0645 \u0627\u0644\u0642\u0627\u0639\u062f\u0629) \d+\.\d+")
    for i, (heading, text) in enumerate(paras):
        if heading:
            chapter = text.strip()
            if chapter.startswith("Changes in version"):
                historical, seen_changes = seen_changes, True     # the newest changes chapter comes first
            else:
                historical = False
            nxt = next((t for h, t in paras[i + 1:] if t.strip()), "")
            if nxt.startswith(("Historical record", "\u0633\u062c\u0644 \u062a\u0627\u0631\u064a\u062e\u064a")):
                historical = True
            continue
        if historical:
            continue
        for what, rx in FIGURES:
            for m in re.finditer(rx, text):
                if m.group(1).replace(",", "") == want[what]:
                    continue
                marks = [x for g in dated.finditer(text) for x in g.groups() if x] + \
                        [g.group(0) for g in dated.finditer(text) if not any(g.groups())]
                if any(x not in (last_file, commit) for x in marks):
                    continue                                  # the paragraph dates its figures
                problems.append(f"{path.name}: \"{m.group(0)}\" under \"{chapter[:60]}\" reads as the present "
                                f"(the pack has {want[what]} {what})")
    return problems


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
    present = dict(want, tables=str(v.get("tables", "")))
    for d in docs:
        text = docx_text(d)
        for what, value in want.items():
            if value not in text:
                problems.append(f"{d.name}: does not state the {what} of the pack ({value})")
        if v.get("tables"):
            problems += current_figures_misstated(d, present, commit, v["last_schema_file"].split("_")[0])
    for p in problems:
        print(p, file=sys.stderr)
    print(f"delivery check: {len(docs)} document(s) against commit {commit}, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

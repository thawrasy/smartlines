"""Quotes the code and the tests of the critical controls for an evidence pack (evaluation reports of October 2026, TEM
R-15): every claim that a control is closed comes with the code that enforces it and the result of the tests that prove
it, from the same commit, instead of a file path alone.

    python3 db/tools/critical_excerpts.py --out <dir> [--junit junit.xml]... [--db-log db_tests.log] [--commit <tested commit>]

The controls are listed in docs/operations/evidence/critical_controls.json. A Python function is quoted from its file
(ast); a SQL function from the last schema file that defines it. A test reference is either "<file>::" (every test of a
backend test file, results from the JUnit report) or "db:<prefix>" (every database check whose name starts so, results
from the db/tests output). Several JUnit reports may be given: a test the suite skips and a later step runs (the live
event contract check, MASSLAK_EVENT_CONTRACTS_LIVE) counts once, as run. Writes CRITICAL_CONTROLS.md and
critical_controls.json with passed, skipped and failed per control; exits 1 when a quoted symbol is missing or a test of
a critical control failed or was skipped (independent review of 18 October 2026: a skipped test proves nothing).
"""
from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET  # noqa: S405 - the JUnit report of this run, not outside input
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTROLS = ROOT / "docs" / "operations" / "evidence" / "critical_controls.json"
THREATS = ROOT / "docs" / "operations" / "evidence" / "threat_control_map.json"


def python_excerpt(rel: str, symbol: str) -> tuple[str, int, int]:
    src = (ROOT / rel).read_text(encoding="utf-8")
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == symbol:
            start = node.decorator_list[0].lineno if node.decorator_list else node.lineno
            lines = src.splitlines()[start - 1:node.end_lineno]
            return "\n".join(lines), start, node.end_lineno
    raise LookupError(f"{rel}: no function {symbol}")


def sql_excerpt(name: str) -> tuple[str, str]:
    schema, fn = name.split(".")
    pattern = re.compile(r"^CREATE (?:OR REPLACE )?FUNCTION " + re.escape(schema) + r"\." + re.escape(fn) + r"\(", re.M)
    found = None
    for f in sorted((ROOT / "db" / "schema").glob("[0-9]*_*.sql"), key=lambda p: int(p.name.split("_")[0])):
        text = f.read_text(encoding="utf-8")
        for m in pattern.finditer(text):
            end = re.search(r"^\$\$;|^END \$\$;", text[m.start():], re.M)
            body = text[m.start():m.start() + end.end()] if end else text[m.start():m.start() + 4000]
            found = (f.name, body)
    if not found:
        raise LookupError(f"no SQL function {name}")
    return found


def junit_results(paths: list[Path]) -> dict[str, str]:
    out: dict[str, str] = {}
    for path in paths:
        if not path.exists():
            continue
        for case in ET.parse(path).getroot().iter("testcase"):  # noqa: S314
            file = (case.get("file") or case.get("classname", "").replace(".", "/") + ".py").split("/")[-1]
            status = "failed" if case.find("failure") is not None or case.find("error") is not None else \
                "skipped" if case.find("skipped") is not None else "passed"
            key = f"{file}::{case.get('name')}"
            if out.get(key) in (None, "skipped"):
                out[key] = status
    return out


def db_results(path: Path | None) -> dict[str, str]:
    if not path or not path.exists():
        return {}
    out = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^(PASS|FAIL)\s+(.*)$", line.strip())
        if m:
            out[m.group(2).split(" — ")[0].strip()] = "passed" if m.group(1) == "PASS" else "failed"
    return out


def threat_map(out: Path, results: dict[str, dict], commit: str) -> list[str]:
    """critical/THREAT_CONTROL_MAP.md: each threat with the controls that answer it and their test results in this run
    (independent review, round 8, T-04). A threat with neither a control nor a launch gate, an unknown control, or a
    control none of whose tests passed is a problem."""
    if not THREATS.exists():
        return []
    spec = json.loads(THREATS.read_text(encoding="utf-8"))
    md = [f"# Threats and the controls that answer them, at commit {commit}", "",
          "From docs/operations/evidence/threat_control_map.json; the test counts are those of CRITICAL_CONTROLS.md.", "",
          "| Threat | Controls (tests passed of run) | Gate |", "|---|---|---|"]
    problems = []
    for t in spec["threats"]:
        cells = []
        for cid in t["controls"]:
            r = results.get(cid)
            if r is None:
                problems.append(f"{t['id']}: unknown control {cid}")
                continue
            cells.append(f"{cid} ({r['passed']} of {r['tests']})")
            if not r["passed"]:
                problems.append(f"{t['id']}: control {cid} has no passing test")
        if not t["controls"] and not t.get("gate"):
            problems.append(f"{t['id']}: no control and no launch gate")
        md.append(f"| {t['id']} {t['threat']} | {', '.join(cells) or '-'} | {t.get('gate', '')} |")
    (out / "THREAT_CONTROL_MAP.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--junit", action="append", default=[])
    ap.add_argument("--db-log")
    ap.add_argument("--commit", default="HEAD", help="the commit the test results come from")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    junit = junit_results([Path(j) for j in a.junit])
    dbr = db_results(Path(a.db_log) if a.db_log else None)
    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", a.commit], capture_output=True, text=True).stdout.strip()
    spec = json.loads(CONTROLS.read_text(encoding="utf-8"))
    md = [f"# Critical controls: code and tests at commit {commit}", "",
          "Each control is quoted from the code of this commit, with the tests that prove it and their result in this run.", ""]
    summary, problems = [], []
    for c in spec["controls"]:
        md += [f"## {c['id']} {c['control']}", ""]
        for ref in c["code"]:
            try:
                if "python" in ref:
                    code, s, e = python_excerpt(ref["python"], ref["symbol"])
                    md += [f"`{ref['python']}` lines {s}-{e}, `{ref['symbol']}`:", "", "```python", code, "```", ""]
                else:
                    file, code = sql_excerpt(ref["sql"])
                    md += [f"`db/schema/{file}`, `{ref['sql']}`:", "", "```sql", code, "```", ""]
            except LookupError as e:
                problems.append(f"{c['id']}: {e}")
                md += [f"**Missing:** {e}", ""]
        tests = {}
        for t in c["tests"]:
            if t.startswith("db:"):
                tests.update({k: v for k, v in dbr.items() if k.startswith(t[3:])})
            else:
                tests.update({k: v for k, v in junit.items() if k.startswith(t)})
        failed = [k for k, v in tests.items() if v == "failed"]
        skipped = [k for k, v in tests.items() if v == "skipped"]
        if junit and dbr and not tests:
            problems.append(f"{c['id']}: no test result in this run for {', '.join(c['tests'])}")
        problems += [f"{c['id']}: test failed: {k}" for k in failed]
        problems += [f"{c['id']}: test skipped: {k}" for k in skipped]
        passed = sum(v == "passed" for v in tests.values())
        md += [f"Tests ({len(tests)}: {passed} passed, {len(skipped)} skipped, {len(failed)} failed):", ""]
        md += [f"- {'PASS' if v == 'passed' else v.upper()} `{k}`" for k, v in sorted(tests.items())] or ["- (no result in this run)"]
        md.append("")
        summary.append({"id": c["id"], "control": c["control"], "tests": len(tests), "passed": passed, "skipped": skipped,
                        "failed": failed})
    (out / "CRITICAL_CONTROLS.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    problems += threat_map(out, {c["id"]: c for c in summary}, commit)
    (out / "critical_controls.json").write_text(json.dumps({"commit": commit, "controls": summary, "problems": problems},
                                                           indent=1) + "\n", encoding="utf-8")
    for p in problems:
        print(p, file=sys.stderr)
    print(f"critical controls: {len(summary)} quoted in {out}, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

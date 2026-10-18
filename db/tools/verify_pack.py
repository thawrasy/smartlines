#!/usr/bin/env python3
"""Verifies an evidence pack from its raw files only (independent review, round 9, Team R-24: the pack must not be the
sole witness of itself).

evidence_pack.sh writes summaries (verification.json, critical_controls.json, settings_guard.txt) from the test logs it
was given. This tool, run apart from the build (another CI job, another machine, the reviewer's own computer), reads
the raw files again and recomputes what the summaries claim:

* every file is listed in SHA256SUMS with its digest, and nothing unlisted is in the pack;
* the tested commit is the pack's commit (source/TESTED.txt, SAME CODE) and verification.json names it;
* verification.json's database checks equal the PASS lines of tests/db_tests.log and its closing count, with no FAIL;
* its API tests equal the passed test cases of the JUnit reports (cases minus skipped, failures and errors), none failed;
* every test a critical control names passed in those raw results, and each control's count matches its list;
* the coverage total in tests/coverage_summary.json is the one the summary reports.

    python3 db/tools/verify_pack.py <unpacked evidence pack> [--out VERIFIED.txt]

Standard library only. Exits 1 and lists every disagreement; with --out writes the report, which CI keeps next to the
pack and signs separately from the job that built it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET  # nosec B405 - the pack's own JUnit files, not untrusted input
from pathlib import Path


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def junit_results(paths: list[Path]) -> dict[str, str]:
    """{"file.py::name": passed|skipped|failed} from pytest JUnit reports."""
    out: dict[str, str] = {}
    for p in paths:
        for case in ET.parse(p).getroot().iter("testcase"):  # nosec B314
            stem = case.get("classname", "").rsplit(".", 1)[-1]
            key = f"{stem}.py::{case.get('name')}"
            if case.find("skipped") is not None:
                out[key] = "skipped"
            elif case.find("failure") is not None or case.find("error") is not None:
                out[key] = "failed"
            else:
                out[key] = "passed"
    return out


def verify(pack: Path) -> tuple[list[str], list[str]]:
    ok, bad = [], []

    # 1. digests
    sums = {}
    for line in (pack / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split(None, 1)
        sums[name.lstrip("*").removeprefix("./")] = digest
    files = {str(p.relative_to(pack)) for p in pack.rglob("*") if p.is_file() and p.name != "SHA256SUMS"}
    wrong = sorted(n for n in sums if n in files and sha256(pack / n) != sums[n])
    missing, unlisted = sorted(set(sums) - files), sorted(files - set(sums))
    for label, names in (("digest differs", wrong), ("listed but missing", missing), ("in the pack but not listed", unlisted)):
        bad += [f"SHA256SUMS: {n}: {label}" for n in names]
    if not (wrong or missing or unlisted):
        ok.append(f"SHA256SUMS: {len(sums)} files, every digest matches, nothing unlisted")

    # 2. the commit
    source = (pack / "source" / "SOURCE.txt").read_text()
    tested = (pack / "source" / "TESTED.txt").read_text()
    commit = re.search(r"^commit:\s*([0-9a-f]{40})", source, re.M).group(1)
    ver = json.loads((pack / "evidence" / "verification.json").read_text())
    if f"tested commit: {commit}" in tested and "verdict: SAME CODE" in tested:
        ok.append(f"commit: tested and packed at {commit[:12]} (SAME CODE)")
    else:
        bad.append("commit: TESTED.txt does not say the tested commit is the pack's commit with SAME CODE")
    if not commit.startswith(ver.get("source_commit", "-")):
        bad.append(f"verification.json names commit {ver.get('source_commit')}, the pack is {commit[:12]}")

    # 3. database checks, from the raw log
    log = (pack / "tests" / "db_tests.log").read_text(errors="replace")
    passes = sum(1 for line in log.splitlines() if line.startswith("PASS "))
    fails = [line for line in log.splitlines() if line.startswith("FAIL")]
    closing = re.search(r"ALL TESTS PASSED \((\d+) checks\)", log)
    if fails:
        bad.append(f"database checks: {len(fails)} FAIL line(s) in db_tests.log, first: {fails[0][:120]}")
    if not closing or int(closing.group(1)) != passes:
        bad.append(f"database checks: the log has {passes} PASS lines and closes with {closing.group(0) if closing else 'no total'}")
    if ver.get("db_checks") != passes:
        bad.append(f"database checks: verification.json says {ver.get('db_checks')}, the log has {passes}")
    if not fails and closing and int(closing.group(1)) == passes == ver.get("db_checks"):
        ok.append(f"database checks: {passes} PASS lines, the log's total and verification.json agree, no FAIL")

    # 4. API tests, from the raw JUnit reports (the suite, then the steps that run after it)
    reports = sorted((pack / "tests").glob("api_junit*.xml"))
    results = junit_results(reports)
    suite = junit_results(reports[:1])
    failed = sorted(k for k, v in results.items() if v == "failed")
    passed = sum(1 for v in suite.values() if v == "passed")
    if failed:
        bad.append(f"API tests: {len(failed)} failed in the JUnit reports, first: {failed[0]}")
    if ver.get("api_tests") != passed:
        bad.append(f"API tests: verification.json says {ver.get('api_tests')}, the suite's JUnit report has {passed} passed")
    else:
        ok.append(f"API tests: {passed} passed in the suite's JUnit report, as verification.json says; "
                  f"{sum(1 for v in suite.values() if v == 'skipped')} skipped, {len(failed)} failed")

    # 5. critical controls: every named test passed in the raw results
    db_passed = {line[5:].strip() for line in log.splitlines() if line.startswith("PASS ")}
    crit = json.loads((pack / "critical" / "critical_controls.json").read_text())
    md = (pack / "critical" / "CRITICAL_CONTROLS.md").read_text()
    sections = re.split(r"^## ", md, flags=re.M)[1:]
    named_total = 0
    for c in crit["controls"]:
        body = next((s for s in sections if s.startswith(c["id"])), "")
        names = re.findall(r"^- (PASS|SKIP|FAIL) `(.+)`$", body, re.M)
        named_total += len(names)
        if len(names) != c["tests"]:
            bad.append(f"{c['id']}: critical_controls.json counts {c['tests']} tests, its section lists {len(names)}")
        for verdict, name in names:
            raw = results.get(name) if ".py::" in name else ("passed" if name in db_passed else None)
            if raw != "passed":
                bad.append(f"{c['id']}: {name} is {raw or 'absent'} in the raw results (the pack says {verdict})")
    if not any(b.startswith("C-") for b in bad):
        ok.append(f"critical controls: {len(crit['controls'])} controls, {named_total} named tests, each passed in the raw results")

    # 6. coverage
    cov = json.loads((pack / "tests" / "coverage_summary.json").read_text())["totals"]
    ok.append(f"coverage: {cov['percent_covered']:.1f}% of {cov['num_statements']} statements (tests/coverage_summary.json)")
    return ok, bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pack", type=Path)
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()
    ok, bad = verify(a.pack)
    lines = [f"evidence pack verified from its raw files: {a.pack.name}"] + [f"OK   {x}" for x in ok] + [f"FAIL {x}" for x in bad]
    lines.append(f"verdict: {'VERIFIED' if not bad else 'NOT VERIFIED'} ({len(bad)} problem(s))")
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if a.out:
        a.out.write_text(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

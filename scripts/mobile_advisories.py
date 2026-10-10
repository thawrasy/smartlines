#!/usr/bin/env python3
"""The mobile apps' advisories against their register (reviews of October 2026, M-11).

    npm audit --json > audit.json        (in mobile/; npm exits 1 when it finds advisories)
    python3 scripts/mobile_advisories.py audit.json [BUNDLE_DIR ...]

mobile/advisories.json classes every advisory npm audit reports as build (tooling on the build machine) or runtime
(shipped in the app). This check fails when
  * a high or critical advisory is not in the register;
  * a runtime advisory at high or above has no dated acceptance (accepted_by): it is fixed, not lived with;
  * an entry is past its review date (review_by);
  * a package classed build appears in an app bundle: each BUNDLE_DIR is the output of `expo export --source-maps`,
    whose source maps list every file the app carries.
An advisory below high missing from the register, or an entry npm audit no longer reports, is printed as a note.
Exit status 0 when the register holds, 1 otherwise.
"""
from __future__ import annotations

import datetime as dt
import json
import sys
from pathlib import Path

REGISTER = Path(__file__).resolve().parents[1] / "mobile" / "advisories.json"
SERIOUS = {"high", "critical"}


def reported(audit: dict) -> dict[str, dict]:
    """advisory id -> {package, severity, title}: the leaves of npm audit's tree, where an advisory is named."""
    out: dict[str, dict] = {}
    for name, vuln in (audit.get("vulnerabilities") or {}).items():
        for via in vuln.get("via") or []:
            if isinstance(via, dict) and via.get("url"):
                ident = via["url"].rstrip("/").rsplit("/", 1)[-1]
                out[ident] = {"package": via.get("name") or name, "severity": via.get("severity", "unknown"),
                              "title": via.get("title", "")}
    return out


def bundled_packages(bundle_dirs: list[Path]) -> set[str]:
    """The npm packages whose files the app bundles carry, from their source maps."""
    found: set[str] = set()
    for root in bundle_dirs:
        for source_map in root.rglob("*.map"):
            for src in json.loads(source_map.read_text()).get("sources", []):
                if "node_modules/" not in src:
                    continue
                parts = src.rsplit("node_modules/", 1)[1].split("/")
                found.add("/".join(parts[:2]) if parts[0].startswith("@") else parts[0])
    return found


def check(audit: dict, register: dict, bundles: set[str] | None, today: dt.date) -> tuple[list[str], list[str]]:
    problems, notes = [], []
    entries = {e["id"]: e for e in register.get("advisories", [])}
    found = reported(audit)
    for ident, adv in sorted(found.items()):
        entry = entries.get(ident)
        if entry is None:
            line = f"{ident} ({adv['package']}, {adv['severity']}) is not classed in mobile/advisories.json: {adv['title']}"
            (problems if adv["severity"] in SERIOUS else notes).append(line)
            continue
        if entry.get("class") not in ("build", "runtime"):
            problems.append(f"{ident} ({adv['package']}) is classed {entry.get('class')!r}: build or runtime")
        if entry.get("class") == "runtime" and adv["severity"] in SERIOUS and not entry.get("accepted_by"):
            problems.append(f"{ident} ({adv['package']}, {adv['severity']}) ships in the app and nobody accepted it: "
                            "upgrade, or record who accepts it until when (accepted_by, review_by)")
    for ident, entry in sorted(entries.items()):
        try:
            due = dt.date.fromisoformat(entry.get("review_by", ""))
        except ValueError:
            problems.append(f"{ident} has no review date (review_by, YYYY-MM-DD)")
            continue
        if due < today:
            problems.append(f"{ident} ({entry.get('package')}) was due for review on {due}: check its class and the upgrade")
        if ident not in found:
            notes.append(f"{ident} ({entry.get('package')}) is no longer reported: its entry can go")
        if bundles is not None and entry.get("class") == "build" and entry.get("package") in bundles:
            problems.append(f"{ident}: {entry.get('package')} is classed build but the app bundle carries it: class it runtime")
    return problems, notes


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    audit = json.loads(Path(argv[0]).read_text())
    register = json.loads(REGISTER.read_text())
    bundle_dirs = [Path(p) for p in argv[1:]]
    bundles = bundled_packages(bundle_dirs) if bundle_dirs else None
    if bundle_dirs and not bundles:
        print("no source maps in the bundles given: export with --source-maps", file=sys.stderr)
        return 1
    problems, notes = check(audit, register, bundles, dt.date.today())
    for n in notes:
        print(f"note: {n}")
    for p in problems:
        print(f"refused: {p}", file=sys.stderr)
    counts = {}
    for adv in reported(audit).values():
        counts[adv["severity"]] = counts.get(adv["severity"], 0) + 1
    print(f"mobile advisories: {counts or 'none'}; register: {len(register.get('advisories', []))} entries"
          + (f"; {len(bundles)} packages in the bundles" if bundles is not None else ""))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

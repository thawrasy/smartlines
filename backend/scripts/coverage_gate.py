"""Test coverage gate (review of release 1.47.0, R-52).

Reads coverage.json (python -m coverage json) and backend/coverage-thresholds.json, and fails when:
  * the total line coverage falls below its minimum;
  * a module that moves money, signs people in or keeps tenants apart falls below its own minimum;
  * an exception has passed its expiry date, or names no owner or reason.

Minimums are a ratchet: raise them when coverage grows, never lower them without an exception that names who accepted
it and until when. Usage: python scripts/coverage_gate.py [coverage.json] [coverage-thresholds.json]
"""
import json
import sys
from datetime import date
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]


def gate(report: dict, rules: dict, today: date) -> list[str]:
    problems = []
    exceptions = {}
    for e in rules.get("exceptions", []):
        if not e.get("owner") or not e.get("reason") or not e.get("until"):
            problems.append(f"exception for {e.get('file')}: owner, reason and until are required")
            continue
        if date.fromisoformat(e["until"]) < today:
            problems.append(f"exception for {e['file']} expired on {e['until']} (owner {e['owner']})")
            continue
        exceptions[e["file"]] = e
    total = report["totals"]["percent_covered"]
    if total + 1e-9 < rules["total"]:
        problems.append(f"total coverage {total:.1f}% is below the minimum {rules['total']}%")
    files = report["files"]
    for name, minimum in sorted(rules.get("files", {}).items()):
        if name in exceptions:
            minimum = exceptions[name]["minimum"]
        got = files.get(name, {}).get("summary", {}).get("percent_covered")
        if got is None:
            problems.append(f"{name}: not measured (renamed or moved? update coverage-thresholds.json)")
        elif got + 1e-9 < minimum:
            problems.append(f"{name}: {got:.1f}% is below its minimum {minimum}%")
    return problems


def main(argv: list[str]) -> int:
    report = json.loads(Path(argv[1] if len(argv) > 1 else BACKEND / "coverage.json").read_text(encoding="utf-8"))
    rules = json.loads(Path(argv[2] if len(argv) > 2 else BACKEND / "coverage-thresholds.json").read_text(encoding="utf-8"))
    problems = gate(report, rules, date.today())
    total = report["totals"]["percent_covered"]
    print(f"total line coverage {total:.1f}% (minimum {rules['total']}%), {len(rules.get('files', {}))} critical modules checked")
    for p in problems:
        print("FAIL", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

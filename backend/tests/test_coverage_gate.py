"""The coverage gate (review of release 1.47.0, R-52): a module that moves money, signs people in or keeps tenants apart
cannot lose its tests silently, and an exception to a minimum carries an owner, a reason and an end date."""
import importlib.util
import json
from datetime import date
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("coverage_gate", BACKEND / "scripts" / "coverage_gate.py")
gate_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate_module)


def report(total: float, **files: float) -> dict:
    return {"totals": {"percent_covered": total}, "files": {k: {"summary": {"percent_covered": v}} for k, v in files.items()}}


RULES = {"total": 80, "files": {"app/ledger.py": 85, "app/deps.py": 90}, "exceptions": []}


def test_a_critical_module_that_lost_tests_fails():
    assert gate_module.gate(report(88, **{"app/ledger.py": 90, "app/deps.py": 95}), RULES, date(2026, 10, 1)) == []
    problems = gate_module.gate(report(88, **{"app/ledger.py": 60, "app/deps.py": 95}), RULES, date(2026, 10, 1))
    assert problems == ["app/ledger.py: 60.0% is below its minimum 85%"]
    assert gate_module.gate(report(70, **{"app/ledger.py": 90, "app/deps.py": 95}), RULES, date(2026, 10, 1)) == \
        ["total coverage 70.0% is below the minimum 80%"]
    assert "not measured" in gate_module.gate(report(88, **{"app/deps.py": 95}), RULES, date(2026, 10, 1))[0]


def test_an_exception_needs_an_owner_and_ends():
    rules = {**RULES, "exceptions": [{"file": "app/ledger.py", "minimum": 50, "owner": "Finance lead", "until": "2026-12-31",
                                       "reason": "rewritten this quarter"}]}
    measured = report(88, **{"app/ledger.py": 60, "app/deps.py": 95})
    assert gate_module.gate(measured, rules, date(2026, 10, 1)) == []
    expired = gate_module.gate(measured, rules, date(2027, 1, 1))
    assert any("expired on 2026-12-31" in p for p in expired) and any("below its minimum 85%" in p for p in expired)
    rules["exceptions"][0]["owner"] = ""
    assert any("owner, reason and until are required" in p for p in gate_module.gate(measured, rules, date(2026, 10, 1)))


def test_the_repository_minimums_are_well_formed():
    rules = json.loads((BACKEND / "coverage-thresholds.json").read_text(encoding="utf-8"))
    assert 0 < rules["total"] <= 100 and rules["files"]
    for name, minimum in rules["files"].items():
        assert (BACKEND / name).exists(), name
        assert 0 < minimum <= 100
    for e in rules["exceptions"]:
        assert e["file"] in rules["files"] and e["owner"] and e["reason"] and date.fromisoformat(e["until"]) >= date.today()

"""db/tools/verify_pack.py: an evidence pack checked from its raw files, apart from the job that built it (independent
review, round 9, Team R-24). A pack whose summaries disagree with its own logs, or whose files changed after the digests
were taken, is NOT VERIFIED."""
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("verify_pack", ROOT / "db" / "tools" / "verify_pack.py")
vp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vp)
COMMIT = "a" * 40


def make_pack(root: Path, db_checks=2, api_tests=2) -> Path:
    files = {
        "source/SOURCE.txt": f"commit: {COMMIT}\n",
        "source/TESTED.txt": f"tested commit: {COMMIT}\npack commit:   {COMMIT}\nverdict: SAME CODE (no file differs)\n",
        "evidence/verification.json": json.dumps({"source_commit": COMMIT[:12], "db_checks": db_checks, "api_tests": api_tests}),
        "tests/db_tests.log": "PASS  RLS: a company sees its own rows\nPASS  Ledger: balanced\n=== ALL TESTS PASSED (2 checks) ===\n",
        "tests/api_junit.xml": ('<testsuites><testsuite><testcase classname="tests.test_x" name="test_a"/>'
                                '<testcase classname="tests.test_x" name="test_b"/>'
                                '<testcase classname="tests.test_x" name="test_c"><skipped/></testcase></testsuite></testsuites>'),
        "tests/coverage_summary.json": json.dumps({"totals": {"percent_covered": 90.0, "num_statements": 100}}),
        "critical/critical_controls.json": json.dumps({"commit": COMMIT, "controls": [
            {"id": "C-01", "tests": 2, "passed": 2, "skipped": [], "failed": []}]}),
        "critical/CRITICAL_CONTROLS.md": ("# Critical controls\n\n## C-01 isolation\n\nTests (2: 2 passed):\n\n"
                                          "- PASS `test_x.py::test_a`\n- PASS `RLS: a company sees its own rows`\n"),
    }
    for name, text in files.items():
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_text(text)
    (root / "SHA256SUMS").write_text("".join(f"{hashlib.sha256((root / n).read_bytes()).hexdigest()}  ./{n}\n" for n in files))
    return root


def test_a_consistent_pack_is_verified(tmp_path):
    ok, bad = vp.verify(make_pack(tmp_path))
    assert bad == [] and any("2 PASS lines" in x for x in ok) and any("2 passed" in x for x in ok)


def test_a_file_changed_after_the_digests_is_caught(tmp_path):
    pack = make_pack(tmp_path)
    (pack / "tests" / "db_tests.log").write_text((pack / "tests" / "db_tests.log").read_text() + "\n")
    (pack / "extra.txt").write_text("added later")
    _, bad = vp.verify(pack)
    assert any("db_tests.log: digest differs" in b for b in bad) and any("extra.txt: in the pack but not listed" in b for b in bad)


def test_summaries_that_disagree_with_the_raw_results_are_caught(tmp_path):
    _, bad = vp.verify(make_pack(tmp_path, db_checks=3, api_tests=5))
    assert any("verification.json says 3, the log has 2" in b for b in bad)
    assert any("verification.json says 5" in b for b in bad)


def test_a_critical_test_that_did_not_pass_in_the_raw_results_is_caught(tmp_path):
    pack = make_pack(tmp_path)
    md = pack / "critical" / "CRITICAL_CONTROLS.md"
    md.write_text(md.read_text().replace("test_x.py::test_a", "test_x.py::test_c"))     # test_c was skipped
    sums = pack / "SHA256SUMS"
    sums.write_text("".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  ./{p.relative_to(pack)}\n"
                            for p in sorted(pack.rglob("*")) if p.is_file() and p.name != "SHA256SUMS"))
    _, bad = vp.verify(pack)
    assert any("C-01: test_x.py::test_c is skipped in the raw results" in b for b in bad)

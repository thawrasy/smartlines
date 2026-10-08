"""The launch gate kit (review stage B): the evidence checker never counts a development run, judges each gate by its
success criterion, and the burst and soak verdicts flag what they must. Unit tests: no API or database needed."""
import importlib.util
import json
import os

from loadtest import burst, soak

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("launch_gates", os.path.join(ROOT, "db", "tools", "launch_gates.py"))
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)

GOOD_RESTORE = {"result": "PASS", "latest": {"rpo_measured_s": 3.2, "rto_measured_s": 600, "schema_matches_source": True,
                                             "checks": {"wallets_reconcile": True, "no_orphans": True, "ledger_balanced": True}}}


def write(d, name, doc):
    with open(os.path.join(d, name), "w") as fh:
        json.dump(doc, fh)


def status(d, gate):
    return next(r for r in gates.check(str(d)) if r["gate"] == gate)


def test_a_development_drill_never_passes_a_gate(tmp_path):
    write(tmp_path, "restore_drill_2026-10-07.json", GOOD_RESTORE)
    r = status(tmp_path, 1)
    assert r["status"] == "Development only" and "staging or production" in r["reasons"][0]


def test_a_staging_drill_passes_only_within_rpo_and_rto(tmp_path):
    write(tmp_path, "restore_staging_2026-11-01.json", {**GOOD_RESTORE, "environment": "staging"})
    assert status(tmp_path, 1)["status"] == "Passed"
    slow = {**GOOD_RESTORE, "environment": "staging", "latest": {**GOOD_RESTORE["latest"], "rto_measured_s": 2400}}
    other = tmp_path / "other"
    other.mkdir()
    write(other, "restore_staging_2026-11-02.json", slow)
    r = status(other, 1)
    assert r["status"] == "Failed" and any("RTO" in x for x in r["reasons"])


def test_egress_counts_only_in_production(tmp_path):
    (tmp_path / "egress_staging_2026-11-01.txt").write_text("ok ...\negress proxy: all probes passed\n")
    assert status(tmp_path, 2)["status"] == "Development only"
    (tmp_path / "egress_production_2026-11-03.txt").write_text("ok ...\negress proxy: all probes passed\n")
    assert status(tmp_path, 2)["status"] == "Passed"


def test_capacity_needs_1x_and_2x_passing_a_5x_run_and_an_8_hour_soak(tmp_path):
    def run(rate, verdict):
        return {"environment": "staging", "target_per_second": rate, "verdict": {"status": verdict}}
    write(tmp_path, "burst_staging_1x.json", run(240, "PASS"))
    write(tmp_path, "burst_staging_2x.json", run(480, "PASS"))
    write(tmp_path, "burst_staging_5x.json", run(1200, "FAIL"))         # 5x records the limit; it need not pass
    r = status(tmp_path, 3)
    assert r["status"] == "Open" and r["reasons"] == ["a soak of at least 8 hours passing on staging"]
    write(tmp_path, "soak_staging.json", {"environment": "staging", "duration_s": 9 * 3600, "verdict": {"status": "PASS"}})
    assert status(tmp_path, 3)["status"] == "Passed"


def test_a_penetration_test_passes_only_with_every_high_finding_closed(tmp_path):
    doc = {"environment": "production", "report_ref": "FIRM-2026-11", "findings": [
        {"id": "F-1", "severity": "HIGH", "status": "FIXED_RETESTED"},
        {"id": "F-2", "severity": "CRITICAL", "status": "ACCEPTED", "accepted_reason": "", "accepted_on": "", "accepted_by": ""},
        {"id": "F-3", "severity": "LOW", "status": "OPEN"}]}
    write(tmp_path, "pentest_2026-11.json", doc)
    r = status(tmp_path, 8)
    assert r["status"] == "Failed" and r["reasons"] == ["F-2 (CRITICAL) is neither fixed and retested nor accepted with a dated reason"]
    doc["findings"][1].update(accepted_reason="Compensating control in place", accepted_on="2026-11-20", accepted_by="owner")
    write(tmp_path, "pentest_2026-11.json", doc)
    assert status(tmp_path, 8)["status"] == "Passed"


def test_the_ai_gate_waits_for_its_phase_and_templates_exist():
    assert status(ROOT, 9)["status"] == "Not applicable yet"
    for g in (5, 6, 7, 8):
        assert gates.TEMPLATES[g]["gate"] == g


def test_the_repository_evidence_is_development_only():
    rows = {r["gate"]: r["status"] for r in gates.check(gates.EVIDENCE)}
    assert "Passed" not in rows.values()


# ------------------------------------------------------------------ burst and soak verdicts
def burst_report(**over):
    rep = {"target_per_second": 240, "achieved": {"arrivals_per_second": 239.0}, "outcomes": {"dropped": 0},
           "generator": {"start_lateness_p95_ms": 4.0},
           "steps": [{"step": "hold", "requests": 10000, "errors": 2, "p95_ms": 300.0, "p99_ms": 700.0},
                     {"step": "book_pay", "requests": 9000, "errors": 3, "p95_ms": 600.0, "p99_ms": 1200.0}],
           "integrity": {"double_sold_seats": 0, "unbalanced_transactions": 0, "wallet_mismatches": 0},
           "database": {"deadlocks": 0}}
    rep.update(over)
    return rep


def test_burst_verdicts():
    assert burst.verdict(burst_report())["status"] == "PASS"
    slow = burst_report(steps=[{"step": "book_pay", "requests": 100, "errors": 0, "p95_ms": 900.0, "p99_ms": 1400.0}])
    assert burst.verdict(slow)["status"] == "FAIL"
    assert burst.verdict(burst_report(integrity={"double_sold_seats": 1, "unbalanced_transactions": 0,
                                                 "wallet_mismatches": 0}))["status"] == "FAIL"
    lagging = burst_report(generator={"start_lateness_p95_ms": 250.0})
    assert burst.verdict(lagging)["status"] == "INCONCLUSIVE"
    assert burst.verdict({k: v for k, v in burst_report().items() if k != "integrity"})["status"] == "INCONCLUSIVE"


def sample(t, rss, pending=5, oldest=1.0, dead=0.05, lag=0.0, deadlocks=0, p95=100.0):
    return {"t_s": t, "api_rss_mb": rss, "outbox_pending": pending, "outbox_oldest_s": oldest, "dead_ratio_max": dead,
            "replica_lag_s": lag, "deadlocks": deadlocks, "db_mb": 100.0, "xid_age": 1000, "autovacuum_runs": t // 600,
            "requests": 1000, "errors": 0, "p95_ms": {"hold": p95, "book_pay": p95}}


def test_soak_verdicts():
    hours = 9
    flat = [sample(t, 300.0) for t in range(0, hours * 3600, 600)]
    assert soak.verdict(flat, [{"requests": 10, "errors": 0}], hours * 3600, soak.LIMITS)["status"] == "PASS"
    leaking = [sample(t, 300.0 + t / 3600 * 120) for t in range(0, hours * 3600, 600)]   # 120 MB an hour
    v = soak.verdict(leaking, [{"requests": 10, "errors": 0}], hours * 3600, soak.LIMITS)
    assert v["status"] == "FAIL" and "memory grows" in v["reasons"][0]
    short = [sample(t, 300.0) for t in range(0, 1200, 60)]
    assert soak.verdict(short, [{"requests": 10, "errors": 0}], 1200, soak.LIMITS)["status"] == "INCONCLUSIVE"

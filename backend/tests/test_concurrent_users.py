"""The concurrent users scenario (backend/loadtest/users.py; evaluation reports of October 2026, GIMI): the journey mix,
the verdict against the service targets, and a short run against the API."""
import os
import random

import pytest

from loadtest import users


def test_the_journey_mix_follows_its_shares():
    rng = random.Random(7)
    picks = [users.pick_journey(rng) for _ in range(20000)]
    for name, share in users.JOURNEYS:
        assert abs(picks.count(name) / len(picks) - share) < 0.02, name


def test_the_verdict_reads_the_service_targets():
    fast = {"times": {"search": [100.0] * 50, "book_pay": [400.0] * 50}, "errors": {}}
    assert users.summarise([fast], 10, 10, 10)["verdict"] == "PASS"
    slow = {"times": {"search": [900.0] * 50}, "errors": {}}
    out = users.summarise([slow], 10, 10, 10)
    assert out["verdict"] == "FAIL" and any("search: p95_ms" in b for b in out["breaches"])
    failing = {"times": {"search": [100.0] * 50}, "errors": {"search": 1}}
    assert any("error rate" in b for b in users.summarise([failing], 10, 10, 10)["breaches"])
    merged = users.summarise([fast, fast], 20, 10, 10)
    assert merged["requests"] == 200                          # the workers' measurements are merged


@pytest.mark.skipif(not os.environ.get("MASSLAK_TEST_URL"), reason="needs a running API")
def test_a_short_run_against_the_api():
    out = users.summarise([users._worker((os.environ["MASSLAK_TEST_URL"], 20, 2, 1.0, 4.0, 0.5, 3))], 20, 4.0, 0.5)
    assert out["requests"] > 0 and {"search", "seat_map"} <= {s["step"] for s in out["steps"]}
    assert out["error_rate"] < 0.05, out

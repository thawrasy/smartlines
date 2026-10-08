"""Stage B of the expert review of October 2026 (docs/operations/REVIEW_STAGE_B.md): ageing of the cash carriers owe,
finance metrics, and how stale a report read from the replica may be. The SSRF and DNS rebinding tests are in
test_ssrf.py; the burst and soak tools are in backend/loadtest."""
import asyncio
import os

import pytest

from app import db
from app.errors import ApiError
from app.modules.reports import freshness
from test_e2e import client, login


# ------------------------------------------------------------------ report freshness
def test_each_report_has_a_freshness_class():
    assert freshness.freshness_class("wallet_movements", {"columns": ["created_at"]}) == "financial"
    assert freshness.freshness_class("cash_aging", {"columns": ["carrier"]}) == "financial"
    assert freshness.freshness_class("bookings", {"group_by": ["created_date"], "totals": []}) == "analytical"
    assert freshness.freshness_class("bookings", {"columns": ["booking_ref"]}) == "operational"


def run_check(monkeypatch, lag, dataset, spec):
    async def lagging(_conn):
        return lag
    monkeypatch.setattr(db, "replica_lag_seconds", lagging)
    monkeypatch.setattr(freshness, "_limits", (float("inf"), dict(freshness.DEFAULTS)))
    return asyncio.run(freshness.check(dataset, spec, None))


def test_a_financial_report_waits_for_a_lagging_replica(monkeypatch):
    with pytest.raises(ApiError) as e:
        run_check(monkeypatch, 120.0, "wallet_movements", {"columns": ["created_at"]})
    assert e.value.status == 503 and e.value.code == "REPORT_DATA_STALE"
    assert e.value.details == {"lag_seconds": 120.0, "limit_seconds": 60}
    assert run_check(monkeypatch, 30.0, "wallet_movements", {"columns": ["created_at"]})["stale"] is False


def test_other_reports_are_served_with_a_warning(monkeypatch):
    listing = run_check(monkeypatch, 400.0, "bookings", {"columns": ["booking_ref"]})
    assert listing == {"class": "operational", "lag_seconds": 400.0, "limit_seconds": 300, "stale": True}
    totals = run_check(monkeypatch, 400.0, "bookings", {"group_by": ["created_date"]})
    assert totals["class"] == "analytical" and totals["stale"] is False
    # without a replica (sandbox, or reports on the primary) nothing is stale
    assert run_check(monkeypatch, None, "wallet_movements", {"columns": ["created_at"]})["stale"] is False


def test_the_lag_query_runs_as_the_application_role(monkeypatch):
    """The measurement itself, against a real server as the API's role: a primary is not replaying anything, so the
    answer is "no replica" rather than an error (a streaming replica is exercised by the staging kit)."""
    async def run():
        await db.open_pools()
        try:
            monkeypatch.setattr(db, "_reports_pool", db._pool)      # stands in for a reports pool
            monkeypatch.setattr(db, "_lag", None)
            async with db._pool.acquire() as conn:
                return await db.replica_lag_seconds(conn)
        finally:
            monkeypatch.setattr(db, "_reports_pool", None)
            await db.close_pools()
    assert asyncio.run(run()) is None


def test_every_report_answer_says_how_fresh_it_is():
    admin = login("admin@masslak.test", "PLATFORM")
    r = admin.post("/api/reports/run", json={"code": "fin.wallet_movements", "params": {"from": "2026-01-01", "to": "2026-12-31"}})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["freshness"]["class"] == "financial" and body["freshness"]["stale"] is False
    assert "replica_lag_seconds" in body and body["data_as_of"]


# ------------------------------------------------------------------ cash ageing
def test_cash_ageing_report_and_positions_agree():
    admin = login("admin@masslak.test", "PLATFORM")
    r = admin.post("/api/reports/run", json={"code": "fin.cash_aging"})
    assert r.status_code == 200, r.text
    rep = r.json()
    keys = [c["key"] for c in rep["columns"]]
    assert keys[:3] == ["carrier", "owed", "credit_limit"] and "overdue" in keys and "oldest_unpaid_date" in keys
    for row in rep["rows"]:
        assert row["owed"] == row["days_0_7"] + row["days_8_30"] + row["days_31_60"] + row["days_61_90"] + row["days_over_90"]
        assert row["overdue"] == row["days_31_60"] + row["days_61_90"] + row["days_over_90"]
    positions = admin.get("/api/admin/cash/positions").json()["positions"]
    assert positions and all({"overdue", "days_0_7", "days_over_90", "oldest_unpaid_at"} <= p.keys() for p in positions)
    for p in positions:
        assert p["owed"] == p["days_0_7"] + p["days_8_30"] + p["days_31_60"] + p["days_61_90"] + p["days_over_90"]


def test_a_carrier_reads_only_its_own_cash_ageing():
    owner = login("owner@carrier.test", "OPERATOR")
    r = owner.post("/api/reports/run", json={"code": "fin.cash_aging"})
    assert r.status_code == 200, r.text
    me = owner.get("/api/auth/me").json()
    names = {row["carrier"] for row in r.json()["rows"]}
    assert len(names) <= 1
    if names:
        assert names == {me.get("company", {}).get("legal_name") or next(iter(names))}
    assert client().post("/api/reports/run", json={"code": "fin.cash_aging"}).status_code == 401


@pytest.mark.skipif(not os.environ.get("MASSLAK_METRICS_TOKEN"), reason="needs MASSLAK_METRICS_TOKEN")
def test_cash_owed_and_overdue_reach_monitoring():
    r = client().get("/api/metrics", headers={"Authorization": f"Bearer {os.environ['MASSLAK_METRICS_TOKEN']}"})
    assert r.status_code == 200
    for name in ("masslak_cash_owed_minor", "masslak_cash_overdue_minor", "masslak_cash_overdue_carriers",
                 "masslak_cash_near_limit_carriers"):
        assert f'\n{name}{{currency="SYP"}} ' in r.text, name      # one series per open market currency (1061)

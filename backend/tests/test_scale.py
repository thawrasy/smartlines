"""Ten million operations a day (docs/operations/CAPACITY_MODEL.md, schema file 1052): shared wallets take credits without
a row lock and still report the balance that counts, positions arrive in batches, and the latest position of a vehicle
is kept in one row."""
import os
import uuid

import httpx
import pytest

from test_e2e import BASE, login, owner_sql

TOKEN = os.environ.get("MASSLAK_METRICS_TOKEN", "")
needs_owner = pytest.mark.skipif(not os.environ.get("MASSLAK_OWNER_URL"), reason="needs MASSLAK_OWNER_URL")


@needs_owner
def test_a_shared_wallet_counts_a_credit_at_once_and_the_roll_up_folds_it_in():
    admin = login("admin@masslak.test", "PLATFORM")
    a = next(a for a in admin.get("/api/admin/agencies").json()["agencies"] if a["legal_name"] == "Demo Travel Agency")
    wallet = owner_sql("SELECT w.id FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id "
                       "WHERE p.uid = $1::uuid AND w.wallet_type = 'COMPANY' AND w.currency = 'SYP'", a["uid"])
    assert owner_sql("SELECT balance_mode FROM fin.wallet WHERE id = $1", wallet) == "DEFERRED"
    owner_sql("SELECT fin.roll_up_balances()")
    stored = owner_sql("SELECT balance FROM fin.wallet WHERE id = $1", wallet)
    r = admin.post(f"/api/admin/agencies/{a['uid']}/deposit",
                   json={"amount": 1_234_500, "bank_reference": "SCALE-1", "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 200, r.text
    # the credit counts at once (the answer and the agency's dashboard), the wallet row itself was not touched
    assert r.json()["balance"] == owner_sql("SELECT fin.wallet_balance($1)", wallet)
    assert owner_sql("SELECT balance FROM fin.wallet WHERE id = $1", wallet) == stored
    agency = login("agency@agency.test", "AGENCY")
    assert agency.get("/api/agency/dashboard").json()["balance"] == r.json()["balance"]
    # the roll-up folds it into the stored balance, and the ledger reconciles
    owner_sql("SELECT fin.roll_up_balances()")
    assert owner_sql("SELECT balance FROM fin.wallet WHERE id = $1", wallet) == r.json()["balance"]
    assert owner_sql("SELECT (fin.reconcile_wallets()).mismatches") == 0


@needs_owner
def test_the_agency_statement_runs_from_the_opening_balance_to_the_balance_that_counts():
    agency = login("agency@agency.test", "AGENCY")
    st = agency.get("/api/agency/statement").json()
    assert st["closing_balance"] == st["opening_balance"] + st["total_credit"] - st["total_debit"]
    running = st["opening_balance"]
    for e in st["entries"]:
        running += e["amount"] if e["direction"] == "CR" else -e["amount"]
        assert e["balance_after"] == running
    assert st["closing_balance"] == agency.get("/api/agency/dashboard").json()["balance"]


@needs_owner
def test_a_batch_of_positions_is_one_request_and_the_vehicle_keeps_its_latest_position():
    import test_e2e as e2e
    from test_mobile import bearer, mobile_login
    e2e.publish_fresh_trip()
    r, _ = mobile_login(e2e.FRESH_DRIVERS[-1], "DRIVER", e2e.FRESH_DRIVER_PASSWORD)
    assert r.status_code == 200, r.text
    d = bearer(r.json()["access_token"])
    trip = d.get("/api/driver/trips").json()["trips"][-1]["uid"]
    from datetime import datetime, timedelta, timezone
    now = datetime.now(timezone.utc)
    points = [{"lat": 33.5000 + i / 1000, "lng": 36.3000, "accuracy_m": 6, "provider": "GPS", "event_id": str(uuid.uuid4()),
               "seq": 100 + i, "device_ts": (now - timedelta(seconds=30 - 10 * i)).isoformat()} for i in range(3)]
    r = d.post("/api/driver/locations", json={"trip_uid": trip, "points": points})
    assert r.status_code == 200, r.text
    assert r.json()["accepted"] == 3 and r.json()["duplicates"] == 0 and r.json()["trust"].get("HIGH") == 3
    vehicle = owner_sql("SELECT vehicle_id FROM ops.geo_event WHERE event_id = $1::uuid", points[0]["event_id"])
    assert float(owner_sql("SELECT lat FROM ops.vehicle_position WHERE vehicle_id = $1", vehicle)) == pytest.approx(33.502)
    # the same batch again changes nothing, and an older position never replaces the latest
    again = d.post("/api/driver/locations", json={"trip_uid": trip, "points": points}).json()
    assert again["accepted"] == 0 and again["duplicates"] == 3
    old = {**points[0], "event_id": str(uuid.uuid4()), "lat": 34.0, "device_ts": (now - timedelta(minutes=5)).isoformat()}
    assert d.post("/api/driver/locations", json={"trip_uid": trip, "points": [old]}).json()["accepted"] == 1
    assert float(owner_sql("SELECT lat FROM ops.vehicle_position WHERE vehicle_id = $1", vehicle)) == pytest.approx(33.502)
    # a batch is bounded
    too_many = d.post("/api/driver/locations", json={"trip_uid": trip, "points": [points[0]] * 121})
    assert too_many.status_code == 422


@pytest.mark.skipif(not TOKEN, reason="needs MASSLAK_METRICS_TOKEN")
def test_metrics_show_the_roll_up_lag_and_the_open_ledger_days():
    body = httpx.get(f"{BASE}/api/metrics", headers={"Authorization": f"Bearer {TOKEN}"}).text
    for name in ("masslak_wallet_rollup_lag_seconds", "masslak_ledger_open_days", "masslak_audit_online_months"):
        assert name in body, name

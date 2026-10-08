"""Vehicle positions in a telemetry database (review stage D2: schema file 1063, db/telemetry/schema.sql).

Runs against an API started with MASSLAK_TELEMETRY_DATABASE_URL; MASSLAK_TELEMETRY_TEST_URL is the same database, read
directly by the test. Positions are graded on the primary by the same rules as before, their history lands in the
telemetry database and not on the primary, and the vehicle keeps its latest position on the primary.
"""
import asyncio
import os
import uuid
from datetime import datetime, timedelta, timezone

import asyncpg
import httpx
import pytest

import test_e2e as e2e
from test_e2e import BASE, OWNER_URL, owner_sql

TEL_URL = os.environ.get("MASSLAK_TELEMETRY_TEST_URL")
TOKEN = os.environ.get("MASSLAK_METRICS_TOKEN", "")
pytestmark = pytest.mark.skipif(not (TEL_URL and OWNER_URL),
                                reason="needs an API with a telemetry database (MASSLAK_TELEMETRY_TEST_URL) and MASSLAK_OWNER_URL")


def tel_sql(sql: str, *args):
    async def run():
        conn = await asyncpg.connect(TEL_URL)
        try:
            return await conn.fetchval(sql, *args)
        finally:
            await conn.close()
    return asyncio.run(run())


@pytest.fixture(scope="module")
def drive():
    from test_mobile import bearer, mobile_login
    e2e.publish_fresh_trip()
    r, _ = mobile_login(e2e.FRESH_DRIVERS[-1], "DRIVER", e2e.FRESH_DRIVER_PASSWORD)
    assert r.status_code == 200, r.text
    d = bearer(r.json()["access_token"])
    trip = d.get("/api/driver/trips").json()["trips"][-1]
    return d, trip["uid"], owner_sql("SELECT id FROM ops.trip WHERE uid = $1::uuid", trip["uid"])


def point(lat: float, seq: int, at: datetime, **extra) -> dict:
    return {"lat": lat, "lng": 36.3, "accuracy_m": 6, "provider": "GPS", "event_id": str(uuid.uuid4()), "seq": seq,
            "device_ts": at.isoformat(), **extra}


def stored(event_id: str, column: str = "trust"):
    return tel_sql(f"SELECT {column} FROM tel.position WHERE event_id = $1::uuid", event_id)


def test_positions_are_graded_on_the_primary_and_kept_in_the_telemetry_database(drive):
    d, trip, trip_id = drive
    now = datetime.now(timezone.utc)
    points = [point(33.5 + i / 1000, 100 + i, now - timedelta(seconds=30 - 10 * i)) for i in range(3)]
    r = d.post("/api/driver/locations", json={"trip_uid": trip, "points": points})
    assert r.status_code == 200, r.text
    assert r.json() == {"ok": True, "accepted": 3, "duplicates": 0, "trust": {"HIGH": 3}}
    # the history is in the telemetry database, with the trip's company, vehicle and the driver's device
    company, vehicle = owner_sql("SELECT company_id FROM ops.trip WHERE id = $1", trip_id), \
        owner_sql("SELECT vehicle_id FROM ops.trip WHERE id = $1", trip_id)
    for p in points:
        assert stored(p["event_id"]) == "HIGH"
        assert stored(p["event_id"], "company_id") == company and stored(p["event_id"], "vehicle_id") == vehicle
        assert stored(p["event_id"], "device_id") is not None
    assert owner_sql("SELECT count(*) FROM ops.geo_event WHERE event_id = ANY($1::uuid[])", [p["event_id"] for p in points]) == 0
    # the primary keeps the vehicle's latest position, with the device's counter
    assert float(owner_sql("SELECT lat FROM ops.vehicle_position WHERE vehicle_id = $1", vehicle)) == pytest.approx(33.502)
    assert owner_sql("SELECT seq FROM ops.vehicle_position WHERE vehicle_id = $1", vehicle) == 102
    # the same batch again is skipped as duplicates; an older position is kept but never replaces the latest
    assert d.post("/api/driver/locations", json={"trip_uid": trip, "points": points}).json()["duplicates"] == 3
    old = point(34.0, 90, now - timedelta(minutes=5))
    assert d.post("/api/driver/locations", json={"trip_uid": trip, "points": [old]}).json()["accepted"] == 1
    assert float(owner_sql("SELECT lat FROM ops.vehicle_position WHERE vehicle_id = $1", vehicle)) == pytest.approx(33.502)


def test_the_trust_rules_are_the_same_as_on_the_primary(drive):
    d, trip, trip_id = drive
    vehicle = owner_sql("SELECT vehicle_id FROM ops.trip WHERE id = $1", trip_id)
    now = datetime.now(timezone.utc)
    latest = owner_sql("SELECT ts FROM ops.vehicle_position WHERE vehicle_id = $1", vehicle)
    base = max(now - timedelta(seconds=5), latest + timedelta(seconds=1))
    # 50 km in one minute after the latest position: impossible speed; a lower counter: out of order; a mock: rejected
    jump = point(33.95, 200, base + timedelta(seconds=60))
    back = point(33.951, 150, base + timedelta(seconds=70))
    r = d.post("/api/driver/locations", json={"trip_uid": trip, "points": [jump, back]})
    assert r.status_code == 200, r.text
    assert "IMPOSSIBLE_SPEED" in stored(jump["event_id"], "trust_flags") and stored(jump["event_id"]) == "LOW"
    assert "OUT_OF_ORDER" in stored(back["event_id"], "trust_flags")
    mock = d.post("/api/driver/location", json={"trip_uid": trip, **point(33.96, 300, base + timedelta(seconds=80), is_mock=True)})
    assert mock.json()["trust"] == "REJECTED" and "MOCK_LOCATION" in mock.json()["flags"], mock.text
    # a rejected position is kept as evidence but never becomes the vehicle's latest
    assert float(owner_sql("SELECT lat FROM ops.vehicle_position WHERE vehicle_id = $1", vehicle)) == pytest.approx(33.951)
    single = point(33.952, 400, base + timedelta(seconds=90))
    first = d.post("/api/driver/location", json={"trip_uid": trip, **single})
    assert first.json()["trust"] in ("HIGH", "LOW") and d.post("/api/driver/location", json={"trip_uid": trip, **single}).json()["duplicate"]


def test_nothing_is_stored_for_a_trip_that_is_not_the_drivers(drive):
    d, _, _ = drive
    p = point(33.5, 1, datetime.now(timezone.utc))
    r = d.post("/api/driver/locations", json={"trip_uid": str(uuid.uuid4()), "points": [p]})
    assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_ASSIGNED"
    assert tel_sql("SELECT count(*) FROM tel.position WHERE event_id = $1::uuid", p["event_id"]) == 0


def test_the_api_login_appends_only_and_the_upkeep_follows_the_primary():
    for sql in ("DELETE FROM tel.position", "UPDATE tel.position SET trust = 'HIGH'", "DROP TABLE tel.position_default"):
        with pytest.raises(asyncpg.PostgresError):
            tel_sql(sql)
    keep = owner_sql("SELECT keep_days FROM ops.position_retention()")
    assert tel_sql("SELECT (tel.upkeep($1, false)) ->> 'keep_days'", keep) == str(keep)
    assert tel_sql("SELECT value FROM tel.metrics() WHERE metric = 'masslak_telemetry_partitions_missing'") == 0


@pytest.mark.skipif(not TOKEN, reason="needs MASSLAK_METRICS_TOKEN")
def test_metrics_report_the_telemetry_database():
    body = httpx.get(f"{BASE}/api/metrics", headers={"Authorization": f"Bearer {TOKEN}"}).text
    assert "masslak_telemetry_up 1.0" in body and "masslak_telemetry_partitions_missing 0.0" in body

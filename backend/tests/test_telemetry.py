"""Vehicle positions in a telemetry database (review stage D2: schema file 1063, db/telemetry/schema.sql).

Runs against an API started with MASSLAK_TELEMETRY_DATABASE_URL. The test reaches the same database three ways:
MASSLAK_TELEMETRY_TEST_URL as the API's append-only login, MASSLAK_TELEMETRY_UPKEEP_TEST_URL as the worker's upkeep
login, and MASSLAK_TELEMETRY_OWNER_TEST_URL as its owner, to read what was stored. Positions are graded on the primary
by the same rules as before, their history lands in the telemetry database and not on the primary, and the vehicle
keeps its latest position on the primary.
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
TEL_UPKEEP_URL = os.environ.get("MASSLAK_TELEMETRY_UPKEEP_TEST_URL")
TEL_OWNER_URL = os.environ.get("MASSLAK_TELEMETRY_OWNER_TEST_URL")
TOKEN = os.environ.get("MASSLAK_METRICS_TOKEN", "")
pytestmark = pytest.mark.skipif(not (TEL_URL and TEL_UPKEEP_URL and TEL_OWNER_URL and OWNER_URL),
                                reason="needs an API with a telemetry database (MASSLAK_TELEMETRY_TEST_URL, "
                                       "MASSLAK_TELEMETRY_UPKEEP_TEST_URL, MASSLAK_TELEMETRY_OWNER_TEST_URL) and MASSLAK_OWNER_URL")


def tel_sql(sql: str, *args, url: str | None = None):
    async def run():
        conn = await asyncpg.connect(url or TEL_URL)
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
    return tel_sql(f"SELECT {column} FROM tel.position WHERE event_id = $1::uuid", event_id, url=TEL_OWNER_URL)


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
    assert tel_sql("SELECT count(*) FROM tel.position WHERE event_id = $1::uuid", p["event_id"], url=TEL_OWNER_URL) == 0


def test_the_api_login_appends_only_and_cannot_destroy_or_read_the_history():
    """C-02: the login the internet-facing API holds appends positions and creates days ahead; it reads no position,
    changes none, and cannot run the upkeep that drops days."""
    for sql in ("DELETE FROM tel.position", "UPDATE tel.position SET trust = 'HIGH'", "DROP TABLE tel.position_default",
                "SELECT company_id, lat, lng FROM tel.position LIMIT 1", "SELECT tel.upkeep(1, false)",
                "UPDATE tel.policy SET held = false", "SELECT tel.drop_older_than(1)"):
        with pytest.raises(asyncpg.InsufficientPrivilegeError):
            tel_sql(sql)
    assert tel_sql("SELECT tel.ensure_ahead()") >= 0
    assert tel_sql("SELECT value FROM tel.metrics() WHERE metric = 'masslak_telemetry_partitions_missing'") == 0


def test_the_upkeep_follows_the_primary_respects_a_hold_and_never_goes_below_the_floor():
    keep = owner_sql("SELECT keep_days FROM ops.position_retention()")
    assert tel_sql("SELECT (tel.upkeep($1, false)) ->> 'keep_days'", keep, url=TEL_UPKEEP_URL) == str(max(keep, 7))
    # a day older than any retention, created by the owner: kept while the primary reports a hold, dropped after
    old = (datetime.now(timezone.utc) - timedelta(days=60)).date()
    name = f"position_{old:%Y%m%d}"
    tel_sql(f"CREATE TABLE IF NOT EXISTS tel.{name} PARTITION OF tel.position FOR VALUES FROM ('{old}') TO ('{old + timedelta(days=1)}')",
            url=TEL_OWNER_URL)
    try:
        assert tel_sql("SELECT (tel.upkeep($1, true)) ->> 'partitions_dropped'", keep, url=TEL_UPKEEP_URL) == "0"
        assert tel_sql("SELECT held FROM tel.policy", url=TEL_OWNER_URL) is True
        assert tel_sql("SELECT tel.upkeep(1, true) ->> 'partitions_dropped'", url=TEL_UPKEEP_URL) == "0"
        assert tel_sql(f"SELECT to_regclass('tel.{name}') IS NOT NULL", url=TEL_OWNER_URL) is True
        assert tel_sql("SELECT (tel.upkeep($1, false)) ->> 'partitions_dropped'", keep, url=TEL_UPKEEP_URL) != "0"
        assert tel_sql(f"SELECT to_regclass('tel.{name}') IS NULL", url=TEL_OWNER_URL) is True
        # asked to keep a single day, the upkeep still keeps the floor: today's and the last week's days stay
        tel_sql("SELECT tel.upkeep(1, false)", url=TEL_UPKEEP_URL)
        floor = tel_sql("SELECT min_keep_days FROM tel.policy", url=TEL_OWNER_URL)
        day = (datetime.now(timezone.utc) - timedelta(days=floor - 1)).date()
        assert tel_sql(f"SELECT to_regclass('tel.position_{day:%Y%m%d}') IS NOT NULL", url=TEL_OWNER_URL) is True
    finally:
        tel_sql(f"DROP TABLE IF EXISTS tel.{name}", url=TEL_OWNER_URL)
        tel_sql("UPDATE tel.policy SET held = false, held_since = NULL", url=TEL_OWNER_URL)
    with pytest.raises(asyncpg.InsufficientPrivilegeError):
        tel_sql("SELECT count(*) FROM tel.position", url=TEL_UPKEEP_URL)


def test_the_worker_drops_only_through_its_own_login(monkeypatch):
    """Without the upkeep login the worker still creates the days ahead (through the API's login) but says the retention
    is not applied; with it, the retention the primary reports is applied."""
    from app import config, db, telemetry

    async def run():
        pool = await asyncpg.create_pool(TEL_URL, min_size=1, max_size=1)
        monkeypatch.setattr(db, "_telemetry_pool", pool)
        settings = config.get_settings()
        try:
            monkeypatch.setattr(settings, "telemetry_upkeep_url", "")
            without = await telemetry.upkeep(30, False)
            monkeypatch.setattr(settings, "telemetry_upkeep_url", TEL_UPKEEP_URL)
            return without, await telemetry.upkeep(30, False)
        finally:
            await pool.close()
    without, with_login = asyncio.run(run())
    assert without["retention"] == "not applied" and without["partitions_dropped"] == 0
    assert with_login["keep_days"] == 30 and with_login["held"] is False


@pytest.mark.skipif(not TOKEN, reason="needs MASSLAK_METRICS_TOKEN")
def test_metrics_report_the_telemetry_database():
    body = httpx.get(f"{BASE}/api/metrics", headers={"Authorization": f"Bearer {TOKEN}"}).text
    assert "masslak_telemetry_up 1.0" in body and "masslak_telemetry_partitions_missing 0.0" in body

"""End-to-end tests against a running API with the demo data (scripts/seed_demo.py).

    MASSLAK_TEST_URL=http://localhost:8077 MASSLAK_OWNER_URL=postgresql://... pytest backend/tests -q

They exercise the real database: RLS, triggers, the ledger and the audit logs.
"""
import asyncio
import os
import uuid
from datetime import datetime, timedelta

import asyncpg
import httpx
import pytest

BASE = os.environ.get("MASSLAK_TEST_URL", "http://localhost:8077")
OWNER_URL = os.environ.get("MASSLAK_OWNER_URL")
PASSWORD = os.environ.get("MASSLAK_DEMO_PASSWORD", "Masslak-Demo-2026")
H = {"X-Masslak-Client": "web"}


def client() -> httpx.Client:
    return httpx.Client(base_url=BASE, headers=H, timeout=20)


def login(email: str, portal: str) -> httpx.Client:
    c = client()
    r = c.post("/api/auth/login", json={"identifier": email, "password": PASSWORD, "portal": portal})
    assert r.status_code == 200, r.text
    return c


def day(offset: int) -> str:
    return (datetime.utcnow() + timedelta(hours=3) + timedelta(days=offset)).date().isoformat()




def owner_sql(sql: str, *args):
    async def run():
        conn = await asyncpg.connect(OWNER_URL)
        try:
            return await conn.fetchval(sql, *args)
        finally:
            await conn.close()
    return asyncio.run(run())


@pytest.fixture(scope="module")
def pax():
    return login("passenger@masslak.test", "PASSENGER")


@pytest.fixture(scope="module")
def trip(pax):
    # The completion test moves its trip into the past, so each run takes the next bookable trip of the week
    for offset in range(1, 7):
        r = pax.get("/api/trips/search", params={"origin": "DAM", "destination": "HMA", "on": day(offset), "passengers": 2})
        assert r.status_code == 200
        trips = [t for t in r.json()["trips"] if t["bookable"] and t["seats_left"] >= 4]
        if trips:
            break
    assert trips, "no bookable trips left this week; reseed the demo data"
    t = trips[0]
    assert t["price"] == 2800000 and t["from_seq"] == 0 and t["to_seq"] == 2  # ladder: Hama 28,000 - Damascus 0
    return t


def free_seats(c, t, n):
    seats = c.get(f"/api/trips/{t['uid']}", params={"from_seq": t["from_seq"], "to_seq": t["to_seq"]}).json()["seats"]
    free = [x["seat_no"] for x in seats if x["free"]]
    assert len(free) >= n, "trip is sold out; reseed the demo data"
    return free[:n]


def hold(c, t, seats):
    return c.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": seats})


def book(c, t, token, seats, brand="STANDARD", key=None):
    return c.post("/api/bookings", json={
        "hold_token": token, "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "fare_brand": brand,
        "idempotency_key": key or uuid.uuid4().hex,
        "passengers": [{"full_name": f"Passenger {s}", "seat_no": s, "id_type": "NATIONAL_ID", "id_last4": "1234"} for s in seats]})


def test_security_headers_and_client_header(pax):
    r = httpx.post(f"{BASE}/api/auth/login", json={"identifier": "x@y.z", "password": "x", "portal": "PASSENGER"})
    assert r.status_code == 400 and r.json()["error"]["code"] == "CLIENT_HEADER_REQUIRED"
    r = pax.get("/api/auth/me")
    assert r.headers["x-content-type-options"] == "nosniff" and "frame-ancestors 'none'" in r.headers["content-security-policy"]
    assert r.json()["portal"] == "PASSENGER"


def test_wrong_portal_rejected():
    c = client()
    r = c.post("/api/auth/login", json={"identifier": "passenger@masslak.test", "password": PASSWORD, "portal": "OPERATOR"})
    assert r.status_code == 403 and r.json()["error"]["code"] == "PORTAL_NOT_ALLOWED"


def test_passenger_cannot_open_carrier_api(pax):
    r = pax.get("/api/carrier/dashboard")
    assert r.status_code == 403


def test_seat_map_and_hold_conflict(pax, trip):
    r = pax.get(f"/api/trips/{trip['uid']}", params={"from_seq": trip["from_seq"], "to_seq": trip["to_seq"]})
    assert r.status_code == 200 and len(r.json()["seats"]) == trip["seats_total"]
    a, b = free_seats(pax, trip, 2)
    first = hold(pax, trip, [a])
    assert first.status_code == 201
    second = hold(pax, trip, [a, b])          # seat a already held: the whole hold is refused
    assert second.status_code == 409 and second.json()["error"]["code"] == "SEAT_TAKEN"
    assert hold(pax, trip, [b]).status_code == 201    # nothing was half-locked by the failed attempt


def test_booking_paid_from_wallet_is_idempotent_and_balanced(pax, trip):
    before = pax.get("/api/wallet").json()["balance"]
    seats = free_seats(pax, trip, 2)
    h = hold(pax, trip, seats).json()["hold_token"]
    key = uuid.uuid4().hex
    r = book(pax, trip, h, seats, key=key)
    assert r.status_code == 201, r.text
    ref, total = r.json()["booking_ref"], r.json()["total"]
    assert total == 2 * 2800000 + 100000
    again = book(pax, trip, h, seats, key=key)
    assert again.json().get("replayed") and again.json()["booking_ref"] == ref
    assert pax.get("/api/wallet").json()["balance"] == before - total
    detail = pax.get(f"/api/bookings/{ref}").json()
    assert detail["booking"]["status"] == "CONFIRMED" and len(detail["tickets"]) == 2
    # Seats are now sold for every segment of the pair
    seg = pax.get(f"/api/trips/{trip['uid']}", params={"from_seq": 0, "to_seq": 1}).json()["seats"]
    assert not next(s for s in seg if s["seat_no"] == seats[0])["free"]
    pytest.booking_ref = ref
    pytest.ticket_uid = detail["tickets"][0]["uid"]


def test_other_user_cannot_see_booking(pax):
    other = client()
    email = f"u{uuid.uuid4().hex[:8]}@example.com"
    assert other.post("/api/auth/register", json={"full_name": "Other User", "email": email,
                                                   "password": "another-long-password"}).status_code == 201
    assert other.post("/api/auth/login", json={"identifier": email, "password": "another-long-password",
                                               "portal": "PASSENGER"}).status_code == 200
    assert other.get(f"/api/bookings/{pytest.booking_ref}").status_code == 404


def test_cancel_refund_follows_brand(pax):
    trip = pax.get("/api/trips/search", params={"origin": "DAM", "destination": "HMA", "on": day(3)}).json()["trips"][0]
    [seat] = free_seats(pax, trip, 1)
    h = hold(pax, trip, [seat]).json()["hold_token"]
    ref = book(pax, trip, h, [seat], brand="STANDARD").json()["booking_ref"]
    before = pax.get("/api/wallet").json()["balance"]
    r = pax.post(f"/api/bookings/{ref}/cancel")
    assert r.status_code == 200 and r.json()["refund"] == 2800000      # > 24h before departure: 100% of the fare
    assert pax.get("/api/wallet").json()["balance"] == before + 2800000
    assert pax.post(f"/api/bookings/{ref}/cancel").status_code == 409
    seats = pax.get(f"/api/trips/{trip['uid']}", params={"from_seq": 0, "to_seq": 2}).json()["seats"]
    assert next(s for s in seats if s["seat_no"] == seat)["free"]


def test_sandbox_topup(pax):
    before = pax.get("/api/wallet").json()["balance"]
    key = uuid.uuid4().hex
    r = pax.post("/api/wallet/topup", json={"amount": 1000000, "idempotency_key": key})
    assert r.status_code == 200 and r.json()["balance"] == before + 1000000
    assert pax.post("/api/wallet/topup", json={"amount": 1000000, "idempotency_key": key}).json()["replayed"]


def test_driver_boarding_scan(trip):
    pax = login("passenger@masslak.test", "PASSENGER")
    token = pax.get(f"/api/tickets/{pytest.ticket_uid}/qr").json()["token"]
    # The demo trips rotate three vehicles and three drivers; find the driver assigned to this trip
    for email in ("driver@carrier.test", "driver2@carrier.test", "driver3@carrier.test"):
        d = login(email, "DRIVER")
        if any(t["uid"] == trip["uid"] for t in d.get("/api/driver/trips").json()["trips"]):
            break
    r = d.post("/api/driver/scan", json={"trip_uid": trip["uid"], "token": token})
    assert r.json()["result"] == "OK", r.text
    assert d.post("/api/driver/scan", json={"trip_uid": trip["uid"], "token": token}).json()["result"] == "DUPLICATE"
    assert d.post("/api/driver/scan", json={"trip_uid": trip["uid"], "token": token[:-3] + "AAA"}).json()["result"] == "INVALID_QR"
    pytest.driver_email = email


def test_carrier_dashboard_manifest_and_vehicle(trip):
    o = login("owner@carrier.test", "OPERATOR")
    dash = o.get("/api/carrier/dashboard").json()
    assert dash["active_vehicles"] >= 3
    m = o.get(f"/api/carrier/trips/{trip['uid']}/manifest").json()
    assert any(p["status"] == "BOARDED" for p in m["passengers"])
    plate = str(uuid.uuid4().int)[:6]
    r = o.post("/api/carrier/vehicles", json={"plate_no": plate, "chassis_no": f"CHS-{plate}", "passenger_seats": 30,
                                              "insurance_no": "POL-T", "insurer": "Test", "insurance_issue": "2026-01-01",
                                              "insurance_expiry": "2026-01-02"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "INSURANCE_EXPIRED"


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to move a trip into the past")
def test_trip_completion_releases_escrow(trip):
    o = login("owner@carrier.test", "OPERATOR")
    assert o.post(f"/api/carrier/trips/{trip['uid']}/complete").json()["error"]["code"] == "TRIP_NOT_STARTED"
    # Each run moves its trip into its own past day so the vehicle and crew exclusion constraints never clash
    owner_sql("""UPDATE ops.trip SET departure_at = now() - make_interval(days => d, hours => 6),
                                     arrival_at = now() - make_interval(days => d, hours => 1)
                   FROM (SELECT count(*)::int AS d FROM ops.trip WHERE departure_at < now() - interval '2 hours') past
                 WHERE uid = $1""", uuid.UUID(trip["uid"]))
    before = o.get("/api/carrier/dashboard").json()["released_balance"]
    r = o.post(f"/api/carrier/trips/{trip['uid']}/complete")
    assert r.status_code == 200, r.text
    after = o.get("/api/carrier/dashboard").json()["released_balance"]
    assert after - before >= 2 * 2800000          # the carrier fares of the first booking
    unbalanced = owner_sql("""SELECT count(*) FROM fin.ledger_txn t WHERE (SELECT sum(CASE direction WHEN 'DR' THEN amount ELSE -amount END)
                              FROM fin.ledger_entry e WHERE e.txn_id = t.id) <> 0""")
    assert unbalanced == 0


def test_admin_onboarding_ip_rules_and_audit():
    a = login("admin@masslak.test", "PLATFORM")
    assert a.get("/api/admin/overview").json()["carriers"] >= 1
    code = "".join(chr(65 + (uuid.uuid4().int >> i) % 26) for i in (0, 8, 16))
    r = a.post("/api/admin/companies", json={"legal_name": f"Test Carrier {code}", "code3": code, "owner_name": "Owner",
                                             "owner_email": f"{code.lower()}{uuid.uuid4().hex[:4]}@example.com",
                                             "owner_password": "test-owner-password"})
    assert r.status_code in (201, 409), r.text
    # Block a range, then a request "from" that range (via the trusted proxy header) is refused at the edge of the API
    rule = a.post("/api/security/ip-rules", json={"target": "203.0.113.0/24", "action": "BLOCK", "reason": "test block",
                                                  "expires_hours": 1}).json()["id"]
    r = httpx.get(f"{BASE}/api/health", headers={"X-Forwarded-For": "203.0.113.9"})
    assert r.status_code == 403 and r.json()["error"]["code"] == "IP_BLOCKED"
    assert httpx.get(f"{BASE}/api/health", headers={"X-Forwarded-For": "198.51.100.1"}).status_code == 200
    assert a.post(f"/api/security/ip-rules/{rule}/revoke", json={"reason": "test done"}).status_code == 200
    assert httpx.get(f"{BASE}/api/health", headers={"X-Forwarded-For": "203.0.113.9"}).status_code == 200
    assert a.post("/api/security/ip-rules", json={"target": "127.0.0.0/8", "reason": "oops"}).json()["error"]["code"] == "SELF_BLOCK"
    events = a.get("/api/security/auth-events").json()["events"]
    assert any(e["event"] == "LOGIN_SUCCESS" for e in events)
    activity = a.get("/api/security/activity").json()["activity"]
    assert any(x["action"] == "security.ip_rule.create" for x in activity)
    assert a.get("/api/regulator/dashboard").status_code == 200


def test_regulator_is_read_only():
    r = login("regulator@masslak.test", "PLATFORM")
    assert r.get("/api/regulator/dashboard").status_code == 200
    assert r.post("/api/security/ip-rules", json={"target": "192.0.2.1", "reason": "x" * 5}).status_code == 403
    assert r.post("/api/admin/stations", json={"city_code": "DAM", "number": 9, "name": "X station", "lat": 1, "lng": 1}).status_code == 403


def test_lockout_after_failed_logins():
    c = client()
    email = f"lock{uuid.uuid4().hex[:8]}@example.com"
    c.post("/api/auth/register", json={"full_name": "Lock Test", "email": email, "password": "correct-long-password"})
    codes = [c.post("/api/auth/login", json={"identifier": email, "password": "wrong-password", "portal": "PASSENGER"}).status_code
             for _ in range(5)]
    assert codes == [401] * 5
    r = c.post("/api/auth/login", json={"identifier": email, "password": "correct-long-password", "portal": "PASSENGER"})
    assert r.status_code == 423 and r.json()["error"]["code"] == "ACCOUNT_LOCKED"


def test_public_verification_detects_forgery(pax):
    detail = pax.get(f"/api/bookings/{pytest.booking_ref}").json()
    token = detail["booking"]["verify_token"]
    ok = httpx.get(f"{BASE}/api/verify", params={"token": token}).json()
    assert ok["valid"] and ok["booking_ref"] == pytest.booking_ref
    forged = token.replace(pytest.booking_ref, "AAAAAA")
    assert httpx.get(f"{BASE}/api/verify", params={"token": forged}).json() == {"valid": False, "reason": "SIGNATURE_INVALID"}

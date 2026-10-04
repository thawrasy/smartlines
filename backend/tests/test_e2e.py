"""End-to-end tests against a running API with the demo data (scripts/seed_demo.py).

    MASSLAK_TEST_URL=http://localhost:8077 MASSLAK_OWNER_URL=postgresql://... pytest backend/tests -q

They exercise the real database: RLS, triggers, the ledger and the audit logs.
"""
import asyncio
import os
import secrets
import uuid
from datetime import datetime, timedelta, timezone

import asyncpg
import httpx
import pytest

BASE = os.environ.get("MASSLAK_TEST_URL", "http://localhost:8077")
OWNER_URL = os.environ.get("MASSLAK_OWNER_URL")
PASSWORD = os.environ.get("MASSLAK_DEMO_PASSWORD", "Masslak-Demo-2026")
# Each run speaks from its own address in the benchmarking range (RFC 2544), passed through the trusted local
# proxy hop. The automatic IP blocking counts failed sign-ins per address, so runs stay independent of each other.
RUN_IP = f"198.18.{secrets.randbelow(256)}.{1 + secrets.randbelow(254)}"
H = {"X-Masslak-Client": "web", "X-Forwarded-For": RUN_IP}


def client() -> httpx.Client:
    return httpx.Client(base_url=BASE, headers=H, timeout=20)


def login(email: str, portal: str) -> httpx.Client:
    c = client()
    r = c.post("/api/auth/login", json={"identifier": email, "password": PASSWORD, "portal": portal})
    assert r.status_code == 200, r.text
    return c


def day(offset: int) -> str:
    return (datetime.utcnow() + timedelta(hours=3) + timedelta(days=offset)).date().isoformat()




def new_passenger() -> httpx.Client:
    c = client()
    email = f"u{uuid.uuid4().hex[:8]}@example.com"
    assert c.post("/api/auth/register", json={"full_name": "Test User", "email": email,
                                              "password": "another-long-password"}).status_code == 201
    assert c.post("/api/auth/login", json={"identifier": email, "password": "another-long-password",
                                           "portal": "PASSENGER"}).status_code == 200
    return c


def owner_sql(sql: str, *args, fetch: bool = False):
    async def run():
        conn = await asyncpg.connect(OWNER_URL)
        try:
            return await (conn.fetchrow(sql, *args) if fetch else conn.fetchval(sql, *args))
        finally:
            await conn.close()
    return asyncio.run(run())


@pytest.fixture(scope="module")
def pax():
    c = login("passenger@masslak.test", "PASSENGER")
    # Bookings spend from the shared demo wallet; a sandbox top-up keeps repeated runs independent
    for _ in range(3):
        r = c.post("/api/wallet/topup", json={"amount": 10000000, "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 200, r.text
    return c


def bookable_trip(pax):
    for offset in range(1, 7):
        r = pax.get("/api/trips/search", params={"origin": "DAM", "destination": "HMA", "on": day(offset), "passengers": 2})
        assert r.status_code == 200
        trips = [t for t in r.json()["trips"] if t["bookable"] and t["seats_left"] >= 4]
        if trips:
            return trips[0]
    return None


def publish_fresh_trip() -> None:
    """The demo week runs out after many runs (the completion test moves a trip into the past each time), so the
    suite publishes its own trip through the carrier API, the same way a carrier clerk would."""
    o = login("owner@carrier.test", "OPERATOR")
    route = next(r for r in o.get("/api/carrier/routes").json()["routes"] if r["code"] == "DAM-ALP")
    vehicles = [v["uid"] for v in o.get("/api/carrier/vehicles").json()["vehicles"] if v["status"] == "ACTIVE"]
    drivers = [c["uid"] for c in o.get("/api/carrier/crew").json()["crew"]
               if c["status"] == "ACTIVE" and c["email"] in ("driver@carrier.test", "driver2@carrier.test", "driver3@carrier.test")]
    for offset in range(2, 7):
        for hour in (5, 23, 4, 22, 3):
            minute = secrets.randbelow(60)
            for v in vehicles:
                for d in drivers:
                    r = o.post("/api/carrier/trips", json={"route_uid": route["uid"], "vehicle_uid": v, "driver_uid": d,
                                                           "departure_local": f"{day(offset)}T{hour:02d}:{minute:02d}:00"})
                    if r.status_code == 201:
                        return
    pytest.fail("could not publish a fresh trip: every vehicle or driver is busy")


@pytest.fixture(scope="module")
def trip(pax):
    t = bookable_trip(pax)
    if t is None:
        publish_fresh_trip()
        t = bookable_trip(pax)
    assert t, "no bookable trip found after publishing one"
    assert t["price"] == 2800000 and t["from_seq"] == 0 and t["to_seq"] == 2  # ladder: Hama 28,000 - Damascus 0
    return t


def free_seats(c, t, n):
    seats = c.get(f"/api/trips/{t['uid']}", params={"from_seq": t["from_seq"], "to_seq": t["to_seq"]}).json()["seats"]
    free = [x["seat_no"] for x in seats if x["free"]]
    assert len(free) >= n, "trip is sold out; reseed the demo data"
    return free[:n]


def hold(c, t, seats):
    return c.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": seats})


def syrian(seat):
    return {"nationality": "SY", "first_name": "Rami", "father_name": "Khaled", "grandfather_name": "Omar",
            "last_name": f"Haddad{chr(65 + seat % 26)}", "seat_no": seat, "id_type": "NATIONAL_ID", "id_last4": "1234"}


def book(c, t, token, seats, brand="STANDARD", key=None, passengers=None):
    return c.post("/api/bookings", json={
        "hold_token": token, "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "fare_brand": brand,
        "idempotency_key": key or uuid.uuid4().hex, "passengers": passengers or [syrian(s) for s in seats]})


def test_security_headers_and_client_header(pax):
    r = httpx.post(f"{BASE}/api/auth/login", json={"identifier": "x@y.z", "password": "x", "portal": "PASSENGER"},
                   headers={"X-Forwarded-For": RUN_IP})
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


def test_seat_map_and_hold_conflict(trip):
    pax = new_passenger()          # holds count against a per-user limit, so each run uses a fresh account
    r = pax.get(f"/api/trips/{trip['uid']}", params={"from_seq": trip["from_seq"], "to_seq": trip["to_seq"]})
    assert r.status_code == 200 and len(r.json()["seats"]) == trip["seats_total"]
    a, b = free_seats(pax, trip, 2)
    first = hold(pax, trip, [a])
    assert first.status_code == 201
    second = hold(pax, trip, [a, b])          # seat a already held: the whole hold is refused
    assert second.status_code == 409 and second.json()["error"]["code"] == "SEAT_TAKEN"
    third = hold(pax, trip, [b])
    assert third.status_code == 201                   # nothing was half-locked by the failed attempt
    for token in (first.json()["hold_token"], third.json()["hold_token"]):
        assert pax.delete(f"/api/holds/{token}").json()["released_seats"] == 1
    seats = pax.get(f"/api/trips/{trip['uid']}", params={"from_seq": trip["from_seq"], "to_seq": trip["to_seq"]}).json()["seats"]
    assert all(x["free"] for x in seats if x["seat_no"] in (a, b))


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


def test_passenger_names_follow_the_identity_document(pax, trip):
    a, b = free_seats(pax, trip, 2)
    h = hold(pax, trip, [a, b]).json()["hold_token"]
    # A Syrian citizen without the grandfather's name is refused before anything is written
    incomplete = {**syrian(a), "grandfather_name": None}
    r = book(pax, trip, h, [a, b], passengers=[incomplete, syrian(b)])
    assert r.status_code == 422 and r.json()["error"]["code"] == "NAME_PARTS_REQUIRED"
    bad = book(pax, trip, h, [a, b], passengers=[{**syrian(a), "first_name": "R4mi"}, syrian(b)])
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "VALIDATION_FAILED"
    # A foreign passport holder with two names, written as in the passport
    foreign = {"nationality": "FR", "first_name": "Marie Claire", "last_name": "Dubois", "seat_no": b, "id_type": "PASSPORT"}
    r = book(pax, trip, h, [a, b], passengers=[{**syrian(a), "first_name": "  Rami  "}, foreign])
    assert r.status_code == 201, r.text
    tickets = pax.get(f"/api/bookings/{r.json()['booking_ref']}").json()["tickets"]
    names = {k["seat_no"]: (k["full_name"], k["nationality"]) for k in tickets}
    assert names[a] == (f"Rami Khaled Omar {syrian(a)['last_name']}", "SY")
    assert names[b] == ("Marie Claire Dubois", "FR")
    # The ticket prints the first and last name only; the booking keeps the full document name
    printed = {k["seat_no"]: k["ticket_name"] for k in tickets}
    assert printed[a] == f"Rami {syrian(a)['last_name']}"
    assert printed[b] == "Marie Claire Dubois"


def test_document_number_is_stored_encrypted(pax, trip):
    (a,) = free_seats(pax, trip, 1)
    h = hold(pax, trip, [a]).json()["hold_token"]
    p = {**syrian(a), "id_no": "010-2030-4057"}
    p.pop("id_last4")
    r = book(pax, trip, h, [a], passengers=[p])
    assert r.status_code == 201, r.text
    pytest.encrypted_ref = r.json()["booking_ref"]
    # A number without its document type is refused before any hold is needed
    seat = free_seats(pax, trip, 1)[0]
    bad = book(pax, trip, str(uuid.uuid4()), [seat], passengers=[{**syrian(seat), "id_type": None, "id_no": "0102030405"}])
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "ID_TYPE_REQUIRED"


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_document_number_never_reaches_the_database_in_plaintext():
    row = owner_sql("""SELECT p.id_no_enc, p.id_no_bidx, p.id_no_last4, p.enc_key_id
                         FROM sales.passenger p JOIN sales.booking b ON b.id = p.booking_id
                        WHERE b.booking_ref = $1""", pytest.encrypted_ref, fetch=True)
    assert row["id_no_last4"] == "4057" and row["enc_key_id"] is not None
    assert b"0102030405" not in row["id_no_enc"] and row["id_no_enc"][:1] == b"\x01"
    assert len(row["id_no_bidx"]) == 32


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_database_enforces_name_parts():
    with pytest.raises(asyncpg.CheckViolationError):
        owner_sql("""INSERT INTO sales.passenger (booking_id, full_name, first_name, last_name, nationality)
                     SELECT id, 'Rami Haddad', 'Rami', 'Haddad', 'SY' FROM sales.booking LIMIT 1""")


def test_other_user_cannot_see_booking(pax):
    other = new_passenger()
    assert other.get(f"/api/bookings/{pytest.booking_ref}").status_code == 404


def test_cancel_refund_follows_brand(pax):
    # A trip more than 24 hours away, so the STANDARD brand refunds the whole fare
    later = [t for d in range(2, 7) for t in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "HMA",
                                                                               "on": day(d)}).json()["trips"]
             if datetime.fromisoformat(t["departs_at"]) > datetime.now(timezone.utc) + timedelta(hours=25)]
    trip = later[-1]
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
    assert a.post("/api/security/ip-rules", json={"target": f"{RUN_IP}/32", "reason": "oops"}).json()["error"]["code"] == "SELF_BLOCK"
    events = a.get("/api/security/auth-events").json()["events"]
    assert any(e["event"] == "LOGIN_SUCCESS" for e in events)
    activity = a.get("/api/security/activity").json()["activity"]
    assert any(x["action"] == "security.ip_rule.create" for x in activity)
    assert a.get("/api/regulator/dashboard").status_code == 200
    summary = a.get("/api/security/summary").json()
    assert summary["logins_24h"] >= 1 and "last_seal" in summary
    assert httpx.get(f"{BASE}/api/ref", headers={"X-Forwarded-For": RUN_IP}).json()["fare_brands"][1]["rules"]["refund"] == [[24, 100], [2, 50]]


def test_regulator_is_read_only():
    r = login("regulator@masslak.test", "PLATFORM")
    assert r.get("/api/regulator/dashboard").status_code == 200
    assert r.post("/api/security/ip-rules", json={"target": "192.0.2.1", "reason": "x" * 5}).status_code == 403
    assert r.post("/api/admin/stations", json={"city_code": "DAM", "number": 9, "name": "X station", "lat": 1, "lng": 1}).status_code == 403


def test_lockout_after_failed_logins():
    # Failed logins also feed the automatic IP block, so they come from a random benchmark-range address
    c = client()
    c.headers["X-Forwarded-For"] = f"198.18.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"
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
    ok = httpx.get(f"{BASE}/api/verify", params={"token": token}, headers={"X-Forwarded-For": RUN_IP}).json()
    assert ok["valid"] and ok["booking_ref"] == pytest.booking_ref
    forged = token.replace(pytest.booking_ref, "AAAAAA")
    assert httpx.get(f"{BASE}/api/verify", params={"token": forged}, headers={"X-Forwarded-For": RUN_IP}).json() == {"valid": False, "reason": "SIGNATURE_INVALID"}


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to reset the account afterwards")
def test_two_factor_sign_in_for_staff():
    from app import mfa
    email = "regulator@masslak.test"
    uid = owner_sql("SELECT id FROM iam.app_user WHERE email = $1", email)
    owner_sql("UPDATE iam.mfa_factor SET disabled_at = now() WHERE user_id = $1 AND disabled_at IS NULL", uid)
    try:
        c = login(email, "PLATFORM")
        start = c.post("/api/auth/mfa/enroll").json()
        assert start["uri"].startswith("otpauth://totp/") and len(start["secret"]) >= 32
        secret = owner_sql("SELECT secret_enc FROM iam.mfa_factor WHERE user_id = $1 AND verified_at IS NULL", uid)
        assert start["secret"].encode() not in secret                        # stored encrypted
        assert c.post("/api/auth/mfa/confirm", json={"code": "000000"}).status_code == 422
        done = c.post("/api/auth/mfa/confirm", json={"code": mfa.code_at(start["secret"], mfa.current_step())})
        assert done.status_code == 200, done.text
        recovery = done.json()["recovery_codes"]
        assert len(recovery) == 10

        # The next sign-in stops at the second factor
        c2 = client()
        r = c2.post("/api/auth/login", json={"identifier": email, "password": PASSWORD, "portal": "PLATFORM"})
        assert r.json()["mfa"] == "VERIFY"
        blocked = c2.get("/api/auth/me")
        assert blocked.status_code == 401 and blocked.json()["error"]["code"] == "MFA_REQUIRED"
        # The code already used at enrolment is refused (replay), a recovery code works once
        wrong = c2.post("/api/auth/mfa/verify", json={"code": mfa.code_at(start["secret"], mfa.current_step())})
        assert wrong.status_code == 422 and wrong.json()["error"]["attempts_left"] == 4
        assert c2.post("/api/auth/mfa/verify", json={"code": recovery[0]}).json()["recovery_code_used"]
        assert c2.get("/api/auth/me").json()["mfa"]["enrolled"] is True

        # The same recovery code cannot open another session; five wrong codes revoke the session
        c3 = client()
        c3.post("/api/auth/login", json={"identifier": email, "password": PASSWORD, "portal": "PLATFORM"})
        assert c3.post("/api/auth/mfa/verify", json={"code": recovery[0]}).status_code == 422
        for _ in range(3):
            c3.post("/api/auth/mfa/verify", json={"code": "999999"})
        last = c3.post("/api/auth/mfa/verify", json={"code": "999999"})
        assert last.status_code == 401 and last.json()["error"]["code"] == "MFA_TOO_MANY_ATTEMPTS"
        assert c3.get("/api/auth/me").status_code == 401
    finally:
        owner_sql("UPDATE iam.mfa_factor SET disabled_at = now() WHERE user_id = $1 AND disabled_at IS NULL", uid)

"""Release 1.48.0, package C (review of release 1.47.0, and the owner's decision 2).

* two-factor sign-in by several methods: an authenticator app, a code by text message, a code by WhatsApp; the
  platform opens one or more and chooses the portals that must use one, drivers included (R-31);
* a boarding names a stop of the trip and a passenger boards only where their ticket starts or later (R-10);
* an offline scan cannot be older than the driver's first download of the trip's pack (R-09);
* holds counted and taken in one step (R-07), the same booking key sent twice at once (R-08), a wallet opened twice at
  once;
* positions the telemetry database could not take wait on the primary and are delivered later (R-03).
"""
import asyncio
import re
import secrets
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import asyncpg
import httpx
import pytest

import test_e2e as e2e
from test_account import register, sign_in
from test_e2e import BASE, H, OWNER_URL, login, owner_sql, syrian
from test_notifications import logged

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def mobile_number() -> str:
    return "+9639" + "".join(secrets.choice("0123456789") for _ in range(8))


def sent(channel: str, to: str) -> list[str]:
    """The codes sent to a number, oldest first (the sandbox keeps messages in a log)."""
    return [re.search(r"(?<!\d)(\d{6})(?!\d)", m["body"]).group(1) for m in logged(channel) if m["to"] == to]


# ------------------------------------------------------------------ two-factor sign-in by message (decision 2)
def test_a_text_message_number_is_enrolled_and_signs_in():
    email, password = register()
    c, _ = sign_in(email, password)
    methods = c.get("/api/auth/mfa/methods").json()
    assert {"TOTP", "SMS", "WHATSAPP"} <= set(methods["available"]) and methods["enrolled"] == []
    number = mobile_number()
    r = c.post("/api/auth/mfa/enroll", json={"method": "SMS", "mobile": number})
    assert r.status_code == 200, r.text
    assert r.json()["sent_to"].endswith(number[-4:]) and number not in r.text
    assert c.post("/api/auth/mfa/confirm", json={"code": "000000", "method": "SMS"}).status_code == 422
    done = c.post("/api/auth/mfa/confirm", json={"code": sent("sms", number)[-1], "method": "SMS"})
    assert done.status_code == 200, done.text
    assert len(done.json()["recovery_codes"]) == 10                     # the first method gives the recovery codes

    uid = owner_sql("SELECT id FROM iam.app_user WHERE email = $1", email)
    phone = owner_sql("SELECT secret_enc FROM iam.mfa_factor WHERE user_id = $1 AND factor_type = 'SMS' AND verified_at IS NOT NULL", uid)
    assert number.encode() not in phone                                  # the number is kept encrypted
    assert owner_sql("SELECT count(*) FROM iam.mfa_challenge WHERE user_id = $1 AND octet_length(code_hash) = 32", uid) >= 1

    # the enrolment code went out moments ago; a new one may be asked for once the resend wait has passed
    owner_sql("UPDATE iam.mfa_challenge SET created_at = created_at - interval '2 minutes', "
              "expires_at = expires_at - interval '2 minutes' WHERE user_id = $1", uid)
    d, r = sign_in(email, password)
    assert r.json()["mfa"] == "VERIFY" and r.json()["mfa_methods"] == ["SMS"]
    assert d.get("/api/bookings").json()["error"]["code"] == "MFA_REQUIRED"
    before = len(sent("sms", number))
    assert d.post("/api/auth/mfa/send", json={"method": "SMS"}).status_code == 200
    code = sent("sms", number)[-1]
    assert len(sent("sms", number)) == before + 1
    again = d.post("/api/auth/mfa/send", json={"method": "SMS"})
    assert again.status_code == 429 and again.json()["error"]["code"] == "MFA_RESEND_TOO_SOON" and again.json()["error"]["retry_in"] > 0
    assert d.post("/api/auth/mfa/verify", json={"code": code, "method": "SMS"}).json()["method"] == "sms"
    assert d.get("/api/bookings").status_code == 200

    e, _ = sign_in(email, password)                                       # a code works once
    assert e.post("/api/auth/mfa/verify", json={"code": code, "method": "SMS"}).status_code == 422


def test_a_message_code_allows_five_tries():
    email, password = register()
    c, _ = sign_in(email, password)
    number = mobile_number()
    assert c.post("/api/auth/mfa/enroll", json={"method": "SMS", "mobile": number}).status_code == 200
    code = sent("sms", number)[-1]
    wrong = f"{(int(code) + 1) % 1000000:06d}"
    for _ in range(5):
        assert c.post("/api/auth/mfa/confirm", json={"code": wrong, "method": "SMS"}).status_code == 422
    # the code is closed after five wrong entries, even the right one is refused now
    assert c.post("/api/auth/mfa/confirm", json={"code": code, "method": "SMS"}).status_code == 422


@pytest.fixture()
def security():
    """The security officer, and the policy put back as it was afterwards."""
    sec = login("security@masslak.test", "PLATFORM")
    before = sec.get("/api/security/mfa-policy").json()["policy"]
    yield sec, before
    assert sec.put("/api/security/mfa-policy", json=before).status_code == 200


def test_the_platform_requires_drivers_to_enrol_and_whatsapp_codes_work(security):
    sec, before = security
    view = sec.get("/api/security/mfa-policy").json()
    assert view["delivery"]["TOTP"] and "PLATFORM" in view["always_required"]
    assert login("finance@masslak.test", "PLATFORM").put("/api/security/mfa-policy", json=before).status_code == 403
    r = sec.put("/api/security/mfa-policy", json={**before, "required_portals": ["DRIVER"], "enforce_in_sandbox": True})
    assert r.status_code == 200, r.text
    assert r.json()["policy"]["required_portals"] == ["DRIVER"]
    assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'security.mfa_policy_changed'") >= 1
    assert sec.put("/api/security/mfa-policy", json={**before, "methods": []}).status_code == 422

    e2e.publish_fresh_trip()
    driver = e2e.FRESH_DRIVERS[-1]
    c = e2e.client()
    r = c.post("/api/auth/login", json={"identifier": driver, "password": e2e.FRESH_DRIVER_PASSWORD, "portal": "DRIVER"})
    assert r.status_code == 200 and r.json()["mfa"] == "ENROLL"           # a driver now enrols at sign-in (R-31)
    assert c.get("/api/driver/trips").json()["error"]["code"] == "MFA_REQUIRED"
    number = mobile_number()
    assert c.post("/api/auth/mfa/enroll", json={"method": "WHATSAPP", "mobile": number}).status_code == 200
    done = c.post("/api/auth/mfa/confirm", json={"code": sent("whatsapp", number)[-1], "method": "WHATSAPP"})
    assert done.status_code == 200, done.text
    assert c.get("/api/driver/trips").status_code == 200

    # WhatsApp is closed: the driver's next sign-in asks to enrol a method that is still open
    assert sec.put("/api/security/mfa-policy", json={**before, "methods": ["TOTP", "SMS"], "required_portals": ["DRIVER"],
                                                     "enforce_in_sandbox": True}).status_code == 200
    c2 = e2e.client()
    r = c2.post("/api/auth/login", json={"identifier": driver, "password": e2e.FRESH_DRIVER_PASSWORD, "portal": "DRIVER"})
    assert r.json()["mfa"] == "ENROLL" and r.json()["mfa_methods"] == []
    closed = c2.post("/api/auth/mfa/send", json={"method": "WHATSAPP"})
    assert closed.status_code == 409 and closed.json()["error"]["code"] == "MFA_METHOD_OFF"


# ------------------------------------------------------------------ boarding stops and offline scan times
@pytest.fixture(scope="module")
def boarding():
    """A fresh trip leaving in two hours with its own driver, and two tickets: the first leg (stops 0-1) and the second (1-2)."""
    e2e.publish_fresh_trip()
    d = login(e2e.FRESH_DRIVERS[-1], "DRIVER", e2e.FRESH_DRIVER_PASSWORD)
    trip = d.get("/api/driver/trips").json()["trips"][-1]["uid"]
    pax = login("passenger@masslak.test", "PASSENGER")
    pax.post("/api/wallet/topup", json={"amount": 10000000, "idempotency_key": uuid.uuid4().hex})
    tickets = []
    for a, b in ((0, 1), (1, 2)):
        seat = [x["seat_no"] for x in pax.get(f"/api/trips/{trip}", params={"from_seq": a, "to_seq": b}).json()["seats"] if x["free"]][0]
        h = pax.post("/api/holds", json={"trip_uid": trip, "from_seq": a, "to_seq": b, "seat_nos": [seat]}).json()
        r = pax.post("/api/bookings", json={"hold_token": h["hold_token"], "trip_uid": trip, "from_seq": a, "to_seq": b,
                                            "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 201, r.text
        tickets += pax.get(f"/api/bookings/{r.json()['booking_ref']}").json()["tickets"]
    owner_sql("""UPDATE ops.trip SET departure_at = now() + interval '2 hours', arrival_at = now() + interval '7 hours'
                  WHERE uid = $1""", uuid.UUID(trip))
    yield {"driver": d, "trip": trip, "pax": pax, "tickets": tickets}
    owner_sql("""UPDATE ops.trip SET departure_at = now() - make_interval(days => d, hours => 6),
                                     arrival_at = now() - make_interval(days => d, hours => 1)
                   FROM (SELECT count(*)::int AS d FROM ops.trip WHERE departure_at < now() - interval '2 hours') past
                  WHERE uid = $1""", uuid.UUID(trip))
    login("owner@carrier.test", "OPERATOR").post(f"/api/carrier/trips/{trip}/complete")


def test_a_boarding_names_a_stop_the_ticket_covers(boarding):
    d, trip, pax = boarding["driver"], boarding["trip"], boarding["pax"]
    first, second = boarding["tickets"]
    qr = lambda k: pax.get(f"/api/tickets/{k['uid']}/offline").json()["credential"]   # noqa: E731
    assert d.post("/api/driver/scan", json={"trip_uid": trip, "token": qr(first), "stop_seq": 9}).json()["result"] == "UNKNOWN_STOP"
    assert d.post("/api/driver/scan", json={"trip_uid": trip, "token": qr(first), "stop_seq": 1}).json()["result"] == "WRONG_STOP"
    assert d.post("/api/driver/scan", json={"trip_uid": trip, "token": qr(second), "stop_seq": 0}).json()["result"] == "WRONG_STOP"
    assert d.post("/api/driver/scan", json={"trip_uid": trip, "token": qr(first)}).json()["result"] == "OK"   # its first stop
    assert d.post("/api/driver/scan", json={"trip_uid": trip, "token": qr(second), "stop_seq": 1}).json()["result"] == "OK"
    stops = owner_sql("""SELECT array_agg(e.stop_seq || ':' || e.result ORDER BY e.id)::text FROM sales.boarding_event e
                          JOIN ops.trip t ON t.id = e.trip_id WHERE t.uid = $1""", uuid.UUID(trip))
    assert stops == "{1:WRONG_STOP,0:WRONG_STOP,0:OK,1:OK}"           # the unknown stop was not recorded


def test_an_offline_scan_is_not_older_than_the_pack(boarding):
    d, trip, pax = boarding["driver"], boarding["trip"], boarding["pax"]
    seat = [x["seat_no"] for x in pax.get(f"/api/trips/{trip}", params={"from_seq": 0, "to_seq": 2}).json()["seats"] if x["free"]][:2]
    h = pax.post("/api/holds", json={"trip_uid": trip, "from_seq": 0, "to_seq": 2, "seat_nos": seat}).json()
    r = pax.post("/api/bookings", json={"hold_token": h["hold_token"], "trip_uid": trip, "from_seq": 0, "to_seq": 2,
                                        "passengers": [syrian(s) for s in seat], "idempotency_key": uuid.uuid4().hex})
    tickets = pax.get(f"/api/bookings/{r.json()['booking_ref']}").json()["tickets"]
    assert d.get(f"/api/driver/trips/{trip}/offline").status_code == 200             # the pack is downloaded now
    creds = [pax.get(f"/api/tickets/{k['uid']}/offline").json()["credential"] for k in tickets]
    hour_ago = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()         # within a day of departure
    later = (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat()
    scans = [{"scan_id": "pk-" + secrets.token_hex(6), "token": creds[0], "scanned_at": hour_ago},
             {"scan_id": "pk-" + secrets.token_hex(6), "token": creds[1], "scanned_at": later}]
    assert [x["result"] for x in d.post("/api/driver/scans/batch", json={"trip_uid": trip, "scans": scans}).json()["results"]] == ["OK", "OK"]
    early = owner_sql("SELECT boarded_at FROM sales.ticket WHERE uid = $1", uuid.UUID(tickets[0]["uid"]))
    assert early > datetime.now(timezone.utc) - timedelta(minutes=2)                 # dated at the upload, not an hour back
    assert owner_sql("SELECT downloads FROM ops.offline_pack_download p JOIN ops.trip t ON t.id = p.trip_id WHERE t.uid = $1",
                     uuid.UUID(trip)) >= 1


# ------------------------------------------------------------------ races
def _clients_of(c: httpx.Client, n: int) -> list[httpx.Client]:
    return [httpx.Client(base_url=BASE, headers=H, timeout=30, cookies=c.cookies) for _ in range(n)]


def test_holds_sent_together_cannot_pass_the_limit():
    from app.modules.sales.models import MAX_LOCKED_SEATS
    c = e2e.new_passenger()
    t = e2e.bookable_trip(c)
    if t is None:
        e2e.publish_fresh_trip()
        t = e2e.bookable_trip(c)
    seats = e2e.free_seats(c, t, MAX_LOCKED_SEATS + 4)
    clients = _clients_of(c, len(seats))
    with ThreadPoolExecutor(len(seats)) as pool:
        codes = list(pool.map(lambda cs: e2e.hold(cs[0], t, [cs[1]]).status_code, zip(clients, seats)))
    assert codes.count(201) == MAX_LOCKED_SEATS and set(codes) == {201, 429}       # the count and the lock are one step


def test_the_same_booking_key_sent_together_answers_with_one_booking(pax_wallet):
    c, t = pax_wallet
    seats = e2e.free_seats(c, t, 1)
    token = e2e.hold(c, t, seats).json()["hold_token"]
    key = uuid.uuid4().hex
    clients = _clients_of(c, 4)
    with ThreadPoolExecutor(4) as pool:
        answers = list(pool.map(lambda x: e2e.book(x, t, token, seats, key=key), clients))
    assert all(a.status_code == 201 for a in answers), [a.text for a in answers]
    assert len({a.json()["booking_ref"] for a in answers}) == 1
    assert sum(1 for a in answers if not a.json().get("replayed")) == 1


@pytest.fixture()
def pax_wallet():
    c = e2e.new_passenger()
    assert c.post("/api/wallet/topup", json={"amount": 10000000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    t = e2e.bookable_trip(c)
    if t is None:
        e2e.publish_fresh_trip()
        t = e2e.bookable_trip(c)
    return c, t


def test_a_wallet_opened_twice_at_once_is_one_wallet():
    from app import ledger
    party = owner_sql("SELECT id FROM iam.party WHERE party_type = 'PERSON' ORDER BY id DESC LIMIT 1")
    currency = owner_sql("""SELECT code FROM ref.currency c WHERE NOT EXISTS (SELECT 1 FROM fin.wallet w WHERE w.owner_party_id = $1
                              AND w.wallet_type = 'USER' AND w.currency = c.code) ORDER BY code LIMIT 1""", party)

    async def race():
        a, b = await asyncpg.connect(OWNER_URL), await asyncpg.connect(OWNER_URL)
        try:
            ta, tb = a.transaction(), b.transaction()
            await ta.start()
            await tb.start()
            for conn in (a, b):
                await conn.execute("SELECT sys.set_context(NULL, NULL, 'SYSTEM')")
            first = await ledger.user_wallet(a, party, currency)               # opened, not yet committed
            second = asyncio.create_task(ledger.user_wallet(b, party, currency))
            await asyncio.sleep(0.3)
            assert not second.done()                                         # waits for the first, does not fail
            await ta.commit()
            other = await second
            await tb.rollback()
            return first["id"], other["id"]
        finally:
            await a.close()
            await b.close()
    first, other = asyncio.run(race())
    assert first == other


# ------------------------------------------------------------------ positions kept for the telemetry database (R-03)
def test_positions_wait_on_the_primary_while_the_telemetry_database_is_down(monkeypatch):
    from app import db, telemetry
    from app.errors import ApiError
    trip = owner_sql("SELECT id, company_id FROM ops.trip ORDER BY id DESC LIMIT 1", fetch=True)
    now = datetime.now(timezone.utc).replace(microsecond=0)
    event = uuid.uuid4()
    graded = [{"received_at": now, "company_id": trip["company_id"], "vehicle_id": None, "driver_user_id": None,
               "device_id": None, "trust": "HIGH", "trust_flags": []}]
    points = [{"ts": now, "lat": 33.5, "lng": 36.3, "accuracy_m": 5.0, "speed_kmh": None, "event_id": event, "seq": 1,
               "device_ts": now, "provider": "GPS", "is_mock": False}]
    calls: list[list[dict]] = []

    async def store_rows(rows):
        calls.append(rows)
        if len(calls) == 1:
            raise ApiError(503, "TELEMETRY_UNAVAILABLE", "the telemetry database does not answer")
        return [r["trust"] for r in rows]
    monkeypatch.setattr(telemetry, "store_rows", store_rows)
    monkeypatch.setattr(db, "telemetry_pool", lambda: object())

    async def run():
        await db.open_pools()
        try:
            async with db.transaction(db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")) as conn:
                await telemetry.queue(conn, trip["id"], trip["company_id"], graded, points)
            return await telemetry.drain_backlog(), await telemetry.drain_backlog()
        finally:
            await db.close_pools()
    down, up = asyncio.run(run())
    assert down == 0 and up >= 1
    mine = [r for r in calls[-1] if r["event_id"] == event]
    assert mine and mine[0]["ts"] == now and mine[0]["trip_id"] == trip["id"]        # times and ids come back typed
    row = owner_sql("""SELECT attempts, delivered_at IS NOT NULL AS delivered, last_error FROM ops.position_backlog
                        WHERE positions @> jsonb_build_array(jsonb_build_object('event_id', $1::text))""", str(event), fetch=True)
    assert row["delivered"] and row["attempts"] == 2 and "does not answer" in row["last_error"]

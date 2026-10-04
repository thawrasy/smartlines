"""Agency channel end to end: selling from the prepaid balance, commission, daily limit, isolation, cancellation
and the release of the commission when the trip completes."""
import uuid
from datetime import datetime, timezone

import pytest

from test_e2e import (OWNER_URL, bookable_trip, client, free_seats, login, owner_sql, publish_fresh_trip, syrian)

FEE = 100000
RATE_BP = 500


@pytest.fixture(scope="module")
def agency():
    return login("agency@agency.test", "AGENCY")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def agency_uid(admin):
    a = next(a for a in admin.get("/api/admin/agencies").json()["agencies"] if a["legal_name"] == "Demo Travel Agency")
    # Keep the demo agency funded and within its terms whatever earlier runs left behind
    r = admin.post(f"/api/admin/agencies/{a['uid']}/agreement",
                   json={"commission_bp": RATE_BP, "daily_limit": 10_000_000_000, "status": "ACTIVE", "reason": "test run"})
    assert r.status_code == 200, r.text
    r = admin.post(f"/api/admin/agencies/{a['uid']}/deposit",
                   json={"amount": 30_000_000, "bank_reference": "TEST-RUN", "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 200, r.text
    return a["uid"]


@pytest.fixture(scope="module")
def trip(agency_uid):
    c = client()
    t = bookable_trip(c)
    if t is None:
        publish_fresh_trip()
        t = bookable_trip(c)
    assert t
    return t


def sell(agency, trip, seats, brand="STANDARD", key=None):
    h = agency.post("/api/agency/holds", json={"trip_uid": trip["uid"], "from_seq": trip["from_seq"],
                                               "to_seq": trip["to_seq"], "seat_nos": seats})
    assert h.status_code == 201, h.text
    token = h.json()["hold_token"]
    r = agency.post("/api/agency/bookings", json={
        "hold_token": token, "trip_uid": trip["uid"], "from_seq": trip["from_seq"],
        "to_seq": trip["to_seq"], "fare_brand": brand, "passengers": [syrian(s) for s in seats],
        "idempotency_key": key or uuid.uuid4().hex, "contact_mobile": "+963944000111"})
    if r.status_code != 201 or r.json().get("replayed"):
        agency.delete(f"/api/agency/holds/{token}")       # a refused or replayed sale leaves its seats free
    return r


def test_portals_stay_apart():
    c = client()
    r = c.post("/api/auth/login", json={"identifier": "owner@carrier.test", "password": "Masslak-Demo-2026", "portal": "AGENCY"})
    assert r.status_code == 403
    r = c.post("/api/auth/login", json={"identifier": "agency@agency.test", "password": "Masslak-Demo-2026", "portal": "OPERATOR"})
    assert r.status_code == 403
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.get("/api/agency/dashboard").status_code == 403


def test_agency_sells_at_the_public_price_and_earns_commission(agency, trip):
    before = agency.get("/api/agency/dashboard").json()
    assert before["agreement"]["commission_bp"] == RATE_BP
    seats = free_seats(agency, trip, 2)
    key = uuid.uuid4().hex
    r = sell(agency, trip, seats, key=key)
    assert r.status_code == 201, r.text
    out = r.json()
    fares = 2 * trip["price"]
    assert out["total"] == fares + FEE                          # the traveller pays what the website charges
    assert out["commission"] == fares * RATE_BP // 10000 // 100 * 100
    # The sale is idempotent: a retry on a weak network returns the same booking without charging again
    again = sell(agency, trip, free_seats(agency, trip, 2), key=key)
    assert again.json() == {"booking_ref": out["booking_ref"], "replayed": True}
    after = agency.get("/api/agency/dashboard").json()
    assert before["balance"] - after["balance"] == out["total"]
    assert after["sold_today"] - before["sold_today"] == out["total"]
    detail = agency.get(f"/api/agency/bookings/{out['booking_ref']}").json()
    assert detail["booking"]["commission"] == out["commission"]
    assert detail["booking"]["contact_mobile"] == "+963944000111"
    assert all(t["ticket_name"].startswith("Rami Haddad") and "Khaled" not in t["ticket_name"] for t in detail["tickets"])
    qr = agency.get(f"/api/agency/tickets/{detail['tickets'][0]['uid']}/qr")
    assert qr.status_code == 200 and qr.json()["token"]
    found = agency.get("/api/agency/bookings", params={"q": "+963944000111"}).json()["bookings"]
    assert any(b["booking_ref"] == out["booking_ref"] for b in found)
    pytest.agency_ref, pytest.agency_total, pytest.agency_commission = out["booking_ref"], out["total"], out["commission"]


def test_agency_booking_is_private_to_the_agency(agency):
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.get(f"/api/bookings/{pytest.agency_ref}").status_code == 404
    mine = pax.get("/api/bookings").json()["bookings"]
    if mine:   # and the agency cannot open a passenger's own booking
        assert agency.get(f"/api/agency/bookings/{mine[0]['booking_ref']}").status_code == 404


def test_daily_limit_is_enforced(agency, admin, agency_uid, trip):
    sold = agency.get("/api/agency/dashboard").json()["sold_today"]
    r = admin.post(f"/api/admin/agencies/{agency_uid}/agreement",
                   json={"commission_bp": RATE_BP, "daily_limit": sold + 1000, "status": "ACTIVE", "reason": "limit test"})
    assert r.status_code == 200
    try:
        r = sell(agency, trip, free_seats(agency, trip, 1))
        assert r.status_code == 409 and r.json()["error"]["code"] == "AGENCY_DAILY_LIMIT", r.text
        assert r.json()["error"]["remaining"] == 1000
    finally:
        admin.post(f"/api/admin/agencies/{agency_uid}/agreement",
                   json={"commission_bp": RATE_BP, "daily_limit": 10_000_000_000, "status": "ACTIVE", "reason": "restore"})


def test_suspended_agency_cannot_sell(agency, admin, agency_uid, trip):
    admin.post(f"/api/admin/agencies/{agency_uid}/agreement",
               json={"commission_bp": RATE_BP, "daily_limit": 10_000_000_000, "status": "SUSPENDED", "reason": "test"})
    try:
        r = agency.post("/api/agency/holds", json={"trip_uid": trip["uid"], "from_seq": trip["from_seq"],
                                                   "to_seq": trip["to_seq"], "seat_nos": free_seats(agency, trip, 1)})
        assert r.status_code == 403 and r.json()["error"]["code"] == "AGENCY_SUSPENDED"
    finally:
        admin.post(f"/api/admin/agencies/{agency_uid}/agreement",
                   json={"commission_bp": RATE_BP, "daily_limit": 10_000_000_000, "status": "ACTIVE", "reason": "restore"})


def expected_refund(fare_total: int, departs_at: str) -> int:
    hours = (datetime.fromisoformat(departs_at) - datetime.now(timezone.utc)).total_seconds() / 3600
    return fare_total * (100 if hours >= 24 else 50 if hours >= 2 else 0) // 100


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to check the allocation")
def test_cancellation_refunds_the_agency_and_keeps_commission_in_proportion(agency, trip):
    r = sell(agency, trip, free_seats(agency, trip, 1))
    assert r.status_code == 201, r.text
    sale = r.json()
    balance = agency.get("/api/agency/dashboard").json()["balance"]
    c = agency.post(f"/api/agency/bookings/{sale['booking_ref']}/cancel")
    assert c.status_code == 200, c.text
    refund = c.json()["refund"]
    assert refund == expected_refund(trip["price"], trip["departs_at"])
    assert agency.get("/api/agency/dashboard").json()["balance"] - balance == refund
    fares = trip["price"]
    assert c.json()["commission_kept"] == sale["commission"] * (fares - refund) // fares
    # What the allocation still owes equals what stayed in escrow
    due = owner_sql("""SELECT sum(l.amount - l.refunded_amount) FROM fin.price_allocation_line l
                         JOIN sales.booking b ON b.price_allocation_id = l.allocation_id WHERE b.booking_ref = $1""",
                    sale["booking_ref"])
    assert due == sale["total"] - refund


def test_statement_lists_the_sales(agency):
    st = agency.get("/api/agency/statement").json()
    assert st["total_debit"] >= pytest.agency_total
    assert any(e["txn_type"] == "BOOKING_PAY" and e["memo"] == pytest.agency_ref for e in st["entries"])
    assert st["closing_balance"] == st["opening_balance"] + st["total_credit"] - st["total_debit"]
    assert agency.get("/api/agency/statement", params={"month": "2026-13"}).status_code == 422


def test_new_agency_staff_must_use_a_second_factor(agency):
    email = f"seller{uuid.uuid4().hex[:8]}@example.com"
    r = agency.post("/api/agency/staff", json={"full_name": "Sami Seller", "email": email,
                                                "password": "a-long-seller-password", "role": "SELLER"})
    assert r.status_code == 201, r.text
    assert any(s["email"] == email and s["role"] == "AGENCY_SELLER" for s in agency.get("/api/agency/staff").json()["staff"])
    c = client()
    r = c.post("/api/auth/login", json={"identifier": email, "password": "a-long-seller-password", "portal": "AGENCY"})
    assert r.status_code == 200 and r.json()["mfa"] == "ENROLL"
    assert c.get("/api/agency/dashboard").json()["error"]["code"] == "MFA_REQUIRED"


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to move a trip into the past")
def test_commission_is_released_to_the_agency_when_the_trip_completes(agency, trip):
    o = login("owner@carrier.test", "OPERATOR")
    owner_sql("""UPDATE ops.trip SET departure_at = now() - make_interval(days => d, hours => 6),
                                     arrival_at = now() - make_interval(days => d, hours => 1)
                   FROM (SELECT count(*)::int AS d FROM ops.trip WHERE departure_at < now() - interval '2 hours') past
                 WHERE uid = $1""", uuid.UUID(trip["uid"]))
    before = agency.get("/api/agency/dashboard").json()
    r = o.post(f"/api/carrier/trips/{trip['uid']}/complete")
    assert r.status_code == 200, r.text
    after = agency.get("/api/agency/dashboard").json()
    assert after["balance"] - before["balance"] >= pytest.agency_commission
    assert after["commission_released"] - before["commission_released"] >= pytest.agency_commission

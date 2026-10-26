"""The miles programme (owner's note 19, migration 1166): name and unit as settings, a chart of miles per pair of
stations that boarded tickets earn by, award tickets shown but not redeemed in the first phase, partners active only
with a contract number, and the partners corner with promoted partners labelled only while that display is on."""
import uuid

import pytest

from test_e2e import OWNER_URL, day, free_seats, login, owner_sql, syrian
from test_use_case_gaps import fresh_trip

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


def test_the_programme_name_and_unit_are_settings(admin):
    shown = login("passenger@masslak.test", "PASSENGER").get("/api/loyalty/programme").json()
    assert shown["programme"]["unit_en"] and shown["programme"]["name_ar"] and shown["award_redemption"] is False
    assert shown["promoted_display"] is False
    current = admin.get("/api/admin/miles").json()["programme"]
    body = {"name": "Masslak Miles", "name_ar": current["name_ar"], "unit_en": "miles", "unit_ar": current["unit_ar"], "expiry_months": 24}
    assert admin.put("/api/admin/miles/programme", json=body).json() == {"ok": True}
    assert login("passenger@masslak.test", "PASSENGER").put("/api/admin/miles/programme", json=body).status_code == 403


def test_a_ticket_between_two_stations_of_the_chart_earns_its_miles(admin):
    trip = fresh_trip()
    ends = owner_sql("""SELECT (SELECT s.code FROM ops.trip_stop t JOIN net.station s ON s.id = t.station_id WHERE t.trip_id = $1 ORDER BY t.seq LIMIT 1) AS a,
                               (SELECT s.code FROM ops.trip_stop t JOIN net.station s ON s.id = t.station_id WHERE t.trip_id = $1 ORDER BY t.seq DESC LIMIT 1) AS b""",
                     trip["id"], fetch=True)
    assert admin.post("/api/admin/miles/chart", json={"from_station": ends["a"], "to_station": ends["a"], "miles": 10}).json()["error"]["code"] == "SAME_STATION"
    made = admin.post("/api/admin/miles/chart", json={"from_station": ends["b"], "to_station": ends["a"], "miles": 999})
    assert made.status_code == 201, made.text
    chart = made.json()["id"]
    try:
        pax = login("passenger@masslak.test", "PASSENGER")
        # either direction of the pair
        assert pax.get("/api/loyalty/miles", params={"from": ends["a"], "to": ends["b"]}).json()["miles"] == 999
        assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
        before = (pax.get("/api/loyalty").json().get("account") or {}).get("balance", 0)
        t = next(x for x in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
                 if x["uid"] == str(trip["uid"]))
        seat = free_seats(pax, t, 1)[0]
        h = pax.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]})
        r = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"],
                                            "to_seq": t["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 201, r.text
        ref = r.json()["booking_ref"]
        multiplier = owner_sql("""SELECT pricing.tier_multiplier(a.tier_id) FROM pricing.points_account a JOIN iam.app_user u ON u.party_id = a.party_id
                                   WHERE u.email = 'passenger@masslak.test' ORDER BY a.id LIMIT 1""") or 1
        owner_sql("""UPDATE ops.trip SET status = 'DEPARTED', departure_at = now() - interval '4 hours', arrival_at = now() - interval '1 hour'
                      WHERE id = $1""", trip["id"])
        owner_sql("""UPDATE sales.ticket SET status = 'BOARDED', boarded_at = now() - interval '4 hours'
                      WHERE booking_id = (SELECT id FROM sales.booking WHERE booking_ref = $1)""", ref)
        done = login("owner@carrier.test", "OPERATOR").post(f"/api/carrier/trips/{trip['uid']}/complete")
        assert done.status_code == 200, done.text
        earned = int(999 * multiplier)
        assert pax.get("/api/loyalty").json()["account"]["balance"] == before + earned
        assert owner_sql("""SELECT l.rule_id IS NULL AND l.idempotency_key LIKE 'earn:%:chart:%' FROM pricing.points_ledger l
                             JOIN sales.booking b ON b.id = l.booking_id WHERE b.booking_ref = $1""", ref)
    finally:
        assert admin.post(f"/api/admin/miles/chart/{chart}/retire").json() == {"status": "RETIRED"}


def test_award_tickets_are_shown_and_wait_for_the_redemption_switch(admin):
    a = owner_sql("SELECT code FROM net.station WHERE code LIKE 'SY-DAM-C%' AND status = 'ACTIVE' ORDER BY code LIMIT 1")
    b = owner_sql("SELECT code FROM net.station WHERE code LIKE 'SY-HMS-C%' AND status = 'ACTIVE' ORDER BY code LIMIT 1")
    made = admin.post("/api/admin/miles/awards", json={"from_station": a, "to_station": b, "miles": 5000, "fee": 50000, "reduced_amount": 100000})
    assert made.status_code == 201, made.text
    try:
        shown = login("passenger@masslak.test", "PASSENGER").get("/api/loyalty/awards").json()
        mine = next(x for x in shown["awards"] if x["uid"] == made.json()["uid"])
        assert shown["redeemable"] is False and mine["miles"] == 5000 and mine["fee"] == 50000 and mine["reduced_amount"] == 100000
    finally:
        assert admin.post(f"/api/admin/miles/awards/{made.json()['uid']}/retire").json() == {"status": "RETIRED"}


def test_partners_need_a_contract_and_promoted_ones_are_labelled_only_when_shown(admin):
    program = owner_sql("SELECT id FROM pricing.loyalty_program WHERE status = 'ACTIVE' ORDER BY id LIMIT 1")
    party = owner_sql("""SELECT p.id FROM iam.party p WHERE p.party_type = 'COMPANY'
                          AND NOT EXISTS (SELECT 1 FROM pricing.loyalty_partner lp WHERE lp.program_id = $1 AND lp.party_id = p.id)
                        ORDER BY p.id DESC LIMIT 1""", program)
    partner = owner_sql("""INSERT INTO pricing.loyalty_partner (program_id, party_id, partner_type) VALUES ($1, $2, 'SHOP') RETURNING id""", program, party)
    bad = admin.put(f"/api/admin/miles/partners/{partner}", json={"status": "ACTIVE", "promoted": True})
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "PARTNER_CONTRACT_REQUIRED"
    ok = admin.put(f"/api/admin/miles/partners/{partner}", json={"status": "ACTIVE", "contract_ref": "LP-2026-014", "corner_note": "10% off",
                                                                 "promoted": True})
    assert ok.status_code == 200, ok.text
    pax = login("passenger@masslak.test", "PASSENGER")
    corner = pax.get("/api/loyalty/corner").json()
    shop = next(p for p in corner["partners"] if p["id"] == partner)
    assert corner["promoted_display"] is False and shop["promoted"] is False and shop["corner_note"] == "10% off"
    try:
        assert admin.put("/api/admin/miles/settings", json={"promoted_display": True}).json()["promoted_display"] is True
        corner = pax.get("/api/loyalty/corner").json()
        assert corner["partners"][0]["promoted"] is True and any(p["id"] == partner and p["promoted"] for p in corner["partners"])
    finally:
        assert admin.put("/api/admin/miles/settings", json={"promoted_display": False}).json() == {"award_redemption": False, "promoted_display": False}
        admin.put(f"/api/admin/miles/partners/{partner}", json={"status": "ENDED", "promoted": False})

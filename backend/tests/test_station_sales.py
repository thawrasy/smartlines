"""Tickets sold at a station's counter under the carrier's BOOKING right (migration 1110; owner's decision: first
release): refused without the right; with it, the counter holds seats, sells for cash and prints the tickets; the cash
is owed by the operating company within its limit; the carrier sees the sale on its trip; a cash sale cancelled at the
counter is refunded from the drawer; another company's sale stays invisible."""
import uuid

import pytest

from test_boarding_stations import ADMIN, CARRIER, set_setting, station_session, stations_module
from test_e2e import OWNER_URL, day, free_seats, login, owner_sql, settle_password, syrian
from test_use_case_gaps import fresh_trip


@pytest.fixture(scope="module")
def admin():
    return login(*ADMIN)


def _company(admin, name):
    email = f"sales-{uuid.uuid4().hex[:8]}@example.com"
    password = f"Harbor-{uuid.uuid4().hex[:10]}-26!q"
    r = admin.post("/api/admin/boarding/operating-companies", json={
        "legal_name": name, "owner_name": "Counter Owner", "owner_email": email, "owner_password": password})
    assert r.status_code == 201, r.text
    settle_password(email)
    return {"uid": r.json()["uid"], "email": email, "password": password}


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_station_counter_sells_a_carriers_tickets_for_cash_under_its_booking_right(admin):
    carrier = login(*CARRIER)
    company = _company(admin, "Central Station Sales")
    other = _company(admin, "Other Station Sales")
    trip = fresh_trip()
    station = owner_sql("""SELECT s.uid FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                            WHERE ts.trip_id = $1 AND ts.seq = 0""", trip["id"])
    clerk = station_session(company)
    stranger = station_session(other)
    pax = login("passenger@masslak.test", "PASSENGER")
    t = next(x for x in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
             if x["uid"] == str(trip["uid"]))
    grants = []
    stations_module(admin, True)
    try:
        set_setting(admin, "boarding.stations.enabled", True)
        set_setting(admin, "boarding.mode.carrier_contracted", True)
        assert admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": True}).status_code == 200
        counter = admin.post(f"/api/admin/boarding/stations/{station}/gates",
                             json={"gate_type": "COUNTER", "operator_company_uid": company["uid"]}).json()["code"]
        seats = free_seats(pax, t, 2)
        hold = {"station_uid": str(station), "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seats[0]]}
        # without the carrier's BOOKING right, the counter cannot even hold a seat
        r = clerk.post("/api/station/holds", json=hold)
        assert r.status_code == 409 and r.json()["error"]["code"] == "NOT_GRANTED", r.text
        g = carrier.post("/api/carrier/station-operators/grants",
                         json={"operator_company_uid": company["uid"], "station_uid": str(station), "permission": "BOOKING"})
        assert g.status_code == 201, g.text
        grants.append(g.json()["uid"])
        listed = next(x for x in clerk.get("/api/station/trips", params={"station_uid": str(station)}).json()["trips"]
                      if x["trip_uid"] == str(trip["uid"]))
        assert listed["may_sell"] and not listed["may_check_in"]
        assert stranger.post("/api/station/holds", json=hold).json()["error"]["code"] == "NOT_GRANTED"
        # the sale: held, priced and sold for cash; the tickets are issued at once
        h = clerk.post("/api/station/holds", json=hold)
        assert h.status_code == 201, h.text
        booking = {"station_uid": str(station), "counter_code": counter, "hold_token": h.json()["hold_token"], "trip_uid": t["uid"],
                   "from_seq": t["from_seq"], "to_seq": t["to_seq"], "passengers": [syrian(seats[0])],
                   "idempotency_key": uuid.uuid4().hex, "contact_mobile": "+963944000111"}
        q = clerk.post("/api/station/bookings/quote", json=booking)
        assert q.status_code == 200, q.text
        owed = clerk.get("/api/station/cash").json()["owed"]
        sold = clerk.post("/api/station/bookings", json=booking)
        assert sold.status_code == 201 and sold.json()["status"] == "CONFIRMED", sold.text
        ref, total = sold.json()["booking_ref"], sold.json()["total"]
        assert clerk.post("/api/station/bookings", json=booking).json()["replayed"]
        assert clerk.get("/api/station/cash").json()["owed"] == owed + total
        detail = clerk.get(f"/api/station/bookings/{ref}").json()
        assert detail["booking"]["refundable_here"] and len(detail["tickets"]) == 1
        qr = clerk.get(f"/api/station/tickets/{detail['tickets'][0]['uid']}/qr")
        assert qr.status_code == 200
        # paper carries the ticket's signed code, not the rotating one (design review of the station screens)
        paper = clerk.get(f"/api/station/tickets/{detail['tickets'][0]['uid']}/offline")
        assert paper.status_code == 200 and paper.json()["credential"].startswith("T2."), paper.text
        assert stranger.get(f"/api/station/tickets/{detail['tickets'][0]['uid']}/offline").status_code == 404
        day_sales = clerk.get("/api/station/bookings", params={"station_uid": str(station)}).json()
        assert any(x["booking_ref"] == ref and x["counter"] == counter for x in day_sales["bookings"]) and day_sales["total"] >= total
        # the booking is the carrier's: it sees it on its trip; another operating company does not
        assert owner_sql("SELECT company_id FROM sales.booking WHERE booking_ref = $1", ref) == owner_sql(
            "SELECT company_id FROM ops.trip WHERE id = $1", trip["id"])
        assert owner_sql("SELECT count(*) FROM brd.station_sale s JOIN sales.booking b ON b.id = s.booking_id WHERE b.booking_ref = $1", ref) == 1
        assert stranger.get(f"/api/station/bookings/{ref}").status_code == 404
        # cancelled at the counter: what the fare refunds comes back in cash from the drawer, lowering what is owed
        c = clerk.post(f"/api/station/bookings/{ref}/cancel")
        assert c.status_code == 200, c.text
        assert clerk.get("/api/station/cash").json()["owed"] == owed + total - c.json()["refund"]
        # the platform sees the company's cash position with the carriers'
        finance = login("finance@masslak.test", "PLATFORM")
        positions = finance.get("/api/admin/cash/positions").json()
        rows = positions.get("positions", positions) if isinstance(positions, dict) else positions
        assert any(p["name"] == "Central Station Sales" for p in rows)
    finally:
        for g in grants:
            carrier.post(f"/api/carrier/station-operators/grants/{g}/revoke")
        set_setting(admin, "boarding.mode.carrier_contracted", False)
        set_setting(admin, "boarding.stations.enabled", False)
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": False})
        stations_module(admin, False)
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])

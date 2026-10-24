"""The counter check and the boarding pass at a boarding station (build step 3, migration 1105): the operating company
checks a passenger in at its own counter with the carrier's BOARDING_PASS right, the pass prints the bay, the check-in
window and the carrier's required references are applied, and station staff with the BOARDING right board only
checked-in tickets. Every action is in the activity log."""
import uuid
from datetime import datetime, timedelta

import pytest

from test_boarding_stations import ADMIN, CARRIER, set_setting, station_session, stations_module
from test_e2e import OWNER_URL, day, free_seats, login, owner_sql, syrian
from test_use_case_gaps import fresh_trip


@pytest.fixture(scope="module")
def admin():
    return login(*ADMIN)


@pytest.fixture(scope="module")
def operating_company(admin):
    email = f"counter-{uuid.uuid4().hex[:8]}@example.com"
    password = f"Harbor-{uuid.uuid4().hex[:10]}-26!q"
    r = admin.post("/api/admin/boarding/operating-companies", json={
        "legal_name": "Central Station Counters", "owner_name": "Counter Owner", "owner_email": email, "owner_password": password})
    assert r.status_code == 201, r.text
    return {"uid": r.json()["uid"], "email": email, "password": password}


def book(pax, trip):
    t = next(x for x in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
             if x["uid"] == str(trip["uid"]))
    seat = free_seats(pax, t, 1)[0]
    h = pax.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]})
    r = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"],
                                        "to_seq": t["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    detail = pax.get(f"/api/bookings/{r.json()['booking_ref']}").json()
    return r.json()["booking_ref"], detail["tickets"][0]


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_counter_check_boarding_pass_and_boarding_at_the_bay(admin, operating_company):
    carrier = login(*CARRIER)
    trip = fresh_trip()
    station = owner_sql("""SELECT s.uid FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                            WHERE ts.trip_id = $1 AND ts.seq = 0""", trip["id"])
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    ref, ticket = book(pax, trip)
    _, other = book(pax, trip)
    token = pax.get(f"/api/tickets/{ticket['uid']}/qr").json()["token"]
    counter_staff = station_session(operating_company)
    grants = []
    stations_module(admin, True)
    try:
        set_setting(admin, "boarding.stations.enabled", True)
        set_setting(admin, "boarding.mode.carrier_contracted", True)
        assert admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": True}).status_code == 200
        counter = admin.post(f"/api/admin/boarding/stations/{station}/gates",
                             json={"gate_type": "COUNTER", "operator_company_uid": operating_company["uid"]}).json()["code"]
        bay = admin.post(f"/api/admin/boarding/stations/{station}/gates", json={"gate_type": "BAY"}).json()["code"]
        owner_sql("""UPDATE ops.trip_stop SET gate_id = (SELECT g.id FROM net.station_gate g JOIN net.station s ON s.id = g.station_id
                                                          WHERE s.uid = $2 AND g.code = $3) WHERE trip_id = $1 AND seq = 0""",
                  trip["id"], station, bay)
        body = {"station_uid": str(station), "counter_code": counter, "token": token, "document_checked": True}
        # without the carrier's right, no pass
        r = counter_staff.post("/api/station/checkin", json=body)
        assert r.status_code == 409 and r.json()["error"]["code"] == "NOT_GRANTED", r.text
        for right in ("BOARDING_PASS", "BOARDING"):
            g = carrier.post("/api/carrier/station-operators/grants",
                             json={"operator_company_uid": operating_company["uid"], "station_uid": str(station), "permission": right})
            assert g.status_code == 201, g.text
            grants.append(g.json()["uid"])
        listed = next(x for x in counter_staff.get("/api/station/trips", params={"station_uid": str(station)}).json()["trips"]
                      if x["trip_uid"] == str(trip["uid"]))
        assert listed["may_check_in"] and listed["may_board"] and listed["bay"] == bay and listed["tickets"] >= 2
        # where the trip goes, for the counter (1113)
        assert listed["dest_city"] == "ALP" and listed["dest_code"] and listed["dest_name"]
        # the passenger's photo is not shown at the counter: off until a legal approval allows it (build step 5, 1111)
        shown = counter_staff.get(f"/api/station/tickets/{ticket['uid']}/photo", params={"station_uid": str(station)})
        assert shown.status_code in (403, 404) and shown.json()["error"]["code"] in ("PHOTO_VIEW_NOT_ALLOWED", "PHOTO_DISABLED"), shown.text
        # the counter check: the pass prints the bay and the counter
        r = counter_staff.post("/api/station/checkin", json=body)
        assert r.status_code == 201, r.text
        bp = r.json()
        assert bp["bay"] == bay and bp["counter"] == counter and bp["ticket_no"] == ticket["ticket_no"] and not bp["repeated"]
        # the pass carries the ticket's signed code, so the bay and the driver's app scan the paper (1113)
        assert bp["ticket_uid"] == ticket["uid"] and bp["credential"].startswith("T2."), bp
        # typed at the counter: number and booking reference give the same pass
        again = counter_staff.post("/api/station/checkin", json={**body, "token": None, "ticket_no": ticket["ticket_no"], "booking_ref": ref})
        assert again.status_code == 201 and again.json()["pass_no"] == bp["pass_no"] and again.json()["repeated"]
        got = counter_staff.get(f"/api/station/passes/{bp['pass_no']}")
        assert got.status_code == 200 and got.json()["pass_no"] == bp["pass_no"] and got.json()["credential"].startswith("T2."), got.text
        assert counter_staff.post("/api/station/checkin", json={**body, "token": None, "ticket_no": ticket["ticket_no"],
                                                                "booking_ref": "WRONG1"}).status_code == 422
        # the carrier's required references: a missing one stops the check-in of the next passenger
        set_setting(admin, "boarding.references.required", ["LIC-STATION-TEST"])
        other_token = pax.get(f"/api/tickets/{other['uid']}/qr").json()["token"]
        r = counter_staff.post("/api/station/checkin", json={**body, "token": other_token})
        assert r.status_code == 409 and r.json()["error"]["code"] == "REFERENCES_MISSING", r.text
        set_setting(admin, "boarding.references.required", [])
        # boarding at the bay: the checked-in ticket boards once; the other one, not checked in, does not
        trip_uid = str(trip["uid"])
        token = pax.get(f"/api/tickets/{ticket['uid']}/qr").json()["token"]
        assert counter_staff.post("/api/station/board", json={"station_uid": str(station), "trip_uid": trip_uid, "token": token}).json()["result"] == "OK"
        assert counter_staff.post("/api/station/board", json={"station_uid": str(station), "trip_uid": trip_uid, "token": token}).json()["result"] == "DUPLICATE"
        # the code printed on the pass names the same ticket
        assert counter_staff.post("/api/station/board", json={"station_uid": str(station), "trip_uid": trip_uid,
                                                              "token": bp["credential"]}).json()["result"] == "DUPLICATE"
        other_token = pax.get(f"/api/tickets/{other['uid']}/qr").json()["token"]
        assert counter_staff.post("/api/station/board", json={"station_uid": str(station), "trip_uid": trip_uid,
                                                              "token": other_token}).json()["result"] == "CHECKIN_REQUIRED"
        cancel = counter_staff.post(f"/api/station/passes/{bp['pass_no']}/cancel", json={"reason": "too late"})
        assert cancel.status_code == 409 and cancel.json()["error"]["code"] == "ALREADY_BOARDED"
        assert owner_sql("SELECT status FROM sales.ticket WHERE uid = $1::uuid", ticket["uid"]) == "BOARDED"
        # the activity log keeps who did what, at which counter
        assert owner_sql("""SELECT count(*) FROM audit.activity_log WHERE action = 'boarding.checkin' AND reason LIKE $1""",
                         f"pass {bp['pass_no']} at counter {counter}%") >= 1
        assert owner_sql("SELECT count(*) FROM audit.activity_log WHERE action = 'boarding.station_scan'") >= 1
        # the carrier sees the check-ins on its trips
        assert owner_sql("SELECT operator_company_id IS NOT NULL FROM brd.station_checkin WHERE pass_no = $1", bp["pass_no"])
    finally:
        for g in grants:
            carrier.post(f"/api/carrier/station-operators/grants/{g}/revoke")
        set_setting(admin, "boarding.references.required", [])
        set_setting(admin, "boarding.mode.carrier_contracted", False)
        set_setting(admin, "boarding.stations.enabled", False)
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": False})
        stations_module(admin, False)
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_the_check_in_window_of_the_station_is_applied(admin, operating_company):
    carrier = login(*CARRIER)
    trip = fresh_trip()
    station = owner_sql("""SELECT s.uid FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                            WHERE ts.trip_id = $1 AND ts.seq = 0""", trip["id"])
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    _, ticket = book(pax, trip)
    counter_staff = station_session(operating_company)
    stations_module(admin, True)
    grant = None
    try:
        set_setting(admin, "boarding.stations.enabled", True)
        set_setting(admin, "boarding.mode.carrier_contracted", True)
        # the trip leaves in two days: a window opening two hours before departure is not open yet
        assert admin.put(f"/api/admin/boarding/stations/{station}",
                         json={"enabled": True, "checkin_opens_minutes": 120, "checkin_closes_minutes": 30}).status_code == 200
        counter = admin.post(f"/api/admin/boarding/stations/{station}/gates",
                             json={"gate_type": "COUNTER", "operator_company_uid": operating_company["uid"]}).json()["code"]
        g = carrier.post("/api/carrier/station-operators/grants",
                         json={"operator_company_uid": operating_company["uid"], "station_uid": str(station), "permission": "BOARDING_PASS"})
        grant = g.json()["uid"]
        token = pax.get(f"/api/tickets/{ticket['uid']}/qr").json()["token"]
        r = counter_staff.post("/api/station/checkin", json={"station_uid": str(station), "counter_code": counter, "token": token,
                                                             "document_checked": True})
        assert r.status_code == 409 and r.json()["error"]["code"] == "CHECKIN_NOT_OPEN", r.text
        # the counter's list shows when the window opens and closes for the trip (1113)
        listed = next(x for x in counter_staff.get("/api/station/trips", params={"station_uid": str(station)}).json()["trips"]
                      if x["trip_uid"] == str(trip["uid"]))
        departs = datetime.fromisoformat(listed["departs_at"])
        assert departs - datetime.fromisoformat(listed["checkin_opens_at"]) == timedelta(minutes=120)
        assert departs - datetime.fromisoformat(listed["checkin_closes_at"]) == timedelta(minutes=30)
    finally:
        if grant:
            carrier.post(f"/api/carrier/station-operators/grants/{grant}/revoke")
        set_setting(admin, "boarding.mode.carrier_contracted", False)
        set_setting(admin, "boarding.stations.enabled", False)
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": False})
        stations_module(admin, False)
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


def test_a_pass_issued_before_the_ticket_opens_says_when_its_code_is_ready(monkeypatch):
    """The signed code exists only from the hours before departure the platform sets: a pass issued earlier carries no
    code and says from when it is ready, and a cancelled pass carries none (design review of the station screens, 1113)."""
    import asyncio

    from app.errors import ApiError
    from app.modules.boarding import api as boarding

    async def not_yet(conn, ctx, ticket_uid):
        raise ApiError(409, "TICKET_NOT_YET", "the ticket opens three hours before departure", opens_at="2026-10-14T05:00:00+00:00")
    monkeypatch.setattr(boarding.sales, "offline_credential", not_yet)
    out = asyncio.run(boarding._with_code(None, None, {"status": "CHECKED_IN", "ticket_uid": str(uuid.uuid4())}))
    assert out["credential"] is None and out["credential_opens_at"] == "2026-10-14T05:00:00+00:00"
    out = asyncio.run(boarding._with_code(None, None, {"status": "CANCELLED", "ticket_uid": str(uuid.uuid4())}))
    assert out["credential"] is None and "credential_opens_at" not in out

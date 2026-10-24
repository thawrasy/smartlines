"""A station counter for the browser checks of the web interface (frontend/e2e/ui-checks.mjs, design review of the
station screens, October 2026). Run against the API after the end-to-end tests: it switches boarding stations on at the
station of a fresh trip leaving within the hour, opens two counters and two bays there for a new operating company, has
the carrier give it the three rights, books two tickets, checks one in and sells one at the counter, then writes the
clerk's session (signed in with the second factor) and what the station pages need to a JSON file the checks read
through MASSLAK_UI_STATION.

    cd backend && python tests/ui_station_setup.py ../station-ui.json
"""
import json
import os
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.dirname(HERE)]          # the test helpers and the application, as pytest finds them

from test_boarding_stations import set_setting, station_session, stations_module  # noqa: E402
from test_e2e import free_seats, login, owner_sql, syrian  # noqa: E402
from test_use_case_gaps import fresh_trip  # noqa: E402


def main(out: str) -> None:
    admin = login("admin@masslak.test", "PLATFORM")
    carrier = login("owner@carrier.test", "OPERATOR")
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 1_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200

    company = {"email": f"ui-station-{uuid.uuid4().hex[:8]}@example.com", "password": f"Cedar-{uuid.uuid4().hex[:10]}-26!q"}
    r = admin.post("/api/admin/boarding/operating-companies", json={
        "legal_name": "UI Check Station Services", "owner_name": "UI Check Clerk",
        "owner_email": company["email"], "owner_password": company["password"]})
    assert r.status_code == 201, r.text
    company["uid"] = r.json()["uid"]

    trip = fresh_trip()                      # leaves within the hour, so its check-in window is open
    owner_sql("""WITH d AS (SELECT now() + interval '60 minutes' - sched_dep AS delta FROM ops.trip_stop WHERE trip_id = $1 AND seq = 0)
                 UPDATE ops.trip_stop s SET sched_dep = s.sched_dep + d.delta, sched_arr = s.sched_arr + d.delta FROM d WHERE s.trip_id = $1""",
              trip["id"])
    owner_sql("""UPDATE ops.trip t SET departure_at = (SELECT sched_dep FROM ops.trip_stop WHERE trip_id = t.id AND seq = 0),
                 arrival_at = (SELECT coalesce(sched_arr, sched_dep) FROM ops.trip_stop WHERE trip_id = t.id ORDER BY seq DESC LIMIT 1)
                 WHERE id = $1""", trip["id"])
    station = str(owner_sql("SELECT s.uid FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id WHERE ts.trip_id = $1 AND ts.seq = 0",
                            trip["id"]))
    stations_module(admin, True)
    for key, value in (("boarding.stations.enabled", True), ("boarding.mode.carrier_contracted", True),
                       ("boarding.checkin.opens_minutes", 180), ("boarding.checkin.closes_minutes", 20)):
        set_setting(admin, key, value)
    # the operating company is also the station's administration, so the bays page has a station to show (1115)
    assert admin.put(f"/api/admin/boarding/stations/{station}",
                     json={"enabled": True, "displays": True, "manager_company_uid": company["uid"]}).status_code == 200

    def gate(kind, who=None):
        g = admin.post(f"/api/admin/boarding/stations/{station}/gates", json={"gate_type": kind, **({"operator_company_uid": who} if who else {})})
        assert g.status_code == 201, g.text
        return g.json()["code"]
    counter = gate("COUNTER", company["uid"])
    gate("COUNTER", company["uid"])
    bay = gate("BAY")
    gate("BAY")
    owner_sql("""UPDATE ops.trip_stop SET gate_id = (SELECT g.id FROM net.station_gate g JOIN net.station s ON s.id = g.station_id
                 WHERE s.uid = $2 AND g.code = $3) WHERE trip_id = $1 AND seq = 0""", trip["id"], uuid.UUID(station), bay)
    for right in ("BOOKING", "BOARDING_PASS", "BOARDING"):
        g = carrier.post("/api/carrier/station-operators/grants", json={"operator_company_uid": company["uid"], "station_uid": station, "permission": right})
        assert g.status_code == 201, g.text
    carrier.post("/api/carrier/references", json={"kind": "AGREEMENT", "reference_no": "AG-UI-0001", "issued_by": "Masslak"})

    last = owner_sql("SELECT max(seq) FROM ops.trip_stop WHERE trip_id = $1", trip["id"])
    leg = {"uid": str(trip["uid"]), "from_seq": 0, "to_seq": last}
    seats = free_seats(pax, leg, 2)
    h = pax.post("/api/holds", json={"trip_uid": leg["uid"], "from_seq": 0, "to_seq": last, "seat_nos": seats})
    assert h.status_code == 201, h.text
    b = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": leg["uid"], "from_seq": 0, "to_seq": last,
                                        "passengers": [syrian(s) for s in seats], "idempotency_key": uuid.uuid4().hex})
    assert b.status_code == 201, b.text
    ticket = pax.get(f"/api/bookings/{b.json()['booking_ref']}").json()["tickets"][0]

    clerk = station_session(company)
    token = pax.get(f"/api/tickets/{ticket['uid']}/qr").json()["token"]
    c = clerk.post("/api/station/checkin", json={"station_uid": station, "counter_code": counter, "token": token, "document_checked": True})
    assert c.status_code == 201, c.text
    seat = free_seats(pax, leg, 1)
    h = clerk.post("/api/station/holds", json={"station_uid": station, "trip_uid": leg["uid"], "from_seq": 0, "to_seq": last, "seat_nos": seat})
    assert h.status_code == 201, h.text
    sold = clerk.post("/api/station/bookings", json={
        "station_uid": station, "counter_code": counter, "hold_token": h.json()["hold_token"], "trip_uid": leg["uid"], "from_seq": 0,
        "to_seq": last, "passengers": [syrian(seat[0])], "idempotency_key": uuid.uuid4().hex, "contact_mobile": "+963944000111"})
    assert sold.status_code == 201, sold.text

    browser = station_session(company)     # a session of its own for the browser (a code is used once)
    # a departures screen and an arrivals screen, registered by the station's administration (1120)
    screens = {}
    for kind, label in (("DEPARTURES", "Main hall"), ("ARRIVALS", "Arrivals hall")):
        r = browser.post("/api/station/screens", json={"station_uid": station, "kind": kind, "label": label})
        assert r.status_code == 201, r.text
        screens[kind] = r.json()["uid"]
    code = owner_sql("SELECT code FROM net.station WHERE uid = $1", uuid.UUID(station))
    with open(out, "w") as f:
        json.dump({"cookies": dict(browser.cookies), "station_uid": station, "station_code": code, "counter": counter,
                   "trip_uid": leg["uid"], "booking_ref": sold.json()["booking_ref"],
                   "departures_screen": screens["DEPARTURES"], "arrivals_screen": screens["ARRIVALS"]}, f, indent=1)
    print(f"station {code} counter {counter} trip {trip['trip_no']} sold {sold.json()['booking_ref']}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "station-ui.json")

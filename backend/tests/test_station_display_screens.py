"""Separate Departures and Arrivals screens at a station (owner's decision, October 2026; migration 1120).

The platform decides which kinds of screen a station may show (departures, arrivals, both on one board); the station's
administration registers its screens, gives each a kind and a place, and distributes them; each screen opens its own
board by its link, headed with its kind, and reports when it was last seen.
"""
import pytest

from test_boarding_stations import ADMIN, set_setting, station_session, stations_module
from test_e2e import OWNER_URL, client, login, owner_sql
from test_station_sales import _company
from test_use_case_gaps import fresh_trip

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

ALL = ["DEPARTURES", "ARRIVALS", "COMBINED"]


@pytest.fixture(scope="module")
def admin():
    return login(*ADMIN)


def _leaves_soon(trip_id: int) -> None:
    """The whole trip moves to leave in twenty minutes; its stops keep their order, so it arrives within six hours."""
    owner_sql("""UPDATE ops.trip_stop ts SET sched_arr = ts.sched_arr + d.shift, sched_dep = ts.sched_dep + d.shift
                   FROM (SELECT now() + interval '20 minutes' - sched_dep AS shift FROM ops.trip_stop
                          WHERE trip_id = $1 AND seq = 0) d
                  WHERE ts.trip_id = $1""", trip_id)


def _stop_station(trip_id: int, last: bool) -> str:
    return str(owner_sql(f"""SELECT s.uid FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                              WHERE ts.trip_id = $1 ORDER BY ts.seq {'DESC' if last else 'ASC'} LIMIT 1""", trip_id))


def test_the_station_administration_puts_departures_and_arrivals_on_separate_screens(admin):
    trip = fresh_trip()
    _leaves_soon(trip["id"])
    origin, destination = _stop_station(trip["id"], False), _stop_station(trip["id"], True)
    manager = _company(admin, "Screens Station Administration")
    stranger = _company(admin, "Screens Other Company")
    anyone = client()
    stations_module(admin, True)
    try:
        set_setting(admin, "boarding.stations.enabled", True)
        # the platform shows separate departures and arrivals screens at the station, not the board with both
        r = admin.put(f"/api/admin/boarding/stations/{origin}", json={
            "enabled": True, "displays": True, "manager_company_uid": manager["uid"], "display_kinds": ["ARRIVALS", "DEPARTURES"]})
        assert r.status_code == 200 and r.json()["boarding"]["display_kinds"] == ["DEPARTURES", "ARRIVALS"], r.text
        r = anyone.get(f"/api/public/stations/{origin}/board")
        assert r.status_code == 404 and r.json()["error"]["code"] == "BOARD_OFF"
        assert admin.put(f"/api/admin/boarding/stations/{origin}", json={
            "enabled": True, "displays": True, "display_kinds": []}).status_code == 422          # at least one kind
        # the administration sees what the platform allows and registers its screens
        staff = station_session(manager)
        view = staff.get("/api/station/screens", params={"station_uid": origin})
        assert view.status_code == 200, view.text
        assert view.json()["kinds"] == ["DEPARTURES", "ARRIVALS"] and view.json()["screens"] == []
        assert view.json()["displays"] is True and view.json()["boards_on"] is True
        r = staff.post("/api/station/screens", json={"station_uid": origin, "kind": "COMBINED", "label": "Main hall"})
        assert r.status_code == 422 and r.json()["error"]["code"] == "SCREEN_KIND_NOT_ALLOWED", r.text
        dep = staff.post("/api/station/screens", json={"station_uid": origin, "kind": "DEPARTURES", "label": " Hall A "})
        assert dep.status_code == 201 and dep.json()["label"] == "Hall A" and dep.json()["link"] == f"/screen/{dep.json()['uid']}", dep.text
        arr = staff.post("/api/station/screens", json={"station_uid": origin, "kind": "ARRIVALS", "label": "Arrivals hall"})
        assert arr.status_code == 201, arr.text
        dep, arr = dep.json()["uid"], arr.json()["uid"]
        r = staff.post("/api/station/screens", json={"station_uid": origin, "kind": "ARRIVALS", "label": "hall a"})
        assert r.status_code == 409 and r.json()["error"]["code"] == "SCREEN_LABEL_TAKEN"
        assert staff.post("/api/station/screens", json={"station_uid": origin, "kind": "ARRIVALS", "label": "x" * 61}).status_code == 422
        # each screen shows its own kind, headed by it, with its place; nobody signs in on the display
        board = anyone.get(f"/api/public/screens/{dep}")
        assert board.status_code == 200, board.text
        board = board.json()
        assert board["kind"] == "DEPARTURES" and board["screen"] == {"uid": dep, "kind": "DEPARTURES", "label": "Hall A"}
        assert board["arrivals"] == [] and any(d["trip_no"] == trip["trip_no"] for d in board["departures"])
        assert board["languages"] == ["ar", "en"] and not any(k in str(board) for k in ("passenger", "booking_ref", "seat_no"))
        board = anyone.get(f"/api/public/screens/{arr}").json()
        assert board["kind"] == "ARRIVALS" and board["departures"] == []
        # the administration sees which screens are up
        screens = {s["uid"]: s for s in staff.get("/api/station/screens", params={"station_uid": origin}).json()["screens"]}
        assert screens[dep]["online"] and screens[dep]["last_seen_at"] and screens[arr]["online"]
        assert [s["kind"] for s in screens.values()] == ["DEPARTURES", "ARRIVALS"]
        # another company is not this station's administration
        other = station_session(stranger)
        r = other.get("/api/station/screens", params={"station_uid": origin})
        assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_STATION_ADMIN"
        r = other.patch(f"/api/station/screens/{dep}", json={"active": False})
        assert r.status_code == 404 and r.json()["error"]["code"] == "SCREEN_UNKNOWN"
        assert other.delete(f"/api/station/screens/{dep}").status_code == 404
        # the platform stops the arrivals screens: the screen goes dark and the administration sees why
        assert admin.put(f"/api/admin/boarding/stations/{origin}", json={
            "enabled": True, "displays": True, "manager_company_uid": manager["uid"], "display_kinds": ["DEPARTURES"]}).status_code == 200
        r = anyone.get(f"/api/public/screens/{arr}")
        assert r.status_code == 404 and r.json()["error"]["code"] == "SCREEN_OFF"
        screens = {s["uid"]: s for s in staff.get("/api/station/screens", params={"station_uid": origin}).json()["screens"]}
        assert screens[arr]["allowed"] is False and screens[dep]["allowed"] is True
        r = staff.patch(f"/api/station/screens/{dep}", json={"kind": "ARRIVALS"})
        assert r.status_code == 422 and r.json()["error"]["code"] == "SCREEN_KIND_NOT_ALLOWED"
        # the administration moves a screen, stops it and starts it again, and takes one down
        assert staff.patch(f"/api/station/screens/{arr}", json={"kind": "DEPARTURES", "label": "Gate 2"}).status_code == 200
        assert anyone.get(f"/api/public/screens/{arr}").json()["screen"] == {"uid": arr, "kind": "DEPARTURES", "label": "Gate 2"}
        assert staff.patch(f"/api/station/screens/{dep}", json={"label": "Gate 2"}).json()["error"]["code"] == "SCREEN_LABEL_TAKEN"
        assert staff.patch(f"/api/station/screens/{dep}", json={"active": False}).status_code == 200
        assert anyone.get(f"/api/public/screens/{dep}").status_code == 404
        assert staff.patch(f"/api/station/screens/{dep}", json={"active": True}).status_code == 200
        assert anyone.get(f"/api/public/screens/{dep}").status_code == 200
        assert staff.delete(f"/api/station/screens/{arr}").json() == {"uid": arr, "removed": True}
        assert anyone.get(f"/api/public/screens/{arr}").status_code == 404
        # the platform sees the screens, and registers them itself where a station has no administration
        listed = next(s for s in admin.get("/api/admin/boarding/stations").json()["stations"] if s["uid"] == origin)
        assert listed["display_kinds"] == ["DEPARTURES"] and listed["screens"] == 1
        assert [s["uid"] for s in admin.get(f"/api/admin/boarding/stations/{origin}").json()["screens"]] == [dep]
        assert admin.put(f"/api/admin/boarding/stations/{destination}", json={"enabled": True, "displays": True}).status_code == 200
        far = admin.post(f"/api/admin/boarding/stations/{destination}/screens", json={"kind": "ARRIVALS", "label": "Exit"})
        assert far.status_code == 201, far.text
        board = anyone.get(f"/api/public/screens/{far.json()['uid']}").json()
        assert board["departures"] == [] and any(a["trip_no"] == trip["trip_no"] for a in board["arrivals"]), board
        r = admin.patch(f"/api/admin/boarding/stations/{origin}/screens/{far.json()['uid']}", json={"active": False})
        assert r.status_code == 404                                       # the screen is not that station's
        assert admin.delete(f"/api/admin/boarding/stations/{destination}/screens/{far.json()['uid']}").status_code == 200
        assert owner_sql("SELECT count(*) FROM audit.activity_log WHERE action LIKE 'boarding.screen_%'") >= 6
    finally:
        owner_sql("""DELETE FROM net.station_screen WHERE station_id IN (SELECT id FROM net.station WHERE uid IN ($1::uuid, $2::uuid))""",
                  origin, destination)
        for st in (origin, destination):
            admin.put(f"/api/admin/boarding/stations/{st}", json={"enabled": False, "displays": False, "display_kinds": ALL})
        set_setting(admin, "boarding.stations.enabled", False)
        stations_module(admin, False)
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


def test_only_the_station_portal_and_the_platform_manage_screens(admin):
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.get("/api/station/screens", params={"station_uid": "00000000-0000-0000-0000-000000000000"}).status_code in (401, 403)
    assert pax.get("/api/admin/boarding/stations/00000000-0000-0000-0000-000000000000/screens").status_code in (401, 403)
    r = client().get("/api/public/screens/00000000-0000-0000-0000-000000000000")
    assert r.status_code == 404 and r.json()["error"]["code"] == "SCREEN_OFF"

"""The screens of build step 4 (migration 1112): the station's public departure board appears only once the platform
switches on its boarding stations and the station's screens; it lists the departures with their bay and state and
carries no passenger data. The platform lists the stations and the operating companies; the carrier sees whom it can
give rights to, and what the operating companies did on its trips in a day."""
import pytest

from test_boarding_stations import ADMIN, CARRIER, set_setting
from test_e2e import OWNER_URL, client, login, owner_sql
from test_station_sales import _company
from test_use_case_gaps import fresh_trip


@pytest.fixture(scope="module")
def admin():
    return login(*ADMIN)


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_the_departure_board_shows_only_where_the_platform_switched_the_screens_on(admin):
    trip = fresh_trip()
    station = owner_sql("""SELECT s.uid FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                            WHERE ts.trip_id = $1 AND ts.seq = 0""", trip["id"])
    owner_sql("UPDATE ops.trip_stop SET sched_dep = now() + interval '90 minutes' WHERE trip_id = $1 AND seq = 0", trip["id"])
    anyone = client()
    try:
        r = anyone.get(f"/api/public/stations/{station}/board")
        assert r.status_code == 404 and r.json()["error"]["code"] == "BOARD_OFF", r.text
        assert admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": False, "displays": True}).status_code == 200
        assert anyone.get(f"/api/public/stations/{station}/board").status_code == 404      # the platform switch is still off
        set_setting(admin, "boarding.stations.enabled", True)
        set_setting(admin, "boarding.checkin.opens_minutes", 120)
        r = anyone.get(f"/api/public/stations/{station}/board")
        assert r.status_code == 200, r.text
        board = r.json()
        assert board["station"]["time_zone"] and "departures" in board and "arrivals" in board
        row = next(d for d in board["departures"] if d["trip_no"] == trip["trip_no"])
        assert row["status"] == "CHECK_IN" and row["city"] and set(row) == {"trip_no", "carrier", "at", "city", "city_code", "via", "via_codes", "bay", "status"}
        assert len(row["via_codes"]) == len(row["via"])          # the stops on the way, named on screen from their codes (1113)
        assert not any(k in r.text for k in ("passenger", "ticket_no", "booking_ref", "seat_no", "mobile"))
        listed = next(s for s in admin.get("/api/admin/boarding/stations").json()["stations"] if s["uid"] == str(station))
        assert listed["displays"] and not listed["enabled"]
    finally:
        set_setting(admin, "boarding.checkin.opens_minutes", None)
        set_setting(admin, "boarding.stations.enabled", False)
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": False, "displays": False})
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_the_platform_and_the_carrier_see_the_operating_companies_and_their_work(admin):
    company = _company(admin, "Screens Station Services")
    companies = admin.get("/api/admin/boarding/operating-companies").json()["companies"]
    assert any(c["uid"] == company["uid"] and c["counters"] == 0 for c in companies)
    carrier = login(*CARRIER)
    options = carrier.get("/api/carrier/station-operators/options").json()
    assert options["stations"] and any(c["uid"] == company["uid"] for c in options["companies"])
    activity = carrier.get("/api/carrier/station-operators/activity")
    assert activity.status_code == 200 and {"day", "checkins", "sales"} <= set(activity.json())
    # the station screens are the platform's and the carrier's: other portals are refused
    assert carrier.get("/api/admin/boarding/stations").status_code in (401, 403)
    assert admin.get("/api/carrier/station-operators/activity").status_code in (401, 403)
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.get("/api/carrier/station-operators/options").status_code in (401, 403)

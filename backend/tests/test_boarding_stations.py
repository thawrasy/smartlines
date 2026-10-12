"""Boarding stations (owner's decisions, October 2026; migration 1097): off at launch. The platform sets the switches and the
check-in window, numbers the counters and bays of each station, and a carrier keeps its own reference numbers. Nothing here
changes a booking or a boarding until the platform switches a station on."""
import uuid

import pytest

from test_e2e import login, owner_sql

ADMIN = ("admin@masslak.test", "PLATFORM")
CARRIER = ("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def admin():
    return login(*ADMIN)


@pytest.fixture(scope="module")
def station(admin):
    r = admin.post("/api/admin/stations", json={"city_code": "DAM", "number": 961, "name": "Boarding test station",
                                                "lat": 33.5, "lng": 36.3})
    assert r.status_code == 201, r.text
    return owner_sql("SELECT uid FROM net.station WHERE code = $1", r.json()["code"], fetch=True)["uid"]


def set_setting(admin, key, value):
    r = admin.put("/api/admin/boarding/settings", json={"key": key, "value": value})
    assert r.status_code == 200, r.text
    return r.json()


def test_the_boarding_stations_are_off_at_launch(admin):
    settings = admin.get("/api/admin/boarding/settings").json()["settings"]
    assert settings["boarding.stations.enabled"] is False
    assert settings["boarding.mode.state_mandated"] is False and settings["boarding.mode.carrier_contracted"] is False
    assert settings["boarding.checkin.opens_minutes"] is None and settings["boarding.checkin.closes_minutes"] is None
    assert settings["boarding.references.required"] == []


def test_only_the_platform_changes_the_boarding_settings():
    carrier = login(*CARRIER)
    assert carrier.get("/api/admin/boarding/settings").status_code == 403
    assert carrier.put("/api/admin/boarding/settings",
                       json={"key": "boarding.stations.enabled", "value": True}).status_code == 403


@pytest.mark.parametrize("key, value", [
    ("boarding.stations.enabled", "yes"),
    ("boarding.checkin.opens_minutes", 2000),
    ("boarding.references.required", ["AGREEMENT", 7]),
])
def test_an_invalid_boarding_setting_is_refused(admin, key, value):
    r = admin.put("/api/admin/boarding/settings", json={"key": key, "value": value})
    assert r.status_code == 422 and r.json()["error"]["code"] == "INVALID_SETTING", r.text


def test_a_setting_outside_the_boarding_keys_is_refused(admin):
    assert admin.put("/api/admin/boarding/settings", json={"key": "boarding.other", "value": True}).status_code == 422


def test_a_station_boards_only_when_the_platform_and_the_station_are_both_on(admin, station):
    url = f"/api/admin/boarding/stations/{station}"
    try:
        assert admin.put(url, json={"enabled": True, "displays": True}).status_code == 200
        assert admin.get(url).json()["boarding_on_now"] is False          # the platform switch is still off
        set_setting(admin, "boarding.stations.enabled", True)
        view = admin.get(url).json()
        assert view["boarding"]["enabled"] is True and view["boarding"]["displays"] is True
        assert view["boarding_on_now"] is True
    finally:
        set_setting(admin, "boarding.stations.enabled", False)
        admin.put(url, json={"enabled": False})
    assert admin.get(url).json()["boarding_on_now"] is False


def test_the_check_in_window_of_a_station_opens_before_it_closes(admin, station):
    r = admin.put(f"/api/admin/boarding/stations/{station}",
                  json={"enabled": False, "checkin_opens_minutes": 30, "checkin_closes_minutes": 60})
    assert r.status_code == 422 and r.json()["error"]["code"] == "INVALID_SETTING", r.text


def test_the_platform_numbers_the_counters_and_bays_of_each_station(admin, station):
    operator = owner_sql("SELECT p.uid FROM iam.company c JOIN iam.party p ON p.id = c.id ORDER BY c.id LIMIT 1",
                         fetch=True)["uid"]
    base = f"/api/admin/boarding/stations/{station}/gates"
    first = admin.post(base, json={"gate_type": "COUNTER", "operator_company_uid": str(operator)})
    second = admin.post(base, json={"gate_type": "COUNTER", "operator_company_uid": str(operator)})
    bay = admin.post(base, json={"gate_type": "BAY"})
    assert first.status_code == 201 and first.json()["code"] == "C001", first.text
    assert second.json()["code"] == "C002"
    assert bay.json()["code"] == "B001"
    no_company = admin.post(base, json={"gate_type": "COUNTER"})
    assert no_company.status_code == 422 and no_company.json()["error"]["code"] == "INVALID_GATE"
    bay_with_company = admin.post(base, json={"gate_type": "BAY", "operator_company_uid": str(operator)})
    assert bay_with_company.status_code == 422 and bay_with_company.json()["error"]["code"] == "INVALID_GATE"
    codes = [g["code"] for g in admin.get(f"/api/admin/boarding/stations/{station}").json()["gates"]]
    assert codes == ["B001", "C001", "C002"]


def test_an_unknown_station_is_not_found(admin):
    assert admin.get(f"/api/admin/boarding/stations/{uuid.uuid4()}").status_code == 404


def test_a_carrier_records_retires_and_is_told_which_references_are_missing(admin):
    carrier = login(*CARRIER)
    assert admin.post("/api/carrier/references", json={"kind": "AGREEMENT", "reference_no": "X-1"}).status_code == 403
    set_setting(admin, "boarding.references.required", ["AGREEMENT"])
    try:
        number = f"AGR-{uuid.uuid4().hex[:8]}"
        assert "AGREEMENT" in carrier.get("/api/carrier/references").json()["missing"]
        r = carrier.post("/api/carrier/references", json={"kind": "AGREEMENT", "reference_no": number,
                                                          "issued_by": "Ministry of Transport", "issued_on": "2026-01-01"})
        assert r.status_code == 201, r.text
        uid = r.json()["uid"]
        listed = carrier.get("/api/carrier/references").json()
        assert [x["reference_no"] for x in listed["references"] if x["status"] == "ACTIVE"].count(number) == 1
        assert "AGREEMENT" not in listed["missing"]
        duplicate = carrier.post("/api/carrier/references", json={"kind": "AGREEMENT", "reference_no": number})
        assert duplicate.status_code == 409 and duplicate.json()["error"]["code"] == "REFERENCE_EXISTS"
        licence_without_type = carrier.post("/api/carrier/references", json={"kind": "LICENCE", "reference_no": "L-1"})
        assert licence_without_type.status_code == 422 and licence_without_type.json()["error"]["code"] == "INVALID_REFERENCE"
        retired = carrier.post(f"/api/carrier/references/{uid}/retire")
        assert retired.status_code == 200 and retired.json()["status"] == "RETIRED"
        again = carrier.post(f"/api/carrier/references/{uid}/retire")
        assert again.status_code == 409 and again.json()["error"]["code"] == "REFERENCE_RETIRED"
        assert carrier.post(f"/api/carrier/references/{uuid.uuid4()}/retire").status_code == 404
        assert "AGREEMENT" in carrier.get("/api/carrier/references").json()["missing"]
    finally:
        set_setting(admin, "boarding.references.required", [])

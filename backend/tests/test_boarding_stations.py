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


def stations_module(admin, enabled: bool) -> None:
    """The stations feature (tracking_stations) closes the station tables while it is off (phase 7)."""
    r = admin.put("/api/admin/modules/tracking_stations", json={"enabled": enabled, "reason": "automated test of boarding stations (1097)"})
    assert r.status_code == 200, r.text


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


def operator_company(carrier_uid: str) -> uuid.UUID:
    """An operating company other than the carrier."""
    return owner_sql("SELECT p.uid FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid <> $1 ORDER BY c.id LIMIT 1",
                     uuid.UUID(carrier_uid), fetch=True)["uid"]


def may(operator: uuid.UUID, carrier: uuid.UUID, station: uuid.UUID, permission: str) -> bool:
    return owner_sql("""SELECT net.operator_may(
            (SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1),
            (SELECT id FROM iam.party WHERE uid = $2),
            (SELECT id FROM net.station WHERE uid = $3), $4)""", operator, carrier, station, permission)


def test_a_carrier_gives_its_operating_company_a_right_at_a_station_and_takes_it_back(admin, station):
    carrier = login(*CARRIER)
    carrier_uid = carrier.get("/api/auth/me").json()["company"]["uid"]
    operator = operator_company(carrier_uid)
    url = "/api/carrier/station-operators/grants"
    body = {"operator_company_uid": str(operator), "station_uid": str(station), "permission": "BOARDING"}
    stations_module(admin, True)
    try:
        self_grant = carrier.post(url, json={**body, "operator_company_uid": carrier_uid})
        assert self_grant.status_code == 422 and self_grant.json()["error"]["code"] == "INVALID_GRANT", self_grant.text
        r = carrier.post(url, json=body)
        assert r.status_code == 201, r.text
        uid = r.json()["uid"]
        listed = [g for g in carrier.get(url).json()["grants"] if g["uid"] == uid]
        assert len(listed) == 1 and listed[0]["revoked_at"] is None and listed[0]["permission"] == "BOARDING"
        duplicate = carrier.post(url, json=body)
        assert duplicate.status_code == 409 and duplicate.json()["error"]["code"] == "GRANT_EXISTS", duplicate.text
        set_setting(admin, "boarding.stations.enabled", True)
        set_setting(admin, "boarding.mode.carrier_contracted", True)
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": True})
        assert may(operator, uuid.UUID(carrier_uid), station, "BOARDING") is True
        assert may(operator, uuid.UUID(carrier_uid), station, "BOOKING") is False
        revoked = carrier.post(f"{url}/{uid}/revoke")
        assert revoked.status_code == 200 and revoked.json()["status"] == "REVOKED"
        assert carrier.post(f"{url}/{uid}/revoke").json()["error"]["code"] == "GRANT_REVOKED"
        assert may(operator, uuid.UUID(carrier_uid), station, "BOARDING") is False
    finally:
        set_setting(admin, "boarding.mode.carrier_contracted", False)
        set_setting(admin, "boarding.stations.enabled", False)
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": False})
        stations_module(admin, False)


def test_the_platform_grants_a_state_mandated_operator_and_only_while_that_mode_is_on(admin, station):
    carrier_uid = login(*CARRIER).get("/api/auth/me").json()["company"]["uid"]
    operator = operator_company(carrier_uid)
    url = "/api/admin/boarding/operator-grants"
    stations_module(admin, True)
    try:
        set_setting(admin, "boarding.stations.enabled", True)
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": True})
        r = admin.post(url, json={"operator_company_uid": str(operator), "station_uid": str(station), "permission": "BOARDING_PASS"})
        assert r.status_code == 201, r.text
        uid = r.json()["uid"]
        listed = [g for g in admin.get(url).json()["grants"] if g["uid"] == uid]
        assert len(listed) == 1 and listed[0]["carrier_uid"] is None
        assert may(operator, uuid.UUID(carrier_uid), station, "BOARDING_PASS") is False          # the mode is off at launch
        set_setting(admin, "boarding.mode.state_mandated", True)
        assert may(operator, uuid.UUID(carrier_uid), station, "BOARDING_PASS") is True
        assert admin.post(f"{url}/{uid}/revoke").status_code == 200
        assert may(operator, uuid.UUID(carrier_uid), station, "BOARDING_PASS") is False
    finally:
        set_setting(admin, "boarding.mode.state_mandated", False)
        set_setting(admin, "boarding.stations.enabled", False)
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": False})
        stations_module(admin, False)


# ------------------------------------------------------------------ the station portal (1099)
def station_session(company: dict):
    """Sign in to the STATION portal with the second factor the owner's account requires: enrolled at the first sign-in,
    verified with a later code at the next ones (a code is used once)."""
    from app import mfa
    from test_e2e import client
    c = client()
    r = c.post("/api/auth/login", json={"identifier": company["email"], "password": company["password"], "portal": "STATION"})
    assert r.status_code == 200, r.text
    if "secret" not in company:
        start = c.post("/api/auth/mfa/enroll")
        assert start.status_code == 200, start.text
        company["secret"], company["step"] = start.json()["secret"], mfa.current_step()
        done = c.post("/api/auth/mfa/confirm", json={"code": mfa.code_at(company["secret"], company["step"])})
    else:
        company["step"] = max(mfa.current_step(), company["step"] + 1)
        done = c.post("/api/auth/mfa/verify", json={"code": mfa.code_at(company["secret"], company["step"])})
    assert done.status_code == 200, done.text
    return c


def sign_in(email: str, password: str, portal: str):
    from test_e2e import client
    return client().post("/api/auth/login", json={"identifier": email, "password": password, "portal": portal})


@pytest.fixture(scope="module")
def operating_company(admin):
    email = f"station-{uuid.uuid4().hex[:8]}@example.com"
    password = f"Harbor-{uuid.uuid4().hex[:10]}-26!q"
    r = admin.post("/api/admin/boarding/operating-companies", json={
        "legal_name": "Damascus Station Services", "owner_name": "Station Owner", "owner_email": email, "owner_password": password})
    assert r.status_code == 201, r.text
    return {"uid": r.json()["uid"], "email": email, "password": password}


def test_onboarding_an_operating_company_is_a_platform_task(admin):
    carrier = login(*CARRIER)
    body = {"legal_name": "Some Operator", "owner_name": "Some Owner", "owner_email": f"x-{uuid.uuid4().hex[:6]}@example.com",
            "owner_password": f"Harbor-{uuid.uuid4().hex[:10]}-26!q"}
    assert carrier.post("/api/admin/boarding/operating-companies", json=body).status_code == 403
    weak = admin.post("/api/admin/boarding/operating-companies", json={**body, "owner_password": "short"})
    assert weak.status_code == 422, weak.text


def test_an_operating_company_signs_in_to_the_station_portal_and_nowhere_else(operating_company):
    c = station_session(operating_company)
    me = c.get("/api/auth/me").json()
    assert me["portal"] == "STATION" and me["company"]["uid"] == operating_company["uid"]
    assert "station.counter" in me["permissions"]
    assert "trip.publish" not in me["permissions"] and "boarding.operators" not in me["permissions"]   # never a carrier's
    for portal in ("OPERATOR", "DRIVER"):
        r = sign_in(operating_company["email"], operating_company["password"], portal)
        assert r.status_code == 403 and r.json()["error"]["code"] == "COMPANY_NOT_ACTIVE", (portal, r.text)
    assert c.get("/api/carrier/references").status_code == 403
    assert c.get("/api/admin/boarding/settings").status_code == 403


def test_a_carrier_does_not_open_the_station_portal():
    r = sign_in("owner@carrier.test", "Masslak-Demo-2026", "STATION")
    assert r.status_code == 403 and r.json()["error"]["code"] == "COMPANY_NOT_ACTIVE", r.text


def test_the_operating_company_sees_the_rights_given_to_it_and_its_counters(admin, station, operating_company):
    carrier = login(*CARRIER)
    c = station_session(operating_company)
    url = "/api/carrier/station-operators/grants"
    stations_module(admin, True)
    try:
        set_setting(admin, "boarding.stations.enabled", True)
        set_setting(admin, "boarding.mode.carrier_contracted", True)
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": True})
        r = carrier.post(url, json={"operator_company_uid": operating_company["uid"], "station_uid": str(station), "permission": "BOARDING"})
        assert r.status_code == 201, r.text
        grant = r.json()["uid"]
        counter = admin.post(f"/api/admin/boarding/stations/{station}/gates",
                             json={"gate_type": "COUNTER", "operator_company_uid": operating_company["uid"]})
        assert counter.status_code == 201, counter.text
        view = c.get("/api/station/overview").json()
        mine = [g for g in view["grants"] if g["uid"] == grant]
        assert len(mine) == 1 and mine[0]["permission"] == "BOARDING" and mine[0]["usable_now"] is True
        assert [x["code"] for x in view["counters"]] == [counter.json()["code"]]
        assert view["counters"][0]["boarding_on_now"] is True
        assert carrier.post(f"{url}/{grant}/revoke").status_code == 200
        assert [g for g in c.get("/api/station/overview").json()["grants"] if g["uid"] == grant] == []
    finally:
        set_setting(admin, "boarding.mode.carrier_contracted", False)
        set_setting(admin, "boarding.stations.enabled", False)
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": False})
        stations_module(admin, False)

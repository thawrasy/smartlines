"""Routes of the network (owner's requests N11, N37, N38; migration 1163): the platform defines them along the roads, in
versions approved by a second person; carriers define their services only on them, serving every mandatory station;
a carrier asks for a route the network lacks."""
import random
from datetime import date, timedelta

import pytest

from network_helper import network_route
from test_e2e import OWNER_URL, login
from test_roads_guide import _load, roads_workbook

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _central(admin, city: str) -> str:
    return next(s for s in admin.get("/api/stations", params={"city": city}).json()["stations"] if s["station_class"] == "CENTRAL")["uid"]


@pytest.fixture(scope="module")
def people():
    return login("admin@masslak.test", "PLATFORM"), login("geo@masslak.test", "PLATFORM"), login("owner@carrier.test", "OPERATOR")


def test_the_platform_defines_a_route_and_carriers_serve_it(people):
    admin, geo, carrier = people
    a, b, c = _central(admin, "DAM"), _central(admin, "HMS"), _central(admin, "ALP")
    body = {"name_en": "Damascus Aleppo by Homs", "name_ar": "Damascus Aleppo ar",
            "version": {"distance_km": 350, "stops": [{"station_uid": a}, {"station_uid": b, "km": 160, "mandatory": True}, {"station_uid": c, "km": 350}]}}
    bad = {**body, "version": {**body["version"], "stops": [{"station_uid": a}, {"station_uid": b, "km": 400}, {"station_uid": c, "km": 350}]}}
    assert admin.post("/api/admin/network/routes", json=bad).json()["error"]["code"] in ("STOP_BEYOND", "STOP_ORDER")
    r = admin.post("/api/admin/network/routes", json=body)
    assert r.status_code == 201, r.text
    route, version, code = r.json()["uid"], r.json()["version_uid"], r.json()["code"]
    assert code.startswith("DAM-ALP-")
    assert carrier.post("/api/admin/network/routes", json=body).status_code == 403
    assert admin.post(f"/api/admin/network/versions/{version}/decide", json={"approve": True}).json()["error"]["code"] == "FOUR_EYES"
    assert geo.post(f"/api/admin/network/versions/{version}/decide", json={"approve": True}).json()["status"] == "ACTIVE"
    listed = {x["uid"]: x for x in carrier.get("/api/network/routes").json()["routes"]}
    assert [s["station_uid"] for s in listed[route]["stops"]] == [a, b, c] and listed[route]["stops"][1]["mandatory"] is True

    stop = lambda uid, m, fare: {"station_uid": uid, "arr_offset_min": m, "dep_offset_min": m, "fare_from_origin": fare}
    assert carrier.post("/api/carrier/routes", json={"code": "FREE-1", "stops": [stop(a, 0, 0), stop(c, 300, 900000)]}
                        ).json()["error"]["code"] == "ROUTE_FROM_NETWORK"
    on = lambda stops: carrier.post("/api/carrier/routes", json={"network_route_uid": route, "stops": stops})
    assert on([stop(a, 0, 0), stop(c, 300, 900000)]).json()["error"]["code"] == "MANDATORY_STOP"
    assert on([stop(c, 0, 0), stop(b, 120, 400000)]).json()["error"]["code"] == "STATION_ORDER"
    assert on([stop(a, 0, 0), stop(_central(admin, "LTK"), 200, 400000)]).json()["error"]["code"] == "STATION_NOT_ON_ROUTE"
    r = on([stop(a, 0, 0), stop(b, 120, 400000), stop(c, 300, 900000)])
    assert r.status_code == 201, r.text
    mine = next(x for x in carrier.get("/api/carrier/routes").json()["routes"] if x["uid"] == r.json()["uid"])
    assert r.json()["code"].endswith(tuple(f"-DAM-ALP-{n}" for n in range(1, 100))) and mine["service_type"] == "INDIRECT"
    part = on([stop(b, 0, 0), stop(c, 180, 500000)])
    assert part.status_code == 201, part.text

    # a new version waits for its date; one waits at a time; who proposed withdraws
    later = (date.today() + timedelta(days=5)).isoformat()
    v2 = admin.post(f"/api/admin/network/routes/{route}/versions", json={**body["version"], "effective_from": later, "note": "new stop times"})
    assert v2.status_code == 201, v2.text
    assert admin.post(f"/api/admin/network/routes/{route}/versions", json=body["version"]).json()["error"]["code"] == "ROUTE_VERSION_WAITING"
    assert geo.post(f"/api/admin/network/versions/{v2.json()['version_uid']}/decide", json={"approve": True}).json()["status"] == "APPROVED"
    shown = carrier.get(f"/api/network/routes/{route}").json()
    assert shown["shown"]["version"] == 1 and [v["status"] for v in shown["versions"]] == ["APPROVED", "ACTIVE"]
    assert admin.post(f"/api/admin/network/versions/{v2.json()['version_uid']}/withdraw").json()["status"] == "WITHDRAWN"
    other_end = {**body["version"], "stops": [{"station_uid": a}, {"station_uid": b, "km": 160}]}
    assert admin.post(f"/api/admin/network/routes/{route}/versions", json=other_end).json()["error"]["code"] == "ROUTE_ENDS"
    v3 = admin.post(f"/api/admin/network/routes/{route}/versions", json=body["version"]).json()["version_uid"]
    assert geo.post(f"/api/admin/network/versions/{v3}/decide", json={"approve": False}).json()["error"]["code"] == "ROUTE_NOTE"
    assert geo.post(f"/api/admin/network/versions/{v3}/decide", json={"approve": False, "note": "same as before"}).json()["status"] == "REJECTED"


def test_a_route_follows_road_segments_and_takes_its_distances_from_them(people):
    admin, geo, _ = people
    road = f"S{random.randint(900, 998)}"
    loaded = _load(admin, roads_workbook({road: [("C1001", "SY010000", 33.517175, 36.27671, 0), ("C1007", "SY020000", 36.2021, 37.1343, 350)]},
                                         f"net{random.random()}"))
    assert loaded.status_code == 200, loaded.text
    made = []
    for city, place in (("DAM", "C1001"), ("ALP", "C1007")):
        for _ in range(5):
            r = admin.post("/api/admin/stations", json={"city_code": city, "place": place, "number": random.randint(700, 999), "name": f"Road station {city}"})
            if r.status_code == 201:
                break
        assert r.status_code == 201, r.text
        made.append(next(s for s in admin.get("/api/stations", params={"city": city}).json()["stations"] if s["code"] == r.json()["code"])["uid"])
    gap = {"stops": [{"station_uid": made[0]}, {"station_uid": made[1]}],
           "segments": [{"road": road, "from_seq": 1, "to_seq": 2}, {"road": road, "from_seq": 1, "to_seq": 2}]}
    assert admin.post("/api/admin/network/routes", json={"name_en": "Gap", "name_ar": "Gap ar", "version": gap}).json()["error"]["code"] == "ROUTE_GAP"
    r = admin.post("/api/admin/network/routes", json={"name_en": "Along the road", "name_ar": "Along ar", "version": {
        "stops": [{"station_uid": made[0]}, {"station_uid": made[1]}], "segments": [{"road": road, "from_seq": 1, "to_seq": 2}]}})
    assert r.status_code == 201, r.text
    assert geo.post(f"/api/admin/network/versions/{r.json()['version_uid']}/decide", json={"approve": True}).json()["status"] == "ACTIVE"
    shown = admin.get(f"/api/network/routes/{r.json()['uid']}").json()["shown"]
    assert float(shown["distance_km"]) == 350 and [float(s["km_from_start"]) for s in shown["stops"]] == [0, 350]
    assert shown["segments"][0]["road"] == road and {g["pcode"] for g in shown["governorates"]} == {"SY01", "SY02"}


def test_carriers_ask_for_a_route_the_network_lacks(people):
    admin, _, carrier = people
    a, b = _central(admin, "DAM"), _central(admin, "DRA")
    r = carrier.post("/api/carrier/route-requests", json={"from_station_uid": a, "to_station_uid": b, "via": "M5", "note": "daily demand from Daraa"})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    waiting = {x["uid"]: x for x in admin.get("/api/admin/network/requests").json()["requests"]}
    assert waiting[uid]["status"] == "OPEN" and waiting[uid]["via"] == "M5"
    made = network_route([a, b], [0, 100], "Damascus Daraa")
    assert admin.post(f"/api/admin/network/requests/{uid}/answer", json={"status": "DONE", "answer": "route opened", "route_uid": made}
                      ).json()["status"] == "DONE"
    assert admin.post(f"/api/admin/network/requests/{uid}/answer", json={"status": "DECLINED", "answer": "again"}).json()["error"]["code"] == "REQUEST_CLOSED"
    mine = {x["uid"]: x for x in carrier.get("/api/carrier/route-requests").json()["requests"]}
    assert mine[uid]["status"] == "DONE" and mine[uid]["route_code"].startswith("DAM-DRA-")

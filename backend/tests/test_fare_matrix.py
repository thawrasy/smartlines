"""A price for every station pair of a route (owner's request N10, migration 1164): the carrier prices the matrix, the
fare ladder follows its first row and each trip made from the route takes it; the platform keeps carrier classes and
the state's price bands, applied only while their switch is on."""
import secrets

import pytest

from network_helper import network_route
from test_e2e import OWNER_URL, day, login, owner_sql
from test_trip_changes import vehicle

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _central(admin, city: str) -> str:
    return next(s for s in admin.get("/api/stations", params={"city": city}).json()["stations"] if s["station_class"] == "CENTRAL")["uid"]


@pytest.fixture(scope="module")
def people():
    return login("admin@masslak.test", "PLATFORM"), login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def route(people):
    admin, carrier = people
    a, b, c = _central(admin, "DAM"), _central(admin, "HMS"), _central(admin, "ALP")
    net = network_route([a, b, c], [0, 160, 350], "Fare matrix route")

    def stop(uid, m, fare):
        return {"station_uid": uid, "arr_offset_min": m, "dep_offset_min": m, "fare_from_origin": fare}

    r = carrier.post("/api/carrier/routes", json={"network_route_uid": net, "stops": [stop(a, 0, 0), stop(b, 120, 400000), stop(c, 300, 900000)]})
    assert r.status_code == 201, r.text
    return r.json()["uid"]


def _cells(prices: dict) -> list[dict]:
    return [{"from_seq": a, "to_seq": b, "price": p} for (a, b), p in prices.items()]


def test_the_carrier_prices_every_pair_and_trips_take_the_matrix(people, route):
    _, carrier = people
    shown = carrier.get(f"/api/carrier/routes/{route}/fares").json()
    assert [s["dist_from_origin_km"] for s in shown["stops"]] == [0, 160, 350]
    # before any matrix, a pair costs the difference of the ladder
    assert {(c["from_seq"], c["to_seq"]): c["price"] for c in shown["cells"]} == {(0, 1): 400000, (0, 2): 900000, (1, 2): 500000}
    assert not any(c["set"] for c in shown["cells"])
    incomplete = carrier.put(f"/api/carrier/routes/{route}/fares", json={"cells": _cells({(0, 1): 300000, (0, 2): 800000})})
    assert incomplete.status_code == 422 and incomplete.json()["error"]["code"] == "FARE_MATRIX_INCOMPLETE"
    # a middle pair dearer than the whole way is allowed and reported
    r = carrier.put(f"/api/carrier/routes/{route}/fares", json={"cells": _cells({(0, 1): 300000, (0, 2): 800000, (1, 2): 850000})})
    assert r.status_code == 200, r.text
    assert r.json() == {"pairs": 3, "dearer_inside_longer": ["1-2"]}
    shown = carrier.get(f"/api/carrier/routes/{route}/fares").json()
    assert all(c["set"] for c in shown["cells"]) and [s["fare_from_origin"] for s in shown["stops"]] == [0, 300000, 800000]

    v = vehicle(carrier, 44)
    for _ in range(10):
        t = carrier.post("/api/carrier/trips", json={"route_uid": route, "vehicle_uid": v,
                                                       "departure_local": f"{day(3)}T{6 + secrets.randbelow(12):02d}:{secrets.randbelow(60):02d}:00"})
        if t.status_code != 409:
            break
    assert t.status_code == 201, t.text
    price = owner_sql("""SELECT f.price FROM ops.trip_pair_fare f JOIN ops.trip t ON t.id = f.trip_id
                          WHERE t.uid = $1 AND f.from_seq = 1 AND f.to_seq = 2""", t.json()["uid"])
    assert price == 850000


def test_state_bands_by_carrier_class_apply_only_while_switched_on(people, route):
    admin, carrier = people
    assert carrier.get("/api/admin/carrier-classes").status_code == 403
    code = f"T{secrets.randbelow(10**6)}"
    assert admin.post("/api/admin/carrier-classes", json={"code": code, "name_en": "Test class", "name_ar": "Test class ar"}).status_code == 201
    company = owner_sql("SELECT p.uid FROM iam.party p JOIN iam.company_member m ON m.company_id = p.id JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = 'owner@carrier.test' LIMIT 1")
    r = admin.post("/api/admin/carrier-classes/assign", json={"company_uid": str(company), "class_code": code, "source_document": "Decision 12/2026"})
    assert r.status_code == 201, r.text
    bad = admin.post("/api/admin/price-bands", json={"class_code": code, "min_per_km": 5000, "max_per_km": 1000})
    assert bad.json()["error"]["code"] == "BAND_ORDER"
    # 1000 to 4000 per km for every vehicle; coaches up to 2000
    assert admin.post("/api/admin/price-bands", json={"class_code": code, "min_per_km": 1000, "max_per_km": 4000}).status_code == 201
    assert admin.post("/api/admin/price-bands", json={"class_code": code, "vehicle_type": "COACH", "max_per_km": 2000}).status_code == 201
    listed = admin.get("/api/admin/carrier-classes").json()
    assert listed["enabled"] is False and any(a["class_code"] == code and a["ended_at"] is None for a in listed["assignments"])

    # 850000 over 190 km is 4473 per km: above the band, but the switch is off
    prices = {(0, 1): 300000, (0, 2): 800000, (1, 2): 850000}
    assert carrier.put(f"/api/carrier/routes/{route}/fares", json={"cells": _cells(prices)}).status_code == 200
    try:
        assert admin.put("/api/admin/price-bands/settings", json={"enabled": True}).json() == {"enabled": True}
        shown = carrier.get(f"/api/carrier/routes/{route}/fares").json()
        assert shown["band"]["max_per_km"] == 4000 and {c["to_seq"]: c["band"] for c in shown["cells"] if c["from_seq"] == 1} == {2: "above"}
        r = carrier.put(f"/api/carrier/routes/{route}/fares", json={"cells": _cells(prices)})
        assert r.status_code == 422 and r.json()["error"]["code"] == "FARE_OUTSIDE_BAND" and r.json()["error"]["pairs"] == ["1-2"]
        inside = {(0, 1): 400000, (0, 2): 700000, (1, 2): 380000}
        assert carrier.put(f"/api/carrier/routes/{route}/fares", json={"cells": _cells(inside)}).status_code == 200
        # a coach has its own band: 400000 over 160 km is 2500 per km, above 2000
        t = carrier.post("/api/carrier/trips", json={"route_uid": route, "vehicle_uid": vehicle(carrier, 44),
                                                       "departure_local": f"{day(4)}T{6 + secrets.randbelow(12):02d}:{secrets.randbelow(60):02d}:00"})
        assert t.status_code == 422 and t.json()["error"]["code"] == "FARE_OUTSIDE_BAND", t.text
    finally:
        assert admin.put("/api/admin/price-bands/settings", json={"enabled": False}).json() == {"enabled": False}

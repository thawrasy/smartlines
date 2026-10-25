"""Cities by class and pickers from the governorate down to the station (owner's request N37, migration 1160)."""
import uuid

import pytest

from test_e2e import OWNER_URL, login
from test_geography import _VILLAGES, _upload, workbook

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def admin():
    a = login("admin@masslak.test", "PLATFORM")
    r = _upload(a, workbook([]))
    assert r.status_code == 200, r.text
    return a


def test_the_pickers_go_down_from_the_governorate_to_the_station(admin):
    c = login("passenger@masslak.test", "PASSENGER")
    top = c.get("/api/geo/cascade").json()
    assert "SY01" in {g["pcode"] for g in top["governorates"]}
    assert top["areas"] == [] and top["stations"] == []                 # nothing below a city until one is chosen
    damascus = c.get("/api/geo/cascade", params={"governorate": "SY01"}).json()
    assert "DAM" in {x["code"] for x in damascus["cities"]} and all(x["governorate"] == "SY01" for x in damascus["cities"])
    city = c.get("/api/geo/cascade", params={"governorate": "SY01", "city": "DAM"}).json()
    assert "N0001" in {a["pcode"] for a in city["areas"]}
    assert city["stations"] and "SY-DAM-C001" in {s["code"] for s in city["stations"]}
    area = c.get("/api/geo/cascade", params={"governorate": "SY01", "city": "DAM", "area": "N0001"}).json()
    assert all(s["place"] == "N0001" for s in area["stations"])
    assert c.get("/api/geo/cascade", params={"governorate": "Damascus"}).status_code == 422
    listed = {x["code"]: x for x in c.get("/api/geo/cities").json()["cities"]}
    assert listed["DAM"]["governorate"] == "SY01" and listed["DAM"]["city_class"] == "MAIN"


def test_a_city_opened_later_is_a_secondary_destination_until_the_platform_says_otherwise(admin):
    village = f"C{next(_VILLAGES)}"
    assert _upload(admin, workbook([(village, f"Village {village}", 36.3, 37.2)])).status_code == 200
    code = "".join(chr(65 + (uuid.uuid4().int >> i) % 26) for i in (0, 8, 16))
    r = admin.post(f"/api/admin/geo/places/{village}/serve", json={"code": code})
    assert r.status_code == 200, r.text
    code = r.json()["city_code"]
    cities = admin.get("/api/geo/cascade", params={"governorate": "SY02"}).json()["cities"]
    mine = next(x for x in cities if x["code"] == code)
    assert mine["city_class"] == "SECONDARY"
    assert [x["city_class"] for x in cities] == sorted((x["city_class"] for x in cities), key=lambda k: k != "MAIN")   # main first
    assert login("owner@carrier.test", "OPERATOR").put(f"/api/admin/geo/cities/{code}", json={"city_class": "MAIN"}).status_code == 403
    assert admin.put(f"/api/admin/geo/cities/{code}", json={"city_class": "CAPITAL"}).status_code == 422
    assert admin.put(f"/api/admin/geo/cities/{code}", json={"city_class": "MAIN"}).json()["city_class"] == "MAIN"
    again = admin.get("/api/geo/cascade", params={"governorate": "SY02"}).json()["cities"]
    assert next(x for x in again if x["code"] == code)["city_class"] == "MAIN"
    assert admin.put("/api/admin/geo/cities/QQZ", json={"city_class": "MAIN"}).status_code == 404

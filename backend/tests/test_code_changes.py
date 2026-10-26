"""Codes that can be changed (owner's request N39, migration 1161): a change is previewed with every code it touches,
refused when a new code is taken, approved by a second person, in effect on its date; a governorate's new code goes
down to its districts and sub-districts, a city's to its stations; the old codes still find what they named."""
import asyncio
import random
import string
from datetime import date, timedelta

import pytest

from test_e2e import OWNER_URL, login, owner_sql
from test_geography import _VILLAGES, _upload, workbook

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _free_city_code() -> str:
    while True:
        code = "".join(random.choices(string.ascii_uppercase, k=3))
        if not owner_sql("SELECT ref.code_entity('CITY', $1)", code):
            return code


@pytest.fixture(scope="module")
def people():
    admin, geo = login("admin@masslak.test", "PLATFORM"), login("geo@masslak.test", "PLATFORM")
    assert _upload(admin, workbook([])).status_code == 200
    return admin, geo


@pytest.fixture()
def city(people):
    """A city of the network opened for the test, with one station."""
    admin, _ = people
    village = f"C{next(_VILLAGES)}"
    assert _upload(admin, workbook([(village, f"Village {village}", 36.3, 37.2)])).status_code == 200
    r = admin.post(f"/api/admin/geo/places/{village}/serve", json={"code": _free_city_code()})
    assert r.status_code == 200, r.text
    code = r.json()["city_code"]
    r = admin.post("/api/admin/stations", json={"city_code": code, "number": 1, "name": "Code test station", "lat": 36.3, "lng": 37.2})
    assert r.status_code == 201, r.text
    return code, r.json()["code"]


def test_a_city_code_changes_with_its_stations_after_a_second_person_approves(people, city):
    admin, geo = people
    code, station = city
    new = _free_city_code()
    # the preview lists the city and its station; a code taken is reported, not used
    plan = admin.post("/api/admin/geo/codes/preview", json={"kind": "CITY", "code": code, "new_code": new}).json()
    assert plan["conflicts"] == [] and [(i["kind"], i["old"], i["new"]) for i in plan["items"]] == [
        ("CITY", code, new), ("STATION", station, f"SY-{new}-C001")]
    taken = admin.post("/api/admin/geo/codes/preview", json={"kind": "CITY", "code": code, "new_code": "DAM"}).json()
    assert {"code": "DAM", "problem": "IN_USE"} in taken["conflicts"]          # and its station's SY-DAM-C001
    r = admin.post("/api/admin/geo/codes/changes", json={"kind": "CITY", "code": code, "new_code": "DAM", "reason": "testing a taken code"})
    assert r.json()["error"]["code"] == "CODE_CONFLICT"
    assert admin.post("/api/admin/geo/codes/preview", json={"kind": "CITY", "code": code, "new_code": "AB1"}).json()["error"]["code"] == "CODE_FORMAT"

    r = admin.post("/api/admin/geo/codes/changes", json={"kind": "CITY", "code": code, "new_code": new, "reason": "new national coding",
                                                         "source_document": "Decision 12/2026"})
    assert r.status_code == 201 and r.json()["codes"] == 2, r.text
    uid = r.json()["uid"]
    # a second request on the same city waits for the first
    again = admin.post("/api/admin/geo/codes/preview", json={"kind": "CITY", "code": code, "new_code": _free_city_code()}).json()
    assert {c["problem"] for c in again["conflicts"]} == {"ANOTHER_CHANGE_WAITING"}
    assert admin.post(f"/api/admin/geo/codes/changes/{uid}/decide", json={"approve": True}).json()["error"]["code"] == "FOUR_EYES"
    assert login("owner@carrier.test", "OPERATOR").post(f"/api/admin/geo/codes/changes/{uid}/decide", json={"approve": True}).status_code == 403
    r = geo.post(f"/api/admin/geo/codes/changes/{uid}/decide", json={"approve": True})
    assert r.json()["status"] == "APPLIED", r.text

    # the new codes are in use; the ids, and so every link, are the same
    assert owner_sql("SELECT code FROM net.station WHERE code = $1", f"SY-{new}-C001")
    assert not owner_sql("SELECT 1 FROM ref.city WHERE code = $1", code)
    cities = {c["code"] for c in admin.get("/api/geo/cities").json()["cities"]}
    assert new in cities and code not in cities
    # the old codes still find what they named, and dated history says when each was used
    hist = admin.get("/api/admin/geo/codes/history", params={"kind": "CITY", "code": code}).json()
    assert hist["code"] == new and [h["code"] for h in hist["old_codes"]] == [code]
    assert admin.get("/api/admin/geo/codes/history", params={"kind": "STATION", "code": station}).json()["code"] == f"SY-{new}-C001"
    assert owner_sql("SELECT ref.current_code('CITY', $1)", code) == new
    assert owner_sql("SELECT ref.code_on('CITY', ref.code_entity('CITY', $1), now() - interval '1 hour')", new) == code
    # nobody else may take an old code, and nobody writes a code directly
    village = f"C{next(_VILLAGES)}"
    assert _upload(admin, workbook([(village, f"Village {village}", 36.3, 37.2)])).status_code == 200
    r = admin.post(f"/api/admin/geo/places/{village}/serve", json={"code": code})
    assert r.status_code >= 400 and r.json()["error"]["code"] == "CODE_OLD", r.text
    with pytest.raises(Exception) as err:
        owner_sql("UPDATE ref.city SET code = $2 WHERE code = $1", new, _free_city_code())
    assert "CODE_CHANGE_REQUIRED" in str(err.value)
    listed = {c["uid"]: c for c in geo.get("/api/admin/geo/codes/changes", params={"status": "APPLIED"}).json()["changes"]}
    assert listed[uid]["decided_by"] == "geo@masslak.test" and listed[uid]["source_document"] == "Decision 12/2026"


def test_a_change_dated_later_waits_and_can_be_withdrawn_or_rejected(people, city):
    admin, geo = people
    code, station = city
    later = (date.today() + timedelta(days=3)).isoformat()
    r = admin.post("/api/admin/geo/codes/changes", json={"kind": "STATION", "code": station, "new_code": f"SY-{code}-C002",
                                                         "reason": "station renumbered", "effective_on": later})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert geo.post(f"/api/admin/geo/codes/changes/{uid}/decide", json={"approve": True}).json()["status"] == "APPROVED"
    assert owner_sql("SELECT ref.apply_due_code_changes()::text") == '{"failed": 0, "applied": 0}'
    assert owner_sql("SELECT 1 FROM net.station WHERE code = $1", station)                 # not yet in effect
    assert geo.post(f"/api/admin/geo/codes/changes/{uid}/cancel").json()["error"]["code"] == "FORBIDDEN"
    assert admin.post(f"/api/admin/geo/codes/changes/{uid}/cancel").json()["status"] == "CANCELLED"
    # a station's code carries its own city; a past date is refused; a rejection says why
    bad = admin.post("/api/admin/geo/codes/preview", json={"kind": "STATION", "code": station, "new_code": "SY-DAM-C777"})
    assert bad.json()["error"]["code"] == "CODE_CITY"
    past = admin.post("/api/admin/geo/codes/changes", json={"kind": "STATION", "code": station, "new_code": f"SY-{code}-C003",
                                                            "reason": "station renumbered", "effective_on": "2020-01-01"})
    assert past.json()["error"]["code"] == "CODE_DATE"
    r = admin.post("/api/admin/geo/codes/changes", json={"kind": "STATION", "code": station, "new_code": f"SY-{code}-C003",
                                                         "reason": "station renumbered"})
    uid = r.json()["uid"]
    assert geo.post(f"/api/admin/geo/codes/changes/{uid}/decide", json={"approve": False}).json()["error"]["code"] == "CODE_NOTE"
    assert geo.post(f"/api/admin/geo/codes/changes/{uid}/decide", json={"approve": False, "note": "keep the number"}
                    ).json()["status"] == "REJECTED"
    assert owner_sql("SELECT 1 FROM net.station WHERE code = $1", station)


def test_a_governorate_code_goes_down_to_its_districts_and_sub_districts(people):
    admin, geo = people
    free = [g for g in (f"SY{n}" for n in range(60, 99)) if not owner_sql("SELECT ref.code_entity('AREA', $1)", g)]
    old, new = free[0], free[1]
    owner_sql("""WITH g AS (INSERT INTO ref.admin_area (pcode, country_code, level, name_en, name_ar) VALUES ($1, 'SY', 1, 'Test gov', 'x') RETURNING id),
                      d AS (INSERT INTO ref.admin_area (pcode, country_code, level, parent_id, name_en, name_ar)
                            SELECT $1 || '01', 'SY', 2, id, 'Test district', 'x' FROM g RETURNING id)
                 INSERT INTO ref.admin_area (pcode, country_code, level, parent_id, name_en, name_ar)
                 SELECT $1 || '0102', 'SY', 3, id, 'Test sub-district', 'x' FROM d""", old)
    # a district keeps its governorate's prefix; the governorate moves it
    assert admin.post("/api/admin/geo/codes/preview", json={"kind": "AREA", "code": f"{old}01", "new_code": f"{new}01"}
                      ).json()["error"]["code"] == "CODE_PARENT"
    plan = admin.post("/api/admin/geo/codes/preview", json={"kind": "AREA", "code": old, "new_code": new}).json()
    assert [(i["old"], i["new"]) for i in plan["items"]] == [(old, new), (f"{old}01", f"{new}01"), (f"{old}0102", f"{new}0102")]
    uid = admin.post("/api/admin/geo/codes/changes", json={"kind": "AREA", "code": old, "new_code": new, "reason": "re-coded"}).json()["uid"]
    assert geo.post(f"/api/admin/geo/codes/changes/{uid}/decide", json={"approve": True}).json()["status"] == "APPLIED"
    assert owner_sql("SELECT count(*) FROM ref.admin_area WHERE left(pcode, 4) = $1", new) == 3
    assert owner_sql("SELECT ref.current_code('AREA', $1)", f"{old}0102") == f"{new}0102"


def test_the_united_nations_file_is_read_through_the_code_changes():
    """A later file still carrying the old codes updates the re-coded areas and places, and an area it adds under a
    re-coded one takes the new prefix."""
    from app.modules.geo import importer

    class Conn:
        async def fetch(self, sql, *args):
            return ([{"old_code": "SY14", "current_code": "SY20"}, {"old_code": "SY1401", "current_code": "SY2001"}]
                    if "'AREA'" in sql else [{"old_code": "C1400", "current_code": "C1499"}])
    wb = importer.Workbook("SY", "x", None,
                           areas=[importer.Area("SY14", 1, None, "G", "g", None, None), importer.Area("SY1401", 2, "SY14", "D", "d", None, None),
                                  importer.Area("SY1405", 2, "SY14", "New", "n", None, None)],
                           places=[importer.Place("C1400", "COMMUNITY", "SY140500", None, "P", "p", 1.0, 1.0)])
    assert asyncio.run(importer._recode(Conn(), wb)) == 7
    assert [(a.pcode, a.parent) for a in wb.areas] == [("SY20", None), ("SY2001", "SY20"), ("SY2005", "SY20")]
    assert (wb.places[0].pcode, wb.places[0].area) == ("C1499", "SY200500")

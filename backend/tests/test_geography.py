"""The administrative geography (owner's request, October 2026; migration 1124): the United Nations workbook of
governorates, districts, sub-districts, communities and neighbourhoods is checked and loaded by the platform; a newer
file updates and retires; places are found by name or code with their way up; a community is opened for routes."""
import io
import uuid

import openpyxl
import pytest

from test_e2e import OWNER_URL, client, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

AR = "\u0645\u0643\u0627\u0646"          # an Arabic word, written with escapes so the source stays in English
COLUMNS = {
    "admin1": ["admin0Name_ar", "admin0Name_en", "admin0Pcode", "admin1Name_ar", "admin1Name_en", "admin1Pcode", "admin1RefName",
               "LastUpdateDate", "validOn", "validTo"],
    "admin2": ["admin0Name_en", "admin0Name_ar", "admin0Pcode", "admin1Name_en", "admin1Name_ar", "admin1Pcode", "admin2Name_en",
               "admin2Name_ar", "admin2Pcode", "admin2RefName", "LastUpdateDate", "validOn", "validTo"],
    "admin3": ["admin0Name_en", "admin0Name_ar", "admin0Pcode", "admin1Name_en", "admin1Name_ar", "admin1Pcode", "admin2Name_en",
               "admin2Name_ar", "admin2Pcode", "admin3Name_en", "admin3Name_ar", "admin3Pcode", "admin3RefName_en", "LastUpdateDate",
               "validOn", "validTo"],
    "city_neighbourhoods": ["admin4Pcode", "areaName_en", "areaName_ar", "areaPcode", "Neighbourhood_Name_en", "Neighbourhood_Name_ar",
                            "Neighbourhood_Pcode", "Neighbourhood_PreviuosPcode"],
    "Location": ["admin0Name_en", "admin0Name_ar", "admin0Pcode", "admin1Name_en", "admin1Name_ar", "admin1Pcode", "admin2Name_en",
                 "admin2Name_ar", "admin2Pcode", "admin3Name_en", "admin3Name_ar", "admin3Pcode", "admin4Name_en", "admin4Name_ar",
                 "admin4Pcode", "LocationName_en", "LocationName_ar", "Location_Pcode", "location_type", "LastUpdateDate",
                 "Latitude_y", "Longitude_x"],
}


def workbook(villages: list[tuple[str, str, float, float]], bad: bool = False) -> bytes:
    """A small workbook in the United Nations' layout: one governorate with Damascus and Aleppo, their districts and
    sub-districts, the two cities with a neighbourhood of Damascus, and the villages given (code, name, lat, lng)."""
    wb = openpyxl.Workbook()
    wb.remove(wb.active)
    sheets = {n: wb.create_sheet(n) for n in COLUMNS}
    for n, cols in COLUMNS.items():
        sheets[n].append(cols)

    def row(sheet: str, **values):
        sheets[sheet].append([values.get(c) for c in COLUMNS[sheet]])
    for code, name in (("SY01", "Damascus"), ("SY02", "Aleppo")):
        row("admin1", admin0Pcode="SY", admin1Pcode=code, admin1Name_en=name, admin1Name_ar=AR, validOn="2016-09-05")
        row("admin2", admin1Pcode=code, admin2Pcode=code + "00", admin2Name_en=name, admin2Name_ar=AR)
        row("admin3", admin2Pcode=code + "00", admin3Pcode=code + "0000", admin3Name_en=name, admin3Name_ar=AR)

    def place(code, name, sub, lat, lng, kind="Community", parent=None):
        row("Location", admin3Pcode=sub, admin4Pcode=parent or code, Location_Pcode=code, LocationName_en=name, LocationName_ar=AR,
            location_type=kind, LastUpdateDate="19/12/2018", Latitude_y=lat, Longitude_x=lng)
    place("C1001", "Damascus", "SY010000", 33.517175, 36.27671)
    place("C1007", "Aleppo", "SY020000", 36.2021, 37.1343)
    place("N0001", "Barza Al Balad", "SY010000", 33.55, 36.32, kind="Neighbourhood", parent="C1001")
    row("city_neighbourhoods", admin4Pcode="C1001", areaPcode="A003", areaName_en="Burza", areaName_ar=AR, Neighbourhood_Pcode="N0001",
        Neighbourhood_Name_en="Barza Al Balad", Neighbourhood_Name_ar=AR, Neighbourhood_PreviuosPcode="SY0100044")
    for code, name, lat, lng in villages:
        place(code, name, "SY020000", lat, lng)
    if bad:
        place("C9999", "Nowhere", "SY990000", 10.0, 10.0)
    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()


def _upload(admin, data: bytes, name: str = "syr_locations.xlsx"):
    return admin.post("/api/admin/geo/import", files={"file": (name, data, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")})


def test_the_platform_loads_the_united_nations_geography_and_opens_a_place_for_routes():
    admin = login("admin@masslak.test", "PLATFORM")
    village = f"C{8000 + uuid.uuid4().int % 1999}"
    # a workbook with mistakes loads nothing, and says what is wrong
    r = _upload(admin, workbook([(village, "Test Village", 36.1, 37.2)], bad=True))
    assert r.status_code == 422 and r.json()["error"]["code"] == "GEO_FILE_INVALID", r.text
    assert "SY990000" in r.json()["error"]["message"] and "outside the country" in r.json()["error"]["message"]
    r = _upload(admin, b"not a workbook")
    assert r.status_code == 422 and r.json()["error"]["code"] == "GEO_FILE_FORMAT"
    # a good one is loaded once; the cities of the network are linked to their places
    data = workbook([(village, "Test Village", 36.1, 37.2)])
    r = _upload(admin, data)
    assert r.status_code == 200 and r.json()["counts"]["communities"] >= 3 and r.json()["counts"]["neighbourhoods"] == 1, r.text
    assert _upload(admin, data).json()["already_loaded"] is True
    assert owner_sql("SELECT p.pcode FROM ref.city c JOIN ref.place p ON p.id = c.place_id WHERE c.code = 'DAM'") == "C1001"
    # anyone finds a place by name or code, with its way up to the governorate
    c = client()
    found = c.get("/api/geo/places", params={"q": "Test Village"}).json()["places"]
    assert found and found[0]["pcode"] == village and found[0]["governorate"]["pcode"] == "SY02" and found[0]["served"] is None
    assert c.get("/api/geo/places", params={"q": village}).json()["places"][0]["pcode"] == village
    assert [a["pcode"] for a in c.get("/api/geo/areas").json()["areas"]][:2] == ["SY01", "SY02"]
    assert any(p["pcode"] == village for p in c.get("/api/geo/areas", params={"parent": "SY020000"}).json()["places"])
    damascus = c.get("/api/geo/places/C1001").json()
    assert damascus["neighbourhoods"][0]["city_area_code"] == "A003" and damascus["served"] == "DAM"
    # the platform opens the village for routes as a city of the network
    letters = "".join(chr(65 + (uuid.uuid4().int >> k) % 26) for k in (0, 8, 16))
    code = "Q" + letters[:2]
    while owner_sql("SELECT 1 FROM ref.city WHERE code = $1", code):
        code = "Q" + "".join(chr(65 + (uuid.uuid4().int >> k) % 26) for k in (0, 8))
    r = admin.post(f"/api/admin/geo/places/{village}/serve", json={"code": "DAM"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "CITY_CODE_TAKEN", r.text
    r = admin.post(f"/api/admin/geo/places/{village}/serve", json={"code": code})
    assert r.status_code == 200 and r.json()["city_code"] == code, r.text
    assert admin.post(f"/api/admin/geo/places/{village}/serve", json={}).json()["city_code"] == code     # already open
    assert admin.post("/api/admin/geo/places/N0001/serve", json={"code": "QQQ"}).json()["error"]["code"] == "PLACE_NOT_COMMUNITY"
    assert login("owner@carrier.test", "OPERATOR").post(f"/api/admin/geo/places/{village}/serve", json={"code": "ZZZ"}).status_code == 403
    summary = admin.get("/api/admin/geo").json()
    assert any(x["code"] == code and x["pcode"] == village for x in summary["cities"]) and summary["loads"]
    # a newer file that no longer holds the village retires it; it is never deleted
    r = _upload(admin, workbook([]), "syr_locations_newer.xlsx")
    assert r.status_code == 200 and r.json()["counts"]["retired"] >= 1, r.text
    assert owner_sql("SELECT status FROM ref.place WHERE pcode = $1", village) == "RETIRED"
    assert not c.get("/api/geo/places", params={"q": village}).json()["places"]


def _box(lat0, lat1, lng0, lng1) -> dict:
    return {"type": "Polygon", "coordinates": [[[lng0, lat0], [lng1, lat0], [lng1, lat1], [lng0, lat1], [lng0, lat0]]]}


def _boundaries(features: list[tuple[dict, dict]]) -> bytes:
    import json
    return json.dumps({"type": "FeatureCollection", "name": f"syr_admbnda_{uuid.uuid4().hex[:6]}",
                       "features": [{"type": "Feature", "properties": p, "geometry": g} for p, g in features]}).encode()


def _upload_boundaries(admin, data: bytes):
    return admin.post("/api/admin/geo/boundaries", files={"file": ("syr_admbnda.geojson", data, "application/geo+json")})


def test_boundaries_field_surveys_and_stations_in_their_places():
    """1125: the areas' boundaries are loaded from the same publisher; a point is located in its sub-district; places
    found in the field are proposed and used once a second person accepts them; a station stands in its place."""
    admin = login("admin@masslak.test", "PLATFORM")
    village = f"C{8000 + uuid.uuid4().int % 1999}"
    assert _upload(admin, workbook([(village, "Survey Base", 36.15, 37.25)]), "syr_locations_survey.xlsx").status_code == 200

    # boundaries: a wrong file loads nothing; a good one puts each shape on its area
    aleppo = _box(35.9, 36.6, 36.8, 37.7)
    r = _upload_boundaries(admin, _boundaries([({"ADM1_PCODE": "SY99"}, aleppo)]))
    assert r.status_code == 422 and r.json()["error"]["code"] == "GEO_FILE_INVALID" and "SY99" in r.json()["error"]["message"], r.text
    r = _upload_boundaries(admin, _boundaries([({"ADM1_PCODE": "SY02"}, {"type": "Point", "coordinates": [37.1, 36.2]})]))
    assert r.status_code == 422 and "not a polygon" in r.json()["error"]["message"], r.text
    assert _upload_boundaries(admin, b"{not json").json()["error"]["code"] == "GEO_FILE_FORMAT"
    r = _upload_boundaries(admin, _boundaries([
        ({"ADM0_PCODE": "SY", "ADM1_PCODE": "SY02"}, aleppo),
        ({"ADM1_PCODE": "SY02", "ADM2_PCODE": "SY0200"}, aleppo),
        ({"ADM1_PCODE": "SY02", "ADM2_PCODE": "SY0200", "ADM3_PCODE": "SY020000"}, aleppo)]))
    assert r.status_code == 200 and r.json()["counts"]["updated"] == 3 and r.json()["counts"]["sub_districts"] == 1, r.text
    shape = client().get("/api/geo/areas/SY020000/boundary").json()
    assert shape["properties"]["pcode"] == "SY020000" and shape["geometry"]["type"] in ("Polygon", "MultiPolygon")
    assert client().get("/api/geo/areas/SY010000/boundary").status_code == 404
    # where a point lies: in its sub-district by the boundary, with the nearest places
    here = client().get("/api/geo/locate", params={"lat": 36.151, "lng": 37.251}).json()
    assert here["by_boundary"] is True and here["sub_district"]["pcode"] == "SY020000" and here["places"][0]["pcode"] == village
    assert here["places"][0]["metres"] < 200

    # a place found in the field: proposed, invisible until a second person accepts it
    body = {"kind": "COMMUNITY", "sub_district": "SY020000", "name_en": f"New Hamlet {uuid.uuid4().hex[:4]}",
            "name_ar": "\u0642\u0631\u064a\u0629", "lat": 36.31, "lng": 37.31, "surveyed_on": "2026-10-01", "note": "eleven houses"}
    r = admin.post("/api/admin/geo/places", json=body | {"lat": 33.5, "lng": 36.3})
    assert r.status_code == 409 and r.json()["error"]["code"] == "PLACE_OUTSIDE_AREA", r.text
    r = admin.post("/api/admin/geo/places", json=body)
    assert r.status_code == 201 and r.json()["pcode"].startswith("F") and r.json()["status"] == "PROPOSED", r.text
    hamlet = r.json()["pcode"]
    assert not client().get("/api/geo/places", params={"q": body["name_en"]}).json()["places"]
    assert admin.post(f"/api/admin/geo/places/{hamlet}/review", json={"accept": True}).json()["error"]["code"] == "FOUR_EYES"
    geo = login("geo@masslak.test", "PLATFORM")
    waiting = geo.get("/api/admin/geo/proposed").json()["places"]
    assert any(p["pcode"] == hamlet and p["status"] == "PROPOSED" and p["proposed_by"] == "admin@masslak.test" for p in waiting)
    assert geo.post(f"/api/admin/geo/places/{hamlet}/review", json={"accept": True, "note": "seen on the survey"}).json()["status"] == "ACTIVE"
    assert client().get("/api/geo/places", params={"q": body["name_en"]}).json()["places"][0]["pcode"] == hamlet
    # a like name close to a known place is most likely that place, unless the surveyor says otherwise
    twin = body | {"name_en": "Survey Base", "lat": 36.151, "lng": 37.251}
    r = admin.post("/api/admin/geo/places", json=twin)
    assert r.status_code == 409 and r.json()["error"]["code"] == "PLACE_DUPLICATE" and village in r.json()["error"]["message"], r.text
    other = admin.post("/api/admin/geo/places", json=twin | {"not_duplicate": True}).json()["pcode"]
    assert geo.post(f"/api/admin/geo/places/{other}/review", json={"accept": False}).json()["error"]["code"] == "REVIEW_NOTE"
    assert geo.post(f"/api/admin/geo/places/{other}/review", json={"accept": False, "note": "the same farm as the known place"}
                    ).json()["status"] == "REJECTED"
    assert geo.post(f"/api/admin/geo/places/{other}/review", json={"accept": True}).json()["error"]["code"] == "PLACE_NOT_PROPOSED"
    assert login("owner@carrier.test", "OPERATOR").post("/api/admin/geo/places", json=body).status_code == 403

    # stations stand in places: the city comes from the place when it is open for routes
    code = "Q" + "".join(chr(65 + (uuid.uuid4().int >> k) % 26) for k in (0, 8))
    while owner_sql("SELECT 1 FROM ref.city WHERE code = $1", code):
        code = "Q" + "".join(chr(65 + (uuid.uuid4().int >> k) % 26) for k in (0, 8))
    r = admin.post("/api/admin/stations", json={"place": hamlet, "number": 1, "name": "Hamlet Stop"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "CITY_REQUIRED", r.text
    assert admin.post(f"/api/admin/geo/places/{village}/serve", json={"code": code}).status_code == 200
    r = admin.post("/api/admin/stations", json={"place": village, "number": 1, "name": "Survey Base Central"})
    assert r.status_code == 201 and r.json()["code"] == f"SY-{code}-C001", r.text
    listed = next(s for s in admin.get("/api/admin/stations").json()["stations"] if s["code"] == f"SY-{code}-C001")
    assert listed["place_pcode"] == village and abs(listed["lat"] - 36.15) < 1e-6
    # a station in the city's governorate takes a village's place; one in another governorate is refused
    r = admin.post("/api/admin/stations", json={"place": hamlet, "city_code": code, "number": 2, "name": "Hamlet Stop"})
    assert r.status_code == 201, r.text
    r = admin.post("/api/admin/stations", json={"place": "N0001", "city_code": code, "number": 3, "name": "Far Stop"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "PLACE_NOT_IN_CITY", r.text
    dam = next(s for s in admin.get("/api/admin/stations").json()["stations"] if s["code"] == "SY-DAM-C001")
    assert admin.put(f"/api/admin/stations/{dam['uid']}/place", json={"place": "N0001"}).status_code == 200
    assert owner_sql("SELECT p.pcode FROM net.station s JOIN ref.place p ON p.id = s.place_id WHERE s.code = 'SY-DAM-C001'") == "N0001"
    # the new city is named in both languages wherever cities are listed
    named = next(c for c in client().get("/api/geo/cities").json()["cities"] if c["code"] == code)
    assert named["name_en"] == "Survey Base" and named["pcode"] == village


def test_the_platform_corrects_published_names_and_they_survive_a_newer_file():
    """1127: a word of the published names written as it is known, in one place or an area; the published name is kept
    and found, the correction holds after a newer file, and removing it gives the published name back."""
    admin = login("admin@masslak.test", "PLATFORM")
    village = f"C{8000 + uuid.uuid4().int % 1999}"
    data = workbook([(village, "Tal Hmeis Quamishli", 36.12, 37.22), ("C1999", "Kfar Quamishli", 36.13, 37.23)])
    assert _upload(admin, data, "syr_names.xlsx").status_code == 200
    # the owner's corrections hold in their areas only: this test file puts the villages in Aleppo, not in Qamishli's district
    assert client().get(f"/api/geo/places/{village}").json()["name_en"] == "Tal Hmeis Quamishli"
    r = admin.post("/api/admin/geo/names", json={"lang": "en", "wrong": "Quamishli", "correct": "Qamishli", "scope": village,
                                                 "reason": "the spelling known locally and internationally"})
    assert r.status_code == 201 and r.json()["changed"] >= 1, r.text
    one = client().get(f"/api/geo/places/{village}").json()
    assert one["name_en"] == "Tal Hmeis Qamishli" and one["published_en"] == "Tal Hmeis Quamishli"
    assert client().get("/api/geo/places/C1999").json()["name_en"] == "Kfar Quamishli"            # another place keeps its name
    # the published spelling still finds it
    assert any(p["pcode"] == village for p in client().get("/api/geo/places", params={"q": "Tal Hmeis Quamishli"}).json()["places"])
    listed = next(c for c in admin.get("/api/admin/geo/names").json()["corrections"] if c["scope_pcode"] == village)
    assert listed["places"] == 1 and listed["correct"] == "Qamishli"
    assert any(c["wrong"] == "Tadmor" and c["scope_pcode"] == "C2889" for c in admin.get("/api/admin/geo/names").json()["corrections"])
    # a newer file publishes the old spelling again: the correction holds
    newer = workbook([(village, "Tal Hmeis Quamishli", 36.12, 37.22), ("C1999", "Kfar Quamishli", 36.13, 37.24)])
    assert _upload(admin, newer, "syr_names_newer.xlsx").status_code == 200
    assert client().get(f"/api/geo/places/{village}").json()["name_en"] == "Tal Hmeis Qamishli"
    assert login("owner@carrier.test", "OPERATOR").post("/api/admin/geo/names", json={
        "lang": "en", "wrong": "Kfar", "correct": "Kafr", "reason": "a carrier tries"}).status_code == 403
    assert admin.delete(f"/api/admin/geo/names/{listed['id']}").status_code == 200
    assert client().get(f"/api/geo/places/{village}").json()["name_en"] == "Tal Hmeis Quamishli"


def test_the_platform_draws_an_area_with_its_boundary_places_and_stations():
    """1129: the map of an area: its boundary, the areas under it, its places (the communities of a sub-district; the
    cities of the network above it) and its stations; for the platform's geography staff only."""
    admin = login("admin@masslak.test", "PLATFORM")
    village = f"C{8000 + uuid.uuid4().int % 1999}"
    assert _upload(admin, workbook([(village, "Map Village", 36.2, 37.3)]), "syr_locations_map.xlsx").status_code == 200
    aleppo = _box(35.9, 36.6, 36.8, 37.7)
    assert _upload_boundaries(admin, _boundaries([
        ({"ADM0_PCODE": "SY", "ADM1_PCODE": "SY02"}, aleppo),
        ({"ADM1_PCODE": "SY02", "ADM2_PCODE": "SY0200"}, aleppo),
        ({"ADM1_PCODE": "SY02", "ADM2_PCODE": "SY0200", "ADM3_PCODE": "SY020000"}, aleppo)])).status_code == 200
    country = admin.get("/api/admin/geo/areas/SY/map")
    assert country.status_code == 200, country.text
    country = country.json()
    assert country["area"]["level"] == 0 and any(c["pcode"] == "SY02" and c["boundary"] for c in country["children"])
    assert all(p["city_code"] for p in country["places"]) and country["stations"]
    sub = admin.get("/api/admin/geo/areas/SY020000/map").json()
    assert sub["area"]["boundary"]["type"] in ("Polygon", "MultiPolygon") and sub["children"] == []
    assert any(p["pcode"] == village for p in sub["places"])
    assert admin.get("/api/admin/geo/areas/SY99/map").status_code == 404
    assert admin.get("/api/admin/geo/areas/XX/map").status_code == 404
    assert login("owner@carrier.test", "OPERATOR").get("/api/admin/geo/areas/SY/map").status_code == 403

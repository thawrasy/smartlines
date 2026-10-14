"""The administrative geography (owner's request, October 2026; migration 1124): the United Nations workbook of
governorates, districts, sub-districts, communities and neighbourhoods is checked and loaded by the platform; a newer
file updates and retires; places are found by name or code with their way up; a community is opened for routes."""
import io
import uuid

import openpyxl
import pytest

from test_e2e import OWNER_URL, client, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

AR = "مكان"          # an Arabic word, written with escapes so the source stays in English
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

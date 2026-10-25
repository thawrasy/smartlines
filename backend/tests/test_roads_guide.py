"""The roads guide (owner's request N38, migration 1162): the owner's workbook of numbered roads is checked against the
loaded geography and loaded whole; junctions are worked out; a road's verification is raised by one person and approved
by another; carriers propose corrections and the platform applies the ones it accepts."""
import io
import random

import openpyxl
import pytest

from test_e2e import OWNER_URL, login
from test_geography import _VILLAGES, _upload, workbook

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

POINT_COLS = 22
INDEX_HEAD = ["number", "old", "class", "name ar", "Road name (English)", "regional", "start", "end", "points", "length",
              "governorates", "areas", "count", "notes"]


def roads_workbook(roads: dict[str, list[tuple]], salt: str = "") -> bytes:
    """roads: code -> [(place, sub_district, lat, lng, km_from_previous)]; the owner's layout, headings in English."""
    wb = openpyxl.Workbook()
    pts = wb.active
    head = [f"c{i}" for i in range(POINT_COLS)]
    head[15] = "Location Pcode"
    pts.append(head)
    idx = wb.create_sheet("index")
    idx.append(INDEX_HEAD)
    for code, points in roads.items():
        total = 0
        for seq, (place, sub, lat, lng, km) in enumerate(points, start=1):
            total += km
            row = [None] * POINT_COLS
            row[0], row[3], row[6], row[9], row[12], row[15] = code, seq, sub[:4], sub[:6], sub, place
            row[16], row[17], row[18], row[19], row[21] = lat, lng, km, total, f"note {salt}"
            pts.append(row)
        idx.append([code, code, "c", f"Road {code} ar", f"Road {code}", None, "a", "b", len(points), total, None, None, 1, None])
    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()


def _load(admin, data: bytes):
    return admin.post("/api/admin/roads/import", files={"file": ("roads.xlsx", data, "application/octet-stream")})


@pytest.fixture(scope="module")
def guide():
    admin, geo = login("admin@masslak.test", "PLATFORM"), login("geo@masslak.test", "PLATFORM")
    v1, v2 = f"C{next(_VILLAGES)}", f"C{next(_VILLAGES)}"
    assert _upload(admin, workbook([(v1, f"Village {v1}", 34.9, 36.8), (v2, f"Village {v2}", 36.4, 37.6)])).status_code == 200
    a, b = (f"S{n}" for n in random.sample(range(900, 999), 2))
    roads = {a: [("C1001", "SY010000", 33.517175, 36.27671, 0), (v1, "SY020000", 34.9, 36.8, 190), ("C1007", "SY020000", 36.2021, 37.1343, 160)],
             b: [("C1007", "SY020000", 36.2021, 37.1343, 0), (v2, "SY020000", 36.4, 37.6, 50)]}
    return admin, geo, a, b, roads, v1


def test_the_owner_file_is_checked_whole_and_loaded(guide):
    admin, _, a, b, roads, v1 = guide
    bad = {a: roads[a][:1] + [("C0001", "SY020000", 34.9, 36.8, 10)]}
    r = _load(admin, roads_workbook(bad))
    assert r.status_code == 422 and r.json()["error"]["code"] == "ROADS_FILE_INVALID" and "C0001" in r.json()["error"]["message"]
    wrong_area = {a: roads[a][:1] + [(v1, "SY010000", 34.9, 36.8, 10)]}
    assert "lies in SY020000" in _load(admin, roads_workbook(wrong_area)).json()["error"]["message"]
    assert _load(admin, b"not a workbook").json()["error"]["code"] == "ROADS_FILE_FORMAT"
    assert login("owner@carrier.test", "OPERATOR").post("/api/admin/roads/import", files={"file": ("r.xlsx", b"x", "application/octet-stream")}).status_code == 403

    first = roads_workbook(roads, "first")   # built once: a workbook records when it was saved, so a rebuild is another file
    r = _load(admin, first)
    assert r.status_code == 200, r.text
    assert r.json()["counts"]["roads"] == 2 and r.json()["counts"]["points"] == 5
    assert _load(admin, first).json()["already_loaded"] is True
    listed = {x["code"]: x for x in admin.get("/api/geo/roads").json()["roads"]}
    assert listed[a]["road_class"] == "SECONDARY" and listed[a]["points"] == 3 and float(listed[a]["length_km"]) == 350
    assert listed[a]["verification_status"] == "OWNER_FILE" and listed[a]["governorates"] == ["SY01", "SY02"]
    road = admin.get(f"/api/geo/roads/{a}").json()
    assert [p["seq"] for p in road["points"]] == [1, 2, 3] and b in road["points"][2]["crossing_roads"]
    assert "C1007" in {j["pcode"] for j in admin.get("/api/geo/roads/junctions").json()["junctions"]}
    drawn = {x["code"]: x for x in admin.get("/api/geo/roads/map").json()["roads"]}
    assert len(drawn[b]["line"]) == 2
    assert admin.get("/api/geo/roads/ZZ999").status_code == 404


def test_verification_is_raised_by_one_person_and_approved_by_another(guide):
    admin, geo, a, _, roads, _ = guide
    r = admin.post(f"/api/admin/roads/{a}/verification", json={"to_status": "CARRIER_CONFIRMED", "document_ref": "Carriers' meeting 3/2026"})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert admin.post(f"/api/admin/roads/{a}/verification", json={"to_status": "AUTHORITY_APPROVED", "document_ref": "letter"}
                      ).json()["error"]["code"] == "ROAD_WAITING"
    assert admin.post(f"/api/admin/roads/verifications/{uid}/decide", json={"approve": True}).json()["error"]["code"] == "FOUR_EYES"
    assert geo.post(f"/api/admin/roads/verifications/{uid}/decide", json={"approve": True}).json()["status"] == "APPROVED"
    assert admin.get(f"/api/geo/roads/{a}").json()["verification_status"] == "CARRIER_CONFIRMED"
    # a later owner file does not overwrite a road verified beyond it
    out = _load(admin, roads_workbook(roads, "second")).json()
    assert a in out["counts"]["kept_verified"]


def test_carriers_propose_corrections_and_the_platform_applies_the_accepted_ones(guide):
    admin, geo, _, b, _, v1 = guide
    carrier = login("owner@carrier.test", "OPERATOR")
    r = carrier.post(f"/api/carrier/roads/{b}/corrections", json={"seq": 2, "kind": "DISTANCE", "km": 55, "remark": "measured on the odometer"})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert carrier.post(f"/api/carrier/roads/{b}/corrections", json={"seq": 2, "kind": "PLACE", "place": "C0001", "remark": "wrong village"}
                        ).json()["error"]["code"] == "PLACE_UNKNOWN"
    assert carrier.post(f"/api/carrier/roads/{b}/corrections", json={"kind": "DISTANCE", "km": 5, "remark": "no point named"}
                        ).json()["error"]["code"] == "ROAD_POINT_REQUIRED"
    mine = carrier.get("/api/carrier/roads/corrections").json()["corrections"]
    assert uid in {c["uid"] for c in mine}
    waiting = {c["uid"]: c for c in admin.get("/api/admin/roads/corrections").json()["corrections"]}
    assert waiting[uid]["current_km"] == 50 and waiting[uid]["km"] == 55
    assert admin.post(f"/api/admin/roads/corrections/{uid}/review", json={"accept": True}).json()["status"] == "ACCEPTED"
    road = admin.get(f"/api/geo/roads/{b}").json()
    assert float(road["points"][1]["km_from_previous"]) == 55 and float(road["points"][1]["km_cumulative"]) == 55 and float(road["length_km"]) == 55
    # a place correction proposed by the platform is reviewed by another person and moves the point
    r = admin.post(f"/api/admin/roads/{b}/corrections", json={"seq": 2, "kind": "PLACE", "place": v1, "remark": "the road passes the other village"})
    uid = r.json()["uid"]
    assert admin.post(f"/api/admin/roads/corrections/{uid}/review", json={"accept": True}).json()["error"]["code"] == "FOUR_EYES"
    assert geo.post(f"/api/admin/roads/corrections/{uid}/review", json={"accept": False}).json()["error"]["code"] == "CORRECTION_NOTE"
    assert geo.post(f"/api/admin/roads/corrections/{uid}/review", json={"accept": True}).json()["status"] == "ACCEPTED"
    assert admin.get(f"/api/geo/roads/{b}").json()["points"][1]["pcode"] == v1

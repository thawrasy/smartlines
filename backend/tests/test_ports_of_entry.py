"""Border crossings and airports (owner's note N45, migration 1168): the owner's approved workbook is checked against the
loaded geography and loaded whole; each port keeps its fixed code while its names and details are edited with a reason,
every change is kept in its history, and a later file does not overwrite what the platform edited by hand."""
import io
import random
import string

import asyncpg
import openpyxl
import pytest

from test_e2e import OWNER_URL, client, login, owner_sql
from test_geography import _upload, workbook

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

HEAD = ["crossing_code", "crossing_kind", "name_ar", "name_en", "counterpart_name_ar", "counterpart_name_en",
        "counterpart_country_iso2", "counterpart_country_en", "iata_code", "admin0Pcode", "admin1Pcode", "admin2Pcode",
        "admin3Pcode", "Location_Pcode", "Latitude_y", "Longitude_x", "match_quality", "review_note"]
AR = "\u0645\u0646\u0641\u0630"            # an Arabic word, escaped so the source stays in English


def ports_workbook(rows: list[dict], salt: str = "") -> bytes:
    wb = openpyxl.Workbook()
    wb.active.title = "guide"
    wb.active.append(["a sheet the importer ignores"])
    ws = wb.create_sheet("import")
    ws.append(HEAD)
    for r in rows:
        ws.append([r.get(h) for h in HEAD[:-1]] + [f"{r.get('review_note') or ''}{salt}" or None])
    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()


def _load(admin, data: bytes):
    return admin.post("/api/admin/ports/import", files={"file": ("ports.xlsx", data, "application/octet-stream")})


def _free(prefix: str, make) -> str:
    for _ in range(200):
        code = make()
        if not owner_sql("SELECT 1 FROM net.port_of_entry WHERE code = $1", code):
            return code
    raise AssertionError(f"no free {prefix} code")


@pytest.fixture(scope="module")
def ports():
    admin = login("admin@masslak.test", "PLATFORM")
    assert _upload(admin, workbook([])).status_code == 200          # Damascus and Aleppo, their districts and sub-districts
    land = _free("LND", lambda: f"LND-LB-{random.randint(10, 99)}")
    remote = _free("LND", lambda: f"LND-IQ-{random.randint(10, 99)}")
    letters = string.ascii_uppercase
    air = _free("AIR", lambda: "AIR-" + "".join(random.choice(letters) for _ in range(3)))
    iata = air[4:] if not owner_sql("SELECT 1 FROM net.port_of_entry WHERE iata_code = $1", air[4:]) else None
    rows = [
        {"crossing_code": land, "crossing_kind": "LAND_BORDER", "name_ar": AR, "name_en": "Test Crossing", "counterpart_name_ar": AR,
         "counterpart_name_en": "Other Side", "counterpart_country_iso2": "LB", "admin0Pcode": "SY", "admin1Pcode": "SY01",
         "admin2Pcode": "SY0100", "admin3Pcode": "SY010000", "Location_Pcode": "C1001", "Latitude_y": 33.51, "Longitude_x": 36.28,
         "match_quality": "EXACT"},
        {"crossing_code": remote, "crossing_kind": "LAND_BORDER", "name_ar": AR, "name_en": "Remote Crossing", "counterpart_name_en": "Far Side",
         "counterpart_country_iso2": "IQ", "admin0Pcode": "SY", "admin1Pcode": "SY02", "admin2Pcode": "SY0200", "admin3Pcode": "SY020000",
         "match_quality": "AREA", "review_note": "tied to its sub-district"},
        {"crossing_code": air, "crossing_kind": "INTL_AIRPORT", "name_ar": AR, "name_en": "Test Airport", "iata_code": iata,
         "admin0Pcode": "SY", "admin1Pcode": "SY02", "admin2Pcode": "SY0200", "admin3Pcode": "SY020000", "Location_Pcode": "C1007",
         "Latitude_y": 36.18, "Longitude_x": 37.22, "match_quality": "NEAREST"},
    ]
    return admin, rows, land, remote, air


def test_the_owner_file_is_checked_whole_and_loaded(ports):
    admin, rows, land, remote, air = ports
    # a crossing whose code names another country, and an airport with a country: nothing is loaded
    bad = [dict(rows[0], counterpart_country_iso2="JO"), dict(rows[2], counterpart_country_iso2="TR")]
    r = _load(admin, ports_workbook(bad))
    assert r.status_code == 422 and r.json()["error"]["code"] == "PORTS_FILE_INVALID", r.text
    assert "country in the code" in r.json()["error"]["message"] and "country" in r.json()["error"]["message"]
    assert _load(admin, b"not a workbook").json()["error"]["code"] == "PORTS_FILE_FORMAT"
    unknown = [dict(rows[0], Location_Pcode="C0001")]
    assert "no active place C0001" in _load(admin, ports_workbook(unknown)).json()["error"]["message"]
    assert not owner_sql("SELECT count(*) FROM net.port_of_entry WHERE code = ANY($1::text[])", [land, remote, air])

    r = _load(admin, ports_workbook(rows))
    assert r.status_code == 200, r.text
    assert r.json()["counts"]["added"] == 3 and r.json()["counts"]["by_kind"]["LAND_BORDER"] == 2
    assert _load(admin, ports_workbook(rows)).json()["already_loaded"] is True       # the same file twice changes nothing
    public = {p["code"]: p for p in client().get("/api/geo/ports").json()["ports"]}
    assert public[land]["counterpart_country"] == "LB" and public[land]["governorate"] == "SY01"
    assert public[remote]["lat"] is None and public[air]["kind"] == "INTL_AIRPORT"
    listed = {p["code"]: p for p in admin.get("/api/admin/ports").json()["ports"]}
    assert listed[remote]["place"] is None and listed[remote]["match_quality"] == "AREA" and listed[land]["place"] == "C1001"
    assert login("passenger@masslak.test", "PASSENGER").get("/api/admin/ports").status_code == 403


def test_names_change_with_a_reason_and_every_change_is_kept(ports):
    admin, rows, land, remote, air = ports
    assert admin.put(f"/api/admin/ports/{land}", json={"name_en": "Renamed Crossing"}).status_code == 422     # no reason
    r = admin.put(f"/api/admin/ports/{land}", json={"name_en": "Renamed Crossing", "status": "RESTRICTED",
                                                   "reason": "the authority renamed it"})
    assert r.status_code == 200 and r.json()["changed_fields"] == 2, r.text
    r = admin.put(f"/api/admin/ports/{remote}", json={"lat": 33.31, "lng": 38.69, "reason": "position surveyed at the gate"})
    assert r.status_code == 200, r.text
    hist = admin.get(f"/api/admin/ports/{land}/history").json()["changes"]
    fields = {c["field"]: c for c in hist}
    assert fields["name_en"]["old_value"] == "Test Crossing" and fields["name_en"]["new_value"] == "Renamed Crossing"
    assert fields["name_en"]["reason"] == "the authority renamed it" and fields["name_en"]["changed_by"] == "admin@masslak.test"
    listed = {p["code"]: p for p in admin.get("/api/admin/ports").json()["ports"]}
    assert listed[remote]["position_source"] == "SURVEY" and listed[remote]["match_quality"] == "SURVEYED"
    assert listed[land]["edited_by_hand"] is True and listed[land]["status"] == "RESTRICTED"
    # the code never changes, and the history is never rewritten
    with pytest.raises(asyncpg.RaiseError, match="PORT_CODE_FIXED"):
        owner_sql("UPDATE net.port_of_entry SET code = 'LND-LB-00' WHERE code = $1", land)
    with pytest.raises(asyncpg.RaiseError, match="PORT_HISTORY_APPEND_ONLY"):
        owner_sql("DELETE FROM net.port_of_entry_change WHERE port_id = (SELECT id FROM net.port_of_entry WHERE code = $1)", land)


def test_a_later_file_keeps_the_platform_edits(ports):
    admin, rows, land, remote, air = ports
    newer = [dict(r, name_en=r["name_en"] + " v2") for r in rows]
    r = _load(admin, ports_workbook(newer, salt=" (second file)"))
    assert r.status_code == 200, r.text
    assert set(r.json()["counts"]["kept_edited"]) == {land, remote} and r.json()["counts"]["updated"] == 1
    listed = {p["code"]: p for p in admin.get("/api/admin/ports").json()["ports"]}
    assert listed[land]["name_en"] == "Renamed Crossing" and listed[air]["name_en"] == "Test Airport v2"
    by_file = [c for c in admin.get(f"/api/admin/ports/{air}/history").json()["changes"] if c["field"] == "name_en"]
    assert by_file and by_file[0]["by_file"] == "ports.xlsx" and by_file[0]["changed_by"] == "admin@masslak.test"   # who loaded it

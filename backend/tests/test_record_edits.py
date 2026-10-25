"""Records are edited and every edit is kept (owner's note, 1170): a vehicle's details with its regulated numbers
changed only with a reason and its history; a new licence and a correction of a saved one, applied when two people of
the platform approve it; a crew member's details, a name corrected only with a reason."""
import uuid

import pytest

from test_e2e import OWNER_URL, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def carrier():
    return login("owner@carrier.test", "OPERATOR")


def _new_vehicle(carrier) -> str:
    tag = uuid.uuid4().hex[:6].upper()
    layouts = carrier.get("/api/carrier/seat-layouts").json()["layouts"]
    r = carrier.post("/api/carrier/vehicles", json={
        "plate_no": f"ED-{tag}", "chassis_no": f"CHS{tag}EDIT", "vehicle_type": "COACH", "seat_layout_uid": layouts[0]["uid"],
        "insurance_no": f"INS-{tag}", "insurer": "Test Insurance", "insurance_issue": "2026-01-01", "insurance_expiry": "2027-12-31"})
    assert r.status_code == 201, r.text
    return r.json()["uid"]


def test_a_vehicle_is_edited_and_its_history_kept(carrier):
    uid = _new_vehicle(carrier)
    tag = uuid.uuid4().hex[:6].upper()
    r = carrier.patch(f"/api/carrier/vehicles/{uid}", json={"plate_no": f"NEW-{tag}"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "VEHICLE_CHANGE_REASON"
    r = carrier.patch(f"/api/carrier/vehicles/{uid}", json={"plate_no": f"NEW-{tag}", "reason": "new plates from the traffic police"})
    assert r.status_code == 200, r.text
    assert carrier.patch(f"/api/carrier/vehicles/{uid}", json={"manufacture_year": 2018, "status": "OUT_OF_SERVICE"}).status_code == 200
    assert carrier.patch(f"/api/carrier/vehicles/{uid}", json={}).json()["error"]["code"] == "NOTHING_TO_CHANGE"
    d = carrier.get(f"/api/carrier/vehicles/{uid}").json()
    assert d["vehicle"]["plate_no"] == f"NEW-{tag}" and d["vehicle"]["manufacture_year"] == 2018 and d["vehicle"]["status"] == "OUT_OF_SERVICE"
    plate = next(h for h in d["history"] if h["field"] == "plate_no")
    assert plate["new_value"] == f"NEW-{tag}" and plate["reason"] == "new plates from the traffic police" and plate["changed_by"]
    assert {h["field"] for h in d["history"]} >= {"plate_no", "manufacture_year", "status"}
    # another carrier, or the platform's held states, are not the carrier's to touch
    assert login("passenger@masslak.test", "PASSENGER").patch(f"/api/carrier/vehicles/{uid}", json={"make": "X"}).status_code in (401, 403)
    owner_sql("UPDATE fleet.vehicle SET status = 'BLOCKED' WHERE uid = $1", uid)
    assert carrier.patch(f"/api/carrier/vehicles/{uid}", json={"status": "ACTIVE"}).json()["error"]["code"] == "VEHICLE_HELD"


def test_a_saved_licence_is_corrected_through_two_approvals(carrier):
    uid = _new_vehicle(carrier)
    r = carrier.post(f"/api/carrier/vehicles/{uid}/licences", json={
        "license_type": "INSPECTION", "license_no": "INSP-1170", "issuer": "Traffic department",
        "issue_date": "2026-06-01", "expiry_date": "2027-06-01"})
    assert r.status_code == 201, r.text
    lic = r.json()["uid"]
    assert any(x["uid"] == lic for x in carrier.get(f"/api/carrier/vehicles/{uid}").json()["licences"])
    r = carrier.post(f"/api/carrier/licences/{lic}/change-request", json={"expiry_date": "2027-09-01", "reason": "date typed wrong"})
    assert r.status_code == 201, r.text
    req = r.json()["request"]
    assert carrier.post(f"/api/carrier/licences/{lic}/change-request",
                        json={"license_no": "INSP-9", "reason": "again"}).json()["error"]["code"] == "LICENCE_CHANGE_OPEN"
    # two people of the platform other than the one who asked: reviewed, then approved; the licence then carries the change
    reviewer = owner_sql("SELECT id FROM iam.app_user WHERE email = 'admin@masslak.test'")
    approver = owner_sql("SELECT id FROM iam.app_user WHERE email = 'security@masslak.test'")
    owner_sql("UPDATE fleet.license_change_request SET status = 'REVIEWED', reviewed_by = $2 WHERE id = $1", req, reviewer)
    owner_sql("UPDATE fleet.license_change_request SET status = 'APPROVED', approved_by = $2, decided_at = now() WHERE id = $1", req, approver)
    got = next(x for x in carrier.get(f"/api/carrier/vehicles/{uid}").json()["licences"] if x["uid"] == lic)
    assert got["expiry_date"] == "2027-09-01" and got["license_no"] == "INSP-1170"


def test_a_crew_member_is_corrected_with_a_reason(carrier):
    r = carrier.post("/api/carrier/crew", json={"crew_type": "HOST", "first_name": "Rami", "last_name": "Haddad"})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    r = carrier.patch(f"/api/carrier/crew/{uid}", json={"last_name": "Haddadin"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "CREW_CHANGE_REASON"
    r = carrier.patch(f"/api/carrier/crew/{uid}", json={"last_name": "Haddadin", "reason": "spelt as in the ID card"})
    assert r.status_code == 200, r.text
    assert carrier.patch(f"/api/carrier/crew/{uid}", json={"crew_type": "ASSISTANT", "license_class": "b"}).status_code == 200
    d = carrier.get(f"/api/carrier/crew/{uid}").json()
    assert d["last_name"] == "Haddadin" and d["full_name"] == "Rami Haddadin" and d["crew_type"] == "ASSISTANT" and d["license_class"] == "B"
    kept = owner_sql("""SELECT count(*) FROM fleet.crew_change c JOIN iam.party p ON p.id = c.party_id
                         WHERE p.uid = $1 AND c.field IN ('crew_type', 'license_class')""", uid)
    assert kept == 2
    assert carrier.patch(f"/api/carrier/crew/{uid}", json={"first_name": None, "reason": "test"}).json()["error"]["code"] == "NAME_PARTS_REQUIRED"


def test_the_platform_edits_a_station_and_keeps_its_history():
    admin = login("admin@masslak.test", "PLATFORM")
    st = admin.get("/api/admin/stations").json()["stations"][0]
    r = admin.patch(f"/api/admin/stations/{st['uid']}", json={"name": st["name"] + " (renamed)"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "STATION_CHANGE_REASON"
    assert admin.patch(f"/api/admin/stations/{st['uid']}", json={"lat": 33.5}).json()["error"]["code"] == "POSITION_PAIR"
    r = admin.patch(f"/api/admin/stations/{st['uid']}", json={"name": st["name"] + " (renamed)", "phone": "+963112223344",
                                                             "reason": "the governorate renamed the station"})
    assert r.status_code == 200, r.text
    d = admin.get(f"/api/admin/stations/{st['uid']}").json()
    assert d["station"]["name"].endswith("(renamed)") and d["station"]["phone"] == "+963112223344"
    assert {h["field"] for h in d["history"]} >= {"name", "phone"}
    assert next(h for h in d["history"] if h["field"] == "name")["reason"] == "the governorate renamed the station"
    admin.patch(f"/api/admin/stations/{st['uid']}", json={"name": st["name"], "reason": "test: back to the old name"})
    carrier = login("owner@carrier.test", "OPERATOR")
    assert carrier.patch(f"/api/admin/stations/{st['uid']}", json={"phone": "+963110000000"}).status_code in (401, 403)


def test_the_platform_corrects_a_company_and_keeps_its_history():
    admin = login("admin@masslak.test", "PLATFORM")
    co = next(c for c in admin.get("/api/admin/companies").json()["companies"] if c["company_type"] == "CARRIER")
    r = admin.patch(f"/api/admin/companies/{co['uid']}", json={"legal_name": co["legal_name"] + " LLC"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "COMPANY_CHANGE_REASON"
    r = admin.patch(f"/api/admin/companies/{co['uid']}", json={"legal_name": co["legal_name"] + " LLC", "cr_expiry": "2030-12-31",
                                                               "reason": "registered name corrected from the register"})
    assert r.status_code == 200, r.text
    d = admin.get(f"/api/admin/companies/{co['uid']}").json()
    assert d["company"]["legal_name"] == co["legal_name"] + " LLC" and d["company"]["cr_expiry"] == "2030-12-31"
    name = next(h for h in d["history"] if h["field"] == "legal_name")
    assert name["old_value"] == co["legal_name"] and name["reason"] == "registered name corrected from the register"
    admin.patch(f"/api/admin/companies/{co['uid']}", json={"legal_name": co["legal_name"], "reason": "test: back to the old name"})

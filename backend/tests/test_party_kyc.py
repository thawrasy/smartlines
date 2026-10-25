"""Know your customer for every party (owner's request N14, migration 1159): agencies and station operating companies
fill the form of their kind, drivers and passengers fill theirs about themselves, one reviewer verifies a person, and
what a verified person unlocks is a platform setting that locks nothing at launch."""
import json
import uuid

import pytest

from test_boarding_stations import operating_company, station_session  # noqa: F401  (a fixture and its sign-in)
from test_e2e import OWNER_URL, client, login, new_passenger, owner_sql, settle_password

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
ID_NO = "N" + uuid.uuid4().hex[:9].upper()


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


def sections(view: dict) -> set[str]:
    return {s["key"] for s in view["definition"]["sections"]}


def person_answers(**extra) -> dict:
    return {"nationality": "SY", "id_type": "NATIONAL_ID", "id_number": ID_NO, "birth_date": "1990-04-02",
            "residence_governorate": "Damascus", "residence_city": "Damascus", "residence_address": "Mezzeh, building 4",
            "pep_any": {"value": False}, "consent_processing": True, "attestation": True, **extra}


def test_an_agency_fills_the_agency_form():
    agency = login("agency@agency.test", "AGENCY")
    view = agency.get("/api/agency/kyc")
    assert view.status_code == 200, view.text
    assert "agency_operations" in sections(view.json()) and "fleet" not in sections(view.json())
    opened = agency.post("/api/agency/kyc/open").json()
    uid = opened["file"]["uid"]
    r = agency.put(f"/api/agency/kyc/{uid}", json={"answers": {"legal_name": "Agency Test", "agency_services": ["TICKETS", "GROUP_TOURS"]}})
    assert r.status_code == 200, r.text
    assert r.json()["answers"]["agency_services"] == ["TICKETS", "GROUP_TOURS"] and "agency_license_no" in r.json()["missing"]
    bad = agency.put(f"/api/agency/kyc/{uid}", json={"answers": {"agency_services": ["BOATS"]}})
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "KYC_INVALID"
    assert agency.post(f"/api/agency/kyc/{uid}/submit").json()["error"]["code"] == "KYC_INCOMPLETE"
    assert agency.get("/api/carrier/kyc").status_code == 403                  # the agency's own door only


def test_a_station_operating_company_fills_the_station_form(operating_company):  # noqa: F811
    c = station_session(operating_company)
    view = c.get("/api/station/kyc")
    assert view.status_code == 200, view.text
    assert "station_site" in sections(view.json())
    uid = c.post("/api/station/kyc/open").json()["file"]["uid"]
    r = c.put(f"/api/station/kyc/{uid}", json={"answers": {"station_facilities": ["WAITING_HALL", "PRAYER_ROOM"], "bays_count": 24}})
    assert r.status_code == 200 and r.json()["answers"]["bays_count"] == 24, r.text


def test_a_passenger_is_verified_by_a_reviewer(admin):
    pax = new_passenger()
    view = pax.get("/api/account/kyc").json()
    assert view["kind"] == "PASSENGER" and view["file"] is None and view["verified"] is False and view["required_before"] == []
    uid = pax.post("/api/account/kyc/open").json()["file"]["uid"]
    saved = pax.put(f"/api/account/kyc/{uid}", json={"answers": person_answers()})
    assert saved.status_code == 200 and saved.json()["missing"] == [] and saved.json()["completeness"] == 100, saved.text
    sealed = saved.json()["answers"]["id_number"]
    assert sealed["$last4"] == ID_NO[-4:] and ID_NO not in json.dumps(saved.json())
    party = owner_sql("SELECT party_id FROM iam.person_kyc WHERE uid = $1", uuid.UUID(uid))
    assert ID_NO not in owner_sql("SELECT answers::text FROM iam.person_kyc WHERE uid = $1", uuid.UUID(uid))
    assert pax.post(f"/api/account/kyc/{uid}/submit").json()["status"] == "SUBMITTED"
    assert owner_sql("SELECT verification_status FROM iam.party WHERE id = $1", party) == "PENDING"
    assert pax.put(f"/api/account/kyc/{uid}", json={"answers": person_answers()}).json()["error"]["code"] == "KYC_LOCKED"

    waiting = {f["uid"]: f for f in admin.get("/api/admin/person-kyc?status=WAITING").json()["files"]}
    assert waiting[uid]["subject_kind"] == "PASSENGER"
    seen = admin.get(f"/api/admin/person-kyc/{uid}").json()
    assert seen["may_decide"] is True and seen["person"]["verification_status"] == "PENDING"
    shown = admin.post(f"/api/admin/person-kyc/{uid}/reveal", json={"path": "id_number", "reason": "checking the identity card"})
    assert shown.status_code == 200 and shown.json()["value"] == ID_NO, shown.text
    nope = admin.post(f"/api/admin/person-kyc/{uid}/decide", json={"decision": "RETURN"})
    assert nope.status_code == 422 and nope.json()["error"]["code"] == "REASON_REQUIRED"
    back = admin.post(f"/api/admin/person-kyc/{uid}/decide", json={"decision": "RETURN", "note": "the address is short", "fields": ["residence_address"]})
    assert back.json()["status"] == "RETURNED"
    mine = pax.get("/api/account/kyc").json()
    assert mine["file"]["return_fields"] == ["residence_address"] and mine["verification_status"] == "UNVERIFIED"
    pax.put(f"/api/account/kyc/{uid}", json={"answers": person_answers(residence_address="Mezzeh, street 12, building 4", id_number=sealed)})
    assert pax.post(f"/api/account/kyc/{uid}/submit").json()["status"] == "SUBMITTED"
    ok = admin.post(f"/api/admin/person-kyc/{uid}/decide", json={"decision": "APPROVE"})
    assert ok.status_code == 200 and ok.json()["status"] == "APPROVED" and ok.json()["review_due"], ok.text
    mine = pax.get("/api/account/kyc").json()
    assert mine["verified"] is True and mine["verification_status"] == "VERIFIED" and mine["file"]["status"] == "APPROVED"
    # the kept number still opens after the correction
    assert admin.post(f"/api/admin/person-kyc/{uid}/reveal", json={"path": "id_number", "reason": "second look"}).json()["value"] == ID_NO
    assert pax.get(f"/api/admin/person-kyc/{uid}").status_code == 403


def test_what_a_verified_person_unlocks_is_a_setting(admin):
    before = admin.get("/api/admin/kyc/settings").json()["persons"]
    assert before["required_before"] == {"PASSENGER": [], "DRIVER": []}            # nothing locked at launch
    bad = admin.put("/api/admin/kyc/settings/persons", json={"value": {"required_before": {"PASSENGER": ["DRIVE"], "DRIVER": []},
                                                                      "review_months": {"PASSENGER": 60, "DRIVER": 24}}})
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "INVALID_SETTING"
    pax = new_passenger()
    party = owner_sql("SELECT party_id FROM iam.app_user WHERE email = $1", pax.get("/api/auth/me").json()["email"])
    on = {"required_before": {"PASSENGER": ["LOYALTY_REDEEM"], "DRIVER": ["DRIVE"]}, "review_months": {"PASSENGER": 60, "DRIVER": 24}}
    assert admin.put("/api/admin/kyc/settings/persons", json={"value": on}).status_code == 200
    try:
        assert pax.get("/api/account/kyc").json()["required_before"] == ["LOYALTY_REDEEM"]
        with pytest.raises(Exception, match="KYC_REQUIRED"):
            owner_sql("SELECT iam.person_kyc_gate($1, 'PASSENGER', 'LOYALTY_REDEEM')", party)
    finally:
        assert admin.put("/api/admin/kyc/settings/persons", json={"value": before}).status_code == 200
    owner_sql("SELECT iam.person_kyc_gate($1, 'PASSENGER', 'LOYALTY_REDEEM')", party)    # off again: nothing refused


def test_a_driver_fills_the_driver_form():
    carrier = login("owner@carrier.test", "OPERATOR")
    email = f"kycdrv{uuid.uuid4().hex[:8]}@example.com"
    password = "Harbour-Lantern-Window-73"
    r = carrier.post("/api/carrier/crew", json={"crew_type": "DRIVER", "first_name": "Kareem", "last_name": "Saleh",
                                                "email": email, "password": password})
    assert r.status_code == 201, r.text
    settle_password(email)
    driver = client()
    assert driver.post("/api/auth/login", json={"identifier": email, "password": password, "portal": "DRIVER"}).status_code == 200
    view = driver.get("/api/account/kyc").json()
    assert view["kind"] == "DRIVER" and "driving_record" in sections(view)
    uid = driver.post("/api/account/kyc/open").json()["file"]["uid"]
    r = driver.put(f"/api/account/kyc/{uid}", json={"answers": {"licence_classes": ["D", "E"], "years_driving": 12}})
    assert r.status_code == 200 and "criminal_record" in r.json()["missing"], r.text


def test_each_kind_has_its_own_form_versions(admin):
    forms = {k: admin.get(f"/api/admin/kyc/form?kind={k}").json() for k in ("CARRIER", "AGENCY", "STATION", "DRIVER", "PASSENGER")}
    assert all(f["active"] for f in forms.values())
    assert len({f["active"]["version"] for f in forms.values()}) == 5
    person = forms["PASSENGER"]["active"]["definition"]
    with_docs = dict(person, documents=[{"type": "CR", "required": True}])
    r = admin.put("/api/admin/kyc/form?kind=PASSENGER", json={"definition": with_docs})
    assert r.status_code == 422 and r.json()["error"]["code"] == "KYC_FORM_INVALID"
    draft = admin.put("/api/admin/kyc/form?kind=PASSENGER", json={"definition": person, "note": "same as before"})
    assert draft.status_code == 200, draft.text
    assert admin.get("/api/admin/kyc/form?kind=CARRIER").json()["draft"] is None or \
        admin.get("/api/admin/kyc/form?kind=CARRIER").json()["draft"]["version"] != draft.json()["version"]
    owner_sql("DELETE FROM iam.kyc_form WHERE version = $1 AND status = 'DRAFT'", draft.json()["version"])

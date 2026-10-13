"""Know your customer for the companies on the platform (owner's request, October 2026; migration 1118).

* When the platform establishes a company it opens the company's KYC file: identity, licensing, ownership and control,
  compliance declarations, finances, taxes, operations, fleet, staff and agents, expectations, consents.
* The company fills it in its portal, or platform staff capture it from paper. Identity document and account numbers
  are encrypted before they are stored; reading one in clear needs a reason and is recorded.
* A complete file is submitted with the documents asked for and passes the review stages of the settings (compliance,
  then finance, by default), one person per stage; a stage approves, returns it with what to correct, or rejects it.
  Its risk is scored by rules that are settings and sets when it is reviewed again.
* The form is versioned data: the platform makes and activates a new version without a release.
"""
import uuid
from datetime import date

import pytest

from test_boarding_stations import ADMIN, CARRIER
from test_e2e import OWNER_URL, day, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

FINANCE = ("finance@masslak.test", "PLATFORM")
YES = {"aml_policy", "cash_handling_controls", "tax_clearance", "passenger_insurance", "vehicle_insurance", "technical_inspection",
       "social_insurance", "einvoice_mandate", "prices_include_tax", "route_permits", "indirect_tax_registered", "audited_accounts"}


@pytest.fixture(scope="module")
def admin():
    return login(*ADMIN)


@pytest.fixture(scope="module")
def carrier():
    return login(*CARRIER)


@pytest.fixture(scope="module")
def finance():
    return login(*FINANCE)


def _setting(admin, key: str, value):
    r = admin.put(f"/api/admin/kyc/settings/{key}", json={"value": value})
    assert r.status_code == 200, r.text


def _options(definition: dict, name: str) -> list:
    return [o["value"] if isinstance(o, dict) else o for o in definition["option_sets"][name]]


def _value(spec: dict, definition: dict, i: int, in_table: bool):
    t, key = spec["type"], spec["key"]
    if spec.get("sensitive"):
        return f"ID-{i}{key[:2].upper()}0012345"
    return {
        "email": f"{key}{i}@example.com", "phone": "+963 11 2223344", "url": "https://example.com", "country": "SY",
        "station": "Damascus Central", "date": "2015-03-01", "time": "07:30", "textarea": f"Answer to {key}",
        "select": (_options(definition, spec["options"]) or [None])[0] if spec.get("options") else None,
        "multi": _options(definition, spec["options"])[:1] if spec.get("options") else None,
        "number": max(int(spec.get("min", 1)), 1), "decimal": max(spec.get("min", 1), 1), "percent": 10, "money": 2600000,
        "yesno": {"value": True, "details": "Details given"} if key in YES else {"value": False},
        "bool": not in_table,
    }.get(t, f"Answer {key} {i}"[:int(spec.get("max", 300))])


def complete_answers(definition: dict) -> dict:
    """A complete, low-risk set of answers to whatever version of the form is in force."""
    out = {}
    for section in definition["sections"]:
        for f in section["fields"]:
            if f["type"] == "table":
                out[f["key"]] = [{c["key"]: _value(c, definition, i, True) for c in f["columns"]}
                                 for i in range(max(f.get("min_rows", 1), 1))]
            else:
                out[f["key"]] = _value(f, definition, 0, False)
    return out


def _open(carrier, admin) -> dict:
    """The demo carrier's open file, ready to fill: one left under review by an earlier run is rejected first."""
    view = carrier.post("/api/carrier/kyc/open").json()
    if view["file"]["status"] == "SUBMITTED":
        r = admin.post(f"/api/admin/kyc/{view['file']['uid']}/decide", json={"decision": "REJECT", "note": "left by an earlier run"})
        assert r.status_code == 200, r.text
        view = carrier.post("/api/carrier/kyc/open").json()
    assert view["file"]["status"] in ("DRAFT", "RETURNED"), view
    return view


def test_the_company_fills_its_file_and_identity_numbers_are_kept_encrypted(admin, carrier):
    view = _open(carrier, admin)
    definition, uid = view["definition"], view["file"]["uid"]
    assert [s["key"] for s in definition["sections"]][:3] == ["identity", "licensing", "contacts"]
    assert {d["type"] for d in view["documents"] if d["required"]} >= {"CR", "TRANSPORT_LICENSE", "TAX_CERT", "ID_DOCUMENT"}
    assert "risk_level" not in view["file"] and "risk_score" not in view["file"]
    answers = complete_answers(definition)
    secret = f"N-{uuid.uuid4().int % 10 ** 9:09d}"
    answers["ubos"][0]["id_number"] = secret
    saved = carrier.put(f"/api/carrier/kyc/{uid}", json={"answers": answers})
    assert saved.status_code == 200, saved.text
    sealed = saved.json()["answers"]["ubos"][0]["id_number"]
    assert sealed["$last4"] == secret[-4:] and "$enc" in sealed and saved.json()["completeness"] == 100
    stored = owner_sql("SELECT answers::text FROM iam.company_kyc WHERE uid = $1", uuid.UUID(uid))
    assert secret not in stored and secret[2:] not in stored
    # sent back as received, the value is kept; moved to another field or another row's column, it is refused
    answers["ubos"][0]["id_number"] = sealed
    again = carrier.put(f"/api/carrier/kyc/{uid}", json={"answers": answers}).json()
    assert again["answers"]["ubos"][0]["id_number"]["$enc"] == sealed["$enc"]
    moved = dict(answers, directors=[dict(answers["directors"][0], id_number=sealed)])
    r = carrier.put(f"/api/carrier/kyc/{uid}", json={"answers": moved})
    assert r.status_code == 422 and r.json()["error"]["errors"] == {"directors.0.id_number": "sealed"}, r.text
    # every answer is checked against the form
    bad = dict(answers, company_email="not-an-email", cash_share_pct=150, legal_form="NOPE", ownership_layers="two")
    r = carrier.put(f"/api/carrier/kyc/{uid}", json={"answers": bad})
    assert r.status_code == 422 and r.json()["error"]["errors"] == {
        "company_email": "email", "cash_share_pct": "range", "legal_form": "option", "ownership_layers": "number"}, r.text
    # nothing is submitted without the documents the form asks for
    r = carrier.post(f"/api/carrier/kyc/{uid}/submit")
    assert r.status_code == 422 and r.json()["error"]["code"] == "KYC_INCOMPLETE", r.text
    assert "doc:ARTICLES" in r.json()["error"]["missing"] and "doc:BANK_LETTER" in r.json()["error"]["missing"]


def test_a_file_passes_compliance_and_finance_one_person_per_stage(admin, carrier, finance):
    view = _open(carrier, admin)
    uid = view["file"]["uid"]
    answers = complete_answers(view["definition"])
    answers["ubos"][0]["id_number"] = "N-555001234"
    assert carrier.put(f"/api/carrier/kyc/{uid}", json={"answers": answers}).status_code == 200
    try:
        _setting(admin, "documents_on_submit", False)
        submitted = carrier.post(f"/api/carrier/kyc/{uid}/submit")
        assert submitted.status_code == 200 and submitted.json()["waiting_for"] == {"by": "COMPLIANCE"}, submitted.text
    finally:
        _setting(admin, "documents_on_submit", True)
    mine = carrier.get("/api/carrier/kyc").json()["file"]
    assert mine["status"] == "SUBMITTED" and mine["waiting_for"] == "COMPLIANCE" and "risk_factors" not in mine
    assert carrier.put(f"/api/carrier/kyc/{uid}", json={"answers": answers}).json()["error"]["code"] == "KYC_LOCKED"
    # the platform's list shows the stage waiting; finance does not decide compliance
    row = next(f for f in admin.get("/api/admin/kyc?status=WAITING").json()["files"] if f["uid"] == uid)
    assert row["waiting_for"] == {"by": "COMPLIANCE"} and row["may_decide"] and row["risk_level"] == "LOW"
    r = finance.post(f"/api/admin/kyc/{uid}/decide", json={"decision": "APPROVE"})
    assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_YOUR_STAGE", r.text
    # an identity number is read in clear only with a reason, and the reading is recorded
    full = admin.get(f"/api/admin/kyc/{uid}").json()
    assert full["answers"]["ubos"][0]["id_number"]["$last4"] == "1234" and full["may_decide"]
    assert admin.post(f"/api/admin/kyc/{uid}/reveal", json={"path": "ubos.0.id_number", "reason": "x"}).status_code == 422
    shown = admin.post(f"/api/admin/kyc/{uid}/reveal", json={"path": "ubos.0.id_number", "reason": "checking the owner's ID card"})
    assert shown.status_code == 200 and shown.json()["value"] == "N-555001234", shown.text
    assert owner_sql("""SELECT count(*) FROM audit.data_access_log WHERE object_type = 'company_kyc'
                         AND fields = ARRAY['ubos.0.id_number'] AND purpose LIKE 'KYC_REVIEW%'""") >= 1
    assert owner_sql("SELECT count(*) FROM sec.policy_decision WHERE purpose_code = 'KYC_REVIEW' AND decision = 'ALLOW'") >= 1
    # compliance returns it with what to correct; the company corrects and submits again
    r = admin.post(f"/api/admin/kyc/{uid}/decide", json={"decision": "RETURN", "note": "Name the auditor", "fields": ["audited_accounts"]})
    assert r.status_code == 200 and r.json()["status"] == "RETURNED", r.text
    mine = carrier.get("/api/carrier/kyc").json()["file"]
    assert mine["status"] == "RETURNED" and mine["return_note"] == "Name the auditor" and mine["return_fields"] == ["audited_accounts"]
    answers["audited_accounts"] = {"value": True, "details": "Example Audit and Partners"}
    answers["ubos"][0]["id_number"] = full["answers"]["ubos"][0]["id_number"]
    assert carrier.put(f"/api/carrier/kyc/{uid}", json={"answers": answers}).status_code == 200
    try:
        _setting(admin, "documents_on_submit", False)
        assert carrier.post(f"/api/carrier/kyc/{uid}/submit").status_code == 200
    finally:
        _setting(admin, "documents_on_submit", True)
    # compliance approves and sets the level, then finance, a second person
    r = admin.post(f"/api/admin/kyc/{uid}/decide", json={"decision": "APPROVE", "note": "Cash-heavy business", "risk_level": "MEDIUM"})
    assert r.status_code == 200 and r.json()["next"] == {"by": "FINANCE"}, r.text
    r = admin.post(f"/api/admin/kyc/{uid}/decide", json={"decision": "APPROVE"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "SECOND_PERSON_REQUIRED", r.text
    r = finance.post(f"/api/admin/kyc/{uid}/decide", json={"decision": "APPROVE"})
    assert r.status_code == 200 and r.json()["status"] == "APPROVED" and r.json()["risk_level"] == "MEDIUM", r.text
    due = date.fromisoformat(r.json()["review_due"])
    today = date.fromisoformat(day(0))     # the market's date, as the database counts it
    assert (due.year - today.year) * 12 + due.month - today.month == 24
    full = admin.get(f"/api/admin/kyc/{uid}").json()
    assert [(x["decision"], x["stage"]["by"]) for x in full["decisions"]][-3:] == [
        ("RETURN", "COMPLIANCE"), ("APPROVE", "COMPLIANCE"), ("APPROVE", "FINANCE")]
    # an update is a new version from the approved answers; the approved file stays in force meanwhile
    update = carrier.post("/api/carrier/kyc/open").json()
    assert update["file"]["status"] == "DRAFT" and update["file"]["version"] == full["version"] + 1
    assert update["approved"]["status"] == "APPROVED" and update["file"]["answers"]["legal_form"] == answers["legal_form"]


def test_platform_staff_capture_a_file_from_paper_and_another_person_reviews_it(admin, finance):
    code = "".join(chr(65 + (uuid.uuid4().int >> i) % 26) for i in (0, 8, 16))
    r = admin.post("/api/admin/companies", json={"legal_name": f"Paper Carrier {code}", "code3": code, "owner_name": "Owner",
                                                 "owner_email": f"{code.lower()}{uuid.uuid4().hex[:4]}@example.com",
                                                 "owner_password": "paper-carrier-passphrase"})
    assert r.status_code == 201, r.text
    company = r.json()["uid"]
    # the company's file was opened when the platform established it
    row = next(f for f in admin.get("/api/admin/kyc?status=OPEN").json()["files"] if f["company_uid"] == company)
    assert row["status"] == "DRAFT" and row["version"] == 1
    assert admin.post(f"/api/admin/kyc/companies/{company}/open").json()["uid"] == row["uid"]
    full = admin.get(f"/api/admin/kyc/{row['uid']}").json()
    assert full["answers"]["legal_name"] == f"Paper Carrier {code}"
    answers = complete_answers(full["definition"])
    answers["sanctions_listed"] = {"value": True, "details": "Listed by a national list"}
    saved = admin.put(f"/api/admin/kyc/{row['uid']}", json={"answers": answers})
    assert saved.status_code == 200 and saved.json()["completeness"] == 100, saved.text
    try:
        _setting(admin, "documents_on_submit", False)
        assert admin.post(f"/api/admin/kyc/{row['uid']}/submit").status_code == 200
    finally:
        _setting(admin, "documents_on_submit", True)
    listed = next(f for f in admin.get("/api/admin/kyc?status=WAITING").json()["files"] if f["uid"] == row["uid"])
    assert listed["risk_level"] == "PROHIBITED"
    # who captured and submitted the file does not review it; a sanctions match is never approved
    r = admin.post(f"/api/admin/kyc/{row['uid']}/decide", json={"decision": "REJECT", "note": "Sanctions match"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "SECOND_PERSON_REQUIRED", r.text
    security = login("security@masslak.test", "PLATFORM")
    r = security.post(f"/api/admin/kyc/{row['uid']}/decide", json={"decision": "APPROVE"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "KYC_PROHIBITED", r.text
    r = security.post(f"/api/admin/kyc/{row['uid']}/decide", json={"decision": "REJECT", "note": "Sanctions match confirmed"})
    assert r.status_code == 200 and r.json()["status"] == "REJECTED", r.text
    # a company's staff never see another company's file, and finance cannot capture
    assert finance.put(f"/api/admin/kyc/{row['uid']}", json={"answers": {}}).status_code == 403


def test_the_gate_and_the_settings_are_the_platforms(admin, carrier):
    r = admin.put("/api/admin/kyc/settings/review_stages", json={"value": [{"by": "BOSS"}]})
    assert r.status_code == 422 and r.json()["error"]["code"] == "INVALID_SETTING", r.text
    r = admin.put("/api/admin/kyc/settings/risk_levels", json={"value": {"MEDIUM": 70, "HIGH": 60}})
    assert r.status_code == 422, r.text
    assert carrier.put("/api/admin/kyc/settings/required_before", json={"value": []}).status_code == 403
    settings = admin.get("/api/admin/kyc/settings").json()
    assert settings["review_stages"] == [{"by": "COMPLIANCE"}, {"by": "FINANCE"}] and settings["ubo_threshold_pct"] == 25
    assert any(rule["code"] == "SANCTIONS" and rule["level"] == "PROHIBITED" for rule in settings["risk_rules"])
    # while the platform asks for it, a company whose file is not approved publishes no trip
    view = carrier.get("/api/carrier/kyc").json()
    assert view["approved"] is not None                     # the demo carrier's file was approved above
    route = next(r["uid"] for r in carrier.get("/api/carrier/schedules").json()["routes"] if r["code"] == "DAM-ALP")
    from test_launch import _fresh_vehicle
    try:
        _setting(admin, "required_before", ["PUBLISH_TRIPS"])
        r = carrier.post("/api/carrier/trips", json={"route_uid": route, "vehicle_uid": _fresh_vehicle(carrier),
                                                      "departure_local": f"{day(22)}T22:{uuid.uuid4().int % 60:02d}:00", "publish": True})
        assert r.status_code == 201, r.text                # approved: it publishes
        owner_sql("UPDATE iam.company_kyc SET status = 'SUPERSEDED' WHERE company_id = (SELECT company_id FROM iam.company_member m "
                  "JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = 'owner@carrier.test' LIMIT 1) AND status = 'APPROVED'")
        r = carrier.post("/api/carrier/trips", json={"route_uid": route, "vehicle_uid": _fresh_vehicle(carrier),
                                                      "departure_local": f"{day(23)}T22:{uuid.uuid4().int % 60:02d}:00", "publish": True})
        assert r.status_code == 409 and r.json()["error"]["code"] == "KYC_REQUIRED", r.text
    finally:
        _setting(admin, "required_before", [])


def test_the_form_is_versioned_data_the_platform_checks_and_activates(admin, carrier):
    form = admin.get("/api/admin/kyc/form").json()
    active = form["active"]
    assert active["status"] == "ACTIVE" and len(active["definition"]["sections"]) == 13
    r = admin.put("/api/admin/kyc/form", json={"definition": {"sections": [{"key": "a1", "fields": [{"key": "x1", "type": "blob"}]}]}})
    assert r.status_code == 422 and r.json()["error"]["code"] == "KYC_FORM_INVALID", r.text
    # the regulator asks a new question: a field the platform adds, with its own labels, in a new version
    definition = active["definition"]
    definition["sections"][1]["fields"].append({"key": f"road_safety_cert_{uuid.uuid4().hex[:6]}", "type": "yesno",
                                                "label": {"en": "Road safety certificate", "ar": "Road safety certificate (ar)"},
                                                "details": True})
    r = admin.put("/api/admin/kyc/form", json={"definition": definition, "note": "Road safety certificate"})
    assert r.status_code == 200, r.text
    version = r.json()["version"]
    assert version > active["version"]
    assert carrier.post(f"/api/admin/kyc/form/{version}/activate").status_code == 403
    r = admin.post(f"/api/admin/kyc/form/{version}/activate")
    assert r.status_code == 200, r.text
    form = admin.get("/api/admin/kyc/form").json()
    assert form["active"]["version"] == version and form["draft"] is None
    assert next(v for v in form["versions"] if v["version"] == active["version"])["status"] == "RETIRED"

"""Government bodies (N47) and the vehicle movement code (N48), 1169: a body and its scopes (a second person approves
each), a member who checks at the roadside, the carrier's placard (printed once, revoked with its reason), the scan that
shows the vehicle's movement within the body's scopes, the sample the server draws and the closed check, and the
carrier who sees the checks of its own vehicles."""
import uuid

import pytest

from test_e2e import OWNER_URL, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def setup():
    admin, second = login("admin@masslak.test", "PLATFORM"), login("security@masslak.test", "PLATFORM")
    carrier = login("owner@carrier.test", "OPERATOR")
    code = "GOV-" + uuid.uuid4().hex[:6].upper()
    # a vehicle of the carrier with a published trip that has tickets; the window is widened for the test and put back
    vehicle = owner_sql(
        """SELECT v.uid::text FROM fleet.vehicle v JOIN ops.trip t ON t.vehicle_id = v.id
            WHERE t.status = 'PUBLISHED' AND t.departure_at > now()
              AND v.company_id = (SELECT home_company_id FROM iam.app_user WHERE email = 'owner@carrier.test')
              AND EXISTS (SELECT 1 FROM sales.ticket k WHERE k.trip_id = t.id AND k.status IN ('ISSUED', 'BOARDED'))
            ORDER BY t.departure_at LIMIT 1""")
    assert vehicle, "the demo carrier has a published trip with tickets"
    window = owner_sql("SELECT value::text FROM sys.setting WHERE key = 'roadside.window_minutes'")
    owner_sql("UPDATE sys.setting SET value = '525600'::jsonb WHERE key = 'roadside.window_minutes'")
    yield admin, second, carrier, code, vehicle
    owner_sql("UPDATE sys.setting SET value = $1::jsonb WHERE key = 'roadside.window_minutes'", window or "180")


def test_a_body_sees_only_the_scopes_a_second_person_approved(setup):
    admin, second, _, code, _ = setup
    r = admin.post("/api/admin/authorities", json={"code": code, "kind": "INTERIOR", "name_ar": "\u0627\u0644\u062f\u0627\u062e\u0644\u064a\u0629",
                                                   "name_en": "Interior (test)"})
    assert r.status_code == 201, r.text
    body = next(b for b in admin.get("/api/admin/authorities").json()["bodies"] if b["code"] == code)
    assert {s["category"] for s in body["scopes"]} == {"MANIFEST_VEHICLE", "TRACKING", "MANIFEST_PERSON", "IDENTITY", "MANIFEST_CARGO"}
    assert not any(s["approved"] for s in body["scopes"])                 # the kind's defaults wait for approval
    first = body["scopes"][0]["id"]
    assert admin.post(f"/api/admin/authorities/{code}/scopes/{first}/approve").json()["error"]["code"] == "SCOPE_SAME_PERSON"
    for s in body["scopes"]:
        if s["category"] != "IDENTITY":
            assert second.post(f"/api/admin/authorities/{code}/scopes/{s['id']}/approve").status_code == 200
    assert admin.post(f"/api/admin/authorities/{code}/members", json={"email": "owner@carrier.test"}).json()["error"]["code"] in ("MEMBER_NOT_PLATFORM", "NOT_PLATFORM_STAFF")
    assert admin.post(f"/api/admin/authorities/{code}/members", json={"email": "privacy2@masslak.test"}).status_code == 201
    assert login("regulator@masslak.test", "PLATFORM").get("/api/admin/authorities").status_code == 403


def test_the_carrier_prints_one_placard_and_revokes_it_with_a_reason(setup):
    _, _, carrier, _, vehicle = setup
    current = carrier.get(f"/api/carrier/vehicles/{vehicle}/placard").json()
    if current["placard"]:
        assert carrier.post(f"/api/carrier/vehicles/{vehicle}/placard/revoke", json={"reason": "test run"}).status_code == 200
    r = carrier.post(f"/api/carrier/vehicles/{vehicle}/placard")
    assert r.status_code == 201, r.text
    serial = r.json()["serial"]
    assert carrier.post(f"/api/carrier/vehicles/{vehicle}/placard").json()["error"]["code"] == "PLACARD_IN_FORCE"
    pdf = carrier.get(f"/api/carrier/vehicles/{vehicle}/placard.pdf")
    assert pdf.status_code == 200 and pdf.content[:4] == b"%PDF" and pdf.content.count(b"/Type /Page") >= 2
    assert carrier.get(f"/api/carrier/vehicles/{vehicle}/placard").json()["placard"]["serial"] == serial
    listed = next(v for v in carrier.get("/api/carrier/placards").json()["vehicles"] if v["uid"] == vehicle)
    assert listed["serial"] == serial and listed["revoked"] >= 0
    assert carrier.post(f"/api/carrier/vehicles/{vehicle}/placard/revoke", json={"reason": ""}).status_code == 422
    other = login("passenger@masslak.test", "PASSENGER")
    assert other.post(f"/api/carrier/vehicles/{vehicle}/placard").status_code in (401, 403)


def _code(carrier, vehicle):
    serial = carrier.get(f"/api/carrier/vehicles/{vehicle}/placard").json()["placard"]["serial"]
    import os
    import sys
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
    from app.security import vehicle_code_token
    return vehicle_code_token(vehicle, serial), serial


def test_a_scan_shows_the_movement_and_the_server_draws_the_sample(setup):
    admin, _, carrier, code, vehicle = setup
    token, serial = _code(carrier, vehicle)
    officer = login("privacy2@masslak.test", "INSPECTOR")
    assert officer.post("/api/roadside/scan", json={"code": "MS1-not-a-code"}).json()["error"]["code"] == "CODE_INVALID"
    forged = token[:-3] + ("AAA" if token[-3:] != "AAA" else "BBB")          # well formed, but no placard carries it
    assert officer.post("/api/roadside/scan", json={"code": forged, "body": code}).json()["error"]["code"] == "CODE_UNKNOWN"
    assert officer.post("/api/roadside/scan", json={"code": " " + token.lower() + " ", "body": code}).status_code == 201   # read by hand
    r = officer.post("/api/roadside/scan", json={"code": token, "body": code, "lat": 33.51, "lng": 36.29})
    assert r.status_code == 201, r.text
    scan = r.json()
    assert scan["result"] == "VALID" and scan["body"] == code and scan["vehicle"]["carrier"]
    assert scan["movement"]["kind"] == "SCHEDULED_TRIP" and scan["movement"]["sold"] >= 1 and "cargo" in scan["movement"]
    check = scan["check"]
    sample = officer.post(f"/api/roadside/checks/{check}/sample", json={"mode": "SAMPLE"}).json()
    assert 1 <= len(sample["people"]) <= 3 and sample["people"][0]["name"]          # MANIFEST_PERSON approved
    assert officer.post(f"/api/roadside/checks/{check}/sample", json={"mode": "FULL"}).json()["error"]["code"] == "SAMPLE_DRAWN"
    people = [{"ticket": p["ticket"], "outcome": "CHECKED"} for p in sample["people"]]
    people[0]["outcome"] = "ISSUE"
    assert officer.post(f"/api/roadside/checks/{check}/close", json={"outcome": "CLEAR", "people": people}).json()["error"]["code"] == "OUTCOME_MISMATCH"
    assert officer.post(f"/api/roadside/checks/{check}/close",
                        json={"outcome": "ISSUES", "people": [{"ticket": str(uuid.uuid4()), "outcome": "CHECKED"}]}).json()["error"]["code"] == "NOT_DRAWN"
    r = officer.post(f"/api/roadside/checks/{check}/close", json={"outcome": "ISSUES", "note": "one passenger without an ID", "people": people})
    assert r.status_code == 200, r.text
    assert officer.post(f"/api/roadside/checks/{check}/close", json={"outcome": "CLEAR"}).json()["error"]["code"] == "CHECK_CLOSED"
    mine = officer.get("/api/roadside/checks").json()["checks"]
    assert mine[0]["uid"] == check and mine[0]["outcome"] == "ISSUES" and mine[0]["body"] == code
    # the carrier sees the check of its vehicle, without the officer's account
    seen = next(c for c in carrier.get("/api/carrier/roadside-checks").json()["checks"] if c["uid"] == check)
    assert seen["outcome"] == "ISSUES" and "inspector" not in seen and isinstance(seen["warnings"], list)
    assert any(c["uid"] == check for c in admin.get("/api/admin/authorities/checks").json()["checks"])


def test_a_revoked_placard_answers_revoked_and_a_body_without_scopes_sees_no_movement(setup):
    admin, _, carrier, code, vehicle = setup
    token, serial = _code(carrier, vehicle)
    officer = login("privacy2@masslak.test", "INSPECTOR")
    narrow = "GOV-" + uuid.uuid4().hex[:6].upper()
    admin.post("/api/admin/authorities", json={"code": narrow, "kind": "OTHER", "name_ar": "\u062c\u0647\u0629", "name_en": "No scopes (test)"})
    admin.post(f"/api/admin/authorities/{narrow}/members", json={"email": "privacy2@masslak.test"})
    blind = officer.post("/api/roadside/scan", json={"code": token, "body": narrow}).json()
    assert blind["result"] == "VALID" and blind["movement"] is None and blind["movement_hidden"] is True
    assert officer.post("/api/roadside/scan", json={"code": token}).json()["error"]["code"] == "BODY_REQUIRED"   # two bodies now
    assert carrier.post(f"/api/carrier/vehicles/{vehicle}/placard/revoke", json={"reason": "placard lost"}).status_code == 200
    gone = officer.post("/api/roadside/scan", json={"code": token, "body": code}).json()
    assert gone["result"] == "REVOKED" and gone["warnings"] == ["CODE_REVOKED"] and gone["movement"] is None
    assert carrier.post(f"/api/carrier/vehicles/{vehicle}/placard").json()["serial"] == serial + 1

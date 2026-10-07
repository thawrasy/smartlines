"""Design audit T3 (1048), end to end: file quarantine, report recipients, position evidence, requirement maker-checker."""
import uuid

import pytest

import test_e2e as e2e
from test_documents import upload
from test_e2e import OWNER_URL, login, owner_sql


@pytest.fixture(scope="module")
def carrier():
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


def pdf(extra: bytes = b"") -> bytes:
    return b"%PDF-1.4\n% T3 test\n" + uuid.uuid4().hex.encode() + b"\n" + extra + b"\n%%EOF\n"


# ------------------------------------------------------------------ T3-15 quarantine
@pytest.mark.parametrize("payload, reason", [
    (b"/OpenAction << /S /JavaScript /JS (app.alert(1)) >>", "PDF_ACTIVE_CONTENT"),
    (b"X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*", "EICAR_TEST_SIGNATURE"),
])
@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_a_dangerous_file_is_rejected_and_kept_in_quarantine(carrier, payload, reason):
    r = upload(carrier, data=pdf(payload), name="scan-probe.pdf")
    assert r.status_code == 422 and r.json()["error"]["code"] == "FILE_REJECTED", r.text
    # the upload rolled back: no document points at the file, nothing reached the document list
    assert owner_sql("SELECT count(*) FROM iam.document d JOIN ref.file_object f ON f.id = d.file_id WHERE f.scan_detail = $1", reason) == 0


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_a_file_waiting_for_its_scan_is_not_served_or_approved(carrier, admin):
    r = upload(carrier, data=pdf(), name="pending.pdf")
    assert r.status_code == 201, r.text
    doc = r.json()["uid"]
    assert owner_sql("""SELECT f.scan_status FROM iam.document d JOIN ref.file_object f ON f.id = d.file_id WHERE d.uid = $1""",
                     uuid.UUID(doc)) == "CLEAN"
    # put it back in quarantine, as when the scanner is down
    owner_sql(f"""DO $$ BEGIN PERFORM set_config('app.scope', 'SYSTEM', true);
                  UPDATE ref.file_object f SET scan_status = 'PENDING', scanned_at = NULL, scan_engine = NULL
                    FROM iam.document d WHERE d.file_id = f.id AND d.uid = '{uuid.UUID(doc)}'; END $$""")
    r = carrier.get(f"/api/company/documents/{doc}/file")
    assert r.status_code == 409 and r.json()["error"]["code"] == "FILE_NOT_CLEAN"
    r = admin.post(f"/api/admin/documents/{doc}/decision", json={"decision": "APPROVE"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "FILE_NOT_CLEAN"
    # the worker's retry scans it again and releases it
    import asyncio
    from app import db
    from app.modules.documents import scanner

    async def retry():
        await db.open_pools()
        try:
            return await scanner.scan_pending()
        finally:
            await db.close_pools()
    assert asyncio.run(retry()) >= 1
    assert carrier.get(f"/api/company/documents/{doc}/file").status_code == 200


# ------------------------------------------------------------------ T3-05 recipients
def test_a_report_goes_only_to_approved_recipients(carrier, admin):
    body = {"code": "sales.daily", "frequency": "WEEKLY", "format": "CSV"}
    r = carrier.post("/api/reports/schedules", json={**body, "recipients": ["someone@outside.example"]})
    assert r.status_code == 422 and r.json()["error"]["code"] == "REPORT_RECIPIENT_NOT_ALLOWED"
    assert r.json()["error"]["recipients"] == ["someone@outside.example"]
    # the platform may send to its own mail domain (setting reports.platform_recipient_domains), not elsewhere
    r = admin.post("/api/reports/schedules", json={**body, "recipients": ["ops@masslak.com", "someone@outside.example"]})
    assert r.status_code == 422 and r.json()["error"]["recipients"] == ["someone@outside.example"]
    r = admin.post("/api/reports/schedules", json={**body, "recipients": ["ops@masslak.com"]})
    assert r.status_code == 201, r.text
    assert admin.delete(f"/api/reports/schedules/{r.json()['uid']}").status_code == 200


# ------------------------------------------------------------------ T3-11 position evidence
def test_positions_carry_evidence_and_duplicates_are_ignored():
    e2e.publish_fresh_trip()
    d = login(e2e.FRESH_DRIVERS[-1], "DRIVER", e2e.FRESH_DRIVER_PASSWORD)
    trip = d.get("/api/driver/trips").json()["trips"][-1]["uid"]
    ev = str(uuid.uuid4())
    point = {"trip_uid": trip, "lat": 33.51, "lng": 36.29, "accuracy_m": 6, "event_id": ev, "seq": 1, "provider": "GPS"}
    first = d.post("/api/driver/location", json=point)
    assert first.status_code == 200 and first.json()["trust"] == "HIGH", first.text
    again = d.post("/api/driver/location", json=point)
    assert again.status_code == 200 and again.json().get("duplicate") is True
    mock = d.post("/api/driver/location", json={**point, "event_id": str(uuid.uuid4()), "seq": 2, "is_mock": True})
    assert mock.json()["trust"] == "REJECTED" and "MOCK_LOCATION" in mock.json()["flags"]


# ------------------------------------------------------------------ T3-14 requirement maker-checker
@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_a_requirement_change_needs_a_second_platform_user(admin):
    code = "license.vehicle.inspection"
    r = admin.post(f"/api/admin/compliance/requirements/{code}/changes",
                   json={"level": "REQUIRED", "reason": "Inspection certificates become mandatory by decree"})
    assert r.status_code == 201, r.text
    change = r.json()["uid"]
    assert "would_be_blocked" in r.json()["impact"]
    r = admin.post(f"/api/admin/compliance/changes/{change}/decision", json={"approve": True})
    assert r.status_code == 409 and r.json()["error"]["code"] == "REQUIREMENT_SELF_APPROVAL"
    level = owner_sql("SELECT level FROM sys.compliance_requirement WHERE code = $1", code)
    assert level == "OPTIONAL"
    # a second administrator decides; here they reject it, so the requirement stays as it was
    owner_sql("""INSERT INTO iam.user_role (user_id, role_id) SELECT u.id, r.id FROM iam.app_user u, iam.role r
                  WHERE u.email = 'security@masslak.test' AND r.code = 'PLATFORM_ADMIN' ON CONFLICT DO NOTHING""")
    second = login("security@masslak.test", "PLATFORM")
    r = second.post(f"/api/admin/compliance/changes/{change}/decision", json={"approve": False, "note": "Decree not published yet"})
    assert r.status_code == 200 and r.json()["status"] == "REJECTED"
    listed = next(c for c in admin.get("/api/admin/compliance/requirements").json()["changes"] if c["uid"] == change)
    assert listed["status"] == "REJECTED" and listed["decided_by"] == "security@masslak.test"
    assert owner_sql("SELECT level FROM sys.compliance_requirement WHERE code = $1", code) == "OPTIONAL"

"""Documents end to end: type detection from content, size limit, encryption at rest, company isolation, logged
staff access and platform review."""
import os
import uuid
from datetime import date, timedelta
from pathlib import Path

import pytest

from test_e2e import OWNER_URL, login, owner_sql

PDF = b"%PDF-1.4\n% Masslak test document\n" + uuid.uuid4().hex.encode() + b"\n%%EOF\n"
NEXT_YEAR = (date.today() + timedelta(days=365)).isoformat()


@pytest.fixture(scope="module")
def carrier():
    return login("owner@carrier.test", "OPERATOR")


def upload(c, data=PDF, name="licence.pdf", **form):
    fields = {"doc_type": "TRANSPORT_LICENSE", "issuer": "Ministry of Transport", "expiry_date": NEXT_YEAR, **form}
    return c.post("/api/company/documents", data=fields, files={"file": (name, data, "application/pdf")})


def test_content_type_is_detected_not_trusted(carrier):
    r = upload(carrier, b"<html><script>alert(1)</script></html>", name="looks-like.pdf")
    assert r.status_code == 422 and r.json()["error"]["code"] == "FILE_TYPE"
    r = upload(carrier, b"%PDF-" + b"0" * (4 * 1024 * 1024))
    assert r.status_code == 422 and r.json()["error"]["code"] == "FILE_TOO_LARGE"
    r = upload(carrier, expiry_date=(date.today() - timedelta(days=1)).isoformat())
    assert r.status_code == 422 and r.json()["error"]["code"] == "DOCUMENT_EXPIRED"


@pytest.fixture(scope="module")
def doc(carrier):
    r = upload(carrier, name="../../etc/passwd licence.pdf")
    assert r.status_code == 201, r.text
    return r.json()["uid"]


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_file_is_encrypted_at_rest_and_named_safely(doc):
    row = owner_sql("""SELECT f.storage_key, f.file_name, f.mime_type FROM iam.document d JOIN ref.file_object f ON f.id = d.file_id
                        WHERE d.uid = $1""", uuid.UUID(doc), fetch=True)
    assert row["mime_type"] == "application/pdf" and "/" not in row["file_name"] and ".." not in row["storage_key"]
    if os.environ.get("MASSLAK_FILES_BACKEND") == "s3":       # the API runs on the object store (CI, code review 3.2)
        from app.modules.documents import storage
        store = storage.s3_from_settings()
        stored = store.read(row["storage_key"])
        assert store._request("HEAD", row["storage_key"])[1]["x-amz-server-side-encryption"] == "AES256"
    else:
        stored = (Path(__file__).resolve().parents[1] / "../data/files" / row["storage_key"]).read_bytes()
    assert PDF not in stored and b"Masslak test document" not in stored and stored[:1] == b"\x01"


def test_owner_reads_the_file_but_other_companies_cannot(carrier, doc):
    listed = next(d for d in carrier.get("/api/company/documents").json()["documents"] if d["uid"] == doc)
    assert listed["status"] == "PENDING" and listed["days_left"] >= 364
    r = carrier.get(f"/api/company/documents/{doc}/file")
    assert r.status_code == 200 and r.content == PDF
    assert r.headers["content-disposition"].startswith("attachment") and r.headers["x-content-type-options"] == "nosniff"
    agency = login("agency@agency.test", "AGENCY")
    assert agency.get(f"/api/company/documents/{doc}/file").status_code == 404
    assert all(d["uid"] != doc for d in agency.get("/api/company/documents").json()["documents"])
    vehicle = carrier.get("/api/carrier/vehicles").json()["vehicles"][0]["uid"]
    assert upload(agency, doc_type="VEHICLE_REG", vehicle_uid=vehicle).status_code == 404


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_platform_review_is_logged_and_final(carrier, doc):
    admin = login("admin@masslak.test", "PLATFORM")
    assert any(d["uid"] == doc for d in admin.get("/api/admin/documents").json()["documents"])
    assert admin.get(f"/api/admin/documents/{doc}/file").content == PDF
    logged = owner_sql("""SELECT count(*) FROM audit.data_access_log l JOIN iam.document d ON d.id = l.object_id
                           WHERE l.object_type = 'document' AND d.uid = $1""", uuid.UUID(doc))
    assert logged >= 1
    r = admin.post(f"/api/admin/documents/{doc}/decision", json={"decision": "REJECT"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "REASON_REQUIRED"
    assert admin.post(f"/api/admin/documents/{doc}/decision", json={"decision": "APPROVE"}).status_code == 200
    assert admin.post(f"/api/admin/documents/{doc}/decision", json={"decision": "REJECT", "note": "late"}).status_code == 409
    listed = next(d for d in carrier.get("/api/company/documents").json()["documents"] if d["uid"] == doc)
    assert listed["status"] == "APPROVED"
    assert carrier.post(f"/api/admin/documents/{doc}/decision", json={"decision": "APPROVE"}).status_code == 403


def test_reading_documents_takes_the_permission_that_files_them(doc):
    """R-25: a counter clerk of the same company, and a platform account that does not review companies, read nothing."""
    clerk = login("counter@carrier.test", "OPERATOR")
    for path in ("/api/company/documents", f"/api/company/documents/{doc}/file"):
        r = clerk.get(path)
        assert r.status_code == 403 and r.json()["error"]["code"] == "FORBIDDEN", (path, r.text)
    finance = login("finance@masslak.test", "PLATFORM")
    for path in ("/api/admin/documents", f"/api/admin/documents/{doc}/file"):
        assert finance.get(path).status_code == 403, path

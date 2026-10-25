"""Driver and crew details (owner's request N3, migration 1158): names in parts, an encrypted national number, licences
with class, dates and pictures, and the platform's switches on missing or expired licences."""
import json
import uuid
from datetime import date, timedelta

import pytest

from test_e2e import OWNER_URL, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
PNG = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
       b"\x00\x00\x00\rIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82")


@pytest.fixture(scope="module")
def carrier():
    return login("owner@carrier.test", "OPERATOR")


def national() -> str:
    return "0" + str(uuid.uuid4().int)[:10]


def test_a_host_is_entered_with_name_parts_and_an_encrypted_national_number(carrier):
    nid = national()
    r = carrier.post("/api/carrier/crew", json={"crew_type": "HOST", "first_name": "Rami", "father_name": "Adel", "last_name": "Haddad",
                                                "national_id": nid})
    assert r.status_code == 201 and r.json()["sign_in"] is None, r.text          # a host without a sign-in
    uid = r.json()["uid"]
    row = next(c for c in carrier.get("/api/carrier/crew").json()["crew"] if c["uid"] == uid)
    assert row["full_name"] == "Rami Adel Haddad" and row["crew_type"] == "HOST" and row["id_no_last4"] == nid[-4:]
    assert row["problems"] == []                                                # hosts need no licence by default
    stored = owner_sql("SELECT id_no_enc FROM iam.party WHERE uid = $1", uuid.UUID(uid))
    assert nid.encode() not in stored
    again = carrier.post("/api/carrier/crew", json={"crew_type": "ASSISTANT", "first_name": "Other", "last_name": "Person", "national_id": nid})
    assert again.status_code == 409 and again.json()["error"]["code"] == "DOCUMENT_IN_USE"
    bad = carrier.post("/api/carrier/crew", json={"crew_type": "DRIVER", "first_name": "No", "last_name": "Account"})
    assert bad.status_code == 422                                                # a driver needs a sign-in


def test_a_driver_licence_with_its_class_and_pictures_and_the_switches(carrier):
    email = f"crew{uuid.uuid4().hex[:8]}@example.com"
    r = carrier.post("/api/carrier/crew", json={"crew_type": "DRIVER", "first_name": "Samer", "father_name": "Nabil", "last_name": "Kassem",
                                                "national_id": national(), "email": email, "password": "Harbour-Lantern-Window-73"})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    row = next(c for c in carrier.get("/api/carrier/crew").json()["crew"] if c["uid"] == uid)
    assert row["problems"] == ["MISSING:DRIVING"]
    today = date.today()
    lic = carrier.post(f"/api/carrier/crew/{uid}/licences", json={
        "license_type": "DRIVING", "license_no": "DL-" + uuid.uuid4().hex[:6], "issuer": "Damascus traffic department",
        "license_class": "d", "issue_date": str(today - timedelta(days=400)), "expiry_date": str(today + timedelta(days=30))})
    assert lic.status_code == 201, lic.text
    lid = lic.json()["uid"]
    up = carrier.post(f"/api/carrier/crew/{uid}/licences/{lid}/images/front", files={"file": ("front.png", PNG, "image/png")})
    assert up.status_code == 201, up.text
    d = carrier.get(f"/api/carrier/crew/{uid}").json()
    got = d["licences"][0]
    assert got["license_class"] == "D" and got["front_uid"] == up.json()["uid"] and got["back_uid"] is None and d["problems"] == []
    # an expired transport licence, once required, shows; refusing it on a trip follows the platform's switch
    carrier.post(f"/api/carrier/crew/{uid}/licences", json={
        "license_type": "TRANSPORT", "license_no": "TA-" + uuid.uuid4().hex[:6], "issuer": "Transport authority",
        "issue_date": str(today - timedelta(days=800)), "expiry_date": str(today - timedelta(days=5))})
    before = owner_sql("SELECT value::text FROM sys.setting WHERE key = 'crew.licences'")
    conf = json.loads(before)
    conf["required"]["DRIVER"] = ["DRIVING", "TRANSPORT"]
    owner_sql("UPDATE sys.setting SET value = $1::jsonb WHERE key = 'crew.licences'", json.dumps(conf))
    try:
        assert carrier.get(f"/api/carrier/crew/{uid}").json()["problems"] == ["EXPIRED:TRANSPORT"]
        party = owner_sql("SELECT id FROM iam.party WHERE uid = $1", uuid.UUID(uid))
        problems = owner_sql("SELECT fleet.crew_licence_problems($1, current_date)", party)
        assert list(problems) == ["EXPIRED:TRANSPORT"]
    finally:
        owner_sql("UPDATE sys.setting SET value = $1::jsonb WHERE key = 'crew.licences'", before)
    bad = carrier.post(f"/api/carrier/crew/{uid}/licences", json={
        "license_type": "DRIVING", "license_no": "DL-X1", "issuer": "X", "issue_date": str(today), "expiry_date": str(today - timedelta(days=1))})
    assert bad.status_code == 422
    other = login("agency@agency.test", "AGENCY")
    assert other.get(f"/api/carrier/crew/{uid}").status_code in (403, 404)

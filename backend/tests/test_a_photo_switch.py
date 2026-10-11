"""The boarding photo is off at launch and is switched on only by an approved change with a legal basis (migration 1094).

The name of this file sorts before the other test modules, so the first test sees the fresh database the suite seeds.
"""
import pytest

from test_boarding_photo import JPEG, SWITCH_ADMIN, SWITCH_CHECKER, SWITCH_FINAL, register, upload
from test_e2e import login


def test_the_boarding_photo_is_off_on_a_fresh_database():
    admin = login(*SWITCH_ADMIN)
    if admin.get("/api/admin/photos/evidence-kinds").json()["enabled"]:
        pytest.skip("the switch is already on: this check needs a fresh database")
    _, c = register()
    r = upload(c, JPEG)
    assert r.status_code == 409 and r.json()["error"]["code"] == "PHOTO_DISABLED", r.text
    assert c.get("/api/account/photo").json()["has_photo"] is False


def test_a_switch_without_a_legal_basis_is_refused():
    admin = login(*SWITCH_ADMIN)
    short = admin.post("/api/admin/photos/feature/changes",
                       json={"enabled": True, "legal_basis": "short", "reason": "test of the switch (1094)"})
    assert short.status_code == 422, short.text
    missing = admin.post("/api/admin/photos/feature/changes", json={"enabled": True, "reason": "test of the switch (1094)"})
    assert missing.status_code == 422, missing.text


def test_the_switch_passes_its_stages_and_then_takes_effect():
    admin = login(*SWITCH_ADMIN)
    if admin.get("/api/admin/photos/evidence-kinds").json()["enabled"]:
        pytest.skip("the switch is already on: this check needs a fresh database")
    r = admin.post("/api/admin/photos/feature/changes", json={
        "enabled": True, "legal_basis": "test: a decision of the owner with a legal basis (1094)",
        "reason": "test of the switch and its stages (1094)"})
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    uid = r.json()["uid"]
    assert login(*SWITCH_CHECKER).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "PENDING"
    assert admin.get("/api/admin/photos/evidence-kinds").json()["enabled"] is False     # not before the last approval
    assert login(*SWITCH_FINAL).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "APPLIED"
    assert admin.get("/api/admin/photos/evidence-kinds").json()["enabled"] is True
    _, c = register()
    r = upload(c, JPEG)
    assert r.status_code == 201 and r.json() == {"taken_by": "SELF"}, r.text

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


PRIVACY = ("privacy@masslak.test", "PLATFORM")
DEFAULT_STAGES = ["CHECK", "APPROVE"]


def stages_of(admin):
    return admin.get("/api/admin/photos/evidence-kinds").json()["approval_stages"]


def set_stages(admin, stages):
    return admin.put("/api/admin/photos/settings/approval-stages", json={"stages": stages})


def change_row(admin, uid):
    return next(c for c in admin.get("/api/admin/photos/policy-changes").json()["changes"] if c["uid"] == uid)


def test_the_approval_stages_are_a_setting_and_no_stage_is_forced():
    admin = login(*SWITCH_ADMIN)
    assert stages_of(admin) == DEFAULT_STAGES                  # the default: the checker and the final approval
    for bad in (["APPROVE"], ["APPROVE", "CHECK"], ["CHECK", "SOMETHING"], ["CHECK", "THIRD_PARTY_CHECK"]):
        assert set_stages(admin, bad).status_code == 422, bad
    assert stages_of(admin) == DEFAULT_STAGES                  # a refused change leaves the setting as it was
    three = ["CHECK", "THIRD_PARTY_CHECK", "APPROVE"]
    try:
        assert set_stages(admin, three).json() == {"approval_stages": three}
        assert stages_of(admin) == three
    finally:
        assert set_stages(admin, DEFAULT_STAGES).status_code == 200
    assert stages_of(admin) == DEFAULT_STAGES


def test_a_change_asked_keeps_the_stages_it_was_asked_with():
    admin = login(*SWITCH_ADMIN)
    try:
        assert set_stages(admin, ["CHECK", "THIRD_PARTY_CHECK", "APPROVE"]).status_code == 200
        r = admin.post("/api/admin/photos/identity-age/changes", json={"min_age": 18, "reason": "test of the stages (1095)"})
        assert r.status_code == 201, r.text
        uid = r.json()["uid"]
        assert change_row(admin, uid)["stages"] == ["CHECK", "THIRD_PARTY_CHECK", "APPROVE"]
    finally:
        assert set_stages(admin, DEFAULT_STAGES).status_code == 200
    # the change still passes its own three stages: checker, third party, final approval
    assert login(*SWITCH_CHECKER).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "PENDING"
    assert login(*PRIVACY).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "PENDING"
    assert login(*SWITCH_FINAL).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "APPLIED"


def test_the_legal_document_number_is_optional_and_recorded_with_the_approval():
    admin = login(*SWITCH_ADMIN)
    r = admin.post("/api/admin/photos/identity-age/changes", json={"min_age": 18, "reason": "test of the document number (1095)"})
    uid = r.json()["uid"]
    assert login(*SWITCH_CHECKER).post(f"/api/admin/photos/policy-changes/{uid}/approve",
                                       json={"document_no": "DOC-2026-0001"}).json()["status"] == "PENDING"
    assert change_row(admin, uid)["legal_document_no"] == "DOC-2026-0001"     # recorded with the first approval
    assert login(*SWITCH_FINAL).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "APPLIED"
    # without a number, the approval is the same
    r = admin.post("/api/admin/photos/identity-age/changes", json={"min_age": 18, "reason": "test without a number (1095)"})
    uid = r.json()["uid"]
    assert login(*SWITCH_CHECKER).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "PENDING"
    assert login(*SWITCH_FINAL).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "APPLIED"
    assert change_row(admin, uid)["legal_document_no"] is None

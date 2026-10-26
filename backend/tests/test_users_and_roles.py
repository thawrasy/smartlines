"""Users and roles in every portal (owner's request N1, migration 1154): ready roles, roles defined from what the
administrator holds, users given roles, and per-user exceptions approved by a second person."""
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from test_e2e import OWNER_URL, PASSWORD, login, owner_sql, settle_password

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
NEW_PASSWORD = "Harbour-Lantern-Window-73"


def ready(email: str) -> None:
    """A member of staff made by a test signs in with the test's password and without enrolling a second factor here."""
    settle_password(email)
    owner_sql("UPDATE iam.app_user SET mfa_required = false WHERE email = $1", email)


def until(days: int) -> str:
    return (datetime.now(timezone.utc) + timedelta(days=days)).isoformat()


def role_uid(c, code: str) -> str:
    return next(r["uid"] for r in c.get("/api/people/roles").json()["roles"] if r["code"] == code)


def add_staff(c, roles: list[str]) -> tuple[str, str]:
    email = f"staff{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/api/people/users", json={"full_name": "Staff Member", "email": email, "password": NEW_PASSWORD, "roles": roles})
    assert r.status_code == 201, r.text
    assert r.json()["sign_in"]["username"]
    ready(email)
    return email, r.json()["uid"]


def test_platform_roles_hold_only_what_the_administrator_holds():
    admin = login("admin@masslak.test", "PLATFORM")
    cat = admin.get("/api/people/catalog").json()
    assert cat["kind"] == "PLATFORM"
    mine = {p["code"] for p in cat["permissions"] if p["grantable"]}
    assert "users.manage" in mine and "campaign.manage" not in mine      # marketing's, not the administrator's
    codes = {r["code"] for r in admin.get("/api/people/roles").json()["roles"]}
    assert {"PLATFORM_OPERATIONS", "PLATFORM_FINANCE", "PLATFORM_SECURITY", "PLATFORM_SUPPORT", "PLATFORM_COMPLIANCE",
            "PLATFORM_READONLY"} <= codes

    r = admin.post("/api/people/roles", json={"name": "Night desk", "permissions": ["report.platform", "campaign.manage"]})
    assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_HELD", r.text
    r = admin.post("/api/people/roles", json={"name": "Night desk", "permissions": ["report.platform", "trip.search"]})
    assert r.status_code == 201 and r.json()["editable"] is True, r.text
    night = r.json()["uid"]
    # a ready role is never edited; one of the platform's own is
    r = admin.put(f"/api/people/roles/{role_uid(admin, 'PLATFORM_READONLY')}",
                  json={"name": "Read only", "permissions": ["report.platform"], "status": "ACTIVE"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "READY_ROLE"
    r = admin.put(f"/api/people/roles/{night}", json={"name": "Night desk", "permissions": ["report.platform"], "status": "ACTIVE"})
    assert r.status_code == 200 and r.json()["permissions"] == ["report.platform"]

    # marketing's role holds what the administrator lacks: it cannot be given by them
    r = admin.post("/api/people/users", json={"full_name": "Staff Member", "email": f"x{uuid.uuid4().hex[:8]}@example.com",
                                             "password": NEW_PASSWORD, "roles": [role_uid(admin, "PLATFORM_MARKETING")]})
    assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_HELD"
    email, _ = add_staff(admin, [night])
    staff = login(email, "PLATFORM", NEW_PASSWORD)
    me = staff.get("/api/auth/me").json()
    assert "report.platform" in me["permissions"] and "users.manage" not in me["permissions"]
    assert staff.get("/api/people/users").status_code == 403


def test_an_exception_works_only_after_a_second_administrator_approves_and_ends_on_its_date():
    admin = login("admin@masslak.test", "PLATFORM")
    target_email, target = add_staff(admin, [role_uid(admin, "PLATFORM_READONLY")])
    second_email, _ = add_staff(admin, [role_uid(admin, "PLATFORM_USERS")])
    second = login(second_email, "PLATFORM", NEW_PASSWORD)

    r = admin.post(f"/api/people/users/{target}/exceptions",
                   json={"permission": "report.platform", "effect": "DENY", "valid_to": until(7), "reason": "audit of report access"})
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    deny = r.json()["uid"]
    again = admin.post(f"/api/people/users/{target}/exceptions",
                       json={"permission": "report.platform", "effect": "DENY", "valid_to": until(7), "reason": "asked twice"})
    assert again.status_code == 409 and again.json()["error"]["code"] == "EXCEPTION_OPEN"
    staff = login(target_email, "PLATFORM", NEW_PASSWORD)
    assert "report.platform" in staff.get("/api/auth/me").json()["permissions"]          # pending: nothing changes yet

    own = admin.post(f"/api/people/exceptions/{deny}/approve", json={})
    assert own.status_code == 409 and own.json()["error"]["code"] == "FOUR_EYES"
    assert second.post(f"/api/people/exceptions/{deny}/approve", json={}).json()["status"] == "ACTIVE"
    assert "report.platform" not in staff.get("/api/auth/me").json()["permissions"]

    # granting needs the permission on both sides: the second administrator does not hold trip.search
    r = admin.post(f"/api/people/users/{target}/exceptions",
                   json={"permission": "trip.search", "effect": "GRANT", "valid_to": until(3), "reason": "covers the support desk"})
    grant = r.json()["uid"]
    r = second.post(f"/api/people/exceptions/{grant}/approve", json={})
    assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_HELD"
    assert second.post(f"/api/people/exceptions/{grant}/reject", json={"note": "ask support"}).json()["status"] == "REJECTED"

    assert admin.post(f"/api/people/exceptions/{deny}/revoke", json={}).json()["status"] == "REVOKED"
    assert "report.platform" in staff.get("/api/auth/me").json()["permissions"]
    r = admin.post(f"/api/people/users/{target}/exceptions",
                   json={"permission": "report.platform", "effect": "DENY", "valid_to": until(400), "reason": "too long"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "INVALID_WINDOW"
    # what was decided is never rewritten
    assert owner_sql("SELECT status FROM iam.permission_exception WHERE uid = $1", uuid.UUID(deny)) == "REVOKED"


def test_a_carrier_manages_its_own_people_with_one_role_each_and_cannot_touch_its_owner():
    owner = login("owner@carrier.test", "OPERATOR")
    roles = owner.get("/api/people/roles").json()["roles"]
    codes = {r["code"] for r in roles}
    assert {"CARRIER_OPERATIONS", "CARRIER_SUPPORT", "CARRIER_READONLY", "CARRIER_ADMIN"} <= codes
    assert not codes & {"AGENCY_SELLER", "STATION_COUNTER", "PLATFORM_ADMIN"}
    r = owner.post("/api/people/users", json={"full_name": "Staff Member", "email": f"x{uuid.uuid4().hex[:8]}@example.com",
                                             "password": NEW_PASSWORD, "roles": [role_uid(owner, "CARRIER_SUPPORT"), role_uid(owner, "CARRIER_READONLY")]})
    assert r.status_code == 422 and r.json()["error"]["code"] == "ONE_ROLE"
    admin_email, admin_uid = add_staff(owner, [role_uid(owner, "CARRIER_ADMIN")])
    company_admin = login(admin_email, "OPERATOR", NEW_PASSWORD)
    # the company's administrator holds company.staff, report.company and the login log: operations is not theirs to give
    r = company_admin.post("/api/people/users", json={"full_name": "Staff Member", "email": f"y{uuid.uuid4().hex[:8]}@example.com",
                                                     "password": NEW_PASSWORD, "roles": [role_uid(owner, "CARRIER_OPERATIONS")]})
    assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_HELD"
    users = company_admin.get("/api/people/users").json()["users"]
    boss = next(u for u in users if u["is_owner"])
    r = company_admin.put(f"/api/people/users/{boss['uid']}", json={"status": "DISABLED"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "OWNER"
    r = company_admin.put(f"/api/people/users/{admin_uid}", json={"status": "DISABLED"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "NOT_YOURSELF"
    # a role the company defines is its own and not seen by another company
    r = owner.post("/api/people/roles", json={"name": "Weekend dispatch", "permissions": ["trip.search", "manifest.view"]})
    assert r.status_code == 201
    disabled_email, disabled = add_staff(owner, [r.json()["uid"]])
    member = login(disabled_email, "OPERATOR", NEW_PASSWORD)
    assert owner.put(f"/api/people/users/{disabled}", json={"status": "DISABLED"}).status_code == 200
    assert member.get("/api/auth/me").status_code == 401                       # the open session ended at once
    agency = login("agency@agency.test", "AGENCY")
    assert "Weekend dispatch" not in {x["name"] for x in agency.get("/api/people/roles").json()["roles"]}


def test_staff_without_the_right_do_not_reach_the_section():
    assert login("passenger@masslak.test", "PASSENGER").get("/api/people/users").status_code == 403
    counter = login("counter@carrier.test", "OPERATOR")
    assert counter.get("/api/people/roles").status_code == 403
    assert PASSWORD

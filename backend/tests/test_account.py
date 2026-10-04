"""Account self-service: sessions and remote sign-out, password change, voluntary two-step sign-in for passengers,
consents, data export and erasure."""
import uuid

import pytest

from app import mfa
from test_e2e import OWNER_URL, client, login, owner_sql


def register() -> tuple[str, str]:
    email, password = f"u{uuid.uuid4().hex[:8]}@example.com", "first-long-password"
    assert client().post("/api/auth/register", json={"full_name": "Account Tester", "email": email, "password": password}).status_code == 201
    return email, password


def sign_in(email, password):
    c = client()
    r = c.post("/api/auth/login", json={"identifier": email, "password": password, "portal": "PASSENGER"})
    return c, r


def test_sessions_and_password_change():
    email, password = register()
    a, _ = sign_in(email, password)
    b, _ = sign_in(email, password)
    sec = a.get("/api/account/security").json()
    assert len(sec["sessions"]) == 2 and sum(s["current"] for s in sec["sessions"]) == 1
    assert a.post("/api/account/sessions/revoke-others").json()["revoked"] == 1
    assert b.get("/api/account/security").status_code == 401                  # the other device is signed out

    bad = a.post("/api/account/password", json={"current_password": "wrong-password-x", "new_password": "second-long-password"})
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "PASSWORD_WRONG"
    weak = a.post("/api/account/password", json={"current_password": password, "new_password": "short"})
    assert weak.status_code == 422 and weak.json()["error"]["code"] == "PASSWORD_TOO_SHORT"
    assert a.post("/api/account/password", json={"current_password": password, "new_password": "second-long-password"}).status_code == 200
    assert sign_in(email, password)[1].status_code == 401
    assert sign_in(email, "second-long-password")[1].status_code == 200
    events = [e["event"] for e in a.get("/api/account/security").json()["events"]]
    assert "PASSWORD_CHANGED" in events and "SESSION_REVOKED" in events


def test_passenger_can_opt_in_to_two_step_sign_in():
    email, password = register()
    c, r = sign_in(email, password)
    assert r.json()["mfa"] is None
    secret = c.post("/api/auth/mfa/enroll").json()["secret"]
    r = c.post("/api/auth/mfa/confirm", json={"code": mfa.code_at(secret, mfa.current_step())})
    assert r.status_code == 200 and len(r.json()["recovery_codes"]) == 10
    d, r = sign_in(email, password)
    assert r.json()["mfa"] == "VERIFY"                                        # once enrolled, always asked
    assert d.get("/api/bookings").json()["error"]["code"] == "MFA_REQUIRED"


def test_consents_and_export():
    email, password = register()
    c, _ = sign_in(email, password)
    assert all(not x["granted"] for x in c.get("/api/account/consents").json()["consents"])
    assert c.post("/api/account/consents", json={"purpose": "MARKETING", "granted": True}).status_code == 200
    assert c.post("/api/account/consents", json={"purpose": "BIOMETRICS", "granted": True}).status_code == 422
    marketing = next(x for x in c.get("/api/account/consents").json()["consents"] if x["purpose"] == "MARKETING")
    assert marketing["granted"] is True
    r = c.get("/api/account/export")
    assert r.status_code == 200 and r.headers["content-disposition"].startswith("attachment")
    data = r.json()
    assert data["profile"]["email"] == email and any(e["event"] == "LOGIN_SUCCESS" for e in data["sign_ins"])
    assert any(x["kind"] == "ACCESS" and x["status"] == "DONE" for x in c.get("/api/account/requests").json()["requests"])


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_erasure_anonymises_the_account():
    email, password = register()
    c, _ = sign_in(email, password)
    assert c.post("/api/account/erasure", json={"reason": "leaving"}).status_code == 201
    again = c.post("/api/account/erasure", json={})
    assert again.status_code == 409 and again.json()["error"]["code"] == "REQUEST_OPEN"
    admin = login("admin@masslak.test", "PLATFORM")
    req = next(r for r in admin.get("/api/admin/privacy/requests").json()["requests"] if r["email"] == email)
    assert admin.post(f"/api/admin/privacy/requests/{req['uid']}/complete").status_code == 200
    assert sign_in(email, password)[1].status_code == 401
    assert c.get("/api/account/security").status_code == 401
    row = owner_sql("""SELECT u.status, u.email LIKE 'erased-%' AS hidden, p.legal_name FROM iam.app_user u
                         JOIN iam.party p ON p.id = u.party_id JOIN gov.subject_request r ON r.user_id = u.id
                        WHERE r.uid = $1""", uuid.UUID(req["uid"]), fetch=True)
    assert row["status"] == "CLOSED" and row["hidden"] and row["legal_name"] == "Erased user"
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.get("/api/admin/privacy/requests").status_code == 403

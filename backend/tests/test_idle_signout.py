"""Idle sign-out (owner's note, October 2026; migration 1146): a session left without activity past its portal's period
(auth.idle, set by the security officers) ends at its next request with SESSION_IDLE; a request a screen sends by
itself does not count as activity; the period is a platform setting changed with the decision behind it."""
import pytest

from test_e2e import OWNER_URL, login, new_passenger, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to age a session")

LATEST = "SELECT id FROM iam.user_session WHERE user_id = (SELECT id FROM iam.app_user WHERE email = $1) ORDER BY id DESC LIMIT 1"


def _age(session_id: int, minutes: int) -> None:
    owner_sql("UPDATE iam.user_session SET last_seen_at = now() - make_interval(mins => $2) WHERE id = $1", session_id, minutes)


def test_an_idle_session_ends_and_says_why():
    pax = new_passenger()
    me = pax.get("/api/auth/me").json()
    assert me["idle_minutes"] == 60
    sid = owner_sql(LATEST, me["email"])
    _age(sid, 59)
    assert pax.get("/api/auth/me").status_code == 200              # still within the hour, and the request counts
    _age(sid, 61)
    r = pax.get("/api/auth/me")
    assert r.status_code == 401 and r.json()["error"]["code"] == "SESSION_IDLE", r.text
    assert owner_sql("SELECT revoke_reason FROM iam.user_session WHERE id = $1", sid) == "idle"
    assert pax.get("/api/auth/me").json()["error"]["code"] == "SESSION_IDLE"    # and keeps saying so


def test_a_background_request_is_not_activity():
    pax = new_passenger()
    sid = owner_sql(LATEST, pax.get("/api/auth/me").json()["email"])
    _age(sid, 30)
    assert pax.get("/api/notifications", headers={"X-Masslak-Background": "1"}).status_code == 200
    assert owner_sql("SELECT last_seen_at < now() - interval '29 minutes' FROM iam.user_session WHERE id = $1", sid) is True
    assert pax.get("/api/auth/me").status_code == 200
    assert owner_sql("SELECT last_seen_at > now() - interval '1 minute' FROM iam.user_session WHERE id = $1", sid) is True


def test_the_security_officers_set_the_period():
    admin = login("admin@masslak.test", "PLATFORM")
    before = admin.get("/api/security/idle-policy")
    assert before.status_code == 200 and before.json()["minutes"]["PLATFORM"] == 15, before.text
    minutes = dict(before.json()["minutes"])
    try:
        r = admin.put("/api/security/idle-policy", json={"minutes": {**minutes, "PASSENGER": 3}, "reason": "too short"})
        assert r.status_code == 422 and r.json()["error"]["code"] == "INVALID_SETTING", r.text
        r = admin.put("/api/security/idle-policy", json={"minutes": {**minutes, "PASSENGER": 20}, "reason": "Security review 3/2026"})
        assert r.status_code == 200 and r.json()["minutes"]["PASSENGER"] == 20, r.text
        assert new_passenger().get("/api/auth/me").json()["idle_minutes"] == 20
        assert login("owner@carrier.test", "OPERATOR").put("/api/security/idle-policy", json={
            "minutes": minutes, "reason": "a carrier tries"}).status_code == 403
    finally:
        assert admin.put("/api/security/idle-policy", json={"minutes": minutes, "reason": "back to the default"}).status_code == 200

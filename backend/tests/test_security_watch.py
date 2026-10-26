"""The security watch (wave 7, migration 1167): bait addresses that block whoever touches them, the exception register
(one person asks, another approves, always with an end date), sign-in limits per device and per network, the security
figures for the monitoring, and the relay that takes Alertmanager's security alerts to Telegram."""
import os
import secrets

import httpx
import pytest

from app import ratelimit, shield
from test_e2e import BASE, OWNER_URL, client, login, owner_sql

e2e = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _from(ip: str) -> httpx.Client:
    return httpx.Client(base_url=BASE, headers={"X-Masslak-Client": "web", "X-Forwarded-For": ip}, timeout=20)


def _address() -> str:
    return f"198.18.{secrets.randbelow(250) + 1}.{secrets.randbelow(250) + 1}"


# ------------------------------------------------------------------ no database
def test_bait_addresses_are_paths_no_route_serves():
    from app.main import app
    for path in ("/api/internal/users", "/api/debug", "/api/v0/admin", "/backup/db.sql", "/db-backup/", "/API/Private/keys"):
        assert shield.is_bait(path), path
    for path in ("/api/trips/search", "/api/admin/miles", "/backups-guide", "/api/v1/trips", "/ar/bus/x"):
        assert not shield.is_bait(path), path
    routes = [r.path for r in app.routes if hasattr(r, "path")]
    assert not [p for p in routes if shield.is_bait(p)], "a real route sits under a bait address"


def test_networks_are_counted_by_their_prefix():
    assert ratelimit.network_key("203.0.113.77") == "203.0.113.0/24"
    assert ratelimit.network_key("::ffff:203.0.113.77") == "203.0.113.0/24"
    assert ratelimit.network_key("2001:db8:1:2:3:4:5:6") == "2001:db8:1::/48"
    assert ratelimit.network_key("2001:db8:1:2:3:4:5:6", v6_prefix=64) == "2001:db8:1:2::/64"


def test_robots_names_one_bait_and_no_portal():
    from app.modules.seo.pages import robots_text
    live = robots_text(test_server=False)
    assert "Disallow: /backup/" in live and shield.is_bait("/backup/") and "/admin" not in live


# ------------------------------------------------------------------ with the server
@e2e
def test_touching_a_bait_address_blocks_the_address_at_once():
    ip = _address()
    c = _from(ip)
    assert c.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP"}).status_code != 403
    r = c.get("/api/internal/users")
    assert r.status_code == 404 and r.json()["error"]["code"] == "NOT_FOUND"      # looks like nothing is there
    assert c.get("/api/health").status_code in (200, 403)
    assert c.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP"}).json()["error"]["code"] == "IP_BLOCKED"
    rule = owner_sql("""SELECT source || ' ' || (expires_at > now() + interval '23 hours')::text FROM sec.ip_rule
                         WHERE cidr = $1::cidr AND revoked_at IS NULL ORDER BY id DESC LIMIT 1""", f"{ip}/32")
    assert rule == "AUTO_ABUSE true"
    assert owner_sql("SELECT count(*) FROM sec.waf_hit WHERE ip = $1::inet AND rule = 'bait'", ip) == 1
    # a web page under a bait address answers as a page that does not exist
    other = _from(_address())
    page = other.get("/backup/site.tar.gz")
    assert page.status_code == 404 and page.text == "Not found"


@e2e
def test_an_exception_needs_a_second_person_and_an_end_date():
    first = login("admin@masslak.test", "PLATFORM")
    second = login("security@masslak.test", "PLATFORM")
    ip = _address()
    # allowing an address straight away is no longer possible
    direct = first.post("/api/security/ip-rules", json={"target": ip, "action": "ALLOW", "reason": "partner gateway"})
    assert direct.status_code == 409 and direct.json()["error"]["code"] == "USE_EXCEPTION_REGISTER"
    assert first.post("/api/security/exceptions", json={"target": "10.0.0.0/8", "reason": "the whole private range",
                                                        "days": 5}).json()["error"]["code"] == "EXCEPTION_TOO_WIDE"
    too_long = first.post("/api/security/exceptions", json={"target": ip, "reason": "a partner's gateway address", "days": 365})
    assert too_long.status_code == 409 and too_long.json()["error"]["code"] == "EXCEPTION_EXPIRY_INVALID"
    made = first.post("/api/security/exceptions", json={"target": ip, "scope": "ALL", "reason": "a partner's gateway address", "days": 7})
    assert made.status_code == 201, made.text
    uid = made.json()["uid"]
    try:
        own = first.post(f"/api/security/exceptions/{uid}/approve", json={"note": "fine"})
        assert own.status_code in (403, 409) and own.json()["error"]["code"] in ("EXCEPTION_SAME_PERSON", "STEP_UP_REQUIRED")
        if own.json()["error"]["code"] == "STEP_UP_REQUIRED":
            pytest.skip("the platform's staff sign in with a second factor here; the four-eyes rule is checked in the database tests")
        ok = second.post(f"/api/security/exceptions/{uid}/approve", json={"note": "checked with the partner"})
        assert ok.status_code == 200 and ok.json() == {"status": "APPROVED"}
        listed = next(e for e in first.get("/api/security/exceptions").json()["exceptions"] if e["uid"] == uid)
        assert listed["status"] == "APPROVED" and listed["ip_rule_id"]
        # the approved address passes even a bait address untouched
        c = _from(ip)
        assert c.get("/api/internal/users").status_code == 404
        assert c.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP"}).status_code != 403
    finally:
        r = second.post(f"/api/security/exceptions/{uid}/revoke", json={"note": "test over"})
        if r.status_code == 200:
            assert owner_sql("SELECT revoked_at IS NOT NULL FROM sec.ip_rule WHERE id = (SELECT ip_rule_id FROM sec.shield_exception WHERE uid = $1::uuid)", uid)
        else:
            second.post(f"/api/security/exceptions/{uid}/decline", json={"note": "test over"})


@e2e
def test_sign_in_is_limited_per_device_and_per_network():
    key = "security.signin_device_per_minute"
    before = owner_sql("SELECT value::text FROM sys.setting WHERE key = $1", key)
    owner_sql("UPDATE sys.setting SET value = '3'::jsonb WHERE key = $1", key)
    try:
        device = secrets.token_hex(12)
        codes = []
        for n in range(4):
            c = _from(_address())                     # a fresh address and account each time: only the device repeats
            r = c.post("/api/auth/login", json={"identifier": f"nobody{n}-{device}@masslak.test", "password": "wrong-password",
                                                "portal": "PASSENGER", "device_id": device})
            codes.append(r.status_code)
        assert codes == [401, 401, 401, 429], codes
        assert "device" in r.json()["error"]["message"]
        # another device is not held back
        other = _from(_address()).post("/api/auth/login", json={"identifier": f"other-{device}@masslak.test", "password": "wrong-password",
                                                                 "portal": "PASSENGER", "device_id": secrets.token_hex(12)})
        assert other.status_code == 401
    finally:
        owner_sql("UPDATE sys.setting SET value = $2::jsonb WHERE key = $1", key, before)


@e2e
def test_the_security_figures_reach_the_monitoring():
    token = os.environ.get("MASSLAK_METRICS_TOKEN")
    if not token:
        pytest.skip("needs MASSLAK_METRICS_TOKEN")
    text = client().get("/api/metrics", headers={"Authorization": f"Bearer {token}"}).text
    for name in ("masslak_security_alerts_open{severity=\"CRITICAL\"}", "masslak_security_waf_hits_15m{rule=\"bait\"}",
                 "masslak_security_auth_failures_15m", "masslak_security_ip_blocks_active{source=\"AUTO_ABUSE\"}",
                 "masslak_security_shield_level", "masslak_security_exceptions_pending"):
        assert name in text, name


@e2e
def test_the_alert_relay_takes_alertmanager_posts_with_its_token():
    token = os.environ.get("MASSLAK_ALERT_RELAY_TOKEN")
    if not token:
        pytest.skip("needs MASSLAK_ALERT_RELAY_TOKEN")
    body = {"status": "firing", "alerts": [{"status": "firing", "startsAt": "2026-10-25T16:00:00Z",
                                            "labels": {"alertname": "BaitTouched", "severity": "page"},
                                            "annotations": {"summary": "An address touched a bait address"}}]}
    plain = httpx.Client(base_url=BASE, timeout=20)
    assert plain.post("/api/security/relay/alertmanager", json=body).status_code == 401
    assert plain.post("/api/security/relay/alertmanager", json=body, headers={"Authorization": "Bearer wrong"}).status_code == 401
    before = owner_sql("SELECT value::text FROM sys.setting WHERE key = 'security.alert_telegram_chats'")
    owner_sql("UPDATE sys.setting SET value = '[\"-1001234567890\"]'::jsonb WHERE key = 'security.alert_telegram_chats'")
    try:
        r = plain.post("/api/security/relay/alertmanager", json=body, headers={"Authorization": f"Bearer {token}"})
        assert r.status_code in (200, 502), r.text
        if r.status_code == 200:
            assert r.json() == {"alerts": 1, "sent": 1, "failed": 0}
    finally:
        owner_sql("UPDATE sys.setting SET value = $1::jsonb WHERE key = 'security.alert_telegram_chats'", before)

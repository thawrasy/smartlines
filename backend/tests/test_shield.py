"""The platform shield (owner's request, October 2026; migration 1142): the application firewall, the traffic counters,
the shield level (lockdown stops the traffic until the security staff have checked) and one session per portal."""
import secrets
import time

import httpx
import pytest

from app import shield
from test_e2e import BASE, OWNER_URL, client, login, new_passenger, owner_sql


# ------------------------------------------------------------------ firewall rules (no database)
def test_ordinary_requests_pass_untouched():
    for query in ("origin=DAM&destination=ALP&on=2026-10-19&passengers=2", "q=محطة دمشق المركزية", "name=O'Brien",
                  "note=see you at 7:30; bring the ticket", "ref=TB7GXH-019&lang=ar"):
        assert shield.inspect_line("GET", "/api/trips/search", query, {"user-agent": "Mozilla/5.0"}) is None, query
    body = b'{"first_name": "\xd8\xa3\xd8\xad\xd9\x85\xd8\xaf", "message": "The bus left at 07:30 & arrived late; please refund."}'
    assert shield.inspect_body("/api/support/cases", "application/json", body) is None


def test_probes_scanners_methods_and_size_are_caught():
    assert shield.inspect_line("GET", "/.env", "", {}).rule == "probe"
    assert shield.inspect_line("GET", "/wp-admin/install", "", {}).rule == "probe"
    assert shield.inspect_line("GET", "/index.php", "", {}).rule == "probe"
    assert shield.inspect_line("GET", "/assets/app.js.map", "", {}).rule == "probe"     # no source maps are served
    assert shield.inspect_line("GET", "/api/trips", "", {"user-agent": "sqlmap/1.7"}).rule == "scanner"
    assert shield.inspect_line("TRACE", "/api/trips", "", {}).rule == "bad_method"
    assert shield.inspect_line("GET", "/api/trips", "q=" + "a" * 3000, {}).rule == "oversize"


def test_values_named_like_secrets_are_not_inspected():
    # a password may hold any characters: the firewall never reads it (nor stores it as a sample)
    body = b'{"identifier": "a@b.test", "password": "<any characters at all>", "portal": "PASSENGER"}'
    assert shield.inspect_body("/api/auth/login", "application/json", body) is None


def test_traffic_counts_windows_and_keeps_the_busiest_addresses():
    t = shield.Traffic()
    for _ in range(5):
        t.record("198.51.100.1", 200, now=1000.0)
    t.record("198.51.100.2", 401, "auth_fail", now=1003.0)
    t.record("198.51.100.3", 403, "waf", now=1012.0)             # the next window
    closed = t.take_closed(now=1015.0)
    assert [k for k, _ in closed] == [1000]
    w = closed[0][1]
    assert (w["requests"], w["err_4xx"], w["auth_fail"]) == (6, 1, 1) and w["top"].most_common(1) == [("198.51.100.1", 5)]
    assert list(t.windows) == [1010]                             # the open window keeps counting


def test_lockdown_lets_the_console_sign_in_and_payment_notices_through():
    shield.load({"level": "LOCKDOWN", "policy": {"waf_mode": "BLOCK", "lockdown_allow_signed_in": False}, "session_policy": {}})
    try:
        assert shield.lockdown_allows("/api/security/shield", "ADMIN", None, False)
        assert shield.lockdown_allows("/api/auth/login", "PASSENGER", None, False)
        assert shield.lockdown_allows("/api/payments/notify/x", "PAYMENT_WEBHOOK", None, False)
        assert shield.lockdown_allows("/api/wallet", "PASSENGER", "ALLOW", False)
        assert not shield.lockdown_allows("/api/wallet", "PASSENGER", None, True)
        assert not shield.lockdown_allows("/api/trips/search", "PASSENGER", None, False)
    finally:
        shield.load({"level": "NORMAL", "policy": {"waf_mode": "BLOCK"}, "session_policy": {}})


# ------------------------------------------------------------------ end to end (running API and database)
e2e = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _from(ip: str) -> httpx.Client:
    return httpx.Client(base_url=BASE, headers={"X-Masslak-Client": "web", "X-Forwarded-For": ip}, timeout=20)


@e2e
def test_repeated_probes_block_the_address():
    ip = f"198.18.{secrets.randbelow(256)}.{1 + secrets.randbelow(254)}"
    c = _from(ip)
    for _ in range(5):
        assert c.get("/.env").status_code == 404                      # a probe looks like a missing page
    assert owner_sql("SELECT count(*) FROM sec.waf_hit WHERE ip = $1::inet AND rule = 'probe'", ip) >= 5
    r = c.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": "2026-12-01", "passengers": 1})
    assert r.status_code == 403 and r.json()["error"]["code"] == "IP_BLOCKED"
    assert owner_sql("SELECT count(*) FROM sec.ip_rule WHERE source = 'WAF' AND cidr = $1::cidr AND revoked_at IS NULL", f"{ip}/32") == 1


@e2e
def test_isolation_headers_on_every_answer():
    r = client().get("/api/health")
    assert r.headers["cross-origin-opener-policy"] == "same-origin"
    assert r.headers["x-content-type-options"] == "nosniff" and "frame-ancestors 'none'" in r.headers["content-security-policy"]


def _wait(check, seconds: float = 8.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if check():
            return True
        time.sleep(0.5)
    return False


@e2e
def test_lockdown_stops_the_traffic_until_staff_lower_it():
    admin = login("admin@masslak.test", "PLATFORM")
    passenger = login("passenger@masslak.test", "PASSENGER")
    r = admin.put("/api/security/shield/level", json={"level": "LOCKDOWN", "reason": "checking abnormal traffic", "minutes": 30})
    assert r.status_code == 200, r.text
    try:
        assert _wait(lambda: passenger.get("/api/wallet").status_code == 503)
        r = passenger.get("/api/wallet")
        assert r.json()["error"]["code"] == "SHIELD_LOCKDOWN" and r.headers["retry-after"] == "60"
        view = admin.get("/api/security/shield")                      # the console still works
        assert view.status_code == 200 and view.json()["state"]["level"] == "LOCKDOWN"
        assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'security.shield_changed' AND payload ->> 'level' = 'LOCKDOWN'") >= 1
        # only the platform's security staff control it
        assert login("owner@carrier.test", "OPERATOR").put("/api/security/shield/level", json={
            "level": "NORMAL", "reason": "a carrier tries"}).status_code in (403, 503)
    finally:
        assert admin.put("/api/security/shield/level", json={"level": "NORMAL", "reason": "checked, traffic is normal"}).status_code == 200
    assert _wait(lambda: passenger.get("/api/wallet").status_code == 200)


@e2e
def test_a_new_sign_in_ends_the_other_session_when_the_portal_keeps_one():
    admin = login("admin@masslak.test", "PLATFORM")
    view = admin.get("/api/security/shield").json()["state"]
    policy = {**view["policy"], "session_policy": {**view["session_policy"], "PASSENGER": "SINGLE"}}
    assert admin.put("/api/security/shield/policy", json=policy).status_code == 200
    try:
        first = new_passenger()
        email = first.get("/api/auth/me").json()["email"]
        assert first.get("/api/wallet").status_code == 200
        _wait(lambda: False, 5.5)                                    # every process has read the rule
        second = client()
        assert second.post("/api/auth/login", json={"identifier": email, "password": "another-long-password",
                                                    "portal": "PASSENGER"}).status_code == 200
        r = first.get("/api/wallet")
        assert r.status_code == 401 and r.json()["error"]["code"] == "SESSION_REPLACED"
        assert second.get("/api/wallet").status_code == 200
        assert owner_sql("""SELECT count(*) FROM sys.outbox_event WHERE event_type = 'account.signed_in_elsewhere'
                             AND (payload ->> 'user_id')::bigint = (SELECT id FROM iam.app_user WHERE email = $1)""", email) == 1
    finally:
        policy["session_policy"]["PASSENGER"] = "MULTI"
        assert admin.put("/api/security/shield/policy", json=policy).status_code == 200


@e2e
def test_traffic_reaches_the_watch():
    c = client()
    for _ in range(5):
        c.get("/api/health")
    assert _wait(lambda: owner_sql("SELECT coalesce(sum(requests), 0) FROM sec.traffic_sample WHERE window_start > now() - interval '2 minutes'") > 0, 25)

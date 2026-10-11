"""Reviews of release 1.49.0: the fixes other than the settings guard (test_settings_guard.py) and the rate limiter's
cap (test_ratelimit.py). docs/operations/REVIEW_OCT_2026_RESPONSE.md, section 7, lists them with the findings.
"""
from types import SimpleNamespace

from starlette.requests import Request

from app import middleware


def _request(path: str, route: str | None = None) -> Request:
    scope = {"type": "http", "method": "GET", "path": path, "raw_path": path.encode(), "query_string": b"",
             "headers": [], "scheme": "https", "server": ("localhost", 443)}
    if route:
        scope["route"] = SimpleNamespace(path=route)
    return Request(scope)


# ------------------------------------------------------------------ F-02: the activity log keeps no token or identifier
def test_the_activity_log_records_the_route_not_the_path():
    token = "q7Hk2Jx9Lw-ZpVt4rYs8aBcDeFgHiJkL"
    assert middleware._endpoint(_request(f"/api/reports/deliveries/{token}", "/api/reports/deliveries/{token}")) \
        == "/api/reports/deliveries/{token}"
    # refused before routing (a blocked address, a rate limit): identifiers and tokens become *
    assert middleware._endpoint(_request(f"/api/reports/deliveries/{token}")) == "/api/reports/deliveries/*"
    assert middleware._endpoint(_request("/api/bookings/MSL-7Q2K9/cancel")) == "/api/bookings/*/cancel"
    assert middleware._endpoint(_request("/api/trips/1234/seats")) == "/api/trips/*/seats"
    assert middleware._endpoint(_request("/api/health")) == "/api/health"


# ------------------------------------------------------------------ F-03: Caddy's logs keep no token from a URL
def test_caddy_hides_tokens_in_both_of_its_logs():
    from pathlib import Path
    caddyfile = (Path(__file__).resolve().parents[2] / "deploy" / "Caddyfile").read_text(encoding="utf-8")
    rule = 'request>uri regexp "(/api/reports/deliveries/)[^/?]+|([?&]token=)[^&]*" "${1}${2}REDACTED"'
    assert caddyfile.count(rule) == 2, "the access log and Caddy's own log (errors) both filter the URI"
    assert "log default {" in caddyfile and "log_credentials" not in caddyfile.split("#")[0]


# ------------------------------------------------------------------ secrets never on a command line
def test_the_migration_passes_no_secret_on_a_command_line():
    from pathlib import Path
    script = (Path(__file__).resolve().parents[2] / "deploy" / "migrate.sh").read_text(encoding="utf-8")
    for var in ("api_password", "audit_password", "context_key", "cdc_password", "pw", "writer_password", "upkeep_password"):
        assert f"-v {var}=" not in script, var
        assert f"\\getenv {var} " in script, var


# ------------------------------------------------------------------ password hashes follow the Argon2 parameters
def test_a_hash_made_with_other_parameters_is_marked_for_a_new_one():
    from argon2 import PasswordHasher
    from app.security import hash_password, password_needs_rehash
    assert password_needs_rehash(PasswordHasher(time_cost=1, memory_cost=8192, parallelism=1).hash("x")) is True
    assert password_needs_rehash(hash_password("x")) is False
    assert password_needs_rehash(None) is False and password_needs_rehash("not a hash") is False


def test_a_sign_in_replaces_a_hash_made_with_weaker_parameters():
    import os
    import pytest
    if not os.environ.get("MASSLAK_TEST_URL"):
        pytest.skip("needs the running API (MASSLAK_TEST_URL)")
    from argon2 import PasswordHasher
    from app.security import password_needs_rehash
    from test_e2e import PASSWORD, login, owner_sql
    email = "passenger@masslak.test"
    weak = PasswordHasher(time_cost=1, memory_cost=8192, parallelism=1).hash(PASSWORD)
    owner_sql("UPDATE iam.app_user SET password_hash = $2 WHERE email = $1", email, weak)
    login(email, "PASSENGER")
    stored = owner_sql("SELECT password_hash FROM iam.app_user WHERE email = $1", email)
    assert stored != weak and not password_needs_rehash(stored)
    login(email, "PASSENGER")          # the new hash still opens the account


# ------------------------------------------------------------------ the burst test separates what it measures
def test_burst_trips_take_a_timetable_share():
    from loadtest import burst
    w = burst.trip_weights(100, 0.7)
    assert abs(sum(w) - 1) < 1e-9 and w[0] == w[9] and abs(sum(w[:10]) - 0.7) < 1e-9
    assert abs(sum(w[10:40]) - 0.15) < 1e-9 and abs(sum(w[40:]) - 0.15) < 1e-9
    assert burst.trip_weights(2, 0.7) == [1.0, 1.0]           # too few trips to have a busy tenth: equal shares
    assert abs(sum(burst.trip_weights(4, 0.7)) - 1) < 1e-9


def _burst(rate=10.0, seconds=10, warmup=0):
    from types import SimpleNamespace as NS
    from loadtest import burst
    b = burst.Burst(NS(rate=rate, seconds=seconds, warmup_seconds=warmup, trips=4, hot_share=0.7, cancel_ratio=0.0,
                       max_inflight=100))
    return b


def test_burst_reports_start_and_completion_rates_and_the_drain():
    b = _burst()
    b.outcomes.update(booked=90, dropped=0)
    b.window.update({"from": 100.0, "to": 110.0, "first_start": 100.0, "last_start": 109.9, "last_done": 125.0})
    b.inflight_max = 37
    r = b.rates(25.0)
    assert r["arrival_start_rate_per_second"] == 10.0 and r["arrivals_started"] == 100
    assert r["bookings_completed_per_second"] == 3.6          # 90 over the 25 s until the last one finished
    assert r["drain_seconds"] == 15.0 and r["inflight_max"] == 37


def test_a_burst_the_server_finishes_late_fails():
    from loadtest import burst
    from test_launch_gates_kit import burst_report
    late = burst_report(seconds=600, achieved={"arrival_start_rate_per_second": 240.0, "arrivals_per_second": 240.0,
                                               "drain_seconds": 90.0})
    v = burst.verdict(late)
    assert v["status"] == "FAIL" and "after the schedule ended" in v["reasons"][0]
    on_time = burst_report(seconds=600, achieved={"arrival_start_rate_per_second": 240.0, "drain_seconds": 2.0})
    assert burst.verdict(on_time)["status"] == "PASS"
    stale = burst_report(release={"hash_matches": False})
    assert burst.verdict(stale)["status"] == "INCONCLUSIVE"


def test_warm_up_arrivals_are_not_counted():
    import asyncio

    class Client:
        pass

    b = _burst(rate=200.0, seconds=1, warmup=1)
    seen = []

    async def arrival(c, measured=True):
        seen.append(measured)
        b.idle.put_nowait(c)

    b.arrival = arrival
    asyncio.run(b.generate([Client() for _ in range(500)]))   # never short of travellers
    assert seen.count(False) == 200 and seen.count(True) == 200
    assert len(b.lateness) == 200                             # the generator's lateness covers the measured window only


def test_the_burst_records_the_build(tmp_path, monkeypatch):
    from loadtest import burst
    (tmp_path / "RELEASE").write_text("version=1.50.0\ncommit=" + "a" * 40 + "\n")
    (tmp_path / "IMAGES").write_text("commit=" + "a" * 40 + "\nversion=1.50.0\nmasslak=ghcr.io/x/masslak@sha256:" + "b" * 64 + "\n")
    monkeypatch.setattr(burst, "ROOT", tmp_path)
    b = burst.build()
    assert b["commit"] == "a" * 40 and b["version"] == "1.50.0" and b["source"] == "RELEASE"
    assert b["images"] == {"masslak": "ghcr.io/x/masslak@sha256:" + "b" * 64} and b["images_commit"] == "a" * 40


# ------------------------------------------------------------------ token keys, one per purpose, named in each token
def _keys(monkeypatch, qr: str = "", document: str = "", legacy: str = "", lookup: str = ""):
    from app import security
    for name, value in (("MASSLAK_QR_KEYS", qr), ("MASSLAK_DOCUMENT_KEYS", document), ("MASSLAK_LEGACY_DOCUMENT_TOKENS", legacy),
                        ("MASSLAK_LOOKUP_KEYS", lookup)):
        if value:
            monkeypatch.setenv(name, value)
        else:
            monkeypatch.delenv(name, raising=False)
    security.token_keys.cache_clear()
    return security


def _key(byte: str) -> str:
    import base64
    return base64.b64encode(bytes.fromhex(byte * 32)).decode()


def test_qr_codes_and_document_tokens_name_keys_of_their_own(monkeypatch):
    s = _keys(monkeypatch)
    qr, _ = s.ticket_qr_token("11111111-2222-3333-4444-555555555555", now=1_000_000)
    doc = s.document_token("booking", "MSL-7Q2K9")
    assert qr.startswith("Q1.s1.") and doc.startswith("D2.s1.")         # unset: keys derived for each purpose
    assert s.verify_ticket_qr(qr, now=1_000_000) == "11111111-2222-3333-4444-555555555555"
    assert s.verify_document_token(doc) == ("booking", "MSL-7Q2K9")
    # the purposes do not share a key: a QR signature never verifies as a document one, and neither is the secret's
    assert dict(s.token_keys("qr"))["s1"] != dict(s.token_keys("document"))["s1"]
    assert s.verify_document_token(doc.replace("D2.", "D2.", 1)[:-4] + "AAAA") is None
    s = _keys(monkeypatch, qr="q2:" + _key("ab"), document="d2:" + _key("cd"))
    assert s.ticket_qr_token("u", now=1_000_000)[0].startswith("Q1.q2.u.")
    assert s.verify_document_token(doc) is None                         # signed with a key no longer listed
    s.token_keys.cache_clear()


def test_a_rotation_keeps_the_tokens_of_the_old_key_valid(monkeypatch):
    s = _keys(monkeypatch, document="d1:" + _key("01"))
    old = s.document_token("booking", "MSL-OLD01")
    s = _keys(monkeypatch, document="d2:" + _key("02") + ",d1:" + _key("01"))
    new = s.document_token("booking", "MSL-NEW01")
    assert new.startswith("D2.d2.") and s.verify_document_token(old) == ("booking", "MSL-OLD01")
    assert s.verify_document_token(new) == ("booking", "MSL-NEW01")
    # from the derived key to keys of its own: "s1" keeps what the derived key signed
    s = _keys(monkeypatch)
    derived = s.document_token("booking", "MSL-DRV01")
    s = _keys(monkeypatch, document="d3:" + _key("03") + ",s1")
    assert s.verify_document_token(derived) == ("booking", "MSL-DRV01")
    s.token_keys.cache_clear()


def test_tokens_signed_with_the_secret_itself(monkeypatch):
    s = _keys(monkeypatch)
    legacy_doc = "D1.booking.MSL-7Q2K9." + s._legacy_sign("D1.booking.MSL-7Q2K9")
    assert s.verify_document_token(legacy_doc) == ("booking", "MSL-7Q2K9")      # printed before release 1.50.0
    s = _keys(monkeypatch, legacy="refuse")
    assert s.verify_document_token(legacy_doc) is None
    t = 1_000_000 // 30
    legacy_qr = f"T1.u.{t}." + s._legacy_sign(f"T1.u.{t}")
    assert s.verify_ticket_qr(legacy_qr, now=1_000_000) is None                 # rotating codes: refused at once
    s.token_keys.cache_clear()


def test_a_malformed_key_list_stops_the_start(monkeypatch):
    import pytest
    s = _keys(monkeypatch, qr="Q 1:abc")
    with pytest.raises(s.KeyConfigError, match="key id"):
        s.require_keys_in_production()
    s = _keys(monkeypatch, qr="q1:" + _key("ab") + ",q1:" + _key("cd"))
    with pytest.raises(s.KeyConfigError, match="twice"):
        s.require_keys_in_production()
    s = _keys(monkeypatch, document="d1:c2hvcnQ=")
    with pytest.raises(s.KeyConfigError, match="32 bytes"):
        s.require_keys_in_production()
    s.token_keys.cache_clear()


# ------------------------------------------------------------------ F-06: no inline style allowed by any page's policy
def test_no_page_policy_allows_inline_code():
    import base64
    import hashlib
    from pathlib import Path
    from app.modules.seo import render
    main = (Path(__file__).resolve().parents[1] / "app" / "main.py").read_text(encoding="utf-8")
    assert "unsafe-inline" not in main and "unsafe-eval" not in main
    assert "unsafe-inline" not in render.CSP and "unsafe-eval" not in render.CSP
    # the landing pages' one stylesheet is allowed by its hash, so it must be exactly the text the page carries
    assert f"'sha256-{base64.b64encode(hashlib.sha256(render.CSS.encode()).digest()).decode()}'" in render.CSP
    seo = "".join(p.read_text(encoding="utf-8") for p in (Path(render.__file__).parent).glob("*.py"))
    assert "style=" not in seo.replace("f\"<style>{CSS}</style>\"", ""), "a style attribute in served HTML is refused"


# ------------------------------------------------------------------ images of a known version in every overlay
def test_no_overlay_runs_an_image_of_unknown_version():
    import re
    from pathlib import Path
    root = Path(__file__).resolve().parents[2]
    ours = ("masslak:", "masslak-db:", "masslak-egress:", "masslak-postgres:", "masslak-staging-db:")
    for f in ("deploy/production/docker-compose.production.yml", "deploy/production/docker-compose.telemetry.yml",
              "deploy/warehouse/docker-compose.warehouse.yml", "deploy/staging/docker-compose.staging.yml"):
        for image in re.findall(r"^\s*image:\s*(\S+)", (root / f).read_text(encoding="utf-8"), re.M):
            if image.startswith(ours):
                assert ":${MASSLAK_IMAGE_TAG" in image, f"{f}: {image}"
                if "production" in f or "warehouse" in f:
                    assert ":${MASSLAK_IMAGE_TAG:?" in image, f"{f}: {image} must refuse to start without the release's tag"
            else:
                assert "@sha256:" in image, f"{f}: {image} is not pinned by digest"


# ------------------------------------------------------------------ lookup digests: blocklist and invite codes not keyed by the secret
def test_a_lookup_digest_without_keys_is_the_digest_stored_before_1_50(monkeypatch):
    import hashlib
    import hmac
    from app.config import get_settings
    s = _keys(monkeypatch)
    legacy = hmac.new(get_settings().signing_secret.encode(), b"ali@example.com", hashlib.sha256).digest()
    assert s.identifier_hash("Ali@Example.com") == legacy           # blocks and failure counts of earlier releases still match
    s.token_keys.cache_clear()


def test_a_key_change_stores_new_digests_and_still_matches_the_old_ones(monkeypatch):
    import hashlib
    import hmac
    from app.config import get_settings
    old_secret = get_settings().signing_secret.encode()
    legacy = hmac.new(old_secret, b"ali@example.com", hashlib.sha256).digest()
    s = _keys(monkeypatch, lookup="l2:" + _key("cd") + ",s1")
    hashes = s.identifier_hashes("ali@example.com")
    assert hashes[0] != legacy and hashes[1] == legacy              # new records under the first key, the old ones still found
    assert s.identifier_hash("ali@example.com") == hashes[0]
    s = _keys(monkeypatch, lookup="l2:" + _key("cd"))              # once "s1" is removed, the old digests no longer match
    assert legacy not in s.identifier_hashes("ali@example.com")
    s.token_keys.cache_clear()


def test_an_invite_code_matches_under_any_listed_key(monkeypatch):
    import hashlib
    import hmac
    from app.config import get_settings
    from app.modules.family import service as fam
    legacy = hmac.new(get_settings().signing_secret.encode(), b"family-invite:ABC23456", hashlib.sha256).digest()
    s = _keys(monkeypatch, lookup="l2:" + _key("cd") + ",s1")
    assert fam.code_hash("abc23456") != legacy and fam.code_hashes("abc23456")[1] == legacy
    s.token_keys.cache_clear()


def test_a_blocked_value_is_refused_whatever_key_stored_it(monkeypatch):
    import asyncio
    import hashlib
    import hmac
    from app.config import get_settings
    legacy = hmac.new(get_settings().signing_secret.encode(), b"ali@example.com", hashlib.sha256).digest()

    class Conn:
        def __init__(self, blocked):
            self.blocked = blocked
        async def fetchval(self, sql, kind, digest):
            return digest in self.blocked

    s = _keys(monkeypatch, lookup="l2:" + _key("cd") + ",s1")
    assert asyncio.run(s.identifier_blocked(Conn({legacy}), "EMAIL", " Ali@Example.com "))   # blocked before the change
    assert not asyncio.run(s.identifier_blocked(Conn(set()), "EMAIL", "ali@example.com"))
    s.token_keys.cache_clear()


# ------------------------------------------------------------------ the offline ticket opens three hours before departure
def test_a_credential_opens_three_hours_before_departure_and_closes_an_hour_after_arrival():
    import pytest
    from datetime import datetime, timedelta, timezone
    from app.errors import ApiError
    from app.modules.sales.service import credential_window
    departure = datetime(2026, 10, 11, 6, 0, tzinfo=timezone.utc)
    arrival = departure + timedelta(hours=2)
    with pytest.raises(ApiError) as refused:
        credential_window(departure, arrival, departure - timedelta(hours=3, seconds=1), 3)
    assert refused.value.code == "TICKET_NOT_YET" and refused.value.status == 409
    assert credential_window(departure, arrival, departure - timedelta(hours=3), 3) == int(arrival.timestamp()) + 3600
    assert credential_window(departure, arrival, arrival, 3) == int(arrival.timestamp()) + 3600   # boarding mid-route


# ------------------------------------------------------------------ closing an account keeps its data (1085)
def test_a_closed_account_keeps_its_data_and_comes_back_with_the_same_details():
    import os
    import uuid
    import pytest
    if not os.environ.get("MASSLAK_TEST_URL"):
        pytest.skip("needs the running API (MASSLAK_TEST_URL)")
    from test_e2e import client, login, owner_sql
    email = f"close{uuid.uuid4().hex[:8]}@example.com"
    password = "closing-test-password-2026"
    assert client().post("/api/auth/register", json={"full_name": "Ahmad Sample", "email": email,
                                                     "password": password}).status_code == 201
    signed_in = login(email, "PASSENGER", password)
    assert signed_in.post("/api/account/deactivate", json={"password": "not-the-password-x"}).status_code == 422
    assert signed_in.post("/api/account/deactivate", json={"password": password}).status_code == 200
    # the sessions ended with the closing, and the right details are told that the account is closed
    assert signed_in.get("/api/auth/me").status_code == 401
    # the account row is kept, only its status changes: closing deletes nothing
    assert owner_sql("SELECT status FROM iam.app_user WHERE email = $1", email) == "DEACTIVATED"
    closed = client().post("/api/auth/login", json={"identifier": email, "password": password, "portal": "PASSENGER"})
    assert closed.status_code == 403 and closed.json()["error"]["code"] == "ACCOUNT_DEACTIVATED"
    # a wrong password is refused as before, and reactivation needs the same details
    assert client().post("/api/auth/login", json={"identifier": email, "password": "not-the-password-x",
                                                  "portal": "PASSENGER"}).status_code == 401
    assert client().post("/api/auth/reactivate", json={"identifier": email, "password": "not-the-password-x"}).status_code == 401
    assert client().post("/api/auth/reactivate", json={"identifier": email, "password": password}).status_code == 200
    assert login(email, "PASSENGER", password).get("/api/auth/me").status_code == 200
    stored = owner_sql("SELECT status FROM iam.app_user WHERE email = $1", email)
    assert stored == "ACTIVE"

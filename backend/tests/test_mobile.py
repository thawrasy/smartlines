"""Mobile backend: device-bound sessions with rotating refresh tokens and theft detection, bearer access, device
sign-out, signed offline ticket credentials verified with the public key alone, and offline boarding uploads."""
import base64
import json
import secrets
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

import test_e2e as e2e
from test_e2e import BASE, OWNER_URL, RUN_IP, login, owner_sql, syrian

PASSWORD = e2e.PASSWORD


def app_client(platform="android") -> httpx.Client:
    return httpx.Client(base_url=BASE, timeout=20, headers={"X-Masslak-Client": platform, "X-Forwarded-For": RUN_IP})


def mobile_login(email, portal="PASSENGER", password=PASSWORD, device=None):
    device = device or secrets.token_urlsafe(24)
    r = app_client().post("/api/auth/login", json={"identifier": email, "password": password, "portal": portal,
                                                   "device_id": device, "app_version": "1.0.0"})
    return r, device


def bearer(token, platform="android") -> httpx.Client:
    c = app_client(platform)
    c.headers["Authorization"] = f"Bearer {token}"
    return c


def test_mobile_session_uses_tokens_not_cookies():
    r = app_client().post("/api/auth/login", json={"identifier": "passenger@masslak.test", "password": PASSWORD})
    assert r.status_code == 422 and r.json()["error"]["code"] == "DEVICE_REQUIRED"
    r, _ = mobile_login("passenger@masslak.test")
    assert r.status_code == 200 and "set-cookie" not in r.headers
    body = r.json()
    assert body["access_token"] and body["refresh_token"] and body["access_expires_at"]
    assert bearer(body["access_token"]).get("/api/auth/me").json()["email"] == "passenger@masslak.test"
    # A bearer token is accepted only from the mobile apps, never from a browser page
    web = httpx.Client(base_url=BASE, headers={"X-Masslak-Client": "web", "X-Forwarded-For": RUN_IP,
                                               "Authorization": f"Bearer {body['access_token']}"})
    assert web.get("/api/auth/me").status_code == 401


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_refresh_rotates_and_detects_a_stolen_refresh_token():
    r, device = mobile_login("passenger@masslak.test")
    first = r.json()
    owner_sql("UPDATE iam.user_session SET access_expires_at = now() - interval '1 minute' WHERE token_hash = digest($1, 'sha256')",
              first["access_token"])
    assert bearer(first["access_token"]).get("/api/auth/me").status_code == 401          # access token expired
    assert app_client().post("/api/auth/refresh", json={"refresh_token": first["refresh_token"],
                                                        "device_id": secrets.token_urlsafe(24)}).status_code == 401
    r = app_client().post("/api/auth/refresh", json={"refresh_token": first["refresh_token"], "device_id": device})
    assert r.status_code == 200, r.text
    second = r.json()
    assert bearer(second["access_token"]).get("/api/auth/me").status_code == 200
    # The first refresh token again, a moment later from the same installation: a race with its own rotation (M-02),
    # answered 409 with no tokens and no harm to the session
    race = app_client().post("/api/auth/refresh", json={"refresh_token": first["refresh_token"], "device_id": device})
    assert race.status_code == 409 and race.json()["error"]["code"] == "REFRESH_RACE", race.text
    assert bearer(second["access_token"]).get("/api/auth/me").status_code == 200
    # The first refresh token used again later (as a thief holding a copy would): the session ends for everyone
    owner_sql("UPDATE iam.user_session SET access_expires_at = access_expires_at - interval '1 minute' WHERE token_hash = digest($1, 'sha256')",
              second["access_token"])
    stolen = app_client().post("/api/auth/refresh", json={"refresh_token": first["refresh_token"], "device_id": device})
    assert stolen.status_code == 401
    assert bearer(second["access_token"]).get("/api/auth/me").status_code == 401
    assert app_client().post("/api/auth/refresh", json={"refresh_token": second["refresh_token"], "device_id": device}).status_code == 401


def test_two_refreshes_racing_with_one_token_rotate_it_once():
    """M-02: the check and the rotation hold the session's row; of two requests with the same refresh token one gets the
    new tokens and the other a 409, and the session stays valid with the winner's tokens."""
    r, device = mobile_login("passenger@masslak.test")
    first = r.json()

    def refresh(_):
        return app_client().post("/api/auth/refresh", json={"refresh_token": first["refresh_token"], "device_id": device})
    with ThreadPoolExecutor(max_workers=2) as pool:
        answers = list(pool.map(refresh, range(2)))
    assert sorted(a.status_code for a in answers) == [200, 409], [a.text for a in answers]
    winner = next(a.json() for a in answers if a.status_code == 200)
    assert bearer(winner["access_token"]).get("/api/auth/me").status_code == 200
    again = app_client().post("/api/auth/refresh", json={"refresh_token": winner["refresh_token"], "device_id": device})
    assert again.status_code == 200, again.text


def test_signing_out_a_lost_device():
    email, pw = f"m{uuid.uuid4().hex[:8]}@example.com", "lost-phone-long-passphrase"
    assert e2e.client().post("/api/auth/register", json={"full_name": "Mobile User", "email": email, "password": pw}).status_code == 201
    r, device = mobile_login(email, password=pw)
    tokens = r.json()
    web = e2e.client()
    web.post("/api/auth/login", json={"identifier": email, "password": pw, "portal": "PASSENGER"})
    phone = next(d for d in web.get("/api/account/devices").json()["devices"] if d["platform"] == "ANDROID")
    assert bearer(tokens["access_token"]).post("/api/account/push-token", json={"token": "fcm:" + "a" * 40}).status_code == 200
    assert web.post(f"/api/account/devices/{phone['id']}/revoke").status_code == 200
    assert bearer(tokens["access_token"]).get("/api/auth/me").status_code == 401
    assert app_client().post("/api/auth/refresh", json={"refresh_token": tokens["refresh_token"], "device_id": device}).status_code == 401
    again, _ = mobile_login(email, password=pw, device=device)
    assert again.status_code == 403 and again.json()["error"]["code"] == "DEVICE_REVOKED"


@pytest.fixture(scope="module")
def boarding():
    """A fresh trip with its own driver, and a passenger ticket on it."""
    e2e.publish_fresh_trip()
    driver_email = e2e.FRESH_DRIVERS[-1]
    d = login(driver_email, "DRIVER", e2e.FRESH_DRIVER_PASSWORD)
    trip_uid = d.get("/api/driver/trips").json()["trips"][-1]["uid"]
    pax = login("passenger@masslak.test", "PASSENGER")
    seats = [x["seat_no"] for x in pax.get(f"/api/trips/{trip_uid}", params={"from_seq": 0, "to_seq": 2}).json()["seats"] if x["free"]][:2]
    h = pax.post("/api/holds", json={"trip_uid": trip_uid, "from_seq": 0, "to_seq": 2, "seat_nos": seats}).json()
    b = pax.post("/api/bookings", json={"hold_token": h["hold_token"], "trip_uid": trip_uid, "from_seq": 0, "to_seq": 2,
                                        "passengers": [syrian(s) for s in seats], "idempotency_key": uuid.uuid4().hex})
    assert b.status_code == 201, b.text
    tickets = pax.get(f"/api/bookings/{b.json()['booking_ref']}").json()["tickets"]
    yield {"driver": d, "trip": trip_uid, "pax": pax, "tickets": tickets}
    # Boarding has started on this trip, so finish it like a real trip: other tests must not pick it up for sale
    if OWNER_URL:
        owner_sql("""UPDATE ops.trip SET departure_at = now() - make_interval(days => d, hours => 6),
                                         arrival_at = now() - make_interval(days => d, hours => 1)
                       FROM (SELECT count(*)::int AS d FROM ops.trip WHERE departure_at < now() - interval '2 hours') past
                      WHERE uid = $1""", uuid.UUID(trip_uid))
        login("owner@carrier.test", "OPERATOR").post(f"/api/carrier/trips/{trip_uid}/complete")


def test_offline_credential_verifies_with_the_public_key_alone(boarding):
    cred = boarding["pax"].get(f"/api/tickets/{boarding['tickets'][0]['uid']}/offline").json()["credential"]
    key = e2e.client().get("/api/public/keys/ticket").json()
    _, payload, sig = cred.split(".")
    def unb64(s):
        return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
    Ed25519PublicKey.from_public_bytes(unb64(key["public_key"])).verify(unb64(sig), payload.encode())   # raises if forged
    claims = json.loads(unb64(payload))
    assert claims["k"] == boarding["tickets"][0]["uid"] and claims["t"] == boarding["trip"] and claims["s"] == boarding["tickets"][0]["seat_label"]
    other = login("owner@carrier.test", "OPERATOR")
    assert other.get(f"/api/tickets/{boarding['tickets'][0]['uid']}/offline").status_code == 403


def test_offline_boarding_upload_is_applied_once(boarding):
    d, trip = boarding["driver"], boarding["trip"]
    pack = d.get(f"/api/driver/trips/{trip}/offline").json()
    assert {t["uid"] for t in boarding["tickets"]} <= {t["uid"] for t in pack["tickets"]}
    assert "id_no" not in json.dumps(pack) and pack["public_key"]
    cred = boarding["pax"].get(f"/api/tickets/{boarding['tickets'][0]['uid']}/offline").json()["credential"]
    second = boarding["pax"].get(f"/api/tickets/{boarding['tickets'][1]['uid']}/offline").json()["credential"]
    scans = [{"scan_id": "scan-" + secrets.token_hex(6), "token": cred, "scanned_at": "2026-10-04T06:00:00Z"},
             {"scan_id": "scan-" + secrets.token_hex(6), "token": cred, "scanned_at": "2026-10-04T06:00:05Z"},
             {"scan_id": "scan-" + secrets.token_hex(6), "token": second[:-4] + "AAAA", "scanned_at": "2026-10-04T06:00:09Z"}]
    r = d.post("/api/driver/scans/batch", json={"trip_uid": trip, "scans": scans})
    assert r.status_code == 200, r.text
    assert [x["result"] for x in r.json()["results"]] == ["OK", "DUPLICATE", "INVALID_QR"]
    again = d.post("/api/driver/scans/batch", json={"trip_uid": trip, "scans": scans[:1]}).json()["results"][0]
    assert again["result"] == "OK" and again["replayed"] is True                        # a retried upload changes nothing
    online = d.post("/api/driver/scan", json={"trip_uid": trip, "token": second})       # the credential also works online
    assert online.json()["result"] == "OK"


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to move the trip into the past")
def test_offline_scan_uploaded_after_the_credential_expired(boarding):
    """A driver boards offline and syncs the next day: the credential was valid when scanned, so the boarding stands.
    A scan dated more than a day before departure is judged at the upload time instead (third-party review, Oct 2026)."""
    d, trip, pax = boarding["driver"], boarding["trip"], boarding["pax"]
    seats = [x["seat_no"] for x in pax.get(f"/api/trips/{trip}", params={"from_seq": 0, "to_seq": 2}).json()["seats"] if x["free"]][:2]
    h = pax.post("/api/holds", json={"trip_uid": trip, "from_seq": 0, "to_seq": 2, "seat_nos": seats}).json()
    b = pax.post("/api/bookings", json={"hold_token": h["hold_token"], "trip_uid": trip, "from_seq": 0, "to_seq": 2,
                                        "passengers": [syrian(s) for s in seats], "idempotency_key": uuid.uuid4().hex})
    assert b.status_code == 201, b.text
    tickets = pax.get(f"/api/bookings/{b.json()['booking_ref']}").json()["tickets"]
    # The trip left ten hours ago and arrived seven hours ago: its credentials expired an hour ago (arrival + 6 h)
    owner_sql("""UPDATE ops.trip SET departure_at = now() - interval '10 hours', arrival_at = now() - interval '7 hours'
                  WHERE uid = $1""", uuid.UUID(trip))
    # and the driver downloaded its pack before it left (an offline scan cannot be older than the download, R-09)
    owner_sql("""UPDATE ops.offline_pack_download SET first_at = now() - interval '11 hours', last_at = now() - interval '11 hours'
                  WHERE trip_id = (SELECT id FROM ops.trip WHERE uid = $1)""", uuid.UUID(trip))
    creds = [pax.get(f"/api/tickets/{k['uid']}/offline").json()["credential"] for k in tickets]
    on_board = (datetime.now(timezone.utc) - timedelta(hours=9)).isoformat()
    long_before = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
    scans = [{"scan_id": "late-" + secrets.token_hex(6), "token": creds[0], "scanned_at": on_board},
             {"scan_id": "late-" + secrets.token_hex(6), "token": creds[1], "scanned_at": long_before}]
    r = d.post("/api/driver/scans/batch", json={"trip_uid": trip, "scans": scans})
    assert r.status_code == 200, r.text
    by_scan = {x["scan_id"]: x["result"] for x in r.json()["results"]}      # answered in the order the scans happened
    assert [by_scan[x["scan_id"]] for x in scans] == ["OK", "INVALID_QR"]
    # online, the same expired credential is refused: only an offline scan made in time counts
    assert d.post("/api/driver/scan", json={"trip_uid": trip, "token": creds[1]}).json()["result"] == "INVALID_QR"

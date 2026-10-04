"""Mobile backend: device-bound sessions with rotating refresh tokens and theft detection, bearer access, device
sign-out, signed offline ticket credentials verified with the public key alone, and offline boarding uploads."""
import base64
import json
import secrets
import uuid

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
    # The first refresh token is used again (as a thief holding a copy would): the session ends for everyone
    stolen = app_client().post("/api/auth/refresh", json={"refresh_token": first["refresh_token"], "device_id": device})
    assert stolen.status_code == 401
    assert bearer(second["access_token"]).get("/api/auth/me").status_code == 401
    assert app_client().post("/api/auth/refresh", json={"refresh_token": second["refresh_token"], "device_id": device}).status_code == 401


def test_signing_out_a_lost_device():
    email, pw = f"m{uuid.uuid4().hex[:8]}@example.com", "mobile-long-password"
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
    unb64 = lambda s: base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
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

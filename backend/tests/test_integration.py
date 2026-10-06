"""Integration API v1: clients, keys, scopes, partner wallet credits, channel sales, border authorities and webhooks.

What must never happen: a key stored in a readable form, a client acting before platform approval (or approved by its
own creator), a key reaching another company's rows or a scope it was not granted, a partner credit applied twice,
a webhook carrying another company's events or personal data it was not approved for, or an unsigned delivery.
"""
import datetime as dt
import hashlib
import hmac
import ipaddress
import json
import os
import secrets
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

import httpx
import pytest

from test_e2e import BASE, H, OWNER_URL, book, free_seats, login, owner_sql, pax, trip  # noqa: F401, F811  (pax and trip are fixtures)

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
BACKEND = os.path.join(os.path.dirname(__file__), "..")


def api(key: str) -> httpx.Client:
    """A partner's HTTP client: the key in a header, no cookies, no browser client header."""
    return httpx.Client(base_url=BASE, headers={"X-Api-Key": key, "X-Forwarded-For": H["X-Forwarded-For"]}, timeout=30)


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def security():
    return login("security@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def owner():
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def agency():
    return login("agency@agency.test", "AGENCY")


def make_client(creator, approver, **body) -> tuple[str, str]:
    """Creates, approves and issues a key; returns (client uid, key)."""
    r = creator.post("/api/integrations/clients", json={"environment": "SANDBOX", **body})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert r.json()["status"] == "PENDING"
    r = approver.post(f"/api/integrations/clients/{uid}/approve", json={})
    assert r.status_code == 200, r.text
    r = creator.post(f"/api/integrations/clients/{uid}/keys")
    assert r.status_code == 201, r.text
    return uid, r.json()["key"]


@pytest.fixture(scope="module")
def carrier_client(owner, admin):
    return make_client(owner, admin, name="Carrier ERP", kind="CARRIER",
                       scopes=["trips:read", "manifests:read", "bookings:read", "reports:read", "webhooks:manage"])


def test_company_client_needs_approval_and_key_is_hashed(owner, admin):
    r = owner.post("/api/integrations/clients", json={"name": "Timetable feed", "kind": "CARRIER", "scopes": ["trips:read"]})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert owner.post(f"/api/integrations/clients/{uid}/keys").json()["error"]["code"] == "API_CLIENT_NOT_ACTIVE"
    assert owner.post(f"/api/integrations/clients/{uid}/approve", json={}).status_code == 403          # platform security only
    # a carrier cannot take scopes of other kinds
    bad = owner.post("/api/integrations/clients", json={"name": "Greedy", "kind": "CARRIER", "scopes": ["wallet:credit"]})
    assert bad.json()["error"]["code"] == "SCOPE_NOT_ALLOWED"
    assert owner.post("/api/integrations/clients", json={"name": "Bank", "kind": "PARTNER", "scopes": ["wallet:credit"]}
                      ).json()["error"]["code"] == "KIND_NOT_ALLOWED"
    assert admin.post(f"/api/integrations/clients/{uid}/approve", json={}).json()["status"] == "ACTIVE"
    k = owner.post(f"/api/integrations/clients/{uid}/keys").json()
    assert k["key"].startswith("msk_test_") and len(k["key"]) > 40
    row = owner_sql("SELECT key_hash, key_prefix FROM iam.api_key WHERE id = $1", k["id"], fetch=True)
    assert bytes(row["key_hash"]) == hashlib.sha256(k["key"].encode()).digest() and row["key_prefix"] == k["key"][:17]
    detail = owner.get(f"/api/integrations/clients/{uid}").json()
    assert all("key" not in x for x in detail["keys"]) and k["key"] not in json.dumps(detail)
    assert api(k["key"]).get("/api/v1/me").json()["scopes"] == ["trips:read"]
    # a third key is refused while two are active (rotation keeps at most two)
    owner.post(f"/api/integrations/clients/{uid}/keys")
    assert owner.post(f"/api/integrations/clients/{uid}/keys").json()["error"]["code"] == "API_KEY_LIMIT"
    # revoking stops the key at once
    assert owner.post(f"/api/integrations/clients/{uid}/keys/{k['id']}/revoke", json={"reason": "rotated out"}).status_code == 200
    assert api(k["key"]).get("/api/v1/me").json()["error"]["code"] == "API_KEY_INVALID"


def test_keys_are_checked_and_cookies_ignored(owner):
    anon = httpx.Client(base_url=BASE, headers={"X-Forwarded-For": H["X-Forwarded-For"]}, timeout=20)
    assert anon.get("/api/v1/me").json()["error"]["code"] == "API_KEY_REQUIRED"
    assert api("msk_test_" + "x" * 43).get("/api/v1/me").json()["error"]["code"] == "API_KEY_INVALID"
    # a staff session cookie does not open /api/v1
    assert httpx.Client(base_url=BASE, cookies=owner.cookies, timeout=20).get("/api/v1/me").status_code == 401


def test_carrier_key_reads_only_its_company(carrier_client, trip):
    _, key = carrier_client
    c = api(key)
    me = c.get("/api/v1/me").json()
    assert me["kind"] == "CARRIER" and me["acting_account"] == "owner@carrier.test"
    today = dt.date.today()
    trips = c.get("/api/v1/trips", params={"from": str(today - dt.timedelta(days=5)), "to": str(today + dt.timedelta(days=30))})
    assert trips.status_code == 200, trips.text
    company = owner_sql("SELECT c.id FROM iam.company c JOIN iam.company_member m ON m.company_id = c.id JOIN iam.app_user u ON u.id = m.user_id "
                        "WHERE u.email = 'owner@carrier.test'")
    uids = [t["uid"] for t in trips.json()["trips"]]
    assert uids and owner_sql("SELECT count(*) FROM ops.trip WHERE uid = ANY($1::uuid[]) AND company_id <> $2", uids, company) == 0
    m = c.get(f"/api/v1/trips/{uids[0]}/manifest")
    assert m.status_code == 200 and "passengers" in m.json()
    other = owner_sql("SELECT uid::text FROM ops.trip WHERE company_id <> $1 LIMIT 1", company)
    if other:
        assert c.get(f"/api/v1/trips/{other}/manifest").status_code == 404
    found = c.get("/api/v1/trips/search", params={"origin": "HAM", "destination": "DAM", "on": str(today)})
    assert found.status_code == 200, found.text
    assert c.post("/api/v1/wallet/credits", json={"mobile": "0944000000", "amount": 100000, "reference": "abcdef"}).json()["error"]["code"] == "SCOPE_MISSING"
    assert c.get("/api/v1/border/manifests").json()["error"]["code"] == "SCOPE_MISSING"
    # reports: the same catalog and rules as the portal, as a file
    codes = [r["code"] for r in c.get("/api/v1/reports").json()["reports"]]
    assert codes
    r = c.get(f"/api/v1/reports/{codes[0]}", params={"format": "csv"})
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/csv"), r.text
    # reading personal data is in the activity log with the client
    n = owner_sql("SELECT count(*) FROM audit.activity_log WHERE actor_type = 'API_CLIENT' AND action = 'manifest.view' "
                  "AND api_client_id = (SELECT id FROM iam.api_client WHERE uid = $1)", uuid.UUID(carrier_client[0]))
    assert n >= 1
    assert owner_sql("SELECT sum(requests) FROM iam.api_usage_daily WHERE api_client_id = (SELECT id FROM iam.api_client WHERE uid = $1)",
                     uuid.UUID(carrier_client[0])) >= 5


def test_suspension_and_ip_allowlist(carrier_client, owner, admin):
    uid, key = carrier_client
    c = api(key)
    assert admin.post(f"/api/integrations/clients/{uid}/suspend", json={"reason": "security review"}).json()["status"] == "SUSPENDED"
    assert c.get("/api/v1/me").json()["error"]["code"] == "API_CLIENT_INACTIVE"
    assert admin.post(f"/api/integrations/clients/{uid}/reactivate", json={}).json()["status"] == "ACTIVE"
    assert owner.put(f"/api/integrations/clients/{uid}", json={"ip_allowlist": ["10.0.0.0/8"]}).status_code == 200
    assert c.get("/api/v1/me").json()["error"]["code"] == "API_IP_NOT_ALLOWED"
    run_net = str(ipaddress.ip_network(H["X-Forwarded-For"] + "/16", strict=False))
    assert owner.put(f"/api/integrations/clients/{uid}", json={"ip_allowlist": [run_net]}).status_code == 200
    assert c.get("/api/v1/me").status_code == 200
    # an approved client cannot widen its own scopes
    assert owner.put(f"/api/integrations/clients/{uid}", json={"scopes": ["trips:read", "manifests:read", "bookings:read", "reports:read",
                                                                       "webhooks:manage", "shipments:read"]}
                     ).json()["error"]["code"] == "SCOPE_WIDENING_NEEDS_APPROVAL"
    assert owner.put(f"/api/integrations/clients/{uid}", json={"ip_allowlist": []}).status_code == 200


@pytest.fixture(scope="module")
def partner(admin, security):
    """A bank partner, created by one platform officer and approved by another."""
    r = admin.post("/api/integrations/clients", json={"name": "Partner Bank", "kind": "PARTNER", "scopes": ["wallet:credit", "webhooks:manage"],
                                                      "provider_code": "PARTNER_API", "environment": "SANDBOX"})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert admin.post(f"/api/integrations/clients/{uid}/approve", json={}).json()["error"]["code"] == "FOUR_EYES"
    assert security.post(f"/api/integrations/clients/{uid}/approve", json={}).json()["status"] == "ACTIVE"
    return uid, admin.post(f"/api/integrations/clients/{uid}/keys").json()["key"]


def passenger_with_mobile(mobile: str) -> httpx.Client:
    c = httpx.Client(base_url=BASE, headers=H, timeout=20)
    email = f"u{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/api/auth/register", json={"full_name": "Test User", "email": email, "mobile": mobile, "password": "another-long-password"})
    assert r.status_code == 201, r.text
    assert c.post("/api/auth/login", json={"identifier": email, "password": "another-long-password", "portal": "PASSENGER"}).status_code == 200
    return c


def test_partner_credits_a_wallet_once(partner):
    mobile = "09" + str(secrets.randbelow(10**8)).zfill(8)
    pax = passenger_with_mobile(mobile)
    c = api(partner[1])
    assert c.post("/api/v1/wallet/lookup", json={"mobile": mobile}).json() == {"exists": True, "first_name": "Test"}
    assert c.post("/api/v1/wallet/lookup", json={"mobile": "0999999990"}).json()["exists"] is False
    before = pax.get("/api/wallet").json()["balance"]
    ref = "BNK-" + secrets.token_hex(6)
    r = c.post("/api/v1/wallet/credits", json={"mobile": mobile, "amount": 5_000_000, "reference": ref})
    assert r.status_code == 201 and r.json()["status"] == "SUCCESS", r.text
    again = c.post("/api/v1/wallet/credits", json={"mobile": mobile, "amount": 5_000_000, "reference": ref})
    assert again.json()["replayed"] is True and again.json()["uid"] == r.json()["uid"]
    assert pax.get("/api/wallet").json()["balance"] == before + 5_000_000
    assert c.post("/api/v1/wallet/credits", json={"mobile": mobile, "amount": 6_000_000, "reference": ref}).json()["error"]["code"] == "REFERENCE_REUSED"
    assert c.get(f"/api/v1/wallet/credits/{ref}").json()["status"] == "SUCCESS"
    listing = c.get("/api/v1/wallet/credits", params={"from": str(dt.date.today())}).json()
    assert ref in [x["reference"] for x in listing["credits"]]
    # the ledger: the partner's clearing account owes what the wallet received
    txn = owner_sql("SELECT ledger_txn_id FROM fin.payment WHERE uid = $1", uuid.UUID(r.json()["uid"]))
    assert owner_sql("SELECT sum(CASE WHEN direction = 'DR' THEN amount ELSE -amount END) FROM fin.ledger_entry WHERE txn_id = $1", txn) == 0
    assert c.get("/api/v1/bookings", params={"from": str(dt.date.today())}).json()["error"]["code"] == "SCOPE_MISSING"


def test_client_rate_limit(partner, admin):
    uid, key = partner
    assert admin.put(f"/api/integrations/clients/{uid}", json={"rate_limit_per_min": 10}).status_code == 200
    c = api(key)
    codes = [c.get("/api/v1/me").status_code for _ in range(14)]
    assert 429 in codes
    assert admin.put(f"/api/integrations/clients/{uid}", json={"rate_limit_per_min": 600}).status_code == 200


def test_channel_sells_through_the_api(agency, admin, trip):
    uid, key = make_client(agency, admin, name="Agency booking engine", kind="CHANNEL",
                           scopes=["trips:read", "bookings:read", "bookings:write"])
    c = api(key)
    seat_map = c.get(f"/api/v1/trips/{trip['uid']}", params={"from_seq": trip["from_seq"], "to_seq": trip["to_seq"]}).json()["seats"]
    seats = [s["seat_no"] for s in seat_map if s["free"]][:1]
    h = c.post("/api/v1/holds", json={"trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"], "seat_nos": seats})
    assert h.status_code == 201, h.text
    passenger = {"nationality": "SY", "first_name": "Rami", "father_name": "Khaled", "grandfather_name": "Omar", "last_name": "Haddad",
                 "seat_no": seats[0], "id_type": "NATIONAL_ID", "id_last4": "1234"}
    body = {"hold_token": h.json()["hold_token"], "trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"],
            "fare_brand": "STANDARD", "idempotency_key": uuid.uuid4().hex, "passengers": [passenger], "contact_mobile": "+963944123456"}
    b = c.post("/api/v1/bookings", json=body)
    assert b.status_code == 201, b.text
    ref = b.json()["booking_ref"]
    assert c.post("/api/v1/bookings", json=body).json().get("replayed") is True
    got = c.get(f"/api/v1/bookings/{ref}").json()
    assert got["booking"]["channel"] == "AGENCY" and len(got["tickets"]) == 1
    assert ref in [x["booking_ref"] for x in c.get("/api/v1/bookings", params={"from": str(dt.date.today())}).json()["bookings"]]
    row = owner_sql("SELECT actor_type, user_id IS NOT NULL AS by_user FROM audit.activity_log WHERE action = 'agency.sell' "
                    "AND api_client_id = (SELECT id FROM iam.api_client WHERE uid = $1) ORDER BY id DESC LIMIT 1", uuid.UUID(uid), fetch=True)
    assert row["actor_type"] == "API_CLIENT" and row["by_user"]
    assert c.post(f"/api/v1/bookings/{ref}/cancel").status_code == 200


def test_border_authority_reads_and_decides(admin, security):
    authority = owner_sql("SELECT bp.authority_id FROM brd.border_point bp WHERE bp.authority_id IS NOT NULL ORDER BY bp.station_id LIMIT 1")
    code = owner_sql("SELECT code FROM sec.authority_profile WHERE id = $1", authority)
    src = owner_sql("""SELECT m.trip_id, m.border_point_id, (SELECT max(version) FROM brd.manifest x WHERE x.trip_id = m.trip_id
                         AND x.border_point_id = m.border_point_id) AS v FROM brd.manifest m JOIN brd.border_point bp ON bp.station_id = m.border_point_id
                        WHERE bp.authority_id = $1 LIMIT 1""", authority, fetch=True)
    mid = owner_sql("""INSERT INTO brd.manifest (trip_id, border_point_id, version, manifest_type, status) VALUES ($1, $2, $3, 'PRE_DEPARTURE', 'SUBMITTED')
                       RETURNING id""", src["trip_id"], src["border_point_id"], src["v"] + 1)
    sys.path.insert(0, BACKEND)
    from app.crypto import RESTRICTED_REF, FieldCipher, _derive
    sealed = FieldCipher({1: _derive(RESTRICTED_REF)}, {RESTRICTED_REF: 1}, b"x" * 32).encrypt("N7654321", "brd.manifest_person.doc_no")
    ticket = owner_sql("SELECT id FROM sales.ticket ORDER BY id DESC LIMIT 1")
    pid = owner_sql("""INSERT INTO brd.manifest_person (manifest_id, person_role, ticket_id, doc_type, doc_no_enc, doc_no_bidx, enc_key_id,
                         issuing_country, nationality, birth_date) VALUES ($1, 'PASSENGER', $2, 'PASSPORT', $3, $4, 1, 'SY', 'SY', '1990-01-01') RETURNING id""",
                    mid, ticket, sealed.ciphertext, secrets.token_bytes(32))
    muid = str(owner_sql("SELECT uid FROM brd.manifest WHERE id = $1", mid))
    r = admin.post("/api/integrations/clients", json={"name": "Border authority", "kind": "AUTHORITY", "authority_code": code,
                                                      "scopes": ["border:read", "border:respond"]})
    assert r.status_code == 201, r.text
    security.post(f"/api/integrations/clients/{r.json()['uid']}/approve", json={})
    c = api(admin.post(f"/api/integrations/clients/{r.json()['uid']}/keys").json()["key"])
    listed = c.get("/api/v1/border/manifests", params={"status": "SUBMITTED"}).json()["manifests"]
    assert muid in [m["uid"] for m in listed]
    others = owner_sql("""SELECT count(*) FROM brd.manifest m JOIN brd.border_point bp ON bp.station_id = m.border_point_id
                           LEFT JOIN brd.crossing_profile cp ON cp.id = m.profile_id
                           WHERE m.uid = ANY($1::uuid[]) AND bp.authority_id IS DISTINCT FROM $2 AND cp.authority_id IS DISTINCT FROM $2""",
                       [uuid.UUID(m["uid"]) for m in listed], authority)
    assert others == 0
    detail = c.get(f"/api/v1/border/manifests/{muid}").json()
    assert detail["people"][0]["doc_no"] == "N7654321"
    stranger = owner_sql("SELECT id FROM brd.manifest_person WHERE manifest_id <> $1 LIMIT 1", mid)
    assert c.post(f"/api/v1/border/manifests/{muid}/decisions", json={"decisions": [{"subject": "PERSON", "subject_id": stranger, "decision": "HOLD"}]}
                  ).json()["error"]["code"] == "SUBJECT_NOT_IN_MANIFEST"
    d = c.post(f"/api/v1/border/manifests/{muid}/decisions", json={"decisions": [
        {"subject": "PERSON", "subject_id": pid, "decision": "OK"}, {"subject": "MANIFEST", "decision": "OK"}]})
    assert d.json()["status"] == "ACKNOWLEDGED", d.text
    assert c.post(f"/api/v1/border/manifests/{muid}/decisions", json={"decisions": [{"subject": "MANIFEST", "decision": "DENY"}]}
                  ).json()["error"]["code"] == "MANIFEST_NOT_OPEN"
    assert owner_sql("SELECT count(*) FROM brd.manifest_response WHERE manifest_id = $1", mid) == 2


# ------------------------------------------------------------------ webhooks
class Receiver:
    """A local HTTPS endpoint with a self-signed certificate (the worker trusts it through MASSLAK_WEBHOOK_CA_FILE)."""

    def __init__(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import NameOID
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
        now = dt.datetime.now(dt.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - dt.timedelta(minutes=5)).not_valid_after(now + dt.timedelta(days=1))
                .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
                .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True).sign(key, hashes.SHA256()))
        d = tempfile.mkdtemp()
        self.cert, kfile = os.path.join(d, "cert.pem"), os.path.join(d, "key.pem")
        open(self.cert, "wb").write(cert.public_bytes(serialization.Encoding.PEM))
        open(kfile, "wb").write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self.got: list[tuple[dict, bytes]] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                outer.got.append(({k.lower(): v for k, v in self.headers.items()}, body))
                self.send_response(200)
                self.end_headers()

            def log_message(self, *a):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(self.cert, kfile)
        self.server.socket = ctx.wrap_socket(self.server.socket, server_side=True)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"https://localhost:{self.server.server_address[1]}/hooks/masslak"


def run_worker(receiver: Receiver) -> None:
    env = {**os.environ, "MASSLAK_WEBHOOK_ALLOW_PRIVATE": "true", "MASSLAK_WEBHOOK_CA_FILE": receiver.cert}
    r = subprocess.run([sys.executable, "-m", "app.modules.notify.worker", "--once"], cwd=BACKEND, env=env, capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr[-2000:]


def verify(secret: str, headers: dict, body: bytes) -> bool:
    t, v1 = (p.split("=", 1)[1] for p in headers["x-masslak-signature"].split(","))
    good = hmac.new(secret.encode(), f"{t}.".encode() + body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(good, v1) and abs(time.time() - int(t)) < 300


def test_webhooks_are_signed_scoped_and_private(carrier_client, owner, agency, admin, trip, pax):
    uid, key = carrier_client
    rx = Receiver()
    assert owner.post(f"/api/integrations/clients/{uid}/webhooks", json={"url": "https://10.1.2.3/hook", "events": ["booking.confirmed"]}
                      ).json()["error"]["code"] == "WEBHOOK_URL_NOT_PUBLIC"
    assert owner.post(f"/api/integrations/clients/{uid}/webhooks", json={"url": rx.url, "events": ["wallet.credited"]}
                      ).json()["error"]["code"] == "WEBHOOK_EVENT_NOT_ALLOWED"
    hook = owner.post(f"/api/integrations/clients/{uid}/webhooks", json={"url": rx.url, "events": ["booking.confirmed", "booking.cancelled"]})
    assert hook.status_code == 201, hook.text
    secret, wuid = hook.json()["secret"], hook.json()["uid"]
    # an agency endpoint subscribed to the same event must not receive the carrier's direct sales
    ag_uid, _ = make_client(agency, admin, name="Agency listener", kind="CHANNEL", scopes=["bookings:read", "webhooks:manage"])
    ag = agency.post(f"/api/integrations/clients/{ag_uid}/webhooks", json={"url": rx.url, "events": ["booking.confirmed"]})
    assert ag.status_code == 201, ag.text
    run_worker(rx)                                # drain whatever is already waiting
    rx.got.clear()
    assert owner.post(f"/api/integrations/clients/{uid}/webhooks/{wuid}/ping").status_code == 200
    run_worker(rx)
    pings = [(h, b) for h, b in rx.got if h["x-masslak-event"] == "webhook.ping"]
    assert len(pings) == 1 and verify(secret, *pings[0])
    assert not verify("whsec_wrong", *pings[0])
    # a direct booking on the carrier's trip
    rx.got.clear()
    seats = free_seats(pax, trip, 1)
    token = pax.post("/api/holds", json={"trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"], "seat_nos": seats}).json()["hold_token"]
    pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex})
    b = book(pax, trip, token, seats)
    assert b.status_code == 201, b.text
    run_worker(rx)
    confirmed = [(h, json.loads(body)) for h, body in rx.got if h["x-masslak-event"] == "booking.confirmed"
                 and json.loads(body)["data"].get("booking_ref") == b.json()["booking_ref"]]
    assert len(confirmed) == 1, [h["x-masslak-event"] for h, _ in rx.got]
    data = confirmed[0][1]["data"]
    assert "contact_mobile" not in data and "booker_user_id" not in data and data["trip_no"]
    assert confirmed[0][1]["type"] == "booking.confirmed" and confirmed[0][1]["api_version"] == "v1"
    ag_id = owner_sql("SELECT id FROM sys.webhook_endpoint WHERE uid = $1", uuid.UUID(ag.json()["uid"]))
    assert owner_sql("""SELECT count(*) FROM sys.webhook_delivery d JOIN sys.outbox_event o ON o.id = d.outbox_event_id
                         WHERE d.endpoint_id = $1 AND o.payload->>'booking_ref' = $2""", ag_id, b.json()["booking_ref"]) == 0
    detail = owner.get(f"/api/integrations/clients/{uid}").json()
    assert any(d["status"] == "DELIVERED" and d["event_type"] == "booking.confirmed" for d in detail["deliveries"])
    # the client manages its endpoints with its key too
    c = api(key)
    assert wuid in [w["uid"] for w in c.get("/api/v1/webhooks").json()["webhooks"]]
    rotated = c.post(f"/api/v1/webhooks/{wuid}/rotate").json()["secret"]
    assert rotated != secret
    assert c.delete(f"/api/v1/webhooks/{wuid}").status_code == 200


def test_openapi_contract():
    spec = httpx.get(f"{BASE}/api/v1/openapi.json", timeout=20).json()
    assert spec["components"]["securitySchemes"]["ApiKey"]["name"] == "X-Api-Key"
    for path in ("/api/v1/wallet/credits", "/api/v1/bookings", "/api/v1/border/manifests/{uid}/decisions", "/api/v1/webhooks"):
        assert path in spec["paths"]
    assert all(p.startswith("/api/v1/") for p in spec["paths"])

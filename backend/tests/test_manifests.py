"""Carrier-issued manifests (study 11.10): the carrier issues a signed, versioned manifest for a domestic trip; routes
approved by a second platform officer decide which authorities receive it; the authority pulls and acknowledges it
through the integration API; no other carrier sees it."""
import uuid

import pytest

from test_e2e import free_seats, hold, login, new_passenger, owner_sql, pax, syrian, trip  # noqa: F401  (fixtures)
from test_integration import api

FUND = 10_000_000


@pytest.fixture(scope="module")
def owner():
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def security():
    return login("security@masslak.test", "PLATFORM")


def booked(t):
    p = new_passenger()
    assert p.post("/api/wallet/topup", json={"amount": FUND, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    seat = free_seats(p, t, 1)
    h = hold(p, t, seat).json()["hold_token"]
    r = p.post("/api/bookings", json={"hold_token": h, "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"],
                                      "idempotency_key": uuid.uuid4().hex, "passengers": [syrian(seat[0])]})
    assert r.status_code == 201, r.text
    return r.json()["booking_ref"]


def test_manifest_issued_routed_pulled_and_acknowledged(owner, admin, security, trip):
    booked(trip)
    code = "AUTH-" + uuid.uuid4().hex[:6].upper()
    authority = owner_sql("""INSERT INTO sec.authority_profile (code, name, authority_type, protocol, active)
                             VALUES ($1, 'Traffic police (test)', 'TRAFFIC', 'REST', true) RETURNING id""", code)
    r = admin.post("/api/r/manifest-route", json={"authority_id": authority, "scope": "DOMESTIC", "channel": "API_PULL",
                                                   "legal_basis": "Passenger transport regulation, article 12", "company_id":
                                                   owner_sql("SELECT company_id FROM ops.trip WHERE uid = $1", uuid.UUID(trip["uid"]))})
    assert r.status_code == 201, r.text
    route = r.json()["_key"]
    try:
        r = admin.post(f"/api/r/manifest-route/{route}/do/approve")
        assert r.status_code in (403, 409), r.text                                  # the drafting officer cannot approve
        r = security.post(f"/api/r/manifest-route/{route}/do/approve")
        assert r.status_code == 200, r.text

        r = owner.post(f"/api/carrier/trips/{trip['uid']}/manifests", json={"type": "PRE_DEPARTURE"})
        assert r.status_code == 201, r.text
        first = r.json()["issued"][0]
        assert first["scope"] == "DOMESTIC" and first["persons"] >= 1 and len(first["sha256"]) == 64
        mine = [d for d in first["deliveries"] if d["authority"] == "Traffic police (test)"]
        assert len(mine) == 1 and mine[0]["channel"] == "API_PULL" and mine[0]["status"] == "AVAILABLE"

        r = owner.post(f"/api/carrier/trips/{trip['uid']}/manifests", json={"type": "AMENDMENT"})
        second = r.json()["issued"][0]
        assert second["version"] == first["version"] + 1
        listed = owner.get(f"/api/carrier/trips/{trip['uid']}/manifests").json()["manifests"]
        status = {m["uid"]: m["status"] for m in listed}
        assert status[first["uid"]] == "SUPERSEDED" and status[second["uid"]] == "ISSUED"

        detail = owner.get(f"/api/carrier/manifests/{second['uid']}").json()
        assert all(p["doc_last4"] is None or len(p["doc_last4"]) <= 4 for p in detail["people"])      # documents masked for the carrier
        csv = owner.get(f"/api/carrier/manifests/{second['uid']}/export")
        lines = csv.content.decode("utf-8-sig").splitlines()
        assert csv.status_code == 200 and lines[0].startswith("trip,") and second["sha256"] in lines[0] and "full_name" in lines[1]

        # the authority pulls it with its own API key and acknowledges it
        r = admin.post("/api/integrations/clients", json={"name": "Traffic police", "kind": "AUTHORITY", "authority_code": code,
                                                          "scopes": ["manifests:receive"]})
        assert r.status_code == 201, r.text
        assert security.post(f"/api/integrations/clients/{r.json()['uid']}/approve", json={}).status_code == 200
        c = api(admin.post(f"/api/integrations/clients/{r.json()['uid']}/keys").json()["key"])
        waiting = c.get("/api/v1/manifests/deliveries", params={"status": "AVAILABLE"}).json()["deliveries"]
        ours = next(d for d in waiting if d["manifest_uid"] == second["uid"])
        full = c.get(f"/api/v1/manifests/deliveries/{ours['uid']}").json()
        assert full["scope"] == "DOMESTIC" and len(full["people"]) >= 1
        assert all(p["doc_no"] is None for p in full["people"])          # the route was not approved for full document numbers
        r = c.post(f"/api/v1/manifests/deliveries/{ours['uid']}/ack", json={"status": "ACKNOWLEDGED", "ack_ref": "TP-2026-1"})
        assert r.status_code == 200, r.text
        assert c.post(f"/api/v1/manifests/deliveries/{ours['uid']}/ack", json={"status": "REJECTED"}).status_code == 409
        seen = owner.get(f"/api/carrier/manifests/{second['uid']}").json()["deliveries"]
        assert any(d["status"] == "ACKNOWLEDGED" and d["ack_ref"] == "TP-2026-1" for d in seen)

        # another company never sees the manifest
        agency = login("agency@agency.test", "AGENCY")
        assert agency.get(f"/api/carrier/manifests/{second['uid']}").status_code in (403, 404)
        assert owner_sql("SELECT count(*) FROM brd.manifest_delivery d JOIN brd.manifest m ON m.id = d.manifest_id WHERE m.uid = $1",
                         uuid.UUID(second["uid"])) >= 1
    finally:
        security.post(f"/api/r/manifest-route/{route}/do/retire")


def test_only_published_trips_of_the_carrier_get_a_manifest(owner):
    t = owner_sql("""SELECT t.uid FROM ops.trip t WHERE t.company_id = (SELECT company_id FROM iam.company_member m JOIN iam.app_user u
                       ON u.id = m.user_id WHERE u.email = 'owner@carrier.test') AND t.status = 'DRAFT' LIMIT 1""")
    if t:
        r = owner.post(f"/api/carrier/trips/{t}/manifests", json={"type": "PRE_DEPARTURE"})
        assert r.status_code == 409 and r.json()["error"]["code"] == "TRIP_NOT_PUBLISHED"
    assert owner.post(f"/api/carrier/trips/{uuid.uuid4()}/manifests", json={"type": "FINAL"}).status_code == 404

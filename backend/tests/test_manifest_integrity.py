"""Manifests carry their cargo, cannot change once issued, and reach the border authority through its contract
(review of release 1.47.0, package G: R-11, R-12, R-13).

An international trip with a passenger and a booked parcel is issued through the carrier API: the manifest holds both,
is signed, and is SUBMITTED to the authority of its crossing. That authority lists it, reads it with its cargo and the
canonical form, verifies the hash and the signature with the published key, and acknowledges it through
/api/v1/border; the carrier sees the answer. The database refuses any change to an issued manifest's rows.
"""
import base64
import hashlib
import json
import secrets
import uuid

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from test_e2e import FRESH_DRIVERS, OWNER_URL, bookable_trip, client, day, free_seats, hold, login, new_passenger, owner_sql
from test_integration import api

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def modules():
    admin = login("admin@masslak.test", "PLATFORM")
    states = {m["key"]: m["enabled"] for m in admin.get("/api/admin/modules").json()["modules"]}
    changed = [k for k in ("cargo", "trip_manifests") if not states.get(k)]
    for k in changed:
        assert admin.put(f"/api/admin/modules/{k}", json={"enabled": True, "reason": "manifest tests"}).status_code == 200
    yield
    for k in changed:
        admin.put(f"/api/admin/modules/{k}", json={"enabled": False, "reason": "manifest tests done"})


@pytest.fixture(scope="module")
def owner(modules):
    return login("owner@carrier.test", "OPERATOR")


def international_trip(owner) -> dict:
    """A trip Damascus to Beirut published through the carrier API, with its crossing at Jdeidet Yabous."""
    admin = login("admin@masslak.test", "PLATFORM")
    stations = admin.get("/api/stations", params={"city": "BEY"}).json()["stations"]
    if not stations:
        r = admin.post("/api/admin/stations", json={"city_code": "BEY", "number": 1, "name": "Beirut Charles Helou Station",
                                                    "lat": 33.8990, "lng": 35.5140})
        assert r.status_code == 201, r.text
        stations = admin.get("/api/stations", params={"city": "BEY"}).json()["stations"]
    dam = next(s for s in admin.get("/api/stations", params={"city": "DAM"}).json()["stations"] if s["station_class"] == "CENTRAL")["uid"]
    code = f"DAM-BEY-{secrets.randbelow(9000) + 1000}"
    r = owner.post("/api/carrier/routes", json={"code": code, "stops": [
        {"station_uid": dam, "arr_offset_min": 0, "dep_offset_min": 0, "fare_from_origin": 0},
        {"station_uid": stations[0]["uid"], "arr_offset_min": 180, "dep_offset_min": 180, "fare_from_origin": 5500000}]})
    assert r.status_code == 201, r.text
    route = next(x for x in owner.get("/api/carrier/routes").json()["routes"] if x["code"] == code)
    layout = next(x for x in owner.get("/api/carrier/seat-layouts").json()["layouts"] if x["total_seats"] == 44)
    plate = str(100000 + secrets.randbelow(900000))
    r = owner.post("/api/carrier/vehicles", json={
        "plate_no": plate, "chassis_no": f"CHS-I{plate}", "vehicle_type": "COACH", "seat_layout_uid": layout["uid"],
        "insurance_no": f"POL-I{plate}", "insurer": "Test", "insurance_issue": "2026-01-01", "insurance_expiry": "2030-01-01"})
    assert r.status_code == 201, r.text
    vehicle = r.json()["uid"]
    email = f"driver{uuid.uuid4().hex[:8]}@example.com"
    r = owner.post("/api/carrier/crew", json={"full_name": "Border Driver", "email": email, "password": "fresh-driver-password"})
    assert r.status_code == 201, r.text
    FRESH_DRIVERS.append(email)
    driver = r.json()["uid"]
    for _ in range(10):
        r = owner.post("/api/carrier/trips", json={"route_uid": route["uid"], "vehicle_uid": vehicle, "driver_uid": driver,
                                                   "departure_local": f"{day(3)}T{6 + secrets.randbelow(12):02d}:{secrets.randbelow(60):02d}:00"})
        if r.status_code != 409:
            break
    assert r.status_code == 201, r.text
    pax = new_passenger()
    for d in (3, 4, 2):
        trips = pax.get("/api/trips/search", params={"origin": "DAM", "destination": "BEY", "on": day(d), "passengers": 1}).json()["trips"]
        t = next((x for x in trips if x["uid"] == r.json()["uid"]), None)
        if t:
            break
    assert t, "the new international trip is not on sale"
    # the crossing plan: which border point the trip leaves Syria through (planning data of the trip)
    owner_sql("""INSERT INTO ops.trip_crossing_plan (trip_id, seq, exit_station_id, entry_station_id)
                 SELECT t.id, 1, x.id, e.id FROM ops.trip t, net.station x, net.station e
                  WHERE t.uid = $1 AND x.code = 'SY-DAM-X901' AND e.code = 'SY-DRA-X902'""", uuid.UUID(t["uid"]))
    owner_sql("UPDATE fleet.vehicle SET cargo_capacity_kg = 1000 WHERE uid = $1", uuid.UUID(vehicle))
    return t


def test_an_international_manifest_carries_cargo_is_signed_and_answered_through_the_border_contract(owner):
    t = international_trip(owner)
    # a passenger with a passport, through the passenger API
    p = new_passenger()
    assert p.post("/api/wallet/topup", json={"amount": 50_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    seat = free_seats(p, t, 1)
    h = hold(p, t, seat).json()["hold_token"]
    traveller = {"nationality": "SY", "first_name": "Rami", "father_name": "Khaled", "grandfather_name": "Omar", "last_name": "Haddad",
                 "seat_no": seat[0], "id_type": "PASSPORT", "id_no": f"N{secrets.randbelow(10**7):07d}", "birth_date": "1990-04-01",
                 "passport_expiry": "2031-01-01", "gender": "M"}
    r = p.post("/api/bookings", json={"hold_token": h, "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"],
                                      "idempotency_key": uuid.uuid4().hex, "passengers": [traveller]})
    assert r.status_code == 201, r.text
    # a parcel booked on its hold
    assert owner.put(f"/api/carrier/trips/{t['uid']}/hold", json={"max_weight_kg": 200}).status_code == 200
    tariff = owner.post("/api/carrier/parcels/tariffs", json={"code": "INT" + uuid.uuid4().hex[:5].upper(), "name": "Cross-border parcel",
                                                              "pricing_mode": "WEIGHT", "currency": "SYP", "per_kg": 100000}).json()
    r = p.post("/api/parcels", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "tariff_uid": tariff["uid"],
                                     "weight_kg": 6, "length_cm": 40, "width_cm": 30, "height_cm": 20, "description": "Household items",
                                     "recipient_name": "Maya Haddad", "recipient_mobile": "+9613123456", "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    tracking = r.json()["tracking_no"]

    r = owner.post(f"/api/carrier/trips/{t['uid']}/manifests", json={"type": "PRE_DEPARTURE"})
    assert r.status_code == 201, r.text
    m = r.json()["issued"][0]
    assert m["scope"] == "INTERNATIONAL" and m["status"] == "SUBMITTED" and m["content"] == "MIXED" and m["cargo"] == 1
    check = owner.get(f"/api/carrier/manifests/{m['uid']}/verify").json()
    assert check["hash_matches"] and check["signature_valid"]
    detail = owner.get(f"/api/carrier/manifests/{m['uid']}").json()
    assert detail["cargo"][0]["tracking_no"] == tracking and detail["cargo"][0]["declared_weight_kg"] == 6.0

    # the issued rows are sealed: no change, no addition, no removal
    mid = owner_sql("SELECT id FROM brd.manifest WHERE uid = $1", uuid.UUID(m["uid"]))
    for sql in ("UPDATE brd.manifest_cargo SET declared_weight_kg = 1 WHERE manifest_id = $1",
                "DELETE FROM brd.manifest_person WHERE manifest_id = $1",
                "UPDATE brd.manifest SET manifest_type = 'FINAL' WHERE id = $1"):
        with pytest.raises(Exception) as err:
            owner_sql(sql, mid)
        assert "MANIFEST_SEALED" in str(err.value), sql

    # the authority of the crossing, with a border key: list, read, verify, decide
    authority = owner_sql("""SELECT bp.authority_id FROM brd.border_point bp JOIN net.station s ON s.id = bp.station_id
                              WHERE s.code = 'SY-DAM-X901'""")
    code = owner_sql("SELECT code FROM sec.authority_profile WHERE id = $1", authority)
    admin, security = login("admin@masslak.test", "PLATFORM"), login("security@masslak.test", "PLATFORM")
    r = admin.post("/api/integrations/clients", json={"name": "Border authority", "kind": "AUTHORITY", "authority_code": code,
                                                      "scopes": ["border:read", "border:respond"]})
    assert r.status_code == 201, r.text
    assert security.post(f"/api/integrations/clients/{r.json()['uid']}/approve", json={}).status_code == 200
    border = api(admin.post(f"/api/integrations/clients/{r.json()['uid']}/keys").json()["key"])
    listed = border.get("/api/v1/border/manifests", params={"status": "SUBMITTED"}).json()["manifests"]
    assert m["uid"] in [x["uid"] for x in listed]
    full = border.get(f"/api/v1/border/manifests/{m['uid']}").json()
    passenger = next(x for x in full["people"] if x["role"] == "PASSENGER")
    assert passenger["doc_no"] == traveller["id_no"] and full["cargo"][0]["declared_weight_kg"] == 6.0
    integrity = full["integrity"]
    canonical = json.dumps(integrity["canonical"], sort_keys=True, separators=(",", ":")).encode()
    digest = hashlib.sha256(canonical).digest()
    assert digest.hex() == integrity["sha256"] == m["sha256"]
    key = client().get("/api/public/keys/manifest").json()
    assert key["kid"] == integrity["kid"]
    raw = base64.urlsafe_b64decode(key["public_key"] + "=" * (-len(key["public_key"]) % 4))
    Ed25519PublicKey.from_public_bytes(raw).verify(base64.b64decode(integrity["signature"]), digest)   # raises if forged
    person = passenger["id"]
    d = border.post(f"/api/v1/border/manifests/{m['uid']}/decisions", json={"decisions": [
        {"subject": "PERSON", "subject_id": person, "decision": "OK"}, {"subject": "MANIFEST", "decision": "OK"}]})
    assert d.status_code == 200 and d.json()["status"] == "ACKNOWLEDGED", d.text
    assert border.post(f"/api/v1/border/manifests/{m['uid']}/decisions", json={"decisions": [{"subject": "MANIFEST", "decision": "DENY"}]}
                       ).json()["error"]["code"] == "MANIFEST_NOT_OPEN"
    seen = {x["uid"]: x["status"] for x in owner.get(f"/api/carrier/trips/{t['uid']}/manifests").json()["manifests"]}
    assert seen[m["uid"]] == "ACKNOWLEDGED"                       # the carrier sees the border's answer

    # a pre-arrival manifest for the same crossing supersedes it
    r = owner.post(f"/api/carrier/trips/{t['uid']}/manifests", json={"type": "PRE_ARRIVAL"})
    assert r.status_code == 201, r.text
    arrival = r.json()["issued"][0]
    assert arrival["version"] == m["version"] + 1 and arrival["type"] == "PRE_ARRIVAL" and arrival["status"] == "SUBMITTED"


def test_a_pre_arrival_manifest_is_for_international_trips_only(owner):
    pax = new_passenger()
    t = bookable_trip(pax)
    if t is None:
        pytest.skip("no domestic trip on sale")
    r = owner.post(f"/api/carrier/trips/{t['uid']}/manifests", json={"type": "PRE_ARRIVAL"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "MANIFEST_TYPE_SCOPE", r.text

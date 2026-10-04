"""Module workflows end to end: shuttle subscriptions paid from the wallet, parcels with public tracking, taxi requests,
car rental bookings and the freight marketplace (post, bid, award). Needs the module demo data (seed_modules.py)."""
import time
import uuid
from datetime import datetime, timedelta, timezone

import httpx
import pytest

from test_e2e import BASE, OWNER_URL, RUN_IP, login, new_passenger

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module", autouse=True)
def modules_on(admin):
    before = {m["key"]: m["enabled"] for m in admin.get("/api/admin/modules").json()["modules"]}
    for key in ("shuttle_subscriptions", "cargo", "taxi", "car_rental", "freight"):
        if not before[key]:
            assert admin.put(f"/api/admin/modules/{key}", json={"enabled": True, "reason": "workflow tests"}).status_code == 200
    time.sleep(6)
    yield
    for key, on in before.items():
        if not on and key in ("shuttle_subscriptions", "cargo", "taxi", "car_rental", "freight"):
            admin.put(f"/api/admin/modules/{key}", json={"enabled": False, "reason": "workflow tests"})


@pytest.fixture(scope="module")
def rider():
    c = new_passenger()
    return c


def topup(c, amount=50_000_000):
    assert c.post("/api/wallet/topup", json={"amount": amount, "idempotency_key": uuid.uuid4().hex}).status_code == 200


def balance(c):
    return c.get("/api/wallet").json()["balance"]


def test_subscription_is_paid_from_the_wallet_and_issues_a_pass(rider):
    plans = rider.get("/api/w/subscriptions/plans").json()["plans"]
    assert plans, "run backend/scripts/seed_modules.py: no shuttle plans on sale"
    plan = plans[0]
    r = rider.post("/api/w/subscriptions", json={"plan_id": plan["id"], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 402 and r.json()["error"]["code"] == "INSUFFICIENT_BALANCE"
    topup(rider)
    before = balance(rider)
    r = rider.post("/api/w/subscriptions", json={"plan_id": plan["id"], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    assert r.json()["pass_no"].startswith("SP")
    assert balance(rider) == before - plan["price"]
    r = rider.post("/api/w/subscriptions", json={"plan_id": plan["id"], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 409 and r.json()["error"]["code"] == "ALREADY_SUBSCRIBED"
    mine = rider.get("/api/w/subscriptions/mine").json()["subscriptions"]
    assert mine[0]["status"] == "ACTIVE" and mine[0]["pass_no"]


def test_parcel_quote_send_and_public_tracking(rider):
    topup(rider)
    opts = rider.get("/api/w/parcels/options").json()
    assert opts["services"] and len(opts["stations"]) >= 2
    body = {"service_id": opts["services"][0]["id"], "origin_station_id": opts["stations"][0]["id"],
            "dest_station_id": opts["stations"][1]["id"], "weight_kg": 4.2, "declared_value": 1_500_000}
    q = rider.post("/api/w/parcels/quote", json=body).json()
    assert q["price"] > 0
    same = rider.post("/api/w/parcels/quote", json=body | {"dest_station_id": body["origin_station_id"]})
    assert same.status_code == 422
    before = balance(rider)
    r = rider.post("/api/w/parcels", json=body | {"recipient_name": "Lina Haddad", "recipient_mobile": "+963944555111",
                                                  "contents": "Books", "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    tracking = r.json()["tracking_no"]
    assert balance(rider) == before - q["price"]
    t = httpx.get(f"{BASE}/api/track/{tracking}", headers={"X-Forwarded-For": RUN_IP})
    assert t.status_code == 200
    data = t.json()
    assert data["status"] == "CREATED" and data["events"][0]["milestone"] == "CREATED"
    assert "Lina" not in t.text and "963944555111" not in t.text          # no personal data on public tracking
    assert httpx.get(f"{BASE}/api/track/MS0000000000", headers={"X-Forwarded-For": RUN_IP}).status_code == 404
    assert any(p["tracking_no"] == tracking for p in rider.get("/api/w/parcels/mine").json()["parcels"])


def test_taxi_estimate_request_and_cancel(rider):
    trip = {"city_id": 1, "pickup_lat": 33.5138, "pickup_lng": 36.2765, "dropoff_lat": 33.4950, "dropoff_lng": 36.2420}
    est = rider.post("/api/w/taxi/estimate", json=trip)
    assert est.status_code == 200, "run backend/scripts/seed_modules.py: no meter tariff in Damascus"
    assert est.json()["fare"] > 0 and est.json()["km"] > 1
    assert rider.post("/api/w/taxi/estimate", json=trip | {"dropoff_lat": 33.5139, "dropoff_lng": 36.2766}).status_code == 422
    r = rider.post("/api/w/taxi/requests", json=trip | {"pickup_text": "Marjeh square", "dropoff_text": "Mazzeh"})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert r.json()["fare"] == est.json()["fare"]
    assert rider.post(f"/api/w/taxi/requests/{uid}/cancel").json()["status"] == "CANCELLED"
    r = rider.post(f"/api/w/taxi/requests/{uid}/cancel")
    assert r.status_code == 409 and r.json()["error"]["code"] == "INVALID_STATE"
    late = rider.post("/api/w/taxi/requests", json=trip | {"pickup_text": "A", "dropoff_text": "Mazzeh", "kind": "ADVANCE"})
    assert late.status_code == 422


def test_rental_offers_booking_and_cancel(rider):
    start = (datetime.now(timezone.utc) + timedelta(days=3)).replace(microsecond=0)
    end = start + timedelta(days=4)
    branches = rider.get("/api/w/rental/offers").json()["branches"]
    assert branches, "run backend/scripts/seed_modules.py: no rental branches"
    offers = []
    for b in branches:
        offers = rider.get("/api/w/rental/offers", params={"branch_id": b["id"], "starts_at": start.isoformat(),
                                                           "ends_at": end.isoformat()}).json()["offers"]
        if offers:
            break
    assert offers
    o = offers[0]
    assert o["days"] == 4 and o["total"] >= o["price"]
    r = rider.post("/api/w/rental/bookings", json={"rate_id": o["rate_id"], "pickup_branch_id": b["id"],
                                                   "starts_at": start.isoformat(), "ends_at": end.isoformat()})
    assert r.status_code == 201, r.text
    assert r.json()["quoted_total"] == o["total"]
    uid = r.json()["uid"]
    bad = rider.post("/api/w/rental/bookings", json={"rate_id": o["rate_id"], "pickup_branch_id": b["id"],
                                                     "starts_at": end.isoformat(), "ends_at": start.isoformat()})
    assert bad.status_code == 422
    assert rider.post(f"/api/w/rental/bookings/{uid}/cancel").json()["status"] == "CANCELLED"


def test_freight_marketplace_post_bid_award():
    shipper, other = new_passenger(), new_passenger()
    carrier = login("owner@carrier.test", "OPERATOR")
    stations = shipper.get("/api/w/parcels/options").json()["stations"]
    start = datetime.now(timezone.utc) + timedelta(days=2)
    desc = f"Olive oil pallets {uuid.uuid4().hex[:6]}"
    r = shipper.post("/api/w/freight/requests", json={
        "origin_station_id": stations[0]["id"], "dest_station_id": stations[1]["id"], "cargo_category": "GENERAL",
        "cargo_description": desc, "declared_weight_kg": 18000, "packages": 40, "pickup_from": start.isoformat(),
        "pickup_to": (start + timedelta(days=1)).isoformat(), "target_price": 350_000_000})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    market = carrier.get("/api/w/freight/market").json()["requests"]
    assert any(x["uid"] == uid for x in market)
    r = carrier.post(f"/api/w/freight/requests/{uid}/bid", json={"price": 320_000_000, "valid_hours": 24})
    assert r.status_code == 201, r.text
    bid_id = r.json()["id"]
    again = carrier.post(f"/api/w/freight/requests/{uid}/bid", json={"price": 300_000_000})
    assert again.status_code == 409 and again.json()["error"]["code"] == "ALREADY_BID"
    assert other.post(f"/api/w/freight/bids/{bid_id}/accept").status_code == 404     # not their load
    mine = shipper.get("/api/w/freight/requests/mine").json()["requests"]
    load = next(x for x in mine if x["uid"] == uid)
    assert [b["id"] for b in load["bids"]] == [bid_id]
    r = shipper.post(f"/api/w/freight/bids/{bid_id}/accept")
    assert r.status_code == 200, r.text
    assert r.json()["price"] == 320_000_000
    assert shipper.post(f"/api/w/freight/bids/{bid_id}/accept").status_code == 409
    assert not any(x["uid"] == uid for x in carrier.get("/api/w/freight/market").json()["requests"])
    assert carrier.post(f"/api/w/freight/bids/{bid_id}/withdraw").status_code == 409     # accepted bids stay


def test_workflows_follow_the_module_switch(admin, rider):
    assert admin.put("/api/admin/modules/taxi", json={"enabled": False, "reason": "workflow tests"}).status_code == 200
    try:
        time.sleep(6)
        r = rider.post("/api/w/taxi/estimate", json={"city_id": 1, "pickup_lat": 33.51, "pickup_lng": 36.27,
                                                     "dropoff_lat": 33.49, "dropoff_lng": 36.24})
        assert r.status_code == 404 and r.json()["error"]["code"] == "MODULE_DISABLED"
    finally:
        admin.put("/api/admin/modules/taxi", json={"enabled": True, "reason": "workflow tests"})
        time.sleep(6)

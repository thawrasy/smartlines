"""Parcels booked on a trip's hold (owner's decision 3; review of release 1.47.0, R-14).

Carrier tariffs price a parcel by weight, by volume, by the dearer of the two (both charges shown), at a fixed price
(letters) or by agreement with the customer. A booking takes the hold space before the wallet is charged, so the last
space goes to one customer only and nobody pays for a parcel that has no place on the trip.
"""
import threading
import uuid

import pytest

from test_e2e import OWNER_URL, bookable_trip, day, login, new_passenger, owner_sql, publish_fresh_trip

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
FUND = 50_000_000


@pytest.fixture(scope="module")
def cargo_on():
    admin = login("admin@masslak.test", "PLATFORM")
    was = next(m["enabled"] for m in admin.get("/api/admin/modules").json()["modules"] if m["key"] == "cargo")
    if not was:
        assert admin.put("/api/admin/modules/cargo", json={"enabled": True, "reason": "parcel tests"}).status_code == 200
    yield
    if not was:
        admin.put("/api/admin/modules/cargo", json={"enabled": False, "reason": "parcel tests done"})


@pytest.fixture(scope="module")
def owner(cargo_on):
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def tariffs(owner):
    tag = uuid.uuid4().hex[:5].upper()
    out = {}
    for code, body in {
        "P": {"name": "Parcel by weight or size", "pricing_mode": "WEIGHT_AND_VOLUME", "base_price": 100000, "per_kg": 50000,
              "per_m3": 10000000, "min_charge": 300000, "max_weight_kg": 40},
        "L": {"name": "Letter", "pricing_mode": "FIXED", "fixed_price": 250000, "max_weight_kg": 0.5},
        "V": {"name": "Valuables, price agreed", "pricing_mode": "NEGOTIATED", "max_weight_kg": 5},
    }.items():
        r = owner.post("/api/carrier/parcels/tariffs", json={"code": f"T{tag}{code}", "currency": "SYP", **body})
        assert r.status_code == 201, r.text
        out[code] = r.json()
    r = owner.post("/api/carrier/parcels/tariffs", json={"code": f"T{tag}X", "name": "Broken", "pricing_mode": "WEIGHT", "currency": "SYP"})
    assert r.status_code == 422                                    # a weight tariff needs its rate per kilogram
    return out


@pytest.fixture(scope="module")
def hold_trip(owner):
    pax = new_passenger()
    trip = bookable_trip(pax)
    if trip is None:
        publish_fresh_trip()
        trip = bookable_trip(pax)
    owner_sql("""UPDATE fleet.vehicle SET cargo_capacity_kg = greatest(coalesce(cargo_capacity_kg, 0), 2000)
                  WHERE id = (SELECT vehicle_id FROM ops.trip WHERE uid = $1)""", uuid.UUID(trip["uid"]))
    used = owner.get(f"/api/carrier/trips/{trip['uid']}/hold").json()["hold"]
    used_kg = (used["max_weight_kg"] - used["free_weight_kg"]) if used else 0
    r = owner.put(f"/api/carrier/trips/{trip['uid']}/hold", json={"max_weight_kg": used_kg + 30})   # 30 kg free for this test
    assert r.status_code == 200, r.text
    return trip


def customer():
    p = new_passenger()
    assert p.post("/api/wallet/topup", json={"amount": FUND, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    return p


def parcel(trip, tariff, kg, cm=(40, 30, 20), **extra):
    return {"trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"], "tariff_uid": tariff["uid"],
            "weight_kg": kg, "length_cm": cm[0], "width_cm": cm[1], "height_cm": cm[2], **extra}


def booking(trip, tariff, kg, cm=(40, 30, 20)):
    return parcel(trip, tariff, kg, cm, description="Books and clothes", recipient_name="Lina Haddad", recipient_mobile="+963944555666",
                  idempotency_key=uuid.uuid4().hex)


def test_customers_find_trips_with_free_hold_and_the_carriers_tariffs(hold_trip, tariffs):
    p = customer()
    found = None
    for d in range(1, 7):
        trips = p.get("/api/parcels/trips", params={"origin": "DAM", "destination": "HMA", "on": day(d)}).json()["trips"]
        found = next((t for t in trips if t["uid"] == hold_trip["uid"]), None)
        if found:
            break
    assert found and found["hold"]["free_weight_kg"] >= 30
    modes = {t["pricing_mode"] for t in found["tariffs"]}
    assert {"WEIGHT_AND_VOLUME", "FIXED", "NEGOTIATED"} <= modes


def test_a_quote_shows_the_weight_and_the_volume_and_charges_the_dearer(hold_trip, tariffs):
    p = customer()
    light_but_big = p.post("/api/parcels/quote", json=parcel(hold_trip, tariffs["P"], 2, (100, 50, 40))).json()
    price = light_but_big["price"]
    assert price["weight_kg"] == 2 and price["volume_m3"] == 0.2
    assert price["weight_charge"] == 100000 and price["volume_charge"] == 2000000
    assert price["basis"] == "VOLUME" and price["total"] == 100000 + 2000000 and light_but_big["fits"]
    heavy_but_small = p.post("/api/parcels/quote", json=parcel(hold_trip, tariffs["P"], 10, (20, 20, 20))).json()["price"]
    assert heavy_but_small["basis"] == "WEIGHT" and heavy_but_small["total"] == 100000 + 500000
    tiny = p.post("/api/parcels/quote", json=parcel(hold_trip, tariffs["P"], 1, (10, 10, 10))).json()["price"]
    assert tiny["total"] == 300000                                 # the minimum charge
    letter = p.post("/api/parcels/quote", json=parcel(hold_trip, tariffs["L"], 0.2, (30, 22, 1))).json()["price"]
    assert letter["mode"] == "FIXED" and letter["total"] == 250000
    r = p.post("/api/parcels/quote", json=parcel(hold_trip, tariffs["L"], 2, (30, 22, 1)))
    assert r.status_code == 409 and r.json()["error"]["code"] == "PARCEL_TOO_HEAVY"


def test_a_booking_takes_hold_space_before_the_money_and_never_twice(owner, hold_trip, tariffs):
    p = customer()
    before = p.get("/api/wallet").json()["balance"]
    body = booking(hold_trip, tariffs["P"], 12, (30, 30, 30))
    r = p.post("/api/parcels", json=body)
    assert r.status_code == 201, r.text
    first = r.json()
    assert first["price"]["total"] == 100000 + 600000 and not first["replayed"]
    again = p.post("/api/parcels", json=body).json()
    assert again["replayed"] and again["tracking_no"] == first["tracking_no"]
    assert p.get("/api/wallet").json()["balance"] == before - first["price"]["total"]       # charged once
    row = owner_sql("""SELECT s.guaranteed, l.trip_id IS NOT NULL AS on_trip, l.status FROM ship.shipment s
                        JOIN ship.shipment_leg l ON l.shipment_id = s.id WHERE s.tracking_no = $1""", first["tracking_no"], fetch=True)
    assert row["guaranteed"] and row["on_trip"] and row["status"] == "BOOKED"
    on_board = owner.get(f"/api/carrier/trips/{hold_trip['uid']}/hold").json()
    assert any(x["tracking_no"] == first["tracking_no"] for x in on_board["parcels"])
    mine = p.get("/api/parcels/mine").json()["parcels"]
    assert mine[0]["tracking_no"] == first["tracking_no"] and mine[0]["guaranteed"] and mine[0]["volume_m3"] == 0.027

    # more than the hold has left: refused, and nothing is charged
    free = on_board["hold"]["free_weight_kg"]
    balance = p.get("/api/wallet").json()["balance"]
    r = p.post("/api/parcels", json=booking(hold_trip, tariffs["P"], min(free + 1, 40), (30, 30, 30)))
    assert r.status_code == 409 and r.json()["error"]["code"] == "CARGO_CAPACITY", r.text
    assert p.get("/api/wallet").json()["balance"] == balance


def test_two_customers_for_the_last_space_one_gets_it(owner, hold_trip, tariffs):
    free = owner.get(f"/api/carrier/trips/{hold_trip['uid']}/hold").json()["hold"]["free_weight_kg"]
    if free < 2:
        pytest.skip("the hold of this trip is full from earlier runs")
    kg = min(round(free * 0.6, 1), 40)                             # either fits alone, both do not
    a, b = customer(), customer()
    results = []

    def go(c):
        results.append(c.post("/api/parcels", json=booking(hold_trip, tariffs["P"], kg, (20, 20, 20))))

    threads = [threading.Thread(target=go, args=(c,)) for c in (a, b)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    codes = sorted(r.status_code for r in results)
    assert codes == [201, 409], [r.text for r in results]
    assert next(r for r in results if r.status_code == 409).json()["error"]["code"] == "CARGO_CAPACITY"


def test_a_price_agreed_with_the_carrier(owner, hold_trip, tariffs):
    p = customer()
    r = p.post("/api/parcels", json=booking(hold_trip, tariffs["V"], 1, (20, 10, 5)))
    assert r.status_code == 409 and r.json()["error"]["code"] == "PRICE_BY_AGREEMENT"
    r = p.post("/api/parcels/offers", json=parcel(hold_trip, tariffs["V"], 1, (20, 10, 5), description="Signed contract papers"))
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    accept = {"recipient_name": "Lina Haddad", "recipient_mobile": "+963944555666", "idempotency_key": uuid.uuid4().hex}
    assert p.post(f"/api/parcels/offers/{uid}/accept", json=accept).json()["error"]["code"] == "OFFER_NOT_OPEN"   # no price yet
    waiting = owner.get("/api/carrier/parcels/offers", params={"status": "REQUESTED"}).json()["offers"]
    assert any(o["uid"] == uid and o["weight_kg"] == 1 for o in waiting)
    r = owner.post(f"/api/carrier/parcels/offers/{uid}/price", json={"price": 900000, "valid_hours": 6, "note": "Handed to the driver"})
    assert r.status_code == 200 and r.json()["status"] == "OFFERED", r.text
    assert p.get("/api/parcels/offers").json()["offers"][0]["price"] == 900000
    before = p.get("/api/wallet").json()["balance"]
    r = p.post(f"/api/parcels/offers/{uid}/accept", json=accept)
    assert r.status_code == 201, r.text
    assert r.json()["price"]["total"] == 900000 and r.json()["price"]["basis"] == "AGREED"
    assert p.get("/api/wallet").json()["balance"] == before - 900000
    assert p.post(f"/api/parcels/offers/{uid}/withdraw").status_code == 409
    other = new_passenger()
    assert other.post(f"/api/parcels/offers/{uid}/accept", json=accept).status_code == 404       # someone else's offer


def test_the_database_refuses_a_guaranteed_shipment_without_capacity():
    with pytest.raises(Exception) as err:
        owner_sql("""INSERT INTO ship.shipment (tracking_no, company_id, shipper_party_id, service_id, origin_station_id, dest_station_id,
                        guaranteed)
                     SELECT 'GX' || substr(md5(random()::text), 1, 10), c.id, (SELECT min(id) FROM iam.party WHERE party_type = 'PERSON'),
                            (SELECT min(id) FROM ship.service_product), (SELECT min(id) FROM net.station), (SELECT max(id) FROM net.station), true
                       FROM iam.company c ORDER BY c.id LIMIT 1""")
    assert "CAPACITY_REQUIRED" in str(err.value)

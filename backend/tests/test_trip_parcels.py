"""Parcels on scheduled trips (owner's decision N5; migration 1147): a switch of their own, the platform's policy
(carriers by type, scheduled trips only, prohibited items, the shortest hand-over time, who decides the fees), each
carrier's choices and drop-off points, a reservation without payment in phase one that is paid in cash when handed
over or released when its time passes, the counter sale and the signed label."""
import uuid

import pytest

from app.security import verify_parcel_label
from test_e2e import OWNER_URL, bookable_trip, login, new_passenger, owner_sql, publish_fresh_trip

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def owner():
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def setup(admin, owner):
    """The switch on, a tariff, a trip with hold space; the policy and the carrier's choices put back after."""
    was = next(m["enabled"] for m in admin.get("/api/admin/modules").json()["modules"] if m["key"] == "trip_parcels")
    if not was:
        assert admin.put("/api/admin/modules/trip_parcels", json={"enabled": True, "reason": "parcel tests"}).status_code == 200
    policy = admin.get("/api/admin/parcels/policy").json()
    settings = owner.get("/api/carrier/parcels/settings").json()
    t = owner.post("/api/carrier/parcels/tariffs", json={"code": f"TP{uuid.uuid4().hex[:5].upper()}", "name": "Parcel by weight",
                                                         "pricing_mode": "WEIGHT", "currency": "SYP", "per_kg": 50000, "max_weight_kg": 30})
    assert t.status_code == 201, t.text
    pax = new_passenger()
    trip = bookable_trip(pax)
    if trip is None:
        publish_fresh_trip()
        trip = bookable_trip(pax)
    owner_sql("""UPDATE fleet.vehicle SET cargo_capacity_kg = greatest(coalesce(cargo_capacity_kg, 0), 2000)
                  WHERE id = (SELECT vehicle_id FROM ops.trip WHERE uid = $1)""", uuid.UUID(trip["uid"]))
    hold = owner.get(f"/api/carrier/trips/{trip['uid']}/hold").json()["hold"]
    used = (hold["max_weight_kg"] - hold["free_weight_kg"]) if hold else 0
    assert owner.put(f"/api/carrier/trips/{trip['uid']}/hold", json={"max_weight_kg": used + 60}).status_code == 200
    yield {"tariff": t.json(), "trip": trip, "policy": policy}
    admin.put("/api/admin/parcels/policy", json={**policy, "reason": "back to the default"})
    owner.put("/api/carrier/parcels/settings", json={k: settings[k] for k in ("booking_mode", "handover_minutes", "cancel_fee", "no_show_fee")})
    if not was:
        admin.put("/api/admin/modules/trip_parcels", json={"enabled": False, "reason": "parcel tests done"})


def body(setup, **extra):
    trip = setup["trip"]
    return {"trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"], "tariff_uid": setup["tariff"]["uid"],
            "weight_kg": 4, "length_cm": 30, "width_cm": 20, "height_cm": 20, "description": "Clothes", "recipient_name": "Rami Saleh",
            "recipient_mobile": "+963944123456", "idempotency_key": uuid.uuid4().hex, **extra}


def policy(admin, setup, **change):
    r = admin.put("/api/admin/parcels/policy", json={**setup["policy"], **change, "reason": "parcel test"})
    assert r.status_code == 200, r.text
    return r.json()


def test_the_platform_sets_the_policy_and_scheduled_trips_alone_take_parcels(admin, owner, setup):
    assert setup["policy"]["scheduled_only"] is True and "WEAPONS" in setup["policy"]["prohibited"]
    assert owner.put("/api/admin/parcels/policy", json={**setup["policy"], "reason": "a carrier tries"}).status_code == 403
    pax = new_passenger()
    r = pax.post("/api/parcels", json=body(setup, accept_rules=True))          # a demo trip belongs to no regular trip
    assert r.status_code == 409 and r.json()["error"]["code"] == "PARCELS_SCHEDULED_ONLY", r.text
    policy(admin, setup, scheduled_only=False)
    rules = pax.get("/api/parcels/rules").json()
    assert rules["scheduled_only"] is False and rules["prohibited"]
    r = pax.post("/api/parcels", json=body(setup))                               # the sender's word on the prohibited items
    assert r.status_code == 422 and r.json()["error"]["code"] == "PROHIBITED_ITEMS_ACK" and r.json()["error"]["prohibited"], r.text


def test_the_carrier_chooses_how_parcels_are_booked_and_where_they_are_handed_over(admin, owner, setup):
    policy(admin, setup, scheduled_only=False)
    s = owner.get("/api/carrier/parcels/settings").json()
    assert s["allowed"] and s["min_handover_minutes"] == 60
    r = owner.put("/api/carrier/parcels/settings", json={"booking_mode": "ONLINE_DROPOFF", "handover_minutes": 30, "cancel_fee": 0, "no_show_fee": 0})
    assert r.status_code == 422 and r.json()["error"]["code"] == "HANDOVER_TOO_SHORT"
    r = owner.post("/api/carrier/parcels/points", json={"kind": "OFFICE", "name": "Baramkeh office", "address": "Baramkeh, Damascus",
                                                        "hours": "Daily 08:00-20:00", "phone": "+963112233445"})
    assert r.status_code == 201, r.text
    point = r.json()["uid"]
    assert any(p["uid"] == point for p in owner.get("/api/carrier/parcels/points").json()["points"])
    # counter only: no online booking
    assert owner.put("/api/carrier/parcels/settings", json={"booking_mode": "COUNTER_ONLY", "handover_minutes": 120,
                                                            "cancel_fee": 0, "no_show_fee": 0}).status_code == 200
    r = new_passenger().post("/api/parcels", json=body(setup, accept_rules=True))
    assert r.status_code == 409 and r.json()["error"]["code"] == "PARCELS_COUNTER_ONLY", r.text
    assert owner.put("/api/carrier/parcels/settings", json={"booking_mode": "ONLINE_DROPOFF", "handover_minutes": 120,
                                                            "cancel_fee": 0, "no_show_fee": 0}).status_code == 200
    assert owner.post(f"/api/carrier/parcels/points/{point}/close").json()["status"] == "CLOSED"


def test_phase_one_reserves_without_payment_then_the_counter_receives_and_labels(admin, owner, setup):
    policy(admin, setup, scheduled_only=False)
    pt = owner.post("/api/carrier/parcels/points", json={"kind": "OFFICE", "name": "Mazzeh office", "address": "Mazzeh, Damascus",
                                                         "hours": "08:00-18:00"}).json()["uid"]
    pax = new_passenger()
    try:
        assert admin.put("/api/admin/money-mode", json={"mode": "NO_FUNDS", "basis": "Phase one of the pilot"}).status_code == 200
        r = pax.post("/api/parcels", json=body(setup, accept_rules=True, drop_point_uid=pt))
        assert r.status_code == 201, r.text
        out = r.json()
        assert out["status"] == "EXPECTED" and out["handover_by"]
        assert owner_sql("SELECT paid_at IS NULL AND pay_method IS NULL FROM ship.shipment WHERE tracking_no = $1", out["tracking_no"]) is True
        assert any(p["tracking_no"] == out["tracking_no"] for p in owner.get("/api/carrier/parcels/awaiting").json()["parcels"])
        assert owner.get(f"/api/carrier/parcels/{out['tracking_no']}/label").json()["error"]["code"] == "NOT_HANDED_OVER"
        label = owner.post(f"/api/carrier/parcels/{out['tracking_no']}/receive", json={"weight_kg": 4.5})
        assert label.status_code == 200, label.text
        label = label.json()
        assert label["status"] == "CREATED" and label["pay_method"] == "CASH" and label["weight_kg"] == 4.5
        assert verify_parcel_label(label["code"]) == (out["tracking_no"], label["label_no"])
        assert verify_parcel_label(label["code"].replace(out["tracking_no"], "MB0000000000")) is None     # an altered label fails
        r = owner.post(f"/api/carrier/parcels/{out['tracking_no']}/receive", json={})
        assert r.status_code == 409 and r.json()["error"]["code"] == "ALREADY_HANDED_OVER"
    finally:
        assert admin.put("/api/admin/money-mode", json={"mode": "FULL", "basis": "back to the test default"}).status_code == 200


def test_a_reservation_not_handed_over_in_time_is_released(admin, owner, setup):
    policy(admin, setup, scheduled_only=False)
    pax = new_passenger()
    try:
        assert admin.put("/api/admin/money-mode", json={"mode": "NO_FUNDS", "basis": "Phase one of the pilot"}).status_code == 200
        late = pax.post("/api/parcels", json=body(setup, accept_rules=True)).json()["tracking_no"]
        kept = pax.post("/api/parcels", json=body(setup, accept_rules=True)).json()["tracking_no"]
        mine = pax.post("/api/parcels", json=body(setup, accept_rules=True)).json()["tracking_no"]
    finally:
        admin.put("/api/admin/money-mode", json={"mode": "FULL", "basis": "back to the test default"})
    owner_sql("UPDATE ship.shipment SET handover_by = now() - interval '1 minute' WHERE tracking_no = $1", late)
    assert owner_sql("SELECT ship.release_unhanded_parcels()") >= 1
    assert owner_sql("SELECT status || ':' || release_reason FROM ship.shipment WHERE tracking_no = $1", late) == "CANCELLED:NOT_HANDED_OVER"
    assert owner_sql("SELECT count(*) FROM ship.shipment_leg l JOIN ship.shipment s ON s.id = l.shipment_id "
                     "WHERE s.tracking_no = $1 AND l.status = 'CANCELLED'", late) == 1          # its hold is free again
    assert owner_sql("SELECT status FROM ship.shipment WHERE tracking_no = $1", kept) == "EXPECTED"
    assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'parcel.released' AND payload ->> 'tracking_no' = $1", late) == 1
    # the sender cancels a reservation not handed over
    assert pax.post(f"/api/parcels/{mine}/cancel").json()["status"] == "CANCELLED"
    assert pax.post(f"/api/parcels/{mine}/cancel").json()["error"]["code"] == "PARCEL_NOT_RESERVED"


def test_the_counter_sells_a_parcel_paid_in_cash_with_its_label(admin, owner, setup):
    policy(admin, setup, scheduled_only=False)
    b = body(setup, sender_name="Hala Khoury")
    r = owner.post("/api/carrier/parcels/counter", json=b)
    assert r.status_code == 422 and r.json()["error"]["code"] == "PROHIBITED_ITEMS_ACK"
    r = owner.post("/api/carrier/parcels/counter", json={**b, "accept_rules": True})
    assert r.status_code == 201, r.text
    out = r.json()
    assert out["label"]["pay_method"] == "CASH" and out["label"]["sender_name"] == "Hala Khoury" and out["label"]["handed_over_at"]
    assert owner.post("/api/carrier/parcels/counter", json={**b, "accept_rules": True}).json()["replayed"] is True   # same key, one parcel
    assert new_passenger().post("/api/carrier/parcels/counter", json={**b, "accept_rules": True}).status_code == 403


def test_the_platform_stops_a_carrier_and_decides_its_fees_when_it_regulates_them(admin, owner, setup):
    policy(admin, setup, scheduled_only=False)
    carrier_uid = owner.get("/api/auth/me").json()["company"]["uid"]
    try:
        assert admin.put(f"/api/admin/parcels/carriers/{carrier_uid}/stop", json={"stopped": True, "reason": "Complaints under review"}).status_code == 200
        r = new_passenger().post("/api/parcels", json=body(setup, accept_rules=True))
        assert r.status_code == 409 and r.json()["error"]["code"] == "PARCELS_NOT_OFFERED" and r.json()["error"]["reason"] == "STOPPED", r.text
        assert owner.get("/api/carrier/parcels/settings").json()["not_allowed_reason"] == "STOPPED"
    finally:
        assert admin.put(f"/api/admin/parcels/carriers/{carrier_uid}/stop", json={"stopped": False, "reason": "Review closed"}).status_code == 200
    # while the platform regulates the fees, a carrier's new fees wait for its decision
    policy(admin, setup, scheduled_only=False, fee_policy="PLATFORM")
    base = {"booking_mode": "ONLINE_DROPOFF", "handover_minutes": 120}
    before = owner.get("/api/carrier/parcels/settings").json()
    s = owner.put("/api/carrier/parcels/settings", json={**base, "cancel_fee": 50000, "no_show_fee": 70000}).json()
    assert s["pending_fees"] == {"cancel_fee": 50000, "no_show_fee": 70000} and s["cancel_fee"] == before["cancel_fee"]
    listed = next(c for c in admin.get("/api/admin/parcels/carriers").json()["carriers"] if c["uid"] == carrier_uid)
    assert listed["pending_fees"]["cancel_fee"] == 50000
    assert admin.post(f"/api/admin/parcels/carriers/{carrier_uid}/fees", json={"approve": True, "reason": "Within the cap"}).status_code == 200
    s = owner.get("/api/carrier/parcels/settings").json()
    assert (s["cancel_fee"], s["no_show_fee"], s["pending_fees"]) == (50000, 70000, None)
    assert admin.post(f"/api/admin/parcels/carriers/{carrier_uid}/fees", json={"approve": True, "reason": "again"}).json()["error"]["code"] == "NO_PENDING_FEES"

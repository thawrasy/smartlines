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


ID = {"doc_kind": "NATIONAL_ID", "doc_no": "0123456714471", "holder_name": "Rami Saleh", "issued_by": "Homs civil registry"}


def handed_over(admin, owner, setup, pax):
    """A parcel the sender reserved and handed over at the counter: its tracking number and label code."""
    policy(admin, setup, scheduled_only=False)
    try:
        assert admin.put("/api/admin/money-mode", json={"mode": "NO_FUNDS", "basis": "Phase one of the pilot"}).status_code == 200
        r = pax.post("/api/parcels", json=body(setup, accept_rules=True))
        assert r.status_code == 201, r.text
        no = r.json()["tracking_no"]
        label = owner.post(f"/api/carrier/parcels/{no}/receive", json={})
        assert label.status_code == 200, label.text
    finally:
        admin.put("/api/admin/money-mode", json={"mode": "FULL", "basis": "back to the test default"})
    return no, label.json()["code"]


def test_the_parcel_is_loaded_arrives_and_is_collected_with_the_senders_code(admin, owner, setup):
    """1182: on board by its label, off at the destination, the code to the sender and the recipient, wrong codes counted,
    then handed over with the right one; each step a milestone the sender reads."""
    pax = new_passenger()
    no, code = handed_over(admin, owner, setup, pax)
    r = owner.post("/api/carrier/parcels/scan/arrive", json={"tracking_no": no})
    assert r.status_code == 409 and r.json()["error"]["code"] == "PARCEL_NOT_LOADED"
    assert owner.post("/api/carrier/parcels/scan/load", json={"code": code[:-3] + "AAA"}).json()["error"]["code"] in ("LABEL_INVALID", "VALIDATION")
    r = owner.post("/api/carrier/parcels/scan/load", json={"code": code, "trip_uid": str(uuid.uuid4())})
    assert r.status_code == 409 and r.json()["error"]["code"] == "PARCEL_OTHER_TRIP"
    r = owner.post("/api/carrier/parcels/scan/load", json={"code": code, "trip_uid": setup["trip"]["uid"]})
    assert r.status_code == 200 and r.json()["status"] == "IN_NETWORK", r.text
    assert owner.post("/api/carrier/parcels/scan/load", json={"code": code}).json()["error"]["code"] == "PARCEL_ON_BOARD"
    j = pax.get(f"/api/parcels/{no}/journey").json()
    assert j["loaded_at"] and j["pickup_code"] is None
    r = owner.post("/api/carrier/parcels/scan/arrive", json={"code": code})
    assert r.status_code == 200 and r.json()["waits_days"] >= 1, r.text
    j = pax.get(f"/api/parcels/{no}/journey").json()
    pin = j["pickup_code"]
    assert len(pin) == 6 and pin.isdigit()
    assert [e["milestone"] for e in j["events"]][-2:] == ["LOADED", "ARRIVED"]
    assert new_passenger().get(f"/api/parcels/{no}/journey").status_code == 404           # another passenger sees nothing
    assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'parcel.arrived' AND payload ->> 'tracking_no' = $1", no) == 1
    assert owner_sql("SELECT position($2 in payload::text) FROM sys.outbox_event WHERE event_type = 'parcel.arrived' "
                     "AND payload ->> 'tracking_no' = $1", no, pin) == 0                    # the code never sits in the outbox
    waiting = owner.get("/api/carrier/parcels/waiting").json()
    row = next(p for p in waiting["parcels"] if p["tracking_no"] == no)
    assert row["overdue"] is False and row["days_waited"] == 0
    # a refused or unclaimed parcel needs the days to pass; a wrong code is counted
    r = owner.post(f"/api/carrier/parcels/{no}/exception", json={"kind": "UNCLAIMED", "note": "nobody came"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "PARCEL_NOT_OVERDUE"
    wrong = "000000" if pin != "000000" else "111111"
    r = owner.post(f"/api/carrier/parcels/{no}/deliver", json={"pickup_code": wrong, "delivered_to": "Rami Saleh"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "PICKUP_CODE_WRONG" and r.json()["error"]["tries_left"] == 4
    assert owner.post(f"/api/carrier/parcels/{no}/deliver", json={"delivered_to": "Rami Saleh"}).status_code == 422
    r = owner.post(f"/api/carrier/parcels/{no}/deliver", json={"pickup_code": pin, "delivered_to": "Rami Saleh"})
    assert r.status_code == 200 and r.json()["method"] == "OTP", r.text
    assert owner.post(f"/api/carrier/parcels/{no}/deliver", json={"pickup_code": pin, "delivered_to": "Rami"}).json()["error"]["code"] \
        == "PARCEL_NOT_WAITING"
    assert owner_sql("SELECT p.method || ':' || s.status FROM ship.delivery_proof p JOIN ship.shipment s ON s.id = p.shipment_id "
                     "WHERE s.tracking_no = $1", no) == "OTP:DELIVERED"
    j = pax.get(f"/api/parcels/{no}/journey").json()
    assert j["status"] == "DELIVERED" and j["pickup_code"] is None and j["events"][-1]["milestone"] == "DELIVERED"
    assert not any(p["tracking_no"] == no for p in owner.get("/api/carrier/parcels/waiting").json()["parcels"])


def test_locked_codes_need_an_identity_check_and_an_unclaimed_parcel_goes_back(admin, owner, setup):
    pax = new_passenger()
    no, code = handed_over(admin, owner, setup, pax)
    assert owner.post("/api/carrier/parcels/scan/load", json={"tracking_no": no}).status_code == 200
    assert owner.post("/api/carrier/parcels/scan/arrive", json={"tracking_no": no}).status_code == 200
    owner_sql("UPDATE ship.shipment SET pickup_code_tries = 5 WHERE tracking_no = $1", no)
    pin = pax.get(f"/api/parcels/{no}/journey").json()["pickup_code"]
    r = owner.post(f"/api/carrier/parcels/{no}/deliver", json={"pickup_code": pin, "delivered_to": "Rami Saleh"})
    assert r.status_code == 423 and r.json()["error"]["code"] == "PICKUP_CODE_LOCKED"
    # not collected within the policy's days: recorded as unclaimed, then sent back
    owner_sql("UPDATE ship.shipment SET arrived_at = arrived_at - interval '30 days' WHERE tracking_no = $1", no)
    assert next(p for p in owner.get("/api/carrier/parcels/waiting").json()["parcels"] if p["tracking_no"] == no)["overdue"] is True
    assert owner.post(f"/api/carrier/parcels/{no}/return", json={"note": "back to the sender"}).json()["error"]["code"] == "PARCEL_NO_EXCEPTION"
    r = owner.post(f"/api/carrier/parcels/{no}/exception", json={"kind": "UNCLAIMED", "note": "nobody came in thirty days"})
    assert r.status_code == 200 and r.json()["status"] == "EXCEPTION", r.text
    assert pax.get(f"/api/parcels/{no}/journey").json()["pickup_code"] is None
    r = owner.post(f"/api/carrier/parcels/{no}/return", json={"note": "back to the sender"})
    assert r.status_code == 200 and r.json()["status"] == "RETURNED"
    assert owner.post(f"/api/carrier/parcels/{no}/deliver", json={"id_check": ID, "delivered_to": "Rami"}).json()["error"]["code"] \
        == "PARCEL_NOT_WAITING"
    assert [e["milestone"] for e in pax.get(f"/api/parcels/{no}/journey").json()["events"]][-2:] == ["EXCEPTION", "RETURNED"]


def test_an_identity_check_hands_over_a_parcel_whose_code_is_lost_and_damage_is_recorded(admin, owner, setup):
    pax = new_passenger()
    no, _ = handed_over(admin, owner, setup, pax)
    damaged, _ = handed_over(admin, owner, setup, pax)
    for n in (no, damaged):
        assert owner.post("/api/carrier/parcels/scan/load", json={"tracking_no": n}).status_code == 200
    r = owner.post(f"/api/carrier/parcels/{damaged}/exception", json={"kind": "REFUSED", "note": "not yet at the station"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "PARCEL_NOT_WAITING"
    r = owner.post(f"/api/carrier/parcels/{damaged}/exception", json={"kind": "DAMAGED", "note": "box crushed in the hold"})
    assert r.status_code == 200, r.text
    assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'parcel.exception' AND payload ->> 'tracking_no' = $1", damaged) == 1
    assert owner.post("/api/carrier/parcels/scan/arrive", json={"tracking_no": no}).status_code == 200
    r = owner.post(f"/api/carrier/parcels/{no}/deliver", json={"id_check": ID, "delivered_to": "Rami Saleh"})
    assert r.status_code == 200 and r.json()["method"] == "ID" and r.json()["id_checked"] is True, r.text
    row = owner_sql("SELECT c.doc_kind, c.doc_last4, c.holder_name, c.issued_by, position('01234567' in encode(c.doc_no_enc, 'escape')) AS plain "
                    "FROM ship.parcel_id_check c JOIN ship.shipment s ON s.id = c.shipment_id WHERE s.tracking_no = $1", no, fetch=True)
    assert (row["doc_kind"], row["doc_last4"], row["holder_name"], row["issued_by"], row["plain"]) == \
        ("NATIONAL_ID", "4471", "Rami Saleh", "Homs civil registry", 0)                  # the number itself is encrypted
    assert pax.get(f"/api/parcels/{no}/journey").json()["id_check"] == {"kind": "NATIONAL_ID", "last4": "4471", "holder": "Rami Saleh"}
    assert new_passenger().post(f"/api/carrier/parcels/{no}/deliver", json={"id_check": ID, "delivered_to": "Someone"}).status_code == 403


def counter_parcel(owner, setup, **extra) -> tuple[str, str]:
    """A parcel sold and handed over at the counter: its tracking number and label code."""
    r = owner.post("/api/carrier/parcels/counter", json={**body(setup, sender_name="Hala Khoury", accept_rules=True), **extra})
    assert r.status_code == 201, r.text
    return r.json()["tracking_no"], r.json()["label"]["code"]


def point(owner, name: str) -> str:
    r = owner.post("/api/carrier/parcels/points", json={"kind": "OFFICE", "name": name, "address": f"{name} street", "hours": "08:00-20:00"})
    assert r.status_code in (200, 201), r.text
    return r.json()["uid"]


def test_the_parcel_passes_through_the_carriers_locations_in_order(admin, owner, setup):
    """1183: received at B, sent on to C, received at C, sent on to the destination; a wrong location and skipping the
    sending-on are refused; every location is a step the carrier's list and the tracking show."""
    policy(admin, setup, scheduled_only=False)
    no, code = counter_parcel(owner, setup)
    b, c, d = point(owner, "Homs office"), point(owner, "Hama office"), point(owner, "Idlib office")
    r = owner.post("/api/carrier/parcels/scan/receive", json={"tracking_no": no, "point_uid": b})
    assert r.status_code == 409 and r.json()["error"]["code"] == "PARCEL_NOT_LOADED"
    assert owner.post("/api/carrier/parcels/scan/load", json={"code": code}).status_code == 200
    assert owner.post("/api/carrier/parcels/scan/dispatch", json={"tracking_no": no}).json()["error"]["code"] == "PARCEL_NOT_AT_LOCATION"
    r = owner.post("/api/carrier/parcels/scan/receive", json={"code": code, "point_uid": b})
    assert r.status_code == 200 and r.json()["location"] == "Homs office", r.text
    assert any(p["tracking_no"] == no for p in owner.get("/api/carrier/parcels/waiting").json()["at_locations"])
    assert owner.post("/api/carrier/parcels/scan/receive", json={"tracking_no": no, "point_uid": c}).json()["error"]["code"] \
        == "PARCEL_AT_LOCATION"
    assert owner.post("/api/carrier/parcels/scan/arrive", json={"tracking_no": no}).json()["error"]["code"] == "PARCEL_AT_LOCATION"
    assert owner.post("/api/carrier/parcels/scan/dispatch", json={"tracking_no": no, "next_point_uid": b}).json()["error"]["code"] \
        == "SAME_LOCATION"
    r = owner.post("/api/carrier/parcels/scan/dispatch", json={"tracking_no": no, "next_point_uid": c})
    assert r.status_code == 200 and r.json()["to"] == "Hama office", r.text
    r = owner.post("/api/carrier/parcels/scan/receive", json={"tracking_no": no, "point_uid": d})
    assert r.status_code == 409 and r.json()["error"]["code"] == "PARCEL_OTHER_LOCATION" and r.json()["error"]["expected"] == "Hama office"
    assert owner.post("/api/carrier/parcels/scan/receive", json={"tracking_no": no, "point_uid": c}).status_code == 200
    assert owner.post("/api/carrier/parcels/scan/dispatch", json={"tracking_no": no}).status_code == 200
    assert owner.post("/api/carrier/parcels/scan/arrive", json={"tracking_no": no}).status_code == 200
    hops = owner_sql("SELECT string_agg(p.name, ' > ' ORDER BY h.seq) FROM ship.parcel_hop h JOIN ship.parcel_point p ON p.id = h.point_id "
                     "JOIN ship.shipment s ON s.id = h.shipment_id WHERE s.tracking_no = $1", no)
    assert hops == "Homs office > Hama office"
    assert owner_sql("SELECT count(*) FROM ship.tracking_event e JOIN ship.shipment s ON s.id = e.shipment_id "
                     "WHERE s.tracking_no = $1 AND e.milestone IN ('RECEIVED_AT_HUB', 'DEPARTED')", no) == 4
    assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'parcel.moved' AND payload ->> 'tracking_no' = $1", no) == 3


def test_the_clerk_sends_the_code_again_a_few_times_at_most(admin, owner, setup):
    policy(admin, setup, scheduled_only=False)
    no, code = counter_parcel(owner, setup)
    assert owner.post(f"/api/carrier/parcels/{no}/send-code").json()["error"]["code"] == "PARCEL_NOT_WAITING"
    owner.post("/api/carrier/parcels/scan/load", json={"code": code})
    owner.post("/api/carrier/parcels/scan/arrive", json={"code": code})
    for left in (2, 1, 0):
        r = owner.post(f"/api/carrier/parcels/{no}/send-code")
        assert r.status_code == 200 and r.json()["sends_left"] == left, r.text
    r = owner.post(f"/api/carrier/parcels/{no}/send-code")
    assert r.status_code == 429 and r.json()["error"]["code"] == "CODE_SENDS_SPENT"
    assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'parcel.code_sent' AND payload ->> 'tracking_no' = $1", no) == 3
    assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type LIKE 'parcel.%' AND payload ->> 'tracking_no' = $1 "
                     "AND payload::text ~ '\"pickup_code\"'", no) == 0                 # the code never sits in the outbox


def test_a_parcel_taken_to_an_address_gets_its_code_when_it_leaves(admin, owner, setup):
    """The carrier switches delivery to an address on; arrival is announced without a code, the code goes out with the
    courier, a failed attempt withdraws it and the next departure issues a new one."""
    policy(admin, setup, scheduled_only=False)
    settings = owner.get("/api/carrier/parcels/settings").json()
    keep = {k: settings[k] for k in ("booking_mode", "handover_minutes", "cancel_fee", "no_show_fee")}
    r = owner.post("/api/carrier/parcels/counter", json={**body(setup, sender_name="Hala Khoury", accept_rules=True),
                                                         "delivery_mode": "ADDRESS", "delivery_address": "Hama, Al-Hader street 12"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "NO_ADDRESS_DELIVERY"
    assert owner.put("/api/carrier/parcels/settings", json={**keep, "address_delivery": True, "address_fee": 250000}).status_code == 200
    try:
        r = owner.post("/api/carrier/parcels/counter", json={**body(setup, sender_name="Hala Khoury", accept_rules=True), "delivery_mode": "ADDRESS"})
        assert r.status_code == 422 and r.json()["error"]["code"] == "ADDRESS_REQUIRED"
        plain = owner.post("/api/carrier/parcels/counter", json=body(setup, sender_name="Hala Khoury", accept_rules=True)).json()
        no, code = counter_parcel(owner, setup, delivery_mode="ADDRESS", delivery_address="Hama, Al-Hader street 12")
        fee = owner_sql("SELECT (price_breakdown ->> 'address_fee')::bigint FROM ship.shipment WHERE tracking_no = $1", no)
        assert fee == 250000 and plain["price"].get("address_fee") is None
        owner.post("/api/carrier/parcels/scan/load", json={"code": code})
        assert owner.post("/api/carrier/parcels/scan/arrive", json={"code": code}).json()["delivery_mode"] == "ADDRESS"
        assert owner_sql("SELECT pickup_code_hash IS NULL FROM ship.shipment WHERE tracking_no = $1", no) is True
        assert owner.post(f"/api/carrier/parcels/{no}/send-code").json()["error"]["code"] == "NO_CODE_YET"
        assert owner.post(f"/api/carrier/parcels/{no}/deliver", json={"id_check": ID, "delivered_to": "Rami Saleh"}).json()["error"]["code"] \
            == "PARCEL_NOT_OUT"
        r = owner.post(f"/api/carrier/parcels/{no}/out")
        assert r.status_code == 200 and r.json()["status"] == "OUT_FOR_DELIVERY", r.text
        assert owner.post(f"/api/carrier/parcels/{no}/out").json()["error"]["code"] == "PARCEL_OUT"
        first = owner_sql("SELECT pickup_code_hash FROM ship.shipment WHERE tracking_no = $1", no)
        r = owner.post(f"/api/carrier/parcels/{no}/attempt-failed", json={"reason": "NOBODY_HOME"})
        assert r.status_code == 200 and r.json()["status"] == "IN_NETWORK"
        assert owner_sql("SELECT result || ':' || reason_code FROM ship.delivery_attempt a JOIN ship.shipment s ON s.id = a.shipment_id "
                         "WHERE s.tracking_no = $1", no) == "FAILED:NOBODY_HOME"
        assert owner.post(f"/api/carrier/parcels/{no}/out").status_code == 200
        assert owner_sql("SELECT pickup_code_hash FROM ship.shipment WHERE tracking_no = $1", no) != first     # a new code
        assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'parcel.out_for_delivery' "
                         "AND payload ->> 'tracking_no' = $1", no) == 2
        r = owner.post(f"/api/carrier/parcels/{no}/deliver", json={"id_check": ID, "delivered_to": "Rami Saleh"})
        assert r.status_code == 200 and r.json()["method"] == "ID", r.text
        assert owner_sql("SELECT array_agg(result ORDER BY attempt_no)::text FROM ship.delivery_attempt a JOIN ship.shipment s "
                         "ON s.id = a.shipment_id WHERE s.tracking_no = $1", no) == "{FAILED,DELIVERED}"
    finally:
        owner.put("/api/carrier/parcels/settings", json={**keep, "address_delivery": False, "address_fee": 0})


def test_an_important_parcel_needs_both_the_code_and_an_identity_check(admin, owner, setup):
    pax = new_passenger()
    policy(admin, setup, scheduled_only=False)
    try:
        assert admin.put("/api/admin/money-mode", json={"mode": "NO_FUNDS", "basis": "Phase one of the pilot"}).status_code == 200
        r = pax.post("/api/parcels", json=body(setup, accept_rules=True, secure=True))
        assert r.status_code == 201, r.text
        no = r.json()["tracking_no"]
        code = owner.post(f"/api/carrier/parcels/{no}/receive", json={}).json()["code"]
    finally:
        admin.put("/api/admin/money-mode", json={"mode": "FULL", "basis": "back to the test default"})
    owner.post("/api/carrier/parcels/scan/load", json={"code": code})
    owner.post("/api/carrier/parcels/scan/arrive", json={"code": code})
    assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'parcel.moved' AND (payload ->> 'secure')::boolean "
                     "AND payload ->> 'tracking_no' = $1", no) == 1            # its sender hears of every step
    pin = pax.get(f"/api/parcels/{no}/journey").json()["pickup_code"]
    r = owner.post(f"/api/carrier/parcels/{no}/deliver", json={"pickup_code": pin, "delivered_to": "Rami Saleh"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "ID_CHECK_REQUIRED"
    r = owner.post(f"/api/carrier/parcels/{no}/deliver", json={"id_check": ID, "delivered_to": "Rami Saleh"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "CODE_REQUIRED"
    r = owner.post(f"/api/carrier/parcels/{no}/deliver", json={"pickup_code": pin, "id_check": ID, "delivered_to": "Rami Saleh"})
    assert r.status_code == 200 and r.json()["method"] == "OTP" and r.json()["id_checked"] is True, r.text
    j = pax.get(f"/api/parcels/{no}/journey").json()
    assert j["secure"] is True and j["id_check"]["last4"] == "4471" and j["pickup_code"] is None

"""Charter (owner's request, October 2026; migration 1123): a carrier hires out vehicles apart from its trips and its
scheduled trips whole or in blocks, to tourism companies and, by special request, to travellers, on its own terms. The
customer asks, the carrier prices, the customer pays into escrow; a whole-trip charter takes its seats off sale; the
carrier is paid when the service is done, less the platform's commission; a cancellation refunds as the terms say."""
import secrets
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from test_e2e import OWNER_URL, client, day, login, new_passenger, owner_sql, syrian

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

POLICY = "Driver included; fuel included within 300 km a day; waiting over two hours is charged; no smoking."


def _carrier():
    return login("owner@carrier.test", "OPERATOR")


def _funded_agency():
    admin = login("admin@masslak.test", "PLATFORM")
    a = next(a for a in admin.get("/api/admin/agencies").json()["agencies"] if a["legal_name"] == "Demo Travel Agency")
    assert admin.post(f"/api/admin/agencies/{a['uid']}/agreement", json={
        "commission_bp": 500, "daily_limit": 10_000_000_000, "status": "ACTIVE", "reason": "charter test"}).status_code == 200
    assert admin.post(f"/api/admin/agencies/{a['uid']}/deposit", json={
        "amount": 700_000_000, "bank_reference": "TEST-CHARTER", "idempotency_key": uuid.uuid4().hex}).status_code == 200
    return login("agency@agency.test", "AGENCY")


def _wallet(agency) -> int:
    return agency.get("/api/agency/dashboard").json()["balance"]


def _fresh_trip(o) -> dict:
    """A trip of the carrier nobody has booked yet, on sale the day after tomorrow."""
    route = next(r for r in o.get("/api/carrier/routes").json()["routes"] if r["code"] == "DAM-ALP")
    layout = next(x for x in o.get("/api/carrier/seat-layouts").json()["layouts"] if x["total_seats"] == 44)
    plate = str(100000 + secrets.randbelow(900000))
    r = o.post("/api/carrier/vehicles", json={
        "plate_no": plate, "chassis_no": f"CHS-C{plate}", "vehicle_type": "COACH", "seat_layout_uid": layout["uid"],
        "insurance_no": f"POL-C{plate}", "insurer": "Test", "insurance_issue": "2026-01-01", "insurance_expiry": "2030-01-01"})
    assert r.status_code == 201, r.text
    vehicle = r.json()["uid"]
    r = o.post("/api/carrier/crew", json={"full_name": "Charter Driver", "email": f"driver{uuid.uuid4().hex[:8]}@example.com",
                                          "password": "fresh-crew-long-passphrase"})
    assert r.status_code == 201, r.text
    driver = r.json()["uid"]
    for _ in range(10):
        r = o.post("/api/carrier/trips", json={"route_uid": route["uid"], "vehicle_uid": vehicle, "driver_uid": driver,
                                               "departure_local": f"{day(3)}T{6 + secrets.randbelow(12):02d}:{secrets.randbelow(60):02d}:00"})
        if r.status_code != 409:
            break
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    trips = client().get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(3)}).json()["trips"]
    t = next((x for x in trips if x["uid"] == uid), None)
    if t is None:
        pytest.skip("the fresh trip is not on sale (approval needed)")
    return t | {"vehicle_uid": vehicle}


def test_a_tourism_company_hires_a_coach_apart_from_the_trips():
    o = _carrier()
    r = o.post("/api/carrier/charter/offers", json={
        "kind": "VEHICLE", "title": "Coach with driver, 45 seats", "vehicle_type": "COACH", "seats": 45, "vehicles": 3,
        "audience": ["AGENCY"], "price_basis": "PER_DAY", "price": 150_000_000, "currency": "SYP", "notice_hours": 24,
        "cancel_before_hours": 72, "cancel_refund_pct": 80, "base_city": "DAM", "policy": POLICY})
    assert r.status_code == 201, r.text
    offer = r.json()
    assert offer["audience"] == ["AGENCY"] and offer["carrier_name"]
    # a traveller does not see an offer made to tourism companies only, and cannot ask under it
    pax = new_passenger()
    assert offer["uid"] not in [x["uid"] for x in pax.get("/api/charter/offers").json()["offers"]]
    starts = (datetime.now(timezone.utc) + timedelta(days=5)).replace(microsecond=0)
    ask = {"offer_uid": offer["uid"], "contact_name": "Rami Haddad", "contact_mobile": "+963944000222", "from_city": "DAM", "to_city": "LTK",
           "starts_at": starts.isoformat(), "ends_at": (starts + timedelta(days=2)).isoformat(), "passengers": 80, "vehicles": 2,
           "itinerary": "Damascus - Latakia - Tartus and back", "idempotency_key": uuid.uuid4().hex}
    r = pax.post("/api/charter/requests", json={**ask, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 403 and r.json()["error"]["code"] == "OFFER_NOT_FOR_YOU", r.text

    agency = _funded_agency()
    assert offer["uid"] in [x["uid"] for x in agency.get("/api/agency/charter/offers", params={"kind": "VEHICLE"}).json()["offers"]]
    r = agency.post("/api/agency/charter/requests", json={**ask, "passengers": 91})
    assert r.status_code == 422 and r.json()["error"]["code"] == "TOO_MANY_PASSENGERS", r.text
    r = agency.post("/api/agency/charter/requests", json={**ask, "starts_at": (datetime.now(timezone.utc) + timedelta(hours=3)).isoformat(),
                                                            "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 422 and r.json()["error"]["code"] == "NOTICE_TOO_SHORT", r.text
    r = agency.post("/api/agency/charter/requests", json=ask)
    assert r.status_code == 201, r.text
    req = r.json()
    assert req["status"] == "REQUESTED" and req["kind"] == "VEHICLE" and req["ref"].startswith("CH")
    assert req["estimate"] == 150_000_000 * 2 * 2                                 # two coaches for two days
    assert agency.post("/api/agency/charter/requests", json=ask).json()["uid"] == req["uid"]        # sent again: the same request
    # the carrier's later changes do not change the terms the request was made under
    assert o.patch(f"/api/carrier/charter/offers/{offer['uid']}", json={"price": 170_000_000, "cancel_refund_pct": 50}).status_code == 200
    assert agency.get(f"/api/agency/charter/requests/{req['uid']}").json()["terms"]["cancel_refund_pct"] == 80

    # nothing can be accepted before the carrier prices it
    assert agency.post(f"/api/agency/charter/requests/{req['uid']}/accept").json()["error"]["code"] == "CHARTER_NOT_PRICED"
    mine = o.get("/api/carrier/charter/requests", params={"status": "REQUESTED"}).json()["requests"]
    assert req["uid"] in [x["uid"] for x in mine]
    r = o.post(f"/api/carrier/charter/requests/{req['uid']}/quote", json={"price": 560_000_000, "valid_hours": 24, "note": "Two 2024 coaches"})
    assert r.status_code == 200 and r.json()["status"] == "QUOTED" and r.json()["price"] == 560_000_000, r.text

    balance = _wallet(agency)
    r = agency.post(f"/api/agency/charter/requests/{req['uid']}/accept")
    assert r.status_code == 200 and r.json()["status"] == "CONFIRMED", r.text
    assert balance - _wallet(agency) == 560_000_000
    assert agency.post(f"/api/agency/charter/requests/{req['uid']}/accept").json()["replayed"] is True        # paid once
    assert owner_sql("""SELECT count(*) FROM fin.ledger_txn WHERE ref_type = 'charter_request' AND txn_type = 'CHARTER_PAY'
                         AND memo = $1""", req["ref"]) == 1
    # the carrier names the vehicle: one that runs a trip at that time is refused (1128), a free one is named
    vehicles = o.get("/api/carrier/vehicles").json()["vehicles"]
    assert vehicles
    coach = _new_vehicle(o)
    r = o.post(f"/api/carrier/charter/requests/{req['uid']}/vehicle", json={"vehicle_uid": coach["uid"]})
    assert r.status_code == 200 and r.json()["vehicle_plate"] == coach["plate_no"], r.text
    # done only once it has begun
    assert o.post(f"/api/carrier/charter/requests/{req['uid']}/complete").json()["error"]["code"] == "CHARTER_NOT_STARTED"

    # the tourism company cancels in time: 80% back, the rest to the carrier
    r = agency.post(f"/api/agency/charter/requests/{req['uid']}/cancel", json={"reason": "the group was postponed"})
    assert r.status_code == 200 and r.json()["status"] == "CANCELLED" and r.json()["refunded_amount"] == 448_000_000, r.text
    assert balance - _wallet(agency) == 112_000_000
    # the platform sees every carrier's requests
    seen = login("admin@masslak.test", "PLATFORM").get("/api/admin/charter/requests").json()
    assert req["uid"] in [x["uid"] for x in seen["requests"]] and seen["active_offers"] >= 1
    assert o.patch(f"/api/carrier/charter/offers/{offer['uid']}", json={"status": "ARCHIVED"}).status_code == 200


def test_a_whole_trip_charter_takes_its_seats_off_sale_and_pays_the_carrier_when_done():
    o = _carrier()
    t = _fresh_trip(o)
    r = o.post("/api/carrier/charter/offers", json={
        "kind": "WHOLE_TRIP", "title": "Our scheduled trips, whole or in blocks", "partial_seats": True, "min_seats": 10,
        "audience": ["AGENCY", "PASSENGER"], "price_basis": "PER_SEAT", "price": 2_000_000, "currency": "SYP", "notice_hours": 12,
        "cancel_before_hours": 48, "cancel_refund_pct": 100, "policy": "Blocks of ten seats or more; the whole trip on request."})
    assert r.status_code == 201, r.text
    offer = r.json()
    agency = _funded_agency()
    ask = {"offer_uid": offer["uid"], "contact_name": "Rami Haddad", "contact_mobile": "+963944000333", "trip_uid": t["uid"], "from_seq": t["from_seq"],
           "to_seq": t["to_seq"], "idempotency_key": uuid.uuid4().hex}
    r = agency.post("/api/agency/charter/requests", json={**ask, "seats": 4, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 422 and r.json()["error"]["code"] == "BLOCK_TOO_SMALL", r.text
    # a block of twelve seats
    r = agency.post("/api/agency/charter/requests", json={**ask, "seats": 12})
    assert r.status_code == 201 and r.json()["estimate"] == 24_000_000, r.text
    block = r.json()
    assert o.post(f"/api/carrier/charter/requests/{block['uid']}/quote", json={"price": 21_000_000}).status_code == 200
    left = t["seats_left"]
    r = agency.post(f"/api/agency/charter/requests/{block['uid']}/accept")
    assert r.status_code == 200 and r.json()["seats_held"] == 12, r.text
    after = next(x for x in client().get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(3)}).json()["trips"]
                 if x["uid"] == t["uid"])
    assert after["seats_left"] == left - 12
    # the whole trip is no longer free: a traveller's request for it is refused
    pax = new_passenger()
    r = pax.post("/api/charter/requests", json={**ask, "whole": True, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 409 and r.json()["error"]["code"] == "WHOLE_TRIP_TAKEN", r.text

    # the carrier cancels: the agency is refunded in full and the seats go back on sale
    balance = _wallet(agency)
    r = o.post(f"/api/carrier/charter/requests/{block['uid']}/cancel", json={"reason": "vehicle off the road"})
    assert r.status_code == 200 and r.json()["refunded_amount"] == 21_000_000 and r.json()["seats_held"] == 0, r.text
    assert _wallet(agency) - balance == 21_000_000
    back = next(x for x in client().get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(3)}).json()["trips"]
                if x["uid"] == t["uid"])
    assert back["seats_left"] == left

    # the whole trip, done: the carrier is paid less the platform's commission
    admin = login("admin@masslak.test", "PLATFORM")
    assert admin.put("/api/admin/charter/commission", json={"commission_bp": 500}).status_code == 200
    try:
        r = agency.post("/api/agency/charter/requests", json={**ask, "whole": True, "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 201 and r.json()["seats"] == left, r.text
        whole = r.json()
        assert o.post(f"/api/carrier/charter/requests/{whole['uid']}/quote", json={"price": 80_000_000}).status_code == 200
        assert agency.post(f"/api/agency/charter/requests/{whole['uid']}/accept").json()["seats_held"] == left
        owner_sql("UPDATE ops.trip_stop SET sched_dep = now() - interval '1 hour' WHERE trip_id = (SELECT id FROM ops.trip WHERE uid = $1::uuid) AND seq = $2",
                  t["uid"], t["from_seq"])
        r = o.post(f"/api/carrier/charter/requests/{whole['uid']}/complete")
        assert r.status_code == 200 and r.json()["status"] == "COMPLETED", r.text
        paid = owner_sql("""SELECT e.amount FROM fin.ledger_entry e JOIN fin.ledger_txn x ON x.id = e.txn_id JOIN fin.wallet w ON w.id = e.wallet_id
                             WHERE x.txn_type = 'CHARTER_RELEASE' AND x.memo = $1 AND w.wallet_type = 'COMMISSION'""", whole["ref"])
        assert paid == 4_000_000                                                         # 5% of 80,000.00
    finally:
        assert admin.put("/api/admin/charter/commission", json={"commission_bp": 0}).status_code == 200
    assert o.patch(f"/api/carrier/charter/offers/{offer['uid']}", json={"status": "ARCHIVED"}).status_code == 200


def test_a_traveller_asks_by_special_request_and_the_price_lapses():
    o = _carrier()
    r = o.post("/api/carrier/charter/offers", json={
        "kind": "VEHICLE", "title": "Minivan for families", "vehicle_type": "VAN", "seats": 12, "audience": ["PASSENGER"],
        "price_basis": "ON_REQUEST", "currency": "SYP", "notice_hours": 0, "policy": "By special request; priced per trip."})
    assert r.status_code == 201, r.text
    offer = r.json()
    pax = new_passenger()
    starts = datetime.now(timezone.utc) + timedelta(days=2)
    r = pax.post("/api/charter/requests", json={"offer_uid": offer["uid"], "contact_name": "Rami Haddad", "contact_mobile": "+963944000444", "from_city": "DAM",
                                                "to_city": "HMS", "starts_at": starts.isoformat(), "ends_at": (starts + timedelta(hours=8)).isoformat(),
                                                "passengers": 9, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201 and r.json()["estimate"] is None, r.text
    req = r.json()
    assert o.post(f"/api/carrier/charter/requests/{req['uid']}/quote", json={"price": 90_000_000, "valid_hours": 2}).status_code == 200
    owner_sql("UPDATE sales.charter_request SET valid_until = now() - interval '1 minute' WHERE uid = $1::uuid", req["uid"])
    assert pax.get("/api/charter/requests").json()["requests"][0]["status"] == "EXPIRED"
    r = pax.post(f"/api/charter/requests/{req['uid']}/accept")
    assert r.status_code == 409 and r.json()["error"]["code"] == "QUOTE_EXPIRED", r.text
    # another traveller sees nothing of it
    assert new_passenger().get(f"/api/charter/requests/{req['uid']}").status_code == 404
    # an open request is withdrawn, not cancelled
    r2 = pax.post("/api/charter/requests", json={"offer_uid": offer["uid"], "contact_name": "Rami Haddad", "contact_mobile": "+963944000444", "from_city": "DAM",
                                                 "to_city": "HMS", "starts_at": starts.isoformat(), "ends_at": (starts + timedelta(hours=8)).isoformat(),
                                                 "passengers": 9, "idempotency_key": uuid.uuid4().hex}).json()
    assert pax.post(f"/api/charter/requests/{r2['uid']}/withdraw").json()["status"] == "WITHDRAWN"
    assert o.post(f"/api/carrier/charter/requests/{r2['uid']}/quote", json={"price": 1000}).json()["error"]["code"] == "CHARTER_CLOSED"
    assert o.patch(f"/api/carrier/charter/offers/{offer['uid']}", json={"status": "ARCHIVED"}).status_code == 200


def test_the_travellers_named_on_a_block_are_ticketed_and_on_the_manifest():
    """1126: the tourism company names the travellers on the seats it hired; they are tickets of the trip, on the
    carrier's list and the manifest, taken off one by one, and cancelled with the charter when the carrier cancels the trip."""
    o = _carrier()
    t = _fresh_trip(o)
    r = o.post("/api/carrier/charter/offers", json={
        "kind": "WHOLE_TRIP", "title": "Blocks of our trips for groups", "partial_seats": True, "min_seats": 4,
        "audience": ["AGENCY"], "price_basis": "PER_SEAT", "price": 2_000_000, "currency": "SYP", "notice_hours": 12,
        "cancel_before_hours": 48, "cancel_refund_pct": 100, "policy": "Blocks of four seats or more, named before departure."})
    assert r.status_code == 201, r.text
    offer = r.json()
    agency = _funded_agency()
    r = agency.post("/api/agency/charter/requests", json={
        "offer_uid": offer["uid"], "contact_name": "Rami Haddad", "contact_mobile": "+963944000444", "trip_uid": t["uid"],
        "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seats": 5, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    block = r.json()
    path = f"/api/agency/charter/requests/{block['uid']}/travellers"
    # nobody is named before the charter is confirmed
    assert agency.post(path, json={"travellers": [syrian(1) | {"seat_no": None}]}).json()["error"]["code"] == "CHARTER_NOT_CONFIRMED"
    assert o.post(f"/api/carrier/charter/requests/{block['uid']}/quote", json={"price": 9_000_000}).status_code == 200
    assert agency.post(f"/api/agency/charter/requests/{block['uid']}/accept").json()["seats_held"] == 5
    held = agency.get(path).json()
    seats = [x["seat_no"] for x in held["seats"]]
    assert len(seats) == 5 and held["named"] == 0 and held["booking_ref"] is None
    # a seat outside the block, a baby on a lap and more people than seats are refused
    outside = next(n for n in range(1, 45) if n not in seats)
    assert agency.post(path, json={"travellers": [syrian(outside)]}).json()["error"]["code"] == "CHARTER_SEAT"
    assert agency.post(path, json={"travellers": [syrian(1) | {"seat_no": None, "category": "INFANT", "birth_date": "2026-01-01"}]}
                       ).json()["error"]["code"] == "CHARTER_INFANT"
    assert agency.post(path, json={"travellers": [syrian(n) | {"seat_no": None} for n in range(6)]}).json()["error"]["code"] == "CHARTER_SEATS_FULL"
    # two travellers: one on the seat asked for, one on the next free seat of the block
    r = agency.post(path, json={"travellers": [syrian(seats[2]), syrian(7) | {"seat_no": None, "first_name": "Lina"}]})
    assert r.status_code == 200 and r.json()["named"] == 2, r.text
    named = r.json()
    assert {x["seat_no"] for x in named["issued"]} == {seats[2], seats[0]} and named["booking_ref"]
    assert agency.post(path, json={"travellers": [syrian(seats[2])]}).json()["error"]["code"] == "CHARTER_SEAT_NAMED"
    # tickets of the trip, on the carrier's list and its manifest; the booking costs nothing and is not cancelled alone
    assert {x["ticket_no"] for x in o.get(f"/api/carrier/charter/requests/{block['uid']}/travellers").json()["seats"] if x["ticket_no"]} \
        == {x["ticket_no"] for x in named["issued"]}
    manifest = o.get(f"/api/carrier/trips/{t['uid']}/manifest").json()["passengers"]
    on_list = {p["ticket_no"]: p for p in manifest}
    assert all(x["ticket_no"] in on_list for x in named["issued"])
    assert on_list[named["issued"][1]["ticket_no"]]["full_name"].startswith("Lina")
    assert owner_sql("SELECT total_amount FROM sales.booking WHERE booking_ref = $1", named["booking_ref"]) == 0
    r = agency.post(f"/api/agency/bookings/{named['booking_ref']}/cancel")
    assert r.status_code == 409 and r.json()["error"]["code"] == "CHARTER_BOOKING", r.text
    # one taken off: the ticket is cancelled and the seat is free again in the block, still off sale
    gone = named["issued"][1]["ticket_no"]
    r = agency.delete(f"{path}/{gone}")
    assert r.status_code == 200 and r.json()["named"] == 1 and r.json()["freed"] == seats[0], r.text
    assert gone not in {p["ticket_no"] for p in o.get(f"/api/carrier/trips/{t['uid']}/manifest").json()["passengers"]}
    assert owner_sql("""SELECT count(*) FROM ops.seat_segment s JOIN ops.trip x ON x.id = s.trip_id
                         WHERE x.uid = $1::uuid AND s.seat_no = $2 AND s.status = 'BLOCKED'""", t["uid"], seats[0]) >= 1
    # the carrier cancels the trip: the charter is refunded in full and its travellers' tickets are cancelled with it
    balance = _wallet(agency)
    r = o.post(f"/api/carrier/trips/{t['uid']}/cancel", json={"reason": "the road is closed by snow"})
    assert r.status_code == 200 and r.json()["charters_cancelled"] == 1, r.text
    assert _wallet(agency) - balance == 9_000_000
    assert agency.get(f"/api/agency/charter/requests/{block['uid']}").json()["status"] == "CANCELLED"
    assert owner_sql("""SELECT count(*) FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                         WHERE b.booking_ref = $1 AND k.status <> 'CANCELLED'""", named["booking_ref"]) == 0
    assert owner_sql("SELECT status FROM sales.booking WHERE booking_ref = $1", named["booking_ref"]) == "CANCELLED"
    assert o.patch(f"/api/carrier/charter/offers/{offer['uid']}", json={"status": "ARCHIVED"}).status_code == 200



def _new_vehicle(o) -> dict:
    layout = next(x for x in o.get("/api/carrier/seat-layouts").json()["layouts"] if x["total_seats"] == 44)
    plate = str(100000 + secrets.randbelow(900000))
    r = o.post("/api/carrier/vehicles", json={
        "plate_no": plate, "chassis_no": f"CHS-V{plate}", "vehicle_type": "COACH", "seat_layout_uid": layout["uid"],
        "insurance_no": f"POL-V{plate}", "insurer": "Test", "insurance_issue": "2026-01-01", "insurance_expiry": "2030-01-01"})
    assert r.status_code == 201, r.text
    return {"uid": r.json()["uid"], "plate_no": plate}


def test_a_hire_paid_by_deposit_and_balance_with_its_vehicles_named_one_by_one():
    """1128: a deposit on acceptance and the rest before the start; done only once paid in full; each vehicle of the hire
    named, and a vehicle hired out cannot run a trip at that time."""
    o = _carrier()
    r = o.post("/api/carrier/charter/offers", json={
        "kind": "VEHICLE", "title": "Coaches for groups, deposit 30%", "vehicle_type": "COACH", "seats": 45, "vehicles": 3,
        "audience": ["AGENCY"], "price_basis": "PER_TRIP", "price": 50_000_000, "currency": "SYP", "notice_hours": 24,
        "cancel_before_hours": 24, "cancel_refund_pct": 80, "deposit_pct": 30, "balance_hours": 24, "policy": POLICY})
    assert r.status_code == 201 and r.json()["deposit_pct"] == 30, r.text
    offer = r.json()
    agency = _funded_agency()
    starts = (datetime.now(timezone.utc) + timedelta(days=5)).replace(microsecond=0)
    r = agency.post("/api/agency/charter/requests", json={
        "offer_uid": offer["uid"], "contact_name": "Rami Haddad", "contact_mobile": "+963944000555", "from_city": "DAM", "to_city": "ALP",
        "starts_at": starts.isoformat(), "ends_at": (starts + timedelta(days=2)).isoformat(), "passengers": 80, "vehicles": 2,
        "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201 and r.json()["terms"]["deposit_pct"] == 30, r.text
    req = r.json()
    assert o.post(f"/api/carrier/charter/requests/{req['uid']}/quote", json={"price": 100_000_000}).status_code == 200
    # two vehicles named; a third is refused
    a, b, c = _new_vehicle(o), _new_vehicle(o), _new_vehicle(o)
    for v in (a, b):
        r = o.post(f"/api/carrier/charter/requests/{req['uid']}/vehicle", json={"vehicle_uid": v["uid"]})
        assert r.status_code == 200, r.text
    assert sorted(r.json()["vehicle_plates"]) == sorted([a["plate_no"], b["plate_no"]])
    r = o.post(f"/api/carrier/charter/requests/{req['uid']}/vehicle", json={"vehicle_uid": c["uid"]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "CHARTER_VEHICLES_FULL", r.text
    # the deposit on acceptance
    balance = _wallet(agency)
    r = agency.post(f"/api/agency/charter/requests/{req['uid']}/accept")
    assert r.status_code == 200 and r.json()["paid_amount"] == 30_000_000 and r.json()["balance_due"] == 70_000_000, r.text
    assert r.json()["balance_due_at"] and balance - _wallet(agency) == 30_000_000
    # a hired-out vehicle is on its schedule: a trip at that time is refused
    route = next(x for x in o.get("/api/carrier/routes").json()["routes"] if x["code"] == "DAM-ALP")
    driver = o.post("/api/carrier/crew", json={"full_name": "Hire Driver", "email": f"hire{uuid.uuid4().hex[:8]}@example.com",
                                               "password": "fresh-crew-long-passphrase"}).json()["uid"]
    r = o.post("/api/carrier/trips", json={"route_uid": route["uid"], "vehicle_uid": a["uid"], "driver_uid": driver,
                                           "departure_local": f"{day(6)}T10:00:00"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "VEHICLE_HIRED", r.text
    # the balance, once
    r = agency.post(f"/api/agency/charter/requests/{req['uid']}/balance")
    assert r.status_code == 200 and r.json()["balance_due"] == 0 and r.json()["paid_amount"] == 100_000_000, r.text
    assert agency.post(f"/api/agency/charter/requests/{req['uid']}/balance").json()["replayed"] is True
    assert balance - _wallet(agency) == 100_000_000
    # a vehicle taken off frees it; one that runs a trip at that time cannot take its place
    r = o.delete(f"/api/carrier/charter/requests/{req['uid']}/vehicles/{b['uid']}")
    assert r.status_code == 200 and r.json()["vehicle_plates"] == [a["plate_no"]], r.text
    r = o.post("/api/carrier/trips", json={"route_uid": route["uid"], "vehicle_uid": c["uid"], "driver_uid": driver,
                                           "departure_local": f"{day(6)}T15:40:00"})
    assert r.status_code == 201, r.text
    r = o.post(f"/api/carrier/charter/requests/{req['uid']}/vehicle", json={"vehicle_uid": c["uid"]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "VEHICLE_BUSY", r.text
    # cancelled in time by the tourism company: 80% of what was paid back
    r = agency.post(f"/api/agency/charter/requests/{req['uid']}/cancel", json={"reason": "the group was postponed"})
    assert r.status_code == 200 and r.json()["refunded_amount"] == 80_000_000, r.text
    assert o.patch(f"/api/carrier/charter/offers/{offer['uid']}", json={"status": "ARCHIVED"}).status_code == 200

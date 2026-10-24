"""Changes to a scheduled trip (owner's request N42; migration 1148): another vehicle, a moved departure, passengers
moved to another trip, each with a reason from the platform's list; the trip keeps its number; every booking is told,
and those no channel reaches are listed for the carrier to call."""
import secrets
import uuid
from datetime import datetime, timedelta

import pytest

from test_e2e import OWNER_URL, day, free_seats, login, owner_sql, syrian
from test_notifications import run_worker
from test_use_case_gaps import fresh_trip

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def owner():
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def counter():
    return login("counter@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def pax():
    c = login("passenger@masslak.test", "PASSENGER")
    assert c.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    return c


@pytest.fixture(scope="module", autouse=True)
def cash_room():
    admin = login("admin@masslak.test", "PLATFORM")
    company = owner_sql("SELECT m.company_id FROM iam.company_member m JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = 'owner@carrier.test'")
    assert admin.put(f"/api/admin/cash/limits/{company}", json={"limit_amount": 10_000_000_000, "reason": "trip change tests"}).status_code == 200


def searched(pax, trip):
    return next(x for x in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
                if x["uid"] == str(trip["uid"]))


def sell(c, base, t, seat=None, **extra):
    seat = seat or free_seats(c, t, 1)[0]
    h = c.post(f"{base}/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]})
    assert h.status_code == 201, h.text
    r = c.post(f"{base}/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"],
                                         "to_seq": t["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex, **extra})
    assert r.status_code == 201, r.text
    return r.json()


def vehicle(owner, seats: int) -> str:
    layout = next(x for x in owner.get("/api/carrier/seat-layouts").json()["layouts"] if x["total_seats"] == seats)
    plate = str(1_000_000_000 + secrets.randbelow(9_000_000_000))
    r = owner.post("/api/carrier/vehicles", json={
        "plate_no": plate, "chassis_no": f"CHS-S{plate}", "vehicle_type": "COACH", "seat_layout_uid": layout["uid"],
        "insurance_no": f"POL-S{plate}", "insurer": "Test", "insurance_issue": "2026-01-01", "insurance_expiry": "2030-01-01"})
    assert r.status_code == 201, r.text
    return r.json()["uid"]


def test_the_platform_lists_the_reasons_and_a_reason_is_required(owner):
    trip = fresh_trip()
    try:
        r = owner.get("/api/carrier/trip-changes/reasons").json()
        assert {"BREAKDOWN", "ACCIDENT", "LATE_INCOMING_TRIP", "OTHER"} <= {x["code"] for x in r["reasons"]}
        assert all(x["ar"] and x["en"] for x in r["reasons"]) and r["free_cancel_shift_min"] == 60
        dep = owner_sql("SELECT departure_at FROM ops.trip WHERE id = $1", trip["id"])
        later = (dep + timedelta(minutes=30)).isoformat()
        bad = owner.post(f"/api/carrier/trips/{trip['uid']}/reschedule", json={"departure_at": later, "reason": "TRAFFIC_JAM"})
        assert bad.status_code == 422 and bad.json()["error"]["code"] == "REASON_UNKNOWN"
        bad = owner.post(f"/api/carrier/trips/{trip['uid']}/reschedule", json={"departure_at": later, "reason": "OTHER"})
        assert bad.status_code == 422 and bad.json()["error"]["code"] == "REASON_NOTE_REQUIRED"
        too_far = (dep + timedelta(days=3)).isoformat()
        bad = owner.post(f"/api/carrier/trips/{trip['uid']}/reschedule", json={"departure_at": too_far, "reason": "WEATHER"})
        assert bad.status_code == 422 and bad.json()["error"]["code"] == "SHIFT_TOO_LARGE"
        # a carrier does not change the platform's list
        assert owner.get("/api/admin/trip-changes/policy").status_code == 403
    finally:
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


def test_a_moved_departure_keeps_the_number_tells_everyone_and_frees_the_fee(owner, counter, pax):
    trip = fresh_trip()
    t = searched(pax, trip)
    online = sell(pax, "/api", t)
    walk_in = sell(counter, "/api/carrier/counter", t)                       # no mobile left: the carrier must call
    before = owner_sql("SELECT departure_at, trip_no, (SELECT sched_dep FROM ops.trip_stop WHERE trip_id = $1 AND seq = 1) AS stop1 "
                       "FROM ops.trip WHERE id = $1", trip["id"], fetch=True)
    r = owner.post(f"/api/carrier/trips/{trip['uid']}/reschedule",
                   json={"departure_at": (before["departure_at"] + timedelta(minutes=90)).isoformat(), "reason": "LATE_INCOMING_TRIP",
                         "note": "The bus from Aleppo is late"})
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["shift_min"] == 90 and out["free_cancel"] is True and out["affected"] == 2
    assert out["notified"] == 1 and out["unreachable"] == 1
    after = owner_sql("SELECT departure_at, trip_no, shift_min, (SELECT sched_dep FROM ops.trip_stop WHERE trip_id = $1 AND seq = 1) AS stop1 "
                      "FROM ops.trip WHERE id = $1", trip["id"], fetch=True)
    assert after["trip_no"] == before["trip_no"]                               # the reference stays as issued (N43)
    assert after["departure_at"] - before["departure_at"] == timedelta(minutes=90) == after["stop1"] - before["stop1"]
    assert after["shift_min"] >= 90
    log = owner.get(f"/api/carrier/trips/{trip['uid']}/changes").json()["changes"]
    assert log[0]["kind"] == "RESCHEDULE" and log[0]["reason_code"] == "LATE_INCOMING_TRIP" and log[0]["note"] == "The bus from Aleppo is late"
    calls = log[0]["to_call"]
    assert [c["booking_ref"] for c in calls] == [walk_in["booking_ref"]]
    assert owner.post(f"/api/carrier/trips/{trip['uid']}/changes/calls/{calls[0]['id']}", json={"outcome": "INFORMED"}).json()["ok"]
    assert owner.get(f"/api/carrier/trips/{trip['uid']}/changes").json()["changes"][0]["to_call"][0]["outcome"] == "INFORMED"
    # the passenger sees the change and may cancel with everything back, the fare's fee waived
    view = pax.get(f"/api/bookings/{online['booking_ref']}").json()["booking"]
    assert view["free_cancel"] is True and view["trip_changes"][0]["kind"] == "RESCHEDULE" and view["trip_changes"][0]["shift_min"] == 90
    run_worker()
    told = pax.get("/api/notifications").json()["notifications"]
    assert any(n["template_code"] == "booking.trip_changed.reschedule" and n["payload"]["booking_ref"] == online["booking_ref"] for n in told)
    wallet = pax.get("/api/wallet").json()["balance"]
    r = pax.post(f"/api/bookings/{online['booking_ref']}/cancel")
    assert r.status_code == 200, r.text
    assert r.json()["refund"] == online["total"] and pax.get("/api/wallet").json()["balance"] == wallet + online["total"]
    owner.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "End of the trip change test"})


def test_another_vehicle_keeps_the_number_and_moves_the_seats_it_lacks(owner, pax):
    trip = fresh_trip()
    t = searched(pax, trip)
    back = sell(pax, "/api", t, seat=40)                                          # a seat a 32-seat vehicle does not have
    front = sell(pax, "/api", t, seat=3)
    small = vehicle(owner, 32)
    bad = owner.post(f"/api/carrier/trips/{trip['uid']}/vehicle", json={"vehicle_uid": small, "reason": "BREAKDOWN", "at_stop_seq": 1})
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "SWAP_STOP"       # a stop only on the way
    r = owner.post(f"/api/carrier/trips/{trip['uid']}/vehicle", json={"vehicle_uid": small, "reason": "BREAKDOWN", "note": "Gearbox"})
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["seats"] == 32 and out["seats_moved"] == 1 and out["affected"] == 2 and not out["en_route"]
    seat = owner_sql("""SELECT k.seat_no FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id WHERE b.booking_ref = $1""",
                     back["booking_ref"])
    assert seat <= 32
    assert owner_sql("SELECT k.seat_no FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id WHERE b.booking_ref = $1",
                     front["booking_ref"]) == 3                                   # a seat the vehicle has stays as sold
    row = owner_sql("SELECT trip_no, seats_total, vehicle_id FROM ops.trip WHERE id = $1", trip["id"], fetch=True)
    assert row["trip_no"] == trip["trip_no"] and row["seats_total"] == 32 and row["vehicle_id"] != trip["vehicle_id"]
    assert owner_sql("SELECT count(*) FROM ops.seat_segment WHERE trip_id = $1 AND seat_no > 32 AND status <> 'BLOCKED'", trip["id"]) == 0
    assert owner_sql("""SELECT count(*) FROM ops.seat_segment s JOIN sales.ticket k ON k.id = s.ticket_id
                         WHERE s.trip_id = $1 AND s.status = 'SOLD' AND k.seat_no = s.seat_no""", trip["id"]) == 2 * (t["to_seq"] - t["from_seq"])
    swap = owner_sql("SELECT reason_code, seats_moved, en_route FROM ops.vehicle_swap WHERE trip_id = $1", trip["id"], fetch=True)
    assert swap["reason_code"] == "BREAKDOWN" and swap["seats_moved"] == 1 and swap["en_route"] is False
    assert owner_sql("SELECT old_seat_no FROM sales.ticket_move m JOIN sales.ticket k ON k.id = m.ticket_id WHERE k.trip_id = $1",
                     trip["id"]) == 40
    # the same vehicle again is refused
    again = owner.post(f"/api/carrier/trips/{trip['uid']}/vehicle", json={"vehicle_uid": small, "reason": "BREAKDOWN"})
    assert again.status_code == 409 and again.json()["error"]["code"] == "SAME_VEHICLE"
    owner.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "End of the trip change test"})


def test_passengers_moved_to_another_trip_keep_their_booking_and_pay_nothing(owner, pax):
    first, second = fresh_trip(), fresh_trip()
    t = searched(pax, first)
    moved = sell(pax, "/api", t)
    paid = pax.get("/api/wallet").json()["balance"]
    old_ticket = owner_sql("SELECT k.ticket_no FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id WHERE b.booking_ref = $1",
                           moved["booking_ref"])
    opts = owner.get(f"/api/carrier/trips/{first['uid']}/rebook-options").json()
    assert any(x["uid"] == str(second["uid"]) for x in opts["trips"])
    assert [b["booking_ref"] for b in opts["bookings"]] == [moved["booking_ref"]]
    r = owner.post(f"/api/carrier/trips/{first['uid']}/rebook",
                   json={"to_trip_uid": str(second["uid"]), "reason": "VEHICLE_REPLACEMENT"})
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["bookings_moved"] == 1 and out["tickets_moved"] == 1 and out["notified"] == 1
    view = pax.get(f"/api/bookings/{moved['booking_ref']}").json()
    assert view["booking"]["status"] == "CONFIRMED" and view["booking"]["trip_no"] == second["trip_no"]
    assert view["tickets"][0]["ticket_no"] != old_ticket and view["tickets"][0]["ticket_no"].startswith(moved["booking_ref"])
    assert view["booking"]["trip_changes"][-1]["kind"] == "REBOOK"
    assert pax.get("/api/wallet").json()["balance"] == paid                       # no difference charged, nothing refunded
    assert owner_sql("SELECT count(*) FROM ops.seat_segment WHERE trip_id = $1 AND status = 'SOLD'", first["id"]) == 0
    assert owner_sql("SELECT count(*) FROM ops.seat_segment WHERE trip_id = $1 AND status = 'SOLD'", second["id"]) == t["to_seq"] - t["from_seq"]
    # the first trip, now empty, is cancelled without refunding anyone; the moved booking stays on the second
    c = owner.post(f"/api/carrier/trips/{first['uid']}/cancel", json={"reason": "Replaced by the next departure"})
    assert c.status_code == 200 and c.json()["bookings_refunded"] == 0, c.text
    assert pax.get(f"/api/bookings/{moved['booking_ref']}").json()["booking"]["status"] == "CONFIRMED"
    run_worker()
    told = pax.get("/api/notifications").json()["notifications"]
    n = next(x for x in told if x["template_code"] == "booking.trip_changed.rebook" and x["payload"]["booking_ref"] == moved["booking_ref"])
    assert n["payload"]["new_trip_no"] == second["trip_no"]
    nothing = owner.post(f"/api/carrier/trips/{second['uid']}/rebook", json={"to_trip_uid": str(first["uid"]), "reason": "WEATHER"})
    assert nothing.status_code == 409 and nothing.json()["error"]["code"] == "REBOOK_TARGET_INVALID"   # a cancelled trip takes no one
    owner.post(f"/api/carrier/trips/{second['uid']}/cancel", json={"reason": "End of the trip change test"})

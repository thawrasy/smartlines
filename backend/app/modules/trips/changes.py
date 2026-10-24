"""Changes to a scheduled trip (owner's request N42, migration 1148).

A trip keeps its number and its reference whatever happens to it. The carrier may change its vehicle (before departure
or on the way), move its departure, or move its passengers to another of its trips, each with a reason from the
platform's catalogue. Every change is kept in ops.trip_change; every booking it touches is told at once with the new
time, trip, seat or vehicle, and those the system cannot reach are listed for the carrier to call.

Seats: a ticket keeps its seat number where it can; otherwise it takes a free seat covering the same stretch. Moving a
seat frees the old segments and sells the new ones to the same ticket, which the database checks (seat_segment_guard).
"""
import json
from datetime import datetime, timedelta, timezone
from typing import Optional

import asyncpg

from ...errors import ApiError
from ...util import ticket_no
from ..fleet import service as fleet
from ..notify.outbox import emit
from ..notify.render import messages
from ..sales.repository import FREE_SEG

LIVE = ("PUBLISHED", "BOARDING")                    # sold and not yet left
BOOKINGS = ("CONFIRMED", "PENDING_PAYMENT")         # bookings still travelling on the trip


async def policy(conn: asyncpg.Connection) -> dict:
    """The platform's reasons and limits. A reason the platform has not named in Arabic takes the wording of the Arabic
    messages file (the schema holds no Arabic text), so both languages are always shown."""
    v = await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'trips.change_policy'")
    p = json.loads(v) if isinstance(v, str) else dict(v or {})
    words = messages("ar").get("reason_code_labels", {})
    p["reasons"] = [r | {"ar": r.get("ar") or words.get(r["code"], r.get("en", r["code"]))} for r in p.get("reasons", [])]
    return p


async def check_reason(conn: asyncpg.Connection, code: str, note: Optional[str]) -> None:
    codes = {r["code"] for r in (await policy(conn)).get("reasons", [])}
    if code not in codes:
        raise ApiError(422, "REASON_UNKNOWN", "pick a reason from the platform's list", reasons=sorted(codes))
    if code == "OTHER" and len((note or "").strip()) < 3:
        raise ApiError(422, "REASON_NOTE_REQUIRED", "explain the reason in the note")


async def _log(conn: asyncpg.Connection, trip, kind: str, reason: str, note: Optional[str], user_id: int, details: dict,
               old_dep=None, new_dep=None, shift: Optional[int] = None) -> int:
    return await conn.fetchval(
        """INSERT INTO ops.trip_change (trip_id, kind, old_departure, new_departure, shift_min, reason, reason_code, note,
             details, by_user_id) VALUES ($1, $2, $3, $4, $5, $6, $6, $7, $8::jsonb, $9) RETURNING id""",
        trip["id"], kind, old_dep, new_dep, shift, reason, (note or "").strip() or None, json.dumps(details, default=str), user_id)


async def _departs_local(conn: asyncpg.Connection, trip_id: int, seq: int) -> str:
    return await conn.fetchval(
        """SELECT to_char(sched_dep AT TIME ZONE ref.station_tz(station_id), 'YYYY-MM-DD HH24:MI')
             FROM ops.trip_stop WHERE trip_id = $1 AND seq = $2""", trip_id, seq)


async def _tell(conn: asyncpg.Connection, change_id: int, trip, kind: str, reason: str, extra: dict,
                common: Optional[dict] = None) -> dict:
    """Tells every booking still on the trip (after the change) and lists those no channel reaches. extra[booking_id]
    adds what changed for that booking (its new seats, its new trip)."""
    plate = await conn.fetchval("SELECT plate_no FROM fleet.vehicle WHERE id = $1", trip["vehicle_id"])
    notified = unreachable = 0
    rows = await conn.fetch(
        """SELECT b.id, b.booking_ref, b.booker_user_id, b.agency_id, b.pay_option, b.contact_mobile, b.company_id,
                  min(k.from_seq) AS from_seq
             FROM sales.booking b JOIN sales.ticket k ON k.booking_id = b.id AND k.status IN ('ISSUED','HOLD')
            WHERE b.trip_id = $1 AND b.status = ANY($2::text[]) GROUP BY b.id ORDER BY b.id""", trip["id"], list(BOOKINGS))
    for b in rows:
        counter = b["pay_option"] == "CASH_COUNTER" or None
        reachable = bool(b["contact_mobile"]) if (b["agency_id"] or counter or not b["booker_user_id"]) else True
        payload = {"change": kind, "reason_code": reason, "booking_ref": b["booking_ref"], "trip_no": trip["trip_no"],
                   "trip_code": trip["trip_code"], "departs_local": await _departs_local(conn, trip["id"], b["from_seq"]),
                   "vehicle_plate": plate, "booker_user_id": b["booker_user_id"], "agency_id": b["agency_id"],
                   "counter": counter, "contact_mobile": b["contact_mobile"], **(common or {}), **extra.get(b["id"], {})}
        await emit(conn, "booking.trip_changed", "booking", b["id"], payload, company_id=b["company_id"])
        if reachable:
            notified += 1
        else:
            unreachable += 1
            await conn.execute("INSERT INTO ops.trip_change_contact (trip_change_id, booking_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                               change_id, b["id"])
    await conn.execute("UPDATE ops.trip_change SET affected = $2, notified = $3, unreachable = $4 WHERE id = $1",
                       change_id, len(rows), notified, unreachable)
    return {"affected": len(rows), "notified": notified, "unreachable": unreachable}


# ------------------------------------------------------------------ seats
async def _free_seat(conn: asyncpg.Connection, trip_id: int, f: int, t: int, limit: int, prefer: Optional[int]) -> Optional[int]:
    return await conn.fetchval(
        f"""SELECT s.seat_no FROM ops.seat_segment s
             WHERE s.trip_id = $1 AND s.seg >= $2 AND s.seg < $3 AND s.seat_no <= $4
             GROUP BY s.seat_no HAVING count(*) = $3 - $2 AND bool_and({FREE_SEG})
             ORDER BY s.seat_no = $5 DESC, s.seat_no LIMIT 1""", trip_id, f, t, limit, prefer)


async def _release(conn: asyncpg.Connection, ticket_id: int) -> None:
    await conn.execute(
        """UPDATE ops.seat_segment SET status = 'AVAILABLE', ticket_id = NULL, lock_token = NULL, lock_user_id = NULL,
                  lock_expires_at = NULL WHERE ticket_id = $1""", ticket_id)


async def _sell(conn: asyncpg.Connection, ticket_id: int, trip_id: int, seat: int, f: int, t: int) -> None:
    n = await conn.fetchval(
        """WITH s AS (UPDATE ops.seat_segment SET status = 'SOLD', ticket_id = $1, lock_token = NULL, lock_user_id = NULL,
                             lock_expires_at = NULL
                       WHERE trip_id = $2 AND seat_no = $3 AND seg >= $4 AND seg < $5 RETURNING 1)
           SELECT count(*) FROM s""", ticket_id, trip_id, seat, f, t)
    if n != t - f:
        raise ApiError(409, "SEAT_NOT_FREE", f"seat {seat} is not free on the whole stretch")


def _new_ticket_no(booking_ref: str, old: str) -> str:
    try:
        index = int(old.rsplit("-", 1)[1][:2])
    except (IndexError, ValueError):
        index = 1
    for _ in range(20):
        new = ticket_no(booking_ref, index)
        if new != old:
            return new
    return f"{booking_ref}-{index:02d}X"


# ------------------------------------------------------------------ change the vehicle
async def swap_vehicle(conn: asyncpg.Connection, trip, vehicle_id: int, reason: str, note: Optional[str], user_id: int,
                       at_stop_seq: Optional[int] = None, driver_party_id: Optional[int] = None) -> dict:
    """Puts another vehicle on the trip, before departure or on the way; the trip keeps its number. The database checks
    the vehicle as for any trip; seats keep their numbers where the new vehicle has them, the rest move to free seats."""
    await check_reason(conn, reason, note)
    if trip["status"] not in ("DRAFT", "PUBLISHED", "BOARDING", "DEPARTED"):
        raise ApiError(409, "TRIP_NOT_CHANGEABLE", "the trip has ended or was cancelled", trip_status=trip["status"])
    if vehicle_id == trip["vehicle_id"]:
        raise ApiError(409, "SAME_VEHICLE", "the trip already runs with this vehicle")
    en_route = trip["status"] == "DEPARTED"
    if en_route != (at_stop_seq is not None):
        raise ApiError(422, "SWAP_STOP", "name the stop where the vehicle is changed on the way, and only then")
    if en_route and not await conn.fetchval("SELECT 1 FROM ops.trip_stop WHERE trip_id = $1 AND seq = $2", trip["id"], at_stop_seq):
        raise ApiError(422, "SWAP_STOP", "the stop is not on this trip")
    v = await conn.fetchrow(
        """SELECT v.id, v.passenger_seats, v.plate_no, v.status, v.company_id FROM fleet.vehicle v WHERE v.id = $1""", vehicle_id)
    if v is None or v["status"] != "ACTIVE" or (v["company_id"] != trip["company_id"] and not await conn.fetchval(
            """SELECT 1 FROM fleet.vehicle_lease WHERE vehicle_id = $1 AND lessee_company_id = $2 AND status = 'ACTIVE'
                  AND period @> ($3::timestamptz AT TIME ZONE 'UTC')::date""", vehicle_id, trip["company_id"], trip["departure_at"])):
        raise ApiError(409, "VEHICLE_NOT_ELIGIBLE", "the vehicle is not in service with this carrier")
    new_n, old_n = v["passenger_seats"], trip["seats_total"]
    await conn.execute("SELECT 1 FROM ops.seat_segment WHERE trip_id = $1 FOR UPDATE", trip["id"])
    if new_n > old_n:     # seats a smaller vehicle closed open again; the others are added
        await conn.execute("UPDATE ops.seat_segment SET status = 'AVAILABLE' WHERE trip_id = $1 AND seat_no > $2 AND seat_no <= $3 AND status = 'BLOCKED'",
                           trip["id"], old_n, new_n)
        await conn.execute(
            """INSERT INTO ops.seat_segment (trip_id, seat_no, seg)
               SELECT $1, seat, seg FROM generate_series($2, $3) seat, generate_series(0, $4) seg ON CONFLICT DO NOTHING""",
            trip["id"], old_n + 1, new_n, trip["segments_count"] - 1)
    change_id = await _log(conn, trip, "VEHICLE_SWAP", reason, note, user_id,
                           {"from_vehicle_id": trip["vehicle_id"], "to_vehicle_id": vehicle_id, "plate": v["plate_no"],
                            "en_route": en_route, "at_stop_seq": at_stop_seq})
    moved, extra = 0, {}
    # tickets whose seat the new vehicle does not have take a free seat on the same stretch
    for k in await conn.fetch(
            """SELECT k.id, k.booking_id, k.ticket_no, k.seat_no, k.from_seq, k.to_seq, k.status FROM sales.ticket k
                WHERE k.trip_id = $1 AND k.seat_no > $2 AND k.status IN ('ISSUED','HOLD','BOARDED') ORDER BY k.id""",
            trip["id"], new_n):
        if k["status"] == "HOLD":                   # a seat only held in a basket is let go
            await _release(conn, k["id"])
            await conn.execute("UPDATE sales.ticket SET status = 'CANCELLED' WHERE id = $1", k["id"])
            continue
        await _release(conn, k["id"])
        seat = await _free_seat(conn, trip["id"], k["from_seq"], k["to_seq"], new_n, None)
        if seat is None:
            raise ApiError(409, "NOT_ENOUGH_SEATS", "the new vehicle has too few free seats: move some passengers to another trip first",
                           seats=new_n)
        await conn.execute("UPDATE sales.ticket SET seat_no = $2 WHERE id = $1", k["id"], seat)
        await _sell(conn, k["id"], trip["id"], seat, k["from_seq"], k["to_seq"])
        await conn.execute(
            """INSERT INTO sales.ticket_move (ticket_id, trip_change_id, from_trip_id, to_trip_id, old_ticket_no, new_ticket_no,
                 old_seat_no, new_seat_no) VALUES ($1, $2, $3, $3, $4, $4, $5, $6)""",
            k["id"], change_id, trip["id"], k["ticket_no"], k["seat_no"], seat)
        extra.setdefault(k["booking_id"], {"new_seats": []})["new_seats"].append(seat)
        moved += 1
    if new_n < old_n:
        held = await conn.fetchval("SELECT count(*) FROM ops.seat_segment WHERE trip_id = $1 AND seat_no > $2 AND status = 'SOLD'",
                                   trip["id"], new_n)
        if held:
            raise ApiError(409, "NOT_ENOUGH_SEATS", "seats beyond the new vehicle's are still sold", seats=new_n)
        # the seats the new vehicle lacks are closed, not deleted: a larger vehicle later opens them again
        await conn.execute(
            """UPDATE ops.seat_segment SET status = 'BLOCKED', lock_token = NULL, lock_user_id = NULL, lock_expires_at = NULL
                WHERE trip_id = $1 AND seat_no > $2""", trip["id"], new_n)
    seat_map = await fleet.trip_seat_map(conn, vehicle_id)
    await conn.execute("UPDATE ops.trip SET vehicle_id = $2, seats_total = $3, seat_map = $4::jsonb WHERE id = $1",
                       trip["id"], vehicle_id, new_n, json.dumps(seat_map) if seat_map else None)
    driver_changed = False
    if driver_party_id:
        await conn.execute("UPDATE ops.crew_assignment SET status = 'RELEASED' WHERE trip_id = $1 AND crew_role = 'DRIVER' AND status <> 'RELEASED'",
                           trip["id"])
        await conn.execute(
            """INSERT INTO ops.crew_assignment (trip_id, party_id, crew_role) VALUES ($1, $2, 'DRIVER')
               ON CONFLICT (trip_id, party_id) DO UPDATE SET status = 'ASSIGNED'""", trip["id"], driver_party_id)
        driver_changed = True
    await conn.execute(
        """INSERT INTO ops.vehicle_swap (trip_id, from_vehicle_id, to_vehicle_id, reason, reason_code, seats_reassigned,
             approved_by, trip_change_id, en_route, at_stop_seq, seats_moved, driver_changed)
           VALUES ($1, $2, $3, $4, $4, $5, $6, $7, $8, $9, $10, $11)""",
        trip["id"], trip["vehicle_id"], vehicle_id, reason, moved > 0, user_id, change_id, en_route, at_stop_seq, moved, driver_changed)
    t = await conn.fetchrow("SELECT * FROM ops.trip WHERE id = $1", trip["id"])
    told = await _tell(conn, change_id, t, "VEHICLE_SWAP", reason, extra)
    return {"ok": True, "change_id": change_id, "plate": v["plate_no"], "seats": new_n, "seats_moved": moved,
            "en_route": en_route, **told}


# ------------------------------------------------------------------ move the departure
async def reschedule(conn: asyncpg.Connection, trip, new_departure: datetime, reason: str, note: Optional[str],
                     user_id: int) -> dict:
    """Moves the departure and every stop by the same minutes; the trip keeps its number and its reference (N43). The
    database checks that the vehicle is free at the new time."""
    await check_reason(conn, reason, note)
    if trip["status"] not in ("DRAFT",) + LIVE:
        raise ApiError(409, "TRIP_NOT_CHANGEABLE", "only a trip that has not left can be moved", trip_status=trip["status"])
    if new_departure.tzinfo is None:
        raise ApiError(422, "TIME_ZONE_REQUIRED", "give the new departure with its time zone")
    if new_departure <= datetime.now(timezone.utc):
        raise ApiError(422, "DEPARTURE_PAST", "the new departure has passed")
    shift = round((new_departure - trip["departure_at"]).total_seconds() / 60)
    p = await policy(conn)
    if shift == 0:
        raise ApiError(422, "SAME_DEPARTURE", "the trip already leaves at this time")
    if abs(shift) > int(p.get("max_shift_min", 1440)):
        raise ApiError(422, "SHIFT_TOO_LARGE", "move the passengers to another trip instead", max_shift_min=p.get("max_shift_min"))
    iv = timedelta(minutes=shift)
    await conn.execute(
        """UPDATE ops.trip SET departure_at = departure_at + $2, arrival_at = arrival_at + $2, shift_min = shift_min + $3
            WHERE id = $1""", trip["id"], iv, shift)
    await conn.execute("UPDATE ops.trip_stop SET sched_arr = sched_arr + $2, sched_dep = sched_dep + $2 WHERE trip_id = $1",
                       trip["id"], iv)
    await conn.execute(
        """UPDATE ops.crew_assignment c SET busy = t.vehicle_busy FROM ops.trip t
            WHERE c.trip_id = $1 AND t.id = c.trip_id AND c.status <> 'RELEASED'""", trip["id"])
    change_id = await _log(conn, trip, "RESCHEDULE", reason, note, user_id,
                           {"free_cancel": abs(shift) >= int(p.get("free_cancel_shift_min", 60))},
                           trip["departure_at"], trip["departure_at"] + iv, shift)
    t = await conn.fetchrow("SELECT * FROM ops.trip WHERE id = $1", trip["id"])
    free = abs(shift) >= int(p.get("free_cancel_shift_min", 60))
    told = await _tell(conn, change_id, t, "RESCHEDULE", reason, {}, {"shift_min": shift, "free_cancel": free})
    return {"ok": True, "change_id": change_id, "shift_min": shift, "departure_at": t["departure_at"], "free_cancel": free, **told}


async def waives_fee(conn: asyncpg.Connection, booking_id: int, trip_id: int, booked_at: datetime) -> bool:
    """A passenger whose trip the carrier moved by at least the platform's threshold after the booking was made cancels
    with everything back (N42)."""
    threshold = int((await policy(conn)).get("free_cancel_shift_min", 60))
    return bool(await conn.fetchval(
        """SELECT true FROM ops.trip_change WHERE trip_id = $1 AND kind = 'RESCHEDULE' AND created_at > $2
              AND abs(shift_min) >= $3 LIMIT 1""", trip_id, booked_at, threshold))


# ------------------------------------------------------------------ move passengers to another trip
REBOOK_TARGETS = """
SELECT t.id, t.uid, t.trip_no, t.trip_code, t.departure_at, t.seats_total, v.plate_no,
       (SELECT count(DISTINCT s.seat_no) FROM ops.seat_segment s WHERE s.trip_id = t.id AND s.seat_no <= t.seats_total
          AND NOT """ + FREE_SEG + """) AS seats_taken
  FROM ops.trip t LEFT JOIN fleet.vehicle v ON v.id = t.vehicle_id
 WHERE t.company_id = $1 AND t.id <> $2 AND t.status IN ('PUBLISHED','BOARDING') AND t.departure_at > now()
   AND t.departure_at < $3::timestamptz + make_interval(hours => $4)
   AND NOT EXISTS (SELECT 1 FROM ops.trip_stop a WHERE a.trip_id = $2
                    AND NOT EXISTS (SELECT 1 FROM ops.trip_stop b WHERE b.trip_id = t.id AND b.station_id = a.station_id))
 ORDER BY t.departure_at"""


async def rebook_targets(conn: asyncpg.Connection, trip) -> list[dict]:
    """The carrier's coming trips that stop at every station of this trip, within the platform's window."""
    hours = int((await policy(conn)).get("rebook_window_hours", 72))
    return [dict(r) | {"seats_left": r["seats_total"] - r["seats_taken"]}
            for r in await conn.fetch(REBOOK_TARGETS, trip["company_id"], trip["id"], trip["departure_at"], hours)]


async def rebook(conn: asyncpg.Connection, trip, target_id: int, booking_refs: Optional[list[str]], reason: str,
                 note: Optional[str], user_id: int) -> dict:
    """Moves bookings (named ones, or all) to another of the carrier's trips. Each keeps its reference and its price;
    each ticket gets a new number on the new trip, its seat number where free, else another free seat."""
    await check_reason(conn, reason, note)
    if trip["status"] not in ("DRAFT",) + LIVE:
        raise ApiError(409, "TRIP_NOT_CHANGEABLE", "passengers are moved before the trip leaves", trip_status=trip["status"])
    target = next((t for t in await rebook_targets(conn, trip) if t["id"] == target_id), None)
    if target is None:
        raise ApiError(409, "REBOOK_TARGET_INVALID", "move to a coming trip of the same carrier stopping at the same stations")
    target = await conn.fetchrow("SELECT * FROM ops.trip WHERE id = $1 FOR UPDATE", target_id)
    stations = {r["seq"]: r["station_id"] for r in await conn.fetch("SELECT seq, station_id FROM ops.trip_stop WHERE trip_id = $1", trip["id"])}
    seq_on = {r["station_id"]: r["seq"] for r in await conn.fetch("SELECT seq, station_id FROM ops.trip_stop WHERE trip_id = $1", target_id)}
    bookings = await conn.fetch(
        """SELECT * FROM sales.booking WHERE trip_id = $1 AND status = ANY($2::text[]) AND charter_request_id IS NULL
              AND ($3::text[] IS NULL OR booking_ref = ANY($3::text[])) ORDER BY id FOR UPDATE""",
        trip["id"], list(BOOKINGS), booking_refs)
    if booking_refs and len(bookings) != len(set(booking_refs)):
        raise ApiError(404, "BOOKING_NOT_ON_TRIP", "a booking named is not on this trip or cannot be moved")
    if not bookings:
        raise ApiError(409, "NOTHING_TO_MOVE", "no booking on this trip to move")
    await conn.execute("SELECT 1 FROM ops.seat_segment WHERE trip_id = ANY($1::bigint[]) FOR UPDATE", [trip["id"], target_id])
    await conn.execute("SET CONSTRAINTS sales.ticket_booking_trip_fk DEFERRED")     # booking and tickets move together (1148)
    change_id = await _log(conn, trip, "REBOOK", reason, note, user_id,
                           {"to_trip_id": target_id, "to_trip_no": target["trip_no"], "to_trip_code": target["trip_code"],
                            "bookings": [b["booking_ref"] for b in bookings]})
    moved_tickets, extra = 0, {}
    for b in bookings:
        seats = []
        for k in await conn.fetch(
                """SELECT * FROM sales.ticket WHERE booking_id = $1 AND trip_id = $2 AND status IN ('ISSUED','HOLD')
                    ORDER BY seat_no NULLS LAST, id""", b["id"], trip["id"]):
            f, t = seq_on.get(stations[k["from_seq"]]), seq_on.get(stations[k["to_seq"]])
            if f is None or t is None or f >= t:
                raise ApiError(409, "REBOOK_TARGET_INVALID", "the other trip does not run this passenger's stretch in the same direction")
            await _release(conn, k["id"])
            seat = None
            if k["seat_no"] is not None:
                seat = await _free_seat(conn, target_id, f, t, target["seats_total"], k["seat_no"])
                if seat is None:
                    raise ApiError(409, "NOT_ENOUGH_SEATS", f"trip {target['trip_code'] or target['trip_no']} has too few free seats",
                                   booking_ref=b["booking_ref"])
            new_no = _new_ticket_no(b["booking_ref"], k["ticket_no"])
            await conn.execute(
                """UPDATE sales.ticket SET trip_id = $2, from_seq = $3, to_seq = $4, seat_no = $5, ticket_no = $6,
                          qr_serial = qr_serial + 1 WHERE id = $1""", k["id"], target_id, f, t, seat, new_no)
            if seat is not None:
                await _sell(conn, k["id"], target_id, seat, f, t)
                seats.append(seat)
            await conn.execute(
                """INSERT INTO sales.ticket_move (ticket_id, trip_change_id, from_trip_id, to_trip_id, old_ticket_no, new_ticket_no,
                     old_seat_no, new_seat_no) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)""",
                k["id"], change_id, trip["id"], target_id, k["ticket_no"], new_no, k["seat_no"], seat)
            moved_tickets += 1
        await conn.execute("UPDATE sales.booking SET trip_id = $2 WHERE id = $1", b["id"], target_id)
        extra[b["id"]] = {"new_trip_no": target["trip_no"], "new_trip_code": target["trip_code"], "new_seats": seats,
                          "from_trip_code": trip["trip_code"] or trip["trip_no"]}
    # the moved bookings are told on their new trip, with its time and vehicle
    told = await _tell_moved(conn, change_id, target, reason, extra)
    await conn.execute("UPDATE ops.trip_change SET affected = $2, notified = $3, unreachable = $4 WHERE id = $1",
                       change_id, told["affected"], told["notified"], told["unreachable"])
    return {"ok": True, "change_id": change_id, "bookings_moved": len(bookings), "tickets_moved": moved_tickets,
            "to_trip_no": target["trip_no"], "to_trip_code": target["trip_code"], **told}


async def _tell_moved(conn: asyncpg.Connection, change_id: int, target, reason: str, extra: dict) -> dict:
    plate = await conn.fetchval("SELECT plate_no FROM fleet.vehicle WHERE id = $1", target["vehicle_id"])
    notified = unreachable = 0
    for booking_id, what in extra.items():
        b = await conn.fetchrow(
            """SELECT b.*, (SELECT min(from_seq) FROM sales.ticket WHERE booking_id = b.id) AS from_seq
                 FROM sales.booking b WHERE b.id = $1""", booking_id)
        counter = b["pay_option"] == "CASH_COUNTER" or None
        reachable = bool(b["contact_mobile"]) if (b["agency_id"] or counter or not b["booker_user_id"]) else True
        await emit(conn, "booking.trip_changed", "booking", booking_id, {
            "change": "REBOOK", "reason_code": reason, "booking_ref": b["booking_ref"], "trip_no": target["trip_no"],
            "trip_code": target["trip_code"], "departs_local": await _departs_local(conn, target["id"], b["from_seq"]),
            "vehicle_plate": plate, "booker_user_id": b["booker_user_id"], "agency_id": b["agency_id"], "counter": counter,
            "contact_mobile": b["contact_mobile"], **what}, company_id=b["company_id"])
        if reachable:
            notified += 1
        else:
            unreachable += 1
            await conn.execute("INSERT INTO ops.trip_change_contact (trip_change_id, booking_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                               change_id, booking_id)
    return {"affected": len(extra), "notified": notified, "unreachable": unreachable}


# ------------------------------------------------------------------ the record
async def history(conn: asyncpg.Connection, trip_id: int) -> list[dict]:
    rows = await conn.fetch(
        """SELECT c.uid, c.kind, c.reason_code, c.note, c.old_departure, c.new_departure, c.shift_min, c.details, c.affected,
                  c.notified, c.unreachable, c.created_at, py.legal_name AS by_name,
                  coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'booking_ref', b.booking_ref, 'mobile', b.contact_mobile,
                                     'contacted_at', x.contacted_at, 'outcome', x.outcome, 'note', x.note) ORDER BY x.id)
                              FROM ops.trip_change_contact x JOIN sales.booking b ON b.id = x.booking_id
                             WHERE x.trip_change_id = c.id), '[]'::jsonb) AS to_call
             FROM ops.trip_change c LEFT JOIN iam.app_user u ON u.id = c.by_user_id LEFT JOIN iam.party py ON py.id = u.party_id
            WHERE c.trip_id = $1 OR (c.kind = 'REBOOK' AND (c.details->>'to_trip_id')::bigint = $1)
            ORDER BY c.created_at DESC, c.id DESC""", trip_id)
    out = []
    for r in rows:
        d = dict(r)
        for k in ("details", "to_call"):
            d[k] = json.loads(d[k]) if isinstance(d[k], str) else d[k]
        out.append(d)
    return out


async def record_call(conn: asyncpg.Connection, trip_id: int, contact_id: int, outcome: str, note: Optional[str], user_id: int) -> None:
    done = await conn.fetchval(
        """UPDATE ops.trip_change_contact x SET contacted_at = now(), contacted_by = $3, outcome = $4, note = $5
             FROM ops.trip_change c WHERE x.id = $2 AND c.id = x.trip_change_id
              AND (c.trip_id = $1 OR (c.details->>'to_trip_id')::bigint = $1) RETURNING x.id""",
        trip_id, contact_id, user_id, outcome, (note or "").strip() or None)
    if done is None:
        raise ApiError(404, "NOT_FOUND", "no such passenger to call on this trip")

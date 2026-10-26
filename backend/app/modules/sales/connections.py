"""Connections across carriers, and a booking changed to another trip (owner's request, October 2026; migration 1130).

Where no trip runs from one city to another (Daraa to Aleppo), search offers a connection: a trip to a city on the way
(Damascus, Homs) and a trip of the same carrier or another from there, leaving a while after the first arrives; at least
journey.connections.min_minutes at the same station, min_minutes_station_change between two stations of the city, and
at most max_minutes. A carrier that keeps its trips out of connections is not offered in them.

A connection is booked as one journey of kind CONNECTION (journeys.py): each trip stays a booking of its own carrier
with that carrier's rules, and the traveller accepts the risks first (risk_ack_at). Where the platform requires it
(journey.connections.require_flexible), every trip after the first is booked with a fare that may be changed, or with a
carrier that changes it free when the first trip arrived late.

A booking is changed to another trip of the same carrier between the same cities. Before the departure the fare's rules
apply (a changeable fare, its change fee). After the trip left without the traveller, the carrier's policy applies for
change_window_hours after the departure: FREE_CHANGE changes it free when the trip before it in the connection arrived
too late (or was cancelled), FARE_RULES under the fare's rules, NONE not at all. A change cancels the old booking with its
value back to the wallet less the fee, and books the new trip from the same wallet, in one transaction; the travellers,
the fare and the journey are carried over. Once the carrier completes the missed trip its tickets are closed as not
travelled, and no change is possible any more.
"""
from __future__ import annotations

import json
import uuid
from datetime import date, datetime, timedelta, timezone

import asyncpg
from pydantic import BaseModel, Field

from ... import crypto, db
from ...errors import ApiError
from . import repository as repo
from .models import BookingIn, HoldIn, PassengerIn

PASSENGER_CATEGORIES = ("ADULT", "CHILD", "INFANT")
ID_TYPES = ("NATIONAL_ID", "PASSPORT", "RESIDENCE", "LAISSEZ_PASSER", "TRAVEL_DOCUMENT", "OTHER")


def _json(v):
    return json.loads(v) if isinstance(v, str) else v


async def settings(conn: asyncpg.Connection) -> dict:
    return _json(await conn.fetchval("SELECT sales.connection_settings()::text"))


async def policy(conn: asyncpg.Connection, company_id: int) -> dict:
    return _json(await conn.fetchval("SELECT ops.connection_policy($1)::text", company_id))


# ------------------------------------------------------------------ search
_LEG = f"""
  SELECT DISTINCT ON (t.id, {{key}})
         t.id, t.uid AS trip_uid, t.trip_no, t.trip_code, t.company_id, t.currency,
         a.seq AS from_seq, b.seq AS to_seq, a.sched_dep AS departs_at, b.sched_arr AS arrives_at,
         sa.id AS from_station_id, sb.id AS to_station_id, sa.name AS from_station, sb.name AS to_station,
         sa.code AS from_code, sb.code AS to_code, ca.id AS from_city_id, cb.id AS to_city_id,
         ca.code AS from_city, cb.code AS to_city, ca.name AS from_city_name, cb.name AS to_city_name,
         coalesce(pf.price, b.fare_from_origin - a.fare_from_origin) AS price,
         t.seats_total - (SELECT count(DISTINCT s.seat_no) FROM ops.seat_segment s
                           WHERE s.trip_id = t.id AND s.seg >= a.seq AND s.seg < b.seq AND NOT {repo.FREE_SEG}) AS seats_left,
         cpy.legal_name AS carrier_name, cpy.uid AS carrier_uid, cc.code3 AS carrier_code, iam.logo_version(t.company_id) AS carrier_logo,
         coalesce(pol.missed_connection, 'FARE_RULES') AS missed_connection, coalesce(pol.change_window_hours, 24) AS change_window_hours,
         pol.note AS policy_note
    FROM ops.trip t
    JOIN ops.trip_stop a ON a.trip_id = t.id JOIN net.station sa ON sa.id = a.station_id JOIN ref.city ca ON ca.id = sa.city_id
    JOIN ops.trip_stop b ON b.trip_id = t.id AND b.seq > a.seq JOIN net.station sb ON sb.id = b.station_id JOIN ref.city cb ON cb.id = sb.city_id
    JOIN iam.party cpy ON cpy.id = t.company_id
    LEFT JOIN net.carrier_code cc ON cc.company_id = t.company_id AND cc.status = 'ACTIVE'
    LEFT JOIN ops.trip_pair_fare pf ON pf.trip_id = t.id AND pf.from_seq = a.seq AND pf.to_seq = b.seq
    LEFT JOIN ops.carrier_connection_policy pol ON pol.company_id = t.company_id
   WHERE t.status IN ('PUBLISHED', 'BOARDING') AND coalesce(pol.offer_in_connections, true)
     AND a.kind = 'STATION' AND b.kind = 'STATION' AND a.sellable AND a.sales_closed_at IS NULL
     AND (t.service_type = 'INDIRECT' OR (a.seq = 0 AND b.seq = t.segments_count))
     AND a.sched_dep > now() + make_interval(mins => t.sales_cutoff_min)
     AND {{where}}
   ORDER BY t.id, {{key}}, {{order}}"""

_FIRST = _LEG.format(
    key="cb.id", order="a.seq, b.seq",
    where="""ca.code = $1 AND cb.code NOT IN ($1, $2) AND (a.sched_dep AT TIME ZONE ca.timezone)::date = $3
             -- a trip that goes on to the destination is a direct trip, not the first of a connection
             AND NOT EXISTS (SELECT 1 FROM ops.trip_stop z JOIN net.station sz ON sz.id = z.station_id
                               JOIN ref.city cz ON cz.id = sz.city_id WHERE z.trip_id = t.id AND z.seq > a.seq AND cz.code = $2)""")
_SECOND = _LEG.format(
    key="ca.id", order="a.seq DESC, b.seq",
    where="""cb.code = $2 AND ca.id IN (SELECT to_city_id FROM first)
             AND a.sched_dep BETWEEN (SELECT min(arrives_at) FROM first) AND (SELECT max(arrives_at) FROM first) + make_interval(mins => $4::int)""")
SEARCH_SQL = f"""
  WITH first AS ({_FIRST}),
  second AS ({_SECOND})
  SELECT row_to_json(f) AS a, row_to_json(s) AS b,
         extract(epoch FROM s.departs_at - f.arrives_at)::int / 60 AS minutes, s.from_station_id = f.to_station_id AS same_station
    FROM first f JOIN second s ON s.from_city_id = f.to_city_id AND s.id <> f.id
     AND s.departs_at >= f.arrives_at + make_interval(mins => CASE WHEN s.from_station_id = f.to_station_id THEN $5::int ELSE $6::int END)
     AND s.departs_at <= f.arrives_at + make_interval(mins => $4::int)
   ORDER BY s.arrives_at, f.price + s.price
   LIMIT 20"""

_LEG_KEYS = ("trip_uid", "trip_no", "trip_code", "from_seq", "to_seq", "departs_at", "arrives_at", "from_station", "to_station",
             "from_code", "to_code", "from_city", "to_city", "price", "currency", "seats_left", "carrier_name", "carrier_uid",
             "carrier_code", "carrier_logo")


def _leg(r: dict, passengers: int) -> dict:
    return {k: r[k] for k in _LEG_KEYS} | {
        "bookable": r["seats_left"] >= passengers,
        "policy": {"missed_connection": r["missed_connection"], "change_window_hours": r["change_window_hours"], "note": r["policy_note"]}}


async def search(conn: asyncpg.Connection, origin: str, destination: str, on: date, passengers: int) -> dict:
    """Connections of two trips from origin to destination, boarding on the day; the earliest arrival first."""
    cfg = await settings(conn)
    if not cfg["enabled"]:
        return {"enabled": False, "settings": cfg, "connections": []}
    # an old city code still finds its city (1161, N39)
    origin, destination = await conn.fetchval("SELECT ARRAY[ref.current_code('CITY', $1), ref.current_code('CITY', $2)]", origin, destination)
    recs = await conn.fetch(SEARCH_SQL, origin, destination, on, cfg["max_minutes"], cfg["min_minutes"], cfg["min_minutes_station_change"])
    out = []
    for r in recs:
        a, b = _json(r["a"]), _json(r["b"])
        legs = [_leg(a, passengers), _leg(b, passengers)]
        same_money = a["currency"] == b["currency"]
        out.append({
            "legs": legs, "departs_at": a["departs_at"], "arrives_at": b["arrives_at"],
            "carriers": len({a["company_id"], b["company_id"]}),
            "price": a["price"] + b["price"] if same_money else None, "currency": a["currency"] if same_money else None,
            "bookable": all(x["bookable"] for x in legs),
            "change": {"city": a["to_city"], "city_name": a["to_city_name"], "arrives_at": a["to_station"], "leaves_from": b["from_station"],
                       "same_station": r["same_station"], "minutes": r["minutes"]}})
    return {"enabled": True, "settings": cfg, "connections": out}


# ------------------------------------------------------------------ booking a connection
async def check(conn: asyncpg.Connection, legs, brands: list[str]) -> None:
    """A connection booked as a journey: each trip leaves from the city where the one before arrives, within the change
    time the platform sets; every carrier takes part in connections; the later trips are changeable where required."""
    cfg = await settings(conn)
    if not cfg["enabled"]:
        raise ApiError(409, "CONNECTIONS_OFF", "connections are not offered at present")
    rows = []
    for i, leg in enumerate(legs, start=1):
        rows.append(await conn.fetchrow(
            """SELECT t.id, t.company_id, a.station_id AS from_station, sa.city_id AS from_city, b.station_id AS to_station,
                      sb.city_id AS to_city, a.sched_dep AS departs_at, b.sched_arr AS arrives_at
                 FROM ops.trip t JOIN ops.trip_stop a ON a.trip_id = t.id AND a.seq = $2 JOIN net.station sa ON sa.id = a.station_id
                 JOIN ops.trip_stop b ON b.trip_id = t.id AND b.seq = $3 JOIN net.station sb ON sb.id = b.station_id
                WHERE t.uid = $1""", leg.trip_uid, leg.from_seq, leg.to_seq))
    for i, (prev, nxt) in enumerate(zip(rows, rows[1:]), start=2):
        if nxt["id"] == prev["id"] or nxt["from_city"] != prev["to_city"]:
            raise ApiError(422, "CONNECTION_BREAK", f"trip {i} does not leave from the city where trip {i - 1} arrives", leg=i)
        gap = (nxt["departs_at"] - prev["arrives_at"]).total_seconds() / 60
        need = cfg["min_minutes"] if nxt["from_station"] == prev["to_station"] else cfg["min_minutes_station_change"]
        if gap < need:
            raise ApiError(422, "CONNECTION_TOO_SHORT", f"trip {i} leaves {int(gap)} minutes after trip {i - 1} arrives; at least {need} are needed",
                           leg=i, minutes=int(gap), needed=need)
        if gap > cfg["max_minutes"]:
            raise ApiError(422, "CONNECTION_TOO_LONG", f"trip {i} leaves more than {cfg['max_minutes']} minutes after trip {i - 1} arrives",
                           leg=i, minutes=int(gap), max_minutes=cfg["max_minutes"])
    for i, (row, brand) in enumerate(zip(rows, brands), start=1):
        pol = await policy(conn, row["company_id"])
        if not pol["offer_in_connections"]:
            raise ApiError(409, "CARRIER_NOT_IN_CONNECTIONS", f"the carrier of trip {i} does not take part in connections", leg=i)
        if i > 1 and cfg["require_flexible"] and pol["missed_connection"] != "FREE_CHANGE":
            rules = _json(await conn.fetchval("SELECT rules FROM pricing.fare_brand WHERE code = $1 AND active", brand)) or {}
            if not rules.get("changeable"):
                raise ApiError(422, "CONNECTION_NEEDS_FLEX",
                               f"trip {i} of a connection is booked with a fare that may be changed, in case the trip before it is late",
                               leg=i)


# ------------------------------------------------------------------ changing a booking
class ChangeIn(BaseModel):
    trip_uid: uuid.UUID
    from_seq: int = Field(ge=0, le=500)
    to_seq: int = Field(ge=1, le=500)
    idempotency_key: str = Field(min_length=8, max_length=60)


async def state(conn: asyncpg.Connection, b) -> dict:
    """Whether and on what basis the booking may be changed now, its fee and what comes back to the wallet."""
    out: dict = {"allowed": False, "reason": None, "basis": None, "fee": 0, "fares": 0, "refund": 0, "currency": b["currency"],
                 "missed": False, "inbound_late": False, "connection": False, "why": None}
    tickets = await conn.fetch(
        """SELECT k.status, k.total_amount, k.rules_snapshot, k.fare_brand_code, a.sched_dep, a.actual_dep
             FROM sales.ticket k JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq
            WHERE k.booking_id = $1 AND k.status <> 'CANCELLED'""", b["id"])
    pol = await policy(conn, b["company_id"])
    out["policy"] = {k: pol[k] for k in ("missed_connection", "change_window_hours", "note")}
    if b["status"] != "CONFIRMED" or not tickets:
        out["why"] = "CANNOT_CHANGE"
        return out
    if b["charter_request_id"] or b["agency_id"] or b["funding_source"] in ("HEAD_WALLET", "FAMILY_ACCOUNT") or b["pay_method"] != "WALLET":
        out["why"] = "CHANGE_NOT_AVAILABLE"        # booked by an agency, for a charter, from a family's money or not from the wallet
        return out
    if any(t["status"] != "ISSUED" for t in tickets):
        out["why"] = "CANNOT_CHANGE"               # a traveller boarded, or the carrier closed the trip
        return out
    now = datetime.now(timezone.utc)
    departs = min(t["actual_dep"] or t["sched_dep"] for t in tickets)
    # a completed trip keeps a connection's missed booking open until the change window ends (1132)
    held = await held_until(conn, b) if b["trip_status"] == "COMPLETED" else None
    missed = held is not None or b["trip_status"] == "DEPARTED" or (b["trip_status"] == "BOARDING" and now >= departs)
    if b["trip_status"] not in ("PUBLISHED", "BOARDING", "DEPARTED") and held is None:
        out["why"] = "CANNOT_CHANGE"
        return out
    mc = _json(await conn.fetchval("SELECT sales.missed_connection($1)::text", b["id"]))
    fares = sum(t["total_amount"] for t in tickets)
    out.update(missed=missed, inbound_late=mc["inbound_late"], connection=mc["connection"], fares=fares,
               departs_at=departs, brand=tickets[0]["fare_brand_code"])
    if missed:
        until = held or departs + timedelta(hours=pol["change_window_hours"])
        out["change_until"] = until
        if now > until:
            out["why"] = "CHANGE_WINDOW_CLOSED"
            return out
        if pol["missed_connection"] == "NONE":
            out["why"] = "CHANGE_NOT_ALLOWED"      # the carrier's policy: a missed trip is lost
            return out
    reason = "MISSED_CONNECTION" if mc["connection"] and (missed or mc["inbound_late"]) else "CUSTOMER"
    if pol["missed_connection"] == "FREE_CHANGE" and mc["inbound_late"]:
        out.update(allowed=True, reason="MISSED_CONNECTION", basis="FREE_CHANGE", fee=0, refund=fares)
        return out
    rules = [_json(t["rules_snapshot"]) or {} for t in tickets]
    if not all(r.get("changeable") for r in rules):
        out["why"] = "NOT_CHANGEABLE"              # the fare may not be changed
        return out
    fee = sum(t["total_amount"] * int(r.get("change_fee_pct") or 0) // 100 for t, r in zip(tickets, rules))
    out.update(allowed=True, reason=reason, basis="FARE_RULES", fee=fee, refund=fares - fee)
    return out


async def held_until(conn: asyncpg.Connection, b) -> datetime | None:
    """When the hold of a connection's missed booking ends, while it is held (1132)."""
    return await conn.fetchval("SELECT hold_until FROM sales.connection_hold WHERE booking_id = $1 AND status = 'HELD'", b["id"])


async def release_due_holds(conn: asyncpg.Connection, ctx: db.Context) -> int:
    """Held connections whose change window ended: the escrow goes to the carrier and its partners, the tickets are
    closed as no-show and the booking completed, as when the trip was completed (1132). Run by the worker each minute."""
    from ...ledger import platform_wallet, post_txn
    done = 0
    async with db.system_scope(conn, ctx):
        due = await conn.fetch(
            """SELECT h.booking_id, h.currency, b.booking_ref FROM sales.connection_hold h JOIN sales.booking b ON b.id = h.booking_id
                WHERE h.status = 'HELD' AND h.hold_until <= now() ORDER BY h.hold_until LIMIT 200 FOR UPDATE OF h SKIP LOCKED""")
        for h in due:
            lines = await conn.fetch(
                """SELECT l.id, l.amount - l.refunded_amount AS due, l.wallet_id
                     FROM fin.price_allocation_line l JOIN fin.price_allocation a ON a.id = l.allocation_id
                    WHERE a.booking_id = $1 AND l.is_leaf AND l.release_event = 'TRIP_COMPLETED'
                      AND l.status IN ('HELD','PARTIAL_REFUND')""", h["booking_id"])
            entries = [(ln["wallet_id"], "CR", ln["due"]) for ln in lines if ln["due"] > 0]
            if entries:
                escrow = await platform_wallet(conn, "ESCROW", h["currency"])
                await post_txn(conn, "RELEASE", h["currency"], f"hold:{h['booking_id']}:release",
                               [(escrow["id"], "DR", sum(e[2] for e in entries)), *entries],
                               ref_type="booking", ref_id=h["booking_id"], memo=h["booking_ref"])
            await conn.execute("UPDATE fin.price_allocation_line SET status = 'RELEASED', released_at = now() WHERE id = ANY($1::bigint[])",
                               [ln["id"] for ln in lines])
            await conn.execute("UPDATE sales.ticket SET status = 'NO_SHOW' WHERE booking_id = $1 AND status = 'ISSUED'", h["booking_id"])
            await conn.execute("UPDATE sales.booking SET status = 'COMPLETED' WHERE id = $1 AND status = 'CONFIRMED'", h["booking_id"])
            await conn.execute("UPDATE sales.connection_hold SET status = 'RELEASED', closed_at = now() WHERE booking_id = $1", h["booking_id"])
            done += 1
    return done


OPTIONS_SQL = f"""
  SELECT DISTINCT ON (t.id) t.uid AS trip_uid, t.trip_no, t.trip_code, t.currency, a.seq AS from_seq, b.seq AS to_seq,
         a.sched_dep AS departs_at, b.sched_arr AS arrives_at, sa.name AS from_station, sb.name AS to_station,
         coalesce(pf.price, b.fare_from_origin - a.fare_from_origin) AS price,
         t.seats_total - (SELECT count(DISTINCT s.seat_no) FROM ops.seat_segment s
                           WHERE s.trip_id = t.id AND s.seg >= a.seq AND s.seg < b.seq AND NOT {repo.FREE_SEG}) AS seats_left
    FROM ops.trip t
    JOIN ops.trip_stop a ON a.trip_id = t.id JOIN net.station sa ON sa.id = a.station_id
    JOIN ops.trip_stop b ON b.trip_id = t.id AND b.seq > a.seq JOIN net.station sb ON sb.id = b.station_id
    LEFT JOIN ops.trip_pair_fare pf ON pf.trip_id = t.id AND pf.from_seq = a.seq AND pf.to_seq = b.seq
   WHERE t.company_id = $1 AND t.id <> $2 AND t.status IN ('PUBLISHED', 'BOARDING')
     AND sa.city_id = $3 AND sb.city_id = $4
     AND a.kind = 'STATION' AND b.kind = 'STATION' AND a.sellable AND a.sales_closed_at IS NULL
     AND (t.service_type = 'INDIRECT' OR (a.seq = 0 AND b.seq = t.segments_count))
     AND a.sched_dep > now() + make_interval(mins => t.sales_cutoff_min) AND a.sched_dep < now() + interval '3 days'
     AND ($5::uuid IS NULL OR (t.uid = $5 AND a.seq = $6 AND b.seq = $7))
   ORDER BY t.id, a.seq, b.seq DESC"""


async def _cities(conn: asyncpg.Connection, b) -> asyncpg.Record:
    return await conn.fetchrow(
        """SELECT sa.city_id AS from_city, sb.city_id AS to_city,
                  (SELECT count(*) FROM sales.ticket x WHERE x.booking_id = $1 AND x.status <> 'CANCELLED' AND x.seat_no IS NOT NULL) AS seated
             FROM (SELECT min(from_seq) AS f, max(to_seq) AS t, min(trip_id) AS trip_id FROM sales.ticket WHERE booking_id = $1) k
             JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.f JOIN net.station sa ON sa.id = a.station_id
             JOIN ops.trip_stop z ON z.trip_id = k.trip_id AND z.seq = k.t JOIN net.station sb ON sb.id = z.station_id""", b["id"])


async def options(conn: asyncpg.Connection, b) -> dict:
    """The booking's change state and the carrier's trips between the same cities in the next three days."""
    st = await state(conn, b)
    trips = []
    if st["allowed"]:
        c = await _cities(conn, b)
        recs = await conn.fetch(OPTIONS_SQL, b["company_id"], b["trip_id"], c["from_city"], c["to_city"], None, None, None)
        trips = [dict(r) | {"bookable": r["seats_left"] >= c["seated"]} for r in sorted(recs, key=lambda r: r["departs_at"])]
    return {"change": st, "trips": trips}


async def _passengers(conn: asyncpg.Connection, booking_id: int) -> list[PassengerIn]:
    """The booking's travellers as they were booked, the seated first; a baby on a lap names the traveller who carries them."""
    rows = await conn.fetch(
        """SELECT p.*, k.seat_no, fm.uid AS member_uid FROM sales.passenger p
             JOIN sales.ticket k ON k.passenger_id = p.id AND k.booking_id = p.booking_id AND k.status <> 'CANCELLED'
             LEFT JOIN iam.family_member fm ON fm.id = p.family_member_id
            WHERE p.booking_id = $1 ORDER BY k.seat_no IS NULL, p.id""", booking_id)
    fc = await crypto.cipher(conn)
    order = {r["id"]: i for i, r in enumerate(rows, start=1)}
    out = []
    for r in rows:
        id_no = fc.decrypt(bytes(r["id_no_enc"]), r["enc_key_id"], "sales.passenger.id_no") if r["id_no_enc"] else None
        mobile = fc.decrypt(bytes(r["mobile_enc"]), r["enc_key_id"], "sales.passenger.mobile") if r["mobile_enc"] else None
        id_type = r["id_type"] if r["id_type"] in ID_TYPES else None
        out.append(PassengerIn(
            nationality=r["nationality"] or "SY", first_name=r["first_name"] or r["full_name"], father_name=r["father_name"],
            grandfather_name=r["grandfather_name"], last_name=r["last_name"] or r["full_name"],
            category=r["passenger_category"] if r["passenger_category"] in PASSENGER_CATEGORIES else None,
            birth_date=r["birth_date"], gender=r["gender"], family_member_uid=r["member_uid"],
            id_type=id_type if (id_no or r["id_no_last4"]) else None, id_no=id_no,
            id_last4=None if id_no else r["id_no_last4"], mobile=mobile,
            passport_expiry=r["passport_expiry"] if id_type == "PASSPORT" else None,
            first_name_latin=r["first_name_latin"], father_name_latin=r["father_name_latin"],
            grandfather_name_latin=r["grandfather_name_latin"], last_name_latin=r["last_name_latin"],
            seat_no=r["seat_no"], with_adult=order.get(r["accompanied_by_passenger_id"]) if r["seat_no"] is None else None))
    return out


async def change(conn: asyncpg.Connection, ctx: db.Context, b, buyer, body: ChangeIn, seat_limit: int) -> dict:
    """Changes the booking to another trip: the old booking is cancelled with its value back less the fee, the new one
    paid from the same wallet, and the change recorded; all in the caller's transaction."""
    from .service import cancel_booking, create_booking, create_hold
    key = f"change:{body.idempotency_key}"
    done = await conn.fetchrow(
        """SELECT c.*, nb.booking_ref FROM sales.booking_change c JOIN sales.booking nb ON nb.id = c.to_booking_id
            WHERE c.from_booking_id = $1 AND nb.idempotency_key = $2""", b["id"], key)
    if done:                                                          # the same change sent again
        return {"booking_ref": done["booking_ref"], "fee": done["fee"], "refunded": done["refunded"], "paid": done["paid"],
                "currency": done["currency"], "basis": done["basis"], "reason": done["reason"], "replayed": True}
    await conn.execute("SELECT 1 FROM sales.booking WHERE id = $1 FOR UPDATE", b["id"])
    st = await state(conn, b)
    if not st["allowed"]:
        messages = {"CHANGE_WINDOW_CLOSED": "the carrier accepts a change of a missed trip only for some hours after its departure",
                    "CHANGE_NOT_ALLOWED": "the carrier does not change a missed trip; the ticket is lost",
                    "NOT_CHANGEABLE": "the fare of this booking may not be changed",
                    "CHANGE_NOT_AVAILABLE": "this booking is changed by whoever paid it, at the carrier or the agency"}
        raise ApiError(409, st["why"], messages.get(st["why"], "this booking can no longer be changed"))
    c = await _cities(conn, b)
    trip = await conn.fetchrow(OPTIONS_SQL, b["company_id"], b["trip_id"], c["from_city"], c["to_city"], body.trip_uid,
                               body.from_seq, body.to_seq)
    if trip is None:
        raise ApiError(409, "CHANGE_TRIP_INVALID", "change to another trip of the same carrier between the same cities, in the next three days")
    async with db.system_scope(conn, ctx):
        people = await _passengers(conn, b["id"])
    seated = [p for p in people if p.seat_no is not None]
    free = await conn.fetchval(
        f"""SELECT ARRAY(SELECT s.seat_no FROM ops.seat_segment s JOIN ops.trip t ON t.id = s.trip_id
                          WHERE t.uid = $1 AND s.seg >= $2 AND s.seg < $3 GROUP BY s.seat_no
                         HAVING count(*) = $3 - $2 AND bool_and({repo.FREE_SEG}) ORDER BY s.seat_no)""",
        body.trip_uid, body.from_seq, body.to_seq)
    if len(free) < len(seated):
        raise ApiError(409, "NOT_ENOUGH_SEATS", f"the trip has {len(free)} seats left for {len(seated)} travellers", seats_left=len(free))
    seats = list(free[:len(seated)])
    people = [p.model_copy(update={"seat_no": seats.pop(0)}) if p.seat_no is not None else p for p in people]
    cancelled = await cancel_booking(conn, ctx, b, buyer, reason="CHANGED", refund=st["refund"], missed=st["missed"], notify=False)
    await conn.execute("UPDATE sales.connection_hold SET status = 'CHANGED', closed_at = now() WHERE booking_id = $1 AND status = 'HELD'", b["id"])
    hold = await create_hold(conn, buyer.user_id, HoldIn(trip_uid=body.trip_uid, from_seq=body.from_seq, to_seq=body.to_seq,
                                                         seat_nos=[p.seat_no for p in people if p.seat_no is not None]), limit=seat_limit)
    new = await create_booking(conn, ctx, buyer, BookingIn(
        hold_token=uuid.UUID(hold["hold_token"]), trip_uid=body.trip_uid, from_seq=body.from_seq, to_seq=body.to_seq,
        fare_brand=st["brand"], passengers=people, idempotency_key=key, pay_with="WALLET"), option="WALLET")
    await conn.execute(
        """UPDATE sales.booking SET journey_uid = $2, journey_kind = $3, journey_leg = $4, risk_ack_at = $5, changed_from_id = $6
            WHERE id = $1""", new["booking_id"], b["journey_uid"], b["journey_kind"], b["journey_leg"], b["risk_ack_at"], b["id"])
    await conn.execute(
        """INSERT INTO sales.booking_change (from_booking_id, to_booking_id, reason, missed, inbound_late, basis, fee, refunded,
             paid, currency, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)""",
        b["id"], new["booking_id"], st["reason"], st["missed"], st["inbound_late"], st["basis"], st["fee"], cancelled["refund"],
        new["total"], b["currency"], buyer.user_id)
    return {"booking_ref": new["booking_ref"], "booking_id": new["booking_id"], "fee": st["fee"], "refunded": cancelled["refund"],
            "paid": new["total"], "currency": new["currency"], "basis": st["basis"], "reason": st["reason"]}

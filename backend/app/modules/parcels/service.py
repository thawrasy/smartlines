"""Parcels booked on a trip's hold (owner's decision 3; review of release 1.47.0, R-14).

A carrier publishes parcel tariffs: by weight, by volume, by whichever of the two costs more, a fixed price per item
(letters), or a price agreed with the customer. The price of a parcel always comes from ship.parcel_price(), which shows
the weight and volume charges next to the total, for a quote and for the booking alike.

A booking is guaranteed: in one transaction the shipment, its parcel and its leg on the chosen trip are written, the
database checks the hold under the capacity row's lock (1067: CARGO_NOT_OFFERED, CARGO_CAPACITY) and only then the
wallet is charged. Two customers taking the last space at once: one gets it, the other is refused before paying. A
guaranteed shipment cannot be committed without its leg (1078, CAPACITY_REQUIRED).

A price agreed with the customer goes through an offer: the customer asks with the parcel's size and the trip, the
carrier answers with a price valid until a time, and the customer books at that price before it lapses.
"""
from __future__ import annotations

import json
import secrets
import uuid
from decimal import Decimal
from typing import Optional

import asyncpg

from ... import db
from ...deps import Principal
from ...errors import ApiError, not_found
from ..notify.outbox import emit

SERVICE_CODE = "ECONOMY"           # the coach-hold service product the shipments of booked parcels belong to
DEFAULT_CARRIER = {"booking_mode": "ONLINE_DROPOFF", "handover_minutes": 120, "cancel_fee": 0, "no_show_fee": 0,
                   "pending_fees": None, "fees_decision": None, "stopped": False, "stopped_reason": None,
                   "address_delivery": False, "address_fee": 0}


def _j(v):
    return json.loads(v) if isinstance(v, str) else (v or {})


async def policy(conn: asyncpg.Connection) -> dict:
    """The platform's parcel policy (1147): carriers allowed by type, scheduled trips only, the shortest hand-over time,
    the prohibited items and who decides the fees."""
    return _j(await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'parcels.policy'"))


async def carrier_settings(conn: asyncpg.Connection, company_id: int) -> dict:
    r = await conn.fetchrow("SELECT * FROM ship.parcel_carrier WHERE company_id = $1", company_id)
    out = dict(DEFAULT_CARRIER) if r is None else {**dict(r), "pending_fees": _j(r["pending_fees"]) if r["pending_fees"] else None}
    out.pop("company_id", None)
    return out


async def carrier_allowed(conn: asyncpg.Connection, company_id: int, pol: Optional[dict] = None) -> Optional[str]:
    """Why a carrier may not offer parcels, or None when it may: its kind is not open, or the platform stopped it."""
    pol = pol or await policy(conn)
    kind = await conn.fetchval("SELECT company_type FROM iam.company WHERE id = $1", company_id)
    if kind not in (pol.get("carrier_types") or []):
        return "CARRIER_TYPE"
    if await conn.fetchval("SELECT stopped FROM ship.parcel_carrier WHERE company_id = $1", company_id):
        return "STOPPED"
    return None


async def require_parcel_trip(conn: asyncpg.Connection, trip: asyncpg.Record) -> dict:
    """The carrier offers parcels and the trip may take them (a scheduled trip while the policy says so); its settings."""
    pol = await policy(conn)
    why = await carrier_allowed(conn, trip["company_id"], pol)
    if why:
        raise ApiError(409, "PARCELS_NOT_OFFERED", "this carrier does not take parcels", reason=why)
    if pol.get("scheduled_only") and trip["template_id"] is None:
        raise ApiError(409, "PARCELS_SCHEDULED_ONLY", "parcels travel on scheduled trips only")
    return await carrier_settings(conn, trip["company_id"])


async def points(conn: asyncpg.Connection, company_id: int) -> list[dict]:
    rows = await conn.fetch(
        """SELECT p.uid, p.kind, p.name, p.address, p.hours, p.phone, s.code AS station_code
             FROM ship.parcel_point p LEFT JOIN net.station s ON s.id = p.station_id
            WHERE p.company_id = $1 AND p.status = 'ACTIVE' ORDER BY p.kind DESC, p.name""", company_id)
    return [{**dict(r), "uid": str(r["uid"])} for r in rows]


async def online_terms(conn: asyncpg.Connection, trip: asyncpg.Record, accept_rules: bool, drop_point_uid) -> dict:
    """What an online booking needs (1147): a carrier that books online, the sender's word on the prohibited items, a
    drop-off point of the carrier, and time left to hand it over. In phase one (N13) it is a reservation paid in cash
    when handed over; otherwise it is paid from the wallet now and still handed over by the same time."""
    from ...money_mode import no_funds
    settings = await require_parcel_trip(conn, trip)
    if settings["booking_mode"] == "COUNTER_ONLY":
        raise ApiError(409, "PARCELS_COUNTER_ONLY", "this carrier takes parcels at its counter only")
    if not accept_rules:
        raise ApiError(422, "PROHIBITED_ITEMS_ACK", "confirm the parcel holds none of the prohibited items",
                       prohibited=(await policy(conn)).get("prohibited") or [])
    point = None
    if drop_point_uid is not None:
        point = await conn.fetchval("SELECT id FROM ship.parcel_point WHERE uid = $1 AND company_id = $2 AND status = 'ACTIVE'",
                                    drop_point_uid, trip["company_id"])
        if point is None:
            raise not_found("drop-off point")
    by = await handover_by(conn, trip, settings)
    if by <= await conn.fetchval("SELECT now()"):
        raise ApiError(409, "TOO_LATE_TO_HAND_OVER", "the time to hand a parcel over for this trip has passed",
                       handover_by=by.isoformat())
    if await no_funds(conn):
        return {"reserve_until": by, "drop_point_id": point}
    return {"handover_until": by, "drop_point_id": point}


async def handover_by(conn: asyncpg.Connection, trip: asyncpg.Record, settings: dict):
    """When an online reservation must be handed over: the carrier's time before departure, never under the platform's."""
    pol = await policy(conn)
    minutes = max(int(settings["handover_minutes"]), int(pol.get("min_handover_minutes") or 0))
    return await conn.fetchval("SELECT $1::timestamptz - make_interval(mins => $2)", trip["departs_at"], minutes)


async def handover_terms(conn: asyncpg.Connection, company_id: int, delivery_mode: str, delivery_address: Optional[str],
                         secure: bool, declared_value: int) -> dict:
    """How the parcel is handed over at its destination (1183): collected at the counter, or taken to an address when the
    carrier offers it (its fee added to the price); important when the sender asks or its declared value reaches the
    platform's amount."""
    settings = await carrier_settings(conn, company_id)
    if delivery_mode == "ADDRESS":
        if not settings["address_delivery"]:
            raise ApiError(409, "NO_ADDRESS_DELIVERY", "this carrier does not take parcels to an address")
        if not delivery_address or len(delivery_address.strip()) < 5:
            raise ApiError(422, "ADDRESS_REQUIRED", "write the recipient's address")
    threshold = (await policy(conn)).get("secure_from_value")
    auto = threshold is not None and declared_value >= int(threshold) > 0
    return {"delivery_mode": delivery_mode, "delivery_address": delivery_address.strip() if delivery_mode == "ADDRESS" else None,
            "secure": bool(secure or auto), "address_fee": int(settings["address_fee"]) if delivery_mode == "ADDRESS" else 0}


def volume_m3(length_cm: float, width_cm: float, height_cm: float) -> Decimal:
    return (Decimal(str(length_cm)) * Decimal(str(width_cm)) * Decimal(str(height_cm)) / Decimal(1_000_000)).quantize(Decimal("0.0001"))


async def trip_for_parcel(conn: asyncpg.Connection, trip_uid: uuid.UUID, from_seq: int, to_seq: int) -> asyncpg.Record:
    """A published trip still open for sale between two of its stations."""
    t = await conn.fetchrow(
        """SELECT t.id, t.uid, t.trip_no, t.company_id, t.status, t.segments_count, $2::smallint AS from_seq, $3::smallint AS to_seq,
                  t.template_id,
                  a.station_id AS origin, z.station_id AS destination,
                  a.sched_dep AS departs_at, sa.code AS from_code, sz.code AS to_code
             FROM ops.trip t JOIN ops.trip_stop a ON a.trip_id = t.id AND a.seq = $2 JOIN net.station sa ON sa.id = a.station_id
             JOIN ops.trip_stop z ON z.trip_id = t.id AND z.seq = $3 JOIN net.station sz ON sz.id = z.station_id
            WHERE t.uid = $1""", trip_uid, from_seq, to_seq)
    if t is None or from_seq >= to_seq:
        raise not_found("trip segment")
    if t["status"] not in ("PUBLISHED", "BOARDING") or t["departs_at"] is None or \
            not await conn.fetchval("SELECT $1::timestamptz > now()", t["departs_at"]):
        raise ApiError(409, "TRIP_CLOSED", "this trip no longer takes parcels")
    return t


async def tariff(conn: asyncpg.Connection, uid: uuid.UUID, company_id: int) -> asyncpg.Record:
    t = await conn.fetchrow("SELECT * FROM ship.parcel_tariff WHERE uid = $1 AND company_id = $2 AND status = 'ACTIVE'", uid, company_id)
    if t is None:
        raise ApiError(404, "TARIFF_NOT_FOUND", "this carrier does not offer that parcel tariff")
    return t


async def hold_of(conn: asyncpg.Connection, trip_id: int) -> Optional[dict]:
    r = await conn.fetchrow("SELECT * FROM ship.trip_hold($1)", trip_id)
    if r is None:
        return None
    return {k: (float(v) if isinstance(v, Decimal) else v) for k, v in dict(r).items()}


async def quote(conn: asyncpg.Connection, trip: asyncpg.Record, t: asyncpg.Record, weight_kg: float, vol: Decimal) -> dict:
    breakdown = json.loads(await conn.fetchval("SELECT ship.parcel_price($1, $2, $3)::text", t["id"], Decimal(str(weight_kg)), vol))
    hold = await hold_of(conn, trip["id"])
    fits = bool(hold) and hold["free_weight_kg"] >= weight_kg \
        and (hold["free_volume_m3"] is None or hold["free_volume_m3"] >= float(vol)) \
        and (hold["free_items"] is None or hold["free_items"] >= 1)
    return {"price": breakdown, "hold": hold, "fits": fits, "agreed": t["pricing_mode"] == "NEGOTIATED"}


def _label() -> str:
    return "PB-" + "".join(secrets.choice("0123456789") for _ in range(12))


async def book(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, trip: asyncpg.Record, t: asyncpg.Record, *,
               weight_kg: float, length_cm: float, width_cm: float, height_cm: float, description: str, recipient_name: str,
               recipient_mobile: str, declared_value: int, idempotency_key: str, offer: Optional[asyncpg.Record] = None,
               reserve_until=None, drop_point_id: Optional[int] = None, counter: bool = False, sender_name: Optional[str] = None,
               handover_until=None, terms: Optional[dict] = None) -> dict:
    """Books one parcel on the trip's hold and charges the wallet, in that order, in the caller's transaction.

    reserve_until: phase one (N13, 1147) - the space is taken without payment until then; the sender pays at the counter
    when handing it over, or it is released. counter: sold and handed over at the carrier's counter, paid in cash; the
    shipper is the carrier's company and sender_name the person in front of the clerk.
    """
    from ...modular.workflows import _charge
    vol = volume_m3(length_cm, width_cm, height_cm)
    breakdown = json.loads(await conn.fetchval("SELECT ship.parcel_price($1, $2, $3)::text", t["id"], Decimal(str(weight_kg)), vol))
    if offer is not None:
        price, currency = offer["price"], offer["currency"]
        breakdown.update(total=price, basis="AGREED", offer=str(offer["uid"]))
    elif breakdown["total"] is None:
        raise ApiError(409, "PRICE_BY_AGREEMENT", "this tariff is priced by agreement with the carrier: ask for an offer first")
    else:
        price, currency = breakdown["total"], breakdown["currency"]
    terms = terms or {"delivery_mode": "PICKUP", "delivery_address": None, "secure": False, "address_fee": 0}
    if terms["address_fee"]:                                  # taken to an address (1183): the carrier's fee on top
        price += terms["address_fee"]
        breakdown.update(address_fee=terms["address_fee"], total=price)
    async with db.system_scope(conn, ctx):
        done = await conn.fetchrow(
            "SELECT tracking_no, price_breakdown FROM ship.shipment WHERE shipper_party_id = $1 AND idempotency_key = $2",
            pr.company_id if counter else pr.party_id, idempotency_key)
        if done is not None:                                  # the same request again: the booking it made, nothing charged twice
            bd = json.loads(done["price_breakdown"]) if isinstance(done["price_breakdown"], str) else done["price_breakdown"]
            return {"tracking_no": done["tracking_no"], "price": bd, "replayed": True}
        service = await conn.fetchval("SELECT id FROM ship.service_product WHERE code = $1 AND status = 'ACTIVE'", SERVICE_CODE)
        if service is None:
            raise ApiError(409, "SERVICE_OFF", "the coach hold parcel service is not active")
        for _ in range(5):
            tracking = "MB" + "".join(secrets.choice("0123456789") for _ in range(10))
            if not await conn.fetchval("SELECT 1 FROM ship.shipment WHERE tracking_no = $1", tracking):
                break
        status = "EXPECTED" if reserve_until is not None else "CREATED"
        sid = await conn.fetchval(
            """INSERT INTO ship.shipment (tracking_no, company_id, shipper_party_id, service_id, shipper_type, origin_station_id,
                 dest_station_id, payer_type, declared_value, currency, billable_weight_kg, price_breakdown, recipient_name,
                 recipient_mobile, contents, status, guaranteed, tariff_id, idempotency_key, handover_by, drop_point_id,
                 sold_at_counter, sender_name, handed_over_at, handed_over_by, paid_at, pay_method, delivery_mode, delivery_address,
                 secure)
               VALUES ($1, $2, $3, $4, 'INDIVIDUAL', $5, $6, 'SENDER', $7, $8, $9, $10::jsonb, $11, $12, $13, $16, true, $14, $15,
                       $17, $18, $19, $20, CASE WHEN $19 THEN now() END, CASE WHEN $19 THEN $21::bigint END,
                       CASE WHEN $16 = 'CREATED' THEN now() END, CASE WHEN $19 THEN 'CASH' WHEN $16 = 'CREATED' THEN 'WALLET' END,
                       $22, $23, $24)
               RETURNING id""",
            tracking, trip["company_id"], pr.company_id if counter else pr.party_id, service, trip["origin"], trip["destination"],
            declared_value, currency, Decimal(str(weight_kg)), json.dumps(breakdown), recipient_name.strip(), recipient_mobile,
            description, t["id"], idempotency_key, status, reserve_until or handover_until, drop_point_id, counter,
            sender_name.strip() if sender_name else None, pr.user_id, terms["delivery_mode"], terms["delivery_address"], terms["secure"])
        await conn.execute(
            """INSERT INTO ship.parcel (shipment_id, piece_no, label_no, weight_kg, length_cm, width_cm, height_cm, content_desc)
               VALUES ($1, 1, $2, $3, $4, $5, $6, $7)""",
            sid, _label(), Decimal(str(weight_kg)), Decimal(str(length_cm)), Decimal(str(width_cm)), Decimal(str(height_cm)), description)
        # the capacity is taken here, under the hold's lock (1067); a full hold refuses before any money moves
        await conn.execute(
            """INSERT INTO ship.shipment_leg (shipment_id, seq, mode, carrier_company_id, trip_id, from_station_id, to_station_id,
                 from_seq, to_seq, price, currency, status)
               VALUES ($1, 1, 'BUS_HOLD', $2, $3, $4, $5, $6, $7, $8, $9, 'BOOKED')""",
            sid, trip["company_id"], trip["id"], trip["origin"], trip["destination"], trip["from_seq"], trip["to_seq"], price, currency)
        if offer is not None:
            await conn.execute("UPDATE ship.parcel_offer SET status = 'ACCEPTED', shipment_id = $2 WHERE id = $1", offer["id"], sid)
        await conn.execute(
            "INSERT INTO ship.tracking_event (shipment_id, milestone, station_id, actor_user_id) VALUES ($1, 'CREATED', $2, $3)",
            sid, trip["origin"], pr.user_id)
        await emit(conn, "shipment.created", "shipment", sid,
                   {"tracking_no": tracking, "price": price, "trip_no": trip["trip_no"], "guaranteed": True}, company_id=trip["company_id"])
    if reserve_until is None and not counter:                 # paid online now; a reservation and a counter sale are paid in cash
        await _charge(conn, ctx, pr, trip["company_id"], price, currency, "SHIPMENT_PAY", f"parcel:{pr.party_id}:{idempotency_key}",
                      "shipment", t["name"])
    return {"tracking_no": tracking, "price": breakdown, "replayed": False, "status": status,
            "handover_by": (reserve_until or handover_until).isoformat() if (reserve_until or handover_until) else None}

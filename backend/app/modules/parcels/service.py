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


def volume_m3(length_cm: float, width_cm: float, height_cm: float) -> Decimal:
    return (Decimal(str(length_cm)) * Decimal(str(width_cm)) * Decimal(str(height_cm)) / Decimal(1_000_000)).quantize(Decimal("0.0001"))


async def trip_for_parcel(conn: asyncpg.Connection, trip_uid: uuid.UUID, from_seq: int, to_seq: int) -> asyncpg.Record:
    """A published trip still open for sale between two of its stations."""
    t = await conn.fetchrow(
        """SELECT t.id, t.uid, t.trip_no, t.company_id, t.status, t.segments_count, $2::smallint AS from_seq, $3::smallint AS to_seq,
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
               recipient_mobile: str, declared_value: int, idempotency_key: str, offer: Optional[asyncpg.Record] = None) -> dict:
    """Books one parcel on the trip's hold and charges the wallet, in that order, in the caller's transaction."""
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
    async with db.system_scope(conn, ctx):
        done = await conn.fetchrow(
            "SELECT tracking_no, price_breakdown FROM ship.shipment WHERE shipper_party_id = $1 AND idempotency_key = $2",
            pr.party_id, idempotency_key)
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
        sid = await conn.fetchval(
            """INSERT INTO ship.shipment (tracking_no, company_id, shipper_party_id, service_id, shipper_type, origin_station_id,
                 dest_station_id, payer_type, declared_value, currency, billable_weight_kg, price_breakdown, recipient_name,
                 recipient_mobile, contents, status, guaranteed, tariff_id, idempotency_key)
               VALUES ($1, $2, $3, $4, 'INDIVIDUAL', $5, $6, 'SENDER', $7, $8, $9, $10::jsonb, $11, $12, $13, 'CREATED', true, $14, $15)
               RETURNING id""",
            tracking, trip["company_id"], pr.party_id, service, trip["origin"], trip["destination"], declared_value, currency,
            Decimal(str(weight_kg)), json.dumps(breakdown), recipient_name.strip(), recipient_mobile, description, t["id"], idempotency_key)
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
    await _charge(conn, ctx, pr, trip["company_id"], price, currency, "SHIPMENT_PAY", f"parcel:{pr.party_id}:{idempotency_key}",
                  "shipment", t["name"])
    return {"tracking_no": tracking, "price": breakdown, "replayed": False}

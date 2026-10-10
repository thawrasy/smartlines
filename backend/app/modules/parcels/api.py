"""Parcels booked on a trip's hold, with each carrier's tariffs and prices agreed per parcel (owner's decision 3).

    Customer (passenger portal; the cargo module must be on)
    GET  /api/parcels/trips                    trips between two cities on a day that take parcels, with free hold and tariffs
    POST /api/parcels/quote                    the price of a parcel on a trip: weight and volume charges and the total
    POST /api/parcels                          book it: the hold space is taken, then the wallet is charged
    GET  /api/parcels/mine                     my parcels
    POST /api/parcels/offers                   ask the carrier for a price (tariffs priced by agreement)
    GET  /api/parcels/offers                   my requests and the prices offered
    POST /api/parcels/offers/{uid}/accept      book at the offered price before it lapses
    POST /api/parcels/offers/{uid}/withdraw    no longer wanted

    Carrier
    GET  /api/carrier/parcels/tariffs          the carrier's tariffs
    POST /api/carrier/parcels/tariffs          a new tariff (a code already active is replaced: the old one retires)
    POST /api/carrier/parcels/tariffs/{uid}/retire
    GET  /api/carrier/parcels/offers           requests waiting for a price, and the offers made
    POST /api/carrier/parcels/offers/{uid}/price    offer a price valid for some hours
    POST /api/carrier/parcels/offers/{uid}/decline
    PUT  /api/carrier/trips/{trip_uid}/hold    the hold a trip offers for parcels (weight, volume, pieces)
    GET  /api/carrier/trips/{trip_uid}/hold    what is offered, used and free, with the parcels on board
"""
from __future__ import annotations

import json
import uuid
from datetime import date, datetime, timezone
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field, model_validator

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden, not_found
from ...modular import features
from ...util import row_dict
from ..notify.outbox import emit
from . import service

customer = APIRouter(prefix="/api/parcels", tags=["parcels"])
carrier = APIRouter(prefix="/api/carrier", tags=["parcels"])
passenger = require_portal("PASSENGER")
operator = require_portal("OPERATOR")
MODES = Literal["WEIGHT", "VOLUME", "WEIGHT_AND_VOLUME", "FIXED", "NEGOTIATED"]


async def _on() -> None:
    if not await features.is_on("cargo"):
        raise ApiError(404, "MODULE_DISABLED", "module cargo is switched off")


def _need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden(f"missing permission: {' or '.join(codes)}")


def _tariff_view(t) -> dict:
    out = row_dict(t)
    for k in ("max_weight_kg", "max_volume_m3"):
        out[k] = float(t[k]) if t[k] is not None else None
    out.pop("id", None)
    out.pop("company_id", None)
    out.pop("created_by", None)
    return out


# ------------------------------------------------------------------ customer
class Size(BaseModel):
    weight_kg: float = Field(gt=0, le=1000)
    length_cm: float = Field(gt=0, le=400)
    width_cm: float = Field(gt=0, le=300)
    height_cm: float = Field(gt=0, le=300)


class ParcelQuoteIn(Size):
    trip_uid: uuid.UUID
    from_seq: int = Field(ge=0, le=60)
    to_seq: int = Field(ge=1, le=60)
    tariff_uid: uuid.UUID


class ParcelBookIn(ParcelQuoteIn):
    description: str = Field(min_length=2, max_length=200)
    recipient_name: str = Field(min_length=3, max_length=120)
    recipient_mobile: str = Field(pattern=r"^\+?[0-9]{8,15}$")
    declared_value: int = Field(default=0, ge=0, le=10_000_000_000)
    idempotency_key: str = Field(min_length=8, max_length=80)


class OfferIn(ParcelQuoteIn):
    description: str = Field(min_length=2, max_length=200)


class AcceptIn(BaseModel):
    recipient_name: str = Field(min_length=3, max_length=120)
    recipient_mobile: str = Field(pattern=r"^\+?[0-9]{8,15}$")
    declared_value: int = Field(default=0, ge=0, le=10_000_000_000)
    idempotency_key: str = Field(min_length=8, max_length=80)


@customer.get("/trips")
async def parcel_trips(request: Request, origin: str = Query(..., min_length=3, max_length=3),
                       destination: str = Query(..., min_length=3, max_length=3), on: date = Query(...),
                       pr: Principal = Depends(passenger)):
    """Trips that take parcels between two cities on a day: the segment, the free hold and the carrier's tariffs."""
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        trips = await conn.fetch(
            """SELECT DISTINCT ON (t.id) t.id, t.uid, t.trip_no, t.company_id, cp.legal_name AS carrier_name, a.seq AS from_seq,
                      b.seq AS to_seq, a.sched_dep AS departs_at, b.sched_arr AS arrives_at, sa.name AS from_station, sb.name AS to_station
                 FROM ops.trip t JOIN iam.party cp ON cp.id = t.company_id
                 JOIN ops.trip_stop a ON a.trip_id = t.id JOIN net.station sa ON sa.id = a.station_id JOIN ref.city ca ON ca.id = sa.city_id
                 JOIN ops.trip_stop b ON b.trip_id = t.id AND b.seq > a.seq JOIN net.station sb ON sb.id = b.station_id
                 JOIN ref.city cb ON cb.id = sb.city_id
                WHERE t.status IN ('PUBLISHED', 'BOARDING') AND ca.code = $1 AND cb.code = $2 AND a.kind = 'STATION' AND b.kind = 'STATION'
                  AND (a.sched_dep AT TIME ZONE ca.timezone)::date = $3 AND a.sched_dep > now()
                ORDER BY t.id, a.seq, b.seq DESC""", origin.upper(), destination.upper(), on)
        out = []
        for t in trips:
            hold = await service.hold_of(conn, t["id"])
            if hold is None:
                continue
            tariffs = await conn.fetch(
                "SELECT * FROM ship.parcel_tariff WHERE company_id = $1 AND status = 'ACTIVE' ORDER BY pricing_mode, code", t["company_id"])
            row = row_dict(t)
            row.pop("id")
            row.pop("company_id")
            out.append({**row, "hold": hold, "tariffs": [_tariff_view(x) for x in tariffs]})
    out.sort(key=lambda r: r["departs_at"])
    return {"trips": out}


@customer.post("/quote")
async def parcel_quote(body: ParcelQuoteIn, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        trip = await service.trip_for_parcel(conn, body.trip_uid, body.from_seq, body.to_seq)
        t = await service.tariff(conn, body.tariff_uid, trip["company_id"])
        return await service.quote(conn, trip, t, body.weight_kg, service.volume_m3(body.length_cm, body.width_cm, body.height_cm))


@customer.post("", status_code=201)
async def parcel_book(body: ParcelBookIn, request: Request, pr: Principal = Depends(passenger)):
    """Books a parcel on the trip's hold: the space is taken first, then the wallet is charged, in one transaction."""
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        trip = await service.trip_for_parcel(conn, body.trip_uid, body.from_seq, body.to_seq)
        t = await service.tariff(conn, body.tariff_uid, trip["company_id"])
        out = await service.book(conn, ctx, pr, trip, t, weight_kg=body.weight_kg, length_cm=body.length_cm, width_cm=body.width_cm,
                                 height_cm=body.height_cm, description=body.description.strip(), recipient_name=body.recipient_name,
                                 recipient_mobile=body.recipient_mobile, declared_value=body.declared_value,
                                 idempotency_key=body.idempotency_key)
    request.state.audit = {"action": "parcel.book", "object_type": "shipment", "object_id": None, "reason": out["tracking_no"]}
    return out


@customer.get("/mine")
async def my_parcels(request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT s.tracking_no, s.status, s.created_at, s.recipient_name, s.guaranteed, s.currency, s.price_breakdown,
                      t.trip_no, l.status AS leg_status, oa.code AS origin_code, da.code AS destination_code,
                      p.weight_kg, p.volume_m3
                 FROM ship.shipment s LEFT JOIN ship.shipment_leg l ON l.shipment_id = s.id AND l.seq = 1
                 LEFT JOIN ops.trip t ON t.id = l.trip_id LEFT JOIN ship.parcel p ON p.shipment_id = s.id AND p.piece_no = 1
                 LEFT JOIN net.station oa ON oa.id = s.origin_station_id LEFT JOIN net.station da ON da.id = s.dest_station_id
                WHERE s.shipper_party_id = $1 ORDER BY s.created_at DESC LIMIT 50""", pr.party_id)
    out = []
    for r in rows:
        d = row_dict(r)
        d["weight_kg"] = float(r["weight_kg"]) if r["weight_kg"] is not None else None
        d["volume_m3"] = float(r["volume_m3"]) if r["volume_m3"] is not None else None
        d["price_breakdown"] = r["price_breakdown"] if isinstance(r["price_breakdown"], dict) else json.loads(r["price_breakdown"] or "{}")
        out.append(d)
    return {"parcels": out}


def _offer_view(o) -> dict:
    d = row_dict(o)
    for k in ("weight_kg", "volume_m3"):
        if d.get(k) is not None:
            d[k] = float(o[k])
    for k in ("id", "tariff_id", "company_id", "requester_party_id", "requester_user_id", "trip_id", "offered_by", "shipment_id"):
        d.pop(k, None)
    return d


_OFFERS = """SELECT o.*, t.code AS tariff_code, t.name AS tariff_name, tr.trip_no, tr.uid AS trip_uid, cp.legal_name AS carrier_name,
                    s.tracking_no
               FROM ship.parcel_offer o JOIN ship.parcel_tariff t ON t.id = o.tariff_id JOIN ops.trip tr ON tr.id = o.trip_id
               JOIN iam.party cp ON cp.id = o.company_id LEFT JOIN ship.shipment s ON s.id = o.shipment_id"""


@customer.post("/offers", status_code=201)
async def ask_offer(body: OfferIn, request: Request, pr: Principal = Depends(passenger)):
    """Asks the carrier for a price for one parcel on a trip (a tariff priced by agreement)."""
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        trip = await service.trip_for_parcel(conn, body.trip_uid, body.from_seq, body.to_seq)
        t = await service.tariff(conn, body.tariff_uid, trip["company_id"])
        if t["pricing_mode"] != "NEGOTIATED":
            raise ApiError(409, "PRICE_PUBLISHED", "this tariff has a published price: book it directly")
        vol = service.volume_m3(body.length_cm, body.width_cm, body.height_cm)
        await conn.fetchval("SELECT ship.parcel_price($1, $2, $3)", t["id"], body.weight_kg, vol)   # the tariff's limits apply
        o = await conn.fetchrow(
            """INSERT INTO ship.parcel_offer (tariff_id, company_id, requester_party_id, requester_user_id, trip_id, from_seq, to_seq,
                 weight_kg, volume_m3, description) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id, uid""",
            t["id"], trip["company_id"], pr.party_id, pr.user_id, trip["id"], body.from_seq, body.to_seq, body.weight_kg, vol,
            body.description.strip())
        await emit(conn, "parcel.offer_requested", "parcel_offer", o["id"], {"offer_uid": str(o["uid"]), "trip_no": trip["trip_no"]},
                   company_id=trip["company_id"])
    return {"uid": str(o["uid"]), "status": "REQUESTED"}


@customer.get("/offers")
async def my_offers(request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(_OFFERS + " WHERE o.requester_party_id = $1 ORDER BY o.created_at DESC LIMIT 50", pr.party_id)
    return {"offers": [_offer_view(r) for r in rows]}


async def _my_offer(conn, pr: Principal, uid: uuid.UUID):
    o = await conn.fetchrow("SELECT * FROM ship.parcel_offer WHERE uid = $1 AND requester_party_id = $2 FOR UPDATE", uid, pr.party_id)
    if o is None:
        raise not_found("offer")
    return o


@customer.post("/offers/{uid}/accept", status_code=201)
async def accept_offer(uid: uuid.UUID, body: AcceptIn, request: Request, pr: Principal = Depends(passenger)):
    """Books the parcel at the price the carrier offered, while the offer is valid; the hold is checked as for any booking."""
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        o = await _my_offer(conn, pr, uid)
        if o["status"] != "OFFERED":
            raise ApiError(409, "OFFER_NOT_OPEN", "this offer cannot be accepted", offer_status=o["status"])
        if o["valid_until"] < datetime.now(timezone.utc):
            raise ApiError(409, "OFFER_EXPIRED", "the carrier's offer has lapsed")
        trip_uid = await conn.fetchval("SELECT uid FROM ops.trip WHERE id = $1", o["trip_id"])
        trip = await service.trip_for_parcel(conn, trip_uid, o["from_seq"], o["to_seq"])
        t = await conn.fetchrow("SELECT * FROM ship.parcel_tariff WHERE id = $1", o["tariff_id"])
        # the size asked for: a cube of the stated volume (the carrier measures the parcel at acceptance)
        side = max(float(o["volume_m3"]), 0.000001) ** (1 / 3) * 100
        out = await service.book(conn, ctx, pr, trip, t, weight_kg=float(o["weight_kg"]), length_cm=side, width_cm=side, height_cm=side,
                                 description=o["description"], recipient_name=body.recipient_name, recipient_mobile=body.recipient_mobile,
                                 declared_value=body.declared_value, idempotency_key=body.idempotency_key, offer=o)
    request.state.audit = {"action": "parcel.accept_offer", "object_type": "parcel_offer", "object_id": o["id"], "reason": out["tracking_no"]}
    return out


@customer.post("/offers/{uid}/withdraw")
async def withdraw_offer(uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        o = await _my_offer(conn, pr, uid)
        if o["status"] not in ("REQUESTED", "OFFERED"):
            raise ApiError(409, "OFFER_NOT_OPEN", "this offer is closed", offer_status=o["status"])
        await conn.execute("UPDATE ship.parcel_offer SET status = 'WITHDRAWN' WHERE id = $1", o["id"])
    return {"status": "WITHDRAWN"}


# ------------------------------------------------------------------ carrier
class TariffIn(BaseModel):
    code: str = Field(pattern=r"^[A-Z][A-Z0-9_]{1,29}$")
    name: str = Field(min_length=2, max_length=80)
    pricing_mode: MODES
    currency: str = Field(min_length=3, max_length=3)
    base_price: int = Field(default=0, ge=0)
    per_kg: Optional[int] = Field(default=None, ge=0)
    per_m3: Optional[int] = Field(default=None, ge=0)
    fixed_price: Optional[int] = Field(default=None, ge=0)
    min_charge: int = Field(default=0, ge=0)
    max_weight_kg: Optional[float] = Field(default=None, gt=0, le=10000)
    max_volume_m3: Optional[float] = Field(default=None, gt=0, le=100)

    @model_validator(mode="after")
    def _rates(self):
        need = {"WEIGHT": ("per_kg",), "VOLUME": ("per_m3",), "WEIGHT_AND_VOLUME": ("per_kg", "per_m3"), "FIXED": ("fixed_price",)}
        missing = [f for f in need.get(self.pricing_mode, ()) if getattr(self, f) is None]
        if missing:
            raise ValueError(f"{self.pricing_mode} needs {', '.join(missing)}")
        return self


class PriceIn(BaseModel):
    price: int = Field(gt=0)
    valid_hours: int = Field(default=24, ge=1, le=168)
    note: Optional[str] = Field(default=None, max_length=300)


class HoldIn(BaseModel):
    max_weight_kg: float = Field(ge=0, le=60000)
    max_volume_m3: Optional[float] = Field(default=None, gt=0, le=200)
    max_items: Optional[int] = Field(default=None, gt=0, le=10000)


@carrier.get("/parcels/tariffs")
async def tariffs(request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.tariffs", "shipping.operate")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch("SELECT * FROM ship.parcel_tariff WHERE company_id = $1 ORDER BY status, code, created_at DESC",
                                pr.company_id)
    return {"tariffs": [_tariff_view(r) for r in rows]}


@carrier.post("/parcels/tariffs", status_code=201)
async def add_tariff(body: TariffIn, request: Request, pr: Principal = Depends(operator)):
    """A new tariff; one with the same code still active retires, so a price change starts cleanly from now on."""
    await _on()
    _need(pr, "parcels.tariffs")
    async with db.transaction(context_for(request, pr)) as conn:
        await conn.execute("UPDATE ship.parcel_tariff SET status = 'RETIRED' WHERE company_id = $1 AND code = $2 AND status = 'ACTIVE'",
                           pr.company_id, body.code)
        r = await conn.fetchrow(
            """INSERT INTO ship.parcel_tariff (company_id, code, name, pricing_mode, currency, base_price, per_kg, per_m3, fixed_price,
                 min_charge, max_weight_kg, max_volume_m3, created_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) RETURNING *""",
            pr.company_id, body.code, body.name, body.pricing_mode, body.currency.upper(), body.base_price, body.per_kg, body.per_m3,
            body.fixed_price, body.min_charge, body.max_weight_kg, body.max_volume_m3, pr.user_id)
    request.state.audit = {"action": "parcel.tariff", "object_type": "parcel_tariff", "object_id": r["id"], "reason": body.pricing_mode}
    return _tariff_view(r)


@carrier.post("/parcels/tariffs/{uid}/retire")
async def retire_tariff(uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.tariffs")
    async with db.transaction(context_for(request, pr)) as conn:
        done = await conn.fetchval(
            "UPDATE ship.parcel_tariff SET status = 'RETIRED' WHERE uid = $1 AND company_id = $2 AND status = 'ACTIVE' RETURNING id",
            uid, pr.company_id)
    if done is None:
        raise not_found("tariff")
    return {"status": "RETIRED"}


@carrier.get("/parcels/offers")
async def carrier_offers(request: Request, status: Optional[str] = None, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.tariffs", "shipping.operate")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(_OFFERS + " WHERE o.company_id = $1 AND ($2::text IS NULL OR o.status = $2) ORDER BY o.created_at DESC LIMIT 200",
                                pr.company_id, status)
    return {"offers": [_offer_view(r) for r in rows]}


async def _carrier_offer(conn, pr: Principal, uid: uuid.UUID):
    o = await conn.fetchrow("SELECT * FROM ship.parcel_offer WHERE uid = $1 AND company_id = $2 FOR UPDATE", uid, pr.company_id)
    if o is None:
        raise not_found("offer")
    return o


@carrier.post("/parcels/offers/{uid}/price")
async def price_offer(uid: uuid.UUID, body: PriceIn, request: Request, pr: Principal = Depends(operator)):
    """The carrier's price for the parcel, valid for some hours (and never past the trip's departure)."""
    await _on()
    _need(pr, "parcels.tariffs", "shipping.operate")
    async with db.transaction(context_for(request, pr)) as conn:
        o = await _carrier_offer(conn, pr, uid)
        if o["status"] not in ("REQUESTED", "OFFERED"):
            raise ApiError(409, "OFFER_NOT_OPEN", "this request is closed", offer_status=o["status"])
        currency = await conn.fetchval("SELECT currency FROM ship.parcel_tariff WHERE id = $1", o["tariff_id"])
        until = await conn.fetchval(
            """SELECT least(now() + make_interval(hours => $3),
                            (SELECT sched_dep FROM ops.trip_stop WHERE trip_id = $1 AND seq = $2))""", o["trip_id"], o["from_seq"],
            body.valid_hours)
        await conn.execute(
            """UPDATE ship.parcel_offer SET status = 'OFFERED', price = $2, currency = $3, valid_until = $4, note = $5, offered_by = $6,
                 offered_at = now() WHERE id = $1""", o["id"], body.price, currency, until, body.note, pr.user_id)
        await emit(conn, "parcel.offer_priced", "parcel_offer", o["id"], {"offer_uid": str(uid), "price": body.price, "currency": currency},
                   company_id=pr.company_id)
    request.state.audit = {"action": "parcel.offer_price", "object_type": "parcel_offer", "object_id": o["id"], "reason": str(body.price)}
    return {"status": "OFFERED", "price": body.price, "currency": currency, "valid_until": until.isoformat()}


@carrier.post("/parcels/offers/{uid}/decline")
async def decline_offer(uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.tariffs", "shipping.operate")
    async with db.transaction(context_for(request, pr)) as conn:
        o = await _carrier_offer(conn, pr, uid)
        if o["status"] not in ("REQUESTED", "OFFERED"):
            raise ApiError(409, "OFFER_NOT_OPEN", "this request is closed", offer_status=o["status"])
        await conn.execute("UPDATE ship.parcel_offer SET status = 'DECLINED' WHERE id = $1", o["id"])
    return {"status": "DECLINED"}


async def _own_trip(conn, pr: Principal, trip_uid: uuid.UUID):
    t = await conn.fetchrow("SELECT id, trip_no, status FROM ops.trip WHERE uid = $1 AND company_id = $2", trip_uid, pr.company_id)
    if t is None:
        raise not_found("trip")
    return t


@carrier.put("/trips/{trip_uid}/hold")
async def set_hold(trip_uid: uuid.UUID, body: HoldIn, request: Request, pr: Principal = Depends(operator)):
    """The hold a trip offers for parcels; never more than its vehicle may carry nor less than what is loaded (1067)."""
    await _on()
    _need(pr, "shipping.operate", "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _own_trip(conn, pr, trip_uid)
        await conn.execute(
            """INSERT INTO ship.trip_cargo_capacity (trip_id, max_weight_kg, max_volume_m3, max_items) VALUES ($1, $2, $3, $4)
               ON CONFLICT (trip_id) DO UPDATE SET max_weight_kg = EXCLUDED.max_weight_kg, max_volume_m3 = EXCLUDED.max_volume_m3,
                 max_items = EXCLUDED.max_items""", t["id"], body.max_weight_kg, body.max_volume_m3, body.max_items)
        hold = await service.hold_of(conn, t["id"])
    request.state.audit = {"action": "parcel.hold", "object_type": "trip", "object_id": t["id"], "reason": f"{body.max_weight_kg} kg"}
    return {"trip_no": t["trip_no"], "hold": hold}


@carrier.get("/trips/{trip_uid}/hold")
async def get_hold(trip_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.tariffs", "shipping.operate", "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _own_trip(conn, pr, trip_uid)
        hold = await service.hold_of(conn, t["id"])
        parcels = await conn.fetch(
            """SELECT s.tracking_no, s.status, l.status AS leg_status, l.from_seq, l.to_seq, p.weight_kg, p.volume_m3, s.contents
                 FROM ship.shipment_leg l JOIN ship.shipment s ON s.id = l.shipment_id
                 LEFT JOIN ship.parcel p ON p.shipment_id = s.id AND p.piece_no = 1
                WHERE l.trip_id = $1 AND l.status <> 'CANCELLED' ORDER BY l.id""", t["id"])
    return {"trip_no": t["trip_no"], "hold": hold,
            "parcels": [{**row_dict(p), "weight_kg": float(p["weight_kg"]) if p["weight_kg"] is not None else None,
                         "volume_m3": float(p["volume_m3"]) if p["volume_m3"] is not None else None} for p in parcels]}


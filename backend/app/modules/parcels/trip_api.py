"""Parcels on scheduled trips (owner's decision N5, 1147): the platform's policy, each carrier's choices, its drop-off
points, the counter, hand-over and the label.

    Customer (passenger portal)
    GET  /api/parcels/rules                         prohibited items and the shortest hand-over time
    POST /api/parcels/{tracking_no}/cancel          a reservation not yet handed over is released

    Carrier
    GET  /api/carrier/parcels/settings              booking online or at the counter only, hand-over time, fees
    PUT  /api/carrier/parcels/settings
    GET  /api/carrier/parcels/points                its stations and offices that receive parcels
    POST /api/carrier/parcels/points
    POST /api/carrier/parcels/points/{uid}/close
    POST /api/carrier/parcels/counter               a parcel sold and handed over at the counter, paid in cash
    GET  /api/carrier/parcels/awaiting              online reservations waiting to be handed over
    POST /api/carrier/parcels/{tracking_no}/receive the sender hands it over (and pays in cash if not paid)
    GET  /api/carrier/parcels/{tracking_no}/label   what the label shows, with its signed code

    Platform (policy.matrix)
    GET  /api/admin/parcels/policy                  who may offer parcels, scheduled trips only, prohibited items, fees
    PUT  /api/admin/parcels/policy
    GET  /api/admin/parcels/carriers                each carrier's choices, fees waiting for a decision
    PUT  /api/admin/parcels/carriers/{uid}/stop     stop or resume one carrier's parcels, with a reason
    POST /api/admin/parcels/carriers/{uid}/fees     approve or reject a carrier's new fees (when the platform regulates them)
"""
from __future__ import annotations

import json
import uuid
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_permission, require_portal
from ...errors import ApiError, forbidden, not_found
from ...security import parcel_label_token
from ...util import row_dict
from ..notify.outbox import emit
from . import service
from .api import Size, _on

customer = APIRouter(prefix="/api/parcels", tags=["parcels"])
carrier = APIRouter(prefix="/api/carrier/parcels", tags=["parcels"])
platform = APIRouter(prefix="/api/admin/parcels", tags=["parcels"])
passenger = require_portal("PASSENGER")
operator = require_portal("OPERATOR")
policy_staff = require_permission("policy.matrix")
MOBILE = r"^\+?[0-9]{8,15}$"


def _need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden(f"missing permission: {' or '.join(codes)}")


async def _shipment(conn: asyncpg.Connection, tracking_no: str, **where) -> asyncpg.Record:
    s = await conn.fetchrow(
        """SELECT s.*, l.trip_id, l.id AS leg_id FROM ship.shipment s
             LEFT JOIN ship.shipment_leg l ON l.shipment_id = s.id AND l.seq = 1
            WHERE s.tracking_no = $1 AND ($2::bigint IS NULL OR s.company_id = $2) AND ($3::bigint IS NULL OR s.shipper_party_id = $3)
            FOR UPDATE OF s""", tracking_no.upper(), where.get("company_id"), where.get("shipper_party_id"))
    if s is None:
        raise not_found("parcel")
    return s


async def _release(conn: asyncpg.Connection, s: asyncpg.Record, reason: str) -> None:
    await conn.execute("UPDATE ship.shipment SET status = 'CANCELLED', release_reason = $2, updated_at = now() WHERE id = $1", s["id"], reason)
    await conn.execute("UPDATE ship.shipment_leg SET status = 'CANCELLED' WHERE shipment_id = $1 AND status <> 'CANCELLED'", s["id"])


# ------------------------------------------------------------------ customer
@customer.get("/rules")
async def rules(request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        pol = await service.policy(conn)
    return {"prohibited": pol.get("prohibited") or [], "min_handover_minutes": pol.get("min_handover_minutes"),
            "scheduled_only": bool(pol.get("scheduled_only"))}


@customer.post("/{tracking_no}/cancel")
async def cancel_reservation(tracking_no: str, request: Request, pr: Principal = Depends(passenger)):
    """A reservation not handed over and not paid is released, and its hold space with it."""
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _shipment(conn, tracking_no, shipper_party_id=pr.party_id)
        if s["status"] != "EXPECTED" or s["paid_at"] is not None:
            raise ApiError(409, "PARCEL_NOT_RESERVED", "only a reservation not yet handed over can be cancelled here",
                           parcel_status=s["status"])
        await _release(conn, s, "CANCELLED_BY_SENDER")
    return {"tracking_no": s["tracking_no"], "status": "CANCELLED"}


# ------------------------------------------------------------------ carrier: settings and points
class SettingsIn(BaseModel):
    booking_mode: Literal["ONLINE_DROPOFF", "COUNTER_ONLY"]
    handover_minutes: int = Field(ge=15, le=2880)
    cancel_fee: int = Field(ge=0, le=100_000_000)
    no_show_fee: int = Field(ge=0, le=100_000_000)


class PointIn(BaseModel):
    kind: Literal["STATION", "OFFICE"]
    station_uid: Optional[uuid.UUID] = None
    name: str = Field(min_length=2, max_length=120)
    address: str = Field(min_length=3, max_length=300)
    hours: str = Field(min_length=2, max_length=200)
    phone: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{6,15}$")


async def _settings_view(conn: asyncpg.Connection, company_id: int) -> dict:
    pol = await service.policy(conn)
    s = await service.carrier_settings(conn, company_id)
    return {**s, "allowed": await service.carrier_allowed(conn, company_id, pol) is None,
            "not_allowed_reason": await service.carrier_allowed(conn, company_id, pol),
            "min_handover_minutes": pol.get("min_handover_minutes"), "fee_policy": pol.get("fee_policy", "CARRIER"),
            "prohibited": pol.get("prohibited") or [], "updated_at": s["updated_at"].isoformat() if s.get("updated_at") else None}


@carrier.get("/settings")
async def get_settings(request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.tariffs", "parcels.counter", "shipping.operate")
    async with db.transaction(context_for(request, pr)) as conn:
        return await _settings_view(conn, pr.company_id)


@carrier.put("/settings")
async def put_settings(body: SettingsIn, request: Request, pr: Principal = Depends(operator)):
    """The carrier's choices. Its fees apply at once while the carrier decides them; when the platform regulates them
    the new fees wait for its decision and the approved ones stay in force meanwhile."""
    await _on()
    _need(pr, "parcels.tariffs")
    async with db.transaction(context_for(request, pr)) as conn:
        pol = await service.policy(conn)
        if body.handover_minutes < int(pol.get("min_handover_minutes") or 0):
            raise ApiError(422, "HANDOVER_TOO_SHORT", "the hand-over time is shorter than the platform allows",
                           min_handover_minutes=pol.get("min_handover_minutes"))
        current = await service.carrier_settings(conn, pr.company_id)
        regulated = pol.get("fee_policy") == "PLATFORM"
        fees_changed = (body.cancel_fee, body.no_show_fee) != (current["cancel_fee"], current["no_show_fee"])
        pending = {"cancel_fee": body.cancel_fee, "no_show_fee": body.no_show_fee} if regulated and fees_changed else None
        cancel_fee, no_show_fee = (current["cancel_fee"], current["no_show_fee"]) if pending else (body.cancel_fee, body.no_show_fee)
        await conn.execute(
            """INSERT INTO ship.parcel_carrier (company_id, booking_mode, handover_minutes, cancel_fee, no_show_fee, pending_fees, updated_by)
               VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7)
               ON CONFLICT (company_id) DO UPDATE SET booking_mode = EXCLUDED.booking_mode, handover_minutes = EXCLUDED.handover_minutes,
                 cancel_fee = EXCLUDED.cancel_fee, no_show_fee = EXCLUDED.no_show_fee,
                 pending_fees = coalesce(EXCLUDED.pending_fees, CASE WHEN $8 THEN ship.parcel_carrier.pending_fees END),
                 updated_by = EXCLUDED.updated_by, updated_at = now()""",
            pr.company_id, body.booking_mode, body.handover_minutes, cancel_fee, no_show_fee,
            json.dumps(pending) if pending else None, pr.user_id, regulated and not fees_changed)
        out = await _settings_view(conn, pr.company_id)
    request.state.audit = {"action": "parcel.settings", "object_type": "company", "object_id": pr.company_id,
                           "reason": f"{body.booking_mode} {body.handover_minutes} min" + (" (fees pending)" if pending else "")}
    return out


@carrier.get("/points")
async def list_points(request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.tariffs", "parcels.counter", "shipping.operate")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT p.uid, p.kind, p.name, p.address, p.hours, p.phone, p.status, s.code AS station_code, s.uid AS station_uid
                 FROM ship.parcel_point p LEFT JOIN net.station s ON s.id = p.station_id
                WHERE p.company_id = $1 ORDER BY p.status, p.kind DESC, p.name""", pr.company_id)
    return {"points": [row_dict(r) for r in rows]}


@carrier.post("/points", status_code=201)
async def add_point(body: PointIn, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.tariffs")
    async with db.transaction(context_for(request, pr)) as conn:
        station = None
        if body.kind == "STATION":
            if body.station_uid is None:
                raise ApiError(422, "STATION_REQUIRED", "choose the station")
            station = await conn.fetchval("SELECT id FROM net.station WHERE uid = $1", body.station_uid)
            if station is None:
                raise not_found("station")
        r = await conn.fetchrow(
            """INSERT INTO ship.parcel_point (company_id, kind, station_id, name, address, hours, phone, created_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id, uid""",
            pr.company_id, body.kind, station, body.name.strip(), body.address.strip(), body.hours.strip(), body.phone, pr.user_id)
    request.state.audit = {"action": "parcel.point", "object_type": "parcel_point", "object_id": r["id"], "reason": body.name}
    return {"uid": str(r["uid"]), "status": "ACTIVE"}


@carrier.post("/points/{uid}/close")
async def close_point(uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.tariffs")
    async with db.transaction(context_for(request, pr)) as conn:
        done = await conn.fetchval("UPDATE ship.parcel_point SET status = 'CLOSED' WHERE uid = $1 AND company_id = $2 RETURNING id",
                                   uid, pr.company_id)
    if done is None:
        raise not_found("drop-off point")
    return {"status": "CLOSED"}


# ------------------------------------------------------------------ carrier: the counter
class CounterParcelIn(Size):
    trip_uid: uuid.UUID
    from_seq: int = Field(ge=0, le=60)
    to_seq: int = Field(ge=1, le=60)
    tariff_uid: uuid.UUID
    description: str = Field(min_length=2, max_length=200)
    sender_name: str = Field(min_length=3, max_length=120)
    recipient_name: str = Field(min_length=3, max_length=120)
    recipient_mobile: str = Field(pattern=MOBILE)
    declared_value: int = Field(default=0, ge=0, le=10_000_000_000)
    accept_rules: bool = False
    idempotency_key: str = Field(min_length=8, max_length=80)


class ReceiveIn(BaseModel):
    weight_kg: Optional[float] = Field(default=None, gt=0, le=1000)   # as weighed at the counter, when it differs


def _label_view(r: asyncpg.Record) -> dict:
    d = row_dict(r)
    d["weight_kg"] = float(r["weight_kg"]) if r["weight_kg"] is not None else None
    d["code"] = parcel_label_token(r["tracking_no"], r["label_no"])
    return d


async def _label(conn: asyncpg.Connection, tracking_no: str, company_id: int) -> dict:
    r = await conn.fetchrow(
        """SELECT s.tracking_no, p.label_no, s.status, s.sender_name, sp.legal_name AS shipper_name, s.recipient_name,
                  s.recipient_mobile, s.contents, p.weight_kg, t.trip_no, a.code AS from_code, sa.name AS from_station,
                  z.code AS to_code, sz.name AS to_station, st.sched_dep AS departs_at, s.paid_at, s.pay_method, s.handed_over_at,
                  s.price_breakdown ->> 'total' AS price, s.currency, cp.legal_name AS carrier_name
             FROM ship.shipment s JOIN ship.parcel p ON p.shipment_id = s.id AND p.piece_no = 1
             JOIN ship.shipment_leg l ON l.shipment_id = s.id AND l.seq = 1 JOIN ops.trip t ON t.id = l.trip_id
             JOIN ops.trip_stop st ON st.trip_id = t.id AND st.seq = l.from_seq
             JOIN net.station a ON a.id = l.from_station_id JOIN net.station z ON z.id = l.to_station_id
             JOIN net.station sa ON sa.id = l.from_station_id JOIN net.station sz ON sz.id = l.to_station_id
             LEFT JOIN iam.party sp ON sp.id = s.shipper_party_id JOIN iam.party cp ON cp.id = s.company_id
            WHERE s.tracking_no = $1 AND s.company_id = $2""", tracking_no.upper(), company_id)
    if r is None:
        raise not_found("parcel")
    return _label_view(r)


@carrier.post("/counter", status_code=201)
async def counter_sale(body: CounterParcelIn, request: Request, pr: Principal = Depends(operator)):
    """A parcel the clerk sells and receives at once, paid in cash; the label is printed straight away."""
    await _on()
    _need(pr, "parcels.counter")
    if not body.accept_rules:
        raise ApiError(422, "PROHIBITED_ITEMS_ACK", "confirm the parcel holds none of the prohibited items")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        trip = await service.trip_for_parcel(conn, body.trip_uid, body.from_seq, body.to_seq)
        if trip["company_id"] != pr.company_id:
            raise not_found("trip")
        await service.require_parcel_trip(conn, trip)
        t = await service.tariff(conn, body.tariff_uid, trip["company_id"])
        out = await service.book(conn, ctx, pr, trip, t, weight_kg=body.weight_kg, length_cm=body.length_cm, width_cm=body.width_cm,
                                 height_cm=body.height_cm, description=body.description.strip(), recipient_name=body.recipient_name,
                                 recipient_mobile=body.recipient_mobile, declared_value=body.declared_value,
                                 idempotency_key=body.idempotency_key, counter=True, sender_name=body.sender_name)
        label = await _label(conn, out["tracking_no"], pr.company_id)
    request.state.audit = {"action": "parcel.counter_sale", "object_type": "shipment", "object_id": None, "reason": out["tracking_no"]}
    return {**out, "label": label}


@carrier.get("/awaiting")
async def awaiting(request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.counter", "shipping.operate")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT s.tracking_no, s.status, s.handover_by, s.paid_at, s.recipient_name, s.contents, s.price_breakdown ->> 'total' AS price,
                      s.currency, sp.legal_name AS shipper_name, t.trip_no, st.sched_dep AS departs_at, pp.name AS drop_point
                 FROM ship.shipment s JOIN ship.shipment_leg l ON l.shipment_id = s.id AND l.seq = 1 JOIN ops.trip t ON t.id = l.trip_id
                 JOIN ops.trip_stop st ON st.trip_id = t.id AND st.seq = l.from_seq LEFT JOIN iam.party sp ON sp.id = s.shipper_party_id
                 LEFT JOIN ship.parcel_point pp ON pp.id = s.drop_point_id
                WHERE s.company_id = $1 AND s.handed_over_at IS NULL AND s.status IN ('EXPECTED', 'CREATED') AND st.sched_dep > now()
                ORDER BY s.handover_by NULLS LAST LIMIT 200""", pr.company_id)
    return {"parcels": [row_dict(r) for r in rows]}


@carrier.post("/{tracking_no}/receive")
async def receive(tracking_no: str, body: ReceiveIn, request: Request, pr: Principal = Depends(operator)):
    """The sender hands the parcel over: paid in cash now if it was a reservation; the hold is checked again if it weighs more."""
    await _on()
    _need(pr, "parcels.counter")
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _shipment(conn, tracking_no, company_id=pr.company_id)
        if s["handed_over_at"] is not None:
            raise ApiError(409, "ALREADY_HANDED_OVER", "this parcel was already received")
        if s["status"] not in ("EXPECTED", "CREATED"):
            raise ApiError(409, "PARCEL_NOT_OPEN", "this parcel can no longer be received", parcel_status=s["status"])
        if body.weight_kg is not None:
            await conn.execute("UPDATE ship.parcel SET weight_kg = $2 WHERE shipment_id = $1 AND piece_no = 1", s["id"], body.weight_kg)
            await conn.execute("UPDATE ship.shipment SET billable_weight_kg = $2 WHERE id = $1", s["id"], body.weight_kg)
        await conn.execute(
            """UPDATE ship.shipment SET status = 'CREATED', handed_over_at = now(), handed_over_by = $2,
                 paid_at = coalesce(paid_at, now()), pay_method = coalesce(pay_method, 'CASH'), updated_at = now() WHERE id = $1""",
            s["id"], pr.user_id)
        await conn.execute(
            "INSERT INTO ship.tracking_event (shipment_id, milestone, station_id, actor_user_id) VALUES ($1, 'PICKED_UP', $2, $3)",
            s["id"], s["origin_station_id"], pr.user_id)
        await emit(conn, "parcel.handed_over", "shipment", s["id"], {"tracking_no": s["tracking_no"], "shipper_party_id": s["shipper_party_id"]},
                   company_id=pr.company_id)
        label = await _label(conn, tracking_no, pr.company_id)
    request.state.audit = {"action": "parcel.receive", "object_type": "shipment", "object_id": s["id"], "reason": s["tracking_no"]}
    return label


@carrier.get("/{tracking_no}/label")
async def label(tracking_no: str, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "parcels.counter", "shipping.operate")
    async with db.transaction(context_for(request, pr)) as conn:
        out = await _label(conn, tracking_no, pr.company_id)
    if out["handed_over_at"] is None:
        raise ApiError(409, "NOT_HANDED_OVER", "the label is printed when the parcel is handed over")
    return out


# ------------------------------------------------------------------ platform
class PolicyIn(BaseModel):
    carrier_types: list[Literal["CARRIER", "INDIVIDUAL_OPERATOR", "FOREIGN_CARRIER"]]
    scheduled_only: bool
    min_handover_minutes: int = Field(ge=15, le=1440)
    fee_policy: Literal["CARRIER", "PLATFORM"]
    prohibited: list[str] = Field(min_length=1, max_length=60)
    reason: str = Field(min_length=5, max_length=300)


class StopIn(BaseModel):
    stopped: bool
    reason: str = Field(min_length=5, max_length=300)


class FeesDecisionIn(BaseModel):
    approve: bool
    reason: str = Field(min_length=5, max_length=300)


@platform.get("/policy")
async def get_policy(request: Request, pr: Principal = Depends(policy_staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.policy(conn)


@platform.put("/policy")
async def put_policy(body: PolicyIn, request: Request, pr: Principal = Depends(policy_staff)):
    items = [i.strip() for i in body.prohibited if i.strip()]
    if not items or any(len(i) > 80 for i in items):
        raise ApiError(422, "INVALID_SETTING", "each prohibited item is 1 to 80 characters")
    value = {"carrier_types": body.carrier_types, "scheduled_only": body.scheduled_only,
             "min_handover_minutes": body.min_handover_minutes, "fee_policy": body.fee_policy, "prohibited": items}
    async with db.transaction(context_for(request, pr)) as conn:
        await conn.execute("UPDATE sys.setting SET value = $1::jsonb, updated_by = $2, updated_at = now() WHERE key = 'parcels.policy'",
                           json.dumps(value), pr.user_id)
        out = await service.policy(conn)
    request.state.audit = {"action": "parcel.policy", "object_type": "setting", "object_id": None, "reason": body.reason}
    return out


async def _company(conn: asyncpg.Connection, uid: uuid.UUID) -> asyncpg.Record:
    c = await conn.fetchrow("SELECT c.id, p.legal_name FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1", uid)
    if c is None:
        raise not_found("carrier")
    return c


@platform.get("/carriers")
async def carriers(request: Request, pr: Principal = Depends(policy_staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        pol = await service.policy(conn)
        rows = await conn.fetch(
            """SELECT p.uid, p.legal_name, c.company_type, pc.booking_mode, pc.handover_minutes, pc.cancel_fee, pc.no_show_fee,
                      pc.pending_fees, pc.stopped, pc.stopped_reason,
                      (SELECT count(*) FROM ship.parcel_point pp WHERE pp.company_id = c.id AND pp.status = 'ACTIVE') AS points,
                      (SELECT count(*) FROM ship.parcel_tariff t WHERE t.company_id = c.id AND t.status = 'ACTIVE') AS tariffs
                 FROM iam.company c JOIN iam.party p ON p.id = c.id LEFT JOIN ship.parcel_carrier pc ON pc.company_id = c.id
                WHERE c.company_type IN ('CARRIER', 'INDIVIDUAL_OPERATOR', 'FOREIGN_CARRIER') AND c.approval_status = 'APPROVED'
                ORDER BY p.legal_name""")
    out = []
    for r in rows:
        d = row_dict(r)
        d["pending_fees"] = json.loads(r["pending_fees"]) if isinstance(r["pending_fees"], str) else r["pending_fees"]
        d["type_allowed"] = r["company_type"] in (pol.get("carrier_types") or [])
        d["stopped"] = bool(r["stopped"])
        out.append(d)
    return {"carriers": out, "policy": pol}


@platform.put("/carriers/{uid}/stop")
async def stop_carrier(uid: uuid.UUID, body: StopIn, request: Request, pr: Principal = Depends(policy_staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        c = await _company(conn, uid)
        await conn.execute(
            """INSERT INTO ship.parcel_carrier (company_id, stopped, stopped_reason, updated_by) VALUES ($1, $2, $3, $4)
               ON CONFLICT (company_id) DO UPDATE SET stopped = EXCLUDED.stopped, stopped_reason = EXCLUDED.stopped_reason,
                 updated_by = EXCLUDED.updated_by, updated_at = now()""", c["id"], body.stopped, body.reason.strip(), pr.user_id)
        await emit(conn, "parcel.carrier_stopped" if body.stopped else "parcel.carrier_resumed", "company", c["id"],
                   {"reason": body.reason.strip(), "carrier_name": c["legal_name"]}, company_id=c["id"])
    request.state.audit = {"action": "parcel.carrier_stop", "object_type": "company", "object_id": c["id"],
                           "reason": f"{'stop' if body.stopped else 'resume'}: {body.reason}"}
    return {"stopped": body.stopped}


@platform.post("/carriers/{uid}/fees")
async def decide_fees(uid: uuid.UUID, body: FeesDecisionIn, request: Request, pr: Principal = Depends(policy_staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        c = await _company(conn, uid)
        pending = await conn.fetchval("SELECT pending_fees FROM ship.parcel_carrier WHERE company_id = $1 FOR UPDATE", c["id"])
        if not pending:
            raise ApiError(409, "NO_PENDING_FEES", "this carrier has no fees waiting for a decision")
        fees = json.loads(pending) if isinstance(pending, str) else pending
        if body.approve:
            await conn.execute(
                """UPDATE ship.parcel_carrier SET cancel_fee = $2, no_show_fee = $3, pending_fees = NULL, fees_decision = $4,
                     updated_by = $5, updated_at = now() WHERE company_id = $1""",
                c["id"], fees["cancel_fee"], fees["no_show_fee"], f"approved: {body.reason.strip()}", pr.user_id)
        else:
            await conn.execute(
                """UPDATE ship.parcel_carrier SET pending_fees = NULL, fees_decision = $2, updated_by = $3, updated_at = now()
                    WHERE company_id = $1""", c["id"], f"rejected: {body.reason.strip()}", pr.user_id)
        await emit(conn, "parcel.fees_decided", "company", c["id"], {"approved": body.approve, "reason": body.reason.strip(), **fees},
                   company_id=c["id"])
    request.state.audit = {"action": "parcel.fees", "object_type": "company", "object_id": c["id"],
                           "reason": f"{'approve' if body.approve else 'reject'}: {body.reason}"}
    return {"approved": body.approve}

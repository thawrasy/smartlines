"""A parcel's journey after it is handed over (review of the parcel system, 26 October 2026; migration 1182;
docs/design/PARCEL_JOURNEY.md).

The carrier's staff scan the parcel's label (or type its tracking number) when it goes on board and again when it is
taken off at the destination station. It then waits for its recipient, who collects it with a six-digit code the sender
received with the arrival notice (the code is drawn from the parcel and the moment it arrived, so it is never stored;
only its keyed hash is kept, with a limit of wrong tries) or, when the code is lost or the tries are spent, after an
identity check the clerk records. A parcel damaged, missing or refused is an exception with its note; one not collected
within the policy's days may be sent back. Every step is a tracking milestone the sender and the public tracking page see.

    Carrier (shipping.operate or parcels.counter)
    POST /api/carrier/parcels/scan/load             {code | tracking_no, trip_uid?}: on board
    POST /api/carrier/parcels/scan/arrive           {code | tracking_no}: taken off at the destination; the code goes out
    GET  /api/carrier/parcels/waiting               parcels waiting for their recipients, with the days waited
    POST /api/carrier/parcels/{tracking_no}/deliver {pickup_code | id_checked + id_note, delivered_to}
    POST /api/carrier/parcels/{tracking_no}/exception {kind, note}
    POST /api/carrier/parcels/{tracking_no}/return  {note}: an exception's parcel goes back to its sender

    Sender (passenger portal)
    GET  /api/parcels/{tracking_no}/journey         the milestones, and the pickup code while the parcel waits
"""
from __future__ import annotations

import hashlib
import hmac
import json
from datetime import datetime
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field, model_validator

from ... import db
from ...config import get_settings
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden, not_found
from ...security import verify_parcel_label
from ...util import row_dict
from ..notify.outbox import emit
from .api import _on

carrier = APIRouter(prefix="/api/carrier/parcels", tags=["parcels"])
customer = APIRouter(prefix="/api/parcels", tags=["parcels"])
operator = require_portal("OPERATOR")
passenger = require_portal("PASSENGER")


def _staff(pr: Principal) -> None:
    if not pr.permissions.intersection(("shipping.operate", "parcels.counter")):
        raise forbidden("missing permission: shipping.operate or parcels.counter")


# ------------------------------------------------------------------ the pickup code
def _key() -> bytes:
    return hmac.new(get_settings().signing_secret.encode(), b"parcel-pickup", hashlib.sha256).digest()


def pickup_code(tracking_no: str, arrived_at: datetime | str) -> str:
    """Six digits drawn from the parcel and the moment it arrived: the same every time it is shown, never stored."""
    stamp = arrived_at.isoformat() if isinstance(arrived_at, datetime) else str(arrived_at)
    digest = hmac.new(_key(), f"{tracking_no}|{stamp}".encode(), hashlib.sha256).digest()
    return f"{int.from_bytes(digest[:6], 'big') % 1_000_000:06d}"


def _code_hash(tracking_no: str, code: str) -> bytes:
    return hmac.new(_key(), f"check|{tracking_no}|{code}".encode(), hashlib.sha256).digest()


# ------------------------------------------------------------------ shared
async def _policy(conn) -> dict:
    v = await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'parcels.policy'")
    return json.loads(v) if isinstance(v, str) else (v or {})


class ScanIn(BaseModel):
    code: Optional[str] = Field(default=None, min_length=10, max_length=200)      # the label's signed code
    tracking_no: Optional[str] = Field(default=None, min_length=4, max_length=40)

    @model_validator(mode="after")
    def _one(self):
        if (self.code is None) == (self.tracking_no is None):
            raise ValueError("scan the label or type the tracking number")
        return self

    def number(self) -> str:
        if self.code:
            read = verify_parcel_label(self.code.strip())
            if read is None:
                raise ApiError(422, "LABEL_INVALID", "this is not a parcel label of the platform")
            return read[0]
        return (self.tracking_no or "").strip().upper()


async def _parcel(conn, tracking_no: str, company_id: int) -> asyncpg.Record:
    s = await conn.fetchrow(
        """SELECT s.*, l.id AS leg_id, l.trip_id, l.status AS leg_status, t.uid AS trip_uid, t.trip_no,
                  sz.name AS dest_station, cp.legal_name AS carrier_name
             FROM ship.shipment s JOIN ship.shipment_leg l ON l.shipment_id = s.id AND l.seq = 1
             JOIN ops.trip t ON t.id = l.trip_id LEFT JOIN net.station sz ON sz.id = s.dest_station_id
             JOIN iam.party cp ON cp.id = s.company_id
            WHERE s.tracking_no = $1 AND s.company_id = $2 FOR UPDATE OF s""", tracking_no, company_id)
    if s is None:
        raise not_found("parcel")
    return s


async def _milestone(conn, s, milestone: str, station_id, user_id: int, reason: Optional[str] = None) -> None:
    await conn.execute(
        """INSERT INTO ship.tracking_event (shipment_id, leg_id, milestone, reason_code, station_id, actor_user_id)
           VALUES ($1, $2, $3, $4, $5, $6)""", s["id"], s["leg_id"], milestone, reason, station_id, user_id)


def _audit(request: Request, action: str, s, reason: Optional[str] = None) -> None:
    request.state.audit = {"action": action, "object_type": "shipment", "object_id": s["id"],
                           "reason": f"{s['tracking_no']}: {reason}" if reason else s["tracking_no"]}


def _notice(s, **extra) -> dict:
    return {"tracking_no": s["tracking_no"], "shipper_party_id": s["shipper_party_id"], "recipient_name": s["recipient_name"],
            "recipient_mobile": s["recipient_mobile"], "station": s["dest_station"], "carrier": s["carrier_name"], **extra}


# ------------------------------------------------------------------ on board and off
class LoadIn(ScanIn):
    trip_uid: Optional[str] = None      # the trip being loaded: a parcel booked on another trip is refused


@carrier.post("/scan/load")
async def scan_load(body: LoadIn, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, body.number(), pr.company_id)
        if body.trip_uid and str(s["trip_uid"]) != body.trip_uid:
            raise ApiError(409, "PARCEL_OTHER_TRIP", "this parcel travels on another trip", trip_no=s["trip_no"])
        if s["handed_over_at"] is None or s["status"] in ("CANCELLED", "RETURNED", "DELIVERED"):
            raise ApiError(409, "PARCEL_NOT_READY", "this parcel was not handed over, or its journey is over", parcel_status=s["status"])
        if s["loaded_at"] is not None:
            raise ApiError(409, "PARCEL_ON_BOARD", "this parcel is already on board")
        await conn.execute("UPDATE ship.shipment SET loaded_at = now(), loaded_by = $2, status = 'IN_NETWORK', updated_at = now() WHERE id = $1",
                           s["id"], pr.user_id)
        await conn.execute("UPDATE ship.shipment_leg SET status = 'IN_TRANSIT' WHERE id = $1", s["leg_id"])
        await _milestone(conn, s, "LOADED", s["origin_station_id"], pr.user_id)
    _audit(request, "parcel.loaded", s)
    return {"tracking_no": s["tracking_no"], "trip_no": s["trip_no"], "recipient_name": s["recipient_name"], "status": "IN_NETWORK"}


@carrier.post("/scan/arrive")
async def scan_arrive(body: ScanIn, request: Request, pr: Principal = Depends(operator)):
    """Taken off at the destination station: the parcel waits for its recipient, and the sender is sent the pickup code."""
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, body.number(), pr.company_id)
        if s["loaded_at"] is None:
            raise ApiError(409, "PARCEL_NOT_LOADED", "scan this parcel on board before it arrives")
        if s["arrived_at"] is not None:
            raise ApiError(409, "PARCEL_ARRIVED", "this parcel has already arrived")
        arrived = await conn.fetchval("SELECT now()")
        await conn.execute(
            """UPDATE ship.shipment SET arrived_at = $2, arrived_by = $3, pickup_code_hash = $4, pickup_code_tries = 0,
                      updated_at = now() WHERE id = $1""",
            s["id"], arrived, pr.user_id, _code_hash(s["tracking_no"], pickup_code(s["tracking_no"], arrived)))
        await conn.execute("UPDATE ship.shipment_leg SET status = 'HANDED_OVER' WHERE id = $1", s["leg_id"])
        await _milestone(conn, s, "ARRIVED", s["dest_station_id"], pr.user_id)
        days = int((await _policy(conn)).get("unclaimed_days", 7))
        await emit(conn, "parcel.arrived", "shipment", s["id"], _notice(s, arrived_at=arrived.isoformat(), days=days),
                   company_id=pr.company_id)
    _audit(request, "parcel.arrived", s)
    return {"tracking_no": s["tracking_no"], "recipient_name": s["recipient_name"], "station": s["dest_station"], "waits_days": days}


@carrier.get("/waiting")
async def waiting(request: Request, pr: Principal = Depends(operator)):
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        days = int((await _policy(conn)).get("unclaimed_days", 7))
        rows = await conn.fetch(
            """SELECT s.tracking_no, s.recipient_name, s.recipient_mobile, s.contents, s.arrived_at, s.exception_kind,
                      s.exception_note, s.pickup_code_tries, sz.name AS station, t.trip_no,
                      (now() - s.arrived_at) > make_interval(days => $2) AS overdue,
                      extract(day FROM now() - s.arrived_at)::int AS days_waited
                 FROM ship.shipment s JOIN ship.shipment_leg l ON l.shipment_id = s.id AND l.seq = 1
                 JOIN ops.trip t ON t.id = l.trip_id LEFT JOIN net.station sz ON sz.id = s.dest_station_id
                WHERE s.company_id = $1 AND s.arrived_at IS NOT NULL AND s.delivered_at IS NULL AND s.returned_at IS NULL
                ORDER BY s.arrived_at LIMIT 300""", pr.company_id, days)
    return {"unclaimed_days": days, "parcels": [row_dict(r) for r in rows]}


# ------------------------------------------------------------------ to the recipient
class DeliverIn(BaseModel):
    pickup_code: Optional[str] = Field(default=None, pattern=r"^\d{6}$")
    id_checked: bool = False                                         # the clerk saw the recipient's identity document
    id_note: Optional[str] = Field(default=None, min_length=3, max_length=120)   # which document, its last digits
    delivered_to: str = Field(min_length=3, max_length=120)

    @model_validator(mode="after")
    def _how(self):
        if self.pickup_code is None and not (self.id_checked and self.id_note):
            raise ValueError("the pickup code, or an identity check with its note")
        return self


@carrier.post("/{tracking_no}/deliver")
async def deliver(tracking_no: str, body: DeliverIn, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, tracking_no.strip().upper(), pr.company_id)
        if s["arrived_at"] is None or s["delivered_at"] is not None or s["returned_at"] is not None:
            raise ApiError(409, "PARCEL_NOT_WAITING", "this parcel is not waiting for its recipient", parcel_status=s["status"])
        tries = int((await _policy(conn)).get("pickup_code_tries", 5))
        method, wrong = "ID", None
        if body.pickup_code is not None:
            if s["pickup_code_tries"] >= tries:
                raise ApiError(423, "PICKUP_CODE_LOCKED", "too many wrong codes: hand it over after an identity check")
            if not hmac.compare_digest(bytes(s["pickup_code_hash"]), _code_hash(s["tracking_no"], body.pickup_code)):
                # the wrong try is kept: the transaction ends normally and the refusal is raised after it
                await conn.execute("UPDATE ship.shipment SET pickup_code_tries = pickup_code_tries + 1 WHERE id = $1", s["id"])
                wrong = max(tries - s["pickup_code_tries"] - 1, 0)
            method = "OTP"
        if wrong is None:
            await _handed(conn, s, body, method, pr.user_id)
            await emit(conn, "parcel.delivered", "shipment", s["id"], _notice(s, delivered_to=body.delivered_to.strip(), method=method),
                       company_id=pr.company_id)
    if wrong is not None:
        raise ApiError(422, "PICKUP_CODE_WRONG", "the code does not match", tries_left=wrong)
    _audit(request, "parcel.delivered", s, method)
    return {"tracking_no": s["tracking_no"], "status": "DELIVERED", "method": method, "cod_collected": s["cod_amount"] or 0}


async def _handed(conn, s, body: DeliverIn, method: str, user_id: int) -> None:
    """The parcel leaves the counter: its proof, the cash on delivery collected, the milestone."""
    await conn.execute("UPDATE ship.shipment SET delivered_at = now(), delivered_by = $2, status = 'DELIVERED', updated_at = now() WHERE id = $1",
                       s["id"], user_id)
    await conn.execute("UPDATE ship.shipment_leg SET status = 'COMPLETED' WHERE id = $1", s["leg_id"])
    attempt = await conn.fetchval(
        """INSERT INTO ship.delivery_attempt (shipment_id, attempt_no, courier_user_id, result)
           VALUES ($1, (SELECT coalesce(max(attempt_no), 0) + 1 FROM ship.delivery_attempt WHERE shipment_id = $1), $2, 'DELIVERED')
           RETURNING id""", s["id"], user_id)
    to = body.delivered_to.strip() + (f" ({body.id_note.strip()})" if method == "ID" and body.id_note else "")
    await conn.execute("INSERT INTO ship.delivery_proof (shipment_id, attempt_id, method, delivered_to) VALUES ($1, $2, $3, $4)",
                       s["id"], attempt, method, to[:200])
    if s["cod_amount"]:
        await conn.execute(
            """INSERT INTO ship.cod_collection (shipment_id, amount, currency, collected_at, collected_by, status)
               VALUES ($1, $2, $3, now(), $4, 'COLLECTED') ON CONFLICT (shipment_id) DO NOTHING""",
            s["id"], s["cod_amount"], s["currency"], user_id)
    await _milestone(conn, s, "DELIVERED", s["dest_station_id"], user_id, method)


class ExceptionIn(BaseModel):
    kind: Literal["DAMAGED", "MISSING", "REFUSED", "UNCLAIMED"]
    note: str = Field(min_length=3, max_length=300)


@carrier.post("/{tracking_no}/exception")
async def exception(tracking_no: str, body: ExceptionIn, request: Request, pr: Principal = Depends(operator)):
    """Damaged or missing (at loading or arrival), refused by the recipient, or not collected within the policy's days."""
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, tracking_no.strip().upper(), pr.company_id)
        if s["handed_over_at"] is None or s["delivered_at"] is not None or s["returned_at"] is not None or s["status"] == "CANCELLED":
            raise ApiError(409, "PARCEL_NOT_OPEN", "this parcel's journey is over", parcel_status=s["status"])
        if body.kind in ("REFUSED", "UNCLAIMED") and s["arrived_at"] is None:
            raise ApiError(409, "PARCEL_NOT_WAITING", "only a parcel waiting at its station is refused or unclaimed")
        if body.kind == "UNCLAIMED":
            days = int((await _policy(conn)).get("unclaimed_days", 7))
            if not await conn.fetchval("SELECT now() - $1::timestamptz > make_interval(days => $2)", s["arrived_at"], days):
                raise ApiError(409, "PARCEL_NOT_OVERDUE", "the parcel has not yet waited the policy's days", days=days)
        await conn.execute(
            "UPDATE ship.shipment SET exception_kind = $2, exception_note = $3, status = 'EXCEPTION', updated_at = now() WHERE id = $1",
            s["id"], body.kind, body.note.strip())
        await _milestone(conn, s, "EXCEPTION", s["dest_station_id"] if s["arrived_at"] else s["origin_station_id"], pr.user_id, body.kind)
        await emit(conn, "parcel.exception", "shipment", s["id"], _notice(s, kind=body.kind, note=body.note.strip()),
                   company_id=pr.company_id)
    _audit(request, "parcel.exception", s, f"{body.kind}: {body.note}")
    return {"tracking_no": s["tracking_no"], "status": "EXCEPTION", "kind": body.kind}


class ReturnIn(BaseModel):
    note: str = Field(min_length=3, max_length=300)


@carrier.post("/{tracking_no}/return")
async def send_back(tracking_no: str, body: ReturnIn, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, tracking_no.strip().upper(), pr.company_id)
        if s["exception_kind"] is None or s["returned_at"] is not None or s["delivered_at"] is not None:
            raise ApiError(409, "PARCEL_NO_EXCEPTION", "a parcel goes back after an exception is recorded")
        await conn.execute("UPDATE ship.shipment SET returned_at = now(), status = 'RETURNED', updated_at = now() WHERE id = $1", s["id"])
        await _milestone(conn, s, "RETURNED", s["dest_station_id"], pr.user_id, s["exception_kind"])
    _audit(request, "parcel.returned", s, body.note)
    return {"tracking_no": s["tracking_no"], "status": "RETURNED"}


# ------------------------------------------------------------------ the sender
@customer.get("/{tracking_no}/journey")
async def journey(tracking_no: str, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        s = await conn.fetchrow(
            """SELECT s.id, s.tracking_no, s.status, s.recipient_name, s.handed_over_at, s.loaded_at, s.arrived_at, s.delivered_at,
                      s.returned_at, s.exception_kind, s.exception_note, sz.name AS station
                 FROM ship.shipment s LEFT JOIN net.station sz ON sz.id = s.dest_station_id
                WHERE s.tracking_no = $1 AND s.shipper_party_id = $2""", tracking_no.strip().upper(), pr.party_id)
        if s is None:
            raise not_found("parcel")
        events = await conn.fetch(
            """SELECT e.milestone, e.reason_code, e.ts, st.name AS place FROM ship.tracking_event e
                 LEFT JOIN net.station st ON st.id = e.station_id WHERE e.shipment_id = $1 ORDER BY e.ts, e.id""", s["id"])
    out = row_dict(s)
    out.pop("id")
    waiting_now = s["arrived_at"] is not None and s["delivered_at"] is None and s["returned_at"] is None and s["exception_kind"] is None
    out["pickup_code"] = pickup_code(s["tracking_no"], s["arrived_at"]) if waiting_now else None
    out["events"] = [row_dict(e) for e in events]
    return out

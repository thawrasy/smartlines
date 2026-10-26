"""A parcel's journey after it is handed over (review of the parcel system and the owner's note of 26 October 2026;
migrations 1182 and 1183; docs/design/PARCEL_JOURNEY.md).

The carrier's staff scan the parcel's label (or type its tracking number) when it goes on board. A carrier with several
locations along the way receives it at each one and sends it on to the next (A, then B, then C, ... Z); every location is
a step its sender follows. At the destination the parcel is taken off and handed over in one of two ways:

* collected at the counter (the default): the six-digit pickup code goes to the recipient's mobile and the sender's
  account on arrival; the clerk can send it again when the recipient asks;
* taken to the recipient's address, when the carrier switched it on in its settings and the sender chose it: arrival is
  announced, and the code goes out when the parcel leaves for the address; a failed attempt brings it back to the station
  and the next departure issues a new code.

The code is drawn from the parcel and the moment it was issued, so it is never stored; only its keyed hash is kept, with
a limit of wrong tries. Without the code (lost, or the tries spent) the parcel is handed over after an identity check
recorded field by field: the document's kind, its number (encrypted, its last four digits shown), the holder and the
issuer. An important parcel (the sender's choice, or a declared value from the platform's amount) needs both the code and
the identity check, and its sender is told of every step. A parcel damaged, missing or refused is an exception with its
note; one not collected within the policy's days may be sent back.

    Carrier (shipping.operate or parcels.counter)
    POST /api/carrier/parcels/scan/load             {code | tracking_no, trip_uid?}: on board
    POST /api/carrier/parcels/scan/receive          {code | tracking_no, point_uid}: received at one of the carrier's locations
    POST /api/carrier/parcels/scan/dispatch         {code | tracking_no, next_point_uid?}: sent on from there
    POST /api/carrier/parcels/scan/arrive           {code | tracking_no}: taken off at the destination
    GET  /api/carrier/parcels/waiting               parcels at the destination, with the days waited
    POST /api/carrier/parcels/{tracking_no}/send-code   the code again, to the recipient's mobile
    POST /api/carrier/parcels/{tracking_no}/out     leaves for the address; the code goes out
    POST /api/carrier/parcels/{tracking_no}/attempt-failed {reason, responsible}: back at the station
    POST /api/carrier/parcels/{tracking_no}/deliver {pickup_code?, id_check?, delivered_to}
    POST /api/carrier/parcels/{tracking_no}/exception {kind, note}
    POST /api/carrier/parcels/{tracking_no}/return  {note}: an exception's parcel goes back to its sender

    Sender (passenger portal)
    GET  /api/parcels/{tracking_no}/journey         the steps, the locations passed, and the code while it is valid
"""
from __future__ import annotations

import hashlib
import hmac
import json
import uuid
from datetime import datetime
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field, model_validator

from ... import crypto, db
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


def pickup_code(tracking_no: str, issued_at: datetime | str) -> str:
    """Six digits drawn from the parcel and the moment its code was issued: the same every time it is shown, never stored."""
    stamp = issued_at.isoformat() if isinstance(issued_at, datetime) else str(issued_at)
    digest = hmac.new(_key(), f"{tracking_no}|{stamp}".encode(), hashlib.sha256).digest()
    return f"{int.from_bytes(digest[:6], 'big') % 1_000_000:06d}"


def _code_hash(tracking_no: str, code: str) -> bytes:
    return hmac.new(_key(), f"check|{tracking_no}|{code}".encode(), hashlib.sha256).digest()


async def _issue_code(conn, s) -> datetime:
    """A new code for the parcel: its moment, its hash, the wrong tries and the sends counted afresh."""
    at = await conn.fetchval("SELECT now()")
    await conn.execute(
        "UPDATE ship.shipment SET code_issued_at = $2, pickup_code_hash = $3, pickup_code_tries = 0, code_sends = 0 WHERE id = $1",
        s["id"], at, _code_hash(s["tracking_no"], pickup_code(s["tracking_no"], at)))
    return at


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
                  sz.name AS dest_station, cp.legal_name AS carrier_name,
                  (SELECT h.id FROM ship.parcel_hop h WHERE h.shipment_id = s.id AND h.dispatched_at IS NULL) AS open_hop
             FROM ship.shipment s JOIN ship.shipment_leg l ON l.shipment_id = s.id AND l.seq = 1
             JOIN ops.trip t ON t.id = l.trip_id LEFT JOIN net.station sz ON sz.id = s.dest_station_id
             JOIN iam.party cp ON cp.id = s.company_id
            WHERE s.tracking_no = $1 AND s.company_id = $2 FOR UPDATE OF s""", tracking_no, company_id)
    if s is None:
        raise not_found("parcel")
    return s


async def _point(conn, uid: uuid.UUID, company_id: int) -> asyncpg.Record:
    p = await conn.fetchrow("SELECT id, name, station_id FROM ship.parcel_point WHERE uid = $1 AND company_id = $2 AND status = 'ACTIVE'",
                            uid, company_id)
    if p is None:
        raise not_found("location")
    return p


async def _milestone(conn, s, milestone: str, station_id, user_id: int, reason: Optional[str] = None) -> None:
    await conn.execute(
        """INSERT INTO ship.tracking_event (shipment_id, leg_id, milestone, reason_code, station_id, actor_user_id)
           VALUES ($1, $2, $3, $4, $5, $6)""", s["id"], s["leg_id"], milestone, reason, station_id, user_id)


def _audit(request: Request, action: str, s, reason: Optional[str] = None) -> None:
    request.state.audit = {"action": action, "object_type": "shipment", "object_id": s["id"],
                           "reason": f"{s['tracking_no']}: {reason}" if reason else s["tracking_no"]}


def _notice(s, **extra) -> dict:
    return {"tracking_no": s["tracking_no"], "shipper_party_id": s["shipper_party_id"], "recipient_name": s["recipient_name"],
            "recipient_mobile": s["recipient_mobile"], "station": s["dest_station"], "carrier": s["carrier_name"],
            "delivery_mode": s["delivery_mode"], "secure": s["secure"], **extra}


def _moving(s) -> None:
    """Between loading and arrival, not stopped by an exception."""
    if s["loaded_at"] is None:
        raise ApiError(409, "PARCEL_NOT_LOADED", "scan this parcel on board first")
    if s["arrived_at"] is not None:
        raise ApiError(409, "PARCEL_ARRIVED", "this parcel has already arrived")
    if s["exception_kind"] is not None:
        raise ApiError(409, "PARCEL_NOT_OPEN", "a problem is recorded on this parcel", parcel_status=s["status"])


# ------------------------------------------------------------------ on board, through the locations, off
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
        await emit(conn, "parcel.moved", "shipment", s["id"], _notice(s, step="LOADED", place=None), company_id=pr.company_id)
    _audit(request, "parcel.loaded", s)
    return {"tracking_no": s["tracking_no"], "trip_no": s["trip_no"], "recipient_name": s["recipient_name"], "status": "IN_NETWORK"}


class ReceiveIn(ScanIn):
    point_uid: uuid.UUID                # the location receiving it


@carrier.post("/scan/receive")
async def scan_receive(body: ReceiveIn, request: Request, pr: Principal = Depends(operator)):
    """Received at one of the carrier's locations on the way; it stays there until it is sent on."""
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, body.number(), pr.company_id)
        _moving(s)
        if s["open_hop"] is not None:
            raise ApiError(409, "PARCEL_AT_LOCATION", "this parcel is at a location: send it on before another receives it")
        p = await _point(conn, body.point_uid, pr.company_id)
        last = await conn.fetchrow("SELECT seq, next_point_id FROM ship.parcel_hop WHERE shipment_id = $1 ORDER BY seq DESC LIMIT 1", s["id"])
        if last is not None and last["next_point_id"] is not None and last["next_point_id"] != p["id"]:
            expected = await conn.fetchval("SELECT name FROM ship.parcel_point WHERE id = $1", last["next_point_id"])
            raise ApiError(409, "PARCEL_OTHER_LOCATION", "this parcel was sent to another location", expected=expected)
        await conn.execute(
            "INSERT INTO ship.parcel_hop (company_id, shipment_id, seq, point_id, received_by) VALUES ($1, $2, $3, $4, $5)",
            pr.company_id, s["id"], (last["seq"] + 1) if last else 1, p["id"], pr.user_id)
        await _milestone(conn, s, "RECEIVED_AT_HUB", p["station_id"], pr.user_id, p["name"][:40])
        await emit(conn, "parcel.moved", "shipment", s["id"], _notice(s, step="RECEIVED", place=p["name"]), company_id=pr.company_id)
    _audit(request, "parcel.received_at", s, p["name"])
    return {"tracking_no": s["tracking_no"], "recipient_name": s["recipient_name"], "location": p["name"]}


class DispatchIn(ScanIn):
    next_point_uid: Optional[uuid.UUID] = None    # the next location; none when it goes on to the destination


@carrier.post("/scan/dispatch")
async def scan_dispatch(body: DispatchIn, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, body.number(), pr.company_id)
        _moving(s)
        if s["open_hop"] is None:
            raise ApiError(409, "PARCEL_NOT_AT_LOCATION", "this parcel was not received at a location")
        here = await conn.fetchrow("SELECT h.point_id, p.name FROM ship.parcel_hop h JOIN ship.parcel_point p ON p.id = h.point_id "
                                   "WHERE h.id = $1", s["open_hop"])
        nxt = await _point(conn, body.next_point_uid, pr.company_id) if body.next_point_uid else None
        if nxt is not None and nxt["id"] == here["point_id"]:
            raise ApiError(422, "SAME_LOCATION", "the next location is the one it is at")
        await conn.execute("UPDATE ship.parcel_hop SET dispatched_at = now(), dispatched_by = $2, next_point_id = $3 WHERE id = $1",
                           s["open_hop"], pr.user_id, nxt["id"] if nxt else None)
        await _milestone(conn, s, "DEPARTED", None, pr.user_id, here["name"][:40])
    _audit(request, "parcel.dispatched", s, f"{here['name']} -> {nxt['name'] if nxt else 'destination'}")
    return {"tracking_no": s["tracking_no"], "from": here["name"], "to": nxt["name"] if nxt else s["dest_station"]}


@carrier.post("/scan/arrive")
async def scan_arrive(body: ScanIn, request: Request, pr: Principal = Depends(operator)):
    """Taken off at the destination. Collected at the counter: the code goes out now. Taken to an address: arrival is
    announced, and the code goes out when it leaves for the address."""
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, body.number(), pr.company_id)
        _moving(s)
        if s["open_hop"] is not None:
            raise ApiError(409, "PARCEL_AT_LOCATION", "this parcel is at a location on the way: send it on first")
        code_at = await _issue_code(conn, s) if s["delivery_mode"] == "PICKUP" else None
        await conn.execute("UPDATE ship.shipment SET arrived_at = coalesce($2, now()), arrived_by = $3, updated_at = now() WHERE id = $1",
                           s["id"], code_at, pr.user_id)
        await conn.execute("UPDATE ship.shipment_leg SET status = 'HANDED_OVER' WHERE id = $1", s["leg_id"])
        await _milestone(conn, s, "ARRIVED", s["dest_station_id"], pr.user_id)
        days = int((await _policy(conn)).get("unclaimed_days", 7))
        await emit(conn, "parcel.arrived", "shipment", s["id"],
                   _notice(s, code_at=code_at.isoformat() if code_at else None, days=days, address=s["delivery_address"]),
                   company_id=pr.company_id)
    _audit(request, "parcel.arrived", s)
    return {"tracking_no": s["tracking_no"], "recipient_name": s["recipient_name"], "station": s["dest_station"], "waits_days": days,
            "delivery_mode": s["delivery_mode"]}


@carrier.get("/waiting")
async def waiting(request: Request, pr: Principal = Depends(operator)):
    """Parcels at the destination, not yet handed over or sent back; and those at the carrier's locations on the way."""
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        pol = await _policy(conn)
        days = int(pol.get("unclaimed_days", 7))
        rows = await conn.fetch(
            """SELECT s.tracking_no, s.recipient_name, s.recipient_mobile, s.contents, s.arrived_at, s.exception_kind,
                      s.exception_note, s.pickup_code_tries, s.code_sends, s.delivery_mode, s.delivery_address, s.secure,
                      s.out_for_delivery_at, sz.name AS station, t.trip_no,
                      (now() - s.arrived_at) > make_interval(days => $2) AS overdue,
                      extract(day FROM now() - s.arrived_at)::int AS days_waited
                 FROM ship.shipment s JOIN ship.shipment_leg l ON l.shipment_id = s.id AND l.seq = 1
                 JOIN ops.trip t ON t.id = l.trip_id LEFT JOIN net.station sz ON sz.id = s.dest_station_id
                WHERE s.company_id = $1 AND s.arrived_at IS NOT NULL AND s.delivered_at IS NULL AND s.returned_at IS NULL
                ORDER BY s.arrived_at LIMIT 300""", pr.company_id, days)
        at_points = await conn.fetch(
            """SELECT s.tracking_no, s.recipient_name, s.contents, s.secure, p.name AS location, h.received_at
                 FROM ship.parcel_hop h JOIN ship.shipment s ON s.id = h.shipment_id JOIN ship.parcel_point p ON p.id = h.point_id
                WHERE h.company_id = $1 AND h.dispatched_at IS NULL ORDER BY h.received_at LIMIT 300""", pr.company_id)
    return {"unclaimed_days": days, "code_tries": int(pol.get("pickup_code_tries", 5)), "code_sends": int(pol.get("code_sends", 3)),
            "parcels": [row_dict(r) for r in rows], "at_locations": [row_dict(r) for r in at_points]}


def _waiting(s) -> None:
    if s["arrived_at"] is None or s["delivered_at"] is not None or s["returned_at"] is not None or s["exception_kind"] is not None:
        raise ApiError(409, "PARCEL_NOT_WAITING", "this parcel is not waiting for its recipient", parcel_status=s["status"])


# ------------------------------------------------------------------ the code again, and the trip to the address
@carrier.post("/{tracking_no}/send-code")
async def send_code(tracking_no: str, request: Request, pr: Principal = Depends(operator)):
    """The recipient asks at the counter or on the doorstep: the same code goes to their mobile again, a few times at most."""
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, tracking_no.strip().upper(), pr.company_id)
        _waiting(s)
        if s["code_issued_at"] is None:
            raise ApiError(409, "NO_CODE_YET", "the code goes out when the parcel leaves for the address")
        limit = int((await _policy(conn)).get("code_sends", 3))
        if s["code_sends"] >= limit:
            raise ApiError(429, "CODE_SENDS_SPENT", "the code was sent again as often as allowed: hand it over after an identity check",
                           limit=limit)
        await conn.execute("UPDATE ship.shipment SET code_sends = code_sends + 1 WHERE id = $1", s["id"])
        await emit(conn, "parcel.code_sent", "shipment", s["id"], _notice(s, code_at=s["code_issued_at"].isoformat()),
                   company_id=pr.company_id)
    _audit(request, "parcel.code_sent", s)
    return {"tracking_no": s["tracking_no"], "sends_left": limit - s["code_sends"] - 1}


@carrier.post("/{tracking_no}/out")
async def out_for_delivery(tracking_no: str, request: Request, pr: Principal = Depends(operator)):
    """The parcel leaves for the recipient's address: a new code goes to the recipient, who gives it on the doorstep."""
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, tracking_no.strip().upper(), pr.company_id)
        _waiting(s)
        if s["delivery_mode"] != "ADDRESS":
            raise ApiError(409, "PARCEL_FOR_PICKUP", "this parcel is collected at the counter")
        if s["out_for_delivery_at"] is not None:
            raise ApiError(409, "PARCEL_OUT", "this parcel is already on its way to the address")
        code_at = await _issue_code(conn, s)
        await conn.execute("UPDATE ship.shipment SET out_for_delivery_at = $2, out_by = $3, status = 'OUT_FOR_DELIVERY', "
                           "updated_at = now() WHERE id = $1", s["id"], code_at, pr.user_id)
        await _milestone(conn, s, "OUT_FOR_DELIVERY", s["dest_station_id"], pr.user_id)
        await emit(conn, "parcel.out_for_delivery", "shipment", s["id"], _notice(s, code_at=code_at.isoformat(), address=s["delivery_address"]),
                   company_id=pr.company_id)
    _audit(request, "parcel.out_for_delivery", s)
    return {"tracking_no": s["tracking_no"], "status": "OUT_FOR_DELIVERY", "address": s["delivery_address"]}


class AttemptIn(BaseModel):
    reason: Literal["NOBODY_HOME", "WRONG_ADDRESS", "REFUSED_AT_DOOR", "NO_CODE", "ACCESS", "OTHER"]
    responsible: Literal["CUSTOMER", "NETWORK"] = "CUSTOMER"


@carrier.post("/{tracking_no}/attempt-failed")
async def attempt_failed(tracking_no: str, body: AttemptIn, request: Request, pr: Principal = Depends(operator)):
    """Not delivered at the address: the attempt is recorded and the parcel is back at the station, its code withdrawn."""
    await _on()
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _parcel(conn, tracking_no.strip().upper(), pr.company_id)
        _waiting(s)
        if s["out_for_delivery_at"] is None:
            raise ApiError(409, "PARCEL_NOT_OUT", "this parcel is not on its way to the address")
        await conn.execute(
            """INSERT INTO ship.delivery_attempt (shipment_id, attempt_no, courier_user_id, result, reason_code, responsible)
               VALUES ($1, (SELECT coalesce(max(attempt_no), 0) + 1 FROM ship.delivery_attempt WHERE shipment_id = $1), $2, 'FAILED', $3, $4)""",
            s["id"], pr.user_id, body.reason, body.responsible)
        await conn.execute("UPDATE ship.shipment SET out_for_delivery_at = NULL, out_by = NULL, code_issued_at = NULL, "
                           "pickup_code_hash = NULL, status = 'IN_NETWORK', updated_at = now() WHERE id = $1", s["id"])
        await _milestone(conn, s, "DELIVERY_ATTEMPTED", s["dest_station_id"], pr.user_id, body.reason)
        await emit(conn, "parcel.moved", "shipment", s["id"], _notice(s, step="ATTEMPT_FAILED", place=None, reason=body.reason),
                   company_id=pr.company_id)
    _audit(request, "parcel.attempt_failed", s, body.reason)
    return {"tracking_no": s["tracking_no"], "status": "IN_NETWORK"}


# ------------------------------------------------------------------ to the recipient
class IdCheckIn(BaseModel):
    doc_kind: Literal["NATIONAL_ID", "PASSPORT", "FAMILY_BOOK", "RESIDENCE", "DRIVING_LICENCE", "OTHER"]
    doc_no: str = Field(min_length=4, max_length=40, pattern="^[A-Za-z0-9\\u0660-\\u0669 /-]+$")
    holder_name: str = Field(min_length=3, max_length=120)
    issued_by: Optional[str] = Field(default=None, min_length=2, max_length=120)


class DeliverIn(BaseModel):
    pickup_code: Optional[str] = Field(default=None, pattern=r"^\d{6}$")
    id_check: Optional[IdCheckIn] = None                 # the identity document the clerk saw
    delivered_to: str = Field(min_length=3, max_length=120)

    @model_validator(mode="after")
    def _how(self):
        if self.pickup_code is None and self.id_check is None:
            raise ValueError("the pickup code, or an identity check")
        return self


@carrier.post("/{tracking_no}/deliver")
async def deliver(tracking_no: str, body: DeliverIn, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _staff(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        s = await _parcel(conn, tracking_no.strip().upper(), pr.company_id)
        _waiting(s)
        if s["delivery_mode"] == "ADDRESS" and s["out_for_delivery_at"] is None:
            raise ApiError(409, "PARCEL_NOT_OUT", "a parcel for an address is handed over on its way there")
        tries = int((await _policy(conn)).get("pickup_code_tries", 5))
        locked = s["pickup_code_tries"] >= tries
        if s["secure"] and body.id_check is None:
            raise ApiError(422, "ID_CHECK_REQUIRED", "an important parcel is handed over only after an identity check")
        if s["secure"] and body.pickup_code is None and not locked:
            raise ApiError(422, "CODE_REQUIRED", "an important parcel needs the recipient's code as well")
        method, wrong = "ID", None
        if body.pickup_code is not None:
            if locked:
                raise ApiError(423, "PICKUP_CODE_LOCKED", "too many wrong codes: hand it over after an identity check")
            if not hmac.compare_digest(bytes(s["pickup_code_hash"]), _code_hash(s["tracking_no"], body.pickup_code)):
                # the wrong try is kept: the transaction ends normally and the refusal is raised after it
                await conn.execute("UPDATE ship.shipment SET pickup_code_tries = pickup_code_tries + 1 WHERE id = $1", s["id"])
                wrong = max(tries - s["pickup_code_tries"] - 1, 0)
            method = "OTP"
        if wrong is None:
            if body.id_check is not None:
                await _record_id(conn, ctx, s, body.id_check, pr)
            await _handed(conn, s, body, method, pr.user_id)
            await emit(conn, "parcel.delivered", "shipment", s["id"],
                       _notice(s, delivered_to=body.delivered_to.strip(), method=method, id_checked=body.id_check is not None),
                       company_id=pr.company_id)
    if wrong is not None:
        raise ApiError(422, "PICKUP_CODE_WRONG", "the code does not match", tries_left=wrong)
    _audit(request, "parcel.delivered", s, method + ("+ID" if body.id_check and method == "OTP" else ""))
    return {"tracking_no": s["tracking_no"], "status": "DELIVERED", "method": method, "id_checked": body.id_check is not None,
            "cod_collected": s["cod_amount"] or 0}


async def _record_id(conn, ctx, s, check: IdCheckIn, pr: Principal) -> None:
    """The document's number is kept encrypted; the record shows its kind, its last four digits, holder and issuer."""
    async with db.system_scope(conn, ctx):
        fc = await crypto.cipher(conn)
    sealed = fc.encrypt(check.doc_no.strip(), "ship.parcel_id_check.doc_no")
    await conn.execute(
        """INSERT INTO ship.parcel_id_check (shipment_id, company_id, doc_kind, doc_no_enc, enc_key_id, doc_last4, holder_name,
             issued_by, checked_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)""",
        s["id"], pr.company_id, check.doc_kind, sealed.ciphertext, sealed.key_id, crypto.last4(check.doc_no) or "-",
        check.holder_name.strip(), check.issued_by.strip() if check.issued_by else None, pr.user_id)


async def _handed(conn, s, body: DeliverIn, method: str, user_id: int) -> None:
    """The parcel leaves the counter: its proof, the cash on delivery collected, the milestone."""
    await conn.execute("UPDATE ship.shipment SET delivered_at = now(), delivered_by = $2, status = 'DELIVERED', updated_at = now() WHERE id = $1",
                       s["id"], user_id)
    await conn.execute("UPDATE ship.shipment_leg SET status = 'COMPLETED' WHERE id = $1", s["leg_id"])
    attempt = await conn.fetchval(
        """INSERT INTO ship.delivery_attempt (shipment_id, attempt_no, courier_user_id, result)
           VALUES ($1, (SELECT coalesce(max(attempt_no), 0) + 1 FROM ship.delivery_attempt WHERE shipment_id = $1), $2, 'DELIVERED')
           RETURNING id""", s["id"], user_id)
    await conn.execute("INSERT INTO ship.delivery_proof (shipment_id, attempt_id, method, delivered_to) VALUES ($1, $2, $3, $4)",
                       s["id"], attempt, method, body.delivered_to.strip()[:200])
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
        await conn.execute("UPDATE ship.shipment SET returned_at = now(), out_for_delivery_at = NULL, out_by = NULL, "
                           "status = 'RETURNED', updated_at = now() WHERE id = $1", s["id"])
        await _milestone(conn, s, "RETURNED", s["dest_station_id"], pr.user_id, s["exception_kind"])
    _audit(request, "parcel.returned", s, body.note)
    return {"tracking_no": s["tracking_no"], "status": "RETURNED"}


# ------------------------------------------------------------------ the sender
@customer.get("/{tracking_no}/journey")
async def journey(tracking_no: str, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        s = await conn.fetchrow(
            """SELECT s.id, s.tracking_no, s.status, s.recipient_name, s.handed_over_at, s.loaded_at, s.arrived_at, s.delivered_at,
                      s.returned_at, s.exception_kind, s.exception_note, s.delivery_mode, s.delivery_address, s.secure,
                      s.out_for_delivery_at, s.code_issued_at, sz.name AS station
                 FROM ship.shipment s LEFT JOIN net.station sz ON sz.id = s.dest_station_id
                WHERE s.tracking_no = $1 AND s.shipper_party_id = $2""", tracking_no.strip().upper(), pr.party_id)
        if s is None:
            raise not_found("parcel")
        async with db.system_scope(conn, ctx):        # the carrier's record of the check: its sender sees the kind, last digits, holder
            idc = await conn.fetchrow("SELECT doc_kind, doc_last4, holder_name FROM ship.parcel_id_check WHERE shipment_id = $1", s["id"])
        events = await conn.fetch(
            """SELECT e.milestone, e.reason_code, e.ts, st.name AS place FROM ship.tracking_event e
                 LEFT JOIN net.station st ON st.id = e.station_id WHERE e.shipment_id = $1 ORDER BY e.ts, e.id""", s["id"])
        hops = await conn.fetch(
            """SELECT h.seq, p.name AS location, h.received_at, h.dispatched_at, n.name AS sent_to
                 FROM ship.parcel_hop h JOIN ship.parcel_point p ON p.id = h.point_id LEFT JOIN ship.parcel_point n ON n.id = h.next_point_id
                WHERE h.shipment_id = $1 ORDER BY h.seq""", s["id"])
    out = row_dict(s)
    out.pop("id")
    out.pop("code_issued_at")
    out["id_check"] = {"kind": idc["doc_kind"], "last4": idc["doc_last4"], "holder": idc["holder_name"]} if idc else None
    valid = s["code_issued_at"] is not None and s["delivered_at"] is None and s["returned_at"] is None and s["exception_kind"] is None
    out["pickup_code"] = pickup_code(s["tracking_no"], s["code_issued_at"]) if valid else None
    out["events"] = [row_dict(e) for e in events]
    out["hops"] = [row_dict(h) for h in hops]
    return out

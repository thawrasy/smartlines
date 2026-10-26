"""Changes to a scheduled trip (owner's request N42, 1148).

    Carrier
    GET  /api/carrier/trip-changes/reasons              the platform's reasons, in both languages
    GET  /api/carrier/trips/{uid}/changes               what changed on the trip, and who is left to call
    POST /api/carrier/trips/{uid}/vehicle               another vehicle, before departure or on the way
    POST /api/carrier/trips/{uid}/reschedule            the departure moved; every stop moves with it
    GET  /api/carrier/trips/{uid}/rebook-options        the carrier's coming trips the passengers may be moved to
    POST /api/carrier/trips/{uid}/rebook                move bookings (named, or all) to one of them
    POST /api/carrier/trips/{uid}/changes/calls/{id}    a passenger the system could not reach was called

    Platform (policy.matrix)
    GET  /api/admin/trip-changes/policy                 the reasons and the thresholds
    PUT  /api/admin/trip-changes/policy
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_permission, require_portal
from ...errors import ApiError, forbidden, not_found
from ...util import row_dict
from . import changes

carrier = APIRouter(prefix="/api/carrier", tags=["trip changes"])
platform = APIRouter(prefix="/api/admin/trip-changes", tags=["trip changes"])
operator = require_portal("OPERATOR")
policy_staff = require_permission("policy.matrix")
REASON = r"^[A-Z_]{3,40}$"


def _need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden("missing permission: " + " | ".join(codes))


async def _trip(conn, pr: Principal, trip_uid: uuid.UUID, lock: bool = True):
    t = await conn.fetchrow(f"SELECT * FROM ops.trip WHERE uid = $1 AND company_id = $2{' FOR UPDATE' if lock else ''}",
                            trip_uid, pr.company_id)
    if t is None:
        raise not_found("trip")
    return t


class Why(BaseModel):
    reason: str = Field(pattern=REASON)
    note: Optional[str] = Field(default=None, max_length=500)


class VehicleIn(Why):
    vehicle_uid: uuid.UUID
    at_stop_seq: Optional[int] = Field(default=None, ge=0, le=60)      # on the way: the stop where it is changed
    driver_uid: Optional[uuid.UUID] = None                             # a new driver with it, optional


class RescheduleIn(Why):
    departure_at: datetime


class RebookIn(Why):
    to_trip_uid: uuid.UUID
    booking_refs: Optional[list[str]] = Field(default=None, max_length=200)   # none: every booking on the trip


class CallIn(BaseModel):
    outcome: Literal["INFORMED", "NO_ANSWER", "WRONG_NUMBER"]
    note: Optional[str] = Field(default=None, max_length=300)


@carrier.get("/trip-changes/reasons")
async def reasons(request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        p = await changes.policy(conn)
    return {"reasons": p.get("reasons", []), "free_cancel_shift_min": p.get("free_cancel_shift_min"),
            "max_shift_min": p.get("max_shift_min"), "rebook_window_hours": p.get("rebook_window_hours")}


@carrier.get("/trips/{trip_uid}/changes")
async def trip_changes(trip_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trip(conn, pr, trip_uid, lock=False)
        return {"trip_no": t["trip_no"], "trip_code": t["trip_code"], "status": t["status"], "shift_min": t["shift_min"],
                "changes": await changes.history(conn, t["id"])}


@carrier.post("/trips/{trip_uid}/vehicle")
async def change_vehicle(trip_uid: uuid.UUID, body: VehicleIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.reschedule", "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trip(conn, pr, trip_uid)
        vehicle_id = await conn.fetchval("SELECT id FROM fleet.vehicle WHERE uid = $1", body.vehicle_uid)
        if vehicle_id is None:
            raise not_found("vehicle")
        driver = None
        if body.driver_uid:
            driver = await conn.fetchval(
                """SELECT c.party_id FROM fleet.crew_profile c JOIN iam.party p ON p.id = c.party_id
                    WHERE p.uid = $1 AND c.company_id = $2""", body.driver_uid, pr.company_id)
            if driver is None:
                raise not_found("driver")
        out = await changes.swap_vehicle(conn, t, vehicle_id, body.reason, body.note, pr.user_id, body.at_stop_seq, driver)
    request.state.audit = {"action": "trip.vehicle_change", "object_type": "trip", "object_id": t["id"], "reason": body.reason}
    return out


@carrier.post("/trips/{trip_uid}/reschedule")
async def reschedule(trip_uid: uuid.UUID, body: RescheduleIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.reschedule")
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trip(conn, pr, trip_uid)
        out = await changes.reschedule(conn, t, body.departure_at, body.reason, body.note, pr.user_id)
    request.state.audit = {"action": "trip.reschedule", "object_type": "trip", "object_id": t["id"], "reason": body.reason}
    return out


@carrier.get("/trips/{trip_uid}/rebook-options")
async def rebook_options(trip_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trip(conn, pr, trip_uid, lock=False)
        trips = await changes.rebook_targets(conn, t)
        bookings = await conn.fetch(
            """SELECT b.booking_ref, b.status, count(k.id) AS tickets, b.contact_mobile IS NOT NULL OR b.booker_user_id IS NOT NULL AS reachable
                 FROM sales.booking b JOIN sales.ticket k ON k.booking_id = b.id AND k.status IN ('ISSUED','HOLD')
                WHERE b.trip_id = $1 AND b.status IN ('CONFIRMED','PENDING_PAYMENT') AND b.charter_request_id IS NULL
                GROUP BY b.id ORDER BY b.id""", t["id"])
    return {"trips": [{k: v for k, v in r.items() if k != "id"} | {"uid": str(r["uid"])} for r in trips],
            "bookings": [row_dict(b) for b in bookings]}


@carrier.post("/trips/{trip_uid}/rebook")
async def rebook(trip_uid: uuid.UUID, body: RebookIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.reschedule", "trip.cancel")
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trip(conn, pr, trip_uid)
        target = await conn.fetchval("SELECT id FROM ops.trip WHERE uid = $1 AND company_id = $2", body.to_trip_uid, pr.company_id)
        if target is None:
            raise not_found("trip")
        refs = [r.strip().upper() for r in body.booking_refs] if body.booking_refs else None
        out = await changes.rebook(conn, t, target, refs, body.reason, body.note, pr.user_id)
    request.state.audit = {"action": "trip.rebook", "object_type": "trip", "object_id": t["id"], "reason": body.reason}
    return out


@carrier.post("/trips/{trip_uid}/changes/calls/{contact_id}")
async def record_call(trip_uid: uuid.UUID, contact_id: int, body: CallIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.reschedule", "trip.cancel", "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trip(conn, pr, trip_uid, lock=False)
        await changes.record_call(conn, t["id"], contact_id, body.outcome, body.note, pr.user_id)
    return {"ok": True}


# ------------------------------------------------------------------ platform
class ReasonIn(BaseModel):
    code: str = Field(pattern=REASON)
    en: str = Field(min_length=2, max_length=80)
    ar: str = Field(min_length=2, max_length=80)


class PolicyIn(BaseModel):
    reasons: list[ReasonIn] = Field(min_length=1, max_length=40)
    free_cancel_shift_min: int = Field(ge=0, le=1440)
    max_shift_min: int = Field(ge=15, le=10080)
    rebook_window_hours: int = Field(ge=1, le=720)


@platform.get("/policy")
async def get_policy(request: Request, pr: Principal = Depends(policy_staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await changes.policy(conn)


@platform.put("/policy")
async def put_policy(body: PolicyIn, request: Request, pr: Principal = Depends(policy_staff)):
    codes = [r.code for r in body.reasons]
    if len(set(codes)) != len(codes) or "OTHER" not in codes:
        raise ApiError(422, "REASONS_INVALID", "each reason once, and OTHER kept for what the list does not name")
    async with db.transaction(context_for(request, pr)) as conn:
        await conn.execute("UPDATE sys.setting SET value = $1::jsonb, updated_by = $2, updated_at = now() WHERE key = 'trips.change_policy'",
                           json.dumps(body.model_dump()), pr.user_id)
    request.state.audit = {"action": "trip_changes.policy", "object_type": "setting", "object_id": None}
    return body.model_dump()

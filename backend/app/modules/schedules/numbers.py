"""Trip numbers from the carrier's range (owner's request N7, migration 1165).

Every carrier has by default the whole block of each trip type; the platform may narrow a carrier's range and widen it
again, and a carrier whose range fills asks for more. The carrier picks the number of a regular trip from its free
numbers; the system fills in the default.

    Carrier (the OPERATOR portal)
    GET  /api/carrier/numbers?trip_type=&direction=&from_date=&until_date=&route_uid=
                                                     the range, the default number and the free numbers, lowest first
    GET  /api/carrier/numbers/for-trip?route_uid=&day=
                                                     for a trip made by hand: the carrier's numbers on that route that day,
                                                     and the default extra number
    GET  /api/carrier/number-ranges                  the carrier's range in each block and its requests
    POST /api/carrier/number-ranges/requests         {block, note}: ask the platform for a wider range

    Platform (the PLATFORM portal; schedule.approve)
    GET  /api/admin/number-ranges                    the ranges set, with history, and the open requests
    PUT  /api/admin/number-ranges                    {company_uid, block, from_no, to_no, note}: no from/to gives the whole block back
    POST /api/admin/number-ranges/requests/{uid}/decline   {answer}
"""
import uuid
from datetime import date, timedelta
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_permission, require_portal
from ...errors import ApiError, not_found

carrier = APIRouter(prefix="/api/carrier", tags=["schedules"])
platform = APIRouter(prefix="/api/admin", tags=["schedules"])
operator = require_portal("OPERATOR")

BLOCKS = ("SCHEDULED", "INTL", "SHUTTLE", "CARGO", "EXTRA")
Block = Literal["SCHEDULED", "INTL", "SHUTTLE", "CARGO", "EXTRA"]
TripType = Literal["SCHEDULED", "SHUTTLE", "INTERNATIONAL", "CARGO", "EXTRA"]
BLOCK_OF = {"SCHEDULED": "SCHEDULED", "INTERNATIONAL": "INTL", "SHUTTLE": "SHUTTLE", "CARGO": "CARGO", "EXTRA": "EXTRA"}   # ops.number_block


async def _staff(pr: Principal = Depends(require_permission("schedule.approve"))) -> Principal:
    if pr.portal != "PLATFORM":
        raise ApiError(403, "FORBIDDEN", "wrong portal for this operation")
    return pr


def _range(r) -> dict:
    return {"from": r.lower, "to": r.upper - 1}


async def number_problem(conn: asyncpg.Connection, company: int, trip_type: str, direction: str, number: int) -> None:
    """Refuses a number outside the block, of the wrong parity or outside the carrier's range."""
    problem = await conn.fetchval("SELECT ops.carrier_number_problem($1, $2, $3, $4)", company, trip_type, direction, number)
    if problem:
        code, _, message = problem.partition(":")
        raise ApiError(422, code, message.strip())


@carrier.get("/numbers")
async def free_numbers(request: Request, trip_type: TripType = "SCHEDULED", direction: Literal["OUTBOUND", "INBOUND"] = "OUTBOUND",
                       from_date: Optional[date] = None, until_date: Optional[date] = None, route_uid: Optional[uuid.UUID] = None,
                       pr: Principal = Depends(operator)):
    start = from_date or date.today()
    if until_date is not None and until_date < start:
        raise ApiError(422, "INVALID_RANGE", "the end comes after the start")
    async with db.transaction(context_for(request, pr)) as conn:
        route = None
        if route_uid is not None:
            route = await conn.fetchval("SELECT id FROM net.route WHERE uid = $1 AND company_id = $2", route_uid, pr.company_id)
            if route is None:
                raise not_found("route")
        period = asyncpg.Range(start, (until_date + timedelta(days=1)) if until_date else None)
        block = BLOCK_OF[trip_type]
        rng = await conn.fetchval("SELECT ops.carrier_number_range($1, $2)", pr.company_id, block)
        suggested = await conn.fetchval("SELECT ops.suggest_schedule_number($1, $2, $3, $4, $5)", pr.company_id, trip_type, direction, period, route)
        free = [r["n"] for r in await conn.fetch("SELECT n FROM ops.free_schedule_numbers($1, $2, $3, $4, $5, 200) n",
                                                 pr.company_id, trip_type, direction, period, route)]
    return {"block": block, "range": _range(rng), "suggested": suggested, "free": free}


@carrier.get("/numbers/for-trip")
async def trip_numbers(route_uid: uuid.UUID, day: date, request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        route = await conn.fetchrow("SELECT id FROM net.route WHERE uid = $1 AND company_id = $2", route_uid, pr.company_id)
        if route is None:
            raise not_found("route")
        mine = await conn.fetch(
            """SELECT s.number, s.block, s.direction FROM net.service_number s
                WHERE s.company_id = $1 AND s.route_id = $2 AND s.valid @> $3::date ORDER BY s.number""", pr.company_id, route["id"], day)
        extra = await conn.fetchval("SELECT ops.default_trip_number($1, $2, $3)", pr.company_id, route["id"], day)
        rng = await conn.fetchval("SELECT ops.carrier_number_range($1, 'EXTRA')", pr.company_id)
    return {"service_numbers": [dict(r) for r in mine], "suggested_extra": extra, "extra_range": _range(rng)}


@carrier.get("/number-ranges")
async def my_ranges(request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        ranges = [{"block": b, **_range(await conn.fetchval("SELECT ops.carrier_number_range($1, $2)", pr.company_id, b))} for b in BLOCKS]
        asked = await conn.fetch(
            """SELECT uid, block, note, status, requested_at, answer, answered_at FROM net.number_range_request
                WHERE company_id = $1 ORDER BY requested_at DESC LIMIT 50""", pr.company_id)
    return {"ranges": ranges, "requests": [dict(r) for r in asked]}


class RangeAsk(BaseModel):
    block: Block
    note: str = Field(min_length=3, max_length=500)


@carrier.post("/number-ranges/requests", status_code=201)
async def ask_range(body: RangeAsk, request: Request, pr: Principal = Depends(operator)):
    if "trip.publish" not in pr.permissions:
        raise ApiError(403, "FORBIDDEN", "missing permission: trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        try:
            uid = await conn.fetchval(
                "INSERT INTO net.number_range_request (company_id, block, note, requested_by) VALUES ($1, $2, $3, $4) RETURNING uid",
                pr.company_id, body.block, body.note.strip(), pr.user_id)
        except asyncpg.UniqueViolationError as exc:
            raise ApiError(409, "NUMBER_RANGE_REQUEST_OPEN", "a request for this block is already waiting") from exc
    request.state.audit = {"action": "number_range.request", "object_type": "company", "object_id": pr.company_id, "reason": body.block}
    return {"uid": str(uid), "status": "OPEN"}


# ------------------------------------------------------------------ platform
@platform.get("/number-ranges")
async def ranges(request: Request, pr: Principal = Depends(_staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT p.uid AS company_uid, p.legal_name AS company, r.block, r.from_no, r.to_no, r.note, u.email AS set_by, r.set_at, r.ended_at
                 FROM net.number_range r JOIN iam.party p ON p.id = r.company_id LEFT JOIN iam.app_user u ON u.id = r.set_by
                ORDER BY r.ended_at IS NOT NULL, p.legal_name, r.block, r.set_at DESC LIMIT 500""")
        asked = await conn.fetch(
            """SELECT q.uid, p.uid AS company_uid, p.legal_name AS company, q.block, q.note, q.status, q.requested_at, q.answer
                 FROM net.number_range_request q JOIN iam.party p ON p.id = q.company_id
                ORDER BY q.status <> 'OPEN', q.requested_at DESC LIMIT 200""")
        blocks = {b: _range(await conn.fetchval("SELECT ops.block_range($1)", b)) for b in BLOCKS}
    return {"blocks": blocks, "ranges": [dict(r) for r in rows], "requests": [dict(r) for r in asked]}


class RangeIn(BaseModel):
    company_uid: uuid.UUID
    block: Block
    from_no: Optional[int] = Field(default=None, ge=1000, le=9999)
    to_no: Optional[int] = Field(default=None, ge=1000, le=9999)
    note: Optional[str] = Field(default=None, max_length=500)


@platform.put("/number-ranges")
async def set_range(body: RangeIn, request: Request, pr: Principal = Depends(_staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        company = await conn.fetchval(
            "SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1 AND c.company_type = 'CARRIER'", body.company_uid)
        if company is None:
            raise not_found("carrier")
        try:
            rng = await conn.fetchval("SELECT net.set_number_range($1, $2, $3, $4, $5)", company, body.block, body.from_no, body.to_no, body.note)
        except asyncpg.RaiseError as exc:
            code, _, message = str(exc).partition(":")
            raise ApiError(422, code, message.strip()) from exc
    request.state.audit = {"action": "number_range.set", "object_type": "company", "object_id": company,
                           "reason": f"{body.block} {body.from_no}-{body.to_no}"}
    return {"block": body.block, "range": _range(rng)}


class Decline(BaseModel):
    answer: str = Field(min_length=3, max_length=500)


@platform.post("/number-ranges/requests/{uid}/decline")
async def decline(uid: uuid.UUID, body: Decline, request: Request, pr: Principal = Depends(_staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        done = await conn.fetchval(
            """UPDATE net.number_range_request SET status = 'DECLINED', answer = $2, answered_by = $3, answered_at = now()
                WHERE uid = $1 AND status = 'OPEN' RETURNING id""", uid, body.answer.strip(), pr.user_id)
        if done is None:
            raise not_found("open request")
    request.state.audit = {"action": "number_range.decline", "object_type": "number_range_request", "object_id": done}
    return {"status": "DECLINED"}

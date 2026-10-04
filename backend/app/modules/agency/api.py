"""Agency portal API: /api/agency. Sell tickets for any approved carrier, follow bookings, statements, staff."""
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, EmailStr, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, not_found
from ...routers.bookings import qr_response
from ...security import password_problem
from ..sales import service as sales
from ..sales.models import AgencyBookingIn, HoldIn
from . import repository as repo
from . import service

router = APIRouter(prefix="/api/agency", tags=["agency"])
agency = require_portal("AGENCY")


@router.get("/dashboard")
async def dashboard(request: Request, pr: Principal = Depends(agency)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.dashboard(conn, pr)


@router.post("/holds", status_code=201)
async def create_hold(body: HoldIn, request: Request, pr: Principal = Depends(agency)):
    async with db.transaction(context_for(request, pr)) as conn:
        await service.ensure_can_sell(conn, pr)
        hold = await sales.create_hold(conn, pr.user_id, body)
    request.state.audit = {"action": "booking.hold", "object_type": "trip", "object_id": hold.pop("trip_id")}
    return hold


@router.delete("/holds/{hold_token}")
async def release_hold(hold_token: uuid.UUID, request: Request, pr: Principal = Depends(agency)):
    async with db.transaction(context_for(request, pr)) as conn:
        released = await sales.release_hold(conn, pr.user_id, hold_token)
    return {"ok": True, "released_seats": released}


@router.post("/bookings", status_code=201)
async def sell(body: AgencyBookingIn, request: Request, pr: Principal = Depends(agency)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await service.sell(conn, ctx, pr, body)
    if out.get("replayed"):
        return out
    request.state.audit = {"action": "agency.sell", "object_type": "booking", "object_id": out.pop("booking_id")}
    return out


@router.get("/bookings")
async def bookings(request: Request, q: Optional[str] = Query(default=None, max_length=20, pattern=r"^[0-9A-Za-z+]+$"),
                   pr: Principal = Depends(agency)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"bookings": await service.bookings(conn, pr, q)}


@router.get("/bookings/{ref}")
async def booking_detail(ref: str, request: Request, pr: Principal = Depends(agency)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await service.booking_detail(conn, ctx, pr, ref)


@router.post("/bookings/{ref}/cancel")
async def cancel(ref: str, request: Request, pr: Principal = Depends(agency)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        booking_id, out = await service.cancel(conn, ctx, pr, ref)
    request.state.audit = {"action": "agency.cancel", "object_type": "booking", "object_id": booking_id}
    return out


@router.get("/tickets/{ticket_uid}/qr")
async def ticket_qr(ticket_uid: uuid.UUID, request: Request, pr: Principal = Depends(agency)):
    async with db.transaction(context_for(request, pr)) as conn:
        status = await repo.ticket_status(conn, service.require_agency(pr), ticket_uid)
    return qr_response(ticket_uid, status)


@router.get("/tickets/{ticket_uid}/offline")
async def ticket_offline(ticket_uid: uuid.UUID, request: Request, pr: Principal = Depends(agency)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        if await repo.ticket_status(conn, service.require_agency(pr), ticket_uid) is None:
            raise not_found("ticket")
        return await sales.offline_credential(conn, ctx, ticket_uid)


@router.get("/statement")
async def statement(request: Request, month: Optional[str] = Query(default=None, pattern=r"^\d{4}-\d{2}$"),
                    pr: Principal = Depends(agency)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.statement(conn, pr, month)


@router.get("/staff")
async def staff(request: Request, pr: Principal = Depends(agency)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"staff": await service.staff(conn, pr)}


class StaffIn(BaseModel):
    full_name: str = Field(min_length=3, max_length=120)
    email: EmailStr
    mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")
    password: str = Field(min_length=1, max_length=200)
    role: Literal["SELLER", "ACCOUNTANT"] = "SELLER"


@router.post("/staff", status_code=201)
async def add_staff(body: StaffIn, request: Request, pr: Principal = Depends(agency)):
    problem = password_problem(body.password)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    async with db.transaction(context_for(request, pr)) as conn:
        party_id, uid = await service.add_staff(conn, pr, body.full_name, body.email, body.mobile, body.password, body.role)
    request.state.audit = {"action": "agency.staff_create", "object_type": "party", "object_id": party_id}
    return {"uid": uid}

"""Counter cash and payment options API.

  Counter   /api/carrier/counter/...       sell for cash, collect pay-later reservations, cancel, print, the day's cash
  Finance   /api/admin/payment-methods     open and close the ways of paying a booking (with a reason)
            /api/admin/cash/...            what each carrier owes for cash, credit limits, remittances (four eyes)
"""
import uuid
from datetime import date
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import forbidden
from ...routers.bookings import qr_response
from ..sales import options
from ..sales import service as sales
from ..sales.models import MOBILE, BookingIn, HoldIn
from . import service

router = APIRouter(tags=["cash"])
operator = require_portal("OPERATOR")
platform = require_portal("PLATFORM")


class CounterBookingIn(BookingIn):
    """A sale at the counter: the traveller may leave a mobile number for the confirmation text."""
    contact_mobile: Optional[str] = Field(default=None, pattern=MOBILE)


# ------------------------------------------------------------------ the counter
@router.get("/api/carrier/counter/dashboard")
async def dashboard(request: Request, pr: Principal = Depends(operator)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await service.dashboard(conn, ctx, pr)


@router.post("/api/carrier/counter/holds", status_code=201)
async def create_hold(body: HoldIn, request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        await service.ensure_trip(conn, pr, body.trip_uid)
        hold = await sales.create_hold(conn, pr.user_id, body)
    request.state.audit = {"action": "booking.hold", "object_type": "trip", "object_id": hold.pop("trip_id")}
    return hold


@router.delete("/api/carrier/counter/holds/{hold_token}")
async def release_hold(hold_token: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    service.counter_of(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        released = await sales.release_hold(conn, pr.user_id, hold_token)
    return {"ok": True, "released_seats": released}


@router.post("/api/carrier/counter/bookings/quote")
async def quote(body: CounterBookingIn, request: Request, pr: Principal = Depends(operator)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        await service.ensure_trip(conn, pr, body.trip_uid)
        return await sales.quote(conn, ctx, body, service.buyer_for(pr))


@router.post("/api/carrier/counter/bookings", status_code=201)
async def sell(body: CounterBookingIn, request: Request, pr: Principal = Depends(operator)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await service.sell(conn, ctx, pr, body)
    if out.get("replayed"):
        return out
    request.state.audit = {"action": "counter.sell", "object_type": "booking", "object_id": out.pop("booking_id")}
    return out


@router.get("/api/carrier/counter/bookings")
async def bookings(request: Request, q: Optional[str] = Query(default=None, max_length=20, pattern=r"^[0-9A-Za-z+]+$"),
                   status: Optional[Literal["PENDING_PAYMENT", "CONFIRMED", "CANCELLED", "COMPLETED", "EXPIRED"]] = None,
                   pr: Principal = Depends(operator)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return {"bookings": await service.bookings(conn, ctx, pr, q, status)}


@router.get("/api/carrier/counter/bookings/{ref}")
async def booking_detail(ref: str, request: Request, pr: Principal = Depends(operator)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await service.booking_detail(conn, ctx, pr, ref)


@router.post("/api/carrier/counter/bookings/{ref}/collect")
async def collect(ref: str, request: Request, pr: Principal = Depends(operator)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await service.collect(conn, ctx, pr, ref)
    request.state.audit = {"action": "counter.collect", "object_type": "booking", "object_id": out.pop("booking_id")}
    return out


@router.post("/api/carrier/counter/bookings/{ref}/cancel")
async def cancel(ref: str, request: Request, pr: Principal = Depends(operator)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        booking_id, out = await service.cancel(conn, ctx, pr, ref)
    request.state.audit = {"action": "counter.cancel", "object_type": "booking", "object_id": booking_id}
    return out


@router.get("/api/carrier/counter/tickets/{ticket_uid}/qr")
async def ticket_qr(ticket_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        status = await service.ticket_status(conn, ctx, pr, ticket_uid)
    return qr_response(ticket_uid, status)


@router.get("/api/carrier/counter/report")
async def day_report(request: Request, day: Optional[date] = None, pr: Principal = Depends(operator)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await service.day_report(conn, ctx, pr, day)


# ------------------------------------------------------------------ finance: the switches
@router.get("/api/admin/payment-methods")
async def methods(request: Request, pr: Principal = Depends(platform)):
    service.need(pr, "payment.methods", "payment.fee_policy", "ledger.reconcile")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await options.all_methods(conn)
        providers = await conn.fetch(
            """SELECT code, name, adapter, status FROM fin.payment_provider
                WHERE adapter IN ('HOSTED_CARD','INSTALLMENT','FINANCING') AND 'BOOKING' = ANY(purposes) ORDER BY sort_order""")
        kinds = await conn.fetch("SELECT code, name FROM ref.trip_type ORDER BY sort")
    out = []
    for m in rows:
        d = {k: m[k] for k in ("code", "enabled", "channels", "min_amount", "max_amount", "provider_adapter", "config", "sort_order",
                               "reason", "updated_at")}
        d["providers"] = [dict(p) for p in providers if p["adapter"] == m["provider_adapter"]]
        d["allowed_channels"] = sorted(service.ALLOWED_CHANNELS[m["code"]])
        d["settings"] = sorted(service.CONFIG_KEYS.get(m["code"], {}))
        out.append(d)
    return {"methods": out, "trip_types": [dict(k) for k in kinds], "can_change": "payment.methods" in pr.permissions}


class MethodIn(BaseModel):
    enabled: bool
    channels: list[Literal["WEB", "APP", "AGENCY", "COUNTER"]] = Field(min_length=1, max_length=4)
    min_amount: int = Field(ge=0, le=100_000_000_000)
    max_amount: Optional[int] = Field(default=None, gt=0, le=100_000_000_000)
    config: dict = Field(default_factory=dict)
    reason: str = Field(min_length=5, max_length=300)


@router.put("/api/admin/payment-methods/{code}")
async def update_method(code: Literal["WALLET", "AGENCY_BALANCE", "CASH_COUNTER", "PAY_LATER", "CARD", "INSTALLMENT", "FINANCING"],
                        body: MethodIn, request: Request, pr: Principal = Depends(platform)):
    service.need(pr, "payment.methods")
    async with db.transaction(context_for(request, pr)) as conn:
        m = await service.update_method(conn, pr.user_id, code, body)
    request.state.audit = {"action": "payment.method.update", "object_type": "payment_method", "object_id": None,
                           "reason": f"{code} {'open' if body.enabled else 'closed'}: {body.reason}"[:300]}
    return {"ok": True, "code": m["code"], "enabled": m["enabled"]}


# ------------------------------------------------------------------ finance: cash owed by carriers
def _finance(pr: Principal) -> None:
    if not pr.permissions.intersection({"cash.remittance", "cash.credit_limit", "ledger.reconcile"}):
        raise forbidden("missing permission: cash.remittance | cash.credit_limit | ledger.reconcile")


@router.get("/api/admin/cash/positions")
async def positions(request: Request, pr: Principal = Depends(platform)):
    _finance(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"positions": await service.positions(conn)}


class LimitIn(BaseModel):
    limit_amount: int = Field(ge=0, le=100_000_000_000)
    reason: str = Field(min_length=5, max_length=300)


@router.put("/api/admin/cash/limits/{company_id}")
async def set_limit(company_id: int, body: LimitIn, request: Request, pr: Principal = Depends(platform)):
    service.need(pr, "cash.credit_limit")
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.set_limit(conn, pr.user_id, company_id, body.limit_amount, body.reason)
    request.state.audit = {"action": "cash.limit.set", "object_type": "company", "object_id": company_id}
    return out


@router.get("/api/admin/cash/remittances")
async def remittances(request: Request, status: Optional[Literal["PENDING", "CONFIRMED", "REJECTED"]] = None,
                      pr: Principal = Depends(platform)):
    _finance(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await service.remittances(conn, status)
    for r in rows:
        r["mine"] = r.pop("recorded_by") == pr.user_id
        r.pop("confirmed_by", None)
    return {"remittances": rows}


class RemittanceIn(BaseModel):
    company_id: int
    amount: int = Field(gt=0, le=100_000_000_000)
    method: Literal["BANK_DEPOSIT", "CASH_OFFICE", "EXCHANGE_HOUSE"]
    ref: Optional[str] = Field(default=None, max_length=80)
    note: Optional[str] = Field(default=None, max_length=300)


@router.post("/api/admin/cash/remittances", status_code=201)
async def record_remittance(body: RemittanceIn, request: Request, pr: Principal = Depends(platform)):
    service.need(pr, "cash.remittance")
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.record_remittance(conn, pr.user_id, body.company_id, body.amount, body.method, body.ref, body.note)
    request.state.audit = {"action": "cash.remittance.record", "object_type": "cash_remittance", "object_id": out["id"]}
    return out


class DecisionIn(BaseModel):
    approve: bool
    note: Optional[str] = Field(default=None, max_length=300)


@router.post("/api/admin/cash/remittances/{rid}/decide")
async def decide(rid: int, body: DecisionIn, request: Request, pr: Principal = Depends(platform)):
    service.need(pr, "cash.remittance")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            out = await service.decide_remittance(conn, pr.user_id, rid, body.approve, body.note)
    request.state.audit = {"action": "cash.remittance.confirm" if body.approve else "cash.remittance.reject",
                           "object_type": "cash_remittance", "object_id": rid}
    return out

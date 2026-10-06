"""Passenger channel: seat holds, bookings paid from the wallet, tickets with rotating QR codes, and cancellation.

The use cases live in modules/sales/service.py and are shared with the agency channel.
"""
import json
import uuid

from fastapi import APIRouter, Depends, Request

from .. import db
from ..config import get_settings
from ..deps import Principal, context_for, require_portal
from ..errors import ApiError, not_found
from ..modules.sales import repository as sales_repo
from ..modules.sales import service as sales
from ..modules.sales.models import BookingIn, HoldIn, QuoteIn
from ..security import ticket_qr_token
from ..util import row_dict

router = APIRouter(prefix="/api", tags=["bookings"])
passenger = require_portal("PASSENGER")


def _buyer(pr: Principal) -> sales.Buyer:
    return sales.Buyer(party_id=pr.party_id, user_id=pr.user_id, channel="WEB")


@router.post("/bookings/quote")
async def quote(body: QuoteIn, request: Request, pr: Principal = Depends(passenger)):
    """The price of every traveller (adult, child, infant) and any family offer, before paying."""
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await sales.quote(conn, ctx, body, _buyer(pr))


@router.post("/holds", status_code=201)
async def create_hold(body: HoldIn, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        hold = await sales.create_hold(conn, pr.user_id, body)
    request.state.audit = {"action": "booking.hold", "object_type": "trip", "object_id": hold.pop("trip_id")}
    return hold


@router.delete("/holds/{hold_token}")
async def release_hold(hold_token: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        released = await sales.release_hold(conn, pr.user_id, hold_token)
    return {"ok": True, "released_seats": released}


@router.post("/bookings", status_code=201)
async def create_booking(body: BookingIn, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await sales.create_booking(conn, ctx, _buyer(pr), body)
    if out.get("replayed"):
        return out
    request.state.audit = {"action": "booking.create", "object_type": "booking", "object_id": out["booking_id"]}
    return {"booking_ref": out["booking_ref"], "total": out["total"], "currency": out["currency"]}


async def _booking_for(conn, pr: Principal, ref: str, family: bool = False):
    """The caller's own booking; with family=True also one the caller's family bought (as its head) or that the caller
    travels on (4.20). Changing a booking stays with whoever booked it."""
    b = await conn.fetchrow(
        """SELECT b.*, t.trip_no, t.uid AS trip_uid, t.departure_at, t.status AS trip_status,
                  cp.legal_name AS carrier_name
             FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id JOIN iam.party cp ON cp.id = b.company_id
            WHERE b.booking_ref = $1 AND (b.booker_party_id = $2
                  OR ($3 AND ((b.family_id IS NOT NULL AND iam.is_family_head(b.family_id)) OR sales.travels_on(b.id))))""",
        ref.upper(), pr.party_id, family)
    if b is None:
        raise not_found("booking")
    return b


@router.get("/bookings")
async def my_bookings(request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            f"""SELECT b.booking_ref, b.status, b.total_amount, b.currency, b.created_at, t.trip_no, t.uid AS trip_uid,
                       cp.legal_name AS carrier_name, {sales_repo.JOURNEY_SQL}
                  FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id JOIN iam.party cp ON cp.id = b.company_id
                 WHERE b.booker_party_id = $1 OR (b.family_id IS NOT NULL AND iam.is_family_head(b.family_id)) OR sales.travels_on(b.id)
                 ORDER BY b.created_at DESC LIMIT 50""", pr.party_id)
    out = []
    for r in recs:
        d = row_dict(r)
        d["journey"] = json.loads(d["journey"]) if isinstance(d["journey"], str) else d["journey"]
        out.append(d)
    return {"bookings": out}


@router.get("/bookings/{ref}")
async def booking_detail(ref: str, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        b = await _booking_for(conn, pr, ref, family=True)
        return await sales.booking_view(conn, ctx, b)


@router.get("/tickets/{ticket_uid}/qr")
async def ticket_qr(ticket_uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        status = await conn.fetchval(
            """SELECT k.status FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                WHERE k.uid = $1 AND b.booker_party_id = $2""", ticket_uid, pr.party_id)
    return qr_response(ticket_uid, status)


def qr_response(ticket_uid: uuid.UUID, status) -> dict:
    if status is None:
        raise not_found("ticket")
    if status not in ("ISSUED", "BOARDED"):
        raise ApiError(409, "TICKET_NOT_VALID", "ticket is not valid for boarding")
    token, valid_until = ticket_qr_token(str(ticket_uid))
    return {"token": token, "valid_until": valid_until, "window": get_settings().qr_window_seconds}


@router.get("/tickets/{ticket_uid}/offline")
async def ticket_offline(ticket_uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    """Signed credential the app stores to show the ticket with no connection (the driver app verifies it offline)."""
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        owned = await conn.fetchval(
            """SELECT 1 FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                WHERE k.uid = $1 AND b.booker_party_id = $2""", ticket_uid, pr.party_id)
        if not owned:
            raise not_found("ticket")
        return await sales.offline_credential(conn, ctx, ticket_uid)


@router.post("/bookings/{ref}/cancel")
async def cancel_booking(ref: str, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        b = await _booking_for(conn, pr, ref)
        out = await sales.cancel_booking(conn, ctx, b, _buyer(pr))
    request.state.audit = {"action": "booking.cancel", "object_type": "booking", "object_id": b["id"]}
    out.pop("commission_kept", None)
    return out

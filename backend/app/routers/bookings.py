"""Passenger channel: seat holds, bookings paid from the wallet or reserved and paid later, tickets with rotating QR
codes, cancellation, and a booking changed to another trip of its carrier (1130).

The use cases live in modules/sales/service.py and are shared with the agency and counter channels. Which ways of
paying are offered is decided by platform administration (fin.payment_method, 1056).
"""
import json
import uuid
from typing import Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from .. import db
from ..config import get_settings
from ..deps import Principal, context_for, public_base, require_portal, sales_channel
from ..errors import ApiError, not_found
from ..modules.payments import service as payments
from ..modules.sales import connections, options
from ..modules.sales import repository as sales_repo
from ..modules.sales import service as sales
from ..modules.sales.models import BookingIn, HoldIn, QuoteIn
from ..security import ticket_qr_token
from ..util import row_dict

router = APIRouter(prefix="/api", tags=["bookings"])
passenger = require_portal("PASSENGER")


def _buyer(pr: Principal, request: Request) -> sales.Buyer:
    return sales.Buyer(party_id=pr.party_id, user_id=pr.user_id, channel=sales_channel(request))


@router.post("/bookings/quote")
async def quote(body: QuoteIn, request: Request, pr: Principal = Depends(passenger)):
    """The price of every traveller (adult, child, infant) and any family offer, before paying."""
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await sales.quote(conn, ctx, body, _buyer(pr, request))


@router.post("/holds", status_code=201)
async def create_hold(body: HoldIn, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        hold = await sales.create_hold(conn, pr.user_id, body, limit=await sales.seat_limit(conn, pr.party_id))
    request.state.audit = {"action": "booking.hold", "object_type": "trip", "object_id": hold.pop("trip_id")}
    return hold


@router.get("/bookings/limits")
async def booking_limits(request: Request, pr: Principal = Depends(passenger)):
    """The seats the passenger books at once (1122): the platform's number, more when they head a larger family."""
    async with db.transaction(context_for(request, pr)) as conn:
        mine = await sales.seat_limit(conn, pr.party_id)
        limits = json.loads(await conn.fetchval("SELECT sales.seat_limits()::text"))
    return {"max_seats": mine, "default_seats": limits["max_seats"], "family": mine > limits["max_seats"]}


@router.delete("/holds/{hold_token}")
async def release_hold(hold_token: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        released = await sales.release_hold(conn, pr.user_id, hold_token)
    return {"ok": True, "released_seats": released}


@router.post("/bookings", status_code=201)
async def create_booking(body: BookingIn, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await sales.create_booking(conn, ctx, _buyer(pr, request), body, option=body.pay_with)
    if out.get("replayed"):
        return out
    request.state.audit = {"action": "booking.reserve" if out["status"] == "PENDING_PAYMENT" else "booking.create",
                           "object_type": "booking", "object_id": out["booking_id"]}
    return {k: out[k] for k in ("booking_ref", "total", "currency", "status", "pay_option")} | (
        {"pay_by": out["pay_by"]} if out.get("pay_by") else {})


@router.get("/payments/booking-options")
async def booking_options(request: Request, trip_uid: Optional[uuid.UUID] = None, pr: Principal = Depends(passenger)):
    """The ways of paying a booking that platform administration has opened, with the providers behind them; with a
    trip, only the gateway options its carrier takes (1145)."""
    async with db.transaction(context_for(request, pr)) as conn:
        carrier = await conn.fetchval("SELECT company_id FROM ops.trip WHERE uid = $1", trip_uid) if trip_uid else None
        if trip_uid and carrier is None:
            raise not_found("trip")
        return {"options": await options.booking_options(conn, options.channel_of(sales_channel(request)), carrier)}


class BookingPaymentIn(BaseModel):
    provider: str = Field(pattern=r"^[A-Z_]{3,20}$")
    idempotency_key: str = Field(min_length=8, max_length=80)


@router.post("/bookings/{ref}/payments", status_code=201)
async def pay_booking(ref: str, body: BookingPaymentIn, request: Request, pr: Principal = Depends(passenger)):
    """Pays a reservation through the provider of its option: the passenger is sent to the provider's page."""
    ctx = context_for(request, pr)
    base = public_base(request)
    out = await payments.start_booking_payment(ctx, pr.party_id, pr.user_id, ref, body.provider, body.idempotency_key,
                                               f"{base}/booking/{ref.upper()}?payment={{uid}}",
                                               channel=options.channel_of(sales_channel(request)))
    request.state.audit = {"action": "payment.start", "object_type": "payment", "object_id": None}
    return out


async def _booking_for(conn, pr: Principal, ref: str, family: bool = False):
    """The caller's own booking; with family=True also one the caller's family bought (as its head) or that the caller
    travels on (4.20). Changing a booking stays with whoever booked it."""
    b = await conn.fetchrow(
        """SELECT b.*, t.trip_no, t.trip_code, t.uid AS trip_uid, t.departure_at, t.status AS trip_status,
                  cp.legal_name AS carrier_name, cp.uid AS carrier_uid, iam.logo_version(cp.id) AS carrier_logo
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
            f"""SELECT b.booking_ref, b.status, b.total_amount, b.currency, b.created_at, t.trip_no, t.trip_code, t.uid AS trip_uid,
                       cp.legal_name AS carrier_name, cp.uid AS carrier_uid, iam.logo_version(cp.id) AS carrier_logo,
                       {sales_repo.JOURNEY_SQL}
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


class SosIn(BaseModel):
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)


@router.post("/tickets/{ticket_uid}/sos", status_code=201)
async def ticket_sos(ticket_uid: uuid.UUID, body: SosIn, request: Request, pr: Principal = Depends(passenger)):
    """A passenger on the trip presses SOS from their ticket: the carrier and the platform are told at once (1101).
    The database checks again that the caller travels on the trip and that the trip is under way."""
    async with db.transaction(context_for(request, pr)) as conn:
        trip_id = await conn.fetchval(
            """SELECT k.trip_id FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                WHERE k.uid = $1 AND (b.booker_party_id = $2 OR b.booker_user_id = $3)""", ticket_uid, pr.party_id, pr.user_id)
        if trip_id is None:
            raise not_found("ticket")
        out = json.loads(await conn.fetchval("SELECT sec.raise_sos($1, $2, $3)::text", trip_id, body.lat, body.lng))
    request.state.audit = {"action": "sos.raise", "object_type": "sos_event", "object_id": out["sos_id"]}
    return out


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
        if b["status"] == "PENDING_PAYMENT":
            out = await sales.cancel_reserved(conn, ctx, b, pr.user_id)
        else:
            if b["pay_method"] == "CASH" and not (await options.method(conn, "WALLET"))["enabled"]:
                # cash goes back in cash: without the wallet there is nowhere online to return it to
                raise ApiError(409, "CANCEL_AT_COUNTER", "cancel at the carrier's counter to get your cash back")
            out = await sales.cancel_booking(conn, ctx, b, _buyer(pr, request))
    request.state.audit = {"action": "booking.cancel", "object_type": "booking", "object_id": b["id"]}
    out.pop("commission_kept", None)
    return out


@router.get("/bookings/{ref}/change-options")
async def change_options(ref: str, request: Request, pr: Principal = Depends(passenger)):
    """Whether the booking may be changed now and on what basis (its fare's rules, or its carrier's policy after a missed
    connection), with the carrier's trips between the same cities in the next three days."""
    async with db.transaction(context_for(request, pr)) as conn:
        return await connections.options(conn, await _booking_for(conn, pr, ref))


@router.post("/bookings/{ref}/change")
async def change_booking(ref: str, body: connections.ChangeIn, request: Request, pr: Principal = Depends(passenger)):
    """Changes the booking to another trip of its carrier: the old one cancelled with its value back less the change fee,
    the new one paid from the wallet, in one transaction."""
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        b = await _booking_for(conn, pr, ref)
        out = await connections.change(conn, ctx, b, _buyer(pr, request), body, await sales.seat_limit(conn, pr.party_id))
    if not out.get("replayed"):
        request.state.audit = {"action": "booking.change", "object_type": "booking", "object_id": out.pop("booking_id"),
                               "reason": f"{b['booking_ref']} -> {out['booking_ref']}: {out['basis']}, fee {out['fee']}"}
    return out

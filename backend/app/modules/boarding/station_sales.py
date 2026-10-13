"""Tickets sold at a station's counter under the carrier's BOOKING right (migration 1110; owner's decision: first release).

    POST   /api/station/holds                       hold seats on a trip boarding at the station, for a carrier that gave the right
    DELETE /api/station/holds/{hold_token}          release them
    POST   /api/station/bookings/quote              the price before taking the cash
    POST   /api/station/bookings                    sell for cash: the tickets are issued at once, the cash is owed by the company
    GET    /api/station/bookings?station_uid=&day=  the counter's sales of a day (the station's time zone) and their total
    GET    /api/station/bookings/{ref}              a booking it sold, with its tickets (to print them)
    POST   /api/station/bookings/{ref}/cancel       cancel at the counter: a cash sale is refunded in cash from the drawer
    GET    /api/station/tickets/{ticket_uid}/qr     a ticket's rotating code, shown on the counter's screen
    GET    /api/station/tickets/{ticket_uid}/offline  the ticket's signed code (T2) that stays the same, to print: from the
                                                    hours before departure the platform sets (TICKET_NOT_YET before)
    GET    /api/station/cash                        what the company owes for cash sales, its limit and what is left
    GET    /api/station/tickets/{ticket_uid}/photo?station_uid=   the passenger's photo at check-in: refused until the
                                                    platform turns it on under a legal approval (build step 5, 1111)

The booking is the carrier's, like a sale at its own counter (1056); the operating company is its booker and owes the
cash on its own cash wallet, within its limit, remitted to the platform. Everything is refused unless the platform has
switched boarding stations and the station on, and the carrier has given the company the BOOKING right at the station.
"""
from __future__ import annotations

import uuid
from datetime import date, datetime, time, timedelta
from typing import Optional
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Query, Request
from pydantic import Field

from ... import db, markets
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden, not_found
from ...ledger import cash_wallet
from ...routers.bookings import qr_response
from ...util import rows
from ..cash import service as cash
from ..sales import service as sales
from ..sales.models import MOBILE, BookingIn, HoldIn

router = APIRouter(prefix="/api/station", tags=["boarding"])
staff = require_portal("STATION")


def _operator(pr: Principal) -> int:
    if pr.company_id is None or not (pr.is_owner or "station.counter" in pr.permissions):
        raise forbidden("missing permission: station.counter")
    return pr.company_id


async def _station(conn, station_uid: uuid.UUID) -> int:
    sid = await conn.fetchval("SELECT id FROM net.station WHERE uid = $1", station_uid)
    if sid is None:
        raise not_found("station")
    return sid


async def _may_sell(conn, trip_uid: uuid.UUID, from_seq: int, station_id: int) -> int:
    trip_id = await conn.fetchval("SELECT id FROM ops.trip WHERE uid = $1", trip_uid)
    if trip_id is None or not await conn.fetchval("SELECT brd.station_may_sell($1, $2, $3)", trip_id, from_seq, station_id):
        raise ApiError(409, "NOT_GRANTED", "this counter may not sell this trip here: the station is off, the passenger does not "
                                           "board here, or the carrier has not given the company the BOOKING right")
    return trip_id


def _buyer(pr: Principal, station_id: int, contact_mobile: Optional[str] = None) -> sales.Buyer:
    return sales.Buyer(party_id=pr.company_id, user_id=pr.user_id, channel="STATION", cash_company_id=pr.company_id,
                       contact_mobile=contact_mobile, station_id=station_id)


class StationHoldIn(HoldIn):
    station_uid: uuid.UUID


class StationBookingIn(BookingIn):
    station_uid: uuid.UUID
    counter_code: Optional[str] = Field(default=None, pattern=r"^C[0-9]{3}$")
    contact_mobile: Optional[str] = Field(default=None, pattern=MOBILE)


@router.post("/holds", status_code=201)
async def create_hold(body: StationHoldIn, request: Request, pr: Principal = Depends(staff)):
    _operator(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _may_sell(conn, body.trip_uid, body.from_seq, await _station(conn, body.station_uid))
        hold = await sales.create_hold(conn, pr.user_id, HoldIn(**body.model_dump(exclude={"station_uid"})))
    request.state.audit = {"action": "booking.hold", "object_type": "trip", "object_id": hold.pop("trip_id")}
    return hold


@router.delete("/holds/{hold_token}")
async def release_hold(hold_token: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    _operator(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        released = await sales.release_hold(conn, pr.user_id, hold_token)
    return {"ok": True, "released_seats": released}


def _booking_in(body: StationBookingIn) -> BookingIn:
    return BookingIn(**body.model_dump(exclude={"station_uid", "counter_code", "contact_mobile"}))


@router.post("/bookings/quote")
async def quote(body: StationBookingIn, request: Request, pr: Principal = Depends(staff)):
    _operator(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        station_id = await _station(conn, body.station_uid)
        await _may_sell(conn, body.trip_uid, body.from_seq, station_id)
        return await sales.quote(conn, ctx, _booking_in(body), _buyer(pr, station_id))


@router.post("/bookings", status_code=201)
async def sell(body: StationBookingIn, request: Request, pr: Principal = Depends(staff)):
    """Sells for cash at the counter: the tickets are issued at once; the company owes the cash, within its limit."""
    company = _operator(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        station_id = await _station(conn, body.station_uid)
        await _may_sell(conn, body.trip_uid, body.from_seq, station_id)
        gate_id = None
        if body.counter_code:
            gate_id = await conn.fetchval(
                """SELECT id FROM net.station_gate WHERE station_id = $1 AND code = $2 AND gate_type = 'COUNTER'
                     AND operator_company_id = $3 AND status = 'ACTIVE'""", station_id, body.counter_code, company)
            if gate_id is None:
                raise ApiError(409, "COUNTER_NOT_YOURS", "this counter is not the company's at this station")
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('cash-sales'), $1::int)", company)
        currency = (await markets.of_party(conn, company)).currency
        async with db.system_scope(conn, ctx):
            await cash_wallet(conn, company, currency)

        async def within_limit(conn, total: int) -> None:
            p = await cash.position(conn, company)
            if p["owed"] + total > p["limit"]:
                raise ApiError(409, "CASH_LIMIT_REACHED", "cash sales are stopped until the company remits what it owes",
                               owed=p["owed"], limit=p["limit"], remaining=p["remaining"])

        out = await sales.create_booking(conn, ctx, _buyer(pr, station_id, body.contact_mobile), _booking_in(body),
                                         before_payment=within_limit, option="CASH_COUNTER")
        if out.get("replayed"):
            return out
        b = await conn.fetchrow("SELECT company_id, total_amount, currency FROM sales.booking WHERE id = $1", out["booking_id"])
        await conn.execute(
            """INSERT INTO brd.station_sale (booking_id, station_id, counter_gate_id, operator_company_id, carrier_company_id, sold_by,
                                             total, currency) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)""",
            out["booking_id"], station_id, gate_id, company, b["company_id"], pr.user_id, b["total_amount"], b["currency"])
    request.state.audit = {"action": "station.sell", "object_type": "booking", "object_id": out.pop("booking_id"),
                           "reason": f"station sale at {body.counter_code or 'counter'}"}
    return out


@router.get("/bookings")
async def day_sales(station_uid: uuid.UUID, request: Request, day: Optional[date] = None, pr: Principal = Depends(staff)):
    company = _operator(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        station_id = await _station(conn, station_uid)
        zone = ZoneInfo(await markets.station_zone(conn, station_id))
        day = day or datetime.now(zone).date()
        start = datetime.combine(day, time.min, zone)
        rs = await conn.fetch(
            """SELECT b.booking_ref, b.status, b.total_amount, b.currency, b.pay_method, s.created_at, t.trip_no, cp.legal_name AS carrier,
                      g.code AS counter, (SELECT count(*) FROM sales.ticket k WHERE k.booking_id = b.id) AS tickets
                 FROM brd.station_sale s JOIN sales.booking b ON b.id = s.booking_id JOIN ops.trip t ON t.id = b.trip_id
                 JOIN iam.party cp ON cp.id = s.carrier_company_id LEFT JOIN net.station_gate g ON g.id = s.counter_gate_id
                WHERE s.operator_company_id = $1 AND s.station_id = $2 AND s.created_at >= $3 AND s.created_at < $4
                ORDER BY s.created_at DESC""", company, station_id, start, start + timedelta(days=1))
    sold = [r for r in rs if r["status"] in ("CONFIRMED", "COMPLETED")]
    return {"day": day.isoformat(), "bookings": rows(rs), "count": len(sold), "total": sum(r["total_amount"] for r in sold),
            "currency": rs[0]["currency"] if rs else None}


async def _sold(conn, ctx, company: int, ref: str):
    async with db.system_scope(conn, ctx):
        b = await conn.fetchrow(
            """SELECT b.*, t.trip_no, t.uid AS trip_uid, t.departure_at, t.status AS trip_status, cp.legal_name AS carrier_name
                 FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id JOIN iam.party cp ON cp.id = b.company_id
                 JOIN brd.station_sale s ON s.booking_id = b.id
                WHERE b.booking_ref = $1 AND s.operator_company_id = $2""", ref.upper(), company)
    if b is None:
        raise not_found("booking")
    return b


@router.get("/bookings/{ref}")
async def booking_detail(ref: str, request: Request, pr: Principal = Depends(staff)):
    company = _operator(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        b = await _sold(conn, ctx, company, ref)
        out = await sales.booking_view(conn, ctx, b)
    out["booking"]["refundable_here"] = b["status"] == "CONFIRMED" and b["pay_method"] == "CASH"
    return out


@router.post("/bookings/{ref}/cancel")
async def cancel(ref: str, request: Request, pr: Principal = Depends(staff)):
    """Cancels a booking the company sold: the refund the fare allows is paid back in cash from the counter's drawer."""
    company = _operator(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        b = await _sold(conn, ctx, company, ref)
        if b["pay_method"] != "CASH":
            raise ApiError(409, "CANCEL_ONLINE", "this booking was not paid in cash at the counter")
        station_id = await conn.fetchval("SELECT station_id FROM brd.station_sale WHERE booking_id = $1", b["id"])
        out = await sales.cancel_booking(conn, ctx, b, _buyer(pr, station_id), reason="COUNTER")
    out.pop("commission_kept", None)
    request.state.audit = {"action": "station.cancel", "object_type": "booking", "object_id": b["id"]}
    return out


async def _sold_ticket(conn, ctx: db.Context, company: int, ticket_uid: uuid.UUID) -> str:
    """The status of a ticket the station's operating company sold; any other ticket is not found."""
    async with db.system_scope(conn, ctx):
        status = await conn.fetchval(
            """SELECT k.status FROM sales.ticket k JOIN brd.station_sale s ON s.booking_id = k.booking_id
                WHERE k.uid = $1 AND s.operator_company_id = $2""", ticket_uid, company)
    if status is None:
        raise not_found("ticket")
    return status


@router.get("/tickets/{ticket_uid}/qr")
async def ticket_qr(ticket_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    company = _operator(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        status = await _sold_ticket(conn, ctx, company, ticket_uid)
    return qr_response(ticket_uid, status)


@router.get("/tickets/{ticket_uid}/offline")
async def ticket_offline(ticket_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    """The code printed on a paper ticket: the rotating code changes every window and cannot be printed, so paper
    carries the signed credential, issued only from the hours before departure the platform sets (design review of
    the station screens, October 2026)."""
    company = _operator(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        await _sold_ticket(conn, ctx, company, ticket_uid)
        return await sales.offline_credential(conn, ctx, ticket_uid)


@router.get("/tickets/{ticket_uid}/photo")
async def ticket_photo(ticket_uid: uuid.UUID, station_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    """The passenger's photo for the counter check, only once a legal approval allows it (1111). Audited."""
    from fastapi import Response

    from ..photo import service as photo
    _operator(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        party_id, data, mime = await photo.read_for_counter(conn, ctx, ticket_uid, await _station(conn, station_uid))
    request.state.audit = {"action": "photo.view", "object_type": "party", "object_id": party_id, "reason": "station counter check-in"}
    return Response(content=data, media_type=mime)


@router.get("/cash")
async def cash_position(request: Request, pr: Principal = Depends(staff)):
    company = _operator(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await cash.position(conn, company)


@router.get("/sales/summary")
async def summary(request: Request, days: int = Query(default=7, ge=1, le=62), pr: Principal = Depends(staff)):
    """The company's station sales per day and station, for its own reconciliation."""
    company = _operator(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rs = await conn.fetch(
            """SELECT st.code AS station, (s.created_at AT TIME ZONE ref.station_tz(s.station_id))::date AS day, count(*) AS bookings,
                      sum(s.total) FILTER (WHERE b.status IN ('CONFIRMED', 'COMPLETED'))::bigint AS total, s.currency
                 FROM brd.station_sale s JOIN sales.booking b ON b.id = s.booking_id JOIN net.station st ON st.id = s.station_id
                WHERE s.operator_company_id = $1 AND s.created_at > now() - make_interval(days => $2)
                GROUP BY 1, 2, 5 ORDER BY 2 DESC, 1""", company, days)
    return {"days": rows(rs)}

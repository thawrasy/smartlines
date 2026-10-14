"""Journeys booked together (owner's request, October 2026; migration 1121).

    Passenger
    POST /api/journeys                      {kind, legs[{trip_uid, from_seq, to_seq}], passengers[], pay_with, idempotency_key}
    GET  /api/journeys/{journey_uid}        the journey's bookings, leg by leg
    Agency (booking.on_behalf): a tourism group of up to agency.group.max_passengers on every leg
    GET  /api/agency/journeys/options       how many travellers a group may have
    POST /api/agency/journeys               the same, with contact_mobile; paid from the agency's balance
    GET  /api/agency/journeys/{journey_uid}

A passenger books the platform's seat limit at once (four unless it decides otherwise, more for a family head; 1122),
GROUP_THROUGH_AGENCY beyond; an agency's group is split into bookings of that many seats on each leg (GROUP_TOO_LARGE
beyond its setting). Every leg is booked through the channel's own sale, so its
price, rules, limits and payment are those of a single booking; the journey is one transaction.
"""
import uuid

from fastapi import APIRouter, Depends, Request

from ... import db
from ...deps import Principal, context_for, require_portal, sales_channel
from ...errors import ApiError, not_found
from ..agency import service as agency_service
from . import journeys
from . import service as sales
from .models import AgencyBookingIn, BookingIn

passenger = APIRouter(prefix="/api/journeys", tags=["bookings"])
agency = APIRouter(prefix="/api/agency/journeys", tags=["agency"])


async def _group_limit(conn) -> int:
    return await conn.fetchval("SELECT sales.setting_int('agency.group.max_passengers', 50)")


def _answer(out: dict) -> dict:
    return out | {"bookings": [{k: v for k, v in b.items() if k != "booking_id"} for b in out["bookings"]]}


async def _replayed(conn, party_id: int, journey_uid: uuid.UUID) -> dict:
    """The journey sent again: its bookings as they were made."""
    rows = await conn.fetch(
        """SELECT journey_kind, journey_leg AS leg, booking_ref, total_amount AS total, currency, status,
                  CASE WHEN status = 'PENDING_PAYMENT' THEN hold_expires_at END AS pay_by FROM sales.booking
            WHERE booker_party_id = $1 AND journey_uid = $2 ORDER BY journey_leg, id""", party_id, journey_uid)
    totals: dict[str, int] = {}
    for r in rows:
        totals[r["currency"]] = totals.get(r["currency"], 0) + r["total"]
    return {"journey_uid": journey_uid, "kind": rows[0]["journey_kind"], "replayed": True,
            "bookings": [{k: r[k] for k in ("leg", "booking_ref", "total", "currency", "status", "pay_by")} for r in rows],
            "totals": [{"currency": c, "total": t} for c, t in totals.items()],
            "status": "CONFIRMED" if all(r["status"] == "CONFIRMED" for r in rows) else "PENDING_PAYMENT"}


# ------------------------------------------------------------------ passenger
@passenger.post("", status_code=201)
async def book_journey(body: journeys.JourneyIn, request: Request, pr: Principal = Depends(require_portal("PASSENGER"))):
    ctx = context_for(request, pr)
    buyer = sales.Buyer(party_id=pr.party_id, user_id=pr.user_id, channel=sales_channel(request))

    async with db.transaction(ctx) as conn:
        limit = await sales.seat_limit(conn, pr.party_id)
        if body.seated > limit:
            raise ApiError(422, "GROUP_THROUGH_AGENCY", f"a passenger books at most {limit} seats at once; a group books through an agency",
                           max_seats=limit)

        async def sell(b: BookingIn) -> dict:
            return await sales.create_booking(conn, ctx, buyer, b, option=b.pay_with)
        out = await journeys.book(conn, pr.party_id, pr.user_id, body, limit, sell)
        if out.get("replayed"):
            return await _replayed(conn, pr.party_id, out["journey_uid"])
    request.state.audit = {"action": "booking.journey", "object_type": "booking", "object_id": out["bookings"][0]["booking_id"],
                           "reason": f"{body.kind}: {len(body.legs)} trip(s), {len(out['bookings'])} booking(s)"}
    return _answer(out)


@passenger.get("/{journey_uid}")
async def journey(journey_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PASSENGER"))):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await journeys.view(conn, pr.party_id, journey_uid)
    if out is None:
        raise not_found("journey")
    return out


# ------------------------------------------------------------------ agency
@agency.get("/options")
async def agency_options(request: Request, pr: Principal = Depends(require_portal("AGENCY"))):
    agency_service.require_agency(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"max_passengers": await _group_limit(conn), "seats_per_booking": await sales.seat_limit(conn), "max_legs": journeys.MAX_LEGS}


@agency.post("", status_code=201)
async def agency_journey(body: journeys.AgencyJourneyIn, request: Request, pr: Principal = Depends(require_portal("AGENCY"))):
    agency_id = agency_service.require_agency(pr)
    agency_service.need(pr, "booking.on_behalf")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        limit = await _group_limit(conn)
        if body.seated > limit:
            raise ApiError(422, "GROUP_TOO_LARGE", f"a group has at most {limit} travellers", max_passengers=limit)

        async def sell(b: BookingIn) -> dict:
            return await agency_service.sell(conn, ctx, pr, AgencyBookingIn(**b.model_dump(), contact_mobile=body.contact_mobile))
        out = await journeys.book(conn, agency_id, pr.user_id, body, await sales.seat_limit(conn), sell)
        if out.get("replayed"):
            return await _replayed(conn, agency_id, out["journey_uid"])
    request.state.audit = {"action": "agency.journey", "object_type": "booking", "object_id": out["bookings"][0]["booking_id"],
                           "reason": f"{body.kind}: {len(body.legs)} trip(s), {len(body.passengers)} traveller(s)"}
    return _answer(out)


@agency.get("/{journey_uid}")
async def agency_journey_view(journey_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("AGENCY"))):
    agency_id = agency_service.require_agency(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await journeys.view(conn, agency_id, journey_uid)
    if out is None:
        raise not_found("journey")
    return out

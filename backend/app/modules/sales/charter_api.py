"""Charter: buses, minibuses and whole trips hired from carriers (owner's request, October 2026; migration 1123).

    Carrier (charter.manage)
    GET   /api/carrier/charter/offers                    the offers the carrier publishes
    POST  /api/carrier/charter/offers                    a vehicle apart from the trips, or its trips whole or in blocks
    PATCH /api/carrier/charter/offers/{uid}              price, terms, pause or archive
    GET   /api/carrier/charter/requests                  the requests it received
    POST  /api/carrier/charter/requests/{uid}/quote      a price valid for some hours (and the vehicle, when known)
    POST  /api/carrier/charter/requests/{uid}/decline
    POST  /api/carrier/charter/requests/{uid}/vehicle    the vehicle of a vehicle hire
    POST  /api/carrier/charter/requests/{uid}/complete   the service is done: the carrier is paid
    POST  /api/carrier/charter/requests/{uid}/cancel     a confirmed charter cancelled: refunded in full
    GET   /api/carrier/charter/requests/{uid}/travellers the travellers named on a trip charter's seats (1126)
    Tourism company (booking.on_behalf), and a traveller by special request
    GET   /api/agency/charter/offers                     GET /api/charter/offers
    POST  /api/agency/charter/requests                   POST /api/charter/requests
    GET   /api/agency/charter/requests[/{uid}]           GET /api/charter/requests[/{uid}]
    POST  /api/agency/charter/requests/{uid}/accept      POST /api/charter/requests/{uid}/accept      pays into escrow
    POST  /api/agency/charter/requests/{uid}/withdraw    POST /api/charter/requests/{uid}/withdraw
    POST  /api/agency/charter/requests/{uid}/cancel      POST /api/charter/requests/{uid}/cancel      refunded as the offer says
    GET|POST /api/agency/charter/requests/{uid}/travellers               the travellers on the seats (1126)
    DELETE   /api/agency/charter/requests/{uid}/travellers/{ticket_no}   (and the same under /api/charter)
    Platform
    GET   /api/admin/charter/requests                    every carrier's requests (report.platform)
    GET   /api/admin/charter/commission                  PUT the platform's commission (policy.matrix)
"""
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import forbidden
from ..agency import service as agency_service
from . import charter

carrier = APIRouter(prefix="/api/carrier/charter", tags=["charter"])
agency = APIRouter(prefix="/api/agency/charter", tags=["charter"])
passenger = APIRouter(prefix="/api/charter", tags=["charter"])
platform = APIRouter(prefix="/api/admin/charter", tags=["charter"])

Status = Optional[Literal["REQUESTED", "QUOTED", "CONFIRMED", "COMPLETED", "DECLINED", "WITHDRAWN", "EXPIRED", "CANCELLED"]]


class ReasonIn(BaseModel):
    reason: str = Field(min_length=3, max_length=300)


class VehicleIn(BaseModel):
    vehicle_uid: uuid.UUID


class CommissionIn(BaseModel):
    commission_bp: int = Field(ge=0, le=3000)


def _need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden("missing permission: " + " | ".join(codes))


def _audit(request: Request, action: str, out: dict) -> dict:
    request.state.audit = {"action": action, "object_type": "charter_request", "reason": out["ref"]}
    return out


# ------------------------------------------------------------------ carrier
def _carrier(pr: Principal) -> int:
    _need(pr, "charter.manage")
    if not pr.company_id:
        raise forbidden("carrier staff only")
    return pr.company_id


@carrier.get("/offers")
async def carrier_offers(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"offers": await charter.carrier_offers(conn, company)}


@carrier.post("/offers", status_code=201)
async def create_offer(body: charter.OfferIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await charter.create_offer(conn, company, pr.user_id, body)
    request.state.audit = {"action": "charter.offer", "object_type": "charter_offer", "reason": f"{body.kind}: {body.title}"[:120]}
    return out


@carrier.patch("/offers/{uid}")
async def change_offer(uid: uuid.UUID, body: charter.OfferPatch, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await charter.change_offer(conn, company, uid, body)
    request.state.audit = {"action": "charter.offer_change", "object_type": "charter_offer", "reason": out["title"][:120]}
    return out


@carrier.get("/requests")
async def carrier_requests(request: Request, status: Status = Query(default=None), pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"requests": await charter.list_requests(conn, company_id=company, status=status)}


@carrier.post("/requests/{uid}/quote")
async def quote(uid: uuid.UUID, body: charter.QuoteIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await charter.quote(conn, company, pr.user_id, uid, body)
    return _audit(request, "charter.quote", out)


@carrier.post("/requests/{uid}/decline")
async def decline(uid: uuid.UUID, body: ReasonIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await charter.decline(conn, company, pr.user_id, uid, body.reason)
    return _audit(request, "charter.decline", out)


@carrier.post("/requests/{uid}/vehicle")
async def vehicle(uid: uuid.UUID, body: VehicleIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await charter.assign_vehicle(conn, company, uid, body.vehicle_uid)
    return _audit(request, "charter.vehicle", out)


@carrier.post("/requests/{uid}/complete")
async def complete(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _carrier(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await charter.complete(conn, ctx, company, pr.user_id, uid)
    return _audit(request, "charter.complete", out)


@carrier.get("/requests/{uid}/travellers")
async def carrier_travellers(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    """The travellers named on the seats of a charter (1126); they are on the trip's manifest as well."""
    company = _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await charter.travellers_view(conn, uid, company_id=company)


@carrier.post("/requests/{uid}/cancel")
async def carrier_cancel(uid: uuid.UUID, body: ReasonIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _carrier(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await charter.cancel(conn, ctx, uid, pr.user_id, body.reason, company_id=company)
    return _audit(request, "charter.cancel", out)


# ------------------------------------------------------------------ the customer: a tourism company or a traveller
def _agency(pr: Principal) -> charter.Customer:
    agency_id = agency_service.require_agency(pr)
    agency_service.need(pr, "booking.on_behalf")
    return charter.Customer(party_id=agency_id, user_id=pr.user_id, kind="AGENCY")


def _traveller(pr: Principal) -> charter.Customer:
    return charter.Customer(party_id=pr.party_id, user_id=pr.user_id, kind="PASSENGER")


def _customer_routes(router: APIRouter, portal: str, who) -> None:
    """The same requests for both kinds of customer, each under its own portal."""

    @router.get("/offers")
    async def offers(request: Request, kind: Optional[Literal["VEHICLE", "WHOLE_TRIP"]] = Query(default=None),
                     pr: Principal = Depends(require_portal(portal))):
        c = who(pr)
        async with db.transaction(context_for(request, pr)) as conn:
            return {"offers": await charter.open_offers(conn, c.kind, kind)}

    @router.post("/requests", status_code=201)
    async def ask(body: charter.RequestIn, request: Request, pr: Principal = Depends(require_portal(portal))):
        c = who(pr)
        async with db.transaction(context_for(request, pr)) as conn:
            out = await charter.create_request(conn, c, body)
        return out if out.get("replayed") else _audit(request, "charter.request", out)

    @router.get("/requests")
    async def mine(request: Request, status: Status = Query(default=None), pr: Principal = Depends(require_portal(portal))):
        c = who(pr)
        async with db.transaction(context_for(request, pr)) as conn:
            return {"requests": await charter.list_requests(conn, party_id=c.party_id, status=status)}

    @router.get("/requests/{uid}")
    async def one(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal(portal))):
        c = who(pr)
        async with db.transaction(context_for(request, pr)) as conn:
            return await charter.request_view(conn, uid, party_id=c.party_id)

    @router.post("/requests/{uid}/accept")
    async def accept(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal(portal))):
        c = who(pr)
        ctx = context_for(request, pr)
        async with db.transaction(ctx) as conn:
            out = await charter.accept(conn, ctx, c, uid)
        return out if out.get("replayed") else _audit(request, "charter.accept", out)

    @router.post("/requests/{uid}/withdraw")
    async def withdraw(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal(portal))):
        c = who(pr)
        async with db.transaction(context_for(request, pr)) as conn:
            out = await charter.withdraw(conn, c, uid)
        return _audit(request, "charter.withdraw", out)

    @router.post("/requests/{uid}/cancel")
    async def cancel(uid: uuid.UUID, body: ReasonIn, request: Request, pr: Principal = Depends(require_portal(portal))):
        c = who(pr)
        ctx = context_for(request, pr)
        async with db.transaction(ctx) as conn:
            out = await charter.cancel(conn, ctx, uid, pr.user_id, body.reason, who=c)
        return _audit(request, "charter.cancel", out)

    @router.get("/requests/{uid}/travellers")
    async def travellers(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal(portal))):
        c = who(pr)
        async with db.transaction(context_for(request, pr)) as conn:
            return await charter.travellers_view(conn, uid, party_id=c.party_id)

    @router.post("/requests/{uid}/travellers")
    async def name(uid: uuid.UUID, body: charter.TravellersIn, request: Request, pr: Principal = Depends(require_portal(portal))):
        c = who(pr)
        ctx = context_for(request, pr)
        async with db.transaction(ctx) as conn:
            out = await charter.name_travellers(conn, ctx, c, uid, body)
        return _audit(request, "charter.travellers", out)

    @router.delete("/requests/{uid}/travellers/{ticket_no}")
    async def unname(uid: uuid.UUID, ticket_no: str, request: Request, pr: Principal = Depends(require_portal(portal))):
        c = who(pr)
        ctx = context_for(request, pr)
        async with db.transaction(ctx) as conn:
            out = await charter.unname_traveller(conn, ctx, c, uid, ticket_no)
        return _audit(request, "charter.traveller_off", out)


_customer_routes(agency, "AGENCY", _agency)
_customer_routes(passenger, "PASSENGER", _traveller)


# ------------------------------------------------------------------ platform
@platform.get("/requests")
async def all_requests(request: Request, status: Status = Query(default=None), pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr, "report.platform", "policy.matrix")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await charter.list_requests(conn, status=status, limit=500)
        offers = await conn.fetchval("SELECT count(*) FROM sales.charter_offer WHERE status = 'ACTIVE'")
        carriers = await conn.fetchval("SELECT count(DISTINCT company_id) FROM sales.charter_offer WHERE status = 'ACTIVE'")
    return {"requests": rows, "active_offers": offers, "carriers": carriers}


@platform.get("/commission")
async def get_commission(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr, "policy.matrix")
    async with db.transaction(context_for(request, pr)) as conn:
        return {"commission_bp": await conn.fetchval("SELECT sales.setting_int('charter.commission_bp', 0)")}


@platform.put("/commission")
async def set_commission(body: CommissionIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr, "policy.matrix")
    async with db.transaction(context_for(request, pr)) as conn:
        bp = await conn.fetchval("SELECT sales.set_charter_commission($1)", body.commission_bp)
    request.state.audit = {"action": "charter.commission", "object_type": "setting", "reason": f"{bp} bp"}
    return {"commission_bp": bp}

"""Support (study 7.6): complaints, inquiries and claims from passengers, trip ratings, claim payment and the blocklist.

Passengers open cases on their own bookings, follow the public conversation and rate trips they travelled on. Staff
handle cases in the support module screens (crm.case and crm.case_event); the database sets references and service
levels, stamps the first response and keeps closed cases closed (schema file 1054). Finance pays an approved claim
here: the passenger's wallet is credited from the carrier's or the platform's wallet by someone other than the person
who approved it.
"""
import uuid
from datetime import datetime
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db, markets
from ...deps import Principal, context_for, require_permission, require_portal, sales_channel
from ...errors import ApiError, not_found
from ...ledger import company_wallet, platform_wallet, post_txn, user_wallet
from ...security import identifier_hash
from ...util import rows
from ..notify.outbox import emit

router = APIRouter(prefix="/api/support", tags=["support"])
admin = APIRouter(prefix="/api/admin/support", tags=["support"])
passenger = require_portal("PASSENGER")
CATEGORIES = ("DELAY", "CANCELLATION", "REFUND", "BAGGAGE", "STAFF", "VEHICLE", "SAFETY", "PAYMENT", "ACCOUNT", "OTHER")

CASE_COLS = """c.uid, c.ref, c.kind, c.category, c.priority, c.status, c.subject, c.description, c.claim_amount,
               c.approved_amount, c.payout_status, c.resolution, c.csat, c.first_due_at, c.resolve_due_at, c.created_at,
               c.updated_at, b.booking_ref"""


class CaseIn(BaseModel):
    kind: Literal["COMPLAINT", "INQUIRY", "CLAIM"] = "COMPLAINT"
    category: Literal[CATEGORIES] = "OTHER"           # type: ignore[valid-type]
    subject: str = Field(min_length=4, max_length=160)
    description: str = Field(min_length=10, max_length=4000)
    booking_ref: Optional[str] = Field(default=None, max_length=12)
    claim_amount: Optional[int] = Field(default=None, gt=0, le=100_000_000)


class MessageIn(BaseModel):
    body: str = Field(min_length=1, max_length=4000)


class CsatIn(BaseModel):
    score: int = Field(ge=1, le=5)


class RatingIn(BaseModel):
    ticket_uid: uuid.UUID
    stars: int = Field(ge=1, le=5)
    punctuality: Optional[int] = Field(default=None, ge=1, le=5)
    comfort: Optional[int] = Field(default=None, ge=1, le=5)
    staff: Optional[int] = Field(default=None, ge=1, le=5)
    comment: Optional[str] = Field(default=None, max_length=1000)


def _channel(request: Request) -> str:
    return "APP" if sales_channel(request).startswith("APP") else "WEB"


async def _own_case(conn, pr: Principal, case_uid: uuid.UUID):
    c = await conn.fetchrow("SELECT * FROM crm.\"case\" WHERE uid = $1 AND party_id = $2", case_uid, pr.party_id)
    if c is None:
        raise not_found("case")
    return c


# ------------------------------------------------------------------ passengers
@router.get("/cases")
async def my_cases(request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            f"""SELECT {CASE_COLS},
                       (SELECT count(*) FROM crm.case_event e WHERE e.case_id = c.id AND e.visibility = 'PUBLIC'
                           AND e.kind = 'REPLY' AND e.actor_role <> 'CUSTOMER') AS replies
                  FROM crm."case" c LEFT JOIN sales.booking b ON b.id = c.booking_id
                 WHERE c.party_id = $1 ORDER BY c.created_at DESC LIMIT 100""", pr.party_id)
    return {"cases": rows(recs), "categories": CATEGORIES}


@router.post("/cases", status_code=201)
async def open_case(body: CaseIn, request: Request, pr: Principal = Depends(passenger)):
    if body.kind == "CLAIM" and not body.claim_amount:
        raise ApiError(422, "CLAIM_AMOUNT_REQUIRED", "a claim states the amount claimed")
    if body.kind == "CLAIM" and not body.booking_ref:
        raise ApiError(422, "BOOKING_REQUIRED", "a claim is made on a booking")
    async with db.transaction(context_for(request, pr)) as conn:
        booking_id = None
        if body.booking_ref:
            booking_id = await conn.fetchval(
                "SELECT id FROM sales.booking WHERE booking_ref = $1 AND (booker_party_id = $2 OR sales.travels_on(id))",
                body.booking_ref.upper(), pr.party_id)
            if booking_id is None:
                raise not_found("booking")
        open_cases = await conn.fetchval(
            "SELECT count(*) FROM crm.\"case\" WHERE party_id = $1 AND status IN ('NEW','OPEN','WAITING')", pr.party_id)
        if open_cases >= 10:
            raise ApiError(429, "TOO_MANY_OPEN_CASES", "you already have ten open requests; we will answer them first")
        priority = "HIGH" if body.category == "SAFETY" else "NORMAL"
        rec = await conn.fetchrow(
            """INSERT INTO crm."case" (kind, category, priority, channel, subject, description, party_id, booking_id, claim_amount)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id, uid, ref""",
            body.kind, body.category, priority, _channel(request), body.subject.strip(), body.description.strip(),
            pr.party_id, booking_id, body.claim_amount if body.kind == "CLAIM" else None)
    request.state.audit = {"action": "case.open", "object_type": "case", "object_id": rec["id"]}
    return {"uid": str(rec["uid"]), "ref": rec["ref"]}


@router.get("/cases/{case_uid}")
async def case_detail(case_uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        c = await _own_case(conn, pr, case_uid)
        head = await conn.fetchrow(
            f"""SELECT {CASE_COLS} FROM crm."case" c LEFT JOIN sales.booking b ON b.id = c.booking_id WHERE c.id = $1""", c["id"])
        events = await conn.fetch(
            """SELECT kind, actor_role = 'CUSTOMER' AS mine, body, created_at FROM crm.case_event
                WHERE case_id = $1 AND visibility = 'PUBLIC' AND kind IN ('REPLY','ATTACHMENT','STATUS')
                ORDER BY id""", c["id"])
    return {"case": rows([head])[0], "messages": rows(events)}


@router.post("/cases/{case_uid}/messages", status_code=201)
async def add_message(case_uid: uuid.UUID, body: MessageIn, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        c = await _own_case(conn, pr, case_uid)
        if c["status"] in ("CLOSED", "REJECTED"):
            raise ApiError(409, "CASE_FINAL", "this request is closed; open a new one")
        await conn.execute(
            """INSERT INTO crm.case_event (case_id, actor_id, actor_role, kind, visibility, body)
               VALUES ($1, $2, 'CUSTOMER', 'REPLY', 'PUBLIC', $3)""", c["id"], pr.user_id, body.body.strip())
    request.state.audit = {"action": "case.message", "object_type": "case", "object_id": c["id"]}
    return {"ok": True}


@router.post("/cases/{case_uid}/satisfaction")
async def satisfaction(case_uid: uuid.UUID, body: CsatIn, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        c = await _own_case(conn, pr, case_uid)
        if c["status"] not in ("RESOLVED", "CLOSED"):
            raise ApiError(409, "CASE_NOT_RESOLVED", "rate the answer once the request is resolved")
        await conn.execute("UPDATE crm.\"case\" SET csat = $2 WHERE id = $1", c["id"], body.score)
    return {"ok": True}


@router.get("/ratable")
async def ratable(request: Request, pr: Principal = Depends(passenger)):
    """Tickets the caller travelled on in the last 30 days and has not rated yet."""
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT k.uid AS ticket_uid, k.ticket_no, t.trip_no, t.departure_at, so.name AS origin, sd.name AS destination,
                      cp.legal_name AS carrier_name
                 FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id JOIN ops.trip t ON t.id = k.trip_id
                 JOIN net.route r ON r.id = t.route_id JOIN net.station so ON so.id = r.origin_station_id
                 JOIN net.station sd ON sd.id = r.dest_station_id JOIN iam.party cp ON cp.id = t.company_id
                WHERE b.booker_party_id = $1 AND k.status <> 'CANCELLED'
                  AND (t.status = 'COMPLETED' OR k.status = 'BOARDED' OR t.arrival_at < now())
                  AND t.departure_at > now() - interval '30 days'
                  AND NOT EXISTS (SELECT 1 FROM crm.trip_rating x WHERE x.ticket_id = k.id)
                ORDER BY t.departure_at DESC LIMIT 20""", pr.party_id)
    return {"tickets": rows(recs)}


@router.post("/ratings", status_code=201)
async def rate(body: RatingIn, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        ticket = await conn.fetchrow("SELECT id, trip_id FROM sales.ticket WHERE uid = $1", body.ticket_uid)
        if ticket is None:
            raise not_found("ticket")
        if await conn.fetchval("SELECT 1 FROM crm.trip_rating WHERE ticket_id = $1", ticket["id"]):
            raise ApiError(409, "ALREADY_RATED", "this ticket is already rated")
        trip_company = await conn.fetchval("SELECT company_id FROM ops.trip WHERE id = $1", ticket["trip_id"])
        rid = await conn.fetchval(
            """INSERT INTO crm.trip_rating (ticket_id, trip_id, company_id, party_id, stars, punctuality, comfort, staff, comment)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id""",
            ticket["id"], ticket["trip_id"], trip_company, pr.party_id, body.stars, body.punctuality, body.comfort,
            body.staff, (body.comment or "").strip() or None)
    request.state.audit = {"action": "trip.rate", "object_type": "trip_rating", "object_id": rid}
    return {"ok": True}


# ------------------------------------------------------------------ finance: approved claims
@admin.get("/claims")
async def claims_due(request: Request, pr: Principal = Depends(require_permission("compensation.pay"))):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT c.uid, c.ref, c.subject, c.claim_amount, c.approved_amount, c.liable, c.payout_status, c.updated_at,
                      b.booking_ref, b.currency, cp.legal_name AS carrier_name, pp.legal_name AS customer_name
                 FROM crm."case" c LEFT JOIN sales.booking b ON b.id = c.booking_id
                 LEFT JOIN iam.party cp ON cp.id = c.company_id LEFT JOIN iam.party pp ON pp.id = c.party_id
                WHERE c.kind = 'CLAIM' AND c.payout_status = 'PENDING_FINANCE' ORDER BY c.updated_at""")
    return {"claims": rows(recs)}


@admin.post("/cases/{case_uid}/pay")
async def pay_claim(case_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_permission("compensation.pay"))):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        c = await conn.fetchrow("SELECT * FROM crm.\"case\" WHERE uid = $1 FOR UPDATE", case_uid)
        if c is None:
            raise not_found("case")
        if c["kind"] != "CLAIM" or c["payout_status"] != "PENDING_FINANCE":
            raise ApiError(409, "CLAIM_NOT_PAYABLE", "only an approved claim waiting for finance is paid")
        decider = await conn.fetchval(
            "SELECT actor_id FROM crm.case_event WHERE case_id = $1 AND kind = 'DECISION' ORDER BY id DESC LIMIT 1", c["id"])
        if decider == pr.user_id:
            raise ApiError(409, "FOUR_EYES", "the claim is paid by someone other than the person who approved it")
        # the booking's currency, else the claimant's market (1061)
        currency = (await conn.fetchval("SELECT currency FROM sales.booking WHERE id = $1", c["booking_id"])
                    or (await markets.of_party(conn, c["party_id"])).currency)
        async with db.system_scope(conn, ctx):
            source = (await company_wallet(conn, c["company_id"], currency) if c["liable"] == "CARRIER"
                      else await platform_wallet(conn, "PLATFORM", currency))
            target = await user_wallet(conn, c["party_id"], currency)
            txn = await post_txn(conn, "COMPENSATION", currency, f"case:{c['id']}:claim",
                                 [(source["id"], "DR", c["approved_amount"]), (target["id"], "CR", c["approved_amount"])],
                                 ref_type="case", ref_id=c["id"], user_id=pr.user_id, memo=c["ref"])
            await conn.execute("UPDATE crm.\"case\" SET payout_status = 'PAID', payout_ledger_txn_id = $2 WHERE id = $1",
                               c["id"], txn)
            user_id = await conn.fetchval(
                "SELECT id FROM iam.app_user WHERE party_id = $1 AND status = 'ACTIVE' ORDER BY id LIMIT 1", c["party_id"])
            await emit(conn, "claim.paid", "case", c["id"], {"case_ref": c["ref"], "amount": c["approved_amount"],
                                                              "user_id": user_id}, company_id=c["company_id"])
    request.state.audit = {"action": "claim.pay", "object_type": "case", "object_id": c["id"]}
    return {"ok": True, "amount": c["approved_amount"], "currency": currency}


# ------------------------------------------------------------------ security: the blocklist
class BlockIn(BaseModel):
    entry_type: Literal["DEVICE", "PHONE", "EMAIL", "IBAN", "ID_DOC", "CARD_BIN"]
    value: str = Field(min_length=3, max_length=200)
    reason: str = Field(min_length=5, max_length=300)
    expires_at: Optional[datetime] = None


def block_digest(value: str) -> bytes:
    """The digest the blocklist keeps: the same HMAC as login identifiers, over the value without spaces."""
    return identifier_hash("".join(value.split()))


@admin.post("/blocklist", status_code=201)
async def add_block(body: BlockIn, request: Request, pr: Principal = Depends(require_permission("security.console"))):
    async with db.transaction(context_for(request, pr)) as conn:
        rid = await conn.fetchval(
            """INSERT INTO sec.blocklist_entry (entry_type, value_hash, reason, added_by, expires_at)
               VALUES ($1, $2, $3, $4, $5) ON CONFLICT (entry_type, value_hash) DO NOTHING RETURNING id""",
            body.entry_type, block_digest(body.value), body.reason.strip(), pr.user_id, body.expires_at)
    if rid is None:
        raise ApiError(409, "ALREADY_BLOCKED", "this value is already on the blocklist")
    request.state.audit = {"action": "blocklist.add", "object_type": "blocklist_entry", "object_id": rid}
    return {"id": rid}

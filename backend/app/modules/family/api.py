"""Family accounts in the passenger portal (study 4.20).

    Head
    GET    /api/family                               my family: members, account balance, open requests (or, for a member, my record)
    POST   /api/family                               create the family (the head becomes its first member)
    POST   /api/family/members                       register a member with full details
    PATCH  /api/family/members/{uid}                 details, funding and limits
    DELETE /api/family/members/{uid}                 remove a member (a linked account is unlinked)
    POST   /api/family/members/{uid}/invite          a one-time code for the member's own device (shown once, 24 hours)
    POST   /api/family/requests/{uid}/approve        approve the account and how its purchases are paid
    POST   /api/family/requests/{uid}/reject
    GET    /api/family/members/{uid}/rules           times and routes the member may travel on the family's money
    POST   /api/family/members/{uid}/rules
    DELETE /api/family/rules/{uid}
    POST   /api/family/account/topup                 head wallet -> family trips account
    POST   /api/family/account/withdraw              family trips account -> head wallet
    GET    /api/family/spend                         charges made on behalf of members
    GET    /api/family/offers?company_id=            a carrier's family offers
    POST   /api/family/passes                        shuttle passes for several members at once, with the carrier's family offer

    Member (their own account, on their own device)
    POST   /api/family/join                          enter the head's code; the head then approves
    POST   /api/family/leave                         leave the family
"""
from __future__ import annotations

import uuid
from datetime import date, time, timedelta
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field, model_validator

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, not_found
from ...ledger import company_wallet, post_txn
from ...modular import features
from ..fares.categories import age_on, bands, category_for, family_offer
from ..notify.outbox import emit
from ..sales.models import MOBILE, NAME_PART
from . import service as fam

router = APIRouter(prefix="/api/family", tags=["family"])
passenger = require_portal("PASSENGER")
RELATIONS = Literal["SPOUSE", "SON", "DAUGHTER", "FATHER", "MOTHER", "BROTHER", "SISTER", "GRANDCHILD", "GRANDPARENT", "OTHER"]
FUNDING = Literal["OWN", "HEAD_WALLET", "FAMILY_ACCOUNT"]
DOCS = Literal["NATIONAL_ID", "PASSPORT", "RESIDENCE", "LAISSEZ_PASSER", "TRAVEL_DOCUMENT", "OTHER"]


async def _on() -> None:
    if not await features.is_on("family_accounts"):
        raise ApiError(404, "MODULE_DISABLED", "module family_accounts is switched off")


class FamilyIn(BaseModel):
    name: str = Field(min_length=2, max_length=80)


class Limits(BaseModel):
    funding: FUNDING = "HEAD_WALLET"
    per_trip_limit: Optional[int] = Field(default=None, gt=0, le=10_000_000_000)
    daily_limit: Optional[int] = Field(default=None, gt=0, le=10_000_000_000)
    monthly_limit: Optional[int] = Field(default=None, gt=0, le=100_000_000_000)


class MemberIn(Limits):
    relation: RELATIONS
    first_name: str = Field(min_length=1, max_length=60, pattern=NAME_PART)
    father_name: Optional[str] = Field(default=None, max_length=60, pattern=NAME_PART)
    grandfather_name: Optional[str] = Field(default=None, max_length=60, pattern=NAME_PART)
    last_name: str = Field(min_length=1, max_length=60, pattern=NAME_PART)
    nationality: str = Field(default="SY", pattern=r"^[A-Z]{2}$")
    birth_date: date
    gender: Optional[Literal["M", "F"]] = None
    id_type: Optional[DOCS] = None
    id_no: Optional[str] = Field(default=None, min_length=4, max_length=24, pattern=r"^[0-9A-Za-z \-/]+$")
    passport_expiry: Optional[date] = None
    mobile: Optional[str] = Field(default=None, pattern=MOBILE)

    @model_validator(mode="after")
    def _checks(self):
        if self.birth_date > date.today() or self.birth_date < date(1900, 1, 1):
            raise ValueError("BIRTH_DATE_INVALID: the date of birth is not valid")
        if self.id_no and not self.id_type:
            raise ValueError("ID_TYPE_REQUIRED: give the document type with the document number")
        if self.nationality == "SY" and age_on(self.birth_date, date.today()) >= 14 and not (self.father_name and self.grandfather_name):
            raise ValueError("NAME_PARTS_REQUIRED: Syrian citizens need first, father, grandfather and family names")
        return self


class MemberPatch(BaseModel):
    mobile: Optional[str] = Field(default=None, pattern=MOBILE)
    id_type: Optional[DOCS] = None
    id_no: Optional[str] = Field(default=None, min_length=4, max_length=24, pattern=r"^[0-9A-Za-z \-/]+$")
    passport_expiry: Optional[date] = None
    funding: Optional[FUNDING] = None
    per_trip_limit: Optional[int] = Field(default=None, ge=0, le=10_000_000_000)    # 0 removes the limit
    daily_limit: Optional[int] = Field(default=None, ge=0, le=10_000_000_000)
    monthly_limit: Optional[int] = Field(default=None, ge=0, le=100_000_000_000)


class RuleIn(BaseModel):
    rule_type: Literal["TIME_WINDOW", "ROUTE", "LINE"]
    days: Optional[list[int]] = Field(default=None, min_length=1, max_length=7)
    start_time: Optional[str] = Field(default=None, pattern=r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
    end_time: Optional[str] = Field(default=None, pattern=r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
    from_city: Optional[str] = Field(default=None, max_length=8)
    to_city: Optional[str] = Field(default=None, max_length=8)
    both_ways: bool = True
    line_id: Optional[int] = None

    @model_validator(mode="after")
    def _shape(self):
        if self.days and not set(self.days) <= set(range(1, 8)):
            raise ValueError("DAYS_INVALID: weekdays are 1 (Monday) to 7 (Sunday)")
        if self.rule_type == "TIME_WINDOW" and not (self.start_time and self.end_time and self.start_time < self.end_time):
            raise ValueError("TIME_WINDOW_INVALID: give a start time before the end time")
        if self.rule_type == "ROUTE" and not (self.from_city and self.to_city and self.from_city != self.to_city):
            raise ValueError("ROUTE_INVALID: give two different cities")
        if self.rule_type == "LINE" and not self.line_id:
            raise ValueError("LINE_REQUIRED: choose a line")
        return self


class Amount(BaseModel):
    amount: int = Field(gt=0, le=10_000_000_000)
    currency: str = Field(default="SYP", pattern=r"^[A-Z]{3}$")
    idempotency_key: str = Field(min_length=8, max_length=80)


class Approve(BaseModel):
    funding: FUNDING = "HEAD_WALLET"


class Join(BaseModel):
    code: str = Field(min_length=8, max_length=8, pattern=r"^[A-Za-z0-9]{8}$")
    device_label: Optional[str] = Field(default=None, max_length=120)
    device_id: Optional[str] = Field(default=None, min_length=8, max_length=200)


class FamilyPasses(BaseModel):
    plan_id: int
    member_uids: list[uuid.UUID] = Field(min_length=1, max_length=12)
    pay_from: Literal["HEAD_WALLET", "FAMILY_ACCOUNT"] = "HEAD_WALLET"
    idempotency_key: str = Field(min_length=8, max_length=80)


# ------------------------------------------------------------------ the family

async def _summary(conn: asyncpg.Connection, ctx: db.Context, m: fam.Membership) -> dict:
    f = m.family
    if m.role == "MEMBER":
        return {"role": "MEMBER", "family": {"uid": str(f["uid"]), "name": f["name"]}, "me": fam.member_view(m.member),
                "rules": await _member_rules(conn, m.member["id"])}
    members = await conn.fetch(
        "SELECT * FROM iam.family_member WHERE family_id = $1 AND status = 'ACTIVE' ORDER BY relation <> 'SELF', birth_date", f["id"])
    requests = await conn.fetch(
        """SELECT r.uid, r.status, r.device_label, r.submitted_at, r.expires_at, m.uid AS member_uid, m.first_name, m.last_name
             FROM iam.family_link_request r JOIN iam.family_member m ON m.id = r.member_id
            WHERE r.family_id = $1 AND r.status IN ('INVITED','PENDING') ORDER BY r.created_at DESC""", f["id"])
    async with db.system_scope(conn, ctx):
        acct = await conn.fetchrow("SELECT balance, currency FROM fin.wallet WHERE id = $1", f["trips_wallet_id"]) if f["trips_wallet_id"] else None
    return {"role": "HEAD", "family": {"uid": str(f["uid"]), "name": f["name"]},
            "account": {"balance": acct["balance"] if acct else 0, "currency": acct["currency"] if acct else "SYP"},
            "members": [fam.member_view(r) for r in members],
            "requests": [{"uid": str(r["uid"]), "status": r["status"], "device_label": r["device_label"],
                          "submitted_at": r["submitted_at"], "expires_at": r["expires_at"], "member_uid": str(r["member_uid"]),
                          "member": f"{r['first_name']} {r['last_name']}"} for r in requests]}


@router.get("")
async def my_family(request: Request, pr: Principal = Depends(passenger)):
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        m = await fam.membership(conn, pr.party_id)
        if m is None:
            return {"role": None}
        return await _summary(conn, ctx, m)


@router.post("", status_code=201)
async def create_family(body: FamilyIn, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        if await fam.membership(conn, pr.party_id):
            raise ApiError(409, "ALREADY_IN_FAMILY", "you already head or belong to a family")
        async with db.system_scope(conn, ctx):
            me = await conn.fetchrow("SELECT legal_name, birth_date, gender, nationality, mobile FROM iam.party WHERE id = $1", pr.party_id)
        f = await conn.fetchrow("INSERT INTO iam.family (head_party_id, name) VALUES ($1, $2) RETURNING *", pr.party_id, body.name)
        parts = (me["legal_name"] or "").split()
        first, last = (parts[0], parts[-1]) if len(parts) > 1 else ((parts or ["-"])[0], "-")
        father, grandfather = (parts[1], parts[2]) if len(parts) == 4 else (None, None)
        await conn.execute(
            """INSERT INTO iam.family_member (family_id, party_id, relation, first_name, father_name, grandfather_name, last_name,
                 nationality, birth_date, gender, mobile, funding) VALUES ($1, $2, 'SELF', $3, $4, $5, $6, $7, $8, $9, $10, 'OWN')""",
            f["id"], pr.party_id, first, father, grandfather, last, me["nationality"] or "SY", me["birth_date"] or date(1990, 1, 1),
            me["gender"], me["mobile"])
        request.state.audit = {"action": "family.create", "object_type": "iam.family", "object_id": f["id"]}
        return await _summary(conn, ctx, await fam.membership(conn, pr.party_id))


@router.post("/members", status_code=201)
async def add_member(body: MemberIn, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        f = await fam.head_family(conn, pr.party_id)
        if await conn.fetchval("SELECT count(*) FROM iam.family_member WHERE family_id = $1 AND status = 'ACTIVE'", f["id"]) >= 15:
            raise ApiError(409, "FAMILY_FULL", "a family has at most 15 members")
        name = " ".join(p for p in (body.first_name, body.father_name, body.grandfather_name, body.last_name) if p)
        async with db.system_scope(conn, ctx):
            party = await conn.fetchval(
                """INSERT INTO iam.party (party_type, legal_name, nationality, birth_date, gender, mobile, country_code)
                   VALUES ('PERSON', $1, $2, $3, $4, $5, 'SY') RETURNING id""", name, body.nationality, body.birth_date, body.gender, body.mobile)
            enc, bidx, last4, key = await fam.seal_document(conn, body.id_type, body.id_no, body.nationality)
        m = await conn.fetchrow(
            """INSERT INTO iam.family_member (family_id, party_id, relation, first_name, father_name, grandfather_name, last_name,
                 nationality, birth_date, gender, id_type, id_no_enc, id_no_bidx, id_no_last4, enc_key_id, passport_expiry, mobile,
                 funding, per_trip_limit, daily_limit, monthly_limit)
               VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21) RETURNING *""",
            f["id"], party, body.relation, body.first_name, body.father_name, body.grandfather_name, body.last_name, body.nationality,
            body.birth_date, body.gender, body.id_type, enc, bidx, last4, key, body.passport_expiry, body.mobile, body.funding,
            body.per_trip_limit, body.daily_limit, body.monthly_limit)
        request.state.audit = {"action": "family.member_add", "object_type": "iam.family_member", "object_id": m["id"]}
    return fam.member_view(m)


@router.patch("/members/{uid}")
async def update_member(uid: uuid.UUID, body: MemberPatch, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        f = await fam.head_family(conn, pr.party_id)
        m = await fam.member_by_uid(conn, f["id"], uid)
        sets, args = [], [m["id"]]

        def put(col, val):
            args.append(val)
            sets.append(f"{col} = ${len(args)}")
        data = body.model_dump(exclude_unset=True)
        for col in ("mobile", "passport_expiry", "funding"):
            if col in data:
                put(col, data[col])
        for col in ("per_trip_limit", "daily_limit", "monthly_limit"):
            if col in data:
                put(col, data[col] or None)
        if data.get("id_no"):
            id_type = data.get("id_type") or m["id_type"]
            if not id_type:
                raise ApiError(422, "ID_TYPE_REQUIRED", "give the document type with the document number")
            async with db.system_scope(conn, ctx):
                enc, bidx, last4, key = await fam.seal_document(conn, id_type, data["id_no"], m["nationality"])
            for col, val in (("id_type", id_type), ("id_no_enc", enc), ("id_no_bidx", bidx), ("id_no_last4", last4), ("enc_key_id", key)):
                put(col, val)
        if m["relation"] == "SELF" and data.get("funding") not in (None, "OWN"):
            raise ApiError(409, "HEAD_PAYS_OWN", "the head always pays from their own wallet")
        if sets:
            m = await conn.fetchrow(f"UPDATE iam.family_member SET {', '.join(sets)} WHERE id = $1 RETURNING *", *args)
        request.state.audit = {"action": "family.member_update", "object_type": "iam.family_member", "object_id": m["id"]}
    return fam.member_view(m)


@router.delete("/members/{uid}")
async def remove_member(uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        f = await fam.head_family(conn, pr.party_id)
        m = await fam.member_by_uid(conn, f["id"], uid)
        if m["relation"] == "SELF":
            raise ApiError(409, "CANNOT_REMOVE_HEAD", "the head cannot be removed")
        await conn.execute(
            """UPDATE iam.family_member SET status = 'REMOVED', account_status = CASE WHEN account_status = 'LINKED' THEN 'REVOKED'
                 ELSE account_status END, linked_user_id = NULL WHERE id = $1""", m["id"])
        await conn.execute("UPDATE iam.family_link_request SET status = 'CANCELLED' WHERE member_id = $1 AND status IN ('INVITED','PENDING')", m["id"])
        request.state.audit = {"action": "family.member_remove", "object_type": "iam.family_member", "object_id": m["id"]}
    return {"ok": True}


# ------------------------------------------------------------------ linking a member's own account

@router.post("/members/{uid}/invite", status_code=201)
async def invite(uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        f = await fam.head_family(conn, pr.party_id)
        m = await fam.member_by_uid(conn, f["id"], uid)
        if m["relation"] == "SELF" or m["account_status"] == "LINKED":
            raise ApiError(409, "ALREADY_LINKED", "this member already has a linked account")
        await conn.execute("UPDATE iam.family_link_request SET status = 'CANCELLED' WHERE member_id = $1 AND status IN ('INVITED','PENDING')", m["id"])
        code = fam.new_code()
        expires = fam.invite_expiry()
        await conn.execute(
            "INSERT INTO iam.family_link_request (family_id, member_id, invite_code_hash, expires_at) VALUES ($1, $2, $3, $4)",
            f["id"], m["id"], fam.code_hash(code), expires)
        await conn.execute("UPDATE iam.family_member SET account_status = 'INVITED' WHERE id = $1", m["id"])
        request.state.audit = {"action": "family.invite", "object_type": "iam.family_member", "object_id": m["id"]}
    return {"code": code, "expires_at": expires}


@router.post("/join")
async def join(body: Join, request: Request, pr: Principal = Depends(passenger)):
    """Called from the member's own account on their device. Nothing is linked until the head approves."""
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        if await fam.membership(conn, pr.party_id):
            raise ApiError(409, "ALREADY_IN_FAMILY", "this account already heads or belongs to a family")
        async with db.system_scope(conn, ctx):
            req = await conn.fetchrow(
                """SELECT r.*, f.head_party_id, f.name AS family_name FROM iam.family_link_request r JOIN iam.family f ON f.id = r.family_id
                    WHERE r.invite_code_hash = $1 AND r.status = 'INVITED' AND r.expires_at > now()""", fam.code_hash(body.code))
            if req is None:
                raise ApiError(404, "INVITE_INVALID", "the code is wrong or has expired")
            if req["head_party_id"] == pr.party_id:
                raise ApiError(409, "OWN_INVITE", "use the code on the family member's own account")
            await conn.execute(
                """UPDATE iam.family_link_request SET status = 'PENDING', requester_user_id = $2, requester_party_id = $3,
                     device_label = $4, device_hash = $5, ip = $6, submitted_at = now() WHERE id = $1""",
                req["id"], pr.user_id, pr.party_id, body.device_label, fam.device_hash(body.device_id) if body.device_id else None,
                request.state.client_ip)
            await conn.execute("UPDATE iam.family_member SET account_status = 'PENDING' WHERE id = $1", req["member_id"])
            head_user = await conn.fetchval("SELECT id FROM iam.app_user WHERE party_id = $1 ORDER BY id LIMIT 1", req["head_party_id"])
            await emit(conn, "family.link_requested", "family", req["family_id"],
                       {"booker_user_id": head_user, "device_label": body.device_label or ""})
        request.state.audit = {"action": "family.join_request", "object_type": "iam.family_link_request", "object_id": req["id"]}
    return {"status": "PENDING", "family": req["family_name"]}


async def _request(conn: asyncpg.Connection, family_id: int, uid: uuid.UUID) -> asyncpg.Record:
    r = await conn.fetchrow("SELECT * FROM iam.family_link_request WHERE family_id = $1 AND uid = $2", family_id, uid)
    if r is None:
        raise not_found("request")
    if r["status"] != "PENDING":
        raise ApiError(409, "INVALID_STATE", "this request is not waiting for approval")
    return r


@router.post("/requests/{uid}/approve")
async def approve(uid: uuid.UUID, body: Approve, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        f = await fam.head_family(conn, pr.party_id)
        r = await _request(conn, f["id"], uid)
        await fam.link_account(conn, ctx, r, body.funding, pr.user_id)
        async with db.system_scope(conn, ctx):
            await emit(conn, "family.link_approved", "family", f["id"], {"booker_user_id": r["requester_user_id"], "family": f["name"]})
        request.state.audit = {"action": "family.link_approve", "object_type": "iam.family_link_request", "object_id": r["id"]}
    return {"status": "APPROVED", "funding": body.funding}


@router.post("/requests/{uid}/reject")
async def reject(uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        f = await fam.head_family(conn, pr.party_id)
        r = await _request(conn, f["id"], uid)
        await conn.execute("UPDATE iam.family_link_request SET status = 'REJECTED', decided_at = now(), decided_by = $2 WHERE id = $1",
                           r["id"], pr.user_id)
        await conn.execute("UPDATE iam.family_member SET account_status = 'NONE' WHERE id = $1", r["member_id"])
        request.state.audit = {"action": "family.link_reject", "object_type": "iam.family_link_request", "object_id": r["id"]}
    return {"status": "REJECTED"}


@router.post("/leave")
async def leave(request: Request, pr: Principal = Depends(passenger)):
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        m = await fam.membership(conn, pr.party_id)
        if m is None or m.role != "MEMBER":
            raise ApiError(409, "NOT_A_MEMBER", "you do not belong to a family")
        async with db.system_scope(conn, ctx):
            await conn.execute(
                "UPDATE iam.family_member SET status = 'REMOVED', account_status = 'REVOKED', linked_user_id = NULL WHERE id = $1",
                m.member["id"])
        request.state.audit = {"action": "family.leave", "object_type": "iam.family_member", "object_id": m.member["id"]}
    return {"ok": True}


# ------------------------------------------------------------------ travel rules

def _rule_view(r) -> dict:
    return {"uid": str(r["uid"]), "rule_type": r["rule_type"], "days": r["days"],
            "start_time": r["start_time"].strftime("%H:%M") if r["start_time"] else None,
            "end_time": r["end_time"].strftime("%H:%M") if r["end_time"] else None,
            "from_city_id": r["from_city_id"], "to_city_id": r["to_city_id"], "both_ways": r["both_ways"], "line_id": r["line_id"]}


async def _member_rules(conn: asyncpg.Connection, member_id: int) -> list[dict]:
    rows = await conn.fetch(
        """SELECT r.*, a.code AS from_city, b.code AS to_city, l.name AS line FROM iam.family_travel_rule r
             LEFT JOIN ref.city a ON a.id = r.from_city_id LEFT JOIN ref.city b ON b.id = r.to_city_id
             LEFT JOIN net.line l ON l.id = r.line_id WHERE r.member_id = $1 AND r.active ORDER BY r.id""", member_id)
    return [_rule_view(r) | {"from_city": r["from_city"], "to_city": r["to_city"], "line": r["line"]} for r in rows]


def _time(v: Optional[str]) -> Optional[time]:
    return time.fromisoformat(v) if v else None


@router.get("/members/{uid}/rules")
async def rules(uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        f = await fam.head_family(conn, pr.party_id)
        m = await fam.member_by_uid(conn, f["id"], uid)
        return {"rules": await _member_rules(conn, m["id"])}


@router.post("/members/{uid}/rules", status_code=201)
async def add_rule(uid: uuid.UUID, body: RuleIn, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        f = await fam.head_family(conn, pr.party_id)
        m = await fam.member_by_uid(conn, f["id"], uid)
        if m["relation"] == "SELF":
            raise ApiError(409, "HEAD_UNLIMITED", "rules apply to family members, not to the head")
        cities = {}
        for code in (body.from_city, body.to_city):
            if code:
                cid = await conn.fetchval("SELECT id FROM ref.city WHERE code = $1", code.upper())
                if cid is None:
                    raise not_found("city")
                cities[code] = cid
        if body.line_id and not await conn.fetchval("SELECT 1 FROM net.line WHERE id = $1", body.line_id):
            raise not_found("line")
        r = await conn.fetchrow(
            """INSERT INTO iam.family_travel_rule (member_id, rule_type, days, start_time, end_time, from_city_id, to_city_id,
                 both_ways, line_id) VALUES ($1, $2, $3::smallint[], $4, $5, $6, $7, $8, $9) RETURNING *""",
            m["id"], body.rule_type, body.days, _time(body.start_time), _time(body.end_time), cities.get(body.from_city), cities.get(body.to_city),
            body.both_ways, body.line_id if body.rule_type == "LINE" else None)
        request.state.audit = {"action": "family.rule_add", "object_type": "iam.family_travel_rule", "object_id": r["id"]}
    return _rule_view(r)


@router.delete("/rules/{uid}")
async def delete_rule(uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        f = await fam.head_family(conn, pr.party_id)
        n = await conn.execute(
            """DELETE FROM iam.family_travel_rule r USING iam.family_member m
                WHERE r.uid = $1 AND m.id = r.member_id AND m.family_id = $2""", uid, f["id"])
        if n.endswith(" 0"):
            raise not_found("rule")
    return {"ok": True}


# ------------------------------------------------------------------ family trips account

@router.post("/account/topup")
async def topup(body: Amount, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        f = await fam.head_family(conn, pr.party_id)
        return await fam.transfer(conn, ctx, f, body.amount, body.currency, True, f"family:{f['id']}:in:{body.idempotency_key}", pr.user_id)


@router.post("/account/withdraw")
async def withdraw(body: Amount, request: Request, pr: Principal = Depends(passenger)):
    await _on()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        f = await fam.head_family(conn, pr.party_id)
        return await fam.transfer(conn, ctx, f, body.amount, body.currency, False, f"family:{f['id']}:out:{body.idempotency_key}", pr.user_id)


@router.get("/spend")
async def spend(request: Request, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        f = await fam.head_family(conn, pr.party_id)
        rows = await conn.fetch(
            """SELECT s.source, s.amount, s.currency, s.ref_type, s.created_at, m.uid AS member_uid, m.first_name, m.last_name
                 FROM iam.family_spend s JOIN iam.family_member m ON m.id = s.member_id
                WHERE s.family_id = $1 ORDER BY s.created_at DESC LIMIT 200""", f["id"])
    return {"spend": [dict(r) | {"member_uid": str(r["member_uid"])} for r in rows]}


# ------------------------------------------------------------------ offers and passes for the whole family

@router.get("/offers")
async def offers(request: Request, company_id: Optional[int] = None, pr: Principal = Depends(passenger)):
    await _on()
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT o.uid, o.code, o.name, o.applies_to, o.min_members, o.min_adults, o.min_minors, o.discount_type, o.discount_value,
                      o.max_discount, upper(o.valid) AS valid_until, p.legal_name AS carrier, o.company_id
                 FROM pricing.family_offer o JOIN iam.party p ON p.id = o.company_id
                WHERE o.status = 'ACTIVE' AND o.valid @> current_date AND ($1::bigint IS NULL OR o.company_id = $1)
                ORDER BY p.legal_name, o.code""", company_id)
    return {"offers": [dict(r) | {"uid": str(r["uid"]), "discount_value": float(r["discount_value"])} for r in rows]}


@router.post("/passes", status_code=201)
async def family_passes(body: FamilyPasses, request: Request, pr: Principal = Depends(passenger)):
    """One payment for a shuttle pass per chosen member, at the plan price less the carrier's family offer."""
    await _on()
    if not await features.is_on("shuttle_subscriptions"):
        raise ApiError(404, "MODULE_DISABLED", "module shuttle_subscriptions is switched off")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        f = await fam.head_family(conn, pr.party_id)
        plan = await conn.fetchrow("SELECT * FROM sales.subscription_plan WHERE id = $1 AND status = 'ACTIVE'", body.plan_id)
        if plan is None:
            raise not_found("plan")
        if len(set(body.member_uids)) != len(body.member_uids):
            raise ApiError(422, "DUPLICATE_MEMBER", "a member is chosen twice")
        members = [await fam.member_by_uid(conn, f["id"], u) for u in body.member_uids]
        today = date.today()
        b = await bands(conn, plan["company_id"])
        cats = [category_for(b, m["birth_date"], today, None) for m in members]
        if plan["passenger_category"] in ("ADULT", "CHILD") and any(c != plan["passenger_category"] and not (
                plan["passenger_category"] == "CHILD" and c == "INFANT") for c in cats):
            raise ApiError(422, "PLAN_CATEGORY", f"this plan is for the {plan['passenger_category'].lower()} category")
        for m in members:
            if await conn.fetchval(
                    """SELECT 1 FROM sales.subscription WHERE plan_id = $1 AND party_id = $2 AND status = 'ACTIVE' AND ends_on >= current_date""",
                    plan["id"], m["party_id"]):
                raise ApiError(409, "ALREADY_SUBSCRIBED", f"{m['first_name']} already has this pass")
        gross = plan["price"] * len(members)
        adults = sum(c == "ADULT" for c in cats)
        offer = await family_offer(conn, plan["company_id"], None, "PASSES", today, len(members), adults, len(members) - adults,
                                   gross, len(members))
        discount = offer.discount if offer else 0
        total = gross - discount
        async with db.system_scope(conn, ctx):
            wallet = await fam.funding_wallet(conn, f, body.pay_from, plan["currency"])
            if wallet["balance"] - wallet["hold_balance"] < total:
                raise ApiError(402, "INSUFFICIENT_BALANCE", "balance is not enough", required=total,
                               balance=wallet["balance"] - wallet["hold_balance"])
            operator = await company_wallet(conn, plan["company_id"], plan["currency"])
            try:
                txn = await post_txn(conn, "SUBSCRIPTION_PAY", plan["currency"], f"family-passes:{f['id']}:{body.idempotency_key}",
                                     [(wallet["id"], "DR", total), (operator["id"], "CR", total)], ref_type="subscription",
                                     user_id=pr.user_id, memo=f"{plan['code']} x{len(members)}")
            except asyncpg.UniqueViolationError:
                raise ApiError(409, "DUPLICATE_REQUEST", "this payment was already made")
            out = []
            share, left = (total // len(members)) // 100 * 100, total
            for i, m in enumerate(members):
                paid = left if i == len(members) - 1 else share
                left -= paid
                sub = await conn.fetchrow(
                    """INSERT INTO sales.subscription (plan_id, company_id, party_id, wallet_id, starts_on, ends_on, price_paid, currency,
                         ledger_txn_id, status, family_id, purchased_by_party_id, family_offer_id)
                       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'ACTIVE', $10, $11, $12) RETURNING id, uid, ends_on""",
                    plan["id"], plan["company_id"], m["party_id"], wallet["id"], today, today + timedelta(days=plan["period_days"] - 1),
                    paid, plan["currency"], txn, f["id"], pr.party_id, offer.offer_id if offer else None)
                pass_no = "SP" + uuid.uuid4().hex[:10].upper()
                await conn.execute("INSERT INTO sales.shuttle_pass (subscription_id, pass_no, medium, status) VALUES ($1, $2, 'QR', 'ACTIVE')",
                                   sub["id"], pass_no)
                if m["relation"] != "SELF":
                    await fam.log_spend(conn, f["id"], m["id"], body.pay_from, paid, plan["currency"], "subscription", sub["id"],
                                        pr.user_id, txn)
                out.append({"member_uid": str(m["uid"]), "subscription_uid": str(sub["uid"]), "pass_no": pass_no, "price_paid": paid,
                            "ends_on": sub["ends_on"]})
        request.state.audit = {"action": "family.passes", "object_type": "sales.subscription_plan", "object_id": plan["id"]}
    return {"total": total, "gross": gross, "discount": discount, "offer": offer.code if offer else None, "currency": plan["currency"],
            "passes": out}

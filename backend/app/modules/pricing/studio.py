"""Pricing and tax studio (owner's note of 25 October 2026: pricing and taxes made professional).

One place where the platform's finance officers see and change what a traveller pays and where each part goes:

    GET  /api/admin/pricing/taxes                 jurisdictions and every tax scheme with its rules and bands, in plain terms
    POST /api/admin/pricing/taxes                 a scheme with its rules and bands in one step, waiting for a second officer;
                                                  {from_id} makes it the next version of that scheme (same code)
    POST /api/admin/pricing/taxes/{id}/approve    a second officer puts it in force; the version it replaces ends when it starts
    POST /api/admin/pricing/taxes/{id}/withdraw   a waiting scheme is withdrawn (kept, retired)
    POST /api/admin/pricing/taxes/{id}/retire     a scheme in force stops applying from now
    GET  /api/admin/pricing/preview-options       what the preview can be asked about
    POST /api/admin/pricing/preview               the receipt of a sale: fares, the taxes inside them, the platform fee and its
                                                  taxes, the payment fee and an agency's commission, and who receives what;
                                                  waiting schemes can be tried before they are approved

The taxes are those of the e-invoice engine (einvoice/taxes.py, 1108): the preview and the invoices give the same numbers.
Rules of a scheme in force never change (the database refuses it); a change is a new version approved by a second officer.
Amounts are in the smallest unit of the currency.
"""
from __future__ import annotations

import json
from datetime import date, datetime, time, timezone
from decimal import Decimal
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field, model_validator

from ... import db, markets, money_mode
from ...config import get_settings
from ...deps import Principal, context_for, require_permission
from ...errors import ApiError, not_found
from ...util import rows
from ..einvoice import taxes
from ..payments import fees
from . import commission

router = APIRouter(prefix="/api/admin/pricing", tags=["pricing"])

TaxType = Literal["VAT", "SALES", "LEVY", "FEE", "STAMP", "WITHHOLDING", "OTHER"]
Treatment = Literal["STANDARD", "ZERO", "EXEMPT", "OUT_OF_SCOPE", "REVERSE"]


async def _officer(pr: Principal = Depends(require_permission("pricing.tax_commission"))) -> Principal:
    if pr.portal != "PLATFORM":
        raise ApiError(403, "FORBIDDEN", "wrong portal for this operation")
    return pr


# ------------------------------------------------------------------ reading
def _summary(scheme: dict) -> str:
    """The scheme in a few words, for its card (the screens translate the parts)."""
    if scheme["treatment"] != "STANDARD":
        return scheme["treatment"]
    parts = []
    for r in scheme["rules"]:
        if r["calc_method"] == "PERCENT":
            parts.append(f"{Decimal(r['rate']).normalize():f}%")
        elif r["calc_method"] == "FIXED":
            parts.append(f"{r['amount']}/{r['applies_per']}")
        elif r["calc_method"] == "TIERED":
            parts.append(f"{len(r['bands'])} bands")
    return " + ".join(parts) or "—"


async def _schemes(conn: asyncpg.Connection, where: str = "TRUE", *args) -> list[dict]:
    recs = await conn.fetch(
        f"""SELECT s.id, s.code, s.name, s.tax_type, s.treatment, s.scope, s.collected_by, s.version, s.status,
                   lower(s.valid) AS valid_from, upper(s.valid) AS valid_to, s.created_at,
                   j.id AS jurisdiction_id, j.name AS jurisdiction, j.country_code,
                   p.uid AS payable_to_uid, p.legal_name AS payable_to,
                   cu.email AS created_by, au.email AS approved_by,
                   (s.status = 'ACTIVE' AND s.valid @> now()) AS in_force,
                   (s.status = 'ACTIVE' AND lower(s.valid) > now()) AS scheduled
              FROM pricing.tax_scheme s JOIN pricing.jurisdiction j ON j.id = s.jurisdiction_id
              LEFT JOIN iam.party p ON p.id = s.payable_to_party_id
              LEFT JOIN iam.app_user cu ON cu.id = s.created_by LEFT JOIN iam.app_user au ON au.id = s.approved_by
             WHERE {where} ORDER BY s.code, s.version DESC""", *args)
    out = [dict(r) for r in recs]
    if not out:
        return []
    rules = await conn.fetch(
        """SELECT id, scheme_id, seq, calc_method, rate, amount, base_type, base_include, compound_mode, min_amount, max_amount,
                  rounding_rule, applies_per FROM pricing.tax_rule WHERE scheme_id = ANY($1::bigint[]) ORDER BY scheme_id, priority, seq""",
        [s["id"] for s in out])
    bands = await conn.fetch(
        """SELECT tax_rule_id, dimension, from_value, to_value, rate, amount, mode FROM pricing.rate_band
            WHERE tax_rule_id = ANY($1::bigint[]) ORDER BY tax_rule_id, from_value""", [r["id"] for r in rules])
    by_rule: dict[int, list] = {}
    for b in bands:
        by_rule.setdefault(b["tax_rule_id"], []).append({k: (float(v) if isinstance(v, Decimal) else v) for k, v in dict(b).items() if k != "tax_rule_id"})
    by_scheme: dict[int, list] = {}
    for r in rules:
        d = dict(r)
        d["base_include"] = d["base_include"] if isinstance(d["base_include"], list) else json.loads(d["base_include"] or "[]")
        d["rate"] = float(d["rate"]) if d["rate"] is not None else None
        d["bands"] = by_rule.get(d.pop("id"), [])
        d.pop("scheme_id")
        by_scheme.setdefault(r["scheme_id"], []).append(d)
    for s in out:
        s["scope"] = s["scope"] if isinstance(s["scope"], dict) else json.loads(s["scope"] or "{}")
        s["rules"] = by_scheme.get(s["id"], [])
        s["summary"] = _summary(s)
        for k in ("valid_from", "valid_to", "created_at"):
            s[k] = s[k].isoformat() if s[k] else None
        s["payable_to_uid"] = str(s["payable_to_uid"]) if s["payable_to_uid"] else None
    return out


@router.get("/taxes")
async def tax_overview(request: Request, pr: Principal = Depends(_officer)):
    async with db.transaction(context_for(request, pr)) as conn:
        juris = await conn.fetch("SELECT id, country_code, level, name FROM pricing.jurisdiction ORDER BY country_code, name")
        schemes = await _schemes(conn)
    return {"jurisdictions": rows(juris), "schemes": schemes, "me": pr.email}


# ------------------------------------------------------------------ writing
class BandIn(BaseModel):
    dimension: Literal["AMOUNT", "DISTANCE"] = "AMOUNT"
    from_value: float = Field(ge=0)
    to_value: Optional[float] = Field(default=None, gt=0)
    rate: Optional[float] = Field(default=None, ge=0, le=100)
    amount: Optional[int] = Field(default=None, ge=0)
    mode: Literal["WHOLE", "MARGINAL"] = "WHOLE"

    @model_validator(mode="after")
    def _terms(self):
        if (self.rate is None) == (self.amount is None):
            raise ValueError("a band gives a rate or an amount")
        if self.to_value is not None and self.to_value <= self.from_value:
            raise ValueError("a band ends after it starts")
        return self


class RuleIn(BaseModel):
    calc_method: Literal["PERCENT", "FIXED", "TIERED"]
    rate: Optional[float] = Field(default=None, ge=0, le=100)
    amount: Optional[int] = Field(default=None, ge=0)
    base_type: Literal["FARE", "TAXES"] = "FARE"
    base_include: list[str] = Field(default_factory=list, max_length=10)
    compound_mode: Literal["ADD", "CASCADE", "MAX", "MIN"] = "ADD"
    min_amount: Optional[int] = Field(default=None, ge=0)
    max_amount: Optional[int] = Field(default=None, ge=0)
    rounding: Literal["HALF_UP", "HALF_EVEN", "DOWN", "UP"] = "HALF_UP"
    applies_per: Literal["TICKET", "BOOKING", "PASSENGER"] = "TICKET"
    bands: list[BandIn] = Field(default_factory=list, max_length=20)

    @model_validator(mode="after")
    def _terms(self):
        if self.calc_method == "PERCENT" and self.rate is None:
            raise ValueError("a percent rule gives its rate")
        if self.calc_method == "FIXED" and self.amount is None:
            raise ValueError("a fixed rule gives its amount")
        if self.calc_method == "TIERED" and not self.bands:
            raise ValueError("a tiered rule gives its bands")
        if self.base_type == "TAXES" and not self.base_include:
            raise ValueError("a tax on taxes names the taxes it is levied on")
        if self.min_amount is not None and self.max_amount is not None and self.min_amount > self.max_amount:
            raise ValueError("the minimum is above the maximum")
        if len({b.dimension for b in self.bands}) > 1 or len({b.mode for b in self.bands}) > 1:
            raise ValueError("the bands of a rule share one dimension and one mode")
        return self


class SchemeIn(BaseModel):
    code: str = Field(pattern=r"^[A-Z][A-Z0-9_-]{1,29}$")
    name: str = Field(min_length=2, max_length=120)
    jurisdiction_id: int
    tax_type: TaxType
    treatment: Treatment = "STANDARD"
    collected_by: Literal["CARRIER", "PLATFORM", "AUTHORITY"] = "PLATFORM"
    payable_to_uid: Optional[str] = None
    products: list[Literal["TICKET", "BOOKING_FEE"]] = Field(default_factory=list)
    sellers: list[Literal["CARRIER", "PLATFORM"]] = Field(default_factory=list)
    origin_cities: list[str] = Field(default_factory=list, max_length=50)
    valid_from: date
    valid_to: Optional[date] = None
    rules: list[RuleIn] = Field(default_factory=list, max_length=10)
    from_id: Optional[int] = None                     # the scheme this one replaces as its next version

    @model_validator(mode="after")
    def _shape(self):
        if self.treatment == "STANDARD" and not self.rules:
            raise ValueError("a standard-rated tax gives at least one rule")
        if self.treatment != "STANDARD" and self.rules:
            raise ValueError("an exempt, zero-rated or out-of-scope tax has no rules")
        if self.valid_to is not None and self.valid_to <= self.valid_from:
            raise ValueError("the scheme ends before it starts")
        if self.code in {c for r in self.rules for c in r.base_include}:
            raise ValueError("a tax is not levied on itself")
        return self


def _start(d: date) -> datetime:
    """A scheme starts at the beginning of its first day (UTC); today means now, so it can apply at once."""
    at = datetime.combine(d, time.min, tzinfo=timezone.utc)
    return max(at, datetime.now(timezone.utc)) if d <= date.today() else at


@router.post("/taxes", status_code=201)
async def create_scheme(body: SchemeIn, request: Request, pr: Principal = Depends(_officer)):
    if body.valid_from < date.today():
        raise ApiError(422, "SCHEME_IN_PAST", "a tax scheme starts today or later; past sales keep the taxes they had")
    async with db.transaction(context_for(request, pr)) as conn:
        if not await conn.fetchval("SELECT EXISTS (SELECT 1 FROM pricing.jurisdiction WHERE id = $1)", body.jurisdiction_id):
            raise not_found("jurisdiction")
        payable = None
        if body.payable_to_uid:
            payable = await conn.fetchval("SELECT id FROM iam.party WHERE uid = $1::uuid", body.payable_to_uid)
            if payable is None:
                raise not_found("receiving authority")
        if body.from_id is not None:
            prev = await conn.fetchrow("SELECT code, status FROM pricing.tax_scheme WHERE id = $1", body.from_id)
            if prev is None:
                raise not_found("tax scheme")
            if prev["code"] != body.code:
                raise ApiError(422, "VERSION_CODE", "a new version keeps the scheme's code")
        elif await conn.fetchval("SELECT EXISTS (SELECT 1 FROM pricing.tax_scheme WHERE code = $1 AND status <> 'RETIRED')", body.code):
            raise ApiError(409, "SCHEME_EXISTS", "a scheme with this code exists; record a new version of it instead")
        known = {r["code"] for r in await conn.fetch("SELECT DISTINCT code FROM pricing.tax_scheme WHERE status IN ('ACTIVE', 'PENDING')")}
        unknown = sorted({c for r in body.rules for c in r.base_include} - known)
        if unknown:
            raise ApiError(422, "BASE_UNKNOWN", "the rule is levied on taxes that do not exist", codes=unknown)
        version = (await conn.fetchval("SELECT max(version) FROM pricing.tax_scheme WHERE code = $1", body.code) or 0) + 1
        scope = {k: v for k, v in (("products", body.products), ("sellers", body.sellers), ("origin_cities", body.origin_cities)) if v}
        start = _start(body.valid_from)
        end = datetime.combine(body.valid_to, time.min, tzinfo=timezone.utc) if body.valid_to else None
        sid = await conn.fetchval(
            """INSERT INTO pricing.tax_scheme (code, name, jurisdiction_id, tax_type, treatment, scope, collected_by, payable_to_party_id,
                                               valid, version, status, created_by)
               VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, tstzrange($9, $10), $11, 'PENDING', $12) RETURNING id""",
            body.code, body.name.strip(), body.jurisdiction_id, body.tax_type, body.treatment, json.dumps(scope), body.collected_by,
            payable, start, end, version, pr.user_id)
        for seq, r in enumerate(body.rules, start=1):
            rid = await conn.fetchval(
                """INSERT INTO pricing.tax_rule (scheme_id, seq, calc_method, rate, amount, base_type, base_include, compound_mode,
                                                 min_amount, max_amount, rounding_rule, applies_per, priority)
                   VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8, $9, $10, $11, $12, $13) RETURNING id""",
                sid, seq, r.calc_method, r.rate, r.amount, r.base_type, json.dumps(r.base_include), r.compound_mode,
                r.min_amount, r.max_amount, r.rounding, r.applies_per, seq * 10)
            for b in r.bands:
                await conn.execute(
                    """INSERT INTO pricing.rate_band (tax_rule_id, dimension, from_value, to_value, rate, amount, mode)
                       VALUES ($1, $2, $3, $4, $5, $6, $7)""", rid, b.dimension, b.from_value, b.to_value, b.rate, b.amount, b.mode)
    request.state.audit = {"action": "pricing.tax_scheme_create", "object_type": "tax_scheme", "object_id": sid,
                           "reason": f"{body.code} v{version}"}
    return {"id": sid, "code": body.code, "version": version, "status": "PENDING"}


TABLE = {"taxes": ("pricing.tax_scheme", "tax_scheme"), "commissions": ("pricing.commission_scheme", "commission_scheme")}
Kind = Literal["taxes", "commissions"]


async def _pending(conn: asyncpg.Connection, table: str, sid: int) -> asyncpg.Record:
    s = await conn.fetchrow(f"SELECT * FROM {table} WHERE id = $1 FOR UPDATE", sid)
    if s is None:
        raise not_found("scheme")
    if s["status"] != "PENDING":
        raise ApiError(409, "SCHEME_NOT_PENDING", "only a scheme waiting for approval can be approved or withdrawn")
    return s


@router.post("/{kind}/{sid}/approve")
async def approve_scheme(kind: Kind, sid: int, request: Request, pr: Principal = Depends(_officer)):
    table, obj = TABLE[kind]
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _pending(conn, table, sid)
        if s["created_by"] == pr.user_id:
            raise ApiError(403, "SAME_OFFICER", "a second officer approves a scheme, not the one who recorded it")
        start = max(s["valid"].lower, datetime.now(timezone.utc))
        # the version in force of the same code ends when this one starts; one that would start later is refused
        for old in await conn.fetch(f"SELECT id, valid FROM {table} WHERE code = $1 AND status = 'ACTIVE' AND id <> $2 FOR UPDATE", s["code"], sid):
            if old["valid"].lower >= start:
                raise ApiError(409, "VERSION_OVERLAP", "a version of this scheme already starts on or after this one; withdraw one of them")
            if old["valid"].upper is None or old["valid"].upper > start:
                await conn.execute(f"UPDATE {table} SET valid = tstzrange(lower(valid), $2) WHERE id = $1", old["id"], start)
        await conn.execute(f"UPDATE {table} SET status = 'ACTIVE', approved_by = $2, valid = tstzrange($3, upper(valid)) WHERE id = $1",
                           sid, pr.user_id, start)
    request.state.audit = {"action": f"pricing.{obj}_approve", "object_type": obj, "object_id": sid, "reason": s["code"]}
    return {"id": sid, "status": "ACTIVE", "valid_from": start.isoformat()}


@router.post("/{kind}/{sid}/withdraw")
async def withdraw_scheme(kind: Kind, sid: int, request: Request, pr: Principal = Depends(_officer)):
    table, obj = TABLE[kind]
    async with db.transaction(context_for(request, pr)) as conn:
        s = await _pending(conn, table, sid)
        await conn.execute(f"UPDATE {table} SET status = 'RETIRED' WHERE id = $1", sid)
    request.state.audit = {"action": f"pricing.{obj}_withdraw", "object_type": obj, "object_id": sid, "reason": s["code"]}
    return {"id": sid, "status": "RETIRED"}


@router.post("/{kind}/{sid}/retire")
async def retire_scheme(kind: Kind, sid: int, request: Request, pr: Principal = Depends(_officer)):
    table, obj = TABLE[kind]
    async with db.transaction(context_for(request, pr)) as conn:
        s = await conn.fetchrow(f"SELECT code, status FROM {table} WHERE id = $1 FOR UPDATE", sid)
        if s is None:
            raise not_found("scheme")
        if s["status"] != "ACTIVE":
            raise ApiError(409, "SCHEME_NOT_ACTIVE", "only a scheme in force is retired")
        await conn.execute(
            f"""UPDATE {table} SET status = 'RETIRED',
                       valid = tstzrange(lower(valid), greatest(lower(valid), least(coalesce(upper(valid), 'infinity'), now()))) WHERE id = $1""",
            sid)
    request.state.audit = {"action": f"pricing.{obj}_retire", "object_type": obj, "object_id": sid, "reason": s["code"]}
    return {"id": sid, "status": "RETIRED"}


# ------------------------------------------------------------------ commission schemes (1175)
async def _commissions(conn: asyncpg.Connection) -> list[dict]:
    recs = await conn.fetch(
        """SELECT s.id, s.code, s.name, s.type, s.funded_by, s.beneficiary_role, s.base_type, s.scope, s.version, s.status,
                  lower(s.valid) AS valid_from, upper(s.valid) AS valid_to, cu.email AS created_by, au.email AS approved_by,
                  (s.status = 'ACTIVE' AND s.valid @> now()) AS in_force, (s.status = 'ACTIVE' AND lower(s.valid) > now()) AS scheduled
             FROM pricing.commission_scheme s LEFT JOIN iam.app_user cu ON cu.id = s.created_by LEFT JOIN iam.app_user au ON au.id = s.approved_by
            ORDER BY s.code, s.version DESC""")
    out = [dict(r) for r in recs]
    rules = await conn.fetch(
        """SELECT r.id, r.scheme_id, r.seq, r.calc_method, r.rate, r.amount, r.min_amount, r.max_amount FROM pricing.commission_rule r
            WHERE r.scheme_id = ANY($1::bigint[]) ORDER BY r.scheme_id, r.seq""", [s["id"] for s in out])
    bands = await conn.fetch(
        """SELECT commission_rule_id, from_value, to_value, rate, amount, mode FROM pricing.rate_band
            WHERE commission_rule_id = ANY($1::bigint[]) ORDER BY commission_rule_id, from_value""", [r["id"] for r in rules])
    by_rule: dict[int, list] = {}
    for b in bands:
        by_rule.setdefault(b["commission_rule_id"], []).append({k: (float(v) if isinstance(v, Decimal) else v) for k, v in dict(b).items() if k != "commission_rule_id"})
    by_scheme: dict[int, list] = {}
    for r in rules:
        d = dict(r)
        d["rate"] = float(d["rate"]) if d["rate"] is not None else None
        d["bands"] = by_rule.get(d.pop("id"), [])
        by_scheme.setdefault(d.pop("scheme_id"), []).append(d)
    for s in out:
        s["scope"] = s["scope"] if isinstance(s["scope"], dict) else json.loads(s["scope"] or "{}")
        s["rules"] = by_scheme.get(s["id"], [])
        s["receiver"] = commission.RECEIVER[s["type"]]
        s["payer"] = commission.PAYER[s["funded_by"]]
        for k in ("valid_from", "valid_to"):
            s[k] = s[k].isoformat() if s[k] else None
    return out


@router.get("/commissions")
async def commission_overview(request: Request, pr: Principal = Depends(_officer)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"schemes": await _commissions(conn)}


class CommissionRuleIn(BaseModel):
    calc_method: Literal["PERCENT", "FIXED", "TIERED"]
    rate: Optional[float] = Field(default=None, ge=0, le=100)
    amount: Optional[int] = Field(default=None, ge=0)
    min_amount: Optional[int] = Field(default=None, ge=0)
    max_amount: Optional[int] = Field(default=None, ge=0)
    bands: list[BandIn] = Field(default_factory=list, max_length=20)

    @model_validator(mode="after")
    def _terms(self):
        if self.calc_method == "PERCENT" and self.rate is None:
            raise ValueError("a percent rule gives its rate")
        if self.calc_method == "FIXED" and self.amount is None:
            raise ValueError("a fixed rule gives its amount")
        if self.calc_method == "TIERED" and not self.bands:
            raise ValueError("a tiered rule gives its bands")
        if self.min_amount is not None and self.max_amount is not None and self.min_amount > self.max_amount:
            raise ValueError("the minimum is above the maximum")
        if len({b.mode for b in self.bands}) > 1 or any(b.dimension != "AMOUNT" for b in self.bands):
            raise ValueError("the bands of a commission are of the amount and share one mode")
        return self


class CommissionIn(BaseModel):
    code: str = Field(pattern=r"^[A-Z][A-Z0-9_-]{1,29}$")
    name: str = Field(min_length=2, max_length=120)
    type: Literal["PLATFORM", "INTERMEDIARY", "SUB_AGENT", "OVERRIDE", "PAYMENT", "REFERRAL"]
    funded_by: Literal["CARRIER", "PLATFORM", "CUSTOMER", "CHANNEL"]
    beneficiary_role: str = Field(default="", max_length=60)
    base_type: Literal["FARE", "NET", "FEE"] = "FARE"
    channels: list[Literal["WEB", "AGENCY", "COUNTER", "API"]] = Field(default_factory=list)
    valid_from: date
    valid_to: Optional[date] = None
    rules: list[CommissionRuleIn] = Field(min_length=1, max_length=10)
    from_id: Optional[int] = None

    @model_validator(mode="after")
    def _shape(self):
        if self.valid_to is not None and self.valid_to <= self.valid_from:
            raise ValueError("the scheme ends before it starts")
        if commission.RECEIVER[self.type] == commission.PAYER[self.funded_by]:
            raise ValueError("a commission is not paid by the one who receives it")
        return self


@router.post("/commissions", status_code=201)
async def create_commission(body: CommissionIn, request: Request, pr: Principal = Depends(_officer)):
    if body.valid_from < date.today():
        raise ApiError(422, "SCHEME_IN_PAST", "a commission scheme starts today or later; past sales keep the commissions they had")
    async with db.transaction(context_for(request, pr)) as conn:
        if body.from_id is not None:
            prev = await conn.fetchval("SELECT code FROM pricing.commission_scheme WHERE id = $1", body.from_id)
            if prev is None:
                raise not_found("commission scheme")
            if prev != body.code:
                raise ApiError(422, "VERSION_CODE", "a new version keeps the scheme's code")
        elif await conn.fetchval("SELECT EXISTS (SELECT 1 FROM pricing.commission_scheme WHERE code = $1 AND status <> 'RETIRED')", body.code):
            raise ApiError(409, "SCHEME_EXISTS", "a scheme with this code exists; record a new version of it instead")
        version = (await conn.fetchval("SELECT max(version) FROM pricing.commission_scheme WHERE code = $1", body.code) or 0) + 1
        scope = {"channels": body.channels} if body.channels else {}
        end = datetime.combine(body.valid_to, time.min, tzinfo=timezone.utc) if body.valid_to else None
        sid = await conn.fetchval(
            """INSERT INTO pricing.commission_scheme (code, name, type, funded_by, beneficiary_role, scope, base_type, valid, version, status, created_by)
               VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, tstzrange($8, $9), $10, 'PENDING', $11) RETURNING id""",
            body.code, body.name.strip(), body.type, body.funded_by, body.beneficiary_role.strip() or commission.RECEIVER[body.type].lower(),
            json.dumps(scope), body.base_type, _start(body.valid_from), end, version, pr.user_id)
        for seq, r in enumerate(body.rules, start=1):
            rid = await conn.fetchval(
                """INSERT INTO pricing.commission_rule (scheme_id, seq, calc_method, rate, amount, min_amount, max_amount)
                   VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id""", sid, seq, r.calc_method, r.rate, r.amount, r.min_amount, r.max_amount)
            for b in r.bands:
                await conn.execute(
                    """INSERT INTO pricing.rate_band (commission_rule_id, dimension, from_value, to_value, rate, amount, mode)
                       VALUES ($1, 'AMOUNT', $2, $3, $4, $5, $6)""", rid, b.from_value, b.to_value, b.rate, b.amount, b.mode)
    request.state.audit = {"action": "pricing.commission_scheme_create", "object_type": "commission_scheme", "object_id": sid,
                           "reason": f"{body.code} v{version}"}
    return {"id": sid, "code": body.code, "version": version, "status": "PENDING"}


# ------------------------------------------------------------------ the preview
@router.get("/preview-options")
async def preview_options(request: Request, pr: Principal = Depends(_officer)):
    async with db.transaction(context_for(request, pr)) as conn:
        methods = await conn.fetch(
            "SELECT code, name, adapter FROM fin.payment_provider WHERE status = 'ACTIVE' ORDER BY sort_order NULLS LAST, code")
        countries = await conn.fetch("SELECT DISTINCT country_code FROM pricing.jurisdiction ORDER BY 1")
        cities = await conn.fetch("SELECT code, name, country_code FROM ref.city WHERE is_active ORDER BY country_code, name LIMIT 500")
        no_funds = await money_mode.no_funds(conn)
    return {"methods": rows(methods), "countries": [r["country_code"] for r in countries], "cities": rows(cities),
            "platform_fee": 0 if no_funds else get_settings().platform_fee, "no_funds": no_funds}


class PreviewIn(BaseModel):
    fare: int = Field(gt=0, le=10_000_000_000)            # the price of one ticket, taxes included
    passengers: int = Field(default=1, ge=1, le=50)
    country: str = Field(default="SY", pattern=r"^[A-Z]{2}$")
    origin_city: Optional[str] = Field(default=None, max_length=10)
    distance_km: Optional[float] = Field(default=None, ge=0, le=5000)
    at: Optional[date] = None
    method: Optional[str] = Field(default=None, max_length=40)
    agency_commission_bp: int = Field(default=0, ge=0, le=5000)
    try_ids: list[int] = Field(default_factory=list, max_length=10)     # waiting schemes tried as if in force
    channel: Optional[Literal["WEB", "AGENCY", "COUNTER", "API"]] = None   # where the sale is made, for commission schemes
    try_commission_ids: list[int] = Field(default_factory=list, max_length=10)
    currency: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")   # the country's market currency when not given


def _kind(sc: Optional[taxes.Scheme]) -> str:
    """PERCENT when the tax is one rate of its base (the rate shown is the law's); otherwise the rate shown is effective."""
    if sc is None or sc.treatment != "STANDARD":
        return "NONE"
    return "PERCENT" if len(sc.rules) == 1 and sc.rules[0].calc_method == "PERCENT" else sc.rules[0].calc_method if len(sc.rules) == 1 else "MIXED"


def _tax_out(t: taxes.LineTax, times: int = 1, sc: Optional[taxes.Scheme] = None) -> dict:
    return {"code": t.code, "tax_type": t.tax_type, "treatment": t.treatment, "rate": float(t.rate), "base": t.base * times,
            "amount": t.amount * times, "payable_to_party_id": t.payable_to_party_id, "kind": _kind(sc)}


@router.post("/preview")
async def preview(body: PreviewIn, request: Request, pr: Principal = Depends(_officer)):
    from ..sales.service import commission_for
    at = datetime.combine(body.at, time(12), tzinfo=timezone.utc) if body.at else None
    async with db.transaction(context_for(request, pr)) as conn:
        no_funds = await money_mode.no_funds(conn)
        currency = body.currency or (await markets.of_country(conn, body.country)).currency
        tried = await taxes.schemes_by_id(conn, body.try_ids) if body.try_ids else []
        tried_codes = {s.code for s in tried}

        async def schemes(seller: str, product: str):
            sale = taxes.Sale(country=body.country, seller=seller, product=product, origin_city=body.origin_city,
                              distance_km=Decimal(str(body.distance_km)) if body.distance_km is not None else None, at=at)
            base = [s for s in await taxes.schemes_for(conn, sale) if s.code not in tried_codes]
            return sale, taxes._ordered(base + [s for s in tried if taxes._applies(s, sale)])

        t_sale, t_schemes = await schemes("CARRIER", "TICKET")
        first_net, first_taxes = taxes.split_inclusive(body.fare, t_schemes, t_sale, first_line=True)
        other_net, other_taxes = taxes.split_inclusive(body.fare, t_schemes, t_sale, first_line=False)
        n = body.passengers
        by_code = {sc.code: sc for sc in t_schemes}
        ticket_net = first_net + other_net * (n - 1)
        ticket_taxes: dict[str, dict] = {}
        for t, k in [(x, 1) for x in first_taxes] + [(x, n - 1) for x in other_taxes]:
            if k == 0:
                continue
            o = ticket_taxes.setdefault(t.code, {**_tax_out(t, 0, by_code.get(t.code)), "base": 0, "amount": 0})
            o["base"] += t.base * k
            o["amount"] += t.amount * k
        fares_total = body.fare * n
        fee = 0 if no_funds else get_settings().platform_fee
        f_sale, f_schemes = await schemes("PLATFORM", "BOOKING_FEE")
        fee_net, fee_taxes = taxes.split_inclusive(fee, f_schemes, f_sale) if fee else (0, [])
        agency_cut = commission_for(fares_total, body.agency_commission_bp)
        pay = {"fee": 0, "absorbed": 0, "label": None, "borne_by": "PAYER"}
        if body.method and not no_funds:
            p = await conn.fetchrow("SELECT id, code, adapter, min_amount, max_amount FROM fin.payment_provider WHERE code = $1", body.method)
            if p is None:
                raise not_found("payment method")
            pay = await fees.fee_for(conn, dict(p), currency, fares_total + fee, None)
        c_tried = await commission.load(conn, "id = ANY($1::bigint[])", body.try_commission_ids) if body.try_commission_ids else []
        c_tried_codes = {c.code for c in c_tried}
        c_schemes = [c for c in await commission.in_force(conn, at) if c.code not in c_tried_codes] + c_tried
        c_schemes = [c for c in c_schemes if commission.applies(c, body.channel, None)]
        c_names = {r["id"]: r["name"] for r in await conn.fetch(
            "SELECT id, coalesce(name, code) AS name FROM pricing.commission_scheme WHERE id = ANY($1::bigint[])", [c.id for c in c_schemes])}
        authorities = {r["id"]: r["legal_name"] for r in await conn.fetch(
            "SELECT id, legal_name FROM iam.party WHERE id = ANY($1::bigint[])",
            [t["payable_to_party_id"] for t in ticket_taxes.values() if t["payable_to_party_id"]]
            + [t.payable_to_party_id for t in fee_taxes if t.payable_to_party_id])}
    tax_lines = list(ticket_taxes.values())
    fee_by_code = {sc.code: sc for sc in f_schemes}
    fee_tax_lines = [_tax_out(t, 1, fee_by_code.get(t.code)) for t in fee_taxes]
    for t in tax_lines + fee_tax_lines:
        t["payable_to"] = authorities.get(t.pop("payable_to_party_id"))
        t["tried"] = t["code"] in tried_codes
    total_tax = sum(t["amount"] for t in tax_lines) + sum(t["amount"] for t in fee_tax_lines)
    bucket = {"CARRIER": ticket_net - agency_cut, "AGENCY": agency_cut, "PLATFORM": fee_net - pay.get("absorbed", 0), "TAX": total_tax,
              "PAYMENT": pay["fee"] + pay.get("absorbed", 0), "REFERRER": 0}
    bases = {"FARE": fares_total, "NET": ticket_net, "FEE": fee}
    commission_lines, traveller_extra = [], 0
    for c in c_schemes:
        base = bases[c.base_type]
        amt = commission.amount(c, base)
        payer, receiver = commission.PAYER[c.funded_by], commission.RECEIVER[c.type]
        if payer == "TRAVELLER":
            traveller_extra += amt
        else:
            bucket[payer] -= amt
        bucket[receiver] += amt
        commission_lines.append({"code": c.code, "name": c_names.get(c.id, c.code), "type": c.type, "payer": payer, "receiver": receiver,
                                 "base_type": c.base_type, "base": base, "amount": amt, "tried": c.code in c_tried_codes})
    paid = fares_total + fee + pay["fee"] + traveller_extra
    shares = [{"who": k, "amount": v} for k, v in bucket.items()]
    return {
        "currency": currency, "passengers": n, "fare": body.fare, "fares_total": fares_total,
        "ticket_net": ticket_net, "ticket_taxes": tax_lines,
        "platform_fee": fee, "platform_fee_net": fee_net, "platform_fee_taxes": fee_tax_lines,
        "payment_fee": pay["fee"], "payment_fee_absorbed": pay.get("absorbed", 0), "payment_fee_label": pay.get("label"),
        "agency_commission": agency_cut, "total_paid": paid, "total_tax": total_tax,
        "shares": [s for s in shares if s["amount"]], "no_funds": no_funds,
        "tried": sorted(tried_codes | c_tried_codes),
        "commissions": commission_lines, "traveller_commission": traveller_extra,
    }

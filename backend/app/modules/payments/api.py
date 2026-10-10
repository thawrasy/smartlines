"""Payments API.

  Passengers   /api/payments/...          methods, wallet top-up by card or partner e-wallet, bank transfer, status, code
  Providers    /api/payments/notify/{code} signed server-to-server notifications (the only source of a card result)
  Test gateway /api/payments/test/{uid}   sandbox only: the hosted page of the built-in card simulator
  Finance      /api/admin/payments/...    providers, bank statement import and matching, refunds to the source
  Agencies     /api/agency/wallet-topups  cash at the counter credited to a passenger's wallet
"""
import json
import uuid
from datetime import datetime, timezone
from typing import Literal, Optional

from fastapi import APIRouter, Depends, File, Form, Query, Request, UploadFile
from pydantic import BaseModel, Field

from ... import db
from ...config import get_settings
from ...deps import Principal, context_for, public_base, require_portal, require_user
from ...errors import ApiError, forbidden, not_found
from . import adapters, approvals, fees, service

router = APIRouter(tags=["payments"])
passenger = require_portal("PASSENGER")
platform = require_portal("PLATFORM")
agency = require_portal("AGENCY")


def _need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden("missing permission: " + " | ".join(codes))


def _system(request: Request) -> db.Context:
    return db.Context(request_id=request.state.request_id, ip=request.state.client_ip, scope="SYSTEM")


# ------------------------------------------------------------------ passengers
@router.get("/api/payments/methods")
async def methods(request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"methods": await service.methods(conn, party_id=pr.party_id)}


@router.get("/api/payments/quote")
async def quote(request: Request, method: str = Query(pattern=r"^[A-Z_]{3,20}$"), amount: int = Query(gt=0, le=1_000_000_000),
                pr: Principal = Depends(passenger)):
    """What the payer will be asked for with this way of paying, the platform's fee included, before paying (decision 4)."""
    async with db.transaction(context_for(request, pr)) as conn:
        p = await service.provider(conn, method)
        if p["status"] != "ACTIVE":
            raise ApiError(409, "PAYMENT_METHOD_UNAVAILABLE", "this payment method is not available")
        currency = (await service.markets.of_party(conn, pr.party_id)).currency
        return await fees.quote(conn, p, currency, amount, pr.party_id)


class TopupIn(BaseModel):
    method: str = Field(pattern=r"^[A-Z_]{3,20}$")
    amount: int = Field(gt=0, le=1_000_000_000)           # minor units
    idempotency_key: str = Field(min_length=8, max_length=80)
    mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")


@router.post("/api/payments/topups", status_code=201)
async def topup(body: TopupIn, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    base = public_base(request)
    # no transaction here: the service records the payment, calls the provider with none open, then records its answer
    out = await service.start_topup(ctx, pr.party_id, pr.user_id, body.method, body.amount, body.idempotency_key, body.mobile,
                                    f"{base}/wallet?payment={{uid}}")
    request.state.audit = {"action": "payment.start", "object_type": "payment", "object_id": None}
    return out


class TransferIn(BaseModel):
    amount: int = Field(gt=0, le=1_000_000_000)
    idempotency_key: str = Field(min_length=8, max_length=80)


@router.post("/api/payments/bank-transfers", status_code=201)
async def bank_transfer(body: TransferIn, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await service.start_bank_transfer(conn, ctx, pr.party_id, body.amount, body.idempotency_key)


@router.get("/api/payments/mine")
async def mine(request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            rows = await conn.fetch(
                """SELECT p.uid, p.status, p.stage, p.amount, p.method, p.created_at, p.expires_at, p.failure_code, pv.code AS provider,
                          t.virtual_ref AS reference
                     FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id
                     LEFT JOIN fin.bank_transfer_topup t ON t.payment_id = p.id
                    WHERE p.payer_party_id = $1 AND p.purpose = 'TOPUP' ORDER BY p.id DESC LIMIT 20""", pr.party_id)
    return {"payments": [{**dict(r), "uid": str(r["uid"]), "created_at": r["created_at"].isoformat(),
                          "expires_at": r["expires_at"].isoformat() if r["expires_at"] else None} for r in rows]}


@router.get("/api/payments/{uid}")
async def status(uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await service.status_of(conn, ctx, pr.party_id, uid)


class CodeIn(BaseModel):
    code: str = Field(pattern=r"^[0-9]{4,8}$")


@router.post("/api/payments/{uid}/code")
async def code(uid: uuid.UUID, body: CodeIn, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    out = await service.confirm_code(ctx, pr.party_id, pr.user_id, uid, body.code)
    request.state.audit = {"action": "payment.confirm_code", "object_type": "payment", "object_id": None}
    err = out.get("error")
    if err:
        status = {"OTP_INVALID": 422, "OTP_TOO_MANY_ATTEMPTS": 429}.get(err, 409)
        raise ApiError(status, err, err.lower().replace("_", " "), **({"attempts_left": out["attempts_left"]} if "attempts_left" in out else {}))
    return out


@router.post("/api/payments/{uid}/cancel")
async def cancel(uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await service.cancel(conn, ctx, pr.party_id, uid)


# ------------------------------------------------------------------ provider notifications
@router.post("/api/payments/notify/{code}")
async def notify(code: str, request: Request):
    raw = await request.body()
    if len(raw) > 64_000:
        raise ApiError(413, "PAYLOAD_TOO_LARGE", "notification too large")
    ctx = _system(request)
    async with db.transaction(ctx) as conn:
        p = await service.provider(conn, code.upper())
        if p["adapter"] not in adapters.NOTIFYING:
            raise not_found("provider")
        valid = adapters.verify(adapters.secret_for(p), raw, request.headers.get(adapters.SIGNATURE_HEADER))
        try:
            notice = adapters.parse_notice(raw)
            payload = json.loads(raw)
        except (ApiError, ValueError):
            await service.record_rejected(conn, ctx, p, raw, request.state.client_ip)
            notice = None
        out = await service.apply_notice(conn, ctx, p, notice, payload, valid, request.state.client_ip) if notice else {"error": "BAD_NOTIFICATION"}
    # everything above is committed (including rejected notifications); refusals are answered after the commit
    if out.get("error") == "BAD_SIGNATURE":
        raise ApiError(401, "BAD_SIGNATURE", "notification signature invalid")
    if out.get("error") == "BAD_NOTIFICATION":
        raise ApiError(400, "BAD_NOTIFICATION", "malformed notification")
    return out


# ------------------------------------------------------------------ test gateway (sandbox only)
# The simulator stands for a provider's hosted page. Only the payer opens it, signed in (reviews of October 2026, M-12):
# a sandbox server holding real data cannot have a stranger who learns a payment's id confirm it.
async def _test_payment(conn, ctx, uid: uuid.UUID, pr: Principal):
    if not get_settings().sandbox:
        raise not_found("payment")
    async with db.system_scope(conn, ctx):
        row = await conn.fetchrow(
            """SELECT p.uid, p.amount, p.fee, p.currency, p.status, p.stage, p.provider_ref, p.purpose, pv.code, pv.name, pv.adapter,
                      b.booking_ref, p.payer_party_id, p.agency_company_id
                 FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id
                 LEFT JOIN sales.booking b ON b.id = p.booking_id WHERE p.uid = $1""", uid)
    if row is None or row["adapter"] not in adapters.HOSTED:
        raise not_found("payment")
    payer = row["payer_party_id"] is not None and row["payer_party_id"] == pr.party_id
    agency = row["agency_company_id"] is not None and row["agency_company_id"] == pr.company_id
    if not (payer or agency):
        raise not_found("payment")
    return row


@router.get("/api/payments/test/{uid}")
async def test_page(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_user)):
    ctx = _system(request)
    async with db.transaction(ctx) as conn:
        row = await _test_payment(conn, ctx, uid, pr)
    return {"uid": str(row["uid"]), "amount": row["amount"], "fee": row["fee"], "total": row["amount"] + row["fee"],
            "currency": row["currency"], "status": row["status"], "provider": row["name"],
            "code": row["code"], "kind": row["adapter"], "booking_ref": row["booking_ref"]}


class TestDecision(BaseModel):
    approve: bool


@router.post("/api/payments/test/{uid}")
async def test_decide(uid: uuid.UUID, body: TestDecision, request: Request, pr: Principal = Depends(require_user)):
    """The simulator behaves like a real gateway: it signs a notification and delivers it to the notification endpoint."""
    ctx = _system(request)
    async with db.transaction(ctx) as conn:
        row = await _test_payment(conn, ctx, uid, pr)
        p = await service.provider(conn, row["code"])
    raw, sig = adapters.simulator_notice(p, dict(row), body.approve)
    if not adapters.verify(adapters.secret_for(p), raw, sig):
        raise ApiError(500, "SIMULATOR_SIGNATURE", "simulator could not sign")
    async with db.transaction(ctx) as conn:
        out = await service.apply_notice(conn, ctx, p, adapters.parse_notice(raw), json.loads(raw), True, request.state.client_ip)
    back = f"/booking/{row['booking_ref']}?payment={uid}" if row["booking_ref"] else f"/wallet?payment={uid}"
    return {**out, "return_to": back}


# ------------------------------------------------------------------ finance
@router.get("/api/admin/payments/providers")
async def providers(request: Request, pr: Principal = Depends(platform)):
    _need(pr, "payment.fee_policy", "ledger.reconcile")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch("SELECT * FROM fin.payment_provider ORDER BY sort_order")
    out = []
    for r in rows:
        p = service.provider_dict(r)
        secret_env = p["config"].get("secret_env")
        out.append({"code": p["code"], "name": p["name"], "kind": p["kind"], "adapter": p["adapter"], "status": p["status"],
                    "min_amount": p["min_amount"], "max_amount": p["max_amount"], "fee_pct": float(p["fee_policy"].get("pct", 0)),
                    "fee_borne_by": p["fee_policy"].get("borne_by", "PLATFORM"),
                    "config": {k: v for k, v in p["config"].items() if not k.endswith("_env")},
                    "secret_configured": bool(secret_env and __import__("os").environ.get(secret_env)),
                    "purposes": list(p["purposes"]),
                    "simulated": adapters.simulated(p) if p["adapter"] in adapters.NOTIFYING else False})
    return {"providers": out, "sandbox": get_settings().sandbox}


EDITABLE_CONFIG = {"base_url", "merchant_id", "merchant_code", "bank_name", "account_name", "iban", "valid_days"}


class ProviderIn(BaseModel):
    status: Literal["ACTIVE", "INACTIVE"]
    min_amount: int = Field(gt=0)
    max_amount: int = Field(gt=0)
    fee_pct: float = Field(ge=0, le=10)
    fee_borne_by: Literal["PLATFORM", "PAYER"] = "PAYER"     # decision 4: by default the customer pays the fee
    config: dict = Field(default_factory=dict)


@router.put("/api/admin/payments/providers/{code}")
async def update_provider(code: str, body: ProviderIn, request: Request, pr: Principal = Depends(platform)):
    _need(pr, "payment.fee_policy")
    bad = set(body.config) - EDITABLE_CONFIG
    if bad:
        raise ApiError(422, "CONFIG_NOT_EDITABLE", "these settings cannot be changed here: " + ", ".join(sorted(bad)))
    if body.config.get("base_url") and not str(body.config["base_url"]).startswith("https://"):
        raise ApiError(422, "CONFIG_INSECURE_URL", "the provider address must use https")
    if body.config.get("base_url"):
        # the same public-address rules as partner webhooks (SSRF, review stage B); the egress proxy checks again
        from ..integration.webhooks import check_url
        try:
            check_url(str(body.config["base_url"]))
        except ApiError as exc:
            raise ApiError(422, "CONFIG_URL_NOT_PUBLIC", "the provider address must be a public https address") from exc
    if body.max_amount < body.min_amount:
        raise ApiError(422, "PAYMENT_AMOUNT_OUT_OF_RANGE", "the maximum is below the minimum")
    async with db.transaction(context_for(request, pr)) as conn:
        p = await service.provider(conn, code.upper())
        if p["adapter"] == "SANDBOX" and body.status == "ACTIVE" and not get_settings().sandbox:
            raise ApiError(409, "SANDBOX_ONLY", "the test gateway cannot be switched on in production")
        cfg = {**p["config"], **{k: v for k, v in body.config.items() if k in EDITABLE_CONFIG}}
        if p["adapter"] == "BANK_TRANSFER" and body.status == "ACTIVE" and not (cfg.get("iban") and cfg.get("bank_name")):
            raise ApiError(422, "BANK_DETAILS_REQUIRED", "the bank name and IBAN are required to accept transfers")
        await conn.execute(
            """UPDATE fin.payment_provider SET status = $2, min_amount = $3, max_amount = $4, fee_policy = $5::jsonb, config = $6::jsonb,
                      updated_by = $7, updated_at = now() WHERE id = $1""",
            p["id"], body.status, body.min_amount, body.max_amount, json.dumps({"pct": body.fee_pct, "borne_by": body.fee_borne_by}),
            json.dumps(cfg), pr.user_id)
        await fees.provider_default(conn, p, body.fee_pct, body.fee_borne_by, pr.user_id)
    request.state.audit = {"action": "payment.provider.update", "object_type": "payment_provider", "object_id": p["id"]}
    return {"ok": True}


@router.post("/api/admin/payments/statements", status_code=201)
async def import_statement(request: Request, pr: Principal = Depends(platform), file: UploadFile = File(...),
                           account_label: str = Form(default="Main account", min_length=2, max_length=80),
                           decimal_mark: Literal[".", ","] = Form(default=".")):
    _need(pr, "ledger.reconcile")
    data = await file.read(2_000_001)
    if len(data) > 2_000_000:
        raise ApiError(413, "FILE_TOO_LARGE", "statement files are limited to 2 MB")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await service.import_statement(conn, ctx, pr.user_id, account_label, data, decimal_mark)
    request.state.audit = {"action": "payment.statement.import", "object_type": "bank_statement_import", "object_id": None}
    return out


@router.get("/api/admin/payments/statement-lines")
async def statement_lines(request: Request, status: str = Query(default="UNMATCHED", pattern=r"^(UNMATCHED|PROPOSED|MATCHED|IGNORED)$"),
                          pr: Principal = Depends(platform)):
    _need(pr, "ledger.reconcile")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT l.id, l.value_date, l.amount, l.currency, l.reference, l.payer, l.bank_ref, l.status, l.note, t.virtual_ref,
                      i.account_label, i.created_at AS imported_at
                 FROM fin.bank_statement_line l JOIN fin.bank_statement_import i ON i.id = l.import_id
                 LEFT JOIN fin.bank_transfer_topup t ON t.id = l.topup_id
                WHERE l.status = $1 ORDER BY l.value_date DESC, l.id DESC LIMIT 300""", status)
        awaiting = await conn.fetch(
            """SELECT t.virtual_ref, t.amount, t.created_at, t.expires_at, p.legal_name AS payer
                 FROM fin.bank_transfer_topup t JOIN fin.wallet w ON w.id = t.wallet_id LEFT JOIN iam.party p ON p.id = w.owner_party_id
                WHERE t.status = 'AWAITING' ORDER BY t.created_at DESC LIMIT 300""")
    return {"lines": [{**dict(r), "value_date": r["value_date"].isoformat(), "imported_at": r["imported_at"].isoformat()} for r in rows],
            "awaiting": [{**dict(r), "created_at": r["created_at"].isoformat(),
                          "expires_at": r["expires_at"].isoformat() if r["expires_at"] else None} for r in awaiting]}


class MatchIn(BaseModel):
    reference: str = Field(min_length=5, max_length=40)
    credit_received: bool = False


@router.post("/api/admin/payments/statement-lines/{line_id}/match")
async def match(line_id: int, body: MatchIn, request: Request, pr: Principal = Depends(platform)):
    _need(pr, "ledger.reconcile")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await service.match_line(conn, ctx, pr.user_id, line_id, body.reference, body.credit_received)
    request.state.audit = {"action": "payment.statement.match", "object_type": "bank_statement_line", "object_id": line_id}
    return out


class IgnoreIn(BaseModel):
    note: str = Field(min_length=5, max_length=300)


@router.post("/api/admin/payments/statement-lines/{line_id}/ignore")
async def ignore(line_id: int, body: IgnoreIn, request: Request, pr: Principal = Depends(platform)):
    _need(pr, "ledger.reconcile")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await service.ignore_line(conn, ctx, pr.user_id, line_id, body.note)
    request.state.audit = {"action": "payment.statement.ignore", "object_type": "bank_statement_line", "object_id": line_id}
    return out


class RefundIn(BaseModel):
    amount: int = Field(gt=0)
    reason: str = Field(min_length=5, max_length=300)
    idempotency_key: str = Field(min_length=8, max_length=80)


@router.post("/api/admin/payments/{uid}/refund")
async def refund(uid: uuid.UUID, body: RefundIn, request: Request, pr: Principal = Depends(platform)):
    _need(pr, "compensation.pay")
    ctx = context_for(request, pr)
    out = await service.request_refund(ctx, pr.user_id, uid, body.amount, body.reason, body.idempotency_key)
    request.state.audit = {"action": "payment.refund", "object_type": "payment", "object_id": None}
    return out


@router.post("/api/admin/payments/refunds/{uid}/resend")
async def resend_refund(uid: uuid.UUID, request: Request, pr: Principal = Depends(platform)):
    """Asks the provider again, now, about a refund whose outcome is unknown (same reference; the worker also does it)."""
    _need(pr, "compensation.pay")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        rid = await conn.fetchval("SELECT id FROM fin.payment_refund WHERE uid = $1 AND stage IN ('SENDING', 'UNKNOWN')", uid)
    if rid is None:
        raise ApiError(409, "REFUND_NOT_WAITING", "this refund is not waiting for its provider")
    out = await service.send_refund(ctx, rid, pr.user_id)
    request.state.audit = {"action": "payment.refund.resend", "object_type": "payment_refund", "object_id": rid}
    return out


# ------------------------------------------------------------------ agencies
class AgencyTopupIn(BaseModel):
    mobile: str = Field(pattern=r"^\+?[0-9]{8,15}$")
    amount: int = Field(gt=0, le=1_000_000_000)
    idempotency_key: str = Field(min_length=8, max_length=80)


@router.post("/api/agency/wallet-topups", status_code=201)
async def agency_topup(body: AgencyTopupIn, request: Request, pr: Principal = Depends(agency)):
    _need(pr, "booking.on_behalf", "sale.cash")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await service.agency_topup(conn, ctx, pr.company_id, pr.user_id, body.mobile, body.amount, body.idempotency_key)
    request.state.audit = {"action": "agency.wallet_topup", "object_type": "payment", "object_id": None}
    return out


@router.get("/api/agency/wallet-topups")
async def agency_topups(request: Request, pr: Principal = Depends(agency)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            rows = await conn.fetch(
                """SELECT uid, amount, provider_ref AS receipt, payer_mobile_mask AS mobile, created_at FROM fin.payment
                    WHERE agency_company_id = $1 AND method = 'CASH' ORDER BY id DESC LIMIT 50""", pr.company_id)
    return {"topups": [{**dict(r), "uid": str(r["uid"]), "created_at": r["created_at"].isoformat()} for r in rows]}


@router.get("/api/admin/payments/recent")
async def recent(request: Request, method: Optional[str] = Query(default=None, pattern=r"^(CARD|E_WALLET|BANK|CASH|INSTALLMENT|FINANCING)$"),
                 pr: Principal = Depends(platform)):
    _need(pr, "ledger.reconcile", "compensation.pay")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT p.uid, p.created_at, p.method, p.purpose, p.status, p.stage, p.amount, p.refunded_amount, p.fee, p.provider_ref,
                      p.card_last4, p.payer_mobile_mask, p.failure_code, pv.code AS provider, pa.legal_name AS payer, b.booking_ref
                 FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id LEFT JOIN iam.party pa ON pa.id = p.payer_party_id
                 LEFT JOIN sales.booking b ON b.id = p.booking_id
                WHERE p.purpose IN ('TOPUP','BOOKING') AND ($1::text IS NULL OR p.method = $1) ORDER BY p.id DESC LIMIT 100""", method)
    return {"payments": [{**dict(r), "uid": str(r["uid"]), "created_at": r["created_at"].isoformat()} for r in rows]}


# ------------------------------------------------------------------ fee rules (decision 4)
class FeeRuleIn(BaseModel):
    label: str = Field(min_length=3, max_length=120)
    provider: Optional[str] = Field(default=None, pattern=r"^[A-Z_]{3,20}$")      # None: every way of paying
    currency: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")           # None: every currency (percentage only)
    customer_uid: Optional[uuid.UUID] = None                                       # one passenger or company
    kind: Literal["PERCENT", "FIXED", "PERCENT_PLUS_FIXED", "NONE"]
    pct: float = Field(default=0, ge=0, le=20)
    fixed_amount: int = Field(default=0, ge=0)
    min_fee: Optional[int] = Field(default=None, ge=0)
    max_fee: Optional[int] = Field(default=None, ge=0)
    round_to: int = Field(default=1, ge=1, le=1_000_000)
    rounding: Literal["HALF_UP", "UP", "DOWN"] = "HALF_UP"
    borne_by: Literal["PAYER", "PLATFORM"] = "PAYER"
    valid_from: Optional[datetime] = None
    valid_to: Optional[datetime] = None
    status: Literal["ACTIVE", "INACTIVE"] = "ACTIVE"


@router.get("/api/admin/payments/fee-rules")
async def fee_rules(request: Request, pr: Principal = Depends(platform)):
    _need(pr, "payment.fee_policy", "ledger.reconcile")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(fees.LIST_SQL + " ORDER BY f.status, f.currency NULLS FIRST, f.provider_id NULLS FIRST, f.valid_from DESC")
    return {"rules": [fees.rule_out(r) for r in rows]}


async def _rule_values(conn, body: FeeRuleIn) -> list:
    provider_id = (await service.provider(conn, body.provider))["id"] if body.provider else None
    party_id = None
    if body.customer_uid:
        party_id = await conn.fetchval("SELECT id FROM iam.party WHERE uid = $1", body.customer_uid)
        if party_id is None:
            raise not_found("customer")
    return [body.label.strip(), provider_id, body.currency, party_id, body.kind, round(body.pct, 3), body.fixed_amount, body.min_fee,
            body.max_fee, body.round_to, body.rounding, body.borne_by, body.valid_from or datetime.now(timezone.utc), body.valid_to,
            body.status]


@router.post("/api/admin/payments/fee-rules", status_code=201)
async def create_fee_rule(body: FeeRuleIn, request: Request, pr: Principal = Depends(platform)):
    _need(pr, "payment.fee_policy")
    async with db.transaction(context_for(request, pr)) as conn:
        values = await _rule_values(conn, body)
        row = await conn.fetchrow(
            f"""INSERT INTO fin.fee_rule ({", ".join(fees.RULE_COLUMNS)}, created_by, updated_by)
                VALUES ({", ".join(f"${i}" for i in range(1, len(values) + 1))}, ${len(values) + 1}, ${len(values) + 1})
                RETURNING id, uid""", *values, pr.user_id)
    request.state.audit = {"action": "payment.fee_rule.create", "object_type": "fee_rule", "object_id": row["id"]}
    return {"uid": str(row["uid"])}


@router.put("/api/admin/payments/fee-rules/{uid}")
async def update_fee_rule(uid: uuid.UUID, body: FeeRuleIn, request: Request, pr: Principal = Depends(platform)):
    _need(pr, "payment.fee_policy")
    async with db.transaction(context_for(request, pr)) as conn:
        values = await _rule_values(conn, body)
        sets = ", ".join(f"{c} = ${i + 2}" for i, c in enumerate(fees.RULE_COLUMNS))
        rid = await conn.fetchval(f"UPDATE fin.fee_rule SET {sets}, updated_by = ${len(values) + 2}, updated_at = now() WHERE uid = $1 RETURNING id",
                                  uid, *values, pr.user_id)
        if rid is None:
            raise not_found("fee rule")
    request.state.audit = {"action": "payment.fee_rule.update", "object_type": "fee_rule", "object_id": rid}
    return {"ok": True}


# ------------------------------------------------------------------ the approval matrix (decision 5)
@router.get("/api/admin/approvals")
async def approval_requests(request: Request, status: str = Query(default="PENDING", pattern=r"^(PENDING|APPROVED|REJECTED|CANCELLED)$"),
                            pr: Principal = Depends(platform)):
    _need(pr, "ledger.reconcile", "compensation.pay", "approval.policy")
    async with db.transaction(context_for(request, pr)) as conn:
        return {"requests": await approvals.requests(conn, pr.user_id, pr.permissions, status)}


class DecisionIn(BaseModel):
    decision: Literal["APPROVE", "REJECT"]
    note: Optional[str] = Field(default=None, max_length=300)


@router.post("/api/admin/approvals/{uid}/decision")
async def approval_decision(uid: uuid.UUID, body: DecisionIn, request: Request, pr: Principal = Depends(platform)):
    """One level's decision; the database checks the level, the permission, the named people and the four eyes."""
    out = await service.decide_approval(context_for(request, pr), pr.user_id, uid, body.decision == "APPROVE", body.note)
    request.state.audit = {"action": f"approval.{body.decision.lower()}", "object_type": "approval_request", "object_id": None,
                           "reason": body.note}
    return out


class CancelIn(BaseModel):
    note: str = Field(min_length=5, max_length=300)


@router.post("/api/admin/approvals/{uid}/cancel")
async def approval_cancel(uid: uuid.UUID, body: CancelIn, request: Request, pr: Principal = Depends(platform)):
    _need(pr, "approval.policy")
    out = await service.cancel_approval(context_for(request, pr), pr.user_id, uid, body.note)
    request.state.audit = {"action": "approval.cancel", "object_type": "approval_request", "object_id": None, "reason": body.note}
    return out


@router.get("/api/admin/approvals/policies")
async def approval_policies(request: Request, pr: Principal = Depends(platform)):
    _need(pr, "approval.policy", "ledger.reconcile", "compensation.pay")
    async with db.transaction(context_for(request, pr)) as conn:
        return {"policies": await approvals.policies(conn), "can_change": "approval.policy" in pr.permissions}


class LevelIn(BaseModel):
    name: str = Field(min_length=2, max_length=80)
    permission: str = Field(pattern=r"^[a-z_]+\.[a-z_]+$")
    min_amount: int = Field(default=0, ge=0)
    members: list[str] = Field(default_factory=list, max_length=20)


class PolicyIn(BaseModel):
    levels: list[LevelIn] = Field(max_length=approvals.MAX_LEVELS)


@router.put("/api/admin/approvals/policies/{action}")
async def set_approval_policy(action: str, body: PolicyIn, request: Request, pr: Principal = Depends(platform)):
    _need(pr, "approval.policy")
    async with db.transaction(context_for(request, pr)) as conn:
        await approvals.set_policy(conn, pr.user_id, action.upper(), [lv.model_dump() for lv in body.levels])
    request.state.audit = {"action": "approval.policy", "object_type": "approval_policy", "object_id": None,
                           "reason": f"{action.upper()}: {len(body.levels)} level(s)"}
    return {"ok": True}

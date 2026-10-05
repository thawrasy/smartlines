"""Payments API.

  Passengers   /api/payments/...          methods, wallet top-up by card or partner e-wallet, bank transfer, status, code
  Providers    /api/payments/notify/{code} signed server-to-server notifications (the only source of a card result)
  Test gateway /api/payments/test/{uid}   sandbox only: the hosted page of the built-in card simulator
  Finance      /api/admin/payments/...    providers, bank statement import and matching, refunds to the source
  Agencies     /api/agency/wallet-topups  cash at the counter credited to a passenger's wallet
"""
import json
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, File, Form, Query, Request, UploadFile
from pydantic import BaseModel, Field

from ... import db
from ...config import get_settings
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden, not_found
from . import adapters, service

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
        return {"methods": await service.methods(conn)}


class TopupIn(BaseModel):
    method: str = Field(pattern=r"^[A-Z_]{3,20}$")
    amount: int = Field(gt=0, le=1_000_000_000)           # minor units
    idempotency_key: str = Field(min_length=8, max_length=80)
    mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")


@router.post("/api/payments/topups", status_code=201)
async def topup(body: TopupIn, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    base = str(request.base_url).rstrip("/")
    async with db.transaction(ctx) as conn:
        out = await service.start_topup(conn, ctx, pr.party_id, pr.user_id, body.method, body.amount, body.idempotency_key, body.mobile,
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
    async with db.transaction(ctx) as conn:
        out = await service.confirm_code(conn, ctx, pr.party_id, pr.user_id, uid, body.code)
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
        if p["adapter"] not in ("HOSTED_CARD", "PARTNER_WALLET"):
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
async def _test_payment(conn, ctx, uid: uuid.UUID):
    if not get_settings().sandbox:
        raise not_found("payment")
    async with db.system_scope(conn, ctx):
        row = await conn.fetchrow(
            """SELECT p.uid, p.amount, p.currency, p.status, p.stage, p.provider_ref, pv.code, pv.name, pv.adapter
                 FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id WHERE p.uid = $1""", uid)
    if row is None or row["adapter"] != "HOSTED_CARD":
        raise not_found("payment")
    return row


@router.get("/api/payments/test/{uid}")
async def test_page(uid: uuid.UUID, request: Request):
    ctx = _system(request)
    async with db.transaction(ctx) as conn:
        row = await _test_payment(conn, ctx, uid)
    return {"uid": str(row["uid"]), "amount": row["amount"], "currency": row["currency"], "status": row["status"], "provider": row["name"], "code": row["code"]}


class TestDecision(BaseModel):
    approve: bool


@router.post("/api/payments/test/{uid}")
async def test_decide(uid: uuid.UUID, body: TestDecision, request: Request):
    """The simulator behaves like a real gateway: it signs a notification and delivers it to the notification endpoint."""
    ctx = _system(request)
    async with db.transaction(ctx) as conn:
        row = await _test_payment(conn, ctx, uid)
        p = await service.provider(conn, row["code"])
    raw, sig = adapters.simulator_notice(p, dict(row), body.approve)
    if not adapters.verify(adapters.secret_for(p), raw, sig):
        raise ApiError(500, "SIMULATOR_SIGNATURE", "simulator could not sign")
    async with db.transaction(ctx) as conn:
        out = await service.apply_notice(conn, ctx, p, adapters.parse_notice(raw), json.loads(raw), True, request.state.client_ip)
    return {**out, "return_to": f"/wallet?payment={uid}"}


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
                    "simulated": adapters.simulated(p) if p["adapter"] in ("HOSTED_CARD", "PARTNER_WALLET") else False})
    return {"providers": out, "sandbox": get_settings().sandbox}


EDITABLE_CONFIG = {"base_url", "merchant_id", "merchant_code", "bank_name", "account_name", "iban", "valid_days"}


class ProviderIn(BaseModel):
    status: Literal["ACTIVE", "INACTIVE"]
    min_amount: int = Field(gt=0)
    max_amount: int = Field(gt=0)
    fee_pct: float = Field(ge=0, le=10)
    fee_borne_by: Literal["PLATFORM", "PAYER"] = "PLATFORM"
    config: dict = Field(default_factory=dict)


@router.put("/api/admin/payments/providers/{code}")
async def update_provider(code: str, body: ProviderIn, request: Request, pr: Principal = Depends(platform)):
    _need(pr, "payment.fee_policy")
    bad = set(body.config) - EDITABLE_CONFIG
    if bad:
        raise ApiError(422, "CONFIG_NOT_EDITABLE", "these settings cannot be changed here: " + ", ".join(sorted(bad)))
    if body.config.get("base_url") and not str(body.config["base_url"]).startswith("https://"):
        raise ApiError(422, "CONFIG_INSECURE_URL", "the provider address must use https")
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
    request.state.audit = {"action": "payment.provider.update", "object_type": "payment_provider", "object_id": p["id"]}
    return {"ok": True}


@router.post("/api/admin/payments/statements", status_code=201)
async def import_statement(request: Request, pr: Principal = Depends(platform), file: UploadFile = File(...),
                           account_label: str = Form(default="Main account", min_length=2, max_length=80)):
    _need(pr, "ledger.reconcile")
    data = await file.read(2_000_001)
    if len(data) > 2_000_000:
        raise ApiError(413, "FILE_TOO_LARGE", "statement files are limited to 2 MB")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await service.import_statement(conn, ctx, pr.user_id, account_label, data)
    request.state.audit = {"action": "payment.statement.import", "object_type": "bank_statement_import", "object_id": None}
    return out


@router.get("/api/admin/payments/statement-lines")
async def statement_lines(request: Request, status: str = Query(default="UNMATCHED", pattern=r"^(UNMATCHED|MATCHED|IGNORED)$"),
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
    async with db.transaction(ctx) as conn:
        out = await service.refund(conn, ctx, pr.user_id, uid, body.amount, body.reason, body.idempotency_key)
    request.state.audit = {"action": "payment.refund", "object_type": "payment", "object_id": None}
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
async def recent(request: Request, method: Optional[str] = Query(default=None, pattern=r"^(CARD|E_WALLET|BANK|CASH)$"),
                 pr: Principal = Depends(platform)):
    _need(pr, "ledger.reconcile", "compensation.pay")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT p.uid, p.created_at, p.method, p.status, p.stage, p.amount, p.refunded_amount, p.fee, p.provider_ref, p.card_last4,
                      p.payer_mobile_mask, p.failure_code, pv.code AS provider, pa.legal_name AS payer
                 FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id LEFT JOIN iam.party pa ON pa.id = p.payer_party_id
                WHERE p.purpose = 'TOPUP' AND ($1::text IS NULL OR p.method = $1) ORDER BY p.id DESC LIMIT 100""", method)
    return {"payments": [{**dict(r), "uid": str(r["uid"]), "created_at": r["created_at"].isoformat()} for r in rows]}

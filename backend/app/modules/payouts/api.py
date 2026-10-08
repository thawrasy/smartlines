"""Payout API. /api/finance for carrier and agency owners, /api/admin/finance for platform finance."""
import uuid
from datetime import date
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from . import service

company = APIRouter(prefix="/api/finance", tags=["payouts"])
platform = APIRouter(prefix="/api/admin/finance", tags=["payouts"])
owner = require_portal("OPERATOR", "AGENCY")
staff = require_portal("PLATFORM")


class BankAccountIn(BaseModel):
    bank_name: str = Field(min_length=2, max_length=120)
    holder_name: str = Field(min_length=3, max_length=160)
    iban: str = Field(min_length=15, max_length=42, pattern=r"^[A-Za-z0-9 \-]+$")


class WithdrawalIn(BaseModel):
    bank_account_uid: uuid.UUID
    amount: int = Field(gt=0, le=100_000_000_000)
    idempotency_key: str = Field(min_length=8, max_length=80)


class RejectIn(BaseModel):
    reason: str = Field(min_length=3, max_length=300)


class PaidIn(BaseModel):
    bank_ref: str = Field(min_length=3, max_length=60, pattern=r"^[0-9A-Za-z\-/]+$")


class SettlementRunIn(BaseModel):
    company_uid: uuid.UUID
    period_from: date
    period_to: date


# ------------------------------------------------------------------ company
@company.get("/balance")
async def balance(request: Request, pr: Principal = Depends(owner)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.balance(conn, pr)


@company.get("/bank-accounts")
async def bank_accounts(request: Request, pr: Principal = Depends(owner)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"accounts": await service.my_bank_accounts(conn, pr)}


@company.post("/bank-accounts", status_code=201)
async def add_bank_account(body: BankAccountIn, request: Request, pr: Principal = Depends(owner)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        account_id, uid = await service.add_bank_account(conn, ctx, pr, body.bank_name, body.holder_name, body.iban)
    request.state.audit = {"action": "bank_account.create", "object_type": "bank_account", "object_id": account_id}
    return {"uid": uid}


@company.get("/withdrawals")
async def withdrawals(request: Request, pr: Principal = Depends(owner)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"withdrawals": await service.my_withdrawals(conn, pr)}


@company.post("/withdrawals", status_code=201)
async def request_withdrawal(body: WithdrawalIn, request: Request, pr: Principal = Depends(owner)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await service.request_withdrawal(conn, pr, body.bank_account_uid, body.amount, body.idempotency_key, ctx)
    if "id" in out:
        request.state.audit = {"action": "withdrawal.request", "object_type": "withdrawal", "object_id": out.pop("id")}
    return out


@company.get("/settlements")
async def settlements(request: Request, pr: Principal = Depends(owner)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"settlements": await service.my_settlements(conn, pr)}


@company.get("/settlements/{batch_uid}")
async def settlement(batch_uid: uuid.UUID, request: Request, pr: Principal = Depends(owner)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.settlement_detail(conn, pr, batch_uid)


# ------------------------------------------------------------------ platform finance
@platform.get("/bank-accounts")
async def pending_accounts(request: Request, pr: Principal = Depends(staff)):
    service.finance(pr, "withdrawal.approve", "payout.run")
    async with db.transaction(context_for(request, pr)) as conn:
        return {"accounts": await service.pending_accounts(conn)}


@platform.post("/bank-accounts/{account_uid}/verify")
async def verify(account_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        account_id = await service.verify_account(conn, pr, account_uid)
    request.state.audit = {"action": "bank_account.verify", "object_type": "bank_account", "object_id": account_id}
    return {"ok": True}


@platform.get("/withdrawals")
async def all_withdrawals(request: Request, pr: Principal = Depends(staff),
                          status: Optional[Literal["REQUESTED", "APPROVED", "PAID", "REJECTED", "FAILED"]] = Query(default=None)):
    service.finance(pr, "withdrawal.approve", "payout.run")
    async with db.transaction(context_for(request, pr)) as conn:
        return {"withdrawals": await service.all_withdrawals(conn, status)}


@platform.post("/withdrawals/{withdrawal_uid}/approve")
async def approve(withdrawal_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.approve(conn, pr, withdrawal_uid)
    request.state.audit = {"action": "withdrawal.approve", "object_type": "withdrawal", "object_id": out.pop("id")}
    return out


@platform.post("/withdrawals/{withdrawal_uid}/reject")
async def reject(withdrawal_uid: uuid.UUID, body: RejectIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        wid = await service.reject(conn, pr, withdrawal_uid, body.reason)
    request.state.audit = {"action": "withdrawal.reject", "object_type": "withdrawal", "object_id": wid, "reason": body.reason}
    return {"ok": True}


@platform.get("/withdrawals/{withdrawal_uid}/transfer")
async def transfer_details(withdrawal_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await service.reveal_iban(conn, ctx, pr, withdrawal_uid)


@platform.post("/withdrawals/{withdrawal_uid}/paid")
async def paid(withdrawal_uid: uuid.UUID, body: PaidIn, request: Request, pr: Principal = Depends(staff)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        wid = await service.mark_paid(conn, ctx, pr, withdrawal_uid, body.bank_ref)
    request.state.audit = {"action": "withdrawal.paid", "object_type": "withdrawal", "object_id": wid, "reason": body.bank_ref}
    return {"ok": True}


@platform.get("/settlements")
async def all_settlements(request: Request, pr: Principal = Depends(staff)):
    service.finance(pr, "payout.run", "ledger.reconcile")
    async with db.transaction(context_for(request, pr)) as conn:
        return {"settlements": await service.all_settlements(conn)}


@platform.post("/settlements", status_code=201)
async def run_settlement(body: SettlementRunIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        batch_id, uid = await service.run_settlement(conn, pr, body.company_uid, body.period_from, body.period_to)
    request.state.audit = {"action": "settlement.draft", "object_type": "settlement", "object_id": batch_id}
    return {"uid": uid}


@platform.get("/settlements/{batch_uid}")
async def settlement_detail(batch_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    service.finance(pr, "payout.run", "ledger.reconcile")
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.settlement_detail(conn, pr, batch_uid)


@platform.post("/settlements/{batch_uid}/approve")
async def approve_settlement(batch_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        batch_id = await service.approve_settlement(conn, pr, batch_uid)
    request.state.audit = {"action": "settlement.approve", "object_type": "settlement", "object_id": batch_id}
    return {"ok": True}

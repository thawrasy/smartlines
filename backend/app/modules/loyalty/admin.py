"""Loyalty partners in the platform portal (migration 1107).

    GET  /api/admin/loyalty/partners                      the partners, their programme currency and what is owed to them
    GET  /api/admin/loyalty/settlements                   the latest statements, newest first
    POST /api/admin/loyalty/vouchers/accept               honour a voucher for a partner that has no API client
    POST /api/admin/loyalty/settlements                   draw up a partner's statement of honoured vouchers for a period
    POST /api/admin/loyalty/settlements/{uid}/pay         record the bank transfer of an approved statement (a third person)

Agreements (written, then activated by another person), statements (approved by another person) and the partners
themselves are kept through the generic screens: loyalty-agreement, loyalty-settlement, loyalty-partner.
"""
from __future__ import annotations

import uuid
from datetime import date

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_permission
from ...errors import ApiError, not_found
from ...modular import features
from ...util import rows
from . import partners

router = APIRouter(prefix="/api/admin/loyalty", tags=["admin"], dependencies=[features.require_module("loyalty_partners")])


@router.get("/partners")
async def list_partners(request: Request, pr: Principal = Depends(require_permission("loyalty.manage", "payout.run"))):
    """What a statement is drawn up from: each partner, its active agreement and the honoured vouchers not yet on a statement."""
    async with db.transaction(context_for(request, pr)) as conn:
        rs = await conn.fetch(
            """SELECT lp.id, p.legal_name AS name, lp.partner_type, lp.status, lp.settlement_cycle, g.currency,
                      lp.api_client_id IS NOT NULL AS has_api,
                      (SELECT a.uid FROM pricing.loyalty_agreement a WHERE a.loyalty_partner_id = lp.id AND a.status = 'ACTIVE' LIMIT 1) AS agreement,
                      (SELECT count(*) FROM pricing.partner_redemption r WHERE r.loyalty_partner_id = lp.id AND r.agreement_id IS NOT NULL
                          AND NOT EXISTS (SELECT 1 FROM pricing.loyalty_settlement_line l JOIN pricing.loyalty_settlement s ON s.id = l.settlement_id
                                           WHERE l.redemption_id = r.id AND s.status <> 'CANCELLED')) AS unsettled,
                      (SELECT coalesce(sum(r.payable), 0) FROM pricing.partner_redemption r WHERE r.loyalty_partner_id = lp.id AND r.agreement_id IS NOT NULL
                          AND NOT EXISTS (SELECT 1 FROM pricing.loyalty_settlement_line l JOIN pricing.loyalty_settlement s ON s.id = l.settlement_id
                                           WHERE l.redemption_id = r.id AND s.status <> 'CANCELLED')) AS unsettled_payable
                 FROM pricing.loyalty_partner lp JOIN iam.party p ON p.id = lp.party_id JOIN pricing.loyalty_program g ON g.id = lp.program_id
                ORDER BY p.legal_name""")
    return {"partners": rows(rs)}


@router.get("/settlements")
async def list_settlements(request: Request, pr: Principal = Depends(require_permission("loyalty.manage", "payout.run"))):
    async with db.transaction(context_for(request, pr)) as conn:
        rs = await conn.fetch(
            """SELECT s.uid, s.loyalty_partner_id AS partner_id, p.legal_name AS partner, s.currency, lower(s.period) AS date_from,
                      upper(s.period) - 1 AS date_to, s.redemptions, s.value, s.payable, s.status, s.created_at, s.approved_at,
                      s.paid_at, s.bank_ref
                 FROM pricing.loyalty_settlement s JOIN pricing.loyalty_partner lp ON lp.id = s.loyalty_partner_id
                 JOIN iam.party p ON p.id = lp.party_id ORDER BY s.created_at DESC LIMIT 200""")
    return {"settlements": rows(rs)}


class AcceptIn(BaseModel):
    partner_id: int = Field(gt=0)
    code: str = Field(min_length=10, max_length=40)
    reference: str | None = Field(default=None, max_length=80)


@router.post("/vouchers/accept", status_code=201)
async def accept_for_partner(body: AcceptIn, request: Request, pr: Principal = Depends(require_permission("loyalty.manage"))):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await partners.accept(conn, ctx, body.partner_id, body.code, body.reference, pr.user_id, None)
    request.state.audit = {"action": "voucher.accept", "object_type": "partner_redemption", "object_id": out["redemption"]}
    return out


class SettlementIn(BaseModel):
    partner_id: int = Field(gt=0)
    currency: str | None = Field(default=None, pattern=r"^[A-Z]{3}$")     # empty: the partner's programme currency
    date_from: date
    date_to: date


@router.post("/settlements", status_code=201)
async def open_settlement(body: SettlementIn, request: Request, pr: Principal = Depends(require_permission("loyalty.manage"))):
    if (body.date_to - body.date_from).days > 92:
        raise ApiError(422, "INVALID_PERIOD", "a statement covers at most 92 days")
    async with db.transaction(context_for(request, pr)) as conn:
        currency = await conn.fetchval(
            """SELECT g.currency FROM pricing.loyalty_partner lp JOIN pricing.loyalty_program g ON g.id = lp.program_id
                WHERE lp.id = $1""", body.partner_id)
        if currency is None:
            raise not_found("loyalty partner")
        out = await partners.open_settlement(conn, body.partner_id, body.currency or currency, body.date_from, body.date_to, pr.user_id)
    request.state.audit = {"action": "loyalty.settlement_open", "object_type": "loyalty_settlement", "reason": out["settlement"]}
    return out


class PayIn(BaseModel):
    bank_ref: str = Field(min_length=3, max_length=80)


@router.post("/settlements/{settlement}/pay")
async def pay_settlement(settlement: uuid.UUID, body: PayIn, request: Request, pr: Principal = Depends(require_permission("payout.run"))):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await partners.pay_settlement(conn, ctx, settlement, body.bank_ref.strip(), pr.user_id)
    request.state.audit = {"action": "loyalty.settlement_paid", "object_type": "loyalty_settlement", "reason": body.bank_ref[:80]}
    return out

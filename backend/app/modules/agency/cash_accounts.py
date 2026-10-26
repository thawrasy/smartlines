"""Agencies' cash sales settled with the carriers (owner's decision N13, 1145).

In phase one an agency sells for cash (AGENCY_CASH): the traveller pays the agency, which owes the carrier its share
(the fares less the commission agreed with the carrier) and pays it directly, until agency wallets open. The platform
keeps the account between each agency and each carrier: what was sold, what the carrier recorded receiving, and what
is still owed. The carrier records each sum it receives; its cash wallet now holds it and the agency's no longer does.

    GET  /api/agency/cash-accounts                 the agency's account with each carrier
    GET  /api/carrier/agency-cash                  the carrier's account with each agency
    POST /api/carrier/agency-cash/receipts         the carrier records cash an agency paid it
"""
import uuid

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, not_found
from ...ledger import cash_wallet, post_txn
from ...util import row_dict
from ..notify.outbox import emit
from . import service as agency_service

router = APIRouter(tags=["agency"])


class ReceiptIn(BaseModel):
    agency_uid: uuid.UUID
    currency: str = Field(min_length=3, max_length=3)
    amount: int = Field(gt=0)
    reference: str = Field(min_length=3, max_length=80)


async def accounts(conn: asyncpg.Connection, agency_id: int | None = None, carrier_id: int | None = None) -> list[dict]:
    """One row per agency and carrier pair that has cash sales or receipts, seen from either side."""
    rows = await conn.fetch(
        """WITH pairs AS (SELECT b.agency_id, b.company_id AS carrier_id, b.currency FROM sales.booking b
                            WHERE b.pay_option = 'AGENCY_CASH' AND b.price_allocation_id IS NOT NULL
                              AND ($1::bigint IS NULL OR b.agency_id = $1) AND ($2::bigint IS NULL OR b.company_id = $2)
                          UNION
                          SELECT s.agency_id, s.carrier_id, s.currency FROM fin.agency_cash_settlement s
                            WHERE ($1::bigint IS NULL OR s.agency_id = $1) AND ($2::bigint IS NULL OR s.carrier_id = $2))
           SELECT pa.uid AS agency_uid, pa.legal_name AS agency_name, pc.uid AS carrier_uid, pc.legal_name AS carrier_name,
                  iam.logo_version(pc.id) AS carrier_logo, p.currency,
                  (SELECT coalesce(sum(s.amount), 0) FROM fin.agency_cash_settlement s
                    WHERE s.agency_id = p.agency_id AND s.carrier_id = p.carrier_id AND s.currency = p.currency)::bigint AS received,
                  fin.agency_cash_owed(p.agency_id, p.carrier_id, p.currency) AS owed,
                  (SELECT max(s.confirmed_at) FROM fin.agency_cash_settlement s
                    WHERE s.agency_id = p.agency_id AND s.carrier_id = p.carrier_id AND s.currency = p.currency) AS last_received_at
             FROM pairs p JOIN iam.party pa ON pa.id = p.agency_id JOIN iam.party pc ON pc.id = p.carrier_id
            ORDER BY owed DESC, pa.legal_name, pc.legal_name""", agency_id, carrier_id)
    out = []
    for r in rows:
        d = row_dict(r)
        d["sold"] = d["owed"] + d["received"]        # the carrier's share of the cash sales, net of refunds
        out.append(d)
    return out


async def receipts(conn: asyncpg.Connection, agency_id: int | None = None, carrier_id: int | None = None) -> list[dict]:
    rows = await conn.fetch(
        """SELECT s.uid, pa.legal_name AS agency_name, pc.legal_name AS carrier_name, s.currency, s.amount, s.reference,
                  s.confirmed_at
             FROM fin.agency_cash_settlement s JOIN iam.party pa ON pa.id = s.agency_id JOIN iam.party pc ON pc.id = s.carrier_id
            WHERE ($1::bigint IS NULL OR s.agency_id = $1) AND ($2::bigint IS NULL OR s.carrier_id = $2)
            ORDER BY s.confirmed_at DESC LIMIT 50""", agency_id, carrier_id)
    return [row_dict(r) for r in rows]


async def record_receipt(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, body: ReceiptIn) -> dict:
    """The carrier records cash an agency paid it: never more than the agency owes, and once per reference."""
    carrier_id = pr.company_id
    agency_id = await conn.fetchval(
        "SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1 AND c.company_type = 'AGENCY'",
        body.agency_uid)
    if agency_id is None:
        raise not_found("agency")
    currency = body.currency.upper()
    await conn.execute("SELECT pg_advisory_xact_lock(hashtextextended(format('agency_cash:%s:%s', $1::bigint, $2::bigint), 0))",
                       agency_id, carrier_id)
    owed = await conn.fetchval("SELECT fin.agency_cash_owed($1, $2, $3)", agency_id, carrier_id, currency)
    if body.amount > owed:
        raise ApiError(409, "MORE_THAN_OWED", "the agency owes less than this amount", owed=owed)
    reference = body.reference.strip()
    if await conn.fetchval("SELECT 1 FROM fin.agency_cash_settlement WHERE carrier_id = $1 AND reference = $2", carrier_id, reference):
        raise ApiError(409, "REFERENCE_USED", "this receipt reference was already recorded")
    async with db.system_scope(conn, ctx):
        carrier_cash = await cash_wallet(conn, carrier_id, currency)
        agency_cash = await cash_wallet(conn, agency_id, currency)
        txn = await post_txn(conn, "AGENCY_CASH_SETTLE", currency, f"agency_cash:{carrier_id}:{reference}",
                             [(carrier_cash["id"], "DR", body.amount), (agency_cash["id"], "CR", body.amount)],
                             ref_type="company", ref_id=agency_id, user_id=pr.user_id, memo=reference)
    row = await conn.fetchrow(
        """INSERT INTO fin.agency_cash_settlement (agency_id, carrier_id, currency, amount, reference, ledger_txn_id, confirmed_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id, uid, confirmed_at""",
        agency_id, carrier_id, currency, body.amount, reference, txn, pr.user_id)
    carrier_name = await conn.fetchval("SELECT legal_name FROM iam.party WHERE id = $1", carrier_id)
    await emit(conn, "agency_cash.received", "agency_cash_settlement", row["id"], {
        "agency_id": agency_id, "carrier_name": carrier_name, "amount": body.amount, "currency": currency,
        "reference": reference, "owed_after": owed - body.amount}, company_id=agency_id)
    return {"uid": str(row["uid"]), "amount": body.amount, "currency": currency, "reference": reference,
            "confirmed_at": row["confirmed_at"].isoformat(), "owed": owed - body.amount, "settlement_id": row["id"]}


# ------------------------------------------------------------------ routes
@router.get("/api/agency/cash-accounts")
async def agency_accounts(request: Request, pr: Principal = Depends(require_portal("AGENCY"))):
    agency_id = agency_service.require_agency(pr)
    agency_service.need(pr, "report.company", "company.billing", "booking.on_behalf")
    async with db.transaction(context_for(request, pr)) as conn:
        return {"cash_sales": await agency_service.sells_for_cash(conn),
                "accounts": await accounts(conn, agency_id=agency_id), "receipts": await receipts(conn, agency_id=agency_id)}


@router.get("/api/carrier/agency-cash")
async def carrier_accounts(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    agency_service.need(pr, "company.billing", "report.company", "sale.cash")
    async with db.transaction(context_for(request, pr)) as conn:
        return {"accounts": await accounts(conn, carrier_id=pr.company_id), "receipts": await receipts(conn, carrier_id=pr.company_id)}


@router.post("/api/carrier/agency-cash/receipts", status_code=201)
async def carrier_receipt(body: ReceiptIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    agency_service.need(pr, "company.billing", "sale.cash")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await record_receipt(conn, ctx, pr, body)
    request.state.audit = {"action": "agency_cash.receipt", "object_type": "agency_cash_settlement",
                           "object_id": out.pop("settlement_id"), "reason": f"{out['amount']} {out['currency']} ({out['reference']})"}
    return out

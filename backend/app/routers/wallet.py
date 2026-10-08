"""Passenger wallet: balance, statement and top-up.

Top-up goes through a payment provider adapter. Only the sandbox provider is implemented here; it
simulates the gateway's signed notification so the full flow (payment -> notification -> ledger)
can be tested. It is refused unless MASSLAK_SANDBOX=true.
"""
import json
import uuid

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from .. import db, markets
from ..config import get_settings
from ..deps import Principal, context_for, require_portal
from ..errors import ApiError
from ..ledger import platform_wallet, post_txn, user_wallet
from ..util import rows

router = APIRouter(prefix="/api/wallet", tags=["wallet"])
passenger = require_portal("PASSENGER")


@router.get("")
async def wallet(request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        w = await user_wallet(conn, pr.party_id, (await markets.of_party(conn, pr.party_id)).currency)   # the passenger's market (1061)
        entries = await conn.fetch(
            """SELECT e.direction, e.amount, e.balance_after, e.created_at, t.txn_type, t.memo
                 FROM fin.ledger_entry e JOIN fin.ledger_txn t ON t.id = e.txn_id
                WHERE e.wallet_id = $1 ORDER BY e.created_at DESC, e.id DESC LIMIT 50""", w["id"])
    return {"currency": w["currency"], "balance": w["balance"], "entries": rows(entries),
            "sandbox": get_settings().sandbox}


class TopupIn(BaseModel):
    amount: int = Field(gt=0, le=1_000_000_000)          # minor units
    idempotency_key: str = Field(min_length=8, max_length=80)


@router.post("/topup")
async def topup(body: TopupIn, request: Request, pr: Principal = Depends(passenger)):
    if not get_settings().sandbox:
        raise ApiError(503, "PAYMENT_PROVIDER_UNAVAILABLE", "no live payment provider is configured")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        # a replay is the same payer's own request: another payer's key is never looked up (review stage A2) and,
        # the key being unique, ends in ALREADY_EXISTS without saying anything about that payment
        done = await conn.fetchval("SELECT status FROM fin.payment WHERE idempotency_key = $1 AND payer_party_id = $2",
                                   body.idempotency_key, pr.party_id)
        if done:
            return {"status": done, "replayed": True}
        currency = (await markets.of_party(conn, pr.party_id)).currency
        w = await user_wallet(conn, pr.party_id, currency)
        async with db.system_scope(conn, ctx):
            provider = await conn.fetchrow("SELECT id FROM fin.payment_provider WHERE code = 'SANDBOX'")
            if provider is None:
                raise ApiError(503, "PAYMENT_PROVIDER_UNAVAILABLE", "sandbox provider not configured")
            provider_ref = f"SBX-{uuid.uuid4().hex[:16]}"
            pay_id = await conn.fetchval(
                """INSERT INTO fin.payment (provider_id, purpose, payer_party_id, wallet_id, method, currency, amount,
                     provider_ref, idempotency_key)
                   VALUES ($1, 'TOPUP', $2, $3, 'CARD', $7, $4, $5, $6) RETURNING id""",
                provider["id"], pr.party_id, w["id"], body.amount, provider_ref, body.idempotency_key, currency)
            # Simulated signed notification from the gateway (source of truth for the payment status)
            await conn.execute(
                """INSERT INTO fin.payment_notification (provider_id, event_id, payment_id, signature_valid, source_ip, payload, processed_at)
                   VALUES ($1, $2, $3, true, $4::inet, $5::jsonb, now())""",
                provider["id"], f"evt-{provider_ref}", pay_id, request.state.client_ip,
                json.dumps({"type": "payment.captured", "ref": provider_ref, "amount": body.amount, "sandbox": True}))
            clearing = await platform_wallet(conn, "GATEWAY_CLEARING", currency)
            txn = await post_txn(conn, "TOPUP", currency, f"payment:{pay_id}",
                                 [(clearing["id"], "DR", body.amount), (w["id"], "CR", body.amount)],
                                 ref_type="payment", ref_id=pay_id, user_id=pr.user_id, memo=provider_ref)
            await conn.execute("UPDATE fin.payment SET status = 'SUCCESS', ledger_txn_id = $2, settled_at = now() WHERE id = $1",
                               pay_id, txn)
        balance = await conn.fetchval("SELECT balance FROM fin.wallet WHERE id = $1", w["id"])
    request.state.audit = {"action": "wallet.topup", "object_type": "payment", "object_id": pay_id}
    return {"status": "SUCCESS", "balance": balance}

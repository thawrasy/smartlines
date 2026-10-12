"""Loyalty points in the passenger portal (study 5.12, 5.13; migration 1103).

    GET  /api/loyalty            the programme, my balance and tier, what it is worth, how to redeem, recent movements
    POST /api/loyalty/redeem     turn points into wallet credit at the programme's point value

Points are earned when the carrier completes a trip (pricing.earn_points_for_trip, called by the trip completion) and
expire after the programme's months (pricing.expire_points, daily). A redemption moves points and money together in one
transaction: the points ledger takes the points, the platform's loyalty expense wallet pays the member's wallet.
"""
from __future__ import annotations

import json

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...ledger import loyalty_wallet, post_txn, user_wallet
from ...modular import features
from ...util import row_dict, rows

router = APIRouter(prefix="/api/loyalty", tags=["loyalty"], dependencies=[features.require_module("loyalty")])
passenger = require_portal("PASSENGER")


@router.get("")
async def my_points(request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        program = await conn.fetchrow(
            """SELECT g.id, g.code, g.name, g.point_value, g.currency, g.expiry_months,
                      (SELECT jsonb_build_object('min_points', coalesce((r.formula ->> 'min_points')::bigint, 1),
                                                 'step', coalesce((r.formula ->> 'step')::bigint, 1))
                         FROM pricing.loyalty_rule r WHERE r.program_id = g.id AND r.kind = 'BURN' AND r.active AND r.valid @> now()
                        ORDER BY r.id DESC LIMIT 1) AS redeem
                 FROM pricing.loyalty_program g WHERE g.status = 'ACTIVE' ORDER BY g.id LIMIT 1""")
        if program is None:
            return {"program": None, "account": None, "entries": []}
        account = await conn.fetchrow(
            """SELECT a.id, a.balance, a.status, t.code AS tier_code, t.name AS tier_name
                 FROM pricing.points_account a LEFT JOIN pricing.loyalty_tier t ON t.id = a.tier_id
                WHERE a.program_id = $1 AND a.party_id = $2""", program["id"], pr.party_id)
        entries = await conn.fetch(
            """SELECT l.txn_type, l.points, l.expires_at, l.created_at FROM pricing.points_ledger l
                WHERE l.account_id = $1 ORDER BY l.id DESC LIMIT 20""", account["id"]) if account else []
    p = row_dict(program)
    p.pop("id")
    p["redeem"] = json.loads(p["redeem"]) if isinstance(p["redeem"], str) else p["redeem"]
    a = None
    if account:
        a = {k: account[k] for k in ("balance", "status", "tier_code", "tier_name")}
        a["value"] = account["balance"] * program["point_value"]
    return {"program": p, "account": a, "entries": rows(entries)}


class RedeemIn(BaseModel):
    points: int = Field(gt=0, le=100_000_000)
    idempotency_key: str = Field(min_length=8, max_length=64)


@router.post("/redeem")
async def redeem(body: RedeemIn, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = json.loads(await conn.fetchval("SELECT pricing.redeem_points($1, $2, $3)::text", pr.party_id, body.points,
                                             f"redeem:{pr.party_id}:{body.idempotency_key}"))
        if not out["replayed"] and out["value"] > 0:
            async with db.system_scope(conn, ctx):
                source = await loyalty_wallet(conn, out["currency"])
                wallet = await user_wallet(conn, pr.party_id, out["currency"])
                await post_txn(conn, "LOYALTY_REDEEM", out["currency"], f"points:{out['ledger_id']}",
                               [(source["id"], "DR", out["value"]), (wallet["id"], "CR", out["value"])],
                               ref_type="points_ledger", ref_id=out["ledger_id"], user_id=pr.user_id, memo=f"{out['points']} points")
    request.state.audit = {"action": "points.redeem", "object_type": "points_ledger", "object_id": out["ledger_id"]}
    return {k: out[k] for k in ("points", "value", "currency", "replayed") if k in out} | {"balance": out.get("balance")}

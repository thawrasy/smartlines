"""The payment gateway opened carrier by carrier (owner's decision N13, phase two; 1145).

After the platform contracts a gateway, a traveller pays a carrier's ticket through it only once the platform has
activated that option for the carrier. Each carrier is told when its contract is signed and again when the option goes
live on its trips, so the roll-out goes step by step. The gateway settles into the platform's bank account and the
carrier is paid its share as with any electronic payment (escrow, release on completion, withdrawal).

    GET /api/admin/payment-activations                          every carrier's state, per gateway option
    PUT /api/admin/payment-activations/{carrier_uid}/{option}   {status, basis}: contracted, active or suspended
    GET /api/carrier/payment-activations                        the carrier's own state
"""
import uuid
from typing import Literal

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal, require_step_up
from ...errors import ApiError, not_found
from ...util import row_dict
from ..notify.outbox import emit
from .service import need

router = APIRouter(tags=["payments"])
GATEWAY_OPTIONS = ("CARD", "INSTALLMENT", "FINANCING")
Option = Literal["CARD", "INSTALLMENT", "FINANCING"]


class ActivationIn(BaseModel):
    status: Literal["CONTRACTED", "ACTIVE", "SUSPENDED"]
    basis: str = Field(min_length=3, max_length=200)


async def states(conn: asyncpg.Connection, carrier_id: int | None = None) -> list[dict]:
    rows = await conn.fetch(
        """SELECT p.uid AS carrier_uid, p.legal_name AS carrier_name, a.option_code, a.status, a.basis, a.contracted_at,
                  a.activated_at, a.changed_at
             FROM fin.carrier_payment_activation a JOIN iam.party p ON p.id = a.carrier_id
            WHERE $1::bigint IS NULL OR a.carrier_id = $1
            ORDER BY p.legal_name, a.option_code""", carrier_id)
    return [row_dict(r) for r in rows]


async def set_state(conn: asyncpg.Connection, user_id: int, carrier_uid: uuid.UUID, option: str, body: ActivationIn) -> dict:
    carrier = await conn.fetchrow(
        """SELECT c.id, p.legal_name FROM iam.company c JOIN iam.party p ON p.id = c.id
            WHERE p.uid = $1 AND c.company_type IN ('CARRIER','INDIVIDUAL_OPERATOR','FOREIGN_CARRIER')""", carrier_uid)
    if carrier is None:
        raise not_found("carrier")
    before = await conn.fetchval(
        "SELECT status FROM fin.carrier_payment_activation WHERE carrier_id = $1 AND option_code = $2", carrier["id"], option)
    if before is None and body.status != "CONTRACTED":
        raise ApiError(409, "NOT_CONTRACTED", "record the carrier's contract before activating the option")
    row = await conn.fetchrow(
        """INSERT INTO fin.carrier_payment_activation (carrier_id, option_code, status, basis, activated_at, changed_by)
           VALUES ($1, $2, $3, $4, CASE WHEN $3 = 'ACTIVE' THEN now() END, $5)
           ON CONFLICT (carrier_id, option_code) DO UPDATE SET status = EXCLUDED.status, basis = EXCLUDED.basis,
                activated_at = CASE WHEN EXCLUDED.status = 'ACTIVE' THEN coalesce(fin.carrier_payment_activation.activated_at, now())
                                    ELSE fin.carrier_payment_activation.activated_at END,
                changed_by = EXCLUDED.changed_by, changed_at = now()
           RETURNING id, status, contracted_at, activated_at""", carrier["id"], option, body.status, body.basis.strip(), user_id)
    if before != body.status:          # the carrier hears of each step: contract signed, option live, option paused
        await emit(conn, f"payment_activation.{body.status.lower()}", "carrier_payment_activation", row["id"], {
            "option": option, "status": body.status, "basis": body.basis.strip(), "carrier_name": carrier["legal_name"]},
            company_id=carrier["id"])
    return {"carrier_uid": str(carrier_uid), "option_code": option, "status": row["status"], "basis": body.basis.strip(),
            "contracted_at": row["contracted_at"].isoformat(),
            "activated_at": row["activated_at"].isoformat() if row["activated_at"] else None, "id": row["id"]}


@router.get("/api/admin/payment-activations")
async def admin_list(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    need(pr, "payment.methods", "payment.fee_policy", "ledger.reconcile")
    async with db.transaction(context_for(request, pr)) as conn:
        return {"options": list(GATEWAY_OPTIONS), "activations": await states(conn)}


@router.put("/api/admin/payment-activations/{carrier_uid}/{option}")
async def admin_set(carrier_uid: uuid.UUID, option: Option, body: ActivationIn, request: Request,
                    pr: Principal = Depends(require_portal("PLATFORM"))):
    need(pr, "payment.methods")
    require_step_up(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await set_state(conn, pr.user_id, carrier_uid, option, body)
    request.state.audit = {"action": "payment_activation.set", "object_type": "carrier_payment_activation",
                           "object_id": out.pop("id"), "reason": f"{option} {body.status}: {body.basis}"}
    return out


@router.get("/api/carrier/payment-activations")
async def carrier_list(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"activations": await states(conn, pr.company_id)}

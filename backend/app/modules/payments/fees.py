"""Payment fees (owner's decision 4; review of release 1.47.0, R-20).

The platform sets the fee of each way of paying, per currency and, when it wants, per customer: a percentage, a fixed
amount, both, or nothing (for offers), within a period. By default the customer pays it, on top of the amount, and sees
it before paying; a rule may say the platform bears it instead. The rule in force and its rounding are in the database
(fin.fee_rule, fin.payment_fee), so the fee shown, the fee asked from the provider and the fee posted are one number.

Fees apply to the providers that take money for the platform (cards, partner e-wallets, instalments, financing); bank
transfers, agency counters and partner credits carry none.
"""
from __future__ import annotations

from typing import Optional

import asyncpg

from ...errors import ApiError

FEE_ADAPTERS = ("HOSTED_CARD", "PARTNER_WALLET", "INSTALLMENT", "FINANCING")


def _out(r) -> dict:
    return {"fee": r["fee"], "absorbed": r["absorbed"], "rule_id": r["rule_id"], "label": r["label"], "kind": r["kind"],
            "pct": float(r["pct"]), "fixed_amount": r["fixed_amount"], "borne_by": r["borne_by"]}


async def fee_for(conn: asyncpg.Connection, p: dict, currency: str, amount: int, party_id: Optional[int]) -> dict:
    """The fee of one payment of this amount: what the payer adds, what the platform absorbs, and the rule."""
    if p["adapter"] not in FEE_ADAPTERS:
        return {"fee": 0, "absorbed": 0, "rule_id": None, "label": None, "kind": "NONE", "pct": 0.0, "fixed_amount": 0,
                "borne_by": "PAYER"}
    return _out(await conn.fetchrow("SELECT * FROM fin.payment_fee($1, $2, $3, $4)", p["id"], currency, amount, party_id))


async def quote(conn: asyncpg.Connection, p: dict, currency: str, amount: int, party_id: Optional[int]) -> dict:
    """What the payer will be asked for, shown before paying."""
    if not p["min_amount"] <= amount <= p["max_amount"]:
        raise ApiError(422, "PAYMENT_AMOUNT_OUT_OF_RANGE", "amount outside the method's limits",
                       min_amount=p["min_amount"], max_amount=p["max_amount"])
    f = await fee_for(conn, p, currency, amount, party_id)
    return {"method": p["code"], "currency": currency, "amount": amount, "fee": f["fee"], "total": amount + f["fee"],
            "fee_label": f["label"], "fee_borne_by": f["borne_by"], "fee_absorbed": f["absorbed"]}


RULE_COLUMNS = ("label", "provider_id", "currency", "party_id", "kind", "pct", "fixed_amount", "min_fee", "max_fee",
                "round_to", "rounding", "borne_by", "valid_from", "valid_to", "status")


def rule_out(r) -> dict:
    return {"uid": str(r["uid"]), "label": r["label"], "provider": r["provider_code"], "currency": r["currency"].strip() if r["currency"] else None,
            "customer": r["party_name"], "customer_uid": str(r["party_uid"]) if r["party_uid"] else None,
            "kind": r["kind"], "pct": float(r["pct"]), "fixed_amount": r["fixed_amount"], "min_fee": r["min_fee"],
            "max_fee": r["max_fee"], "round_to": r["round_to"], "rounding": r["rounding"], "borne_by": r["borne_by"],
            "valid_from": r["valid_from"].isoformat(), "valid_to": r["valid_to"].isoformat() if r["valid_to"] else None,
            "status": r["status"]}


LIST_SQL = """SELECT f.*, pv.code AS provider_code, pa.legal_name AS party_name, pa.uid AS party_uid
                FROM fin.fee_rule f LEFT JOIN fin.payment_provider pv ON pv.id = f.provider_id
                LEFT JOIN iam.party pa ON pa.id = f.party_id"""


async def provider_default(conn: asyncpg.Connection, p: dict, pct: float, borne_by: str, user_id: int) -> None:
    """The provider screen's percentage and payer are the provider's default rule (every currency, every customer)."""
    rid = await conn.fetchval("""SELECT id FROM fin.fee_rule WHERE provider_id = $1 AND party_id IS NULL AND currency IS NULL
                                    AND status = 'ACTIVE' AND label LIKE 'Default fee of %' ORDER BY id LIMIT 1""", p["id"])
    kind = "PERCENT" if pct > 0 else "NONE"
    if rid:
        await conn.execute("UPDATE fin.fee_rule SET kind = $2, pct = $3, borne_by = $4, updated_by = $5, updated_at = now() WHERE id = $1",
                           rid, kind, round(pct, 3), borne_by, user_id)
    elif pct > 0:
        await conn.execute("""INSERT INTO fin.fee_rule (label, provider_id, kind, pct, borne_by, created_by, updated_by)
                              VALUES ($1, $2, 'PERCENT', $3, $4, $5, $5)""", f"Default fee of {p['name']}", p["id"], round(pct, 3),
                           borne_by, user_id)

"""Commission schemes computed (1175): what a commission scheme takes from a sale and who pays it to whom.

A scheme has a type (who receives it), a payer (funded_by), a base and rules:
    type        PLATFORM → the platform; INTERMEDIARY, SUB_AGENT, OVERRIDE → the selling agency; PAYMENT → the payment
                provider; REFERRAL → the referrer
    funded_by   CARRIER, PLATFORM, CHANNEL (the agency's own share) pay it out of what they receive; CUSTOMER adds it to
                what the traveller pays
    base        FARE the ticket price paid; NET the fare without its taxes; FEE the platform fee
    rules       PERCENT of the base, FIXED per booking, TIERED by bands of the base (the band the base falls in, WHOLE,
                or each band on its own share, MARGINAL); each with a minimum and a maximum; the rules of a scheme add up
A scheme's scope narrows it to sales channels (WEB, AGENCY, COUNTER, API) and to companies. Amounts are in minor units,
rounded half up.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from decimal import ROUND_HALF_UP, Decimal
from typing import Optional

import asyncpg

RECEIVER = {"PLATFORM": "PLATFORM", "INTERMEDIARY": "AGENCY", "SUB_AGENT": "AGENCY", "OVERRIDE": "AGENCY", "PAYMENT": "PAYMENT",
            "REFERRAL": "REFERRER"}
PAYER = {"CARRIER": "CARRIER", "PLATFORM": "PLATFORM", "CHANNEL": "AGENCY", "CUSTOMER": "TRAVELLER"}


@dataclass
class CBand:
    low: Decimal
    high: Optional[Decimal]
    rate: Optional[Decimal]
    amount: Optional[int]
    mode: str


@dataclass
class CRule:
    calc_method: str
    rate: Optional[Decimal]
    amount: Optional[int]
    min_amount: Optional[int]
    max_amount: Optional[int]
    bands: list[CBand] = field(default_factory=list)


@dataclass
class CScheme:
    id: int
    code: str
    type: str
    funded_by: str
    beneficiary_role: str
    base_type: str
    scope: dict
    rules: list[CRule] = field(default_factory=list)


def applies(sc: CScheme, channel: Optional[str], company_id: Optional[int]) -> bool:
    s = sc.scope or {}
    return ((not s.get("channels") or channel in s["channels"])
            and (not s.get("company_ids") or company_id in s["company_ids"]))


def _rule(r: CRule, base: Decimal) -> Decimal:
    if r.calc_method == "PERCENT":
        v = base * Decimal(r.rate or 0) / 100
    elif r.calc_method == "FIXED":
        v = Decimal(r.amount or 0)
    else:
        v = Decimal(0)
        if r.bands and r.bands[0].mode == "MARGINAL":
            for b in r.bands:
                top = base if b.high is None else min(base, Decimal(b.high))
                part = top - Decimal(b.low)
                if part > 0:
                    v += part * Decimal(b.rate or 0) / 100 + Decimal(b.amount or 0)
        else:
            for b in r.bands:
                if Decimal(b.low) <= base and (b.high is None or base < Decimal(b.high)):
                    v = base * Decimal(b.rate) / 100 if b.rate is not None else Decimal(b.amount or 0)
                    break
    if r.min_amount is not None and v < r.min_amount:
        v = Decimal(r.min_amount)
    if r.max_amount is not None and v > r.max_amount:
        v = Decimal(r.max_amount)
    return v


def amount(sc: CScheme, base: int) -> int:
    """The commission of a scheme on its base."""
    return int(sum((_rule(r, Decimal(base)) for r in sc.rules), Decimal(0)).quantize(Decimal(1), rounding=ROUND_HALF_UP))


async def load(conn: asyncpg.Connection, where: str, *args) -> list[CScheme]:
    rows = await conn.fetch(
        f"SELECT id, code, type, funded_by, beneficiary_role, base_type, scope FROM pricing.commission_scheme WHERE {where} ORDER BY code", *args)
    schemes = [CScheme(r["id"], r["code"], r["type"], r["funded_by"], r["beneficiary_role"], r["base_type"],
                       r["scope"] if isinstance(r["scope"], dict) else json.loads(r["scope"] or "{}")) for r in rows]
    if not schemes:
        return []
    by_id = {s.id: s for s in schemes}
    rules = await conn.fetch(
        "SELECT id, scheme_id, calc_method, rate, amount, min_amount, max_amount FROM pricing.commission_rule WHERE scheme_id = ANY($1::bigint[]) ORDER BY scheme_id, seq",
        list(by_id))
    bands = await conn.fetch(
        "SELECT commission_rule_id, from_value, to_value, rate, amount, mode FROM pricing.rate_band WHERE commission_rule_id = ANY($1::bigint[]) ORDER BY commission_rule_id, from_value",
        [r["id"] for r in rules])
    by_rule = {}
    for r in rules:
        cr = CRule(r["calc_method"], r["rate"], r["amount"], r["min_amount"], r["max_amount"])
        by_rule[r["id"]] = cr
        by_id[r["scheme_id"]].rules.append(cr)
    for b in bands:
        by_rule[b["commission_rule_id"]].bands.append(CBand(b["from_value"], b["to_value"], b["rate"], b["amount"], b["mode"]))
    return schemes


async def in_force(conn: asyncpg.Connection, at=None) -> list[CScheme]:
    return await load(conn, "status = 'ACTIVE' AND valid @> coalesce($1::timestamptz, now())", at)

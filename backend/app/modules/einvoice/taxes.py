"""Taxes of an e-invoice line from the platform's tax schemes (migration 1108; owner's decision, October 2026).

A scheme is one tax (VAT, sales tax, a local levy, a stamp ...) of a jurisdiction, with a treatment (OUT_OF_SCOPE,
EXEMPT, ZERO, STANDARD, REVERSE), a scope (products, sellers, carriers, origin cities) and, when STANDARD, rules:
  PERCENT  rate % of the base            FIXED   an amount per ticket, or once per booking (applies_per BOOKING)
  TIERED   bands of the base (or of the trip's distance): the band it falls in (WHOLE) or each band's share (MARGINAL)
A rule's base is the line's net amount (base_type FARE) plus the taxes of the line it names in base_include, or only
those taxes (base_type TAXES): compound taxes and taxes on taxes. A scheme's rules combine in order: ADD sums, MAX and
MIN keep the larger or smaller, CASCADE adds the scheme's earlier rules to the rule's base. Each rule has a minimum, a
maximum and a rounding (HALF_UP, HALF_EVEN, DOWN, UP) to minor units.

Prices on the platform include their taxes. split_inclusive finds the largest net amount whose taxes fit in the price
paid; the taxes are computed on it and any remaining minor unit stays in the net amount, so net + taxes = price.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime
from decimal import ROUND_CEILING, ROUND_FLOOR, ROUND_HALF_EVEN, ROUND_HALF_UP, Decimal
from typing import Optional

import asyncpg

from ...errors import ApiError

_ROUND = {"HALF_UP": ROUND_HALF_UP, "HALF_EVEN": ROUND_HALF_EVEN, "DOWN": ROUND_FLOOR, "UP": ROUND_CEILING}


@dataclass
class Band:
    dimension: str
    low: Decimal
    high: Optional[Decimal]
    rate: Optional[Decimal]
    amount: Optional[int]
    mode: str


@dataclass
class Rule:
    seq: int
    calc_method: str
    rate: Optional[Decimal]
    amount: Optional[int]
    base_type: str
    base_include: list[str]
    compound_mode: str
    min_amount: Optional[int]
    max_amount: Optional[int]
    rounding: str
    applies_per: str
    priority: int
    bands: list[Band] = field(default_factory=list)


@dataclass
class Scheme:
    id: int
    code: str
    tax_type: str
    treatment: str
    payable_to_party_id: Optional[int]
    scope: dict
    rules: list[Rule] = field(default_factory=list)


@dataclass
class LineTax:
    scheme_id: Optional[int]
    code: str
    tax_type: str
    treatment: str
    rate: Decimal
    base: int
    amount: int
    payable_to_party_id: Optional[int]


@dataclass
class Sale:
    """What decides which taxes apply to a line."""
    country: str
    seller: str                      # CARRIER or PLATFORM
    product: str                     # TICKET or BOOKING_FEE
    company_id: Optional[int] = None
    origin_city: Optional[str] = None
    distance_km: Optional[Decimal] = None
    at: Optional[datetime] = None    # the time of the sale: the schemes valid then apply


def _applies(scheme: Scheme, sale: Sale) -> bool:
    s = scheme.scope or {}
    return ((not s.get("products") or sale.product in s["products"])
            and (not s.get("sellers") or sale.seller in s["sellers"])
            and (not s.get("company_ids") or sale.company_id in s["company_ids"])
            and (not s.get("origin_cities") or sale.origin_city in s["origin_cities"]))


async def schemes_for(conn: asyncpg.Connection, sale: Sale) -> list[Scheme]:
    """The active schemes of the sale's country valid at the time of the sale that apply to it, in the order their
    taxes are computed (a tax levied on another tax comes after it)."""
    rows = await conn.fetch(
        """SELECT s.id, s.code, s.tax_type, s.treatment, s.payable_to_party_id, s.scope
             FROM pricing.tax_scheme s JOIN pricing.jurisdiction j ON j.id = s.jurisdiction_id
            WHERE s.status = 'ACTIVE' AND s.valid @> coalesce($2::timestamptz, now()) AND j.country_code = $1
            ORDER BY s.code""", sale.country, sale.at)
    schemes = [sc for sc in (_scheme(r) for r in rows) if _applies(sc, sale)]
    await _attach_rules(conn, schemes)
    return _ordered(schemes)


def _scheme(r) -> Scheme:
    scope = r["scope"] if isinstance(r["scope"], dict) else json.loads(r["scope"] or "{}")
    return Scheme(r["id"], r["code"], r["tax_type"], r["treatment"], r["payable_to_party_id"], scope)


async def schemes_by_id(conn: asyncpg.Connection, ids: list[int]) -> list[Scheme]:
    """Given schemes whatever their status, with their rules: a draft tried in the price preview before it is approved."""
    rows = await conn.fetch("SELECT id, code, tax_type, treatment, payable_to_party_id, scope FROM pricing.tax_scheme WHERE id = ANY($1::bigint[])", ids)
    schemes = [_scheme(r) for r in rows]
    await _attach_rules(conn, schemes)
    return schemes


async def _attach_rules(conn: asyncpg.Connection, schemes: list[Scheme]) -> None:
    if not schemes:
        return
    rules = await conn.fetch(
        """SELECT id, scheme_id, seq, calc_method, rate, amount, base_type, base_include, compound_mode, min_amount, max_amount,
                  rounding_rule, applies_per, priority FROM pricing.tax_rule WHERE scheme_id = ANY($1::bigint[]) ORDER BY priority, seq""",
        [sc.id for sc in schemes])
    bands = await conn.fetch(
        """SELECT tax_rule_id, dimension, from_value, to_value, rate, amount, mode FROM pricing.rate_band
            WHERE tax_rule_id = ANY($1::bigint[]) ORDER BY tax_rule_id, from_value""", [r["id"] for r in rules])
    by_scheme = {sc.id: sc for sc in schemes}
    by_rule: dict[int, Rule] = {}
    for r in rules:
        include = r["base_include"] if isinstance(r["base_include"], list) else json.loads(r["base_include"] or "[]")
        rule = Rule(r["seq"], r["calc_method"], r["rate"], r["amount"], r["base_type"], [str(c) for c in include], r["compound_mode"],
                    r["min_amount"], r["max_amount"], r["rounding_rule"], r["applies_per"], r["priority"])
        by_rule[r["id"]] = rule
        by_scheme[r["scheme_id"]].rules.append(rule)
    for b in bands:
        by_rule[b["tax_rule_id"]].bands.append(Band(b["dimension"], b["from_value"], b["to_value"], b["rate"], b["amount"], b["mode"]))


def _ordered(schemes: list[Scheme]) -> list[Scheme]:
    """Topological order on base_include, by code otherwise; a loop (refused when a scheme is activated) is an error."""
    codes = {sc.code: sc for sc in schemes}
    deps = {sc.code: {c for r in sc.rules for c in r.base_include if c in codes and c != sc.code} for sc in schemes}
    out, done = [], set()
    while len(out) < len(schemes):
        ready = sorted(c for c in codes if c not in done and deps[c] <= done)
        if not ready:
            raise ApiError(409, "TAX_SCHEME_LOOP", "the active tax schemes are levied on each other in a loop")
        for c in ready:
            out.append(codes[c])
            done.add(c)
    return out


def _rule_amount(rule: Rule, base: Decimal, sale: Sale, first_line: bool) -> Decimal:
    if rule.applies_per == "BOOKING" and not first_line and rule.calc_method in ("FIXED", "TIERED"):
        return Decimal(0)                                   # a fixed amount per booking is charged on its first line
    if rule.calc_method == "PERCENT":
        return base * Decimal(rule.rate) / 100
    if rule.calc_method == "FIXED":
        return Decimal(rule.amount or 0)
    if rule.calc_method == "TIERED":
        if not rule.bands:
            return Decimal(0)
        value = Decimal(sale.distance_km or 0) if rule.bands[0].dimension == "DISTANCE" else base
        if rule.bands[0].mode == "MARGINAL" and rule.bands[0].dimension == "AMOUNT":
            total = Decimal(0)
            for b in rule.bands:
                top = value if b.high is None else min(value, Decimal(b.high))
                part = top - Decimal(b.low)
                if part > 0:
                    total += part * Decimal(b.rate or 0) / 100 + Decimal(b.amount or 0)
            return total
        for b in rule.bands:                                # WHOLE: the band the value falls in
            if Decimal(b.low) <= value and (b.high is None or value < Decimal(b.high)):
                return base * Decimal(b.rate) / 100 if b.rate is not None else Decimal(b.amount or 0)
        return Decimal(0)
    raise ApiError(409, "TAX_RULE_UNSUPPORTED", f"tax rule method {rule.calc_method} is not computed by the issuer")


def taxes_on(net: int, schemes: list[Scheme], sale: Sale, first_line: bool = True) -> list[LineTax]:
    """The taxes of a line whose net amount is given, in the schemes' order."""
    out: list[LineTax] = []
    amounts: dict[str, int] = {}
    for sc in _ordered(schemes):
        if sc.treatment != "STANDARD":
            out.append(LineTax(sc.id, sc.code, sc.tax_type, sc.treatment, Decimal(0), net, 0, sc.payable_to_party_id))
            amounts[sc.code] = 0
            continue
        total: Optional[int] = None
        first_base: Optional[int] = None
        for rule in sc.rules:
            base = Decimal(net if rule.base_type == "FARE" else 0) + sum(Decimal(amounts.get(c, 0)) for c in rule.base_include)
            if rule.compound_mode == "CASCADE" and total is not None:
                base += total
            raw = _rule_amount(rule, base, sale, first_line)
            if rule.min_amount is not None and raw < rule.min_amount:
                raw = Decimal(rule.min_amount)
            if rule.max_amount is not None and raw > rule.max_amount:
                raw = Decimal(rule.max_amount)
            amt = int(raw.quantize(Decimal(1), rounding=_ROUND.get(rule.rounding, ROUND_HALF_UP)))
            if first_base is None:
                first_base = int(base)
            if total is None:
                total = amt
            elif rule.compound_mode == "MAX":
                total = max(total, amt)
            elif rule.compound_mode == "MIN":
                total = min(total, amt)
            else:                                           # ADD and CASCADE
                total += amt
        total = total or 0
        base_out = first_base if first_base is not None else net
        single = len(sc.rules) == 1 and sc.rules[0].calc_method == "PERCENT"
        rate = (Decimal(sc.rules[0].rate) if single else
                (Decimal(total * 100) / Decimal(base_out) if base_out else Decimal(0))).quantize(Decimal("0.000001"))
        out.append(LineTax(sc.id, sc.code, sc.tax_type, "STANDARD", rate, base_out, total, sc.payable_to_party_id))
        amounts[sc.code] = total
    return out


def split_inclusive(gross: int, schemes: list[Scheme], sale: Sale, first_line: bool = True) -> tuple[int, list[LineTax]]:
    """(net, taxes) of a price that includes its taxes: the largest net whose taxes fit; net + taxes = gross."""
    if not any(sc.treatment == "STANDARD" for sc in schemes):
        return gross, taxes_on(gross, schemes, sale, first_line)
    floor_taxes = taxes_on(0, schemes, sale, first_line)
    if sum(t.amount for t in floor_taxes) >= gross:
        # fixed taxes larger than the price itself: the whole price is tax, shared in proportion (the last absorbs rounding)
        shared = proportion(floor_taxes, gross, sum(t.amount for t in floor_taxes))
        if shared:
            shared[-1].amount += gross - sum(t.amount for t in shared)
        return 0, shared
    lo, hi = 0, gross
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if mid + sum(t.amount for t in taxes_on(mid, schemes, sale, first_line)) <= gross:
            lo = mid
        else:
            hi = mid - 1
    taxes = taxes_on(lo, schemes, sale, first_line)
    return gross - sum(t.amount for t in taxes), taxes


def line_treatment(taxes: list[LineTax]) -> str:
    """The line's own treatment, from its taxes: standard if any tax is charged on it."""
    kinds = {t.treatment for t in taxes}
    for k in ("STANDARD", "ZERO", "EXEMPT", "REVERSE"):
        if k in kinds:
            return k
    return "OUT_OF_SCOPE"


def proportion(taxes: list[LineTax], part: int, whole: int) -> list[LineTax]:
    """The share part/whole of each tax, for a credit note against an invoice (half up, per tax)."""
    if whole <= 0:
        return []
    ratio = Decimal(part) / Decimal(whole)
    return [LineTax(t.scheme_id, t.code, t.tax_type, t.treatment, t.rate,
                    int((Decimal(t.base) * ratio).quantize(Decimal(1), rounding=ROUND_HALF_UP)),
                    int((Decimal(t.amount) * ratio).quantize(Decimal(1), rounding=ROUND_HALF_UP)), t.payable_to_party_id)
            for t in taxes]

"""Amounts as people read them (1176).

Every amount is a bigint in the minor unit of its currency; ref.currency says how many of them make one unit
(minor_unit) and how many decimal places people see and pay in (decimals). Since the new Syrian pound (1 January 2026,
100 old pounds to one new) the pound's amounts count ten-thousandths of a new pound and show with two decimals; other
currencies store what they show. The table is read once at start; until then two and two.
"""
from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal
from typing import Optional

import asyncpg

_UNITS: dict[str, tuple[int, int]] = {}
_DEFAULT: dict[str, Optional[str]] = {"currency": None}


async def load(conn: asyncpg.Connection) -> None:
    rows = await conn.fetch("SELECT code, minor_unit, decimals FROM ref.currency")
    _UNITS.update({r["code"]: (r["minor_unit"], r["decimals"]) for r in rows})
    _DEFAULT["currency"] = await conn.fetchval(
        "SELECT m.currency FROM ref.market m WHERE m.is_default LIMIT 1")


def units(currency: Optional[str] = None) -> tuple[int, int]:
    """(minor_unit, decimals) of a currency, the default market's when none is named."""
    return _UNITS.get(currency or _DEFAULT["currency"] or "", (2, 2))


def major(minor: int, currency: Optional[str] = None) -> Decimal:
    """The amount in whole currency units, rounded half up to the decimals people pay in."""
    scale, decimals = units(currency)
    return (Decimal(int(minor)).scaleb(-scale)).quantize(Decimal(1).scaleb(-decimals), rounding=ROUND_HALF_UP)


def text(minor: int, currency: Optional[str] = None) -> str:
    """The amount with thousands separators; a whole amount shows no decimals."""
    v = major(minor, currency)
    return f"{v:,.0f}" if v == v.to_integral_value() else f"{v:,}"


def to_minor(value: Decimal | int | float | str, currency: Optional[str] = None) -> int:
    """An amount people typed (in whole units) as stored minor units."""
    scale, _ = units(currency)
    return int(Decimal(str(value)).scaleb(scale).quantize(Decimal(1), rounding=ROUND_HALF_UP))

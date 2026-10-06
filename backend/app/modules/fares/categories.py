"""Passenger categories (study 4.19): who counts as an adult, a child or an infant on a carrier, what each pays,
and which family offer a group earns.

Age bands and category fares are data: a carrier's own active rows win, the platform default applies until the
carrier sets its own. The category is worked out from the date of birth on the travel date, so a child who turns
twelve before the trip travels as an adult.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from typing import Optional

import asyncpg

from ...errors import ApiError

CATEGORIES = ("ADULT", "CHILD", "INFANT")


@dataclass(frozen=True)
class Band:
    category: str
    min_age: int
    max_age: Optional[int]          # exclusive
    seat_required: bool
    needs_adult: bool
    max_per_adult: Optional[int]

    def holds(self, age: int) -> bool:
        return self.min_age <= age and (self.max_age is None or age < self.max_age)

    def public(self) -> dict:
        return {"category": self.category, "min_age": self.min_age, "max_age": self.max_age,
                "seat_required": self.seat_required, "needs_adult": self.needs_adult, "max_per_adult": self.max_per_adult}


def age_on(birth: date, day: date) -> int:
    """Completed years on a day."""
    return day.year - birth.year - ((day.month, day.day) < (birth.month, birth.day))


async def bands(conn: asyncpg.Connection, company_id: int) -> dict[str, Band]:
    """The carrier's active bands, or the platform default when the carrier has none."""
    rows = await conn.fetch(
        """SELECT category, min_age, max_age, seat_required, needs_adult, max_per_adult, company_id
             FROM pricing.passenger_age_band WHERE status = 'ACTIVE' AND (company_id = $1 OR company_id IS NULL)""", company_id)
    own = [r for r in rows if r["company_id"] == company_id]
    use = own or [r for r in rows if r["company_id"] is None]
    out = {r["category"]: Band(r["category"], r["min_age"], r["max_age"], r["seat_required"], r["needs_adult"], r["max_per_adult"])
           for r in use}
    if "ADULT" not in out:
        out["ADULT"] = Band("ADULT", 12, None, True, False, None)
    return out


def category_for(b: dict[str, Band], birth: Optional[date], travel: date, claimed: Optional[str]) -> str:
    """Category of one traveller. A date of birth decides; without one only an adult may be booked."""
    if birth is None:
        if claimed in (None, "ADULT"):
            return "ADULT"
        raise ApiError(422, "BIRTH_DATE_REQUIRED", "children and infants need a date of birth")
    if birth > travel:
        raise ApiError(422, "BIRTH_DATE_INVALID", "the date of birth is after the travel date")
    age = age_on(birth, travel)
    found = next((c for c in ("INFANT", "CHILD", "ADULT") if c in b and b[c].holds(age)), "ADULT")
    if claimed and claimed != found:
        raise ApiError(422, "CATEGORY_MISMATCH", f"a traveller aged {age} travels as {found}", category=found, age=age)
    return found


async def category_fare(conn: asyncpg.Connection, company_id: int, route_id: Optional[int], category: str,
                        adult_fare: int, travel: date, currency: str) -> int:
    """Fare of a child or an infant: route rule, then carrier rule, then platform default; adults pay the adult fare."""
    if category == "ADULT":
        return adult_fare
    r = await conn.fetchrow(
        """SELECT method, value, currency FROM pricing.category_fare_rule
            WHERE status = 'ACTIVE' AND category = $2 AND valid @> $4::date
              AND (company_id = $1 OR company_id IS NULL) AND (route_id IS NULL OR route_id = $3)
            ORDER BY (route_id IS NOT NULL) DESC, (company_id IS NOT NULL) DESC, id DESC LIMIT 1""",
        company_id, category, route_id, travel)
    if r is None:
        return adult_fare
    if r["method"] == "FREE":
        return 0
    if r["method"] == "FIXED":
        if r["currency"] != currency:
            return adult_fare
        return min(int(r["value"]), adult_fare)
    return round_unit(adult_fare * float(r["value"]) / 100)


def round_unit(amount: float) -> int:
    return int(round(amount / 100.0)) * 100


@dataclass(frozen=True)
class OfferResult:
    offer_id: int
    code: str
    name: str
    discount: int


async def family_offer(conn: asyncpg.Connection, company_id: int, route_id: Optional[int], applies: str, travel: date,
                       members: int, adults: int, minors: int, fares: int, per_member_count: int) -> Optional[OfferResult]:
    """The best active offer of the carrier the group qualifies for, and the discount it gives on the fares."""
    rows = await conn.fetch(
        """SELECT id, code, name, discount_type, discount_value, max_discount FROM pricing.family_offer
            WHERE company_id = $1 AND status = 'ACTIVE' AND valid @> $3::date AND applies_to IN ($4, 'BOTH')
              AND (route_id IS NULL OR route_id = $2) AND min_members <= $5 AND min_adults <= $6 AND min_minors <= $7""",
        company_id, route_id, travel, applies, members, adults, minors)
    best: Optional[OfferResult] = None
    for r in rows:
        if r["discount_type"] == "PCT":
            d = round_unit(fares * float(r["discount_value"]) / 100)
        else:
            d = int(r["discount_value"]) * per_member_count
        if r["max_discount"]:
            d = min(d, r["max_discount"])
        d = min(d, fares)
        if d > 0 and (best is None or d > best.discount):
            best = OfferResult(r["id"], r["code"], r["name"], d)
    return best

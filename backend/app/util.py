"""Small shared helpers."""
import secrets
import string
from datetime import date, datetime
from typing import Any

_REF_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no 0/O/1/I to avoid misreading


def booking_ref() -> str:
    return "".join(secrets.choice(_REF_ALPHABET) for _ in range(6))


def ticket_no(booking_ref_: str, index: int) -> str:
    return f"{booking_ref_}-{index:02d}{secrets.choice(string.digits)}"



def iso(v: Any) -> Any:
    if isinstance(v, (datetime, date)):
        return v.isoformat()
    return v


def row_dict(row) -> dict:
    """asyncpg Record -> JSON-friendly dict (UUIDs and dates as strings)."""
    if row is None:
        return None
    out = {}
    for k, v in row.items():
        if isinstance(v, (datetime, date)):
            out[k] = v.isoformat()
        elif v.__class__.__name__ == "UUID":
            out[k] = str(v)
        else:
            out[k] = v
    return out


def rows(records) -> list[dict]:
    return [row_dict(r) for r in records]


def ticket_name(first: str | None, last: str | None, full: str) -> str:
    """Name printed on a ticket: first and last name only. The booking and manifests keep the full document name."""
    return " ".join(p for p in (first, last) if p) or full


def round_unit(amount) -> int:
    """Rounds minor units to a whole currency unit (100 minor units), halves up as the database's round() does: Python's
    round() takes a half to the even unit, so 2,550 and 2,650 would both become 2,600."""
    from decimal import ROUND_HALF_UP, Decimal
    return int((Decimal(str(amount)) / 100).quantize(Decimal(1), rounding=ROUND_HALF_UP)) * 100


def round_minor(amount) -> int:
    """Rounds an amount to whole minor units, halves up like round_unit (a rate per ton times a weight, a fare per km)."""
    from decimal import ROUND_HALF_UP, Decimal
    return int(Decimal(str(amount)).quantize(Decimal(1), rounding=ROUND_HALF_UP))

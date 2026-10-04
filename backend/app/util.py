"""Small shared helpers."""
import secrets
import string
from datetime import date, datetime
from typing import Any
from zoneinfo import ZoneInfo

LOCAL_TZ = ZoneInfo("Asia/Damascus")
_REF_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no 0/O/1/I to avoid misreading


def booking_ref() -> str:
    return "".join(secrets.choice(_REF_ALPHABET) for _ in range(6))


def ticket_no(booking_ref_: str, index: int) -> str:
    return f"{booking_ref_}-{index:02d}{secrets.choice(string.digits)}"


def local_date(dt: datetime) -> date:
    return dt.astimezone(LOCAL_TZ).date()


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

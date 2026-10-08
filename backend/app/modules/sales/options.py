"""Payment options a booking can be paid with, as platform administration opened them (fin.payment_method, 1056).

The database refuses a closed option when a booking is written; these helpers answer the same question earlier, with
a clear error, and work out when a reserved booking must be paid by.
"""
import json
from datetime import datetime, timedelta, timezone
from typing import Optional

import asyncpg

from ...errors import ApiError

RESERVED = ("PAY_LATER", "CARD", "INSTALLMENT", "FINANCING")      # paid after the booking is written
PROVIDER_OPTIONS = {"CARD": "HOSTED_CARD", "INSTALLMENT": "INSTALLMENT", "FINANCING": "FINANCING"}
PAY_METHOD = {"WALLET": "WALLET", "AGENCY_BALANCE": "WALLET", "CASH_COUNTER": "CASH", "PAY_LATER": "CASH",
              "CARD": "CARD", "INSTALLMENT": "INSTALLMENT", "FINANCING": "FINANCING"}


def _cfg(v) -> dict:
    return json.loads(v) if isinstance(v, str) else dict(v or {})


async def all_methods(conn: asyncpg.Connection) -> list[dict]:
    rows = await conn.fetch("SELECT * FROM fin.payment_method ORDER BY sort_order")
    return [{**dict(r), "config": _cfg(r["config"])} for r in rows]


async def method(conn: asyncpg.Connection, code: str) -> dict:
    r = await conn.fetchrow("SELECT * FROM fin.payment_method WHERE code = $1", code)
    if r is None:
        raise ApiError(422, "PAYMENT_METHOD_UNKNOWN", "unknown payment option")
    return {**dict(r), "config": _cfg(r["config"])}


async def require(conn: asyncpg.Connection, code: str, channel: str, amount: Optional[int] = None) -> dict:
    """The option, if it is open on this channel for this amount; otherwise the reason it is not."""
    m = await method(conn, code)
    if not m["enabled"]:
        raise ApiError(409, "PAYMENT_METHOD_DISABLED", "this way of paying is closed", option=code)
    if channel not in m["channels"]:
        raise ApiError(409, "PAYMENT_METHOD_DISABLED", "this way of paying is not offered here", option=code)
    if amount is not None and (amount < m["min_amount"] or (m["max_amount"] is not None and amount > m["max_amount"])):
        raise ApiError(422, "PAYMENT_AMOUNT_OUT_OF_RANGE", "the amount is outside this option's limits", option=code,
                       min_amount=m["min_amount"], max_amount=m["max_amount"])
    return m


def channel_of(channel_code: str) -> str:
    """The switch channel of a sales channel code."""
    if channel_code == "AGENCY":
        return "AGENCY"
    if channel_code == "COUNTER":
        return "COUNTER"
    return "APP" if channel_code.startswith("APP") else "WEB"


def pay_by(m: dict, departure: datetime, now: Optional[datetime] = None) -> datetime:
    """When a reserved booking must be paid: the option's hold, but never later than its cut-off before departure."""
    now = now or datetime.now(timezone.utc)
    cfg = m["config"]
    hold = timedelta(hours=float(cfg["hold_hours"])) if "hold_hours" in cfg else timedelta(minutes=float(cfg.get("hold_minutes", 20)))
    cutoff = timedelta(minutes=float(cfg["cutoff_minutes"])) if "cutoff_minutes" in cfg else timedelta(hours=float(cfg.get("cutoff_hours", 0)))
    latest = departure - cutoff
    if latest <= now + timedelta(minutes=5):
        raise ApiError(409, "TOO_LATE_TO_RESERVE", "this trip leaves too soon to pay later; pay now instead", option=m["code"])
    return min(now + hold, latest)


async def check_open_reservations(conn: asyncpg.Connection, m: dict, booker_party_id: int) -> None:
    """A passenger keeps only a few unpaid reservations at a time, so seats are not blocked by people who never come."""
    limit = int(m["config"].get("max_open", 0) or 0)
    if not limit:
        return
    open_ = await conn.fetchval(
        "SELECT count(*) FROM sales.booking WHERE booker_party_id = $1 AND status = 'PENDING_PAYMENT' AND pay_option = $2",
        booker_party_id, m["code"])
    if open_ >= limit:
        raise ApiError(409, "TOO_MANY_RESERVATIONS", "pay or cancel your open reservations first", limit=limit)


def eligible_trip(m: dict, trip_type: Optional[str]) -> bool:
    """Financing may be limited to some kinds of trip (pilgrimages, tours); an empty list means every trip."""
    allowed = m["config"].get("trip_types") or []
    return not allowed or (trip_type in allowed)


async def booking_options(conn: asyncpg.Connection, channel: str) -> list[dict]:
    """The options a checkout can offer on this channel, with the providers behind the electronic ones."""
    out = []
    for m in await all_methods(conn):
        if not m["enabled"] or channel not in m["channels"]:
            continue
        item = {"code": m["code"], "min_amount": m["min_amount"], "max_amount": m["max_amount"]}
        cfg = m["config"]
        if m["code"] == "PAY_LATER":
            item.update(hold_hours=cfg.get("hold_hours"), cutoff_minutes=cfg.get("cutoff_minutes"))
        if m["provider_adapter"]:
            rows = await conn.fetch(
                """SELECT code, name, min_amount, max_amount FROM fin.payment_provider
                    WHERE status = 'ACTIVE' AND adapter = $1 AND 'BOOKING' = ANY(purposes) ORDER BY sort_order""", m["provider_adapter"])
            if not rows:
                continue
            item["providers"] = [dict(r) for r in rows]
            if cfg.get("trip_types"):
                item["trip_types"] = cfg["trip_types"]
        out.append(item)
    return out

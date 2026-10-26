"""The penalty on a carrier for a cancelled trip, only where the regulators impose one (owner's decision; 1106).

The platform turns it on in its settings (trip.cancel_penalty) with the regulator's decision; the passengers are refunded
in full whatever it says (cancel_trip). The penalty is recorded with the trip and taken from the carrier's balance when
the balance covers it; otherwise it stays DUE and the carrier's next trip completion sets it off from the released
earnings (collect_due).
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from decimal import ROUND_HALF_UP, Decimal
from typing import Optional

import asyncpg

from ...errors import ApiError
from ...ledger import company_wallet, platform_wallet, post_txn
from ..notify.outbox import emit


async def setting(conn: asyncpg.Connection) -> dict:
    raw = await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'trip.cancel_penalty'")
    return (json.loads(raw) if isinstance(raw, str) else raw) or {"enabled": False}


def _amounts(rule: dict, bookings: list[dict]) -> tuple[int, list[int]]:
    """The penalty and each booking's share of it (by fares; the last share takes the rounding)."""
    fares = sum(b["fares"] for b in bookings)
    value = Decimal(str(rule["value"]))
    if rule["basis"] == "PERCENT_OF_FARES":
        total = int((Decimal(fares) * value / 100).quantize(Decimal(1), ROUND_HALF_UP))
    elif rule["basis"] == "PER_TICKET":
        total = int(value) * sum(b["tickets"] for b in bookings)
    else:
        total = int(value)
    shares, given = [], 0
    for i, b in enumerate(bookings):
        share = total - given if i == len(bookings) - 1 else (total * b["fares"] // fares if fares else 0)
        shares.append(share)
        given += share
    return total, shares


async def charge(conn: asyncpg.Connection, trip: asyncpg.Record, bookings: list[dict], user_id: int) -> Optional[dict]:
    """Records the penalty of a cancelled trip when the setting is on and applies to it; the caller holds the system
    scope. bookings: the refunded ones, each {booking_id, fares, tickets, wallet_id}."""
    rule = await setting(conn)
    if not rule.get("enabled"):
        return None
    hours = rule.get("within_hours")
    if hours is not None and (trip["departure_at"] - datetime.now(timezone.utc)).total_seconds() > float(hours) * 3600:
        return None
    if rule["payee"] == "PASSENGERS" and not bookings:
        return None
    total, shares = _amounts(rule, bookings)
    if total <= 0:
        return None
    share_rows = [{"booking_id": b["booking_id"], "wallet_id": b["wallet_id"], "amount": s}
                  for b, s in zip(bookings, shares) if s > 0 and b["wallet_id"]] if rule["payee"] == "PASSENGERS" else []
    pid = await conn.fetchval(
        """INSERT INTO ops.trip_cancel_penalty (trip_id, company_id, currency, amount, basis, rate, payee, payee_party_id, shares, legal_ref)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10) RETURNING id""",
        trip["id"], trip["company_id"], trip["currency"], total, rule["basis"], Decimal(str(rule["value"])), rule["payee"],
        rule.get("authority_party_id") if rule["payee"] == "AUTHORITY" else None, json.dumps(share_rows), rule["legal_ref"].strip())
    collected = await _collect(conn, pid, user_id)
    await emit(conn, "trip.cancel_penalty", "trip", trip["id"], {
        "trip_no": trip["trip_no"], "amount": total, "legal_ref": rule["legal_ref"].strip(), "collected": collected},
        company_id=trip["company_id"])
    return {"amount": total, "payee": rule["payee"], "legal_ref": rule["legal_ref"].strip(), "status": "COLLECTED" if collected else "DUE"}


async def _collect(conn: asyncpg.Connection, penalty_id: int, user_id: Optional[int]) -> bool:
    """Takes a DUE penalty from the carrier's balance in one transaction, or leaves it DUE when the balance is short."""
    p = await conn.fetchrow("SELECT * FROM ops.trip_cancel_penalty WHERE id = $1 FOR UPDATE", penalty_id)
    if p is None or p["status"] != "DUE":
        return False
    carrier = await company_wallet(conn, p["company_id"], p["currency"])
    if p["payee"] == "PASSENGERS":
        shares = json.loads(p["shares"]) if isinstance(p["shares"], str) else p["shares"]
        credits = [(s["wallet_id"], "CR", s["amount"]) for s in shares]
        rest = p["amount"] - sum(s["amount"] for s in shares)
        if rest > 0:                                        # a booking whose paying wallet is unknown: the platform holds it
            credits.append(((await platform_wallet(conn, "PLATFORM", p["currency"]))["id"], "CR", rest))
    elif p["payee"] == "AUTHORITY":
        credits = [((await company_wallet(conn, p["payee_party_id"], p["currency"], label="Authority account"))["id"], "CR", p["amount"])]
    else:
        credits = [((await platform_wallet(conn, "PLATFORM", p["currency"]))["id"], "CR", p["amount"])]
    try:
        async with conn.transaction():                      # a savepoint: a short balance leaves the penalty DUE
            await post_txn(conn, "CANCEL_PENALTY", p["currency"], f"penalty:{p['id']}", [(carrier["id"], "DR", p["amount"]), *credits],
                           ref_type="trip_cancel_penalty", ref_id=p["id"], user_id=user_id, memo=p["legal_ref"][:120])
    except ApiError as e:
        if e.code != "INSUFFICIENT_BALANCE":
            raise
        return False
    await conn.execute("UPDATE ops.trip_cancel_penalty SET status = 'COLLECTED', collected_at = now() WHERE id = $1", p["id"])
    return True


async def collect_due(conn: asyncpg.Connection, company_id: int, user_id: Optional[int]) -> int:
    """Sets off the carrier's DUE penalties from its balance, oldest first, while the balance covers them (called when a
    trip completes and its earnings are released). Returns the amount collected."""
    collected = 0
    for p in await conn.fetch("SELECT id, amount FROM ops.trip_cancel_penalty WHERE company_id = $1 AND status = 'DUE' ORDER BY id",
                              company_id):
        if not await _collect(conn, p["id"], user_id):
            break
        collected += p["amount"]
    return collected

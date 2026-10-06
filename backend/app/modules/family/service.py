"""Family accounts (study 4.20): the head registers the family, pays for it, buys for all of it, approves the accounts
members open on their own devices, and limits when and where each member may travel on the family's money.

The database keeps families private (row-level security: the head sees everything, a linked member only their own
record and rules). The money moves through the ledger like any other payment; every charge made on behalf of a member
is also written to iam.family_spend, against which the limits are checked.
"""
from __future__ import annotations

import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Optional
from zoneinfo import ZoneInfo

import asyncpg

from ... import crypto, db
from ...config import get_settings
from ...errors import ApiError, not_found
from ...ledger import post_txn, user_wallet

LOCAL = ZoneInfo("Asia/Damascus")
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"          # no 0/O or 1/I to misread
INVITE_HOURS = 24
FUNDING = ("OWN", "HEAD_WALLET", "FAMILY_ACCOUNT")


@dataclass
class Membership:
    family: asyncpg.Record
    role: str                                # HEAD or MEMBER
    member: Optional[asyncpg.Record]         # the caller's own member row


async def membership(conn: asyncpg.Connection, party_id: int) -> Optional[Membership]:
    """The family the caller heads, or the one they belong to through a linked account."""
    f = await conn.fetchrow("SELECT * FROM iam.family WHERE head_party_id = $1 AND status = 'ACTIVE'", party_id)
    if f:
        m = await conn.fetchrow("SELECT * FROM iam.family_member WHERE family_id = $1 AND relation = 'SELF'", f["id"])
        return Membership(f, "HEAD", m)
    m = await conn.fetchrow(
        """SELECT m.* FROM iam.family_member m JOIN iam.family f ON f.id = m.family_id
            WHERE m.party_id = $1 AND m.account_status = 'LINKED' AND m.status = 'ACTIVE' AND f.status = 'ACTIVE'""", party_id)
    if m is None:
        return None
    f = await conn.fetchrow("SELECT * FROM iam.family WHERE id = $1", m["family_id"])
    return Membership(f, "MEMBER", m)


async def head_family(conn: asyncpg.Connection, party_id: int) -> asyncpg.Record:
    f = await conn.fetchrow("SELECT * FROM iam.family WHERE head_party_id = $1 AND status = 'ACTIVE'", party_id)
    if f is None:
        raise ApiError(404, "NO_FAMILY", "create your family first")
    return f


async def member_by_uid(conn: asyncpg.Connection, family_id: int, uid) -> asyncpg.Record:
    m = await conn.fetchrow("SELECT * FROM iam.family_member WHERE family_id = $1 AND uid = $2 AND status = 'ACTIVE'", family_id, uid)
    if m is None:
        raise not_found("family member")
    return m


def full_name(m) -> str:
    return " ".join(p for p in (m["first_name"], m["father_name"], m["grandfather_name"], m["last_name"]) if p)


def code_hash(code: str) -> bytes:
    return hmac.new(get_settings().signing_secret.encode(), b"family-invite:" + code.upper().encode(), hashlib.sha256).digest()


def new_code() -> str:
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(8))


def device_hash(value: str) -> bytes:
    return hmac.new(get_settings().signing_secret.encode(), b"device:" + value.encode(), hashlib.sha256).digest()


# ------------------------------------------------------------------ money

async def family_wallet(conn: asyncpg.Connection, family: asyncpg.Record, currency: str) -> asyncpg.Record:
    """The family trips account; created on first use, owned by the head."""
    if family["trips_wallet_id"]:
        w = await conn.fetchrow("SELECT * FROM fin.wallet WHERE id = $1", family["trips_wallet_id"])
        if w and w["currency"] == currency:
            return w
    w = await conn.fetchrow(
        "SELECT * FROM fin.wallet WHERE owner_party_id = $1 AND wallet_type = 'FAMILY' AND currency = $2", family["head_party_id"], currency)
    if w is None:
        w = await conn.fetchrow(
            """INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency)
               VALUES ($1, 'FAMILY', 'Family trips account', $2) RETURNING *""", family["head_party_id"], currency)
    if family["trips_wallet_id"] is None:
        await conn.execute("UPDATE iam.family SET trips_wallet_id = $2 WHERE id = $1", family["id"], w["id"])
    return w


async def funding_wallet(conn: asyncpg.Connection, family: asyncpg.Record, source: str, currency: str) -> asyncpg.Record:
    if source == "FAMILY_ACCOUNT":
        return await family_wallet(conn, family, currency)
    return await user_wallet(conn, family["head_party_id"], currency)


async def transfer(conn: asyncpg.Connection, ctx: db.Context, family: asyncpg.Record, amount: int, currency: str,
                   to_family: bool, key: str, user_id: int) -> dict:
    """Moves money between the head's wallet and the family trips account."""
    async with db.system_scope(conn, ctx):
        head = await user_wallet(conn, family["head_party_id"], currency)
        fam = await family_wallet(conn, family, currency)
        src, dst = (head, fam) if to_family else (fam, head)
        if src["balance"] - src["hold_balance"] < amount:
            raise ApiError(402, "INSUFFICIENT_BALANCE", "balance is not enough", balance=src["balance"] - src["hold_balance"])
        txn = await post_txn(conn, "FAMILY_TOPUP" if to_family else "FAMILY_WITHDRAW", currency, key,
                             [(src["id"], "DR", amount), (dst["id"], "CR", amount)], ref_type="family", ref_id=family["id"],
                             user_id=user_id, memo="family trips account")
        balance = await conn.fetchval("SELECT balance FROM fin.wallet WHERE id = $1", fam["id"])
    return {"txn_id": txn, "family_account_balance": balance}


# ------------------------------------------------------------------ rules and limits

@dataclass(frozen=True)
class Journey:
    """What a purchase is for, to check against a member's rules."""
    departs: Optional[datetime] = None       # trips: departure; passes: None (time windows apply when riding)
    from_city_id: Optional[int] = None
    to_city_id: Optional[int] = None
    line_id: Optional[int] = None


async def check_rules(conn: asyncpg.Connection, member: asyncpg.Record, journey: Journey) -> None:
    """A member travelling on the family's money must match one rule of each type the head has set."""
    rules = await conn.fetch("SELECT * FROM iam.family_travel_rule WHERE member_id = $1 AND active", member["id"])
    by_type: dict[str, list] = {}
    for r in rules:
        by_type.setdefault(r["rule_type"], []).append(r)
    if journey.departs and "TIME_WINDOW" in by_type:
        local = journey.departs.astimezone(LOCAL)
        ok = any((not r["days"] or local.isoweekday() in r["days"]) and r["start_time"] <= local.time() <= r["end_time"]
                 for r in by_type["TIME_WINDOW"])
        if not ok:
            raise ApiError(403, "FAMILY_TIME_NOT_ALLOWED", "this trip is outside the times allowed for this family member")
    if journey.from_city_id and "ROUTE" in by_type:
        pair = (journey.from_city_id, journey.to_city_id)
        ok = any(pair == (r["from_city_id"], r["to_city_id"]) or (r["both_ways"] and pair == (r["to_city_id"], r["from_city_id"]))
                 for r in by_type["ROUTE"])
        if not ok:
            raise ApiError(403, "FAMILY_ROUTE_NOT_ALLOWED", "this route is not allowed for this family member")
    if journey.line_id and "LINE" in by_type and not any(r["line_id"] == journey.line_id for r in by_type["LINE"]):
        raise ApiError(403, "FAMILY_LINE_NOT_ALLOWED", "this line is not allowed for this family member")


async def check_limits(conn: asyncpg.Connection, member: asyncpg.Record, amount: int) -> None:
    if member["per_trip_limit"] and amount > member["per_trip_limit"]:
        raise ApiError(403, "FAMILY_LIMIT_PER_TRIP", "above the amount allowed per purchase", limit=member["per_trip_limit"])
    now = datetime.now(LOCAL)
    day0 = now.replace(hour=0, minute=0, second=0, microsecond=0)
    month0 = day0.replace(day=1)
    spent = await conn.fetchrow(
        """SELECT coalesce(sum(CASE WHEN ref_type = 'refund' THEN -amount ELSE amount END) FILTER (WHERE created_at >= $2), 0) AS day,
                  coalesce(sum(CASE WHEN ref_type = 'refund' THEN -amount ELSE amount END) FILTER (WHERE created_at >= $3), 0) AS month
             FROM iam.family_spend WHERE member_id = $1""", member["id"], day0, month0)
    if member["daily_limit"] and spent["day"] + amount > member["daily_limit"]:
        raise ApiError(403, "FAMILY_LIMIT_DAILY", "above the daily amount allowed", limit=member["daily_limit"], spent=spent["day"])
    if member["monthly_limit"] and spent["month"] + amount > member["monthly_limit"]:
        raise ApiError(403, "FAMILY_LIMIT_MONTHLY", "above the monthly amount allowed", limit=member["monthly_limit"],
                       spent=spent["month"])


async def log_spend(conn: asyncpg.Connection, family_id: int, member_id: int, source: str, amount: int, currency: str,
                    ref_type: str, ref_id: int, user_id: int, txn_id: Optional[int]) -> None:
    await conn.execute(
        """INSERT INTO iam.family_spend (family_id, member_id, source, amount, currency, ref_type, ref_id, initiated_by, ledger_txn_id)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)""", family_id, member_id, source, amount, currency, ref_type, ref_id,
        user_id, txn_id)


# ------------------------------------------------------------------ members

async def seal_document(conn: asyncpg.Connection, id_type: Optional[str], id_no: Optional[str], nationality: str):
    """Encrypted document number, its blind index and the masked last four (or nothing)."""
    if not id_no:
        return None, None, None, None
    fc = await crypto.cipher(conn)
    sealed = fc.encrypt(id_no, "iam.family_member.id_no")
    return sealed.ciphertext, fc.blind_index(id_no, f"{id_type}:{nationality}"), crypto.last4(id_no), sealed.key_id


async def member_document(conn: asyncpg.Connection, m: asyncpg.Record) -> Optional[str]:
    """The member's document number in clear, to copy it onto a booking (read in the platform scope by the caller)."""
    if not m["id_no_enc"]:
        return None
    fc = await crypto.cipher(conn)
    return fc.decrypt(bytes(m["id_no_enc"]), m["enc_key_id"], "iam.family_member.id_no")


def member_view(m: asyncpg.Record, today: Optional[date] = None) -> dict:
    from ..fares.categories import age_on
    today = today or date.today()
    return {"uid": str(m["uid"]), "relation": m["relation"], "first_name": m["first_name"], "father_name": m["father_name"],
            "grandfather_name": m["grandfather_name"], "last_name": m["last_name"], "full_name": full_name(m),
            "nationality": m["nationality"], "birth_date": m["birth_date"].isoformat(), "age": age_on(m["birth_date"], today),
            "gender": m["gender"], "id_type": m["id_type"], "id_last4": m["id_no_last4"],
            "passport_expiry": m["passport_expiry"].isoformat() if m["passport_expiry"] else None, "mobile": m["mobile"],
            "account_status": m["account_status"], "funding": m["funding"], "per_trip_limit": m["per_trip_limit"],
            "daily_limit": m["daily_limit"], "monthly_limit": m["monthly_limit"]}


async def link_account(conn: asyncpg.Connection, ctx: db.Context, req: asyncpg.Record, funding: str, user_id: int) -> None:
    """Approves a member's own account: the member record and whatever was bought for it move to that account's person."""
    async with db.system_scope(conn, ctx):
        m = await conn.fetchrow("SELECT * FROM iam.family_member WHERE id = $1", req["member_id"])
        old, new = m["party_id"], req["requester_party_id"]
        if await conn.fetchval("SELECT 1 FROM iam.family_member WHERE party_id = $1 AND status = 'ACTIVE' AND id <> $2", new, m["id"]):
            raise ApiError(409, "ALREADY_IN_FAMILY", "this account already belongs to a family")
        if old != new:
            await conn.execute("UPDATE sales.subscription SET party_id = $2 WHERE party_id = $1 AND family_id = $3", old, new, m["family_id"])
            await conn.execute("UPDATE sales.passenger SET party_id = $1 WHERE family_member_id = $2", new, m["id"])
        await conn.execute(
            """UPDATE iam.family_member SET party_id = $2, account_status = 'LINKED', linked_user_id = $3, funding = $4
                WHERE id = $1""", m["id"], new, req["requester_user_id"], funding)
        await conn.execute(
            "UPDATE iam.family_link_request SET status = 'APPROVED', decided_at = now(), decided_by = $2, funding = $3 WHERE id = $1",
            req["id"], user_id, funding)


def invite_expiry() -> datetime:
    return datetime.now(timezone.utc) + timedelta(hours=INVITE_HOURS)

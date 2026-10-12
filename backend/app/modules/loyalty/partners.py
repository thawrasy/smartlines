"""Points redeemed at partners under the agreements the platform records with each of them (migration 1107).

An agreement says how many points buy how much at the partner and the percentage of that the platform pays the partner
when it honours the voucher. The member turns points into a voucher (the points leave at once); the partner honours it
through its API client, or the platform does for it; the platform then owes the partner its share, posted from the
loyalty expense wallet to the partner's wallet, and pays it with the partner's statement (drafted, approved and paid by
three different people). Unused vouchers give the points back when they expire or are cancelled.
"""
from __future__ import annotations

import json
import secrets
import uuid
from datetime import date

import asyncpg

from ... import db
from ...crypto import cipher
from ...errors import ApiError, not_found
from ...ledger import loyalty_wallet, partner_wallet, platform_wallet, post_txn

_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"          # Crockford base32: no I, L, O or U to misread
CODE_COLUMN = "pricing.reward_voucher.code"


def new_code() -> str:
    """MV-XXXX-XXXX-XXXX-XXXX: 80 random bits, read out or typed at the partner's till."""
    raw = "".join(secrets.choice(_ALPHABET) for _ in range(16))
    return "MV-" + "-".join(raw[i:i + 4] for i in range(0, 16, 4))


async def code_hash(conn: asyncpg.Connection, code: str) -> bytes:
    """The keyed hash a voucher is found by; dashes, spaces and case do not matter."""
    return (await cipher(conn)).blind_index(code, "voucher")


async def issue(conn: asyncpg.Connection, party_id: int, user_id: int, agreement: uuid.UUID, points: int, key: str) -> dict:
    """The member spends points for a voucher at the agreed rate. The same key returns the same voucher and code."""
    c = await cipher(conn)
    code = new_code()
    sealed = c.encrypt(code, CODE_COLUMN)
    out = json.loads(await conn.fetchval(
        "SELECT pricing.redeem_at_partner($1, $2, $3, $4, $5, $6, $7, $8)::text",
        party_id, user_id, agreement, points, key, c.blind_index(code, "voucher"), sealed.ciphertext, sealed.key_id))
    if out.get("replayed"):
        row = await conn.fetchrow("SELECT code_enc, code_key_id FROM pricing.reward_voucher WHERE id = $1", out["voucher_id"])
        code = c.decrypt(bytes(row["code_enc"]), row["code_key_id"], CODE_COLUMN) if row["code_enc"] else None
    out["code"] = code
    out.pop("voucher_id", None)
    return out


async def my_vouchers(conn: asyncpg.Connection, user_id: int, limit: int = 20) -> list[dict]:
    c = await cipher(conn)
    rs = await conn.fetch(
        """SELECT v.uid, v.points, v.value, v.currency, v.status, v.expires_at, v.used_at, v.created_at, v.code_enc, v.code_key_id,
                  p.legal_name AS partner
             FROM pricing.reward_voucher v LEFT JOIN pricing.loyalty_partner lp ON lp.id = v.loyalty_partner_id
             LEFT JOIN iam.party p ON p.id = lp.party_id
            WHERE v.user_id = $1 AND v.agreement_id IS NOT NULL ORDER BY v.id DESC LIMIT $2""", user_id, limit)
    out = []
    for r in rs:
        d = {k: r[k] for k in ("points", "value", "currency", "status", "partner")}
        d["voucher"] = str(r["uid"])
        for k in ("expires_at", "used_at", "created_at"):
            d[k] = r[k].isoformat() if r[k] else None
        # the code is shown only while the voucher can still be used
        d["code"] = (c.decrypt(bytes(r["code_enc"]), r["code_key_id"], CODE_COLUMN)
                     if r["status"] == "ISSUED" and r["code_enc"] else None)
        out.append(d)
    return out


async def partner_by_client(conn: asyncpg.Connection, client_id: int) -> asyncpg.Record:
    row = await conn.fetchrow(
        """SELECT lp.id, lp.party_id, lp.status, p.legal_name FROM pricing.loyalty_partner lp JOIN iam.party p ON p.id = lp.party_id
            WHERE lp.api_client_id = $1""", client_id)
    if row is None:
        raise ApiError(403, "PARTNER_NOT_CONFIGURED", "this client is not linked to a loyalty partner")
    return row


async def check(conn: asyncpg.Connection, partner_id: int, code: str) -> dict:
    """What a voucher is worth at this partner, before the sale; says nothing about vouchers of other partners."""
    v = await conn.fetchrow(
        """SELECT uid, value, currency, status, expires_at, used_at FROM pricing.reward_voucher
            WHERE code_hash = $1 AND loyalty_partner_id = $2""", await code_hash(conn, code), partner_id)
    if v is None:
        raise ApiError(404, "VOUCHER_UNKNOWN", "no voucher with this code at this partner")
    from datetime import datetime, timezone
    usable = v["status"] == "ISSUED" and v["expires_at"] > datetime.now(timezone.utc)
    return {"voucher": str(v["uid"]), "value": v["value"], "currency": v["currency"], "usable": usable,
            "status": v["status"] if v["status"] != "ISSUED" or usable else "EXPIRED", "expires_at": v["expires_at"].isoformat(),
            "used_at": v["used_at"].isoformat() if v["used_at"] else None}


async def accept(conn: asyncpg.Connection, ctx: db.Context, partner_id: int, code: str, partner_ref: str | None,
                 user_id: int | None, client_id: int | None) -> dict:
    """The partner honours the voucher; what the platform owes it is posted to its wallet in the same transaction."""
    async with db.system_scope(conn, ctx):
        out = json.loads(await conn.fetchval("SELECT pricing.accept_voucher($1, $2, $3, $4, $5)::text", partner_id,
                                             await code_hash(conn, code), partner_ref, user_id, client_id))
        if out["payable"] > 0:
            source = await loyalty_wallet(conn, out["currency"])
            target = await partner_wallet(conn, out["partner_party_id"], out["currency"])
            await post_txn(conn, "LOYALTY_PARTNER", out["currency"], f"partner-redemption:{out['redemption_id']}",
                           [(source["id"], "DR", out["payable"]), (target["id"], "CR", out["payable"])],
                           ref_type="partner_redemption", ref_id=out["redemption_id"], user_id=user_id,
                           memo=f"Voucher honoured by {out['partner']}")
    return {k: out[k] for k in ("voucher", "points", "value", "payable", "currency")} | {"redemption": out["redemption_id"]}


async def partner_redemptions(conn: asyncpg.Connection, partner_id: int, start: date, end: date) -> list[dict]:
    rs = await conn.fetch(
        """SELECT r.id, v.uid AS voucher, r.points, r.value, r.payable, r.currency, r.partner_ref, r.redeemed_at,
                  (SELECT s.uid FROM pricing.loyalty_settlement_line l JOIN pricing.loyalty_settlement s ON s.id = l.settlement_id
                    WHERE l.redemption_id = r.id) AS settlement
             FROM pricing.partner_redemption r LEFT JOIN pricing.reward_voucher v ON v.id = r.voucher_id
            WHERE r.loyalty_partner_id = $1 AND r.redeemed_at >= $2 AND r.redeemed_at < $3::date + 1 ORDER BY r.id""",
        partner_id, start, end)
    return [{"redemption": r["id"], "voucher": str(r["voucher"]) if r["voucher"] else None, "points": r["points"], "value": r["value"],
             "payable": r["payable"], "currency": r["currency"], "reference": r["partner_ref"],
             "redeemed_at": r["redeemed_at"].isoformat(), "settlement": str(r["settlement"]) if r["settlement"] else None} for r in rs]


async def open_settlement(conn: asyncpg.Connection, partner_id: int, currency: str, start: date, end: date, user_id: int) -> dict:
    out = json.loads(await conn.fetchval("SELECT pricing.open_loyalty_settlement($1, $2, $3, $4, $5)::text",
                                         partner_id, currency, start, end, user_id))
    uid = await conn.fetchval("SELECT uid FROM pricing.loyalty_settlement WHERE id = $1", out["settlement_id"])
    return {"settlement": str(uid), "redemptions": out["redemptions"], "value": out["value"], "payable": out["payable"],
            "currency": currency}


async def pay_settlement(conn: asyncpg.Connection, ctx: db.Context, settlement: uuid.UUID, bank_ref: str, user_id: int) -> dict:
    """A third person records the bank transfer of an approved statement; the partner's wallet is debited by it."""
    s = await conn.fetchrow(
        """SELECT s.*, lp.party_id FROM pricing.loyalty_settlement s JOIN pricing.loyalty_partner lp ON lp.id = s.loyalty_partner_id
            WHERE s.uid = $1 FOR UPDATE OF s""", settlement)
    if s is None:
        raise not_found("settlement")
    if s["status"] != "APPROVED":
        raise ApiError(409, "SETTLEMENT_NOT_APPROVED", "a statement is paid once approved")
    if user_id in (s["created_by"], s["approved_by"]):
        raise ApiError(403, "FOUR_EYES", "whoever drew up or approved a statement does not pay it")
    txn = None
    async with db.system_scope(conn, ctx):
        if s["payable"] > 0:
            source = await partner_wallet(conn, s["party_id"], s["currency"])
            clearing = await platform_wallet(conn, "BANK_CLEARING", s["currency"])
            txn = await post_txn(conn, "PAYOUT", s["currency"], f"loyalty-settlement:{s['id']}:paid",
                                 [(source["id"], "DR", s["payable"]), (clearing["id"], "CR", s["payable"])],
                                 ref_type="loyalty_settlement", ref_id=s["id"], user_id=user_id, memo=f"Bank transfer {bank_ref}")
    await conn.execute(
        """UPDATE pricing.loyalty_settlement SET status = 'PAID', paid_by = $2, paid_at = now(), bank_ref = $3, ledger_txn_id = $4
            WHERE id = $1""", s["id"], user_id, bank_ref, txn)
    return {"settlement": str(settlement), "status": "PAID", "payable": s["payable"], "currency": s["currency"]}

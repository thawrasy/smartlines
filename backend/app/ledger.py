"""Double-entry ledger helpers on top of fin.ledger_txn / fin.ledger_entry.

The database enforces the invariants (balanced transactions, immutable entries, no negative
balances, idempotency); these helpers only find wallets and write the rows.
"""
from typing import Iterable, Optional

import asyncpg

from .errors import ApiError


async def platform_party_id(conn: asyncpg.Connection) -> int:
    pid = await conn.fetchval(
        "SELECT id FROM iam.party WHERE party_type = 'COMPANY' AND legal_name = 'Masslak Platform' ORDER BY id LIMIT 1")
    if pid is None:
        raise ApiError(500, "PLATFORM_NOT_SEEDED", "platform party is missing")
    return pid


async def counted(conn: asyncpg.Connection, w: asyncpg.Record) -> dict:
    """The wallet row with the balance that counts. A shared (DEFERRED) wallet's stored balance lags its newest entries
    by a few seconds; fin.wallet_balance adds the entries the roll-up has not folded in yet (CAPACITY_MODEL.md)."""
    out = dict(w)
    if out.get("balance_mode") == "DEFERRED":
        out["balance"] = await conn.fetchval("SELECT fin.wallet_balance($1)", out["id"])
    return out


async def platform_wallet(conn: asyncpg.Connection, wallet_type: str, currency: str) -> dict:
    w = await conn.fetchrow(
        """SELECT w.* FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
            WHERE p.legal_name = 'Masslak Platform' AND p.party_type = 'COMPANY'
              AND w.wallet_type = $1 AND w.currency = $2""", wallet_type, currency)
    if w is None:
        raise ApiError(500, "WALLET_MISSING", f"platform {wallet_type} wallet missing for {currency}")
    return await counted(conn, w)


async def owned_wallet(conn: asyncpg.Connection, owner_party_id: int, wallet_type: str, currency: str,
                        insert_sql: str, *args) -> asyncpg.Record:
    """Finds the owner's wallet of this type and currency, opening it on first use. Two first uses at the same moment
    both reach the insert: the second waits for the first, does nothing (wallet_owner_uq), and reads the first one's
    wallet, so neither request fails (review of release 1.47.0, report 3)."""
    find = "SELECT * FROM fin.wallet WHERE owner_party_id = $1 AND wallet_type = $2 AND currency = $3"
    w = await conn.fetchrow(find, owner_party_id, wallet_type, currency)
    if w is None:
        w = await conn.fetchrow(insert_sql + " ON CONFLICT (owner_party_id, wallet_type, currency) "
                                "WHERE owner_party_id IS NOT NULL DO NOTHING RETURNING *", *args)
        if w is None:
            w = await conn.fetchrow(find, owner_party_id, wallet_type, currency)
    return w


async def user_wallet(conn: asyncpg.Connection, party_id: int, currency: str) -> asyncpg.Record:
    return await owned_wallet(
        conn, party_id, "USER", currency,
        "INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency) VALUES ($1, 'USER', 'Passenger wallet', $2)",
        party_id, currency)


async def company_wallet(conn: asyncpg.Connection, company_id: int, currency: str,
                         label: str = "Carrier wallet") -> dict:
    w = await owned_wallet(
        conn, company_id, "COMPANY", currency,
        "INSERT INTO fin.wallet (owner_party_id, company_id, wallet_type, label, currency) VALUES ($1, $1, 'COMPANY', $3, $2)",
        company_id, currency, label)
    return await counted(conn, w)


async def cash_wallet(conn: asyncpg.Connection, company_id: int, currency: str) -> dict:
    """The carrier's cash wallet (study 6.5): debited by each cash sale at its counter, so a negative balance is cash it
    holds for the platform; credited when its earnings are set off and when it remits. Exact balance (IMMEDIATE)."""
    w = await owned_wallet(
        conn, company_id, "CASH_COLLECT", currency,
        """INSERT INTO fin.wallet (owner_party_id, company_id, wallet_type, label, currency, allow_negative, balance_mode)
           VALUES ($1, $1, 'CASH_COLLECT', 'Counter cash', $2, true, 'IMMEDIATE')""", company_id, currency)
    return dict(w)


async def post_txn(conn: asyncpg.Connection, txn_type: str, currency: str, idempotency_key: str,
                   entries: Iterable[tuple[int, str, int]], *, ref_type: Optional[str] = None,
                   ref_id: Optional[int] = None, user_id: Optional[int] = None, memo: Optional[str] = None) -> int:
    """Writes one balanced transaction; entries are (wallet_id, 'DR'|'CR', amount)."""
    # an entry of a passenger or family wallet updates its balance, and a debit of a shared wallet locks it; touching
    # wallets in ascending id keeps two transactions that move money between the same wallets in opposite directions
    # from deadlocking (lock order: docs/database/STANDARDS.md). Credits to shared wallets take no lock at all.
    entries = sorted((e for e in entries if e[2] > 0), key=lambda e: e[0])
    txn_id = await conn.fetchval(
        """INSERT INTO fin.ledger_txn (txn_type, currency, ref_type, ref_id, idempotency_key, memo, created_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id""",
        txn_type, currency, ref_type, ref_id, idempotency_key, memo, user_id)
    try:
        await conn.executemany(
            "INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) VALUES ($1, $2, $3, $4)",
            [(txn_id, w, d, a) for w, d, a in entries])
    except asyncpg.CheckViolationError:
        raise ApiError(402, "INSUFFICIENT_BALANCE", "wallet balance is not enough")
    return txn_id

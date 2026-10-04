"""SQL for payouts. Row-level security limits a company to its own accounts, withdrawals and statements."""
import uuid
from datetime import date
from typing import Optional

import asyncpg


async def bank_accounts(conn: asyncpg.Connection, party_id: Optional[int] = None, unverified_only: bool = False):
    return await conn.fetch(
        """SELECT a.id, a.uid, a.bank_name, a.holder_name, a.iban_last4, a.currency, a.verified, a.status, a.created_at,
                  p.legal_name AS company_name
             FROM iam.bank_account a JOIN iam.party p ON p.id = a.party_id
            WHERE ($1::bigint IS NULL OR a.party_id = $1) AND (NOT $2 OR (NOT a.verified AND a.status = 'ACTIVE'))
            ORDER BY a.created_at DESC""", party_id, unverified_only)


async def bank_account_by_uid(conn, account_uid: uuid.UUID) -> Optional[asyncpg.Record]:
    return await conn.fetchrow("SELECT * FROM iam.bank_account WHERE uid = $1", account_uid)


async def insert_bank_account(conn, party_id: int, bank_name: str, holder: str, enc: bytes, bidx: bytes, last4: str,
                              key_id: int, currency: str) -> asyncpg.Record:
    return await conn.fetchrow(
        """INSERT INTO iam.bank_account (party_id, bank_name, holder_name, iban_enc, iban_bidx, iban_last4, enc_key_id, currency)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id, uid""",
        party_id, bank_name, holder, enc, bidx, last4, key_id, currency)


async def verify_bank_account(conn, account_id: int, user_id: int) -> None:
    await conn.execute("UPDATE iam.bank_account SET verified = true, verified_by = $2, verified_at = now() WHERE id = $1",
                       account_id, user_id)


WITHDRAWAL_COLS = """w.id, w.uid, w.amount, w.currency, w.status, w.needs_second, w.created_at, w.decided_at, w.paid_at,
                     w.bank_ref, w.reject_reason, w.requested_by, w.approved_by, w.second_approver,
                     a.bank_name, a.iban_last4, a.uid AS bank_account_uid, p.legal_name AS company_name,
                     rp.legal_name AS requested_by_name"""
WITHDRAWAL_FROM = """fin.withdrawal_request w JOIN iam.bank_account a ON a.id = w.bank_account_id
                     JOIN iam.party p ON p.id = w.company_id
                     JOIN iam.app_user ru ON ru.id = w.requested_by JOIN iam.party rp ON rp.id = ru.party_id"""


async def withdrawals(conn, company_id: Optional[int] = None, status: Optional[str] = None):
    return await conn.fetch(
        f"""SELECT {WITHDRAWAL_COLS} FROM {WITHDRAWAL_FROM}
             WHERE ($1::bigint IS NULL OR w.company_id = $1) AND ($2::text IS NULL OR w.status = $2)
             ORDER BY w.created_at DESC LIMIT 200""", company_id, status)


async def withdrawal_for_update(conn, withdrawal_uid: uuid.UUID) -> Optional[asyncpg.Record]:
    return await conn.fetchrow(
        f"SELECT {WITHDRAWAL_COLS}, w.wallet_id, w.bank_account_id, w.company_id FROM {WITHDRAWAL_FROM} WHERE w.uid = $1 FOR UPDATE OF w",
        withdrawal_uid)


async def insert_withdrawal(conn, wallet_id: int, account_id: int, company_id: int, amount: int, currency: str,
                            user_id: int, needs_second: bool, key: str) -> asyncpg.Record:
    return await conn.fetchrow(
        """INSERT INTO fin.withdrawal_request (wallet_id, bank_account_id, company_id, amount, currency, requested_by,
             needs_second, idempotency_key)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id, uid""",
        wallet_id, account_id, company_id, amount, currency, user_id, needs_second, key)


async def set_hold(conn, wallet_id: int, delta: int) -> None:
    """Moves money in or out of the wallet's hold; the database refuses a hold above the balance."""
    await conn.execute("UPDATE fin.wallet SET hold_balance = hold_balance + $2 WHERE id = $1", wallet_id, delta)


async def second_approval_above(conn) -> int:
    return int(await conn.fetchval(
        "SELECT coalesce((SELECT (value #>> '{}')::bigint FROM sys.setting WHERE key = 'payout.second_approval_above'), 100000000)"))


async def settlement_trips(conn, company_id: int, start: date, end: date):
    """Per completed trip in the period: fares sold, agency commission, refunds and what was released to the carrier."""
    return await conn.fetch(
        """SELECT t.id AS trip_id, t.trip_no,
                  coalesce(sum(l.amount) FILTER (WHERE l.code = 'CARRIER_FARE'), 0)
                    + coalesce(sum(l.amount) FILTER (WHERE l.code = 'AGENCY_COMMISSION'), 0) AS gross,
                  coalesce(sum(l.amount - l.refunded_amount) FILTER (WHERE l.code = 'AGENCY_COMMISSION'), 0) AS commission,
                  coalesce(sum(l.refunded_amount) FILTER (WHERE l.code IN ('CARRIER_FARE','AGENCY_COMMISSION')), 0) AS refunds,
                  coalesce(sum(l.amount - l.refunded_amount) FILTER (WHERE l.code = 'CARRIER_FARE' AND l.status = 'RELEASED'), 0) AS net
             FROM ops.trip t
             JOIN sales.booking b ON b.trip_id = t.id
             JOIN fin.price_allocation_line l ON l.allocation_id = b.price_allocation_id
            WHERE t.company_id = $1 AND t.status = 'COMPLETED'
              AND (t.departure_at AT TIME ZONE 'Asia/Damascus')::date BETWEEN $2 AND $3
            GROUP BY t.id, t.trip_no ORDER BY t.trip_no""", company_id, start, end)


async def settlements(conn, company_id: Optional[int] = None):
    return await conn.fetch(
        """SELECT s.id, s.uid, lower(s.period) AS period_from, upper(s.period) - 1 AS period_to, s.currency, s.gross,
                  s.commission, s.refunds, s.net, s.status, s.created_at, s.approved_at, s.created_by, s.approved_by,
                  p.legal_name AS company_name,
                  (SELECT count(*) FROM fin.settlement_line l WHERE l.batch_id = s.id) AS trips
             FROM fin.settlement_batch s JOIN iam.party p ON p.id = s.company_id
            WHERE ($1::bigint IS NULL OR s.company_id = $1) ORDER BY s.created_at DESC LIMIT 200""", company_id)


async def settlement_lines(conn, batch_id: int):
    return await conn.fetch(
        "SELECT trip_no, gross, commission, refunds, net FROM fin.settlement_line WHERE batch_id = $1 ORDER BY trip_no", batch_id)

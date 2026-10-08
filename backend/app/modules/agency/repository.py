"""SQL for the agency module. Row-level security limits every query to the signed-in agency's bookings."""
from datetime import date
from typing import Optional

import asyncpg

from ..sales.repository import JOURNEY_SQL


async def lock_agency_sales(conn: asyncpg.Connection, agency_id: int) -> None:
    """Serialises one agency's sales for the rest of the transaction, so concurrent sales are checked against the
    daily limit in turn. A transaction-level advisory lock: no table lock, released on commit or rollback."""
    await conn.execute("SELECT pg_advisory_xact_lock(hashtext('agency-sales'), $1::int)", agency_id)


async def agreement(conn: asyncpg.Connection, agency_id: int) -> Optional[asyncpg.Record]:
    return await conn.fetchrow(
        "SELECT * FROM sales.agency_agreement WHERE agency_id = $1 AND status <> 'ENDED'", agency_id)


async def sold_on(conn: asyncpg.Connection, agency_id: int, day: date) -> int:
    """Sales of one local day that count against the daily limit (cancelled bookings no longer count)."""
    return await conn.fetchval(
        """SELECT coalesce(sum(total_amount), 0)::bigint FROM sales.booking
            WHERE agency_id = $1 AND status IN ('CONFIRMED','COMPLETED')
              AND (created_at AT TIME ZONE 'Asia/Damascus')::date = $2""", agency_id, day)


async def commission_totals(conn: asyncpg.Connection, agency_id: int) -> asyncpg.Record:
    return await conn.fetchrow(
        """SELECT coalesce(sum(l.amount - l.refunded_amount) FILTER (WHERE l.status IN ('HELD','PARTIAL_REFUND')), 0)::bigint AS held,
                  coalesce(sum(l.amount - l.refunded_amount) FILTER (WHERE l.status = 'RELEASED'), 0)::bigint AS released
             FROM fin.price_allocation_line l JOIN fin.price_allocation a ON a.id = l.allocation_id
             JOIN sales.booking b ON b.id = a.booking_id
            WHERE b.agency_id = $1 AND l.code = 'AGENCY_COMMISSION'""", agency_id)


async def bookings(conn: asyncpg.Connection, agency_id: int, query: Optional[str], limit: int = 100) -> list[asyncpg.Record]:
    return await conn.fetch(
        f"""SELECT b.booking_ref, b.status, b.total_amount, b.currency, b.created_at, b.contact_mobile,
                   t.trip_no, cp.legal_name AS carrier_name, sp.legal_name AS sold_by,
                   (b.price_breakdown ->> 'agency_commission')::bigint AS commission,
                   (SELECT count(*) FROM sales.ticket k WHERE k.booking_id = b.id) AS passengers,
                   {JOURNEY_SQL}
              FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id JOIN iam.party cp ON cp.id = b.company_id
              LEFT JOIN iam.app_user su ON su.id = b.booker_user_id LEFT JOIN iam.party sp ON sp.id = su.party_id
             WHERE b.agency_id = $1
               AND ($2::text IS NULL OR b.booking_ref = upper($2) OR b.contact_mobile = $2)
             ORDER BY b.created_at DESC LIMIT $3""", agency_id, query, limit)


async def booking(conn: asyncpg.Connection, agency_id: int, ref: str) -> Optional[asyncpg.Record]:
    return await conn.fetchrow(
        """SELECT b.*, t.trip_no, t.uid AS trip_uid, t.departure_at, t.status AS trip_status,
                  cp.legal_name AS carrier_name
             FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id JOIN iam.party cp ON cp.id = b.company_id
            WHERE b.booking_ref = $1 AND b.agency_id = $2""", ref.upper(), agency_id)


async def ticket_status(conn: asyncpg.Connection, agency_id: int, ticket_uid) -> Optional[str]:
    return await conn.fetchval(
        """SELECT k.status FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
            WHERE k.uid = $1 AND b.agency_id = $2""", ticket_uid, agency_id)


async def balance_before(conn: asyncpg.Connection, wallet_id: int, start: date) -> int:
    """The balance at the start of the day (Damascus time), from the closed-day totals and the entries after them."""
    return await conn.fetchval(
        "SELECT coalesce(fin.wallet_balance_at($1, ($2::date)::timestamp AT TIME ZONE 'Asia/Damascus'), 0)", wallet_id, start)


async def statement(conn: asyncpg.Connection, wallet_id: int, start: date, end: date) -> list[asyncpg.Record]:
    """Entries of the period, oldest first; the caller adds the running balance (a shared wallet stores none)."""
    return await conn.fetch(
        """SELECT e.direction, e.amount, e.created_at, t.txn_type, t.memo
             FROM fin.ledger_entry e JOIN fin.ledger_txn t ON t.id = e.txn_id
            WHERE e.wallet_id = $1
              AND e.created_at >= ($2::date)::timestamp AT TIME ZONE 'Asia/Damascus'
              AND e.created_at < ($3::date + 1)::timestamp AT TIME ZONE 'Asia/Damascus'
            ORDER BY e.created_at, e.id""", wallet_id, start, end)


async def daily_sales(conn: asyncpg.Connection, agency_id: int, start: date, end: date) -> list[asyncpg.Record]:
    return await conn.fetch(
        """SELECT (b.created_at AT TIME ZONE 'Asia/Damascus')::date AS day,
                  count(*) FILTER (WHERE b.status <> 'CANCELLED') AS bookings,
                  coalesce(sum(b.total_amount) FILTER (WHERE b.status <> 'CANCELLED'), 0)::bigint AS sales,
                  count(*) FILTER (WHERE b.status = 'CANCELLED') AS cancelled
             FROM sales.booking b
            WHERE b.agency_id = $1 AND (b.created_at AT TIME ZONE 'Asia/Damascus')::date BETWEEN $2 AND $3
            GROUP BY 1 ORDER BY 1""", agency_id, start, end)

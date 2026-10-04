"""Agency use cases: sell on behalf of a traveller within the agreement, cancel, report.

The agency pays from its prepaid company wallet. The traveller's price is the same as on the website; the
carrier funds the agency's commission out of its fare. Selling and the daily limit are checked under a per-agency lock,
so two clerks selling at the same moment cannot pass the limit together.
"""
from datetime import date, datetime, timedelta

import asyncpg

from ... import db
from ...deps import Principal
from ...errors import ApiError, forbidden, not_found
from ...ledger import company_wallet
from ...util import LOCAL_TZ, row_dict, rows
from ..sales import service as sales
from ..sales.models import AgencyBookingIn
from . import repository as repo


def _today() -> date:
    return datetime.now(LOCAL_TZ).date()


def require_agency(pr: Principal) -> int:
    if pr.portal != "AGENCY" or not pr.company_id:
        raise forbidden("agency portal only")
    return pr.company_id


def need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden("missing permission: " + " | ".join(codes))


async def _active_agreement(conn: asyncpg.Connection, agency_id: int) -> asyncpg.Record:
    a = await repo.agreement(conn, agency_id)
    if a is None or a["status"] != "ACTIVE":
        raise ApiError(403, "AGENCY_SUSPENDED", "the agency agreement is not active")
    return a


async def ensure_can_sell(conn: asyncpg.Connection, pr: Principal) -> None:
    """Holding seats is already part of selling: a suspended agency cannot take seats out of sale."""
    need(pr, "booking.on_behalf")
    await _active_agreement(conn, require_agency(pr))


def buyer_for(pr: Principal, agreement: asyncpg.Record, contact_mobile: str | None = None) -> sales.Buyer:
    return sales.Buyer(party_id=pr.company_id, user_id=pr.user_id, channel="AGENCY", agency_id=pr.company_id,
                       commission_bp=agreement["commission_bp"], contact_mobile=contact_mobile)


async def dashboard(conn: asyncpg.Connection, pr: Principal) -> dict:
    agency_id = require_agency(pr)
    a = await repo.agreement(conn, agency_id)
    wallet = await company_wallet(conn, agency_id, "SYP", label="Agency wallet")
    sold = await repo.sold_on(conn, agency_id, _today())
    com = await repo.commission_totals(conn, agency_id)
    recent = await repo.bookings(conn, agency_id, None, limit=8)
    return {
        "balance": wallet["balance"], "currency": wallet["currency"],
        "agreement": None if a is None else {"status": a["status"], "commission_bp": a["commission_bp"],
                                             "daily_limit": a["daily_limit"]},
        "sold_today": sold, "remaining_today": max(0, (a["daily_limit"] if a else 0) - sold),
        "commission_held": com["held"], "commission_released": com["released"],
        "recent": rows(recent),
    }


async def sell(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, body: AgencyBookingIn) -> dict:
    agency_id = require_agency(pr)
    need(pr, "booking.on_behalf")
    await repo.lock_agency_sales(conn, agency_id)
    agreement = await _active_agreement(conn, agency_id)

    async def within_daily_limit(conn, total: int) -> None:
        sold = await repo.sold_on(conn, agency_id, _today())
        if sold + total > agreement["daily_limit"]:
            raise ApiError(409, "AGENCY_DAILY_LIMIT", "this sale would pass the agency's daily limit",
                           remaining=max(0, agreement["daily_limit"] - sold))

    return await sales.create_booking(conn, ctx, buyer_for(pr, agreement, body.contact_mobile), body,
                                      before_payment=within_daily_limit)


async def booking_detail(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, ref: str) -> dict:
    agency_id = require_agency(pr)
    b = await repo.booking(conn, agency_id, ref)
    if b is None:
        raise not_found("booking")
    out = await sales.booking_view(conn, ctx, b)
    out["booking"]["commission"] = out["booking"]["price_breakdown"].get("agency_commission")
    return out


async def cancel(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, ref: str) -> tuple[int, dict]:
    agency_id = require_agency(pr)
    need(pr, "booking.on_behalf")
    b = await repo.booking(conn, agency_id, ref)
    if b is None:
        raise not_found("booking")
    agreement = await repo.agreement(conn, agency_id)
    buyer = sales.Buyer(party_id=agency_id, user_id=pr.user_id, channel="AGENCY", agency_id=agency_id,
                        commission_bp=agreement["commission_bp"] if agreement else 0)
    return b["id"], await sales.cancel_booking(conn, ctx, b, buyer)


async def statement(conn: asyncpg.Connection, pr: Principal, month: str | None) -> dict:
    agency_id = require_agency(pr)
    need(pr, "report.company", "company.billing", "booking.on_behalf")
    try:
        start = date.fromisoformat(f"{month}-01") if month else _today().replace(day=1)
    except ValueError:
        raise ApiError(422, "INVALID_MONTH", "month must look like 2026-10")
    end = (start.replace(day=28) + timedelta(days=4)).replace(day=1) - timedelta(days=1)
    wallet = await company_wallet(conn, agency_id, "SYP", label="Agency wallet")
    entries = await repo.statement(conn, wallet["id"], start, end)
    days = await repo.daily_sales(conn, agency_id, start, end)
    credit = sum(e["amount"] for e in entries if e["direction"] == "CR")
    debit = sum(e["amount"] for e in entries if e["direction"] == "DR")
    opening = await repo.balance_before(conn, wallet["id"], start)
    return {"month": start.isoformat()[:7], "from": start.isoformat(), "to": end.isoformat(),
            "currency": wallet["currency"], "opening_balance": opening,
            "closing_balance": entries[-1]["balance_after"] if entries else opening,
            "total_credit": credit, "total_debit": debit,
            "entries": rows(entries), "days": [row_dict(d) for d in days]}


async def staff(conn: asyncpg.Connection, pr: Principal) -> list[dict]:
    agency_id = require_agency(pr)
    recs = await conn.fetch(
        """SELECT p.uid, p.legal_name AS full_name, u.email, m.is_owner, m.status, r.code AS role, u.last_login_at,
                  EXISTS (SELECT 1 FROM iam.mfa_factor f WHERE f.user_id = u.id AND f.factor_type = 'TOTP'
                             AND f.verified_at IS NOT NULL AND f.disabled_at IS NULL) AS mfa_enrolled
             FROM iam.company_member m JOIN iam.app_user u ON u.id = m.user_id JOIN iam.party p ON p.id = u.party_id
             LEFT JOIN iam.role r ON r.id = m.role_id
            WHERE m.company_id = $1 ORDER BY m.is_owner DESC, p.legal_name""", agency_id)
    return rows(recs)


async def add_staff(conn: asyncpg.Connection, pr: Principal, full_name: str, email: str, mobile: str | None,
                    password: str, role: str) -> tuple[int, str]:
    """Adds a seller or accountant. Agency staff always sign in with a second factor."""
    from ...security import hash_password
    agency_id = require_agency(pr)
    need(pr, "company.staff")
    role_id = await conn.fetchval("SELECT id FROM iam.role WHERE code = $1 AND company_id IS NULL", f"AGENCY_{role}")
    party_id = await conn.fetchval(
        "INSERT INTO iam.party (party_type, legal_name, email, mobile) VALUES ('PERSON', $1, $2, $3) RETURNING id",
        full_name.strip(), email, mobile)
    await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'AGENCY')", party_id)
    user_id = await conn.fetchval(
        """INSERT INTO iam.app_user (party_id, account_kind, email, mobile, password_hash, password_changed_at, status,
             preferred_locale, mfa_required) VALUES ($1, 'AGENCY', $2, $3, $4, now(), 'ACTIVE', 'ar', true) RETURNING id""",
        party_id, email, mobile, hash_password(password))
    await conn.execute("INSERT INTO iam.company_member (user_id, company_id, role_id) VALUES ($1, $2, $3)",
                       user_id, agency_id, role_id)
    uid = await conn.fetchval("SELECT uid FROM iam.party WHERE id = $1", party_id)
    return party_id, str(uid)

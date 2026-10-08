"""Cash sales at the carrier's counter and the cash a carrier owes the platform (study 6.5, schema 1056).

A ticket sold for cash at a counter is paid from the carrier's cash wallet (CASH_COLLECT): the wallet goes negative by
the price, which is the cash the carrier now holds for the platform. The money itself is booked into escrow exactly as
for any other sale, so the fare, the platform fee and the release on trip completion are unchanged. The carrier's debt
is cleared in two ways: its released earnings are set off against it (after each completed trip and before each
withdrawal), and what is left is remitted and confirmed by platform finance, one person recording and another
confirming. A credit limit per carrier stops cash sales when the debt would pass it.
"""
import json
import uuid
from datetime import date, datetime
from typing import Optional

import asyncpg

from ... import db
from ...deps import Principal
from ...errors import ApiError, forbidden, not_found
from ...ledger import cash_wallet, company_wallet, platform_wallet, post_txn
from ...util import LOCAL_TZ, row_dict
from ..sales import options
from ..sales import repository as sales_repo
from ..sales import service as sales

CURRENCY = "SYP"


def need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden("missing permission: " + " | ".join(codes))


def counter_of(pr: Principal) -> int:
    if pr.portal != "OPERATOR" or not pr.company_id:
        raise forbidden("carrier portal only")
    need(pr, "sale.cash")
    return pr.company_id


def buyer_for(pr: Principal, contact_mobile: Optional[str] = None) -> sales.Buyer:
    return sales.Buyer(party_id=pr.company_id, user_id=pr.user_id, channel="COUNTER", cash_company_id=pr.company_id,
                       contact_mobile=contact_mobile)


async def position(conn: asyncpg.Connection, company_id: int) -> dict:
    """What the carrier owes for cash sales, its limit and what is left before cash sales stop."""
    r = await conn.fetchrow("SELECT fin.cash_owed($1, $2) AS owed, fin.cash_limit($1) AS lim", company_id, CURRENCY)
    return {"owed": r["owed"], "limit": r["lim"], "remaining": max(0, r["lim"] - r["owed"]), "currency": CURRENCY}


async def _within_limit(conn: asyncpg.Connection, company_id: int, amount: int) -> None:
    p = await position(conn, company_id)
    if p["owed"] + amount > p["limit"]:
        raise ApiError(409, "CASH_LIMIT_REACHED", "cash sales are stopped until the carrier remits what it owes",
                       owed=p["owed"], limit=p["limit"], remaining=p["remaining"])


async def _lock(conn: asyncpg.Connection, company_id: int) -> None:
    """Serialises one carrier's cash sales for the rest of the transaction, so the limit is checked in turn."""
    await conn.execute("SELECT pg_advisory_xact_lock(hashtext('cash-sales'), $1::int)", company_id)


# ------------------------------------------------------------------ the counter
async def ensure_trip(conn: asyncpg.Connection, pr: Principal, trip_uid: uuid.UUID) -> None:
    owner = await conn.fetchval("SELECT company_id FROM ops.trip WHERE uid = $1", trip_uid)
    if owner != counter_of(pr):
        raise not_found("trip")


async def sell(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, body) -> dict:
    company = counter_of(pr)
    await _lock(conn, company)
    async with db.system_scope(conn, ctx):
        await cash_wallet(conn, company, CURRENCY)

    async def within_limit(conn, total: int) -> None:
        await _within_limit(conn, company, total)

    return await sales.create_booking(conn, ctx, buyer_for(pr, body.contact_mobile), body, before_payment=within_limit,
                                      option="CASH_COUNTER")


async def _booking(conn: asyncpg.Connection, company_id: int, ref: str) -> asyncpg.Record:
    b = await conn.fetchrow(
        """SELECT b.*, t.trip_no, t.uid AS trip_uid, t.departure_at, t.status AS trip_status, cp.legal_name AS carrier_name
             FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id JOIN iam.party cp ON cp.id = b.company_id
            WHERE b.booking_ref = $1 AND b.company_id = $2""", ref.upper(), company_id)
    if b is None:
        raise not_found("booking")
    return b


async def booking_detail(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, ref: str) -> dict:
    company = counter_of(pr)
    async with db.system_scope(conn, ctx):
        b = await _booking(conn, company, ref)
    out = await sales.booking_view(conn, ctx, b)
    out["booking"]["pay_method"] = b["pay_method"]
    out["booking"]["counter_sale"] = b["pay_option"] == "CASH_COUNTER"
    out["booking"]["collectable"] = b["status"] == "PENDING_PAYMENT" and b["pay_option"] == "PAY_LATER"
    out["booking"]["refundable_here"] = b["status"] == "CONFIRMED" and b["pay_method"] == "CASH"
    return out


async def collect(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, ref: str) -> dict:
    """The passenger pays a pay-later reservation in cash at the counter: the tickets are issued at once."""
    company = counter_of(pr)
    await _lock(conn, company)
    async with db.system_scope(conn, ctx):
        b = await _booking(conn, company, ref)
        if b["pay_option"] != "PAY_LATER":
            raise ApiError(409, "NOT_PAY_AT_COUNTER", "this booking is not paid at the counter")
        await _within_limit(conn, company, b["total_amount"])
        wallet = await cash_wallet(conn, company, b["currency"])
    out = await sales.confirm_reserved(conn, ctx, b["id"], wallet, pr.user_id)
    return {**out, "booking_id": b["id"]}


async def cancel(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, ref: str) -> tuple[int, dict]:
    """Cancels at the counter: an unpaid reservation frees its seats; a cash booking is refunded in cash from the drawer,
    which lowers what the carrier owes. Bookings paid online are cancelled online, so they are refunded the same way."""
    company = counter_of(pr)
    async with db.system_scope(conn, ctx):
        b = await _booking(conn, company, ref)
    if b["status"] == "PENDING_PAYMENT":
        return b["id"], await sales.cancel_reserved(conn, ctx, b, pr.user_id, reason="COUNTER")
    if b["pay_method"] != "CASH":
        raise ApiError(409, "CANCEL_ONLINE", "this booking was paid online; it is cancelled and refunded online")
    async with db.system_scope(conn, ctx):
        await cash_wallet(conn, company, b["currency"])
    out = await sales.cancel_booking(conn, ctx, b, buyer_for(pr), reason="COUNTER")
    out.pop("commission_kept", None)
    return b["id"], out


async def bookings(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, q: Optional[str], status: Optional[str]) -> list[dict]:
    company = counter_of(pr)
    async with db.system_scope(conn, ctx):
        recs = await conn.fetch(
            f"""SELECT b.booking_ref, b.status, b.total_amount, b.currency, b.created_at, b.pay_option, b.pay_method,
                       b.hold_expires_at AS pay_by, b.contact_mobile, t.trip_no, t.departure_at, sp.legal_name AS sold_by,
                       (SELECT count(*) FROM sales.ticket k WHERE k.booking_id = b.id) AS passengers, {sales_repo.JOURNEY_SQL}
                  FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id
                  LEFT JOIN iam.app_user su ON su.id = b.booker_user_id LEFT JOIN iam.party sp ON sp.id = su.party_id
                 WHERE b.company_id = $1 AND b.pay_option IN ('CASH_COUNTER','PAY_LATER')
                   AND ($2::text IS NULL OR b.booking_ref = upper($2) OR b.contact_mobile = $2)
                   AND ($3::text IS NULL OR b.status = $3)
                 ORDER BY b.created_at DESC LIMIT 100""", company, q, status)
    out = []
    for r in recs:
        d = row_dict(r)
        d["journey"] = sales._json(d["journey"])
        if d["status"] != "PENDING_PAYMENT":
            d["pay_by"] = None
        out.append(d)
    return out


async def ticket_status(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, ticket_uid: uuid.UUID) -> Optional[str]:
    company = counter_of(pr)
    async with db.system_scope(conn, ctx):
        return await conn.fetchval(
            """SELECT k.status FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                WHERE k.uid = $1 AND b.company_id = $2""", ticket_uid, company)


async def dashboard(conn: asyncpg.Connection, ctx: db.Context, pr: Principal) -> dict:
    company = counter_of(pr)
    today = datetime.now(LOCAL_TZ).date()
    async with db.system_scope(conn, ctx):
        mine = await _day_lines(conn, company, today, pr.user_id)
        waiting = await conn.fetchval(
            "SELECT count(*) FROM sales.booking WHERE company_id = $1 AND status = 'PENDING_PAYMENT' AND pay_option = 'PAY_LATER'",
            company)
        pos = await position(conn, company)
    return {**pos, "today": today.isoformat(), "my_sales": mine["sales"], "my_cash_in": mine["cash_in"],
            "my_refunds": mine["refunds"], "my_net": mine["cash_in"] - mine["refunds"], "reservations_waiting": waiting,
            "options": [m["code"] for m in await options.all_methods(conn) if m["enabled"] and "COUNTER" in m["channels"]]}


async def _day_lines(conn: asyncpg.Connection, company_id: int, day: date, user_id: Optional[int] = None) -> dict:
    w = await conn.fetchval("SELECT id FROM fin.wallet WHERE owner_party_id = $1 AND wallet_type = 'CASH_COLLECT' AND currency = $2",
                            company_id, CURRENCY)
    if w is None:
        return {"sales": 0, "cash_in": 0, "refunds": 0, "by_seller": []}
    rows = await conn.fetch(
        """SELECT t.created_by AS user_id, sp.legal_name AS seller,
                  count(*) FILTER (WHERE t.txn_type = 'BOOKING_PAY') AS sales,
                  coalesce(sum(e.amount) FILTER (WHERE t.txn_type = 'BOOKING_PAY'), 0)::bigint AS cash_in,
                  coalesce(sum(e.amount) FILTER (WHERE t.txn_type = 'REFUND'), 0)::bigint AS refunds
             FROM fin.ledger_entry e JOIN fin.ledger_txn t ON t.id = e.txn_id
             LEFT JOIN iam.app_user su ON su.id = t.created_by LEFT JOIN iam.party sp ON sp.id = su.party_id
            WHERE e.wallet_id = $1 AND t.txn_type IN ('BOOKING_PAY','REFUND')
              AND e.created_at >= ($2::date)::timestamp AT TIME ZONE 'Asia/Damascus'
              AND e.created_at < ($2::date + 1)::timestamp AT TIME ZONE 'Asia/Damascus'
              AND ($3::bigint IS NULL OR t.created_by = $3)
            GROUP BY t.created_by, sp.legal_name ORDER BY cash_in DESC""", w, day, user_id)
    by = [{**dict(r), "net": r["cash_in"] - r["refunds"]} for r in rows]
    return {"sales": sum(r["sales"] for r in by), "cash_in": sum(r["cash_in"] for r in by),
            "refunds": sum(r["refunds"] for r in by), "by_seller": by}


async def day_report(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, day: date) -> dict:
    """Cash taken and given back at the counters of one local day, per seller: the drawer count of the evening."""
    company = counter_of(pr)
    everyone = bool(pr.permissions.intersection({"report.company", "company.billing"})) or pr.is_owner
    async with db.system_scope(conn, ctx):
        out = await _day_lines(conn, company, day, None if everyone else pr.user_id)
        pos = await position(conn, company)
    return {"day": day.isoformat(), **out, "net": out["cash_in"] - out["refunds"], "position": pos}


# ------------------------------------------------------------------ setting off and remitting
async def net_cash(conn: asyncpg.Connection, company_id: int, key: str, user_id: Optional[int] = None,
                   currency: str = CURRENCY) -> int:
    """Sets the carrier's spendable earnings off against the cash it owes; the caller holds the system scope.

    Money held for a pending withdrawal is left alone. Returns the amount set off (0 when nothing is owed or earned).
    """
    owed = await conn.fetchval("SELECT fin.cash_owed($1, $2)", company_id, currency)
    if not owed:
        return 0
    earned = await company_wallet(conn, company_id, currency)
    amount = min(owed, max(0, earned["balance"] - earned["hold_balance"]))
    if amount <= 0:
        return 0
    cash = await cash_wallet(conn, company_id, currency)
    await post_txn(conn, "CASH_NETTING", currency, key, [(earned["id"], "DR", amount), (cash["id"], "CR", amount)],
                   ref_type="company", ref_id=company_id, user_id=user_id, memo="Cash sales set off against earnings")
    return amount


async def positions(conn: asyncpg.Connection) -> list[dict]:
    rows = await conn.fetch(
        """SELECT c.id AS company_id, p.legal_name AS name, c.company_type, fin.cash_owed(c.id, $1) AS owed,
                  fin.cash_limit(c.id) AS limit_amount, l.reason AS limit_reason, l.set_at AS limit_set_at,
                  (SELECT max(r.confirmed_at) FROM fin.cash_remittance r WHERE r.company_id = c.id AND r.status = 'CONFIRMED') AS last_remitted_at,
                  (SELECT coalesce(sum(r.amount), 0) FROM fin.cash_remittance r WHERE r.company_id = c.id AND r.status = 'PENDING')::bigint AS pending,
                  coalesce(a.days_0_7, 0) AS days_0_7, coalesce(a.days_8_30, 0) AS days_8_30, coalesce(a.days_31_60, 0) AS days_31_60,
                  coalesce(a.days_61_90, 0) AS days_61_90, coalesce(a.days_over_90, 0) AS days_over_90,
                  coalesce(a.overdue, 0) AS overdue, a.oldest_unpaid_at
             FROM iam.company c JOIN iam.party p ON p.id = c.id LEFT JOIN fin.cash_credit_limit l ON l.company_id = c.id
             LEFT JOIN fin.cash_aging(now(), $1) a ON a.company_id = c.id
            WHERE c.company_type IN ('CARRIER','INDIVIDUAL_OPERATOR','FOREIGN_CARRIER') AND c.approval_status = 'APPROVED'
            ORDER BY 4 DESC, p.legal_name""", CURRENCY)
    return [{**row_dict(r), "own_limit": r["limit_reason"] is not None} for r in rows]


async def set_limit(conn: asyncpg.Connection, user_id: int, company_id: int, amount: int, reason: str) -> dict:
    if not await conn.fetchval("SELECT 1 FROM iam.company WHERE id = $1 AND company_type IN ('CARRIER','INDIVIDUAL_OPERATOR','FOREIGN_CARRIER')",
                               company_id):
        raise not_found("carrier")
    await conn.execute(
        """INSERT INTO fin.cash_credit_limit (company_id, limit_amount, reason, set_by) VALUES ($1, $2, $3, $4)
           ON CONFLICT (company_id) DO UPDATE SET limit_amount = EXCLUDED.limit_amount, reason = EXCLUDED.reason,
                  set_by = EXCLUDED.set_by, set_at = now()""", company_id, amount, reason, user_id)
    return {"ok": True, **(await position(conn, company_id))}


async def remittances(conn: asyncpg.Connection, status: Optional[str]) -> list[dict]:
    rows = await conn.fetch(
        """SELECT r.id, r.company_id, p.legal_name AS carrier, r.amount, r.currency, r.method, r.ref, r.status, r.note,
                  r.created_at, r.confirmed_at, rb.legal_name AS recorded_by_name, cb.legal_name AS confirmed_by_name,
                  r.recorded_by, r.confirmed_by
             FROM fin.cash_remittance r JOIN iam.party p ON p.id = r.company_id
             LEFT JOIN iam.app_user ru ON ru.id = r.recorded_by LEFT JOIN iam.party rb ON rb.id = ru.party_id
             LEFT JOIN iam.app_user cu ON cu.id = r.confirmed_by LEFT JOIN iam.party cb ON cb.id = cu.party_id
            WHERE ($1::text IS NULL OR r.status = $1) ORDER BY r.id DESC LIMIT 200""", status)
    return [row_dict(r) for r in rows]


async def record_remittance(conn: asyncpg.Connection, user_id: int, company_id: int, amount: int, method: str,
                            ref: Optional[str], note: Optional[str]) -> dict:
    owed = await conn.fetchval("SELECT fin.cash_owed($1, $2)", company_id, CURRENCY)
    pending = await conn.fetchval("SELECT coalesce(sum(amount), 0)::bigint FROM fin.cash_remittance WHERE company_id = $1 AND status = 'PENDING'",
                                  company_id)
    if amount > owed - pending:
        raise ApiError(422, "REMITTANCE_TOO_LARGE", "more than the carrier owes", owed=owed, pending=pending)
    rid = await conn.fetchval(
        """INSERT INTO fin.cash_remittance (company_id, amount, currency, method, ref, recorded_by, note)
           VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id""", company_id, amount, CURRENCY, method, ref, user_id, note)
    return {"id": rid, "status": "PENDING"}


async def decide_remittance(conn: asyncpg.Connection, user_id: int, rid: int, approve: bool, note: Optional[str]) -> dict:
    """A second finance officer confirms the money arrived (and it is posted) or rejects the record."""
    r = await conn.fetchrow("SELECT * FROM fin.cash_remittance WHERE id = $1 FOR UPDATE", rid)
    if r is None:
        raise not_found("remittance")
    if r["status"] != "PENDING":
        raise ApiError(409, "REMITTANCE_FINAL", "this remittance is already decided")
    if r["recorded_by"] == user_id:
        raise ApiError(403, "FOUR_EYES", "the person who recorded a remittance does not confirm or reject it")
    if not approve:
        await conn.execute("UPDATE fin.cash_remittance SET status = 'REJECTED', confirmed_by = $2, note = coalesce($3, note) WHERE id = $1",
                           rid, user_id, note)
        return {"id": rid, "status": "REJECTED"}
    owed = await conn.fetchval("SELECT fin.cash_owed($1, $2)", r["company_id"], r["currency"])
    if r["amount"] > owed:
        raise ApiError(422, "REMITTANCE_TOO_LARGE", "more than the carrier owes now (its earnings may have been set off)", owed=owed)
    source = await platform_wallet(conn, "BANK_CLEARING", r["currency"])
    cash = await cash_wallet(conn, r["company_id"], r["currency"])
    txn = await post_txn(conn, "CASH_REMITTANCE", r["currency"], f"cash-remittance:{rid}",
                         [(source["id"], "DR", r["amount"]), (cash["id"], "CR", r["amount"])],
                         ref_type="cash_remittance", ref_id=rid, user_id=user_id, memo=r["ref"] or r["method"])
    await conn.execute(
        "UPDATE fin.cash_remittance SET status = 'CONFIRMED', confirmed_by = $2, ledger_txn_id = $3, note = coalesce($4, note) WHERE id = $1",
        rid, user_id, txn, note)
    return {"id": rid, "status": "CONFIRMED", "owed": await conn.fetchval("SELECT fin.cash_owed($1, $2)", r["company_id"], r["currency"])}


# ------------------------------------------------------------------ the switches
ALLOWED_CHANNELS = {"WALLET": {"WEB", "APP"}, "AGENCY_BALANCE": {"AGENCY"}, "CASH_COUNTER": {"COUNTER"},
                    "PAY_LATER": {"WEB", "APP"}, "CARD": {"WEB", "APP"}, "INSTALLMENT": {"WEB", "APP"}, "FINANCING": {"WEB", "APP"}}
CONFIG_KEYS = {
    "CASH_COUNTER": {"default_credit_limit": (0, 100_000_000_000)},
    "PAY_LATER": {"hold_hours": (1, 168), "cutoff_minutes": (30, 2880), "max_open": (0, 10)},
    "CARD": {"hold_minutes": (5, 120)},
    "INSTALLMENT": {"hold_minutes": (5, 240)},
    "FINANCING": {"hold_hours": (1, 336), "cutoff_hours": (0, 336), "trip_types": None},
}


def clean_config(code: str, cfg: dict, trip_types: set[str]) -> dict:
    allowed = CONFIG_KEYS.get(code, {})
    bad = set(cfg) - set(allowed)
    if bad:
        raise ApiError(422, "CONFIG_NOT_EDITABLE", "these settings do not apply to this option: " + ", ".join(sorted(bad)))
    out = {}
    for k, v in cfg.items():
        rng = allowed[k]
        if rng is None:
            if not isinstance(v, list) or not all(isinstance(x, str) and x in trip_types for x in v):
                raise ApiError(422, "INVALID_VALUE", f"{k} lists trip types", allowed=sorted(trip_types))
            out[k] = sorted(set(v))
            continue
        if isinstance(v, bool) or not isinstance(v, int) or not rng[0] <= v <= rng[1]:
            raise ApiError(422, "INVALID_VALUE", f"{k} must be a whole number from {rng[0]} to {rng[1]}")
        out[k] = v
    return out


async def update_method(conn: asyncpg.Connection, user_id: int, code: str, body) -> dict:
    m = await options.method(conn, code)
    extra = set(body.channels) - ALLOWED_CHANNELS[code]
    if extra:
        raise ApiError(422, "CHANNEL_NOT_ALLOWED", "this option is not offered on these channels: " + ", ".join(sorted(extra)))
    if body.max_amount is not None and body.max_amount < body.min_amount:
        raise ApiError(422, "PAYMENT_AMOUNT_OUT_OF_RANGE", "the maximum is below the minimum")
    kinds = {r["code"] for r in await conn.fetch("SELECT code FROM ref.trip_type")}
    cfg = {**m["config"], **clean_config(code, body.config, kinds)}
    await conn.execute(
        """UPDATE fin.payment_method SET enabled = $2, channels = $3, min_amount = $4, max_amount = $5, config = $6::jsonb,
                  reason = $7, updated_by = $8 WHERE code = $1""",
        code, body.enabled, sorted(set(body.channels)), body.min_amount, body.max_amount, json.dumps(cfg), body.reason, user_id)
    return await options.method(conn, code)

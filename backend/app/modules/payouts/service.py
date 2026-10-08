"""Payout use cases.

Company side (carrier or agency owner): register a bank account, request a withdrawal, read statements.
Platform finance: verify accounts, approve or reject withdrawals (never their own requests; a second approver above
the limit), record the bank transfer, and draft and approve settlement statements (drafter and approver differ).

Money only leaves the ledger when a transfer is recorded as paid: DR company wallet, CR bank clearing. Until then the
amount sits in the wallet's hold, which the database keeps at or below the balance.
"""
import uuid
from datetime import date, timedelta

import asyncpg

from ... import crypto, db, policy
from ...deps import Principal
from ...errors import ApiError, forbidden, not_found
from ...ledger import company_wallet, platform_wallet, post_txn
from ...util import row_dict, rows
from ..cash import service as cash
from ..notify.outbox import emit
from . import iban as IBAN
from . import repository as repo

IBAN_COLUMN = "iam.bank_account.iban"


def company_of(pr: Principal) -> int:
    if pr.portal not in ("OPERATOR", "AGENCY") or not pr.company_id:
        raise forbidden("carrier or agency portal only")
    return pr.company_id


def need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden("missing permission: " + " | ".join(codes))


def _label(pr: Principal) -> str:
    return "Agency wallet" if pr.portal == "AGENCY" else "Carrier wallet"


# ------------------------------------------------------------------ company side
async def balance(conn: asyncpg.Connection, pr: Principal) -> dict:
    w = await company_wallet(conn, company_of(pr), "SYP", label=_label(pr))
    return {"currency": w["currency"], "balance": w["balance"], "held": w["hold_balance"],
            "available": w["balance"] - w["hold_balance"]}


async def my_bank_accounts(conn, pr: Principal) -> list[dict]:
    out = rows(await repo.bank_accounts(conn, company_of(pr)))
    for r in out:
        r.pop("id")
    return out


async def add_bank_account(conn, ctx: db.Context, pr: Principal, bank_name: str, holder: str, iban: str) -> tuple[int, str]:
    company = company_of(pr)
    need(pr, "company.payout_schedule", "company.billing")
    if not IBAN.valid(iban):
        raise ApiError(422, "IBAN_INVALID", "the IBAN is not valid")
    value = IBAN.normalise(iban)
    async with db.system_scope(conn, ctx):
        fc = await crypto.cipher(conn)
    sealed = fc.encrypt(value, IBAN_COLUMN)
    row = await repo.insert_bank_account(conn, company, bank_name.strip(), holder.strip(), sealed.ciphertext,
                                         fc.blind_index(value, "IBAN"), value[-4:], sealed.key_id, "SYP")
    return row["id"], str(row["uid"])


async def request_withdrawal(conn, pr: Principal, account_uid: uuid.UUID, amount: int, key: str,
                             ctx: db.Context | None = None) -> dict:
    company = company_of(pr)
    need(pr, "company.payout_schedule")
    w = await company_wallet(conn, company, "SYP", label=_label(pr))
    done = await conn.fetchval("SELECT uid FROM fin.withdrawal_request WHERE wallet_id = $1 AND idempotency_key = $2", w["id"], key)
    if done:
        return {"uid": str(done), "replayed": True}
    acct = await repo.bank_account_by_uid(conn, account_uid)
    if acct is None or acct["party_id"] != company or acct["status"] != "ACTIVE":
        raise not_found("bank account")
    if not acct["verified"]:
        raise ApiError(409, "BANK_ACCOUNT_NOT_VERIFIED", "platform finance has not verified this bank account yet")
    if pr.portal == "OPERATOR" and ctx is not None:
        # counter cash the carrier holds for the platform is set off first (6.5, 1056); the rest can be withdrawn
        async with db.system_scope(conn, ctx):
            if await cash.net_cash(conn, company, f"withdrawal:{w['id']}:{key}:cash-net", pr.user_id):
                w = await company_wallet(conn, company, "SYP", label=_label(pr))
    if amount > w["balance"] - w["hold_balance"]:
        raise ApiError(402, "INSUFFICIENT_BALANCE", "the available balance is not enough",
                       available=w["balance"] - w["hold_balance"])
    needs_second = amount > await repo.second_approval_above(conn)
    row = await repo.insert_withdrawal(conn, w["id"], acct["id"], company, amount, "SYP", pr.user_id, needs_second, key)
    try:
        await repo.set_hold(conn, w["id"], amount)
    except asyncpg.CheckViolationError:
        raise ApiError(402, "INSUFFICIENT_BALANCE", "the available balance is not enough")
    return {"id": row["id"], "uid": str(row["uid"]), "needs_second": needs_second}


async def my_withdrawals(conn, pr: Principal) -> list[dict]:
    out = rows(await repo.withdrawals(conn, company_of(pr)))
    for r in out:
        for k in ("id", "requested_by", "approved_by", "second_approver"):
            r.pop(k)
    return out


async def my_settlements(conn, pr: Principal) -> list[dict]:
    out = rows(await repo.settlements(conn, company_of(pr)))
    return [{k: v for k, v in r.items() if k not in ("id", "created_by", "approved_by")} for r in out]


async def settlement_detail(conn, pr: Principal, batch_uid: uuid.UUID) -> dict:
    s = await conn.fetchrow("SELECT * FROM fin.settlement_batch WHERE uid = $1", batch_uid)
    if s is None or (pr.portal != "PLATFORM" and s["company_id"] != pr.company_id):
        raise not_found("settlement")
    return {"uid": str(s["uid"]), "status": s["status"], "from": s["period"].lower.isoformat(),
            "to": (s["period"].upper - timedelta(days=1)).isoformat(),     # stored as [from, to + 1 day)
            "gross": s["gross"], "commission": s["commission"], "refunds": s["refunds"], "net": s["net"],
            "lines": rows(await repo.settlement_lines(conn, s["id"]))}


# ------------------------------------------------------------------ platform finance
def finance(pr: Principal, *codes: str) -> None:
    if pr.portal != "PLATFORM":
        raise forbidden("platform portal only")
    need(pr, *codes)


async def pending_accounts(conn) -> list[dict]:
    out = rows(await repo.bank_accounts(conn, None, unverified_only=True))
    for r in out:
        r.pop("id")
    return out


async def verify_account(conn, pr: Principal, account_uid: uuid.UUID) -> int:
    finance(pr, "withdrawal.approve", "payout.run")
    acct = await repo.bank_account_by_uid(conn, account_uid)
    if acct is None:
        raise not_found("bank account")
    await repo.verify_bank_account(conn, acct["id"], pr.user_id)
    return acct["id"]


async def reveal_iban(conn, ctx: db.Context, pr: Principal, withdrawal_uid: uuid.UUID) -> dict:
    """Full IBAN for making an approved transfer. Every reveal is written to the data access log with its purpose."""
    finance(pr, "payout.run")
    w = await repo.withdrawal_for_update(conn, withdrawal_uid)
    if w is None:
        raise not_found("withdrawal")
    if w["status"] != "APPROVED":
        raise ApiError(409, "NOT_APPROVED", "the IBAN is shown only for an approved withdrawal")
    acct = await conn.fetchrow("SELECT id, iban_enc, enc_key_id FROM iam.bank_account WHERE id = $1", w["bank_account_id"])
    await policy.authorize(ctx, "iam.bank_account.iban", "READ", "PAYOUT_EXECUTION", f"payout transfer for withdrawal {w['uid']}",
                           "payout.run")
    async with db.system_scope(conn, ctx):
        fc = await crypto.cipher(conn)
        await conn.execute(
            """INSERT INTO audit.data_access_log (user_id, company_id, ip, object_type, object_id, fields, purpose, request_id)
               VALUES ($1, $2, $3::inet, 'bank_account', $4, ARRAY['iban'], $5, $6)""",
            pr.user_id, w["company_id"], ctx.ip, acct["id"], f"payout transfer for withdrawal {w['uid']}", ctx.request_id)
    return {"iban": fc.decrypt(acct["iban_enc"], acct["enc_key_id"], IBAN_COLUMN), "holder": w["company_name"],
            "bank": w["bank_name"], "amount": w["amount"], "currency": w["currency"]}


async def approve(conn, pr: Principal, withdrawal_uid: uuid.UUID) -> dict:
    """First approval, or the second one for amounts above the limit. Nobody approves their own request or twice."""
    finance(pr, "withdrawal.approve")
    w = await repo.withdrawal_for_update(conn, withdrawal_uid)
    if w is None:
        raise not_found("withdrawal")
    if pr.user_id == w["requested_by"]:
        raise ApiError(403, "FOUR_EYES", "you cannot approve your own request")
    if w["status"] != "REQUESTED" and not (w["status"] == "APPROVED" and w["needs_second"] and w["second_approver"] is None):
        raise ApiError(409, "INVALID_TRANSITION", "this withdrawal is not waiting for approval")
    if w["approved_by"] is None:
        await conn.execute(
            "UPDATE fin.withdrawal_request SET status = 'APPROVED', approved_by = $2, decided_at = now() WHERE id = $1",
            w["id"], pr.user_id)
        return {"id": w["id"], "status": "APPROVED", "waiting_second": w["needs_second"]}
    if pr.user_id == w["approved_by"]:
        raise ApiError(403, "FOUR_EYES", "a second, different approver is required")
    await conn.execute("UPDATE fin.withdrawal_request SET second_approver = $2 WHERE id = $1", w["id"], pr.user_id)
    return {"id": w["id"], "status": "APPROVED", "waiting_second": False}


async def reject(conn, pr: Principal, withdrawal_uid: uuid.UUID, reason: str) -> int:
    finance(pr, "withdrawal.approve")
    w = await repo.withdrawal_for_update(conn, withdrawal_uid)
    if w is None:
        raise not_found("withdrawal")
    if w["status"] not in ("REQUESTED", "APPROVED"):
        raise ApiError(409, "INVALID_TRANSITION", "this withdrawal can no longer be rejected")
    await conn.execute(
        "UPDATE fin.withdrawal_request SET status = 'REJECTED', reject_reason = $2, decided_at = now() WHERE id = $1",
        w["id"], reason)
    await repo.set_hold(conn, w["wallet_id"], -w["amount"])
    await emit(conn, "withdrawal.rejected", "withdrawal", w["id"], {"amount": w["amount"], "reason": reason},
               company_id=w["company_id"])
    return w["id"]


async def mark_paid(conn, ctx: db.Context, pr: Principal, withdrawal_uid: uuid.UUID, bank_ref: str) -> int:
    """Records the bank transfer and posts it: the hold is released and the wallet debited in the same transaction."""
    finance(pr, "payout.run")
    w = await repo.withdrawal_for_update(conn, withdrawal_uid)
    if w is None:
        raise not_found("withdrawal")
    if w["status"] != "APPROVED" or (w["needs_second"] and w["second_approver"] is None):
        raise ApiError(409, "NOT_APPROVED", "the withdrawal still needs its approvals")
    if pr.user_id == w["requested_by"]:
        raise ApiError(403, "FOUR_EYES", "you cannot pay your own request")
    async with db.system_scope(conn, ctx):
        clearing = await platform_wallet(conn, "BANK_CLEARING", w["currency"])
        await repo.set_hold(conn, w["wallet_id"], -w["amount"])
        txn = await post_txn(conn, "PAYOUT", w["currency"], f"withdrawal:{w['id']}:paid",
                             [(w["wallet_id"], "DR", w["amount"]), (clearing["id"], "CR", w["amount"])],
                             ref_type="withdrawal", ref_id=w["id"], user_id=pr.user_id, memo=f"Bank transfer {bank_ref}")
        await conn.execute(
            """UPDATE fin.withdrawal_request SET status = 'PAID', bank_ref = $2, ledger_txn_id = $3, paid_by = $4, paid_at = now()
                WHERE id = $1""", w["id"], bank_ref, txn, pr.user_id)
        await emit(conn, "withdrawal.paid", "withdrawal", w["id"], {"amount": w["amount"], "bank_ref": bank_ref,
                                                                    "iban_last4": w["iban_last4"]}, company_id=w["company_id"])
    return w["id"]


async def all_withdrawals(conn, status: str | None) -> list[dict]:
    return rows(await repo.withdrawals(conn, None, status))


async def run_settlement(conn, pr: Principal, company_uid: uuid.UUID, start: date, end: date) -> tuple[int, str]:
    finance(pr, "payout.run")
    if end < start:
        raise ApiError(422, "INVALID_PERIOD", "the period ends before it starts")
    company = await conn.fetchval("SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1", company_uid)
    if company is None:
        raise not_found("company")
    lines = await repo.settlement_trips(conn, company, start, end)
    tot = {k: sum(r[k] for r in lines) for k in ("gross", "commission", "refunds", "net")}
    batch = await conn.fetchrow(
        """INSERT INTO fin.settlement_batch (company_id, period, currency, gross, commission, tax, refunds, net, created_by)
           VALUES ($1, daterange($2, $3, '[]'), 'SYP', $4, $5, 0, $6, $7, $8) RETURNING id, uid""",
        company, start, end, tot["gross"], tot["commission"], tot["refunds"], tot["net"], pr.user_id)
    await conn.executemany(
        """INSERT INTO fin.settlement_line (batch_id, trip_id, trip_no, gross, commission, tax, refunds, net)
           VALUES ($1, $2, $3, $4, $5, 0, $6, $7)""",
        [(batch["id"], r["trip_id"], r["trip_no"], r["gross"], r["commission"], r["refunds"], r["net"]) for r in lines])
    return batch["id"], str(batch["uid"])


async def approve_settlement(conn, pr: Principal, batch_uid: uuid.UUID) -> int:
    finance(pr, "payout.run", "ledger.reconcile")
    s = await conn.fetchrow("SELECT id, status, created_by FROM fin.settlement_batch WHERE uid = $1 FOR UPDATE", batch_uid)
    if s is None:
        raise not_found("settlement")
    if s["created_by"] == pr.user_id:
        raise ApiError(403, "FOUR_EYES", "the statement must be approved by someone other than its author")
    if s["status"] != "DRAFT":
        raise ApiError(409, "INVALID_TRANSITION", "only draft statements can be approved")
    await conn.execute("UPDATE fin.settlement_batch SET status = 'APPROVED', approved_by = $2, approved_at = now() WHERE id = $1",
                       s["id"], pr.user_id)
    return s["id"]


async def all_settlements(conn) -> list[dict]:
    return [row_dict(r) for r in await repo.settlements(conn)]

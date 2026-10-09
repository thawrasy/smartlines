"""Payments: money entering wallets from cards, partner e-wallets, bank transfers and agency counters, and refunds.

Rules every flow follows:
  - a payment is credited exactly once: only a PENDING payment can become SUCCESS, under a row lock, and a signed
    provider event is recorded once (unique provider + event id among signed notices, 1073);
  - the provider is called outside any database transaction and off the event loop, after the payment row is
    committed, with a merchant reference fixed by that row (review of 1.47.0, R-16, R-17);
  - the payer's fee comes from the platform's fee rules (fees.py), is shown before paying, asked from the provider on
    top of the amount and posted to platform revenue;
  - the amount and currency a provider reports must equal the payment's, otherwise nothing is credited;
  - every credit is one balanced ledger transaction (clearing account debited, wallet credited) with an idempotency key;
  - what the browser says never counts: cards and e-wallets are credited from the provider's signed notification or
    the provider's own answer to the confirmation call, bank transfers from the bank statement.
"""
import asyncio
import csv
import hashlib
import io
import json
import re
import secrets
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Optional

import asyncpg

from ... import db, markets
from ...errors import ApiError, not_found
from ...ledger import company_wallet, counted, platform_wallet, post_txn, user_wallet
from ..notify.outbox import emit
from ..sales import options
from ..sales import service as sales
from . import adapters, approvals, fees

OTP_MAX_ATTEMPTS = 5
PENDING_MINUTES = {"HOSTED_CARD": 30, "PARTNER_WALLET": 10, "INSTALLMENT": 30, "FINANCING": 24 * 60}


def _cfg(v) -> dict:
    return json.loads(v) if isinstance(v, str) else dict(v or {})


def provider_dict(row: asyncpg.Record) -> dict:
    d = dict(row)
    d["config"], d["fee_policy"] = _cfg(row["config"]), _cfg(row["fee_policy"])
    return d


async def provider(conn, code: str) -> dict:
    row = await conn.fetchrow("SELECT * FROM fin.payment_provider WHERE code = $1", code)
    if row is None:
        raise not_found("payment method")
    return provider_dict(row)


def mask(mobile: str) -> str:
    digits = re.sub(r"\D", "", mobile)
    return f"+{digits[:4]}{'*' * max(0, len(digits) - 6)}{digits[-2:]}" if len(digits) >= 8 else "***"


async def methods(conn, purpose: str = "TOPUP", party_id: Optional[int] = None) -> list[dict]:
    """The ways of paying open to this payer, each with the fee rule that applies to them (shown before paying)."""
    rows = await conn.fetch(
        """SELECT id, code, name, kind, adapter, min_amount, max_amount, fee_policy, config FROM fin.payment_provider
            WHERE status = 'ACTIVE' AND $1 = ANY(purposes) ORDER BY sort_order""", purpose)
    currency = (await markets.of_party(conn, party_id)).currency if party_id else (await markets.default(conn)).currency
    out = []
    for r in rows:
        p = provider_dict(r)
        if p["adapter"] == "SANDBOX" and not adapters.get_settings().sandbox:
            continue
        f = await fees.fee_for(conn, p, currency, 0, party_id)
        out.append({"code": p["code"], "name": p["name"], "kind": p["kind"], "adapter": p["adapter"], "min_amount": p["min_amount"],
                    "max_amount": p["max_amount"], "currency": currency, "fee_pct": f["pct"], "fee_fixed": f["fixed_amount"],
                    "fee_borne_by": f["borne_by"], "fee_label": f["label"]})
    return out


def _payment_out(row) -> dict:
    return {"uid": str(row["uid"]), "status": row["status"], "stage": row["stage"], "amount": row["amount"], "currency": row["currency"],
            "fee": row["fee"], "total": row["amount"] + row["fee"], "method": row["method"], "provider": row["provider_code"] if "provider_code" in row.keys() else None,
            "checkout_url": row["checkout_url"], "expires_at": row["expires_at"].isoformat() if row["expires_at"] else None,
            "failure_code": row["failure_code"], "created_at": row["created_at"].isoformat()}


# ------------------------------------------------------------------ cards and partner e-wallets
# A payment is written and committed before its provider is called, and the call runs in a thread outside any
# transaction (review of 1.47.0, R-16): a slow provider holds neither a database connection nor the event loop, and a
# payment the provider took always has its row here. The merchant reference is fixed by the row, so asking again after
# an unknown outcome is the same request to the provider, never a second charge. Three steps:
#   1. record (stage CREATED), committed;  2. call the provider, no transaction open;
#   3. record its answer under the row's lock: REDIRECTED or OTP_SENT, FAILED when it refused, PROVIDER_UNKNOWN when no
#      answer came (a signed notice or the expiry settles it; repeating the request asks again with the same reference).
PREFIX = {"HOSTED_CARD": "CRD", "INSTALLMENT": "INS", "FINANCING": "FIN", "PARTNER_WALLET": "EWL", "SANDBOX": "SBX"}
RESUMABLE = ("CREATED", "PROVIDER_UNKNOWN")


async def _provider_start(p: dict, pay, return_url: str, mobile: Optional[str], description: str):
    """Step 2, in a thread: what the provider answered, or the error that says it did not."""
    adapter = adapters.ADAPTERS[p["adapter"]]
    payload = {"uid": str(pay["uid"]), "reference": pay["provider_ref"], "amount": pay["amount"] + pay["fee"],
               "currency": pay["currency"], "description": description}
    args = (p, payload, return_url.replace("{uid}", str(pay["uid"])))
    if p["adapter"] == "PARTNER_WALLET":
        args += (mobile or "",)
    try:
        return await asyncio.to_thread(adapter.start, *args), None
    except ApiError as exc:
        return None, exc


async def _record_start(conn, p: dict, pay_id: int, action, error, user_id: Optional[int]):
    """Step 3, under the payment's lock."""
    pay = await conn.fetchrow("SELECT * FROM fin.payment WHERE id = $1 FOR UPDATE", pay_id)
    if pay["status"] != "PENDING" or pay["stage"] not in RESUMABLE:
        return pay                              # a signed notice settled it meanwhile, or the payer cancelled it
    if error is None:
        stage = {"REDIRECT": "REDIRECTED", "OTP": "OTP_SENT", "DONE": "REDIRECTED"}[action.kind]
        pay = await conn.fetchrow(
            """UPDATE fin.payment SET checkout_url = $2, stage = $3, provider_attempts = provider_attempts + 1,
                      provider_checked_at = now() WHERE id = $1 RETURNING *""", pay_id, action.url, stage)
        if action.kind == "DONE":               # the sandbox gateway answers at once
            pay = await _succeed(conn, p, pay, user_id, card_last4=None)
        return pay
    if isinstance(error, adapters.ProviderRefused):
        return await conn.fetchrow(
            """UPDATE fin.payment SET status = 'FAILED', stage = 'FAILED', failure_code = 'PROVIDER_REFUSED',
                      provider_attempts = provider_attempts + 1, provider_checked_at = now() WHERE id = $1 RETURNING *""", pay_id)
    if isinstance(error, adapters.ProviderUnknown):
        return await conn.fetchrow(
            """UPDATE fin.payment SET stage = 'PROVIDER_UNKNOWN', provider_attempts = provider_attempts + 1,
                      provider_checked_at = now() WHERE id = $1 RETURNING *""", pay_id)
    return pay                                  # nothing was sent (circuit open, not configured): it stays CREATED


def _start_result(p: dict, pay, action, error) -> dict:
    if error is not None and pay["status"] == "PENDING":
        if isinstance(error, adapters.ProviderUnknown) or pay["stage"] == "PROVIDER_UNKNOWN":
            raise ApiError(502, "PAYMENT_PROVIDER_UNAVAILABLE", "the payment provider did not answer; the payment is kept and "
                           "the same request asks it again", payment=str(pay["uid"]), retry_after=5)
        raise error                             # nothing sent: the same request later resumes this payment
    if error is not None:
        raise ApiError(502, "PAYMENT_PROVIDER_REFUSED", "the payment provider refused this payment", payment=str(pay["uid"]))
    out = {**_payment_out(pay), "provider": p["code"], "action": action.kind if action else None, "url": action.url if action else None}
    if action and action.details.get("test_code"):
        out["test_code"] = action.details["test_code"]     # sandbox only: lets testers finish the flow
    return out


async def start_topup(ctx: db.Context, party_id: int, user_id: int, code: str, amount: int, key: str,
                      mobile: Optional[str], return_url: str) -> dict:
    async with db.transaction(ctx) as conn:                                       # step 1
        p = await provider(conn, code)
        if p["status"] != "ACTIVE" or "TOPUP" not in p["purposes"]:
            raise ApiError(409, "PAYMENT_METHOD_UNAVAILABLE", "this payment method is not available")
        if p["adapter"] in ("BANK_TRANSFER", "CASH_AGENT"):
            raise ApiError(409, "PAYMENT_METHOD_UNAVAILABLE", "use the bank transfer or agency flow")
        if not p["min_amount"] <= amount <= p["max_amount"]:
            raise ApiError(422, "PAYMENT_AMOUNT_OUT_OF_RANGE", "amount outside the method's limits",
                           min_amount=p["min_amount"], max_amount=p["max_amount"])
        if p["adapter"] == "PARTNER_WALLET" and not (mobile and re.fullmatch(r"\+?[0-9]{8,15}", mobile)):
            raise ApiError(422, "PAYER_MOBILE_REQUIRED", "the mobile number of the e-wallet is required")
        async with db.system_scope(conn, ctx):
            pay = await conn.fetchrow("SELECT p.*, pv.code AS provider_code FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id "
                                      "WHERE p.idempotency_key = $1 AND p.payer_party_id = $2", key, party_id)
            if pay and not (pay["status"] == "PENDING" and pay["stage"] in RESUMABLE):
                return {**_payment_out(pay), "replayed": True}
            if pay is None:
                currency = (await markets.of_party(conn, party_id)).currency          # the passenger's market (1061)
                w = await user_wallet(conn, party_id, currency)
                f = await fees.fee_for(conn, p, currency, amount, party_id)
                uid = uuid.uuid4()
                pay = await conn.fetchrow(
                    """INSERT INTO fin.payment (uid, provider_id, purpose, payer_party_id, wallet_id, method, currency, amount, fee,
                                                fee_absorbed, fee_rule_id, idempotency_key, payer_mobile_mask, provider_ref, stage, expires_at)
                       VALUES ($1, $2, 'TOPUP', $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 'CREATED',
                               now() + make_interval(mins => $14)) RETURNING *""",
                    uid, p["id"], party_id, w["id"], {"HOSTED_CARD": "CARD", "PARTNER_WALLET": "E_WALLET"}.get(p["adapter"], "CARD"),
                    currency, amount, f["fee"], f["absorbed"], f["rule_id"], key, mask(mobile) if mobile else None,
                    adapters.reference(PREFIX.get(p["adapter"], "PAY"), uid), PENDING_MINUTES.get(p["adapter"], 30))
    action, error = await _provider_start(p, pay, return_url, mobile, "Masslak wallet top-up")       # step 2
    async with db.transaction(ctx) as conn:                                       # step 3
        async with db.system_scope(conn, ctx):
            pay = await _record_start(conn, p, pay["id"], action, error, user_id)
    return _start_result(p, pay, action, error)


async def clearing_wallet(conn, p: dict, pay) -> asyncpg.Record:
    """The account the money comes from: the agency's prepaid balance, the bank account, or the gateway clearing account."""
    if p["adapter"] == "CASH_AGENT":
        return await company_wallet(conn, pay["agency_company_id"], pay["currency"], label="Agency wallet")
    if p["adapter"] == "BANK_TRANSFER":
        return await platform_wallet(conn, "BANK_CLEARING", pay["currency"])
    if p.get("clearing_wallet_id"):
        return await conn.fetchrow("SELECT * FROM fin.wallet WHERE id = $1", p["clearing_wallet_id"])
    return await platform_wallet(conn, "GATEWAY_CLEARING", pay["currency"])


# Payments the platform stopped waiting for; the provider may still confirm that it took the money (1071)
GAVE_UP = ("EXPIRED", "BOOKING_EXPIRED", "CANCELLED")


async def _succeed(conn, p: dict, pay, user_id: Optional[int], card_last4: Optional[str]):
    """Credits the wallet for a pending payment, once. The caller holds the system scope. A payment the platform gave up
    on (expired or cancelled on this side) is credited too when the provider confirms it took the money: the money
    waits in the wallet, and finance is told, rather than being lost (code review of October 2026)."""
    row = await conn.fetchrow("SELECT * FROM fin.payment WHERE id = $1 FOR UPDATE", pay["id"])
    late = row["status"] == "FAILED" and row["failure_code"] in GAVE_UP
    if row["status"] != "PENDING" and not late:
        return row
    clearing = await clearing_wallet(conn, p, row)
    lines = [(clearing["id"], "DR", row["amount"] + row["fee"]), (row["wallet_id"], "CR", row["amount"])]
    if row["fee"]:                              # the payer's fee, taken with the amount, is platform revenue (1074)
        lines.append(((await platform_wallet(conn, "PLATFORM", row["currency"]))["id"], "CR", row["fee"]))
    txn = await post_txn(conn, "TOPUP", row["currency"], f"payment:{row['id']}", lines,
                         ref_type="payment", ref_id=row["id"], user_id=user_id, memo=row["provider_ref"])
    done = await conn.fetchrow(
        """UPDATE fin.payment SET status = 'SUCCESS', stage = 'CONFIRMED', ledger_txn_id = $2, settled_at = now(),
                  card_last4 = coalesce($3, card_last4), failure_code = NULL, captured_late = $4 WHERE id = $1 RETURNING *""",
        row["id"], txn, card_last4, late)
    if late:
        await emit(conn, "payment.captured_late", "payment", done["id"], {
            "payment": str(done["uid"]), "amount": done["amount"], "currency": done["currency"],
            "gave_up_because": row["failure_code"], "booking_id": done["booking_id"]})
    if done["purpose"] == "BOOKING" and done["booking_id"]:
        # the money of a reserved booking (1056): it reached the payer's wallet above and pays the booking from there;
        # if the reservation has lapsed meanwhile, it simply stays in the wallet (refundable to its source by finance)
        w = await conn.fetchrow("SELECT * FROM fin.wallet WHERE id = $1", done["wallet_id"])
        await sales.settle_reserved(conn, done["booking_id"], w, user_id)
    return done


# ------------------------------------------------------------------ paying a reserved booking (1056)
async def start_booking_payment(ctx: db.Context, party_id: int, user_id: int, ref: str, code: str, key: str,
                                return_url: str, channel: str = "WEB") -> dict:
    """Sends the passenger to the provider of the option their reservation was made with (card, instalments, financing);
    the option must still be open on the channel paying (WEB or APP). The same three steps as a top-up."""
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            b = await conn.fetchrow("SELECT * FROM sales.booking WHERE booking_ref = $1 AND booker_party_id = $2 FOR UPDATE",
                                    ref.upper(), party_id)
            if b is None:
                raise not_found("booking")
            pay = await conn.fetchrow("SELECT p.*, pv.code AS provider_code FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id "
                                      "WHERE p.idempotency_key = $1 AND p.payer_party_id = $2", key, party_id)
            if pay and not (pay["status"] == "PENDING" and pay["stage"] in RESUMABLE):
                return {**_payment_out(pay), "replayed": True}
            p = await provider(conn, code)
            if pay is None:
                if b["status"] != "PENDING_PAYMENT":
                    raise ApiError(409, "BOOKING_NOT_PENDING", "this booking is not waiting for payment", booking_status=b["status"])
                if b["hold_expires_at"] is not None and b["hold_expires_at"] <= datetime.now(timezone.utc):
                    raise ApiError(409, "RESERVATION_EXPIRED", "the time to pay this reservation has passed")
                adapter_name = options.PROVIDER_OPTIONS.get(b["pay_option"])
                if adapter_name is None:
                    raise ApiError(409, "PAY_AT_COUNTER", "this reservation is paid in cash at the carrier's counter")
                await options.require(conn, b["pay_option"], channel, b["total_amount"])
                if p["status"] != "ACTIVE" or "BOOKING" not in p["purposes"] or p["adapter"] != adapter_name:
                    raise ApiError(409, "PAYMENT_METHOD_UNAVAILABLE", "this provider does not take this kind of payment")
                if not p["min_amount"] <= b["total_amount"] <= p["max_amount"]:
                    raise ApiError(422, "PAYMENT_AMOUNT_OUT_OF_RANGE", "amount outside the provider's limits",
                                   min_amount=p["min_amount"], max_amount=p["max_amount"])
                if await conn.fetchval("SELECT 1 FROM fin.payment WHERE booking_id = $1 AND purpose = 'BOOKING' AND status = 'PENDING' "
                                       "AND (expires_at IS NULL OR expires_at > now())", b["id"]):
                    raise ApiError(409, "PAYMENT_IN_PROGRESS", "a payment for this booking is already in progress")
                w = await user_wallet(conn, party_id, b["currency"])
                f = await fees.fee_for(conn, p, b["currency"], b["total_amount"], party_id)
                uid = uuid.uuid4()
                pay = await conn.fetchrow(
                    """INSERT INTO fin.payment (uid, provider_id, purpose, booking_id, payer_party_id, wallet_id, method, currency, amount,
                                                fee, fee_absorbed, fee_rule_id, idempotency_key, provider_ref, stage, expires_at)
                       VALUES ($1, $2, 'BOOKING', $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 'CREATED',
                               least(now() + make_interval(mins => $14), $15)) RETURNING *""",
                    uid, p["id"], b["id"], party_id, w["id"], options.PAY_METHOD[b["pay_option"]], b["currency"], b["total_amount"],
                    f["fee"], f["absorbed"], f["rule_id"], key, adapters.reference(PREFIX.get(p["adapter"], "PAY"), uid),
                    PENDING_MINUTES.get(p["adapter"], 30), b["hold_expires_at"])
    action, error = await _provider_start(p, pay, return_url, None, f"Masslak booking {ref.upper()}")
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            pay = await _record_start(conn, p, pay["id"], action, error, user_id)
    return _start_result(p, pay, action, error)


async def _fail(conn, pay, code: str) -> asyncpg.Record:
    return await conn.fetchrow("UPDATE fin.payment SET status = 'FAILED', stage = 'FAILED', failure_code = $2 WHERE id = $1 AND status = 'PENDING' "
                               "RETURNING *", pay["id"], code) or pay


async def record_rejected(conn, ctx: db.Context, p: dict, raw: bytes, ip: str) -> None:
    """A notification that could not even be read is still kept, for the security review."""
    async with db.system_scope(conn, ctx):
        await conn.execute(
            """INSERT INTO fin.payment_notification (provider_id, event_id, signature_valid, source_ip, payload)
               VALUES ($1, $2, false, $3::inet, $4::jsonb)""",
            p["id"], "unreadable-" + hashlib.sha256(raw).hexdigest()[:32], ip, json.dumps({"raw": raw[:2000].decode("utf-8", "replace")}))


def notice_matches(notice: adapters.Notice, pay) -> bool:
    """What the provider says it took is what the payment asked: the amount with the payer's fee, and the currency. A
    notice or confirmation without a currency is in the payment's own (1061). Used for signed notices and for wallet
    codes alike (R-19)."""
    return notice.amount == pay["amount"] + pay["fee"] and (notice.currency or pay["currency"]) == pay["currency"]


async def apply_notice(conn, ctx: db.Context, p: dict, notice: adapters.Notice, raw: dict, signature_valid: bool, ip: str) -> dict:
    """Records a provider notification and, when it is valid and new, settles the payment it names."""
    async with db.system_scope(conn, ctx):
        pay = await conn.fetchrow("SELECT * FROM fin.payment WHERE provider_id = $1 AND provider_ref = $2", p["id"], notice.provider_ref)
        # notifications are append-only: a valid one is processed in this same transaction, so it is stamped on insert.
        # Only a signed notice takes its event id (1073): an unsigned copy posted first cannot make the real one a replay.
        nid = await conn.fetchval(
            """INSERT INTO fin.payment_notification (provider_id, event_id, payment_id, signature_valid, source_ip, payload, processed_at)
               VALUES ($1, $2, $3, $4, $5::inet, $6::jsonb, CASE WHEN $4 AND $3::bigint IS NOT NULL THEN now() END)
               ON CONFLICT (provider_id, event_id) WHERE signature_valid DO NOTHING RETURNING id""",
            p["id"], notice.event_id, pay["id"] if pay else None, signature_valid, ip, json.dumps(raw))
        if not signature_valid:
            return {"ok": False, "error": "BAD_SIGNATURE"}          # recorded; the caller refuses after the commit
        if nid is None:
            return {"ok": True, "replayed": True}
        if pay is None:
            raise not_found("payment")
        if not notice_matches(notice, pay):
            await _fail(conn, pay, "AMOUNT_MISMATCH")
            return {"ok": False, "error": "AMOUNT_MISMATCH"}
        if notice.status == "SUCCESS":
            pay = await _succeed(conn, p, pay, None, notice.card_last4)
        else:
            pay = await _fail(conn, pay, notice.failure_code or "DECLINED")
    return {"ok": True, "status": pay["status"]}


async def confirm_code(ctx: db.Context, party_id: int, user_id: int, uid: uuid.UUID, code: str) -> dict:
    """The payer's one-time code, checked by the provider. The attempt is counted and committed first; the provider is
    asked with no transaction open; its answer is recorded under the payment's lock (R-16)."""
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            pay = await conn.fetchrow("SELECT * FROM fin.payment WHERE uid = $1 AND payer_party_id = $2 FOR UPDATE", uid, party_id)
            if pay is None:
                raise not_found("payment")
            if pay["status"] != "PENDING" or pay["stage"] != "OTP_SENT":
                raise ApiError(409, "PAYMENT_NOT_PENDING", "this payment is not waiting for a code")
            if pay["expires_at"] and pay["expires_at"] < datetime.now(timezone.utc):
                await conn.execute("UPDATE fin.payment SET status = 'FAILED', stage = 'EXPIRED', failure_code = 'EXPIRED' WHERE id = $1", pay["id"])
                return {"error": "PAYMENT_EXPIRED"}
            if pay["otp_attempts"] >= OTP_MAX_ATTEMPTS:
                await _fail(conn, pay, "OTP_TOO_MANY_ATTEMPTS")
                return {"error": "OTP_TOO_MANY_ATTEMPTS"}
            pay = await conn.fetchrow("UPDATE fin.payment SET otp_attempts = otp_attempts + 1 WHERE id = $1 RETURNING *", pay["id"])
            p = provider_dict(await conn.fetchrow("SELECT * FROM fin.payment_provider WHERE id = $1", pay["provider_id"]))
    try:
        notice = await asyncio.to_thread(adapters.ADAPTERS[p["adapter"]].confirm, p, {
            "uid": str(uid), "amount": pay["amount"] + pay["fee"], "currency": pay["currency"], "provider_ref": pay["provider_ref"]}, code)
    except adapters.ProviderUnknown:
        return {"status": "PENDING", "stage": "OTP_SENT", "waiting_for_provider": True}   # its signed notice will settle it
    except adapters.ProviderRefused:
        notice = adapters.Notice(event_id="", provider_ref=pay["provider_ref"], status="FAILED", amount=0, currency=None,
                                 failure_code="OTP_INVALID")
    if notice is None:
        return {"status": "PENDING", "stage": "OTP_SENT"}
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            pay = await conn.fetchrow("SELECT * FROM fin.payment WHERE id = $1 FOR UPDATE", pay["id"])
            if pay["status"] != "PENDING":
                return {"status": pay["status"], "stage": pay["stage"], "failure_code": pay["failure_code"]}
            if notice.status != "SUCCESS" and notice.failure_code == "OTP_INVALID":
                left = OTP_MAX_ATTEMPTS - pay["otp_attempts"]
                if left <= 0:
                    await _fail(conn, pay, "OTP_TOO_MANY_ATTEMPTS")
                return {"error": "OTP_INVALID", "attempts_left": max(0, left)}
            await conn.execute(
                """INSERT INTO fin.payment_notification (provider_id, event_id, payment_id, signature_valid, source_ip, payload, processed_at)
                   VALUES ($1, $2, $3, true, $4::inet, $5::jsonb, now()) ON CONFLICT (provider_id, event_id) WHERE signature_valid DO NOTHING""",
                p["id"], notice.event_id, pay["id"], ctx.ip, json.dumps({"confirm": notice.status, "reference": notice.provider_ref}))
            if not notice_matches(notice, pay):          # the same check as a signed notice, currency included (R-19)
                await _fail(conn, pay, "AMOUNT_MISMATCH")
                return {"error": "AMOUNT_MISMATCH"}
            pay = await (_succeed(conn, p, pay, user_id, None) if notice.status == "SUCCESS"
                         else _fail(conn, pay, notice.failure_code or "DECLINED"))
    return {"status": pay["status"], "stage": pay["stage"], "failure_code": pay["failure_code"]}


async def status_of(conn, ctx: db.Context, party_id: Optional[int], uid: uuid.UUID) -> dict:
    async with db.system_scope(conn, ctx):
        row = await conn.fetchrow(
            """SELECT p.*, pv.code AS provider_code FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id
                WHERE p.uid = $1 AND ($2::bigint IS NULL OR p.payer_party_id = $2)""", uid, party_id)
        if row is None:
            raise not_found("payment")
        if row["status"] == "PENDING" and row["expires_at"] and row["expires_at"] < datetime.now(timezone.utc):
            row = await conn.fetchrow("UPDATE fin.payment SET status = 'FAILED', stage = 'EXPIRED', failure_code = 'EXPIRED' "
                                      "WHERE id = $1 AND status = 'PENDING' RETURNING *, $2::text AS provider_code", row["id"], row["provider_code"]) or row
        out = _payment_out(row)
        out["provider"] = row["provider_code"]
        if row["method"] == "BANK":
            t = await conn.fetchrow("SELECT virtual_ref, expires_at, status FROM fin.bank_transfer_topup WHERE payment_id = $1", row["id"])
            if t:
                out["reference"] = t["virtual_ref"]
    return out


async def cancel(conn, ctx: db.Context, party_id: int, uid: uuid.UUID) -> dict:
    async with db.system_scope(conn, ctx):
        row = await conn.fetchrow("UPDATE fin.payment SET status = 'FAILED', stage = 'CANCELLED', failure_code = 'CANCELLED' "
                                  "WHERE uid = $1 AND payer_party_id = $2 AND status = 'PENDING' RETURNING id", uid, party_id)
        if row:
            await conn.execute("UPDATE fin.bank_transfer_topup SET status = 'REJECTED' WHERE payment_id = $1 AND status = 'AWAITING'", row["id"])
    if row is None:
        raise ApiError(409, "PAYMENT_NOT_PENDING", "nothing to cancel")
    return {"ok": True}


async def expire_stale(conn) -> int:
    # a transfer whose statement line waits for its approval is not given up on (1074)
    rows = await conn.fetch(
        """UPDATE fin.payment p SET status = 'FAILED', stage = 'EXPIRED', failure_code = 'EXPIRED'
            WHERE p.status = 'PENDING' AND p.expires_at < now()
              AND NOT EXISTS (SELECT 1 FROM fin.bank_transfer_topup t JOIN fin.bank_statement_line l ON l.topup_id = t.id
                               WHERE t.payment_id = p.id AND l.status = 'PROPOSED')
           RETURNING p.id""")
    if rows:
        await conn.execute("UPDATE fin.bank_transfer_topup SET status = 'REJECTED' WHERE status = 'AWAITING' AND payment_id = ANY($1::bigint[])",
                           [r["id"] for r in rows])
    return len(rows)


# ------------------------------------------------------------------ bank transfers
def make_reference() -> str:
    """MSL + 9 random digits + 2 check digits (ISO 7064 mod 97-10), so a mistyped reference is caught."""
    body = f"{secrets.randbelow(10**9):09d}"
    check = 98 - (int(body + "00") % 97)
    return f"MSL{body}{check:02d}"


def valid_reference(ref: str) -> bool:
    m = re.fullmatch(r"MSL(\d{9})(\d{2})", ref)
    return bool(m) and int(m.group(1) + m.group(2)) % 97 == 1


def find_reference(text: str) -> Optional[str]:
    flat = re.sub(r"[^A-Z0-9]", "", (text or "").upper())
    for m in re.finditer(r"MSL\d{11}", flat):
        if valid_reference(m.group(0)):
            return m.group(0)
    return None


async def start_bank_transfer(conn, ctx: db.Context, party_id: int, amount: int, key: str) -> dict:
    p = await provider(conn, "BANK")
    if p["status"] != "ACTIVE":
        raise ApiError(409, "PAYMENT_METHOD_UNAVAILABLE", "bank transfers are not available")
    if not p["min_amount"] <= amount <= p["max_amount"]:
        raise ApiError(422, "PAYMENT_AMOUNT_OUT_OF_RANGE", "amount outside the method's limits", min_amount=p["min_amount"], max_amount=p["max_amount"])
    cfg = p["config"]
    days = int(cfg.get("valid_days", 3))
    async with db.system_scope(conn, ctx):
        existing = await conn.fetchrow("SELECT p.id FROM fin.payment p WHERE p.idempotency_key = $1 AND p.payer_party_id = $2", key, party_id)
        if existing is None:
            open_count = await conn.fetchval("SELECT count(*) FROM fin.payment WHERE payer_party_id = $1 AND method = 'BANK' AND status = 'PENDING'",
                                             party_id)
            if open_count >= 3:
                raise ApiError(409, "TOO_MANY_OPEN_TRANSFERS", "finish or cancel your open bank transfers first")
            currency = (await markets.of_party(conn, party_id)).currency
            w = await user_wallet(conn, party_id, currency)
            for _ in range(5):
                ref = make_reference()
                if not await conn.fetchval("SELECT 1 FROM fin.bank_transfer_topup WHERE virtual_ref = $1", ref):
                    break
            pay_id = await conn.fetchval(
                """INSERT INTO fin.payment (provider_id, purpose, payer_party_id, wallet_id, method, currency, amount, idempotency_key, provider_ref,
                                            stage, expires_at)
                   VALUES ($1, 'TOPUP', $2, $3, 'BANK', $8, $4, $5, $6, 'AWAITING_TRANSFER', now() + make_interval(days => $7)) RETURNING id""",
                p["id"], party_id, w["id"], amount, key, ref, days, currency)
            await conn.execute(
                """INSERT INTO fin.bank_transfer_topup (wallet_id, virtual_ref, amount, status, payment_id, expires_at)
                   VALUES ($1, $2, $3, 'AWAITING', $4, now() + make_interval(days => $5))""", w["id"], ref, amount, pay_id, days)
        else:
            pay_id = existing["id"]
        row = await conn.fetchrow("SELECT p.*, t.virtual_ref FROM fin.payment p JOIN fin.bank_transfer_topup t ON t.payment_id = p.id WHERE p.id = $1",
                                  pay_id)
    return {**_payment_out(row), "provider": "BANK", "action": "TRANSFER", "reference": row["virtual_ref"],
            "bank": {"bank_name": cfg.get("bank_name", ""), "account_name": cfg.get("account_name", ""), "iban": cfg.get("iban", "")}}


def parse_amount(text: str, decimal_mark: str = ".") -> Decimal:
    """An amount as a bank writes it, read with the file's decimal mark: "1,234.50" with ".", "1.234,50" with ",".
    The other mark may only group thousands; anything else is refused rather than read as another number (R-24)."""
    raw = (text or "").strip().replace("\u066b", decimal_mark).replace("\u066c", "," if decimal_mark == "." else ".")
    bad = ApiError(422, "STATEMENT_BAD_AMOUNT", f"cannot read the amount {text!r} with the decimal mark {decimal_mark!r}")
    negative = raw.startswith("-") or raw.endswith("-") or (raw.startswith("(") and raw.endswith(")"))
    body = "".join(ch for ch in raw if ch.isdigit() or ch in ".,")
    group = "," if decimal_mark == "." else "."
    if not body or body.count(decimal_mark) > 1:
        raise bad
    whole, _, frac = body.partition(decimal_mark)
    parts = whole.split(group)
    if group in frac or (len(parts) > 1 and (not 1 <= len(parts[0]) <= 3 or any(len(x) != 3 for x in parts[1:]))):
        raise bad
    try:
        value = Decimal("".join(parts) or "0") + (Decimal("0." + frac) if frac else 0)
    except InvalidOperation as e:
        raise bad from e
    return -value if negative else value


def to_minor(value: Decimal, minor_unit: int) -> int:
    """In the currency's minor unit; more decimals than the currency has is an error, never rounded away (R-24)."""
    scaled = value.scaleb(minor_unit)
    if scaled != scaled.to_integral_value():
        raise ApiError(422, "STATEMENT_BAD_AMOUNT", f"{value} has more decimals than its currency ({minor_unit})")
    return int(scaled)


FIELDS = {"value_date": ("value_date", "date", "booking_date"), "amount": ("amount", "credit"),
          "currency": ("currency",), "reference": ("reference", "description", "details", "narrative"),
          "payer": ("payer", "name", "sender", "remitter"), "bank_ref": ("bank_ref", "transaction_id", "transaction", "ref", "id")}


def parse_statement(data: bytes, decimal_mark: str = ".") -> list[dict]:
    """A CSV export of the bank account: one header row, then one line per transaction; debits are skipped. Amounts
    stay decimal here: they are put in minor units with the currency of each line (import_statement)."""
    text = data.decode("utf-8-sig", errors="replace")
    rows = list(csv.reader(io.StringIO(text)))
    if len(rows) < 2:
        raise ApiError(422, "STATEMENT_EMPTY", "the file has no transactions")
    head = [h.strip().lower() for h in rows[0]]
    col = {}
    for field, names in FIELDS.items():
        for i, h in enumerate(head):
            if h in names:
                col[field] = i
                break
    missing = {"value_date", "amount", "bank_ref"} - set(col)
    if missing:
        raise ApiError(422, "STATEMENT_COLUMNS_MISSING", "missing columns: " + ", ".join(sorted(missing)))
    out = []
    for r in rows[1:]:
        if not any(x.strip() for x in r):
            continue
        get = lambda f: r[col[f]].strip() if f in col and col[f] < len(r) else ""   # noqa: E731
        amount = parse_amount(get("amount"), decimal_mark)
        if amount <= 0:
            continue
        try:
            d = date.fromisoformat(get("value_date")[:10])
        except ValueError as e:
            raise ApiError(422, "STATEMENT_BAD_DATE", f"bad date {get('value_date')!r}") from e
        out.append({"value_date": d, "amount": amount, "currency": (get("currency") or "").upper()[:3] or None, "reference": get("reference")[:300],
                    "payer": get("payer")[:120], "bank_ref": get("bank_ref")[:80]})
    if len(out) > 5000:
        raise ApiError(422, "STATEMENT_TOO_LARGE", "at most 5000 lines per file")
    return out


async def _credit_transfer(conn, line_id: int, topup, user_id: int) -> None:
    p = await provider(conn, "BANK")
    pay = await conn.fetchrow("SELECT * FROM fin.payment WHERE id = $1", topup["payment_id"])
    pay = await _succeed(conn, p, pay, user_id, None)
    await conn.execute("UPDATE fin.bank_transfer_topup SET status = 'MATCHED', matched_at = now(), ledger_txn_id = $2, matched_by = $3, "
                       "statement_line_id = $4 WHERE id = $1", topup["id"], pay["ledger_txn_id"], user_id, line_id)
    await conn.execute("UPDATE fin.bank_statement_line SET status = 'MATCHED', topup_id = $2, decided_by = $3, decided_at = now() WHERE id = $1",
                       line_id, topup["id"], user_id)


async def _propose(conn, line_id: int, topup, user_id: int, credit_received: bool = False) -> Optional[dict]:
    """A line matched to a transfer, by the import or by hand. Under the approval matrix (decision 5, R-23) it waits as
    PROPOSED for its levels; with no level needed for this amount it is credited at once. Returns the request, if any."""
    ln = await conn.fetchrow(
        """UPDATE fin.bank_statement_line SET status = 'PROPOSED', topup_id = $2, proposed_by = $3, credit_received = $4
            WHERE id = $1 RETURNING *""", line_id, topup["id"], user_id, credit_received)
    request = await approvals.open_request(conn, "BANK_CREDIT", line_id, ln["amount"], ln["currency"].strip(),
                                           f"Bank credit {ln['amount']} {ln['currency'].strip()} to transfer {topup['virtual_ref']} "
                                           f"(statement line {ln['bank_ref']})", user_id)
    if request is None:
        await credit_line(conn, line_id, user_id)
    return request


async def credit_line(conn, line_id: int, user_id: int) -> None:
    """Credits a proposed line once its approval is complete (or none was needed). A line matched with another amount
    corrects the transfer to what arrived first. The caller holds the system scope."""
    ln = await conn.fetchrow("SELECT * FROM fin.bank_statement_line WHERE id = $1 FOR UPDATE", line_id)
    if ln["status"] != "PROPOSED":
        raise ApiError(409, "LINE_ALREADY_DECIDED", "this line is not waiting to be credited")
    topup = await conn.fetchrow("SELECT * FROM fin.bank_transfer_topup WHERE id = $1 FOR UPDATE", ln["topup_id"])
    if topup["amount"] != ln["amount"]:
        if not ln["credit_received"]:
            raise ApiError(409, "AMOUNT_DIFFERS", "amounts differ", expected=topup["amount"], received=ln["amount"])
        await conn.execute("UPDATE fin.bank_transfer_topup SET amount = $2 WHERE id = $1", topup["id"], ln["amount"])
        await conn.execute("UPDATE fin.payment SET amount = $2 WHERE id = $1 AND status = 'PENDING'", topup["payment_id"], ln["amount"])
        topup = await conn.fetchrow("SELECT * FROM fin.bank_transfer_topup WHERE id = $1", topup["id"])
    if topup["expires_at"] and topup["expires_at"] < datetime.now(timezone.utc):
        await conn.execute("UPDATE fin.payment SET expires_at = now() + interval '1 hour' WHERE id = $1 AND status = 'PENDING'",
                           topup["payment_id"])
    await _credit_transfer(conn, line_id, topup, user_id)


async def unpropose_line(conn, line_id: int, note: str) -> None:
    """An approver rejected the match: the line goes back to the lines to review, the transfer stays open."""
    await conn.execute("""UPDATE fin.bank_statement_line SET status = 'UNMATCHED', topup_id = NULL, credit_received = false,
                                 note = $2 WHERE id = $1 AND status = 'PROPOSED'""", line_id, note[:300])


async def import_statement(conn, ctx: db.Context, user_id: int, account_label: str, data: bytes, decimal_mark: str = ".") -> dict:
    lines = parse_statement(data, decimal_mark)
    digest = hashlib.sha256(data).digest()
    async with db.system_scope(conn, ctx):
        if await conn.fetchval("SELECT 1 FROM fin.bank_statement_import WHERE account_label = $1 AND file_sha256 = $2", account_label, digest):
            raise ApiError(409, "STATEMENT_ALREADY_IMPORTED", "this file was already imported")
        imp = await conn.fetchrow("INSERT INTO fin.bank_statement_import (account_label, file_sha256, line_count, imported_by) "
                                  "VALUES ($1, $2, $3, $4) RETURNING id, uid", account_label, digest, len(lines), user_id)
        matched = proposed = 0
        for ln in lines:
            if await conn.fetchval("SELECT 1 FROM fin.bank_statement_line WHERE bank_ref = $1 AND status IN ('PROPOSED', 'MATCHED')",
                                   ln["bank_ref"]):
                continue                                       # the same bank transaction in an overlapping statement
            ref = find_reference(ln["reference"])
            topup = await conn.fetchrow(
                "SELECT t.*, w.currency FROM fin.bank_transfer_topup t JOIN fin.wallet w ON w.id = t.wallet_id "
                "WHERE t.virtual_ref = $1 FOR UPDATE OF t", ref) if ref else None
            if ln["currency"] is None:                     # a statement without a currency column is in the transfer's
                ln["currency"] = topup["currency"] if topup else (await markets.default(conn)).currency
            minor_unit = await conn.fetchval("SELECT minor_unit FROM ref.currency WHERE code = $1", ln["currency"])
            if minor_unit is None:
                raise ApiError(422, "STATEMENT_BAD_CURRENCY", f"unknown currency {ln['currency']!r} on line {ln['bank_ref']}")
            ln["amount"] = to_minor(ln["amount"], minor_unit)  # the currency's own decimals, not always two (R-24)
            note = None
            if ref is None:
                note = "NO_REFERENCE"
            elif topup is None:
                note = "UNKNOWN_REFERENCE"
            elif topup["status"] != "AWAITING" or await conn.fetchval(
                    "SELECT 1 FROM fin.bank_statement_line WHERE topup_id = $1 AND status IN ('PROPOSED', 'MATCHED')", topup["id"]):
                note = "TOPUP_NOT_AWAITING"
            elif topup["amount"] != ln["amount"] or ln["currency"] != topup["currency"]:
                note = "AMOUNT_DIFFERS"
            line_id = await conn.fetchval(
                """INSERT INTO fin.bank_statement_line (import_id, value_date, amount, currency, reference, payer, bank_ref, note)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (import_id, bank_ref) DO NOTHING RETURNING id""",
                imp["id"], ln["value_date"], ln["amount"], ln["currency"], ln["reference"], ln["payer"], ln["bank_ref"], note)
            if line_id and note is None:
                if await _propose(conn, line_id, topup, user_id) is None:
                    matched += 1
                else:
                    proposed += 1
        await conn.execute("UPDATE fin.bank_statement_import SET matched_count = $2 WHERE id = $1", imp["id"], matched)
    return {"uid": str(imp["uid"]), "lines": len(lines), "matched": matched, "awaiting_approval": proposed,
            "unmatched": len(lines) - matched - proposed}


async def match_line(conn, ctx: db.Context, user_id: int, line_id: int, reference: str, credit_received: bool) -> dict:
    """Finance matches an unmatched line by hand. A different amount is only accepted when finance confirms crediting
    what actually arrived; the transfer is corrected to that amount when the line is credited, after its approval."""
    async with db.system_scope(conn, ctx):
        ln = await conn.fetchrow("SELECT * FROM fin.bank_statement_line WHERE id = $1 FOR UPDATE", line_id)
        if ln is None:
            raise not_found("statement line")
        if ln["status"] != "UNMATCHED":
            raise ApiError(409, "LINE_ALREADY_DECIDED", "this line was already decided")
        ref = find_reference(reference) or reference.strip().upper()
        topup = await conn.fetchrow("SELECT * FROM fin.bank_transfer_topup WHERE virtual_ref = $1 FOR UPDATE", ref)
        if topup is None or topup["status"] != "AWAITING" or await conn.fetchval(
                "SELECT 1 FROM fin.bank_statement_line WHERE topup_id = $1 AND status IN ('PROPOSED', 'MATCHED')", topup["id"]):
            raise ApiError(409, "TOPUP_NOT_AWAITING", "no open transfer with this reference")
        if topup["amount"] != ln["amount"] and not credit_received:
            raise ApiError(409, "AMOUNT_DIFFERS", "amounts differ", expected=topup["amount"], received=ln["amount"])
        await conn.execute("UPDATE fin.bank_statement_line SET note = $2 WHERE id = $1", line_id,
                           "MATCHED_BY_HAND" if topup["amount"] == ln["amount"] else "AMOUNT_CORRECTED")
        request = await _propose(conn, line_id, topup, user_id, credit_received=topup["amount"] != ln["amount"])
    return {"ok": True, "status": "PROPOSED" if request else "MATCHED", "approval": request}


async def ignore_line(conn, ctx: db.Context, user_id: int, line_id: int, note: str) -> dict:
    async with db.system_scope(conn, ctx):
        done = await conn.fetchval("UPDATE fin.bank_statement_line SET status = 'IGNORED', note = $3, decided_by = $2, decided_at = now() "
                                   "WHERE id = $1 AND status = 'UNMATCHED' RETURNING id", line_id, user_id, note)
    if not done:
        raise ApiError(409, "LINE_ALREADY_DECIDED", "this line was already decided")
    return {"ok": True}


# ------------------------------------------------------------------ agency counters
async def passenger_by_mobile(conn, mobile: str, required: bool = True):
    """The active passenger account registered with this mobile (local or international form). The caller holds the system scope."""
    digits = re.sub(r"\D", "", mobile)
    person = await conn.fetchrow(
        """SELECT p.id, p.legal_name FROM iam.party p JOIN iam.app_user u ON u.party_id = p.id
            WHERE regexp_replace(coalesce(u.mobile, ''), '\\D', '', 'g') IN ($1, '963' || ltrim($1, '0'))
              AND u.status = 'ACTIVE' AND p.party_type = 'PERSON' LIMIT 1""", digits)
    if person is None and required:
        raise ApiError(404, "PASSENGER_NOT_FOUND", "no passenger account with this mobile")
    return person


async def agency_topup(conn, ctx: db.Context, agency_id: int, user_id: int, mobile: str, amount: int, key: str) -> dict:
    """Cash paid at an agency counter: the agency's prepaid balance pays the passenger's wallet."""
    p = await provider(conn, "AGENT")
    if p["status"] != "ACTIVE":
        raise ApiError(409, "PAYMENT_METHOD_UNAVAILABLE", "agency top-ups are not available")
    if not p["min_amount"] <= amount <= p["max_amount"]:
        raise ApiError(422, "PAYMENT_AMOUNT_OUT_OF_RANGE", "amount outside the limits", min_amount=p["min_amount"], max_amount=p["max_amount"])
    async with db.system_scope(conn, ctx):
        done = await conn.fetchrow("SELECT p.*, pv.code AS provider_code FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id "
                                   "WHERE p.idempotency_key = $1 AND p.agency_company_id = $2", key, agency_id)
        if done:
            return {**_payment_out(done), "replayed": True}
        person = await passenger_by_mobile(conn, mobile)
        currency = (await markets.of_party(conn, agency_id)).currency
        if (await markets.of_party(conn, person["id"])).currency != currency:
            raise ApiError(409, "CURRENCY_MISMATCH", "the agency and the passenger are in markets of different currencies")
        aw = await company_wallet(conn, agency_id, currency, label="Agency wallet")
        if aw["balance"] - aw["hold_balance"] < amount:
            raise ApiError(402, "INSUFFICIENT_BALANCE", "the agency balance is not enough")
        w = await user_wallet(conn, person["id"], currency)
        pay = await conn.fetchrow(
            """INSERT INTO fin.payment (provider_id, purpose, payer_party_id, wallet_id, method, currency, amount, idempotency_key, provider_ref,
                                        agency_company_id, payer_mobile_mask)
               VALUES ($1, 'TOPUP', $2, $3, 'CASH', $9, $4, $5, $6, $7, $8) RETURNING *""",
            p["id"], person["id"], w["id"], amount, key, "AGT" + secrets.token_hex(6).upper(), agency_id, mask(mobile), currency)
        pay = await _succeed(conn, p, pay, user_id, None)
    first = (person["legal_name"] or "").split(" ")[0]
    return {**_payment_out(pay), "provider": "AGENT", "receipt": pay["provider_ref"], "passenger": first}


async def partner_credit(conn, ctx: db.Context, client_id: int, provider_id: int, mobile: str, amount: int, reference: str) -> dict:
    """A bank or e-wallet partner collected the money (branch, app, ATM) and credits the passenger's wallet through the API.

    The partner's reference is its idempotency key: sending it again returns the first result, and reusing it for another
    amount or mobile is refused. The partner owes the amount to the platform through its clearing account until settled."""
    async with db.system_scope(conn, ctx):
        p = provider_dict(await conn.fetchrow("SELECT * FROM fin.payment_provider WHERE id = $1", provider_id))
        done = await conn.fetchrow("SELECT p.*, pv.code AS provider_code FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id "
                                   "WHERE p.api_client_id = $1 AND p.provider_ref = $2", client_id, reference)
        if done:
            if done["amount"] != amount or done["payer_mobile_mask"] != mask(mobile):
                raise ApiError(409, "REFERENCE_REUSED", "this reference was already used for another credit")
            return {**_payment_out(done), "reference": reference, "replayed": True}
        if p["status"] != "ACTIVE":
            raise ApiError(409, "PAYMENT_METHOD_UNAVAILABLE", "wallet credits by this partner are not available")
        if not p["min_amount"] <= amount <= p["max_amount"]:
            raise ApiError(422, "PAYMENT_AMOUNT_OUT_OF_RANGE", "amount outside the limits", min_amount=p["min_amount"], max_amount=p["max_amount"])
        person = await passenger_by_mobile(conn, mobile)
        currency = (await markets.of_party(conn, person["id"])).currency
        w = await user_wallet(conn, person["id"], currency)
        pay = await conn.fetchrow(
            """INSERT INTO fin.payment (provider_id, purpose, payer_party_id, wallet_id, method, currency, amount, idempotency_key, provider_ref,
                                        api_client_id, payer_mobile_mask)
               VALUES ($1, 'TOPUP', $2, $3, $4, $10, $5, $6, $7, $8, $9) RETURNING *""",
            p["id"], person["id"], w["id"], "E_WALLET" if p["kind"] == "E_WALLET" else "BANK", amount, f"api:{client_id}:{reference}",
            reference, client_id, mask(mobile), currency)
        pay = await _succeed(conn, p, pay, None, None)
        await emit(conn, "wallet.credited", "payment", pay["id"], {"payment": str(pay["uid"]), "reference": reference, "amount": amount,
                                                                   "currency": currency, "api_client_id": client_id})
    first = (person["legal_name"] or "").split(" ")[0]
    return {**_payment_out(pay), "provider": p["code"], "reference": reference, "passenger": first}


# ------------------------------------------------------------------ refunds to the original method
# A refund holds its amount in the payer's wallet when it is asked for, under a provider reference fixed by the refund
# row, and is posted only once the provider accepted it (review of 1.47.0, R-17). The provider is called with no
# transaction open; an unknown outcome leaves the refund UNKNOWN and the worker asks again with the same reference,
# which the provider treats as the same refund. A refusal, or a rejection under the approval matrix, releases the hold.
REFUND_RETRY_MINUTES = (1, 5, 15, 60, 240)


def _refund_out(r, extra: Optional[dict] = None) -> dict:
    return {"uid": str(r["uid"]), "status": r["status"], "stage": r["stage"], "amount": r["amount"], **(extra or {})}


async def request_refund(ctx: db.Context, user_id: int, uid: uuid.UUID, amount: int, reason: str, key: str) -> dict:
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            prior = await conn.fetchrow("SELECT * FROM fin.payment_refund WHERE idempotency_key = $1", key)
            if prior:
                return _refund_out(prior, {"replayed": True})
            pay = await conn.fetchrow("SELECT * FROM fin.payment WHERE uid = $1 FOR UPDATE", uid)
            if pay is None:
                raise not_found("payment")
            if pay["status"] != "SUCCESS" or pay["method"] not in ("CARD", "E_WALLET", "INSTALLMENT", "FINANCING"):
                raise ApiError(409, "REFUND_NOT_ALLOWED", "only successful card, e-wallet, instalment and financing payments go back to their source")
            in_flight = await conn.fetchval("SELECT coalesce(sum(amount), 0)::bigint FROM fin.payment_refund WHERE payment_id = $1 AND status = 'PENDING'",
                                            pay["id"])
            refundable = pay["amount"] - pay["refunded_amount"] - in_flight
            if amount > refundable:
                raise ApiError(422, "REFUND_TOO_LARGE", "more than what is left to refund", refundable=refundable)
            p = provider_dict(await conn.fetchrow("SELECT * FROM fin.payment_provider WHERE id = $1", pay["provider_id"]))
            if p["adapter"] not in adapters.NOTIFYING:
                raise ApiError(409, "REFUND_NOT_ALLOWED", "test payments have no source to refund to")
            # the payer's wallet: a passenger's (exact) or an agency's (shared: the balance that counts includes new entries)
            w = await counted(conn, await conn.fetchrow("SELECT * FROM fin.wallet WHERE id = $1 FOR UPDATE", pay["wallet_id"]))
            if w["balance"] - w["hold_balance"] < amount:
                raise ApiError(402, "INSUFFICIENT_BALANCE", "the wallet no longer holds this amount")
            ruid = uuid.uuid4()
            r = await conn.fetchrow(
                """INSERT INTO fin.payment_refund (uid, payment_id, amount, reason, requested_by, idempotency_key, stage, provider_reference, held)
                   VALUES ($1, $2, $3, $4, $5, $6, 'REQUESTED', $7, true) RETURNING *""",
                ruid, pay["id"], amount, reason, user_id, key, adapters.reference("RFD", ruid))
            await conn.execute("SELECT fin.adjust_hold($1, $2)", pay["wallet_id"], amount)
            request = await approvals.open_request(conn, "REFUND", r["id"], amount, pay["currency"],
                                                   f"Refund {amount} {pay['currency']} of payment {pay['provider_ref']}: {reason}", user_id)
            stage = "AWAITING_APPROVAL" if request else "SENDING"
            r = await conn.fetchrow("UPDATE fin.payment_refund SET stage = $2 WHERE id = $1 RETURNING *", r["id"], stage)
    if request:
        return _refund_out(r, {"approval": request})
    return await send_refund(ctx, r["id"], user_id)


async def send_refund(ctx: db.Context, refund_id: int, user_id: Optional[int]) -> dict:
    """Sends one refund to its provider (again, with the same reference, when the last outcome is unknown)."""
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            r = await conn.fetchrow("SELECT * FROM fin.payment_refund WHERE id = $1 FOR UPDATE", refund_id)
            if r["status"] != "PENDING" or r["stage"] not in ("SENDING", "UNKNOWN"):
                return _refund_out(r)
            wait = REFUND_RETRY_MINUTES[min(r["attempts"], len(REFUND_RETRY_MINUTES) - 1)]
            r = await conn.fetchrow("""UPDATE fin.payment_refund SET stage = 'SENDING', attempts = attempts + 1,
                                              next_attempt_at = now() + make_interval(mins => $2) WHERE id = $1 RETURNING *""",
                                    refund_id, wait)
            pay = await conn.fetchrow("SELECT * FROM fin.payment WHERE id = $1", r["payment_id"])
            p = provider_dict(await conn.fetchrow("SELECT * FROM fin.payment_provider WHERE id = $1", pay["provider_id"]))
    try:
        provider_ref = await asyncio.to_thread(adapters.ADAPTERS[p["adapter"]].refund, p, {"provider_ref": pay["provider_ref"]},
                                               r["amount"], r["provider_reference"])
        error = None
    except ApiError as exc:
        provider_ref, error = None, exc
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            r = await conn.fetchrow("SELECT * FROM fin.payment_refund WHERE id = $1 FOR UPDATE", refund_id)
            if r["status"] != "PENDING":
                return _refund_out(r)
            if isinstance(error, adapters.ProviderRefused):
                await _end_refund(conn, r, pay, "REFUSED", str(error.message))
                r = await conn.fetchrow("SELECT * FROM fin.payment_refund WHERE id = $1", refund_id)
                return _refund_out(r, {"error": "REFUND_REFUSED"})
            if error is not None:               # no answer, or the circuit is open: asked again with the same reference
                r = await conn.fetchrow("UPDATE fin.payment_refund SET stage = 'UNKNOWN', last_error = left($2, 500) WHERE id = $1 RETURNING *",
                                        refund_id, f"{error.code}: {error.message}")
                return _refund_out(r, {"retry_at": r["next_attempt_at"].isoformat()})
            await conn.execute("SELECT fin.adjust_hold($1, $2)", pay["wallet_id"], -r["amount"])
            clearing = await clearing_wallet(conn, p, pay)
            txn = await post_txn(conn, "REFUND", pay["currency"], f"payment-refund:{r['id']}",
                                 [(pay["wallet_id"], "DR", r["amount"]), (clearing["id"], "CR", r["amount"])],
                                 ref_type="payment", ref_id=pay["id"], user_id=user_id, memo=r["reason"][:120])
            r = await conn.fetchrow(
                """UPDATE fin.payment_refund SET status = 'SUCCESS', stage = 'DONE', held = false, ledger_txn_id = $2, provider_ref = $3,
                          completed_at = now(), last_error = NULL WHERE id = $1 RETURNING *""", refund_id, txn, provider_ref)
            new = await conn.fetchrow("UPDATE fin.payment SET refunded_amount = refunded_amount + $2, "
                                      "status = CASE WHEN refunded_amount + $2 = amount THEN 'REFUNDED' ELSE status END, "
                                      "stage = CASE WHEN refunded_amount + $2 = amount THEN 'REFUNDED' ELSE stage END WHERE id = $1 RETURNING *",
                                      pay["id"], r["amount"])
    return _refund_out(r, {"payment_status": new["status"], "refunded_amount": new["refunded_amount"]})


async def _end_refund(conn, r, pay, stage: str, why: str) -> None:
    """A refund that will not be paid: the provider refused it or an approver rejected it. Releases the held amount."""
    await conn.execute("SELECT fin.adjust_hold($1, $2)", pay["wallet_id"], -r["amount"])
    await conn.execute("""UPDATE fin.payment_refund SET status = 'FAILED', stage = $2, held = false, completed_at = now(),
                                 last_error = left($3, 500) WHERE id = $1""", r["id"], stage, why)


async def resend_refunds(limit: int = 20) -> int:
    """Worker: refunds whose last outcome is unknown (or whose sender stopped) are asked again, same reference."""
    ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
    async with db.transaction(ctx) as conn:
        due = [r["id"] for r in await conn.fetch(
            "SELECT id FROM fin.payment_refund WHERE stage IN ('SENDING', 'UNKNOWN') AND next_attempt_at <= now() ORDER BY next_attempt_at LIMIT $1",
            limit)]
    for rid in due:
        await send_refund(ctx, rid, None)
    return len(due)


# ------------------------------------------------------------------ the approval matrix: what a decision does
async def decide_approval(ctx: db.Context, user_id: int, uid: uuid.UUID, approve: bool, note: Optional[str]) -> dict:
    """One level's decision. The last approval carries the decision out (a statement credit in the same transaction, a
    refund sent to its provider after it); a rejection undoes what waited for it."""
    send = None
    async with db.transaction(ctx) as conn:
        rq = await approvals.decide(conn, user_id, uid, approve, note)
        async with db.system_scope(conn, ctx):
            send = await _carry_out(conn, rq, user_id, note or "")
    if send:
        return {"status": rq["status"], "refund": await send_refund(ctx, send, user_id)}
    return {"status": rq["status"]}


async def cancel_approval(ctx: db.Context, user_id: int, uid: uuid.UUID, note: str) -> dict:
    async with db.transaction(ctx) as conn:
        rq = await approvals.cancel(conn, uid)
        async with db.system_scope(conn, ctx):
            await _carry_out(conn, rq, user_id, f"cancelled: {note}")
    return {"status": rq["status"]}


async def _carry_out(conn, rq, user_id: int, note: str) -> Optional[int]:
    """Returns the id of a refund to send once the transaction is committed."""
    if rq["status"] == "PENDING":
        return None
    if rq["action"] == "BANK_CREDIT":
        if rq["status"] == "APPROVED":
            await credit_line(conn, rq["object_id"], user_id)
        else:
            await unpropose_line(conn, rq["object_id"], f"APPROVAL_{rq['status']}: {note}")
        return None
    r = await conn.fetchrow("SELECT * FROM fin.payment_refund WHERE id = $1 FOR UPDATE", rq["object_id"])
    if r["status"] != "PENDING":
        return None
    if rq["status"] == "APPROVED":
        await conn.execute("UPDATE fin.payment_refund SET stage = 'SENDING' WHERE id = $1", r["id"])
        return r["id"]
    pay = await conn.fetchrow("SELECT * FROM fin.payment WHERE id = $1", r["payment_id"])
    await _end_refund(conn, r, pay, "REJECTED", note or rq["status"].lower())
    return None

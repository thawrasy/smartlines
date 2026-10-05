"""Payments: money entering wallets from cards, partner e-wallets, bank transfers and agency counters, and refunds.

Rules every flow follows:
  - a payment is credited exactly once: only a PENDING payment can become SUCCESS, under a row lock, and a provider
    event is recorded once (unique provider + event id);
  - the amount and currency a provider reports must equal the payment's, otherwise nothing is credited;
  - every credit is one balanced ledger transaction (clearing account debited, wallet credited) with an idempotency key;
  - what the browser says never counts: cards and e-wallets are credited from the provider's signed notification or
    the provider's own answer to the confirmation call, bank transfers from the bank statement.
"""
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

from ... import db
from ...errors import ApiError, not_found
from ...ledger import company_wallet, platform_wallet, post_txn, user_wallet
from . import adapters

OTP_MAX_ATTEMPTS = 5
PENDING_MINUTES = {"HOSTED_CARD": 30, "PARTNER_WALLET": 10}


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


def fee_of(p: dict, amount: int) -> int:
    pct = Decimal(str(p["fee_policy"].get("pct", 0)))
    return int((Decimal(amount) * pct / 100).quantize(Decimal("1")))


async def methods(conn, purpose: str = "TOPUP") -> list[dict]:
    rows = await conn.fetch(
        """SELECT code, name, kind, adapter, min_amount, max_amount, fee_policy, config FROM fin.payment_provider
            WHERE status = 'ACTIVE' AND $1 = ANY(purposes) ORDER BY sort_order""", purpose)
    out = []
    for r in rows:
        p = provider_dict(r)
        if p["adapter"] == "SANDBOX" and not adapters.get_settings().sandbox:
            continue
        out.append({"code": p["code"], "name": p["name"], "kind": p["kind"], "adapter": p["adapter"], "min_amount": p["min_amount"],
                    "max_amount": p["max_amount"], "fee_pct": float(p["fee_policy"].get("pct", 0)),
                    "fee_borne_by": p["fee_policy"].get("borne_by", "PLATFORM")})
    return out


def _payment_out(row) -> dict:
    return {"uid": str(row["uid"]), "status": row["status"], "stage": row["stage"], "amount": row["amount"], "currency": row["currency"],
            "method": row["method"], "provider": row["provider_code"] if "provider_code" in row.keys() else None,
            "checkout_url": row["checkout_url"], "expires_at": row["expires_at"].isoformat() if row["expires_at"] else None,
            "failure_code": row["failure_code"], "created_at": row["created_at"].isoformat()}


# ------------------------------------------------------------------ cards and partner e-wallets
async def start_topup(conn, ctx: db.Context, party_id: int, user_id: int, code: str, amount: int, key: str,
                      mobile: Optional[str], return_url: str) -> dict:
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
    existing = await conn.fetchrow("SELECT p.*, pv.code AS provider_code FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id "
                                   "WHERE p.idempotency_key = $1 AND p.payer_party_id = $2", key, party_id)
    if existing:
        return {**_payment_out(existing), "replayed": True}
    w = await user_wallet(conn, party_id, "SYP")
    method = {"HOSTED_CARD": "CARD", "PARTNER_WALLET": "E_WALLET"}.get(p["adapter"], "CARD")
    async with db.system_scope(conn, ctx):
        pay = await conn.fetchrow(
            """INSERT INTO fin.payment (provider_id, purpose, payer_party_id, wallet_id, method, currency, amount, fee, idempotency_key,
                                        payer_mobile_mask, expires_at)
               VALUES ($1, 'TOPUP', $2, $3, $4, 'SYP', $5, $6, $7, $8, now() + make_interval(mins => $9)) RETURNING *""",
            p["id"], party_id, w["id"], method, amount, fee_of(p, amount), key, mask(mobile) if mobile else None,
            PENDING_MINUTES.get(p["adapter"], 30))
        adapter = adapters.ADAPTERS[p["adapter"]]
        payload = {"uid": str(pay["uid"]), "amount": amount, "currency": "SYP"}
        return_url = return_url.replace("{uid}", str(pay["uid"]))
        action = adapter.start(p, payload, return_url, mobile) if p["adapter"] == "PARTNER_WALLET" else adapter.start(p, payload, return_url)
        stage = {"REDIRECT": "REDIRECTED", "OTP": "OTP_SENT", "DONE": "CONFIRMED"}[action.kind]
        pay = await conn.fetchrow("UPDATE fin.payment SET provider_ref = $2, checkout_url = $3, stage = $4 WHERE id = $1 RETURNING *",
                                  pay["id"], action.provider_ref, action.url, "REDIRECTED" if stage == "CONFIRMED" else stage)
        if action.kind == "DONE":                     # the sandbox gateway answers at once
            pay = await _succeed(conn, p, pay, user_id, card_last4=None)
    out = {**_payment_out(pay), "provider": p["code"], "action": action.kind, "url": action.url}
    if action.details.get("test_code"):
        out["test_code"] = action.details["test_code"]     # sandbox only: lets testers finish the flow
    return out


async def clearing_wallet(conn, p: dict, pay) -> asyncpg.Record:
    """The account the money comes from: the agency's prepaid balance, the bank account, or the gateway clearing account."""
    if p["adapter"] == "CASH_AGENT":
        return await company_wallet(conn, pay["agency_company_id"], pay["currency"], label="Agency wallet")
    if p["adapter"] == "BANK_TRANSFER":
        return await platform_wallet(conn, "BANK_CLEARING", pay["currency"])
    if p.get("clearing_wallet_id"):
        return await conn.fetchrow("SELECT * FROM fin.wallet WHERE id = $1", p["clearing_wallet_id"])
    return await platform_wallet(conn, "GATEWAY_CLEARING", pay["currency"])


async def _succeed(conn, p: dict, pay, user_id: Optional[int], card_last4: Optional[str]):
    """Credits the wallet for a pending payment, once. The caller holds the system scope."""
    row = await conn.fetchrow("SELECT * FROM fin.payment WHERE id = $1 FOR UPDATE", pay["id"])
    if row["status"] != "PENDING":
        return row
    clearing = await clearing_wallet(conn, p, row)
    txn = await post_txn(conn, "TOPUP", row["currency"], f"payment:{row['id']}",
                         [(clearing["id"], "DR", row["amount"]), (row["wallet_id"], "CR", row["amount"])],
                         ref_type="payment", ref_id=row["id"], user_id=user_id, memo=row["provider_ref"])
    return await conn.fetchrow(
        """UPDATE fin.payment SET status = 'SUCCESS', stage = 'CONFIRMED', ledger_txn_id = $2, settled_at = now(),
                  card_last4 = coalesce($3, card_last4) WHERE id = $1 RETURNING *""", row["id"], txn, card_last4)


async def _fail(conn, pay, code: str) -> asyncpg.Record:
    return await conn.fetchrow("UPDATE fin.payment SET status = 'FAILED', stage = 'FAILED', failure_code = $2 WHERE id = $1 AND status = 'PENDING' "
                               "RETURNING *", pay["id"], code) or pay


async def record_rejected(conn, ctx: db.Context, p: dict, raw: bytes, ip: str) -> None:
    """A notification that could not even be read is still kept, for the security review."""
    async with db.system_scope(conn, ctx):
        await conn.execute(
            """INSERT INTO fin.payment_notification (provider_id, event_id, signature_valid, source_ip, payload)
               VALUES ($1, $2, false, $3::inet, $4::jsonb) ON CONFLICT (provider_id, event_id) DO NOTHING""",
            p["id"], "unreadable-" + hashlib.sha256(raw).hexdigest()[:32], ip, json.dumps({"raw": raw[:2000].decode("utf-8", "replace")}))


async def apply_notice(conn, ctx: db.Context, p: dict, notice: adapters.Notice, raw: dict, signature_valid: bool, ip: str) -> dict:
    """Records a provider notification and, when it is valid and new, settles the payment it names."""
    async with db.system_scope(conn, ctx):
        pay = await conn.fetchrow("SELECT * FROM fin.payment WHERE provider_id = $1 AND provider_ref = $2", p["id"], notice.provider_ref)
        # notifications are append-only: a valid one is processed in this same transaction, so it is stamped on insert
        nid = await conn.fetchval(
            """INSERT INTO fin.payment_notification (provider_id, event_id, payment_id, signature_valid, source_ip, payload, processed_at)
               VALUES ($1, $2, $3, $4, $5::inet, $6::jsonb, CASE WHEN $4 AND $3::bigint IS NOT NULL THEN now() END)
               ON CONFLICT (provider_id, event_id) DO NOTHING RETURNING id""",
            p["id"], notice.event_id, pay["id"] if pay else None, signature_valid, ip, json.dumps(raw))
        if not signature_valid:
            return {"ok": False, "error": "BAD_SIGNATURE"}          # recorded; the caller refuses after the commit
        if nid is None:
            return {"ok": True, "replayed": True}
        if pay is None:
            raise not_found("payment")
        if notice.amount != pay["amount"] or notice.currency != pay["currency"]:
            await _fail(conn, pay, "AMOUNT_MISMATCH")
            return {"ok": False, "error": "AMOUNT_MISMATCH"}
        if notice.status == "SUCCESS":
            pay = await _succeed(conn, p, pay, None, notice.card_last4)
        else:
            pay = await _fail(conn, pay, notice.failure_code or "DECLINED")
    return {"ok": True, "status": pay["status"]}


async def confirm_code(conn, ctx: db.Context, party_id: int, user_id: int, uid: uuid.UUID, code: str) -> dict:
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
        await conn.execute("UPDATE fin.payment SET otp_attempts = otp_attempts + 1 WHERE id = $1", pay["id"])
        p = provider_dict(await conn.fetchrow("SELECT * FROM fin.payment_provider WHERE id = $1", pay["provider_id"]))
        notice = adapters.ADAPTERS[p["adapter"]].confirm(p, {"uid": str(uid), "amount": pay["amount"], "currency": pay["currency"],
                                                            "provider_ref": pay["provider_ref"]}, code)
        if notice is None:
            return {"status": "PENDING", "stage": "OTP_SENT"}
        if notice.status != "SUCCESS" and notice.failure_code == "OTP_INVALID":
            left = OTP_MAX_ATTEMPTS - pay["otp_attempts"] - 1
            if left <= 0:
                await _fail(conn, pay, "OTP_TOO_MANY_ATTEMPTS")
            return {"error": "OTP_INVALID", "attempts_left": max(0, left)}    # the counter is kept: raised after the commit
        await conn.execute(
            """INSERT INTO fin.payment_notification (provider_id, event_id, payment_id, signature_valid, source_ip, payload, processed_at)
               VALUES ($1, $2, $3, true, $4::inet, $5::jsonb, now()) ON CONFLICT (provider_id, event_id) DO NOTHING""",
            p["id"], notice.event_id, pay["id"], ctx.ip, json.dumps({"confirm": notice.status, "reference": notice.provider_ref}))
        if notice.amount != pay["amount"]:
            await _fail(conn, pay, "AMOUNT_MISMATCH")
            return {"error": "AMOUNT_MISMATCH"}
        pay = await (_succeed(conn, p, pay, user_id, None) if notice.status == "SUCCESS" else _fail(conn, pay, notice.failure_code or "DECLINED"))
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
    rows = await conn.fetch("UPDATE fin.payment SET status = 'FAILED', stage = 'EXPIRED', failure_code = 'EXPIRED' "
                            "WHERE status = 'PENDING' AND expires_at < now() RETURNING id")
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
            w = await user_wallet(conn, party_id, "SYP")
            for _ in range(5):
                ref = make_reference()
                if not await conn.fetchval("SELECT 1 FROM fin.bank_transfer_topup WHERE virtual_ref = $1", ref):
                    break
            pay_id = await conn.fetchval(
                """INSERT INTO fin.payment (provider_id, purpose, payer_party_id, wallet_id, method, currency, amount, idempotency_key, provider_ref,
                                            stage, expires_at)
                   VALUES ($1, 'TOPUP', $2, $3, 'BANK', 'SYP', $4, $5, $6, 'AWAITING_TRANSFER', now() + make_interval(days => $7)) RETURNING id""",
                p["id"], party_id, w["id"], amount, key, ref, days)
            await conn.execute(
                """INSERT INTO fin.bank_transfer_topup (wallet_id, virtual_ref, amount, status, payment_id, expires_at)
                   VALUES ($1, $2, $3, 'AWAITING', $4, now() + make_interval(days => $5))""", w["id"], ref, amount, pay_id, days)
        else:
            pay_id = existing["id"]
        row = await conn.fetchrow("SELECT p.*, t.virtual_ref FROM fin.payment p JOIN fin.bank_transfer_topup t ON t.payment_id = p.id WHERE p.id = $1",
                                  pay_id)
    return {**_payment_out(row), "provider": "BANK", "action": "TRANSFER", "reference": row["virtual_ref"],
            "bank": {"bank_name": cfg.get("bank_name", ""), "account_name": cfg.get("account_name", ""), "iban": cfg.get("iban", "")}}


def _minor(text: str) -> int:
    s = (text or "").replace(",", "").replace(" ", "").strip()
    try:
        v = Decimal(s)
    except InvalidOperation as e:
        raise ApiError(422, "STATEMENT_BAD_AMOUNT", f"bad amount {text!r}") from e
    return int((v * 100).quantize(Decimal("1")))


FIELDS = {"value_date": ("value_date", "date", "booking_date"), "amount": ("amount", "credit"),
          "currency": ("currency",), "reference": ("reference", "description", "details", "narrative"),
          "payer": ("payer", "name", "sender", "remitter"), "bank_ref": ("bank_ref", "transaction_id", "transaction", "ref", "id")}


def parse_statement(data: bytes) -> list[dict]:
    """A CSV export of the bank account: one header row, then one line per transaction; debits are skipped."""
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
        amount = _minor(get("amount"))
        if amount <= 0:
            continue
        try:
            d = date.fromisoformat(get("value_date")[:10])
        except ValueError as e:
            raise ApiError(422, "STATEMENT_BAD_DATE", f"bad date {get('value_date')!r}") from e
        out.append({"value_date": d, "amount": amount, "currency": (get("currency") or "SYP").upper()[:3], "reference": get("reference")[:300],
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


async def import_statement(conn, ctx: db.Context, user_id: int, account_label: str, data: bytes) -> dict:
    lines = parse_statement(data)
    digest = hashlib.sha256(data).digest()
    async with db.system_scope(conn, ctx):
        if await conn.fetchval("SELECT 1 FROM fin.bank_statement_import WHERE account_label = $1 AND file_sha256 = $2", account_label, digest):
            raise ApiError(409, "STATEMENT_ALREADY_IMPORTED", "this file was already imported")
        imp = await conn.fetchrow("INSERT INTO fin.bank_statement_import (account_label, file_sha256, line_count, imported_by) "
                                  "VALUES ($1, $2, $3, $4) RETURNING id, uid", account_label, digest, len(lines), user_id)
        matched = 0
        for ln in lines:
            if await conn.fetchval("SELECT 1 FROM fin.bank_statement_line WHERE bank_ref = $1 AND status = 'MATCHED'", ln["bank_ref"]):
                continue                                       # the same bank transaction in an overlapping statement
            ref = find_reference(ln["reference"])
            topup = await conn.fetchrow("SELECT * FROM fin.bank_transfer_topup WHERE virtual_ref = $1 FOR UPDATE", ref) if ref else None
            note = None
            if ref is None:
                note = "NO_REFERENCE"
            elif topup is None:
                note = "UNKNOWN_REFERENCE"
            elif topup["status"] != "AWAITING":
                note = "TOPUP_NOT_AWAITING"
            elif topup["amount"] != ln["amount"] or ln["currency"] != "SYP":
                note = "AMOUNT_DIFFERS"
            line_id = await conn.fetchval(
                """INSERT INTO fin.bank_statement_line (import_id, value_date, amount, currency, reference, payer, bank_ref, note)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (import_id, bank_ref) DO NOTHING RETURNING id""",
                imp["id"], ln["value_date"], ln["amount"], ln["currency"], ln["reference"], ln["payer"], ln["bank_ref"], note)
            if line_id and note is None:
                await _credit_transfer(conn, line_id, topup, user_id)
                matched += 1
        await conn.execute("UPDATE fin.bank_statement_import SET matched_count = $2 WHERE id = $1", imp["id"], matched)
    return {"uid": str(imp["uid"]), "lines": len(lines), "matched": matched, "unmatched": len(lines) - matched}


async def match_line(conn, ctx: db.Context, user_id: int, line_id: int, reference: str, credit_received: bool) -> dict:
    """Finance matches an unmatched line by hand. A different amount is only accepted when finance confirms crediting
    what actually arrived, and the top-up is corrected to that amount before it is credited."""
    async with db.system_scope(conn, ctx):
        ln = await conn.fetchrow("SELECT * FROM fin.bank_statement_line WHERE id = $1 FOR UPDATE", line_id)
        if ln is None:
            raise not_found("statement line")
        if ln["status"] != "UNMATCHED":
            raise ApiError(409, "LINE_ALREADY_DECIDED", "this line was already decided")
        ref = find_reference(reference) or reference.strip().upper()
        topup = await conn.fetchrow("SELECT * FROM fin.bank_transfer_topup WHERE virtual_ref = $1 FOR UPDATE", ref)
        if topup is None or topup["status"] != "AWAITING":
            raise ApiError(409, "TOPUP_NOT_AWAITING", "no open transfer with this reference")
        if topup["amount"] != ln["amount"]:
            if not credit_received:
                raise ApiError(409, "AMOUNT_DIFFERS", "amounts differ", expected=topup["amount"], received=ln["amount"])
            await conn.execute("UPDATE fin.bank_transfer_topup SET amount = $2 WHERE id = $1", topup["id"], ln["amount"])
            await conn.execute("UPDATE fin.payment SET amount = $2 WHERE id = $1 AND status = 'PENDING'", topup["payment_id"], ln["amount"])
            topup = await conn.fetchrow("SELECT * FROM fin.bank_transfer_topup WHERE id = $1", topup["id"])
        if topup["expires_at"] and topup["expires_at"] < datetime.now(timezone.utc):
            await conn.execute("UPDATE fin.payment SET expires_at = now() + interval '1 hour' WHERE id = $1", topup["payment_id"])
        await conn.execute("UPDATE fin.bank_statement_line SET note = $2 WHERE id = $1", line_id,
                           "MATCHED_BY_HAND" if topup["amount"] == ln["amount"] else "AMOUNT_CORRECTED")
        await _credit_transfer(conn, line_id, topup, user_id)
    return {"ok": True}


async def ignore_line(conn, ctx: db.Context, user_id: int, line_id: int, note: str) -> dict:
    async with db.system_scope(conn, ctx):
        done = await conn.fetchval("UPDATE fin.bank_statement_line SET status = 'IGNORED', note = $3, decided_by = $2, decided_at = now() "
                                   "WHERE id = $1 AND status = 'UNMATCHED' RETURNING id", line_id, user_id, note)
    if not done:
        raise ApiError(409, "LINE_ALREADY_DECIDED", "this line was already decided")
    return {"ok": True}


# ------------------------------------------------------------------ agency counters
async def agency_topup(conn, ctx: db.Context, agency_id: int, user_id: int, mobile: str, amount: int, key: str) -> dict:
    """Cash paid at an agency counter: the agency's prepaid balance pays the passenger's wallet."""
    p = await provider(conn, "AGENT")
    if p["status"] != "ACTIVE":
        raise ApiError(409, "PAYMENT_METHOD_UNAVAILABLE", "agency top-ups are not available")
    if not p["min_amount"] <= amount <= p["max_amount"]:
        raise ApiError(422, "PAYMENT_AMOUNT_OUT_OF_RANGE", "amount outside the limits", min_amount=p["min_amount"], max_amount=p["max_amount"])
    digits = re.sub(r"\D", "", mobile)
    async with db.system_scope(conn, ctx):
        done = await conn.fetchrow("SELECT p.*, pv.code AS provider_code FROM fin.payment p JOIN fin.payment_provider pv ON pv.id = p.provider_id "
                                   "WHERE p.idempotency_key = $1 AND p.agency_company_id = $2", key, agency_id)
        if done:
            return {**_payment_out(done), "replayed": True}
        person = await conn.fetchrow(
            """SELECT p.id, p.legal_name FROM iam.party p JOIN iam.app_user u ON u.party_id = p.id
                WHERE regexp_replace(coalesce(p.mobile, u.mobile, ''), '\\D', '', 'g') IN ($1, '963' || ltrim($1, '0'))
                  AND u.status = 'ACTIVE' AND p.party_type = 'PERSON' LIMIT 1""", digits)
        if person is None:
            raise ApiError(404, "PASSENGER_NOT_FOUND", "no passenger account with this mobile")
        aw = await company_wallet(conn, agency_id, "SYP", label="Agency wallet")
        if aw["balance"] - aw["hold_balance"] < amount:
            raise ApiError(402, "INSUFFICIENT_BALANCE", "the agency balance is not enough")
        w = await user_wallet(conn, person["id"], "SYP")
        pay = await conn.fetchrow(
            """INSERT INTO fin.payment (provider_id, purpose, payer_party_id, wallet_id, method, currency, amount, idempotency_key, provider_ref,
                                        agency_company_id, payer_mobile_mask)
               VALUES ($1, 'TOPUP', $2, $3, 'CASH', 'SYP', $4, $5, $6, $7, $8) RETURNING *""",
            p["id"], person["id"], w["id"], amount, key, "AGT" + secrets.token_hex(6).upper(), agency_id, mask(mobile))
        pay = await _succeed(conn, p, pay, user_id, None)
    first = (person["legal_name"] or "").split(" ")[0]
    return {**_payment_out(pay), "provider": "AGENT", "receipt": pay["provider_ref"], "passenger": first}


# ------------------------------------------------------------------ refunds to the original method
async def refund(conn, ctx: db.Context, user_id: int, uid: uuid.UUID, amount: int, reason: str, key: str) -> dict:
    async with db.system_scope(conn, ctx):
        prior = await conn.fetchrow("SELECT * FROM fin.payment_refund WHERE idempotency_key = $1", key)
        if prior:
            return {"uid": str(prior["uid"]), "status": prior["status"], "replayed": True}
        pay = await conn.fetchrow("SELECT * FROM fin.payment WHERE uid = $1 FOR UPDATE", uid)
        if pay is None:
            raise not_found("payment")
        if pay["status"] != "SUCCESS" or pay["method"] not in ("CARD", "E_WALLET"):
            raise ApiError(409, "REFUND_NOT_ALLOWED", "only successful card and e-wallet payments go back to their source")
        if amount > pay["amount"] - pay["refunded_amount"]:
            raise ApiError(422, "REFUND_TOO_LARGE", "more than what is left to refund", refundable=pay["amount"] - pay["refunded_amount"])
        w = await conn.fetchrow("SELECT * FROM fin.wallet WHERE id = $1 FOR UPDATE", pay["wallet_id"])
        if w["balance"] - w["hold_balance"] < amount:
            raise ApiError(402, "INSUFFICIENT_BALANCE", "the wallet no longer holds this amount")
        p = provider_dict(await conn.fetchrow("SELECT * FROM fin.payment_provider WHERE id = $1", pay["provider_id"]))
        rid = await conn.fetchval("INSERT INTO fin.payment_refund (payment_id, amount, reason, requested_by, idempotency_key) "
                                  "VALUES ($1, $2, $3, $4, $5) RETURNING id", pay["id"], amount, reason, user_id, key)
        provider_ref = adapters.ADAPTERS[p["adapter"]].refund(p, {"provider_ref": pay["provider_ref"]}, amount, f"refund:{rid}")
        clearing = await clearing_wallet(conn, p, pay)
        txn = await post_txn(conn, "REFUND", pay["currency"], f"payment-refund:{rid}",
                             [(pay["wallet_id"], "DR", amount), (clearing["id"], "CR", amount)],
                             ref_type="payment", ref_id=pay["id"], user_id=user_id, memo=reason[:120])
        await conn.execute("UPDATE fin.payment_refund SET status = 'SUCCESS', ledger_txn_id = $2, provider_ref = $3, completed_at = now() "
                           "WHERE id = $1", rid, txn, provider_ref)
        new = await conn.fetchrow("UPDATE fin.payment SET refunded_amount = refunded_amount + $2, "
                                  "status = CASE WHEN refunded_amount + $2 = amount THEN 'REFUNDED' ELSE status END, "
                                  "stage = CASE WHEN refunded_amount + $2 = amount THEN 'REFUNDED' ELSE stage END WHERE id = $1 RETURNING *",
                                  pay["id"], amount)
    return {"status": "SUCCESS", "payment_status": new["status"], "refunded_amount": new["refunded_amount"]}

"""Payment integration: card gateway, partner e-wallets, bank transfers, agency counters and refunds.

What must never happen: a wallet credited twice for one payment, credited from what the browser says, credited with an
amount other than the one paid, credited from a notification with a wrong signature, or a code guessed without limit.
"""
import hashlib
import hmac
import json
import os
import secrets
import time

import pytest

from test_e2e import OWNER_URL, client, login, new_passenger, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
IBAN = "SY21 0010 0000 0000 0012 3456 789"


def key() -> str:
    return secrets.token_hex(12)


def balance(c) -> int:
    return c.get("/api/wallet").json()["balance"]


def psp_secret(code: str) -> bytes:
    """The sandbox derives each provider's signing key from the platform secret (see adapters.secret_for)."""
    return hmac.new(os.environ["MASSLAK_SIGNING_SECRET"].encode(), f"psp:{code}".encode(), hashlib.sha256).digest()


def signed(code: str, body: dict, secret: bytes = None) -> tuple[bytes, dict]:
    raw = json.dumps(body).encode()
    ts = int(time.time())
    mac = hmac.new(secret or psp_secret(code), f"{ts}.".encode() + raw, hashlib.sha256).hexdigest()
    return raw, {"X-Masslak-Signature": f"t={ts},v1={mac}", "Content-Type": "application/json", "X-Masslak-Client": "web"}


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module", autouse=True)
def providers_on(admin):
    """Switch the card, e-wallet and bank methods on (no provider address: the sandbox simulator answers)."""
    base = {"min_amount": 100000, "max_amount": 100000000, "fee_pct": 1.0, "fee_borne_by": "PLATFORM"}
    for code, cfg in (("CARD", {}), ("EWALLET", {}), ("BANK", {"bank_name": "Commercial Bank of Syria", "iban": IBAN, "valid_days": 3})):
        r = admin.put(f"/api/admin/payments/providers/{code}", json={**base, "status": "ACTIVE", "config": cfg})
        assert r.status_code == 200, r.text
    yield


@pytest.fixture()
def pax():
    return new_passenger()


def test_methods_and_provider_admin(admin, pax):
    codes = {m["code"] for m in pax.get("/api/payments/methods").json()["methods"]}
    assert {"CARD", "EWALLET", "BANK", "AGENT"} <= codes
    listed = {p["code"]: p for p in admin.get("/api/admin/payments/providers").json()["providers"]}
    assert listed["CARD"]["simulated"] is True and "secret_env" not in listed["CARD"]["config"]
    # secrets and unknown settings cannot be written through the API, and a provider address must be https
    r = admin.put("/api/admin/payments/providers/CARD", json={"status": "ACTIVE", "min_amount": 100000, "max_amount": 100000000,
                                                             "fee_pct": 1, "config": {"secret_env": "X"}})
    assert r.status_code == 422
    r = admin.put("/api/admin/payments/providers/CARD", json={"status": "ACTIVE", "min_amount": 100000, "max_amount": 100000000,
                                                             "fee_pct": 1, "config": {"base_url": "http://psp.example"}})
    assert r.status_code == 422
    # a passenger cannot manage providers
    assert pax.get("/api/admin/payments/providers").status_code == 403


def test_card_topup_credited_once_from_the_signed_notification(pax):
    before = balance(pax)
    r = pax.post("/api/payments/topups", json={"method": "CARD", "amount": 2500000, "idempotency_key": (k := key())})
    assert r.status_code == 201, r.text
    p = r.json()
    assert p["action"] == "REDIRECT" and p["url"] == f"/pay/test/{p['uid']}" and p["status"] == "PENDING"
    # the same request replayed returns the same payment
    assert pax.post("/api/payments/topups", json={"method": "CARD", "amount": 2500000, "idempotency_key": k}).json()["uid"] == p["uid"]
    assert balance(pax) == before, "nothing is credited before the gateway confirms"
    page = pax.get(f"/api/payments/test/{p['uid']}").json()
    assert page["amount"] == 2500000
    done = pax.post(f"/api/payments/test/{p['uid']}", json={"approve": True})
    assert done.status_code == 200 and done.json()["status"] == "SUCCESS", done.text
    assert balance(pax) == before + 2500000
    assert pax.get(f"/api/payments/{p['uid']}").json()["status"] == "SUCCESS"
    # the gateway retrying the same event changes nothing
    ref = owner_sql("SELECT provider_ref FROM fin.payment WHERE uid = $1::uuid", p["uid"])
    raw, headers = signed("CARD", {"event_id": f"sim-{ref}", "reference": ref, "status": "SUCCESS", "amount": 2500000, "currency": "SYP"})
    r = pax.post("/api/payments/notify/CARD", content=raw, headers=headers)
    assert r.status_code == 200 and r.json().get("replayed")
    # a new event for an already settled payment changes nothing either
    raw, headers = signed("CARD", {"event_id": f"evt-{key()}", "reference": ref, "status": "SUCCESS", "amount": 2500000, "currency": "SYP"})
    assert pax.post("/api/payments/notify/CARD", content=raw, headers=headers).status_code == 200
    assert balance(pax) == before + 2500000
    entries = owner_sql("""SELECT count(*) FROM fin.ledger_entry e JOIN fin.payment p ON p.ledger_txn_id = e.txn_id WHERE p.uid = $1::uuid""",
                        p["uid"])
    assert entries == 2


def test_forged_and_tampered_notifications_are_refused(pax):
    before = balance(pax)
    p = pax.post("/api/payments/topups", json={"method": "CARD", "amount": 1000000, "idempotency_key": key()}).json()
    ref = owner_sql("SELECT provider_ref FROM fin.payment WHERE uid = $1::uuid", p["uid"])
    # signed with another key: refused, but recorded for the security review
    raw, headers = signed("CARD", {"event_id": f"forged-{ref}", "reference": ref, "status": "SUCCESS", "amount": 1000000, "currency": "SYP"},
                          secret=b"not-the-key")
    assert pax.post("/api/payments/notify/CARD", content=raw, headers=headers).status_code == 401
    assert owner_sql("SELECT signature_valid FROM fin.payment_notification WHERE event_id = $1", f"forged-{ref}") is False
    # an old timestamp is refused even with the right key
    old = json.dumps({"event_id": f"old-{ref}", "reference": ref, "status": "SUCCESS", "amount": 1000000, "currency": "SYP"}).encode()
    ts = int(time.time()) - 3600
    mac = hmac.new(psp_secret("CARD"), f"{ts}.".encode() + old, hashlib.sha256).hexdigest()
    r = pax.post("/api/payments/notify/CARD", content=old, headers={"X-Masslak-Signature": f"t={ts},v1={mac}", "Content-Type": "application/json"})
    assert r.status_code == 401
    # correctly signed but for another amount: the payment fails, nothing is credited
    raw, headers = signed("CARD", {"event_id": f"tamper-{ref}", "reference": ref, "status": "SUCCESS", "amount": 100, "currency": "SYP"})
    r = pax.post("/api/payments/notify/CARD", content=raw, headers=headers)
    assert r.status_code == 200 and r.json()["error"] == "AMOUNT_MISMATCH"
    assert pax.get(f"/api/payments/{p['uid']}").json()["failure_code"] == "AMOUNT_MISMATCH"
    assert balance(pax) == before
    # garbage is refused
    assert pax.post("/api/payments/notify/CARD", content=b"not json", headers={"Content-Type": "application/json"}).status_code in (400, 401)


def test_an_unsigned_copy_cannot_take_the_event_id_first(pax):
    """R-18: someone who guesses the provider's next event id posts it first with a bad signature; the provider's real
    notice with that id still settles the payment, and both are kept for the security review."""
    before = balance(pax)
    p = pax.post("/api/payments/topups", json={"method": "CARD", "amount": 1200000, "idempotency_key": key()}).json()
    ref = owner_sql("SELECT provider_ref FROM fin.payment WHERE uid = $1::uuid", p["uid"])
    event = {"event_id": f"evt-{ref}", "reference": ref, "status": "SUCCESS", "amount": 1200000, "currency": "SYP"}
    for _ in range(2):                                 # repeated forgeries are kept too
        raw, headers = signed("CARD", event, secret=b"guessed")
        assert pax.post("/api/payments/notify/CARD", content=raw, headers=headers).status_code == 401
    raw, headers = signed("CARD", event)
    r = pax.post("/api/payments/notify/CARD", content=raw, headers=headers)
    assert r.status_code == 200 and r.json().get("status") == "SUCCESS", r.text
    assert balance(pax) == before + 1200000
    kept = owner_sql("SELECT array_agg(signature_valid ORDER BY id) FROM fin.payment_notification WHERE event_id = $1",
                     f"evt-{ref}")
    assert kept == [False, False, True]
    raw, headers = signed("CARD", event)               # the real one again is a replay
    assert pax.post("/api/payments/notify/CARD", content=raw, headers=headers).json().get("replayed")
    assert balance(pax) == before + 1200000


def test_ewallet_code_attempts_are_limited_and_kept(pax):
    before = balance(pax)
    assert pax.post("/api/payments/topups", json={"method": "EWALLET", "amount": 500000, "idempotency_key": key()}).status_code == 422
    p = pax.post("/api/payments/topups", json={"method": "EWALLET", "amount": 500000, "idempotency_key": key(),
                                               "mobile": "+963944000111"}).json()
    assert p["action"] == "OTP" and p["stage"] == "OTP_SENT"
    r = pax.post(f"/api/payments/{p['uid']}/code", json={"code": "000000"})
    assert r.status_code == 422 and r.json()["error"]["attempts_left"] == 4
    r = pax.post(f"/api/payments/{p['uid']}/code", json={"code": "111111"})
    assert r.json()["error"]["attempts_left"] == 3, "wrong attempts are counted across requests"
    ok = pax.post(f"/api/payments/{p['uid']}/code", json={"code": p["test_code"]})
    assert ok.status_code == 200 and ok.json()["status"] == "SUCCESS"
    assert balance(pax) == before + 500000
    # another payment: five wrong codes close it
    q = pax.post("/api/payments/topups", json={"method": "EWALLET", "amount": 500000, "idempotency_key": key(), "mobile": "+963944000111"}).json()
    for _ in range(5):
        pax.post(f"/api/payments/{q['uid']}/code", json={"code": "999999"})
    assert pax.post(f"/api/payments/{q['uid']}/code", json={"code": q["test_code"]}).status_code in (409, 429)
    assert balance(pax) == before + 500000
    # another passenger cannot see or confirm it
    other = new_passenger()
    assert other.get(f"/api/payments/{q['uid']}").status_code == 404


def test_bank_transfer_matched_from_the_statement(admin, pax):
    before = balance(pax)
    t = pax.post("/api/payments/bank-transfers", json={"amount": 3000000, "idempotency_key": key()}).json()
    ref = t["reference"]
    assert ref.startswith("MSL") and int(ref[3:]) % 97 == 1 and t["bank"]["iban"] == IBAN
    u = pax.post("/api/payments/bank-transfers", json={"amount": 2000000, "idempotency_key": key()}).json()
    bank_ref = f"TRX{secrets.token_hex(5)}"
    csv = ("date,amount,currency,description,payer,transaction_id\n"
           f"2026-10-05,\"30,000.00\",SYP,Top-up {ref[:7]} {ref[7:]},Test User,{bank_ref}\n"
           f"2026-10-05,1500.00,SYP,no reference here,Someone,TRX{secrets.token_hex(5)}\n"
           f"2026-10-05,25000.00,SYP,{u['reference']},Test User,TRX{secrets.token_hex(5)}\n"
           f"2026-10-05,-500.00,SYP,bank fee,,TRX{secrets.token_hex(5)}\n")
    files = {"file": ("statement.csv", csv.encode(), "text/csv")}
    r = admin.post("/api/admin/payments/statements", files=files, data={"account_label": "CBS main"})
    assert r.status_code == 201, r.text
    assert r.json() == {**r.json(), "lines": 3, "matched": 1, "unmatched": 2}
    assert balance(pax) == before + 3000000
    assert pax.get(f"/api/payments/{t['uid']}").json()["status"] == "SUCCESS"
    # the same file twice is refused
    assert admin.post("/api/admin/payments/statements", files=files, data={"account_label": "CBS main"}).status_code == 409
    lines = admin.get("/api/admin/payments/statement-lines").json()["lines"]
    differs = next(x for x in lines if x["reference"] == u["reference"])
    assert differs["note"] == "AMOUNT_DIFFERS"
    # by hand: refused while the amounts differ, accepted when finance credits what arrived
    r = admin.post(f"/api/admin/payments/statement-lines/{differs['id']}/match", json={"reference": u["reference"]})
    assert r.status_code == 409
    r = admin.post(f"/api/admin/payments/statement-lines/{differs['id']}/match", json={"reference": u["reference"], "credit_received": True})
    assert r.status_code == 200, r.text
    assert balance(pax) == before + 3000000 + 2500000
    noref = next(x for x in lines if x["reference"] == "no reference here")
    assert admin.post(f"/api/admin/payments/statement-lines/{noref['id']}/ignore", json={"note": "Not a top-up"}).status_code == 200
    assert pax.get("/api/payments/methods").status_code == 200


def test_statement_with_decimal_commas(admin, pax):
    """R-24: a bank that writes 1.234,50 is read with the decimal mark finance chooses; read with the wrong one, the
    file is refused rather than credited with another amount."""
    before = balance(pax)
    t = pax.post("/api/payments/bank-transfers", json={"amount": 12345050, "idempotency_key": key()}).json()
    text = ('"date","amount","currency","description","transaction_id"\n'
            f'"2026-10-06","123.450,50","SYP","{t["reference"]}","TRX{secrets.token_hex(5)}"\n')
    files = {"file": ("statement-eu.csv", text.encode(), "text/csv")}
    r = admin.post("/api/admin/payments/statements", files=files, data={"account_label": "EU style"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "STATEMENT_BAD_AMOUNT", r.text
    r = admin.post("/api/admin/payments/statements", files=files, data={"account_label": "EU style", "decimal_mark": ","})
    assert r.status_code == 201 and r.json()["matched"] == 1, r.text
    assert balance(pax) == before + 12345050


def test_agency_counter_topup(pax):
    agency = login("agency@agency.test", "AGENCY")
    mobile = f"+9639{secrets.randbelow(10**8):08d}"
    email = f"t{secrets.token_hex(4)}@example.com"
    reg = client()
    r = reg.post("/api/auth/register", json={"full_name": "Counter Customer", "email": email, "mobile": mobile,
                                             "password": "another-long-password"})
    assert r.status_code == 201, r.text                                  # the phone is the account's (never the party's)
    c = login(email, "PASSENGER", "another-long-password")
    before = balance(c)
    agency_before = agency.get("/api/agency/dashboard").json()
    r = agency.post("/api/agency/wallet-topups", json={"mobile": mobile, "amount": 1500000, "idempotency_key": (k := key())})
    assert r.status_code == 201, r.text
    assert r.json()["receipt"].startswith("AGT")
    again = agency.post("/api/agency/wallet-topups", json={"mobile": mobile, "amount": 1500000, "idempotency_key": k})
    assert again.json().get("replayed")
    assert balance(c) == before + 1500000
    assert agency.post("/api/agency/wallet-topups", json={"mobile": "+963900000000", "amount": 1500000,
                                                          "idempotency_key": key()}).status_code == 404
    assert agency_before is not None


def test_refund_goes_back_to_the_card(admin, pax):
    p = pax.post("/api/payments/topups", json={"method": "CARD", "amount": 2000000, "idempotency_key": key()}).json()
    pax.post(f"/api/payments/test/{p['uid']}", json={"approve": True})
    before = balance(pax)
    r = admin.post(f"/api/admin/payments/{p['uid']}/refund", json={"amount": 500000, "reason": "Customer request", "idempotency_key": (k := key())})
    assert r.status_code == 200 and r.json()["refunded_amount"] == 500000, r.text
    assert admin.post(f"/api/admin/payments/{p['uid']}/refund", json={"amount": 500000, "reason": "Customer request",
                                                                     "idempotency_key": k}).json().get("replayed")
    assert balance(pax) == before - 500000
    assert admin.post(f"/api/admin/payments/{p['uid']}/refund", json={"amount": 1600000, "reason": "Too much",
                                                                     "idempotency_key": key()}).status_code == 422
    assert admin.post(f"/api/admin/payments/{p['uid']}/refund", json={"amount": 1500000, "reason": "Rest of it",
                                                                     "idempotency_key": key()}).json()["payment_status"] == "REFUNDED"

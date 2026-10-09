"""Payouts end to end: encrypted bank accounts, withdrawals held then paid with four-eyes approval, a second approver
above the limit, logged IBAN reveal, and settlement statements approved by someone other than their author."""
import secrets
import uuid
from datetime import date, timedelta

import pytest

from test_e2e import OWNER_URL, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def make_iban(country="SY") -> str:
    """A valid IBAN with a random account number (ISO 13616 mod-97 check digits)."""
    bban = "0001" + "".join(secrets.choice("0123456789") for _ in range(16))
    digits = "".join(str(int(ch, 36)) for ch in bban + country + "00")
    return f"{country}{98 - int(digits) % 97:02d}{bban}"


@pytest.fixture(scope="module")
def carrier():
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def finance():
    return login("finance@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def account(carrier, admin):
    assert carrier.post("/api/finance/bank-accounts", json={"bank_name": "Test Bank", "holder_name": "Demo Carrier A",
                                                            "iban": "SY00 0001 2345 6789 0123 4567"}).json()["error"]["code"] == "IBAN_INVALID"
    iban = make_iban()
    r = carrier.post("/api/finance/bank-accounts", json={"bank_name": "Test Bank", "holder_name": "Demo Carrier A", "iban": iban})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    acct = next(a for a in carrier.get("/api/finance/bank-accounts").json()["accounts"] if a["uid"] == uid)
    assert acct["iban_last4"] == iban[-4:] and acct["verified"] is False and "iban" not in acct
    stored = owner_sql("SELECT iban_enc FROM iam.bank_account WHERE uid = $1", uuid.UUID(uid))
    assert iban.encode() not in stored and stored[:1] == b"\x01"              # encrypted at rest
    r = carrier.post("/api/finance/withdrawals", json={"bank_account_uid": uid, "amount": 10000, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 409 and r.json()["error"]["code"] == "BANK_ACCOUNT_NOT_VERIFIED"
    assert any(a["uid"] == uid for a in admin.get("/api/admin/finance/bank-accounts").json()["accounts"])
    assert admin.post(f"/api/admin/finance/bank-accounts/{uid}/verify").status_code == 200
    return uid, iban


@pytest.fixture
def low_second_approval_limit():
    owner_sql("UPDATE sys.setting SET value = '1000' WHERE key = 'payout.second_approval_above'")
    yield
    owner_sql("UPDATE sys.setting SET value = '100000000' WHERE key = 'payout.second_approval_above'")


def test_withdrawal_needs_two_approvers_above_the_limit_and_is_posted_when_paid(carrier, admin, finance, account,
                                                                                 low_second_approval_limit):
    uid, iban = account
    before = carrier.get("/api/finance/balance").json()
    assert before["available"] >= 10000, "the carrier needs released funds; run the completion tests first"
    key = uuid.uuid4().hex
    r = carrier.post("/api/finance/withdrawals", json={"bank_account_uid": uid, "amount": 10000, "idempotency_key": key})
    assert r.status_code == 201 and r.json()["needs_second"] is True
    w = r.json()["uid"]
    assert carrier.post("/api/finance/withdrawals", json={"bank_account_uid": uid, "amount": 10000,
                                                          "idempotency_key": key}).json()["replayed"] is True
    held = carrier.get("/api/finance/balance").json()
    assert held["held"] - before["held"] == 10000 and before["available"] - held["available"] == 10000

    assert admin.post(f"/api/admin/finance/withdrawals/{w}/approve").json()["waiting_second"] is True
    again = admin.post(f"/api/admin/finance/withdrawals/{w}/approve")
    assert again.status_code == 403 and again.json()["error"]["code"] == "FOUR_EYES"
    early = finance.post(f"/api/admin/finance/withdrawals/{w}/paid", json={"bank_ref": "TRF-1"})
    assert early.status_code == 409 and early.json()["error"]["code"] == "NOT_APPROVED"
    assert finance.post(f"/api/admin/finance/withdrawals/{w}/approve").json()["waiting_second"] is False

    details = finance.get(f"/api/admin/finance/withdrawals/{w}/transfer").json()
    assert details["iban"] == iban and details["amount"] == 10000
    logged = owner_sql("""SELECT count(*) FROM audit.data_access_log WHERE object_type = 'bank_account'
                           AND purpose LIKE '%' || $1 || '%'""", w)
    assert logged == 1

    # whoever approved it does not pay it out (review of 1.47.0, R-22): a third finance person does
    ref = f"TRF-{secrets.token_hex(3)}"
    for approver in (admin, finance):
        r = approver.post(f"/api/admin/finance/withdrawals/{w}/paid", json={"bank_ref": ref})
        assert r.status_code == 403 and r.json()["error"]["code"] == "FOUR_EYES", r.text
    treasury = login("treasury@masslak.test", "PLATFORM")
    assert treasury.post(f"/api/admin/finance/withdrawals/{w}/paid", json={"bank_ref": ref}).status_code == 200
    after = carrier.get("/api/finance/balance").json()
    assert before["balance"] - after["balance"] == 10000 and after["held"] == before["held"]
    row = next(x for x in carrier.get("/api/finance/withdrawals").json()["withdrawals"] if x["uid"] == w)
    assert row["status"] == "PAID" and row["bank_ref"] == ref
    assert owner_sql("""SELECT count(*) FROM fin.ledger_txn t WHERE (SELECT sum(CASE direction WHEN 'DR' THEN amount ELSE -amount END)
                        FROM fin.ledger_entry e WHERE e.txn_id = t.id) <> 0""") == 0


def test_rejected_withdrawal_releases_the_hold(carrier, admin, account):
    uid, _ = account
    before = carrier.get("/api/finance/balance").json()
    w = carrier.post("/api/finance/withdrawals", json={"bank_account_uid": uid, "amount": 5000,
                                                       "idempotency_key": uuid.uuid4().hex}).json()["uid"]
    assert admin.post(f"/api/admin/finance/withdrawals/{w}/reject", json={"reason": "account holder mismatch"}).status_code == 200
    assert carrier.get("/api/finance/balance").json() == before
    r = carrier.post("/api/finance/withdrawals", json={"bank_account_uid": uid, "amount": before["available"] + 1,
                                                       "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 402


def test_withdrawals_are_private_to_the_company(account):
    agency = login("agency@agency.test", "AGENCY")
    uid, _ = account
    assert all(w["bank_account_uid"] != uid for w in agency.get("/api/finance/withdrawals").json()["withdrawals"])
    r = agency.post("/api/finance/withdrawals", json={"bank_account_uid": uid, "amount": 100, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 404
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.get("/api/finance/balance").status_code == 403


def test_settlement_statement_is_approved_by_someone_else(carrier, admin, finance):
    company = next(c for c in admin.get("/api/admin/companies").json()["companies"] if c["legal_name"] == "Demo Carrier A")
    start = date.today() - timedelta(days=400) + timedelta(days=secrets.randbelow(300))   # periods may not overlap
    r = admin.post("/api/admin/finance/settlements", json={"company_uid": company["uid"], "period_from": start.isoformat(),
                                                            "period_to": start.isoformat()})
    if r.status_code == 409:
        pytest.skip("that day already has a statement")
    assert r.status_code == 201, r.text
    s = r.json()["uid"]
    own = admin.post(f"/api/admin/finance/settlements/{s}/approve")
    assert own.status_code == 403 and own.json()["error"]["code"] == "FOUR_EYES"
    assert finance.post(f"/api/admin/finance/settlements/{s}/approve").status_code == 200
    mine = next(x for x in carrier.get("/api/finance/settlements").json()["settlements"] if x["uid"] == s)
    assert mine["status"] == "APPROVED"
    detail = carrier.get(f"/api/finance/settlements/{s}").json()
    assert detail["from"] == detail["to"] == start.isoformat()
    assert sum(line["net"] for line in detail["lines"]) == detail["net"]

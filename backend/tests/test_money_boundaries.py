"""Money boundaries of release 1.48.0 (review of 1.47.0, package B, and the owner's decisions 4 and 5).

* fees set by the platform per way of paying, customer and period, shown before paying, charged and posted (R-20);
* a payment recorded before its provider is called; an unknown answer keeps it and the same request asks again with
  the same reference (R-16);
* a refund held in the wallet, sent once under a fixed reference, posted only when the provider accepted it, asked
  again after an unknown outcome, released after a refusal (R-17);
* the approval matrix: levels, permissions, named people, amounts from which a level applies, four eyes (R-23);
* the circuit breaker of provider calls.
"""
import secrets
from datetime import datetime, timedelta, timezone

import pytest

from test_e2e import OWNER_URL, login, new_passenger, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def key() -> str:
    return secrets.token_hex(12)


def balance(c) -> dict:
    return c.get("/api/wallet").json()


def party_uid(c) -> str:
    email = c.get("/api/auth/me").json()["email"]
    return str(owner_sql("SELECT p.uid FROM iam.party p JOIN iam.app_user u ON u.party_id = p.id WHERE u.email = $1", email))


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def finance():
    return login("finance@masslak.test", "PLATFORM")


@pytest.fixture(scope="module", autouse=True)
def providers_on(admin):
    """Cards and e-wallets on the simulator for this module, put back as they were afterwards."""
    before = {p["code"]: p for p in admin.get("/api/admin/payments/providers").json()["providers"]}
    base = {"min_amount": 100000, "max_amount": 100000000, "fee_pct": 0, "fee_borne_by": "PAYER"}
    for code in ("CARD", "EWALLET"):
        assert admin.put(f"/api/admin/payments/providers/{code}", json={**base, "status": "ACTIVE", "config": {}}).status_code == 200
    yield
    for code in ("CARD", "EWALLET"):
        owner_sql("UPDATE fin.payment_provider SET config = config - 'simulate_start' - 'simulate_refund', status = $2 WHERE code = $1",
                  code, before[code]["status"])
    owner_sql("UPDATE fin.fee_rule SET status = 'INACTIVE' WHERE label LIKE 'zz %'")


def simulate(code: str, what: str, how: str | None) -> None:
    owner_sql("UPDATE fin.payment_provider SET config = CASE WHEN $3::text IS NULL THEN config - $2 "
              "ELSE config || jsonb_build_object($2, $3::text) END WHERE code = $1", code, what, how)


def pay_by_card(c, amount: int) -> dict:
    p = c.post("/api/payments/topups", json={"method": "CARD", "amount": amount, "idempotency_key": key()})
    assert p.status_code == 201, p.text
    done = c.post(f"/api/payments/test/{p.json()['uid']}", json={"approve": True})
    assert done.json()["status"] == "SUCCESS", done.text
    return p.json()


# ------------------------------------------------------------------ fees (decision 4, R-20)
def test_fee_rules_are_shown_charged_and_posted(admin):
    pax = new_passenger()
    me = party_uid(pax)
    rule = {"label": "zz card fee", "provider": "CARD", "currency": "SYP", "customer_uid": me, "kind": "PERCENT_PLUS_FIXED",
            "pct": 2.5, "fixed_amount": 10000, "round_to": 100, "rounding": "UP", "borne_by": "PAYER"}
    assert admin.post("/api/admin/payments/fee-rules", json=rule).status_code == 201
    # an offer for this customer on every other way of paying, and an expired one that no longer applies
    assert admin.post("/api/admin/payments/fee-rules", json={"label": "zz free e-wallet", "currency": "SYP", "customer_uid": me,
                                                             "kind": "NONE"}).status_code == 201
    past = datetime.now(timezone.utc) - timedelta(days=2)
    assert admin.post("/api/admin/payments/fee-rules", json={
        "label": "zz old e-wallet fee", "provider": "EWALLET", "currency": "SYP", "customer_uid": me, "kind": "FIXED",
        "fixed_amount": 99900, "valid_from": (past - timedelta(days=5)).isoformat(), "valid_to": past.isoformat()}).status_code == 201

    q = pax.get("/api/payments/quote", params={"method": "CARD", "amount": 1234567}).json()
    # 2.5% of 1,234,567 = 30,864.175, plus 10,000 = 40,864.175, rounded up to a step of 100
    assert q == {**q, "amount": 1234567, "fee": 40900, "total": 1275467, "fee_label": "zz card fee", "fee_borne_by": "PAYER"}
    assert pax.get("/api/payments/quote", params={"method": "EWALLET", "amount": 1234567}).json()["fee"] == 0
    methods = {m["code"]: m for m in pax.get("/api/payments/methods").json()["methods"]}
    assert methods["CARD"]["fee_pct"] == 2.5 and methods["CARD"]["fee_fixed"] == 10000 and methods["EWALLET"]["fee_label"] == "zz free e-wallet"
    other = new_passenger()                       # another customer: none of these rules
    assert other.get("/api/payments/quote", params={"method": "CARD", "amount": 1234567}).json()["fee"] == 0

    revenue_before = owner_sql("SELECT fin.wallet_balance(w.id) FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id "
                               "WHERE p.legal_name = 'Masslak Platform' AND w.wallet_type = 'PLATFORM' AND w.currency = 'SYP'")
    start = balance(pax)["balance"]
    p = pay_by_card(pax, 1234567)
    assert p["fee"] == 40900 and p["total"] == 1275467
    assert balance(pax)["balance"] == start + 1234567, "the wallet gets the amount; the fee is not the passenger's money"
    row = owner_sql("""SELECT p.fee, p.fee_rule_id IS NOT NULL AS ruled, (SELECT sum(e.amount) FILTER (WHERE e.direction = 'DR')
                                                                         FROM fin.ledger_entry e WHERE e.txn_id = p.ledger_txn_id) AS taken
                         FROM fin.payment p WHERE p.uid = $1::uuid""", p["uid"], fetch=True)
    assert dict(row) == {"fee": 40900, "ruled": True, "taken": 1275467}
    revenue = owner_sql("SELECT fin.wallet_balance(w.id) FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id "
                        "WHERE p.legal_name = 'Masslak Platform' AND w.wallet_type = 'PLATFORM' AND w.currency = 'SYP'")
    assert revenue - revenue_before >= 40900


def test_a_fee_the_platform_bears_is_not_asked_from_the_payer(admin):
    pax = new_passenger()
    assert admin.post("/api/admin/payments/fee-rules", json={
        "label": "zz offer: card fee on us", "provider": "CARD", "currency": "SYP", "customer_uid": party_uid(pax),
        "kind": "PERCENT", "pct": 3, "borne_by": "PLATFORM"}).status_code == 201
    q = pax.get("/api/payments/quote", params={"method": "CARD", "amount": 1000000}).json()
    assert q["fee"] == 0 and q["total"] == 1000000 and q["fee_absorbed"] == 30000
    p = pay_by_card(pax, 1000000)
    assert owner_sql("SELECT fee_absorbed FROM fin.payment WHERE uid = $1::uuid", p["uid"]) == 30000


def test_fee_rules_are_managed_by_the_platform_only(admin):
    pax = new_passenger()
    assert pax.get("/api/admin/payments/fee-rules").status_code == 403
    bad = admin.post("/api/admin/payments/fee-rules", json={"label": "zz bad", "kind": "FIXED", "fixed_amount": 500})
    assert bad.status_code == 422, "a fixed amount needs a currency"
    listed = admin.get("/api/admin/payments/fee-rules").json()["rules"]
    assert any(r["label"] == "zz card fee" for r in listed)


# ------------------------------------------------------------------ the provider call (R-16)
def test_a_payment_is_kept_when_the_provider_does_not_answer():
    pax = new_passenger()
    simulate("CARD", "simulate_start", "no_answer")
    try:
        k = key()
        r = pax.post("/api/payments/topups", json={"method": "CARD", "amount": 600000, "idempotency_key": k})
        assert r.status_code == 502 and r.json()["error"]["code"] == "PAYMENT_PROVIDER_UNAVAILABLE", r.text
        uid = r.json()["error"]["payment"]
        first = owner_sql("SELECT status, stage, provider_attempts, provider_ref FROM fin.payment WHERE uid = $1::uuid", uid, fetch=True)
        assert (first["status"], first["stage"], first["provider_attempts"]) == ("PENDING", "PROVIDER_UNKNOWN", 1)
    finally:
        simulate("CARD", "simulate_start", None)
    # the same request asks the provider again with the same merchant reference: never a second charge
    again = pax.post("/api/payments/topups", json={"method": "CARD", "amount": 600000, "idempotency_key": k})
    assert again.status_code == 201 and again.json()["uid"] == uid and again.json()["action"] == "REDIRECT", again.text
    after = owner_sql("SELECT stage, provider_attempts, provider_ref FROM fin.payment WHERE uid = $1::uuid", uid, fetch=True)
    assert (after["stage"], after["provider_attempts"], after["provider_ref"]) == ("REDIRECTED", 2, first["provider_ref"])
    assert after["provider_ref"].startswith("CRD") and uid.replace("-", "")[:20].upper() in after["provider_ref"]


def test_a_refused_start_fails_the_payment():
    pax = new_passenger()
    simulate("CARD", "simulate_start", "refuse")
    try:
        r = pax.post("/api/payments/topups", json={"method": "CARD", "amount": 600000, "idempotency_key": key()})
        assert r.status_code == 502 and r.json()["error"]["code"] == "PAYMENT_PROVIDER_REFUSED", r.text
        assert owner_sql("SELECT failure_code FROM fin.payment WHERE uid = $1::uuid", r.json()["error"]["payment"]) == "PROVIDER_REFUSED"
    finally:
        simulate("CARD", "simulate_start", None)


# ------------------------------------------------------------------ refunds (R-17)
def test_a_refund_is_held_sent_once_and_posted_only_when_accepted(admin):
    pax = new_passenger()
    p = pay_by_card(pax, 2000000)
    before = balance(pax)
    simulate("CARD", "simulate_refund", "no_answer")
    try:
        r = admin.post(f"/api/admin/payments/{p['uid']}/refund", json={"amount": 700000, "reason": "Customer request", "idempotency_key": key()})
        assert r.status_code == 200 and r.json()["status"] == "PENDING" and r.json()["stage"] == "UNKNOWN", r.text
        rid = r.json()["uid"]
        held = balance(pax)
        assert held["balance"] == before["balance"], "nothing is posted before the provider accepts"
        assert owner_sql("SELECT hold_balance FROM fin.wallet w JOIN fin.payment p ON p.wallet_id = w.id WHERE p.uid = $1::uuid",
                         p["uid"]) == 700000, "but the amount cannot be spent meanwhile"
        ref = owner_sql("SELECT provider_reference FROM fin.payment_refund WHERE uid = $1::uuid", rid)
        # what is left to refund counts the refund in flight
        too_much = admin.post(f"/api/admin/payments/{p['uid']}/refund", json={"amount": 1400000, "reason": "More of it", "idempotency_key": key()})
        assert too_much.status_code == 422 and too_much.json()["error"]["refundable"] == 1300000
    finally:
        simulate("CARD", "simulate_refund", None)
    done = admin.post(f"/api/admin/payments/refunds/{rid}/resend")
    assert done.status_code == 200 and done.json()["status"] == "SUCCESS" and done.json()["refunded_amount"] == 700000, done.text
    row = owner_sql("SELECT provider_reference, attempts, held FROM fin.payment_refund WHERE uid = $1::uuid", rid, fetch=True)
    assert (row["provider_reference"], row["attempts"], row["held"]) == (ref, 2, False)
    assert balance(pax)["balance"] == before["balance"] - 700000
    assert owner_sql("SELECT hold_balance FROM fin.wallet w JOIN fin.payment p ON p.wallet_id = w.id WHERE p.uid = $1::uuid", p["uid"]) == 0
    assert admin.post(f"/api/admin/payments/refunds/{rid}/resend").status_code == 409


def test_a_refused_refund_releases_the_hold(admin):
    pax = new_passenger()
    p = pay_by_card(pax, 1500000)
    before = balance(pax)
    simulate("CARD", "simulate_refund", "refuse")
    try:
        r = admin.post(f"/api/admin/payments/{p['uid']}/refund", json={"amount": 500000, "reason": "Customer request", "idempotency_key": key()})
        assert r.status_code == 200 and r.json()["status"] == "FAILED" and r.json()["stage"] == "REFUSED", r.text
    finally:
        simulate("CARD", "simulate_refund", None)
    assert balance(pax) == before
    assert owner_sql("SELECT hold_balance FROM fin.wallet w JOIN fin.payment p ON p.wallet_id = w.id WHERE p.uid = $1::uuid", p["uid"]) == 0


# ------------------------------------------------------------------ the approval matrix (decision 5)
@pytest.fixture()
def two_level_refunds(admin):
    """Refunds need finance review, and from 1,000,000 a second level that only the treasurer may decide."""
    r = admin.put("/api/admin/approvals/policies/REFUND", json={"levels": [
        {"name": "Finance review", "permission": "compensation.pay"},
        {"name": "Large refunds", "permission": "payout.run", "min_amount": 1000000, "members": ["treasury@masslak.test"]}]})
    assert r.status_code == 200, r.text
    yield
    assert admin.put("/api/admin/approvals/policies/REFUND", json={"levels": []}).status_code == 200


def test_the_matrix_takes_its_levels_in_order_from_the_named_people(admin, finance, two_level_refunds):
    pax = new_passenger()
    p = pay_by_card(pax, 3000000)
    before = balance(pax)["balance"]
    r = admin.post(f"/api/admin/payments/{p['uid']}/refund", json={"amount": 1200000, "reason": "Cancelled tour", "idempotency_key": key()})
    assert r.status_code == 200 and r.json()["stage"] == "AWAITING_APPROVAL" and r.json()["approval"]["levels"] == [1, 2], r.text
    uid = r.json()["approval"]["uid"]

    def decide(who, decision="APPROVE", note=None):
        return who.post(f"/api/admin/approvals/{uid}/decision", json={"decision": decision, "note": note})

    assert decide(admin).json()["error"]["code"] == "FOUR_EYES"                 # the requester decides nothing
    assert decide(finance).json()["status"] == "PENDING"                          # level 1
    assert decide(finance).json()["error"]["code"] in ("APPROVAL_NOT_ALLOWED", "ALREADY_EXISTS")   # one person, one level
    security = login("security@masslak.test", "PLATFORM")
    assert decide(security).json()["error"]["code"] == "APPROVAL_NOT_ALLOWED"    # level 2 is for the named people only
    assert balance(pax)["balance"] == before
    treasury = login("treasury@masslak.test", "PLATFORM")
    done = decide(treasury)
    assert done.status_code == 200 and done.json()["status"] == "APPROVED" and done.json()["refund"]["status"] == "SUCCESS", done.text
    assert balance(pax)["balance"] == before - 1200000
    # below the second level's amount, finance review alone
    small = admin.post(f"/api/admin/payments/{p['uid']}/refund", json={"amount": 300000, "reason": "Small one", "idempotency_key": key()})
    assert small.json()["approval"]["levels"] == [1]


def test_a_rejection_releases_the_refund(admin, finance, two_level_refunds):
    pax = new_passenger()
    p = pay_by_card(pax, 1000000)
    before = balance(pax)
    r = admin.post(f"/api/admin/payments/{p['uid']}/refund", json={"amount": 400000, "reason": "Not justified", "idempotency_key": key()})
    uid = r.json()["approval"]["uid"]
    no_reason = finance.post(f"/api/admin/approvals/{uid}/decision", json={"decision": "REJECT"})
    assert no_reason.status_code == 422
    assert finance.post(f"/api/admin/approvals/{uid}/decision", json={"decision": "REJECT", "note": "No proof"}).json()["status"] == "REJECTED"
    assert balance(pax) == before
    assert owner_sql("SELECT status || '/' || stage FROM fin.payment_refund WHERE uid = $1::uuid", r.json()["uid"]) == "FAILED/REJECTED"


def test_the_matrix_refuses_people_who_could_never_decide(admin, finance):
    r = admin.put("/api/admin/approvals/policies/BANK_CREDIT", json={"levels": [
        {"name": "Finance review", "permission": "ledger.reconcile", "members": ["regulator@masslak.test"]}]})
    assert r.status_code == 422 and r.json()["error"]["code"] == "MEMBER_CANNOT_DECIDE"
    assert finance.put("/api/admin/approvals/policies/BANK_CREDIT", json={"levels": []}).status_code == 403
    policies = {p["action"]: p for p in finance.get("/api/admin/approvals/policies").json()["policies"]}
    assert policies["BANK_CREDIT"]["levels"][0]["permission"] == "ledger.reconcile"
    assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'approval.policy_changed'") >= 1


# ------------------------------------------------------------------ the circuit breaker
def test_the_circuit_opens_after_unanswered_calls_and_closes_on_an_answer(monkeypatch):
    from app.errors import ApiError
    from app.modules.payments import breaker
    breaker.reset()
    monkeypatch.setenv("MASSLAK_PSP_BREAKER_FAILURES", "3")
    monkeypatch.setenv("MASSLAK_PSP_BREAKER_OPEN_SECONDS", "0.2")
    for _ in range(3):
        breaker.before("ZZ")
        breaker.after("ZZ", False)
    assert breaker.is_open("ZZ")
    with pytest.raises(ApiError) as e:
        breaker.before("ZZ")
    assert e.value.status == 503 and e.value.details["retry_after"] >= 1
    import time
    time.sleep(0.25)
    breaker.before("ZZ")                       # the trial call goes through
    with pytest.raises(ApiError):
        breaker.before("ZZ")                   # only one at a time while half open
    breaker.after("ZZ", True)
    assert not breaker.is_open("ZZ")
    breaker.before("ZZ")
    breaker.after("ZZ", False)                 # one failure on a closed circuit does not open it
    assert not breaker.is_open("ZZ")
    breaker.reset()


def test_withdrawal_payer_is_not_an_approver_in_the_database():
    """R-22 in the database too: a direct write cannot make an approver the payer (1074)."""
    row = owner_sql("""SELECT pg_get_constraintdef(oid) FROM pg_constraint
                        WHERE conrelid = 'fin.withdrawal_request'::regclass AND conname = 'withdrawal_paid_by_not_approver'""")
    assert "approved_by" in row and "second_approver" in row

"""Phase one, no money with the platform (owner's decision N13; migration 1145): the platform switches to NO_FUNDS,
naming the decision; the wallet, an agency's balance, cards, instalments and financing close, top-ups and withdrawals
stop, and the fee is zero; switching back to FULL reopens what was open."""
import uuid

import pytest

from test_e2e import OWNER_URL, login, new_passenger

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def test_phase_one_holds_no_money_and_ends_as_it_began():
    admin = login("admin@masslak.test", "PLATFORM")
    before = admin.get("/api/admin/money-mode").json()
    assert before["mode"] == "FULL" and "WALLET" in before["open"]
    assert login("owner@carrier.test", "OPERATOR").put("/api/admin/money-mode", json={
        "mode": "NO_FUNDS", "basis": "a carrier tries"}).status_code == 403
    try:
        r = admin.put("/api/admin/money-mode", json={"mode": "NO_FUNDS", "basis": "Phase one of the pilot"})
        assert r.status_code == 200, r.text
        assert r.json()["mode"] == "NO_FUNDS" and not {"WALLET", "AGENCY_BALANCE", "CARD"} & set(r.json()["open"])
        assert {"PAY_LATER", "CASH_COUNTER"} <= set(r.json()["open"])
        r = new_passenger().post("/api/wallet/topup", json={"amount": 5000, "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 409 and r.json()["error"]["code"] == "NO_FUNDS_PHASE", r.text
        owner = login("owner@carrier.test", "OPERATOR")
        assert owner.get("/api/finance/balance").json()["money_mode"] == "NO_FUNDS"
        r = owner.post("/api/finance/withdrawals", json={"bank_account_uid": str(uuid.uuid4()), "amount": 1000,
                                                         "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 409 and r.json()["error"]["code"] == "NO_FUNDS_PHASE", r.text
        r = admin.put("/api/admin/money-mode", json={"mode": "NO_FUNDS", "basis": "x"})
        assert r.status_code == 422                                              # the decision is named
    finally:
        r = admin.put("/api/admin/money-mode", json={"mode": "FULL", "basis": "back to the test default"})
        assert r.status_code == 200, r.text
    assert set(before["open"]) <= set(r.json()["open"])

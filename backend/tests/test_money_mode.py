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
        assert {"PAY_LATER", "CASH_COUNTER", "AGENCY_CASH"} <= set(r.json()["open"])
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


def test_an_agency_sells_for_cash_in_phase_one_and_settles_with_the_carrier():
    """An agency's sale in phase one is cash (AGENCY_CASH): it keeps its commission, owes the carrier the rest, and the
    carrier records what it receives; the account between them follows each sale, refund and receipt."""
    from test_agency import sell
    from test_e2e import bookable_trip, client, free_seats, owner_sql, publish_fresh_trip
    admin = login("admin@masslak.test", "PLATFORM")
    a = next(a for a in admin.get("/api/admin/agencies").json()["agencies"] if a["legal_name"] == "Demo Travel Agency")
    assert admin.post(f"/api/admin/agencies/{a['uid']}/agreement", json={
        "commission_bp": 500, "daily_limit": 10_000_000_000, "status": "ACTIVE", "reason": "test run"}).status_code == 200
    agency, owner = login("agency@agency.test", "AGENCY"), login("owner@carrier.test", "OPERATOR")
    t = bookable_trip(client())
    if t is None:
        publish_fresh_trip()
        t = bookable_trip(client())
    try:
        assert admin.put("/api/admin/money-mode", json={"mode": "NO_FUNDS", "basis": "Phase one of the pilot"}).status_code == 200
        assert agency.get("/api/agency/cash-accounts").json()["cash_sales"] is True

        def account() -> dict:
            rows = [x for x in owner.get("/api/carrier/agency-cash").json()["accounts"] if x["agency_uid"] == a["uid"]]
            return rows[0] if rows else {"owed": 0, "received": 0, "sold": 0}
        before = account()
        r = sell(agency, t, free_seats(agency, t, 2))
        assert r.status_code == 201, r.text
        out = r.json()
        assert out["pay_option"] == "AGENCY_CASH" and out["status"] == "CONFIRMED"
        fares = out["total"]                                                  # no platform fee in phase one
        assert out["commission"] == (fares * 500 // 10000) // 100 * 100       # the agency keeps its commission
        share = fares - out["commission"]
        assert account()["owed"] == before["owed"] + share
        assert owner_sql(f"SELECT pay_method FROM sales.booking WHERE booking_ref = '{out['booking_ref']}'") == "CASH"

        # the carrier records what it receives: never more than owed, each reference once
        body = {"agency_uid": a["uid"], "currency": "SYP", "amount": account()["owed"] + 100, "reference": f"R-{uuid.uuid4().hex[:8]}"}
        r = owner.post("/api/carrier/agency-cash/receipts", json=body)
        assert r.status_code == 409 and r.json()["error"]["code"] == "MORE_THAN_OWED", r.text
        body["amount"] = share // 2
        r = owner.post("/api/carrier/agency-cash/receipts", json=body)
        assert r.status_code == 201 and r.json()["owed"] == before["owed"] + share - share // 2, r.text
        assert owner.post("/api/carrier/agency-cash/receipts", json=body).json()["error"]["code"] == "REFERENCE_USED"
        mine = agency.get("/api/agency/cash-accounts").json()
        assert any(x["reference"] == body["reference"] for x in mine["receipts"])
        assert owner_sql(f"SELECT count(*) FROM sys.outbox_event WHERE event_type = 'agency_cash.received' "
                         f"AND payload ->> 'reference' = '{body['reference']}'") == 1
        # another agency's clerk or a passenger cannot record or read the carrier's side
        assert agency.post("/api/carrier/agency-cash/receipts", json=body).status_code == 403
        assert new_passenger().get("/api/agency/cash-accounts").status_code == 403

        # a cancellation hands cash back to the traveller: the carrier's share falls by what was refunded
        owed_before_cancel = account()["owed"]
        r = agency.post(f"/api/agency/bookings/{out['booking_ref']}/cancel")
        assert r.status_code == 200, r.text
        assert account()["owed"] < owed_before_cancel
    finally:
        assert admin.put("/api/admin/money-mode", json={"mode": "FULL", "basis": "back to the test default"}).status_code == 200
    assert agency.get("/api/agency/cash-accounts").json()["cash_sales"] is False


def test_the_gateway_opens_carrier_by_carrier_and_each_step_is_told():
    """Phase two: the platform records each carrier's contract, then activates the option; the carrier is told at each
    step, and a gateway option is offered on a carrier's trips only while active for it."""
    from test_e2e import owner_sql
    admin, owner = login("admin@masslak.test", "PLATFORM"), login("owner@carrier.test", "OPERATOR")
    mine = owner.get("/api/carrier/payment-activations").json()["activations"]
    carrier_uid = mine[0]["carrier_uid"]
    assert {x["option_code"]: x["status"] for x in mine}["INSTALLMENT"] == "ACTIVE"
    events = "SELECT count(*) FROM sys.outbox_event WHERE event_type = '{}' AND payload ->> 'option' = 'INSTALLMENT'"
    paused = owner_sql(events.format("payment_activation.suspended"))
    try:
        r = admin.put(f"/api/admin/payment-activations/{carrier_uid}/INSTALLMENT", json={"status": "SUSPENDED", "basis": "Gateway maintenance"})
        assert r.status_code == 200 and r.json()["status"] == "SUSPENDED", r.text
        assert owner_sql(events.format("payment_activation.suspended")) == paused + 1
        assert owner_sql(f"SELECT fin.carrier_takes((SELECT id FROM iam.party WHERE uid = '{carrier_uid}'), 'INSTALLMENT')") is False
        # the same state again tells nobody twice
        assert admin.put(f"/api/admin/payment-activations/{carrier_uid}/INSTALLMENT", json={"status": "SUSPENDED", "basis": "still"}).status_code == 200
        assert owner_sql(events.format("payment_activation.suspended")) == paused + 1
        # a carrier cannot change it; an unknown carrier is not found
        assert owner.put(f"/api/admin/payment-activations/{carrier_uid}/INSTALLMENT", json={"status": "ACTIVE", "basis": "a carrier tries"}).status_code == 403
        assert admin.put(f"/api/admin/payment-activations/{uuid.uuid4()}/CARD", json={"status": "CONTRACTED", "basis": "nobody"}).status_code == 404
    finally:
        r = admin.put(f"/api/admin/payment-activations/{carrier_uid}/INSTALLMENT", json={"status": "ACTIVE", "basis": "Maintenance over"})
        assert r.status_code == 200 and r.json()["activated_at"], r.text
    assert owner_sql(events.format("payment_activation.active")) >= 1

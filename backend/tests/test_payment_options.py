"""Payment options switched by the platform (1056): cash at the carrier's counter with a credit limit, reserve online
and pay at the counter, card / instalment / financing payments through a provider, expiry of unpaid reservations,
setting carrier earnings off against counter cash, and remittances confirmed by a second person."""
import math
import uuid
from datetime import datetime, timezone

import pytest

from test_e2e import (OWNER_URL, bookable_trip, client, free_seats, login, owner_sql, publish_fresh_trip, syrian)

HIGH_LIMIT = 10_000_000_000


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def finance():
    return login("finance@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def counter():
    return login("counter@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def pax():
    c = login("passenger@masslak.test", "PASSENGER")
    r = c.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 200, r.text
    return c


@pytest.fixture(scope="module")
def trip():
    c = client()
    t = bookable_trip(c)
    if t is None:
        publish_fresh_trip()
        t = bookable_trip(c)
    assert t
    return t


@pytest.fixture(scope="module")
def company(admin, trip):
    """The demo carrier's id, with a limit high enough for the tests."""
    positions = admin.get("/api/admin/cash/positions").json()["positions"]
    cid = next(p["company_id"] for p in positions if p["name"] == trip["carrier_name"])
    r = admin.put(f"/api/admin/cash/limits/{cid}", json={"limit_amount": HIGH_LIMIT, "reason": "test run"})
    assert r.status_code == 200, r.text
    return cid


def method(admin, code: str) -> dict:
    return next(m for m in admin.get("/api/admin/payment-methods").json()["methods"] if m["code"] == code)


def switch(admin, code: str, enabled: bool, **changes):
    m = method(admin, code)
    body = {"enabled": enabled, "channels": changes.pop("channels", m["channels"]), "min_amount": changes.pop("min_amount", m["min_amount"]),
            "max_amount": changes.pop("max_amount", m["max_amount"]), "config": changes.pop("config", {}),
            "reason": "test run of the payment options"}
    return admin.put(f"/api/admin/payment-methods/{code}", json=body)


def provider(admin, code: str, status: str):
    p = next(p for p in admin.get("/api/admin/payments/providers").json()["providers"] if p["code"] == code)
    return admin.put(f"/api/admin/payments/providers/{code}", json={
        "status": status, "min_amount": p["min_amount"], "max_amount": p["max_amount"], "fee_pct": p["fee_pct"],
        "fee_borne_by": p["fee_borne_by"], "config": {}})


def hold(c, trip, seats, base="/api"):
    r = c.post(f"{base}/holds", json={"trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"], "seat_nos": seats})
    assert r.status_code == 201, r.text
    return r.json()["hold_token"]


def book(c, trip, seats, pay_with="WALLET", base="/api", **extra):
    token = hold(c, trip, seats, base)
    r = c.post(f"{base}/bookings", json={
        "hold_token": token, "trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"],
        "passengers": [syrian(s) for s in seats], "idempotency_key": uuid.uuid4().hex, "pay_with": pay_with, **extra})
    if r.status_code != 201:
        c.delete(f"{base}/holds/{token}")
    return r


def counter_sell(counter, trip, n=1):
    return book(counter, trip, free_seats(counter, trip, n), base="/api/carrier/counter", contact_mobile="+963944000222")


def owed(counter) -> int:
    return counter.get("/api/carrier/counter/dashboard").json()["owed"]


def test_switches_are_listed_and_guarded(admin, pax, counter):
    codes = [o["code"] for o in pax.get("/api/payments/booking-options").json()["options"]]
    assert codes == ["WALLET", "PAY_LATER"]                  # card, instalments and financing wait for a contract
    listed = admin.get("/api/admin/payment-methods").json()
    assert {m["code"] for m in listed["methods"]} == {"WALLET", "AGENCY_BALANCE", "CASH_COUNTER", "PAY_LATER", "CARD", "INSTALLMENT", "FINANCING"}
    assert listed["can_change"] is True
    # an electronic option cannot open without an active provider behind it
    r = switch(admin, "CARD", True)
    assert r.status_code == 409 and r.json()["error"]["code"] == "NO_ACTIVE_PROVIDER", r.text
    # an option is offered only on its own channels, and settings are checked
    assert switch(admin, "PAY_LATER", True, channels=["WEB", "APP", "COUNTER"]).json()["error"]["code"] == "CHANNEL_NOT_ALLOWED"
    assert switch(admin, "PAY_LATER", True, config={"hold_hours": 0}).json()["error"]["code"] == "INVALID_VALUE"
    assert switch(admin, "PAY_LATER", True, config={"surprise": 1}).json()["error"]["code"] == "CONFIG_NOT_EDITABLE"
    # only platform staff with the permission change them
    assert pax.put("/api/admin/payment-methods/WALLET", json={}).status_code in (403, 422)
    assert counter.get("/api/admin/payment-methods").status_code == 403
    regulator = login("regulator@masslak.test", "PLATFORM")
    assert regulator.put("/api/admin/payment-methods/WALLET", json={
        "enabled": False, "channels": ["WEB"], "min_amount": 0, "max_amount": None, "config": {}, "reason": "not allowed"}).status_code == 403


def test_closed_option_refuses_bookings(admin, pax, trip):
    assert switch(admin, "WALLET", False).status_code == 200
    try:
        r = book(pax, trip, free_seats(pax, trip, 1))
        assert r.status_code == 409 and r.json()["error"]["code"] == "PAYMENT_METHOD_DISABLED", r.text
        assert "WALLET" not in [o["code"] for o in pax.get("/api/payments/booking-options").json()["options"]]
    finally:
        assert switch(admin, "WALLET", True).status_code == 200


def test_counter_sells_for_cash(counter, company, trip):
    before = owed(counter)
    r = counter_sell(counter, trip, 2)
    assert r.status_code == 201, r.text
    out = r.json()
    assert out["status"] == "CONFIRMED" and out["pay_option"] == "CASH_COUNTER"
    assert owed(counter) - before == out["total"]           # the cash in the drawer is owed to the platform
    detail = counter.get(f"/api/carrier/counter/bookings/{out['booking_ref']}").json()
    assert detail["booking"]["counter_sale"] and detail["booking"]["refundable_here"]
    assert all(t["status"] == "ISSUED" for t in detail["tickets"])
    assert counter.get(f"/api/carrier/counter/tickets/{detail['tickets'][0]['uid']}/qr").status_code == 200
    found = counter.get("/api/carrier/counter/bookings", params={"q": "+963944000222"}).json()["bookings"]
    assert any(b["booking_ref"] == out["booking_ref"] for b in found)
    report = counter.get("/api/carrier/counter/report").json()
    assert report["sales"] >= 1 and report["cash_in"] >= out["total"]
    pytest.cash_ref, pytest.cash_total = out["booking_ref"], out["total"]


def test_only_carrier_sellers_use_the_counter(counter, pax):
    assert pax.get("/api/carrier/counter/dashboard").status_code == 403
    assert login("driver@carrier.test", "DRIVER").get("/api/carrier/counter/dashboard").status_code == 403
    assert login("owner@carrier.test", "OPERATOR").get("/api/carrier/counter/dashboard").status_code == 200   # owners may sell too
    # a trip that is not the carrier's own is not found at its counter
    r = counter.post("/api/carrier/counter/holds", json={"trip_uid": str(uuid.uuid4()), "from_seq": 0, "to_seq": 1, "seat_nos": [1]})
    assert r.status_code == 404


def test_credit_limit_stops_cash_sales(admin, counter, company, trip):
    now = owed(counter)
    assert admin.put(f"/api/admin/cash/limits/{company}", json={"limit_amount": now + 1000, "reason": "limit test"}).status_code == 200
    try:
        r = counter_sell(counter, trip)
        assert r.status_code == 409 and r.json()["error"]["code"] == "CASH_LIMIT_REACHED", r.text
        assert counter.get("/api/carrier/counter/dashboard").json()["remaining"] == 1000
        assert counter.put(f"/api/admin/cash/limits/{company}", json={"limit_amount": 1, "reason": "not mine"}).status_code == 403
    finally:
        admin.put(f"/api/admin/cash/limits/{company}", json={"limit_amount": HIGH_LIMIT, "reason": "restore"})


def test_counter_cancel_gives_cash_back(counter):
    before = owed(counter)
    r = counter.post(f"/api/carrier/counter/bookings/{pytest.cash_ref}/cancel")
    assert r.status_code == 200, r.text
    refund = r.json()["refund"]
    assert refund > 0 and before - owed(counter) == refund    # the cash handed back no longer counts as owed
    again = counter.post(f"/api/carrier/counter/bookings/{pytest.cash_ref}/cancel")
    assert again.status_code == 409


def test_pay_later_reserves_then_counter_collects(pax, counter, trip):
    wallet = pax.get("/api/wallet").json()["balance"]
    r = book(pax, trip, free_seats(pax, trip, 1), pay_with="PAY_LATER")
    assert r.status_code == 201, r.text
    out = r.json()
    assert out["status"] == "PENDING_PAYMENT" and out["pay_by"]
    assert pax.get("/api/wallet").json()["balance"] == wallet            # nothing was taken
    detail = pax.get(f"/api/bookings/{out['booking_ref']}").json()
    assert detail["booking"]["status"] == "PENDING_PAYMENT" and detail["booking"]["pay_by"]
    ticket = detail["tickets"][0]
    assert ticket["status"] == "HOLD"
    assert pax.get(f"/api/tickets/{ticket['uid']}/qr").json()["error"]["code"] == "TICKET_NOT_VALID"
    # at the counter the passenger gives the reference and pays cash
    view = counter.get(f"/api/carrier/counter/bookings/{out['booking_ref']}").json()
    assert view["booking"]["collectable"] is True
    before = owed(counter)
    c = counter.post(f"/api/carrier/counter/bookings/{out['booking_ref']}/collect")
    assert c.status_code == 200 and c.json()["status"] == "CONFIRMED", c.text
    assert owed(counter) - before == out["total"]
    assert counter.post(f"/api/carrier/counter/bookings/{out['booking_ref']}/collect").json()["replayed"] is True
    detail = pax.get(f"/api/bookings/{out['booking_ref']}").json()
    assert detail["booking"]["status"] == "CONFIRMED" and detail["tickets"][0]["status"] == "ISSUED"
    assert pax.get(f"/api/tickets/{ticket['uid']}/qr").status_code == 200
    pytest.later_ref = out["booking_ref"]


def test_the_apps_book_on_their_own_channel(admin, pax, trip):
    """The passenger apps (review stage C8) see and use the options open on the APP channel, and their bookings are
    recorded on APP_ANDROID or APP_IOS; a switch closed for the apps leaves the website as it is."""
    from test_mobile import bearer, mobile_login
    r, _ = mobile_login("passenger@masslak.test")
    app = bearer(r.json()["access_token"], "ios")
    m = method(admin, "PAY_LATER")
    assert switch(admin, "PAY_LATER", True, channels=["WEB"]).status_code == 200
    try:
        assert "PAY_LATER" not in [o["code"] for o in app.get("/api/payments/booking-options").json()["options"]]
        assert "PAY_LATER" in [o["code"] for o in pax.get("/api/payments/booking-options").json()["options"]]
        refused = book(app, trip, free_seats(app, trip, 1), pay_with="PAY_LATER")
        assert refused.status_code == 409 and refused.json()["error"]["code"] == "PAYMENT_METHOD_DISABLED", refused.text
    finally:
        assert switch(admin, "PAY_LATER", True, channels=m["channels"]).status_code == 200
    opts = {o["code"]: o for o in app.get("/api/payments/booking-options").json()["options"]}
    assert opts["PAY_LATER"]["hold_hours"] and opts["PAY_LATER"]["cutoff_minutes"]
    r = book(app, trip, free_seats(app, trip, 1), pay_with="PAY_LATER")
    assert r.status_code == 201 and r.json()["status"] == "PENDING_PAYMENT" and r.json()["pay_by"], r.text
    ref = r.json()["booking_ref"]
    detail = app.get(f"/api/bookings/{ref}").json()["booking"]
    assert detail["pay_option"] == "PAY_LATER" and detail["pay_by"]
    if OWNER_URL:
        assert owner_sql("SELECT c.code FROM sales.booking b JOIN sales.channel c ON c.id = b.channel_id WHERE b.booking_ref = $1", ref) == "APP_IOS"
    # the reservation is cancelled from the app and the seat goes back on sale
    out = app.post(f"/api/bookings/{ref}/cancel")
    assert out.status_code == 200 and out.json()["status"] == "CANCELLED", out.text


def test_cash_paid_booking_is_refunded_in_cash(admin, pax, counter):
    # without the wallet open, the passenger has nowhere online to receive cash back: the counter refunds it
    assert switch(admin, "WALLET", False).status_code == 200
    try:
        r = pax.post(f"/api/bookings/{pytest.later_ref}/cancel")
        assert r.status_code == 409 and r.json()["error"]["code"] == "CANCEL_AT_COUNTER", r.text
    finally:
        switch(admin, "WALLET", True)
    before = owed(counter)
    r = counter.post(f"/api/carrier/counter/bookings/{pytest.later_ref}/cancel")
    assert r.status_code == 200 and before - owed(counter) == r.json()["refund"], r.text


def test_open_reservations_are_limited_and_cancellable(pax, trip):
    m = method(login("admin@masslak.test", "PLATFORM"), "PAY_LATER")
    refs = []
    try:
        for _ in range(m["config"]["max_open"] + 1):
            r = book(pax, trip, free_seats(pax, trip, 1), pay_with="PAY_LATER")
            if r.status_code == 201:
                refs.append(r.json()["booking_ref"])
            else:
                assert r.status_code == 409 and r.json()["error"]["code"] == "TOO_MANY_RESERVATIONS", r.text
                break
        else:
            pytest.fail("a passenger kept more open reservations than allowed")
    finally:
        for ref in refs:
            seat = pax.get(f"/api/bookings/{ref}").json()["tickets"][0]["seat_no"]
            r = pax.post(f"/api/bookings/{ref}/cancel")
            assert r.status_code == 200 and r.json()["refund"] == 0 and r.json()["status"] == "CANCELLED", r.text
            assert seat in _free(pax, trip)                       # the seat is back on sale


def _free(c, t):
    seats = c.get(f"/api/trips/{t['uid']}", params={"from_seq": t["from_seq"], "to_seq": t["to_seq"]}).json()["seats"]
    return [x["seat_no"] for x in seats if x["free"]]


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to move the pay-by time")
def test_unpaid_reservation_expires_and_frees_its_seats(pax, counter, trip):
    seat = free_seats(pax, trip, 1)
    r = book(pax, trip, seat, pay_with="PAY_LATER")
    assert r.status_code == 201, r.text
    ref = r.json()["booking_ref"]
    assert seat[0] not in _free(pax, trip)
    owner_sql("UPDATE sales.booking SET hold_expires_at = now() - interval '1 minute' WHERE booking_ref = $1", ref)
    assert counter.post(f"/api/carrier/counter/bookings/{ref}/collect").json()["error"]["code"] == "RESERVATION_EXPIRED"
    assert owner_sql("SELECT sales.expire_reservations()") >= 1
    assert pax.get(f"/api/bookings/{ref}").json()["booking"]["status"] == "EXPIRED"
    assert seat[0] in _free(pax, trip)
    assert counter.post(f"/api/carrier/counter/bookings/{ref}/collect").json()["error"]["code"] == "BOOKING_NOT_PENDING"


def test_instalments_through_a_provider(admin, pax, trip):
    assert provider(admin, "INSTALMENTS", "ACTIVE").status_code == 200
    try:
        assert switch(admin, "INSTALLMENT", True).status_code == 200
        opts = {o["code"]: o for o in pax.get("/api/payments/booking-options").json()["options"]}
        assert [p["code"] for p in opts["INSTALLMENT"]["providers"]] == ["INSTALMENTS"]
        # a provider an open option relies on cannot be switched off
        r = provider(admin, "INSTALMENTS", "INACTIVE")
        assert r.status_code == 409 and r.json()["error"]["code"] == "PROVIDER_IN_USE", r.text
        wallet = pax.get("/api/wallet").json()["balance"]
        r = book(pax, trip, free_seats(pax, trip, 1), pay_with="INSTALLMENT")
        assert r.status_code == 201 and r.json()["status"] == "PENDING_PAYMENT", r.text
        ref = r.json()["booking_ref"]
        assert pax.post(f"/api/bookings/{ref}/payments", json={"provider": "SANDBOX", "idempotency_key": uuid.uuid4().hex}).status_code == 409
        p = pax.post(f"/api/bookings/{ref}/payments", json={"provider": "INSTALMENTS", "idempotency_key": uuid.uuid4().hex})
        assert p.status_code == 201 and p.json()["action"] == "REDIRECT", p.text
        uid = p.json()["uid"]
        again = pax.post(f"/api/bookings/{ref}/payments", json={"provider": "INSTALMENTS", "idempotency_key": uuid.uuid4().hex})
        assert again.json()["error"]["code"] == "PAYMENT_IN_PROGRESS"
        page = client().get(f"/api/payments/test/{uid}").json()
        assert page["kind"] == "INSTALLMENT" and page["booking_ref"] == ref
        done = client().post(f"/api/payments/test/{uid}", json={"approve": True})
        assert done.status_code == 200 and done.json()["status"] == "SUCCESS", done.text
        assert done.json()["return_to"].startswith(f"/booking/{ref}")
        detail = pax.get(f"/api/bookings/{ref}").json()
        assert detail["booking"]["status"] == "CONFIRMED" and detail["tickets"][0]["status"] == "ISSUED"
        assert pax.get("/api/wallet").json()["balance"] == wallet          # the provider's money went straight to the booking
        # cancelled online, the refund goes to the wallet, and finance can send it back to the provider
        assert pax.post(f"/api/bookings/{ref}/cancel").status_code == 200
    finally:
        switch(admin, "INSTALLMENT", False)
        provider(admin, "INSTALMENTS", "INACTIVE")


def test_financing_has_a_minimum_and_a_kind_of_trip(admin, pax, trip):
    assert provider(admin, "TRAVEL_FINANCE", "ACTIVE").status_code == 200
    m = method(admin, "FINANCING")
    try:
        assert switch(admin, "FINANCING", True).status_code == 200
        r = book(pax, trip, free_seats(pax, trip, 1), pay_with="FINANCING")
        assert r.status_code == 422 and r.json()["error"]["code"] == "PAYMENT_AMOUNT_OUT_OF_RANGE", r.text
        assert switch(admin, "FINANCING", True, min_amount=0).status_code == 200
        r = book(pax, trip, free_seats(pax, trip, 1), pay_with="FINANCING")
        assert r.status_code == 409 and r.json()["error"]["code"] == "PAYMENT_METHOD_DISABLED", r.text   # a scheduled trip, not a tour
        # approval takes time: a cutoff longer than the time left before departure refuses the reservation (set from the
        # trip itself, so the test holds at any hour of the day)
        left = (datetime.fromisoformat(trip["departs_at"]) - datetime.now(timezone.utc)).total_seconds() / 3600
        assert switch(admin, "FINANCING", True, min_amount=0,
                      config={"trip_types": ["SCHEDULED"], "cutoff_hours": min(336, math.ceil(left) + 1)}).status_code == 200
        r = book(pax, trip, free_seats(pax, trip, 1), pay_with="FINANCING")
        assert r.status_code == 409 and r.json()["error"]["code"] == "TOO_LATE_TO_RESERVE", r.text
        assert switch(admin, "FINANCING", True, min_amount=0, config={"cutoff_hours": 1}).status_code == 200
        r = book(pax, trip, free_seats(pax, trip, 1), pay_with="FINANCING")
        assert r.status_code == 201 and r.json()["status"] == "PENDING_PAYMENT", r.text
        assert pax.post(f"/api/bookings/{r.json()['booking_ref']}/cancel").status_code == 200
    finally:
        switch(admin, "FINANCING", False, min_amount=m["min_amount"],
               config={"trip_types": m["config"]["trip_types"], "cutoff_hours": m["config"]["cutoff_hours"]})
        provider(admin, "TRAVEL_FINANCE", "INACTIVE")


def test_remittance_needs_a_second_person(admin, finance, counter, company, trip):
    if owed(counter) == 0:
        assert counter_sell(counter, trip).status_code == 201
    due = owed(counter)
    r = admin.post("/api/admin/cash/remittances", json={"company_id": company, "amount": due + 100, "method": "BANK_DEPOSIT"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "REMITTANCE_TOO_LARGE"
    part = due // 2
    r = admin.post("/api/admin/cash/remittances", json={"company_id": company, "amount": part, "method": "BANK_DEPOSIT", "ref": "DEP-1"})
    assert r.status_code == 201, r.text
    rid = r.json()["id"]
    mine = admin.post(f"/api/admin/cash/remittances/{rid}/decide", json={"approve": True})
    assert mine.status_code == 403 and mine.json()["error"]["code"] == "FOUR_EYES"
    ok = finance.post(f"/api/admin/cash/remittances/{rid}/decide", json={"approve": True})
    assert ok.status_code == 200 and ok.json()["status"] == "CONFIRMED", ok.text
    assert owed(counter) == due - part
    assert finance.post(f"/api/admin/cash/remittances/{rid}/decide", json={"approve": False}).status_code == 409
    listed = finance.get("/api/admin/cash/remittances", params={"status": "CONFIRMED"}).json()["remittances"]
    assert any(x["id"] == rid and x["mine"] is False for x in listed)


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to move the trip into the past")
def test_trip_completion_sets_earnings_off_against_cash(admin, finance, counter, company, trip):
    if owed(counter) == 0:
        assert counter_sell(counter, trip).status_code == 201
    due = owed(counter)
    owner_sql("""UPDATE ops.trip SET departure_at = now() - make_interval(days => d, hours => 6),
                                     arrival_at = now() - make_interval(days => d, hours => 1)
                   FROM (SELECT count(*)::int AS d FROM ops.trip WHERE departure_at < now() - interval '2 hours') past
                 WHERE uid = $1""", uuid.UUID(trip["uid"]))
    o = login("owner@carrier.test", "OPERATOR")
    r = o.post(f"/api/carrier/trips/{trip['uid']}/complete")
    assert r.status_code == 200, r.text
    set_off = r.json()["cash_set_off"]
    assert set_off > 0 and owed(counter) == due - set_off
    # what is still owed is remitted, so the next tests start from a clean position
    rest = owed(counter)
    if rest:
        rid = admin.post("/api/admin/cash/remittances", json={"company_id": company, "amount": rest, "method": "CASH_OFFICE"}).json()["id"]
        assert finance.post(f"/api/admin/cash/remittances/{rid}/decide", json={"approve": True}).status_code == 200
    assert owed(counter) == 0
    unbalanced = owner_sql("""SELECT count(*) FROM fin.ledger_txn t WHERE (SELECT sum(CASE direction WHEN 'DR' THEN amount ELSE -amount END)
                              FROM fin.ledger_entry e WHERE e.txn_id = t.id) <> 0""")
    assert unbalanced == 0

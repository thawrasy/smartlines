"""The gaps found by the review of the use cases (October 2026), end to end: the platform opens tracking alerts on its
own (1100); the driver and the passengers raise an SOS and the driver reports incidents from the apps (1101)."""
import uuid

import pytest

from test_e2e import (FRESH_DRIVER_PASSWORD, FRESH_DRIVERS, OWNER_URL, client, day, free_seats, login, owner_sql, publish_fresh_trip,
                      syrian)
from test_notifications import run_worker


def fresh_trip():
    """A trip of its own (vehicle, driver) for the carrier owner@carrier.test, still PUBLISHED, with no tickets."""
    publish_fresh_trip()
    return owner_sql("""SELECT t.id, t.uid, t.trip_no, t.trip_code, t.vehicle_id FROM ops.trip t JOIN iam.company_member m ON m.company_id = t.company_id
                         JOIN iam.app_user u ON u.id = m.user_id
                        WHERE u.email = 'owner@carrier.test' AND t.status = 'PUBLISHED'
                          AND NOT EXISTS (SELECT 1 FROM sales.ticket k WHERE k.trip_id = t.id)
                        ORDER BY t.id DESC LIMIT 1""", fetch=True)


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_silent_departed_trip_alerts_the_carrier():
    trip = fresh_trip()
    o = login("owner@carrier.test", "OPERATOR")
    owner_sql("""UPDATE ops.trip SET status = 'DEPARTED', departure_at = now() - interval '10 minutes',
                 arrival_at = now() + interval '3 hours' WHERE id = $1""", trip["id"])
    try:
        run_worker()
        alert = owner_sql("""SELECT kind, severity FROM ops.tracking_alert WHERE trip_id = $1 AND status = 'OPEN'""", trip["id"], fetch=True)
        assert alert and alert["kind"] == "SIGNAL_LOST" and alert["severity"] == "MEDIUM"
        board = o.get("/api/carrier/dashboard").json()
        assert any(a["kind"] == "TRACKING_SIGNAL_LOST" and a["subject"] == trip["trip_no"] for a in board["alerts"])
        run_worker()                    # the next pass sends the notice and does not open a second alert
        assert owner_sql("SELECT count(*) FROM ops.tracking_alert WHERE trip_id = $1", trip["id"]) == 1
        told = o.get("/api/notifications").json()["notifications"]
        assert any(n["template_code"] == "tracking.signal_lost" and n["payload"].get("trip_no") == trip["trip_no"] for n in told)
    finally:
        owner_sql("UPDATE ops.tracking_alert SET status = 'RESOLVED', resolved_at = now() WHERE trip_id = $1 AND status = 'OPEN'", trip["id"])
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_sos_and_incident_from_the_apps():
    trip = fresh_trip()
    driver = login(FRESH_DRIVERS[-1], "DRIVER", FRESH_DRIVER_PASSWORD)
    pax = login("passenger@masslak.test", "PASSENGER")
    # the passenger books a seat while the trip is on sale
    found = pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
    t = next(x for x in found if x["uid"] == str(trip["uid"]))
    seat = free_seats(pax, t, 1)[0]
    h = pax.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]})
    assert h.status_code == 201, h.text
    r = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"],
                                        "to_seq": t["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    ticket = pax.get(f"/api/bookings/{r.json()['booking_ref']}").json()["tickets"][0]["uid"]
    # two days before departure the trip is not under way: no SOS yet
    r = pax.post(f"/api/tickets/{ticket}/sos", json={})
    assert r.status_code == 409 and r.json()["error"]["code"] == "SOS_TRIP_NOT_ACTIVE"
    owner_sql("""UPDATE ops.trip SET status = 'DEPARTED', departure_at = now() - interval '1 hour', arrival_at = now() + interval '3 hours'
                  WHERE id = $1""", trip["id"])
    try:
        r = pax.post(f"/api/tickets/{ticket}/sos", json={"lat": 34.73, "lng": 36.71})
        assert r.status_code == 201 and r.json()["role"] == "PASSENGER" and not r.json()["repeated"], r.text
        pax_sos = r.json()["sos_id"]
        again = pax.post(f"/api/tickets/{ticket}/sos", json={})
        assert again.json()["repeated"] and again.json()["sos_id"] == r.json()["sos_id"]
        other = login("owner@carrier.test", "OPERATOR")
        assert other.post(f"/api/tickets/{ticket}/sos", json={}).status_code == 403          # not a passenger session
        r = driver.post("/api/driver/sos", json={"trip_uid": str(trip["uid"])})
        assert r.status_code == 201 and r.json()["role"] == "DRIVER", r.text
        driver_sos = r.json()["sos_id"]
        r = driver.post("/api/driver/incidents", json={"trip_uid": str(trip["uid"]), "type": "COLLISION", "severity": "SEVERE",
                                                       "injuries": True, "description": "Rear-ended at the toll gate"})
        assert r.status_code == 201, r.text
        assert r.json()["sos_id"] == driver_sos and r.json()["vehicle_out_of_service"]
        incident = r.json()["incident_id"]
        # the carrier sees the incident and the alarms, and reviews the incident
        o = login("owner@carrier.test", "OPERATOR")
        rows = o.get("/api/r/incident", params={"f_status": "OPEN"}).json()["rows"]
        mine = next(x for x in rows if str(x["_key"]) == str(incident))
        assert mine["severity"] == "SEVERE" and mine["reported_via"] == "DRIVER_APP"
        assert o.post(f"/api/r/incident/{incident}/do/review").status_code == 200
        alarms = o.get("/api/r/sos-event", params={"f_status": "OPEN"}).json()["rows"]
        assert {str(driver_sos), str(pax_sos)} <= {str(a["_key"]) for a in alarms}
        assert o.post(f"/api/r/sos-event/{driver_sos}/do/acknowledge").status_code == 200
        # the owners and the platform's security staff are told
        run_worker()
        told = o.get("/api/notifications").json()["notifications"]
        assert any(n["template_code"] == "sos.raised" and n["payload"]["trip_no"] == trip["trip_no"] for n in told)
        assert any(n["template_code"] == "incident.reported" and n["payload"]["trip_no"] == trip["trip_no"] for n in told)
        assert owner_sql("""SELECT count(*) FROM crm.notification n JOIN iam.app_user u ON u.id = n.user_id
                             WHERE u.email = 'security@masslak.test' AND n.template_code = 'sos.raised'
                               AND n.payload ->> 'trip_no' = $1""", trip["trip_no"]) >= 1
        # the vehicle is out of service: it cannot take another trip until released
        assert owner_sql("""SELECT count(*) FROM fleet.vehicle_service_status WHERE vehicle_id = $1 AND status = 'OUT_OF_SERVICE'
                             AND period @> now()""", trip["vehicle_id"]) == 1
        # someone who is not on the trip cannot raise an SOS on it
        stranger_ticket = owner_sql("""SELECT k.uid FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                                        JOIN iam.app_user u ON u.party_id = b.booker_party_id
                                       WHERE u.email <> 'passenger@masslak.test' AND k.trip_id = $1 LIMIT 1""", trip["id"])
        assert stranger_ticket is None or pax.post(f"/api/tickets/{stranger_ticket}/sos", json={}).status_code == 404
    finally:
        owner_sql("UPDATE sec.sos_event SET status = 'CLOSED' WHERE trip_id = $1", trip["id"])
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_carrier_cancels_a_trip_with_full_refunds():
    trip = fresh_trip()
    admin = login("admin@masslak.test", "PLATFORM")
    owner = login("owner@carrier.test", "OPERATOR")
    counter = login("counter@carrier.test", "OPERATOR")
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    company = owner_sql("SELECT company_id FROM ops.trip WHERE id = $1", trip["id"])
    assert admin.put(f"/api/admin/cash/limits/{company}", json={"limit_amount": 10_000_000_000, "reason": "test run"}).status_code == 200
    t = next(x for x in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
             if x["uid"] == str(trip["uid"]))
    wallet_before = pax.get("/api/wallet").json()["balance"]
    owed_before = counter.get("/api/carrier/counter/dashboard").json()["owed"]

    def sell(c, base, **extra):
        seat = free_seats(c, t, 1)[0]
        h = c.post(f"{base}/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]})
        assert h.status_code == 201, h.text
        r = c.post(f"{base}/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"],
                                             "to_seq": t["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex, **extra})
        assert r.status_code == 201, r.text
        return r.json()

    online = sell(pax, "/api")
    cash = sell(counter, "/api/carrier/counter", contact_mobile="+963944000333")
    assert pax.get("/api/wallet").json()["balance"] == wallet_before - online["total"]
    # a reason is required, and the counter clerk may not cancel trips
    assert owner.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "x"}).status_code == 422
    assert counter.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "Vehicle failed inspection"}).status_code == 403
    r = owner.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "Vehicle failed inspection"})
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["bookings_refunded"] == 2 and out["refund_total"] == online["total"] + cash["total"]
    # everything paid comes back to where it came from: the wallet in full (fee included), the counter's cash account
    assert pax.get("/api/wallet").json()["balance"] == wallet_before
    assert counter.get("/api/carrier/counter/dashboard").json()["owed"] == owed_before
    assert pax.get(f"/api/bookings/{online['booking_ref']}").json()["booking"]["status"] == "CANCELLED"
    assert owner_sql("""SELECT count(*) FROM fin.price_allocation_line l JOIN sales.booking b ON b.price_allocation_id = l.allocation_id
                         WHERE b.trip_id = $1 AND l.status <> 'REFUNDED'""", trip["id"]) == 0
    assert owner_sql("SELECT status FROM ops.trip WHERE id = $1", trip["id"]) == "CANCELLED"
    assert owner_sql("SELECT reason FROM ops.trip_disruption WHERE trip_id = $1 AND decision = 'CANCEL'", trip["id"]) == "Vehicle failed inspection"
    assert owner_sql("SELECT count(*) FROM ops.crew_assignment WHERE trip_id = $1 AND status <> 'RELEASED'", trip["id"]) == 0
    again = owner.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "Vehicle failed inspection"})
    assert again.status_code == 409 and again.json()["error"]["code"] == "TRIP_NOT_CANCELLABLE"
    # the travellers are told: in the app for the passenger, by text for the counter's customer
    run_worker()
    told = pax.get("/api/notifications").json()["notifications"]
    n = next(x for x in told if x["template_code"] == "booking.cancelled_by_carrier" and x["payload"]["booking_ref"] == online["booking_ref"])
    assert n["payload"]["refund_to"] == "WALLET" and n["payload"]["refund_amount"] == online["total"]
    assert owner_sql("""SELECT payload ->> 'refund_to' FROM sys.outbox_event WHERE event_type = 'booking.cancelled_by_carrier'
                         AND payload ->> 'booking_ref' = $1""", cash["booking_ref"]) == "COUNTER"


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_points_earned_after_the_trip_and_redeemed_to_the_wallet():
    program = owner_sql("SELECT id, point_value FROM pricing.loyalty_program WHERE status = 'ACTIVE' AND currency = 'SYP' ORDER BY id LIMIT 1",
                        fetch=True)
    rules = [owner_sql("""INSERT INTO pricing.loyalty_rule (program_id, kind, formula, valid)
                          VALUES ($1, $2, $3::jsonb, tstzrange(now() - interval '1 hour', NULL)) RETURNING id""",
                       program["id"], kind, formula)
             for kind, formula in (("EARN", '{"per_amount": 100000, "points": 1}'), ("BURN", '{"min_points": 10, "step": 10}'))]
    try:
        trip = fresh_trip()
        pax = login("passenger@masslak.test", "PASSENGER")
        assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
        before = (pax.get("/api/loyalty").json().get("account") or {}).get("balance", 0)
        t = next(x for x in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
                 if x["uid"] == str(trip["uid"]))
        seat = free_seats(pax, t, 1)[0]
        h = pax.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]})
        r = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"],
                                            "to_seq": t["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 201, r.text
        ref = r.json()["booking_ref"]
        fares = owner_sql("""SELECT sum(k.total_amount) FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                              WHERE b.booking_ref = $1""", ref)
        # the trip runs: the passenger boards, the carrier completes it
        owner_sql("""UPDATE ops.trip SET status = 'DEPARTED', departure_at = now() - interval '4 hours', arrival_at = now() - interval '1 hour'
                      WHERE id = $1""", trip["id"])
        owner_sql("""UPDATE sales.ticket SET status = 'BOARDED', boarded_at = now() - interval '4 hours'
                      WHERE booking_id = (SELECT id FROM sales.booking WHERE booking_ref = $1)""", ref)
        done = login("owner@carrier.test", "OPERATOR").post(f"/api/carrier/trips/{trip['uid']}/complete")
        assert done.status_code == 200, done.text
        earned = fares // 100000
        assert done.json()["points_earned"] >= earned > 0
        view = pax.get("/api/loyalty").json()
        assert view["account"]["balance"] == before + earned and view["program"]["redeem"] == {"min_points": 10, "step": 10}
        assert view["account"]["value"] == view["account"]["balance"] * program["point_value"]
        # the member turns points into wallet credit; the same request twice is taken once
        wallet = pax.get("/api/wallet").json()["balance"]
        bad = pax.post("/api/loyalty/redeem", json={"points": 15, "idempotency_key": uuid.uuid4().hex})
        assert bad.status_code == 409 and bad.json()["error"]["code"] == "POINTS_BAD_AMOUNT"
        key = uuid.uuid4().hex
        r = pax.post("/api/loyalty/redeem", json={"points": 10, "idempotency_key": key})
        assert r.status_code == 200 and r.json()["value"] == 10 * program["point_value"], r.text
        assert pax.post("/api/loyalty/redeem", json={"points": 10, "idempotency_key": key}).json()["replayed"]
        assert pax.get("/api/wallet").json()["balance"] == wallet + 10 * program["point_value"]
        assert pax.get("/api/loyalty").json()["account"]["balance"] == before + earned - 10
        assert owner_sql("""SELECT w.wallet_type FROM fin.ledger_txn x JOIN fin.ledger_entry e ON e.txn_id = x.id JOIN fin.wallet w ON w.id = e.wallet_id
                             WHERE x.txn_type = 'LOYALTY_REDEEM' AND e.direction = 'DR' ORDER BY x.id DESC LIMIT 1""") == "EXPENSE"
        run_worker()
        told = pax.get("/api/notifications").json()["notifications"]
        assert any(n["template_code"] == "points.earned" and n["payload"]["trip_no"] == trip["trip_no"] for n in told)
    finally:
        owner_sql("UPDATE pricing.loyalty_rule SET active = false WHERE id = ANY($1::bigint[])", rules)


def _seller_unit(party_sql: str, name: str, tax_no: str, prefix: str) -> int:
    """A tax profile valid now and an active issuing unit for the party (the carrier or the platform)."""
    authority = owner_sql("""INSERT INTO acct.tax_authority (code, country_code, name) VALUES ('SY-GCTF-T', 'SY', 'Taxes (test)')
                             ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name RETURNING id""")
    party = owner_sql(party_sql)
    profile = owner_sql("SELECT id FROM acct.tax_profile WHERE party_id = $1 AND valid @> now()", party) or owner_sql(
        """INSERT INTO acct.tax_profile (party_id, authority_id, tax_status, tax_no, legal_name)
           VALUES ($1, $2, 'REGISTERED', $3, $4) RETURNING id""", party, authority, tax_no, name)
    return owner_sql("SELECT id FROM acct.einvoice_unit WHERE profile_id = $1 AND status = 'ACTIVE'", profile) or owner_sql(
        """INSERT INTO acct.einvoice_unit (profile_id, authority_id, unit_code, number_prefix) VALUES ($1, $2, $3, $4) RETURNING id""",
        profile, authority, f"{prefix}{uuid.uuid4().hex[:6]}", prefix)


def _tax_schemes() -> dict:
    """VAT 10 % on tickets and booking fees, and a 2 % levy on the VAT for another authority, approved by a second officer."""
    tag = uuid.uuid4().hex[:5].upper()
    j = owner_sql("INSERT INTO pricing.jurisdiction (country_code, level, name) VALUES ('SY', 'COUNTRY', $1) RETURNING id", f"Syria {tag}")
    maker = owner_sql("SELECT id FROM iam.app_user WHERE email = 'admin@masslak.test'")
    checker = owner_sql("SELECT id FROM iam.app_user WHERE email = 'finance@masslak.test'")
    authority = owner_sql("INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY', $1) RETURNING id", f"Reconstruction fund {tag}")
    ids = []
    for code, kind, payable, rate, base_type, include in ((f"VAT{tag}", "VAT", None, 10, "FARE", "[]"),
                                                           (f"REC{tag}", "LEVY", authority, 2, "TAXES", f'["VAT{tag}"]')):
        sid = owner_sql("""INSERT INTO pricing.tax_scheme (code, name, jurisdiction_id, tax_type, treatment, scope, collected_by,
                                                           payable_to_party_id, valid, created_by)
                           VALUES ($1, $1, $2, $3, 'STANDARD', '{"products": ["TICKET", "BOOKING_FEE"]}', 'PLATFORM', $4,
                                   tstzrange(now() - interval '1 day', NULL), $5) RETURNING id""", code, j, kind, payable, maker)
        owner_sql("""INSERT INTO pricing.tax_rule (scheme_id, seq, calc_method, rate, base_type, base_include)
                     VALUES ($1, 1, 'PERCENT', $2, $3, $4::jsonb)""", sid, rate, base_type, include)
        ids.append(sid)
    for sid in ids:
        owner_sql("UPDATE pricing.tax_scheme SET status = 'ACTIVE', approved_by = $2 WHERE id = $1", sid, checker)
    return {"ids": ids, "vat_code": f"VAT{tag}", "levy_code": f"REC{tag}"}


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_paid_booking_gets_signed_einvoices_and_a_refund_a_credit_note():
    import base64
    from app.modules.einvoice.service import read_qr
    trip = fresh_trip()
    carrier_unit = _seller_unit(f"SELECT company_id FROM ops.trip WHERE id = {trip['id']}", "Demo Carrier", "0101234567", "CAR-")
    platform_unit = _seller_unit("SELECT id FROM iam.party WHERE legal_name = 'Masslak Platform' AND party_type = 'COMPANY'",
                                 "Masslak Platform", "0109999999", "MSL-")
    # the platform's taxes (1108): VAT 10 % on tickets and fees, and a 2 % levy on the VAT owed to another authority
    schemes = _tax_schemes()
    try:
        pax = login("passenger@masslak.test", "PASSENGER")
        assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
        t = next(x for x in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
                 if x["uid"] == str(trip["uid"]))
        seat = free_seats(pax, t, 1)[0]
        h = pax.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]})
        r = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"],
                                            "to_seq": t["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 201, r.text
        ref, total = r.json()["booking_ref"], r.json()["total"]
        run_worker()
        detail = pax.get(f"/api/bookings/{ref}").json()
        invoices = [i for i in detail["invoices"] if i["doc_type"] == "INVOICE"]
        assert len(invoices) == 2 and sum(i["total"] for i in invoices) == total          # the tickets and the fee
        assert {i["number"][:4] for i in invoices} == {"CAR-", "MSL-"}
        run_worker()                                                                        # issued once only
        assert len(pax.get(f"/api/bookings/{ref}").json()["invoices"]) == 2
        for inv in invoices:
            v = client().get(f"/api/verify/einvoice/{inv['uuid']}").json()
            assert v["valid"] and v["hash_valid"] and v["signature_valid"] and v["qr_matches"] and v["chain_valid"], v
            assert v["number"] == inv["number"] and v["kid"] and v["public_key"]
            by = {x["tax"]: x for x in v["taxes"]}
            assert set(by) == {schemes["vat_code"], schemes["levy_code"]}, v["taxes"]
            vat, levy = by[schemes["vat_code"]], by[schemes["levy_code"]]
            assert abs(vat["amount"] - vat["base"] // 10) <= len(v["taxes"]) and levy["base"] == vat["amount"]
            assert abs(levy["amount"] - vat["amount"] * 2 / 100) <= 1 and v["tax_total"] == vat["amount"] + levy["amount"]
            assert owner_sql("SELECT sum(net_amount) + sum(tax_amount) FROM acct.einvoice_line l JOIN acct.einvoice_document d ON d.id = l.document_id WHERE d.uuid = $1::uuid",
                             inv["uuid"]) == v["total"]
        keys = client().get("/api/public/keys/einvoice").json()
        assert any(k["kid"] == v["kid"] and k["public_key"] == v["public_key"] for k in keys["keys"])
        qr = read_qr(owner_sql("SELECT qr_payload FROM acct.einvoice_document WHERE uuid = $1::uuid", invoices[0]["uuid"]))
        assert qr[6] == owner_sql("SELECT hash FROM acct.einvoice_document WHERE uuid = $1::uuid", invoices[0]["uuid"])
        assert base64.b64decode(qr[7]) and qr[1] in ("Demo Carrier", "Masslak Platform")
        assert client().get(f"/api/verify/einvoice/{uuid.uuid4()}").json() == {"valid": False, "reason": "NOT_FOUND"}
        # the passenger cancels: what is refunded of the fare comes back as a credit note against the carrier's invoice
        c = pax.post(f"/api/bookings/{ref}/cancel")
        assert c.status_code == 200, c.text
        refund = c.json()["refund"]
        run_worker()
        notes = [i for i in pax.get(f"/api/bookings/{ref}").json()["invoices"] if i["doc_type"] == "CREDIT_NOTE"]
        if refund:
            assert len(notes) == 1 and notes[0]["total"] == refund and notes[0]["number"].startswith("CAR-")
            v = client().get(f"/api/verify/einvoice/{notes[0]['uuid']}").json()
            assert v["valid"] and v["original_number"].startswith("CAR-")
            assert {x["tax"] for x in v["taxes"]} == {schemes["vat_code"], schemes["levy_code"]}
        else:
            assert notes == []
        assert owner_sql("SELECT acct.einvoice_chain_breaks($1) + acct.einvoice_chain_breaks($2)", carrier_unit, platform_unit) == 0
    finally:
        owner_sql("UPDATE pricing.tax_scheme SET status = 'RETIRED' WHERE id = ANY($1::bigint[])", schemes["ids"])
        owner_sql("UPDATE acct.einvoice_unit SET status = 'SUSPENDED' WHERE id = ANY($1::bigint[])", [carrier_unit, platform_unit])


def _book_on(pax, trip):
    t = next(x for x in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
             if x["uid"] == str(trip["uid"]))
    seat = free_seats(pax, t, 1)[0]
    h = pax.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]})
    r = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"],
                                        "to_seq": t["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    return r.json()


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_cancellation_penalty_only_when_the_regulators_impose_one():
    admin = login("admin@masslak.test", "PLATFORM")
    owner = login("owner@carrier.test", "OPERATOR")
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    assert admin.get("/api/admin/trips/cancel-penalty").json() == {"enabled": False}
    bad = admin.put("/api/admin/trips/cancel-penalty", json={"enabled": True, "basis": "PER_TICKET", "value": 100, "payee": "PLATFORM"})
    assert bad.status_code == 409 and bad.json()["error"]["code"] == "INVALID_SETTING"          # no regulator's decision
    assert owner.put("/api/admin/trips/cancel-penalty", json={"enabled": False}).status_code == 403
    rule = {"enabled": True, "basis": "PER_TICKET", "value": 100, "payee": "PASSENGERS", "legal_ref": "Regulator decision 7/2026"}
    assert admin.put("/api/admin/trips/cancel-penalty", json=rule).status_code == 200
    try:
        trip = fresh_trip()
        booked = _book_on(pax, trip)
        wallet = pax.get("/api/wallet").json()["balance"]
        r = owner.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "Road closed by the authorities"})
        assert r.status_code == 200, r.text
        out = r.json()
        # the passenger gets the whole payment back, and the penalty is the regulators' on top, charged to the carrier
        assert out["refund_total"] == booked["total"] and out["penalty"]["amount"] == 100
        assert out["penalty"]["legal_ref"] == "Regulator decision 7/2026"
        if out["penalty"]["status"] == "DUE":
            # the carrier's balance did not cover it: the next completed trip sets it off from the released earnings
            assert pax.get("/api/wallet").json()["balance"] == wallet + booked["total"]
            nxt = fresh_trip()
            sold = _book_on(pax, nxt)
            owner_sql("""UPDATE ops.trip SET status = 'DEPARTED', departure_at = now() - interval '4 hours', arrival_at = now() - interval '1 hour'
                          WHERE id = $1""", nxt["id"])
            done = owner.post(f"/api/carrier/trips/{nxt['uid']}/complete")
            assert done.status_code == 200 and done.json()["penalties_collected"] >= 100, done.text
            assert sold["total"] > 0
        assert owner_sql("SELECT status FROM ops.trip_cancel_penalty WHERE trip_id = $1", trip["id"]) == "COLLECTED"
        # the passengers' share reached the wallet that paid the booking, from the carrier's balance
        moved = owner_sql("""SELECT string_agg(w.wallet_type || ':' || e.direction || ':' || e.amount, ',' ORDER BY e.direction, w.wallet_type)
                               FROM ops.trip_cancel_penalty p JOIN fin.ledger_txn x ON x.idempotency_key = 'penalty:' || p.id
                               JOIN fin.ledger_entry e ON e.txn_id = x.id JOIN fin.wallet w ON w.id = e.wallet_id WHERE p.trip_id = $1""", trip["id"])
        assert moved == "USER:CR:100,COMPANY:DR:100", moved
        listed = owner.get("/api/r/trip-cancel-penalty").json()["rows"]
        assert any(x["legal_ref"] == "Regulator decision 7/2026" for x in listed)
    finally:
        admin.put("/api/admin/trips/cancel-penalty", json={"enabled": False})

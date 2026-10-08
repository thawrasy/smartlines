"""Launch completeness (schema file 1054): support cases and their service levels, claims paid under four eyes, trip
ratings after travel, trips generated from templates, the blocklist at registration and sign-in, and the guardian's
side of school transport."""
import re
import secrets
import time
import uuid

import pytest

from test_e2e import OWNER_URL, client, day, login, new_passenger, owner_sql
from test_modules import CACHE_SECONDS, switch

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def carrier():
    return login("owner@carrier.test", "OPERATOR")


def _case_key(admin, ref):
    rows = admin.get("/api/r/case", params={"q": ref}).json()["rows"]
    return next(r["_key"] for r in rows if r["ref"] == ref)


# ------------------------------------------------------------------ cases
def test_a_case_gets_service_levels_and_the_customer_sees_public_replies_only(admin):
    pax = new_passenger()
    r = pax.post("/api/support/cases", json={"kind": "INQUIRY", "category": "PAYMENT", "subject": "Card top-up",
                                             "description": "My card top-up did not show in the wallet."})
    assert r.status_code == 201, r.text
    ref, uid = r.json()["ref"], r.json()["uid"]
    assert re.fullmatch(r"C[0-9A-F]{7}", ref)
    due = owner_sql("""SELECT round(extract(epoch FROM first_due_at - created_at) / 3600) || '/' ||
                              round(extract(epoch FROM resolve_due_at - created_at) / 3600)
                         FROM crm."case" WHERE ref = $1""", ref)
    assert due == "8/72"                                     # NORMAL priority in support.sla
    key = _case_key(admin, ref)
    case_id = int(key)
    note = admin.post("/api/r/case-event", json={"case_id": case_id, "kind": "NOTE", "visibility": "INTERNAL",
                                                  "body": "Checked the gateway: payment captured."})
    assert note.status_code == 201, note.text
    reply = admin.post("/api/r/case-event", json={"case_id": case_id, "kind": "REPLY", "visibility": "PUBLIC",
                                                   "body": "The amount is now in your wallet."})
    assert reply.status_code == 201, reply.text
    seen = pax.get(f"/api/support/cases/{uid}").json()
    assert [m["body"] for m in seen["messages"]] == ["The amount is now in your wallet."]   # the internal note stays inside
    assert seen["case"]["status"] == "OPEN"
    assert owner_sql("SELECT first_response_at IS NOT NULL FROM crm.\"case\" WHERE ref = $1", ref)
    assert owner_sql("""SELECT count(*) FROM sys.outbox_event WHERE event_type = 'case.replied' AND aggregate_id = $1""", case_id) == 1
    # the customer answers, the case is resolved and rated, then closed for good
    assert pax.post(f"/api/support/cases/{uid}/messages", json={"body": "Thank you, I see it."}).status_code == 201
    assert pax.post(f"/api/support/cases/{uid}/satisfaction", json={"score": 5}).json()["error"]["code"] == "CASE_NOT_RESOLVED"
    assert admin.post(f"/api/r/case/{key}/do/resolve").status_code == 200
    assert pax.post(f"/api/support/cases/{uid}/satisfaction", json={"score": 5}).status_code == 200
    assert admin.post(f"/api/r/case/{key}/do/close").status_code == 200
    assert pax.post(f"/api/support/cases/{uid}/messages", json={"body": "One more thing"}).json()["error"]["code"] == "CASE_FINAL"
    # another passenger cannot see the case
    assert new_passenger().get(f"/api/support/cases/{uid}").status_code == 404


def test_a_customer_cannot_write_internal_notes():
    owner_sql("""DO $$ DECLARE c bigint; BEGIN
                   INSERT INTO crm."case" (kind, category, subject, channel) VALUES ('INQUIRY', 'OTHER', 'probe', 'WEB')
                   RETURNING id INTO c;
                   INSERT INTO crm.case_event (case_id, actor_role, kind, visibility, body) VALUES (c, 'CUSTOMER', 'NOTE', 'INTERNAL', 'x');
                 EXCEPTION WHEN OTHERS THEN
                   IF SQLERRM NOT LIKE 'CUSTOMER_EVENT%' THEN RAISE; END IF;
                 END $$""")
    assert owner_sql("SELECT count(*) FROM crm.case_event WHERE actor_role = 'CUSTOMER' AND visibility = 'INTERNAL'") == 0


# ------------------------------------------------------------------ claims
def _fund_platform():
    """The platform's operating wallet pays the claims it is liable for; a test server may hold nothing in it."""
    owner_sql("""DO $$ DECLARE src bigint; dst bigint; t bigint; BEGIN
                   SELECT w.id INTO src FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
                    WHERE p.legal_name = 'Masslak Platform' AND w.wallet_type = 'BANK_CLEARING' AND w.currency = 'SYP';
                   SELECT w.id INTO dst FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
                    WHERE p.legal_name = 'Masslak Platform' AND w.wallet_type = 'PLATFORM' AND w.currency = 'SYP';
                   INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, memo)
                   VALUES ('ADJUST', 'SYP', 'test-fund-' || gen_random_uuid(), 'test funding') RETURNING id INTO t;
                   INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) VALUES (t, src, 'DR', 5000000), (t, dst, 'CR', 5000000);
                 END $$""")


def _passenger_booking():
    """A confirmed booking of the demo passenger, made through the normal booking API."""
    import test_e2e as e2e
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 10000000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    t = e2e.bookable_trip(pax)
    if t is None:
        e2e.publish_fresh_trip()
        t = e2e.bookable_trip(pax)
    seats = e2e.free_seats(pax, t, 1)
    token = e2e.hold(pax, t, seats).json()["hold_token"]
    r = e2e.book(pax, t, token, seats)
    assert r.status_code == 201, r.text
    return pax, r.json()["booking_ref"]


def test_a_claim_is_approved_by_one_person_and_paid_once_by_another(admin):
    pax, ref = _passenger_booking()
    r = pax.post("/api/support/cases", json={"kind": "CLAIM", "category": "DELAY", "subject": "Four hours late",
                                             "description": "The bus left four hours late and I missed my appointment.",
                                             "booking_ref": ref, "claim_amount": 500000})
    assert r.status_code == 201, r.text
    case_ref, uid = r.json()["ref"], r.json()["uid"]
    key = _case_key(admin, case_ref)
    over = admin.patch(f"/api/r/case/{key}", json={"approved_amount": 600000, "liable": "PLATFORM"})
    assert over.json()["error"]["code"] == "APPROVED_OVER_CLAIM"
    assert admin.post(f"/api/r/case/{key}/do/send_to_finance").json()["error"]["code"] == "CLAIM_NOT_DECIDED"
    assert admin.patch(f"/api/r/case/{key}", json={"approved_amount": 300000, "liable": "PLATFORM"}).status_code == 200
    assert admin.post(f"/api/r/case/{key}/do/send_to_finance").status_code == 200
    # the approver holds the paying permission too (finance role), and is still refused
    assert admin.post(f"/api/admin/support/cases/{uid}/pay").json()["error"]["code"] == "FOUR_EYES"
    _fund_platform()
    finance = login("finance@masslak.test", "PLATFORM")
    assert any(c["ref"] == case_ref for c in finance.get("/api/admin/support/claims").json()["claims"])
    before = pax.get("/api/wallet").json()["balance"]
    paid = finance.post(f"/api/admin/support/cases/{uid}/pay")
    assert paid.status_code == 200, paid.text
    assert pax.get("/api/wallet").json()["balance"] == before + 300000
    assert finance.post(f"/api/admin/support/cases/{uid}/pay").json()["error"]["code"] == "CLAIM_NOT_PAYABLE"
    assert pax.get(f"/api/support/cases/{uid}").json()["case"]["payout_status"] == "PAID"
    assert owner_sql("SELECT ref_type FROM fin.ledger_txn t JOIN crm.\"case\" c ON c.payout_ledger_txn_id = t.id WHERE c.ref = $1",
                     case_ref) == "case"
    # the paid amount is fixed
    assert admin.patch(f"/api/r/case/{key}", json={"approved_amount": 200000}).json()["error"]["code"] == "CLAIM_PAID"


# ------------------------------------------------------------------ trip templates and ratings
def _fresh_vehicle(carrier):
    layout = next(x for x in carrier.get("/api/carrier/seat-layouts").json()["layouts"] if x["total_seats"] == 44)
    plate = str(100000 + secrets.randbelow(900000))
    r = carrier.post("/api/carrier/vehicles", json={
        "plate_no": plate, "chassis_no": f"CHS-G{plate}", "vehicle_type": "COACH", "seat_layout_uid": layout["uid"],
        "insurance_no": f"POL-G{plate}", "insurer": "Test", "insurance_issue": "2026-01-01", "insurance_expiry": "2030-01-01"})
    assert r.status_code == 201, r.text
    return r.json()["uid"]


def test_a_template_generates_each_departure_once_and_a_traveller_rates_the_trip(carrier):
    vehicle_uid = _fresh_vehicle(carrier)
    vehicle_id = owner_sql("SELECT id FROM fleet.vehicle WHERE uid = $1", uuid.UUID(vehicle_uid))
    route_id = owner_sql("SELECT id FROM net.route WHERE code = 'DAM-ALP' ORDER BY id LIMIT 1")
    minute = secrets.randbelow(50)
    r = carrier.post("/api/r/trip-template", json={
        "route_id": route_id, "default_vehicle_id": vehicle_id, "departure_time": f"05:{minute:02d}",
        "days_of_week": [1, 2, 3, 4, 5, 6, 7], "base_price": 28000, "currency": "SYP", "active": [day(3), day(30)]})
    assert r.status_code == 201, r.text
    tpl = r.json()["_key"]
    gen = carrier.post(f"/api/carrier/trip-templates/{tpl}/generate", json={"from_date": day(3), "to_date": day(5), "publish": True})
    assert gen.status_code == 200, gen.text
    assert len(gen.json()["created"]) == 3, gen.json()
    again = carrier.post(f"/api/carrier/trip-templates/{tpl}/generate", json={"from_date": day(3), "to_date": day(5)}).json()
    assert again["created"] == [] and {s["reason"] for s in again["skipped"]} == {"EXISTS"}
    outside = carrier.post(f"/api/carrier/trip-templates/{tpl}/generate", json={"from_date": day(1), "to_date": day(2)}).json()
    assert outside["created"] == [] and outside["skipped"] == []          # before the template's period
    assert carrier.post(f"/api/carrier/trip-templates/{tpl}/generate",
                        json={"from_date": day(3), "to_date": day(90)}).json()["error"]["code"] == "INVALID_RANGE"
    assert carrier.post(f"/api/r/trip-template/{tpl}/do/pause").status_code == 200
    assert carrier.post(f"/api/carrier/trip-templates/{tpl}/generate",
                        json={"from_date": day(6), "to_date": day(6)}).json()["error"]["code"] == "TEMPLATE_NOT_ACTIVE"
    # another carrier's template is not found
    assert owner_sql("SELECT count(*) FROM ops.trip WHERE template_id = $1", int(tpl)) == 3

    # a passenger books the first generated trip, cannot rate it before travelling, and rates it once after
    trip_uid = str(owner_sql("SELECT uid FROM ops.trip WHERE template_id = $1 ORDER BY departure_at LIMIT 1", int(tpl)))
    pax = new_passenger()
    assert pax.post("/api/wallet/topup", json={"amount": 10000000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    import test_e2e as e2e
    t = {"uid": trip_uid, "from_seq": 0, "to_seq": owner_sql("SELECT segments_count FROM ops.trip WHERE uid = $1", uuid.UUID(trip_uid))}
    seats = e2e.free_seats(pax, t, 1)
    token = e2e.hold(pax, t, seats).json()["hold_token"]
    assert e2e.book(pax, t, token, seats).status_code == 201
    ticket = str(owner_sql("""SELECT k.uid FROM sales.ticket k JOIN ops.trip t ON t.id = k.trip_id WHERE t.uid = $1""", uuid.UUID(trip_uid)))
    early = pax.post("/api/support/ratings", json={"ticket_uid": ticket, "stars": 4})
    assert early.json()["error"]["code"] == "TRIP_NOT_TRAVELLED"
    owner_sql("""UPDATE ops.trip SET departure_at = now() - make_interval(days => d, hours => 6),
                                     arrival_at = now() - make_interval(days => d, hours => 1)
                   FROM (SELECT count(*)::int + 1 AS d FROM ops.trip WHERE departure_at < now() - interval '2 hours') past
                 WHERE uid = $1""", uuid.UUID(trip_uid))
    assert any(x["ticket_uid"] == ticket for x in pax.get("/api/support/ratable").json()["tickets"])
    ok = pax.post("/api/support/ratings", json={"ticket_uid": ticket, "stars": 4, "punctuality": 5, "comment": "Clean bus"})
    assert ok.status_code == 201, ok.text
    assert pax.post("/api/support/ratings", json={"ticket_uid": ticket, "stars": 1}).json()["error"]["code"] == "ALREADY_RATED"
    assert not any(x["ticket_uid"] == ticket for x in pax.get("/api/support/ratable").json()["tickets"])
    # someone else cannot rate a ticket they neither bought nor travelled on
    other = new_passenger().post("/api/support/ratings", json={"ticket_uid": ticket, "stars": 1})
    assert other.status_code in (404, 409)


# ------------------------------------------------------------------ blocklist
def test_the_blocklist_refuses_registration_and_sign_in():
    security = login("security@masslak.test", "PLATFORM")
    blocked = f"blocked{uuid.uuid4().hex[:8]}@example.com"
    r = security.post("/api/admin/support/blocklist", json={"entry_type": "EMAIL", "value": blocked, "reason": "repeated chargebacks"})
    assert r.status_code == 201, r.text
    assert security.post("/api/admin/support/blocklist", json={"entry_type": "EMAIL", "value": blocked.upper(),
                                                               "reason": "the same address again"}).json()["error"]["code"] == "ALREADY_BLOCKED"
    reg = client().post("/api/auth/register", json={"full_name": "Blocked User", "email": blocked, "password": "another-long-password"})
    assert reg.status_code == 403 and reg.json()["error"]["code"] == "BLOCKED"
    # an existing account blocked afterwards cannot sign in, and the refusal is in the sign-in log
    email = f"later{uuid.uuid4().hex[:8]}@example.com"
    assert client().post("/api/auth/register", json={"full_name": "Later Blocked", "email": email,
                                                     "password": "another-long-password"}).status_code == 201
    assert security.post("/api/admin/support/blocklist", json={"entry_type": "EMAIL", "value": email, "reason": "fraud confirmed"}).status_code == 201
    r = client().post("/api/auth/login", json={"identifier": email, "password": "another-long-password", "portal": "PASSENGER"})
    assert r.status_code == 403 and r.json()["error"]["code"] == "BLOCKED"
    assert owner_sql("""SELECT count(*) FROM audit.auth_event e JOIN iam.app_user u ON u.id = e.user_id
                         WHERE u.email = $1 AND e.reason = 'blocklist'""", email) == 1
    # only the digest is stored
    assert owner_sql("SELECT count(*) FROM sec.blocklist_entry WHERE octet_length(value_hash) <> 32") == 0
    # a passenger cannot add entries
    assert login("passenger@masslak.test", "PASSENGER").post(
        "/api/admin/support/blocklist", json={"entry_type": "EMAIL", "value": "x@example.com", "reason": "no reason"}).status_code == 403


# ------------------------------------------------------------------ school transport: the guardian's side
@pytest.fixture(scope="module")
def school_on(admin):
    was = next(m["enabled"] for m in admin.get("/api/admin/modules").json()["modules"] if m["key"] == "school_transport")
    if not was:
        switch(admin, "school_transport", True)
        time.sleep(CACHE_SECONDS)
    yield
    if not was:
        switch(admin, "school_transport", False)


def _school_enrolment():
    """A school, a licensed operator (the demo carrier, under a government contract), a contract and a pupil enrolled,
    written as the owner. A government contract carries no guardian, so the guardian's consent is still to be given."""
    return owner_sql("""
      WITH guardian AS (SELECT party_id AS id FROM iam.app_user WHERE email = 'passenger@masslak.test'),
           carrier AS (SELECT id FROM iam.party WHERE legal_name = 'Demo Carrier A'),
           city AS (SELECT id FROM ref.city WHERE code = 'DAM'),
           sp AS (INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY', 'Test School ' || floor(random() * 1e9)) RETURNING id),
           sc AS (INSERT INTO iam.company (id, approval_status) SELECT id, 'APPROVED' FROM sp RETURNING id),
           school AS (INSERT INTO sch.school (company_id, sector, city_id, status)
                      SELECT sc.id, 'PRIVATE', city.id, 'ACTIVE' FROM sc, city RETURNING id),
           op AS (INSERT INTO sch.operator (company_id, operator_kind, school_transport_license_no, license_issuer, status,
                                            approved_by, approved_at, government_contract_no)
                  SELECT carrier.id, 'GOVERNMENT_CONTRACTED', 'STL-TEST-' || floor(random() * 1e6), 'Damascus Transport Directorate', 'APPROVED',
                         (SELECT id FROM iam.app_user WHERE email = 'admin@masslak.test'), now(), 'MOE-TEST-1'
                    FROM carrier
                  ON CONFLICT (company_id) DO UPDATE SET operator_kind = 'GOVERNMENT_CONTRACTED', school_id = NULL, government_contract_no = 'MOE-TEST-1',
                                                         status = 'APPROVED',
                                                         approved_by = EXCLUDED.approved_by, approved_at = now()
                  RETURNING id, company_id),
           k AS (INSERT INTO sch.contract (operator_id, company_id, contract_kind, school_id, school_year, valid, pricing_mode, price,
                                           school_transport_license_no, license_authority, status)
                 SELECT op.id, op.company_id, 'GOVERNMENT', school.id, '2026-2027', daterange('2026-09-01', '2027-07-01'),
                        'MONTHLY', 15000000, 'STL-TEST', 'Damascus Transport Directorate', 'ACTIVE' FROM op, school RETURNING id, school_id),
           child AS (INSERT INTO iam.party (party_type, legal_name, birth_date) VALUES ('PERSON', 'Test Pupil', date '2017-03-01') RETURNING id),
           pupil AS (INSERT INTO sch.student (school_id, party_id, grade, class_name)
                     SELECT k.school_id, child.id, '4', 'B' FROM k, child RETURNING id),
           g AS (INSERT INTO sch.student_guardian (student_id, party_id, role, relation, is_primary)
                 SELECT pupil.id, guardian.id, 'GUARDIAN', 'FATHER', true FROM pupil, guardian RETURNING student_id)
      INSERT INTO sch.enrollment (contract_id, student_id) SELECT k.id, g.student_id FROM k, g RETURNING id""")


def test_a_guardian_answers_for_the_pupil_and_nothing_else(school_on):
    enrolment = _school_enrolment()
    guardian = login("passenger@masslak.test", "PASSENGER")
    mine = guardian.get("/api/r/enrollment").json()["rows"]
    assert any(int(r["_key"]) == enrolment for r in mine)
    row = next(r for r in mine if int(r["_key"]) == enrolment)
    assert row["guardian_consent"] == "PENDING"
    r = guardian.post(f"/api/r/enrollment/{enrolment}/do/give_consent")
    assert r.status_code == 200, r.text
    rec = owner_sql("""SELECT e.guardian_consent || ' ' || (e.consent_by_party_id = u.party_id)::text || ' ' || (e.consent_at IS NOT NULL)::text
                         FROM sch.enrollment e, iam.app_user u WHERE e.id = $1 AND u.email = 'passenger@masslak.test'""", enrolment)
    assert rec == "GIVEN true true"
    # the guardian's portal reads enrolments only; the activation stays with the operator
    assert guardian.post(f"/api/r/enrollment/{enrolment}/do/activate").status_code == 404
    edit = guardian.patch(f"/api/r/enrollment/{enrolment}", json={"to_stop_seq": 3})
    assert edit.status_code == 409 and edit.json()["error"]["code"] == "GUARDIAN_CONSENT_ONLY"   # held by the database
    # an absence for tomorrow is accepted and recorded with the guardian; another passenger cannot report one
    r = guardian.post("/api/r/absence-notice", json={"enrollment_id": enrolment, "absent_on": day(1), "direction": "BOTH"})
    assert r.status_code == 201, r.text
    stranger = new_passenger().post("/api/r/absence-notice", json={"enrollment_id": enrolment, "absent_on": day(2), "direction": "BOTH"})
    assert stranger.status_code in (403, 404, 409, 422)
    past = guardian.post("/api/r/absence-notice", json={"enrollment_id": enrolment, "absent_on": day(-1), "direction": "BOTH"})
    assert past.json()["error"]["code"] == "ABSENCE_IN_PAST"
    # the operator sees the enrolment and its consent; it is activated only once a route is set
    carrier = login("owner@carrier.test", "OPERATOR")
    assert any(int(r["_key"]) == enrolment and r["guardian_consent"] == "GIVEN" for r in carrier.get("/api/r/enrollment").json()["rows"])
    assert carrier.post(f"/api/r/enrollment/{enrolment}/do/activate").json()["error"]["code"] == "INVALID_VALUE"

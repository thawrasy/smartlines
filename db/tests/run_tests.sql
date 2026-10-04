-- =====================================================================
-- Schema tests: run against a freshly built database (build.sh)
--   psql -d <db> -v ON_ERROR_STOP=1 -f db/tests/run_tests.sql
-- Any failure stops the run with a FAIL message
-- =====================================================================
\set QUIET on
SET client_min_messages = notice;

CREATE OR REPLACE FUNCTION pg_temp.expect_error(p_sql text, p_like text, p_name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%' || p_like || '%' THEN
      RAISE NOTICE 'PASS  %', p_name; RETURN;
    END IF;
    RAISE EXCEPTION 'FAIL  % — unexpected error: %', p_name, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL  % — expected error containing "%"', p_name, p_like;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ok(p_cond boolean, p_name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond THEN RAISE NOTICE 'PASS  %', p_name; ELSE RAISE EXCEPTION 'FAIL  %', p_name; END IF;
END $$;

-- ------------------------------ Setup (as owner) ----------------------
BEGIN;
INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY','Al-Quds Transport'), ('COMPANY','Al-Sham Lines'), ('PERSON','Test Driver'), ('PERSON','Test Passenger');
INSERT INTO iam.company (id, approval_status) SELECT id, 'APPROVED' FROM iam.party WHERE legal_name IN ('Al-Quds Transport','Al-Sham Lines');
INSERT INTO iam.app_user (party_id, account_kind, email, status, password_hash) SELECT id, 'COMPANY', 'owner@quds.test', 'ACTIVE', '$argon2id$v=19$m=65536,t=3,p=1$Zq9-PW-MARKER-7731' FROM iam.party WHERE legal_name = 'Al-Quds Transport';
INSERT INTO iam.app_user (party_id, account_kind, email, status) SELECT id, 'PLATFORM', 'admin@masslak.test', 'ACTIVE' FROM iam.party WHERE legal_name = 'Masslak Platform';
INSERT INTO iam.app_user (party_id, account_kind, email, status) SELECT id, 'PLATFORM', 'finance@masslak.test', 'ACTIVE' FROM iam.party WHERE legal_name = 'Test Driver';
INSERT INTO net.station (code, city_id, country_code, station_class, name, lat, lng, status)
SELECT 'SY-' || c.code || '-C001', c.id, 'SY', 'CENTRAL', c.name || ' Central Station', c.lat, c.lng, 'ACTIVE' FROM ref.city c WHERE c.code IN ('DAM','HMS','ALP');
INSERT INTO net.route (company_id, code, origin_station_id, dest_station_id, service_type)
SELECT (SELECT id FROM iam.party WHERE legal_name='Al-Quds Transport'), 'DAM-ALP',
       (SELECT id FROM net.station WHERE code='SY-DAM-C001'), (SELECT id FROM net.station WHERE code='SY-ALP-C001'), 'INDIRECT';
INSERT INTO fleet.vehicle (company_id, vehicle_type, plate_no, chassis_no, passenger_seats, owner_party_id, status)
SELECT id, 'COACH', '123456', 'CHS-A-1', 48, id, 'ACTIVE' FROM iam.party WHERE legal_name='Al-Quds Transport';
INSERT INTO fleet.vehicle (company_id, vehicle_type, plate_no, chassis_no, passenger_seats, owner_party_id, status)
SELECT id, 'COACH', '654321', 'CHS-B-1', 40, id, 'ACTIVE' FROM iam.party WHERE legal_name='Al-Sham Lines';
INSERT INTO fleet.crew_profile (party_id, company_id, crew_type)
SELECT (SELECT id FROM iam.party WHERE legal_name='Test Driver'), (SELECT id FROM iam.party WHERE legal_name='Al-Quds Transport'), 'DRIVER';
COMMIT;

-- Shorthand values
SELECT id AS ca FROM iam.party WHERE legal_name='Al-Quds Transport' \gset
SELECT id AS cb FROM iam.party WHERE legal_name='Al-Sham Lines' \gset
SELECT id AS driver FROM iam.party WHERE legal_name='Test Driver' \gset
SELECT id AS pax FROM iam.party WHERE legal_name='Test Passenger' \gset
SELECT id AS ua FROM iam.app_user WHERE email='owner@quds.test' \gset
SELECT id AS uadmin FROM iam.app_user WHERE email='admin@masslak.test' \gset
SELECT id AS ufin FROM iam.app_user WHERE email='finance@masslak.test' \gset
SELECT id AS va FROM fleet.vehicle WHERE chassis_no='CHS-A-1' \gset
SELECT id AS vb FROM fleet.vehicle WHERE chassis_no='CHS-B-1' \gset
SELECT id AS route FROM net.route WHERE code='DAM-ALP' \gset

-- ------------------------------ As the application role (subject to RLS) ----------
SET ROLE masslak_app;

-- 1) Tenant isolation
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM fleet.vehicle) = 1, 'RLS: carrier A sees only its own vehicles');
SELECT pg_temp.ok((SELECT count(*) FROM fleet.vehicle WHERE id = :vb) = 0, 'RLS: carrier A cannot see carrier B vehicle');
SELECT pg_temp.expect_error(format($$INSERT INTO fleet.vehicle (company_id, vehicle_type, plate_no, chassis_no, passenger_seats, owner_party_id) VALUES (%s,'COACH','X1','X1',10,%s)$$, :cb, :cb),
  'row-level security', 'RLS: carrier A cannot create a vehicle for carrier B');
COMMIT;

BEGIN;
SELECT pg_temp.ok((SELECT count(*) FROM fleet.vehicle) = 0, 'RLS: no context = no private rows visible (deny by default)');
COMMIT;

-- 2) Trips: no vehicle or crew conflicts
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
INSERT INTO ops.trip (trip_no, company_id, route_id, vehicle_id, departure_at, arrival_at, status, seats_total, segments_count, currency, base_price, service_type)
VALUES ('QDS214/03OCT26', :ca, :route, :va, '2026-10-03 06:00+00', '2026-10-03 11:00+00', 'PUBLISHED', 48, 2, 'SYP', 3500000, 'INDIRECT');
SELECT pg_temp.expect_error(format($$INSERT INTO ops.trip (trip_no, company_id, route_id, vehicle_id, departure_at, arrival_at, status, seats_total, segments_count, currency, base_price)
  VALUES ('QDS216/03OCT26', %s, %s, %s, '2026-10-03 11:10+00', '2026-10-03 14:00+00', 'PUBLISHED', 48, 1, 'SYP', 1000000)$$, :ca, :route, :va),
  'conflicting key', 'Vehicle cannot be assigned to overlapping trips (incl. 30-min turnaround)');
INSERT INTO ops.trip (trip_no, company_id, route_id, vehicle_id, departure_at, arrival_at, status, seats_total, segments_count, currency, base_price)
VALUES ('QDS218/03OCT26', :ca, :route, :va, '2026-10-03 11:30+00', '2026-10-03 14:00+00', 'PUBLISHED', 48, 1, 'SYP', 1000000);
SELECT pg_temp.ok(true, 'Vehicle can take next trip after turnaround');
SELECT pg_temp.expect_error(format($$INSERT INTO ops.trip (trip_no, company_id, route_id, vehicle_id, departure_at, arrival_at, status, seats_total, segments_count, currency, base_price)
  VALUES ('QDS220/04OCT26', %s, %s, %s, '2026-10-04 06:00+00', '2026-10-04 11:00+00', 'PUBLISHED', 40, 1, 'SYP', 1000000)$$, :ca, :route, :vb),
  'VEHICLE_NOT_OWNED_OR_LEASED', 'Carrier cannot assign another carrier''s vehicle');
INSERT INTO ops.crew_assignment (trip_id, party_id, crew_role) SELECT id, :driver, 'DRIVER' FROM ops.trip WHERE trip_no='QDS214/03OCT26';
INSERT INTO ops.crew_assignment (trip_id, party_id, crew_role) SELECT id, :driver, 'DRIVER' FROM ops.trip WHERE trip_no='QDS218/03OCT26';
SELECT pg_temp.ok(true, 'Driver can take a back-to-back trip');
INSERT INTO ops.trip (trip_no, company_id, route_id, departure_at, arrival_at, status, seats_total, segments_count, currency, base_price)
VALUES ('QDS222/03OCT26', :ca, :route, '2026-10-03 08:00+00', '2026-10-03 10:00+00', 'DRAFT', 48, 1, 'SYP', 1000000);
SELECT pg_temp.expect_error(format($$INSERT INTO ops.crew_assignment (trip_id, party_id, crew_role) SELECT id, %s, 'DRIVER' FROM ops.trip WHERE trip_no='QDS222/03OCT26'$$, :driver),
  'conflicting key', 'Driver cannot be assigned to overlapping trips');
COMMIT;

-- 3) Double-entry ledger
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
INSERT INTO fin.wallet (owner_party_id, wallet_type, currency) VALUES (:pax, 'USER', 'SYP');
SELECT id AS w_user FROM fin.wallet WHERE owner_party_id = :pax AND wallet_type = 'USER' \gset
SELECT id AS w_gw FROM fin.wallet WHERE wallet_type = 'GATEWAY_CLEARING' AND currency = 'SYP' \gset
WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('TOPUP','SYP','t-1') RETURNING id)
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount)
SELECT t.id, x.w, x.d, 500000 FROM t, (VALUES (:w_gw, 'DR'), (:w_user, 'CR')) AS x(w, d);
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.ok((SELECT balance FROM fin.wallet WHERE id = :w_user) = 500000, 'Ledger: balanced top-up credits user wallet atomically');
SELECT pg_temp.expect_error(format($$WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('BAD','SYP','t-2') RETURNING id)
  INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) SELECT t.id, %s, 'CR', 100 FROM t$$, :w_user),
  'UNBALANCED_TXN', 'Ledger: unbalanced transaction rejected at commit');
SELECT pg_temp.expect_error(format($$WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('OVER','SYP','t-3') RETURNING id)
  INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) SELECT t.id, x.w, x.d, 900000 FROM t, (VALUES (%s,'DR'),(%s,'CR')) x(w,d)$$, :w_user, :w_gw),
  'wallet_check', 'Ledger: user wallet cannot go negative');
SELECT pg_temp.expect_error('UPDATE fin.ledger_entry SET amount = 1', 'permission denied', 'Ledger: app role cannot update entries');
SELECT pg_temp.expect_error($$INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('TOPUP','SYP','t-1')$$, 'duplicate key', 'Ledger: idempotency key prevents double posting');
COMMIT;

-- 4) Booking state machine
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, channel_id, currency, total_amount, price_breakdown, rules_version, idempotency_key, status, confirmed_at)
SELECT 'ABC123', t.id, :ca, :pax, (SELECT id FROM sales.channel WHERE code='WEB'), 'SYP', 3500000, '{}', 'r1', 'b-1', 'CONFIRMED', now()
FROM ops.trip t WHERE trip_no = 'QDS214/03OCT26';
SELECT pg_temp.expect_error($$UPDATE sales.booking SET status = 'PENDING_PAYMENT' WHERE booking_ref = 'ABC123'$$, 'INVALID_TRANSITION', 'Booking: invalid state transition rejected');
COMMIT;

BEGIN;
SELECT sys.set_context(NULL, NULL, 'PASSENGER', NULL, NULL, NULL, NULL, :pax);
SELECT pg_temp.ok((SELECT count(*) FROM sales.booking) = 1, 'RLS: passenger sees own booking');
SELECT pg_temp.ok((SELECT count(*) FROM fin.wallet) = 1, 'RLS: passenger sees only own wallet');
COMMIT;

-- 4a) Seat layouts: private to the carrier, and a vehicle always carries exactly its layout's seats
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
INSERT INTO fleet.seat_layout (company_id, name, total_seats, grid) VALUES (:ca, 'Test 2+2', 8, '[["SS_SS","SS_SS"]]');
SELECT pg_temp.ok((SELECT count(*) FROM fleet.seat_layout WHERE name = 'Test 2+2') = 1, 'Layouts: carrier sees its own layout');
SELECT pg_temp.expect_error(format($$UPDATE fleet.vehicle SET seat_layout_id = (SELECT id FROM fleet.seat_layout WHERE name = 'Test 2+2') WHERE id = %s$$, :va),
  'SEAT_COUNT_MISMATCH', 'Layouts: vehicle seat count must equal the layout');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, :cb, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM fleet.seat_layout WHERE name = 'Test 2+2') = 0, 'RLS: another carrier cannot see the layout');
COMMIT;

-- 4a2) Payouts: a company cannot verify its own bank account; withdrawals follow their state machine and four eyes
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
SELECT pg_temp.expect_error(format($$INSERT INTO iam.bank_account (party_id, bank_name, holder_name, iban_enc, iban_bidx, iban_last4, enc_key_id, currency, verified)
  VALUES (%s, 'B', 'H', '\x01', '\x02', '1234', 1, 'SYP', true)$$, :ca), 'only platform finance verifies', 'Payouts: company cannot self-verify a bank account');
INSERT INTO iam.bank_account (party_id, bank_name, holder_name, iban_enc, iban_bidx, iban_last4, enc_key_id, currency)
VALUES (:ca, 'B', 'H', '\x01', '\x03', '1234', 1, 'SYP');
SELECT pg_temp.ok(true, 'Payouts: company registers an unverified bank account');
COMMIT;
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
INSERT INTO fin.wallet (owner_party_id, company_id, wallet_type, currency) VALUES (:ca, :ca, 'COMPANY', 'SYP') ON CONFLICT DO NOTHING;
INSERT INTO fin.withdrawal_request (wallet_id, bank_account_id, company_id, amount, requested_by)
SELECT w.id, a.id, :ca, 100, :ua FROM fin.wallet w, iam.bank_account a WHERE w.owner_party_id = :ca AND w.wallet_type = 'COMPANY' AND a.party_id = :ca;
SELECT pg_temp.expect_error($$UPDATE fin.withdrawal_request SET status = 'PAID' WHERE status = 'REQUESTED'$$, 'INVALID_TRANSITION', 'Payouts: a request cannot jump to paid');
SELECT pg_temp.expect_error(format($$UPDATE fin.withdrawal_request SET status = 'APPROVED', approved_by = %s WHERE status = 'REQUESTED'$$, :ua),
  'check', 'Payouts: the requester cannot approve their own withdrawal');
COMMIT;

-- 4b) Agencies: an agency sees the bookings it sold and nothing else; only the platform sets its terms
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY','Barada Travel'), ('COMPANY','Orontes Travel');
INSERT INTO iam.company (id, company_type, approval_status)
SELECT id, 'AGENCY', 'APPROVED' FROM iam.party WHERE legal_name IN ('Barada Travel','Orontes Travel');
COMMIT;
SELECT id AS ag1 FROM iam.party WHERE legal_name='Barada Travel' \gset
SELECT id AS ag2 FROM iam.party WHERE legal_name='Orontes Travel' \gset

BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
INSERT INTO sales.agency_agreement (agency_id, commission_bp, daily_limit) VALUES (:ag1, 500, 10000000), (:ag2, 300, 10000000);
SELECT pg_temp.expect_error(format($$INSERT INTO sales.agency_agreement (agency_id, commission_bp, daily_limit) VALUES (%s, 2500, 1)$$, :ag2),
  'commission_bp', 'Agency: commission above 20% rejected');
INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, channel_id, currency, total_amount, price_breakdown,
                           rules_version, idempotency_key, status, confirmed_at, agency_id, contact_mobile)
SELECT 'AGN001', t.id, :ca, :ag1, (SELECT id FROM sales.channel WHERE code='AGENCY'), 'SYP', 3500000, '{}', 'r1', 'a-1',
       'CONFIRMED', now(), :ag1, '+963944000111'
FROM ops.trip t WHERE trip_no = 'QDS214/03OCT26';
COMMIT;

BEGIN;
SELECT sys.set_context(NULL, :ag1, 'AGENCY');
SELECT pg_temp.ok((SELECT count(*) FROM sales.booking) = 1, 'RLS: agency sees the booking it sold');
SELECT pg_temp.ok((SELECT count(*) FROM sales.booking WHERE booking_ref = 'ABC123') = 0, 'RLS: agency cannot see a passenger''s booking');
SELECT pg_temp.ok((SELECT count(*) FROM sales.agency_agreement) = 1, 'RLS: agency reads only its own agreement');
UPDATE sales.agency_agreement SET commission_bp = 2000;
SELECT pg_temp.expect_error(format($$INSERT INTO sales.agency_agreement (agency_id, commission_bp, daily_limit) VALUES (%s, 2000, 1)$$, :ag1),
  'row-level security', 'RLS: agency cannot write its own terms');
COMMIT;

BEGIN;
SELECT sys.set_context(NULL, :ag2, 'AGENCY');
SELECT pg_temp.ok((SELECT count(*) FROM sales.booking) = 0, 'RLS: another agency cannot see that booking');
COMMIT;

BEGIN;
SELECT sys.set_context(NULL, :ag1, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM sales.booking) = 0, 'RLS: agency visibility needs the AGENCY scope');
COMMIT;

BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
SELECT pg_temp.ok((SELECT commission_bp FROM sales.agency_agreement WHERE agency_id = :ag1) = 500, 'Agency: terms unchanged by the agency''s update');
COMMIT;

-- 5) E-invoice
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
INSERT INTO acct.tax_authority (code, country_code, name) VALUES ('SY-GCTF', 'SY', 'General Commission for Taxes and Fees');
INSERT INTO acct.tax_profile (party_id, authority_id, tax_status, tax_no, legal_name)
SELECT :ca, id, 'REGISTERED', '0101234567', 'Al-Quds Transport' FROM acct.tax_authority WHERE code='SY-GCTF';
INSERT INTO acct.einvoice_unit (profile_id, authority_id, unit_code, number_prefix)
SELECT p.id, p.authority_id, 'QDS-01', 'QDS-' FROM acct.tax_profile p WHERE party_id = :ca;
SELECT id AS unit FROM acct.einvoice_unit WHERE unit_code='QDS-01' \gset
SELECT id AS prof FROM acct.tax_profile WHERE party_id = :ca \gset
INSERT INTO acct.einvoice_document (doc_type, subtype, seller_profile_id, unit_id, company_id, buyer_party_id, source_type, source_id, currency, subtotal, tax_total, total)
VALUES ('INVOICE','SIMPLIFIED', :prof, :unit, :ca, :pax, 'BOOKING', 1, 'SYP', 3000000, 500000, 3500000);
SELECT max(id) AS inv FROM acct.einvoice_document \gset
INSERT INTO acct.einvoice_line (document_id, line_no, description, unit_price, net_amount, tax_rate, tax_amount)
VALUES (:inv, 1, 'Ticket Damascus - Aleppo', 3000000, 3000000, 0.166667, 500000);
SELECT pg_temp.ok((acct.finalize_einvoice(:inv, 'HASH-1', 'SIG', 'QR-TLV')).number = 'QDS-0000000001', 'E-invoice: finalize assigns gapless number');
SELECT pg_temp.ok((SELECT previous_hash FROM acct.einvoice_document WHERE id = :inv) = '0', 'E-invoice: first hash links to genesis');
SELECT pg_temp.expect_error(format('UPDATE acct.einvoice_document SET total = 1, subtotal = 1, tax_total = 0 WHERE id = %s', :inv), 'IMMUTABLE_RECORD', 'E-invoice: finalized content cannot change');
SELECT pg_temp.expect_error(format('INSERT INTO acct.einvoice_line (document_id, line_no, description, unit_price, net_amount) VALUES (%s, 2, %L, 1, 1)', :inv, 'x'), 'IMMUTABLE_RECORD', 'E-invoice: cannot add lines after finalize');
SELECT pg_temp.expect_error(format('DELETE FROM acct.einvoice_document WHERE id = %s', :inv), 'permission denied', 'E-invoice: cannot be deleted');
UPDATE acct.einvoice_document SET status = 'SUBMITTED' WHERE id = :inv;
UPDATE acct.einvoice_document SET status = 'CLEARED', authority_ref = 'GOV-777', confirmed_at = now() WHERE id = :inv;
SELECT pg_temp.expect_error(format($$UPDATE acct.einvoice_document SET status = 'FINALIZED' WHERE id = %s$$, :inv), 'INVALID_TRANSITION', 'E-invoice: confirmed invoice is fully locked');
INSERT INTO acct.einvoice_document (doc_type, subtype, seller_profile_id, unit_id, company_id, buyer_party_id, source_type, source_id, original_doc_id, reason_code, currency, subtotal, tax_total, total)
VALUES ('CREDIT_NOTE','SIMPLIFIED', :prof, :unit, :ca, :pax, 'REFUND', 1, :inv, 'CANCEL', 'SYP', 3000000, 500000, 3500000);
SELECT max(id) AS cn FROM acct.einvoice_document \gset
SELECT pg_temp.ok((SELECT (acct.finalize_einvoice(:cn, 'HASH-2', 'SIG', 'QR2')).previous_hash) = 'HASH-1', 'E-invoice: credit note chained to previous hash');
INSERT INTO acct.einvoice_document (doc_type, subtype, seller_profile_id, unit_id, company_id, buyer_party_id, source_type, source_id, original_doc_id, reason_code, currency, subtotal, tax_total, total)
VALUES ('CREDIT_NOTE','SIMPLIFIED', :prof, :unit, :ca, :pax, 'REFUND', 1, :inv, 'CANCEL', 'SYP', 100, 0, 100);
SELECT max(id) AS cn2 FROM acct.einvoice_document \gset
SELECT pg_temp.expect_error(format('SELECT acct.finalize_einvoice(%s, %L, %L, %L)', :cn2, 'H3', 'S', 'Q'), 'CREDIT_EXCEEDS_ORIGINAL', 'E-invoice: credit notes cannot exceed original');
COMMIT;

-- 6) License date locking
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
INSERT INTO fleet.license_record (company_id, subject_type, subject_id, license_type, license_no, issuer, issue_date, expiry_date, status)
VALUES (:ca, 'VEHICLE', :va, 'INSURANCE', 'POL-1', 'Test Insurance Co.', '2026-01-01', '2026-12-31', 'VALID');
SELECT max(id) AS lic FROM fleet.license_record \gset
SELECT pg_temp.expect_error(format($$UPDATE fleet.license_record SET expiry_date = '2027-12-31' WHERE id = %s$$, :lic), 'LICENSE_LOCKED', 'License: locked expiry cannot be edited directly');
COMMIT;
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'PLATFORM');
INSERT INTO fleet.license_change_request (license_record_id, requested_by, new_values, status, reviewed_by, approved_by)
VALUES (:lic, :ua, '{"expiry_date":"2027-12-31"}', 'APPROVED', :ufin, :uadmin);
UPDATE fleet.license_record SET expiry_date = '2027-12-31', last_change_request_id = (SELECT max(id) FROM fleet.license_change_request) WHERE id = :lic;
SELECT pg_temp.ok((SELECT expiry_date FROM fleet.license_record WHERE id = :lic) = '2027-12-31', 'License: change applied only via approved dual-control request');
SELECT pg_temp.expect_error(format($$INSERT INTO fleet.license_change_request (license_record_id, requested_by, new_values, approved_by) VALUES (%s, %s, '{}', %s)$$, :lic, :ua, :ua),
  'license_change_request_check', 'License: requester cannot approve own change');
COMMIT;

-- 7) IP rules and automatic blocking
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'PLATFORM');
INSERT INTO sec.ip_rule (rule_type, cidr, action, scope, reason) VALUES ('CIDR', '203.0.113.0/24', 'BLOCK', 'ALL', 'scraping');
INSERT INTO sec.ip_rule (rule_type, cidr, action, scope, priority, reason) VALUES ('CIDR', '203.0.113.10/32', 'ALLOW', 'API', 200, 'partner gateway');
INSERT INTO sec.ip_rule (rule_type, cidr, action, scope, reason, expires_at) VALUES ('CIDR', '198.51.100.0/24', 'BLOCK', 'ALL', 'old', now() - interval '1 hour');
SELECT pg_temp.ok((SELECT action FROM sec.ip_decision('203.0.113.7', 'PASSENGER')) = 'BLOCK', 'IP: address inside blocked range is blocked');
SELECT pg_temp.ok((SELECT action FROM sec.ip_decision('203.0.113.10', 'API')) = 'ALLOW', 'IP: higher-priority allow for a partner overrides range block on API');
SELECT pg_temp.ok((SELECT action FROM sec.ip_decision('203.0.113.10', 'PASSENGER')) = 'BLOCK', 'IP: allow rule scoped to API does not open other portals');
SELECT pg_temp.ok((SELECT count(*) FROM sec.ip_decision('198.51.100.5', 'ALL')) = 0, 'IP: expired rule is ignored');
SELECT pg_temp.ok((SELECT count(*) FROM sys.outbox_event WHERE event_type = 'sec.ip_rule.changed') >= 3, 'IP: rule changes are published to the edge (outbox)');
SELECT pg_temp.expect_error($$DELETE FROM sec.ip_rule$$, 'permission denied', 'IP: rules are revoked, never deleted');
COMMIT;

BEGIN;
SELECT sys.set_context(NULL, NULL, 'SYSTEM');
INSERT INTO audit.auth_event (event, actor_type, identifier_hash, portal, ip, result, reason)
SELECT 'LOGIN_FAILED', 'ANONYMOUS', '\x01', 'PASSENGER', '192.0.2.44', 'FAILURE', 'bad password' FROM generate_series(1, 30);
COMMIT;
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'PLATFORM');
SELECT pg_temp.ok((SELECT action FROM sec.ip_decision('192.0.2.44', 'PASSENGER')) = 'BLOCK', 'Auto-block: 30 failed logins from one IP block it automatically');
SELECT pg_temp.ok((SELECT expires_at > now() FROM sec.ip_rule WHERE source = 'AUTO_AUTH' LIMIT 1), 'Auto-block: automatic block is temporary');
COMMIT;

-- 8) Audit logs
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY', NULL, gen_random_uuid(), '10.0.0.5');
INSERT INTO audit.activity_log (actor_type, user_id, company_id, ip, http_method, endpoint, action, object_type, object_id, result, http_status, ts)
VALUES ('USER', :ua, :ca, '10.0.0.5', 'POST', '/v1/trips', 'trip.publish', 'trip', 1, 'SUCCESS', 201, now() - interval '5 minutes');
INSERT INTO audit.activity_log (actor_type, api_client_id, ip, http_method, endpoint, action, result, http_status, ts)
VALUES ('API_CLIENT', NULL, '10.0.0.9', 'GET', '/v1/carrier/trips', 'trip.search', 'SUCCESS', 200, now() - interval '5 minutes');
UPDATE fleet.vehicle SET standing_capacity = 5 WHERE id = :va;
SELECT pg_temp.expect_error('UPDATE audit.activity_log SET result = $$ERROR$$', 'permission denied', 'Audit: app role cannot modify activity log');
SELECT pg_temp.expect_error('SELECT count(*) FROM audit.activity_log', 'permission denied', 'Audit: app role cannot read audit logs (auditor only)');
COMMIT;

RESET ROLE;
SELECT pg_temp.expect_error('UPDATE audit.activity_log SET result = $$ERROR$$', 'IMMUTABLE_RECORD', 'Audit: even the owner cannot modify log rows (trigger)');
SELECT pg_temp.ok((SELECT row_hash IS NOT NULL FROM audit.activity_log LIMIT 1), 'Audit: every row carries a content hash');
SELECT pg_temp.ok((SELECT user_id = :ua AND new_values ? 'standing_capacity' AND ip = '10.0.0.5'
                   FROM audit.row_change WHERE table_name = 'vehicle' AND op = 'U' ORDER BY id DESC LIMIT 1),
                  'Audit: DB-level change capture records who changed what, from which IP');
SELECT pg_temp.ok((SELECT new_values->>'password_hash' = '***' FROM audit.row_change WHERE table_name = 'app_user' AND new_values->>'email' = 'owner@quds.test'), 'Audit: password hash redacted in change log');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM audit.row_change WHERE new_values::text LIKE '%Zq9-PW-MARKER-7731%'), 'Audit: no secret value anywhere in change log');
SELECT pg_temp.ok(audit.seal('activity_log') IS NOT NULL, 'Audit: activity log block sealed with hash chain');
SELECT pg_temp.ok((SELECT row_count FROM audit.log_seal WHERE log_name = 'activity_log' ORDER BY id DESC LIMIT 1) = 2, 'Audit: seal covers all eligible rows');

-- 9) Miscellaneous
SELECT pg_temp.ok(sys.mod11_check_digit('004512378') BETWEEN 0 AND 9, 'Tracking numbers: Mod-11 check digit function');
SELECT pg_temp.expect_error($$INSERT INTO net.station (code, city_id, country_code, station_class, name, lat, lng) VALUES ('BAD', 1, 'SY', 'CENTRAL', 'x', 0, 0)$$, 'station_code_check', 'Station code format enforced (SY-DAM-C001)');
SELECT pg_temp.expect_error(format($$INSERT INTO net.service_number (company_id, number, block, direction) VALUES (%s, 1500, 'SCHEDULED', 'OUTBOUND')$$, :ca), 'service_number_check', 'Service number must be inside its block');

SELECT pg_temp.ok((SELECT code FROM ref.locale WHERE is_default) = 'en', 'Locales: English is the single default locale');
SELECT pg_temp.ok((SELECT direction FROM ref.locale WHERE code = 'ar') = 'RTL', 'Locales: Arabic UI locale is RTL');
SELECT pg_temp.ok((SELECT preferred_locale FROM iam.app_user WHERE email = 'owner@quds.test') = 'en', 'Locales: users default to English');
SELECT pg_temp.expect_error($$UPDATE iam.app_user SET preferred_locale = 'xx' WHERE email = 'owner@quds.test'$$, 'app_user_preferred_locale_fkey', 'Locales: unknown locale rejected');

\echo '=== ALL TESTS PASSED ==='

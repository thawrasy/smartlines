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

-- The phase modules exercised below are switched on, as the platform does before a phase starts (1039 closes the
-- tables of a module whose switch is off). The shipped defaults are kept to check them below.
SELECT value AS shipped_features FROM sys.setting WHERE key = 'features' \gset
UPDATE sys.setting SET value = value || '{"cargo":true,"freight":true,"border_manifest":true,"carrier_billing":true,"service_partners":true,
  "rail":true,"taxi":true,"car_rental":true,"contract_transport":true}'::jsonb WHERE key = 'features';

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

-- 4a3) Documents: a company uploads but never decides on its own documents
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
INSERT INTO ref.file_object (storage_key, mime_type, size_bytes, sha256, company_id) VALUES ('t/doc1', 'application/pdf', 10, '\x00', :ca);
INSERT INTO iam.document (owner_type, owner_id, doc_type, file_id, company_id)
SELECT 'COMPANY', :ca, 'CR', id, :ca FROM ref.file_object WHERE storage_key = 't/doc1';
SELECT pg_temp.expect_error($$UPDATE iam.document SET status = 'APPROVED' WHERE doc_type = 'CR'$$, 'only the platform reviews', 'Documents: company cannot approve its own document');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, :cb, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM iam.document) = 0 AND (SELECT count(*) FROM ref.file_object WHERE storage_key = 't/doc1') = 0,
  'RLS: another company sees neither the document nor its file');
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
VALUES ('CREDIT_NOTE','SIMPLIFIED', :prof, :unit, :ca, :pax, 'BOOKING', 1, :inv, 'CANCEL', 'SYP', 3000000, 500000, 3500000);
SELECT max(id) AS cn FROM acct.einvoice_document \gset
SELECT pg_temp.ok((SELECT (acct.finalize_einvoice(:cn, 'HASH-2', 'SIG', 'QR2')).previous_hash) = 'HASH-1', 'E-invoice: credit note chained to previous hash');
INSERT INTO acct.einvoice_document (doc_type, subtype, seller_profile_id, unit_id, company_id, buyer_party_id, source_type, source_id, original_doc_id, reason_code, currency, subtotal, tax_total, total)
VALUES ('CREDIT_NOTE','SIMPLIFIED', :prof, :unit, :ca, :pax, 'BOOKING', 1, :inv, 'CANCEL', 'SYP', 100, 0, 100);
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


-- 10) Extensibility and annex D readiness (1003)
SELECT pg_temp.ok((SELECT count(*) FROM ref.party_role_type WHERE code IN ('EDU_INSTITUTION','EMPLOYER','GUARDIAN','ATTENDANT')) = 4, 'Reference: contracted-transport party roles exist');
SELECT pg_temp.ok((SELECT count(*) FROM ref.trip_type WHERE code IN ('TRANSIT_PAX','CONTRACT')) = 2, 'Reference: passenger transit and contract trip types exist');
SELECT pg_temp.ok((SELECT dangerous FROM ref.cargo_category WHERE code = 'DANGEROUS'), 'Reference: cargo categories carry the hazard flag');
SELECT pg_temp.ok((SELECT value->>'transit_passengers' = 'false' AND value->>'contract_transport' = 'false' FROM (SELECT :'shipped_features'::jsonb AS value) f), 'Feature flags: new modules ship disabled');
SELECT pg_temp.expect_error(format($$INSERT INTO iam.party_role (party_id, role_code) VALUES (%s, 'MADE_UP')$$, :pax), 'party_role_role_code_fk', 'Reference: unknown party role rejected by foreign key');
SELECT pg_temp.expect_error($$UPDATE ops.trip SET trip_type = 'NOPE' WHERE trip_no = 'QDS222/03OCT26'$$, 'trip_trip_type_fk', 'Reference: unknown trip type rejected by foreign key');
INSERT INTO net.station (code, city_id, country_code, station_class, subtype, name, lat, lng, status)
SELECT v.code, c.id, 'SY', 'CENTRAL', 'BORDER', v.name, c.lat, c.lng, 'ACTIVE'
  FROM (VALUES ('SY-DRA-X001','DRA','Nassib border crossing'), ('SY-IDL-X001','IDL','Bab al-Hawa border crossing')) v(code, city, name)
  JOIN ref.city c ON c.code = v.city;
SELECT id AS b_in FROM net.station WHERE code = 'SY-DRA-X001' \gset
SELECT id AS b_out FROM net.station WHERE code = 'SY-IDL-X001' \gset
SELECT id AS st_dam FROM net.station WHERE code = 'SY-DAM-C001' \gset
SELECT id AS t_tr FROM ops.trip WHERE trip_no = 'QDS214/03OCT26' \gset

SET ROLE masslak_app;
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'PLATFORM');
INSERT INTO ref.party_role_type (code, name, module) VALUES ('SCHOOL_BOARD', 'School board', 'contract_transport');
SELECT pg_temp.ok(true, 'Reference: the platform adds a new role without a schema change');
SELECT pg_temp.expect_error($$DELETE FROM ref.trip_type WHERE code = 'SCHEDULED'$$, 'SYSTEM_VALUE', 'Reference: system values cannot be deleted');
COMMIT;
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
SELECT pg_temp.expect_error($$INSERT INTO ref.trip_type (code, name) VALUES ('MINE', 'Mine')$$, 'row-level security', 'Reference: a carrier cannot change reference lists');
INSERT INTO ops.trip_crossing_plan (trip_id, seq, exit_station_id, entry_station_id) VALUES (:t_tr, 1, :b_out, :b_in);
SELECT pg_temp.ok(true, 'Transit: the carrier records the trip''s border crossing plan');
SELECT pg_temp.expect_error(format($$INSERT INTO ops.trip_crossing_plan (trip_id, seq, exit_station_id, entry_station_id) VALUES (%s, 2, %s, %s)$$, :t_tr, :st_dam, :b_in),
  'NOT_A_BORDER_POINT', 'Transit: crossing points must be border stations');
INSERT INTO ops.crossing_event (trip_id, station_id, direction, source, occurred_at) VALUES (:t_tr, :b_in, 'ENTRY', 'DRIVER', now());
SELECT pg_temp.ok(true, 'Transit: the driver records the entry crossing');
SELECT pg_temp.expect_error($$UPDATE ops.crossing_event SET direction = 'EXIT'$$, 'permission denied', 'Transit: crossing events are append-only');
INSERT INTO ctr.service_contract (kind, client_party_id, carrier_company_id, starts_on, ends_on, pricing_mode, price)
VALUES ('SCHOOL', :pax, :ca, '2026-09-01', '2027-06-30', 'MONTHLY', 150000000);
SELECT pg_temp.ok((SELECT count(*) FROM ctr.service_contract) = 1, 'Contracts: the carrier sees its contract');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, :cb, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM ctr.service_contract) = 0, 'Contracts: another carrier cannot see the contract');
SELECT pg_temp.ok((SELECT count(*) FROM ops.crossing_event) = 0, 'Transit: another carrier cannot see crossing events');
SELECT pg_temp.expect_error(format($$INSERT INTO ctr.service_contract (kind, client_party_id, carrier_company_id, starts_on, ends_on, pricing_mode, price)
  VALUES ('STAFF', %s, %s, '2026-09-01', '2027-06-30', 'MONTHLY', 1)$$, :pax, :ca), 'row-level security', 'Contracts: a carrier cannot create a contract for another carrier');
COMMIT;
RESET ROLE;
INSERT INTO iam.party_role (party_id, role_code) VALUES (:pax, 'SCHOOL_BOARD');
SELECT pg_temp.ok(true, 'Reference: a party takes the newly added role');


-- 11) Full data model of study v2.6 (files 1010 to 1029)
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND n.nspname IN ('bill','ptn','ship','frt','brd','rail','taxi','rent') AND NOT c.relrowsecurity),
  'Model: every table of the new modules has row-level security');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND n.nspname IN ('bill','ptn','ship','frt','brd','rail','taxi','rent')
    AND NOT has_table_privilege('masslak_app', c.oid, 'SELECT')), 'Model: the application role can reach every new table');
SELECT pg_temp.ok((SELECT value->>'car_rental' = 'false' AND value->>'freight' = 'false' AND value->>'border_manifest' = 'false'
  FROM (SELECT :'shipped_features'::jsonb AS value) f), 'Model: the new modules ship disabled behind feature flags');
SELECT pg_temp.ok((SELECT pg_get_constraintdef(oid) LIKE '%OFFLINE_SCAN%' AND pg_get_constraintdef(oid) LIKE '%CASH%'
  FROM pg_constraint WHERE conname = 'boarding_event_method_check'), 'Boarding: offline driver scans (1002) and cash shuttle boardings are both accepted');
SELECT pg_temp.expect_error(format($$INSERT INTO brd.border_point (station_id, point_type, country_code) VALUES (%s, 'LAND', 'SY')$$, :st_dam),
  'NOT_A_BORDER_POINT', 'Border: a border point must be a BORDER station');
SELECT pg_temp.expect_error($$INSERT INTO frt.container (container_no, size_type) VALUES ('ABC1234567', '22G1')$$,
  'container_container_no_check', 'Freight: container numbers follow ISO 6346');

INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY','Third Courier'), ('COMPANY','North Fuel');
INSERT INTO iam.company (id, approval_status, company_type) SELECT id, 'APPROVED', CASE legal_name WHEN 'North Fuel' THEN 'PARTNER' ELSE 'CARRIER' END
  FROM iam.party WHERE legal_name IN ('Third Courier','North Fuel');
SELECT id AS cc FROM iam.party WHERE legal_name = 'Third Courier' \gset
SELECT id AS cfuel FROM iam.party WHERE legal_name = 'North Fuel' \gset
INSERT INTO ship.service_product (code, name) VALUES ('EXPRESS_1D', 'Express next day');
INSERT INTO ship.shipment (tracking_no, company_id, shipper_party_id, service_id, origin_station_id, dest_station_id)
SELECT 'MSL0000000017', :ca, :pax, id, :st_dam, :b_in FROM ship.service_product WHERE code = 'EXPRESS_1D';
SELECT id AS shp FROM ship.shipment WHERE tracking_no = 'MSL0000000017' \gset
INSERT INTO ship.shipment_leg (shipment_id, seq, mode, carrier_company_id, trip_id) VALUES (:shp, 1, 'BUS_HOLD', :cb, :t_tr);
INSERT INTO brd.border_point (station_id, point_type, country_code) VALUES (:b_in, 'LAND', 'SY');
INSERT INTO brd.manifest (trip_id, border_point_id, manifest_type) VALUES (:t_tr, :b_in, 'PRE_ARRIVAL');
SELECT id AS mf FROM brd.manifest WHERE trip_id = :t_tr \gset
INSERT INTO brd.manifest_response (manifest_id, subject_type, decision) VALUES (:mf, 'MANIFEST', 'OK');
INSERT INTO brd.manifest_person (manifest_id, person_role, crew_party_id, nationality) VALUES (:mf, 'CREW', :driver, 'SY');
SELECT id AS mperson FROM brd.manifest_person WHERE manifest_id = :mf \gset
INSERT INTO brd.manifest_response (manifest_id, subject_type, subject_id, decision, silent_flag) VALUES (:mf, 'PERSON', :mperson, 'OK', true);
INSERT INTO ptn.partner (party_id, company_id, partner_type, code, status) VALUES (:cfuel, :cfuel, 'FUEL', 'FUEL-001', 'ACTIVE');
SELECT id AS ptnr FROM ptn.partner WHERE code = 'FUEL-001' \gset
INSERT INTO ptn.partner_contract (partner_id, commission_model, rate_bp, valid, status) VALUES (:ptnr, 'PERCENT', 150, daterange(current_date, NULL), 'ACTIVE');
INSERT INTO frt.freight_request (shipper_party_id, shipper_company_id, origin_station_id, dest_station_id, cargo_category, cargo_description,
  declared_weight_kg, pickup_window, mode, status)
VALUES (:pax, :ca, :st_dam, :b_in, 'GENERAL', 'Textiles', 12000, tstzrange(now(), now() + interval '2 days'), 'BID', 'OPEN'),
       (:pax, :ca, :st_dam, :b_in, 'FOOD', 'Olive oil', 8000, tstzrange(now(), now() + interval '2 days'), 'BID', 'DRAFT');
INSERT INTO fleet.truck_unit (vehicle_id, axle_config, gvw_kg, tare_kg) VALUES (:va, '6x4', 40000, 9000);
INSERT INTO fleet.trailer (company_id, plate_no, trailer_type, payload_kg) VALUES (:ca, 'TR-1001', 'CURTAIN', 24000);
SELECT id AS trl FROM fleet.trailer WHERE plate_no = 'TR-1001' \gset
INSERT INTO fin.wallet (owner_party_id, wallet_type, currency) VALUES (:pax, 'USER', 'SYP') ON CONFLICT DO NOTHING;
SELECT id AS wpax FROM fin.wallet WHERE owner_party_id = :pax AND wallet_type = 'USER' AND currency = 'SYP' \gset
INSERT INTO net.line (code, name, kind, fare_regime, status) VALUES ('DAM-L1', 'Damascus line 1', 'SHUTTLE', 'REGULATED', 'ACTIVE');
SELECT id AS ln FROM net.line WHERE code = 'DAM-L1' \gset

SET ROLE masslak_app;
BEGIN;
SELECT sys.set_context(NULL, :cb, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM ship.shipment WHERE id = :shp) = 1, 'Shipping: the carrier of a leg sees the shipment');
SELECT pg_temp.ok((SELECT count(*) FROM frt.open_loads()) = 1, 'Freight: other carriers see open bid requests only, not drafts');
SELECT pg_temp.ok((SELECT count(*) FROM frt.freight_request) = 0,
  'Isolation: a competing carrier cannot read the shipper''s request (identity, addresses), only the market view');
INSERT INTO frt.freight_bid (request_id, carrier_company_id, price, valid_until)
SELECT id, :cb, 9000000, now() + interval '1 day' FROM frt.open_loads();
SELECT pg_temp.ok(true, 'Freight: a carrier bids on an open request');
SELECT pg_temp.ok((SELECT count(*) FROM ptn.partner) = 1 AND (SELECT count(*) FROM ptn.partner_contract) = 0,
  'Partners: carriers see active partners but not their contracts');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, :cc, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM ship.shipment) = 0 AND (SELECT count(*) FROM ship.shipment_leg) = 0,
  'Shipping: an unrelated company sees neither the shipment nor its legs');
SELECT pg_temp.ok((SELECT count(*) FROM frt.freight_bid) = 0, 'Freight: a carrier cannot see another carrier''s bid');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, NULL, 'PASSENGER', NULL, NULL, NULL, NULL, :pax);
SELECT pg_temp.ok((SELECT count(*) FROM ship.shipment) = 1, 'Shipping: the shipper sees its own shipment');
COMMIT;
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM brd.manifest_response) = 1, 'Border: the carrier never sees silent authority flags');
SELECT pg_temp.expect_error(format($$INSERT INTO brd.manifest_response (manifest_id, subject_type, decision) VALUES (%s, 'MANIFEST', 'DENY')$$, :mf),
  'row-level security', 'Border: only the platform records authority decisions');
INSERT INTO fleet.truck_combination (company_id, truck_vehicle_id, trailer_id, period) VALUES (:ca, :va, :trl, tstzrange(now(), now() + interval '1 day'));
SELECT pg_temp.expect_error(format($$INSERT INTO fleet.truck_combination (company_id, truck_vehicle_id, trailer_id, period)
  VALUES (%s, %s, %s, tstzrange(now() + interval '2 hours', now() + interval '3 hours'))$$, :ca, :va, :trl),
  'exclusion constraint', 'Fleet: a truck or trailer cannot be coupled twice at the same time');
INSERT INTO ops.shuttle_ride (user_id, wallet_id, trip_id, line_id, board_station_id, board_ts) VALUES (:ua, :wpax, :t_tr, :ln, :st_dam, now());
SELECT pg_temp.expect_error(format($$INSERT INTO ops.shuttle_ride (user_id, wallet_id, trip_id, line_id, board_station_id, board_ts)
  VALUES (%s, %s, %s, %s, %s, now())$$, :ua, :wpax, :t_tr, :ln, :st_dam), 'shuttle_ride_one_open', 'Shuttle: one open ride per user');
SELECT pg_temp.expect_error($$UPDATE ops.ride_segment_charge SET amount = 0$$, 'permission denied', 'Shuttle: ride charges are append-only');
INSERT INTO ship.tracking_event (shipment_id, milestone) VALUES (:shp, 'RECEIVED_AT_HUB');
SELECT pg_temp.expect_error($$UPDATE ship.tracking_event SET milestone = 'DELIVERED'$$, 'permission denied', 'Shipping: tracking events are append-only');
SELECT pg_temp.expect_error(format($$INSERT INTO acct.sales_invoice (company_id, invoice_no, customer_party_id, issue_date, subtotal, tax, total)
  VALUES (%s, 'INV-1', %s, current_date, 1000, 100, 1200)$$, :ca, :pax), 'sales_invoice_check', 'Accounting: invoice total must equal subtotal plus tax');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, :cfuel, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM ptn.partner_contract) = 1, 'Partners: partner staff see their own contract (no policy recursion)');
COMMIT;
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'PLATFORM');
SELECT pg_temp.ok((SELECT count(*) FROM brd.manifest_response) = 2, 'Border: the platform sees every authority decision');
INSERT INTO bill.plan (code, kind, name, annual_fee) VALUES ('BASIC', 'STANDARD', 'Basic', 1200000);
SELECT pg_temp.expect_error(format($$INSERT INTO bill.carrier_agreement (company_id, label, terms, valid_days, created_by, approved_by)
  VALUES (%s, 'Special', '{}', 365, %s, %s)$$, :ca, :uadmin, :uadmin), 'carrier_agreement_check', 'Billing: an agreement needs a second approver');
INSERT INTO bill.company_subscription (company_id, source, plan_id, starts_at, ends_at, terms)
SELECT :ca, 'PLAN', id, now(), now() + interval '1 year', '{}' FROM bill.plan WHERE code = 'BASIC';
SELECT pg_temp.expect_error(format($$INSERT INTO bill.company_subscription (company_id, source, plan_id, starts_at, ends_at, terms)
  SELECT %s, 'PLAN', id, now(), now() + interval '1 year', '{}' FROM bill.plan WHERE code = 'BASIC'$$, :ca),
  'company_subscription_one_active', 'Billing: one active subscription per company');
COMMIT;
RESET ROLE;

-- Row-level security coverage (1037): private data never relies on the application layer alone
SELECT pg_temp.ok(NOT EXISTS (
  SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND NOT c.relrowsecurity
     AND n.nspname NOT IN ('pg_catalog','information_schema','public','audit')
     AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                  AND a.attname IN ('company_id','booking_id'))
     AND (n.nspname || '.' || c.relname) NOT IN ('iam.user_session','pricing.points_ledger','crm.trip_rating')),
  'Governance: every table holding company or booking rows has row-level security');
SELECT pg_temp.ok(NOT EXISTS (
  SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind = 'r' AND NOT c.relrowsecurity AND n.nspname IN ('gov','sec')
     AND (n.nspname || '.' || c.relname) NOT IN ('sec.sos_event','sec.authority_order','sec.authority_data_request','sec.authority_policy',
                                                  'sec.authority_profile','sec.document_signature','sec.tamper_event')),
  'Governance: governance and security registers are isolated');
SET ROLE masslak_app;
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM ref.currency) > 0, 'RLS: catalogs stay readable by every portal');
SELECT pg_temp.expect_error($$INSERT INTO ref.currency DEFAULT VALUES$$, 'row-level security', 'RLS: a carrier cannot change a catalog');
SELECT pg_temp.expect_error($$INSERT INTO sec.watchlist_entry DEFAULT VALUES$$, 'row-level security', 'RLS: a carrier cannot write the watchlist');
SELECT pg_temp.ok((SELECT count(*) FROM gov.privacy_incident) = 0, 'RLS: a carrier cannot read privacy incidents');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, :cb, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM sales.ticket t JOIN sales.booking b ON b.id = t.booking_id WHERE b.company_id = :ca) = 0
                  AND (SELECT count(*) FROM sales.ticket) = (SELECT count(*) FROM sales.ticket t WHERE EXISTS (SELECT 1 FROM sales.booking b WHERE b.id = t.booking_id)),
  'RLS: tickets follow the visibility of their booking');
SELECT pg_temp.ok((SELECT count(*) FROM fin.payment p JOIN sales.booking b ON b.id = p.booking_id WHERE b.company_id = :ca) = 0,
  'RLS: another carrier cannot see payments of a booking');
COMMIT;
RESET ROLE;

-- Passenger categories, families, manifests and commercial isolation (1038)
INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON','Family Head'), ('PERSON','Family Son'), ('PERSON','Stranger');
SELECT id AS fhead FROM iam.party WHERE legal_name = 'Family Head' \gset
SELECT id AS fson FROM iam.party WHERE legal_name = 'Family Son' \gset
SELECT id AS fstranger FROM iam.party WHERE legal_name = 'Stranger' \gset
INSERT INTO iam.family (head_party_id, name) VALUES (:fhead, 'Head family');
SELECT id AS fam FROM iam.family WHERE head_party_id = :fhead \gset
INSERT INTO iam.family_member (family_id, party_id, relation, first_name, last_name, birth_date)
VALUES (:fam, :fhead, 'SELF', 'Head', 'Family', '1980-01-01'), (:fam, :fson, 'SON', 'Son', 'Family', '2016-05-01');
SELECT id AS fsonm FROM iam.family_member WHERE party_id = :fson \gset
INSERT INTO frt.container (container_no, size_type, owner_party_id) VALUES ('MSKU1234565', '40HC', :ca);
INSERT INTO ship.rate_table (company_id, service_id, valid, status, currency)
SELECT :ca, id, daterange(current_date, NULL), 'PUBLISHED', 'SYP' FROM ship.service_product ORDER BY id LIMIT 1;
INSERT INTO sec.authority_profile (code, name, authority_type, protocol) VALUES ('TEST-POLICE', 'Test police', 'POLICE', 'REST');
SELECT id AS auth FROM sec.authority_profile WHERE code = 'TEST-POLICE' \gset
SET ROLE masslak_app;
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
SELECT pg_temp.expect_error(format($$INSERT INTO pricing.passenger_age_band (company_id, category, min_age, max_age) VALUES (%s, 'CHILD', 2, 12), (%s, 'INFANT', 0, 3)$$, :ca, :ca),
  'passenger_age_band', 'Categories: a carrier''s age bands cannot overlap');
INSERT INTO pricing.passenger_age_band (company_id, category, min_age, max_age, seat_required, needs_adult, max_per_adult)
VALUES (:ca, 'INFANT', 0, 3, false, true, 1), (:ca, 'CHILD', 3, 14, true, true, NULL), (:ca, 'ADULT', 14, NULL, true, false, NULL);
SELECT pg_temp.ok((SELECT count(*) FROM pricing.passenger_age_band WHERE company_id = :ca) = 3, 'Categories: a carrier sets its own age bands');
SELECT pg_temp.expect_error($$INSERT INTO pricing.passenger_age_band (company_id, category, min_age, max_age) VALUES (NULL, 'CHILD', 1, 5)$$,
  'row-level security', 'Categories: a carrier cannot change the platform default');
SELECT pg_temp.ok((SELECT count(*) FROM frt.container WHERE container_no = 'MSKU1234565') = 1, 'Isolation: the owner sees its container');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, :cb, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM pricing.passenger_age_band WHERE company_id = :ca) = 3, 'Categories: age bands are public so travellers see who counts as a child');
SELECT pg_temp.ok((SELECT count(*) FROM frt.container WHERE container_no = 'MSKU1234565') = 0, 'Isolation: another company cannot see the container');
SELECT pg_temp.ok((SELECT count(*) FROM ship.rate_table WHERE company_id = :ca) = 0, 'Isolation: a competing carrier cannot read another carrier''s rate table');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, NULL, 'PASSENGER', NULL, NULL, NULL, NULL, :fstranger);
SELECT pg_temp.ok((SELECT count(*) FROM ship.rate_table WHERE company_id = :ca) = 1, 'Isolation: a customer still reads published prices');
SELECT pg_temp.ok((SELECT count(*) FROM iam.family_member) = 0 AND (SELECT count(*) FROM iam.family) = 0, 'Families: a stranger sees no family or member');
SELECT pg_temp.expect_error(format($$INSERT INTO iam.family_member (family_id, party_id, relation, first_name, last_name, birth_date) VALUES (%s, %s, 'OTHER', 'X', 'Y', '2000-01-01')$$, :fam, :fstranger),
  'row-level security', 'Families: only the head adds members');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, NULL, 'PASSENGER', NULL, NULL, NULL, NULL, :fhead);
SELECT pg_temp.ok((SELECT count(*) FROM iam.family_member WHERE family_id = :fam) = 2, 'Families: the head sees every member');
INSERT INTO iam.family_travel_rule (member_id, rule_type, days, start_time, end_time) VALUES (:fsonm, 'TIME_WINDOW', '{1,2,3,4,5}', '06:00', '18:00');
SELECT pg_temp.ok(true, 'Families: the head limits a member to school days and hours');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, NULL, 'PASSENGER', NULL, NULL, NULL, NULL, :fson);
SELECT pg_temp.ok((SELECT count(*) FROM iam.family_member) = 0, 'Families: a member without a linked account sees nothing');
COMMIT;
RESET ROLE;
UPDATE iam.family_member SET account_status = 'LINKED', linked_user_id = :ua WHERE id = :fsonm;
SET ROLE masslak_app;
BEGIN;
SELECT sys.set_context(NULL, NULL, 'PASSENGER', NULL, NULL, NULL, NULL, :fson);
SELECT pg_temp.ok((SELECT count(*) FROM iam.family_member) = 1 AND (SELECT count(*) FROM iam.family_travel_rule) = 1,
  'Families: a linked member sees only their own record and rules');
UPDATE iam.family_member SET funding = 'FAMILY_ACCOUNT', daily_limit = 999999999 WHERE id = :fsonm;
SELECT pg_temp.ok((SELECT funding = 'HEAD_WALLET' AND daily_limit IS NULL FROM iam.family_member WHERE id = :fsonm),
  'Families: a member cannot change their own funding or limits');
COMMIT;
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'PLATFORM');
SELECT pg_temp.expect_error(format($$INSERT INTO brd.manifest_route (authority_id, scope, channel, legal_basis, status, created_by, approved_by) VALUES (%s, 'ALL', 'API_PULL', 'Law 1 of 2026', 'ACTIVE', %s, %s)$$, :auth, :uadmin, :uadmin),
  'manifest_route', 'Manifests: the officer who drafts a route cannot approve it');
INSERT INTO brd.manifest_route (authority_id, scope, channel, legal_basis, status, created_by, approved_by, approved_at)
VALUES (:auth, 'DOMESTIC', 'API_PULL', 'Law 1 of 2026', 'ACTIVE', :uadmin, :ufin, now());
SELECT pg_temp.ok(true, 'Manifests: a route goes live with a second officer''s approval');
COMMIT;
BEGIN;
SELECT sys.set_context(NULL, :ca, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM brd.manifest_route) = 0, 'Manifests: carriers do not see the authorities'' routing rules');
COMMIT;
RESET ROLE;

-- Relational design rules (1033): primary keys, references, foreign key indexes
SELECT pg_temp.ok(NOT EXISTS (
  SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p')),
  'Design: every table has a primary key');
SELECT pg_temp.ok(NOT EXISTS (
  SELECT 1 FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema')
     AND a.attnum > 0 AND NOT a.attisdropped AND a.attname LIKE '%\_id'
     AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype IN ('f','p') AND a.attnum = ANY (k.conkey))
     AND coalesce(col_description(c.oid, a.attnum), '') !~ '^(Polymorphic|External|No FK):'),
  'Design: every reference column is a foreign key or says why not');
SELECT pg_temp.ok(NOT EXISTS (
  SELECT 1 FROM pg_constraint k JOIN pg_class rc ON rc.oid = k.confrelid JOIN pg_namespace rn ON rn.oid = rc.relnamespace
   JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
   WHERE k.contype = 'f' AND NOT (rn.nspname = 'ref' AND rc.relname <> 'file_object')
     AND NOT (rc.oid = 'iam.app_user'::regclass AND a.attname ~ '(_by|_by_user_id)$|^(actor_id|reviewer_id|proposer_id|approver_id|second_approver|by_user_id|scorer_user_id)$')
     AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = k.conrelid AND i.indkey[0] = k.conkey[1])),
  'Design: every foreign key has a supporting index');


-- =====================================================================
-- Review hardening (1039): the acceptance matrix of the database architecture review, section 6
-- =====================================================================
-- Classification and RLS coverage (3.1, 3.2)
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM sys.v_security_inventory WHERE data_class IS NULL), 'Review 3.2: every table has a data class');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM sys.v_security_inventory WHERE NOT rls), 'Review 3.2: every table has row-level security');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM sys.v_security_inventory WHERE data_class IN ('TENANT_PRIVATE','USER_PRIVATE') AND tenant_path IS NULL),
  'Review 3.4: every private table has a documented owner path');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM sys.v_security_inventory WHERE data_class = 'RESTRICTED_SECURITY' AND reporting_select),
  'Review 3.2: reporting never reads restricted security tables');
SELECT pg_temp.ok((SELECT bool_and(rls_forced) FROM sys.v_security_inventory WHERE table_name IN ('iam.auth_token','iam.mfa_factor','iam.biometric_template')),
  'Review 3.2: row security is forced on credentials, factors and biometrics');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('masslak_app','masslak_api','masslak_readonly','masslak_auditor','masslak_audit')
  AND (rolsuper OR rolbypassrls)) AND NOT EXISTS (SELECT 1 FROM sys.v_security_inventory WHERE owner LIKE 'masslak_a%' OR owner = 'masslak_readonly'),
  'RLS bypass: runtime roles own no table and cannot bypass row security');
SET ROLE masslak_app;
SELECT pg_temp.expect_error('ALTER TABLE iam.auth_token DISABLE ROW LEVEL SECURITY', 'must be owner', 'RLS bypass: the application cannot switch row security off');

-- Tenant isolation sweep: carrier A sees no row of carrier B in any table that carries a company
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
DO $$
DECLARE r record; n bigint; cb bigint := (SELECT id FROM iam.party WHERE legal_name = 'Al-Sham Lines'); leaks text := '';
BEGIN
  FOR r IN SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'company_id' AND NOT a.attisdropped
            WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema','audit')
              AND has_table_privilege('masslak_app', c.oid, 'SELECT') LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I WHERE company_id = $1', r.nspname, r.relname) INTO n USING cb;
    IF n > 0 AND NOT (r.nspname = 'pricing' OR (r.nspname, r.relname) IN (('iam','role'), ('net','route'), ('ops','trip'))) THEN
      leaks := leaks || format(' %s.%s(%s)', r.nspname, r.relname, n);
    END IF;
  END LOOP;
  IF leaks <> '' THEN RAISE EXCEPTION 'FAIL  Tenant isolation sweep: carrier A sees carrier B rows in%', leaks; END IF;
  RAISE NOTICE 'PASS  Tenant isolation sweep: carrier A sees no private row of carrier B in any table';
END $$;
SELECT pg_temp.ok((SELECT count(*) FROM iam.auth_token) = 0 AND (SELECT count(*) FROM iam.mfa_factor) = 0,
  'Review 3.2: a company session reads no sign-in tokens or factors of anyone');
COMMIT;
BEGIN;
SELECT pg_temp.ok((SELECT count(*) FROM iam.app_user) = 0 AND (SELECT count(*) FROM iam.user_session) = 0
  AND (SELECT count(*) FROM iam.party WHERE party_type = 'PERSON') = 0,
  'Review 3.2: an anonymous request reads no accounts, sessions or people');
SELECT sys.set_context(NULL, NULL, 'AUTH');
SELECT pg_temp.ok((SELECT count(*) FROM iam.app_user WHERE email = 'owner@quds.test') = 1 AND (SELECT count(*) FROM fin.wallet) = 0,
  'Review 3.2: the sign-in scope reads accounts and nothing else');
COMMIT;

-- Polymorphic references become real foreign keys (3.3)
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
INSERT INTO iam.document (owner_type, owner_id, doc_type, company_id) VALUES ('VEHICLE', :va, 'REGISTRATION', :ca);
SELECT pg_temp.ok((SELECT owner_vehicle_id FROM iam.document WHERE owner_type = 'VEHICLE' AND owner_id = :va ORDER BY id DESC LIMIT 1) = :va,
  'Review 3.3: a document of a vehicle carries a real foreign key to it');
SELECT pg_temp.expect_error(format($$INSERT INTO iam.document (owner_type, owner_id, doc_type, company_id) VALUES ('VEHICLE', 987654321, 'REGISTRATION', %s)$$, :ca),
  'foreign key', 'Review 3.3: a document cannot point to a vehicle that does not exist');
COMMIT;

-- A reference never crosses companies (3.4)
RESET ROLE;
BEGIN;
INSERT INTO net.route (company_id, code, origin_station_id, dest_station_id, service_type)
SELECT :cb, 'SHAM-1', origin_station_id, dest_station_id, 'DIRECT' FROM net.route WHERE id = :route;
SELECT pg_temp.expect_error(format($$INSERT INTO ops.trip (trip_no, company_id, route_id, departure_at, arrival_at, status, seats_total, segments_count, currency, base_price)
  VALUES ('QDS900/09OCT26', %s, (SELECT id FROM net.route WHERE code = 'SHAM-1'), '2026-10-09 06:00+00', '2026-10-09 09:00+00', 'DRAFT', 40, 1, 'SYP', 1)$$, :ca),
  'TENANT_MISMATCH', 'Review 3.4: a trip cannot run on another company''s route');
COMMIT;
SET ROLE masslak_app;

-- Ledger (3.5): reversals mirror the original, balances move only through entries, reconciliation is clean
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, source_event_id) VALUES ('TOPUP','SYP','rv-1', '11111111-1111-1111-1111-111111111111') RETURNING id)
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) SELECT t.id, x.w, x.d, 1000 FROM t, (VALUES (:w_gw, 'DR'), (:w_user, 'CR')) AS x(w, d);
SELECT id AS rv1 FROM fin.ledger_txn WHERE idempotency_key = 'rv-1' \gset
SELECT pg_temp.expect_error(format($$INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, reverses_txn_id) VALUES ('REVERSAL','SYP','rv-x', %s)$$, :rv1),
  'reversal_reason', 'Review 3.5: a reversal states its reason');
SELECT pg_temp.expect_error(format($$WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, reverses_txn_id, reversal_reason)
  VALUES ('REVERSAL','SYP','rv-bad', %s, 'customer refund') RETURNING id)
  INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) SELECT t.id, x.w, x.d, 999 FROM t, (VALUES (%s,'DR'),(%s,'CR')) x(w,d)$$, :rv1, :w_user, :w_gw),
  'REVERSAL_NOT_MIRROR', 'Review 3.5: a reversal must mirror the original amounts and wallets');
WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, reverses_txn_id, reversal_reason)
           VALUES ('REVERSAL','SYP','rv-ok', :rv1, 'customer refund') RETURNING id)
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) SELECT t.id, x.w, x.d, 1000 FROM t, (VALUES (:w_user, 'DR'), (:w_gw, 'CR')) AS x(w, d);
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.ok(true, 'Review 3.5: an exact mirror reverses the transaction');
SELECT pg_temp.expect_error($$INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, source_event_id) VALUES ('TOPUP','SYP','rv-2', '11111111-1111-1111-1111-111111111111')$$,
  'ledger_txn_source_event', 'Payment replay: the same provider event posts once');
SELECT pg_temp.expect_error(format('UPDATE fin.wallet SET balance = balance + 1 WHERE id = %s', :w_user), 'BALANCE_WRITE_FORBIDDEN',
  'Review 3.5: a wallet balance never changes without a ledger entry');
SELECT pg_temp.expect_error(format($$WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('FX','USD','fx-1') RETURNING id)
  INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) SELECT t.id, x.w, x.d, 10 FROM t, (VALUES (%s,'DR'),(%s,'CR')) x(w,d)$$, :w_gw, :w_user),
  'CURRENCY_MISMATCH', 'Multi-currency: a transaction never mixes currencies');
COMMIT;
RESET ROLE;
SELECT pg_temp.ok((fin.reconcile_wallets()).mismatches = 0, 'Review 3.5: every wallet balance equals the sum of its entries');
SET ROLE masslak_app;

-- Seats (3.8): a sold segment belongs to its ticket; a passenger only holds free seats
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
SELECT id AS t214 FROM ops.trip WHERE trip_no = 'QDS214/03OCT26' \gset
INSERT INTO ops.trip_stop (trip_id, seq, station_id, kind, sched_dep) VALUES (:t214, 0, (SELECT id FROM net.station WHERE code = 'SY-DAM-C001'), 'STATION', '2026-10-03 06:00+00');
INSERT INTO ops.trip_stop (trip_id, seq, station_id, kind, sched_arr, sched_dep) VALUES (:t214, 1, (SELECT id FROM net.station WHERE code = 'SY-HMS-C001'), 'STATION', '2026-10-03 08:00+00', '2026-10-03 08:15+00');
INSERT INTO ops.trip_stop (trip_id, seq, station_id, kind, sched_arr) VALUES (:t214, 2, (SELECT id FROM net.station WHERE code = 'SY-ALP-C001'), 'STATION', '2026-10-03 11:00+00');
INSERT INTO ops.seat_segment (trip_id, seat_no, seg) VALUES (:t214, 7, 0), (:t214, 7, 1);
INSERT INTO sales.passenger (booking_id, full_name, first_name, last_name, nationality, father_name, grandfather_name, passenger_category)
SELECT id, 'Test Passenger', 'Test', 'Passenger', 'JO', NULL, NULL, 'ADULT' FROM sales.booking WHERE booking_ref = 'ABC123';
INSERT INTO sales.ticket (ticket_no, booking_id, passenger_id, trip_id, from_seq, to_seq, seat_no, fare_amount, total_amount, rules_snapshot)
SELECT 'TK-REV-1', b.id, p.id, :t214, 0, 1, 7, 100, 100, '{}' FROM sales.booking b JOIN sales.passenger p ON p.booking_id = b.id WHERE b.booking_ref = 'ABC123' LIMIT 1;
INSERT INTO sales.ticket (ticket_no, booking_id, passenger_id, trip_id, from_seq, to_seq, seat_no, fare_amount, total_amount, rules_snapshot)
SELECT 'TK-REV-3', booking_id, passenger_id, trip_id, 1, 2, 7, 100, 100, '{}' FROM sales.ticket WHERE ticket_no = 'TK-REV-1';
SELECT id AS tk1 FROM sales.ticket WHERE ticket_no = 'TK-REV-1' \gset
SELECT id AS tk3 FROM sales.ticket WHERE ticket_no = 'TK-REV-3' \gset
SELECT pg_temp.expect_error(format('UPDATE ops.seat_segment SET status = %L, ticket_id = %s WHERE trip_id = %s AND seat_no = 7 AND seg = 1', 'SOLD', :tk1, :t214),
  'SEAT_TICKET_MISMATCH', 'Seat contention: a ticket only takes the segments it covers');
UPDATE ops.seat_segment SET status = 'SOLD', ticket_id = :tk1 WHERE trip_id = :t214 AND seat_no = 7 AND seg = 0;
SELECT pg_temp.expect_error(format($$INSERT INTO sales.ticket (ticket_no, booking_id, passenger_id, trip_id, from_seq, to_seq, seat_no, fare_amount, total_amount, rules_snapshot)
  SELECT 'TK-REV-2', booking_id, passenger_id, trip_id, 0, 5, 7, 1, 1, '{}' FROM sales.ticket WHERE id = %s$$, :tk1),
  'ticket_trip_id_to_seq_fkey', 'Review 3.14: a ticket ends at a stop of its trip');
COMMIT;
BEGIN;
SELECT sys.set_context(:ua, NULL, 'PASSENGER');
WITH x AS (UPDATE ops.seat_segment SET status = 'AVAILABLE', ticket_id = NULL WHERE trip_id = :t214 AND seat_no = 7 AND seg = 0 RETURNING 1)
SELECT pg_temp.ok((SELECT count(*) FROM x) = 0, 'Seat contention: a passenger cannot free a sold seat');
UPDATE ops.seat_segment SET status = 'LOCKED', lock_token = gen_random_uuid(), lock_user_id = :ua, lock_expires_at = now() + interval '5 minutes'
 WHERE trip_id = :t214 AND seat_no = 7 AND seg = 1;
SELECT pg_temp.ok((SELECT status FROM ops.seat_segment WHERE trip_id = :t214 AND seat_no = 7 AND seg = 1) = 'LOCKED', 'Seat contention: a passenger holds a free seat for themselves');
SELECT pg_temp.expect_error(format($$UPDATE ops.seat_segment SET status = 'SOLD', ticket_id = %s WHERE trip_id = %s AND seat_no = 7 AND seg = 1$$, :tk3, :t214),
  'row-level security', 'Seat contention: only the sale, not the passenger, marks a seat sold');
COMMIT;

-- Business rules (3.14)
RESET ROLE;
BEGIN;
SELECT pg_temp.expect_error(format($$INSERT INTO iam.beneficial_owner (company_id, party_id, ownership_pct) VALUES (%s, %s, 70), (%s, %s, 40)$$, :ca, :pax, :ca, :driver),
  'OWNERSHIP_OVER_100', 'Review 3.14: beneficial owners never exceed 100%');
SELECT pg_temp.expect_error(format($$INSERT INTO sales.passenger (booking_id, full_name, first_name, last_name, nationality, passenger_category)
  SELECT id, 'Baby', 'Baby', 'One', 'JO', 'INFANT' FROM sales.booking WHERE booking_ref = 'ABC123'$$),
  'passenger_infant_birth_date', 'Review 3.14: an infant has a date of birth');
SELECT id AS adult FROM sales.passenger WHERE full_name = 'Test Passenger' ORDER BY id LIMIT 1 \gset
SELECT pg_temp.expect_error(format($$INSERT INTO sales.passenger (booking_id, full_name, first_name, last_name, nationality, passenger_category, birth_date, accompanied_by_passenger_id)
  SELECT b.id, n, n, 'Lap', 'JO', 'INFANT', current_date - 200, %s FROM sales.booking b, (VALUES ('Baby A'), ('Baby B')) v(n) WHERE b.booking_ref = 'ABC123'$$, :adult),
  'TOO_MANY_LAP_INFANTS', 'Review 3.14: one adult carries one infant on the lap');
SELECT pg_temp.expect_error(format($$UPDATE ops.trip SET seats_total = 60 WHERE id = %s$$, :t214),
  'CAPACITY_EXCEEDS_VEHICLE', 'Review 3.14: a trip never sells more seats than its vehicle has');
INSERT INTO fleet.license_record (company_id, subject_type, subject_id, license_type, license_no, issuer, issue_date, expiry_date, status)
VALUES (:ca, 'VEHICLE', :va, 'INSPECTION', 'INS-REV-1', 'Traffic', '2025-01-01', '2026-10-20', 'VALID');
SELECT pg_temp.expect_error(format($$INSERT INTO ops.trip (trip_no, company_id, route_id, vehicle_id, departure_at, arrival_at, status, seats_total, segments_count, currency, base_price)
  VALUES ('QDS901/25OCT26', %s, %s, %s, '2026-10-25 06:00+00', '2026-10-25 09:00+00', 'PUBLISHED', 40, 1, 'SYP', 1)$$, :ca, :route, :va),
  'LICENSE_EXPIRED', 'License expiry race: a trip after the vehicle''s licence ends is not published');
INSERT INTO net.line (code, name, kind, fare_regime) VALUES ('L-REV', 'Review line', 'SHUTTLE', 'REGULATED') ON CONFLICT DO NOTHING;
SELECT pg_temp.expect_error(format($$INSERT INTO net.line_permit (line_id, company_id, valid, status, permit_no) SELECT id, %s, daterange('2030-01-01','2030-12-31'), 'ACTIVE', 'P-REV' FROM net.line WHERE code = 'L-REV'$$, :ca),
  'PERMIT_OUTSIDE_VALIDITY', 'Review 3.14: a line permit is not activated outside its validity');
COMMIT;

-- Manifests (3.14): the version chain, and delivery only to the route's authority
BEGIN;
SELECT pg_temp.expect_error(format($$INSERT INTO brd.manifest (trip_id, border_point_id, version, manifest_type) VALUES (%s, %s, 2, 'PRE_ARRIVAL')$$, :t_tr, :b_in),
  'MANIFEST_CHAIN', 'Manifest retry: a new version supersedes the previous one of the same crossing');
INSERT INTO sec.authority_profile (code, name, authority_type, protocol) VALUES ('REV-A', 'Authority A', 'BORDER', 'REST'), ('REV-B', 'Authority B', 'BORDER', 'REST');
INSERT INTO brd.manifest_route (authority_id, scope, content_type, manifest_types, channel, legal_basis, status, created_by, approved_by, approved_at)
SELECT id, 'ALL', 'ALL', ARRAY['PRE_ARRIVAL'], 'API_PULL', 'Border law', 'ACTIVE', :uadmin, :ufin, now() FROM sec.authority_profile WHERE code = 'REV-A';
SELECT pg_temp.expect_error(format($$INSERT INTO brd.manifest_delivery (manifest_id, route_id, authority_id, channel)
  SELECT %s, r.id, (SELECT id FROM sec.authority_profile WHERE code = 'REV-B'), 'API_PULL' FROM brd.manifest_route r JOIN sec.authority_profile a ON a.id = r.authority_id WHERE a.code = 'REV-A'$$, :mf),
  'AUTHORITY_SCOPE', 'Authority scope: authority B never receives a manifest routed to authority A');
COMMIT;

-- Restricted reads need a purpose and a reason, and every decision is kept (3.11)
SET ROLE masslak_app;
BEGIN;
SELECT sys.set_context(:ufin, NULL, 'PLATFORM');
SELECT pg_temp.ok(NOT sec.authorize('sales.passenger.id_no', 'READ', 'SUPPORT_CASE', ''), 'Document access: a read without a reason is refused');
SELECT pg_temp.ok(sec.authorize('sales.passenger.id_no', 'READ', 'SUPPORT_CASE', 'case 2026-118, identity check'), 'Document access: a read with purpose and reason is allowed');
SELECT pg_temp.ok((SELECT count(*) FROM sec.policy_decision WHERE resource = 'sales.passenger.id_no') = 2
  AND (SELECT count(*) FROM sec.policy_decision WHERE resource = 'sales.passenger.id_no' AND decision = 'DENY') = 1,
  'Document access: allowed and refused decisions are both recorded');
COMMIT;

-- Dormant modules are closed at the database (3.10)
RESET ROLE;
UPDATE sys.setting SET value = value || '{"cargo":false}'::jsonb WHERE key = 'features';
SET ROLE masslak_app;
BEGIN;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
SELECT pg_temp.ok((SELECT count(*) FROM ship.service_product) = 0 AND (SELECT count(*) FROM ship.shipment) = 0,
  'Feature flag safety: a company reads nothing of a module that is off');
SELECT pg_temp.expect_error($$INSERT INTO ship.service_product (code, name) VALUES ('X_OFF', 'Off')$$, 'row-level security',
  'Feature flag safety: nor writes to it');
SELECT sys.set_context(:uadmin, NULL, 'PLATFORM');
SELECT pg_temp.ok((SELECT count(*) FROM ship.service_product) > 0, 'Feature flag safety: the platform still prepares a module before launch');
COMMIT;
RESET ROLE;
UPDATE sys.setting SET value = value || '{"cargo":true}'::jsonb WHERE key = 'features';

-- Keys (3.12): no new data under a retired key, one active key per purpose
BEGIN;
INSERT INTO sec.key_registry (key_ref, purpose, data_class, algorithm, status) VALUES ('kms://masslak/field/restricted/v0', 'FIELD_ENCRYPTION', 'RESTRICTED', 'AES-256-GCM', 'DECRYPT_ONLY');
SELECT pg_temp.expect_error(format($$UPDATE iam.party SET id_no_enc = '\x01', id_no_bidx = '\x02', enc_key_id = (SELECT id FROM sec.key_registry WHERE key_ref = 'kms://masslak/field/restricted/v0') WHERE id = %s$$, :pax),
  'KEY_NOT_ACTIVE', 'Review 3.12: nothing new is encrypted under a decrypt-only key');
SELECT pg_temp.expect_error($$INSERT INTO sec.key_registry (key_ref, purpose, data_class, algorithm, status) VALUES ('kms://masslak/field/restricted/v9', 'FIELD_ENCRYPTION', 'RESTRICTED', 'AES-256-GCM', 'ACTIVE')$$,
  'key_registry_one_active', 'Review 3.12: one active key per purpose and class');
COMMIT;

-- Retention and erasure (3.15)
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'PLATFORM');
INSERT INTO gov.legal_hold (scope_type, scope_id, reason, case_ref, placed_by) VALUES ('PARTY', :driver, 'Accident investigation', 'COURT-2026-44', :uadmin);
SELECT pg_temp.expect_error(format('SELECT gov.erase_party(%s)', :driver), 'LEGAL_HOLD', 'Erasure request: refused while a legal hold covers the person');
SELECT pg_temp.ok((gov.erase_party(:pax)) ->> 'party' = 'PSEUDONYMISED', 'Erasure request: the person is pseudonymised');
SELECT pg_temp.ok((SELECT legal_name LIKE 'Erased person%' AND mobile IS NULL AND email IS NULL FROM iam.party WHERE id = :pax)
  AND EXISTS (SELECT 1 FROM sales.booking WHERE booker_party_id = :pax), 'Erasure request: identity is gone, the bookings and their money stay');
COMMIT;

-- Tracking partitions and the daily job (3.7)
SELECT pg_temp.ok((sys.run_maintenance()) ->> 'wallet_mismatches' = '0', 'Restore and upkeep: the daily job runs and the ledger reconciles');
SELECT pg_temp.ok((SELECT count(*) FROM pg_inherits WHERE inhparent = 'ops.geo_event'::regclass) >= 4, 'Tracking burst: position partitions exist months ahead');

\echo '=== ALL TESTS PASSED ==='

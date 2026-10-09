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

-- A requirement changes only through an approved proposal (1048); tests use this to change one directly as owner
CREATE OR REPLACE FUNCTION pg_temp.set_requirement(p_code text, p_level text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE cid bigint; a bigint; b bigint;
BEGIN
  SELECT min(id), max(id) INTO a, b FROM iam.app_user;
  INSERT INTO sys.requirement_change (code, from_level, to_level, reason, impact, proposed_by)
  SELECT code, level, p_level, 'Test change of a requirement', '{}', a FROM sys.compliance_requirement WHERE code = p_code
  RETURNING id INTO cid;
  PERFORM set_config('masslak.requirement_change', cid::text, true);
  UPDATE sys.compliance_requirement SET level = p_level WHERE code = p_code;
  PERFORM set_config('masslak.requirement_change', '', true);
  UPDATE sys.requirement_change SET status = 'APPLIED', decided_by = b, decided_at = now() WHERE id = cid;
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
  "rail":true,"taxi":true,"car_rental":true,"contract_transport":true,"transit_passengers":true,"tracking_stations":true,
  "gov_integration":true,"shuttle_rides":true,"approved_lines":true,"route_compliance":true,"intermediary_platforms":true,
  "loyalty_partners":true,"accounting_ops":true}'::jsonb WHERE key = 'features';

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
  'wallet_balance_not_negative', 'Ledger: user wallet cannot go negative');
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
SELECT pg_temp.ok((SELECT new_values->>'password_hash' = '***' AND new_values->>'email' = '***' FROM audit.row_change
                    WHERE table_name = 'app_user' AND op = 'I' AND row_pk = :'ua'), 'Audit: password hash and contact fields redacted in change log');
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
SELECT pg_temp.expect_error($$DELETE FROM ref.trip_type WHERE code = 'SCHEDULED'$$, 'permission denied', 'Reference: the application deletes no reference values (system values are also guarded by a trigger)');
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
INSERT INTO ship.shipment_leg (shipment_id, seq, mode, carrier_company_id) VALUES (:shp, 1, 'BUS_HOLD', :cb);
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
INSERT INTO sys.city_rollout (feature_key, city_id, stage, status) SELECT 'shuttle_rides', id, 1, 'PILOT' FROM ref.city WHERE code = 'DAM';
INSERT INTO net.line (code, name, kind, fare_regime, status, city_id) SELECT 'DAM-L1', 'Damascus line 1', 'SHUTTLE', 'REGULATED', 'ACTIVE', id FROM ref.city WHERE code = 'DAM';
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

-- =====================================================================
-- Integrity audit (1040): relationships that are each valid alone but must agree with each other
-- =====================================================================
RESET ROLE;
SELECT id AS t222 FROM ops.trip WHERE trip_no = 'QDS222/03OCT26' \gset
SELECT id AS bk FROM sales.booking WHERE booking_ref = 'ABC123' \gset
BEGIN;
INSERT INTO ops.trip_stop (trip_id, seq, station_id, kind, sched_dep) VALUES (:t222, 0, :st_dam, 'STATION', '2026-10-03 08:00+00');
INSERT INTO ops.trip_stop (trip_id, seq, station_id, kind, sched_arr) VALUES (:t222, 1, (SELECT id FROM net.station WHERE code = 'SY-HMS-C001'), 'STATION', '2026-10-03 10:00+00');
SELECT pg_temp.expect_error(format($$INSERT INTO sales.ticket (ticket_no, booking_id, passenger_id, trip_id, from_seq, to_seq, seat_no, fare_amount, total_amount, rules_snapshot)
  VALUES ('TK-X-1', %s, %s, %s, 0, 1, 9, 1, 1, '{}')$$, :bk, :adult, :t222),
  'ticket_booking_trip_fk', 'Audit F-002: a ticket travels on the trip of its booking');
INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, channel_id, currency, total_amount, price_breakdown, rules_version, idempotency_key, status)
VALUES ('XYZ999', :t214, :ca, :pax, (SELECT id FROM sales.channel WHERE code = 'WEB'), 'SYP', 1, '{}', 'r1', 'b-audit', 'PENDING_PAYMENT');
SELECT pg_temp.expect_error(format($$INSERT INTO sales.ticket (ticket_no, booking_id, passenger_id, trip_id, from_seq, to_seq, seat_no, fare_amount, total_amount, rules_snapshot)
  SELECT 'TK-X-2', id, %s, %s, 0, 1, 9, 1, 1, '{}' FROM sales.booking WHERE booking_ref = 'XYZ999'$$, :adult, :t214),
  'ticket_passenger_booking_fk', 'Audit F-002: a ticket is issued to a passenger of its own booking');
INSERT INTO ops.seat_segment (trip_id, seat_no, seg) VALUES (:t222, 9, 0);
SELECT pg_temp.expect_error(format($$UPDATE ops.seat_segment SET status = 'SOLD', ticket_id = %s WHERE trip_id = %s AND seat_no = 9 AND seg = 0$$, :tk1, :t222),
  'SEAT_TICKET_MISMATCH', 'Audit F-001: a seat is sold only to a ticket of its own trip (the 1039 seat guard)');
SELECT pg_temp.ok((SELECT count(*) FROM pg_constraint WHERE convalidated AND conname IN ('seat_segment_ticket_trip_fk','ticket_booking_trip_fk','ticket_passenger_booking_fk')) = 3,
  'Audit F-001/F-002: the sale chain is also held by validated composite keys, which no trigger setting switches off');
SELECT pg_temp.expect_error(format($$INSERT INTO sales.boarding_event (ticket_id, trip_id, stop_seq, event_type, method, result) VALUES (%s, %s, 0, 'BOARD', 'AGENT_SCAN', 'OK')$$, :tk1, :t222),
  'TICKET_OTHER_TRIP', 'Audit C-03: a boarding on another trip is never recorded as valid');
INSERT INTO sales.boarding_event (ticket_id, trip_id, stop_seq, event_type, method, result) VALUES (:tk1, :t222, 0, 'DENIED', 'AGENT_SCAN', 'WRONG_TRIP');
SELECT pg_temp.ok(true, 'Audit C-03: a ticket presented on the wrong trip is still recorded, as WRONG_TRIP');
INSERT INTO brd.manifest (trip_id, border_point_id, manifest_type) VALUES (:t222, :b_in, 'PRE_ARRIVAL');
SELECT pg_temp.expect_error(format($$INSERT INTO brd.manifest_person (manifest_id, person_role, ticket_id, nationality) SELECT id, 'PASSENGER', %s, 'SY' FROM brd.manifest WHERE trip_id = %s$$, :tk1, :t222),
  'MANIFEST_TICKET_OTHER_TRIP', 'Audit C-03: a manifest lists only tickets of its own trip');
SELECT pg_temp.expect_error(format($$INSERT INTO ship.shipment_leg (shipment_id, seq, mode, carrier_company_id, trip_id) VALUES (%s, 2, 'BUS_HOLD', %s, %s)$$, :shp, :cb, :t214),
  'LEG_TRIP_OTHER_CARRIER', 'Audit C-03: a cargo leg rides a trip of its own carrier');
INSERT INTO ship.shipment_leg (shipment_id, seq, mode, carrier_company_id, trip_id) VALUES (:shp, 2, 'BUS_HOLD', :ca, :t214);
SELECT pg_temp.ok(true, 'Audit C-03: the trip operator carries the leg');
SELECT pg_temp.expect_error(format($$INSERT INTO fin.payment (provider_id, purpose, booking_id, payer_party_id, wallet_id, method, currency, amount, idempotency_key)
  SELECT p.id, 'BOOKING', %s, %s, %s, 'E_WALLET', 'SYP', 100, 'audit-pay-1' FROM fin.payment_provider p WHERE p.code = 'SANDBOX'$$, :bk, :driver, :wpax),
  'WALLET_NOT_PAYERS', 'Audit C-03: nobody pays from another person''s wallet');
INSERT INTO pricing.fare_brand (code, name, company_id, rules) VALUES ('SHAM_PLUS', 'Sham Plus', :cb, '{}');
SELECT pg_temp.expect_error(format($$UPDATE sales.ticket SET fare_brand_code = 'SHAM_PLUS' WHERE id = %s$$, :tk1),
  'TENANT_MISMATCH', 'Audit FK-0327: a ticket never sells another carrier''s fare brand');
INSERT INTO pricing.jurisdiction (country_code, level, name) VALUES ('SY', 'COUNTRY', 'Audit Syria');
INSERT INTO pricing.jurisdiction (country_code, level, name, parent_id) SELECT 'SY', 'REGION', 'Audit Damascus', id FROM pricing.jurisdiction WHERE name = 'Audit Syria';
SELECT pg_temp.expect_error($$UPDATE pricing.jurisdiction SET parent_id = (SELECT id FROM pricing.jurisdiction WHERE name = 'Audit Damascus') WHERE name = 'Audit Syria'$$,
  'JURISDICTION_CYCLE', 'Audit FK-0414: tax jurisdictions form a tree without loops');
ROLLBACK;

-- Tenant guards on the references that had none; a vehicle follows ownership or an active lease (F-003, F-004)
BEGIN;
SELECT pg_temp.expect_error(format($$INSERT INTO ops.incident (company_id, vehicle_id, type, severity, occurred_at) VALUES (%s, %s, 'BREAKDOWN', 'MINOR', now())$$, :ca, :vb),
  'VEHICLE_NOT_OWNED_OR_LEASED', 'Audit F-004: an incident cannot name another company''s vehicle');
INSERT INTO fleet.vehicle_lease (vehicle_id, owner_party_id, lessee_company_id, contract_no, period, status)
VALUES (:vb, :cb, :ca, 'LEASE-AUDIT-1', daterange(current_date - 1, current_date + 90), 'ACTIVE');
INSERT INTO ops.incident (company_id, vehicle_id, type, severity, occurred_at) VALUES (:ca, :vb, 'BREAKDOWN', 'MINOR', now());
SELECT pg_temp.ok(true, 'Audit F-004: a leased vehicle serves its lessee (a plain same-company key would refuse it)');
SELECT pg_temp.expect_error(format($$INSERT INTO fleet.driving_hours_log (party_id, company_id, kind, started_at) VALUES (%s, %s, 'DRIVING', now())$$, :driver, :cb),
  'TENANT_MISMATCH', 'Audit F-004: another company cannot log hours for a driver who is not theirs');
-- the guards are not bypassed by bulk loading: COPY fires them like INSERT
SELECT pg_temp.expect_error(format($$COPY ops.incident (company_id, vehicle_id, type, severity, occurred_at) FROM PROGRAM 'printf "%s,%s,COLLISION,MINOR,2026-10-01 10:00+00\n"' WITH (FORMAT csv)$$, :cb, :va),
  'VEHICLE_NOT_OWNED_OR_LEASED', 'Audit F-003: bulk loading (COPY) is checked like every insert');
ROLLBACK;

-- Every tenant guard is a row trigger that runs before insert and update, enabled and never deferred (F-003)
SELECT pg_temp.ok((SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                    WHERE NOT t.tgisinternal AND p.proname IN ('tg_same_company','tg_vehicle_of_company')) >= 110
  AND NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                   WHERE NOT t.tgisinternal AND p.proname IN ('tg_same_company','tg_vehicle_of_company','tg_boarding_ticket_trip','tg_manifest_person_trip','tg_leg_trip_carrier','tg_payment_wallet_owner')
                     AND (t.tgtype & 1 = 0 OR t.tgtype & 2 = 0 OR t.tgtype & 4 = 0 OR t.tgtype & 16 = 0 OR t.tgenabled <> 'O' OR t.tgdeferrable)),
  'Audit F-003: tenant guards are row-level, BEFORE INSERT OR UPDATE, enabled and not deferrable');

-- One COMPANY wallet per company and currency (H-02)
BEGIN;
INSERT INTO fin.wallet (owner_party_id, company_id, wallet_type, currency) VALUES (NULL, :ca, 'COMPANY', 'USD');
SELECT pg_temp.expect_error(format($$INSERT INTO fin.wallet (owner_party_id, company_id, wallet_type, currency) VALUES (NULL, %s, 'COMPANY', 'USD')$$, :ca),
  'wallet_company_currency_uq', 'Audit H-02: one company wallet per company and currency');
ROLLBACK;

-- Governance: no new two-way dependency between schemas without review (H-07), no JSONB in security or keys (M-02)
SELECT pg_temp.ok(NOT EXISTS (
  SELECT 1 FROM sys.v_schema_dependency a JOIN sys.v_schema_dependency b ON a.from_schema = b.to_schema AND a.to_schema = b.from_schema
   WHERE a.from_schema < a.to_schema
     AND (a.from_schema || '<->' || a.to_schema) <> ALL (ARRAY[
       'acct<->sales','fin<->iam','fin<->ops','fin<->pricing','fin<->sales','fin<->ship','fleet<->iam','fleet<->ops','fleet<->ptn',
       'frt<->ship','gov<->iam','gov<->sec','iam<->net','iam<->ops','iam<->ref','iam<->sec','ops<->sales','ops<->sec','pricing<->sales',
       'ref<->sec','sales<->sec'])),
  'Audit H-07: no new two-way dependency between schemas outside the reviewed baseline');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_policy WHERE coalesce(pg_get_expr(polqual, polrelid), '') || coalesce(pg_get_expr(polwithcheck, polrelid), '') ~ '->')
  AND NOT EXISTS (SELECT 1 FROM pg_index WHERE pg_get_indexdef(indexrelid) ~ '->>|->')
  AND NOT EXISTS (SELECT 1 FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
                   WHERE c.contype = 'f' AND a.atttypid = 'jsonb'::regtype),
  'Audit M-02: no security policy, key or index depends on a JSONB field');
SELECT pg_temp.ok(obj_description('ops.seat_lock'::regclass) LIKE 'Audit trail%' AND obj_description('ops.seat_lock'::regclass) NOT LIKE '%memory%',
  'Audit C-01: the seat hold has one record, the LOCKED seat segment');
SET ROLE masslak_app;

-- Project phases (1041): every table has a phase, and no table needs a row of a later phase
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                               WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema')
                                 AND NOT EXISTS (SELECT 1 FROM sys.table_phase t WHERE t.table_name = n.nspname || '.' || c.relname))
  AND NOT EXISTS (SELECT 1 FROM sys.table_phase t WHERE to_regclass(t.table_name) IS NULL),
  'Phases: every table belongs to exactly one project phase, and the map names no missing table');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM sys.v_phase_forward_reference WHERE required),
  'Phases: no table of an earlier phase requires a row of a later phase (forward references are optional readiness columns)');
SELECT pg_temp.ok((SELECT tables FROM sys.v_phase_summary WHERE code = '1A') > 0 AND (SELECT tables FROM sys.v_phase_summary WHERE code = '1B') > 0,
  'Phases: Phase 1 is split into releases 1A and 1B');

-- Owner decisions (1042): the shuttle opens city by city; the contact center and the AI assistant come later
RESET ROLE;
BEGIN;
SELECT pg_temp.expect_error($$INSERT INTO net.line (code, name, kind, fare_regime, status, city_id) SELECT 'ALP-L1', 'Aleppo line 1', 'SHUTTLE', 'REGULATED', 'ACTIVE', id FROM ref.city WHERE code = 'ALP'$$,
  'CITY_NOT_OPEN', 'Phases: a shuttle line is not activated in a city the shuttle has not opened yet');
INSERT INTO net.line (code, name, kind, fare_regime, status, city_id) SELECT 'ALP-L1', 'Aleppo line 1', 'SHUTTLE', 'REGULATED', 'DRAFT', id FROM ref.city WHERE code = 'ALP';
INSERT INTO sys.city_rollout (feature_key, city_id, stage, status) SELECT 'shuttle_rides', id, 2, 'OPEN' FROM ref.city WHERE code = 'ALP';
UPDATE net.line SET status = 'ACTIVE' WHERE code = 'ALP-L1';
SELECT pg_temp.ok((SELECT status FROM net.line WHERE code = 'ALP-L1') = 'ACTIVE', 'Phases: once its city stage opens, the line is activated');
ROLLBACK;
SELECT pg_temp.ok((SELECT count(*) FROM sys.table_phase WHERE phase_code = 'CS' AND (table_name LIKE 'crm.call%' OR table_name LIKE 'crm.ai%')) = 14
  AND (SELECT phase_code FROM sys.table_phase WHERE table_name = 'crm.case') = '1A',
  'Phases: support starts on cases (WhatsApp, email); the contact center and the AI assistant come in a later phase');
SET ROLE masslak_app;

-- Route compliance (1043): requirements switched by configuration, vehicles bound to their line, violations and reporting
RESET ROLE;
BEGIN;
SELECT pg_temp.ok((SELECT level FROM sys.compliance_requirement WHERE code = 'route.vehicle_binding.shuttle') = 'REQUIRED'
  AND (SELECT level FROM sys.compliance_requirement WHERE code = 'route.report.authority') = 'OFF'
  AND (SELECT level FROM sys.compliance_requirement WHERE code = 'tracking.gps_device') = 'OFF'
  AND NOT EXISTS (SELECT 1 FROM sys.compliance_requirement WHERE domain = 'LICENSE' AND level = 'REQUIRED'),
  'Compliance: licences, tracking devices and reporting are prepared but not imposed; only shuttle vehicles are bound to their line');
INSERT INTO sys.city_rollout (feature_key, city_id, stage, status) SELECT 'shuttle_rides', id, 1, 'OPEN' FROM ref.city WHERE code = 'DAM'
  ON CONFLICT (feature_key, city_id) DO UPDATE SET status = 'OPEN';
INSERT INTO net.line (code, name, kind, fare_regime, status, city_id) SELECT 'DAM-T1', 'Damascus test line', 'SHUTTLE', 'REGULATED', 'ACTIVE', id FROM ref.city WHERE code = 'DAM';
INSERT INTO net.line_version (line_id, version, geometry, distance_km, typical_min, status)
SELECT id, 1, '{"type":"LineString","coordinates":[[36.29,33.51],[36.31,33.52]]}', 6.5, 25, 'ACTIVE' FROM net.line WHERE code = 'DAM-T1';
INSERT INTO net.line_permit (line_id, company_id, valid, max_vehicles, status)
SELECT id, :ca, '[2026-01-01,2027-01-01)', 1, 'ACTIVE' FROM net.line WHERE code = 'DAM-T1';
SELECT id AS lv1 FROM net.line_version WHERE line_id = (SELECT id FROM net.line WHERE code = 'DAM-T1') \gset
SELECT id AS lp1 FROM net.line_permit WHERE line_id = (SELECT id FROM net.line WHERE code = 'DAM-T1') \gset
SELECT pg_temp.expect_error(format($$INSERT INTO ops.trip (trip_no, company_id, route_id, vehicle_id, line_version_id, trip_type, departure_at, arrival_at, status, seats_total, segments_count, currency, base_price)
  VALUES ('T1-0001', %s, %s, %s, %s, 'SHUTTLE', '2026-10-06 06:00+00', '2026-10-06 06:30+00', 'PUBLISHED', 48, 1, 'SYP', 50000)$$, :ca, :route, :va, :lv1),
  'VEHICLE_NOT_BOUND_TO_LINE', 'Compliance: a shuttle trip on an approved line needs a vehicle bound to that line');
INSERT INTO fleet.line_permit_vehicle (permit_id, company_id, vehicle_id, valid) VALUES (:lp1, :ca, :va, '[2026-10-01,2027-01-01)');
INSERT INTO ops.trip (trip_no, company_id, route_id, vehicle_id, line_version_id, trip_type, departure_at, arrival_at, status, seats_total, segments_count, currency, base_price)
VALUES ('T1-0001', :ca, :route, :va, :lv1, 'SHUTTLE', '2026-10-06 06:00+00', '2026-10-06 06:30+00', 'PUBLISHED', 48, 1, 'SYP', 50000);
SELECT pg_temp.ok((SELECT compliance_source FROM ops.trip WHERE trip_no = 'T1-0001') = 'REGULATED_LINE',
  'Compliance: once bound, the trip runs and carries the obligation to keep to the approved line');
INSERT INTO fleet.vehicle (company_id, vehicle_type, plate_no, chassis_no, passenger_seats, owner_party_id, status)
VALUES (:ca, 'MINIBUS', '777001', 'CHS-T1-2', 24, :ca, 'ACTIVE');
SELECT pg_temp.expect_error(format($$INSERT INTO fleet.line_permit_vehicle (permit_id, company_id, vehicle_id, valid)
  SELECT %s, %s, id, '[2026-10-01,2027-01-01)' FROM fleet.vehicle WHERE chassis_no = 'CHS-T1-2'$$, :lp1, :ca),
  'PERMIT_VEHICLE_LIMIT', 'Compliance: the permit''s vehicle limit is enforced');
SELECT pg_temp.expect_error(format($$INSERT INTO fleet.line_permit_vehicle (permit_id, company_id, vehicle_id, valid) VALUES (%s, %s, %s, '[2026-10-01,2027-01-01)')$$, :lp1, :ca, :vb),
  'VEHICLE_NOT_OWNED_OR_LEASED', 'Compliance: a permit cannot bind another carrier''s vehicle');
-- off duty: recorded, never reportable
INSERT INTO ops.route_violation (company_id, vehicle_id, compliance_source, line_version_id, kind, tracking_source, started_at, in_service, driver_warned_at, alarm_started_at, status)
VALUES (:ca, :va, 'REGULATED_LINE', :lv1, 'OFF_ROUTE', 'DRIVER_APP', '2026-10-06 05:00+00', false, '2026-10-06 05:00:30+00', '2026-10-06 05:02+00', 'CONFIRMED');
SELECT id AS rv1 FROM ops.route_violation ORDER BY id DESC LIMIT 1 \gset
SELECT pg_temp.expect_error(format($$INSERT INTO ops.violation_report (violation_id, authority, channel) VALUES (%s, 'TRAFFIC_POLICE', 'API')$$, :rv1),
  'NOT_REPORTABLE', 'Compliance: nothing is reported to the authorities while reporting is not required');
SELECT pg_temp.set_requirement('route.report.authority', 'REQUIRED');
SELECT pg_temp.expect_error(format($$INSERT INTO ops.violation_report (violation_id, authority, channel) VALUES (%s, 'TRAFFIC_POLICE', 'API')$$, :rv1),
  'NOT_REPORTABLE', 'Compliance: a vehicle off duty (no running trip, no passengers) is not reported');
SELECT pg_temp.expect_error(format($$UPDATE ops.route_violation SET status = 'REPORTED' WHERE id = %s$$, :rv1),
  'NOT_REPORTABLE', 'Compliance: an off-duty violation cannot be marked reported');
-- in service: the running trip makes it reportable once confirmed
UPDATE ops.trip SET status = 'DEPARTED' WHERE trip_no = 'T1-0001';
INSERT INTO ops.route_violation (company_id, vehicle_id, trip_id, compliance_source, line_version_id, kind, tracking_source, started_at, in_service, status)
SELECT :ca, :va, id, 'REGULATED_LINE', :lv1, 'OFF_ROUTE', 'DRIVER_APP', '2026-10-06 06:10+00', false, 'CONFIRMED' FROM ops.trip WHERE trip_no = 'T1-0001';
SELECT id AS rv2 FROM ops.route_violation ORDER BY id DESC LIMIT 1 \gset
SELECT pg_temp.ok((SELECT in_service FROM ops.route_violation WHERE id = :rv2), 'Compliance: a violation during a running trip counts as in service');
INSERT INTO ops.violation_report (violation_id, authority, channel) VALUES (:rv2, 'TRAFFIC_POLICE', 'API');
SELECT pg_temp.ok(true, 'Compliance: a confirmed violation in service is reported once the regulator requires it');
SELECT pg_temp.expect_error(format($$UPDATE ops.route_violation SET evidence = '{"edited": true}' WHERE id = %s$$, :rv2),
  'VIOLATION_EVIDENCE_FROZEN', 'Compliance: the evidence of a reviewed violation cannot change');
-- PostGIS (1045): distance from the binding route, diversions, and valid shapes for binding routes
SELECT pg_temp.ok((SELECT NOT off_route AND distance_m < 50 FROM ops.route_distance_m((SELECT id FROM ops.trip WHERE trip_no = 'T1-0001'), 33.515, 36.30))
  AND (SELECT off_route AND distance_m > 1000 FROM ops.route_distance_m((SELECT id FROM ops.trip WHERE trip_no = 'T1-0001'), 33.60, 36.30)),
  'PostGIS: a position on the approved line is inside its corridor, kilometres away is off route');
INSERT INTO net.line_diversion (line_id, active, geometry, reason, issued_by)
SELECT id, tstzrange(now() - interval '1 hour', now() + interval '1 day'), '{"type":"LineString","coordinates":[[36.30,33.515],[36.30,33.60]]}', 'ROAD_CLOSED', 'Damascus traffic police'
  FROM net.line WHERE code = 'DAM-T1';
SELECT pg_temp.ok((SELECT NOT off_route FROM ops.route_distance_m((SELECT id FROM ops.trip WHERE trip_no = 'T1-0001'), 33.60, 36.30)),
  'PostGIS: a trip following the regulator''s active diversion is not off route');
SELECT pg_temp.expect_error($$INSERT INTO net.line_version (line_id, version, geometry, distance_km, typical_min, status) SELECT id, 2, '{"type":"LineString","coordinates":[[36.29,33.51]]}', 6.5, 25, 'APPROVED' FROM net.line WHERE code = 'DAM-T1'$$,
  'ROUTE_SHAPE_INVALID', 'PostGIS: a line version is approved only with a valid route line');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM net.stations_near(33.5138, 36.2765, 5000)), 'PostGIS: stations near a point are found by spatial index');
ROLLBACK;

-- School transport (1044): operators under licence, pupils and guardians, hand-over and the empty-bus check
BEGIN;
UPDATE sys.setting SET value = value || '{"school_transport": true}'::jsonb WHERE key = 'features';
INSERT INTO iam.party (party_type, legal_name, birth_date) VALUES ('ENTITY','Al-Amal School', NULL), ('COMPANY','Solo Driver', NULL),
  ('PERSON','Pupil One', '2017-03-01'), ('PERSON','Pupil Father', '1985-05-05'), ('PERSON','Not A Receiver', '1990-01-01'),
  ('PERSON','Blocked Relative', '1980-01-01');
SELECT id AS school_party FROM iam.party WHERE legal_name = 'Al-Amal School' \gset
SELECT id AS solo FROM iam.party WHERE legal_name = 'Solo Driver' \gset
SELECT id AS pupil FROM iam.party WHERE legal_name = 'Pupil One' \gset
SELECT id AS father FROM iam.party WHERE legal_name = 'Pupil Father' \gset
SELECT id AS stranger2 FROM iam.party WHERE legal_name = 'Not A Receiver' \gset
SELECT id AS blocked FROM iam.party WHERE legal_name = 'Blocked Relative' \gset
INSERT INTO iam.company (id, company_type, approval_status) VALUES (:school_party, 'SCHOOL', 'APPROVED'), (:solo, 'CARRIER', 'APPROVED');
INSERT INTO sch.school (company_id, sector, city_id, status) SELECT :school_party, 'PRIVATE', id, 'ACTIVE' FROM ref.city WHERE code = 'DAM';
SELECT id AS school FROM sch.school WHERE company_id = :school_party \gset
SELECT pg_temp.expect_error(format($$INSERT INTO sch.operator (company_id, operator_kind, school_transport_license_no, license_issuer) VALUES (%s, 'INDIVIDUAL', 'ST-1001', 'Transport authority')$$, :solo),
  'OPERATOR_KIND_MISMATCH', 'School: an individual operator must be an individual owner-driver account');
SELECT pg_temp.expect_error(format($$INSERT INTO sch.operator (company_id, operator_kind, school_transport_license_no, license_issuer) VALUES (%s, 'TRANSPORT_COMPANY', NULL, 'Transport authority')$$, :ca),
  'school_transport_license_no', 'School: an operator cannot exist without its school transport licence number');
INSERT INTO sch.operator (company_id, operator_kind, school_id, school_transport_license_no, license_issuer, status, approved_by)
VALUES (:school_party, 'SCHOOL_OWNED', :school, 'ST-2001', 'Ministry of education', 'APPROVED', :uadmin);
SELECT pg_temp.set_requirement('license.company.school_transport', 'REQUIRED');
SELECT pg_temp.expect_error(format($$INSERT INTO sch.operator (company_id, operator_kind, school_transport_license_no, license_issuer, status, approved_by) VALUES (%s, 'TRANSPORT_COMPANY', 'ST-3001', 'Transport authority', 'APPROVED', %s)$$, :ca, :uadmin),
  'REQUIREMENT_UNMET', 'School: once the government imposes the company licence, approval needs a verified licence record');
SELECT pg_temp.set_requirement('license.company.school_transport', 'OPTIONAL');
INSERT INTO sch.operator (company_id, operator_kind, school_transport_license_no, license_issuer, status, approved_by)
VALUES (:ca, 'TRANSPORT_COMPANY', 'ST-3001', 'Transport authority', 'APPROVED', :uadmin);
SELECT pg_temp.ok(true, 'School: while optional, the operator is approved on its licence number alone');
SELECT id AS op_school FROM sch.operator WHERE company_id = :school_party \gset
SELECT id AS op_co FROM sch.operator WHERE company_id = :ca \gset
-- the guardian defines the pupil from their own account
INSERT INTO iam.family (head_party_id, name) VALUES (:father, 'Pupil family');
INSERT INTO iam.family_member (family_id, party_id, relation, first_name, last_name, birth_date)
SELECT id, :pupil, 'SON', 'Pupil', 'One', '2017-03-01' FROM iam.family WHERE head_party_id = :father;
INSERT INTO sch.student (school_id, party_id, family_member_id) SELECT :school, :pupil, id FROM iam.family_member WHERE party_id = :pupil;
SELECT id AS stu FROM sch.student WHERE party_id = :pupil \gset
INSERT INTO sch.student_guardian (student_id, party_id, role, relation, is_primary) VALUES (:stu, :father, 'GUARDIAN', 'FATHER', true);
INSERT INTO sch.student_guardian (student_id, party_id, role, relation, can_receive, receive_blocked) VALUES (:stu, :blocked, 'RECEIVER', 'RELATIVE', false, true);
SELECT pg_temp.ok(iam.is_minor('2017-03-01') AND NOT iam.is_minor('1985-05-05'), 'School: minors are told apart by the configured age of majority');
SELECT pg_temp.expect_error(format($$INSERT INTO sch.contract (operator_id, company_id, contract_kind, school_id, guardian_party_id, school_year, valid, pricing_mode, school_transport_license_no, license_authority)
  VALUES (%s, %s, 'GUARDIAN_COMPANY', %s, %s, '2026-2027', '[2026-09-01,2027-06-30)', 'MONTHLY', 'ST-2001', 'Ministry of education')$$, :op_school, :school_party, :school, :father),
  'CONTRACT_KIND_MISMATCH', 'School: a guardian contracts with a company, not with a school''s own fleet');
INSERT INTO sch.contract (operator_id, company_id, contract_kind, school_id, guardian_party_id, school_year, valid, pricing_mode, price, school_transport_license_no, license_authority, status, signed_at)
VALUES (:op_co, :ca, 'GUARDIAN_COMPANY', :school, :father, '2026-2027', '[2026-09-01,2027-06-30)', 'MONTHLY', 2500000, 'ST-3001', 'Transport authority', 'ACTIVE', now());
SELECT id AS con FROM sch.contract WHERE operator_id = :op_co \gset
INSERT INTO sch.route (company_id, operator_id, school_id, code, direction, vehicle_id, driver_party_id, depart_time, status)
VALUES (:ca, :op_co, :school, 'AMAL-PM-1', 'FROM_SCHOOL', :va, :driver, '13:30', 'ACTIVE');
SELECT id AS sroute FROM sch.route WHERE code = 'AMAL-PM-1' \gset
INSERT INTO sch.route_stop (route_id, seq, label, lat, lng) VALUES (:sroute, 1, 'Mezzeh gate', 33.50, 36.25);
INSERT INTO sch.enrollment (contract_id, student_id, from_route_id, from_stop_seq, status) VALUES (:con, :stu, :sroute, 1, 'ACTIVE');
SELECT pg_temp.ok((SELECT guardian_consent FROM sch.enrollment WHERE contract_id = :con) = 'GIVEN',
  'School: the guardian who signed the contract has consented to the transport');
INSERT INTO sch.run (route_id, run_date, status) VALUES (:sroute, '2026-10-12', 'IN_PROGRESS');
SELECT id AS srun FROM sch.run WHERE route_id = :sroute \gset
SELECT id AS enr FROM sch.enrollment WHERE contract_id = :con \gset
INSERT INTO sch.attendance (run_id, enrollment_id, event, occurred_at, source) VALUES (:srun, :enr, 'BOARD', '2026-10-12 13:31+00', 'QR');
SELECT pg_temp.expect_error(format($$INSERT INTO sch.attendance (run_id, enrollment_id, event, occurred_at, source) VALUES (%s, %s, 'ALIGHT', '2026-10-12 14:00+00', 'ATTENDANT')$$, :srun, :enr),
  'RECEIVER_REQUIRED', 'School: a young pupil does not leave the homeward bus without a receiver');
SELECT pg_temp.expect_error(format($$INSERT INTO sch.attendance (run_id, enrollment_id, event, received_by_party_id, occurred_at, source) VALUES (%s, %s, 'HANDED_OVER', %s, '2026-10-12 14:00+00', 'ATTENDANT')$$, :srun, :enr, :stranger2),
  'RECEIVER_NOT_AUTHORIZED', 'School: the pupil is not handed to a stranger');
SELECT pg_temp.expect_error(format($$INSERT INTO sch.attendance (run_id, enrollment_id, event, received_by_party_id, occurred_at, source) VALUES (%s, %s, 'HANDED_OVER', %s, '2026-10-12 14:00+00', 'ATTENDANT')$$, :srun, :enr, :blocked),
  'RECEIVER_NOT_AUTHORIZED', 'School: the pupil is not handed to a person under a custody restriction');
SELECT pg_temp.expect_error(format($$UPDATE sch.run SET status = 'COMPLETED' WHERE id = %s$$, :srun),
  'CHILD_STILL_ON_BOARD', 'School: a run cannot close while a pupil is still on the bus');
INSERT INTO sch.attendance (run_id, enrollment_id, event, received_by_party_id, occurred_at, source) VALUES (:srun, :enr, 'HANDED_OVER', :father, '2026-10-12 14:01+00', 'ATTENDANT');
SELECT pg_temp.expect_error(format($$UPDATE sch.run SET status = 'COMPLETED' WHERE id = %s$$, :srun),
  'SWEEP_CHECK_MISSING', 'School: a run closes only after the check that no child is left on the bus');
UPDATE sch.run SET status = 'COMPLETED', sweep_checked_at = '2026-10-12 14:20+00', sweep_checked_by = :driver WHERE id = :srun;
SELECT pg_temp.ok((SELECT completed_at IS NOT NULL FROM sch.run WHERE id = :srun), 'School: with everyone handed over and the bus checked, the run closes');
-- the school's own fleet enrols its pupils; the guardian's approval in the app is switched on later
INSERT INTO sch.contract (operator_id, company_id, contract_kind, school_id, school_year, valid, pricing_mode, school_transport_license_no, license_authority, status)
VALUES (:op_school, :school_party, 'SCHOOL_ASSIGNED', :school, '2026-2027', '[2026-09-01,2027-06-30)', 'YEAR', 'ST-2001', 'Ministry of education', 'ACTIVE');
SELECT id AS con2 FROM sch.contract WHERE operator_id = :op_school \gset
INSERT INTO sch.enrollment (contract_id, student_id, status) VALUES (:con2, :stu, 'PENDING');
SELECT pg_temp.set_requirement('school.guardian_consent', 'REQUIRED');
SELECT pg_temp.expect_error(format($$UPDATE sch.enrollment SET status = 'ACTIVE', to_route_id = NULL WHERE contract_id = %s$$, :con2),
  'CONSENT_MISSING', 'School: once required, a school-assigned pupil rides only after the guardian approves in the app');
-- isolation: another carrier sees nothing, the guardian sees their child
SET ROLE masslak_app;
SELECT sys.set_context(NULL, :cb, 'COMPANY');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM sch.student) AND NOT EXISTS (SELECT 1 FROM sch.contract),
  'School: another carrier sees no pupil and no contract');
SELECT sys.set_context(NULL, NULL, 'PASSENGER', NULL, NULL, NULL, NULL, :father);
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM sch.student WHERE id = :stu) AND EXISTS (SELECT 1 FROM sch.attendance),
  'School: the guardian sees their child and the hand-over record');
SELECT sys.set_context(NULL, NULL, 'PASSENGER', NULL, NULL, NULL, NULL, :stranger2);
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM sch.student), 'School: another passenger sees no pupil');
RESET ROLE;
ROLLBACK;
SELECT pg_temp.ok((SELECT data_class FROM sys.table_class WHERE table_name = 'sch.student') = 'USER_PRIVATE'
  AND (SELECT phase_code FROM sys.table_phase WHERE table_name = 'sch.student') = 'SCH'
  AND (SELECT phase_code FROM sys.table_phase WHERE table_name = 'ops.route_violation') = '2',
  'Phases: school transport is its own phase and its pupils'' data is classified personal; route compliance is in Phase 2');
SET ROLE masslak_app;

-- Third-party audit hardening (1046)
RESET ROLE;
BEGIN;
INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON', 'Person As Carrier'), ('PERSON', 'Owner Driver');
SELECT pg_temp.expect_error($$INSERT INTO iam.company (id, company_type) SELECT id, 'CARRIER' FROM iam.party WHERE legal_name = 'Person As Carrier'$$,
  'COMPANY_PARTY_TYPE', 'Audit R-06: a carrier company cannot sit on a person''s record');
INSERT INTO iam.company (id, company_type) SELECT id, 'INDIVIDUAL_OPERATOR' FROM iam.party WHERE legal_name = 'Owner Driver';
SELECT pg_temp.ok(true, 'Audit R-06: an individual owner-driver''s company sits on their person record');
SELECT pg_temp.expect_error(format($$UPDATE iam.party SET party_type = 'PERSON' WHERE id = %s$$, :ca),
  'COMPANY_PARTY_TYPE', 'Audit R-06: a company''s party cannot be turned into a person');
-- R-04: no clear contact data for persons, passengers or family members
SELECT pg_temp.expect_error($$INSERT INTO iam.party (party_type, legal_name, mobile) VALUES ('PERSON', 'Clear Phone', '+963944000111')$$,
  'party_person_contact_sealed', 'Audit R-04: a person''s phone is never stored in clear on the party');
INSERT INTO iam.party (party_type, legal_name, email) VALUES ('COMPANY', 'Contact Company', 'desk@contact.test');
SELECT pg_temp.ok(true, 'Audit R-04: a company keeps its business contact');
SELECT pg_temp.expect_error(format($$UPDATE sales.passenger SET mobile = '+963944000111' WHERE id = (SELECT min(id) FROM sales.passenger)$$),
  'passenger_mobile_sealed', 'Audit R-04: a passenger''s phone is only stored encrypted');
SELECT pg_temp.ok(NOT has_column_privilege('masslak_readonly', 'iam.app_user', 'email', 'SELECT')
  AND NOT has_column_privilege('masslak_auditor', 'iam.app_user', 'mobile', 'SELECT')
  AND has_column_privilege('masslak_readonly', 'iam.app_user', 'status', 'SELECT')
  AND NOT has_column_privilege('masslak_readonly', 'iam.party', 'mobile', 'SELECT'),
  'Audit R-04: reporting and audit roles read accounts and parties without their contact fields');
SELECT pg_temp.ok(audit.redact('{"mobile": "+963944000111", "email": "a@b.test", "status": "ACTIVE"}') =
  '{"mobile": "***", "email": "***", "status": "ACTIVE"}'::jsonb, 'Audit R-04: the change log masks contact fields');
-- R-03: every (type, id) reference is registered, and the sweep finds and reports orphans
SELECT pg_temp.ok(NOT EXISTS (
  SELECT 1 FROM information_schema.columns a JOIN information_schema.columns b
    ON a.table_schema = b.table_schema AND a.table_name = b.table_name AND b.column_name ~ '_type$'
    AND a.column_name IN (regexp_replace(b.column_name, '_type$', '_id'), regexp_replace(b.column_name, '_type$', '_ref_id'))
   WHERE a.data_type IN ('bigint','integer') AND a.table_schema NOT IN ('pg_catalog','information_schema','gis')
     AND to_regclass(a.table_schema || '.' || a.table_name) IN (SELECT c.oid FROM pg_class c WHERE c.relkind IN ('r','p') AND NOT c.relispartition)
     AND NOT EXISTS (SELECT 1 FROM sys.polymorphic_reference r WHERE r.table_name = a.table_schema || '.' || a.table_name AND r.type_col = b.column_name)),
  'Audit R-03: every polymorphic reference is registered with its targets, owner and reason');
-- since 1048 a missing row is refused when written; the probe plays a row whose trip disappeared later
ALTER TABLE gov.legal_hold DISABLE TRIGGER scope_type_checked;
INSERT INTO gov.legal_hold (scope_type, scope_id, reason, case_ref, placed_by) VALUES ('TRIP', 987654321, 'Orphan probe', 'TEST-1', :uadmin);
ALTER TABLE gov.legal_hold ENABLE TRIGGER scope_type_checked;
SELECT pg_temp.ok((SELECT orphans FROM sys.find_orphans() WHERE table_name = 'gov.legal_hold' AND type_value = 'TRIP') = 1,
  'Audit R-03: the sweep finds a reference to a missing row');
SELECT sys.run_orphan_check() AS swept \gset
SELECT pg_temp.ok(:swept >= 1 AND EXISTS (SELECT 1 FROM sys.outbox_event WHERE event_type = 'integrity.orphans_found'),
  'Audit R-03: orphans raise an alert through the outbox');
-- R-14: a later phase is closed in the database while its switch is off
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM sys.table_phase tp JOIN sys.project_phase pp ON pp.code = tp.phase_code
                                WHERE pp.feature_keys <> '{}' AND split_part(tp.table_name, '.', 1) NOT IN (SELECT schema_name FROM sys.module_gate)
                                  AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname || '.' || p.tablename = tp.table_name AND p.policyname = 'phase_gate')),
  'Audit R-14: every table of a switched phase is closed in the database, not only by the application');
INSERT INTO net.corridor (code, name, country_code, path, status)
VALUES ('SY-JO-TEST', 'Test corridor', 'SY', '{"type":"LineString","coordinates":[[36.29,33.51],[36.10,32.62]]}', 'ACTIVE');
SELECT id AS corridor FROM net.corridor WHERE code = 'SY-JO-TEST' \gset
UPDATE sys.setting SET value = value || '{"transit_passengers": false}'::jsonb WHERE key = 'features';
SET LOCAL ROLE masslak_app;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM net.corridor), 'Audit R-14: a company sees nothing of a phase whose switch is off');
RESET ROLE;
UPDATE sys.setting SET value = value || '{"shuttle_rides": false, "approved_lines": false, "shuttle_subscriptions": false, "route_compliance": false}'::jsonb
 WHERE key = 'features';
SET LOCAL ROLE masslak_app;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
SELECT pg_temp.expect_error(format($$INSERT INTO fleet.tracking_device (company_id, vehicle_id, provider, serial_no, installed) VALUES (%s, %s, 'Test GPS', 'SN-1', '[2026-10-01,)')$$, :ca, :va),
  'phase_gate', 'Audit R-14: nor writes to a closed phase, even to its own rows');
RESET ROLE;
UPDATE sys.setting SET value = value || '{"shuttle_rides": true, "approved_lines": true, "route_compliance": true}'::jsonb WHERE key = 'features';
RESET ROLE;
UPDATE sys.setting SET value = value || '{"transit_passengers": true}'::jsonb WHERE key = 'features';
SET LOCAL ROLE masslak_app;
SELECT sys.set_context(:ua, :ca, 'COMPANY');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM net.corridor WHERE code = 'SY-JO-TEST'), 'Audit R-14: once the switch is on, the phase opens');
RESET ROLE;
ROLLBACK;
SELECT pg_temp.ok((SELECT ordinal FROM sys.project_phase WHERE code = 'SCH') > (SELECT ordinal FROM sys.project_phase WHERE code = '15')
  AND (SELECT ordinal FROM sys.project_phase WHERE code = 'SCH') < (SELECT max(ordinal) FROM sys.project_phase)
  AND (SELECT phase_code FROM sys.table_phase WHERE table_name = 'ops.violation_report') = '5',
  'Phases: school transport comes before the last phase; reporting to authorities waits for government integration');
SET ROLE masslak_app;

-- Audit operations (1047): schema change log, JSONB contracts, frozen snapshots, lifecycle and the permission matrix
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM audit.ddl_event WHERE in_migration) > 0 AND (SELECT value FROM sys.setting WHERE key = 'security.ddl_audit') = 'true',
  'Audit R-09: schema changes made by migrations are logged as such');
BEGIN;
CREATE POLICY probe_policy ON net.station FOR SELECT TO masslak_readonly USING (false);
DROP POLICY probe_policy ON net.station;
SELECT pg_temp.ok((SELECT count(*) FROM audit.ddl_event WHERE NOT in_migration AND security_relevant AND command_tag IN ('CREATE POLICY','DROP POLICY')) >= 2
  AND EXISTS (SELECT 1 FROM sys.outbox_event WHERE event_type = 'security.ddl_change'),
  'Audit R-09: a policy change outside a migration is logged and raises an alert');
SELECT pg_temp.expect_error($$UPDATE audit.ddl_event SET command_tag = 'X'$$, 'IMMUTABLE_RECORD', 'Audit R-09: the schema change log cannot be edited');
ROLLBACK;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM sys.v_jsonb_inventory i WHERE NOT EXISTS (
                    SELECT 1 FROM sys.json_contract c WHERE c.table_name = i.table_name AND c.column_name = i.column_name))
  AND NOT EXISTS (SELECT 1 FROM sys.json_contract_violations()),
  'Audit R-08: every JSONB column has a registered kind and version, and stored values meet their contracts');
BEGIN;
SELECT pg_temp.expect_error($$UPDATE pricing.fare_brand SET rules = rules || '{"change_fee_pct": 150}' WHERE code = 'STANDARD'$$,
  'JSON_CONTRACT_VIOLATION', 'Audit R-08: a fare rule outside its contract is refused');
SELECT pg_temp.expect_error($$INSERT INTO net.line (code, name, kind, fare_regime) VALUES ('JSON-T1', 'Json test', 'INTERCITY', 'FREE');
  INSERT INTO net.line_version (line_id, version, geometry, distance_km, typical_min) SELECT id, 1, '{"type":"Point","coordinates":[36.2,33.5]}', 1, 1 FROM net.line WHERE code = 'JSON-T1'$$,
  'JSON_CONTRACT_VIOLATION', 'Audit R-08: a route shape that is not a line is refused even as a draft');
INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, channel_id, currency, total_amount, price_breakdown, rules_version, idempotency_key, status)
SELECT 'SNAP01', t.id, :ca, :pax, (SELECT id FROM sales.channel WHERE code='WEB'), 'SYP', 3500000, '{"total": 3500000}', 'r1', 'snap-1', 'PENDING_PAYMENT'
  FROM ops.trip t WHERE trip_no = 'QDS214/03OCT26';
SELECT pg_temp.expect_error($$UPDATE sales.booking SET price_breakdown = '{"total": 1}' WHERE booking_ref = 'SNAP01'$$,
  'SNAPSHOT_FROZEN', 'Audit R-08: the price of a sold booking cannot change');
ROLLBACK;
BEGIN;
INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload, status, published_at, created_at)
VALUES ('probe.old', 'probe', 1, '{}', 'PUBLISHED', now() - interval '400 days', now() - interval '400 days'),
       ('probe.new', 'probe', 2, '{}', 'PUBLISHED', now(), now());
SELECT sys.purge_expired() ->> 'outbox_events' AS purged \gset
SELECT pg_temp.ok(:purged >= 1 AND NOT EXISTS (SELECT 1 FROM sys.outbox_event WHERE event_type = 'probe.old')
  AND EXISTS (SELECT 1 FROM sys.outbox_event WHERE event_type = 'probe.new'),
  'Audit R-11: delivered events are purged when their retention ends, recent ones stay');
INSERT INTO gov.legal_hold (scope_type, dataset, reason, case_ref, placed_by) VALUES ('DATASET', 'sys.outbox_event', 'Hold probe', 'TEST-2', :uadmin);
INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload, status, published_at)
VALUES ('probe.held', 'probe', 3, '{}', 'PUBLISHED', now() - interval '400 days');
SELECT sys.purge_expired() ->> 'outbox_events' AS purged \gset
SELECT pg_temp.ok(:purged = 0 AND EXISTS (SELECT 1 FROM sys.outbox_event WHERE event_type = 'probe.held'),
  'Audit R-11: a legal hold on the dataset stops the purge');
ROLLBACK;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM gov.v_lifecycle_matrix WHERE erasure_method IS NULL OR retention_days IS NULL)
  AND (SELECT count(*) FROM gov.v_lifecycle_matrix) >= 17,
  'Audit R-11: every inventoried dataset has a retention, an erasure method and its copies');
SELECT pg_temp.ok((SELECT count(*) FROM sys.v_policy_matrix) = (SELECT count(*) FROM pg_policies)
  AND NOT EXISTS (SELECT 1 FROM sys.v_policy_matrix WHERE data_class IN ('TENANT_PRIVATE','USER_PRIVATE') AND permissive = 'PERMISSIVE'
                    AND command IN ('ALL','INSERT','UPDATE') AND coalesce(check_expr, '') ~ '^\s*true\s*$'
                    -- by design: any transaction writes its own events to the outbox; reading them stays restricted
                    AND (table_name, policyname) NOT IN (('sys.outbox_event', 'outbox_insert'))),
  'Audit R-05: the permission matrix covers every policy, and no private table accepts writes unconditionally');
SET ROLE masslak_app;

-- Write sweep findings (1047): sessions, files and typed references
RESET ROLE;
BEGIN;
SELECT pg_temp.expect_error(format($$INSERT INTO iam.user_session (user_id, company_id, portal, token_hash, ip, expires_at) VALUES (%s, %s, 'OPERATOR', '\x00', '127.0.0.1', now() + interval '1 hour')$$, :ua, :cb),
  'SESSION_COMPANY_NOT_MEMBER', 'Audit R-01: a session cannot act for a company its user does not belong to');
SELECT pg_temp.ok(pg_get_triggerdef((SELECT oid FROM pg_trigger WHERE tgname = 'owner_typed_ref' AND tgrelid = 'iam.document'::regclass)) !~ 'UPDATE OF',
  'Audit R-01: typed reference columns are rebuilt on every update, so writing one directly is undone');
SELECT pg_temp.ok((SELECT with_check FROM pg_policies WHERE schemaname = 'ref' AND tablename = 'file_object' AND policyname = 'file_object_isolation')
                  ~ 'company_id IS NULL', 'Audit R-01: an uploader cannot give a file to a company they do not act for');
ROLLBACK;
SET ROLE masslak_app;

-- =====================================================================
-- Design audit T3 (1048)
-- =====================================================================
RESET ROLE;
BEGIN;
-- T3-04: signatures and business references
SELECT pg_temp.expect_error($$INSERT INTO sec.document_signature (doc_type, doc_ref_id, serial_no, sha256, signature, key_id)
  VALUES ('TICKET', 987654321, 'SIG-T3-1', '\x00', '\x00', (SELECT min(id) FROM sec.key_registry))$$,
  'REFERENCE_MISSING', 'Audit T3-04: a signature cannot name a ticket that does not exist');
SELECT pg_temp.expect_error($$INSERT INTO fin.ledger_txn (txn_type, currency, ref_type, ref_id, idempotency_key) VALUES ('TOPUP', 'SYP', 'booking', 987654321, 't3-ref-1')$$,
  'REFERENCE_MISSING', 'Audit T3-04: a ledger transaction cannot name a booking that does not exist');
SELECT pg_temp.expect_error($$INSERT INTO fin.ledger_txn (txn_type, currency, ref_type, ref_id, idempotency_key) VALUES ('TOPUP', 'SYP', 'bogus', 1, 't3-ref-2')$$,
  'REFERENCE_TYPE_UNKNOWN', 'Audit T3-04: a ledger transaction cannot name an unregistered kind of row');
SELECT pg_temp.expect_error(format($$INSERT INTO gov.legal_hold (scope_type, scope_id, reason, case_ref, placed_by) VALUES ('TRIP', 987654321, 'Hold probe', 'T3-H', %s)$$, :uadmin),
  'REFERENCE_MISSING', 'Audit T3-04: a legal hold cannot cover a trip that does not exist');

-- T3-03: break-glass
SELECT pg_temp.expect_error(format($$INSERT INTO sec.break_glass_log (actor_id, reason, incident_ref, scope, expires_at) VALUES (%s, 'Restore a corrupted booking row', 'INC-1', 'DB', now() + interval '1 hour')$$, :ufin),
  'break_glass_approved', 'Audit T3-03: break-glass needs an approver unless declared an emergency');
SELECT pg_temp.expect_error(format($$INSERT INTO sec.break_glass_log (actor_id, approver_id, reason, incident_ref, scope, expires_at) VALUES (%s, %s, 'Restore a corrupted booking row', 'INC-1', 'DB', now() + interval '9 hours')$$, :ufin, :uadmin),
  'BREAK_GLASS_TOO_LONG', 'Audit T3-03: break-glass access cannot outlast its maximum');
SELECT pg_temp.expect_error(format($$INSERT INTO sec.break_glass_log (actor_id, approver_id, reason, incident_ref, scope, expires_at) VALUES (%s, %s, 'Restore a corrupted booking row', 'INC-1', 'DB', now() + interval '1 hour')$$, :ufin, :ufin),
  'break_glass_log_check', 'Audit T3-03: nobody approves their own break-glass access');
INSERT INTO sec.break_glass_log (actor_id, approver_id, reason, incident_ref, scope, expires_at)
VALUES (:ufin, :uadmin, 'Restore a corrupted booking row', 'INC-1', 'DB', now() + interval '1 hour');
SELECT max(id) AS bg1 FROM sec.break_glass_log \gset
SELECT pg_temp.ok(sec.break_glass_active(:ufin, 'DB') AND EXISTS (SELECT 1 FROM sys.outbox_event WHERE event_type = 'security.break_glass_opened' AND aggregate_id = :bg1),
  'Audit T3-03: an approved break-glass access is active and raises an alert at once');
SELECT pg_temp.expect_error(format($$UPDATE sec.break_glass_log SET expires_at = expires_at + interval '1 hour' WHERE id = %s$$, :bg1),
  'BREAK_GLASS_SEALED', 'Audit T3-03: a break-glass grant cannot be extended');
SELECT pg_temp.expect_error(format($$DELETE FROM sec.break_glass_log WHERE id = %s$$, :bg1),
  'BREAK_GLASS_SEALED', 'Audit T3-03: a break-glass record cannot be deleted');
INSERT INTO sec.break_glass_log (actor_id, reason, incident_ref, scope, emergency, started_at, expires_at)
VALUES (:ua, 'Emergency: payments stuck at the gateway', 'INC-2', 'DB', true, now() - interval '30 hours', now() - interval '29 hours');
SELECT max(id) AS bg2 FROM sec.break_glass_log \gset
SELECT pg_temp.ok(NOT sec.break_glass_active(:ua), 'Audit T3-03: an expired access is inactive without any job running');
SELECT sec.break_glass_upkeep() AS bgu \gset
SELECT pg_temp.ok((SELECT closed_reason FROM sec.break_glass_log WHERE id = :bg2) = 'EXPIRED'
  AND EXISTS (SELECT 1 FROM sys.outbox_event WHERE event_type = 'security.break_glass_unreviewed' AND aggregate_id = :bg2),
  'Audit T3-03: the upkeep closes expired access and alerts on an emergency left unreviewed');
SELECT pg_temp.expect_error(format($$UPDATE sec.break_glass_log SET reviewed_by = %s, review_note = 'Checked the statements run' WHERE id = %s$$, :ua, :bg2),
  'break_glass_reviewer', 'Audit T3-03: nobody reviews their own break-glass access');
UPDATE sec.break_glass_log SET reviewed_by = :uadmin, review_note = 'Checked the statements run against the incident' WHERE id = :bg2;
SELECT pg_temp.ok((SELECT reviewed_at IS NOT NULL FROM sec.break_glass_log WHERE id = :bg2), 'Audit T3-03: an independent review is recorded');
ROLLBACK;

BEGIN;
-- T3-10, T3-11: positions
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
                           WHERE i.inhparent = 'ops.geo_event'::regclass AND c.relname = 'geo_event_' || to_char(current_date, 'YYYYMMDD'))
  AND NOT EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
                   WHERE i.inhparent = 'ops.geo_event'::regclass AND c.relname ~ '^geo_event_[0-9]{6}$')
  AND (SELECT retention_days FROM gov.data_inventory WHERE dataset = 'ops.geo_event') = 7
  AND NOT EXISTS (SELECT 1 FROM sys.setting WHERE key = 'retention.geo_event_days'),
  'Audit T3-10: positions sit in daily partitions, with one stated retention of 7 days');
SELECT sys.ensure_daily_partitions('ops.geo_event', 0, 12);
SELECT sys.drop_daily_partitions_older_than('ops.geo_event', 7) AS geo_dropped \gset
SELECT pg_temp.ok(:geo_dropped >= 4
  AND NOT EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
                   WHERE i.inhparent = 'ops.geo_event'::regclass AND c.relname = 'geo_event_' || to_char(current_date - 9, 'YYYYMMDD')),
  'Audit T3-10: whole days past the retention are dropped, to the day');
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id, seq, device_ts)
VALUES (now() - interval '2 minutes', :va, 33.5100, 36.2900, 8, 'GPS', '00000000-0000-4000-8000-000000000001', 10, now() - interval '2 minutes');
SELECT pg_temp.ok((SELECT trust FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-000000000001') = 'HIGH',
  'Audit T3-11: an accurate, timely position is graded HIGH');
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id, seq, device_ts)
SELECT now(), vehicle_id, lat, lng, accuracy_m, provider, event_id, seq, device_ts FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-000000000001';
SELECT pg_temp.ok((SELECT count(*) FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-000000000001') = 1,
  'Audit T3-11: a resent position is dropped as a duplicate, even filed under another time');
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id, seq, device_ts) VALUES
  (now() - interval '1 minute', :va, 33.5110, 36.2910, 8, 'GPS', '00000000-0000-4000-8000-000000000002', 9, now() - interval '1 minute'),
  (now() - interval '50 seconds', :va, 34.7300, 36.7100, 8, 'GPS', '00000000-0000-4000-8000-000000000003', 11, now() - interval '50 seconds'),
  (now() - interval '40 seconds', :vb, 33.5100, 36.2900, 8, 'GPS', '00000000-0000-4000-8000-000000000004', 1, now() - interval '40 seconds');
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id, is_mock, device_ts)
VALUES (now(), :vb, 33.5100, 36.2900, 5, 'GPS', '00000000-0000-4000-8000-000000000005', true, now());
SELECT pg_temp.ok((SELECT trust_flags @> '{OUT_OF_ORDER}' FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-000000000002')
  AND (SELECT trust = 'LOW' AND trust_flags @> '{IMPOSSIBLE_SPEED}' FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-000000000003')
  AND (SELECT trust FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-000000000005') = 'REJECTED',
  'Audit T3-11: out-of-order, implausible and mock positions are graded down or rejected');
SELECT pg_temp.expect_error(format($$INSERT INTO ops.route_violation (company_id, vehicle_id, compliance_source, line_version_id, kind, tracking_source, started_at, in_service, status, evidence_trust)
  VALUES (%s, %s, 'REGULATED_LINE', %s, 'OFF_ROUTE', 'DRIVER_APP', now(), true, 'CONFIRMED', 'LOW')$$, :ca, :va, :lv1),
  'EVIDENCE_LOW_TRUST', 'Audit T3-11: a violation on low-trust positions is not confirmed without a person''s review');
ROLLBACK;

BEGIN;
-- T3-14: requirement changes
SELECT pg_temp.expect_error($$UPDATE sys.compliance_requirement SET level = 'REQUIRED' WHERE code = 'license.vehicle.insurance'$$,
  'REQUIREMENT_CHANGE_NEEDS_APPROVAL', 'Audit T3-14: a requirement cannot be switched directly');
SELECT pg_temp.expect_error($$SELECT sys.propose_requirement_change('license.vehicle.insurance', 'REQUIRED', NULL, 'Insurance becomes mandatory by decree')$$,
  'REQUIREMENT_CHANGE_FORBIDDEN', 'Audit T3-14: only a platform user proposes a requirement change');
SELECT set_config('app.scope', 'PLATFORM', true), set_config('app.user_id', :'uadmin', true);
SELECT sys.propose_requirement_change('license.vehicle.insurance', 'REQUIRED', current_date + 30, 'Insurance becomes mandatory by decree') AS rc1 \gset
SELECT pg_temp.ok((SELECT impact ? 'would_be_blocked' AND (impact ->> 'subjects')::int >= 1 FROM sys.requirement_change WHERE id = :rc1),
  'Audit T3-14: a proposal measures how many would fall short');
SELECT pg_temp.expect_error(format($$SELECT sys.decide_requirement_change(%s, true, 'ok')$$, :rc1),
  'REQUIREMENT_SELF_APPROVAL', 'Audit T3-14: the proposer cannot approve their own change');
SELECT set_config('app.user_id', :'ufin', true);
SELECT sys.decide_requirement_change(:rc1, true, 'Decree checked') AS rc_done \gset
SELECT pg_temp.ok(:'rc_done' = 'APPLIED'
  AND (SELECT level = 'REQUIRED' AND required_from = current_date + 30 FROM sys.compliance_requirement WHERE code = 'license.vehicle.insurance'),
  'Audit T3-14: a second person''s approval applies the change with its date');
ROLLBACK;

BEGIN;
-- T3-15: file quarantine
SET LOCAL app.scope = 'TENANT';
INSERT INTO ref.file_object (storage_key, mime_type, size_bytes, sha256, company_id) VALUES ('t3/probe', 'application/pdf', 10, '\x01', :ca);
SELECT max(id) AS f1 FROM ref.file_object \gset
SELECT pg_temp.ok((SELECT scan_status FROM ref.file_object WHERE id = :f1) = 'PENDING', 'Audit T3-15: a new file waits in quarantine');
SELECT pg_temp.expect_error(format($$UPDATE ref.file_object SET scan_status = 'CLEAN', scanned_at = now(), scan_engine = 'self' WHERE id = %s$$, :f1),
  'FILE_SCAN_STATUS', 'Audit T3-15: an uploader cannot mark their own file clean');
SET LOCAL app.scope = 'SYSTEM';
UPDATE ref.file_object SET scan_status = 'REJECTED', scanned_at = now(), scan_engine = 'test', scan_detail = 'EICAR' WHERE id = :f1;
SELECT pg_temp.expect_error(format($$UPDATE ref.file_object SET scan_status = 'CLEAN' WHERE id = %s$$, :f1),
  'FILE_SCAN_FINAL', 'Audit T3-15: a rejected file stays rejected');
SELECT pg_temp.expect_error(format($$INSERT INTO sec.document_signature (doc_type, doc_ref_id, serial_no, sha256, signature, key_id, file_id)
  VALUES ('STATEMENT', (SELECT min(id) FROM fin.settlement_batch), 'SIG-T3-2', '\x00', '\x00', (SELECT min(id) FROM sec.key_registry), %s)$$, :f1),
  'FILE_NOT_CLEAN', 'Audit T3-15: a file that is not clean cannot be signed');
ROLLBACK;

BEGIN;
-- T3-19, T3-02, T3-18, T3-12
SELECT pg_temp.expect_error(format($$INSERT INTO sec.access_review (user_id, reviewer_id, decision) VALUES (%s, %s, 'KEEP')$$, :ua, :ua),
  'access_review_not_self', 'Audit T3-19: nobody reviews their own access');
SELECT pg_temp.expect_error($$INSERT INTO audit.data_access_log (object_type, object_id, fields, purpose, request_id) VALUES ('document', 1, '{file}', 'probe', gen_random_uuid())$$,
  'data_access_log_actor', 'Audit T3-19: a sensitive read names its actor');
SELECT pg_temp.expect_error($$INSERT INTO audit.data_access_log (service_name, object_type, object_id, fields, purpose) VALUES ('scanner', 'document', 1, '{file}', 'probe')$$,
  'data_access_log_actor', 'Audit T3-19: a sensitive read names its request');
SELECT pg_temp.ok((SELECT count(*) FROM pg_constraint WHERE conname IN ('authority_profile_endpoint_encrypted', 'gov_adapter_config_endpoint_encrypted')
                    AND pg_get_constraintdef(oid) ~ 'https\|sftp\|amqps') = 2
  AND 'http://registry.example/api' !~ '^(https|sftp|amqps)://',
  'Audit T3-02: government endpoints must use an encrypted transport');
SELECT pg_temp.expect_error($$INSERT INTO ref.city (code, name, country_code) VALUES ('T3X', 'Probe', 'SY')$$,
  'CITY_TIMEZONE', 'Audit T3-18: a new city must name its time zone');
INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload) VALUES ('probe.a', 'probe', 77, '{}'), ('probe.b', 'probe', 77, '{}');
SELECT pg_temp.ok((SELECT array_agg(aggregate_seq ORDER BY id) FROM sys.outbox_event WHERE aggregate_type = 'probe' AND aggregate_id = 77) = '{1,2}'
  AND (SELECT bool_and(schema_version = 1) FROM sys.outbox_event WHERE aggregate_type = 'probe'),
  'Audit T3-12: events carry their schema version and their order within the aggregate');
ROLLBACK;
SET ROLE masslak_app;

-- =====================================================================
-- Re-audit of design 3.8 (1049)
-- =====================================================================
RESET ROLE;
BEGIN;
SELECT sys.run_maintenance() IS NOT NULL AS ran \gset
SELECT pg_temp.ok((SELECT ok AND finished_at IS NOT NULL FROM sys.job_run WHERE job = 'maintenance' ORDER BY id DESC LIMIT 1)
  AND (SELECT value FROM sys.ops_metrics() WHERE metric = 'masslak_job_last_success_age_seconds') < 60,
  'Audit T3-16: every run of the daily upkeep is recorded with its result, and monitoring sees how old the last success is');
SELECT pg_temp.ok((SELECT count(DISTINCT metric) FROM sys.ops_metrics() WHERE metric IN ('masslak_outbox_oldest_pending_seconds',
                   'masslak_geo_partitions_missing', 'masslak_wallet_mismatches', 'masslak_db_wal_archive_last_success_age_seconds',
                   'masslak_db_lock_waiters', 'masslak_db_longest_transaction_seconds', 'masslak_db_deadlocks_total', 'masslak_db_xid_age',
                   'masslak_files_pending_scan', 'masslak_break_glass_open')) = 10
  AND (SELECT value FROM sys.ops_metrics() WHERE metric = 'masslak_geo_partitions_missing') = 0,
  'Audit T3-16: the operational metrics cover the outbox, partitions, money, WAL archiving, locks, transactions and scans');
SELECT pg_temp.ok(NOT has_function_privilege('public', 'sys.ops_metrics()', 'EXECUTE') AND has_function_privilege('masslak_app', 'sys.ops_metrics()', 'EXECUTE'),
  'Audit T3-16: only the application and reporting roles read the operational metrics');
ROLLBACK;
BEGIN;
-- T3-11: devices
INSERT INTO iam.device (user_id, fingerprint_hash, platform, trust_status) VALUES (:ua, '\x0101', 'ANDROID', 'TRUSTED');
SELECT max(id) AS dev FROM iam.device \gset
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id, device_id)
VALUES (now(), :va, 33.51, 36.29, 6, 'GPS', '00000000-0000-4000-8000-0000000000a1', :dev);
UPDATE iam.device SET revoked_at = now(), trust_status = 'REVOKED' WHERE id = :dev;
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id, device_id)
VALUES (now() + interval '1 second', :va, 33.51, 36.29, 6, 'GPS', '00000000-0000-4000-8000-0000000000a2', :dev);
SELECT pg_temp.ok((SELECT trust FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-0000000000a1') = 'HIGH'
  AND (SELECT trust = 'REJECTED' AND trust_flags @> '{DEVICE_REVOKED}' FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-0000000000a2'),
  'Audit T3-11: positions from a revoked device are rejected');
SELECT pg_temp.set_requirement('tracking.device_attestation', 'REQUIRED');
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id)
VALUES (now() + interval '2 seconds', :vb, 33.51, 36.29, 6, 'GPS', '00000000-0000-4000-8000-0000000000a3');
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id, device_ts)
VALUES (now() + interval '3 seconds', :vb, 33.51, 36.29, 6, 'GPS', '00000000-0000-4000-8000-0000000000a4', now() + interval '10 minutes');
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id, device_ts)
VALUES (now() + interval '4 seconds', :vb, 33.51, 36.29, 6, 'GPS', '00000000-0000-4000-8000-0000000000a5', now() - interval '30 minutes');
SELECT pg_temp.ok((SELECT trust = 'LOW' AND trust_flags @> '{NO_DEVICE}' FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-0000000000a3')
  AND (SELECT trust = 'REJECTED' AND trust_flags @> '{FUTURE_TIME}' FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-0000000000a4')
  AND (SELECT trust_flags @> '{LATE}' FROM ops.geo_event WHERE event_id = '00000000-0000-4000-8000-0000000000a5'),
  'Audit T3-11: with attestation required a position without a device is low-trust; a device clock 10 minutes ahead is rejected and 30 minutes behind is late');
ROLLBACK;

BEGIN;
-- T3-12: resends of money events, payment reconciliation
SELECT pg_temp.ok((SELECT sum(value::bigint) FROM jsonb_each_text(fin.reconcile_payments() - 'at')) = 0,
  'Audit T3-12: payments, refunds, provider notices and the ledger reconcile');
SELECT pg_temp.ok((sys.run_maintenance()) ? 'payment_mismatches', 'Audit T3-12: the daily upkeep reconciles payments');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'sys.delivery_retry_request'::regclass
                            AND pg_get_constraintdef(oid) LIKE '%decided_by IS DISTINCT FROM requested_by%')
  AND NOT has_table_privilege('masslak_app', 'sys.delivery_retry_request', 'DELETE'),
  'Audit T3-12: a resend request cannot be approved by its requester and is never deleted');
ROLLBACK;
SET ROLE masslak_app;

-- =====================================================================
-- Owner decisions (1050)
-- =====================================================================
RESET ROLE;
BEGIN;
SELECT pg_temp.ok((SELECT value::int FROM sys.setting WHERE key = 'recovery.rpo_seconds') = 60
  AND (SELECT value::int FROM sys.setting WHERE key = 'recovery.rto_minutes') = 30
  AND (SELECT (value ->> 'booking_payment_availability')::numeric FROM sys.setting WHERE key = 'slo.objectives') = 0.999,
  'Owner decision: the approved RPO, RTO and SLOs are settings the tools compare against');
SELECT pg_temp.expect_error(format($$INSERT INTO iam.user_role (user_id, role_id, granted_by) SELECT %s, id, %s FROM iam.role WHERE code = 'EXTERNAL_AUDITOR'$$, :ufin, :uadmin),
  'EXTERNAL_ACCESS_GRANT_REQUIRED', 'Owner decision: the external auditor role cannot be given outside a time-bound grant');
SELECT pg_temp.expect_error(format($$INSERT INTO sec.external_access_grant (user_id, granted_by, organisation, purpose, engagement_ref, expires_at) VALUES (%s, %s, 'Lab', 'Penetration test of the API', 'PT-1', now() + interval '60 days')$$, :ufin, :uadmin),
  'EXTERNAL_ACCESS_TOO_LONG', 'Owner decision: external access cannot outlast its maximum');
SELECT pg_temp.expect_error(format($$INSERT INTO sec.external_access_grant (user_id, granted_by, organisation, purpose, engagement_ref, expires_at) VALUES (%s, %s, 'Lab', 'Penetration test of the API', 'PT-1', now() + interval '10 days')$$, :ufin, :ufin),
  'external_access_grant_check', 'Owner decision: nobody grants external access to themselves');
INSERT INTO sec.external_access_grant (user_id, granted_by, organisation, purpose, engagement_ref, expires_at)
VALUES (:ufin, :uadmin, 'Lab', 'Penetration test of the API', 'PT-1', now() + interval '10 days');
SELECT max(id) AS eg FROM sec.external_access_grant \gset
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM iam.user_role ur JOIN iam.role r ON r.id = ur.role_id WHERE ur.user_id = :ufin AND r.code = 'EXTERNAL_AUDITOR'
                            AND ur.valid_to BETWEEN now() + interval '9 days' AND now() + interval '11 days')
  AND EXISTS (SELECT 1 FROM sys.outbox_event WHERE event_type = 'security.external_access_granted' AND aggregate_id = :eg)
  AND NOT EXISTS (SELECT 1 FROM iam.role_permission rp JOIN iam.role r ON r.id = rp.role_id WHERE r.code = 'EXTERNAL_AUDITOR'
                    AND rp.permission_code NOT IN ('audit.view', 'policy.matrix')),
  'Owner decision: a grant gives the read-only role until its end date and is announced');
SELECT pg_temp.expect_error(format($$UPDATE sec.external_access_grant SET expires_at = expires_at + interval '1 day' WHERE id = %s$$, :eg),
  'EXTERNAL_ACCESS_SEALED', 'Owner decision: a grant cannot be extended');
UPDATE sec.external_access_grant SET revoked_at = now(), revoked_by = :uadmin WHERE id = :eg;
SELECT pg_temp.ok((SELECT ur.valid_to <= now() FROM iam.user_role ur JOIN iam.role r ON r.id = ur.role_id WHERE ur.user_id = :ufin AND r.code = 'EXTERNAL_AUDITOR'),
  'Owner decision: revoking a grant ends the role at once');
ROLLBACK;
SET ROLE masslak_app;

-- =====================================================================
-- Architecture review of design 3.9 (1051)
-- =====================================================================
RESET ROLE;
SELECT pg_temp.ok(NOT EXISTS (
  SELECT 1 FROM pg_class c WHERE c.relkind = 'p'
     AND ((obj_description(c.oid) ILIKE '%monthly%' AND EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhrelid
                                                                 WHERE i.inhparent = c.oid AND p.relname ~ '_[0-9]{8}$'))
       OR (obj_description(c.oid) ILIKE '%daily%' AND NOT EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhrelid
                                                                   WHERE i.inhparent = c.oid AND p.relname ~ '_[0-9]{8}$')))),
  'Architecture review: the comment of a partitioned table matches its partitions (daily or monthly)');
SELECT pg_temp.ok(obj_description('ops.geo_event'::regclass) LIKE '%daily partitions%',
  'Architecture review: positions are described as daily partitions');
SELECT pg_temp.ok((SELECT count(DISTINCT labels ->> 'table') FROM sys.capacity_metrics() WHERE metric = 'masslak_table_rows_estimate') = 11
  AND (SELECT value FROM sys.capacity_metrics() WHERE metric = 'masslak_outbox_partitioning_due') = 0
  AND EXISTS (SELECT 1 FROM sys.capacity_metrics() WHERE metric = 'masslak_table_bytes' AND labels ->> 'table' = 'ops.geo_event' AND value > 0),
  'Architecture review: capacity metrics cover the growing tables, partitions included');
BEGIN;
UPDATE sys.setting SET value = '0' WHERE key = 'capacity.outbox_partition_rows';
ANALYZE sys.outbox_event;
SELECT pg_temp.ok((SELECT value FROM sys.capacity_metrics() WHERE metric = 'masslak_outbox_partitioning_due') =
                  CASE WHEN (SELECT reltuples FROM pg_class WHERE oid = 'sys.outbox_event'::regclass) > 0 THEN 1 ELSE 0 END,
  'Architecture review: the outbox partitioning point follows its setting');
ROLLBACK;
SET ROLE masslak_app;
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM sys.capacity_metrics() WHERE metric = 'masslak_db_track_functions'),
  'Architecture review: the application role reads the capacity metrics');

-- =====================================================================
-- Ten million operations a day (1052)
-- =====================================================================
RESET ROLE;
SELECT id AS sc_company FROM fin.wallet WHERE wallet_type = 'COMPANY' AND currency = 'SYP' ORDER BY id LIMIT 1 \gset
SELECT id AS sc_gw FROM fin.wallet WHERE wallet_type = 'GATEWAY_CLEARING' AND currency = 'SYP' ORDER BY id LIMIT 1 \gset
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM fin.wallet WHERE wallet_type IN ('USER', 'FAMILY') AND balance_mode <> 'IMMEDIATE')
  AND NOT EXISTS (SELECT 1 FROM fin.wallet WHERE wallet_type NOT IN ('USER', 'FAMILY') AND balance_mode <> 'DEFERRED'),
  'Scale: passenger and family wallets update at once, shared wallets are DEFERRED');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                               WHERE t.tgrelid IN ('fin.ledger_entry'::regclass, 'fin.wallet'::regclass, 'ops.geo_event'::regclass)
                                 AND NOT t.tgisinternal AND p.proname <> 'tg_forbid_mutation'
                                 AND p.proname NOT IN ('tg_wallet_defaults', 'tg_wallet_opens_empty', 'tg_wallet_balance_guard')
                                 AND NOT (p.prosecdef AND p.proconfig IS NOT NULL)),
  'Scale: the money and position triggers read every row they need whoever posts (SECURITY DEFINER with a fixed search path)');
SELECT pg_temp.ok((SELECT relkind FROM pg_class WHERE oid = 'fin.ledger_entry'::regclass) = 'p'
  AND (SELECT count(*) FROM pg_inherits WHERE inhparent = 'fin.ledger_entry'::regclass) >= 4
  AND EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = 'fin.ledger_entry'::regclass
                AND array_to_string(c.reloptions, ',') LIKE '%autovacuum_vacuum_insert_scale_factor=0.05%'),
  'Scale: ledger entries sit in monthly partitions that carry their storage settings');
-- a credit to a shared wallet touches no wallet row and counts at once
SELECT balance AS sc_stored, fin.wallet_balance(id) AS sc_counted FROM fin.wallet WHERE id = :sc_company \gset
BEGIN;
WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('BOOKING_PAY', 'SYP', 'scale-1') RETURNING id)
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) SELECT t.id, x.w, x.d, x.a FROM t, (VALUES (:sc_gw, 'DR', 14000), (:sc_company, 'CR', 7000), (:w_user, 'CR', 7000)) x(w, d, a);
SELECT pg_temp.ok((SELECT balance FROM fin.wallet WHERE id = :sc_company) = :sc_stored
  AND fin.wallet_balance(:sc_company) = :sc_counted + 7000
  AND (SELECT bool_and(balance_after IS NULL AND created_xid IS NOT NULL) FROM fin.ledger_entry e JOIN fin.ledger_txn t ON t.id = e.txn_id
        WHERE t.idempotency_key = 'scale-1' AND e.wallet_id = :sc_company)
  AND (SELECT balance_after IS NOT NULL FROM fin.ledger_entry e JOIN fin.ledger_txn t ON t.id = e.txn_id
        WHERE t.idempotency_key = 'scale-1' AND e.wallet_id = :w_user),
  'Scale: a credit to a shared wallet appends its entry without touching the wallet row, and counts at once');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM audit.row_change WHERE table_name = 'wallet' AND row_pk IN (:'sc_company', :'w_user') AND ts >= now()),
  'Scale: a posting adds no wallet change to the audit log (the entry is the record)');
COMMIT;
BEGIN;
UPDATE fin.wallet SET status = 'FROZEN' WHERE id = :w_user;
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM audit.row_change WHERE table_name = 'wallet' AND row_pk = :'w_user' AND ts >= now()),
  'Scale: any other wallet change is still in the audit log');
ROLLBACK;
SELECT fin.roll_up_balances() AS sc_rolled \gset
SELECT pg_temp.ok(:sc_rolled >= 1 AND (SELECT balance FROM fin.wallet WHERE id = :sc_company) = fin.wallet_balance(:sc_company)
  AND fin.wallet_balance(:sc_company) = :sc_counted + 7000,
  'Scale: the roll-up folds finished entries into the stored balance');
-- a debit of a shared wallet that must stay covered checks the balance that counts
SELECT pg_temp.expect_error(format($$WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('PAYOUT', 'SYP', 'scale-2') RETURNING id)
  INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) SELECT t.id, x.w, x.d, %s FROM t, (VALUES (%s, 'DR'), (%s, 'CR')) x(w, d)$$,
  :sc_counted + 7001, :sc_company, :sc_gw), 'INSUFFICIENT_BALANCE', 'Scale: a shared wallet cannot pay out more than it holds');
SELECT pg_temp.expect_error(format('SELECT fin.adjust_hold(%s, %s)', :sc_company, :sc_counted + 7001), 'INSUFFICIENT_BALANCE',
  'Scale: a withdrawal hold cannot exceed the balance that counts');
BEGIN;
SELECT fin.adjust_hold(:sc_company, 5000);
SELECT fin.adjust_hold(:sc_company, -5000);
SELECT pg_temp.ok((SELECT hold_balance FROM fin.wallet WHERE id = :sc_company) = 0, 'Scale: a hold within the balance is placed and released');
ROLLBACK;
SELECT pg_temp.ok((fin.reconcile_wallets()).mismatches = 0, 'Scale: every wallet reconciles in both balance modes');
-- closed days: totals with running balances, nothing posted into them afterwards, the balance at any moment
BEGIN;
WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, created_at) VALUES ('BOOKING_PAY', 'SYP', 'scale-old', now() - interval '3 days') RETURNING id)
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount, created_at)
SELECT t.id, x.w, x.d, 400, now() - interval '3 days' FROM t, (VALUES (:sc_gw, 'DR'), (:sc_company, 'CR')) x(w, d);
COMMIT;
SELECT fin.roll_up_balances();
SELECT fin.close_ledger_days() AS sc_days \gset
SELECT closed_through AS sc_closed FROM fin.ledger_close WHERE id \gset
SELECT pg_temp.ok(:sc_days >= 3 AND :'sc_closed'::date = (now() AT TIME ZONE 'UTC')::date - 1
  AND EXISTS (SELECT 1 FROM fin.ledger_day_total WHERE wallet_id = :sc_company AND day = ((now() - interval '3 days') AT TIME ZONE 'UTC')::date AND credit >= 400),
  'Scale: closing totals every wallet per finished day, up to yesterday');
SELECT pg_temp.expect_error(format($$WITH t AS (INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('BOOKING_PAY', 'SYP', 'scale-late') RETURNING id)
  INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount, created_at) SELECT t.id, x.w, x.d, 1, now() - interval '2 days' FROM t, (VALUES (%s, 'DR'), (%s, 'CR')) x(w, d)$$,
  :sc_gw, :sc_company), 'LEDGER_DAY_CLOSED', 'Scale: nothing is posted into a closed day');
SELECT pg_temp.ok(fin.verify_ledger_day(((now() - interval '3 days') AT TIME ZONE 'UTC')::date) = 0
  AND fin.wallet_balance_at(:sc_company, now()) = fin.wallet_balance(:sc_company)
  AND fin.wallet_balance_at(:sc_company, now() - interval '3 days' + interval '1 second')
      = (SELECT coalesce(sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END), 0) FROM fin.ledger_entry
          WHERE wallet_id = :sc_company AND created_at < now() - interval '3 days' + interval '1 second'),
  'Scale: a closed day re-reads the same, and the balance at any moment matches the entries');
SELECT pg_temp.ok((fin.reconcile_wallets()).mismatches = 0, 'Scale: reconciliation reads the last running total and the open days only');
SELECT pg_temp.expect_error('UPDATE fin.ledger_day_total SET credit = credit + 1', 'IMMUTABLE_RECORD', 'Scale: closed-day totals never change');
-- the latest position of a vehicle
BEGIN;
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id, seq, device_ts) VALUES
  (now() - interval '20 seconds', :va, 33.5200, 36.3000, 6, 'GPS', '00000000-0000-4000-8000-0000000000a1', 501, now() - interval '20 seconds'),
  (now() - interval '10 seconds', :va, 33.5210, 36.3010, 6, 'GPS', '00000000-0000-4000-8000-0000000000a2', 502, now() - interval '10 seconds');
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider, event_id, seq, device_ts)
VALUES (now() - interval '30 seconds', :va, 33.9, 36.9, 6, 'GPS', '00000000-0000-4000-8000-0000000000a3', 500, now() - interval '30 seconds');
SELECT pg_temp.ok((SELECT lat FROM ops.vehicle_position WHERE vehicle_id = :va) = 33.5210,
  'Scale: the latest position of a vehicle is kept in one row, and an older position never replaces it');
ROLLBACK;
-- the audit online window: a month is dropped only when the signed archive covers it
BEGIN;
UPDATE sys.setting SET value = '-1' WHERE key = 'audit.online_months';
SELECT audit.drop_archived_partitions() AS sc_dropped_before \gset
SELECT pg_temp.ok(to_regclass('audit.row_change_' || to_char(now(), 'YYYYMM')) IS NOT NULL,
  'Scale: an audit month that is not archived stays in the database');
SELECT audit.record_archive('audit.row_change', (SELECT max(id) FROM audit.row_change), repeat('a', 64));
SELECT audit.drop_archived_partitions() AS sc_dropped \gset
SELECT pg_temp.ok(to_regclass('audit.row_change_' || to_char(now(), 'YYYYMM')) IS NULL,
  'Scale: an audit month older than the online window and covered by the archive is dropped');
ROLLBACK;
SET ROLE masslak_app;
SELECT pg_temp.expect_error($$SELECT audit.record_archive('audit.row_change', 1, repeat('b', 64))$$, 'permission denied',
  'Scale: only the audit role records archive checkpoints');
RESET ROLE;
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM sys.scale_metrics() WHERE metric = 'masslak_wallet_rollup_lag_seconds')
  AND (SELECT value FROM sys.scale_metrics() WHERE metric = 'masslak_ledger_open_days') <= 2,
  'Scale: roll-up lag and open ledger days are measured');
SET ROLE masslak_app;

-- the outbox in daily partitions (1053)
RESET ROLE;
SELECT pg_temp.ok((SELECT relkind FROM pg_class WHERE oid = 'sys.outbox_event'::regclass) = 'p'
  AND EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = 'sys.outbox_event'::regclass
                AND c.relname = 'outbox_event_' || to_char(current_date, 'YYYYMMDD') AND array_to_string(c.reloptions, ',') LIKE '%fillfactor=80%')
  AND (SELECT count(*) FROM pg_indexes WHERE schemaname = 'sys' AND tablename = 'outbox_event' AND indexdef LIKE '%WHERE (status = ''PENDING''%') = 1,
  'Scale: the outbox sits in daily partitions with its storage settings and one pending-queue index');
BEGIN;
INSERT INTO sys.webhook_endpoint (owner_kind, url, events, secret_enc, enc_key_id)
SELECT 'INTEGRATION', 'https://scale-test.example/hook', '{scale.delivered}', '\x00', (SELECT min(id) FROM sec.key_registry)
RETURNING id AS sc_ep \gset
SELECT sys.ensure_daily_partitions('sys.outbox_event', 0, 40);
INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload, status, published_at, created_at) VALUES
  ('scale.old', 'booking', 1, '{}', 'PUBLISHED', now() - interval '35 days', now() - interval '35 days'),
  ('scale.waiting', 'booking', 1, '{}', 'PENDING', NULL, now() - interval '34 days'),
  ('scale.delivered', 'booking', 1, '{}', 'PUBLISHED', now() - interval '33 days', now() - interval '33 days');
INSERT INTO sys.webhook_delivery (endpoint_id, outbox_event_id, event_type, status)
SELECT :sc_ep, id, event_type, 'DELIVERED' FROM sys.outbox_event WHERE event_type = 'scale.delivered';
SELECT pg_temp.ok((SELECT d.outbox_created_at = o.created_at FROM sys.webhook_delivery d JOIN sys.outbox_event o ON o.id = d.outbox_event_id
                    WHERE o.event_type = 'scale.delivered'),
  'Scale: a delivery keeps the day of its event, filled in when the writer does not give it');
SELECT sys.drop_outbox_days() AS sc_out_days \gset
SELECT pg_temp.ok(to_regclass('sys.outbox_event_' || to_char(current_date - 35, 'YYYYMMDD')) IS NULL
  AND to_regclass('sys.outbox_event_' || to_char(current_date - 34, 'YYYYMMDD')) IS NOT NULL
  AND to_regclass('sys.outbox_event_' || to_char(current_date - 33, 'YYYYMMDD')) IS NOT NULL,
  'Scale: a finished day of events is dropped whole after the retention; a day with a waiting event or a kept delivery stays');
ROLLBACK;
SET ROLE masslak_app;

-- =====================================================================
-- Launch completeness (1054)
-- =====================================================================
RESET ROLE;
BEGIN;
INSERT INTO crm."case" (kind, category, priority, channel, subject) VALUES ('COMPLAINT', 'SAFETY', 'CRITICAL', 'WEB', 'lc probe')
RETURNING id AS lc_case, ref AS lc_ref \gset
SELECT pg_temp.ok(:'lc_ref' ~ '^C[0-9A-F]{7}$'
  AND (SELECT first_due_at - created_at = interval '1 hour' AND resolve_due_at - created_at = interval '8 hours' FROM crm."case" WHERE id = :lc_case),
  'Launch: a new case gets a reference and its service-level dates from support.sla');
INSERT INTO crm.case_event (case_id, actor_role, kind, visibility, body) VALUES (:lc_case, 'STAFF', 'REPLY', 'PUBLIC', 'answer');
SELECT pg_temp.ok((SELECT first_response_at IS NOT NULL AND status = 'OPEN' FROM crm."case" WHERE id = :lc_case),
  'Launch: the first public staff reply stamps the first response and opens the case');
SELECT pg_temp.expect_error(format($q$INSERT INTO crm.case_event (case_id, actor_role, kind, visibility, body)
                                     VALUES (%s, 'CUSTOMER', 'NOTE', 'INTERNAL', 'x')$q$, :lc_case), 'CUSTOMER_EVENT',
  'Launch: a customer adds public replies only');
UPDATE crm."case" SET status = 'RESOLVED' WHERE id = :lc_case;
UPDATE crm."case" SET status = 'CLOSED' WHERE id = :lc_case;
SELECT pg_temp.expect_error(format('UPDATE crm."case" SET status = %L WHERE id = %s', 'OPEN', :lc_case), 'CASE_FINAL',
  'Launch: a closed case does not reopen');
SELECT pg_temp.expect_error($q$INSERT INTO crm."case" (kind, category, channel, subject, claim_amount) VALUES ('INQUIRY', 'OTHER', 'WEB', 'x', 100)$q$,
  'NOT_A_CLAIM', 'Launch: only a claim carries amounts');
INSERT INTO crm."case" (kind, category, channel, subject, claim_amount) VALUES ('CLAIM', 'DELAY', 'WEB', 'lc claim', 1000)
RETURNING id AS lc_claim \gset
SELECT pg_temp.expect_error(format('UPDATE crm."case" SET approved_amount = 2000 WHERE id = %s', :lc_claim), 'APPROVED_OVER_CLAIM',
  'Launch: the approved amount stays within the amount claimed');
SELECT pg_temp.expect_error(format($q$UPDATE crm."case" SET approved_amount = 500, liable = 'NONE', payout_status = 'PENDING_FINANCE' WHERE id = %s$q$, :lc_claim),
  'CLAIM_NOT_DECIDED', 'Launch: a claim goes to finance with the carrier or the platform liable');
UPDATE crm."case" SET approved_amount = 500, liable = 'PLATFORM', payout_status = 'PENDING_FINANCE' WHERE id = :lc_claim;
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM crm.case_event WHERE case_id = :lc_claim AND kind = 'DECISION'),
  'Launch: sending a claim to finance records the decision');
SELECT pg_temp.expect_error(format($q$UPDATE crm."case" SET payout_status = 'PAID' WHERE id = %s$q$, :lc_claim), 'CLAIM_NOT_PAYABLE',
  'Launch: a claim is paid only with its ledger transaction');
ROLLBACK;
SELECT pg_temp.ok((SELECT targets ? 'case' FROM sys.polymorphic_reference WHERE table_name = 'fin.ledger_txn' AND type_col = 'ref_type'),
  'Launch: a paid claim''s ledger transaction may point at its case');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'ops' AND indexname = 'trip_template_departure_uniq'),
  'Launch: a template generates one trip per departure');
BEGIN;
INSERT INTO sec.blocklist_entry (entry_type, value_hash, reason) VALUES ('PHONE', '\xabcd', 'lc probe');
SELECT pg_temp.ok(sec.is_blocked('PHONE', '\xabcd') AND NOT sec.is_blocked('EMAIL', '\xabcd') AND NOT sec.is_blocked('PHONE', '\xabce')
  AND has_function_privilege('masslak_app', 'sec.is_blocked(text, bytea)', 'EXECUTE')
  AND NOT has_function_privilege('public', 'sec.is_blocked(text, bytea)', 'EXECUTE'),
  'Launch: registration and sign-in can ask the blocklist without reading it');
UPDATE sec.blocklist_entry SET expires_at = now() - interval '1 minute' WHERE value_hash = '\xabcd';
SELECT pg_temp.ok(NOT sec.is_blocked('PHONE', '\xabcd'), 'Launch: an expired blocklist entry no longer blocks');
ROLLBACK;
BEGIN;
SELECT id AS lc_license FROM fleet.license_record ORDER BY id LIMIT 1 \gset
SELECT id AS lc_u1 FROM iam.app_user ORDER BY id LIMIT 1 \gset
SELECT pg_temp.ok((SELECT count(*) FROM pg_policy WHERE polrelid = 'sales.passenger_compensation'::regclass AND NOT polpermissive) = 3
  AND (SELECT count(*) FROM pg_policy WHERE polrelid = 'ops.trip_disruption'::regclass AND polname = 'split_write'
         AND pg_get_expr(polwithcheck, polrelid) NOT LIKE '%partner_company_id%') = 1,
  'Launch: only the platform writes passenger compensation, and only the trip''s carrier writes its disruption');
SELECT pg_temp.expect_error(format($q$INSERT INTO fleet.license_change_request (license_record_id, requested_by, new_values, reviewed_by, status)
                                     VALUES (%s, %s, '{}', %s, 'REVIEWED')$q$, :lc_license, :lc_u1, :lc_u1), 'FOUR_EYES',
  'Launch: the requester of a licence change does not review it');
ROLLBACK;
SET ROLE masslak_app;

-- =====================================================================
-- Contact centre and AI phase gate (1055)
-- =====================================================================
RESET ROLE;
SELECT pg_temp.ok((:'shipped_features'::jsonb ->> 'ai_assistant')::boolean IS NOT TRUE
  AND (:'shipped_features'::jsonb ->> 'contact_center')::boolean IS NOT TRUE AND NOT sys.phase_on('CS'),
  'AI phase: a new install ships the contact centre and AI phase closed');
SELECT pg_temp.expect_error($q$UPDATE sys.setting SET value = value || '{"ai_assistant": true}'::jsonb WHERE key = 'features'$q$,
  'DPIA_REQUIRED', 'AI phase: the AI switch does not open without an approved data protection review');
BEGIN;
INSERT INTO ref.file_object (storage_key, mime_type, size_bytes, sha256)
VALUES ('dpia/ai-probe.pdf', 'application/pdf', 1, sha256('dpia'::bytea)) RETURNING id AS ai_file \gset
SELECT id AS ai_user FROM iam.app_user ORDER BY id LIMIT 1 \gset
INSERT INTO gov.feature_compliance_review (feature, decision, approved_by) VALUES ('contact_center', 'APPROVED', :ai_user);
SELECT pg_temp.expect_error($q$UPDATE sys.setting SET value = value || '{"contact_center": true}'::jsonb WHERE key = 'features'$q$,
  'DPIA_REQUIRED', 'AI phase: an approval without the DPIA file does not open the phase');
INSERT INTO gov.feature_compliance_review (feature, dpia_file_id, decision, approved_by) VALUES ('contact_center', :ai_file, 'APPROVED', :ai_user);
UPDATE sys.setting SET value = value || '{"contact_center": true}'::jsonb WHERE key = 'features';
SELECT pg_temp.ok(sys.phase_on('CS'), 'AI phase: an approved review with its DPIA opens the phase');
ROLLBACK;
SET ROLE masslak_app;

-- =====================================================================
-- Payment options switched by the platform (1056)
-- =====================================================================
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM fin.payment_method) = 7
  AND (SELECT array_agg(code ORDER BY sort_order) FROM fin.payment_method WHERE enabled) = '{WALLET,AGENCY_BALANCE,CASH_COUNTER,PAY_LATER}',
  'Payment options: a new install opens the wallet, agency balance, counter cash and pay later; cards, instalments and financing wait for a contract');
SELECT pg_temp.expect_error($$UPDATE fin.payment_method SET enabled = true WHERE code = 'CARD'$$, 'NO_ACTIVE_PROVIDER',
  'Payment options: card payment does not open without an active card provider for bookings');
BEGIN;
UPDATE fin.payment_method SET enabled = false WHERE code IN ('AGENCY_BALANCE', 'CASH_COUNTER', 'PAY_LATER');
SELECT pg_temp.expect_error($$UPDATE fin.payment_method SET enabled = false WHERE code = 'WALLET'$$, 'LAST_PAYMENT_METHOD',
  'Payment options: the last open way of paying cannot be closed');
ROLLBACK;
BEGIN;
UPDATE fin.payment_provider SET status = 'ACTIVE' WHERE code = 'INSTALMENTS';
UPDATE fin.payment_method SET enabled = true WHERE code = 'INSTALLMENT';
SELECT pg_temp.expect_error($$UPDATE fin.payment_provider SET status = 'INACTIVE' WHERE code = 'INSTALMENTS'$$, 'PROVIDER_IN_USE',
  'Payment options: the provider an open option relies on cannot be switched off');
ROLLBACK;
SELECT pg_temp.ok((SELECT 'BOOKING' = ANY (purposes) FROM fin.payment_provider WHERE code = 'CARD')
  AND (SELECT config -> 'trip_types' FROM fin.payment_method WHERE code = 'FINANCING') = '["PILGRIMAGE", "TOURISM"]'
  AND EXISTS (SELECT 1 FROM ref.trip_type WHERE code = 'PILGRIMAGE'),
  'Payment options: the card gateway also takes checkout payments, and financing is meant for pilgrimages and tours');
SELECT pg_temp.expect_error($$UPDATE fin.payment_method SET config = '{"hold_hours": 24, "surprise": 1}' WHERE code = 'PAY_LATER'$$,
  'JSON_CONTRACT_VIOLATION', 'Payment options: an option''s settings are checked against their contract');
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
UPDATE fin.payment_method SET enabled = false WHERE code = 'PAY_LATER';
SELECT pg_temp.expect_error(format($$INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, channel_id, currency, total_amount,
    price_breakdown, rules_version, idempotency_key, status, pay_option, hold_expires_at)
  VALUES ('PO0001', %s, %s, %s, (SELECT id FROM sales.channel WHERE code = 'WEB'), 'SYP', 1000, '{}', 'r1', 'po-1', 'PENDING_PAYMENT', 'PAY_LATER',
          now() + interval '1 hour')$$, :t214, :ca, :pax),
  'PAYMENT_METHOD_DISABLED', 'Payment options: a booking cannot use a way of paying that is closed');
ROLLBACK;
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
SELECT pg_temp.expect_error(format($$INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, channel_id, currency, total_amount,
    price_breakdown, rules_version, idempotency_key, status, pay_option)
  VALUES ('PO0002', %s, %s, %s, (SELECT id FROM sales.channel WHERE code = 'WEB'), 'SYP', 1000, '{}', 'r1', 'po-2', 'PENDING_PAYMENT', 'PAY_LATER')$$,
  :t214, :ca, :pax), 'PAY_BY_REQUIRED', 'Payment options: a reservation always has a time to be paid by');
UPDATE fin.payment_method SET min_amount = 5000 WHERE code = 'PAY_LATER';
SELECT pg_temp.expect_error(format($$INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, channel_id, currency, total_amount,
    price_breakdown, rules_version, idempotency_key, status, pay_option, hold_expires_at)
  VALUES ('PO0003', %s, %s, %s, (SELECT id FROM sales.channel WHERE code = 'WEB'), 'SYP', 1000, '{}', 'r1', 'po-3', 'PENDING_PAYMENT', 'PAY_LATER',
          now() + interval '1 hour')$$, :t214, :ca, :pax),
  'PAYMENT_AMOUNT_OUT_OF_RANGE', 'Payment options: an amount below the option''s minimum is refused');
ROLLBACK;
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, channel_id, currency, total_amount, price_breakdown, rules_version,
  idempotency_key, status, pay_option, pay_method, hold_expires_at)
VALUES ('PO0004', :t214, :ca, :pax, (SELECT id FROM sales.channel WHERE code = 'WEB'), 'SYP', 1000, '{}', 'r1', 'po-4', 'PENDING_PAYMENT', 'PAY_LATER',
        'CASH', now() - interval '1 minute') RETURNING id AS po_b \gset
INSERT INTO sales.passenger (booking_id, full_name, first_name, last_name, nationality, passenger_category)
VALUES (:po_b, 'Late Payer', 'Late', 'Payer', 'JO', 'ADULT') RETURNING id AS po_p \gset
INSERT INTO sales.ticket (ticket_no, booking_id, passenger_id, trip_id, from_seq, to_seq, seat_no, fare_amount, total_amount, rules_snapshot, status)
VALUES ('PO0004-1', :po_b, :po_p, :t214, 0, 1, 8, 1000, 1000, '{}', 'HOLD') RETURNING id AS po_k \gset
INSERT INTO ops.seat_segment (trip_id, seat_no, seg, status, ticket_id) VALUES (:t214, 8, 0, 'SOLD', :po_k);
SELECT sales.expire_reservations() AS po_freed \gset
SELECT pg_temp.ok(:po_freed >= 1 AND (SELECT status FROM sales.booking WHERE id = :po_b) = 'EXPIRED'
  AND (SELECT status FROM sales.ticket WHERE id = :po_k) = 'CANCELLED'
  AND (SELECT status FROM ops.seat_segment WHERE trip_id = :t214 AND seat_no = 8 AND seg = 0) = 'AVAILABLE',
  'Payment options: a reservation not paid in time expires and gives its seat back');
ROLLBACK;
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
INSERT INTO fin.wallet (owner_party_id, company_id, wallet_type, label, currency, allow_negative, balance_mode)
VALUES (:ca, :ca, 'CASH_COLLECT', 'Counter cash', 'SYP', true, 'IMMEDIATE') RETURNING id AS po_cash \gset
SELECT w.id AS po_escrow FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
 WHERE p.legal_name = 'Masslak Platform' AND w.wallet_type = 'ESCROW' AND w.currency = 'SYP' \gset
INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, memo) VALUES ('BOOKING_PAY', 'SYP', 'po-cash-1', 'counter sale') RETURNING id AS po_txn \gset
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) VALUES (:po_txn, :po_cash, 'DR', 5000), (:po_txn, :po_escrow, 'CR', 5000);
SELECT pg_temp.ok(fin.cash_owed(:ca) = 5000 AND fin.cash_limit(:ca) = 100000000,
  'Payment options: cash sold at a counter is owed by the carrier, within the default cash limit');
INSERT INTO fin.cash_credit_limit (company_id, limit_amount, reason, set_by) VALUES (:ca, 1000, 'probe limit', :uadmin);
SELECT pg_temp.ok(fin.cash_limit(:ca) = 1000, 'Payment options: a carrier''s own cash limit replaces the default');
SELECT pg_temp.expect_error(format($$INSERT INTO fin.cash_remittance (company_id, amount, method, recorded_by, status) VALUES (%s, 100, 'BANK_DEPOSIT', %s, 'CONFIRMED')$$,
  :ca, :uadmin), 'REMITTANCE_STATUS', 'Payment options: a remittance is recorded as pending first');
INSERT INTO fin.cash_remittance (company_id, amount, method, recorded_by) VALUES (:ca, 100, 'BANK_DEPOSIT', :uadmin) RETURNING id AS po_r \gset
SELECT pg_temp.expect_error(format($$UPDATE fin.cash_remittance SET status = 'REJECTED', confirmed_by = %s WHERE id = %s$$, :uadmin, :po_r),
  'FOUR_EYES', 'Payment options: whoever records a remittance does not confirm or reject it');
SELECT pg_temp.expect_error(format($$UPDATE fin.cash_remittance SET status = 'CONFIRMED', confirmed_by = %s WHERE id = %s$$, :ufin, :po_r),
  'cash_remittance_confirmed', 'Payment options: a confirmed remittance carries its ledger posting');
UPDATE fin.cash_remittance SET status = 'REJECTED', confirmed_by = :ufin WHERE id = :po_r;
SELECT pg_temp.expect_error(format($$UPDATE fin.cash_remittance SET status = 'PENDING' WHERE id = %s$$, :po_r),
  'REMITTANCE_FINAL', 'Payment options: a decided remittance does not change');
ROLLBACK;
SELECT pg_temp.ok(has_function_privilege('masslak_app', 'sales.expire_reservations()', 'EXECUTE')
  AND NOT has_function_privilege('public', 'sales.expire_reservations()', 'EXECUTE')
  AND NOT has_function_privilege('public', 'fin.cash_owed(bigint, character)', 'EXECUTE'),
  'Payment options: the expiry job and the cash figures run for the application only');
-- Review stage B (1057): ageing of the cash a carrier owes, oldest sales paid first. Closed ledger days refuse
-- back-dated entries, so the sales are placed ahead of now and aged as of a later day (now + 100 days)
BEGIN;
SELECT sys.set_context(:uadmin, NULL, 'SYSTEM');
INSERT INTO fin.wallet (owner_party_id, company_id, wallet_type, label, currency, allow_negative, balance_mode)
VALUES (:ca, :ca, 'CASH_COLLECT', 'Counter cash', 'SYP', true, 'IMMEDIATE') RETURNING id AS ag_cash \gset
SELECT w.id AS ag_escrow FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
 WHERE p.legal_name = 'Masslak Platform' AND w.wallet_type = 'ESCROW' AND w.currency = 'SYP' \gset
INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('BOOKING_PAY', 'SYP', 'ag-1') RETURNING id AS ag_t1 \gset
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount, created_at)
VALUES (:ag_t1, :ag_cash, 'DR', 3000, now()), (:ag_t1, :ag_escrow, 'CR', 3000, now());
INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('BOOKING_PAY', 'SYP', 'ag-2') RETURNING id AS ag_t2 \gset
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount, created_at)
VALUES (:ag_t2, :ag_cash, 'DR', 2000, now() + interval '60 days'), (:ag_t2, :ag_escrow, 'CR', 2000, now() + interval '60 days');
INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('BOOKING_PAY', 'SYP', 'ag-3') RETURNING id AS ag_t3 \gset
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount, created_at)
VALUES (:ag_t3, :ag_cash, 'DR', 1000, now() + interval '98 days'), (:ag_t3, :ag_escrow, 'CR', 1000, now() + interval '98 days');
INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key) VALUES ('CASH_NETTING', 'SYP', 'ag-4') RETURNING id AS ag_t4 \gset
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount, created_at)
VALUES (:ag_t4, :ag_escrow, 'DR', 3500, now() + interval '99 days'), (:ag_t4, :ag_cash, 'CR', 3500, now() + interval '99 days');
SELECT pg_temp.ok((SELECT row(owed, days_0_7, days_8_30, days_31_60, days_61_90, days_over_90, overdue)::text = '(2500,1000,0,1500,0,0,1500)'
                          AND oldest_unpaid_at = now() + interval '60 days' FROM fin.cash_aging(now() + interval '100 days') WHERE company_id = :ca),
  'Cash ageing: 6,000 sold and 3,500 set off leave 2,500 owed, made of the newest sales (1,000 of this week, 1,500 of a 40-day-old sale)');
SELECT pg_temp.ok((SELECT row(owed, days_31_60, overdue)::text = '(3000,3000,3000)' FROM fin.cash_aging(now() + interval '50 days') WHERE company_id = :ca),
  'Cash ageing: asked for an earlier day, only what was owed then counts, aged from that day');
SELECT pg_temp.ok((SELECT count(*) FROM sys.finance_metrics()) = 4
  AND (SELECT value FROM sys.finance_metrics() WHERE metric = 'masslak_cash_owed_minor') = (SELECT coalesce(sum(owed), 0) FROM fin.cash_aging()),
  'Cash ageing: what is owed and overdue reaches monitoring');
SELECT sys.set_context(NULL, :cb, 'COMPANY');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM fin.cash_aging(now() + interval '100 days') WHERE company_id = :ca),
  'Cash ageing: another carrier does not see what this one owes');
ROLLBACK;
SELECT pg_temp.ok(NOT has_function_privilege('public', 'fin.cash_aging(timestamp with time zone, character)', 'EXECUTE')
  AND has_function_privilege('masslak_app', 'sys.finance_metrics()', 'EXECUTE'),
  'Cash ageing: the figures are for the application, not for everyone');
-- Review stage C (1059): the application deletes only where sys.app_delete_grant says
SELECT pg_temp.ok(NOT EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'public', 'gis')
       AND has_table_privilege('masslak_app', c.oid, 'DELETE') <> EXISTS (SELECT 1 FROM sys.app_delete_grant g
                                                                           WHERE g.table_name = n.nspname || '.' || c.relname))
  AND (SELECT count(*) FROM sys.app_delete_grant) = 36,
  'Narrower grants: DELETE for the application on exactly the 36 listed tables');
SET ROLE masslak_app;
SELECT pg_temp.expect_error($$DELETE FROM sales.passenger WHERE id = -1$$, 'permission denied',
  'Narrower grants: the application cannot delete a business record, even one row-level security would show it');
RESET ROLE;
-- Review stage C (1058): the release manifest
SELECT pg_temp.ok((SELECT version = (SELECT version FROM sys.schema_migration ORDER BY string_to_array(version, '.')::int[] DESC LIMIT 1)
                     FROM sys.current_release())
  AND (SELECT files = (SELECT count(*) FROM sys.schema_file) AND hash_matches FROM sys.current_release()),
  'Release manifest: the build recorded the release, every applied file and their hash');
SELECT count(*) AS rm_rows FROM sys.release_manifest \gset
SELECT pg_temp.ok((SELECT id FROM sys.record_release('UPGRADE', 'unknown')) IS NOT NULL
  AND (SELECT count(*) FROM sys.release_manifest) <= :rm_rows + 1,
  'Release manifest: a run that changes nothing adds no second row');
SELECT count(*) AS rm_rows FROM sys.release_manifest \gset
SELECT pg_temp.ok((SELECT id FROM sys.record_release('UPGRADE', 'unknown')) IS NOT NULL AND (SELECT count(*) FROM sys.release_manifest) = :rm_rows,
  'Release manifest: recording the same release again changes nothing');
BEGIN;
DELETE FROM sys.schema_file WHERE file = (SELECT max(file) FROM sys.schema_file);
SELECT pg_temp.ok(NOT (SELECT hash_matches FROM sys.current_release()),
  'Release manifest: a file removed from the record by hand no longer matches the manifest (the upgrade refuses)');
ROLLBACK;
SELECT pg_temp.ok(has_function_privilege('masslak_app', 'sys.current_release()', 'EXECUTE')
  AND NOT has_function_privilege('masslak_app', 'sys.record_release(text, text)', 'EXECUTE')
  AND NOT has_table_privilege('masslak_app', 'sys.release_manifest', 'INSERT'),
  'Release manifest: the application reads the release and cannot record one');
SELECT pg_temp.ok(has_table_privilege('masslak_app', 'sys.schema_file', 'SELECT')
  AND NOT has_table_privilege('masslak_app', 'sys.schema_file', 'INSERT')
  AND NOT has_table_privilege('masslak_app', 'sys.schema_file', 'UPDATE')
  AND NOT has_table_privilege('masslak_app', 'sys.schema_file', 'DELETE'),
  'Readiness: the application reads which schema files are applied and cannot change the record');
-- Review stage D (1061): markets with their time zone and currency
SELECT pg_temp.ok((SELECT count(*) FROM ref.market WHERE is_default AND status = 'ACTIVE') = 1
  AND (SELECT time_zone || ' ' || currency FROM ref.market WHERE is_default) = 'Asia/Damascus SYP',
  'Markets: exactly one default market, open, in Damascus time and Syrian pounds');
SELECT pg_temp.expect_error($$UPDATE ref.market SET time_zone = 'Mars/Olympus' WHERE country_code = 'JO'$$, 'MARKET_TIMEZONE',
  'Markets: a market needs a real time zone');
SELECT pg_temp.expect_error($$UPDATE ref.market SET currency = 'USD' WHERE country_code = 'SY'$$, 'MARKET_CURRENCY_FIXED',
  'Markets: an open market keeps its currency');
SELECT pg_temp.ok((SELECT timezone FROM ref.city WHERE code = 'BEY') = 'Asia/Beirut'
  AND (SELECT timezone FROM ref.city WHERE code = 'AMM') = 'Asia/Amman',
  'Markets: Beirut and Amman carry their own time zones, not Damascus''s');
SELECT pg_temp.ok((SELECT bool_and(ref.company_currency(c.id) = 'SYP' AND ref.company_tz(c.id) = 'Asia/Damascus') FROM iam.company c)
  AND (SELECT ref.station_tz(min(s.id)) FROM net.station s JOIN ref.city c ON c.id = s.city_id WHERE c.code = 'DAM') = 'Asia/Damascus'
  AND (ref.market_of_country('FR')).country_code = 'SY',
  'Markets: companies and stations take their market''s time zone and currency; a country with no market falls in the default one');
BEGIN;
UPDATE ref.market SET status = 'ACTIVE' WHERE country_code = 'JO';
SELECT pg_temp.ok((SELECT count(*) FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
                    WHERE p.legal_name = 'Masslak Platform' AND w.currency = 'JOD') = 7
  AND (SELECT count(*) FROM sys.finance_metrics() WHERE labels ->> 'currency' = 'JOD') = 4,
  'Markets: opening a market creates the platform''s wallets in its currency and measures its counter cash apart');
INSERT INTO iam.party (party_type, legal_name, country_code) VALUES ('COMPANY', 'Amman Test Lines', 'JO');
SELECT pg_temp.ok(fin.cash_limit((SELECT id FROM iam.party WHERE legal_name = 'Amman Test Lines')) = 0
  AND ref.company_tz((SELECT id FROM iam.party WHERE legal_name = 'Amman Test Lines')) = 'Asia/Amman',
  'Markets: a carrier of another market keeps its time and has no cash limit until it is given one');
ROLLBACK;
SELECT pg_temp.expect_error(format($$UPDATE ops.trip SET currency = 'JOD' WHERE id = %s$$, (SELECT min(id) FROM ops.trip)),
  'TRIP_CURRENCY_UNSUPPORTED', 'Markets: a trip cannot be priced in the currency of a market that is not open');
-- Review stage C (1060): finer monitoring
SELECT pg_temp.ok((SELECT count(DISTINCT labels->>'table') FROM sys.partition_metrics())
                    = (SELECT count(*) FROM pg_class WHERE relkind = 'p' AND NOT relispartition)
  AND NOT EXISTS (SELECT 1 FROM sys.partition_metrics() WHERE metric = 'masslak_partition_ahead_seconds'
                   AND value < CASE labels->>'period' WHEN 'day' THEN 6 * 86400 ELSE 85 * 86400 END)
  AND NOT EXISTS (SELECT 1 FROM sys.partition_metrics() WHERE metric = 'masslak_partition_default_rows' AND value > 0),
  'Finer monitoring: every partitioned table reports how far ahead its partitions go and its default partition is empty');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM sys.lock_metrics())
  AND has_function_privilege('masslak_app', 'sys.lock_metrics()', 'EXECUTE')
  AND has_function_privilege('masslak_app', 'sys.partition_metrics()', 'EXECUTE')
  AND NOT has_function_privilege('masslak_auditor', 'sys.lock_metrics()', 'EXECUTE'),
  'Finer monitoring: lock waits per table are reported to the application only, and none is reported when nothing waits');
-- Review stage D (1062): change data capture to the data warehouse
SELECT pg_temp.ok(
  (SELECT count(*) FROM pg_publication_tables WHERE pubname = 'masslak_dw') = (SELECT count(*) FROM sys.dw_columns())
  AND NOT EXISTS (SELECT 1 FROM sys.dw_columns() d
                   WHERE (SELECT array_agg(c ORDER BY c) FROM unnest(d.columns) c)
                     IS DISTINCT FROM (SELECT array_agg(c::text ORDER BY c) FROM pg_publication_tables pt, unnest(pt.attnames) c
                                        WHERE pt.pubname = 'masslak_dw' AND format('%s.%s', pt.schemaname, pt.tablename) = d.table_name))
  AND (SELECT pubviaroot FROM pg_publication WHERE pubname = 'masslak_dw'),
  'Warehouse: the publication carries exactly the listed tables and columns, partitioned tables as one');
SELECT pg_temp.ok(NOT EXISTS (
    SELECT 1 FROM pg_publication_tables pt LEFT JOIN sys.table_class tc ON tc.table_name = pt.schemaname || '.' || pt.tablename
     WHERE pt.pubname = 'masslak_dw' AND coalesce(tc.data_class, 'unknown') NOT IN ('PUBLIC_CATALOG', 'TENANT_PRIVATE'))
  AND NOT EXISTS (
    SELECT 1 FROM pg_publication_tables pt, unnest(pt.attnames) c
     WHERE pt.pubname = 'masslak_dw'
       AND (c ~ '(name|email|phone|mobile|birth|national|document|passport|address|contact|booker|payer|party|family|memo|note|card|iban|account_no|device|token|secret)'
            OR c ~ '(^|_)(ip|lat|lon|lng|geom|position)(_|$)')
       AND (pt.schemaname, pt.tablename, c) <> ('ref', 'city', 'name')),
  'Warehouse: nothing personal is published: no person, security or audit table, no name, contact, identity, payer, booker, memo or card column (a city''s name aside)');
SELECT pg_temp.ok(
  (SELECT rolreplication AND rolbypassrls AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb FROM pg_roles WHERE rolname = 'masslak_cdc')
  AND NOT EXISTS (SELECT 1 FROM pg_auth_members WHERE member = 'masslak_cdc'::regrole)
  AND NOT EXISTS (SELECT 1 FROM information_schema.table_privileges WHERE grantee = 'masslak_cdc')
  AND (SELECT count(*) FROM information_schema.column_privileges WHERE grantee = 'masslak_cdc' AND privilege_type = 'SELECT')
      = (SELECT sum(cardinality(columns)) FROM sys.dw_columns())
  AND NOT EXISTS (SELECT 1 FROM information_schema.column_privileges WHERE grantee = 'masslak_cdc' AND privilege_type <> 'SELECT')
  AND NOT has_function_privilege('masslak_app', 'sys.dw_publish()', 'EXECUTE')
  AND has_function_privilege('masslak_app', 'sys.replication_metrics()', 'EXECUTE'),
  'Warehouse: the replication role reads the published columns and nothing else, and belongs to no other role');
-- Review stage D (1063): vehicle positions in a telemetry database
SELECT pg_temp.expect_error($$SELECT * FROM ops.accept_positions((SELECT min(id) FROM ops.trip),
                                     '[{"ts": "2026-10-08T10:00:00Z", "lat": 33.5, "lng": 36.3}]')$$,
  'NOT_ASSIGNED', 'Telemetry: positions are graded only for the signed-in driver''s own trip');
SELECT pg_temp.ok(
  ops.position_trust(ops.position_flags(now(), now(), 33.5, 36.3, 5, 'GPS', true, NULL, 1, NULL, NULL, NULL, NULL, NULL)) = 'REJECTED'
  AND ops.position_flags(now(), now(), 33.9, 36.3, 5, 'GPS', false, NULL, 4, NULL, now() - interval '1 minute', 33.5, 36.3, 5)
      @> ARRAY['IMPOSSIBLE_SPEED', 'OUT_OF_ORDER']
  AND ops.position_trust(ARRAY['LATE']) = 'LOW' AND ops.position_trust('{}') = 'HIGH'
  AND has_function_privilege('masslak_app', 'ops.accept_positions(bigint, jsonb)', 'EXECUTE')
  AND has_function_privilege('masslak_app', 'ops.position_retention()', 'EXECUTE')
  AND NOT has_function_privilege('masslak_app', 'ops.position_flags(timestamptz, timestamptz, numeric, numeric, real, text, boolean, timestamptz, bigint, bigint, timestamptz, numeric, numeric, bigint)', 'EXECUTE')
  AND (SELECT keep_days FROM ops.position_retention()) = (SELECT retention_days FROM gov.data_inventory WHERE dataset = 'ops.geo_event'),
  'Telemetry: one set of trust rules grades positions in both stores, and the telemetry database keeps them as long as the primary says');
-- 1066: positions with and without a vehicle are both graded (regression of 1063 found by the gate 4 rehearsal)
BEGIN;
INSERT INTO ops.geo_event (ts, lat, lng, accuracy_m, provider) VALUES (now(), 33.5, 36.3, 9, 'GPS');
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, provider)
SELECT now(), min(id), 33.5, 36.3, 9, 'GPS' FROM fleet.vehicle;
SELECT pg_temp.ok((SELECT count(*) FROM ops.geo_event WHERE ts > now() - interval '1 minute' AND trust IN ('HIGH', 'LOW')) >= 2,
  'Telemetry: a position without a vehicle is graded like any other');
ROLLBACK;
-- Review stage D (1064): bookings partitioned by ranges of id
SELECT pg_temp.ok(
  (SELECT relkind FROM pg_class WHERE oid = 'sales.booking'::regclass) = 'p'
  AND (SELECT pg_get_partkeydef('sales.booking'::regclass)) = 'RANGE (id)'
  AND (SELECT value FROM sys.partition_metrics() WHERE metric = 'masslak_partition_ids_ahead' AND labels->>'table' = 'sales.booking') >= 2
  AND NOT EXISTS (SELECT 1 FROM sales.booking b WHERE NOT EXISTS (SELECT 1 FROM sales.booking_key k WHERE k.booking_id = b.id
                    AND k.booking_ref = b.booking_ref AND k.uid = b.uid))
  AND (SELECT count(*) FROM pg_constraint WHERE confrelid = 'sales.booking'::regclass AND contype = 'f') >= 22
  AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'sales.booking'::regclass)
  AND has_table_privilege('masslak_app', 'sales.booking', 'INSERT') AND NOT has_table_privilege('masslak_app', 'sales.booking_key', 'SELECT'),
  'Partitioned bookings: by ranges of id, two ranges ahead, every booking''s keys registered, references, row security and grants kept');
SELECT pg_temp.expect_error(format($$UPDATE sales.booking SET booking_ref = (SELECT booking_ref FROM sales.booking WHERE id <> %1$s LIMIT 1) WHERE id = %1$s$$,
                                   (SELECT min(id) FROM sales.booking)),
  'booking_key_booking_ref_key', 'Partitioned bookings: a booking reference stays unique across all partitions');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM audit.row_change WHERE schema_name = 'sales' AND table_name = 'booking')
  AND NOT EXISTS (SELECT 1 FROM audit.row_change WHERE schema_name = 'sales' AND table_name LIKE 'booking\_p%'),
  'Partitioned bookings: the audit trail names the bookings table, not its partitions');
-- Review stage D (1065): automatic failover
SELECT pg_temp.ok(
  (SELECT count(*) FROM sys.ha_metrics()) = 3
  AND (SELECT value FROM sys.ha_metrics() WHERE metric = 'masslak_db_in_recovery') = 0
  AND has_function_privilege('masslak_app', 'sys.ha_metrics()', 'EXECUTE')
  AND NOT has_table_privilege('masslak_app', 'sys.failover_probe', 'INSERT')
  AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'sys.failover_probe'::regclass),
  'Failover: the standbys able to take over are reported to the application, and the drill''s table is the platform''s');
SET ROLE masslak_app;

\echo '=== ALL TESTS PASSED ==='

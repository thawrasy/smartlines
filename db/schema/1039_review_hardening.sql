-- =====================================================================
-- 1039: hardening after the database architecture review (Masslak_Database_Architecture_Review_AR_v1.0)
--   Each part names the review finding it closes. Findings that the existing schema already met are not repeated
--   here; docs/database/REVIEW_RESPONSE.md maps every finding to its evidence (file, constraint or test).
--
--   A  Request context: a narrow AUTH scope for sign-in, and rows a transaction just created          (3.2)
--   B  Data classification of every table and a security inventory view                              (3.1, 3.2)
--   C  Row-level security for the 83 tables that had none                                            (3.2, 3.4)
--   D  Restricted tables: no reporting access, row security forced                                   (3.2, 3.12)
--   E  Typed foreign keys behind the polymorphic references of decision records                      (3.3)
--   F  A row and its parent belong to the same company                                               (3.4)
--   G  Ledger: reversals mirror the original, balances move only through entries, reconciliation     (3.5)
--   H  Seat inventory: a sold segment matches its ticket; expired holds are released                 (3.8)
--   I  Business rules as constraints                                                                 (3.14)
--   J  Retention, legal hold and erasure by pseudonymisation                                         (3.15)
--   K  Tracking partitions and retention run by a maintenance function                               (3.7)
--   L  Scopes, purposes and a log of authorisation decisions                                         (3.11)
--   M  Encryption keys: versions, one active key per purpose, no new data under a retired key         (3.12)
--   N  Dormant modules are closed at the database, not only in the application                       (3.10)
--   O  Versioned reference data                                                                      (3.9)
-- =====================================================================

-- =====================================================================
-- A  Request context
-- =====================================================================
-- Sign-in reads accounts, tokens and factors before anyone is known. It now runs in its own AUTH scope, which opens
-- only those tables, instead of an unrestricted one.
CREATE OR REPLACE FUNCTION sys.ctx_is_auth() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT coalesce(sys.ctx_scope() = 'AUTH', false) $$;

-- Rows created by the current transaction. A company creating a staff account must read back the person row it has
-- just written, before the membership that will make it visible exists. A BEFORE INSERT trigger notes the new id in
-- a transaction-local setting, and the read rule accepts ids on that list (row security checks an inserted row,
-- RETURNING included, before it has a transaction id, so xmin cannot serve).
CREATE OR REPLACE FUNCTION sys.tg_remember_new_row() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE k text := 'app.new.' || TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
BEGIN
  PERFORM set_config(k, coalesce(nullif(current_setting(k, true), ''), '') || ',' || NEW.id::text, true);
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION sys.created_here(p_table text, p_id bigint) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_id::text = ANY (string_to_array(nullif(current_setting('app.new.' || p_table, true), ''), ','))
$$;
COMMENT ON FUNCTION sys.created_here IS 'True for a row inserted by the current transaction: its creator may read it back';

-- Separate read, insert and change rules. A new row has no transaction id while its insert rule is checked, so
-- "the creator may read it back" belongs to the read rule only.
CREATE OR REPLACE FUNCTION sys.rls_rw(p_table text, p_read text, p_insert text, p_change text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE pol text;
BEGIN
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_table);
  FOREACH pol IN ARRAY ARRAY['isolation','split_read','split_write','rw_read','rw_insert','rw_update','rw_delete'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %s', pol, p_table);
  END LOOP;
  EXECUTE format('CREATE POLICY rw_read ON %s FOR SELECT USING (%s)', p_table, p_read);
  EXECUTE format('CREATE POLICY rw_insert ON %s FOR INSERT WITH CHECK (%s)', p_table, p_insert);
  EXECUTE format('CREATE POLICY rw_update ON %s FOR UPDATE USING (%s) WITH CHECK (%s)', p_table, p_change, p_change);
  EXECUTE format('CREATE POLICY rw_delete ON %s FOR DELETE USING (sys.ctx_is_platform())', p_table);
END $$;
COMMENT ON FUNCTION sys.ctx_is_auth IS 'True while the API signs a user in or registers an account (scope AUTH)';

-- =====================================================================
-- B  Data classification
-- =====================================================================
CREATE TABLE IF NOT EXISTS sys.table_class (
  table_name  text PRIMARY KEY,                -- schema.table
  data_class  text NOT NULL CHECK (data_class IN (
                'PUBLIC_CATALOG',              -- everyone reads, the platform writes
                'PLATFORM_CONFIDENTIAL',       -- platform staff only
                'TENANT_PRIVATE',              -- one company (directly or through its parent row)
                'USER_PRIVATE',                -- one person and the platform
                'RESTRICTED_SECURITY',         -- credentials, factors, biometrics, authority orders: never reported
                'APPEND_ONLY_AUDIT',           -- written by the application, read by auditors only
                'SYSTEM')),                    -- schema bookkeeping
  tenant_path text,                            -- how the owner of a row is found (column or parent)
  note        text
);
COMMENT ON TABLE sys.table_class IS 'Data class of every table (review 3.2). A test fails when a table has no class or its RLS does not match its class';

-- =====================================================================
-- C  Row-level security for the tables that relied on the application alone
-- =====================================================================
-- ------------------------------ sign-in, identity and devices (3.2: auth_token, mfa_factor, device, biometric)
SELECT sys.rls_rw('iam.app_user',
  'sys.ctx_is_platform() OR sys.ctx_is_auth() OR id = sys.ctx_user_id() OR (party_id IS NOT NULL AND party_id = sys.ctx_party_id())'
  || ' OR sys.created_here(''iam.app_user'', app_user.id)'
  || ' OR EXISTS (SELECT 1 FROM iam.company_member m WHERE m.user_id = app_user.id AND sys.tenant_visible(m.company_id))',
  -- who may open an account: sign-up, the platform, and a company or agency adding its own staff
  'sys.ctx_is_platform() OR sys.ctx_is_auth() OR (account_kind IN (''COMPANY'',''AGENCY'') AND sys.ctx_scope() IN (''COMPANY'',''AGENCY'')'
  || ' AND sys.ctx_company_id() IS NOT NULL)',
  'sys.ctx_is_platform() OR sys.ctx_is_auth() OR id = sys.ctx_user_id() OR sys.created_here(''iam.app_user'', app_user.id)'
  || ' OR (sys.ctx_scope() IN (''COMPANY'',''AGENCY'') AND EXISTS (SELECT 1 FROM iam.company_member m'
  || '     WHERE m.user_id = app_user.id AND sys.tenant_visible(m.company_id)))');
-- The security console reads user e-mails next to log rows (column grant in create_login_roles.sql)
DROP POLICY IF EXISTS auditor_read ON iam.app_user;
CREATE POLICY auditor_read ON iam.app_user FOR SELECT TO masslak_auditor USING (true);
-- Sessions: an anonymous request used to see every session (no user in the context); now only sign-in does
SELECT sys.rls('iam.user_session', 'sys.ctx_is_platform() OR sys.ctx_is_auth() OR user_id = sys.ctx_user_id()'
  || ' OR (company_id IS NOT NULL AND sys.tenant_visible(company_id))');
SELECT sys.rls('iam.auth_token', 'sys.ctx_is_platform() OR sys.ctx_is_auth() OR user_id = sys.ctx_user_id()');
SELECT sys.rls('iam.mfa_factor', 'sys.ctx_is_platform() OR sys.ctx_is_auth() OR user_id = sys.ctx_user_id()');
SELECT sys.rls('iam.device', 'sys.ctx_is_platform() OR sys.ctx_is_auth() OR user_id = sys.ctx_user_id()');
SELECT sys.rls_parent('iam.push_token', 'device_id', 'iam.device');
SELECT sys.rls('iam.biometric_template', 'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()');
SELECT sys.rls('iam.gov_identity_link', 'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()');
SELECT sys.rls('iam.verification', 'sys.ctx_is_platform()'
  || ' OR (subject_type = ''PARTY'' AND subject_id = sys.ctx_party_id())'
  || ' OR (subject_type = ''COMPANY'' AND sys.tenant_visible(subject_id))'
  || ' OR (subject_type = ''VEHICLE'' AND EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = verification.subject_id AND sys.tenant_visible(v.company_id)))');
SELECT sys.rls('iam.user_role', 'sys.ctx_is_platform() OR user_id = sys.ctx_user_id()');
SELECT sys.rls_catalog('iam.identity_provider');
SELECT sys.rls_split('iam.role_permission',
  'EXISTS (SELECT 1 FROM iam.role r WHERE r.id = role_permission.role_id)',
  'EXISTS (SELECT 1 FROM iam.role r WHERE r.id = role_permission.role_id AND sys.tenant_visible(r.company_id))');

-- People are private; organisations (carriers, agencies, the platform) are a public directory.
SELECT sys.rls_rw('iam.party',
  'party_type <> ''PERSON'' OR sys.ctx_is_platform() OR sys.ctx_is_auth() OR id = sys.ctx_party_id() OR sys.created_here(''iam.party'', party.id)'
  || ' OR EXISTS (SELECT 1 FROM iam.app_user u JOIN iam.company_member m ON m.user_id = u.id'
  || '            WHERE u.party_id = party.id AND sys.tenant_visible(m.company_id))'
  || ' OR EXISTS (SELECT 1 FROM fleet.crew_profile cp WHERE cp.party_id = party.id AND sys.tenant_visible(cp.company_id))'
  || ' OR EXISTS (SELECT 1 FROM sales.passenger p WHERE p.party_id = party.id)'
  || ' OR EXISTS (SELECT 1 FROM iam.family_member fm WHERE fm.party_id = party.id)'
  || ' OR EXISTS (SELECT 1 FROM iam.family f WHERE f.head_party_id = party.id AND iam.is_member_of(f.id))'
  || ' OR EXISTS (SELECT 1 FROM sales.booking b WHERE b.booker_party_id = party.id)',
  -- any signed-in actor may record a person (a passenger, a family member, a new staff member); reading them is what is guarded
  'sys.ctx_is_platform() OR sys.ctx_is_auth() OR sys.ctx_user_id() IS NOT NULL',
  'sys.ctx_is_platform() OR sys.ctx_is_auth() OR id = sys.ctx_party_id() OR sys.created_here(''iam.party'', party.id)'
  || ' OR (party_type <> ''PERSON'' AND sys.tenant_visible(id))'
  || ' OR EXISTS (SELECT 1 FROM iam.app_user u JOIN iam.company_member m ON m.user_id = u.id'
  || '            WHERE u.party_id = party.id AND sys.tenant_visible(m.company_id))'
  || ' OR EXISTS (SELECT 1 FROM fleet.crew_profile cp WHERE cp.party_id = party.id AND sys.tenant_visible(cp.company_id))'
  || ' OR iam.is_head_of_party(party.id)');
SELECT sys.rls_rw('iam.party_role',
  'EXISTS (SELECT 1 FROM iam.party p WHERE p.id = party_role.party_id)',
  'sys.ctx_is_platform() OR sys.ctx_is_auth() OR sys.ctx_user_id() IS NOT NULL',
  'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()');

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['iam.party','iam.app_user','fin.ledger_txn'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS aa_remember_new_row ON %s', t);
    EXECUTE format('CREATE TRIGGER aa_remember_new_row BEFORE INSERT ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_remember_new_row()', t);
  END LOOP;
END $$;

-- ------------------------------ trip operations (3.2 and 3.4: trip_stop, seat/standing segments, geo events)
-- Timetable rows of a published trip are public, like the trip; only the trip's company changes them.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ops.trip_stop','ops.standing_segment','ops.trip_pair_fare','ops.family_zone'] LOOP
    PERFORM sys.rls_split(t,
      format('EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = %s.trip_id)', (parse_ident(t))[2]),
      format('EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = %s.trip_id AND sys.tenant_visible(x.company_id))', (parse_ident(t))[2]));
  END LOOP;
END $$;
-- Seats: a signed-in passenger takes a free seat or gives back their own hold; selling, blocking and freeing
-- sold seats stay with the trip's company and the platform.
SELECT sys.rls_split('ops.seat_segment',
  'EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = seat_segment.trip_id)',
  'EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = seat_segment.trip_id AND sys.tenant_visible(x.company_id))');
DROP POLICY IF EXISTS passenger_hold ON ops.seat_segment;
CREATE POLICY passenger_hold ON ops.seat_segment FOR UPDATE
  USING (sys.ctx_user_id() IS NOT NULL AND EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = seat_segment.trip_id)
         AND (status = 'AVAILABLE' OR (status = 'LOCKED' AND (lock_user_id = sys.ctx_user_id() OR lock_expires_at <= now()))))
  WITH CHECK ((status = 'LOCKED' AND lock_user_id = sys.ctx_user_id())
              OR (status = 'AVAILABLE' AND lock_user_id IS NULL AND ticket_id IS NULL));

SELECT sys.rls('ops.geo_event', 'sys.ctx_is_platform()'
  || ' OR (trip_id IS NOT NULL AND EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = geo_event.trip_id AND sys.tenant_visible(x.company_id)))'
  || ' OR (vehicle_id IS NOT NULL AND EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = geo_event.vehicle_id AND sys.tenant_visible(v.company_id)))'
  || ' OR (driver_user_id IS NOT NULL AND driver_user_id = sys.ctx_user_id())');
SELECT sys.rls_parent('ops.incident_evidence', 'incident_id', 'ops.incident');
SELECT sys.rls_parent('ops.incident_external_link', 'incident_id', 'ops.incident');
SELECT sys.rls_trip('ops.trip_disruption', 'sys.tenant_visible(trip_disruption.partner_company_id)');
SELECT sys.rls_trip('sales.boarding_event', 'EXISTS (SELECT 1 FROM sales.ticket k WHERE k.id = boarding_event.ticket_id)');
SELECT sys.rls_trip('sec.sos_event', 'sos_event.triggered_by = sys.ctx_user_id()');
SELECT sys.rls_split('crm.trip_rating', 'true', 'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()');

-- ------------------------------ fleet
SELECT sys.rls_parent('fleet.field_check_log', 'vehicle_id', 'fleet.vehicle');
SELECT sys.rls_parent('fleet.vehicle_qr_tag', 'vehicle_id', 'fleet.vehicle');
SELECT sys.rls_parent('fleet.vehicle_status_history', 'vehicle_id', 'fleet.vehicle');
SELECT sys.rls_parent('fleet.license_change_request', 'license_record_id', 'fleet.license_record');

-- ------------------------------ network
SELECT sys.rls_split('net.route_stop',
  'EXISTS (SELECT 1 FROM net.route r WHERE r.id = route_stop.route_id)',
  'EXISTS (SELECT 1 FROM net.route r WHERE r.id = route_stop.route_id AND sys.tenant_visible(r.company_id))');
SELECT sys.rls_split('net.station_contact',
  'EXISTS (SELECT 1 FROM net.station s WHERE s.id = station_contact.station_id)',
  'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM net.station s WHERE s.id = station_contact.station_id'
  || ' AND s.station_class <> ''CENTRAL'' AND s.owner_company_id = sys.ctx_company_id())');
SELECT sys.rls_platform('net.code_reservation');

-- ------------------------------ money (3.2: ledger_txn, ledger_entry, payment_notification, bank_transfer_topup)
SELECT sys.rls_parent('fin.ledger_entry', 'wallet_id', 'fin.wallet');
SELECT sys.rls_rw('fin.ledger_txn',
  'sys.ctx_is_platform() OR sys.created_here(''fin.ledger_txn'', ledger_txn.id) OR EXISTS (SELECT 1 FROM fin.ledger_entry e WHERE e.txn_id = ledger_txn.id)',
  'sys.ctx_is_platform() OR sys.ctx_user_id() IS NOT NULL',
  'false');                                -- ledger rows never change (and a trigger says so)
SELECT sys.rls('fin.payment_notification', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM fin.payment p WHERE p.id = payment_notification.payment_id)');
SELECT sys.rls('fin.bank_transfer_topup', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM fin.wallet w WHERE w.id = bank_transfer_topup.wallet_id)');

-- ------------------------------ pricing
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pricing.allocation_template','pricing.allocation_template_line','pricing.commission_scheme',
                           'pricing.commission_rule','pricing.rate_band','pricing.loyalty_program','pricing.loyalty_rule',
                           'pricing.loyalty_tier'] LOOP
    PERFORM sys.rls_catalog(t);
  END LOOP;
END $$;
SELECT sys.rls_split('pricing.fare_table_item',
  'EXISTS (SELECT 1 FROM pricing.fare_table f WHERE f.id = fare_table_item.fare_table_id)',
  'EXISTS (SELECT 1 FROM pricing.fare_table f WHERE f.id = fare_table_item.fare_table_id AND sys.tenant_visible(f.company_id))');
SELECT sys.rls('pricing.points_account', 'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()');
SELECT sys.rls_parent('pricing.points_ledger', 'account_id', 'pricing.points_account');
SELECT sys.rls('pricing.promo_code', 'sys.ctx_is_platform() OR owner_party_id = sys.ctx_party_id()'
  || ' OR EXISTS (SELECT 1 FROM pricing.campaign c WHERE c.id = promo_code.campaign_id AND c.company_id IS NOT NULL AND sys.tenant_visible(c.company_id))');

-- ------------------------------ sales channels: the platform's own channels are public, partner channels are private
SELECT sys.rls_split('sales.channel',
  'party_id IS NULL OR sys.ctx_is_platform() OR party_id = sys.ctx_company_id() OR api_client_id = sys.ctx_api_client_id()',
  'sys.ctx_is_platform() OR party_id = sys.ctx_company_id()');

-- ------------------------------ customer care
SELECT sys.rls_parent('crm.ai_message', 'conversation_id', 'crm.ai_conversation');
SELECT sys.rls_parent('crm.ai_tool_call', 'conversation_id', 'crm.ai_conversation');
SELECT sys.rls_parent('crm.case_event', 'case_id', 'crm."case"');

-- ------------------------------ authorities and security (3.2: authority_order, authority_data_request, signatures)
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['sec.authority_order','sec.authority_data_request','sec.authority_policy'] LOOP
    PERFORM sys.rls_platform(t);
  END LOOP;
END $$;
-- Which authorities exist (name and type) is shown to carriers next to their manifests; only the platform changes them
SELECT sys.rls_split('sec.authority_profile', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('sec.document_signature', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM ref.file_object f WHERE f.id = document_signature.file_id)');
SELECT sys.rls('sec.tamper_event', 'sys.ctx_is_platform() OR user_id = sys.ctx_user_id()');

-- ------------------------------ accounting and tax
SELECT sys.rls_parent('acct.account_mapping', 'connection_id', 'acct.accounting_connection');
SELECT sys.rls_parent('acct.sync_item', 'connection_id', 'acct.accounting_connection');
SELECT sys.rls_parent('acct.einvoice_line', 'document_id', 'acct.einvoice_document');
SELECT sys.rls_parent('acct.einvoice_submission', 'document_id', 'acct.einvoice_document');
SELECT sys.rls_parent('acct.journal_line', 'entry_id', 'acct.journal_entry');
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['acct.einvoice_activation','acct.einvoice_template','acct.tax_profile_field','acct.posting_rule'] LOOP
    PERFORM sys.rls_catalog(t);
  END LOOP;
END $$;
-- A tax profile belongs to a party: a company (its own profile) or a person
SELECT sys.rls('acct.tax_profile', 'sys.ctx_is_platform() OR party_id = sys.ctx_party_id() OR sys.tenant_visible(party_id)');
SELECT sys.rls_parent('acct.tax_profile_value', 'profile_id', 'acct.tax_profile');
SELECT sys.rls_parent('acct.tax_registration', 'profile_id', 'acct.tax_profile');
SELECT sys.rls_parent('acct.tax_return', 'profile_id', 'acct.tax_profile');
SELECT sys.rls_parent('acct.tax_return_line', 'return_id', 'acct.tax_return');
SELECT sys.rls_parent('acct.einvoice_unit', 'profile_id', 'acct.tax_profile');
SELECT sys.rls('acct.tax_payment', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM acct.tax_profile p WHERE p.id = tax_payment.profile_id)');
SELECT sys.rls('acct.tax_collection_no_file', 'sys.ctx_is_platform() OR payer_party_id = sys.ctx_party_id() OR sys.tenant_visible(payer_party_id)');

-- ------------------------------ system tables
SELECT sys.rls_catalog('sys.setting');
SELECT sys.rls_catalog('sys.schema_migration');
SELECT sys.rls_platform('sys.table_class');
GRANT SELECT ON sys.table_class TO masslak_app, masslak_readonly, masslak_auditor;

-- ------------------------------ audit logs: the application appends, auditors read, nobody else sees them
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['audit.activity_log','audit.auth_event','audit.data_access_log','audit.log_seal','audit.row_change'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS audit_append ON %s', t);
    EXECUTE format('DROP POLICY IF EXISTS audit_read ON %s', t);
    EXECUTE format('CREATE POLICY audit_append ON %s FOR INSERT TO masslak_app WITH CHECK (true)', t);
    EXECUTE format('CREATE POLICY audit_read ON %s FOR SELECT TO masslak_auditor USING (true)', t);
  END LOOP;
END $$;

DROP FUNCTION IF EXISTS sys.row_is_new(xid);         -- an earlier draft of sys.created_here

-- =====================================================================
-- D  Restricted tables: never in reporting, row security forced where no definer function relies on the owner
-- =====================================================================
DO $$
DECLARE t text; used boolean;
BEGIN
  FOREACH t IN ARRAY ARRAY['iam.auth_token','iam.mfa_factor','iam.biometric_template','iam.gov_identity_link','iam.verification',
                           'iam.device','iam.push_token','iam.user_session','iam.api_key','sec.authority_order',
                           'sec.authority_data_request','sec.authority_policy','sec.tamper_event','sec.break_glass_log',
                           'sec.key_registry'] LOOP
    CONTINUE WHEN to_regclass(t) IS NULL;
    EXECUTE format('REVOKE ALL ON %s FROM masslak_readonly', t);
    -- the key registry is read by the key-status trigger of part M, which must see every key
    SELECT t = 'sec.key_registry' OR EXISTS (SELECT 1 FROM pg_proc WHERE prosecdef AND prosrc ILIKE '%' || t || '%') INTO used;
    IF NOT used THEN
      EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    ELSE
      EXECUTE format('ALTER TABLE %s NO FORCE ROW LEVEL SECURITY', t);
    END IF;
  END LOOP;
END $$;
-- Only the owner may change a table's security; the runtime roles must never own tables or bypass RLS
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('masslak_app','masslak_api','masslak_readonly','masslak_auditor','masslak_audit')
               AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION 'RUNTIME_ROLE_BYPASSES_RLS: a runtime role is superuser or has BYPASSRLS';
  END IF;
END $$;

-- =====================================================================
-- E  Typed foreign keys behind polymorphic references (3.3)
--   The (type, id) pair stays for the application; a trigger copies the id into the column of its type, and that
--   column is a real foreign key (existence, type and ON DELETE RESTRICT). At most one typed column is set.
--   Audit, outbox and ledger references stay polymorphic on purpose: they are metadata, never a decision input.
-- =====================================================================
CREATE OR REPLACE FUNCTION sys.tg_typed_reference() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  type_col text := TG_ARGV[0]; id_col text := TG_ARGV[1]; map jsonb := TG_ARGV[2]::jsonb; prefix text := TG_ARGV[3];
  rec jsonb := to_jsonb(NEW); k text; patch jsonb := '{}'::jsonb;
BEGIN
  FOR k IN SELECT jsonb_object_keys(map) LOOP
    patch := patch || jsonb_build_object(prefix || '_' || lower(k) || '_id',
               CASE WHEN rec ->> type_col = k THEN rec -> id_col ELSE 'null'::jsonb END);
  END LOOP;
  NEW := jsonb_populate_record(NEW, patch);
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION sys.typed_reference(p_table text, p_type_col text, p_id_col text, p_map jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  prefix text := regexp_replace(p_type_col, '_type$', '');
  rel text := (parse_ident(p_table))[2];
  k text; target text; col text; fk text; cols text[] := '{}'; live jsonb := '{}'::jsonb;
BEGIN
  FOR k, target IN SELECT key, value #>> '{}' FROM jsonb_each(p_map) LOOP
    CONTINUE WHEN to_regclass(target) IS NULL
               OR NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass(target) AND attname = 'id' AND NOT attisdropped);
    col := prefix || '_' || lower(k) || '_id';
    fk := left(rel || '_' || col || '_fk', 63);
    cols := cols || col;
    live := live || jsonb_build_object(k, target);
    EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS %I bigint', p_table, col);
    EXECUTE format('COMMENT ON COLUMN %s.%I IS %L', p_table, col,
                   format('Typed reference: set from %s/%s when %s = %s (review 3.3)', p_type_col, p_id_col, p_type_col, k));
    -- one-off copy of existing rows: append-only tables block updates, so their triggers pause for this statement only
    EXECUTE format('ALTER TABLE %s DISABLE TRIGGER USER', p_table);
    EXECUTE format('UPDATE %s SET %I = %I WHERE %I = %L AND %I IS DISTINCT FROM %I', p_table, col, p_id_col, p_type_col, k, col, p_id_col);
    EXECUTE format('ALTER TABLE %s ENABLE TRIGGER USER', p_table);
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = p_table::regclass AND conname = fk) THEN
      EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %s (id) ON DELETE RESTRICT NOT VALID',
                     p_table, fk, col, target);
      BEGIN
        EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', p_table, fk);
      EXCEPTION WHEN foreign_key_violation THEN
        RAISE WARNING 'ORPHAN_REFERENCES: %.% points to missing rows of %; new rows are checked, old ones need repair', p_table, col, target;
      END;
    END IF;
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %s (%I) WHERE %I IS NOT NULL', left(rel || '_' || col || '_idx', 63), p_table, col, col);
  END LOOP;
  EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', p_table, left(rel || '_' || prefix || '_one_ref', 63));
  EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (num_nonnulls(%s) <= 1)', p_table, left(rel || '_' || prefix || '_one_ref', 63),
                 (SELECT string_agg(quote_ident(c), ', ') FROM unnest(cols) c));
  EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', left(prefix || '_typed_ref', 63), p_table);
  EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF %I, %I ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_typed_reference(%L, %L, %L, %L)',
                 left(prefix || '_typed_ref', 63), p_type_col, p_id_col, p_table, p_type_col, p_id_col, live::text, prefix);
END $$;
COMMENT ON FUNCTION sys.typed_reference IS 'Adds one real foreign key per type behind a (type, id) reference, filled by a trigger (review 3.3)';

SELECT sys.typed_reference('iam.document', 'owner_type', 'owner_id', '{"PARTY":"iam.party","COMPANY":"iam.company","VEHICLE":"fleet.vehicle",
  "STATION":"net.station","LEASE":"fleet.vehicle_lease","INSURANCE":"fleet.insurance_policy","LICENSE":"fleet.license_record","INCIDENT":"ops.incident"}');
SELECT sys.typed_reference('iam.verification', 'subject_type', 'subject_id', '{"PARTY":"iam.party","COMPANY":"iam.company","VEHICLE":"fleet.vehicle","DOCUMENT":"iam.document"}');
SELECT sys.typed_reference('fleet.license_record', 'subject_type', 'subject_id', '{"VEHICLE":"fleet.vehicle","TRAILER":"fleet.trailer","DRIVER":"iam.party",
  "COMPANY":"iam.company","STATION":"net.station","PARTNER":"ptn.partner"}');
SELECT sys.typed_reference('sec.screening_request', 'subject_type', 'subject_id', '{"PASSENGER":"iam.party","DRIVER":"iam.party","HOST":"iam.party",
  "VEHICLE":"fleet.vehicle","COMPANY":"iam.company"}');
SELECT sys.typed_reference('sec.screening_request', 'context_type', 'context_id', '{"BOOKING":"sales.booking","TRIP":"ops.trip"}');
SELECT sys.typed_reference('sec.risk_assessment', 'subject_type', 'subject_id', '{"USER":"iam.app_user","PARTY":"iam.party","BOOKING":"sales.booking",
  "PAYMENT":"fin.payment","WITHDRAWAL":"fin.withdrawal_request","API_CLIENT":"iam.api_client"}');
SELECT sys.typed_reference('sec.verification_job', 'subject_type', 'subject_id', '{"PARTY":"iam.party","VEHICLE":"fleet.vehicle","LICENSE":"fleet.license_record",
  "COMPANY":"iam.company","DOCUMENT":"iam.document"}');
SELECT sys.typed_reference('fin.price_allocation', 'subject_type', 'subject_id', '{"BOOKING":"sales.booking","TICKET":"sales.ticket","SHIPMENT":"ship.shipment",
  "FREIGHT_LEG":"ship.shipment_leg","SUBSCRIPTION":"sales.subscription"}');
SELECT sys.typed_reference('brd.manifest_response', 'subject_type', 'subject_id', '{"PERSON":"brd.manifest_person","VEHICLE":"fleet.vehicle","CARGO":"brd.manifest_cargo"}');
SELECT sys.typed_reference('brd.manifest_discrepancy', 'subject_type', 'subject_id', '{"PERSON":"brd.manifest_person","VEHICLE":"fleet.vehicle","CARGO":"brd.manifest_cargo"}');
SELECT sys.typed_reference('acct.einvoice_document', 'source_type', 'source_id', '{"BOOKING":"sales.booking","TICKET":"sales.ticket","SHIPMENT":"ship.shipment",
  "SUBSCRIPTION":"sales.subscription","REFUND":"sales.refund_request"}');
SELECT sys.typed_reference('acct.sales_invoice', 'source_type', 'source_id', '{"BOOKING":"sales.booking","SHIPMENT":"ship.shipment","SUBSCRIPTION":"sales.subscription"}');
-- Authority orders and fraud cases had free-text types: they get a closed list first
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'authority_order_target_type_ck') THEN
    ALTER TABLE sec.authority_order ADD CONSTRAINT authority_order_target_type_ck CHECK (target_type IN
      ('PARTY','USER','BOOKING','TICKET','TRIP','VEHICLE','COMPANY','WALLET','PAYMENT','DOCUMENT')) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fraud_case_subject_type_ck') THEN
    ALTER TABLE sec.fraud_case ADD CONSTRAINT fraud_case_subject_type_ck CHECK (subject_type IN
      ('USER','PARTY','BOOKING','PAYMENT','WITHDRAWAL','API_CLIENT','COMPANY','DEVICE','IP')) NOT VALID;
  END IF;
END $$;
SELECT sys.typed_reference('sec.authority_order', 'target_type', 'target_id', '{"PARTY":"iam.party","USER":"iam.app_user","BOOKING":"sales.booking",
  "TICKET":"sales.ticket","TRIP":"ops.trip","VEHICLE":"fleet.vehicle","COMPANY":"iam.company","WALLET":"fin.wallet","PAYMENT":"fin.payment","DOCUMENT":"iam.document"}');
SELECT sys.typed_reference('sec.fraud_case', 'subject_type', 'subject_id', '{"USER":"iam.app_user","PARTY":"iam.party","BOOKING":"sales.booking",
  "PAYMENT":"fin.payment","WITHDRAWAL":"fin.withdrawal_request","API_CLIENT":"iam.api_client","COMPANY":"iam.company","DEVICE":"iam.device"}');

-- Integrity triggers of earlier files that read a table protected above: they must see every row, not the caller's
-- view of it (a balance check that saw only the caller's ledger lines would reject or accept the wrong transaction)
ALTER FUNCTION fin.tg_ledger_txn_balanced() SECURITY DEFINER SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION acct.tg_journal_guard() SECURITY DEFINER SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION fleet.tg_license_locked() SECURITY DEFINER SET search_path = pg_catalog, pg_temp;

-- Validation triggers below run as the owner (SECURITY DEFINER with a fixed search_path): a rule must see the
-- rows it checks even when the caller's row security hides them, or a cross-tenant reference would pass unseen.
-- =====================================================================
-- F  A row and the row it points to belong to the same company (3.4)
--   Checked when both carry a company. References that may cross companies by design are not listed:
--   leased vehicles on trips, partner stations selling fuel to carriers, parcels riding another carrier's trip.
-- =====================================================================
CREATE OR REPLACE FUNCTION sys.tg_same_company() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE fk_col text := TG_ARGV[0]; parent text := TG_ARGV[1]; ref bigint; mine bigint; theirs bigint;
BEGIN
  ref := (to_jsonb(NEW) ->> fk_col)::bigint;
  mine := (to_jsonb(NEW) ->> 'company_id')::bigint;
  IF ref IS NULL OR mine IS NULL THEN RETURN NEW; END IF;
  EXECUTE format('SELECT company_id FROM %s WHERE id = $1', parent) INTO theirs USING ref;
  IF theirs IS NOT NULL AND theirs <> mine THEN
    RAISE EXCEPTION 'TENANT_MISMATCH: %.% points to a row of another company (% -> %)', TG_TABLE_NAME, fk_col, parent, ref
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION sys.tg_same_company IS 'Rejects a reference to a row of another company (review 3.4)';

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('acct.cash_box','account_id','acct.gl_account'), ('acct.cash_payment','account_id','acct.gl_account'),
    ('acct.cash_payment','journal_entry_id','acct.journal_entry'), ('acct.cash_payment','wallet_id','fin.wallet'),
    ('acct.cash_receipt','invoice_id','acct.sales_invoice'), ('acct.cash_receipt','journal_entry_id','acct.journal_entry'),
    ('acct.cash_receipt','wallet_id','fin.wallet'), ('acct.cost_center','route_id','net.route'), ('acct.cost_center','trip_id','ops.trip'),
    ('acct.credit_note','einvoice_document_id','acct.einvoice_document'), ('acct.credit_note','invoice_id','acct.sales_invoice'),
    ('acct.einvoice_document','original_doc_id','acct.einvoice_document'), ('acct.gl_account','parent_id','acct.gl_account'),
    ('acct.journal_entry','reversed_by_id','acct.journal_entry'), ('acct.sales_invoice','einvoice_document_id','acct.einvoice_document'),
    ('acct.sales_invoice','journal_entry_id','acct.journal_entry'), ('acct.tax_code','account_id','acct.gl_account'),
    ('bill.billed_usage','invoice_id','bill.carrier_invoice'), ('bill.billed_usage','subscription_id','bill.company_subscription'),
    ('bill.carrier_invoice','subscription_id','bill.company_subscription'), ('bill.company_subscription','agreement_id','bill.carrier_agreement'),
    ('crm."case"','booking_id','sales.booking'), ('crm."case"','trip_id','ops.trip'), ('crm.call','case_id','crm."case"'),
    ('crm.trip_rating','trip_id','ops.trip'), ('fin.payout','settlement_batch_id','fin.settlement_batch'),
    ('fin.withdrawal_request','wallet_id','fin.wallet'), ('fleet.boarding_validator','vehicle_id','fleet.vehicle'),
    ('fleet.driving_hours_log','trip_id','ops.trip'), ('fleet.insurance_claim','incident_id','ops.incident'),
    ('fleet.license_record','document_id','iam.document'), ('fleet.license_record','subject_vehicle_id','fleet.vehicle'),
    ('fleet.seat_price_rule','vehicle_id','fleet.vehicle'), ('fleet.seat_price_rule','seat_layout_id','fleet.seat_layout'),
    ('fleet.truck_combination','trailer_id','fleet.trailer'), ('fleet.vehicle','seat_layout_id','fleet.seat_layout'),
    ('fleet.vehicle_fuel_profile','vehicle_id','fleet.vehicle'), ('fleet.vehicle_service_status','vehicle_id','fleet.vehicle'),
    ('fleet.vehicle_service_status','incident_id','ops.incident'), ('iam.company_member','role_id','iam.role'),
    ('iam.document','owner_vehicle_id','fleet.vehicle'), ('net.service_number','route_id','net.route'),
    ('ops.incident','trip_id','ops.trip'), ('ops.trip','route_id','net.route'), ('ops.trip','service_number_id','net.service_number'),
    ('ops.trip','template_id','ops.trip_template'), ('ops.trip_template','route_id','net.route'),
    ('ops.trip_template','service_number_id','net.service_number'), ('pricing.award_seat_rule','route_id','net.route'),
    ('pricing.category_fare_rule','route_id','net.route'), ('pricing.family_offer','route_id','net.route'),
    ('pricing.fare_table','route_id','net.route'), ('rail.coach_layout','fare_class_id','rail.fare_class'),
    ('rent.rental_booking','pickup_branch_id','rent.rental_branch'), ('rent.rental_booking','return_branch_id','rent.rental_branch'),
    ('rent.rental_booking','rate_id','rent.rental_rate'), ('rent.rental_booking','vehicle_id','rent.rental_fleet'),
    ('rent.rental_fleet','home_branch_id','rent.rental_branch'), ('rent.rental_fleet','vehicle_id','fleet.vehicle'),
    ('rent.rental_rate','branch_id','rent.rental_branch'), ('rent.telematics_device','vehicle_id','fleet.vehicle'),
    ('rpt.report_run','definition_id','rpt.report_definition'), ('rpt.report_schedule','definition_id','rpt.report_definition'),
    ('sales.booking','trip_id','ops.trip'), ('sales.channel_inventory_rule','route_id','net.route'),
    ('sales.subscription','plan_id','sales.subscription_plan'), ('ship.cargo_rate_card','route_id','net.route'),
    ('ship.courier_route','hub_id','ship.hub'), ('ship.handling_unit','parent_unit_id','ship.handling_unit'),
    ('ship.load','dest_hub_id','ship.hub'), ('ship.load','origin_hub_id','ship.hub'), ('ship.pickup_request','courier_route_id','ship.courier_route'),
    ('ship.pricing_agreement','account_id','ship.shipper_account'), ('ship.shipment','payer_account_id','ship.shipper_account'),
    ('ship.shipment','shipper_account_id','ship.shipper_account'), ('ship.shipper_account','pricing_agreement_id','ship.pricing_agreement'),
    ('ship.shipper_account','wallet_id','fin.wallet'), ('taxi.taxi_permit','office_id','taxi.taxi_office'),
    ('taxi.taxi_permit','vehicle_id','fleet.vehicle')
  ) v(tbl, col, parent) LOOP
    CONTINUE WHEN to_regclass(r.tbl) IS NULL OR to_regclass(r.parent) IS NULL;
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', left('same_company_' || r.col, 63), r.tbl);
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF %I, company_id ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_same_company(%L, %L)',
                   left('same_company_' || r.col, 63), r.col, r.tbl, r.col, r.parent);
  END LOOP;
END $$;

-- =====================================================================
-- G  Ledger (3.5). Already enforced before this file: one currency per transaction and wallets of that currency only,
--   debits equal credits with at least two lines (checked at commit), immutable rows, a unique idempotency key per
--   transaction, no negative balance. Added here:
-- =====================================================================
-- 1) Posting batches with a control total, the event a transaction came from, and the reason of a reversal
CREATE TABLE IF NOT EXISTS fin.posting_batch (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  source        text NOT NULL,                        -- settlement, payout run, import...
  currency      char(3) NOT NULL REFERENCES ref.currency(code),
  control_total bigint NOT NULL CHECK (control_total >= 0),   -- sum of debit lines expected in the batch
  entry_count   int NOT NULL CHECK (entry_count >= 0),
  closed_at     timestamptz,
  created_by    bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS posting_batch_created_by_idx ON fin.posting_batch (created_by);
CREATE INDEX IF NOT EXISTS posting_batch_currency_idx ON fin.posting_batch (currency);
COMMENT ON TABLE fin.posting_batch IS 'A group of ledger transactions posted together; closing it checks the control total (review 3.5)';
ALTER TABLE fin.ledger_txn ADD COLUMN IF NOT EXISTS posting_batch_id bigint REFERENCES fin.posting_batch(id);
ALTER TABLE fin.ledger_txn ADD COLUMN IF NOT EXISTS source_event_id uuid;
ALTER TABLE fin.ledger_txn ADD COLUMN IF NOT EXISTS reversal_reason text;
COMMENT ON COLUMN fin.ledger_txn.source_event_id IS 'External: the outbox or provider event that produced this transaction';
COMMENT ON COLUMN fin.ledger_txn.reversal_reason IS 'Why a reversal was posted (required when reverses_txn_id is set)';
CREATE INDEX IF NOT EXISTS ledger_txn_posting_batch_idx ON fin.ledger_txn (posting_batch_id);
CREATE UNIQUE INDEX IF NOT EXISTS ledger_txn_one_reversal ON fin.ledger_txn (reverses_txn_id) WHERE reverses_txn_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ledger_txn_source_event ON fin.ledger_txn (source_event_id, txn_type) WHERE source_event_id IS NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ledger_txn_reversal_reason_ck') THEN
    ALTER TABLE fin.ledger_txn ADD CONSTRAINT ledger_txn_reversal_reason_ck
      CHECK (reverses_txn_id IS NULL OR length(btrim(coalesce(reversal_reason, ''))) > 0) NOT VALID;
  END IF;
END $$;

-- 2) A reversal mirrors the original exactly: same currency, same wallets and amounts, opposite directions
CREATE OR REPLACE FUNCTION fin.tg_reversal_mirrors() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE orig fin.ledger_txn%ROWTYPE; diff int;
BEGIN
  IF NEW.reverses_txn_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO orig FROM fin.ledger_txn WHERE id = NEW.reverses_txn_id;
  IF orig.reverses_txn_id IS NOT NULL THEN
    RAISE EXCEPTION 'REVERSAL_OF_REVERSAL: txn % already is a reversal', orig.id USING ERRCODE = 'P0001';
  END IF;
  IF orig.currency <> NEW.currency THEN
    RAISE EXCEPTION 'REVERSAL_CURRENCY: % reverses a % transaction', NEW.currency, orig.currency USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO diff FROM (
    (SELECT wallet_id, CASE direction WHEN 'DR' THEN 'CR' ELSE 'DR' END AS direction, amount FROM fin.ledger_entry WHERE txn_id = orig.id
     EXCEPT ALL SELECT wallet_id, direction::text, amount FROM fin.ledger_entry WHERE txn_id = NEW.id)
    UNION ALL
    (SELECT wallet_id, direction::text, amount FROM fin.ledger_entry WHERE txn_id = NEW.id
     EXCEPT ALL SELECT wallet_id, CASE direction WHEN 'DR' THEN 'CR' ELSE 'DR' END, amount FROM fin.ledger_entry WHERE txn_id = orig.id)) d;
  IF diff > 0 THEN
    RAISE EXCEPTION 'REVERSAL_NOT_MIRROR: txn % does not mirror txn %', NEW.id, orig.id USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS ledger_reversal_mirrors ON fin.ledger_txn;
CREATE CONSTRAINT TRIGGER ledger_reversal_mirrors AFTER INSERT ON fin.ledger_txn
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fin.tg_reversal_mirrors();

-- 3) A closed batch matches its control total
CREATE OR REPLACE FUNCTION fin.tg_posting_batch_close() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE total bigint; n int;
BEGIN
  IF NEW.closed_at IS NULL OR OLD.closed_at IS NOT NULL THEN RETURN NEW; END IF;
  SELECT coalesce(sum(e.amount) FILTER (WHERE e.direction = 'DR'), 0), count(DISTINCT t.id) INTO total, n
    FROM fin.ledger_txn t JOIN fin.ledger_entry e ON e.txn_id = t.id WHERE t.posting_batch_id = NEW.id;
  IF total <> NEW.control_total OR n <> NEW.entry_count THEN
    RAISE EXCEPTION 'BATCH_CONTROL_TOTAL: batch % has % in % transactions, expected % in %', NEW.id, total, n, NEW.control_total, NEW.entry_count
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS posting_batch_close ON fin.posting_batch;
CREATE TRIGGER posting_batch_close BEFORE UPDATE OF closed_at ON fin.posting_batch FOR EACH ROW EXECUTE FUNCTION fin.tg_posting_batch_close();

-- 4) A wallet balance changes only through a ledger entry, never by a direct UPDATE
CREATE OR REPLACE FUNCTION fin.tg_ledger_entry_apply() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE w fin.wallet%ROWTYPE; t_currency char(3); delta bigint;
BEGIN
  SELECT * INTO w FROM fin.wallet WHERE id = NEW.wallet_id FOR UPDATE;
  SELECT currency INTO t_currency FROM fin.ledger_txn WHERE id = NEW.txn_id;
  IF w.currency <> t_currency THEN
    RAISE EXCEPTION 'CURRENCY_MISMATCH: wallet % vs txn %', w.currency, t_currency USING ERRCODE = 'P0001';
  END IF;
  IF w.status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'WALLET_NOT_ACTIVE' USING ERRCODE = 'P0001';
  END IF;
  delta := CASE WHEN NEW.direction = 'CR' THEN NEW.amount ELSE -NEW.amount END;
  PERFORM set_config('fin.posting_entry', NEW.txn_id::text, true);
  UPDATE fin.wallet SET balance = balance + delta WHERE id = NEW.wallet_id
    RETURNING balance INTO NEW.balance_after;            -- a CHECK constraint on the wallet rejects negative balances
  PERFORM set_config('fin.posting_entry', '', true);
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION fin.tg_wallet_balance_guard() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.balance IS DISTINCT FROM OLD.balance AND coalesce(current_setting('fin.posting_entry', true), '') = '' THEN
    RAISE EXCEPTION 'BALANCE_WRITE_FORBIDDEN: a wallet balance moves only through fin.ledger_entry' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS wallet_balance_guard ON fin.wallet;
CREATE TRIGGER wallet_balance_guard BEFORE UPDATE OF balance ON fin.wallet FOR EACH ROW EXECUTE FUNCTION fin.tg_wallet_balance_guard();
-- A new wallet starts at zero; money arrives as ledger entries
CREATE OR REPLACE FUNCTION fin.tg_wallet_opens_empty() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.balance <> 0 THEN
    RAISE EXCEPTION 'WALLET_OPENING_BALANCE: a wallet opens at zero and is funded by ledger entries' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS wallet_opens_empty ON fin.wallet;
CREATE TRIGGER wallet_opens_empty BEFORE INSERT ON fin.wallet FOR EACH ROW EXECUTE FUNCTION fin.tg_wallet_opens_empty();

-- 5) Daily reconciliation: every balance equals the sum of its entries
CREATE TABLE IF NOT EXISTS fin.wallet_reconciliation (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_at      timestamptz NOT NULL DEFAULT now(),
  wallets     int NOT NULL,
  mismatches  int NOT NULL,
  detail      jsonb NOT NULL DEFAULT '[]'
);
COMMENT ON TABLE fin.wallet_reconciliation IS 'Result of each balance-versus-entries reconciliation (review 3.5); a mismatch raises an alert';
CREATE OR REPLACE FUNCTION fin.reconcile_wallets() RETURNS fin.wallet_reconciliation
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r fin.wallet_reconciliation;
BEGIN
  WITH sums AS (
    SELECT w.id, w.balance, coalesce(sum(CASE e.direction WHEN 'CR' THEN e.amount ELSE -e.amount END), 0) AS ledger
      FROM fin.wallet w LEFT JOIN fin.ledger_entry e ON e.wallet_id = w.id GROUP BY w.id, w.balance),
  bad AS (SELECT id, balance, ledger FROM sums WHERE balance <> ledger)
  INSERT INTO fin.wallet_reconciliation (wallets, mismatches, detail)
  SELECT (SELECT count(*) FROM sums), (SELECT count(*) FROM bad),
         coalesce((SELECT jsonb_agg(jsonb_build_object('wallet_id', id, 'balance', balance, 'ledger', ledger)) FROM bad), '[]')
  RETURNING * INTO r;
  IF r.mismatches > 0 THEN
    INSERT INTO sys.outbox_event (aggregate_type, aggregate_id, event_type, payload)
    VALUES ('WALLET_RECONCILIATION', r.id, 'ledger.imbalance', jsonb_build_object('mismatches', r.mismatches));
  END IF;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION fin.reconcile_wallets() FROM PUBLIC;
SELECT sys.rls_platform('fin.posting_batch');
SELECT sys.rls_platform('fin.wallet_reconciliation');
GRANT SELECT, INSERT, UPDATE ON fin.posting_batch TO masslak_app;
GRANT SELECT ON fin.wallet_reconciliation TO masslak_app, masslak_readonly;

-- =====================================================================
-- H  Seat inventory (3.8). PostgreSQL is the only source of truth (no cache holds seats). One row per seat and
--   segment, with its primary key, already makes a double sale impossible. Added here:
-- =====================================================================
ALTER TABLE ops.seat_segment ADD COLUMN IF NOT EXISTS version int NOT NULL DEFAULT 0;
COMMENT ON COLUMN ops.seat_segment.version IS 'Increments on every change, for optimistic checks by callers';
CREATE OR REPLACE FUNCTION ops.tg_seat_segment_guard() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k record;
BEGIN
  NEW.version := OLD.version + 1;
  IF NEW.status = 'SOLD' AND (OLD.status <> 'SOLD' OR NEW.ticket_id IS DISTINCT FROM OLD.ticket_id) THEN
    IF OLD.status = 'SOLD' AND OLD.ticket_id IS NOT NULL AND NEW.ticket_id IS DISTINCT FROM OLD.ticket_id THEN
      RAISE EXCEPTION 'SEAT_ALREADY_SOLD: seat % segment % of trip % is sold', NEW.seat_no, NEW.seg, NEW.trip_id USING ERRCODE = 'P0001';
    END IF;
    SELECT trip_id, seat_no, from_seq, to_seq, status INTO k FROM sales.ticket WHERE id = NEW.ticket_id;
    IF k.trip_id IS DISTINCT FROM NEW.trip_id OR k.seat_no IS DISTINCT FROM NEW.seat_no
       OR NEW.seg < k.from_seq OR NEW.seg >= k.to_seq THEN
      RAISE EXCEPTION 'SEAT_TICKET_MISMATCH: the ticket does not cover seat % segment % of trip %', NEW.seat_no, NEW.seg, NEW.trip_id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS seat_segment_guard ON ops.seat_segment;
CREATE TRIGGER seat_segment_guard BEFORE UPDATE ON ops.seat_segment FOR EACH ROW EXECUTE FUNCTION ops.tg_seat_segment_guard();

-- Holds end by time even if nobody comes back: free reads already treat an expired hold as free, and this
-- function clears them for good (called by sys.run_maintenance)
CREATE OR REPLACE FUNCTION ops.release_expired_holds() RETURNS int
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH r AS (UPDATE ops.seat_segment SET status = 'AVAILABLE', lock_token = NULL, lock_user_id = NULL, lock_expires_at = NULL
              WHERE status = 'LOCKED' AND lock_expires_at <= now() RETURNING 1)
  SELECT count(*)::int FROM r
$$;
REVOKE ALL ON FUNCTION ops.release_expired_holds() FROM PUBLIC;

-- =====================================================================
-- I  Business rules as constraints (3.14)
-- =====================================================================
-- 1) Beneficial owners of a company never add up to more than 100%
CREATE OR REPLACE FUNCTION iam.tg_beneficial_total() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE total numeric;
BEGIN
  SELECT sum(ownership_pct) INTO total FROM iam.beneficial_owner WHERE company_id = NEW.company_id;
  IF total > 100 THEN
    RAISE EXCEPTION 'OWNERSHIP_OVER_100: beneficial owners of company % add up to %%%', NEW.company_id, total USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS beneficial_total ON iam.beneficial_owner;
CREATE CONSTRAINT TRIGGER beneficial_total AFTER INSERT OR UPDATE ON iam.beneficial_owner
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION iam.tg_beneficial_total();

-- 2) An infant on a lap travels with an adult of the same booking, within the carrier's limit per adult
CREATE OR REPLACE FUNCTION sales.tg_lap_infant() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE carrier record; per int; n int;
BEGIN
  IF NEW.accompanied_by_passenger_id IS NULL THEN RETURN NULL; END IF;
  SELECT p.booking_id, p.passenger_category, p.accompanied_by_passenger_id AS rides_on_lap, b.company_id
    INTO carrier FROM sales.passenger p JOIN sales.booking b ON b.id = p.booking_id WHERE p.id = NEW.accompanied_by_passenger_id;
  IF carrier.booking_id IS DISTINCT FROM NEW.booking_id THEN
    RAISE EXCEPTION 'LAP_ADULT_INVALID: the carrying adult is not on this booking' USING ERRCODE = 'P0001';
  END IF;
  IF carrier.passenger_category IN ('INFANT','CHILD') OR carrier.rides_on_lap IS NOT NULL THEN
    RAISE EXCEPTION 'LAP_ADULT_INVALID: an infant is carried by an adult, not by a child or another infant' USING ERRCODE = 'P0001';
  END IF;
  SELECT coalesce((SELECT max_per_adult FROM pricing.passenger_age_band
                    WHERE category = 'INFANT' AND status = 'ACTIVE' AND company_id IS NOT DISTINCT FROM carrier.company_id LIMIT 1),
                  (SELECT max_per_adult FROM pricing.passenger_age_band
                    WHERE category = 'INFANT' AND status = 'ACTIVE' AND company_id IS NULL LIMIT 1), 1) INTO per;
  SELECT count(*) INTO n FROM sales.passenger WHERE accompanied_by_passenger_id = NEW.accompanied_by_passenger_id;
  IF n > per THEN
    RAISE EXCEPTION 'TOO_MANY_LAP_INFANTS: one adult carries at most % infant(s)', per USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS lap_infant ON sales.passenger;
CREATE CONSTRAINT TRIGGER lap_infant AFTER INSERT OR UPDATE OF accompanied_by_passenger_id ON sales.passenger
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION sales.tg_lap_infant();

-- 3) An infant is an infant by date of birth; a band may also require an identity document
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'passenger_infant_birth_date') THEN
    ALTER TABLE sales.passenger ADD CONSTRAINT passenger_infant_birth_date
      CHECK (passenger_category IS DISTINCT FROM 'INFANT' OR birth_date IS NOT NULL) NOT VALID;
  END IF;
END $$;
ALTER TABLE pricing.passenger_age_band ADD COLUMN IF NOT EXISTS document_required boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN pricing.passenger_age_band.document_required IS 'Travellers of this band need an identity document type on the ticket';
CREATE OR REPLACE FUNCTION sales.tg_band_document() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.passenger_category IS NOT NULL AND NEW.id_type IS NULL AND EXISTS (
       SELECT 1 FROM pricing.passenger_age_band a JOIN sales.booking b ON b.id = NEW.booking_id
        WHERE a.category = NEW.passenger_category AND a.status = 'ACTIVE' AND a.document_required
          AND (a.company_id = b.company_id OR a.company_id IS NULL)) THEN
    RAISE EXCEPTION 'DOCUMENT_REQUIRED: % travellers need an identity document', NEW.passenger_category USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS band_document ON sales.passenger;
CREATE TRIGGER band_document BEFORE INSERT OR UPDATE OF passenger_category, id_type ON sales.passenger
  FOR EACH ROW EXECUTE FUNCTION sales.tg_band_document();

-- 4) Stops: a pair fare points to stops that exist, in travel order (tickets already did); the first and last stops
--    are stations
--    and scheduled times never go backwards
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'trip_pair_fare_from_stop_fk') THEN
    ALTER TABLE ops.trip_pair_fare ADD CONSTRAINT trip_pair_fare_from_stop_fk FOREIGN KEY (trip_id, from_seq)
      REFERENCES ops.trip_stop (trip_id, seq) ON DELETE CASCADE NOT VALID;
    ALTER TABLE ops.trip_pair_fare ADD CONSTRAINT trip_pair_fare_to_stop_fk FOREIGN KEY (trip_id, to_seq)
      REFERENCES ops.trip_stop (trip_id, seq) ON DELETE CASCADE NOT VALID;
  END IF;
  -- tickets already point to existing stops in order (060_sales.sql); an earlier draft of this file repeated it
  ALTER TABLE sales.ticket DROP CONSTRAINT IF EXISTS ticket_from_stop_fk;
  ALTER TABLE sales.ticket DROP CONSTRAINT IF EXISTS ticket_to_stop_fk;
  ALTER TABLE sales.ticket DROP CONSTRAINT IF EXISTS ticket_segment_order;
END $$;
DROP INDEX IF EXISTS sales.ticket_trip_from_idx;
DROP INDEX IF EXISTS sales.ticket_trip_to_idx;
CREATE INDEX IF NOT EXISTS trip_pair_fare_to_stop_idx ON ops.trip_pair_fare (trip_id, to_seq);
CREATE OR REPLACE FUNCTION ops.tg_trip_stops_order() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE tid bigint := coalesce(NEW.trip_id, OLD.trip_id); bad text;
BEGIN
  SELECT CASE
    WHEN first_kind <> 'STATION' THEN 'the first stop is not a station'
    WHEN last_kind <> 'STATION' THEN 'the last stop is not a station'
    WHEN backwards > 0 THEN 'scheduled times go backwards'
  END INTO bad FROM (
    SELECT (array_agg(kind ORDER BY seq))[1] AS first_kind, (array_agg(kind ORDER BY seq DESC))[1] AS last_kind,
           count(*) FILTER (WHERE coalesce(sched_arr, sched_dep) < prev_dep) AS backwards
      FROM (SELECT seq, kind, sched_arr, sched_dep, lag(coalesce(sched_dep, sched_arr)) OVER (ORDER BY seq) AS prev_dep
              FROM ops.trip_stop WHERE trip_id = tid) s
    HAVING count(*) > 0) x;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'TRIP_STOPS_INVALID: trip %: %', tid, bad USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trip_stops_order ON ops.trip_stop;
CREATE CONSTRAINT TRIGGER trip_stops_order AFTER INSERT OR UPDATE OF seq, kind, sched_arr, sched_dep ON ops.trip_stop
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_stops_order();

-- 5) Publishing a trip: the vehicle has the seats and standing room it sells, its licences are valid on the day,
--    and a trip on an approved line has an active permit for that day
CREATE OR REPLACE FUNCTION ops.tg_trip_publish_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v record; day date; lic record; line bigint;
BEGIN
  IF NEW.status NOT IN ('PUBLISHED','BOARDING') OR NEW.vehicle_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND NEW.status = OLD.status AND NEW.vehicle_id IS NOT DISTINCT FROM OLD.vehicle_id
     AND NEW.departure_at = OLD.departure_at AND NEW.seats_total = OLD.seats_total
     AND NEW.standing_capacity IS NOT DISTINCT FROM OLD.standing_capacity THEN
    RETURN NEW;
  END IF;
  day := (NEW.departure_at AT TIME ZONE 'UTC')::date;
  SELECT passenger_seats, standing_capacity INTO v FROM fleet.vehicle WHERE id = NEW.vehicle_id;
  IF NEW.seats_total > coalesce(v.passenger_seats, 0) THEN
    RAISE EXCEPTION 'CAPACITY_EXCEEDS_VEHICLE: % seats sold on a vehicle with %', NEW.seats_total, v.passenger_seats USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(NEW.standing_capacity, 0) > coalesce(v.standing_capacity, 0) THEN
    RAISE EXCEPTION 'CAPACITY_EXCEEDS_VEHICLE: % standing places on a vehicle with %', NEW.standing_capacity, v.standing_capacity
      USING ERRCODE = 'P0001';
  END IF;
  -- the latest record of each licence type must still be valid on the day of departure
  SELECT l.license_type, l.expiry_date, l.status INTO lic FROM (
    SELECT DISTINCT ON (license_type) license_type, expiry_date, status FROM fleet.license_record
     WHERE subject_type = 'VEHICLE' AND subject_id = NEW.vehicle_id AND status <> 'PENDING_REVIEW'
     ORDER BY license_type, expiry_date DESC) l
   WHERE l.expiry_date < day OR l.status IN ('EXPIRED','SUSPENDED') LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'LICENSE_EXPIRED: the vehicle''s % licence is % on %', lic.license_type, lower(lic.status), day USING ERRCODE = 'P0001';
  END IF;
  IF NEW.line_version_id IS NOT NULL THEN
    SELECT line_id INTO line FROM net.line_version WHERE id = NEW.line_version_id;
    IF NOT EXISTS (SELECT 1 FROM net.line_permit p WHERE p.line_id = line AND p.company_id = NEW.company_id
                     AND p.status = 'ACTIVE' AND p.valid @> day) THEN
      RAISE EXCEPTION 'LINE_PERMIT_REQUIRED: no active permit on this line for %', day USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trip_publish_rules ON ops.trip;
CREATE TRIGGER trip_publish_rules BEFORE INSERT OR UPDATE ON ops.trip FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_publish_rules();

-- 6) A line permit is only activated inside its validity
CREATE OR REPLACE FUNCTION net.tg_line_permit_active() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.status = 'ACTIVE' AND (TG_OP = 'INSERT' OR OLD.status <> 'ACTIVE') AND NOT NEW.valid @> current_date THEN
    RAISE EXCEPTION 'PERMIT_OUTSIDE_VALIDITY: permit % is valid %, today is %', NEW.permit_no, NEW.valid, current_date USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS line_permit_active ON net.line_permit;
CREATE TRIGGER line_permit_active BEFORE INSERT OR UPDATE OF status, valid ON net.line_permit FOR EACH ROW EXECUTE FUNCTION net.tg_line_permit_active();

-- 7) A new manifest version supersedes the previous version of the same trip and crossing, and nothing else
CREATE OR REPLACE FUNCTION brd.tg_manifest_chain() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE prev record;
BEGIN
  IF NEW.version = 1 THEN
    IF NEW.supersedes_id IS NOT NULL THEN
      RAISE EXCEPTION 'MANIFEST_CHAIN: version 1 supersedes nothing' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  SELECT trip_id, border_point_id, version INTO prev FROM brd.manifest WHERE id = NEW.supersedes_id;
  IF NOT FOUND OR prev.trip_id <> NEW.trip_id OR prev.border_point_id IS DISTINCT FROM NEW.border_point_id
     OR prev.version <> NEW.version - 1 THEN
    RAISE EXCEPTION 'MANIFEST_CHAIN: version % must supersede version % of the same trip and crossing', NEW.version, NEW.version - 1
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS manifest_chain ON brd.manifest;
CREATE TRIGGER manifest_chain BEFORE INSERT OR UPDATE OF version, supersedes_id ON brd.manifest FOR EACH ROW EXECUTE FUNCTION brd.tg_manifest_chain();
CREATE UNIQUE INDEX IF NOT EXISTS manifest_superseded_once ON brd.manifest (supersedes_id) WHERE supersedes_id IS NOT NULL;

-- 8) A manifest goes only to the authority of an approved, live route that covers it
CREATE OR REPLACE FUNCTION brd.tg_delivery_scope() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record; m record; tc bigint;
BEGIN
  SELECT * INTO r FROM brd.manifest_route WHERE id = NEW.route_id;
  SELECT mf.scope, mf.content_type, mf.manifest_type, mf.border_point_id, t.company_id INTO m
    FROM brd.manifest mf JOIN ops.trip t ON t.id = mf.trip_id WHERE mf.id = NEW.manifest_id;
  IF r.authority_id IS DISTINCT FROM NEW.authority_id THEN
    RAISE EXCEPTION 'AUTHORITY_SCOPE: the delivery authority is not the route''s authority' USING ERRCODE = 'P0001';
  END IF;
  IF r.status IS DISTINCT FROM 'ACTIVE' OR r.approved_by IS NULL THEN
    RAISE EXCEPTION 'AUTHORITY_SCOPE: the route is not approved and live' USING ERRCODE = 'P0001';
  END IF;
  -- the same matching as the issuing service (manifests/service.py); country and city filters stay with the service
  IF r.scope NOT IN (m.scope, 'ALL') OR (r.company_id IS NOT NULL AND r.company_id <> m.company_id)
     OR (r.border_point_id IS NOT NULL AND r.border_point_id IS DISTINCT FROM m.border_point_id)
     OR r.content_type NOT IN (m.content_type, 'ALL')
     OR NOT m.manifest_type = ANY (r.manifest_types) THEN
    RAISE EXCEPTION 'AUTHORITY_SCOPE: the route does not cover this manifest' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS delivery_scope ON brd.manifest_delivery;
CREATE TRIGGER delivery_scope BEFORE INSERT OR UPDATE OF route_id, authority_id, manifest_id ON brd.manifest_delivery
  FOR EACH ROW EXECUTE FUNCTION brd.tg_delivery_scope();
-- An authority data request is delivered only after a second officer approved it
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'authority_request_approved_before_delivery') THEN
    ALTER TABLE sec.authority_data_request ADD CONSTRAINT authority_request_approved_before_delivery
      CHECK (status NOT IN ('APPROVED','DELIVERED') OR approved_by IS NOT NULL) NOT VALID;
  END IF;
END $$;

-- =====================================================================
-- J  Retention, legal hold and erasure (3.15)
--   Erasure pseudonymises a person: their identity disappears, the financial, tax, manifest and audit rows stay and
--   keep their keys. Nothing is erased while a legal hold covers the person.
-- =====================================================================
CREATE TABLE IF NOT EXISTS gov.retention_policy (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code           text NOT NULL UNIQUE,
  dataset        text NOT NULL,                       -- schema.table or a logical dataset
  retention_days int NOT NULL CHECK (retention_days > 0),
  action         text NOT NULL CHECK (action IN ('DELETE','ANONYMIZE','ARCHIVE')),
  legal_basis    text NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE gov.retention_policy IS 'How long each kind of record is kept and what happens after (review 3.15)';
INSERT INTO gov.retention_policy (code, dataset, retention_days, action, legal_basis) VALUES
  ('PARTY_IDENTITY', 'iam.party', 2555, 'ANONYMIZE', 'Account data: 7 years after closure for tax and dispute evidence'),
  ('PASSENGER_RECORD', 'sales.passenger', 1825, 'ANONYMIZE', 'Passenger lists: 5 years for authority requests and refunds'),
  ('DOCUMENT_FILE', 'iam.document', 1825, 'ANONYMIZE', 'Licences and identity documents: 5 years after expiry'),
  ('GEO_TRACKING', 'ops.geo_event', 90, 'DELETE', 'Live positions: short operational window (study 16.18)'),
  ('AUDIT_LOG', 'audit.*', 2555, 'ARCHIVE', 'Audit evidence: archived to immutable storage, never edited')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS gov.legal_hold (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid         uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  scope_type  text NOT NULL CHECK (scope_type IN ('PARTY','COMPANY','TRIP','BOOKING','DATASET')),
  scope_id    bigint,
  dataset     text,
  reason      text NOT NULL,
  case_ref    text NOT NULL,                          -- court or authority reference
  placed_by   bigint NOT NULL REFERENCES iam.app_user(id),
  placed_at   timestamptz NOT NULL DEFAULT now(),
  released_by bigint REFERENCES iam.app_user(id),
  released_at timestamptz,
  CHECK ((scope_type = 'DATASET') = (dataset IS NOT NULL AND scope_id IS NULL)),
  CHECK (released_by IS NULL OR released_by <> placed_by)
);
COMMENT ON TABLE gov.legal_hold IS 'Records that must not be deleted or anonymised while a case is open; release needs a second officer';
COMMENT ON COLUMN gov.legal_hold.scope_id IS 'Polymorphic: id of the party, company, trip or booking named by scope_type';
CREATE INDEX IF NOT EXISTS legal_hold_scope_idx ON gov.legal_hold (scope_type, scope_id) WHERE released_at IS NULL;
CREATE INDEX IF NOT EXISTS legal_hold_placed_by_idx ON gov.legal_hold (placed_by);
CREATE INDEX IF NOT EXISTS legal_hold_released_by_idx ON gov.legal_hold (released_by);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['iam.party','sales.passenger','iam.document','iam.family_member'] LOOP
    CONTINUE WHEN to_regclass(t) IS NULL;
    EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS retention_policy_id bigint REFERENCES gov.retention_policy(id)', t);
    EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS legal_hold boolean NOT NULL DEFAULT false', t);
    EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS anonymized_at timestamptz', t);
    EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS erasure_request_id bigint REFERENCES gov.subject_request(id)', t);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %s (retention_policy_id)', (parse_ident(t))[2] || '_retention_policy_idx', t);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %s (erasure_request_id)', (parse_ident(t))[2] || '_erasure_request_idx', t);
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS gov.erasure_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  party_id    bigint NOT NULL REFERENCES iam.party(id),
  request_id  bigint REFERENCES gov.subject_request(id),
  outcome     text NOT NULL CHECK (outcome IN ('DONE','PARTIAL','REFUSED')),
  detail      jsonb NOT NULL,
  done_by     bigint REFERENCES iam.app_user(id),
  done_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS erasure_log_party_idx ON gov.erasure_log (party_id);
CREATE INDEX IF NOT EXISTS erasure_log_request_idx ON gov.erasure_log (request_id);
CREATE INDEX IF NOT EXISTS erasure_log_done_by_idx ON gov.erasure_log (done_by);
COMMENT ON TABLE gov.erasure_log IS 'Each erasure: what was pseudonymised, what was kept and why';

-- Runs with the owner's rights: consents and passenger lists are append-only for the application, and erasure is the
-- one sanctioned change to them. The function itself refuses anyone but the platform.
CREATE OR REPLACE FUNCTION gov.erase_party(p_party_id bigint, p_request_id bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE kept int; done int; uid8 text; v_result jsonb;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: erasure is a platform task' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM iam.party WHERE id = p_party_id AND legal_hold)
     OR EXISTS (SELECT 1 FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'PARTY' AND scope_id = p_party_id) THEN
    INSERT INTO gov.erasure_log (party_id, request_id, outcome, detail, done_by)
    VALUES (p_party_id, p_request_id, 'REFUSED', '{"reason":"LEGAL_HOLD"}', sys.ctx_user_id());
    RAISE EXCEPTION 'LEGAL_HOLD: party % is under a legal hold', p_party_id USING ERRCODE = 'P0001';
  END IF;
  SELECT left(uid::text, 8) INTO uid8 FROM iam.party WHERE id = p_party_id;
  UPDATE iam.party SET legal_name = 'Erased person ' || uid8, name_latin = NULL, id_no_enc = NULL, id_no_bidx = NULL,
         id_no_last4 = NULL, enc_key_id = NULL, birth_date = NULL, gender = NULL, mobile = NULL, email = NULL, address = NULL,
         external_ref = NULL, status = 'CLOSED', anonymized_at = now(), erasure_request_id = p_request_id
   WHERE id = p_party_id;
  UPDATE iam.app_user SET email = 'erased-' || id || '@erased.invalid', mobile = NULL, password_hash = NULL, status = 'CLOSED'
   WHERE party_id = p_party_id;
  UPDATE gov.consent SET withdrawn_at = now() WHERE party_id = p_party_id AND withdrawn_at IS NULL;
  -- passenger rows: anonymised once their trip is past the passenger-record retention; younger ones are kept by law
  WITH pol AS (SELECT retention_days FROM gov.retention_policy WHERE code = 'PASSENGER_RECORD'),
  old AS (UPDATE sales.passenger p SET full_name = 'Erased person ' || uid8, first_name = 'Erased', father_name = NULL,
                 grandfather_name = NULL, last_name = uid8, id_no_enc = NULL, id_no_bidx = NULL, id_no_last4 = NULL,
                 passport_no_enc = NULL, passport_no_bidx = NULL, enc_key_id = NULL, mobile = NULL,
                 anonymized_at = now(), erasure_request_id = p_request_id
            FROM pol WHERE p.party_id = p_party_id AND NOT p.legal_hold
             AND EXISTS (SELECT 1 FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id
                          WHERE b.id = p.booking_id AND t.departure_at < now() - make_interval(days => pol.retention_days))
          RETURNING 1)
  SELECT count(*) INTO done FROM old;
  SELECT count(*) INTO kept FROM sales.passenger WHERE party_id = p_party_id AND anonymized_at IS NULL;
  v_result := jsonb_build_object('party', 'PSEUDONYMISED', 'passenger_rows_anonymised', done, 'passenger_rows_kept', kept,
                               'kept_reason', CASE WHEN kept > 0 THEN 'within the legal retention of passenger lists' END,
                               'financial_rows', 'KEPT', 'audit', 'KEPT_REDACTED');
  INSERT INTO gov.erasure_log (party_id, request_id, outcome, detail, done_by)
  VALUES (p_party_id, p_request_id, CASE WHEN kept > 0 THEN 'PARTIAL' ELSE 'DONE' END, v_result, sys.ctx_user_id());
  IF p_request_id IS NOT NULL THEN
    UPDATE gov.subject_request SET status = 'DONE', handled_by = sys.ctx_user_id(), handled_at = now(), result = v_result::text
     WHERE id = p_request_id;
  END IF;
  RETURN v_result;
END $$;
COMMENT ON FUNCTION gov.erase_party IS 'Right to erasure by pseudonymisation; refuses under a legal hold (review 3.15)';
REVOKE ALL ON FUNCTION gov.erase_party(bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gov.erase_party(bigint, bigint) TO masslak_app;
SELECT sys.rls_catalog('gov.retention_policy');
SELECT sys.rls_platform('gov.legal_hold');
SELECT sys.rls_platform('gov.erasure_log');
GRANT SELECT, INSERT, UPDATE ON gov.legal_hold TO masslak_app;
GRANT SELECT ON gov.retention_policy TO masslak_app, masslak_readonly;
GRANT SELECT, INSERT ON gov.erasure_log TO masslak_app;
GRANT SELECT ON gov.legal_hold, gov.erasure_log TO masslak_auditor;

-- =====================================================================
-- K  Tracking: partitions created ahead, old ones dropped by retention unless held, expired holds released (3.7)
-- =====================================================================
CREATE INDEX IF NOT EXISTS geo_event_vehicle_idx ON ops.geo_event (vehicle_id, ts);
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, location, processors) VALUES
  ('ops.geo_event', 'CONFIDENTIAL', 'Operations', 'Live vehicle positions for passengers and safety', 'Contract and safety', 90, 'Primary region', '{}'),
  ('audit.activity_log', 'CONFIDENTIAL', 'Security', 'Evidence of user actions', 'Legal obligation', 2555, 'Primary region, sealed', '{}'),
  ('sales.passenger', 'RESTRICTED', 'Sales', 'Passenger lists and manifests', 'Contract and legal obligation', 1825, 'Primary region', '{}'),
  ('iam.party', 'RESTRICTED', 'Identity', 'Account holders and their identity', 'Contract', 2555, 'Primary region', '{}')
ON CONFLICT (dataset) DO NOTHING;

CREATE OR REPLACE FUNCTION sys.run_maintenance() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p text; done jsonb := '{}'::jsonb; keep_days int; dropped int := 0; held boolean; r fin.wallet_reconciliation;
BEGIN
  FOR p IN SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'p' AND NOT c.relispartition LOOP
    PERFORM sys.ensure_monthly_partitions(p, 3, 1);
  END LOOP;
  SELECT retention_days INTO keep_days FROM gov.data_inventory WHERE dataset = 'ops.geo_event';
  held := EXISTS (SELECT 1 FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'DATASET' AND dataset = 'ops.geo_event');
  IF keep_days IS NOT NULL AND NOT held THEN
    dropped := sys.drop_partitions_older_than('ops.geo_event', greatest(1, ceil(keep_days / 30.0)::int));
  END IF;
  r := fin.reconcile_wallets();
  done := jsonb_build_object('partitions_checked', true, 'geo_partitions_dropped', dropped, 'geo_retention_held', held,
                             'expired_holds_released', ops.release_expired_holds(),
                             'wallet_mismatches', r.mismatches, 'at', now());
  RETURN done;
END $$;
COMMENT ON FUNCTION sys.run_maintenance IS 'Daily job: partitions ahead, tracking retention (skipped under a legal hold), expired seat holds, wallet reconciliation';
REVOKE ALL ON FUNCTION sys.run_maintenance() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.run_maintenance() TO masslak_app;

-- =====================================================================
-- L  Scopes, purposes and authorisation decisions (3.11)
-- =====================================================================
CREATE TABLE IF NOT EXISTS gov.data_purpose (
  code                    text PRIMARY KEY,
  description             text NOT NULL,
  requires_reason         boolean NOT NULL DEFAULT true,
  requires_second_approval boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE gov.data_purpose IS 'Why restricted data is read; some purposes need a written reason or a second officer';
INSERT INTO gov.data_purpose (code, description, requires_reason, requires_second_approval) VALUES
  ('SUPPORT_CASE', 'Customer care on an open case', true, false),
  ('AUTHORITY_MANIFEST', 'Manifest content for a routed authority', true, false),
  ('AUTHORITY_REQUEST', 'An official data request', true, true),
  ('FRAUD_REVIEW', 'Fraud or risk investigation', true, false),
  ('OPERATIONS', 'Running today''s trips', false, false),
  ('PAYOUT_EXECUTION', 'Paying a company to its verified bank account', false, true)
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS iam.role_scope (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  role_id     bigint NOT NULL REFERENCES iam.role(id) ON DELETE CASCADE,
  scope_type  text NOT NULL CHECK (scope_type IN ('STATION','ROUTE','LINE','CITY','COUNTRY','TRIP_TYPE')),
  scope_value text NOT NULL,
  UNIQUE (role_id, scope_type, scope_value)
);
COMMENT ON TABLE iam.role_scope IS 'Limits a role to some stations, routes, lines, cities, countries or trip types';
CREATE TABLE IF NOT EXISTS iam.user_station_scope (
  user_id    bigint NOT NULL REFERENCES iam.app_user(id) ON DELETE CASCADE,
  station_id bigint NOT NULL REFERENCES net.station(id),
  company_id bigint NOT NULL REFERENCES iam.company(id),
  valid      daterange NOT NULL DEFAULT daterange(current_date, NULL),
  PRIMARY KEY (user_id, station_id)
);
CREATE INDEX IF NOT EXISTS user_station_scope_station_idx ON iam.user_station_scope (station_id);
CREATE INDEX IF NOT EXISTS user_station_scope_company_idx ON iam.user_station_scope (company_id);
COMMENT ON TABLE iam.user_station_scope IS 'Station staff act only at their stations';
CREATE TABLE IF NOT EXISTS sec.authority_scope (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  authority_id  bigint NOT NULL REFERENCES sec.authority_profile(id),
  data_category text NOT NULL CHECK (data_category IN ('MANIFEST_PERSON','MANIFEST_VEHICLE','MANIFEST_CARGO','BOOKING','TRACKING','IDENTITY','PAYMENT')),
  scope_type    text NOT NULL CHECK (scope_type IN ('ALL','COUNTRY','BORDER_POINT','CITY','COMPANY')),
  scope_value   text,
  legal_basis   text NOT NULL,
  valid         daterange NOT NULL,
  created_by    bigint NOT NULL REFERENCES iam.app_user(id),
  approved_by   bigint REFERENCES iam.app_user(id),
  CHECK ((scope_type = 'ALL') = (scope_value IS NULL)),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);
CREATE INDEX IF NOT EXISTS authority_scope_authority_idx ON sec.authority_scope (authority_id);
CREATE INDEX IF NOT EXISTS authority_scope_created_by_idx ON sec.authority_scope (created_by);
CREATE INDEX IF NOT EXISTS authority_scope_approved_by_idx ON sec.authority_scope (approved_by);
COMMENT ON TABLE sec.authority_scope IS 'What each authority may receive, where, on which legal basis, approved by a second officer';

CREATE TABLE IF NOT EXISTS sec.policy_decision (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  decided_at     timestamptz NOT NULL DEFAULT now(),
  request_id     uuid,
  user_id        bigint REFERENCES iam.app_user(id),
  company_id     bigint REFERENCES iam.company(id),
  scope          text,
  resource       text NOT NULL,
  action         text NOT NULL,
  purpose_code   text REFERENCES gov.data_purpose(code),
  reason         text,
  decision       text NOT NULL CHECK (decision IN ('ALLOW','DENY')),
  rule           text NOT NULL,
  policy_version text NOT NULL
);
COMMENT ON COLUMN sec.policy_decision.request_id IS 'External: the API request id';
CREATE INDEX IF NOT EXISTS policy_decision_user_idx ON sec.policy_decision (user_id, decided_at);
CREATE INDEX IF NOT EXISTS policy_decision_company_idx ON sec.policy_decision (company_id);
CREATE INDEX IF NOT EXISTS policy_decision_purpose_idx ON sec.policy_decision (purpose_code);
DROP TRIGGER IF EXISTS policy_decision_immutable ON sec.policy_decision;
CREATE TRIGGER policy_decision_immutable BEFORE UPDATE OR DELETE ON sec.policy_decision FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE sec.policy_decision IS 'Every decision to read restricted data, with its purpose, reason and policy version (review 3.11)';

-- The policy decision point for restricted reads. The caller passes the purpose and the reason; the decision is
-- recorded either way, and a missing reason or a missing permission returns false (backend: app/policy.py).
CREATE OR REPLACE FUNCTION sec.authorize(p_resource text, p_action text, p_purpose text, p_reason text,
                                         p_permission text DEFAULT NULL, p_policy_version text DEFAULT '1039.1')
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE pur gov.data_purpose; verdict text := 'ALLOW'; why text := 'purpose and reason given';
BEGIN
  SELECT * INTO pur FROM gov.data_purpose WHERE code = p_purpose;
  IF NOT FOUND THEN
    verdict := 'DENY'; why := 'unknown purpose';
  ELSIF pur.requires_reason AND length(btrim(coalesce(p_reason, ''))) < 5 THEN
    verdict := 'DENY'; why := 'a written reason is required';
  ELSIF p_permission IS NOT NULL AND NOT sys.ctx_is_platform() AND NOT EXISTS (
          SELECT 1 FROM iam.company_member m JOIN iam.role_permission rp ON rp.role_id = m.role_id
           WHERE m.user_id = sys.ctx_user_id() AND m.company_id = sys.ctx_company_id() AND rp.permission_code = p_permission
          UNION ALL
          SELECT 1 FROM iam.user_role ur JOIN iam.role_permission rp ON rp.role_id = ur.role_id
           WHERE ur.user_id = sys.ctx_user_id() AND rp.permission_code = p_permission) THEN
    verdict := 'DENY'; why := 'missing permission ' || p_permission;
  END IF;
  INSERT INTO sec.policy_decision (request_id, user_id, company_id, scope, resource, action, purpose_code, reason, decision, rule, policy_version)
  VALUES (sys.ctx_request_id(), sys.ctx_user_id(), sys.ctx_company_id(), sys.ctx_scope(), p_resource, p_action,
          CASE WHEN pur.code IS NOT NULL THEN p_purpose END, p_reason, verdict, why, p_policy_version);
  RETURN verdict = 'ALLOW';                -- the caller refuses; the decision row is committed in its own transaction
END $$;
REVOKE ALL ON FUNCTION sec.authorize(text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.authorize(text, text, text, text, text, text) TO masslak_app;

SELECT sys.rls_catalog('gov.data_purpose');
SELECT sys.rls_split('iam.role_scope', 'EXISTS (SELECT 1 FROM iam.role r WHERE r.id = role_scope.role_id)',
                     'EXISTS (SELECT 1 FROM iam.role r WHERE r.id = role_scope.role_id AND sys.tenant_visible(r.company_id))');
SELECT sys.rls('iam.user_station_scope', 'sys.tenant_visible(company_id) OR user_id = sys.ctx_user_id()');
SELECT sys.rls_platform('sec.authority_scope');
SELECT sys.rls_platform('sec.policy_decision');
GRANT SELECT ON gov.data_purpose TO masslak_app, masslak_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON iam.role_scope, iam.user_station_scope TO masslak_app;
GRANT SELECT ON iam.role_scope, iam.user_station_scope TO masslak_readonly;
GRANT SELECT, INSERT, UPDATE ON sec.authority_scope TO masslak_app;
GRANT SELECT ON sec.policy_decision TO masslak_app, masslak_auditor;

-- =====================================================================
-- M  Encryption keys (3.12). Key material never enters the database: sec.key_registry holds references to keys in
--   KMS/HSM (or injected into the process), and the API refuses to start in production without them.
-- =====================================================================
ALTER TABLE sec.key_registry ADD COLUMN IF NOT EXISTS key_version int NOT NULL DEFAULT 1;
ALTER TABLE sec.key_registry ADD COLUMN IF NOT EXISTS kms_key_id text;
ALTER TABLE sec.key_registry ADD COLUMN IF NOT EXISTS wrapped_dek bytea;
COMMENT ON COLUMN sec.key_registry.kms_key_id IS 'External: the KMS or HSM key that wraps this data key (envelope encryption)';
COMMENT ON COLUMN sec.key_registry.wrapped_dek IS 'The data key encrypted by the KMS key; plaintext keys are never stored';
CREATE UNIQUE INDEX IF NOT EXISTS key_registry_one_active ON sec.key_registry (purpose, data_class, coalesce(company_id, 0))
  WHERE status = 'ACTIVE';
CREATE OR REPLACE FUNCTION sec.tg_active_key_only() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k bigint := (to_jsonb(NEW) ->> 'enc_key_id')::bigint; st text;
BEGIN
  IF k IS NULL OR (TG_OP = 'UPDATE' AND k IS NOT DISTINCT FROM (to_jsonb(OLD) ->> 'enc_key_id')::bigint) THEN RETURN NEW; END IF;
  SELECT status INTO st FROM sec.key_registry WHERE id = k;
  IF st IS DISTINCT FROM 'ACTIVE' THEN
    RAISE EXCEPTION 'KEY_NOT_ACTIVE: new data is never encrypted under a % key', coalesce(st, 'missing') USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT n.nspname || '.' || c.relname AS t FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE a.attname = 'enc_key_id' AND NOT a.attisdropped AND c.relkind IN ('r','p') AND NOT c.relispartition
              AND n.nspname NOT IN ('pg_catalog','information_schema') LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS active_key_only ON %s', r.t);
    EXECUTE format('CREATE TRIGGER active_key_only BEFORE INSERT OR UPDATE OF enc_key_id ON %s FOR EACH ROW EXECUTE FUNCTION sec.tg_active_key_only()', r.t);
  END LOOP;
END $$;

-- =====================================================================
-- N  Dormant modules are closed at the database (3.10)
--   A restrictive policy is added to every table of a phase module: while its switch is off, nobody but the platform
--   (configuring it ahead of launch) can read or write it, whatever the application does.
-- =====================================================================
CREATE OR REPLACE FUNCTION sys.feature_on(p_keys text[]) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT bool_or(coalesce((value ->> k)::boolean, false)) FROM sys.setting, unnest(p_keys) k WHERE key = 'features'), false)
$$;
CREATE TABLE IF NOT EXISTS sys.module_gate (
  schema_name text PRIMARY KEY,
  feature_keys text[] NOT NULL,
  phase       text NOT NULL
);
COMMENT ON TABLE sys.module_gate IS 'Which feature switch opens the tables of each phase schema (review 3.10)';
INSERT INTO sys.module_gate VALUES
  ('ship', '{cargo}', 'Release 3: shipping'), ('frt', '{freight}', 'Release 3: freight'),
  ('brd', '{border_manifest,trip_manifests}', 'Release 1B: manifests; Release 3: borders'),
  ('bill', '{carrier_billing}', 'Release 1B: carrier billing'), ('ptn', '{service_partners}', 'Release 3: service partners'),
  ('rail', '{rail}', 'Release 3+: rail'), ('taxi', '{taxi}', 'Release 3+: taxi'), ('rent', '{car_rental}', 'Release 3+: car rental'),
  ('ctr', '{contract_transport}', 'Release 3+: contracted transport')
ON CONFLICT (schema_name) DO UPDATE SET feature_keys = EXCLUDED.feature_keys, phase = EXCLUDED.phase;
SELECT sys.rls_catalog('sys.module_gate');
GRANT SELECT ON sys.module_gate TO masslak_app, masslak_readonly;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT n.nspname || '.' || c.relname AS t, g.feature_keys FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN sys.module_gate g ON g.schema_name = n.nspname
            WHERE c.relkind IN ('r','p') AND NOT c.relispartition LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', r.t);
    EXECUTE format('DROP POLICY IF EXISTS module_gate ON %s', r.t);
    EXECUTE format('CREATE POLICY module_gate ON %s AS RESTRICTIVE FOR ALL USING (sys.ctx_is_platform() OR sys.feature_on(%L)) WITH CHECK (sys.ctx_is_platform() OR sys.feature_on(%L))',
                   r.t, r.feature_keys, r.feature_keys);
  END LOOP;
END $$;

-- =====================================================================
-- O  Versioned reference data (3.9)
-- =====================================================================
CREATE TABLE IF NOT EXISTS ref.seed_version (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dataset    text NOT NULL,                      -- e.g. ref.country, pricing.tax_rule, gov customs tariff
  version    text NOT NULL,
  sha256     bytea NOT NULL,
  source     text NOT NULL,                      -- schema file or official publication
  signed_by  text,                               -- who approved a legal or customs reference set
  signature  bytea,
  effective  daterange NOT NULL DEFAULT daterange(current_date, NULL),
  applied_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (dataset, version)
);
COMMENT ON TABLE ref.seed_version IS 'Version, hash and approval of each reference data set (review 3.9)';
SELECT sys.rls_catalog('ref.seed_version');
GRANT SELECT ON ref.seed_version TO masslak_app, masslak_readonly;
INSERT INTO ref.seed_version (dataset, version, sha256, source)
SELECT d, '1039', sha256(convert_to(d || ':' || (SELECT count(*) FROM ref.country)::text, 'UTF8')), '950_seed.sql / 970_passenger_names.sql'
  FROM unnest(ARRAY['ref.country','ref.currency','ref.city','iam.permission']) d
ON CONFLICT (dataset, version) DO NOTHING;

-- Every CHECK list in the schema, sorted into lifecycle states (fixed, changed by a migration) and business lists
-- (candidates for reference tables). The data dictionary documents each one.
CREATE OR REPLACE VIEW sys.v_check_inventory AS
SELECT n.nspname || '.' || c.relname AS table_name, k.conname AS constraint_name, pg_get_constraintdef(k.oid) AS definition,
       CASE WHEN pg_get_constraintdef(k.oid) ~* '\m(status|state|direction|decision|outcome|result|stage)\M' THEN 'LIFECYCLE'
            WHEN pg_get_constraintdef(k.oid) ~ 'ANY \(ARRAY' THEN 'BUSINESS_LIST'
            ELSE 'RULE' END AS kind
  FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE k.contype = 'c' AND n.nspname NOT IN ('pg_catalog','information_schema');
COMMENT ON VIEW sys.v_check_inventory IS 'Inventory of CHECK constraints by kind (review 3.9)';

-- =====================================================================
-- B (continued)  Classify every table and publish the security inventory (3.1, 3.2)
-- =====================================================================
CREATE OR REPLACE FUNCTION sys.refresh_table_class() RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  WITH t AS (
    SELECT c.oid, n.nspname || '.' || c.relname AS tn, n.nspname AS sch
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema')),
  pol AS (
    SELECT t.tn, array_agg(p.policyname::text) AS names,
           string_agg(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''), ' ' ORDER BY p.cmd = 'SELECT' DESC, p.policyname) AS quals
      FROM t LEFT JOIN pg_policies p ON p.schemaname || '.' || p.tablename = t.tn AND p.policyname <> 'module_gate' GROUP BY t.tn),
  cls AS (
    SELECT t.tn,
      CASE
        WHEN t.sch = 'audit' OR t.tn IN ('sec.policy_decision') THEN 'APPEND_ONLY_AUDIT'
        WHEN t.tn IN ('iam.auth_token','iam.mfa_factor','iam.biometric_template','iam.gov_identity_link','iam.verification',
                      'iam.device','iam.push_token','iam.user_session','iam.api_key','sec.authority_order','sec.authority_data_request',
                      'sec.authority_policy','sec.authority_scope','sec.tamper_event','sec.break_glass_log','sec.key_registry') THEN 'RESTRICTED_SECURITY'
        WHEN t.tn = 'sec.authority_profile' THEN 'PUBLIC_CATALOG'
        WHEN t.sch = 'sys' AND t.tn NOT IN ('sys.outbox_event','sys.webhook_endpoint','sys.webhook_delivery') THEN 'SYSTEM'
        WHEN 'catalog_read' = ANY (p.names) OR (t.sch = 'ref' AND p.quals ~ '^\s*true\s+sys\.ctx_is_platform\(\)') THEN 'PUBLIC_CATALOG'
        WHEN p.quals ~ '^\s*sys\.ctx_is_platform\(\)\s+sys\.ctx_is_platform\(\)\s*$' THEN 'PLATFORM_CONFIDENTIAL'
        WHEN t.tn IN ('iam.app_user','iam.party','iam.party_role','iam.user_role','pricing.points_account','pricing.points_ledger',
                      'iam.family','iam.family_member','gov.consent','gov.subject_request','crm.ai_conversation','crm.ai_message',
                      'crm.ai_tool_call') THEN 'USER_PRIVATE'
        ELSE 'TENANT_PRIVATE'
      END AS data_class,
      CASE
        WHEN EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = t.oid AND a.attname = 'company_id' AND NOT a.attisdropped) THEN 'company_id'
        WHEN p.quals ~ 'tenant_visible\(\w+\)' THEN substring(p.quals FROM 'tenant_visible\((\w+)\)')
        WHEN p.quals ~ 'FROM ([a-z_]+\.[a-z_"]+) ' THEN 'parent ' || substring(p.quals FROM 'FROM ([a-z_]+\.[a-z_"]+) ')
        WHEN p.quals ~ '(ship|frt|ptn|taxi|sales|iam)\.(can_see|is)_\w+\(\w+\)' THEN 'via ' || substring(p.quals FROM '((ship|frt|ptn|taxi|sales|iam)\.(can_see|is)_\w+\(\w+\))')
        WHEN p.quals ~ 'is_me\((\w+)\)' THEN substring(p.quals FROM 'is_me\((\w+)\)')
        WHEN p.quals ~ 'party_id = sys\.ctx_party_id\(\)' THEN 'party_id'
        WHEN p.quals ~ 'user_id = sys\.ctx_user_id\(\)' THEN 'user_id'
        WHEN p.quals ~ 'company_id = sys\.ctx_company_id\(\)' THEN substring(p.quals FROM '(\w*company_id) = sys\.ctx_company_id')
        WHEN p.quals ~ '^\s*true\s' OR p.quals ~ '\(status = ''ACTIVE''' THEN 'public read, platform writes'
      END AS tenant_path
      FROM t JOIN pol p ON p.tn = t.tn)
  INSERT INTO sys.table_class (table_name, data_class, tenant_path)
  SELECT tn, data_class, tenant_path FROM cls
  ON CONFLICT (table_name) DO UPDATE SET data_class = EXCLUDED.data_class, tenant_path = EXCLUDED.tenant_path;
  -- reference lists with their own read/write policies are catalogs too; two paths the policy text does not reveal
  UPDATE sys.table_class SET data_class = 'PUBLIC_CATALOG', tenant_path = 'public read, platform writes'
   WHERE table_name LIKE 'ref.%' AND table_name <> 'ref.file_object' AND data_class = 'TENANT_PRIVATE' AND tenant_path IS NULL;
  UPDATE sys.table_class SET tenant_path = 'party_id (partner channels); the platform''s own channels are public'
   WHERE table_name = 'sales.channel';
  UPDATE sys.table_class SET tenant_path = 'parent acct.sync_item -> acct.accounting_connection' WHERE table_name = 'acct.sync_conflict';
  UPDATE sys.table_class SET data_class = 'PLATFORM_CONFIDENTIAL', tenant_path = 'platform reads; any session may report an event'
   WHERE table_name = 'sec.security_event';
  DELETE FROM sys.table_class tc WHERE to_regclass(tc.table_name) IS NULL;
  SELECT count(*) INTO n FROM sys.table_class;
  RETURN n;
END $$;
COMMENT ON FUNCTION sys.refresh_table_class IS 'Classifies every table from its schema, policies and columns; rerun by each new schema file';
SELECT sys.refresh_table_class();

CREATE OR REPLACE VIEW sys.v_security_inventory AS
SELECT n.nspname || '.' || c.relname AS table_name, tc.data_class, tc.tenant_path,
       c.relrowsecurity AS rls, c.relforcerowsecurity AS rls_forced,
       (SELECT count(*) FROM pg_policies p WHERE p.schemaname = n.nspname AND p.tablename = c.relname) AS policies,
       pg_get_userbyid(c.relowner) AS owner,
       has_table_privilege('masslak_app', c.oid, 'SELECT') AS app_select,
       has_table_privilege('masslak_app', c.oid, 'UPDATE') AS app_update,
       has_table_privilege('masslak_app', c.oid, 'DELETE') AS app_delete,
       has_table_privilege('masslak_readonly', c.oid, 'SELECT') AS reporting_select,
       g.feature_keys AS module_switch
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN sys.table_class tc ON tc.table_name = n.nspname || '.' || c.relname
  LEFT JOIN sys.module_gate g ON g.schema_name = n.nspname
 WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema');
COMMENT ON VIEW sys.v_security_inventory IS 'One row per table: class, owner path, RLS, privileges and module switch (review 3.1)';
GRANT SELECT ON sys.v_security_inventory TO masslak_auditor;

-- New tables of this file
SELECT sys.grant_rw(ARRAY['sys.module_gate']);
REVOKE INSERT, UPDATE, DELETE ON sys.module_gate FROM masslak_app;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.21.0', 'Review hardening: RLS on every table, classification, typed references, tenant checks, ledger, seats, business rules, retention, scopes, keys, module gates'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.21.0');

-- Constraints added NOT VALID above are validated now; existing rows that break one are reported, not hidden
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conrelid::regclass::text AS t, conname FROM pg_constraint
            WHERE NOT convalidated AND conname IN ('authority_order_target_type_ck','fraud_case_subject_type_ck','ledger_txn_reversal_reason_ck',
              'passenger_infant_birth_date','trip_pair_fare_from_stop_fk','trip_pair_fare_to_stop_fk',
              'authority_request_approved_before_delivery') LOOP
    BEGIN
      EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', r.t, r.conname);
    EXCEPTION WHEN check_violation OR foreign_key_violation THEN
      RAISE WARNING 'EXISTING_ROWS_BREAK_RULE: % on %: new rows are checked, existing ones need review', r.conname, r.t;
    END;
  END LOOP;
END $$;

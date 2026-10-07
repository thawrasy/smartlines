-- =====================================================================
-- 1046: hardening after the third-party technical audit, and owner decisions
--   A  Owner decisions: school transport comes before the last phase; electronic reporting of violations to the
--      authorities waits for the government's e-government infrastructure (expected beyond two years), so it moves to
--      Phase 5 (government integration). Tracking positions and alerts belong to release 1B: the driver app and the
--      regulator dashboard already use them.
--   B  R-06: a company record sits on a company or entity party; on a person only for an individual owner-driver.
--   C  R-04: contact data. The design rule says phone numbers are protected, the tables held them in clear:
--        - phone numbers of passengers and family members are encrypted (with the key reference and the last four
--          digits for display), written by the application; the clear columns must stay empty;
--        - a person's contact lives only on their account (iam.app_user), never again on the party;
--        - account e-mail and phone (sign-in and notification addresses) stay readable by the application only:
--          reporting and audit roles lose those columns, and the change log masks every contact field.
--   D  R-03: every polymorphic reference is registered with its targets, owner and reason; a weekly sweep counts
--      references to missing rows and raises an alert through the outbox.
--   E  R-14: a closed phase is closed in the database: every table of a later phase that is not already behind a
--      module switch gets a restrictive policy tied to the switches of its phase.
-- =====================================================================

-- =====================================================================
-- A  Owner decisions
-- =====================================================================
UPDATE sys.project_phase SET ordinal = 15.5, name = 'Phase SCH: school transport (before the last phase)' WHERE code = 'SCH';
UPDATE sys.compliance_requirement
   SET description = 'Confirmed violations of vehicles in service are reported electronically to the authorities. Waits for the '
                     || 'government''s e-government infrastructure (expected beyond two years); until then violations stay with the '
                     || 'carrier and the platform',
       authority = 'Transport authority, interior (through government integration, Phase 5)'
 WHERE code = 'route.report.authority';
UPDATE sys.table_phase SET phase_code = '5' WHERE table_name = 'ops.violation_report';
UPDATE sys.table_phase SET phase_code = '1B' WHERE table_name IN ('ops.geo_event','ops.tracking_alert');
UPDATE sys.table_phase SET phase_code = '1A' WHERE table_name = 'gis.spatial_ref_sys';   -- every spatial function reads it

-- =====================================================================
-- B  R-06: the party under a company
-- =====================================================================
CREATE OR REPLACE FUNCTION iam.tg_company_party_type() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE ptype text; ctype text;
BEGIN
  IF TG_TABLE_NAME = 'company' THEN
    SELECT party_type INTO ptype FROM iam.party WHERE id = NEW.id;
    ctype := NEW.company_type;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM iam.company WHERE id = NEW.id) THEN RETURN NEW; END IF;
    ptype := NEW.party_type;
    SELECT company_type INTO ctype FROM iam.company WHERE id = NEW.id;
  END IF;
  IF ptype = 'PERSON' AND ctype <> 'INDIVIDUAL_OPERATOR' THEN
    RAISE EXCEPTION 'COMPANY_PARTY_TYPE: a % company must be a company or entity party; only an individual operator is a person', ctype
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS company_party_type ON iam.company;
CREATE TRIGGER company_party_type BEFORE INSERT OR UPDATE OF id, company_type ON iam.company
  FOR EACH ROW EXECUTE FUNCTION iam.tg_company_party_type();
DROP TRIGGER IF EXISTS company_party_type ON iam.party;
CREATE TRIGGER company_party_type BEFORE UPDATE OF party_type ON iam.party
  FOR EACH ROW EXECUTE FUNCTION iam.tg_company_party_type();

-- =====================================================================
-- C  R-04: contact data
-- =====================================================================
-- The change log masks contact fields as it masks secrets (existing log rows are append-only and stay as written)
CREATE OR REPLACE FUNCTION audit.redact(p jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_object_agg(k, CASE
           WHEN k ~ '(_enc|_hash|_bidx|password|secret|token|signature|template)$' OR k ~ '^(password|secret|token)'
             THEN to_jsonb('***'::text)
           WHEN k ~ '^(mobile|email|phone|address|to_address|contact_mobile|contact_email|contact_phone|payer_mobile)$'
                AND v <> 'null'::jsonb
             THEN to_jsonb('***'::text)
           ELSE v END), '{}'::jsonb)
  FROM jsonb_each(p) AS e(k, v)
$$;

-- Encrypted phone numbers of passengers and family members (the application seals them with the field key)
ALTER TABLE sales.passenger ADD COLUMN IF NOT EXISTS mobile_enc bytea;
ALTER TABLE sales.passenger ADD COLUMN IF NOT EXISTS mobile_last4 text;
ALTER TABLE iam.family_member ADD COLUMN IF NOT EXISTS mobile_enc bytea;
ALTER TABLE iam.family_member ADD COLUMN IF NOT EXISTS mobile_last4 text;
COMMENT ON COLUMN sales.passenger.mobile_enc IS 'Phone number, encrypted under enc_key_id (associated data sales.passenger.mobile)';
COMMENT ON COLUMN iam.family_member.mobile_enc IS 'Phone number, encrypted under enc_key_id (associated data iam.family_member.mobile)';
COMMENT ON COLUMN sales.passenger.mobile IS 'Retired: always empty; the phone number is in mobile_enc';
COMMENT ON COLUMN iam.family_member.mobile IS 'Retired: always empty; the phone number is in mobile_enc';
DO $$ BEGIN
  ALTER TABLE sales.passenger ADD CONSTRAINT passenger_mobile_key_ck CHECK (mobile_enc IS NULL OR enc_key_id IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE iam.family_member ADD CONSTRAINT family_member_mobile_key_ck CHECK (mobile_enc IS NULL OR enc_key_id IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- A person's contact lives on their account only: carry what the account lacks, then clear the party
UPDATE iam.app_user u SET mobile = p.mobile
  FROM iam.party p
 WHERE p.id = u.party_id AND u.mobile IS NULL AND p.mobile IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM iam.app_user x WHERE x.mobile = p.mobile);
UPDATE iam.party p SET mobile = NULL, email = NULL, address = NULL
 WHERE p.party_type = 'PERSON' AND (p.mobile IS NOT NULL OR p.email IS NOT NULL OR p.address IS NOT NULL)
   AND (EXISTS (SELECT 1 FROM iam.app_user u WHERE u.party_id = p.id)
        OR EXISTS (SELECT 1 FROM iam.family_member m WHERE m.party_id = p.id)
        OR EXISTS (SELECT 1 FROM sales.passenger s WHERE s.party_id = p.id));
COMMENT ON COLUMN iam.party.mobile IS 'Contact of a company or entity; empty for persons (their contact is on their account)';
COMMENT ON COLUMN iam.party.email IS 'Contact of a company or entity; empty for persons (their contact is on their account)';

-- The clear columns stay empty for every new or changed row; existing rows are checked once the application's sealing
-- tool has run (python -m app.tools.seal_contacts), and the check then covers them too
DO $$
DECLARE c record;
BEGIN
  FOR c IN SELECT * FROM (VALUES
      ('sales.passenger', 'passenger_mobile_sealed', 'mobile IS NULL'),
      ('iam.family_member', 'family_member_mobile_sealed', 'mobile IS NULL'),
      ('iam.party', 'party_person_contact_sealed', 'party_type <> ''PERSON'' OR (mobile IS NULL AND email IS NULL AND address IS NULL)')
    ) AS x(tbl, con, expr) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = c.tbl::regclass AND conname = c.con) THEN
      EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%s) NOT VALID', c.tbl, c.con, c.expr);
    END IF;
    BEGIN
      EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', c.tbl, c.con);
    EXCEPTION WHEN check_violation THEN
      RAISE WARNING 'CONTACT_NOT_SEALED: %: existing rows hold clear contact data; run python -m app.tools.seal_contacts', c.tbl;
    END;
  END LOOP;
END $$;

-- Reporting and audit roles read everything but contact fields
CREATE OR REPLACE FUNCTION sys.hide_columns(p_table text, p_cols text[], p_roles text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r text; keep text;
BEGIN
  SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO keep
    FROM pg_attribute WHERE attrelid = p_table::regclass AND attnum > 0 AND NOT attisdropped AND attname <> ALL (p_cols);
  FOREACH r IN ARRAY p_roles LOOP
    CONTINUE WHEN NOT has_table_privilege(r, p_table, 'SELECT') AND NOT EXISTS (
      SELECT 1 FROM information_schema.column_privileges WHERE grantee = r AND table_schema || '.' || table_name = p_table);
    EXECUTE format('REVOKE SELECT ON %s FROM %I', p_table, r);
    EXECUTE format('GRANT SELECT (%s) ON %s TO %I', keep, p_table, r);
  END LOOP;
END $$;
REVOKE EXECUTE ON FUNCTION sys.hide_columns(text, text[], text[]) FROM PUBLIC;
SELECT sys.hide_columns('iam.app_user', '{email,mobile}', '{masslak_readonly,masslak_auditor}');
SELECT sys.hide_columns('iam.party', '{email,mobile,address}', '{masslak_readonly,masslak_auditor}');
SELECT sys.hide_columns('sales.passenger', '{mobile,mobile_enc}', '{masslak_readonly,masslak_auditor}');
SELECT sys.hide_columns('iam.family_member', '{mobile,mobile_enc}', '{masslak_readonly,masslak_auditor}');

-- =====================================================================
-- D  R-03: polymorphic references, their owners and a weekly orphan sweep
-- =====================================================================
CREATE TABLE IF NOT EXISTS sys.polymorphic_reference (
  table_name  text NOT NULL,
  type_col    text NOT NULL,
  id_col      text NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('TYPED','BUSINESS','METADATA')),
  targets     jsonb NOT NULL DEFAULT '{}',          -- type value -> table; types not listed are external or free text
  owner       text NOT NULL,                        -- the module that writes and answers for it
  reason      text NOT NULL,                        -- why it is not a single foreign key
  PRIMARY KEY (table_name, type_col)
);
COMMENT ON TABLE sys.polymorphic_reference IS 'Every (type, id) reference: TYPED ones are backed by real foreign keys, BUSINESS ones are swept for orphans weekly, METADATA ones outlive their rows on purpose (third-party audit R-03)';
SELECT sys.rls_catalog('sys.polymorphic_reference');
GRANT SELECT ON sys.polymorphic_reference TO masslak_app, masslak_readonly, masslak_auditor;

-- Typed references, read from the triggers that fill their foreign keys
INSERT INTO sys.polymorphic_reference (table_name, type_col, id_col, kind, targets, owner, reason)
SELECT c.relid::regclass::text, a[1], a[2], 'TYPED', a[3]::jsonb, split_part(c.relid::regclass::text, '.', 1),
       'One reference to several kinds of row; each kind is a real foreign key filled by sys.tg_typed_reference'
  FROM (SELECT t.tgrelid AS relid, string_to_array(encode(t.tgargs, 'escape'), '\000') AS a
          FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
         WHERE p.proname = 'tg_typed_reference' AND NOT t.tgisinternal) c
ON CONFLICT (table_name, type_col) DO UPDATE SET targets = EXCLUDED.targets, kind = 'TYPED';

INSERT INTO sys.polymorphic_reference (table_name, type_col, id_col, kind, targets, owner, reason) VALUES
  ('fin.ledger_txn', 'ref_type', 'ref_id', 'BUSINESS',
   '{"booking":"sales.booking","payment":"fin.payment","family":"iam.family","subscription":"sales.subscription","trip":"ops.trip",
     "withdrawal":"fin.withdrawal_request","shipment":"ship.shipment","company":"iam.company"}', 'fin',
   'A ledger transaction names the business event it posts; the ledger outlives nothing, so a missing event is an error'),
  ('iam.family_spend', 'ref_type', 'ref_id', 'BUSINESS',
   '{"booking":"sales.booking","refund":"sales.booking","subscription":"sales.subscription","ride":"ops.shuttle_ride"}', 'iam',
   'The purchase a family member''s spending came from'),
  ('gov.legal_hold', 'scope_type', 'scope_id', 'BUSINESS',
   '{"PARTY":"iam.party","COMPANY":"iam.company","TRIP":"ops.trip","BOOKING":"sales.booking"}', 'gov',
   'A legal hold covers one record of several kinds, or a whole dataset'),
  ('sales.external_mapping', 'local_type', 'local_id', 'BUSINESS',
   '{"STATION":"net.station","ROUTE":"net.route","TRIP":"ops.trip","CITY":"ref.city"}', 'sales',
   'A channel''s code mapped to one of our stations, routes, trips or cities (fares are matched by code)'),
  ('acct.account_mapping', 'local_type', 'local_id', 'BUSINESS',
   '{"GL_ACCOUNT":"acct.gl_account","PARTY":"iam.party","TAX_CODE":"acct.tax_code","COST_CENTER":"acct.cost_center"}', 'acct',
   'A local record mapped to the external accounting system'),
  ('acct.journal_entry', 'source_type', 'source_id', 'METADATA', '{}', 'acct', 'The posting source as recorded; journals outlive their sources'),
  ('acct.tax_collection_no_file', 'source_type', 'source_id', 'METADATA', '{}', 'acct', 'Tax collection reference as filed'),
  ('bill.usage_event', 'ref_type', 'ref_id', 'METADATA', '{}', 'bill', 'Metered usage keeps the reference it was billed on'),
  ('audit.activity_log', 'object_type', 'object_id', 'METADATA', '{}', 'audit', 'The audit trail must survive deletion of its object'),
  ('audit.data_access_log', 'object_type', 'object_id', 'METADATA', '{}', 'audit', 'The access trail must survive deletion of its object'),
  ('sys.outbox_event', 'aggregate_type', 'aggregate_id', 'METADATA', '{}', 'sys', 'An event outlives its aggregate; consumers carry their own copy')
ON CONFLICT (table_name, type_col) DO UPDATE SET kind = EXCLUDED.kind, targets = EXCLUDED.targets, owner = EXCLUDED.owner, reason = EXCLUDED.reason;

CREATE TABLE IF NOT EXISTS sys.orphan_check (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  checked_at  timestamptz NOT NULL DEFAULT now(),
  orphans     bigint NOT NULL,
  findings    jsonb NOT NULL                        -- [{table, type, target, orphans, sample}]
);
COMMENT ON TABLE sys.orphan_check IS 'Result of each orphan sweep over the registered references; any orphan raises an integrity.orphans_found event';
SELECT sys.rls_platform('sys.orphan_check');
GRANT SELECT ON sys.orphan_check TO masslak_readonly, masslak_auditor;

-- Typed references are checked too: a value of a kind with a table must name a row of it
CREATE OR REPLACE FUNCTION sys.find_orphans()
  RETURNS TABLE (table_name text, type_value text, target text, orphans bigint, sample bigint[])
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record; k text; tgt text;
BEGIN
  FOR r IN SELECT * FROM sys.polymorphic_reference WHERE kind IN ('TYPED','BUSINESS') ORDER BY 1, 2 LOOP
    FOR k, tgt IN SELECT key, value #>> '{}' FROM jsonb_each(r.targets) LOOP
      CONTINUE WHEN to_regclass(tgt) IS NULL OR to_regclass(r.table_name) IS NULL;
      RETURN QUERY EXECUTE format(
        'SELECT %L::text, %L::text, %L::text, count(*), (array_agg(s.%I ORDER BY s.%I))[1:5]
           FROM %s s WHERE s.%I = %L AND s.%I IS NOT NULL AND NOT EXISTS (SELECT 1 FROM %s t WHERE t.id = s.%I)
          HAVING count(*) > 0',
        r.table_name, k, tgt, r.id_col, r.id_col, r.table_name, r.type_col, k, r.id_col, tgt, r.id_col);
    END LOOP;
  END LOOP;
END $$;
COMMENT ON FUNCTION sys.find_orphans IS 'References of the registered polymorphic columns that name a missing row (third-party audit R-03)';
REVOKE EXECUTE ON FUNCTION sys.find_orphans() FROM PUBLIC;

CREATE OR REPLACE FUNCTION sys.run_orphan_check() RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE f jsonb; n bigint; cid bigint;
BEGIN
  SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb), coalesce(sum(x.orphans), 0) INTO f, n FROM sys.find_orphans() x;
  INSERT INTO sys.orphan_check (orphans, findings) VALUES (n, f) RETURNING id INTO cid;
  IF n > 0 THEN
    INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
    VALUES ('integrity.orphans_found', 'sys.orphan_check', cid, jsonb_build_object('orphans', n, 'findings', f));
  END IF;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION sys.run_orphan_check() FROM PUBLIC;

-- The daily upkeep runs the sweep once a week
CREATE OR REPLACE FUNCTION sys.run_maintenance() RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p text; done jsonb := '{}'::jsonb; keep_days int; dropped int := 0; held boolean; r fin.wallet_reconciliation;
        orphans bigint;
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
  IF NOT EXISTS (SELECT 1 FROM sys.orphan_check WHERE checked_at > now() - interval '7 days') THEN
    orphans := sys.run_orphan_check();
  END IF;
  done := jsonb_build_object('partitions_checked', true, 'geo_partitions_dropped', dropped, 'geo_retention_held', held,
                             'expired_holds_released', ops.release_expired_holds(),
                             'wallet_mismatches', r.mismatches, 'orphans', orphans, 'at', now());
  RETURN done;
END $$;

-- =====================================================================
-- E  R-14: a closed phase is closed in the database
-- =====================================================================
ALTER TABLE sys.project_phase ADD COLUMN IF NOT EXISTS feature_keys text[] NOT NULL DEFAULT '{}';
COMMENT ON COLUMN sys.project_phase.feature_keys IS 'The switches that open the phase; none means always open (releases 1A and 1B)';
UPDATE sys.project_phase p SET feature_keys = v.keys FROM (VALUES
  ('ERP', '{accounting_ops}'::text[]), ('2', '{shuttle_rides,approved_lines,shuttle_subscriptions,route_compliance}'),
  ('3', '{cargo}'), ('4', '{international}'), ('5', '{gov_integration,gov_adapters}'), ('6', '{border_manifest}'),
  ('7', '{tracking_stations}'), ('8', '{freight}'), ('9', '{intermediary_platforms,service_partners,loyalty_partners}'),
  ('10', '{rail}'), ('11', '{taxi}'), ('12', '{car_rental}'), ('13', '{transit_passengers}'), ('14', '{contract_transport}'),
  ('15', '{freight}'), ('SCH', '{school_transport}'), ('CS', '{contact_center,ai_assistant}')) AS v(code, keys)
 WHERE p.code = v.code;

CREATE OR REPLACE FUNCTION sys.phase_on(p_code text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT cardinality(feature_keys) = 0 OR sys.feature_on(feature_keys) FROM sys.project_phase WHERE code = p_code), true)
$$;
COMMENT ON FUNCTION sys.phase_on IS 'The phase is open: it needs no switch, or one of its switches is on';
GRANT EXECUTE ON FUNCTION sys.phase_on(text) TO masslak_app, masslak_readonly, masslak_auditor;

-- One restrictive policy per table of a switched phase outside the module schemas (which sys.module_gate closes);
-- rerun after any change to the phase map
CREATE OR REPLACE FUNCTION sys.apply_phase_gates() RETURNS int LANGUAGE plpgsql AS $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT tp.table_name AS t, tp.phase_code AS code,
                  (pp.feature_keys <> '{}' AND split_part(tp.table_name, '.', 1) NOT IN (SELECT schema_name FROM sys.module_gate)) AS gated
             FROM sys.table_phase tp JOIN sys.project_phase pp ON pp.code = tp.phase_code
            WHERE to_regclass(tp.table_name) IS NOT NULL LOOP
    EXECUTE format('DROP POLICY IF EXISTS phase_gate ON %s', r.t);
    IF r.gated THEN
      EXECUTE format('CREATE POLICY phase_gate ON %s AS RESTRICTIVE FOR ALL USING (sys.ctx_is_platform() OR sys.phase_on(%L)) '
                     || 'WITH CHECK (sys.ctx_is_platform() OR sys.phase_on(%L))', r.t, r.code, r.code);
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION sys.apply_phase_gates() FROM PUBLIC;

-- The table classifier reads the business policies only, as it already ignores the module gate
DO $$
DECLARE def text;
BEGIN
  def := pg_get_functiondef('sys.refresh_table_class()'::regprocedure);
  IF position('phase_gate' IN def) = 0 THEN
    def := replace(def, 'p.policyname <> ''module_gate''', 'p.policyname NOT IN (''module_gate'', ''phase_gate'')');
    EXECUTE def;
  END IF;
END $$;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('sys.polymorphic_reference', '1A', 'E03'), ('sys.orphan_check', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();

INSERT INTO sys.schema_migration (version, description)
SELECT '1.28.0', 'Audit hardening: contact data, company party type, orphan sweep, phase gates; school phase and reporting decisions'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.28.0');

SELECT sys.refresh_table_class();

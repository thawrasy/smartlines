-- =====================================================================
-- 1047: the remaining items of the third-party technical audit that live in the database
--   A  R-09: every schema change is recorded in an append-only log, and a security-relevant change (grants, policies,
--      functions, row-level security, triggers) made outside a migration raises an alert through the outbox.
--      Migrations mark themselves with the setting masslak.migrating (db/build.sh and db/upgrade.sh).
--   B  R-08: every JSONB column is registered with its kind and version; rule and shape columns carry a contract the
--      database checks on every write; price and terms snapshots are frozen once written.
--   C  R-11: the data lifecycle matrix (data class, retention, legal basis, erasure, copies and backup expiry) for every
--      dataset that holds personal or operational data, and a purge of delivered events, webhook deliveries and
--      notifications when their retention ends (legal holds respected).
--   D  R-05: the permission matrix of every policy, read from the catalog, for review and for the audit pack.
--   E  R-01: the write sweep found three ways to hand a row to another company; each is closed.
-- =====================================================================

-- =====================================================================
-- A  R-09: schema change log and alerts
-- =====================================================================
CREATE TABLE IF NOT EXISTS audit.ddl_event (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at      timestamptz NOT NULL DEFAULT now(),
  command_tag      text NOT NULL,
  object_type      text,
  object_identity  text,
  in_migration     boolean NOT NULL,
  security_relevant boolean NOT NULL,
  session_user_name text NOT NULL,
  current_user_name text NOT NULL,
  client_addr      inet,
  application_name text,
  statement        text                                  -- first 2,000 characters of the statement
);
CREATE INDEX IF NOT EXISTS ddl_event_security_idx ON audit.ddl_event (occurred_at) WHERE security_relevant AND NOT in_migration;
COMMENT ON TABLE audit.ddl_event IS 'Every schema change (DDL, grants, policies); security-relevant changes outside a migration raise an alert (third-party audit R-09)';
ALTER TABLE audit.ddl_event ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS isolation ON audit.ddl_event;
CREATE POLICY isolation ON audit.ddl_event USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
DROP POLICY IF EXISTS auditor_read ON audit.ddl_event;
CREATE POLICY auditor_read ON audit.ddl_event FOR SELECT TO masslak_auditor USING (true);
GRANT SELECT ON audit.ddl_event TO masslak_auditor, masslak_readonly;
DROP TRIGGER IF EXISTS forbid_mutation ON audit.ddl_event;
CREATE TRIGGER forbid_mutation BEFORE UPDATE OR DELETE ON audit.ddl_event FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

CREATE OR REPLACE FUNCTION audit.ddl_is_security(p_tag text, p_statement text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_tag IN ('GRANT','REVOKE','CREATE POLICY','ALTER POLICY','DROP POLICY','CREATE FUNCTION','ALTER FUNCTION',
                   'DROP FUNCTION','CREATE PROCEDURE','ALTER PROCEDURE','DROP TRIGGER','ALTER TRIGGER','CREATE EVENT TRIGGER',
                   'ALTER EVENT TRIGGER','DROP EVENT TRIGGER','ALTER DEFAULT PRIVILEGES','ALTER EXTENSION','DROP TABLE','DROP SCHEMA')
      OR (p_tag = 'ALTER TABLE' AND coalesce(p_statement, '') ~* '(ROW LEVEL SECURITY|DISABLE\s+TRIGGER|OWNER\s+TO)')
$$;

CREATE OR REPLACE FUNCTION audit.on_ddl_end() RETURNS event_trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record; migrating boolean := coalesce(current_setting('masslak.migrating', true), '') = 'on';
        stmt text := left(current_query(), 2000); sec boolean; ev bigint;
BEGIN
  FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
    CONTINUE WHEN r.in_extension OR coalesce(r.schema_name, '') LIKE 'pg\_temp%';
    sec := audit.ddl_is_security(r.command_tag, stmt);
    INSERT INTO audit.ddl_event (command_tag, object_type, object_identity, in_migration, security_relevant, session_user_name,
                                 current_user_name, client_addr, application_name, statement)
    VALUES (r.command_tag, r.object_type, r.object_identity, migrating, sec, session_user, current_user, inet_client_addr(),
            current_setting('application_name', true), stmt)
    RETURNING id INTO ev;
    IF sec AND NOT migrating THEN
      INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
      VALUES ('security.ddl_change', 'audit.ddl_event', ev,
              jsonb_build_object('command', r.command_tag, 'object', r.object_identity, 'by', session_user, 'at', now()));
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION audit.on_sql_drop() RETURNS event_trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record; migrating boolean := coalesce(current_setting('masslak.migrating', true), '') = 'on';
        stmt text := left(current_query(), 2000); ev bigint;
BEGIN
  FOR r IN SELECT * FROM pg_event_trigger_dropped_objects() WHERE original AND NOT is_temporary LOOP
    INSERT INTO audit.ddl_event (command_tag, object_type, object_identity, in_migration, security_relevant, session_user_name,
                                 current_user_name, client_addr, application_name, statement)
    VALUES (tg_tag, r.object_type, r.object_identity, migrating,
            r.object_type IN ('table','schema','policy','function','trigger','role','event trigger'), session_user, current_user,
            inet_client_addr(), current_setting('application_name', true), stmt)
    RETURNING id INTO ev;
    IF NOT migrating AND r.object_type IN ('table','schema','policy','function','trigger') THEN
      INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
      VALUES ('security.ddl_change', 'audit.ddl_event', ev,
              jsonb_build_object('command', tg_tag, 'object', r.object_identity, 'by', session_user, 'at', now()));
    END IF;
  END LOOP;
END $$;

-- Event triggers need a superuser; on a managed server without one the log is skipped and the setting says so
DO $$
BEGIN
  DROP EVENT TRIGGER IF EXISTS masslak_ddl_end;
  DROP EVENT TRIGGER IF EXISTS masslak_sql_drop;
  CREATE EVENT TRIGGER masslak_ddl_end ON ddl_command_end EXECUTE FUNCTION audit.on_ddl_end();
  CREATE EVENT TRIGGER masslak_sql_drop ON sql_drop EXECUTE FUNCTION audit.on_sql_drop();
  INSERT INTO sys.setting (key, value, description) VALUES ('security.ddl_audit', 'true', 'Schema changes are logged in audit.ddl_event')
  ON CONFLICT (key) DO UPDATE SET value = 'true';
EXCEPTION WHEN insufficient_privilege THEN
  INSERT INTO sys.setting (key, value, description)
  VALUES ('security.ddl_audit', 'false', 'Schema change log unavailable: event triggers need a superuser; use the server''s DDL logging')
  ON CONFLICT (key) DO UPDATE SET value = 'false';
  RAISE WARNING 'DDL_AUDIT_UNAVAILABLE: event triggers need a superuser; enable log_statement = ddl on the server instead';
END $$;

-- =====================================================================
-- B  R-08: JSONB contracts and frozen snapshots
-- =====================================================================
CREATE TABLE IF NOT EXISTS sys.json_contract (
  table_name  text NOT NULL,
  column_name text NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('RULES','SHAPE','SNAPSHOT','CONFIG','EVIDENCE','PAYLOAD','CONTACT')),
  version     int NOT NULL DEFAULT 1 CHECK (version >= 1),
  spec        jsonb,                                   -- the checked contract (a subset of JSON Schema), when the kind needs one
  note        text,
  PRIMARY KEY (table_name, column_name)
);
COMMENT ON TABLE sys.json_contract IS 'Every JSONB column with its kind and contract version; RULES and SHAPE columns are validated on write, SNAPSHOT columns are frozen once written (third-party audit R-08)';
COMMENT ON COLUMN sys.json_contract.spec IS 'Supported: type (or a list of types), required, properties, additionalProperties false, items, enum, minimum, maximum, minItems';
SELECT sys.rls_catalog('sys.json_contract');
GRANT SELECT ON sys.json_contract TO masslak_app, masslak_readonly, masslak_auditor;

-- The first rule a value breaks, as "path: reason"; NULL when it conforms
CREATE OR REPLACE FUNCTION sys.json_violation(p_value jsonb, p_spec jsonb, p_path text DEFAULT '$') RETURNS text
  LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE t text := jsonb_typeof(p_value); want jsonb := p_spec -> 'type'; ok boolean; k text; sub jsonb; v text; i int;
BEGIN
  IF p_spec IS NULL OR p_value IS NULL THEN RETURN NULL; END IF;
  IF want IS NOT NULL THEN
    IF jsonb_typeof(want) = 'string' THEN want := jsonb_build_array(want); END IF;
    SELECT bool_or(w = t OR (w = 'integer' AND t = 'number' AND (p_value #>> '{}')::numeric = trunc((p_value #>> '{}')::numeric)))
      INTO ok FROM jsonb_array_elements_text(want) w;
    IF NOT coalesce(ok, false) THEN RETURN format('%s: expected %s, found %s', p_path, want, t); END IF;
  END IF;
  IF p_spec ? 'enum' AND NOT (p_spec -> 'enum') @> jsonb_build_array(p_value) THEN
    RETURN format('%s: %s is not one of %s', p_path, p_value, p_spec -> 'enum');
  END IF;
  IF t = 'number' THEN
    IF p_spec ? 'minimum' AND (p_value #>> '{}')::numeric < (p_spec ->> 'minimum')::numeric THEN RETURN format('%s: below %s', p_path, p_spec ->> 'minimum'); END IF;
    IF p_spec ? 'maximum' AND (p_value #>> '{}')::numeric > (p_spec ->> 'maximum')::numeric THEN RETURN format('%s: above %s', p_path, p_spec ->> 'maximum'); END IF;
  END IF;
  IF t = 'object' THEN
    FOR k IN SELECT jsonb_array_elements_text(coalesce(p_spec -> 'required', '[]')) LOOP
      IF NOT p_value ? k THEN RETURN format('%s.%s: required', p_path, k); END IF;
    END LOOP;
    FOR k, sub IN SELECT key, value FROM jsonb_each(coalesce(p_spec -> 'properties', '{}')) LOOP
      IF p_value ? k THEN
        v := sys.json_violation(p_value -> k, sub, p_path || '.' || k);
        IF v IS NOT NULL THEN RETURN v; END IF;
      END IF;
    END LOOP;
    IF p_spec -> 'additionalProperties' = 'false'::jsonb THEN
      SELECT key INTO k FROM jsonb_object_keys(p_value) key WHERE NOT coalesce(p_spec -> 'properties', '{}') ? key LIMIT 1;
      IF k IS NOT NULL THEN RETURN format('%s.%s: not allowed', p_path, k); END IF;
    END IF;
  END IF;
  IF t = 'array' THEN
    IF p_spec ? 'minItems' AND jsonb_array_length(p_value) < (p_spec ->> 'minItems')::int THEN
      RETURN format('%s: fewer than %s items', p_path, p_spec ->> 'minItems');
    END IF;
    IF p_spec ? 'items' THEN
      FOR i IN 0 .. jsonb_array_length(p_value) - 1 LOOP
        v := sys.json_violation(p_value -> i, p_spec -> 'items', p_path || '[' || i || ']');
        IF v IS NOT NULL THEN RETURN v; END IF;
      END LOOP;
    END IF;
  END IF;
  RETURN NULL;
END $$;
COMMENT ON FUNCTION sys.json_violation IS 'Checks a JSONB value against a contract (a subset of JSON Schema); returns the first violation or NULL';
GRANT EXECUTE ON FUNCTION sys.json_violation(jsonb, jsonb, text) TO masslak_app, masslak_readonly;

CREATE OR REPLACE FUNCTION sys.tg_json_contract() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c record; val jsonb; old_val jsonb; v text;
BEGIN
  FOR c IN SELECT * FROM sys.json_contract WHERE table_name = TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME AND kind IN ('RULES','SHAPE','SNAPSHOT') LOOP
    val := to_jsonb(NEW) -> c.column_name;
    IF c.kind = 'SNAPSHOT' THEN
      IF TG_OP = 'UPDATE' THEN
        old_val := to_jsonb(OLD) -> c.column_name;
        IF old_val IS NOT NULL AND old_val NOT IN ('null'::jsonb, '{}'::jsonb, '[]'::jsonb) AND val IS DISTINCT FROM old_val THEN
          RAISE EXCEPTION 'SNAPSHOT_FROZEN: %.% cannot change once written', TG_TABLE_NAME, c.column_name USING ERRCODE = 'P0001';
        END IF;
      END IF;
      CONTINUE;
    END IF;
    v := sys.json_violation(val, c.spec, c.column_name);
    IF v IS NOT NULL THEN
      RAISE EXCEPTION 'JSON_CONTRACT_VIOLATION: %.% v%: %', TG_TABLE_NAME, c.column_name, c.version, v USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

-- Every JSONB column classified by name; contracts for the rule and shape columns the platform depends on
INSERT INTO sys.json_contract (table_name, column_name, kind, note)
SELECT i.table_name, i.column_name::text,
       CASE WHEN i.column_name ~ '(snapshot|price_breakdown)$' THEN 'SNAPSHOT'
            WHEN i.column_name IN ('geometry','path','polygon') THEN 'SHAPE'
            WHEN i.column_name = 'address' THEN 'CONTACT'
            WHEN i.column_name ~ '(evidence|detail|details|findings|signals|changes|old_values|new_values|warnings|errors|redacted|result|notified|damage|issues)$'
              THEN 'EVIDENCE'
            WHEN i.column_name IN ('payload','params','proposed_value','new_values','value') AND i.table_name NOT IN ('sys.setting','sys.company_setting','acct.tax_profile_value','gov.policy_change','ship.shipment_option','ship.delivery_preference','pricing.override_policy')
              THEN 'PAYLOAD'
            WHEN i.column_name ~ '(rules|rule|condition|formula|benefit|benefits|terms|tiers|fees|sla|discounts|scope|scope_rule|audience_rule|funding|limits|lines_template|markup_policy|fare_visibility|decision_map|applies_to|base_include|tax_treatment|trigger_rule|regulated_bounds|credit_terms|earned_tiers|baggage_policy|fee_policy|required_fields|validation|crew_seats)$'
              THEN 'RULES'
            ELSE 'CONFIG' END,
       'classified by name (1047)'
  FROM sys.v_jsonb_inventory i
ON CONFLICT (table_name, column_name) DO NOTHING;

INSERT INTO sys.json_contract (table_name, column_name, kind, spec, note) VALUES
  ('pricing.fare_brand', 'rules', 'RULES', '{"type":"object","properties":{
      "refundable":{"type":"boolean"},"changeable":{"type":"boolean"},"priority_boarding":{"type":"boolean"},
      "refund":{"type":"array","items":{"type":"array","minItems":2,"items":{"type":"number","minimum":0}}},
      "change_fee_pct":{"type":"number","minimum":0,"maximum":100},"bags_included":{"type":"integer","minimum":0},
      "kg_per_piece":{"type":"number","minimum":0}}}', 'Fare brand rules: refund ladder [[hours before departure, percent]], change fee, bags'),
  ('fin.payment_provider', 'fee_policy', 'RULES', '{"type":"object","properties":{
      "pct":{"type":"number","minimum":0,"maximum":100},"borne_by":{"enum":["PLATFORM","PAYER"]}}}', 'Who bears the gateway fee'),
  ('net.compliance_profile', 'spec', 'RULES', '{"type":"object","properties":{
      "required":{"type":"array","items":{"type":"string"}},"optional":{"type":"array","items":{"type":"string"}},
      "grace_days":{"type":"integer","minimum":0}}}', 'Required and optional fields with the grace period'),
  ('fleet.vehicle', 'crew_seats', 'RULES', '{"type":"object","properties":{
      "driver":{"type":"integer","minimum":0},"steward":{"type":"integer","minimum":0},"assistant":{"type":"integer","minimum":0}},
      "additionalProperties":false}', 'Crew seats by role'),
  ('net.line_version', 'geometry', 'SHAPE', '{"type":"object","properties":{"type":{"enum":["LineString"]},
      "coordinates":{"type":"array","items":{"type":"array","minItems":2,"items":{"type":"number"}}}}}', 'GeoJSON LineString (drafts may be empty)'),
  ('net.line_diversion', 'geometry', 'SHAPE', '{"type":"object","properties":{"type":{"enum":["LineString"]},
      "coordinates":{"type":"array","items":{"type":"array","minItems":2,"items":{"type":"number"}}}}}', 'GeoJSON LineString'),
  ('net.corridor', 'path', 'SHAPE', '{"type":"object","properties":{"type":{"enum":["LineString"]},
      "coordinates":{"type":"array","items":{"type":"array","minItems":2,"items":{"type":"number"}}}}}', 'GeoJSON LineString'),
  ('sch.route', 'path', 'SHAPE', '{"type":["object","null"],"properties":{"type":{"enum":["LineString"]},
      "coordinates":{"type":"array","items":{"type":"array","minItems":2,"items":{"type":"number"}}}}}', 'GeoJSON LineString'),
  ('ops.trip', 'baggage_policy', 'RULES', '{"type":"object"}', 'Baggage policy of the trip'),
  ('sales.booking', 'price_breakdown', 'SNAPSHOT', NULL, 'The price as sold; frozen once written'),
  ('sales.ticket', 'rules_snapshot', 'SNAPSHOT', NULL, 'The fare rules as sold; frozen once written'),
  ('sales.refund_request', 'policy_snapshot', 'SNAPSHOT', NULL, 'The refund policy applied; frozen once written'),
  ('gov.policy_change', 'authority_snapshot', 'SNAPSHOT', NULL, 'The authority as it was when the change was decided'),
  ('ops.trip', 'crew_snapshot', 'CONFIG', NULL, 'Crew at publication; refreshed when the crew changes before departure'),
  ('ops.trip', 'seat_prices_snapshot', 'CONFIG', NULL, 'Seat prices at publication; refreshed when the carrier reprices before sale'),
  ('ship.shipment', 'price_breakdown', 'CONFIG', NULL, 'Quoted price; requoted until the shipment is accepted'),
  ('frt.freight_contract', 'price_breakdown', 'CONFIG', NULL, 'Price of the awarded contract')
ON CONFLICT (table_name, column_name) DO UPDATE SET kind = EXCLUDED.kind, spec = EXCLUDED.spec, note = EXCLUDED.note,
  version = CASE WHEN sys.json_contract.spec IS NOT NULL AND sys.json_contract.spec IS DISTINCT FROM EXCLUDED.spec
                 THEN sys.json_contract.version + 1 ELSE sys.json_contract.version END;

-- One trigger per table that has a checked or frozen column
CREATE OR REPLACE FUNCTION sys.apply_json_contracts() RETURNS int LANGUAGE plpgsql AS $$
DECLARE t text; n int := 0;
BEGIN
  FOR t IN SELECT DISTINCT table_name FROM sys.json_contract
            WHERE to_regclass(table_name) IS NOT NULL AND (kind = 'SNAPSHOT' OR (kind IN ('RULES','SHAPE') AND spec IS NOT NULL)) LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS json_contract ON %s', t);
    EXECUTE format('CREATE TRIGGER json_contract BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_json_contract()', t);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION sys.apply_json_contracts() FROM PUBLIC;
SELECT sys.apply_json_contracts();

-- Rows already stored that break their contract (read by the tests and the audit pack)
CREATE OR REPLACE FUNCTION sys.json_contract_violations()
  RETURNS TABLE (table_name text, column_name text, violations bigint, first_violation text)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c record;
BEGIN
  FOR c IN SELECT * FROM sys.json_contract WHERE spec IS NOT NULL AND to_regclass(json_contract.table_name) IS NOT NULL LOOP
    RETURN QUERY EXECUTE format(
      'SELECT %L::text, %L::text, count(*), min(v) FROM (SELECT sys.json_violation(%I, %L::jsonb, %L) AS v FROM %s) x WHERE v IS NOT NULL HAVING count(*) > 0',
      c.table_name, c.column_name, c.column_name, c.spec, c.column_name, c.table_name);
  END LOOP;
END $$;
REVOKE EXECUTE ON FUNCTION sys.json_contract_violations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.json_contract_violations() TO masslak_auditor;

-- =====================================================================
-- C  R-11: data lifecycle matrix and purge
-- =====================================================================
ALTER TABLE gov.data_inventory ADD COLUMN IF NOT EXISTS erasure_method text;
ALTER TABLE gov.data_inventory ADD COLUMN IF NOT EXISTS copies text[] NOT NULL DEFAULT '{}';
ALTER TABLE gov.data_inventory ADD COLUMN IF NOT EXISTS backup_retention_days int CHECK (backup_retention_days IS NULL OR backup_retention_days > 0);
DO $$ BEGIN
  ALTER TABLE gov.data_inventory ADD CONSTRAINT data_inventory_erasure_ck CHECK (erasure_method IS NULL OR erasure_method IN
    ('PSEUDONYMISE','DELETE','DROP_PARTITION','KEEP_LEGAL','AGGREGATE_ONLY'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN gov.data_inventory.copies IS 'Where copies of the data go: replicas, backups, object storage, search, outbox, webhooks, exports';

INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days) VALUES
  ('iam.party', 'RESTRICTED', 'iam', 'Identity of persons and companies', 'Contract', 2555, 'PSEUDONYMISE', '{replica,backup}', 35),
  ('iam.app_user', 'RESTRICTED', 'iam', 'Accounts and sign-in addresses', 'Contract', 2555, 'PSEUDONYMISE', '{replica,backup}', 35),
  ('iam.family_member', 'RESTRICTED', 'iam', 'Family members defined by a head', 'Contract and consent', 1825, 'PSEUDONYMISE', '{replica,backup}', 35),
  ('sales.passenger', 'RESTRICTED', 'sales', 'Passengers of a booking (identity, encrypted documents and phones)', 'Contract and legal manifest duty', 1825, 'PSEUDONYMISE', '{replica,backup,manifests}', 35),
  ('sales.booking', 'CONFIDENTIAL', 'sales', 'Bookings and their price', 'Contract and tax law', 3650, 'KEEP_LEGAL', '{replica,backup,ledger,einvoice}', 35),
  ('fin.ledger_entry', 'CONFIDENTIAL', 'fin', 'Double-entry ledger', 'Accounting law', 3650, 'KEEP_LEGAL', '{replica,backup}', 35),
  ('ops.geo_event', 'CONFIDENTIAL', 'ops', 'Positions of vehicles while tracked', 'Legitimate interest and regulation', 90, 'DROP_PARTITION', '{backup}', 35),
  ('ops.route_violation', 'CONFIDENTIAL', 'ops', 'Route violations with their evidence', 'Regulation', 730, 'DELETE', '{replica,backup}', 35),
  ('sch.student', 'RESTRICTED', 'sch', 'Pupils (minors) with encrypted medical notes', 'Contract and guardian consent', 365, 'DELETE', '{replica,backup}', 35),
  ('sch.attendance', 'RESTRICTED', 'sch', 'Boarding and hand-over of pupils', 'Safety of minors', 365, 'DELETE', '{replica,backup}', 35),
  ('sys.outbox_event', 'CONFIDENTIAL', 'sys', 'Events waiting for or delivered to consumers', 'Contract', 30, 'DELETE', '{webhooks,notifications}', 35),
  ('sys.webhook_delivery', 'CONFIDENTIAL', 'sys', 'Webhook deliveries to partners', 'Contract', 90, 'DELETE', '{partners}', 35),
  ('crm.notification', 'CONFIDENTIAL', 'crm', 'Messages sent to users (addresses masked)', 'Contract', 365, 'DELETE', '{email,sms}', 35),
  ('audit.activity_log', 'CONFIDENTIAL', 'audit', 'Request log', 'Legal obligation and security', 2555, 'KEEP_LEGAL', '{backup,worm_archive}', 35),
  ('audit.row_change', 'CONFIDENTIAL', 'audit', 'Database change capture (contact fields masked)', 'Legal obligation and security', 2555, 'KEEP_LEGAL', '{backup,worm_archive}', 35),
  ('audit.ddl_event', 'INTERNAL', 'audit', 'Schema and privilege changes', 'Security', 2555, 'KEEP_LEGAL', '{backup,worm_archive}', 35),
  ('ref.file_object', 'RESTRICTED', 'ref', 'Uploaded documents (encrypted in object storage)', 'Contract and regulation', 2555, 'DELETE', '{object_storage,backup}', 35)
ON CONFLICT (dataset) DO UPDATE SET erasure_method = EXCLUDED.erasure_method, copies = EXCLUDED.copies,
  backup_retention_days = EXCLUDED.backup_retention_days, retention_days = coalesce(gov.data_inventory.retention_days, EXCLUDED.retention_days);

CREATE OR REPLACE VIEW gov.v_lifecycle_matrix AS
SELECT d.dataset, d.data_class, tc.data_class AS table_data_class, d.owner, d.purpose, d.legal_basis, d.retention_days,
       d.erasure_method, d.copies, d.backup_retention_days,
       EXISTS (SELECT 1 FROM gov.legal_hold h WHERE h.released_at IS NULL AND h.scope_type = 'DATASET' AND h.dataset = d.dataset) AS on_legal_hold
  FROM gov.data_inventory d LEFT JOIN sys.table_class tc ON tc.table_name = d.dataset;
COMMENT ON VIEW gov.v_lifecycle_matrix IS 'Data class, retention, legal basis, erasure method, copies and backup expiry of every dataset (third-party audit R-11)';
GRANT SELECT ON gov.v_lifecycle_matrix TO masslak_auditor, masslak_readonly;

-- Delivered events, finished webhook deliveries and old notifications are purged when their retention ends
CREATE OR REPLACE FUNCTION sys.purge_expired() RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE d_out int := 0; d_hook int := 0; d_note int := 0; days int;
  held text[] := ARRAY(SELECT dataset FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'DATASET');
BEGIN
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'sys.webhook_delivery';
  IF days IS NOT NULL AND NOT 'sys.webhook_delivery' = ANY (held) THEN
    DELETE FROM sys.webhook_delivery WHERE status IN ('DELIVERED','DEAD') AND created_at < now() - make_interval(days => days);
    GET DIAGNOSTICS d_hook = ROW_COUNT;
  END IF;
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'sys.outbox_event';
  IF days IS NOT NULL AND NOT 'sys.outbox_event' = ANY (held) THEN
    DELETE FROM sys.outbox_event o WHERE o.status = 'PUBLISHED' AND o.published_at < now() - make_interval(days => days)
       AND NOT EXISTS (SELECT 1 FROM sys.webhook_delivery w WHERE w.outbox_event_id = o.id);
    GET DIAGNOSTICS d_out = ROW_COUNT;
  END IF;
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'crm.notification';
  IF days IS NOT NULL AND NOT 'crm.notification' = ANY (held) THEN
    DELETE FROM crm.notification WHERE created_at < now() - make_interval(days => days);
    GET DIAGNOSTICS d_note = ROW_COUNT;
  END IF;
  RETURN jsonb_build_object('outbox_events', d_out, 'webhook_deliveries', d_hook, 'notifications', d_note);
END $$;
REVOKE EXECUTE ON FUNCTION sys.purge_expired() FROM PUBLIC;

-- The daily upkeep also purges
DO $$
DECLARE def text;
BEGIN
  def := pg_get_functiondef('sys.run_maintenance()'::regprocedure);
  IF position('purge_expired' IN def) = 0 THEN
    def := replace(def, '''orphans'', orphans, ''at'', now());', '''orphans'', orphans, ''purged'', sys.purge_expired(), ''at'', now());');
    EXECUTE def;
  END IF;
END $$;

-- =====================================================================
-- D  R-05: the permission matrix
-- =====================================================================
CREATE OR REPLACE VIEW sys.v_policy_matrix AS
SELECT p.schemaname || '.' || p.tablename AS table_name, tc.data_class, tc.tenant_path, tp.phase_code,
       p.policyname, p.permissive, p.cmd AS command, p.roles::text AS roles, p.qual AS using_expr,
       coalesce(p.with_check, CASE WHEN p.cmd IN ('ALL','UPDATE') THEN p.qual END) AS check_expr,
       CASE WHEN p.policyname IN ('module_gate','phase_gate') THEN 'SWITCH'
            WHEN p.qual ~ 'ctx_is_platform\(\)' AND p.qual !~ 'tenant_visible|ctx_party_id|ctx_user_id|is_me|EXISTS' THEN 'PLATFORM'
            WHEN coalesce(p.qual, '') ~ '^\s*true\s*$' THEN 'PUBLIC'
            WHEN p.qual ~ 'tenant_visible' THEN 'TENANT'
            WHEN p.qual ~ 'ctx_party_id|ctx_user_id|is_me' THEN 'OWNER'
            WHEN p.qual ~ 'EXISTS' THEN 'PARENT'
            ELSE 'OTHER' END AS actor_scope
  FROM pg_policies p
  LEFT JOIN sys.table_class tc ON tc.table_name = p.schemaname || '.' || p.tablename
  LEFT JOIN sys.table_phase tp ON tp.table_name = p.schemaname || '.' || p.tablename;
COMMENT ON VIEW sys.v_policy_matrix IS 'Every policy as subject x actor scope x command, with its read and write conditions (third-party audit R-05)';
GRANT SELECT ON sys.v_policy_matrix TO masslak_auditor, masslak_readonly;


-- =====================================================================
-- E  R-01: what the write sweep found (backend/tests/test_isolation.py)
-- =====================================================================
-- Typed reference columns are derived only: their trigger now fires on every update, so writing one directly is undone
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT t.tgrelid::regclass::text AS tbl, t.tgname, encode(t.tgargs, 'escape') AS args
             FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
            WHERE p.proname = 'tg_typed_reference' AND NOT t.tgisinternal LOOP
    EXECUTE format('DROP TRIGGER %I ON %s', r.tgname, r.tbl);
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_typed_reference(%s)',
                   r.tgname, r.tbl, (SELECT string_agg(quote_literal(a), ', ') FROM unnest(string_to_array(rtrim(r.args, E'\\000'), E'\\000')) a));
  END LOOP;
END $$;

-- and the helper creates them that way from now on
DO $$
DECLARE def text;
BEGIN
  def := pg_get_functiondef('sys.typed_reference(text,text,text,jsonb)'::regprocedure);
  IF position('UPDATE OF %I, %I ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_typed_reference' IN def) > 0 THEN
    def := replace(def, 'BEFORE INSERT OR UPDATE OF %I, %I ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_typed_reference(%L, %L, %L, %L)'',
                 left(prefix || ''_typed_ref'', 63), p_type_col, p_id_col, p_table,',
                 'BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_typed_reference(%L, %L, %L, %L)'',
                 left(prefix || ''_typed_ref'', 63), p_table,');
    EXECUTE def;
  END IF;
END $$;

-- A file belongs to a company the writer acts for; a personal upload carries no company
DROP POLICY IF EXISTS file_object_isolation ON ref.file_object;
CREATE POLICY file_object_isolation ON ref.file_object
  USING (sys.tenant_visible(company_id) OR uploaded_by = sys.ctx_user_id())
  WITH CHECK (sys.tenant_visible(company_id) OR (company_id IS NULL AND uploaded_by = sys.ctx_user_id()));

-- A session keeps its user, and acts only for a company its user is an active member of
CREATE OR REPLACE FUNCTION iam.tg_session_company() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'SESSION_USER_FIXED: a session cannot change its user' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.company_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.company_id IS DISTINCT FROM OLD.company_id)
     AND NOT EXISTS (SELECT 1 FROM iam.company_member m WHERE m.user_id = NEW.user_id AND m.company_id = NEW.company_id AND m.status = 'ACTIVE') THEN
    RAISE EXCEPTION 'SESSION_COMPANY_NOT_MEMBER: the session''s user is not an active member of that company' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS session_company ON iam.user_session;
CREATE TRIGGER session_company BEFORE INSERT OR UPDATE OF user_id, company_id ON iam.user_session
  FOR EACH ROW EXECUTE FUNCTION iam.tg_session_company();

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('audit.ddl_event', '1A', 'E25'), ('sys.json_contract', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.29.0', 'Audit operations: schema change log and alerts, JSONB contracts and frozen snapshots, lifecycle matrix and purge, policy matrix'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.29.0');

SELECT sys.refresh_table_class();

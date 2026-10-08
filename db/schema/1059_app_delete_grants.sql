-- =====================================================================
-- 1059: the application deletes only where it must (expert review of October 2026, stage C, narrower grants step 1)
--   Until now masslak_app held DELETE on almost every table (900 granted it schema by schema, sys.grant_rw table by
--   table), and row-level security alone decided what a delete could reach. The application deletes from 36 tables:
--   three in its own code (MFA factors, push tokens, family travel rules) and the 33 lists the module screens edit
--   line by line. sys.app_delete_grant records them with the reason; DELETE is revoked everywhere else, and
--   sys.grant_rw no longer grants it. A new delete in the code needs a row here first (db/tests and the API tests
--   check both sides). Business records are never deleted by the application: they are cancelled, closed or archived.
-- =====================================================================

CREATE TABLE IF NOT EXISTS sys.app_delete_grant (
  table_name  text PRIMARY KEY CHECK (table_name ~ '^[a-z_]+\.[a-z_]+$'),
  reason      text NOT NULL CHECK (length(reason) >= 10),
  granted_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sys.app_delete_grant IS 'The tables the application may delete from, and why; DELETE is revoked from masslak_app everywhere else (1059)';
SELECT sys.rls_catalog('sys.app_delete_grant');
REVOKE ALL ON sys.app_delete_grant FROM masslak_app;
GRANT SELECT ON sys.app_delete_grant TO masslak_app, masslak_readonly, masslak_auditor;

INSERT INTO sys.app_delete_grant (table_name, reason) VALUES
  -- the application's own code
  ('iam.mfa_factor', 'a person removes an authenticator, or staff reset a lost second factor'),
  ('iam.push_token', 'a device signs out or its push token is replaced'),
  ('iam.family_travel_rule', 'the head of a family removes a travel rule of a member'),
  -- module screens: lines of a list, edited in place (backend/app/modular/specs, delete=True)
  ('brd.manifest_cargo', 'cargo lines of a manifest still being prepared'),
  ('crm.ai_eval_case', 'evaluation cases of the assistant, kept by the platform'),
  ('crm.call_agent_skill', 'skills of a contact centre agent'),
  ('crm.call_queue_skill', 'skills a contact centre queue asks for'),
  ('crm.call_skill', 'the contact centre skill list'),
  ('ctr.authorized_receiver', 'people a contract allows to receive passengers'),
  ('ctr.contract_route', 'routes of a transport contract'),
  ('frt.leg_container', 'containers on a freight leg'),
  ('iam.beneficial_owner', 'beneficial owners a company declares'),
  ('iam.user_station_scope', 'stations a staff account may work at'),
  ('net.approved_rest_stop', 'rest stops approved for a line'),
  ('net.line_fare', 'fares between the stops of a line'),
  ('net.line_stop', 'stops of a line'),
  ('net.station_contact', 'contact people of a station'),
  ('ops.trip_crossing_plan', 'border crossings planned for a trip'),
  ('pricing.allocation_template_line', 'lines of a revenue allocation template'),
  ('pricing.fare_table_item', 'items of a fare table'),
  ('ptn.partner_menu_item', 'a service partner''s menu items'),
  ('rail.train_composition', 'cars of a train'),
  ('sales.channel_inventory_rule', 'seat quotas of a sales channel'),
  ('sales.external_mapping', 'codes mapped to an external system'),
  ('sch.route_stop', 'stops of a school route'),
  ('sec.blocklist_entry', 'entries of the security blocklist, removed by the security team'),
  ('ship.cargo_rate_card', 'lines of a cargo rate card'),
  ('ship.load_plan', 'load plans of a shipment run'),
  ('ship.load_stop', 'stops of a load plan'),
  ('ship.partner_status_map', 'status codes mapped from a shipping partner'),
  ('ship.pricing_zone_chart', 'cells of a pricing zone chart'),
  ('ship.prohibited_item', 'the prohibited items list'),
  ('ship.rate_table_entry', 'entries of a shipping rate table'),
  ('ship.routing_rule', 'shipment routing rules'),
  ('ship.sort_window', 'sorting windows of a hub'),
  ('ship.transit_time_matrix', 'cells of the transit time matrix')
ON CONFLICT (table_name) DO NOTHING;

-- Grants DELETE exactly where sys.app_delete_grant says, and revokes it everywhere else
CREATE OR REPLACE FUNCTION sys.enforce_app_delete_grants() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE t record; revoked integer := 0;
BEGIN
  FOR t IN
    SELECT c.oid::regclass AS tbl, n.nspname || '.' || c.relname AS name
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'public', 'gis')
       AND n.nspname NOT LIKE 'pg\_%'
  LOOP
    IF EXISTS (SELECT 1 FROM sys.app_delete_grant g WHERE g.table_name = t.name) THEN
      EXECUTE format('GRANT DELETE ON %s TO masslak_app', t.tbl);
    ELSIF has_table_privilege('masslak_app', t.tbl, 'DELETE') THEN
      EXECUTE format('REVOKE DELETE ON %s FROM masslak_app', t.tbl);
      revoked := revoked + 1;
    END IF;
  END LOOP;
  RETURN revoked;
END $$;
COMMENT ON FUNCTION sys.enforce_app_delete_grants IS 'Applies sys.app_delete_grant: DELETE for masslak_app on the listed tables only (1059)';
REVOKE ALL ON FUNCTION sys.enforce_app_delete_grants() FROM PUBLIC;

-- New tables get read and write without delete; a delete is granted through sys.app_delete_grant
CREATE OR REPLACE FUNCTION sys.grant_rw(p_tables text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY p_tables LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE ON %s TO masslak_app', t);
    EXECUTE format('GRANT SELECT ON %s TO masslak_readonly', t);
    IF EXISTS (SELECT 1 FROM sys.app_delete_grant g WHERE g.table_name = t) THEN
      EXECUTE format('GRANT DELETE ON %s TO masslak_app', t);
    END IF;
  END LOOP;
END $$;

SELECT sys.enforce_app_delete_grants();

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sys.app_delete_grant', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days)
VALUES ('sys.app_delete_grant', 'INTERNAL', 'sys', 'Where the application may delete rows, with the reason', 'Legitimate interest', 3650,
        'KEEP_LEGAL', '{replica,backup}', 35)
ON CONFLICT (dataset) DO NOTHING;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.39.1', 'Expert review stage C: the application deletes only from the tables listed in sys.app_delete_grant'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.39.1');

SELECT sys.refresh_table_class();

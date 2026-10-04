-- =====================================================================
-- 1010: full data model of study v2.6 (files 1010 to 1029)
--   Files 1010 to 1029 complete the database against every entity the study defines, including the modules
--   of later phases (sections 4.10, 9, 10, 11, 13, 14, 21 and appendix D). Each module stays disabled behind its
--   feature flag until its phase starts (2.8, decision D-6). Nothing in the existing tables is removed.
--   This file adds the new schemas and the helpers the following files use to declare row-level security and
--   privileges in one line per table.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS bill;   -- carrier subscriptions, metering and platform invoices (5.11 d)
CREATE SCHEMA IF NOT EXISTS ptn;    -- service partners: fuel stations, rest stops, maintenance (14.11)
CREATE SCHEMA IF NOT EXISTS ship;   -- shipments and the integrated shipping network (9)
CREATE SCHEMA IF NOT EXISTS frt;    -- trucking, heavy transport and transit freight (10)
CREATE SCHEMA IF NOT EXISTS brd;    -- border manifest gateway (11)
CREATE SCHEMA IF NOT EXISTS rail;   -- rail extension (phase 10, 14.8)
CREATE SCHEMA IF NOT EXISTS taxi;   -- taxis within and between cities (phase 11, 21.1)
CREATE SCHEMA IF NOT EXISTS rent;   -- unified car rental platform (phase 12, 21.2)
COMMENT ON SCHEMA bill IS 'Carrier subscriptions, plans, agreements, metering and platform invoices';
COMMENT ON SCHEMA ptn  IS 'Service partners (fuel stations, rest stops, maintenance): contracts, sales and settlement';
COMMENT ON SCHEMA ship IS 'Shipments, parcels, handling units, hubs, couriers, rates and partner integration (study 9)';
COMMENT ON SCHEMA frt  IS 'Freight requests, bids, contracts, legs, containers, transit declarations (study 10)';
COMMENT ON SCHEMA brd  IS 'Border manifest gateway: border points, crossing profiles, manifests and responses (study 11)';
COMMENT ON SCHEMA rail IS 'Rail extension: coach layouts, fare classes and connected journeys (phase 10)';
COMMENT ON SCHEMA taxi IS 'Taxis: permits, shifts, ride requests, dispatch and meter tariffs (phase 11)';
COMMENT ON SCHEMA rent IS 'Car rental: companies, branches, rates, bookings, contracts, inspections and deposits (phase 12)';

-- ------------------------------ policy helpers ------------------------------
-- One policy per table, recreated on every run so the files stay idempotent.
CREATE OR REPLACE FUNCTION sys.rls(p_table text, p_using text, p_check text DEFAULT NULL, p_name text DEFAULT 'isolation')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_table);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %s', p_name, p_table);
  EXECUTE format('CREATE POLICY %I ON %s USING (%s) WITH CHECK (%s)', p_name, p_table, p_using, coalesce(p_check, p_using));
END $$;

-- Rows owned by one company (tenant): the platform or that company
CREATE OR REPLACE FUNCTION sys.rls_tenant(p_table text, p_column text DEFAULT 'company_id') RETURNS void
LANGUAGE sql AS $$ SELECT sys.rls(p_table, format('sys.tenant_visible(%I)', p_column)) $$;

-- Rows that inherit the visibility of their parent row (the parent's own policy decides)
CREATE OR REPLACE FUNCTION sys.rls_parent(p_table text, p_column text, p_parent text, p_parent_key text DEFAULT 'id') RETURNS void
LANGUAGE sql AS $$
  -- the child column is qualified with the child table name so it never binds to a parent column of the same name
  SELECT sys.rls(p_table, format('EXISTS (SELECT 1 FROM %s p WHERE p.%I = %I.%I)', p_parent, p_parent_key,
                                 (parse_ident(p_table))[2], p_column))
$$;

-- Different read and write rules (public timetables and plans written by their company)
CREATE OR REPLACE FUNCTION sys.rls_split(p_table text, p_read text, p_write text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_table);
  EXECUTE format('DROP POLICY IF EXISTS split_read ON %s', p_table);
  EXECUTE format('DROP POLICY IF EXISTS split_write ON %s', p_table);
  EXECUTE format('CREATE POLICY split_read ON %s FOR SELECT USING (%s)', p_table, p_read);
  EXECUTE format('CREATE POLICY split_write ON %s FOR ALL USING (%s) WITH CHECK (%s)', p_table, p_write, p_write);
END $$;

-- Operational rows of a trip: only the trip's company and the platform. Published trips are readable by all,
-- so trip children check the company explicitly instead of inheriting the trip's read policy.
CREATE OR REPLACE FUNCTION sys.rls_trip(p_table text, p_extra text DEFAULT NULL) RETURNS void
LANGUAGE sql AS $$
  SELECT sys.rls(p_table, '(EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = trip_id AND sys.tenant_visible(x.company_id)))'
                          || coalesce(' OR ' || p_extra, ''))
$$;

-- Platform catalogs: everyone reads, only the platform writes
CREATE OR REPLACE FUNCTION sys.rls_catalog(p_table text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_table);
  EXECUTE format('DROP POLICY IF EXISTS catalog_read ON %s', p_table);
  EXECUTE format('DROP POLICY IF EXISTS catalog_write ON %s', p_table);
  EXECUTE format('CREATE POLICY catalog_read ON %s FOR SELECT USING (true)', p_table);
  EXECUTE format('CREATE POLICY catalog_write ON %s FOR ALL USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform())', p_table);
END $$;

-- Platform-only data (treasury, security, regulator links)
CREATE OR REPLACE FUNCTION sys.rls_platform(p_table text) RETURNS void
LANGUAGE sql AS $$ SELECT sys.rls(p_table, 'sys.ctx_is_platform()') $$;

-- Privileges: read-write for the application, read for reporting
CREATE OR REPLACE FUNCTION sys.grant_rw(p_tables text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY p_tables LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %s TO masslak_app', t);
    EXECUTE format('GRANT SELECT ON %s TO masslak_readonly', t);
  END LOOP;
END $$;

-- Append-only: the application inserts and reads, never updates or deletes (plus a trigger)
CREATE OR REPLACE FUNCTION sys.grant_append(p_tables text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY p_tables LOOP
    EXECUTE format('REVOKE UPDATE, DELETE ON %s FROM masslak_app', t);
    EXECUTE format('GRANT SELECT, INSERT ON %s TO masslak_app', t);
    EXECUTE format('GRANT SELECT ON %s TO masslak_readonly', t);
    EXECUTE format('DROP TRIGGER IF EXISTS forbid_mutation ON %s', t);
    EXECUTE format('CREATE TRIGGER forbid_mutation BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation()', t);
  END LOOP;
END $$;

-- updated_at maintenance
CREATE OR REPLACE FUNCTION sys.track_updates(p_table text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS set_updated_at ON %s', p_table);
  EXECUTE format('CREATE TRIGGER set_updated_at BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at()', p_table);
END $$;

-- Migration helpers only: never callable by the application
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['sys.rls(text,text,text,text)','sys.rls_tenant(text,text)','sys.rls_parent(text,text,text,text)',
                           'sys.rls_catalog(text)','sys.rls_split(text,text,text)','sys.rls_trip(text,text)','sys.rls_platform(text)','sys.grant_rw(text[])','sys.grant_append(text[])',
                           'sys.track_updates(text)'] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', f);
  END LOOP;
END $$;

DO $$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY['bill','ptn','ship','frt','brd','rail','taxi','rent'] LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO masslak_app, masslak_readonly, masslak_auditor', s);
  END LOOP;
END $$;

-- A party may own rows directly (passenger's own rides, vouchers, orders)
CREATE OR REPLACE FUNCTION sys.is_me(p_user_id bigint) RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT p_user_id IS NOT NULL AND p_user_id = sys.ctx_user_id() $$;

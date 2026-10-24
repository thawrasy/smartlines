-- =====================================================================
-- Masslak - 1084: the settings the database trusts, protected by the server (reviews of release 1.49.0, the residual
-- path of finding C-01)
--
-- Row-level security reads the request context from transaction settings (app.*), and the ledger, requirement,
-- file-scan and cargo guards read flags the platform's functions raise (fin.posting_entry, masslak.*). Schema file 1080
-- withdrew set_config from every role, so injected SQL cannot change them; a login could still type
-- SET app.scope = 'PLATFORM' as a statement of its own, since PostgreSQL lets anyone set a setting nobody defined.
-- The settings guard (db/guard/masslak_guard.c), loaded with the server, defines each of them with the superuser
-- context: such a statement, a value in the connection options, RESET and ALTER ROLE ... SET are refused to every
-- login but a superuser. The platform's functions that set them are SECURITY DEFINER and owned by the superuser that
-- applies the schema, so they keep working; reading is not restricted, so the row rules cost nothing more.
--
-- This file
--   1. names the protected settings for the database (sys.guarded_settings) and reports whether the server enforces
--      them (sys.guard_status): the API's readiness check requires it on a production server, the production preflight
--      before installing;
--   2. moves the list of rows the current transaction created, which their creator may read back (1039), from one
--      setting per table (app.new.<schema>.<table>, names no module can define in advance) to the one protected
--      setting app.new_rows, holding schema.table:id entries.
-- A server without the guard (a developer's own PostgreSQL) works as before; the guard is part of every database image
-- of the repository (docker-compose.yml, deploy/production/db, deploy/staging/db) and of the CI jobs.
-- =====================================================================

-- ------------------------------------------------------------------ 1. the protected settings
-- The same list as db/guard/masslak_guard.c and backend/app/guard.py (backend/tests/test_settings_guard.py compares
-- the three, and checks that every custom setting the schema reads is on it).
CREATE OR REPLACE FUNCTION sys.guarded_settings() RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['app.user_id', 'app.company_id', 'app.scope', 'app.api_client_id', 'app.request_id', 'app.ip',
               'app.session_id', 'app.party_id', 'app.new_rows',
               'fin.posting_entry', 'masslak.requirement_change', 'masslak.cargo_backfill', 'masslak.migrating']
$$;
COMMENT ON FUNCTION sys.guarded_settings IS 'Settings the database trusts, which only the platform''s own functions may set (db/guard, 1084)';

-- true when the server defines every one of them with the superuser context, that is when the guard is loaded
CREATE OR REPLACE FUNCTION sys.guard_status() RETURNS boolean
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM unnest(sys.guarded_settings()) AS g(name)
     WHERE NOT EXISTS (SELECT 1 FROM pg_settings s WHERE s.name = g.name AND s.context = 'superuser'))
$$;
COMMENT ON FUNCTION sys.guard_status IS 'True when the settings guard is loaded: every setting of sys.guarded_settings() can be set by a superuser only (1084)';
GRANT EXECUTE ON FUNCTION sys.guarded_settings() TO PUBLIC;
GRANT EXECUTE ON FUNCTION sys.guard_status() TO PUBLIC;

-- ------------------------------------------------------------------ 2. rows created by the transaction
-- 1080 made this trigger run as its owner; the list it keeps is now one protected setting for every table.
CREATE OR REPLACE FUNCTION sys.tg_remember_new_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  PERFORM set_config('app.new_rows',
                     coalesce(nullif(current_setting('app.new_rows', true), ''), '') || ',' || TG_TABLE_SCHEMA || '.'
                       || TG_TABLE_NAME || ':' || NEW.id::text,
                     true);
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION sys.created_here(p_table text, p_id bigint) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT (p_table || ':' || p_id::text) = ANY (string_to_array(nullif(current_setting('app.new_rows', true), ''), ','))
$$;
COMMENT ON FUNCTION sys.created_here IS 'True for a row inserted by the current transaction: its creator may read it back (1039; one protected list since 1084)';

-- ------------------------------------------------------------------ 3. what monitoring sees
-- An open window for request contexts without a ticket (1080) made the API "not ready" only; it now pages at once,
-- and so does a database server that no longer loads the guard (deploy/monitoring/alerts.yml).
CREATE OR REPLACE FUNCTION sys.security_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT 'masslak_context_unsigned_window_open', '{}'::jsonb,
         (EXISTS (SELECT 1 FROM sys.context_unsigned_window WHERE allowed_until > now()))::int::float8
  UNION ALL
  SELECT 'masslak_settings_guard_loaded', '{}'::jsonb, sys.guard_status()::int::float8
$$;
REVOKE ALL ON FUNCTION sys.security_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.security_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.security_metrics IS 'An open window for unsigned request contexts, and whether the settings guard is loaded (1084)';

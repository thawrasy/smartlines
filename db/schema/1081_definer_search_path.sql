-- =====================================================================
-- Masslak - 1081: functions that run as their owner search the session's temporary objects last
-- (reviews of October 2026: the assessment's addition 1, and M-09)
--
-- When pg_temp is not named in a function's search_path, PostgreSQL searches the session's temporary schema first,
-- before even pg_catalog. Nineteen SECURITY DEFINER functions set a path without it; one of them
-- (audit.tg_capture_change) reads pg_class by its bare name, so a temporary table of that name could have changed the
-- table an audit row names. 1080 withdrew temporary objects from the application; this file closes the path itself:
-- every SECURITY DEFINER function of the platform ends its search_path with pg_temp, and a check reports any new one
-- that does not (sys.definer_path_gaps, run by db/tests).
-- Creating objects in the public schema is withdrawn from every role explicitly (PostgreSQL 15 and later already do so
-- on a new cluster; a cluster upgraded from an older version would not).
-- =====================================================================

DO $$
DECLARE r record; path text;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS fn,
           (SELECT substring(c FROM 'search_path=(.*)') FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%') AS cur
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.prosecdef AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_%'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
  LOOP
    IF r.cur IS NULL THEN
      path := 'pg_catalog, pg_temp';
    ELSIF r.cur ~ '(^|,\s*)"?pg_temp"?\s*$' THEN
      CONTINUE;                                   -- already last
    ELSE
      path := regexp_replace(r.cur, '\s*,?\s*"?pg_temp"?\s*', '', 'g') || ', pg_temp';
    END IF;
    EXECUTE format('ALTER FUNCTION %s SET search_path = %s', r.fn, path);
  END LOOP;
  REVOKE CREATE ON SCHEMA public FROM PUBLIC;
END $$;

-- SECURITY DEFINER functions of the platform (extensions' own excepted) whose search_path does not end with pg_temp
CREATE OR REPLACE FUNCTION sys.definer_path_gaps() RETURNS TABLE (function_name text, search_path text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT p.oid::regprocedure::text,
         coalesce((SELECT substring(c FROM 'search_path=(.*)') FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'), '(none)')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE p.prosecdef AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_%'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
     AND NOT coalesce((SELECT c ~ '(=|,\s*)"?pg_temp"?\s*$' FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'), false)
$$;
REVOKE ALL ON FUNCTION sys.definer_path_gaps() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.definer_path_gaps() TO masslak_readonly, masslak_auditor;
COMMENT ON FUNCTION sys.definer_path_gaps IS 'SECURITY DEFINER functions whose search_path does not end with pg_temp; must be empty (1081)';

-- =====================================================================
-- 1135: no SECURITY DEFINER function is executable by PUBLIC (evaluation reports of October 2026, MANU; owner's
-- approval)
--   PostgreSQL grants EXECUTE on a new function to PUBLIC. Most schema files revoke it and grant named roles, but 132
--   SECURITY DEFINER functions kept the default: 97 trigger functions and 35 that can be called (row-level security
--   predicates, sys.set_context, sys.feature_on and others). It was not reachable: PUBLIC has no USAGE on their
--   schemas, so only the roles that use those schemas could call them. Defence in depth all the same:
--   * each such function is granted, by name, to every role that has USAGE on its schema (no role loses a call it
--     could make), and EXECUTE is revoked from PUBLIC;
--   * trigger and event trigger functions get no grant: PostgreSQL does not check EXECUTE when a trigger fires;
--   * db/tests (block 1135) fails on any SECURITY DEFINER function a later schema file leaves open to PUBLIC.
-- =====================================================================

DO $$
DECLARE f record; r record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig, n.oid AS nsp, p.prorettype IN ('trigger'::regtype, 'event_trigger'::regtype) AS is_trigger
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.prosecdef AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'public', 'gis')
       AND has_function_privilege('public', p.oid, 'EXECUTE')
  LOOP
    IF NOT f.is_trigger THEN
      FOR r IN SELECT rolname FROM pg_roles
                WHERE NOT rolsuper AND rolname NOT LIKE 'pg\_%' AND has_schema_privilege(oid, f.nsp, 'USAGE')
      LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', f.sig, r.rolname);
      END LOOP;
    END IF;
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', f.sig);
  END LOOP;
END $$;

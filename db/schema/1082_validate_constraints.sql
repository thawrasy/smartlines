-- =====================================================================
-- Masslak - 1082: constraints added NOT VALID are validated afterwards, and readiness names any that is not
-- (reviews of October 2026, H-09)
--
-- Schema files add a constraint NOT VALID so that applying them never scans a large table under a lock; until it is
-- validated, the rows that were there before it are not checked. Some files validated their own at once, others
-- (1046 for contact data, 1074, 1078) left them for later, and nothing made later happen: 1046's three constraints
-- stayed unchecked on a server where app.tools.seal_contacts had not run, and the upgrade only warned.
-- db/build.sh and db/upgrade.sh now end with CALL sys.validate_constraints(): every NOT VALID constraint of the
-- platform is validated, each in its own transaction (VALIDATE takes a SHARE UPDATE EXCLUSIVE lock, so reads and writes
-- go on). One whose old rows break it stays NOT VALID, is named in a warning, and /api/ready reports
-- "constraints": false until the rows are fixed and the next migration validates it.
-- =====================================================================

-- NOT VALID constraints of the platform's tables (extensions' own and partitions' copies excepted)
CREATE OR REPLACE FUNCTION sys.unvalidated_constraints() RETURNS TABLE (table_name text, constraint_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT c.conrelid::regclass::text, c.conname::text
    FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
   WHERE NOT c.convalidated AND c.conparentid = 0
     AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_%'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_constraint'::regclass AND d.objid = c.oid AND d.deptype = 'e')
   ORDER BY 1, 2
$$;
REVOKE ALL ON FUNCTION sys.unvalidated_constraints() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.unvalidated_constraints() TO masslak_app, masslak_readonly, masslak_auditor;
COMMENT ON FUNCTION sys.unvalidated_constraints IS 'Constraints still NOT VALID; must be empty for /api/ready (1082, H-09)';

-- Validates each NOT VALID constraint in a transaction of its own; one that existing rows break is reported and left.
-- No SET clause: a procedure that has one cannot commit, so every name is qualified instead.
CREATE OR REPLACE PROCEDURE sys.validate_constraints()
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT u.table_name, u.constraint_name FROM sys.unvalidated_constraints() u LOOP
    BEGIN
      EXECUTE pg_catalog.format('ALTER TABLE %s VALIDATE CONSTRAINT %I', r.table_name, r.constraint_name);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'constraint % on % stays NOT VALID: %', r.constraint_name, r.table_name, SQLERRM;
    END;
    COMMIT;
  END LOOP;
END $$;
REVOKE ALL ON PROCEDURE sys.validate_constraints() FROM PUBLIC;
COMMENT ON PROCEDURE sys.validate_constraints IS 'Validates every NOT VALID constraint, each in its own transaction; run by db/build.sh and db/upgrade.sh (1082, H-09)';

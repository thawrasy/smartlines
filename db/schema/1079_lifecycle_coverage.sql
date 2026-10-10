-- =====================================================================
-- 1079: every table belongs to a dataset with a lifecycle (review of release 1.47.0, R-04)
--   gov.data_inventory named 33 datasets with their purpose, retention, erasure and copies, but most of the ~500 tables
--   were in none of them, so a table holding personal or operational data could exist with no retention, no erasure
--   method and no legal hold. Now:
--   * a table is either a dataset of its own (a row in gov.data_inventory) or a member of one (gov.dataset_member);
--   * the tables not yet covered are grouped by schema and kind into datasets of their own: personal records (tables
--     with names, contacts, dates of birth or documents), records of a carrier or a customer, platform records, public
--     catalogs, system configuration and audit trails, each with a retention, an erasure method and the copies it lives
--     in;
--   * gov.lifecycle_gaps() lists any table in neither, and any table whose data is more sensitive than its dataset says;
--     the database checks (db/tests) require it to be empty, so a new table without a lifecycle fails CI;
--   * gov.v_table_lifecycle shows, for every table, the dataset, retention, erasure, copies and legal hold that apply.
-- =====================================================================
CREATE TABLE IF NOT EXISTS gov.dataset_member (
  table_name  text PRIMARY KEY,
  dataset     text NOT NULL REFERENCES gov.data_inventory(dataset),
  note        text,
  assigned_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS dataset_member_dataset_fkx ON gov.dataset_member (dataset);
COMMENT ON TABLE gov.dataset_member IS 'Which dataset (and so which retention, erasure and copies) a table belongs to (1079, R-04)';
SELECT sys.rls_platform('gov.dataset_member');
GRANT SELECT ON gov.dataset_member TO masslak_readonly, masslak_auditor;

-- the sensitivity of a table's data, from its class (sys.table_class) and its columns
CREATE OR REPLACE FUNCTION gov.table_sensitivity(p_table text) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE
    WHEN tc.data_class IN ('USER_PRIVATE', 'RESTRICTED_SECURITY') THEN 'RESTRICTED'
    WHEN EXISTS (SELECT 1 FROM information_schema.columns c
                  WHERE c.table_schema || '.' || c.table_name = p_table
                    AND c.column_name IN ('full_name', 'first_name', 'mobile', 'mobile_enc', 'email', 'birth_date',
                                          'id_no', 'id_no_enc', 'doc_no_enc', 'national_id', 'iban_enc', 'address_line'))
         AND tc.data_class NOT IN ('PUBLIC_CATALOG', 'SYSTEM') THEN 'RESTRICTED'
    WHEN tc.data_class IN ('TENANT_PRIVATE', 'PLATFORM_CONFIDENTIAL', 'APPEND_ONLY_AUDIT') THEN 'CONFIDENTIAL'
    WHEN tc.data_class = 'SYSTEM' THEN 'INTERNAL'
    ELSE 'PUBLIC' END
    FROM sys.table_class tc WHERE tc.table_name = p_table
$$;
COMMENT ON FUNCTION gov.table_sensitivity IS 'RESTRICTED, CONFIDENTIAL, INTERNAL or PUBLIC for a table, from its class and its columns (1079)';

-- the tables not covered yet join a dataset of their schema and sensitivity; this runs once, here: from now on a new
-- table is given its dataset by the file that creates it (gov.lifecycle_gaps() fails CI otherwise)
DO $$
DECLARE r record; ds text; schema_purpose text;
BEGIN
  FOR r IN SELECT tc.table_name, split_part(tc.table_name, '.', 1) AS sch, gov.table_sensitivity(tc.table_name) AS sens
             FROM sys.table_class tc
            WHERE NOT EXISTS (SELECT 1 FROM gov.data_inventory d WHERE d.dataset = tc.table_name)
              AND NOT EXISTS (SELECT 1 FROM gov.dataset_member m WHERE m.table_name = tc.table_name)
            ORDER BY 1 LOOP
    ds := r.sch || ' ' || CASE r.sens WHEN 'RESTRICTED' THEN 'personal records' WHEN 'CONFIDENTIAL' THEN 'records'
                                       WHEN 'INTERNAL' THEN 'configuration' ELSE 'catalog' END;
    schema_purpose := CASE r.sch
      WHEN 'acct' THEN 'accounting' WHEN 'audit' THEN 'audit trail' WHEN 'bill' THEN 'carrier billing' WHEN 'brd' THEN 'border manifests'
      WHEN 'crm' THEN 'customer relations' WHEN 'ctr' THEN 'contracted transport' WHEN 'fin' THEN 'payments and ledger'
      WHEN 'fleet' THEN 'fleet' WHEN 'frt' THEN 'freight' WHEN 'gis' THEN 'maps' WHEN 'gov' THEN 'data governance'
      WHEN 'iam' THEN 'identity and access' WHEN 'net' THEN 'network and stations' WHEN 'ops' THEN 'trip operations'
      WHEN 'pricing' THEN 'pricing and loyalty' WHEN 'ptn' THEN 'service partners' WHEN 'rail' THEN 'rail' WHEN 'ref' THEN 'reference data'
      WHEN 'rent' THEN 'car rental' WHEN 'rpt' THEN 'reports' WHEN 'sales' THEN 'sales and tickets' WHEN 'sch' THEN 'school transport'
      WHEN 'sec' THEN 'security and authorities' WHEN 'ship' THEN 'shipping' WHEN 'sys' THEN 'platform system' WHEN 'taxi' THEN 'taxi'
      ELSE r.sch END;
    INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies,
                                    backup_retention_days)
    VALUES (ds, r.sens, r.sch,
            initcap(schema_purpose) || ': ' || CASE r.sens WHEN 'RESTRICTED' THEN 'records naming or identifying people'
              WHEN 'CONFIDENTIAL' THEN 'records of carriers, customers and the platform' WHEN 'INTERNAL' THEN 'settings and upkeep of the platform'
              ELSE 'published lists everyone may read' END,
            CASE WHEN r.sch IN ('fin', 'acct', 'audit', 'bill') THEN 'Legal obligation'
                 WHEN r.sens = 'PUBLIC' THEN 'Legitimate interest' WHEN r.sch IN ('sec', 'gov') THEN 'Legal obligation' ELSE 'Contract' END,
            CASE WHEN r.sch IN ('fin', 'acct', 'audit', 'bill') THEN 3650
                 WHEN r.sens = 'RESTRICTED' THEN 1825 WHEN r.sens = 'CONFIDENTIAL' THEN 2555 ELSE 3650 END,   -- catalogs: while in use
            CASE WHEN r.sch IN ('fin', 'acct', 'audit', 'bill') THEN 'KEEP_LEGAL' WHEN r.sens = 'RESTRICTED' THEN 'PSEUDONYMISE'
                 ELSE 'KEEP_LEGAL' END,
            '{replica,backup,offsite}', 35)
    ON CONFLICT (dataset) DO NOTHING;
    INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES (r.table_name, ds, 'grouped by schema and sensitivity (1079)')
    ON CONFLICT (table_name) DO NOTHING;
  END LOOP;
END $$;

-- a table outside every dataset, or more sensitive than the dataset it is in
CREATE OR REPLACE FUNCTION gov.lifecycle_gaps() RETURNS TABLE (table_name text, problem text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH t AS (
    SELECT n.nspname || '.' || c.relname AS tn FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
       AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'public') AND n.nspname NOT LIKE 'pg\_%'),
  rank AS (SELECT * FROM (VALUES ('PUBLIC', 0), ('INTERNAL', 1), ('CONFIDENTIAL', 2), ('RESTRICTED', 3)) v(cls, r))
  SELECT t.tn, 'no dataset: add it to gov.data_inventory or gov.dataset_member'
    FROM t WHERE NOT EXISTS (SELECT 1 FROM gov.data_inventory d WHERE d.dataset = t.tn)
             AND NOT EXISTS (SELECT 1 FROM gov.dataset_member m WHERE m.table_name = t.tn)
  UNION ALL
  SELECT m.table_name, format('holds %s data but its dataset "%s" is %s', s.cls, d.dataset, d.data_class)
    FROM gov.dataset_member m JOIN gov.data_inventory d ON d.dataset = m.dataset
    CROSS JOIN LATERAL (SELECT gov.table_sensitivity(m.table_name) AS cls) s
    JOIN rank rs ON rs.cls = s.cls JOIN rank rd ON rd.cls = d.data_class
   WHERE rs.r > rd.r
  UNION ALL
  SELECT m.table_name, 'member of a dataset but no longer a table' FROM gov.dataset_member m
   WHERE to_regclass(m.table_name) IS NULL
$$;
REVOKE ALL ON FUNCTION gov.lifecycle_gaps() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gov.lifecycle_gaps() TO masslak_readonly, masslak_auditor;
COMMENT ON FUNCTION gov.lifecycle_gaps IS 'Tables without a lifecycle, or more sensitive than their dataset; must be empty (1079, R-04)';

CREATE OR REPLACE VIEW gov.v_table_lifecycle WITH (security_barrier) AS
  SELECT tc.table_name, coalesce(d_own.dataset, d_mem.dataset) AS dataset,
         gov.table_sensitivity(tc.table_name) AS sensitivity, coalesce(d_own.data_class, d_mem.data_class) AS dataset_class,
         coalesce(d_own.retention_days, d_mem.retention_days) AS retention_days,
         coalesce(d_own.erasure_method, d_mem.erasure_method) AS erasure_method,
         coalesce(d_own.copies, d_mem.copies) AS copies,
         coalesce(d_own.backup_retention_days, d_mem.backup_retention_days) AS backup_retention_days,
         EXISTS (SELECT 1 FROM gov.legal_hold h WHERE h.released_at IS NULL AND h.scope_type = 'DATASET'
                    AND h.dataset IN (d_own.dataset, d_mem.dataset)) AS on_legal_hold
    FROM sys.table_class tc
    LEFT JOIN gov.data_inventory d_own ON d_own.dataset = tc.table_name
    LEFT JOIN gov.dataset_member m ON m.table_name = tc.table_name
    LEFT JOIN gov.data_inventory d_mem ON d_mem.dataset = m.dataset;
COMMENT ON VIEW gov.v_table_lifecycle IS 'Every table with the dataset, retention, erasure, copies and legal hold that apply to it (1079)';
GRANT SELECT ON gov.v_table_lifecycle TO masslak_readonly, masslak_auditor;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('gov.dataset_member', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note)
SELECT 'gov.dataset_member', dataset, 'the lifecycle map itself (1079)' FROM gov.data_inventory WHERE dataset = 'gov configuration'
ON CONFLICT (table_name) DO NOTHING;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days)
SELECT 'gov.dataset_member', 'INTERNAL', 'gov', 'Which dataset each table belongs to', 'Legal obligation', 3650, 'KEEP_LEGAL',
       '{replica,backup,offsite}', 35
 WHERE NOT EXISTS (SELECT 1 FROM gov.dataset_member WHERE table_name = 'gov.dataset_member')
ON CONFLICT (dataset) DO NOTHING;
-- the record of applied schema files is created by db/build.sh and db/upgrade.sh themselves, after the files run
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days)
VALUES ('sys.schema_file', 'INTERNAL', 'sys', 'Which schema files the database has applied, with their hashes', 'Legal obligation', 3650,
        'KEEP_LEGAL', '{replica,backup,offsite}', 35)
ON CONFLICT (dataset) DO NOTHING;

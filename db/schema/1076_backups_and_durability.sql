-- =====================================================================
-- 1076: backups that leave the server, durability the owner chooses (review of release 1.47.0, package D)
-- =====================================================================
-- a. Every nightly backup records its local copy and its off-site copy (deploy/backup.sh, R-41): the monitoring
--    alerts when either is older than a day, so a backup that stays on the server it protects is seen.
-- b. Zero data loss is a setting (owner's decision 1, R-39): MASSLAK_ZERO_DATA_LOSS=on makes a standby confirm every
--    commit (deploy/durability.sh applies it to PostgreSQL or to Patroni). The database reports whether commits wait
--    for a standby now, and whether one is confirming, so a setting that is on but not in force pages someone.
-- c. The security console's connections are capped by their role, so the primary's connection count no longer grows
--    with the number of API servers (R-46).

-- ------------------------------------------------------------------ a. backup runs
CREATE TABLE IF NOT EXISTS sys.backup_run (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  copy        text NOT NULL CHECK (copy IN ('LOCAL','OFFSITE')),
  ok          boolean NOT NULL,
  detail      text CHECK (detail IS NULL OR length(detail) <= 500),
  bytes       bigint CHECK (bytes IS NULL OR bytes >= 0),
  at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS backup_run_copy_idx ON sys.backup_run (copy, at DESC);
COMMENT ON TABLE sys.backup_run IS 'Each nightly backup''s local and off-site copy, with its outcome (1076, R-41)';
ALTER TABLE sys.backup_run ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS platform_only ON sys.backup_run;
CREATE POLICY platform_only ON sys.backup_run USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
GRANT SELECT ON sys.backup_run TO masslak_readonly, masslak_auditor;

-- called by deploy/backup.sh through psql as the database owner
CREATE OR REPLACE FUNCTION sys.record_backup(p_copy text, p_ok boolean, p_detail text, p_bytes bigint DEFAULT NULL)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  INSERT INTO sys.backup_run (copy, ok, detail, bytes) VALUES (upper(p_copy), p_ok, left(p_detail, 500), p_bytes)
$$;
REVOKE ALL ON FUNCTION sys.record_backup(text, boolean, text, bigint) FROM PUBLIC;
COMMENT ON FUNCTION sys.record_backup IS 'Records one copy of a nightly backup (deploy/backup.sh, 1076)';

-- ------------------------------------------------------------------ b, a. metrics
CREATE OR REPLACE FUNCTION sys.durability_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  -- seconds since the last good copy; a server that never wrote one counts from its installation
  SELECT 'masslak_backup_last_success_age_seconds', jsonb_build_object('copy', lower(c.copy)),
         extract(epoch FROM now() - coalesce(
           (SELECT max(b.at) FROM sys.backup_run b WHERE b.copy = c.copy AND b.ok),
           (SELECT min(m.applied_at) FROM sys.schema_migration m), now()))::float8
    FROM (VALUES ('LOCAL'), ('OFFSITE')) AS c(copy)
  UNION ALL
  SELECT 'masslak_backup_last_failed', jsonb_build_object('copy', lower(c.copy)),
         coalesce((SELECT (NOT b.ok)::int FROM sys.backup_run b WHERE b.copy = c.copy ORDER BY b.at DESC LIMIT 1), 0)::float8
    FROM (VALUES ('LOCAL'), ('OFFSITE')) AS c(copy)
  UNION ALL
  -- commits wait for a standby: a standby is named and commits are not local-only
  SELECT 'masslak_db_commits_wait_for_standby', '{}'::jsonb,
         (current_setting('synchronous_standby_names') <> ''
          AND current_setting('synchronous_commit') IN ('on', 'remote_apply', 'remote_write'))::int::float8
   WHERE NOT pg_is_in_recovery()
$$;
REVOKE ALL ON FUNCTION sys.durability_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.durability_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.durability_metrics IS 'Age of the last local and off-site backups, and whether commits wait for a standby (1076)';

-- ------------------------------------------------------------------ c. the security console's connections
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_audit') THEN
    ALTER ROLE masslak_audit CONNECTION LIMIT 20;
  END IF;
END $$;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sys.backup_run', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

SELECT sys.refresh_table_class();

-- =====================================================================
-- 1065: automatic failover and the second site (expert review of October 2026, stage D6)
--   Patroni keeps one primary and promotes a standby when it fails (deploy/ha); the API reaches whichever server is
--   primary through a list of hosts and target_session_attrs=read-write, or through HAProxy. This file adds what the
--   database itself contributes: figures on the standbys that can take over (alert NoFailoverCandidate) and a table
--   the failover drill writes to (db/tools/failover_drill.py), so drills never need a schema change on the server.
-- =====================================================================

CREATE TABLE IF NOT EXISTS sys.failover_probe (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  drill      uuid NOT NULL,
  seq        integer NOT NULL,
  written_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
COMMENT ON TABLE sys.failover_probe IS 'Rows written by a failover drill, to count what the new primary kept (1065)';
CREATE INDEX IF NOT EXISTS failover_probe_drill_idx ON sys.failover_probe (drill, seq);
ALTER TABLE sys.failover_probe ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS platform_only ON sys.failover_probe;
CREATE POLICY platform_only ON sys.failover_probe USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sys.failover_probe', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

-- The servers that could take over: standbys streaming from this one, and those confirming commits synchronously
-- (with Patroni's synchronous mode a failover loses no committed transaction).
CREATE OR REPLACE FUNCTION sys.ha_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT 'masslak_db_in_recovery', '{}'::jsonb, pg_is_in_recovery()::int::float8
  UNION ALL
  SELECT 'masslak_db_standbys', jsonb_build_object('sync', s.sync), count(r.pid)::float8
    FROM (VALUES ('async'), ('sync')) AS s(sync)
    LEFT JOIN pg_stat_replication r ON r.state = 'streaming'
         AND CASE WHEN r.sync_state IN ('sync', 'quorum') THEN 'sync' ELSE 'async' END = s.sync
   WHERE NOT pg_is_in_recovery()
   GROUP BY s.sync
$$;
REVOKE ALL ON FUNCTION sys.ha_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.ha_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.ha_metrics IS 'Standbys able to take over, and whether this server is a standby (1065)';

INSERT INTO sys.schema_migration (version, description)
SELECT '1.44.0', 'Expert review stage D6: failover drill probe and standby figures for automatic failover and the second site'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.44.0');

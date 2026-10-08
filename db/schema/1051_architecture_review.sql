-- =====================================================================
-- 1051: actions after the architecture review of design 3.9 (docs/database/ARCHITECTURE_REVIEW_RESPONSE.md)
--   A  The positions table described itself as partitioned monthly; it has been daily since 1048. The design document
--      copies table comments, so the stale text reached the reviewers. Corrected, and a check keeps comments on
--      partitioned tables in step with their partitions.
--   B  Capacity metrics: row and size estimates of the growing tables, the outbox purge backlog, the point at which the
--      outbox should be partitioned (setting capacity.outbox_partition_rows), and the time spent in database functions
--      and triggers when track_functions is on (staging), so the cost of triggers is measured, not assumed.
-- =====================================================================

-- =====================================================================
-- A  positions: the comment says what the table is
-- =====================================================================
COMMENT ON TABLE ops.geo_event IS
  'Tracking positions; daily partitions created ahead by sys.ensure_daily_partitions and dropped whole after the retention of the lifecycle matrix (7 days, T3-10); no foreign keys on the hot insert path';

-- =====================================================================
-- B  capacity and cost metrics
-- =====================================================================
INSERT INTO sys.setting (key, value, description) VALUES
  ('capacity.outbox_partition_rows', '20000000',
   'Rows in sys.outbox_event above which the outbox is partitioned by day (purge by dropping partitions); alert OutboxPartitioningDue')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION sys.capacity_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE outbox_rows float8;
        outbox_days int := coalesce((SELECT di.retention_days FROM gov.data_inventory di WHERE di.dataset = 'sys.outbox_event'), 30);
BEGIN
  -- estimated rows and bytes of the tables that grow with traffic (a partitioned table counts its partitions)
  RETURN QUERY
  WITH t(name) AS (VALUES ('sales.booking'), ('sales.ticket'), ('fin.ledger_txn'), ('fin.ledger_entry'), ('sys.outbox_event'),
                          ('sys.webhook_delivery'), ('ops.geo_event'), ('audit.row_change'), ('audit.activity_log'),
                          ('audit.data_access_log'), ('audit.auth_event')),
  rel AS (SELECT t.name, c.oid FROM t JOIN pg_class c ON c.oid = to_regclass(t.name)),
  parts AS (SELECT rel.name, coalesce(i.inhrelid, rel.oid) AS oid FROM rel LEFT JOIN pg_inherits i ON i.inhparent = rel.oid)
  SELECT m.metric, jsonb_build_object('table', p.name), m.v
    FROM (SELECT name, sum(greatest(c.reltuples, 0))::float8 AS r, sum(pg_total_relation_size(c.oid))::float8 AS b
            FROM parts JOIN pg_class c ON c.oid = parts.oid GROUP BY name) p
   CROSS JOIN LATERAL (VALUES ('masslak_table_rows_estimate'::text, p.r), ('masslak_table_bytes', p.b)) m(metric, v);

  -- the outbox: published events past their retention that the purge has not removed yet, and the partitioning point
  RETURN QUERY SELECT 'masslak_outbox_purge_backlog'::text, '{}'::jsonb, count(*)::float8 FROM sys.outbox_event
                WHERE status = 'PUBLISHED' AND published_at < now() - make_interval(days => outbox_days + 1);
  outbox_rows := greatest((SELECT reltuples FROM pg_class WHERE oid = 'sys.outbox_event'::regclass), 0);
  RETURN QUERY SELECT 'masslak_outbox_partitioning_due'::text, '{}'::jsonb,
                      CASE WHEN outbox_rows > coalesce((SELECT st.value::float8 FROM sys.setting st WHERE st.key = 'capacity.outbox_partition_rows'), 2e7)
                           THEN 1 ELSE 0 END::float8;

  -- time spent in database functions, triggers included (needs track_functions = pl; empty otherwise): the 25 costliest
  RETURN QUERY
  SELECT m.metric, jsonb_build_object('function', f.schemaname || '.' || f.funcname), m.v
    FROM (SELECT * FROM pg_stat_user_functions ORDER BY total_time DESC LIMIT 25) f
   CROSS JOIN LATERAL (VALUES ('masslak_db_function_calls_total'::text, f.calls::float8),
                              ('masslak_db_function_seconds_total', f.total_time / 1000.0),
                              ('masslak_db_function_self_seconds_total', f.self_time / 1000.0)) m(metric, v);
  RETURN QUERY SELECT 'masslak_db_track_functions'::text, '{}'::jsonb,
                      CASE current_setting('track_functions') WHEN 'none' THEN 0 ELSE 1 END::float8;
END $$;
REVOKE ALL ON FUNCTION sys.capacity_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.capacity_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.capacity_metrics IS 'Growth and cost metrics for the monitoring scrape: table sizes, outbox purge and partitioning point, time in functions and triggers (architecture review, October 2026)';

INSERT INTO sys.schema_migration (version, description)
SELECT '1.33.0', 'Architecture review: positions comment corrected; capacity metrics (table growth, outbox partitioning point, trigger cost)'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.33.0');

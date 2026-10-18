-- =====================================================================
-- 1133: the outbox's review point (systems review of study 3.8, October 2026, R-12)
--   1051 set a partitioning point for the outbox (capacity.outbox_partition_rows, 20 million rows) and the alert
--   OutboxPartitioningDue. 1053 then partitioned the outbox by day, and the metric behind the alert has read 0 since:
--   it took the row estimate of the outbox's own table, which a partitioned table does not have.
--   * The metric now sums the outbox's daily partitions (masslak_outbox_rows_estimate).
--   * The point becomes a review point, lowered to 8 million rows as the review proposed and the owner approved
--     (capacity.outbox_review_rows): past it, the outbox holds more events than the volume the platform is sized for
--     today, or finished days are not being dropped; the retention and the capacity are reviewed (alert
--     OutboxReviewDue, RUNBOOKS.md section 10). At the full design volume the owner raises it with the capacity model.
-- =====================================================================

DELETE FROM sys.setting WHERE key = 'capacity.outbox_partition_rows';
INSERT INTO sys.setting (key, value, description) VALUES
  ('capacity.outbox_review_rows', '8000000'::jsonb,
   'Rows in sys.outbox_event, over all its daily partitions, above which its retention and capacity are reviewed; alert OutboxReviewDue (1133)')
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
  -- the outbox's rows over all its daily partitions (the parent of a partitioned table has no estimate of its own), and
  -- whether they passed the review point
  outbox_rows := (SELECT coalesce(sum(greatest(c.reltuples, 0)), 0) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
                   WHERE i.inhparent = 'sys.outbox_event'::regclass);
  RETURN QUERY SELECT 'masslak_outbox_rows_estimate'::text, '{}'::jsonb, outbox_rows;
  RETURN QUERY SELECT 'masslak_outbox_review_due'::text, '{}'::jsonb,
                      CASE WHEN outbox_rows > coalesce((SELECT (st.value #>> '{}')::float8 FROM sys.setting st
                                                         WHERE st.key = 'capacity.outbox_review_rows'), 8e6)
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

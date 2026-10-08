-- =====================================================================
-- 1060: finer monitoring (expert review of October 2026, stage C7)
--   masslak_db_lock_waiters counted every waiting session in one figure. sys.lock_metrics() names the table each
--   wait is on (a row lock is counted on the table of its row) and how long the longest one has waited, so an alert
--   points at the hot table. sys.partition_metrics() shows, for every partitioned table, how far ahead its partitions
--   go and whether rows fell into its default partition (a missing partition), not only for vehicle positions.
-- =====================================================================

-- Sessions waiting for a lock now, per table, and the longest wait in seconds. A session waiting for a row first takes
-- the row's tuple lock and then waits on the transaction holding it, so its table comes from that tuple lock; a wait
-- with no table (another transaction's insert of the same key) is reported as "(transaction)".
CREATE OR REPLACE FUNCTION sys.lock_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH waiting AS (
    SELECT coalesce(l.relation, (SELECT t.relation FROM pg_locks t
                                  WHERE t.pid = l.pid AND t.granted AND t.locktype = 'tuple' LIMIT 1)) AS rel,
           l.waitstart
      FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
     WHERE NOT l.granted AND a.datname = current_database()
  ), named AS (
    SELECT CASE WHEN rel IS NULL THEN '(transaction)'
                ELSE coalesce(pg_partition_root(rel), rel)::regclass::text END AS tbl, waitstart
      FROM waiting
  )
  SELECT x.metric, jsonb_build_object('table', n.tbl), x.value
    FROM (SELECT tbl, count(*)::float8 AS waiting,
                 coalesce(max(extract(epoch FROM clock_timestamp() - waitstart)), 0)::float8 AS longest
            FROM named GROUP BY tbl) n,
         LATERAL (VALUES ('masslak_lock_waiting'::text, n.waiting), ('masslak_lock_wait_seconds_max', n.longest)) AS x(metric, value)
$$;
REVOKE ALL ON FUNCTION sys.lock_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.lock_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.lock_metrics IS 'Lock waits per table and the longest wait, for the monitoring scrape (review stage C7, 1060)';

-- For each partitioned table: its partitions, how far ahead of now the last one ends (daily tables keep 7 days ahead,
-- monthly ones 3 months, sys.run_maintenance_body), and the rows in its default partition (counted up to 10,000).
CREATE OR REPLACE FUNCTION sys.partition_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p record; ahead float8; parts int; def regclass; def_rows bigint; period text;
BEGIN
  FOR p IN SELECT c.oid, c.oid::regclass::text AS name FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'p' AND NOT c.relispartition AND n.nspname NOT LIKE 'pg\_%' ORDER BY 2 LOOP
    SELECT count(*), max(extract(epoch FROM substring(pg_get_expr(k.relpartbound, k.oid) FROM 'TO \(''([^'']+)''\)')::timestamptz - now())),
           (array_agg(k.oid::regclass) FILTER (WHERE pg_get_expr(k.relpartbound, k.oid) = 'DEFAULT'))[1]
      INTO parts, ahead, def
      FROM pg_inherits i JOIN pg_class k ON k.oid = i.inhrelid WHERE i.inhparent = p.oid;
    period := CASE WHEN p.name IN ('ops.geo_event', 'sys.outbox_event') THEN 'day' ELSE 'month' END;
    def_rows := 0;
    IF def IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM (SELECT 1 FROM %s LIMIT 10000) s', def) INTO def_rows;
    END IF;
    metric := 'masslak_partitions'; labels := jsonb_build_object('table', p.name); value := parts; RETURN NEXT;
    metric := 'masslak_partition_ahead_seconds'; labels := jsonb_build_object('table', p.name, 'period', period);
    value := coalesce(ahead, 0); RETURN NEXT;
    metric := 'masslak_partition_default_rows'; labels := jsonb_build_object('table', p.name); value := def_rows; RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION sys.partition_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.partition_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.partition_metrics IS 'Partitions per partitioned table, how far ahead they go and rows in the default partition, for the monitoring scrape (review stage C7, 1060)';

INSERT INTO sys.schema_migration (version, description)
SELECT '1.39.2', 'Expert review stage C: lock waits per table and partition horizon in the monitoring scrape'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.39.2');

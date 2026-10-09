-- =====================================================================
-- 1077: statement statistics (review of release 1.47.0, report 3, sections 4.1 and 7.2)
--   pg_stat_statements groups the statements the server ran by their normalised text, with every constant replaced by
--   a placeholder, and counts calls, time, rows and blocks read for each. Indexes and rewrites are then chosen from
--   measurements: the statements that cost most in total, the slowest on average, the most frequent and the ones
--   reading most from disk.
--   The extension collects only when the server preloads it (shared_preload_libraries in docker-compose.yml,
--   deploy/postgres/replica.sh, deploy/staging and deploy/ha/patroni.yml). Where it is missing or not preloaded nothing
--   here fails: sys.top_statements() answers no rows and masslak_db_statement_stats_enabled reads 0.
--   Statement texts never carry bind values (placeholders only); utility statements are not tracked
--   (pg_stat_statements.track_utility=off); any literal left in a text is masked and texts are cut at 500 characters.
--   Only the platform security console and the read-only reports role can call sys.top_statements().
-- =====================================================================
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_stat_statements') THEN
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;
    REVOKE ALL ON public.pg_stat_statements, public.pg_stat_statements_info FROM PUBLIC;
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  -- a managed server where the owner may not create it: an administrator creates it once, the functions below adapt
  RAISE NOTICE 'pg_stat_statements was not created (%); statement statistics stay off', SQLERRM;
END $$;

-- whether statistics are being collected now: the extension exists and the server preloaded it
CREATE OR REPLACE FUNCTION sys.statement_stats_enabled() RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF to_regclass('public.pg_stat_statements') IS NULL THEN
    RETURN false;
  END IF;
  PERFORM 1 FROM public.pg_stat_statements(false) LIMIT 1;
  RETURN true;
EXCEPTION WHEN object_not_in_prerequisite_state OR undefined_function OR insufficient_privilege THEN
  RETURN false;
END $$;
REVOKE ALL ON FUNCTION sys.statement_stats_enabled() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.statement_stats_enabled() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.statement_stats_enabled IS 'True when pg_stat_statements exists and the server preloads it (1077)';

-- The statements of this database ordered by total time, mean time, calls or blocks read from disk.
-- p_order: TOTAL (default), MEAN, CALLS or READS; p_limit 1..100; p_min_calls leaves out statements run only a few times.
CREATE OR REPLACE FUNCTION sys.top_statements(p_order text DEFAULT 'TOTAL', p_limit int DEFAULT 20, p_min_calls bigint DEFAULT 1)
RETURNS TABLE (queryid bigint, role_name text, calls bigint, total_ms double precision, mean_ms double precision,
               max_ms double precision, rows bigint, shared_blks_hit bigint, shared_blks_read bigint,
               temp_blks_written bigint, wal_bytes numeric, hit_ratio double precision, query text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_order text := CASE upper(coalesce(p_order, 'TOTAL'))
                    WHEN 'TOTAL' THEN 's.total_exec_time' WHEN 'MEAN' THEN 's.mean_exec_time'
                    WHEN 'CALLS' THEN 's.calls' WHEN 'READS' THEN 's.shared_blks_read' END;
BEGIN
  IF v_order IS NULL THEN
    RAISE EXCEPTION 'STATEMENT_ORDER: order by TOTAL, MEAN, CALLS or READS' USING ERRCODE = '22023';
  END IF;
  IF NOT sys.statement_stats_enabled() THEN
    RETURN;
  END IF;
  RETURN QUERY EXECUTE format(
    $q$SELECT s.queryid, r.rolname::text, s.calls, s.total_exec_time, s.mean_exec_time, s.max_exec_time, s.rows,
              s.shared_blks_hit, s.shared_blks_read, s.temp_blks_written, s.wal_bytes,
              CASE WHEN s.shared_blks_hit + s.shared_blks_read > 0
                   THEN s.shared_blks_hit::float8 / (s.shared_blks_hit + s.shared_blks_read) END,
              left(regexp_replace(s.query, '''(?:[^'']|'''')*''', '''?''', 'g'), 500)
         FROM public.pg_stat_statements(true) s
         LEFT JOIN pg_roles r ON r.oid = s.userid
        WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
          AND s.toplevel AND s.calls >= $1
        ORDER BY %s DESC NULLS LAST
        LIMIT $2$q$, v_order)
  USING greatest(coalesce(p_min_calls, 1), 1), least(greatest(coalesce(p_limit, 20), 1), 100);
END $$;
REVOKE ALL ON FUNCTION sys.top_statements(text, int, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.top_statements(text, int, bigint) TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.top_statements IS
  'Statements of this database by total or mean time, calls or disk reads; literals masked, no bind values (1077)';

-- Metrics without a label per statement: whether statistics run, how many statements are tracked, how many were
-- evicted for lack of room (pg_stat_statements.max too low) and the slowest mean among frequent statements.
CREATE OR REPLACE FUNCTION sys.statement_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_on boolean := sys.statement_stats_enabled();
BEGIN
  metric := 'masslak_db_statement_stats_enabled'; labels := '{}'; value := v_on::int;
  RETURN NEXT;
  IF NOT v_on THEN
    RETURN;
  END IF;
  RETURN QUERY EXECUTE
    $q$SELECT 'masslak_db_statements_tracked', '{}'::jsonb, count(*)::float8
         FROM public.pg_stat_statements(false) s WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
       UNION ALL
       SELECT 'masslak_db_statement_evictions_total', '{}'::jsonb, i.dealloc::float8 FROM public.pg_stat_statements_info i
       UNION ALL
       SELECT 'masslak_db_statement_slowest_mean_seconds', '{}'::jsonb, coalesce(max(s.mean_exec_time), 0) / 1000.0
         FROM public.pg_stat_statements(false) s
        WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database()) AND s.toplevel AND s.calls >= 100$q$;
END $$;
REVOKE ALL ON FUNCTION sys.statement_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.statement_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.statement_metrics IS 'Statement statistics for /api/metrics without a label per statement (1077)';

-- Starting a fresh measurement window (after an index change, to compare before and after): the security console only
CREATE OR REPLACE FUNCTION sys.reset_statement_stats() RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.statement_stats_enabled() THEN
    RETURN false;
  END IF;
  EXECUTE 'SELECT public.pg_stat_statements_reset()';
  RETURN true;
EXCEPTION WHEN insufficient_privilege THEN
  RETURN false;                         -- the owner may not reset on this server (GRANT pg_stat_statements_reset to it)
END $$;
REVOKE ALL ON FUNCTION sys.reset_statement_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.reset_statement_stats() TO masslak_app;
COMMENT ON FUNCTION sys.reset_statement_stats IS 'Clears the statement statistics to start a new measurement window (1077)';

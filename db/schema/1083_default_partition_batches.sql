-- =====================================================================
-- Masslak - 1083: a late upkeep moves large periods out of the default partition one period per transaction
-- (reviews of October 2026, M-08)
--
-- When the daily upkeep stops for a while, rows of the days (months, id ranges) without a partition wait in the
-- table's default partition, and the next upkeep moves them (sys.create_partition, 1070). It moved every late period
-- inside the one transaction of sys.run_maintenance: the table's lock was held while all of them were copied, and with
-- a large backlog the upkeep ran into the application role's 30 s statement timeout and failed as a whole, every day,
-- ledger close and wallet reconciliation included.
--
-- Now the daily upkeep moves a period itself only while it is small (partitions.inline_move_rows, 50,000 rows). A
-- larger period is left where it is, still readable through its table, and sys.move_default_period() moves it: one
-- period per call, which the worker makes in a transaction of its own, with a longer statement timeout and a bounded
-- wait for the lock (10 s), until the default partitions are empty. Writers of the table wait for one period at a
-- time, never for the whole backlog.
--
-- Measured on a development server (4 vCPU, 16 GB, PostgreSQL 16), one day of outbox events per period: 200,000 rows
-- moved in 1.8 s, 1,000,000 rows in 5.9 s. The 50,000 rows the upkeep may move itself take about half a second.
-- Before, a stop of five such days held the outbox's lock for about 30 s in one transaction and hit the timeout.
-- =====================================================================

INSERT INTO sys.setting (key, value, description) VALUES
  ('partitions.inline_move_rows', '50000'::jsonb,
   'Rows of one late period the daily upkeep moves out of a default partition itself; larger periods are moved one per transaction by sys.move_default_period (1083, M-08)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION sys.partition_inline_limit() RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT greatest(coalesce((SELECT (value #>> '{}')::bigint FROM sys.setting WHERE key = 'partitions.inline_move_rows'), 50000), 0)
$$;
REVOKE EXECUTE ON FUNCTION sys.partition_inline_limit() FROM PUBLIC;
COMMENT ON FUNCTION sys.partition_inline_limit() IS 'The setting partitions.inline_move_rows (1083, M-08)';

-- The partition of a period, unless more than p_inline_max of its rows wait in the default partition: then nothing
-- is changed, -1 is returned, and the period is left to sys.move_default_period.
CREATE OR REPLACE FUNCTION sys.create_partition(p_parent text, p_part text, p_from text, p_to text, p_inline_max bigint)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE def regclass; key text; waiting bigint;
BEGIN
  IF p_inline_max IS NOT NULL THEN
    SELECT k.oid::regclass INTO def FROM pg_inherits i JOIN pg_class k ON k.oid = i.inhrelid
     WHERE i.inhparent = p_parent::regclass AND pg_get_expr(k.relpartbound, k.oid) = 'DEFAULT';
    IF def IS NOT NULL THEN
      SELECT a.attname INTO key FROM pg_partitioned_table pt
        JOIN pg_attribute a ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
       WHERE pt.partrelid = p_parent::regclass;
      -- counts no further than the limit: a large default partition is not read through to decide
      EXECUTE format('SELECT count(*) FROM (SELECT 1 FROM %s WHERE %I >= %L AND %I < %L LIMIT %s) s',
                     def, key, p_from, key, p_to, p_inline_max + 1) INTO waiting;
      IF waiting > p_inline_max THEN
        RAISE NOTICE 'partition % left for sys.move_default_period: more than % of its rows wait in %',
                     p_part, p_inline_max, def;
        RETURN -1;
      END IF;
    END IF;
  END IF;
  RETURN sys.create_partition(p_parent, p_part, p_from, p_to);
END $$;
REVOKE EXECUTE ON FUNCTION sys.create_partition(text, text, text, text, bigint) FROM PUBLIC;
COMMENT ON FUNCTION sys.create_partition(text, text, text, text, bigint) IS
  'Creates a range partition and moves its rows out of the default partition, unless more than p_inline_max wait there: then -1 and nothing changed (1083, M-08)';

-- The three upkeep functions of 1070 and 1075, creating partitions through the limited form above
CREATE OR REPLACE FUNCTION sys.ensure_daily_partitions(p_parent text, p_days_ahead integer DEFAULT 7, p_days_back integer DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE d date; part text; sch text := split_part(p_parent, '.', 1); tbl text := split_part(p_parent, '.', 2);
        start date := current_date - p_days_back; oldest timestamptz := sys.default_partition_oldest(p_parent);
        lim bigint := sys.partition_inline_limit();
BEGIN
  IF oldest IS NOT NULL AND oldest::date < start THEN
    start := oldest::date;                 -- the upkeep stopped for longer than its look-back (R-02)
  END IF;
  FOR d IN SELECT generate_series(start, current_date + p_days_ahead, interval '1 day')::date LOOP
    part := format('%I.%I', sch, tbl || '_' || to_char(d, 'YYYYMMDD'));
    IF to_regclass(part) IS NULL AND sys.create_partition(p_parent, part, d::text, (d + 1)::text, lim) >= 0 THEN
      PERFORM sys.apply_partition_options(part, p_parent);
    END IF;
  END LOOP;
  part := format('%I.%I', sch, tbl || '_default');
  IF to_regclass(part) IS NULL THEN
    EXECUTE format('CREATE TABLE %s PARTITION OF %s DEFAULT', part, p_parent);
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION sys.ensure_monthly_partitions(p_parent text, p_months_ahead integer DEFAULT 3, p_months_back integer DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE m date; part text; sch text := split_part(p_parent, '.', 1); tbl text := split_part(p_parent, '.', 2);
        start date := (date_trunc('month', now()) - make_interval(months => p_months_back))::date;
        oldest timestamptz := sys.default_partition_oldest(p_parent);
        lim bigint := sys.partition_inline_limit();
BEGIN
  IF oldest IS NOT NULL AND date_trunc('month', oldest)::date < start THEN
    start := date_trunc('month', oldest)::date;
  END IF;
  FOR m IN SELECT generate_series(start, date_trunc('month', now()) + make_interval(months => p_months_ahead),
                                  interval '1 month')::date LOOP
    part := format('%I.%I', sch, tbl || '_' || to_char(m, 'YYYYMM'));
    IF to_regclass(part) IS NULL
       AND sys.create_partition(p_parent, part, m::text, (m + interval '1 month')::date::text, lim) >= 0 THEN
      PERFORM sys.apply_partition_options(part, p_parent);
    END IF;
  END LOOP;
  part := format('%I.%I', sch, tbl || '_default');
  IF to_regclass(part) IS NULL THEN
    EXECUTE format('CREATE TABLE %s PARTITION OF %s DEFAULT', part, p_parent);
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION sys.ensure_id_partitions(p_table regclass, p_step bigint, p_ahead integer DEFAULT 2)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
DECLARE seq text := pg_get_serial_sequence(p_table::text, 'id'); last bigint := 0; step bigint := p_step; k bigint; n integer := 0;
        base text := (SELECT c.relname FROM pg_class c WHERE c.oid = p_table);
        sch text := (SELECT ns.nspname FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace WHERE c.oid = p_table);
        bounds record; lim bigint := sys.partition_inline_limit();
BEGIN
  IF seq IS NOT NULL THEN EXECUTE format('SELECT last_value FROM %s', seq) INTO last; END IF;
  SELECT max(substring(pg_get_expr(c.relpartbound, c.oid) FROM 'TO \(''?(-?[0-9]+)''?\)')::bigint
             - substring(pg_get_expr(c.relpartbound, c.oid) FROM 'FROM \(''?(-?[0-9]+)''?\)')::bigint) AS width
    INTO bounds FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = p_table;
  step := coalesce(bounds.width, p_step);
  IF step IS NULL OR step < 1000 THEN RAISE EXCEPTION 'PARTITION_STEP_INVALID: %', step; END IF;
  FOR k IN 0 .. (last / step) + p_ahead LOOP
    IF to_regclass(format('%I.%I', sch, base || '_p' || lpad(k::text, 4, '0'))) IS NULL
       AND sys.create_partition(p_table::text, format('%I.%I', sch, base || '_p' || lpad(k::text, 4, '0')),
                                (k * step)::text, ((k + 1) * step)::text, lim) >= 0 THEN
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $function$;

-- One late period out of a default partition: the oldest waiting, of the first table that has one. The worker calls it
-- in a transaction of its own, again and again while it returns a period (app.modules.notify.worker). The kind of
-- partitioning follows sys.run_maintenance_body: days for positions and the outbox, id ranges for bookings, months
-- for every other partitioned table.
CREATE OR REPLACE FUNCTION sys.move_default_period() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET lock_timeout = '10s' AS $$
DECLARE p text; def regclass; key text; sch text; tbl text; low text; part text; lo text; hi text; step bigint;
        waiting boolean; moved bigint; started timestamptz := clock_timestamp();
BEGIN
  FOR p, def IN
    SELECT n.nspname || '.' || c.relname, k.oid::regclass
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_inherits i ON i.inhparent = c.oid JOIN pg_class k ON k.oid = i.inhrelid
     WHERE c.relkind = 'p' AND NOT c.relispartition AND pg_get_expr(k.relpartbound, k.oid) = 'DEFAULT'
     ORDER BY 1
  LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s)', def) INTO waiting;
    CONTINUE WHEN NOT waiting;
    SELECT a.attname INTO key FROM pg_partitioned_table pt
      JOIN pg_attribute a ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
     WHERE pt.partrelid = p::regclass;
    sch := split_part(p, '.', 1); tbl := split_part(p, '.', 2);
    EXECUTE format('SELECT min(%I)::text FROM %s', key, def) INTO low;
    IF p = 'sales.booking' THEN
      SELECT max(substring(pg_get_expr(c.relpartbound, c.oid) FROM 'TO \(''?(-?[0-9]+)''?\)')::bigint
                 - substring(pg_get_expr(c.relpartbound, c.oid) FROM 'FROM \(''?(-?[0-9]+)''?\)')::bigint)
        INTO step FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
       WHERE i.inhparent = p::regclass AND pg_get_expr(c.relpartbound, c.oid) <> 'DEFAULT';
      lo := ((low::bigint / step) * step)::text; hi := ((low::bigint / step + 1) * step)::text;
      part := format('%I.%I', sch, tbl || '_p' || lpad((low::bigint / step)::text, 4, '0'));
    ELSIF p IN ('ops.geo_event', 'sys.outbox_event') THEN
      lo := (low::timestamptz)::date::text; hi := ((low::timestamptz)::date + 1)::text;
      part := format('%I.%I', sch, tbl || '_' || to_char((low::timestamptz)::date, 'YYYYMMDD'));
    ELSE
      lo := date_trunc('month', low::timestamptz)::date::text;
      hi := (date_trunc('month', low::timestamptz) + interval '1 month')::date::text;
      part := format('%I.%I', sch, tbl || '_' || to_char(low::timestamptz, 'YYYYMM'));
    END IF;
    moved := sys.create_partition(p, part, lo, hi);
    PERFORM sys.apply_partition_options(part, p);
    RETURN jsonb_build_object('table', p, 'partition', part, 'rows', moved,
                              'seconds', round(extract(epoch FROM clock_timestamp() - started)::numeric, 3));
  END LOOP;
  RETURN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION sys.move_default_period() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.move_default_period() TO masslak_app;
COMMENT ON FUNCTION sys.move_default_period() IS
  'Moves the oldest late period out of a default partition into its own partition, or returns NULL when none waits; one per transaction (1083, M-08)';

-- How many rows wait in default partitions, for the worker to know there is a backlog without reading it whole
CREATE OR REPLACE FUNCTION sys.default_partition_backlog() RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE def regclass; waiting boolean; n bigint := 0;
BEGIN
  FOR def IN SELECT k.oid::regclass FROM pg_class c JOIN pg_inherits i ON i.inhparent = c.oid JOIN pg_class k ON k.oid = i.inhrelid
              WHERE c.relkind = 'p' AND NOT c.relispartition AND pg_get_expr(k.relpartbound, k.oid) = 'DEFAULT' LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s)', def) INTO waiting;
    IF waiting THEN n := n + 1; END IF;
  END LOOP;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION sys.default_partition_backlog() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.default_partition_backlog() TO masslak_app;
COMMENT ON FUNCTION sys.default_partition_backlog() IS
  'Partitioned tables whose default partition holds rows waiting for a partition (1083, M-08)';

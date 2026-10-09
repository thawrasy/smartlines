-- =====================================================================
-- 1070: partition upkeep that survives running late (code review of October 2026, 7.3)
-- =====================================================================
-- The daily upkeep creates partitions a few days (months, id ranges) ahead. If it stops for longer, rows of a period
-- without a partition land in the table's default partition, and when the upkeep runs again, creating that period's
-- partition fails ("updated partition constraint for default partition would be violated"): the error aborted the
-- whole upkeep, ledger close and wallet reconciliation included, until someone moved the rows by hand.
--
-- sys.create_partition now moves them itself. In one transaction (writers of the table wait on its lock instead of
-- failing): the default partition is detached, the period's rows are copied into a plain table, which has no trigger,
-- so nothing is posted, counted or audited a second time, and removed from the default partition; the plain table is
-- attached as the period's partition (indexes, keys and row triggers follow the parent) and the default partition is
-- attached again. The three upkeep functions create every partition through it.

CREATE OR REPLACE FUNCTION sys.create_partition(p_parent text, p_part text, p_from text, p_to text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  def regclass;
  key text;
  moved bigint;
BEGIN
  BEGIN
    EXECUTE format('CREATE TABLE %s PARTITION OF %s FOR VALUES FROM (%L) TO (%L)', p_part, p_parent, p_from, p_to);
    RETURN 0;
  EXCEPTION WHEN check_violation THEN
    NULL;                                  -- rows of this period already sit in the default partition: move them
  END;
  SELECT k.oid::regclass INTO def FROM pg_inherits i JOIN pg_class k ON k.oid = i.inhrelid
   WHERE i.inhparent = p_parent::regclass AND pg_get_expr(k.relpartbound, k.oid) = 'DEFAULT';
  SELECT a.attname INTO key FROM pg_partitioned_table pt
    JOIN pg_attribute a ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
   WHERE pt.partrelid = p_parent::regclass;
  EXECUTE format('ALTER TABLE %s DETACH PARTITION %s', p_parent, def);
  EXECUTE format('CREATE TABLE %s (LIKE %s INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING GENERATED INCLUDING STORAGE INCLUDING COMMENTS)',
                 p_part, p_parent);
  EXECUTE format('INSERT INTO %s SELECT * FROM %s WHERE %I >= %L AND %I < %L', p_part, def, key, p_from, key, p_to);
  GET DIAGNOSTICS moved = ROW_COUNT;
  EXECUTE format('DELETE FROM %s WHERE %I >= %L AND %I < %L', def, key, p_from, key, p_to);
  EXECUTE format('ALTER TABLE %s ATTACH PARTITION %s FOR VALUES FROM (%L) TO (%L)', p_parent, p_part, p_from, p_to);
  EXECUTE format('ALTER TABLE %s ATTACH PARTITION %s DEFAULT', p_parent, def);
  RAISE WARNING 'partition upkeep was late: % rows of % moved from its default partition into %', moved, p_parent, p_part;
  RETURN moved;
END $$;
COMMENT ON FUNCTION sys.create_partition(text, text, text, text) IS
  'Creates a range partition, moving the rows of its range out of the default partition first when the upkeep ran late (1070); returns the rows moved';
REVOKE EXECUTE ON FUNCTION sys.create_partition(text, text, text, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION sys.ensure_daily_partitions(p_parent text, p_days_ahead integer DEFAULT 7, p_days_back integer DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE d date; part text; sch text := split_part(p_parent, '.', 1); tbl text := split_part(p_parent, '.', 2);
BEGIN
  FOR d IN SELECT generate_series(current_date - p_days_back, current_date + p_days_ahead, interval '1 day')::date LOOP
    part := format('%I.%I', sch, tbl || '_' || to_char(d, 'YYYYMMDD'));
    IF to_regclass(part) IS NULL THEN
      PERFORM sys.create_partition(p_parent, part, d::text, (d + 1)::text);
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
BEGIN
  FOR m IN SELECT generate_series(date_trunc('month', now()) - make_interval(months => p_months_back),
                                  date_trunc('month', now()) + make_interval(months => p_months_ahead),
                                  interval '1 month')::date LOOP
    part := format('%I.%I', sch, tbl || '_' || to_char(m, 'YYYYMM'));
    IF to_regclass(part) IS NULL THEN
      PERFORM sys.create_partition(p_parent, part, m::text, (m + interval '1 month')::date::text);
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
        bounds record;
BEGIN
  IF seq IS NOT NULL THEN EXECUTE format('SELECT last_value FROM %s', seq) INTO last; END IF;
  SELECT max(substring(pg_get_expr(c.relpartbound, c.oid) FROM 'TO \(''?(-?[0-9]+)''?\)')::bigint
             - substring(pg_get_expr(c.relpartbound, c.oid) FROM 'FROM \(''?(-?[0-9]+)''?\)')::bigint) AS width
    INTO bounds FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = p_table;
  step := coalesce(bounds.width, p_step);
  IF step IS NULL OR step < 1000 THEN RAISE EXCEPTION 'PARTITION_STEP_INVALID: %', step; END IF;
  FOR k IN 0 .. (last / step) + p_ahead LOOP
    IF to_regclass(format('%I.%I', sch, base || '_p' || lpad(k::text, 4, '0'))) IS NULL THEN
      PERFORM sys.create_partition(p_table::text, format('%I.%I', sch, base || '_p' || lpad(k::text, 4, '0')),
                                   (k * step)::text, ((k + 1) * step)::text);
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $function$;

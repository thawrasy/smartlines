-- =====================================================================
-- 1064: bookings partitioned by id (expert review of October 2026, stage D5)
--   Bookings are the largest table of the booking path (capacity model: about 1.5 million a day at the design target).
--   One table of billions of rows makes every vacuum, index rebuild and archive a whole-table job. Partitioned by
--   ranges of id, each partition is a few weeks of bookings at the peak: vacuum and reindex work partition by
--   partition, and a closed fiscal year can be detached and moved to the archive database (capacity model, stage 3)
--   without touching the rest.
--   Why id and not the date: 21 tables refer to a booking by its id. A partitioned table's unique keys must contain
--   the partition key, so with id every one of those references keeps working unchanged; with the date each of them
--   would need the booking's date as well. Ids grow with time, so a range of ids is a range of days.
--   Keys that must stay unique across all partitions without containing id (the booking reference, the public uid,
--   and the booker's idempotency key) are kept in sales.booking_key, written by a trigger in the same statement.
--   The conversion runs once, now, while the table is small (sys.partition_by_id); partitions ahead are created by
--   the daily upkeep (sales.ensure_booking_partitions) and watched (masslak_partition_ids_ahead, PartitionsRunningOut).
-- =====================================================================

-- ------------------------------------------------------------------ generic triggers name the partitioned table
-- A row trigger defined on a partitioned table runs with the partition as its table; the audit trail and the JSON
-- contracts are kept per table, so they look up the partitioned table the row belongs to.
CREATE OR REPLACE FUNCTION audit.tg_capture_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE o jsonb; n jsonb; pk text; sch name := TG_TABLE_SCHEMA; tbl name := TG_TABLE_NAME;
BEGIN
  IF (SELECT c.relispartition FROM pg_class c WHERE c.oid = TG_RELID) THEN
    SELECT ns.nspname, c.relname INTO sch, tbl FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE c.oid = pg_partition_root(TG_RELID);
  END IF;
  IF TG_OP <> 'INSERT' THEN o := audit.redact(to_jsonb(OLD)); END IF;
  IF TG_OP <> 'DELETE' THEN n := audit.redact(to_jsonb(NEW)); END IF;
  pk := coalesce(n->>'id', o->>'id', n->>'party_id', o->>'party_id', n->>'company_id', o->>'company_id', n->>'key', o->>'key');
  IF TG_OP = 'UPDATE' THEN               -- store changed fields only
    SELECT jsonb_object_agg(k, o->k), jsonb_object_agg(k, n->k) INTO o, n
      FROM jsonb_object_keys(n) k WHERE (o->k) IS DISTINCT FROM (n->k) AND k NOT IN ('updated_at');
    IF n IS NULL THEN RETURN NULL; END IF;
  END IF;
  INSERT INTO audit.row_change (schema_name, table_name, op, row_pk, old_values, new_values,
                                user_id, api_client_id, company_id, request_id, ip)
  VALUES (sch, tbl, left(TG_OP, 1), pk, o, n,
          sys.ctx_user_id(), sys.ctx_api_client_id(), sys.ctx_company_id(), sys.ctx_request_id(), sys.ctx_ip());
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION sys.tg_json_contract() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c record; val jsonb; old_val jsonb; v text; tbl text := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
BEGIN
  IF (SELECT k.relispartition FROM pg_class k WHERE k.oid = TG_RELID) THEN
    tbl := pg_partition_root(TG_RELID)::regclass::text;
  END IF;
  FOR c IN SELECT * FROM sys.json_contract WHERE table_name = tbl AND kind IN ('RULES','SHAPE','SNAPSHOT') LOOP
    val := to_jsonb(NEW) -> c.column_name;
    IF c.kind = 'SNAPSHOT' THEN
      IF TG_OP = 'UPDATE' THEN
        old_val := to_jsonb(OLD) -> c.column_name;
        IF old_val IS NOT NULL AND old_val NOT IN ('null'::jsonb, '{}'::jsonb, '[]'::jsonb) AND val IS DISTINCT FROM old_val THEN
          RAISE EXCEPTION 'SNAPSHOT_FROZEN: %.% cannot change once written', tbl, c.column_name USING ERRCODE = 'P0001';
        END IF;
      END IF;
      CONTINUE;
    END IF;
    v := sys.json_violation(val, c.spec, c.column_name);
    IF v IS NOT NULL THEN
      RAISE EXCEPTION 'JSON_CONTRACT_VIOLATION: %.% v%: %', tbl, c.column_name, c.version, v USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

-- ------------------------------------------------------------------ partitions by ranges of id
-- Creates the partitions <table>_pNNNN of p_step ids each, from the first to p_ahead beyond the one holding the
-- latest id. Once partitions exist, their own width is used (a changed setting never makes ranges overlap).
CREATE OR REPLACE FUNCTION sys.ensure_id_partitions(p_table regclass, p_step bigint, p_ahead integer DEFAULT 2)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
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
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (%s) TO (%s)',
                     sch, base || '_p' || lpad(k::text, 4, '0'), p_table, k * step, (k + 1) * step);
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION sys.ensure_id_partitions(regclass, bigint, integer) FROM PUBLIC;
COMMENT ON FUNCTION sys.ensure_id_partitions IS 'Range partitions of p_step ids up to p_ahead beyond the latest id (1064)';

-- Turns a table into one partitioned by ranges of id, in place, within the caller's transaction: the same name,
-- columns, defaults, identity, checks, keys, indexes, triggers, row security and policies, grants (column grants
-- included), comments and publications; foreign keys and policies of other tables that refer to it are dropped and
-- created again. Every unique key must contain id (the caller replaces the others first). Rows are copied without
-- firing triggers (nothing about them changes). Holds an exclusive lock on the table for the whole copy: run it
-- while the table is small, or in a maintenance window (docs/database/MIGRATION_PLANS.md).
CREATE OR REPLACE FUNCTION sys.partition_by_id(p_table regclass, p_step bigint, p_ahead integer DEFAULT 2)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  rel record; r record; s text; sch text; nm text; tname text; tmp text; idatt int2;
  own text[] := '{}'; after text[] := '{}'; seq_old text; last bigint; copied bigint; parts integer;
  fks integer := 0; pols integer := 0; t0 timestamptz := clock_timestamp();
BEGIN
  SELECT c.relkind, c.relname, ns.nspname, c.relrowsecurity, c.relforcerowsecurity, c.relacl, c.reloptions,
         obj_description(c.oid, 'pg_class') AS cmt
    INTO rel FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace WHERE c.oid = p_table;
  IF rel.relkind = 'p' THEN
    RETURN jsonb_build_object('table', p_table::text, 'converted', false);
  END IF;
  sch := rel.nspname; nm := rel.relname; tname := format('%I.%I', sch, nm); tmp := nm || '_partitioned';
  SELECT a.attnum INTO idatt FROM pg_attribute a WHERE a.attrelid = p_table AND a.attname = 'id' AND NOT a.attisdropped;
  IF idatt IS NULL THEN RAISE EXCEPTION 'PARTITION_NO_ID: % has no id column', tname; END IF;
  IF EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = p_table AND i.indisunique AND NOT idatt = ANY (i.indkey::int2[])) THEN
    RAISE EXCEPTION 'PARTITION_UNIQUE_WITHOUT_ID: % has a unique key without id: %', tname,
      (SELECT string_agg(i.indexrelid::regclass::text, ', ') FROM pg_index i
        WHERE i.indrelid = p_table AND i.indisunique AND NOT idatt = ANY (i.indkey::int2[]));
  END IF;
  IF rel.reloptions IS NOT NULL THEN RAISE EXCEPTION 'PARTITION_STORAGE_OPTIONS: % has storage options %', tname, rel.reloptions; END IF;
  EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE', tname);

  -- what other tables hold against it: foreign keys and policies (bound to the table itself, not its name)
  FOR r IN SELECT c.oid, c.conrelid::regclass AS tbl, c.conname, pg_get_constraintdef(c.oid) AS def,
                  obj_description(c.oid, 'pg_constraint') AS cmt
             FROM pg_constraint c WHERE c.confrelid = p_table AND c.contype = 'f' AND c.conrelid <> p_table LOOP
    after := after || format('ALTER TABLE %s ADD CONSTRAINT %I %s', r.tbl, r.conname, r.def);
    IF r.cmt IS NOT NULL THEN after := after || format('COMMENT ON CONSTRAINT %I ON %s IS %L', r.conname, r.tbl, r.cmt); END IF;
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
    fks := fks + 1;
  END LOOP;
  FOR r IN SELECT DISTINCT p.oid, p.polrelid::regclass AS tbl, p.polname, ns.nspname, c.relname
             FROM pg_policy p JOIN pg_depend d ON d.classid = 'pg_policy'::regclass AND d.objid = p.oid
             JOIN pg_class c ON c.oid = p.polrelid JOIN pg_namespace ns ON ns.oid = c.relnamespace
            WHERE d.refclassid = 'pg_class'::regclass AND d.refobjid = p_table LOOP
    SELECT format('CREATE POLICY %I ON %s AS %s FOR %s TO %s%s%s', pp.policyname, r.tbl, pp.permissive, pp.cmd,
                  array_to_string(ARRAY(SELECT CASE WHEN x = 'public' THEN 'PUBLIC' ELSE quote_ident(x) END FROM unnest(pp.roles) x), ', '),
                  CASE WHEN pp.qual IS NOT NULL THEN ' USING (' || pp.qual || ')' ELSE '' END,
                  CASE WHEN pp.with_check IS NOT NULL THEN ' WITH CHECK (' || pp.with_check || ')' ELSE '' END)
      INTO s FROM pg_policies pp WHERE pp.schemaname = r.nspname AND pp.tablename = r.relname AND pp.policyname = r.polname;
    after := after || s;
    EXECUTE format('DROP POLICY %I ON %s', r.polname, r.tbl);
    pols := pols + 1;
  END LOOP;

  -- its own keys, foreign keys, indexes, triggers, grants, comments and publications, to create on the new table
  FOR r IN SELECT c.conname, pg_get_constraintdef(c.oid) AS def, obj_description(c.oid, 'pg_constraint') AS cmt
             FROM pg_constraint c WHERE c.conrelid = p_table AND c.contype IN ('p', 'u', 'f')
            ORDER BY CASE c.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 ELSE 2 END, c.conname LOOP
    own := own || format('ALTER TABLE %s ADD CONSTRAINT %I %s', tname, r.conname, r.def);
    IF r.cmt IS NOT NULL THEN own := own || format('COMMENT ON CONSTRAINT %I ON %s IS %L', r.conname, tname, r.cmt); END IF;
  END LOOP;
  FOR r IN SELECT pg_get_indexdef(i.indexrelid) AS def, i.indexrelid::regclass AS idx, obj_description(i.indexrelid, 'pg_class') AS cmt
             FROM pg_index i WHERE i.indrelid = p_table
              AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid AND c.conrelid = p_table) LOOP
    own := own || r.def;
    IF r.cmt IS NOT NULL THEN own := own || format('COMMENT ON INDEX %s IS %L', r.idx, r.cmt); END IF;
  END LOOP;
  FOR r IN SELECT t.tgname, pg_get_triggerdef(t.oid) AS def, t.tgenabled FROM pg_trigger t
            WHERE t.tgrelid = p_table AND NOT t.tgisinternal ORDER BY t.tgname LOOP
    own := own || r.def;
    IF r.tgenabled = 'D' THEN own := own || format('ALTER TABLE %s DISABLE TRIGGER %I', tname, r.tgname); END IF;
  END LOOP;
  IF rel.relrowsecurity THEN own := own || format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', tname); END IF;
  IF rel.relforcerowsecurity THEN own := own || format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', tname); END IF;
  FOR r IN SELECT a.privilege_type, a.grantee FROM aclexplode(rel.relacl) a
            WHERE a.grantee <> (SELECT c.relowner FROM pg_class c WHERE c.oid = p_table) LOOP
    own := own || format('GRANT %s ON %s TO %s', r.privilege_type, tname,
                         CASE WHEN r.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.grantee::regrole::text) END);
  END LOOP;
  FOR r IN SELECT at.attname, a.privilege_type, a.grantee FROM pg_attribute at, aclexplode(at.attacl) a
            WHERE at.attrelid = p_table AND at.attacl IS NOT NULL LOOP
    own := own || format('GRANT %s (%I) ON %s TO %s', r.privilege_type, r.attname, tname,
                         CASE WHEN r.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.grantee::regrole::text) END);
  END LOOP;
  IF rel.cmt IS NOT NULL THEN own := own || format('COMMENT ON TABLE %s IS %L', tname, rel.cmt); END IF;
  FOR r IN SELECT pt.pubname, pt.attnames FROM pg_publication_tables pt WHERE pt.schemaname = sch AND pt.tablename = nm LOOP
    own := own || format('ALTER PUBLICATION %I ADD TABLE %s (%s)', r.pubname, tname,
                         array_to_string(ARRAY(SELECT quote_ident(x) FROM unnest(r.attnames) x), ', '));
  END LOOP;

  -- the new table, its partitions and its rows
  EXECUTE format('CREATE TABLE %I.%I (LIKE %s INCLUDING DEFAULTS INCLUDING GENERATED INCLUDING IDENTITY INCLUDING CONSTRAINTS '
                 'INCLUDING COMMENTS INCLUDING STATISTICS INCLUDING STORAGE INCLUDING COMPRESSION) PARTITION BY RANGE (id)',
                 sch, tmp, tname);
  -- the next id the new table hands out: the one the old sequence would have, never below the highest id held
  seq_old := pg_get_serial_sequence(tname, 'id');
  IF seq_old IS NOT NULL THEN
    EXECUTE format('SELECT CASE WHEN is_called THEN last_value ELSE last_value - 1 END FROM %s', seq_old) INTO last;
  END IF;
  EXECUTE format('SELECT greatest(%s, coalesce(max(id), 0)) FROM %s', coalesce(last, 0), tname) INTO last;
  FOR r IN SELECT k FROM generate_series(0, last / p_step + p_ahead) k LOOP
    EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%s) TO (%s)',
                   sch, nm || '_p' || lpad(r.k::text, 4, '0'), sch, tmp, r.k * p_step, (r.k + 1) * p_step);
  END LOOP;
  EXECUTE format('INSERT INTO %I.%I OVERRIDING SYSTEM VALUE SELECT * FROM %s', sch, tmp, tname);
  GET DIAGNOSTICS copied = ROW_COUNT;
  IF seq_old IS NOT NULL THEN
    EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN id RESTART WITH %s', sch, tmp, last + 1);
  END IF;

  -- the swap: the old table goes (nothing may still depend on it), the new one takes its name
  EXECUTE format('DROP TABLE %s', tname);
  EXECUTE format('ALTER TABLE %I.%I RENAME TO %I', sch, tmp, nm);
  IF seq_old IS NOT NULL THEN
    EXECUTE format('ALTER SEQUENCE %s RENAME TO %I', pg_get_serial_sequence(tname, 'id'), split_part(seq_old, '.', 2));
  END IF;
  FOREACH s IN ARRAY own LOOP EXECUTE s; END LOOP;
  FOREACH s IN ARRAY after LOOP EXECUTE s; END LOOP;
  EXECUTE format('ANALYZE %s', tname);
  SELECT count(*) INTO parts FROM pg_inherits WHERE inhparent = tname::regclass;
  RETURN jsonb_build_object('table', tname, 'converted', true, 'rows', copied, 'partitions', parts, 'step', p_step,
                            'foreign_keys_recreated', fks, 'policies_recreated', pols,
                            'seconds', round(extract(epoch FROM clock_timestamp() - t0)::numeric, 3));
END $$;
REVOKE ALL ON FUNCTION sys.partition_by_id(regclass, bigint, integer) FROM PUBLIC;
COMMENT ON FUNCTION sys.partition_by_id IS 'Turns a table into one partitioned by ranges of id, in place (1064)';

-- ------------------------------------------------------------------ bookings
INSERT INTO sys.setting (key, value, description)
VALUES ('capacity.booking_partition_ids', '10000000',
        'Ids per partition of sales.booking (about a week at the design peak); used when the table is first partitioned')
ON CONFLICT (key) DO NOTHING;

-- Unique across all partitions: the reference printed on tickets, the public id, the booker's idempotency key
CREATE TABLE IF NOT EXISTS sales.booking_key (
  booking_id      bigint PRIMARY KEY REFERENCES sales.booking (id) ON DELETE CASCADE,
  uid             uuid NOT NULL UNIQUE,
  booking_ref     text NOT NULL UNIQUE,
  booker_party_id bigint,
  idempotency_key text,
  UNIQUE (booker_party_id, idempotency_key)
);
COMMENT ON TABLE sales.booking_key IS
  'Keys of sales.booking that are unique over all its partitions (1064); written only by trigger sales.booking.booking_key';
COMMENT ON COLUMN sales.booking_key.booker_party_id IS 'No FK: a copy of sales.booking.booker_party_id, which carries the reference';
ALTER TABLE sales.booking_key ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales.booking_key FORCE ROW LEVEL SECURITY;
-- no role is granted the table; the policy states its owner path (a key row belongs to its booking)
DROP POLICY IF EXISTS isolation ON sales.booking_key;
CREATE POLICY isolation ON sales.booking_key USING (EXISTS (SELECT 1 FROM sales.booking b WHERE b.id = booking_id));
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note)
VALUES ('sales.booking_key', 'TENANT_PRIVATE', 'parent sales.booking', 'written by trigger only; no role reads it')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sales.booking_key', '1A', 'E11')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

CREATE OR REPLACE FUNCTION sales.tg_booking_key() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO sales.booking_key VALUES (NEW.id, NEW.uid, NEW.booking_ref, NEW.booker_party_id, NEW.idempotency_key);
  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE sales.booking_key SET uid = NEW.uid, booking_ref = NEW.booking_ref, booker_party_id = NEW.booker_party_id,
                                 idempotency_key = NEW.idempotency_key
     WHERE booking_id = OLD.id;
  ELSE
    DELETE FROM sales.booking_key WHERE booking_id = OLD.id;
  END IF;
  RETURN NULL;
END $$;

DO $$
DECLARE step bigint := coalesce((SELECT value::bigint FROM sys.setting WHERE key = 'capacity.booking_partition_ids'), 10000000);
        res jsonb;
BEGIN
  IF (SELECT relkind FROM pg_class WHERE oid = 'sales.booking'::regclass) = 'r' THEN
    INSERT INTO sales.booking_key SELECT id, uid, booking_ref, booker_party_id, idempotency_key FROM sales.booking
      ON CONFLICT (booking_id) DO NOTHING;
    -- the three keys move to sales.booking_key; lookups keep an index on each partition
    ALTER TABLE sales.booking DROP CONSTRAINT IF EXISTS booking_booking_ref_key;
    ALTER TABLE sales.booking DROP CONSTRAINT IF EXISTS booking_uid_key;
    ALTER TABLE sales.booking DROP CONSTRAINT IF EXISTS booking_booker_party_id_idempotency_key_key;
    CREATE INDEX IF NOT EXISTS booking_ref_idx ON sales.booking (booking_ref);
    CREATE INDEX IF NOT EXISTS booking_uid_idx ON sales.booking (uid);
    CREATE INDEX IF NOT EXISTS booking_idempotency_idx ON sales.booking (booker_party_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
    res := sys.partition_by_id('sales.booking', step, 2);
    RAISE NOTICE 'sales.booking partitioned: %', res;
  END IF;
END $$;

DROP TRIGGER IF EXISTS booking_key ON sales.booking;
CREATE TRIGGER booking_key AFTER INSERT OR DELETE OR UPDATE OF uid, booking_ref, booker_party_id, idempotency_key ON sales.booking
  FOR EACH ROW EXECUTE FUNCTION sales.tg_booking_key();
COMMENT ON TRIGGER booking_key ON sales.booking IS 'Keeps the reference, uid and idempotency key unique over all partitions (1064)';

-- the warehouse's column grants and publication follow the new table
SELECT sys.dw_publish();

-- Partitions two ranges ahead of the latest booking (called by the daily upkeep, sys.run_maintenance)
CREATE OR REPLACE FUNCTION sales.ensure_booking_partitions() RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT sys.ensure_id_partitions('sales.booking',
                                  coalesce((SELECT value::bigint FROM sys.setting WHERE key = 'capacity.booking_partition_ids'), 10000000), 2)
$$;
REVOKE ALL ON FUNCTION sales.ensure_booking_partitions() FROM PUBLIC;
COMMENT ON FUNCTION sales.ensure_booking_partitions IS 'Creates the booking partitions two ranges ahead of the latest id (1064)';

-- The daily upkeep (sys.run_maintenance) creates partitions ahead for every partitioned table: by day, by month,
-- and now by ranges of id for bookings. Unchanged otherwise (body of 1052).
CREATE OR REPLACE FUNCTION sys.run_maintenance_body()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
DECLARE p text; done jsonb := '{}'::jsonb; keep_days int; dropped int := 0; held boolean; r fin.wallet_reconciliation;
        orphans bigint; closed int; checked_day date; day_mismatch int;
BEGIN
  FOR p IN SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'p' AND NOT c.relispartition LOOP
    IF p IN ('ops.geo_event', 'sys.outbox_event') THEN
      PERFORM sys.ensure_daily_partitions(p, 7, 1);
    ELSIF p = 'sales.booking' THEN
      -- partitioned by ranges of id (1064): two ranges ahead of the latest booking
      PERFORM sales.ensure_booking_partitions();
    ELSE
      PERFORM sys.ensure_monthly_partitions(p, 3, 1);
    END IF;
  END LOOP;
  SELECT retention_days INTO keep_days FROM gov.data_inventory WHERE dataset = 'ops.geo_event';
  held := EXISTS (SELECT 1 FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'DATASET' AND dataset = 'ops.geo_event');
  IF keep_days IS NOT NULL AND NOT held THEN
    dropped := sys.drop_daily_partitions_older_than('ops.geo_event', keep_days);
  END IF;
  -- a vehicle that stopped reporting does not keep its last position beyond the retention of positions
  DELETE FROM ops.vehicle_position
   WHERE ts < now() - make_interval(days => coalesce((SELECT retention_days FROM gov.data_inventory WHERE dataset = 'ops.vehicle_position'), 7));
  closed := fin.close_ledger_days();
  checked_day := (SELECT closed_through - 7 FROM fin.ledger_close WHERE id);
  day_mismatch := CASE WHEN checked_day IS NULL THEN 0 ELSE fin.verify_ledger_day(checked_day) END;
  r := fin.reconcile_wallets();
  IF NOT EXISTS (SELECT 1 FROM sys.orphan_check WHERE checked_at > now() - interval '7 days') THEN
    orphans := sys.run_orphan_check();
  END IF;
  done := jsonb_build_object('partitions_checked', true, 'geo_partitions_dropped', dropped, 'geo_retention_held', held,
                             'expired_holds_released', ops.release_expired_holds(),
                             'ledger_days_closed', closed, 'ledger_day_verified', checked_day, 'ledger_day_mismatches', day_mismatch,
                             'wallet_mismatches', r.mismatches + day_mismatch, 'orphans', orphans, 'purged', sys.purge_expired(),
                             'audit_partitions_dropped', audit.drop_archived_partitions(),
                             'break_glass', sec.break_glass_upkeep(), 'at', now());
  RETURN done;
END $function$;

-- ------------------------------------------------------------------ monitoring
-- Tables partitioned by date report how far ahead their partitions reach in seconds; tables partitioned by id report
-- how many partitions' worth of ids remain beyond the latest id (alert PartitionsRunningOut below one).
CREATE OR REPLACE FUNCTION sys.partition_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p record; ahead float8; parts int; def regclass; def_rows bigint; period text; top bigint; width bigint;
        seq text; last bigint;
BEGIN
  FOR p IN SELECT c.oid, c.oid::regclass::text AS name,
                  format_type(a.atttypid, NULL) IN ('timestamp with time zone', 'timestamp without time zone', 'date') AS by_time
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_partitioned_table pt ON pt.partrelid = c.oid
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = pt.partattrs[0]
            WHERE c.relkind = 'p' AND NOT c.relispartition AND n.nspname NOT LIKE 'pg\_%' ORDER BY 2 LOOP
    SELECT count(*), (array_agg(k.oid::regclass) FILTER (WHERE pg_get_expr(k.relpartbound, k.oid) = 'DEFAULT'))[1]
      INTO parts, def FROM pg_inherits i JOIN pg_class k ON k.oid = i.inhrelid WHERE i.inhparent = p.oid;
    def_rows := 0;
    IF def IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM (SELECT 1 FROM %s LIMIT 10000) s', def) INTO def_rows;
    END IF;
    metric := 'masslak_partitions'; labels := jsonb_build_object('table', p.name); value := parts; RETURN NEXT;
    IF p.by_time THEN
      SELECT max(extract(epoch FROM substring(pg_get_expr(k.relpartbound, k.oid) FROM 'TO \(''([^'']+)''\)')::timestamptz - now()))
        INTO ahead FROM pg_inherits i JOIN pg_class k ON k.oid = i.inhrelid
       WHERE i.inhparent = p.oid AND pg_get_expr(k.relpartbound, k.oid) <> 'DEFAULT';
      period := CASE WHEN p.name IN ('ops.geo_event', 'sys.outbox_event') THEN 'day' ELSE 'month' END;
      metric := 'masslak_partition_ahead_seconds'; labels := jsonb_build_object('table', p.name, 'period', period);
      value := coalesce(ahead, 0); RETURN NEXT;
    ELSE
      SELECT max(substring(pg_get_expr(k.relpartbound, k.oid) FROM 'TO \(''?(-?[0-9]+)''?\)')::bigint),
             max(substring(pg_get_expr(k.relpartbound, k.oid) FROM 'TO \(''?(-?[0-9]+)''?\)')::bigint
                 - substring(pg_get_expr(k.relpartbound, k.oid) FROM 'FROM \(''?(-?[0-9]+)''?\)')::bigint)
        INTO top, width FROM pg_inherits i JOIN pg_class k ON k.oid = i.inhrelid
       WHERE i.inhparent = p.oid AND pg_get_expr(k.relpartbound, k.oid) <> 'DEFAULT';
      seq := pg_get_serial_sequence(p.name, 'id'); last := 0;
      IF seq IS NOT NULL THEN EXECUTE format('SELECT last_value FROM %s', seq) INTO last; END IF;
      metric := 'masslak_partition_ids_ahead'; labels := jsonb_build_object('table', p.name);
      value := coalesce((top - last)::float8 / nullif(width, 0), 0); RETURN NEXT;
    END IF;
    metric := 'masslak_partition_default_rows'; labels := jsonb_build_object('table', p.name); value := def_rows; RETURN NEXT;
  END LOOP;
END $$;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.43.0', 'Expert review stage D5: bookings partitioned by ranges of id; keys unique over all partitions in sales.booking_key'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.43.0');

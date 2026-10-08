-- =====================================================================
-- 1053: the outbox at ten million operations a day (docs/operations/CAPACITY_MODEL.md, docs/integration/EVENTS.md)
--   About eight million events a day at the full-platform volume pass the partitioning point of 1051
--   (capacity.outbox_partition_rows, 20 million rows) within three days. The outbox is therefore partitioned by day now,
--   while it is small: a finished day is dropped whole instead of deleting millions of rows, and the worker's queue scan
--   stays on the partial index of a few recent days.
--   * sys.outbox_event: daily partitions on created_at. An event's identity is (id, created_at); event_uid stays
--     unique per day (random UUIDs; the contract's stable id is unchanged).
--   * sys.webhook_delivery keeps the event's day (outbox_created_at) with its reference, so a day of events and its
--     deliveries can be told apart; a day of events is dropped only when no delivery of it is kept any more.
--   * The duplicate pending-queue index of the original table is not recreated.
-- =====================================================================

DO $$
DECLARE days_back int; mx bigint;
BEGIN
  IF (SELECT relkind FROM pg_class WHERE oid = 'sys.outbox_event'::regclass) = 'p' THEN
    RETURN;                                   -- already converted
  END IF;
  ALTER TABLE sys.webhook_delivery DROP CONSTRAINT IF EXISTS webhook_delivery_outbox_event_id_fkey;
  ALTER TABLE sys.webhook_delivery ADD COLUMN IF NOT EXISTS outbox_created_at timestamptz;
  UPDATE sys.webhook_delivery d SET outbox_created_at = o.created_at FROM sys.outbox_event o WHERE o.id = d.outbox_event_id;
  ALTER TABLE sys.outbox_event RENAME TO outbox_event_unpartitioned;
  ALTER INDEX sys.outbox_event_pkey RENAME TO outbox_event_unpartitioned_pkey;
  ALTER INDEX sys.outbox_event_event_uid_key RENAME TO outbox_event_unpartitioned_event_uid_key;
  ALTER INDEX sys.outbox_pending RENAME TO outbox_unpartitioned_pending;
  ALTER INDEX sys.outbox_pending_idx RENAME TO outbox_unpartitioned_pending_idx;
  ALTER INDEX sys.outbox_event_aggregate_id_poly RENAME TO outbox_event_unpartitioned_aggregate_id_poly;
  CREATE TABLE sys.outbox_event (
    id              bigint GENERATED ALWAYS AS IDENTITY,
    event_uid       uuid NOT NULL DEFAULT gen_random_uuid(),
    event_type      text NOT NULL,
    aggregate_type  text NOT NULL,
    aggregate_id    bigint NOT NULL,
    company_id      bigint,
    payload         jsonb NOT NULL,
    status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'PUBLISHED', 'FAILED')),
    attempts        integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    last_error      text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    published_at    timestamptz,
    schema_version  smallint NOT NULL DEFAULT 1,
    correlation_id  uuid DEFAULT sys.ctx_request_id(),
    aggregate_seq   bigint,
    PRIMARY KEY (id, created_at),
    UNIQUE (event_uid, created_at)
  ) PARTITION BY RANGE (created_at);
  days_back := greatest(1, coalesce((SELECT current_date - min(created_at)::date FROM sys.outbox_event_unpartitioned), 1));
  PERFORM sys.ensure_daily_partitions('sys.outbox_event', 7, days_back);
  INSERT INTO sys.outbox_event (id, event_uid, event_type, aggregate_type, aggregate_id, company_id, payload, status, attempts,
                                next_attempt_at, last_error, created_at, published_at, schema_version, correlation_id, aggregate_seq)
  OVERRIDING SYSTEM VALUE
  SELECT id, event_uid, event_type, aggregate_type, aggregate_id, company_id, payload, status, attempts, next_attempt_at, last_error,
         created_at, published_at, schema_version, correlation_id, aggregate_seq FROM sys.outbox_event_unpartitioned;
  mx := coalesce((SELECT max(id) FROM sys.outbox_event_unpartitioned), 0);
  EXECUTE format('ALTER TABLE sys.outbox_event ALTER COLUMN id RESTART WITH %s', mx + 1);
  DROP TABLE sys.outbox_event_unpartitioned;
  ALTER TABLE sys.webhook_delivery ALTER COLUMN outbox_created_at SET NOT NULL;
END $$;

CREATE INDEX IF NOT EXISTS outbox_pending ON sys.outbox_event (next_attempt_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS outbox_event_aggregate_id_poly ON sys.outbox_event (aggregate_type, aggregate_id);
COMMENT ON TABLE sys.outbox_event IS 'Transactional outbox: written in the same transaction as the change, then published to services and partners; daily partitions, a finished day dropped whole after the retention (1053)';
COMMENT ON COLUMN sys.outbox_event.aggregate_id IS 'Polymorphic: the row named by (aggregate_type, aggregate_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN sys.outbox_event.company_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN sys.outbox_event.correlation_id IS 'External: the request that caused the event, for tracing across services (audit T3-12)';
COMMENT ON COLUMN sys.outbox_event.aggregate_seq IS 'Order of the event among its aggregate''s events (1, 2, ...); consumers apply an event only after the previous one (audit T3-12)';

DROP TRIGGER IF EXISTS a_outbox_sequence ON sys.outbox_event;
CREATE TRIGGER a_outbox_sequence BEFORE INSERT ON sys.outbox_event FOR EACH ROW EXECUTE FUNCTION sys.tg_outbox_sequence();

ALTER TABLE sys.outbox_event ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS outbox_system ON sys.outbox_event;
CREATE POLICY outbox_system ON sys.outbox_event USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
DROP POLICY IF EXISTS outbox_insert ON sys.outbox_event;
CREATE POLICY outbox_insert ON sys.outbox_event FOR INSERT WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON sys.outbox_event TO masslak_app;
GRANT SELECT ON sys.outbox_event TO masslak_readonly;

INSERT INTO sys.partition_option (parent, options, reason) VALUES
  ('sys.outbox_event', '{fillfactor=80,autovacuum_vacuum_scale_factor=0.01,autovacuum_analyze_scale_factor=0.02}',
   'Every event changes status once: room for the update on the same page, and vacuum soon after')
ON CONFLICT (parent) DO UPDATE SET options = EXCLUDED.options, reason = EXCLUDED.reason;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.oid::regclass::text AS part FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
            WHERE i.inhparent = 'sys.outbox_event'::regclass LOOP
    PERFORM sys.apply_partition_options(r.part, 'sys.outbox_event');
  END LOOP;
END $$;

-- deliveries name the event by its identity; the event's day is filled in when the writer does not give it
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'sys.webhook_delivery'::regclass AND conname = 'webhook_delivery_outbox_event_fkey') THEN
    ALTER TABLE sys.webhook_delivery ADD CONSTRAINT webhook_delivery_outbox_event_fkey
      FOREIGN KEY (outbox_event_id, outbox_created_at) REFERENCES sys.outbox_event (id, created_at);
  END IF;
END $$;
DROP INDEX IF EXISTS sys.webhook_delivery_outbox_event_id_fkx;
CREATE INDEX IF NOT EXISTS webhook_delivery_outbox_event_fkx ON sys.webhook_delivery (outbox_event_id, outbox_created_at);
CREATE INDEX IF NOT EXISTS webhook_delivery_event_day_idx ON sys.webhook_delivery (outbox_created_at);
COMMENT ON COLUMN sys.webhook_delivery.outbox_created_at IS 'When the delivered event was written: with outbox_event_id, the identity of the event in the daily partitions (1053)';

CREATE OR REPLACE FUNCTION sys.tg_delivery_event_day() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.outbox_created_at IS NULL THEN
    SELECT created_at INTO NEW.outbox_created_at FROM sys.outbox_event WHERE id = NEW.outbox_event_id ORDER BY created_at DESC LIMIT 1;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a_delivery_event_day ON sys.webhook_delivery;
CREATE TRIGGER a_delivery_event_day BEFORE INSERT ON sys.webhook_delivery FOR EACH ROW EXECUTE FUNCTION sys.tg_delivery_event_day();

-- dropping finished days: older than the outbox retention, no event still waiting, and no delivery of it still kept
-- (deliveries have their own, longer retention); a legal hold on the outbox keeps every day
CREATE OR REPLACE FUNCTION sys.drop_outbox_days() RETURNS int LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record; n int := 0; pending boolean; days int := (SELECT retention_days FROM gov.data_inventory WHERE dataset = 'sys.outbox_event');
BEGIN
  IF days IS NULL OR EXISTS (SELECT 1 FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'DATASET' AND dataset = 'sys.outbox_event') THEN
    RETURN 0;
  END IF;
  FOR r IN SELECT c.oid::regclass::text AS part,
                  substring(pg_get_expr(c.relpartbound, c.oid) from 'FROM \(''([0-9-]+)')::date AS lower_bound,
                  substring(pg_get_expr(c.relpartbound, c.oid) from 'TO \(''([0-9-]+)')::date AS upper_bound
             FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
            WHERE i.inhparent = 'sys.outbox_event'::regclass AND pg_get_expr(c.relpartbound, c.oid) LIKE 'FOR VALUES FROM%' LOOP
    CONTINUE WHEN r.upper_bound > current_date - days;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE status = ''PENDING'')', r.part) INTO pending;
    CONTINUE WHEN pending;
    CONTINUE WHEN EXISTS (SELECT 1 FROM sys.webhook_delivery d WHERE d.outbox_created_at >= r.lower_bound AND d.outbox_created_at < r.upper_bound);
    -- detaching checks that no delivery references the day (the deliveries' foreign key), then the day goes
    EXECUTE format('ALTER TABLE sys.outbox_event DETACH PARTITION %s', r.part);
    EXECUTE format('DROP TABLE %s', r.part);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION sys.drop_outbox_days() FROM PUBLIC;
COMMENT ON FUNCTION sys.drop_outbox_days() IS 'Drops finished days of the outbox after its retention, unless an event of the day still waits or a delivery of it is still kept';

-- the purge: deliveries by their retention, days of events by sys.drop_outbox_days, stragglers in the default partition
CREATE OR REPLACE FUNCTION sys.purge_expired() RETURNS jsonb LANGUAGE plpgsql
  SECURITY DEFINER SET search_path TO 'pg_catalog', 'pg_temp' AS $function$
DECLARE d_out int := 0; d_days int := 0; d_hook int := 0; d_note int := 0; days int;
  held text[] := ARRAY(SELECT dataset FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'DATASET');
BEGIN
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'sys.webhook_delivery';
  IF days IS NOT NULL AND NOT 'sys.webhook_delivery' = ANY (held) THEN
    DELETE FROM sys.webhook_delivery WHERE status IN ('DELIVERED','DEAD') AND created_at < now() - make_interval(days => days);
    GET DIAGNOSTICS d_hook = ROW_COUNT;
  END IF;
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'sys.outbox_event';
  IF days IS NOT NULL AND NOT 'sys.outbox_event' = ANY (held) THEN
    d_days := sys.drop_outbox_days();
    IF to_regclass('sys.outbox_event_default') IS NOT NULL THEN
      DELETE FROM sys.outbox_event_default o WHERE o.status = 'PUBLISHED' AND o.published_at < now() - make_interval(days => days)
         AND NOT EXISTS (SELECT 1 FROM sys.webhook_delivery w WHERE w.outbox_event_id = o.id AND w.outbox_created_at = o.created_at);
      GET DIAGNOSTICS d_out = ROW_COUNT;
    END IF;
  END IF;
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'crm.notification';
  IF days IS NOT NULL AND NOT 'crm.notification' = ANY (held) THEN
    DELETE FROM crm.notification WHERE created_at < now() - make_interval(days => days);
    GET DIAGNOSTICS d_note = ROW_COUNT;
  END IF;
  RETURN jsonb_build_object('outbox_events', d_out, 'outbox_days_dropped', d_days, 'webhook_deliveries', d_hook, 'notifications', d_note);
END $function$;

UPDATE gov.data_inventory SET erasure_method = 'DROP_PARTITION' WHERE dataset = 'sys.outbox_event';

INSERT INTO sys.schema_migration (version, description)
SELECT '1.35.0', 'Outbox in daily partitions dropped whole after the retention; deliveries keep the event''s day'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.35.0');

SELECT sys.refresh_table_class();

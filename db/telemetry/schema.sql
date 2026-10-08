-- =====================================================================
-- Telemetry database: the history of vehicle positions (expert review of October 2026, stage D2)
--   A PostgreSQL of its own, so the largest write stream (capacity model: 2,000 positions a second in service hours)
--   no longer fills the primary's WAL, replica and backups. The primary grades each position and keeps each
--   vehicle's latest (schema file 1063, ops.accept_positions); the API appends the graded positions here.
--   Run by deploy/migrate.sh when MASSLAK_TELEMETRY_OWNER_URL is set; safe to run again:
--     psql <owner url> -v ON_ERROR_STOP=1 -v writer_password=... -f db/telemetry/schema.sql
--   Rows are append-only evidence (audit T3-11): the writer may insert and read, never change or delete. Daily
--   partitions are created ahead and dropped whole after the retention the primary sets (gov.data_inventory, legal
--   holds respected), by the worker through tel.upkeep.
-- =====================================================================

SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS tel;
COMMENT ON SCHEMA tel IS 'Vehicle positions, graded on the primary (1063) and kept here by day';

CREATE TABLE IF NOT EXISTS tel.position (
  ts             timestamptz NOT NULL,
  received_at    timestamptz NOT NULL DEFAULT now(),
  company_id     bigint NOT NULL,
  trip_id        bigint,
  vehicle_id     bigint,
  driver_user_id bigint,
  device_id      bigint,
  lat            numeric(9,6) NOT NULL,
  lng            numeric(9,6) NOT NULL,
  accuracy_m     real,
  speed_kmh      real,
  heading        smallint,
  source         text NOT NULL DEFAULT 'DRIVER_APP',
  event_id       uuid,
  seq            bigint CHECK (seq IS NULL OR seq >= 0),
  device_ts      timestamptz,
  provider       text CHECK (provider IS NULL OR provider IN ('GPS','NETWORK','FUSED','DEVICE')),
  is_mock        boolean NOT NULL DEFAULT false,
  trust          text NOT NULL CHECK (trust IN ('HIGH','LOW','REJECTED')),
  trust_flags    text[] NOT NULL DEFAULT '{}'
) PARTITION BY RANGE (ts);
COMMENT ON TABLE tel.position IS 'Vehicle positions with their trust grade (audit T3-11); ids are those of the primary';
CREATE TABLE IF NOT EXISTS tel.position_default PARTITION OF tel.position DEFAULT;
-- a position the device resends (same event id) is a duplicate: the insert skips it
CREATE UNIQUE INDEX IF NOT EXISTS position_event_uq ON tel.position (event_id, ts);
CREATE INDEX IF NOT EXISTS position_vehicle_ts_idx ON tel.position (vehicle_id, ts DESC);
CREATE INDEX IF NOT EXISTS position_trip_ts_idx ON tel.position (trip_id, ts);
CREATE INDEX IF NOT EXISTS position_company_ts_idx ON tel.position (company_id, ts);

-- Daily partitions from p_back days ago to p_ahead days ahead; returns how many were created
CREATE OR REPLACE FUNCTION tel.ensure_partitions(p_ahead integer, p_back integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE d date; n integer := 0; name text;
BEGIN
  FOR d IN SELECT generate_series(current_date - p_back, current_date + p_ahead, interval '1 day')::date LOOP
    name := 'position_' || to_char(d, 'YYYYMMDD');
    IF to_regclass('tel.' || name) IS NULL THEN
      EXECUTE format('CREATE TABLE tel.%I PARTITION OF tel.position FOR VALUES FROM (%L) TO (%L)', name, d, d + 1);
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;

-- Drops the daily partitions wholly older than p_keep_days; never fewer than one day is kept
CREATE OR REPLACE FUNCTION tel.drop_older_than(p_keep_days integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record; n integer := 0; cutoff date := current_date - greatest(p_keep_days, 1);
BEGIN
  FOR r IN SELECT c.oid::regclass::text AS part, pg_get_expr(c.relpartbound, c.oid) AS bound
             FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = 'tel.position'::regclass LOOP
    IF r.bound LIKE 'FOR VALUES FROM%' AND substring(r.bound from 'TO \(''([0-9-]+)')::date <= cutoff THEN
      EXECUTE format('DROP TABLE %s', r.part);
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;

-- Daily upkeep, called by the worker with the retention and hold the primary reports (ops.position_retention)
CREATE OR REPLACE FUNCTION tel.upkeep(p_keep_days integer, p_held boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE created integer; dropped integer := 0;
BEGIN
  created := tel.ensure_partitions(7, least(greatest(p_keep_days, 1), 31));
  IF NOT p_held THEN dropped := tel.drop_older_than(p_keep_days); END IF;
  RETURN jsonb_build_object('partitions_created', created, 'partitions_dropped', dropped, 'held', p_held, 'keep_days', p_keep_days);
END $$;

-- Figures for the API's metrics endpoint
CREATE OR REPLACE FUNCTION tel.metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT 'masslak_telemetry_partitions_missing', '{}'::jsonb,
         (2 - (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'tel'::regnamespace
                AND c.relname IN ('position_' || to_char(current_date, 'YYYYMMDD'), 'position_' || to_char(current_date + 1, 'YYYYMMDD'))))::float8
  UNION ALL
  SELECT 'masslak_telemetry_default_rows', '{}'::jsonb, (SELECT count(*) FROM tel.position_default)::float8
  UNION ALL
  SELECT 'masslak_telemetry_bytes', '{}'::jsonb,
         (SELECT coalesce(sum(pg_total_relation_size(i.inhrelid)), 0) FROM pg_inherits i WHERE i.inhparent = 'tel.position'::regclass)::float8
$$;

-- The API's login (MASSLAK_TELEMETRY_DATABASE_URL): append and read, never change or delete
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_tel') THEN CREATE ROLE masslak_tel LOGIN; END IF;
END $$;
\if :{?writer_password}
SELECT format('ALTER ROLE masslak_tel PASSWORD %L', :'writer_password') \gexec
\endif
ALTER ROLE masslak_tel SET statement_timeout = '10s';
GRANT USAGE ON SCHEMA tel TO masslak_tel;
REVOKE ALL ON tel.position FROM masslak_tel;
GRANT SELECT, INSERT ON tel.position TO masslak_tel;
REVOKE ALL ON FUNCTION tel.ensure_partitions(integer, integer), tel.drop_older_than(integer), tel.upkeep(integer, boolean),
                       tel.metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tel.upkeep(integer, boolean), tel.metrics() TO masslak_tel;
SELECT tel.ensure_partitions(7, 7);

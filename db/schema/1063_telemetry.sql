-- =====================================================================
-- 1063: vehicle positions in a telemetry database (expert review of October 2026, stage D2)
--   Positions are the largest write stream (capacity model: 2,000 a second in service hours, about half the primary's
--   WAL). With MASSLAK_TELEMETRY_DATABASE_URL set, their history goes to a PostgreSQL of its own (db/telemetry/schema.sql);
--   the primary keeps what bookings, operations and the live map need: the grade of each position (one set of rules,
--   below), the latest position of each vehicle, and the tracking alerts. Without it nothing changes: positions are
--   written to ops.geo_event as before, graded by the same rules.
--   ops.accept_positions grades a batch for the driver's own trip and keeps the latest position; the API then stores
--   the graded batch in the telemetry database. ops.position_retention tells the worker how long to keep it there.
-- =====================================================================

ALTER TABLE ops.vehicle_position ADD COLUMN IF NOT EXISTS seq bigint;
COMMENT ON COLUMN ops.vehicle_position.seq IS 'The device''s counter of the latest position: the next one with a lower counter is out of order (1063)';

-- The trust rules of a position (audit T3-11), in one place for both stores. prev_*: the vehicle's latest accepted
-- position before this one (within a day), or NULL.
CREATE OR REPLACE FUNCTION ops.position_flags(p_ts timestamptz, p_received timestamptz, p_lat numeric, p_lng numeric,
    p_accuracy real, p_provider text, p_is_mock boolean, p_device_ts timestamptz, p_seq bigint, p_device bigint,
    p_prev_ts timestamptz, p_prev_lat numeric, p_prev_lng numeric, p_prev_seq bigint)
RETURNS text[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  flags text[] := '{}'; km float8; hrs float8; att text;
  acc_low real := coalesce((SELECT value::real FROM sys.setting WHERE key = 'tracking.max_accuracy_m'), 50);
  acc_bad real := coalesce((SELECT value::real FROM sys.setting WHERE key = 'tracking.reject_accuracy_m'), 500);
  vmax float8 := coalesce((SELECT value::float8 FROM sys.setting WHERE key = 'tracking.max_speed_kmh'), 200);
  late int := coalesce((SELECT value::int FROM sys.setting WHERE key = 'tracking.late_minutes'), 10);
BEGIN
  IF p_is_mock THEN flags := array_append(flags, 'MOCK_LOCATION'); END IF;
  IF p_device_ts IS NOT NULL AND p_device_ts > p_received + interval '2 minutes' THEN flags := array_append(flags, 'FUTURE_TIME'); END IF;
  IF p_accuracy IS NOT NULL AND p_accuracy > acc_bad THEN flags := array_append(flags, 'NO_FIX'); END IF;
  IF p_accuracy IS NULL OR p_accuracy > acc_low THEN flags := array_append(flags, 'INACCURATE'); END IF;
  IF p_provider = 'NETWORK' THEN flags := array_append(flags, 'NETWORK_ONLY'); END IF;
  IF p_device_ts IS NOT NULL AND p_device_ts < p_received - make_interval(mins => late) THEN flags := array_append(flags, 'LATE'); END IF;
  -- the device: unknown, revoked, failed attestation, or (when required) not attested
  IF p_device IS NULL THEN
    IF sys.requirement_enforced('tracking.device_attestation', current_date) THEN flags := array_append(flags, 'NO_DEVICE'); END IF;
  ELSE
    SELECT CASE WHEN d.revoked_at IS NOT NULL THEN 'REVOKED' ELSE d.attestation_state END INTO att FROM iam.device d WHERE d.id = p_device;
    IF att IN ('REVOKED', 'FAILED') THEN
      flags := array_append(flags, 'DEVICE_' || att);
    ELSIF att <> 'PASSED' AND sys.requirement_enforced('tracking.device_attestation', current_date) THEN
      flags := array_append(flags, 'NOT_ATTESTED');
    END IF;
  END IF;
  IF p_prev_ts IS NOT NULL THEN
    IF p_seq IS NOT NULL AND p_prev_seq IS NOT NULL AND p_seq <= p_prev_seq THEN flags := array_append(flags, 'OUT_OF_ORDER'); END IF;
    km := 2 * 6371 * asin(sqrt(power(sin(radians(p_lat - p_prev_lat) / 2), 2)
                               + cos(radians(p_prev_lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - p_prev_lng) / 2), 2)));
    hrs := greatest(extract(epoch FROM p_ts - p_prev_ts) / 3600.0, 1.0 / 3600);
    IF km > 0.2 AND km / hrs > vmax THEN flags := array_append(flags, 'IMPOSSIBLE_SPEED'); END IF;
  END IF;
  RETURN flags;
END $$;
REVOKE ALL ON FUNCTION ops.position_flags(timestamptz, timestamptz, numeric, numeric, real, text, boolean, timestamptz, bigint,
                                           bigint, timestamptz, numeric, numeric, bigint) FROM PUBLIC;
COMMENT ON FUNCTION ops.position_flags IS 'The trust flags of a vehicle position (audit T3-11); used by both position stores (1063)';

CREATE OR REPLACE FUNCTION ops.position_trust(p_flags text[]) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_flags && ARRAY['MOCK_LOCATION','FUTURE_TIME','NO_FIX','DEVICE_REVOKED','DEVICE_FAILED'] THEN 'REJECTED'
              WHEN cardinality(p_flags) > 0 THEN 'LOW' ELSE 'HIGH' END
$$;
COMMENT ON FUNCTION ops.position_trust IS 'HIGH, LOW or REJECTED from the trust flags of a position (1063)';

-- Positions kept on the primary (no telemetry database): the same rules, the history as the previous position
CREATE OR REPLACE FUNCTION ops.tg_geo_event_trust() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE prev record;
BEGIN
  NEW.received_at := now();
  -- a position the device resends (same event id) is dropped quietly: the insert returns no row
  IF NEW.event_id IS NOT NULL AND EXISTS (SELECT 1 FROM ops.geo_event g WHERE g.event_id = NEW.event_id AND g.ts > NEW.ts - interval '8 days'
                                            AND g.ts < NEW.ts + interval '8 days') THEN
    RETURN NULL;
  END IF;
  IF NEW.vehicle_id IS NOT NULL THEN
    SELECT g.ts, g.lat, g.lng, g.seq INTO prev FROM ops.geo_event g
     WHERE g.vehicle_id = NEW.vehicle_id AND g.ts <= NEW.ts AND g.ts > NEW.ts - interval '1 day' AND g.trust <> 'REJECTED'
     ORDER BY g.ts DESC LIMIT 1;
  END IF;
  NEW.trust_flags := ops.position_flags(NEW.ts, NEW.received_at, NEW.lat, NEW.lng, NEW.accuracy_m, NEW.provider, NEW.is_mock,
                                        NEW.device_ts, NEW.seq, NEW.device_id, prev.ts, prev.lat, prev.lng, prev.seq);
  NEW.trust := ops.position_trust(NEW.trust_flags);
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION ops.tg_vehicle_position() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  INSERT INTO ops.vehicle_position AS p (vehicle_id, trip_id, driver_user_id, ts, lat, lng, speed_kmh, heading, accuracy_m, trust, seq, updated_at)
  SELECT DISTINCT ON (n.vehicle_id) n.vehicle_id, n.trip_id, n.driver_user_id, n.ts, n.lat, n.lng, n.speed_kmh, n.heading,
         n.accuracy_m, n.trust, n.seq, now()
    FROM new_positions n
   WHERE n.vehicle_id IS NOT NULL AND n.trust IS DISTINCT FROM 'REJECTED'
   ORDER BY n.vehicle_id, n.ts DESC
  ON CONFLICT (vehicle_id) DO UPDATE
     SET trip_id = EXCLUDED.trip_id, driver_user_id = EXCLUDED.driver_user_id, ts = EXCLUDED.ts, lat = EXCLUDED.lat,
         lng = EXCLUDED.lng, speed_kmh = EXCLUDED.speed_kmh, heading = EXCLUDED.heading, accuracy_m = EXCLUDED.accuracy_m,
         trust = EXCLUDED.trust, seq = EXCLUDED.seq, updated_at = now()
   WHERE p.ts < EXCLUDED.ts;
  RETURN NULL;
END $$;

-- Positions kept in the telemetry database: grades a batch from the driver's own trip, in the order sent, each
-- against the vehicle's latest accepted position or the batch's previous one, keeps the latest position and closes
-- the trip's signal alerts. A position older than the vehicle's latest is graded without the speed and order checks
-- (the history is in the telemetry database); its own time, accuracy, device and mock checks still apply.
CREATE OR REPLACE FUNCTION ops.accept_positions(p_trip bigint, p_points jsonb)
RETURNS TABLE (idx integer, ts timestamptz, received_at timestamptz, trust text, trust_flags text[],
               company_id bigint, vehicle_id bigint, driver_user_id bigint, device_id bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
#variable_conflict use_column
DECLARE
  t record; dev bigint; last record; p record; f text[]; g text; j int; b int; k int := 0; top int;
  prev_ts timestamptz; prev_lat numeric; prev_lng numeric; prev_seq bigint; rcv timestamptz := now();
  -- the batch graded so far (at most 120 positions; arrays rather than a temporary table, which would write to the
  -- catalogue on every request)
  a_ts timestamptz[] := '{}'; a_lat numeric[] := '{}'; a_lng numeric[] := '{}'; a_seq bigint[] := '{}';
  a_ok boolean[] := '{}'; a_speed real[] := '{}'; a_acc real[] := '{}'; a_trust text[] := '{}';
BEGIN
  SELECT x.id, x.company_id, x.vehicle_id INTO t FROM ops.trip x
   WHERE x.id = p_trip AND EXISTS (SELECT 1 FROM ops.crew_assignment ca WHERE ca.trip_id = x.id AND ca.party_id = sys.ctx_party_id()
                                                                         AND ca.status <> 'RELEASED');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_ASSIGNED: the trip is assigned to another driver' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p_points) IS DISTINCT FROM 'array' OR jsonb_array_length(p_points) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'POSITIONS_INVALID: between 1 and 120 positions' USING ERRCODE = 'P0001';
  END IF;
  SELECT s.device_id INTO dev FROM iam.user_session s WHERE s.id = sys.ctx_session_id();
  SELECT v.ts, v.lat, v.lng, v.seq INTO last FROM ops.vehicle_position v WHERE v.vehicle_id = t.vehicle_id;
  FOR p IN SELECT e.ordinality::int AS i, (e.value->>'ts')::timestamptz AS ts, (e.value->>'lat')::numeric AS lat,
                  (e.value->>'lng')::numeric AS lng, (e.value->>'accuracy_m')::real AS accuracy_m,
                  (e.value->>'speed_kmh')::real AS speed_kmh, e.value->>'provider' AS provider,
                  coalesce((e.value->>'is_mock')::boolean, false) AS is_mock, (e.value->>'device_ts')::timestamptz AS device_ts,
                  (e.value->>'seq')::bigint AS seq
             FROM jsonb_array_elements(p_points) WITH ORDINALITY e LOOP
    -- the previous accepted position: the batch's latest at or before this one, else the vehicle's latest (strictly
    -- earlier, so a batch resent after a failed store is not graded against itself)
    b := NULL;
    FOR j IN 1 .. k LOOP
      IF a_ok[j] AND a_ts[j] <= p.ts AND a_ts[j] > p.ts - interval '1 day' AND (b IS NULL OR a_ts[j] >= a_ts[b]) THEN b := j; END IF;
    END LOOP;
    IF b IS NOT NULL THEN
      prev_ts := a_ts[b]; prev_lat := a_lat[b]; prev_lng := a_lng[b]; prev_seq := a_seq[b];
    ELSIF last.ts IS NOT NULL AND last.ts < p.ts AND last.ts > p.ts - interval '1 day' THEN
      prev_ts := last.ts; prev_lat := last.lat; prev_lng := last.lng; prev_seq := last.seq;
    ELSE
      prev_ts := NULL; prev_lat := NULL; prev_lng := NULL; prev_seq := NULL;
    END IF;
    f := ops.position_flags(p.ts, rcv, p.lat, p.lng, p.accuracy_m, p.provider, p.is_mock, p.device_ts, p.seq, dev,
                            prev_ts, prev_lat, prev_lng, prev_seq);
    g := ops.position_trust(f);
    k := k + 1;
    a_ts[k] := p.ts; a_lat[k] := p.lat; a_lng[k] := p.lng; a_seq[k] := p.seq; a_ok[k] := g <> 'REJECTED';
    a_speed[k] := p.speed_kmh; a_acc[k] := p.accuracy_m; a_trust[k] := g;
    idx := p.i; ts := p.ts; received_at := rcv; trust := g; trust_flags := f;
    company_id := t.company_id; vehicle_id := t.vehicle_id; driver_user_id := sys.ctx_user_id(); device_id := dev;
    RETURN NEXT;
  END LOOP;
  -- the vehicle's latest position: the newest accepted one of the batch, when newer than the one kept
  top := NULL;
  FOR j IN 1 .. k LOOP
    IF a_ok[j] AND (top IS NULL OR a_ts[j] >= a_ts[top]) THEN top := j; END IF;
  END LOOP;
  IF t.vehicle_id IS NOT NULL AND top IS NOT NULL THEN
    INSERT INTO ops.vehicle_position AS v (vehicle_id, trip_id, driver_user_id, ts, lat, lng, speed_kmh, accuracy_m, trust, seq, updated_at)
    VALUES (t.vehicle_id, t.id, sys.ctx_user_id(), a_ts[top], a_lat[top], a_lng[top], a_speed[top], a_acc[top], a_trust[top],
            a_seq[top], now())
    ON CONFLICT (vehicle_id) DO UPDATE
       SET trip_id = EXCLUDED.trip_id, driver_user_id = EXCLUDED.driver_user_id, ts = EXCLUDED.ts, lat = EXCLUDED.lat,
           lng = EXCLUDED.lng, speed_kmh = EXCLUDED.speed_kmh, heading = NULL, accuracy_m = EXCLUDED.accuracy_m,
           trust = EXCLUDED.trust, seq = EXCLUDED.seq, updated_at = now()
     WHERE v.ts < EXCLUDED.ts;
  END IF;
  UPDATE ops.tracking_alert a SET status = 'RESOLVED', resolved_at = now()
   WHERE a.trip_id = t.id AND a.status = 'OPEN' AND a.kind IN ('SIGNAL_LOST', 'TRACKING_OFF');
END $$;
REVOKE ALL ON FUNCTION ops.accept_positions(bigint, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.accept_positions(bigint, jsonb) TO masslak_app;
COMMENT ON FUNCTION ops.accept_positions IS
  'Grades positions of the signed-in driver''s trip, keeps the vehicle''s latest and closes signal alerts; the history goes to the telemetry database (1063)';

-- How long the telemetry database keeps positions, and whether a legal hold stops deleting them (data lifecycle, R-11)
CREATE OR REPLACE FUNCTION ops.position_retention(OUT keep_days integer, OUT held boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT retention_days FROM gov.data_inventory WHERE dataset = 'ops.geo_event'), 7),
         EXISTS (SELECT 1 FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'DATASET' AND dataset = 'ops.geo_event')
$$;
REVOKE ALL ON FUNCTION ops.position_retention() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.position_retention() TO masslak_app;
COMMENT ON FUNCTION ops.position_retention IS 'Retention of vehicle positions and any legal hold, for the telemetry database''s upkeep (1063)';

INSERT INTO sys.schema_migration (version, description)
SELECT '1.42.0', 'Expert review stage D2: vehicle positions in a telemetry database; one set of trust rules for both stores'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.42.0');

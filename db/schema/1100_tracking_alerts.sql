-- =====================================================================
-- Masslak - 1100: the platform opens tracking alerts (a gap found by the review of the use cases, October 2026)
--
-- ops.tracking_alert was read by the carrier's dashboard and closed when positions came back (the driver's location
-- routes, ops.accept_positions), but nothing opened an alert. The worker now calls ops.raise_tracking_alerts() every
-- minute:
--   * a departed trip whose vehicle has sent no position for longer than tracking.alert.silence_seconds gets one open
--     SIGNAL_LOST alert, severity MEDIUM;
--   * when the silence passes tracking.alert.escalate_seconds the alert is escalated, severity HIGH;
--   * each opening and each escalation leaves an outbox event, so the carrier's owners are told (IN_APP and e-mail).
-- The silence counts from the vehicle's latest position on this trip, or from the latest departure recorded at a
-- stop, or from the scheduled departure, whichever is latest. A trip at tracking level STRICT uses half of each
-- threshold. The existing paths keep closing the alert when positions return.
-- =====================================================================

INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('tracking.alert.silence_seconds', '300'::jsonb, 'PLATFORM',
   'Seconds without a position before a departed trip gets a SIGNAL_LOST alert; STRICT trips use half (1100)'),
  ('tracking.alert.escalate_seconds', '900'::jsonb, 'PLATFORM',
   'Seconds without a position before the alert is escalated to the carrier; STRICT trips use half (1100)')
ON CONFLICT (key) DO NOTHING;

-- How long each departed trip has been silent, and the factor of its tracking level
CREATE OR REPLACE FUNCTION ops.trip_silence()
RETURNS TABLE (trip_id bigint, company_id bigint, trip_no text, last_seen timestamptz, silent_seconds integer, factor numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT t.id, t.company_id, t.trip_no, s.last_seen, extract(epoch FROM now() - s.last_seen)::integer,
         CASE WHEN t.tracking_level = 'STRICT' THEN 0.5 ELSE 1 END
    FROM ops.trip t
    CROSS JOIN LATERAL (
      SELECT greatest(
               (SELECT vp.ts FROM ops.vehicle_position vp WHERE vp.vehicle_id = t.vehicle_id AND vp.trip_id = t.id),
               (SELECT max(ts.actual_dep) FROM ops.trip_stop ts WHERE ts.trip_id = t.id),
               t.departure_at) AS last_seen) s
   WHERE t.status = 'DEPARTED'
$$;
REVOKE ALL ON FUNCTION ops.trip_silence() FROM PUBLIC;
COMMENT ON FUNCTION ops.trip_silence IS 'Departed trips with the time since their last sign of life: a position, a recorded departure or the scheduled one (1100)';

CREATE OR REPLACE FUNCTION ops.raise_tracking_alerts() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_silence integer := coalesce((SELECT (value #>> '{}')::integer FROM sys.setting WHERE key = 'tracking.alert.silence_seconds'), 300);
  v_escalate integer := coalesce((SELECT (value #>> '{}')::integer FROM sys.setting WHERE key = 'tracking.alert.escalate_seconds'), 900);
  v_opened integer;
  v_escalated integer;
BEGIN
  WITH opened AS (
    INSERT INTO ops.tracking_alert (trip_id, kind, severity, detail)
    SELECT s.trip_id, 'SIGNAL_LOST', 'MEDIUM', jsonb_build_object('last_seen', s.last_seen, 'silent_seconds', s.silent_seconds)
      FROM ops.trip_silence() s
     WHERE s.silent_seconds > v_silence * s.factor
       AND NOT EXISTS (SELECT 1 FROM ops.tracking_alert a
                        WHERE a.trip_id = s.trip_id AND a.status = 'OPEN' AND a.kind IN ('SIGNAL_LOST', 'TRACKING_OFF'))
    RETURNING id, trip_id, detail),
  told AS (
    INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, company_id, payload)
    SELECT 'tracking.signal_lost', 'trip', o.trip_id, t.company_id,
           jsonb_build_object('alert_id', o.id, 'trip_no', t.trip_no, 'minutes', greatest(1, (o.detail ->> 'silent_seconds')::integer / 60))
      FROM opened o JOIN ops.trip t ON t.id = o.trip_id
    RETURNING 1)
  SELECT count(*) INTO v_opened FROM told;

  WITH escalated AS (
    UPDATE ops.tracking_alert a
       SET escalated = true, severity = 'HIGH',
           detail = coalesce(a.detail, '{}'::jsonb) || jsonb_build_object('escalated_at', now(), 'silent_seconds', s.silent_seconds)
      FROM ops.trip_silence() s
     WHERE a.trip_id = s.trip_id AND a.status = 'OPEN' AND a.kind = 'SIGNAL_LOST' AND NOT a.escalated
       AND s.silent_seconds > v_escalate * s.factor
    RETURNING a.id, a.trip_id, s.silent_seconds),
  told AS (
    INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, company_id, payload)
    SELECT 'tracking.alert_escalated', 'trip', e.trip_id, t.company_id,
           jsonb_build_object('alert_id', e.id, 'trip_no', t.trip_no, 'minutes', e.silent_seconds / 60)
      FROM escalated e JOIN ops.trip t ON t.id = e.trip_id
    RETURNING 1)
  SELECT count(*) INTO v_escalated FROM told;

  RETURN jsonb_build_object('opened', v_opened, 'escalated', v_escalated);
END $$;
REVOKE ALL ON FUNCTION ops.raise_tracking_alerts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.raise_tracking_alerts() TO masslak_app;
COMMENT ON FUNCTION ops.raise_tracking_alerts IS
  'Opens SIGNAL_LOST for departed trips silent past the setting and escalates them; the carrier is told through the outbox (worker, every minute; 1100)';

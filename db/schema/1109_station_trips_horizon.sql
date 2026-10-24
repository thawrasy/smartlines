-- =====================================================================
-- Masslak - 1109: the station's list of trips covers its calendar days (today, tomorrow and the day after, in the
-- station's time zone) instead of a rolling 48 hours, so a trip of the day after tomorrow is on the list at any hour
-- of the night, as on the station's departure board. Trips that left within the last two hours stay listed.
-- =====================================================================

CREATE OR REPLACE FUNCTION brd.station_trips(p_station_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH horizon AS (
    SELECT ((date_trunc('day', now() AT TIME ZONE z) + interval '3 days') AT TIME ZONE z) AS until
      FROM (SELECT coalesce(ref.station_tz(p_station_id), 'UTC') AS z) tz)
  SELECT coalesce(jsonb_agg(x ORDER BY x ->> 'departs_at'), '[]'::jsonb) FROM (
    SELECT jsonb_build_object(
             'trip_uid', t.uid, 'trip_no', t.trip_no, 'carrier', cp.legal_name, 'status', t.status, 'stop_seq', ts.seq,
             'departs_at', coalesce(ts.sched_dep, t.departure_at),
             'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = ts.gate_id),
             'may_check_in', brd.station_actor_may(t.company_id, p_station_id, 'BOARDING_PASS'),
             'may_board', brd.station_actor_may(t.company_id, p_station_id, 'BOARDING'),
             'tickets', (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.from_seq = ts.seq AND k.status IN ('ISSUED','BOARDED')),
             'checked_in', (SELECT count(*) FROM brd.station_checkin c WHERE c.trip_id = t.id AND c.station_id = p_station_id AND c.status = 'CHECKED_IN'),
             'boarded', (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.from_seq = ts.seq AND k.status = 'BOARDED')) AS x
      FROM ops.trip_stop ts JOIN ops.trip t ON t.id = ts.trip_id JOIN iam.party cp ON cp.id = t.company_id, horizon h
     WHERE ts.station_id = p_station_id AND t.status IN ('PUBLISHED','BOARDING')
       AND coalesce(ts.sched_dep, t.departure_at) >= now() - interval '2 hours'
       AND coalesce(ts.sched_dep, t.departure_at) < h.until
       AND (brd.station_actor_may(t.company_id, p_station_id, 'BOARDING_PASS') OR brd.station_actor_may(t.company_id, p_station_id, 'BOARDING'))
     LIMIT 300) y
$$;
REVOKE ALL ON FUNCTION brd.station_trips(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_trips(bigint) TO masslak_app;
COMMENT ON FUNCTION brd.station_trips IS 'Trips leaving a station today, tomorrow and the day after (its time zone) for which the caller may check in or board, with their counts and bay (1105, 1109)';

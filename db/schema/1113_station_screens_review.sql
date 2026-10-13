-- =====================================================================
-- Masslak - 1113: what the station screens show, after their design review of October 2026
-- (docs/design/STATION_SCREENS_REVIEW.md). Fields are added; none is removed or renamed.
--   * The counter's trip list names where each trip goes (its last stop and that stop's city) and when the check-in
--     window of this station opens and closes for it, so the counter shows the check-in state of a trip rather than
--     its sale state. A trip that ends at this station is no longer listed: nothing is sold, checked in or boarded there.
--   * The boarding pass names its ticket (its uid), so the counter prints on it the ticket's signed code (T2) that the
--     bay and the driver's app scan; the code itself is made by the application, as for the passenger's app.
--   * The departure board gives the city codes of the stops on the way next to their names, so the screen names
--     them in its own language, as it already does for the destination.
-- =====================================================================

CREATE OR REPLACE FUNCTION brd.station_trips(p_station_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH horizon AS (
    SELECT ((date_trunc('day', now() AT TIME ZONE z) + interval '3 days') AT TIME ZONE z) AS until
      FROM (SELECT coalesce(ref.station_tz(p_station_id), 'UTC') AS z) tz),
  win AS (                                         -- the check-in window: the station's own, else the platform's (as 1105)
    SELECT coalesce(b.checkin_opens_minutes, (SELECT (value #>> '{}')::integer FROM sys.setting
                                               WHERE key = 'boarding.checkin.opens_minutes' AND jsonb_typeof(value) = 'number')) AS opens,
           coalesce(b.checkin_closes_minutes, (SELECT (value #>> '{}')::integer FROM sys.setting
                                                WHERE key = 'boarding.checkin.closes_minutes' AND jsonb_typeof(value) = 'number')) AS closes
      FROM (SELECT 1) x LEFT JOIN net.station_boarding b ON b.station_id = p_station_id)
  SELECT coalesce(jsonb_agg(x ORDER BY x ->> 'departs_at'), '[]'::jsonb) FROM (
    SELECT jsonb_build_object(
             'trip_uid', t.uid, 'trip_no', t.trip_no, 'carrier', cp.legal_name, 'status', t.status, 'stop_seq', ts.seq,
             'departs_at', coalesce(ts.sched_dep, t.departure_at),
             'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = ts.gate_id),
             'dest_code', ds.code, 'dest_name', ds.name, 'dest_city', dc.code,
             'checkin_opens_at', coalesce(ts.sched_dep, t.departure_at) - make_interval(mins => w.opens),
             'checkin_closes_at', coalesce(ts.sched_dep, t.departure_at) - make_interval(mins => w.closes),
             'may_check_in', brd.station_actor_may(t.company_id, p_station_id, 'BOARDING_PASS'),
             'may_board', brd.station_actor_may(t.company_id, p_station_id, 'BOARDING'),
             'may_sell', sys.ctx_company_id() IS DISTINCT FROM t.company_id AND brd.station_actor_may(t.company_id, p_station_id, 'BOOKING'),
             'tickets', (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.from_seq = ts.seq AND k.status IN ('ISSUED','BOARDED')),
             'checked_in', (SELECT count(*) FROM brd.station_checkin c WHERE c.trip_id = t.id AND c.station_id = p_station_id AND c.status = 'CHECKED_IN'),
             'boarded', (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.from_seq = ts.seq AND k.status = 'BOARDED')) AS x
      FROM ops.trip_stop ts JOIN ops.trip t ON t.id = ts.trip_id JOIN iam.party cp ON cp.id = t.company_id
      JOIN ops.trip_stop zl ON zl.trip_id = t.id AND zl.seq = (SELECT max(z.seq) FROM ops.trip_stop z WHERE z.trip_id = t.id)
      JOIN net.station ds ON ds.id = zl.station_id LEFT JOIN ref.city dc ON dc.id = ds.city_id, horizon h, win w
     WHERE ts.station_id = p_station_id AND ts.seq < zl.seq AND t.status IN ('PUBLISHED','BOARDING')
       AND coalesce(ts.sched_dep, t.departure_at) >= now() - interval '2 hours'
       AND coalesce(ts.sched_dep, t.departure_at) < h.until
       AND (brd.station_actor_may(t.company_id, p_station_id, 'BOARDING_PASS') OR brd.station_actor_may(t.company_id, p_station_id, 'BOARDING')
            OR brd.station_actor_may(t.company_id, p_station_id, 'BOOKING'))
     LIMIT 300) y
$$;
REVOKE ALL ON FUNCTION brd.station_trips(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_trips(bigint) TO masslak_app;
COMMENT ON FUNCTION brd.station_trips IS 'Trips leaving a station today, tomorrow and the day after (its time zone) that the caller may sell, check in or board, with where they go, the check-in window at this station, their counts and bay (1105, 1109, 1110, 1113)';

CREATE OR REPLACE FUNCTION brd.station_board(p_station_uid uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH st AS (
    SELECT s.id, s.code, s.name, coalesce(ref.station_tz(s.id), 'UTC') AS tz,
           coalesce(b.checkin_opens_minutes, (SELECT (value #>> '{}')::integer FROM sys.setting
                                               WHERE key = 'boarding.checkin.opens_minutes' AND jsonb_typeof(value) = 'number')) AS opens,
           coalesce(b.checkin_closes_minutes, (SELECT (value #>> '{}')::integer FROM sys.setting
                                                WHERE key = 'boarding.checkin.closes_minutes' AND jsonb_typeof(value) = 'number')) AS closes
      FROM net.station s JOIN net.station_boarding b ON b.station_id = s.id
     WHERE s.uid = p_station_uid AND s.status = 'ACTIVE' AND b.displays
       AND coalesce((SELECT (value #>> '{}')::boolean FROM sys.setting WHERE key = 'boarding.stations.enabled'), false)),
  stops AS (                                       -- the station's stops on published trips, with the trip's first and last stop
    SELECT t.id AS trip_id, t.trip_no, t.status AS trip_status, cp.legal_name AS carrier, ts.seq, ts.sched_arr, ts.sched_dep,
           ts.actual_arr, ts.actual_dep, ts.gate_id, t.departure_at, t.arrival_at,
           (SELECT min(x.seq) FROM ops.trip_stop x WHERE x.trip_id = t.id) AS first_seq,
           (SELECT max(x.seq) FROM ops.trip_stop x WHERE x.trip_id = t.id) AS last_seq
      FROM st JOIN ops.trip_stop ts ON ts.station_id = st.id JOIN ops.trip t ON t.id = ts.trip_id JOIN iam.party cp ON cp.id = t.company_id
     WHERE t.published_at IS NOT NULL AND t.status IN ('PUBLISHED', 'BOARDING', 'DEPARTED', 'COMPLETED', 'CANCELLED')),
  dep AS (
    SELECT p.*, coalesce(p.sched_dep, p.departure_at) AS at FROM stops p
     WHERE p.seq < p.last_seq
       AND coalesce(p.sched_dep, p.departure_at) >= now() - interval '15 minutes'
       AND coalesce(p.sched_dep, p.departure_at) < now() + interval '12 hours'
     ORDER BY coalesce(p.sched_dep, p.departure_at) LIMIT 60),
  arr AS (
    SELECT p.*, coalesce(p.sched_arr, p.arrival_at) AS at FROM stops p
     WHERE p.seq > p.first_seq
       AND coalesce(p.sched_arr, p.arrival_at) >= now() - interval '30 minutes'
       AND coalesce(p.sched_arr, p.arrival_at) < now() + interval '6 hours'
     ORDER BY coalesce(p.sched_arr, p.arrival_at) LIMIT 40),
  -- up to three cities (or stations without a city) between two stops of a trip, other than the far end, in stop order
  way AS (
    SELECT w.trip_id, w.lo, w.hi, w.far,
           coalesce(jsonb_agg(v.name ORDER BY v.seq), '[]'::jsonb) AS names, coalesce(jsonb_agg(v.code ORDER BY v.seq), '[]'::jsonb) AS codes
      FROM (SELECT trip_id, seq AS lo, last_seq AS hi, last_seq AS far FROM dep
            UNION SELECT trip_id, first_seq, seq, first_seq FROM arr) w
      LEFT JOIN LATERAL (
        SELECT u.seq, u.name, u.code FROM (
          SELECT DISTINCT ON (coalesce(c.id, -s.id)) x.seq, coalesce(c.name, s.name) AS name, c.code
            FROM ops.trip_stop x JOIN net.station s ON s.id = x.station_id LEFT JOIN ref.city c ON c.id = s.city_id
            JOIN ops.trip_stop fx ON fx.trip_id = w.trip_id AND fx.seq = w.far JOIN net.station fs ON fs.id = fx.station_id
           WHERE x.trip_id = w.trip_id AND x.seq > w.lo AND x.seq < w.hi
             AND coalesce(c.id, -s.id) IS DISTINCT FROM coalesce(fs.city_id, -fs.id)
           ORDER BY coalesce(c.id, -s.id), x.seq) u ORDER BY u.seq LIMIT 3) v ON true
     GROUP BY w.trip_id, w.lo, w.hi, w.far)
  SELECT jsonb_build_object(
    'station', jsonb_build_object('code', st.code, 'name', st.name, 'time_zone', st.tz),
    'now', now(),
    'departures', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'trip_no', d.trip_no, 'carrier', d.carrier, 'at', d.at,
               'city', coalesce(dc.name, ds.name), 'city_code', coalesce(dc.code, ds.code),
               'via', coalesce(wy.names, '[]'::jsonb), 'via_codes', coalesce(wy.codes, '[]'::jsonb),
               'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = d.gate_id),
               'status', CASE
                 WHEN d.trip_status = 'CANCELLED' THEN 'CANCELLED'
                 WHEN d.actual_dep IS NOT NULL OR d.trip_status = 'COMPLETED'
                      OR (d.trip_status = 'DEPARTED' AND d.seq = d.first_seq) THEN 'DEPARTED'
                 WHEN (d.trip_status = 'BOARDING' AND d.seq = d.first_seq)
                      OR EXISTS (SELECT 1 FROM sales.ticket k WHERE k.trip_id = d.trip_id AND k.from_seq = d.seq AND k.status = 'BOARDED') THEN 'BOARDING'
                 WHEN st.opens IS NOT NULL AND now() >= d.at - make_interval(mins => st.opens)
                      AND (st.closes IS NULL OR now() <= d.at - make_interval(mins => st.closes)) THEN 'CHECK_IN'
                 ELSE 'SCHEDULED' END) ORDER BY d.at, d.trip_no)
        FROM dep d
        JOIN ops.trip_stop dl ON dl.trip_id = d.trip_id AND dl.seq = d.last_seq
        JOIN net.station ds ON ds.id = dl.station_id LEFT JOIN ref.city dc ON dc.id = ds.city_id
        LEFT JOIN way wy ON wy.trip_id = d.trip_id AND wy.lo = d.seq AND wy.hi = d.last_seq AND wy.far = d.last_seq), '[]'::jsonb),
    'arrivals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'trip_no', a.trip_no, 'carrier', a.carrier, 'at', a.at,
               'city', coalesce(oc.name, os.name), 'city_code', coalesce(oc.code, os.code),
               'via', coalesce(wy.names, '[]'::jsonb), 'via_codes', coalesce(wy.codes, '[]'::jsonb),
               'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = a.gate_id),
               'status', CASE
                 WHEN a.trip_status = 'CANCELLED' THEN 'CANCELLED'
                 WHEN a.actual_arr IS NOT NULL OR a.trip_status = 'COMPLETED' THEN 'ARRIVED'
                 ELSE 'EXPECTED' END) ORDER BY a.at, a.trip_no)
        FROM arr a
        JOIN ops.trip_stop ao ON ao.trip_id = a.trip_id AND ao.seq = a.first_seq
        JOIN net.station os ON os.id = ao.station_id LEFT JOIN ref.city oc ON oc.id = os.city_id
        LEFT JOIN way wy ON wy.trip_id = a.trip_id AND wy.lo = a.first_seq AND wy.hi = a.seq AND wy.far = a.first_seq), '[]'::jsonb))
    FROM st
$$;
REVOKE ALL ON FUNCTION brd.station_board(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_board(uuid) TO masslak_app;
COMMENT ON FUNCTION brd.station_board IS 'The public departure board of a station whose screens the platform switched on: departures of the next 12 hours and arrivals of the next 6, with bays, states and the city codes of the stops on the way, without passenger data; NULL otherwise (1112, 1113)';

CREATE OR REPLACE FUNCTION brd.boarding_pass(p_checkin_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
           'pass_no', c.pass_no, 'status', c.status, 'checked_in_at', c.created_at, 'document_checked', c.document_checked,
           'ticket_uid', k.uid, 'ticket_no', k.ticket_no, 'ticket_status', k.status, 'seat_no', k.seat_no,
           'passenger', btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
           'trip_no', t.trip_no, 'carrier', cp.legal_name,
           'from_station', sa.name, 'from_code', sa.code, 'to_station', sb.name, 'to_code', sb.code,
           'departs_at', coalesce(a.sched_dep, t.departure_at),
           'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = coalesce(a.gate_id, c.bay_gate_id)),
           'counter', (SELECT g.code FROM net.station_gate g WHERE g.id = c.counter_gate_id))
    FROM brd.station_checkin c JOIN sales.ticket k ON k.id = c.ticket_id JOIN sales.passenger p ON p.id = k.passenger_id
    JOIN ops.trip t ON t.id = c.trip_id JOIN iam.party cp ON cp.id = t.company_id
    JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq JOIN net.station sa ON sa.id = a.station_id
    JOIN ops.trip_stop z ON z.trip_id = k.trip_id AND z.seq = k.to_seq JOIN net.station sb ON sb.id = z.station_id
   WHERE c.id = p_checkin_id
     AND (sys.tenant_visible(c.carrier_company_id) OR sys.tenant_visible(c.operator_company_id))   -- the caller's own passes only
$$;
REVOKE ALL ON FUNCTION brd.boarding_pass(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.boarding_pass(bigint) TO masslak_app;   -- the routes read only passes the caller's row security shows
COMMENT ON FUNCTION brd.boarding_pass IS 'What the boarding pass prints: passenger, seat, trip, stations, departure, the bay when assigned, the counter, and its ticket for the signed code (1105, 1113)';

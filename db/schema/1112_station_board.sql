-- =====================================================================
-- Masslak - 1112: the station's departure board (build step 4). The big screen in the station hall shows every
-- departure of the coming hours with its bay and its state (on time, check-in open, boarding, departed, cancelled),
-- and the arrivals. It is public and carries no passenger data: trip numbers, carriers, times, cities and bays only.
-- It shows only while the platform's boarding stations are switched on and the platform has switched the station's
-- screens on (net.station_boarding.displays); otherwise the function answers NULL and the API answers 404.
-- =====================================================================

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
     ORDER BY coalesce(p.sched_arr, p.arrival_at) LIMIT 40)
  SELECT jsonb_build_object(
    'station', jsonb_build_object('code', st.code, 'name', st.name, 'time_zone', st.tz),
    'now', now(),
    'departures', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'trip_no', d.trip_no, 'carrier', d.carrier, 'at', d.at,
               'city', coalesce(dc.name, ds.name), 'city_code', coalesce(dc.code, ds.code),
               'via', coalesce((SELECT jsonb_agg(v.name ORDER BY v.seq) FROM (
                         SELECT u.seq, u.name FROM (
                           SELECT DISTINCT ON (coalesce(c.id, -s.id)) x.seq, coalesce(c.name, s.name) AS name
                             FROM ops.trip_stop x JOIN net.station s ON s.id = x.station_id LEFT JOIN ref.city c ON c.id = s.city_id
                            WHERE x.trip_id = d.trip_id AND x.seq > d.seq AND x.seq < d.last_seq
                              AND coalesce(c.id, -s.id) IS DISTINCT FROM coalesce(dc.id, -ds.id)
                            ORDER BY coalesce(c.id, -s.id), x.seq) u ORDER BY u.seq LIMIT 3) v), '[]'::jsonb),
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
        JOIN net.station ds ON ds.id = dl.station_id LEFT JOIN ref.city dc ON dc.id = ds.city_id), '[]'::jsonb),
    'arrivals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'trip_no', a.trip_no, 'carrier', a.carrier, 'at', a.at,
               'city', coalesce(oc.name, os.name), 'city_code', coalesce(oc.code, os.code),
               'via', coalesce((SELECT jsonb_agg(v.name ORDER BY v.seq) FROM (
                         SELECT u.seq, u.name FROM (
                           SELECT DISTINCT ON (coalesce(c.id, -s.id)) x.seq, coalesce(c.name, s.name) AS name
                             FROM ops.trip_stop x JOIN net.station s ON s.id = x.station_id LEFT JOIN ref.city c ON c.id = s.city_id
                            WHERE x.trip_id = a.trip_id AND x.seq > a.first_seq AND x.seq < a.seq
                              AND coalesce(c.id, -s.id) IS DISTINCT FROM coalesce(oc.id, -os.id)
                            ORDER BY coalesce(c.id, -s.id), x.seq) u ORDER BY u.seq LIMIT 3) v), '[]'::jsonb),
               'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = a.gate_id),
               'status', CASE
                 WHEN a.trip_status = 'CANCELLED' THEN 'CANCELLED'
                 WHEN a.actual_arr IS NOT NULL OR a.trip_status = 'COMPLETED' THEN 'ARRIVED'
                 ELSE 'EXPECTED' END) ORDER BY a.at, a.trip_no)
        FROM arr a
        JOIN ops.trip_stop ao ON ao.trip_id = a.trip_id AND ao.seq = a.first_seq
        JOIN net.station os ON os.id = ao.station_id LEFT JOIN ref.city oc ON oc.id = os.city_id), '[]'::jsonb))
    FROM st
$$;
REVOKE ALL ON FUNCTION brd.station_board(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_board(uuid) TO masslak_app;
COMMENT ON FUNCTION brd.station_board IS 'The public departure board of a station whose screens the platform switched on: departures of the next 12 hours and arrivals of the next 6, with bays and states, without passenger data; NULL otherwise (1112)';

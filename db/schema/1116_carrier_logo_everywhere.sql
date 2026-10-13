-- =====================================================================
-- Masslak - 1116: the carrier's logo next to its name, wherever the name is shown (owner's note, October 2026)
--   The logo belongs to the carrier, not to a trip: the platform adds it once, when it defines the company
--   (iam.company_logo, 1115), and every screen that names the carrier shows it beside the name - search results, the
--   trip and the booking, the ticket and the boarding pass, the counter's trips and sales, the bays page, the board,
--   the support desk, parcels, the cash desk and the platform's lists. iam.logo_version gives the version the screens
--   put in the logo's address (/api/public/companies/{uid}/logo?v=...), so a new logo is fetched at once and an
--   unchanged one comes from the cache; NULL when the company has none, and the name is shown alone.
-- =====================================================================

CREATE OR REPLACE FUNCTION iam.logo_version(p_company_id bigint) RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT pg_catalog.encode(pg_catalog.substr(l.sha256, 1, 6), 'hex') FROM iam.company_logo l WHERE l.company_id = p_company_id
$$;
REVOKE ALL ON FUNCTION iam.logo_version(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.logo_version(bigint) TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION iam.logo_version IS 'The version of a company''s logo (the first six bytes of its SHA-256, in hex) that a screen puts in the logo''s address next to the name; NULL when it has none (1116)';

-- ------------------------------------------------------------------ the station's screens name each carrier with its logo
CREATE OR REPLACE FUNCTION brd.station_bays(p_station_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_until timestamptz;
BEGIN
  IF NOT net.station_bays_by_caller(p_station_id) THEN
    RAISE EXCEPTION 'NOT_STATION_ADMIN: only the station''s administration assigns its bays' USING ERRCODE = 'P0001';
  END IF;
  SELECT (date_trunc('day', now() AT TIME ZONE z) + interval '3 days') AT TIME ZONE z INTO v_until
    FROM (SELECT coalesce(ref.station_tz(p_station_id), 'UTC') AS z) tz;
  RETURN jsonb_build_object(
    'mode', coalesce((SELECT b.bay_mode FROM net.station_boarding b WHERE b.station_id = p_station_id), 'TRIP'),
    'bays', coalesce((SELECT jsonb_agg(jsonb_build_object('code', g.code, 'gate_type', g.gate_type) ORDER BY g.gate_type, g.code)
                        FROM net.station_gate g
                       WHERE g.station_id = p_station_id AND g.gate_type IN ('BAY', 'GATE', 'PLATFORM') AND g.status = 'ACTIVE'), '[]'::jsonb),
    'carriers', coalesce((
      SELECT jsonb_agg(jsonb_build_object('carrier_uid', p.uid, 'carrier', p.legal_name, 'carrier_logo', iam.logo_version(p.id),
                                          'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = cb.gate_id),
                                          'updated_at', cb.updated_at) ORDER BY p.legal_name)
        FROM iam.party p
        LEFT JOIN net.station_carrier_bay cb ON cb.station_id = p_station_id AND cb.carrier_company_id = p.id
       WHERE cb.gate_id IS NOT NULL OR p.id IN (
               SELECT t.company_id FROM ops.trip_stop ts JOIN ops.trip t ON t.id = ts.trip_id
                WHERE ts.station_id = p_station_id AND t.published_at IS NOT NULL
                  AND coalesce(ts.sched_dep, t.departure_at) >= now() - interval '90 days'
                  AND ts.seq < (SELECT max(z.seq) FROM ops.trip_stop z WHERE z.trip_id = t.id))), '[]'::jsonb),
    'trips', coalesce((
      SELECT jsonb_agg(x ORDER BY x ->> 'departs_at', x ->> 'trip_no') FROM (
        SELECT jsonb_build_object(
                 'trip_uid', t.uid, 'trip_no', t.trip_no, 'trip_code', t.trip_code, 'carrier_uid', cp.uid, 'carrier', cp.legal_name,
                 'carrier_logo', iam.logo_version(cp.id), 'status', t.status,
                 'stop_seq', ts.seq, 'departs_at', coalesce(ts.sched_dep, t.departure_at),
                 'dest_code', ds.code, 'dest_name', ds.name, 'dest_city', dc.code,
                 'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = brd.stop_bay_id(t.id, ts.seq)),
                 'trip_bay', (SELECT g.code FROM net.station_gate g WHERE g.id = ts.gate_id),
                 'bay_source', CASE WHEN ts.gate_id IS NOT NULL THEN 'TRIP'
                                    WHEN brd.stop_bay_id(t.id, ts.seq) IS NOT NULL THEN 'CARRIER' END) AS x
          FROM ops.trip_stop ts JOIN ops.trip t ON t.id = ts.trip_id JOIN iam.party cp ON cp.id = t.company_id
          JOIN ops.trip_stop zl ON zl.trip_id = t.id AND zl.seq = (SELECT max(z.seq) FROM ops.trip_stop z WHERE z.trip_id = t.id)
          JOIN net.station ds ON ds.id = zl.station_id LEFT JOIN ref.city dc ON dc.id = ds.city_id
         WHERE ts.station_id = p_station_id AND ts.seq < zl.seq AND t.status IN ('PUBLISHED', 'BOARDING')
           AND coalesce(ts.sched_dep, t.departure_at) >= now() - interval '2 hours'
           AND coalesce(ts.sched_dep, t.departure_at) < v_until
         LIMIT 300) y), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION brd.station_bays(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_bays(bigint) TO masslak_app;
COMMENT ON FUNCTION brd.station_bays IS 'What the station''s administration sees to assign bays: the mode, the open bays, the carriers with their permanent bay, the departures of three days with the bay in force; each carrier with its logo (1115, 1116)';

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
             'trip_uid', t.uid, 'trip_no', t.trip_no, 'trip_code', t.trip_code, 'status', t.status, 'stop_seq', ts.seq,
             'carrier', cp.legal_name, 'carrier_uid', cp.uid, 'carrier_logo', iam.logo_version(cp.id),
             'departs_at', coalesce(ts.sched_dep, t.departure_at),
             'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = brd.stop_bay_id(t.id, ts.seq)),
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
COMMENT ON FUNCTION brd.station_trips IS 'Trips leaving a station today, tomorrow and the day after (its time zone) that the caller may sell, check in or board, with where they go, the check-in window at this station, their counts, the bay in force and the carrier''s logo (1105, 1109, 1110, 1113, 1115, 1116)';

CREATE OR REPLACE FUNCTION brd.boarding_pass(p_checkin_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
           'pass_no', c.pass_no, 'status', c.status, 'checked_in_at', c.created_at, 'document_checked', c.document_checked,
           'ticket_uid', k.uid, 'ticket_no', k.ticket_no, 'ticket_status', k.status, 'seat_no', k.seat_no,
           'passenger', btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
           'trip_no', t.trip_no, 'trip_code', t.trip_code, 'carrier', cp.legal_name, 'carrier_uid', cp.uid, 'carrier_logo', iam.logo_version(cp.id),
           'from_station', sa.name, 'from_code', sa.code, 'to_station', sb.name, 'to_code', sb.code,
           'departs_at', coalesce(a.sched_dep, t.departure_at),
           'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = coalesce(brd.stop_bay_id(k.trip_id, k.from_seq), c.bay_gate_id)),
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
COMMENT ON FUNCTION brd.boarding_pass IS 'What the boarding pass prints: passenger, seat, trip and the carrier''s logo, stations, departure, the bay in force (else the one at check-in), the counter, and its ticket for the signed code (1105, 1113, 1115, 1116)';

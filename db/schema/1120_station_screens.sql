-- =====================================================================
-- 1120  Station display screens: separate Departures and Arrivals screens (owner's decision, October 2026)
-- =====================================================================
-- A station shows its departures and its arrivals on separate screens, each headed with its word ("Departures",
-- "Arrivals") in the languages the board shows in turn (1115). The platform decides which kinds of screen a station
-- may show (net.station_boarding.display_kinds): DEPARTURES, ARRIVALS, and COMBINED, the board with both that the
-- station had before. The station's administration (1115, net.station_boarding.manager_company_id) registers its
-- screens, gives each a kind and a place, and distributes them as it needs: every screen has its own link
-- (/screen/{uid}) that opens its board full screen on the display. A screen reports when it was last seen, so the
-- administration knows which displays are up. The platform does the same where a station has no administration yet.
-- The boards stay public and without passenger data, and only for a station whose screens the platform switched on.

-- ------------------------------------------------------------------ the kinds the platform allows at a station
ALTER TABLE net.station_boarding ADD COLUMN IF NOT EXISTS display_kinds text[] NOT NULL DEFAULT '{DEPARTURES,ARRIVALS,COMBINED}';
ALTER TABLE net.station_boarding DROP CONSTRAINT IF EXISTS station_boarding_display_kinds_check;
ALTER TABLE net.station_boarding ADD CONSTRAINT station_boarding_display_kinds_check
  CHECK (cardinality(display_kinds) >= 1 AND display_kinds <@ ARRAY['DEPARTURES', 'ARRIVALS', 'COMBINED']::text[]);
COMMENT ON COLUMN net.station_boarding.display_kinds IS 'The kinds of screen the platform allows at the station: DEPARTURES, ARRIVALS, COMBINED (both on one board) (1120)';

-- ------------------------------------------------------------------ the screens of a station
CREATE TABLE IF NOT EXISTS net.station_screen (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  station_id          bigint NOT NULL REFERENCES net.station(id),
  kind                text NOT NULL CHECK (kind IN ('DEPARTURES', 'ARRIVALS', 'COMBINED')),
  label               text NOT NULL CHECK (length(btrim(label)) BETWEEN 1 AND 60),
  active              boolean NOT NULL DEFAULT true,
  last_seen_at        timestamptz,
  created_by_user_id  bigint REFERENCES iam.app_user(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_by_user_id  bigint REFERENCES iam.app_user(id),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (station_id, label)
);
CREATE INDEX IF NOT EXISTS station_screen_created_by_user_id_fkx ON net.station_screen (created_by_user_id);
CREATE INDEX IF NOT EXISTS station_screen_updated_by_user_id_fkx ON net.station_screen (updated_by_user_id);
COMMENT ON TABLE net.station_screen IS 'A display screen of a station: its kind (departures, arrivals or both), its place, and when it was last seen; registered by the station''s administration (1120)';
COMMENT ON COLUMN net.station_screen.uid IS 'The screen''s own link (/screen/{uid}); whoever holds it sees the public board of that screen';
COMMENT ON COLUMN net.station_screen.label IS 'Where the screen is, as the station names it (hall, gate, entrance)';
COMMENT ON COLUMN net.station_screen.last_seen_at IS 'When the screen last read its board, to the minute';
SELECT sys.rls_platform('net.station_screen');
GRANT SELECT ON net.station_screen TO masslak_app;              -- written by the functions below only
GRANT SELECT ON net.station_screen TO masslak_readonly;
DROP TRIGGER IF EXISTS zz_audit_capture ON net.station_screen;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR DELETE OR UPDATE OF kind, label, active ON net.station_screen
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();     -- the screen reading its board is not a change

-- whether the platform allows a kind of screen at a station
CREATE OR REPLACE FUNCTION net.screen_kind_allowed(p_station_id bigint, p_kind text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT p_kind = ANY(coalesce((SELECT b.display_kinds FROM net.station_boarding b WHERE b.station_id = p_station_id),
                               ARRAY['DEPARTURES', 'ARRIVALS', 'COMBINED']::text[]))
$$;

-- what the administration sees: whether the boards are on, the kinds allowed, and the screens
CREATE OR REPLACE FUNCTION net.station_screens(p_station_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT net.station_bays_by_caller(p_station_id) THEN
    RAISE EXCEPTION 'NOT_STATION_ADMIN: only the station''s administration registers its screens' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object(
    'boards_on', coalesce((SELECT (value #>> '{}')::boolean FROM sys.setting WHERE key = 'boarding.stations.enabled'), false),
    'displays', coalesce((SELECT b.displays FROM net.station_boarding b WHERE b.station_id = p_station_id), false),
    'kinds', to_jsonb(coalesce((SELECT b.display_kinds FROM net.station_boarding b WHERE b.station_id = p_station_id),
                               ARRAY['DEPARTURES', 'ARRIVALS', 'COMBINED']::text[])),
    'screens', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'uid', sc.uid, 'kind', sc.kind, 'label', sc.label, 'active', sc.active,
               'allowed', net.screen_kind_allowed(p_station_id, sc.kind),
               'last_seen_at', sc.last_seen_at, 'online', coalesce(sc.last_seen_at >= now() - interval '2 minutes', false),
               'created_at', sc.created_at, 'updated_at', sc.updated_at)
             ORDER BY array_position(ARRAY['DEPARTURES', 'ARRIVALS', 'COMBINED']::text[], sc.kind), sc.label)
        FROM net.station_screen sc WHERE sc.station_id = p_station_id), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION net.screen_label_problem(p_label text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN p_label IS NULL OR length(btrim(p_label)) NOT BETWEEN 1 AND 60
              THEN 'SCREEN_LABEL_INVALID: a screen is named by its place, 1 to 60 characters' END
$$;

-- a new screen; its link is its uid
CREATE OR REPLACE FUNCTION net.add_station_screen(p_station_id bigint, p_kind text, p_label text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_problem text; v_uid uuid;
BEGIN
  IF NOT net.station_bays_by_caller(p_station_id) THEN
    RAISE EXCEPTION 'NOT_STATION_ADMIN: only the station''s administration registers its screens' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('DEPARTURES', 'ARRIVALS', 'COMBINED') THEN
    RAISE EXCEPTION 'SCREEN_KIND_INVALID: a screen shows the departures, the arrivals, or both' USING ERRCODE = 'P0001';
  END IF;
  IF NOT net.screen_kind_allowed(p_station_id, p_kind) THEN
    RAISE EXCEPTION 'SCREEN_KIND_NOT_ALLOWED: the platform does not show % screens at this station', p_kind USING ERRCODE = 'P0001';
  END IF;
  v_problem := net.screen_label_problem(p_label);
  IF v_problem IS NOT NULL THEN
    RAISE EXCEPTION '%', v_problem USING ERRCODE = 'P0001';
  END IF;
  PERFORM 1 FROM net.station WHERE id = p_station_id FOR UPDATE;        -- one count at a time
  IF (SELECT count(*) FROM net.station_screen WHERE station_id = p_station_id) >= 200 THEN
    RAISE EXCEPTION 'SCREENS_LIMIT: a station has at most 200 screens' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM net.station_screen WHERE station_id = p_station_id AND lower(label) = lower(btrim(p_label))) THEN
    RAISE EXCEPTION 'SCREEN_LABEL_TAKEN: the station already has a screen named %', btrim(p_label) USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO net.station_screen (station_id, kind, label, created_by_user_id, updated_by_user_id)
  VALUES (p_station_id, p_kind, btrim(p_label), sys.ctx_user_id(), sys.ctx_user_id())
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- change a screen's kind, place or state; null leaves it as it is
CREATE OR REPLACE FUNCTION net.change_station_screen(p_screen_uid uuid, p_kind text, p_label text, p_active boolean)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_screen net.station_screen%ROWTYPE; v_problem text;
BEGIN
  SELECT * INTO v_screen FROM net.station_screen WHERE uid = p_screen_uid FOR UPDATE;
  IF NOT FOUND OR NOT net.station_bays_by_caller(v_screen.station_id) THEN
    RAISE EXCEPTION 'SCREEN_UNKNOWN: no such screen at a station you administer' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind IS NOT NULL AND p_kind <> v_screen.kind THEN
    IF p_kind NOT IN ('DEPARTURES', 'ARRIVALS', 'COMBINED') THEN
      RAISE EXCEPTION 'SCREEN_KIND_INVALID: a screen shows the departures, the arrivals, or both' USING ERRCODE = 'P0001';
    END IF;
    IF NOT net.screen_kind_allowed(v_screen.station_id, p_kind) THEN
      RAISE EXCEPTION 'SCREEN_KIND_NOT_ALLOWED: the platform does not show % screens at this station', p_kind USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF p_label IS NOT NULL THEN
    v_problem := net.screen_label_problem(p_label);
    IF v_problem IS NOT NULL THEN
      RAISE EXCEPTION '%', v_problem USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM net.station_screen WHERE station_id = v_screen.station_id AND id <> v_screen.id
                                                   AND lower(label) = lower(btrim(p_label))) THEN
      RAISE EXCEPTION 'SCREEN_LABEL_TAKEN: the station already has a screen named %', btrim(p_label) USING ERRCODE = 'P0001';
    END IF;
  END IF;
  UPDATE net.station_screen
     SET kind = coalesce(p_kind, kind), label = coalesce(btrim(p_label), label), active = coalesce(p_active, active),
         updated_by_user_id = sys.ctx_user_id(), updated_at = now()
   WHERE id = v_screen.id;
  RETURN v_screen.station_id;
END $$;

-- a screen taken down for good; its link stops working
CREATE OR REPLACE FUNCTION net.remove_station_screen(p_screen_uid uuid) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_station bigint;
BEGIN
  SELECT station_id INTO v_station FROM net.station_screen WHERE uid = p_screen_uid;
  IF v_station IS NULL OR NOT net.station_bays_by_caller(v_station) THEN
    RAISE EXCEPTION 'SCREEN_UNKNOWN: no such screen at a station you administer' USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM net.station_screen WHERE uid = p_screen_uid;
  RETURN v_station;
END $$;

REVOKE ALL ON FUNCTION net.screen_kind_allowed(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.station_screens(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.screen_label_problem(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.add_station_screen(bigint, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.change_station_screen(uuid, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.remove_station_screen(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.screen_kind_allowed(bigint, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.station_screens(bigint) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.screen_label_problem(text) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.add_station_screen(bigint, text, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.change_station_screen(uuid, text, text, boolean) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.remove_station_screen(uuid) TO masslak_app;
COMMENT ON FUNCTION net.screen_kind_allowed IS 'Whether the platform allows a kind of screen (departures, arrivals, both) at a station (1120)';
COMMENT ON FUNCTION net.station_screens IS 'What the station''s administration sees of its screens: whether the boards are on, the kinds the platform allows, each screen with its kind, place, state and when it was last seen (1120)';
COMMENT ON FUNCTION net.screen_label_problem IS 'Why a screen''s place is refused, or null (1120)';
COMMENT ON FUNCTION net.add_station_screen IS 'The station''s administration registers a screen of an allowed kind at a place; its uid is its link (1120)';
COMMENT ON FUNCTION net.change_station_screen IS 'The station''s administration changes a screen''s kind, place or state (1120)';
COMMENT ON FUNCTION net.remove_station_screen IS 'The station''s administration takes a screen down for good; its link stops working (1120)';

-- ------------------------------------------------------------------ the board of one kind
-- The board as before (1115), for one kind: DEPARTURES leaves the arrivals out, ARRIVALS the departures, COMBINED shows
-- both. A kind the platform does not allow at the station answers NULL, as a station whose screens are off.
DROP FUNCTION IF EXISTS brd.station_board(uuid);
CREATE OR REPLACE FUNCTION brd.station_board(p_station_uid uuid, p_kind text DEFAULT 'COMBINED') RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH st AS (
    SELECT s.id, s.code, s.name, coalesce(ref.station_tz(s.id), 'UTC') AS tz,
           coalesce(b.checkin_opens_minutes, (SELECT (value #>> '{}')::integer FROM sys.setting
                                               WHERE key = 'boarding.checkin.opens_minutes' AND jsonb_typeof(value) = 'number')) AS opens,
           coalesce(b.checkin_closes_minutes, (SELECT (value #>> '{}')::integer FROM sys.setting
                                                WHERE key = 'boarding.checkin.closes_minutes' AND jsonb_typeof(value) = 'number')) AS closes
      FROM net.station s JOIN net.station_boarding b ON b.station_id = s.id
     WHERE s.uid = p_station_uid AND s.status = 'ACTIVE' AND b.displays AND p_kind = ANY(b.display_kinds)
       AND coalesce((SELECT (value #>> '{}')::boolean FROM sys.setting WHERE key = 'boarding.stations.enabled'), false)),
  stops AS (                                       -- the station's stops on published trips, with the trip's first and last stop
    SELECT t.id AS trip_id, t.trip_no, t.trip_code, t.status AS trip_status, cp.legal_name AS carrier, cp.uid AS carrier_uid,
           (SELECT encode(substr(l.sha256, 1, 6), 'hex') FROM iam.company_logo l WHERE l.company_id = t.company_id) AS carrier_logo,
           ts.seq, ts.sched_arr, ts.sched_dep, ts.actual_arr, ts.actual_dep, brd.stop_bay_id(t.id, ts.seq) AS gate_id,
           t.departure_at, t.arrival_at,
           (SELECT min(x.seq) FROM ops.trip_stop x WHERE x.trip_id = t.id) AS first_seq,
           (SELECT max(x.seq) FROM ops.trip_stop x WHERE x.trip_id = t.id) AS last_seq
      FROM st JOIN ops.trip_stop ts ON ts.station_id = st.id JOIN ops.trip t ON t.id = ts.trip_id JOIN iam.party cp ON cp.id = t.company_id
     WHERE t.published_at IS NOT NULL AND t.status IN ('PUBLISHED', 'BOARDING', 'DEPARTED', 'COMPLETED', 'CANCELLED')),
  dep AS (
    SELECT p.*, coalesce(p.sched_dep, p.departure_at) AS at FROM stops p
     WHERE p_kind <> 'ARRIVALS' AND p.seq < p.last_seq
       AND coalesce(p.sched_dep, p.departure_at) >= now() - interval '15 minutes'
       AND coalesce(p.sched_dep, p.departure_at) < now() + interval '12 hours'
     ORDER BY coalesce(p.sched_dep, p.departure_at) LIMIT 60),
  arr AS (
    SELECT p.*, coalesce(p.sched_arr, p.arrival_at) AS at FROM stops p
     WHERE p_kind <> 'DEPARTURES' AND p.seq > p.first_seq
       AND coalesce(p.sched_arr, p.arrival_at) >= now() - interval '30 minutes'
       AND coalesce(p.sched_arr, p.arrival_at) < now() + interval '6 hours'
     ORDER BY coalesce(p.sched_arr, p.arrival_at) LIMIT CASE WHEN p_kind = 'ARRIVALS' THEN 60 ELSE 40 END),
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
     GROUP BY w.trip_id, w.lo, w.hi, w.far),
  lang AS (                                        -- the board's languages and how long each stays (1115)
    SELECT coalesce((SELECT value FROM sys.setting WHERE key = 'boarding.board.languages' AND jsonb_typeof(value) = 'array'),
                    '["ar","en"]'::jsonb) AS languages,
           coalesce((SELECT (value #>> '{}')::integer FROM sys.setting
                      WHERE key = 'boarding.board.rotate_seconds' AND jsonb_typeof(value) = 'number'), 10) AS rotate_seconds)
  SELECT jsonb_build_object(
    'station', jsonb_build_object('code', st.code, 'name', st.name, 'time_zone', st.tz),
    'kind', p_kind,
    'now', now(),
    'languages', lang.languages, 'rotate_seconds', lang.rotate_seconds,
    'departures', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'trip_no', d.trip_no, 'trip_code', d.trip_code, 'carrier', d.carrier, 'carrier_uid', d.carrier_uid, 'carrier_logo', d.carrier_logo, 'at', d.at,
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
               'trip_no', a.trip_no, 'trip_code', a.trip_code, 'carrier', a.carrier, 'carrier_uid', a.carrier_uid, 'carrier_logo', a.carrier_logo, 'at', a.at,
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
    FROM st, lang
$$;
REVOKE ALL ON FUNCTION brd.station_board(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_board(uuid, text) TO masslak_app;
COMMENT ON FUNCTION brd.station_board IS 'The public board of a station whose screens the platform switched on, for one kind it allows: departures of the next 12 hours, arrivals of the next 6, or both, with the bay in force, states, carriers'' logos, the city codes of the stops on the way and the languages shown in turn, without passenger data; NULL otherwise (1112, 1113, 1115, 1120)';

-- the board of one screen, by its link; the screen is seen (to the minute) even while it shows nothing
CREATE OR REPLACE FUNCTION brd.screen_board(p_screen_uid uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v record; v_board jsonb;
BEGIN
  SELECT sc.id, sc.uid, sc.kind, sc.label, sc.active, s.uid AS station_uid INTO v
    FROM net.station_screen sc JOIN net.station s ON s.id = sc.station_id WHERE sc.uid = p_screen_uid;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  UPDATE net.station_screen SET last_seen_at = date_trunc('minute', now())
   WHERE id = v.id AND (last_seen_at IS NULL OR last_seen_at < date_trunc('minute', now()));
  IF NOT v.active THEN
    RETURN NULL;
  END IF;
  v_board := brd.station_board(v.station_uid, v.kind);
  IF v_board IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN v_board || jsonb_build_object('screen', jsonb_build_object('uid', v.uid, 'kind', v.kind, 'label', v.label));
END $$;
REVOKE ALL ON FUNCTION brd.screen_board(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.screen_board(uuid) TO masslak_app;
COMMENT ON FUNCTION brd.screen_board IS 'The public board of one screen by its link: its kind''s board with the screen''s kind and place; NULL for an unknown or stopped screen, a kind the platform no longer allows, or a station whose screens are off; marks the screen seen (1120)';

-- ------------------------------------------------------------------ the permission of the administration's staff
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('station.screens', 'station', 'COMPANY', 'Register the display screens of a station the company administers: each screen''s kind (departures, arrivals or both) and place', false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role (code, name, scope, is_system)
SELECT 'STATION_SCREENS', 'Station screens officer (template)', 'COMPANY', true
 WHERE NOT EXISTS (SELECT 1 FROM iam.role WHERE code = 'STATION_SCREENS' AND company_id IS NULL);
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'station.screens' FROM iam.role r WHERE r.code = 'STATION_SCREENS' AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('net.station_screen', '1B', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('net.station_screen', 'PLATFORM_CONFIDENTIAL', 'the platform reads; the station''s administration through its functions',
   'the display screens of stations, each with its link (1120)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.station_screen', 'net records', 'the display screens of stations (1120)')
ON CONFLICT (table_name) DO NOTHING;

-- =====================================================================
-- Masslak - 1115: the owner's decisions on the station screens (October 2026; docs/design/STATION_SCREENS_REVIEW.md)
--   * Bays are assigned by the station's administration: the operating company the platform designates for a station
--     (net.station_boarding.manager_company_id). It chooses how (bay_mode): CARRIER, a permanent bay for each carrier at
--     the station (net.station_carrier_bay), which it can change at any time; or TRIP, a bay for each trip. A bay set on a
--     trip's stop (ops.trip_stop.gate_id) is used first in either mode; in CARRIER mode the carrier's bay applies when
--     the trip has none. brd.stop_bay_id gives the bay in force, which the counter's trips, the boarding pass and the
--     departure board read. The platform may do the same where a station has no administration yet.
--   * A company's logo, added by the platform when it defines the company, to a specification the application checks
--     (a PNG it re-encodes, 120 to 240 pixels high and one to four times as wide), shown next to the company's name on
--     the departure board and in search results (iam.company_logo; public, like the name).
--   * The departure board shows its languages in turn (decision O2): boarding.board.languages (["ar","en"], the first
--     also sets the layout) and boarding.board.rotate_seconds (10), returned with the board.
-- The driver's boarding by ticket number and booking reference (decision O1) needs no table: it uses brd.ticket_uid (1105).
-- =====================================================================

-- ------------------------------------------------------------------ the board's languages
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('boarding.board.languages', '["ar","en"]'::jsonb, 'PLATFORM',
   'Languages the departure board shows in turn, the first also setting its layout (1115, owner''s decision O2)'),
  ('boarding.board.rotate_seconds', '10'::jsonb, 'PLATFORM',
   'Seconds each language of the departure board stays on screen (1115)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION net.set_boarding_setting(p_key text, p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_other jsonb; v_opens integer; v_closes integer;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: boarding stations are a platform task' USING ERRCODE = 'P0001';
  END IF;
  IF p_key IN ('boarding.stations.enabled', 'boarding.mode.state_mandated', 'boarding.mode.carrier_contracted') THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'INVALID_SETTING: % is true or false', p_key USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_key IN ('boarding.checkin.opens_minutes', 'boarding.checkin.closes_minutes') THEN
    IF p_value <> 'null'::jsonb AND NOT (CASE WHEN jsonb_typeof(p_value) = 'number' AND (p_value #>> '{}') ~ '^[0-9]{1,4}$'
                                              THEN (p_value #>> '{}')::integer <= 1440 ELSE false END) THEN
      RAISE EXCEPTION 'INVALID_SETTING: % is a whole number of minutes up to 1440, or null', p_key USING ERRCODE = 'P0001';
    END IF;
    v_other := coalesce((SELECT value FROM sys.setting WHERE key = CASE WHEN p_key = 'boarding.checkin.opens_minutes'
                           THEN 'boarding.checkin.closes_minutes' ELSE 'boarding.checkin.opens_minutes' END), 'null'::jsonb);
    IF p_value <> 'null'::jsonb AND v_other <> 'null'::jsonb THEN
      v_opens  := CASE WHEN p_key = 'boarding.checkin.opens_minutes' THEN (p_value #>> '{}')::integer ELSE (v_other #>> '{}')::integer END;
      v_closes := CASE WHEN p_key = 'boarding.checkin.closes_minutes' THEN (p_value #>> '{}')::integer ELSE (v_other #>> '{}')::integer END;
      IF v_opens <= v_closes THEN
        RAISE EXCEPTION 'INVALID_SETTING: the check-in opens more minutes before departure than it closes' USING ERRCODE = 'P0001';
      END IF;
    END IF;
  ELSIF p_key = 'boarding.references.required' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'array' OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_value) e
         WHERE jsonb_typeof(e) IS DISTINCT FROM 'string' OR length(e #>> '{}') NOT BETWEEN 1 AND 60) THEN
      RAISE EXCEPTION 'INVALID_SETTING: the required references are a list of codes of 1 to 60 characters' USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_key = 'boarding.board.languages' THEN
    IF (CASE WHEN jsonb_typeof(p_value) IS DISTINCT FROM 'array' THEN true
             ELSE jsonb_array_length(p_value) NOT BETWEEN 1 AND 2
                  OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_value) e
                              WHERE jsonb_typeof(e) IS DISTINCT FROM 'string' OR e #>> '{}' NOT IN ('ar', 'en'))
                  OR (SELECT count(DISTINCT e #>> '{}') FROM jsonb_array_elements(p_value) e) <> jsonb_array_length(p_value) END) THEN
      RAISE EXCEPTION 'INVALID_SETTING: the board shows ar, en or both, each once' USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_key = 'boarding.board.rotate_seconds' THEN
    IF NOT (CASE WHEN jsonb_typeof(p_value) = 'number' AND (p_value #>> '{}') ~ '^[0-9]{1,2}$'
                 THEN (p_value #>> '{}')::integer BETWEEN 5 AND 60 ELSE false END) THEN
      RAISE EXCEPTION 'INVALID_SETTING: each language stays 5 to 60 seconds' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    RAISE EXCEPTION 'INVALID_SETTING: % is not a boarding setting', p_key USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
  VALUES (p_key, p_value, 'PLATFORM', 'Boarding stations setting (1097)', sys.ctx_user_id(), now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  RETURN p_value;
END $$;
REVOKE ALL ON FUNCTION net.set_boarding_setting(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.set_boarding_setting(text, jsonb) TO masslak_app;

-- ------------------------------------------------------------------ a company's logo, defined by the platform
CREATE TABLE IF NOT EXISTS iam.company_logo (
  company_id   bigint PRIMARY KEY REFERENCES iam.company(id),
  image        bytea NOT NULL CHECK (octet_length(image) BETWEEN 67 AND 524288),
  mime_type    text NOT NULL DEFAULT 'image/png' CHECK (mime_type = 'image/png'),
  width        integer NOT NULL,
  height       integer NOT NULL CHECK (height BETWEEN 120 AND 240),
  sha256       bytea NOT NULL CHECK (octet_length(sha256) = 32),
  uploaded_by  bigint NOT NULL REFERENCES iam.app_user(id),
  uploaded_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (width BETWEEN height AND 4 * height)
);
CREATE INDEX IF NOT EXISTS company_logo_uploaded_by_fkx ON iam.company_logo (uploaded_by);
COMMENT ON TABLE iam.company_logo IS 'A company''s logo, set by the platform when it defines the company: a PNG the application re-encodes to its specification, public like the name (1115)';
SELECT sys.rls_catalog('iam.company_logo');
GRANT SELECT, INSERT, UPDATE ON iam.company_logo TO masslak_app;   -- removed by iam.remove_company_logo only
GRANT SELECT ON iam.company_logo TO masslak_readonly;

CREATE OR REPLACE FUNCTION iam.remove_company_logo(p_company_id bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: a company''s logo is set by the platform' USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM iam.company_logo WHERE company_id = p_company_id;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION iam.remove_company_logo(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.remove_company_logo(bigint) TO masslak_app;
COMMENT ON FUNCTION iam.remove_company_logo IS 'The platform removes a company''s logo; the name is shown alone again (1115)';

-- ------------------------------------------------------------------ the station's administration and how it assigns bays
ALTER TABLE net.station_boarding ADD COLUMN IF NOT EXISTS manager_company_id bigint REFERENCES iam.company(id);
ALTER TABLE net.station_boarding ADD COLUMN IF NOT EXISTS bay_mode text NOT NULL DEFAULT 'TRIP' CHECK (bay_mode IN ('CARRIER', 'TRIP'));
CREATE INDEX IF NOT EXISTS station_boarding_manager_company_id_fkx ON net.station_boarding (manager_company_id);
COMMENT ON COLUMN net.station_boarding.manager_company_id IS 'The station''s administration: the operating company the platform designated to assign its bays (1115)';
COMMENT ON COLUMN net.station_boarding.bay_mode IS 'CARRIER: a permanent bay for each carrier, changed by the administration; TRIP: a bay for each trip (1115)';

-- the administration is a station operating company
CREATE OR REPLACE FUNCTION net.tg_station_manager() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.manager_company_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM iam.company c WHERE c.id = NEW.manager_company_id AND c.company_type = 'STATION_OPERATOR') THEN
    RAISE EXCEPTION 'NOT_STATION_OPERATOR: a station is administered by a station operating company' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS station_manager_check ON net.station_boarding;
CREATE TRIGGER station_manager_check BEFORE INSERT OR UPDATE OF manager_company_id ON net.station_boarding
  FOR EACH ROW EXECUTE FUNCTION net.tg_station_manager();

CREATE TABLE IF NOT EXISTS net.station_carrier_bay (
  station_id          bigint NOT NULL REFERENCES net.station(id),
  carrier_company_id  bigint NOT NULL REFERENCES iam.company(id),
  gate_id             bigint NOT NULL REFERENCES net.station_gate(id),
  set_by_user_id      bigint REFERENCES iam.app_user(id),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (station_id, carrier_company_id)
);
CREATE INDEX IF NOT EXISTS station_carrier_bay_carrier_company_id_fkx ON net.station_carrier_bay (carrier_company_id);
CREATE INDEX IF NOT EXISTS station_carrier_bay_gate_id_fkx ON net.station_carrier_bay (gate_id);
CREATE INDEX IF NOT EXISTS station_carrier_bay_set_by_user_id_fkx ON net.station_carrier_bay (set_by_user_id);
COMMENT ON TABLE net.station_carrier_bay IS 'The permanent bay of a carrier at a station, set and changed by the station''s administration (1115); public like the bays';
SELECT sys.rls_catalog('net.station_carrier_bay');
GRANT SELECT ON net.station_carrier_bay TO masslak_app;       -- written by net.set_carrier_bay only
GRANT SELECT ON net.station_carrier_bay TO masslak_readonly;

-- who runs a station's bays: its administration, or the platform
CREATE OR REPLACE FUNCTION net.station_bays_by_caller(p_station_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT sys.ctx_is_platform() OR (sys.ctx_company_id() IS NOT NULL AND EXISTS (
           SELECT 1 FROM net.station_boarding b WHERE b.station_id = p_station_id AND b.manager_company_id = sys.ctx_company_id()))
$$;

-- an open bay, gate or platform of the station, by its code
CREATE OR REPLACE FUNCTION net.station_bay_id(p_station_id bigint, p_code text) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT g.id FROM net.station_gate g
   WHERE g.station_id = p_station_id AND g.code = upper(btrim(p_code)) AND g.gate_type IN ('BAY', 'GATE', 'PLATFORM') AND g.status = 'ACTIVE'
$$;

CREATE OR REPLACE FUNCTION net.set_station_bay_mode(p_station_id bigint, p_mode text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT net.station_bays_by_caller(p_station_id) THEN
    RAISE EXCEPTION 'NOT_STATION_ADMIN: only the station''s administration assigns its bays' USING ERRCODE = 'P0001';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('CARRIER', 'TRIP') THEN
    RAISE EXCEPTION 'INVALID_SETTING: the bays are assigned per carrier (CARRIER) or per trip (TRIP)' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO net.station_boarding (station_id, bay_mode, updated_by_user_id, updated_at)
  VALUES (p_station_id, p_mode, sys.ctx_user_id(), now())
  ON CONFLICT (station_id) DO UPDATE SET bay_mode = excluded.bay_mode, updated_by_user_id = excluded.updated_by_user_id,
                                         updated_at = excluded.updated_at;
  RETURN p_mode;
END $$;

-- a carrier's permanent bay; null removes it
CREATE OR REPLACE FUNCTION net.set_carrier_bay(p_station_id bigint, p_carrier_uid uuid, p_code text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_gate bigint; v_carrier_id bigint;
BEGIN
  IF NOT net.station_bays_by_caller(p_station_id) THEN
    RAISE EXCEPTION 'NOT_STATION_ADMIN: only the station''s administration assigns its bays' USING ERRCODE = 'P0001';
  END IF;
  SELECT c.id INTO v_carrier_id FROM iam.party p JOIN iam.company c ON c.id = p.id
   WHERE p.uid = p_carrier_uid AND c.company_type IN ('CARRIER', 'INDIVIDUAL_OPERATOR', 'FOREIGN_CARRIER');
  IF v_carrier_id IS NULL THEN
    RAISE EXCEPTION 'NOT_A_CARRIER: a permanent bay is given to a carrier' USING ERRCODE = 'P0001';
  END IF;
  IF p_code IS NULL OR btrim(p_code) = '' THEN
    DELETE FROM net.station_carrier_bay WHERE station_id = p_station_id AND carrier_company_id = v_carrier_id;
    RETURN NULL;
  END IF;
  v_gate := net.station_bay_id(p_station_id, p_code);
  IF v_gate IS NULL THEN
    RAISE EXCEPTION 'BAY_UNKNOWN: % is not an open bay of this station', p_code USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO net.station_carrier_bay (station_id, carrier_company_id, gate_id, set_by_user_id, updated_at)
  VALUES (p_station_id, v_carrier_id, v_gate, sys.ctx_user_id(), now())
  ON CONFLICT (station_id, carrier_company_id) DO UPDATE SET gate_id = excluded.gate_id, set_by_user_id = excluded.set_by_user_id,
                                                             updated_at = excluded.updated_at;
  RETURN upper(btrim(p_code));
END $$;

-- the bay of one trip at one of its stops; null clears it (the carrier's permanent bay applies again in CARRIER mode)
CREATE OR REPLACE FUNCTION brd.assign_trip_bay(p_trip_uid uuid, p_seq integer, p_code text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_station bigint; v_gate bigint; v_trip_id bigint;
BEGIN
  SELECT ts.station_id, t.id INTO v_station, v_trip_id
    FROM ops.trip_stop ts JOIN ops.trip t ON t.id = ts.trip_id
   WHERE t.uid = p_trip_uid AND ts.seq = p_seq AND t.status IN ('PUBLISHED', 'BOARDING')
     AND ts.seq < (SELECT max(z.seq) FROM ops.trip_stop z WHERE z.trip_id = t.id);
  IF v_station IS NULL THEN
    RAISE EXCEPTION 'TRIP_NOT_OPEN: the trip does not stop here or has left' USING ERRCODE = 'P0001';
  END IF;
  IF NOT net.station_bays_by_caller(v_station) THEN
    RAISE EXCEPTION 'NOT_STATION_ADMIN: only the station''s administration assigns its bays' USING ERRCODE = 'P0001';
  END IF;
  IF p_code IS NULL OR btrim(p_code) = '' THEN
    UPDATE ops.trip_stop SET gate_id = NULL WHERE trip_id = v_trip_id AND seq = p_seq;
    RETURN NULL;
  END IF;
  v_gate := net.station_bay_id(v_station, p_code);
  IF v_gate IS NULL THEN
    RAISE EXCEPTION 'BAY_UNKNOWN: % is not an open bay of this station', p_code USING ERRCODE = 'P0001';
  END IF;
  UPDATE ops.trip_stop SET gate_id = v_gate WHERE trip_id = v_trip_id AND seq = p_seq;
  RETURN upper(btrim(p_code));
END $$;

-- the bay in force at a stop: the trip's own, else (in CARRIER mode) the carrier's permanent bay at the station
CREATE OR REPLACE FUNCTION brd.stop_bay_id(p_trip_id bigint, p_seq integer) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(ts.gate_id, CASE WHEN b.bay_mode = 'CARRIER' THEN cb.gate_id END)
    FROM ops.trip_stop ts JOIN ops.trip t ON t.id = ts.trip_id
    LEFT JOIN net.station_boarding b ON b.station_id = ts.station_id
    LEFT JOIN net.station_carrier_bay cb ON cb.station_id = ts.station_id AND cb.carrier_company_id = t.company_id
   WHERE ts.trip_id = p_trip_id AND ts.seq = p_seq
$$;

REVOKE ALL ON FUNCTION net.station_bays_by_caller(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.station_bay_id(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.set_station_bay_mode(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.set_carrier_bay(bigint, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION brd.assign_trip_bay(uuid, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION brd.stop_bay_id(bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.station_bays_by_caller(bigint) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.station_bay_id(bigint, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.set_station_bay_mode(bigint, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.set_carrier_bay(bigint, uuid, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION brd.assign_trip_bay(uuid, integer, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION brd.stop_bay_id(bigint, integer) TO masslak_app;
COMMENT ON FUNCTION net.station_bays_by_caller IS 'Whether the caller runs the station''s bays: its administration or the platform (1115)';
COMMENT ON FUNCTION net.station_bay_id IS 'An open bay, gate or platform of a station, by its code (1115)';
COMMENT ON FUNCTION net.set_station_bay_mode IS 'The station''s administration chooses a permanent bay per carrier or a bay per trip (1115)';
COMMENT ON FUNCTION net.set_carrier_bay IS 'The station''s administration sets, changes or removes a carrier''s permanent bay (1115)';
COMMENT ON FUNCTION brd.assign_trip_bay IS 'The station''s administration sets or clears the bay of one trip at the station (1115)';
COMMENT ON FUNCTION brd.stop_bay_id IS 'The bay in force at a trip''s stop: its own, else the carrier''s permanent bay where the station assigns per carrier (1115)';

-- the permission of the administration's staff, and its role template
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('station.bays', 'station', 'COMPANY', 'Assign the bays of a station the company administers: a permanent bay for each carrier, or a bay for each trip', false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role (code, name, scope, is_system)
SELECT 'STATION_BAYS', 'Station bays officer (template)', 'COMPANY', true
 WHERE NOT EXISTS (SELECT 1 FROM iam.role WHERE code = 'STATION_BAYS' AND company_id IS NULL);
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'station.bays' FROM iam.role r WHERE r.code = 'STATION_BAYS' AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('net.station_carrier_bay', '1B', 'E04'), ('iam.company_logo', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('net.station_carrier_bay', 'PUBLIC_CATALOG', 'public read, the station''s administration writes', 'carriers'' permanent bays at stations (1115)'),
  ('iam.company_logo', 'PUBLIC_CATALOG', 'public read, platform writes', 'company logos shown next to their names (1115)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.station_carrier_bay', 'net catalog', 'carriers'' permanent bays at stations (1115)'),
  ('iam.company_logo', 'iam records', 'company logos (1115)')
ON CONFLICT (table_name) DO NOTHING;

-- ------------------------------------------------------------------ the bays page of the station's administration
-- the mode, the open bays, the carriers that leave from the station with their permanent bay, and the departures of
-- today, tomorrow and the day after (the station's time zone) with the bay in force and where it comes from
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
      SELECT jsonb_agg(jsonb_build_object('carrier_uid', p.uid, 'carrier', p.legal_name,
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
                 'trip_uid', t.uid, 'trip_no', t.trip_no, 'trip_code', t.trip_code, 'carrier_uid', cp.uid, 'carrier', cp.legal_name, 'status', t.status,
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
COMMENT ON FUNCTION brd.station_bays IS 'What the station''s administration sees to assign bays: the mode, the open bays, the carriers with their permanent bay, the departures of three days with the bay in force (1115)';

-- ------------------------------------------------------------------ the screens read the bay in force
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
             'trip_uid', t.uid, 'trip_no', t.trip_no, 'trip_code', t.trip_code, 'carrier', cp.legal_name, 'status', t.status, 'stop_seq', ts.seq,
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
COMMENT ON FUNCTION brd.station_trips IS 'Trips leaving a station today, tomorrow and the day after (its time zone) that the caller may sell, check in or board, with where they go, the check-in window at this station, their counts and the bay in force (1105, 1109, 1110, 1113, 1115)';

CREATE OR REPLACE FUNCTION brd.boarding_pass(p_checkin_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
           'pass_no', c.pass_no, 'status', c.status, 'checked_in_at', c.created_at, 'document_checked', c.document_checked,
           'ticket_uid', k.uid, 'ticket_no', k.ticket_no, 'ticket_status', k.status, 'seat_no', k.seat_no,
           'passenger', btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
           'trip_no', t.trip_no, 'trip_code', t.trip_code, 'carrier', cp.legal_name,
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
COMMENT ON FUNCTION brd.boarding_pass IS 'What the boarding pass prints: passenger, seat, trip, stations, departure, the bay in force (else the one at check-in), the counter, and its ticket for the signed code (1105, 1113, 1115)';

-- the board: the bay in force, the carrier's logo next to its name, and the languages it shows in turn
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
     GROUP BY w.trip_id, w.lo, w.hi, w.far),
  lang AS (                                        -- the board's languages and how long each stays (1115)
    SELECT coalesce((SELECT value FROM sys.setting WHERE key = 'boarding.board.languages' AND jsonb_typeof(value) = 'array'),
                    '["ar","en"]'::jsonb) AS languages,
           coalesce((SELECT (value #>> '{}')::integer FROM sys.setting
                      WHERE key = 'boarding.board.rotate_seconds' AND jsonb_typeof(value) = 'number'), 10) AS rotate_seconds)
  SELECT jsonb_build_object(
    'station', jsonb_build_object('code', st.code, 'name', st.name, 'time_zone', st.tz),
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
REVOKE ALL ON FUNCTION brd.station_board(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_board(uuid) TO masslak_app;
COMMENT ON FUNCTION brd.station_board IS 'The public departure board of a station whose screens the platform switched on: departures of the next 12 hours and arrivals of the next 6, with the bay in force, states, carriers'' logos, the city codes of the stops on the way and the languages shown in turn, without passenger data; NULL otherwise (1112, 1113, 1115)';

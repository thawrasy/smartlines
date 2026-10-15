-- =====================================================================
-- 1129  Station screens: some bays or carriers on a screen, a display paired by a short code, an unseen screen told
-- =====================================================================
-- The open items of 1120. A screen may show only some of the station's bays (a screen above bays 1 to 4) or only some
-- carriers (a carrier's own hall): net.station_screen.bays and carrier_ids, empty for all. The board of that screen
-- leaves the rest out.
-- A display is paired without typing a long link: it opens /screen/pair, which shows a short code (six letters and
-- digits that are not mistaken for one another) valid for ten minutes; the station's administration enters the code
-- against one of its screens, and the display, which asked with a secret only it holds (kept here as a hash), opens
-- that screen's board. A code is used once.
-- A screen that was seen and stops reading its board for longer than a setting (boarding.screens.unseen_minutes,
-- 10 by default) is shown as unseen to the administration, and the administration is told once per outage (outbox
-- event screen.unseen; the platform's boarding staff where the station has no administration).

ALTER TABLE net.station_screen ADD COLUMN IF NOT EXISTS bays text[] NOT NULL DEFAULT '{}';
ALTER TABLE net.station_screen ADD COLUMN IF NOT EXISTS carrier_ids bigint[] NOT NULL DEFAULT '{}';
ALTER TABLE net.station_screen ADD COLUMN IF NOT EXISTS unseen_told_at timestamptz;
ALTER TABLE net.station_screen DROP CONSTRAINT IF EXISTS station_screen_filter_ck;
ALTER TABLE net.station_screen ADD CONSTRAINT station_screen_filter_ck CHECK (cardinality(bays) <= 40 AND cardinality(carrier_ids) <= 40);
COMMENT ON COLUMN net.station_screen.bays IS 'The bays, gates or platforms the screen shows, by code; empty: all (1129)';
COMMENT ON COLUMN net.station_screen.carrier_ids IS 'The carriers whose trips the screen shows; empty: all (1129)';
COMMENT ON COLUMN net.station_screen.unseen_told_at IS 'When the administration was told the screen stopped reading its board (1129)';

INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('boarding.screens.unseen_minutes', '10'::jsonb, 'PLATFORM', 'Minutes without reading its board after which a screen that was seen is reported unseen (1129)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION net.screen_unseen_minutes() RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT greatest(2, coalesce((SELECT (value #>> '{}')::integer FROM sys.setting
                                WHERE key = 'boarding.screens.unseen_minutes' AND jsonb_typeof(value) = 'number'), 10))
$$;

-- ------------------------------------------------------------------ the bays and carriers of a screen
CREATE OR REPLACE FUNCTION net.set_screen_filter(p_screen_uid uuid, p_bays text[], p_carriers uuid[]) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_screen net.station_screen%ROWTYPE; v_bays text[]; v_ids bigint[]; v_bad text;
BEGIN
  SELECT * INTO v_screen FROM net.station_screen WHERE uid = p_screen_uid FOR UPDATE;
  IF NOT FOUND OR NOT net.station_bays_by_caller(v_screen.station_id) THEN
    RAISE EXCEPTION 'SCREEN_UNKNOWN: no such screen at a station you administer' USING ERRCODE = 'P0001';
  END IF;
  SELECT coalesce(array_agg(DISTINCT upper(btrim(b)) ORDER BY upper(btrim(b))), '{}') INTO v_bays
    FROM unnest(coalesce(p_bays, '{}')) b WHERE btrim(b) <> '';
  SELECT b INTO v_bad FROM unnest(v_bays) b WHERE net.station_bay_id(v_screen.station_id, b) IS NULL LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'SCREEN_BAY_UNKNOWN: the station has no open bay %', v_bad USING ERRCODE = 'P0001';
  END IF;
  SELECT coalesce(array_agg(DISTINCT c.id ORDER BY c.id), '{}') INTO v_ids
    FROM unnest(coalesce(p_carriers, '{}')) u JOIN iam.party p ON p.uid = u JOIN iam.company c ON c.id = p.id
   WHERE c.company_type IN ('CARRIER', 'INDIVIDUAL_OPERATOR', 'FOREIGN_CARRIER');
  IF cardinality(v_ids) <> (SELECT count(DISTINCT u) FROM unnest(coalesce(p_carriers, '{}')) u) THEN
    RAISE EXCEPTION 'SCREEN_CARRIER_UNKNOWN: a screen shows the trips of carriers only' USING ERRCODE = 'P0001';
  END IF;
  IF cardinality(v_bays) > 40 OR cardinality(v_ids) > 40 THEN
    RAISE EXCEPTION 'SCREEN_FILTER_LIMIT: a screen names at most 40 bays and 40 carriers' USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.station_screen SET bays = v_bays, carrier_ids = v_ids, updated_by_user_id = sys.ctx_user_id(), updated_at = now()
   WHERE id = v_screen.id;
  RETURN v_screen.station_id;
END $$;
DROP TRIGGER IF EXISTS zz_audit_capture ON net.station_screen;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR DELETE OR UPDATE OF kind, label, active, bays, carrier_ids ON net.station_screen
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();     -- the screen reading its board is not a change

-- what the administration sees: as 1120, with each screen's bays and carriers and whether it went unseen
CREATE OR REPLACE FUNCTION net.station_screens(p_station_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_unseen integer := net.screen_unseen_minutes();
BEGIN
  IF NOT net.station_bays_by_caller(p_station_id) THEN
    RAISE EXCEPTION 'NOT_STATION_ADMIN: only the station''s administration registers its screens' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object(
    'boards_on', coalesce((SELECT (value #>> '{}')::boolean FROM sys.setting WHERE key = 'boarding.stations.enabled'), false),
    'displays', coalesce((SELECT b.displays FROM net.station_boarding b WHERE b.station_id = p_station_id), false),
    'kinds', to_jsonb(coalesce((SELECT b.display_kinds FROM net.station_boarding b WHERE b.station_id = p_station_id),
                               ARRAY['DEPARTURES', 'ARRIVALS', 'COMBINED']::text[])),
    'unseen_minutes', v_unseen,
    'bays', coalesce((SELECT jsonb_agg(g.code ORDER BY g.code) FROM net.station_gate g
                       WHERE g.station_id = p_station_id AND g.gate_type IN ('BAY', 'GATE', 'PLATFORM') AND g.status = 'ACTIVE'), '[]'::jsonb),
    'carriers', coalesce((SELECT jsonb_agg(jsonb_build_object('uid', p.uid, 'name', p.legal_name) ORDER BY p.legal_name)
                           FROM iam.party p WHERE p.id IN (SELECT DISTINCT t.company_id FROM ops.trip_stop ts JOIN ops.trip t ON t.id = ts.trip_id
                                                            WHERE ts.station_id = p_station_id AND t.departure_at > now() - interval '30 days')), '[]'::jsonb),
    'screens', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'uid', sc.uid, 'kind', sc.kind, 'label', sc.label, 'active', sc.active,
               'allowed', net.screen_kind_allowed(p_station_id, sc.kind),
               'last_seen_at', sc.last_seen_at, 'online', coalesce(sc.last_seen_at >= now() - interval '2 minutes', false),
               'unseen', sc.active AND sc.last_seen_at IS NOT NULL AND sc.last_seen_at < now() - make_interval(mins => v_unseen),
               'bays', to_jsonb(sc.bays),
               'carriers', coalesce((SELECT jsonb_agg(jsonb_build_object('uid', p.uid, 'name', p.legal_name) ORDER BY p.legal_name)
                                       FROM iam.party p WHERE p.id = ANY(sc.carrier_ids)), '[]'::jsonb),
               'created_at', sc.created_at, 'updated_at', sc.updated_at)
             ORDER BY array_position(ARRAY['DEPARTURES', 'ARRIVALS', 'COMBINED']::text[], sc.kind), sc.label)
        FROM net.station_screen sc WHERE sc.station_id = p_station_id), '[]'::jsonb));
END $$;

-- the board of one screen, by its link: as 1120, with only the bays and carriers the screen names
CREATE OR REPLACE FUNCTION brd.screen_board(p_screen_uid uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v record; v_board jsonb; v_carriers text[];
BEGIN
  SELECT sc.id, sc.uid, sc.kind, sc.label, sc.active, sc.bays, sc.carrier_ids, s.uid AS station_uid INTO v
    FROM net.station_screen sc JOIN net.station s ON s.id = sc.station_id WHERE sc.uid = p_screen_uid;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  UPDATE net.station_screen SET last_seen_at = date_trunc('minute', now()), unseen_told_at = NULL
   WHERE id = v.id AND (last_seen_at IS NULL OR last_seen_at < date_trunc('minute', now()));
  IF NOT v.active THEN
    RETURN NULL;
  END IF;
  v_board := brd.station_board(v.station_uid, v.kind);
  IF v_board IS NULL THEN
    RETURN NULL;
  END IF;
  IF cardinality(v.bays) > 0 OR cardinality(v.carrier_ids) > 0 THEN
    v_carriers := ARRAY(SELECT p.uid::text FROM iam.party p WHERE p.id = ANY(v.carrier_ids));
    v_board := v_board
      || jsonb_build_object('departures', coalesce((
           SELECT jsonb_agg(e ORDER BY n) FROM jsonb_array_elements(v_board -> 'departures') WITH ORDINALITY x(e, n)
            WHERE (cardinality(v.bays) = 0 OR e ->> 'bay' = ANY(v.bays))
              AND (cardinality(v_carriers) = 0 OR e ->> 'carrier_uid' = ANY(v_carriers))), '[]'::jsonb))
      || jsonb_build_object('arrivals', coalesce((
           SELECT jsonb_agg(e ORDER BY n) FROM jsonb_array_elements(v_board -> 'arrivals') WITH ORDINALITY x(e, n)
            WHERE (cardinality(v.bays) = 0 OR e ->> 'bay' = ANY(v.bays))
              AND (cardinality(v_carriers) = 0 OR e ->> 'carrier_uid' = ANY(v_carriers))), '[]'::jsonb));
  END IF;
  RETURN v_board || jsonb_build_object('screen', jsonb_build_object('uid', v.uid, 'kind', v.kind, 'label', v.label)
    || CASE WHEN cardinality(v.bays) > 0 OR cardinality(v.carrier_ids) > 0
            THEN jsonb_build_object('bays', to_jsonb(v.bays), 'carriers_only', cardinality(v.carrier_ids) > 0) ELSE '{}'::jsonb END);
END $$;

-- ------------------------------------------------------------------ pairing a display by a short code
CREATE TABLE IF NOT EXISTS net.screen_pairing (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         text NOT NULL CHECK (code ~ '^[ACDEFHJKMNPRTUVWXY3479]{6}$'),
  token_hash   bytea NOT NULL UNIQUE CHECK (length(token_hash) = 32),
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  screen_id    bigint REFERENCES net.station_screen(id) ON DELETE CASCADE,
  paired_by    bigint REFERENCES iam.app_user(id),
  paired_at    timestamptz,
  CONSTRAINT screen_pairing_paired_ck CHECK ((screen_id IS NULL) = (paired_at IS NULL) AND (paired_by IS NULL OR screen_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS screen_pairing_code_ix ON net.screen_pairing (code, expires_at) WHERE screen_id IS NULL;
CREATE INDEX IF NOT EXISTS screen_pairing_screen_id_fkx ON net.screen_pairing (screen_id);
CREATE INDEX IF NOT EXISTS screen_pairing_paired_by_fkx ON net.screen_pairing (paired_by);
CREATE INDEX IF NOT EXISTS screen_pairing_expires_ix ON net.screen_pairing (expires_at);
COMMENT ON TABLE net.screen_pairing IS 'A display asking to be paired: the short code it shows, the hash of the secret only it holds, and the screen the station''s administration gave it (1129)';
SELECT sys.rls_platform('net.screen_pairing');
GRANT SELECT ON net.screen_pairing TO masslak_readonly;     -- the application reaches it through the functions below only

-- a display asks for a code; the code is drawn by the application and refused while another display holds it
CREATE OR REPLACE FUNCTION net.start_screen_pairing(p_code text, p_token_hash bytea) RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_until timestamptz := now() + interval '10 minutes';
BEGIN
  IF (SELECT count(*) FROM net.screen_pairing WHERE screen_id IS NULL AND expires_at > now()) >= 2000 THEN
    RAISE EXCEPTION 'PAIRING_BUSY: too many displays are waiting to be paired; try again in a few minutes' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM net.screen_pairing WHERE code = p_code AND screen_id IS NULL AND expires_at > now()) THEN
    RAISE EXCEPTION 'PAIRING_CODE_TAKEN: the code is in use' USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM net.screen_pairing WHERE expires_at < now() - interval '1 day';            -- old requests go
  INSERT INTO net.screen_pairing (code, token_hash, expires_at) VALUES (p_code, p_token_hash, v_until);
  RETURN v_until;
END $$;

-- the station's administration gives the display one of its screens
CREATE OR REPLACE FUNCTION net.claim_screen_pairing(p_code text, p_screen_uid uuid) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_screen net.station_screen%ROWTYPE; v_pairing bigint;
BEGIN
  SELECT * INTO v_screen FROM net.station_screen WHERE uid = p_screen_uid;
  IF NOT FOUND OR NOT net.station_bays_by_caller(v_screen.station_id) THEN
    RAISE EXCEPTION 'SCREEN_UNKNOWN: no such screen at a station you administer' USING ERRCODE = 'P0001';
  END IF;
  SELECT id INTO v_pairing FROM net.screen_pairing
   WHERE code = upper(btrim(p_code)) AND screen_id IS NULL AND expires_at > now() ORDER BY id DESC LIMIT 1 FOR UPDATE;
  IF v_pairing IS NULL THEN
    RAISE EXCEPTION 'PAIRING_UNKNOWN: no display shows this code now; open the pairing page on the display again' USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.screen_pairing SET screen_id = v_screen.id, paired_by = sys.ctx_user_id(), paired_at = now() WHERE id = v_pairing;
  RETURN v_screen.station_id;
END $$;

-- the display asks with its secret whether it was paired, and to which screen (for ten minutes after the pairing)
CREATE OR REPLACE FUNCTION net.screen_pairing_state(p_token_hash bytea) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE
    WHEN p.id IS NULL THEN jsonb_build_object('status', 'UNKNOWN')
    WHEN p.screen_id IS NOT NULL AND p.paired_at > now() - interval '10 minutes'
      THEN jsonb_build_object('status', 'PAIRED', 'screen_uid', (SELECT sc.uid FROM net.station_screen sc WHERE sc.id = p.screen_id))
    WHEN p.screen_id IS NULL AND p.expires_at > now() THEN jsonb_build_object('status', 'WAITING', 'code', p.code, 'expires_at', p.expires_at)
    ELSE jsonb_build_object('status', 'EXPIRED') END
    FROM (SELECT 1) one LEFT JOIN net.screen_pairing p ON p.token_hash = p_token_hash
$$;

-- ------------------------------------------------------------------ screens that stopped reading their board
CREATE OR REPLACE FUNCTION net.raise_screen_alerts() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_told integer;
BEGIN
  WITH due AS (
    UPDATE net.station_screen sc SET unseen_told_at = now()
      FROM net.station s JOIN net.station_boarding b ON b.station_id = s.id
     WHERE sc.station_id = s.id AND sc.active AND b.displays AND s.status = 'ACTIVE'
       AND sc.kind = ANY(b.display_kinds)
       AND coalesce((SELECT (value #>> '{}')::boolean FROM sys.setting WHERE key = 'boarding.stations.enabled'), false)
       AND sc.last_seen_at IS NOT NULL AND sc.last_seen_at < now() - make_interval(mins => net.screen_unseen_minutes())
       AND sc.unseen_told_at IS NULL
    RETURNING sc.id, sc.label, sc.kind, sc.last_seen_at, s.code AS station_code, s.name AS station_name, b.manager_company_id),
  told AS (
    INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, company_id, payload)
    SELECT 'screen.unseen', 'station_screen', d.id, d.manager_company_id,
           jsonb_build_object('label', d.label, 'kind', d.kind, 'station', d.station_code, 'station_name', d.station_name,
                              'minutes', greatest(1, (extract(epoch FROM now() - d.last_seen_at) / 60)::integer))
      FROM due d
    RETURNING 1)
  SELECT count(*) INTO v_told FROM told;
  RETURN v_told;
END $$;

REVOKE ALL ON FUNCTION net.screen_unseen_minutes() FROM PUBLIC;
REVOKE ALL ON FUNCTION net.set_screen_filter(uuid, text[], uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.start_screen_pairing(text, bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.claim_screen_pairing(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.screen_pairing_state(bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.raise_screen_alerts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.screen_unseen_minutes() TO masslak_app;
GRANT EXECUTE ON FUNCTION net.set_screen_filter(uuid, text[], uuid[]) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.start_screen_pairing(text, bytea) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.claim_screen_pairing(text, uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.screen_pairing_state(bytea) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.raise_screen_alerts() TO masslak_app;
COMMENT ON FUNCTION net.screen_unseen_minutes IS 'Minutes without reading its board after which a screen is unseen (setting, at least 2; 1129)';
COMMENT ON FUNCTION net.set_screen_filter IS 'The station''s administration names the bays and carriers a screen shows; empty for all (1129)';
COMMENT ON FUNCTION net.start_screen_pairing IS 'A display asks to be paired: its short code, valid ten minutes, and the hash of its secret (1129)';
COMMENT ON FUNCTION net.claim_screen_pairing IS 'The station''s administration gives the display showing a code one of its screens; a code is used once (1129)';
COMMENT ON FUNCTION net.screen_pairing_state IS 'Whether a display was paired, by the hash of its secret, and its screen (1129)';
COMMENT ON FUNCTION net.raise_screen_alerts IS 'Screens that were seen and stopped reading their board past the setting; the administration is told once per outage through the outbox (worker, every minute; 1129)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('net.screen_pairing', '1B', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('net.screen_pairing', 'PLATFORM_CONFIDENTIAL', 'the platform reads; displays and the station''s administration through its functions',
   'displays waiting to be paired with a station screen, by a short code (1129)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.screen_pairing', 'net records', 'displays paired with station screens by a short code (1129)')
ON CONFLICT (table_name) DO NOTHING;

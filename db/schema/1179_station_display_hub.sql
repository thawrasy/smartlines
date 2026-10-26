-- =====================================================================
-- 1179  Station displays on a closed network (owner's note N46): the station display hub
-- =====================================================================
-- Design: docs/design/STATION_DISPLAYS_LAN.md. A station whose screens are on its own network (LAN, a screens VLAN)
-- runs one display hub: a small server inside the station that alone talks to the platform, outbound only, and serves
-- the boards to the screens' players over the LAN. The screens never touch the internet.
--   * net.display_hub: a hub, paired once with its station by a one-time code the station's administration makes
--     (net.hub_pairing), then holding its own key (kept here as a hash) that the administration can revoke.
--   * net.station_screen gains its network identity: the short code the player opens at the hub
--     (http://<hub>/screen/<code>), a group (departure gates, arrivals hall, bays...), the hub that serves it, and the
--     player's hardware address (MAC) and fixed IP. A screen is shown only to the player whose MAC and IP both match.
--   * net.hub_player: a player that announced itself to the hub and waits for the administration to approve it and
--     give it a screen; nobody types an address from scratch.
--   * net.hub_event: what the hub reported that the administration must see: an unknown device, a known player seen at
--     another address, the uplink cut and for how long. Written once, never changed.
-- The hub reads the boards of its screens without stamping them seen; a screen is seen when its player reports to the
-- hub, which tells the platform. The short-code pairing of 1129 stays for screens on the internet.

-- ------------------------------------------------------------------ the hubs
CREATE TABLE IF NOT EXISTS net.display_hub (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid              uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  station_id       bigint NOT NULL REFERENCES net.station(id),
  label            text NOT NULL CHECK (length(btrim(label)) BETWEEN 1 AND 60),
  key_hash         bytea NOT NULL UNIQUE CHECK (length(key_hash) = 32),
  created_by       bigint REFERENCES iam.app_user(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  last_contact_at  timestamptz,
  version          text CHECK (version IS NULL OR length(version) <= 40),
  revoked_at       timestamptz,
  revoked_by       bigint REFERENCES iam.app_user(id),
  revoke_reason    text CHECK (revoke_reason IS NULL OR length(btrim(revoke_reason)) BETWEEN 3 AND 300),
  CONSTRAINT display_hub_revoked_ck CHECK ((revoked_at IS NULL) = (revoke_reason IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS display_hub_label_ux ON net.display_hub (station_id, label) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS display_hub_created_by_fkx ON net.display_hub (created_by);
CREATE INDEX IF NOT EXISTS display_hub_revoked_by_fkx ON net.display_hub (revoked_by);
COMMENT ON TABLE net.display_hub IS 'A station display hub: the one server inside a station that talks to the platform (outbound only) and serves the boards to the screens on the station''s own network (1179, N46)';
COMMENT ON COLUMN net.display_hub.key_hash IS 'SHA-256 of the hub''s own key, given to it once at pairing; the key itself is never kept';
COMMENT ON COLUMN net.display_hub.last_contact_at IS 'When the hub last reached the platform, to the minute';

-- a one-time code the station's administration makes and types into the hub when it is installed
CREATE TABLE IF NOT EXISTS net.hub_pairing (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  station_id  bigint NOT NULL REFERENCES net.station(id),
  label       text NOT NULL CHECK (length(btrim(label)) BETWEEN 1 AND 60),
  code_hash   bytea NOT NULL UNIQUE CHECK (length(code_hash) = 32),
  created_by  bigint REFERENCES iam.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,
  hub_id      bigint REFERENCES net.display_hub(id),
  used_at     timestamptz,
  CONSTRAINT hub_pairing_used_ck CHECK ((hub_id IS NULL) = (used_at IS NULL))
);
CREATE INDEX IF NOT EXISTS hub_pairing_station_id_fkx ON net.hub_pairing (station_id);
CREATE INDEX IF NOT EXISTS hub_pairing_created_by_fkx ON net.hub_pairing (created_by);
CREATE INDEX IF NOT EXISTS hub_pairing_hub_id_fkx ON net.hub_pairing (hub_id);
COMMENT ON TABLE net.hub_pairing IS 'A one-time code with which a new display hub joins its station; valid one hour, used once, kept as a hash (1179)';

-- ------------------------------------------------------------------ the screens' network identity
ALTER TABLE net.station_screen ADD COLUMN IF NOT EXISTS hub_id bigint REFERENCES net.display_hub(id);
ALTER TABLE net.station_screen ADD COLUMN IF NOT EXISTS screen_code text;
ALTER TABLE net.station_screen ADD COLUMN IF NOT EXISTS group_name text;
ALTER TABLE net.station_screen ADD COLUMN IF NOT EXISTS mac macaddr;
ALTER TABLE net.station_screen ADD COLUMN IF NOT EXISTS fixed_ip inet;
ALTER TABLE net.station_screen DROP CONSTRAINT IF EXISTS station_screen_network_ck;
ALTER TABLE net.station_screen ADD CONSTRAINT station_screen_network_ck CHECK (
  (screen_code IS NULL OR screen_code ~ '^[A-Z0-9][A-Z0-9-]{1,15}$')
  AND (group_name IS NULL OR length(btrim(group_name)) BETWEEN 1 AND 40)
  AND (fixed_ip IS NULL OR (family(fixed_ip) IN (4, 6) AND masklen(fixed_ip) = CASE family(fixed_ip) WHEN 4 THEN 32 ELSE 128 END))
  AND ((mac IS NULL) = (fixed_ip IS NULL))
  AND (mac IS NULL OR hub_id IS NOT NULL));
CREATE UNIQUE INDEX IF NOT EXISTS station_screen_code_ux ON net.station_screen (station_id, screen_code) WHERE screen_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS station_screen_mac_ux ON net.station_screen (hub_id, mac) WHERE mac IS NOT NULL;
CREATE INDEX IF NOT EXISTS station_screen_hub_id_fkx ON net.station_screen (hub_id);
COMMENT ON COLUMN net.station_screen.hub_id IS 'The display hub that serves the screen on the station''s own network; empty for a screen on the internet (1179)';
COMMENT ON COLUMN net.station_screen.screen_code IS 'The short code the player opens at the hub: http://<hub>/screen/<code> (1179)';
COMMENT ON COLUMN net.station_screen.group_name IS 'The group the screen belongs to: departure gates, arrivals hall, bays... (1179)';
COMMENT ON COLUMN net.station_screen.mac IS 'The hardware address of the player approved for the screen; the hub shows the board only to it, at its fixed IP (1179)';
COMMENT ON COLUMN net.station_screen.fixed_ip IS 'The address the station''s network reserves for the player (DHCP reservation); a player seen elsewhere is reported (1179)';

-- ------------------------------------------------------------------ players waiting for approval
CREATE TABLE IF NOT EXISTS net.hub_player (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid         uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  hub_id      bigint NOT NULL REFERENCES net.display_hub(id),
  mac         macaddr NOT NULL,
  ip          inet NOT NULL,
  first_seen  timestamptz NOT NULL DEFAULT now(),
  last_seen   timestamptz NOT NULL DEFAULT now(),
  status      text NOT NULL DEFAULT 'WAITING' CHECK (status IN ('WAITING', 'APPROVED', 'REJECTED')),
  screen_id   bigint REFERENCES net.station_screen(id) ON DELETE SET NULL,
  decided_by  bigint REFERENCES iam.app_user(id),
  decided_at  timestamptz,
  UNIQUE (hub_id, mac),
  CONSTRAINT hub_player_decided_ck CHECK ((status = 'WAITING') = (decided_at IS NULL))
);
CREATE INDEX IF NOT EXISTS hub_player_screen_id_fkx ON net.hub_player (screen_id);
CREATE INDEX IF NOT EXISTS hub_player_decided_by_fkx ON net.hub_player (decided_by);
COMMENT ON TABLE net.hub_player IS 'A screen player that announced itself to a display hub: waiting for the station''s administration, approved for a screen, or rejected (1179)';

-- ------------------------------------------------------------------ what the hub reports
CREATE TABLE IF NOT EXISTS net.hub_event (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hub_id      bigint NOT NULL REFERENCES net.display_hub(id),
  kind        text NOT NULL CHECK (kind IN ('UNKNOWN_DEVICE', 'ADDRESS_MISMATCH', 'UPLINK_RESTORED', 'REJECTED_DEVICE')),
  mac         macaddr,
  ip          inet,
  screen_id   bigint REFERENCES net.station_screen(id) ON DELETE SET NULL,
  seconds     integer CHECK (seconds IS NULL OR seconds >= 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS hub_event_hub_time_ix ON net.hub_event (hub_id, created_at DESC);
CREATE INDEX IF NOT EXISTS hub_event_screen_id_fkx ON net.hub_event (screen_id);
COMMENT ON TABLE net.hub_event IS 'What a display hub reported for the administration: an unknown device, a player at another address, a rejected device asking again, the uplink back after a cut and for how long (1179); never changed';
CREATE OR REPLACE FUNCTION net.tg_hub_event_kept() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  -- a screen taken down leaves its events, without the link to it (ON DELETE SET NULL); nothing else ever changes
  IF TG_OP = 'UPDATE' AND OLD.screen_id IS NOT NULL AND NEW.screen_id IS NULL
     AND (NEW.id, NEW.hub_id, NEW.kind, NEW.mac, NEW.ip, NEW.seconds, NEW.created_at)
         IS NOT DISTINCT FROM (OLD.id, OLD.hub_id, OLD.kind, OLD.mac, OLD.ip, OLD.seconds, OLD.created_at) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'HUB_EVENT_KEPT: what a hub reported is never changed' USING ERRCODE = 'P0001';
END $$;
DROP TRIGGER IF EXISTS hub_event_kept ON net.hub_event;
CREATE TRIGGER hub_event_kept BEFORE UPDATE OR DELETE ON net.hub_event FOR EACH ROW EXECUTE FUNCTION net.tg_hub_event_kept();

SELECT sys.rls_platform('net.display_hub');
SELECT sys.rls_platform('net.hub_pairing');
SELECT sys.rls_platform('net.hub_player');
SELECT sys.rls_platform('net.hub_event');
GRANT SELECT ON net.display_hub, net.hub_pairing, net.hub_player, net.hub_event TO masslak_readonly;   -- the application uses the functions below
DROP TRIGGER IF EXISTS zz_audit_capture ON net.display_hub;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR DELETE OR UPDATE OF label, revoked_at ON net.display_hub
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();     -- the hub's contacts are not changes
DROP TRIGGER IF EXISTS zz_audit_capture ON net.hub_player;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR DELETE OR UPDATE OF status, screen_id ON net.hub_player
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS zz_audit_capture ON net.station_screen;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR DELETE OR UPDATE OF kind, label, active, hub_id, screen_code, group_name, mac, fixed_ip
  ON net.station_screen FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- ------------------------------------------------------------------ the board of a screen, without stamping it seen
CREATE OR REPLACE FUNCTION brd.screen_board_data(p_screen_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v record; v_board jsonb; v_carriers text[];
BEGIN
  SELECT sc.id, sc.uid, sc.kind, sc.label, sc.active, sc.bays, sc.carrier_ids, s.uid AS station_uid INTO v
    FROM net.station_screen sc JOIN net.station s ON s.id = sc.station_id WHERE sc.id = p_screen_id;
  IF NOT FOUND OR NOT v.active THEN
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

-- a screen on the internet reads its board through its link and is stamped seen; the same board as the hub's
CREATE OR REPLACE FUNCTION brd.screen_board(p_screen_uid uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  SELECT id INTO v_id FROM net.station_screen WHERE uid = p_screen_uid;
  IF v_id IS NULL THEN
    RETURN NULL;
  END IF;
  UPDATE net.station_screen SET last_seen_at = date_trunc('minute', now()), unseen_told_at = NULL
   WHERE id = v_id AND (last_seen_at IS NULL OR last_seen_at < date_trunc('minute', now()));
  RETURN brd.screen_board_data(v_id);
END $$;

-- ------------------------------------------------------------------ the administration: pairing a hub
CREATE OR REPLACE FUNCTION net.start_hub_pairing(p_station_id bigint, p_label text, p_code_hash bytea) RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_until timestamptz := now() + interval '1 hour';
BEGIN
  IF NOT net.station_bays_by_caller(p_station_id) THEN
    RAISE EXCEPTION 'NOT_STATION_ADMIN: only the station''s administration adds its display hubs' USING ERRCODE = 'P0001';
  END IF;
  IF p_label IS NULL OR length(btrim(p_label)) NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'HUB_LABEL_INVALID: a hub is named by its place, 1 to 60 characters' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM net.display_hub WHERE station_id = p_station_id AND label = btrim(p_label) AND revoked_at IS NULL) THEN
    RAISE EXCEPTION 'HUB_LABEL_TAKEN: the station has a hub with this name' USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM net.hub_pairing WHERE hub_id IS NULL AND expires_at < now() - interval '1 day';
  INSERT INTO net.hub_pairing (station_id, label, code_hash, created_by, expires_at)
  VALUES (p_station_id, btrim(p_label), p_code_hash, sys.ctx_user_id(), v_until);
  RETURN v_until;
END $$;

-- the hub, being installed, gives the code and the hash of the key it made; it becomes the station's hub
CREATE OR REPLACE FUNCTION net.claim_hub(p_code_hash bytea, p_key_hash bytea, p_version text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_pairing net.hub_pairing%ROWTYPE; v_hub net.display_hub%ROWTYPE;
BEGIN
  SELECT * INTO v_pairing FROM net.hub_pairing WHERE code_hash = p_code_hash FOR UPDATE;
  IF NOT FOUND OR v_pairing.hub_id IS NOT NULL OR v_pairing.expires_at < now() THEN
    RAISE EXCEPTION 'HUB_CODE_UNKNOWN: the code is wrong, used or expired; make a new one in the station portal' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO net.display_hub (station_id, label, key_hash, created_by, last_contact_at, version)
  VALUES (v_pairing.station_id, v_pairing.label, p_key_hash, v_pairing.created_by, date_trunc('minute', now()), left(p_version, 40))
  RETURNING * INTO v_hub;
  UPDATE net.hub_pairing SET hub_id = v_hub.id, used_at = now() WHERE id = v_pairing.id;
  RETURN jsonb_build_object('hub_uid', v_hub.uid, 'label', v_hub.label,
                            'station_uid', (SELECT uid FROM net.station WHERE id = v_hub.station_id),
                            'station_code', (SELECT code FROM net.station WHERE id = v_hub.station_id));
END $$;

-- the hub calling with its key: the hub, or nothing for an unknown or revoked key; its contact is stamped
CREATE OR REPLACE FUNCTION net.hub_by_key(p_key_hash bytea, p_version text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  UPDATE net.display_hub SET last_contact_at = date_trunc('minute', now()), version = coalesce(left(p_version, 40), version)
   WHERE key_hash = p_key_hash AND revoked_at IS NULL
   RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ------------------------------------------------------------------ the hub's pull: its screens and their boards
CREATE OR REPLACE FUNCTION net.hub_sync(p_hub_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_hub net.display_hub%ROWTYPE;
BEGIN
  SELECT * INTO v_hub FROM net.display_hub WHERE id = p_hub_id AND revoked_at IS NULL;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object(
    'hub', jsonb_build_object('uid', v_hub.uid, 'label', v_hub.label),
    'station', (SELECT jsonb_build_object('uid', s.uid, 'code', s.code, 'name', s.name) FROM net.station s WHERE s.id = v_hub.station_id),
    'server_time', now(),
    'screens', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'code', sc.screen_code, 'kind', sc.kind, 'label', sc.label, 'group', sc.group_name,
               'mac', sc.mac::text, 'ip', host(sc.fixed_ip), 'board', brd.screen_board_data(sc.id))
             ORDER BY sc.screen_code)
        FROM net.station_screen sc
       -- its own screens, and the station's screens no hub serves yet: a new player opens one and waits for approval
       WHERE sc.station_id = v_hub.station_id AND (sc.hub_id = v_hub.id OR sc.hub_id IS NULL)
         AND sc.active AND sc.screen_code IS NOT NULL), '[]'::jsonb),
    'rejected', coalesce((SELECT jsonb_agg(p.mac::text ORDER BY p.mac) FROM net.hub_player p
                           WHERE p.hub_id = v_hub.id AND p.status = 'REJECTED'), '[]'::jsonb),
    -- the boards name cities by code; the hub shows them in Arabic and English without reaching the platform
    'cities', coalesce((SELECT jsonb_object_agg(c.code, jsonb_build_object('en', c.name, 'ar', coalesce(pl.name_ar, c.name)))
                          FROM ref.city c LEFT JOIN ref.place pl ON pl.id = c.place_id WHERE c.is_active), '{}'::jsonb));
END $$;

-- the hub reports the players it saw on the screens' network, and how long its uplink was cut if it was
CREATE OR REPLACE FUNCTION net.hub_report(p_hub_id bigint, p_players jsonb, p_gap_seconds integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_station bigint; e jsonb; v_mac macaddr; v_ip inet; v_screen net.station_screen%ROWTYPE; v_player net.hub_player%ROWTYPE;
        v_seen integer := 0; v_waiting integer := 0; v_mismatch integer := 0;
BEGIN
  SELECT station_id INTO v_station FROM net.display_hub WHERE id = p_hub_id AND revoked_at IS NULL;
  IF v_station IS NULL THEN
    RAISE EXCEPTION 'HUB_UNKNOWN: the hub is not paired or was revoked' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p_players) <> 'array' OR jsonb_array_length(p_players) > 500 THEN
    RAISE EXCEPTION 'HUB_REPORT_INVALID: a report lists at most 500 players' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(p_gap_seconds, 0) >= 60 THEN
    INSERT INTO net.hub_event (hub_id, kind, seconds) VALUES (p_hub_id, 'UPLINK_RESTORED', p_gap_seconds);
  END IF;
  FOR e IN SELECT * FROM jsonb_array_elements(p_players) LOOP
    BEGIN
      v_mac := (e ->> 'mac')::macaddr; v_ip := (e ->> 'ip')::inet;
    EXCEPTION WHEN others THEN
      CONTINUE;                                              -- a malformed entry is skipped, not trusted
    END;
    SELECT * INTO v_screen FROM net.station_screen WHERE hub_id = p_hub_id AND mac = v_mac;
    IF FOUND THEN
      IF host(v_screen.fixed_ip) <> host(v_ip) THEN
        v_mismatch := v_mismatch + 1;
        IF NOT EXISTS (SELECT 1 FROM net.hub_event WHERE hub_id = p_hub_id AND kind = 'ADDRESS_MISMATCH' AND mac = v_mac
                         AND ip = v_ip AND created_at > now() - interval '1 hour') THEN
          INSERT INTO net.hub_event (hub_id, kind, mac, ip, screen_id) VALUES (p_hub_id, 'ADDRESS_MISMATCH', v_mac, v_ip, v_screen.id);
        END IF;
      ELSE
        v_seen := v_seen + 1;
        UPDATE net.station_screen SET last_seen_at = date_trunc('minute', now()), unseen_told_at = NULL
         WHERE id = v_screen.id AND (last_seen_at IS NULL OR last_seen_at < date_trunc('minute', now()));
      END IF;
      CONTINUE;
    END IF;
    SELECT * INTO v_player FROM net.hub_player WHERE hub_id = p_hub_id AND mac = v_mac;
    IF NOT FOUND THEN
      INSERT INTO net.hub_player (hub_id, mac, ip) VALUES (p_hub_id, v_mac, v_ip);
      INSERT INTO net.hub_event (hub_id, kind, mac, ip) VALUES (p_hub_id, 'UNKNOWN_DEVICE', v_mac, v_ip);
      v_waiting := v_waiting + 1;
    ELSE
      UPDATE net.hub_player SET ip = v_ip, last_seen = now() WHERE id = v_player.id;
      IF v_player.status = 'WAITING' THEN
        v_waiting := v_waiting + 1;
      ELSIF v_player.status = 'REJECTED' AND NOT EXISTS (
          SELECT 1 FROM net.hub_event WHERE hub_id = p_hub_id AND kind = 'REJECTED_DEVICE' AND mac = v_mac AND created_at > now() - interval '1 day') THEN
        INSERT INTO net.hub_event (hub_id, kind, mac, ip) VALUES (p_hub_id, 'REJECTED_DEVICE', v_mac, v_ip);
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('seen', v_seen, 'waiting', v_waiting, 'mismatch', v_mismatch);
END $$;

-- ------------------------------------------------------------------ the administration: players, screens, hubs
-- approve a waiting player for one of the station's screens (its MAC and IP become the screen's), or reject it
CREATE OR REPLACE FUNCTION net.decide_hub_player(p_player_uid uuid, p_screen_uid uuid, p_approve boolean) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_player net.hub_player%ROWTYPE; v_station bigint; v_screen net.station_screen%ROWTYPE;
BEGIN
  SELECT p.* INTO v_player FROM net.hub_player p WHERE p.uid = p_player_uid FOR UPDATE;
  SELECT h.station_id INTO v_station FROM net.display_hub h WHERE h.id = v_player.hub_id AND h.revoked_at IS NULL;
  IF v_station IS NULL OR NOT net.station_bays_by_caller(v_station) THEN
    RAISE EXCEPTION 'PLAYER_UNKNOWN: no such player at a station you administer' USING ERRCODE = 'P0001';
  END IF;
  IF v_player.status <> 'WAITING' THEN
    RAISE EXCEPTION 'PLAYER_DECIDED: the player was already approved or rejected' USING ERRCODE = 'P0001';
  END IF;
  IF NOT p_approve THEN
    UPDATE net.hub_player SET status = 'REJECTED', decided_by = sys.ctx_user_id(), decided_at = now() WHERE id = v_player.id;
    RETURN v_station;
  END IF;
  SELECT * INTO v_screen FROM net.station_screen WHERE uid = p_screen_uid FOR UPDATE;
  IF NOT FOUND OR v_screen.station_id <> v_station THEN
    RAISE EXCEPTION 'SCREEN_UNKNOWN: no such screen at this station' USING ERRCODE = 'P0001';
  END IF;
  IF v_screen.screen_code IS NULL THEN
    RAISE EXCEPTION 'SCREEN_CODE_REQUIRED: give the screen its code before a player is approved for it' USING ERRCODE = 'P0001';
  END IF;
  -- a screen has one player: the one it had goes back to waiting
  UPDATE net.hub_player SET status = 'WAITING', screen_id = NULL, decided_by = NULL, decided_at = NULL
   WHERE screen_id = v_screen.id AND id <> v_player.id;
  UPDATE net.station_screen SET hub_id = v_player.hub_id, mac = v_player.mac, fixed_ip = v_player.ip,
         updated_by_user_id = sys.ctx_user_id(), updated_at = now() WHERE id = v_screen.id;
  UPDATE net.hub_player SET status = 'APPROVED', screen_id = v_screen.id, decided_by = sys.ctx_user_id(), decided_at = now()
   WHERE id = v_player.id;
  RETURN v_station;
END $$;

-- the screen's code and group, and its fixed IP once the station's network reserved another address for it
CREATE OR REPLACE FUNCTION net.set_screen_network(p_screen_uid uuid, p_code text, p_group text, p_fixed_ip inet) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_screen net.station_screen%ROWTYPE; v_code text := nullif(upper(btrim(p_code)), '');
BEGIN
  SELECT * INTO v_screen FROM net.station_screen WHERE uid = p_screen_uid FOR UPDATE;
  IF NOT FOUND OR NOT net.station_bays_by_caller(v_screen.station_id) THEN
    RAISE EXCEPTION 'SCREEN_UNKNOWN: no such screen at a station you administer' USING ERRCODE = 'P0001';
  END IF;
  IF v_code IS NOT NULL AND v_code !~ '^[A-Z0-9][A-Z0-9-]{1,15}$' THEN
    RAISE EXCEPTION 'SCREEN_CODE_INVALID: 2 to 16 letters, digits and hyphens, such as DEP-1' USING ERRCODE = 'P0001';
  END IF;
  IF v_code IS NOT NULL AND EXISTS (SELECT 1 FROM net.station_screen WHERE station_id = v_screen.station_id AND screen_code = v_code AND id <> v_screen.id) THEN
    RAISE EXCEPTION 'SCREEN_CODE_TAKEN: another screen of the station has this code' USING ERRCODE = 'P0001';
  END IF;
  IF p_fixed_ip IS NOT NULL AND v_screen.mac IS NULL THEN
    RAISE EXCEPTION 'SCREEN_NO_PLAYER: approve the screen''s player before changing its address' USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.station_screen SET screen_code = v_code, group_name = nullif(btrim(p_group), ''),
         fixed_ip = coalesce(p_fixed_ip, fixed_ip), updated_by_user_id = sys.ctx_user_id(), updated_at = now()
   WHERE id = v_screen.id;
  RETURN v_screen.station_id;
END $$;

-- the screen's player is released (a player replaced or moved): the screen waits for another
CREATE OR REPLACE FUNCTION net.release_screen_player(p_screen_uid uuid) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_screen net.station_screen%ROWTYPE;
BEGIN
  SELECT * INTO v_screen FROM net.station_screen WHERE uid = p_screen_uid FOR UPDATE;
  IF NOT FOUND OR NOT net.station_bays_by_caller(v_screen.station_id) THEN
    RAISE EXCEPTION 'SCREEN_UNKNOWN: no such screen at a station you administer' USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.hub_player SET status = 'WAITING', screen_id = NULL, decided_by = NULL, decided_at = NULL WHERE screen_id = v_screen.id;
  UPDATE net.station_screen SET mac = NULL, fixed_ip = NULL, hub_id = NULL, updated_by_user_id = sys.ctx_user_id(), updated_at = now()
   WHERE id = v_screen.id;
  RETURN v_screen.station_id;
END $$;

CREATE OR REPLACE FUNCTION net.revoke_hub(p_hub_uid uuid, p_reason text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_hub net.display_hub%ROWTYPE;
BEGIN
  SELECT * INTO v_hub FROM net.display_hub WHERE uid = p_hub_uid FOR UPDATE;
  IF NOT FOUND OR NOT net.station_bays_by_caller(v_hub.station_id) THEN
    RAISE EXCEPTION 'HUB_UNKNOWN: no such hub at a station you administer' USING ERRCODE = 'P0001';
  END IF;
  IF v_hub.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'HUB_REVOKED: the hub was already revoked' USING ERRCODE = 'P0001';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'HUB_REASON: a revocation gives its reason' USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.station_screen SET mac = NULL, fixed_ip = NULL, hub_id = NULL, updated_by_user_id = sys.ctx_user_id(), updated_at = now()
   WHERE hub_id = v_hub.id;
  UPDATE net.display_hub SET revoked_at = now(), revoked_by = sys.ctx_user_id(), revoke_reason = btrim(p_reason) WHERE id = v_hub.id;
  RETURN v_hub.station_id;
END $$;

-- what the administration sees: its hubs, the players waiting, the screens' network identity, the last events
CREATE OR REPLACE FUNCTION net.station_hubs(p_station_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT net.station_bays_by_caller(p_station_id) THEN
    RAISE EXCEPTION 'NOT_STATION_ADMIN: only the station''s administration sees its display hubs' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object(
    'hubs', coalesce((SELECT jsonb_agg(jsonb_build_object(
               'uid', h.uid, 'label', h.label, 'created_at', h.created_at, 'last_contact_at', h.last_contact_at,
               'online', coalesce(h.last_contact_at >= now() - interval '3 minutes', false), 'version', h.version,
               'revoked_at', h.revoked_at, 'revoke_reason', h.revoke_reason,
               'screens', (SELECT count(*) FROM net.station_screen sc WHERE sc.hub_id = h.id))
             ORDER BY h.revoked_at NULLS FIRST, h.label)
        FROM net.display_hub h WHERE h.station_id = p_station_id), '[]'::jsonb),
    'players', coalesce((SELECT jsonb_agg(jsonb_build_object(
               'uid', p.uid, 'hub', h.label, 'mac', p.mac::text, 'ip', host(p.ip), 'status', p.status,
               'first_seen', p.first_seen, 'last_seen', p.last_seen,
               'screen', (SELECT sc.label FROM net.station_screen sc WHERE sc.id = p.screen_id))
             ORDER BY array_position(ARRAY['WAITING', 'APPROVED', 'REJECTED'], p.status), p.last_seen DESC)
        FROM net.hub_player p JOIN net.display_hub h ON h.id = p.hub_id
       WHERE h.station_id = p_station_id AND h.revoked_at IS NULL), '[]'::jsonb),
    'screens', coalesce((SELECT jsonb_agg(jsonb_build_object(
               'uid', sc.uid, 'label', sc.label, 'kind', sc.kind, 'code', sc.screen_code, 'group', sc.group_name,
               'hub', (SELECT h.label FROM net.display_hub h WHERE h.id = sc.hub_id), 'mac', sc.mac::text, 'ip', host(sc.fixed_ip),
               'last_seen_at', sc.last_seen_at, 'online', coalesce(sc.last_seen_at >= now() - interval '2 minutes', false))
             ORDER BY sc.group_name NULLS LAST, sc.screen_code NULLS LAST, sc.label)
        FROM net.station_screen sc WHERE sc.station_id = p_station_id AND sc.active), '[]'::jsonb),
    'events', coalesce((SELECT jsonb_agg(x ORDER BY x ->> 'at' DESC) FROM (
        SELECT jsonb_build_object('kind', e.kind, 'hub', h.label, 'mac', e.mac::text, 'ip', host(e.ip), 'seconds', e.seconds,
                                  'screen', (SELECT sc.label FROM net.station_screen sc WHERE sc.id = e.screen_id), 'at', e.created_at) AS x
          FROM net.hub_event e JOIN net.display_hub h ON h.id = e.hub_id
         WHERE h.station_id = p_station_id ORDER BY e.created_at DESC LIMIT 50) last), '[]'::jsonb));
END $$;

REVOKE ALL ON FUNCTION brd.screen_board_data(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.start_hub_pairing(bigint, text, bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.claim_hub(bytea, bytea, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.hub_by_key(bytea, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.hub_sync(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.hub_report(bigint, jsonb, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.decide_hub_player(uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.set_screen_network(uuid, text, text, inet) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.release_screen_player(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.revoke_hub(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.station_hubs(bigint) FROM PUBLIC;
-- brd.screen_board_data is called only by the definer functions above, never by the application
GRANT EXECUTE ON FUNCTION net.start_hub_pairing(bigint, text, bytea) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.claim_hub(bytea, bytea, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.hub_by_key(bytea, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.hub_sync(bigint) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.hub_report(bigint, jsonb, integer) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.decide_hub_player(uuid, uuid, boolean) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.set_screen_network(uuid, text, text, inet) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.release_screen_player(uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.revoke_hub(uuid, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.station_hubs(bigint) TO masslak_app;
COMMENT ON FUNCTION brd.screen_board_data IS 'The board of one screen, filtered by its bays and carriers, without stamping it seen (1179)';
COMMENT ON FUNCTION net.start_hub_pairing IS 'The station''s administration makes a one-time code for a new display hub, valid one hour (1179)';
COMMENT ON FUNCTION net.claim_hub IS 'A display hub being installed gives the code and the hash of its own key, and becomes the station''s hub (1179)';
COMMENT ON FUNCTION net.hub_by_key IS 'The hub calling with its key, or nothing for an unknown or revoked key; stamps its contact (1179)';
COMMENT ON FUNCTION net.hub_sync IS 'What a hub pulls: its station, its screens with their code, group, player and board, and the rejected players (1179)';
COMMENT ON FUNCTION net.hub_report IS 'A hub reports the players it saw: approved players stamp their screens seen, a known player at another address and an unknown device are reported (1179)';
COMMENT ON FUNCTION net.decide_hub_player IS 'The station''s administration approves a waiting player for one of its screens, or rejects it (1179)';
COMMENT ON FUNCTION net.set_screen_network IS 'The station''s administration gives a screen its code, its group and, after a new reservation, its fixed IP (1179)';
COMMENT ON FUNCTION net.release_screen_player IS 'The screen''s player is released, and the screen waits for another (1179)';
COMMENT ON FUNCTION net.revoke_hub IS 'The station''s administration revokes a hub''s key, with its reason; its screens wait for a new hub (1179)';
COMMENT ON FUNCTION net.station_hubs IS 'The station''s display hubs, waiting players, screens on the hubs and the last events, for its administration (1179)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('net.display_hub', '1B', 'E04'), ('net.hub_pairing', '1B', 'E04'), ('net.hub_player', '1B', 'E04'), ('net.hub_event', '1B', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('net.display_hub', 'PLATFORM_CONFIDENTIAL', 'the platform reads; hubs and the station''s administration through its functions',
   'the display hubs of stations, each with the hash of its key (1179)'),
  ('net.hub_pairing', 'PLATFORM_CONFIDENTIAL', 'the platform reads; the station''s administration and hubs through its functions',
   'one-time codes with which display hubs join their stations (1179)'),
  ('net.hub_player', 'PLATFORM_CONFIDENTIAL', 'the platform reads; the station''s administration through its functions',
   'screen players on stations'' own networks, by hardware address, waiting, approved or rejected (1179)'),
  ('net.hub_event', 'PLATFORM_CONFIDENTIAL', 'the platform reads; the station''s administration through its functions',
   'what display hubs reported: unknown devices, players at another address, uplink cuts (1179)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.display_hub', 'net records', 'station display hubs (1179)'),
  ('net.hub_pairing', 'net records', 'pairing codes of display hubs (1179)'),
  ('net.hub_player', 'net records', 'screen players on stations'' own networks (1179)'),
  ('net.hub_event', 'net records', 'events reported by display hubs (1179)')
ON CONFLICT (table_name) DO NOTHING;

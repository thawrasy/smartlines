-- =====================================================================
-- 1142: the platform shield (owner's request, October 2026)
--   An application firewall in front of every API route, a watch on the platform's traffic that alerts the platform's
--   security staff when it turns abnormal, a shield level they control (normal, elevated, lockdown: traffic stopped
--   until they have checked), and one active session per account and portal.
--
--   * sec.waf_hit: each request the application firewall stopped or noted (attack patterns in the address, headers or
--     body; scanners; probes for files no route serves). Repeated hits from one address block it for a while
--     (sec.waf_strike, through sec.auto_block_ip, so the block escalates and expires like the others).
--   * sec.traffic_sample: what each API process saw in each 10-second window (requests, refusals, errors, firewall
--     hits, failed sign-ins, its busiest addresses). Kept 7 days.
--   * sec.traffic_alert: an abnormal minute (volume, spike over the usual, errors, firewall hits, a sign-in flood, one
--     address far above the rest), opened once and kept up to date while it lasts, acknowledged and resolved by staff.
--     Opening one notifies the security staff (outbox event security.traffic_alert).
--   * sec.shield_state: the level, its reason and end, the thresholds and automatic actions, and the session rule per
--     portal; sec.shield_event keeps every change of level.
--   Everything here is platform-only: no carrier, agency or traveller reads or writes a row.
-- =====================================================================

CREATE TABLE IF NOT EXISTS sec.shield_state (
  id              smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  level           text NOT NULL DEFAULT 'NORMAL' CHECK (level IN ('NORMAL', 'ELEVATED', 'LOCKDOWN')),
  reason          text CHECK (reason IS NULL OR length(reason) BETWEEN 3 AND 300),
  set_by          bigint REFERENCES iam.app_user(id),
  set_at          timestamptz NOT NULL DEFAULT now(),
  until           timestamptz,                    -- empty = until changed by hand
  auto            boolean NOT NULL DEFAULT false, -- raised by the platform itself, not by a person
  policy          jsonb NOT NULL DEFAULT '{
      "waf_mode": "BLOCK", "waf_strikes": 5, "waf_window_min": 10, "waf_block_min": 30,
      "alert_rpm": 20000, "alert_ip_rpm": 6000, "spike_factor": 4, "spike_min_rpm": 600,
      "alert_error_pct": 20, "alert_waf_per_min": 60, "alert_auth_fail_per_min": 300,
      "auto_block_heavy": true, "auto_elevate": true, "auto_elevate_min": 30,
      "elevated_rate_factor": 0.5, "lockdown_allow_signed_in": false}'::jsonb,
  session_policy  jsonb NOT NULL DEFAULT '{"PASSENGER": "SINGLE", "PLATFORM": "SINGLE", "OPERATOR": "SINGLE", "AGENCY": "SINGLE",
      "STATION": "SINGLE", "DRIVER": "SINGLE", "INSPECTOR": "SINGLE"}'::jsonb,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_typeof(policy) = 'object' AND jsonb_typeof(session_policy) = 'object'),
  CHECK (policy ->> 'waf_mode' IN ('OFF', 'DETECT', 'BLOCK'))
);
CREATE INDEX IF NOT EXISTS shield_state_set_by_fkx ON sec.shield_state (set_by);
INSERT INTO sec.shield_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
COMMENT ON TABLE sec.shield_state IS 'The platform shield: level (normal, elevated, lockdown), thresholds and automatic actions, one-session rule per portal (1142)';
COMMENT ON COLUMN sec.shield_state.policy IS 'alert_ip_rpm is five times the per-address API limit (1200 a minute): an address that keeps sending that much after being refused is a flood, not a busy shared mobile-network address';
COMMENT ON COLUMN sec.shield_state.session_policy IS 'Per portal: SINGLE (a new sign-in ends the account''s other sessions in that portal) or MULTI';

CREATE TABLE IF NOT EXISTS sec.shield_event (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  level       text NOT NULL CHECK (level IN ('NORMAL', 'ELEVATED', 'LOCKDOWN')),
  previous    text NOT NULL CHECK (previous IN ('NORMAL', 'ELEVATED', 'LOCKDOWN')),
  reason      text NOT NULL,
  set_by      bigint REFERENCES iam.app_user(id),
  auto        boolean NOT NULL,
  until       timestamptz
);
CREATE INDEX IF NOT EXISTS shield_event_set_by_fkx ON sec.shield_event (set_by);
CREATE INDEX IF NOT EXISTS shield_event_at_idx ON sec.shield_event (at DESC);
DROP TRIGGER IF EXISTS shield_event_frozen ON sec.shield_event;
CREATE TRIGGER shield_event_frozen BEFORE UPDATE OR DELETE ON sec.shield_event FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE sec.shield_event IS 'Every change of the shield level, by whom or by the platform, and why (1142); never rewritten';

CREATE TABLE IF NOT EXISTS sec.waf_hit (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  ip          inet NOT NULL,
  method      text NOT NULL CHECK (length(method) <= 10),
  path        text NOT NULL CHECK (length(path) <= 300),
  rule        text NOT NULL CHECK (rule ~ '^[a-z_]{2,40}$'),
  location    text NOT NULL CHECK (location IN ('METHOD', 'PATH', 'QUERY', 'HEADER', 'BODY', 'AGENT', 'SIZE')),
  sample      text CHECK (length(sample) <= 160),   -- the matched part, shortened; never a credential header
  user_agent  text CHECK (length(user_agent) <= 200),
  action      text NOT NULL CHECK (action IN ('BLOCKED', 'LOGGED'))
);
CREATE INDEX IF NOT EXISTS waf_hit_ip_at_idx ON sec.waf_hit (ip, at DESC);
CREATE INDEX IF NOT EXISTS waf_hit_at_idx ON sec.waf_hit (at DESC);
COMMENT ON TABLE sec.waf_hit IS 'A request the application firewall stopped (or noted, in detect mode): rule, where it matched, a short sample (1142); kept 30 days';

CREATE TABLE IF NOT EXISTS sec.traffic_sample (
  window_start   timestamptz NOT NULL,
  instance       text NOT NULL CHECK (length(instance) BETWEEN 1 AND 80),
  requests       int NOT NULL DEFAULT 0 CHECK (requests >= 0),
  err_4xx        int NOT NULL DEFAULT 0 CHECK (err_4xx >= 0),
  err_5xx        int NOT NULL DEFAULT 0 CHECK (err_5xx >= 0),
  blocked        int NOT NULL DEFAULT 0 CHECK (blocked >= 0),     -- refused by an address rule or the shield
  limited        int NOT NULL DEFAULT 0 CHECK (limited >= 0),     -- refused by a rate limit
  waf_hits       int NOT NULL DEFAULT 0 CHECK (waf_hits >= 0),
  auth_failures  int NOT NULL DEFAULT 0 CHECK (auth_failures >= 0),
  top            jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(top) = 'object'),   -- busiest addresses: {"ip": requests}
  PRIMARY KEY (window_start, instance)
);
COMMENT ON TABLE sec.traffic_sample IS 'Requests each API process saw in a 10-second window, with refusals, errors and its busiest addresses (1142); kept 7 days';

CREATE TABLE IF NOT EXISTS sec.traffic_alert (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  alert_key     text NOT NULL CHECK (length(alert_key) BETWEEN 3 AND 80),   -- VOLUME, SPIKE, ... or ADDRESS:<ip>
  kind          text NOT NULL CHECK (kind IN ('VOLUME', 'SPIKE', 'ERRORS', 'WAF', 'AUTH_FLOOD', 'HEAVY_ADDRESS')),
  severity      text NOT NULL CHECK (severity IN ('WARNING', 'CRITICAL')),
  status        text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'ACKNOWLEDGED', 'RESOLVED')),
  opened_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  metrics       jsonb NOT NULL,
  actions       jsonb NOT NULL DEFAULT '[]'::jsonb,   -- what the platform did by itself (address blocked, level raised)
  ack_by        bigint REFERENCES iam.app_user(id),
  ack_at        timestamptz,
  resolved_by   bigint REFERENCES iam.app_user(id),
  resolved_at   timestamptz,
  note          text CHECK (note IS NULL OR length(note) <= 500),
  CHECK ((status = 'RESOLVED') = (resolved_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS traffic_alert_live_uq ON sec.traffic_alert (alert_key) WHERE status <> 'RESOLVED';
CREATE INDEX IF NOT EXISTS traffic_alert_opened_idx ON sec.traffic_alert (opened_at DESC);
CREATE INDEX IF NOT EXISTS traffic_alert_ack_by_fkx ON sec.traffic_alert (ack_by);
CREATE INDEX IF NOT EXISTS traffic_alert_resolved_by_fkx ON sec.traffic_alert (resolved_by);
COMMENT ON TABLE sec.traffic_alert IS 'An abnormal minute of traffic, open until staff resolve it; one live alert per kind or address (1142)';

-- ------------------------------------------------------------------ platform only
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['sec.shield_state', 'sec.shield_event', 'sec.waf_hit', 'sec.traffic_sample', 'sec.traffic_alert'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS platform_only ON %s', t);
    EXECUTE format('CREATE POLICY platform_only ON %s USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform())', t);
    EXECUTE format('GRANT SELECT ON %s TO masslak_app, masslak_readonly, masslak_auditor', t);
  END LOOP;
END $$;
GRANT UPDATE (level, reason, set_by, set_at, until, auto, policy, session_policy, updated_at) ON sec.shield_state TO masslak_app;
GRANT INSERT ON sec.shield_event, sec.waf_hit, sec.traffic_alert TO masslak_app;
GRANT INSERT, UPDATE ON sec.traffic_sample TO masslak_app;
GRANT UPDATE (severity, status, last_seen_at, metrics, actions, ack_by, ack_at, resolved_by, resolved_at, note) ON sec.traffic_alert TO masslak_app;
-- the 7-day and 30-day upkeep (sec.shield_upkeep) deletes old samples and hits; registered as the review asks (1059)
INSERT INTO sys.app_delete_grant (table_name, reason) VALUES
  ('sec.traffic_sample', 'traffic samples older than 7 days are removed by the shield upkeep'),
  ('sec.waf_hit', 'firewall hits older than 30 days are removed by the shield upkeep')
ON CONFLICT (table_name) DO NOTHING;
GRANT DELETE ON sec.traffic_sample, sec.waf_hit TO masslak_app;

-- ------------------------------------------------------------------ functions
-- The shield as the API reads it: an ended level counts as normal until the worker records the return
CREATE OR REPLACE FUNCTION sec.shield_view() RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object('level', CASE WHEN s.until IS NOT NULL AND s.until <= now() THEN 'NORMAL' ELSE s.level END,
                            'until', s.until, 'auto', s.auto, 'reason', s.reason, 'set_at', s.set_at,
                            'policy', s.policy, 'session_policy', s.session_policy)
    FROM sec.shield_state s WHERE s.id = 1
$$;
REVOKE ALL ON FUNCTION sec.shield_view() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.shield_view() TO masslak_app;
COMMENT ON FUNCTION sec.shield_view IS 'The shield level in force with its thresholds and session rules, as the API applies them (1142)';

-- Sets the level, with the reason; LOCKDOWN and ELEVATED may end on their own. Platform scope only.
CREATE OR REPLACE FUNCTION sec.set_shield(p_level text, p_reason text, p_until timestamptz DEFAULT NULL, p_auto boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE prev text;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the shield is a platform control' USING ERRCODE = 'P0001';
  END IF;
  IF p_level NOT IN ('NORMAL', 'ELEVATED', 'LOCKDOWN') THEN
    RAISE EXCEPTION 'INVALID_LEVEL: NORMAL, ELEVATED or LOCKDOWN' USING ERRCODE = 'P0001';
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) NOT BETWEEN 3 AND 300 THEN
    RAISE EXCEPTION 'REASON_REQUIRED: name the reason for the change' USING ERRCODE = 'P0001';
  END IF;
  IF p_until IS NOT NULL AND (p_until <= now() OR p_level = 'NORMAL') THEN
    RAISE EXCEPTION 'INVALID_UNTIL: an end time is in the future, for a raised level' USING ERRCODE = 'P0001';
  END IF;
  SELECT CASE WHEN until IS NOT NULL AND until <= now() THEN 'NORMAL' ELSE level END INTO prev FROM sec.shield_state WHERE id = 1 FOR UPDATE;
  UPDATE sec.shield_state SET level = p_level, reason = btrim(p_reason), set_by = CASE WHEN p_auto THEN NULL ELSE sys.ctx_user_id() END,
         set_at = now(), until = p_until, auto = p_auto, updated_at = now() WHERE id = 1;
  INSERT INTO sec.shield_event (level, previous, reason, set_by, auto, until)
  VALUES (p_level, prev, btrim(p_reason), CASE WHEN p_auto THEN NULL ELSE sys.ctx_user_id() END, p_auto, p_until);
  IF prev IS DISTINCT FROM p_level THEN
    INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
    VALUES ('security.shield_changed', 'shield', 1,
            jsonb_build_object('level', p_level, 'previous', prev, 'reason', btrim(p_reason), 'auto', p_auto, 'until', p_until));
  END IF;
  RETURN sec.shield_view();
END $$;
REVOKE ALL ON FUNCTION sec.set_shield(text, text, timestamptz, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.set_shield(text, text, timestamptz, boolean) TO masslak_app;
COMMENT ON FUNCTION sec.set_shield IS 'Changes the shield level with the reason, records it and notifies the security staff (1142)';

-- A firewall hit from an address: recorded; at the policy's number of hits in its window the address is blocked for a
-- while (escalating on repeats, sec.auto_block_ip). Returns the address's hits in the window.
CREATE OR REPLACE FUNCTION sec.waf_strike(p_ip inet, p_method text, p_path text, p_rule text, p_location text,
                                          p_sample text, p_user_agent text, p_blocked boolean)
RETURNS int LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE pol jsonb; n int;
BEGIN
  SELECT policy INTO pol FROM sec.shield_state WHERE id = 1;
  INSERT INTO sec.waf_hit (ip, method, path, rule, location, sample, user_agent, action)
  VALUES (p_ip, left(p_method, 10), left(p_path, 300), p_rule, p_location, left(p_sample, 160), left(p_user_agent, 200),
          CASE WHEN p_blocked THEN 'BLOCKED' ELSE 'LOGGED' END);
  SELECT count(*) INTO n FROM sec.waf_hit
   WHERE ip = p_ip AND at > now() - make_interval(mins => coalesce((pol ->> 'waf_window_min')::int, 10));
  IF p_blocked AND n = coalesce((pol ->> 'waf_strikes')::int, 5) THEN
    PERFORM sec.auto_block_ip(p_ip, 'ALL', 'WAF', 'application firewall: repeated attack patterns',
                              coalesce((pol ->> 'waf_block_min')::int, 30), jsonb_build_object('rule', p_rule, 'hits', n));
  END IF;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION sec.waf_strike(inet, text, text, text, text, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.waf_strike(inet, text, text, text, text, text, text, boolean) TO masslak_app;
COMMENT ON FUNCTION sec.waf_strike IS 'Records an application firewall hit; blocks the address for a while at the policy''s number of hits (1142)';

-- Adds a process's 10-second counts (a process flushing twice in one window adds up)
CREATE OR REPLACE FUNCTION sec.add_traffic_sample(p_window timestamptz, p_instance text, p_requests int, p_err_4xx int,
                                                  p_err_5xx int, p_blocked int, p_limited int, p_waf int, p_auth_fail int, p_top jsonb)
RETURNS void LANGUAGE sql SET search_path = pg_catalog, pg_temp AS $$
  INSERT INTO sec.traffic_sample AS t (window_start, instance, requests, err_4xx, err_5xx, blocked, limited, waf_hits, auth_failures, top)
  VALUES (p_window, p_instance, p_requests, p_err_4xx, p_err_5xx, p_blocked, p_limited, p_waf, p_auth_fail, coalesce(p_top, '{}'::jsonb))
  ON CONFLICT (window_start, instance) DO UPDATE SET
    requests = t.requests + excluded.requests, err_4xx = t.err_4xx + excluded.err_4xx, err_5xx = t.err_5xx + excluded.err_5xx,
    blocked = t.blocked + excluded.blocked, limited = t.limited + excluded.limited, waf_hits = t.waf_hits + excluded.waf_hits,
    auth_failures = t.auth_failures + excluded.auth_failures,
    top = (SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
             FROM (SELECT k, sum(v::int) AS v FROM (SELECT * FROM jsonb_each_text(t.top) UNION ALL SELECT * FROM jsonb_each_text(excluded.top)) x(k, v)
                    GROUP BY k ORDER BY 2 DESC LIMIT 20) y)
$$;
REVOKE ALL ON FUNCTION sec.add_traffic_sample(timestamptz, text, int, int, int, int, int, int, int, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.add_traffic_sample(timestamptz, text, int, int, int, int, int, int, int, jsonb) TO masslak_app;
COMMENT ON FUNCTION sec.add_traffic_sample IS 'Adds an API process''s counts for a 10-second window (1142)';

-- Opens an alert, or keeps the live one of the same key up to date; true when it was opened now
CREATE OR REPLACE FUNCTION sec.raise_traffic_alert(p_key text, p_kind text, p_severity text, p_metrics jsonb, p_actions jsonb)
RETURNS boolean LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE aid bigint;
BEGIN
  UPDATE sec.traffic_alert SET last_seen_at = now(), metrics = p_metrics, actions = actions || coalesce(p_actions, '[]'::jsonb),
         severity = CASE WHEN p_severity = 'CRITICAL' THEN 'CRITICAL' ELSE severity END
   WHERE alert_key = p_key AND status <> 'RESOLVED';
  IF FOUND THEN
    RETURN false;
  END IF;
  INSERT INTO sec.traffic_alert (alert_key, kind, severity, metrics, actions)
  VALUES (p_key, p_kind, p_severity, p_metrics, coalesce(p_actions, '[]'::jsonb)) RETURNING id INTO aid;
  INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
  VALUES ('security.traffic_alert', 'traffic_alert', aid,
          jsonb_build_object('kind', p_kind, 'severity', p_severity, 'metrics', p_metrics, 'actions', coalesce(p_actions, '[]'::jsonb)));
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION sec.raise_traffic_alert(text, text, text, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.raise_traffic_alert(text, text, text, jsonb, jsonb) TO masslak_app;

-- Reads the last full minute against the usual of the hour before, opens alerts, takes the automatic actions the policy
-- allows (blocking an address far above the rest, raising the level to ELEVATED for a while), and returns the level
-- to NORMAL when a raised level ended. Run by the worker once a minute.
CREATE OR REPLACE FUNCTION sec.evaluate_traffic() RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  pol jsonb; st record; m record; usual numeric; opened int := 0; acts jsonb; critical boolean := false;
  t_end timestamptz := date_trunc('minute', now()); t_start timestamptz := date_trunc('minute', now()) - interval '1 minute';
  a record; err_pct numeric;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the traffic watch runs in the platform scope' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO st FROM sec.shield_state WHERE id = 1;
  pol := st.policy;
  IF st.level <> 'NORMAL' AND st.until IS NOT NULL AND st.until <= now() THEN
    PERFORM sec.set_shield('NORMAL', 'the raised level ended at its set time', NULL, true);
    SELECT * INTO st FROM sec.shield_state WHERE id = 1;
  END IF;

  SELECT coalesce(sum(requests), 0) AS requests, coalesce(sum(err_5xx), 0) AS err_5xx, coalesce(sum(waf_hits), 0) AS waf,
         coalesce(sum(auth_failures), 0) AS auth_fail, coalesce(sum(blocked), 0) AS blocked, coalesce(sum(limited), 0) AS limited
    INTO m FROM sec.traffic_sample WHERE window_start >= t_start AND window_start < t_end;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY n) INTO usual
    FROM (SELECT date_trunc('minute', window_start) AS mi, sum(requests) AS n FROM sec.traffic_sample
           WHERE window_start >= t_end - interval '62 minutes' AND window_start < t_end - interval '2 minutes' GROUP BY 1) x;

  IF m.requests > (pol ->> 'alert_rpm')::int THEN
    critical := true;
    opened := opened + sec.raise_traffic_alert('VOLUME', 'VOLUME', 'CRITICAL',
      jsonb_build_object('requests_per_min', m.requests, 'threshold', (pol ->> 'alert_rpm')::int), '[]')::int;
  END IF;
  IF usual IS NOT NULL AND usual >= (pol ->> 'spike_min_rpm')::int AND m.requests > usual * (pol ->> 'spike_factor')::numeric THEN
    opened := opened + sec.raise_traffic_alert('SPIKE', 'SPIKE', 'WARNING',
      jsonb_build_object('requests_per_min', m.requests, 'usual_per_min', round(usual), 'factor', (pol ->> 'spike_factor')::numeric), '[]')::int;
  END IF;
  err_pct := CASE WHEN m.requests >= 100 THEN 100.0 * m.err_5xx / m.requests END;
  IF err_pct IS NOT NULL AND err_pct > (pol ->> 'alert_error_pct')::numeric THEN
    opened := opened + sec.raise_traffic_alert('ERRORS', 'ERRORS', 'WARNING',
      jsonb_build_object('server_errors_pct', round(err_pct, 1), 'requests_per_min', m.requests), '[]')::int;
  END IF;
  IF m.waf > (pol ->> 'alert_waf_per_min')::int THEN
    opened := opened + sec.raise_traffic_alert('WAF', 'WAF', 'WARNING', jsonb_build_object('firewall_hits_per_min', m.waf), '[]')::int;
  END IF;
  IF m.auth_fail > (pol ->> 'alert_auth_fail_per_min')::int THEN
    opened := opened + sec.raise_traffic_alert('AUTH_FLOOD', 'AUTH_FLOOD', 'WARNING',
      jsonb_build_object('failed_sign_ins_per_min', m.auth_fail), '[]')::int;
  END IF;

  -- one address far above the rest: blocked for a while when the policy allows it (it can be lifted from the console)
  FOR a IN SELECT k AS ip, sum(v::int) AS n FROM sec.traffic_sample, jsonb_each_text(top) e(k, v)
            WHERE window_start >= t_start AND window_start < t_end GROUP BY k
           HAVING sum(v::int) > (pol ->> 'alert_ip_rpm')::int ORDER BY 2 DESC LIMIT 20 LOOP
    acts := '[]'::jsonb;
    IF coalesce((pol ->> 'auto_block_heavy')::boolean, false) AND a.ip ~ '^[0-9a-fA-F:./]+$' THEN
      PERFORM sec.auto_block_ip(split_part(a.ip, '/', 1)::inet, 'ALL', 'AUTO_RATE', 'traffic watch: far above the rest', 30,
                                jsonb_build_object('requests_per_min', a.n));
      acts := jsonb_build_array(jsonb_build_object('action', 'ADDRESS_BLOCKED', 'minutes', 30, 'at', now()));
    END IF;
    opened := opened + sec.raise_traffic_alert('ADDRESS:' || left(a.ip, 60), 'HEAVY_ADDRESS', 'WARNING',
      jsonb_build_object('address', a.ip, 'requests_per_min', a.n, 'threshold', (pol ->> 'alert_ip_rpm')::int), acts)::int;
  END LOOP;

  -- a critical minute raises the level for a while, never to lockdown: stopping the traffic is the staff's decision
  IF critical AND st.level = 'NORMAL' AND coalesce((pol ->> 'auto_elevate')::boolean, false) THEN
    PERFORM sec.set_shield('ELEVATED', 'traffic watch: abnormal volume', now() + make_interval(mins => coalesce((pol ->> 'auto_elevate_min')::int, 30)), true);
    UPDATE sec.traffic_alert SET actions = actions || jsonb_build_array(jsonb_build_object('action', 'LEVEL_ELEVATED', 'at', now()))
     WHERE alert_key = 'VOLUME' AND status <> 'RESOLVED';
  END IF;
  RETURN jsonb_build_object('minute', t_start, 'requests', m.requests, 'usual', round(usual), 'opened', opened,
                            'level', (SELECT level FROM sec.shield_state WHERE id = 1));
END $$;
REVOKE ALL ON FUNCTION sec.evaluate_traffic() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.evaluate_traffic() TO masslak_app;
COMMENT ON FUNCTION sec.evaluate_traffic IS 'The traffic watch: the last minute against the usual, alerts, automatic blocks and raised level (1142); once a minute';

-- Upkeep: samples older than 7 days, firewall hits older than 30
CREATE OR REPLACE FUNCTION sec.shield_upkeep() RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE s int; w int;
BEGIN
  DELETE FROM sec.traffic_sample WHERE window_start < now() - interval '7 days';
  GET DIAGNOSTICS s = ROW_COUNT;
  DELETE FROM sec.waf_hit WHERE at < now() - interval '30 days';
  GET DIAGNOSTICS w = ROW_COUNT;
  RETURN jsonb_build_object('samples', s, 'waf_hits', w);
END $$;
REVOKE ALL ON FUNCTION sec.shield_upkeep() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.shield_upkeep() TO masslak_app;

-- ------------------------------------------------------------------ registration
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('sec.shield_state', 'policy', 'CONFIG', 1, '{"type": "object", "required": ["waf_mode", "waf_strikes", "alert_rpm", "alert_ip_rpm"]}'::jsonb,
   'thresholds and automatic actions of the shield (1142)'),
  ('sec.shield_state', 'session_policy', 'CONFIG', 1, '{"type": "object"}'::jsonb, 'SINGLE or MULTI per portal (1142)'),
  ('sec.traffic_sample', 'top', 'EVIDENCE', 1, '{"type": "object"}'::jsonb, 'the busiest addresses of a window with their requests (1142)'),
  ('sec.traffic_alert', 'metrics', 'EVIDENCE', 1, '{"type": "object"}'::jsonb, 'the figures that opened or last updated the alert (1142)'),
  ('sec.traffic_alert', 'actions', 'EVIDENCE', 1, '{"type": "array"}'::jsonb, 'what the platform did by itself for the alert (1142)')
ON CONFLICT DO NOTHING;
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('sec.shield_state', '1A', 'E25'), ('sec.shield_event', '1A', 'E25'), ('sec.waf_hit', '1A', 'E25'),
  ('sec.traffic_sample', '1A', 'E25'), ('sec.traffic_alert', '1A', 'E25')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('sec.shield_state', 'sec records', 'the shield level, thresholds and session rules (1142)'),
  ('sec.shield_event', 'sec records', 'changes of the shield level (1142)'),
  ('sec.waf_hit', 'sec personal records', 'firewall hits with the client address, kept 30 days (1142)'),
  ('sec.traffic_sample', 'sec personal records', 'traffic per 10 seconds with the busiest client addresses, kept 7 days (1142)'),
  ('sec.traffic_alert', 'sec personal records', 'abnormal traffic, an address alert names the address (1142)')
ON CONFLICT (table_name) DO NOTHING;

-- 1167: the security watch (wave 7, owner's notes 20-32).
--   * security figures for the monitoring (sys.security_metrics): open traffic alerts by severity, firewall and bait
--     hits of the last 15 minutes by rule, failed sign-ins of the last 15 minutes, active address blocks by source,
--     the shield level, exceptions waiting for approval and those ending within 7 days;
--   * bait addresses (sec.bait_touch): paths no route serves and no honest client asks for (the API's robots.txt names
--     them as disallowed); touching one records a firewall hit with rule "bait" and blocks the address at once, for
--     security.bait_block_minutes (doubled for an address blocked before, as every automatic block);
--   * the exception register (sec.shield_exception): an address or range let through the shield (an ALLOW rule) is
--     requested by one person and approved by another, always with an end date no further than
--     security.exception_max_days; the approval writes the ALLOW rule, a revocation or the end date removes it;
--   * sign-in limits per device and per network as settings (the application takes the buckets, sec.rate_take): per
--     device identifier of the mobile apps, and per network (IPv4 /24, IPv6 /48 by default), on top of the existing
--     per-address and per-account limits;
--   * security.alert_telegram_chats: the Telegram chats the alert relay sends security alerts to.

INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('security.signin_device_per_minute', '10'::jsonb, 'PLATFORM',
   'Sign-in attempts a minute from one device identifier of the mobile apps (1167)'),
  ('security.signin_network_per_minute', '600'::jsonb, 'PLATFORM',
   'Sign-in attempts a minute from one network: many subscribers share a mobile network, so it is generous (1167)'),
  ('security.signin_network_prefix_v4', '24'::jsonb, 'PLATFORM', 'The IPv4 network size the network sign-in limit counts by (1167)'),
  ('security.signin_network_prefix_v6', '48'::jsonb, 'PLATFORM', 'The IPv6 network size the network sign-in limit counts by (1167)'),
  ('security.bait_block_minutes', '1440'::jsonb, 'PLATFORM',
   'Minutes an address that touched a bait address is blocked, doubled for an address blocked before (1167)'),
  ('security.exception_max_days', '90'::jsonb, 'PLATFORM', 'The longest an exception to the shield may last (1167)'),
  ('security.alert_telegram_chats', '[]'::jsonb, 'PLATFORM',
   'Telegram chat identifiers the alert relay sends security alerts to; empty sends none (1167)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION sec.setting_int(p_key text, p_default int) RETURNS int
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT CASE WHEN jsonb_typeof(value) = 'number' THEN (value #>> '{}')::int END
                     FROM sys.setting WHERE key = p_key), p_default)
$$;
COMMENT ON FUNCTION sec.setting_int(text, int) IS 'A whole-number platform setting of the security watch, or the default (1167)';
REVOKE ALL ON FUNCTION sec.setting_int(text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.setting_int(text, int) TO masslak_app;

-- ------------------------------------------------------------------ bait addresses
CREATE OR REPLACE FUNCTION sec.bait_touch(p_ip inet, p_method text, p_path text, p_user_agent text) RETURNS bigint
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE rid bigint; decision text;
BEGIN
  INSERT INTO sec.waf_hit (ip, method, path, rule, location, sample, user_agent, action)
  VALUES (p_ip, left(p_method, 10), left(p_path, 300), 'bait', 'PATH', left(p_path, 160), left(p_user_agent, 200), 'BLOCKED');
  SELECT action INTO decision FROM sec.ip_decision(p_ip, 'ALL');
  IF decision IS NOT DISTINCT FROM 'ALLOW' OR decision IS NOT DISTINCT FROM 'BLOCK' THEN
    RETURN NULL;                                  -- an approved exception, or already blocked
  END IF;
  rid := sec.auto_block_ip(p_ip, 'ALL', 'AUTO_ABUSE', 'bait address touched: ' || left(p_path, 120),
                           sec.setting_int('security.bait_block_minutes', 1440),
                           jsonb_build_object('rule', 'bait', 'path', left(p_path, 300), 'method', left(p_method, 10)));
  RETURN rid;
END $$;
COMMENT ON FUNCTION sec.bait_touch(inet, text, text, text) IS 'Records a touch of a bait address and blocks the client address at once, unless an exception lets it through (1167)';
REVOKE ALL ON FUNCTION sec.bait_touch(inet, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.bait_touch(inet, text, text, text) TO masslak_app;

-- ------------------------------------------------------------------ the exception register
CREATE TABLE IF NOT EXISTS sec.shield_exception (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  target        cidr NOT NULL,
  scope         text NOT NULL DEFAULT 'ALL'
                CHECK (scope IN ('ALL','PASSENGER','OPERATOR','AGENCY','ADMIN','API','PAYMENT_WEBHOOK','DRIVER')),
  reason        text NOT NULL CHECK (length(reason) BETWEEN 10 AND 500),
  status        text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','DECLINED','REVOKED')),
  requested_by  bigint NOT NULL REFERENCES iam.app_user(id),
  requested_at  timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  decided_by    bigint REFERENCES iam.app_user(id),
  decided_at    timestamptz,
  decision_note text CHECK (decision_note IS NULL OR length(decision_note) <= 500),
  ip_rule_id    bigint REFERENCES sec.ip_rule(id),
  revoked_by    bigint REFERENCES iam.app_user(id),
  revoked_at    timestamptz,
  CHECK (expires_at > requested_at),
  CHECK (decided_by IS NULL OR decided_by <> requested_by),
  CHECK ((status = 'PENDING') = (decided_at IS NULL)),
  CHECK ((status = 'APPROVED') <= (ip_rule_id IS NOT NULL)),
  CHECK ((status = 'REVOKED') = (revoked_at IS NOT NULL))
);
COMMENT ON TABLE sec.shield_exception IS 'An address or range let through the shield: requested by one person, approved by another, always with an end date (1167)';
COMMENT ON COLUMN sec.shield_exception.ip_rule_id IS 'The ALLOW rule the approval wrote; revoked with the exception';
CREATE INDEX IF NOT EXISTS shield_exception_requested_by ON sec.shield_exception (requested_by);
CREATE INDEX IF NOT EXISTS shield_exception_decided_by ON sec.shield_exception (decided_by);
CREATE INDEX IF NOT EXISTS shield_exception_revoked_by ON sec.shield_exception (revoked_by);
CREATE INDEX IF NOT EXISTS shield_exception_ip_rule ON sec.shield_exception (ip_rule_id);
CREATE INDEX IF NOT EXISTS shield_exception_open ON sec.shield_exception (status, expires_at) WHERE status IN ('PENDING','APPROVED');

CREATE OR REPLACE FUNCTION sec.tg_shield_exception() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE max_days int := sec.setting_int('security.exception_max_days', 90);
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'PENDING' THEN
      RAISE EXCEPTION 'EXCEPTION_NOT_PENDING: an exception starts as a request' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.expires_at <= now() OR NEW.expires_at > now() + make_interval(days => max_days) THEN
      RAISE EXCEPTION 'EXCEPTION_EXPIRY_INVALID: the end date must be within % days', max_days USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.target, NEW.scope, NEW.reason, NEW.requested_by, NEW.requested_at, NEW.expires_at)
     IS DISTINCT FROM (OLD.target, OLD.scope, OLD.reason, OLD.requested_by, OLD.requested_at, OLD.expires_at) THEN
    RAISE EXCEPTION 'EXCEPTION_FROZEN: a request is not changed; decline it and request again' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  IF OLD.status = 'PENDING' AND NEW.status IN ('APPROVED','DECLINED') THEN
    IF NEW.decided_by IS NULL OR NEW.decided_by = OLD.requested_by THEN
      RAISE EXCEPTION 'EXCEPTION_SAME_PERSON: another person decides an exception' USING ERRCODE = 'P0001';
    END IF;
    NEW.decided_at := now();
    IF NEW.status = 'APPROVED' THEN
      IF OLD.expires_at <= now() THEN
        RAISE EXCEPTION 'EXCEPTION_EXPIRY_INVALID: the request has passed its end date' USING ERRCODE = 'P0001';
      END IF;
      INSERT INTO sec.ip_rule (rule_type, cidr, action, scope, priority, reason, source, created_by, approved_by, expires_at)
      VALUES ('CIDR', OLD.target, 'ALLOW', OLD.scope, 300, 'exception ' || OLD.uid || ': ' || left(OLD.reason, 250), 'MANUAL',
              OLD.requested_by, NEW.decided_by, OLD.expires_at)
      RETURNING id INTO NEW.ip_rule_id;
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'APPROVED' AND NEW.status = 'REVOKED' THEN
    IF NEW.revoked_by IS NULL THEN
      RAISE EXCEPTION 'EXCEPTION_REVOKER_REQUIRED: a revocation names its person' USING ERRCODE = 'P0001';
    END IF;
    NEW.revoked_at := now();
    UPDATE sec.ip_rule SET revoked_at = now(), revoked_by = NEW.revoked_by,
                           revoke_reason = coalesce(NEW.decision_note, 'exception revoked')
     WHERE id = OLD.ip_rule_id AND revoked_at IS NULL;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'EXCEPTION_NOT_PENDING: % cannot become %', OLD.status, NEW.status USING ERRCODE = 'P0001';
END $$;
DROP TRIGGER IF EXISTS shield_exception_rules ON sec.shield_exception;
CREATE TRIGGER shield_exception_rules BEFORE INSERT OR UPDATE ON sec.shield_exception
  FOR EACH ROW EXECUTE FUNCTION sec.tg_shield_exception();

SELECT sys.rls('sec.shield_exception', 'sys.ctx_is_platform()', 'sys.ctx_is_platform()');
GRANT SELECT, INSERT ON sec.shield_exception TO masslak_app;
GRANT UPDATE (status, decided_by, decided_at, decision_note, ip_rule_id, revoked_by, revoked_at) ON sec.shield_exception TO masslak_app;
GRANT SELECT ON sec.shield_exception TO masslak_readonly, masslak_auditor;
DROP TRIGGER IF EXISTS zz_audit_capture ON sec.shield_exception;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON sec.shield_exception FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- ------------------------------------------------------------------ figures for the monitoring
CREATE OR REPLACE FUNCTION sys.security_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT 'masslak_context_unsigned_window_open', '{}'::jsonb,
         (EXISTS (SELECT 1 FROM sys.context_unsigned_window WHERE allowed_until > now()))::int::float8
  UNION ALL
  SELECT 'masslak_settings_guard_loaded', '{}'::jsonb, sys.guard_status()::int::float8
  UNION ALL
  SELECT 'masslak_security_alerts_open', jsonb_build_object('severity', s.sev),
         (SELECT count(*) FROM sec.traffic_alert a WHERE a.status <> 'RESOLVED' AND a.severity = s.sev)::float8
    FROM unnest(ARRAY['WARNING','CRITICAL']) AS s(sev)
  UNION ALL
  SELECT 'masslak_security_waf_hits_15m', jsonb_build_object('rule', r.rule), count(h.id)::float8
    FROM unnest(ARRAY['bait','probe','scanner','sql_injection','script_injection','command_injection','path_traversal',
                      'template_injection','metadata_address','null_byte','bad_method','oversize']) AS r(rule)
    LEFT JOIN sec.waf_hit h ON h.rule = r.rule AND h.at > now() - interval '15 minutes'
   GROUP BY r.rule
  UNION ALL
  SELECT 'masslak_security_auth_failures_15m', '{}'::jsonb,
         coalesce((SELECT sum(auth_failures) FROM sec.traffic_sample WHERE window_start > now() - interval '15 minutes'), 0)::float8
  UNION ALL
  SELECT 'masslak_security_ip_blocks_active', jsonb_build_object('source', s.src),
         (SELECT count(*) FROM sec.ip_rule i WHERE i.action = 'BLOCK' AND i.revoked_at IS NULL
             AND (i.expires_at IS NULL OR i.expires_at > now()) AND i.source = s.src)::float8
    FROM unnest(ARRAY['MANUAL','AUTO_RATE','AUTO_AUTH','AUTO_ABUSE','WAF','THREAT_FEED','SOC','AUTHORITY']) AS s(src)
  UNION ALL
  SELECT 'masslak_security_shield_level', '{}'::jsonb,
         coalesce((SELECT CASE level WHEN 'NORMAL' THEN 0 WHEN 'ELEVATED' THEN 1 ELSE 2 END FROM sec.shield_state WHERE id = 1), 0)::float8
  UNION ALL
  SELECT 'masslak_security_exceptions_pending', '{}'::jsonb,
         (SELECT count(*) FROM sec.shield_exception WHERE status = 'PENDING' AND expires_at > now())::float8
  UNION ALL
  SELECT 'masslak_security_exceptions_ending_7d', '{}'::jsonb,
         (SELECT count(*) FROM sec.shield_exception WHERE status = 'APPROVED' AND expires_at > now()
             AND expires_at < now() + interval '7 days')::float8
$$;
REVOKE ALL ON FUNCTION sys.security_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.security_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.security_metrics IS 'Security figures for the metrics endpoint: the context window and settings guard (1084); alerts, firewall and bait hits, failed sign-ins, blocks, shield level and exceptions (1167)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sec.shield_exception', '1A', 'E25')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('sec.shield_exception', 'sec records', 'addresses let through the shield, with requester, approver and end date (1167)')
ON CONFLICT (table_name) DO NOTHING;

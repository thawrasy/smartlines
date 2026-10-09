-- =====================================================================
-- 1075: two-factor sign-in by several methods, boarding and position integrity (review of release 1.47.0, package C)
-- =====================================================================
-- a. Two-factor sign-in (owner's decision 2, R-31). The platform chooses in its settings which methods are open
--    (an authenticator app, a text message, a WhatsApp message; one or more) and which portals must use one. A code
--    sent by message is kept only as a keyed hash, for a few minutes, with a limited number of tries. Drivers can now
--    be required to use one like any other staff.
-- b. A boarding names a stop of its trip, and a passenger boards only at a stop their ticket covers (R-10).
-- c. The first download of a trip's offline pack is recorded per driver: a scan made offline cannot have happened
--    before it (R-09).
-- d. The daily and monthly upkeep creates a partition for every past period that has rows waiting in the default
--    partition, not only the last one, so a long stop of the upkeep no longer leaves rows outside the retention (R-02).
-- e. Positions the telemetry database could not take wait on the primary and are delivered by the worker, so a
--    driver's history is not lost when the app cannot send it again (R-03).

-- ------------------------------------------------------------------ a. two-factor sign-in by several methods
ALTER TABLE iam.mfa_factor DROP CONSTRAINT IF EXISTS mfa_factor_factor_type_check;
ALTER TABLE iam.mfa_factor ADD CONSTRAINT mfa_factor_factor_type_check
  CHECK (factor_type IN ('TOTP','SMS','WHATSAPP','PASSKEY','RECOVERY_CODES'));
COMMENT ON TABLE iam.mfa_factor IS
  'Second factors: TOTP (encrypted secret), SMS and WHATSAPP (the encrypted phone number the codes go to, its last four digits in label), passkeys, recovery codes (1075)';

-- one verified factor of each kind and one being enrolled: a new phone or number is enrolled while the old one still
-- works, and replaces it only once its first code is confirmed
DROP INDEX IF EXISTS iam.mfa_factor_one_active;
CREATE UNIQUE INDEX IF NOT EXISTS mfa_factor_one_verified ON iam.mfa_factor (user_id, factor_type)
  WHERE disabled_at IS NULL AND verified_at IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS mfa_factor_one_pending ON iam.mfa_factor (user_id, factor_type)
  WHERE disabled_at IS NULL AND verified_at IS NULL;

CREATE TABLE IF NOT EXISTS iam.mfa_challenge (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid         uuid NOT NULL UNIQUE,
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  factor_id   bigint NOT NULL REFERENCES iam.mfa_factor(id),
  session_id  bigint REFERENCES iam.user_session(id),
  channel     text NOT NULL CHECK (channel IN ('SMS','WHATSAPP')),
  purpose     text NOT NULL CHECK (purpose IN ('ENROL','VERIFY')),
  code_hash   bytea NOT NULL CHECK (octet_length(code_hash) = 32),
  attempts    smallint NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
  expires_at  timestamptz NOT NULL,
  consumed_at timestamptz,
  sent_at     timestamptz,
  send_error  text CHECK (send_error IS NULL OR length(send_error) <= 300),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '15 minutes')
);
CREATE INDEX IF NOT EXISTS mfa_challenge_user_idx ON iam.mfa_challenge (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS mfa_challenge_factor_id_fkx ON iam.mfa_challenge (factor_id);
CREATE INDEX IF NOT EXISTS mfa_challenge_session_id_fkx ON iam.mfa_challenge (session_id);
COMMENT ON TABLE iam.mfa_challenge IS
  'A one-time code sent by text or WhatsApp message: only its keyed hash is kept, it expires within minutes and allows five tries (1075, decision 2)';
COMMENT ON COLUMN iam.mfa_challenge.code_hash IS 'HMAC-SHA256 of the code with the blind-index key, scoped by the challenge uid; the code itself is never stored';
SELECT sys.rls('iam.mfa_challenge', 'sys.ctx_is_platform() OR sys.ctx_is_auth() OR user_id = sys.ctx_user_id()');
ALTER TABLE iam.mfa_challenge FORCE ROW LEVEL SECURITY;          -- like the factors themselves (1039)
GRANT SELECT, INSERT, UPDATE ON iam.mfa_challenge TO masslak_app;

-- the policy, edited by the security officers: which methods are open, which portals must use one
INSERT INTO sys.setting (key, value, description) VALUES
  ('auth.mfa', jsonb_build_object(
      'methods', jsonb_build_array('TOTP', 'SMS', 'WHATSAPP'),
      'required_portals', jsonb_build_array('PLATFORM', 'INSPECTOR', 'OPERATOR', 'DRIVER', 'AGENCY'),
      'enforce_in_sandbox', false, 'code_minutes', 5, 'resend_seconds', 60, 'sends_per_hour', 5),
   'Two-factor sign-in: the methods open (TOTP, SMS, WHATSAPP), the portals that must use one, and the message code limits (1075, decision 2)')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------ b. a boarding names a stop of its trip
ALTER TABLE sales.boarding_event DROP CONSTRAINT IF EXISTS boarding_event_result_check;
ALTER TABLE sales.boarding_event ADD CONSTRAINT boarding_event_result_check
  CHECK (result IN ('OK','DUPLICATE','INVALID_QR','WRONG_TRIP','DOCS_REQUIRED','WRONG_STOP'));

CREATE OR REPLACE FUNCTION sales.tg_boarding_stop() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ops.trip_stop WHERE trip_id = NEW.trip_id AND seq = NEW.stop_seq) THEN
    RAISE EXCEPTION 'UNKNOWN_STOP: stop % is not a stop of this trip', NEW.stop_seq USING ERRCODE = 'P0001';
  END IF;
  IF NEW.ticket_id IS NOT NULL AND NEW.event_type = 'BOARD' THEN
    SELECT from_seq, to_seq INTO k FROM sales.ticket WHERE id = NEW.ticket_id;
    IF NEW.stop_seq < k.from_seq OR NEW.stop_seq >= k.to_seq THEN
      RAISE EXCEPTION 'STOP_OUTSIDE_TICKET: the ticket covers stops % to %, not a boarding at %', k.from_seq, k.to_seq, NEW.stop_seq
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS boarding_stop ON sales.boarding_event;
CREATE TRIGGER boarding_stop BEFORE INSERT ON sales.boarding_event
  FOR EACH ROW EXECUTE FUNCTION sales.tg_boarding_stop();
COMMENT ON FUNCTION sales.tg_boarding_stop() IS
  'A boarding names a stop of its trip; a passenger boards only at a stop between the start of their ticket and its end (1075, R-10)';

-- ------------------------------------------------------------------ c. offline packs downloaded, per driver and trip
CREATE TABLE IF NOT EXISTS ops.offline_pack_download (
  trip_id        bigint NOT NULL REFERENCES ops.trip(id),
  user_id        bigint NOT NULL REFERENCES iam.app_user(id),
  company_id     bigint NOT NULL REFERENCES iam.company(id),
  first_at       timestamptz NOT NULL DEFAULT now(),
  last_at        timestamptz NOT NULL DEFAULT now(),
  downloads      int NOT NULL DEFAULT 1 CHECK (downloads > 0),
  PRIMARY KEY (trip_id, user_id),
  CHECK (last_at >= first_at)
);
CREATE INDEX IF NOT EXISTS offline_pack_download_user_id_fkx ON ops.offline_pack_download (user_id);
CREATE INDEX IF NOT EXISTS offline_pack_download_company_id_fkx ON ops.offline_pack_download (company_id);
COMMENT ON TABLE ops.offline_pack_download IS
  'When a driver first and last downloaded a trip''s offline boarding pack; a scan made offline cannot be older than the first download (1075, R-09)';
SELECT sys.rls_tenant('ops.offline_pack_download');
GRANT SELECT, INSERT, UPDATE ON ops.offline_pack_download TO masslak_app;
GRANT SELECT ON ops.offline_pack_download TO masslak_readonly, masslak_auditor;

-- ------------------------------------------------------------------ d. every late period gets its partition
-- The oldest row waiting in a table's default partition: the upkeep starts from its period when that is older than
-- the usual look-back, so each day (month) of a long stop is created and its rows moved by sys.create_partition.
CREATE OR REPLACE FUNCTION sys.default_partition_oldest(p_parent text) RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE def regclass; key text; oldest timestamptz;
BEGIN
  SELECT k.oid::regclass INTO def FROM pg_inherits i JOIN pg_class k ON k.oid = i.inhrelid
   WHERE i.inhparent = p_parent::regclass AND pg_get_expr(k.relpartbound, k.oid) = 'DEFAULT';
  IF def IS NULL THEN RETURN NULL; END IF;
  SELECT a.attname INTO key FROM pg_partitioned_table pt
    JOIN pg_attribute a ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
   WHERE pt.partrelid = p_parent::regclass;
  EXECUTE format('SELECT min(%I)::timestamptz FROM %s', key, def) INTO oldest;
  RETURN oldest;
END $$;
REVOKE EXECUTE ON FUNCTION sys.default_partition_oldest(text) FROM PUBLIC;
COMMENT ON FUNCTION sys.default_partition_oldest(text) IS
  'The oldest key waiting in a time-partitioned table''s default partition, or NULL (1075, R-02)';

CREATE OR REPLACE FUNCTION sys.ensure_daily_partitions(p_parent text, p_days_ahead integer DEFAULT 7, p_days_back integer DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE d date; part text; sch text := split_part(p_parent, '.', 1); tbl text := split_part(p_parent, '.', 2);
        start date := current_date - p_days_back; oldest timestamptz := sys.default_partition_oldest(p_parent);
BEGIN
  IF oldest IS NOT NULL AND oldest::date < start THEN
    start := oldest::date;                 -- the upkeep stopped for longer than its look-back (R-02)
  END IF;
  FOR d IN SELECT generate_series(start, current_date + p_days_ahead, interval '1 day')::date LOOP
    part := format('%I.%I', sch, tbl || '_' || to_char(d, 'YYYYMMDD'));
    IF to_regclass(part) IS NULL THEN
      PERFORM sys.create_partition(p_parent, part, d::text, (d + 1)::text);
      PERFORM sys.apply_partition_options(part, p_parent);
    END IF;
  END LOOP;
  part := format('%I.%I', sch, tbl || '_default');
  IF to_regclass(part) IS NULL THEN
    EXECUTE format('CREATE TABLE %s PARTITION OF %s DEFAULT', part, p_parent);
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION sys.ensure_monthly_partitions(p_parent text, p_months_ahead integer DEFAULT 3, p_months_back integer DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE m date; part text; sch text := split_part(p_parent, '.', 1); tbl text := split_part(p_parent, '.', 2);
        start date := (date_trunc('month', now()) - make_interval(months => p_months_back))::date;
        oldest timestamptz := sys.default_partition_oldest(p_parent);
BEGIN
  IF oldest IS NOT NULL AND date_trunc('month', oldest)::date < start THEN
    start := date_trunc('month', oldest)::date;
  END IF;
  FOR m IN SELECT generate_series(start, date_trunc('month', now()) + make_interval(months => p_months_ahead),
                                  interval '1 month')::date LOOP
    part := format('%I.%I', sch, tbl || '_' || to_char(m, 'YYYYMM'));
    IF to_regclass(part) IS NULL THEN
      PERFORM sys.create_partition(p_parent, part, m::text, (m + interval '1 month')::date::text);
      PERFORM sys.apply_partition_options(part, p_parent);
    END IF;
  END LOOP;
  part := format('%I.%I', sch, tbl || '_default');
  IF to_regclass(part) IS NULL THEN
    EXECUTE format('CREATE TABLE %s PARTITION OF %s DEFAULT', part, p_parent);
  END IF;
END $function$;

-- ------------------------------------------------------------------ e. positions waiting for the telemetry database
CREATE TABLE IF NOT EXISTS ops.position_backlog (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id       bigint NOT NULL REFERENCES ops.trip(id),
  company_id    bigint NOT NULL REFERENCES iam.company(id),
  positions     jsonb NOT NULL CHECK (jsonb_typeof(positions) = 'array' AND jsonb_array_length(positions) BETWEEN 1 AND 120),
  created_at    timestamptz NOT NULL DEFAULT now(),
  attempts      int NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error    text CHECK (last_error IS NULL OR length(last_error) <= 300),
  delivered_at  timestamptz
);
CREATE INDEX IF NOT EXISTS position_backlog_waiting_idx ON ops.position_backlog (created_at) WHERE delivered_at IS NULL;
CREATE INDEX IF NOT EXISTS position_backlog_trip_id_fkx ON ops.position_backlog (trip_id);
CREATE INDEX IF NOT EXISTS position_backlog_company_id_fkx ON ops.position_backlog (company_id);
COMMENT ON TABLE ops.position_backlog IS
  'Graded positions the telemetry database could not take when they arrived; the worker delivers them in order (duplicates skipped there) (1075, R-03)';
SELECT sys.rls_tenant('ops.position_backlog');
GRANT SELECT, INSERT, UPDATE ON ops.position_backlog TO masslak_app;
GRANT SELECT ON ops.position_backlog TO masslak_readonly, masslak_auditor;

INSERT INTO sys.json_contract (table_name, column_name, kind, version, note) VALUES
  ('ops.position_backlog', 'positions', 'PAYLOAD', 1, 'Graded positions as the telemetry database stores them, one object each (telemetry._COLUMNS)')
ON CONFLICT DO NOTHING;

-- the backlog for the monitoring scrape: positions waiting and the age of the oldest
CREATE OR REPLACE FUNCTION ops.position_backlog_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT 'masslak_position_backlog_batches', '{}'::jsonb, count(*)::float8
    FROM ops.position_backlog WHERE delivered_at IS NULL
  UNION ALL
  SELECT 'masslak_position_backlog_oldest_seconds', '{}'::jsonb,
         coalesce(extract(epoch FROM now() - min(created_at)), 0)::float8
    FROM ops.position_backlog WHERE delivered_at IS NULL
$$;
REVOKE EXECUTE ON FUNCTION ops.position_backlog_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.position_backlog_metrics() TO masslak_app, masslak_readonly;

-- ------------------------------------------------------------------ purge: old challenges and delivered backlog
CREATE OR REPLACE FUNCTION sys.purge_expired() RETURNS jsonb LANGUAGE plpgsql
  SECURITY DEFINER SET search_path TO 'pg_catalog', 'pg_temp' AS $function$
DECLARE d_out int := 0; d_days int := 0; d_hook int := 0; d_note int := 0; d_code int := 0; d_pos int := 0; days int;
  held text[] := ARRAY(SELECT dataset FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'DATASET');
BEGIN
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'sys.webhook_delivery';
  IF days IS NOT NULL AND NOT 'sys.webhook_delivery' = ANY (held) THEN
    DELETE FROM sys.webhook_delivery WHERE status IN ('DELIVERED','DEAD') AND created_at < now() - make_interval(days => days);
    GET DIAGNOSTICS d_hook = ROW_COUNT;
  END IF;
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'sys.outbox_event';
  IF days IS NOT NULL AND NOT 'sys.outbox_event' = ANY (held) THEN
    d_days := sys.drop_outbox_days();
    IF to_regclass('sys.outbox_event_default') IS NOT NULL THEN
      DELETE FROM sys.outbox_event_default o WHERE o.status = 'PUBLISHED' AND o.published_at < now() - make_interval(days => days)
         AND NOT EXISTS (SELECT 1 FROM sys.webhook_delivery w WHERE w.outbox_event_id = o.id AND w.outbox_created_at = o.created_at);
      GET DIAGNOSTICS d_out = ROW_COUNT;
    END IF;
  END IF;
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'crm.notification';
  IF days IS NOT NULL AND NOT 'crm.notification' = ANY (held) THEN
    DELETE FROM crm.notification WHERE created_at < now() - make_interval(days => days);
    GET DIAGNOSTICS d_note = ROW_COUNT;
  END IF;
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'iam.mfa_challenge';
  IF days IS NOT NULL AND NOT 'iam.mfa_challenge' = ANY (held) THEN
    DELETE FROM iam.mfa_challenge WHERE created_at < now() - make_interval(days => days);
    GET DIAGNOSTICS d_code = ROW_COUNT;
  END IF;
  SELECT retention_days INTO days FROM gov.data_inventory WHERE dataset = 'ops.position_backlog';
  IF days IS NOT NULL AND NOT 'ops.position_backlog' = ANY (held) THEN
    DELETE FROM ops.position_backlog WHERE delivered_at < now() - make_interval(days => days);
    GET DIAGNOSTICS d_pos = ROW_COUNT;
  END IF;
  RETURN jsonb_build_object('outbox_events', d_out, 'outbox_days_dropped', d_days, 'webhook_deliveries', d_hook,
                            'notifications', d_note, 'mfa_challenges', d_code, 'position_backlog', d_pos);
END $function$;

-- ------------------------------------------------------------------ registrations
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('iam.mfa_challenge', '1A', 'E02'), ('ops.offline_pack_download', '1A', 'E11'), ('ops.position_backlog', '1A', 'E09')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days) VALUES
  ('iam.mfa_challenge', 'CONFIDENTIAL', 'iam', 'One-time sign-in codes sent by message, kept as keyed hashes to check them and count tries', 'Security of processing', 30, 'DELETE', '{replica,backup}', 35),
  ('ops.position_backlog', 'CONFIDENTIAL', 'ops', 'Vehicle positions waiting for the telemetry database', 'Contract', 7, 'DELETE', '{replica,backup}', 35),
  ('ops.offline_pack_download', 'INTERNAL', 'ops', 'When drivers downloaded offline boarding packs, to bound the time of offline scans', 'Contract', 400, 'KEEP_LEGAL', '{replica,backup}', 35)
ON CONFLICT (dataset) DO NOTHING;

SELECT sys.refresh_table_class();

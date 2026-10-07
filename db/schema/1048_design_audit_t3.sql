-- =====================================================================
-- 1048: the technical audit of design document v3.7 (findings T3-xx; see docs/database/DESIGN_AUDIT_T3.md)
--   A  T3-04: an official signature, a ledger transaction, a family spend or a legal hold names a real row of a
--      registered kind the moment it is written, not only at the weekly sweep.
--   B  T3-03: break-glass access expires on its own, needs an approver other than its user (or a declared emergency
--      reviewed afterwards), names its incident, alerts at once, and cannot be rewritten.
--   C  T3-10, T3-11: tracking positions sit in daily partitions that match their retention, with one source for that
--      retention; each position carries the device's event id, sequence, device and server times and a trust grade,
--      duplicates are refused, and a violation built on low-trust positions needs a person's review before it counts.
--   D  T3-14: a regulatory requirement changes only through a proposal approved by a second person, with its impact
--      measured when proposed.
--   E  T3-15: an uploaded file is quarantined until it is scanned; only a CLEAN file can be signed or downloaded.
--   F  T3-19: nobody reviews their own access, and every read of sensitive data names its actor and request.
--   G  T3-02, T3-18: government endpoints use encrypted transports; every city names a real time zone.
--   H  T3-12: every outbox event carries its schema version, correlation id and a sequence per aggregate.
-- =====================================================================

-- =====================================================================
-- A  T3-04: references that carry legal or financial weight
-- =====================================================================
-- Official signatures: the document kinds are registered, and the signed row is checked when the signature is written.
-- Real foreign keys would make sec depend on acct and brd, which already depend on sec (test H-07), so the check is a
-- trigger, and the weekly sweep watches for a signed row removed later.
INSERT INTO sys.polymorphic_reference (table_name, type_col, id_col, kind, targets, owner, reason) VALUES
  ('sec.document_signature', 'doc_type', 'doc_ref_id', 'BUSINESS',
   '{"TICKET":"sales.ticket","BOARDING_PASS":"sales.ticket","INVOICE":"acct.sales_invoice","RECEIPT":"fin.payment",
     "MANIFEST":"brd.manifest","STATEMENT":"fin.settlement_batch"}', 'sec',
   'An official signature names the document it signs; foreign keys would create schema cycles')
ON CONFLICT (table_name, type_col) DO UPDATE SET targets = EXCLUDED.targets, kind = EXCLUDED.kind, reason = EXCLUDED.reason;
COMMENT ON COLUMN sec.document_signature.doc_ref_id IS 'Polymorphic: the row named by (doc_type, doc_ref_id); checked when written by sys.tg_business_reference (audit T3-04)';

-- A signature is written once; only its revocation is recorded afterwards
CREATE OR REPLACE FUNCTION sec.tg_signature_sealed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'SIGNATURE_SEALED: an issued signature is never deleted; revoke it' USING ERRCODE = 'P0001';
  END IF;
  IF (to_jsonb(NEW) - 'revoked_at') IS DISTINCT FROM (to_jsonb(OLD) - 'revoked_at')
     OR (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at) THEN
    RAISE EXCEPTION 'SIGNATURE_SEALED: only the revocation of a signature can be recorded, once' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS signature_sealed ON sec.document_signature;
CREATE TRIGGER signature_sealed BEFORE UPDATE OR DELETE ON sec.document_signature
  FOR EACH ROW EXECUTE FUNCTION sec.tg_signature_sealed();

-- Business references (ledger, family spending, legal holds) are checked when written; the weekly sweep stays as a net
CREATE OR REPLACE FUNCTION sys.tg_business_reference() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_type_col text := TG_ARGV[0]; v_id_col text := TG_ARGV[1];
  rec jsonb := to_jsonb(NEW); t text := rec ->> v_type_col; ref bigint := (rec ->> v_id_col)::bigint; target text; found boolean;
BEGIN
  IF t IS NULL OR ref IS NULL THEN          -- a kind without a row (a dataset hold, a posting not tied to one row)
    IF t IS NULL AND ref IS NOT NULL THEN
      RAISE EXCEPTION 'REFERENCE_TYPE_MISSING: %.% is set without %', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_id_col, v_type_col
        USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  SELECT r.targets ->> t INTO target FROM sys.polymorphic_reference r
   WHERE r.table_name = TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME AND r.type_col = v_type_col;
  IF target IS NULL THEN
    RAISE EXCEPTION 'REFERENCE_TYPE_UNKNOWN: % is not a registered kind for %.%', t, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_type_col
      USING ERRCODE = 'P0001';
  END IF;
  EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE id = $1)', target) INTO found USING ref;
  IF NOT found THEN
    RAISE EXCEPTION 'REFERENCE_MISSING: % % does not exist (%.%)', t, ref, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_id_col
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION sys.tg_business_reference IS 'Checks a registered (type, id) reference when it is written: the kind is registered and the row exists (audit T3-04)';

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT table_name, type_col, id_col FROM sys.polymorphic_reference
            WHERE table_name IN ('fin.ledger_txn', 'iam.family_spend', 'gov.legal_hold', 'sec.document_signature') LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', r.type_col || '_checked', r.table_name);
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF %I, %I ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_business_reference(%L, %L)',
                   r.type_col || '_checked', r.type_col, r.id_col, r.table_name, r.type_col, r.id_col);
  END LOOP;
END $$;
UPDATE sys.polymorphic_reference SET reason = reason || '; checked when written (sys.tg_business_reference)'
 WHERE table_name IN ('fin.ledger_txn', 'iam.family_spend', 'gov.legal_hold', 'sec.document_signature') AND reason NOT LIKE '%checked when written%';

-- =====================================================================
-- B  T3-03: break-glass access
-- =====================================================================
ALTER TABLE sec.break_glass_log
  ADD COLUMN IF NOT EXISTS expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS incident_ref text,
  ADD COLUMN IF NOT EXISTS scope text,
  ADD COLUMN IF NOT EXISTS emergency boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS closed_reason text,
  ADD COLUMN IF NOT EXISTS reviewed_by bigint REFERENCES iam.app_user(id),
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS review_note text,
  ADD COLUMN IF NOT EXISTS review_alerted_at timestamptz;
UPDATE sec.break_glass_log SET expires_at = coalesce(ended_at, started_at + interval '4 hours') WHERE expires_at IS NULL;
UPDATE sec.break_glass_log SET incident_ref = 'LEGACY-' || id WHERE incident_ref IS NULL;
UPDATE sec.break_glass_log SET scope = 'UNSPECIFIED' WHERE scope IS NULL;
UPDATE sec.break_glass_log SET emergency = true WHERE approver_id IS NULL;
ALTER TABLE sec.break_glass_log ALTER COLUMN expires_at SET NOT NULL, ALTER COLUMN incident_ref SET NOT NULL, ALTER COLUMN scope SET NOT NULL;
CREATE INDEX IF NOT EXISTS break_glass_log_reviewed_by_fkx ON sec.break_glass_log (reviewed_by);
CREATE INDEX IF NOT EXISTS break_glass_log_open_idx ON sec.break_glass_log (actor_id, expires_at) WHERE ended_at IS NULL;
DO $$
BEGIN
  ALTER TABLE sec.break_glass_log DROP CONSTRAINT IF EXISTS break_glass_window;
  ALTER TABLE sec.break_glass_log ADD CONSTRAINT break_glass_window CHECK (expires_at > started_at AND (ended_at IS NULL OR ended_at >= started_at));
  ALTER TABLE sec.break_glass_log DROP CONSTRAINT IF EXISTS break_glass_approved;
  ALTER TABLE sec.break_glass_log ADD CONSTRAINT break_glass_approved CHECK (approver_id IS NOT NULL OR emergency);
  ALTER TABLE sec.break_glass_log DROP CONSTRAINT IF EXISTS break_glass_reviewer;
  ALTER TABLE sec.break_glass_log ADD CONSTRAINT break_glass_reviewer CHECK (reviewed_by IS NULL OR reviewed_by <> actor_id);
  ALTER TABLE sec.break_glass_log DROP CONSTRAINT IF EXISTS break_glass_closed_reason;
  ALTER TABLE sec.break_glass_log ADD CONSTRAINT break_glass_closed_reason
    CHECK ((ended_at IS NULL) = (closed_reason IS NULL) AND (closed_reason IS NULL OR closed_reason IN ('ENDED','EXPIRED','REVOKED')));
  ALTER TABLE sec.break_glass_log DROP CONSTRAINT IF EXISTS break_glass_incident;
  ALTER TABLE sec.break_glass_log ADD CONSTRAINT break_glass_incident CHECK (length(btrim(incident_ref)) >= 3 AND length(btrim(reason)) >= 10);
END $$;
UPDATE sec.break_glass_log SET closed_reason = 'ENDED' WHERE ended_at IS NOT NULL AND closed_reason IS NULL;

INSERT INTO sys.setting (key, value, description) VALUES
  ('security.break_glass_max_minutes', '240', 'Longest break-glass access that can be granted; it then expires on its own'),
  ('security.break_glass_review_hours', '24', 'An emergency break-glass access must be reviewed within this many hours of its end'),
  ('reports.platform_recipient_domains', '["masslak.com"]', 'Mail domains a platform report may be sent to, besides platform accounts (audit T3-05)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION sec.tg_break_glass_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE max_min int := coalesce((SELECT value::int FROM sys.setting WHERE key = 'security.break_glass_max_minutes'), 240);
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'BREAK_GLASS_SEALED: a break-glass record is never deleted' USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.expires_at > NEW.started_at + make_interval(mins => max_min) THEN
      RAISE EXCEPTION 'BREAK_GLASS_TOO_LONG: break-glass access lasts at most % minutes', max_min USING ERRCODE = 'P0001';
    END IF;
    IF NEW.ended_at IS NOT NULL OR NEW.reviewed_by IS NOT NULL THEN
      RAISE EXCEPTION 'BREAK_GLASS_SEALED: a break-glass access opens without an end or a review' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.approver_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM iam.app_user u WHERE u.id = NEW.approver_id AND u.status = 'ACTIVE') THEN
      RAISE EXCEPTION 'BREAK_GLASS_APPROVER: the approver is not an active account' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
    VALUES ('security.break_glass_opened', 'break_glass', NEW.id,
            jsonb_build_object('actor_id', NEW.actor_id, 'approver_id', NEW.approver_id, 'emergency', NEW.emergency,
                               'incident_ref', NEW.incident_ref, 'scope', NEW.scope, 'expires_at', NEW.expires_at));
    RETURN NEW;
  END IF;
  -- UPDATE: the grant itself never changes; it can be shortened, closed once and reviewed once
  IF NEW.actor_id <> OLD.actor_id OR NEW.reason <> OLD.reason OR NEW.approver_id IS DISTINCT FROM OLD.approver_id
     OR NEW.started_at <> OLD.started_at OR NEW.incident_ref <> OLD.incident_ref OR NEW.scope <> OLD.scope
     OR NEW.emergency <> OLD.emergency OR NEW.expires_at > OLD.expires_at THEN
    RAISE EXCEPTION 'BREAK_GLASS_SEALED: a break-glass grant cannot be widened or rewritten' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.ended_at IS NOT NULL AND (NEW.ended_at IS DISTINCT FROM OLD.ended_at OR NEW.closed_reason IS DISTINCT FROM OLD.closed_reason) THEN
    RAISE EXCEPTION 'BREAK_GLASS_SEALED: a closed break-glass access stays closed' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.reviewed_by IS NOT NULL AND (NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
                                      OR NEW.review_note IS DISTINCT FROM OLD.review_note) THEN
    RAISE EXCEPTION 'BREAK_GLASS_SEALED: a review is recorded once' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.reviewed_by IS NOT NULL AND OLD.reviewed_by IS NULL THEN
    IF NEW.ended_at IS NULL THEN
      RAISE EXCEPTION 'BREAK_GLASS_REVIEW: an access is reviewed after it ends' USING ERRCODE = 'P0001';
    END IF;
    IF length(btrim(coalesce(NEW.review_note, ''))) < 10 THEN
      RAISE EXCEPTION 'BREAK_GLASS_REVIEW: the review needs a note of what was accessed and why' USING ERRCODE = 'P0001';
    END IF;
    NEW.reviewed_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS break_glass_rules ON sec.break_glass_log;
CREATE TRIGGER break_glass_rules BEFORE INSERT OR UPDATE OR DELETE ON sec.break_glass_log
  FOR EACH ROW EXECUTE FUNCTION sec.tg_break_glass_rules();
REVOKE DELETE ON sec.break_glass_log FROM masslak_app;

CREATE OR REPLACE FUNCTION sec.break_glass_active(p_actor bigint, p_scope text DEFAULT NULL) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM sec.break_glass_log b
                  WHERE b.actor_id = p_actor AND b.ended_at IS NULL AND b.expires_at > now()
                    AND (p_scope IS NULL OR b.scope IN (p_scope, 'ALL')))
$$;
COMMENT ON FUNCTION sec.break_glass_active IS 'Whether an account holds an open, unexpired break-glass access; expiry needs no job to take effect (audit T3-03)';

-- Closes expired grants and raises an alert for emergency grants left unreviewed (called by the daily upkeep and the worker)
CREATE OR REPLACE FUNCTION sec.break_glass_upkeep() RETURNS jsonb LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE closed int; alerted int; hrs int := coalesce((SELECT value::int FROM sys.setting WHERE key = 'security.break_glass_review_hours'), 24);
BEGIN
  WITH c AS (UPDATE sec.break_glass_log SET ended_at = expires_at, closed_reason = 'EXPIRED'
              WHERE ended_at IS NULL AND expires_at <= now() RETURNING id, actor_id, incident_ref)
  , e AS (INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
          SELECT 'security.break_glass_expired', 'break_glass', id, jsonb_build_object('actor_id', actor_id, 'incident_ref', incident_ref) FROM c
          RETURNING 1)
  SELECT count(*) INTO closed FROM e;
  WITH u AS (UPDATE sec.break_glass_log SET review_alerted_at = now()
              WHERE ended_at IS NOT NULL AND reviewed_by IS NULL AND review_alerted_at IS NULL
                AND ended_at < now() - make_interval(hours => hrs)
              RETURNING id, actor_id, incident_ref, emergency)
  , e AS (INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
          SELECT 'security.break_glass_unreviewed', 'break_glass', id,
                 jsonb_build_object('actor_id', actor_id, 'incident_ref', incident_ref, 'emergency', emergency) FROM u
          RETURNING 1)
  SELECT count(*) INTO alerted FROM e;
  RETURN jsonb_build_object('expired_closed', closed, 'unreviewed_alerts', alerted);
END $$;

-- =====================================================================
-- C  T3-10, T3-11: tracking positions
-- =====================================================================
-- One source for the retention: the lifecycle matrix (the old setting is removed)
UPDATE gov.data_inventory SET retention_days = 7, erasure_method = 'DROP_PARTITION',
       purpose = 'Positions of vehicles while tracked; daily partitions dropped after the retention, violation evidence keeps its own copy'
 WHERE dataset = 'ops.geo_event';
DELETE FROM sys.setting WHERE key = 'retention.geo_event_days';

CREATE OR REPLACE FUNCTION sys.ensure_daily_partitions(p_parent text, p_days_ahead int DEFAULT 7, p_days_back int DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE d date; part text; sch text := split_part(p_parent, '.', 1); tbl text := split_part(p_parent, '.', 2);
BEGIN
  FOR d IN SELECT generate_series(current_date - p_days_back, current_date + p_days_ahead, interval '1 day')::date LOOP
    part := format('%I.%I', sch, tbl || '_' || to_char(d, 'YYYYMMDD'));
    IF to_regclass(part) IS NULL THEN
      EXECUTE format('CREATE TABLE %s PARTITION OF %s FOR VALUES FROM (%L) TO (%L)', part, p_parent, d, d + 1);
    END IF;
  END LOOP;
  part := format('%I.%I', sch, tbl || '_default');
  IF to_regclass(part) IS NULL THEN
    EXECUTE format('CREATE TABLE %s PARTITION OF %s DEFAULT', part, p_parent);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION sys.drop_daily_partitions_older_than(p_parent text, p_keep_days int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE r record; n int := 0; cutoff date := current_date - p_keep_days;
BEGIN
  FOR r IN SELECT c.oid::regclass::text AS part, pg_get_expr(c.relpartbound, c.oid) AS bound
             FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = p_parent::regclass LOOP
    IF r.bound LIKE 'FOR VALUES FROM%' AND substring(r.bound from 'TO \(''([0-9-]+)')::date <= cutoff THEN
      EXECUTE format('DROP TABLE %s', r.part);
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;
COMMENT ON FUNCTION sys.drop_daily_partitions_older_than IS 'Drops whole days past the retention, so the kept window matches the stated retention to the day (audit T3-10)';

-- Re-partition by day: positions inside the retention move to the new days, older ones are dropped with their month
DO $$
DECLARE r record; keep int := 7; moved bigint := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
              WHERE i.inhparent = 'ops.geo_event'::regclass AND c.relname ~ '^geo_event_[0-9]{6}$') THEN
    CREATE TEMP TABLE geo_keep ON COMMIT DROP AS SELECT * FROM ops.geo_event WHERE ts >= current_date - keep;
    FOR r IN SELECT c.oid::regclass::text AS part FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
              WHERE i.inhparent = 'ops.geo_event'::regclass LOOP
      EXECUTE format('DROP TABLE %s', r.part);
    END LOOP;
    PERFORM sys.ensure_daily_partitions('ops.geo_event', 7, keep);
    INSERT INTO ops.geo_event OVERRIDING SYSTEM VALUE SELECT * FROM geo_keep;
    GET DIAGNOSTICS moved = ROW_COUNT;
    RAISE NOTICE 'geo_event re-partitioned by day; % positions kept', moved;
  END IF;
END $$;

-- Evidence fields of a position
ALTER TABLE ops.geo_event
  ADD COLUMN IF NOT EXISTS event_id uuid,
  ADD COLUMN IF NOT EXISTS seq bigint,
  ADD COLUMN IF NOT EXISTS device_ts timestamptz,
  ADD COLUMN IF NOT EXISTS received_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS provider text,
  ADD COLUMN IF NOT EXISTS is_mock boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS trust text NOT NULL DEFAULT 'HIGH',
  ADD COLUMN IF NOT EXISTS trust_flags text[] NOT NULL DEFAULT '{}';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.geo_event'::regclass AND conname = 'geo_event_trust_check') THEN
    ALTER TABLE ops.geo_event ADD CONSTRAINT geo_event_trust_check CHECK (trust IN ('HIGH','LOW','REJECTED'));
    ALTER TABLE ops.geo_event ADD CONSTRAINT geo_event_provider_check CHECK (provider IS NULL OR provider IN ('GPS','NETWORK','FUSED','DEVICE'));
    ALTER TABLE ops.geo_event ADD CONSTRAINT geo_event_seq_check CHECK (seq IS NULL OR seq >= 0);
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS geo_event_device_event_uq ON ops.geo_event (event_id, ts);
CREATE INDEX IF NOT EXISTS geo_event_event_idx ON ops.geo_event (event_id) WHERE event_id IS NOT NULL;
COMMENT ON COLUMN ops.geo_event.event_id IS 'External: id the device gives the position; a resent position is dropped as a duplicate (audit T3-11)';
COMMENT ON COLUMN ops.geo_event.trust IS 'HIGH, LOW (late, out of order, inaccurate, network-only or implausible speed) or REJECTED (mock location, far in the future)';

INSERT INTO sys.setting (key, value, description) VALUES
  ('tracking.max_accuracy_m', '50', 'A position less accurate than this many metres is graded LOW'),
  ('tracking.reject_accuracy_m', '500', 'A position less accurate than this many metres is REJECTED'),
  ('tracking.max_speed_kmh', '200', 'A jump between two positions faster than this is graded LOW'),
  ('tracking.late_minutes', '10', 'A position received this many minutes after the device took it is graded LOW')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION ops.tg_geo_event_trust() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  prev record; flags text[] := '{}'; km float8; hrs float8;
  acc_low real := coalesce((SELECT value::real FROM sys.setting WHERE key = 'tracking.max_accuracy_m'), 50);
  acc_bad real := coalesce((SELECT value::real FROM sys.setting WHERE key = 'tracking.reject_accuracy_m'), 500);
  vmax float8 := coalesce((SELECT value::float8 FROM sys.setting WHERE key = 'tracking.max_speed_kmh'), 200);
  late int := coalesce((SELECT value::int FROM sys.setting WHERE key = 'tracking.late_minutes'), 10);
BEGIN
  NEW.received_at := now();
  -- a position the device resends (same event id) is dropped quietly: the insert returns no row
  IF NEW.event_id IS NOT NULL AND EXISTS (SELECT 1 FROM ops.geo_event g WHERE g.event_id = NEW.event_id AND g.ts > NEW.ts - interval '8 days'
                                            AND g.ts < NEW.ts + interval '8 days') THEN
    RETURN NULL;
  END IF;
  IF NEW.is_mock THEN flags := array_append(flags, 'MOCK_LOCATION'); END IF;
  IF NEW.device_ts IS NOT NULL AND NEW.device_ts > NEW.received_at + interval '2 minutes' THEN flags := array_append(flags, 'FUTURE_TIME'); END IF;
  IF NEW.accuracy_m IS NOT NULL AND NEW.accuracy_m > acc_bad THEN flags := array_append(flags, 'NO_FIX'); END IF;
  IF NEW.accuracy_m IS NULL OR NEW.accuracy_m > acc_low THEN flags := array_append(flags, 'INACCURATE'); END IF;
  IF NEW.provider = 'NETWORK' THEN flags := array_append(flags, 'NETWORK_ONLY'); END IF;
  IF NEW.device_ts IS NOT NULL AND NEW.device_ts < NEW.received_at - make_interval(mins => late) THEN flags := array_append(flags, 'LATE'); END IF;
  IF NEW.vehicle_id IS NOT NULL THEN
    SELECT g.ts, g.lat, g.lng, g.seq INTO prev FROM ops.geo_event g
     WHERE g.vehicle_id = NEW.vehicle_id AND g.ts <= NEW.ts AND g.ts > NEW.ts - interval '1 day' AND g.trust <> 'REJECTED'
     ORDER BY g.ts DESC LIMIT 1;
    IF FOUND THEN
      IF NEW.seq IS NOT NULL AND prev.seq IS NOT NULL AND NEW.seq <= prev.seq THEN flags := array_append(flags, 'OUT_OF_ORDER'); END IF;
      km := 2 * 6371 * asin(sqrt(power(sin(radians(NEW.lat - prev.lat) / 2), 2)
                                 + cos(radians(prev.lat)) * cos(radians(NEW.lat)) * power(sin(radians(NEW.lng - prev.lng) / 2), 2)));
      hrs := greatest(extract(epoch FROM NEW.ts - prev.ts) / 3600.0, 1.0 / 3600);
      IF km > 0.2 AND km / hrs > vmax THEN flags := array_append(flags, 'IMPOSSIBLE_SPEED'); END IF;
    END IF;
  END IF;
  NEW.trust_flags := flags;
  NEW.trust := CASE WHEN flags && ARRAY['MOCK_LOCATION','FUTURE_TIME','NO_FIX'] THEN 'REJECTED'
                    WHEN cardinality(flags) > 0 THEN 'LOW' ELSE 'HIGH' END;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS geo_event_trust ON ops.geo_event;
CREATE TRIGGER geo_event_trust BEFORE INSERT ON ops.geo_event FOR EACH ROW EXECUTE FUNCTION ops.tg_geo_event_trust();

-- A violation carries the trust of its evidence; a low-trust one counts only after a person reviewed it
ALTER TABLE ops.route_violation ADD COLUMN IF NOT EXISTS evidence_trust text NOT NULL DEFAULT 'HIGH';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.route_violation'::regclass AND conname = 'route_violation_evidence_trust_check') THEN
    ALTER TABLE ops.route_violation ADD CONSTRAINT route_violation_evidence_trust_check CHECK (evidence_trust IN ('HIGH','LOW'));
  END IF;
END $$;
CREATE OR REPLACE FUNCTION ops.tg_violation_needs_trust() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v record;
BEGIN
  IF TG_TABLE_NAME = 'route_violation' THEN
    IF NEW.status IN ('CONFIRMED','REPORTED') AND NEW.evidence_trust = 'LOW' AND NEW.reviewed_by IS NULL THEN
      RAISE EXCEPTION 'EVIDENCE_LOW_TRUST: a violation built on low-trust positions needs a person''s review first' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT evidence_trust, reviewed_by INTO v FROM ops.route_violation WHERE id = NEW.violation_id;
    IF v.evidence_trust = 'LOW' AND v.reviewed_by IS NULL THEN
      RAISE EXCEPTION 'EVIDENCE_LOW_TRUST: a violation built on low-trust positions needs a person''s review first' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a_violation_needs_trust ON ops.route_violation;
CREATE TRIGGER a_violation_needs_trust BEFORE INSERT OR UPDATE OF status, evidence_trust, reviewed_by ON ops.route_violation
  FOR EACH ROW EXECUTE FUNCTION ops.tg_violation_needs_trust();
DROP TRIGGER IF EXISTS a_violation_needs_trust ON ops.violation_report;
CREATE TRIGGER a_violation_needs_trust BEFORE INSERT ON ops.violation_report
  FOR EACH ROW EXECUTE FUNCTION ops.tg_violation_needs_trust();

-- =====================================================================
-- D  T3-14: a regulatory requirement changes with two people and a measured impact
-- =====================================================================
CREATE TABLE IF NOT EXISTS sys.requirement_change (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid            uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  code           text NOT NULL REFERENCES sys.compliance_requirement(code),
  from_level     text NOT NULL,
  to_level       text NOT NULL CHECK (to_level IN ('OFF','OPTIONAL','REQUIRED')),
  required_from  date,
  reason         text NOT NULL CHECK (length(btrim(reason)) >= 10),
  impact         jsonb NOT NULL,
  status         text NOT NULL DEFAULT 'PROPOSED' CHECK (status IN ('PROPOSED','APPLIED','REJECTED','CANCELLED')),
  proposed_by    bigint NOT NULL REFERENCES iam.app_user(id),
  proposed_at    timestamptz NOT NULL DEFAULT now(),
  decided_by     bigint REFERENCES iam.app_user(id),
  decided_at     timestamptz,
  decision_note  text,
  CHECK (decided_by IS NULL OR decided_by <> proposed_by),
  CHECK ((status = 'PROPOSED') = (decided_at IS NULL))
);
CREATE INDEX IF NOT EXISTS requirement_change_code_fkx ON sys.requirement_change (code);
CREATE INDEX IF NOT EXISTS requirement_change_proposed_by_fkx ON sys.requirement_change (proposed_by);
CREATE INDEX IF NOT EXISTS requirement_change_decided_by_fkx ON sys.requirement_change (decided_by);
CREATE UNIQUE INDEX IF NOT EXISTS requirement_change_one_open ON sys.requirement_change (code) WHERE status = 'PROPOSED';
COMMENT ON TABLE sys.requirement_change IS 'Every change of a regulatory requirement: proposed with its measured impact, decided by a second person (audit T3-14)';
SELECT sys.rls_catalog('sys.requirement_change');
GRANT SELECT ON sys.requirement_change TO masslak_app, masslak_readonly, masslak_auditor;
DROP TRIGGER IF EXISTS forbid_delete ON sys.requirement_change;
CREATE TRIGGER forbid_delete BEFORE DELETE ON sys.requirement_change FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

-- Who would fall short if the requirement were enforced on a date
CREATE OR REPLACE FUNCTION sys.requirement_impact(p_code text, p_level text, p_on date DEFAULT current_date) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r sys.compliance_requirement; total bigint; unmet bigint;
BEGIN
  SELECT * INTO r FROM sys.compliance_requirement WHERE code = p_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'REQUIREMENT_UNKNOWN: %', p_code USING ERRCODE = 'P0001';
  END IF;
  IF p_level <> 'REQUIRED' THEN
    RETURN jsonb_build_object('blocks', 0, 'note', 'a requirement that is not REQUIRED blocks nobody');
  END IF;
  IF r.domain = 'LICENSE' AND r.subject_type IN ('VEHICLE','DRIVER','COMPANY') THEN
    IF r.subject_type = 'VEHICLE' THEN
      SELECT count(*), count(*) FILTER (WHERE NOT fleet.license_valid('VEHICLE', v.id, r.license_type, p_on))
        INTO total, unmet FROM fleet.vehicle v WHERE v.status = 'ACTIVE';
    ELSIF r.subject_type = 'DRIVER' THEN
      SELECT count(DISTINCT c.party_id), count(DISTINCT c.party_id) FILTER (WHERE NOT fleet.license_valid('DRIVER', c.party_id, r.license_type, p_on))
        INTO total, unmet FROM fleet.crew_profile c WHERE c.status = 'ACTIVE';
    ELSE
      SELECT count(*), count(*) FILTER (WHERE NOT fleet.license_valid('COMPANY', c.id, r.license_type, p_on))
        INTO total, unmet FROM iam.company c;
    END IF;
    RETURN jsonb_build_object('subject_type', r.subject_type, 'license_type', r.license_type, 'on', p_on,
                              'subjects', total, 'would_be_blocked', unmet, 'applies_to', r.applies_to);
  END IF;
  RETURN jsonb_build_object('domain', r.domain, 'applies_to', r.applies_to, 'note', 'impact is reviewed by the approver for this kind of requirement');
END $$;

CREATE OR REPLACE FUNCTION sys.propose_requirement_change(p_code text, p_level text, p_required_from date, p_reason text) RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r sys.compliance_requirement; who bigint := sys.ctx_user_id(); new_id bigint;
BEGIN
  IF who IS NULL OR NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'REQUIREMENT_CHANGE_FORBIDDEN: only a platform user can propose a requirement change' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM sys.compliance_requirement WHERE code = p_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'REQUIREMENT_UNKNOWN: %', p_code USING ERRCODE = 'P0001';
  END IF;
  IF r.level = p_level AND r.required_from IS NOT DISTINCT FROM p_required_from THEN
    RAISE EXCEPTION 'REQUIREMENT_UNCHANGED: the requirement already has that level and date' USING ERRCODE = 'P0001';
  END IF;
  IF p_level = 'REQUIRED' AND p_required_from IS NOT NULL AND p_required_from < current_date THEN
    RAISE EXCEPTION 'REQUIREMENT_PAST_DATE: a requirement cannot be enforced from a past date' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO sys.requirement_change (code, from_level, to_level, required_from, reason, impact, proposed_by)
  VALUES (p_code, r.level, p_level, p_required_from, p_reason, sys.requirement_impact(p_code, p_level, coalesce(p_required_from, current_date)), who)
  RETURNING id INTO new_id;
  INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
  VALUES ('compliance.requirement_proposed', 'requirement_change', new_id, jsonb_build_object('code', p_code, 'to_level', p_level));
  RETURN new_id;
END $$;

CREATE OR REPLACE FUNCTION sys.decide_requirement_change(p_id bigint, p_approve boolean, p_note text) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c sys.requirement_change; who bigint := sys.ctx_user_id();
BEGIN
  IF who IS NULL OR NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'REQUIREMENT_CHANGE_FORBIDDEN: only a platform user can decide a requirement change' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO c FROM sys.requirement_change WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR c.status <> 'PROPOSED' THEN
    RAISE EXCEPTION 'REQUIREMENT_CHANGE_CLOSED: no open proposal with that id' USING ERRCODE = 'P0001';
  END IF;
  IF who = c.proposed_by THEN
    RAISE EXCEPTION 'REQUIREMENT_SELF_APPROVAL: a second person must decide a requirement change' USING ERRCODE = 'P0001';
  END IF;
  IF NOT p_approve THEN
    UPDATE sys.requirement_change SET status = 'REJECTED', decided_by = who, decided_at = now(), decision_note = p_note WHERE id = p_id;
    RETURN 'REJECTED';
  END IF;
  IF (SELECT level FROM sys.compliance_requirement WHERE code = c.code) <> c.from_level THEN
    RAISE EXCEPTION 'REQUIREMENT_CHANGED_SINCE: the requirement changed after this proposal; propose again' USING ERRCODE = 'P0001';
  END IF;
  PERFORM set_config('masslak.requirement_change', p_id::text, true);
  UPDATE sys.compliance_requirement SET level = c.to_level, required_from = c.required_from, updated_by = who WHERE code = c.code;
  PERFORM set_config('masslak.requirement_change', '', true);
  UPDATE sys.requirement_change SET status = 'APPLIED', decided_by = who, decided_at = now(), decision_note = p_note WHERE id = p_id;
  INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
  VALUES ('compliance.requirement_changed', 'requirement_change', p_id,
          jsonb_build_object('code', c.code, 'from_level', c.from_level, 'to_level', c.to_level, 'required_from', c.required_from));
  RETURN 'APPLIED';
END $$;
REVOKE ALL ON FUNCTION sys.propose_requirement_change(text, text, date, text), sys.decide_requirement_change(bigint, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.propose_requirement_change(text, text, date, text), sys.decide_requirement_change(bigint, boolean, text),
  sys.requirement_impact(text, text, date) TO masslak_app;

-- The level and date of a requirement move only through an approved change (migrations excepted)
CREATE OR REPLACE FUNCTION sys.tg_requirement_guarded() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE cid text := nullif(current_setting('masslak.requirement_change', true), '');
BEGIN
  IF coalesce(current_setting('masslak.migrating', true), '') = 'on' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.level IS NOT DISTINCT FROM OLD.level AND NEW.required_from IS NOT DISTINCT FROM OLD.required_from THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' AND NEW.level = 'OFF' THEN
    RETURN NEW;
  END IF;
  IF cid IS NULL OR NOT EXISTS (SELECT 1 FROM sys.requirement_change c WHERE c.id = cid::bigint AND c.code = NEW.code
                                    AND c.status = 'PROPOSED' AND c.to_level = NEW.level) THEN
    RAISE EXCEPTION 'REQUIREMENT_CHANGE_NEEDS_APPROVAL: change a requirement through sys.propose_requirement_change and a second person''s decision'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a_requirement_guarded ON sys.compliance_requirement;
CREATE TRIGGER a_requirement_guarded BEFORE INSERT OR UPDATE ON sys.compliance_requirement
  FOR EACH ROW EXECUTE FUNCTION sys.tg_requirement_guarded();

-- =====================================================================
-- E  T3-15: files are quarantined until scanned
-- =====================================================================
ALTER TABLE ref.file_object
  ADD COLUMN IF NOT EXISTS scan_status text NOT NULL DEFAULT 'PENDING',
  ADD COLUMN IF NOT EXISTS scanned_at timestamptz,
  ADD COLUMN IF NOT EXISTS scan_engine text,
  ADD COLUMN IF NOT EXISTS scan_detail text,
  ADD COLUMN IF NOT EXISTS scan_attempts int NOT NULL DEFAULT 0;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ref.file_object'::regclass AND conname = 'file_object_scan_status_check') THEN
    ALTER TABLE ref.file_object ADD CONSTRAINT file_object_scan_status_check
      CHECK (scan_status IN ('PENDING','SCANNING','CLEAN','REJECTED','QUARANTINED'));
    ALTER TABLE ref.file_object ADD CONSTRAINT file_object_scan_done_check
      CHECK ((scan_status IN ('CLEAN','REJECTED','QUARANTINED')) = (scanned_at IS NOT NULL AND scan_engine IS NOT NULL));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS file_object_scan_queue_idx ON ref.file_object (created_at) WHERE scan_status IN ('PENDING','SCANNING');
COMMENT ON COLUMN ref.file_object.scan_status IS 'Quarantine: PENDING until scanned; only CLEAN files are downloaded, signed or shared (audit T3-15)';

-- A file enters as PENDING; only the platform's scanner moves it, and a verdict is final
CREATE OR REPLACE FUNCTION ref.tg_file_scan_rules() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.scan_status <> 'PENDING' AND NOT sys.ctx_is_platform() AND coalesce(current_setting('masslak.migrating', true), '') <> 'on' THEN
      RAISE EXCEPTION 'FILE_SCAN_STATUS: a new file waits for the scanner' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.scan_status IS DISTINCT FROM OLD.scan_status THEN
    IF NOT sys.ctx_is_platform() THEN
      RAISE EXCEPTION 'FILE_SCAN_STATUS: only the platform''s scanner sets a file''s scan result' USING ERRCODE = 'P0001';
    END IF;
    IF OLD.scan_status IN ('REJECTED','QUARANTINED') THEN
      RAISE EXCEPTION 'FILE_SCAN_FINAL: a rejected or quarantined file stays so' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF NEW.storage_key <> OLD.storage_key OR NEW.sha256 <> OLD.sha256 OR NEW.size_bytes <> OLD.size_bytes THEN
    RAISE EXCEPTION 'FILE_CONTENT_FIXED: a stored file''s content never changes; upload a new file' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS file_scan_rules ON ref.file_object;
CREATE TRIGGER file_scan_rules BEFORE INSERT OR UPDATE ON ref.file_object FOR EACH ROW EXECUTE FUNCTION ref.tg_file_scan_rules();

-- Only a clean file is signed
CREATE OR REPLACE FUNCTION sec.tg_signature_file_clean() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.file_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ref.file_object f WHERE f.id = NEW.file_id AND f.scan_status = 'CLEAN') THEN
    RAISE EXCEPTION 'FILE_NOT_CLEAN: only a scanned, clean file can be signed' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS signature_file_clean ON sec.document_signature;
CREATE TRIGGER signature_file_clean BEFORE INSERT ON sec.document_signature FOR EACH ROW EXECUTE FUNCTION sec.tg_signature_file_clean();

-- A document cannot be approved while its file is not clean
CREATE OR REPLACE FUNCTION iam.tg_document_file_clean() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.status = 'APPROVED' AND OLD.status IS DISTINCT FROM 'APPROVED' AND NEW.file_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM ref.file_object f WHERE f.id = NEW.file_id AND f.scan_status = 'CLEAN') THEN
    RAISE EXCEPTION 'FILE_NOT_CLEAN: a document is approved only once its file is scanned clean' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS z_document_file_clean ON iam.document;
CREATE TRIGGER z_document_file_clean BEFORE UPDATE OF status ON iam.document FOR EACH ROW EXECUTE FUNCTION iam.tg_document_file_clean();

-- =====================================================================
-- F  T3-19: access reviews and sensitive reads
-- =====================================================================
ALTER TABLE sec.access_review ADD COLUMN IF NOT EXISTS due_on date, ADD COLUMN IF NOT EXISTS scope text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'sec.access_review'::regclass AND conname = 'access_review_not_self') THEN
    ALTER TABLE sec.access_review ADD CONSTRAINT access_review_not_self CHECK (reviewer_id <> user_id);
  END IF;
END $$;

ALTER TABLE audit.data_access_log ADD COLUMN IF NOT EXISTS service_name text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'audit.data_access_log'::regclass AND conname = 'data_access_log_actor') THEN
    ALTER TABLE audit.data_access_log ADD CONSTRAINT data_access_log_actor
      CHECK (num_nonnulls(user_id, api_client_id, service_name) >= 1 AND request_id IS NOT NULL);
  END IF;
END $$;
COMMENT ON COLUMN audit.data_access_log.service_name IS 'A background service reading without a person (named, so every read has an actor; audit T3-19)';

-- =====================================================================
-- G  T3-02, T3-18: government endpoints and city time zones
-- =====================================================================
UPDATE sec.authority_profile SET endpoint = NULL WHERE endpoint IS NOT NULL AND endpoint !~ '^(https|sftp|amqps)://';
UPDATE sec.gov_adapter_config SET endpoint = 'https://adapter.invalid/' || id WHERE endpoint !~ '^(https|sftp|amqps)://';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'authority_profile_endpoint_encrypted') THEN
    ALTER TABLE sec.authority_profile ADD CONSTRAINT authority_profile_endpoint_encrypted
      CHECK (endpoint IS NULL OR endpoint ~ '^(https|sftp|amqps)://');
    ALTER TABLE sec.gov_adapter_config ADD CONSTRAINT gov_adapter_config_endpoint_encrypted
      CHECK (endpoint IS NULL OR endpoint ~ '^(https|sftp|amqps)://');
  END IF;
END $$;

ALTER TABLE ref.city ALTER COLUMN timezone DROP DEFAULT;
CREATE OR REPLACE FUNCTION ref.tg_city_timezone() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.timezone IS NULL OR NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.timezone) OR NEW.timezone !~ '/' THEN
    RAISE EXCEPTION 'CITY_TIMEZONE: give the city''s IANA time zone (for example Asia/Damascus)' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS city_timezone ON ref.city;
CREATE TRIGGER city_timezone BEFORE INSERT OR UPDATE OF timezone ON ref.city FOR EACH ROW EXECUTE FUNCTION ref.tg_city_timezone();

-- =====================================================================
-- H  T3-12: the event envelope
-- =====================================================================
ALTER TABLE sys.outbox_event
  ADD COLUMN IF NOT EXISTS schema_version smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS correlation_id uuid DEFAULT sys.ctx_request_id(),
  ADD COLUMN IF NOT EXISTS aggregate_seq bigint;
COMMENT ON COLUMN sys.outbox_event.correlation_id IS 'External: the request that caused the event, for tracing across services (audit T3-12)';
COMMENT ON COLUMN sys.outbox_event.aggregate_seq IS 'Order of the event among its aggregate''s events (1, 2, ...); consumers apply an event only after the previous one (audit T3-12)';

CREATE TABLE IF NOT EXISTS sys.outbox_sequence (
  aggregate_type text NOT NULL,
  aggregate_id   bigint NOT NULL,
  last_seq       bigint NOT NULL,
  PRIMARY KEY (aggregate_type, aggregate_id)
);
COMMENT ON TABLE sys.outbox_sequence IS 'Last event number per aggregate; survives the purge of delivered events so numbers never repeat';
SELECT sys.rls_catalog('sys.outbox_sequence');
GRANT SELECT ON sys.outbox_sequence TO masslak_readonly, masslak_auditor;
INSERT INTO sys.polymorphic_reference (table_name, type_col, id_col, kind, targets, owner, reason) VALUES
  ('sys.outbox_sequence', 'aggregate_type', 'aggregate_id', 'METADATA', '{}', 'sys',
   'The event counter of an aggregate outlives the aggregate, so numbers are never reused')
ON CONFLICT (table_name, type_col) DO NOTHING;

CREATE OR REPLACE FUNCTION sys.tg_outbox_sequence() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  INSERT INTO sys.outbox_sequence AS s (aggregate_type, aggregate_id, last_seq) VALUES (NEW.aggregate_type, NEW.aggregate_id, 1)
  ON CONFLICT (aggregate_type, aggregate_id) DO UPDATE SET last_seq = s.last_seq + 1
  RETURNING last_seq INTO NEW.aggregate_seq;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a_outbox_sequence ON sys.outbox_event;
CREATE TRIGGER a_outbox_sequence BEFORE INSERT ON sys.outbox_event FOR EACH ROW EXECUTE FUNCTION sys.tg_outbox_sequence();

-- =====================================================================
-- Daily upkeep: daily position partitions, break-glass expiry and review alerts
-- =====================================================================
CREATE OR REPLACE FUNCTION sys.run_maintenance() RETURNS jsonb LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p text; done jsonb := '{}'::jsonb; keep_days int; dropped int := 0; held boolean; r fin.wallet_reconciliation;
        orphans bigint;
BEGIN
  FOR p IN SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'p' AND NOT c.relispartition LOOP
    IF p = 'ops.geo_event' THEN
      PERFORM sys.ensure_daily_partitions(p, 7, 1);
    ELSE
      PERFORM sys.ensure_monthly_partitions(p, 3, 1);
    END IF;
  END LOOP;
  SELECT retention_days INTO keep_days FROM gov.data_inventory WHERE dataset = 'ops.geo_event';
  held := EXISTS (SELECT 1 FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'DATASET' AND dataset = 'ops.geo_event');
  IF keep_days IS NOT NULL AND NOT held THEN
    dropped := sys.drop_daily_partitions_older_than('ops.geo_event', keep_days);
  END IF;
  r := fin.reconcile_wallets();
  IF NOT EXISTS (SELECT 1 FROM sys.orphan_check WHERE checked_at > now() - interval '7 days') THEN
    orphans := sys.run_orphan_check();
  END IF;
  done := jsonb_build_object('partitions_checked', true, 'geo_partitions_dropped', dropped, 'geo_retention_held', held,
                             'expired_holds_released', ops.release_expired_holds(),
                             'wallet_mismatches', r.mismatches, 'orphans', orphans, 'purged', sys.purge_expired(),
                             'break_glass', sec.break_glass_upkeep(), 'at', now());
  RETURN done;
END $$;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('sys.requirement_change', '1A', 'E03'), ('sys.outbox_sequence', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

INSERT INTO sys.json_contract (table_name, column_name, kind, version, note) VALUES
  ('sys.requirement_change', 'impact', 'SNAPSHOT', 1, 'Measured impact of a proposed requirement change, frozen when proposed')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();

INSERT INTO sys.schema_migration (version, description)
SELECT '1.30.0', 'Design audit T3: typed signature references, checked business references, break-glass expiry, daily position partitions and trust, requirement maker-checker, file quarantine, access review and envelope fields'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.30.0');

SELECT sys.refresh_table_class();

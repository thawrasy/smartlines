-- 1169: government bodies (owner's note N47) and the vehicle movement code (N48).
--
-- Builds on the study's tables, which had no screens yet:
--   * sec.authority_profile: the bodies. New kinds (interior, finance, transport authority, transport ministry, other),
--     names in Arabic and English. Members (sec.authority_member, 1117) sign in at the inspector portal; what a body may
--     see is its approved scopes (sec.authority_scope), two new categories (TAX, REGULATORY) and a second person approves
--     each scope before it counts (sec.authority_may).
--   * fleet.vehicle_qr_tag: the signed code on the vehicle's placard, printed once per vehicle; a serial counts the
--     placards, and a lost or copied one is revoked with its reason.
--   * fleet.field_check_log: every roadside scan and check: the movement found, the warnings shown, the sample
--     the server drew at random and the outcome of each person checked. It is never changed once closed and never deleted.
--     The body it was made for is kept beside it in sec.field_check_body (sec already depends on fleet).

-- ------------------------------------------------------------------ bodies
ALTER TABLE sec.authority_profile
  ADD COLUMN IF NOT EXISTS name_ar text CHECK (name_ar IS NULL OR length(name_ar) BETWEEN 2 AND 200),
  ADD COLUMN IF NOT EXISTS name_en text CHECK (name_en IS NULL OR length(name_en) BETWEEN 2 AND 200),
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
UPDATE sec.authority_profile SET name_en = left(name, 200) WHERE name_en IS NULL AND length(name) >= 2;
ALTER TABLE sec.authority_profile DROP CONSTRAINT IF EXISTS authority_profile_authority_type_check;
ALTER TABLE sec.authority_profile ADD CONSTRAINT authority_profile_authority_type_check CHECK (authority_type IN (
  'TRAFFIC','PASSPORT','BORDER','PUBLIC_SECURITY','CUSTOMS','REGULATOR','POLICE',
  'INTERIOR','FINANCE','TRANSPORT_AUTHORITY','TRANSPORT_MINISTRY','OTHER'));
COMMENT ON COLUMN sec.authority_profile.authority_type IS
  'The kind of body: interior and internal security, public security, traffic, the transport authority, finance (tax), the transport ministry, customs, borders... (100, 1169)';

ALTER TABLE sec.authority_scope DROP CONSTRAINT IF EXISTS authority_scope_data_category_check;
ALTER TABLE sec.authority_scope ADD CONSTRAINT authority_scope_data_category_check CHECK (data_category IN (
  'MANIFEST_PERSON','MANIFEST_VEHICLE','MANIFEST_CARGO','BOOKING','TRACKING','IDENTITY','PAYMENT','TAX','REGULATORY'));
COMMENT ON COLUMN sec.authority_scope.data_category IS
  'What the body may see: movements (MANIFEST_VEHICLE, TRACKING), passengers'' names (MANIFEST_PERSON), ID numbers (IDENTITY), goods and parcels (MANIFEST_CARGO), bookings, payments, tax (TAX) and the regulator''s indicators (REGULATORY) (1169)';

-- a scope counts once a second person approved it, while it is in force
CREATE OR REPLACE FUNCTION sec.authority_may(p_authority bigint, p_category text) RETURNS boolean
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM sec.authority_scope s JOIN sec.authority_profile a ON a.id = s.authority_id
                  WHERE s.authority_id = p_authority AND s.data_category = p_category AND a.active
                    AND s.approved_by IS NOT NULL AND s.valid @> current_date)
$$;
COMMENT ON FUNCTION sec.authority_may(bigint, text) IS 'Whether an active body holds an approved scope in force for a category of data (1169)';
GRANT EXECUTE ON FUNCTION sec.authority_may(bigint, text) TO masslak_app;

-- ------------------------------------------------------------------ the placard's code
ALTER TABLE fleet.vehicle_qr_tag
  ADD COLUMN IF NOT EXISTS serial int NOT NULL DEFAULT 1 CHECK (serial >= 1),
  ADD COLUMN IF NOT EXISTS issued_by bigint REFERENCES iam.app_user(id),
  ADD COLUMN IF NOT EXISTS revoked_by bigint REFERENCES iam.app_user(id),
  ADD COLUMN IF NOT EXISTS revoke_reason text CHECK (revoke_reason IS NULL OR length(revoke_reason) BETWEEN 3 AND 300);
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_qr_serial ON fleet.vehicle_qr_tag (vehicle_id, serial);
CREATE INDEX IF NOT EXISTS vehicle_qr_tag_issued_by_fkx ON fleet.vehicle_qr_tag (issued_by);
CREATE INDEX IF NOT EXISTS vehicle_qr_tag_revoked_by_fkx ON fleet.vehicle_qr_tag (revoked_by);
COMMENT ON COLUMN fleet.vehicle_qr_tag.serial IS 'The placard''s number for this vehicle: a new placard after a revocation takes the next one (1169)';

CREATE OR REPLACE FUNCTION fleet.tg_vehicle_qr_tag() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'QR_TAG_KEPT: a placard is revoked, never deleted' USING ERRCODE = 'P0001';
  END IF;
  IF (NEW.vehicle_id, NEW.token_hash, NEW.serial, NEW.issued_at, NEW.issued_by)
     IS DISTINCT FROM (OLD.vehicle_id, OLD.token_hash, OLD.serial, OLD.issued_at, OLD.issued_by) THEN
    RAISE EXCEPTION 'QR_TAG_FIXED: a placard''s code never changes; revoke it and print another' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'QR_TAG_REVOKED: a revoked placard stays revoked' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.revoked_at IS NOT NULL AND NEW.revoke_reason IS NULL THEN
    RAISE EXCEPTION 'QR_TAG_REASON: a revocation gives its reason' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS vehicle_qr_tag_rules ON fleet.vehicle_qr_tag;
CREATE TRIGGER vehicle_qr_tag_rules BEFORE UPDATE OR DELETE ON fleet.vehicle_qr_tag
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_vehicle_qr_tag();

-- ------------------------------------------------------------------ roadside checks
ALTER TABLE fleet.field_check_log
  ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS tag_id bigint REFERENCES fleet.vehicle_qr_tag(id),
  ADD COLUMN IF NOT EXISTS movement_kind text CHECK (movement_kind IS NULL OR movement_kind ~ '^[A-Z_]{2,30}$'),
  ADD COLUMN IF NOT EXISTS movement_ref text CHECK (movement_ref IS NULL OR length(movement_ref) <= 80),
  ADD COLUMN IF NOT EXISTS trip_id bigint REFERENCES ops.trip(id),
  ADD COLUMN IF NOT EXISTS warnings jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(warnings) = 'array'),
  ADD COLUMN IF NOT EXISTS sample_mode text NOT NULL DEFAULT 'NONE' CHECK (sample_mode IN ('NONE','SAMPLE','FULL')),
  ADD COLUMN IF NOT EXISTS sample jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(sample) = 'array'),
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'CLOSED' CHECK (status IN ('OPEN','CLOSED')),
  ADD COLUMN IF NOT EXISTS outcome text CHECK (outcome IS NULL OR outcome IN ('CLEAR','ISSUES')),
  ADD COLUMN IF NOT EXISTS note text CHECK (note IS NULL OR length(note) <= 1000),
  ADD COLUMN IF NOT EXISTS closed_at timestamptz;
ALTER TABLE fleet.field_check_log DROP CONSTRAINT IF EXISTS field_check_log_result_check;
ALTER TABLE fleet.field_check_log ADD CONSTRAINT field_check_log_result_check
  CHECK (result IN ('VALID','EXPIRED','NOT_FOUND','MISMATCH','REVOKED'));
-- the queries recorded before 1169 were single lookups: closed when made. From now on a scan opens a check, and the
-- officer closes it with its outcome.
UPDATE fleet.field_check_log SET closed_at = created_at WHERE closed_at IS NULL AND status = 'CLOSED';
ALTER TABLE fleet.field_check_log ALTER COLUMN status SET DEFAULT 'OPEN';
ALTER TABLE fleet.field_check_log DROP CONSTRAINT IF EXISTS field_check_log_closed;
ALTER TABLE fleet.field_check_log ADD CONSTRAINT field_check_log_closed CHECK ((status = 'CLOSED') = (closed_at IS NOT NULL));
CREATE UNIQUE INDEX IF NOT EXISTS field_check_log_uid ON fleet.field_check_log (uid);
CREATE INDEX IF NOT EXISTS field_check_log_tag_id_fkx ON fleet.field_check_log (tag_id);
CREATE INDEX IF NOT EXISTS field_check_log_trip_id_fkx ON fleet.field_check_log (trip_id);
CREATE INDEX IF NOT EXISTS field_check_log_vehicle_time ON fleet.field_check_log (vehicle_id, created_at DESC);
COMMENT ON COLUMN fleet.field_check_log.sample IS
  'The people the server drew at random (or everyone, FULL): [{ticket, seat, outcome: CHECKED|ISSUE|ABSENT|null, note}] (1169)';
COMMENT ON COLUMN fleet.field_check_log.warnings IS 'The warnings the scan showed: overload, blocked vehicle, expired document or licence, no movement... (1169)';

INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('fleet.field_check_log', 'warnings', 'SHAPE', 1, '{"type": "array", "items": {"type": "string"}}'::jsonb,
   'the warnings a roadside scan showed, as codes (1169)'),
  ('fleet.field_check_log', 'sample', 'SHAPE', 1,
   '{"type": "array", "items": {"type": "object", "required": ["ticket"]}}'::jsonb,
   'the people drawn for a check, each with its seat and outcome (1169)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();

-- a check is written once; while open, only its sample and outcome are filled in, and closing freezes it
CREATE OR REPLACE FUNCTION fleet.tg_field_check_log() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'FIELD_CHECK_KEPT: a roadside check is never deleted' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.status = 'CLOSED' THEN
    RAISE EXCEPTION 'FIELD_CHECK_CLOSED: a closed roadside check is never changed' USING ERRCODE = 'P0001';
  END IF;
  IF (NEW.uid, NEW.inspector_user_id, NEW.vehicle_id, NEW.method, NEW.result, NEW.lat, NEW.lng, NEW.created_at,
      NEW.tag_id, NEW.movement_kind, NEW.movement_ref, NEW.trip_id, NEW.warnings)
     IS DISTINCT FROM (OLD.uid, OLD.inspector_user_id, OLD.vehicle_id, OLD.method, OLD.result, OLD.lat, OLD.lng, OLD.created_at,
      OLD.tag_id, OLD.movement_kind, OLD.movement_ref, OLD.trip_id, OLD.warnings) THEN
    RAISE EXCEPTION 'FIELD_CHECK_FIXED: what the scan found is never changed' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.sample_mode <> 'NONE' AND (NEW.sample_mode <> OLD.sample_mode
     OR jsonb_array_length(NEW.sample) <> jsonb_array_length(OLD.sample)
     OR (SELECT array_agg(e ->> 'ticket' ORDER BY e ->> 'ticket') FROM jsonb_array_elements(NEW.sample) e)
        IS DISTINCT FROM (SELECT array_agg(e ->> 'ticket' ORDER BY e ->> 'ticket') FROM jsonb_array_elements(OLD.sample) e)) THEN
    RAISE EXCEPTION 'FIELD_CHECK_SAMPLE_FIXED: the people drawn for a check are not changed' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'CLOSED' THEN
    IF NEW.outcome IS NULL THEN
      RAISE EXCEPTION 'FIELD_CHECK_OUTCOME: a check closes with its outcome' USING ERRCODE = 'P0001';
    END IF;
    NEW.closed_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS field_check_log_rules ON fleet.field_check_log;
CREATE TRIGGER field_check_log_rules BEFORE UPDATE OR DELETE ON fleet.field_check_log
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_field_check_log();

-- the body a check was made for: kept in sec, which already depends on fleet, so the schemas keep one direction
CREATE TABLE IF NOT EXISTS sec.field_check_body (
  check_id      bigint PRIMARY KEY REFERENCES fleet.field_check_log(id),
  authority_id  bigint NOT NULL REFERENCES sec.authority_profile(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS field_check_body_authority_id_fkx ON sec.field_check_body (authority_id);
COMMENT ON TABLE sec.field_check_body IS 'The government body each roadside check was made for (1169, N47/N48); written with the check, never changed';
CREATE OR REPLACE FUNCTION sec.tg_field_check_body_kept() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'FIELD_CHECK_FIXED: the body of a roadside check is never changed' USING ERRCODE = 'P0001';
END $$;
DROP TRIGGER IF EXISTS field_check_body_kept ON sec.field_check_body;
CREATE TRIGGER field_check_body_kept BEFORE UPDATE OR DELETE ON sec.field_check_body
  FOR EACH ROW EXECUTE FUNCTION sec.tg_field_check_body_kept();
SELECT sys.rls('sec.field_check_body', 'sys.ctx_is_platform()', 'sys.ctx_is_platform()');

-- ------------------------------------------------------------------ settings, rights, roles
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('roadside.sample_size', '3'::jsonb, 'PLATFORM', 'How many passengers the server draws at random for a sample check at the roadside (1169, N48)'),
  ('roadside.window_minutes', '180'::jsonb, 'PLATFORM',
   'A published trip of the vehicle that departs within this many minutes before or after the scan counts as its movement (1169, N48)')
ON CONFLICT (key) DO NOTHING;

INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('roadside.check', 'gov', 'PLATFORM', 'Scan a vehicle''s code at the roadside, draw a sample and record the check (inspector portal)', false),
  ('authority.manage', 'gov', 'PLATFORM', 'Register government bodies, their members and the data they may see', true),
  ('vehicle.placard', 'fleet', 'COMPANY', 'Print and revoke the movement code placards of the company''s vehicles', false)
ON CONFLICT (code) DO NOTHING;

INSERT INTO iam.role (code, name, scope, is_system, company_kind, description)
SELECT 'ROADSIDE_INSPECTOR', 'Roadside inspector', 'PLATFORM', true, NULL,
       'A member of a government body: scans vehicles'' codes at the roadside and records checks within the body''s scopes'
 WHERE NOT EXISTS (SELECT 1 FROM iam.role r WHERE r.code = 'ROADSIDE_INSPECTOR' AND r.company_id IS NULL);

INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, x.p FROM iam.role r JOIN (VALUES
  ('ROADSIDE_INSPECTOR', 'roadside.check'),
  ('PLATFORM_ADMIN', 'authority.manage'), ('PLATFORM_ADMIN', 'roadside.check'),
  ('PLATFORM_SECURITY', 'authority.manage'), ('PLATFORM_SECURITY', 'roadside.check'),
  ('CARRIER_ADMIN', 'vehicle.placard'), ('CARRIER_OPERATIONS', 'vehicle.placard')
) AS x(code, p) ON x.code = r.code AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ access
GRANT SELECT, INSERT ON fleet.vehicle_qr_tag TO masslak_app;
GRANT UPDATE (revoked_at, revoked_by, revoke_reason) ON fleet.vehicle_qr_tag TO masslak_app;
GRANT SELECT, INSERT ON fleet.field_check_log TO masslak_app;
GRANT UPDATE (sample_mode, sample, status, outcome, note, closed_at) ON fleet.field_check_log TO masslak_app;
GRANT SELECT, INSERT, UPDATE ON sec.authority_profile, sec.authority_scope TO masslak_app;
-- members are added by INSERT and removed through sec.remove_authority_member (1117); the application deletes nothing
GRANT SELECT, INSERT ON sec.field_check_body TO masslak_app;
GRANT SELECT ON sec.field_check_body TO masslak_readonly, masslak_auditor;
GRANT SELECT ON fleet.vehicle_qr_tag, fleet.field_check_log TO masslak_readonly, masslak_auditor;
DROP TRIGGER IF EXISTS zz_audit_capture ON fleet.vehicle_qr_tag;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON fleet.vehicle_qr_tag FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS zz_audit_capture ON fleet.field_check_log;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON fleet.field_check_log FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- in force from the pilot: a carrier prints its placards, the bodies check from the first day
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('fleet.vehicle_qr_tag', '1A', 'E06'), ('fleet.field_check_log', '1A', 'E07'),
  ('sec.authority_profile', '1A', 'E24'), ('sec.authority_scope', '1A', 'E24'), ('sec.field_check_body', '1A', 'E24')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('fleet.vehicle_qr_tag', 'sec records', 'the movement code placards of vehicles, with who printed and revoked them (1169)'),
  ('fleet.field_check_log', 'sec records', 'roadside scans and checks by government bodies, with the sample and its outcome (1169)'),
  ('sec.field_check_body', 'sec records', 'the government body each roadside check was made for (1169)')
ON CONFLICT (table_name) DO NOTHING;

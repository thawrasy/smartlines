-- =====================================================================
-- 1154: users and roles in every portal (owner's request N1)
--   * One "Users and roles" section for the platform, carriers, agencies and station operating companies: ready roles,
--     roles a company or the platform defines from the permission catalog, users linked to a role.
--   * Nobody grants what they do not hold: a role given or defined holds only permissions of the person giving it.
--   * Per-user exceptions: a permission granted or denied beyond the role, always with an end date and a reason, active
--     only once a second person with the same right approves it.
--   * The platform's administrators manage users with the permission users.manage (not only the platform owner);
--     companies keep company.staff.
-- =====================================================================

INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('users.manage', 'iam', 'PLATFORM', 'Create platform staff, give them roles, define platform roles and request or approve per-user exceptions', true)
ON CONFLICT (code) DO NOTHING;

-- ------------------------------------------------------------------ roles: a stable reference, the kind of company, a status
ALTER TABLE iam.role ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE iam.role ADD COLUMN IF NOT EXISTS company_kind text;
ALTER TABLE iam.role ADD COLUMN IF NOT EXISTS description text;
ALTER TABLE iam.role ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE iam.role ADD COLUMN IF NOT EXISTS created_by bigint REFERENCES iam.app_user(id);
ALTER TABLE iam.role ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
CREATE UNIQUE INDEX IF NOT EXISTS role_uid_uq ON iam.role (uid);
CREATE INDEX IF NOT EXISTS role_created_by_fkx ON iam.role (created_by);
ALTER TABLE iam.role DROP CONSTRAINT IF EXISTS role_status_ck;
ALTER TABLE iam.role ADD CONSTRAINT role_status_ck CHECK (status IN ('ACTIVE', 'RETIRED'));
ALTER TABLE iam.role DROP CONSTRAINT IF EXISTS role_description_ck;
ALTER TABLE iam.role ADD CONSTRAINT role_description_ck CHECK (description IS NULL OR length(description) BETWEEN 1 AND 300);
ALTER TABLE iam.role DROP CONSTRAINT IF EXISTS role_name_ck;
ALTER TABLE iam.role ADD CONSTRAINT role_name_ck CHECK (length(name) BETWEEN 2 AND 80);

-- the company templates and company roles say which kind of company they serve
UPDATE iam.role SET company_kind = CASE
    WHEN code LIKE 'CARRIER\_%' THEN 'CARRIER' WHEN code LIKE 'AGENCY\_%' THEN 'AGENCY' WHEN code LIKE 'STATION\_%' THEN 'STATION' END
 WHERE scope = 'COMPANY' AND company_id IS NULL AND company_kind IS NULL;
UPDATE iam.role r SET company_kind = CASE c.company_type WHEN 'AGENCY' THEN 'AGENCY' WHEN 'STATION_OPERATOR' THEN 'STATION' ELSE 'CARRIER' END
  FROM iam.company c WHERE c.id = r.company_id AND r.company_kind IS NULL;
ALTER TABLE iam.role DROP CONSTRAINT IF EXISTS role_company_kind_ck;
ALTER TABLE iam.role ADD CONSTRAINT role_company_kind_ck
  CHECK ((scope = 'PLATFORM' AND company_kind IS NULL) OR (scope = 'COMPANY' AND company_kind IN ('CARRIER', 'AGENCY', 'STATION')));
COMMENT ON COLUMN iam.role.company_kind IS 'For company roles: the kind of company the role serves (carrier, agency, station operating company) (1154, N1)';
COMMENT ON COLUMN iam.role.status IS 'A retired role is no longer given; people who hold it keep it until moved (1154, N1)';

-- ------------------------------------------------------------------ ready roles (N1: operations, finance, security, support, compliance, read-only)
INSERT INTO iam.role (code, name, scope, is_system, company_kind, description)
SELECT x.code, x.name, x.scope, true, x.kind, x.descr
  FROM (VALUES
    ('PLATFORM_OPERATIONS', 'Operations', 'PLATFORM', NULL, 'Trips, schedules, stations and lines across the network'),
    ('PLATFORM_COMPLIANCE', 'Compliance', 'PLATFORM', NULL, 'Company files, compliance reviews, violations and obligations'),
    ('PLATFORM_READONLY', 'Read only', 'PLATFORM', NULL, 'Sees platform reports and tracking; changes nothing'),
    ('PLATFORM_USERS', 'Users administrator', 'PLATFORM', NULL, 'Creates platform staff and gives roles within what they hold'),
    ('CARRIER_ADMIN', 'Carrier administrator', 'COMPANY', 'CARRIER', 'Manages the company''s users and roles'),
    ('CARRIER_SUPPORT', 'Carrier support', 'COMPANY', 'CARRIER', 'Answers passengers: finds trips and bookings, handles cases'),
    ('CARRIER_READONLY', 'Carrier read only', 'COMPANY', 'CARRIER', 'Sees the company''s reports, manifests and tracking'),
    ('AGENCY_ADMIN', 'Agency administrator', 'COMPANY', 'AGENCY', 'Manages the agency''s users and roles'),
    ('AGENCY_READONLY', 'Agency read only', 'COMPANY', 'AGENCY', 'Sees the agency''s reports'),
    ('STATION_ADMIN', 'Station administrator', 'COMPANY', 'STATION', 'Manages the station company''s users and roles'),
    ('STATION_READONLY', 'Station read only', 'COMPANY', 'STATION', 'Sees the station''s bays, counters and screens without changing them')
  ) AS x(code, name, scope, kind, descr)
 WHERE NOT EXISTS (SELECT 1 FROM iam.role r WHERE r.code = x.code AND r.company_id IS NULL);

INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, x.p FROM iam.role r JOIN (VALUES
  ('PLATFORM_ADMIN', 'users.manage'),
  ('PLATFORM_USERS', 'users.manage'), ('PLATFORM_USERS', 'audit.view'),
  ('PLATFORM_OPERATIONS', 'schedule.approve'), ('PLATFORM_OPERATIONS', 'schedule.settings'), ('PLATFORM_OPERATIONS', 'station.approve'),
  ('PLATFORM_OPERATIONS', 'stations.operate'), ('PLATFORM_OPERATIONS', 'lines.manage'), ('PLATFORM_OPERATIONS', 'tracking.all'),
  ('PLATFORM_OPERATIONS', 'trip.complete'), ('PLATFORM_OPERATIONS', 'trip.reschedule'), ('PLATFORM_OPERATIONS', 'trip.search'),
  ('PLATFORM_OPERATIONS', 'report.platform'), ('PLATFORM_OPERATIONS', 'boarding.manage'), ('PLATFORM_OPERATIONS', 'carrier_code.approve'),
  ('PLATFORM_COMPLIANCE', 'kyc.view'), ('PLATFORM_COMPLIANCE', 'kyc.review.compliance'), ('PLATFORM_COMPLIANCE', 'violation.review'),
  ('PLATFORM_COMPLIANCE', 'obligation.manage'), ('PLATFORM_COMPLIANCE', 'policy.matrix'), ('PLATFORM_COMPLIANCE', 'license.approve_change'),
  ('PLATFORM_COMPLIANCE', 'report.platform'), ('PLATFORM_COMPLIANCE', 'audit.view'),
  ('PLATFORM_READONLY', 'report.platform'), ('PLATFORM_READONLY', 'tracking.all'), ('PLATFORM_READONLY', 'kyc.view'),
  ('CARRIER_ADMIN', 'company.staff'), ('CARRIER_ADMIN', 'report.company'), ('CARRIER_ADMIN', 'company.login_log'),
  ('CARRIER_SUPPORT', 'trip.search'), ('CARRIER_SUPPORT', 'case.handle'), ('CARRIER_SUPPORT', 'manifest.view'),
  ('CARRIER_READONLY', 'report.company'), ('CARRIER_READONLY', 'manifest.view'), ('CARRIER_READONLY', 'tracking.own'),
  ('AGENCY_ADMIN', 'company.staff'), ('AGENCY_ADMIN', 'report.company'), ('AGENCY_ADMIN', 'company.login_log'),
  ('AGENCY_READONLY', 'report.company'),
  ('STATION_ADMIN', 'company.staff'),
  ('STATION_READONLY', 'station.screens')
) AS x(r, p) ON x.r = r.code AND r.company_id IS NULL
WHERE EXISTS (SELECT 1 FROM iam.permission WHERE code = x.p)
ON CONFLICT DO NOTHING;

-- editing a role replaces its permissions; a platform staff member's roles are replaced when moved
INSERT INTO sys.app_delete_grant (table_name, reason) VALUES
  ('iam.role_permission', 'an administrator edits a role: permissions taken out of the role are removed (1154, N1)'),
  ('iam.user_role', 'an administrator moves a platform staff member to other roles (1154, N1)')
ON CONFLICT (table_name) DO NOTHING;
GRANT DELETE ON iam.role_permission, iam.user_role TO masslak_app;

-- ------------------------------------------------------------------ per-user exceptions
CREATE TABLE IF NOT EXISTS iam.permission_exception (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id         bigint NOT NULL REFERENCES iam.app_user(id),
  company_id      bigint REFERENCES iam.company(id),          -- empty: a platform staff member's exception
  permission_code text NOT NULL REFERENCES iam.permission(code),
  effect          text NOT NULL CHECK (effect IN ('GRANT', 'DENY')),
  reason          text NOT NULL CHECK (length(reason) BETWEEN 5 AND 500),
  valid_from      timestamptz NOT NULL DEFAULT now(),
  valid_to        timestamptz NOT NULL,
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'ACTIVE', 'REJECTED', 'REVOKED')),
  requested_by    bigint NOT NULL REFERENCES iam.app_user(id),
  decided_by      bigint REFERENCES iam.app_user(id),
  decided_at      timestamptz,
  decision_note   text CHECK (decision_note IS NULL OR length(decision_note) BETWEEN 1 AND 500),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT permission_exception_window_ck CHECK (valid_to > valid_from AND valid_to <= valid_from + interval '366 days'),
  -- a second person decides, and never the person the exception is for
  CONSTRAINT permission_exception_four_eyes_ck CHECK (decided_by IS NULL OR (decided_by <> requested_by AND decided_by <> user_id)),
  CONSTRAINT permission_exception_decision_ck CHECK ((status = 'PENDING') = (decided_by IS NULL AND decided_at IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS permission_exception_uid_uq ON iam.permission_exception (uid);
-- one open exception per person, company and permission
CREATE UNIQUE INDEX IF NOT EXISTS permission_exception_open_uq ON iam.permission_exception (user_id, coalesce(company_id, 0), permission_code)
  WHERE status IN ('PENDING', 'ACTIVE');
CREATE INDEX IF NOT EXISTS permission_exception_user_id_fkx ON iam.permission_exception (user_id);
CREATE INDEX IF NOT EXISTS permission_exception_company_id_fkx ON iam.permission_exception (company_id);
CREATE INDEX IF NOT EXISTS permission_exception_permission_code_fkx ON iam.permission_exception (permission_code);
CREATE INDEX IF NOT EXISTS permission_exception_requested_by_fkx ON iam.permission_exception (requested_by);
CREATE INDEX IF NOT EXISTS permission_exception_decided_by_fkx ON iam.permission_exception (decided_by);
DROP TRIGGER IF EXISTS permission_exception_updated ON iam.permission_exception;
CREATE TRIGGER permission_exception_updated BEFORE UPDATE ON iam.permission_exception
  FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE iam.permission_exception IS
  'A permission granted or denied to one person beyond their role, with an end date and a reason, active once a second person approves (1154, N1)';

-- what was decided stays decided: only an active exception may still be revoked
CREATE OR REPLACE FUNCTION iam.tg_permission_exception_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IN ('REJECTED', 'REVOKED') THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: a decided exception is not changed' USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.status = 'ACTIVE' AND NEW.status <> 'REVOKED' THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: an active exception is only revoked' USING ERRCODE = 'check_violation';
  END IF;
  IF (NEW.user_id, NEW.company_id, NEW.permission_code, NEW.effect, NEW.reason, NEW.valid_from, NEW.valid_to, NEW.requested_by)
     IS DISTINCT FROM (OLD.user_id, OLD.company_id, OLD.permission_code, OLD.effect, OLD.reason, OLD.valid_from, OLD.valid_to, OLD.requested_by) THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: the request itself is not rewritten; ask again' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS permission_exception_frozen ON iam.permission_exception;
CREATE TRIGGER permission_exception_frozen BEFORE UPDATE ON iam.permission_exception
  FOR EACH ROW EXECUTE FUNCTION iam.tg_permission_exception_frozen();

SELECT sys.rls('iam.permission_exception',
  'sys.ctx_is_platform() OR (company_id IS NOT NULL AND company_id = sys.ctx_company_id()) OR user_id = sys.ctx_user_id()');
ALTER TABLE iam.permission_exception FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON iam.permission_exception TO masslak_app;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('iam.permission_exception', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
SELECT sys.enforce_app_delete_grants();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.permission_exception', 'iam records', 'per-user grants and denials beyond a role, approved by a second person (1154)')
ON CONFLICT (table_name) DO NOTHING;

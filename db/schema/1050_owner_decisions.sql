-- =====================================================================
-- 1050: the owner's decisions after the review of design 3.9 (docs/operations/LAUNCH_GATES.md)
--   A  Recovery and service targets approved: RPO 60 s, RTO 30 min, and the SLOs of docs/operations/SLO.md. They are
--      settings, so the restore drill and monitoring compare their measurements with the approved values.
--   B  External reviewers (auditors, penetration testers) get access only through the permission matrix: the role
--      EXTERNAL_AUDITOR, read-only, granted by a second person for a stated reason and a limited time (at most
--      security.external_access_max_days), announced at once, never open-ended.
-- =====================================================================

-- =====================================================================
-- A  approved targets
-- =====================================================================
INSERT INTO sys.setting (key, value, description) VALUES
  ('recovery.rpo_seconds', '60', 'Approved recovery point objective: data that may be lost when the server is lost (owner, 8 October 2026)'),
  ('recovery.rto_minutes', '30', 'Approved recovery time objective: time to a usable database on new hardware (owner, 8 October 2026)'),
  ('slo.objectives', '{"approved_on": "2026-10-08", "booking_payment_availability": 0.999, "booking_p95_s": 0.8, "booking_p99_s": 1.5,
     "search_p95_s": 0.3, "search_availability": 0.999, "tracking_availability": 0.995, "tracking_p95_s": 0.5,
     "outbox_oldest_s": 120, "wallet_mismatches": 0}',
   'Approved service level objectives (docs/operations/SLO.md); alerts and the launch gates use them')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;

-- =====================================================================
-- B  external reviewers: read-only, time-bound, granted by a second person
-- =====================================================================
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('external_access.grant', 'security', 'PLATFORM', 'Grant or revoke time-bound read-only access for external auditors and penetration testers', true)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role (code, name, scope, is_system)
SELECT 'EXTERNAL_AUDITOR', 'External auditor or penetration tester (read-only, time-bound)', 'PLATFORM', true
 WHERE NOT EXISTS (SELECT 1 FROM iam.role WHERE code = 'EXTERNAL_AUDITOR' AND company_id IS NULL);
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, p.code FROM iam.role r,
       (VALUES ('audit.view'), ('policy.matrix')) p(code)
 WHERE r.code = 'EXTERNAL_AUDITOR' AND r.company_id IS NULL
ON CONFLICT DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'external_access.grant' FROM iam.role r WHERE r.code IN ('PLATFORM_ADMIN', 'PLATFORM_SECURITY') AND r.company_id IS NULL
ON CONFLICT DO NOTHING;
INSERT INTO sys.setting (key, value, description) VALUES
  ('security.external_access_max_days', '30', 'Longest access an external auditor or tester can be given in one grant')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS sec.external_access_grant (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid          uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  user_id      bigint NOT NULL REFERENCES iam.app_user(id),
  granted_by   bigint NOT NULL REFERENCES iam.app_user(id),
  organisation text NOT NULL CHECK (length(btrim(organisation)) >= 2),
  purpose      text NOT NULL CHECK (length(btrim(purpose)) >= 10),
  engagement_ref text NOT NULL CHECK (length(btrim(engagement_ref)) >= 3),
  starts_at    timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  revoked_by   bigint REFERENCES iam.app_user(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (granted_by <> user_id),
  CHECK (expires_at > starts_at),
  CHECK ((revoked_at IS NULL) = (revoked_by IS NULL))
);
CREATE INDEX IF NOT EXISTS external_access_grant_user_id_fkx ON sec.external_access_grant (user_id);
CREATE INDEX IF NOT EXISTS external_access_grant_granted_by_fkx ON sec.external_access_grant (granted_by);
CREATE INDEX IF NOT EXISTS external_access_grant_revoked_by_fkx ON sec.external_access_grant (revoked_by);
COMMENT ON TABLE sec.external_access_grant IS 'Every access given to an external auditor or tester: who, for which engagement, granted by whom, until when (owner decision, 8 October 2026)';
SELECT sys.rls('sec.external_access_grant', 'sys.ctx_is_platform()');
GRANT SELECT, INSERT, UPDATE ON sec.external_access_grant TO masslak_app;
GRANT SELECT ON sec.external_access_grant TO masslak_readonly, masslak_auditor;

-- A grant is limited in time, never widened, never deleted; the role assignment follows it
CREATE OR REPLACE FUNCTION sec.tg_external_access() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE max_days int := coalesce((SELECT value::int FROM sys.setting WHERE key = 'security.external_access_max_days'), 30);
        rid bigint := (SELECT id FROM iam.role WHERE code = 'EXTERNAL_AUDITOR' AND company_id IS NULL);
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'EXTERNAL_ACCESS_SEALED: an access grant is never deleted; revoke it' USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.expires_at > NEW.starts_at + make_interval(days => max_days) THEN
      RAISE EXCEPTION 'EXTERNAL_ACCESS_TOO_LONG: external access lasts at most % days per grant', max_days USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM iam.app_user u WHERE u.id = NEW.user_id AND u.account_kind = 'PLATFORM' AND u.status = 'ACTIVE') THEN
      RAISE EXCEPTION 'EXTERNAL_ACCESS_ACCOUNT: the reviewer needs an active platform account of their own' USING ERRCODE = 'P0001';
    END IF;
    DELETE FROM iam.user_role WHERE user_id = NEW.user_id AND role_id = rid;
    INSERT INTO iam.user_role (user_id, role_id, granted_by, valid_to) VALUES (NEW.user_id, rid, NEW.granted_by, NEW.expires_at);
    INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
    VALUES ('security.external_access_granted', 'external_access_grant', NEW.id,
            jsonb_build_object('user_id', NEW.user_id, 'organisation', NEW.organisation, 'engagement_ref', NEW.engagement_ref,
                               'expires_at', NEW.expires_at, 'granted_by', NEW.granted_by));
    RETURN NEW;
  END IF;
  IF NEW.user_id <> OLD.user_id OR NEW.granted_by <> OLD.granted_by OR NEW.organisation <> OLD.organisation
     OR NEW.purpose <> OLD.purpose OR NEW.engagement_ref <> OLD.engagement_ref OR NEW.starts_at <> OLD.starts_at
     OR NEW.expires_at > OLD.expires_at OR (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at) THEN
    RAISE EXCEPTION 'EXTERNAL_ACCESS_SEALED: a grant can only be shortened or revoked; give a new grant to extend it' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.revoked_at IS NOT NULL AND OLD.revoked_at IS NULL THEN
    UPDATE iam.user_role SET valid_to = least(coalesce(valid_to, NEW.revoked_at), NEW.revoked_at)
     WHERE user_id = NEW.user_id AND role_id = rid;
    INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
    VALUES ('security.external_access_revoked', 'external_access_grant', NEW.id, jsonb_build_object('user_id', NEW.user_id));
  ELSIF NEW.expires_at < OLD.expires_at THEN
    UPDATE iam.user_role SET valid_to = NEW.expires_at WHERE user_id = NEW.user_id AND role_id = rid;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS external_access ON sec.external_access_grant;
CREATE TRIGGER external_access AFTER INSERT ON sec.external_access_grant FOR EACH ROW EXECUTE FUNCTION sec.tg_external_access();
DROP TRIGGER IF EXISTS external_access_change ON sec.external_access_grant;
CREATE TRIGGER external_access_change BEFORE UPDATE OR DELETE ON sec.external_access_grant FOR EACH ROW EXECUTE FUNCTION sec.tg_external_access();

-- The role cannot be handed out any other way: an EXTERNAL_AUDITOR assignment always has an end, matching a live grant
CREATE OR REPLACE FUNCTION iam.tg_external_role_bounded() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.role_id = (SELECT id FROM iam.role WHERE code = 'EXTERNAL_AUDITOR' AND company_id IS NULL)
     AND (NEW.valid_to IS NULL OR NOT EXISTS (SELECT 1 FROM sec.external_access_grant g WHERE g.user_id = NEW.user_id
                                                 AND g.revoked_at IS NULL AND g.expires_at >= NEW.valid_to)) THEN
    RAISE EXCEPTION 'EXTERNAL_ACCESS_GRANT_REQUIRED: the external auditor role comes only from a time-bound access grant' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS external_role_bounded ON iam.user_role;
CREATE TRIGGER external_role_bounded BEFORE INSERT OR UPDATE OF role_id, valid_to ON iam.user_role
  FOR EACH ROW EXECUTE FUNCTION iam.tg_external_role_bounded();

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sec.external_access_grant', '1A', 'E25')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days)
VALUES ('sec.external_access_grant', 'CONFIDENTIAL', 'sec', 'Access given to external auditors and testers', 'Legitimate interest (security)',
        2555, 'KEEP_LEGAL', '{backup,archive}', 35)
ON CONFLICT (dataset) DO NOTHING;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.32.0', 'Owner decisions: approved RPO, RTO and SLOs as settings; time-bound external auditor access through the permission matrix'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.32.0');

SELECT sys.refresh_table_class();

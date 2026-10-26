-- =====================================================================
-- Masslak - 1089: a change to the documents accepted for a photo change, and to the identity age rule, needs two
--               people (the eighth round, 11 October 2026)
--
-- The owner's decisions: switching a kind of evidence on or off needs at least two people, and more when the platform's
-- settings ask for it. The age below which a national identity card is not accepted is a platform setting.
--
-- A change is asked for by one platform person, who counts as the first approval; each further approval is a different
-- platform person; the change applies when the approvals reach the number in the settings (never fewer than two). The
-- request function refuses a document that is off, and a national identity card for a person younger than the age in the
-- settings or whose birth date is not known while that rule is set. Nothing refers to the new tables except the approvals,
-- so they add no reference cycle (db/tools/schema_dependencies.py).
-- =====================================================================

-- 1. the settings: the number of approvals (never below two) and the age rule (null: no age rule) ---------------------
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('photo.policy_min_approvals', '2'::jsonb, 'PLATFORM',
   'People who approve a change to the documents accepted for a photo change, counting the one who asks; never fewer than two'),
  ('photo.identity_card_min_age', 'null'::jsonb, 'PLATFORM',
   'Age in years below which a national identity card is not accepted as evidence for a photo change; null: no age rule')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION iam.photo_policy_min_approvals() RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT greatest(2, coalesce((SELECT (value #>> '{}')::integer FROM sys.setting WHERE key = 'photo.policy_min_approvals'), 2))
$$;

-- 2. the changes and their approvals -----------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iam.photo_policy_change (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  change_type          text NOT NULL CHECK (change_type IN ('EVIDENCE_KIND', 'IDENTITY_MIN_AGE')),
  evidence_code        text REFERENCES iam.photo_evidence_kind (code),
  new_active           boolean,
  new_min_age          integer CHECK (new_min_age BETWEEN 0 AND 120),                  -- null: the rule is cleared
  reason               text NOT NULL CHECK (length(reason) BETWEEN 10 AND 500),
  requested_by_user_id bigint NOT NULL REFERENCES iam.app_user (id),
  requested_at         timestamptz NOT NULL DEFAULT now(),
  status               text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPLIED', 'REJECTED')),
  decided_by_user_id   bigint REFERENCES iam.app_user (id),
  decided_at           timestamptz,
  CHECK (change_type <> 'EVIDENCE_KIND' OR (evidence_code IS NOT NULL AND new_active IS NOT NULL AND new_min_age IS NULL)),
  CHECK (change_type <> 'IDENTITY_MIN_AGE' OR (evidence_code IS NULL AND new_active IS NULL)),
  CHECK (status = 'PENDING' OR decided_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS photo_policy_change_evidence_code_fkx ON iam.photo_policy_change (evidence_code);
CREATE INDEX IF NOT EXISTS photo_policy_change_requested_by_user_id_fkx ON iam.photo_policy_change (requested_by_user_id);
CREATE INDEX IF NOT EXISTS photo_policy_change_decided_by_user_id_fkx ON iam.photo_policy_change (decided_by_user_id);
COMMENT ON TABLE iam.photo_policy_change IS 'A change to the accepted evidence or the identity age rule of a photo change; two people (1089)';

CREATE TABLE IF NOT EXISTS iam.photo_policy_approval (
  change_id        bigint NOT NULL REFERENCES iam.photo_policy_change (id),
  approver_user_id bigint NOT NULL REFERENCES iam.app_user (id),
  approved_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (change_id, approver_user_id)
);
CREATE INDEX IF NOT EXISTS photo_policy_approval_approver_user_id_fkx ON iam.photo_policy_approval (approver_user_id);
COMMENT ON TABLE iam.photo_policy_approval IS 'Who approved a change of the photo policy; the one who asks is the first (1089)';

SELECT sys.rls_platform('iam.photo_policy_change');
SELECT sys.rls_platform('iam.photo_policy_approval');
GRANT SELECT ON iam.photo_policy_change, iam.photo_policy_approval TO masslak_app;

-- 3. the functions that change them ------------------------------------------------------------------------------------
-- the one who asks counts as the first approval
CREATE OR REPLACE FUNCTION iam.request_photo_policy_change(p_type text, p_evidence_code text, p_active boolean,
    p_min_age integer, p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_id bigint; v_uid uuid;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the photo policy is a platform task' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_policy_change (change_type, evidence_code, new_active, new_min_age, reason, requested_by_user_id)
  VALUES (p_type, p_evidence_code, p_active, p_min_age, p_reason, sys.ctx_user_id())
  RETURNING id, uid INTO v_id, v_uid;
  INSERT INTO iam.photo_policy_approval (change_id, approver_user_id) VALUES (v_id, sys.ctx_user_id());
  RETURN v_uid;
END $$;

-- returns PENDING while approvals are short of the number in the settings, and APPLIED once they reach it
CREATE OR REPLACE FUNCTION iam.approve_photo_policy_change(p_uid uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c iam.photo_policy_change; v_count integer;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the photo policy is a platform task' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO c FROM iam.photo_policy_change WHERE uid = p_uid AND status = 'PENDING' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_PENDING: the change is not waiting for approval' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM iam.photo_policy_approval WHERE change_id = c.id AND approver_user_id = sys.ctx_user_id()) THEN
    RAISE EXCEPTION 'ALREADY_APPROVED: this person has already approved the change' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_policy_approval (change_id, approver_user_id) VALUES (c.id, sys.ctx_user_id());
  SELECT count(*) INTO v_count FROM iam.photo_policy_approval WHERE change_id = c.id;
  IF v_count < iam.photo_policy_min_approvals() THEN
    RETURN 'PENDING';
  END IF;
  IF c.change_type = 'EVIDENCE_KIND' THEN
    UPDATE iam.photo_evidence_kind SET active = c.new_active, changed_by_user_id = sys.ctx_user_id(), changed_at = now()
     WHERE code = c.evidence_code;
  ELSE
    INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
    VALUES ('photo.identity_card_min_age', coalesce(to_jsonb(c.new_min_age), 'null'::jsonb), 'PLATFORM',
            'Age in years below which a national identity card is not accepted as evidence for a photo change; null: no age rule',
            sys.ctx_user_id(), now())
    ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  END IF;
  UPDATE iam.photo_policy_change SET status = 'APPLIED', decided_by_user_id = sys.ctx_user_id(), decided_at = now()
   WHERE id = c.id;
  RETURN 'APPLIED';
END $$;

CREATE OR REPLACE FUNCTION iam.reject_photo_policy_change(p_uid uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the photo policy is a platform task' USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.photo_policy_change SET status = 'REJECTED', decided_by_user_id = sys.ctx_user_id(), decided_at = now()
   WHERE uid = p_uid AND status = 'PENDING';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_PENDING: the change is not waiting for a decision' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- the evidence a person may show now: the kind is on, and for a national identity card the age rule is met
CREATE OR REPLACE FUNCTION iam.evidence_accepted(p_party_id bigint, p_kind text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_min integer; v_birth date;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM iam.photo_evidence_kind WHERE code = p_kind AND active) THEN
    RETURN false;
  END IF;
  IF p_kind = 'IDENTITY_DOCUMENT' THEN
    v_min := (SELECT (value #>> '{}')::integer FROM sys.setting WHERE key = 'photo.identity_card_min_age');
    IF v_min IS NOT NULL THEN
      SELECT birth_date INTO v_birth FROM iam.party WHERE id = p_party_id;
      IF v_birth IS NULL OR age(current_date, v_birth) < make_interval(years => v_min) THEN
        RETURN false;
      END IF;
    END IF;
  END IF;
  RETURN true;
END $$;

-- the request of 1088 is replaced: it checks the same thing through evidence_accepted, which also knows the age rule
CREATE OR REPLACE FUNCTION iam.request_photo_change(p_party_id bigint, p_reason text, p_evidence_kind text,
    p_evidence_file_id bigint, p_photo_file_id bigint) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_uid uuid;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: a photo change is a platform task' USING ERRCODE = 'P0001';
  END IF;
  IF NOT iam.evidence_accepted(p_party_id, p_evidence_kind) THEN
    RAISE EXCEPTION 'EVIDENCE_KIND_NOT_ACCEPTED: this document is not accepted as evidence for this person now' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_change_request (party_id, requested_by_user_id, reason, evidence_kind, evidence_file_id, photo_file_id)
  VALUES (p_party_id, sys.ctx_user_id(), p_reason, p_evidence_kind, p_evidence_file_id, p_photo_file_id)
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- the one-person switch of 1088 is withdrawn: a change of the setting goes through the approvals above
DROP FUNCTION IF EXISTS iam.set_photo_evidence_kind(text, boolean);

REVOKE ALL ON FUNCTION iam.photo_policy_min_approvals() FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.request_photo_policy_change(text, text, boolean, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.approve_photo_policy_change(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.reject_photo_policy_change(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.evidence_accepted(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.photo_policy_min_approvals() TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.request_photo_policy_change(text, text, boolean, integer, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.approve_photo_policy_change(uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.reject_photo_policy_change(uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.evidence_accepted(bigint, text) TO masslak_app;

-- 4. the lifecycle of the new tables (1079) -------------------------------------------------------------------------
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('iam.photo_policy_change', '1A', 'E01'), ('iam.photo_policy_approval', '1A', 'E01')
ON CONFLICT (table_name) DO NOTHING;
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('iam.photo_policy_change', 'PLATFORM_CONFIDENTIAL', NULL, 'changes to the accepted evidence and the age rule (1089)'),
  ('iam.photo_policy_approval', 'PLATFORM_CONFIDENTIAL', NULL, 'who approved a change of the photo policy (1089)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.photo_policy_change', 'gov records', 'the changes that decide which documents a photo change accepts (1089)'),
  ('iam.photo_policy_approval', 'gov records', 'the approvals of those changes (1089)');

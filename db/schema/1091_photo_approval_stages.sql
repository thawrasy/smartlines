-- =====================================================================
-- Masslak - 1091: the approval stages of a change are a platform setting; the age default is 18; each data item can be
--               required or optional (the ninth round, 11 October 2026)
--
-- The owner's decisions: a change requested by one person goes to the platform and passes through the stages set in the
-- platform's settings, by default two: a checker, then the final approval by a second person. A stage is one person who
-- is not the requester and has not approved earlier in the same change. The number of stages can be raised later, never
-- below two. The age below which a national identity card is not accepted is 18 by default and changes with the law.
-- Each item of data is set as required or optional in the settings, until the laws say which items are compulsory.
--
-- A change snapshots the stages when it is requested, so a later change of the setting does not alter a request in progress.
-- The approvals of both kinds of change (a change of a photo on file, and a change of the photo policy) are one table.
-- Nothing refers to the approvals except the requests, so no reference cycle is added (db/tools/schema_dependencies.py).
-- =====================================================================

-- 1. the settings ----------------------------------------------------------------------------------------------------
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('photo.approval_stages', '["CHECK","APPROVE"]'::jsonb, 'PLATFORM',
   'The stages a change passes after the one who asks: CHECK (checks the evidence and the data), THIRD_PARTY_CHECK, and APPROVE (the final approval, always last); at least two')
ON CONFLICT (key) DO NOTHING;
UPDATE sys.setting SET value = '18'::jsonb,
       description = 'Age in years below which a national identity card is not accepted as evidence for a photo change; null: no age rule; set by law'
 WHERE key = 'photo.identity_card_min_age' AND value = 'null'::jsonb;
DELETE FROM sys.setting WHERE key = 'photo.policy_min_approvals';

-- the stages in force, never fewer than two, the last one the final approval; the default when the setting is not valid
CREATE OR REPLACE FUNCTION iam.photo_approval_stages() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((
    SELECT s.value FROM sys.setting s
     WHERE s.key = 'photo.approval_stages'
       AND jsonb_typeof(s.value) = 'array'
       AND jsonb_array_length(s.value) >= 2
       AND s.value ->> (jsonb_array_length(s.value) - 1) = 'APPROVE'
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(s.value) e
                        WHERE e NOT IN ('CHECK', 'THIRD_PARTY_CHECK', 'APPROVE'))),
    '["CHECK","APPROVE"]'::jsonb)
$$;

-- 2. the data items that are required or optional --------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iam.data_requirement (
  field_code         text PRIMARY KEY CHECK (field_code ~ '^[a-z]+\.[a-z_]+$'),
  label              text NOT NULL CHECK (length(label) BETWEEN 3 AND 120),
  requirement        text NOT NULL DEFAULT 'OPTIONAL' CHECK (requirement IN ('REQUIRED', 'OPTIONAL')),
  changed_by_user_id bigint REFERENCES iam.app_user (id),
  changed_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS data_requirement_changed_by_user_id_fkx ON iam.data_requirement (changed_by_user_id);
COMMENT ON TABLE iam.data_requirement IS 'Which data items a photo change needs: REQUIRED or OPTIONAL, set by the platform until the law says (1091)';
INSERT INTO iam.data_requirement (field_code, label, requirement) VALUES
  ('party.birth_date', 'Date of birth', 'OPTIONAL'),
  ('party.nationality', 'Nationality', 'OPTIONAL'),
  ('party.national_number', 'National number on the person''s record', 'OPTIONAL'),
  ('evidence.national_number', 'National number shown on the evidence (checked by the approver)', 'OPTIONAL')
ON CONFLICT (field_code) DO NOTHING;
SELECT sys.rls_platform('iam.data_requirement');
GRANT SELECT ON iam.data_requirement TO masslak_app;

-- true when the item is not required, or the person's record has it; the evidence number is checked by the approver
CREATE OR REPLACE FUNCTION iam.data_requirement_met(p_party_id bigint, p_field text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_req text; v_ok boolean;
BEGIN
  SELECT requirement INTO v_req FROM iam.data_requirement WHERE field_code = p_field;
  IF v_req IS NULL OR v_req = 'OPTIONAL' THEN
    RETURN true;
  END IF;
  SELECT CASE p_field
           WHEN 'party.birth_date' THEN p.birth_date IS NOT NULL
           WHEN 'party.nationality' THEN p.nationality IS NOT NULL
           WHEN 'party.national_number' THEN p.id_no_enc IS NOT NULL
           ELSE true
         END
    INTO v_ok FROM iam.party p WHERE p.id = p_party_id;
  RETURN coalesce(v_ok, false);
END $$;

-- 3. the approvals, one table for both kinds of change ---------------------------------------------------------------
ALTER TABLE iam.photo_change_request ADD COLUMN IF NOT EXISTS approval_stages jsonb NOT NULL DEFAULT '["CHECK","APPROVE"]'::jsonb
  CHECK (jsonb_typeof(approval_stages) = 'array' AND jsonb_array_length(approval_stages) >= 2);
ALTER TABLE iam.photo_policy_change ADD COLUMN IF NOT EXISTS approval_stages jsonb NOT NULL DEFAULT '["CHECK","APPROVE"]'::jsonb
  CHECK (jsonb_typeof(approval_stages) = 'array' AND jsonb_array_length(approval_stages) >= 2);

CREATE TABLE IF NOT EXISTS iam.photo_approval (
  subject_type     text NOT NULL CHECK (subject_type IN ('CHANGE_REQUEST', 'POLICY_CHANGE')),
  subject_id       bigint NOT NULL,                       -- a row of iam.photo_change_request or iam.photo_policy_change
  step             integer NOT NULL CHECK (step >= 1),
  stage_kind       text NOT NULL CHECK (stage_kind IN ('CHECK', 'THIRD_PARTY_CHECK', 'APPROVE')),
  approver_user_id bigint NOT NULL REFERENCES iam.app_user (id),
  approved_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (subject_type, subject_id, step),
  UNIQUE (subject_type, subject_id, approver_user_id)
);
CREATE INDEX IF NOT EXISTS photo_approval_approver_user_id_fkx ON iam.photo_approval (approver_user_id);
COMMENT ON TABLE iam.photo_approval IS 'The approvals of a change of a photo on file or of the photo policy, one row per stage (1091)';
SELECT sys.rls_platform('iam.photo_approval');
GRANT SELECT ON iam.photo_approval TO masslak_app;

-- the next stage of a change: the one who asks does not approve it, nobody approves twice, the stages are in order
CREATE OR REPLACE FUNCTION iam.record_photo_approval(p_type text, p_id bigint, p_requester bigint, p_stages jsonb) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_me bigint := sys.ctx_user_id(); v_step integer;
BEGIN
  IF v_me = p_requester THEN
    RAISE EXCEPTION 'FOUR_EYES: the one who asks for a change does not approve it' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM iam.photo_approval WHERE subject_type = p_type AND subject_id = p_id AND approver_user_id = v_me) THEN
    RAISE EXCEPTION 'ALREADY_APPROVED: this person has already approved the change' USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) + 1 INTO v_step FROM iam.photo_approval WHERE subject_type = p_type AND subject_id = p_id;
  IF v_step > jsonb_array_length(p_stages) THEN
    RAISE EXCEPTION 'NOT_PENDING: the change has passed all its stages' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_approval (subject_type, subject_id, step, stage_kind, approver_user_id)
  VALUES (p_type, p_id, v_step, p_stages ->> (v_step - 1), v_me);
  RETURN v_step;
END $$;
REVOKE ALL ON FUNCTION iam.record_photo_approval(text, bigint, bigint, jsonb) FROM PUBLIC;

-- 4. the change of a photo on file: the stages, then the photo is replaced (1087) -------------------------------------
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
  IF EXISTS (SELECT 1 FROM iam.data_requirement WHERE requirement = 'REQUIRED' AND NOT iam.data_requirement_met(p_party_id, field_code)) THEN
    RAISE EXCEPTION 'DATA_REQUIRED: an item the platform requires is missing from the person''s record' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_change_request (party_id, requested_by_user_id, reason, evidence_kind, evidence_file_id, photo_file_id, approval_stages)
  VALUES (p_party_id, sys.ctx_user_id(), p_reason, p_evidence_kind, p_evidence_file_id, p_photo_file_id, iam.photo_approval_stages())
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- replaces apply_photo_change of 1087: each stage is recorded; the last one replaces the photo
DROP FUNCTION IF EXISTS iam.apply_photo_change(uuid);
CREATE OR REPLACE FUNCTION iam.approve_photo_change(p_uid uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r iam.photo_change_request; v_old bigint; v_step integer;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: a photo change is a platform task' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM iam.photo_change_request WHERE uid = p_uid AND status = 'PENDING' FOR UPDATE;
  IF NOT FOUND OR r.photo_file_id IS NULL THEN
    RAISE EXCEPTION 'NOT_PENDING: the request is not waiting for a decision' USING ERRCODE = 'P0001';
  END IF;
  v_step := iam.record_photo_approval('CHANGE_REQUEST', r.id, r.requested_by_user_id, r.approval_stages);
  IF v_step < jsonb_array_length(r.approval_stages) THEN
    RETURN 'PENDING';
  END IF;
  SELECT pp.file_id INTO v_old FROM iam.party_photo pp WHERE pp.party_id = r.party_id FOR UPDATE;
  IF v_old IS NULL THEN
    INSERT INTO iam.party_photo (party_id, file_id, taken_by, taken_by_user_id)
    VALUES (r.party_id, r.photo_file_id, 'PLATFORM', sys.ctx_user_id());
  ELSE
    UPDATE iam.party_photo SET file_id = r.photo_file_id, taken_by = 'PLATFORM', taken_by_user_id = sys.ctx_user_id(),
                               taken_at = now()
     WHERE party_id = r.party_id;
    DELETE FROM ref.file_object WHERE id = v_old;
  END IF;
  UPDATE iam.photo_change_request SET status = 'APPLIED', decided_by_user_id = sys.ctx_user_id(), decided_at = now(),
                                      photo_file_id = NULL
   WHERE id = r.id;
  RETURN 'APPLIED';
END $$;

-- 5. the photo policy: the stages, the kinds, the age and the data items (1089 extended) -----------------------------
ALTER TABLE iam.photo_policy_change DROP CONSTRAINT photo_policy_change_change_type_check;
ALTER TABLE iam.photo_policy_change DROP CONSTRAINT photo_policy_change_check;
ALTER TABLE iam.photo_policy_change DROP CONSTRAINT photo_policy_change_check1;
ALTER TABLE iam.photo_policy_change ADD COLUMN IF NOT EXISTS field_code text REFERENCES iam.data_requirement (field_code);
ALTER TABLE iam.photo_policy_change ADD COLUMN IF NOT EXISTS new_requirement text CHECK (new_requirement IN ('REQUIRED', 'OPTIONAL'));
ALTER TABLE iam.photo_policy_change ADD CONSTRAINT photo_policy_change_change_type_check
  CHECK (change_type IN ('EVIDENCE_KIND', 'IDENTITY_MIN_AGE', 'FIELD_REQUIREMENT'));
ALTER TABLE iam.photo_policy_change ADD CONSTRAINT photo_policy_change_shape_check CHECK (
     (change_type = 'EVIDENCE_KIND' AND evidence_code IS NOT NULL AND new_active IS NOT NULL
        AND new_min_age IS NULL AND field_code IS NULL AND new_requirement IS NULL)
  OR (change_type = 'IDENTITY_MIN_AGE' AND evidence_code IS NULL AND new_active IS NULL
        AND field_code IS NULL AND new_requirement IS NULL)
  OR (change_type = 'FIELD_REQUIREMENT' AND field_code IS NOT NULL AND new_requirement IS NOT NULL
        AND evidence_code IS NULL AND new_active IS NULL AND new_min_age IS NULL));
CREATE INDEX IF NOT EXISTS photo_policy_change_field_code_fkx ON iam.photo_policy_change (field_code);

CREATE OR REPLACE FUNCTION iam.request_photo_policy_change(p_type text, p_evidence_code text, p_active boolean,
    p_min_age integer, p_field text, p_requirement text, p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_uid uuid;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the photo policy is a platform task' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_policy_change (change_type, evidence_code, new_active, new_min_age, field_code, new_requirement, reason,
                                       requested_by_user_id, approval_stages)
  VALUES (p_type, p_evidence_code, p_active, p_min_age, p_field, p_requirement, p_reason, sys.ctx_user_id(),
          iam.photo_approval_stages())
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;
DROP FUNCTION IF EXISTS iam.request_photo_policy_change(text, text, boolean, integer, text);

-- the photo policy change is applied when its last stage is recorded
CREATE OR REPLACE FUNCTION iam.approve_photo_policy_change(p_uid uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c iam.photo_policy_change; v_step integer;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the photo policy is a platform task' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO c FROM iam.photo_policy_change WHERE uid = p_uid AND status = 'PENDING' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_PENDING: the change is not waiting for approval' USING ERRCODE = 'P0001';
  END IF;
  v_step := iam.record_photo_approval('POLICY_CHANGE', c.id, c.requested_by_user_id, c.approval_stages);
  IF v_step < jsonb_array_length(c.approval_stages) THEN
    RETURN 'PENDING';
  END IF;
  IF c.change_type = 'EVIDENCE_KIND' THEN
    UPDATE iam.photo_evidence_kind SET active = c.new_active, changed_by_user_id = sys.ctx_user_id(), changed_at = now()
     WHERE code = c.evidence_code;
  ELSIF c.change_type = 'IDENTITY_MIN_AGE' THEN
    INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
    VALUES ('photo.identity_card_min_age', coalesce(to_jsonb(c.new_min_age), 'null'::jsonb), 'PLATFORM',
            'Age in years below which a national identity card is not accepted as evidence for a photo change; null: no age rule; set by law',
            sys.ctx_user_id(), now())
    ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  ELSE
    UPDATE iam.data_requirement SET requirement = c.new_requirement, changed_by_user_id = sys.ctx_user_id(), changed_at = now()
     WHERE field_code = c.field_code;
  END IF;
  UPDATE iam.photo_policy_change SET status = 'APPLIED', decided_by_user_id = sys.ctx_user_id(), decided_at = now()
   WHERE id = c.id;
  RETURN 'APPLIED';
END $$;

DROP FUNCTION IF EXISTS iam.photo_policy_min_approvals();

-- 6. the one-approver table of 1089 is replaced by the table above ----------------------------------------------------
DELETE FROM sys.table_phase WHERE table_name = 'iam.photo_policy_approval';
DELETE FROM sys.table_class WHERE table_name = 'iam.photo_policy_approval';
DELETE FROM gov.dataset_member WHERE table_name = 'iam.photo_policy_approval';
DROP TABLE IF EXISTS iam.photo_policy_approval;

-- 7. grants of the functions the application calls -------------------------------------------------------------------
REVOKE ALL ON FUNCTION iam.photo_approval_stages() FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.data_requirement_met(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.approve_photo_change(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.request_photo_policy_change(text, text, boolean, integer, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.approve_photo_policy_change(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.photo_approval_stages() TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.data_requirement_met(bigint, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.approve_photo_change(uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.request_photo_policy_change(text, text, boolean, integer, text, text, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.approve_photo_policy_change(uuid) TO masslak_app;

-- 8. the lifecycle of the new tables (1079) ---------------------------------------------------------------------------
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('iam.photo_approval', '1A', 'E01'), ('iam.data_requirement', '1A', 'E01')
ON CONFLICT (table_name) DO NOTHING;
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('iam.photo_approval', 'PLATFORM_CONFIDENTIAL', NULL, 'the approvals of a photo change and of the photo policy, stage by stage (1091)'),
  ('iam.data_requirement', 'PLATFORM_CONFIDENTIAL', NULL, 'which data items a photo change needs (1091)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.photo_approval', 'gov records', 'the approvals of changes that decide who may change a boarding photo (1091)'),
  ('iam.data_requirement', 'gov records', 'the data a photo change requires, set by the platform (1091)');

-- 9. the approvals refer to two kinds of change: registered with their targets (audit R-03) ---------------------------
INSERT INTO sys.polymorphic_reference (table_name, type_col, id_col, kind, targets, owner, reason) VALUES
  ('iam.photo_approval', 'subject_type', 'subject_id', 'TYPED',
   '{"CHANGE_REQUEST": "iam.photo_change_request", "POLICY_CHANGE": "iam.photo_policy_change"}'::jsonb, 'iam',
   'the approvals of a change of a photo on file or of the photo policy; the stages are recorded by iam.record_photo_approval (1091)');

-- 10. the stages of a change are a JSON value with a contract: at least two, of the known kinds (audit R-08) -----------
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('iam.photo_change_request', 'approval_stages', 'CONFIG', 1,
   '{"type": "array", "minItems": 2, "items": {"enum": ["CHECK", "THIRD_PARTY_CHECK", "APPROVE"]}}'::jsonb,
   'the approval stages of a photo change, frozen when it is asked (1091)'),
  ('iam.photo_policy_change', 'approval_stages', 'CONFIG', 1,
   '{"type": "array", "minItems": 2, "items": {"enum": ["CHECK", "THIRD_PARTY_CHECK", "APPROVE"]}}'::jsonb,
   'the approval stages of a change to the photo policy, frozen when it is asked (1091)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();

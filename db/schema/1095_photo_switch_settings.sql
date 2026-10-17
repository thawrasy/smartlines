-- The approval stages of the photo policy are a setting the platform can change later, and no stage is forced: a security
-- stage (THIRD_PARTY_CHECK) is one of the choices, never a requirement (owner's decision, October 2026). A change applied
-- to the switch records the legal document number that the approver gives with the approval; the number is optional.

-- 1. the stages: a platform setting, valid in shape (never fewer than two, APPROVE always last) --------------------------
CREATE OR REPLACE FUNCTION iam.set_photo_approval_stages(p_stages jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_count integer;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the photo policy is a platform task' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p_stages) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'INVALID_STAGES: the stages are a list' USING ERRCODE = 'P0001';
  END IF;
  v_count := jsonb_array_length(p_stages);
  IF v_count < 2 OR v_count > 5 THEN
    RAISE EXCEPTION 'INVALID_STAGES: at least two stages and at most five' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_stages) e WHERE e NOT IN ('CHECK', 'THIRD_PARTY_CHECK', 'APPROVE')) THEN
    RAISE EXCEPTION 'INVALID_STAGES: a stage is CHECK, THIRD_PARTY_CHECK or APPROVE' USING ERRCODE = 'P0001';
  END IF;
  IF p_stages ->> (v_count - 1) <> 'APPROVE' THEN
    RAISE EXCEPTION 'INVALID_STAGES: the final approval is the last stage' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
  VALUES ('photo.approval_stages', p_stages, 'PLATFORM',
          'The stages a change passes after the one who asks: CHECK, THIRD_PARTY_CHECK (a security or third-party check, optional) and APPROVE (the final approval, always last); at least two (1095)',
          sys.ctx_user_id(), now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  RETURN p_stages;
END $$;

-- 2. the legal document number, recorded with an approval ------------------------------------------------------------
ALTER TABLE iam.photo_policy_change ADD COLUMN IF NOT EXISTS legal_document_no text
  CHECK (length(legal_document_no) BETWEEN 1 AND 100);

-- 3. the approval step takes the optional document number (the body of 1094 with the number recorded) ----------------
DROP FUNCTION IF EXISTS iam.approve_photo_policy_change(uuid);
CREATE OR REPLACE FUNCTION iam.approve_photo_policy_change(p_uid uuid, p_document text DEFAULT NULL) RETURNS text
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
  IF p_document IS NOT NULL THEN
    -- the document number is recorded with the approval; a later approver may give it when the first did not
    UPDATE iam.photo_policy_change SET legal_document_no = p_document WHERE id = c.id;
  END IF;
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
  ELSIF c.change_type = 'FEATURE_ENABLED' THEN
    INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
    VALUES ('photo.enabled', to_jsonb(c.new_active), 'PLATFORM',
            'Whether the boarding photo is taken, shown and required at all. Switched only through a change with a legal basis (1094)',
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

REVOKE ALL ON FUNCTION iam.set_photo_approval_stages(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.approve_photo_policy_change(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.set_photo_approval_stages(jsonb) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.approve_photo_policy_change(uuid, text) TO masslak_app;

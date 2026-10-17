-- The boarding photo is off at launch (owner's decision, October 2026). It is switched on only by a later decision that has a
-- legal basis, an exceptional approval or an explicit security approval, and that passes the approval stages of the photo
-- policy (1091). The switch is a platform setting; the database reads it, so taking a photo is refused while it is off.

-- 1. the switch, off ------------------------------------------------------------------------------------------------------
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('photo.enabled', 'false'::jsonb, 'PLATFORM',
   'Whether the boarding photo is taken, shown and required at all. Off at launch; it is switched on only through a change with a legal basis that passes the approval stages (1094)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION iam.photo_enabled() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT (value #>> '{}')::boolean FROM sys.setting WHERE key = 'photo.enabled'), false)
$$;

-- 2. the change: the switch, its legal basis --------------------------------------------------------------------------
ALTER TABLE iam.photo_policy_change ADD COLUMN IF NOT EXISTS legal_basis text
  CHECK (length(legal_basis) BETWEEN 10 AND 500);
ALTER TABLE iam.photo_policy_change DROP CONSTRAINT IF EXISTS photo_policy_change_change_type_check;
ALTER TABLE iam.photo_policy_change ADD CONSTRAINT photo_policy_change_change_type_check
  CHECK (change_type IN ('EVIDENCE_KIND', 'IDENTITY_MIN_AGE', 'FIELD_REQUIREMENT', 'FEATURE_ENABLED'));
ALTER TABLE iam.photo_policy_change DROP CONSTRAINT IF EXISTS photo_policy_change_shape_check;
ALTER TABLE iam.photo_policy_change ADD CONSTRAINT photo_policy_change_shape_check CHECK (
     (change_type = 'EVIDENCE_KIND' AND evidence_code IS NOT NULL AND new_active IS NOT NULL
        AND new_min_age IS NULL AND field_code IS NULL AND new_requirement IS NULL)
  OR (change_type = 'IDENTITY_MIN_AGE' AND evidence_code IS NULL AND new_active IS NULL
        AND field_code IS NULL AND new_requirement IS NULL)
  OR (change_type = 'FIELD_REQUIREMENT' AND field_code IS NOT NULL AND new_requirement IS NOT NULL
        AND evidence_code IS NULL AND new_active IS NULL AND new_min_age IS NULL)
  OR (change_type = 'FEATURE_ENABLED' AND new_active IS NOT NULL AND evidence_code IS NULL AND new_min_age IS NULL
        AND field_code IS NULL AND new_requirement IS NULL));
-- a legal basis is asked for the switch, and only for it
ALTER TABLE iam.photo_policy_change DROP CONSTRAINT IF EXISTS photo_policy_change_legal_basis_check1;
ALTER TABLE iam.photo_policy_change ADD CONSTRAINT photo_policy_change_legal_basis_check1
  CHECK ((change_type = 'FEATURE_ENABLED') = (legal_basis IS NOT NULL));
-- one switch change waits for approval at a time
CREATE UNIQUE INDEX IF NOT EXISTS photo_policy_change_feature_pending
  ON iam.photo_policy_change ((change_type)) WHERE change_type = 'FEATURE_ENABLED' AND status = 'PENDING';

CREATE OR REPLACE FUNCTION iam.request_photo_feature_change(p_enabled boolean, p_legal_basis text, p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_uid uuid;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the photo policy is a platform task' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_policy_change (change_type, new_active, reason, legal_basis, requested_by_user_id, approval_stages)
  VALUES ('FEATURE_ENABLED', p_enabled, p_reason, p_legal_basis, sys.ctx_user_id(), iam.photo_approval_stages())
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- 3. applying an approved change: the switch joins the others (the body of 1091 with one more branch) ----------------
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

-- 4. the database refuses to take a photo while the switch is off (the body of 1086 with the gate) -----------------------
CREATE OR REPLACE FUNCTION iam.set_party_photo(p_party_id bigint, p_file_id bigint, p_user_id bigint)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_as text;
BEGIN
  IF NOT iam.photo_enabled() THEN
    RAISE EXCEPTION 'PHOTO_DISABLED: the boarding photo is not in use on this platform' USING ERRCODE = 'P0001';
  END IF;
  IF p_party_id = sys.ctx_party_id() THEN
    v_as := 'SELF';
  ELSIF EXISTS (SELECT 1 FROM iam.family f JOIN iam.family_member m ON m.family_id = f.id
                 WHERE f.head_party_id = sys.ctx_party_id() AND f.status = 'ACTIVE'
                   AND m.party_id = p_party_id AND m.status = 'ACTIVE') THEN
    v_as := 'HEAD_OF_FAMILY';
  ELSE
    RAISE EXCEPTION 'FORBIDDEN: only the person or the head of their family takes the photo' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM iam.party_photo WHERE party_id = p_party_id) THEN
    RAISE EXCEPTION 'PHOTO_EXISTS: a photo is on file and changes only through the platform' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.party_photo (party_id, file_id, taken_by, taken_by_user_id)
       VALUES (p_party_id, p_file_id, v_as, p_user_id);
  RETURN v_as;
END $$;

REVOKE ALL ON FUNCTION iam.photo_enabled() FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.request_photo_feature_change(boolean, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.photo_enabled() TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.request_photo_feature_change(boolean, text, text) TO masslak_app;

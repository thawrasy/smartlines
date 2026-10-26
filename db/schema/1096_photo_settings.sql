-- The rest of the photo's switches are platform settings, each changed through the approval stages of the photo policy
-- (owner's decision, October 2026): who may see the photo and when (the traveler on request; the driver and the carrier's
-- office only while the trip is boarding), when a photo becomes mandatory (from a date the platform sets; nothing is forced),
-- how often a person is verified, and which identity provider checks the person (none until one is connected).

-- 1. the settings, at their launch values ---------------------------------------------------------------------------------
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('photo.view_access', '{"TRAVELER": true, "DRIVER_AT_BOARDING": true, "CARRIER_OFFICE_AT_BOARDING": false, "AGENT": false}'::jsonb,
   'PLATFORM', 'Who may see the boarding photo: the traveler on request, the driver and the carrier office while the trip is boarding, an agent (1096)'),
  ('photo.verify_every_days', 'null'::jsonb, 'PLATFORM',
   'Days after which a person checks their identity again to keep the photo in use; null: no periodic check (1096)'),
  ('photo.enforce_from', 'null'::jsonb, 'PLATFORM',
   'The date from which the photo rules in force are enforced (a photo required by a rule is asked from then on); null: not enforced yet (1096)'),
  ('photo.identity_provider', '"NONE"'::jsonb, 'PLATFORM',
   'The identity verification provider that checks the person: NONE until a government digital identity system or a licensed provider is connected (1096)')
ON CONFLICT (key) DO NOTHING;

-- 2. reading a setting: only the photo's own keys ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iam.photo_setting(p_key text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT s.value FROM sys.setting s
   WHERE s.key = p_key
     AND p_key IN ('photo.view_access', 'photo.verify_every_days', 'photo.enforce_from', 'photo.identity_provider')
$$;

-- 3. the change: a setting, with its value checked here --------------------------------------------------------------------
ALTER TABLE iam.photo_policy_change ADD COLUMN IF NOT EXISTS setting_key text
  CHECK (setting_key IN ('photo.view_access', 'photo.verify_every_days', 'photo.enforce_from', 'photo.identity_provider'));
ALTER TABLE iam.photo_policy_change ADD COLUMN IF NOT EXISTS setting_value jsonb;
ALTER TABLE iam.photo_policy_change DROP CONSTRAINT IF EXISTS photo_policy_change_change_type_check;
ALTER TABLE iam.photo_policy_change ADD CONSTRAINT photo_policy_change_change_type_check
  CHECK (change_type IN ('EVIDENCE_KIND', 'IDENTITY_MIN_AGE', 'FIELD_REQUIREMENT', 'FEATURE_ENABLED', 'SETTING'));
ALTER TABLE iam.photo_policy_change DROP CONSTRAINT IF EXISTS photo_policy_change_shape_check;
ALTER TABLE iam.photo_policy_change ADD CONSTRAINT photo_policy_change_shape_check CHECK (
     (change_type = 'EVIDENCE_KIND' AND evidence_code IS NOT NULL AND new_active IS NOT NULL
        AND new_min_age IS NULL AND field_code IS NULL AND new_requirement IS NULL)
  OR (change_type = 'IDENTITY_MIN_AGE' AND evidence_code IS NULL AND new_active IS NULL
        AND field_code IS NULL AND new_requirement IS NULL)
  OR (change_type = 'FIELD_REQUIREMENT' AND field_code IS NOT NULL AND new_requirement IS NOT NULL
        AND evidence_code IS NULL AND new_active IS NULL AND new_min_age IS NULL)
  OR (change_type = 'FEATURE_ENABLED' AND new_active IS NOT NULL AND evidence_code IS NULL AND new_min_age IS NULL
        AND field_code IS NULL AND new_requirement IS NULL)
  OR (change_type = 'SETTING' AND setting_key IS NOT NULL AND setting_value IS NOT NULL AND evidence_code IS NULL
        AND new_active IS NULL AND new_min_age IS NULL AND field_code IS NULL AND new_requirement IS NULL));
ALTER TABLE iam.photo_policy_change DROP CONSTRAINT IF EXISTS photo_policy_change_setting_check;
ALTER TABLE iam.photo_policy_change ADD CONSTRAINT photo_policy_change_setting_check
  CHECK ((change_type = 'SETTING') = (setting_key IS NOT NULL));

CREATE OR REPLACE FUNCTION iam.request_photo_setting_change(p_key text, p_value jsonb, p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_uid uuid;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the photo policy is a platform task' USING ERRCODE = 'P0001';
  END IF;
  IF p_key = 'photo.view_access' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'INVALID_SETTING: the view access is an object of the four roles' USING ERRCODE = 'P0001';
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(p_value)) <> 4
       OR EXISTS (SELECT 1 FROM jsonb_each(p_value) e
                   WHERE e.key NOT IN ('TRAVELER', 'DRIVER_AT_BOARDING', 'CARRIER_OFFICE_AT_BOARDING', 'AGENT')
                      OR jsonb_typeof(e.value) IS DISTINCT FROM 'boolean') THEN
      RAISE EXCEPTION 'INVALID_SETTING: each of the four roles is true or false' USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_key = 'photo.verify_every_days' THEN
    IF p_value <> 'null'::jsonb AND (jsonb_typeof(p_value) IS DISTINCT FROM 'number'
       OR (p_value #>> '{}') !~ '^[0-9]+$' OR (p_value #>> '{}')::integer NOT BETWEEN 1 AND 365) THEN
      RAISE EXCEPTION 'INVALID_SETTING: the days are a whole number from 1 to 365, or null' USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_key = 'photo.enforce_from' THEN
    IF p_value <> 'null'::jsonb THEN
      IF jsonb_typeof(p_value) IS DISTINCT FROM 'string' OR (p_value #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RAISE EXCEPTION 'INVALID_SETTING: the date is YYYY-MM-DD, or null' USING ERRCODE = 'P0001';
      END IF;
      PERFORM (p_value #>> '{}')::date;
    END IF;
  ELSIF p_key = 'photo.identity_provider' THEN
    IF p_value IS DISTINCT FROM '"NONE"'::jsonb THEN
      RAISE EXCEPTION 'INVALID_SETTING: no identity provider is connected yet (NONE)' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    RAISE EXCEPTION 'INVALID_SETTING: not a photo setting' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_policy_change (change_type, setting_key, setting_value, reason, requested_by_user_id, approval_stages)
  VALUES ('SETTING', p_key, p_value, p_reason, sys.ctx_user_id(), iam.photo_approval_stages())
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- 4. the apply step: the setting joins the others (the body of 1095 with one more branch) ------------------------------
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
  ELSIF c.change_type = 'SETTING' THEN
    INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
    VALUES (c.setting_key, c.setting_value, 'PLATFORM', 'Set by an approved photo policy change (1096)', sys.ctx_user_id(), now())
    ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  ELSE
    UPDATE iam.data_requirement SET requirement = c.new_requirement, changed_by_user_id = sys.ctx_user_id(), changed_at = now()
     WHERE field_code = c.field_code;
  END IF;
  UPDATE iam.photo_policy_change SET status = 'APPLIED', decided_by_user_id = sys.ctx_user_id(), decided_at = now()
   WHERE id = c.id;
  RETURN 'APPLIED';
END $$;

REVOKE ALL ON FUNCTION iam.photo_setting(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.request_photo_setting_change(text, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.approve_photo_policy_change(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.photo_setting(text) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.request_photo_setting_change(text, jsonb, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.approve_photo_policy_change(uuid, text) TO masslak_app;

-- 5. the JSON of the new value: its shape is checked by the request, by key (the contract keeps the column to JSON values)
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('iam.photo_policy_change', 'setting_value', 'CONFIG', 1,
   '{"type": ["object", "array", "string", "number", "boolean", "null"]}'::jsonb,
   'the new value of a photo setting, checked for its key when it is asked (1096)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();

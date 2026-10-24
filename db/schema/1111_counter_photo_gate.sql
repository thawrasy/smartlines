-- =====================================================================
-- Masslak - 1111: the boarding photo at a station counter stays off until a legal and legislative approval allows it
-- (owner's decision, October 2026; build step 5)
--
-- The photo's view access (1096) gains a fifth role, STATION_COUNTER_AT_CHECKIN: the clerk of a station's operating
-- company sees the passenger's photo while checking the ticket in. It is off at launch, and it is not turned on from the
-- platform until the competent authorities approve showing it: like every photo setting it passes the approval stages,
-- and the change that turns it on is applied only with the approval's legal document number recorded. While it is off,
-- the counter's photo route answers PHOTO_VIEW_NOT_ALLOWED and nothing is shown.
-- =====================================================================

UPDATE sys.setting SET value = value || '{"STATION_COUNTER_AT_CHECKIN": false}'::jsonb,
       description = 'Who may see the boarding photo: the traveler on request, the driver and the carrier office while the trip is boarding, an agent, a station counter at check-in under a legal approval (1096, 1111)'
 WHERE key = 'photo.view_access' AND NOT value ? 'STATION_COUNTER_AT_CHECKIN';

CREATE OR REPLACE FUNCTION iam.request_photo_setting_change(p_key text, p_value jsonb, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
DECLARE v_uid uuid;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the photo policy is a platform task' USING ERRCODE = 'P0001';
  END IF;
  IF p_key = 'photo.view_access' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'INVALID_SETTING: the view access is an object of the five roles' USING ERRCODE = 'P0001';
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(p_value)) <> 5
       OR EXISTS (SELECT 1 FROM jsonb_each(p_value) e
                   WHERE e.key NOT IN ('TRAVELER', 'DRIVER_AT_BOARDING', 'CARRIER_OFFICE_AT_BOARDING', 'AGENT', 'STATION_COUNTER_AT_CHECKIN')
                      OR jsonb_typeof(e.value) IS DISTINCT FROM 'boolean') THEN
      RAISE EXCEPTION 'INVALID_SETTING: each of the five roles is true or false' USING ERRCODE = 'P0001';
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
END $function$;

CREATE OR REPLACE FUNCTION iam.approve_photo_policy_change(p_uid uuid, p_document text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
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
    -- the photo at a station counter is shown only under a legal and legislative approval, whose document number is
    -- recorded with the approval (owner's decision, October 2026): without it the change is not applied
    IF c.setting_key = 'photo.view_access' AND coalesce((c.setting_value ->> 'STATION_COUNTER_AT_CHECKIN')::boolean, false)
       AND NOT coalesce((iam.photo_setting('photo.view_access') ->> 'STATION_COUNTER_AT_CHECKIN')::boolean, false)
       AND (SELECT legal_document_no FROM iam.photo_policy_change WHERE id = c.id) IS NULL THEN
      RAISE EXCEPTION 'LEGAL_BASIS_REQUIRED: the photo at a station counter is shown only under the legal approval that allows it; give its document number with the approval' USING ERRCODE = 'P0001';
    END IF;
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
END $function$;

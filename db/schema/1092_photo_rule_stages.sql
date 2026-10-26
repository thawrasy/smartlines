-- =====================================================================
-- Masslak - 1092: the approval stages apply to the photo rules (WP1; the ninth round, 11 October 2026)
--
-- A rule that requires a boarding photo is proposed by one platform person and goes through the stages of the platform's
-- settings (photo.approval_stages: by default a checker, then a final approval by a second person) before it is in force.
-- A proposal can be withdrawn by any platform person, which ends it without affecting anything. A rule in force is
-- retired through the same stages; until the last stage is recorded it stays in force, so a retirement that is not yet
-- approved does not relax the rule. The person who gave the final approval of a rule does not approve its retirement, and
-- the one who asks for a retirement does not approve it either.
--
-- A retirement has its own approval subject (a retirement request id from a sequence), so the approvals of a retirement
-- that was rejected do not count for a later one. The approvals table takes the two new subjects, and the registry and the
-- JSON contracts know the new columns (audit R-03, R-08).
-- =====================================================================

-- 1. the status and the stages of a rule ------------------------------------------------------------------------------
ALTER TABLE iam.photo_rule DROP CONSTRAINT photo_rule_status_check;
ALTER TABLE iam.photo_rule ADD CONSTRAINT photo_rule_status_check
  CHECK (status IN ('PROPOSED', 'APPROVED', 'RETIRING', 'RETIRED'));
ALTER TABLE iam.photo_rule ADD COLUMN IF NOT EXISTS approval_stages jsonb NOT NULL DEFAULT '["CHECK","APPROVE"]'::jsonb
  CHECK (jsonb_typeof(approval_stages) = 'array' AND jsonb_array_length(approval_stages) >= 2);
ALTER TABLE iam.photo_rule ADD COLUMN IF NOT EXISTS retirement_request_id bigint;
ALTER TABLE iam.photo_rule ADD COLUMN IF NOT EXISTS retirement_requested_by_user_id bigint REFERENCES iam.app_user (id);
ALTER TABLE iam.photo_rule ADD COLUMN IF NOT EXISTS retirement_reason text
  CHECK (retirement_reason IS NULL OR length(retirement_reason) BETWEEN 10 AND 500);
ALTER TABLE iam.photo_rule ADD COLUMN IF NOT EXISTS retirement_stages jsonb
  CHECK (retirement_stages IS NULL OR (jsonb_typeof(retirement_stages) = 'array' AND jsonb_array_length(retirement_stages) >= 2));
ALTER TABLE iam.photo_rule ADD COLUMN IF NOT EXISTS retirement_requested_at timestamptz;
COMMENT ON COLUMN iam.photo_rule.retirement_request_id IS 'No FK: a value of iam.photo_rule_retirement_seq, one per retirement request; the approvals of the retirement refer to it (1092)';
ALTER TABLE iam.photo_rule ADD CONSTRAINT photo_rule_retirement_check CHECK (
  status <> 'RETIRING' OR (retirement_request_id IS NOT NULL AND retirement_requested_by_user_id IS NOT NULL
                           AND retirement_reason IS NOT NULL AND retirement_stages IS NOT NULL));
CREATE INDEX IF NOT EXISTS photo_rule_retirement_requested_by_user_id_fkx ON iam.photo_rule (retirement_requested_by_user_id);
CREATE SEQUENCE IF NOT EXISTS iam.photo_rule_retirement_seq;

-- 2. the approvals take the two new subjects ----------------------------------------------------------------------------
ALTER TABLE iam.photo_approval DROP CONSTRAINT photo_approval_subject_type_check;
ALTER TABLE iam.photo_approval ADD CONSTRAINT photo_approval_subject_type_check
  CHECK (subject_type IN ('CHANGE_REQUEST', 'POLICY_CHANGE', 'RULE', 'RULE_RETIREMENT'));
UPDATE sys.polymorphic_reference SET targets = '{"CHANGE_REQUEST": "iam.photo_change_request", "POLICY_CHANGE": "iam.photo_policy_change", "RULE": "iam.photo_rule", "RULE_RETIREMENT": "iam.photo_rule"}'::jsonb
 WHERE table_name = 'iam.photo_approval' AND type_col = 'subject_type';
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('iam.photo_rule', 'approval_stages', 'CONFIG', 1,
   '{"type": "array", "minItems": 2, "items": {"enum": ["CHECK", "THIRD_PARTY_CHECK", "APPROVE"]}}'::jsonb,
   'the approval stages of a photo rule, frozen when it is proposed (1092)'),
  ('iam.photo_rule', 'retirement_stages', 'CONFIG', 1,
   '{"type": "array", "minItems": 2, "items": {"enum": ["CHECK", "THIRD_PARTY_CHECK", "APPROVE"]}}'::jsonb,
   'the approval stages of the retirement of a photo rule, frozen when it is requested (1092)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();

-- 3. the requirement in force: a rule being retired stays in force until its retirement is approved --------------------
CREATE OR REPLACE FUNCTION iam.photo_requirement(p_market char, p_trip_scope text, p_traveller_class text,
                                                  p_category text, p_on date DEFAULT current_date) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((
    SELECT r.requirement FROM iam.photo_rule r
     WHERE r.status IN ('APPROVED', 'RETIRING')
       AND (r.market IS NULL OR r.market = p_market)
       AND (r.trip_scope IS NULL OR r.trip_scope = p_trip_scope)
       AND (r.traveller_class IS NULL OR r.traveller_class = p_traveller_class)
       AND (r.passenger_category IS NULL OR r.passenger_category = p_category)
       AND r.effective_from <= p_on AND (r.effective_to IS NULL OR r.effective_to > p_on)
     ORDER BY ((r.market IS NOT NULL)::int + (r.trip_scope IS NOT NULL)::int
               + (r.traveller_class IS NOT NULL)::int + (r.passenger_category IS NOT NULL)::int) DESC,
              r.effective_from DESC, r.id DESC
     LIMIT 1), 'OPTIONAL')
$$;

-- 4. the proposal takes the stages in force -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iam.propose_photo_rule(p_market char, p_trip_scope text, p_traveller_class text, p_category text,
    p_requirement text, p_effective_from date, p_legal_basis text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_uid uuid;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: photo rules are a platform task' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_rule (market, trip_scope, traveller_class, passenger_category, requirement, effective_from,
                              legal_basis, proposed_by_user_id, approval_stages)
  VALUES (p_market, p_trip_scope, p_traveller_class, p_category, p_requirement, p_effective_from, p_legal_basis,
          sys.ctx_user_id(), iam.photo_approval_stages())
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- 5. the stages of a proposal: it is in force when the last stage is recorded ---------------------------------------
DROP FUNCTION IF EXISTS iam.approve_photo_rule(uuid);
CREATE FUNCTION iam.approve_photo_rule(p_uid uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r iam.photo_rule; v_step integer;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: photo rules are a platform task' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM iam.photo_rule WHERE uid = p_uid AND status = 'PROPOSED' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_PROPOSED: the rule is not waiting for approval' USING ERRCODE = 'P0001';
  END IF;
  v_step := iam.record_photo_approval('RULE', r.id, r.proposed_by_user_id, r.approval_stages);
  IF v_step < jsonb_array_length(r.approval_stages) THEN
    RETURN 'PENDING';
  END IF;
  UPDATE iam.photo_rule SET status = 'APPROVED', approved_by_user_id = sys.ctx_user_id(), approved_at = now()
   WHERE id = r.id;
  RETURN 'APPROVED';
END $$;

-- a proposal withdrawn by a platform person: it never comes into force, so nothing is relaxed
DROP FUNCTION IF EXISTS iam.retire_photo_rule(uuid);
CREATE OR REPLACE FUNCTION iam.withdraw_photo_rule(p_uid uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: photo rules are a platform task' USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.photo_rule SET status = 'RETIRED', retired_by_user_id = sys.ctx_user_id(), retired_at = now()
   WHERE uid = p_uid AND status = 'PROPOSED';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_PROPOSED: only a proposal that is not yet in force is withdrawn' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- 6. the retirement of a rule in force, through its own stages --------------------------------------------------------
CREATE OR REPLACE FUNCTION iam.request_photo_rule_retirement(p_uid uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: photo rules are a platform task' USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.photo_rule SET status = 'RETIRING', retirement_request_id = nextval('iam.photo_rule_retirement_seq'),
         retirement_requested_by_user_id = sys.ctx_user_id(), retirement_reason = p_reason,
         retirement_stages = iam.photo_approval_stages(), retirement_requested_at = now()
   WHERE uid = p_uid AND status = 'APPROVED';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_APPROVED: only a rule in force is retired, through its stages' USING ERRCODE = 'P0001';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION iam.approve_photo_rule_retirement(p_uid uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r iam.photo_rule; v_step integer;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: photo rules are a platform task' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM iam.photo_rule WHERE uid = p_uid AND status = 'RETIRING' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_PENDING: the retirement is not waiting for approval' USING ERRCODE = 'P0001';
  END IF;
  IF sys.ctx_user_id() = r.approved_by_user_id THEN
    RAISE EXCEPTION 'FOUR_EYES: the person who gave the final approval of the rule does not retire it' USING ERRCODE = 'P0001';
  END IF;
  v_step := iam.record_photo_approval('RULE_RETIREMENT', r.retirement_request_id, r.retirement_requested_by_user_id, r.retirement_stages);
  IF v_step < jsonb_array_length(r.retirement_stages) THEN
    RETURN 'PENDING';
  END IF;
  UPDATE iam.photo_rule SET status = 'RETIRED', retired_by_user_id = sys.ctx_user_id(), retired_at = now() WHERE id = r.id;
  RETURN 'RETIRED';
END $$;

-- a retirement that is turned down: the rule stays in force, as approved
CREATE OR REPLACE FUNCTION iam.reject_photo_rule_retirement(p_uid uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: photo rules are a platform task' USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.photo_rule SET status = 'APPROVED' WHERE uid = p_uid AND status = 'RETIRING';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_PENDING: the retirement is not waiting for a decision' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- 7. grants of the functions the application calls -------------------------------------------------------------------
REVOKE ALL ON FUNCTION iam.approve_photo_rule(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.withdraw_photo_rule(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.request_photo_rule_retirement(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.approve_photo_rule_retirement(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.reject_photo_rule_retirement(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.approve_photo_rule(uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.withdraw_photo_rule(uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.request_photo_rule_retirement(uuid, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.approve_photo_rule_retirement(uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.reject_photo_rule_retirement(uuid) TO masslak_app;

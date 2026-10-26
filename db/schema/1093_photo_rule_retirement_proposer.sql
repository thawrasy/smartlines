-- =====================================================================
-- Masslak - 1093: the person who proposed a photo rule does not approve its retirement (the tenth round, owner's answer)
--
-- The owner's decision: a retirement of a rule in force is approved by people who did not propose the rule, did not give
-- it its final approval, and did not ask for the retirement. The proposer may ask for the retirement; they do not approve
-- it. The check is in the function, and the API answers first with the same code.
-- =====================================================================

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
  IF sys.ctx_user_id() = r.proposed_by_user_id THEN
    RAISE EXCEPTION 'FOUR_EYES: the person who proposed the rule does not approve its retirement' USING ERRCODE = 'P0001';
  END IF;
  v_step := iam.record_photo_approval('RULE_RETIREMENT', r.retirement_request_id, r.retirement_requested_by_user_id, r.retirement_stages);
  IF v_step < jsonb_array_length(r.retirement_stages) THEN
    RETURN 'PENDING';
  END IF;
  UPDATE iam.photo_rule SET status = 'RETIRED', retired_by_user_id = sys.ctx_user_id(), retired_at = now() WHERE id = r.id;
  RETURN 'RETIRED';
END $$;

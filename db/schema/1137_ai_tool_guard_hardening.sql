-- =====================================================================
-- 1137: the AI assistant's tool guard, hardened (independent review of 18 October 2026, plan item B2)
--   Widening the injection test set to tool arguments, units and the policy itself found four gaps in 1134:
--     * a limit written as text ("max_amount": "100") was not a number, so it was silently not applied;
--     * an amount of zero or less passed the amount limit;
--     * an amount in another currency than the policy's passed it (a limit in pounds is not a limit in dollars);
--     * a closed conversation could be opened again by clearing ended_at, and its tools would run;
--     * a request with no conversation, or one that does not exist, failed on a constraint instead of a clear refusal.
--   Now the policy's limits must be well-formed numbers (and a currency code), an amount must be above zero and in the
--   policy's currency when it names one, and a conversation once ended stays ended.
-- =====================================================================

ALTER TABLE crm.ai_policy DROP CONSTRAINT IF EXISTS ai_policy_limits_ck;
ALTER TABLE crm.ai_policy ADD CONSTRAINT ai_policy_limits_ck CHECK (
  jsonb_typeof(limits) = 'object'
  AND (NOT limits ? 'max_amount'
       OR (jsonb_typeof(limits -> 'max_amount') = 'number' AND (limits ->> 'max_amount')::numeric > 0))
  AND (NOT limits ? 'max_calls_per_conversation'
       OR (jsonb_typeof(limits -> 'max_calls_per_conversation') = 'number'
           AND (limits ->> 'max_calls_per_conversation')::numeric >= 0
           AND (limits ->> 'max_calls_per_conversation')::numeric = trunc((limits ->> 'max_calls_per_conversation')::numeric)))
  AND (NOT limits ? 'currency' OR (jsonb_typeof(limits -> 'currency') = 'string' AND limits ->> 'currency' ~ '^[A-Z]{3}$')));
COMMENT ON CONSTRAINT ai_policy_limits_ck ON crm.ai_policy IS
  'Limits the guard can apply: max_amount a number above zero, max_calls_per_conversation a whole number, currency an ISO code (1137)';

CREATE OR REPLACE FUNCTION crm.ai_tool_refusal(p_conversation bigint, p_tool text, p_args jsonb, p_confirmed boolean)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE pol crm.ai_policy; conv crm.ai_conversation; calls int; amount numeric;
BEGIN
  SELECT * INTO pol FROM crm.ai_policy WHERE tool = p_tool;
  SELECT * INTO conv FROM crm.ai_conversation WHERE id = p_conversation;
  IF NOT sys.feature_on(ARRAY['ai_assistant']) THEN RETURN 'ASSISTANT_OFF'; END IF;
  IF NOT coalesce(pol.enabled, false) THEN RETURN 'TOOL_DISABLED'; END IF;
  IF pol.requires_confirmation AND NOT coalesce(p_confirmed, false) THEN RETURN 'NOT_CONFIRMED'; END IF;
  IF conv.id IS NULL OR conv.ended_at IS NOT NULL THEN RETURN 'CONVERSATION_CLOSED'; END IF;
  IF jsonb_typeof(pol.limits -> 'max_calls_per_conversation') = 'number' THEN
    SELECT count(*) INTO calls FROM crm.ai_tool_call
     WHERE conversation_id = p_conversation AND tool = p_tool AND result_status = 'OK';
    IF calls >= (pol.limits ->> 'max_calls_per_conversation')::int THEN RETURN 'CALL_LIMIT'; END IF;
  END IF;
  IF jsonb_typeof(pol.limits -> 'max_amount') = 'number' THEN
    amount := CASE WHEN jsonb_typeof(p_args -> 'amount') = 'number' THEN (p_args ->> 'amount')::numeric END;
    -- an amount the tool cannot read, of zero or less, or above the limit is refused: the limit cannot be held otherwise
    IF amount IS NULL OR amount <= 0 OR amount > (pol.limits ->> 'max_amount')::numeric THEN RETURN 'AMOUNT_LIMIT'; END IF;
    -- a limit in one currency says nothing of an amount in another (1137)
    IF pol.limits ? 'currency' AND (p_args ->> 'currency') IS DISTINCT FROM (pol.limits ->> 'currency') THEN
      RETURN 'AMOUNT_LIMIT';
    END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION crm.ai_tool_refusal(bigint, text, jsonb, boolean) FROM PUBLIC;

-- a request must name a conversation that exists: refused with its own code, before anything is recorded
CREATE OR REPLACE FUNCTION crm.ai_authorize_tool(p_conversation bigint, p_tool text, p_args jsonb, p_confirmed boolean)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE pol crm.ai_policy; why text; v_id bigint;
BEGIN
  SELECT * INTO pol FROM crm.ai_policy WHERE tool = p_tool;
  IF pol.tool IS NULL THEN
    RAISE EXCEPTION 'AI_TOOL_UNKNOWN: the assistant has no tool %', left(p_tool, 60);
  END IF;
  -- one request at a time per conversation, so two cannot both pass a call limit
  PERFORM 1 FROM crm.ai_conversation WHERE id = p_conversation FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI_CONVERSATION_UNKNOWN: no conversation %', p_conversation;
  END IF;
  why := crm.ai_tool_refusal(p_conversation, p_tool, p_args, p_confirmed);
  INSERT INTO crm.ai_tool_call (conversation_id, tool, args_redacted, action_level, confirmed_by_user, result_status, refusal)
  VALUES (p_conversation, p_tool, coalesce(p_args, '{}'::jsonb), pol.action_level, coalesce(p_confirmed, false),
          CASE WHEN why IS NULL THEN 'OK' ELSE 'DENIED' END, why)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('allowed', why IS NULL, 'refusal', why, 'call_id', v_id, 'action_level', pol.action_level);
END $$;
REVOKE ALL ON FUNCTION crm.ai_authorize_tool(bigint, text, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.ai_authorize_tool(bigint, text, jsonb, boolean) TO masslak_app;

-- a conversation once ended stays ended: its tools never run again
CREATE OR REPLACE FUNCTION crm.tg_ai_conversation_ended() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF OLD.ended_at IS NOT NULL AND NEW.ended_at IS DISTINCT FROM OLD.ended_at THEN
    RAISE EXCEPTION 'AI_CONVERSATION_ENDED: conversation % ended at %', OLD.id, OLD.ended_at;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION crm.tg_ai_conversation_ended() FROM PUBLIC;
DROP TRIGGER IF EXISTS b_ai_conversation_ended ON crm.ai_conversation;
CREATE TRIGGER b_ai_conversation_ended BEFORE UPDATE OF ended_at ON crm.ai_conversation
  FOR EACH ROW EXECUTE FUNCTION crm.tg_ai_conversation_ended();

SELECT sys.refresh_table_class();

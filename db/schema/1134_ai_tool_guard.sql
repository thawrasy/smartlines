-- =====================================================================
-- 1134: the AI assistant's tools are authorised by the database, whatever the model says (systems review of study 3.8,
-- October 2026, R-14; launch gate 9)
--   The assistant (phase CS, closed until its data protection review is approved, 1055) will act only through the tools
--   of crm.ai_policy. A prompt injection, in a message or in text a tool returns, can make a model ask for any tool with
--   any arguments. So the decision is not the model's: before a tool runs, crm.ai_authorize_tool records the request
--   and allows it only when
--     * the assistant switch is on (the kill switch: turning ai_assistant off stops every tool at once);
--     * the tool exists in the policy and is enabled;
--     * the traveller confirmed it, where the policy asks for confirmation;
--     * the conversation is open and the tool's limits hold (max_calls_per_conversation, max_amount).
--   A refused request is kept as DENIED with its reason (append-only, 090), so attempts can be counted and reviewed.
--   A row written as OK by any other path is checked the same way and refused (backstop).
--   The test set in db/tests (block 1134) assumes a model that obeys every injected instruction.
-- =====================================================================

ALTER TABLE crm.ai_tool_call ADD COLUMN IF NOT EXISTS refusal text
  CHECK (refusal IN ('ASSISTANT_OFF', 'TOOL_DISABLED', 'NOT_CONFIRMED', 'CONVERSATION_CLOSED', 'CALL_LIMIT', 'AMOUNT_LIMIT'));
COMMENT ON COLUMN crm.ai_tool_call.refusal IS 'Why the database refused the tool (result DENIED); null when it was allowed (1134)';
ALTER TABLE crm.ai_tool_call DROP CONSTRAINT IF EXISTS ai_tool_call_refusal_ck;
ALTER TABLE crm.ai_tool_call ADD CONSTRAINT ai_tool_call_refusal_ck CHECK (refusal IS NULL OR result_status = 'DENIED');

-- why a tool may not run now (null: it may)
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
    -- an amount the tool cannot read is refused as well: the limit cannot be checked
    IF amount IS NULL OR amount > (pol.limits ->> 'max_amount')::numeric THEN RETURN 'AMOUNT_LIMIT'; END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION crm.ai_tool_refusal(bigint, text, jsonb, boolean) FROM PUBLIC;
COMMENT ON FUNCTION crm.ai_tool_refusal IS 'Why the assistant may not run this tool now, or null (1134)';

-- the only way a tool is allowed: records the request and answers whether it may run
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
  why := crm.ai_tool_refusal(p_conversation, p_tool, p_args, p_confirmed);
  INSERT INTO crm.ai_tool_call (conversation_id, tool, args_redacted, action_level, confirmed_by_user, result_status, refusal)
  VALUES (p_conversation, p_tool, coalesce(p_args, '{}'::jsonb), pol.action_level, coalesce(p_confirmed, false),
          CASE WHEN why IS NULL THEN 'OK' ELSE 'DENIED' END, why)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('allowed', why IS NULL, 'refusal', why, 'call_id', v_id, 'action_level', pol.action_level);
END $$;
REVOKE ALL ON FUNCTION crm.ai_authorize_tool(bigint, text, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.ai_authorize_tool(bigint, text, jsonb, boolean) TO masslak_app;
COMMENT ON FUNCTION crm.ai_authorize_tool IS 'Records an assistant tool request and allows it only within the policy and the kill switch (1134)';

-- backstop: a row written as allowed by any other path holds to the same rules, at the policy's own level
CREATE OR REPLACE FUNCTION crm.tg_ai_tool_call_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE why text; lvl smallint;
BEGIN
  IF NEW.result_status <> 'OK' THEN
    RETURN NEW;
  END IF;
  SELECT action_level INTO lvl FROM crm.ai_policy WHERE tool = NEW.tool;
  IF NEW.action_level IS DISTINCT FROM lvl THEN
    RAISE EXCEPTION 'AI_TOOL_REFUSED: % runs at action level %, not %', NEW.tool, lvl, NEW.action_level;
  END IF;
  why := crm.ai_tool_refusal(NEW.conversation_id, NEW.tool, NEW.args_redacted, NEW.confirmed_by_user);
  IF why IS NOT NULL THEN
    RAISE EXCEPTION 'AI_TOOL_REFUSED: % (%)', NEW.tool, why;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_ai_tool_call_guard ON crm.ai_tool_call;
CREATE TRIGGER b_ai_tool_call_guard BEFORE INSERT ON crm.ai_tool_call FOR EACH ROW EXECUTE FUNCTION crm.tg_ai_tool_call_guard();

SELECT sys.refresh_table_class();

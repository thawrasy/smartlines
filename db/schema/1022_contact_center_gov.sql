-- =====================================================================
-- 1022: AI-first contact center (study 7.11) and government integration adapters (4.10, phase 5)
--   Calls handled by the AI assistant or an agent with warm transfer, call events, callbacks, queues, agents and
--   skills, quality scoring and the assistant's evaluation set; government adapter configuration and the
--   verification jobs sent through it.
-- =====================================================================

CREATE TABLE IF NOT EXISTS crm.call_queue (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code            text NOT NULL UNIQUE,
  name            text NOT NULL,
  channel         text NOT NULL DEFAULT 'VOICE' CHECK (channel IN ('VOICE','WHATSAPP','CHAT')),
  sla_target_sec  int NOT NULL DEFAULT 60 CHECK (sla_target_sec > 0),
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CLOSED'))
);
CREATE TABLE IF NOT EXISTS crm.call_skill (
  code  text PRIMARY KEY,
  name  text NOT NULL
);
CREATE TABLE IF NOT EXISTS crm.call_agent (
  id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id  bigint NOT NULL UNIQUE REFERENCES iam.app_user(id),
  shift    jsonb NOT NULL DEFAULT '{}',
  status   text NOT NULL DEFAULT 'OFFLINE' CHECK (status IN ('AVAILABLE','BUSY','BREAK','OFFLINE'))
);
CREATE TABLE IF NOT EXISTS crm.call_agent_skill (
  agent_id    bigint NOT NULL REFERENCES crm.call_agent(id) ON DELETE CASCADE,
  skill_code  text NOT NULL REFERENCES crm.call_skill(code),
  level       smallint NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 5),
  PRIMARY KEY (agent_id, skill_code)
);
CREATE TABLE IF NOT EXISTS crm.call_queue_skill (
  queue_id    bigint NOT NULL REFERENCES crm.call_queue(id) ON DELETE CASCADE,
  skill_code  text NOT NULL REFERENCES crm.call_skill(code),
  PRIMARY KEY (queue_id, skill_code)
);

CREATE TABLE IF NOT EXISTS crm.call (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  direction           text NOT NULL CHECK (direction IN ('INBOUND','OUTBOUND')),
  caller_hash         bytea NOT NULL,                                -- never the raw number
  line_ref            text,
  queue_id            bigint REFERENCES crm.call_queue(id),
  party_id            bigint REFERENCES iam.party(id),
  company_id          bigint REFERENCES iam.company(id),             -- caller's company when a carrier calls
  case_id             bigint REFERENCES crm.case(id),
  ai_conversation_id  bigint REFERENCES crm.ai_conversation(id),
  agent_id            bigint REFERENCES crm.call_agent(id),
  handled_by          text CHECK (handled_by IN ('AI','AGENT')),
  state               text NOT NULL DEFAULT 'RINGING' CHECK (state IN ('RINGING','AI_HANDLING','QUEUED','AGENT_HANDLING','ENDED')),
  started_at          timestamptz NOT NULL DEFAULT now(),
  answered_at         timestamptz,
  ended_at            timestamptz,
  outcome             text CHECK (outcome IN ('RESOLVED','TRANSFERRED','CALLBACK','ABANDONED','CASE_OPENED')),
  recording_file_id   bigint REFERENCES ref.file_object(id),
  transcript_file_id  bigint REFERENCES ref.file_object(id),
  csat                smallint CHECK (csat BETWEEN 1 AND 5),
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX IF NOT EXISTS call_started_idx ON crm.call (started_at);
COMMENT ON TABLE crm.call IS 'Every call: AI first, warm transfer to an agent when needed (7.11)';

CREATE TABLE IF NOT EXISTS crm.call_event (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  call_id          bigint NOT NULL REFERENCES crm.call(id),
  ts               timestamptz NOT NULL DEFAULT now(),
  kind             text NOT NULL CHECK (kind IN ('IVR','AI_TURN','TOOL_CALL','TRANSFER','HOLD','RESUME','END')),
  detail_redacted  jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS call_event_call_idx ON crm.call_event (call_id, ts);

CREATE TABLE IF NOT EXISTS crm.callback_request (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  call_id            bigint REFERENCES crm.call(id),
  phone_hash         bytea NOT NULL,
  reason             text NOT NULL,
  due_at             timestamptz NOT NULL,
  assigned_agent_id  bigint REFERENCES crm.call_agent(id),
  status             text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','DONE','FAILED','CANCELLED'))
);

CREATE TABLE IF NOT EXISTS crm.call_qa (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  call_id         bigint NOT NULL REFERENCES crm.call(id),
  scorer          text NOT NULL CHECK (scorer IN ('AI','HUMAN')),
  scorer_user_id  bigint REFERENCES iam.app_user(id),
  score           numeric(5,2) NOT NULL CHECK (score BETWEEN 0 AND 100),
  flags           text[] NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (scorer = 'AI' OR scorer_user_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS crm.ai_eval_case (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  lang_dialect  text NOT NULL,                                       -- e.g. ar-SY, ar-LB, en
  input         text NOT NULL,
  expected      text NOT NULL,
  last_result   text CHECK (last_result IN ('PASS','FAIL','PARTIAL')),
  last_run_at   timestamptz,
  active        boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE crm.ai_eval_case IS 'Test set of the assistant per dialect, run before each model or policy change';

-- ------------------------------ government integration (phase 5) ------------------------------
CREATE TABLE IF NOT EXISTS sec.gov_adapter_config (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  authority_id  bigint NOT NULL REFERENCES sec.authority_profile(id),
  adapter_type  text NOT NULL CHECK (adapter_type IN ('CIVIL_REGISTRY','VEHICLE_REGISTRY','DRIVING_LICENSE','TAX','COMMERCIAL_REGISTRY','DIGITAL_ID')),
  endpoint      text NOT NULL,
  protocol      text NOT NULL CHECK (protocol IN ('REST','SOAP','X_ROAD','SFTP')),
  cert_ref      text,
  mapping       jsonb NOT NULL DEFAULT '{}',
  timeout_ms    int NOT NULL DEFAULT 5000,
  status        text NOT NULL DEFAULT 'TESTING' CHECK (status IN ('TESTING','ACTIVE','SUSPENDED')),
  UNIQUE (authority_id, adapter_type)
);
COMMENT ON TABLE sec.gov_adapter_config IS 'Adapter to a government registry; field mapping changes by configuration (phase 5)';

CREATE TABLE IF NOT EXISTS sec.verification_job (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  adapter_id       bigint NOT NULL REFERENCES sec.gov_adapter_config(id),
  verification_id  bigint REFERENCES iam.verification(id),
  subject_type     text NOT NULL CHECK (subject_type IN ('PARTY','VEHICLE','LICENSE','COMPANY','DOCUMENT')),
  subject_id       bigint NOT NULL,
  request_ref      text,
  status           text NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','SENT','MATCHED','MISMATCH','NOT_FOUND','FAILED')),
  attempts         int NOT NULL DEFAULT 0,
  result           jsonb,
  requested_at     timestamptz NOT NULL DEFAULT now(),
  completed_at     timestamptz
);
CREATE INDEX IF NOT EXISTS verification_job_subject_idx ON sec.verification_job (subject_type, subject_id);

-- ------------------------------ isolation and privileges ------------------------------
DO $$ BEGIN
  PERFORM sys.rls_platform(t) FROM unnest(ARRAY['crm.call_queue','crm.call_skill','crm.call_agent','crm.call_agent_skill',
    'crm.call_queue_skill','crm.callback_request','crm.call_qa','crm.ai_eval_case','sec.gov_adapter_config','sec.verification_job']) t;
  -- a carrier sees calls its staff made; recordings and transcripts stay behind the platform's access controls
  PERFORM sys.rls('crm.call', 'sys.ctx_is_platform() OR (company_id IS NOT NULL AND company_id = sys.ctx_company_id())', 'sys.ctx_is_platform()');
  PERFORM sys.rls_parent('crm.call_event', 'call_id', 'crm.call');
  PERFORM sys.grant_rw(ARRAY['crm.call_queue','crm.call_skill','crm.call_agent','crm.call_agent_skill','crm.call_queue_skill',
    'crm.call','crm.callback_request','crm.call_qa','crm.ai_eval_case','sec.gov_adapter_config','sec.verification_job']);
  PERFORM sys.grant_append(ARRAY['crm.call_event']);
END $$;
GRANT SELECT ON sec.gov_adapter_config, sec.verification_job TO masslak_auditor;

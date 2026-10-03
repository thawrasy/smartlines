-- =====================================================================
-- 090: complaints, claims, ratings, notifications and the AI assistant (crm)
--      and governance: policy authority matrix, legal obligations, data protection (gov)
-- Source: 7.6, 7.7, 7.10, 2.5, 16.13, 16.24, 34
-- =====================================================================

-- ============================== crm ==================================
CREATE TABLE crm.case (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  ref               text NOT NULL UNIQUE,
  kind              text NOT NULL CHECK (kind IN ('COMPLAINT','CLAIM','INQUIRY')),
  category          text NOT NULL,
  priority          text NOT NULL DEFAULT 'NORMAL' CHECK (priority IN ('LOW','NORMAL','HIGH','CRITICAL')),
  status            text NOT NULL DEFAULT 'NEW' CHECK (status IN ('NEW','OPEN','WAITING','RESOLVED','CLOSED','REJECTED')),
  channel           text NOT NULL DEFAULT 'APP' CHECK (channel IN ('APP','WEB','CALL','WHATSAPP','EMAIL','AI_ASSISTANT','OPERATOR')),
  subject           text NOT NULL,
  description       text,
  party_id          bigint REFERENCES iam.party(id),
  booking_id        bigint REFERENCES sales.booking(id),
  trip_id           bigint REFERENCES ops.trip(id),
  company_id        bigint REFERENCES iam.company(id),
  assigned_to       bigint REFERENCES iam.app_user(id),
  first_due_at      timestamptz,
  resolve_due_at    timestamptz,
  first_response_at timestamptz,
  resolved_at       timestamptz,
  sla_breached      boolean NOT NULL DEFAULT false,
  resolution        text,
  claim_amount      bigint,
  approved_amount   bigint,
  liable            text CHECK (liable IN ('CARRIER','PLATFORM','PARTNER','NONE')),
  payout_status     text NOT NULL DEFAULT 'NONE' CHECK (payout_status IN ('NONE','PENDING_FINANCE','PAID')),
  payout_ledger_txn_id bigint REFERENCES fin.ledger_txn(id),
  csat              smallint CHECK (csat BETWEEN 1 AND 5),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX case_open_idx ON crm.case (status, resolve_due_at) WHERE status IN ('NEW','OPEN','WAITING');
CREATE TRIGGER case_updated BEFORE UPDATE ON crm.case FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE crm.case IS 'Complaint, claim or inquiry with service levels, compensation and segregation of duties (7.6)';

CREATE TABLE crm.case_event (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id     bigint NOT NULL REFERENCES crm.case(id),
  actor_id    bigint REFERENCES iam.app_user(id),
  actor_role  text NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('NOTE','REPLY','STATUS','ASSIGN','ATTACHMENT','DECISION')),
  visibility  text NOT NULL DEFAULT 'PUBLIC' CHECK (visibility IN ('PUBLIC','INTERNAL')),
  body        text,
  file_id     bigint REFERENCES ref.file_object(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER case_event_immutable BEFORE UPDATE OR DELETE ON crm.case_event FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

CREATE TABLE crm.trip_rating (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ticket_id   bigint NOT NULL UNIQUE REFERENCES sales.ticket(id),
  trip_id     bigint NOT NULL REFERENCES ops.trip(id),
  company_id  bigint NOT NULL REFERENCES iam.company(id),
  party_id    bigint NOT NULL REFERENCES iam.party(id),
  stars       smallint NOT NULL CHECK (stars BETWEEN 1 AND 5),
  punctuality smallint CHECK (punctuality BETWEEN 1 AND 5),
  comfort     smallint CHECK (comfort BETWEEN 1 AND 5),
  staff       smallint CHECK (staff BETWEEN 1 AND 5),
  comment     text,
  moderation  text NOT NULL DEFAULT 'VISIBLE' CHECK (moderation IN ('VISIBLE','HIDDEN')),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX trip_rating_company_idx ON crm.trip_rating (company_id, created_at DESC);
COMMENT ON TABLE crm.trip_rating IS 'Trip rating (one ticket = one rating), feeds carrier ranking (7.7)';

CREATE TABLE crm.notification_template (
  code        text NOT NULL,
  channel     text NOT NULL CHECK (channel IN ('PUSH','SMS','EMAIL','WHATSAPP','IN_APP')),
  locale      text NOT NULL DEFAULT 'en' REFERENCES ref.locale(code),
  subject     text,
  body        text NOT NULL,
  approved_by bigint REFERENCES iam.app_user(id),
  active      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (code, channel, locale)
);
COMMENT ON TABLE crm.notification_template IS 'Approved notification templates (notification catalog 34)';

CREATE TABLE crm.notification (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id         bigint REFERENCES iam.app_user(id),
  party_id        bigint REFERENCES iam.party(id),
  template_code   text NOT NULL,
  channel         text NOT NULL,
  to_address      text,                               -- masked when displayed
  payload         jsonb NOT NULL DEFAULT '{}',
  trip_id         bigint REFERENCES ops.trip(id),
  booking_id      bigint REFERENCES sales.booking(id),
  status          text NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','SENT','DELIVERED','FAILED','READ')),
  cost_minor      bigint NOT NULL DEFAULT 0,          -- charged to the carrier according to its plan
  charged_company_id bigint REFERENCES iam.company(id),
  attempts        smallint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  sent_at         timestamptz,
  read_at         timestamptz
);
CREATE INDEX notification_user_idx ON crm.notification (user_id, created_at DESC);
CREATE INDEX notification_queued_idx ON crm.notification (created_at) WHERE status = 'QUEUED';

-- AI assistant (7.10)
CREATE TABLE crm.ai_policy (
  tool                  text PRIMARY KEY,
  action_level          smallint NOT NULL CHECK (action_level BETWEEN 0 AND 3),
  limits                jsonb NOT NULL DEFAULT '{}',
  requires_confirmation boolean NOT NULL DEFAULT true,
  enabled               boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE crm.ai_policy IS 'Assistant tools, each tool''s action level, limits and user confirmation requirement';

CREATE TABLE crm.ai_conversation (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  channel       text NOT NULL CHECK (channel IN ('APP','WEB','WHATSAPP','VOICE')),
  party_id      bigint REFERENCES iam.party(id),
  company_id    bigint REFERENCES iam.company(id),
  started_at    timestamptz NOT NULL DEFAULT now(),
  ended_at      timestamptz,
  resolved      boolean,
  escalated_case_id bigint REFERENCES crm.case(id),
  csat          smallint CHECK (csat BETWEEN 1 AND 5)
);

CREATE TABLE crm.ai_message (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id bigint NOT NULL REFERENCES crm.ai_conversation(id),
  role            text NOT NULL CHECK (role IN ('USER','ASSISTANT','SYSTEM','TOOL')),
  redacted_text   text NOT NULL,                      -- after redaction of personal data
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE crm.ai_tool_call (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id   bigint NOT NULL REFERENCES crm.ai_conversation(id),
  tool              text NOT NULL REFERENCES crm.ai_policy(tool),
  args_redacted     jsonb NOT NULL,
  action_level      smallint NOT NULL,
  confirmed_by_user boolean NOT NULL DEFAULT false,
  result_status     text NOT NULL CHECK (result_status IN ('OK','DENIED','ERROR')),
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER ai_tool_call_immutable BEFORE UPDATE OR DELETE ON crm.ai_tool_call FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE crm.ai_tool_call IS 'Every tool executed by the assistant with the customer''s permissions and confirmation (append-only)';

-- ============================== gov ==================================
-- Policy authority matrix (2.5)
CREATE TABLE gov.policy_domain (
  code              text PRIMARY KEY,                 -- TARIFF, REFUND_POLICY, SALES_CUTOFF ...
  name              text NOT NULL,
  class             text NOT NULL CHECK (class IN ('TARIFF','COMMERCIAL','COMPLIANCE','OPERATIONS')),
  regulated_bounds  jsonb
);

CREATE TABLE gov.policy_authority (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  domain_code       text NOT NULL REFERENCES gov.policy_domain(code),
  scope             jsonb NOT NULL DEFAULT '{}',      -- service_type, region, company
  mode              text NOT NULL CHECK (mode IN ('PLATFORM','OPERATOR_BOUNDED','REGULATOR','BOUNDS','DUAL')),
  version           int NOT NULL,
  effective_from    timestamptz NOT NULL,
  decision_doc_sha256 bytea,
  status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','RETIRED')),
  approved_by       bigint[] NOT NULL DEFAULT '{}',
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (domain_code, version)
);
COMMENT ON TABLE gov.policy_authority IS 'Who decides each policy domain (platform, carrier within limits, regulator, dual)';

CREATE TABLE gov.policy_change (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  domain_code     text NOT NULL REFERENCES gov.policy_domain(code),
  company_id      bigint REFERENCES iam.company(id),
  version         int NOT NULL,
  proposed_value  jsonb NOT NULL,
  proposer_id     bigint NOT NULL REFERENCES iam.app_user(id),
  approvers       bigint[] NOT NULL DEFAULT '{}',
  authority_snapshot jsonb NOT NULL,
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','REJECTED','RETIRED')),
  effective_from  timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT (proposer_id = ANY (approvers)))
);
COMMENT ON TABLE gov.policy_change IS 'Versioned policy change approved according to the matrix; the proposer cannot approve';

-- Legal obligations and compliance register (16.24)
CREATE TABLE gov.obligation_register (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source          text NOT NULL,                      -- law, decision, circular, contract
  ref_no          text NOT NULL,
  title           text NOT NULL,
  effective_date  date,
  control_ref     text,
  evidence_file_id bigint REFERENCES ref.file_object(id),
  owner_user_id   bigint REFERENCES iam.app_user(id),
  status          text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','COMPLIANT','GAP','NOT_APPLICABLE')),
  next_review     date
);
COMMENT ON TABLE gov.obligation_register IS 'Register of legal obligations mapped to controls and evidence';

CREATE TABLE gov.partner_dpa (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_party_id  bigint NOT NULL REFERENCES iam.party(id),
  purpose           text NOT NULL,
  data_fields       text[] NOT NULL,
  retention_days    int NOT NULL,
  processing_location text,
  signed_at         date NOT NULL,
  review_at         date NOT NULL,
  file_id           bigint REFERENCES ref.file_object(id)
);
COMMENT ON TABLE gov.partner_dpa IS 'Data processing agreements with partners and providers';

CREATE TABLE gov.feature_compliance_review (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  feature         text NOT NULL,
  dpia_file_id    bigint REFERENCES ref.file_object(id),
  obligations     bigint[] NOT NULL DEFAULT '{}',
  decision        text NOT NULL CHECK (decision IN ('APPROVED','APPROVED_WITH_CONDITIONS','REJECTED')),
  approved_by     bigint REFERENCES iam.app_user(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- Data protection (16.13)
CREATE TABLE gov.data_inventory (
  dataset         text PRIMARY KEY,                   -- schema.table or schema.table.column
  data_class      text NOT NULL CHECK (data_class IN ('RESTRICTED','CONFIDENTIAL','INTERNAL','PUBLIC')),
  owner           text NOT NULL,
  purpose         text NOT NULL,
  legal_basis     text NOT NULL,
  retention_days  int,
  location        text NOT NULL DEFAULT 'PRIMARY_DC',
  processors      text[] NOT NULL DEFAULT '{}'
);
COMMENT ON TABLE gov.data_inventory IS 'Data inventory with classification, purpose and retention (drives automatic deletion)';

CREATE TABLE gov.consent (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  party_id    bigint NOT NULL REFERENCES iam.party(id),
  purpose     text NOT NULL CHECK (purpose IN ('MARKETING','CALL_RECORDING','AUTHORITY_SHARING','BIOMETRICS','LOCATION','PARTNER_SHARING')),
  granted     boolean NOT NULL,
  source      text NOT NULL,
  policy_version text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  withdrawn_at timestamptz
);
CREATE INDEX consent_party_idx ON gov.consent (party_id, purpose, created_at DESC);
COMMENT ON TABLE gov.consent IS 'Consents with policy version and withdrawal date';

CREATE TABLE gov.subject_request (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  party_id    bigint NOT NULL REFERENCES iam.party(id),
  kind        text NOT NULL CHECK (kind IN ('ACCESS','RECTIFY','ERASE','PORTABILITY')),
  status      text NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED','IN_PROGRESS','DONE','REJECTED')),
  due_at      timestamptz NOT NULL,
  result      text,
  handled_by  bigint REFERENCES iam.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE gov.privacy_incident (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  detected_at           timestamptz NOT NULL,
  data_class            text NOT NULL,
  affected_count        int,
  description           text NOT NULL,
  status                text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CONTAINED','CLOSED')),
  notified_authority_at timestamptz,
  notified_subjects_at  timestamptz,
  security_event_id     bigint
);

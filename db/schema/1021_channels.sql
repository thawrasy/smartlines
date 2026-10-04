-- =====================================================================
-- 1021: distribution channels and intermediary platforms (study 14.7, 14.8, 14.9, phase 9)
--   Channel agreements linked to commission schemes (a carrier-specific agreement takes precedence over the general
--   one), inventory allotments and cut-offs, API profiles and quotas, the channel's own booking reference,
--   settlement statements with lines and correction memos, and inbound content sources with their mappings.
--   sales.agency_agreement (file 990) stays the travel-agency agreement of phase 1.
-- =====================================================================

ALTER TABLE sales.channel ADD COLUMN IF NOT EXISTS relationship text;
DO $$ BEGIN
  ALTER TABLE sales.channel ADD CONSTRAINT channel_relationship_ck
    CHECK (relationship IS NULL OR relationship IN ('CARRIER_AGENT','PARTNER_PLATFORM'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN sales.channel.relationship IS 'Decides who funds the commission: the carrier''s agent or a partner platform (6.9 c)';

CREATE TABLE IF NOT EXISTS sales.channel_agreement (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  channel_id            bigint NOT NULL REFERENCES sales.channel(id),
  company_id            bigint REFERENCES iam.company(id),            -- empty: the general agreement for all carriers
  model                 text NOT NULL CHECK (model IN ('COMMISSION','NET_FARE')),
  rate_bp               int CHECK (rate_bp BETWEEN 0 AND 10000),
  commission_scheme_id  bigint REFERENCES pricing.commission_scheme(id),
  scope                 jsonb NOT NULL DEFAULT '{}',
  fare_visibility       jsonb NOT NULL DEFAULT '{}',
  markup_policy         jsonb NOT NULL DEFAULT '{}',
  settlement_cycle      text NOT NULL DEFAULT 'WEEKLY' CHECK (settlement_cycle IN ('DAILY','WEEKLY','MONTHLY')),
  label                 text NOT NULL,
  valid                 daterange NOT NULL,
  status                text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','SUSPENDED','ENDED')),
  created_by            bigint REFERENCES iam.app_user(id),
  approved_by           bigint REFERENCES iam.app_user(id),
  CHECK (model <> 'COMMISSION' OR rate_bp IS NOT NULL OR commission_scheme_id IS NOT NULL),
  CHECK (approved_by IS NULL OR approved_by <> created_by),
  EXCLUDE USING gist (channel_id WITH =, (coalesce(company_id, 0)) WITH =, valid WITH &&) WHERE (status = 'ACTIVE')
);
COMMENT ON TABLE sales.channel_agreement IS 'Terms between a channel and the platform or a carrier; links to the commission scheme (5.8)';

CREATE TABLE IF NOT EXISTS sales.channel_inventory_rule (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  channel_id       bigint NOT NULL REFERENCES sales.channel(id),
  company_id       bigint NOT NULL REFERENCES iam.company(id),
  route_id         bigint REFERENCES net.route(id),
  trip_type        text REFERENCES ref.trip_type(code),
  allotment_seats  int CHECK (allotment_seats >= 0),
  cutoff_min       int NOT NULL DEFAULT 60 CHECK (cutoff_min >= 0),
  release_rule     text NOT NULL DEFAULT 'AT_CUTOFF' CHECK (release_rule IN ('AT_CUTOFF','NEVER','ON_DEMAND')),
  visibility       text NOT NULL DEFAULT 'VISIBLE' CHECK (visibility IN ('VISIBLE','HIDDEN')),
  CHECK (route_id IS NOT NULL OR trip_type IS NOT NULL)
);
COMMENT ON TABLE sales.channel_inventory_rule IS 'Seats allotted to a channel per route or trip type, and when unsold seats return';

CREATE TABLE IF NOT EXISTS sales.channel_api_profile (
  channel_id          bigint PRIMARY KEY REFERENCES sales.channel(id),
  api_client_id       bigint NOT NULL UNIQUE REFERENCES iam.api_client(id),
  api_schema          text NOT NULL DEFAULT 'NATIVE' CHECK (api_schema IN ('NATIVE','NDC_LIKE','OSDM')),
  rate_limit_per_min  int NOT NULL DEFAULT 600 CHECK (rate_limit_per_min > 0),
  look_to_book_limit  int CHECK (look_to_book_limit > 0),
  cache_ttl_sec       int NOT NULL DEFAULT 60,
  ip_allow            cidr[] NOT NULL DEFAULT '{}',
  mtls_cert_ref       text
);

CREATE TABLE IF NOT EXISTS sales.channel_booking_ref (
  booking_id        bigint PRIMARY KEY REFERENCES sales.booking(id),
  channel_id        bigint NOT NULL REFERENCES sales.channel(id),
  external_locator  text NOT NULL,
  agent_ref         text,
  sub_agent_ref     text,
  UNIQUE (channel_id, external_locator)
);
COMMENT ON TABLE sales.channel_booking_ref IS 'The booking reference in the channel''s own system';

CREATE TABLE IF NOT EXISTS sales.channel_statement (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  channel_id    bigint NOT NULL REFERENCES sales.channel(id),
  period        daterange NOT NULL,
  gross_sales   bigint NOT NULL DEFAULT 0,
  refunds       bigint NOT NULL DEFAULT 0,
  commission    bigint NOT NULL DEFAULT 0,
  taxes         bigint NOT NULL DEFAULT 0,
  net_due       bigint NOT NULL DEFAULT 0,
  currency      char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  ledger_txn_id bigint REFERENCES fin.ledger_txn(id),
  status        text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ISSUED','DISPUTED','SETTLED')),
  EXCLUDE USING gist (channel_id WITH =, period WITH &&)
);
CREATE TABLE IF NOT EXISTS sales.channel_statement_line (
  statement_id  bigint NOT NULL REFERENCES sales.channel_statement(id) ON DELETE CASCADE,
  line_no       int NOT NULL,
  booking_id    bigint REFERENCES sales.booking(id),
  kind          text NOT NULL CHECK (kind IN ('SALE','REFUND','ADJUSTMENT')),
  gross         bigint NOT NULL,
  commission    bigint NOT NULL DEFAULT 0,
  tax           bigint NOT NULL DEFAULT 0,
  net           bigint NOT NULL,
  PRIMARY KEY (statement_id, line_no)
);

CREATE TABLE IF NOT EXISTS sales.channel_memo (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  channel_id    bigint NOT NULL REFERENCES sales.channel(id),
  statement_id  bigint REFERENCES sales.channel_statement(id),
  memo_type     text NOT NULL CHECK (memo_type IN ('DEBIT','CREDIT')),
  reason        text NOT NULL,
  amount        bigint NOT NULL CHECK (amount > 0),
  currency      char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  ref           text,
  status        text NOT NULL DEFAULT 'ISSUED' CHECK (status IN ('ISSUED','ACCEPTED','DISPUTED','SETTLED','CANCELLED')),
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sales.channel_memo IS 'Debit and credit memos that correct a channel statement (ADM/ACM pattern)';

CREATE TABLE IF NOT EXISTS sales.supplier_source (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name             text NOT NULL,
  source_type      text NOT NULL CHECK (source_type IN ('RAIL','BUS_SYSTEM','OTHER')),
  company_id       bigint REFERENCES iam.company(id),                -- the carrier whose content is imported
  protocol         text NOT NULL CHECK (protocol IN ('REST','SOAP','OSDM','GTFS','SFTP')),
  credentials_ref  text,
  status           text NOT NULL DEFAULT 'TESTING' CHECK (status IN ('TESTING','ACTIVE','SUSPENDED','ENDED'))
);
COMMENT ON TABLE sales.supplier_source IS 'Inbound content source: an external rail or bus system whose inventory is sold on the platform (14.8)';

CREATE TABLE IF NOT EXISTS sales.external_mapping (
  source_id    bigint NOT NULL REFERENCES sales.supplier_source(id) ON DELETE CASCADE,
  local_type   text NOT NULL CHECK (local_type IN ('STATION','ROUTE','FARE','TRIP','CITY')),
  local_id     bigint NOT NULL,
  external_id  text NOT NULL,
  PRIMARY KEY (source_id, local_type, external_id),
  UNIQUE (source_id, local_type, local_id)
);

-- ------------------------------ isolation and privileges ------------------------------
-- A channel's own users (its company or its API client) see their channel's data
CREATE OR REPLACE FUNCTION sales.is_channel_member(p_channel_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT sys.ctx_is_platform()
      OR EXISTS (SELECT 1 FROM sales.channel c WHERE c.id = p_channel_id
                 AND (c.party_id = sys.ctx_company_id() OR c.api_client_id = sys.ctx_api_client_id()))
$$;
DO $$ BEGIN
  PERFORM sys.rls_split('sales.channel_agreement', 'sales.is_channel_member(channel_id) OR sys.tenant_visible(company_id)', 'sys.ctx_is_platform()');
  PERFORM sys.rls_split('sales.channel_inventory_rule', 'sales.is_channel_member(channel_id) OR sys.tenant_visible(company_id)',
    'sys.tenant_visible(company_id)');
  PERFORM sys.rls_split('sales.channel_api_profile', 'sales.is_channel_member(channel_id)', 'sys.ctx_is_platform()');
  PERFORM sys.rls('sales.channel_booking_ref', 'sales.is_channel_member(channel_id)
    OR EXISTS (SELECT 1 FROM sales.booking b WHERE b.id = channel_booking_ref.booking_id)');
  PERFORM sys.rls_split(t, 'sales.is_channel_member(channel_id)', 'sys.ctx_is_platform()')
    FROM unnest(ARRAY['sales.channel_statement','sales.channel_memo']) t;
  PERFORM sys.rls_parent('sales.channel_statement_line', 'statement_id', 'sales.channel_statement');
  PERFORM sys.rls('sales.supplier_source', 'sys.ctx_is_platform() OR (company_id IS NOT NULL AND company_id = sys.ctx_company_id())');
  PERFORM sys.rls_parent('sales.external_mapping', 'source_id', 'sales.supplier_source');
  PERFORM sys.grant_rw(ARRAY['sales.channel_agreement','sales.channel_inventory_rule','sales.channel_api_profile',
    'sales.channel_booking_ref','sales.channel_statement','sales.channel_statement_line','sales.channel_memo',
    'sales.supplier_source','sales.external_mapping']);
END $$;

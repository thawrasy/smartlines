-- =====================================================================
-- 1036: public integration API v1 (backend/app/modules/integration)
--   Partners call /api/v1 with an API key (iam.api_key: hashed, shown once, rotated). A client acts for its
--   company within its scopes: a carrier reads its trips, bookings and manifests; a sales channel (agency)
--   sells tickets; a bank or e-wallet partner credits passenger wallets for money it collected; an authority
--   reads manifests and regulator reports. Webhooks deliver outbox events signed with HMAC-SHA256.
-- =====================================================================

-- ------------------------------ clients
ALTER TABLE iam.api_client ADD COLUMN IF NOT EXISTS description text CHECK (description IS NULL OR length(description) <= 500);
ALTER TABLE iam.api_client ADD COLUMN IF NOT EXISTS contact_email text CHECK (contact_email IS NULL OR contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');
ALTER TABLE iam.api_client ADD COLUMN IF NOT EXISTS acting_user_id bigint REFERENCES iam.app_user(id);
ALTER TABLE iam.api_client ADD COLUMN IF NOT EXISTS payment_provider_id bigint REFERENCES fin.payment_provider(id);
ALTER TABLE iam.api_client ADD COLUMN IF NOT EXISTS authority_id bigint REFERENCES sec.authority_profile(id);
ALTER TABLE iam.api_client ADD COLUMN IF NOT EXISTS status_reason text;
COMMENT ON COLUMN iam.api_client.authority_id IS 'For authorities: the authority whose border points (and crossing profiles) the client may read and answer';
CREATE INDEX IF NOT EXISTS api_client_authority_id_fkx ON iam.api_client (authority_id);
COMMENT ON COLUMN iam.api_client.acting_user_id IS 'The staff account the client acts for: bookings and changes are attributed to it, and its current rights cap the scopes';
COMMENT ON COLUMN iam.api_client.payment_provider_id IS 'For bank and e-wallet partners: the provider whose limits and clearing account apply to wallet credits';
CREATE INDEX IF NOT EXISTS api_client_acting_user_id_fkx ON iam.api_client (acting_user_id);
CREATE INDEX IF NOT EXISTS api_client_payment_provider_id_fkx ON iam.api_client (payment_provider_id);
CREATE INDEX IF NOT EXISTS api_key_api_client_id_fkx ON iam.api_key (api_client_id);

-- keys and webhooks are visible with their client
SELECT sys.rls_parent('iam.api_key', 'api_client_id', 'iam.api_client');
SELECT sys.rls('sys.webhook_endpoint',
  'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM iam.api_client c WHERE c.id = webhook_endpoint.api_client_id)');
SELECT sys.rls_parent('sys.webhook_delivery', 'endpoint_id', 'sys.webhook_endpoint');
CREATE INDEX IF NOT EXISTS webhook_endpoint_api_client_id_fkx ON sys.webhook_endpoint (api_client_id);
CREATE INDEX IF NOT EXISTS webhook_delivery_outbox_event_id_fkx ON sys.webhook_delivery (outbox_event_id);
ALTER TABLE sys.webhook_delivery ADD COLUMN IF NOT EXISTS response_ms int;
ALTER TABLE sys.webhook_delivery ADD COLUMN IF NOT EXISTS event_type text;

-- ------------------------------ daily usage per client (requests and errors)
CREATE TABLE IF NOT EXISTS iam.api_usage_daily (
  api_client_id bigint NOT NULL REFERENCES iam.api_client(id),
  day           date NOT NULL,
  requests      int NOT NULL DEFAULT 0 CHECK (requests >= 0),
  errors        int NOT NULL DEFAULT 0 CHECK (errors >= 0),
  last_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (api_client_id, day)
);
COMMENT ON TABLE iam.api_usage_daily IS 'Calls per API client and day, for the client console and capacity planning';
SELECT sys.rls_parent('iam.api_usage_daily', 'api_client_id', 'iam.api_client');
SELECT sys.grant_rw(ARRAY['iam.api_usage_daily']);

-- ------------------------------ wallet credits by bank and e-wallet partners
ALTER TABLE fin.payment_provider DROP CONSTRAINT IF EXISTS payment_provider_adapter_check;
ALTER TABLE fin.payment_provider ADD CONSTRAINT payment_provider_adapter_check
  CHECK (adapter IN ('SANDBOX','HOSTED_CARD','PARTNER_WALLET','BANK_TRANSFER','CASH_AGENT','API_PARTNER'));
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS api_client_id bigint REFERENCES iam.api_client(id);
COMMENT ON COLUMN fin.payment.api_client_id IS 'The partner API client that credited this payment (money collected at its branches or in its app)';
CREATE INDEX IF NOT EXISTS payment_api_client_id_fkx ON fin.payment (api_client_id);
CREATE UNIQUE INDEX IF NOT EXISTS payment_api_client_ref ON fin.payment (api_client_id, provider_ref) WHERE api_client_id IS NOT NULL;

INSERT INTO fin.payment_provider (code, name, kind, adapter, config, fee_policy, status, sort_order, min_amount, max_amount, purposes)
VALUES ('PARTNER_API', 'Bank and e-wallet partner collections (API)', 'BANK', 'API_PARTNER', '{}',
        '{"pct": 0, "borne_by": "PLATFORM"}', 'ACTIVE', 80, 100000, 100000000, ARRAY['COLLECT'])
ON CONFLICT (code) DO NOTHING;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.19.0', 'Integration API v1: client acting account, usage, key and webhook isolation, partner wallet credits'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.19.0');

-- =====================================================================
-- 1155: integration requests (owner's request N2, decision of 2026-10-23: option B)
--   A carrier or an agency no longer makes API clients, keys, webhooks or scopes itself. Its owner, or an administrator
--   the owner authorised (company.api_keys), files a connection request with every detail the platform needs: why,
--   which kind of connection, the outside system (name, vendor, host, addresses), the data needed, a contact person and
--   the expected volume. Platform security builds the client from the request; another person approves it (the
--   existing four-eyes rule); the company then sees the key once in its portal.
-- =====================================================================

CREATE TABLE IF NOT EXISTS iam.integration_request (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid              uuid NOT NULL DEFAULT gen_random_uuid(),
  company_id       bigint NOT NULL REFERENCES iam.company(id),
  requested_by     bigint NOT NULL REFERENCES iam.app_user(id),
  purpose          text NOT NULL CHECK (length(purpose) BETWEEN 10 AND 1000),
  connection_type  text NOT NULL CHECK (connection_type IN ('READ', 'WEBHOOKS', 'TWO_WAY')),
  data_needed      text[] NOT NULL CHECK (cardinality(data_needed) BETWEEN 1 AND 12),
  system_name      text NOT NULL CHECK (length(system_name) BETWEEN 2 AND 120),
  system_vendor    text CHECK (system_vendor IS NULL OR length(system_vendor) BETWEEN 2 AND 120),
  system_host      text CHECK (system_host IS NULL OR system_host ~ '^[A-Za-z0-9.-]{3,253}$'),
  ip_addresses     cidr[] NOT NULL DEFAULT '{}' CHECK (cardinality(ip_addresses) <= 20),
  contact_name     text NOT NULL CHECK (length(contact_name) BETWEEN 3 AND 120),
  contact_email    text NOT NULL CHECK (contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  contact_mobile   text CHECK (contact_mobile IS NULL OR contact_mobile ~ '^\+?[0-9]{8,15}$'),
  expected_volume  text NOT NULL CHECK (expected_volume IN ('LOW', 'MEDIUM', 'HIGH')),
  environment      text NOT NULL DEFAULT 'SANDBOX' CHECK (environment IN ('SANDBOX', 'PRODUCTION')),
  status           text NOT NULL DEFAULT 'SUBMITTED' CHECK (status IN ('SUBMITTED', 'CLIENT_CREATED', 'REJECTED', 'WITHDRAWN')),
  api_client_id    bigint REFERENCES iam.api_client(id),
  handled_by       bigint REFERENCES iam.app_user(id),
  handled_at       timestamptz,
  decision_note    text CHECK (decision_note IS NULL OR length(decision_note) BETWEEN 1 AND 500),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT integration_request_client_ck CHECK ((status = 'CLIENT_CREATED') = (api_client_id IS NOT NULL)),
  CONSTRAINT integration_request_handled_ck CHECK (status IN ('SUBMITTED', 'WITHDRAWN') OR (handled_by IS NOT NULL AND handled_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS integration_request_uid_uq ON iam.integration_request (uid);
CREATE UNIQUE INDEX IF NOT EXISTS integration_request_api_client_uq ON iam.integration_request (api_client_id) WHERE api_client_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS integration_request_company_id_fkx ON iam.integration_request (company_id);
CREATE INDEX IF NOT EXISTS integration_request_requested_by_fkx ON iam.integration_request (requested_by);
CREATE INDEX IF NOT EXISTS integration_request_handled_by_fkx ON iam.integration_request (handled_by);
CREATE INDEX IF NOT EXISTS integration_request_open_ix ON iam.integration_request (created_at) WHERE status = 'SUBMITTED';
DROP TRIGGER IF EXISTS integration_request_updated ON iam.integration_request;
CREATE TRIGGER integration_request_updated BEFORE UPDATE ON iam.integration_request
  FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE iam.integration_request IS
  'A company''s request for a programmatic connection; platform security builds the client from it and another person approves (1155, N2)';

SELECT sys.rls('iam.integration_request', 'sys.tenant_visible(company_id)');
ALTER TABLE iam.integration_request FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON iam.integration_request TO masslak_app;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('iam.integration_request', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.integration_request', 'iam records', 'companies'' requests for a programmatic connection (1155)')
ON CONFLICT (table_name) DO NOTHING;

UPDATE iam.permission SET description = 'Request a programmatic connection for the company and take its key once approved'
 WHERE code = 'company.api_keys';

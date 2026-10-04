-- =====================================================================
-- 1001: privacy self-service (study 16.20 data subject rights)
--   * A person can export their data, record consents, and ask for erasure. Erasure anonymises the account and
--     personal fields; bookings, tickets and ledger entries stay (financial and tax retention) under the
--     anonymised party.
--   * Requests are answered within 30 days by platform staff holding privacy.manage.
-- =====================================================================
ALTER TABLE gov.subject_request ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE gov.subject_request ADD COLUMN IF NOT EXISTS user_id bigint REFERENCES iam.app_user(id);
ALTER TABLE gov.subject_request ADD COLUMN IF NOT EXISTS reason text;
ALTER TABLE gov.subject_request ADD COLUMN IF NOT EXISTS handled_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS subject_request_uid_uq ON gov.subject_request (uid);
CREATE UNIQUE INDEX IF NOT EXISTS subject_request_one_open ON gov.subject_request (party_id, kind) WHERE status IN ('RECEIVED','IN_PROGRESS');
CREATE INDEX IF NOT EXISTS consent_party_idx ON gov.consent (party_id, purpose, created_at DESC);

ALTER TABLE gov.subject_request ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS subject_request_owner ON gov.subject_request;
CREATE POLICY subject_request_owner ON gov.subject_request
  USING (sys.ctx_is_platform() OR party_id = sys.ctx_party_id())
  WITH CHECK (sys.ctx_is_platform() OR party_id = sys.ctx_party_id());
ALTER TABLE gov.consent ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS consent_owner ON gov.consent;
CREATE POLICY consent_owner ON gov.consent
  USING (sys.ctx_is_platform() OR party_id = sys.ctx_party_id())
  WITH CHECK (sys.ctx_is_platform() OR party_id = sys.ctx_party_id());
-- Consent history is append-only: a change is a new row
REVOKE UPDATE, DELETE ON gov.consent FROM masslak_app;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.9.0', 'Privacy self-service: export, consents, erasure requests'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.9.0');

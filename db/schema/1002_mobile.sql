-- =====================================================================
-- 1002: mobile apps (architecture section 6)
--   * Mobile sessions use a short-lived access token and a rotating refresh token, both stored only as SHA-256
--     hashes and bound to a device record. Presenting an already rotated refresh token revokes the session
--     (token theft detection).
--   * Driver apps board passengers offline with signed ticket credentials and upload the scans later; each scan
--     carries the device's own identifier so a retried upload is applied once.
-- =====================================================================
ALTER TABLE iam.user_session ADD COLUMN IF NOT EXISTS access_expires_at timestamptz;
ALTER TABLE iam.user_session ADD COLUMN IF NOT EXISTS prev_refresh_hash bytea;
ALTER TABLE iam.user_session ADD COLUMN IF NOT EXISTS client text NOT NULL DEFAULT 'web';
DO $$ BEGIN
  ALTER TABLE iam.user_session ADD CONSTRAINT user_session_client_ck CHECK (client IN ('web','android','ios'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS user_session_prev_refresh_idx ON iam.user_session (prev_refresh_hash) WHERE prev_refresh_hash IS NOT NULL;
COMMENT ON COLUMN iam.user_session.access_expires_at IS 'Mobile access token expiry (15 minutes); web sessions use expires_at only';

ALTER TABLE sales.boarding_event ADD COLUMN IF NOT EXISTS device_scan_id text;
ALTER TABLE sales.boarding_event ADD COLUMN IF NOT EXISTS scanned_at timestamptz;
ALTER TABLE sales.boarding_event DROP CONSTRAINT IF EXISTS boarding_event_method_check;
ALTER TABLE sales.boarding_event ADD CONSTRAINT boarding_event_method_check
  CHECK (method IN ('AGENT_SCAN','SELF_SCAN','VALIDATOR_QR','VALIDATOR_NFC','MANUAL','OFFLINE_SCAN'));
CREATE UNIQUE INDEX IF NOT EXISTS boarding_event_device_scan_uq ON sales.boarding_event (scanned_by_user_id, device_scan_id)
  WHERE device_scan_id IS NOT NULL;

INSERT INTO sec.key_registry (key_ref, purpose, data_class, algorithm)
SELECT 'kms://masslak/sign/ticket-credential/v1', 'QR_SIGNING', 'INTERNAL', 'Ed25519'
 WHERE NOT EXISTS (SELECT 1 FROM sec.key_registry WHERE key_ref = 'kms://masslak/sign/ticket-credential/v1');

INSERT INTO sys.schema_migration (version, description)
SELECT '1.10.0', 'Mobile sessions with rotating refresh tokens, offline boarding'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.10.0');

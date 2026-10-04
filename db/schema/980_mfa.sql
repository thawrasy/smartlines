-- =====================================================================
-- 980: two-factor sign-in (TOTP, RFC 6238) for staff portals (study 16.18)
--   * The TOTP secret is stored AES-256-GCM encrypted (secret_enc + enc_key_id), never in clear.
--   * last_used_step blocks replay of a code inside its 30-second window.
--   * Recovery codes are stored as SHA-256 hashes inside an encrypted RECOVERY_CODES factor; each is single use.
--   * A session that still owes its second factor counts failures and is revoked after five.
-- =====================================================================
ALTER TABLE iam.mfa_factor ADD COLUMN IF NOT EXISTS last_used_step bigint;
ALTER TABLE iam.mfa_factor ADD COLUMN IF NOT EXISTS label text;
ALTER TABLE iam.user_session ADD COLUMN IF NOT EXISTS mfa_failures smallint NOT NULL DEFAULT 0;

CREATE UNIQUE INDEX IF NOT EXISTS mfa_factor_one_active
  ON iam.mfa_factor (user_id, factor_type) WHERE disabled_at IS NULL;

COMMENT ON COLUMN iam.mfa_factor.last_used_step IS 'Last accepted TOTP time step; a code for this step or earlier is refused (replay)';
COMMENT ON COLUMN iam.user_session.mfa_failures IS 'Wrong second-factor codes on this session; five revoke it';

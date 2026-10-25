-- =====================================================================
-- 1151: second-factor channels (owner's request N36)
--   * Codes for the second step of sign-in can come by e-mail or by Telegram, besides the authenticator app and the
--     recovery codes. Text messages and WhatsApp stay in the code but are closed in the policy until a provider is
--     contracted.
--   * A Telegram chat is linked by a one-time link: the person opens t.me/<bot>?start=<token> from the sign-in page;
--     the bot's webhook receives the token and records the chat, encrypted, on the pending factor; the first code goes
--     to that chat and confirms it.
-- =====================================================================

ALTER TABLE iam.mfa_factor DROP CONSTRAINT IF EXISTS mfa_factor_factor_type_check;
ALTER TABLE iam.mfa_factor ADD CONSTRAINT mfa_factor_factor_type_check
  CHECK (factor_type IN ('TOTP','SMS','WHATSAPP','EMAIL','TELEGRAM','PASSKEY','RECOVERY_CODES'));
COMMENT ON TABLE iam.mfa_factor IS
  'Second factors: TOTP (encrypted secret), SMS and WHATSAPP (encrypted phone number), EMAIL (encrypted address), TELEGRAM (encrypted chat id), passkeys, recovery codes (1075, 1151)';

ALTER TABLE iam.mfa_challenge DROP CONSTRAINT IF EXISTS mfa_challenge_channel_check;
ALTER TABLE iam.mfa_challenge ADD CONSTRAINT mfa_challenge_channel_check
  CHECK (channel IN ('SMS','WHATSAPP','EMAIL','TELEGRAM'));
COMMENT ON TABLE iam.mfa_challenge IS
  'A one-time code sent by e-mail, Telegram, text or WhatsApp message: only its keyed hash is kept, it expires within minutes and allows five tries (1075, 1151)';

-- ------------------------------------------------------------------ a Telegram chat linked by a one-time link
CREATE TABLE IF NOT EXISTS iam.messenger_link (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  factor_id   bigint NOT NULL REFERENCES iam.mfa_factor(id),
  channel     text NOT NULL CHECK (channel IN ('TELEGRAM')),
  token_hash  bytea NOT NULL CHECK (octet_length(token_hash) = 32),
  expires_at  timestamptz NOT NULL,
  linked_at   timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT messenger_link_window_ck CHECK (expires_at > created_at AND expires_at <= created_at + interval '30 minutes')
);
CREATE UNIQUE INDEX IF NOT EXISTS messenger_link_token_uq ON iam.messenger_link (token_hash);
CREATE INDEX IF NOT EXISTS messenger_link_user_id_fkx ON iam.messenger_link (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS messenger_link_factor_id_fkx ON iam.messenger_link (factor_id);
COMMENT ON TABLE iam.messenger_link IS
  'A one-time link that ties a Telegram chat to a second factor being enrolled: only the keyed hash of its token is kept, it lasts minutes and is used once (1151, N36)';
SELECT sys.rls('iam.messenger_link', 'sys.ctx_is_platform() OR sys.ctx_is_auth() OR user_id = sys.ctx_user_id()');
ALTER TABLE iam.messenger_link FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON iam.messenger_link TO masslak_app;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('iam.messenger_link', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.messenger_link', 'iam records', 'one-time links that tie a Telegram chat to a second factor (1151)')
ON CONFLICT (table_name) DO NOTHING;

-- ------------------------------------------------------------------ the policy: e-mail and Telegram open, messages closed
UPDATE sys.setting
   SET value = jsonb_set(value, '{methods}',
                 (SELECT coalesce(jsonb_agg(m ORDER BY array_position(ARRAY['TOTP','EMAIL','TELEGRAM','SMS','WHATSAPP'], m)), '[]'::jsonb)
                    FROM (SELECT DISTINCT m FROM jsonb_array_elements_text(value -> 'methods') m
                           WHERE m NOT IN ('SMS', 'WHATSAPP')
                          UNION SELECT 'EMAIL' UNION SELECT 'TELEGRAM') s)),
       description = 'Two-factor sign-in: the methods open (TOTP, EMAIL, TELEGRAM; SMS and WHATSAPP once a provider is contracted), the portals that must use one, and the message code limits (1075, 1151)'
 WHERE key = 'auth.mfa' AND NOT (value -> 'methods' ? 'TELEGRAM');

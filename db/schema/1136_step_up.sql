-- =====================================================================
-- 1136: step-up authentication for sensitive operations (evaluation reports of October 2026, GP; owner's approval)
--   A session passes its second factor once, at sign-in. Before an operation that moves money out, widens access or
--   takes data out, the API now asks for the second factor again when the last one on this session is older than
--   auth.mfa.step_up_minutes (10 by default, 5 to 60, set by the security officers): adding or verifying a bank account,
--   approving or paying withdrawals and settlements, adding staff, external auditor access and authority members,
--   changing the two-factor policy, exporting reports, manifests or a person's own data, creating API clients, keys
--   and webhook endpoints. It applies to everyone who uses a second factor (staff always outside the sandbox).
--   * iam.user_session.mfa_at: when this session last passed its second factor (sign-in or step-up).
-- =====================================================================

ALTER TABLE iam.user_session ADD COLUMN IF NOT EXISTS mfa_at timestamptz;
COMMENT ON COLUMN iam.user_session.mfa_at IS 'When this session last passed its second factor, at sign-in or step-up; sensitive operations need it recent (1136)';

UPDATE sys.setting SET value = value || '{"step_up_minutes": 10}'::jsonb, updated_at = now()
 WHERE key = 'auth.mfa' AND NOT value ? 'step_up_minutes';

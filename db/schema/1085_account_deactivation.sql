-- =====================================================================
-- Masslak - 1085: a closed account keeps its data (the owner's rule of 10 October 2026)
--
-- The owner closes an account with POST /api/account/deactivate: the status becomes DEACTIVATED, every session ends,
-- nothing is deleted, and nobody signs in until the owner reactivates it with the same details (POST /api/auth/reactivate).
-- The erasure request of 1039 (gov.erase_party) is another thing: an irreversible pseudonymisation on the person's own
-- written request, which ends with the status CLOSED. The event names of the sign-in audit trail follow the same rule.
-- =====================================================================

ALTER TABLE iam.app_user DROP CONSTRAINT app_user_status_check;
ALTER TABLE iam.app_user ADD CONSTRAINT app_user_status_check
  CHECK (status IN ('PENDING', 'ACTIVE', 'LOCKED', 'DISABLED', 'CLOSED', 'DEACTIVATED'));
COMMENT ON COLUMN iam.app_user.status IS 'DEACTIVATED: closed by its owner, data kept, reactivated with the same details (POST /api/auth/reactivate, 1085); CLOSED: erased (1039)';

ALTER TABLE audit.auth_event DROP CONSTRAINT auth_event_event_check;
ALTER TABLE audit.auth_event ADD CONSTRAINT auth_event_event_check
  CHECK (event = ANY (ARRAY['LOGIN_SUCCESS'::text, 'LOGIN_FAILED'::text, 'LOGOUT'::text, 'MFA_SUCCESS'::text, 'MFA_FAILED'::text,
    'OTP_SENT'::text, 'OTP_FAILED'::text, 'PASSWORD_CHANGED'::text, 'PASSWORD_RESET'::text, 'TOKEN_REFRESH'::text,
    'SESSION_REVOKED'::text, 'ACCOUNT_LOCKED'::text, 'DEVICE_NEW'::text, 'DEVICE_APPROVED'::text, 'PORTAL_SWITCH'::text,
    'API_KEY_AUTH'::text, 'API_KEY_REJECTED'::text, 'IP_BLOCKED'::text, 'ACCOUNT_DEACTIVATED'::text, 'ACCOUNT_REACTIVATED'::text]));

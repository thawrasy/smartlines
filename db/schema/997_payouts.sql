-- =====================================================================
-- 997: payouts to carriers and agencies, and settlement statements (study 5.7, 6.4)
--   * A company withdraws from its wallet to a verified bank account. The amount is held on the wallet when the
--     request is made (hold_balance), so it cannot be spent twice while finance processes it.
--   * Four eyes: the person who requests never approves; above a set amount a second, different approver is
--     needed; the transfer is recorded as paid with the bank reference, and only then posted to the ledger.
--   * Settlement statements per period are drafted by one finance user and approved by another.
--   * IBANs are stored AES-256-GCM encrypted with a blind index; revealing one to finance is logged with a reason.
-- =====================================================================

-- Withdrawals
ALTER TABLE fin.withdrawal_request ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE fin.withdrawal_request ADD COLUMN IF NOT EXISTS company_id bigint REFERENCES iam.company(id);
ALTER TABLE fin.withdrawal_request ADD COLUMN IF NOT EXISTS currency char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code);
ALTER TABLE fin.withdrawal_request ADD COLUMN IF NOT EXISTS needs_second boolean NOT NULL DEFAULT false;
ALTER TABLE fin.withdrawal_request ADD COLUMN IF NOT EXISTS idempotency_key text;
ALTER TABLE fin.withdrawal_request ADD COLUMN IF NOT EXISTS bank_ref text;
ALTER TABLE fin.withdrawal_request ADD COLUMN IF NOT EXISTS reject_reason text;
ALTER TABLE fin.withdrawal_request ADD COLUMN IF NOT EXISTS paid_by bigint REFERENCES iam.app_user(id);
ALTER TABLE fin.withdrawal_request ADD COLUMN IF NOT EXISTS paid_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS withdrawal_uid_uq ON fin.withdrawal_request (uid);
CREATE UNIQUE INDEX IF NOT EXISTS withdrawal_idem_uq ON fin.withdrawal_request (wallet_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS withdrawal_status_idx ON fin.withdrawal_request (status, created_at);
DO $$ BEGIN
  ALTER TABLE fin.withdrawal_request ADD CONSTRAINT withdrawal_paid_ck
    CHECK (status <> 'PAID' OR (bank_ref IS NOT NULL AND ledger_txn_id IS NOT NULL AND approved_by IS NOT NULL
                               AND (NOT needs_second OR second_approver IS NOT NULL)));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE fin.withdrawal_request ADD CONSTRAINT withdrawal_payer_ck CHECK (paid_by IS NULL OR paid_by <> requested_by);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Only allowed status moves (anything else is refused)
CREATE OR REPLACE FUNCTION fin.tg_withdrawal_transition() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'REQUESTED' AND NEW.status IN ('APPROVED','REJECTED')) OR
       (OLD.status = 'APPROVED'  AND NEW.status IN ('PAID','REJECTED','FAILED'))) THEN
    RAISE EXCEPTION 'INVALID_TRANSITION: withdrawal % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS withdrawal_transition ON fin.withdrawal_request;
CREATE TRIGGER withdrawal_transition BEFORE UPDATE ON fin.withdrawal_request
  FOR EACH ROW EXECUTE FUNCTION fin.tg_withdrawal_transition();

ALTER TABLE fin.withdrawal_request ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS withdrawal_isolation ON fin.withdrawal_request;
CREATE POLICY withdrawal_isolation ON fin.withdrawal_request
  USING (sys.tenant_visible(company_id)) WITH CHECK (sys.tenant_visible(company_id));

-- Bank accounts: the company's own, and finance
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS verified_by bigint REFERENCES iam.app_user(id);
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS verified_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS bank_account_uid_uq ON iam.bank_account (uid);
ALTER TABLE iam.bank_account ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bank_account_isolation ON iam.bank_account;
CREATE POLICY bank_account_isolation ON iam.bank_account
  USING (sys.tenant_visible(party_id) OR party_id = sys.ctx_party_id())
  WITH CHECK (sys.tenant_visible(party_id) OR party_id = sys.ctx_party_id());
-- A company cannot mark its own account verified: only the platform changes verification
CREATE OR REPLACE FUNCTION iam.tg_bank_account_verify() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT sys.ctx_is_platform() AND
     ((TG_OP = 'INSERT' AND NEW.verified) OR (TG_OP = 'UPDATE' AND NEW.verified IS DISTINCT FROM OLD.verified)) THEN
    RAISE EXCEPTION 'FORBIDDEN: only platform finance verifies bank accounts' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS bank_account_verify ON iam.bank_account;
CREATE TRIGGER bank_account_verify BEFORE INSERT OR UPDATE ON iam.bank_account
  FOR EACH ROW EXECUTE FUNCTION iam.tg_bank_account_verify();

-- Settlement statements: drafted by one person, approved by another
ALTER TABLE fin.settlement_batch ADD COLUMN IF NOT EXISTS created_by bigint REFERENCES iam.app_user(id);
ALTER TABLE fin.settlement_batch ADD COLUMN IF NOT EXISTS approved_at timestamptz;
DO $$ BEGIN
  ALTER TABLE fin.settlement_batch ADD CONSTRAINT settlement_four_eyes_ck CHECK (approved_by IS NULL OR approved_by <> created_by);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE fin.settlement_line ADD COLUMN IF NOT EXISTS trip_no text;
ALTER TABLE fin.settlement_line ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS settlement_line_via_batch ON fin.settlement_line;
CREATE POLICY settlement_line_via_batch ON fin.settlement_line
  USING (EXISTS (SELECT 1 FROM fin.settlement_batch b WHERE b.id = batch_id));

INSERT INTO sys.setting (key, value, description)
VALUES ('payout.second_approval_above', '100000000', 'Withdrawals above this amount (minor units, SYP 1,000,000) need a second approver')
ON CONFLICT (key) DO NOTHING;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.6.0', 'Payouts with four-eyes approval, settlement statements, encrypted bank accounts'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.6.0');

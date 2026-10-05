-- =====================================================================
-- 1035: payment integration
--   Every way money enters a wallet goes through a provider adapter (backend/app/modules/payments):
--     HOSTED_CARD     card gateway with a hosted payment page; the result arrives as a signed server notification
--     PARTNER_WALLET  another e-wallet or bank app: request to pay on the payer's mobile, confirmed with a one-time code
--     BANK_TRANSFER   transfer to the platform's bank account with a unique reference, matched from the bank statement
--     CASH_AGENT      cash at an agency counter, paid from the agency's prepaid balance
--     SANDBOX         simulated gateway for testing (refused unless MASSLAK_SANDBOX=true)
--   Provider secrets never sit in the database: config names the environment variable that holds each one.
-- =====================================================================

-- ------------------------------ providers
ALTER TABLE fin.payment_provider ADD COLUMN IF NOT EXISTS adapter text NOT NULL DEFAULT 'SANDBOX'
  CHECK (adapter IN ('SANDBOX','HOSTED_CARD','PARTNER_WALLET','BANK_TRANSFER','CASH_AGENT'));
ALTER TABLE fin.payment_provider ADD COLUMN IF NOT EXISTS min_amount bigint NOT NULL DEFAULT 100000 CHECK (min_amount > 0);
ALTER TABLE fin.payment_provider ADD COLUMN IF NOT EXISTS max_amount bigint NOT NULL DEFAULT 100000000 CHECK (max_amount > 0);
ALTER TABLE fin.payment_provider ADD COLUMN IF NOT EXISTS purposes text[] NOT NULL DEFAULT ARRAY['TOPUP']::text[];
ALTER TABLE fin.payment_provider ADD COLUMN IF NOT EXISTS sort_order smallint NOT NULL DEFAULT 100;
ALTER TABLE fin.payment_provider ADD COLUMN IF NOT EXISTS updated_by bigint REFERENCES iam.app_user(id);
ALTER TABLE fin.payment_provider ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
DO $$ BEGIN
  ALTER TABLE fin.payment_provider ADD CONSTRAINT payment_provider_amounts CHECK (max_amount >= min_amount);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN fin.payment_provider.adapter IS 'Integration pattern implemented by the backend adapter of the same name';
COMMENT ON COLUMN fin.payment_provider.config IS 'Non-secret settings (base URL, merchant code, bank account details); secrets are named by *_env keys and read from the environment';

-- ------------------------------ payments: the stage of the flow, expiry and failure reason
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS stage text NOT NULL DEFAULT 'CREATED'
  CHECK (stage IN ('CREATED','REDIRECTED','OTP_SENT','AWAITING_TRANSFER','CONFIRMED','FAILED','CANCELLED','EXPIRED','REFUNDED'));
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS checkout_url text CHECK (checkout_url IS NULL OR checkout_url ~ '^(https://|/)');
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS expires_at timestamptz;
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS failure_code text CHECK (failure_code IS NULL OR failure_code ~ '^[A-Z_]{3,40}$');
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS payer_mobile_mask text;
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS otp_attempts smallint NOT NULL DEFAULT 0 CHECK (otp_attempts BETWEEN 0 AND 10);
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS refunded_amount bigint NOT NULL DEFAULT 0 CHECK (refunded_amount >= 0);
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS agency_company_id bigint REFERENCES iam.company(id);
DO $$ BEGIN
  ALTER TABLE fin.payment ADD CONSTRAINT payment_refund_within_amount CHECK (refunded_amount <= amount);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN fin.payment.stage IS 'Where the flow stands; status stays the money outcome (PENDING, SUCCESS, FAILED, REFUNDED)';
COMMENT ON COLUMN fin.payment.payer_mobile_mask IS 'Masked mobile of a partner e-wallet payer, for support; the full number is only sent to the provider';
CREATE INDEX IF NOT EXISTS payment_agency_company_id_fkx ON fin.payment (agency_company_id);
CREATE INDEX IF NOT EXISTS payment_pending_expiry ON fin.payment (expires_at) WHERE status = 'PENDING';
CREATE UNIQUE INDEX IF NOT EXISTS payment_provider_ref_uq ON fin.payment (provider_id, provider_ref) WHERE provider_ref IS NOT NULL;

-- One notification per provider event: a replayed notification is recorded once and applied once
CREATE UNIQUE INDEX IF NOT EXISTS payment_notification_event_uq ON fin.payment_notification (provider_id, event_id);

-- ------------------------------ refunds to the original method
CREATE TABLE IF NOT EXISTS fin.payment_refund (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  payment_id      bigint NOT NULL REFERENCES fin.payment(id),
  amount          bigint NOT NULL CHECK (amount > 0),
  reason          text NOT NULL CHECK (length(reason) BETWEEN 5 AND 300),
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SUCCESS','FAILED')),
  provider_ref    text,
  ledger_txn_id   bigint REFERENCES fin.ledger_txn(id),
  requested_by    bigint NOT NULL REFERENCES iam.app_user(id),
  idempotency_key text NOT NULL UNIQUE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz,
  CHECK (status <> 'SUCCESS' OR ledger_txn_id IS NOT NULL)
);
COMMENT ON TABLE fin.payment_refund IS 'Money returned to the card or e-wallet it came from; the wallet is debited in the same transaction';
CREATE INDEX IF NOT EXISTS payment_refund_payment_id_fkx ON fin.payment_refund (payment_id);
CREATE INDEX IF NOT EXISTS payment_refund_ledger_txn_id_fkx ON fin.payment_refund (ledger_txn_id);
CREATE INDEX IF NOT EXISTS payment_refund_requested_by_fkx ON fin.payment_refund (requested_by);

-- ------------------------------ bank transfers: reference per top-up, matched from statements
ALTER TABLE fin.bank_transfer_topup ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE fin.bank_transfer_topup ADD COLUMN IF NOT EXISTS payment_id bigint REFERENCES fin.payment(id);
ALTER TABLE fin.bank_transfer_topup ADD COLUMN IF NOT EXISTS expires_at timestamptz;
ALTER TABLE fin.bank_transfer_topup ADD COLUMN IF NOT EXISTS matched_by bigint REFERENCES iam.app_user(id);
ALTER TABLE fin.bank_transfer_topup ADD COLUMN IF NOT EXISTS statement_line_id bigint;
CREATE UNIQUE INDEX IF NOT EXISTS bank_transfer_topup_uid_uq ON fin.bank_transfer_topup (uid);
CREATE INDEX IF NOT EXISTS bank_transfer_topup_payment_id_fkx ON fin.bank_transfer_topup (payment_id);
CREATE INDEX IF NOT EXISTS bank_transfer_topup_matched_by_fkx ON fin.bank_transfer_topup (matched_by);

CREATE TABLE IF NOT EXISTS fin.bank_statement_import (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  account_label text NOT NULL CHECK (length(account_label) BETWEEN 2 AND 80),
  file_sha256   bytea NOT NULL,
  line_count    integer NOT NULL CHECK (line_count >= 0),
  matched_count integer NOT NULL DEFAULT 0 CHECK (matched_count >= 0),
  imported_by   bigint NOT NULL REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_label, file_sha256)
);
COMMENT ON TABLE fin.bank_statement_import IS 'A bank statement file imported by finance; the same file cannot be imported twice';
CREATE INDEX IF NOT EXISTS bank_statement_import_imported_by_fkx ON fin.bank_statement_import (imported_by);

CREATE TABLE IF NOT EXISTS fin.bank_statement_line (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  import_id     bigint NOT NULL REFERENCES fin.bank_statement_import(id) ON DELETE CASCADE,
  value_date    date NOT NULL,
  amount        bigint NOT NULL CHECK (amount > 0),
  currency      char(3) NOT NULL REFERENCES ref.currency(code),
  reference     text,
  payer         text,
  bank_ref      text NOT NULL,
  status        text NOT NULL DEFAULT 'UNMATCHED' CHECK (status IN ('UNMATCHED','MATCHED','IGNORED')),
  topup_id      bigint REFERENCES fin.bank_transfer_topup(id),
  note          text CHECK (note IS NULL OR length(note) <= 300),
  decided_by    bigint REFERENCES iam.app_user(id),
  decided_at    timestamptz,
  UNIQUE (import_id, bank_ref),
  CHECK ((status = 'MATCHED') = (topup_id IS NOT NULL))
);
COMMENT ON TABLE fin.bank_statement_line IS 'One credit line of an imported statement: matched to a top-up by reference and amount, or decided by finance';
COMMENT ON COLUMN fin.bank_statement_line.bank_ref IS 'External: the bank''s own transaction reference';
CREATE INDEX IF NOT EXISTS bank_statement_line_import_id_fkx ON fin.bank_statement_line (import_id);
CREATE INDEX IF NOT EXISTS bank_statement_line_topup_id_fkx ON fin.bank_statement_line (topup_id);
CREATE INDEX IF NOT EXISTS bank_statement_line_decided_by_fkx ON fin.bank_statement_line (decided_by);
CREATE UNIQUE INDEX IF NOT EXISTS bank_statement_line_bank_ref_once ON fin.bank_statement_line (bank_ref) WHERE status = 'MATCHED';
DO $$ BEGIN
  ALTER TABLE fin.bank_transfer_topup ADD CONSTRAINT bank_transfer_topup_statement_line_fk
    FOREIGN KEY (statement_line_id) REFERENCES fin.bank_statement_line(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS bank_transfer_topup_statement_line_id_fkx ON fin.bank_transfer_topup (statement_line_id);

-- ------------------------------ row-level security and privileges
SELECT sys.rls('fin.payment_refund', 'sys.ctx_is_platform()');
SELECT sys.rls('fin.bank_statement_import', 'sys.ctx_is_platform()');
SELECT sys.rls('fin.bank_statement_line', 'sys.ctx_is_platform()');
SELECT sys.grant_rw(ARRAY['fin.payment_refund','fin.bank_statement_import','fin.bank_statement_line']);

-- ------------------------------ platform clearing wallet for bank transfers (cards and e-wallets use GATEWAY_CLEARING)
INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency, allow_negative)
SELECT p.id, 'BANK_CLEARING', 'Bank transfers received', 'SYP', true FROM iam.party p
 WHERE p.legal_name = 'Masslak Platform' AND p.party_type = 'COMPANY'
   AND NOT EXISTS (SELECT 1 FROM fin.wallet w WHERE w.owner_party_id = p.id AND w.wallet_type = 'BANK_CLEARING' AND w.currency = 'SYP');

-- ------------------------------ the providers the platform starts with (inactive until configured, except sandbox)
INSERT INTO fin.payment_provider (code, name, kind, adapter, config, fee_policy, status, sort_order, min_amount, max_amount)
VALUES
  ('CARD', 'Bank card (Visa, Mastercard, local cards)', 'CARD', 'HOSTED_CARD',
   '{"base_url": "", "merchant_id": "", "secret_env": "MASSLAK_PSP_CARD_SECRET", "api_key_env": "MASSLAK_PSP_CARD_KEY"}',
   '{"pct": 1.5, "borne_by": "PLATFORM"}', 'INACTIVE', 10, 500000, 50000000),
  ('EWALLET', 'Partner e-wallet', 'E_WALLET', 'PARTNER_WALLET',
   '{"base_url": "", "merchant_code": "", "secret_env": "MASSLAK_PSP_EWALLET_SECRET", "api_key_env": "MASSLAK_PSP_EWALLET_KEY"}',
   '{"pct": 1.0, "borne_by": "PLATFORM"}', 'INACTIVE', 20, 100000, 20000000),
  ('BANK', 'Bank transfer', 'BANK', 'BANK_TRANSFER',
   '{"bank_name": "", "account_name": "Masslak", "iban": "", "valid_days": 3}',
   '{"pct": 0, "borne_by": "PAYER"}', 'INACTIVE', 30, 1000000, 500000000),
  ('AGENT', 'Cash at a travel agency', 'CASH_AGENT', 'CASH_AGENT', '{}',
   '{"pct": 0, "borne_by": "PLATFORM"}', 'ACTIVE', 40, 100000, 10000000)
ON CONFLICT (code) DO NOTHING;
UPDATE fin.payment_provider SET adapter = 'SANDBOX', sort_order = 90 WHERE code = 'SANDBOX' AND adapter = 'SANDBOX';

INSERT INTO sys.schema_migration (version, description)
SELECT '1.18.0', 'Payment integration: card gateway, partner e-wallets, bank transfers with statement matching, agency top-ups, refunds'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.18.0');

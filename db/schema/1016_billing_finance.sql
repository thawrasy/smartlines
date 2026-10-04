-- =====================================================================
-- 1016: carrier subscriptions and billing (study 5.11 d), cash remittances (6.5), payout account (6.6) and
--       the liquidity controls of the wallet float (6.8 c)
--   The carrier's own API keys are iam.api_client and iam.api_key (carrier_api_key in 5.11 d).
-- =====================================================================

-- ------------------------------ plans and agreements ------------------------------
CREATE TABLE IF NOT EXISTS bill.plan (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code                  text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_]{2,30}$'),
  kind                  text NOT NULL CHECK (kind IN ('STANDARD','SHUTTLE')),
  name                  text NOT NULL,
  annual_fee            bigint NOT NULL CHECK (annual_fee >= 0),
  currency              char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  included_users        int NOT NULL DEFAULT 1 CHECK (included_users >= 0),
  extra_user_fee        bigint NOT NULL DEFAULT 0 CHECK (extra_user_fee >= 0),
  max_extra_users       int CHECK (max_extra_users >= 0),
  included_invoices     int NOT NULL DEFAULT 0,
  included_api_calls    int NOT NULL DEFAULT 0,
  included_whatsapp     int NOT NULL DEFAULT 0,
  commission_bp         int NOT NULL DEFAULT 0 CHECK (commission_bp BETWEEN 0 AND 10000),
  overage_invoice_fee   bigint NOT NULL DEFAULT 0,
  overage_api_per_1000  bigint NOT NULL DEFAULT 0,
  overage_whatsapp_fee  bigint NOT NULL DEFAULT 0,
  self_service          boolean NOT NULL DEFAULT true,
  status                text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  created_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE bill.plan IS 'Package catalog: three carrier plans and two shuttle plans with included quantities and overage (5.11 d)';

CREATE TABLE IF NOT EXISTS bill.carrier_agreement (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id   bigint NOT NULL REFERENCES iam.company(id),
  label        text NOT NULL,
  terms        jsonb NOT NULL,                                      -- commission per carrier, discount on the annual fee
  valid_days   int NOT NULL CHECK (valid_days > 0),
  status       text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','REJECTED','ENDED')),
  created_by   bigint NOT NULL REFERENCES iam.app_user(id),
  approved_by  bigint REFERENCES iam.app_user(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);
COMMENT ON TABLE bill.carrier_agreement IS 'A negotiated agreement with one carrier, four-eyes approved';

CREATE TABLE IF NOT EXISTS bill.company_subscription (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint NOT NULL REFERENCES iam.company(id),
  source        text NOT NULL CHECK (source IN ('PLAN','AGREEMENT')),
  plan_id       bigint REFERENCES bill.plan(id),
  agreement_id  bigint REFERENCES bill.carrier_agreement(id),
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('PENDING','ACTIVE','GRACE','SUSPENDED','EXPIRED','CANCELLED')),
  starts_at     timestamptz NOT NULL,
  ends_at       timestamptz NOT NULL,
  terms         jsonb NOT NULL,                                     -- snapshot of the plan or agreement
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((source = 'PLAN' AND plan_id IS NOT NULL) OR (source = 'AGREEMENT' AND agreement_id IS NOT NULL)),
  CHECK (ends_at > starts_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS company_subscription_one_active ON bill.company_subscription (company_id)
  WHERE status IN ('ACTIVE','GRACE');
COMMENT ON TABLE bill.company_subscription IS 'One active subscription per company; terms are copied at start';

CREATE TABLE IF NOT EXISTS bill.usage_event (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint NOT NULL REFERENCES iam.company(id),
  kind        text NOT NULL CHECK (kind IN ('INVOICE','TICKET','API_CALL','WHATSAPP','USER_SEAT')),
  qty         int NOT NULL DEFAULT 1 CHECK (qty > 0),
  ref_type    text,
  ref_id      bigint,
  ts          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS usage_event_company_idx ON bill.usage_event (company_id, kind, ts);
COMMENT ON TABLE bill.usage_event IS 'Metering log; append-only';

CREATE TABLE IF NOT EXISTS bill.carrier_invoice (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id           bigint NOT NULL REFERENCES iam.company(id),
  subscription_id      bigint REFERENCES bill.company_subscription(id),
  kind                 text NOT NULL CHECK (kind IN ('SUBSCRIPTION','USAGE')),
  period_start         date NOT NULL,
  period_end           date NOT NULL,
  subtotal             bigint NOT NULL DEFAULT 0,
  discount             bigint NOT NULL DEFAULT 0,
  tax                  bigint NOT NULL DEFAULT 0,
  total                bigint NOT NULL DEFAULT 0,
  currency             char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status               text NOT NULL DEFAULT 'DUE' CHECK (status IN ('DRAFT','DUE','PAID','OVERDUE','VOID')),
  einvoice_document_id bigint REFERENCES acct.einvoice_document(id),
  ledger_txn_id        bigint REFERENCES fin.ledger_txn(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, kind, period_start),
  CHECK (period_end >= period_start),
  CHECK (total = subtotal - discount + tax)
);

CREATE TABLE IF NOT EXISTS bill.carrier_invoice_line (
  invoice_id   bigint NOT NULL REFERENCES bill.carrier_invoice(id) ON DELETE CASCADE,
  line_no      smallint NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('ANNUAL_FEE','EXTRA_USER','INVOICE','API_CALL','WHATSAPP','DISCOUNT','OTHER')),
  description  text NOT NULL,
  qty          numeric(12,2) NOT NULL DEFAULT 1,
  unit_price   bigint NOT NULL,
  amount       bigint NOT NULL,
  PRIMARY KEY (invoice_id, line_no)
);

CREATE TABLE IF NOT EXISTS bill.billed_usage (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id       bigint NOT NULL REFERENCES iam.company(id),
  subscription_id  bigint NOT NULL REFERENCES bill.company_subscription(id),
  invoice_id       bigint NOT NULL REFERENCES bill.carrier_invoice(id),
  kind             text NOT NULL CHECK (kind IN ('INVOICE','TICKET','API_CALL','WHATSAPP','USER_SEAT')),
  qty              int NOT NULL CHECK (qty >= 0),
  period_start     date NOT NULL,
  UNIQUE (subscription_id, kind, period_start)
);
COMMENT ON TABLE bill.billed_usage IS 'What has already been billed of the overage, so usage is never billed twice';

-- ------------------------------ cash and payouts (6.5, 6.6) ------------------------------
CREATE TABLE IF NOT EXISTS fin.cash_remittance (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id     bigint NOT NULL REFERENCES iam.company(id),
  amount         bigint NOT NULL CHECK (amount > 0),
  currency       char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  method         text NOT NULL CHECK (method IN ('BANK_DEPOSIT','CASH_OFFICE','EXCHANGE_HOUSE','OFFSET')),
  ref            text,
  ledger_txn_id  bigint REFERENCES fin.ledger_txn(id),
  recorded_by    bigint NOT NULL REFERENCES iam.app_user(id),
  reconciled_at  timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE fin.cash_remittance IS 'Cash collected by a carrier from cash sales and remitted to the platform (6.5)';

ALTER TABLE iam.company ADD COLUMN IF NOT EXISTS payout_bank_account_id bigint REFERENCES iam.bank_account(id);
COMMENT ON COLUMN iam.company.payout_bank_account_id IS 'Beneficiary account for scheduled payouts (bank_ref in 6.6)';

-- ------------------------------ float and liquidity (6.8 c) ------------------------------
CREATE TABLE IF NOT EXISTS fin.float_account (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bank_party_id    bigint NOT NULL REFERENCES iam.party(id),
  kind             text NOT NULL CHECK (kind IN ('CLIENT_POOL','OPERATING','TAX')),
  currency         char(3) NOT NULL REFERENCES ref.currency(code),
  account_ref      text NOT NULL,                                   -- masked bank account reference
  ledger_wallet_id bigint REFERENCES fin.wallet(id),                -- the ledger wallet it is matched with
  status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CLOSED')),
  UNIQUE (bank_party_id, account_ref)
);
COMMENT ON TABLE fin.float_account IS 'Bank accounts holding wallet funds, each matched by a ledger wallet (6.8 c)';

CREATE TABLE IF NOT EXISTS fin.deposit_placement (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id   bigint NOT NULL REFERENCES fin.float_account(id),
  product      text NOT NULL CHECK (product IN ('SWEEP','OVERNIGHT','7D','30D')),
  principal    bigint NOT NULL CHECK (principal > 0),
  rate_bp      int NOT NULL CHECK (rate_bp >= 0),                   -- return, Sharia-compliant product terms
  starts_on    date NOT NULL,
  matures_on   date NOT NULL,
  status       text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','MATURED','BROKEN')),
  CHECK (matures_on >= starts_on)
);
COMMENT ON TABLE fin.deposit_placement IS 'Maturity ladder of placements; client funds stay withdrawable at any time';

CREATE TABLE IF NOT EXISTS fin.float_report (
  report_date     date NOT NULL,
  currency        char(3) NOT NULL REFERENCES ref.currency(code),
  liabilities     bigint NOT NULL,
  assets          bigint NOT NULL,
  coverage_ratio  numeric(6,4) NOT NULL,
  liquid_ratio    numeric(6,4) NOT NULL,
  yield_accrued   bigint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (report_date, currency)
);
COMMENT ON TABLE fin.float_report IS 'Daily coverage of wallet liabilities by bank assets';

-- ------------------------------ isolation and privileges ------------------------------
DO $$ BEGIN
  PERFORM sys.rls_catalog('bill.plan');
  PERFORM sys.rls_split(t, 'sys.tenant_visible(company_id)', 'sys.ctx_is_platform()')
    FROM unnest(ARRAY['bill.carrier_agreement','bill.company_subscription','bill.carrier_invoice','bill.billed_usage']) t;
  PERFORM sys.rls_parent('bill.carrier_invoice_line', 'invoice_id', 'bill.carrier_invoice');
  PERFORM sys.rls_tenant('bill.usage_event');
  PERFORM sys.rls_tenant('fin.cash_remittance');
  PERFORM sys.rls_platform(t) FROM unnest(ARRAY['fin.float_account','fin.deposit_placement','fin.float_report']) t;
  PERFORM sys.grant_rw(ARRAY['bill.plan','bill.carrier_agreement','bill.company_subscription','bill.carrier_invoice',
    'bill.carrier_invoice_line','bill.billed_usage','fin.cash_remittance','fin.float_account','fin.deposit_placement','fin.float_report']);
  PERFORM sys.grant_append(ARRAY['bill.usage_event']);
END $$;

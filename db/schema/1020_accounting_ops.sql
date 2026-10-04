-- =====================================================================
-- 1020: simplified accounting operations (study 13.7)
--   Sales invoices with sequential numbering and their lines, credit notes, receipt and payment vouchers, agent
--   and office cash boxes with sessions, tax codes, and the sync jobs, export batches and conflicts of the
--   integration with external accounting systems. An empty company_id means the platform's own books.
-- =====================================================================

CREATE TABLE IF NOT EXISTS acct.tax_code (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint REFERENCES iam.company(id),
  code        text NOT NULL,
  name        text NOT NULL,
  rate        numeric(6,3) NOT NULL CHECK (rate BETWEEN 0 AND 100),
  account_id  bigint REFERENCES acct.gl_account(id),
  tax_rule_id bigint REFERENCES pricing.tax_rule(id),
  active      boolean NOT NULL DEFAULT true,
  UNIQUE NULLS NOT DISTINCT (company_id, code)
);
COMMENT ON TABLE acct.tax_code IS 'Tax code of the books, mapped to a GL account and to the pricing engine''s tax rule';

ALTER TABLE acct.cost_center ADD COLUMN IF NOT EXISTS trip_id bigint REFERENCES ops.trip(id);

CREATE TABLE IF NOT EXISTS acct.sales_invoice (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id           bigint REFERENCES iam.company(id),
  invoice_no           text NOT NULL,
  customer_party_id    bigint NOT NULL REFERENCES iam.party(id),
  issue_date           date NOT NULL,
  due_date             date,
  currency             char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  subtotal             bigint NOT NULL DEFAULT 0,
  tax                  bigint NOT NULL DEFAULT 0,
  total                bigint NOT NULL DEFAULT 0,
  source_type          text CHECK (source_type IN ('BOOKING','SHIPMENT','FREIGHT','CONTRACT','SUBSCRIPTION','MANUAL')),
  source_id            bigint,
  einvoice_document_id bigint REFERENCES acct.einvoice_document(id),
  journal_entry_id     bigint REFERENCES acct.journal_entry(id),
  status               text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ISSUED','PARTIALLY_PAID','PAID','CANCELLED')),
  created_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (company_id, invoice_no),
  CHECK (total = subtotal + tax),
  CHECK (due_date IS NULL OR due_date >= issue_date)
);
COMMENT ON TABLE acct.sales_invoice IS 'Sales invoice of the books with gapless numbering per company; linked to its e-invoice when one is required';

CREATE TABLE IF NOT EXISTS acct.sales_invoice_line (
  invoice_id     bigint NOT NULL REFERENCES acct.sales_invoice(id) ON DELETE CASCADE,
  line_no        smallint NOT NULL,
  description    text NOT NULL,
  qty            numeric(12,3) NOT NULL DEFAULT 1,
  unit_price     bigint NOT NULL,
  tax_code_id    bigint REFERENCES acct.tax_code(id),
  tax_amount     bigint NOT NULL DEFAULT 0,
  amount         bigint NOT NULL,
  account_id     bigint REFERENCES acct.gl_account(id),
  cost_center_id bigint REFERENCES acct.cost_center(id),
  PRIMARY KEY (invoice_id, line_no)
);

CREATE TABLE IF NOT EXISTS acct.credit_note (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id           bigint REFERENCES iam.company(id),
  credit_no            text NOT NULL,
  invoice_id           bigint NOT NULL REFERENCES acct.sales_invoice(id),
  reason               text NOT NULL,
  amount               bigint NOT NULL CHECK (amount > 0),
  tax                  bigint NOT NULL DEFAULT 0,
  einvoice_document_id bigint REFERENCES acct.einvoice_document(id),
  status               text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ISSUED','APPLIED','CANCELLED')),
  created_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (company_id, credit_no)
);
COMMENT ON TABLE acct.credit_note IS 'The only way to reduce an issued invoice (refunds); goes through e-invoicing like the invoice';

CREATE TABLE IF NOT EXISTS acct.cash_box (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id      bigint REFERENCES iam.company(id),
  owner_party_id  bigint NOT NULL REFERENCES iam.party(id),            -- the agent or office responsible
  station_id      bigint REFERENCES net.station(id),
  currency        char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  account_id      bigint REFERENCES acct.gl_account(id),
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CLOSED'))
);

CREATE TABLE IF NOT EXISTS acct.cash_session (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cash_box_id       bigint NOT NULL REFERENCES acct.cash_box(id),
  opened_by         bigint NOT NULL REFERENCES iam.app_user(id),
  opened_at         timestamptz NOT NULL DEFAULT now(),
  opening_amount    bigint NOT NULL DEFAULT 0,
  closed_at         timestamptz,
  closing_amount    bigint,
  expected_amount   bigint,
  variance          bigint GENERATED ALWAYS AS (closing_amount - expected_amount) STORED,
  handed_over_at    timestamptz,
  handed_over_to    bigint REFERENCES iam.app_user(id),
  status            text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED','HANDED_OVER','RECONCILED'))
);
CREATE UNIQUE INDEX IF NOT EXISTS cash_session_one_open ON acct.cash_session (cash_box_id) WHERE status = 'OPEN';
COMMENT ON TABLE acct.cash_session IS 'A shift of a cash box: opening, closing, variance and hand-over';

CREATE TABLE IF NOT EXISTS acct.cash_receipt (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id       bigint REFERENCES iam.company(id),
  receipt_no       text NOT NULL,
  method           text NOT NULL CHECK (method IN ('CASH','WALLET','BANK','CARD')),
  cash_session_id  bigint REFERENCES acct.cash_session(id),
  wallet_id        bigint REFERENCES fin.wallet(id),
  bank_account_id  bigint REFERENCES iam.bank_account(id),
  party_id         bigint NOT NULL REFERENCES iam.party(id),
  invoice_id       bigint REFERENCES acct.sales_invoice(id),
  amount           bigint NOT NULL CHECK (amount > 0),
  currency         char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  ref              text,
  receipt_date     date NOT NULL DEFAULT current_date,
  journal_entry_id bigint REFERENCES acct.journal_entry(id),
  UNIQUE NULLS NOT DISTINCT (company_id, receipt_no),
  CHECK (method <> 'CASH' OR cash_session_id IS NOT NULL),
  CHECK (method <> 'WALLET' OR wallet_id IS NOT NULL),
  CHECK (method <> 'BANK' OR bank_account_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS acct.cash_payment (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id       bigint REFERENCES iam.company(id),
  voucher_no       text NOT NULL,
  method           text NOT NULL CHECK (method IN ('CASH','WALLET','BANK')),
  cash_session_id  bigint REFERENCES acct.cash_session(id),
  wallet_id        bigint REFERENCES fin.wallet(id),
  bank_account_id  bigint REFERENCES iam.bank_account(id),
  party_id         bigint NOT NULL REFERENCES iam.party(id),
  amount           bigint NOT NULL CHECK (amount > 0),
  currency         char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  purpose          text NOT NULL,
  account_id       bigint REFERENCES acct.gl_account(id),
  payment_date     date NOT NULL DEFAULT current_date,
  approved_by      bigint REFERENCES iam.app_user(id),
  journal_entry_id bigint REFERENCES acct.journal_entry(id),
  UNIQUE NULLS NOT DISTINCT (company_id, voucher_no),
  CHECK (method <> 'CASH' OR cash_session_id IS NOT NULL)
);

-- ------------------------------ integration with accounting systems (13.10) ------------------------------
CREATE TABLE IF NOT EXISTS acct.sync_job (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  connection_id  bigint NOT NULL REFERENCES acct.accounting_connection(id),
  batch_ref      text NOT NULL,
  started_at     timestamptz NOT NULL DEFAULT now(),
  finished_at    timestamptz,
  items_total    int NOT NULL DEFAULT 0,
  items_failed   int NOT NULL DEFAULT 0,
  status         text NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','COMPLETED','PARTIAL','FAILED')),
  UNIQUE (connection_id, batch_ref)
);
ALTER TABLE acct.sync_item ADD COLUMN IF NOT EXISTS job_id bigint REFERENCES acct.sync_job(id);

CREATE TABLE IF NOT EXISTS acct.sync_conflict (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  item_id        bigint NOT NULL REFERENCES acct.sync_item(id),
  conflict_type  text NOT NULL CHECK (conflict_type IN ('CHANGED_BOTH_SIDES','MISSING_EXTERNAL','MAPPING_MISSING','VALUE_MISMATCH')),
  detail         jsonb NOT NULL DEFAULT '{}',
  resolution     text CHECK (resolution IN ('KEEP_LOCAL','KEEP_EXTERNAL','MANUAL')),
  resolved_by    bigint REFERENCES iam.app_user(id),
  resolved_at    timestamptz
);

CREATE TABLE IF NOT EXISTS acct.export_batch (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id   bigint REFERENCES iam.company(id),
  format       text NOT NULL CHECK (format IN ('CSV','XLSX','XML','JSON','SAF_T')),
  period       daterange NOT NULL,
  file_id      bigint REFERENCES ref.file_object(id),
  checksum     text,
  created_by   bigint REFERENCES iam.app_user(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE acct.export_batch IS 'File export of the books for systems without an API, with its checksum';

-- ------------------------------ isolation and privileges ------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['acct.tax_code','acct.sales_invoice','acct.credit_note','acct.cash_box','acct.cash_receipt',
                           'acct.cash_payment','acct.export_batch'] LOOP
    -- same rule as the existing books: platform books (empty company) for the platform only
    PERFORM sys.rls(t, 'sys.ctx_is_platform() OR company_id = sys.ctx_company_id()', NULL, 'books_isolation');
  END LOOP;
  PERFORM sys.rls_parent('acct.sales_invoice_line', 'invoice_id', 'acct.sales_invoice');
  PERFORM sys.rls_parent('acct.cash_session', 'cash_box_id', 'acct.cash_box');
  PERFORM sys.rls_parent('acct.sync_job', 'connection_id', 'acct.accounting_connection');
  PERFORM sys.rls('acct.sync_conflict', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM acct.sync_item i
    JOIN acct.accounting_connection c ON c.id = i.connection_id WHERE i.id = sync_conflict.item_id)');
  PERFORM sys.grant_rw(ARRAY['acct.tax_code','acct.sales_invoice','acct.sales_invoice_line','acct.credit_note','acct.cash_box',
    'acct.cash_session','acct.cash_receipt','acct.cash_payment','acct.sync_job','acct.sync_conflict','acct.export_batch']);
END $$;
REVOKE DELETE ON acct.sales_invoice, acct.credit_note, acct.cash_receipt, acct.cash_payment FROM masslak_app;

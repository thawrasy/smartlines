-- =====================================================================
-- 080: simplified accounting, accounting integration hub, e-invoicing and tax profiles
-- Source: 13.2 to 13.7, 13.11 to 13.14
-- E-invoice: draft -> finalized after payment (gapless number + chained hash + QR)
--   -> submitted to the authority -> confirmed (fully locked). No updates, no deletes; cancellation only by a linked credit note.
-- =====================================================================

-- ------------------------------ Chart of accounts and journal entries ----------------
CREATE TABLE acct.gl_account (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint REFERENCES iam.company(id),    -- empty = platform books
  code          text NOT NULL,
  name          text NOT NULL,
  account_type  text NOT NULL CHECK (account_type IN ('ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE')),
  parent_id     bigint REFERENCES acct.gl_account(id),
  currency      char(3) REFERENCES ref.currency(code),
  is_postable   boolean NOT NULL DEFAULT true,
  external_code text,
  active        boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX gl_account_code_uq ON acct.gl_account (coalesce(company_id, 0), code);
COMMENT ON TABLE acct.gl_account IS 'Simplified chart of accounts per book (platform or company) from an editable template (13.3)';

CREATE TABLE acct.gl_period (
  company_id  bigint REFERENCES iam.company(id),
  period      date NOT NULL,                          -- first day of the month
  status      text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED')),
  closed_by   bigint REFERENCES iam.app_user(id),
  closed_at   timestamptz
);
CREATE UNIQUE INDEX gl_period_uq ON acct.gl_period (coalesce(company_id, 0), period);

CREATE TABLE acct.cost_center (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint REFERENCES iam.company(id),
  code        text NOT NULL,
  name        text NOT NULL,
  route_id    bigint REFERENCES net.route(id),
  station_id  bigint REFERENCES net.station(id)
);
CREATE UNIQUE INDEX cost_center_code_uq ON acct.cost_center (coalesce(company_id, 0), code);

CREATE TABLE acct.posting_rule (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_type      text NOT NULL,                      -- booking.paid, trip.completed, refund.paid ...
  condition       jsonb NOT NULL DEFAULT '{}',
  lines_template  jsonb NOT NULL,
  version         int NOT NULL DEFAULT 1,
  active          boolean NOT NULL DEFAULT true,
  created_by      bigint REFERENCES iam.app_user(id),
  approved_by     bigint REFERENCES iam.app_user(id),
  UNIQUE (event_type, version),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);
COMMENT ON TABLE acct.posting_rule IS 'Posting rules: events become journal entries; no module writes to the ledger directly (13.4)';

CREATE TABLE acct.journal_entry (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id      bigint REFERENCES iam.company(id),
  entry_no        text NOT NULL,
  entry_date      date NOT NULL,
  source_type     text NOT NULL,                      -- LEDGER_TXN, EINVOICE, MANUAL, DAILY_SUMMARY
  source_id       bigint,
  posting_rule_id bigint REFERENCES acct.posting_rule(id),
  currency        char(3) NOT NULL REFERENCES ref.currency(code),
  fx_rate         numeric(20,10) NOT NULL DEFAULT 1,
  memo            text,
  status          text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','POSTED','REVERSED')),
  reversed_by_id  bigint REFERENCES acct.journal_entry(id),
  created_by      bigint REFERENCES iam.app_user(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  posted_at       timestamptz
);
CREATE UNIQUE INDEX journal_entry_no_uq ON acct.journal_entry (coalesce(company_id, 0), entry_no);
CREATE INDEX journal_entry_source_idx ON acct.journal_entry (source_type, source_id);
COMMENT ON TABLE acct.journal_entry IS 'Journal entry; after posting it is never modified, corrections by reversing entry';

CREATE TABLE acct.journal_line (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entry_id        bigint NOT NULL REFERENCES acct.journal_entry(id),
  account_id      bigint NOT NULL REFERENCES acct.gl_account(id),
  party_id        bigint REFERENCES iam.party(id),
  cost_center_id  bigint REFERENCES acct.cost_center(id),
  debit           bigint NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit          bigint NOT NULL DEFAULT 0 CHECK (credit >= 0),
  amount_fc       bigint,
  memo            text,
  CHECK ((debit = 0) <> (credit = 0))
);
CREATE INDEX journal_line_entry_idx ON acct.journal_line (entry_id);
CREATE INDEX journal_line_account_idx ON acct.journal_line (account_id);

CREATE OR REPLACE FUNCTION acct.tg_journal_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE d bigint; c bigint;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'DRAFT' THEN RAISE EXCEPTION 'IMMUTABLE_RECORD: posted journal entry' USING ERRCODE = 'P0001'; END IF;
    RETURN OLD;
  END IF;
  IF OLD.status = 'POSTED' THEN
    IF NOT (NEW.status = 'REVERSED' AND NEW.reversed_by_id IS NOT NULL
            AND (to_jsonb(NEW) - 'status' - 'reversed_by_id') = (to_jsonb(OLD) - 'status' - 'reversed_by_id')) THEN
      RAISE EXCEPTION 'IMMUTABLE_RECORD: posted journal entry' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.status = 'REVERSED' THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: reversed journal entry' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'POSTED' AND OLD.status = 'DRAFT' THEN
    IF EXISTS (SELECT 1 FROM acct.gl_period p WHERE coalesce(p.company_id,0) = coalesce(NEW.company_id,0)
                AND p.period = date_trunc('month', NEW.entry_date)::date AND p.status = 'CLOSED') THEN
      RAISE EXCEPTION 'PERIOD_CLOSED' USING ERRCODE = 'P0001';
    END IF;
    SELECT coalesce(sum(debit),0), coalesce(sum(credit),0) INTO d, c FROM acct.journal_line WHERE entry_id = NEW.id;
    IF d <> c OR d = 0 THEN RAISE EXCEPTION 'UNBALANCED_ENTRY: D=% C=%', d, c USING ERRCODE = 'P0001'; END IF;
    NEW.posted_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER journal_guard BEFORE UPDATE OR DELETE ON acct.journal_entry FOR EACH ROW EXECUTE FUNCTION acct.tg_journal_guard();

CREATE OR REPLACE FUNCTION acct.tg_journal_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE st text;
BEGIN
  SELECT status INTO st FROM acct.journal_entry WHERE id = coalesce(NEW.entry_id, OLD.entry_id);
  IF st <> 'DRAFT' THEN RAISE EXCEPTION 'IMMUTABLE_RECORD: lines of posted entry' USING ERRCODE = 'P0001'; END IF;
  RETURN coalesce(NEW, OLD);
END $$;
CREATE TRIGGER journal_line_guard BEFORE INSERT OR UPDATE OR DELETE ON acct.journal_line FOR EACH ROW EXECUTE FUNCTION acct.tg_journal_line_guard();

-- ------------------------------ Accounting integration hub (13.5) ----------
CREATE TABLE acct.accounting_connection (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id      bigint REFERENCES iam.company(id),
  system_type     text NOT NULL CHECK (system_type IN ('ODOO','ZOHO','D365','SAP','ORACLE','ALAMEEN','FILE','API')),
  credentials_ref text,                               -- vault reference, not the secret itself
  settings        jsonb NOT NULL DEFAULT '{}',
  mode            text NOT NULL DEFAULT 'DAILY' CHECK (mode IN ('REALTIME','DAILY','FILE')),
  status          text NOT NULL DEFAULT 'INACTIVE' CHECK (status IN ('ACTIVE','INACTIVE','ERROR')),
  created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE acct.accounting_connection IS 'Link between the platform or a company and an external accounting system (Odoo, Zoho, Al-Ameen, file, API)';

CREATE TABLE acct.account_mapping (
  connection_id bigint NOT NULL REFERENCES acct.accounting_connection(id) ON DELETE CASCADE,
  local_type    text NOT NULL CHECK (local_type IN ('GL_ACCOUNT','PARTY','TAX_CODE','COST_CENTER')),
  local_id      bigint NOT NULL,
  external_id   text NOT NULL,
  external_name text,
  PRIMARY KEY (connection_id, local_type, local_id)
);

CREATE TABLE acct.sync_item (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  connection_id bigint NOT NULL REFERENCES acct.accounting_connection(id),
  batch_ref     text NOT NULL,
  item_type     text NOT NULL CHECK (item_type IN ('JOURNAL','INVOICE','CREDIT_NOTE','PAYMENT','PARTY','TAX_RETURN')),
  local_id      bigint NOT NULL,
  external_id   text,
  idempotency_key text NOT NULL UNIQUE,
  status        text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','CONFIRMED','FAILED','CONFLICT')),
  attempts      int NOT NULL DEFAULT 0,
  error         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  sent_at       timestamptz
);
CREATE INDEX sync_item_pending ON acct.sync_item (connection_id) WHERE status IN ('PENDING','FAILED');
COMMENT ON TABLE acct.sync_item IS 'Log of journal entries and invoices pushed to the external system via API, with retries and deduplication (13.12)';

-- ------------------------------ Tax authority and tax profile (13.11) -
CREATE TABLE acct.tax_authority (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code                  text NOT NULL UNIQUE,
  country_code          char(2) NOT NULL REFERENCES ref.country(code),
  name                  text NOT NULL,
  regime                text NOT NULL DEFAULT 'GENERATION' CHECK (regime IN ('GENERATION','REPORTING','CLEARANCE')),
  report_deadline_hours int,
  api_base              text,
  status                text NOT NULL DEFAULT 'INACTIVE' CHECK (status IN ('ACTIVE','INACTIVE'))
);
COMMENT ON TABLE acct.tax_authority IS 'Tax authority and its adapter: generation mode before integration, then reporting or clearance';

CREATE TABLE acct.einvoice_template (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  authority_id  bigint NOT NULL REFERENCES acct.tax_authority(id),
  version       int NOT NULL,
  fields        jsonb NOT NULL,
  qr_encoding   text NOT NULL DEFAULT 'TLV_BASE64',
  xml_schema_ref text,
  valid_from    timestamptz NOT NULL,
  UNIQUE (authority_id, version)
);

CREATE TABLE acct.einvoice_activation (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  authority_id      bigint NOT NULL REFERENCES acct.tax_authority(id),
  doc_type          text NOT NULL CHECK (doc_type IN ('INVOICE','CREDIT_NOTE','DEBIT_NOTE','*')),
  taxpayer_category text NOT NULL DEFAULT '*',
  mandatory_from    timestamptz NOT NULL,
  mode              text NOT NULL CHECK (mode IN ('GENERATION','REPORTING','CLEARANCE')),
  active            boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE acct.einvoice_activation IS 'Phased mandate activation per taxpayer category, document type and date';

CREATE TABLE acct.tax_profile (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  party_id            bigint NOT NULL REFERENCES iam.party(id),
  authority_id        bigint REFERENCES acct.tax_authority(id),
  tax_status          text NOT NULL CHECK (tax_status IN ('REGISTERED','UNREGISTERED','EXEMPT','FLAT','NON_RESIDENT')),
  tax_no              text,
  cr_no               text,
  branch_code         text,
  legal_name          text NOT NULL,
  einvoice_mandatory  boolean NOT NULL DEFAULT false,
  issuer_mode         text NOT NULL DEFAULT 'PLATFORM' CHECK (issuer_mode IN ('PLATFORM','OWN_SYSTEM')),
  verified_source     text NOT NULL DEFAULT 'MANUAL' CHECK (verified_source IN ('MANUAL','GOV')),
  approved_by         bigint REFERENCES iam.app_user(id),
  valid               tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (tax_status <> 'REGISTERED' OR tax_no IS NOT NULL),
  EXCLUDE USING gist (party_id WITH =, valid WITH &&)
);
COMMENT ON TABLE acct.tax_profile IS 'Tax profile of each company, owner or partner, with non-overlapping time versions';

CREATE TABLE acct.tax_profile_field (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  country_code  char(2) NOT NULL REFERENCES ref.country(code),
  authority_id  bigint REFERENCES acct.tax_authority(id),
  code          text NOT NULL,
  label         text NOT NULL,
  data_type     text NOT NULL CHECK (data_type IN ('TEXT','NUMBER','DATE','BOOL','FILE','CHOICE')),
  required      boolean NOT NULL DEFAULT false,
  validation    jsonb,
  UNIQUE (country_code, code)
);
CREATE TABLE acct.tax_profile_value (
  profile_id  bigint NOT NULL REFERENCES acct.tax_profile(id) ON DELETE CASCADE,
  field_id    bigint NOT NULL REFERENCES acct.tax_profile_field(id),
  value       jsonb NOT NULL,
  PRIMARY KEY (profile_id, field_id)
);
COMMENT ON TABLE acct.tax_profile_field IS 'Dynamic tax fields added by the administrator per country or authority without code changes';

CREATE TABLE acct.tax_registration (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  profile_id        bigint NOT NULL REFERENCES acct.tax_profile(id),
  tax_scheme_id     bigint NOT NULL REFERENCES pricing.tax_scheme(id),
  filing_frequency  text NOT NULL CHECK (filing_frequency IN ('MONTHLY','QUARTERLY','ANNUAL')),
  registered        daterange NOT NULL
);

-- ------------------------------ E-invoice -----------------
CREATE TABLE acct.einvoice_unit (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  profile_id      bigint NOT NULL REFERENCES acct.tax_profile(id),
  authority_id    bigint NOT NULL REFERENCES acct.tax_authority(id),
  unit_code       text NOT NULL,
  number_prefix   text NOT NULL,                      -- numbering prefix for the seller/unit
  certificate_ref text,                               -- authority certificate in the vault
  cert_expiry     timestamptz,
  signing_key_id  int REFERENCES sec.key_registry(id),
  counter_value   bigint NOT NULL DEFAULT 0,          -- counter that is never reset
  last_hash       text NOT NULL DEFAULT '0',          -- hash of the last invoice (chain)
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ONBOARDING','ACTIVE','SUSPENDED')),
  UNIQUE (authority_id, unit_code)
);
COMMENT ON TABLE acct.einvoice_unit IS 'Issuing unit per seller: counter, last invoice hash and certificate';

CREATE TABLE acct.einvoice_document (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uuid              uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  doc_type          text NOT NULL CHECK (doc_type IN ('INVOICE','CREDIT_NOTE','DEBIT_NOTE')),
  subtype           text NOT NULL CHECK (subtype IN ('STANDARD','SIMPLIFIED')),
  seller_profile_id bigint NOT NULL REFERENCES acct.tax_profile(id),
  unit_id           bigint NOT NULL REFERENCES acct.einvoice_unit(id),
  company_id        bigint REFERENCES iam.company(id),  -- for tenant isolation
  buyer_party_id    bigint REFERENCES iam.party(id),
  buyer_tax_no      text,
  source_type       text NOT NULL CHECK (source_type IN ('BOOKING','TICKET','SHIPMENT','SUBSCRIPTION','COMMISSION','REFUND','OTHER')),
  source_id         bigint NOT NULL,
  original_doc_id   bigint REFERENCES acct.einvoice_document(id),
  reason_code       text,
  currency          char(3) NOT NULL REFERENCES ref.currency(code),
  subtotal          bigint NOT NULL DEFAULT 0,
  tax_total         bigint NOT NULL DEFAULT 0,
  total             bigint NOT NULL DEFAULT 0 CHECK (total >= 0),
  number            text,
  counter_value     bigint,
  previous_hash     text,
  hash              text,
  signature         text,
  qr_payload        text,
  xml_file_id       bigint REFERENCES ref.file_object(id),
  pdf_file_id       bigint REFERENCES ref.file_object(id),
  status            text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','CANCELLED_DRAFT','FINALIZED','SUBMITTED','CLEARED','REPORTED','ACCEPTED_WITH_WARNINGS','REJECTED')),
  authority_ref     text,
  finalized_at      timestamptz,
  confirmed_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (doc_type = 'INVOICE' OR original_doc_id IS NOT NULL),
  CHECK (subtype = 'SIMPLIFIED' OR buyer_tax_no IS NOT NULL),
  CHECK (status IN ('DRAFT','CANCELLED_DRAFT') OR (number IS NOT NULL AND hash IS NOT NULL AND qr_payload IS NOT NULL AND finalized_at IS NOT NULL)),
  CHECK (total = subtotal + tax_total)
);
CREATE UNIQUE INDEX einvoice_number_uq ON acct.einvoice_document (unit_id, number) WHERE number IS NOT NULL;
CREATE INDEX einvoice_source_idx ON acct.einvoice_document (source_type, source_id);
CREATE INDEX einvoice_pending_idx ON acct.einvoice_document (finalized_at) WHERE status IN ('FINALIZED','SUBMITTED');
COMMENT ON TABLE acct.einvoice_document IS 'Invoice, credit note and debit note; after finalization only the status and the authority''s response may change, and deletion is never allowed';

CREATE OR REPLACE FUNCTION acct.tg_einvoice_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: e-invoice documents are never deleted' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.status NOT IN ('DRAFT') THEN
    IF (to_jsonb(NEW) - 'status' - 'authority_ref' - 'confirmed_at')
       IS DISTINCT FROM (to_jsonb(OLD) - 'status' - 'authority_ref' - 'confirmed_at') THEN
      RAISE EXCEPTION 'IMMUTABLE_RECORD: finalized e-invoice content cannot change' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'DRAFT'     AND NEW.status IN ('FINALIZED','CANCELLED_DRAFT')) OR
       (OLD.status = 'FINALIZED' AND NEW.status = 'SUBMITTED') OR
       (OLD.status = 'SUBMITTED' AND NEW.status IN ('CLEARED','REPORTED','ACCEPTED_WITH_WARNINGS','REJECTED','SUBMITTED'))) THEN
    RAISE EXCEPTION 'INVALID_TRANSITION: e-invoice % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER einvoice_guard BEFORE UPDATE OR DELETE ON acct.einvoice_document FOR EACH ROW EXECUTE FUNCTION acct.tg_einvoice_guard();

CREATE TABLE acct.einvoice_line (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  document_id         bigint NOT NULL REFERENCES acct.einvoice_document(id),
  line_no             smallint NOT NULL,
  description         text NOT NULL,
  qty                 numeric(12,3) NOT NULL DEFAULT 1,
  unit_price          bigint NOT NULL,
  discount            bigint NOT NULL DEFAULT 0,
  net_amount          bigint NOT NULL,
  tax_scheme_id       bigint REFERENCES pricing.tax_scheme(id),
  treatment           text NOT NULL DEFAULT 'STANDARD' CHECK (treatment IN ('STANDARD','ZERO','EXEMPT','OUT_OF_SCOPE','REVERSE')),
  tax_rate            numeric(9,6) NOT NULL DEFAULT 0,
  tax_amount          bigint NOT NULL DEFAULT 0,
  allocation_line_id  bigint REFERENCES fin.price_allocation_line(id),
  UNIQUE (document_id, line_no)
);

CREATE OR REPLACE FUNCTION acct.tg_einvoice_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE st text;
BEGIN
  SELECT status INTO st FROM acct.einvoice_document WHERE id = coalesce(NEW.document_id, OLD.document_id);
  IF st <> 'DRAFT' THEN RAISE EXCEPTION 'IMMUTABLE_RECORD: lines of finalized e-invoice' USING ERRCODE = 'P0001'; END IF;
  RETURN coalesce(NEW, OLD);
END $$;
CREATE TRIGGER einvoice_line_guard BEFORE INSERT OR UPDATE OR DELETE ON acct.einvoice_line FOR EACH ROW EXECUTE FUNCTION acct.tg_einvoice_line_guard();

-- Finalization: gapless number and chained hash (the unit row lock prevents races)
CREATE OR REPLACE FUNCTION acct.finalize_einvoice(
  p_document_id bigint, p_hash text, p_signature text, p_qr_payload text,
  p_xml_file_id bigint DEFAULT NULL, p_pdf_file_id bigint DEFAULT NULL
) RETURNS acct.einvoice_document LANGUAGE plpgsql AS $$
DECLARE d acct.einvoice_document; u acct.einvoice_unit; credited bigint; orig_total bigint;
BEGIN
  SELECT * INTO d FROM acct.einvoice_document WHERE id = p_document_id FOR UPDATE;
  IF d.status <> 'DRAFT' THEN RAISE EXCEPTION 'INVALID_TRANSITION: not a draft' USING ERRCODE = 'P0001'; END IF;
  IF d.doc_type = 'CREDIT_NOTE' THEN
    SELECT total INTO orig_total FROM acct.einvoice_document WHERE id = d.original_doc_id;
    SELECT coalesce(sum(total), 0) INTO credited FROM acct.einvoice_document
      WHERE original_doc_id = d.original_doc_id AND doc_type = 'CREDIT_NOTE'
        AND status NOT IN ('DRAFT','CANCELLED_DRAFT','REJECTED');
    IF credited + d.total > orig_total THEN
      RAISE EXCEPTION 'CREDIT_EXCEEDS_ORIGINAL: % + % > %', credited, d.total, orig_total USING ERRCODE = 'P0001';
    END IF;
  END IF;
  SELECT * INTO u FROM acct.einvoice_unit WHERE id = d.unit_id FOR UPDATE;
  UPDATE acct.einvoice_unit SET counter_value = counter_value + 1, last_hash = p_hash WHERE id = u.id;
  UPDATE acct.einvoice_document SET
    counter_value = u.counter_value + 1,
    number        = u.number_prefix || lpad((u.counter_value + 1)::text, 10, '0'),
    previous_hash = u.last_hash,
    hash = p_hash, signature = p_signature, qr_payload = p_qr_payload,
    xml_file_id = p_xml_file_id, pdf_file_id = p_pdf_file_id,
    status = 'FINALIZED', finalized_at = now()
  WHERE id = p_document_id RETURNING * INTO d;
  RETURN d;
END $$;
COMMENT ON FUNCTION acct.finalize_einvoice IS 'Finalizes the invoice after payment: gapless sequential number, hash linked to the previous one, signature and QR';

CREATE TABLE acct.einvoice_submission (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  document_id     bigint NOT NULL REFERENCES acct.einvoice_document(id),
  attempt         smallint NOT NULL,
  mode            text NOT NULL CHECK (mode IN ('REPORTING','CLEARANCE')),
  sent_at         timestamptz NOT NULL DEFAULT now(),
  response_status text,
  authority_ref   text,
  stamped_xml_file_id bigint REFERENCES ref.file_object(id),
  authority_qr    text,
  warnings        jsonb,
  errors          jsonb,
  UNIQUE (document_id, attempt)
);
CREATE TRIGGER einvoice_submission_immutable BEFORE UPDATE OR DELETE ON acct.einvoice_submission
  FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE acct.einvoice_submission IS 'Every submission attempt to the government authority and its response as received (append-only)';

ALTER TABLE sales.refund_request ADD CONSTRAINT refund_credit_note_fk FOREIGN KEY (credit_note_id) REFERENCES acct.einvoice_document(id);
ALTER TABLE sales.passenger_compensation ADD CONSTRAINT compensation_credit_note_fk FOREIGN KEY (credit_note_id) REFERENCES acct.einvoice_document(id);

-- ------------------------------ Tax returns and collections --------------------
CREATE TABLE acct.tax_return (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  profile_id    bigint NOT NULL REFERENCES acct.tax_profile(id),
  authority_id  bigint NOT NULL REFERENCES acct.tax_authority(id),
  tax_scheme_id bigint NOT NULL REFERENCES pricing.tax_scheme(id),
  period        daterange NOT NULL,
  status        text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','RECONCILED','SUBMITTED','PAID','AMENDED')),
  submitted_at  timestamptz,
  authority_ref text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (profile_id WITH =, tax_scheme_id WITH =, period WITH &&) WHERE (status <> 'AMENDED')
);
CREATE TABLE acct.tax_return_line (
  return_id   bigint NOT NULL REFERENCES acct.tax_return(id) ON DELETE CASCADE,
  box_code    text NOT NULL,
  amount      bigint NOT NULL,
  source_note text,
  PRIMARY KEY (return_id, box_code)
);
COMMENT ON TABLE acct.tax_return IS 'Draft tax return per taxpayer and period using the authority''s form boxes';

CREATE TABLE acct.tax_collection_no_file (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payer_party_id  bigint NOT NULL REFERENCES iam.party(id),
  tax_scheme_id   bigint NOT NULL REFERENCES pricing.tax_scheme(id),
  base            bigint NOT NULL,
  amount          bigint NOT NULL CHECK (amount >= 0),
  currency        char(3) NOT NULL REFERENCES ref.currency(code),
  source_type     text NOT NULL,
  source_id       bigint NOT NULL,
  receipt_no      text NOT NULL UNIQUE,
  remitted_payment_id bigint,
  created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE acct.tax_collection_no_file IS 'Taxes and fees collected from a party without a tax file (transit, flat-rate) with a collection receipt';

CREATE TABLE acct.tax_payment (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  profile_id    bigint REFERENCES acct.tax_profile(id),  -- empty = the platform acting as collection agent
  authority_id  bigint NOT NULL REFERENCES acct.tax_authority(id),
  tax_return_id bigint REFERENCES acct.tax_return(id),
  tax_scheme_id bigint NOT NULL REFERENCES pricing.tax_scheme(id),
  amount        bigint NOT NULL CHECK (amount > 0),
  currency      char(3) NOT NULL REFERENCES ref.currency(code),
  paid_at       timestamptz NOT NULL,
  ref           text,
  ledger_txn_id bigint REFERENCES fin.ledger_txn(id)
);
ALTER TABLE acct.tax_collection_no_file ADD CONSTRAINT tcnf_payment_fk FOREIGN KEY (remitted_payment_id) REFERENCES acct.tax_payment(id);

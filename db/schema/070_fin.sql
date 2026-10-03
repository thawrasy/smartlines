-- =====================================================================
-- 070: المحافظ والدفتر المزدوج والمدفوعات وتوزيع السعر والتسوية
-- المرجع: 4.7، 5.7، 5.8، 6.1 إلى 6.3، 6.6، 16.25
-- الثوابت المالية مفروضة في القاعدة نفسها:
--   (1) لكل قيد: مجموع المدين = مجموع الدائن (يُفحص عند الالتزام COMMIT)
--   (2) القيود لا تُعدَّل ولا تُحذف؛ التصحيح بقيد عكسي
--   (3) رصيد المحفظة يُحدَّث ذرياً ولا يصبح سالباً إلا لمحافظ المقاصة
--   (4) مجموع أوراق شجرة التوزيع = إجمالي السعر
-- =====================================================================

CREATE TABLE fin.wallet (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  owner_party_id  bigint REFERENCES iam.party(id),    -- فارغ لمحافظ المنصة الداخلية
  company_id      bigint REFERENCES iam.company(id),  -- لعزل المستأجر
  wallet_type     text NOT NULL CHECK (wallet_type IN ('USER','COMPANY','PLATFORM','ESCROW','COMMISSION','TAX','SPONSOR','GATEWAY_CLEARING','BANK_CLEARING','CASH_COLLECT','DEPOSIT','EXPENSE')),
  label           text,
  currency        char(3) NOT NULL REFERENCES ref.currency(code),
  balance         bigint NOT NULL DEFAULT 0,          -- رصيد مخزَّن = Σ دائن − Σ مدين
  hold_balance    bigint NOT NULL DEFAULT 0 CHECK (hold_balance >= 0),
  allow_negative  boolean NOT NULL DEFAULT false,     -- لمحافظ المقاصة فقط
  kyc_level       smallint NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (allow_negative OR balance >= 0),
  CHECK (allow_negative OR hold_balance <= balance)
);
CREATE UNIQUE INDEX wallet_owner_uq ON fin.wallet (owner_party_id, wallet_type, currency) WHERE owner_party_id IS NOT NULL;
CREATE INDEX wallet_company_idx ON fin.wallet (company_id);
COMMENT ON TABLE fin.wallet IS 'المحفظة: مستخدم، شركة، منصة، ضمان Escrow، عمولة، ضريبة، مقاصة؛ الرصيد يُطابَق مع القيود';

CREATE TABLE fin.ledger_txn (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  txn_type        text NOT NULL,                      -- TOPUP, BOOKING_PAY, RELEASE, REFUND, PAYOUT, FEE, REVERSAL ...
  currency        char(3) NOT NULL REFERENCES ref.currency(code),
  ref_type        text,
  ref_id          bigint,
  idempotency_key text NOT NULL UNIQUE,
  memo            text,
  reverses_txn_id bigint REFERENCES fin.ledger_txn(id),
  created_by      bigint REFERENCES iam.app_user(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ledger_txn_ref_idx ON fin.ledger_txn (ref_type, ref_id);
COMMENT ON TABLE fin.ledger_txn IS 'رأس القيد المالي؛ غير قابل للتعديل، ومفتاح عدم التكرار يمنع القيد المزدوج';

CREATE TABLE fin.ledger_entry (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  txn_id        bigint NOT NULL REFERENCES fin.ledger_txn(id),
  wallet_id     bigint NOT NULL REFERENCES fin.wallet(id),
  direction     char(2) NOT NULL CHECK (direction IN ('DR','CR')),
  amount        bigint NOT NULL CHECK (amount > 0),
  balance_after bigint,                               -- يُحسب آلياً
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ledger_entry_wallet_idx ON fin.ledger_entry (wallet_id, id);
CREATE INDEX ledger_entry_txn_idx ON fin.ledger_entry (txn_id);
COMMENT ON TABLE fin.ledger_entry IS 'سطر القيد (مدين/دائن)؛ إلحاق فقط، ويحدّث رصيد المحفظة ذرياً';

-- تحديث الرصيد ذرياً مع قفل صف المحفظة، وفحص العملة
CREATE OR REPLACE FUNCTION fin.tg_ledger_entry_apply() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE w fin.wallet%ROWTYPE; t_currency char(3); delta bigint;
BEGIN
  SELECT * INTO w FROM fin.wallet WHERE id = NEW.wallet_id FOR UPDATE;
  SELECT currency INTO t_currency FROM fin.ledger_txn WHERE id = NEW.txn_id;
  IF w.currency <> t_currency THEN
    RAISE EXCEPTION 'CURRENCY_MISMATCH: wallet % vs txn %', w.currency, t_currency USING ERRCODE = 'P0001';
  END IF;
  IF w.status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'WALLET_NOT_ACTIVE' USING ERRCODE = 'P0001';
  END IF;
  delta := CASE WHEN NEW.direction = 'CR' THEN NEW.amount ELSE -NEW.amount END;
  UPDATE fin.wallet SET balance = balance + delta WHERE id = NEW.wallet_id
    RETURNING balance INTO NEW.balance_after;            -- قيد CHECK على المحفظة يرفض الرصيد السالب
  RETURN NEW;
END $$;
CREATE TRIGGER ledger_entry_apply BEFORE INSERT ON fin.ledger_entry FOR EACH ROW EXECUTE FUNCTION fin.tg_ledger_entry_apply();

-- توازن القيد عند الالتزام (Deferred)
CREATE OR REPLACE FUNCTION fin.tg_ledger_txn_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE dr bigint; cr bigint; n int;
BEGIN
  SELECT coalesce(sum(amount) FILTER (WHERE direction = 'DR'), 0),
         coalesce(sum(amount) FILTER (WHERE direction = 'CR'), 0), count(*)
    INTO dr, cr, n FROM fin.ledger_entry WHERE txn_id = NEW.txn_id;
  IF dr <> cr OR n < 2 THEN
    RAISE EXCEPTION 'UNBALANCED_TXN: txn % DR=% CR=% lines=%', NEW.txn_id, dr, cr, n USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ledger_txn_balanced AFTER INSERT ON fin.ledger_entry
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fin.tg_ledger_txn_balanced();

CREATE TRIGGER ledger_txn_immutable   BEFORE UPDATE OR DELETE ON fin.ledger_txn   FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
CREATE TRIGGER ledger_entry_immutable BEFORE UPDATE OR DELETE ON fin.ledger_entry FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

-- ------------------------------ المدفوعات -----------------------------
CREATE TABLE fin.payment_provider (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('CARD','BANK','E_WALLET','CASH_AGENT')),
  config      jsonb NOT NULL DEFAULT '{}',            -- بلا أسرار
  fee_policy  jsonb NOT NULL DEFAULT '{}',            -- نسبة/ثابت/من يتحمل (5.11 ج)
  clearing_wallet_id bigint REFERENCES fin.wallet(id),
  status      text NOT NULL DEFAULT 'INACTIVE' CHECK (status IN ('ACTIVE','INACTIVE'))
);
COMMENT ON TABLE fin.payment_provider IS 'مزود الدفع بمحوّل موحد قابل للاستبدال';

CREATE TABLE fin.payment (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  provider_id     bigint NOT NULL REFERENCES fin.payment_provider(id),
  purpose         text NOT NULL CHECK (purpose IN ('TOPUP','BOOKING','SUBSCRIPTION','OTHER')),
  booking_id      bigint REFERENCES sales.booking(id),
  payer_party_id  bigint NOT NULL REFERENCES iam.party(id),
  wallet_id       bigint REFERENCES fin.wallet(id),
  method          text NOT NULL CHECK (method IN ('CARD','BANK','E_WALLET','CASH')),
  currency        char(3) NOT NULL REFERENCES ref.currency(code),
  amount          bigint NOT NULL CHECK (amount > 0),
  fee             bigint NOT NULL DEFAULT 0,
  platform_fee    bigint NOT NULL DEFAULT 0,
  provider_ref    text,
  idempotency_key text NOT NULL UNIQUE,
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SUCCESS','FAILED','REFUNDED')),
  ledger_txn_id   bigint REFERENCES fin.ledger_txn(id),
  card_last4      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  settled_at      timestamptz,
  UNIQUE (provider_id, provider_ref),
  CHECK (status <> 'SUCCESS' OR ledger_txn_id IS NOT NULL)
);
CREATE INDEX payment_booking_idx ON fin.payment (booking_id);
COMMENT ON TABLE fin.payment IS 'الدفعة؛ لا تصبح SUCCESS إلا بإشعار موقّع من البوابة وقيد في الدفتر (16.25)';

CREATE OR REPLACE FUNCTION fin.tg_payment_transition() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'PENDING' AND NEW.status IN ('SUCCESS','FAILED')) OR
       (OLD.status = 'SUCCESS' AND NEW.status = 'REFUNDED')) THEN
    RAISE EXCEPTION 'INVALID_TRANSITION: payment % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
  END IF;
  IF OLD.status <> 'PENDING' AND (NEW.amount <> OLD.amount OR NEW.currency <> OLD.currency) THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: settled payment amount' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER payment_transition BEFORE UPDATE ON fin.payment FOR EACH ROW EXECUTE FUNCTION fin.tg_payment_transition();

CREATE TABLE fin.payment_notification (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider_id     bigint NOT NULL REFERENCES fin.payment_provider(id),
  event_id        text NOT NULL,
  payment_id      bigint REFERENCES fin.payment(id),
  signature_valid boolean NOT NULL,
  source_ip       inet,
  payload         jsonb NOT NULL,
  received_at     timestamptz NOT NULL DEFAULT now(),
  processed_at    timestamptz,
  UNIQUE (provider_id, event_id)
);
CREATE TRIGGER payment_notification_immutable BEFORE DELETE ON fin.payment_notification
  FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE fin.payment_notification IS 'إشعارات البوابة الموقّعة كما وردت (مرجع حالة الدفع، ومنع التكرار)';

CREATE TABLE fin.bank_transfer_topup (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  wallet_id   bigint NOT NULL REFERENCES fin.wallet(id),
  virtual_ref text NOT NULL UNIQUE,
  bank_ref    text,
  amount      bigint CHECK (amount > 0),
  status      text NOT NULL DEFAULT 'AWAITING' CHECK (status IN ('AWAITING','MATCHED','REJECTED')),
  matched_at  timestamptz,
  ledger_txn_id bigint REFERENCES fin.ledger_txn(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE fin.bank_transfer_topup IS 'شحن المحفظة بتحويل بنكي بمرجع فريد ومطابقة تلقائية';

CREATE TABLE fin.withdrawal_request (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  wallet_id       bigint NOT NULL REFERENCES fin.wallet(id),
  bank_account_id bigint NOT NULL REFERENCES iam.bank_account(id),
  amount          bigint NOT NULL CHECK (amount > 0),
  status          text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','APPROVED','REJECTED','PAID','FAILED')),
  requested_by    bigint NOT NULL REFERENCES iam.app_user(id),
  approved_by     bigint REFERENCES iam.app_user(id),
  second_approver bigint REFERENCES iam.app_user(id),   -- للمبالغ فوق الحد (موافقتان)
  ledger_txn_id   bigint REFERENCES fin.ledger_txn(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  decided_at      timestamptz,
  CHECK (approved_by IS NULL OR approved_by <> requested_by),
  CHECK (second_approver IS NULL OR (second_approver <> requested_by AND second_approver <> approved_by))
);
COMMENT ON TABLE fin.withdrawal_request IS 'طلب السحب بحدود ومراجعة وموافقتين للمبالغ الكبيرة';

-- ------------------------------ توزيع السعر (5.7) -------------------
CREATE TABLE fin.price_allocation (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  subject_type  text NOT NULL CHECK (subject_type IN ('BOOKING','TICKET','SHIPMENT','FREIGHT_LEG','SUBSCRIPTION')),
  subject_id    bigint NOT NULL,
  booking_id    bigint REFERENCES sales.booking(id),
  currency      char(3) NOT NULL REFERENCES ref.currency(code),
  total         bigint NOT NULL CHECK (total >= 0),
  template_id   bigint REFERENCES pricing.allocation_template(id),
  rules_version text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (subject_type, subject_id)
);
ALTER TABLE sales.booking ADD CONSTRAINT booking_allocation_fk FOREIGN KEY (price_allocation_id) REFERENCES fin.price_allocation(id);
COMMENT ON TABLE fin.price_allocation IS 'رأس شجرة توزيع السعر لكل حجز أو تذكرة أو شحنة';

CREATE TABLE fin.price_allocation_line (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  allocation_id         bigint NOT NULL REFERENCES fin.price_allocation(id),
  code                  text NOT NULL,
  level                 smallint NOT NULL,
  parent_line_id        bigint REFERENCES fin.price_allocation_line(id),
  is_leaf               boolean NOT NULL,
  component_type        text NOT NULL,
  beneficiary_party_id  bigint REFERENCES iam.party(id),
  tax_scheme_id         bigint REFERENCES pricing.tax_scheme(id),
  commission_scheme_id  bigint REFERENCES pricing.commission_scheme(id),
  basis                 text NOT NULL,
  rate                  numeric(18,6),
  amount                bigint NOT NULL,              -- قد يكون سالباً للخصم
  wallet_id             bigint REFERENCES fin.wallet(id),
  release_event         text NOT NULL,
  released_at           timestamptz,
  refunded_amount       bigint NOT NULL DEFAULT 0,
  status                text NOT NULL DEFAULT 'HELD' CHECK (status IN ('HELD','RELEASED','REFUNDED','PARTIAL_REFUND')),
  UNIQUE (allocation_id, code)
);
COMMENT ON TABLE fin.price_allocation_line IS 'أسطر الشجرة: أجرة، ضريبة، عمولة، رسم، خصم؛ كل ورقة تُحرَّر لمحفظة مستفيدها عند حدثها';

CREATE OR REPLACE FUNCTION fin.tg_allocation_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s bigint; t bigint;
BEGIN
  SELECT coalesce(sum(amount), 0) INTO s FROM fin.price_allocation_line WHERE allocation_id = NEW.allocation_id AND is_leaf;
  SELECT total INTO t FROM fin.price_allocation WHERE id = NEW.allocation_id;
  IF s <> t THEN
    RAISE EXCEPTION 'ALLOCATION_MISMATCH: allocation % leaves=% total=%', NEW.allocation_id, s, t USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER allocation_balanced AFTER INSERT OR UPDATE OF amount ON fin.price_allocation_line
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fin.tg_allocation_balanced();

CREATE TABLE fin.tax_ledger (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jurisdiction_id     bigint NOT NULL REFERENCES pricing.jurisdiction(id),
  tax_scheme_id       bigint NOT NULL REFERENCES pricing.tax_scheme(id),
  company_id          bigint REFERENCES iam.company(id),
  period              date NOT NULL,                  -- أول يوم في الشهر
  direction           text NOT NULL CHECK (direction IN ('COLLECTED','REFUNDED')),
  currency            char(3) NOT NULL REFERENCES ref.currency(code),
  base                bigint NOT NULL,
  tax                 bigint NOT NULL,
  allocation_line_id  bigint REFERENCES fin.price_allocation_line(id),
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX tax_ledger_period_idx ON fin.tax_ledger (tax_scheme_id, period);
CREATE TRIGGER tax_ledger_immutable BEFORE UPDATE OR DELETE ON fin.tax_ledger FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE fin.tax_ledger IS 'دفتر الضرائب المحصلة والمستردة لكل مخطط واختصاص وفترة (أساس الإقرار)';

-- ------------------------------ التسوية والتحويل --------------------
CREATE TABLE fin.settlement_batch (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid         uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id  bigint NOT NULL REFERENCES iam.company(id),
  period      daterange NOT NULL,
  currency    char(3) NOT NULL REFERENCES ref.currency(code),
  gross       bigint NOT NULL DEFAULT 0,
  commission  bigint NOT NULL DEFAULT 0,
  tax         bigint NOT NULL DEFAULT 0,
  refunds     bigint NOT NULL DEFAULT 0,
  net         bigint NOT NULL DEFAULT 0,
  status      text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED','PAID','DISPUTED')),
  approved_by bigint REFERENCES iam.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (company_id WITH =, period WITH &&) WHERE (status <> 'DISPUTED')
);
COMMENT ON TABLE fin.settlement_batch IS 'كشف تسوية الناقل لفترة؛ لا تتداخل الفترات';

CREATE TABLE fin.settlement_line (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  batch_id    bigint NOT NULL REFERENCES fin.settlement_batch(id) ON DELETE CASCADE,
  trip_id     bigint REFERENCES ops.trip(id),
  gross       bigint NOT NULL,
  commission  bigint NOT NULL,
  tax         bigint NOT NULL,
  refunds     bigint NOT NULL DEFAULT 0,
  net         bigint NOT NULL
);

CREATE TABLE fin.payout_schedule (
  company_id    bigint PRIMARY KEY REFERENCES iam.company(id),
  frequency     text NOT NULL DEFAULT 'WEEKLY' CHECK (frequency IN ('DAILY','WEEKLY','MONTHLY')),
  weekday       smallint CHECK (weekday BETWEEN 1 AND 7),
  month_day     smallint CHECK (month_day BETWEEN 1 AND 28),
  holdback_pct  numeric(5,2) NOT NULL DEFAULT 0,
  min_amount    bigint NOT NULL DEFAULT 0,
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAUSED')),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE fin.payout (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id          bigint NOT NULL REFERENCES iam.company(id),
  settlement_batch_id bigint REFERENCES fin.settlement_batch(id),
  bank_account_id     bigint REFERENCES iam.bank_account(id),
  period              text NOT NULL,
  currency            char(3) NOT NULL REFERENCES ref.currency(code),
  gross               bigint NOT NULL,
  holdback            bigint NOT NULL DEFAULT 0,
  net                 bigint NOT NULL CHECK (net >= 0),
  status              text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','PAID','FAILED','RETRY')),
  bank_ref            text,
  ledger_txn_id       bigint REFERENCES fin.ledger_txn(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, period)
);
COMMENT ON TABLE fin.payout IS 'التحويل البنكي للناقل بحسب جدوله';

CREATE TABLE fin.bank_reconciliation (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  recon_date    date NOT NULL,
  account_label text NOT NULL,
  currency      char(3) NOT NULL REFERENCES ref.currency(code),
  bank_balance  bigint NOT NULL,
  wallets_total bigint NOT NULL,
  receivables   bigint NOT NULL DEFAULT 0,
  diff          bigint GENERATED ALWAYS AS (bank_balance - wallets_total - receivables) STORED,
  status        text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','MATCHED','INVESTIGATING')),
  reviewed_by   bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (recon_date, account_label, currency)
);
COMMENT ON TABLE fin.bank_reconciliation IS 'المطابقة اليومية: رصيد البنك = إجمالي المحافظ + المستحقات';

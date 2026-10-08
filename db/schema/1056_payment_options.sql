-- =====================================================================
-- 1056: payment options the platform switches on and off (owner decision, October 2026)
--   Until card gateways and e-wallet companies are contracted, the pilot and release 1 run on cash. Platform
--   administration chooses which ways of paying a booking are open, and opens the electronic ones once a provider
--   is contracted and set up:
--     WALLET          the passenger pays from the platform wallet (topped up by card, e-wallet, transfer or an agency)
--     AGENCY_BALANCE  an agency sells from its prepaid balance and takes the traveller's cash itself
--     CASH_COUNTER    the carrier's counter or station staff sell a ticket for cash (study 6.5)
--     PAY_LATER       the passenger reserves online and pays cash at the carrier's counter before departure
--     CARD            card payment at checkout through a contracted gateway (HyperPay, Amazon Payment Services, ...)
--     INSTALLMENT     pay in instalments through a contracted provider (Tabby, Tamara or similar, where available)
--     FINANCING       a financing company pays a high-value trip (Umrah, Hajj, tours) and collects from the traveller
--   a. fin.payment_method: one switch per option, with amount limits, channels and settings; an option that needs a
--      provider cannot open without an active one, a provider an open option relies on cannot be switched off, and
--      the last open option cannot be closed
--   b. providers and payments know the instalment and financing kinds; inactive placeholders wait for the contracts
--   c. a booking records the option it was paid with, and the database refuses a closed option; a reserved booking
--      (pay later, or waiting for a provider) holds its seats with tickets on HOLD, which are never valid for boarding
--   d. cash sold by a carrier is owed to the platform on the carrier's cash wallet (CASH_COLLECT, negative balance):
--      a credit limit per carrier caps what it may owe, the carrier's earnings are set off against it, and what is
--      left is remitted and confirmed by a second person
--   e. reservations not paid in time expire and give their seats back
-- =====================================================================

-- ------------------------------------------------------------------ a. the switches
CREATE TABLE IF NOT EXISTS fin.payment_method (
  code              text PRIMARY KEY CHECK (code IN ('WALLET','AGENCY_BALANCE','CASH_COUNTER','PAY_LATER','CARD','INSTALLMENT','FINANCING')),
  enabled           boolean NOT NULL DEFAULT false,
  channels          text[] NOT NULL CHECK (channels <@ ARRAY['WEB','APP','AGENCY','COUNTER']::text[] AND cardinality(channels) > 0),
  min_amount        bigint NOT NULL DEFAULT 0 CHECK (min_amount >= 0),
  max_amount        bigint CHECK (max_amount IS NULL OR max_amount >= min_amount),
  provider_adapter  text CHECK (provider_adapter IS NULL OR provider_adapter IN ('HOSTED_CARD','INSTALLMENT','FINANCING')),
  config            jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(config) = 'object'),
  sort_order        smallint NOT NULL DEFAULT 100,
  reason            text,
  updated_by        bigint REFERENCES iam.app_user(id),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE fin.payment_method IS 'Ways of paying a booking that platform administration opens or closes (1056)';
COMMENT ON COLUMN fin.payment_method.provider_adapter IS 'The provider kind the option needs; it opens only while such a provider is active for bookings';
COMMENT ON COLUMN fin.payment_method.config IS 'PAY_LATER: hold_hours, cutoff_minutes, max_open; CASH_COUNTER: default_credit_limit; provider options: hold_minutes or hold_hours, cutoff_hours, trip_types (empty: every trip)';

-- trips that financing is meant for: pilgrimages (Umrah, Hajj) and tours, chosen by the carrier when it creates the trip
INSERT INTO ref.trip_type (code, name, module, is_system, sort) VALUES
  ('PILGRIMAGE', 'Pilgrimage (Umrah, Hajj)', 'core', true, 80), ('TOURISM', 'Tour', 'core', true, 90)
ON CONFLICT (code) DO NOTHING;

INSERT INTO fin.payment_method (code, enabled, channels, min_amount, max_amount, provider_adapter, config, sort_order) VALUES
  ('WALLET',         true,  '{WEB,APP}', 0, NULL, NULL, '{}', 10),
  ('AGENCY_BALANCE', true,  '{AGENCY}',  0, NULL, NULL, '{}', 20),
  ('CASH_COUNTER',   true,  '{COUNTER}', 0, NULL, NULL, '{"default_credit_limit": 100000000}', 30),
  ('PAY_LATER',      true,  '{WEB,APP}', 0, NULL, NULL, '{"hold_hours": 24, "cutoff_minutes": 120, "max_open": 2}', 40),
  ('CARD',           false, '{WEB,APP}', 0, NULL, 'HOSTED_CARD', '{"hold_minutes": 20}', 50),
  ('INSTALLMENT',    false, '{WEB,APP}', 0, NULL, 'INSTALLMENT', '{"hold_minutes": 30}', 60),
  ('FINANCING',      false, '{WEB,APP}', 100000000, NULL, 'FINANCING', '{"hold_hours": 72, "cutoff_hours": 48, "trip_types": ["PILGRIMAGE", "TOURISM"]}', 70)
ON CONFLICT (code) DO NOTHING;

ALTER TABLE fin.payment_method ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS read_all ON fin.payment_method;
CREATE POLICY read_all ON fin.payment_method FOR SELECT USING (true);
DROP POLICY IF EXISTS platform_writes ON fin.payment_method;
CREATE POLICY platform_writes ON fin.payment_method FOR UPDATE USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
GRANT SELECT, UPDATE ON fin.payment_method TO masslak_app;
GRANT SELECT ON fin.payment_method TO masslak_readonly, masslak_auditor;

CREATE OR REPLACE FUNCTION fin.tg_payment_method_rules() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.enabled AND NEW.provider_adapter IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM fin.payment_provider p
        WHERE p.status = 'ACTIVE' AND p.adapter = NEW.provider_adapter AND 'BOOKING' = ANY (p.purposes)) THEN
    RAISE EXCEPTION 'NO_ACTIVE_PROVIDER: % opens only with an active % provider for bookings', NEW.code, NEW.provider_adapter
      USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.enabled AND NOT NEW.enabled
     AND NOT EXISTS (SELECT 1 FROM fin.payment_method m WHERE m.enabled AND m.code <> NEW.code) THEN
    RAISE EXCEPTION 'LAST_PAYMENT_METHOD: at least one way of paying stays open' USING ERRCODE = 'P0001';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a_payment_method_rules ON fin.payment_method;
CREATE TRIGGER a_payment_method_rules BEFORE INSERT OR UPDATE ON fin.payment_method
  FOR EACH ROW EXECUTE FUNCTION fin.tg_payment_method_rules();

-- ------------------------------------------------------------------ b. providers for instalments and financing
ALTER TABLE fin.payment_provider DROP CONSTRAINT IF EXISTS payment_provider_kind_check;
ALTER TABLE fin.payment_provider ADD CONSTRAINT payment_provider_kind_check
  CHECK (kind IN ('CARD','BANK','E_WALLET','CASH_AGENT','INSTALLMENT','FINANCING'));
ALTER TABLE fin.payment_provider DROP CONSTRAINT IF EXISTS payment_provider_adapter_check;
ALTER TABLE fin.payment_provider ADD CONSTRAINT payment_provider_adapter_check
  CHECK (adapter IN ('SANDBOX','HOSTED_CARD','PARTNER_WALLET','BANK_TRANSFER','CASH_AGENT','API_PARTNER','INSTALLMENT','FINANCING'));
ALTER TABLE fin.payment DROP CONSTRAINT IF EXISTS payment_method_check;
ALTER TABLE fin.payment ADD CONSTRAINT payment_method_check CHECK (method IN ('CARD','BANK','E_WALLET','CASH','INSTALLMENT','FINANCING'));
COMMENT ON COLUMN fin.payment.booking_id IS 'For purpose BOOKING: the reserved booking this payment confirms once the provider reports success (1056)';

-- the card gateway contracted for wallet top-ups also takes card payment at checkout once the CARD option is opened
UPDATE fin.payment_provider SET purposes = purposes || '{BOOKING}'::text[]
 WHERE code = 'CARD' AND adapter = 'HOSTED_CARD' AND NOT 'BOOKING' = ANY (purposes);
-- placeholders: switched off, no endpoint, until a contract names the provider and its keys
INSERT INTO fin.payment_provider (code, name, kind, adapter, status, purposes, min_amount, max_amount, sort_order, config, fee_policy) VALUES
  ('INSTALMENTS', 'Instalment provider (to be contracted)', 'INSTALLMENT', 'INSTALLMENT', 'INACTIVE', '{BOOKING}', 100000, 1000000000, 60,
   '{"base_url": "", "secret_env": "MASSLAK_PSP_INSTALMENTS_SECRET", "api_key_env": "MASSLAK_PSP_INSTALMENTS_KEY", "merchant_id": ""}',
   '{"pct": 0, "borne_by": "PLATFORM"}'),
  ('TRAVEL_FINANCE', 'Travel financing company (to be contracted)', 'FINANCING', 'FINANCING', 'INACTIVE', '{BOOKING}', 100000000, 10000000000, 70,
   '{"base_url": "", "secret_env": "MASSLAK_PSP_TRAVEL_FINANCE_SECRET", "api_key_env": "MASSLAK_PSP_TRAVEL_FINANCE_KEY", "merchant_id": ""}',
   '{"pct": 0, "borne_by": "PLATFORM"}')
ON CONFLICT (code) DO NOTHING;

CREATE OR REPLACE FUNCTION fin.tg_provider_in_use() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'ACTIVE' AND (NEW.status <> 'ACTIVE' OR NOT ('BOOKING' = ANY (NEW.purposes)) OR NEW.adapter <> OLD.adapter)
     AND 'BOOKING' = ANY (OLD.purposes)
     AND EXISTS (SELECT 1 FROM fin.payment_method m WHERE m.enabled AND m.provider_adapter = OLD.adapter)
     AND NOT EXISTS (SELECT 1 FROM fin.payment_provider p WHERE p.id <> OLD.id AND p.status = 'ACTIVE'
                        AND p.adapter = OLD.adapter AND 'BOOKING' = ANY (p.purposes)) THEN
    RAISE EXCEPTION 'PROVIDER_IN_USE: close the payment option that relies on % first', OLD.code USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_provider_in_use ON fin.payment_provider;
CREATE TRIGGER b_provider_in_use BEFORE UPDATE ON fin.payment_provider FOR EACH ROW EXECUTE FUNCTION fin.tg_provider_in_use();

-- ------------------------------------------------------------------ c. the option a booking is paid with
ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS pay_option text REFERENCES fin.payment_method(code);
COMMENT ON COLUMN sales.booking.pay_option IS 'The payment option chosen; checked open when the booking is made (1056)';
COMMENT ON COLUMN sales.booking.hold_expires_at IS 'A reserved booking (PENDING_PAYMENT) must be paid before this time, or it expires and frees its seats';
ALTER TABLE sales.booking DROP CONSTRAINT IF EXISTS booking_pay_method_check;
ALTER TABLE sales.booking ADD CONSTRAINT booking_pay_method_check
  CHECK (pay_method IN ('WALLET','CARD','BANK','CASH','POINTS','MIXED','INSTALLMENT','FINANCING'));
CREATE INDEX IF NOT EXISTS booking_pay_option_idx ON sales.booking (pay_option, status) WHERE status = 'PENDING_PAYMENT';
-- bookings made before the options existed were all paid at once from a wallet: the agency's, or the passenger's
UPDATE sales.booking SET pay_option = CASE WHEN agency_id IS NOT NULL THEN 'AGENCY_BALANCE' ELSE 'WALLET' END WHERE pay_option IS NULL;

CREATE OR REPLACE FUNCTION sales.tg_booking_pay_option() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  m fin.payment_method%ROWTYPE;
BEGIN
  IF NEW.pay_option IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT * INTO m FROM fin.payment_method WHERE code = NEW.pay_option;
  IF NOT m.enabled THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_DISABLED: % is closed by platform administration', NEW.pay_option USING ERRCODE = 'P0001';
  END IF;
  IF NEW.total_amount < m.min_amount OR (m.max_amount IS NOT NULL AND NEW.total_amount > m.max_amount) THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_OUT_OF_RANGE: % accepts amounts from % to %', NEW.pay_option, m.min_amount, coalesce(m.max_amount::text, 'any')
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'PENDING_PAYMENT' AND NEW.pay_option IN ('PAY_LATER','CARD','INSTALLMENT','FINANCING') AND NEW.hold_expires_at IS NULL THEN
    RAISE EXCEPTION 'PAY_BY_REQUIRED: a reserved booking needs a time to be paid by' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_booking_pay_option ON sales.booking;
CREATE TRIGGER b_booking_pay_option BEFORE INSERT ON sales.booking FOR EACH ROW EXECUTE FUNCTION sales.tg_booking_pay_option();

COMMENT ON COLUMN sales.ticket.status IS 'HOLD: reserved and not yet paid (pay later, provider pending), never valid for boarding; ISSUED once paid (1056)';

-- ------------------------------------------------------------------ d. cash owed by carriers
CREATE TABLE IF NOT EXISTS fin.cash_credit_limit (
  company_id    bigint PRIMARY KEY REFERENCES iam.company(id),
  limit_amount  bigint NOT NULL CHECK (limit_amount >= 0),
  reason        text NOT NULL CHECK (length(btrim(reason)) >= 3),
  set_by        bigint NOT NULL REFERENCES iam.app_user(id),
  set_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE fin.cash_credit_limit IS 'How much cash sold at a carrier''s counter it may owe the platform before cash sales stop; default in CASH_COUNTER config (1056)';
SELECT sys.rls_tenant('fin.cash_credit_limit');
GRANT SELECT, INSERT, UPDATE ON fin.cash_credit_limit TO masslak_app;
GRANT SELECT ON fin.cash_credit_limit TO masslak_readonly, masslak_auditor;
DROP POLICY IF EXISTS platform_writes ON fin.cash_credit_limit;
CREATE POLICY platform_writes ON fin.cash_credit_limit AS RESTRICTIVE FOR INSERT WITH CHECK (sys.ctx_is_platform());
DROP POLICY IF EXISTS platform_updates ON fin.cash_credit_limit;
CREATE POLICY platform_updates ON fin.cash_credit_limit AS RESTRICTIVE FOR UPDATE USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());

ALTER TABLE fin.cash_remittance ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'PENDING';
ALTER TABLE fin.cash_remittance ADD COLUMN IF NOT EXISTS confirmed_by bigint REFERENCES iam.app_user(id);
ALTER TABLE fin.cash_remittance ADD COLUMN IF NOT EXISTS confirmed_at timestamptz;
ALTER TABLE fin.cash_remittance ADD COLUMN IF NOT EXISTS note text;
DO $$ BEGIN
  ALTER TABLE fin.cash_remittance ADD CONSTRAINT cash_remittance_status_check CHECK (status IN ('PENDING','CONFIRMED','REJECTED'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE fin.cash_remittance ADD CONSTRAINT cash_remittance_confirmed CHECK (status <> 'CONFIRMED' OR (ledger_txn_id IS NOT NULL AND confirmed_by IS NOT NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN fin.cash_remittance.status IS 'Recorded by one finance officer, confirmed (and posted) or rejected by another (1056)';

CREATE OR REPLACE FUNCTION fin.tg_cash_remittance_rules() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'PENDING' THEN
      RAISE EXCEPTION 'REMITTANCE_STATUS: a remittance is recorded as pending' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status <> 'PENDING' THEN
    RAISE EXCEPTION 'REMITTANCE_FINAL: a confirmed or rejected remittance does not change' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status IN ('CONFIRMED','REJECTED') THEN
    IF NEW.confirmed_by IS NULL OR NEW.confirmed_by = OLD.recorded_by THEN
      RAISE EXCEPTION 'FOUR_EYES: the person who recorded a remittance does not confirm or reject it' USING ERRCODE = 'P0001';
    END IF;
    NEW.confirmed_at := now();
    NEW.reconciled_at := CASE WHEN NEW.status = 'CONFIRMED' THEN now() END;
  END IF;
  IF NEW.amount <> OLD.amount OR NEW.company_id <> OLD.company_id OR NEW.recorded_by <> OLD.recorded_by THEN
    RAISE EXCEPTION 'REMITTANCE_FINAL: amount, carrier and recorder stay as recorded' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a_cash_remittance_rules ON fin.cash_remittance;
CREATE TRIGGER a_cash_remittance_rules BEFORE INSERT OR UPDATE ON fin.cash_remittance
  FOR EACH ROW EXECUTE FUNCTION fin.tg_cash_remittance_rules();
GRANT SELECT, INSERT, UPDATE ON fin.cash_remittance TO masslak_app;

UPDATE sys.polymorphic_reference SET targets = targets || '{"cash_remittance": "fin.cash_remittance"}'::jsonb
 WHERE table_name = 'fin.ledger_txn' AND NOT targets ? 'cash_remittance';

COMMENT ON TABLE fin.cash_remittance IS 'Cash collected by a carrier from cash sales and remitted to the platform (6.5); four eyes since 1056';

-- the carrier's cash wallet (IMMEDIATE, may go negative): what it owes is the negative part of the balance
CREATE OR REPLACE FUNCTION fin.cash_owed(p_company bigint, p_currency char(3) DEFAULT 'SYP') RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(greatest(0, -sum(fin.wallet_balance(w.id))), 0)::bigint FROM fin.wallet w
   WHERE w.owner_party_id = p_company AND w.wallet_type = 'CASH_COLLECT' AND w.currency = p_currency
$$;
COMMENT ON FUNCTION fin.cash_owed IS 'Cash sold by the carrier that it has not yet set off or remitted (1056)';
REVOKE EXECUTE ON FUNCTION fin.cash_owed(bigint, char) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.cash_owed(bigint, char) TO masslak_app, masslak_readonly, masslak_auditor;

CREATE OR REPLACE FUNCTION fin.cash_limit(p_company bigint) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT l.limit_amount FROM fin.cash_credit_limit l WHERE l.company_id = p_company),
                  (SELECT (m.config ->> 'default_credit_limit')::bigint FROM fin.payment_method m WHERE m.code = 'CASH_COUNTER'), 0)
$$;
COMMENT ON FUNCTION fin.cash_limit IS 'The carrier''s cash credit limit: its own, or the default of the CASH_COUNTER option (1056)';
REVOKE EXECUTE ON FUNCTION fin.cash_limit(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.cash_limit(bigint) TO masslak_app, masslak_readonly, masslak_auditor;

-- ------------------------------------------------------------------ e. unpaid reservations expire
CREATE OR REPLACE FUNCTION sales.expire_reservations() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  n int;
BEGIN
  WITH due AS (
    UPDATE sales.booking SET status = 'EXPIRED'
     WHERE status = 'PENDING_PAYMENT' AND hold_expires_at IS NOT NULL AND hold_expires_at < now()
    RETURNING id),
  k AS (
    UPDATE sales.ticket t SET status = 'CANCELLED' FROM due WHERE t.booking_id = due.id AND t.status = 'HOLD' RETURNING t.id)
  UPDATE ops.seat_segment s SET status = 'AVAILABLE', ticket_id = NULL FROM k WHERE s.ticket_id = k.id AND s.status = 'SOLD';
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE fin.payment p SET status = 'FAILED', stage = 'EXPIRED', failure_code = 'BOOKING_EXPIRED'
    FROM sales.booking b
   WHERE p.booking_id = b.id AND p.purpose = 'BOOKING' AND p.status = 'PENDING' AND b.status = 'EXPIRED';
  RETURN n;
END $$;
COMMENT ON FUNCTION sales.expire_reservations IS 'Expires reservations not paid in time and frees their seats; returns the seat segments freed (worker, every minute)';
REVOKE EXECUTE ON FUNCTION sales.expire_reservations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.expire_reservations() TO masslak_app;

-- ------------------------------------------------------------------ permissions
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('payment.methods', 'fin', 'PLATFORM', 'Open and close the ways of paying a booking', true),
  ('cash.credit_limit', 'fin', 'PLATFORM', 'Set how much cash a carrier may owe before its cash sales stop', true)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, x.p FROM iam.role r JOIN (VALUES
  ('PLATFORM_ADMIN', 'payment.methods'), ('PLATFORM_FINANCE', 'payment.methods'), ('PLATFORM_FINANCE', 'cash.credit_limit')) AS x(role, p)
  ON r.code = x.role AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ registrations
INSERT INTO sys.json_contract (table_name, column_name, kind, spec, note) VALUES
  ('fin.payment_method', 'config', 'RULES', '{"type":"object","additionalProperties":false,"properties":{
      "default_credit_limit":{"type":"integer","minimum":0},"hold_hours":{"type":"number","minimum":1},
      "hold_minutes":{"type":"number","minimum":1},"cutoff_minutes":{"type":"number","minimum":0},
      "cutoff_hours":{"type":"number","minimum":0},"max_open":{"type":"integer","minimum":0},
      "trip_types":{"type":"array","items":{"type":"string"}}}}', 'Settings of a payment option: hold and cut-off times, open reservations, credit limit, trips financed')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('fin.payment_method', '1A', 'E16'), ('fin.cash_credit_limit', '1A', 'E16')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days) VALUES
  ('fin.payment_method', 'INTERNAL', 'fin', 'Ways of paying a booking that platform administration opened or closed, with the reason', 'Accounting law', 3650, 'KEEP_LEGAL', '{replica,backup}', 35),
  ('fin.cash_credit_limit', 'CONFIDENTIAL', 'fin', 'How much counter cash each carrier may owe the platform', 'Contract', 3650, 'KEEP_LEGAL', '{replica,backup}', 35)
ON CONFLICT (dataset) DO NOTHING;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.37.0', 'Payment options switched by the platform: cash at the counter, pay later, cards, instalments and financing'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.37.0');

SELECT sys.refresh_table_class();

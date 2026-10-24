-- =====================================================================
-- 1145: phase one, no money with the platform (owner's decision N13, October 2026)
--   Until the platform is licensed to hold travellers' money, it holds none: bookings are reserved on the site or the
--   app and paid in cash at the carrier's counter before a deadline (PAY_LATER), or sold for cash at the counter
--   (CASH_COUNTER); a reservation not paid in time is cancelled and its seats freed (1056). One platform setting,
--   platform.money_mode, says which phase runs:
--     FULL      every option the platform opens (1056)
--     NO_FUNDS  phase one: the wallet (paying and topping up), an agency's prepaid balance, cards, instalments and
--               financing are closed and cannot be opened; withdrawals stop; the platform's fee and every commission
--               are zero; the carriers' finance pages show figures computed from the sales only
--   Switching to NO_FUNDS keeps the options' previous state, and switching back to FULL restores it. Only the platform
--   switches, naming the decision behind it.
--   Agencies sell for cash in phase one too (owner, N13): AGENCY_CASH, the agency takes the traveller's cash and settles
--   with the carrier directly until agency wallets open. The platform keeps the account: the agency's cash wallet shows
--   what it holds, fin.agency_cash_owed what it owes each carrier (fares less its commission), and the carrier records
--   each sum it receives (fin.agency_cash_settlement); no money passes through the platform.
-- =====================================================================

-- an agency's cash sale (N13): open in phase one, beside the carrier's counter and pay-later
ALTER TABLE fin.payment_method DROP CONSTRAINT IF EXISTS payment_method_code_check;
ALTER TABLE fin.payment_method ADD CONSTRAINT payment_method_code_check
  CHECK (code IN ('WALLET','AGENCY_BALANCE','AGENCY_CASH','CASH_COUNTER','PAY_LATER','CARD','INSTALLMENT','FINANCING'));
INSERT INTO fin.payment_method (code, enabled, channels, min_amount, max_amount, provider_adapter, config, sort_order)
VALUES ('AGENCY_CASH', false, '{AGENCY}', 0, NULL, NULL, '{}', 25)
ON CONFLICT (code) DO NOTHING;

INSERT INTO sys.setting (key, value, description) VALUES
  ('platform.money_mode', '{"mode": "FULL"}'::jsonb,
   'FULL, or NO_FUNDS: phase one, the platform holds no money (cash at the counter only, no fee or commission); with the options open before the switch (N13, 1145)')
ON CONFLICT (key) DO NOTHING;

-- the options that hold money for someone: closed while the platform holds none
CREATE OR REPLACE FUNCTION fin.money_options() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['WALLET','AGENCY_BALANCE','CARD','INSTALLMENT','FINANCING']
$$;
COMMENT ON FUNCTION fin.money_options IS 'Payment options that leave money with the platform or a provider for it: closed in phase one (N13, 1145)';

CREATE OR REPLACE FUNCTION fin.money_mode() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT value ->> 'mode' FROM sys.setting WHERE key = 'platform.money_mode'), 'FULL')
$$;
REVOKE ALL ON FUNCTION fin.money_mode() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.money_mode() TO masslak_app;
COMMENT ON FUNCTION fin.money_mode IS 'FULL, or NO_FUNDS while the platform holds no money (N13, 1145)';

-- an option that holds money does not open in phase one, whoever tries
CREATE OR REPLACE FUNCTION fin.tg_payment_method_phase() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.enabled AND NEW.code = ANY (fin.money_options()) AND fin.money_mode() = 'NO_FUNDS'
     AND (TG_OP = 'INSERT' OR NOT OLD.enabled) THEN
    RAISE EXCEPTION 'NO_FUNDS_PHASE: % holds money; the platform holds none in phase one', NEW.code USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_payment_method_phase ON fin.payment_method;
CREATE TRIGGER b_payment_method_phase BEFORE INSERT OR UPDATE ON fin.payment_method
  FOR EACH ROW EXECUTE FUNCTION fin.tg_payment_method_phase();

-- moving between the phases; NO_FUNDS opens the cash options first, so that one stays open (the checks of who may are
-- set_money_mode's and apply_money_mode_default's)
CREATE OR REPLACE FUNCTION fin.switch_money_mode(p_mode text, p_basis text, p_user bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_was jsonb; v_open jsonb; v_opened jsonb;
BEGIN
  SELECT value INTO v_was FROM sys.setting WHERE key = 'platform.money_mode' FOR UPDATE;
  IF coalesce(v_was ->> 'mode', 'FULL') = p_mode THEN
    RETURN;
  END IF;
  IF p_mode = 'NO_FUNDS' THEN
    SELECT coalesce(jsonb_agg(code ORDER BY code), '[]'::jsonb) INTO v_open
      FROM fin.payment_method WHERE enabled AND code = ANY (fin.money_options());
    SELECT coalesce(jsonb_agg(code ORDER BY code), '[]'::jsonb) INTO v_opened
      FROM fin.payment_method WHERE code IN ('PAY_LATER','CASH_COUNTER','AGENCY_CASH') AND NOT enabled;
    UPDATE fin.payment_method SET enabled = true, updated_by = p_user, reason = 'Phase one: ' || btrim(p_basis)
     WHERE code IN ('PAY_LATER','CASH_COUNTER','AGENCY_CASH') AND NOT enabled;
    UPDATE fin.payment_method SET enabled = false, updated_by = p_user, reason = 'Phase one: ' || btrim(p_basis)
     WHERE enabled AND code = ANY (fin.money_options());
  ELSE
    v_open := coalesce(v_was -> 'open_before', '[]'::jsonb);
    v_opened := coalesce(v_was -> 'opened', '[]'::jsonb);
  END IF;
  UPDATE sys.setting
     SET value = jsonb_strip_nulls(jsonb_build_object('mode', p_mode, 'basis', btrim(p_basis), 'set_at', now(), 'set_by', p_user,
                                    'open_before', CASE WHEN p_mode = 'NO_FUNDS' THEN v_open END,
                                    'opened', CASE WHEN p_mode = 'NO_FUNDS' THEN v_opened END)),
         scope = 'PLATFORM', updated_by = p_user, updated_at = now()
   WHERE key = 'platform.money_mode';
  IF p_mode = 'FULL' THEN                         -- the options open before phase one open again (their providers allowing)
    UPDATE fin.payment_method SET enabled = true, updated_by = p_user, reason = 'Phase one ended: ' || btrim(p_basis)
     WHERE code IN (SELECT jsonb_array_elements_text(v_open)) AND NOT enabled;
    UPDATE fin.payment_method SET enabled = false, updated_by = p_user, reason = 'Phase one ended: ' || btrim(p_basis)
     WHERE code IN (SELECT jsonb_array_elements_text(v_opened)) AND enabled;      -- and the cash ones it opened close
  END IF;
END $$;
REVOKE ALL ON FUNCTION fin.switch_money_mode(text, text, bigint) FROM PUBLIC;
COMMENT ON FUNCTION fin.switch_money_mode IS 'Moves between FULL and NO_FUNDS, closing or reopening the options that hold money; called by set_money_mode and apply_money_mode_default only (1145)';

-- the platform moves between the phases, naming the decision
CREATE OR REPLACE FUNCTION fin.set_money_mode(p_mode text, p_basis text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the money phase is a platform setting' USING ERRCODE = 'P0001';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('FULL','NO_FUNDS') THEN
    RAISE EXCEPTION 'INVALID_SETTING: the phase is FULL or NO_FUNDS' USING ERRCODE = 'P0001';
  END IF;
  IF length(btrim(coalesce(p_basis, ''))) NOT BETWEEN 3 AND 160 THEN
    RAISE EXCEPTION 'INVALID_SETTING: name the decision behind the change' USING ERRCODE = 'P0001';
  END IF;
  PERFORM fin.switch_money_mode(p_mode, p_basis, sys.ctx_user_id());
  RETURN fin.money_mode_state();
END $$;
REVOKE ALL ON FUNCTION fin.set_money_mode(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.set_money_mode(text, text) TO masslak_app;
COMMENT ON FUNCTION fin.set_money_mode IS 'Moves between FULL and NO_FUNDS (phase one), closing or reopening the options that hold money; platform only (N13, 1145)';

CREATE OR REPLACE FUNCTION fin.money_mode_state() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object('mode', fin.money_mode(),
                            'basis', (SELECT value -> 'basis' FROM sys.setting WHERE key = 'platform.money_mode'),
                            'set_at', (SELECT value -> 'set_at' FROM sys.setting WHERE key = 'platform.money_mode'),
                            'open', (SELECT coalesce(jsonb_agg(code ORDER BY sort_order), '[]'::jsonb) FROM fin.payment_method WHERE enabled))
$$;
REVOKE ALL ON FUNCTION fin.money_mode_state() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.money_mode_state() TO masslak_app;
COMMENT ON FUNCTION fin.money_mode_state IS 'The money phase, the decision behind it and the payment options open (N13, 1145)';

-- the server's default phase (MASSLAK_MONEY_MODE, deploy/migrate.sh): applied while nobody has set the phase in
-- administration, so a person's choice is never overridden by a restart
CREATE OR REPLACE FUNCTION fin.apply_money_mode_default(p_mode text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF p_mode NOT IN ('FULL','NO_FUNDS') THEN
    RAISE EXCEPTION 'INVALID_SETTING: the phase is FULL or NO_FUNDS' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM sys.setting WHERE key = 'platform.money_mode' AND value ? 'set_by') THEN
    PERFORM fin.switch_money_mode(p_mode, 'Server default (MASSLAK_MONEY_MODE)', NULL);
  END IF;
  RETURN fin.money_mode();
END $$;
REVOKE ALL ON FUNCTION fin.apply_money_mode_default(text) FROM PUBLIC;
COMMENT ON FUNCTION fin.apply_money_mode_default IS 'Applies the server''s default money phase while nobody has set it in administration (N13, 1145)';

-- ------------------------------------------------------------------ agencies' cash, settled with the carriers
CREATE TABLE IF NOT EXISTS fin.agency_cash_settlement (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid            uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  agency_id      bigint NOT NULL REFERENCES iam.company(id),
  carrier_id     bigint NOT NULL REFERENCES iam.company(id),
  currency       char(3) NOT NULL REFERENCES ref.currency(code),
  amount         bigint NOT NULL CHECK (amount > 0),
  reference      text NOT NULL CHECK (length(btrim(reference)) BETWEEN 3 AND 80),
  ledger_txn_id  bigint REFERENCES fin.ledger_txn(id),
  confirmed_by   bigint NOT NULL REFERENCES iam.app_user(id),
  confirmed_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (agency_id <> carrier_id),
  UNIQUE (carrier_id, reference)
);
CREATE INDEX IF NOT EXISTS agency_cash_settlement_agency_idx ON fin.agency_cash_settlement (agency_id, carrier_id);
CREATE INDEX IF NOT EXISTS agency_cash_settlement_ledger_txn_id_fkx ON fin.agency_cash_settlement (ledger_txn_id);
CREATE INDEX IF NOT EXISTS agency_cash_settlement_confirmed_by_fkx ON fin.agency_cash_settlement (confirmed_by);
CREATE INDEX IF NOT EXISTS agency_cash_settlement_currency_fkx ON fin.agency_cash_settlement (currency);
COMMENT ON TABLE fin.agency_cash_settlement IS 'Cash an agency paid a carrier for its cash sales, as the carrier recorded receiving it (N13, 1145)';
ALTER TABLE fin.agency_cash_settlement ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS parties_read ON fin.agency_cash_settlement;
CREATE POLICY parties_read ON fin.agency_cash_settlement FOR SELECT
  USING (sys.tenant_visible(agency_id) OR sys.tenant_visible(carrier_id));
DROP POLICY IF EXISTS carrier_records ON fin.agency_cash_settlement;
CREATE POLICY carrier_records ON fin.agency_cash_settlement FOR INSERT WITH CHECK (sys.tenant_visible(carrier_id));
GRANT SELECT, INSERT ON fin.agency_cash_settlement TO masslak_app;
GRANT SELECT ON fin.agency_cash_settlement TO masslak_readonly, masslak_auditor;

-- what an agency owes a carrier for its cash sales: the carrier's share of the bookings it sold for cash, net of what
-- was refunded on cancellation (the agency keeps its commission from the cash), less what the carrier recorded receiving
CREATE OR REPLACE FUNCTION fin.agency_cash_owed(p_agency bigint, p_carrier bigint, p_currency char(3)) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT (coalesce((SELECT sum(l.amount - l.refunded_amount)
                      FROM sales.booking b JOIN fin.price_allocation_line l ON l.allocation_id = b.price_allocation_id
                     WHERE b.agency_id = p_agency AND b.company_id = p_carrier AND b.currency = p_currency
                       AND b.pay_option = 'AGENCY_CASH' AND l.code = 'CARRIER_FARE'), 0)
        - coalesce((SELECT sum(s.amount) FROM fin.agency_cash_settlement s
                     WHERE s.agency_id = p_agency AND s.carrier_id = p_carrier AND s.currency = p_currency), 0))::bigint
$$;
REVOKE ALL ON FUNCTION fin.agency_cash_owed(bigint, bigint, char) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.agency_cash_owed(bigint, bigint, char) TO masslak_app;
COMMENT ON FUNCTION fin.agency_cash_owed IS 'What an agency owes a carrier for its cash sales, less what the carrier recorded receiving (N13, 1145)';

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('fin.agency_cash_settlement', '1A', 'E16')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('fin.agency_cash_settlement', 'fin records', 'cash agencies paid carriers for their cash sales in phase one (1145)')
ON CONFLICT (table_name) DO NOTHING;

-- ------------------------------------------------------------------ the gateway, carrier by carrier (phase two)
-- Once the platform has contracted a payment gateway (a card scheme, instalments, financing), the traveller pays the
-- ticket through it: the gateway settles into the platform's bank account and the platform pays the carrier its share
-- (escrow, release on completion, withdrawal: the payouts module). The platform opens it carrier by carrier: each is
-- told when its contract is signed and again when its trips take the option, so the roll-out goes step by step.
CREATE TABLE IF NOT EXISTS fin.carrier_payment_activation (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  carrier_id    bigint NOT NULL REFERENCES iam.company(id),
  option_code   text NOT NULL REFERENCES fin.payment_method(code) CHECK (option_code IN ('CARD','INSTALLMENT','FINANCING')),
  status        text NOT NULL CHECK (status IN ('CONTRACTED','ACTIVE','SUSPENDED')),
  basis         text NOT NULL CHECK (length(btrim(basis)) BETWEEN 3 AND 200),
  contracted_at timestamptz NOT NULL DEFAULT now(),
  activated_at  timestamptz,
  changed_by    bigint NOT NULL REFERENCES iam.app_user(id),
  changed_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (carrier_id, option_code),
  CHECK (status <> 'ACTIVE' OR activated_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS carrier_payment_activation_changed_by_fkx ON fin.carrier_payment_activation (changed_by);
CREATE INDEX IF NOT EXISTS carrier_payment_activation_option_code_fkx ON fin.carrier_payment_activation (option_code);
COMMENT ON TABLE fin.carrier_payment_activation IS 'Gateway payment options the platform opened for each carrier, step by step (N13 phase two, 1145)';
ALTER TABLE fin.carrier_payment_activation ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS carrier_or_platform_reads ON fin.carrier_payment_activation;
CREATE POLICY carrier_or_platform_reads ON fin.carrier_payment_activation FOR SELECT
  USING (sys.ctx_is_platform() OR sys.tenant_visible(carrier_id));
DROP POLICY IF EXISTS platform_writes ON fin.carrier_payment_activation;
CREATE POLICY platform_writes ON fin.carrier_payment_activation FOR ALL
  USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
GRANT SELECT, INSERT, UPDATE ON fin.carrier_payment_activation TO masslak_app;
GRANT SELECT ON fin.carrier_payment_activation TO masslak_readonly, masslak_auditor;

-- whether a traveller may pay this carrier's ticket through the gateway option: open by the platform and active for it
CREATE OR REPLACE FUNCTION fin.carrier_takes(p_carrier bigint, p_option text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM fin.carrier_payment_activation a
                  WHERE a.carrier_id = p_carrier AND a.option_code = p_option AND a.status = 'ACTIVE')
$$;
REVOKE ALL ON FUNCTION fin.carrier_takes(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.carrier_takes(bigint, text) TO masslak_app;
COMMENT ON FUNCTION fin.carrier_takes IS 'Whether the platform activated a gateway payment option for the carrier (1145)';

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('fin.carrier_payment_activation', '1A', 'E16')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('fin.carrier_payment_activation', 'fin records', 'gateway payment options opened carrier by carrier (1145)')
ON CONFLICT (table_name) DO NOTHING;

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
-- =====================================================================

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

-- the platform moves between the phases, naming the decision; NO_FUNDS opens the cash options first, so that one stays open
CREATE OR REPLACE FUNCTION fin.set_money_mode(p_mode text, p_basis text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_was jsonb; v_open jsonb;
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
  SELECT value INTO v_was FROM sys.setting WHERE key = 'platform.money_mode' FOR UPDATE;
  IF coalesce(v_was ->> 'mode', 'FULL') = p_mode THEN
    RETURN fin.money_mode_state();
  END IF;
  IF p_mode = 'NO_FUNDS' THEN
    SELECT coalesce(jsonb_agg(code ORDER BY code), '[]'::jsonb) INTO v_open
      FROM fin.payment_method WHERE enabled AND code = ANY (fin.money_options());
    UPDATE fin.payment_method SET enabled = true, updated_by = sys.ctx_user_id(), reason = 'Phase one: ' || btrim(p_basis)
     WHERE code IN ('PAY_LATER','CASH_COUNTER') AND NOT enabled;
    UPDATE fin.payment_method SET enabled = false, updated_by = sys.ctx_user_id(), reason = 'Phase one: ' || btrim(p_basis)
     WHERE enabled AND code = ANY (fin.money_options());
  ELSE
    v_open := coalesce(v_was -> 'open_before', '[]'::jsonb);
  END IF;
  UPDATE sys.setting
     SET value = jsonb_build_object('mode', p_mode, 'basis', btrim(p_basis), 'set_at', now(), 'set_by', sys.ctx_user_id(),
                                    'open_before', CASE WHEN p_mode = 'NO_FUNDS' THEN v_open END),
         scope = 'PLATFORM', updated_by = sys.ctx_user_id(), updated_at = now()
   WHERE key = 'platform.money_mode';
  IF p_mode = 'FULL' THEN                         -- the options open before phase one open again (their providers allowing)
    UPDATE fin.payment_method SET enabled = true, updated_by = sys.ctx_user_id(), reason = 'Phase one ended: ' || btrim(p_basis)
     WHERE code IN (SELECT jsonb_array_elements_text(v_open)) AND NOT enabled;
  END IF;
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

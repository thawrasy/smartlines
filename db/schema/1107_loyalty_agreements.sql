-- =====================================================================
-- Masslak - 1107: points redeemed at partners under agreements the platform records per partner (owner's decision,
-- October 2026)
--
-- The platform bears the cost of a redemption at prices agreed with each partner. An agreement says how many points
-- buy how much at the partner (points = amount), and the percentage of that amount the platform pays the partner when
-- the partner honours it (the rest is the partner's own contribution). Example: 100 points = 10,000 SYP at a rest stop,
-- platform pays 80 %: a member spends 300 points for a 30,000 SYP voucher; when the rest stop accepts it the platform
-- owes it 24,000 SYP.
--
--   pricing.loyalty_agreement   the terms per partner and currency, valid over a period; written as a DRAFT, activated
--                               by a second person (four eyes), frozen once active; one active agreement per partner,
--                               currency and day
--   pricing.redeem_at_partner   the member turns points into a voucher at the agreed rate (the points leave at once)
--   pricing.accept_voucher      the partner (its API client) or the platform for it honours the voucher: the redemption
--                               is recorded with the amount the platform owes; the application posts it from the
--                               platform's loyalty expense wallet to the partner's wallet in the same transaction
--   pricing.release_vouchers    daily: vouchers past their date, or at a partner whose agreement with the platform has
--                               ended, give the points back (as does a member cancelling an unused voucher)
--   pricing.loyalty_settlement  the partner's statement per period: drafted, approved by another person, then paid by
--                               bank transfer by a third (the application posts the payment)
-- The member's own redemption for wallet credit (1103) stays as it was: the programme's point value is the platform's
-- own rate. Partners, agreements, vouchers and partner redemptions join the loyalty release (1B); the switch
-- loyalty_partners turns the partner screens and API on and no longer opens phase 9.
-- =====================================================================

-- ------------------------------------------------------------------ phases: partner redemption joins the loyalty release
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('pricing.loyalty_partner', '1B', 'E15'), ('pricing.reward_voucher', '1B', 'E15'), ('pricing.partner_redemption', '1B', 'E15')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
UPDATE sys.project_phase SET feature_keys = array_remove(feature_keys, 'loyalty_partners')
 WHERE code = '9' AND 'loyalty_partners' = ANY (feature_keys);

-- ------------------------------------------------------------------ the partner's wallet: what the platform owes it
ALTER TABLE fin.wallet DROP CONSTRAINT IF EXISTS wallet_wallet_type_check;
ALTER TABLE fin.wallet ADD CONSTRAINT wallet_wallet_type_check CHECK (wallet_type IN ('USER','COMPANY','PLATFORM','ESCROW',
  'COMMISSION','TAX','SPONSOR','GATEWAY_CLEARING','BANK_CLEARING','CASH_COLLECT','DEPOSIT','EXPENSE','FAMILY','PARTNER'));

-- ------------------------------------------------------------------ a partner's API client (it accepts vouchers)
ALTER TABLE pricing.loyalty_partner ADD COLUMN IF NOT EXISTS api_client_id bigint REFERENCES iam.api_client(id);
CREATE UNIQUE INDEX IF NOT EXISTS loyalty_partner_api_client_id_key ON pricing.loyalty_partner (api_client_id) WHERE api_client_id IS NOT NULL;
COMMENT ON COLUMN pricing.loyalty_partner.api_client_id IS 'The API client (kind PARTNER, scope vouchers:redeem) through which the partner accepts vouchers (1107)';

-- ------------------------------------------------------------------ the agreement
CREATE TABLE IF NOT EXISTS pricing.loyalty_agreement (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  loyalty_partner_id  bigint NOT NULL REFERENCES pricing.loyalty_partner(id),
  currency            char(3) NOT NULL REFERENCES ref.currency(code),
  points              bigint NOT NULL CHECK (points > 0),                 -- this many points ...
  amount              bigint NOT NULL CHECK (amount > 0),                 -- ... buy this much at the partner (minor units)
  platform_share_pct  numeric(5,2) NOT NULL CHECK (platform_share_pct > 0 AND platform_share_pct <= 100),
  min_points          bigint NOT NULL CHECK (min_points > 0),
  step_points         bigint NOT NULL CHECK (step_points > 0),
  voucher_days        integer NOT NULL DEFAULT 30 CHECK (voucher_days BETWEEN 1 AND 365),
  valid               daterange NOT NULL DEFAULT daterange(current_date, NULL),
  contract_ref        text NOT NULL CHECK (length(btrim(contract_ref)) BETWEEN 3 AND 120),
  note                text CHECK (note IS NULL OR length(note) <= 500),
  status              text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'ACTIVE', 'ENDED')),
  created_by          bigint REFERENCES iam.app_user(id),
  approved_by         bigint REFERENCES iam.app_user(id),
  approved_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT isempty(valid) AND NOT lower_inf(valid)),
  CHECK (min_points % step_points = 0),
  CHECK (status = 'DRAFT' OR approved_by IS NOT NULL),
  CHECK (approved_by IS NULL OR created_by IS NULL OR approved_by <> created_by),
  EXCLUDE USING gist (loyalty_partner_id WITH =, currency WITH =, valid WITH &&) WHERE (status = 'ACTIVE')
);
CREATE INDEX IF NOT EXISTS loyalty_agreement_loyalty_partner_id_fkx ON pricing.loyalty_agreement (loyalty_partner_id);
CREATE INDEX IF NOT EXISTS loyalty_agreement_created_by_fkx ON pricing.loyalty_agreement (created_by);
CREATE INDEX IF NOT EXISTS loyalty_agreement_approved_by_fkx ON pricing.loyalty_agreement (approved_by);
COMMENT ON TABLE pricing.loyalty_agreement IS 'Agreed redemption price at a partner: points = amount, and the percentage of the amount the platform pays the partner; four eyes, frozen once active (1107)';
COMMENT ON COLUMN pricing.loyalty_agreement.platform_share_pct IS 'Percentage of a voucher''s value the platform pays the partner when it is honoured; the rest is the partner''s contribution';

CREATE OR REPLACE FUNCTION pricing.tg_loyalty_agreement() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status <> 'DRAFT'
     AND (NEW.loyalty_partner_id, NEW.currency, NEW.points, NEW.amount, NEW.platform_share_pct, NEW.min_points,
          NEW.step_points, NEW.voucher_days, lower(NEW.valid), NEW.contract_ref)
         IS DISTINCT FROM
         (OLD.loyalty_partner_id, OLD.currency, OLD.points, OLD.amount, OLD.platform_share_pct, OLD.min_points,
          OLD.step_points, OLD.voucher_days, lower(OLD.valid), OLD.contract_ref) THEN
    RAISE EXCEPTION 'AGREEMENT_FROZEN: an active or ended agreement keeps its terms; end it and record a new one' USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'ENDED' AND NEW.status <> 'ENDED' THEN
    RAISE EXCEPTION 'AGREEMENT_ENDED: an ended agreement stays ended' USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'ACTIVE' AND NEW.status = 'DRAFT' THEN
    RAISE EXCEPTION 'AGREEMENT_FROZEN: an active agreement does not go back to draft' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'ACTIVE' AND (TG_OP = 'INSERT' OR OLD.status <> 'ACTIVE') THEN
    IF NOT EXISTS (SELECT 1 FROM pricing.loyalty_partner WHERE id = NEW.loyalty_partner_id AND status = 'ACTIVE') THEN
      RAISE EXCEPTION 'PARTNER_NOT_ACTIVE: activate the partner before its agreement' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pricing.loyalty_partner lp JOIN pricing.loyalty_program g ON g.id = lp.program_id
                    WHERE lp.id = NEW.loyalty_partner_id AND g.currency = NEW.currency) THEN
      RAISE EXCEPTION 'AGREEMENT_CURRENCY: the agreement is in the programme''s currency' USING ERRCODE = 'P0001';
    END IF;
    NEW.approved_at := coalesce(NEW.approved_at, now());
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'ACTIVE' AND NEW.status = 'ENDED' AND (upper_inf(NEW.valid) OR upper(NEW.valid) > current_date + 1) THEN
    NEW.valid := daterange(lower(NEW.valid), greatest(lower(NEW.valid) + 1, current_date + 1));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS loyalty_agreement_rules ON pricing.loyalty_agreement;
CREATE TRIGGER loyalty_agreement_rules BEFORE INSERT OR UPDATE ON pricing.loyalty_agreement
  FOR EACH ROW EXECUTE FUNCTION pricing.tg_loyalty_agreement();

SELECT sys.rls_platform('pricing.loyalty_agreement');
GRANT SELECT, INSERT, UPDATE ON pricing.loyalty_agreement TO masslak_app;
GRANT SELECT ON pricing.loyalty_agreement TO masslak_readonly;

-- ------------------------------------------------------------------ vouchers and redemptions name their agreement
ALTER TABLE pricing.reward_voucher ADD COLUMN IF NOT EXISTS agreement_id bigint REFERENCES pricing.loyalty_agreement(id);
ALTER TABLE pricing.reward_voucher ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE pricing.reward_voucher ADD COLUMN IF NOT EXISTS code_enc bytea;
ALTER TABLE pricing.reward_voucher ADD COLUMN IF NOT EXISTS code_key_id bigint REFERENCES sec.key_registry(id);
CREATE INDEX IF NOT EXISTS reward_voucher_code_key_id_fkx ON pricing.reward_voucher (code_key_id);
ALTER TABLE pricing.reward_voucher ADD COLUMN IF NOT EXISTS returned_ledger_id bigint REFERENCES pricing.points_ledger(id);
CREATE UNIQUE INDEX IF NOT EXISTS reward_voucher_uid_key ON pricing.reward_voucher (uid);
CREATE UNIQUE INDEX IF NOT EXISTS reward_voucher_points_ledger_id_key ON pricing.reward_voucher (points_ledger_id) WHERE points_ledger_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS reward_voucher_agreement_id_fkx ON pricing.reward_voucher (agreement_id);
CREATE INDEX IF NOT EXISTS reward_voucher_returned_ledger_id_fkx ON pricing.reward_voucher (returned_ledger_id);
CREATE INDEX IF NOT EXISTS reward_voucher_open_idx ON pricing.reward_voucher (expires_at) WHERE status = 'ISSUED';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'pricing.reward_voucher'::regclass AND conname = 'reward_voucher_used_check') THEN
    ALTER TABLE pricing.reward_voucher ADD CONSTRAINT reward_voucher_used_check CHECK ((status = 'USED') = (used_at IS NOT NULL));
    ALTER TABLE pricing.reward_voucher ADD CONSTRAINT reward_voucher_code_check CHECK ((code_enc IS NULL) = (code_key_id IS NULL));
    ALTER TABLE pricing.reward_voucher ADD CONSTRAINT reward_voucher_returned_check
      CHECK (returned_ledger_id IS NULL OR status IN ('EXPIRED', 'CANCELLED'));
  END IF;
END $$;
COMMENT ON COLUMN pricing.reward_voucher.code_enc IS 'The voucher code, encrypted (field cipher), so the member can show it again; code_hash finds it (1107)';
COMMENT ON COLUMN pricing.reward_voucher.returned_ledger_id IS 'The points ledger row that gave the points back when the voucher expired or was cancelled (1107)';

CREATE TABLE IF NOT EXISTS pricing.loyalty_settlement (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  loyalty_partner_id  bigint NOT NULL REFERENCES pricing.loyalty_partner(id),
  currency            char(3) NOT NULL REFERENCES ref.currency(code),
  period              daterange NOT NULL CHECK (NOT isempty(period) AND NOT lower_inf(period) AND NOT upper_inf(period)),
  redemptions         integer NOT NULL CHECK (redemptions > 0),
  value               bigint NOT NULL CHECK (value >= 0),
  payable             bigint NOT NULL CHECK (payable >= 0 AND payable <= value),
  status              text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'APPROVED', 'PAID', 'CANCELLED')),
  created_by          bigint NOT NULL REFERENCES iam.app_user(id),
  approved_by         bigint REFERENCES iam.app_user(id),
  approved_at         timestamptz,
  paid_by             bigint REFERENCES iam.app_user(id),
  paid_at             timestamptz,
  bank_ref            text CHECK (bank_ref IS NULL OR length(btrim(bank_ref)) BETWEEN 3 AND 80),
  ledger_txn_id       bigint REFERENCES fin.ledger_txn(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK ((status IN ('APPROVED', 'PAID')) = (approved_by IS NOT NULL) OR status = 'CANCELLED'),
  CHECK ((status = 'PAID') = (paid_at IS NOT NULL AND paid_by IS NOT NULL AND bank_ref IS NOT NULL)),
  CHECK (approved_by IS NULL OR approved_by <> created_by),
  CHECK (paid_by IS NULL OR (paid_by <> created_by AND paid_by <> approved_by))
);
CREATE INDEX IF NOT EXISTS loyalty_settlement_loyalty_partner_id_fkx ON pricing.loyalty_settlement (loyalty_partner_id, status);
CREATE INDEX IF NOT EXISTS loyalty_settlement_created_by_fkx ON pricing.loyalty_settlement (created_by);
CREATE INDEX IF NOT EXISTS loyalty_settlement_approved_by_fkx ON pricing.loyalty_settlement (approved_by);
CREATE INDEX IF NOT EXISTS loyalty_settlement_paid_by_fkx ON pricing.loyalty_settlement (paid_by);
CREATE INDEX IF NOT EXISTS loyalty_settlement_ledger_txn_id_fkx ON pricing.loyalty_settlement (ledger_txn_id);
COMMENT ON TABLE pricing.loyalty_settlement IS 'A partner''s statement of honoured vouchers for a period: drafted, approved by another person, paid by a third (1107)';
SELECT sys.rls_platform('pricing.loyalty_settlement');
GRANT SELECT, INSERT ON pricing.loyalty_settlement TO masslak_app;
GRANT UPDATE (status, approved_by, approved_at, paid_by, paid_at, bank_ref, ledger_txn_id) ON pricing.loyalty_settlement TO masslak_app;
GRANT SELECT ON pricing.loyalty_settlement TO masslak_readonly;

-- the honoured vouchers a statement covers (partner redemptions are append-only, so the link lives here)
CREATE TABLE IF NOT EXISTS pricing.loyalty_settlement_line (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  settlement_id   bigint NOT NULL REFERENCES pricing.loyalty_settlement(id),
  redemption_id   bigint NOT NULL UNIQUE REFERENCES pricing.partner_redemption(id),
  value           bigint NOT NULL CHECK (value >= 0),
  payable         bigint NOT NULL CHECK (payable >= 0 AND payable <= value)
);
CREATE INDEX IF NOT EXISTS loyalty_settlement_line_settlement_id_fkx ON pricing.loyalty_settlement_line (settlement_id);
COMMENT ON TABLE pricing.loyalty_settlement_line IS 'An honoured voucher covered by a partner statement; each redemption is settled once (1107)';
SELECT sys.rls_platform('pricing.loyalty_settlement_line');
GRANT SELECT ON pricing.loyalty_settlement_line TO masslak_app, masslak_readonly;

ALTER TABLE pricing.partner_redemption ADD COLUMN IF NOT EXISTS agreement_id bigint REFERENCES pricing.loyalty_agreement(id);
ALTER TABLE pricing.partner_redemption ADD COLUMN IF NOT EXISTS payable bigint;
ALTER TABLE pricing.partner_redemption ADD COLUMN IF NOT EXISTS partner_ref text;
ALTER TABLE pricing.partner_redemption ADD COLUMN IF NOT EXISTS accepted_by bigint REFERENCES iam.app_user(id);
ALTER TABLE pricing.partner_redemption ADD COLUMN IF NOT EXISTS api_client_id bigint REFERENCES iam.api_client(id);
CREATE INDEX IF NOT EXISTS partner_redemption_agreement_id_fkx ON pricing.partner_redemption (agreement_id);
CREATE INDEX IF NOT EXISTS partner_redemption_accepted_by_fkx ON pricing.partner_redemption (accepted_by);
CREATE INDEX IF NOT EXISTS partner_redemption_api_client_id_fkx ON pricing.partner_redemption (api_client_id);
CREATE INDEX IF NOT EXISTS partner_redemption_partner_time_idx ON pricing.partner_redemption (loyalty_partner_id, redeemed_at);
CREATE UNIQUE INDEX IF NOT EXISTS partner_redemption_voucher_id_key ON pricing.partner_redemption (voucher_id) WHERE voucher_id IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'pricing.partner_redemption'::regclass AND conname = 'partner_redemption_payable_check') THEN
    ALTER TABLE pricing.partner_redemption ADD CONSTRAINT partner_redemption_payable_check
      CHECK (agreement_id IS NULL OR (payable IS NOT NULL AND payable BETWEEN 0 AND value AND commission = value - payable));
    ALTER TABLE pricing.partner_redemption ADD CONSTRAINT partner_redemption_partner_ref_check
      CHECK (partner_ref IS NULL OR length(partner_ref) <= 80);
  END IF;
END $$;
COMMENT ON COLUMN pricing.partner_redemption.payable IS 'What the platform owes the partner for this voucher under the agreement; commission is the partner''s contribution (value - payable) (1107)';

-- ------------------------------------------------------------------ what a member may redeem at partners now
CREATE OR REPLACE FUNCTION pricing.partner_offers(p_party_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'agreement', a.uid, 'partner', p.legal_name, 'partner_type', lp.partner_type,
           'points', a.points, 'amount', a.amount, 'currency', a.currency, 'min_points', a.min_points,
           'step_points', a.step_points, 'voucher_days', a.voucher_days, 'valid_to', upper(a.valid))
           ORDER BY p.legal_name), '[]'::jsonb)
    FROM pricing.loyalty_agreement a
    JOIN pricing.loyalty_partner lp ON lp.id = a.loyalty_partner_id AND lp.status = 'ACTIVE'
    JOIN pricing.loyalty_program g ON g.id = lp.program_id AND g.status = 'ACTIVE'
    JOIN iam.party p ON p.id = lp.party_id
   WHERE a.status = 'ACTIVE' AND a.valid @> current_date
     AND (p_party_id IS NULL OR EXISTS (SELECT 1 FROM pricing.points_account pa WHERE pa.program_id = g.id
                                          AND pa.party_id = p_party_id AND pa.status = 'ACTIVE'))
$$;
REVOKE ALL ON FUNCTION pricing.partner_offers(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pricing.partner_offers(bigint) TO masslak_app;
COMMENT ON FUNCTION pricing.partner_offers IS 'The partners a member can redeem at today and their agreed rates (without what the platform pays them) (1107)';

-- ------------------------------------------------------------------ the member turns points into a partner voucher
CREATE OR REPLACE FUNCTION pricing.redeem_at_partner(p_party_id bigint, p_user_id bigint, p_agreement uuid, p_points bigint,
                                                     p_key text, p_code_hash bytea, p_code_enc bytea, p_code_key_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_ag record;
  v_a record;
  v_ledger bigint;
  v_voucher record;
  v_value bigint;
BEGIN
  IF (p_party_id IS DISTINCT FROM sys.ctx_party_id() OR p_user_id IS DISTINCT FROM sys.ctx_user_id()) AND NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'POINTS_NOT_YOURS: points are redeemed by their member' USING ERRCODE = 'P0001';
  END IF;
  SELECT v.id, v.uid, v.points, v.value, v.currency, v.expires_at, v.code_enc, v.code_key_id, v.status INTO v_voucher
    FROM pricing.points_ledger l JOIN pricing.reward_voucher v ON v.points_ledger_id = l.id WHERE l.idempotency_key = p_key;
  IF v_voucher.id IS NOT NULL THEN                          -- the same request again: the same voucher
    RETURN jsonb_build_object('voucher_id', v_voucher.id, 'voucher', v_voucher.uid, 'points', v_voucher.points,
                              'value', v_voucher.value, 'currency', v_voucher.currency, 'expires_at', v_voucher.expires_at,
                              'status', v_voucher.status, 'replayed', true);
  END IF;
  SELECT a.*, lp.program_id, lp.party_id AS partner_party_id, p.legal_name AS partner_name INTO v_ag
    FROM pricing.loyalty_agreement a JOIN pricing.loyalty_partner lp ON lp.id = a.loyalty_partner_id
    JOIN iam.party p ON p.id = lp.party_id
   WHERE a.uid = p_agreement AND a.status = 'ACTIVE' AND a.valid @> current_date AND lp.status = 'ACTIVE';
  IF v_ag.id IS NULL THEN
    RAISE EXCEPTION 'AGREEMENT_NOT_AVAILABLE: this partner takes no points now' USING ERRCODE = 'P0001';
  END IF;
  SELECT a.id, a.balance, a.status, g.point_value, g.status AS program_status INTO v_a
    FROM pricing.points_account a JOIN pricing.loyalty_program g ON g.id = a.program_id
   WHERE a.party_id = p_party_id AND a.program_id = v_ag.program_id FOR UPDATE OF a;
  IF v_a.id IS NULL OR v_a.status <> 'ACTIVE' OR v_a.program_status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'POINTS_NOT_AVAILABLE: there is no active points account to redeem from' USING ERRCODE = 'P0001';
  END IF;
  IF p_points < v_ag.min_points OR p_points % v_ag.step_points <> 0 THEN
    RAISE EXCEPTION 'POINTS_BAD_AMOUNT: redeem at least % points, in steps of %', v_ag.min_points, v_ag.step_points USING ERRCODE = 'P0001';
  END IF;
  IF p_points > v_a.balance THEN
    RAISE EXCEPTION 'POINTS_INSUFFICIENT: the balance is % points', v_a.balance USING ERRCODE = 'P0001';
  END IF;
  v_value := floor(p_points::numeric * v_ag.amount / v_ag.points);
  IF v_value <= 0 THEN
    RAISE EXCEPTION 'POINTS_BAD_AMOUNT: these points are worth nothing at this partner' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO pricing.points_ledger (account_id, txn_type, points, funded_by, idempotency_key)
  VALUES (v_a.id, 'REDEEM', -p_points, 'PLATFORM', p_key) RETURNING id INTO v_ledger;
  UPDATE pricing.points_account SET balance = balance - p_points WHERE id = v_a.id;
  PERFORM pricing.add_liability(v_ag.program_id, NULL, 'REDEEMED', p_points * v_a.point_value);
  INSERT INTO pricing.reward_voucher (user_id, loyalty_partner_id, agreement_id, points_ledger_id, code_hash, code_enc, code_key_id,
                                      points, value, currency, expires_at)
  VALUES (p_user_id, v_ag.loyalty_partner_id, v_ag.id, v_ledger, p_code_hash, p_code_enc, p_code_key_id, p_points, v_value,
          v_ag.currency, now() + make_interval(days => v_ag.voucher_days))
  RETURNING id, uid, expires_at INTO v_voucher;
  RETURN jsonb_build_object('voucher_id', v_voucher.id, 'voucher', v_voucher.uid, 'points', p_points, 'value', v_value,
                            'currency', v_ag.currency, 'expires_at', v_voucher.expires_at, 'partner', v_ag.partner_name,
                            'status', 'ISSUED', 'replayed', false, 'balance', v_a.balance - p_points);
END $$;
REVOKE ALL ON FUNCTION pricing.redeem_at_partner(bigint, bigint, uuid, bigint, text, bytea, bytea, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pricing.redeem_at_partner(bigint, bigint, uuid, bigint, text, bytea, bytea, bigint) TO masslak_app;
COMMENT ON FUNCTION pricing.redeem_at_partner IS 'The member spends points for a voucher at a partner at the agreed rate; idempotent on the key (1107)';

-- ------------------------------------------------------------------ the partner honours a voucher
CREATE OR REPLACE FUNCTION pricing.accept_voucher(p_partner_id bigint, p_code_hash bytea, p_partner_ref text,
                                                  p_user_id bigint, p_api_client_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v record;
  v_payable bigint;
  v_id bigint;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: vouchers are accepted through the partner''s API client or by the platform' USING ERRCODE = 'P0001';
  END IF;
  SELECT rv.*, a.platform_share_pct, lp.status AS partner_status, lp.party_id AS partner_party_id,
         p.legal_name AS partner_name
    INTO v
    FROM pricing.reward_voucher rv JOIN pricing.loyalty_agreement a ON a.id = rv.agreement_id
    JOIN pricing.loyalty_partner lp ON lp.id = rv.loyalty_partner_id JOIN iam.party p ON p.id = lp.party_id
   WHERE rv.code_hash = p_code_hash FOR UPDATE OF rv;
  -- a code of another partner reads as unknown: a partner learns nothing about vouchers held elsewhere
  IF v.id IS NULL OR v.loyalty_partner_id <> p_partner_id THEN
    RAISE EXCEPTION 'VOUCHER_UNKNOWN: no voucher with this code at this partner' USING ERRCODE = 'P0001';
  END IF;
  IF v.status = 'USED' THEN
    RAISE EXCEPTION 'VOUCHER_USED: this voucher was used on %', to_char(v.used_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') USING ERRCODE = 'P0001';
  END IF;
  IF v.status <> 'ISSUED' OR v.expires_at <= now() THEN
    RAISE EXCEPTION 'VOUCHER_EXPIRED: this voucher is no longer valid' USING ERRCODE = 'P0001';
  END IF;
  IF v.partner_status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'PARTNER_NOT_ACTIVE: the partner''s agreement with the platform is not active' USING ERRCODE = 'P0001';
  END IF;
  v_payable := floor(v.value * v.platform_share_pct / 100);
  UPDATE pricing.reward_voucher SET status = 'USED', used_at = now() WHERE id = v.id;
  INSERT INTO pricing.partner_redemption (loyalty_partner_id, voucher_id, agreement_id, points, value, payable, commission, currency,
                                          partner_ref, accepted_by, api_client_id)
  VALUES (v.loyalty_partner_id, v.id, v.agreement_id, v.points, v.value, v_payable, v.value - v_payable, v.currency,
          nullif(btrim(coalesce(p_partner_ref, '')), ''), p_user_id, p_api_client_id)
  RETURNING id INTO v_id;
  INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
  VALUES ('voucher.used', 'reward_voucher', v.id,
          jsonb_build_object('user_id', v.user_id, 'partner', v.partner_name, 'amount', v.value, 'currency', v.currency));
  RETURN jsonb_build_object('redemption_id', v_id, 'voucher', v.uid, 'points', v.points, 'value', v.value, 'payable', v_payable,
                            'currency', v.currency, 'partner_party_id', v.partner_party_id, 'partner', v.partner_name);
END $$;
REVOKE ALL ON FUNCTION pricing.accept_voucher(bigint, bytea, text, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pricing.accept_voucher(bigint, bytea, text, bigint, bigint) TO masslak_app;
COMMENT ON FUNCTION pricing.accept_voucher IS 'The partner honours a voucher: recorded with what the platform owes it under the agreement; the caller posts the money (1107)';

-- ------------------------------------------------------------------ unused vouchers give the points back
CREATE OR REPLACE FUNCTION pricing.return_voucher(p_voucher_id bigint, p_status text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v record;
  v_ledger bigint;
BEGIN
  SELECT rv.id, rv.uid, rv.user_id, rv.points, rv.value, rv.currency, rv.status, l.account_id, a.program_id, g.point_value,
         l.id AS redeem_id
    INTO v
    FROM pricing.reward_voucher rv JOIN pricing.points_ledger l ON l.id = rv.points_ledger_id
    JOIN pricing.points_account a ON a.id = l.account_id JOIN pricing.loyalty_program g ON g.id = a.program_id
   WHERE rv.id = p_voucher_id FOR UPDATE OF rv;
  IF v.id IS NULL OR v.status <> 'ISSUED' THEN
    RETURN NULL;
  END IF;
  INSERT INTO pricing.points_ledger (account_id, txn_type, points, funded_by, idempotency_key, reverses_id)
  VALUES (v.account_id, 'REVERSE', v.points, 'PLATFORM', format('voucher-return:%s', v.id), v.redeem_id)
  RETURNING id INTO v_ledger;
  UPDATE pricing.points_account SET balance = balance + v.points WHERE id = v.account_id;
  PERFORM pricing.add_liability(v.program_id, NULL, 'REDEEMED', -(v.points * v.point_value));
  UPDATE pricing.reward_voucher SET status = p_status, returned_ledger_id = v_ledger WHERE id = v.id;
  INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
  VALUES ('voucher.returned', 'reward_voucher', v.id,
          jsonb_build_object('user_id', v.user_id, 'points', v.points, 'status', p_status));
  RETURN v_ledger;
END $$;
REVOKE ALL ON FUNCTION pricing.return_voucher(bigint, text) FROM PUBLIC;
COMMENT ON FUNCTION pricing.return_voucher IS 'An unused voucher expires or is cancelled and its points go back to the member (1107)';

CREATE OR REPLACE FUNCTION pricing.cancel_voucher(p_voucher uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v record;
BEGIN
  SELECT id, user_id, points, status INTO v FROM pricing.reward_voucher WHERE uid = p_voucher;
  IF v.id IS NULL OR (NOT sys.ctx_is_platform() AND v.user_id IS DISTINCT FROM sys.ctx_user_id()) THEN
    RAISE EXCEPTION 'NOT_FOUND: no such voucher' USING ERRCODE = 'P0001';
  END IF;
  IF v.status <> 'ISSUED' THEN
    RAISE EXCEPTION 'VOUCHER_NOT_OPEN: only an unused voucher is cancelled' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pricing.return_voucher(v.id, 'CANCELLED');
  RETURN jsonb_build_object('points', v.points, 'status', 'CANCELLED');
END $$;
REVOKE ALL ON FUNCTION pricing.cancel_voucher(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pricing.cancel_voucher(uuid) TO masslak_app;
COMMENT ON FUNCTION pricing.cancel_voucher IS 'The member (or the platform) cancels an unused voucher; the points come back (1107)';

CREATE OR REPLACE FUNCTION pricing.release_vouchers() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  r record;
  v_n integer := 0;
  v_points bigint := 0;
BEGIN
  FOR r IN
    SELECT rv.id, rv.points FROM pricing.reward_voucher rv
      LEFT JOIN pricing.loyalty_partner lp ON lp.id = rv.loyalty_partner_id
     WHERE rv.status = 'ISSUED' AND rv.points_ledger_id IS NOT NULL
       AND (rv.expires_at <= now() OR lp.status = 'ENDED')
     ORDER BY rv.id LIMIT 5000
  LOOP
    IF pricing.return_voucher(r.id, 'EXPIRED') IS NOT NULL THEN
      v_n := v_n + 1;
      v_points := v_points + r.points;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('vouchers', v_n, 'points', v_points);
END $$;
REVOKE ALL ON FUNCTION pricing.release_vouchers() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pricing.release_vouchers() TO masslak_app;
COMMENT ON FUNCTION pricing.release_vouchers IS 'Daily: vouchers past their date, or at a partner that has left, give their points back (1107)';

-- points given back by a voucher count as not spent when older earnings expire
CREATE OR REPLACE FUNCTION pricing.expire_points() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_a record;
  v_points bigint;
  v_accounts integer := 0;
  v_total bigint := 0;
BEGIN
  FOR v_a IN
    SELECT a.id, a.balance, a.program_id, g.point_value,
           (SELECT coalesce(sum(points), 0) FROM pricing.points_ledger l WHERE l.account_id = a.id AND l.txn_type = 'EARN'
               AND l.expires_at <= now()) AS due,
           (SELECT coalesce(-sum(points), 0) FROM pricing.points_ledger l WHERE l.account_id = a.id
               AND l.txn_type IN ('REDEEM','EXPIRE','REVERSE')) AS used
      FROM pricing.points_account a JOIN pricing.loyalty_program g ON g.id = a.program_id
     WHERE a.balance > 0 AND EXISTS (SELECT 1 FROM pricing.points_ledger l WHERE l.account_id = a.id AND l.txn_type = 'EARN'
                                       AND l.expires_at <= now())
     FOR UPDATE OF a
  LOOP
    -- points spent so far count against the oldest earnings first; what is past expiry and not spent leaves
    v_points := least(greatest(v_a.due - v_a.used, 0), v_a.balance);
    CONTINUE WHEN v_points <= 0;
    INSERT INTO pricing.points_ledger (account_id, txn_type, points, idempotency_key)
    VALUES (v_a.id, 'EXPIRE', -v_points, format('expire:%s:%s', v_a.id, v_a.due))
    ON CONFLICT (idempotency_key) DO NOTHING;
    CONTINUE WHEN NOT FOUND;
    UPDATE pricing.points_account SET balance = balance - v_points WHERE id = v_a.id;
    PERFORM pricing.add_liability(v_a.program_id, NULL, 'EXPIRED', v_points * v_a.point_value);
    v_accounts := v_accounts + 1;
    v_total := v_total + v_points;
  END LOOP;
  RETURN jsonb_build_object('accounts', v_accounts, 'points', v_total);
END $$;

-- ------------------------------------------------------------------ settlement with the partner
CREATE OR REPLACE FUNCTION pricing.open_loyalty_settlement(p_partner_id bigint, p_currency char(3), p_from date, p_to date,
                                                           p_user_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_id bigint;
  v_n integer;
  v_value bigint;
  v_payable bigint;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: partner settlements are drawn up by the platform' USING ERRCODE = 'P0001';
  END IF;
  IF p_to < p_from THEN
    RAISE EXCEPTION 'INVALID_PERIOD: the period ends before it starts' USING ERRCODE = 'P0001';
  END IF;
  PERFORM 1 FROM pricing.loyalty_partner WHERE id = p_partner_id FOR UPDATE;   -- one statement at a time per partner
  -- one snapshot of the unsettled redemptions makes both the statement's totals and its lines
  WITH due AS MATERIALIZED (
         SELECT r.id, r.value, r.payable FROM pricing.partner_redemption r
          WHERE r.loyalty_partner_id = p_partner_id AND r.currency = p_currency AND r.agreement_id IS NOT NULL
            AND r.redeemed_at >= p_from AND r.redeemed_at < p_to + 1
            AND NOT EXISTS (SELECT 1 FROM pricing.loyalty_settlement_line l WHERE l.redemption_id = r.id)),
       s AS (
         INSERT INTO pricing.loyalty_settlement (loyalty_partner_id, currency, period, redemptions, value, payable, created_by)
         SELECT p_partner_id, p_currency, daterange(p_from, p_to + 1), count(*), coalesce(sum(value), 0), coalesce(sum(payable), 0), p_user_id
           FROM due HAVING count(*) > 0
         RETURNING id, redemptions, value, payable),
       l AS (
         INSERT INTO pricing.loyalty_settlement_line (settlement_id, redemption_id, value, payable)
         SELECT s.id, due.id, due.value, due.payable FROM s CROSS JOIN due RETURNING settlement_id)
  SELECT s.id, s.redemptions, s.value, s.payable INTO v_id, v_n, v_value, v_payable FROM s;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'NOTHING_TO_SETTLE: no honoured vouchers left to settle in this period' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object('settlement_id', v_id, 'redemptions', v_n, 'value', v_value, 'payable', v_payable);
END $$;
REVOKE ALL ON FUNCTION pricing.open_loyalty_settlement(bigint, char, date, date, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pricing.open_loyalty_settlement(bigint, char, date, date, bigint) TO masslak_app;
COMMENT ON FUNCTION pricing.open_loyalty_settlement IS 'Drafts a partner''s statement from its unsettled honoured vouchers of a period (1107)';

-- a cancelled draft frees its redemptions for the next statement
CREATE OR REPLACE FUNCTION pricing.tg_loyalty_settlement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.status = 'CANCELLED' AND OLD.status <> 'CANCELLED' THEN
    IF OLD.status <> 'DRAFT' THEN
      RAISE EXCEPTION 'SETTLEMENT_NOT_DRAFT: only a draft statement is cancelled' USING ERRCODE = 'P0001';
    END IF;
    DELETE FROM pricing.loyalty_settlement_line WHERE settlement_id = NEW.id;
  END IF;
  IF NEW.status = 'APPROVED' AND OLD.status <> 'DRAFT' THEN
    RAISE EXCEPTION 'SETTLEMENT_NOT_DRAFT: only a draft statement is approved' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'PAID' AND OLD.status <> 'APPROVED' THEN
    RAISE EXCEPTION 'SETTLEMENT_NOT_APPROVED: a statement is paid once approved' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.status IN ('PAID', 'CANCELLED') AND NEW IS DISTINCT FROM OLD THEN
    RAISE EXCEPTION 'SETTLEMENT_CLOSED: a paid or cancelled statement does not change' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS loyalty_settlement_rules ON pricing.loyalty_settlement;
CREATE TRIGGER loyalty_settlement_rules BEFORE UPDATE ON pricing.loyalty_settlement
  FOR EACH ROW EXECUTE FUNCTION pricing.tg_loyalty_settlement();

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('pricing.loyalty_agreement', '1B', 'E15'), ('pricing.loyalty_settlement', '1B', 'E15'), ('pricing.loyalty_settlement_line', '1B', 'E15')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('pricing.loyalty_agreement', 'PLATFORM_CONFIDENTIAL', NULL, 'commercial terms agreed with each loyalty partner (1107)'),
  ('pricing.loyalty_settlement', 'PLATFORM_CONFIDENTIAL', NULL, 'statements and payments of honoured vouchers to partners (1107)'),
  ('pricing.loyalty_settlement_line', 'PLATFORM_CONFIDENTIAL', NULL, 'the honoured vouchers each partner statement covers (1107)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('pricing.loyalty_agreement', 'pricing records', 'redemption agreements with loyalty partners (1107)'),
  ('pricing.loyalty_settlement', 'pricing records', 'settlements of honoured vouchers with loyalty partners (1107)'),
  ('pricing.loyalty_settlement_line', 'pricing records', 'the vouchers each partner settlement covers (1107)')
ON CONFLICT (table_name) DO NOTHING;

-- the money transactions name the redemption or the statement they pay
UPDATE sys.polymorphic_reference
   SET targets = targets || '{"partner_redemption": "pricing.partner_redemption", "loyalty_settlement": "pricing.loyalty_settlement"}'::jsonb
 WHERE table_name = 'fin.ledger_txn' AND NOT targets ? 'loyalty_settlement';

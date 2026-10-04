-- =====================================================================
-- 1015: loyalty partners and redemption (study 4.6, 5.13 f), campaign controls and sponsors (5.12 f)
--   Reward catalog, loyalty partners (rest stops, fuel, retail, airlines), redemption channels, award seats,
--   single-use redemption tokens, vouchers, points transfers to and from other programs, the points liability,
--   sponsors and their receivables, card BIN ranges for bank campaigns, and individual override policies.
-- =====================================================================

CREATE TABLE IF NOT EXISTS pricing.loyalty_partner (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id        bigint NOT NULL REFERENCES pricing.loyalty_program(id),
  party_id          bigint NOT NULL REFERENCES iam.party(id),
  service_partner_id bigint REFERENCES ptn.partner(id),               -- when the partner is also a service partner
  partner_type      text NOT NULL CHECK (partner_type IN ('REST_STOP','FUEL','RETAIL','AIRLINE','TRAVEL','OTHER')),
  earn_rate         numeric(8,4) NOT NULL DEFAULT 0 CHECK (earn_rate >= 0),     -- points per currency unit spent
  burn_rate         numeric(8,4) NOT NULL DEFAULT 0 CHECK (burn_rate >= 0),     -- currency value of one point
  conversion_ratio  numeric(10,4),                                    -- partner units per point (transfers)
  settlement_cycle  text NOT NULL DEFAULT 'MONTHLY' CHECK (settlement_cycle IN ('WEEKLY','MONTHLY','QUARTERLY')),
  contract_ref      text,
  status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','ENDED')),
  UNIQUE (program_id, party_id)
);
COMMENT ON TABLE pricing.loyalty_partner IS 'Earn and burn partner of the loyalty program (5.13 f); extends the partner register';

CREATE TABLE IF NOT EXISTS pricing.reward_catalog (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id         bigint NOT NULL REFERENCES pricing.loyalty_program(id),
  loyalty_partner_id bigint REFERENCES pricing.loyalty_partner(id),
  reward_type        text NOT NULL CHECK (reward_type IN ('INTERNAL','PARTNER','EXTERNAL')),
  name               text NOT NULL,
  points_cost        bigint NOT NULL CHECK (points_cost > 0),
  conversion_value   bigint NOT NULL CHECK (conversion_value >= 0),   -- value in minor units
  currency           char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  commission_bp      int NOT NULL DEFAULT 0 CHECK (commission_bp BETWEEN 0 AND 10000),
  external_code      text,
  valid              daterange NOT NULL DEFAULT daterange(current_date, NULL),
  status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  CHECK (reward_type = 'INTERNAL' OR loyalty_partner_id IS NOT NULL OR external_code IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS pricing.redemption_channel (
  code        text PRIMARY KEY CHECK (code IN ('TRIP','UPGRADE','REST_STOP','PARTNER','TRANSFER','STORE')),
  rules       jsonb NOT NULL DEFAULT '{}',
  min_points  bigint NOT NULL DEFAULT 0,
  max_points  bigint,
  active      boolean NOT NULL DEFAULT true,
  CHECK (max_points IS NULL OR max_points >= min_points)
);
INSERT INTO pricing.redemption_channel (code) VALUES ('TRIP'),('UPGRADE'),('REST_STOP'),('PARTNER'),('TRANSFER'),('STORE')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS pricing.award_seat_rule (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id      bigint NOT NULL REFERENCES iam.company(id),
  line_id         bigint REFERENCES net.line(id),
  route_id        bigint REFERENCES net.route(id),
  cabin           text,
  points_cost     bigint NOT NULL CHECK (points_cost > 0),
  quota           int NOT NULL CHECK (quota >= 0),                    -- award seats per trip
  blackout_dates  date[] NOT NULL DEFAULT '{}',
  valid           daterange NOT NULL DEFAULT daterange(current_date, NULL),
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  CHECK ((line_id IS NULL) <> (route_id IS NULL))
);
COMMENT ON TABLE pricing.award_seat_rule IS 'Seats a carrier releases for points on a line or route, with blackout dates';

CREATE TABLE IF NOT EXISTS pricing.redemption_token (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id       bigint NOT NULL REFERENCES iam.app_user(id),
  channel_code  text NOT NULL REFERENCES pricing.redemption_channel(code),
  token_hash    bytea NOT NULL UNIQUE,
  method        text NOT NULL CHECK (method IN ('QR','MEMBER_ID','MOBILE_OTP','API')),
  expires_at    timestamptz NOT NULL,
  used_at       timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE pricing.redemption_token IS 'Single-use temporary token presented at a partner to redeem points';

CREATE TABLE IF NOT EXISTS pricing.reward_voucher (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id            bigint NOT NULL REFERENCES iam.app_user(id),
  catalog_id         bigint REFERENCES pricing.reward_catalog(id),
  loyalty_partner_id bigint REFERENCES pricing.loyalty_partner(id),
  points_ledger_id   bigint REFERENCES pricing.points_ledger(id),
  code_hash          bytea NOT NULL UNIQUE,
  points             bigint NOT NULL CHECK (points > 0),
  value              bigint NOT NULL CHECK (value >= 0),
  currency           char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  expires_at         timestamptz NOT NULL,
  used_at            timestamptz,
  status             text NOT NULL DEFAULT 'ISSUED' CHECK (status IN ('ISSUED','USED','EXPIRED','CANCELLED')),
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pricing.partner_redemption (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  loyalty_partner_id bigint NOT NULL REFERENCES pricing.loyalty_partner(id),
  voucher_id         bigint REFERENCES pricing.reward_voucher(id),
  token_id           bigint REFERENCES pricing.redemption_token(id),
  partner_sale_id    bigint REFERENCES ptn.partner_sale(id),
  points             bigint NOT NULL CHECK (points > 0),
  value              bigint NOT NULL CHECK (value >= 0),
  commission         bigint NOT NULL DEFAULT 0,
  currency           char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  redeemed_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (voucher_id IS NOT NULL OR token_id IS NOT NULL)
);
COMMENT ON TABLE pricing.partner_redemption IS 'Points spent at a partner; the basis of partner settlement and of the liability release';

CREATE TABLE IF NOT EXISTS pricing.points_transfer (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id         bigint NOT NULL REFERENCES pricing.points_account(id),
  loyalty_partner_id bigint NOT NULL REFERENCES pricing.loyalty_partner(id),
  direction          text NOT NULL CHECK (direction IN ('OUT','IN')),
  points             bigint NOT NULL CHECK (points > 0),
  external_units     numeric(14,2) NOT NULL CHECK (external_units > 0),
  ratio              numeric(10,4) NOT NULL CHECK (ratio > 0),
  external_ref       text,
  points_ledger_id   bigint REFERENCES pricing.points_ledger(id),
  status             text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','COMPLETED','FAILED','REVERSED')),
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pricing.points_liability (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id       bigint NOT NULL REFERENCES pricing.loyalty_program(id),
  issuer_party_id  bigint REFERENCES iam.party(id),                    -- empty: the platform
  period           daterange NOT NULL,
  issued           bigint NOT NULL DEFAULT 0,
  redeemed         bigint NOT NULL DEFAULT 0,
  expired          bigint NOT NULL DEFAULT 0,
  breakage_est     bigint NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (program_id, issuer_party_id, period)
);
COMMENT ON TABLE pricing.points_liability IS 'Accounting liability of outstanding points per issuer and period, with estimated breakage';

-- ------------------------------ campaign controls (5.12 f) ------------------------------
ALTER TABLE pricing.campaign ADD COLUMN IF NOT EXISTS budget_alert_pct smallint;
DO $$ BEGIN
  ALTER TABLE pricing.campaign ADD CONSTRAINT campaign_budget_alert_ck CHECK (budget_alert_pct IS NULL OR budget_alert_pct BETWEEN 1 AND 100);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN pricing.campaign.budget_alert_pct IS 'Alert when this share of budget_total is spent (campaign_budget in 5.12 f)';

CREATE TABLE IF NOT EXISTS pricing.sponsor_account (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind                text NOT NULL CHECK (kind IN ('PLATFORM','CARRIER','BANK','PARTNER')),
  party_id            bigint NOT NULL REFERENCES iam.party(id),
  wallet_id           bigint REFERENCES fin.wallet(id),
  receivable_balance  bigint NOT NULL DEFAULT 0,
  currency            char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status              text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
  UNIQUE (party_id, currency)
);
COMMENT ON TABLE pricing.sponsor_account IS 'Who funds a discount, and what they owe the platform for it';

ALTER TABLE pricing.campaign ADD COLUMN IF NOT EXISTS sponsor_account_id bigint REFERENCES pricing.sponsor_account(id);
ALTER TABLE fin.price_allocation_line ADD COLUMN IF NOT EXISTS sponsor_account_id bigint REFERENCES pricing.sponsor_account(id);
ALTER TABLE fin.price_allocation_line ADD COLUMN IF NOT EXISTS funded_by text;
DO $$ BEGIN
  ALTER TABLE fin.price_allocation_line ADD CONSTRAINT price_allocation_line_funded_by_ck
    CHECK (funded_by IS NULL OR funded_by IN ('PLATFORM','CARRIER','BANK','PARTNER'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS pricing.bin_range (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bank_party_id  bigint NOT NULL REFERENCES iam.party(id),
  from_bin       char(8) NOT NULL CHECK (from_bin ~ '^[0-9]{6,8}$'),
  to_bin         char(8) NOT NULL CHECK (to_bin ~ '^[0-9]{6,8}$'),
  card_type      text NOT NULL CHECK (card_type IN ('DEBIT','CREDIT','PREPAID')),
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED')),
  CHECK (from_bin <= to_bin)
);
COMMENT ON TABLE pricing.bin_range IS 'Card number ranges of a bank, used to target bank-funded campaigns';

CREATE TABLE IF NOT EXISTS pricing.override_policy (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  target_type   text NOT NULL CHECK (target_type IN ('USER','COMPANY')),
  user_id       bigint REFERENCES iam.app_user(id),
  company_id    bigint REFERENCES iam.company(id),
  policy_key    text NOT NULL CHECK (policy_key IN ('FEE_BEARER','DISCOUNT','COMMISSION','PAYMENT_FEE')),
  value         jsonb NOT NULL,
  valid         tstzrange NOT NULL,
  reason        text NOT NULL,
  created_by    bigint NOT NULL REFERENCES iam.app_user(id),
  approved_by   bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((target_type = 'USER' AND user_id IS NOT NULL AND company_id IS NULL)
      OR (target_type = 'COMPANY' AND company_id IS NOT NULL AND user_id IS NULL)),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);
COMMENT ON TABLE pricing.override_policy IS 'An approved individual exception to a fee or discount rule, with its reason and period';

-- ------------------------------ isolation and privileges ------------------------------
DO $$ BEGIN
  PERFORM sys.rls_catalog(t) FROM unnest(ARRAY['pricing.loyalty_partner','pricing.reward_catalog','pricing.redemption_channel',
    'pricing.bin_range']) t;
  PERFORM sys.rls_split('pricing.award_seat_rule', 'true', 'sys.tenant_visible(company_id)');
  PERFORM sys.rls(t, 'sys.ctx_is_platform() OR sys.is_me(user_id)') FROM unnest(ARRAY['pricing.redemption_token','pricing.reward_voucher']) t;
  PERFORM sys.rls_platform(t) FROM unnest(ARRAY['pricing.partner_redemption','pricing.points_liability','pricing.sponsor_account']) t;
  -- points accounts have no policy of their own: check the owner explicitly
  PERFORM sys.rls('pricing.points_transfer', 'sys.ctx_is_platform()
    OR EXISTS (SELECT 1 FROM pricing.points_account a WHERE a.id = account_id AND a.party_id = sys.ctx_party_id())');
  PERFORM sys.rls('pricing.override_policy', 'sys.ctx_is_platform()');
  PERFORM sys.grant_rw(ARRAY['pricing.loyalty_partner','pricing.reward_catalog','pricing.redemption_channel','pricing.award_seat_rule',
    'pricing.redemption_token','pricing.reward_voucher','pricing.points_transfer','pricing.points_liability',
    'pricing.sponsor_account','pricing.bin_range','pricing.override_policy']);
  PERFORM sys.grant_append(ARRAY['pricing.partner_redemption']);
END $$;

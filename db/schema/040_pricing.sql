-- =====================================================================
-- 040: fares, brands, taxes, commissions, allocation templates, campaigns and loyalty
-- Source: 4.6, 4.12 b, 5.1 to 5.9, 5.12, 5.13
-- Every financial rule is versioned with dual approval (creator <> approver), and the price is frozen on the booking.
-- =====================================================================

-- ------------------------------ Fare brands (5.9) -----------------
CREATE TABLE pricing.fare_brand (
  code        text PRIMARY KEY,                       -- ECONOMY_SAVER, FLEX ...
  company_id  bigint REFERENCES iam.company(id),      -- empty = shared brand
  name        text NOT NULL,
  factor      numeric(6,4) NOT NULL DEFAULT 1 CHECK (factor > 0),
  rules       jsonb NOT NULL,                         -- {refundable, refund:[[hours,pct]], changeable, change_fee_pct, bags_included, kg_per_piece, priority_boarding}
  sort        smallint NOT NULL DEFAULT 0,
  active      boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE pricing.fare_brand IS 'Fare brands with ticket, baggage and refund conditions; a snapshot is copied to the ticket';

-- ------------------------------ Fare tables -------------------------
CREATE TABLE pricing.fare_table (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope       text NOT NULL CHECK (scope IN ('CENTRAL','COMPANY')),
  company_id  bigint REFERENCES iam.company(id),
  route_id    bigint REFERENCES net.route(id),
  currency    char(3) NOT NULL REFERENCES ref.currency(code),
  locked      boolean NOT NULL DEFAULT false,         -- locked = central pricing the company cannot change
  min_price   bigint CHECK (min_price >= 0),
  max_price   bigint CHECK (max_price >= 0),
  valid       tstzrange NOT NULL,
  version     int NOT NULL DEFAULT 1,
  status      text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','RETIRED')),
  created_by  bigint REFERENCES iam.app_user(id),
  approved_by bigint REFERENCES iam.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (scope = 'CENTRAL' OR company_id IS NOT NULL),
  CHECK (min_price IS NULL OR max_price IS NULL OR min_price <= max_price)
);
COMMENT ON TABLE pricing.fare_table IS 'Central (locked) fare table or carrier fare table within limits (5.2)';

CREATE TABLE pricing.fare_table_item (
  fare_table_id      bigint NOT NULL REFERENCES pricing.fare_table(id) ON DELETE CASCADE,
  from_station_id    bigint NOT NULL REFERENCES net.station(id),
  to_station_id      bigint NOT NULL REFERENCES net.station(id),
  cabin              text NOT NULL DEFAULT 'ECONOMY',
  passenger_category text NOT NULL DEFAULT 'ADULT' CHECK (passenger_category IN ('ADULT','CHILD','INFANT','STUDENT','SENIOR','DISABLED')),
  base_price         bigint NOT NULL CHECK (base_price >= 0),
  PRIMARY KEY (fare_table_id, from_station_id, to_station_id, cabin, passenger_category)
);

CREATE TABLE pricing.pricing_modifier (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint REFERENCES iam.company(id),
  type          text NOT NULL CHECK (type IN ('SEASON','PEAK','WEEKDAY','EARLY','LOAD','CATEGORY')),
  condition     jsonb NOT NULL,
  action_type   text NOT NULL CHECK (action_type IN ('PCT','FIXED')),
  action_value  numeric(12,4) NOT NULL,
  priority      smallint NOT NULL DEFAULT 100,
  valid         tstzrange NOT NULL,
  active        boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE pricing.pricing_modifier IS 'Dynamic pricing modifiers applied in order (5.3)';

-- ------------------------------ Taxes (5.6, 5.8) -------------------
CREATE TABLE pricing.jurisdiction (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  country_code  char(2) NOT NULL REFERENCES ref.country(code),
  level         text NOT NULL CHECK (level IN ('COUNTRY','REGION','BORDER','LOCAL')),
  parent_id     bigint REFERENCES pricing.jurisdiction(id),
  name          text NOT NULL
);
COMMENT ON TABLE pricing.jurisdiction IS 'Tax jurisdiction (country, region, border crossing, local)';

CREATE TABLE pricing.tax_scheme (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code                text NOT NULL,
  name                text NOT NULL,
  jurisdiction_id     bigint NOT NULL REFERENCES pricing.jurisdiction(id),
  tax_type            text NOT NULL CHECK (tax_type IN ('VAT','SALES','LEVY','FEE','STAMP','WITHHOLDING','OTHER')),
  treatment           text NOT NULL DEFAULT 'STANDARD' CHECK (treatment IN ('STANDARD','ZERO','EXEMPT','OUT_OF_SCOPE','REVERSE')),
  scope               jsonb NOT NULL DEFAULT '{}',    -- what it applies to: trip type, service, category...
  collected_by        text NOT NULL CHECK (collected_by IN ('CARRIER','PLATFORM','AUTHORITY')),
  payable_to_party_id bigint REFERENCES iam.party(id),
  valid               tstzrange NOT NULL,
  version             int NOT NULL DEFAULT 1,
  status              text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','RETIRED')),
  created_by          bigint REFERENCES iam.app_user(id),
  approved_by         bigint REFERENCES iam.app_user(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (code, version),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);
COMMENT ON TABLE pricing.tax_scheme IS 'Tax or fee scheme with its treatment, jurisdiction and collecting party, versioned with dual approval';

CREATE TABLE pricing.tax_rule (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scheme_id     bigint NOT NULL REFERENCES pricing.tax_scheme(id) ON DELETE CASCADE,
  seq           smallint NOT NULL,
  calc_method   text NOT NULL CHECK (calc_method IN ('PERCENT','FIXED','TIERED','FORMULA')),
  rate          numeric(9,6),
  amount        bigint,
  base_type     text NOT NULL DEFAULT 'FARE',
  base_include  jsonb NOT NULL DEFAULT '[]',
  compound_mode text NOT NULL DEFAULT 'ADD' CHECK (compound_mode IN ('ADD','CASCADE','MAX','MIN')),
  min_amount    bigint,
  max_amount    bigint,
  rounding_rule text NOT NULL DEFAULT 'HALF_UP',
  applies_per   text NOT NULL DEFAULT 'TICKET' CHECK (applies_per IN ('PASSENGER','TICKET','SEGMENT','KG','BOOKING')),
  priority      smallint NOT NULL DEFAULT 100,
  UNIQUE (scheme_id, seq)
);

CREATE TABLE pricing.rate_band (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tax_rule_id bigint REFERENCES pricing.tax_rule(id) ON DELETE CASCADE,
  commission_rule_id bigint,                          -- FK added after commission_rule
  dimension   text NOT NULL CHECK (dimension IN ('AMOUNT','DISTANCE','WEIGHT','VOLUME','SALES')),
  from_value  numeric(18,4) NOT NULL,
  to_value    numeric(18,4),
  rate        numeric(9,6),
  amount      bigint,
  mode        text NOT NULL DEFAULT 'WHOLE' CHECK (mode IN ('MARGINAL','WHOLE')),
  CHECK ((tax_rule_id IS NULL) <> (commission_rule_id IS NULL))
);
COMMENT ON TABLE pricing.rate_band IS 'Calculation bands for a tax or commission rule';

-- ------------------------------ Commissions ------------------------------
CREATE TABLE pricing.commission_scheme (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code              text NOT NULL,
  type              text NOT NULL CHECK (type IN ('PLATFORM','INTERMEDIARY','SUB_AGENT','OVERRIDE','PAYMENT','REFERRAL')),
  funded_by         text NOT NULL CHECK (funded_by IN ('CARRIER','PLATFORM','CUSTOMER','CHANNEL')),
  beneficiary_role  text NOT NULL,
  scope             jsonb NOT NULL DEFAULT '{}',
  base_type         text NOT NULL DEFAULT 'FARE',
  valid             tstzrange NOT NULL,
  version           int NOT NULL DEFAULT 1,
  status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','RETIRED')),
  created_by        bigint REFERENCES iam.app_user(id),
  approved_by       bigint REFERENCES iam.app_user(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (code, version),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);

CREATE TABLE pricing.commission_rule (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scheme_id     bigint NOT NULL REFERENCES pricing.commission_scheme(id) ON DELETE CASCADE,
  seq           smallint NOT NULL,
  calc_method   text NOT NULL CHECK (calc_method IN ('PERCENT','FIXED','TIERED')),
  rate          numeric(9,6),
  amount        bigint,
  min_amount    bigint,
  max_amount    bigint,
  cap_period    text,
  UNIQUE (scheme_id, seq)
);
ALTER TABLE pricing.rate_band ADD CONSTRAINT rate_band_commission_fk FOREIGN KEY (commission_rule_id) REFERENCES pricing.commission_rule(id) ON DELETE CASCADE;
COMMENT ON TABLE pricing.commission_scheme IS 'Commission scheme (platform, intermediary, payment, referral) with funder, beneficiary and versions';

-- ------------------------------ Price allocation templates (5.7) --------------
CREATE TABLE pricing.allocation_template (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code               text NOT NULL,
  scope              jsonb NOT NULL DEFAULT '{}',
  anchor_line_code   text NOT NULL,
  rounding_line_code text NOT NULL,
  version            int NOT NULL DEFAULT 1,
  status             text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','RETIRED')),
  created_by         bigint REFERENCES iam.app_user(id),
  approved_by        bigint REFERENCES iam.app_user(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (code, version),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);

CREATE TABLE pricing.allocation_template_line (
  template_id     bigint NOT NULL REFERENCES pricing.allocation_template(id) ON DELETE CASCADE,
  code            text NOT NULL,
  level           smallint NOT NULL,
  parent_code     text,
  component_type  text NOT NULL CHECK (component_type IN ('FARE','SEAT','BAGGAGE','TAX','FEE','COMMISSION','PLATFORM_FEE','PAYMENT_FEE','DISCOUNT','SPONSOR','ROUNDING')),
  beneficiary_ref text NOT NULL,                      -- CARRIER, PLATFORM, CHANNEL, TAX:<scheme>, SPONSOR
  basis           text NOT NULL CHECK (basis IN ('PCT_TOTAL','PCT_PARENT','FIXED','RESIDUAL','RULE')),
  value           numeric(18,6),
  rule_ref        text,
  wallet_type     text NOT NULL,
  release_event   text NOT NULL DEFAULT 'TRIP_COMPLETED' CHECK (release_event IN ('PAYMENT','TRIP_DEPARTED','TRIP_COMPLETED','MANUAL')),
  refundable      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (template_id, code)
);
COMMENT ON TABLE pricing.allocation_template IS 'Template of the price allocation tree across beneficiaries (carrier, platform, tax, intermediary)';

-- ------------------------------ Campaigns and offers (5.4, 5.12) ----------
CREATE TABLE pricing.campaign (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  code            text NOT NULL UNIQUE,
  name            text NOT NULL,
  company_id      bigint REFERENCES iam.company(id),  -- empty = platform campaign
  audience_rule   jsonb NOT NULL DEFAULT '{}',
  scope_rule      jsonb NOT NULL DEFAULT '{}',
  trigger         text NOT NULL DEFAULT 'AUTO' CHECK (trigger IN ('AUTO','CODE','BIN','LOYALTY_TIER')),
  benefit         jsonb NOT NULL,                     -- {type: PCT|FIXED|FREE_SEAT, value, cap}
  funding         jsonb NOT NULL,                     -- {platform_pct, carrier_pct, sponsor_party_id}
  budget_total    bigint CHECK (budget_total >= 0),
  budget_spent    bigint NOT NULL DEFAULT 0 CHECK (budget_spent >= 0),
  per_user_limit  int,
  per_day_limit   int,
  stackable       boolean NOT NULL DEFAULT false,
  priority        smallint NOT NULL DEFAULT 100,
  valid           tstzrange NOT NULL,
  status          text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED','LIVE','PAUSED','ENDED')),
  created_by      bigint REFERENCES iam.app_user(id),
  approved_by     bigint REFERENCES iam.app_user(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (approved_by IS NULL OR approved_by <> created_by),
  CHECK (budget_total IS NULL OR budget_spent <= budget_total)
);
COMMENT ON TABLE pricing.campaign IS 'Campaign: audience, scope, benefit, funding, budget and limits (condition -> action)';

CREATE TABLE pricing.promo_code (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campaign_id bigint NOT NULL REFERENCES pricing.campaign(id),
  code        citext NOT NULL UNIQUE,
  max_uses    int,
  uses        int NOT NULL DEFAULT 0,
  owner_party_id bigint REFERENCES iam.party(id),     -- agency or referral
  CHECK (max_uses IS NULL OR uses <= max_uses)
);

-- ------------------------------ Loyalty (5.5, 5.13) -------------------
CREATE TABLE pricing.loyalty_program (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code          text NOT NULL UNIQUE,
  name          text NOT NULL,
  point_value   bigint NOT NULL,                      -- point value in minor units (Decision 74)
  currency      char(3) NOT NULL REFERENCES ref.currency(code),
  expiry_months smallint NOT NULL DEFAULT 24,
  tax_treatment jsonb NOT NULL DEFAULT '{}',          -- tax treatment per movement type (5.13 g)
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAUSED','CLOSED'))
);

CREATE TABLE pricing.loyalty_tier (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id  bigint NOT NULL REFERENCES pricing.loyalty_program(id),
  code        text NOT NULL,
  name        text NOT NULL,
  min_points  bigint NOT NULL DEFAULT 0,
  benefits    jsonb NOT NULL DEFAULT '{}',
  UNIQUE (program_id, code)
);

CREATE TABLE pricing.loyalty_rule (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id  bigint NOT NULL REFERENCES pricing.loyalty_program(id),
  kind        text NOT NULL CHECK (kind IN ('EARN','BURN')),
  condition   jsonb NOT NULL DEFAULT '{}',
  formula     jsonb NOT NULL,                         -- {per_amount, points, multiplier}
  funded_by   text NOT NULL DEFAULT 'PLATFORM' CHECK (funded_by IN ('PLATFORM','CARRIER','PARTNER')),
  valid       tstzrange NOT NULL,
  version     int NOT NULL DEFAULT 1,
  active      boolean NOT NULL DEFAULT true
);

CREATE TABLE pricing.points_account (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id  bigint NOT NULL REFERENCES pricing.loyalty_program(id),
  party_id    bigint NOT NULL REFERENCES iam.party(id),
  tier_id     bigint REFERENCES pricing.loyalty_tier(id),
  balance     bigint NOT NULL DEFAULT 0 CHECK (balance >= 0),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (program_id, party_id)
);
COMMENT ON TABLE pricing.points_account IS 'Points account; the balance is stored and reconciled with the points ledger';

CREATE TABLE pricing.points_ledger (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id      bigint NOT NULL REFERENCES pricing.points_account(id),
  txn_type        text NOT NULL CHECK (txn_type IN ('EARN','REDEEM','EXPIRE','ADJUST','REVERSE')),
  points          bigint NOT NULL CHECK (points <> 0),   -- positive for earning, negative for redemption and expiry
  booking_id      bigint,                             -- FK added after sales.booking
  rule_id         bigint REFERENCES pricing.loyalty_rule(id),
  funded_by       text,
  idempotency_key text NOT NULL UNIQUE,
  expires_at      timestamptz,
  reverses_id     bigint REFERENCES pricing.points_ledger(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX points_ledger_account_idx ON pricing.points_ledger (account_id, created_at);
CREATE TRIGGER points_ledger_immutable BEFORE UPDATE OR DELETE ON pricing.points_ledger
  FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE pricing.points_ledger IS 'Points ledger: append-only, corrections by reversing entry';

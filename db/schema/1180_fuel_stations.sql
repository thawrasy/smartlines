-- 1180: fuel stations (owner's note of 25 October 2026, docs/design/FUEL_STATIONS.md), built on the study's partner
-- tables (1014), not beside them.
--
-- A fuel company (company type FUEL_COMPANY) signs in to its own portal, FUEL, and owns one station or a chain of them
-- (ptn.partner of type FUEL). Its attendants work at the pump from the same portal on a phone: they identify the vehicle
-- by its NFC card (the tag holds a random identifier only; the platform keeps its hash) or by a short-lived code the
-- driver's app shows, see the budget left, fill, photograph the pump's meter and enter its figures.
--
-- Money is paid in advance to the fuel company, never to the platform, which keeps the account only: in the phase
-- without funds (1145) as after it. A carrier, a taxi owner or a rental company holds a fuel account with each fuel
-- company it uses; the fuel company records each sum it receives (TOPUP), each fill takes its amount (FILL), a fill
-- found wrong is given back (REVERSAL). Each vehicle's card carries a budget per day, week or month, as an amount,
-- litres or both; a fill beyond the budget or the balance is refused.
--
-- Every fill is checked: litres x the price in force against the amount on the meter, the litres against the tank, the
-- odometer against the last reading and the consumption since. A fill outside the limits opens anomalies and the sale is
-- held (PENDING) until the vehicle's owner, the fuel company or the platform decides; a confirmed anomaly marks the
-- sale disputed. What the pump measured, the photo of the meter, and the account's entries never change.

-- ------------------------------------------------------------------ 1. the portal, the company type, the rights
ALTER TABLE iam.user_session DROP CONSTRAINT IF EXISTS user_session_portal_check;
ALTER TABLE iam.user_session ADD CONSTRAINT user_session_portal_check
  CHECK (portal IN ('PLATFORM', 'OPERATOR', 'AGENCY', 'PASSENGER', 'DRIVER', 'INSPECTOR', 'STATION', 'FUEL')) NOT VALID;
ALTER TABLE iam.user_session VALIDATE CONSTRAINT user_session_portal_check;

ALTER TABLE iam.company DROP CONSTRAINT IF EXISTS company_company_type_check;
ALTER TABLE iam.company ADD CONSTRAINT company_company_type_check
  CHECK (company_type IN ('CARRIER', 'INDIVIDUAL_OPERATOR', 'FOREIGN_CARRIER', 'AGENCY', 'PARTNER', 'SCHOOL', 'GOVERNMENT',
                          'STATION_OPERATOR', 'FUEL_COMPANY'));

INSERT INTO ref.party_role_type (code, name, module, is_system, sort) VALUES
  ('FUEL_COMPANY', 'Fuel company', 'fuel', true, 66),
  ('FUEL_STAFF', 'Staff of a fuel company', 'fuel', true, 67)
ON CONFLICT (code) DO NOTHING;

INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('fuel.manage', 'fuel', 'COMPANY', 'Run a fuel company: its stations, prices, attendants, the accounts it holds and their top-ups, anomalies', true),
  ('fuel.attend', 'fuel', 'COMPANY', 'Fill vehicles at the pump of the stations the attendant is assigned to', false)
ON CONFLICT (code) DO NOTHING;
-- a fuel company's roles serve the kind FUEL (1154)
ALTER TABLE iam.role DROP CONSTRAINT IF EXISTS role_company_kind_ck;
ALTER TABLE iam.role ADD CONSTRAINT role_company_kind_ck
  CHECK ((scope = 'PLATFORM' AND company_kind IS NULL) OR (scope = 'COMPANY' AND company_kind IN ('CARRIER', 'AGENCY', 'STATION', 'FUEL')));
INSERT INTO iam.role (code, name, scope, is_system, company_kind, description)
SELECT v.code, v.name, 'COMPANY', true, 'FUEL', v.descr
  FROM (VALUES ('FUEL_MANAGER', 'Fuel company manager (template)', 'Stations, prices, attendants, accounts and their top-ups, anomalies; also fills'),
               ('FUEL_ATTENDANT', 'Pump attendant (template)', 'Fills vehicles at the pumps of the stations the attendant is assigned to')) v(code, name, descr)
 WHERE NOT EXISTS (SELECT 1 FROM iam.role r WHERE r.code = v.code AND r.company_id IS NULL);
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, p.code FROM iam.role r JOIN (VALUES ('FUEL_MANAGER', 'fuel.manage'), ('FUEL_MANAGER', 'fuel.attend'),
                                                 ('FUEL_ATTENDANT', 'fuel.attend')) p(role, code) ON p.role = r.code
 WHERE r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- a staff portal: two-factor sign-in as for the station portal (1099), and its idle sign-out (1146)
UPDATE sys.setting
   SET value = jsonb_set(value, '{required_portals}', (value -> 'required_portals') || '["FUEL"]'::jsonb), updated_at = now()
 WHERE key = 'auth.mfa' AND (value -> 'required_portals') ? 'STATION' AND NOT (value -> 'required_portals') ? 'FUEL';
UPDATE sys.setting SET value = jsonb_set(value, '{minutes,FUEL}', '30'::jsonb), updated_at = now()
 WHERE key = 'auth.idle' AND NOT (value -> 'minutes') ? 'FUEL';

INSERT INTO sys.setting (key, value, description) VALUES
  ('fuel.checks', '{"amount_tolerance_pct": 1, "tank_margin_pct": 5, "consumption_margin_pct": 25,
                    "default_l_per_100km": 40, "photo_required": true, "code_seconds": 120}'::jsonb,
   'Checks of a fill (1180): the meter''s amount may differ from litres x price by amount_tolerance_pct; litres above the tank by tank_margin_pct, or a consumption above the vehicle''s expected by consumption_margin_pct (default_l_per_100km without a profile), hold the sale; photo_required asks for the meter''s photo; code_seconds is the life of the code the driver''s app shows')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------ 2. a fuel company's stations
-- a chain: several stations share their company, each station keeps its own party (its name and address)
ALTER TABLE ptn.partner DROP CONSTRAINT IF EXISTS partner_company_id_key;
CREATE INDEX IF NOT EXISTS partner_company_id_fkx ON ptn.partner (company_id);
ALTER TABLE ptn.partner ADD COLUMN IF NOT EXISTS pumps smallint CHECK (pumps IS NULL OR pumps BETWEEN 1 AND 99);
COMMENT ON COLUMN ptn.partner.company_id IS 'The company whose portal runs the partner; for a fuel station its fuel company, which may own several stations (1180)';
COMMENT ON COLUMN ptn.partner.pumps IS 'How many pumps the station has, to name the pump of a fill (1180)';

CREATE OR REPLACE FUNCTION ptn.tg_fuel_partner_company() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.partner_type = 'FUEL' AND NEW.company_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM iam.company c WHERE c.id = NEW.company_id AND c.company_type IN ('FUEL_COMPANY', 'PARTNER')) THEN
    RAISE EXCEPTION 'FUEL_COMPANY_REQUIRED: a fuel station belongs to a fuel company' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS fuel_partner_company ON ptn.partner;
CREATE TRIGGER fuel_partner_company BEFORE INSERT OR UPDATE OF company_id, partner_type ON ptn.partner
  FOR EACH ROW EXECUTE FUNCTION ptn.tg_fuel_partner_company();

-- ------------------------------------------------------------------ 3. fuel accounts: money paid in advance to the fuel company
CREATE TABLE IF NOT EXISTS ptn.fuel_account (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  fuel_company_id    bigint NOT NULL REFERENCES iam.company(id),
  holder_company_id  bigint NOT NULL REFERENCES iam.company(id),
  currency           char(3) NOT NULL REFERENCES ref.currency(code),
  balance            bigint NOT NULL DEFAULT 0 CHECK (balance >= 0),
  low_balance        bigint CHECK (low_balance IS NULL OR low_balance > 0),
  status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'CLOSED')),
  created_by         bigint REFERENCES iam.app_user(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (fuel_company_id, holder_company_id, currency),
  CHECK (fuel_company_id <> holder_company_id)
);
CREATE INDEX IF NOT EXISTS fuel_account_holder_company_id_fkx ON ptn.fuel_account (holder_company_id);
CREATE INDEX IF NOT EXISTS fuel_account_currency_fkx ON ptn.fuel_account (currency);
CREATE INDEX IF NOT EXISTS fuel_account_created_by_fkx ON ptn.fuel_account (created_by);
COMMENT ON TABLE ptn.fuel_account IS 'What a carrier, taxi owner or rental company paid in advance to a fuel company, less its fills; the money is the fuel company''s, the platform keeps the account (1180)';
COMMENT ON COLUMN ptn.fuel_account.balance IS 'Kept by the entries (ptn.fuel_account_entry) only, never set directly';
COMMENT ON COLUMN ptn.fuel_account.low_balance IS 'Below this balance the holder is told with each fill';

CREATE TABLE IF NOT EXISTS ptn.fuel_account_entry (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id     bigint NOT NULL REFERENCES ptn.fuel_account(id),
  kind           text NOT NULL CHECK (kind IN ('TOPUP', 'FILL', 'REVERSAL', 'ADJUSTMENT')),
  amount         bigint NOT NULL CHECK (amount <> 0),
  balance_after  bigint NOT NULL CHECK (balance_after >= 0),
  sale_id        bigint REFERENCES ptn.partner_sale(id),
  reference      text CHECK (reference IS NULL OR length(btrim(reference)) BETWEEN 1 AND 80),
  note           text CHECK (note IS NULL OR length(btrim(note)) BETWEEN 3 AND 300),
  recorded_by    bigint REFERENCES iam.app_user(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fuel_account_entry_kind_ck CHECK (
       (kind = 'TOPUP' AND amount > 0 AND sale_id IS NULL)
    OR (kind = 'FILL' AND amount < 0 AND sale_id IS NOT NULL)
    OR (kind = 'REVERSAL' AND amount > 0 AND sale_id IS NOT NULL AND note IS NOT NULL)
    OR (kind = 'ADJUSTMENT' AND sale_id IS NULL AND note IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS fuel_account_entry_account_ix ON ptn.fuel_account_entry (account_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS fuel_account_entry_sale_ux ON ptn.fuel_account_entry (sale_id, kind) WHERE sale_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS fuel_account_entry_recorded_by_fkx ON ptn.fuel_account_entry (recorded_by);
COMMENT ON TABLE ptn.fuel_account_entry IS 'Each movement of a fuel account: a sum the fuel company received, a fill, a fill given back, an adjustment with its reason; never changed (1180)';

-- an entry moves the balance at once, under the account's lock; the balance never goes below zero
CREATE OR REPLACE FUNCTION ptn.tg_fuel_account_entry() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_balance bigint;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'FUEL_ENTRY_KEPT: an account''s entries are never changed or deleted' USING ERRCODE = 'P0001';
  END IF;
  SELECT balance INTO v_balance FROM ptn.fuel_account WHERE id = NEW.account_id AND status = 'ACTIVE' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_ACCOUNT_CLOSED: the fuel account is closed' USING ERRCODE = 'P0001';
  END IF;
  IF v_balance + NEW.amount < 0 THEN
    RAISE EXCEPTION 'FUEL_BALANCE: the account holds % and cannot pay %', v_balance, -NEW.amount USING ERRCODE = 'P0001';
  END IF;
  NEW.balance_after := v_balance + NEW.amount;
  UPDATE ptn.fuel_account SET balance = NEW.balance_after WHERE id = NEW.account_id;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS fuel_account_entry_move ON ptn.fuel_account_entry;
CREATE TRIGGER fuel_account_entry_move BEFORE INSERT OR UPDATE OR DELETE ON ptn.fuel_account_entry
  FOR EACH ROW EXECUTE FUNCTION ptn.tg_fuel_account_entry();

-- the balance moves with the entries only
CREATE OR REPLACE FUNCTION ptn.tg_fuel_account_balance() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.balance IS DISTINCT FROM OLD.balance AND pg_trigger_depth() < 2 THEN
    RAISE EXCEPTION 'FUEL_BALANCE_BY_ENTRY: a fuel account''s balance moves by its entries only' USING ERRCODE = 'P0001';
  END IF;
  IF (NEW.fuel_company_id, NEW.holder_company_id, NEW.currency) IS DISTINCT FROM (OLD.fuel_company_id, OLD.holder_company_id, OLD.currency) THEN
    RAISE EXCEPTION 'FUEL_ACCOUNT_FIXED: an account''s fuel company, holder and currency never change' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS fuel_account_balance ON ptn.fuel_account;
CREATE TRIGGER fuel_account_balance BEFORE UPDATE ON ptn.fuel_account FOR EACH ROW EXECUTE FUNCTION ptn.tg_fuel_account_balance();

-- ------------------------------------------------------------------ 4. a vehicle's card: its account, budget and NFC tag
ALTER TABLE ptn.fuel_card ADD COLUMN IF NOT EXISTS account_id bigint REFERENCES ptn.fuel_account(id);
ALTER TABLE ptn.fuel_card ADD COLUMN IF NOT EXISTS card_no text;
ALTER TABLE ptn.fuel_card ADD COLUMN IF NOT EXISTS budget_period text;
ALTER TABLE ptn.fuel_card ADD COLUMN IF NOT EXISTS budget_amount bigint;
ALTER TABLE ptn.fuel_card ADD COLUMN IF NOT EXISTS budget_litres numeric(8,2);
ALTER TABLE ptn.fuel_card ADD COLUMN IF NOT EXISTS blocked_reason text;
ALTER TABLE ptn.fuel_card ADD COLUMN IF NOT EXISTS blocked_at timestamptz;
UPDATE ptn.fuel_card SET card_no = upper(substr(replace(uid::text, '-', ''), 1, 10)) WHERE card_no IS NULL;
ALTER TABLE ptn.fuel_card ALTER COLUMN card_no SET DEFAULT upper(substr(md5(gen_random_uuid()::text), 1, 10));
ALTER TABLE ptn.fuel_card ALTER COLUMN card_no SET NOT NULL;
ALTER TABLE ptn.fuel_card DROP CONSTRAINT IF EXISTS fuel_card_budget_ck;
ALTER TABLE ptn.fuel_card ADD CONSTRAINT fuel_card_budget_ck CHECK (
      card_no ~ '^[A-Z0-9]{8,12}$'
  AND (budget_period IS NULL OR budget_period IN ('DAY', 'WEEK', 'MONTH'))
  AND (budget_amount IS NULL OR budget_amount > 0) AND (budget_litres IS NULL OR budget_litres > 0)
  AND ((budget_period IS NULL) = (budget_amount IS NULL AND budget_litres IS NULL))
  AND (blocked_reason IS NULL OR length(btrim(blocked_reason)) BETWEEN 3 AND 200));
CREATE UNIQUE INDEX IF NOT EXISTS fuel_card_card_no_ux ON ptn.fuel_card (card_no);
CREATE INDEX IF NOT EXISTS fuel_card_account_id_fkx ON ptn.fuel_card (account_id);
-- one card in use per vehicle; an older second active card is retired
UPDATE ptn.fuel_card c SET status = 'RETIRED'
 WHERE c.status = 'ACTIVE' AND c.vehicle_id IS NOT NULL
   AND EXISTS (SELECT 1 FROM ptn.fuel_card o WHERE o.vehicle_id = c.vehicle_id AND o.status = 'ACTIVE' AND o.id > c.id);
CREATE UNIQUE INDEX IF NOT EXISTS fuel_card_vehicle_active_ux ON ptn.fuel_card (vehicle_id) WHERE status = 'ACTIVE' AND vehicle_id IS NOT NULL;
COMMENT ON COLUMN ptn.fuel_card.account_id IS 'The fuel account the card''s fills are paid from: the card''s company holds it (1180)';
COMMENT ON COLUMN ptn.fuel_card.card_no IS 'The number printed on the card, typed at the pump when neither the tag nor the app works (1180)';
COMMENT ON COLUMN ptn.fuel_card.budget_period IS 'DAY, WEEK or MONTH: the period of the budget, counted in the holder''s time zone (1180)';
COMMENT ON COLUMN ptn.fuel_card.budget_amount IS 'What the vehicle may spend in a period (1180)';
COMMENT ON COLUMN ptn.fuel_card.budget_litres IS 'The litres the vehicle may take in a period (1180)';

CREATE OR REPLACE FUNCTION ptn.tg_fuel_card_account() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.account_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM ptn.fuel_account a WHERE a.id = NEW.account_id AND a.holder_company_id = NEW.company_id) THEN
    RAISE EXCEPTION 'TENANT_MISMATCH: a card is paid from an account its company holds' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'BLOCKED' AND (TG_OP = 'INSERT' OR OLD.status <> 'BLOCKED') THEN
    NEW.blocked_at := now();
  ELSIF NEW.status <> 'BLOCKED' THEN
    NEW.blocked_at := NULL; NEW.blocked_reason := NULL;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS fuel_card_account ON ptn.fuel_card;
CREATE TRIGGER fuel_card_account BEFORE INSERT OR UPDATE ON ptn.fuel_card FOR EACH ROW EXECUTE FUNCTION ptn.tg_fuel_card_account();

-- the NFC tags of the cards: only a hash of the tag's random identifier; bound at the pump, unbound when lost
CREATE TABLE IF NOT EXISTS ptn.fuel_card_tag (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  card_id      bigint NOT NULL REFERENCES ptn.fuel_card(id),
  tag_hash     bytea NOT NULL CHECK (length(tag_hash) = 32),
  partner_id   bigint REFERENCES ptn.partner(id),
  bound_by     bigint REFERENCES iam.app_user(id),
  bound_at     timestamptz NOT NULL DEFAULT now(),
  unbound_at   timestamptz,
  unbound_by   bigint REFERENCES iam.app_user(id)
);
CREATE UNIQUE INDEX IF NOT EXISTS fuel_card_tag_hash_ux ON ptn.fuel_card_tag (tag_hash) WHERE unbound_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS fuel_card_tag_card_ux ON ptn.fuel_card_tag (card_id) WHERE unbound_at IS NULL;
CREATE INDEX IF NOT EXISTS fuel_card_tag_card_id_fkx ON ptn.fuel_card_tag (card_id);
CREATE INDEX IF NOT EXISTS fuel_card_tag_partner_id_fkx ON ptn.fuel_card_tag (partner_id);
CREATE INDEX IF NOT EXISTS fuel_card_tag_bound_by_fkx ON ptn.fuel_card_tag (bound_by);
CREATE INDEX IF NOT EXISTS fuel_card_tag_unbound_by_fkx ON ptn.fuel_card_tag (unbound_by);
COMMENT ON TABLE ptn.fuel_card_tag IS 'The NFC tag of a vehicle''s fuel card, as the hash of the random identifier it holds; one tag per card and one card per tag (1180)';

-- ------------------------------------------------------------------ 5. the fill: meter photo, figures, checks
ALTER TABLE ptn.partner_sale DROP CONSTRAINT IF EXISTS partner_sale_method_check;
ALTER TABLE ptn.partner_sale ADD CONSTRAINT partner_sale_method_check
  CHECK (method IN ('WALLET', 'CARD', 'CREDIT', 'POINTS', 'MIXED', 'PREPAID'));
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS card_id bigint REFERENCES ptn.fuel_card(id);
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS meter_photo_file_id bigint REFERENCES ref.file_object(id);
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS expected_amount bigint;
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS identified_by text;
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS plate_no text;
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS holder_name text;
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS station_name text;
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS pump_ref text;
ALTER TABLE ptn.partner_sale DROP CONSTRAINT IF EXISTS partner_sale_fill_ck;
ALTER TABLE ptn.partner_sale ADD CONSTRAINT partner_sale_fill_ck CHECK (
  method <> 'PREPAID' OR (card_id IS NOT NULL AND qty IS NOT NULL AND unit_price IS NOT NULL AND expected_amount IS NOT NULL
                          AND identified_by IN ('NFC', 'APP', 'CARD_NO')));
CREATE INDEX IF NOT EXISTS partner_sale_card_ix ON ptn.partner_sale (card_id, created_at) WHERE card_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS partner_sale_meter_photo_file_id_fkx ON ptn.partner_sale (meter_photo_file_id);
COMMENT ON COLUMN ptn.partner_sale.meter_photo_file_id IS 'The photo of the pump''s meter taken by the attendant (1180)';
COMMENT ON COLUMN ptn.partner_sale.expected_amount IS 'Litres x the price in force, compared with the amount on the meter (1180)';
COMMENT ON COLUMN ptn.partner_sale.identified_by IS 'How the vehicle was known at the pump: NFC tag, the driver''s app code, or the card''s number (1180)';
COMMENT ON COLUMN ptn.partner_sale.plate_no IS 'The vehicle''s plate at the time of the fill, for the fuel company''s records (1180)';

-- what the pump measured never changes; the sale's status moves only as the checks are decided
CREATE OR REPLACE FUNCTION ptn.tg_partner_sale_fixed() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.method = 'PREPAID' THEN
      RAISE EXCEPTION 'FUEL_SALE_KEPT: a fill is never deleted' USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.method = 'PREPAID'
     AND (NEW.partner_id, NEW.card_id, NEW.vehicle_id, NEW.company_id, NEW.fuel_type, NEW.qty, NEW.unit_price, NEW.amount,
          NEW.expected_amount, NEW.meter_photo_file_id, NEW.odometer_km, NEW.created_at, NEW.method)
         IS DISTINCT FROM
         (OLD.partner_id, OLD.card_id, OLD.vehicle_id, OLD.company_id, OLD.fuel_type, OLD.qty, OLD.unit_price, OLD.amount,
          OLD.expected_amount, OLD.meter_photo_file_id, OLD.odometer_km, OLD.created_at, OLD.method) THEN
    RAISE EXCEPTION 'FUEL_SALE_FIXED: what the pump measured is never changed' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS partner_sale_fixed ON ptn.partner_sale;
CREATE TRIGGER partner_sale_fixed BEFORE UPDATE OR DELETE ON ptn.partner_sale FOR EACH ROW EXECUTE FUNCTION ptn.tg_partner_sale_fixed();

ALTER TABLE ptn.fuel_anomaly DROP CONSTRAINT IF EXISTS fuel_anomaly_anomaly_type_check;
ALTER TABLE ptn.fuel_anomaly ADD CONSTRAINT fuel_anomaly_anomaly_type_check
  CHECK (anomaly_type IN ('OVER_TANK', 'DISTANCE_MISMATCH', 'CONSUMPTION_HIGH', 'ODOMETER_BACKWARD', 'LOCATION_MISMATCH',
                          'AMOUNT_MISMATCH', 'OTHER'));
ALTER TABLE ptn.fuel_anomaly ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE ptn.fuel_anomaly ADD COLUMN IF NOT EXISTS note text CHECK (note IS NULL OR length(btrim(note)) BETWEEN 3 AND 300);
ALTER TABLE ptn.fuel_anomaly ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
CREATE UNIQUE INDEX IF NOT EXISTS fuel_anomaly_uid_ux ON ptn.fuel_anomaly (uid);
CREATE INDEX IF NOT EXISTS fuel_anomaly_session_id_fkx ON ptn.fuel_anomaly (session_id);
COMMENT ON COLUMN ptn.fuel_anomaly.note IS 'Why the anomaly was explained, confirmed or dismissed (1180)';

-- ------------------------------------------------------------------ 6. isolation and privileges
-- an account is seen by its holder and its fuel company; it moves only through the functions below
CREATE OR REPLACE FUNCTION ptn.account_visible(p_account_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM ptn.fuel_account a WHERE a.id = p_account_id
                    AND (sys.tenant_visible(a.holder_company_id) OR sys.tenant_visible(a.fuel_company_id)))
$$;
SELECT sys.rls_split('ptn.fuel_account', 'sys.tenant_visible(holder_company_id) OR sys.tenant_visible(fuel_company_id)', 'sys.ctx_is_platform()');
SELECT sys.rls_split('ptn.fuel_account_entry', 'EXISTS (SELECT 1 FROM ptn.fuel_account p WHERE p.id = fuel_account_entry.account_id)', 'sys.ctx_is_platform()');
SELECT sys.rls_split('ptn.fuel_card_tag', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM ptn.fuel_card c WHERE c.id = card_id)', 'sys.ctx_is_platform()');
GRANT SELECT ON ptn.fuel_account, ptn.fuel_account_entry, ptn.fuel_card_tag TO masslak_app, masslak_readonly;
-- the module switch of the partner schema (1039) closes the new tables too
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ptn.fuel_account', 'ptn.fuel_account_entry', 'ptn.fuel_card_tag'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS module_gate ON %s', t);
    EXECUTE format('CREATE POLICY module_gate ON %s AS RESTRICTIVE FOR ALL USING (sys.ctx_is_platform() OR sys.feature_on(%L)) '
                   || 'WITH CHECK (sys.ctx_is_platform() OR sys.feature_on(%L))', t, '{service_partners}', '{service_partners}');
  END LOOP;
END $$;
DROP TRIGGER IF EXISTS zz_audit_capture ON ptn.fuel_account;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR DELETE OR UPDATE OF status, low_balance ON ptn.fuel_account
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();     -- the balance is recorded by the entries
DROP TRIGGER IF EXISTS zz_audit_capture ON ptn.fuel_card_tag;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON ptn.fuel_card_tag FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- ------------------------------------------------------------------ 7. the functions
-- the station an attendant works at now: an active fuel station of the caller's company where the caller is staff
CREATE OR REPLACE FUNCTION ptn.attendant_station(p_partner_uid uuid) RETURNS ptn.partner
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v ptn.partner%ROWTYPE;
BEGIN
  SELECT p.* INTO v FROM ptn.partner p
   WHERE p.uid = p_partner_uid AND p.partner_type = 'FUEL' AND p.company_id = sys.ctx_company_id()
     AND EXISTS (SELECT 1 FROM ptn.station_employee e WHERE e.partner_id = p.id AND e.user_id = sys.ctx_user_id() AND e.status = 'ACTIVE');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_STATION_STAFF: you are not an attendant of this station' USING ERRCODE = 'P0001';
  END IF;
  IF v.status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'STATION_INACTIVE: the station is not active' USING ERRCODE = 'P0001';
  END IF;
  RETURN v;
END $$;

-- the start of the budget's period now, in the holder's time zone
CREATE OR REPLACE FUNCTION ptn.budget_start(p_period text, p_company bigint) RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN p_period IS NULL THEN NULL
              ELSE date_trunc(lower(p_period), now() AT TIME ZONE coalesce(ref.company_tz(p_company), 'UTC'))
                   AT TIME ZONE coalesce(ref.company_tz(p_company), 'UTC') END
$$;

-- what a card can still take now: the budget left, the balance, the fuel types and the station's prices
CREATE OR REPLACE FUNCTION ptn.card_state(p_card_id bigint, p_partner_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c ptn.fuel_card%ROWTYPE; a ptn.fuel_account%ROWTYPE; p ptn.partner%ROWTYPE; v record;
        v_from timestamptz; v_used_amount bigint := 0; v_used_litres numeric := 0; v_reason text;
BEGIN
  SELECT * INTO c FROM ptn.fuel_card WHERE id = p_card_id;
  SELECT * INTO p FROM ptn.partner WHERE id = p_partner_id;
  SELECT * INTO a FROM ptn.fuel_account WHERE id = c.account_id;
  SELECT vh.plate_no, vh.fuel_type, vh.status, coalesce(fp.tank_capacity_l, vh.fuel_tank_l) AS tank INTO v
    FROM fleet.vehicle vh LEFT JOIN fleet.vehicle_fuel_profile fp ON fp.vehicle_id = vh.id WHERE vh.id = c.vehicle_id;
  v_from := ptn.budget_start(c.budget_period, c.company_id);
  IF v_from IS NOT NULL THEN
    SELECT coalesce(sum(s.amount), 0), coalesce(sum(s.qty), 0) INTO v_used_amount, v_used_litres
      FROM ptn.partner_sale s WHERE s.card_id = c.id AND s.status <> 'REVERSED' AND s.created_at >= v_from;
  END IF;
  v_reason := CASE WHEN c.status <> 'ACTIVE' THEN 'CARD_' || c.status
                   WHEN c.vehicle_id IS NULL THEN 'CARD_NO_VEHICLE'
                   WHEN v.status IS DISTINCT FROM 'ACTIVE' THEN 'VEHICLE_INACTIVE'
                   WHEN a.id IS NULL THEN 'NO_ACCOUNT'
                   WHEN a.fuel_company_id <> p.company_id THEN 'ACCOUNT_OTHER_COMPANY'
                   WHEN a.status <> 'ACTIVE' THEN 'ACCOUNT_CLOSED'
                   WHEN a.balance = 0 THEN 'NO_BALANCE'
                   WHEN c.budget_amount IS NOT NULL AND v_used_amount >= c.budget_amount THEN 'BUDGET_USED'
                   WHEN c.budget_litres IS NOT NULL AND v_used_litres >= c.budget_litres THEN 'BUDGET_USED' END;
  RETURN jsonb_build_object(
    'card_uid', c.uid, 'card_no', c.card_no, 'status', c.status, 'plate_no', v.plate_no, 'vehicle_fuel', v.fuel_type,
    'tank_l', v.tank, 'fuel_types', to_jsonb(c.fuel_types),
    'holder', (SELECT legal_name FROM iam.party WHERE id = c.company_id),
    'currency', a.currency, 'balance', CASE WHEN a.fuel_company_id = p.company_id THEN a.balance END,
    'budget', jsonb_build_object('period', c.budget_period, 'amount', c.budget_amount, 'litres', c.budget_litres,
                                 'used_amount', v_used_amount, 'used_litres', v_used_litres,
                                 'left_amount', CASE WHEN c.budget_amount IS NOT NULL THEN greatest(c.budget_amount - v_used_amount, 0) END,
                                 'left_litres', CASE WHEN c.budget_litres IS NOT NULL THEN greatest(c.budget_litres - v_used_litres, 0) END),
    'prices', coalesce((SELECT jsonb_object_agg(fuel_type, unit_price) FROM (
                          SELECT DISTINCT ON (fuel_type) fuel_type, unit_price FROM ptn.fuel_price
                           WHERE partner_id = p.id AND valid_from <= now() AND currency = a.currency
                           ORDER BY fuel_type, valid_from DESC) pr), '{}'::jsonb),
    'tag_bound', EXISTS (SELECT 1 FROM ptn.fuel_card_tag t WHERE t.card_id = c.id AND t.unbound_at IS NULL),
    'can_fill', v_reason IS NULL, 'reason', v_reason);
END $$;

-- the attendant identifies the vehicle: by the tag's hash, the card's number, or the card the app code named
CREATE OR REPLACE FUNCTION ptn.fuel_identify(p_partner_uid uuid, p_tag_hash bytea, p_card_no text, p_card_uid uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p ptn.partner%ROWTYPE; v_card bigint;
BEGIN
  p := ptn.attendant_station(p_partner_uid);
  IF num_nonnulls(p_tag_hash, p_card_no, p_card_uid) <> 1 THEN
    RAISE EXCEPTION 'FUEL_IDENTIFY_ONE: identify the vehicle one way' USING ERRCODE = 'P0001';
  END IF;
  SELECT c.id INTO v_card FROM ptn.fuel_card c
   WHERE (p_tag_hash IS NOT NULL AND c.id = (SELECT t.card_id FROM ptn.fuel_card_tag t WHERE t.tag_hash = p_tag_hash AND t.unbound_at IS NULL))
      OR (p_card_no IS NOT NULL AND c.card_no = upper(btrim(p_card_no)))
      OR (p_card_uid IS NOT NULL AND c.uid = p_card_uid);
  IF v_card IS NULL THEN
    RAISE EXCEPTION 'FUEL_CARD_UNKNOWN: no fuel card answers to this' USING ERRCODE = 'P0001';
  END IF;
  RETURN ptn.card_state(v_card, p.id);
END $$;

-- a new NFC tag is bound to the card the app code identified; a card keeps one tag, a tag serves one card
CREATE OR REPLACE FUNCTION ptn.fuel_bind_tag(p_partner_uid uuid, p_card_uid uuid, p_tag_hash bytea) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p ptn.partner%ROWTYPE; c ptn.fuel_card%ROWTYPE;
BEGIN
  p := ptn.attendant_station(p_partner_uid);
  SELECT * INTO c FROM ptn.fuel_card WHERE uid = p_card_uid AND status = 'ACTIVE'
     AND account_id IN (SELECT id FROM ptn.fuel_account WHERE fuel_company_id = p.company_id) FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_CARD_UNKNOWN: no active card of an account of this fuel company' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM ptn.fuel_card_tag WHERE tag_hash = p_tag_hash AND unbound_at IS NULL) THEN
    RAISE EXCEPTION 'FUEL_TAG_TAKEN: this tag already serves a card' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM ptn.fuel_card_tag WHERE card_id = c.id AND unbound_at IS NULL) THEN
    RAISE EXCEPTION 'FUEL_CARD_HAS_TAG: the card has a tag; its owner unbinds it first' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO ptn.fuel_card_tag (card_id, tag_hash, partner_id, bound_by) VALUES (c.id, p_tag_hash, p.id, sys.ctx_user_id());
END $$;

-- the card's company unbinds a lost tag (and usually blocks the card)
CREATE OR REPLACE FUNCTION ptn.fuel_unbind_tag(p_card_uid uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n integer;
BEGIN
  UPDATE ptn.fuel_card_tag t SET unbound_at = now(), unbound_by = sys.ctx_user_id()
    FROM ptn.fuel_card c
   WHERE c.id = t.card_id AND c.uid = p_card_uid AND t.unbound_at IS NULL AND sys.tenant_visible(c.company_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- a holder opens an account with a fuel company
CREATE OR REPLACE FUNCTION ptn.fuel_open_account(p_fuel_company_uid uuid, p_currency char(3)) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_fuel bigint; v_uid uuid;
BEGIN
  IF sys.ctx_company_id() IS NULL OR NOT EXISTS (SELECT 1 FROM iam.company WHERE id = sys.ctx_company_id()
                                                    AND company_type IN ('CARRIER', 'INDIVIDUAL_OPERATOR', 'FOREIGN_CARRIER', 'SCHOOL', 'PARTNER')) THEN
    RAISE EXCEPTION 'NOT_A_FLEET: a fuel account is opened by a company with vehicles' USING ERRCODE = 'P0001';
  END IF;
  SELECT c.id INTO v_fuel FROM iam.company c JOIN iam.party p ON p.id = c.id
   WHERE p.uid = p_fuel_company_uid AND c.company_type = 'FUEL_COMPANY' AND c.approval_status = 'APPROVED';
  IF v_fuel IS NULL THEN
    RAISE EXCEPTION 'FUEL_COMPANY_UNKNOWN: no approved fuel company' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO ptn.fuel_account (fuel_company_id, holder_company_id, currency, created_by)
  VALUES (v_fuel, sys.ctx_company_id(), coalesce(p_currency, ref.company_currency(sys.ctx_company_id()), 'SYP'), sys.ctx_user_id())
  ON CONFLICT (fuel_company_id, holder_company_id, currency) DO UPDATE SET status = 'ACTIVE'
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- the holder sets the balance below which it is told with each fill
CREATE OR REPLACE FUNCTION ptn.fuel_set_low_balance(p_account_uid uuid, p_low_balance bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  UPDATE ptn.fuel_account SET low_balance = p_low_balance
   WHERE uid = p_account_uid AND holder_company_id = sys.ctx_company_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_ACCOUNT_UNKNOWN: no account your company holds' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- the fuel company records a sum it received for an account
CREATE OR REPLACE FUNCTION ptn.fuel_topup(p_account_uid uuid, p_amount bigint, p_reference text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE a ptn.fuel_account%ROWTYPE; v_after bigint;
BEGIN
  SELECT * INTO a FROM ptn.fuel_account WHERE uid = p_account_uid AND fuel_company_id = sys.ctx_company_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_ACCOUNT_UNKNOWN: no account held with your company' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'FUEL_AMOUNT: a top-up is a positive amount' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO ptn.fuel_account_entry (account_id, kind, amount, balance_after, reference, recorded_by)
  VALUES (a.id, 'TOPUP', p_amount, 0, nullif(btrim(p_reference), ''), sys.ctx_user_id())
  RETURNING balance_after INTO v_after;
  RETURN v_after;
END $$;

-- the fill at the pump
CREATE OR REPLACE FUNCTION ptn.fuel_fill(p_partner_uid uuid, p_card_uid uuid, p_identified_by text, p_fuel_type text,
                                         p_litres numeric, p_amount bigint, p_photo_file_id bigint, p_odometer_km integer,
                                         p_pump text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p ptn.partner%ROWTYPE; c ptn.fuel_card%ROWTYPE; a ptn.fuel_account%ROWTYPE; st jsonb; cfg jsonb;
        v_price bigint; v_expected bigint; v_tank numeric; v_profile record; v_last record; v_employee bigint;
        v_session bigint; v_sale bigint; v_sale_uid uuid; v_anomalies jsonb := '[]'::jsonb; v_km integer; v_rate numeric;
        v_limit numeric; v_after bigint; e jsonb;
BEGIN
  p := ptn.attendant_station(p_partner_uid);
  cfg := coalesce((SELECT value FROM sys.setting WHERE key = 'fuel.checks'), '{}'::jsonb);
  SELECT * INTO c FROM ptn.fuel_card WHERE uid = p_card_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_CARD_UNKNOWN: no fuel card answers to this' USING ERRCODE = 'P0001';
  END IF;
  st := ptn.card_state(c.id, p.id);
  IF NOT (st ->> 'can_fill')::boolean THEN
    RAISE EXCEPTION 'FUEL_CANNOT_FILL: %', st ->> 'reason' USING ERRCODE = 'P0001';
  END IF;
  IF p_identified_by NOT IN ('NFC', 'APP', 'CARD_NO') THEN
    RAISE EXCEPTION 'FUEL_IDENTIFY_ONE: identify the vehicle one way' USING ERRCODE = 'P0001';
  END IF;
  IF NOT (p_fuel_type = ANY (c.fuel_types)) THEN
    RAISE EXCEPTION 'FUEL_TYPE_NOT_ALLOWED: the card does not take %', p_fuel_type USING ERRCODE = 'P0001';
  END IF;
  v_price := (st -> 'prices' ->> p_fuel_type)::bigint;
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'FUEL_NO_PRICE: the station has no price for %', p_fuel_type USING ERRCODE = 'P0001';
  END IF;
  IF p_litres IS NULL OR p_litres <= 0 OR p_litres > 2000 OR p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'FUEL_FIGURES: enter the litres and the amount shown on the meter' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce((cfg ->> 'photo_required')::boolean, true) AND p_photo_file_id IS NULL THEN
    RAISE EXCEPTION 'FUEL_PHOTO_REQUIRED: photograph the pump''s meter' USING ERRCODE = 'P0001';
  END IF;
  IF p_photo_file_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ref.file_object f WHERE f.id = p_photo_file_id
                                                    AND f.uploaded_by = sys.ctx_user_id()) THEN
    RAISE EXCEPTION 'FUEL_PHOTO_REQUIRED: the meter''s photo is one the attendant took' USING ERRCODE = 'P0001';
  END IF;
  IF (st -> 'budget' ->> 'left_amount') IS NOT NULL AND p_amount > (st -> 'budget' ->> 'left_amount')::bigint THEN
    RAISE EXCEPTION 'FUEL_BUDGET: the budget left is %', st -> 'budget' ->> 'left_amount' USING ERRCODE = 'P0001';
  END IF;
  IF (st -> 'budget' ->> 'left_litres') IS NOT NULL AND p_litres > (st -> 'budget' ->> 'left_litres')::numeric THEN
    RAISE EXCEPTION 'FUEL_BUDGET_LITRES: the litres left are %', st -> 'budget' ->> 'left_litres' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO a FROM ptn.fuel_account WHERE id = c.account_id;
  SELECT id INTO v_employee FROM ptn.station_employee WHERE partner_id = p.id AND user_id = sys.ctx_user_id();

  -- the checks
  v_expected := round(p_litres * v_price);
  IF abs(v_expected - p_amount) > greatest(v_expected * coalesce((cfg ->> 'amount_tolerance_pct')::numeric, 1) / 100, 1) THEN
    v_anomalies := v_anomalies || jsonb_build_object('type', 'AMOUNT_MISMATCH', 'severity', 'HIGH',
                                                     'evidence', jsonb_build_object('expected', v_expected, 'meter', p_amount, 'price', v_price));
  END IF;
  v_tank := (st ->> 'tank_l')::numeric;
  IF v_tank IS NOT NULL AND p_litres > v_tank * (1 + coalesce((cfg ->> 'tank_margin_pct')::numeric, 5) / 100) THEN
    v_anomalies := v_anomalies || jsonb_build_object('type', 'OVER_TANK', 'severity', 'HIGH',
                                                     'evidence', jsonb_build_object('tank_l', v_tank, 'litres', p_litres));
  END IF;
  SELECT r.value_km, r.ts INTO v_last FROM ptn.odometer_reading r WHERE r.vehicle_id = c.vehicle_id ORDER BY r.ts DESC, r.id DESC LIMIT 1;
  IF p_odometer_km IS NOT NULL AND v_last.value_km IS NOT NULL THEN
    v_km := p_odometer_km - v_last.value_km;
    IF v_km < 0 THEN
      v_anomalies := v_anomalies || jsonb_build_object('type', 'ODOMETER_BACKWARD', 'severity', 'HIGH',
                                                       'evidence', jsonb_build_object('last_km', v_last.value_km, 'now_km', p_odometer_km));
    ELSE
      SELECT fp.expected_l_per_100km, fp.tolerance_pct INTO v_profile FROM fleet.vehicle_fuel_profile fp WHERE fp.vehicle_id = c.vehicle_id;
      v_limit := coalesce(v_profile.expected_l_per_100km, (cfg ->> 'default_l_per_100km')::numeric, 40)
                 * (1 + coalesce(v_profile.tolerance_pct, (cfg ->> 'consumption_margin_pct')::numeric, 25) / 100);
      IF v_km = 0 THEN
        v_anomalies := v_anomalies || jsonb_build_object('type', 'DISTANCE_MISMATCH', 'severity', 'MEDIUM',
                                                         'evidence', jsonb_build_object('km', 0, 'litres', p_litres));
      ELSE
        v_rate := round(p_litres * 100 / v_km, 1);
        IF v_rate > v_limit THEN
          v_anomalies := v_anomalies || jsonb_build_object('type', 'CONSUMPTION_HIGH', 'severity', 'MEDIUM',
                                                           'evidence', jsonb_build_object('km', v_km, 'l_per_100km', v_rate, 'limit', round(v_limit, 1)));
        END IF;
      END IF;
    END IF;
  END IF;

  INSERT INTO ptn.fuel_session (partner_id, pump_ref, station_employee_id, company_id, vehicle_id, fuel_card_id, closed_at, status)
  VALUES (p.id, nullif(btrim(p_pump), ''), v_employee, c.company_id, c.vehicle_id, c.id, now(),
          CASE WHEN jsonb_array_length(v_anomalies) > 0 THEN 'FLAGGED' ELSE 'COMPLETED' END)
  RETURNING id INTO v_session;
  IF p_odometer_km IS NOT NULL THEN
    INSERT INTO ptn.odometer_reading (vehicle_id, session_id, value_km, source, employee_confirmed)
    VALUES (c.vehicle_id, v_session, p_odometer_km, 'MANUAL', true);
  END IF;
  INSERT INTO ptn.partner_sale (partner_id, session_id, company_id, vehicle_id, driver_party_id, fuel_type, qty, unit_price, amount,
                                currency, method, odometer_km, status, card_id, meter_photo_file_id, expected_amount, identified_by,
                                plate_no, holder_name, station_name, pump_ref)
  VALUES (p.id, v_session, c.company_id, c.vehicle_id, c.driver_party_id, p_fuel_type, p_litres, v_price, p_amount,
          a.currency, 'PREPAID', p_odometer_km, CASE WHEN jsonb_array_length(v_anomalies) > 0 THEN 'PENDING' ELSE 'COMPLETED' END,
          c.id, p_photo_file_id, v_expected, p_identified_by, st ->> 'plate_no', st ->> 'holder',
          (SELECT legal_name FROM iam.party WHERE id = p.party_id), nullif(btrim(p_pump), ''))
  RETURNING id, uid INTO v_sale, v_sale_uid;
  INSERT INTO ptn.fuel_account_entry (account_id, kind, amount, balance_after, sale_id, recorded_by)
  VALUES (a.id, 'FILL', -p_amount, 0, v_sale, sys.ctx_user_id())
  RETURNING balance_after INTO v_after;
  FOR e IN SELECT * FROM jsonb_array_elements(v_anomalies) LOOP
    INSERT INTO ptn.fuel_anomaly (session_id, anomaly_type, severity, liters, evidence)
    VALUES (v_session, e ->> 'type', e ->> 'severity', p_litres, e -> 'evidence');
  END LOOP;
  RETURN jsonb_build_object('sale_uid', v_sale_uid, 'sale_id', v_sale, 'status', CASE WHEN jsonb_array_length(v_anomalies) > 0 THEN 'HELD' ELSE 'COMPLETED' END,
                            'anomalies', v_anomalies, 'balance', v_after, 'low_balance', a.low_balance IS NOT NULL AND v_after < a.low_balance,
                            'currency', a.currency, 'plate_no', st ->> 'plate_no', 'holder_company_id', c.company_id,
                            'station', (SELECT legal_name FROM iam.party WHERE id = p.party_id), 'expected_amount', v_expected,
                            'left_amount', CASE WHEN (st -> 'budget' ->> 'left_amount') IS NOT NULL
                                                THEN (st -> 'budget' ->> 'left_amount')::bigint - p_amount END);
END $$;

-- an anomaly decided by the vehicle's owner, the fuel company or the platform; the sale follows its anomalies
CREATE OR REPLACE FUNCTION ptn.decide_fuel_anomaly(p_anomaly_uid uuid, p_outcome text, p_note text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE an ptn.fuel_anomaly%ROWTYPE; s ptn.fuel_session%ROWTYPE; v_status text;
BEGIN
  SELECT * INTO an FROM ptn.fuel_anomaly WHERE uid = p_anomaly_uid FOR UPDATE;
  SELECT * INTO s FROM ptn.fuel_session WHERE id = an.session_id;
  IF an.id IS NULL OR NOT (sys.ctx_is_platform() OR sys.tenant_visible(s.company_id)
                           OR EXISTS (SELECT 1 FROM ptn.partner p WHERE p.id = s.partner_id AND p.company_id = sys.ctx_company_id())) THEN
    RAISE EXCEPTION 'FUEL_ANOMALY_UNKNOWN: no such anomaly for you' USING ERRCODE = 'P0001';
  END IF;
  IF an.status <> 'OPEN' THEN
    RAISE EXCEPTION 'FUEL_ANOMALY_DECIDED: the anomaly was already decided' USING ERRCODE = 'P0001';
  END IF;
  IF p_outcome NOT IN ('EXPLAINED', 'CONFIRMED', 'DISMISSED') OR p_note IS NULL OR length(btrim(p_note)) < 3 THEN
    RAISE EXCEPTION 'FUEL_ANOMALY_NOTE: decide EXPLAINED, CONFIRMED or DISMISSED, with a note' USING ERRCODE = 'P0001';
  END IF;
  UPDATE ptn.fuel_anomaly SET status = p_outcome, note = btrim(p_note), resolved_by = sys.ctx_user_id(), resolved_at = now()
   WHERE id = an.id;
  IF NOT EXISTS (SELECT 1 FROM ptn.fuel_anomaly WHERE session_id = s.id AND status = 'OPEN') THEN
    v_status := CASE WHEN EXISTS (SELECT 1 FROM ptn.fuel_anomaly WHERE session_id = s.id AND status = 'CONFIRMED') THEN 'DISPUTED' ELSE 'COMPLETED' END;
    UPDATE ptn.partner_sale SET status = v_status WHERE session_id = s.id AND status = 'PENDING';
    UPDATE ptn.fuel_session SET status = CASE WHEN v_status = 'COMPLETED' THEN 'COMPLETED' ELSE 'FLAGGED' END WHERE id = s.id;
  END IF;
  RETURN coalesce(v_status, 'PENDING');
END $$;

-- the fuel company gives a fill back to the account (a wrong fill, a disputed one settled in the holder's favour)
CREATE OR REPLACE FUNCTION ptn.fuel_reverse_sale(p_sale_uid uuid, p_reason text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s ptn.partner_sale%ROWTYPE; v_account bigint; v_after bigint;
BEGIN
  SELECT * INTO s FROM ptn.partner_sale WHERE uid = p_sale_uid AND method = 'PREPAID' FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM ptn.partner p WHERE p.id = s.partner_id AND p.company_id = sys.ctx_company_id()) THEN
    RAISE EXCEPTION 'FUEL_SALE_UNKNOWN: no fill of your stations' USING ERRCODE = 'P0001';
  END IF;
  IF s.status = 'REVERSED' THEN
    RAISE EXCEPTION 'FUEL_SALE_REVERSED: the fill was already given back' USING ERRCODE = 'P0001';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'FUEL_REASON: a fill is given back with its reason' USING ERRCODE = 'P0001';
  END IF;
  SELECT account_id INTO v_account FROM ptn.fuel_account_entry WHERE sale_id = s.id AND kind = 'FILL';
  INSERT INTO ptn.fuel_account_entry (account_id, kind, amount, balance_after, sale_id, note, recorded_by)
  VALUES (v_account, 'REVERSAL', s.amount, 0, s.id, btrim(p_reason), sys.ctx_user_id())
  RETURNING balance_after INTO v_after;
  UPDATE ptn.partner_sale SET status = 'REVERSED' WHERE id = s.id;
  RETURN v_after;
END $$;

-- what a fuel company's portal shows: its stations, the accounts held with it and the holders' names
CREATE OR REPLACE FUNCTION ptn.fuel_company_view(p_company_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF p_company_id IS DISTINCT FROM sys.ctx_company_id() AND NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'NOT_FUEL_COMPANY: only the fuel company sees its portal' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object(
    'stations', coalesce((SELECT jsonb_agg(jsonb_build_object(
                   'uid', p.uid, 'code', p.code, 'name', pa.legal_name, 'status', p.status, 'pumps', p.pumps,
                   'station', (SELECT s.name FROM net.station s WHERE s.id = p.station_id),
                   'prices', coalesce((SELECT jsonb_object_agg(fuel_type, jsonb_build_object('price', unit_price, 'currency', currency, 'from', valid_from))
                                         FROM (SELECT DISTINCT ON (fuel_type) fuel_type, unit_price, currency, valid_from FROM ptn.fuel_price
                                                WHERE partner_id = p.id AND valid_from <= now() ORDER BY fuel_type, valid_from DESC) x), '{}'::jsonb),
                   'attendants', (SELECT count(*) FROM ptn.station_employee e WHERE e.partner_id = p.id AND e.status = 'ACTIVE'),
                   'today', (SELECT jsonb_build_object('fills', count(*), 'litres', coalesce(sum(qty), 0), 'amount', coalesce(sum(amount), 0))
                               FROM ptn.partner_sale s WHERE s.partner_id = p.id AND s.status <> 'REVERSED'
                                AND s.created_at >= date_trunc('day', now() AT TIME ZONE coalesce(ref.company_tz(p_company_id), 'UTC'))
                                                    AT TIME ZONE coalesce(ref.company_tz(p_company_id), 'UTC')))
                 ORDER BY p.code) FROM ptn.partner p JOIN iam.party pa ON pa.id = p.party_id
                 WHERE p.company_id = p_company_id AND p.partner_type = 'FUEL'), '[]'::jsonb),
    'accounts', coalesce((SELECT jsonb_agg(jsonb_build_object(
                   'uid', a.uid, 'holder', h.legal_name, 'holder_uid', h.uid, 'currency', a.currency, 'balance', a.balance,
                   'status', a.status, 'cards', (SELECT count(*) FROM ptn.fuel_card c WHERE c.account_id = a.id AND c.status = 'ACTIVE'),
                   'last_topup', (SELECT max(created_at) FROM ptn.fuel_account_entry e WHERE e.account_id = a.id AND e.kind = 'TOPUP'))
                 ORDER BY h.legal_name) FROM ptn.fuel_account a JOIN iam.party h ON h.id = a.holder_company_id
                 WHERE a.fuel_company_id = p_company_id), '[]'::jsonb),
    'open_anomalies', (SELECT count(*) FROM ptn.fuel_anomaly an JOIN ptn.fuel_session s ON s.id = an.session_id
                        JOIN ptn.partner p ON p.id = s.partner_id WHERE p.company_id = p_company_id AND an.status = 'OPEN'));
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['ptn.tg_fuel_partner_company()', 'ptn.tg_fuel_account_entry()', 'ptn.tg_fuel_card_account()',
                           'ptn.account_visible(bigint)', 'ptn.attendant_station(uuid)', 'ptn.budget_start(text,bigint)',
                           'ptn.card_state(bigint,bigint)', 'ptn.fuel_identify(uuid,bytea,text,uuid)', 'ptn.fuel_bind_tag(uuid,uuid,bytea)',
                           'ptn.fuel_unbind_tag(uuid)', 'ptn.fuel_open_account(uuid,character)', 'ptn.fuel_topup(uuid,bigint,text)',
                           'ptn.fuel_set_low_balance(uuid,bigint)',
                           'ptn.fuel_fill(uuid,uuid,text,text,numeric,bigint,bigint,integer,text)', 'ptn.decide_fuel_anomaly(uuid,text,text)',
                           'ptn.fuel_reverse_sale(uuid,text)', 'ptn.fuel_company_view(bigint)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
  END LOOP;
  -- the application calls these; the others are their helpers (account_visible serves the read policy)
  FOREACH f IN ARRAY ARRAY['ptn.account_visible(bigint)', 'ptn.fuel_identify(uuid,bytea,text,uuid)', 'ptn.fuel_bind_tag(uuid,uuid,bytea)',
                           'ptn.fuel_unbind_tag(uuid)', 'ptn.fuel_open_account(uuid,character)', 'ptn.fuel_topup(uuid,bigint,text)',
                           'ptn.fuel_set_low_balance(uuid,bigint)',
                           'ptn.fuel_fill(uuid,uuid,text,text,numeric,bigint,bigint,integer,text)', 'ptn.decide_fuel_anomaly(uuid,text,text)',
                           'ptn.fuel_reverse_sale(uuid,text)', 'ptn.fuel_company_view(bigint)'] LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO masslak_app', f);
  END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION ptn.account_visible(bigint) TO masslak_readonly;
COMMENT ON FUNCTION ptn.account_visible IS 'The fuel account is seen by the caller: its holder or its fuel company (1180)';
COMMENT ON FUNCTION ptn.attendant_station IS 'The active fuel station of the caller''s company where the caller is an active attendant (1180)';
COMMENT ON FUNCTION ptn.budget_start IS 'The start of the current day, week or month in the holder''s time zone (1180)';
COMMENT ON FUNCTION ptn.card_state IS 'What a fuel card may still take at a station: budget left, balance, fuel types, prices, and why not (1180)';
COMMENT ON FUNCTION ptn.fuel_identify IS 'The attendant identifies a vehicle by the hash of its NFC tag, its card number or the card its app code named (1180)';
COMMENT ON FUNCTION ptn.fuel_bind_tag IS 'An attendant binds a new NFC tag to a card identified by the driver''s app code (1180)';
COMMENT ON FUNCTION ptn.fuel_unbind_tag IS 'The card''s company unbinds a lost or broken tag (1180)';
COMMENT ON FUNCTION ptn.fuel_open_account IS 'A company with vehicles opens a fuel account with a fuel company (1180)';
COMMENT ON FUNCTION ptn.fuel_set_low_balance IS 'The holder sets the balance below which each fill''s notice warns it (1180)';
COMMENT ON FUNCTION ptn.fuel_topup IS 'The fuel company records a sum it received for an account held with it (1180)';
COMMENT ON FUNCTION ptn.fuel_fill IS 'A fill at the pump: checked against the budget, balance, price, tank and odometer, paid from the account, held when a check fails (1180)';
COMMENT ON FUNCTION ptn.decide_fuel_anomaly IS 'The vehicle''s owner, the fuel company or the platform decides an anomaly; the held sale completes or becomes disputed (1180)';
COMMENT ON FUNCTION ptn.fuel_reverse_sale IS 'The fuel company gives a fill back to the account, with its reason (1180)';
COMMENT ON FUNCTION ptn.fuel_company_view IS 'A fuel company''s stations with prices and the day''s fills, the accounts held with it, open anomalies (1180)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ptn.fuel_account', '9', 'E27'), ('ptn.fuel_account_entry', '9', 'E27'), ('ptn.fuel_card_tag', '9', 'E27')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('ptn.fuel_account', 'TENANT_PRIVATE', 'holder_company_id or fuel_company_id',
   'what a company with vehicles paid in advance to a fuel company, and its balance (1180)'),
  ('ptn.fuel_account_entry', 'TENANT_PRIVATE', 'via ptn.account_visible(account_id)',
   'the movements of fuel accounts: top-ups, fills, reversals, adjustments (1180)'),
  ('ptn.fuel_card_tag', 'TENANT_PRIVATE', 'parent ptn.fuel_card',
   'hashes of the NFC tags of vehicles'' fuel cards (1180)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ptn.fuel_account', 'ptn records', 'fuel accounts held with fuel companies (1180)'),
  ('ptn.fuel_account_entry', 'ptn records', 'movements of fuel accounts (1180)'),
  ('ptn.fuel_card_tag', 'ptn records', 'NFC tags of fuel cards (1180)')
ON CONFLICT (table_name) DO NOTHING;
SELECT sys.refresh_table_class();

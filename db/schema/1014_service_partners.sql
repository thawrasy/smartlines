-- =====================================================================
-- 1014: service partners (study 14.11): contracted fuel stations, rest stops and maintenance shops.
--   Partner profile on the station pattern (4.11), versioned contracts with dual approval, attendants, posted
--   fuel prices, virtual fuel cards, fuel sessions with odometer readings and anomaly checks, the shared sale
--   transaction, rest-stop menus, pre-orders and ratings, and periodic settlement through the ledger.
-- =====================================================================

CREATE TABLE IF NOT EXISTS ptn.partner (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  party_id          bigint NOT NULL UNIQUE REFERENCES iam.party(id),
  company_id        bigint UNIQUE REFERENCES iam.company(id),          -- the partner's portal tenant (company_type PARTNER)
  partner_type      text NOT NULL CHECK (partner_type IN ('FUEL','REST_STOP','MAINTENANCE','RETAIL','OTHER')),
  code              text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9-]{3,30}$'),
  station_id        bigint REFERENCES net.station(id),
  lat               numeric(9,6),
  lng               numeric(9,6),
  geofence_m        int NOT NULL DEFAULT 150 CHECK (geofence_m BETWEEN 20 AND 2000),
  license_no        text,
  license_expiry    date,
  hours             jsonb NOT NULL DEFAULT '{}',
  menu_enabled      boolean NOT NULL DEFAULT false,
  preorder_enabled  boolean NOT NULL DEFAULT false,
  avg_service_min   smallint CHECK (avg_service_min > 0),
  compliance_state  text NOT NULL DEFAULT 'PENDING' CHECK (compliance_state IN ('PENDING','COMPLIANT','GRACE','SUSPENDED')),
  status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','ENDED')),
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ptn.partner IS 'A contracted service partner, registered on the station pattern (14.11, 4.11)';

CREATE TABLE IF NOT EXISTS ptn.partner_contract (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id         bigint NOT NULL REFERENCES ptn.partner(id),
  version            int NOT NULL DEFAULT 1,
  commission_model   text NOT NULL CHECK (commission_model IN ('PERCENT','FIXED','TIERED')),
  rate_bp            int CHECK (rate_bp BETWEEN 0 AND 10000),          -- basis points for PERCENT
  fixed_fee          bigint CHECK (fixed_fee >= 0),
  tiers              jsonb,                                            -- TIERED: [{from_amount, rate_bp}]
  carrier_fee        bigint NOT NULL DEFAULT 0 CHECK (carrier_fee >= 0),
  carrier_share_pct  numeric(5,2) NOT NULL DEFAULT 0 CHECK (carrier_share_pct BETWEEN 0 AND 100),
  currency           char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  settlement_cycle   text NOT NULL DEFAULT 'WEEKLY' CHECK (settlement_cycle IN ('DAILY','WEEKLY','MONTHLY')),
  credit_terms       jsonb NOT NULL DEFAULT '{}',
  valid              daterange NOT NULL,
  status             text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PENDING_APPROVAL','ACTIVE','ENDED')),
  created_by         bigint REFERENCES iam.app_user(id),
  approved_by        bigint REFERENCES iam.app_user(id),
  UNIQUE (partner_id, version),
  CHECK (approved_by IS NULL OR approved_by <> created_by),
  EXCLUDE USING gist (partner_id WITH =, valid WITH &&) WHERE (status = 'ACTIVE')
);
COMMENT ON TABLE ptn.partner_contract IS 'Versioned commission contract with dual approval; one active contract per period';

CREATE TABLE IF NOT EXISTS ptn.station_employee (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id  bigint NOT NULL REFERENCES ptn.partner(id),
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  role        text NOT NULL CHECK (role IN ('ATTENDANT','CASHIER','MANAGER')),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
  UNIQUE (partner_id, user_id)
);
COMMENT ON TABLE ptn.station_employee IS 'A personal account per attendant, so every fuel session has a named employee';

CREATE TABLE IF NOT EXISTS ptn.fuel_price (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id  bigint NOT NULL REFERENCES ptn.partner(id),
  fuel_type   text NOT NULL CHECK (fuel_type IN ('DIESEL','GASOLINE','LPG','CNG','ADBLUE')),
  unit_price  bigint NOT NULL CHECK (unit_price > 0),
  currency    char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  valid_from  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (partner_id, fuel_type, valid_from)
);

CREATE TABLE IF NOT EXISTS ptn.fuel_card (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id      bigint NOT NULL REFERENCES iam.company(id),
  vehicle_id      bigint REFERENCES fleet.vehicle(id),
  driver_party_id bigint REFERENCES fleet.crew_profile(party_id),
  daily_limit     bigint CHECK (daily_limit > 0),
  monthly_limit   bigint CHECK (monthly_limit > 0),
  currency        char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  fuel_types      text[] NOT NULL DEFAULT '{DIESEL}',
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','BLOCKED','RETIRED')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (vehicle_id IS NOT NULL OR driver_party_id IS NOT NULL)
);
COMMENT ON TABLE ptn.fuel_card IS 'Virtual fuel card of a carrier, bound to a vehicle or a driver, with limits';

CREATE TABLE IF NOT EXISTS ptn.fuel_session (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id           bigint NOT NULL REFERENCES ptn.partner(id),
  pump_ref             text,
  station_employee_id  bigint NOT NULL REFERENCES ptn.station_employee(id),
  company_id           bigint NOT NULL REFERENCES iam.company(id),
  vehicle_id           bigint NOT NULL REFERENCES fleet.vehicle(id),
  driver_party_id      bigint REFERENCES fleet.crew_profile(party_id),
  trip_id              bigint REFERENCES ops.trip(id),
  fuel_card_id         bigint REFERENCES ptn.fuel_card(id),
  opened_at            timestamptz NOT NULL DEFAULT now(),
  closed_at            timestamptz,
  status               text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','COMPLETED','CANCELLED','FLAGGED'))
);
COMMENT ON TABLE ptn.fuel_session IS 'Refuelling session that precedes the sale and carries the odometer evidence (14.11 f)';

CREATE TABLE IF NOT EXISTS ptn.odometer_reading (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id          bigint NOT NULL REFERENCES fleet.vehicle(id),
  session_id          bigint REFERENCES ptn.fuel_session(id),
  value_km            int NOT NULL CHECK (value_km >= 0),
  photo_file_id       bigint REFERENCES ref.file_object(id),
  ocr_value           int,
  driver_confirmed    boolean NOT NULL DEFAULT false,
  employee_confirmed  boolean NOT NULL DEFAULT false,
  source              text NOT NULL CHECK (source IN ('PHOTO','OBD','MANUAL')),
  lat                 numeric(9,6),
  lng                 numeric(9,6),
  ts                  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS odometer_vehicle_idx ON ptn.odometer_reading (vehicle_id, ts);
COMMENT ON TABLE ptn.odometer_reading IS 'Series of odometer readings per vehicle; append-only';

CREATE TABLE IF NOT EXISTS ptn.partner_menu_item (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id  bigint NOT NULL REFERENCES ptn.partner(id),
  name        text NOT NULL,
  category    text NOT NULL DEFAULT 'FOOD' CHECK (category IN ('FOOD','DRINK','SNACK','OTHER')),
  price       bigint NOT NULL CHECK (price >= 0),
  currency    char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  available   boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS ptn.partner_order (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid         uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  partner_id  bigint NOT NULL REFERENCES ptn.partner(id),
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  trip_id     bigint REFERENCES ops.trip(id),
  amount      bigint NOT NULL CHECK (amount >= 0),
  currency    char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  pickup_eta  timestamptz,
  status      text NOT NULL DEFAULT 'PLACED' CHECK (status IN ('PLACED','ACCEPTED','READY','PICKED_UP','CANCELLED')),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS ptn.partner_order_item (
  order_id      bigint NOT NULL REFERENCES ptn.partner_order(id) ON DELETE CASCADE,
  menu_item_id  bigint NOT NULL REFERENCES ptn.partner_menu_item(id),
  qty           smallint NOT NULL CHECK (qty > 0),
  unit_price    bigint NOT NULL CHECK (unit_price >= 0),
  PRIMARY KEY (order_id, menu_item_id)
);
COMMENT ON TABLE ptn.partner_order IS 'Pre-order at a rest stop on the trip (14.11 e); its lines are ptn.partner_order_item';

CREATE TABLE IF NOT EXISTS ptn.partner_sale (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid              uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  partner_id       bigint NOT NULL REFERENCES ptn.partner(id),
  session_id       bigint UNIQUE REFERENCES ptn.fuel_session(id),
  order_id         bigint UNIQUE REFERENCES ptn.partner_order(id),
  company_id       bigint REFERENCES iam.company(id),                  -- carrier paying (fuel)
  user_id          bigint REFERENCES iam.app_user(id),                 -- passenger paying (rest stop)
  vehicle_id       bigint REFERENCES fleet.vehicle(id),
  driver_party_id  bigint REFERENCES iam.party(id),
  trip_id          bigint REFERENCES ops.trip(id),
  fuel_type        text,
  qty              numeric(10,2) CHECK (qty > 0),
  unit_price       bigint CHECK (unit_price >= 0),
  amount           bigint NOT NULL CHECK (amount >= 0),
  points_used      bigint NOT NULL DEFAULT 0 CHECK (points_used >= 0),
  currency         char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  method           text NOT NULL CHECK (method IN ('WALLET','CARD','CREDIT','POINTS','MIXED')),
  odometer_km      int,
  lat              numeric(9,6),
  lng              numeric(9,6),
  status           text NOT NULL DEFAULT 'COMPLETED' CHECK (status IN ('PENDING','COMPLETED','REVERSED','DISPUTED')),
  ledger_txn_id    bigint REFERENCES fin.ledger_txn(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (company_id IS NOT NULL OR user_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS partner_sale_partner_idx ON ptn.partner_sale (partner_id, created_at);
COMMENT ON TABLE ptn.partner_sale IS 'The shared sale transaction for fuel and rest stops, posted through the ledger';

CREATE TABLE IF NOT EXISTS ptn.fuel_anomaly (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  session_id            bigint NOT NULL REFERENCES ptn.fuel_session(id),
  anomaly_type          text NOT NULL CHECK (anomaly_type IN ('OVER_TANK','DISTANCE_MISMATCH','CONSUMPTION_HIGH','ODOMETER_BACKWARD','LOCATION_MISMATCH','OTHER')),
  severity              text NOT NULL CHECK (severity IN ('LOW','MEDIUM','HIGH')),
  distance_odometer_km  numeric(9,1),
  distance_gps_km       numeric(9,1),
  distance_trips_km     numeric(9,1),
  liters                numeric(8,2),
  evidence              jsonb NOT NULL DEFAULT '{}',
  status                text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','EXPLAINED','CONFIRMED','DISMISSED')),
  resolved_by           bigint REFERENCES iam.app_user(id),
  resolved_at           timestamptz
);
COMMENT ON TABLE ptn.fuel_anomaly IS 'Fuel quantity that does not match tank size, distance or expected consumption (14.11 f)';

CREATE TABLE IF NOT EXISTS ptn.partner_settlement (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id     bigint NOT NULL REFERENCES ptn.partner(id),
  period         daterange NOT NULL,
  gross          bigint NOT NULL DEFAULT 0,
  commission     bigint NOT NULL DEFAULT 0,
  carrier_share  bigint NOT NULL DEFAULT 0,
  redemptions    bigint NOT NULL DEFAULT 0,                             -- points redeemed at the partner
  net            bigint NOT NULL DEFAULT 0,
  currency       char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  ledger_txn_id  bigint REFERENCES fin.ledger_txn(id),
  status         text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED','PAID')),
  EXCLUDE USING gist (partner_id WITH =, period WITH &&)
);

CREATE TABLE IF NOT EXISTS ptn.rest_stop_rating (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id   bigint NOT NULL REFERENCES ptn.partner(id),
  user_id      bigint NOT NULL REFERENCES iam.app_user(id),
  trip_id      bigint REFERENCES ops.trip(id),
  overall      smallint NOT NULL CHECK (overall BETWEEN 1 AND 5),
  cleanliness  smallint CHECK (cleanliness BETWEEN 1 AND 5),
  service      smallint CHECK (service BETWEEN 1 AND 5),
  value        smallint CHECK (value BETWEEN 1 AND 5),
  comment      text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (partner_id, user_id, trip_id)
);

-- ------------------------------ isolation and privileges ------------------------------
-- Partner staff see their partner; carriers see their own cards, sessions and sales; passengers their orders.
-- SECURITY DEFINER so the lookup does not re-enter the partner policy (no recursion)
CREATE OR REPLACE FUNCTION ptn.is_partner_staff(p_partner_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT sys.ctx_is_platform()
      OR EXISTS (SELECT 1 FROM ptn.partner p WHERE p.id = p_partner_id AND p.company_id = sys.ctx_company_id())
$$;
DO $$ BEGIN
  PERFORM sys.rls_split('ptn.partner', 'status = ''ACTIVE'' OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
  PERFORM sys.rls_split('ptn.partner_contract', 'ptn.is_partner_staff(partner_id)', 'sys.ctx_is_platform()');
  PERFORM sys.rls('ptn.station_employee', 'ptn.is_partner_staff(partner_id)');
  PERFORM sys.rls_split(t, 'true', 'ptn.is_partner_staff(partner_id)') FROM unnest(ARRAY['ptn.fuel_price','ptn.partner_menu_item']) t;
  PERFORM sys.rls_tenant('ptn.fuel_card');
  PERFORM sys.rls('ptn.fuel_session', 'ptn.is_partner_staff(partner_id) OR sys.tenant_visible(company_id)');
  PERFORM sys.rls('ptn.odometer_reading', 'sys.ctx_is_platform()
    OR EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = vehicle_id)
    OR EXISTS (SELECT 1 FROM ptn.fuel_session s WHERE s.id = session_id AND ptn.is_partner_staff(s.partner_id))');
  PERFORM sys.rls('ptn.partner_order', 'ptn.is_partner_staff(partner_id) OR sys.is_me(user_id)');
  PERFORM sys.rls_parent('ptn.partner_order_item', 'order_id', 'ptn.partner_order');
  PERFORM sys.rls('ptn.partner_sale', 'ptn.is_partner_staff(partner_id) OR sys.tenant_visible(company_id) OR sys.is_me(user_id)');
  PERFORM sys.rls_parent('ptn.fuel_anomaly', 'session_id', 'ptn.fuel_session');
  PERFORM sys.rls_split('ptn.partner_settlement', 'ptn.is_partner_staff(partner_id)', 'sys.ctx_is_platform()');
  PERFORM sys.rls_split('ptn.rest_stop_rating', 'true', 'sys.ctx_is_platform() OR sys.is_me(user_id)');
  PERFORM sys.grant_rw(ARRAY['ptn.partner','ptn.partner_contract','ptn.station_employee','ptn.fuel_price','ptn.fuel_card',
    'ptn.fuel_session','ptn.partner_menu_item','ptn.partner_order','ptn.partner_order_item','ptn.partner_sale',
    'ptn.fuel_anomaly','ptn.partner_settlement','ptn.rest_stop_rating']);
  PERFORM sys.grant_append(ARRAY['ptn.odometer_reading']);
END $$;

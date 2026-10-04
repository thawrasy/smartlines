-- =====================================================================
-- 1024: unified car rental platform (phase 12, study 21.2)
--   Each rental company is a tenant with a subscription; branches are points in the station register; cars are
--   fleet vehicles (class CAR) with ownership, insurance and inspection. Adds rental classes, rates and add-ons,
--   renter rules on the 11.9 pattern, bookings, signed contracts with additional drivers, pickup and return
--   inspections, security deposits, telematics devices and vehicle trip logs.
-- =====================================================================

CREATE TABLE IF NOT EXISTS rent.rental_company (
  company_id  bigint PRIMARY KEY REFERENCES iam.company(id),
  brand       text NOT NULL,
  status      text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','ENDED'))
);

CREATE TABLE IF NOT EXISTS rent.rental_branch (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id   bigint NOT NULL REFERENCES rent.rental_company(company_id),
  station_id   bigint NOT NULL REFERENCES net.station(id),
  branch_type  text NOT NULL CHECK (branch_type IN ('BRANCH','AIRPORT','HOTEL','BORDER')),
  hours        jsonb NOT NULL DEFAULT '{}',
  status       text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CLOSED')),
  UNIQUE (company_id, station_id)
);

CREATE TABLE IF NOT EXISTS rent.rental_vehicle_class (
  code  text PRIMARY KEY CHECK (code ~ '^[A-Z][A-Z0-9_]{1,29}$'),
  name  text NOT NULL,
  sort  int NOT NULL DEFAULT 100
);
INSERT INTO rent.rental_vehicle_class (code, name, sort) VALUES
  ('ECONOMY','Economy',10), ('MIDSIZE','Midsize',20), ('SUV_4WD','Four-wheel drive',30), ('LUXURY','Luxury',40), ('VAN','Van',50)
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS rent.rental_fleet (
  vehicle_id      bigint PRIMARY KEY REFERENCES fleet.vehicle(id),
  company_id      bigint NOT NULL REFERENCES rent.rental_company(company_id),
  rental_class    text NOT NULL REFERENCES rent.rental_vehicle_class(code),
  home_branch_id  bigint REFERENCES rent.rental_branch(id),
  status          text NOT NULL DEFAULT 'AVAILABLE' CHECK (status IN ('AVAILABLE','RENTED','MAINTENANCE','RETIRED'))
);
COMMENT ON TABLE rent.rental_fleet IS 'Rental extension of fleet.vehicle: its class and home branch';

CREATE TABLE IF NOT EXISTS rent.rental_rate (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id           bigint NOT NULL REFERENCES rent.rental_company(company_id),
  rental_class         text NOT NULL REFERENCES rent.rental_vehicle_class(code),
  branch_id            bigint REFERENCES rent.rental_branch(id),          -- empty: all branches
  unit                 text NOT NULL CHECK (unit IN ('DAY','WEEK','MONTH')),
  price                bigint NOT NULL CHECK (price > 0),
  km_included_per_day  int,                                              -- empty: unlimited
  extra_km_price       bigint NOT NULL DEFAULT 0,
  deposit_amount       bigint NOT NULL DEFAULT 0,
  currency             char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  valid                daterange NOT NULL,
  status               text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED'))
);

CREATE TABLE IF NOT EXISTS rent.rental_addon (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint NOT NULL REFERENCES rent.rental_company(company_id),
  code        text NOT NULL CHECK (code IN ('ADDITIONAL_DRIVER','CHILD_SEAT','FULL_INSURANCE','GPS','CROSS_BORDER')),
  price       bigint NOT NULL CHECK (price >= 0),
  unit        text NOT NULL CHECK (unit IN ('PER_DAY','PER_RENTAL')),
  currency    char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  active      boolean NOT NULL DEFAULT true,
  UNIQUE (company_id, code)
);

CREATE TABLE IF NOT EXISTS rent.renter_rule (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  renter_kind        text NOT NULL CHECK (renter_kind IN ('CITIZEN','RESIDENT','VISITOR')),
  rental_class       text REFERENCES rent.rental_vehicle_class(code),
  min_age            smallint NOT NULL DEFAULT 21 CHECK (min_age BETWEEN 18 AND 99),
  min_license_years  smallint NOT NULL DEFAULT 1,
  docs_required      text[] NOT NULL,                                   -- e.g. NATIONAL_ID, DRIVING_LICENSE, PASSPORT, ENTRY_PROOF, IDP
  version            int NOT NULL DEFAULT 1,
  status             text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  approved_by        bigint REFERENCES iam.app_user(id),
  UNIQUE NULLS NOT DISTINCT (renter_kind, rental_class, version)
);
COMMENT ON TABLE rent.renter_rule IS 'Renter eligibility as data-driven rules: age, licence years and documents (11.9 pattern)';

CREATE TABLE IF NOT EXISTS rent.rental_booking (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id        bigint NOT NULL REFERENCES rent.rental_company(company_id),
  renter_party_id   bigint NOT NULL REFERENCES iam.party(id),
  rental_class      text NOT NULL REFERENCES rent.rental_vehicle_class(code),
  vehicle_id        bigint REFERENCES rent.rental_fleet(vehicle_id),
  rate_id           bigint REFERENCES rent.rental_rate(id),
  pickup_branch_id  bigint NOT NULL REFERENCES rent.rental_branch(id),
  return_branch_id  bigint NOT NULL REFERENCES rent.rental_branch(id),
  period            tstzrange NOT NULL,
  quoted_total      bigint NOT NULL CHECK (quoted_total >= 0),
  currency          char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status            text NOT NULL DEFAULT 'CONFIRMED' CHECK (status IN ('PENDING','CONFIRMED','PICKED_UP','RETURNED','CANCELLED','NO_SHOW')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (vehicle_id WITH =, period WITH &&) WHERE (status IN ('CONFIRMED','PICKED_UP'))
);
COMMENT ON TABLE rent.rental_booking IS 'A rental across any company from unified search; a car cannot be double-booked';

CREATE TABLE IF NOT EXISTS rent.rental_booking_addon (
  booking_id  bigint NOT NULL REFERENCES rent.rental_booking(id) ON DELETE CASCADE,
  addon_id    bigint NOT NULL REFERENCES rent.rental_addon(id),
  qty         smallint NOT NULL DEFAULT 1 CHECK (qty > 0),
  amount      bigint NOT NULL CHECK (amount >= 0),
  PRIMARY KEY (booking_id, addon_id)
);

CREATE TABLE IF NOT EXISTS rent.rental_contract (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contract_no        text NOT NULL UNIQUE,
  booking_id         bigint NOT NULL UNIQUE REFERENCES rent.rental_booking(id),
  vehicle_id         bigint NOT NULL REFERENCES rent.rental_fleet(vehicle_id),
  terms              jsonb NOT NULL,                                     -- includes the tracking disclosure (21.2)
  signed_at          timestamptz,
  signature_file_id  bigint REFERENCES ref.file_object(id),
  closed_at          timestamptz,
  final_amount       bigint,
  status             text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED','DISPUTED'))
);
CREATE TABLE IF NOT EXISTS rent.contract_driver (
  contract_id       bigint NOT NULL REFERENCES rent.rental_contract(id) ON DELETE CASCADE,
  party_id          bigint NOT NULL REFERENCES iam.party(id),
  is_primary        boolean NOT NULL DEFAULT false,
  license_verified  boolean NOT NULL DEFAULT false,
  PRIMARY KEY (contract_id, party_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS contract_one_primary_driver ON rent.contract_driver (contract_id) WHERE is_primary;

CREATE TABLE IF NOT EXISTS rent.rental_inspection (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contract_id        bigint NOT NULL REFERENCES rent.rental_contract(id),
  stage              text NOT NULL CHECK (stage IN ('PICKUP','RETURN')),
  odometer_km        int NOT NULL CHECK (odometer_km >= 0),
  fuel_level_pct     smallint NOT NULL CHECK (fuel_level_pct BETWEEN 0 AND 100),
  damage             jsonb NOT NULL DEFAULT '[]',
  photo_file_ids     bigint[] NOT NULL DEFAULT '{}',
  inspector_user_id  bigint REFERENCES iam.app_user(id),
  renter_confirmed   boolean NOT NULL DEFAULT false,
  ts                 timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contract_id, stage)
);

CREATE TABLE IF NOT EXISTS rent.deposit_hold (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contract_id      bigint NOT NULL REFERENCES rent.rental_contract(id),
  method           text NOT NULL CHECK (method IN ('WALLET','CARD')),
  amount           bigint NOT NULL CHECK (amount > 0),
  currency         char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  wallet_id        bigint REFERENCES fin.wallet(id),
  provider_ref     text,
  captured_amount  bigint NOT NULL DEFAULT 0 CHECK (captured_amount >= 0),
  case_id          bigint REFERENCES crm.case(id),                       -- damages and fines settled as a claim (7.6)
  status           text NOT NULL DEFAULT 'HELD' CHECK (status IN ('HELD','PARTIALLY_CAPTURED','CAPTURED','RELEASED')),
  CHECK (captured_amount <= amount),
  CHECK (method <> 'WALLET' OR wallet_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS rent.telematics_device (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint NOT NULL REFERENCES rent.rental_company(company_id),
  vehicle_id    bigint UNIQUE REFERENCES fleet.vehicle(id),
  imei_hash     bytea NOT NULL UNIQUE,
  provider      text NOT NULL,
  installed_at  timestamptz,
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','OFFLINE','REMOVED'))
);

CREATE TABLE IF NOT EXISTS rent.vehicle_trip_log (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  device_id            bigint NOT NULL REFERENCES rent.telematics_device(id),
  vehicle_id           bigint NOT NULL REFERENCES fleet.vehicle(id),
  contract_id          bigint REFERENCES rent.rental_contract(id),
  started_at           timestamptz NOT NULL,
  ended_at             timestamptz,
  distance_km          numeric(8,2),
  max_speed_kmh        smallint,
  geofence_violations  int NOT NULL DEFAULT 0
);
COMMENT ON TABLE rent.vehicle_trip_log IS 'Trips recorded by the telematics device; access limited to the company for safety and recovery (21.2)';

-- ------------------------------ isolation and privileges ------------------------------
DO $$ BEGIN
  PERFORM sys.rls_split('rent.rental_company', 'status = ''ACTIVE'' OR sys.tenant_visible(company_id)', 'sys.ctx_is_platform()');
  PERFORM sys.rls_split(t, 'true', 'sys.tenant_visible(company_id)') FROM unnest(ARRAY['rent.rental_branch','rent.rental_rate','rent.rental_addon']) t;
  PERFORM sys.rls_catalog(t) FROM unnest(ARRAY['rent.rental_vehicle_class','rent.renter_rule']) t;
  PERFORM sys.rls_split('rent.rental_fleet', 'true', 'sys.tenant_visible(company_id)');
  PERFORM sys.rls('rent.rental_booking', 'sys.tenant_visible(company_id) OR renter_party_id = sys.ctx_party_id()');
  PERFORM sys.rls_parent('rent.rental_booking_addon', 'booking_id', 'rent.rental_booking');
  PERFORM sys.rls_parent('rent.rental_contract', 'booking_id', 'rent.rental_booking');
  PERFORM sys.rls_parent(t, 'contract_id', 'rent.rental_contract') FROM unnest(ARRAY['rent.contract_driver','rent.rental_inspection','rent.deposit_hold']) t;
  PERFORM sys.rls_tenant('rent.telematics_device');
  PERFORM sys.rls_parent('rent.vehicle_trip_log', 'device_id', 'rent.telematics_device');
  PERFORM sys.grant_rw(ARRAY['rent.rental_company','rent.rental_branch','rent.rental_vehicle_class','rent.rental_fleet',
    'rent.rental_rate','rent.rental_addon','rent.renter_rule','rent.rental_booking','rent.rental_booking_addon',
    'rent.rental_contract','rent.contract_driver','rent.rental_inspection','rent.deposit_hold','rent.telematics_device',
    'rent.vehicle_trip_log']);
END $$;

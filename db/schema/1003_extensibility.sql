-- =====================================================================
-- 1003: extensibility and readiness for study annex D (version 2.6)
--   D.4  Fixed lists become reference tables: party roles, trip types, vehicle classes, station subtypes and
--        cargo categories. A new value is a row added by the platform, not a schema change. System values
--        cannot be deleted.
--   D.1  Passenger transit across Syria: transit corridors and approved rest stops, the trip's border crossing
--        plan (entry and exit points), crossing events recorded at each border, and the transit head-count
--        reconciliation. Tickets carry the passenger's travel category.
--   D.2  Contracted transport (schools, universities, employers): its own schema `ctr` with contracts, routes,
--        riders, authorised receivers, attendance and invoices.
--   D.3  Cargo categories with hazard and temperature flags, for transit trucks.
--   Everything stays disabled behind feature flags until its phase (2.8).
-- =====================================================================

-- ------------------------------ D.4 reference tables ------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['party_role_type','trip_type','vehicle_class','station_subtype','cargo_category'] LOOP
    EXECUTE format($f$
      CREATE TABLE IF NOT EXISTS ref.%I (
        code        text PRIMARY KEY CHECK (code ~ '^[A-Z][A-Z0-9_]{1,39}$'),
        name        text NOT NULL,
        module      text NOT NULL DEFAULT 'core',
        is_system   boolean NOT NULL DEFAULT false,
        is_active   boolean NOT NULL DEFAULT true,
        sort        int NOT NULL DEFAULT 100,
        created_at  timestamptz NOT NULL DEFAULT now()
      )$f$, t);
  END LOOP;
END $$;
ALTER TABLE ref.cargo_category ADD COLUMN IF NOT EXISTS dangerous boolean NOT NULL DEFAULT false;
ALTER TABLE ref.cargo_category ADD COLUMN IF NOT EXISTS needs_temperature boolean NOT NULL DEFAULT false;

COMMENT ON TABLE ref.party_role_type IS 'Party roles (2.1); rows replace the former fixed list';
COMMENT ON TABLE ref.trip_type       IS 'Trip types: one trip entity with many types (2.1)';
COMMENT ON TABLE ref.vehicle_class   IS 'Vehicle classes';
COMMENT ON TABLE ref.station_subtype IS 'Station subtypes (BORDER marks a border crossing point)';
COMMENT ON TABLE ref.cargo_category  IS 'Cargo categories as additional information for transit and freight (annex D.3)';

INSERT INTO ref.party_role_type (code, name, module, is_system, sort) VALUES
  ('PASSENGER','Passenger','core',true,10), ('OPERATOR','Carrier','core',true,20), ('DRIVER','Driver','core',true,30),
  ('HOST','Host','core',true,40), ('OWNER','Vehicle owner','core',true,50), ('STATION_STAFF','Station staff','core',true,60),
  ('AGENCY','Travel agency','core',true,70), ('CHANNEL_PARTNER','Channel partner','core',true,80), ('INSURER','Insurer','core',true,90),
  ('AUTHORITY','Authority','core',true,100),
  ('EDU_INSTITUTION','School or university','contract_transport',true,200), ('EMPLOYER','Employer','contract_transport',true,210),
  ('GUARDIAN','Guardian','contract_transport',true,220), ('ATTENDANT','Bus attendant','contract_transport',true,230)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref.trip_type (code, name, module, is_system, sort) VALUES
  ('SCHEDULED','Scheduled','core',true,10), ('SHUTTLE','Shuttle','core',true,20), ('INTERNATIONAL','International','international',true,30),
  ('CARGO','Cargo','cargo',true,40), ('EXTRA','Extra','core',true,50),
  ('TRANSIT_PAX','Passenger transit','transit_passengers',true,60), ('CONTRACT','Contracted transport','contract_transport',true,70)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref.vehicle_class (code, name, is_system, sort) VALUES
  ('BUS','Bus',true,10), ('TRUCK','Truck',true,20), ('TRAIN','Train',true,30), ('CAR','Car',true,40), ('OTHER','Other',true,90)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref.station_subtype (code, name, is_system, sort) VALUES
  ('TERMINAL','Terminal',true,10), ('OFFICE','Office',true,20), ('PICKUP','Pick-up point',true,30), ('DEPOT','Depot',true,40),
  ('REST','Rest stop',true,50), ('BORDER','Border crossing',true,60)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref.cargo_category (code, name, module, is_system, dangerous, needs_temperature, sort) VALUES
  ('GENERAL','General goods','cargo',true,false,false,10), ('FOOD','Food','cargo',true,false,false,20),
  ('REFRIGERATED','Refrigerated','cargo',true,false,true,30), ('LIQUID','Liquids','cargo',true,false,false,40),
  ('DANGEROUS','Dangerous goods','cargo',true,true,false,50), ('LIVESTOCK','Livestock','cargo',true,false,false,60),
  ('VEHICLES','Vehicles','cargo',true,false,false,70), ('CONTAINERS','Containers','cargo',true,false,false,80),
  ('OTHER','Other','cargo',true,false,false,90)
ON CONFLICT (code) DO NOTHING;

-- System values are part of the platform's contract with the code: they can be deactivated, never deleted
CREATE OR REPLACE FUNCTION ref.tg_protect_system_value() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.is_system THEN
    RAISE EXCEPTION 'SYSTEM_VALUE: % is a system value and cannot be deleted', OLD.code USING ERRCODE = 'P0001';
  END IF;
  RETURN OLD;
END $$;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['party_role_type','trip_type','vehicle_class','station_subtype','cargo_category'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS protect_system_value ON ref.%I', t);
    EXECUTE format('CREATE TRIGGER protect_system_value BEFORE DELETE ON ref.%I FOR EACH ROW EXECUTE FUNCTION ref.tg_protect_system_value()', t);
    -- everyone reads; only the platform adds or changes values
    EXECUTE format('ALTER TABLE ref.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS ref_read ON ref.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS ref_write ON ref.%I', t);
    EXECUTE format('CREATE POLICY ref_read ON ref.%I FOR SELECT USING (true)', t);
    EXECUTE format('CREATE POLICY ref_write ON ref.%I FOR ALL USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform())', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ref.%I TO masslak_app', t);
    EXECUTE format('GRANT SELECT ON ref.%I TO masslak_readonly', t);
  END LOOP;
END $$;

-- The fixed CHECK lists give way to foreign keys on the reference tables
ALTER TABLE iam.party_role DROP CONSTRAINT IF EXISTS party_role_role_code_check;
ALTER TABLE ops.trip       DROP CONSTRAINT IF EXISTS trip_trip_type_check;
ALTER TABLE fleet.vehicle  DROP CONSTRAINT IF EXISTS vehicle_vehicle_class_check;
ALTER TABLE net.station    DROP CONSTRAINT IF EXISTS station_subtype_check;
DO $$ BEGIN
  ALTER TABLE iam.party_role ADD CONSTRAINT party_role_role_code_fk FOREIGN KEY (role_code) REFERENCES ref.party_role_type(code);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE ops.trip ADD CONSTRAINT trip_trip_type_fk FOREIGN KEY (trip_type) REFERENCES ref.trip_type(code);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE fleet.vehicle ADD CONSTRAINT vehicle_vehicle_class_fk FOREIGN KEY (vehicle_class) REFERENCES ref.vehicle_class(code);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE net.station ADD CONSTRAINT station_subtype_fk FOREIGN KEY (subtype) REFERENCES ref.station_subtype(code);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ------------------------------ D.1 passenger transit ------------------------------
CREATE TABLE IF NOT EXISTS net.corridor (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  code          text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9-]{3,40}$'),
  name          text NOT NULL,
  country_code  char(2) NOT NULL REFERENCES ref.country(code),
  path          jsonb NOT NULL,                        -- GeoJSON LineString of the approved route
  buffer_m      int NOT NULL DEFAULT 500 CHECK (buffer_m BETWEEN 50 AND 20000),
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE net.corridor IS 'Approved transit corridor: route and tolerance; leaving it raises a tracking alert (annex D.1.3)';

CREATE TABLE IF NOT EXISTS net.approved_rest_stop (
  corridor_id   bigint NOT NULL REFERENCES net.corridor(id) ON DELETE CASCADE,
  station_id    bigint NOT NULL REFERENCES net.station(id),
  max_minutes   int NOT NULL DEFAULT 30 CHECK (max_minutes BETWEEN 5 AND 240),
  PRIMARY KEY (corridor_id, station_id)
);
COMMENT ON TABLE net.approved_rest_stop IS 'The only places where a transit trip may stop on its corridor';

ALTER TABLE ops.trip ADD COLUMN IF NOT EXISTS corridor_id bigint REFERENCES net.corridor(id);
ALTER TABLE ops.trip ADD COLUMN IF NOT EXISTS transit_max_minutes int;
DO $$ BEGIN
  ALTER TABLE ops.trip ADD CONSTRAINT trip_transit_max_ck CHECK (transit_max_minutes IS NULL OR transit_max_minutes > 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN ops.trip.transit_max_minutes IS 'Longest allowed time between the entry and exit crossing events of a transit trip';

CREATE TABLE IF NOT EXISTS ops.trip_crossing_plan (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id           bigint NOT NULL REFERENCES ops.trip(id) ON DELETE CASCADE,
  seq               smallint NOT NULL CHECK (seq >= 1),
  exit_station_id   bigint NOT NULL REFERENCES net.station(id),   -- border point left
  entry_station_id  bigint NOT NULL REFERENCES net.station(id),   -- border point entered
  planned_at        timestamptz,
  UNIQUE (trip_id, seq),
  CHECK (exit_station_id <> entry_station_id)
);
COMMENT ON TABLE ops.trip_crossing_plan IS 'The trip''s border crossings in order (11.6); a transit trip has two: into Syria, then out of it';

CREATE OR REPLACE FUNCTION ops.tg_crossing_points_are_borders() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT count(*) FROM net.station WHERE id IN (NEW.exit_station_id, NEW.entry_station_id) AND subtype = 'BORDER') < 2 THEN
    RAISE EXCEPTION 'NOT_A_BORDER_POINT: crossing plan stations must be border points' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS crossing_points_are_borders ON ops.trip_crossing_plan;
CREATE TRIGGER crossing_points_are_borders BEFORE INSERT OR UPDATE ON ops.trip_crossing_plan
  FOR EACH ROW EXECUTE FUNCTION ops.tg_crossing_points_are_borders();

CREATE TABLE IF NOT EXISTS ops.crossing_event (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id             bigint NOT NULL REFERENCES ops.trip(id),
  station_id          bigint NOT NULL REFERENCES net.station(id),
  direction           text NOT NULL CHECK (direction IN ('ENTRY','EXIT')),
  source              text NOT NULL CHECK (source IN ('DRIVER','GEOFENCE','AUTHORITY')),
  occurred_at         timestamptz NOT NULL,
  lat                 numeric(9,6),
  lng                 numeric(9,6),
  recorded_by_user_id bigint REFERENCES iam.app_user(id),
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS crossing_event_trip_idx ON ops.crossing_event (trip_id, occurred_at);
COMMENT ON TABLE ops.crossing_event IS 'Border entry and exit of a trip (11.3 CROSSING_EVENT); append-only';

CREATE TABLE IF NOT EXISTS ops.transit_reconciliation (
  trip_id             bigint PRIMARY KEY REFERENCES ops.trip(id),
  entry_count         int NOT NULL DEFAULT 0,
  exit_count          int NOT NULL DEFAULT 0,
  missing_ticket_ids  bigint[] NOT NULL DEFAULT '{}',
  status              text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','MATCHED','DISCREPANCY','RESOLVED')),
  resolved_by_user_id bigint REFERENCES iam.app_user(id),
  resolved_at         timestamptz,
  note                text
);
COMMENT ON TABLE ops.transit_reconciliation IS 'Transit passengers leaving Syria must match those who entered (annex D.1.5)';

ALTER TABLE sales.ticket ADD COLUMN IF NOT EXISTS travel_category text;
DO $$ BEGIN
  ALTER TABLE sales.ticket ADD CONSTRAINT ticket_travel_category_ck
    CHECK (travel_category IS NULL OR travel_category IN ('DEPARTING','ARRIVING','TRANSIT','DOMESTIC'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN sales.ticket.travel_category IS 'International trips: departing, arriving, transit or domestic, from where the passenger boards and alights';

ALTER TABLE ops.tracking_alert DROP CONSTRAINT IF EXISTS tracking_alert_kind_check;
ALTER TABLE ops.tracking_alert ADD CONSTRAINT tracking_alert_kind_check CHECK (kind IN
  ('SIGNAL_LOST','TRACKING_OFF','OFF_ROUTE','MISSED_STOP','UNSCHEDULED_STOP','SPEEDING','CORRIDOR_EXIT','UNAPPROVED_STOP','TRANSIT_OVERDUE'));

-- Corridors are platform data, readable by everyone; crossing data follows the trip's company
ALTER TABLE net.corridor ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS corridor_read ON net.corridor;
DROP POLICY IF EXISTS corridor_write ON net.corridor;
CREATE POLICY corridor_read  ON net.corridor FOR SELECT USING (status = 'ACTIVE' OR sys.ctx_is_platform());
CREATE POLICY corridor_write ON net.corridor FOR ALL USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
ALTER TABLE net.approved_rest_stop ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rest_stop_read ON net.approved_rest_stop;
DROP POLICY IF EXISTS rest_stop_write ON net.approved_rest_stop;
CREATE POLICY rest_stop_read  ON net.approved_rest_stop FOR SELECT USING (true);
CREATE POLICY rest_stop_write ON net.approved_rest_stop FOR ALL USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());

ALTER TABLE ops.trip_crossing_plan ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS crossing_plan_read ON ops.trip_crossing_plan;
DROP POLICY IF EXISTS crossing_plan_write ON ops.trip_crossing_plan;
CREATE POLICY crossing_plan_read  ON ops.trip_crossing_plan FOR SELECT USING (EXISTS (SELECT 1 FROM ops.trip t WHERE t.id = trip_id));
CREATE POLICY crossing_plan_write ON ops.trip_crossing_plan FOR ALL
  USING (EXISTS (SELECT 1 FROM ops.trip t WHERE t.id = trip_id AND sys.tenant_visible(t.company_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM ops.trip t WHERE t.id = trip_id AND sys.tenant_visible(t.company_id)));
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ops.crossing_event','ops.transit_reconciliation'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS trip_company ON %s', t);
    EXECUTE format($p$CREATE POLICY trip_company ON %s
      USING (EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = trip_id AND sys.tenant_visible(x.company_id)))
      WITH CHECK (EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = trip_id AND sys.tenant_visible(x.company_id)))$p$, t);
  END LOOP;
END $$;
GRANT SELECT, INSERT, UPDATE, DELETE ON net.corridor, net.approved_rest_stop, ops.trip_crossing_plan, ops.transit_reconciliation TO masslak_app;
GRANT SELECT, INSERT ON ops.crossing_event TO masslak_app;
GRANT SELECT ON net.corridor, net.approved_rest_stop, ops.trip_crossing_plan, ops.crossing_event, ops.transit_reconciliation TO masslak_readonly;

-- ------------------------------ D.2 contracted transport (own schema) ------------------------------
CREATE SCHEMA IF NOT EXISTS ctr;
COMMENT ON SCHEMA ctr IS 'Contracted transport: schools, universities and employee transport (annex D.2)';

CREATE TABLE IF NOT EXISTS ctr.service_contract (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  kind                text NOT NULL CHECK (kind IN ('SCHOOL','UNIVERSITY','STAFF')),
  client_party_id     bigint NOT NULL REFERENCES iam.party(id),       -- the institution or employer
  client_company_id   bigint REFERENCES iam.company(id),              -- when the client uses the portal
  carrier_company_id  bigint NOT NULL REFERENCES iam.company(id),     -- a company, or an individual owner-driver's company record
  starts_on           date NOT NULL,
  ends_on             date NOT NULL,
  pricing_mode        text NOT NULL CHECK (pricing_mode IN ('MONTHLY','PER_RIDER','PER_TRIP')),
  price               bigint NOT NULL CHECK (price >= 0),             -- minor units
  currency            char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  terms               jsonb NOT NULL DEFAULT '{}',
  status              text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','SUSPENDED','ENDED')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_on >= starts_on)
);
CREATE TABLE IF NOT EXISTS ctr.contract_route (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contract_id     bigint NOT NULL REFERENCES ctr.service_contract(id) ON DELETE CASCADE,
  route_id        bigint REFERENCES net.route(id),
  direction       text NOT NULL CHECK (direction IN ('INBOUND','OUTBOUND')),
  operating_days  smallint[] NOT NULL DEFAULT '{1,2,3,4,5}',          -- ISO weekdays
  depart_time     time NOT NULL,
  vehicle_id      bigint REFERENCES fleet.vehicle(id),
  driver_party_id bigint REFERENCES iam.party(id),
  attendant_party_id bigint REFERENCES iam.party(id)
);
CREATE TABLE IF NOT EXISTS ctr.contract_rider (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contract_id       bigint NOT NULL REFERENCES ctr.service_contract(id) ON DELETE CASCADE,
  passenger_party_id bigint NOT NULL REFERENCES iam.party(id),
  guardian_party_id bigint REFERENCES iam.party(id),                  -- required for minors by the application
  pickup_station_id bigint REFERENCES net.station(id),
  dropoff_station_id bigint REFERENCES net.station(id),
  guardian_consent_at timestamptz,
  status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAUSED','ENDED')),
  UNIQUE (contract_id, passenger_party_id)
);
CREATE TABLE IF NOT EXISTS ctr.authorized_receiver (
  rider_id      bigint NOT NULL REFERENCES ctr.contract_rider(id) ON DELETE CASCADE,
  party_id      bigint NOT NULL REFERENCES iam.party(id),
  relation      text NOT NULL,
  verified_at   timestamptz,
  PRIMARY KEY (rider_id, party_id)
);
CREATE TABLE IF NOT EXISTS ctr.attendance_event (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id     bigint NOT NULL REFERENCES ops.trip(id),
  rider_id    bigint NOT NULL REFERENCES ctr.contract_rider(id),
  event       text NOT NULL CHECK (event IN ('BOARD','ALIGHT','ABSENT','HANDED_OVER')),
  received_by_party_id bigint REFERENCES iam.party(id),               -- who took the child at drop-off
  occurred_at timestamptz NOT NULL,
  lat         numeric(9,6),
  lng         numeric(9,6),
  source      text NOT NULL CHECK (source IN ('SCAN','DRIVER','ATTENDANT','SYSTEM'))
);
CREATE INDEX IF NOT EXISTS attendance_trip_idx ON ctr.attendance_event (trip_id, rider_id);
CREATE TABLE IF NOT EXISTS ctr.contract_invoice (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contract_id   bigint NOT NULL REFERENCES ctr.service_contract(id),
  period_start  date NOT NULL,
  period_end    date NOT NULL,
  amount        bigint NOT NULL CHECK (amount >= 0),
  currency      char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status        text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ISSUED','PAID','VOID')),
  UNIQUE (contract_id, period_start)
);
COMMENT ON TABLE ctr.service_contract    IS 'Contract between an institution or employer and a carrier (annex D.2.2)';
COMMENT ON TABLE ctr.contract_rider      IS 'Riders on the contract; minors need guardian consent (D.2.4)';
COMMENT ON TABLE ctr.authorized_receiver IS 'People allowed to receive a child at drop-off (D.2.4)';
COMMENT ON TABLE ctr.attendance_event    IS 'Boarding, alighting, absence and hand-over; append-only';

-- Isolation: the carrier and the client institution see their own contracts and everything under them
ALTER TABLE ctr.service_contract ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS contract_parties ON ctr.service_contract;
CREATE POLICY contract_parties ON ctr.service_contract
  USING (sys.tenant_visible(carrier_company_id) OR sys.tenant_visible(client_company_id))
  WITH CHECK (sys.tenant_visible(carrier_company_id) OR sys.tenant_visible(client_company_id));
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ctr.contract_route','ctr.contract_rider','ctr.contract_invoice'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS via_contract ON %s', t);
    EXECUTE format($p$CREATE POLICY via_contract ON %s
      USING (EXISTS (SELECT 1 FROM ctr.service_contract c WHERE c.id = contract_id))
      WITH CHECK (EXISTS (SELECT 1 FROM ctr.service_contract c WHERE c.id = contract_id))$p$, t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['ctr.authorized_receiver','ctr.attendance_event'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS via_rider ON %s', t);
    EXECUTE format($p$CREATE POLICY via_rider ON %s
      USING (EXISTS (SELECT 1 FROM ctr.contract_rider r WHERE r.id = rider_id))
      WITH CHECK (EXISTS (SELECT 1 FROM ctr.contract_rider r WHERE r.id = rider_id))$p$, t);
  END LOOP;
END $$;
GRANT USAGE ON SCHEMA ctr TO masslak_app, masslak_readonly, masslak_auditor;
GRANT SELECT, INSERT, UPDATE, DELETE ON ctr.service_contract, ctr.contract_route, ctr.contract_rider, ctr.authorized_receiver, ctr.contract_invoice TO masslak_app;
GRANT SELECT, INSERT ON ctr.attendance_event TO masslak_app;
GRANT SELECT ON ALL TABLES IN SCHEMA ctr TO masslak_readonly;

-- ------------------------------ feature flags (2.8) ------------------------------
UPDATE sys.setting SET value = '{"transit_passengers":false,"contract_transport":false}'::jsonb || value
 WHERE key = 'features' AND NOT (value ? 'transit_passengers' AND value ? 'contract_transport');

INSERT INTO sys.schema_migration (version, description)
SELECT '1.11.0', 'Reference tables for extensible lists; passenger transit, contracted transport and cargo category readiness'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.11.0');

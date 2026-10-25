-- 1173: one fleet for every kind of vehicle (owner's notes, 25 October 2026). A company defines all its vehicles in one
-- place; what it may define follows its contract with the platform:
--   * iam.company_fleet_line: the lines of business the platform opened for the company (buses, trucks, car rental,
--     taxis), each from the contract and with its period; a vehicle of a use needs its company to hold the line.
--   * fleet.vehicle.fleet_use: the vehicle's use (coach, city bus, minibus, van, rigid truck, tractor head, rental car,
--     taxi), with its odometer, colour and fuel. A tractor head pulls a trailer (fleet.trailer, its own plate and
--     licences, 10.4); some countries number the head and the trailer separately, and both carry licences.
--   * Insurance: a policy names the insurer from the registry (1156), its number, cover and dates, for a vehicle or a
--     trailer; it is checked with the insurer's system later (source INSURER, verified_at).
--   * Maintenance: service plans (oil change, periodic service, tyres, inspection, or a maintenance contract) by
--     distance and months; a vehicle sent to the workshop is IN_MAINTENANCE: an out-of-service period of kind
--     MAINTENANCE refuses a trip (1101) and a rental until it comes back.
--   * Car rental: a rate with unlimited kilometres or kilometres a day and a price for each extra one; a hire with a
--     driver; the odometer at pickup and return gives the extra kilometres (rent.hire_distance).

-- ------------------------------------------------------------------ lines of business by contract
CREATE TABLE IF NOT EXISTS iam.company_fleet_line (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint NOT NULL REFERENCES iam.company(id),
  line          text NOT NULL CHECK (line IN ('BUS', 'TRUCK', 'RENTAL', 'TAXI')),
  contract_ref  text CHECK (contract_ref IS NULL OR length(contract_ref) BETWEEN 2 AND 60),
  valid         daterange NOT NULL DEFAULT daterange(CURRENT_DATE, NULL),
  granted_by    bigint REFERENCES iam.app_user(id),
  ended_by      bigint REFERENCES iam.app_user(id),
  ended_at      timestamptz,
  note          text CHECK (note IS NULL OR length(note) <= 300),
  created_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE iam.company_fleet_line DROP CONSTRAINT IF EXISTS company_fleet_line_once;
ALTER TABLE iam.company_fleet_line ADD CONSTRAINT company_fleet_line_once
  EXCLUDE USING gist (company_id WITH =, line WITH =, valid WITH &&) WHERE (ended_at IS NULL);
CREATE INDEX IF NOT EXISTS company_fleet_line_granted_by_fkx ON iam.company_fleet_line (granted_by);
CREATE INDEX IF NOT EXISTS company_fleet_line_ended_by_fkx ON iam.company_fleet_line (ended_by);
COMMENT ON TABLE iam.company_fleet_line IS 'Lines of business the platform opened for a company under its contract (buses, trucks, car rental, taxis), each for a period (1173)';

-- every company already running vehicles keeps what it runs
INSERT INTO iam.company_fleet_line (company_id, line, note)
SELECT c.id, 'BUS', 'opened for the carriers already registered (1173)' FROM iam.company c
 WHERE c.company_type IN ('CARRIER', 'INDIVIDUAL_OPERATOR', 'FOREIGN_CARRIER', 'SCHOOL')
   AND NOT EXISTS (SELECT 1 FROM iam.company_fleet_line l WHERE l.company_id = c.id AND l.line = 'BUS');
INSERT INTO iam.company_fleet_line (company_id, line, note)
SELECT DISTINCT v.company_id, 'TRUCK', 'opened for the trucks already registered (1173)'
  FROM fleet.vehicle v WHERE v.vehicle_class = 'TRUCK'
   AND NOT EXISTS (SELECT 1 FROM iam.company_fleet_line l WHERE l.company_id = v.company_id AND l.line = 'TRUCK');
INSERT INTO iam.company_fleet_line (company_id, line, note)
SELECT r.company_id, 'RENTAL', 'opened for the rental companies already registered (1173)' FROM rent.rental_company r
 WHERE NOT EXISTS (SELECT 1 FROM iam.company_fleet_line l WHERE l.company_id = r.company_id AND l.line = 'RENTAL');

CREATE OR REPLACE FUNCTION iam.fleet_line_open(p_company bigint, p_line text) RETURNS boolean
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM iam.company_fleet_line
                  WHERE company_id = p_company AND line = p_line AND valid @> CURRENT_DATE AND ended_at IS NULL)
$$;
COMMENT ON FUNCTION iam.fleet_line_open(bigint, text) IS 'Whether the company holds the line of business today (1173)';

-- a carrier registered from now on starts with buses, as before; the platform opens the other lines by contract, and a
-- rental company it registers gets car rental
CREATE OR REPLACE FUNCTION iam.tg_company_default_line() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_TABLE_NAME = 'company' THEN
    IF NEW.company_type IN ('CARRIER', 'INDIVIDUAL_OPERATOR', 'FOREIGN_CARRIER', 'SCHOOL') THEN
      INSERT INTO iam.company_fleet_line (company_id, line, note) VALUES (NEW.id, 'BUS', 'opened with the company (1173)')
      ON CONFLICT DO NOTHING;
    END IF;
  ELSIF NOT iam.fleet_line_open(NEW.company_id, 'RENTAL') THEN
    INSERT INTO iam.company_fleet_line (company_id, line, note) VALUES (NEW.company_id, 'RENTAL', 'opened with the rental company (1173)');
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION iam.tg_company_default_line() FROM PUBLIC;
DROP TRIGGER IF EXISTS company_default_line ON iam.company;
CREATE TRIGGER company_default_line AFTER INSERT ON iam.company FOR EACH ROW EXECUTE FUNCTION iam.tg_company_default_line();
DROP TRIGGER IF EXISTS rental_company_line ON rent.rental_company;
CREATE TRIGGER rental_company_line AFTER INSERT ON rent.rental_company FOR EACH ROW EXECUTE FUNCTION iam.tg_company_default_line();

-- ------------------------------------------------------------------ the vehicle's use, odometer, colour, fuel
ALTER TABLE fleet.vehicle ADD COLUMN IF NOT EXISTS fleet_use text;
UPDATE fleet.vehicle SET fleet_use = CASE
    WHEN vehicle_class = 'TRUCK' THEN 'TRUCK'
    WHEN vehicle_type IN ('COACH', 'MINIBUS', 'CITY_BUS', 'VAN') THEN vehicle_type
    WHEN vehicle_class = 'CAR' THEN 'RENTAL_CAR'
    ELSE 'OTHER' END
 WHERE fleet_use IS NULL;
UPDATE fleet.vehicle v SET fleet_use = 'RENTAL_CAR' FROM rent.rental_fleet r WHERE r.vehicle_id = v.id AND v.fleet_use <> 'RENTAL_CAR';
ALTER TABLE fleet.vehicle ALTER COLUMN fleet_use SET NOT NULL;
ALTER TABLE fleet.vehicle DROP CONSTRAINT IF EXISTS vehicle_fleet_use_ck;
ALTER TABLE fleet.vehicle ADD CONSTRAINT vehicle_fleet_use_ck CHECK (fleet_use IN
  ('COACH', 'CITY_BUS', 'MINIBUS', 'VAN', 'TRUCK', 'TRACTOR', 'RENTAL_CAR', 'TAXI', 'OTHER'));
ALTER TABLE fleet.vehicle ADD COLUMN IF NOT EXISTS odometer_km integer CHECK (odometer_km IS NULL OR odometer_km BETWEEN 0 AND 9999999);
ALTER TABLE fleet.vehicle ADD COLUMN IF NOT EXISTS odometer_at timestamptz;
ALTER TABLE fleet.vehicle ADD COLUMN IF NOT EXISTS colour text CHECK (colour IS NULL OR length(colour) BETWEEN 2 AND 30);
ALTER TABLE fleet.vehicle ADD COLUMN IF NOT EXISTS fuel_type text CHECK (fuel_type IS NULL OR fuel_type IN
  ('PETROL', 'DIESEL', 'HYBRID', 'PLUG_IN_HYBRID', 'ELECTRIC', 'RANGE_EXTENDER', 'GAS'));
ALTER TABLE fleet.vehicle ADD COLUMN IF NOT EXISTS trim_id bigint REFERENCES ref.vehicle_trim(id);
CREATE INDEX IF NOT EXISTS vehicle_trim_id_fkx ON fleet.vehicle (trim_id);
COMMENT ON COLUMN fleet.vehicle.fleet_use IS 'What the vehicle is used for: coach, city bus, minibus, van, rigid truck, tractor head, rental car, taxi (1173)';
COMMENT ON COLUMN fleet.vehicle.odometer_km IS 'The last odometer reading (registration, workshop, rental pickup and return) (1173)';
COMMENT ON COLUMN fleet.vehicle.trim_id IS 'The trim of the chosen model, when known (1172, 1173)';

ALTER TABLE fleet.vehicle DROP CONSTRAINT IF EXISTS vehicle_status_check;
ALTER TABLE fleet.vehicle ADD CONSTRAINT vehicle_status_check CHECK (status IN
  ('PENDING', 'ACTIVE', 'BLOCKED', 'OUT_OF_SERVICE', 'IN_MAINTENANCE', 'IMPOUNDED', 'RETIRED'));

-- a vehicle of a use needs its company to hold the line; the trim belongs to the chosen model
CREATE OR REPLACE FUNCTION fleet.tg_vehicle_fleet_use() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_line text;
BEGIN
  -- a vehicle entered without its use takes the one its class and type say
  IF NEW.fleet_use IS NULL THEN
    NEW.fleet_use := CASE WHEN NEW.vehicle_class = 'TRUCK' THEN 'TRUCK'
                          WHEN NEW.vehicle_type IN ('COACH', 'MINIBUS', 'CITY_BUS', 'VAN') AND NEW.vehicle_class = 'BUS' THEN NEW.vehicle_type
                          ELSE 'OTHER' END;
  END IF;
  v_line := CASE WHEN NEW.fleet_use IN ('COACH', 'CITY_BUS', 'MINIBUS', 'VAN') THEN 'BUS'
                 WHEN NEW.fleet_use IN ('TRUCK', 'TRACTOR') THEN 'TRUCK'
                 WHEN NEW.fleet_use = 'RENTAL_CAR' THEN 'RENTAL'
                 WHEN NEW.fleet_use = 'TAXI' THEN 'TAXI' END;
  -- a row of a company the caller does not see is left to row-level security to refuse
  IF (TG_OP = 'INSERT' OR NEW.fleet_use IS DISTINCT FROM OLD.fleet_use) AND v_line IS NOT NULL
     AND (NOT row_security_active('iam.company_fleet_line') OR sys.tenant_visible(NEW.company_id) OR sys.ctx_is_platform())
     AND NOT iam.fleet_line_open(NEW.company_id, v_line) THEN
    RAISE EXCEPTION 'FLEET_LINE_CLOSED: the company''s contract does not cover % vehicles', lower(v_line) USING ERRCODE = 'P0001';
  END IF;
  IF NEW.trim_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.trim_id IS DISTINCT FROM OLD.trim_id OR NEW.model_id IS DISTINCT FROM OLD.model_id)
     AND NOT EXISTS (SELECT 1 FROM ref.vehicle_trim t WHERE t.id = NEW.trim_id AND t.model_id = NEW.model_id AND t.status = 'ACTIVE') THEN
    RAISE EXCEPTION 'TRIM_UNKNOWN: choose a trim of the vehicle''s model' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION fleet.tg_vehicle_fleet_use() FROM PUBLIC;
DROP TRIGGER IF EXISTS vehicle_fleet_use ON fleet.vehicle;
CREATE TRIGGER vehicle_fleet_use BEFORE INSERT OR UPDATE OF fleet_use, trim_id, model_id ON fleet.vehicle
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_vehicle_fleet_use();

-- the vehicle's own history keeps the new fields too (1170)
DROP TRIGGER IF EXISTS vehicle_edit_history ON fleet.vehicle;
CREATE TRIGGER vehicle_edit_history BEFORE UPDATE ON fleet.vehicle FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'fleet.vehicle_change', 'vehicle_id', 'id',
  'plate_no,plate_country,chassis_no,machine_no,serial_no,vehicle_type,vehicle_class,make,model,model_id,manufacture_year,seat_layout_id,passenger_seats,standing_capacity,cargo_capacity_kg,fuel_tank_l,ownership_type,status,block_reason,fleet_use,colour,fuel_type,trim_id',
  'plate_no,plate_country,chassis_no,machine_no,serial_no', 'VEHICLE');

-- ------------------------------------------------------------------ trailers: edits kept, insurance like a vehicle
ALTER TABLE fleet.trailer ADD COLUMN IF NOT EXISTS change_reason text CHECK (change_reason IS NULL);
ALTER TABLE fleet.trailer ADD COLUMN IF NOT EXISTS make text CHECK (make IS NULL OR length(make) BETWEEN 1 AND 60);
ALTER TABLE fleet.trailer ADD COLUMN IF NOT EXISTS manufacture_year smallint CHECK (manufacture_year IS NULL OR manufacture_year BETWEEN 1950 AND 2100);
COMMENT ON COLUMN fleet.trailer.change_reason IS 'Given with an edit and moved into fleet.trailer_change by the trigger (1173)';
CREATE TABLE IF NOT EXISTS fleet.trailer_change (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trailer_id  bigint NOT NULL REFERENCES fleet.trailer(id),
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  bigint REFERENCES iam.app_user(id),
  field       text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value   text,
  new_value   text,
  reason      text CHECK (reason IS NULL OR length(reason) <= 500)
);
COMMENT ON TABLE fleet.trailer_change IS 'Every edit of a trailer, field by field, with who, when and why (1173); never updated or deleted';
CREATE INDEX IF NOT EXISTS trailer_change_trailer ON fleet.trailer_change (trailer_id, changed_at);
CREATE INDEX IF NOT EXISTS trailer_change_user ON fleet.trailer_change (changed_by);
DROP TRIGGER IF EXISTS trailer_edit_history ON fleet.trailer;
CREATE TRIGGER trailer_edit_history BEFORE UPDATE ON fleet.trailer FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'fleet.trailer_change', 'trailer_id', 'id',
  'plate_no,plate_country,chassis_no,trailer_type,payload_kg,volume_m3,length_m,axles,container_capacity,ownership_type,status,make,manufacture_year',
  'plate_no,plate_country,chassis_no', 'TRAILER');
DROP TRIGGER IF EXISTS trailer_change_append_only ON fleet.trailer_change;
CREATE TRIGGER trailer_change_append_only BEFORE UPDATE OR DELETE ON fleet.trailer_change
  FOR EACH ROW EXECUTE FUNCTION sys.tg_history_append_only();

ALTER TABLE fleet.insurance_policy ADD COLUMN IF NOT EXISTS trailer_id bigint REFERENCES fleet.trailer(id);
ALTER TABLE fleet.insurance_policy ALTER COLUMN vehicle_id DROP NOT NULL;
ALTER TABLE fleet.insurance_policy DROP CONSTRAINT IF EXISTS insurance_policy_subject_ck;
ALTER TABLE fleet.insurance_policy ADD CONSTRAINT insurance_policy_subject_ck CHECK (num_nonnulls(vehicle_id, trailer_id) = 1);
ALTER TABLE fleet.insurance_policy ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid();
CREATE UNIQUE INDEX IF NOT EXISTS insurance_policy_uid_uq ON fleet.insurance_policy (uid);
CREATE INDEX IF NOT EXISTS insurance_policy_trailer_id_fkx ON fleet.insurance_policy (trailer_id);
COMMENT ON COLUMN fleet.insurance_policy.trailer_id IS 'The trailer the policy covers, when it is not a vehicle (1173)';
-- a policy is seen with the vehicle or the trailer it covers
DROP POLICY IF EXISTS tenant_isolation ON fleet.insurance_policy;
CREATE POLICY tenant_isolation ON fleet.insurance_policy
  USING (EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = insurance_policy.vehicle_id)
         OR EXISTS (SELECT 1 FROM fleet.trailer t WHERE t.id = insurance_policy.trailer_id));

-- ------------------------------------------------------------------ maintenance
ALTER TABLE fleet.vehicle_service_status DROP CONSTRAINT IF EXISTS vehicle_service_status_status_check;
ALTER TABLE fleet.vehicle_service_status ADD CONSTRAINT vehicle_service_status_status_check
  CHECK (status IN ('ACTIVE', 'OUT_OF_SERVICE', 'IMPOUNDED', 'MAINTENANCE'));

CREATE TABLE IF NOT EXISTS fleet.service_plan (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid(),
  company_id        bigint NOT NULL REFERENCES iam.company(id),
  vehicle_id        bigint NOT NULL REFERENCES fleet.vehicle(id),
  kind              text NOT NULL CHECK (kind IN ('OIL_CHANGE', 'PERIODIC', 'TYRES', 'INSPECTION', 'CONTRACT', 'OTHER')),
  every_km          integer CHECK (every_km IS NULL OR every_km BETWEEN 100 AND 500000),
  every_months      smallint CHECK (every_months IS NULL OR every_months BETWEEN 1 AND 120),
  last_km           integer CHECK (last_km IS NULL OR last_km >= 0),
  last_date         date,
  provider          text CHECK (provider IS NULL OR length(provider) BETWEEN 2 AND 120),
  contract_no       text CHECK (contract_no IS NULL OR length(contract_no) BETWEEN 2 AND 60),
  contract_until    date,
  notes             text CHECK (notes IS NULL OR length(notes) <= 500),
  status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'ENDED')),
  created_by        bigint REFERENCES iam.app_user(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT service_plan_interval_ck CHECK (every_km IS NOT NULL OR every_months IS NOT NULL OR kind = 'CONTRACT'),
  CONSTRAINT service_plan_contract_ck CHECK (kind <> 'CONTRACT' OR (provider IS NOT NULL AND contract_no IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS service_plan_uid_uq ON fleet.service_plan (uid);
CREATE INDEX IF NOT EXISTS service_plan_company_id_fkx ON fleet.service_plan (company_id);
CREATE INDEX IF NOT EXISTS service_plan_vehicle_id_fkx ON fleet.service_plan (vehicle_id);
CREATE INDEX IF NOT EXISTS service_plan_created_by_fkx ON fleet.service_plan (created_by);
COMMENT ON TABLE fleet.service_plan IS 'When a vehicle is serviced: oil change, periodic service, tyres, inspection, by distance and months, or a maintenance contract (1173)';
DROP TRIGGER IF EXISTS service_plan_updated ON fleet.service_plan;
CREATE TRIGGER service_plan_updated BEFORE UPDATE ON fleet.service_plan FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();

CREATE TABLE IF NOT EXISTS fleet.maintenance_visit (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                uuid NOT NULL DEFAULT gen_random_uuid(),
  company_id         bigint NOT NULL REFERENCES iam.company(id),
  vehicle_id         bigint NOT NULL REFERENCES fleet.vehicle(id),
  plan_id            bigint REFERENCES fleet.service_plan(id),
  kind               text NOT NULL CHECK (kind IN ('OIL_CHANGE', 'PERIODIC', 'TYRES', 'INSPECTION', 'REPAIR', 'ACCIDENT', 'OTHER')),
  workshop           text CHECK (workshop IS NULL OR length(workshop) BETWEEN 2 AND 120),
  sent_at            timestamptz NOT NULL DEFAULT now(),
  odometer_out       integer CHECK (odometer_out IS NULL OR odometer_out >= 0),
  expected_back      date,
  returned_at        timestamptz,
  odometer_in        integer CHECK (odometer_in IS NULL OR odometer_in >= 0),
  cost               bigint CHECK (cost IS NULL OR cost >= 0),
  currency           char(3),
  notes              text CHECK (notes IS NULL OR length(notes) <= 500),
  service_status_id  bigint REFERENCES fleet.vehicle_service_status(id),
  opened_by          bigint REFERENCES iam.app_user(id),
  closed_by          bigint REFERENCES iam.app_user(id),
  CONSTRAINT maintenance_visit_back_ck CHECK (returned_at IS NULL OR returned_at >= sent_at),
  CONSTRAINT maintenance_visit_odometer_ck CHECK (odometer_in IS NULL OR odometer_out IS NULL OR odometer_in >= odometer_out)
);
CREATE UNIQUE INDEX IF NOT EXISTS maintenance_visit_uid_uq ON fleet.maintenance_visit (uid);
CREATE UNIQUE INDEX IF NOT EXISTS maintenance_visit_open_uq ON fleet.maintenance_visit (vehicle_id) WHERE returned_at IS NULL;
CREATE INDEX IF NOT EXISTS maintenance_visit_company_id_fkx ON fleet.maintenance_visit (company_id);
CREATE INDEX IF NOT EXISTS maintenance_visit_plan_id_fkx ON fleet.maintenance_visit (plan_id);
CREATE INDEX IF NOT EXISTS maintenance_visit_service_status_id_fkx ON fleet.maintenance_visit (service_status_id);
CREATE INDEX IF NOT EXISTS maintenance_visit_opened_by_fkx ON fleet.maintenance_visit (opened_by);
CREATE INDEX IF NOT EXISTS maintenance_visit_closed_by_fkx ON fleet.maintenance_visit (closed_by);
COMMENT ON TABLE fleet.maintenance_visit IS 'A vehicle sent to the workshop and its return; while open the vehicle is in maintenance and takes no trip or rental (1173)';

-- sending a vehicle opens its maintenance period and marks it; its return closes both and moves its plan on
CREATE OR REPLACE FUNCTION fleet.tg_maintenance_visit() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_status text; v_period bigint;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT status INTO v_status FROM fleet.vehicle WHERE id = NEW.vehicle_id FOR UPDATE;
    IF v_status NOT IN ('ACTIVE', 'OUT_OF_SERVICE') THEN
      RAISE EXCEPTION 'VEHICLE_NOT_AVAILABLE: a % vehicle is not sent to the workshop', lower(v_status) USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM rent.rental_booking b WHERE b.vehicle_id = NEW.vehicle_id AND b.status = 'PICKED_UP') THEN
      RAISE EXCEPTION 'VEHICLE_ON_HIRE: the vehicle is with a renter; take it back first' USING ERRCODE = 'P0001';
    END IF;
    -- an open out-of-service period becomes the maintenance period
    UPDATE fleet.vehicle_service_status SET period = tstzrange(lower(period), NEW.sent_at)
     WHERE vehicle_id = NEW.vehicle_id AND upper_inf(period) AND lower(period) < NEW.sent_at;
    INSERT INTO fleet.vehicle_service_status (company_id, vehicle_id, status, reason, period)
    VALUES (NEW.company_id, NEW.vehicle_id, 'MAINTENANCE', 'Workshop: ' || coalesce(NEW.workshop, lower(NEW.kind)), tstzrange(NEW.sent_at, NULL))
    RETURNING id INTO v_period;
    NEW.service_status_id := v_period;
    UPDATE fleet.vehicle SET status = 'IN_MAINTENANCE' WHERE id = NEW.vehicle_id;
    IF NEW.odometer_out IS NOT NULL THEN
      UPDATE fleet.vehicle SET odometer_km = greatest(coalesce(odometer_km, 0), NEW.odometer_out), odometer_at = NEW.sent_at
       WHERE id = NEW.vehicle_id;
    END IF;
  ELSIF NEW.returned_at IS NOT NULL AND OLD.returned_at IS NULL THEN
    UPDATE fleet.vehicle_service_status SET period = tstzrange(lower(period), NEW.returned_at) WHERE id = NEW.service_status_id;
    UPDATE fleet.vehicle SET status = 'ACTIVE' WHERE id = NEW.vehicle_id AND status = 'IN_MAINTENANCE';
    IF NEW.odometer_in IS NOT NULL THEN
      UPDATE fleet.vehicle SET odometer_km = greatest(coalesce(odometer_km, 0), NEW.odometer_in), odometer_at = NEW.returned_at
       WHERE id = NEW.vehicle_id;
    END IF;
    IF NEW.plan_id IS NOT NULL THEN
      UPDATE fleet.service_plan SET last_date = NEW.returned_at::date, last_km = coalesce(NEW.odometer_in, NEW.odometer_out, last_km)
       WHERE id = NEW.plan_id;
    END IF;
  ELSIF OLD.returned_at IS NOT NULL AND (NEW.returned_at IS DISTINCT FROM OLD.returned_at OR NEW.vehicle_id <> OLD.vehicle_id) THEN
    RAISE EXCEPTION 'VISIT_CLOSED: a finished workshop visit is not reopened; record a new one' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION fleet.tg_maintenance_visit() FROM PUBLIC;
DROP TRIGGER IF EXISTS maintenance_visit_status ON fleet.maintenance_visit;
CREATE TRIGGER maintenance_visit_status BEFORE INSERT OR UPDATE ON fleet.maintenance_visit
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_maintenance_visit();

-- the next service of a plan: by distance, by date, or both
CREATE OR REPLACE FUNCTION fleet.service_due(p_plan fleet.service_plan, p_odometer integer)
RETURNS TABLE (next_km integer, next_date date, due boolean)
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN p_plan.every_km IS NOT NULL THEN coalesce(p_plan.last_km, 0) + p_plan.every_km END,
         CASE WHEN p_plan.every_months IS NOT NULL THEN (coalesce(p_plan.last_date, p_plan.created_at::date)
                                                         + make_interval(months => p_plan.every_months))::date
              WHEN p_plan.kind = 'CONTRACT' THEN p_plan.contract_until END,
         p_plan.status = 'ACTIVE' AND (
           (p_plan.every_km IS NOT NULL AND coalesce(p_odometer, 0) >= coalesce(p_plan.last_km, 0) + p_plan.every_km)
           OR (p_plan.every_months IS NOT NULL AND CURRENT_DATE >= coalesce(p_plan.last_date, p_plan.created_at::date)
                                                                   + make_interval(months => p_plan.every_months)))
$$;
COMMENT ON FUNCTION fleet.service_due(fleet.service_plan, integer) IS 'The next service of a plan by distance and date, and whether it is due now (1173)';

-- ------------------------------------------------------------------ car rental: kilometres, a driver, no car in the workshop
ALTER TABLE rent.rental_rate ADD COLUMN IF NOT EXISTS unlimited_km boolean NOT NULL DEFAULT false;
-- a rate written before without its kilometre terms had none: it is unlimited
UPDATE rent.rental_rate SET unlimited_km = true
 WHERE NOT unlimited_km AND (km_included_per_day IS NULL OR km_included_per_day <= 0 OR extra_km_price IS NULL OR extra_km_price < 0);
ALTER TABLE rent.rental_rate DROP CONSTRAINT IF EXISTS rental_rate_km_ck;
ALTER TABLE rent.rental_rate ADD CONSTRAINT rental_rate_km_ck CHECK (
  unlimited_km OR (km_included_per_day IS NOT NULL AND km_included_per_day > 0 AND extra_km_price IS NOT NULL AND extra_km_price >= 0));
ALTER TABLE rent.rental_rate ADD COLUMN IF NOT EXISTS driver_price_per_day bigint CHECK (driver_price_per_day IS NULL OR driver_price_per_day >= 0);
COMMENT ON COLUMN rent.rental_rate.unlimited_km IS 'Unlimited kilometres; otherwise kilometres a day are included and each extra one is charged (1173)';
COMMENT ON COLUMN rent.rental_rate.driver_price_per_day IS 'The price of a driver a day when the car is hired with one (1173)';
ALTER TABLE rent.rental_booking ADD COLUMN IF NOT EXISTS with_driver boolean NOT NULL DEFAULT false;
ALTER TABLE rent.rental_booking ADD COLUMN IF NOT EXISTS driver_party_id bigint REFERENCES fleet.crew_profile(party_id);
ALTER TABLE rent.rental_booking DROP CONSTRAINT IF EXISTS rental_booking_driver_ck;
ALTER TABLE rent.rental_booking ADD CONSTRAINT rental_booking_driver_ck CHECK (driver_party_id IS NULL OR with_driver);
CREATE INDEX IF NOT EXISTS rental_booking_driver_party_id_fkx ON rent.rental_booking (driver_party_id);
COMMENT ON COLUMN rent.rental_booking.with_driver IS 'The car is hired with one of the company''s drivers (1173)';

CREATE OR REPLACE FUNCTION rent.tg_booking_vehicle_available() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_kind text;
BEGIN
  IF NEW.vehicle_id IS NULL OR NEW.status NOT IN ('PENDING', 'CONFIRMED', 'PICKED_UP') THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.vehicle_id IS NOT DISTINCT FROM OLD.vehicle_id AND NEW.period = OLD.period
     AND NOT (NEW.status = 'PICKED_UP' AND OLD.status <> 'PICKED_UP') THEN
    RETURN NEW;
  END IF;
  SELECT s.status INTO v_kind FROM fleet.vehicle_service_status s
   WHERE s.vehicle_id = NEW.vehicle_id AND s.status <> 'ACTIVE'
     AND s.period && (CASE WHEN NEW.status = 'PICKED_UP' THEN tstzrange(now(), upper(NEW.period)) ELSE NEW.period END)
   LIMIT 1;
  IF v_kind = 'MAINTENANCE' THEN
    RAISE EXCEPTION 'VEHICLE_IN_MAINTENANCE: the car is in the workshop for this period' USING ERRCODE = 'P0001';
  ELSIF v_kind IS NOT NULL THEN
    RAISE EXCEPTION 'VEHICLE_OUT_OF_SERVICE: the car is out of service or impounded for this period' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.with_driver AND NEW.driver_party_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.driver_party_id IS DISTINCT FROM OLD.driver_party_id)
     AND NOT EXISTS (SELECT 1 FROM fleet.crew_profile c WHERE c.party_id = NEW.driver_party_id AND c.company_id = NEW.company_id
                                                           AND c.crew_type = 'DRIVER' AND c.status = 'ACTIVE') THEN
    RAISE EXCEPTION 'DRIVER_UNKNOWN: choose an active driver of the company' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION rent.tg_booking_vehicle_available() FROM PUBLIC;
DROP TRIGGER IF EXISTS booking_vehicle_available ON rent.rental_booking;
CREATE TRIGGER booking_vehicle_available BEFORE INSERT OR UPDATE OF vehicle_id, status, period, driver_party_id ON rent.rental_booking
  FOR EACH ROW EXECUTE FUNCTION rent.tg_booking_vehicle_available();

-- a booked car is looked up in the rental fleet by its vehicle (the fleet's key is vehicle_id; 1039 looked for an id)
DROP TRIGGER IF EXISTS same_company_vehicle_id ON rent.rental_booking;
CREATE TRIGGER same_company_vehicle_id BEFORE INSERT OR UPDATE OF vehicle_id, company_id ON rent.rental_booking
  FOR EACH ROW EXECUTE FUNCTION sys.tg_same_company('vehicle_id', 'rent.rental_fleet', 'vehicle_id');

-- the odometer at pickup and return moves the car's odometer
CREATE OR REPLACE FUNCTION rent.tg_inspection_odometer() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_vehicle bigint; v_out integer;
BEGIN
  SELECT c.vehicle_id INTO v_vehicle FROM rent.rental_contract c WHERE c.id = NEW.contract_id;
  IF NEW.stage = 'RETURN' THEN
    SELECT odometer_km INTO v_out FROM rent.rental_inspection WHERE contract_id = NEW.contract_id AND stage = 'PICKUP'
     ORDER BY ts DESC LIMIT 1;
    IF v_out IS NOT NULL AND NEW.odometer_km < v_out THEN
      RAISE EXCEPTION 'ODOMETER_BACKWARDS: the odometer at return is below the one at pickup (% km)', v_out USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF v_vehicle IS NOT NULL THEN
    UPDATE fleet.vehicle SET odometer_km = greatest(coalesce(odometer_km, 0), NEW.odometer_km), odometer_at = NEW.ts WHERE id = v_vehicle;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION rent.tg_inspection_odometer() FROM PUBLIC;
DROP TRIGGER IF EXISTS inspection_odometer ON rent.rental_inspection;
CREATE TRIGGER inspection_odometer BEFORE INSERT ON rent.rental_inspection FOR EACH ROW EXECUTE FUNCTION rent.tg_inspection_odometer();

-- the kilometres of a hire and what the extra ones cost
CREATE OR REPLACE FUNCTION rent.hire_distance(p_contract bigint)
RETURNS TABLE (km_out integer, km_in integer, driven integer, days integer, allowed integer, extra integer, extra_charge bigint, unlimited boolean)
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  WITH c AS (
    SELECT c.id, b.period, r.unlimited_km, r.km_included_per_day, r.extra_km_price
      FROM rent.rental_contract c JOIN rent.rental_booking b ON b.id = c.booking_id LEFT JOIN rent.rental_rate r ON r.id = b.rate_id
     WHERE c.id = p_contract),
  o AS (
    SELECT (SELECT odometer_km FROM rent.rental_inspection WHERE contract_id = p_contract AND stage = 'PICKUP' ORDER BY ts DESC LIMIT 1) AS km_out,
           (SELECT odometer_km FROM rent.rental_inspection WHERE contract_id = p_contract AND stage = 'RETURN' ORDER BY ts DESC LIMIT 1) AS km_in),
  d AS (
    SELECT c.*, o.km_out, o.km_in, greatest(1, ceil(extract(epoch FROM upper(c.period) - lower(c.period)) / 86400))::integer AS days
      FROM c, o)
  SELECT km_out, km_in, km_in - km_out, days,
         CASE WHEN coalesce(unlimited_km, false) THEN NULL ELSE days * km_included_per_day END,
         CASE WHEN coalesce(unlimited_km, false) THEN 0 ELSE greatest(0, (km_in - km_out) - days * km_included_per_day) END,
         CASE WHEN coalesce(unlimited_km, false) THEN 0 ELSE greatest(0, (km_in - km_out) - days * km_included_per_day)::bigint * extra_km_price END,
         coalesce(unlimited_km, false)
    FROM d
$$;
COMMENT ON FUNCTION rent.hire_distance(bigint) IS 'A hire''s odometer at pickup and return, the kilometres allowed by its rate and the price of the extra ones (1173)';

-- ------------------------------------------------------------------ grants, isolation, registers
-- a company's edit history (1171) is the company's and the platform's, not every company that can see its name
SELECT sys.rls('iam.company_change', 'sys.tenant_visible(company_id)');
SELECT sys.rls('iam.company_fleet_line', 'sys.tenant_visible(company_id)', 'sys.ctx_is_platform()');
SELECT sys.rls('fleet.service_plan', 'sys.tenant_visible(company_id)');
SELECT sys.rls('fleet.maintenance_visit', 'sys.tenant_visible(company_id)');
SELECT sys.rls_parent('fleet.trailer_change', 'trailer_id', 'fleet.trailer');
GRANT SELECT, INSERT, UPDATE ON iam.company_fleet_line, fleet.service_plan, fleet.maintenance_visit TO masslak_app;
GRANT SELECT, INSERT ON fleet.trailer_change TO masslak_app;
GRANT UPDATE (change_reason) ON fleet.trailer TO masslak_app;
GRANT SELECT ON iam.company_fleet_line, fleet.service_plan, fleet.maintenance_visit, fleet.trailer_change TO masslak_readonly, masslak_auditor;
GRANT EXECUTE ON FUNCTION iam.fleet_line_open(bigint, text), fleet.service_due(fleet.service_plan, integer), rent.hire_distance(bigint) TO masslak_app;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('iam.company_fleet_line', '1A', (SELECT module FROM sys.table_phase WHERE table_name = 'iam.company')),
  ('fleet.service_plan', '1A', (SELECT module FROM sys.table_phase WHERE table_name = 'fleet.vehicle')),
  ('fleet.maintenance_visit', '1A', (SELECT module FROM sys.table_phase WHERE table_name = 'fleet.vehicle')),
  ('fleet.trailer_change', (SELECT phase_code FROM sys.table_phase WHERE table_name = 'fleet.trailer'),
                           (SELECT module FROM sys.table_phase WHERE table_name = 'fleet.trailer'))
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.company_fleet_line', 'iam records', 'the lines of business a company''s contract covers (1173)'),
  ('fleet.service_plan', 'fleet records', 'service plans of vehicles (1173)'),
  ('fleet.maintenance_visit', 'fleet records', 'workshop visits of vehicles (1173)'),
  ('fleet.trailer_change', 'fleet records', 'the history of every edit of a trailer (1173)')
ON CONFLICT (table_name) DO NOTHING;

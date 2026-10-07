-- =====================================================================
-- 1043: regulated routes and route compliance (owner decisions after the regulators' review)
--   A  Requirements switched by configuration: every licence, tracking source and reporting duty a regulator may
--      impose is registered now, each with a level (OFF, OPTIONAL, REQUIRED). The platform collects them while they
--      are optional and enforces them once their level is set to REQUIRED, without a new release.
--   B  Tracking sources: the driver's phone first; contracted tracking devices later, chosen per vehicle.
--   C  Vehicles bound to the approved line they are licensed for (the shuttle first; scheduled routes may follow).
--   D  The route obligation of a trip: an approved line, a transit corridor, a private contract's agreed route, or none.
--   E  Temporary diversions issued by the regulator, so a closed road does not raise false violations.
--   F  Route violations: the driver is warned, then alarmed continuously; reported to the authorities only when
--      reporting is required and the vehicle was in service (running a scheduled trip or carrying passengers).
--   G  Tracking, deviations and alerts move to Phase 2: the shuttle is monitored from the driver's phone.
-- =====================================================================

-- =====================================================================
-- A  Requirements switched by configuration
-- =====================================================================
CREATE TABLE IF NOT EXISTS sys.compliance_requirement (
  code          text PRIMARY KEY CHECK (code ~ '^[a-z0-9_]+(\.[a-z0-9_]+)+$'),
  domain        text NOT NULL CHECK (domain IN ('LICENSE','TRACKING','ROUTE','REPORTING','SCHOOL','ACCOUNT')),
  applies_to    text NOT NULL DEFAULT 'ALL' CHECK (applies_to IN ('ALL','SHUTTLE','SCHEDULED','TRANSIT','CONTRACT','SCHOOL')),
  subject_type  text CHECK (subject_type IN ('VEHICLE','DRIVER','PERSON','COMPANY','STATION','PARTNER','TRAILER')),
  license_type  text,                                                  -- the fleet.license_record type that satisfies it
  level         text NOT NULL DEFAULT 'OPTIONAL' CHECK (level IN ('OFF','OPTIONAL','REQUIRED')),
  required_from date,                                                  -- REQUIRED applies from this date (grace period)
  authority     text,                                                  -- who imposes it: transport authority, ministry, interior
  legal_ref     text,                                                  -- the decision or law, once issued
  description   text NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    bigint REFERENCES iam.app_user (id),
  CHECK ((domain = 'LICENSE') = (license_type IS NOT NULL AND subject_type IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS compliance_requirement_updated_by_fkx ON sys.compliance_requirement (updated_by);
COMMENT ON TABLE sys.compliance_requirement IS 'Licences, tracking and reporting duties a regulator may impose, each switched OFF, OPTIONAL or REQUIRED by configuration';
COMMENT ON COLUMN sys.compliance_requirement.level IS 'OFF: not asked; OPTIONAL: collected when given, never blocking; REQUIRED: enforced from required_from';
SELECT sys.rls_catalog('sys.compliance_requirement');
GRANT SELECT ON sys.compliance_requirement TO masslak_app, masslak_readonly;
DROP TRIGGER IF EXISTS zz_audit_capture ON sys.compliance_requirement;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON sys.compliance_requirement
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
SELECT sys.track_updates('sys.compliance_requirement');

-- Licences now cover any person (school attendants) and the licence kinds regulators issue to transport
ALTER TABLE fleet.license_record DROP CONSTRAINT IF EXISTS license_record_license_type_check;
ALTER TABLE fleet.license_record ADD CONSTRAINT license_record_license_type_check CHECK (license_type IN
  ('TRANSPORT','INSPECTION','INSURANCE','DRIVING','MEDICAL','CR','STATION','HEAVY_DRIVING','CROSS_BORDER','HAZMAT','TAXI',
   'ROUTE_PERMIT','SCHOOL_TRANSPORT','CRIMINAL_RECORD','FIRST_AID','TRACKING_DEVICE','OTHER'));
ALTER TABLE fleet.license_record DROP CONSTRAINT IF EXISTS license_record_subject_type_check;
ALTER TABLE fleet.license_record ADD CONSTRAINT license_record_subject_type_check CHECK (subject_type IN
  ('VEHICLE','TRAILER','DRIVER','PERSON','COMPANY','STATION','PARTNER'));
SELECT sys.typed_reference('fleet.license_record', 'subject_type', 'subject_id',
  '{"DRIVER":"iam.party","PERSON":"iam.party","COMPANY":"iam.company","PARTNER":"ptn.partner","STATION":"net.station",
    "TRAILER":"fleet.trailer","VEHICLE":"fleet.vehicle"}');

ALTER TABLE sys.compliance_requirement DROP CONSTRAINT IF EXISTS compliance_requirement_license_type_ck;
ALTER TABLE sys.compliance_requirement ADD CONSTRAINT compliance_requirement_license_type_ck CHECK (license_type IS NULL OR license_type IN
  ('TRANSPORT','INSPECTION','INSURANCE','DRIVING','MEDICAL','CR','STATION','HEAVY_DRIVING','CROSS_BORDER','HAZMAT','TAXI',
   'ROUTE_PERMIT','SCHOOL_TRANSPORT','CRIMINAL_RECORD','FIRST_AID','TRACKING_DEVICE','OTHER'));

CREATE OR REPLACE FUNCTION sys.requirement_enforced(p_code text, p_on date DEFAULT current_date) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT level = 'REQUIRED' AND (required_from IS NULL OR required_from <= p_on)
                     FROM sys.compliance_requirement WHERE code = p_code), false)
$$;
COMMENT ON FUNCTION sys.requirement_enforced IS 'The requirement is REQUIRED and in force on the date; unknown codes are not enforced';

CREATE OR REPLACE FUNCTION fleet.license_valid(p_subject_type text, p_subject_id bigint, p_license_type text, p_on date DEFAULT current_date)
  RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM fleet.license_record l
                  WHERE l.subject_type = p_subject_type AND l.subject_id = p_subject_id AND l.license_type = p_license_type
                    AND l.status IN ('VALID','EXPIRING') AND p_on BETWEEN l.issue_date AND l.expiry_date)
$$;
COMMENT ON FUNCTION fleet.license_valid IS 'The subject holds a verified licence of the type that is in force on the date';

-- Requirements of a domain that a subject does not meet; empty while they are optional
CREATE OR REPLACE FUNCTION sys.unmet_requirements(p_applies_to text, p_subject_type text, p_subject_id bigint, p_on date DEFAULT current_date)
  RETURNS SETOF text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT r.code FROM sys.compliance_requirement r
   WHERE r.domain = 'LICENSE' AND r.subject_type = p_subject_type AND r.applies_to IN ('ALL', p_applies_to)
     AND sys.requirement_enforced(r.code, p_on)
     AND NOT fleet.license_valid(p_subject_type, p_subject_id, r.license_type, p_on)
   ORDER BY r.code
$$;
COMMENT ON FUNCTION sys.unmet_requirements IS 'Required licences the subject lacks for a service; the API shows them and activation refuses them';
REVOKE EXECUTE ON FUNCTION sys.unmet_requirements(text, text, bigint, date), fleet.license_valid(text, bigint, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.unmet_requirements(text, text, bigint, date), fleet.license_valid(text, bigint, text, date),
  sys.requirement_enforced(text, date) TO masslak_app, masslak_readonly;

-- Everything prepared, nothing imposed yet: only the binding of shuttle vehicles to their line is required (owner
-- decision: the shuttle is monitored on approved lines from its first phase). Raising a level is a configuration change.
INSERT INTO sys.compliance_requirement (code, domain, applies_to, subject_type, license_type, level, authority, description) VALUES
  ('route.vehicle_binding.shuttle',   'ROUTE',     'SHUTTLE',   NULL, NULL, 'REQUIRED', 'Transport authority',
   'A shuttle trip runs only with a vehicle bound to the approved line under the carrier''s permit'),
  ('route.vehicle_binding.scheduled', 'ROUTE',     'SCHEDULED', NULL, NULL, 'OPTIONAL', 'Transport authority',
   'A scheduled trip on a route the regulator bound to an approved line runs only with a vehicle bound to that line'),
  ('route.adherence.shuttle',         'ROUTE',     'SHUTTLE',   NULL, NULL, 'REQUIRED', 'Transport authority',
   'Shuttle trips are checked against the approved line and the driver is warned on leaving it'),
  ('route.adherence.scheduled',       'ROUTE',     'SCHEDULED', NULL, NULL, 'OPTIONAL', 'Transport authority',
   'Scheduled trips on regulated routes are checked against the approved line'),
  ('route.report.authority',          'REPORTING', 'ALL',       NULL, NULL, 'OFF', 'Transport authority, interior',
   'Confirmed violations of vehicles in service are reported electronically to the authorities'),
  ('tracking.driver_app',             'TRACKING',  'ALL',       NULL, NULL, 'OPTIONAL', 'Transport authority',
   'Trips are tracked from the driver''s phone while the trip runs'),
  ('tracking.gps_device',             'TRACKING',  'ALL',       NULL, NULL, 'OFF', 'Transport authority, interior',
   'Vehicles carry a contracted tracking device'),
  ('license.company.cr',              'LICENSE',   'ALL',       'COMPANY', 'CR',               'OPTIONAL', 'Ministry of internal trade', 'Commercial registration of the company'),
  ('license.company.transport',       'LICENSE',   'ALL',       'COMPANY', 'TRANSPORT',        'OPTIONAL', 'Transport authority', 'Licence to operate passenger transport'),
  ('license.vehicle.transport',       'LICENSE',   'ALL',       'VEHICLE', 'TRANSPORT',        'OPTIONAL', 'Transport authority', 'Vehicle operating licence'),
  ('license.vehicle.inspection',      'LICENSE',   'ALL',       'VEHICLE', 'INSPECTION',       'OPTIONAL', 'Traffic police', 'Periodic technical inspection'),
  ('license.vehicle.insurance',       'LICENSE',   'ALL',       'VEHICLE', 'INSURANCE',        'OPTIONAL', 'Insurer', 'Passenger insurance of the vehicle'),
  ('license.vehicle.route_permit',    'LICENSE',   'SHUTTLE',   'VEHICLE', 'ROUTE_PERMIT',     'OPTIONAL', 'Transport authority', 'The vehicle''s permit for its line'),
  ('license.vehicle.tracking_device', 'LICENSE',   'ALL',       'VEHICLE', 'TRACKING_DEVICE',  'OFF',      'Transport authority', 'Certificate of the installed tracking device'),
  ('license.driver.driving',          'LICENSE',   'ALL',       'DRIVER',  'DRIVING',          'OPTIONAL', 'Traffic police', 'Driving licence of the class the vehicle needs'),
  ('license.driver.medical',          'LICENSE',   'ALL',       'DRIVER',  'MEDICAL',          'OPTIONAL', 'Ministry of health', 'Medical fitness certificate'),
  ('license.driver.criminal_record',  'LICENSE',   'ALL',       'DRIVER',  'CRIMINAL_RECORD',  'OPTIONAL', 'Ministry of interior', 'Criminal record certificate'),
  ('license.company.school_transport','LICENSE',   'SCHOOL',    'COMPANY', 'SCHOOL_TRANSPORT', 'OPTIONAL', 'Ministry of education, transport authority', 'Licence to operate school transport'),
  ('license.vehicle.school_transport','LICENSE',   'SCHOOL',    'VEHICLE', 'SCHOOL_TRANSPORT', 'OPTIONAL', 'Transport authority', 'The vehicle is approved for school transport'),
  ('license.driver.school_transport', 'LICENSE',   'SCHOOL',    'DRIVER',  'SCHOOL_TRANSPORT', 'OPTIONAL', 'Transport authority', 'The driver is approved for school transport'),
  ('license.driver.first_aid',        'LICENSE',   'SCHOOL',    'DRIVER',  'FIRST_AID',        'OPTIONAL', 'Ministry of health', 'First aid training'),
  ('license.person.criminal_record',  'LICENSE',   'SCHOOL',    'PERSON',  'CRIMINAL_RECORD',  'OPTIONAL', 'Ministry of interior', 'Criminal record certificate of the school bus attendant'),
  ('license.person.first_aid',        'LICENSE',   'SCHOOL',    'PERSON',  'FIRST_AID',        'OPTIONAL', 'Ministry of health', 'First aid training of the school bus attendant')
ON CONFLICT (code) DO NOTHING;

-- =====================================================================
-- B  Tracking sources: the driver's phone, contracted devices later
-- =====================================================================
ALTER TABLE fleet.vehicle ADD COLUMN IF NOT EXISTS tracking_source text NOT NULL DEFAULT 'DRIVER_APP';
DO $$ BEGIN
  ALTER TABLE fleet.vehicle ADD CONSTRAINT vehicle_tracking_source_ck CHECK (tracking_source IN ('DRIVER_APP','GPS_DEVICE','BOTH'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN fleet.vehicle.tracking_source IS 'Where route compliance reads positions from: the driver''s phone, a contracted device, or both';

CREATE TABLE IF NOT EXISTS fleet.tracking_device (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint NOT NULL REFERENCES iam.company (id),
  vehicle_id    bigint NOT NULL REFERENCES fleet.vehicle (id),
  provider      text NOT NULL,                                       -- the contracted tracking provider
  serial_no     text NOT NULL,
  protocol      text NOT NULL DEFAULT 'API' CHECK (protocol IN ('API','MQTT','TCP','SMS')),
  certificate_no text,                                               -- regulator approval of the device, when required
  installed     daterange NOT NULL,
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('PENDING','ACTIVE','FAULTY','REMOVED')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, serial_no),
  EXCLUDE USING gist (vehicle_id WITH =, installed WITH &&) WHERE (status IN ('PENDING','ACTIVE'))
);
CREATE INDEX IF NOT EXISTS tracking_device_company_id_fkx ON fleet.tracking_device (company_id);
CREATE INDEX IF NOT EXISTS tracking_device_vehicle_id_fkx ON fleet.tracking_device (vehicle_id);
COMMENT ON TABLE fleet.tracking_device IS 'A contracted tracking device installed in a vehicle; one active device per vehicle at a time';
SELECT sys.rls_tenant('fleet.tracking_device');
SELECT sys.grant_rw(ARRAY['fleet.tracking_device']);
DROP TRIGGER IF EXISTS vehicle_of_company ON fleet.tracking_device;
CREATE TRIGGER vehicle_of_company BEFORE INSERT OR UPDATE OF vehicle_id, company_id ON fleet.tracking_device
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_vehicle_of_company('vehicle_id');

-- =====================================================================
-- C  Vehicles bound to the approved line of their permit
-- =====================================================================
CREATE TABLE IF NOT EXISTS fleet.line_permit_vehicle (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  permit_id   bigint NOT NULL REFERENCES net.line_permit (id),
  company_id  bigint NOT NULL REFERENCES iam.company (id),             -- the permit's company
  vehicle_id  bigint NOT NULL REFERENCES fleet.vehicle (id),
  valid       daterange NOT NULL,
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','REMOVED')),
  approved_by bigint REFERENCES iam.app_user (id),                     -- the regulator or platform officer who bound it
  created_at  timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (vehicle_id WITH =, valid WITH &&) WHERE (status = 'ACTIVE')
);
CREATE INDEX IF NOT EXISTS line_permit_vehicle_permit_id_fkx ON fleet.line_permit_vehicle (permit_id);
CREATE INDEX IF NOT EXISTS line_permit_vehicle_company_id_fkx ON fleet.line_permit_vehicle (company_id);
CREATE INDEX IF NOT EXISTS line_permit_vehicle_vehicle_id_fkx ON fleet.line_permit_vehicle (vehicle_id);
CREATE INDEX IF NOT EXISTS line_permit_vehicle_approved_by_fkx ON fleet.line_permit_vehicle (approved_by);
COMMENT ON TABLE fleet.line_permit_vehicle IS 'The vehicles a permit binds to its approved line; a vehicle serves one line at a time, and may still run scheduled trips';
SELECT sys.rls_tenant('fleet.line_permit_vehicle');
SELECT sys.grant_rw(ARRAY['fleet.line_permit_vehicle']);
DROP TRIGGER IF EXISTS zz_audit_capture ON fleet.line_permit_vehicle;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON fleet.line_permit_vehicle
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS vehicle_of_company ON fleet.line_permit_vehicle;
CREATE TRIGGER vehicle_of_company BEFORE INSERT OR UPDATE OF vehicle_id, company_id ON fleet.line_permit_vehicle
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_vehicle_of_company('vehicle_id');
DROP TRIGGER IF EXISTS same_company_permit_id ON fleet.line_permit_vehicle;
CREATE TRIGGER same_company_permit_id BEFORE INSERT OR UPDATE OF permit_id, company_id ON fleet.line_permit_vehicle
  FOR EACH ROW EXECUTE FUNCTION sys.tg_same_company('permit_id', 'net.line_permit');

-- The binding lies within an active permit and keeps to its vehicle limit
CREATE OR REPLACE FUNCTION fleet.tg_permit_vehicle_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p record; n int;
BEGIN
  IF NEW.status <> 'ACTIVE' THEN RETURN NEW; END IF;
  SELECT * INTO p FROM net.line_permit WHERE id = NEW.permit_id;
  IF p.status <> 'ACTIVE' OR NOT (p.valid @> NEW.valid) THEN
    RAISE EXCEPTION 'PERMIT_NOT_ACTIVE: the binding must lie within an active permit of the line' USING ERRCODE = 'P0001';
  END IF;
  IF p.max_vehicles IS NOT NULL THEN
    SELECT count(*) INTO n FROM fleet.line_permit_vehicle
     WHERE permit_id = NEW.permit_id AND status = 'ACTIVE' AND valid && NEW.valid AND id IS DISTINCT FROM NEW.id;
    IF n >= p.max_vehicles THEN
      RAISE EXCEPTION 'PERMIT_VEHICLE_LIMIT: the permit allows % vehicles on the line', p.max_vehicles USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
-- named to fire after the ownership guard (triggers fire in name order)
DROP TRIGGER IF EXISTS vehicle_permit_rules ON fleet.line_permit_vehicle;
CREATE TRIGGER vehicle_permit_rules BEFORE INSERT OR UPDATE ON fleet.line_permit_vehicle
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_permit_vehicle_rules();

CREATE OR REPLACE FUNCTION net.vehicle_bound_to_line(p_vehicle bigint, p_line bigint, p_company bigint, p_on date)
  RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM fleet.line_permit_vehicle b JOIN net.line_permit p ON p.id = b.permit_id
                  WHERE b.vehicle_id = p_vehicle AND p.line_id = p_line AND p.company_id = p_company
                    AND b.status = 'ACTIVE' AND p.status = 'ACTIVE' AND b.valid @> p_on)
$$;
COMMENT ON FUNCTION net.vehicle_bound_to_line IS 'The vehicle is bound to the line under an active permit of the company on the date';
GRANT EXECUTE ON FUNCTION net.vehicle_bound_to_line(bigint, bigint, bigint, date) TO masslak_app, masslak_readonly;

-- A carrier route may be one the regulator imposes: it then follows an approved line (optional readiness column)
ALTER TABLE net.route ADD COLUMN IF NOT EXISTS line_id bigint REFERENCES net.line (id);
CREATE INDEX IF NOT EXISTS route_line_id_fkx ON net.route (line_id);
COMMENT ON COLUMN net.route.line_id IS 'The approved line the regulator imposes on this route; its trips must follow the line (Phase 2)';

-- =====================================================================
-- D  The route obligation of a trip
-- =====================================================================
ALTER TABLE ops.trip ADD COLUMN IF NOT EXISTS compliance_source text NOT NULL DEFAULT 'NONE';
DO $$ BEGIN
  ALTER TABLE ops.trip ADD CONSTRAINT trip_compliance_source_ck CHECK (
    compliance_source IN ('NONE','REGULATED_LINE','TRANSIT_CORRIDOR','CONTRACT')
    AND (compliance_source <> 'REGULATED_LINE' OR line_version_id IS NOT NULL)
    AND (compliance_source <> 'TRANSIT_CORRIDOR' OR corridor_id IS NOT NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN ops.trip.compliance_source IS 'The route the trip must keep to: an approved line, a transit corridor, the agreed route of a private contract (which exempts it from the regulated line), or none';

-- The obligation follows the trip's references; a vehicle on a regulated line must be bound to it while that is required
CREATE OR REPLACE FUNCTION ops.tg_trip_route_obligation() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE l record; rule text;
BEGIN
  IF NEW.compliance_source <> 'CONTRACT' THEN
    NEW.compliance_source := CASE WHEN NEW.line_version_id IS NOT NULL THEN 'REGULATED_LINE'
                                  WHEN NEW.corridor_id IS NOT NULL THEN 'TRANSIT_CORRIDOR' ELSE 'NONE' END;
  END IF;
  IF NEW.compliance_source = 'REGULATED_LINE' AND NEW.vehicle_id IS NOT NULL AND NEW.status <> 'CANCELLED' THEN
    SELECT ln.id, ln.kind INTO l FROM net.line_version v JOIN net.line ln ON ln.id = v.line_id WHERE v.id = NEW.line_version_id;
    rule := CASE WHEN l.kind = 'SHUTTLE' THEN 'route.vehicle_binding.shuttle' ELSE 'route.vehicle_binding.scheduled' END;
    IF sys.requirement_enforced(rule, (NEW.departure_at AT TIME ZONE 'UTC')::date)
       AND NOT net.vehicle_bound_to_line(NEW.vehicle_id, l.id, NEW.company_id, (NEW.departure_at AT TIME ZONE 'UTC')::date) THEN
      RAISE EXCEPTION 'VEHICLE_NOT_BOUND_TO_LINE: the vehicle is not bound to the approved line under an active permit (%)', rule
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trip_route_obligation ON ops.trip;
CREATE TRIGGER trip_route_obligation BEFORE INSERT OR UPDATE OF line_version_id, corridor_id, compliance_source, vehicle_id, status, departure_at
  ON ops.trip FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_route_obligation();

-- =====================================================================
-- E  Temporary diversions issued by the regulator
-- =====================================================================
CREATE TABLE IF NOT EXISTS net.line_diversion (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id      bigint NOT NULL REFERENCES net.line (id),
  active       tstzrange NOT NULL,
  geometry     jsonb NOT NULL,                                        -- GeoJSON LineString of the detour
  corridor_m   int NOT NULL DEFAULT 150 CHECK (corridor_m BETWEEN 20 AND 5000),
  reason       text NOT NULL CHECK (reason IN ('ROAD_CLOSED','WORKS','EVENT','EMERGENCY','SECURITY','OTHER')),
  issued_by    text NOT NULL,                                         -- the authority that ordered it
  reference_no text,
  approved_by  bigint REFERENCES iam.app_user (id),
  status       text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','CANCELLED')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT isempty(active) AND NOT upper_inf(active))
);
CREATE INDEX IF NOT EXISTS line_diversion_line_id_fkx ON net.line_diversion (line_id);
CREATE INDEX IF NOT EXISTS line_diversion_approved_by_fkx ON net.line_diversion (approved_by);
COMMENT ON TABLE net.line_diversion IS 'A temporary detour of an approved line; trips keeping to it raise no violation';
SELECT sys.rls_catalog('net.line_diversion');
GRANT SELECT ON net.line_diversion TO masslak_app, masslak_readonly;
DROP TRIGGER IF EXISTS zz_audit_capture ON net.line_diversion;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON net.line_diversion
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- =====================================================================
-- F  Route violations and reports to the authorities
-- =====================================================================
CREATE TABLE IF NOT EXISTS ops.route_violation (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id          bigint NOT NULL REFERENCES iam.company (id),
  vehicle_id          bigint NOT NULL REFERENCES fleet.vehicle (id),
  trip_id             bigint REFERENCES ops.trip (id),                 -- none when the vehicle was off duty
  driver_party_id     bigint REFERENCES iam.party (id),
  compliance_source   text NOT NULL CHECK (compliance_source IN ('REGULATED_LINE','TRANSIT_CORRIDOR','CONTRACT')),
  line_version_id     bigint REFERENCES net.line_version (id),
  kind                text NOT NULL CHECK (kind IN ('OFF_ROUTE','MISSED_STOP','UNSCHEDULED_STOP','TRACKING_OFF','SPEEDING')),
  tracking_source     text NOT NULL CHECK (tracking_source IN ('DRIVER_APP','GPS_DEVICE')),
  started_at          timestamptz NOT NULL,
  ended_at            timestamptz,
  max_distance_m      int CHECK (max_distance_m >= 0),
  in_service          boolean NOT NULL,                                -- running a scheduled trip or carrying passengers
  carrying_passengers boolean NOT NULL DEFAULT false,
  driver_warned_at    timestamptz,                                     -- first notice in the driver app
  alarm_started_at    timestamptz,                                     -- continuous sound alarm after the grace period
  corrected_at        timestamptz,                                     -- back on the route
  status              text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CORRECTED','CONFIRMED','JUSTIFIED','REPORTED','APPEALED','CLOSED')),
  justification       text CHECK (justification IN ('DIVERSION','ROAD_CLOSED','EMERGENCY','POLICE_ORDER','BREAKDOWN','MAINTENANCE','OTHER')),
  diversion_id        bigint REFERENCES net.line_diversion (id),
  reviewed_by         bigint REFERENCES iam.app_user (id),
  evidence            jsonb NOT NULL DEFAULT '{}',                     -- track segment, speeds and timestamps at detection
  retain_until        date NOT NULL DEFAULT (current_date + 730),      -- legal evidence outlives the 7-day position retention
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (ended_at IS NULL OR ended_at >= started_at),
  CHECK ((status = 'JUSTIFIED') = (justification IS NOT NULL)),
  CHECK (compliance_source <> 'REGULATED_LINE' OR line_version_id IS NOT NULL),
  CHECK (alarm_started_at IS NULL OR driver_warned_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS route_violation_company_idx ON ops.route_violation (company_id, status, started_at);
CREATE INDEX IF NOT EXISTS route_violation_vehicle_id_fkx ON ops.route_violation (vehicle_id, started_at);
CREATE INDEX IF NOT EXISTS route_violation_trip_id_fkx ON ops.route_violation (trip_id);
CREATE INDEX IF NOT EXISTS route_violation_driver_party_id_fkx ON ops.route_violation (driver_party_id);
CREATE INDEX IF NOT EXISTS route_violation_line_version_id_fkx ON ops.route_violation (line_version_id);
CREATE INDEX IF NOT EXISTS route_violation_diversion_id_fkx ON ops.route_violation (diversion_id);
CREATE INDEX IF NOT EXISTS route_violation_reviewed_by_fkx ON ops.route_violation (reviewed_by);
COMMENT ON TABLE ops.route_violation IS 'A deviation from the route the trip must keep to: warning, continuous alarm, correction, review and reporting';
COMMENT ON COLUMN ops.route_violation.in_service IS 'Only violations in service (a scheduled trip running or passengers on board) are reportable; off-duty and maintenance moves are not';
SELECT sys.rls_tenant('ops.route_violation');
SELECT sys.grant_rw(ARRAY['ops.route_violation']);
SELECT sys.track_updates('ops.route_violation');
DROP TRIGGER IF EXISTS zz_audit_capture ON ops.route_violation;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON ops.route_violation
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS vehicle_of_company ON ops.route_violation;
CREATE TRIGGER vehicle_of_company BEFORE INSERT OR UPDATE OF vehicle_id, company_id ON ops.route_violation
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_vehicle_of_company('vehicle_id');
DROP TRIGGER IF EXISTS same_company_trip_id ON ops.route_violation;
CREATE TRIGGER same_company_trip_id BEFORE INSERT OR UPDATE OF trip_id, company_id ON ops.route_violation
  FOR EACH ROW EXECUTE FUNCTION sys.tg_same_company('trip_id', 'ops.trip');

-- In service unless proven otherwise: a trip that is boarding or under way counts, whatever the caller says;
-- the evidence is frozen once the violation leaves OPEN
CREATE OR REPLACE FUNCTION ops.tg_route_violation_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.trip_id IS NOT NULL AND EXISTS (SELECT 1 FROM ops.trip WHERE id = NEW.trip_id AND status IN ('BOARDING','DEPARTED')) THEN
    NEW.in_service := true;
  END IF;
  IF NEW.carrying_passengers THEN NEW.in_service := true; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status <> 'OPEN' AND (NEW.evidence IS DISTINCT FROM OLD.evidence OR NEW.started_at <> OLD.started_at
       OR NEW.vehicle_id <> OLD.vehicle_id OR NEW.trip_id IS DISTINCT FROM OLD.trip_id OR NEW.kind <> OLD.kind) THEN
    RAISE EXCEPTION 'VIOLATION_EVIDENCE_FROZEN: the evidence of a reviewed violation cannot change' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'REPORTED' AND NOT NEW.in_service THEN
    RAISE EXCEPTION 'NOT_REPORTABLE: the vehicle was not in service (no running trip, no passengers)' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS route_violation_rules ON ops.route_violation;
CREATE TRIGGER route_violation_rules BEFORE INSERT OR UPDATE ON ops.route_violation
  FOR EACH ROW EXECUTE FUNCTION ops.tg_route_violation_rules();

CREATE OR REPLACE FUNCTION ops.violation_reportable(p_violation bigint) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT sys.requirement_enforced('route.report.authority', (v.started_at AT TIME ZONE 'UTC')::date)
         AND v.in_service AND v.status IN ('CONFIRMED','REPORTED')
    FROM ops.route_violation v WHERE v.id = p_violation
$$;
COMMENT ON FUNCTION ops.violation_reportable IS 'Reporting is required by the regulator, the vehicle was in service and the violation is confirmed';
GRANT EXECUTE ON FUNCTION ops.violation_reportable(bigint) TO masslak_app, masslak_readonly;

CREATE TABLE IF NOT EXISTS ops.violation_report (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  violation_id  bigint NOT NULL REFERENCES ops.route_violation (id),
  authority     text NOT NULL CHECK (authority IN ('TRANSPORT_AUTHORITY','TRANSPORT_MINISTRY','INTERIOR','TRAFFIC_POLICE','SECURITY')),
  channel       text NOT NULL CHECK (channel IN ('API','EMAIL','PORTAL','SMS')),
  status        text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','ACKNOWLEDGED','FAILED')),
  external_ref  text,
  sent_at       timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (violation_id, authority)
);
COMMENT ON TABLE ops.violation_report IS 'A violation sent to an authority over the channel it imposed; delivered through the outbox';
SELECT sys.rls_parent('ops.violation_report', 'violation_id', 'ops.route_violation');
SELECT sys.grant_rw(ARRAY['ops.violation_report']);
DROP TRIGGER IF EXISTS zz_audit_capture ON ops.violation_report;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON ops.violation_report
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

CREATE OR REPLACE FUNCTION ops.tg_violation_report_allowed() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT coalesce(ops.violation_reportable(NEW.violation_id), false) THEN
    RAISE EXCEPTION 'NOT_REPORTABLE: reporting is not required yet, or the violation is unconfirmed or was off duty' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS violation_report_allowed ON ops.violation_report;
CREATE TRIGGER violation_report_allowed BEFORE INSERT ON ops.violation_report
  FOR EACH ROW EXECUTE FUNCTION ops.tg_violation_report_allowed();

-- Detection and escalation thresholds, changed by configuration
INSERT INTO sys.setting (key, value, description) VALUES
  ('route.adherence', '{"confirm_points": 3, "confirm_seconds": 30, "min_accuracy_m": 50, "warn_after_seconds": 30,
                        "alarm_after_seconds": 120, "alarm_repeat_seconds": 15, "speed_limit_kmh": {"SHUTTLE": 60, "SCHEDULED": 100}}',
   'Off-route detection: points and seconds outside the corridor before a warning, then the continuous alarm'),
  ('route.report_channels', '{}', 'Electronic channel per authority once reporting is required, e.g. {"TRAFFIC_POLICE": "API"}'),
  ('retention.violation_evidence_days', '730', 'How long route violation evidence is kept')
ON CONFLICT (key) DO NOTHING;
UPDATE sys.setting SET value = value || '{"route_compliance": false}'::jsonb
 WHERE key = 'features' AND NOT value ? 'route_compliance';

-- =====================================================================
-- G  Phase map: route compliance belongs to the shuttle phase
-- =====================================================================
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('sys.compliance_requirement', '1A', 'E04'), ('fleet.tracking_device', '2', 'E05'), ('fleet.line_permit_vehicle', '2', 'E05'),
  ('net.line_diversion', '2', 'E05'), ('ops.route_violation', '2', 'E05'), ('ops.violation_report', '2', 'E05')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
-- The shuttle is monitored from the driver's phone in its first phase, so positions, deviations and alerts come with it
UPDATE sys.table_phase SET phase_code = '2'
 WHERE table_name IN ('ops.geo_event','ops.route_adherence_event','ops.tracking_alert');
UPDATE sys.project_phase SET scope = scope || '; route compliance: vehicles bound to their approved line, deviations detected '
       || 'from the driver''s phone, warning and continuous alarm, violations, diversions, and reporting once the regulator requires it'
 WHERE code = '2' AND scope NOT LIKE '%route compliance%';

INSERT INTO sys.schema_migration (version, description)
SELECT '1.25.0', 'Route compliance: configurable requirements, tracking sources, vehicle binding, violations and reporting'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.25.0');

SELECT sys.refresh_table_class();

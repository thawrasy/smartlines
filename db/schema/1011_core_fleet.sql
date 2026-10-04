-- =====================================================================
-- 1011: core and fleet additions (study 4.3, 4.17, 7.10 c, 10.4, 13.14 e, 16.8)
--   Crew profiles for hosts and heavy-class drivers, driving hours, vehicle service status (blocks assignment),
--   insurance claims, authority alerts, truck units, trailers and their combinations, boarding validators,
--   fuel consumption profiles and the device permission state of the driver and passenger apps.
-- =====================================================================

-- ------------------------------ crew (4.3, 10.4) ------------------------------
ALTER TABLE fleet.crew_profile ADD COLUMN IF NOT EXISTS job_title text;
ALTER TABLE fleet.crew_profile ADD COLUMN IF NOT EXISTS certificate_no text;          -- hosts and assistants
ALTER TABLE fleet.crew_profile ADD COLUMN IF NOT EXISTS heavy_class boolean NOT NULL DEFAULT false;
ALTER TABLE fleet.crew_profile ADD COLUMN IF NOT EXISTS cross_border boolean NOT NULL DEFAULT false;
ALTER TABLE fleet.crew_profile ADD COLUMN IF NOT EXISTS hazmat_certified boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN fleet.crew_profile.heavy_class IS 'Holds a heavy-vehicle licence (10.4); the licence itself is a fleet.license_record';

-- Licence types for heavy transport and taxis; trailers carry their own licence documents
ALTER TABLE fleet.license_record DROP CONSTRAINT IF EXISTS license_record_license_type_check;
ALTER TABLE fleet.license_record ADD CONSTRAINT license_record_license_type_check CHECK (license_type IN
  ('TRANSPORT','INSPECTION','INSURANCE','DRIVING','MEDICAL','CR','STATION','HEAVY_DRIVING','CROSS_BORDER','HAZMAT','TAXI','OTHER'));
ALTER TABLE fleet.license_record DROP CONSTRAINT IF EXISTS license_record_subject_type_check;
ALTER TABLE fleet.license_record ADD CONSTRAINT license_record_subject_type_check CHECK (subject_type IN
  ('VEHICLE','TRAILER','DRIVER','COMPANY','STATION','PARTNER'));

CREATE TABLE IF NOT EXISTS fleet.driving_hours_log (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint NOT NULL REFERENCES iam.company(id),
  party_id      bigint NOT NULL REFERENCES fleet.crew_profile(party_id),
  trip_id       bigint REFERENCES ops.trip(id),
  kind          text NOT NULL CHECK (kind IN ('DRIVING','REST','OTHER_WORK')),
  started_at    timestamptz NOT NULL,
  ended_at      timestamptz,
  source        text NOT NULL DEFAULT 'APP' CHECK (source IN ('APP','TACHOGRAPH','MANUAL')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (ended_at IS NULL OR ended_at > started_at)
);
CREATE INDEX IF NOT EXISTS driving_hours_party_idx ON fleet.driving_hours_log (party_id, started_at);
COMMENT ON TABLE fleet.driving_hours_log IS 'Driving and rest periods per driver (10.4); feeds the rest-time rules';

-- ------------------------------ vehicle continuity (7.10 c) ------------------------------
CREATE TABLE IF NOT EXISTS fleet.vehicle_service_status (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id           bigint NOT NULL REFERENCES iam.company(id),
  vehicle_id           bigint NOT NULL REFERENCES fleet.vehicle(id),
  status               text NOT NULL CHECK (status IN ('ACTIVE','OUT_OF_SERVICE','IMPOUNDED')),
  reason               text NOT NULL,
  incident_id          bigint REFERENCES ops.incident(id),
  period               tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  released_by          bigint REFERENCES iam.app_user(id),
  release_evidence_id  bigint REFERENCES ref.file_object(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (vehicle_id WITH =, period WITH &&)
);
COMMENT ON TABLE fleet.vehicle_service_status IS 'Out-of-service and impound periods; a vehicle in such a period cannot be assigned (7.10 c)';

CREATE TABLE IF NOT EXISTS fleet.insurance_claim (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id   bigint NOT NULL REFERENCES iam.company(id),
  incident_id  bigint NOT NULL REFERENCES ops.incident(id),
  policy_id    bigint NOT NULL REFERENCES fleet.insurance_policy(id),
  insurer_ref  text,
  amount       bigint CHECK (amount >= 0),
  currency     char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status       text NOT NULL DEFAULT 'NOTIFIED' CHECK (status IN ('NOTIFIED','UNDER_REVIEW','ACCEPTED','REJECTED','PAID','CLOSED')),
  last_sync_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (incident_id, policy_id)
);
COMMENT ON TABLE fleet.insurance_claim IS 'Claim notified to the insurer for an incident (7.10 c)';

CREATE TABLE IF NOT EXISTS sec.authority_alert (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id        bigint REFERENCES fleet.vehicle(id),
  trip_id           bigint REFERENCES ops.trip(id),
  authority_id      bigint REFERENCES sec.authority_profile(id),
  alert_type        text NOT NULL CHECK (alert_type IN ('EXPIRED_OPERATING','UNREGISTERED_TRIP','EXPIRED_LICENSE','OTHER')),
  evidence_file_id  bigint REFERENCES ref.file_object(id),
  sent_to_authority boolean NOT NULL DEFAULT false,
  sent_at           timestamptz,
  response_ref      text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (vehicle_id IS NOT NULL OR trip_id IS NOT NULL)
);
COMMENT ON TABLE sec.authority_alert IS 'Notifications to the regulator: a vehicle operating with an expired licence or an unregistered trip (4.16 g)';

-- ------------------------------ trucks and trailers (10.4) ------------------------------
CREATE TABLE IF NOT EXISTS fleet.truck_unit (
  vehicle_id                 bigint PRIMARY KEY REFERENCES fleet.vehicle(id) ON DELETE CASCADE,
  axle_config                text NOT NULL,                   -- e.g. 4x2, 6x4
  gvw_kg                     int NOT NULL CHECK (gvw_kg > 0),
  tare_kg                    int NOT NULL CHECK (tare_kg > 0),
  fuel_type                  text NOT NULL DEFAULT 'DIESEL' CHECK (fuel_type IN ('DIESEL','GASOLINE','LNG','CNG','ELECTRIC','HYBRID')),
  gps_device_ref             text,
  hazmat_certified           boolean NOT NULL DEFAULT false,
  cross_border_permit_no     text,
  cross_border_permit_expiry date,
  CHECK (gvw_kg > tare_kg)
);
COMMENT ON TABLE fleet.truck_unit IS 'Truck extension of fleet.vehicle (vehicle_class TRUCK); plate, chassis, ownership and licences stay on the vehicle (10.4, 4.17)';

CREATE TABLE IF NOT EXISTS fleet.trailer (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id          bigint NOT NULL REFERENCES iam.company(id),
  ownership_type      text NOT NULL DEFAULT 'OWNED' CHECK (ownership_type IN ('OWNED','LEASED')),
  owner_party_id      bigint REFERENCES iam.party(id),
  plate_no            text NOT NULL,
  plate_country       char(2) NOT NULL DEFAULT 'SY' REFERENCES ref.country(code),
  chassis_no          text,
  trailer_type        text NOT NULL CHECK (trailer_type IN ('FLATBED','CURTAIN','REEFER','TANKER','CONTAINER_CHASSIS','LOWBED','TIPPER','BOX')),
  payload_kg          int NOT NULL CHECK (payload_kg > 0),
  volume_m3           numeric(8,2),
  length_m            numeric(5,2),
  axles               smallint CHECK (axles BETWEEN 1 AND 8),
  container_capacity  smallint CHECK (container_capacity IN (20, 40)),
  temp_min_c          numeric(4,1),
  temp_max_c          numeric(4,1),
  status              text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('PENDING','ACTIVE','BLOCKED','RETIRED')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plate_country, plate_no),
  CHECK (ownership_type = 'OWNED' OR owner_party_id IS NOT NULL),
  CHECK (temp_min_c IS NULL OR temp_max_c IS NULL OR temp_min_c <= temp_max_c)
);
COMMENT ON TABLE fleet.trailer IS 'Trailers with their own plate and licence documents (10.4)';

CREATE TABLE IF NOT EXISTS fleet.truck_combination (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id       bigint NOT NULL REFERENCES iam.company(id),
  truck_vehicle_id bigint NOT NULL REFERENCES fleet.truck_unit(vehicle_id),
  trailer_id       bigint REFERENCES fleet.trailer(id),
  driver_party_id  bigint REFERENCES fleet.crew_profile(party_id),
  period           tstzrange NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (truck_vehicle_id WITH =, period WITH &&),
  EXCLUDE USING gist (trailer_id WITH =, period WITH &&)
);
COMMENT ON TABLE fleet.truck_combination IS 'Truck, trailer and driver coupled for a period; trailers can be swapped without overlap (10.4)';

-- ------------------------------ boarding validators (7.6 e) ------------------------------
CREATE TABLE IF NOT EXISTS fleet.boarding_validator (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id         bigint NOT NULL REFERENCES iam.company(id),
  device_serial      text NOT NULL UNIQUE,
  vehicle_id         bigint REFERENCES fleet.vehicle(id),
  validator_type     text NOT NULL CHECK (validator_type IN ('QR','NFC','BOTH')),
  firmware           text,
  deny_list_version  int NOT NULL DEFAULT 0,
  last_sync_at       timestamptz,
  status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','OFFLINE','RETIRED')),
  created_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE fleet.boarding_validator IS 'Gate device on the vehicle that validates QR codes and NFC cards offline';

-- ------------------------------ fuel profile (14.11 f) ------------------------------
CREATE TABLE IF NOT EXISTS fleet.vehicle_fuel_profile (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id            bigint REFERENCES iam.company(id),                -- empty for a platform default by class
  vehicle_id            bigint UNIQUE REFERENCES fleet.vehicle(id),
  vehicle_class         text REFERENCES ref.vehicle_class(code),
  tank_capacity_l       numeric(7,1) NOT NULL CHECK (tank_capacity_l > 0),
  expected_l_per_100km  numeric(5,1) NOT NULL CHECK (expected_l_per_100km > 0),
  tolerance_pct         numeric(4,1) NOT NULL DEFAULT 15 CHECK (tolerance_pct BETWEEN 0 AND 100),
  CHECK ((vehicle_id IS NULL) <> (vehicle_class IS NULL))
);
COMMENT ON TABLE fleet.vehicle_fuel_profile IS 'Expected consumption and tolerance, per vehicle or per class, for fuel anomaly checks (14.11 f)';

-- ------------------------------ device permission state (7.13 d) ------------------------------
CREATE TABLE IF NOT EXISTS iam.device_permission_state (
  device_id            bigint PRIMARY KEY REFERENCES iam.device(id) ON DELETE CASCADE,
  user_id              bigint NOT NULL REFERENCES iam.app_user(id),
  location_permission  text NOT NULL CHECK (location_permission IN ('ALWAYS','WHILE_IN_USE','DENIED')),
  location_services_on boolean NOT NULL,
  bluetooth_on         boolean NOT NULL,
  nearby_permission    boolean NOT NULL,
  app_version          text,
  updated_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE iam.device_permission_state IS 'Current location and Nearby permissions per device; a change writes ops.permission_event';

-- ------------------------------ isolation and privileges ------------------------------
DO $$ BEGIN
  PERFORM sys.rls_tenant(t) FROM unnest(ARRAY['fleet.driving_hours_log','fleet.vehicle_service_status','fleet.insurance_claim',
    'fleet.trailer','fleet.truck_combination','fleet.boarding_validator']) t;
  PERFORM sys.rls_parent('fleet.truck_unit', 'vehicle_id', 'fleet.vehicle');
  PERFORM sys.rls('fleet.vehicle_fuel_profile', 'company_id IS NULL OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
  PERFORM sys.rls_platform('sec.authority_alert');
  PERFORM sys.rls('iam.device_permission_state', 'sys.ctx_is_platform() OR sys.is_me(user_id)');
  PERFORM sys.grant_rw(ARRAY['fleet.driving_hours_log','fleet.vehicle_service_status','fleet.insurance_claim','sec.authority_alert',
    'fleet.truck_unit','fleet.trailer','fleet.truck_combination','fleet.boarding_validator','fleet.vehicle_fuel_profile',
    'iam.device_permission_state']);
END $$;
GRANT SELECT ON sec.authority_alert TO masslak_auditor;

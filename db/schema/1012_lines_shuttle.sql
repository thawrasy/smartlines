-- =====================================================================
-- 1012: approved lines, tariffs and route adherence (study 4.15), shuttle rides charged station by station
--       through presence and proximity (7.13), and shuttle subscriptions and passes (4.10, phase 2)
-- =====================================================================

-- ------------------------------ the line catalog (4.15) ------------------------------
CREATE TABLE IF NOT EXISTS net.line (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid          uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  code         text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9-]{2,30}$'),
  name         text NOT NULL,                                      -- English; translations in ref.translation
  kind         text NOT NULL CHECK (kind IN ('SHUTTLE','INTERCITY','INTERNATIONAL')),
  fare_regime  text NOT NULL CHECK (fare_regime IN ('REGULATED','BANDED','FREE')),
  city_id      bigint REFERENCES ref.city(id),                     -- shuttle lines run inside one city
  status       text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','SUSPENDED','RETIRED')),
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE net.line IS 'The official line approved by the regulator (4.15); carriers operate it under a permit';

CREATE TABLE IF NOT EXISTS net.line_version (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id        bigint NOT NULL REFERENCES net.line(id),
  version        int NOT NULL CHECK (version >= 1),
  geometry       jsonb NOT NULL,                                  -- GeoJSON LineString
  corridor_m     int NOT NULL DEFAULT 150 CHECK (corridor_m BETWEEN 20 AND 5000),
  distance_km    numeric(7,2) NOT NULL CHECK (distance_km > 0),
  typical_min    int NOT NULL CHECK (typical_min > 0),
  effective_from date,
  status         text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PENDING_APPROVAL','APPROVED','ACTIVE','RETIRED')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (line_id, version)
);
CREATE UNIQUE INDEX IF NOT EXISTS line_version_one_active ON net.line_version (line_id) WHERE status = 'ACTIVE';
COMMENT ON TABLE net.line_version IS 'A version of the line with its route; trips keep the version they were generated from';

CREATE TABLE IF NOT EXISTS net.line_version_approval (
  line_version_id bigint NOT NULL REFERENCES net.line_version(id) ON DELETE CASCADE,
  user_id         bigint NOT NULL REFERENCES iam.app_user(id),
  role            text NOT NULL CHECK (role IN ('PLATFORM','REGULATOR')),
  approved_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (line_version_id, user_id)
);
COMMENT ON TABLE net.line_version_approval IS 'Four-eyes approval of a line version (approved_by[] in 4.15), one row per approver';

CREATE TABLE IF NOT EXISTS net.line_stop (
  line_version_id bigint NOT NULL REFERENCES net.line_version(id) ON DELETE CASCADE,
  seq             smallint NOT NULL CHECK (seq >= 1),
  station_id      bigint NOT NULL REFERENCES net.station(id),
  mandatory       boolean NOT NULL DEFAULT true,
  geofence_m      int NOT NULL DEFAULT 60 CHECK (geofence_m BETWEEN 10 AND 2000),
  arr_offset_min  int CHECK (arr_offset_min >= 0),
  dep_offset_min  int CHECK (dep_offset_min >= 0),
  PRIMARY KEY (line_version_id, seq),
  UNIQUE (line_version_id, station_id)
);

CREATE TABLE IF NOT EXISTS net.line_permit (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id        bigint NOT NULL REFERENCES net.line(id),
  company_id     bigint NOT NULL REFERENCES iam.company(id),
  valid          daterange NOT NULL,
  max_vehicles   int CHECK (max_vehicles > 0),
  max_trips_day  int CHECK (max_trips_day > 0),
  permit_no      text,
  status         text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','EXPIRED','REVOKED')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (line_id WITH =, company_id WITH =, valid WITH &&)
);
COMMENT ON TABLE net.line_permit IS 'A carrier''s permit to operate a line, with its vehicle and daily-trip limits';

CREATE TABLE IF NOT EXISTS net.line_tariff (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id      bigint NOT NULL REFERENCES net.line(id),
  version      int NOT NULL CHECK (version >= 1),
  regime       text NOT NULL CHECK (regime IN ('REGULATED','BANDED','FREE')),
  mode         text NOT NULL CHECK (mode IN ('SEGMENT','BAND','FLAT','DISTANCE')),
  currency     char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  valid_from   date NOT NULL,
  status       text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED','ACTIVE','RETIRED')),
  approved_by  bigint REFERENCES iam.app_user(id),
  approved_at  timestamptz,
  UNIQUE (line_id, version)
);
COMMENT ON TABLE net.line_tariff IS 'Versioned tariff of a line (4.15); the mode decides how ops.shuttle_ride is charged (7.13)';

CREATE TABLE IF NOT EXISTS net.line_fare (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tariff_id          bigint NOT NULL REFERENCES net.line_tariff(id) ON DELETE CASCADE,
  from_station_id    bigint REFERENCES net.station(id),
  to_station_id      bigint REFERENCES net.station(id),
  passenger_category text NOT NULL DEFAULT 'ADULT' CHECK (passenger_category IN ('ADULT','STUDENT','SENIOR','CHILD','DISABLED')),
  fare               bigint NOT NULL CHECK (fare >= 0),
  band_to_seq        smallint,                                     -- BAND mode: the band ends at this stop
  per_km             bigint CHECK (per_km >= 0),                   -- DISTANCE mode
  UNIQUE NULLS NOT DISTINCT (tariff_id, from_station_id, to_station_id, passenger_category)
);
COMMENT ON TABLE net.line_fare IS 'Fare rows of a tariff (line_fare and line_fare_table in the study): pair, band, flat or per kilometre';

CREATE TABLE IF NOT EXISTS net.timetable_template (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id      bigint NOT NULL REFERENCES net.line(id),
  company_id   bigint NOT NULL REFERENCES iam.company(id),
  kind         text NOT NULL CHECK (kind IN ('FIXED','HEADWAY')),
  days         smallint[] NOT NULL DEFAULT '{1,2,3,4,5,6,7}',     -- ISO weekdays
  times        time[],                                            -- FIXED
  headway_min  int CHECK (headway_min BETWEEN 1 AND 240),         -- HEADWAY
  window_from  time,
  window_to    time,
  valid        daterange NOT NULL,
  status       text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  CHECK ((kind = 'FIXED' AND times IS NOT NULL) OR (kind = 'HEADWAY' AND headway_min IS NOT NULL AND window_from < window_to))
);
COMMENT ON TABLE net.timetable_template IS 'Shuttle timetable: fixed times or a headway within a window';

ALTER TABLE ops.trip ADD COLUMN IF NOT EXISTS line_version_id bigint REFERENCES net.line_version(id);
ALTER TABLE ops.trip ADD COLUMN IF NOT EXISTS timetable_slot time;
ALTER TABLE ops.trip ADD COLUMN IF NOT EXISTS fare_regime text;
DO $$ BEGIN
  ALTER TABLE ops.trip ADD CONSTRAINT trip_fare_regime_ck CHECK (fare_regime IS NULL OR fare_regime IN ('REGULATED','BANDED','FREE'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN ops.trip.line_version_id IS 'Snapshot of the approved line the trip was generated from (4.15)';

CREATE TABLE IF NOT EXISTS ops.route_adherence_event (
  id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id   bigint NOT NULL REFERENCES ops.trip(id),
  kind      text NOT NULL CHECK (kind IN ('OFF_ROUTE','MISSED_STOP','UNSCHEDULED_STOP','BACK_ON_ROUTE')),
  ts        timestamptz NOT NULL,
  lat       numeric(9,6),
  lng       numeric(9,6),
  detail    jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS route_adherence_trip_idx ON ops.route_adherence_event (trip_id, ts);
COMMENT ON TABLE ops.route_adherence_event IS 'Deviations from the line version measured by tracking; append-only';

-- ------------------------------ shuttle rides (7.13) ------------------------------
CREATE TABLE IF NOT EXISTS ops.presence_beacon (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id      bigint NOT NULL REFERENCES ops.trip(id),
  vehicle_id   bigint REFERENCES fleet.vehicle(id),
  source       text NOT NULL CHECK (source IN ('DRIVER_PHONE','VEHICLE_BEACON')),
  key_id       text NOT NULL,                                     -- signing key reference, never the key
  rotation_sec int NOT NULL DEFAULT 30 CHECK (rotation_sec BETWEEN 5 AND 600),
  active       tstzrange NOT NULL,
  EXCLUDE USING gist (trip_id WITH =, source WITH =, active WITH &&)
);
COMMENT ON TABLE ops.presence_beacon IS 'Rotating signed presence tokens per trip that passengers'' phones detect over Nearby';

CREATE TABLE IF NOT EXISTS ops.shuttle_ride (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  user_id             bigint NOT NULL REFERENCES iam.app_user(id),
  wallet_id           bigint NOT NULL REFERENCES fin.wallet(id),
  trip_id             bigint NOT NULL REFERENCES ops.trip(id),
  line_id             bigint NOT NULL REFERENCES net.line(id),
  tariff_id           bigint REFERENCES net.line_tariff(id),
  boarding_event_id   bigint REFERENCES sales.boarding_event(id),
  board_station_id    bigint NOT NULL REFERENCES net.station(id),
  board_ts            timestamptz NOT NULL,
  alight_station_id   bigint REFERENCES net.station(id),
  alight_ts           timestamptz,
  alight_method       text CHECK (alight_method IN ('PROXIMITY_LOST','STATION_QR','MANUAL','TRIP_END','LOCK_MAX_FARE')),
  companions          smallint NOT NULL DEFAULT 0 CHECK (companions BETWEEN 0 AND 9),
  charged_amount      bigint NOT NULL DEFAULT 0 CHECK (charged_amount >= 0),
  outstanding_amount  bigint NOT NULL DEFAULT 0 CHECK (outstanding_amount >= 0),
  currency            char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  last_charged_seq    smallint,
  counts_in_capacity  boolean NOT NULL DEFAULT true,
  status              text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED','REVIEW','DISPUTED')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (alight_ts IS NULL OR alight_ts >= board_ts)
);
CREATE UNIQUE INDEX IF NOT EXISTS shuttle_ride_one_open ON ops.shuttle_ride (user_id) WHERE status = 'OPEN';
CREATE INDEX IF NOT EXISTS shuttle_ride_trip_idx ON ops.shuttle_ride (trip_id);
COMMENT ON TABLE ops.shuttle_ride IS 'One open ride per user, charged stop by stop until alighting (7.13)';

CREATE TABLE IF NOT EXISTS ops.ride_segment_charge (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ride_id        bigint NOT NULL REFERENCES ops.shuttle_ride(id),
  seq_from       smallint NOT NULL,
  seq_to         smallint NOT NULL,
  amount         bigint NOT NULL CHECK (amount >= 0),
  kind           text NOT NULL CHECK (kind IN ('BOARDING','CONTINUATION','BAND_REMAINDER','LOCK')),
  ledger_txn_id  bigint REFERENCES fin.ledger_txn(id),
  ts             timestamptz NOT NULL DEFAULT now(),
  CHECK (seq_to > seq_from)
);
CREATE INDEX IF NOT EXISTS ride_charge_ride_idx ON ops.ride_segment_charge (ride_id);
COMMENT ON TABLE ops.ride_segment_charge IS 'One row per deduction: the receipt lines of a shuttle ride; append-only';

CREATE TABLE IF NOT EXISTS ops.proximity_sample (
  ride_id        bigint NOT NULL REFERENCES ops.shuttle_ride(id) ON DELETE CASCADE,
  ts             timestamptz NOT NULL,
  rssi           smallint,
  est_distance_m numeric(6,1),
  co_moving      boolean,
  source         text NOT NULL CHECK (source IN ('NEARBY','BLE','GPS')),
  PRIMARY KEY (ride_id, ts)
);
COMMENT ON TABLE ops.proximity_sample IS 'Proximity samples between passenger and vehicle; deleted after the retention period (16.13)';

CREATE TABLE IF NOT EXISTS ops.permission_event (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES iam.app_user(id),
  device_id  bigint REFERENCES iam.device(id),
  trip_id    bigint REFERENCES ops.trip(id),
  kind       text NOT NULL CHECK (kind IN ('LOCATION_OFF','PERMISSION_REVOKED','BLUETOOTH_OFF','RESTORED')),
  ts         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS permission_event_trip_idx ON ops.permission_event (trip_id, ts);
COMMENT ON TABLE ops.permission_event IS 'Lock and restore log of app permissions; feeds ops.tracking_alert for drivers; append-only';

-- ------------------------------ subscriptions and passes (4.10, phase 2) ------------------------------
CREATE TABLE IF NOT EXISTS sales.shuttle_zone (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  city_id     bigint NOT NULL REFERENCES ref.city(id),
  polygon     jsonb NOT NULL,                                      -- GeoJSON Polygon
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED'))
);
COMMENT ON TABLE sales.shuttle_zone IS 'Fare zone for zone-based shuttle subscriptions';

CREATE TABLE IF NOT EXISTS sales.subscription_plan (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id   bigint REFERENCES iam.company(id),                  -- empty: a platform plan valid on all carriers
  code         text NOT NULL,
  name         text NOT NULL,
  line_id      bigint REFERENCES net.line(id),
  zone_id      bigint REFERENCES sales.shuttle_zone(id),
  period_days  smallint NOT NULL CHECK (period_days BETWEEN 1 AND 366),
  rides_limit  int CHECK (rides_limit > 0),                        -- empty: unlimited
  passenger_category text NOT NULL DEFAULT 'ADULT' CHECK (passenger_category IN ('ADULT','STUDENT','SENIOR','CHILD','DISABLED')),
  price        bigint NOT NULL CHECK (price >= 0),
  currency     char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status       text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  UNIQUE NULLS NOT DISTINCT (company_id, code)
);

CREATE TABLE IF NOT EXISTS sales.subscription (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid            uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  plan_id        bigint NOT NULL REFERENCES sales.subscription_plan(id),
  company_id     bigint REFERENCES iam.company(id),                -- copied from the plan for isolation
  party_id       bigint NOT NULL REFERENCES iam.party(id),
  wallet_id      bigint REFERENCES fin.wallet(id),
  starts_on      date NOT NULL,
  ends_on        date NOT NULL,
  rides_used     int NOT NULL DEFAULT 0 CHECK (rides_used >= 0),
  price_paid     bigint NOT NULL CHECK (price_paid >= 0),
  currency       char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  ledger_txn_id  bigint REFERENCES fin.ledger_txn(id),
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('PENDING','ACTIVE','EXPIRED','CANCELLED')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_on >= starts_on)
);

CREATE TABLE IF NOT EXISTS sales.nfc_card (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  card_uid_hash  bytea NOT NULL UNIQUE,                            -- never the raw card UID
  wallet_id      bigint REFERENCES fin.wallet(id),
  party_id       bigint REFERENCES iam.party(id),
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','BLOCKED','LOST','RETIRED')),
  issued_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sales.nfc_card IS 'Prepaid card linked to a wallet; validators keep a deny list of blocked cards (7.6 e)';

CREATE TABLE IF NOT EXISTS sales.shuttle_pass (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subscription_id  bigint NOT NULL REFERENCES sales.subscription(id) ON DELETE CASCADE,
  pass_no          text NOT NULL UNIQUE,
  medium           text NOT NULL CHECK (medium IN ('QR','NFC')),
  nfc_card_id      bigint REFERENCES sales.nfc_card(id),
  qr_key_id        text,
  status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','REVOKED','EXPIRED')),
  CHECK (medium = 'QR' OR nfc_card_id IS NOT NULL)
);
COMMENT ON TABLE sales.shuttle_pass IS 'The pass carried by the subscriber: a signed QR or an NFC card';

-- ------------------------------ isolation and privileges ------------------------------
DO $$ BEGIN
  PERFORM sys.rls_catalog(t) FROM unnest(ARRAY['net.line','net.line_version','net.line_version_approval','net.line_stop',
    'net.line_tariff','net.line_fare','sales.shuttle_zone']) t;
  PERFORM sys.rls_split('net.line_permit', 'sys.tenant_visible(company_id) OR status = ''ACTIVE''', 'sys.ctx_is_platform()');
  PERFORM sys.rls_split('net.timetable_template', 'status = ''ACTIVE'' OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
  PERFORM sys.rls_trip(t) FROM unnest(ARRAY['ops.route_adherence_event','ops.presence_beacon']) t;
  PERFORM sys.rls_trip('ops.shuttle_ride', 'sys.is_me(user_id)');
  PERFORM sys.rls_parent(t, 'ride_id', 'ops.shuttle_ride') FROM unnest(ARRAY['ops.ride_segment_charge','ops.proximity_sample']) t;
  PERFORM sys.rls_trip('ops.permission_event', 'sys.is_me(user_id)');
  PERFORM sys.rls_split('sales.subscription_plan', 'status = ''ACTIVE'' OR company_id IS NULL OR sys.tenant_visible(company_id)',
    'CASE WHEN company_id IS NULL THEN sys.ctx_is_platform() ELSE sys.tenant_visible(company_id) END');
  PERFORM sys.rls('sales.subscription', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id) OR party_id = sys.ctx_party_id()');
  PERFORM sys.rls('sales.nfc_card', 'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()');
  PERFORM sys.rls_parent('sales.shuttle_pass', 'subscription_id', 'sales.subscription');
  PERFORM sys.grant_rw(ARRAY['net.line','net.line_version','net.line_version_approval','net.line_stop','net.line_permit',
    'net.line_tariff','net.line_fare','net.timetable_template','ops.presence_beacon','ops.shuttle_ride','sales.shuttle_zone',
    'sales.subscription_plan','sales.subscription','sales.nfc_card','sales.shuttle_pass']);
  PERFORM sys.grant_append(ARRAY['ops.route_adherence_event','ops.ride_segment_charge','ops.permission_event']);
  -- samples are deleted by the retention job, so they are not append-only
  PERFORM sys.grant_rw(ARRAY['ops.proximity_sample']);
END $$;

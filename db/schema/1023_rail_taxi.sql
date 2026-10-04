-- =====================================================================
-- 1023: rail extension (phase 10, 4.10, 14.8) and taxis within and between cities (phase 11, 21.1)
--   Rail reuses trips (transport_mode TRAIN), stations, seat layouts and pricing; it adds fare classes, coach
--   layouts, the train composition of a trip and connected journeys. Taxis reuse parties, vehicles and
--   ownership, the driver app, geo_event tracking, the wallet and the regulated tariff.
-- =====================================================================

-- ------------------------------ rail ------------------------------
CREATE TABLE IF NOT EXISTS rail.fare_class (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint NOT NULL REFERENCES iam.company(id),
  code        text NOT NULL,
  name        text NOT NULL,
  cabin_rank  smallint NOT NULL DEFAULT 2 CHECK (cabin_rank BETWEEN 1 AND 5),      -- 1 = first class
  refundable  boolean NOT NULL DEFAULT true,
  changeable  boolean NOT NULL DEFAULT true,
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED')),
  UNIQUE (company_id, code)
);

CREATE TABLE IF NOT EXISTS rail.coach_layout (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id      bigint NOT NULL REFERENCES iam.company(id),
  code            text NOT NULL,
  coach_type      text NOT NULL CHECK (coach_type IN ('SEATED','SLEEPER','COUCHETTE','DINING','BAGGAGE')),
  seat_layout_id  bigint REFERENCES fleet.seat_layout(id),
  berths          smallint CHECK (berths >= 0),
  fare_class_id   bigint REFERENCES rail.fare_class(id),
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED')),
  UNIQUE (company_id, code),
  CHECK (coach_type IN ('DINING','BAGGAGE') OR seat_layout_id IS NOT NULL OR berths IS NOT NULL)
);
COMMENT ON TABLE rail.coach_layout IS 'A coach type built on the seat layout model (4.13)';

CREATE TABLE IF NOT EXISTS rail.train_composition (
  trip_id          bigint NOT NULL REFERENCES ops.trip(id) ON DELETE CASCADE,
  position         smallint NOT NULL CHECK (position >= 1),
  coach_no         text NOT NULL,
  coach_layout_id  bigint NOT NULL REFERENCES rail.coach_layout(id),
  PRIMARY KEY (trip_id, position),
  UNIQUE (trip_id, coach_no)
);
COMMENT ON TABLE rail.train_composition IS 'Coaches of a train trip in order; seats are addressed as coach number plus seat';

CREATE TABLE IF NOT EXISTS rail.journey (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  party_id           bigint NOT NULL REFERENCES iam.party(id),
  origin_station_id  bigint NOT NULL REFERENCES net.station(id),
  dest_station_id    bigint NOT NULL REFERENCES net.station(id),
  status             text NOT NULL DEFAULT 'BOOKED' CHECK (status IN ('BOOKED','IN_PROGRESS','COMPLETED','DISRUPTED','CANCELLED')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (origin_station_id <> dest_station_id)
);
CREATE TABLE IF NOT EXISTS rail.journey_leg (
  journey_id          bigint NOT NULL REFERENCES rail.journey(id) ON DELETE CASCADE,
  seq                 smallint NOT NULL CHECK (seq >= 1),
  ticket_id           bigint NOT NULL UNIQUE REFERENCES sales.ticket(id),
  trip_id             bigint NOT NULL REFERENCES ops.trip(id),
  min_connection_min  smallint NOT NULL DEFAULT 15 CHECK (min_connection_min >= 0),
  PRIMARY KEY (journey_id, seq)
);
COMMENT ON TABLE rail.journey IS 'Connected journey: several tickets on connecting trips sold and protected as one (phase 10)';

-- ------------------------------ taxi ------------------------------
CREATE TABLE IF NOT EXISTS taxi.taxi_office (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint NOT NULL UNIQUE REFERENCES iam.company(id),
  city_id     bigint NOT NULL REFERENCES ref.city(id),
  license_no  text,
  status      text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','CLOSED'))
);

CREATE TABLE IF NOT EXISTS taxi.taxi_permit (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  permit_no       text NOT NULL UNIQUE,
  vehicle_id      bigint NOT NULL REFERENCES fleet.vehicle(id),
  company_id      bigint NOT NULL REFERENCES iam.company(id),           -- the office, or the owner-driver's company record
  office_id       bigint REFERENCES taxi.taxi_office(id),
  city_id         bigint NOT NULL REFERENCES ref.city(id),
  scope           text NOT NULL DEFAULT 'INTRACITY' CHECK (scope IN ('INTRACITY','INTERCITY','BOTH')),
  gps_required    boolean NOT NULL DEFAULT false,
  valid           daterange NOT NULL,
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','EXPIRED','REVOKED')),
  EXCLUDE USING gist (vehicle_id WITH =, valid WITH &&) WHERE (status IN ('PENDING','ACTIVE'))
);
COMMENT ON TABLE taxi.taxi_permit IS 'Taxi licence of a car; ownership and the owner stay on fleet.vehicle (4.17)';

CREATE TABLE IF NOT EXISTS taxi.meter_tariff (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  city_id       bigint NOT NULL REFERENCES ref.city(id),
  version       int NOT NULL CHECK (version >= 1),
  flag_fall     bigint NOT NULL CHECK (flag_fall >= 0),
  per_km        bigint NOT NULL CHECK (per_km >= 0),
  per_wait_min  bigint NOT NULL DEFAULT 0,
  night_factor  numeric(4,2) NOT NULL DEFAULT 1.0 CHECK (night_factor >= 1),
  min_fare      bigint NOT NULL DEFAULT 0,
  currency      char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  valid         daterange NOT NULL,
  status        text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED','ACTIVE','RETIRED')),
  approved_by   bigint REFERENCES iam.app_user(id),
  UNIQUE (city_id, version)
);
COMMENT ON TABLE taxi.meter_tariff IS 'Regulated meter tariff per city (4.15, 2.5)';

CREATE TABLE IF NOT EXISTS taxi.taxi_shift (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  permit_id        bigint NOT NULL REFERENCES taxi.taxi_permit(id),
  vehicle_id       bigint NOT NULL REFERENCES fleet.vehicle(id),
  driver_party_id  bigint NOT NULL REFERENCES fleet.crew_profile(party_id),
  period           tstzrange NOT NULL,
  status           text NOT NULL DEFAULT 'ON' CHECK (status IN ('ON','PAUSED','ENDED')),
  EXCLUDE USING gist (vehicle_id WITH =, period WITH &&),
  EXCLUDE USING gist (driver_party_id WITH =, period WITH &&)
);
COMMENT ON TABLE taxi.taxi_shift IS 'A driver on a car for a shift; tracking runs only inside a shift (privacy, 21.1)';

CREATE TABLE IF NOT EXISTS taxi.ride_request (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid            uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  rider_user_id  bigint NOT NULL REFERENCES iam.app_user(id),
  kind           text NOT NULL CHECK (kind IN ('INSTANT','ADVANCE','SHARED_SEAT')),
  city_id        bigint NOT NULL REFERENCES ref.city(id),
  pickup_lat     numeric(9,6) NOT NULL,
  pickup_lng     numeric(9,6) NOT NULL,
  pickup_text    text,
  dropoff_lat    numeric(9,6),
  dropoff_lng    numeric(9,6),
  dropoff_text   text,
  requested_for  timestamptz NOT NULL DEFAULT now(),
  seats          smallint NOT NULL DEFAULT 1 CHECK (seats BETWEEN 1 AND 7),
  fare_estimate  bigint,
  currency       char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status         text NOT NULL DEFAULT 'SEARCHING' CHECK (status IN ('SEARCHING','ASSIGNED','CANCELLED','EXPIRED','COMPLETED')),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS taxi.dispatch_offer (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  request_id    bigint NOT NULL REFERENCES taxi.ride_request(id),
  shift_id      bigint NOT NULL REFERENCES taxi.taxi_shift(id),
  distance_m    int,
  offered_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  response      text CHECK (response IN ('ACCEPTED','DECLINED','TIMEOUT')),
  responded_at  timestamptz,
  UNIQUE (request_id, shift_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS dispatch_one_accepted ON taxi.dispatch_offer (request_id) WHERE response = 'ACCEPTED';

CREATE TABLE IF NOT EXISTS taxi.ride (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  request_id      bigint UNIQUE REFERENCES taxi.ride_request(id),      -- empty for a street hail
  shift_id        bigint NOT NULL REFERENCES taxi.taxi_shift(id),
  rider_user_id   bigint REFERENCES iam.app_user(id),
  trip_id         bigint REFERENCES ops.trip(id),                       -- intercity shared taxi sold by seat (4.12)
  tariff_id       bigint REFERENCES taxi.meter_tariff(id),
  fare_mode       text NOT NULL CHECK (fare_mode IN ('METER','FIXED')),
  started_at      timestamptz,
  ended_at        timestamptz,
  distance_km     numeric(7,2),
  wait_min        int,
  fare            bigint CHECK (fare >= 0),
  currency        char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  payment_method  text CHECK (payment_method IN ('CASH','WALLET','QR')),
  ledger_txn_id   bigint REFERENCES fin.ledger_txn(id),
  share_token     text UNIQUE,                                          -- trip sharing link for safety
  status          text NOT NULL DEFAULT 'ARRIVING' CHECK (status IN ('ARRIVING','ON_TRIP','COMPLETED','CANCELLED','DISPUTED')),
  CHECK (fare_mode <> 'METER' OR tariff_id IS NOT NULL),
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);
COMMENT ON TABLE taxi.ride IS 'A taxi ride from a request or a street hail, metered or at a fixed price';

-- ------------------------------ isolation and privileges ------------------------------
CREATE OR REPLACE FUNCTION taxi.can_see_shift(p_shift_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM taxi.taxi_shift s JOIN taxi.taxi_permit p ON p.id = s.permit_id
    WHERE s.id = p_shift_id AND p.company_id = sys.ctx_company_id())
$$;
DO $$ BEGIN
  PERFORM sys.rls_split(t, 'true', 'sys.tenant_visible(company_id)') FROM unnest(ARRAY['rail.fare_class','rail.coach_layout']) t;
  PERFORM sys.rls_split('rail.train_composition', 'true',
    'EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = train_composition.trip_id AND sys.tenant_visible(x.company_id))');
  PERFORM sys.rls('rail.journey', 'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()
    OR EXISTS (SELECT 1 FROM rail.journey_leg l JOIN sales.ticket t ON t.id = l.ticket_id JOIN sales.booking b ON b.id = t.booking_id
               WHERE l.journey_id = journey.id AND sys.tenant_visible(b.company_id))',
    'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()');
  PERFORM sys.rls('rail.journey_leg', 'EXISTS (SELECT 1 FROM sales.ticket t JOIN sales.booking b ON b.id = t.booking_id
    WHERE t.id = journey_leg.ticket_id AND (sys.tenant_visible(b.company_id) OR b.booker_party_id = sys.ctx_party_id()))');
  PERFORM sys.rls_split('taxi.taxi_office', 'true', 'sys.tenant_visible(company_id)');
  PERFORM sys.rls_split('taxi.taxi_permit', 'sys.tenant_visible(company_id) OR status = ''ACTIVE''', 'sys.ctx_is_platform()');
  PERFORM sys.rls_catalog('taxi.meter_tariff');
  PERFORM sys.rls('taxi.taxi_shift', 'EXISTS (SELECT 1 FROM taxi.taxi_permit p WHERE p.id = taxi_shift.permit_id AND sys.tenant_visible(p.company_id))');
  PERFORM sys.rls('taxi.ride_request', 'sys.ctx_is_platform() OR sys.is_me(rider_user_id)
    OR (status = ''SEARCHING'' AND sys.ctx_company_id() IS NOT NULL)', 'sys.ctx_is_platform() OR sys.is_me(rider_user_id)');
  PERFORM sys.rls('taxi.dispatch_offer', 'taxi.can_see_shift(shift_id)');
  PERFORM sys.rls('taxi.ride', 'taxi.can_see_shift(shift_id) OR sys.is_me(rider_user_id)');
  PERFORM sys.grant_rw(ARRAY['rail.fare_class','rail.coach_layout','rail.train_composition','rail.journey','rail.journey_leg',
    'taxi.taxi_office','taxi.taxi_permit','taxi.meter_tariff','taxi.taxi_shift','taxi.ride_request','taxi.dispatch_offer','taxi.ride']);
END $$;

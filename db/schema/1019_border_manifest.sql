-- =====================================================================
-- 1019: border manifest gateway (study 11, phases 4 and 6) with the transit fields of appendix D.1.8
--   Border points extend border stations, crossing profiles hold each authority's required fields without code
--   changes, and a manifest is a versioned snapshot per trip and crossing with persons, vehicles and cargo.
--   Authority decisions and reconciliation results come back as responses and discrepancies.
--   The transit head-count reconciliation of D.1.8 is ops.transit_reconciliation (file 1003).
-- =====================================================================

CREATE TABLE IF NOT EXISTS brd.border_point (
  station_id              bigint PRIMARY KEY REFERENCES net.station(id),      -- station subtype BORDER
  point_type              text NOT NULL CHECK (point_type IN ('LAND','SEA','AIR')),
  country_code            char(2) NOT NULL REFERENCES ref.country(code),      -- the side this point belongs to
  counterpart_station_id  bigint REFERENCES brd.border_point(station_id),     -- the facing point across the border
  authority_id            bigint REFERENCES sec.authority_profile(id),
  hours                   jsonb NOT NULL DEFAULT '{}',
  status                  text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CLOSED','RESTRICTED')),
  CHECK (counterpart_station_id IS NULL OR counterpart_station_id <> station_id)
);
COMMENT ON TABLE brd.border_point IS 'Border crossing point; extends a station of subtype BORDER (11.6)';

CREATE OR REPLACE FUNCTION brd.tg_border_point_is_border() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM net.station WHERE id = NEW.station_id AND subtype = 'BORDER') THEN
    RAISE EXCEPTION 'NOT_A_BORDER_POINT: station % is not of subtype BORDER', NEW.station_id USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS border_point_is_border ON brd.border_point;
CREATE TRIGGER border_point_is_border BEFORE INSERT OR UPDATE ON brd.border_point
  FOR EACH ROW EXECUTE FUNCTION brd.tg_border_point_is_border();

CREATE TABLE IF NOT EXISTS brd.crossing_profile (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  border_point_id  bigint NOT NULL REFERENCES brd.border_point(station_id),
  authority_id     bigint NOT NULL REFERENCES sec.authority_profile(id),
  required_fields  jsonb NOT NULL,
  lead_time_min    int NOT NULL DEFAULT 60 CHECK (lead_time_min >= 0),       -- submit at least this long before arrival
  schema_version   text NOT NULL,
  formats          text[] NOT NULL DEFAULT '{JSON}',                          -- JSON, XML, CSV, UN/EDIFACT PAXLST
  fail_policy      text NOT NULL DEFAULT 'BLOCK' CHECK (fail_policy IN ('BLOCK','ALLOW_PENDING','MANUAL')),
  valid            daterange NOT NULL DEFAULT daterange(current_date, NULL),
  status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  UNIQUE (border_point_id, authority_id, schema_version)
);
COMMENT ON TABLE brd.crossing_profile IS 'What each authority requires at a crossing; changed by configuration, not code';

CREATE TABLE IF NOT EXISTS brd.manifest (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  trip_id           bigint NOT NULL REFERENCES ops.trip(id),
  crossing_plan_id  bigint REFERENCES ops.trip_crossing_plan(id),
  border_point_id   bigint NOT NULL REFERENCES brd.border_point(station_id),
  profile_id        bigint REFERENCES brd.crossing_profile(id),
  version           int NOT NULL DEFAULT 1 CHECK (version >= 1),
  manifest_type     text NOT NULL CHECK (manifest_type IN ('PRE_DEPARTURE','PRE_ARRIVAL','FINAL','AMENDMENT')),
  content_type      text NOT NULL DEFAULT 'PASSENGER' CHECK (content_type IN ('PASSENGER','CARGO','MIXED')),
  submission_id     bigint REFERENCES sec.manifest_submission(id),
  status            text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','CLOSED','SUBMITTED','ACKNOWLEDGED','REJECTED','SUPERSEDED')),
  closed_at         timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (trip_id, border_point_id, version)
);
COMMENT ON TABLE brd.manifest IS 'Manifest header: a versioned snapshot per trip and border point (11.6)';

CREATE TABLE IF NOT EXISTS brd.manifest_person (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  manifest_id           bigint NOT NULL REFERENCES brd.manifest(id) ON DELETE CASCADE,
  person_role           text NOT NULL CHECK (person_role IN ('PASSENGER','CREW')),
  ticket_id             bigint REFERENCES sales.ticket(id),
  crew_party_id         bigint REFERENCES iam.party(id),
  doc_type              text NOT NULL CHECK (doc_type IN ('PASSPORT','NATIONAL_ID','TRAVEL_DOCUMENT','LAISSEZ_PASSER')),
  doc_no_enc            bytea NOT NULL,
  doc_no_bidx           bytea NOT NULL,
  enc_key_id            int NOT NULL REFERENCES sec.key_registry(id),
  issuing_country       char(2) NOT NULL REFERENCES ref.country(code),
  doc_expiry            date,
  nationality           char(2) NOT NULL REFERENCES ref.country(code),
  birth_date            date NOT NULL,
  sex                   char(1) CHECK (sex IN ('M','F','X')),
  embark_station_id     bigint REFERENCES net.station(id),
  disembark_station_id  bigint REFERENCES net.station(id),
  visa_ref              text,
  passenger_category    text CHECK (passenger_category IN ('DEPARTING','ARRIVING','TRANSIT','DOMESTIC')),    -- D.1.5
  syria_entry_point_id  bigint REFERENCES brd.border_point(station_id),                                     -- D.1.8
  syria_exit_point_id   bigint REFERENCES brd.border_point(station_id),
  CHECK ((person_role = 'PASSENGER' AND ticket_id IS NOT NULL) OR (person_role = 'CREW' AND crew_party_id IS NOT NULL)),
  CHECK (passenger_category IS DISTINCT FROM 'TRANSIT' OR (syria_entry_point_id IS NOT NULL AND syria_exit_point_id IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS manifest_person_ticket ON brd.manifest_person (manifest_id, ticket_id) WHERE ticket_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS manifest_person_crew ON brd.manifest_person (manifest_id, crew_party_id) WHERE crew_party_id IS NOT NULL;
COMMENT ON TABLE brd.manifest_person IS 'Snapshot of a passenger or crew member; transit passengers carry their Syrian entry and exit points (D.1.8)';

CREATE TABLE IF NOT EXISTS brd.manifest_vehicle (
  manifest_id    bigint NOT NULL REFERENCES brd.manifest(id) ON DELETE CASCADE,
  vehicle_id     bigint NOT NULL REFERENCES fleet.vehicle(id),
  trailer_id     bigint REFERENCES fleet.trailer(id),
  plate_no       text NOT NULL,
  plate_country  char(2) NOT NULL REFERENCES ref.country(code),
  chassis_no     text,
  PRIMARY KEY (manifest_id, vehicle_id)
);

CREATE TABLE IF NOT EXISTS brd.manifest_cargo (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  manifest_id         bigint NOT NULL REFERENCES brd.manifest(id) ON DELETE CASCADE,
  shipment_id         bigint REFERENCES ship.shipment(id),
  leg_id              bigint REFERENCES ship.shipment_leg(id),
  cargo_category      text NOT NULL REFERENCES ref.cargo_category(code),                -- D.3
  cargo_description   text NOT NULL,
  hs_code             text,
  declared_weight_kg  numeric(10,1) NOT NULL CHECK (declared_weight_kg > 0),
  packages            int CHECK (packages > 0),
  container_no        text,
  seal_no             text,
  un_number           text CHECK (un_number ~ '^UN[0-9]{4}$'),
  adr_class           text,
  temp_min_c          numeric(4,1),
  temp_max_c          numeric(4,1),
  CHECK (shipment_id IS NOT NULL OR leg_id IS NOT NULL),
  CHECK (adr_class IS NULL OR un_number IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS brd.manifest_response (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  manifest_id   bigint NOT NULL REFERENCES brd.manifest(id),
  subject_type  text NOT NULL CHECK (subject_type IN ('MANIFEST','PERSON','VEHICLE','CARGO')),
  subject_id    bigint,
  decision      text NOT NULL CHECK (decision IN ('OK','HOLD','DENY')),
  reason_code   text,
  silent_flag   boolean NOT NULL DEFAULT false,              -- never shown to the carrier (16.12)
  received_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (subject_type = 'MANIFEST' OR subject_id IS NOT NULL)
);
COMMENT ON TABLE brd.manifest_response IS 'Authority decisions per manifest or subject; silent flags are visible to the platform only; append-only';

CREATE TABLE IF NOT EXISTS brd.manifest_discrepancy (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  manifest_id       bigint NOT NULL REFERENCES brd.manifest(id),
  discrepancy_type  text NOT NULL CHECK (discrepancy_type IN ('MISSING_PERSON','EXTRA_PERSON','DOC_MISMATCH','VEHICLE_MISMATCH','CARGO_MISMATCH','WEIGHT_MISMATCH')),
  subject_type      text NOT NULL CHECK (subject_type IN ('PERSON','VEHICLE','CARGO')),
  subject_id        bigint,
  detail            jsonb NOT NULL DEFAULT '{}',
  resolved_by       bigint REFERENCES iam.app_user(id),
  resolved_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------ isolation and privileges ------------------------------
DO $$ BEGIN
  PERFORM sys.rls_catalog(t) FROM unnest(ARRAY['brd.border_point','brd.crossing_profile']) t;
  PERFORM sys.rls_trip('brd.manifest');
  PERFORM sys.rls_parent(t, 'manifest_id', 'brd.manifest') FROM unnest(ARRAY['brd.manifest_person','brd.manifest_vehicle',
    'brd.manifest_cargo','brd.manifest_discrepancy']) t;
  PERFORM sys.rls('brd.manifest_response', 'sys.ctx_is_platform()
    OR (NOT silent_flag AND EXISTS (SELECT 1 FROM brd.manifest m WHERE m.id = manifest_response.manifest_id))', 'sys.ctx_is_platform()');
  PERFORM sys.grant_rw(ARRAY['brd.border_point','brd.crossing_profile','brd.manifest','brd.manifest_person','brd.manifest_vehicle',
    'brd.manifest_cargo','brd.manifest_discrepancy']);
  PERFORM sys.grant_append(ARRAY['brd.manifest_response']);
END $$;
GRANT SELECT ON ALL TABLES IN SCHEMA brd TO masslak_auditor;

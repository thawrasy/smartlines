-- =====================================================================
-- 1164: a price for every station pair of a route, carrier classes and the state's price bands (owner's request N10)
--   * The carrier prices every pair of its route (any boarding station to any later one) in one matrix
--     (net.route_pair_fare): a direct route is one cell. The fare ladder from the origin follows the first row. Every
--     trip made from the route takes the matrix (ops.trip_pair_fare), which search and sales already read.
--   * Carrier prices are free now. The state may later impose price bands by the class it gives each carrier: the
--     platform keeps the classes (ref.carrier_class), the class of each carrier with its document and history
--     (iam.carrier_class_assignment) and the bands per class, in money per km, for every vehicle or one type
--     (pricing.state_price_band). With the setting pricing.state_bands on (off at launch), a price outside the band
--     of the carrier's class is refused when the matrix is saved, and when a trip is made with a vehicle of a type
--     that has its own band.
-- =====================================================================

CREATE TABLE IF NOT EXISTS net.route_pair_fare (
  route_id    bigint NOT NULL REFERENCES net.route(id),
  from_seq    smallint NOT NULL CHECK (from_seq >= 0),
  to_seq      smallint NOT NULL,
  price       bigint NOT NULL CHECK (price >= 0),
  updated_by  bigint REFERENCES iam.app_user(id),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (route_id, from_seq, to_seq),
  CHECK (to_seq > from_seq)
);
CREATE INDEX IF NOT EXISTS route_pair_fare_updated_by_fkx ON net.route_pair_fare (updated_by);
COMMENT ON TABLE net.route_pair_fare IS 'The carrier''s price for every pair of stations of its route, copied to each trip made from it (1164, N10)';
SELECT sys.rls('net.route_pair_fare',
  'EXISTS (SELECT 1 FROM net.route r WHERE r.id = route_pair_fare.route_id AND (sys.ctx_is_platform() OR sys.tenant_visible(r.company_id)))',
  'EXISTS (SELECT 1 FROM net.route r WHERE r.id = route_pair_fare.route_id AND sys.tenant_visible(r.company_id))');
GRANT SELECT, INSERT, UPDATE ON net.route_pair_fare TO masslak_app;
GRANT SELECT ON net.route_pair_fare TO masslak_readonly;
DROP TRIGGER IF EXISTS route_pair_fare_updated ON net.route_pair_fare;
CREATE TRIGGER route_pair_fare_updated BEFORE UPDATE ON net.route_pair_fare FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();

-- ------------------------------------------------------------------ carrier classes and the state's bands
CREATE TABLE IF NOT EXISTS ref.carrier_class (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9]{1,8}$'),
  name_en     text NOT NULL CHECK (length(btrim(name_en)) BETWEEN 1 AND 120),
  name_ar     text NOT NULL CHECK (length(btrim(name_ar)) BETWEEN 1 AND 120),
  criteria    text CHECK (length(criteria) <= 2000),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.carrier_class IS 'The classes the state gives carriers (A, B, C or another scheme), with their criteria (1164, N10)';

CREATE TABLE IF NOT EXISTS iam.carrier_class_assignment (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint NOT NULL REFERENCES iam.company(id),
  class_id      bigint NOT NULL REFERENCES ref.carrier_class(id),
  source_document text NOT NULL CHECK (length(btrim(source_document)) BETWEEN 3 AND 300),
  assigned_on   date NOT NULL,
  valid_until   date,
  assigned_by   bigint NOT NULL REFERENCES iam.app_user(id),
  assigned_at   timestamptz NOT NULL DEFAULT now(),
  ended_at      timestamptz,
  CHECK (valid_until IS NULL OR valid_until >= assigned_on)
);
CREATE UNIQUE INDEX IF NOT EXISTS carrier_class_assignment_current ON iam.carrier_class_assignment (company_id) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS carrier_class_assignment_class_id_fkx ON iam.carrier_class_assignment (class_id);
CREATE INDEX IF NOT EXISTS carrier_class_assignment_assigned_by_fkx ON iam.carrier_class_assignment (assigned_by);
COMMENT ON TABLE iam.carrier_class_assignment IS 'The class of a carrier, on the state''s document, with its dates; a new class ends the one before, which stays as history (1164, N10)';

CREATE TABLE IF NOT EXISTS pricing.state_price_band (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  class_id      bigint NOT NULL REFERENCES ref.carrier_class(id),
  vehicle_type  text CHECK (vehicle_type IN ('COACH', 'MINIBUS', 'CITY_BUS', 'VAN', 'TRAIN_SET', 'OTHER')),
  currency      char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  min_per_km    bigint CHECK (min_per_km >= 0),
  max_per_km    bigint CHECK (max_per_km >= 0),
  valid_from    date NOT NULL,
  source_document text CHECK (length(source_document) <= 300),
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  created_by    bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (min_per_km IS NOT NULL OR max_per_km IS NOT NULL),
  CHECK (min_per_km IS NULL OR max_per_km IS NULL OR min_per_km <= max_per_km)
);
CREATE INDEX IF NOT EXISTS state_price_band_class_id_fkx ON pricing.state_price_band (class_id);
CREATE INDEX IF NOT EXISTS state_price_band_created_by_fkx ON pricing.state_price_band (created_by);
CREATE INDEX IF NOT EXISTS state_price_band_currency_fkx ON pricing.state_price_band (currency);
CREATE UNIQUE INDEX IF NOT EXISTS state_price_band_one ON pricing.state_price_band (class_id, coalesce(vehicle_type, '*'), valid_from) WHERE status = 'ACTIVE';
COMMENT ON TABLE pricing.state_price_band IS 'The state''s price band per km for a carrier class, for every vehicle or one type, from a date (1164, N10)';

INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('pricing.state_bands', 'false'::jsonb, 'PLATFORM',
   'The state''s price bands by carrier class are applied (1164, N10): a carrier price outside its band is refused; off while carrier prices are free')
ON CONFLICT (key) DO NOTHING;

SELECT sys.rls('ref.carrier_class', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('iam.carrier_class_assignment', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id)', 'sys.ctx_is_platform()');
SELECT sys.rls('pricing.state_price_band', 'true', 'sys.ctx_is_platform()');
GRANT SELECT, INSERT, UPDATE ON ref.carrier_class, iam.carrier_class_assignment, pricing.state_price_band TO masslak_app;
GRANT SELECT ON ref.carrier_class, pricing.state_price_band TO masslak_readonly;
DROP TRIGGER IF EXISTS zz_audit_capture ON iam.carrier_class_assignment;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON iam.carrier_class_assignment FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS zz_audit_capture ON pricing.state_price_band;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON pricing.state_price_band FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- the band that holds for a carrier on a date, for a vehicle type (a type's own band first, else the class's general one);
-- nothing while the setting is off or the carrier has no class
CREATE OR REPLACE FUNCTION pricing.band_for(p_company bigint, p_vehicle_type text, p_on date) RETURNS pricing.state_price_band
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT b.* FROM pricing.state_price_band b
    JOIN iam.carrier_class_assignment a ON a.class_id = b.class_id AND a.company_id = p_company AND a.ended_at IS NULL
         AND a.assigned_on <= p_on AND (a.valid_until IS NULL OR a.valid_until >= p_on)
   WHERE b.status = 'ACTIVE' AND b.valid_from <= p_on AND (b.vehicle_type IS NULL OR b.vehicle_type = p_vehicle_type)
     AND coalesce((SELECT value = 'true'::jsonb FROM sys.setting WHERE key = 'pricing.state_bands'), false)
   ORDER BY b.vehicle_type IS NULL, b.valid_from DESC LIMIT 1
$$;
REVOKE ALL ON FUNCTION pricing.band_for(bigint, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pricing.band_for(bigint, text, date) TO masslak_app;
COMMENT ON FUNCTION pricing.band_for IS 'The state''s price band that holds for a carrier and vehicle type on a date, while the setting is on (1164)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('net.route_pair_fare', '1A', 'E13'), ('ref.carrier_class', '1A', 'E01'), ('iam.carrier_class_assignment', '1A', 'E01'),
  ('pricing.state_price_band', '1A', 'E13')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.route_pair_fare', 'net records', 'carriers'' prices for every station pair of their routes (1164)'),
  ('ref.carrier_class', 'ref catalog', 'carrier classes given by the state (1164)'),
  ('iam.carrier_class_assignment', 'iam records', 'the class of each carrier with its history (1164)'),
  ('pricing.state_price_band', 'pricing records', 'the state''s price bands per carrier class (1164)')
ON CONFLICT (table_name) DO NOTHING;

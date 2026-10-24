-- =====================================================================
-- 1124  Administrative geography: governorates, districts, sub-districts, communities and neighbourhoods (owner's request,
--       October 2026)
-- =====================================================================
-- The country is described once, in the hierarchy and with the codes the United Nations use (OCHA's common operational
-- datasets, "P-codes"), so that a route can later be opened from or to any place without defining it first:
--   level 1  governorate (muhafaza)      SY01 ... SY14
--   level 2  district (mantiqa)          SY0100 ...
--   level 3  sub-district (nahiya)       SY010000 ...
--   community: a city, town or village   C1001 ... (with its position), in a sub-district
--   neighbourhood: a part of a city      N0001 ... (with its position and the city's area), in a community
-- The names are kept in Arabic and English as published. The tables are loaded from the published workbook by the
-- platform (the platform page "Geography", POST /api/admin/geo/import; backend/app/modules/geo): each load is a
-- source of its own (ref.geo_source, with the file's SHA-256); a place a newer file drops is retired, never deleted,
-- since stations may stand in it. Field surveys later add places of their own (source FIELD).
-- A place is served when the platform opens it for routes (ref.serve_place): it becomes a city of the network
-- (ref.city, with a three-letter code) where carriers then set up stations; the cities already in use are linked to
-- their places (ref.city.place_id).

CREATE TABLE IF NOT EXISTS ref.geo_source (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid          uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  publisher    text NOT NULL CHECK (publisher IN ('OCHA', 'FIELD', 'PLATFORM')),
  dataset      text NOT NULL CHECK (length(dataset) BETWEEN 3 AND 200),
  file_name    text CHECK (length(file_name) <= 200),
  sha256       text CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  valid_on     date,
  counts       jsonb NOT NULL DEFAULT '{}',
  imported_by  bigint REFERENCES iam.app_user(id),
  imported_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sha256)
);
CREATE INDEX IF NOT EXISTS geo_source_imported_by_fkx ON ref.geo_source (imported_by);
COMMENT ON TABLE ref.geo_source IS 'Each load of the administrative geography: the publisher, the file and its hash, and what it held (1124)';

CREATE TABLE IF NOT EXISTS ref.admin_area (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pcode         text NOT NULL UNIQUE CHECK (pcode ~ '^[A-Z]{2}([0-9]{2}){1,3}$'),
  country_code  char(2) NOT NULL REFERENCES ref.country(code),
  level         smallint NOT NULL CHECK (level BETWEEN 1 AND 3),
  parent_id     bigint REFERENCES ref.admin_area(id),
  name_en       text NOT NULL CHECK (length(btrim(name_en)) BETWEEN 1 AND 120),
  name_ar       text NOT NULL CHECK (length(btrim(name_ar)) BETWEEN 1 AND 120),
  ref_name      text,
  valid_on      date,
  source_id     bigint REFERENCES ref.geo_source(id),
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT admin_area_level_ck CHECK (length(pcode) = 2 + 2 * level AND (level = 1) = (parent_id IS NULL)
                                        AND left(pcode, 2) = country_code)
);
CREATE INDEX IF NOT EXISTS admin_area_parent_id_fkx ON ref.admin_area (parent_id);
CREATE INDEX IF NOT EXISTS admin_area_country_code_fkx ON ref.admin_area (country_code, level);
CREATE INDEX IF NOT EXISTS admin_area_source_id_fkx ON ref.admin_area (source_id);
COMMENT ON TABLE ref.admin_area IS 'Governorates (1), districts (2) and sub-districts (3), with their United Nations codes and Arabic and English names (1124)';

CREATE TABLE IF NOT EXISTS ref.place (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pcode            text NOT NULL UNIQUE CHECK (pcode ~ '^[A-Z][0-9]{3,7}$'),
  kind             text NOT NULL CHECK (kind IN ('COMMUNITY', 'NEIGHBOURHOOD')),
  area_id          bigint NOT NULL REFERENCES ref.admin_area(id),           -- the sub-district
  parent_place_id  bigint REFERENCES ref.place(id),                         -- a neighbourhood's city
  city_area_code   text CHECK (city_area_code ~ '^[A-Z][0-9]{3}$'),         -- the area of the city a neighbourhood is in
  city_area_en     text,
  city_area_ar     text,
  name_en          text NOT NULL CHECK (length(btrim(name_en)) BETWEEN 1 AND 160),
  name_ar          text NOT NULL CHECK (length(btrim(name_ar)) BETWEEN 1 AND 160),
  lat              numeric(9,6) NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lng              numeric(9,6) NOT NULL CHECK (lng BETWEEN -180 AND 180),
  previous_pcode   text,
  updated_on       date,
  source_id        bigint REFERENCES ref.geo_source(id),
  status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT place_kind_ck CHECK ((kind = 'NEIGHBOURHOOD') = (parent_place_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS place_area_id_fkx ON ref.place (area_id);
CREATE INDEX IF NOT EXISTS place_parent_place_id_fkx ON ref.place (parent_place_id);
CREATE INDEX IF NOT EXISTS place_source_id_fkx ON ref.place (source_id);
CREATE INDEX IF NOT EXISTS place_name_en_trgm ON ref.place USING gin (name_en gin_trgm_ops);
CREATE INDEX IF NOT EXISTS place_name_ar_trgm ON ref.place USING gin (name_ar gin_trgm_ops);
COMMENT ON TABLE ref.place IS 'Communities (cities, towns, villages) and the neighbourhoods of cities, with their United Nations codes, names and positions (1124)';

-- the cities of the network and the stations stand in places
ALTER TABLE ref.city ADD COLUMN IF NOT EXISTS place_id bigint REFERENCES ref.place(id);
CREATE UNIQUE INDEX IF NOT EXISTS city_place_uq ON ref.city (place_id) WHERE place_id IS NOT NULL;
COMMENT ON COLUMN ref.city.place_id IS 'The community this city of the network is (1124)';
ALTER TABLE net.station ADD COLUMN IF NOT EXISTS place_id bigint REFERENCES ref.place(id);
CREATE INDEX IF NOT EXISTS station_place_id_fkx ON net.station (place_id);
COMMENT ON COLUMN net.station.place_id IS 'The community or neighbourhood the station stands in, when known (1124)';

DROP TRIGGER IF EXISTS admin_area_updated ON ref.admin_area;
CREATE TRIGGER admin_area_updated BEFORE UPDATE ON ref.admin_area FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
DROP TRIGGER IF EXISTS place_updated ON ref.place;
CREATE TRIGGER place_updated BEFORE UPDATE ON ref.place FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();

-- everyone reads the geography; the platform writes it
SELECT sys.rls_catalog('ref.geo_source');
SELECT sys.rls_catalog('ref.admin_area');
SELECT sys.rls_catalog('ref.place');
GRANT SELECT, INSERT, UPDATE ON ref.geo_source, ref.admin_area, ref.place TO masslak_app;
GRANT SELECT ON ref.geo_source, ref.admin_area, ref.place TO masslak_readonly, masslak_auditor;

-- a place's way up: its sub-district, district and governorate, in both languages
CREATE OR REPLACE FUNCTION ref.place_path(p_place bigint) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
           'pcode', p.pcode, 'kind', p.kind, 'name_en', p.name_en, 'name_ar', p.name_ar, 'lat', p.lat, 'lng', p.lng,
           'city', CASE WHEN c.id IS NOT NULL THEN jsonb_build_object('pcode', c.pcode, 'name_en', c.name_en, 'name_ar', c.name_ar) END,
           'sub_district', jsonb_build_object('pcode', a3.pcode, 'name_en', a3.name_en, 'name_ar', a3.name_ar),
           'district', jsonb_build_object('pcode', a2.pcode, 'name_en', a2.name_en, 'name_ar', a2.name_ar),
           'governorate', jsonb_build_object('pcode', a1.pcode, 'name_en', a1.name_en, 'name_ar', a1.name_ar),
           'served', (SELECT k.code FROM ref.city k WHERE k.place_id = p.id))
    FROM ref.place p
    LEFT JOIN ref.place c ON c.id = p.parent_place_id
    JOIN ref.admin_area a3 ON a3.id = p.area_id
    JOIN ref.admin_area a2 ON a2.id = a3.parent_id
    JOIN ref.admin_area a1 ON a1.id = a2.parent_id
   WHERE p.id = p_place
$$;
GRANT EXECUTE ON FUNCTION ref.place_path(bigint) TO masslak_app;
COMMENT ON FUNCTION ref.place_path IS 'A place with its city, sub-district, district and governorate, in Arabic and English (1124)';

-- the platform opens a place for routes: it becomes a city of the network, where carriers set up stations
CREATE OR REPLACE FUNCTION ref.serve_place(p_pcode text, p_code text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p ref.place; a1 ref.admin_area; v_code text := upper(btrim(coalesce(p_code, ''))); v_have text;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform opens places for routes' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO p FROM ref.place WHERE pcode = p_pcode AND status = 'ACTIVE';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PLACE_UNKNOWN: no place %', p_pcode USING ERRCODE = 'P0001';
  END IF;
  IF p.kind <> 'COMMUNITY' THEN
    RAISE EXCEPTION 'PLACE_NOT_COMMUNITY: a neighbourhood belongs to its city; open the city and put the station in the neighbourhood'
      USING ERRCODE = 'P0001';
  END IF;
  SELECT code INTO v_have FROM ref.city WHERE place_id = p.id;
  IF v_have IS NOT NULL THEN
    UPDATE ref.city SET is_active = true WHERE place_id = p.id;
    RETURN v_have;
  END IF;
  IF v_code !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'CITY_CODE: a city of the network has a code of three letters' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM ref.city WHERE code = v_code) THEN
    RAISE EXCEPTION 'CITY_CODE_TAKEN: % is the code of another city', v_code USING ERRCODE = 'P0001';
  END IF;
  SELECT g.* INTO a1 FROM ref.admin_area s JOIN ref.admin_area d ON d.id = s.parent_id JOIN ref.admin_area g ON g.id = d.parent_id
   WHERE s.id = p.area_id;
  -- the city keeps the time of its country's market
  INSERT INTO ref.city (code, country_code, region, name, lat, lng, place_id, timezone)
  VALUES (v_code, a1.country_code, a1.name_en, p.name_en, p.lat, p.lng, p.id,
          (SELECT m.time_zone FROM ref.market m WHERE m.country_code = a1.country_code));
  RETURN v_code;
END $$;
REVOKE ALL ON FUNCTION ref.serve_place(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.serve_place(text, text) TO masslak_app;
COMMENT ON FUNCTION ref.serve_place IS 'Opens a community for routes: a city of the network with a three-letter code, linked to the place; platform only (1124)';

-- the permission of the platform's staff who load and open places
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('geo.manage', 'ref', 'PLATFORM', 'Load the administrative geography (governorates to neighbourhoods) and open places for routes', false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'geo.manage' FROM iam.role r WHERE r.code = 'PLATFORM_ADMIN' AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ref.geo_source', '1A', 'E03'), ('ref.admin_area', '1A', 'E03'), ('ref.place', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ref.geo_source', 'ref catalog', 'the loads of the administrative geography (1124)'),
  ('ref.admin_area', 'ref catalog', 'governorates, districts and sub-districts (1124)'),
  ('ref.place', 'ref catalog', 'communities and neighbourhoods with their positions (1124)')
ON CONFLICT (table_name) DO NOTHING;
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('ref.geo_source', 'counts', 'EVIDENCE', 1, '{"type": "object"}'::jsonb, 'what a load of the geography held and changed (1124)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();

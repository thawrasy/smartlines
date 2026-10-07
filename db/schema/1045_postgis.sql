-- =====================================================================
-- 1045: PostGIS for route compliance (owner decision)
--   Routes stay stored as GeoJSON for the API; each one also gets a geography column derived from it, indexed for
--   spatial search. The database can then measure how far a position lies from the route a trip must keep to
--   (the approved line, an active diversion, a transit corridor or a school route), which the tracking service uses to
--   confirm deviations and to freeze the evidence of a violation. Live detection stays in the tracking service.
--   The extension lives in its own schema (gis); its reference table of coordinate systems is a public catalog.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS gis;
COMMENT ON SCHEMA gis IS 'PostGIS: spatial types and functions used by route compliance';
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA gis;
GRANT USAGE ON SCHEMA gis TO masslak_app, masslak_readonly, masslak_auditor;
SELECT sys.rls_catalog('gis.spatial_ref_sys');
GRANT SELECT ON gis.spatial_ref_sys TO masslak_app, masslak_readonly;
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('gis.spatial_ref_sys', '2', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

-- A GeoJSON LineString as geography (WGS 84); anything else gives NULL, so drafts may hold unfinished shapes
CREATE OR REPLACE FUNCTION sys.geo_line(p jsonb) RETURNS gis.geography
  LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF p IS NULL OR p ->> 'type' IS DISTINCT FROM 'LineString' OR jsonb_typeof(p -> 'coordinates') <> 'array'
     OR jsonb_array_length(p -> 'coordinates') < 2 THEN
    RETURN NULL;
  END IF;
  RETURN gis.st_setsrid(gis.st_geomfromgeojson(p::text), 4326)::gis.geography;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END $$;
COMMENT ON FUNCTION sys.geo_line IS 'GeoJSON LineString to geography; NULL when the shape is not a valid line';
GRANT EXECUTE ON FUNCTION sys.geo_line(jsonb) TO masslak_app, masslak_readonly;

ALTER TABLE net.line_version ADD COLUMN IF NOT EXISTS path gis.geography GENERATED ALWAYS AS (sys.geo_line(geometry)) STORED;
ALTER TABLE net.line_diversion ADD COLUMN IF NOT EXISTS path gis.geography GENERATED ALWAYS AS (sys.geo_line(geometry)) STORED;
ALTER TABLE net.corridor ADD COLUMN IF NOT EXISTS path_geo gis.geography GENERATED ALWAYS AS (sys.geo_line(path)) STORED;
ALTER TABLE sch.route ADD COLUMN IF NOT EXISTS path_geo gis.geography GENERATED ALWAYS AS (sys.geo_line(path)) STORED;
ALTER TABLE net.station ADD COLUMN IF NOT EXISTS geo gis.geography GENERATED ALWAYS AS
  (CASE WHEN lat IS NOT NULL AND lng IS NOT NULL THEN gis.st_setsrid(gis.st_makepoint(lng::float8, lat::float8), 4326)::gis.geography END) STORED;
CREATE INDEX IF NOT EXISTS line_version_path_gix ON net.line_version USING gist (path);
CREATE INDEX IF NOT EXISTS line_diversion_path_gix ON net.line_diversion USING gist (path);
CREATE INDEX IF NOT EXISTS corridor_path_gix ON net.corridor USING gist (path_geo);
CREATE INDEX IF NOT EXISTS sch_route_path_gix ON sch.route USING gist (path_geo);
CREATE INDEX IF NOT EXISTS station_geo_gix ON net.station USING gist (geo);
COMMENT ON COLUMN net.line_version.path IS 'The approved route as geography, derived from geometry (GeoJSON)';
COMMENT ON COLUMN net.station.geo IS 'The station as a geography point, derived from lat and lng';

-- A route becomes binding only with a valid line: approving or activating a line version, a diversion, a corridor
-- or a school route requires one (drafts may stay unfinished)
CREATE OR REPLACE FUNCTION sys.tg_route_shape_valid() RETURNS trigger LANGUAGE plpgsql
  SET search_path = pg_catalog, pg_temp AS $$
DECLARE shape jsonb := to_jsonb(NEW) -> TG_ARGV[0];
BEGIN
  IF (to_jsonb(NEW) ->> 'status') = ANY (TG_ARGV[1]::text[]) AND shape IS NOT NULL AND shape <> 'null'::jsonb
     AND sys.geo_line(shape) IS NULL THEN
    RAISE EXCEPTION 'ROUTE_SHAPE_INVALID: %.% must be a GeoJSON LineString of at least two points', TG_TABLE_NAME, TG_ARGV[0]
      USING ERRCODE = 'P0001';
  END IF;
  IF (to_jsonb(NEW) ->> 'status') = ANY (TG_ARGV[1]::text[]) AND TG_ARGV[2] = 'required' AND (shape IS NULL OR shape = 'null'::jsonb) THEN
    RAISE EXCEPTION 'ROUTE_SHAPE_INVALID: %.% is required', TG_TABLE_NAME, TG_ARGV[0] USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS route_shape_valid ON net.line_version;
CREATE TRIGGER route_shape_valid BEFORE INSERT OR UPDATE OF geometry, status ON net.line_version
  FOR EACH ROW WHEN (NEW.status IN ('APPROVED','ACTIVE')) EXECUTE FUNCTION sys.tg_route_shape_valid('geometry', '{APPROVED,ACTIVE}', 'required');
DROP TRIGGER IF EXISTS route_shape_valid ON net.line_diversion;
CREATE TRIGGER route_shape_valid BEFORE INSERT OR UPDATE OF geometry, status ON net.line_diversion
  FOR EACH ROW WHEN (NEW.status = 'ACTIVE') EXECUTE FUNCTION sys.tg_route_shape_valid('geometry', '{ACTIVE}', 'required');
DROP TRIGGER IF EXISTS route_shape_valid ON net.corridor;
CREATE TRIGGER route_shape_valid BEFORE INSERT OR UPDATE OF path, status ON net.corridor
  FOR EACH ROW WHEN (NEW.status = 'ACTIVE') EXECUTE FUNCTION sys.tg_route_shape_valid('path', '{ACTIVE}', 'required');
DROP TRIGGER IF EXISTS route_shape_valid ON sch.route;
CREATE TRIGGER route_shape_valid BEFORE INSERT OR UPDATE OF path, status ON sch.route
  FOR EACH ROW WHEN (NEW.status = 'ACTIVE') EXECUTE FUNCTION sys.tg_route_shape_valid('path', '{ACTIVE}', 'optional');

-- How far (metres) a position lies from the route the trip must keep to, and whether that is outside its corridor.
-- A regulated line counts its active diversions as part of the route. NULL when the trip has no route obligation.
CREATE OR REPLACE FUNCTION ops.route_distance_m(p_trip bigint, p_lat numeric, p_lng numeric, p_at timestamptz DEFAULT now())
  RETURNS TABLE (distance_m int, corridor_m int, off_route boolean)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH pos AS (SELECT gis.st_setsrid(gis.st_makepoint(p_lng::float8, p_lat::float8), 4326)::gis.geography AS g),
  shapes AS (
    SELECT v.path, v.corridor_m FROM ops.trip t JOIN net.line_version v ON v.id = t.line_version_id
     WHERE t.id = p_trip AND t.compliance_source = 'REGULATED_LINE'
    UNION ALL
    SELECT d.path, d.corridor_m FROM ops.trip t JOIN net.line_version v ON v.id = t.line_version_id
      JOIN net.line_diversion d ON d.line_id = v.line_id
     WHERE t.id = p_trip AND t.compliance_source = 'REGULATED_LINE' AND d.status = 'ACTIVE' AND d.active @> p_at
    UNION ALL
    SELECT c.path_geo, c.buffer_m FROM ops.trip t JOIN net.corridor c ON c.id = t.corridor_id
     WHERE t.id = p_trip AND t.compliance_source = 'TRANSIT_CORRIDOR'
    UNION ALL
    SELECT r.path_geo, r.corridor_m FROM sch.run rn JOIN sch.route r ON r.id = rn.route_id
     WHERE rn.trip_id = p_trip AND r.path_geo IS NOT NULL),
  measured AS (SELECT gis.st_distance(s.path, pos.g)::int AS d, s.corridor_m FROM shapes s, pos WHERE s.path IS NOT NULL)
  SELECT d, corridor_m, NOT EXISTS (SELECT 1 FROM measured m2 WHERE m2.d <= m2.corridor_m)
    FROM measured ORDER BY d LIMIT 1
$$;
COMMENT ON FUNCTION ops.route_distance_m IS 'Distance from the nearest binding route shape of the trip (line, active diversion, corridor or school route) and whether the position is outside every corridor';
GRANT EXECUTE ON FUNCTION ops.route_distance_m(bigint, numeric, numeric, timestamptz) TO masslak_app, masslak_readonly;

-- Stations within a radius, nearest first: stop arrival on shuttle lines and school pick-up points
CREATE OR REPLACE FUNCTION net.stations_near(p_lat numeric, p_lng numeric, p_radius_m int DEFAULT 200)
  RETURNS TABLE (station_id bigint, distance_m int)
  LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT s.id, gis.st_distance(s.geo, p.g)::int
    FROM net.station s,
         (SELECT gis.st_setsrid(gis.st_makepoint(p_lng::float8, p_lat::float8), 4326)::gis.geography AS g) p
   WHERE gis.st_dwithin(s.geo, p.g, p_radius_m)
   ORDER BY 2
$$;
COMMENT ON FUNCTION net.stations_near IS 'Stations within the radius, nearest first (the caller''s row-level security applies)';
GRANT EXECUTE ON FUNCTION net.stations_near(numeric, numeric, int) TO masslak_app, masslak_readonly;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.27.0', 'PostGIS: route geography, distance from the binding route, stations near a point'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.27.0');

SELECT sys.refresh_table_class();

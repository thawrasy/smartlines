-- =====================================================================
-- 1125  The geography in use: places surveyed in the field, the boundaries of the areas, and where a point lies
--       (owner's decision on the next steps of 1124, October 2026)
-- =====================================================================
-- 1. Field surveys. A place the United Nations file does not hold (a new village, a neighbourhood of a town) is
--    proposed by the platform with what the surveyor found (its sub-district, names, position, the day of the survey)
--    and is used only once another person of the platform has reviewed it (four eyes): PROPOSED, then ACTIVE or
--    REJECTED. Its code is F and five digits (F00001...), apart from the United Nations' C and N codes, so a newer
--    United Nations file never touches it. A place proposed near one already known with a like name is refused as
--    a likely duplicate unless the surveyor says it is another place.
-- 2. Boundaries. The same publisher's boundaries of governorates, districts and sub-districts (OCHA COD-AB, as
--    GeoJSON) are loaded onto ref.admin_area.boundary; a proposed place must then lie in its sub-district.
-- 3. Where a point lies: ref.locate(lat, lng) gives the sub-district holding it (by boundary when loaded) and the
--    nearest communities, so a station is put in its place by its position or found by name (net.station.place_id).

-- ------------------------------------------------------------------ 1. places surveyed in the field
ALTER TABLE ref.place DROP CONSTRAINT IF EXISTS place_status_check;
ALTER TABLE ref.place ADD CONSTRAINT place_status_check CHECK (status IN ('ACTIVE', 'RETIRED', 'PROPOSED', 'REJECTED'));
ALTER TABLE ref.place ADD COLUMN IF NOT EXISTS proposed_by bigint REFERENCES iam.app_user(id);
ALTER TABLE ref.place ADD COLUMN IF NOT EXISTS proposed_at timestamptz;
ALTER TABLE ref.place ADD COLUMN IF NOT EXISTS surveyed_on date;
ALTER TABLE ref.place ADD COLUMN IF NOT EXISTS survey_note text CHECK (length(survey_note) <= 1000);
ALTER TABLE ref.place ADD COLUMN IF NOT EXISTS reviewed_by bigint REFERENCES iam.app_user(id);
ALTER TABLE ref.place ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;
ALTER TABLE ref.place ADD COLUMN IF NOT EXISTS review_note text CHECK (length(review_note) <= 500);
CREATE INDEX IF NOT EXISTS place_proposed_by_fkx ON ref.place (proposed_by);
CREATE INDEX IF NOT EXISTS place_reviewed_by_fkx ON ref.place (reviewed_by);
CREATE INDEX IF NOT EXISTS place_proposed_ix ON ref.place (proposed_at) WHERE status = 'PROPOSED';
ALTER TABLE ref.place DROP CONSTRAINT IF EXISTS place_field_ck;
ALTER TABLE ref.place ADD CONSTRAINT place_field_ck CHECK (
  (status NOT IN ('PROPOSED', 'REJECTED') OR proposed_by IS NOT NULL)
  AND (reviewed_by IS NULL OR reviewed_by IS DISTINCT FROM proposed_by)
  AND (pcode !~ '^F' OR proposed_by IS NOT NULL));
COMMENT ON COLUMN ref.place.proposed_by IS 'Who proposed a place surveyed in the field (1125)';
COMMENT ON COLUMN ref.place.reviewed_by IS 'Who reviewed a proposed place: another person than who proposed it (1125)';

CREATE SEQUENCE IF NOT EXISTS ref.field_place_seq;
GRANT USAGE ON SEQUENCE ref.field_place_seq TO masslak_app;

-- the one source the field surveys are recorded under
CREATE OR REPLACE FUNCTION ref.field_source() RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v bigint;
BEGIN
  SELECT id INTO v FROM ref.geo_source WHERE publisher = 'FIELD' ORDER BY id LIMIT 1;
  IF v IS NULL THEN
    INSERT INTO ref.geo_source (publisher, dataset, imported_by) VALUES ('FIELD', 'Field surveys', sys.ctx_user_id()) RETURNING id INTO v;
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION ref.field_source() FROM PUBLIC;

CREATE OR REPLACE FUNCTION ref.propose_place(p_kind text, p_area text, p_parent text, p_name_en text, p_name_ar text,
                                             p_lat numeric, p_lng numeric, p_surveyed_on date, p_note text,
                                             p_not_duplicate boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE a ref.admin_area; parent ref.place; v_code text; v_like text; v_point gis.geography;
BEGIN
  IF NOT sys.ctx_is_platform() OR sys.ctx_user_id() IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform records places surveyed in the field' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind NOT IN ('COMMUNITY', 'NEIGHBOURHOOD') THEN
    RAISE EXCEPTION 'PLACE_KIND: a community or a neighbourhood' USING ERRCODE = 'P0001';
  END IF;
  IF p_surveyed_on IS NULL OR p_surveyed_on > current_date THEN
    RAISE EXCEPTION 'SURVEY_DATE: the day of the survey, not after today' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind = 'NEIGHBOURHOOD' THEN
    SELECT * INTO parent FROM ref.place WHERE pcode = p_parent AND kind = 'COMMUNITY' AND status = 'ACTIVE';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'PLACE_PARENT: a neighbourhood is in a known community' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO a FROM ref.admin_area WHERE id = parent.area_id;
  ELSE
    SELECT * INTO a FROM ref.admin_area WHERE pcode = p_area AND level = 3 AND status = 'ACTIVE';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'PLACE_AREA: a community is in a known sub-district' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'PLACE_POSITION: a latitude and a longitude' USING ERRCODE = 'P0001';
  END IF;
  v_point := gis.st_setsrid(gis.st_makepoint(p_lng::float8, p_lat::float8), 4326)::gis.geography;
  -- in its sub-district when the boundary is known (2 km of tolerance for the drawing), else near the area's places
  IF a.boundary IS NOT NULL THEN
    IF NOT gis.st_dwithin(a.boundary::gis.geography, v_point, 2000) THEN
      RAISE EXCEPTION 'PLACE_OUTSIDE_AREA: the position is outside % (%)', a.name_en, a.pcode USING ERRCODE = 'P0001';
    END IF;
  ELSIF EXISTS (SELECT 1 FROM ref.place q WHERE q.area_id = a.id AND q.status = 'ACTIVE') AND NOT EXISTS (
          SELECT 1 FROM ref.place q WHERE q.area_id = a.id AND q.status = 'ACTIVE'
             AND gis.st_dwithin(gis.st_setsrid(gis.st_makepoint(q.lng::float8, q.lat::float8), 4326)::gis.geography, v_point, 40000)) THEN
    RAISE EXCEPTION 'PLACE_OUTSIDE_AREA: the position is far from every place of % (%)', a.name_en, a.pcode USING ERRCODE = 'P0001';
  END IF;
  -- a like name within 2 km is most likely the same place
  IF NOT p_not_duplicate THEN
    SELECT q.pcode INTO v_like FROM ref.place q
     WHERE q.status IN ('ACTIVE', 'PROPOSED') AND q.lat BETWEEN p_lat - 0.05 AND p_lat + 0.05 AND q.lng BETWEEN p_lng - 0.05 AND p_lng + 0.05
       AND gis.st_dwithin(gis.st_setsrid(gis.st_makepoint(q.lng::float8, q.lat::float8), 4326)::gis.geography, v_point, 2000)
       AND (public.similarity(q.name_en, p_name_en) > 0.5 OR public.similarity(q.name_ar, p_name_ar) > 0.5)
     LIMIT 1;
    IF v_like IS NOT NULL THEN
      RAISE EXCEPTION 'PLACE_DUPLICATE: % is near with a like name; say it is another place if it is', v_like USING ERRCODE = 'P0001';
    END IF;
  END IF;
  v_code := 'F' || lpad(nextval('ref.field_place_seq')::text, 5, '0');
  INSERT INTO ref.place (pcode, kind, area_id, parent_place_id, name_en, name_ar, lat, lng, updated_on, source_id, status,
                         proposed_by, proposed_at, surveyed_on, survey_note)
  VALUES (v_code, p_kind, a.id, parent.id, btrim(p_name_en), btrim(p_name_ar), p_lat, p_lng, p_surveyed_on, ref.field_source(),
          'PROPOSED', sys.ctx_user_id(), now(), p_surveyed_on, nullif(btrim(coalesce(p_note, '')), ''));
  RETURN v_code;
END $$;
REVOKE ALL ON FUNCTION ref.propose_place(text, text, text, text, text, numeric, numeric, date, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.propose_place(text, text, text, text, text, numeric, numeric, date, text, boolean) TO masslak_app;
COMMENT ON FUNCTION ref.propose_place IS 'Records a place surveyed in the field as PROPOSED, with an F code, after checking its area, position and likely duplicates; platform only (1125)';

CREATE OR REPLACE FUNCTION ref.review_place(p_pcode text, p_accept boolean, p_note text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p ref.place;
BEGIN
  IF NOT sys.ctx_is_platform() OR sys.ctx_user_id() IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform reviews places surveyed in the field' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO p FROM ref.place WHERE pcode = p_pcode FOR UPDATE;
  IF NOT FOUND OR p.status <> 'PROPOSED' THEN
    RAISE EXCEPTION 'PLACE_NOT_PROPOSED: % is not waiting for review', p_pcode USING ERRCODE = 'P0001';
  END IF;
  IF p.proposed_by = sys.ctx_user_id() THEN
    RAISE EXCEPTION 'FOUR_EYES: another person reviews the place you proposed' USING ERRCODE = 'P0001';
  END IF;
  IF NOT p_accept AND length(btrim(coalesce(p_note, ''))) < 5 THEN
    RAISE EXCEPTION 'REVIEW_NOTE: say why the place is rejected' USING ERRCODE = 'P0001';
  END IF;
  UPDATE ref.place SET status = CASE WHEN p_accept THEN 'ACTIVE' ELSE 'REJECTED' END, reviewed_by = sys.ctx_user_id(),
         reviewed_at = now(), review_note = nullif(btrim(coalesce(p_note, '')), '')
   WHERE id = p.id;
  RETURN CASE WHEN p_accept THEN 'ACTIVE' ELSE 'REJECTED' END;
END $$;
REVOKE ALL ON FUNCTION ref.review_place(text, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.review_place(text, boolean, text) TO masslak_app;
COMMENT ON FUNCTION ref.review_place IS 'Accepts a proposed place (ACTIVE, usable) or rejects it with a reason; another person than who proposed it (1125)';

-- ------------------------------------------------------------------ 2. the boundaries of the areas
ALTER TABLE ref.admin_area ADD COLUMN IF NOT EXISTS boundary gis.geometry(MultiPolygon, 4326);
ALTER TABLE ref.admin_area ADD COLUMN IF NOT EXISTS boundary_source_id bigint REFERENCES ref.geo_source(id);
CREATE INDEX IF NOT EXISTS admin_area_boundary_gix ON ref.admin_area USING gist (boundary);
CREATE INDEX IF NOT EXISTS admin_area_boundary_source_id_fkx ON ref.admin_area (boundary_source_id);
COMMENT ON COLUMN ref.admin_area.boundary IS 'The area''s boundary (WGS 84), from the publisher''s boundaries file (1125)';
COMMENT ON COLUMN ref.admin_area.boundary_source_id IS 'The load the boundary came from (1125)';

ALTER TABLE ref.geo_source DROP CONSTRAINT IF EXISTS geo_source_dataset_kind_check;
ALTER TABLE ref.geo_source ADD COLUMN IF NOT EXISTS content text NOT NULL DEFAULT 'PLACES';
ALTER TABLE ref.geo_source ADD CONSTRAINT geo_source_dataset_kind_check CHECK (content IN ('PLACES', 'BOUNDARIES'));
COMMENT ON COLUMN ref.geo_source.content IS 'What a load held: the places (P-codes) or the boundaries of the areas (1125)';

-- ------------------------------------------------------------------ 3. where a point lies
CREATE OR REPLACE FUNCTION ref.locate(p_lat numeric, p_lng numeric, p_limit int DEFAULT 5) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  WITH pt AS (SELECT gis.st_setsrid(gis.st_makepoint(p_lng::float8, p_lat::float8), 4326) AS g),
       inside AS (SELECT a.id, a.pcode FROM ref.admin_area a, pt
                   WHERE a.level = 3 AND a.status = 'ACTIVE' AND a.boundary IS NOT NULL AND gis.st_covers(a.boundary, pt.g)
                   LIMIT 1),
       near AS (SELECT p.id, p.area_id,
                       gis.st_distance(gis.st_setsrid(gis.st_makepoint(p.lng::float8, p.lat::float8), 4326)::gis.geography,
                                       pt.g::gis.geography) AS metres
                  FROM ref.place p, pt
                 WHERE p.status = 'ACTIVE' AND p.lat BETWEEN p_lat - 0.3 AND p_lat + 0.3 AND p.lng BETWEEN p_lng - 0.3 AND p_lng + 0.3
                 ORDER BY metres LIMIT greatest(least(p_limit, 20), 1))
  SELECT jsonb_build_object(
           'by_boundary', EXISTS (SELECT 1 FROM inside),
           'sub_district', (SELECT jsonb_build_object('pcode', a.pcode, 'name_en', a.name_en, 'name_ar', a.name_ar)
                              FROM ref.admin_area a
                             WHERE a.id = coalesce((SELECT id FROM inside), (SELECT area_id FROM near ORDER BY metres LIMIT 1))),
           'places', coalesce((SELECT jsonb_agg(ref.place_path(n.id) || jsonb_build_object('metres', round(n.metres)) ORDER BY n.metres)
                                 FROM near n), '[]'::jsonb))
$$;
GRANT EXECUTE ON FUNCTION ref.locate(numeric, numeric, int) TO masslak_app;
COMMENT ON FUNCTION ref.locate IS 'The sub-district holding a point (by boundary when loaded, else by the nearest place) and the nearest places with their distance (1125)';

-- ------------------------------------------------------------------ who looks after the geography
-- the platform's geography officers load the files and review the places surveyed in the field, apart from the
-- administrators, so a proposed place is reviewed by a second person
INSERT INTO iam.role (code, name, scope, is_system)
SELECT 'PLATFORM_GEOGRAPHY', 'Geography officer', 'PLATFORM', true
 WHERE NOT EXISTS (SELECT 1 FROM iam.role WHERE code = 'PLATFORM_GEOGRAPHY' AND company_id IS NULL);
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'geo.manage' FROM iam.role r WHERE r.code = 'PLATFORM_GEOGRAPHY' AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- =====================================================================
-- 1160: the cities of the network by class, and the way down from a governorate to a station (owner's request N37)
--   * A city of the network is a main city or a secondary destination (ref.city.city_class). The cities already in
--     the network are main; a place the platform opens later is a secondary destination until the platform says
--     otherwise. Main cities come first wherever cities are listed.
--   * Pickers go down one level at a time: the governorate, its cities, the city's areas and neighbourhoods, then the
--     stations there. ref.geo_cascade gives each level for what is already chosen. A city's governorate comes from
--     its place in the United Nations geography (1124): the first four characters of its sub-district's code.
-- =====================================================================

ALTER TABLE ref.city ADD COLUMN IF NOT EXISTS city_class text NOT NULL DEFAULT 'SECONDARY';
ALTER TABLE ref.city DROP CONSTRAINT IF EXISTS city_city_class_check;
ALTER TABLE ref.city ADD CONSTRAINT city_city_class_check CHECK (city_class IN ('MAIN', 'SECONDARY'));
COMMENT ON COLUMN ref.city.city_class IS 'A main city of the network or a secondary destination; main cities are listed first (1160, N37)';
-- the cities in the network before 1160 are its main cities (once: a later class set by the platform is kept)
UPDATE ref.city SET city_class = 'MAIN'
 WHERE city_class = 'SECONDARY' AND NOT EXISTS (SELECT 1 FROM sys.setting WHERE key = 'geo.city_classes_set');
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('geo.city_classes_set', 'true'::jsonb, 'PLATFORM', 'The cities in the network when classes came in were made main cities once (1160)')
ON CONFLICT (key) DO NOTHING;

-- a city's governorate, from its place
CREATE OR REPLACE FUNCTION ref.city_governorate(p_city bigint) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT left(a.pcode, 4) FROM ref.city c JOIN ref.place p ON p.id = c.place_id JOIN ref.admin_area a ON a.id = p.area_id
   WHERE c.id = p_city
$$;
COMMENT ON FUNCTION ref.city_governorate IS 'The governorate (its United Nations code) a city of the network lies in, from its place; NULL when it has none (1160)';

-- each level of the way down, for what is chosen: governorates with cities of the network, the cities of a governorate
-- (main first), the areas and neighbourhoods of a city, and the stations of a city or of one neighbourhood
CREATE OR REPLACE FUNCTION ref.geo_cascade(p_governorate text, p_city text, p_area text) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  WITH cities AS (
    SELECT c.id, c.code, c.name, c.city_class, c.place_id, ref.city_governorate(c.id) AS governorate,
           coalesce(p.name_ar, c.name) AS name_ar
      FROM ref.city c LEFT JOIN ref.place p ON p.id = c.place_id
     WHERE c.is_active AND c.country_code = 'SY'),
  chosen AS (SELECT * FROM cities WHERE code = p_city)
  SELECT jsonb_build_object(
    'governorates', coalesce((
      SELECT jsonb_agg(jsonb_build_object('pcode', a.pcode, 'name_en', a.name_en, 'name_ar', a.name_ar,
                                          'cities', (SELECT count(*) FROM cities x WHERE x.governorate = a.pcode)) ORDER BY a.pcode)
        FROM ref.admin_area a
       WHERE a.level = 1 AND a.status = 'ACTIVE' AND EXISTS (SELECT 1 FROM cities x WHERE x.governorate = a.pcode)), '[]'::jsonb),
    'cities', coalesce((
      SELECT jsonb_agg(jsonb_build_object('code', x.code, 'name_en', x.name, 'name_ar', x.name_ar, 'city_class', x.city_class,
                                          'governorate', x.governorate)
                       ORDER BY x.city_class = 'MAIN' DESC, x.name)
        FROM cities x WHERE p_governorate IS NULL OR x.governorate = p_governorate), '[]'::jsonb),
    'areas', coalesce((
      SELECT jsonb_agg(jsonb_build_object('pcode', n.pcode, 'name_en', n.name_en, 'name_ar', n.name_ar,
                                          'city_area_code', n.city_area_code, 'city_area_en', n.city_area_en,
                                          'city_area_ar', n.city_area_ar) ORDER BY n.city_area_code NULLS LAST, n.name_en)
        FROM chosen k JOIN ref.place n ON n.parent_place_id = k.place_id AND n.status = 'ACTIVE'), '[]'::jsonb),
    'stations', coalesce((
      SELECT jsonb_agg(jsonb_build_object('uid', s.uid, 'code', s.code, 'name', s.name,
                                          'place', (SELECT pl.pcode FROM ref.place pl WHERE pl.id = s.place_id)) ORDER BY s.code)
        FROM chosen k JOIN net.station s ON s.city_id = k.id AND s.status = 'ACTIVE'
       WHERE p_area IS NULL OR s.place_id = (SELECT id FROM ref.place WHERE pcode = p_area)), '[]'::jsonb))
$$;
COMMENT ON FUNCTION ref.geo_cascade IS 'The pickers'' levels for what is chosen: governorates, their cities (main first), a city''s areas and neighbourhoods, its stations (1160, N37)';
GRANT EXECUTE ON FUNCTION ref.city_governorate(bigint), ref.geo_cascade(text, text, text) TO masslak_app, masslak_readonly;

-- =====================================================================
-- 1141: the interface language a visitor sees first, by the country they visit from (owner decision, October 2026)
--   Visitors in Syria see Arabic first; visitors from anywhere else see English and can switch. The language for
--   each country is a platform setting (ui.visitor_locale): a default for countries not listed, and a language per
--   country. A visitor's own choice always wins (the web keeps it in the browser, an account in preferred_locale);
--   this setting decides only the first screen. The country comes from the edge proxy (deploy: CF-IPCountry or the
--   GeoIP header the proxy sets); without it the default applies.
-- =====================================================================

INSERT INTO sys.setting (key, value, description) VALUES
  ('ui.visitor_locale', '{"default": "en", "countries": {"SY": "ar"}}'::jsonb,
   'First interface language by the visitor''s country: a default and a language per ISO country code (1141)')
ON CONFLICT (key) DO NOTHING;

-- the language a visitor from a country sees first; only enabled languages are returned
CREATE OR REPLACE FUNCTION sys.visitor_locale(p_country text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH s AS (SELECT value FROM sys.setting WHERE key = 'ui.visitor_locale'),
       wanted AS (SELECT coalesce((SELECT value -> 'countries' ->> upper(btrim(coalesce(p_country, ''))) FROM s),
                                  (SELECT value ->> 'default' FROM s)) AS code)
  SELECT coalesce((SELECT l.code FROM ref.locale l, wanted w WHERE l.code = w.code AND l.is_enabled),
                  (SELECT code FROM ref.locale WHERE is_default), 'en')
$$;
REVOKE ALL ON FUNCTION sys.visitor_locale(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.visitor_locale(text) TO masslak_app;
COMMENT ON FUNCTION sys.visitor_locale IS 'The interface language a visitor from a country sees first: the country''s language, else the default (1141)';

-- sets the default and the languages by country; platform only, enabled languages and ISO country codes only
CREATE OR REPLACE FUNCTION sys.set_visitor_locale(p_doc jsonb, p_basis text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k text; v text;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the visitor language is a platform setting' USING ERRCODE = 'P0001';
  END IF;
  IF p_doc IS NULL OR jsonb_typeof(p_doc -> 'countries') IS DISTINCT FROM 'object'
     OR NOT EXISTS (SELECT 1 FROM ref.locale WHERE code = p_doc ->> 'default' AND is_enabled) THEN
    RAISE EXCEPTION 'INVALID_SETTING: give an enabled default language and a list of countries' USING ERRCODE = 'P0001';
  END IF;
  FOR k, v IN SELECT key, value FROM jsonb_each_text(p_doc -> 'countries') LOOP
    IF k !~ '^[A-Z]{2}$' THEN
      RAISE EXCEPTION 'INVALID_SETTING: % is not a two-letter country code', k USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ref.locale WHERE code = v AND is_enabled) THEN
      RAISE EXCEPTION 'INVALID_SETTING: % is not an enabled language', v USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  IF length(btrim(coalesce(p_basis, ''))) NOT BETWEEN 3 AND 160 THEN
    RAISE EXCEPTION 'INVALID_SETTING: name the reason for the change' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
  VALUES ('ui.visitor_locale', jsonb_build_object('default', p_doc ->> 'default', 'countries', p_doc -> 'countries',
                                                  'basis', btrim(p_basis)), 'PLATFORM',
          'First interface language by the visitor''s country: a default and a language per ISO country code (1141)',
          sys.ctx_user_id(), now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  RETURN (SELECT value FROM sys.setting WHERE key = 'ui.visitor_locale');
END $$;
REVOKE ALL ON FUNCTION sys.set_visitor_locale(jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.set_visitor_locale(jsonb, text) TO masslak_app;
COMMENT ON FUNCTION sys.set_visitor_locale IS 'Sets the first interface language by country, with the reason; platform only (1141)';

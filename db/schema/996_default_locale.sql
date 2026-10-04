-- =====================================================================
-- 996: platform default interface language
--   English is the default. Setting the value to "ar" makes the Arabic (RTL) interface the default for new
--   accounts; the web build takes the same choice from VITE_DEFAULT_LOCALE. All code and data stay in English.
-- =====================================================================
INSERT INTO sys.setting (key, value, description)
VALUES ('ui.default_locale', '"en"', 'Default interface language for new accounts (en or ar)')
ON CONFLICT (key) DO NOTHING;

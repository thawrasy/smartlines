-- Run by db/build.sh and db/upgrade.sh before any schema file.
--
-- The postgis/postgis image (docker-compose.yml, CI) loads PostGIS, its topology and tiger geocoder extensions and
-- fuzzystrmatch into the public schema of the database named by POSTGRES_DB when the volume is first created. Schema
-- file 1045 keeps PostGIS in its own schema (gis), and its CREATE EXTENSION IF NOT EXISTS does nothing when the
-- extension is already installed elsewhere, so the build stopped at 1045 ("relation gis.spatial_ref_sys does not
-- exist"). Until 1045 has run, nothing of the platform uses PostGIS: a copy installed outside gis is removed here,
-- and 1045 installs it in gis. DROP without CASCADE refuses, and stops the build, if anything else depends on it.
DO $$
BEGIN
  IF to_regclass('gis.spatial_ref_sys') IS NULL
     AND EXISTS (SELECT 1 FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
                  WHERE e.extname = 'postgis' AND n.nspname <> 'gis') THEN
    DROP EXTENSION IF EXISTS postgis_tiger_geocoder;
    DROP EXTENSION IF EXISTS postgis_topology;
    DROP EXTENSION postgis;
    DROP EXTENSION IF EXISTS fuzzystrmatch;
    BEGIN
      DROP SCHEMA IF EXISTS tiger_data, tiger, topology;   -- left empty by the extensions; kept if anything is in them
    EXCEPTION WHEN dependent_objects_still_exist THEN
      RAISE WARNING 'schemas tiger_data, tiger or topology are not empty and were kept';
    END;
    RAISE WARNING 'PostGIS preloaded outside schema gis was removed; schema file 1045 installs it in gis';
  END IF;
END $$;

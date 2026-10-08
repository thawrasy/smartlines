-- =====================================================================
-- 1058: release manifest (expert review of October 2026, stage C)
--   Every build and upgrade records what the database now is: the release version, the commit it came from, how
--   many schema files are applied, and one hash over all of them (sys.schema_hash). db/upgrade.sh compares the hash
--   with the last manifest before it applies anything, so a change to the record of applied files made by hand stops
--   the next upgrade, and reports, metrics and the release notes name the same release.
-- =====================================================================
-- sys.schema_file is created by db/schema_file.sql after the numbered files on a fresh build, so the bodies below are
-- checked when they first run rather than when they are created
SET check_function_bodies = off;

CREATE TABLE IF NOT EXISTS sys.release_manifest (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  version      text NOT NULL,
  commit_sha   text NOT NULL DEFAULT 'unknown' CHECK (commit_sha ~ '^([0-9a-f]{7,40}|unknown|release-archive)$'),
  schema_hash  text NOT NULL CHECK (schema_hash ~ '^[0-9a-f]{64}$'),
  files        integer NOT NULL CHECK (files > 0),
  action       text NOT NULL CHECK (action IN ('BUILD', 'UPGRADE')),
  applied_by   text NOT NULL DEFAULT current_user,
  applied_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sys.release_manifest IS 'What each build or upgrade left the database as: release, commit, applied files and their hash (1058)';
SELECT sys.rls_catalog('sys.release_manifest');
REVOKE ALL ON sys.release_manifest FROM masslak_app;
GRANT SELECT ON sys.release_manifest TO masslak_app, masslak_readonly, masslak_auditor;

-- One hash over every applied schema file and its SHA-256, in file order: equal hashes mean the same schema files
CREATE OR REPLACE FUNCTION sys.schema_hash() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT encode(sha256(convert_to(coalesce(string_agg(f.file || ' ' || f.sha256, E'\n' ORDER BY f.file), ''), 'UTF8')), 'hex')
    FROM sys.schema_file f
$$;
COMMENT ON FUNCTION sys.schema_hash IS 'SHA-256 over the applied schema files and their hashes (release manifest, 1058)';

-- Called by db/build.sh and db/upgrade.sh after the files are applied. A run that changes nothing (the migrate service
-- runs at every start) adds no row; a new version, commit or set of files does.
CREATE OR REPLACE FUNCTION sys.record_release(p_action text, p_commit text DEFAULT 'unknown') RETURNS sys.release_manifest
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v text := coalesce((SELECT m.version FROM sys.schema_migration m
                       ORDER BY string_to_array(m.version, '.')::int[] DESC LIMIT 1), '0');
  c text := CASE WHEN p_commit ~ '^([0-9a-f]{7,40}|unknown|release-archive)$' THEN p_commit ELSE 'unknown' END;
  h text := sys.schema_hash();
  last sys.release_manifest;
BEGIN
  SELECT * INTO last FROM sys.release_manifest ORDER BY id DESC LIMIT 1;
  IF last.id IS NOT NULL AND last.version = v AND last.commit_sha = c AND last.schema_hash = h THEN
    RETURN last;
  END IF;
  INSERT INTO sys.release_manifest (version, commit_sha, schema_hash, files, action)
  VALUES (v, c, h, (SELECT count(*) FROM sys.schema_file), p_action) RETURNING * INTO last;
  RETURN last;
END $$;
REVOKE ALL ON FUNCTION sys.record_release(text, text) FROM PUBLIC;

-- The release the application runs against: reports' source_version, metrics, readiness
CREATE OR REPLACE FUNCTION sys.current_release() RETURNS TABLE (version text, commit_sha text, schema_hash text, files integer,
                                                               applied_at timestamptz, hash_matches boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT r.version, r.commit_sha, r.schema_hash, r.files, r.applied_at, r.schema_hash = sys.schema_hash()
    FROM sys.release_manifest r ORDER BY r.id DESC LIMIT 1
$$;
COMMENT ON FUNCTION sys.current_release IS 'The last build or upgrade and whether the applied files still match its hash (1058)';
REVOKE ALL ON FUNCTION sys.current_release() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.current_release() TO masslak_app, masslak_readonly, masslak_auditor;
GRANT EXECUTE ON FUNCTION sys.schema_hash() TO masslak_app, masslak_readonly, masslak_auditor;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sys.release_manifest', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days)
VALUES ('sys.release_manifest', 'INTERNAL', 'sys', 'Which release, commit and schema files each build or upgrade left in place',
        'Legitimate interest', 3650, 'KEEP_LEGAL', '{replica,backup}', 35)
ON CONFLICT (dataset) DO NOTHING;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.39.0', 'Expert review stage C: release manifest and schema hash'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.39.0');

SELECT sys.refresh_table_class();
RESET check_function_bodies;

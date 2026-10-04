-- Record of applied schema files, used by build.sh and upgrade.sh (not a numbered file: it runs on every upgrade)
CREATE TABLE IF NOT EXISTS sys.schema_file (
  file        text PRIMARY KEY,
  sha256      text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  applied_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sys.schema_file IS 'Schema files applied to this database, with their SHA-256 at the time';
REVOKE ALL ON sys.schema_file FROM masslak_app;
GRANT SELECT ON sys.schema_file TO masslak_readonly;

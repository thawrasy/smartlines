-- =====================================================================
-- 1140: one version for each release (independent review, round 9, MAN P1)
--   sys.record_release names a build after the highest version in sys.schema_migration. The last file to add one was
--   1073 (1.48.0), so releases 1.49.0 and 1.50.0, and every file since, were recorded as 1.48.0: the API, the metrics
--   and the evidence pack called a 1.50+ schema 1.48.0. The missing versions are recorded here, and from now on the
--   release a file belongs to is the repository's VERSION file: scripts/check_release.py fails CI when the highest
--   version a schema file records differs from VERSION, release.yml refuses a tag that is not v<VERSION>, and a
--   production server refuses to install from a checkout that is not that tag (deploy/production/preflight.sh).
--   Files of each release: 1.48.0 up to 1079, 1.49.0 1080 to 1083, 1.50.0 1084 to 1093, 1.51.0 1094 to 1140.
-- =====================================================================

INSERT INTO sys.schema_migration (version, description)
SELECT v, d FROM (VALUES
  ('1.49.0', 'Reviews of release 1.48.0: verified request context, role split, production profile (files 1080 to 1083)'),
  ('1.50.0', 'Reviews of release 1.49.0: settings guard, station portal, boarding photo policy (files 1084 to 1093)'),
  ('1.51.0', 'Readiness release candidate: KYC, trip numbers, journeys, charter, geography, connections, freight, '
             'evaluations and the independent review (files 1094 to 1140)')
) AS x(v, d)
WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration m WHERE m.version = x.v);

-- The station portal (the owner's decision, October 2026: option A). An operating company signs in to its own portal,
-- STATION, which keeps it out of the carriers' records and screens. It acts only with the rights a carrier or the platform
-- gave it (1098). The company is of its own type, STATION_OPERATOR: it opens no other portal, and a carrier does not open
-- this one.

-- 1. the portal, the company type and the party role ------------------------------------------------------------------------
-- the session table can be large on a live server: the new rule is added without a full check under lock, then checked
ALTER TABLE iam.user_session DROP CONSTRAINT IF EXISTS user_session_portal_check;
ALTER TABLE iam.user_session ADD CONSTRAINT user_session_portal_check
  CHECK (portal IN ('PLATFORM', 'OPERATOR', 'AGENCY', 'PASSENGER', 'DRIVER', 'INSPECTOR', 'STATION')) NOT VALID;
ALTER TABLE iam.user_session VALIDATE CONSTRAINT user_session_portal_check;

ALTER TABLE iam.company DROP CONSTRAINT IF EXISTS company_company_type_check;
ALTER TABLE iam.company ADD CONSTRAINT company_company_type_check
  CHECK (company_type IN ('CARRIER', 'INDIVIDUAL_OPERATOR', 'FOREIGN_CARRIER', 'AGENCY', 'PARTNER', 'SCHOOL', 'GOVERNMENT',
                          'STATION_OPERATOR'));

INSERT INTO ref.party_role_type (code, name, module, is_system, sort) VALUES
  ('STATION_OPERATOR', 'Station operating company', 'core', true, 65)
ON CONFLICT (code) DO NOTHING;

-- 2. the counter staff's permission, and the role template of an operating company's staff ----------------------------------
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('station.counter', 'station', 'COMPANY', 'Work at the station counters, for the carriers that gave the operating company its rights', false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role (code, name, scope, is_system)
SELECT 'STATION_COUNTER', 'Station counter agent (template)', 'COMPANY', true
 WHERE NOT EXISTS (SELECT 1 FROM iam.role WHERE code = 'STATION_COUNTER' AND company_id IS NULL);
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'station.counter' FROM iam.role r WHERE r.code = 'STATION_COUNTER'
ON CONFLICT DO NOTHING;

-- 3. two-factor sign-in: the station portal is a staff portal and follows the carrier portal's rule (1075). A policy in
-- which the security officers no longer require it for the carrier portal is left as they set it.
UPDATE sys.setting
   SET value = jsonb_set(value, '{required_portals}', (value -> 'required_portals') || '["STATION"]'::jsonb),
       updated_at = now()
 WHERE key = 'auth.mfa'
   AND (value -> 'required_portals') ? 'OPERATOR'
   AND NOT (value -> 'required_portals') ? 'STATION';

-- =====================================================================
-- 1150: two sign-in doors, bank style for companies (owner's request N16)
--   * Individuals (passengers) sign in with their e-mail or mobile number and password.
--   * Businesses (carriers, agencies, station operators and the platform's own staff) sign in with the company
--     number, the employee's username and the password, then the second factor. No portal picker: the company's kind
--     decides the portal.
--   * Every company has a public company number (iam.company.company_no); the platform has its own (setting
--     auth.doors.platform_no). A username is unique within its company (iam.app_user.home_company_id; the platform's
--     staff have none). The e-mail of a staff account is contact data, never needed to sign in.
--   * A password set by an administrator is temporary: the employee changes it at the first sign-in, before anything
--     else, and it stops working after auth.doors.temp_password_hours.
--   * Existing staff get a username from their e-mail and their company as home; existing companies get a number.
-- =====================================================================

CREATE SEQUENCE IF NOT EXISTS iam.company_no_seq START 100101;
ALTER TABLE iam.company ADD COLUMN IF NOT EXISTS company_no text;
UPDATE iam.company SET company_no = nextval('iam.company_no_seq')::text WHERE company_no IS NULL;
ALTER TABLE iam.company ALTER COLUMN company_no SET DEFAULT nextval('iam.company_no_seq')::text;
ALTER TABLE iam.company ALTER COLUMN company_no SET NOT NULL;
ALTER TABLE iam.company DROP CONSTRAINT IF EXISTS company_no_ck;
ALTER TABLE iam.company ADD CONSTRAINT company_no_ck CHECK (company_no ~ '^[0-9]{6,8}$');
CREATE UNIQUE INDEX IF NOT EXISTS company_no_uq ON iam.company (company_no);
COMMENT ON COLUMN iam.company.company_no IS 'The public number a company''s staff give at the business sign-in door (1150, N16)';
GRANT USAGE ON SEQUENCE iam.company_no_seq TO masslak_app;

ALTER TABLE iam.app_user
  ADD COLUMN IF NOT EXISTS username                 text CHECK (username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'),
  ADD COLUMN IF NOT EXISTS home_company_id          bigint REFERENCES iam.company(id),
  ADD COLUMN IF NOT EXISTS password_must_change     boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS temp_password_expires_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS app_user_username_uq ON iam.app_user (coalesce(home_company_id, 0), username) WHERE username IS NOT NULL;
CREATE INDEX IF NOT EXISTS app_user_home_company_id_fkx ON iam.app_user (home_company_id) WHERE home_company_id IS NOT NULL;
ALTER TABLE iam.app_user DROP CONSTRAINT IF EXISTS app_user_check;
ALTER TABLE iam.app_user DROP CONSTRAINT IF EXISTS app_user_contact_ck;
ALTER TABLE iam.app_user ADD CONSTRAINT app_user_contact_ck CHECK (mobile IS NOT NULL OR email IS NOT NULL OR username IS NOT NULL);
ALTER TABLE iam.app_user DROP CONSTRAINT IF EXISTS app_user_temp_password_ck;
ALTER TABLE iam.app_user ADD CONSTRAINT app_user_temp_password_ck CHECK (NOT password_must_change OR temp_password_expires_at IS NOT NULL);
COMMENT ON COLUMN iam.app_user.username IS 'The employee''s sign-in name, unique within the company (home_company_id) or among the platform''s staff (1150, N16)';
COMMENT ON COLUMN iam.app_user.password_must_change IS 'The password was set by an administrator: changed at the first sign-in before anything else (1150)';

INSERT INTO sys.setting (key, value, description) VALUES
  ('auth.doors', jsonb_build_object('platform_no', '100000', 'temp_password_hours', 72, 'legacy_portal_login', true),
   'Sign-in doors (N16, 1150): the platform''s own company number, how long a temporary password lasts, and whether the older sign-in with a portal picker still answers (turned off at the public launch)')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------ a username for every staff account
CREATE OR REPLACE FUNCTION iam.username_from(p_email text, p_company bigint, p_self bigint)
RETURNS text LANGUAGE plpgsql STABLE SET search_path = pg_catalog, iam AS $$
DECLARE base text; candidate text; n int := 1;
BEGIN
  base := left(regexp_replace(lower(coalesce(split_part(p_email, '@', 1), '')), '[^a-z0-9._-]', '', 'g'), 24);
  base := regexp_replace(base, '^[._-]+', '');
  IF length(base) < 3 THEN base := 'user' || coalesce(p_self, 0); END IF;
  candidate := base;
  WHILE EXISTS (SELECT 1 FROM iam.app_user u WHERE coalesce(u.home_company_id, 0) = coalesce(p_company, 0)
                  AND u.username = candidate AND u.id IS DISTINCT FROM p_self) LOOP
    n := n + 1;
    candidate := base || n;
  END LOOP;
  RETURN candidate;
END $$;
COMMENT ON FUNCTION iam.username_from(text, bigint, bigint) IS 'A free username in the company, from the e-mail''s local part (1150)';

-- the platform's staff: a username when made; a company's staff: home company and username when they join it
CREATE OR REPLACE FUNCTION iam.tg_platform_username() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.account_kind = 'PLATFORM' AND NEW.username IS NULL THEN
    NEW.username := iam.username_from(NEW.email, NULL, NEW.id);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_platform_username ON iam.app_user;
CREATE TRIGGER b_platform_username BEFORE INSERT ON iam.app_user FOR EACH ROW EXECUTE FUNCTION iam.tg_platform_username();

CREATE OR REPLACE FUNCTION iam.tg_member_home() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE iam.app_user u
     SET home_company_id = NEW.company_id,
         username = coalesce(u.username, iam.username_from(u.email, NEW.company_id, u.id))
   WHERE u.id = NEW.user_id AND u.home_company_id IS NULL AND u.account_kind IN ('COMPANY', 'AGENCY');
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS z_member_home ON iam.company_member;
CREATE TRIGGER z_member_home AFTER INSERT ON iam.company_member FOR EACH ROW EXECUTE FUNCTION iam.tg_member_home();

-- existing accounts
UPDATE iam.app_user u SET username = iam.username_from(u.email, NULL, u.id)
 WHERE u.account_kind = 'PLATFORM' AND u.username IS NULL;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT DISTINCT ON (m.user_id) m.user_id, m.company_id FROM iam.company_member m JOIN iam.app_user u ON u.id = m.user_id
            WHERE u.home_company_id IS NULL AND u.account_kind IN ('COMPANY', 'AGENCY')
            ORDER BY m.user_id, m.is_owner DESC, m.company_id LOOP
    UPDATE iam.app_user u SET home_company_id = r.company_id, username = coalesce(u.username, iam.username_from(u.email, r.company_id, u.id))
     WHERE u.id = r.user_id;
  END LOOP;
END $$;

-- =====================================================================
-- 1149: a person's name in parts, in Arabic and as in the passport; the sign-up form (owner's requests N4, N35)
--   * Every person's name is kept in parts: first, father, grandfather, family, and the mother's name if given, in the
--     script of the identity document (iam.party), and the same parts in Latin letters as in the passport. legal_name
--     stays the full name as one text, written from the parts.
--   * Which parts are required follows the nationality, as a platform setting (identity.name_rules): a Syrian gives at
--     least the first, father's and family names (the grandfather's is optional); others give first and family names,
--     and their Latin name too. Latin names become required for Syrians on domestic trips by the same setting, the day
--     the national ID records them.
--   * Passengers carry the Latin parts as well; an international trip needs them, as in the passport.
--   * Accounts made before this file, or with one name only, are asked for their name parts at the next sign-in
--     (names_complete is false until then).
--   * The e-mail of a new account is confirmed by a code sent to it (iam.contact_code); until then, and until its KYC
--     is approved, the person is UNVERIFIED (iam.party.verification_status), which is enough to book.
-- =====================================================================

ALTER TABLE iam.party
  ADD COLUMN IF NOT EXISTS first_name             text CHECK (length(first_name) BETWEEN 1 AND 60),
  ADD COLUMN IF NOT EXISTS father_name            text CHECK (length(father_name) BETWEEN 1 AND 60),
  ADD COLUMN IF NOT EXISTS grandfather_name       text CHECK (length(grandfather_name) BETWEEN 1 AND 60),
  ADD COLUMN IF NOT EXISTS last_name              text CHECK (length(last_name) BETWEEN 1 AND 60),
  ADD COLUMN IF NOT EXISTS mother_name            text CHECK (length(mother_name) BETWEEN 1 AND 60),
  ADD COLUMN IF NOT EXISTS first_name_latin       text CHECK (first_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  ADD COLUMN IF NOT EXISTS father_name_latin      text CHECK (father_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  ADD COLUMN IF NOT EXISTS grandfather_name_latin text CHECK (grandfather_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  ADD COLUMN IF NOT EXISTS last_name_latin        text CHECK (last_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  ADD COLUMN IF NOT EXISTS names_complete         boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN iam.party.first_name IS 'Name parts in the script of the identity document; legal_name is written from them (1149, N4)';
COMMENT ON COLUMN iam.party.first_name_latin IS 'Name parts in Latin letters as in the passport (1149, N4)';
COMMENT ON COLUMN iam.party.names_complete IS 'The person gave the name parts their nationality requires; false asks for them at the next sign-in (1149)';

ALTER TABLE sales.passenger
  ADD COLUMN IF NOT EXISTS first_name_latin       text CHECK (first_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  ADD COLUMN IF NOT EXISTS father_name_latin      text CHECK (father_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  ADD COLUMN IF NOT EXISTS grandfather_name_latin text CHECK (grandfather_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  ADD COLUMN IF NOT EXISTS last_name_latin        text CHECK (last_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$');
COMMENT ON COLUMN sales.passenger.first_name_latin IS 'Name parts in Latin letters as in the passport; required on international trips (1149, N4)';

ALTER TABLE iam.app_user ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;
COMMENT ON COLUMN iam.app_user.email_verified_at IS 'When the account confirmed its e-mail with the code sent to it (1149, N35)';

INSERT INTO sys.setting (key, value, description) VALUES
  ('identity.name_rules', jsonb_build_object(
      'SY', jsonb_build_object('required', jsonb_build_array('first', 'father', 'last'), 'latin_required', false),
      'OTHER', jsonb_build_object('required', jsonb_build_array('first', 'last'), 'latin_required', true),
      'latin_required_domestic', false,
      'email_code_minutes', 30),
   'Name parts each nationality must give (SY: first, father and family; others: first and family, with the Latin name), whether Latin names are required on domestic trips, and how long an e-mail code lasts (1149, N4, N35)')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------ codes sent to confirm an e-mail or a mobile number
CREATE TABLE IF NOT EXISTS iam.contact_code (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid         uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  channel     text NOT NULL CHECK (channel IN ('EMAIL', 'MOBILE')),
  purpose     text NOT NULL CHECK (purpose IN ('VERIFY_CONTACT')),
  code_hash   bytea NOT NULL CHECK (octet_length(code_hash) = 32),
  attempts    smallint NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
  expires_at  timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contact_code_window_ck CHECK (expires_at > created_at AND expires_at <= created_at + interval '24 hours')
);
CREATE UNIQUE INDEX IF NOT EXISTS contact_code_uid_uq ON iam.contact_code (uid);
CREATE INDEX IF NOT EXISTS contact_code_user_id_fkx ON iam.contact_code (user_id, created_at DESC);
COMMENT ON TABLE iam.contact_code IS 'A code sent to confirm an account''s e-mail (or mobile): only its keyed hash is kept, used once, five tries (1149, N35)';
SELECT sys.rls_parent('iam.contact_code', 'user_id', 'iam.app_user');
GRANT SELECT, INSERT, UPDATE ON iam.contact_code TO masslak_app;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('iam.contact_code', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.contact_code', 'iam records', 'codes that confirm an account''s e-mail or mobile (1149)')
ON CONFLICT (table_name) DO NOTHING;

-- ------------------------------------------------------------------ existing people: the parts found in their name
-- A passenger account's one-text name is split on spaces as a first guess (first word, last word); the person is still
-- asked to confirm the parts at the next sign-in, since a guess is not a name as in the document.
UPDATE iam.party p
   SET first_name = split_part(btrim(legal_name), ' ', 1),
       last_name  = CASE WHEN position(' ' IN btrim(legal_name)) > 0
                         THEN regexp_replace(btrim(legal_name), '^.* ', '') END
 WHERE party_type = 'PERSON' AND first_name IS NULL AND length(btrim(coalesce(legal_name, ''))) BETWEEN 1 AND 120
   AND length(split_part(btrim(legal_name), ' ', 1)) BETWEEN 1 AND 60
   AND length(regexp_replace(btrim(legal_name), '^.* ', '')) BETWEEN 1 AND 60;

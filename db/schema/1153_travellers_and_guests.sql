-- =====================================================================
-- 1153: the traveller "Me", saved travellers and booking without an account (owner's request N18)
--   * A registered passenger is not asked again for what the account already holds: the first traveller can be "Me",
--     filled from the account's name parts (1149), date of birth, gender and identity document. The document number is
--     kept on the person encrypted, with its expiry.
--   * Saved travellers: companions a passenger books for again (friends, colleagues), kept with the passenger's consent,
--     document number encrypted. Family members (4.20) stay a separate register with their own rules.
--   * Booking without an account (phase 1 decision): a guest proves an e-mail address with a code and books under a
--     guest account that has no password; after booking the guest may turn it into a full account. A setting can later
--     require an account from citizens (account_required_for = CITIZENS).
-- =====================================================================

ALTER TABLE iam.party ADD COLUMN IF NOT EXISTS id_expiry date;
COMMENT ON COLUMN iam.party.id_expiry IS 'Expiry of the person''s identity document (passport validity on international trips; 1153, N18)';

ALTER TABLE iam.app_user ADD COLUMN IF NOT EXISTS is_guest boolean NOT NULL DEFAULT false;
ALTER TABLE iam.app_user DROP CONSTRAINT IF EXISTS app_user_guest_ck;
ALTER TABLE iam.app_user ADD CONSTRAINT app_user_guest_ck
  CHECK (NOT is_guest OR (account_kind = 'CUSTOMER' AND password_hash IS NULL AND email IS NOT NULL));
COMMENT ON COLUMN iam.app_user.is_guest IS 'A guest who booked without an account: signed in by a code sent to the e-mail, no password, until turned into a full account (1153, N18)';

ALTER TABLE iam.contact_code DROP CONSTRAINT IF EXISTS contact_code_purpose_check;
ALTER TABLE iam.contact_code ADD CONSTRAINT contact_code_purpose_check CHECK (purpose IN ('VERIFY_CONTACT', 'GUEST_SIGN_IN'));

-- ------------------------------------------------------------------ saved travellers
CREATE TABLE IF NOT EXISTS iam.saved_traveller (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                    uuid NOT NULL DEFAULT gen_random_uuid(),
  owner_user_id          bigint NOT NULL REFERENCES iam.app_user(id),
  label                  text CHECK (label IS NULL OR length(label) BETWEEN 1 AND 40),
  nationality            char(2) NOT NULL DEFAULT 'SY' REFERENCES ref.country(code),
  first_name             text NOT NULL CHECK (length(first_name) BETWEEN 1 AND 60),
  father_name            text CHECK (father_name IS NULL OR length(father_name) BETWEEN 1 AND 60),
  grandfather_name       text CHECK (grandfather_name IS NULL OR length(grandfather_name) BETWEEN 1 AND 60),
  last_name              text NOT NULL CHECK (length(last_name) BETWEEN 1 AND 60),
  first_name_latin       text CHECK (first_name_latin IS NULL OR first_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  father_name_latin      text CHECK (father_name_latin IS NULL OR father_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  grandfather_name_latin text CHECK (grandfather_name_latin IS NULL OR grandfather_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  last_name_latin        text CHECK (last_name_latin IS NULL OR last_name_latin ~ '^[A-Za-z][A-Za-z ''.-]{0,59}$'),
  birth_date             date CHECK (birth_date IS NULL OR birth_date > DATE '1900-01-01'),
  gender                 text CHECK (gender IN ('M','F')),
  id_type                text CHECK (id_type IN ('NATIONAL_ID','PASSPORT','RESIDENCE','LAISSEZ_PASSER','TRAVEL_DOCUMENT','OTHER')),
  id_no_enc              bytea,
  id_no_bidx             bytea,
  id_no_last4            text CHECK (id_no_last4 IS NULL OR id_no_last4 ~ '^[0-9A-Za-z]{3,4}$'),
  id_expiry              date,
  enc_key_id             int REFERENCES sec.key_registry(id),
  consent_at             timestamptz NOT NULL DEFAULT now(),
  status                 text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','REMOVED')),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT saved_traveller_doc_ck CHECK (id_no_enc IS NULL OR (id_no_bidx IS NOT NULL AND enc_key_id IS NOT NULL AND id_type IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS saved_traveller_uid_uq ON iam.saved_traveller (uid);
CREATE INDEX IF NOT EXISTS saved_traveller_owner_user_id_fkx ON iam.saved_traveller (owner_user_id) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS saved_traveller_enc_key_id_fkx ON iam.saved_traveller (enc_key_id);
CREATE INDEX IF NOT EXISTS saved_traveller_nationality_fkx ON iam.saved_traveller (nationality);
DROP TRIGGER IF EXISTS saved_traveller_updated ON iam.saved_traveller;
CREATE TRIGGER saved_traveller_updated BEFORE UPDATE ON iam.saved_traveller FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE iam.saved_traveller IS
  'Companions a passenger books for again, kept with the passenger''s consent; the document number encrypted with a blind index and the last four shown (1153, N18)';
SELECT sys.rls_parent('iam.saved_traveller', 'owner_user_id', 'iam.app_user');
ALTER TABLE iam.saved_traveller FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON iam.saved_traveller TO masslak_app;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('iam.saved_traveller', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.saved_traveller', 'iam personal records', 'companions a passenger saved to book for again: names and an encrypted document (1153)')
ON CONFLICT (table_name) DO NOTHING;

-- ------------------------------------------------------------------ the guest booking setting
INSERT INTO sys.setting (key, value, description) VALUES
  ('booking.guest', jsonb_build_object('enabled', true, 'account_required_for', 'NONE', 'code_minutes', 15),
   'Booking without an account (N18, 1153): whether guests may book (phase 1: yes), who must hold an account (NONE, or CITIZENS: travellers of the market''s own nationality), and how long the e-mail code lasts')
ON CONFLICT (key) DO NOTHING;

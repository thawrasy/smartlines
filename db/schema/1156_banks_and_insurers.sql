-- =====================================================================
-- 1156: bank and insurer registries (owner's requests N6 and N9)
--   * Platform staff enter Syrian banks (and later their branches) and insurance companies; another person reviews an
--     entry before it shows in the companies' pickers, and a change to a reviewed entry waits as a proposal until a second
--     person accepts it (maker-checker, as in KYC). Information only: no documents.
--   * Nothing is verified until fully verified: the owner's phase-1 tables are an entry reference (UNVERIFIED); a SWIFT
--     code has its own status (TO_VERIFY / VERIFIED / INVALID).
--   * A company keeps several bank accounts, one default; each picks a bank and a branch ("head office" until branches
--     are loaded), its SWIFT filled from them, the account number and IBAN encrypted; each account has a verification
--     status, ready for a future bank or Central Bank gateway that returns the real holder's name.
--   * The central bank stays in the registry and is hidden from companies' pickers; so is reinsurance among insurers.
-- =====================================================================

-- ------------------------------------------------------------------ banks
CREATE TABLE IF NOT EXISTS ref.bank (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid(),
  code                text NOT NULL CHECK (code ~ '^[A-Z0-9]{2,12}$'),
  name_ar             text NOT NULL CHECK (length(name_ar) BETWEEN 2 AND 160),
  name_en             text NOT NULL CHECK (length(name_en) BETWEEN 2 AND 160),
  short_name          text CHECK (short_name IS NULL OR length(short_name) BETWEEN 2 AND 40),
  bank_type           text NOT NULL DEFAULT 'PRIVATE' CHECK (bank_type IN ('CENTRAL', 'PUBLIC', 'PRIVATE', 'ISLAMIC')),
  swift_bic           text CHECK (swift_bic IS NULL OR swift_bic ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$'),
  swift_status        text NOT NULL DEFAULT 'TO_VERIFY' CHECK (swift_status IN ('TO_VERIFY', 'VERIFIED', 'INVALID')),
  swift_reported      text CHECK (swift_reported IS NULL OR length(swift_reported) BETWEEN 4 AND 20),
  iban_bank_code        text CHECK (iban_bank_code IS NULL OR iban_bank_code ~ '^[0-9A-Z]{2,10}$'),
  address             jsonb NOT NULL DEFAULT '{}',
  phone               text CHECK (phone IS NULL OR length(phone) BETWEEN 5 AND 40),
  fax                 text CHECK (fax IS NULL OR length(fax) BETWEEN 5 AND 40),
  email               text CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  website             text CHECK (website IS NULL OR website ~ '^https?://'),
  hidden_from_companies boolean NOT NULL DEFAULT false,
  notes               text CHECK (notes IS NULL OR length(notes) <= 1000),
  status              text NOT NULL DEFAULT 'PENDING_REVIEW' CHECK (status IN ('PENDING_REVIEW', 'ACTIVE', 'REJECTED', 'RETIRED')),
  verification_status text NOT NULL DEFAULT 'UNVERIFIED' CHECK (verification_status IN ('UNVERIFIED', 'VERIFIED')),
  source              text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL', 'IMPORT')),
  entered_by          bigint NOT NULL REFERENCES iam.app_user(id),
  reviewed_by         bigint REFERENCES iam.app_user(id),
  reviewed_at         timestamptz,
  pending_changes     jsonb,
  pending_by          bigint REFERENCES iam.app_user(id),
  pending_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bank_review_ck CHECK (reviewed_by IS NULL OR reviewed_by <> entered_by),
  CONSTRAINT bank_pending_ck CHECK ((pending_changes IS NULL) = (pending_by IS NULL)),
  CONSTRAINT bank_active_ck CHECK (status <> 'ACTIVE' OR reviewed_by IS NOT NULL),
  CONSTRAINT bank_central_ck CHECK (bank_type <> 'CENTRAL' OR hidden_from_companies)
);
CREATE UNIQUE INDEX IF NOT EXISTS bank_uid_uq ON ref.bank (uid);
CREATE UNIQUE INDEX IF NOT EXISTS bank_code_uq ON ref.bank (code);
CREATE UNIQUE INDEX IF NOT EXISTS bank_swift_uq ON ref.bank (swift_bic) WHERE swift_bic IS NOT NULL AND status <> 'REJECTED';
CREATE INDEX IF NOT EXISTS bank_entered_by_fkx ON ref.bank (entered_by);
CREATE INDEX IF NOT EXISTS bank_reviewed_by_fkx ON ref.bank (reviewed_by);
CREATE INDEX IF NOT EXISTS bank_pending_by_fkx ON ref.bank (pending_by);
COMMENT ON TABLE ref.bank IS
  'Banks entered by platform staff and reviewed by another person before companies see them; UNVERIFIED until fully verified (1156, N6)';
COMMENT ON COLUMN ref.bank.swift_reported IS 'A code given by the source that is not a valid SWIFT/BIC, kept for the follow-up with the bank';
COMMENT ON COLUMN ref.bank.pending_changes IS 'A change proposed to a reviewed bank: applied only when a second person accepts it';

CREATE TABLE IF NOT EXISTS ref.bank_branch (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid(),
  bank_id             bigint NOT NULL REFERENCES ref.bank(id),
  name_ar             text NOT NULL CHECK (length(name_ar) BETWEEN 2 AND 160),
  name_en             text NOT NULL CHECK (length(name_en) BETWEEN 2 AND 160),
  branch_code         text CHECK (branch_code IS NULL OR branch_code ~ '^[0-9A-Z]{1,12}$'),
  swift_bic           text CHECK (swift_bic IS NULL OR swift_bic ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$'),
  is_head_office      boolean NOT NULL DEFAULT false,
  area_id             bigint REFERENCES ref.admin_area(id),
  address             jsonb NOT NULL DEFAULT '{}',
  lat                 numeric(9,6) CHECK (lat IS NULL OR lat BETWEEN -90 AND 90),
  lng                 numeric(9,6) CHECK (lng IS NULL OR lng BETWEEN -180 AND 180),
  phone               text CHECK (phone IS NULL OR length(phone) BETWEEN 5 AND 40),
  email               text CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  status              text NOT NULL DEFAULT 'PENDING_REVIEW' CHECK (status IN ('PENDING_REVIEW', 'ACTIVE', 'REJECTED', 'RETIRED')),
  verification_status text NOT NULL DEFAULT 'UNVERIFIED' CHECK (verification_status IN ('UNVERIFIED', 'VERIFIED')),
  entered_by          bigint NOT NULL REFERENCES iam.app_user(id),
  reviewed_by         bigint REFERENCES iam.app_user(id),
  reviewed_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bank_branch_review_ck CHECK (reviewed_by IS NULL OR reviewed_by <> entered_by),
  CONSTRAINT bank_branch_active_ck CHECK (status <> 'ACTIVE' OR reviewed_by IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS bank_branch_uid_uq ON ref.bank_branch (uid);
CREATE UNIQUE INDEX IF NOT EXISTS bank_branch_code_uq ON ref.bank_branch (bank_id, branch_code) WHERE branch_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS bank_branch_head_uq ON ref.bank_branch (bank_id) WHERE is_head_office AND status <> 'REJECTED';
CREATE INDEX IF NOT EXISTS bank_branch_bank_id_fkx ON ref.bank_branch (bank_id);
CREATE INDEX IF NOT EXISTS bank_branch_area_id_fkx ON ref.bank_branch (area_id);
CREATE INDEX IF NOT EXISTS bank_branch_entered_by_fkx ON ref.bank_branch (entered_by);
CREATE INDEX IF NOT EXISTS bank_branch_reviewed_by_fkx ON ref.bank_branch (reviewed_by);
COMMENT ON TABLE ref.bank_branch IS 'Branches of a bank with their own codes and addresses (phase 2); reviewed by a second person (1156, N6)';

-- ------------------------------------------------------------------ insurers
CREATE TABLE IF NOT EXISTS ref.insurer (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid(),
  code                text NOT NULL CHECK (code ~ '^[A-Z0-9]{2,12}$'),
  name_ar             text NOT NULL CHECK (length(name_ar) BETWEEN 2 AND 160),
  name_en             text NOT NULL CHECK (length(name_en) BETWEEN 2 AND 160),
  ownership           text NOT NULL DEFAULT 'PRIVATE' CHECK (ownership IN ('PUBLIC', 'PRIVATE')),
  insurance_kind      text NOT NULL DEFAULT 'CONVENTIONAL' CHECK (insurance_kind IN ('CONVENTIONAL', 'TAKAFUL', 'REINSURANCE')),
  licence_no          text CHECK (licence_no IS NULL OR length(licence_no) BETWEEN 2 AND 40),
  address             jsonb NOT NULL DEFAULT '{}',
  lat                 numeric(9,6) CHECK (lat IS NULL OR lat BETWEEN -90 AND 90),
  lng                 numeric(9,6) CHECK (lng IS NULL OR lng BETWEEN -180 AND 180),
  phone               text CHECK (phone IS NULL OR length(phone) BETWEEN 5 AND 40),
  fax                 text CHECK (fax IS NULL OR length(fax) BETWEEN 5 AND 40),
  email               text CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  website             text CHECK (website IS NULL OR website ~ '^https?://'),
  hidden_from_companies boolean NOT NULL DEFAULT false,
  notes               text CHECK (notes IS NULL OR length(notes) <= 1000),
  status              text NOT NULL DEFAULT 'PENDING_REVIEW' CHECK (status IN ('PENDING_REVIEW', 'ACTIVE', 'REJECTED', 'RETIRED')),
  verification_status text NOT NULL DEFAULT 'UNVERIFIED' CHECK (verification_status IN ('UNVERIFIED', 'VERIFIED')),
  source              text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL', 'IMPORT')),
  entered_by          bigint NOT NULL REFERENCES iam.app_user(id),
  reviewed_by         bigint REFERENCES iam.app_user(id),
  reviewed_at         timestamptz,
  pending_changes     jsonb,
  pending_by          bigint REFERENCES iam.app_user(id),
  pending_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT insurer_review_ck CHECK (reviewed_by IS NULL OR reviewed_by <> entered_by),
  CONSTRAINT insurer_pending_ck CHECK ((pending_changes IS NULL) = (pending_by IS NULL)),
  CONSTRAINT insurer_active_ck CHECK (status <> 'ACTIVE' OR reviewed_by IS NOT NULL),
  CONSTRAINT insurer_reinsurance_ck CHECK (insurance_kind <> 'REINSURANCE' OR hidden_from_companies)
);
CREATE UNIQUE INDEX IF NOT EXISTS insurer_uid_uq ON ref.insurer (uid);
CREATE UNIQUE INDEX IF NOT EXISTS insurer_code_uq ON ref.insurer (code);
CREATE INDEX IF NOT EXISTS insurer_entered_by_fkx ON ref.insurer (entered_by);
CREATE INDEX IF NOT EXISTS insurer_reviewed_by_fkx ON ref.insurer (reviewed_by);
CREATE INDEX IF NOT EXISTS insurer_pending_by_fkx ON ref.insurer (pending_by);
COMMENT ON TABLE ref.insurer IS
  'Insurance companies entered by platform staff and reviewed by another person; carriers pick their insurer from it (1156, N9)';

DROP TRIGGER IF EXISTS bank_updated ON ref.bank;
CREATE TRIGGER bank_updated BEFORE UPDATE ON ref.bank FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
DROP TRIGGER IF EXISTS bank_branch_updated ON ref.bank_branch;
CREATE TRIGGER bank_branch_updated BEFORE UPDATE ON ref.bank_branch FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
DROP TRIGGER IF EXISTS insurer_updated ON ref.insurer;
CREATE TRIGGER insurer_updated BEFORE UPDATE ON ref.insurer FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();

-- every signed-in user reads (companies see only reviewed, visible rows through the API); only the platform writes
SELECT sys.rls('ref.bank', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('ref.bank_branch', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('ref.insurer', 'true', 'sys.ctx_is_platform()');
GRANT SELECT, INSERT, UPDATE ON ref.bank, ref.bank_branch, ref.insurer TO masslak_app;

-- ------------------------------------------------------------------ company bank accounts
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS bank_id bigint REFERENCES ref.bank(id);
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS branch_id bigint REFERENCES ref.bank_branch(id);
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS swift_bic text;
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS account_no_enc bytea;
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS account_no_last4 text;
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS is_default boolean NOT NULL DEFAULT false;
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS verification_status text NOT NULL DEFAULT 'UNVERIFIED';
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS verification_source text;
ALTER TABLE iam.bank_account ADD COLUMN IF NOT EXISTS verified_holder_name text;
UPDATE iam.bank_account SET verification_status = 'VERIFIED_MANUAL', verification_source = 'platform review before 1156'
 WHERE verified AND verification_status = 'UNVERIFIED';
ALTER TABLE iam.bank_account DROP CONSTRAINT IF EXISTS bank_account_verification_ck;
ALTER TABLE iam.bank_account ADD CONSTRAINT bank_account_verification_ck
  CHECK (verification_status IN ('UNVERIFIED', 'VERIFIED_BY_GATEWAY', 'VERIFIED_MANUAL', 'REJECTED'));
ALTER TABLE iam.bank_account DROP CONSTRAINT IF EXISTS bank_account_swift_ck;
ALTER TABLE iam.bank_account ADD CONSTRAINT bank_account_swift_ck
  CHECK (swift_bic IS NULL OR swift_bic ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$');
ALTER TABLE iam.bank_account DROP CONSTRAINT IF EXISTS bank_account_number_ck;
ALTER TABLE iam.bank_account ADD CONSTRAINT bank_account_number_ck
  CHECK ((account_no_enc IS NULL) = (account_no_last4 IS NULL) AND (account_no_last4 IS NULL OR account_no_last4 ~ '^[0-9A-Z]{2,4}$'));
ALTER TABLE iam.bank_account DROP CONSTRAINT IF EXISTS bank_account_branch_ck;
ALTER TABLE iam.bank_account ADD CONSTRAINT bank_account_branch_ck CHECK (branch_id IS NULL OR bank_id IS NOT NULL);
-- a company never decides its own account's verification (997 guarded "verified"; 1156 adds the status, its source and
-- the holder name a gateway returned)
CREATE OR REPLACE FUNCTION iam.tg_bank_account_verify() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT sys.ctx_is_platform() AND
     ((TG_OP = 'INSERT' AND (NEW.verified OR NEW.verification_status <> 'UNVERIFIED' OR NEW.verified_holder_name IS NOT NULL
                             OR NEW.verification_source IS NOT NULL))
      OR (TG_OP = 'UPDATE' AND (NEW.verified IS DISTINCT FROM OLD.verified OR NEW.verification_status IS DISTINCT FROM OLD.verification_status
                                OR NEW.verified_holder_name IS DISTINCT FROM OLD.verified_holder_name
                                OR NEW.verification_source IS DISTINCT FROM OLD.verification_source))) THEN
    RAISE EXCEPTION 'FORBIDDEN: only platform finance verifies bank accounts' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

-- one default account per company
UPDATE iam.bank_account a SET is_default = true
 WHERE status = 'ACTIVE' AND NOT EXISTS (SELECT 1 FROM iam.bank_account b WHERE b.party_id = a.party_id AND b.is_default)
   AND a.id = (SELECT min(id) FROM iam.bank_account c WHERE c.party_id = a.party_id AND c.status = 'ACTIVE');
CREATE UNIQUE INDEX IF NOT EXISTS bank_account_default_uq ON iam.bank_account (party_id) WHERE is_default AND status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS bank_account_bank_id_fkx ON iam.bank_account (bank_id);
CREATE INDEX IF NOT EXISTS bank_account_branch_id_fkx ON iam.bank_account (branch_id);
COMMENT ON COLUMN iam.bank_account.bank_name IS 'The bank''s name as written (old rows); new rows copy it from ref.bank';
COMMENT ON COLUMN iam.bank_account.verification_status IS
  'UNVERIFIED until a bank gateway (VERIFIED_BY_GATEWAY, with the holder name it returned) or platform staff (VERIFIED_MANUAL) confirm it (1156, N6)';

INSERT INTO sys.setting (key, value, description) VALUES
  ('payouts.accounts', jsonb_build_object('verified_only', false, 'verification_gateway', 'NONE'),
   'Bank accounts for payouts (N6, 1156): whether payouts go only to verified accounts (false at launch) and which account verification gateway answers (NONE until a bank or Central Bank gateway exists)')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------ insurance policies pick the insurer
ALTER TABLE fleet.insurance_policy ADD COLUMN IF NOT EXISTS insurer_id bigint REFERENCES ref.insurer(id);
CREATE INDEX IF NOT EXISTS insurance_policy_insurer_id_fkx ON fleet.insurance_policy (insurer_id);
COMMENT ON COLUMN fleet.insurance_policy.insurer_id IS 'The insurer chosen from the platform''s registry (1156, N9); insurer_name keeps the written name of old rows';

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ref.bank', '1A', 'E01'), ('ref.bank_branch', '1A', 'E01'), ('ref.insurer', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ref.bank', 'ref catalog', 'banks of the registry (1156)'),
  ('ref.bank_branch', 'ref catalog', 'bank branches (1156)'),
  ('ref.insurer', 'ref catalog', 'insurance companies of the registry (1156)')
ON CONFLICT (table_name) DO NOTHING;

-- ------------------------------------------------------------------ the right to keep the registries
-- reference.manage (reference data) now also covers the registries; a second person still reviews every entry
UPDATE iam.permission
   SET description = 'Reference data: currencies, exchange rates, type catalogues, and the registries of banks and insurers (a second person reviews)'
 WHERE code = 'reference.manage';
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, x.p FROM iam.role r JOIN (VALUES
  ('PLATFORM_ADMIN', 'reference.manage'), ('PLATFORM_OPERATIONS', 'reference.manage'), ('PLATFORM_FINANCE', 'reference.manage'),
  ('PLATFORM_COMPLIANCE', 'reference.manage')
) AS x(code, p) ON x.code = r.code AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- a policy whose insurer is chosen from the registry carries its name (the written name stays for old rows); the insurer
-- must be reviewed and shown to companies
CREATE OR REPLACE FUNCTION fleet.tg_insurance_policy_insurer() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_name text;
BEGIN
  IF NEW.insurer_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.insurer_id IS DISTINCT FROM OLD.insurer_id) THEN
    SELECT name_en INTO v_name FROM ref.insurer WHERE id = NEW.insurer_id AND status = 'ACTIVE' AND NOT hidden_from_companies;
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'INSURER_UNKNOWN: choose a reviewed insurance company from the registry' USING ERRCODE = 'P0001';
    END IF;
    NEW.insurer_name := v_name;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS insurance_policy_insurer ON fleet.insurance_policy;
CREATE TRIGGER insurance_policy_insurer BEFORE INSERT OR UPDATE OF insurer_id ON fleet.insurance_policy
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_insurance_policy_insurer();
ALTER TABLE fleet.insurance_policy ALTER COLUMN insurer_name DROP NOT NULL;
ALTER TABLE fleet.insurance_policy DROP CONSTRAINT IF EXISTS insurance_policy_insurer_ck;
ALTER TABLE fleet.insurance_policy ADD CONSTRAINT insurance_policy_insurer_ck CHECK (insurer_id IS NOT NULL OR insurer_name IS NOT NULL);

INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('ref.bank', 'address', 'CONTACT', 1, '{"type": "object"}'::jsonb, 'the bank''s address lines as given (governorate, city, street) (1156)'),
  ('ref.bank', 'pending_changes', 'SHAPE', 1, '{"type": "object"}'::jsonb, 'the fields a proposed change sets, applied when a second person accepts it (1156)'),
  ('ref.bank_branch', 'address', 'CONTACT', 1, '{"type": "object"}'::jsonb, 'the branch''s address lines (1156)'),
  ('ref.insurer', 'address', 'CONTACT', 1, '{"type": "object"}'::jsonb, 'the insurer''s address lines as given (1156)'),
  ('ref.insurer', 'pending_changes', 'SHAPE', 1, '{"type": "object"}'::jsonb, 'the fields a proposed change sets, applied when a second person accepts it (1156)')
ON CONFLICT DO NOTHING;

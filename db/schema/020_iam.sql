-- =====================================================================
-- 020: identity, parties, companies, users, permissions and API clients
-- Source: 4.2, 3.4, 3.5, 3.8, 16.8, 16.18
-- Restricted fields are stored encrypted with AES-256-GCM in *_enc columns
-- with a blind index *_bidx (HMAC-SHA256) for lookup and uniqueness without revealing the value.
-- =====================================================================

-- ------------------------------ Parties -------------------------------
CREATE TABLE iam.party (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  party_type          text NOT NULL CHECK (party_type IN ('PERSON','COMPANY','ENTITY')),
  legal_name          text NOT NULL,                  -- legal name as registered (any script)
  name_latin          text,                           -- optional Latin-script transliteration
  id_type             text CHECK (id_type IN ('NATIONAL_ID','PASSPORT','RESIDENCE','CR','ENTITY_NO','FOREIGN_ID','OTHER')),
  id_no_enc           bytea,                          -- ID/passport number, encrypted (Restricted)
  id_no_bidx          bytea,                          -- blind index for matching
  id_no_last4         text,                           -- masked display only
  enc_key_id          int REFERENCES sec.key_registry(id),
  nationality         char(2) REFERENCES ref.country(code),
  birth_date          date,
  gender              text CHECK (gender IN ('M','F')),
  mobile              text,                           -- E.164
  email               citext,
  address             jsonb,
  country_code        char(2) NOT NULL DEFAULT 'SY' REFERENCES ref.country(code),
  is_foreign          boolean NOT NULL DEFAULT false,
  national_entity_no  text,                           -- for local entities (4.17)
  tax_no              text,                           -- tax details live in acct.tax_profile
  tax_country         char(2) REFERENCES ref.country(code),
  kyc_level           smallint NOT NULL DEFAULT 0 CHECK (kyc_level BETWEEN 0 AND 3),   -- 3.8: L0..L3
  verification_status text NOT NULL DEFAULT 'UNVERIFIED' CHECK (verification_status IN ('UNVERIFIED','PENDING','VERIFIED','REJECTED')),
  status              text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
  external_ref        text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (id_no_enc IS NULL OR (id_no_bidx IS NOT NULL AND enc_key_id IS NOT NULL))
);
CREATE UNIQUE INDEX party_identity_uq ON iam.party (id_type, id_no_bidx) WHERE id_no_bidx IS NOT NULL;
CREATE INDEX party_mobile_idx ON iam.party (mobile);
CREATE TRIGGER party_updated BEFORE UPDATE ON iam.party FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE iam.party IS 'Unified party: person, company or entity; registered once and holds multiple roles (passenger, driver, vehicle owner...)';

CREATE TABLE iam.party_role (
  party_id    bigint NOT NULL REFERENCES iam.party(id),
  role_code   text NOT NULL CHECK (role_code IN ('PASSENGER','OPERATOR','DRIVER','HOST','OWNER','STATION_STAFF','AGENCY','CHANNEL_PARTNER','INSURER','AUTHORITY')),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','ENDED')),
  valid_from  date NOT NULL DEFAULT current_date,
  valid_to    date,
  PRIMARY KEY (party_id, role_code)
);
COMMENT ON TABLE iam.party_role IS 'Party roles (several roles per party)';

-- ------------------------------ Companies (tenants) ---------------------
CREATE TABLE iam.company (
  id                    bigint PRIMARY KEY REFERENCES iam.party(id),   -- = party.id of the company
  company_type          text NOT NULL DEFAULT 'CARRIER' CHECK (company_type IN ('CARRIER','INDIVIDUAL_OPERATOR','FOREIGN_CARRIER','AGENCY','PARTNER')),
  cr_no                 text,
  cr_expiry             date,
  transport_license_no  text,
  regulator_code        text,                         -- optional Transport Authority code (4.16 d)
  settlement_cycle      text NOT NULL DEFAULT 'WEEKLY' CHECK (settlement_cycle IN ('DAILY','WEEKLY','MONTHLY')),
  approval_status       text NOT NULL DEFAULT 'PENDING' CHECK (approval_status IN ('PENDING','APPROVED','REJECTED','SUSPENDED')),
  approved_by           bigint,                       -- FK added after app_user
  approved_at           timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER company_updated BEFORE UPDATE ON iam.company FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE iam.company IS 'Carrier company (tenant): 1:1 profile with party; all company data is isolated by company_id';

CREATE TABLE iam.beneficial_owner (
  company_id    bigint NOT NULL REFERENCES iam.company(id),
  party_id      bigint NOT NULL REFERENCES iam.party(id),
  ownership_pct numeric(5,2) NOT NULL CHECK (ownership_pct > 0 AND ownership_pct <= 100),
  PRIMARY KEY (company_id, party_id)
);
COMMENT ON TABLE iam.beneficial_owner IS 'Beneficial owners of the company (compliance and security)';

CREATE TABLE iam.bank_account (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  party_id      bigint NOT NULL REFERENCES iam.party(id),
  bank_name     text NOT NULL,
  holder_name   text NOT NULL,
  iban_enc      bytea NOT NULL,
  iban_bidx     bytea NOT NULL,
  iban_last4    text NOT NULL,
  enc_key_id    int NOT NULL REFERENCES sec.key_registry(id),
  currency      char(3) NOT NULL REFERENCES ref.currency(code),
  verified      boolean NOT NULL DEFAULT false,
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (party_id, iban_bidx)
);
COMMENT ON TABLE iam.bank_account IS 'Bank accounts for withdrawals and settlement (encrypted IBAN)';

CREATE TABLE iam.document (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  owner_type    text NOT NULL CHECK (owner_type IN ('PARTY','COMPANY','VEHICLE','STATION','LEASE','INSURANCE','LICENSE','INCIDENT','OTHER')),
  owner_id      bigint NOT NULL,
  doc_type      text NOT NULL,                        -- CR, TAX_CERT, ID_FRONT, ID_BACK, SELFIE, VEHICLE_REG, LEASE_CONTRACT, POLICY ...
  doc_no_enc    bytea,
  doc_no_bidx   bytea,
  enc_key_id    int REFERENCES sec.key_registry(id),
  issuer        text,
  issue_date    date,
  expiry_date   date,
  file_id       bigint REFERENCES ref.file_object(id),
  status        text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED','EXPIRED')),
  reviewed_by   bigint,
  reviewed_at   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX document_owner_idx ON iam.document (owner_type, owner_id);
CREATE INDEX document_expiry_idx ON iam.document (expiry_date) WHERE status = 'APPROVED';
COMMENT ON TABLE iam.document IS 'Documents for any entity (polymorphic reference) with file, review and expiry date';

-- ------------------------------ Users ---------------------------
CREATE TABLE iam.app_user (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  party_id            bigint NOT NULL REFERENCES iam.party(id),
  account_kind        text NOT NULL CHECK (account_kind IN ('PLATFORM','COMPANY','AGENCY','CUSTOMER')),
  mobile              text UNIQUE,
  email               citext UNIQUE,
  password_hash       text,                           -- Argon2id (16.18); empty only for OTP/digital-identity accounts
  password_changed_at timestamptz,
  mfa_required        boolean NOT NULL DEFAULT false,
  status              text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','LOCKED','DISABLED','CLOSED')),
  failed_attempts     int NOT NULL DEFAULT 0,
  locked_until        timestamptz,
  last_login_at       timestamptz,
  last_login_ip       inet,
  preferred_locale    text NOT NULL DEFAULT 'en' REFERENCES ref.locale(code),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (mobile IS NOT NULL OR email IS NOT NULL)
);
CREATE INDEX app_user_party_idx ON iam.app_user (party_id);
CREATE TRIGGER app_user_updated BEFORE UPDATE ON iam.app_user FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE iam.app_user IS 'Login account; the account kind determines the portal: platform, company, agency, customer';

ALTER TABLE iam.company       ADD CONSTRAINT company_approved_by_fk FOREIGN KEY (approved_by) REFERENCES iam.app_user(id);
ALTER TABLE iam.document      ADD CONSTRAINT document_reviewed_by_fk FOREIGN KEY (reviewed_by) REFERENCES iam.app_user(id);
ALTER TABLE ref.file_object   ADD CONSTRAINT file_uploaded_by_fk FOREIGN KEY (uploaded_by) REFERENCES iam.app_user(id);
ALTER TABLE sec.key_registry  ADD CONSTRAINT key_company_fk FOREIGN KEY (company_id) REFERENCES iam.company(id);
ALTER TABLE sys.company_setting ADD CONSTRAINT company_setting_company_fk FOREIGN KEY (company_id) REFERENCES iam.company(id);
ALTER TABLE sys.setting       ADD CONSTRAINT setting_updated_by_fk FOREIGN KEY (updated_by) REFERENCES iam.app_user(id);

-- ------------------------------ Permissions (two-level RBAC) ----------
CREATE TABLE iam.permission (
  code        text PRIMARY KEY,                       -- trip.publish, booking.refund, wallet.payout.approve ...
  module      text NOT NULL,
  scope       text NOT NULL CHECK (scope IN ('PLATFORM','COMPANY','BOTH')),
  description text NOT NULL,
  is_sensitive boolean NOT NULL DEFAULT false        -- requires MFA and a reason, always logged
);
COMMENT ON TABLE iam.permission IS 'Permission catalog (section 33)';

CREATE TABLE iam.role (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL,
  name        text NOT NULL,
  scope       text NOT NULL CHECK (scope IN ('PLATFORM','COMPANY')),
  company_id  bigint REFERENCES iam.company(id),      -- empty = system role/template
  is_system   boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (scope = 'COMPANY' OR company_id IS NULL)
);
CREATE UNIQUE INDEX role_code_uq ON iam.role (coalesce(company_id, 0), code);
COMMENT ON TABLE iam.role IS 'Roles: platform roles, company role templates, and roles each company defines for itself (3.4 c)';

CREATE TABLE iam.role_permission (
  role_id         bigint NOT NULL REFERENCES iam.role(id) ON DELETE CASCADE,
  permission_code text NOT NULL REFERENCES iam.permission(code),
  PRIMARY KEY (role_id, permission_code)
);

CREATE TABLE iam.user_role (
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  role_id     bigint NOT NULL REFERENCES iam.role(id),
  granted_by  bigint REFERENCES iam.app_user(id),
  granted_at  timestamptz NOT NULL DEFAULT now(),
  valid_to    timestamptz,
  PRIMARY KEY (user_id, role_id)
);
COMMENT ON TABLE iam.user_role IS 'Platform staff roles';

CREATE TABLE iam.company_member (
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  company_id  bigint NOT NULL REFERENCES iam.company(id),
  role_id     bigint REFERENCES iam.role(id),         -- empty with is_owner = full permissions
  is_owner    boolean NOT NULL DEFAULT false,
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, company_id),
  CHECK (is_owner OR role_id IS NOT NULL)
);
CREATE UNIQUE INDEX company_single_owner ON iam.company_member (company_id) WHERE is_owner;
COMMENT ON TABLE iam.company_member IS 'Company users (seats) and their role; one owner per company, not editable from inside the company';

-- ------------------------------ Login, sessions and devices ------------
CREATE TABLE iam.device (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id           bigint NOT NULL REFERENCES iam.app_user(id),
  fingerprint_hash  bytea NOT NULL,
  platform          text NOT NULL CHECK (platform IN ('ANDROID','IOS','WEB')),
  app_version       text,
  attestation_state text NOT NULL DEFAULT 'UNKNOWN' CHECK (attestation_state IN ('UNKNOWN','PASSED','FAILED')),
  trust_status      text NOT NULL DEFAULT 'PENDING_APPROVAL' CHECK (trust_status IN ('PENDING_APPROVAL','TRUSTED','REVOKED')),
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  revoked_at        timestamptz,
  UNIQUE (user_id, fingerprint_hash)
);
COMMENT ON TABLE iam.device IS 'Registered devices per user (3.5, 16.8); a new operator device requires approval';

CREATE TABLE iam.push_token (
  device_id   bigint PRIMARY KEY REFERENCES iam.device(id) ON DELETE CASCADE,
  token       text NOT NULL,
  consent     boolean NOT NULL DEFAULT true,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE iam.mfa_factor (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  factor_type text NOT NULL CHECK (factor_type IN ('TOTP','SMS','PASSKEY','RECOVERY_CODES')),
  secret_enc  bytea,
  enc_key_id  int REFERENCES sec.key_registry(id),
  public_key  bytea,                                  -- for passkeys
  verified_at timestamptz,
  disabled_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE iam.mfa_factor IS 'MFA factors (TOTP with encrypted secret, passkeys, recovery codes)';

CREATE TABLE iam.user_session (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id         bigint NOT NULL REFERENCES iam.app_user(id),
  device_id       bigint REFERENCES iam.device(id),
  portal          text NOT NULL CHECK (portal IN ('PLATFORM','OPERATOR','AGENCY','PASSENGER','DRIVER','INSPECTOR')),
  company_id      bigint REFERENCES iam.company(id),
  token_hash      bytea NOT NULL UNIQUE,              -- the token itself is never stored
  refresh_hash    bytea UNIQUE,
  ip              inet NOT NULL,
  user_agent      text,
  mfa_passed      boolean NOT NULL DEFAULT false,
  issued_at       timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,
  revoked_at      timestamptz,
  revoke_reason   text
);
CREATE INDEX user_session_active ON iam.user_session (user_id) WHERE revoked_at IS NULL;
COMMENT ON TABLE iam.user_session IS 'Active sessions; revoking one ends the login immediately';

CREATE TABLE iam.auth_token (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     bigint REFERENCES iam.app_user(id),
  kind        text NOT NULL CHECK (kind IN ('INVITE','PASSWORD_RESET','EMAIL_VERIFY','MOBILE_OTP','LOGIN_OTP')),
  token_hash  bytea NOT NULL UNIQUE,
  target      text,                                   -- target mobile number or email
  attempts    smallint NOT NULL DEFAULT 0,
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE iam.auth_token IS 'Invitation, reset and OTP tokens (single use, stored hashed)';

-- ------------------------------ API clients and keys ------------------
CREATE TABLE iam.api_client (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  name              text NOT NULL,
  kind              text NOT NULL CHECK (kind IN ('CARRIER','CHANNEL','PARTNER','INTEGRATION','AUTHORITY','INTERNAL')),
  owner_party_id    bigint NOT NULL REFERENCES iam.party(id),
  company_id        bigint REFERENCES iam.company(id),
  environment       text NOT NULL DEFAULT 'SANDBOX' CHECK (environment IN ('SANDBOX','PRODUCTION')),
  scopes            text[] NOT NULL DEFAULT '{}',
  rate_limit_per_min int NOT NULL DEFAULT 600 CHECK (rate_limit_per_min > 0),
  ip_allowlist      cidr[],                           -- empty = any address (sec.ip_rule rules still apply)
  require_mtls      boolean NOT NULL DEFAULT false,
  mtls_cert_sha256  bytea,
  status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','REVOKED')),
  created_by        bigint REFERENCES iam.app_user(id),
  approved_by       bigint REFERENCES iam.app_user(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER api_client_updated BEFORE UPDATE ON iam.api_client FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE iam.api_client IS 'API clients (carrier, channel, partner, authority): scopes, rate limit, IP allowlist and optional mTLS';

CREATE TABLE iam.api_key (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  api_client_id bigint NOT NULL REFERENCES iam.api_client(id),
  key_prefix    text NOT NULL,                        -- first 8 characters for identification (not usable on their own)
  key_hash      bytea NOT NULL UNIQUE,                -- SHA-256 of the key (32 random bytes, shown once)
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','REVOKED','EXPIRED')),
  expires_at    timestamptz NOT NULL,                 -- rotated every 90 days (16.18)
  last_used_at  timestamptz,
  last_used_ip  inet,
  created_by    bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  revoked_at    timestamptz,
  revoked_by    bigint REFERENCES iam.app_user(id),
  revoke_reason text
);
CREATE INDEX api_key_prefix_idx ON iam.api_key (key_prefix) WHERE status = 'ACTIVE';
COMMENT ON TABLE iam.api_key IS 'Hashed API keys; at most two active keys during rotation';

CREATE OR REPLACE FUNCTION iam.tg_api_key_max_active() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'ACTIVE' AND (SELECT count(*) FROM iam.api_key k
       WHERE k.api_client_id = NEW.api_client_id AND k.status = 'ACTIVE' AND k.id <> NEW.id) >= 2 THEN
    RAISE EXCEPTION 'API_KEY_LIMIT: max 2 active keys per client' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER api_key_max_active BEFORE INSERT OR UPDATE OF status ON iam.api_key
  FOR EACH ROW EXECUTE FUNCTION iam.tg_api_key_max_active();

ALTER TABLE sys.webhook_endpoint ADD CONSTRAINT webhook_api_client_fk FOREIGN KEY (api_client_id) REFERENCES iam.api_client(id);

-- ------------------------------ Identity verification (3.8) ---------------
CREATE TABLE iam.identity_provider (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE,
  country_code char(2) REFERENCES ref.country(code),
  kind        text NOT NULL CHECK (kind IN ('KYC_VENDOR','NATIONAL_REGISTRY','TELECOM','DIGITAL_ID','COMPANY_REGISTRY','VEHICLE_REGISTRY')),
  protocol    text NOT NULL CHECK (protocol IN ('SDK','REST','SOAP','OIDC','SAML','FILE')),
  config      jsonb NOT NULL DEFAULT '{}',            -- no secrets; secrets live in the vault
  status      text NOT NULL DEFAULT 'INACTIVE' CHECK (status IN ('ACTIVE','INACTIVE'))
);
COMMENT ON TABLE iam.identity_provider IS 'Verification adapters: KYC vendor, national registry, telecom, digital identity (activated in Phase 5)';

CREATE TABLE iam.verification (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subject_type    text NOT NULL CHECK (subject_type IN ('PARTY','COMPANY','VEHICLE','DOCUMENT')),
  subject_id      bigint NOT NULL,
  level           smallint CHECK (level BETWEEN 0 AND 3),
  method          text NOT NULL CHECK (method IN ('OTP','MANUAL','DOC_SELFIE','GOV_FACE','GOV_RECORD','GOV_DIGITAL_ID','MOBILE_OWNERSHIP')),
  provider_id     bigint REFERENCES iam.identity_provider(id),
  doc_type        text,
  doc_no_bidx     bytea,
  doc_expiry      date,
  liveness_score  numeric(5,4),
  match_score     numeric(5,4),
  decision        text NOT NULL CHECK (decision IN ('PASSED','FAILED','REVIEW','EXPIRED')),
  reason_code     text,
  evidence_file_ids bigint[],
  reviewer_id     bigint REFERENCES iam.app_user(id),
  gov_ref         text,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX verification_subject_idx ON iam.verification (subject_type, subject_id, created_at DESC);
COMMENT ON TABLE iam.verification IS 'Record of every verification (identity levels L0..L3, company, vehicle, document); manual now, automatic after integration';

CREATE TABLE iam.biometric_template (
  party_id      bigint PRIMARY KEY REFERENCES iam.party(id),
  template_enc  bytea NOT NULL,
  enc_key_id    int NOT NULL REFERENCES sec.key_registry(id),
  algorithm     text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  retain_until  timestamptz NOT NULL
);
COMMENT ON TABLE iam.biometric_template IS 'Facial biometric template, encrypted with a separate key and stored in isolation (3.8 c)';

CREATE TABLE iam.gov_identity_link (
  party_id        bigint NOT NULL REFERENCES iam.party(id),
  provider_id     bigint NOT NULL REFERENCES iam.identity_provider(id),
  subject_ref_bidx bytea NOT NULL,
  assurance_level text,
  linked_at       timestamptz NOT NULL DEFAULT now(),
  last_verified_at timestamptz,
  PRIMARY KEY (party_id, provider_id)
);
COMMENT ON TABLE iam.gov_identity_link IS 'Link between the account and the national digital identity (readiness for a Nafath-style system)';

-- =====================================================================
-- 010: reference data, settings, encryption keys and files
-- =====================================================================

-- ------------------------------ ref ----------------------------------
-- Locales: the schema, code and seed data are English only. Localized UI text
-- (Arabic RTL first, then Turkish, French, Spanish...) is held in ref.translation
-- and rendered by the presentation layer; no table carries per-language columns.
CREATE TABLE ref.locale (
  code        text PRIMARY KEY CHECK (code ~ '^[a-z]{2}(-[A-Z]{2})?$'),   -- BCP 47: en, ar, tr, fr, es, en-GB
  name        text NOT NULL,                          -- English name of the language
  native_name text,                                   -- endonym, shown in the language picker
  direction   text NOT NULL DEFAULT 'LTR' CHECK (direction IN ('LTR','RTL')),
  is_enabled  boolean NOT NULL DEFAULT false,
  is_default  boolean NOT NULL DEFAULT false
);
CREATE UNIQUE INDEX locale_single_default ON ref.locale (is_default) WHERE is_default;
COMMENT ON TABLE ref.locale IS 'Supported UI locales with text direction; English is the system default, other locales are UI-only';

CREATE TABLE ref.translation (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity      text NOT NULL,                          -- schema.table, e.g. ref.city, pricing.fare_brand
  entity_key  text NOT NULL,                          -- primary key of the row, as text
  field       text NOT NULL,                          -- column being localized, e.g. name
  locale      text NOT NULL REFERENCES ref.locale(code),
  value       text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity, entity_key, field, locale)
);
COMMENT ON TABLE ref.translation IS 'Localized display values for reference data; the English value in the source row is the fallback';
CREATE TABLE ref.country (
  code          char(2) PRIMARY KEY,                 -- ISO 3166-1 alpha-2
  name          text NOT NULL,
  phone_prefix  text,
  default_currency char(3),
  is_active     boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE ref.country IS 'Countries (Country Pack 12.4): Syria first, then expansion';

CREATE TABLE ref.currency (
  code        char(3) PRIMARY KEY,                    -- ISO 4217
  name        text NOT NULL,
  minor_unit  smallint NOT NULL DEFAULT 2 CHECK (minor_unit BETWEEN 0 AND 4),
  is_active   boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE ref.currency IS 'Currencies; every amount in the system is a BIGINT in the minor unit of its currency';

ALTER TABLE ref.country ADD CONSTRAINT country_currency_fk FOREIGN KEY (default_currency) REFERENCES ref.currency(code);

CREATE TABLE ref.exchange_rate (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  base_currency char(3) NOT NULL REFERENCES ref.currency(code),
  quote_currency char(3) NOT NULL REFERENCES ref.currency(code),
  rate          numeric(20,10) NOT NULL CHECK (rate > 0),
  source        text NOT NULL DEFAULT 'MANUAL',       -- MANUAL | CENTRAL_BANK | PROVIDER
  valid_from    timestamptz NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (base_currency, quote_currency, valid_from),
  CHECK (base_currency <> quote_currency)
);
COMMENT ON TABLE ref.exchange_rate IS 'Exchange rates with an effective date; the rate used is fixed on every transaction (section 12)';

CREATE TABLE ref.city (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE,                   -- e.g. DAM, ALP, HMS
  country_code char(2) NOT NULL REFERENCES ref.country(code),
  region      text,
  name        text NOT NULL,
  lat         numeric(9,6),
  lng         numeric(9,6),
  timezone    text NOT NULL DEFAULT 'Asia/Damascus',
  is_active   boolean NOT NULL DEFAULT true
);
CREATE INDEX city_name_trgm ON ref.city USING gin (name gin_trgm_ops);
COMMENT ON TABLE ref.city IS 'Cities (domestic and international)';

-- ------------------------------ sec (keys) -------------------------
CREATE TABLE sec.key_registry (
  id          int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  key_ref     text NOT NULL UNIQUE,                   -- key identifier in KMS/Vault (the key itself is never stored here)
  purpose     text NOT NULL CHECK (purpose IN ('FIELD_ENCRYPTION','BLIND_INDEX','DOCUMENT_SIGNING','QR_SIGNING','EINVOICE_SIGNING','WEBHOOK_SECRET','BACKUP')),
  data_class  text NOT NULL DEFAULT 'RESTRICTED' CHECK (data_class IN ('RESTRICTED','CONFIDENTIAL','INTERNAL')),
  company_id  bigint,                                 -- tenant-specific key when needed (FK added after iam)
  algorithm   text NOT NULL,                          -- AES-256-GCM | HMAC-SHA256 | ECDSA-P256 ...
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DECRYPT_ONLY','RETIRED')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  rotated_at  timestamptz,
  expires_at  timestamptz
);
COMMENT ON TABLE sec.key_registry IS 'Registry of encryption and signing keys (16.8, 16.18): references only, keys live in KMS; every encrypted field carries its key_id';

-- ------------------------------ ref.file ------------------------------
CREATE TABLE ref.file_object (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  storage_key   text NOT NULL UNIQUE,                 -- object path in storage (encrypted at rest)
  file_name     text,
  mime_type     text NOT NULL,
  size_bytes    bigint NOT NULL CHECK (size_bytes >= 0),
  sha256        bytea NOT NULL,                       -- file integrity
  data_class    text NOT NULL DEFAULT 'CONFIDENTIAL' CHECK (data_class IN ('RESTRICTED','CONFIDENTIAL','INTERNAL','PUBLIC')),
  enc_key_id    int REFERENCES sec.key_registry(id),
  uploaded_by   bigint,                               -- FK to iam.app_user added later
  retain_until  timestamptz,                          -- automatic deletion after the retention period (16.13)
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.file_object IS 'Metadata for every uploaded file (documents, images, signed PDFs); content is in encrypted object storage';

-- ------------------------------ sys ----------------------------------
CREATE TABLE sys.setting (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  scope       text NOT NULL DEFAULT 'PLATFORM' CHECK (scope IN ('PLATFORM','COUNTRY','COMPANY')),
  description text,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  bigint
);
COMMENT ON TABLE sys.setting IS 'Global settings and feature flags (full-build, activate-by-configuration principle 2.8)';

CREATE TABLE sys.company_setting (
  company_id  bigint NOT NULL,                        -- FK added after iam
  key         text NOT NULL,
  value       jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  bigint,
  PRIMARY KEY (company_id, key)
);
COMMENT ON TABLE sys.company_setting IS 'Per-carrier settings (post-departure sales policy, cutoffs, seat selection modes...)';

CREATE TABLE sys.outbox_event (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_uid     uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  event_type    text NOT NULL,                        -- booking.confirmed, trip.published ...
  aggregate_type text NOT NULL,
  aggregate_id  bigint NOT NULL,
  company_id    bigint,
  payload       jsonb NOT NULL,
  status        text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','PUBLISHED','FAILED')),
  attempts      int NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_error    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  published_at  timestamptz
);
CREATE INDEX outbox_pending ON sys.outbox_event (next_attempt_at) WHERE status = 'PENDING';
COMMENT ON TABLE sys.outbox_event IS 'Transactional outbox: written in the same transaction as the change, then published to services and partners';

CREATE TABLE sys.webhook_endpoint (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  owner_kind    text NOT NULL CHECK (owner_kind IN ('API_CLIENT','INTEGRATION')),
  api_client_id bigint,                               -- FK added after iam
  kind          text NOT NULL DEFAULT 'PARTNER' CHECK (kind IN ('PARTNER','CRM','BI','CASHFLOW','ACCOUNTING','PAYMENT')),
  url           text NOT NULL CHECK (url ~ '^https://'),
  events        text[] NOT NULL,
  secret_enc    bytea NOT NULL,                       -- encrypted HMAC secret
  enc_key_id    int NOT NULL REFERENCES sec.key_registry(id),
  include_pii   boolean NOT NULL DEFAULT false,
  api_version   text NOT NULL DEFAULT 'v1',
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAUSED','DISABLED')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_success_at timestamptz
);
COMMENT ON TABLE sys.webhook_endpoint IS 'Webhook subscriptions for partners and integrations (14, 13.10), signed with HMAC-SHA256';

CREATE TABLE sys.webhook_delivery (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  endpoint_id   bigint NOT NULL REFERENCES sys.webhook_endpoint(id),
  outbox_event_id bigint NOT NULL REFERENCES sys.outbox_event(id),
  delivery_uid  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  status        text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','DELIVERED','FAILED','DEAD')),
  attempts      int NOT NULL DEFAULT 0,
  http_status   int,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_error    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  delivered_at  timestamptz,
  UNIQUE (endpoint_id, outbox_event_id)
);
CREATE INDEX webhook_delivery_pending ON sys.webhook_delivery (next_attempt_at) WHERE status = 'PENDING';
COMMENT ON TABLE sys.webhook_delivery IS 'Delivery attempts, retries and dead letters (DEAD)';

CREATE TABLE sys.schema_migration (
  version     text PRIMARY KEY,
  description text,
  checksum    text,
  applied_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sys.schema_migration IS 'Applied schema versions';

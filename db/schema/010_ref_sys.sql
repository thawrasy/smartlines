-- =====================================================================
-- 010: البيانات المرجعية والإعدادات ومفاتيح التشفير والملفات
-- =====================================================================

-- ------------------------------ ref ----------------------------------
CREATE TABLE ref.country (
  code          char(2) PRIMARY KEY,                 -- ISO 3166-1 alpha-2
  name_ar       text NOT NULL,
  name_en       text NOT NULL,
  phone_prefix  text,
  default_currency char(3),
  is_active     boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE ref.country IS 'الدول (حزمة الدولة 12.4): سوريا أساساً ثم التوسع';

CREATE TABLE ref.currency (
  code        char(3) PRIMARY KEY,                    -- ISO 4217
  name_ar     text NOT NULL,
  name_en     text NOT NULL,
  minor_unit  smallint NOT NULL DEFAULT 2 CHECK (minor_unit BETWEEN 0 AND 4),
  is_active   boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE ref.currency IS 'العملات؛ كل المبالغ في النظام BIGINT بالوحدة الصغرى لهذه العملة';

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
COMMENT ON TABLE ref.exchange_rate IS 'أسعار الصرف بتاريخ سريان؛ يُثبَّت السعر المستخدم في كل عملية (القسم 12)';

CREATE TABLE ref.city (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE,                   -- مثل DAM, ALP, HMS
  country_code char(2) NOT NULL REFERENCES ref.country(code),
  region      text,
  name_ar     text NOT NULL,
  name_en     text NOT NULL,
  lat         numeric(9,6),
  lng         numeric(9,6),
  timezone    text NOT NULL DEFAULT 'Asia/Damascus',
  is_active   boolean NOT NULL DEFAULT true
);
CREATE INDEX city_name_trgm ON ref.city USING gin (name_ar gin_trgm_ops);
COMMENT ON TABLE ref.city IS 'المدن (محلية ودولية)';

-- ------------------------------ sec (مفاتيح) -------------------------
CREATE TABLE sec.key_registry (
  id          int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  key_ref     text NOT NULL UNIQUE,                   -- معرّف المفتاح في KMS/Vault (لا يُخزَّن المفتاح نفسه هنا)
  purpose     text NOT NULL CHECK (purpose IN ('FIELD_ENCRYPTION','BLIND_INDEX','DOCUMENT_SIGNING','QR_SIGNING','EINVOICE_SIGNING','WEBHOOK_SECRET','BACKUP')),
  data_class  text NOT NULL DEFAULT 'RESTRICTED' CHECK (data_class IN ('RESTRICTED','CONFIDENTIAL','INTERNAL')),
  company_id  bigint,                                 -- مفتاح خاص بمستأجر عند الحاجة (FK يضاف بعد iam)
  algorithm   text NOT NULL,                          -- AES-256-GCM | HMAC-SHA256 | ECDSA-P256 ...
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DECRYPT_ONLY','RETIRED')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  rotated_at  timestamptz,
  expires_at  timestamptz
);
COMMENT ON TABLE sec.key_registry IS 'سجل مفاتيح التشفير والتوقيع (16.8 و16.18): المرجع فقط، والمفتاح في KMS؛ كل حقل مشفر يحمل key_id';

-- ------------------------------ ref.file ------------------------------
CREATE TABLE ref.file_object (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  storage_key   text NOT NULL UNIQUE,                 -- مسار الكائن في التخزين (مشفر في التخزين)
  file_name     text,
  mime_type     text NOT NULL,
  size_bytes    bigint NOT NULL CHECK (size_bytes >= 0),
  sha256        bytea NOT NULL,                       -- سلامة الملف
  data_class    text NOT NULL DEFAULT 'CONFIDENTIAL' CHECK (data_class IN ('RESTRICTED','CONFIDENTIAL','INTERNAL','PUBLIC')),
  enc_key_id    int REFERENCES sec.key_registry(id),
  uploaded_by   bigint,                               -- FK إلى iam.app_user يضاف لاحقاً
  retain_until  timestamptz,                          -- الحذف الآلي بعد مدة الاحتفاظ (16.13)
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.file_object IS 'بيانات وصفية لكل ملف مرفوع (مستندات، صور، PDF موقّع)؛ المحتوى في تخزين الكائنات المشفر';

-- ------------------------------ sys ----------------------------------
CREATE TABLE sys.setting (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  scope       text NOT NULL DEFAULT 'PLATFORM' CHECK (scope IN ('PLATFORM','COUNTRY','COMPANY')),
  description text,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  bigint
);
COMMENT ON TABLE sys.setting IS 'الإعدادات العامة ومفاتيح التفعيل (مبدأ البناء الكامل والتفعيل بالإعدادات 2.8)';

CREATE TABLE sys.company_setting (
  company_id  bigint NOT NULL,                        -- FK يضاف بعد iam
  key         text NOT NULL,
  value       jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  bigint,
  PRIMARY KEY (company_id, key)
);
COMMENT ON TABLE sys.company_setting IS 'إعدادات خاصة بكل ناقل (سياسة البيع بعد الانطلاق، مهل الإقفال، أوضاع المقاعد...)';

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
COMMENT ON TABLE sys.outbox_event IS 'صندوق الأحداث الصادرة (Outbox): يُكتب في معاملة التغيير نفسها، ثم يُنشر للخدمات والشركاء';

CREATE TABLE sys.webhook_endpoint (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  owner_kind    text NOT NULL CHECK (owner_kind IN ('API_CLIENT','INTEGRATION')),
  api_client_id bigint,                               -- FK يضاف بعد iam
  kind          text NOT NULL DEFAULT 'PARTNER' CHECK (kind IN ('PARTNER','CRM','BI','CASHFLOW','ACCOUNTING','PAYMENT')),
  url           text NOT NULL CHECK (url ~ '^https://'),
  events        text[] NOT NULL,
  secret_enc    bytea NOT NULL,                       -- سر HMAC مشفر
  enc_key_id    int NOT NULL REFERENCES sec.key_registry(id),
  include_pii   boolean NOT NULL DEFAULT false,
  api_version   text NOT NULL DEFAULT 'v1',
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAUSED','DISABLED')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_success_at timestamptz
);
COMMENT ON TABLE sys.webhook_endpoint IS 'اشتراكات Webhooks للشركاء والتكاملات (14 و13.10)، موقّعة HMAC-SHA256';

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
COMMENT ON TABLE sys.webhook_delivery IS 'محاولات التسليم وإعادة المحاولة والرسائل المتعثرة (DEAD)';

CREATE TABLE sys.schema_migration (
  version     text PRIMARY KEY,
  description text,
  checksum    text,
  applied_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sys.schema_migration IS 'إصدارات المخطط المطبقة';

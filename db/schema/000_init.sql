-- =====================================================================
-- Masslak (مسلك) — قاعدة بيانات المرحلة الأولى
-- 000: الامتدادات والمخططات والأدوار والدوال المساعدة
-- المرجع: الدراسة v2.4، القسم 29.1 (قواعد النقل إلى PostgreSQL)
--   المبالغ BIGINT بالوحدة الصغرى، الأزمنة TIMESTAMPTZ (UTC)،
--   JSONB للحقول المرنة، مفتاح داخلي BIGINT + معرّف عام UUID،
--   مفاتيح أجنبية صريحة، تقسيم الجداول الكبيرة زمنياً، تشفير حقلي.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid, digest
CREATE EXTENSION IF NOT EXISTS citext;      -- بريد إلكتروني غير حساس لحالة الأحرف
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- قيود الاستبعاد (منع تداخل المركبة والسائق والإيجار)
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- البحث النصي عن المحطات والمدن

-- ---------------------------------------------------------------------
-- المخططات (Schemas): كل وحدة في مخطط مستقل بصلاحيات مستقلة
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS sys;      -- الإعدادات، صندوق الأحداث، Webhooks، دوال مساعدة
CREATE SCHEMA IF NOT EXISTS ref;      -- البيانات المرجعية: دول، عملات، مدن، ملفات
CREATE SCHEMA IF NOT EXISTS iam;      -- الهوية والأطراف والمستخدمون والصلاحيات وAPI
CREATE SCHEMA IF NOT EXISTS net;      -- الشبكة: المحطات والخطوط ورموز الناقلين
CREATE SCHEMA IF NOT EXISTS fleet;    -- المركبات والمقاعد والطاقم والتراخيص والتأمين
CREATE SCHEMA IF NOT EXISTS pricing;  -- الأسعار والعلامات والضرائب والعمولات والحملات والولاء
CREATE SCHEMA IF NOT EXISTS ops;      -- الرحلات والمخزون والتشغيل والتتبع والحوادث
CREATE SCHEMA IF NOT EXISTS sales;    -- الحجوزات والمسافرون والتذاكر والصعود
CREATE SCHEMA IF NOT EXISTS fin;      -- المحافظ والدفتر والمدفوعات والتوزيع والتسوية
CREATE SCHEMA IF NOT EXISTS acct;     -- المحاسبة المبسطة والفوترة الإلكترونية والملف الضريبي
CREATE SCHEMA IF NOT EXISTS crm;      -- الشكاوى والتقييم والإشعارات والمساعد الذكي
CREATE SCHEMA IF NOT EXISTS gov;      -- الحوكمة: مصفوفة الصلاحيات، الالتزامات، حماية البيانات
CREATE SCHEMA IF NOT EXISTS sec;      -- الأمن: قواعد IP، المخاطر، المفاتيح، وحدة الأمن والامتثال
CREATE SCHEMA IF NOT EXISTS audit;    -- سجلات الدخول والإجراءات (إلحاق فقط)

-- ---------------------------------------------------------------------
-- الأدوار (Roles) — أقل صلاحية (16.17: حسابات قاعدة بصلاحيات دنيا)
--   masslak_owner   : مالك المخطط، للترحيل فقط (لا يستخدمه التطبيق)
--   masslak_app     : التطبيق؛ يخضع لسياسات RLS، ولا يعدّل السجلات أو يحذفها
--   masslak_readonly: التقارير والقراءة
--   masslak_auditor : قراءة سجلات التدقيق والأمن فقط
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_owner')    THEN CREATE ROLE masslak_owner NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_app')      THEN CREATE ROLE masslak_app NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_readonly') THEN CREATE ROLE masslak_readonly NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_auditor')  THEN CREATE ROLE masslak_auditor NOLOGIN; END IF;
END $$;

-- ---------------------------------------------------------------------
-- سياق الطلب: يضبطه التطبيق في بداية كل معاملة عبر sys.set_context()
-- فتستخدمه سياسات RLS وسجلات التدقيق
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sys.set_context(
  p_user_id       bigint,
  p_company_id    bigint,
  p_scope         text,      -- PLATFORM | COMPANY | AGENCY | PASSENGER | API | SYSTEM
  p_api_client_id bigint DEFAULT NULL,
  p_request_id    uuid   DEFAULT NULL,
  p_ip            inet   DEFAULT NULL,
  p_session_id    bigint DEFAULT NULL,
  p_party_id      bigint DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.user_id',       coalesce(p_user_id::text, ''),       true);
  PERFORM set_config('app.company_id',    coalesce(p_company_id::text, ''),    true);
  PERFORM set_config('app.scope',         coalesce(p_scope, ''),               true);
  PERFORM set_config('app.api_client_id', coalesce(p_api_client_id::text, ''), true);
  PERFORM set_config('app.request_id',    coalesce(p_request_id::text, ''),    true);
  PERFORM set_config('app.ip',            coalesce(host(p_ip), ''),            true);
  PERFORM set_config('app.session_id',    coalesce(p_session_id::text, ''),    true);
  PERFORM set_config('app.party_id',      coalesce(p_party_id::text, ''),      true);
END $$;

CREATE OR REPLACE FUNCTION sys.ctx_bigint(p_key text) RETURNS bigint
LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting(p_key, true), '')::bigint $$;

CREATE OR REPLACE FUNCTION sys.ctx_user_id()       RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT sys.ctx_bigint('app.user_id') $$;
CREATE OR REPLACE FUNCTION sys.ctx_company_id()    RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT sys.ctx_bigint('app.company_id') $$;
CREATE OR REPLACE FUNCTION sys.ctx_api_client_id() RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT sys.ctx_bigint('app.api_client_id') $$;
CREATE OR REPLACE FUNCTION sys.ctx_party_id()      RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT sys.ctx_bigint('app.party_id') $$;
CREATE OR REPLACE FUNCTION sys.ctx_session_id()    RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT sys.ctx_bigint('app.session_id') $$;
CREATE OR REPLACE FUNCTION sys.ctx_scope()         RETURNS text   LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.scope', true), '') $$;
CREATE OR REPLACE FUNCTION sys.ctx_request_id()    RETURNS uuid   LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.request_id', true), '')::uuid $$;
CREATE OR REPLACE FUNCTION sys.ctx_ip()            RETURNS inet   LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.ip', true), '')::inet $$;
CREATE OR REPLACE FUNCTION sys.ctx_is_platform()   RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT coalesce(sys.ctx_scope() IN ('PLATFORM','SYSTEM'), false) $$;

-- عزل المستأجر: صف الشركة مرئي لموظف المنصة أو لمستخدم الشركة نفسها
CREATE OR REPLACE FUNCTION sys.tenant_visible(p_company_id bigint) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT sys.ctx_is_platform() OR (p_company_id IS NOT NULL AND p_company_id = sys.ctx_company_id())
$$;

-- ---------------------------------------------------------------------
-- دوال مشغّلات عامة
-- ---------------------------------------------------------------------
-- تحديث updated_at آلياً
CREATE OR REPLACE FUNCTION sys.tg_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- منع التعديل والحذف (جداول الإلحاق فقط: الدفتر، السجلات، الفواتير المقفلة...)
CREATE OR REPLACE FUNCTION sys.tg_forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'IMMUTABLE_RECORD: % on %.% is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'P0001';
END $$;

-- خانة تحقق Mod 11 (أرقام التتبع والمستندات، 4.16 ب)
CREATE OR REPLACE FUNCTION sys.mod11_check_digit(p_digits text) RETURNS int
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s int := 0; w int := 2; i int; r int;
BEGIN
  FOR i IN REVERSE length(p_digits)..1 LOOP
    s := s + (substr(p_digits, i, 1))::int * w;
    w := CASE WHEN w = 7 THEN 2 ELSE w + 1 END;
  END LOOP;
  r := 11 - (s % 11);
  RETURN CASE WHEN r = 11 THEN 0 WHEN r = 10 THEN 1 ELSE r END;
END $$;

COMMENT ON FUNCTION sys.set_context IS 'يضبط سياق الطلب (المستخدم، الشركة، النطاق، عميل API، رقم الطلب، IP) لسياسات RLS والتدقيق';
COMMENT ON FUNCTION sys.tg_forbid_mutation IS 'يمنع UPDATE وDELETE على جداول الإلحاق فقط';

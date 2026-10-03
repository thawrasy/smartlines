-- =====================================================================
-- 110: سجلات التدقيق — كل دخول وكل إجراء لكل مستخدم أو عميل API
-- المبادئ:
--   * إلحاق فقط: لا UPDATE ولا DELETE (مشغّل + سحب الصلاحية من دور التطبيق)
--   * لكل صف تجزئة SHA-256 لمحتواه (row_hash)، وتُختم الكتل دورياً بسلسلة
--     تجزئة موقّعة (audit.log_seal) فيُكشف أي حذف أو تعديل أو إدراج لاحق
--   * تقسيم شهري للأداء والاحتفاظ؛ الحذف بإسقاط الأقسام بعد المدة النظامية فقط
--   * لا تُخزَّن كلمات مرور ولا رموز ولا قيم مشفرة في السجلات (تنقيح آلي)
-- =====================================================================

-- ------------------------------ دوال الأقسام الشهرية -----------------
CREATE OR REPLACE FUNCTION sys.ensure_monthly_partitions(p_parent text, p_months_ahead int DEFAULT 3, p_months_back int DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE m date; part text; sch text := split_part(p_parent, '.', 1); tbl text := split_part(p_parent, '.', 2);
BEGIN
  FOR m IN SELECT generate_series(date_trunc('month', now()) - make_interval(months => p_months_back),
                                  date_trunc('month', now()) + make_interval(months => p_months_ahead),
                                  interval '1 month')::date LOOP
    part := format('%I.%I', sch, tbl || '_' || to_char(m, 'YYYYMM'));
    IF to_regclass(part) IS NULL THEN
      EXECUTE format('CREATE TABLE %s PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
                     part, p_parent, m, (m + interval '1 month')::date);
    END IF;
  END LOOP;
  part := format('%I.%I', sch, tbl || '_default');
  IF to_regclass(part) IS NULL THEN
    EXECUTE format('CREATE TABLE %s PARTITION OF %s DEFAULT', part, p_parent);
  END IF;
END $$;
COMMENT ON FUNCTION sys.ensure_monthly_partitions IS 'ينشئ أقسام الأشهر القادمة (يُشغَّل يومياً بمهمة مجدولة)؛ القسم الافتراضي شبكة أمان فقط';

CREATE OR REPLACE FUNCTION sys.drop_partitions_older_than(p_parent text, p_keep_months int)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE r record; n int := 0; cutoff date := (date_trunc('month', now()) - make_interval(months => p_keep_months))::date;
BEGIN
  FOR r IN SELECT c.oid::regclass::text AS part, pg_get_expr(c.relpartbound, c.oid) AS bound
           FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
           WHERE i.inhparent = p_parent::regclass LOOP
    IF r.bound LIKE 'FOR VALUES FROM%' AND substring(r.bound from 'TO \(''([0-9-]+)')::date <= cutoff THEN
      EXECUTE format('DROP TABLE %s', r.part);
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;
COMMENT ON FUNCTION sys.drop_partitions_older_than IS 'الحذف وفق جدول الاحتفاظ فقط (بعد الختم والأرشفة في النسخ غير القابلة للتعديل)';

-- تنقيح: إزالة الحقول المشفرة والأسرار من أي JSON قبل حفظه في السجل
CREATE OR REPLACE FUNCTION audit.redact(p jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_object_agg(k, CASE
           WHEN k ~ '(_enc|_hash|_bidx|password|secret|token|signature|template)$' OR k ~ '^(password|secret|token)'
             THEN to_jsonb('***'::text) ELSE v END), '{}'::jsonb)
  FROM jsonb_each(p) AS e(k, v)
$$;

-- تجزئة الصف (تُحسب عند الإدراج)
CREATE OR REPLACE FUNCTION audit.tg_row_hash() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.row_hash := digest(convert_to((to_jsonb(NEW) - 'row_hash')::text, 'UTF8'), 'sha256');
  RETURN NEW;
END $$;

-- ------------------------------ سجل الدخول --------------------------
CREATE TABLE audit.auth_event (
  id              bigint GENERATED ALWAYS AS IDENTITY,
  ts              timestamptz NOT NULL DEFAULT now(),
  event           text NOT NULL CHECK (event IN (
                    'LOGIN_SUCCESS','LOGIN_FAILED','LOGOUT','MFA_SUCCESS','MFA_FAILED','OTP_SENT','OTP_FAILED',
                    'PASSWORD_CHANGED','PASSWORD_RESET','TOKEN_REFRESH','SESSION_REVOKED','ACCOUNT_LOCKED',
                    'DEVICE_NEW','DEVICE_APPROVED','PORTAL_SWITCH','API_KEY_AUTH','API_KEY_REJECTED','IP_BLOCKED')),
  actor_type      text NOT NULL CHECK (actor_type IN ('USER','API_CLIENT','ANONYMOUS')),
  user_id         bigint,
  api_client_id   bigint,
  api_key_id      bigint,
  identifier_hash bytea,                              -- معرّف الدخول المحاول (مجزأ) عند فشل بلا مستخدم معروف
  portal          text,
  company_id      bigint,
  session_id      bigint,
  device_id       bigint,
  ip              inet NOT NULL,
  country_code    char(2),
  asn             int,
  user_agent      text,
  result          text NOT NULL CHECK (result IN ('SUCCESS','FAILURE','BLOCKED')),
  reason          text,
  request_id      uuid,
  row_hash        bytea,
  PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
CREATE INDEX auth_event_user_idx ON audit.auth_event (user_id, ts DESC);
CREATE INDEX auth_event_ip_idx   ON audit.auth_event (ip, ts DESC);
CREATE INDEX auth_event_client_idx ON audit.auth_event (api_client_id, ts DESC) WHERE api_client_id IS NOT NULL;
CREATE TRIGGER auth_event_hash BEFORE INSERT ON audit.auth_event FOR EACH ROW EXECUTE FUNCTION audit.tg_row_hash();
CREATE TRIGGER auth_event_immutable BEFORE UPDATE OR DELETE ON audit.auth_event FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE audit.auth_event IS 'كل محاولة دخول أو خروج أو تحقق أو استخدام مفتاح API، ناجحة أو فاشلة، بالعنوان والجهاز والبوابة';

-- شبكة أمان في القاعدة: إخفاقات متكررة من العنوان نفسه ← حجب آلي متصاعد
CREATE OR REPLACE FUNCTION audit.tg_auth_fail_autoblock() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE thr int; win int; fails int;
BEGIN
  IF NEW.result <> 'FAILURE' THEN RETURN NULL; END IF;
  thr := coalesce((SELECT (value->>'threshold')::int FROM sys.setting WHERE key = 'security.auth_fail_ip'), 30);
  win := coalesce((SELECT (value->>'window_min')::int FROM sys.setting WHERE key = 'security.auth_fail_ip'), 60);
  SELECT count(*) INTO fails FROM audit.auth_event
   WHERE ip = NEW.ip AND result = 'FAILURE' AND ts > now() - make_interval(mins => win);
  IF fails >= thr AND NOT EXISTS (
       SELECT 1 FROM sec.ip_rule r WHERE r.rule_type = 'CIDR' AND r.cidr >>= NEW.ip AND r.action = 'BLOCK'
         AND r.revoked_at IS NULL AND (r.expires_at IS NULL OR r.expires_at > now())) THEN
    PERFORM sec.auto_block_ip(NEW.ip, 'ALL', 'AUTO_AUTH',
      format('%s failed auth attempts in %s min', fails, win), 15, jsonb_build_object('fails', fails, 'window_min', win));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER auth_event_autoblock AFTER INSERT ON audit.auth_event FOR EACH ROW EXECUTE FUNCTION audit.tg_auth_fail_autoblock();

-- ------------------------------ سجل الإجراءات ------------------------
CREATE TABLE audit.activity_log (
  id            bigint GENERATED ALWAYS AS IDENTITY,
  ts            timestamptz NOT NULL DEFAULT now(),
  request_id    uuid,
  actor_type    text NOT NULL CHECK (actor_type IN ('USER','API_CLIENT','SYSTEM','AUTHORITY')),
  user_id       bigint,
  api_client_id bigint,
  company_id    bigint,
  session_id    bigint,
  portal        text,
  ip            inet,
  user_agent    text,
  http_method   text,
  endpoint      text,
  action        text NOT NULL,                        -- رمز الصلاحية أو الإجراء: booking.create, trip.publish ...
  object_type   text,
  object_id     bigint,
  object_uid    uuid,
  result        text NOT NULL CHECK (result IN ('SUCCESS','DENIED','ERROR','BLOCKED','RATE_LIMITED')),
  http_status   smallint,
  latency_ms    int,
  reason        text,                                 -- إلزامي للإجراءات الحساسة
  changes       jsonb,                                -- قبل/بعد بعد التنقيح
  row_hash      bytea,
  PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
CREATE INDEX activity_user_idx    ON audit.activity_log (user_id, ts DESC);
CREATE INDEX activity_client_idx  ON audit.activity_log (api_client_id, ts DESC) WHERE api_client_id IS NOT NULL;
CREATE INDEX activity_company_idx ON audit.activity_log (company_id, ts DESC);
CREATE INDEX activity_object_idx  ON audit.activity_log (object_type, object_id);
CREATE INDEX activity_ip_idx      ON audit.activity_log (ip, ts DESC);
CREATE TRIGGER activity_hash BEFORE INSERT ON audit.activity_log FOR EACH ROW EXECUTE FUNCTION audit.tg_row_hash();
CREATE TRIGGER activity_immutable BEFORE UPDATE OR DELETE ON audit.activity_log FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE audit.activity_log IS 'كل طلب أو إجراء في المنصة أو عبر API: من، متى، من أين، ماذا، على أي كيان، والنتيجة';

-- ------------------------------ سجل الاطلاع على البيانات السرية -------
CREATE TABLE audit.data_access_log (
  id            bigint GENERATED ALWAYS AS IDENTITY,
  ts            timestamptz NOT NULL DEFAULT now(),
  user_id       bigint,
  api_client_id bigint,
  company_id    bigint,
  ip            inet,
  object_type   text NOT NULL,
  object_id     bigint NOT NULL,
  fields        text[] NOT NULL,                      -- مثل {passport_no, id_no}
  purpose       text NOT NULL,                        -- السبب الإلزامي (16.13: وصول بدور مع سبب)
  request_id    uuid,
  row_hash      bytea,
  PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
CREATE INDEX data_access_object_idx ON audit.data_access_log (object_type, object_id);
CREATE INDEX data_access_user_idx ON audit.data_access_log (user_id, ts DESC);
CREATE TRIGGER data_access_hash BEFORE INSERT ON audit.data_access_log FOR EACH ROW EXECUTE FUNCTION audit.tg_row_hash();
CREATE TRIGGER data_access_immutable BEFORE UPDATE OR DELETE ON audit.data_access_log FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE audit.data_access_log IS 'كل كشف لحقل سري (جواز، هوية، IBAN) بالسبب';

-- ------------------------------ التقاط التغييرات على مستوى القاعدة ----
CREATE TABLE audit.row_change (
  id            bigint GENERATED ALWAYS AS IDENTITY,
  ts            timestamptz NOT NULL DEFAULT now(),
  schema_name   text NOT NULL,
  table_name    text NOT NULL,
  op            char(1) NOT NULL CHECK (op IN ('I','U','D')),
  row_pk        text,
  old_values    jsonb,
  new_values    jsonb,
  db_user       text NOT NULL DEFAULT current_user,
  user_id       bigint,
  api_client_id bigint,
  company_id    bigint,
  request_id    uuid,
  ip            inet,
  txid          bigint NOT NULL DEFAULT txid_current(),
  row_hash      bytea,
  PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
CREATE INDEX row_change_obj_idx ON audit.row_change (schema_name, table_name, row_pk);
CREATE TRIGGER row_change_hash BEFORE INSERT ON audit.row_change FOR EACH ROW EXECUTE FUNCTION audit.tg_row_hash();
CREATE TRIGGER row_change_immutable BEFORE UPDATE OR DELETE ON audit.row_change FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE audit.row_change IS 'التقاط آلي لأي تغيير على الجداول الحساسة حتى لو تم خارج التطبيق (مع هوية المستخدم من سياق الطلب)';

CREATE OR REPLACE FUNCTION audit.tg_capture_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE o jsonb; n jsonb; pk text;
BEGIN
  IF TG_OP <> 'INSERT' THEN o := audit.redact(to_jsonb(OLD)); END IF;
  IF TG_OP <> 'DELETE' THEN n := audit.redact(to_jsonb(NEW)); END IF;
  IF TG_OP = 'UPDATE' THEN               -- احفظ الحقول المتغيرة فقط
    SELECT jsonb_object_agg(k, o->k), jsonb_object_agg(k, n->k) INTO o, n
      FROM jsonb_object_keys(n) k WHERE (o->k) IS DISTINCT FROM (n->k) AND k NOT IN ('updated_at');
    IF n IS NULL THEN RETURN NULL; END IF;
  END IF;
  pk := coalesce(n->>'id', o->>'id', n->>'party_id', o->>'party_id', n->>'company_id', o->>'company_id', n->>'key', o->>'key');
  INSERT INTO audit.row_change (schema_name, table_name, op, row_pk, old_values, new_values,
                                user_id, api_client_id, company_id, request_id, ip)
  VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, left(TG_OP, 1), pk, o, n,
          sys.ctx_user_id(), sys.ctx_api_client_id(), sys.ctx_company_id(), sys.ctx_request_id(), sys.ctx_ip());
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'iam.party','iam.company','iam.app_user','iam.company_member','iam.role','iam.role_permission','iam.user_role',
    'iam.api_client','iam.api_key','iam.bank_account','iam.document','iam.verification',
    'net.station','net.route','net.carrier_code','net.service_number',
    'fleet.vehicle','fleet.vehicle_lease','fleet.license_record','fleet.license_change_request','fleet.insurance_policy','fleet.crew_profile',
    'pricing.fare_table','pricing.fare_table_item','pricing.tax_scheme','pricing.tax_rule','pricing.commission_scheme','pricing.commission_rule',
    'pricing.allocation_template','pricing.campaign','pricing.loyalty_rule',
    'ops.trip','ops.trip_disruption','ops.incident',
    'sales.booking','sales.ticket','sales.refund_request','sales.passenger_compensation',
    'fin.wallet','fin.payment','fin.withdrawal_request','fin.settlement_batch','fin.payout','fin.payout_schedule',
    'acct.tax_profile','acct.einvoice_document','acct.journal_entry','acct.posting_rule','acct.accounting_connection',
    'crm.case','gov.policy_authority','gov.policy_change','sys.setting','sys.company_setting',
    'sec.ip_rule','sec.watchlist_entry','sec.authority_data_request','sec.key_registry']
  LOOP
    EXECUTE format('CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change()', t);
  END LOOP;
END $$;

-- ------------------------------ ختم السجلات بسلسلة تجزئة -------------
CREATE TABLE audit.log_seal (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  log_name    text NOT NULL CHECK (log_name IN ('auth_event','activity_log','data_access_log','row_change')),
  from_id     bigint NOT NULL,
  to_id       bigint NOT NULL,
  row_count   bigint NOT NULL,
  block_hash  bytea NOT NULL,                         -- تجزئة متتالية لتجزئات الصفوف بالترتيب
  prev_seal_hash bytea,
  seal_hash   bytea NOT NULL,                         -- sha256(prev_seal_hash || block_hash || range)
  key_id      int REFERENCES sec.key_registry(id),
  signature   bytea,                                  -- توقيع خارجي من KMS (يُضاف من خدمة الختم)
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (log_name, from_id)
);
CREATE TRIGGER log_seal_immutable BEFORE UPDATE OR DELETE ON audit.log_seal FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE audit.log_seal IS 'ختم دوري لكتل السجلات بسلسلة تجزئة (وتوقيع KMS) يكشف أي حذف أو تعديل';

CREATE OR REPLACE FUNCTION audit.seal(p_log text, p_max_rows int DEFAULT 100000) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE last_to bigint; last_hash bytea; f bigint; t bigint; cnt bigint; bh bytea; sh bytea; sid bigint;
BEGIN
  SELECT to_id, seal_hash INTO last_to, last_hash FROM audit.log_seal WHERE log_name = p_log ORDER BY id DESC LIMIT 1;
  last_to := coalesce(last_to, 0);
  EXECUTE format($q$
    WITH b AS (SELECT id, row_hash FROM audit.%I WHERE id > $1 AND ts < now() - interval '1 minute' ORDER BY id LIMIT $2)
    SELECT min(id), max(id), count(*), digest(string_agg(encode(row_hash, 'hex'), '' ORDER BY id), 'sha256') FROM b
  $q$, p_log) INTO f, t, cnt, bh USING last_to, p_max_rows;
  IF cnt = 0 THEN RETURN NULL; END IF;
  sh := digest(coalesce(last_hash, '\x'::bytea) || bh || convert_to(f || ':' || t, 'UTF8'), 'sha256');
  INSERT INTO audit.log_seal (log_name, from_id, to_id, row_count, block_hash, prev_seal_hash, seal_hash)
  VALUES (p_log, f, t, cnt, bh, last_hash, sh) RETURNING id INTO sid;
  RETURN sid;
END $$;
COMMENT ON FUNCTION audit.seal IS 'يختم الكتلة التالية من السجل (مهمة مجدولة كل دقائق)؛ التحقق بإعادة الحساب ومقارنة السلسلة';

-- الأقسام الأولية
DO $$
BEGIN
  PERFORM sys.ensure_monthly_partitions('audit.auth_event');
  PERFORM sys.ensure_monthly_partitions('audit.activity_log');
  PERFORM sys.ensure_monthly_partitions('audit.data_access_log');
  PERFORM sys.ensure_monthly_partitions('audit.row_change');
  PERFORM sys.ensure_monthly_partitions('ops.geo_event');
END $$;

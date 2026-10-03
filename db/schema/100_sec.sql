-- =====================================================================
-- 100: الأمن — قواعد حجب العناوين والنطاقات، المخاطر والاحتيال، الأحداث الأمنية،
--      توقيع المستندات ومنع العبث، ووحدة الأمن والامتثال (الربط مع الجهات)
-- المرجع: 4.9، 16.4، 16.8، 16.17، 16.20، 16.25
-- =====================================================================

-- ------------------------------ قواعد IP --------------------------------
-- حجب أو سماح أو إبطاء أو تحدٍّ لعنوان أو نطاق (CIDR) أو دولة أو مزود (ASN)،
-- على مستوى المنصة كلها أو بوابة بعينها أو عميل API بعينه، يدوياً أو آلياً بمهلة.
-- تُنسخ القواعد إلى الحافة (WAF/بوابة API/Redis) عبر صندوق الأحداث فور تغيّرها.
CREATE TABLE sec.ip_rule (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_type     text NOT NULL CHECK (rule_type IN ('CIDR','COUNTRY','ASN')),
  cidr          cidr,
  country_code  char(2),
  asn           int,
  action        text NOT NULL CHECK (action IN ('BLOCK','ALLOW','THROTTLE','CHALLENGE')),
  scope         text NOT NULL DEFAULT 'ALL' CHECK (scope IN ('ALL','PASSENGER','OPERATOR','AGENCY','ADMIN','API','PAYMENT_WEBHOOK','DRIVER')),
  api_client_id bigint REFERENCES iam.api_client(id), -- قاعدة خاصة بعميل API واحد
  priority      smallint NOT NULL DEFAULT 100,        -- الأعلى يُطبَّق أولاً
  reason        text NOT NULL,
  source        text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL','AUTO_RATE','AUTO_AUTH','AUTO_ABUSE','WAF','THREAT_FEED','SOC','AUTHORITY')),
  evidence      jsonb,
  hit_count     bigint NOT NULL DEFAULT 0,            -- يُحدَّث دورياً من سجلات الحافة
  last_hit_at   timestamptz,
  created_by    bigint REFERENCES iam.app_user(id),
  approved_by   bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz,                          -- فارغ = دائم
  revoked_at    timestamptz,
  revoked_by    bigint REFERENCES iam.app_user(id),
  revoke_reason text,
  CHECK ((rule_type = 'CIDR' AND cidr IS NOT NULL) OR (rule_type = 'COUNTRY' AND country_code IS NOT NULL) OR (rule_type = 'ASN' AND asn IS NOT NULL)),
  CHECK (source NOT LIKE 'AUTO%' OR expires_at IS NOT NULL)   -- الحجب الآلي مؤقت دائماً
);
CREATE INDEX ip_rule_cidr_gist ON sec.ip_rule USING gist (cidr inet_ops) WHERE revoked_at IS NULL AND rule_type = 'CIDR';
CREATE INDEX ip_rule_country ON sec.ip_rule (country_code) WHERE revoked_at IS NULL AND rule_type = 'COUNTRY';
CREATE INDEX ip_rule_asn ON sec.ip_rule (asn) WHERE revoked_at IS NULL AND rule_type = 'ASN';
COMMENT ON TABLE sec.ip_rule IS 'حجب/سماح/إبطاء عنوان أو نطاق أو دولة أو ASN لكل بوابة أو عميل API؛ يدوي أو آلي بمهلة';

-- القرار لعنوان معيّن: الأعلى أولوية ثم الأدق نطاقاً
CREATE OR REPLACE FUNCTION sec.ip_decision(
  p_ip inet, p_scope text, p_country char(2) DEFAULT NULL, p_asn int DEFAULT NULL, p_api_client_id bigint DEFAULT NULL
) RETURNS TABLE (action text, rule_id bigint, reason text)
LANGUAGE sql STABLE AS $$
  SELECT r.action, r.id, r.reason
  FROM sec.ip_rule r
  WHERE r.revoked_at IS NULL
    AND (r.expires_at IS NULL OR r.expires_at > now())
    AND (r.scope = 'ALL' OR r.scope = p_scope)
    AND (r.api_client_id IS NULL OR r.api_client_id = p_api_client_id)
    AND ((r.rule_type = 'CIDR' AND r.cidr >>= p_ip)
      OR (r.rule_type = 'COUNTRY' AND r.country_code = p_country)
      OR (r.rule_type = 'ASN' AND r.asn = p_asn))
  ORDER BY r.priority DESC,
           CASE r.rule_type WHEN 'CIDR' THEN masklen(r.cidr) + 100 WHEN 'ASN' THEN 50 ELSE 0 END DESC,
           CASE r.action WHEN 'BLOCK' THEN 0 WHEN 'CHALLENGE' THEN 1 WHEN 'THROTTLE' THEN 2 ELSE 3 END
  LIMIT 1
$$;
COMMENT ON FUNCTION sec.ip_decision IS 'يعيد القرار المطبق على عنوان IP لبوابة معيّنة (فارغ = لا قاعدة، يُسمح)';

-- حجب آلي متصاعد: كل تكرار خلال 30 يوماً يضاعف المدة (حتى 30 يوماً)
CREATE OR REPLACE FUNCTION sec.auto_block_ip(
  p_ip inet, p_scope text, p_source text, p_reason text, p_base_minutes int DEFAULT 15, p_evidence jsonb DEFAULT NULL
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE prior int; mins int; rid bigint;
BEGIN
  SELECT count(*) INTO prior FROM sec.ip_rule
   WHERE rule_type = 'CIDR' AND cidr = set_masklen(p_ip::cidr, CASE WHEN family(p_ip) = 4 THEN 32 ELSE 128 END)
     AND source LIKE 'AUTO%' AND created_at > now() - interval '30 days';
  mins := least(p_base_minutes * (2 ^ prior)::int, 43200);
  INSERT INTO sec.ip_rule (rule_type, cidr, action, scope, priority, reason, source, evidence, expires_at)
  VALUES ('CIDR', set_masklen(p_ip::cidr, CASE WHEN family(p_ip) = 4 THEN 32 ELSE 128 END), 'BLOCK', p_scope, 150,
          p_reason, p_source, p_evidence, now() + make_interval(mins => mins))
  RETURNING id INTO rid;
  RETURN rid;
END $$;
COMMENT ON FUNCTION sec.auto_block_ip IS 'حجب آلي مؤقت لعنوان يستغل المنصة (محاولات دخول، إغراق، كشط) بمدة متصاعدة';

-- نشر أي تغيير في القواعد إلى الحافة فوراً
CREATE OR REPLACE FUNCTION sec.tg_ip_rule_publish() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
  VALUES ('sec.ip_rule.changed', 'ip_rule', NEW.id, to_jsonb(NEW) - 'evidence');
  RETURN NEW;
END $$;
CREATE TRIGGER ip_rule_publish AFTER INSERT OR UPDATE ON sec.ip_rule FOR EACH ROW EXECUTE FUNCTION sec.tg_ip_rule_publish();
CREATE TRIGGER ip_rule_no_delete BEFORE DELETE ON sec.ip_rule FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

-- هل العنوان ضمن قائمة السماح لعميل API (إن وُجدت)؟
CREATE OR REPLACE FUNCTION sec.api_client_ip_allowed(p_api_client_id bigint, p_ip inet) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN c.ip_allowlist IS NULL OR cardinality(c.ip_allowlist) = 0 THEN true
              ELSE EXISTS (SELECT 1 FROM unnest(c.ip_allowlist) a WHERE a >>= p_ip) END
  FROM iam.api_client c WHERE c.id = p_api_client_id
$$;

-- ------------------------------ المخاطر والاحتيال (16.4) -------------
CREATE TABLE sec.blocklist_entry (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entry_type  text NOT NULL CHECK (entry_type IN ('DEVICE','PHONE','EMAIL','IBAN','ID_DOC','CARD_BIN')),
  value_hash  bytea NOT NULL,
  reason      text NOT NULL,
  added_by    bigint REFERENCES iam.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz,
  UNIQUE (entry_type, value_hash)
);
COMMENT ON TABLE sec.blocklist_entry IS 'قائمة حظر بالقيم المجزأة (جهاز، هاتف، IBAN، وثيقة)';

CREATE TABLE sec.risk_assessment (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subject_type  text NOT NULL CHECK (subject_type IN ('USER','PARTY','BOOKING','PAYMENT','WITHDRAWAL','API_CLIENT','IP')),
  subject_id    bigint,
  event_type    text NOT NULL,
  score         smallint NOT NULL CHECK (score BETWEEN 0 AND 100),
  signals       jsonb NOT NULL,
  decision      text NOT NULL CHECK (decision IN ('ALLOW','STEP_UP','REVIEW','DENY')),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX risk_subject_idx ON sec.risk_assessment (subject_type, subject_id, created_at DESC);

CREATE TABLE sec.fraud_case (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subject_type text NOT NULL,
  subject_id  bigint NOT NULL,
  rule_code   text NOT NULL,
  status      text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','INVESTIGATING','CONFIRMED','DISMISSED')),
  assigned_to bigint REFERENCES iam.app_user(id),
  outcome     text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  closed_at   timestamptz
);

CREATE TABLE sec.security_event (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source          text NOT NULL,                      -- APP, WAF, GATEWAY, DB, SOC
  severity        text NOT NULL CHECK (severity IN ('INFO','LOW','MEDIUM','HIGH','CRITICAL')),
  category        text NOT NULL,                      -- BRUTE_FORCE, TAMPER, PRIV_ESC, DATA_EXPORT ...
  user_id         bigint,
  api_client_id   bigint,
  ip              inet,
  details         jsonb NOT NULL,
  correlation_id  uuid,
  ip_rule_id      bigint REFERENCES sec.ip_rule(id),  -- إن نتج عنه حجب
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX security_event_ip_idx ON sec.security_event (ip, created_at DESC);
CREATE TRIGGER security_event_immutable BEFORE UPDATE OR DELETE ON sec.security_event FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE sec.security_event IS 'الأحداث الأمنية لمركز العمليات (SOC) وقواعد الكشف (16.20)';

CREATE TABLE sec.access_review (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  role_id     bigint REFERENCES iam.role(id),
  reviewer_id bigint NOT NULL REFERENCES iam.app_user(id),
  decision    text NOT NULL CHECK (decision IN ('KEEP','REVOKE')),
  reviewed_on date NOT NULL DEFAULT current_date
);

CREATE TABLE sec.break_glass_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id    bigint NOT NULL REFERENCES iam.app_user(id),
  reason      text NOT NULL,
  approver_id bigint REFERENCES iam.app_user(id),
  started_at  timestamptz NOT NULL DEFAULT now(),
  ended_at    timestamptz,
  CHECK (approver_id IS NULL OR approver_id <> actor_id)
);
COMMENT ON TABLE sec.break_glass_log IS 'وصول الطوارئ بصلاحيات مرتفعة: بسبب وموافقة ومدة';

-- ------------------------------ منع العبث وتوقيع المستندات (16.25) ----
CREATE TABLE sec.document_signature (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  doc_type    text NOT NULL CHECK (doc_type IN ('TICKET','INVOICE','RECEIPT','BOARDING_PASS','MANIFEST','STATEMENT')),
  doc_ref_id  bigint NOT NULL,
  serial_no   text NOT NULL UNIQUE,
  sha256      bytea NOT NULL,
  signature   bytea NOT NULL,
  key_id      int NOT NULL REFERENCES sec.key_registry(id),
  file_id     bigint REFERENCES ref.file_object(id),
  issued_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at  timestamptz
);
CREATE INDEX document_signature_ref_idx ON sec.document_signature (doc_type, doc_ref_id);
COMMENT ON TABLE sec.document_signature IS 'كل مستند رسمي يصدره الخادم موقّعاً؛ صفحة التحقق تقارن به فيُكشف أي مستند معدَّل';

CREATE TABLE sec.tamper_event (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id       bigint,
  api_client_id bigint,
  ip            inet,
  endpoint      text NOT NULL,
  field         text NOT NULL,
  client_value  text,
  server_value  text,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER tamper_event_immutable BEFORE UPDATE OR DELETE ON sec.tamper_event FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE sec.tamper_event IS 'محاولات إرسال قيم تخالف المحسوب في الخادم (سعر، تاريخ، حالة دفع)';

-- ------------------------------ وحدة الأمن والامتثال (4.9) -----------
CREATE TABLE sec.authority_profile (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code          text NOT NULL UNIQUE,
  name          text NOT NULL,
  authority_type text NOT NULL CHECK (authority_type IN ('TRAFFIC','PASSPORT','BORDER','PUBLIC_SECURITY','CUSTOMS','REGULATOR','POLICE')),
  protocol      text NOT NULL CHECK (protocol IN ('REST','SOAP','SFTP','MQ','MANUAL')),
  endpoint      text,
  cert_ref      text,
  data_scope    jsonb NOT NULL DEFAULT '{}',
  fail_policy   text NOT NULL DEFAULT 'ALLOW_QUEUE' CHECK (fail_policy IN ('ALLOW_QUEUE','BLOCK')),
  sla_ms        int,
  active        boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE sec.authority_profile IS 'تعريف الجهة الأمنية ومحوّلها (تعريف بلا ربط في المرحلة 1 — القرار 88)';

CREATE TABLE sec.authority_policy (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  authority_id  bigint NOT NULL REFERENCES sec.authority_profile(id),
  applies_to    jsonb NOT NULL,
  checkpoint    text NOT NULL CHECK (checkpoint IN ('PRE_ISSUE','PRE_DEPARTURE','DEPARTURE')),
  mandatory     boolean NOT NULL DEFAULT true,
  decision_map  jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE sec.screening_request (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  authority_id    bigint NOT NULL REFERENCES sec.authority_profile(id),
  subject_type    text NOT NULL CHECK (subject_type IN ('PASSENGER','DRIVER','HOST','VEHICLE','COMPANY')),
  subject_id      bigint NOT NULL,
  context_type    text NOT NULL CHECK (context_type IN ('BOOKING','TRIP')),
  context_id      bigint NOT NULL,
  identifier_hash bytea NOT NULL,
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','ANSWERED','TIMEOUT')),
  requested_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sec.screening_result (
  request_id  bigint PRIMARY KEY REFERENCES sec.screening_request(id),
  decision    text NOT NULL CHECK (decision IN ('ALLOW','REVIEW','DENY')),
  reason_code text,
  silent_flag boolean NOT NULL DEFAULT false,
  response_ref text,
  valid_until timestamptz,
  reviewed_by bigint REFERENCES iam.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sec.watchlist_entry (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  authority_id    bigint REFERENCES sec.authority_profile(id),
  identifier_type text NOT NULL,
  identifier_hash bytea NOT NULL,
  action          text NOT NULL CHECK (action IN ('DENY','REVIEW','NOTIFY')),
  valid           tstzrange NOT NULL,
  source_ref      text,
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','LIFTED')),
  created_by      bigint REFERENCES iam.app_user(id),
  UNIQUE (identifier_type, identifier_hash, authority_id)
);
COMMENT ON TABLE sec.watchlist_entry IS 'قائمة المراقبة والمنع بالمطابقة المجزأة دون نسخ البيانات الكاملة';

CREATE TABLE sec.manifest_submission (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id       bigint NOT NULL REFERENCES ops.trip(id),
  authority_id  bigint REFERENCES sec.authority_profile(id),
  manifest_type text NOT NULL CHECK (manifest_type IN ('PASSENGER','CREW','CARGO')),
  version       int NOT NULL,
  payload_file_id bigint REFERENCES ref.file_object(id),
  sha256        bytea NOT NULL,
  signature     bytea,
  status        text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','SENT','ACKNOWLEDGED','REJECTED','MANUAL')),
  ack_ref       text,
  retry_count   smallint NOT NULL DEFAULT 0,
  created_by    bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  sent_at       timestamptz,
  UNIQUE (trip_id, manifest_type, version)
);
COMMENT ON TABLE sec.manifest_submission IS 'المنافست (يدوي في المرحلة 1) بإصدارات وتوقيع';

CREATE TABLE sec.authority_order (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  authority_id  bigint NOT NULL REFERENCES sec.authority_profile(id),
  order_ref     text NOT NULL,
  order_type    text NOT NULL CHECK (order_type IN ('BAN','STOP','REROUTE','INSPECT')),
  target_type   text NOT NULL,
  target_id     bigint NOT NULL,
  status        text NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED','EXECUTING','EXECUTED','REJECTED')),
  received_at   timestamptz NOT NULL DEFAULT now(),
  executed_at   timestamptz,
  executed_by   bigint REFERENCES iam.app_user(id),
  UNIQUE (authority_id, order_ref)
);

CREATE TABLE sec.authority_data_request (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  authority_id  bigint NOT NULL REFERENCES sec.authority_profile(id),
  official_ref  text NOT NULL,
  legal_basis   text NOT NULL,
  scope         jsonb NOT NULL,
  requested_by  bigint NOT NULL REFERENCES iam.app_user(id),
  approved_by   bigint REFERENCES iam.app_user(id),
  status        text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','DELIVERED','REJECTED')),
  delivered_at  timestamptz,
  delivery_ref  text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (approved_by IS NULL OR approved_by <> requested_by)
);
COMMENT ON TABLE sec.authority_data_request IS 'طلب بيانات رسمي بتفويض ثنائي؛ لا تسليم لأي جهة خارج هذا المسار';

CREATE TABLE sec.sos_event (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id       bigint REFERENCES ops.trip(id),
  triggered_by  bigint REFERENCES iam.app_user(id),
  lat           numeric(9,6),
  lng           numeric(9,6),
  status        text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','ACKNOWLEDGED','CLOSED')),
  notified      jsonb NOT NULL DEFAULT '[]',
  incident_id   bigint REFERENCES ops.incident(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE gov.privacy_incident ADD CONSTRAINT privacy_incident_secevent_fk FOREIGN KEY (security_event_id) REFERENCES sec.security_event(id);

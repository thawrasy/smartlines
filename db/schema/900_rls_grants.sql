-- =====================================================================
-- 900: عزل المستأجرين (Row Level Security) والصلاحيات على مستوى القاعدة
-- دور التطبيق masslak_app ليس مالك الجداول، فتنطبق عليه السياسات دائماً.
-- إن لم يُضبط سياق الطلب (sys.set_context) لا يُرى أي صف خاص (الرفض افتراضي).
-- =====================================================================

-- ------------------------------ الصلاحيات العامة ---------------------
DO $$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY['sys','ref','iam','net','fleet','pricing','ops','sales','fin','acct','crm','gov','sec','audit'] LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO masslak_app, masslak_readonly, masslak_auditor', s);
    IF s <> 'audit' THEN
      EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO masslak_app', s);
      EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO masslak_readonly', s);
    END IF;
  END LOOP;
END $$;

-- السجلات: التطبيق يضيف فقط، والمدقق يقرأ فقط
GRANT INSERT ON audit.auth_event, audit.activity_log, audit.data_access_log TO masslak_app;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO masslak_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA sec   TO masslak_auditor;

-- جداول الإلحاق فقط: سحب التعديل والحذف صراحة (إضافة إلى المشغّلات)
REVOKE UPDATE, DELETE ON
  fin.ledger_txn, fin.ledger_entry, fin.tax_ledger, fin.payment_notification,
  pricing.points_ledger, sales.boarding_event, acct.einvoice_submission,
  crm.case_event, crm.ai_tool_call, sec.security_event, sec.tamper_event, sec.document_signature
FROM masslak_app;
REVOKE DELETE ON acct.einvoice_document, acct.journal_entry, sec.ip_rule, iam.party, sales.booking, sales.ticket, fin.payment FROM masslak_app;

-- مفاتيح التشفير: قراءة المرجع فقط للتطبيق
REVOKE INSERT, UPDATE, DELETE ON sec.key_registry FROM masslak_app;

-- الدوال الإدارية: ليست للتطبيق
REVOKE EXECUTE ON FUNCTION audit.seal(text, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION sys.drop_partitions_older_than(text, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION sys.ensure_monthly_partitions(text, int, int) FROM PUBLIC;

-- ------------------------------ سياسات العزل ------------------------
-- (أ) جداول خاصة بالناقل بالكامل
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'fleet.vehicle','fleet.crew_profile','fleet.license_record','fleet.seat_price_rule',
    'ops.trip_template','ops.incident','fin.settlement_batch','fin.payout','fin.payout_schedule',
    'net.service_number','sys.company_setting','fin.tax_ledger']
  LOOP
    CONTINUE WHEN to_regclass(t) IS NULL;
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY tenant_isolation ON %s USING (sys.tenant_visible(company_id)) WITH CHECK (sys.tenant_visible(company_id))', t);
  END LOOP;
END $$;

-- التأمين وعقد الإيجار عبر المركبة
ALTER TABLE fleet.insurance_policy ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON fleet.insurance_policy
  USING (EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = vehicle_id));   -- يرث سياسة المركبة
ALTER TABLE fleet.vehicle_lease ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON fleet.vehicle_lease
  USING (sys.tenant_visible(lessee_company_id)) WITH CHECK (sys.tenant_visible(lessee_company_id));

-- (ب) الشركة وأعضاؤها
ALTER TABLE iam.company ENABLE ROW LEVEL SECURITY;
CREATE POLICY company_read ON iam.company FOR SELECT USING (approval_status = 'APPROVED' OR sys.tenant_visible(id));
CREATE POLICY company_write ON iam.company FOR ALL USING (sys.tenant_visible(id)) WITH CHECK (sys.tenant_visible(id));

ALTER TABLE iam.company_member ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_isolation ON iam.company_member
  USING (sys.tenant_visible(company_id) OR user_id = sys.ctx_user_id())
  WITH CHECK (sys.tenant_visible(company_id));

-- (ج) كتالوج عام للقراءة، والكتابة للناقل فقط
ALTER TABLE net.route ENABLE ROW LEVEL SECURITY;
CREATE POLICY route_read  ON net.route FOR SELECT USING (status = 'ACTIVE' OR sys.tenant_visible(company_id));
CREATE POLICY route_write ON net.route FOR ALL USING (sys.tenant_visible(company_id)) WITH CHECK (sys.tenant_visible(company_id));

ALTER TABLE ops.trip ENABLE ROW LEVEL SECURITY;
CREATE POLICY trip_read  ON ops.trip FOR SELECT USING (status IN ('PUBLISHED','BOARDING','DEPARTED','COMPLETED') OR sys.tenant_visible(company_id));
CREATE POLICY trip_write ON ops.trip FOR ALL USING (sys.tenant_visible(company_id)) WITH CHECK (sys.tenant_visible(company_id));

ALTER TABLE net.station ENABLE ROW LEVEL SECURITY;
CREATE POLICY station_read  ON net.station FOR SELECT USING (status = 'ACTIVE' OR sys.ctx_is_platform() OR owner_company_id = sys.ctx_company_id());
CREATE POLICY station_write ON net.station FOR ALL
  USING (sys.ctx_is_platform() OR (station_class <> 'CENTRAL' AND owner_company_id = sys.ctx_company_id()))
  WITH CHECK (sys.ctx_is_platform() OR (station_class <> 'CENTRAL' AND owner_company_id = sys.ctx_company_id()));

-- (د) بيانات يراها الناقل المعني أو صاحبها
ALTER TABLE sales.booking ENABLE ROW LEVEL SECURITY;
CREATE POLICY booking_isolation ON sales.booking
  USING (sys.tenant_visible(company_id) OR booker_party_id = sys.ctx_party_id())
  WITH CHECK (sys.tenant_visible(company_id) OR booker_party_id = sys.ctx_party_id());

ALTER TABLE fin.wallet ENABLE ROW LEVEL SECURITY;
CREATE POLICY wallet_isolation ON fin.wallet
  USING (sys.ctx_is_platform() OR (company_id IS NOT NULL AND company_id = sys.ctx_company_id()) OR owner_party_id = sys.ctx_party_id());

ALTER TABLE acct.einvoice_document ENABLE ROW LEVEL SECURITY;
CREATE POLICY einvoice_isolation ON acct.einvoice_document
  USING (sys.tenant_visible(company_id) OR buyer_party_id = sys.ctx_party_id());

ALTER TABLE crm.case ENABLE ROW LEVEL SECURITY;
CREATE POLICY case_isolation ON crm.case
  USING (sys.tenant_visible(company_id) OR party_id = sys.ctx_party_id());

-- (هـ) الدفاتر: دفاتر المنصة (company_id فارغ) للمنصة فقط
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['acct.gl_account','acct.journal_entry','acct.cost_center','acct.accounting_connection'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY books_isolation ON %s USING (sys.ctx_is_platform() OR company_id = sys.ctx_company_id()) WITH CHECK (sys.ctx_is_platform() OR company_id = sys.ctx_company_id())', t);
  END LOOP;
END $$;

-- (و) مفاتيح API: الناقل يرى مفاتيحه، والمنصة الكل
ALTER TABLE iam.api_client ENABLE ROW LEVEL SECURITY;
CREATE POLICY api_client_isolation ON iam.api_client
  USING (sys.ctx_is_platform() OR (company_id IS NOT NULL AND company_id = sys.ctx_company_id()) OR id = sys.ctx_api_client_id());

-- (ز) قواعد IP والأحداث الأمنية: المنصة فقط
ALTER TABLE sec.ip_rule ENABLE ROW LEVEL SECURITY;
CREATE POLICY ip_rule_platform ON sec.ip_rule USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
ALTER TABLE sec.security_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY security_event_platform ON sec.security_event FOR SELECT USING (sys.ctx_is_platform());
CREATE POLICY security_event_insert ON sec.security_event FOR INSERT WITH CHECK (true);

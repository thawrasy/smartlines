-- =====================================================================
-- 950: البيانات الأولية — المرجعية، المنصة، كتالوج الصلاحيات والأدوار، الإعدادات
-- كتالوج الصلاحيات والأدوار مأخوذ من مصفوفة الصلاحيات (القسم 33)
-- =====================================================================

INSERT INTO ref.currency (code, name_ar, name_en, minor_unit) VALUES
  ('SYP','ليرة سورية','Syrian Pound',2), ('USD','دولار أمريكي','US Dollar',2), ('EUR','يورو','Euro',2),
  ('SAR','ريال سعودي','Saudi Riyal',2), ('JOD','دينار أردني','Jordanian Dinar',3), ('LBP','ليرة لبنانية','Lebanese Pound',2),
  ('TRY','ليرة تركية','Turkish Lira',2), ('IQD','دينار عراقي','Iraqi Dinar',3);

INSERT INTO ref.country (code, name_ar, name_en, phone_prefix, default_currency) VALUES
  ('SY','سوريا','Syria','+963','SYP'), ('LB','لبنان','Lebanon','+961','LBP'), ('JO','الأردن','Jordan','+962','JOD'),
  ('IQ','العراق','Iraq','+964','IQD'), ('TR','تركيا','Turkey','+90','TRY'), ('SA','السعودية','Saudi Arabia','+966','SAR');

INSERT INTO ref.city (code, country_code, region, name_ar, name_en, lat, lng) VALUES
  ('DAM','SY','دمشق','دمشق','Damascus',33.513800,36.276500),
  ('RDM','SY','ريف دمشق','ريف دمشق','Rif Dimashq',33.516700,36.483300),
  ('ALP','SY','حلب','حلب','Aleppo',36.202100,37.134300),
  ('HMS','SY','حمص','حمص','Homs',34.730800,36.709400),
  ('HMA','SY','حماة','حماة','Hama',35.131800,36.757800),
  ('LTK','SY','اللاذقية','اللاذقية','Latakia',35.523800,35.791700),
  ('TRT','SY','طرطوس','طرطوس','Tartus',34.889000,35.886600),
  ('IDL','SY','إدلب','إدلب','Idlib',35.930600,36.633900),
  ('DRZ','SY','دير الزور','دير الزور','Deir ez-Zor',35.336000,40.140800),
  ('RQA','SY','الرقة','الرقة','Raqqa',35.950000,39.016700),
  ('HSK','SY','الحسكة','الحسكة','Al-Hasakah',36.502400,40.747700),
  ('DRA','SY','درعا','درعا','Daraa',32.625000,36.106000),
  ('SWD','SY','السويداء','السويداء','As-Suwayda',32.708900,36.569500),
  ('QNT','SY','القنيطرة','القنيطرة','Quneitra',33.125600,35.824400),
  ('BEY','LB','بيروت','بيروت','Beirut',33.893800,35.501800),
  ('AMM','JO','عمّان','عمّان','Amman',31.945400,35.928400);

-- مراجع المفاتيح (المفاتيح نفسها في KMS)
INSERT INTO sec.key_registry (key_ref, purpose, data_class, algorithm) VALUES
  ('kms://masslak/field/restricted/v1', 'FIELD_ENCRYPTION', 'RESTRICTED', 'AES-256-GCM'),
  ('kms://masslak/field/confidential/v1', 'FIELD_ENCRYPTION', 'CONFIDENTIAL', 'AES-256-GCM'),
  ('kms://masslak/bidx/v1', 'BLIND_INDEX', 'RESTRICTED', 'HMAC-SHA256'),
  ('kms://masslak/sign/documents/v1', 'DOCUMENT_SIGNING', 'RESTRICTED', 'ECDSA-P256'),
  ('kms://masslak/sign/qr/v1', 'QR_SIGNING', 'RESTRICTED', 'ECDSA-P256'),
  ('kms://masslak/webhook/v1', 'WEBHOOK_SECRET', 'RESTRICTED', 'AES-256-GCM');

-- طرف المنصة ومحافظها الداخلية
INSERT INTO iam.party (party_type, legal_name, name_en, country_code, verification_status)
VALUES ('COMPANY', 'منصة مسلك', 'Masslak Platform', 'SY', 'VERIFIED');

INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency, allow_negative)
SELECT p.id, w.t, w.l, c.code, w.neg
FROM iam.party p
CROSS JOIN (VALUES ('PLATFORM','إيراد المنصة',false), ('ESCROW','أموال الضمان',false), ('COMMISSION','العمولات',false),
                   ('TAX','الضرائب المحصلة',false), ('GATEWAY_CLEARING','مقاصة بوابات الدفع',true),
                   ('BANK_CLEARING','مقاصة التحويلات البنكية',true), ('SPONSOR','ذمم الرعاة',true)) AS w(t, l, neg)
CROSS JOIN (VALUES ('SYP'), ('USD')) AS c(code)
WHERE p.name_en = 'Masslak Platform';

INSERT INTO sales.channel (code, channel_type) VALUES
  ('WEB','DIRECT'), ('APP_ANDROID','DIRECT'), ('APP_IOS','DIRECT'), ('COUNTER','COUNTER'), ('CALL_CENTER','CALL_CENTER');

-- ------------------------------ كتالوج الصلاحيات -----------------------
INSERT INTO iam.permission (code, module, scope, description_ar, is_sensitive) VALUES
  ('trip.search','sales','BOTH','البحث وعرض الرحلات',false),
  ('booking.self','sales','BOTH','حجز وإلغاء حجز لنفسه',false),
  ('booking.on_behalf','sales','COMPANY','حجز لعميل نيابة (رصيد الوكالة)',false),
  ('sale.cash','sales','COMPANY','البيع النقدي',true),
  ('wallet.self','fin','BOTH','إدارة المحفظة: شحن وكشف',false),
  ('vehicle.manage','fleet','COMPANY','إنشاء وتعديل المركبات',false),
  ('vehicle.ownership','fleet','COMPANY','ملكية المركبات وعقود الإيجار',false),
  ('trip.publish','ops','COMPANY','نشر الرحلات وجدولتها',false),
  ('trip.reschedule','ops','BOTH','إعادة جدولة رحلة',false),
  ('trip.complete','ops','BOTH','إتمام الرحلة وتحرير الأموال',true),
  ('trip.assign_crew','ops','COMPANY','تعيين السائق والطاقم',false),
  ('driver.tracking','ops','COMPANY','إرسال الموقع وتسجيل المحطات',false),
  ('boarding.scan','ops','BOTH','مسح QR وصعود الركاب',false),
  ('manifest.view','ops','BOTH','قائمة الركاب',true),
  ('tracking.own','ops','COMPANY','التتبع المباشر لرحلات الشركة',false),
  ('tracking.all','ops','PLATFORM','التتبع والإنذارات لكل الرحلات',false),
  ('travel_docs.verify','sec','PLATFORM','التحقق من وثائق السفر',true),
  ('watchlist.manage','sec','PLATFORM','قوائم المنع والمراقبة',true),
  ('company.staff','iam','COMPANY','إدارة موظفي الشركة وأدوارها',true),
  ('company.login_log','audit','BOTH','سجل دخول موظفي الشركة',false),
  ('company.billing','fin','BOTH','اشتراك الشركة وفواتيرها',false),
  ('company.api_keys','iam','COMPANY','مفاتيح API للناقل',true),
  ('company.payout_schedule','fin','BOTH','جدول تحويلات الشركة',true),
  ('company.approve','iam','PLATFORM','فتح حساب ناقل واعتماده',true),
  ('pricing.tax_commission','pricing','PLATFORM','مخططات الضرائب والعمولات',true),
  ('policy.matrix','gov','PLATFORM','مصفوفة الصلاحيات وتغييرها',true),
  ('campaign.manage','pricing','PLATFORM','إنشاء الحملات وتشغيلها',false),
  ('campaign.approve_budget','pricing','PLATFORM','اعتماد ميزانية الحملات',true),
  ('payment.fee_policy','fin','PLATFORM','سياسة رسوم الدفع',true),
  ('cash.remittance','fin','PLATFORM','إيداع وتوريد النقد',true),
  ('payout.run','fin','PLATFORM','تشغيل التحويلات والفوترة',true),
  ('ledger.reconcile','fin','PLATFORM','الدفتر والمطابقة',true),
  ('withdrawal.approve','fin','PLATFORM','اعتماد طلبات السحب',true),
  ('case.handle','crm','BOTH','فتح الشكاوى ومتابعتها',false),
  ('compensation.decide','crm','PLATFORM','قرار التعويض',true),
  ('compensation.pay','fin','PLATFORM','اعتماد دفع التعويض',true),
  ('ai.use','crm','BOTH','استعمال المساعد الذكي',false),
  ('ai.manage','crm','PLATFORM','إدارة أدوات المساعد ومعرفته',true),
  ('report.company','report','COMPANY','تقارير الناقل',false),
  ('report.platform','report','PLATFORM','تقارير المنصة',false),
  ('regulator.dashboard','gov','PLATFORM','لوحة الجهة الناظمة',false),
  ('audit.view','audit','PLATFORM','سجل التدقيق',true),
  ('privacy.manage','gov','PLATFORM','طلبات الخصوصية وحوادث البيانات',true),
  ('loyalty.self','pricing','BOTH','كسب واستبدال نقاطي',false),
  ('loyalty.manage','pricing','PLATFORM','إدارة برنامج الولاء',true),
  ('obligation.manage','gov','PLATFORM','سجل الالتزامات التشريعية',false),
  ('carrier_code.approve','net','PLATFORM','اعتماد رموز الناقلين',true),
  ('license.approve_change','fleet','PLATFORM','اعتماد تعديل تواريخ التراخيص',true),
  ('station.approve','net','PLATFORM','اعتماد نقاط الشركات',false),
  ('security.ip_rules','sec','PLATFORM','إدارة حجب العناوين والنطاقات',true),
  ('security.api_clients','sec','PLATFORM','إدارة عملاء API واعتمادهم',true),
  ('einvoice.manage','acct','BOTH','الفوترة الإلكترونية والملف الضريبي',true),
  ('incident.manage','ops','BOTH','الحوادث وقرارات الاستمرارية',false),
  ('shariah.approve','gov','PLATFORM','اعتماد المنتجات المالية شرعياً',true);

-- ------------------------------ الأدوار النظامية ----------------------
INSERT INTO iam.role (code, name_ar, scope, is_system) VALUES
  ('PLATFORM_ADMIN','مسؤول المنصة','PLATFORM',true),
  ('PLATFORM_FINANCE','المالية','PLATFORM',true),
  ('PLATFORM_SECURITY','الأمن والامتثال','PLATFORM',true),
  ('PLATFORM_SUPPORT','الدعم','PLATFORM',true),
  ('REGULATOR','الجهة الناظمة','PLATFORM',true),
  ('PLATFORM_MARKETING','التسويق','PLATFORM',true),
  ('CARRIER_OPERATIONS','عمليات الناقل (قالب)','COMPANY',true),
  ('CARRIER_COUNTER','موظف شباك (قالب)','COMPANY',true),
  ('CARRIER_DRIVER','سائق (قالب)','COMPANY',true),
  ('CARRIER_ACCOUNTANT','محاسب الناقل (قالب)','COMPANY',true);

INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, x.p FROM iam.role r JOIN (VALUES
  ('PLATFORM_ADMIN','trip.search'),('PLATFORM_ADMIN','company.approve'),('PLATFORM_ADMIN','pricing.tax_commission'),
  ('PLATFORM_ADMIN','policy.matrix'),('PLATFORM_ADMIN','campaign.approve_budget'),('PLATFORM_ADMIN','payment.fee_policy'),
  ('PLATFORM_ADMIN','tracking.all'),('PLATFORM_ADMIN','report.platform'),('PLATFORM_ADMIN','audit.view'),
  ('PLATFORM_ADMIN','privacy.manage'),('PLATFORM_ADMIN','loyalty.manage'),('PLATFORM_ADMIN','carrier_code.approve'),
  ('PLATFORM_ADMIN','license.approve_change'),('PLATFORM_ADMIN','station.approve'),('PLATFORM_ADMIN','ai.manage'),
  ('PLATFORM_ADMIN','ai.use'),('PLATFORM_ADMIN','trip.reschedule'),('PLATFORM_ADMIN','trip.complete'),
  ('PLATFORM_FINANCE','wallet.self'),('PLATFORM_FINANCE','cash.remittance'),('PLATFORM_FINANCE','payout.run'),
  ('PLATFORM_FINANCE','ledger.reconcile'),('PLATFORM_FINANCE','withdrawal.approve'),('PLATFORM_FINANCE','compensation.pay'),
  ('PLATFORM_FINANCE','campaign.approve_budget'),('PLATFORM_FINANCE','report.platform'),('PLATFORM_FINANCE','einvoice.manage'),
  ('PLATFORM_FINANCE','shariah.approve'),('PLATFORM_FINANCE','ai.use'),
  ('PLATFORM_SECURITY','tracking.all'),('PLATFORM_SECURITY','travel_docs.verify'),('PLATFORM_SECURITY','watchlist.manage'),
  ('PLATFORM_SECURITY','manifest.view'),('PLATFORM_SECURITY','boarding.scan'),('PLATFORM_SECURITY','privacy.manage'),
  ('PLATFORM_SECURITY','obligation.manage'),('PLATFORM_SECURITY','security.ip_rules'),('PLATFORM_SECURITY','security.api_clients'),
  ('PLATFORM_SECURITY','shariah.approve'),('PLATFORM_SECURITY','ai.use'),
  ('PLATFORM_SUPPORT','case.handle'),('PLATFORM_SUPPORT','compensation.decide'),('PLATFORM_SUPPORT','ai.use'),
  ('PLATFORM_SUPPORT','trip.search'),
  ('REGULATOR','regulator.dashboard'),('REGULATOR','policy.matrix'),('REGULATOR','report.platform'),
  ('PLATFORM_MARKETING','campaign.manage'),('PLATFORM_MARKETING','loyalty.manage'),('PLATFORM_MARKETING','ai.use'),
  ('CARRIER_OPERATIONS','vehicle.manage'),('CARRIER_OPERATIONS','trip.publish'),('CARRIER_OPERATIONS','trip.reschedule'),
  ('CARRIER_OPERATIONS','trip.assign_crew'),('CARRIER_OPERATIONS','manifest.view'),('CARRIER_OPERATIONS','tracking.own'),
  ('CARRIER_OPERATIONS','incident.manage'),('CARRIER_OPERATIONS','report.company'),('CARRIER_OPERATIONS','case.handle'),
  ('CARRIER_COUNTER','sale.cash'),('CARRIER_COUNTER','boarding.scan'),('CARRIER_COUNTER','trip.search'),
  ('CARRIER_DRIVER','driver.tracking'),('CARRIER_DRIVER','boarding.scan'),('CARRIER_DRIVER','manifest.view'),
  ('CARRIER_DRIVER','incident.manage'),
  ('CARRIER_ACCOUNTANT','company.billing'),('CARRIER_ACCOUNTANT','report.company'),('CARRIER_ACCOUNTANT','einvoice.manage'),
  ('CARRIER_ACCOUNTANT','company.payout_schedule')
) AS x(r, p) ON x.r = r.code AND r.company_id IS NULL;

-- ------------------------------ الإعدادات الافتراضية -------------------
INSERT INTO sys.setting (key, value, description) VALUES
  ('security.auth_fail_ip',   '{"threshold":30,"window_min":60}', 'حجب آلي للعنوان بعد إخفاقات دخول متكررة (16.18)'),
  ('security.auth_fail_user', '{"threshold":5,"window_min":15,"lock_min":15}', 'قفل الحساب بعد إخفاقات متكررة'),
  ('security.admin_ip_allowlist_enforced', 'false', 'عند التفعيل: بوابة الإدارة لا تُفتح إلا من عناوين ALLOW بنطاق ADMIN'),
  ('security.api_key_rotation_days', '90', 'مدة صلاحية مفتاح API'),
  ('retention.audit_months', '84', 'مدة الاحتفاظ بسجلات التدقيق (7 سنوات، تُضبط قانونياً)'),
  ('retention.geo_event_days', '7', 'مدة الاحتفاظ بمواقع التتبع للأفراد'),
  ('booking.hold_minutes', '10', 'مدة الحجز المؤقت للمقاعد'),
  ('booking.sales_cutoff_minutes', '15', 'إقفال البيع قبل المغادرة من المحطة'),
  ('booking.post_departure_policy', '"PHYSICAL_FREE"', 'سياسة البيع بعد الانطلاق الافتراضية (القرار 71)'),
  ('einvoice.mode', '"GENERATION"', 'وضع الفوترة الإلكترونية حتى تفعيل الربط الحكومي'),
  ('features', '{"loyalty":true,"campaigns":true,"ai_assistant":true,"gov_integration":false,"international":false,"cargo":false}', 'مفاتيح التفعيل (2.8)');

INSERT INTO sys.schema_migration (version, description) VALUES ('1.0.0', 'Phase 1 baseline schema');

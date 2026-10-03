-- =====================================================================
-- 950: seed data — reference data, platform party, permission and role catalog, settings
-- The permission and role catalog follows the permission matrix (section 33).
-- All seed values are English; localized labels belong in ref.translation.
-- =====================================================================

-- Native names are endonyms shown in the language picker (display data, not schema)
INSERT INTO ref.locale (code, name, native_name, direction, is_enabled, is_default) VALUES
  ('en','English','English','LTR',true,true),
  ('ar','Arabic',U&'\0627\0644\0639\0631\0628\064A\0629','RTL',true,false),
  ('tr','Turkish',U&'T\00FCrk\00E7e','LTR',false,false),
  ('fr','French',U&'Fran\00E7ais','LTR',false,false),
  ('es','Spanish',U&'Espa\00F1ol','LTR',false,false);

INSERT INTO ref.currency (code, name, minor_unit) VALUES
  ('SYP','Syrian Pound',2), ('USD','US Dollar',2), ('EUR','Euro',2),
  ('SAR','Saudi Riyal',2), ('JOD','Jordanian Dinar',3), ('LBP','Lebanese Pound',2),
  ('TRY','Turkish Lira',2), ('IQD','Iraqi Dinar',3);

INSERT INTO ref.country (code, name, phone_prefix, default_currency) VALUES
  ('SY','Syria','+963','SYP'), ('LB','Lebanon','+961','LBP'), ('JO','Jordan','+962','JOD'),
  ('IQ','Iraq','+964','IQD'), ('TR','Turkey','+90','TRY'), ('SA','Saudi Arabia','+966','SAR');

INSERT INTO ref.city (code, country_code, region, name, lat, lng) VALUES
  ('DAM','SY','Damascus','Damascus',33.513800,36.276500),
  ('RDM','SY','Rif Dimashq','Rif Dimashq',33.516700,36.483300),
  ('ALP','SY','Aleppo','Aleppo',36.202100,37.134300),
  ('HMS','SY','Homs','Homs',34.730800,36.709400),
  ('HMA','SY','Hama','Hama',35.131800,36.757800),
  ('LTK','SY','Latakia','Latakia',35.523800,35.791700),
  ('TRT','SY','Tartus','Tartus',34.889000,35.886600),
  ('IDL','SY','Idlib','Idlib',35.930600,36.633900),
  ('DRZ','SY','Deir ez-Zor','Deir ez-Zor',35.336000,40.140800),
  ('RQA','SY','Raqqa','Raqqa',35.950000,39.016700),
  ('HSK','SY','Al-Hasakah','Al-Hasakah',36.502400,40.747700),
  ('DRA','SY','Daraa','Daraa',32.625000,36.106000),
  ('SWD','SY','As-Suwayda','As-Suwayda',32.708900,36.569500),
  ('QNT','SY','Quneitra','Quneitra',33.125600,35.824400),
  ('BEY','LB','Beirut','Beirut',33.893800,35.501800),
  ('AMM','JO','Amman','Amman',31.945400,35.928400);

-- Key references (the keys themselves live in KMS)
INSERT INTO sec.key_registry (key_ref, purpose, data_class, algorithm) VALUES
  ('kms://masslak/field/restricted/v1', 'FIELD_ENCRYPTION', 'RESTRICTED', 'AES-256-GCM'),
  ('kms://masslak/field/confidential/v1', 'FIELD_ENCRYPTION', 'CONFIDENTIAL', 'AES-256-GCM'),
  ('kms://masslak/bidx/v1', 'BLIND_INDEX', 'RESTRICTED', 'HMAC-SHA256'),
  ('kms://masslak/sign/documents/v1', 'DOCUMENT_SIGNING', 'RESTRICTED', 'ECDSA-P256'),
  ('kms://masslak/sign/qr/v1', 'QR_SIGNING', 'RESTRICTED', 'ECDSA-P256'),
  ('kms://masslak/webhook/v1', 'WEBHOOK_SECRET', 'RESTRICTED', 'AES-256-GCM');

-- Platform party and its internal wallets
INSERT INTO iam.party (party_type, legal_name, country_code, verification_status)
VALUES ('COMPANY', 'Masslak Platform', 'SY', 'VERIFIED');

INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency, allow_negative)
SELECT p.id, w.t, w.l, c.code, w.neg
FROM iam.party p
CROSS JOIN (VALUES ('PLATFORM','Platform revenue',false), ('ESCROW','Escrow funds',false), ('COMMISSION','Commissions',false),
                   ('TAX','Collected taxes',false), ('GATEWAY_CLEARING','Payment gateway clearing',true),
                   ('BANK_CLEARING','Bank transfer clearing',true), ('SPONSOR','Sponsor receivables',true)) AS w(t, l, neg)
CROSS JOIN (VALUES ('SYP'), ('USD')) AS c(code)
WHERE p.legal_name = 'Masslak Platform' AND p.party_type = 'COMPANY';

INSERT INTO sales.channel (code, channel_type) VALUES
  ('WEB','DIRECT'), ('APP_ANDROID','DIRECT'), ('APP_IOS','DIRECT'), ('COUNTER','COUNTER'), ('CALL_CENTER','CALL_CENTER');

-- ------------------------------ Permission catalog ---------------------
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('trip.search','sales','BOTH','Search and view trips',false),
  ('booking.self','sales','BOTH','Book and cancel own bookings',false),
  ('booking.on_behalf','sales','COMPANY','Book on behalf of a customer (agency balance)',false),
  ('sale.cash','sales','COMPANY','Cash sales',true),
  ('wallet.self','fin','BOTH','Wallet management: top-up and statement',false),
  ('vehicle.manage','fleet','COMPANY','Create and edit vehicles',false),
  ('vehicle.ownership','fleet','COMPANY','Vehicle ownership and lease contracts',false),
  ('trip.publish','ops','COMPANY','Publish and schedule trips',false),
  ('trip.reschedule','ops','BOTH','Reschedule a trip',false),
  ('trip.complete','ops','BOTH','Complete a trip and release funds',true),
  ('trip.assign_crew','ops','COMPANY','Assign driver and crew',false),
  ('driver.tracking','ops','COMPANY','Send location and record stops',false),
  ('boarding.scan','ops','BOTH','Scan QR and board passengers',false),
  ('manifest.view','ops','BOTH','Passenger manifest',true),
  ('tracking.own','ops','COMPANY','Live tracking of company trips',false),
  ('tracking.all','ops','PLATFORM','Tracking and alerts for all trips',false),
  ('travel_docs.verify','sec','PLATFORM','Verify travel documents',true),
  ('watchlist.manage','sec','PLATFORM','Ban and watch lists',true),
  ('company.staff','iam','COMPANY','Manage company staff and roles',true),
  ('company.login_log','audit','BOTH','Company staff login log',false),
  ('company.billing','fin','BOTH','Company subscription and invoices',false),
  ('company.api_keys','iam','COMPANY','Carrier API keys',true),
  ('company.payout_schedule','fin','BOTH','Company payout schedule',true),
  ('company.approve','iam','PLATFORM','Open and approve a carrier account',true),
  ('pricing.tax_commission','pricing','PLATFORM','Tax and commission schemes',true),
  ('policy.matrix','gov','PLATFORM','Policy authority matrix and changes',true),
  ('campaign.manage','pricing','PLATFORM','Create and run campaigns',false),
  ('campaign.approve_budget','pricing','PLATFORM','Approve campaign budgets',true),
  ('payment.fee_policy','fin','PLATFORM','Payment fee policy',true),
  ('cash.remittance','fin','PLATFORM','Cash deposit and remittance',true),
  ('payout.run','fin','PLATFORM','Run payouts and billing',true),
  ('ledger.reconcile','fin','PLATFORM','Ledger and reconciliation',true),
  ('withdrawal.approve','fin','PLATFORM','Approve withdrawal requests',true),
  ('case.handle','crm','BOTH','Open and follow up complaints',false),
  ('compensation.decide','crm','PLATFORM','Compensation decision',true),
  ('compensation.pay','fin','PLATFORM','Approve compensation payment',true),
  ('ai.use','crm','BOTH','Use the AI assistant',false),
  ('ai.manage','crm','PLATFORM','Manage assistant tools and knowledge',true),
  ('report.company','report','COMPANY','Carrier reports',false),
  ('report.platform','report','PLATFORM','Platform reports',false),
  ('regulator.dashboard','gov','PLATFORM','Regulator dashboard',false),
  ('audit.view','audit','PLATFORM','Audit log',true),
  ('privacy.manage','gov','PLATFORM','Privacy requests and data incidents',true),
  ('loyalty.self','pricing','BOTH','Earn and redeem own points',false),
  ('loyalty.manage','pricing','PLATFORM','Manage the loyalty program',true),
  ('obligation.manage','gov','PLATFORM','Legal obligations register',false),
  ('carrier_code.approve','net','PLATFORM','Approve carrier codes',true),
  ('license.approve_change','fleet','PLATFORM','Approve license date changes',true),
  ('station.approve','net','PLATFORM','Approve company points',false),
  ('security.ip_rules','sec','PLATFORM','Manage IP and range blocking',true),
  ('security.api_clients','sec','PLATFORM','Manage and approve API clients',true),
  ('einvoice.manage','acct','BOTH','E-invoicing and tax profile',true),
  ('incident.manage','ops','BOTH','Incidents and continuity decisions',false),
  ('shariah.approve','gov','PLATFORM','Shariah approval of financial products',true);

-- ------------------------------ System roles --------------------------
INSERT INTO iam.role (code, name, scope, is_system) VALUES
  ('PLATFORM_ADMIN','Platform administrator','PLATFORM',true),
  ('PLATFORM_FINANCE','Finance','PLATFORM',true),
  ('PLATFORM_SECURITY','Security and compliance','PLATFORM',true),
  ('PLATFORM_SUPPORT','Support','PLATFORM',true),
  ('REGULATOR','Regulator','PLATFORM',true),
  ('PLATFORM_MARKETING','Marketing','PLATFORM',true),
  ('CARRIER_OPERATIONS','Carrier operations (template)','COMPANY',true),
  ('CARRIER_COUNTER','Counter agent (template)','COMPANY',true),
  ('CARRIER_DRIVER','Driver (template)','COMPANY',true),
  ('CARRIER_ACCOUNTANT','Carrier accountant (template)','COMPANY',true);

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

-- ------------------------------ Default settings ----------------------
INSERT INTO sys.setting (key, value, description) VALUES
  ('security.auth_fail_ip',   '{"threshold":30,"window_min":60}', 'Automatic IP block after repeated login failures (16.18)'),
  ('security.auth_fail_user', '{"threshold":5,"window_min":15,"lock_min":15}', 'Lock the account after repeated failures'),
  ('security.admin_ip_allowlist_enforced', 'false', 'When enabled, the admin portal opens only from ALLOW addresses with ADMIN scope'),
  ('security.api_key_rotation_days', '90', 'API key validity period'),
  ('retention.audit_months', '84', 'Audit log retention (7 years, set by law)'),
  ('retention.geo_event_days', '7', 'Retention of individual tracking positions'),
  ('booking.hold_minutes', '10', 'Temporary seat hold duration'),
  ('booking.sales_cutoff_minutes', '15', 'Sales cutoff before departure from the station'),
  ('booking.post_departure_policy', '"PHYSICAL_FREE"', 'Default post-departure sales policy (Decision 71)'),
  ('einvoice.mode', '"GENERATION"', 'E-invoicing mode until government integration is activated'),
  ('features', '{"loyalty":true,"campaigns":true,"ai_assistant":true,"gov_integration":false,"international":false,"cargo":false}', 'Feature flags (2.8)');

INSERT INTO sys.schema_migration (version, description) VALUES ('1.0.0', 'Phase 1 baseline schema');

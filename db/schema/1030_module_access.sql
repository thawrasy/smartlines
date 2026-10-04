-- =====================================================================
-- 1030: permissions of the modules of files 1010 to 1029, and the module switch
--   Each module has a platform permission (".manage": catalogs, approvals, oversight) and, where companies take
--   part, a company permission (".operate"). Company owners hold every company permission automatically.
--   Modules are switched on and off by the platform in sys.setting "features" (modules.manage).
-- =====================================================================

INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('modules.manage','sys','PLATFORM','Switch platform modules on and off',true),
  ('lines.manage','net','PLATFORM','Approved lines, versions, tariffs and permits',true),
  ('lines.operate','net','COMPANY','Timetables and shuttle operation on permitted lines',false),
  ('shuttle.manage','ops','PLATFORM','Shuttle subscription plans and zones',false),
  ('shipping.manage','ship','PLATFORM','Shipping catalog, zones, rates and partners',false),
  ('shipping.operate','ship','COMPANY','Accept, carry and deliver shipments',false),
  ('freight.manage','frt','PLATFORM','Freight oversight and transit declarations',false),
  ('freight.operate','frt','COMPANY','Freight requests, bids, contracts and legs',false),
  ('border.manage','brd','PLATFORM','Border points, crossing profiles and authority responses',true),
  ('border.operate','brd','COMPANY','Prepare and submit trip manifests',true),
  ('billing.manage','bill','PLATFORM','Plans, carrier agreements, subscriptions and invoices',true),
  ('partners.manage','ptn','PLATFORM','Service partners, contracts and settlement',true),
  ('partners.operate','ptn','COMPANY','Partner station operation: sessions, sales, menus',false),
  ('channels.manage','sales','PLATFORM','Channel agreements, allotments, statements',true),
  ('accounting.operate','acct','BOTH','Invoices, credit notes, cash boxes and vouchers',true),
  ('contact_center.manage','crm','PLATFORM','Contact center queues, agents, calls and quality',false),
  ('gov_adapters.manage','sec','PLATFORM','Government registry adapters and verification jobs',true),
  ('rail.manage','rail','BOTH','Rail fare classes, coaches and compositions',false),
  ('taxi.manage','taxi','PLATFORM','Taxi permits and meter tariffs',true),
  ('taxi.operate','taxi','COMPANY','Taxi office: shifts, dispatch and rides',false),
  ('rental.manage','rent','PLATFORM','Rental companies and renter rules',false),
  ('rental.operate','rent','COMPANY','Rental branches, fleet, rates, bookings and contracts',false),
  ('contracts.manage','ctr','PLATFORM','Contracted transport oversight',false),
  ('contracts.operate','ctr','COMPANY','Contracts, routes, riders and attendance',false),
  ('transit.manage','net','PLATFORM','Transit corridors and approved rest stops',true),
  ('transit.operate','ops','COMPANY','Crossing plans and crossing events of transit trips',false),
  ('stations.operate','net','BOTH','Station gates, displays and trip delays',false)
ON CONFLICT (code) DO NOTHING;

INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, p.code FROM iam.role r JOIN iam.permission p
  ON p.code IN ('modules.manage','lines.manage','shuttle.manage','shipping.manage','freight.manage','border.manage',
                'billing.manage','partners.manage','channels.manage','accounting.operate','contact_center.manage',
                'gov_adapters.manage','rail.manage','taxi.manage','rental.manage','contracts.manage','transit.manage',
                'stations.operate')
 WHERE r.code = 'PLATFORM_ADMIN' AND r.company_id IS NULL
ON CONFLICT DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, x.p FROM iam.role r JOIN (VALUES
  ('PLATFORM_FINANCE','billing.manage'),('PLATFORM_FINANCE','accounting.operate'),('PLATFORM_FINANCE','partners.manage'),
  ('PLATFORM_FINANCE','channels.manage'),
  ('PLATFORM_SECURITY','border.manage'),('PLATFORM_SECURITY','gov_adapters.manage'),('PLATFORM_SECURITY','transit.manage'),
  ('PLATFORM_SUPPORT','contact_center.manage'),
  ('CARRIER_OPERATIONS','lines.operate'),('CARRIER_OPERATIONS','shipping.operate'),('CARRIER_OPERATIONS','freight.operate'),
  ('CARRIER_OPERATIONS','border.operate'),('CARRIER_OPERATIONS','contracts.operate'),('CARRIER_OPERATIONS','transit.operate'),
  ('CARRIER_OPERATIONS','taxi.operate'),('CARRIER_OPERATIONS','rental.operate'),('CARRIER_OPERATIONS','stations.operate'),
  ('CARRIER_COUNTER','shipping.operate'),('CARRIER_COUNTER','rental.operate'),
  ('CARRIER_ACCOUNTANT','accounting.operate')
) AS x(r, p) ON x.r = r.code AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- Phase 7 (tracking and stations) gets its own switch; every module key exists in the features setting
UPDATE sys.setting SET value = '{"tracking_stations":false}'::jsonb || value
 WHERE key = 'features' AND NOT (value ? 'tracking_stations');

INSERT INTO sys.schema_migration (version, description)
SELECT '1.13.0', 'Module permissions and the tracking and stations switch'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.13.0');

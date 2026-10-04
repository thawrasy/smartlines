-- =====================================================================
-- 1029: feature flags for the modules of files 1010 to 1024, and the schema version
--   Every module stays off until its phase starts (2.8). Shipping uses the existing "cargo" flag; passenger
--   transit and contracted transport use the flags of file 1003.
-- =====================================================================

UPDATE sys.setting
   SET value = '{"approved_lines":false,"shuttle_rides":false,"shuttle_subscriptions":false,"carrier_billing":false,
                 "service_partners":false,"loyalty_partners":false,"freight":false,"border_manifest":false,
                 "intermediary_platforms":false,"accounting_ops":false,"contact_center":false,"gov_adapters":false,
                 "rail":false,"taxi":false,"car_rental":false}'::jsonb || value
 WHERE key = 'features' AND NOT (value ? 'car_rental');

INSERT INTO sys.schema_migration (version, description)
SELECT '1.12.0', 'Full data model of study v2.6: lines and shuttle rides, billing, service partners, loyalty partners, shipping, '
              || 'freight, border manifest, accounting operations, channels, contact center, government adapters, rail, taxi, car rental'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.12.0');

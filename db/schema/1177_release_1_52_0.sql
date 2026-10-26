-- =====================================================================
-- 1177: release 1.52.0 (files 1143 to 1177)
--   The trial notes of October 2026 in waves 1 to 8: trip references and passenger types, the cash phase, idle
--   sign-out, parcels on scheduled trips, trip changes, names in parts, two sign-in doors, second-factor channels,
--   saved travellers and guests, users and roles in every portal, integration requests, bank and insurer registries,
--   vehicle models, crew details, KYC for every party, city classes, changeable codes, the roads guide, network
--   routes, the fare matrix, trip number ranges, miles, the security watch, ports of entry, government bodies and the
--   vehicle movement code, edits kept with history, the unified fleet, reference lists, the commission studio and the
--   new Syrian pound. Wave 9 (SSH on the server) is set with the owner at production and changes no schema.
-- =====================================================================

INSERT INTO sys.schema_migration (version, description)
SELECT '1.52.0', 'Trial notes of October 2026, waves 1 to 8, the pricing studio and the new Syrian pound (files 1143 to 1177)'
WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.52.0');

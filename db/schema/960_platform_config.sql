-- =====================================================================
-- 960: platform configuration required by the application
--   shared fare brands (5.9), the sandbox payment provider, and permissions used by the API.
-- =====================================================================

INSERT INTO pricing.fare_brand (code, name, factor, rules, sort) VALUES
  ('SAVER',    'Saver',    0.9000, '{"refundable": false, "refund": [], "changeable": false, "bags_included": 1, "kg_per_piece": 20}', 1),
  ('STANDARD', 'Standard', 1.0000, '{"refundable": true, "refund": [[24, 100], [2, 50]], "changeable": true, "change_fee_pct": 10, "bags_included": 1, "kg_per_piece": 23}', 2),
  ('FLEX',     'Flex',     1.2000, '{"refundable": true, "refund": [[2, 100], [0, 70]], "changeable": true, "change_fee_pct": 0, "bags_included": 2, "kg_per_piece": 23, "priority_boarding": true}', 3);

-- Sandbox provider: simulates signed gateway notifications; the API refuses it unless sandbox mode is enabled
INSERT INTO fin.payment_provider (code, name, kind, config, fee_policy, clearing_wallet_id, status)
SELECT 'SANDBOX', 'Sandbox gateway (testing only)', 'CARD', '{"sandbox": true}', '{"pct": 0, "borne_by": "PLATFORM"}', w.id, 'ACTIVE'
  FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
 WHERE p.legal_name = 'Masslak Platform' AND w.wallet_type = 'GATEWAY_CLEARING' AND w.currency = 'SYP';

-- Drivers complete trips from the app; owners already hold every company permission
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, p.code FROM iam.role r, (VALUES ('trip.complete'), ('manifest.view')) AS p(code)
 WHERE r.code = 'CARRIER_OPERATIONS' AND r.company_id IS NULL
ON CONFLICT DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'regulator.dashboard' FROM iam.role r WHERE r.code IN ('PLATFORM_ADMIN','PLATFORM_SECURITY') AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

INSERT INTO sys.schema_migration (version, description) VALUES ('1.1.0', 'Fare brands, sandbox provider, API permissions');

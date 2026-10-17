-- Boarding stations, step 2 (docs/operations/BOARDING_STATIONS.md, sections 2 and 3). Who may act at a station, and for which
-- carrier: an operating company acts only with a grant. A carrier grants its own (the operating company contracted by the
-- carrier, through the carrier's portal); the platform grants a state-mandated operating company (carrier empty: every
-- carrier's trips at the station). A grant is revoked, never changed or deleted. The grants are the policy; the operating
-- companies' own portal and the counter procedures come with the next steps.

-- 1. the permission a carrier gives to a station's operating company, and the permission to give it -----------------------
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('boarding.operators', 'net', 'COMPANY', 'Give an operating company the rights to book, issue boarding passes and run boarding at the carrier''s stations', true)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'boarding.operators' FROM iam.role r WHERE r.code = 'CARRIER_OPERATIONS'
ON CONFLICT DO NOTHING;

-- 2. the grants -------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS net.station_operator_grant (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                   uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  carrier_company_id    bigint REFERENCES iam.company(id),        -- empty: granted by the platform to a state-mandated operator
  operator_company_id   bigint NOT NULL REFERENCES iam.company(id),
  station_id            bigint REFERENCES net.station(id),        -- empty: every station
  permission            text NOT NULL CHECK (permission IN ('BOOKING', 'BOARDING_PASS', 'BOARDING')),
  granted_by_user_id    bigint REFERENCES iam.app_user(id),
  granted_at            timestamptz NOT NULL DEFAULT now(),
  revoked_by_user_id    bigint REFERENCES iam.app_user(id),
  revoked_at            timestamptz,
  CHECK (carrier_company_id IS NULL OR carrier_company_id <> operator_company_id)
);
-- one active grant per carrier, operator, station and permission
CREATE UNIQUE INDEX IF NOT EXISTS station_operator_grant_active_uq
  ON net.station_operator_grant (coalesce(carrier_company_id, 0), operator_company_id, coalesce(station_id, 0), permission)
  WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS station_operator_grant_carrier_company_id_fkx ON net.station_operator_grant (carrier_company_id);
CREATE INDEX IF NOT EXISTS station_operator_grant_operator_company_id_fkx ON net.station_operator_grant (operator_company_id);
CREATE INDEX IF NOT EXISTS station_operator_grant_station_id_fkx ON net.station_operator_grant (station_id);
CREATE INDEX IF NOT EXISTS station_operator_grant_granted_by_user_id_fkx ON net.station_operator_grant (granted_by_user_id);
CREATE INDEX IF NOT EXISTS station_operator_grant_revoked_by_user_id_fkx ON net.station_operator_grant (revoked_by_user_id);
COMMENT ON TABLE net.station_operator_grant IS 'What a station''s operating company may do, for which carrier and at which station (1097, step 2); revoked, never deleted';

-- read: the platform, the carrier that gave it, and the operating company it was given to. Write: the platform grants the
-- state-mandated rights (no carrier), a carrier grants and revokes its own (only with its carrier written)
SELECT sys.rls_split('net.station_operator_grant',
  'sys.ctx_is_platform() OR sys.tenant_visible(carrier_company_id) OR sys.tenant_visible(operator_company_id)',
  '(carrier_company_id IS NULL AND sys.ctx_is_platform()) OR (carrier_company_id IS NOT NULL AND sys.tenant_visible(carrier_company_id))');
GRANT SELECT, INSERT ON net.station_operator_grant TO masslak_app;
GRANT UPDATE (revoked_at, revoked_by_user_id) ON net.station_operator_grant TO masslak_app;   -- revoking only
GRANT SELECT ON net.station_operator_grant TO masslak_readonly;

-- 3. the decision: may this operating company do this at this station for this carrier's trips now --------------------
-- the station must be boarding (1097: the platform switch and the station's own switch), and the grant must be in force
-- under the mode that gave it: a carrier's grant under the contracted mode, a platform grant under the state-mandated mode
CREATE OR REPLACE FUNCTION net.operator_may(p_operator_company_id bigint, p_carrier_company_id bigint, p_station_id bigint,
                                            p_permission text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT net.boarding_station_on(p_station_id) AND EXISTS (
    SELECT 1 FROM net.station_operator_grant g
     WHERE g.operator_company_id = p_operator_company_id AND g.permission = p_permission AND g.revoked_at IS NULL
       AND (g.station_id IS NULL OR g.station_id = p_station_id)
       AND ((g.carrier_company_id IS NOT NULL AND g.carrier_company_id = p_carrier_company_id
             AND coalesce((SELECT (value #>> '{}')::boolean FROM sys.setting WHERE key = 'boarding.mode.carrier_contracted'), false))
         OR (g.carrier_company_id IS NULL
             AND coalesce((SELECT (value #>> '{}')::boolean FROM sys.setting WHERE key = 'boarding.mode.state_mandated'), false))))
$$;

-- 4. the project phase and the lifecycle of the grants: with the stations (phase 7, as the station switch) ----------------
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('net.station_operator_grant', '7', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('net.station_operator_grant', 'TENANT_PRIVATE', 'carrier company or operating company', 'what an operating company may do for a carrier (1097, step 2)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.station_operator_grant', 'net records', 'the grants given to a station''s operating company (1097)')
ON CONFLICT (table_name) DO NOTHING;

-- 5. privileges of the decision ---------------------------------------------------------------------------------------------
REVOKE ALL ON FUNCTION net.operator_may(bigint, bigint, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.operator_may(bigint, bigint, bigint, text) TO masslak_app;

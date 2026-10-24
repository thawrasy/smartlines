-- Boarding stations (the owner's decisions, October 2026; docs/operations/BOARDING_STATIONS.md). Nothing here changes how
-- the platform behaves today: the platform switch is off at launch, every station is off until it is switched on, the
-- check-in window is empty until the authorities fix it, and the reference fields are optional.
--
-- Counters and bays are numbered by the platform, per station, and a number is never reused: a closed counter keeps its
-- number, so a passenger who asks the carrier about a counter gets the same answer later. The boarding pass shows the bay
-- when one is assigned to the trip's stop (ops.trip_stop.gate_id, 1013), and the station screens show the same codes later.

-- 1. permissions: the platform's boarding settings, and a carrier's own reference numbers ----------------------------------
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('boarding.manage', 'net', 'PLATFORM', 'Boarding stations: platform settings, station switches, counter and bay numbering', true),
  ('boarding.references', 'net', 'COMPANY', 'The carrier''s agreement and licence reference numbers', false)
ON CONFLICT (code) DO NOTHING;

INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'boarding.manage' FROM iam.role r WHERE r.code = 'PLATFORM_ADMIN'
ON CONFLICT DO NOTHING;

-- every copy of the carrier's operations role, the template and the copies made for each carrier
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'boarding.references' FROM iam.role r WHERE r.code = 'CARRIER_OPERATIONS'
ON CONFLICT DO NOTHING;

-- 2. the platform settings: off, or empty, at launch -------------------------------------------------------------------
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('boarding.stations.enabled', 'false'::jsonb, 'PLATFORM',
   'Boarding stations are in use on this platform; off at launch (1097)'),
  ('boarding.mode.state_mandated', 'false'::jsonb, 'PLATFORM',
   'A state-mandated operating company runs the stations; off at launch (1097)'),
  ('boarding.mode.carrier_contracted', 'false'::jsonb, 'PLATFORM',
   'Carriers may contract an operating company for their stations; off at launch (1097)'),
  ('boarding.checkin.opens_minutes', 'null'::jsonb, 'PLATFORM',
   'Minutes before departure when the check-in opens; null until the authorities fix it (1097)'),
  ('boarding.checkin.closes_minutes', 'null'::jsonb, 'PLATFORM',
   'Minutes before departure when the check-in closes; null until the authorities fix it (1097)'),
  ('boarding.references.required', '[]'::jsonb, 'PLATFORM',
   'Reference kinds a carrier must have on file before the platform relies on it: AGREEMENT or a licence type; empty: none (1097)')
ON CONFLICT (key) DO NOTHING;

-- the platform writes the settings through this function: each value is checked for its key, and the check-in opens
-- before it closes when both are set
CREATE OR REPLACE FUNCTION net.set_boarding_setting(p_key text, p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_other jsonb; v_opens integer; v_closes integer;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: boarding stations are a platform task' USING ERRCODE = 'P0001';
  END IF;
  IF p_key IN ('boarding.stations.enabled', 'boarding.mode.state_mandated', 'boarding.mode.carrier_contracted') THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'INVALID_SETTING: % is true or false', p_key USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_key IN ('boarding.checkin.opens_minutes', 'boarding.checkin.closes_minutes') THEN
    IF p_value <> 'null'::jsonb AND NOT (CASE WHEN jsonb_typeof(p_value) = 'number' AND (p_value #>> '{}') ~ '^[0-9]{1,4}$'
                                              THEN (p_value #>> '{}')::integer <= 1440 ELSE false END) THEN
      RAISE EXCEPTION 'INVALID_SETTING: % is a whole number of minutes up to 1440, or null', p_key USING ERRCODE = 'P0001';
    END IF;
    v_other := coalesce((SELECT value FROM sys.setting WHERE key = CASE WHEN p_key = 'boarding.checkin.opens_minutes'
                           THEN 'boarding.checkin.closes_minutes' ELSE 'boarding.checkin.opens_minutes' END), 'null'::jsonb);
    IF p_value <> 'null'::jsonb AND v_other <> 'null'::jsonb THEN
      v_opens  := CASE WHEN p_key = 'boarding.checkin.opens_minutes' THEN (p_value #>> '{}')::integer ELSE (v_other #>> '{}')::integer END;
      v_closes := CASE WHEN p_key = 'boarding.checkin.closes_minutes' THEN (p_value #>> '{}')::integer ELSE (v_other #>> '{}')::integer END;
      IF v_opens <= v_closes THEN
        RAISE EXCEPTION 'INVALID_SETTING: the check-in opens more minutes before departure than it closes' USING ERRCODE = 'P0001';
      END IF;
    END IF;
  ELSIF p_key = 'boarding.references.required' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'array' OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_value) e
         WHERE jsonb_typeof(e) IS DISTINCT FROM 'string' OR length(e #>> '{}') NOT BETWEEN 1 AND 60) THEN
      RAISE EXCEPTION 'INVALID_SETTING: the required references are a list of codes of 1 to 60 characters' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    RAISE EXCEPTION 'INVALID_SETTING: % is not a boarding setting', p_key USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
  VALUES (p_key, p_value, 'PLATFORM', 'Boarding stations setting (1097)', sys.ctx_user_id(), now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  RETURN p_value;
END $$;

-- 3. each station on its own: its switch, the counter system it uses, its screens and its own check-in window ----------
CREATE TABLE IF NOT EXISTS net.station_boarding (
  station_id              bigint PRIMARY KEY REFERENCES net.station(id),
  enabled                 boolean NOT NULL DEFAULT false,
  counter_system          text NOT NULL DEFAULT 'PLATFORM' CHECK (counter_system IN ('PLATFORM', 'EXTERNAL')),  -- EXTERNAL: the station's own system, linked to the platform
  displays                boolean NOT NULL DEFAULT false,      -- the station has screens the platform feeds
  checkin_opens_minutes   integer CHECK (checkin_opens_minutes BETWEEN 0 AND 1440),
  checkin_closes_minutes  integer CHECK (checkin_closes_minutes BETWEEN 0 AND 1440),
  updated_by_user_id      bigint REFERENCES iam.app_user(id),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CHECK (checkin_opens_minutes IS NULL OR checkin_closes_minutes IS NULL OR checkin_opens_minutes > checkin_closes_minutes)
);
CREATE INDEX IF NOT EXISTS station_boarding_updated_by_user_id_fkx ON net.station_boarding (updated_by_user_id);
COMMENT ON TABLE net.station_boarding IS 'Boarding switch, counter system, screens and check-in window of one station (1097); written by the platform';

SELECT sys.rls_catalog('net.station_boarding');
GRANT SELECT, INSERT, UPDATE ON net.station_boarding TO masslak_app;
GRANT SELECT ON net.station_boarding TO masslak_readonly;

-- a station takes boarding only when the platform's switch and the station's own switch are both on
CREATE OR REPLACE FUNCTION net.boarding_station_on(p_station_id bigint) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT (value #>> '{}')::boolean FROM sys.setting WHERE key = 'boarding.stations.enabled'), false)
     AND coalesce((SELECT b.enabled FROM net.station_boarding b WHERE b.station_id = p_station_id), false)
$$;

-- 4. counters and bays: each counter belongs to one operating company; the platform numbers them per station ---------
ALTER TABLE net.station_gate ADD COLUMN IF NOT EXISTS operator_company_id bigint REFERENCES iam.company(id);
ALTER TABLE net.station_gate DROP CONSTRAINT IF EXISTS station_gate_counter_operator_check;
ALTER TABLE net.station_gate ADD CONSTRAINT station_gate_counter_operator_check
  CHECK ((gate_type = 'COUNTER') = (operator_company_id IS NOT NULL));
CREATE INDEX IF NOT EXISTS station_gate_operator_company_id_fkx ON net.station_gate (operator_company_id);  -- -> iam.company
COMMENT ON COLUMN net.station_gate.operator_company_id IS 'The operating company that runs a counter (1097); empty for the other gates';

-- the number is the prefix of the kind and three digits: C001 counter, B001 bay, G001 gate, P001 platform. The station row
-- is locked while a number is taken, so two requests never get the same number, and a closed gate keeps its number.
CREATE OR REPLACE FUNCTION net.open_station_gate(p_station_id bigint, p_gate_type text, p_operator_company_id bigint)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_prefix text; v_next integer; v_code text;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: counters and bays are numbered by the platform' USING ERRCODE = 'P0001';
  END IF;
  IF p_gate_type NOT IN ('PLATFORM', 'BAY', 'GATE', 'COUNTER') THEN
    RAISE EXCEPTION 'INVALID_GATE: the gate is a platform, a bay, a gate or a counter' USING ERRCODE = 'P0001';
  END IF;
  IF (p_gate_type = 'COUNTER') IS DISTINCT FROM (p_operator_company_id IS NOT NULL) THEN
    RAISE EXCEPTION 'INVALID_GATE: a counter belongs to one operating company, and only counters do' USING ERRCODE = 'P0001';
  END IF;
  PERFORM 1 FROM net.station WHERE id = p_station_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_FOUND: the station does not exist' USING ERRCODE = 'P0001';
  END IF;
  v_prefix := CASE p_gate_type WHEN 'COUNTER' THEN 'C' WHEN 'BAY' THEN 'B' WHEN 'GATE' THEN 'G' ELSE 'P' END;
  SELECT coalesce(max(substring(code FROM 2)::integer), 0) + 1 INTO v_next
    FROM net.station_gate WHERE station_id = p_station_id AND code ~ ('^' || v_prefix || '[0-9]{3}$');
  IF v_next > 999 THEN
    RAISE EXCEPTION 'INVALID_GATE: at most 999 gates of one kind at a station' USING ERRCODE = 'P0001';
  END IF;
  v_code := v_prefix || lpad(v_next::text, 3, '0');
  INSERT INTO net.station_gate (station_id, code, gate_type, operator_company_id)
  VALUES (p_station_id, v_code, p_gate_type, p_operator_company_id);
  RETURN v_code;
END $$;

-- 5. the optional reference fields: a carrier's agreements and licences, one row per number -------------------------------
-- The numbering scheme of each licence type is not decided yet, so a number is kept as the carrier gives it (1 to 60
-- characters). A reference is retired, never changed: the carrier adds the corrected number and retires the old one.
CREATE TABLE IF NOT EXISTS net.operation_reference (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id          bigint NOT NULL REFERENCES iam.company(id),
  kind                text NOT NULL CHECK (kind IN ('AGREEMENT', 'LICENCE')),
  licence_type        text CHECK (length(licence_type) BETWEEN 1 AND 60),   -- the licence type's code; empty for an agreement
  reference_no        text NOT NULL CHECK (length(reference_no) BETWEEN 1 AND 60),
  issued_by           text CHECK (length(issued_by) BETWEEN 1 AND 120),
  issued_on           date,
  expires_on          date,
  status              text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  created_by_user_id  bigint REFERENCES iam.app_user(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  retired_at          timestamptz,
  CHECK ((kind = 'LICENCE') = (licence_type IS NOT NULL)),
  CHECK (expires_on IS NULL OR issued_on IS NULL OR expires_on >= issued_on),
  CHECK ((status = 'RETIRED') = (retired_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS operation_reference_active_uq
  ON net.operation_reference (company_id, kind, coalesce(licence_type, ''), reference_no) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS operation_reference_company_id_fkx ON net.operation_reference (company_id);
CREATE INDEX IF NOT EXISTS operation_reference_created_by_user_id_fkx ON net.operation_reference (created_by_user_id);
COMMENT ON TABLE net.operation_reference IS 'Agreement and licence reference numbers of a carrier (1097); optional until the setting boarding.references.required asks for them';

SELECT sys.rls_tenant('net.operation_reference');
GRANT SELECT, INSERT ON net.operation_reference TO masslak_app;
GRANT UPDATE (status, retired_at) ON net.operation_reference TO masslak_app;   -- retiring only; the number stays as it was given
GRANT SELECT ON net.operation_reference TO masslak_readonly;

-- the required references that a carrier has not yet on file (empty when none is required)
CREATE OR REPLACE FUNCTION net.operation_references_missing(p_company_id bigint) RETURNS text[]
LANGUAGE sql STABLE AS $$
  SELECT coalesce(array_agg(r.req ORDER BY r.req), '{}'::text[])
    FROM (SELECT jsonb_array_elements_text(coalesce((SELECT value FROM sys.setting WHERE key = 'boarding.references.required'),
                                                    '[]'::jsonb)) AS req) r
   WHERE NOT EXISTS (SELECT 1 FROM net.operation_reference o
                      WHERE o.company_id = p_company_id AND o.status = 'ACTIVE'
                        AND ((r.req = 'AGREEMENT' AND o.kind = 'AGREEMENT')
                          OR (o.kind = 'LICENCE' AND o.licence_type = r.req)))
$$;

-- 6. the project phase of the new tables: the station's boarding switch with the stations and their screens (phase 7, as
-- net.station_gate, closed while that phase is off); the carrier's reference numbers with the carrier's own records (1A,
-- as net.carrier_code), so they are not closed by the stations switch
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('net.station_boarding', '7', 'E04'), ('net.operation_reference', '1A', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();

-- 7. the lifecycle of the new tables (1079): the stations' switches are a platform catalog, a carrier's numbers are its records
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('net.station_boarding', 'PUBLIC_CATALOG', 'public read, platform writes', 'boarding switch and check-in window of each station (1097)'),
  ('net.operation_reference', 'TENANT_PRIVATE', 'company_id', 'agreement and licence numbers of a carrier (1097)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.station_boarding', 'net catalog', 'the boarding switches of the stations (1097)'),
  ('net.operation_reference', 'net records', 'the agreement and licence numbers a carrier records (1097)')
ON CONFLICT (table_name) DO NOTHING;

-- 8. privileges of the functions -------------------------------------------------------------------------------------------
REVOKE ALL ON FUNCTION net.set_boarding_setting(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.open_station_gate(bigint, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.boarding_station_on(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION net.operation_references_missing(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.set_boarding_setting(text, jsonb) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.open_station_gate(bigint, text, bigint) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.boarding_station_on(bigint) TO masslak_app;
GRANT EXECUTE ON FUNCTION net.operation_references_missing(bigint) TO masslak_app;

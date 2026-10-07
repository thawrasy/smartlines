-- =====================================================================
-- 1042: owner's decisions on the phase map (1041)
--   A  The contact center and the AI assistant move to a later phase of their own. Until then support runs on
--      cases (crm.case): complaints arrive by WhatsApp and email during working hours, and a support agent handles
--      them in the system; cases already accept the WHATSAPP and EMAIL channels.
--   B  The shuttle is a phase of its own, opened city by city in several stages: sys.city_rollout records which
--      city is open for which service, and a shuttle line or zone can be activated only in an opened city.
-- =====================================================================

-- =====================================================================
-- A  A later phase for the contact center and the AI assistant
-- =====================================================================
INSERT INTO sys.project_phase (code, ordinal, name, study_ref, scope) VALUES
  ('CS', 16.0, 'Later phase: contact center and AI assistant', '7.11, 7.6 (owner decision, 1042)',
   'Call queues, agents, skills, callbacks and call quality; the AI assistant with its policies, tool calls and evaluations. '
   || 'Until then support runs on cases: WhatsApp and email during working hours, handled by a support agent')
ON CONFLICT (code) DO UPDATE SET ordinal = EXCLUDED.ordinal, name = EXCLUDED.name, study_ref = EXCLUDED.study_ref, scope = EXCLUDED.scope;

UPDATE sys.table_phase SET phase_code = 'CS'
 WHERE table_name IN ('crm.ai_conversation','crm.ai_message','crm.ai_tool_call','crm.ai_policy','crm.ai_eval_case',
                      'crm.call','crm.call_event','crm.call_queue','crm.call_skill','crm.call_agent','crm.call_agent_skill',
                      'crm.call_queue_skill','crm.callback_request','crm.call_qa');

UPDATE sys.project_phase SET scope = 'Companies, users and permissions, fleet and seats, stations, routes and trips, search, seat holds, '
  || 'bookings and tickets, external or cash payment, the price allocation of every sale, promo codes, notifications, support '
  || 'cases from WhatsApp and email handled by a support agent, audit and governance, manual manifests'
 WHERE code = '1A';

-- =====================================================================
-- B  The shuttle: its own phase, opened city by city
-- =====================================================================
UPDATE sys.project_phase SET name = 'Phase 2: shuttle, city by city',
  scope = 'A phase of its own, not part of the launch, opened city by city in stages (sys.city_rollout): approved lines and '
       || 'tariffs, shuttle rides, subscriptions and passes, QR and NFC validators, standing capacity'
 WHERE code = '2';

CREATE TABLE IF NOT EXISTS sys.city_rollout (
  feature_key  text NOT NULL CHECK (feature_key ~ '^[a-z_]+$'),
  city_id      bigint NOT NULL REFERENCES ref.city (id),
  stage        smallint NOT NULL CHECK (stage >= 1),
  status       text NOT NULL DEFAULT 'PLANNED' CHECK (status IN ('PLANNED','PILOT','OPEN','PAUSED')),
  opens_on     date,
  note         text,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feature_key, city_id)
);
CREATE INDEX IF NOT EXISTS city_rollout_city_id_fkx ON sys.city_rollout (city_id);
COMMENT ON TABLE sys.city_rollout IS 'Which city is opened for which service, and in which stage (shuttle city by city, owner decision 1042)';
COMMENT ON COLUMN sys.city_rollout.status IS 'PLANNED: not open; PILOT: open to the pilot carriers; OPEN: open to all; PAUSED: closed again';
SELECT sys.rls_catalog('sys.city_rollout');
GRANT SELECT ON sys.city_rollout TO masslak_app, masslak_readonly;

CREATE OR REPLACE FUNCTION sys.city_open(p_feature text, p_city bigint) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM sys.city_rollout WHERE feature_key = p_feature AND city_id = p_city AND status IN ('PILOT','OPEN'))
$$;
COMMENT ON FUNCTION sys.city_open IS 'The service is open in the city (pilot or general)';

-- A shuttle line or shuttle zone becomes active only in a city opened for the shuttle
CREATE OR REPLACE FUNCTION sys.tg_shuttle_city_open() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.status = 'ACTIVE' AND (TG_TABLE_NAME = 'shuttle_zone' OR (to_jsonb(NEW) ->> 'kind') = 'SHUTTLE')
     AND (NEW.city_id IS NULL OR NOT sys.city_open('shuttle_rides', NEW.city_id)) THEN
    RAISE EXCEPTION 'CITY_NOT_OPEN: the shuttle is not open in this city yet (sys.city_rollout)' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS shuttle_city_open ON net.line;
CREATE TRIGGER shuttle_city_open BEFORE INSERT OR UPDATE OF status, kind, city_id ON net.line
  FOR EACH ROW EXECUTE FUNCTION sys.tg_shuttle_city_open();
DROP TRIGGER IF EXISTS shuttle_city_open ON sales.shuttle_zone;
CREATE TRIGGER shuttle_city_open BEFORE INSERT OR UPDATE OF status, city_id ON sales.shuttle_zone
  FOR EACH ROW EXECUTE FUNCTION sys.tg_shuttle_city_open();

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sys.city_rollout', '2', 'E10')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.24.0', 'Owner decisions: contact center and AI assistant in a later phase; the shuttle opened city by city'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.24.0');

SELECT sys.refresh_table_class();

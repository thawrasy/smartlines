-- =====================================================================
-- 1163: routes of the network, defined by the platform along the roads (owner's requests N11, N37, N38)
--   * A route of the network (net.network_route) runs from one station to another. Its code is set by the system
--     (origin city - destination city - number). It is defined only by the platform, in versions: each version lists
--     the stations in order (origin, stops, rest stops, border crossings, destination; mandatory or not) and, when the
--     roads guide is loaded, the road segments it follows (road, from point, to point). The distance and the
--     governorates crossed come from the segments; the distance of each station from the start too when it stands at
--     a road point, else the platform gives it.
--   * A version is proposed by one person and approved by another; it takes effect on its date, retiring the version
--     before. Trips already made keep the version their route was set on.
--   * A carrier no longer draws its own routes: it picks a route of the network, the stations it boards and alights at
--     on it and the stops it serves (the mandatory ones always), then its times and fares. The carrier's route records
--     the network route and version. The setting network.platform_routes_only (on) can be switched off to let carriers
--     draw free routes as before.
--   * A carrier asks the platform for a route the network lacks (net.route_request).
-- =====================================================================

CREATE TABLE IF NOT EXISTS net.network_route (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  code          text NOT NULL UNIQUE CHECK (code ~ '^[A-Z]{3}-[A-Z]{3}-[0-9]{2,3}$'),
  name_en       text NOT NULL CHECK (length(btrim(name_en)) BETWEEN 3 AND 200),
  name_ar       text NOT NULL CHECK (length(btrim(name_ar)) BETWEEN 3 AND 200),
  origin_station_id bigint NOT NULL REFERENCES net.station(id),
  dest_station_id   bigint NOT NULL REFERENCES net.station(id),
  status        text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'ACTIVE', 'RETIRED')),
  created_by    bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (origin_station_id <> dest_station_id)
);
CREATE INDEX IF NOT EXISTS network_route_origin_station_id_fkx ON net.network_route (origin_station_id);
CREATE INDEX IF NOT EXISTS network_route_dest_station_id_fkx ON net.network_route (dest_station_id);
CREATE INDEX IF NOT EXISTS network_route_created_by_fkx ON net.network_route (created_by);
COMMENT ON TABLE net.network_route IS 'A route of the network from one station to another, defined by the platform in versions; carriers run their services on it (1163, N11)';

CREATE TABLE IF NOT EXISTS net.network_route_version (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  route_id      bigint NOT NULL REFERENCES net.network_route(id),
  version       int NOT NULL CHECK (version >= 1),
  status        text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'ACTIVE', 'RETIRED', 'REJECTED', 'WITHDRAWN')),
  effective_from date NOT NULL,
  distance_km   numeric(8,1) NOT NULL CHECK (distance_km > 0),
  note          text CHECK (length(note) <= 1000),
  proposed_by   bigint NOT NULL REFERENCES iam.app_user(id),
  proposed_at   timestamptz NOT NULL DEFAULT now(),
  decided_by    bigint REFERENCES iam.app_user(id),
  decided_at    timestamptz,
  decision_note text CHECK (length(decision_note) <= 500),
  activated_at  timestamptz,
  UNIQUE (route_id, version),
  CHECK (decided_by IS NULL OR decided_by IS DISTINCT FROM proposed_by),
  CHECK (status NOT IN ('APPROVED', 'ACTIVE', 'REJECTED') OR decided_by IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS network_route_version_one_active ON net.network_route_version (route_id) WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS network_route_version_one_open ON net.network_route_version (route_id) WHERE status IN ('PENDING', 'APPROVED');
CREATE INDEX IF NOT EXISTS network_route_version_proposed_by_fkx ON net.network_route_version (proposed_by);
CREATE INDEX IF NOT EXISTS network_route_version_decided_by_fkx ON net.network_route_version (decided_by);
COMMENT ON TABLE net.network_route_version IS 'A version of a network route: its stations and road segments, proposed by one person, approved by another, in effect from its date (1163)';

CREATE TABLE IF NOT EXISTS net.network_route_segment (
  version_id    bigint NOT NULL REFERENCES net.network_route_version(id),
  seq           smallint NOT NULL CHECK (seq >= 1),
  road_id       bigint NOT NULL REFERENCES net.road(id),
  from_point_id bigint NOT NULL REFERENCES net.road_point(id),
  to_point_id   bigint NOT NULL REFERENCES net.road_point(id),
  km            numeric(8,1) NOT NULL CHECK (km > 0),
  PRIMARY KEY (version_id, seq),
  CHECK (from_point_id <> to_point_id)
);
CREATE INDEX IF NOT EXISTS network_route_segment_road_id_fkx ON net.network_route_segment (road_id);
CREATE INDEX IF NOT EXISTS network_route_segment_from_point_id_fkx ON net.network_route_segment (from_point_id);
CREATE INDEX IF NOT EXISTS network_route_segment_to_point_id_fkx ON net.network_route_segment (to_point_id);
COMMENT ON TABLE net.network_route_segment IS 'The roads a route version follows, in order: a road from one of its points to another (1163, N38)';

CREATE TABLE IF NOT EXISTS net.network_route_stop (
  version_id    bigint NOT NULL REFERENCES net.network_route_version(id),
  seq           smallint NOT NULL CHECK (seq >= 1),
  station_id    bigint NOT NULL REFERENCES net.station(id),
  km_from_start numeric(8,1) NOT NULL CHECK (km_from_start >= 0),
  mandatory     boolean NOT NULL DEFAULT false,
  PRIMARY KEY (version_id, seq),
  UNIQUE (version_id, station_id),
  CHECK (seq > 1 OR km_from_start = 0)
);
CREATE INDEX IF NOT EXISTS network_route_stop_station_id_fkx ON net.network_route_stop (station_id);
COMMENT ON TABLE net.network_route_stop IS 'The stations of a route version in order with their distance from the start; a mandatory one is served by every carrier on the route (1163, N11)';

CREATE TABLE IF NOT EXISTS net.route_request (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id      bigint NOT NULL REFERENCES iam.company(id),
  from_station_id bigint NOT NULL REFERENCES net.station(id),
  to_station_id   bigint NOT NULL REFERENCES net.station(id),
  via             text CHECK (length(via) <= 500),
  note            text NOT NULL CHECK (length(btrim(note)) BETWEEN 5 AND 1000),
  status          text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'DONE', 'DECLINED')),
  requested_by    bigint NOT NULL REFERENCES iam.app_user(id),
  requested_at    timestamptz NOT NULL DEFAULT now(),
  network_route_id bigint REFERENCES net.network_route(id),
  answered_by     bigint REFERENCES iam.app_user(id),
  answered_at     timestamptz,
  answer          text CHECK (length(answer) <= 1000),
  CHECK (from_station_id <> to_station_id),
  CHECK ((status = 'OPEN') = (answered_by IS NULL))
);
CREATE INDEX IF NOT EXISTS route_request_company_id_fkx ON net.route_request (company_id);
CREATE INDEX IF NOT EXISTS route_request_from_station_id_fkx ON net.route_request (from_station_id);
CREATE INDEX IF NOT EXISTS route_request_to_station_id_fkx ON net.route_request (to_station_id);
CREATE INDEX IF NOT EXISTS route_request_requested_by_fkx ON net.route_request (requested_by);
CREATE INDEX IF NOT EXISTS route_request_network_route_id_fkx ON net.route_request (network_route_id);
CREATE INDEX IF NOT EXISTS route_request_answered_by_fkx ON net.route_request (answered_by);
COMMENT ON TABLE net.route_request IS 'A carrier''s request for a route the network lacks; the platform answers it (1163, N11)';

-- the carrier's route records the network route and version it runs on
ALTER TABLE net.route ADD COLUMN IF NOT EXISTS network_route_id bigint REFERENCES net.network_route(id);
ALTER TABLE net.route ADD COLUMN IF NOT EXISTS network_version_id bigint REFERENCES net.network_route_version(id);
CREATE INDEX IF NOT EXISTS route_network_route_id_fkx ON net.route (network_route_id);
CREATE INDEX IF NOT EXISTS route_network_version_id_fkx ON net.route (network_version_id);
COMMENT ON COLUMN net.route.network_route_id IS 'The network route the carrier''s service runs on, when defined from one (1163, N11)';
COMMENT ON COLUMN net.route.network_version_id IS 'The version of the network route in effect when the carrier''s route was set; its trips keep it (1163)';

INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('network.platform_routes_only', 'true'::jsonb, 'PLATFORM',
   'Carriers define their services only on routes of the network set by the platform (1163, N11); off lets them draw free routes as before')
ON CONFLICT (key) DO NOTHING;

SELECT sys.rls('net.network_route', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('net.network_route_version', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('net.network_route_segment', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('net.network_route_stop', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('net.route_request', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id)', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id)');
GRANT SELECT, INSERT ON net.network_route, net.network_route_version, net.network_route_segment, net.network_route_stop TO masslak_app;
GRANT UPDATE ON net.network_route TO masslak_app;
GRANT SELECT, INSERT, UPDATE ON net.route_request TO masslak_app;
GRANT SELECT ON net.network_route, net.network_route_version, net.network_route_segment, net.network_route_stop TO masslak_readonly;
DROP TRIGGER IF EXISTS zz_audit_capture ON net.network_route_version;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON net.network_route_version FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS zz_audit_capture ON net.network_route;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON net.network_route FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- a version is written whole and then only decided: its stations and segments never change
CREATE OR REPLACE FUNCTION net.tg_route_version_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM net.network_route_version v WHERE v.id = NEW.version_id AND v.status <> 'PENDING') THEN
    RAISE EXCEPTION 'ROUTE_VERSION_FROZEN: a decided version is not changed; propose a new one' USING ERRCODE = 'P0001';
  END IF;
  -- now() is the time the transaction began: stations and segments go in with the version, in the same transaction
  IF EXISTS (SELECT 1 FROM net.network_route_version v WHERE v.id = NEW.version_id AND v.proposed_at <> now()) THEN
    RAISE EXCEPTION 'ROUTE_VERSION_FROZEN: a version is written whole when it is proposed' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS network_route_segment_frozen ON net.network_route_segment;
CREATE TRIGGER network_route_segment_frozen BEFORE INSERT OR UPDATE ON net.network_route_segment FOR EACH ROW EXECUTE FUNCTION net.tg_route_version_frozen();
DROP TRIGGER IF EXISTS network_route_stop_frozen ON net.network_route_stop;
CREATE TRIGGER network_route_stop_frozen BEFORE INSERT OR UPDATE ON net.network_route_stop FOR EACH ROW EXECUTE FUNCTION net.tg_route_version_frozen();

-- ------------------------------------------------------------------ deciding and taking effect
CREATE OR REPLACE FUNCTION net.activate_route_version(p_version bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v net.network_route_version;
BEGIN
  SELECT * INTO v FROM net.network_route_version WHERE id = p_version FOR UPDATE;
  IF NOT FOUND OR v.status <> 'APPROVED' THEN
    RAISE EXCEPTION 'ROUTE_VERSION_NOT_APPROVED: the version is not approved and waiting' USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.network_route_version SET status = 'RETIRED' WHERE route_id = v.route_id AND status = 'ACTIVE';
  UPDATE net.network_route_version SET status = 'ACTIVE', activated_at = now() WHERE id = v.id;
  UPDATE net.network_route SET status = 'ACTIVE' WHERE id = v.route_id AND status <> 'ACTIVE';
END $$;
REVOKE ALL ON FUNCTION net.activate_route_version(bigint) FROM PUBLIC;
COMMENT ON FUNCTION net.activate_route_version IS 'Puts an approved version of a network route in effect, retiring the one before (1163)';

CREATE OR REPLACE FUNCTION net.decide_route_version(p_uid uuid, p_approve boolean, p_note text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v net.network_route_version;
BEGIN
  IF NOT sys.ctx_is_platform() OR sys.ctx_user_id() IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform decides the routes of the network' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v FROM net.network_route_version WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND OR v.status <> 'PENDING' THEN
    RAISE EXCEPTION 'ROUTE_VERSION_NOT_PENDING: the version is not waiting for a decision' USING ERRCODE = 'P0001';
  END IF;
  IF v.proposed_by = sys.ctx_user_id() THEN
    RAISE EXCEPTION 'FOUR_EYES: another person decides the version you proposed' USING ERRCODE = 'P0001';
  END IF;
  IF NOT p_approve AND length(btrim(coalesce(p_note, ''))) < 5 THEN
    RAISE EXCEPTION 'ROUTE_NOTE: say why the version is rejected' USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.network_route_version SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END, decided_by = sys.ctx_user_id(),
         decided_at = now(), decision_note = nullif(btrim(coalesce(p_note, '')), '')
   WHERE id = v.id;
  IF p_approve AND v.effective_from <= current_date THEN
    PERFORM net.activate_route_version(v.id);
    RETURN 'ACTIVE';
  END IF;
  RETURN CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END;
END $$;
REVOKE ALL ON FUNCTION net.decide_route_version(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.decide_route_version(uuid, boolean, text) TO masslak_app;
COMMENT ON FUNCTION net.decide_route_version IS 'Another person of the platform approves a route version (in effect at once when its date has come) or rejects it with a reason (1163)';

CREATE OR REPLACE FUNCTION net.withdraw_route_version(p_uid uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v net.network_route_version;
BEGIN
  SELECT * INTO v FROM net.network_route_version WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND OR NOT sys.ctx_is_platform() OR v.proposed_by IS DISTINCT FROM sys.ctx_user_id() THEN
    RAISE EXCEPTION 'FORBIDDEN: who proposed a version withdraws it' USING ERRCODE = 'P0001';
  END IF;
  IF v.status NOT IN ('PENDING', 'APPROVED') THEN
    RAISE EXCEPTION 'ROUTE_VERSION_CLOSED: the version is already %', lower(v.status) USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.network_route_version SET status = 'WITHDRAWN' WHERE id = v.id;
  RETURN 'WITHDRAWN';
END $$;
REVOKE ALL ON FUNCTION net.withdraw_route_version(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.withdraw_route_version(uuid) TO masslak_app;

CREATE OR REPLACE FUNCTION net.activate_due_route_versions() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT id FROM net.network_route_version WHERE status = 'APPROVED' AND effective_from <= current_date ORDER BY effective_from, id LOOP
    PERFORM net.activate_route_version(r.id);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION net.activate_due_route_versions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.activate_due_route_versions() TO masslak_app;
COMMENT ON FUNCTION net.activate_due_route_versions IS 'Puts into effect the approved route versions whose date has come (1163)';

-- the next code of a route between two cities
CREATE OR REPLACE FUNCTION net.next_network_route_code(p_origin bigint, p_dest bigint) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT a.code || '-' || b.code || '-' ||
         lpad((coalesce((SELECT max(substring(r.code from '[0-9]+$')::int) FROM net.network_route r
                          WHERE r.code LIKE a.code || '-' || b.code || '-%'), 0) + 1)::text, 2, '0')
    FROM net.station sa JOIN ref.city a ON a.id = sa.city_id, net.station sb JOIN ref.city b ON b.id = sb.city_id
   WHERE sa.id = p_origin AND sb.id = p_dest
$$;
GRANT EXECUTE ON FUNCTION net.next_network_route_code(bigint, bigint) TO masslak_app;

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('net.network_route', '1A', 'E04'), ('net.network_route_version', '1A', 'E04'), ('net.network_route_segment', '1A', 'E04'),
  ('net.network_route_stop', '1A', 'E04'), ('net.route_request', '1A', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.network_route', 'net records', 'routes of the network defined by the platform (1163)'),
  ('net.network_route_version', 'net records', 'versions of the network routes, four eyes (1163)'),
  ('net.network_route_segment', 'net records', 'road segments a route version follows (1163)'),
  ('net.network_route_stop', 'net records', 'stations of a route version (1163)'),
  ('net.route_request', 'net records', 'carriers'' requests for a route the network lacks (1163)')
ON CONFLICT (table_name) DO NOTHING;

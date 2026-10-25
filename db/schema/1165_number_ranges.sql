-- =====================================================================
-- 1165: trip numbers from the carrier's range, a number on every request (owner's request N7, decisions of 23 Oct 2026)
--   * Numbers may repeat across carriers (the designator tells them apart), so every carrier has by default the whole
--     block of each trip type (scheduled 1000-4999 and so on, 1119). The platform may narrow a carrier's range in a
--     block (from - to, inside the block) and widen it again; a carrier whose range fills asks the platform through
--     its portal (net.number_range_request).
--   * A carrier picks the number of a regular trip from the free numbers of its range that fit the block and the
--     direction (odd outbound, even return); the system fills in the default: the first leg of a line whose eight
--     numbers are free, else the lowest free number. The platform keeps the right to give another number at approval.
-- =====================================================================

CREATE TABLE IF NOT EXISTS net.number_range (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint NOT NULL REFERENCES iam.company(id),
  block       text NOT NULL CHECK (block IN ('SCHEDULED', 'INTL', 'SHUTTLE', 'CARGO', 'EXTRA')),
  from_no     integer NOT NULL,
  to_no       integer NOT NULL,
  note        text CHECK (length(note) <= 500),
  set_by      bigint NOT NULL REFERENCES iam.app_user(id),
  set_at      timestamptz NOT NULL DEFAULT now(),
  ended_at    timestamptz,
  CHECK (from_no <= to_no),
  CHECK (ops.block_range(block) @> from_no AND ops.block_range(block) @> to_no)
);
CREATE UNIQUE INDEX IF NOT EXISTS number_range_current ON net.number_range (company_id, block) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS number_range_set_by_fkx ON net.number_range (set_by);
COMMENT ON TABLE net.number_range IS 'A carrier''s range of trip numbers in a block, set by the platform; none means the whole block; a new range ends the one before, which stays as history (1165, N7)';
SELECT sys.rls('net.number_range', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id)', 'sys.ctx_is_platform()');
GRANT SELECT, INSERT, UPDATE ON net.number_range TO masslak_app;
GRANT SELECT ON net.number_range TO masslak_readonly;
DROP TRIGGER IF EXISTS zz_audit_capture ON net.number_range;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON net.number_range FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

CREATE TABLE IF NOT EXISTS net.number_range_request (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid          uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id   bigint NOT NULL REFERENCES iam.company(id),
  block        text NOT NULL CHECK (block IN ('SCHEDULED', 'INTL', 'SHUTTLE', 'CARGO', 'EXTRA')),
  note         text NOT NULL CHECK (length(btrim(note)) BETWEEN 3 AND 500),
  status       text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'DONE', 'DECLINED')),
  requested_by bigint NOT NULL REFERENCES iam.app_user(id),
  requested_at timestamptz NOT NULL DEFAULT now(),
  answer       text CHECK (length(answer) <= 500),
  answered_by  bigint REFERENCES iam.app_user(id),
  answered_at  timestamptz,
  CHECK ((status = 'OPEN') = (answered_at IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS number_range_request_open ON net.number_range_request (company_id, block) WHERE status = 'OPEN';
CREATE INDEX IF NOT EXISTS number_range_request_requested_by_fkx ON net.number_range_request (requested_by);
CREATE INDEX IF NOT EXISTS number_range_request_answered_by_fkx ON net.number_range_request (answered_by);
COMMENT ON TABLE net.number_range_request IS 'A carrier asks the platform to widen its range of trip numbers in a block; one open request per block (1165, N7)';
SELECT sys.rls('net.number_range_request', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id)',
               'sys.ctx_is_platform() OR sys.tenant_visible(company_id)');
GRANT SELECT, INSERT, UPDATE ON net.number_range_request TO masslak_app;
GRANT SELECT ON net.number_range_request TO masslak_readonly;

-- ------------------------------------------------------------------ the carrier's range and its free numbers
-- the carrier's numbers in a block: the range the platform set, else the whole block
CREATE OR REPLACE FUNCTION ops.carrier_number_range(p_company bigint, p_block text) RETURNS int4range
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT int4range(r.from_no, r.to_no, '[]') FROM net.number_range r
                    WHERE r.company_id = p_company AND r.block = p_block AND r.ended_at IS NULL), ops.block_range(p_block))
$$;
REVOKE ALL ON FUNCTION ops.carrier_number_range(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.carrier_number_range(bigint, text) TO masslak_app;

-- what is wrong with a number a carrier picks: outside the block, the wrong parity, or outside its range
CREATE OR REPLACE FUNCTION ops.carrier_number_problem(p_company bigint, p_trip_type text, p_direction text, p_number integer)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(ops.number_problem(ops.number_block(p_trip_type), p_direction, p_number),
                  CASE WHEN p_number IS NOT NULL AND NOT ops.carrier_number_range(p_company, ops.number_block(p_trip_type)) @> p_number
                       THEN format('NUMBER_OUT_OF_RANGE: your %s numbers are %s to %s', lower(ops.number_block(p_trip_type)),
                                   lower(ops.carrier_number_range(p_company, ops.number_block(p_trip_type))),
                                   upper(ops.carrier_number_range(p_company, ops.number_block(p_trip_type))) - 1) END)
$$;
REVOKE ALL ON FUNCTION ops.carrier_number_problem(bigint, text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.carrier_number_problem(bigint, text, text, integer) TO masslak_app;

-- the free numbers of the carrier's range for a regular trip of a type and direction over a period, lowest first
CREATE OR REPLACE FUNCTION ops.free_schedule_numbers(p_company bigint, p_trip_type text, p_direction text, p_period daterange,
                                                     p_route bigint, p_limit integer DEFAULT 200) RETURNS SETOF integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT n FROM generate_series(lower(ops.carrier_number_range(p_company, ops.number_block(p_trip_type))),
                                upper(ops.carrier_number_range(p_company, ops.number_block(p_trip_type))) - 1) n
   WHERE ops.number_problem(ops.number_block(p_trip_type), p_direction, n) IS NULL
     AND ops.schedule_number_free(p_company, n, p_period, p_route)
   ORDER BY n LIMIT greatest(1, least(p_limit, 1000))
$$;
REVOKE ALL ON FUNCTION ops.free_schedule_numbers(bigint, text, text, daterange, bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.free_schedule_numbers(bigint, text, text, daterange, bigint, integer) TO masslak_app;

-- the default number (1119, now inside the carrier's range): the first leg of a line whose eight numbers are free
-- (leg 1 outbound, leg 2 for a return on its own), else the lowest free number that fits; an extra trip takes the
-- lowest free extra number
CREATE OR REPLACE FUNCTION ops.suggest_schedule_number(p_company bigint, p_trip_type text, p_direction text, p_period daterange,
                                                       p_route bigint) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(
    CASE WHEN ops.number_block(p_trip_type) <> 'EXTRA' THEN
      (SELECT x * 10 + CASE WHEN p_direction = 'OUTBOUND' THEN 1 ELSE 2 END
         FROM generate_series(lower(ops.carrier_number_range(p_company, ops.number_block(p_trip_type))) / 10,
                              (upper(ops.carrier_number_range(p_company, ops.number_block(p_trip_type))) - 1) / 10) x
        WHERE ops.carrier_number_range(p_company, ops.number_block(p_trip_type)) @> int4range(x * 10 + 1, x * 10 + 8, '[]')
          AND NOT EXISTS (SELECT 1 FROM generate_series(1, 8) l WHERE NOT ops.schedule_number_free(p_company, x * 10 + l, p_period, NULL))
        ORDER BY x LIMIT 1)
    END,
    (SELECT n FROM ops.free_schedule_numbers(p_company, p_trip_type, p_direction, p_period, p_route, 1) n))
$$;

-- a trip made by hand without a number: as before (1119), inside the carrier's extra range
CREATE OR REPLACE FUNCTION ops.pick_service_no(p_company bigint, p_route bigint, p_departure timestamptz, p_day date,
                                               p_suffix text, p_trip bigint) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tz text; v_no integer; v_range int4range := ops.carrier_number_range(p_company, 'EXTRA');
BEGIN
  v_tz := coalesce(ref.station_tz((SELECT r.origin_station_id FROM net.route r WHERE r.id = p_route)), 'UTC');
  SELECT t.service_no INTO v_no FROM ops.trip t
   WHERE t.company_id = p_company AND t.route_id = p_route AND v_range @> t.service_no AND t.status <> 'CANCELLED'
     AND t.service_date BETWEEN p_day - 60 AND p_day + 60 AND t.service_date <> p_day
     AND (t.departure_at AT TIME ZONE v_tz)::time = (p_departure AT TIME ZONE v_tz)::time
     AND ops.trip_number_free(p_company, p_day, t.service_no, p_suffix, p_trip)
     AND NOT EXISTS (SELECT 1 FROM net.service_number s WHERE s.company_id = p_company AND s.number = t.service_no AND s.valid @> p_day)
   ORDER BY abs(t.service_date - p_day), t.service_date DESC LIMIT 1;
  IF v_no IS NOT NULL THEN
    RETURN v_no;
  END IF;
  SELECT n INTO v_no FROM generate_series(lower(v_range), upper(v_range) - 1) n
   WHERE ops.trip_number_free(p_company, p_day, n, p_suffix, p_trip)
     AND NOT EXISTS (SELECT 1 FROM net.service_number s WHERE s.company_id = p_company AND s.number = n AND s.valid @> p_day)
   ORDER BY n LIMIT 1;
  RETURN v_no;
END $$;

-- the default number of a trip made by hand on a day, for the carrier's form
CREATE OR REPLACE FUNCTION ops.default_trip_number(p_company bigint, p_route bigint, p_day date) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT ops.pick_service_no(p_company, p_route,
                             (p_day + time '12:00') AT TIME ZONE coalesce(ref.station_tz((SELECT r.origin_station_id FROM net.route r WHERE r.id = p_route)), 'UTC'),
                             p_day, NULL, NULL)
$$;
REVOKE ALL ON FUNCTION ops.default_trip_number(bigint, bigint, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.default_trip_number(bigint, bigint, date) TO masslak_app;

-- ------------------------------------------------------------------ the platform sets a range
-- the range of a carrier in a block, inside the block; numbers already in use outside it stay theirs. NULLs give the
-- carrier the whole block back
CREATE OR REPLACE FUNCTION net.set_number_range(p_company bigint, p_block text, p_from integer, p_to integer, p_note text)
RETURNS int4range
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform sets the ranges of trip numbers' USING ERRCODE = 'P0001';
  END IF;
  IF ops.block_range(p_block) IS NULL THEN
    RAISE EXCEPTION 'NUMBER_BLOCK_UNKNOWN: no block %', p_block USING ERRCODE = 'P0001';
  END IF;
  IF (p_from IS NULL) <> (p_to IS NULL) OR (p_from IS NOT NULL AND (p_from > p_to OR NOT ops.block_range(p_block) @> p_from
                                                                    OR NOT ops.block_range(p_block) @> p_to)) THEN
    RAISE EXCEPTION 'NUMBER_RANGE_INVALID: a range runs from a number to a higher one, both in the % numbers % to %', lower(p_block),
      lower(ops.block_range(p_block)), upper(ops.block_range(p_block)) - 1 USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.number_range SET ended_at = now() WHERE company_id = p_company AND block = p_block AND ended_at IS NULL;
  IF p_from IS NOT NULL THEN
    INSERT INTO net.number_range (company_id, block, from_no, to_no, note, set_by)
    VALUES (p_company, p_block, p_from, p_to, nullif(btrim(p_note), ''), sys.ctx_user_id());
  END IF;
  -- an open request of the carrier for this block is answered by the change
  UPDATE net.number_range_request SET status = 'DONE', answer = coalesce(nullif(btrim(p_note), ''), 'Range changed'),
                                      answered_by = sys.ctx_user_id(), answered_at = now()
   WHERE company_id = p_company AND block = p_block AND status = 'OPEN';
  RETURN ops.carrier_number_range(p_company, p_block);
END $$;
REVOKE ALL ON FUNCTION net.set_number_range(bigint, text, integer, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.set_number_range(bigint, text, integer, integer, text) TO masslak_app;

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('net.number_range', '1A', 'E04'), ('net.number_range_request', '1A', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.number_range', 'net records', 'carriers'' ranges of trip numbers per block (1165)'),
  ('net.number_range_request', 'net records', 'carriers'' requests to widen a range of trip numbers (1165)')
ON CONFLICT (table_name) DO NOTHING;

-- =====================================================================
-- Masslak - 1117: regular trips the carrier defines, approved before they run (owner's decision, October 2026)
--   * A carrier defines a regular trip: a route, a departure time and how it repeats - every day, on chosen days of the
--     week (a single day is weekly), or on chosen days of the month - from a date, to a date or with no end until it is
--     stopped, without the dates it does not run (skip_dates). It keeps one number, the same at the same time on every
--     day it runs, as airlines do (ops.trip_template with recurrence, days_of_month, skip_dates; the number is its
--     net.service_number, shown as the trip code of 1114).
--   * In the first phase the platform approves each new regular trip and each change before it runs, and organizes the
--     numbers: it may give another number than the one asked for. The law may later ask government authorities to
--     approve as well (the Ministry of Transport, the Interior, the traffic police), so the approval stages are a
--     setting, not code: schedule.approval_stages, in order, each the platform or an authority by its code
--     (sec.authority_profile) whose members decide (sec.authority_member). Which requests pass the stages is a setting
--     too (schedule.approval_kinds: NEW, CHANGE, STOP, and TRIP for every trip made by hand); so are the fewest days
--     between a request and the day it takes effect (schedule.min_notice_days), how far ahead an approved regular
--     trip's trips exist (schedule.horizon_days) and the ways a trip may repeat (schedule.recurrences). A request keeps
--     the stages in force when it was made.
--   * A request (ops.schedule_request) holds what is asked, each decision is kept (ops.schedule_approval), and one
--     person decides one stage of a request only. An approved NEW request becomes an active regular trip under its
--     number; a CHANGE ends the current version the day before it takes effect and starts the next under the same
--     number; a STOP ends it. Trips already made from that day are cancelled when nobody holds a booking; trips with
--     bookings stay and are named in the result, for the carrier to move or cancel with refunds (1102). While TRIP is
--     among the kinds, a trip made by hand is published only once approved (ops.tg_trip_publish_approval).
--   * The trips of an approved regular trip are made ahead by the worker, day after day up to the horizon, so one with
--     no end keeps running until it is stopped (ops.trip_template.rolling, generated_until, last_run).
--   * Carriers no longer write templates and service numbers themselves: both come from approved requests, through the
--     functions below. A carrier may still pause an active regular trip and resume it.
-- =====================================================================

-- ------------------------------------------------------------------ the settings
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('schedule.approval_stages', '[{"by":"PLATFORM"}]'::jsonb, 'PLATFORM',
   'Who approves a carrier''s regular trips and their changes, in order: {"by":"PLATFORM"}, or a government authority by its code, {"by":"AUTHORITY","authority":"MOT"} (1117)'),
  ('schedule.approval_kinds', '["NEW","CHANGE"]'::jsonb, 'PLATFORM',
   'Which requests pass the approval stages: NEW, CHANGE, STOP, and TRIP for every trip made by hand (1117)'),
  ('schedule.min_notice_days', '0'::jsonb, 'PLATFORM',
   'The fewest days between a request and the day it takes effect, 0 to 90 (1117)'),
  ('schedule.horizon_days', '30'::jsonb, 'PLATFORM',
   'How many days ahead the trips of an approved regular trip are made, 7 to 120 (1117)'),
  ('schedule.recurrences', '["DAILY","WEEKLY","MONTHLY"]'::jsonb, 'PLATFORM',
   'How a regular trip may repeat: every day, on days of the week, on days of the month (1117)')
ON CONFLICT (key) DO NOTHING;

-- what is wrong with a value of a setting of regular trips, or NULL when it is valid
CREATE OR REPLACE FUNCTION ops.schedule_setting_problem(p_key text, p_value jsonb) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE e jsonb; v_allowed text[];
BEGIN
  IF p_key = 'schedule.approval_stages' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'array' OR jsonb_array_length(p_value) NOT BETWEEN 1 AND 6 THEN
      RETURN 'the approval stages are a list of one to six stages';
    END IF;
    FOR e IN SELECT x FROM jsonb_array_elements(p_value) x LOOP
      IF jsonb_typeof(e) IS DISTINCT FROM 'object' OR coalesce(e ->> 'by', '') NOT IN ('PLATFORM', 'AUTHORITY')
         OR EXISTS (SELECT 1 FROM jsonb_object_keys(e) k WHERE k NOT IN ('by', 'authority')) THEN
        RETURN 'each stage is {"by":"PLATFORM"} or {"by":"AUTHORITY","authority":"<code>"}';
      END IF;
      IF e ->> 'by' = 'PLATFORM' AND e ? 'authority' THEN
        RETURN 'a stage of the platform names no authority';
      END IF;
      IF e ->> 'by' = 'AUTHORITY' AND NOT EXISTS (SELECT 1 FROM sec.authority_profile a WHERE a.code = e ->> 'authority') THEN
        RETURN format('no authority has the code %s', coalesce(e ->> 'authority', 'null'));
      END IF;
    END LOOP;
  ELSIF p_key IN ('schedule.approval_kinds', 'schedule.recurrences') THEN
    v_allowed := CASE p_key WHEN 'schedule.approval_kinds' THEN ARRAY['NEW', 'CHANGE', 'STOP', 'TRIP']
                            ELSE ARRAY['DAILY', 'WEEKLY', 'MONTHLY'] END;
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'array'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_value) x WHERE jsonb_typeof(x) IS DISTINCT FROM 'string' OR NOT (x #>> '{}' = ANY (v_allowed)))
       OR (SELECT count(DISTINCT x #>> '{}') FROM jsonb_array_elements(p_value) x) <> jsonb_array_length(p_value)
       OR (p_key = 'schedule.recurrences' AND jsonb_array_length(p_value) = 0) THEN
      RETURN format('%s is a list of %s, each once%s', p_key, array_to_string(v_allowed, ', '),
                    CASE WHEN p_key = 'schedule.recurrences' THEN ', at least one' ELSE '' END);
    END IF;
  ELSIF p_key IN ('schedule.min_notice_days', 'schedule.horizon_days') THEN
    IF NOT (CASE WHEN jsonb_typeof(p_value) = 'number' AND (p_value #>> '{}') ~ '^[0-9]{1,3}$'
                 THEN (p_value #>> '{}')::integer BETWEEN (CASE p_key WHEN 'schedule.horizon_days' THEN 7 ELSE 0 END)
                                                      AND (CASE p_key WHEN 'schedule.horizon_days' THEN 120 ELSE 90 END)
                 ELSE false END) THEN
      RETURN CASE p_key WHEN 'schedule.horizon_days' THEN 'trips are made 7 to 120 days ahead'
                        ELSE 'the notice is 0 to 90 days' END;
    END IF;
  ELSE
    RETURN format('%s is not a setting of regular trips', p_key);
  END IF;
  RETURN NULL;
END $$;

-- the value in force: the stored one when it is valid, else the default
CREATE OR REPLACE FUNCTION ops.schedule_setting(p_key text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT s.value FROM sys.setting s WHERE s.key = p_key AND ops.schedule_setting_problem(p_key, s.value) IS NULL),
                  CASE p_key WHEN 'schedule.approval_stages' THEN '[{"by":"PLATFORM"}]'::jsonb
                             WHEN 'schedule.approval_kinds' THEN '["NEW","CHANGE"]'::jsonb
                             WHEN 'schedule.min_notice_days' THEN '0'::jsonb
                             WHEN 'schedule.horizon_days' THEN '30'::jsonb
                             WHEN 'schedule.recurrences' THEN '["DAILY","WEEKLY","MONTHLY"]'::jsonb END)
$$;

CREATE OR REPLACE FUNCTION ops.set_schedule_setting(p_key text, p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_problem text;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the settings of regular trips are the platform''s' USING ERRCODE = 'P0001';
  END IF;
  v_problem := ops.schedule_setting_problem(p_key, p_value);
  IF v_problem IS NOT NULL THEN
    RAISE EXCEPTION 'INVALID_SETTING: %', v_problem USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
  VALUES (p_key, p_value, 'PLATFORM', 'Setting of regular trips (1117)', sys.ctx_user_id(), now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  RETURN p_value;
END $$;

CREATE OR REPLACE FUNCTION ops.schedule_needs_approval(p_kind text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT ops.schedule_setting('schedule.approval_kinds') ? p_kind
$$;

-- ------------------------------------------------------------------ a regular trip: how it repeats
ALTER TABLE ops.trip_template
  ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS recurrence text NOT NULL DEFAULT 'WEEKLY',
  ADD COLUMN IF NOT EXISTS days_of_month smallint[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS skip_dates date[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS trip_type text NOT NULL DEFAULT 'SCHEDULED',
  ADD COLUMN IF NOT EXISTS auto_publish boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS rolling boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS generated_until date,
  ADD COLUMN IF NOT EXISTS last_run jsonb,
  ADD COLUMN IF NOT EXISTS approved_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS trip_template_uid_key ON ops.trip_template (uid);
ALTER TABLE ops.trip_template DROP CONSTRAINT IF EXISTS trip_template_recurrence_check;
ALTER TABLE ops.trip_template ADD CONSTRAINT trip_template_recurrence_check CHECK (
  recurrence IN ('DAILY', 'WEEKLY', 'MONTHLY')
  AND days_of_week <@ '{1,2,3,4,5,6,7}'::smallint[]
  AND days_of_month <@ '{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31}'::smallint[]
  AND (recurrence <> 'WEEKLY' OR cardinality(days_of_week) > 0)
  AND (recurrence <> 'MONTHLY' OR cardinality(days_of_month) > 0)
  AND cardinality(skip_dates) <= 400);
ALTER TABLE ops.trip_template DROP CONSTRAINT IF EXISTS trip_template_trip_type_check;
ALTER TABLE ops.trip_template ADD CONSTRAINT trip_template_trip_type_check
  CHECK (trip_type IN ('SCHEDULED', 'SHUTTLE', 'INTERNATIONAL', 'CARGO', 'EXTRA'));
COMMENT ON COLUMN ops.trip_template.recurrence IS 'DAILY: every day; WEEKLY: on days_of_week (ISO, Monday 1); MONTHLY: on days_of_month (a day a month lacks is not run) (1117)';
COMMENT ON COLUMN ops.trip_template.skip_dates IS 'Dates inside the period the regular trip does not run (holidays, closures) (1117)';
COMMENT ON COLUMN ops.trip_template.rolling IS 'The worker makes its trips ahead up to schedule.horizon_days; true for regular trips approved through ops.schedule_request (1117)';
COMMENT ON COLUMN ops.trip_template.generated_until IS 'The last day whose trips the worker has made (1117)';
COMMENT ON COLUMN ops.trip_template.last_run IS 'What the last making of trips did: when, how many, and the days it skipped with why (1117)';

-- the days a pattern runs between two dates, the dates it skips left out; one rule for the database, the API and the screens
CREATE OR REPLACE FUNCTION ops.recurrence_days(p_from date, p_to date, p_recurrence text, p_days_of_week smallint[],
                                               p_days_of_month smallint[], p_skip date[] DEFAULT '{}') RETURNS SETOF date
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT d::date FROM generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
   WHERE NOT (d::date = ANY (coalesce(p_skip, '{}'::date[])))
     AND CASE p_recurrence WHEN 'DAILY' THEN true
                           WHEN 'WEEKLY' THEN extract(isodow FROM d)::smallint = ANY (coalesce(p_days_of_week, '{}'::smallint[]))
                           WHEN 'MONTHLY' THEN extract(day FROM d)::smallint = ANY (coalesce(p_days_of_month, '{}'::smallint[]))
                           ELSE false END
$$;

-- a service number serves one regular trip at a time on the days it runs; versions of one regular trip follow each other
CREATE OR REPLACE FUNCTION ops.tg_template_service_number() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.service_number_id IS NOT NULL AND NEW.status <> 'RETIRED' AND NOT isempty(NEW.active) AND EXISTS (
       SELECT 1 FROM ops.trip_template o
        WHERE o.service_number_id = NEW.service_number_id AND o.id <> NEW.id AND o.status <> 'RETIRED'
          AND o.active && NEW.active
          AND NOT (o.recurrence = 'WEEKLY' AND NEW.recurrence = 'WEEKLY' AND NOT o.days_of_week && NEW.days_of_week)
          AND NOT (o.recurrence = 'MONTHLY' AND NEW.recurrence = 'MONTHLY' AND NOT o.days_of_month && NEW.days_of_month)) THEN
    RAISE EXCEPTION 'SERVICE_NUMBER_TAKEN: another regular trip runs under this number on the same days' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS template_service_number ON ops.trip_template;
CREATE TRIGGER template_service_number
  BEFORE INSERT OR UPDATE OF service_number_id, status, active, days_of_week, recurrence, days_of_month ON ops.trip_template
  FOR EACH ROW EXECUTE FUNCTION ops.tg_template_service_number();

-- ------------------------------------------------------------------ the members of a government authority
CREATE TABLE IF NOT EXISTS sec.authority_member (
  authority_id  bigint NOT NULL REFERENCES sec.authority_profile(id),
  user_id       bigint NOT NULL REFERENCES iam.app_user(id),
  added_by      bigint REFERENCES iam.app_user(id),
  added_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (authority_id, user_id)
);
CREATE INDEX IF NOT EXISTS authority_member_user_id_fkx ON sec.authority_member (user_id);
CREATE INDEX IF NOT EXISTS authority_member_added_by_fkx ON sec.authority_member (added_by);
COMMENT ON TABLE sec.authority_member IS 'The staff accounts that decide for a government authority, at the approval stages that name it (1117)';
SELECT sys.rls_platform('sec.authority_member');
GRANT SELECT, INSERT ON sec.authority_member TO masslak_app;
GRANT SELECT ON sec.authority_member TO masslak_readonly;
DROP TRIGGER IF EXISTS zz_audit_capture ON sec.authority_member;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON sec.authority_member
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

CREATE OR REPLACE FUNCTION sec.remove_authority_member(p_authority_id bigint, p_user_id bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform names the members of an authority' USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM sec.authority_member WHERE authority_id = p_authority_id AND user_id = p_user_id;
  RETURN FOUND;
END $$;

-- ------------------------------------------------------------------ requests and their decisions
CREATE TABLE IF NOT EXISTS ops.schedule_request (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid              uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id       bigint NOT NULL REFERENCES iam.company(id),
  kind             text NOT NULL CHECK (kind IN ('NEW', 'CHANGE', 'STOP', 'TRIP')),
  template_id      bigint REFERENCES ops.trip_template(id),
  trip_id          bigint REFERENCES ops.trip(id),
  proposal         jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(proposal) = 'object'),
  effective_from   date,
  proposed_number  integer CHECK (proposed_number BETWEEN 1 AND 9999),
  assigned_number  integer CHECK (assigned_number BETWEEN 1 AND 9999),
  note             text CHECK (length(note) <= 500),
  approval_stages  jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(approval_stages) = 'array'),
  step             smallint NOT NULL DEFAULT 0 CHECK (step >= 0),
  status           text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED', 'WITHDRAWN')),
  requested_by     bigint NOT NULL REFERENCES iam.app_user(id),
  requested_at     timestamptz NOT NULL DEFAULT now(),
  decided_at       timestamptz,
  decision_note    text CHECK (length(decision_note) <= 500),
  result           jsonb,
  CHECK (kind NOT IN ('CHANGE', 'STOP') OR (template_id IS NOT NULL AND effective_from IS NOT NULL)),
  CHECK (kind <> 'TRIP' OR trip_id IS NOT NULL),
  CHECK (kind <> 'NEW' OR template_id IS NULL OR status = 'APPROVED'),
  CHECK ((status = 'PENDING') = (decided_at IS NULL))
);
CREATE INDEX IF NOT EXISTS schedule_request_company_id_fkx ON ops.schedule_request (company_id, status);
CREATE INDEX IF NOT EXISTS schedule_request_template_id_fkx ON ops.schedule_request (template_id);
CREATE INDEX IF NOT EXISTS schedule_request_trip_id_fkx ON ops.schedule_request (trip_id);
CREATE INDEX IF NOT EXISTS schedule_request_requested_by_fkx ON ops.schedule_request (requested_by);
CREATE INDEX IF NOT EXISTS schedule_request_pending_idx ON ops.schedule_request (requested_at) WHERE status = 'PENDING';
CREATE UNIQUE INDEX IF NOT EXISTS schedule_request_one_open_per_template ON ops.schedule_request (template_id) WHERE status = 'PENDING';
CREATE UNIQUE INDEX IF NOT EXISTS schedule_request_one_open_per_trip ON ops.schedule_request (trip_id) WHERE status = 'PENDING';
COMMENT ON TABLE ops.schedule_request IS 'A carrier''s request for a new regular trip, a change, a stop, or a trip made by hand, with the approval stages in force when it was made (1117)';
COMMENT ON COLUMN ops.schedule_request.assigned_number IS 'The number the platform organizes for a new regular trip; it may differ from the one asked for (1117)';
COMMENT ON COLUMN ops.schedule_request.result IS 'What applying the request did: the regular trip, its number, the trips cancelled and those kept because they have bookings (1117)';
SELECT sys.rls_tenant('ops.schedule_request');
GRANT SELECT ON ops.schedule_request TO masslak_app, masslak_readonly;      -- written through the functions below only

CREATE TABLE IF NOT EXISTS ops.schedule_approval (
  request_id       bigint NOT NULL REFERENCES ops.schedule_request(id),
  step             smallint NOT NULL CHECK (step >= 1),
  stage            jsonb NOT NULL CHECK (jsonb_typeof(stage) = 'object'),
  decision         text NOT NULL CHECK (decision IN ('APPROVED', 'REJECTED')),
  decided_by       bigint NOT NULL REFERENCES iam.app_user(id),
  authority_id     bigint REFERENCES sec.authority_profile(id),
  assigned_number  integer CHECK (assigned_number BETWEEN 1 AND 9999),
  note             text CHECK (length(note) <= 500),
  decided_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, step)
);
CREATE INDEX IF NOT EXISTS schedule_approval_decided_by_fkx ON ops.schedule_approval (decided_by);
CREATE INDEX IF NOT EXISTS schedule_approval_authority_id_fkx ON ops.schedule_approval (authority_id);
COMMENT ON TABLE ops.schedule_approval IS 'Each stage''s decision on a request of regular trips: who, for whom (the platform or an authority), and when; never changed (1117)';
DROP TRIGGER IF EXISTS schedule_approval_immutable ON ops.schedule_approval;
CREATE TRIGGER schedule_approval_immutable BEFORE UPDATE OR DELETE ON ops.schedule_approval
  FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
SELECT sys.rls_parent('ops.schedule_approval', 'request_id', 'ops.schedule_request');
GRANT SELECT ON ops.schedule_approval TO masslak_app, masslak_readonly;

-- carriers no longer write templates or service numbers: both come from approved requests (a pause and its resume stay)
REVOKE INSERT, UPDATE ON ops.trip_template FROM masslak_app;
GRANT UPDATE (status, generated_until, last_run) ON ops.trip_template TO masslak_app;
REVOKE INSERT, UPDATE ON net.service_number FROM masslak_app;

CREATE OR REPLACE FUNCTION ops.tg_template_status_by_carrier() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  -- the worker and the platform pass; a carrier pauses an active regular trip and resumes it, nothing else
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT sys.ctx_is_platform() AND sys.ctx_company_id() IS NOT NULL
     AND NOT (OLD.status = 'ACTIVE' AND NEW.status = 'PAUSED') AND NOT (OLD.status = 'PAUSED' AND NEW.status = 'ACTIVE') THEN
    RAISE EXCEPTION 'SCHEDULE_STOP_REQUIRED: a regular trip ends through a stop request' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS template_status_by_carrier ON ops.trip_template;
CREATE TRIGGER template_status_by_carrier BEFORE UPDATE OF status ON ops.trip_template
  FOR EACH ROW EXECUTE FUNCTION ops.tg_template_status_by_carrier();

-- ------------------------------------------------------------------ numbers
-- the block of numbers a trip type takes (study 4.16 b; net.service_number checks the ranges and the parity)
CREATE OR REPLACE FUNCTION ops.number_block(p_trip_type text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE p_trip_type WHEN 'INTERNATIONAL' THEN 'INTL' WHEN 'SHUTTLE' THEN 'SHUTTLE' WHEN 'CARGO' THEN 'CARGO'
                          WHEN 'EXTRA' THEN 'EXTRA' ELSE 'SCHEDULED' END
$$;

CREATE OR REPLACE FUNCTION ops.number_problem(p_block text, p_direction text, p_number integer) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE
    WHEN p_number IS NULL THEN NULL
    WHEN NOT CASE p_block WHEN 'SCHEDULED' THEN p_number BETWEEN 1 AND 999 WHEN 'INTL' THEN p_number BETWEEN 1000 AND 1999
                          WHEN 'SHUTTLE' THEN p_number BETWEEN 2000 AND 2999 WHEN 'CARGO' THEN p_number BETWEEN 3000 AND 3999
                          ELSE p_number BETWEEN 5000 AND 9999 END
      THEN format('NUMBER_NOT_IN_BLOCK: the %s numbers are %s', lower(p_block),
                  CASE p_block WHEN 'SCHEDULED' THEN '1 to 999' WHEN 'INTL' THEN '1000 to 1999' WHEN 'SHUTTLE' THEN '2000 to 2999'
                               WHEN 'CARGO' THEN '3000 to 3999' ELSE '5000 to 9999' END)
    WHEN p_block <> 'EXTRA' AND (p_direction = 'OUTBOUND') <> (p_number % 2 = 1)
      THEN 'NUMBER_PARITY: an outbound trip takes an odd number, its return an even one'
  END
$$;

-- whether a carrier's number is free for a period, apart from the service number of the regular trip itself
CREATE OR REPLACE FUNCTION ops.schedule_number_free(p_company bigint, p_number integer, p_period daterange, p_route bigint,
                                                    p_keep bigint DEFAULT NULL) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT NOT EXISTS (SELECT 1 FROM net.service_number s
                      WHERE s.company_id = p_company AND s.number = p_number AND s.valid && p_period
                        AND s.id IS DISTINCT FROM p_keep
                        AND (s.route_id IS DISTINCT FROM p_route
                             OR EXISTS (SELECT 1 FROM ops.trip_template t
                                         WHERE t.service_number_id = s.id AND t.status <> 'RETIRED' AND t.active && p_period)))
$$;

-- the lowest free number of the block with the direction's parity: what the platform suggests
CREATE OR REPLACE FUNCTION ops.suggest_schedule_number(p_company bigint, p_trip_type text, p_direction text, p_period daterange,
                                                       p_route bigint) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT n FROM generate_series(1, 9999) n
   WHERE ops.number_problem(ops.number_block(p_trip_type), p_direction, n) IS NULL
     AND ops.schedule_number_free(p_company, n, p_period, p_route)
   ORDER BY n LIMIT 1
$$;

-- ------------------------------------------------------------------ what a request asks for, checked
-- the full description of a regular trip (a new one, or a version after a change) and what is wrong with it
CREATE OR REPLACE FUNCTION ops.schedule_proposal_problem(p_company bigint, p jsonb) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k text; v_from date; v_until date;
BEGIN
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k NOT IN ('route_id', 'vehicle_id', 'departure_time', 'recurrence', 'days_of_week', 'days_of_month', 'skip_dates',
                 'from', 'until', 'base_price', 'currency', 'trip_type', 'direction', 'auto_publish') THEN
      RETURN format('%s is not part of a regular trip', k);
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM net.route r WHERE r.id = (p ->> 'route_id')::bigint AND r.company_id = p_company AND r.status = 'ACTIVE') THEN
    RETURN 'the route is not an active route of the carrier';
  END IF;
  IF p ->> 'vehicle_id' IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM fleet.vehicle v WHERE v.id = (p ->> 'vehicle_id')::bigint AND v.company_id = p_company) THEN
    RETURN 'the vehicle is not the carrier''s';
  END IF;
  IF coalesce(p ->> 'departure_time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9](:00)?$' THEN
    RETURN 'the departure time is HH:MM';
  END IF;
  IF NOT ops.schedule_setting('schedule.recurrences') ? coalesce(p ->> 'recurrence', '') THEN
    RETURN format('a regular trip repeats %s', (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(ops.schedule_setting('schedule.recurrences')) x));
  END IF;
  IF jsonb_typeof(p -> 'days_of_week') IS DISTINCT FROM 'array' OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p -> 'days_of_week') x WHERE jsonb_typeof(x) <> 'number' OR (x #>> '{}') !~ '^[1-7]$')
     OR (p ->> 'recurrence' = 'WEEKLY' AND jsonb_array_length(p -> 'days_of_week') = 0) THEN
    RETURN 'the days of the week are 1 (Monday) to 7 (Sunday), at least one for a weekly trip';
  END IF;
  IF jsonb_typeof(p -> 'days_of_month') IS DISTINCT FROM 'array' OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p -> 'days_of_month') x
        WHERE jsonb_typeof(x) <> 'number' OR (x #>> '{}') !~ '^[0-9]{1,2}$' OR (x #>> '{}')::int NOT BETWEEN 1 AND 31)
     OR (p ->> 'recurrence' = 'MONTHLY' AND jsonb_array_length(p -> 'days_of_month') = 0) THEN
    RETURN 'the days of the month are 1 to 31, at least one for a monthly trip';
  END IF;
  IF jsonb_typeof(p -> 'skip_dates') IS DISTINCT FROM 'array' OR jsonb_array_length(p -> 'skip_dates') > 400 OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p -> 'skip_dates') x WHERE jsonb_typeof(x) <> 'string' OR (x #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$') THEN
    RETURN 'the dates without the trip are a list of dates';
  END IF;
  IF coalesce(p ->> 'from', '') !~ '^\d{4}-\d{2}-\d{2}$' OR (p ->> 'until' IS NOT NULL AND (p ->> 'until') !~ '^\d{4}-\d{2}-\d{2}$') THEN
    RETURN 'the period is from a date to a date, or from a date with no end';
  END IF;
  v_from := (p ->> 'from')::date;
  v_until := (p ->> 'until')::date;
  IF v_until IS NOT NULL AND v_until < v_from THEN
    RETURN 'the period ends after it begins';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.recurrence_days(v_from, coalesce(v_until, v_from + 400), p ->> 'recurrence',
                   ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(p -> 'days_of_week') x),
                   ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(p -> 'days_of_month') x),
                   ARRAY(SELECT x::date FROM jsonb_array_elements_text(p -> 'skip_dates') x))) THEN
    RETURN 'the trip would never run in this period';
  END IF;
  IF jsonb_typeof(p -> 'base_price') IS DISTINCT FROM 'number' OR (p ->> 'base_price') !~ '^[0-9]{1,15}$' THEN
    RETURN 'the base price is a whole amount in the smallest unit of the currency';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ref.currency c WHERE c.code = p ->> 'currency') THEN
    RETURN 'the currency is not known';
  END IF;
  IF coalesce(p ->> 'trip_type', '') NOT IN ('SCHEDULED', 'SHUTTLE', 'INTERNATIONAL', 'CARGO', 'EXTRA') THEN
    RETURN 'the trip type is SCHEDULED, SHUTTLE, INTERNATIONAL, CARGO or EXTRA';
  END IF;
  IF coalesce(p ->> 'direction', '') NOT IN ('OUTBOUND', 'INBOUND') THEN
    RETURN 'the direction is OUTBOUND or INBOUND';
  END IF;
  IF jsonb_typeof(p -> 'auto_publish') IS DISTINCT FROM 'boolean' THEN
    RETURN 'publishing its trips is true or false';
  END IF;
  RETURN NULL;
END $$;

-- a regular trip as a proposal, so that a change is checked as the whole version it makes
CREATE OR REPLACE FUNCTION ops.template_as_proposal(p_template_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
           'route_id', t.route_id, 'vehicle_id', t.default_vehicle_id, 'departure_time', to_char(t.departure_time, 'HH24:MI'),
           'recurrence', t.recurrence, 'days_of_week', to_jsonb(t.days_of_week), 'days_of_month', to_jsonb(t.days_of_month),
           'skip_dates', to_jsonb(t.skip_dates), 'from', lower(t.active), 'until', upper(t.active) - 1,
           'base_price', t.base_price, 'currency', t.currency, 'trip_type', t.trip_type,
           'direction', coalesce((SELECT s.direction FROM net.service_number s WHERE s.id = t.service_number_id), 'OUTBOUND'),
           'auto_publish', t.auto_publish)
    FROM ops.trip_template t WHERE t.id = p_template_id
$$;

-- ------------------------------------------------------------------ applying an approved request
-- trips of a regular trip from a day on: cancelled when nobody holds a booking, kept (and named) otherwise
CREATE OR REPLACE FUNCTION ops.release_template_trips(p_template_id bigint, p_from date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_cancelled integer;
BEGIN
  WITH gone AS (
    UPDATE ops.trip t SET status = 'CANCELLED'
     WHERE t.template_id = p_template_id AND t.service_date >= p_from AND t.status IN ('DRAFT', 'PUBLISHED')
       AND NOT EXISTS (SELECT 1 FROM sales.booking b WHERE b.trip_id = t.id AND b.status IN ('PENDING_PAYMENT', 'CONFIRMED'))
    RETURNING 1)
  SELECT count(*) INTO v_cancelled FROM gone;
  RETURN jsonb_build_object('cancelled', v_cancelled, 'kept', coalesce((
    SELECT jsonb_agg(jsonb_build_object('trip_uid', t.uid, 'trip_code', t.trip_code, 'trip_no', t.trip_no, 'departure_at', t.departure_at,
                                        'bookings', (SELECT count(*) FROM sales.booking b WHERE b.trip_id = t.id
                                                       AND b.status IN ('PENDING_PAYMENT', 'CONFIRMED'))) ORDER BY t.departure_at)
      FROM ops.trip t
     WHERE t.template_id = p_template_id AND t.service_date >= p_from AND t.status NOT IN ('CANCELLED', 'COMPLETED')), '[]'::jsonb));
END $$;

-- the service number of a regular trip for its period: the carrier's own on the same route, else a new one
CREATE OR REPLACE FUNCTION ops.take_schedule_number(p_company bigint, p_number integer, p_proposal jsonb, p_period daterange,
                                                    p_keep bigint DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_block text := ops.number_block(p_proposal ->> 'trip_type'); v_problem text; v_id bigint;
        v_route bigint := (p_proposal ->> 'route_id')::bigint;
BEGIN
  v_problem := ops.number_problem(v_block, p_proposal ->> 'direction', p_number);
  IF v_problem IS NOT NULL THEN
    RAISE EXCEPTION '%', v_problem USING ERRCODE = 'P0001';
  END IF;
  IF NOT ops.schedule_number_free(p_company, p_number, p_period, v_route, p_keep) THEN
    RAISE EXCEPTION 'SERVICE_NUMBER_TAKEN: the carrier''s number % is taken in this period', p_number USING ERRCODE = 'P0001';
  END IF;
  SELECT s.id INTO v_id FROM net.service_number s
   WHERE s.company_id = p_company AND s.number = p_number AND s.valid && p_period ORDER BY s.id LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO net.service_number (company_id, number, block, route_id, direction, valid)
    VALUES (p_company, p_number, v_block, v_route, p_proposal ->> 'direction', p_period) RETURNING id INTO v_id;
  ELSE
    BEGIN
      UPDATE net.service_number SET valid = valid + p_period, route_id = coalesce(route_id, v_route) WHERE id = v_id;
    EXCEPTION WHEN data_exception OR exclusion_violation THEN
      RAISE EXCEPTION 'SERVICE_NUMBER_TAKEN: the carrier''s number % is taken in another period that touches this one', p_number
        USING ERRCODE = 'P0001';
    END;
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION ops.insert_schedule_version(p_company bigint, p jsonb, p_number_id bigint) RETURNS bigint
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  INSERT INTO ops.trip_template (company_id, route_id, service_number_id, default_vehicle_id, departure_time, days_of_week,
                                 days_of_month, skip_dates, recurrence, base_price, currency, active, status, trip_type,
                                 auto_publish, rolling, approved_at)
  VALUES (p_company, (p ->> 'route_id')::bigint, p_number_id, (p ->> 'vehicle_id')::bigint, (p ->> 'departure_time')::time,
          ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(p -> 'days_of_week') x ORDER BY 1),
          ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(p -> 'days_of_month') x ORDER BY 1),
          ARRAY(SELECT x::date FROM jsonb_array_elements_text(p -> 'skip_dates') x ORDER BY 1),
          p ->> 'recurrence', (p ->> 'base_price')::bigint, p ->> 'currency',
          daterange((p ->> 'from')::date, (p ->> 'until')::date + 1), 'ACTIVE', p ->> 'trip_type',
          (p ->> 'auto_publish')::boolean, true, now())
  RETURNING id
$$;

CREATE OR REPLACE FUNCTION ops.apply_schedule_request(p_request_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r ops.schedule_request; t ops.trip_template; v_merged jsonb; v_number integer; v_number_id bigint; v_new bigint;
        v_released jsonb; v_period daterange;
BEGIN
  SELECT * INTO r FROM ops.schedule_request WHERE id = p_request_id FOR UPDATE;
  IF r.kind = 'NEW' THEN
    v_period := daterange((r.proposal ->> 'from')::date, (r.proposal ->> 'until')::date + 1);
    v_number := coalesce(r.assigned_number, r.proposed_number,
                         ops.suggest_schedule_number(r.company_id, r.proposal ->> 'trip_type', r.proposal ->> 'direction', v_period,
                                                     (r.proposal ->> 'route_id')::bigint));
    IF v_number IS NULL THEN
      RAISE EXCEPTION 'SERVICE_NUMBER_TAKEN: no number of this block is free for the period' USING ERRCODE = 'P0001';
    END IF;
    v_number_id := ops.take_schedule_number(r.company_id, v_number, r.proposal, v_period);
    v_new := ops.insert_schedule_version(r.company_id, r.proposal, v_number_id);
    UPDATE ops.schedule_request SET template_id = v_new, assigned_number = v_number, status = 'APPROVED',
                                    decided_at = coalesce(decided_at, now()) WHERE id = r.id;
    RETURN jsonb_build_object('template_uid', (SELECT uid FROM ops.trip_template WHERE id = v_new), 'number', v_number,
                              'trip_code', ops.trip_designator(r.company_id) || ' ' || v_number);
  ELSIF r.kind IN ('CHANGE', 'STOP') THEN
    SELECT * INTO t FROM ops.trip_template WHERE id = r.template_id FOR UPDATE;
    IF t.status = 'RETIRED' OR (upper(t.active) IS NOT NULL AND upper(t.active) <= r.effective_from AND r.kind = 'CHANGE') THEN
      RAISE EXCEPTION 'SCHEDULE_ENDED: the regular trip has ended before that day' USING ERRCODE = 'P0001';
    END IF;
    -- the current version ends the day before; a version that would not run at all is retired
    UPDATE ops.trip_template
       SET active = CASE WHEN lower(active) >= r.effective_from THEN 'empty'::daterange
                         ELSE daterange(lower(active), LEAST(coalesce(upper(active), r.effective_from), r.effective_from)) END,
           status = CASE WHEN lower(active) >= r.effective_from THEN 'RETIRED' ELSE status END
     WHERE id = t.id;
    v_released := ops.release_template_trips(t.id, r.effective_from);
    IF r.kind = 'STOP' THEN
      RETURN jsonb_build_object('template_uid', t.uid, 'ends', r.effective_from) || v_released;
    END IF;
    v_merged := ops.template_as_proposal(t.id) - 'from' - 'until'
                || jsonb_build_object('from', r.effective_from, 'until', upper(t.active) - 1) || r.proposal;
    v_number := (SELECT s.number FROM net.service_number s WHERE s.id = t.service_number_id);
    IF v_number IS NULL THEN
      v_number := coalesce(r.assigned_number, ops.suggest_schedule_number(t.company_id, v_merged ->> 'trip_type',
                                         v_merged ->> 'direction', daterange(r.effective_from, (v_merged ->> 'until')::date + 1),
                                         t.route_id));
    END IF;
    v_number_id := ops.take_schedule_number(t.company_id, v_number, v_merged,
                                            daterange(r.effective_from, (v_merged ->> 'until')::date + 1), t.service_number_id);
    v_new := ops.insert_schedule_version(t.company_id, v_merged, v_number_id);
    RETURN jsonb_build_object('template_uid', (SELECT uid FROM ops.trip_template WHERE id = v_new), 'replaces', t.uid,
                              'from', r.effective_from, 'number', v_number,
                              'trip_code', ops.trip_designator(t.company_id) || ' ' || v_number) || v_released;
  ELSE                                                   -- TRIP: the trip made by hand is published, once approved
    UPDATE ops.schedule_request SET status = 'APPROVED', decided_at = coalesce(decided_at, now()) WHERE id = r.id;
    UPDATE ops.trip SET status = 'PUBLISHED', published_at = now() WHERE id = r.trip_id AND status = 'DRAFT';
    RETURN jsonb_build_object('trip_uid', (SELECT uid FROM ops.trip WHERE id = r.trip_id), 'published', FOUND);
  END IF;
END $$;

-- ------------------------------------------------------------------ asking, deciding, withdrawing
CREATE OR REPLACE FUNCTION ops.request_schedule(p_kind text, p_template_uid uuid, p_trip_uid uuid, p_proposal jsonb,
                                                p_effective_from date, p_proposed_number integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_company bigint := sys.ctx_company_id(); t ops.trip_template; v_trip ops.trip; v_problem text; v_day date;
        v_proposal jsonb := coalesce(p_proposal, '{}'::jsonb); v_id bigint; v_needs boolean; v_result jsonb;
BEGIN
  IF v_company IS NULL OR sys.ctx_user_id() IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: a carrier asks for its regular trips' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind NOT IN ('NEW', 'CHANGE', 'STOP', 'TRIP') THEN
    RAISE EXCEPTION 'SCHEDULE_INVALID: a request is NEW, CHANGE, STOP or TRIP' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind IN ('CHANGE', 'STOP') THEN
    SELECT * INTO t FROM ops.trip_template WHERE uid = p_template_uid AND company_id = v_company;
    IF t.id IS NULL OR t.status = 'RETIRED' THEN
      RAISE EXCEPTION 'NOT_FOUND: no such regular trip of the carrier' USING ERRCODE = 'P0001';
    END IF;
    IF p_effective_from IS NULL OR (upper(t.active) IS NOT NULL AND p_effective_from >= upper(t.active)) THEN
      RAISE EXCEPTION 'SCHEDULE_INVALID: the day it takes effect falls inside the regular trip''s period' USING ERRCODE = 'P0001';
    END IF;
    v_day := p_effective_from;
    IF p_kind = 'STOP' THEN
      v_proposal := '{}'::jsonb;
    ELSE
      IF v_proposal = '{}'::jsonb OR v_proposal ? 'from' OR v_proposal ? 'route_id' OR v_proposal ? 'trip_type' OR v_proposal ? 'currency' THEN
        RAISE EXCEPTION 'SCHEDULE_INVALID: a change names what changes: time, days, dates without the trip, end, vehicle, price or publishing'
          USING ERRCODE = 'P0001';
      END IF;
      v_problem := ops.schedule_proposal_problem(v_company, ops.template_as_proposal(t.id) - 'from' - 'until'
                     || jsonb_build_object('from', p_effective_from, 'until', upper(t.active) - 1) || v_proposal);
    END IF;
  ELSIF p_kind = 'NEW' THEN
    v_proposal := jsonb_build_object('days_of_week', '[]'::jsonb, 'days_of_month', '[]'::jsonb, 'skip_dates', '[]'::jsonb,
                                     'trip_type', 'SCHEDULED', 'direction', 'OUTBOUND', 'auto_publish', true) || v_proposal;
    v_problem := ops.schedule_proposal_problem(v_company, v_proposal);
    v_day := (v_proposal ->> 'from')::date;
    IF v_problem IS NULL AND p_proposed_number IS NOT NULL THEN
      v_problem := ops.number_problem(ops.number_block(v_proposal ->> 'trip_type'), v_proposal ->> 'direction', p_proposed_number);
    END IF;
  ELSE
    SELECT * INTO v_trip FROM ops.trip WHERE uid = p_trip_uid AND company_id = v_company;
    IF v_trip.id IS NULL THEN
      RAISE EXCEPTION 'NOT_FOUND: no such trip of the carrier' USING ERRCODE = 'P0001';
    END IF;
    IF v_trip.status <> 'DRAFT' OR v_trip.template_id IS NOT NULL THEN
      RAISE EXCEPTION 'SCHEDULE_INVALID: only a draft trip made by hand is asked for' USING ERRCODE = 'P0001';
    END IF;
    v_proposal := '{}'::jsonb;
  END IF;
  IF v_problem IS NOT NULL THEN
    RAISE EXCEPTION 'SCHEDULE_INVALID: %', v_problem USING ERRCODE = 'P0001';
  END IF;
  -- the carrier's today is its market's, not the server's (00:00 to 03:00 in Damascus is still yesterday in UTC)
  IF v_day IS NOT NULL
     AND v_day < (now() AT TIME ZONE ref.company_tz(v_company))::date + (ops.schedule_setting('schedule.min_notice_days') #>> '{}')::integer THEN
    RAISE EXCEPTION 'SCHEDULE_NOTICE: it takes effect at least % day(s) after it is asked for, and never in the past',
      ops.schedule_setting('schedule.min_notice_days') #>> '{}' USING ERRCODE = 'P0001';
  END IF;
  v_needs := ops.schedule_needs_approval(p_kind);
  BEGIN
    INSERT INTO ops.schedule_request (company_id, kind, template_id, trip_id, proposal, effective_from, proposed_number, note,
                                      approval_stages, requested_by)
    VALUES (v_company, p_kind, t.id, v_trip.id, v_proposal, CASE WHEN p_kind IN ('CHANGE', 'STOP') THEN p_effective_from END,
            p_proposed_number, nullif(btrim(p_note), ''),
            CASE WHEN v_needs THEN ops.schedule_setting('schedule.approval_stages') ELSE '[]'::jsonb END, sys.ctx_user_id())
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'SCHEDULE_REQUEST_OPEN: a request for it is already waiting' USING ERRCODE = 'P0001';
  END;
  IF NOT v_needs THEN                                    -- a kind the settings let through is applied at once
    v_result := ops.apply_schedule_request(v_id);
    UPDATE ops.schedule_request SET status = 'APPROVED', decided_at = now(), result = v_result WHERE id = v_id;
  END IF;
  RETURN jsonb_build_object('uid', (SELECT uid FROM ops.schedule_request WHERE id = v_id),
                            'status', CASE WHEN v_needs THEN 'PENDING' ELSE 'APPROVED' END, 'result', v_result);
END $$;

-- whether the caller decides a stage: the platform's staff for the platform, an authority's members for that authority
CREATE OR REPLACE FUNCTION ops.schedule_stage_authority(p_stage jsonb) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT a.id FROM sec.authority_profile a JOIN sec.authority_member m ON m.authority_id = a.id
   WHERE p_stage ->> 'by' = 'AUTHORITY' AND a.code = p_stage ->> 'authority' AND m.user_id = sys.ctx_user_id()
$$;

CREATE OR REPLACE FUNCTION ops.may_decide_schedule_stage(p_stage jsonb) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  -- a member of an authority decides for that authority only, never at the platform's stage
  SELECT CASE p_stage ->> 'by' WHEN 'PLATFORM' THEN sys.ctx_is_platform()
                                                    AND NOT EXISTS (SELECT 1 FROM sec.authority_member m WHERE m.user_id = sys.ctx_user_id())
                               WHEN 'AUTHORITY' THEN ops.schedule_stage_authority(p_stage) IS NOT NULL
                               ELSE false END
$$;

CREATE OR REPLACE FUNCTION ops.decide_schedule_request(p_uid uuid, p_approve boolean, p_note text, p_number integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r ops.schedule_request; v_stage jsonb; v_step smallint; v_result jsonb; v_proposal jsonb;
BEGIN
  SELECT * INTO r FROM ops.schedule_request WHERE uid = p_uid FOR UPDATE;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: no such request' USING ERRCODE = 'P0001';
  END IF;
  IF r.status <> 'PENDING' THEN
    RAISE EXCEPTION 'SCHEDULE_DECIDED: the request is already %', lower(r.status) USING ERRCODE = 'P0001';
  END IF;
  v_step := r.step + 1;
  v_stage := r.approval_stages -> (v_step - 1);
  IF NOT ops.may_decide_schedule_stage(v_stage) THEN
    RAISE EXCEPTION 'NOT_YOUR_STAGE: the request waits for %', CASE v_stage ->> 'by' WHEN 'PLATFORM' THEN 'the platform'
                                                              ELSE 'the authority ' || (v_stage ->> 'authority') END
      USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.schedule_approval a WHERE a.request_id = r.id AND a.decided_by = sys.ctx_user_id())
     OR r.requested_by = sys.ctx_user_id() THEN
    RAISE EXCEPTION 'SECOND_PERSON_REQUIRED: one person decides one stage of a request' USING ERRCODE = 'P0001';
  END IF;
  IF NOT p_approve AND length(btrim(coalesce(p_note, ''))) < 3 THEN
    RAISE EXCEPTION 'REASON_REQUIRED: a refusal says why' USING ERRCODE = 'P0001';
  END IF;
  IF p_number IS NOT NULL THEN                           -- the platform organizes the numbers of new regular trips
    IF r.kind <> 'NEW' OR v_stage ->> 'by' <> 'PLATFORM' THEN
      RAISE EXCEPTION 'SCHEDULE_INVALID: the platform gives the number of a new regular trip' USING ERRCODE = 'P0001';
    END IF;
    v_proposal := r.proposal;
    IF ops.number_problem(ops.number_block(v_proposal ->> 'trip_type'), v_proposal ->> 'direction', p_number) IS NOT NULL THEN
      RAISE EXCEPTION '%', ops.number_problem(ops.number_block(v_proposal ->> 'trip_type'), v_proposal ->> 'direction', p_number)
        USING ERRCODE = 'P0001';
    END IF;
    IF NOT ops.schedule_number_free(r.company_id, p_number, daterange((v_proposal ->> 'from')::date, (v_proposal ->> 'until')::date + 1),
                                    (v_proposal ->> 'route_id')::bigint) THEN
      RAISE EXCEPTION 'SERVICE_NUMBER_TAKEN: the carrier''s number % is taken in this period', p_number USING ERRCODE = 'P0001';
    END IF;
    UPDATE ops.schedule_request SET assigned_number = p_number WHERE id = r.id;
  END IF;
  INSERT INTO ops.schedule_approval (request_id, step, stage, decision, decided_by, authority_id, assigned_number, note)
  VALUES (r.id, v_step, v_stage, CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END, sys.ctx_user_id(),
          ops.schedule_stage_authority(v_stage), p_number, nullif(btrim(p_note), ''));
  IF NOT p_approve THEN
    UPDATE ops.schedule_request SET step = v_step, status = 'REJECTED', decided_at = now(), decision_note = btrim(p_note) WHERE id = r.id;
    RETURN jsonb_build_object('status', 'REJECTED', 'step', v_step);
  END IF;
  IF v_step < jsonb_array_length(r.approval_stages) THEN
    UPDATE ops.schedule_request SET step = v_step WHERE id = r.id;
    RETURN jsonb_build_object('status', 'PENDING', 'step', v_step, 'next', r.approval_stages -> v_step);
  END IF;
  UPDATE ops.schedule_request SET step = v_step WHERE id = r.id;
  v_result := ops.apply_schedule_request(r.id);
  UPDATE ops.schedule_request SET status = 'APPROVED', decided_at = now(), decision_note = nullif(btrim(p_note), ''), result = v_result
   WHERE id = r.id;
  RETURN jsonb_build_object('status', 'APPROVED', 'step', v_step, 'result', v_result);
END $$;

CREATE OR REPLACE FUNCTION ops.withdraw_schedule_request(p_uid uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  UPDATE ops.schedule_request SET status = 'WITHDRAWN', decided_at = now()
   WHERE uid = p_uid AND status = 'PENDING' AND company_id = sys.ctx_company_id();
  RETURN FOUND;
END $$;

-- ------------------------------------------------------------------ a trip made by hand waits for its approval
CREATE OR REPLACE FUNCTION ops.tg_trip_publish_approval() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.status = 'PUBLISHED' AND (TG_OP = 'INSERT' OR OLD.status = 'DRAFT') AND NEW.template_id IS NULL
     AND ops.schedule_needs_approval('TRIP')
     AND NOT EXISTS (SELECT 1 FROM ops.schedule_request r WHERE r.trip_id = NEW.id AND r.kind = 'TRIP' AND r.status = 'APPROVED') THEN
    RAISE EXCEPTION 'TRIP_APPROVAL_REQUIRED: a trip made by hand is published once its approval stages are passed' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_trip_publish_approval ON ops.trip;
CREATE TRIGGER b_trip_publish_approval BEFORE INSERT OR UPDATE OF status ON ops.trip
  FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_publish_approval();

-- ------------------------------------------------------------------ the regular trips whose trips are due
-- the days run from the carrier's today, in its market's time zone, to the horizon
CREATE OR REPLACE FUNCTION ops.schedules_due() RETURNS TABLE (template_id bigint, from_day date, to_day date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT id, from_day, to_day FROM (
    SELECT t.id, greatest(coalesce(t.generated_until + 1, lower(t.active)), d.today) AS from_day,
           least(d.today + (ops.schedule_setting('schedule.horizon_days') #>> '{}')::integer,
                 coalesce(upper(t.active) - 1, 'infinity'::date)) AS to_day
      FROM ops.trip_template t
     CROSS JOIN LATERAL (SELECT (now() AT TIME ZONE ref.company_tz(t.company_id))::date AS today) d
     WHERE t.rolling AND t.status = 'ACTIVE' AND NOT isempty(t.active)) due
   WHERE from_day <= to_day
   ORDER BY id
$$;

-- ------------------------------------------------------------------ privileges, comments
REVOKE ALL ON FUNCTION ops.schedule_setting_problem(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.schedule_setting(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.set_schedule_setting(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.schedule_needs_approval(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.recurrence_days(date, date, text, smallint[], smallint[], date[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION sec.remove_authority_member(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.number_block(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.number_problem(text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.schedule_number_free(bigint, integer, daterange, bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.suggest_schedule_number(bigint, text, text, daterange, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.schedule_proposal_problem(bigint, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.template_as_proposal(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.release_template_trips(bigint, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.take_schedule_number(bigint, integer, jsonb, daterange, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.insert_schedule_version(bigint, jsonb, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.apply_schedule_request(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.request_schedule(text, uuid, uuid, jsonb, date, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.schedule_stage_authority(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.may_decide_schedule_stage(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.decide_schedule_request(uuid, boolean, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.withdraw_schedule_request(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.schedules_due() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.schedule_setting(text), ops.set_schedule_setting(text, jsonb), ops.schedule_needs_approval(text),
  ops.recurrence_days(date, date, text, smallint[], smallint[], date[]), sec.remove_authority_member(bigint, bigint),
  ops.suggest_schedule_number(bigint, text, text, daterange, bigint), ops.template_as_proposal(bigint),
  ops.request_schedule(text, uuid, uuid, jsonb, date, integer, text), ops.may_decide_schedule_stage(jsonb),
  ops.decide_schedule_request(uuid, boolean, text, integer), ops.withdraw_schedule_request(uuid), ops.schedules_due()
  TO masslak_app;
COMMENT ON FUNCTION ops.schedule_setting_problem IS 'What is wrong with a value of a setting of regular trips, or NULL (1117)';
COMMENT ON FUNCTION ops.schedule_setting IS 'The value in force of a setting of regular trips: the stored one when valid, else the default (1117)';
COMMENT ON FUNCTION ops.set_schedule_setting IS 'The platform sets the approval stages, the kinds that pass them, the notice, the horizon and the patterns of regular trips (1117)';
COMMENT ON FUNCTION ops.schedule_needs_approval IS 'Whether a kind of request (NEW, CHANGE, STOP, TRIP) passes the approval stages (1117)';
COMMENT ON FUNCTION ops.recurrence_days IS 'The days a pattern runs between two dates, its dates without the trip left out (1117)';
COMMENT ON FUNCTION sec.remove_authority_member IS 'The platform removes a member of a government authority (1117)';
COMMENT ON FUNCTION ops.number_block IS 'The block of service numbers a trip type takes (study 4.16 b, 1117)';
COMMENT ON FUNCTION ops.number_problem IS 'What is wrong with a number for a block and a direction: its range, or its parity (1117)';
COMMENT ON FUNCTION ops.schedule_number_free IS 'Whether a carrier''s number is free for a period, apart from the regular trip''s own (1117)';
COMMENT ON FUNCTION ops.suggest_schedule_number IS 'The lowest free number of the block with the direction''s parity (1117)';
COMMENT ON FUNCTION ops.schedule_proposal_problem IS 'What is wrong with the description of a regular trip, or NULL (1117)';
COMMENT ON FUNCTION ops.template_as_proposal IS 'A regular trip described as a proposal, so a change is checked as the version it makes (1117)';
COMMENT ON FUNCTION ops.release_template_trips IS 'Trips of a regular trip from a day: cancelled without bookings, kept and named with them (1117)';
COMMENT ON FUNCTION ops.take_schedule_number IS 'The service number of a regular trip for its period: the carrier''s own on the route, else a new one (1117)';
COMMENT ON FUNCTION ops.insert_schedule_version IS 'Writes an approved version of a regular trip (1117)';
COMMENT ON FUNCTION ops.apply_schedule_request IS 'Applies an approved request: a new regular trip, the next version, a stop, or the publication of a trip made by hand (1117)';
COMMENT ON FUNCTION ops.request_schedule IS 'A carrier asks for a new regular trip, a change, a stop, or the publication of a trip made by hand; applied at once when its kind needs no approval (1117)';
COMMENT ON FUNCTION ops.schedule_stage_authority IS 'The authority the caller decides for at a stage, or NULL (1117)';
COMMENT ON FUNCTION ops.may_decide_schedule_stage IS 'Whether the caller decides a stage: the platform''s staff, or the named authority''s members (1117)';
COMMENT ON FUNCTION ops.decide_schedule_request IS 'One stage''s decision on a request; the last approval applies it; one person decides one stage (1117)';
COMMENT ON FUNCTION ops.withdraw_schedule_request IS 'The carrier withdraws a request still waiting (1117)';
COMMENT ON FUNCTION ops.schedules_due IS 'The regular trips whose trips are due, with the days to make: up to the horizon, within their period (1117)';
COMMENT ON FUNCTION ops.tg_trip_publish_approval IS 'While TRIP is among the kinds that need approval, a trip made by hand is published only once approved (1117)';
COMMENT ON FUNCTION ops.tg_template_status_by_carrier IS 'A carrier pauses and resumes its regular trips; it ends one through a stop request (1117)';

-- ------------------------------------------------------------------ permissions
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('schedule.approve', 'ops', 'PLATFORM', 'Decide carriers'' requests for regular trips at the platform''s stages (an authority''s members decide its stages by membership)', true),
  ('schedule.settings', 'ops', 'PLATFORM', 'Set the approval stages and rules of regular trips, and the members of government authorities', true)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, p.code FROM iam.role r, (VALUES ('schedule.approve'), ('schedule.settings')) p (code)
 WHERE r.code = 'PLATFORM_ADMIN' AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ops.schedule_request', '1A', 'E08'), ('ops.schedule_approval', '1A', 'E08'), ('sec.authority_member', '1B', 'E24')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('ops.schedule_request', 'TENANT_PRIVATE', 'company_id', 'carriers'' requests for regular trips (1117)'),
  ('ops.schedule_approval', 'TENANT_PRIVATE', 'request_id -> ops.schedule_request.company_id', 'the decisions on those requests (1117)'),
  ('sec.authority_member', 'PLATFORM_CONFIDENTIAL', NULL, 'the staff accounts of government authorities (1117)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ops.schedule_request', 'ops records', 'requests for regular trips (1117)'),
  ('ops.schedule_approval', 'ops records', 'decisions on requests for regular trips (1117)'),
  ('sec.authority_member', 'sec records', 'members of government authorities (1117)')
ON CONFLICT (table_name) DO NOTHING;
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('ops.schedule_request', 'proposal', 'SHAPE', 1, '{"type": "object"}'::jsonb,
   'what is asked: a regular trip''s route, time, pattern, period, price, type, direction and publishing, or what a change changes (1117)'),
  ('ops.schedule_request', 'approval_stages', 'SNAPSHOT', 1, '{"type": "array"}'::jsonb,
   'the approval stages in force when the request was made (1117)'),
  ('ops.schedule_request', 'result', 'SNAPSHOT', 1, '{"type": "object"}'::jsonb,
   'what applying the request did (1117)'),
  ('ops.schedule_approval', 'stage', 'SNAPSHOT', 1, '{"type": "object", "required": ["by"]}'::jsonb,
   'the stage decided: the platform or an authority by its code (1117)'),
  ('ops.trip_template', 'last_run', 'PAYLOAD', 1, NULL,
   'what the last making of trips did: when, how many, the days skipped with why (1117)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();

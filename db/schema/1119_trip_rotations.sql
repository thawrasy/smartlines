-- =====================================================================
-- Masslak - 1119: four-digit trip numbers and the legs of a vehicle's day (owner's decision, October 2026)
--   * Trip numbers have four digits, as airlines print them (DC 1201). The first digit is the block of the trip type:
--     scheduled 1000-4999, international 5000-5999, shuttle 6000-6999, cargo 7000-7999, extra 8000-8999; 9000-9999
--     are kept for later (replacement and positioning runs). The numbers given so far move into their block with the
--     same parity (scheduled +1000, international, shuttle and cargo +4000, extra into 8000-8999); trips ahead that
--     nobody booked take the new number, trips with bookings keep the number printed on their tickets.
--   * The direction is on the last digit: an outbound trip takes an odd number, its return the even number after it.
--   * The day of a vehicle is a line of legs under one prefix: the first three digits name the line, the last the leg,
--     1 to 8, odd away from the carrier's home and even back. DC 1201 Damascus 07:00 to Aleppo returns as DC 1202 at
--     15:00; a vehicle on a short line runs 1211, 1212, 1213, 1214. A number continues the leg before it on the same
--     vehicle (net.service_number.follows_id): the carrier's number one lower, in the same block. The carrier decides:
--     a regular trip may continue a leg of its own (the request names it, the number follows), or stand alone and
--     start a line of its own (the platform suggests a line whose eight numbers are free).
--   * A leg that continues another leaves from the city where the other arrives, runs on the same vehicle, on days the
--     other runs, and leaves at least schedule.min_turnaround_min after it arrives, on the same day. A change to
--     either leg is checked against the other.
--   * Passengers see the return on the same vehicle (ops.trip_return): the trip that continues theirs on the same day,
--     with a note that the vehicle is the one planned; a vehicle replaced on the day keeps the numbers.
-- =====================================================================

-- ------------------------------------------------------------------ the setting
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('schedule.min_turnaround_min', '30'::jsonb, 'PLATFORM',
   'The fewest minutes between a vehicle''s arrival and its next leg, 0 to 600 (1119)')
ON CONFLICT (key) DO NOTHING;

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
  ELSIF p_key IN ('schedule.min_notice_days', 'schedule.horizon_days', 'schedule.min_turnaround_min') THEN
    IF NOT (CASE WHEN jsonb_typeof(p_value) = 'number' AND (p_value #>> '{}') ~ '^[0-9]{1,3}$'
                 THEN (p_value #>> '{}')::integer BETWEEN (CASE p_key WHEN 'schedule.horizon_days' THEN 7 ELSE 0 END)
                                                      AND (CASE p_key WHEN 'schedule.horizon_days' THEN 120
                                                                      WHEN 'schedule.min_turnaround_min' THEN 600 ELSE 90 END)
                 ELSE false END) THEN
      RETURN CASE p_key WHEN 'schedule.horizon_days' THEN 'trips are made 7 to 120 days ahead'
                        WHEN 'schedule.min_turnaround_min' THEN 'the turnaround is 0 to 600 minutes'
                        ELSE 'the notice is 0 to 90 days' END;
    END IF;
  ELSE
    RETURN format('%s is not a setting of regular trips', p_key);
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION ops.schedule_setting(p_key text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT s.value FROM sys.setting s WHERE s.key = p_key AND ops.schedule_setting_problem(p_key, s.value) IS NULL),
                  CASE p_key WHEN 'schedule.approval_stages' THEN '[{"by":"PLATFORM"}]'::jsonb
                             WHEN 'schedule.approval_kinds' THEN '["NEW","CHANGE"]'::jsonb
                             WHEN 'schedule.min_notice_days' THEN '0'::jsonb
                             WHEN 'schedule.horizon_days' THEN '30'::jsonb
                             WHEN 'schedule.recurrences' THEN '["DAILY","WEEKLY","MONTHLY"]'::jsonb
                             WHEN 'schedule.min_turnaround_min' THEN '30'::jsonb END)
$$;

-- ------------------------------------------------------------------ four digits: the numbers given so far move
ALTER TABLE net.service_number DROP CONSTRAINT IF EXISTS service_number_check;
ALTER TABLE net.service_number DROP CONSTRAINT IF EXISTS service_number_number_check;
DO $$
DECLARE r record; v_new integer;
BEGIN
  -- out of the way first, so that no number meets another on its way; the shifts are even, so the parity stays
  UPDATE net.service_number SET number = number + 100000 WHERE number < 100000;
  UPDATE net.service_number SET number = number - 100000 + CASE block WHEN 'SCHEDULED' THEN 1000 ELSE 4000 END
   WHERE block IN ('SCHEDULED', 'INTL', 'SHUTTLE', 'CARGO') AND number >= 100000;
  FOR r IN SELECT id, company_id, valid FROM net.service_number WHERE block = 'EXTRA' AND number >= 100000 ORDER BY number, id LOOP
    SELECT n INTO v_new FROM generate_series(8000, 8999) n
     WHERE NOT EXISTS (SELECT 1 FROM net.service_number s WHERE s.company_id = r.company_id AND s.number = n AND s.valid && r.valid)
     ORDER BY n LIMIT 1;
    IF v_new IS NULL THEN
      RAISE EXCEPTION 'no extra number is free for service number %', r.id;
    END IF;
    UPDATE net.service_number SET number = v_new WHERE id = r.id;
  END LOOP;
END $$;
ALTER TABLE net.service_number ADD CONSTRAINT service_number_number_check CHECK (number BETWEEN 1000 AND 9999);
ALTER TABLE net.service_number ADD CONSTRAINT service_number_block_range CHECK (
  (block = 'SCHEDULED' AND number BETWEEN 1000 AND 4999) OR
  (block = 'INTL'      AND number BETWEEN 5000 AND 5999) OR
  (block = 'SHUTTLE'   AND number BETWEEN 6000 AND 6999) OR
  (block = 'CARGO'     AND number BETWEEN 7000 AND 7999) OR
  (block = 'EXTRA'     AND number BETWEEN 8000 AND 8999));
COMMENT ON TABLE net.service_number IS 'A carrier''s trip number from its type block, four digits, odd outbound and even return; never repeated for a carrier in an overlapping period; may continue the leg before it on the same vehicle (1119)';

-- a number a waiting request asked for that has no place now: the platform gives one when it approves
UPDATE ops.schedule_request SET proposed_number = NULL WHERE status = 'PENDING' AND proposed_number < 1000;
UPDATE ops.schedule_request SET assigned_number = NULL WHERE status = 'PENDING' AND assigned_number < 1000;

-- trips ahead that nobody booked take the new number; trips with bookings keep the number printed on their tickets
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT t.id, t.company_id, t.service_date, t.section_suffix::text AS suffix, s.number
             FROM ops.trip t JOIN net.service_number s ON s.id = t.service_number_id
            WHERE t.service_no IS DISTINCT FROM s.number AND t.status NOT IN ('CANCELLED', 'COMPLETED')
              AND t.service_date >= (now() AT TIME ZONE ref.company_tz(t.company_id))::date
              AND NOT EXISTS (SELECT 1 FROM sales.booking b WHERE b.trip_id = t.id AND b.status IN ('PENDING_PAYMENT', 'CONFIRMED'))
            ORDER BY t.service_date, t.departure_at, t.id LOOP
    IF ops.trip_number_free(r.company_id, r.service_date, r.number, r.suffix, r.id) THEN
      UPDATE ops.trip SET service_no = r.number,
                          trip_code = coalesce((SELECT d || ' ' || r.number || coalesce(r.suffix, '') FROM ops.trip_designator(r.company_id) d
                                                 WHERE d IS NOT NULL), trip_code)
       WHERE id = r.id;
    END IF;
  END LOOP;
END $$;

-- ------------------------------------------------------------------ the legs of a vehicle's day
ALTER TABLE net.service_number ADD COLUMN IF NOT EXISTS follows_id bigint REFERENCES net.service_number(id);
CREATE INDEX IF NOT EXISTS service_number_follows_id_fkx ON net.service_number (follows_id);
COMMENT ON COLUMN net.service_number.follows_id IS 'The leg the same vehicle runs just before this one: the carrier''s number one lower, in the same block; DC 1202 continues DC 1201 (1119)';

CREATE OR REPLACE FUNCTION net.tg_service_number_follows() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE f net.service_number;
BEGIN
  IF NEW.follows_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT * INTO f FROM net.service_number WHERE id = NEW.follows_id;
  IF f.company_id IS DISTINCT FROM NEW.company_id OR NEW.number <> f.number + 1 OR f.number % 10 NOT BETWEEN 1 AND 7
     OR f.block <> NEW.block OR NEW.block = 'EXTRA' THEN
    RAISE EXCEPTION 'ROTATION_INVALID: a number continues the carrier''s number one lower, ending in 1 to 7, in the same block'
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.route_id IS NOT NULL AND f.route_id IS NOT NULL
     AND (SELECT s.city_id FROM net.route r JOIN net.station s ON s.id = r.dest_station_id WHERE r.id = f.route_id)
         IS DISTINCT FROM (SELECT s.city_id FROM net.route r JOIN net.station s ON s.id = r.origin_station_id WHERE r.id = NEW.route_id) THEN
    RAISE EXCEPTION 'ROTATION_INVALID: the next leg leaves from the city where the leg before it arrives' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS service_number_follows ON net.service_number;
CREATE TRIGGER service_number_follows BEFORE INSERT OR UPDATE OF follows_id, number, route_id ON net.service_number
  FOR EACH ROW EXECUTE FUNCTION net.tg_service_number_follows();

-- ------------------------------------------------------------------ numbers
CREATE OR REPLACE FUNCTION ops.block_range(p_block text) RETURNS int4range
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE p_block WHEN 'SCHEDULED' THEN int4range(1000, 5000) WHEN 'INTL' THEN int4range(5000, 6000)
                      WHEN 'SHUTTLE' THEN int4range(6000, 7000) WHEN 'CARGO' THEN int4range(7000, 8000)
                      WHEN 'EXTRA' THEN int4range(8000, 9000) END
$$;

CREATE OR REPLACE FUNCTION ops.number_problem(p_block text, p_direction text, p_number integer) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE
    WHEN p_number IS NULL THEN NULL
    WHEN NOT ops.block_range(p_block) @> p_number
      THEN format('NUMBER_NOT_IN_BLOCK: the %s numbers are %s to %s', lower(p_block), lower(ops.block_range(p_block)),
                  upper(ops.block_range(p_block)) - 1)
    WHEN p_block <> 'EXTRA' AND (p_direction = 'OUTBOUND') <> (p_number % 2 = 1)
      THEN 'NUMBER_PARITY: an outbound trip takes an odd number, its return an even one'
  END
$$;

-- the number the platform suggests for a regular trip that stands alone: the first leg of a line whose eight numbers
-- are free (leg 1 outbound, leg 2 for a return on its own), so that its next legs can follow it; an extra trip takes
-- the lowest free extra number
CREATE OR REPLACE FUNCTION ops.suggest_schedule_number(p_company bigint, p_trip_type text, p_direction text, p_period daterange,
                                                       p_route bigint) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN ops.number_block(p_trip_type) = 'EXTRA' THEN
           (SELECT n FROM generate_series(8000, 8999) n WHERE ops.schedule_number_free(p_company, n, p_period, p_route) ORDER BY n LIMIT 1)
         ELSE
           (SELECT x * 10 + CASE WHEN p_direction = 'OUTBOUND' THEN 1 ELSE 2 END
              FROM generate_series(lower(ops.block_range(ops.number_block(p_trip_type))) / 10,
                                   upper(ops.block_range(ops.number_block(p_trip_type))) / 10 - 1) x
             WHERE NOT EXISTS (SELECT 1 FROM generate_series(1, 8) l
                                WHERE NOT ops.schedule_number_free(p_company, x * 10 + l, p_period, NULL))
             ORDER BY x LIMIT 1)
         END
$$;

-- a trip made by hand without a number: the extra number of its route and time on the nearest other day, else the
-- lowest free extra number that is not one of the carrier's service numbers that day (1114, extra block of 1119)
CREATE OR REPLACE FUNCTION ops.pick_service_no(p_company bigint, p_route bigint, p_departure timestamptz, p_day date,
                                               p_suffix text, p_trip bigint) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tz text; v_no integer;
BEGIN
  v_tz := coalesce(ref.station_tz((SELECT r.origin_station_id FROM net.route r WHERE r.id = p_route)), 'UTC');
  SELECT t.service_no INTO v_no FROM ops.trip t
   WHERE t.company_id = p_company AND t.route_id = p_route AND t.service_no BETWEEN 8000 AND 8999 AND t.status <> 'CANCELLED'
     AND t.service_date BETWEEN p_day - 60 AND p_day + 60 AND t.service_date <> p_day
     AND (t.departure_at AT TIME ZONE v_tz)::time = (p_departure AT TIME ZONE v_tz)::time
     AND ops.trip_number_free(p_company, p_day, t.service_no, p_suffix, p_trip)
     AND NOT EXISTS (SELECT 1 FROM net.service_number s WHERE s.company_id = p_company AND s.number = t.service_no AND s.valid @> p_day)
   ORDER BY abs(t.service_date - p_day), t.service_date DESC LIMIT 1;
  IF v_no IS NOT NULL THEN
    RETURN v_no;
  END IF;
  SELECT n INTO v_no FROM generate_series(8000, 8999) n
   WHERE ops.trip_number_free(p_company, p_day, n, p_suffix, p_trip)
     AND NOT EXISTS (SELECT 1 FROM net.service_number s WHERE s.company_id = p_company AND s.number = n AND s.valid @> p_day)
   ORDER BY n LIMIT 1;
  RETURN v_no;
END $$;

-- ------------------------------------------------------------------ one leg after another
-- what is wrong with a leg that continues another, both as proposals of regular trips, or NULL
CREATE OR REPLACE FUNCTION ops.leg_problem(p_before jsonb, p_next jsonb, p_before_no integer) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_arrives bigint; v_leaves bigint; v_minutes integer; v_turn integer; v_ready integer;
        v_bw smallint[]; v_nw smallint[]; v_bm smallint[]; v_nm smallint[];
BEGIN
  SELECT s.city_id INTO v_arrives FROM net.route r JOIN net.station s ON s.id = r.dest_station_id WHERE r.id = (p_before ->> 'route_id')::bigint;
  SELECT s.city_id INTO v_leaves FROM net.route r JOIN net.station s ON s.id = r.origin_station_id WHERE r.id = (p_next ->> 'route_id')::bigint;
  IF v_arrives IS DISTINCT FROM v_leaves THEN
    RETURN format('the leg after %s leaves from the city where %s arrives', p_before_no, p_before_no);
  END IF;
  IF p_before ->> 'vehicle_id' IS NOT NULL AND p_next ->> 'vehicle_id' IS NOT NULL AND p_before ->> 'vehicle_id' <> p_next ->> 'vehicle_id' THEN
    RETURN format('the leg after %s runs on the same vehicle', p_before_no);
  END IF;
  v_bw := ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(coalesce(p_before -> 'days_of_week', '[]'::jsonb)) x);
  v_nw := ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(coalesce(p_next -> 'days_of_week', '[]'::jsonb)) x);
  v_bm := ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(coalesce(p_before -> 'days_of_month', '[]'::jsonb)) x);
  v_nm := ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(coalesce(p_next -> 'days_of_month', '[]'::jsonb)) x);
  IF NOT (p_before ->> 'recurrence' = 'DAILY'
          OR (p_before ->> 'recurrence' = 'WEEKLY' AND p_next ->> 'recurrence' = 'WEEKLY' AND v_nw <@ v_bw)
          OR (p_before ->> 'recurrence' = 'MONTHLY' AND p_next ->> 'recurrence' = 'MONTHLY' AND v_nm <@ v_bm)) THEN
    RETURN format('the leg after %s runs only on days %s runs', p_before_no, p_before_no);
  END IF;
  SELECT coalesce(max(rs.arr_offset_min), max(r.std_duration_min), 0) INTO v_minutes
    FROM net.route r LEFT JOIN net.route_stop rs ON rs.route_id = r.id WHERE r.id = (p_before ->> 'route_id')::bigint;
  v_turn := (ops.schedule_setting('schedule.min_turnaround_min') #>> '{}')::integer;
  v_ready := (extract(epoch FROM (p_before ->> 'departure_time')::time) / 60)::integer + v_minutes + v_turn;
  IF v_ready > (extract(epoch FROM (p_next ->> 'departure_time')::time) / 60)::integer THEN
    RETURN format('the leg after %s leaves at least %s minutes after %s arrives, on the same day', p_before_no, v_turn, p_before_no);
  END IF;
  RETURN NULL;
END $$;

-- a regular trip that continues a leg (its proposal names the number it follows): checked against every version of
-- that leg in its period; a new one needs that leg to run, a change of one whose leg before has stopped stands alone
CREATE OR REPLACE FUNCTION ops.rotation_problem(p_company bigint, p jsonb, p_require boolean DEFAULT true) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_after integer; v_problem text; v_found boolean := false; v_template bigint;
BEGIN
  IF p ->> 'follows' IS NULL THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p -> 'follows') <> 'number' OR (p ->> 'follows') !~ '^[1-8][0-9]{3}$' THEN
    RETURN 'the leg continued is one of the carrier''s four-digit numbers';
  END IF;
  v_after := (p ->> 'follows')::integer;
  IF v_after % 10 NOT BETWEEN 1 AND 7 THEN
    RETURN 'a vehicle''s day has at most eight legs: the number continued ends in 1 to 7';
  END IF;
  IF NOT ops.block_range(ops.number_block(p ->> 'trip_type')) @> (v_after + 1) OR ops.number_block(p ->> 'trip_type') = 'EXTRA' THEN
    RETURN format('the leg after %s is of the same kind of trip, its number in the same block', v_after);
  END IF;
  FOR v_template IN SELECT t.id FROM ops.trip_template t JOIN net.service_number s ON s.id = t.service_number_id
                     WHERE t.company_id = p_company AND s.number = v_after AND t.status <> 'RETIRED' AND NOT isempty(t.active)
                       AND t.active && daterange((p ->> 'from')::date, (p ->> 'until')::date + 1) LOOP
    v_found := true;
    v_problem := ops.leg_problem(ops.template_as_proposal(v_template), p, v_after);
    IF v_problem IS NOT NULL THEN
      RETURN v_problem;
    END IF;
  END LOOP;
  IF NOT v_found AND p_require THEN
    RETURN format('no regular trip of the carrier runs under %s in this period', v_after);
  END IF;
  RETURN NULL;
END $$;

-- a new version of a leg (p, under the service number p_number_id): the legs that continue it still fit
CREATE OR REPLACE FUNCTION ops.followers_problem(p_number_id bigint, p jsonb) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE f record; v_problem text;
BEGIN
  IF p_number_id IS NULL THEN
    RETURN NULL;
  END IF;
  FOR f IN SELECT t.id, s.number FROM net.service_number s JOIN ops.trip_template t ON t.service_number_id = s.id
            WHERE s.follows_id = p_number_id AND t.status <> 'RETIRED' AND NOT isempty(t.active)
              AND t.active && daterange((p ->> 'from')::date, (p ->> 'until')::date + 1) LOOP
    v_problem := ops.leg_problem(p, ops.template_as_proposal(f.id), f.number - 1);
    IF v_problem IS NOT NULL THEN
      RETURN v_problem;
    END IF;
  END LOOP;
  RETURN NULL;
END $$;

-- ------------------------------------------------------------------ requests that name the leg they continue
CREATE OR REPLACE FUNCTION ops.schedule_proposal_problem(p_company bigint, p jsonb) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k text; v_from date; v_until date;
BEGIN
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k NOT IN ('route_id', 'vehicle_id', 'departure_time', 'recurrence', 'days_of_week', 'days_of_month', 'skip_dates',
                 'from', 'until', 'base_price', 'currency', 'trip_type', 'direction', 'auto_publish', 'follows') THEN
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
  IF p ? 'follows' AND p ->> 'follows' IS NOT NULL AND (jsonb_typeof(p -> 'follows') <> 'number' OR (p ->> 'follows') !~ '^[0-9]{4}$') THEN
    RETURN 'the leg continued is one of the carrier''s four-digit numbers';
  END IF;
  RETURN NULL;
END $$;

-- a regular trip as a proposal, with the leg it continues
CREATE OR REPLACE FUNCTION ops.template_as_proposal(p_template_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
           'route_id', t.route_id, 'vehicle_id', t.default_vehicle_id, 'departure_time', to_char(t.departure_time, 'HH24:MI'),
           'recurrence', t.recurrence, 'days_of_week', to_jsonb(t.days_of_week), 'days_of_month', to_jsonb(t.days_of_month),
           'skip_dates', to_jsonb(t.skip_dates), 'from', lower(t.active), 'until', upper(t.active) - 1,
           'base_price', t.base_price, 'currency', t.currency, 'trip_type', t.trip_type,
           'direction', coalesce(s.direction, 'OUTBOUND'), 'auto_publish', t.auto_publish)
         || CASE WHEN fs.number IS NOT NULL THEN jsonb_build_object('follows', fs.number) ELSE '{}'::jsonb END
    FROM ops.trip_template t LEFT JOIN net.service_number s ON s.id = t.service_number_id
    LEFT JOIN net.service_number fs ON fs.id = s.follows_id
   WHERE t.id = p_template_id
$$;

-- the service number of a regular trip for its period: the carrier's own on the same route, else a new one; a leg
-- that continues another is linked to it
CREATE OR REPLACE FUNCTION ops.take_schedule_number(p_company bigint, p_number integer, p_proposal jsonb, p_period daterange,
                                                    p_keep bigint DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_block text := ops.number_block(p_proposal ->> 'trip_type'); v_problem text; v_id bigint; v_follows bigint; v_has bigint;
        v_route bigint := (p_proposal ->> 'route_id')::bigint;
BEGIN
  v_problem := ops.number_problem(v_block, p_proposal ->> 'direction', p_number);
  IF v_problem IS NOT NULL THEN
    RAISE EXCEPTION '%', v_problem USING ERRCODE = 'P0001';
  END IF;
  IF NOT ops.schedule_number_free(p_company, p_number, p_period, v_route, p_keep) THEN
    RAISE EXCEPTION 'SERVICE_NUMBER_TAKEN: the carrier''s number % is taken in this period', p_number USING ERRCODE = 'P0001';
  END IF;
  IF p_proposal ->> 'follows' IS NOT NULL THEN
    SELECT s.id INTO v_follows FROM net.service_number s
     WHERE s.company_id = p_company AND s.number = (p_proposal ->> 'follows')::integer AND s.valid && p_period ORDER BY s.id LIMIT 1;
  END IF;
  SELECT s.id, s.follows_id INTO v_id, v_has FROM net.service_number s
   WHERE s.company_id = p_company AND s.number = p_number AND s.valid && p_period ORDER BY s.id LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO net.service_number (company_id, number, block, route_id, direction, valid, follows_id)
    VALUES (p_company, p_number, v_block, v_route, p_proposal ->> 'direction', p_period, v_follows) RETURNING id INTO v_id;
  ELSE
    IF v_follows IS NOT NULL AND v_has IS NOT NULL AND v_has <> v_follows THEN
      RAISE EXCEPTION 'ROTATION_INVALID: the number % already continues another leg', p_number USING ERRCODE = 'P0001';
    END IF;
    BEGIN
      UPDATE net.service_number SET valid = valid + p_period, route_id = coalesce(route_id, v_route),
                                    follows_id = coalesce(follows_id, v_follows)
       WHERE id = v_id;
    EXCEPTION WHEN data_exception OR exclusion_violation THEN
      RAISE EXCEPTION 'SERVICE_NUMBER_TAKEN: the carrier''s number % is taken in another period that touches this one', p_number
        USING ERRCODE = 'P0001';
    END;
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION ops.apply_schedule_request(p_request_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r ops.schedule_request; t ops.trip_template; v_merged jsonb; v_number integer; v_number_id bigint; v_new bigint;
        v_released jsonb; v_period daterange; v_problem text;
BEGIN
  SELECT * INTO r FROM ops.schedule_request WHERE id = p_request_id FOR UPDATE;
  IF r.kind = 'NEW' THEN
    v_period := daterange((r.proposal ->> 'from')::date, (r.proposal ->> 'until')::date + 1);
    v_problem := ops.rotation_problem(r.company_id, r.proposal);     -- the leg it continues may have changed meanwhile
    IF v_problem IS NOT NULL THEN
      RAISE EXCEPTION 'ROTATION_INVALID: %', v_problem USING ERRCODE = 'P0001';
    END IF;
    v_number := CASE WHEN r.proposal ->> 'follows' IS NOT NULL THEN (r.proposal ->> 'follows')::integer + 1
                     ELSE coalesce(r.assigned_number, r.proposed_number,
                                   ops.suggest_schedule_number(r.company_id, r.proposal ->> 'trip_type', r.proposal ->> 'direction', v_period,
                                                               (r.proposal ->> 'route_id')::bigint)) END;
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
    IF r.kind = 'CHANGE' THEN                              -- the new version, checked with the legs before and after it
      v_merged := ops.template_as_proposal(t.id) - 'from' - 'until'
                  || jsonb_build_object('from', r.effective_from, 'until', upper(t.active) - 1) || r.proposal;
      v_problem := coalesce(ops.rotation_problem(t.company_id, v_merged, false), ops.followers_problem(t.service_number_id, v_merged));
      IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION 'ROTATION_INVALID: %', v_problem USING ERRCODE = 'P0001';
      END IF;
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

CREATE OR REPLACE FUNCTION ops.request_schedule(p_kind text, p_template_uid uuid, p_trip_uid uuid, p_proposal jsonb,
                                                p_effective_from date, p_proposed_number integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_company bigint := sys.ctx_company_id(); t ops.trip_template; v_trip ops.trip; v_problem text; v_day date;
        v_proposal jsonb := coalesce(p_proposal, '{}'::jsonb); v_id bigint; v_needs boolean; v_result jsonb; v_merged jsonb;
        v_number integer := p_proposed_number;
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
      IF v_proposal = '{}'::jsonb OR v_proposal ? 'from' OR v_proposal ? 'route_id' OR v_proposal ? 'trip_type' OR v_proposal ? 'currency'
         OR v_proposal ? 'follows' OR v_proposal ? 'direction' THEN
        RAISE EXCEPTION 'SCHEDULE_INVALID: a change names what changes: time, days, dates without the trip, end, vehicle, price or publishing'
          USING ERRCODE = 'P0001';
      END IF;
      v_merged := ops.template_as_proposal(t.id) - 'from' - 'until'
                  || jsonb_build_object('from', p_effective_from, 'until', upper(t.active) - 1) || v_proposal;
      v_problem := ops.schedule_proposal_problem(v_company, v_merged);
      IF v_problem IS NULL THEN                          -- the legs before and after it still fit
        v_problem := coalesce(ops.rotation_problem(v_company, v_merged, false), ops.followers_problem(t.service_number_id, v_merged));
        IF v_problem IS NOT NULL THEN
          RAISE EXCEPTION 'ROTATION_INVALID: %', v_problem USING ERRCODE = 'P0001';
        END IF;
      END IF;
    END IF;
  ELSIF p_kind = 'NEW' THEN
    v_proposal := jsonb_build_object('days_of_week', '[]'::jsonb, 'days_of_month', '[]'::jsonb, 'skip_dates', '[]'::jsonb,
                                     'trip_type', 'SCHEDULED', 'direction', 'OUTBOUND', 'auto_publish', true) || v_proposal;
    IF jsonb_typeof(v_proposal -> 'follows') = 'null' THEN
      v_proposal := v_proposal - 'follows';
    END IF;
    IF jsonb_typeof(v_proposal -> 'follows') = 'number' AND (v_proposal ->> 'follows') ~ '^[0-9]{4}$' THEN
      -- the leg after another takes the number after it, and its direction from that number
      v_number := (v_proposal ->> 'follows')::integer + 1;
      v_proposal := v_proposal || jsonb_build_object('direction', CASE WHEN v_number % 2 = 1 THEN 'OUTBOUND' ELSE 'INBOUND' END);
    END IF;
    v_problem := ops.schedule_proposal_problem(v_company, v_proposal);
    v_day := (v_proposal ->> 'from')::date;
    IF v_problem IS NULL AND v_number IS NOT NULL THEN
      v_problem := ops.number_problem(ops.number_block(v_proposal ->> 'trip_type'), v_proposal ->> 'direction', v_number);
    END IF;
    IF v_problem IS NULL THEN
      v_problem := ops.rotation_problem(v_company, v_proposal);
      IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION 'ROTATION_INVALID: %', v_problem USING ERRCODE = 'P0001';
      END IF;
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
            CASE WHEN p_kind = 'NEW' THEN v_number END, nullif(btrim(p_note), ''),
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

-- the number a waiting request would take: the one after the leg it continues, the one given or asked for, or the
-- platform's suggestion
CREATE OR REPLACE FUNCTION ops.request_number(p_request_id bigint) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN r.kind <> 'NEW' THEN NULL
              WHEN r.proposal ->> 'follows' IS NOT NULL THEN (r.proposal ->> 'follows')::integer + 1
              ELSE coalesce(r.assigned_number, r.proposed_number,
                            ops.suggest_schedule_number(r.company_id, r.proposal ->> 'trip_type', r.proposal ->> 'direction',
                                                        daterange((r.proposal ->> 'from')::date, (r.proposal ->> 'until')::date + 1),
                                                        (r.proposal ->> 'route_id')::bigint)) END
    FROM ops.schedule_request r WHERE r.id = p_request_id
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
    IF v_proposal ->> 'follows' IS NOT NULL AND p_number <> (v_proposal ->> 'follows')::integer + 1 THEN
      RAISE EXCEPTION 'ROTATION_INVALID: the leg after % takes the number %', v_proposal ->> 'follows', (v_proposal ->> 'follows')::integer + 1
        USING ERRCODE = 'P0001';
    END IF;
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

-- ------------------------------------------------------------------ the return on the same vehicle
-- the trip that continues an outbound trip on its day (its number odd, the next one following it), with whether the
-- vehicles planned for both are known to be the same; only trips on sale
CREATE OR REPLACE FUNCTION ops.trip_return(p_trip bigint) RETURNS TABLE (trip_id bigint, same_vehicle boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT r.id, CASE WHEN t.vehicle_id IS NULL OR r.vehicle_id IS NULL THEN NULL ELSE t.vehicle_id = r.vehicle_id END
    FROM ops.trip t
    JOIN net.service_number sn ON sn.id = t.service_number_id AND sn.number % 2 = 1
    JOIN net.service_number rn ON rn.follows_id = sn.id
    JOIN ops.trip r ON r.service_number_id = rn.id AND r.company_id = t.company_id AND r.service_date = t.service_date
                   AND r.status IN ('PUBLISHED', 'BOARDING') AND r.departure_at >= t.arrival_at
   WHERE t.id = p_trip
   ORDER BY r.departure_at LIMIT 1
$$;

-- ------------------------------------------------------------------ privileges
REVOKE ALL ON FUNCTION net.tg_service_number_follows() FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.leg_problem(jsonb, jsonb, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.rotation_problem(bigint, jsonb, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.followers_problem(bigint, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.request_number(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.trip_return(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.pick_service_no(bigint, bigint, timestamptz, date, text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.block_range(text), ops.request_number(bigint), ops.trip_return(bigint) TO masslak_app;
GRANT EXECUTE ON FUNCTION ops.trip_return(bigint) TO masslak_readonly;
COMMENT ON FUNCTION ops.trip_return(bigint) IS 'The trip that continues an outbound trip on the same vehicle on its day, and whether the planned vehicles are known to match (1119)';
COMMENT ON FUNCTION ops.leg_problem(jsonb, jsonb, integer) IS 'What is wrong with a leg that continues another: the city, the vehicle, the days, the turnaround (1119)';

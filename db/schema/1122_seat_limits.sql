-- =====================================================================
-- 1122  Seats booked at once: a platform setting, more for a family (owner's decision, October 2026)
-- =====================================================================
-- A traveller books up to four seats at once (approved as the default). The number is the platform's to raise or lower,
-- as a regulator may require; a family head books up to the number of the family's members when the family is larger,
-- within a ceiling the platform sets too. A tourism company books a group of up to agency.group.max_passengers (1121),
-- in bookings of booking.max_seats each. The server reads the limit here (sales.seat_limit) wherever seats are held or
-- booked; only the platform changes it (sales.set_seat_limits), naming the decision behind a change.

INSERT INTO sys.setting (key, value, description) VALUES
  ('booking.max_seats', '4'::jsonb, 'Seats one booking holds, and a traveller books at once; the platform sets it, as regulators may require (1122)'),
  ('booking.family.max_seats', '10'::jsonb, 'Seats a family head books at once: up to the family''s active members, at most this (1122)'),
  ('booking.limits.basis', '{}'::jsonb, 'The decision behind the seat limits as last set, and who set them (1122)')
ON CONFLICT (key) DO NOTHING;

-- a whole number from a setting, or the default when it is missing or not a number
CREATE OR REPLACE FUNCTION sales.setting_int(p_key text, p_default int) RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT CASE WHEN jsonb_typeof(value) = 'number' THEN (value #>> '{}')::numeric::int END
                     FROM sys.setting WHERE key = p_key), p_default)
$$;
REVOKE ALL ON FUNCTION sales.setting_int(text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.setting_int(text, int) TO masslak_app;
COMMENT ON FUNCTION sales.setting_int IS 'A whole-number setting, or the default when it is missing or not a number (1122)';

-- the seats a party books at once: the platform's number, or its family's size when it heads a larger family
CREATE OR REPLACE FUNCTION sales.seat_limit(p_party_id bigint) RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT greatest(sales.setting_int('booking.max_seats', 4),
                  least(sales.setting_int('booking.family.max_seats', 10),
                        coalesce((SELECT count(*)::int FROM iam.family f
                                    JOIN iam.family_member m ON m.family_id = f.id AND m.status = 'ACTIVE'
                                   WHERE f.head_party_id = p_party_id AND f.status = 'ACTIVE'), 0)))
$$;
REVOKE ALL ON FUNCTION sales.seat_limit(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.seat_limit(bigint) TO masslak_app;
COMMENT ON FUNCTION sales.seat_limit IS 'Seats a party books at once: booking.max_seats, or the size of the family it heads up to booking.family.max_seats (1122)';

-- the platform changes the three numbers together, naming the decision (a regulator's or its own)
CREATE OR REPLACE FUNCTION sales.set_seat_limits(p_max_seats int, p_family_max_seats int, p_agency_group int, p_basis text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the seat limits are a platform setting' USING ERRCODE = 'P0001';
  END IF;
  IF p_max_seats IS NULL OR p_max_seats NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'INVALID_SETTING: a booking holds 1 to 20 seats' USING ERRCODE = 'P0001';
  END IF;
  IF p_family_max_seats IS NULL OR p_family_max_seats NOT BETWEEN p_max_seats AND 20 THEN
    RAISE EXCEPTION 'INVALID_SETTING: a family books at least as many seats as anyone, and at most 20' USING ERRCODE = 'P0001';
  END IF;
  IF p_agency_group IS NULL OR p_agency_group NOT BETWEEN p_max_seats AND 60 THEN
    RAISE EXCEPTION 'INVALID_SETTING: an agency''s group is at least one booking and at most 60 travellers' USING ERRCODE = 'P0001';
  END IF;
  IF length(btrim(coalesce(p_basis, ''))) NOT BETWEEN 3 AND 160 THEN
    RAISE EXCEPTION 'INVALID_SETTING: name the decision behind the change (a regulator''s or the platform''s)' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at) VALUES
    ('booking.max_seats', to_jsonb(p_max_seats), 'PLATFORM', 'Seats one booking holds, and a traveller books at once; the platform sets it, as regulators may require (1122)', sys.ctx_user_id(), now()),
    ('booking.family.max_seats', to_jsonb(p_family_max_seats), 'PLATFORM', 'Seats a family head books at once: up to the family''s active members, at most this (1122)', sys.ctx_user_id(), now()),
    ('agency.group.max_passengers', to_jsonb(p_agency_group), 'PLATFORM', 'Travellers an agency books as one group on each leg of a journey (1121)', sys.ctx_user_id(), now()),
    ('booking.limits.basis', jsonb_build_object('basis', btrim(p_basis), 'set_at', now(), 'set_by', sys.ctx_user_id()), 'PLATFORM',
     'The decision behind the seat limits as last set, and who set them (1122)', sys.ctx_user_id(), now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  v := sales.seat_limits();
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION sales.set_seat_limits(int, int, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.set_seat_limits(int, int, int, text) TO masslak_app;
COMMENT ON FUNCTION sales.set_seat_limits IS 'Sets the seats of a booking, of a family and of an agency''s group, with the decision behind them; platform only (1122)';

-- the numbers as they stand, for the screens
CREATE OR REPLACE FUNCTION sales.seat_limits() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
    'max_seats', sales.setting_int('booking.max_seats', 4),
    'family_max_seats', sales.setting_int('booking.family.max_seats', 10),
    'agency_group', sales.setting_int('agency.group.max_passengers', 50),
    'basis', (SELECT value -> 'basis' FROM sys.setting WHERE key = 'booking.limits.basis'),
    'set_at', (SELECT value -> 'set_at' FROM sys.setting WHERE key = 'booking.limits.basis'))
$$;
REVOKE ALL ON FUNCTION sales.seat_limits() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.seat_limits() TO masslak_app;
COMMENT ON FUNCTION sales.seat_limits IS 'The seat limits as they stand: a booking, a family, an agency''s group (1122)';

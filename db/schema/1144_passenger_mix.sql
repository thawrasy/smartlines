-- =====================================================================
-- 1144: travellers by type, and the class (owner's decision N34, October 2026)
--   One search field counts four kinds of traveller: adults, children, infants on a lap and infants on their own seat,
--   with a class: any, economy, business, VIP or an accessible seat. The limits are the platform's settings, applied by
--   the server wherever seats are held or booked (a booking, a journey, a connection, the counter):
--     adults                 1 to booking.max_adults (4)
--     children               0 to booking.max_children (6)
--     infants on a lap       up to the number of adults
--     seats                  adults + children + infants on a seat, at most booking.max_seats (now 9)
--   booking.max_seats was 4 seats a booking (1122); the owner's limit is nine seats with four adults at most, so the
--   setting moves to 9 where the platform never changed it. A value the platform set itself is kept.
--   The class of a seat is its cabin in the vehicle's layout (fleet.seat_layout_seat.cabin), kept on each trip's seat
--   map; a trip without a seat map has economy seats only.
-- =====================================================================

INSERT INTO sys.setting (key, value, description) VALUES
  ('booking.max_adults', '4'::jsonb, 'Adults one booking carries (N34, 1144)'),
  ('booking.max_children', '6'::jsonb, 'Children one booking carries (N34, 1144)')
ON CONFLICT (key) DO NOTHING;
UPDATE sys.setting SET value = '9'::jsonb
 WHERE key = 'booking.max_seats' AND value = '4'::jsonb AND updated_by IS NULL;

-- the problem with a party of travellers, or nothing: the error code the API returns
CREATE OR REPLACE FUNCTION sales.passenger_mix_problem(p_adults int, p_children int, p_lap_infants int, p_seat_infants int)
RETURNS text LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE
    WHEN least(p_adults, p_children, p_lap_infants, p_seat_infants) < 0 THEN 'INVALID_PASSENGERS'
    WHEN p_adults > sales.setting_int('booking.max_adults', 4) THEN 'TOO_MANY_ADULTS'
    WHEN p_children > sales.setting_int('booking.max_children', 6) THEN 'TOO_MANY_CHILDREN'
    WHEN p_lap_infants > p_adults THEN 'TOO_MANY_LAP_INFANTS'
    WHEN p_adults + p_children + p_seat_infants > sales.setting_int('booking.max_seats', 9) THEN 'TOO_MANY_SEATS'
  END
$$;
REVOKE ALL ON FUNCTION sales.passenger_mix_problem(int, int, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.passenger_mix_problem(int, int, int, int) TO masslak_app;
COMMENT ON FUNCTION sales.passenger_mix_problem IS 'Why a party of adults, children, lap infants and seated infants cannot book together, or NULL (N34, 1144)';

-- the platform changes the numbers of adults and children, naming the decision (the seats stay with set_seat_limits)
CREATE OR REPLACE FUNCTION sales.set_passenger_mix(p_max_adults int, p_max_children int, p_basis text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the passenger limits are a platform setting' USING ERRCODE = 'P0001';
  END IF;
  IF p_max_adults IS NULL OR p_max_adults NOT BETWEEN 1 AND sales.setting_int('booking.max_seats', 9) THEN
    RAISE EXCEPTION 'INVALID_SETTING: a booking carries 1 adult up to its seats' USING ERRCODE = 'P0001';
  END IF;
  IF p_max_children IS NULL OR p_max_children NOT BETWEEN 0 AND sales.setting_int('booking.max_seats', 9) THEN
    RAISE EXCEPTION 'INVALID_SETTING: a booking carries no child up to its seats' USING ERRCODE = 'P0001';
  END IF;
  IF length(btrim(coalesce(p_basis, ''))) NOT BETWEEN 3 AND 160 THEN
    RAISE EXCEPTION 'INVALID_SETTING: name the decision behind the change (a regulator''s or the platform''s)' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at) VALUES
    ('booking.max_adults', to_jsonb(p_max_adults), 'PLATFORM', 'Adults one booking carries (N34, 1144)', sys.ctx_user_id(), now()),
    ('booking.max_children', to_jsonb(p_max_children), 'PLATFORM', 'Children one booking carries (N34, 1144)', sys.ctx_user_id(), now()),
    ('booking.limits.basis', jsonb_build_object('basis', btrim(p_basis), 'set_at', now(), 'set_by', sys.ctx_user_id()), 'PLATFORM',
     'The decision behind the seat limits as last set, and who set them (1122)', sys.ctx_user_id(), now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  RETURN sales.seat_limits();
END $$;
REVOKE ALL ON FUNCTION sales.set_passenger_mix(int, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.set_passenger_mix(int, int, text) TO masslak_app;
COMMENT ON FUNCTION sales.set_passenger_mix IS 'Sets the adults and children of a booking, with the decision behind them; platform only (N34, 1144)';

-- the numbers as they stand, for the screens: 1122's, with the travellers' limits
CREATE OR REPLACE FUNCTION sales.seat_limits() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
    'max_seats', sales.setting_int('booking.max_seats', 9),
    'max_adults', sales.setting_int('booking.max_adults', 4),
    'max_children', sales.setting_int('booking.max_children', 6),
    'family_max_seats', sales.setting_int('booking.family.max_seats', 10),
    'agency_group', sales.setting_int('agency.group.max_passengers', 50),
    'basis', (SELECT value -> 'basis' FROM sys.setting WHERE key = 'booking.limits.basis'),
    'set_at', (SELECT value -> 'set_at' FROM sys.setting WHERE key = 'booking.limits.basis'))
$$;
COMMENT ON FUNCTION sales.seat_limits IS 'The limits as they stand: seats, adults and children of a booking, a family, an agency''s group (1122, 1144)';

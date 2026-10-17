-- =====================================================================
-- 1121  Journeys: a round trip, a trip to several places, a group, booked together (owner's request, October 2026)
-- =====================================================================
-- While booking, the passenger chooses one way, a round trip, or several places one after the other (A to B, then to C:
-- a journey planned like a tour), and direct trips or trips with stops. A journey is booked in one go and paid at once:
-- one booking per trip, as before, sharing the journey's uid and numbered by leg. Tourism companies booking groups ask
-- for it most: an agency books a group of up to agency.group.max_passengers travellers on every leg, the group split
-- into bookings of at most four seats each, all of the same journey. Every booking keeps its own tickets, rules and
-- refunds; the journey only ties them together, so it adds columns and no table, and is seen wherever its bookings are.

ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS journey_uid uuid;
ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS journey_kind text;
ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS journey_leg smallint;
ALTER TABLE sales.booking DROP CONSTRAINT IF EXISTS booking_journey_check;
ALTER TABLE sales.booking ADD CONSTRAINT booking_journey_check CHECK (
  (journey_uid IS NULL AND journey_kind IS NULL AND journey_leg IS NULL)
  OR (journey_uid IS NOT NULL AND journey_kind IS NOT NULL AND journey_leg IS NOT NULL      -- a NULL would let the check pass
      AND journey_kind IN ('ONE_WAY', 'ROUND_TRIP', 'MULTI_CITY') AND journey_leg BETWEEN 1 AND 6));
CREATE INDEX IF NOT EXISTS booking_journey_uid_idx ON sales.booking (journey_uid) WHERE journey_uid IS NOT NULL;
COMMENT ON COLUMN sales.booking.journey_uid IS 'The journey the booking belongs to: the bookings of a round trip, of a trip to several places or of a group, booked together (1121)';
COMMENT ON COLUMN sales.booking.journey_kind IS 'ONE_WAY (a group on one trip, in several bookings), ROUND_TRIP or MULTI_CITY (several places one after the other) (1121)';
COMMENT ON COLUMN sales.booking.journey_leg IS 'The leg of the journey this booking travels, 1 to 6, in the order of travel (1121)';

-- how many travellers an agency books as one group on every leg of a journey
INSERT INTO sys.setting (key, value, description) VALUES
  ('agency.group.max_passengers', '50'::jsonb, 'Travellers an agency books as one group on each leg of a journey, split into bookings of at most four seats (1121)')
ON CONFLICT (key) DO NOTHING;

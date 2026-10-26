-- =====================================================================
-- Masslak - 1102: a carrier cancels a trip, with full refunds (a gap found by the review of the use cases, October 2026)
--
-- A passenger could cancel a booking (refunded by the fare brand's schedule) but a carrier had no way to cancel a
-- trip: the trip's bookings would have stayed confirmed. The carrier now cancels a published trip from its portal
-- (POST /api/carrier/trips/{uid}/cancel, backend/app/modules/sales/service.py, cancel_trip):
--   * every paid booking is cancelled and refunded in full, the platform fee included, to the wallet that paid it
--     (the passenger's or the family's wallet, the agency's balance, or the carrier's cash account for a counter sale,
--     whose cash the counter hands back); every line of the booking's price allocation is refunded, so the agency
--     keeps no commission and the carrier earns nothing on it;
--   * reservations not yet paid are cancelled and their seats freed; seats held in a basket are released;
--   * a trip with parcels on its hold is refused until they are moved; open parcel offers are withdrawn;
--   * the crew is released and the decision is kept in ops.trip_disruption (decision CANCEL) with its reason;
--   * the travellers are told (in the app, by e-mail, or by text when they have no account) and the carrier's
--     webhooks receive trip.cancelled.
-- This file adds the permission trip.cancel, held by the carrier operations role and by owners, and the reason.
-- =====================================================================

INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('trip.cancel', 'ops', 'COMPANY', 'Cancel a published trip and refund every booking in full (1102)', true)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'trip.cancel' FROM iam.role r WHERE r.code = 'CARRIER_OPERATIONS'
ON CONFLICT DO NOTHING;

ALTER TABLE ops.trip_disruption ADD COLUMN IF NOT EXISTS reason text;
DO $$ BEGIN
  ALTER TABLE ops.trip_disruption ADD CONSTRAINT trip_disruption_reason_len CHECK (reason IS NULL OR length(reason) BETWEEN 5 AND 500);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN ops.trip_disruption.reason IS 'Why the carrier decided, in its words; required for a cancellation (1102)';
DO $$ BEGIN
  ALTER TABLE ops.trip_disruption ADD CONSTRAINT trip_disruption_cancel_reason CHECK (decision IS DISTINCT FROM 'CANCEL' OR reason IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- A cancelled trip stays visible to those who booked it (the passenger, or the agency that sold it), so their cancelled
-- booking and its refund still show in their lists; it was hidden from everyone but the carrier before
DROP POLICY IF EXISTS trip_read ON ops.trip;
CREATE POLICY trip_read ON ops.trip FOR SELECT USING (
  status IN ('PUBLISHED','BOARDING','DEPARTED','COMPLETED') OR sys.tenant_visible(company_id)
  OR (status = 'CANCELLED' AND EXISTS (SELECT 1 FROM sales.booking b WHERE b.trip_id = trip.id
                                         AND (b.booker_party_id = sys.ctx_party_id() OR b.booker_user_id = sys.ctx_user_id()
                                              OR b.agency_id = sys.ctx_company_id()))));

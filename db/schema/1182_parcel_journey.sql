-- 1182: a parcel's journey after it is handed over (review of the parcel system, 26 October 2026; docs/design/PARCEL_JOURNEY.md).
--
-- 1147 took a parcel from booking to the counter: reserved, paid, handed over and labelled. Its journey on the trip and
-- its hand-over to the recipient were left to the generic shipment screens. Here the carrier's staff scan the label (or
-- type the tracking number) when the parcel goes on board, and again when it is taken off at the destination station;
-- the parcel then waits for its recipient, who collects it with a six-digit code the sender received (kept as a hash
-- only, with a limit of tries) or, when the code is lost, with an identity check the clerk records. A parcel damaged,
-- missing or refused is recorded as an exception with its note; one not collected within the policy's days is returned.
-- Each step is a tracking milestone, and the order of the steps is kept by the table's own checks.

UPDATE sys.setting
   SET value = value || '{"unclaimed_days": 7, "pickup_code_tries": 5}'::jsonb,
       description = description || '; unclaimed_days is how long an arrived parcel waits for its recipient before it may be returned, pickup_code_tries the wrong codes allowed before only an identity check hands it over (1182)',
       updated_at = now()
 WHERE key = 'parcels.policy' AND NOT value ? 'unclaimed_days';

ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS loaded_at timestamptz;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS loaded_by bigint REFERENCES iam.app_user(id);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS arrived_at timestamptz;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS arrived_by bigint REFERENCES iam.app_user(id);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS pickup_code_hash bytea CHECK (pickup_code_hash IS NULL OR length(pickup_code_hash) = 32);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS pickup_code_tries smallint NOT NULL DEFAULT 0 CHECK (pickup_code_tries >= 0);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS delivered_at timestamptz;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS delivered_by bigint REFERENCES iam.app_user(id);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS exception_kind text
  CHECK (exception_kind IS NULL OR exception_kind IN ('DAMAGED', 'MISSING', 'REFUSED', 'UNCLAIMED'));
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS exception_note text
  CHECK (exception_note IS NULL OR length(btrim(exception_note)) BETWEEN 3 AND 300);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS returned_at timestamptz;
CREATE INDEX IF NOT EXISTS shipment_loaded_by_fkx ON ship.shipment (loaded_by);
CREATE INDEX IF NOT EXISTS shipment_arrived_by_fkx ON ship.shipment (arrived_by);
CREATE INDEX IF NOT EXISTS shipment_delivered_by_fkx ON ship.shipment (delivered_by);
CREATE INDEX IF NOT EXISTS shipment_waiting_ix ON ship.shipment (dest_station_id, arrived_at)
  WHERE arrived_at IS NOT NULL AND delivered_at IS NULL AND returned_at IS NULL;

-- the steps come in their order: handed over, on board, arrived, then delivered or returned
ALTER TABLE ship.shipment DROP CONSTRAINT IF EXISTS shipment_journey_ck;
ALTER TABLE ship.shipment ADD CONSTRAINT shipment_journey_ck CHECK (
      (loaded_at IS NULL OR handed_over_at IS NOT NULL)
  AND (arrived_at IS NULL OR loaded_at IS NOT NULL)
  AND (delivered_at IS NULL OR arrived_at IS NOT NULL)
  AND (delivered_at IS NULL OR returned_at IS NULL)
  AND ((exception_kind IS NULL) = (exception_note IS NULL))
  AND (returned_at IS NULL OR exception_kind IS NOT NULL)
  AND ((arrived_at IS NULL) OR (pickup_code_hash IS NOT NULL))) NOT VALID;
ALTER TABLE ship.shipment VALIDATE CONSTRAINT shipment_journey_ck;

COMMENT ON COLUMN ship.shipment.loaded_at IS 'When the parcel went on board, its label scanned by the carrier''s staff (1182)';
COMMENT ON COLUMN ship.shipment.arrived_at IS 'When the parcel was taken off at the destination station and began to wait for its recipient (1182)';
COMMENT ON COLUMN ship.shipment.pickup_code_hash IS 'The hash of the six-digit code the recipient gives to collect the parcel; the code itself is never kept (1182)';
COMMENT ON COLUMN ship.shipment.pickup_code_tries IS 'Wrong codes given; past the policy''s limit only an identity check hands the parcel over (1182)';
COMMENT ON COLUMN ship.shipment.delivered_at IS 'When the recipient collected the parcel (1182)';
COMMENT ON COLUMN ship.shipment.exception_kind IS 'DAMAGED, MISSING, REFUSED or UNCLAIMED, with its note (1182)';
COMMENT ON COLUMN ship.shipment.returned_at IS 'When the parcel went back to its sender after an exception (1182)';

-- the hand-over to the recipient writes its attempt, its proof and the cash collected on delivery: these tables open with
-- either switch too, as 1147 opened the parcel tables (the courier's own tables stay behind cargo alone)
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ship.delivery_attempt', 'ship.delivery_proof', 'ship.cod_collection'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS module_gate ON %s', t);
    EXECUTE format('CREATE POLICY module_gate ON %s AS RESTRICTIVE FOR ALL USING (sys.ctx_is_platform() OR sys.feature_on(%L)) '
                   'WITH CHECK (sys.ctx_is_platform() OR sys.feature_on(%L))', t, '{cargo,trip_parcels}', '{cargo,trip_parcels}');
  END LOOP;
END $$;

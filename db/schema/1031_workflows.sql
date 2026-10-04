-- =====================================================================
-- 1031: columns the module workflows need
--   Parcels sent from the passenger site carry who receives them, so the courier can call ahead and the
--   recipient can be checked at delivery. Public tracking shows neither field.
-- =====================================================================

ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS recipient_name text
  CHECK (recipient_name IS NULL OR length(recipient_name) BETWEEN 3 AND 120);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS recipient_mobile text
  CHECK (recipient_mobile IS NULL OR recipient_mobile ~ '^\+?[0-9]{8,15}$');
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS contents text
  CHECK (contents IS NULL OR length(contents) <= 200);

COMMENT ON COLUMN ship.shipment.recipient_name IS 'Person who receives the parcel (personal data, never shown on public tracking)';
COMMENT ON COLUMN ship.shipment.recipient_mobile IS 'Recipient mobile for delivery calls and one-time codes (personal data)';
COMMENT ON COLUMN ship.shipment.contents IS 'Short description of the contents, declared by the sender';

INSERT INTO sys.schema_migration (version, description)
SELECT '1.14.0', 'Recipient and contents of parcels sent from the passenger site'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.14.0');

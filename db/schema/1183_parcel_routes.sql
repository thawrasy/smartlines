-- 1183: a parcel through the carrier's locations, delivered at the counter or to an address, important parcels and the
-- identity check recorded field by field (owner's note on the parcel journey, 26 October 2026; docs/design/PARCEL_JOURNEY.md).
--
-- 1182 took a parcel on board and off at its destination. A carrier with several locations along the way receives the
-- parcel at each one and sends it on to the next (A, then B, then C, ... Z); each location is a step the sender follows.
-- At the destination the parcel is collected at the counter, the default, or, when the carrier switched it on in its
-- settings, taken to the recipient's address: the pickup code then goes out when the parcel leaves for the address, not
-- when it arrives. The clerk can send the code again at the recipient's request. A parcel the sender marks important (or
-- whose declared value reaches the platform's amount) is handed over only with both the code and an identity check, and
-- its sender is told of every step. An identity check is recorded as the document's kind, its number (encrypted, with its
-- last four digits shown), the holder's name and who issued it.

UPDATE sys.setting
   SET value = value || '{"code_sends": 3, "secure_from_value": null}'::jsonb,
       description = description || '; code_sends is how many times the clerk may send a pickup code again, secure_from_value the declared value from which a parcel is handled as important (null: only when the sender asks) (1183)',
       updated_at = now()
 WHERE key = 'parcels.policy' AND NOT value ? 'code_sends';

-- ------------------------------------------------------------------ the carrier's choice: delivery to an address
ALTER TABLE ship.parcel_carrier ADD COLUMN IF NOT EXISTS address_delivery boolean NOT NULL DEFAULT false;
ALTER TABLE ship.parcel_carrier ADD COLUMN IF NOT EXISTS address_fee bigint NOT NULL DEFAULT 0 CHECK (address_fee >= 0);
COMMENT ON COLUMN ship.parcel_carrier.address_delivery IS 'The carrier also takes parcels to the recipient''s address; off, parcels are collected at its counter (1183)';
COMMENT ON COLUMN ship.parcel_carrier.address_fee IS 'Added to the price of a parcel taken to an address, in minor units (1183)';

-- ------------------------------------------------------------------ the shipment: how it is handed over, where it is
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS delivery_mode text NOT NULL DEFAULT 'PICKUP' CHECK (delivery_mode IN ('PICKUP', 'ADDRESS'));
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS delivery_address text
  CHECK (delivery_address IS NULL OR length(btrim(delivery_address)) BETWEEN 5 AND 300);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS secure boolean NOT NULL DEFAULT false;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS code_issued_at timestamptz;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS code_sends smallint NOT NULL DEFAULT 0 CHECK (code_sends >= 0);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS out_for_delivery_at timestamptz;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS out_by bigint REFERENCES iam.app_user(id);
CREATE INDEX IF NOT EXISTS shipment_out_by_fkx ON ship.shipment (out_by);
COMMENT ON COLUMN ship.shipment.delivery_mode IS 'PICKUP: collected at the destination counter; ADDRESS: taken to delivery_address (1183)';
COMMENT ON COLUMN ship.shipment.secure IS 'An important parcel: handed over with both the code and an identity check, its sender told of every step (1183)';
COMMENT ON COLUMN ship.shipment.code_issued_at IS 'When the current pickup code was issued (arrival at the counter, or leaving for the address); the code is drawn from it and never stored (1183)';
COMMENT ON COLUMN ship.shipment.out_for_delivery_at IS 'When the parcel left the destination for the recipient''s address; cleared when an attempt fails and it is back at the station (1183)';

UPDATE ship.shipment SET code_issued_at = arrived_at WHERE pickup_code_hash IS NOT NULL AND code_issued_at IS NULL;

ALTER TABLE ship.shipment DROP CONSTRAINT IF EXISTS shipment_journey_ck;
ALTER TABLE ship.shipment ADD CONSTRAINT shipment_journey_ck CHECK (
      (loaded_at IS NULL OR handed_over_at IS NOT NULL)
  AND (arrived_at IS NULL OR loaded_at IS NOT NULL)
  AND (delivered_at IS NULL OR arrived_at IS NOT NULL)
  AND (delivered_at IS NULL OR returned_at IS NULL)
  AND ((exception_kind IS NULL) = (exception_note IS NULL))
  AND (returned_at IS NULL OR exception_kind IS NOT NULL)
  -- a parcel collected at the counter has its code from arrival; one taken to an address gets it when it leaves
  AND (arrived_at IS NULL OR delivery_mode = 'ADDRESS' OR pickup_code_hash IS NOT NULL)
  AND ((pickup_code_hash IS NULL) = (code_issued_at IS NULL))
  AND ((delivery_mode = 'ADDRESS') = (delivery_address IS NOT NULL))
  AND (out_for_delivery_at IS NULL OR (delivery_mode = 'ADDRESS' AND arrived_at IS NOT NULL AND pickup_code_hash IS NOT NULL))
  AND (delivered_at IS NULL OR delivery_mode = 'PICKUP' OR out_for_delivery_at IS NOT NULL)) NOT VALID;
ALTER TABLE ship.shipment VALIDATE CONSTRAINT shipment_journey_ck;

-- ------------------------------------------------------------------ the locations a parcel passes through
CREATE TABLE IF NOT EXISTS ship.parcel_hop (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint NOT NULL REFERENCES iam.company(id),
  shipment_id   bigint NOT NULL REFERENCES ship.shipment(id),
  seq           smallint NOT NULL CHECK (seq >= 1),
  point_id      bigint NOT NULL REFERENCES ship.parcel_point(id),
  received_at   timestamptz NOT NULL DEFAULT now(),
  received_by   bigint NOT NULL REFERENCES iam.app_user(id),
  dispatched_at timestamptz,
  dispatched_by bigint REFERENCES iam.app_user(id),
  next_point_id bigint REFERENCES ship.parcel_point(id),
  UNIQUE (shipment_id, seq),
  CHECK ((dispatched_at IS NULL) = (dispatched_by IS NULL)),
  CHECK (dispatched_at IS NULL OR dispatched_at >= received_at),
  CHECK (next_point_id IS NULL OR dispatched_at IS NOT NULL),
  CHECK (next_point_id IS DISTINCT FROM point_id)
);
-- a parcel is at one location at a time: received, not yet sent on
CREATE UNIQUE INDEX IF NOT EXISTS parcel_hop_open_uq ON ship.parcel_hop (shipment_id) WHERE dispatched_at IS NULL;
CREATE INDEX IF NOT EXISTS parcel_hop_point_idx ON ship.parcel_hop (point_id, received_at) WHERE dispatched_at IS NULL;
CREATE INDEX IF NOT EXISTS parcel_hop_company_id_fkx ON ship.parcel_hop (company_id);
CREATE INDEX IF NOT EXISTS parcel_hop_received_by_fkx ON ship.parcel_hop (received_by);
CREATE INDEX IF NOT EXISTS parcel_hop_dispatched_by_fkx ON ship.parcel_hop (dispatched_by);
CREATE INDEX IF NOT EXISTS parcel_hop_next_point_id_fkx ON ship.parcel_hop (next_point_id);
COMMENT ON TABLE ship.parcel_hop IS 'Each of the carrier''s locations a parcel passed through between loading and its destination: received there, then sent on (1183)';
SELECT sys.rls_split('ship.parcel_hop', 'sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
GRANT SELECT, INSERT, UPDATE ON ship.parcel_hop TO masslak_app;
GRANT SELECT ON ship.parcel_hop TO masslak_readonly, masslak_auditor;

-- ------------------------------------------------------------------ the identity check at hand-over
CREATE TABLE IF NOT EXISTS ship.parcel_id_check (
  shipment_id  bigint PRIMARY KEY REFERENCES ship.shipment(id),
  company_id   bigint NOT NULL REFERENCES iam.company(id),
  doc_kind     text NOT NULL CHECK (doc_kind IN ('NATIONAL_ID', 'PASSPORT', 'FAMILY_BOOK', 'RESIDENCE', 'DRIVING_LICENCE', 'OTHER')),
  doc_no_enc   bytea NOT NULL,
  enc_key_id   bigint NOT NULL REFERENCES sec.key_registry(id),
  doc_last4    text NOT NULL CHECK (length(doc_last4) BETWEEN 1 AND 4),
  holder_name  text NOT NULL CHECK (length(btrim(holder_name)) BETWEEN 3 AND 120),
  issued_by    text CHECK (issued_by IS NULL OR length(btrim(issued_by)) BETWEEN 2 AND 120),
  checked_by   bigint NOT NULL REFERENCES iam.app_user(id),
  checked_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS parcel_id_check_company_id_fkx ON ship.parcel_id_check (company_id);
CREATE INDEX IF NOT EXISTS parcel_id_check_enc_key_id_fkx ON ship.parcel_id_check (enc_key_id);
CREATE INDEX IF NOT EXISTS parcel_id_check_checked_by_fkx ON ship.parcel_id_check (checked_by);
COMMENT ON TABLE ship.parcel_id_check IS 'The identity document checked when a parcel was handed over: kind, number (encrypted), holder and issuer (1183)';
COMMENT ON COLUMN ship.parcel_id_check.doc_no_enc IS 'The document number, encrypted under enc_key_id (associated data ship.parcel_id_check.doc_no); only its last four digits are shown';
SELECT sys.rls_split('ship.parcel_id_check', 'sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
GRANT SELECT, INSERT ON ship.parcel_id_check TO masslak_app;
GRANT SELECT ON ship.parcel_id_check TO masslak_auditor;

-- ------------------------------------------------------------------ registrations and the module gate
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ship.parcel_hop', '3', 'E28'), ('ship.parcel_id_check', '3', 'E28')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ship.parcel_hop', 'ship records', 'the locations a parcel passed through (1183)'),
  ('ship.parcel_id_check', 'ship personal records', 'the identity document checked when a parcel was handed over (1183)')
ON CONFLICT (table_name) DO UPDATE SET dataset = EXCLUDED.dataset, note = EXCLUDED.note;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ship.parcel_hop', 'ship.parcel_id_check'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS module_gate ON %s', t);
    EXECUTE format('CREATE POLICY module_gate ON %s AS RESTRICTIVE FOR ALL USING (sys.ctx_is_platform() OR sys.feature_on(%L)) '
                   'WITH CHECK (sys.ctx_is_platform() OR sys.feature_on(%L))', t, '{cargo,trip_parcels}', '{cargo,trip_parcels}');
  END LOOP;
END $$;

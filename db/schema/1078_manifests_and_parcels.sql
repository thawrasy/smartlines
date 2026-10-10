-- =====================================================================
-- 1078: manifests that carry their cargo and cannot change once issued; parcels booked on a trip's hold
--   (review of release 1.47.0, package G: R-11, R-12, R-13, R-14; owner's decision 3)
--
--   Manifests
--   * Once a manifest leaves DRAFT its people, vehicle and cargo rows cannot be added, changed or removed, and its
--     header keeps its content (trip, crossing, version, type, hash, signature); only its status moves on. A change is
--     a new version (AMENDMENT) that supersedes it. Key rotation may still re-encrypt document numbers, whose clear
--     value does not change. The issue path builds the cargo from the shipment legs the trip carries, hashes a
--     canonical form of every row (canonical_version 1) and signs the hash (Ed25519, payload_signature, signing_kid);
--     authorities verify both with the key published at /api/public/keys/manifest.
--   * An international manifest whose crossing has an authority is SUBMITTED to it at issue: the border contract of
--     the integration API (/api/v1/border/*) reads and decides the live manifests, and its decision answers that
--     authority's delivery too, so the carrier sees one result.
--
--   Parcels (owner's decision 3)
--   * Each carrier publishes parcel tariffs (ship.parcel_tariff): by weight, by volume, by whichever of the two costs
--     more (both shown), a fixed price per item (letters), or a price agreed with the customer (ship.parcel_offer: the
--     customer asks, the carrier offers a price valid until a time, the customer accepts and pays it).
--   * ship.parcel_price() is the one place a tariff becomes a price, for quotes and bookings alike.
--   * A booked parcel rides a trip's hold: in one transaction the shipment, its parcel and its leg on the trip are
--     written, the hold capacity is checked under the capacity row's lock (1067), and only then the wallet is charged.
--     A shipment marked guaranteed cannot be committed without a leg on a trip or a load (deferred check).
--   * ship.trip_hold() tells customers how much of a trip's hold is still free, without showing what is loaded.
-- =====================================================================

-- ------------------------------------------------------------------ a. manifests: sealed once issued, signed
ALTER TABLE brd.manifest ADD COLUMN IF NOT EXISTS payload_signature bytea;
ALTER TABLE brd.manifest ADD COLUMN IF NOT EXISTS signing_kid text;
ALTER TABLE brd.manifest ADD COLUMN IF NOT EXISTS canonical_version smallint;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'manifest_signed' AND conrelid = 'brd.manifest'::regclass) THEN
    ALTER TABLE brd.manifest ADD CONSTRAINT manifest_signed
      CHECK (payload_signature IS NULL OR (signing_kid IS NOT NULL AND payload_sha256 IS NOT NULL AND canonical_version IS NOT NULL));
  END IF;
END $$;
COMMENT ON COLUMN brd.manifest.payload_signature IS 'Ed25519 signature of payload_sha256 by the platform manifest key (1078)';
COMMENT ON COLUMN brd.manifest.canonical_version IS 'Version of the canonical form hashed into payload_sha256; NULL for manifests issued before 1078';

-- the header keeps its content once issued; only the status moves on (never back to DRAFT), and an issued manifest is
-- a record that is not deleted
CREATE OR REPLACE FUNCTION brd.tg_manifest_sealed() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF OLD.status = 'DRAFT' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'MANIFEST_SEALED: manifest % was issued and is kept as a record', OLD.id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'DRAFT'
     OR (NEW.trip_id, NEW.border_point_id, NEW.version, NEW.manifest_type, NEW.content_type, NEW.scope, NEW.supersedes_id,
         NEW.payload_sha256, NEW.payload_signature, NEW.signing_kid, NEW.canonical_version, NEW.persons_count, NEW.issued_at,
         NEW.issued_by, NEW.crossing_plan_id, NEW.profile_id)
        IS DISTINCT FROM
        (OLD.trip_id, OLD.border_point_id, OLD.version, OLD.manifest_type, OLD.content_type, OLD.scope, OLD.supersedes_id,
         OLD.payload_sha256, OLD.payload_signature, OLD.signing_kid, OLD.canonical_version, OLD.persons_count, OLD.issued_at,
         OLD.issued_by, OLD.crossing_plan_id, OLD.profile_id) THEN
    RAISE EXCEPTION 'MANIFEST_SEALED: manifest % was issued and cannot change; issue an AMENDMENT', OLD.id USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS manifest_sealed ON brd.manifest;
CREATE TRIGGER manifest_sealed BEFORE UPDATE OR DELETE ON brd.manifest FOR EACH ROW EXECUTE FUNCTION brd.tg_manifest_sealed();

-- people, vehicle and cargo rows of a manifest that left DRAFT do not change
CREATE OR REPLACE FUNCTION brd.tg_manifest_content_sealed() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE ids bigint[]; v_id bigint; v_status text;
BEGIN
  ids := CASE TG_OP WHEN 'INSERT' THEN ARRAY[NEW.manifest_id] WHEN 'DELETE' THEN ARRAY[OLD.manifest_id]
                    ELSE ARRAY[OLD.manifest_id, NEW.manifest_id] END;
  IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'manifest_person' AND OLD.manifest_id = NEW.manifest_id
     AND (to_jsonb(NEW) - ARRAY['doc_no_enc', 'doc_no_bidx', 'enc_key_id'])
         = (to_jsonb(OLD) - ARRAY['doc_no_enc', 'doc_no_bidx', 'enc_key_id']) THEN
    RETURN NEW;                     -- key rotation re-encrypts a document number; its clear value and the hash stay the same
  END IF;
  FOREACH v_id IN ARRAY ids LOOP
    SELECT status INTO v_status FROM brd.manifest WHERE id = v_id;
    -- not found: the manifest itself is being removed (only a DRAFT can be)
    IF FOUND AND v_status <> 'DRAFT' THEN
      RAISE EXCEPTION 'MANIFEST_SEALED: manifest % was issued and its % cannot change; issue an AMENDMENT', v_id,
        replace(TG_TABLE_NAME, 'manifest_', '') USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
DROP TRIGGER IF EXISTS manifest_content_sealed ON brd.manifest_person;
CREATE TRIGGER manifest_content_sealed BEFORE INSERT OR UPDATE OR DELETE ON brd.manifest_person
  FOR EACH ROW EXECUTE FUNCTION brd.tg_manifest_content_sealed();
DROP TRIGGER IF EXISTS manifest_content_sealed ON brd.manifest_vehicle;
CREATE TRIGGER manifest_content_sealed BEFORE INSERT OR UPDATE OR DELETE ON brd.manifest_vehicle
  FOR EACH ROW EXECUTE FUNCTION brd.tg_manifest_content_sealed();
DROP TRIGGER IF EXISTS manifest_content_sealed ON brd.manifest_cargo;
CREATE TRIGGER manifest_content_sealed BEFORE INSERT OR UPDATE OR DELETE ON brd.manifest_cargo
  FOR EACH ROW EXECUTE FUNCTION brd.tg_manifest_content_sealed();

-- the issue path reads each shipment's weight and pieces to declare the cargo
GRANT EXECUTE ON FUNCTION ship.shipment_size(bigint) TO masslak_app;

-- ------------------------------------------------------------------ b. parcels: tariffs, agreed prices, the hold
CREATE TABLE IF NOT EXISTS ship.parcel_tariff (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid            uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id     bigint NOT NULL REFERENCES iam.company(id),
  code           text NOT NULL CHECK (code ~ '^[A-Z][A-Z0-9_]{1,29}$'),
  name           text NOT NULL CHECK (length(name) BETWEEN 2 AND 80),
  pricing_mode   text NOT NULL CHECK (pricing_mode IN ('WEIGHT', 'VOLUME', 'WEIGHT_AND_VOLUME', 'FIXED', 'NEGOTIATED')),
  currency       char(3) NOT NULL REFERENCES ref.currency(code),
  base_price     bigint NOT NULL DEFAULT 0 CHECK (base_price >= 0),     -- minor units, added to a weight or volume charge
  per_kg         bigint CHECK (per_kg >= 0),
  per_m3         bigint CHECK (per_m3 >= 0),
  fixed_price    bigint CHECK (fixed_price >= 0),
  min_charge     bigint NOT NULL DEFAULT 0 CHECK (min_charge >= 0),
  max_weight_kg  numeric(8,2) CHECK (max_weight_kg > 0),
  max_volume_m3  numeric(8,4) CHECK (max_volume_m3 > 0),
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  created_by     bigint REFERENCES iam.app_user(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (pricing_mode NOT IN ('WEIGHT', 'WEIGHT_AND_VOLUME') OR per_kg IS NOT NULL),
  CHECK (pricing_mode NOT IN ('VOLUME', 'WEIGHT_AND_VOLUME') OR per_m3 IS NOT NULL),
  CHECK (pricing_mode <> 'FIXED' OR fixed_price IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS parcel_tariff_active_code ON ship.parcel_tariff (company_id, code) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS parcel_tariff_created_by_fkx ON ship.parcel_tariff (created_by);
COMMENT ON TABLE ship.parcel_tariff IS
  'A carrier''s parcel prices: by weight, by volume, by the dearer of the two, fixed per item, or agreed with the customer (owner''s decision 3, 1078)';
-- customers read the active tariffs of every carrier; a carrier writes its own
SELECT sys.rls_split('ship.parcel_tariff', 'status = ''ACTIVE'' OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
GRANT SELECT, INSERT, UPDATE ON ship.parcel_tariff TO masslak_app;
GRANT SELECT ON ship.parcel_tariff TO masslak_readonly, masslak_auditor;

CREATE TABLE IF NOT EXISTS ship.parcel_offer (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  tariff_id          bigint NOT NULL REFERENCES ship.parcel_tariff(id),
  company_id         bigint NOT NULL REFERENCES iam.company(id),
  requester_party_id bigint NOT NULL REFERENCES iam.party(id),
  requester_user_id  bigint REFERENCES iam.app_user(id),
  trip_id            bigint NOT NULL REFERENCES ops.trip(id),
  from_seq           smallint NOT NULL CHECK (from_seq >= 0),
  to_seq             smallint NOT NULL,
  weight_kg          numeric(8,2) NOT NULL CHECK (weight_kg > 0),
  volume_m3          numeric(8,4) NOT NULL DEFAULT 0 CHECK (volume_m3 >= 0),
  description        text NOT NULL CHECK (length(description) BETWEEN 2 AND 200),
  status             text NOT NULL DEFAULT 'REQUESTED'
                     CHECK (status IN ('REQUESTED', 'OFFERED', 'ACCEPTED', 'DECLINED', 'WITHDRAWN', 'EXPIRED')),
  price              bigint CHECK (price >= 0),
  currency           char(3) REFERENCES ref.currency(code),
  note               text CHECK (length(note) <= 300),
  offered_by         bigint REFERENCES iam.app_user(id),
  offered_at         timestamptz,
  valid_until        timestamptz,
  shipment_id        bigint UNIQUE REFERENCES ship.shipment(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (to_seq > from_seq),
  CHECK (status NOT IN ('OFFERED', 'ACCEPTED') OR (price IS NOT NULL AND currency IS NOT NULL AND valid_until IS NOT NULL)),
  CHECK (status <> 'ACCEPTED' OR shipment_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS parcel_offer_tariff_id_fkx ON ship.parcel_offer (tariff_id);
CREATE INDEX IF NOT EXISTS parcel_offer_company_id_fkx ON ship.parcel_offer (company_id, status);
CREATE INDEX IF NOT EXISTS parcel_offer_requester_party_id_fkx ON ship.parcel_offer (requester_party_id);
CREATE INDEX IF NOT EXISTS parcel_offer_requester_user_id_fkx ON ship.parcel_offer (requester_user_id);
CREATE INDEX IF NOT EXISTS parcel_offer_trip_id_fkx ON ship.parcel_offer (trip_id);
CREATE INDEX IF NOT EXISTS parcel_offer_offered_by_fkx ON ship.parcel_offer (offered_by);
COMMENT ON TABLE ship.parcel_offer IS
  'A price agreed between a carrier and a customer for one parcel on one trip (letters and the like): asked, offered, accepted and paid (owner''s decision 3, 1078)';
SELECT sys.rls('ship.parcel_offer', 'sys.tenant_visible(company_id) OR requester_party_id = sys.ctx_party_id()');
GRANT SELECT, INSERT, UPDATE ON ship.parcel_offer TO masslak_app;
GRANT SELECT ON ship.parcel_offer TO masslak_readonly, masslak_auditor;

-- the new tables open with the shipping module, as the rest of the schema (1039)
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ship.parcel_tariff', 'ship.parcel_offer'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS module_gate ON %s', t);
    EXECUTE format('CREATE POLICY module_gate ON %s AS RESTRICTIVE FOR ALL USING (sys.ctx_is_platform() OR sys.feature_on(%L)) WITH CHECK (sys.ctx_is_platform() OR sys.feature_on(%L))',
                   t, '{cargo}', '{cargo}');
  END LOOP;
END $$;

ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS guaranteed boolean NOT NULL DEFAULT false;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS tariff_id bigint REFERENCES ship.parcel_tariff(id);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS idempotency_key text CHECK (length(idempotency_key) BETWEEN 8 AND 80);
CREATE INDEX IF NOT EXISTS shipment_tariff_id_fkx ON ship.shipment (tariff_id);
CREATE UNIQUE INDEX IF NOT EXISTS shipment_shipper_idempotency ON ship.shipment (shipper_party_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
COMMENT ON COLUMN ship.shipment.guaranteed IS 'Booked on a trip''s hold or a load: committed only with a leg holding its capacity (1078)';

ALTER TABLE ship.parcel ADD COLUMN IF NOT EXISTS volume_m3 numeric(8,4)
  GENERATED ALWAYS AS (length_cm * width_cm * height_cm / 1000000.0) STORED;

-- a guaranteed shipment owns its capacity from the moment it exists: checked at commit, after its leg is written
CREATE OR REPLACE FUNCTION ship.tg_guaranteed_has_capacity() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.guaranteed AND NOT EXISTS (
       SELECT 1 FROM ship.shipment_leg l WHERE l.shipment_id = NEW.id AND l.status <> 'CANCELLED'
          AND (l.trip_id IS NOT NULL OR l.load_id IS NOT NULL)) THEN
    RAISE EXCEPTION 'CAPACITY_REQUIRED: guaranteed shipment % has no leg holding capacity on a trip or a load', NEW.tracking_no
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS guaranteed_has_capacity ON ship.shipment;
CREATE CONSTRAINT TRIGGER guaranteed_has_capacity AFTER INSERT OR UPDATE OF guaranteed ON ship.shipment
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ship.tg_guaranteed_has_capacity();

-- the one place a tariff becomes a price: weight, volume, the dearer of both, fixed, or agreed (no price here)
CREATE OR REPLACE FUNCTION ship.parcel_price(p_tariff bigint, p_weight_kg numeric, p_volume_m3 numeric) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE t ship.parcel_tariff; w_charge bigint; v_charge bigint; charge bigint; basis text;
BEGIN
  SELECT * INTO t FROM ship.parcel_tariff WHERE id = p_tariff AND status = 'ACTIVE';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TARIFF_NOT_FOUND: this parcel tariff is not offered' USING ERRCODE = 'P0001';
  END IF;
  IF p_weight_kg IS NULL OR p_weight_kg <= 0 OR p_volume_m3 IS NULL OR p_volume_m3 < 0 THEN
    RAISE EXCEPTION 'PARCEL_SIZE: give the weight and the size of the parcel' USING ERRCODE = 'P0001';
  END IF;
  IF t.max_weight_kg IS NOT NULL AND p_weight_kg > t.max_weight_kg THEN
    RAISE EXCEPTION 'PARCEL_TOO_HEAVY: % takes up to % kg', t.name, t.max_weight_kg USING ERRCODE = 'P0001';
  END IF;
  IF t.max_volume_m3 IS NOT NULL AND p_volume_m3 > t.max_volume_m3 THEN
    RAISE EXCEPTION 'PARCEL_TOO_LARGE: % takes up to % m3', t.name, t.max_volume_m3 USING ERRCODE = 'P0001';
  END IF;
  w_charge := CASE WHEN t.per_kg IS NOT NULL THEN ceil(p_weight_kg * t.per_kg)::bigint END;
  v_charge := CASE WHEN t.per_m3 IS NOT NULL THEN ceil(p_volume_m3 * t.per_m3)::bigint END;
  CASE t.pricing_mode
    WHEN 'WEIGHT' THEN charge := t.base_price + w_charge; basis := 'WEIGHT';
    WHEN 'VOLUME' THEN charge := t.base_price + v_charge; basis := 'VOLUME';
    WHEN 'WEIGHT_AND_VOLUME' THEN
      basis := CASE WHEN v_charge > w_charge THEN 'VOLUME' ELSE 'WEIGHT' END;
      charge := t.base_price + greatest(w_charge, v_charge);
    WHEN 'FIXED' THEN charge := t.fixed_price; basis := 'FIXED';
    ELSE charge := NULL; basis := 'AGREED';
  END CASE;
  RETURN jsonb_build_object(
    'tariff', t.code, 'mode', t.pricing_mode, 'currency', t.currency, 'weight_kg', p_weight_kg, 'volume_m3', round(p_volume_m3, 4),
    'base', CASE WHEN t.pricing_mode IN ('WEIGHT', 'VOLUME', 'WEIGHT_AND_VOLUME') THEN t.base_price END,
    'weight_charge', w_charge, 'volume_charge', v_charge, 'fixed', t.fixed_price, 'min_charge', t.min_charge, 'basis', basis,
    'total', CASE WHEN charge IS NULL THEN NULL ELSE greatest(charge, t.min_charge) END);
END $$;
REVOKE ALL ON FUNCTION ship.parcel_price(bigint, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ship.parcel_price(bigint, numeric, numeric) TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION ship.parcel_price IS 'Price of one parcel under a tariff, with the weight and volume charges shown; NULL total for an agreed price (1078)';

-- how much of a trip's hold is free, for customers choosing a trip (what is loaded stays the carrier's)
CREATE OR REPLACE FUNCTION ship.trip_hold(p_trip bigint)
  RETURNS TABLE (max_weight_kg numeric, max_volume_m3 numeric, max_items int, free_weight_kg numeric, free_volume_m3 numeric,
                 free_items int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT c.max_weight_kg, c.max_volume_m3, c.max_items, greatest(c.max_weight_kg - u.weight_kg, 0),
         CASE WHEN c.max_volume_m3 IS NOT NULL THEN greatest(c.max_volume_m3 - u.volume_m3, 0) END,
         CASE WHEN c.max_items IS NOT NULL THEN greatest(c.max_items - u.pieces, 0) END
    FROM ship.trip_cargo_capacity c CROSS JOIN LATERAL ship.trip_cargo_usage(c.trip_id) u
   WHERE c.trip_id = p_trip
$$;
REVOKE ALL ON FUNCTION ship.trip_hold(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ship.trip_hold(bigint) TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION ship.trip_hold IS 'Hold offered on a trip and how much of it is still free (1078)';

-- an offer not accepted in time lapses (worker maintenance)
CREATE OR REPLACE FUNCTION ship.expire_parcel_offers() RETURNS integer LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n integer;
BEGIN
  UPDATE ship.parcel_offer SET status = 'EXPIRED'
   WHERE (status = 'OFFERED' AND valid_until < now())
      OR (status IN ('REQUESTED', 'OFFERED') AND EXISTS (SELECT 1 FROM ops.trip_stop ts WHERE ts.trip_id = parcel_offer.trip_id
                                                         AND ts.seq = parcel_offer.from_seq AND ts.sched_dep < now()));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION ship.expire_parcel_offers() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ship.expire_parcel_offers() TO masslak_app;

-- the carrier's own parcel prices: a permission of its operations role
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('parcels.tariffs', 'ship', 'COMPANY', 'Parcel tariffs of the carrier: by weight, volume, both, fixed or agreed', false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'parcels.tariffs' FROM iam.role r WHERE r.code = 'CARRIER_OPERATIONS'
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ registrations
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ship.parcel_tariff', '3', 'E28'), ('ship.parcel_offer', '3', 'E29')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days) VALUES
  ('ship.parcel_tariff', 'PUBLIC', 'ship', 'Parcel prices each carrier publishes', 'Contract', 3650, 'KEEP_LEGAL', '{replica,backup}', 35),
  ('ship.parcel_offer', 'CONFIDENTIAL', 'ship', 'Prices agreed between a carrier and a customer for a parcel', 'Contract', 2555, 'KEEP_LEGAL', '{replica,backup}', 35)
ON CONFLICT (dataset) DO NOTHING;

SELECT sys.refresh_table_class();

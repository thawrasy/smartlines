-- =====================================================================
-- 1157: vehicle makes and models (owner's request N8)
--   * The platform keeps a list of makes and models. Another person reviews an entry before carriers can pick it, as in
--     the bank and insurer registries (1156).
--   * A carrier that does not find its model sends a request. Platform staff approve it, which adds the model, still
--     waiting for a second person's review. Or they reject it with a reason, or point it to a model already in the list.
--   * A vehicle picks its model from the list. The make and model names are copied onto the vehicle, so old rows and
--     reports keep reading them.
-- =====================================================================

CREATE TABLE IF NOT EXISTS ref.vehicle_make (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid(),
  code                text NOT NULL CHECK (code ~ '^[A-Z0-9]{2,16}$'),
  name_en             text NOT NULL CHECK (length(name_en) BETWEEN 2 AND 80),
  name_ar             text NOT NULL CHECK (length(name_ar) BETWEEN 2 AND 80),
  country_code        char(2) REFERENCES ref.country(code),
  status              text NOT NULL DEFAULT 'PENDING_REVIEW' CHECK (status IN ('PENDING_REVIEW', 'ACTIVE', 'REJECTED', 'RETIRED')),
  source              text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL', 'IMPORT', 'REQUEST')),
  entered_by          bigint NOT NULL REFERENCES iam.app_user(id),
  reviewed_by         bigint REFERENCES iam.app_user(id),
  reviewed_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vehicle_make_review_ck CHECK (reviewed_by IS NULL OR reviewed_by <> entered_by),
  CONSTRAINT vehicle_make_active_ck CHECK (status <> 'ACTIVE' OR reviewed_by IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_make_uid_uq ON ref.vehicle_make (uid);
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_make_code_uq ON ref.vehicle_make (code);
CREATE INDEX IF NOT EXISTS vehicle_make_country_code_fkx ON ref.vehicle_make (country_code);
CREATE INDEX IF NOT EXISTS vehicle_make_entered_by_fkx ON ref.vehicle_make (entered_by);
CREATE INDEX IF NOT EXISTS vehicle_make_reviewed_by_fkx ON ref.vehicle_make (reviewed_by);
COMMENT ON TABLE ref.vehicle_make IS 'Vehicle makes kept by the platform and reviewed by a second person (1157, N8)';

CREATE TABLE IF NOT EXISTS ref.vehicle_model (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid(),
  make_id             bigint NOT NULL REFERENCES ref.vehicle_make(id),
  name                text NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  vehicle_class       text NOT NULL DEFAULT 'BUS' CHECK (vehicle_class IN ('BUS', 'TRUCK', 'TRAIN', 'CAR', 'OTHER')),
  vehicle_type        text NOT NULL CHECK (vehicle_type IN ('COACH', 'MINIBUS', 'CITY_BUS', 'VAN', 'TRAIN_SET', 'OTHER')),
  seats_from          smallint CHECK (seats_from IS NULL OR seats_from BETWEEN 1 AND 120),
  seats_to            smallint CHECK (seats_to IS NULL OR seats_to BETWEEN 1 AND 120),
  weight_class        text CHECK (weight_class IS NULL OR weight_class IN ('LIGHT', 'MEDIUM', 'HEAVY')),
  production          text NOT NULL DEFAULT 'CURRENT' CHECK (production IN ('CURRENT', 'OLDER')),
  confidence          text NOT NULL DEFAULT 'VERIFY' CHECK (confidence IN ('HIGH', 'MEDIUM', 'VERIFY')),
  notes               text CHECK (notes IS NULL OR length(notes) <= 500),
  status              text NOT NULL DEFAULT 'PENDING_REVIEW' CHECK (status IN ('PENDING_REVIEW', 'ACTIVE', 'REJECTED', 'RETIRED')),
  source              text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL', 'IMPORT', 'REQUEST')),
  entered_by          bigint NOT NULL REFERENCES iam.app_user(id),
  reviewed_by         bigint REFERENCES iam.app_user(id),
  reviewed_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vehicle_model_seats_ck CHECK (seats_from IS NULL OR seats_to IS NULL OR seats_to >= seats_from),
  CONSTRAINT vehicle_model_weight_ck CHECK (weight_class IS NULL OR vehicle_class = 'TRUCK'),
  CONSTRAINT vehicle_model_review_ck CHECK (reviewed_by IS NULL OR reviewed_by <> entered_by),
  CONSTRAINT vehicle_model_active_ck CHECK (status <> 'ACTIVE' OR reviewed_by IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_model_uid_uq ON ref.vehicle_model (uid);
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_model_name_uq ON ref.vehicle_model (make_id, lower(name), vehicle_type) WHERE status <> 'REJECTED';
CREATE INDEX IF NOT EXISTS vehicle_model_make_id_fkx ON ref.vehicle_model (make_id);
CREATE INDEX IF NOT EXISTS vehicle_model_entered_by_fkx ON ref.vehicle_model (entered_by);
CREATE INDEX IF NOT EXISTS vehicle_model_reviewed_by_fkx ON ref.vehicle_model (reviewed_by);
COMMENT ON TABLE ref.vehicle_model IS 'Vehicle models of a make: kind, approximate seats or truck weight class, whether still made and how sure the name is; reviewed by a second person (1157, N8)';

-- a carrier asks for a model missing from the list
CREATE TABLE IF NOT EXISTS fleet.vehicle_model_request (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid(),
  company_id          bigint NOT NULL REFERENCES iam.company(id),
  requested_by        bigint NOT NULL REFERENCES iam.app_user(id),
  make_id             bigint REFERENCES ref.vehicle_make(id),
  make_name           text CHECK (make_name IS NULL OR length(make_name) BETWEEN 2 AND 80),
  model_name          text NOT NULL CHECK (length(model_name) BETWEEN 1 AND 80),
  vehicle_type        text NOT NULL CHECK (vehicle_type IN ('COACH', 'MINIBUS', 'CITY_BUS', 'VAN', 'TRAIN_SET', 'OTHER')),
  seats               smallint CHECK (seats IS NULL OR seats BETWEEN 1 AND 120),
  note                text CHECK (note IS NULL OR length(note) <= 500),
  status              text NOT NULL DEFAULT 'SUBMITTED' CHECK (status IN ('SUBMITTED', 'APPROVED', 'MATCHED', 'REJECTED', 'WITHDRAWN')),
  model_id            bigint REFERENCES ref.vehicle_model(id),
  handled_by          bigint REFERENCES iam.app_user(id),
  handled_at          timestamptz,
  decision_note       text CHECK (decision_note IS NULL OR length(decision_note) BETWEEN 3 AND 300),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vehicle_model_request_make_ck CHECK (make_id IS NOT NULL OR make_name IS NOT NULL),
  CONSTRAINT vehicle_model_request_model_ck CHECK ((status IN ('APPROVED', 'MATCHED')) = (model_id IS NOT NULL)),
  CONSTRAINT vehicle_model_request_handled_ck CHECK (status IN ('SUBMITTED', 'WITHDRAWN') OR (handled_by IS NOT NULL AND handled_at IS NOT NULL)),
  CONSTRAINT vehicle_model_request_reject_ck CHECK (status <> 'REJECTED' OR decision_note IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_model_request_uid_uq ON fleet.vehicle_model_request (uid);
CREATE INDEX IF NOT EXISTS vehicle_model_request_company_id_fkx ON fleet.vehicle_model_request (company_id);
CREATE INDEX IF NOT EXISTS vehicle_model_request_requested_by_fkx ON fleet.vehicle_model_request (requested_by);
CREATE INDEX IF NOT EXISTS vehicle_model_request_make_id_fkx ON fleet.vehicle_model_request (make_id);
CREATE INDEX IF NOT EXISTS vehicle_model_request_model_id_fkx ON fleet.vehicle_model_request (model_id);
CREATE INDEX IF NOT EXISTS vehicle_model_request_handled_by_fkx ON fleet.vehicle_model_request (handled_by);
CREATE INDEX IF NOT EXISTS vehicle_model_request_open_ix ON fleet.vehicle_model_request (created_at) WHERE status = 'SUBMITTED';
COMMENT ON TABLE fleet.vehicle_model_request IS
  'A carrier''s request for a vehicle model missing from the list; platform staff approve, match to an existing model or reject (1157, N8)';

DROP TRIGGER IF EXISTS vehicle_make_updated ON ref.vehicle_make;
CREATE TRIGGER vehicle_make_updated BEFORE UPDATE ON ref.vehicle_make FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
DROP TRIGGER IF EXISTS vehicle_model_updated ON ref.vehicle_model;
CREATE TRIGGER vehicle_model_updated BEFORE UPDATE ON ref.vehicle_model FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
DROP TRIGGER IF EXISTS vehicle_model_request_updated ON fleet.vehicle_model_request;
CREATE TRIGGER vehicle_model_request_updated BEFORE UPDATE ON fleet.vehicle_model_request FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();

SELECT sys.rls('ref.vehicle_make', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('ref.vehicle_model', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('fleet.vehicle_model_request', 'sys.tenant_visible(company_id)');
ALTER TABLE fleet.vehicle_model_request FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON ref.vehicle_make, ref.vehicle_model, fleet.vehicle_model_request TO masslak_app;

-- ------------------------------------------------------------------ vehicles pick their model
ALTER TABLE fleet.vehicle ADD COLUMN IF NOT EXISTS model_id bigint REFERENCES ref.vehicle_model(id);
CREATE INDEX IF NOT EXISTS vehicle_model_id_fkx ON fleet.vehicle (model_id);
COMMENT ON COLUMN fleet.vehicle.model_id IS 'The model chosen from the platform''s list (1157, N8); make and model keep the names written on old rows';

CREATE OR REPLACE FUNCTION fleet.tg_vehicle_model() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_make text; v_model text;
BEGIN
  IF NEW.model_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.model_id IS DISTINCT FROM OLD.model_id) THEN
    SELECT k.name_en, m.name INTO v_make, v_model
      FROM ref.vehicle_model m JOIN ref.vehicle_make k ON k.id = m.make_id
     WHERE m.id = NEW.model_id AND m.status = 'ACTIVE' AND k.status = 'ACTIVE';
    IF v_model IS NULL THEN
      RAISE EXCEPTION 'MODEL_UNKNOWN: choose a reviewed vehicle model from the list' USING ERRCODE = 'P0001';
    END IF;
    NEW.make := v_make;
    NEW.model := v_model;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS vehicle_model_pick ON fleet.vehicle;
CREATE TRIGGER vehicle_model_pick BEFORE INSERT OR UPDATE OF model_id ON fleet.vehicle
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_vehicle_model();

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ref.vehicle_make', '1A', 'E01'), ('ref.vehicle_model', '1A', 'E01'), ('fleet.vehicle_model_request', '1A', 'E06')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ref.vehicle_make', 'ref catalog', 'vehicle makes (1157)'),
  ('ref.vehicle_model', 'ref catalog', 'vehicle models (1157)'),
  ('fleet.vehicle_model_request', 'fleet records', 'carriers'' requests for a missing vehicle model (1157)')
ON CONFLICT (table_name) DO NOTHING;

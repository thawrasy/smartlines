-- =====================================================================
-- Masslak - 1088: the documents accepted as evidence for a change of the boarding photo, kept as a platform setting
--               (the seventh round, 11 October 2026)
--
-- The owner's decision: the national identity card is the main document, but not every citizen holds one yet and
-- children do not get one before a certain age, so the platform accepts a civil registry extract (with the photo) or a
-- passport as well, and the list is a setting that the platform changes, not a code change. A kind that is switched off
-- is refused for new requests; requests already made keep their evidence until they are decided or the person is erased.
--
-- Nothing refers to the new table except the evidence column of iam.photo_change_request, which now references it, so the
-- table adds no reference cycle (db/tools/schema_dependencies.py).
-- =====================================================================

-- 1. the kinds of evidence -------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iam.photo_evidence_kind (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code               text NOT NULL UNIQUE CHECK (code ~ '^[A-Z_]{3,40}$'),
  label              text NOT NULL CHECK (length(label) BETWEEN 3 AND 120),
  active             boolean NOT NULL DEFAULT true,
  changed_by_user_id bigint REFERENCES iam.app_user (id),
  changed_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS photo_evidence_kind_changed_by_user_id_fkx ON iam.photo_evidence_kind (changed_by_user_id);
COMMENT ON TABLE iam.photo_evidence_kind IS 'The documents accepted as evidence for a change of the boarding photo; a platform setting (1088)';

SELECT sys.rls_platform('iam.photo_evidence_kind');
GRANT SELECT ON iam.photo_evidence_kind TO masslak_app;

INSERT INTO iam.photo_evidence_kind (code, label) VALUES
  ('CIVIL_REGISTRY_EXTRACT', 'Civil registry extract that carries the photo'),
  ('IDENTITY_DOCUMENT', 'National identity card'),
  ('PASSPORT', 'Passport')
ON CONFLICT (code) DO NOTHING;

-- 2. the requests refer to the setting; an earlier fixed list is replaced by the reference ----------------------------
ALTER TABLE iam.photo_change_request DROP CONSTRAINT photo_change_request_evidence_kind_check;
ALTER TABLE iam.photo_change_request ADD CONSTRAINT photo_change_request_evidence_kind_fk
  FOREIGN KEY (evidence_kind) REFERENCES iam.photo_evidence_kind (code);
CREATE INDEX IF NOT EXISTS photo_change_request_evidence_kind_fkx ON iam.photo_change_request (evidence_kind);

-- 3. the setting is changed by the platform only ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iam.set_photo_evidence_kind(p_code text, p_active boolean) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the documents accepted for a photo change are a platform setting' USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.photo_evidence_kind SET active = p_active, changed_by_user_id = sys.ctx_user_id(), changed_at = now()
   WHERE code = p_code RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: no such kind of evidence' USING ERRCODE = 'P0001';
  END IF;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION iam.set_photo_evidence_kind(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.set_photo_evidence_kind(text, boolean) TO masslak_app;

-- the request refuses a kind that is switched off; the body is the one of 1087 with this check added
CREATE OR REPLACE FUNCTION iam.request_photo_change(p_party_id bigint, p_reason text, p_evidence_kind text,
    p_evidence_file_id bigint, p_photo_file_id bigint) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_uid uuid;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: a photo change is a platform task' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM iam.photo_evidence_kind WHERE code = p_evidence_kind AND active) THEN
    RAISE EXCEPTION 'EVIDENCE_KIND_NOT_ACCEPTED: this document is not accepted as evidence now' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_change_request (party_id, requested_by_user_id, reason, evidence_kind, evidence_file_id, photo_file_id)
  VALUES (p_party_id, sys.ctx_user_id(), p_reason, p_evidence_kind, p_evidence_file_id, p_photo_file_id)
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- 4. the lifecycle of the new table (1079) ---------------------------------------------------------------------------
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('iam.photo_evidence_kind', '1A', 'E01')
ON CONFLICT (table_name) DO NOTHING;
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('iam.photo_evidence_kind', 'PLATFORM_CONFIDENTIAL', NULL, 'the documents accepted for a photo change (1088)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.photo_evidence_kind', 'gov records', 'the documents a person may show to change a boarding photo (1088)');

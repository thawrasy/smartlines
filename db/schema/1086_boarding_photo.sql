-- =====================================================================
-- Masslak - 1086: the boarding photo (the owner's decisions of 10 and 11 October 2026)
--
-- A photo of a person is taken when the profile is created: the person takes their own, and the head of a family takes
-- a member's. It is kept while the account exists (closing the account keeps it, 1085) and removed only by an erasure
-- request: gov.erase_party_photo deletes the row and the file row in the erasure's transaction, and the store's sweep
-- deletes the bytes after its 24-hour grace period (files_sweep). The driver of the trip and the carrier's office read
-- it at boarding, and every read is audited by the API.
--
-- The photo is a table of its own, one row per person, so the person keeps no foreign key to the file and the file
-- keeps none back to the person: nothing refers to iam.party_photo, so it adds no reference cycle (db/tools/
-- schema_dependencies.py). The bytes are encrypted in the file store like every file (ref.file_object, RESTRICTED).
-- =====================================================================

CREATE TABLE IF NOT EXISTS iam.party_photo (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid              uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  party_id         bigint NOT NULL UNIQUE REFERENCES iam.party (id),              -- one photo per person
  file_id          bigint NOT NULL REFERENCES ref.file_object (id),
  taken_by         text NOT NULL CHECK (taken_by IN ('SELF', 'HEAD_OF_FAMILY')),
  taken_by_user_id bigint NOT NULL REFERENCES iam.app_user (id),
  taken_at         timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS party_photo_file_id_fkx ON iam.party_photo (file_id);
CREATE INDEX IF NOT EXISTS party_photo_taken_by_user_id_fkx ON iam.party_photo (taken_by_user_id);
COMMENT ON TABLE iam.party_photo IS 'The boarding photo of a person (1086): encrypted file, taken at the profile''s creation, removed only by an erasure request';
COMMENT ON COLUMN iam.party_photo.taken_by IS 'SELF: the person; HEAD_OF_FAMILY: the head of the family, for a member';

-- the person sees their own photo; the platform (and the system scope of the boarding reads) sees all of them
SELECT sys.rls('iam.party_photo', 'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()');
GRANT SELECT ON iam.party_photo TO masslak_app;

-- the table's phase, its class and its lifecycle (1079): the same as the party it belongs to, erased with the person
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('iam.party_photo', '1A', 'E01');
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note)
VALUES ('iam.party_photo', 'USER_PRIVATE', 'parent iam.party', 'the boarding photo of a person (1086)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note)
VALUES ('iam.party_photo', 'iam.party', 'the boarding photo is erased with the person (1086)');

-- Takes the first photo of a person (1086). The database checks who may take it: the person themselves, or the head of
-- the family the person belongs to as a member. A photo on file is never replaced here: a change is made by the platform
-- with proof of identity, and it is audited (the decision of 11 October 2026, sixth round).
CREATE OR REPLACE FUNCTION iam.set_party_photo(p_party_id bigint, p_file_id bigint, p_user_id bigint)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_as text;
BEGIN
  IF p_party_id = sys.ctx_party_id() THEN
    v_as := 'SELF';
  ELSIF EXISTS (SELECT 1 FROM iam.family f JOIN iam.family_member m ON m.family_id = f.id
                 WHERE f.head_party_id = sys.ctx_party_id() AND f.status = 'ACTIVE'
                   AND m.party_id = p_party_id AND m.status = 'ACTIVE') THEN
    v_as := 'HEAD_OF_FAMILY';
  ELSE
    RAISE EXCEPTION 'FORBIDDEN: only the person or the head of their family takes the photo' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM iam.party_photo WHERE party_id = p_party_id) THEN
    RAISE EXCEPTION 'PHOTO_EXISTS: a photo is on file and changes only through the platform' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.party_photo (party_id, file_id, taken_by, taken_by_user_id)
       VALUES (p_party_id, p_file_id, v_as, p_user_id);
  RETURN v_as;
END $$;
REVOKE ALL ON FUNCTION iam.set_party_photo(bigint, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.set_party_photo(bigint, bigint, bigint) TO masslak_app;
COMMENT ON FUNCTION iam.set_party_photo IS 'Takes the first boarding photo of a person (1086): the person or the head of their family only; never replaces one';

-- Erasure of the photo (1086): part of the erasure request, in the same transaction as gov.erase_party. The bytes go with
-- the file row: the store's sweep deletes a stored file no row points to, after 24 hours.
CREATE OR REPLACE FUNCTION gov.erase_party_photo(p_party_id bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_file bigint;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: erasure is a platform task' USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM iam.party_photo WHERE party_id = p_party_id RETURNING file_id INTO v_file;
  IF v_file IS NULL THEN
    RETURN false;
  END IF;
  DELETE FROM ref.file_object WHERE id = v_file;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION gov.erase_party_photo(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gov.erase_party_photo(bigint) TO masslak_app;
COMMENT ON FUNCTION gov.erase_party_photo IS 'Erasure of the boarding photo: deletes the photo row and its file row (1086)';

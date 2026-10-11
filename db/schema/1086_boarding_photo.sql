-- =====================================================================
-- Masslak - 1086: the boarding photo (the owner's decisions of 10 and 11 October 2026)
--
-- A photo of the person is taken when the profile is created: the passenger takes their own, and the head of a family
-- takes the photo of a member. It is kept while the account exists (closing the account keeps it, 1085) and removed
-- only by an erasure request: gov.erase_party_photo clears the reference and deletes the file row, and the store's
-- sweep deletes the bytes after its 24-hour grace period (files_sweep). The photo is shown to the driver and to the
-- carrier's office at boarding, and to nobody else; every view is audited by the API.
-- The bytes are encrypted in the file store like every other file (ref.file_object, data class RESTRICTED).
-- =====================================================================

ALTER TABLE iam.party
  ADD COLUMN IF NOT EXISTS photo_file_id bigint REFERENCES ref.file_object (id),
  ADD COLUMN IF NOT EXISTS photo_taken_at timestamptz,
  ADD COLUMN IF NOT EXISTS photo_taken_by_user_id bigint REFERENCES iam.app_user (id),
  ADD COLUMN IF NOT EXISTS photo_taken_by text CHECK (photo_taken_by IN ('SELF', 'HEAD_OF_FAMILY'));

ALTER TABLE iam.party ADD CONSTRAINT party_photo_complete CHECK (
  (photo_file_id IS NULL) = (photo_taken_at IS NULL)
  AND (photo_file_id IS NULL) = (photo_taken_by IS NULL));

CREATE INDEX IF NOT EXISTS party_photo_file_id_fkx ON iam.party (photo_file_id);
CREATE INDEX IF NOT EXISTS party_photo_taken_by_user_id_fkx ON iam.party (photo_taken_by_user_id);

COMMENT ON COLUMN iam.party.photo_file_id IS 'The boarding photo of this person (encrypted file, RESTRICTED); removed only by gov.erase_party_photo';
COMMENT ON COLUMN iam.party.photo_taken_at IS 'When the photo was taken or replaced';
COMMENT ON COLUMN iam.party.photo_taken_by_user_id IS 'The account that uploaded the photo';
COMMENT ON COLUMN iam.party.photo_taken_by IS 'SELF: the person; HEAD_OF_FAMILY: the head of the family, for a member';

-- Erasure of the photo (1086): part of the erasure request, in the same transaction as gov.erase_party. The bytes go
-- with the file row: the store's sweep deletes a stored file no row points to, after 24 hours.
CREATE OR REPLACE FUNCTION gov.erase_party_photo(p_party_id bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_file bigint;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: erasure is a platform task' USING ERRCODE = 'P0001';
  END IF;
  SELECT photo_file_id INTO v_file FROM iam.party WHERE id = p_party_id FOR UPDATE;
  IF v_file IS NULL THEN
    RETURN false;
  END IF;
  UPDATE iam.party SET photo_file_id = NULL, photo_taken_at = NULL, photo_taken_by_user_id = NULL, photo_taken_by = NULL
   WHERE id = p_party_id;
  DELETE FROM ref.file_object WHERE id = v_file;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION gov.erase_party_photo(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gov.erase_party_photo(bigint) TO masslak_app;
COMMENT ON FUNCTION gov.erase_party_photo IS 'Erasure of the boarding photo: clears the reference and deletes the file row (1086)';

-- Taking or replacing the photo (1086). The database checks who may do it: the person themselves, or the head of the
-- family the person belongs to as a member. The earlier photo's file row goes with the replacement.
CREATE OR REPLACE FUNCTION iam.set_party_photo(p_party_id bigint, p_file_id bigint, p_user_id bigint)
RETURNS TABLE (replaced_file_id bigint, taken_by text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_old bigint; v_by text;
BEGIN
  IF p_party_id = sys.ctx_party_id() THEN
    v_by := 'SELF';
  ELSIF EXISTS (SELECT 1 FROM iam.family f JOIN iam.family_member m ON m.family_id = f.id
                 WHERE f.head_party_id = sys.ctx_party_id() AND f.status = 'ACTIVE'
                   AND m.party_id = p_party_id AND m.status = 'ACTIVE') THEN
    v_by := 'HEAD_OF_FAMILY';
  ELSE
    RAISE EXCEPTION 'FORBIDDEN: only the person or the head of their family takes the photo' USING ERRCODE = 'P0001';
  END IF;
  SELECT photo_file_id INTO v_old FROM iam.party WHERE id = p_party_id FOR UPDATE;
  UPDATE iam.party SET photo_file_id = p_file_id, photo_taken_at = now(), photo_taken_by_user_id = p_user_id,
                       photo_taken_by = v_by
   WHERE id = p_party_id;
  IF v_old IS NOT NULL THEN
    DELETE FROM ref.file_object WHERE id = v_old;
  END IF;
  RETURN QUERY SELECT v_old, v_by;
END $$;
REVOKE ALL ON FUNCTION iam.set_party_photo(bigint, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.set_party_photo(bigint, bigint, bigint) TO masslak_app;
COMMENT ON FUNCTION iam.set_party_photo IS 'Takes or replaces the boarding photo of a person (1086): the person or the head of their family only';

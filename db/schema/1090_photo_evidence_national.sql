-- =====================================================================
-- Masslak - 1090: the documents accepted nationally for a photo change (the eighth round, addendum)
--
-- The owner's list: the national identity card; a civil registry extract (or its issue) that carries the national number;
-- the passport; a travel document issued by the Syrian missions abroad in place of a passport, for Syrian citizens entering
-- Syria; and, in the first phase only, temporary identity documents issued by several authorities, to be switched off later
-- after the know-your-customer process and the registration of each client against the civil registry.
--
-- The kinds stay settings (iam.photo_evidence_kind, switched on or off by two people, 1089). The age rule of the identity
-- card now applies to each kind that is marked for it (age_rule): the national identity card and the temporary identity
-- document. The travel document is accepted for Syrian citizens only. Whether a civil registry extract carries the national
-- number is checked by the second approver against the person's record; the platform does not read the document.
-- =====================================================================

ALTER TABLE iam.photo_evidence_kind ADD COLUMN IF NOT EXISTS age_rule boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN iam.photo_evidence_kind.age_rule IS 'The age rule of a national identity card applies to this kind (1090)';

UPDATE iam.photo_evidence_kind SET label = 'National identity card', age_rule = true WHERE code = 'IDENTITY_DOCUMENT';
UPDATE iam.photo_evidence_kind SET label = 'Civil registry extract showing the national number' WHERE code = 'CIVIL_REGISTRY_EXTRACT';
UPDATE iam.photo_evidence_kind SET label = 'Passport' WHERE code = 'PASSPORT';

INSERT INTO iam.photo_evidence_kind (code, label, age_rule) VALUES
  ('TRAVEL_DOCUMENT', 'Travel document issued by a Syrian mission abroad, in place of a passport, for Syrian citizens entering Syria', false),
  ('TEMPORARY_ID', 'Temporary identity document issued in the first phase by several authorities; to be switched off later', true)
ON CONFLICT (code) DO NOTHING;

-- the request is checked through this rule: the kind is on; a travel document is for Syrian citizens; a kind with the
-- age rule needs the age in the settings to be met, and a birth date on file for it
CREATE OR REPLACE FUNCTION iam.evidence_accepted(p_party_id bigint, p_kind text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_min integer; v_birth date; v_nat char(2); v_age_rule boolean;
BEGIN
  SELECT age_rule INTO v_age_rule FROM iam.photo_evidence_kind WHERE code = p_kind AND active;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  SELECT nationality, birth_date INTO v_nat, v_birth FROM iam.party WHERE id = p_party_id;
  IF p_kind = 'TRAVEL_DOCUMENT' AND v_nat IS DISTINCT FROM 'SY' THEN
    RETURN false;
  END IF;
  IF v_age_rule THEN
    v_min := (SELECT (value #>> '{}')::integer FROM sys.setting WHERE key = 'photo.identity_card_min_age');
    IF v_min IS NOT NULL AND (v_birth IS NULL OR age(current_date, v_birth) < make_interval(years => v_min)) THEN
      RETURN false;
    END IF;
  END IF;
  RETURN true;
END $$;

-- =====================================================================
-- 1055: the contact centre and AI assistant phase stays closed until its data protection review is approved
--   Launch gate 9 (docs/operations/LAUNCH_GATES.md): the phase switch cannot open without the threat model, the DPIA
--   and the acceptance criteria approved. The phase opens with either of its switches, contact_center or ai_assistant
--   (1046), and the feature flags of 2.8 (950) shipped ai_assistant on, so a fresh install had the phase open.
--   a. both switches are turned off where no approved review exists for them
--   b. switching either on is refused until gov.feature_compliance_review holds an approved decision for that switch,
--      with the DPIA file attached and the approver recorded
-- =====================================================================

CREATE OR REPLACE FUNCTION gov.feature_review_approved(p_feature text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM gov.feature_compliance_review r
                  WHERE r.feature = p_feature AND r.decision IN ('APPROVED', 'APPROVED_WITH_CONDITIONS')
                    AND r.dpia_file_id IS NOT NULL AND r.approved_by IS NOT NULL)
$$;
COMMENT ON FUNCTION gov.feature_review_approved IS 'An approved data protection review with its DPIA file and approver exists for this switch (1055)';
REVOKE EXECUTE ON FUNCTION gov.feature_review_approved(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gov.feature_review_approved(text) TO masslak_app, masslak_readonly, masslak_auditor;

-- ------------------------------------------------------------------ a. close the phase where nothing was approved
UPDATE sys.setting s
   SET value = s.value || ((jsonb_build_object('contact_center', false, 'ai_assistant', false)
                             - (CASE WHEN gov.feature_review_approved('contact_center') THEN 'contact_center' ELSE '' END))
                             - (CASE WHEN gov.feature_review_approved('ai_assistant') THEN 'ai_assistant' ELSE '' END)),
       updated_at = now()
 WHERE s.key = 'features'
   AND ((coalesce((s.value ->> 'contact_center')::boolean, false) AND NOT gov.feature_review_approved('contact_center'))
     OR (coalesce((s.value ->> 'ai_assistant')::boolean, false) AND NOT gov.feature_review_approved('ai_assistant')));

-- ------------------------------------------------------------------ b. no switch-on without the approved review
CREATE OR REPLACE FUNCTION sys.tg_dpia_gated_features() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  k text;
BEGIN
  IF NEW.key <> 'features' THEN
    RETURN NEW;
  END IF;
  FOREACH k IN ARRAY ARRAY['contact_center', 'ai_assistant'] LOOP
    IF coalesce((NEW.value ->> k)::boolean, false)
       AND NOT (TG_OP = 'UPDATE' AND coalesce((OLD.value ->> k)::boolean, false))
       AND NOT gov.feature_review_approved(k) THEN
      RAISE EXCEPTION 'DPIA_REQUIRED: % opens the contact centre and AI phase; record an approved data protection review with its DPIA first', k
        USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION sys.tg_dpia_gated_features IS 'Launch gate 9: the contact centre and AI switches open only after an approved data protection review (1055)';

DROP TRIGGER IF EXISTS a_dpia_gated_features ON sys.setting;
CREATE TRIGGER a_dpia_gated_features BEFORE INSERT OR UPDATE OF value ON sys.setting
  FOR EACH ROW EXECUTE FUNCTION sys.tg_dpia_gated_features();

INSERT INTO sys.schema_migration (version, description)
SELECT '1.36.1', 'Contact centre and AI phase closed until an approved data protection review (launch gate 9)'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.36.1');

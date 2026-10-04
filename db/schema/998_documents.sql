-- =====================================================================
-- 998: company and vehicle documents (study 3.4 onboarding, 16.13 file handling)
--   * Files live outside the database, encrypted with AES-256-GCM; ref.file_object keeps the storage key, size,
--     detected type and SHA-256 for integrity.
--   * Each document and file belongs to a company (company_id) for row-level security.
--   * The platform reviews documents; a document past its expiry date is shown as expired.
-- =====================================================================
ALTER TABLE iam.document ADD COLUMN IF NOT EXISTS company_id bigint REFERENCES iam.company(id);
ALTER TABLE iam.document ADD COLUMN IF NOT EXISTS uploaded_by bigint REFERENCES iam.app_user(id);
ALTER TABLE iam.document ADD COLUMN IF NOT EXISTS review_note text;
CREATE INDEX IF NOT EXISTS document_company_idx ON iam.document (company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS document_review_idx ON iam.document (status, created_at) WHERE status = 'PENDING';
DO $$ BEGIN
  ALTER TABLE iam.document ADD CONSTRAINT document_dates_ck CHECK (expiry_date IS NULL OR issue_date IS NULL OR expiry_date > issue_date);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE iam.document ADD CONSTRAINT document_reviewer_ck CHECK (reviewed_by IS NULL OR reviewed_by <> uploaded_by);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE ref.file_object ADD COLUMN IF NOT EXISTS company_id bigint REFERENCES iam.company(id);

ALTER TABLE iam.document ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS document_isolation ON iam.document;
CREATE POLICY document_isolation ON iam.document
  USING (sys.tenant_visible(company_id)) WITH CHECK (sys.tenant_visible(company_id));
ALTER TABLE ref.file_object ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS file_object_isolation ON ref.file_object;
CREATE POLICY file_object_isolation ON ref.file_object
  USING (sys.tenant_visible(company_id) OR uploaded_by = sys.ctx_user_id())
  WITH CHECK (sys.tenant_visible(company_id) OR uploaded_by = sys.ctx_user_id());

-- Review decisions belong to the platform: a company cannot approve its own documents
CREATE OR REPLACE FUNCTION iam.tg_document_review() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT sys.ctx_is_platform() AND (
       (TG_OP = 'INSERT' AND NEW.status <> 'PENDING') OR
       (TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status)) THEN
    RAISE EXCEPTION 'FORBIDDEN: only the platform reviews documents' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS document_review ON iam.document;
CREATE TRIGGER document_review BEFORE INSERT OR UPDATE ON iam.document FOR EACH ROW EXECUTE FUNCTION iam.tg_document_review();

INSERT INTO sys.schema_migration (version, description)
SELECT '1.7.0', 'Company documents with encrypted file storage and platform review'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.7.0');

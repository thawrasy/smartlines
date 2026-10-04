-- =====================================================================
-- 990: travel agencies (study 3.5 agency portal, 5.6 commissions)
--   * An agency is an iam.company of type AGENCY. It sells tickets of any approved carrier from its prepaid
--     company wallet, within a daily sales limit, and earns a commission funded by the carrier.
--   * The commission is a leaf of the booking's price allocation, held in escrow and released to the agency
--     when the trip completes, like the carrier fare. A cancellation earns commission only on what is kept.
--   * Agency staff see the bookings their agency sold (sales.booking.agency_id) and nothing else.
-- =====================================================================

-- ------------------------------ Agreement ------------------------------
CREATE TABLE IF NOT EXISTS sales.agency_agreement (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  agency_id       bigint NOT NULL REFERENCES iam.company(id),
  commission_bp   integer NOT NULL CHECK (commission_bp BETWEEN 0 AND 2000),   -- basis points of the fares (max 20%)
  daily_limit     bigint NOT NULL CHECK (daily_limit > 0),                     -- minor units sold per local day
  currency        char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','ENDED')),
  valid_from      date NOT NULL DEFAULT current_date,
  created_by      bigint REFERENCES iam.app_user(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS agency_agreement_one_active ON sales.agency_agreement (agency_id) WHERE status <> 'ENDED';
DROP TRIGGER IF EXISTS agency_agreement_updated ON sales.agency_agreement;
CREATE TRIGGER agency_agreement_updated BEFORE UPDATE ON sales.agency_agreement
  FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE sales.agency_agreement IS 'Agency terms: commission in basis points of the fares and a daily sales limit';

GRANT SELECT, INSERT, UPDATE ON sales.agency_agreement TO masslak_app;
GRANT SELECT ON sales.agency_agreement TO masslak_readonly;
ALTER TABLE sales.agency_agreement ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS agreement_read ON sales.agency_agreement;
DROP POLICY IF EXISTS agreement_write ON sales.agency_agreement;
-- The agency reads its own terms; only the platform writes them
CREATE POLICY agreement_read  ON sales.agency_agreement FOR SELECT USING (sys.tenant_visible(agency_id));
CREATE POLICY agreement_write ON sales.agency_agreement FOR ALL USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());

-- ------------------------------ Bookings sold by an agency -------------
ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS agency_id bigint REFERENCES iam.company(id);
ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS contact_mobile text CHECK (contact_mobile ~ '^\+?[0-9]{8,15}$');
CREATE INDEX IF NOT EXISTS booking_agency_idx ON sales.booking (agency_id, created_at DESC) WHERE agency_id IS NOT NULL;
COMMENT ON COLUMN sales.booking.agency_id IS 'Agency that sold the booking; booker_party_id is then the agency and booker_user_id its clerk';
COMMENT ON COLUMN sales.booking.contact_mobile IS 'Traveller contact for an agency sale (ticket delivery and trip changes)';

DROP POLICY IF EXISTS booking_isolation ON sales.booking;
CREATE POLICY booking_isolation ON sales.booking
  USING (sys.tenant_visible(company_id) OR booker_party_id = sys.ctx_party_id()
         OR (agency_id IS NOT NULL AND sys.ctx_scope() = 'AGENCY' AND agency_id = sys.ctx_company_id()))
  WITH CHECK (sys.tenant_visible(company_id) OR booker_party_id = sys.ctx_party_id()
         OR (agency_id IS NOT NULL AND sys.ctx_scope() = 'AGENCY' AND agency_id = sys.ctx_company_id()));

INSERT INTO sales.channel (code, channel_type) VALUES ('AGENCY', 'AGENCY') ON CONFLICT (code) DO NOTHING;

-- ------------------------------ Roles ----------------------------------
INSERT INTO iam.role (code, name, scope, is_system)
SELECT x.code, x.name, 'COMPANY', true
  FROM (VALUES ('AGENCY_SELLER', 'Agency seller (template)'), ('AGENCY_ACCOUNTANT', 'Agency accountant (template)')) AS x(code, name)
 WHERE NOT EXISTS (SELECT 1 FROM iam.role r WHERE r.code = x.code AND r.company_id IS NULL);

INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, x.p FROM iam.role r JOIN (VALUES
  ('AGENCY_SELLER', 'trip.search'), ('AGENCY_SELLER', 'booking.on_behalf'),
  ('AGENCY_ACCOUNTANT', 'report.company'), ('AGENCY_ACCOUNTANT', 'company.billing')
) AS x(r, p) ON x.r = r.code AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.4.0', 'Two-factor sign-in (980) and travel agencies (990)'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.4.0');

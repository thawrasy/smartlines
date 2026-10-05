-- =====================================================================
-- 1032: travel documents for international trips (study 11.9, revised in v2.7)
--   A trip segment that ends in, or passes through, another country is international. Every passenger on it
--   travels on a valid passport unless the platform has approved an exception for that destination (or transit)
--   country and the passenger's nationality, naming the other documents accepted there (national ID, residence
--   permit, laissez-passer, travel document). Exceptions are entry rules: drafted by one platform officer,
--   approved by another (four-eyes), optionally limited to a period and always citing their legal basis.
--   Without an active rule the platform default applies: passport, valid at least 180 days after departure.
-- =====================================================================

-- Document types accepted anywhere in the platform
ALTER TABLE sales.passenger DROP CONSTRAINT IF EXISTS passenger_id_type_check;
ALTER TABLE sales.passenger ADD CONSTRAINT passenger_id_type_check
  CHECK (id_type IN ('NATIONAL_ID','PASSPORT','RESIDENCE','LAISSEZ_PASSER','TRAVEL_DOCUMENT','OTHER'));

ALTER TABLE sales.entry_rule ADD COLUMN IF NOT EXISTS valid daterange;            -- empty: open-ended
ALTER TABLE sales.entry_rule ADD COLUMN IF NOT EXISTS legal_basis text;          -- agreement, decree or circular
ALTER TABLE sales.entry_rule ADD COLUMN IF NOT EXISTS note text;                 -- shown to travellers at checkout
DO $$ BEGIN
  ALTER TABLE sales.entry_rule ADD CONSTRAINT entry_rule_docs_known
    CHECK (cardinality(doc_required) >= 1
           AND doc_required <@ ARRAY['PASSPORT','NATIONAL_ID','RESIDENCE','LAISSEZ_PASSER','TRAVEL_DOCUMENT','OTHER']::text[]);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  -- an exception (any document other than a passport) must say on what authority it is granted
  ALTER TABLE sales.entry_rule ADD CONSTRAINT entry_rule_exception_basis
    CHECK (doc_required = ARRAY['PASSPORT']::text[] OR length(coalesce(legal_basis, '')) >= 5) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON COLUMN sales.entry_rule.doc_required IS 'Documents accepted, any one of them: PASSPORT alone is the default; others make the rule an exception';
COMMENT ON COLUMN sales.entry_rule.valid IS 'Period in which the rule applies (departure date); empty means no end';
COMMENT ON COLUMN sales.entry_rule.legal_basis IS 'Agreement, decree or circular that allows the exception';

-- Only one active rule per country, role and nationality may apply on a given day
CREATE INDEX IF NOT EXISTS entry_rule_lookup ON sales.entry_rule (country_code, country_role, nationality) WHERE status = 'ACTIVE';

-- Platform default when no rule matches
INSERT INTO sys.setting (key, value, description)
VALUES ('travel.international_default', '{"docs": ["PASSPORT"], "passport_min_days": 180, "enforcement": "BLOCK"}',
        'Documents required on international trips when no entry rule matches (11.9)')
ON CONFLICT (key) DO NOTHING;

-- Ticket documents carry the passport validity checked at booking and the document type used
ALTER TABLE sales.ticket_doc ADD COLUMN IF NOT EXISTS doc_type text
  CHECK (doc_type IN ('NATIONAL_ID','PASSPORT','RESIDENCE','LAISSEZ_PASSER','TRAVEL_DOCUMENT','OTHER'));
ALTER TABLE sales.ticket_doc ADD COLUMN IF NOT EXISTS exception boolean NOT NULL DEFAULT false;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.15.0', 'Passport required on international trips, with approved document exceptions'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.15.0');

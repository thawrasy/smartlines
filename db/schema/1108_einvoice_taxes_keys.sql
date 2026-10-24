-- =====================================================================
-- Masslak - 1108: taxes on e-invoices from the platform's tax schemes, and signing keys named on every document
-- (owner's decisions, October 2026)
--
-- Taxes. The platform defines its taxes as schemes (pricing.tax_scheme, one tax each: VAT, sales tax, a local levy, a
-- stamp duty ...) with rules (pricing.tax_rule) and bands (pricing.rate_band). A scheme's treatment says whether a
-- sale is OUT_OF_SCOPE, EXEMPT, ZERO-rated, STANDARD (taxed by its rules) or REVERSE charged. Its scope says what it
-- applies to: {"products": ["TICKET", "BOOKING_FEE"], "sellers": ["CARRIER", "PLATFORM"], "company_ids": [..],
-- "origin_cities": ["DAM", ..]} (each key optional; a local tax names the cities it is levied in), within its
-- jurisdiction's country. A rule takes a rate (PERCENT), an amount (FIXED, per ticket or once per booking), or bands
-- (TIERED: the band the base falls in, WHOLE, or each band's share of the base, MARGINAL), with a minimum, a maximum
-- and a rounding. Its base is the line's net amount (base_type FARE) plus the taxes it names in base_include, or only
-- those taxes (base_type TAXES): a sales tax and a VAT compound, and a levy on the VAT for another authority is a rule
-- with base_type TAXES and base_include ["VAT"]. Within a scheme, compound_mode combines its rules (ADD, MAX, MIN, or
-- CASCADE: each rule's base includes the scheme's earlier rules). Prices on the platform include their taxes: the
-- issuer finds the net amount whose taxes make up the price paid. Each tax of each line is kept on the invoice
-- (acct.einvoice_line_tax) with its scheme, rate, base, amount and the authority it is owed to, and enters the hash.
-- A credit note takes back each tax of the original invoice in proportion. The setting einvoice.tax_rate_pct (one rate
-- for everything, 1104) is retired: with no active scheme a sale is out of scope.
--
-- Keys. Every e-invoice names the key that signed it (signing_kid) and the key id enters the hash, so keys can be
-- rotated while every document keeps verifying: MASSLAK_EINVOICE_KEYS lists kid:seed pairs, the first signs, all
-- verify. The public key of every key that ever signed is kept (acct.einvoice_signing_key) and published at
-- /api/public/keys/einvoice, so a document stays verifiable after its private key is retired. Documents before this
-- file stay in canonical version 1 (no key id, one tax per line) and verify as they were issued.
-- =====================================================================

-- ------------------------------------------------------------------ documents: canonical version and signing key
ALTER TABLE acct.einvoice_document ADD COLUMN IF NOT EXISTS canonical_version smallint NOT NULL DEFAULT 1;
ALTER TABLE acct.einvoice_document ADD COLUMN IF NOT EXISTS signing_kid text;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'acct.einvoice_document'::regclass AND conname = 'einvoice_document_canonical_check') THEN
    ALTER TABLE acct.einvoice_document ADD CONSTRAINT einvoice_document_canonical_check
      CHECK (canonical_version IN (1, 2) AND (canonical_version = 1 OR signing_kid IS NOT NULL));
  END IF;
END $$;
COMMENT ON COLUMN acct.einvoice_document.canonical_version IS 'The form that is hashed: 1 before 1108 (one tax per line, no key id), 2 with each line''s taxes and the key id (1108)';
COMMENT ON COLUMN acct.einvoice_document.signing_kid IS 'The key that signed the document (acct.einvoice_signing_key); part of the hashed content from version 2 (1108)';

CREATE TABLE IF NOT EXISTS acct.einvoice_signing_key (
  kid            text PRIMARY KEY CHECK (kid ~ '^[a-z0-9]{1,12}$'),
  algorithm      text NOT NULL DEFAULT 'Ed25519' CHECK (algorithm = 'Ed25519'),
  public_key     text NOT NULL UNIQUE CHECK (length(public_key) BETWEEN 40 AND 60),
  first_used_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE acct.einvoice_signing_key IS 'Public key of every key that signed an e-invoice, kept for verification after the private key is retired (1108)';
SELECT sys.rls_catalog('acct.einvoice_signing_key');
GRANT SELECT, INSERT ON acct.einvoice_signing_key TO masslak_app;
GRANT SELECT ON acct.einvoice_signing_key TO masslak_readonly;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'acct.einvoice_document'::regclass AND conname = 'einvoice_document_signing_kid_fkey') THEN
    ALTER TABLE acct.einvoice_document ADD CONSTRAINT einvoice_document_signing_kid_fkey
      FOREIGN KEY (signing_kid) REFERENCES acct.einvoice_signing_key(kid);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS einvoice_document_signing_kid_fkx ON acct.einvoice_document (signing_kid);

-- ------------------------------------------------------------------ each tax of each line
CREATE TABLE IF NOT EXISTS acct.einvoice_line_tax (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id              bigint NOT NULL REFERENCES acct.einvoice_line(id),
  seq                  smallint NOT NULL CHECK (seq > 0),
  tax_scheme_id        bigint REFERENCES pricing.tax_scheme(id),
  scheme_code          text NOT NULL CHECK (length(scheme_code) BETWEEN 1 AND 40),
  tax_type             text NOT NULL CHECK (tax_type IN ('VAT','SALES','LEVY','FEE','STAMP','WITHHOLDING','OTHER')),
  treatment            text NOT NULL CHECK (treatment IN ('STANDARD','ZERO','EXEMPT','OUT_OF_SCOPE','REVERSE')),
  rate                 numeric(9,6) NOT NULL DEFAULT 0,
  base                 bigint NOT NULL CHECK (base >= 0),
  amount               bigint NOT NULL CHECK (amount >= 0),
  payable_to_party_id  bigint REFERENCES iam.party(id),
  UNIQUE (line_id, seq),
  CHECK (treatment = 'STANDARD' OR amount = 0)
);
CREATE INDEX IF NOT EXISTS einvoice_line_tax_tax_scheme_id_fkx ON acct.einvoice_line_tax (tax_scheme_id);
CREATE INDEX IF NOT EXISTS einvoice_line_tax_payable_to_party_id_fkx ON acct.einvoice_line_tax (payable_to_party_id);
COMMENT ON TABLE acct.einvoice_line_tax IS 'Each tax of an e-invoice line: scheme, treatment, rate, base, amount and the authority it is owed to; fixed once the document is final (1108)';
ALTER TABLE acct.einvoice_line_tax ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS isolation ON acct.einvoice_line_tax;
CREATE POLICY isolation ON acct.einvoice_line_tax
  USING (EXISTS (SELECT 1 FROM acct.einvoice_line l WHERE l.id = einvoice_line_tax.line_id));
GRANT SELECT, INSERT ON acct.einvoice_line_tax TO masslak_app;
GRANT SELECT ON acct.einvoice_line_tax TO masslak_readonly;

CREATE OR REPLACE FUNCTION acct.tg_einvoice_line_tax_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE st text;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: the taxes of an e-invoice line are written once' USING ERRCODE = 'P0001';
  END IF;
  SELECT d.status INTO st FROM acct.einvoice_line l JOIN acct.einvoice_document d ON d.id = l.document_id WHERE l.id = NEW.line_id;
  IF st <> 'DRAFT' THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: taxes of a finalized e-invoice' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS einvoice_line_tax_guard ON acct.einvoice_line_tax;
CREATE TRIGGER einvoice_line_tax_guard BEFORE INSERT OR UPDATE OR DELETE ON acct.einvoice_line_tax
  FOR EACH ROW EXECUTE FUNCTION acct.tg_einvoice_line_tax_guard();

-- ------------------------------------------------------------------ the rules the issuer can compute
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'pricing.tax_rule'::regclass AND conname = 'tax_rule_base_type_check') THEN
    ALTER TABLE pricing.tax_rule ADD CONSTRAINT tax_rule_base_type_check CHECK (base_type IN ('FARE', 'TAXES'));
    ALTER TABLE pricing.tax_rule ADD CONSTRAINT tax_rule_rounding_check CHECK (rounding_rule IN ('HALF_UP', 'HALF_EVEN', 'DOWN', 'UP'));
    ALTER TABLE pricing.tax_rule ADD CONSTRAINT tax_rule_terms_check CHECK (
      (calc_method = 'PERCENT' AND rate IS NOT NULL AND rate >= 0 AND rate <= 100)
      OR (calc_method = 'FIXED' AND amount IS NOT NULL AND amount >= 0)
      OR calc_method IN ('TIERED', 'FORMULA'));
    ALTER TABLE pricing.tax_rule ADD CONSTRAINT tax_rule_limits_check
      CHECK (min_amount IS NULL OR max_amount IS NULL OR min_amount <= max_amount);
  END IF;
END $$;
COMMENT ON COLUMN pricing.tax_rule.base_type IS 'FARE: the line''s net amount plus the taxes named in base_include; TAXES: only those taxes (a tax on a tax) (1108)';
COMMENT ON COLUMN pricing.tax_rule.base_include IS 'Codes of the schemes whose tax on the same line is added to the base, for compound taxes and taxes on taxes (1108)';

-- a scheme goes live only when the issuer can compute it: rules that fit its treatment, bands for tiered rules, no
-- formula rule, and taxes on taxes that name other active or pending schemes without a loop
CREATE OR REPLACE FUNCTION pricing.tg_tax_scheme_check() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_bad text;
BEGIN
  IF NEW.status <> 'ACTIVE' OR (TG_OP = 'UPDATE' AND OLD.status = 'ACTIVE') THEN
    RETURN NEW;
  END IF;
  IF NEW.approved_by IS NULL THEN
    RAISE EXCEPTION 'TAX_SCHEME_UNAPPROVED: a second officer approves a tax scheme before it applies' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.treatment = 'STANDARD' AND NOT EXISTS (SELECT 1 FROM pricing.tax_rule WHERE scheme_id = NEW.id) THEN
    RAISE EXCEPTION 'TAX_SCHEME_RULES: a standard-rated scheme needs at least one rule' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM pricing.tax_rule WHERE scheme_id = NEW.id AND calc_method = 'FORMULA') THEN
    RAISE EXCEPTION 'TAX_SCHEME_RULES: formula rules are not computed by the issuer; use percent, fixed or tiered rules' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM pricing.tax_rule r WHERE r.scheme_id = NEW.id AND r.calc_method = 'TIERED'
               AND NOT EXISTS (SELECT 1 FROM pricing.rate_band b WHERE b.tax_rule_id = r.id)) THEN
    RAISE EXCEPTION 'TAX_SCHEME_RULES: a tiered rule needs its bands' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM pricing.tax_rule r WHERE r.scheme_id = NEW.id AND r.base_type = 'TAXES'
               AND jsonb_array_length(coalesce(r.base_include, '[]')) = 0) THEN
    RAISE EXCEPTION 'TAX_SCHEME_RULES: a tax on taxes names the taxes it is levied on (base_include)' USING ERRCODE = 'P0001';
  END IF;
  SELECT string_agg(code, ', ') INTO v_bad
    FROM (SELECT DISTINCT jsonb_array_elements_text(r.base_include) AS code FROM pricing.tax_rule r WHERE r.scheme_id = NEW.id) x
   WHERE x.code = NEW.code OR NOT EXISTS (SELECT 1 FROM pricing.tax_scheme s WHERE s.code = x.code AND s.status IN ('ACTIVE', 'PENDING'));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'TAX_SCHEME_RULES: the base names unknown taxes or the scheme itself (%)', v_bad USING ERRCODE = 'P0001';
  END IF;
  -- no loop: following base_include from this scheme never comes back to it
  IF EXISTS (
    WITH RECURSIVE dep(code, path) AS (
      SELECT x.code, ARRAY[NEW.code]
        FROM (SELECT DISTINCT jsonb_array_elements_text(r.base_include) AS code FROM pricing.tax_rule r WHERE r.scheme_id = NEW.id) x
      UNION
      SELECT y.code, d.path || d.code
        FROM dep d JOIN pricing.tax_scheme s ON s.code = d.code AND s.status IN ('ACTIVE', 'PENDING')
        JOIN LATERAL (SELECT DISTINCT jsonb_array_elements_text(r.base_include) AS code FROM pricing.tax_rule r WHERE r.scheme_id = s.id) y ON true
       WHERE NOT d.code = ANY (d.path) AND cardinality(d.path) < 20)
    SELECT 1 FROM dep WHERE code = NEW.code) THEN
    RAISE EXCEPTION 'TAX_SCHEME_RULES: these taxes are levied on each other in a loop' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS tax_scheme_check ON pricing.tax_scheme;
CREATE TRIGGER tax_scheme_check BEFORE INSERT OR UPDATE ON pricing.tax_scheme
  FOR EACH ROW EXECUTE FUNCTION pricing.tg_tax_scheme_check();

-- an active scheme's rules and bands are not changed under it: retire it and record a new version
CREATE OR REPLACE FUNCTION pricing.tg_tax_rule_frozen() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_scheme bigint;
BEGIN
  IF TG_TABLE_NAME = 'tax_rule' THEN
    v_scheme := coalesce(NEW.scheme_id, OLD.scheme_id);
  ELSIF coalesce(NEW.tax_rule_id, OLD.tax_rule_id) IS NULL THEN
    RETURN coalesce(NEW, OLD);                              -- a commission band
  ELSE
    SELECT scheme_id INTO v_scheme FROM pricing.tax_rule WHERE id = coalesce(NEW.tax_rule_id, OLD.tax_rule_id);
  END IF;
  IF v_scheme IS NOT NULL AND EXISTS (SELECT 1 FROM pricing.tax_scheme WHERE id = v_scheme AND status IN ('ACTIVE', 'RETIRED')) THEN
    RAISE EXCEPTION 'TAX_SCHEME_FROZEN: the rules of an active or retired tax scheme do not change; record a new version' USING ERRCODE = 'P0001';
  END IF;
  RETURN coalesce(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS tax_rule_frozen ON pricing.tax_rule;
CREATE TRIGGER tax_rule_frozen BEFORE INSERT OR UPDATE OR DELETE ON pricing.tax_rule
  FOR EACH ROW EXECUTE FUNCTION pricing.tg_tax_rule_frozen();
DROP TRIGGER IF EXISTS rate_band_tax_frozen ON pricing.rate_band;
CREATE TRIGGER rate_band_tax_frozen BEFORE INSERT OR UPDATE OR DELETE ON pricing.rate_band
  FOR EACH ROW EXECUTE FUNCTION pricing.tg_tax_rule_frozen();

UPDATE sys.json_contract SET spec = '{"type": "object", "properties": {"products": {"type": "array"}, "sellers": {"type": "array"}, "company_ids": {"type": "array"}, "origin_cities": {"type": "array"}}, "additionalProperties": false}'::jsonb,
       note = 'What a tax applies to: products (TICKET, BOOKING_FEE), sellers (CARRIER, PLATFORM), carriers, origin cities (1108)'
 WHERE table_name = 'pricing.tax_scheme' AND column_name = 'scope';
UPDATE sys.json_contract SET spec = '{"type": "array", "items": {"type": "string"}}'::jsonb,
       note = 'Codes of the taxes added to the rule''s base (compound taxes, taxes on taxes) (1108)'
 WHERE table_name = 'pricing.tax_rule' AND column_name = 'base_include';
SELECT sys.apply_json_contracts();

-- one rate for everything (1104) gives way to the schemes
DELETE FROM sys.setting WHERE key = 'einvoice.tax_rate_pct';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('acct.einvoice_line_tax', '1B', 'E14'), ('acct.einvoice_signing_key', '1B', 'E14')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('acct.einvoice_line_tax', 'TENANT_PRIVATE', 'parent acct.einvoice_line', 'the taxes of each e-invoice line (1108)'),
  ('acct.einvoice_signing_key', 'PUBLIC_CATALOG', 'public read', 'public keys that signed e-invoices (1108)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('acct.einvoice_line_tax', 'acct records', 'the taxes of e-invoice lines (1108)'),
  ('acct.einvoice_signing_key', 'acct records', 'public keys of e-invoice signatures (1108)')
ON CONFLICT (table_name) DO NOTHING;

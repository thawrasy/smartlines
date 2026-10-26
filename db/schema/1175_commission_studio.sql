-- 1175: commission schemes held to the same discipline as tax schemes (owner's note of 25 October 2026: pricing made
-- professional). Until now a commission scheme and its rules were plain rows: a rule could change after the scheme was
-- in force, a scheme could be put in force without a second officer, and a percentage rule could lack its rate.
--   * A scheme has a name besides its code.
--   * A rule gives its terms: a percentage between 0 and 100, a fixed amount of 0 or more, bands for a tiered rule; its
--     minimum is not above its maximum. The base is the fare (FARE), the fare without taxes (NET) or the platform fee
--     (FEE).
--   * A scheme goes in force only once a second officer approved it, with at least one rule, tiered rules with bands.
--   * The rules and bands of a scheme in force or retired never change; a change is a new version.
-- Rules recorded before 1175 that lacked their terms (only test data: no scheme with such a rule was ever in force) are
-- read as zero, so the check holds for every row.

ALTER TABLE pricing.commission_scheme ADD COLUMN IF NOT EXISTS name text CHECK (name IS NULL OR length(name) BETWEEN 2 AND 120);
COMMENT ON COLUMN pricing.commission_scheme.name IS 'The scheme''s name shown to officers (1175); the code stays its key across versions';

UPDATE pricing.commission_rule SET rate = 0 WHERE calc_method = 'PERCENT' AND rate IS NULL;
UPDATE pricing.commission_rule SET amount = 0 WHERE calc_method = 'FIXED' AND amount IS NULL;
UPDATE pricing.commission_rule SET rate = 100 WHERE calc_method = 'PERCENT' AND rate > 100;
UPDATE pricing.commission_rule SET max_amount = min_amount WHERE min_amount IS NOT NULL AND max_amount IS NOT NULL AND min_amount > max_amount;
ALTER TABLE pricing.commission_rule DROP CONSTRAINT IF EXISTS commission_rule_terms_check;
ALTER TABLE pricing.commission_rule ADD CONSTRAINT commission_rule_terms_check CHECK (
  (calc_method = 'PERCENT' AND rate IS NOT NULL AND rate BETWEEN 0 AND 100)
  OR (calc_method = 'FIXED' AND amount IS NOT NULL AND amount >= 0)
  OR calc_method = 'TIERED');
ALTER TABLE pricing.commission_rule DROP CONSTRAINT IF EXISTS commission_rule_limits_check;
ALTER TABLE pricing.commission_rule ADD CONSTRAINT commission_rule_limits_check CHECK (
  min_amount IS NULL OR max_amount IS NULL OR min_amount <= max_amount);
UPDATE pricing.commission_scheme SET base_type = 'FARE' WHERE base_type NOT IN ('FARE', 'NET', 'FEE');
ALTER TABLE pricing.commission_scheme DROP CONSTRAINT IF EXISTS commission_scheme_base_check;
ALTER TABLE pricing.commission_scheme ADD CONSTRAINT commission_scheme_base_check CHECK (base_type IN ('FARE', 'NET', 'FEE'));
COMMENT ON COLUMN pricing.commission_scheme.base_type IS 'FARE: the ticket price paid; NET: the fare without its taxes; FEE: the platform fee (1175)';

-- in force only with a second officer and complete rules
CREATE OR REPLACE FUNCTION pricing.tg_commission_scheme_check() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.status <> 'ACTIVE' OR (TG_OP = 'UPDATE' AND OLD.status = 'ACTIVE') THEN
    RETURN NEW;
  END IF;
  IF NEW.approved_by IS NULL THEN
    RAISE EXCEPTION 'COMMISSION_UNAPPROVED: a second officer approves a commission scheme before it applies' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pricing.commission_rule WHERE scheme_id = NEW.id) THEN
    RAISE EXCEPTION 'COMMISSION_RULES: a commission scheme needs at least one rule' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM pricing.commission_rule r WHERE r.scheme_id = NEW.id AND r.calc_method = 'TIERED'
               AND NOT EXISTS (SELECT 1 FROM pricing.rate_band b WHERE b.commission_rule_id = r.id)) THEN
    RAISE EXCEPTION 'COMMISSION_RULES: a tiered rule needs its bands' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION pricing.tg_commission_scheme_check() IS 'A commission scheme goes in force only approved by a second officer, with complete rules (1175)';
DROP TRIGGER IF EXISTS commission_scheme_check ON pricing.commission_scheme;
CREATE TRIGGER commission_scheme_check BEFORE INSERT OR UPDATE ON pricing.commission_scheme
  FOR EACH ROW EXECUTE FUNCTION pricing.tg_commission_scheme_check();

-- the rules of a scheme in force or retired never change
CREATE OR REPLACE FUNCTION pricing.tg_commission_rule_frozen() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_scheme bigint;
BEGIN
  IF TG_TABLE_NAME = 'commission_rule' THEN
    v_scheme := coalesce(NEW.scheme_id, OLD.scheme_id);
  ELSIF coalesce(NEW.commission_rule_id, OLD.commission_rule_id) IS NULL THEN
    RETURN coalesce(NEW, OLD);                              -- a tax band
  ELSE
    SELECT scheme_id INTO v_scheme FROM pricing.commission_rule WHERE id = coalesce(NEW.commission_rule_id, OLD.commission_rule_id);
  END IF;
  IF v_scheme IS NOT NULL AND EXISTS (SELECT 1 FROM pricing.commission_scheme WHERE id = v_scheme AND status IN ('ACTIVE', 'RETIRED')) THEN
    RAISE EXCEPTION 'COMMISSION_FROZEN: the rules of a commission scheme in force or retired do not change; record a new version'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN coalesce(NEW, OLD);
END $$;
COMMENT ON FUNCTION pricing.tg_commission_rule_frozen() IS 'Rules and bands of a commission scheme in force or retired never change (1175)';
DROP TRIGGER IF EXISTS commission_rule_frozen ON pricing.commission_rule;
CREATE TRIGGER commission_rule_frozen BEFORE INSERT OR UPDATE OR DELETE ON pricing.commission_rule
  FOR EACH ROW EXECUTE FUNCTION pricing.tg_commission_rule_frozen();
DROP TRIGGER IF EXISTS rate_band_commission_frozen ON pricing.rate_band;
CREATE TRIGGER rate_band_commission_frozen BEFORE INSERT OR UPDATE OR DELETE ON pricing.rate_band
  FOR EACH ROW EXECUTE FUNCTION pricing.tg_commission_rule_frozen();

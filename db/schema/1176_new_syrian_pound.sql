-- 1176: the new Syrian pound (owner's note, 26 October 2026).
-- On 1 January 2026 the Central Bank of Syria removed two zeros: 100 old pounds make one new pound, still SYP, still
-- divided into 100 piastres. Every amount here is a bigint in the minor unit of its currency, and the SYP minor unit
-- has been the old piastre (1/100 of an old pound). One old pound is one new piastre, so a stored amount already counts
-- ten-thousandths of a new pound: nothing is rewritten (ledgers, signed invoices and frozen snapshots keep their
-- integers); the currency now says so. minor_unit is the scale amounts are stored in; decimals is how many decimal
-- places people see and pay in (ISO 4217).

ALTER TABLE ref.currency ADD COLUMN IF NOT EXISTS decimals smallint;
UPDATE ref.currency SET decimals = minor_unit WHERE decimals IS NULL;
ALTER TABLE ref.currency ALTER COLUMN decimals SET NOT NULL,
  ADD CONSTRAINT currency_decimals_check CHECK (decimals BETWEEN 0 AND 3 AND decimals <= minor_unit);
COMMENT ON COLUMN ref.currency.minor_unit IS 'Scale of the stored amounts: an amount is a bigint of 10^-minor_unit of the currency';
COMMENT ON COLUMN ref.currency.decimals IS 'Decimal places people see and pay in (ISO 4217); amounts show rounded to them';

UPDATE ref.currency SET minor_unit = 4, decimals = 2, name = 'Syrian Pound (new, 2026)' WHERE code = 'SYP' AND minor_unit = 2;

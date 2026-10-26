# The new Syrian pound and form fields

Owner's note of 26 October 2026: amounts must be in the new currency, after two zeros were removed, not the old one;
fields placed side by side must line up; a required field is marked with an asterisk and an optional one says so inside
the field, instead of "(optional)" in its label.

## The new pound (1176)

On 1 January 2026 the Central Bank of Syria removed two zeros: 100 old pounds make one new pound. The code stays SYP
and the pound keeps 100 piastres.

Every amount is a bigint in the minor unit of its currency. Until now the SYP minor unit was the old piastre, 1/100 of an
old pound. One old pound is one new piastre, so a stored amount already counts ten-thousandths of a new pound. Nothing is
rewritten: ledgers, signed e-invoices, frozen snapshots and history keep their integers. The currency now says what they
count:

| ref.currency | meaning | SYP |
|---|---|---|
| `minor_unit` | the scale amounts are stored in (10^-minor_unit of the currency) | 4 |
| `decimals` | the decimal places people see and pay in (ISO 4217) | 2 |

An old fare of 29,000 pounds, stored as 2,900,000, reads 290 new pounds.

* Backend: `app/money.py` reads the table at start. `major`, `text` and `to_minor` serve messages, the public pages,
  e-invoice QR codes and report exports. Bank statements are read in new pounds. `GET /api/markets` gives `minor_unit`
  and `decimals`.
* Web and mobile: `money()` shows an amount rounded to the decimals people pay in. Every amount field goes through
  `toMinor` and `fromMinor` from `i18n` instead of a fixed factor of 100. Preset amounts (wallet top-ups, steps,
  default limits) are in new pounds.
* Rounding to whole old pounds in fares and family shares is rounding to whole piastres now, which is what the new
  currency pays in.

## Form fields

* `Field` takes `required` (or reads `required` on its control) and `optional`. A required label carries a red
  asterisk. In a form, card or dialog that has optional fields, every field not marked optional carries one. An optional
  text field shows "Optional" as its placeholder.
* Fields side by side in a grid line up: each spans three rows of a subgrid (label, control, hint). A label that wraps to
  two lines moves its neighbours' controls with it.
* About seventy "(optional)" labels moved to the `optional` property. In the Latin name the parts keep short labels,
  since the section heading already says "as in the passport".

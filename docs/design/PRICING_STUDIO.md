# Taxes and pricing studio

Owner's note of 25 October 2026: pricing and taxes must be professional. The platform's finance officers had to fill
generic tables (scheme, rule, band) row by row with codes; nobody could see what a traveller would pay or who would
receive each part. The studio replaces that with one screen (Finance and prices → Taxes and pricing, `/admin/taxes`,
permission `pricing.tax_commission`).

## Taxes

* Each tax is a card in plain terms: its kind (VAT, sales tax, levy, government fee, stamp duty, withholding), its
  treatment (standard, zero rated, exempt, out of scope, reverse charge), what it is worth ("10 %", "500 SYP per
  booking", "2 % of VAT", "2 bands"), what it applies to (tickets, the platform fee, sellers, trip origin cities), its
  period, who it is paid to, and who recorded and approved it.
* The cards are grouped by phase: in force, waiting for approval, starting later, ended.
* A new tax is recorded in four steps (the tax, what it applies to, how it is computed, review) and sent for approval.
  Rules are a percentage, a fixed amount per ticket, booking or passenger, or bands of the amount or of the distance
  (the band the value falls in, or each band on its own share), with a minimum, a maximum and a rounding; a tax can be
  levied on other taxes (a levy on VAT) or have other taxes added to its base (compound taxes).
* A second officer approves it (`SAME_OFFICER` otherwise; the database refuses it too). Once in force its rules never
  change (`TAX_SCHEME_FROZEN`); a change is a **new version** of the same code with its start date: approving it ends
  the version in force at that date, so every sale is taxed by exactly one version. A waiting tax can be withdrawn;
  a tax in force can be retired from now. Nothing is deleted; every step is in the activity log.

## Price preview

The receipt of a sale before it happens, computed by the engine that issues the e-invoices (`einvoice/taxes.py`):
ticket price (taxes included, as travellers see it) × passengers, the carrier's fare without taxes, each tax with its
base and amount and who receives it, the platform fee and its taxes, the payment fee of the chosen method (paid by the
traveller or borne by the platform), an agency's commission, the total paid, and a bar of who receives what (carrier,
agency, platform, taxes, payment provider) that always adds up to the total. Waiting taxes can be tried as if in force,
so the effect of a change is seen before it is approved. In the cash-only phase there is no platform or payment fee.

## API

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/admin/pricing/taxes` | jurisdictions and every scheme with rules, bands, phase and summary |
| POST | `/api/admin/pricing/taxes` | a scheme with its rules and bands (waiting); `from_id` makes the next version |
| POST | `/api/admin/pricing/taxes/{id}/approve` | a second officer puts it in force; ends the previous version |
| POST | `/api/admin/pricing/taxes/{id}/withdraw` | withdraw a waiting scheme |
| POST | `/api/admin/pricing/taxes/{id}/retire` | stop a scheme in force from now |
| GET | `/api/admin/pricing/preview-options` | payment methods, countries, cities, the platform fee |
| POST | `/api/admin/pricing/preview` | the receipt of a sale, with waiting schemes tried by id |

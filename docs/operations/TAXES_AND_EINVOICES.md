# Taxes on e-invoices and the signing keys

Owner's decisions (October 2026); migrations 1104 (issuing) and 1108 (taxes, key ring). Code:
`backend/app/modules/einvoice/taxes.py` (the tax engine) and `service.py` (the issuer).

## Defining taxes

Each tax is a **tax scheme** (screen **Tax schemes**, permission `pricing.tax_commission`) in a **jurisdiction**
(a country, or a region or local area inside it). A scheme has:

| Field | Meaning |
|---|---|
| tax type | VAT, SALES, LEVY, FEE, STAMP, WITHHOLDING, OTHER |
| treatment | `OUT_OF_SCOPE`, `EXEMPT`, `ZERO` (zero-rated), `STANDARD` (taxed by its rules), `REVERSE` (reverse charge) |
| scope | what it applies to: `{"products": ["TICKET", "BOOKING_FEE"], "sellers": ["CARRIER", "PLATFORM"], "company_ids": [..], "origin_cities": ["DAM", ..]}`; each key optional |
| payable to | the authority the tax is owed to (for a tax collected for another body) |
| validity | the period it applies to, by the time of the sale |

A standard-rated scheme has one or more **rules** (screen **Tax rules**) and, for tiered rules, **bands**:

| Rule | Computes |
|---|---|
| `PERCENT` | rate % of the base |
| `FIXED` | an amount per ticket, or once per booking (`applies_per` = `BOOKING`) |
| `TIERED` | from bands of the base or of the trip's distance: `WHOLE` (the band it falls in) or `MARGINAL` (each band's share) |

A rule's **base** is the line's net amount (`base_type` = `FARE`) plus the taxes named in `base_include`, or only those
taxes (`base_type` = `TAXES`). Several rules of one scheme combine by `compound_mode`: `ADD`, `MAX`, `MIN`, or `CASCADE`
(the rule's base includes the scheme's earlier rules). Each rule may have a minimum, a maximum and a rounding
(`HALF_UP`, `HALF_EVEN`, `DOWN`, `UP`).

| The owner's case | How it is defined |
|---|---|
| Out of scope, exempt, zero | a scheme with that treatment; shown on the invoice, nothing charged |
| A rate per band | a `TIERED` rule with its bands |
| A rate per product | a scheme whose scope names the products |
| Compound sales tax and VAT | a SALES scheme, and a VAT scheme whose rule has `base_include` = `["SALES"]` |
| A local tax | a scheme of a local jurisdiction whose scope names its cities |
| A tax on the VAT for another authority | a LEVY scheme payable to that authority, with a rule `base_type` = `TAXES`, `base_include` = `["VAT"]` |

A scheme is written by one officer and approved by another; it applies only once approved and active. A scheme does not
go live when the issuer could not compute it (a standard scheme without rules, a formula rule, a tiered rule without
bands, a tax on taxes that names none, or taxes levied on each other in a loop). Once active, its rules and bands do not
change: retire it and record a new version, so every invoice keeps the rules it was issued under.

## On the invoice

Prices on the platform include their taxes. For each ticket and for the platform's booking fee, the issuer takes the
schemes of the seller's country that apply to the line and were valid when the booking was paid, finds the largest net
amount whose taxes fit in the price paid, and keeps each tax on the line (scheme, treatment, rate, base, amount, the
authority it is owed to); any remaining minor unit stays in the net amount, so net + taxes = price paid. With no
scheme, the sale is out of scope. A credit note takes back each tax of its invoice in proportion to the amount
refunded. The single rate of release 1.49.0 (`einvoice.tax_rate_pct`) is retired.

## Signing keys

Every document is hashed (SHA-256 of its canonical form) and signed with Ed25519. The keys form a ring:

```
MASSLAK_EINVOICE_KEYS=e202610:<base64 of a 32-byte seed>[,e202604:<base64>...]
```

The first key signs; each document names its key (`signing_kid`), and the key id is part of the hashed content. The
public key of every key that ever signed is kept in `acct.einvoice_signing_key` and published at
`GET /api/public/keys/einvoice`, and `GET /api/verify/einvoice/{uuid}` checks a document against the key it names. A
document therefore stays verifiable after its private key is retired. Rotation: put a new key first (a new id), deploy,
and drop the old key once nothing is issued with it; its public key stays published. Production requires a key of its
own first (`deploy/init-env.sh` makes one); a key id reused for a different key stops issuing until it is fixed.
Documents issued before release 1.50.0 keep canonical version 1 (no key id, one rate per line) and verify with the
earlier key (`e1`).

## Look-back window (owner's decision 5)

The issuer covers bookings paid, and refunds made, in the last 30 days (`einvoice.issue_window_days`). Approved by the
owner because it keeps the issuing pass and the reports consistent: an issuing unit switched on today invoices the
sales of the last 30 days once and every new sale from then on, and a carrier's monthly tax return can rely on all of
the previous month's documents being present. Sales older than the window are not invoiced afterwards.

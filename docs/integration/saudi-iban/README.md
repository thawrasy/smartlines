# Saudi IBAN validation — integration package

A reference package for validating Saudi IBANs to ISO 13616 and ISO 7064 MOD 97-10, with the table of IBAN bank codes
SAMA assigns. Every implementation applies the same rules and returns the same error codes, and all of them run the
same test vectors.

| File | Purpose |
|---|---|
| `saudi_banks.json` | The bank table: IBAN bank code, Arabic and English name, status, SWIFT code and how well it is attested. **The single source** the implementations read |
| `messages.json` | Error and warning texts in Arabic and English |
| `python/saudi_iban.py` | Reference implementation in Python, no dependencies |
| `typescript/saudiIban.ts` | The same in TypeScript, for front ends and Node servers |
| `test_vectors.csv` | 47 shared cases, valid and invalid, with the expected result and error code |
| `python/test_saudi_iban.py`, `typescript/saudiIban.test.ts` | Run the vectors, plus Arabic-Indic and Persian digit input, against each implementation |
| `saudi_iban_bank_codes.xlsx` | For non-developers (in Arabic): the bank table, an IBAN checker written as Excel formulas, the algorithm step by step |

Arabic text in the code and data (bank names, messages) is stored as `\u` escapes, as the repository's language
check (`scripts/check_language.py`) requires; it reads as Arabic at run time.

## 1. Structure

24 characters; the SWIFT IBAN Registry format is `SA2!n2!n18!c`.

| Positions | Part | Length | Example |
|---|---|---|---|
| 1–2 | Country code | 2 letters | `SA` |
| 3–4 | Check digits | 2 digits | `03` |
| 5–6 | Bank code (assigned by SAMA) | 2 digits | `80` |
| 7–24 | Account number | 18 characters (digits in practice) | `000000608010167519` |

The check digits are computed from the whole account, so there is no fixed check value per bank.

## 2. Validation, in this order

The first rule that fails is the error returned.

| # | Rule | Error code |
|---|---|---|
| 0 | Normalise: drop spaces, hyphens, no-break spaces and the direction marks U+200E/U+200F; turn Arabic-Indic (U+0660–U+0669) and Persian (U+06F0–U+06F9) digits into 0–9; upper-case; drop a leading `IBAN` | — |
| 1 | Not empty | `EMPTY` |
| 2 | Only `A–Z` and `0–9` | `INVALID_CHARACTERS` |
| 3 | Starts with `SA` | `COUNTRY_NOT_SA` |
| 4 | Exactly 24 characters | `WRONG_LENGTH` |
| 5 | Matches `^SA[0-9]{2}[0-9]{2}[0-9A-Z]{18}$` | `INVALID_FORMAT` |
| 6 | Check digits are not `00`, `01` or `99` (02–98 only) | `INVALID_CHECK_DIGITS` |
| 7 | MOD-97 remainder is 1 | `CHECKSUM_FAILED` |
| 8 | Bank code is in `saudi_banks.json` | `UNKNOWN_BANK` |

**Warnings, which do not reject the IBAN:**
- `LEGACY_BANK`: the code of a merged bank, 40 for Samba and 50 for Alawwal. The IBAN is arithmetically valid, but the
  account may have moved to the acquiring bank.
- `UNKNOWN_BANK`: a warning instead of an error only with `strict_bank=False` / `strictBank: false`, so a bank SAMA
  licenses after the table's last update is not refused.

Rule 6 matters: an account whose real check digits are 97 or 98 also passes MOD-97 with `00` or `01`. The vectors cover
both cases.

## 3. MOD-97

```
rearranged = iban[4:] + iban[0:4]           # move the first four characters to the end
remainder  = 0
for ch in rearranged:
    v = digit value of ch (0–9), or A=10 … Z=35
    remainder = (remainder * (v > 9 ? 100 : 10) + v) mod 97
valid ⇔ remainder == 1
```

Working one character at a time needs no big integers, so it ports to any language, SQL and COBOL included.

**Check digits** for a bank code and an 18-character account: `check = 98 − mod97("SA00" + bank_code + account)`,
written as two digits with a leading zero.

## 4. Usage

**Python**
```python
from saudi_iban import validate, message
r = validate(user_input)            # validate(user_input, strict_bank=False) accepts an unknown bank with a warning
if r.valid:
    save(r.iban)                    # electronic form: 24 characters, no spaces
    show(r.formatted, r.bank["name_ar"], r.bank["swift"], r.warnings)
else:
    show_error(message(r.error))    # message(r.error, "en") for English
```

**TypeScript** (ESM; needs `resolveJsonModule`)
```ts
import { validateSaudiIban, message } from "./saudiIban";
const r = validateSaudiIban(input);
if (!r.valid) showError(message(r.error!));   // message(r.error!, "en") for English
```

## 5. Integration advice

1. **Validate in the front end and on the server.** The front end is for the user's convenience; the server decides.
2. **Store the electronic form** (`iban`: 24 characters, no spaces) and display only the print form (`formatted`).
3. **A valid IBAN does not prove the account exists** or belongs to the payee. Before the first transfer to a new
   payee, verify the name through the bank, with the payee-name inquiry of the local payment services.
4. **An IBAN is personal data.** Mask it in logs and messages (for example `SA03 •••• •••• •••• •••• 7519`) and never
   write it in full to a log file.
5. **The SWIFT code is for display and international transfers only.** Do not rely on one whose `swift_confidence` is
   `single_source` or `unconfirmed` without confirming it with the bank.
6. **To add a bank, update `saudi_banks.json`.** Both implementations read it; no bank table is copied into code. The
   workbook is generated with the JSON by `scripts/gen_saudi_iban_workbook.py`, so add the bank there to update both.

## 6. Tests

```bash
cd python && python -m unittest test_saudi_iban
```
```bash
cd typescript && node --experimental-strip-types --test saudiIban.test.ts
```

A port to another language should run `test_vectors.csv`: any difference from the `error` column means the port does
not match.

## 7. Bank data and sources

- **Bank codes:** the identifiers SAMA assigns, as published in [EngMEita/saudi-banks](https://github.com/EngMEita/saudi-banks),
  cross-checked with cubbbix.com and validatefin.com.
- **Codes confirmed by real IBANs that pass MOD-97:** 36 D360 Bank, 73 First Abu Dhabi Bank, 78 STC Bank.
- **SWIFT codes:** from public BIC directories (Wise, XE, theswiftcodes, ksaexpats, alaan). `swift_confidence` says how
  well each is attested:

  | Value | Meaning |
  |---|---|
  | `confirmed` | Found in more than one source |
  | `single_source` | Found in one source |
  | `unconfirmed` | No source found |

- **Limits:** SAMA publishes no open registry of these codes, so check the table with SAMA or the banks before
  production. Vision Bank is not listed because its code could not be verified.
- **Last updated:** 2026-10-30.

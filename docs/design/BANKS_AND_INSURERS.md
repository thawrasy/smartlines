# Banks and insurers registries (owner's requests N6 and N9, migration 1156)

## What it solves

Companies used to type their bank's name, and carriers typed their insurer's name. Typed names cannot be checked. They
cannot be reported on, and they cannot be linked to a future bank or Central Bank gateway. The platform now keeps three
registries: banks, bank branches and insurance companies. Companies pick from them.

## Registries

| Table | What it holds |
|---|---|
| `ref.bank` | code, Arabic and English names, short name, kind (central, public, private, Islamic), SWIFT/BIC with its own check status, the bank's code inside an IBAN, address, phone, fax, e-mail, website |
| `ref.bank_branch` | the branches of a bank: names, branch code, SWIFT of the branch, head office flag, area, address and position |
| `ref.insurer` | code, names, ownership (public, private), kind (conventional, takaful, reinsurance), licence number, address, position and contacts |

Every entry carries:

- `status`: `PENDING_REVIEW`, `ACTIVE`, `REJECTED` or `RETIRED`;
- `verification_status`: `UNVERIFIED` or `VERIFIED`;
- `source`: `MANUAL` or `IMPORT`;
- who entered it and who reviewed it.

### Review by a second person

- A new entry waits as `PENDING_REVIEW`. The person who entered it can correct it. Another person accepts or rejects it.
  The database refuses `reviewed_by = entered_by` and an `ACTIVE` row without a reviewer.
- A change to an `ACTIVE` entry is kept in `pending_changes` with who proposed it. Companies keep seeing the reviewed
  values until a second person accepts the change. Only one change waits at a time.
- Retiring an entry takes it out of the pickers. Rows that already point to it keep it.
- Reviews ask for a recent second factor (step-up), because companies' money and policies point to these entries.

### Hidden kinds

- The central bank is kept in the registry and hidden from companies' pickers (`bank_central_ck`).
- Reinsurers are kept and hidden from carriers (`insurer_reinsurance_ck`).

### SWIFT codes

- A SWIFT code must have the SWIFT/BIC form (8 or 11 characters). It is unique among entries that were not rejected.
- Whether the code is right is a separate field: `TO_VERIFY`, `VERIFIED` or `INVALID`.
- An import that brings a malformed code keeps it in `swift_reported` and marks it `INVALID`. The rest of the row still
  comes in, and the code is followed up with the bank.

### Who keeps them

- The right is `reference.manage` (reference data), held by the platform's administrators, operations, finance and
  compliance roles.
- Row security lets every signed-in user read the registries. Only a platform context writes them.
- The API shows companies only `ACTIVE` entries that are not hidden. Notes, review details and pending changes are not
  shown to companies.

## Importing the owner's tables

`POST /api/admin/registry/{banks|insurers}/import` takes an `.xlsx` file. The first sheet whose name ends in `_import`
is read, or else the first sheet.

- The required columns are `code`, `name_ar` and `name_en`.
- The other known columns map to the fields above. The insurers table names phone, fax and website in Arabic, and those
  headers are recognised. Unknown columns become address lines.
- Every row comes in as `UNVERIFIED`, `PENDING_REVIEW` and source `IMPORT`, so each one is still reviewed.
- A code already in the registry is skipped and reported. A change to a reviewed entry is proposed on screen.
- A row with a mistake refuses the whole file and says which rows are wrong.

The Arabic data itself is not kept in the repository. It is loaded from the owner's files at run time.

## Company bank accounts

`iam.bank_account` gains these columns:

- `bank_id` and `branch_id`, pointing to the registry;
- `swift_bic`, copied from the branch, or from the bank when it has no branches yet;
- the account number, encrypted (`account_no_enc`) with its last four characters;
- `is_default`: one default account per company, set automatically on the first account;
- `verification_status`: `UNVERIFIED`, `VERIFIED_BY_GATEWAY`, `VERIFIED_MANUAL` or `REJECTED`;
- `verification_source`, and `verified_holder_name` for the name a future gateway returns.

A company never sets these verification fields itself. The 997 trigger is extended to guard them.

### Rules for accounts

- Platform finance verifies an account (`VERIFIED_MANUAL`) or rejects it with a reason. A rejected account is never
  paid and cannot be the default.
- A company can make another account the default. It can stop using an account when no withdrawal to it is open.
- The setting `payouts.accounts.verified_only` decides whether withdrawals go only to verified accounts. It is `false`
  at launch, and platform finance still approves every withdrawal. A rejected account is always refused.
- `payouts.accounts.verification_gateway` is `NONE` until a bank or Central Bank gateway exists.
- The IBAN check (format and ISO 7064 mod-97) is unchanged.
- The account number and the IBAN share the row's key, so key rotation (`tools/rekey.py`) moves both together.

## Insurance policies

- `fleet.insurance_policy.insurer_id` points to the registry.
- A trigger allows only a reviewed insurer that is shown to companies, and copies its name into `insurer_name`.
- `insurer_name` is no longer required when an insurer is picked. It stays for old rows.
- The generic form's picker lists only active, visible insurers.

## Screens

- **Platform → Banks and insurers**: lists with review state and waiting changes, add, correct or propose a change,
  accept or reject, retire, import a file, and branches with their own review.
- **Company → Finance → Add bank account**: bank, then branch (or head office), SWIFT filled in, account number, IBAN,
  and the default choice. The list shows the bank, branch, SWIFT, the last four characters and the verification state.
- **Platform → Finance desk**: verify or reject an account.

## Tests

- `backend/tests/test_registries.py` covers:
  - the review by a second person;
  - proposals on reviewed entries;
  - the hidden central bank;
  - branches;
  - accounts with bank, branch, encrypted account number and one default;
  - finance's rejection;
  - the import (refusal of a whole file, skipped codes, a malformed SWIFT kept aside);
  - the insurer picker without reinsurers.
- `db/tests/run_tests.sql`, block "Registries (1156)", covers:
  - companies cannot write the registry or set verification;
  - four eyes;
  - active only once reviewed;
  - the central bank hidden;
  - the SWIFT form;
  - policies pick only reviewed insurers.

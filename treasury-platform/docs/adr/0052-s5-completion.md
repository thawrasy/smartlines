# ADR 0052: Tenant data export package, notification defaults, template preview, catalogue CSV

Status: built on 2026-10-25 (docs/31 row 53). Written by an AI agent.

## Context

`docs/50` §5 left the app side of the tenant data export (the database side is db/static/042), the tenant default
notification preferences (FR-NTF-011), the template preview and test send (FR-NTF-025) and the catalogue import and
export (FR-CAT-024). The owner asked to finish the setup without further questions.

## Decision

1. **Data export.** `JOB-PLT-EXPORT` (every 5 minutes) builds a zip of every tenant table in the export schemas as JSON
   (binary, `…Enc`, `…Hash` and TenantId columns left out), the clean active files (restricted ones only when the
   export includes restricted data) and a manifest with row counts and SHA-256 of each file. The zip is encrypted with
   the tenant FILE key like any document and expires after 7 days (`JOB-PLT-EXPORT-EXPIRE`). Only the requester
   downloads it, with a step-up code, sealed with a password of 12 to 128 characters chosen at download and never
   stored: OpenSSL `enc` format (Salted__, AES-256-CBC, PBKDF2-SHA256 with 600,000 iterations), so the tenant opens it
   with a standard tool and no platform software.
2. **Notification defaults.** One JSON setting, `ntf.prefs.defaults` (`{"GROUP": {"IN_APP": mode, "EMAIL": mode}}`),
   set only through `/notification-preferences/defaults` (validated like a user's choice). The effective mode is the
   user's own row, else the default, else IMMEDIATE, in the notifier and in the digest job; a mandatory group stays in
   the application. No schema change.
3. **Preview and test send.** The text (sent or stored) with each placeholder as `[name]`; the test goes to the
   administrator's own e-mail through the mail sender directly, marked as a test, outside ntf.Notification and its
   delivery log, and is audited.
4. **Catalogue CSV.** Export of every item of a kind (formula-guarded cells, references by code, UTF-8 with BOM).
   Import of the same columns, code as the key, previewed row by row inside one transaction with a savepoint per row;
   it commits only with `apply` and no error. A high-impact flag on an item in use is refused by import (the screen
   keeps the treasury manager's confirmation). At most 2,000 rows and 2 MB.

## Consequences

- The worker needs `Files:Root`, the same store as the API.
- A database error that dooms the transaction stops the import at that row with IMPORT_STOPPED.
- Lookup lists are not exported or imported in this round.

# ADR 0032: No row on a key that may no longer be used (the rest of DR-20)

Status: decided by the database architect on the owner's request of 2026-10-21 to build item 1 of the open points of
the external review (DR-20 in docs/32-review-findings-decisions.md, DOC-S02 section 6). Builds on ADR 0011 (DR-02:
every key column carries its purpose).

## Context

Every encrypted or blind-indexed column names its key in `sec.TenantKey`, with the key's purpose (DR-02). A foreign
key cannot say the key's status. DOC-S02 asks that a RETIRED or REVOKED key take no new row, and DR-20 that no row
references a RETIRED key. Until now this was left to the rotation service, which is not built.

## Decision

1. **Reference triggers** (`db/static/054_key_guard.sql`). One per table with a foreign key to `sec.TenantKey`, except
   the key log `sec.KeyEvent`; today 9 key columns in 6 tables. They are built from `sys.foreign_keys`, so a new
   encrypted column is covered the next time the script runs (and the script stops if it finds fewer columns than the
   model holds). A new row, or a row whose key column changes, may name only an ACTIVE key (50098). A row that keeps
   its key keeps it whatever the key's status, so rows on a RETIRING key can still be read and updated while the
   rotation re-encrypts them.
2. **The key lifecycle** (`sec.TR_TenantKey_Lifecycle`). PENDING to ACTIVE; ACTIVE to RETIRING; RETIRING to RETIRED, or
   back to ACTIVE when a rotation is given up; any of these to REVOKED. RETIRED and REVOKED are final (50098).
3. **Retirement only when unused.** A key becomes RETIRED only when no row references it (50098).
4. **Revocation is never held back.** A compromised key is revoked at once even with rows on it. Those rows are listed
   by `sec.v_KeyReferences` (per key: table, column, number of rows) until the rotation job re-encrypts or destroys
   them; no new row can be written onto the key.

So the rule of DR-20 holds in the database itself: no row references a RETIRED key, and no row is written onto a key
that is not ACTIVE. The one exception, rows still on a REVOKED key, is deliberate and visible.

## Tests

`db/tests/integrity_tests.sql` KG1 to KG6: a PENDING key refused for a new row; a row cannot move onto a key that is not
ACTIVE, and a row on a RETIRING key can still change; retirement refused while a row is on the key and accepted after
the rotation; the lifecycle only forward; revocation of a key in use; all 9 key columns guarded.

## What stays open

The encryption itself is application code and is not built (DOC-S02 line 36). This guard makes the key register safe
for the rotation service when it is built; it does not encrypt anything.

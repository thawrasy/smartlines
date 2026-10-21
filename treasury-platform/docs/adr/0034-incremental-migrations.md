# ADR 0034: Incremental schema changes for a deployed database

Status: decided by the database architect on the owner's request of 2026-10-21 to build item 3 of the open points of
the external review (DOC-B11 section 6). Builds on ADR 0010 (deployment as bankfas_migrator) and ADR 0014 (the
preflight).

## Context

`db/deploy.sql` builds an empty database only: the preflight refuses one that holds tables (50142). There was no way
to bring a deployed database to a later release, and no record of what had been applied. DOC-B11 section 6.2 proposed
a journal, versioned scripts, repeatable scripts and a parity check. Checking whether the static scripts could run a
second time showed that they could not: `010_rls.sql` stopped, because its predicate functions are schema-bound to
each other and to the policies.

## Decision

1. **The journal** `plat.SchemaMigration`. One row per step: BASELINE, each versioned script, each run R of the
   repeatable scripts. Each row holds the SHA-256 of its file or bundle, the schema fingerprint after the step, who
   applied it, when, and how long it took. No role reads or writes it.
2. **The fingerprint** (`db/static/056_schema_fingerprint.sql`, `plat.fn_SchemaFingerprintParts`,
   `plat.fn_SchemaFingerprint`). It is a SHA-256 over eight parts in binary order: schemas, columns, keys and checks,
   indexes, module definitions (with their trigger and EXECUTE AS state), security policies, roles, and the permissions
   of roles. Database users and role membership are left out: the service logins are made after the deployment and
   differ by design.
3. **The runner** `tools/deploy/migrate.sh` runs as the deployment login inside the deployment window.
   - `baseline`: deploy.sh calls it after a new deployment.
   - `status`: shows the journal, the scripts pending, whether the repeatable scripts changed, and the fingerprint.
   - `apply [--repeatable]`: applies each pending `db/migrations/Vnnnn__description.sql` in order, each in one
     transaction with its journal row (a failure rolls back both). Then it runs the repeatable scripts, which are the
     lines of deploy.sql from `generated/tsql/004_rls_tables.sql` on, in one transaction. It does this when a
     versioned script ran, when the repeatable scripts changed, or on request.
   - `apply` refuses, changing nothing, when: there is no baseline; the fingerprint differs from the journal's (the
     schema was changed outside it); an applied script was edited or removed; a new script sorts before an applied
     one; or a file is misnamed.
4. **The repeatable scripts can run again.** `010_rls.sql` now drops the policies and its predicate functions first and
   makes them again. Because the repeatable run is one transaction, no session sees a table without its policy.
5. A versioned script carries what the repeatable scripts cannot: tables, columns, keys, indexes, and data that must
   move with them. The same change goes into the model, so a new database built by deploy.sql has the same schema.

6. *Amended on 2026-10-21 by ADR 0039 (internal review v6).* migrate.sh runs the server gate of deploy.sh
   (`db/ops/server_gate.sql`: 50140, 50143, 50150) and requires `BANKFAS_CHANGE_REF`, recorded in the new journal column
   `ChangeRef`; `baseline --after-deploy` (deploy.sh only) journals the versioned scripts present; a repeatable run that
   failed after a versioned script is taken up again; a script with a transaction or sqlcmd control line is refused;
   the fingerprint is checked again inside each script's transaction; `status` exits 1 on a problem. The window opens
   only with the server audit running, no service session and a recent full backup (`prepare_database.sh open`, 50151
   to 50153). The fingerprint now covers role membership, grants to every principal, owners and DDL triggers. Tests
   MG1 to MG12, run as `bankfas_migrator` inside a window.

DbUp, which DOC-B11 suggested, would need the service layer, which is not built. When that layer exists, DbUp can take
over the same folder and journal.

## Tests

`tools/ci/migration_check.sh` MG1 to MG7, on the database CI deploys (MG8 to MG12 added by ADR 0039):
- MG1: the baseline is journaled.
- MG2: nothing is pending.
- MG3: the repeatable scripts run again with the fingerprint unchanged.
- MG4: a probe versioned script runs once and changes the fingerprint.
- MG5: edited, early and misnamed scripts are refused.
- MG6: a failing script rolls back.
- MG7: a change outside the journal stops apply.

## What stays open

The parity check of DOC-B11 section 6.3 compares a database built fresh by deploy.sql with one brought up by the
versioned scripts. It needs the first versioned script, and goes into CI with it: CI will deploy the baseline release,
apply db/migrations, and require the fingerprint of a fresh deployment of the same release. `db/migrations` is empty
today.

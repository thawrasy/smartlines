# ADR 0008: The tenant data export runs through procedures, also in SUSPENDED and CLOSED

Status: decided by the database architect (DQ-F04-8, whose decider is the database architect). It builds on the owner decisions on tenant status:
- BR-PLT-002 and DQ-F04-1: the account administrator alone may read and export in SUSPENDED, and only export in CLOSED for 30 days.
- DQ-F05-7: no real tenant closes before the export exists.

It follows ADR 0004 (jobs) and ADR 0007 (audit).

## Context

- `rls.fn_BoundWrite` refuses every direct write unless the tenant is TRIAL or ACTIVE. That is right for business data, but the export is a write too: it records a request, an approval, a running job and a package. It is needed precisely in SUSPENDED and CLOSED (DOC-F04 section 7.4, DOC-F05 section 6.4).
- DQ-F04-8 proposed procedures run as `tp_auth_exec` for the few writes these statuses need. Idle extension and logout were built in ADR 0003. The export request and the export job were left, and with them the job writes O-25 listed.
- `tp_app` could insert and update `cfg.DataExportJob` directly. It could therefore mark an export of restricted data approved, or a package ready, without the reveal holder (BR-PLT-016).

## Decision

1. **Procedures** (`db/static/042_data_export.sql`, all run as `tp_auth_exec`):

   | Procedure | Caller | What it checks and does |
   |---|---|---|
   | `cfg.usp_RequestDataExport` | a USER binding still admitted by the tenant status (`sec.fn_TenantLoginAllowed`) | permission `cfg.export.request` through a role (`sec.fn_UserHasPermission`); one export at a time (50035); APPROVED at once without restricted data, or when the user also holds `party.identity.reveal`, else REQUESTED |
   | `cfg.usp_ApproveDataExport` | a holder of `party.identity.reveal` | REQUESTED to APPROVED for restricted data |
   | `cfg.usp_StartDataExport` | the job `JOB-PLT-EXPORT` (new in the catalogue, allowed in TRIAL, ACTIVE, SUSPENDED and CLOSED within the window) | the oldest approved export to RUNNING; returns its scope |
   | `cfg.usp_FinishDataExport` | the same job | records the sealed package as a `doc.Document` of type `DATA_EXPORT_PACKAGE` with one version under the tenant's FILE key (the file is not uploaded, so its scan status is CLEAN); READY for 7 days, or until the CLOSED window ends if sooner |
   | `cfg.usp_FailDataExport` | the same job | FAILED with the reason |
   | `cfg.usp_ExpireDataExports` | the job `JOB-PLT-EXPORT-EXPIRE` | READY packages past their date to EXPIRED, their document soft-deleted, the storage keys returned so the job deletes the files |

2. **Job bindings are checked again at each call** (`sec.fn_JobTenant`): kind JOB, the right JobKey, and a tenant status the job definition still allows. Another job, or a tenant past its CLOSED window, gets 50034.
3. **Audit** (ADR 0007):
   - EXPORT_REQUESTED, EXPORT_APPROVED and EXPORT_READY are high severity. The category is IDENTITY_ACCESS for restricted data and SECURITY otherwise.
   - EXPORT_READY carries the package's SHA-256, as FR-PLT-039 requires.
   - A package with restricted data also writes a DATA_EXPORT row in `aud.SensitiveAccessLog`, linked to its audit row (BR-PTY-009). `aud.usp_WriteEvent` now returns the id of the row it writes.
   - EXPORT_FAILED and EXPORT_EXPIRED are written too.
4. **No direct rights.** `tp_app` (and so `tp_jobs`) loses INSERT and UPDATE on `cfg.DataExportJob`. The package password never reaches the database.

### Error numbers added

| Code | Meaning |
|---|---|
| 50034 | Not allowed: no suitable binding, permission or tenant status |
| 50035 | An export of this tenant is already in progress |
| 50036 | No export in the expected state with this id |
| 50037 | The tenant has no active DATA_EXPORT_PACKAGE document type or no active FILE key |

## Consequences

- **Tests.** X1 to X6 in `db/tests/data_export_tests.sql` pass in CI (`tools/ci/db_ci.sh` step 17):
  - who may request, one export at a time, no direct writes;
  - approval of restricted data;
  - a suspended tenant exporting, where a direct write fails;
  - a closed tenant within and after its window, with the expiry capped;
  - the sensitive access row, and the error when the package type is missing;
  - expiry of packages.
- **Seed and packs.** The platform seed adds `JOB-PLT-EXPORT`, 31 jobs in all. The tenant pack CAT.DOCTYPES must add the system document type `DATA_EXPORT_PACKAGE` (general, sensitive, locked), so 43 types; without it the job stops at 50037. Each tenant also needs an active FILE key (DOC-S02).
- **Application (FR-PLT-039, S5).**
  - The worker builds the package from the scope (JSON or CSV with the files).
  - It leaves out full identity numbers and images unless the export includes restricted data (BR-PLT-016).
  - It seals the package with the requester's password and stores it in the tenant's file store.
  - It then calls `cfg.usp_FinishDataExport`. The download is audited by the application.
- **Closing.** `plat.usp_ApplyTenantStatus` still refuses to close an ACTIVE or SUSPENDED tenant (50027, DQ-F05-7). The database side of the export now exists, but the guard is lifted only when the application builds packages.
- **Limits.**
  - In SUSPENDED and CLOSED only the account administrator is admitted. A restricted export can therefore be approved there only if the account administrator also holds `party.identity.reveal`; otherwise it waits for reactivation.
  - A refused request writes no audit row (as in ADR 0007).

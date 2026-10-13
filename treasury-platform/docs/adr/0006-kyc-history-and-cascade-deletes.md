# ADR 0006: No cascade delete on KYC data; completeness-profile versions do not change once active

Status: decided by the solution architect under DOC-B09 (O-13: SA responsible, DBA accountable). It is not an owner decision. It closes O-13 of tools/dbgen/erd_open_items.py.

## Context

- The model had two cascade deletes, both in db/model/11-organization-party.model. The review found that credit, audit and KYC data must not be deleted by cascade (O-13).
- **`org.CompanyWealthSource` → `org.CompanyKycFinancialProfile`.** The sources of funds and wealth of a company's KYC financial profile (G-4). The profile is dated history: a new profile closes the previous one (`EffectiveTo`), and the application cannot delete a profile. A cascade fires only on a privileged delete, where it would remove KYC data silently.
- **`pty.KycProfileItemLegalForm` → `pty.KycProfileItem`.** The legal forms an item of a completeness checklist applies to (G-15). This is configuration, and a condition has no meaning without its item. But the application could delete items, and with them their conditions, from any version of a profile, including the ACTIVE one. Completeness is checked against that version (FR-PTY-024), and the model says past checks keep their version.

## Decision

1. **No cascade on KYC data.** `org.CompanyWealthSource.FinancialProfileId` loses `cascade`. Deleting a financial profile that has sources of funds fails on the foreign key (547). Removing KYC data is an explicit, approved retention step (FR-PTY-029, `cfg.retention.approve`) that deletes the rows in order.
2. **The cascade from an item to its conditions stays.** The conditions are part of their item.
3. **Profile versions are immutable once active** (`db/static/041_kyc_profile_versions.sql`, error 50033). Triggers refuse:
   - any insert, change or delete of an item or a condition when the profile is ACTIVE or RETIRED, so the cascade can only act inside a DRAFT;
   - a profile that goes back to DRAFT from ACTIVE or RETIRED.
   A change to an active checklist is a new version: write it as DRAFT, add its items, activate it. Retiring and re-activating a version are allowed, since they do not change its content. The rule holds for every caller, seeds included, so a tenant pack writes each profile in that order (DOC-B05 section 5).
4. **Rule R11 in `tools/dbgen/check_grants.py`.** The model may use `cascade` only on the links in `CASCADE_ALLOWED`, which today holds `pty.KycProfileItemLegalForm.KycProfileItemId` alone. A new cascade fails CI step 3 until it is reviewed and listed.

## Consequences

- **Tests.** K1 to K4 in `db/tests/kyc_history_tests.sql` pass in CI (`tools/ci/db_ci.sh` step 14):
  - K1: a financial profile with sources of funds cannot be deleted, by the owner (547) or the application (229). The deployed database has exactly one cascade, the item conditions.
  - K2: a draft is edited freely, and an item takes its conditions with it.
  - K3: the five possible changes to the items and conditions of an active version are refused.
  - K4: neither an active nor a retired version returns to draft.

  With the triggers disabled, K3 and K4 fail, so the tests do detect the guard.
- **Application.** UC-PTY-10 edits a checklist by creating a new version. Activating a version retires the previous one in the same transaction, because only one version may be ACTIVE per bank, role and kind.
- **Not covered.** A closed financial profile (`EffectiveTo` set) can still be corrected by the application. No requirement forbids correcting a closed profile, so this ADR adds no guard for it.

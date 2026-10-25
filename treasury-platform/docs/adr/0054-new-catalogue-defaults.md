# ADR 0054: New catalogue defaults reach existing tenants by kind

Status: built on 2026-10-25, the owner's choice "split by kind" (docs/31 row 57). Written by an AI agent.

## Context

Q-CAT-02 (approved 2026-10-19) and FR-CAT-003 say a new default is announced and added with the tenant
administrator's approval, never replacing the tenant's changes. The daily upgrade (`SeedUpgradeJob`, DQ-F05-9) added
every new row of a newer pack version at once. Some new rows are needed by the platform itself (the system document type
REQUEST_PRINT that saving a request's PDF uses), so holding every new row for approval would break features until then.

## Decision

1. **Upgrade mode** (`SeedMode.HoldOptional`, the upgrade of a tenant already onboarded): a row is added at once when
   the platform needs it, which means a row of a table outside the catalogues, or a catalogue row marked IsSystem or
   IsLocked. A catalogue row that is neither is held, with every row that refers to it. Onboarding keeps `SeedMode.All`.
2. **Offer** (`GET /catalogs/defaults`): the optional rows of the latest packs whose seed key the tenant does not have,
   read live from the packs folder; only those of the catalogues the user manages.
3. **Add** (`POST /catalogs/defaults/apply`): the chosen rows (or all), plus the missing rows of the same packs that
   refer to them and now resolve (their links), insert only, as the application (an optional row is not a system row,
   so the 060 guard lets it in). Audited as CATALOG_DEFAULTS_APPLIED.
4. Nothing is stored for "held": the offer is computed from the packs and the tenant's rows, so it stays until added.

## Consequences

- A tenant changed nothing it did not choose. A renamed or deactivated row keeps its state, because the seeder matches
  on the seed key and inserts only.
- The catalogue screen shows "New defaults available" whenever a release brings optional items.
- An optional row the tenant does not want stays offered. A "dismiss" would need a table, and was left out.

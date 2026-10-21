# ADR 0035: The tenant pack CORE.ROLES: the system roles and their default permissions

Status: decided by the database architect on the owner's request of 2026-10-21, to close finding E2 of the external
review v5.0 ("the risk officer RK is declared in ADR 0030 but absent from the model, the DDL and the seeds"). Builds
on ADR 0029 (the endorsement), ADR 0030 section 5 (RK, owner decision 35) and DOC-B05 section 5.1.

## Context

The review was right, and the gap was wider than it said. No system role was seeded in any tenant: TA, TM, FO, TE,
FA, RQ, AU and RK were defined only in the role matrices of the specs. The pack CORE.ROLES that should seed them was
left to the application's tenant seeder, which is not built. So the endorsement constraint of 052 was in place, but
nothing in the package gave its permission to anyone. The onboarding test inserted the role TA by hand.

## Decision

1. **Generated from the documents.** `tools/dbgen/core_roles_pack.py` reads these sources on every run, so the pack
   cannot drift from the documents:
   - the role matrices of specs 11 to 14;
   - DOC-F07 section 3 and DOC-F09 section 3.2, the default roles of the M0, M1 and proposed codes.
   It writes the pack (`db/seed/packs/CORE.ROLES/v1`: manifest, `sec.Role.csv`, `sec.RolePermission.csv`) and the
   procedure that applies it (`db/static/057_core_roles.sql`). CI regenerates both and fails on a difference.
2. **Reading a cell.**
   - ✔ grants the permission.
   - ◐ grants it as Restricted: the application narrows it by scope, audience or ownership.
   - R grants only a code that views. An R in a manage row means the role reads through another code.
   - M grants a view code that is not sensitive: a masked view, never a reveal.
   - Cells with two codes ("a · b") are read pairwise. One value may stand for both only when it means the same for
     each (✔, R, M, —). A single ◐ over two codes is refused, because it does not say which code it restricts; the
     matrix must give one value per code. "a + b" is one action that needs both codes, so one value is right there.
   - The rule found two such cells, and both were corrected in the specs rather than worked around in the generator:
     - Spec 13 row 14 now reads ◐/— for the requester: it cancels its own requests (`req.cancel`), not any request
       (`req.cancel.any`).
     - Spec 14 row 28 now reads ◐/◐: the scope limit applies to viewing and to exporting reports alike.
3. **Eight roles, 393 links:** TA 46, TM 127, FO 100, TE 51, FA 9, RQ 19, AU 31, RK 10.
   - RQ takes the purchasing column PR of spec 14.
   - Three columns are not seeded, as the manifest says:
     - PO, the platform operator, is not a tenant role.
     - RQM, the requester's manager, comes from an assignment rule.
     - SL, the sales roles, are custom roles seeded with the S4 templates.
   - Two catalogue codes have no default role: `cat.global.manage`, which belongs to the platform, and
     `req.view.department`, which RQM holds.
4. **Checks that stop the build:**
   - every code is in the permission catalogue;
   - a locked permission goes to TM and FO only (BR-PLT-019);
   - no role holds `fin.credit.endorse` together with `fin.credit.assess` or `fin.credit.approve` (ADR 0029);
   - every role has a permission.
5. **Applied in the database** by `sec.usp_SeedCoreRoles`. The onboarding job JOB-PLT-ONBOARD bound to the new tenant
   runs it (stage B of 038), before `sec.usp_InviteFirstAdministrator`. Only tp_jobs may execute it.
   - Insert only (FR-PLT-008). The first run adds every role (IsSystem 1, SeedKey `ROLE.<code>`) and every link.
   - A later run of the same version adds nothing. A link the tenant removed stays removed, and a role it renamed keeps
     its name. The run counts both (SkippedModifiedCount) and lists them (DiffJson) in `cfg.SeedRun`.
   - Each run is audited as SEED_PACK_APPLIED.

## FA and RK in spec 13 (owner decision 36)

Spec 13 now has columns FA and RK. Both hold `ntf.prefs`, their own notification preferences, because both receive
the notifications of its section 9.2, and RK receives the red warning. Neither works in requests.

## Effect on E2

RK is now seeded in every tenant through onboarding. It holds `fin.credit.endorse`, its notification preferences
(`ntf.prefs`) and eight read permissions, and neither assessment permission. A user given RK passes the endorsement's
preconditions (CR4). The constraint of 052 has its holder outside the preparing line.

## Tests

`db/tests/core_roles_tests.sql` CR1 to CR6:
- CR1: the 8 roles and 393 links.
- CR2: a second run keeps the tenant's changes and lists them.
- CR3: the count per role; the locked permissions are on TM and FO only.
- CR4: RK endorses from outside the line.
- CR5: only the onboarding job runs the pack.
- CR6: onboarding stages B and C together.
The onboarding test O3 now seeds through the pack instead of inserting TA.

## What stays open

- **Upgrades.** Version 1 is the only version. How a later version adds new links without overriding what a tenant
  removed is decided with version 2.
- Spec 14 still has no column for FA and RK: neither works with letters of credit.

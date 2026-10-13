# ADR 0011: Fixes of the 40 open design-review findings, applied before their modules' code

Status: decided by the owner on 2026-10-13 (O-15 in `docs/20-database-design.md`). The owner approved the register `docs/32-review-findings-decisions.md` as proposed and every proposed answer to its ten questions. The register's technical decisions (its section 3.2) are the database architect's. This ADR follows the review of 2026-10-11 (`docs/review/design-review-2026-10-11.json`) and its ten critical fixes (C-12).

## Context

- **What was open.** 36 major and 4 minor findings had no decision.
- **What a recheck found.** Each finding was checked again against the model, the generated DDL and the static scripts:
  - one was already resolved (DR-20, by DR-02);
  - four were partly resolved by later work (DR-13, DR-15, DR-17, DR-35);
  - the rest were open.
- **Some of the review's own fixes were wrong.**
  - Some broke an approved rule: self-approval of an export (BR-PLT-016), and a mandatory reveal reason (Q-PTY-05).
  - Some broke the design: a plain unique key on `col.Collateral.SupersedesId`, and binding an LC's terms to the LC.
  - One could not be built: `EOMONTH` in a check.
- **Why the timing matters.** No real data exists and no application code writes these tables. A change therefore costs one model line before a module's code, rework after it, and a migration after real data.

## Decision

1. **Batch A, applied now in four stages.** It covers 33 findings, whole or in part. Each stage was a commit with its own tests passing CI.
   - **Generator** (`tools/dbgen/dbgen.py`, README):
     - every `set{}` column gets a membership check (only distinct allowed tokens, in capitals, no empty item or space);
     - checks accept `COLLATE` and `DATEADD` with hours and minutes;
     - `via` may name the table's own key;
     - `unique global` makes a key unique across tenants;
     - `sametenant` makes a composite reference to a mixed table;
     - the `src` source text is labelled confidential.
   - **S0 tables:** DR-11 to DR-18 and DR-48.
   - **S1 tables:** DR-19, DR-21, DR-23, DR-24, DR-25 (label), DR-29, DR-47.
   - **S2 to S4 tables:**
     - DR-26, DR-27, DR-31 (label and denial), DR-33, DR-34, DR-35, DR-37, DR-38 (unit);
     - DR-40, extended to insurance assignments and valuation schedules by the owner's answer;
     - DR-41 (lines and header), DR-42, DR-43, DR-45, DR-46 (check and labels), DR-49 (sequence key), DR-50.
2. **The owner's answers, as built:**
   - The ERP code is always unique.
   - A value conflict may sit outside a facility (collateral, tariff item, formula template).
   - An insurance assignment belongs to INSURANCE_ASSIGNMENT collateral, and a valuation schedule to REAL_ESTATE and GENERIC.
   - An audited statement does not supersede a management one.
   - An approval hook runs once per stage and action kind.
   - A purchase LC, legacy ones included, names its issuing bank.
   - A rejection needs a reason; a cancellation does not.
3. **What a check cannot hold is in `db/static/043_review_guards.sql`:**

   | Finding | Guard | Error |
   |---|---|---|
   | DR-11 | Column denial on a document version's content | — |
   | DR-14 | Only a delivered outbox event is deleted | 50041 |
   | DR-15 | Only the revocation columns of a support grant change, and a revocation is final | 50042 |
   | DR-16 | A locked permission goes only to the system roles it names, and a role's Code, IsSystem and SeedKey are not the application's | 50043 |
   | DR-18 | A document of a sensitive type is RESTRICTED, and marking a type sensitive raises its documents | 50045 |
   | DR-19 | A revoked or expired signatory is final | 50046 |
   | DR-31 | `tp_readonly` reads no agreement text | — |
   | DR-41 | An issued proforma's content is not updatable | — |

   Also in static scripts:
   - **`028`:** a setting key must be defined; INT, DECIMAL, BOOL, TIME and STRING values are checked; the working day is 4 to 12 hours (50044).
   - **Seed `100`:** `work.start`, `work.end` and `security.reveal.remask_seconds`, nine definitions in all.
4. **Batch B: entry conditions of the slices.** These are approved but belong to a module's design, so each must land before that module's code:
   - **Before S1:** done the same day; see the amendment below.
   - **Before S1-b:** indirect shareholding per path through a named intermediate (DR-22).
   - **Before S2:**
     - existence and facility of a conflict's target (DR-27);
     - revision integrity in the facility trigger, and the stable identity of a limit (DR-28, DQ-F13-4);
     - redaction of IBAN and account numbers in agreement text (DR-31, DQ-S06-7);
     - collateral versions with SUPERSEDED, DISCARDED and a mandatory release document (DR-36);
     - the unit and basis rules in the evaluation service (DR-38).
   - **Before S2-b:** frozen covenant tests (DR-39).
   - **Before S3:**
     - draft-only triggers on terms and published templates (DR-41);
     - binding and reconciling the request copies (DR-44);
     - the comparison service that copies no restricted value (DR-46);
     - the field keys and default template derived from the template (DR-49).
   - **Before S4:** proforma totals checked against the lines (DR-41).
5. **Deferred with a reason:**
   - the check that no row references a retired or revoked key, until the rotation job is built (DR-20);
   - an anchor for the snapshot hash outside the database, with O-13 (DR-41).
6. **Rejected or replaced by a smaller fix.** The 29 sub-recommendations and their reasons are in the register, section 4. One more was set aside during the work: DR-15's `RevokedAt >= StartsAt`, because a tenant may cancel a future grant before it starts.

## Consequences

- **Tests:**
  - `db/tests/review_fixes_tests.sql` holds RF1 to RF18 (CI step 19). Each case fails when its guard is removed, which was checked by disabling them one by one.
  - `tools/dbgen/check_review_fixes.py` now runs in CI step 3. It verifies 59 fixes, the ten critical ones included, on the generated DDL.
  - Existing tests changed where a fix made their set-up invalid:
    - the support tests write their 80-hour grant with the new check off;
    - the export tests give a cleared job an expiry, use PublicId paths, and use a non-sensitive package type;
    - the numbering tests no longer write the computed ERP code.
- **Model and spec:**
  - `pty.Party.LinkedCompanyId` is gone; the mirror is found through `org.Company.PartyId`. The entity dictionary of specification 10 and the glossary (DOC-B10) follow.
  - `fac.Utilization.SourceRefId` is gone: an LC utilisation is linked from `lc.LetterOfCredit.UtilizationId` only (DQ-F12-14).
  - `ref.Country.WeekendDays` and the two body-type lists are `set{}` columns.
- **ADR 0008:** the tenant pack's `DATA_EXPORT_PACKAGE` type is not sensitive. Otherwise every package would be RESTRICTED; the procedure raises a restricted package itself.
- **Diagrams:** the relationship charts and `docs/20-DATABASE-RELATIONSHIPS-ERD.docx` are rebuilt from the model.

## Amendment, 2026-10-13: the S1 entry conditions are done

The three batch B items due before S1 were built at once, so the schema of S0 and S1 is complete before their code.
- **DR-16.** `cfg.ExpiryAlertRule.RecipientRoles` (a JSON code list) is replaced by the junction `cfg.ExpiryAlertRuleRole`. Its composite key to `sec.Role` keeps every recipient a role of the rule's tenant, and a renamed role still receives.
- **DR-25, DQ-F02-8.** `org.Company.TaxNumber` is dropped. The view `org.v_CompanyTaxIdentity` (025) reads the tax and VAT numbers from the current tax identity of the company's mirror party in its country of incorporation, under the row filters of both tables.
- **DR-30, the owner's answer.** `cat.ProductFinancingType` carries copies of the product's compliance and the financing type's Islamic flag through composite keys, and a check allows only these pairs: conventional with conventional, Islamic with Islamic, neutral with both. A used product's compliance and a used type's flag no longer change.

Tests RF19 to RF21 pass in CI, and `check_review_fixes.py` verifies 61 fixes. Each test fails when its guard is removed.

## Amendment, 2026-10-13: the entry conditions of S1-b to S4 are done

Every batch B item is now built. The model holds the declarative part; `db/static/044_entry_guards.sql` (after 043 in `db/deploy.sql`) holds what a check cannot see. An error raised in a trigger ends the caller's transaction, so the application validates first and the trigger is the last line.

| Slice | Finding | What was built | Error |
|---|---|---|---|
| S1-b | DR-22 | `org.Shareholding.IntermediatePartyId` names the intermediate of each indirect path. A path never passes through a company of the tenant, and a party that is the intermediate of an open path becomes a company only after the path closes. | 50047 |
| S2 | DR-27 | A value conflict names an existing row of its target table and carries that row's facility; a collateral or tariff item has none. | 50048 |
| S2 | DR-28, DQ-F13-4 | Every revisioned table gets `InheritedRootId` and a computed `RootId`, the stable identity of a node across revisions, bound through `SupersedesId` by a composite key, with one open row per root. An approved revision is final; `ApprovedRevisionNo` only moves forward and names an approved revision; approving refuses two rows of one node or a parent outside the revision. | 50049, 50050 |
| S2 | DR-31, DQ-S06-7 | A `redact` column token in the generator adds a check that refuses ten digits in a row or an IBAN in groups of four. Every `OriginalText`, the candidate texts of a value conflict and an obligation's clause text carry it. | 547 |
| S2 | DR-36 | Collateral versions share `RootId`; one draft and one current approved version per root; SUPERSEDED and DISCARDED; a release needs its document; a link names the root. | 50052 |
| S2 | DR-38 | A covenant copies its formula's result unit and statement use through a composite key. The threshold unit is the formula's and fits the measure kind, and a formula on statements needs the basis and assurance. A used formula keeps its unit. | 547 |
| S2-b | DR-39, DQ-F15-4 | `obl.CovenantTest.FormulaId` replaces `FormulaVersion`. An evaluated test changes only by its review. An automatic evaluation names a non-draft version of the covenant's formula, and its snapshot holds that version, the covenant's threshold and operator, and every input it read (BR-FIN-010). | 50053, 50054 |
| S2-b | DR-39, DQ-F15-13 | An agenda item that left SCHEDULED keeps its status, obligation and period; a submission's details may be corrected. | 50055 |
| S3 | DR-41 | LC terms are written as a draft, get their clauses and charges, then lock. A locked version changes only in its treasury fields, until `TreasuryHash` (BR-LCT-019). The trigger is built from the table's columns, so a new column is frozen unless named. | 50056 |
| S3 | DR-41, DR-49 | A template version is written as a draft, gets its parts, then publishes; a published version only retires, and its parts do not change. One current template per request type; a template key stays with one type. `RequestType` loses `DefaultTemplateKey` and the three field keys. | 50057, 2601 |
| S3 | DR-44, DQ-F11-10 | The request's copies of its current stage instance and of its reservation stay, for the queue and SLA indexes, but the database is their only writer. Triggers copy them, `tp_app` is denied the columns, and both references are composite keys to the request itself. `wfl.RequestCopyDrift` lists any that differ, for the new job `JOB-PLT-RECONCILE`. | 230, 547 |
| S3 | DR-46, DQ-F12-11 | `lc.LcFieldDefinition.Sensitivity`; the IBAN field is always RESTRICTED. A restricted field is never copied into a comparison line or an amendment's changed fields. `lc.BeneficiaryIbanChange` reads the change from the keyed hash, or says the keys differ. | 50058 |
| S4 | DR-41 | A proforma's lines are written once, in one statement; each line total, the subtotal and the VAT follow BR-LCE-001. `lc.ProformaTotalsDrift` lists a header without lines. | 50059 |

- **Tests:** RF22 to RF34 pass in CI step 19 (34 cases), and `check_review_fixes.py` verifies 75 fixes. Each trigger was disabled in turn, and so was the column denial of DR-44; each time its test failed.
- **What the application now owes the database:**
  - the order of writing versioned data (draft, then its parts, then lock or publish);
  - one statement for a proforma's lines;
  - the snapshot shape of an automatic evaluation;
  - ChangedFieldsJson as an object keyed by field key.
- **Still deferred:** the external anchor of the snapshot hash (with O-13), and the check that no row references a retired key (DR-20).

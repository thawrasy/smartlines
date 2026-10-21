# ADR 0037: The maker and the checker are the user of the session; what a closed period freezes indirectly

Status: decided by the database architect on the findings of the internal review of 2026-10-21 (lens E, findings 1,
2, 7 to 12, 14, 15, 17, 18 and 23). Builds on ADR 0016 (statements), ADR 0017 and ADR 0022 (assessments and trials),
ADR 0023 (presentation versions), ADR 0024 and ADR 0027 (readiness and early warnings), ADR 0029 and ADR 0030 (the
endorsement, the evidence pack, the confirmed monthly figures, the provision matrix) and ADR 0031 (the period close).

## Context

The columns that name who prepared, entered, approved, confirmed or chose a record (`PreparedBy`, `EnteredBy`,
`ApprovedBy`, `ConfirmedBy`, `ChosenBy`) were written by the application. A CHECK compared them with each other, so the
maker and the checker had to be two ids, but nothing tied either id to the user of the session or to the permission of
the act. An application with a fault, or one used to work around the separation, could prepare and approve alone.

The review found further gaps:
- one user could reopen a confirmed figure, edit it, and confirm it again;
- a presentation version could restructure an approved, audited statement and keep its opinion;
- a closed period could still change through what is not a statement or a monthly figure;
- the calibration and the early warnings read drafts and trials;
- the evidence pack left out what the computation read;
- the submission hash left out the platform data;
- group support could come from an investor that does not control the company;
- the provision matrix counted an ageing that did not add up;
- loss rates had no maker-checker;
- the early warning read a facility from the assessment's snapshot;
- the endorsement could come from the statement's own approver.

## Decision

1. **The actor is the bound user** (`db/static/058_actor_controls.sql`). Triggers compare every actor column that is set
   or changed with `SESSION_CONTEXT(N'UserId')` of a USER binding of the tenant (`sec.fn_BoundAsUser`). They check the
   permission of the act through the user's active roles (`sec.fn_UserHasPermission`, as 052 and 053 do), through
   `fin.fn_ActingUser`. The triggers run as the caller: their ownership chain reads the binding and role tables.

   | Record | Maker (permission) | Checker (permission) |
   |---|---|---|
   | statement | preparer set or changed, and the submission (`fin.stmt.enter`) | approval; rejection and supersession (`fin.stmt.approve`) |
   | assessment | preparer, submission and computation (`fin.credit.assess`) | approval, rejection, supersession (`fin.credit.approve`); endorsement (`fin.credit.endorse`) |
   | analyst's input | every input written names its author (`fin.credit.assess`) | |
   | presentation version | preparer; the build by the preparer (`fin.stmt.enter`, and `fin.credit.assess` for its trial) | the choice (`fin.stmt.approve`) |
   | revenue estimate | every change of a draft names its preparer (`fin.stmt.enter`) | approval as prepared; supersession (`fin.stmt.approve`) |
   | monthly balance, bank flow | every change of content names its author (`fin.stats.enter`) | confirmation as entered; reopening (`fin.stats.confirm`) |
   | loss rate | every change of a draft names its preparer (`fin.formula.manage`) | approval as prepared (`fin.formula.approve`) |

   - A job binding, a support binding or no binding acts for no one: such writes are refused (50170).
   - A statement and an assessment are written as drafts (045, 046). A revenue estimate, a monthly figure and a loss
     rate are now written as drafts too (50173), so no record is inserted already approved.
   - The computation of an assessment (047) is checked through the results it writes (`ComputedAt` changes), so
     `fin.usp_ComputeCreditAssessment` needs `fin.credit.assess` without a change to 047.
   - The build and the choice of a presentation version check the binding and the permission in their procedures too
     (048).
2. **A reopened figure** (finding 2):
   - after a reopening, the next change of the figure's content must name its editor as `EnteredBy` (50170);
   - the reopener does not edit it (the CHECK `LastReopenedBy <> EnteredBy` of the model);
   - a new CHECK keeps the reopener from confirming it (`ConfirmedBy <> LastReopenedBy`);
   - so a figure reopened by one user is edited by a second and confirmed by a third, or by its first confirmer;
   - a confirmed figure has an author (a CHECK).
3. **Loss rates** (finding 15) get a `PreparedBy` column with two CHECKs: the approver is not the preparer, and a rate
   without a preparer is a default of the pack FIN.PROVISION (`SeedKey`). An approved rate does not change and is not
   deleted (50173); a change is a rate with a later `EffectiveFrom`.
4. **Approved revenue estimates** do not change and are not deleted; an approved one only moves to SUPERSEDED (50173).
   The approver changes nothing while approving (50172).
5. **Presentation versions** (finding 7) start from a draft or a submitted statement only. Owner decision 34 lets the
   company restructure its presentation before the final approval. An approved, perhaps audited, statement keeps its
   assurance, auditor and opinion and is corrected by a version of its own (045) (50090). The notch for a restatement
   of an approved statement is in 047 and not changed here.
6. **The close reaches what changes a period indirectly** (finding 8, 053; 50096), where a row carries a date tied to a
   period:
   - an official assessment of an actual statement of a closed period is not added and changes no status (submitted,
     approved, superseded). A trial is still allowed, and so is the endorsement of an approved assessment, which
     changes no figure;
   - a revenue estimate is closed when the fiscal year it covers ends in a closed period. The year Y ends on the last
     day of the company's fiscal year end month of Y;
   - a lender rating is closed when it is dated in a closed period;
   - product lines are closed when their fiscal year ends in a closed period;
   - a loss rate is closed when it takes effect on or before the latest closed day of any company of the tenant. Rates
     are the tenant's and are not tied to one company, so a new rate takes effect after the close.
7. **Records once used are frozen** (finding 9, 058; 50173):
   - a lender rating confirmed against the lender's letter (`VerifiedBy`);
   - a lender rating dated on or before the `EndorsedLastRatingDate` of an endorsed assessment;
   - the product lines of a year that an approved or superseded assessment of the company read.
8. **A consolidation and the close** (finding 23). Once a holding closes the period of an approved consolidated
   statement, the actual statements of its units for that period are closed too: the unit's statement named on the
   unit, or any with a period end within the consolidated period. A unit's monthly figures are closed by the unit's
   own close.
9. **The calibration and the early warnings** (findings 9 and 17, 049):
   - a lender rating is compared with official assessments only, an approved one first;
   - the calibration takes approved official assessments only, so a draft cannot move the bias that the endorsement
     records and the readiness reads;
   - the early warnings read the latest approved official assessment and the latest computed one. For each lender date
     they keep the worse readiness of the two, the approved one on a tie. A draft can add a warning, never hide one, and
     a trial is never read;
   - on a run date the renewal is read from the facility as it is now, at its approved revision (lenders where
     `FromRevision <= ApprovedRevisionNo < ToRevision`): its expiry, its main lender and the lender's decision effective
     that day. The readiness of an assessment on its own date keeps what the assessment read.
10. **The evidence pack** (finding 10, 052) is built of the approved assessment only: not a superseded one, not a trial
    (50095). It adds:
    - `InputsHash` and `Snapshot`;
    - the analyst's inputs, with their justifications and the SHA-256 of their documents' current versions;
    - the guarantors and the bureau report, with the same;
    - the facilities and collateral the computation read;
    - the covenant tests of the statement;
    - the scorecard by code and version, with the SHA-256 of its weights, grids, adjustments and parameters.
11. **The submission hash** (finding 11, 046) takes a digest of the platform data the computation reads
    (`fin.fn_CreditAssessmentPlatformDigest`):
    - the company's facilities with their lenders, limits, uses started by the assessment date, linked collateral and
      the lenders' decisions effective by then;
    - its covenant breaches and covenants;
    - its bank flows to the assessment date and its revenue estimates;
    - the covenant tests that read the statement;
    - the country, region and activity profiles.
    A platform row counts by its row version and a global profile by its content. We chose a digest over computing the
    assessment again at submission: it costs one read, and it is the same function the computation and the report use.
12. **Group support** (finding 12, 046) comes from the parent, or from a holding whose approved consolidated statement
    includes the company as a SUBSIDIARY consolidated in full (method FULL). An associate, a joint venture or a unit
    left out of the consolidation is an investor, not a parent (50065).
13. **The provision matrix** (finding 14, 049) is INCOMPLETE, not ADEQUATE, in three cases:
    - the four ageing buckets do not add up, within 1%, to the gross receivables (`AR_GROSS`, else
      `AR + AR_ECL_ALLOWANCE`);
    - the government part over a year exceeds the part over a year;
    - the recorded allowance is negative.
    A CHECK cannot hold a statement line of one code, so the sign is read here.
14. **The endorsement** (finding 18, 052) is refused:
    - to the statement's preparer and approver;
    - to the user who chose the presentation version that became the statement;
    - for an assessment that is not approved, which covers a superseded one.

Errors 50170 to 50173 are new, from the range 50170-50189 reserved for this work:
- 50170: the actor is not the user bound to the session, or the session is not a user's;
- 50171: the bound user lacks the permission of the act;
- 50172: one person would act twice, which the CHECKs cannot see;
- 50173: an approved, confirmed, verified or used record is changed or deleted, or is written directly in a final
  state.

The extensions of the close keep 50096, presentation versions 50090, the endorsement 50093, the evidence pack 50095,
and group support 50065.

## Open points

- **A second person for the close.** The close (`fin.usp_LockReportingPeriod`) is still made by one holder of
  `fin.period.lock`. A second person would need a proposed state and a confirmer in `fin.ReportingPeriodLock`. A close
  only freezes; the reopening unfreezes, and it already needs another user. So we leave this to the owner.
- **The reading of approved revisions in 047.** The engine (047) reads lenders, limits and collateral links at the
  approved revision with `ToRevision >= ApprovedRevisionNo`. 045 and this decision use `ToRevision > ApprovedRevisionNo`.
  This belongs to the engine, as do the notches for a restatement.

## Consequences

- One static script (058): one function and ten triggers. 053 gains five triggers, and 046 one function.
- The model gains one column (`fin.ReceivableLossRate.PreparedBy`, with its foreign key) and seven CHECKs:
  - two on each monthly figure table;
  - one on revenue estimates;
  - two on loss rates.
- No table or permission is added: the existing permissions of spec 12 carry the acts.
- Test file `db/tests/finance_controls_tests.sql` (CI step 22f) has 14 cases, FC1 to FC14. The fixtures of the
  statements, assessments, performance and readiness tests now bind the approver to approve and the author to
  enter, with roles holding the permissions:
  - `db/tests/financial_statements_tests.sql`;
  - `db/tests/credit_assessment_tests.sql`;
  - `tools/perf/perf_seed.sql`.

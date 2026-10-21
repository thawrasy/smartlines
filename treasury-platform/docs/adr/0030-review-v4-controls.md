# ADR 0030: Confirmed monthly figures, the evidence pack, calibration in the readiness, the risk officer and the provision matrix

Status: decided by the database architect on the owner's decision 35 of 2026-10-20 (docs/31-owner-decisions.md), which
approves items 1, 3, 4 and 5 of the study of the external review v4.0 (docs/38-review-v4-study.md) and the decisions
D1, D4 and D5. Builds on ADR 0024, ADR 0026 to ADR 0029.

## Context

The study of the review v4.0 found four things the system lacked:
- a confirmed monthly balance or bank flow could be edited, which silently changes the bank-flow performance on a
  later re-evaluation;
- an endorsed assessment had no single, sealed evidence pack for an auditor or a lender;
- the calibration against the lenders measured the bias but did not act on it;
- the endorsers received no early warning.

The owner also decided:
- a risk officer role (D1);
- a provision matrix to compare the company's recorded allowance with (D4);
- the default message texts approved, the treasury being the authority to change them (D5).

## Decision

1. **Confirmed monthly figures** (BR-FIN-048).
   - `fin.AccountMonthlyStat` gains `EnteredBy`, `ConfirmedBy` and `ConfirmedOn`, with the maker-checker check that
     `fin.BankFlowEntry` has.
   - Both tables gain `ReopenCount`, `LastReopenedBy`, `LastReopenedOn` and `LastReopenReason`.
   - The triggers `TR_*_ConfirmedFrozen` (052) refuse any change or delete of a CONFIRMED row (50094). The one way
     back is `fin.usp_ReopenMonthlyFigure(@Kind, @Id, @Reason)`: a user who holds `fin.stats.confirm` and is not the
     author returns it to DRAFT with a reason. It is counted, audited (MONTHLY_FIGURE_REOPENED, high severity) and
     confirmed again by the usual maker-checker.
2. **The evidence pack** (BR-FIN-049). `fin.usp_BuildAssessmentEvidencePack(@AssessmentId, @Purpose)` gives one JSON
   document of an endorsed assessment:
   - the report;
   - the statement and every version it supersedes, and its lines;
   - the factors, findings, reconciliation, remedies and scenarios;
   - the lender ratings, the calibration and the provision check;
   - the audit rows of the assessment and its statements.
   Its SHA-256 (over the UTF-16LE text) and its purpose are logged in `fin.AssessmentEvidencePack` and audited
   (EVIDENCE_PACK_BUILT). The same content gives the same hash. It is built by an endorser or an approver, for an
   endorsed assessment only (50095). The application cannot write the log.
3. **Calibration in the readiness** (BR-FIN-046). The tenant setting `fin.calibration.max_age_months` (12, from 3 to
   36) sets how long a lender rating calibrates the assessment.
   - Two AMBER reasons come after all the others: CALIBRATION_OPTIMISTIC, when the company rates itself a notch or more
     above its lenders on average; and CALIBRATION_STALE, when its latest lender rating is older than the setting.
   - The requests ask the lenders for a rating when none is recent (CALIBRATION: NO_LENDER_RATING or
     LENDER_RATING_STALE).
   - The endorsement keeps the bias, the number of ratings and the latest rating date of its day.
   - `fin.v_LenderRatingComparison` and `fin.v_LenderRatingCalibration` move to the start of 049, so the readiness
     reads them.
4. **The endorsers are warned** (item 5). The pack NTF.BASE sends FIN.READINESS_RED also to the holders of
   `fin.credit.endorse` (RecipientKind PERMISSION), whatever their role. `tools/dbgen/ntf_pack.py` checks a
   permission rule against the catalogue.
5. **The risk officer RK** (D1). A system role of CORE.ROLES beside AU: a function independent of the line that prepares
   and approves. In the role matrix of spec 12 it reads what the auditor reads and holds `fin.credit.endorse`, so it
   endorses and receives the red warnings. A tenant may give it more.
   - *Correction of 2026-10-21 (external review v5.0, E2).* What this decision built is the role's definition: the
     column RK of the role matrix in spec 12, the row of DOC-B05 section 5.1, and the recipient code in
     `tools/dbgen/ntf_pack.py`. It is not a row of `sec.Role`: no system role is seeded in any tenant yet. The pack
     CORE.ROLES that seeds TA, TM, FO, TE, FA, RQ, AU and RK, with their permissions, belongs to the application's
     tenant seeder (DOC-B05 section 5.1) and is not built. The words "a system role of CORE.ROLES" described the
     design, not something the package holds. Until the pack exists, the endorsement constraint of 052 is in place but
     has no seeded holder.
   - *Closed on 2026-10-21 (ADR 0035).* The pack CORE.ROLES is built: generated from the role matrices, applied by
     `sec.usp_SeedCoreRoles` (057) during onboarding, and it seeds RK with `fin.credit.endorse` in every tenant
     (CR1 to CR6).
6. **The provision matrix** (D4, BR-FIN-047). `fin.ReceivableLossRate` holds a loss rate per ageing bucket, government
   receivables over a year apart, with its effective date and its approval by the treasury.
   - `fin.v_ReceivableProvisionCheck` (049) gives, for each statement with an ageing, the expected allowance beside
     AR_ECL_ALLOWANCE, the shortfall, the status (NO_AGEING, NO_RATES, SHORTFALL below 90% of expected, ADEQUATE) and
     whether the rates used are approved.
   - A shortfall is a readiness request (PROVISION: ECL_SHORTFALL).
   - The comparison informs the company and its lender. It does not change the grade.
   - The pack FIN.PROVISION holds generic default rates as DRAFT for the treasury: 1, 5, 20 and 50 percent, and 10 for
     government receivables over a year.
7. **The message texts** (D5). The pack NTF.BASE is approved as the default. The treasury is the authority to keep a
   text or override it per tenant (`IsTenantOverride = 1`).

## Consequences

- Two tables (251 in all), eleven columns, one setting, two procedures and two triggers in 052, one view in 049, the
  pack FIN.PROVISION, one rule in NTF.BASE.
- Tests:
  - CA27: freeze and reopen;
  - CA28: the evidence pack;
  - CA29: calibration in the readiness;
  - CA30: the provision matrix;
  - CA24: the red warning's fourth rule.
- The bias thresholds, the calibration age, the loss rates and the 90% tolerance are a first calibration that the
  treasury validates.

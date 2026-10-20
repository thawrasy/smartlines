# ADR 0029: Endorsement for use outside the company, the reason for a choice, and the calibration against lenders

Status: decided by the database architect on the owner's request of 2026-10-20 to build items 1 to 3 of the response
to the external architectural review v3.0 (docs/37-review-v3-response.md). Builds on ADR 0022 to ADR 0026.

## Context

The review v3.0 found that a company's own assessment could be shown outside the company with no one outside the
line that made it vouching for it. It also found that the reason a presentation version was chosen was optional,
and that the lenders' ratings were compared one by one but never over time. Its claim that separation of duties was
a policy only does not hold (the CHECK constraints and 048 refuse a preparer who approves or chooses, CA19). The
three findings above do hold, and each fits a company assessing itself.

## Decision

1. **Endorsement** (BR-FIN-043). An approved assessment of an actual statement is internal until endorsed.
   - The new permission `fin.credit.endorse` is held by AU (the internal auditor) in the role matrix of spec 12. The
     tenant may give it to a CFO or an audit committee member instead.
   - `fin.usp_EndorseCreditAssessment(@AssessmentId, @Note)` (052) endorses once, with a mandatory reason and scope,
     by a bound user who holds the permission, holds neither `fin.credit.assess` nor `fin.credit.approve`, and is
     neither the preparer nor the approver. Error 50093.
   - The columns `EndorsedBy`, `EndorsedOn` and `EndorsementNote` on `fin.CreditAssessment` have CHECK constraints:
     approved or superseded, not trial, endorser different from preparer and approver.
   - The 046 trigger keeps the endorsement once given, and the application role is denied UPDATE on its columns.
   - The report shows `UseScope`: ENDORSED or INTERNAL_ONLY.
2. **The reason for a choice** (BR-FIN-044). `fin.PresentationVersion.ChoiceReason` is required when a version is
   chosen, by a CHECK and by `fin.usp_ChoosePresentationVersion(@VersionId, @Reason)` (048), and denied to the
   application.
3. **Calibration over time** (BR-FIN-045). `fin.v_LenderRatingCalibration` (052), for each company over all lenders
   and for each lender:
   - the number of ratings compared, the mean gap in notches (positive: the lender is more severe), the mean of the
     latest three and the latest gap;
   - the bias: INSUFFICIENT below three ratings, OPTIMISTIC at a mean of one notch or more, CONSERVATIVE at minus one
     or less, ALIGNED otherwise.

## Consequences

- Three columns on `fin.CreditAssessment`, one on `fin.PresentationVersion`, one permission (143 in all), one static
  script (052).
- Tests:
  - CA25: the endorsement and its five refusals;
  - CA26: the calibration, optimistic, conservative and aligned;
  - CA19 case 7: a choice without a reason is refused.
- What the review proposed and this ADR does not take:
  - an IFRS 9 expected credit loss model, a lender's measure; the company is the borrower (docs/37 section 3.1);
  - a mandatory risk function, an organisational choice of each company that the endorsement permission allows.
- The thresholds of the bias (three ratings, one notch) are a first calibration; the treasury validates them.

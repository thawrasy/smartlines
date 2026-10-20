# ADR 0025: Budget statements assessed before the plan is carried out

Status: decided by the database architect on the owner's decision of 2026-10-20 (docs/31-owner-decisions.md decision 34,
docs/36-internal-perspective-study.md gap F5, phase E). Builds on ADR 0022 (the trial assessment) and ADR 0023
(presentation versions).

## Context

A company plans its next year (a budget, an expansion, a new loan) and wants to know, before it acts, whether the plan
weakens its grade, and which alternative is stronger: a loan or new capital, a short or a long tenor. The assessment
read only statements of years that had passed.

## Decision

1. **`fin.FinancialStatement.Nature`**: `ACTUAL` (the default) or `BUDGET`. A budget is prepared by the management
   (`MANAGEMENT`, no audit opinion) and **stays a draft**: it is never submitted or approved (BR-FIN-039, a check). So
   none of the platform's uses of approved statements (covenant tests, consolidation, bank flows, the comparison
   statement of an assessment) ever reads a budget.
2. **Its own series.** The nature joins the series of a statement: the key (company, period, basis, assurance, nature,
   version) and the series a new version supersedes. A budget of 2026 and the actual statement of 2026 entered later do
   not collide, and a budget never supersedes an actual statement.
3. **Assessed by a trial only** (ADR 0022): an official assessment of a budget is refused (50064). Its comparison
   statement is an approved actual statement, chosen as for any assessment. Its summary says that it is a budget.
   It is read with the assurance, audit opinion and going concern of that actual statement: a budget is the
   management's by nature, and the notch of an unaudited annual statement would otherwise show in every budget, hiding
   the plan's own effect.
4. **The comparison** (049): `fin.v_BudgetComparison` sets a budget's trial beside the latest assessment of an earlier
   actual statement of the company (the approved one first), with the notches the plan gains or loses;
   `fin.v_BudgetFactorComparison` sets each metric of the budget beside the same metric of the actual.
5. **Alternatives of a plan** are presentation versions of the budget (ADR 0023): the same remedies, balanced, each a
   new budget draft of the same series with its trial; a budget version may be chosen to replace the budget.
6. **No early warning from a budget**: the warnings read the assessments of actual statements only, since a budget
   looks ahead of the lender's dates rather than reporting on them.

## Consequences

- One column on `fin.FinancialStatement`, a wider series key, two views in 049; 047 and 048 read the nature.
- Test CA21: an official assessment of a budget refused; a budget not submitted; a budget equal to the actual year at
  the actual grade (Ba2) and noted as a budget; a budget that borrows 300 million more to buy fixed assets loses a
  notch (Ba3), its largest loss on the balance sheet quality factor; a budget raises no early warning.
- The comparison of grades casts the notch numbers to integers before subtracting them (they are tinyint): a negative
  difference overflowed; the same correction applies to `fin.v_PresentationComparison` (ADR 0023).
- Known limit: a covenant is not evaluated on a budget, since its formulas are evaluated by the covenant service on
  approved statements; the budget's metrics show the trend of the measures behind the covenants.

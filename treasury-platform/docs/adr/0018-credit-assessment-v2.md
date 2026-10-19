# ADR 0018: The credit assessment, version 2: item by item, linked to the platform, with scenarios and strengthening plans

Status: decided by the database architect, building the owner's requests of 2026-10-19. The content (lines, metrics,
grids, item rules, remedies, activities, products, bureau rules) was drafted and reviewed by separate AI agents in the
role of senior credit analysts, not by a human; the owner decides the open points of docs/35 section 24, and the
bank's credit risk function validates the calibration before a grade is used in a credit decision. Supersedes the
computation of ADR 0017; its scale, life cycle and guards stay.

## Context

The owner found version 1 too shallow and asked, in three messages of 2026-10-19:
- for every point of the balance sheet: its risk, its effect on cash and on the partners' solvency, its weight, and
  the best way to re-classify and re-tabulate it to lower the risk; the size of the market and of cash, the type of
  sales, collateral against debt, trade creditors, the type of assets, the facilities and the reliance on funding,
  the type of expenses;
- a design as rating experts of Moody's, Fitch and SIMAH would do it: linked to the facilities recorded on the
  platform, asking for the detailed data it needs, showing the grade expected of the company's sector, and reading
  the company's products for the quality of its cash flows and the liquidity of its inventory in stagnant markets and
  financial crises;
- with five Moody's documents attached: a comprehensive analysis, and a ready-made scenario of the best plans to
  strengthen the statements on request, without breaking their balance.

Version 1 had 36 metrics on 51 lines, one procedure, and no link to the platform's facilities.

## Decision

1. **One source, two implementations that check each other.** `tools/dbgen/credit_scorecard.json` holds the whole
   methodology: 157 standard lines, 112 metrics with their calculation patterns, 3 scorecards with 134 item rules
   each, 44 adjustments, liquidity, LGD bands and collateral haircuts, 61 activities with their scenarios, 15 product
   categories, 39 remedies with their pro-forma steps, 10 strengthening plans, the outlook rules and 67 report texts.
   `db/seed/104`, the tables of docs/35 and the engine cases are generated from it. `tools/dbgen/credit_reference.py`
   computes everything in Python; `db/static/047` computes it in T-SQL; 94 generated cases compare them number for
   number (core and full evaluation), and CI fails when the committed cases are stale.
2. **Three layers in the database** (047):
   - `fin.usp_CreditCore`: one evaluation of a statement held in temporary tables: the analytical statement with its
     reconciliation, the named quantities, every metric, the factors, the item levels, the completeness, the
     adjustments, the grades, the liquidity label and the facility grade;
   - `fin.usp_CreditEvaluate`: the core on the statement, on the two scenarios of the activity (with the resilience
     overlay), on the pro-forma statement of each remedy, and on each step of the strengthening plans when asked; then
     the triggers and the outlook;
   - `fin.usp_ComputeCreditAssessment`: reads a draft assessment from the tables (statement lines by standard code,
     inputs, guarantors, bureau report, activity, product lines, covenant breaches and bank flows, and the company's
     facilities and collateral on the platform on the assessment date), runs the evaluation, and writes the results.
3. **The analytical statement is explicit.** Each reclassification is a row with its reason
   (`fin.CreditAssessmentReclass`); a subordination, a capital resolution or a waiver changes the reading only with a
   document (`EVIDENCE` inputs).
4. **Blank is not zero for detail.** A LINE absent is zero and a TOTAL absent is the sum of its components, but an
   "of which", detail or disclosure absent is unknown, and an "of which" above its line is ignored and reported.
   BR-FIN-002 changes accordingly.
5. **The platform feeds the assessment.** The facilities and collateral on the assessment date (approved revision,
   utilisation, lenders, commitment, expiry, collateral by structure, personal guarantees) are written as a snapshot
   (`fin.CreditAssessmentFacility`) and drive liquidity, the bureau comparison and the facility grade.
6. **Remedies and plans keep the balance sheet balanced.** Every pro-forma step is a double entry capped by the line
   it decreases; the balance sheet totals are rebuilt and the gap (assets less liabilities and equity) is checked at
   every step. Plans run only when the company asks (`StrengtheningRequested`).
7. **The outlook and the triggers** are fixed rules of this system (docs/35 section 16), not an agency's.
8. **The documents the owner attached** were studied. Two of them forbid using their content to develop a model,
   methodology or database, and the others are copyrighted; no grid, weight, default rate or text was taken from them.
   The calibration stays this system's own.

## Consequences

- 237 tables: 24 new, of which 14 global (`ref.Industry`, the activity profiles and scenarios, product categories,
  standard lines and totals, scorecard parameters and sub-factors, remedies with their triggers and steps,
  strengthening plans and their members, report texts) and 10 of the tenant (guarantors, bureau report, product
  lines, reclassifications, facility snapshot, remedies, scenarios, plans and their steps, triggers); new columns on
  the assessment and its inputs.
- 046 keeps the guards; the computation, the engine, thirteen report views and their grants are in 047.
- Tests: CA1 to CA15 through the tables (step 19c) and 94 engine cases (step 19d); 35 stress cases (step 3).
- Known limits: docs/35 section 25.

Note (2026-10-19, later the same day): ADR 0019 replaces the three scorecards with sixteen sector family scorecards, the
activity scenarios with six macro scenarios computed from sensitivities and country exposures, and the single sovereign
ceiling with a ceiling per country; and the owner decided that the company's treasury department, not the bank's credit
risk function, validates the calibration.

# ADR 0017: The credit assessment of a balance sheet on the Moody's scale

Status: decided by the database architect, building the owner's request of 2026-10-18. The calibration is an expert
judgment revised after an independent review by a separate AI agent in the role of a senior credit analyst
(not a human review); the owner decides the open points of
docs/35 section 15, and the bank's credit risk function validates the thresholds before a grade is used in a credit
decision.

## Context

The owner asked that the study of a balance sheet give a comprehensive assessment, with its strengths drawn from the
financial ratios, how they sit with the covenants, and the resulting risks, in a report of the system; the criteria
on the basis of Moody's published rating scale and scorecard approach (the owner's choice; ADR 0038 corrects an
earlier claim about how widely it is used): a weight for each ratio, risk grades for each balance sheet item and the
analyses drawn from them. The link to an external credit rating system stays a later phase.

The model held approved statements, their units, the covenant tests that read them, the breach register and the bank
flow performance (ADR 0016). It had no ratios of credit analysis, no grades, no strengths or weaknesses and no
report. Moody's publishes the mechanics of its scorecards but not, to us, the grids of each sector, and its grids
are for rated issuers, mostly large.

## Decision

1. **Scale and mechanics of Moody's.**
   - `fin.RatingGrade` holds the 21 grades of the long-term scale and their range on the continuum: Aaa below 1.5,
     then one notch per point, Ca from 19.5. C is not reached by the scorecard.
   - A metric scores linearly between the nine boundaries of its grid (scores 0.5, 1.5, 4.5 ... 19.5, 20.5), and
     takes an end of the continuum beyond them.
   - A qualitative grade takes the midpoint of its range.
2. **The methodology belongs to the platform**, as global data seeded from one file:
   - `tools/dbgen/credit_scorecard.json` holds the metrics, three sector scorecards (general corporates, trading,
     contracting) with their weights and grids, 23 balance-sheet item rules each, 17 adjustments and a sector ceiling for contracting.
   - `db/seed/104` is generated from it, and so are the tables of docs/35. CI checks the seed is current.
   - An approved scorecard, and the grades and metrics it uses, never change (50066); a new calibration is a new
     version.
3. **The database computes.** `fin.usp_ComputeCreditAssessment` reads the lines of an approved statement and of its
   comparison statement. It computes the metrics, with their edge cases at an end of the continuum, the factors, the
   financial and weighted aggregates and the adjustments in their order:
   1. notches;
   2. standalone caps, which give the standalone grade;
   3. group support, capped at the parent's grade;
   4. the override;
   5. absolute caps.

   It also writes the strengths, the points to watch, the weaknesses and the critical risks: those of the scorecard,
   of each item rule, of the covenants tested on the statement, and of the bank flows. Each finding has its text in
   both languages, written at the computation.
4. **Independent implementation.** `tools/dbgen/credit_reference.py` computes the same in Python. The tests expect its
   numbers (CA2 to CA6, CA9), so a fault in either shows.
5. **The company assesses itself.**
   - There is no final grade without the two qualitative grades (an indicative financial grade instead).
   - A qualitative grade more than three notches from the financial grade needs a supporting document.
   - The override is two notches down or one up, with a written justification.
   - The application role cannot write the results (DENY): only the procedure does, through the ownership chain.
6. **Life of an assessment.** It is a draft, computed while a draft, and submitted only computed on what it holds now
   (a SHA-256 of its statement, comparison, scorecard, date, rate and inputs). Someone other than its preparer
   approves it, with one approved assessment per statement. After the draft only its status and approval change
   (50063).
7. **Twelve optional lines** in the statement catalogue (51 lines):
   - contract assets and amounts due from related parties;
   - bank acceptances, amounts due to related parties, subordinated shareholder loans and end-of-service benefits;
   - the revaluation reserve;
   - five off-balance-sheet memo lines: LCs, performance and financial LGs, guarantees given, disputed zakat.

   EBITDA is operating profit plus depreciation and amortisation. A going-concern flag sits on the statement.
8. **Report.** Six views:
   - `fin.v_CreditAssessmentReport`, `Factors`, `Findings` and `Items` (the horizontal and vertical analysis of each
     line with its risk level);
   - `Covenants`;
   - `GroupUnits` (each unit of a consolidated statement with its own approved grade).
9. **Permissions:** `fin.credit.assess` to prepare and compute (TM, FO, FA) and `fin.credit.approve` to approve (TM).

## Consequences

- Ten tables: six global, four of the tenant. The database has 213 tables; 142 permissions.
- Tests CA1 to CA12 (CI step 19c). Disabling any of the ten new triggers makes a test fail.
- `tools/dbgen/credit_stress.py` runs the sixteen stress cases of the independent review in CI step 3. Each must stay
  within the grade range the reviewer expects, so a recalibration that breaks one shows.
- The independent review (docs/35 section 13) found the first calibration 3 to 8 notches wrong in ordinary cases, for
  example:
  - a debt-free loss-maker scored best on leverage;
  - a mid-size manufacturer reached Aa3;
  - equity tests ignored subordinated shareholder loans;
  - LGs never moved the grade;
  - gross murabaha rollovers made DSCR meaningless.

  These were fixed before the module was released.
- Left as documented limits (docs/35 section 16):
  - expert calibration with no default data;
  - annualised interim periods;
  - closing balances for turnover days;
  - no undrawn limits, payment delays or defaults;
  - a flat notch for a qualified opinion;
  - no guarantee substitution.
- The sovereign ceiling (Aa3, Moody's November 2024) is a parameter to check with each scorecard version.

Note (2026-10-19): the computation, the metrics, the report views and the limits of section 16 of docs/35 are superseded by ADR 0018 (docs/35 version 2.0). The scale, the life cycle, the guards and the inputs hash stay as decided here.

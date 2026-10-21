# ADR 0038: Corrections of the credit engine after the internal review v6

Status: decided by the database architect on the findings of an internal review written by AI agents (v6, findings
E3 to E22 and B2, B10 on the engine and its tests). The controls of the same review (046, 048, 049, 051, 052, 053) are
another ADR. Builds on ADR 0017 to ADR 0026 and ADR 0030.

## Context

The review read the engine (047), the statements module it reads (045), the Python reference, the generated cases and
docs/35, and found these, each checked against the code before it was fixed:
- the engine read a facility's lenders, limits and collateral links with `ToRevision >= ApprovedRevisionNo`. The
  contract of the revisions (model 13) is `FromRevision <= n < ToRevision`, as 045 reads it. So a row that an approved
  revision had superseded was read beside the row that replaced it: two collateral links, two root limits (E3);
- the assessment date was free, and what the engine read "on the assessment date" was today's state: the breaches open
  now, the facilities at their latest revision (E4);
- a share-of-revenue flow covenant compared a year's revenue with a window of a month, a quarter or a half (E5);
- the pace of a flow covenant counted the month of the date as elapsed, and the quarter and half windows were
  calendar ones whatever the company's fiscal year (E6);
- the restatement notch read only versions whose reason was RESTATED; a CORRECTION or a presentation version that
  changes the figures escaped it (E7);
- an interim statement was annualised by its period type, so a nine-month year-to-date statement filed as quarterly
  was multiplied by four; the unaudited notch hit annual statements only (E13);
- the whole allowance for expected credit losses was netted against the private receivables over a year, as if it all
  covered them; a negative allowance was read (E14);
- the bureau report's maximum age (`BUREAU_MAX_AGE_MONTHS`, 3) was in the seed and never read; the engine hard-coded
  the six months of the hidden-debt window, and docs/35 said six months for the age (E16, E22);
- an input's document was any id (the tests used 1), and the exchange rates the preparer enters were not shown as
  such (E19);
- a lower-assurance statement could be assessed when a higher one was approved for the period, and a comparison
  statement could be of another period type (E20);
- wording that claimed more than the system is (E21), and a few mismatches between docs/35 and the code (E22);
- the generated comparison of the engine with the reference let some differences through: a value against NULL, a
  quantity missing on one side, an adjustment with other notches (B2);
- four credit tests depended on the calendar (B10).

## Decision

1. **Revisions** (E3, E4). The engine reads the revision in effect on the assessment date: the latest APPROVED
   revision with `EffectiveOn <= AssessmentDate` (not above `ApprovedRevisionNo`), else the approved one. Lenders, root
   limits and collateral links are read with `FromRevision <= n AND (ToRevision IS NULL OR ToRevision > n)`, in the
   facility snapshot and in the collateral by kind. CA13 cases 4 and 5: a revision that replaces the property's link
   and the committed limit, in effect (read alone) and not yet in effect (revision 1 read).
2. **The assessment date** (E4). A non-trial assessment is dated on or after its period end and not after the day of
   the computation (50064). The breaches are those detected by the date and not resolved by it (`ResolvedOn` after the
   date counts as open; a waiver counts once recorded by the date); utilisations active on the date include those
   released after it. What stays as of the computation day: the facility header (amount, expiry, status) and the
   collateral's status and approval, which the revisions do not keep; a utilisation transferred to another facility is
   not moved back. A trial assessment may look ahead.
3. **Flow covenants** (E5, E6, 045). The required amount of a share of revenue is the share of the revenue of the
   window's months: annual revenue × months in the window ÷ 12. The quarter and the half are those of the company's
   fiscal year (from the month after `FiscalYearEndMonth`). `MonthsElapsed` counts the complete months to the end of
   the month before the date; `AchievedElapsed` (a new column of `fin.fn_BankFlowPerformance`) the confirmed flows of
   those months; ON_TRACK and the flow-shortfall notch compare the two on that basis, and the months still to route are
   the rest of the window, the month of the date included. FS7 now expects ON_TRACK (3 of 12 million in 3 of 12
   months), FS8 a quarterly covenant of 1,875,000 and the windows of two fiscal years.
4. **Restatement** (E7). The change of net profit or equity against the superseded version is computed for every
   version that supersedes another, whatever its reason. CA7 case 29.
5. **Interim statements** (E13). The context of the core gains `PeriodMonths` and `PriorPeriodMonths`: the months from
   the statement's start to its end date when it has a start date, else from its type. A period is of 1 to 12 months,
   up to 18 for an annual statement (50064). The rule `UNAUDITED_ANNUAL` keeps its code and applies to every
   management statement, annual or interim: an interim neither audited nor reviewed carries the same information risk.
   Requiring a start date for every interim would refuse statements already entered; it is left to the statement
   module.
6. **The allowance** (E14). The private receivables over a year carry their share of the allowance, allowance × their
   amount ÷ gross receivables; only the rest of them leaves tangible net worth and the realisable value. A negative
   allowance is refused (50064). The crisis loss of the scenarios (private receivables over 180 days net of the
   allowance) is unchanged and remains a known approximation.
7. **The bureau report** (E16, E22). The seed is the source of truth: a report older than `BUREAU_MAX_AGE_MONTHS`
   (3) on the assessment date, or dated after it, is not read (the context gains `BuAgeMonths`), and the report asks
   for a recent one. The hidden-debt window is a parameter, `HIDDEN_DEBT_WINDOW_MONTHS` (6). Three months is kept for
   the age: a credit report describes the company's position now, and the assessment is of a date, while the six
   months are the comparability of the report with the statement's period end; the two are different questions.
   docs/35 section 12 and the request text say so.
8. **Inputs** (E19). A document an input cites is an active document of the tenant owned by the assessed company, or
   linked to it, to its statement or to the assessment, of a type for companies or general (50064). Each exchange rate
   the preparer entered is a finding INFO `FX_RATE_ENTERED`; there is no reference rate on the platform to bound it.
9. **Assurance** (E20). A non-trial assessment of an approved statement is refused when an approved statement of the
   same company, basis, period type and period end has a higher assurance (50064). A comparison statement given is of
   the same period type and ends earlier.
10. **Wording** (E21). The disclaimer of the scorecards says that the calibration was written and reviewed by AI
   agents and not by a human analyst, and that the Fitch equivalent, the recovery rating, the LGD band and the
   liquidity label are an indicative internal mapping, not agency ratings; the report's columns are renamed
   `FitchEquivalentIndicative`, `FacilityFitchEquivalentIndicative` and `RecoveryRatingIndicative`. The provision matrix
   is "in the manner of" the simplified approach, not an IFRS 9 measurement (model 14). ADR 0017 no longer says how
   widely banks use the scale. The metric text "Moody's method" is replaced by a neutral one. The published methodology
   documents in the repository are read for study only; no text of them is copied.
11. **docs/35** (E22). The minimum coverage is the card's `min_coverage`, 60 percent (the seed and the JSON), not 70;
   POS_RESILIENT reads the seven scenarios the engine runs; section 4 and 9 state the new reading rules.
12. **The generated comparison** (B2). Every comparison of `gen_credit_cases.py` is null-safe (a value against NULL is
   a difference), every set is matched both ways (FULL JOIN), the adjustments are compared with their notches and cap,
   the summary rows are counted, and the evaluation's results join `#crS` with a presence check. The first run found
   two quantities the engine did not write (`CASH_REPORTED`, `CF`); it writes them now. No other difference was hidden.
   CI requires at least 148 generated cases.
13. **Reproducible tests** (B10). CA20 case 6, CA21 case 5, CA23 and CA24 date their statements from the day they run
   (ten months before, and two months after for the budget), so the statement's age, and the grade, do not move with
   the calendar. CA5 case 4 and CA6 case 7, which dated assessments in the future or before the period end, use older
   statements.

## Consequences

- The Python reference mirrors 1, 5, 6 and 7 (the parts the core computes): 74 generated cases, 148 PASS lines
  (CE and CV), up from 71 and 142, with V21 (a nine-month management interim), V22 (a bureau report five months old)
  and V23 (three months old). 51 of 51 stress cases stay within the reviewer's ranges.
- Expectations that changed: FS7 (BEHIND to ON_TRACK, 1,125,000 to 1,000,000 a month), the numbers of every case with
  an allowance and receivables over a year, and the findings of an assessment in another currency (FX_RATE_ENTERED).
- New checks: CA7 cases 23 to 29, CA13 cases 4 and 5, FS8. The test counts of CI are unchanged (11 FS, 31 CA).
- No table, column or check is added; one view column set is renamed; `fin.fn_BankFlowPerformance` gains a column;
  one card parameter is added to each scorecard (`HIDDEN_DEBT_WINDOW_MONTHS`). A database already deployed gets the
  procedures from the repeatable scripts; a scorecard approved before the parameter existed keeps the six months (the engine's fallback) until its next version.
- Approximate still: the facility header, the collateral's state and transferred utilisations as of the computation
  day; the crisis loss of receivables; no reference exchange rate; interims without a start date annualised by type.

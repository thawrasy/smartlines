# ADR 0044: Slice S2-b of the application, its defaults and the deviations it took

Status: built on 2026-10-23 at the owner's request "I approve the defaults; start" (docs/31, row 41). The owner
approved all the defaults below (OQ-1 to OQ-17 of the S2-b brief) in that request. Written by an AI agent.

## Context

S2-b covers two modules:

- **Financial statements and verification:** the line catalogue, the statements with their versions and
  consolidation units, monthly balances and bank flows, the period close, the formula library and its parser, the
  covenant tests and the engine that evaluates them, and the breaches the tests find.
- **The company's credit self-assessment, seen from its side before its lenders:** the assessment and its
  presentation versions, the readiness file, lender ratings and calibration, endorsement, the evidence pack, and the
  provision matrix.

The brief found 26 gaps (S2B-GAP-1 to 26) and seventeen open questions. Half of the logic was already in the database
(046 to 053, 058), and the application wraps it. The other half did not exist anywhere and the application builds
it: the test generator, the formula parser and the verification engine.

The exit is AC-FAC-7 and AC-FAC-13:

- **AC-FAC-7** has one test per Given of spec 12:762.
- **AC-FAC-13** is the compliance dashboard of agreement C on a fixed date, with DS-AGR C and a new synthetic pack
  DS-FIN-C.

## Decision

### 1. Batches

| Batch | Content | Commit |
|---|---|---|
| S2B-A | Packs FIN.LINES v1 (157 lines), FLOW_KIND, NTF.BASE v5, FIN.FORMULAS v2, FIN.PROVISION; settings; 063; error map; outbox names; notification severity; the COVENANTS gate; the tenant-local date | 31a719e |
| S2B-B, C | Statements, lines, totals, versions, units, revenue estimates, the catalogue; monthly balances, bank flows, the period close | 95d417e |
| S2B-D | The formula parser (BankFas.Core), the library, analysis measures, the covenant columns | ee3446b |
| S2B-E | The test calendar, the engine, breaches, JOB-FIN-EVAL, R-FIN-05 | 5ce6dc7 |
| S2B-F | The credit assessment and presentation versions over 046 to 048 | 5a516b4 |
| S2B-G | Readiness, lender ratings, calibration, endorsement, the evidence pack, loss rates, JOB-FIN-READINESS | dbe5004 |
| S2B-H | The compliance dashboard (BR-OBL-010), R-OBL-05, AC-FAC-7, DS-FIN-C, AC-FAC-13, these documents | 006cf0e, 21cce4d and the documents commit |

### 2. Database changes

- **`db/static/063_s2b_guards.sql`** freezes two things:
  - An approved formula: it changes only to SUPERSEDED, and a superseded one is final (50176).
  - The structural columns of a system statement line. Code, Section, IsTotal, TotalFormula, IsSystem, IsLocked and
    SeedKey are denied to tp_app, and a system or locked line comes only from the seeder (50174).
- **044 accepts a share-of-revenue test whose rule is MANUAL_ESTIMATE with no statement.** Its snapshot must name an
  approved or superseded revenue estimate of the tested company.
- **db_ci counts 16 settings.**
- **tp_app may delete five more kinds of row** (db/generated/tsql/005_delete_grants.sql, from the model's `deletable`):
  - `fin.StatementLine` and `fin.ConsolidationMember`: only while the statement is a draft (045:71-97);
  - `fin.CreditAssessmentGuarantor` and `fin.CreditAssessmentBureau`: only while the assessment is a draft (046:277-300,
    50063);
  - `fin.CompanyProductLine`: refused once an approved assessment read the year's lines (058, APPROVED_FINAL).
  Each widens what tp_app may do and was missing from this record (review 9.0, docs/47 §5 item 4).

### 3. The engine's snapshot contract

- **What a test stores.**
  - It stores the formula's id and version, never its expression. An approved formula is frozen (063).
  - It stores every input it read:
    - the statement lines by code, and the statements by id, version, basis and assurance;
    - the confirmed monthly balances by account and month;
    - the confirmed flows by entry;
    - the revenue and its source: the same period, the year before, or the estimate.
  - It stores the actual value, judged at full precision and stored with six decimals. The headroom and its
    percentage are stored the same way.
- **Results that are not a judgement.**
  - PENDING_DATA: the data is missing before the due date.
  - MISSING_DATA: the data is still missing after it. The reason is kept.
  - NOT_COMPARABLE: an input is in another currency.
  - NOT_ASSESSED_NO_THRESHOLD: the covenant has no threshold.
- **A re-evaluation is a new row** (EvaluationNo + 1). It never closes a breach. It opens no second breach for the
  same root and period, and sets NeedsReview on the existing one instead.

### 4. Job order

The daily order is the one of OQ-5:

1. JOB-FAC-VALIDITY;
2. JOB-OBL-CALENDAR;
3. JOB-FIN-EVAL;
4. JOB-FIN-READINESS;
5. JOB-NTF-EXPIRY;
6. then the signatory and governance jobs.

Each finance job uses the tenant's local date. JOB-FIN-EVAL also does two other things, which are recorded as
deviations:

- it extends the test calendar to the rolling horizon before it evaluates;
- it sends FIN.BALANCES_MISSING (NTF-FIN-01).

The `statement.approved` consumer re-evaluates, after the approval's transaction (OQ-13), the tests that read
another version or missed the statement.

### 5. The compliance colour (BR-OBL-010 in full)

The colour is computed on a date: `asOf`, today by default.

| Colour | When |
|---|---|
| RED | an OPEN or IN_CURE breach, an overdue item, a descriptive covenant reviewed as not compliant, or a measured covenant whose latest result is a BREACH not waived |
| AMBER | otherwise, a WARNING or MISSING_DATA as the latest result, an item due within 30 days, a facility whose validity is NOT_CONFIRMED, or a review overdue |
| GREY | no obligation in force |
| GREEN | otherwise |

- NOT_ASSESSED and NOT_COMPARABLE are counters only.
- The response lists the reasons with their counts, the families, and the measures. Each measure shows its latest
  result, its headroom, the evaluations of its period, the statements it read and its breach.
- R-OBL-05 builds each row with the same function, so it equals R-OBL-04.

### 6. The defaults taken (OQ-1 to OQ-17)

As listed in docs/46 §4. All were approved by the owner on 2026-10-23.

### 7. Deviations from the brief and the specifications

1. **The covenant early warning is its own event, CMP.WARNING** (NTF.BASE v5). It is not CMP.BREACH with severity
   WARNING. It stays in-app and not mandatory.
2. **The nightly extension of the test calendar runs in JOB-FIN-EVAL**, not in JOB-OBL-CALENDAR.
3. **NTF-FIN-01 runs inside JOB-FIN-EVAL.**
4. **044 is relaxed for MANUAL_ESTIMATE**, as in section 2.
5. **The BR-FIN-017 example matches the database's pace rule** (E6) on a mid-May date, not on 15 April.
6. **The F-batch test changes what the computation read by changing a justification**, not a statement.
7. **50095 maps to 409 EVIDENCE_PACK_REFUSED**, not 404.
8. **Some endpoints are deferred:** the guarantors, the bureau report, the product lines of an assessment, and the
   lender decisions on the facility (FR-FIN-034). The engine reads those tables when they hold rows.
9. **CA23 through the worker covers LEAD, then D90, and no repeat.** The AMBER-to-RED rise within a stage stays
   covered by the database's CA23 case 4 only. A facility in the lead time makes the liquidity SGL-4, so the renewal
   starts RED.
10. **No browser test for S2-b.** The API exit tests cover the exit, and the screens are checked by the type check and
    the build.
11. **AC-FAC-13 moves the application's test clock to 2028-02-16 while it enters the monthly figures of 2027**
    (V-FIN-02 accepts a month only once it has ended), then restores it.
12. **Only a waiver clears the RED of a latest BREACH**, as BR-OBL-010 is written. A CURED breach whose latest test is
    still a BREACH keeps the facility RED until a later test.

## Consequences

- The S2-b exit is the API tests AcFac7Tests and S2bExitTests, with the batch tests:
  FinanceFoundationTests, StatementTests, MonthlyFigureTests, FormulaTests, CovenantEngineTests, CreditTests and
  ReadinessTests.
- DS-FIN-C, like DS-AGR, needs its preparer, reviewer and approver to sign before UAT.
- S3 takes the compliance warning on requests (FR-OBL-015) from the same compliance function.

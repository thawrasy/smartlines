# ADR 0024: The readiness file before the lenders, its timeline and the early warning

Status: decided by the database architect on the owner's decision of 2026-10-20 (docs/31-owner-decisions.md decision 34,
docs/36-internal-perspective-study.md gaps F3 and F4, phase D): an early warning six months ahead, which each company
may change. Builds on ADR 0021 (what a lender notified), ADR 0022 (the trial assessment) and ADR 0023 (presentation
versions).

## Context

An assessment listed the company's weaknesses, the data missing and the remedies, but tied none of them to a date. A
company prepares for its lenders' dates: the renewal of a facility, a covenant test, the submission of its audited
statements; it acts before them, and some actions only count when they happen before the period end.

## Decision

1. **The lead time** is the tenant setting `fin.readiness.lead_months` (default 6, from 1 to 24).
2. **The lender's dates** (`fin.v_CreditReadinessEvents`, 049): within the lead time after the assessment date, each
   facility read with the assessment that expires (its renewal, with what its lender notified), each scheduled covenant
   test of the company with the last result and headroom of its covenant, and each scheduled report to a lender on a
   facility of the company.
3. **The readiness of a date** (BR-FIN-038), by fixed rules of this system:
   - RED: the assessment is not rated, its liquidity is SGL-4 or its grade B3 or worse; a covenant whose last test was a
     breach or whose headroom is below zero; a facility whose lender notified a stop, a reduction or no renewal;
   - AMBER: liquidity SGL-3, a negative outlook, an open critical risk or a missing disclosure; a covenant whose last
     headroom is below its early warning (10% when not set);
   - GREEN otherwise.
4. **What the lender will ask** (`fin.v_CreditReadinessRequests`): each disclosure the assessment found missing or
   inconsistent, the bureau report when none was read, and the document of each remedy proposed.
5. **The timeline** (`fin.v_CreditReadinessActions`): the remedies by the notches they gain, before the company's next
   fiscal year end (a remedy is booked in the period only on a document dated by its end, ADR 0023); then the requests,
   30 days before the first lender date (or the end of the lead time).
6. **The early warning** (`fin.v_CreditEarlyWarnings`): today, for the latest computed assessment of each company, every
   lender date within the lead time that is not GREEN, with the date from which it warns. The notification job of the
   application reads it; the view does not send anything.

## Consequences

- No new table: one setting, a new static script (049) with two functions and four views.
- Test CA20: a renewal in the window with its days left and readiness; a lender's notice of no renewal turns it RED; a
  covenant test after a breach is RED; a shorter lead time leaves the renewal out; the timeline's deadlines; today's
  early warning.
- The rules are a first calibration of the system, not a lender's; the treasury validates them with the rest.

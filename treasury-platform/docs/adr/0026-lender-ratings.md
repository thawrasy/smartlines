# ADR 0026: The ratings a lender communicates, compared with the company's assessment

Status: decided by the database architect on the owner's decision of 2026-10-20 (docs/31-owner-decisions.md decision 34,
docs/36-internal-perspective-study.md gap F6, phase F). Builds on ADR 0021 (what a lender notified) and ADR 0024 (the
readiness file).

## Context

The company's assessment is its own mirror of how a lender reads it. When a lender tells the company the rating it
gave, on its own scale, the company wants to see how far its mirror is from the lender, and where they part, so it
corrects its picture before the next renewal.

## Decision

1. **`fin.LenderRating`** (tenant, source-stamped): the company, the lender, the date, the lender's own grade label, its
   equivalent on the 21-grade scale and whether the lender gave that equivalent or the treasury mapped it (a mapping
   keeps the lender's label, BR-FIN-040), and the reasons the lender gave.
2. **The comparison** (`fin.v_LenderRatingComparison`, 049): each rating beside the company's latest computed assessment
   of an actual statement on or before the rating date (else the nearest after it, the approved one first), with the
   gap in notches and its direction (the lender more severe, more favourable, or the same).
3. **Where they part** (`fin.v_LenderRatingGapDrivers`): when the lender is more favourable, the metrics the assessment
   grades worse than the lender's grade; when more severe, the metrics it grades better; each with its weight and its
   distance from the lender's grade; then every adjustment and ceiling the assessment applied, which a lender may weigh
   otherwise. This is a reading of the assessment against one grade, not the lender's model.
4. **The readiness of a renewal** (ADR 0024) reads the lender's latest rating on or before the date: RED when it is B3
   or worse, AMBER when it is two notches or more below the assessment's grade.

## Consequences

- 248 tables; the readiness events carry the lender's grade.
- Test CA22: a more favourable and a more severe rating with their gaps and drivers; a mapping without the lender's
  label refused; the lender's rating on its renewal; the same grade lists no driver.
- The redacted source text of the new table makes 16 such columns (DR-31 check and RF18).

# ADR 0022: The trial assessment of a statement before its final approval

Status: decided by the database architect on the owner's decision of 2026-10-20 (docs/31-owner-decisions.md decision 34,
docs/36-internal-perspective-study.md gap F1). Extends ADR 0017 to ADR 0021.

## Context

The owner corrected the framing of the credit assessment: the platform serves companies, not banks. A company studies
itself in it to know its position before the bank does, and to restructure and reclassify its statements before
their final approval, audited or internal. The assessment read only an approved statement (50064), so a company
could not study a draft.

## Decision

1. **`fin.CreditAssessment.IsTrial`.** A trial assessment reads a statement that is a draft, submitted or approved;
   an official one reads the approved statement only (BR-FIN-036, error 50064 otherwise).
2. **It stays a draft.** It is computed and computed again as the draft changes; it is never submitted or approved
   (50063), so it is never the source of group support, which needs an approved assessment.
3. **Its hash also holds the statement's lines and status**, since they may still change: a line changed after the
   computation makes the trial no longer current (`IsCurrent` in the report), and computing it again brings it back.
4. **Its summary says that it is a trial** on a statement not yet finally approved, in both languages; the report
   view shows `IsTrial` with the statement's status.
5. The engine is unchanged: a trial computes exactly what an official assessment computes on the same lines.

## Consequences

- One column on `fin.CreditAssessment`; the guards (046), the computation and the report (047) read it.
- Test CA18: an official assessment of a draft refused; a trial computed on the draft and noted as such; a changed
  line makes it not current and a new computation current again; a trial not submitted; a trial and an official
  assessment of the same approved statement give the same grade.
- The next phases of docs/36 (alternative presentations turned into a new draft, the readiness file, the early
  warning, the budget statements) build on the trial assessment.

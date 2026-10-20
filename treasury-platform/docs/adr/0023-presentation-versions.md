# ADR 0023: Presentation versions of a statement before its final approval

Status: decided by the database architect on the owner's decision of 2026-10-20 (docs/31-owner-decisions.md decision 34,
docs/36-internal-perspective-study.md gap F2, phase C). Builds on ADR 0018 (remedies and strengthening plans) and
ADR 0022 (the trial assessment).

## Context

A company studies its statement before it is approved, and prepares it in another form: it moves an amount due to its
partners into a subordinated loan when they sign a subordination agreement, retains its dividends, capitalises a loan.
The engine already computes the pro-forma statement of each remedy and of each step of the strengthening plans, but it
kept only the grade after them, not the statement, and nothing turned a chosen form into a statement.

## Decision

1. **`fin.PresentationVersion` and `fin.PresentationVersionStep`.** A version starts from a live statement of the
   company (a draft, a submitted or an approved one) and, optionally, an assessment of it to compare with. Its steps
   are remedies of the methodology, in order, each with a share (`ScalePct`), its document and the document's date,
   and a written justification.
2. **The build** (`fin.usp_BuildPresentationVersion`, 048) applies the steps with the engine's own remedy steps
   (`fin.usp_CreditApplyRemedy`, which now takes the share), checks that the balance sheet stays balanced, and writes
   the result as a new draft statement of the same series with the reason `RESTRUCTURED` (a new value of
   `VersionReason`). With a source assessment it also writes a trial assessment of the new draft with the same inputs,
   guarantors and bureau report, adds the evidence a step's remedy sets (a subordination, a capital resolution, a
   waiver) with the step's document, and computes it.
3. **The substance rule.** A version is convertible only when every step rests on a document dated by the period end:
   what is agreed or done later is a later event and is not booked in the period. A version that is not convertible
   stays a plan to compare: it is built and assessed, but never chosen. A real action and a presentation that follows
   the substance both need their document; nothing in the version changes what a lender's analytical reading would
   restate, since the engine reads the new draft as it reads any statement.
4. **The choice** (`fin.usp_ChoosePresentationVersion`): a built, convertible version is chosen by someone other than
   its preparer (owner's decision 34: one of the finance team other than the preparer); its draft then supersedes the
   source in the series, and the other built versions of the source are discarded.
5. **Guards** (048, error 50090): a version is written as a draft, built by the database, then chosen or discarded; its
   steps change only as a draft; the draft of a version is not submitted unless its version was chosen; the lines of a
   version's draft are written by the build only; the build's results are denied to the application role.
6. **The comparison** (`fin.v_PresentationComparison`): each version beside its source, with the grade, score and
   liquidity of each, the notches gained, the balance and whether it can become the statement;
   `fin.v_PresentationVersionSteps` and `fin.v_PresentationVersionLines` give its steps and its lines beside the source.

## Consequences

- 247 tables; one value of `fin.FinancialStatement.VersionReason`; a new static script, 048.
- Test CA19: a version built balanced with its moves and its trial assessment; a later document makes it a plan only; the
  preparer cannot choose; another user chooses, the draft supersedes the source and the other version is discarded; a
  draft of a version not chosen is not submitted; its lines and the steps of a built version are fixed.
- The draft of the chosen version then follows the statement's own life: submitted, and approved by someone other than
  its preparer (FR-FIN-006); an audited statement still needs its auditor and opinion.

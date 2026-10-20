# ADR 0021: The lender's actual decision on a facility replaces the estimate of its stance

Status: decided by the database architect on the owner's request of 2026-10-19 (docs/31-owner-decisions.md decision 33).
Extends ADR 0020.

## Context

ADR 0020 estimates the lender's stance in every scenario from the sector's risk: short-term lines cut at renewal,
undrawn limits stopped, margin and fees raised. The owner stressed that every facility stays subject to its lender's
own criteria, and asked that a lender's actual decision be entered for each facility.

## Decision

1. **`fac.FacilityLenderDecision`** (tenant, source-stamped like the other facility facts): the facility, the lender
   (optional), the decision date and its effective date, the limit action (`MAINTAINED`, `UNDRAWN_STOPPED`,
   `LIMIT_REDUCED` with the new limit in the facility currency, `NOT_RENEWED`), and the change of margin and of fees
   in basis points (BR-FIN-035). One decision per facility and effective date; the latest effective on a date is the
   lender's stance on that date. A decision without a document is stamped `ENTERED_NO_DOCUMENT` with a reason.
2. **The assessment reads it with the facility** on the assessment date (047):
   - the decided limit replaces the facility's limit: kept, the drawn amount when the undrawn limit is stopped, the
     new limit, or zero when not renewed; the committed undrawn amount in liquidity is counted on it;
   - what is drawn above the decided limit is due, and joins the liquidity uses (base and scenarios);
   - the change of margin and fees on the drawn amount is added to the finance cost in the scenarios (the base
     statement is the year reported);
   - the estimate of ADR 0020 covers only the facilities whose lender has not decided: the cut at renewal and the
     estimated margin and fees are multiplied by their share of the drawn amount on the platform (of the limits when
     nothing is drawn), and the share of undrawn limits kept in a scenario applies to their undrawn amount only.
3. The facility snapshot of the assessment keeps the decision, the decided limit and the change of margin and fees.

## Consequences

- 245 tables; four columns on `fin.CreditAssessmentFacility`; four quantities of the platform in the engine's context
  (`PfUndrawnDecided`, `PfLenderRepayment`, `PfDecidedShare`, `PfDecidedCost`) that the reference computes the same way.
- Tests: CA17 through the tables (no decision, a stopped undrawn limit, a reduced limit with a repayment, a repricing,
  a decision effective after the assessment date) and the engine case V20; 142 engine cases.
- The decisions are not in the hash of the assessment's inputs, like the facilities themselves: a decision recorded
  after a computation is read at the next computation.

Note (2026-10-20): from the company's side (docs/31 decision 34, docs/36), the decision is what a lender has notified
the company, recorded by its treasury with the document; the computation is unchanged.

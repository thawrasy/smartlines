# ADR 0020: A seventh macro scenario for the current event: the Gulf conflict on the shipping routes

Status: decided by the database architect on the owner's answers of 2026-10-19 (docs/31-owner-decisions.md decision 31).
The owner approved the proposed values EV-01 to EV-05 and answered EV-06 in their own words. The calibration (the
intensities and the country multipliers) is this system's own and was not reviewed by an independent agent; the
company's treasury department validates it with the rest of the methodology. Extends ADR 0019.

## Context

The owner asked for a scenario of a current event (docs/35 section 24). Its details, as answered on the questions page:
- EV-01: a prolonged regional conflict in the Gulf reaching the shipping routes of the Strait of Hormuz and the Red Sea
  for a full year;
- EV-02: the six Gulf states, Jordan and Egypt are hit most, Bahrain, Kuwait and the UAE hardest;
- EV-03: the stress is the disruption, not the oil price level;
- EV-04: 12 months;
- EV-05: tourism, aviation, hotels, shipping, import-dependent trade and imported building materials are hit hardest;
- EV-06 (the owner's own answer): "the credit limit that has not been released stops".

The six scenarios of ADR 0019 apply the same stress to every country through the country exposures, and none of them
models a bank that keeps drawn lines but freezes the undrawn limits.

## Decision

1. **A country multiplier per scenario.** `fin.MacroScenarioCountry` holds the multiplier of a scenario's stress for a
   country; a country without a row takes the scenario's `OtherCountryMult`. The multiplier scales every driver of the
   stress, after the activity sensitivity, the country exposure and the region multiplier. The six scenarios of ADR
   0019 have no rows and a multiplier of 1, so their results do not change.
2. **Undrawn limits.** `fin.MacroScenario.UndrawnAvailablePct` is the share of the committed undrawn limits on the
   platform that stays available in the scenario; the liquidity sources and the quantity `UNDRAWN_COMMITTED` read that
   share. It is 100 in the six scenarios.
3. **`GULF_SHIPPING_CONFLICT`**: conflict and imports at full intensity, demand and real estate 0.4, government
   spending 0.2, credit 0.3, oil 0; inventory at its stagnant-market value; rates +150 basis points; private receivables
   loss 8%; no drawn line withdrawn (0%) and no undrawn limit available (0%); 12 months (`DurationMonths`, shown only:
   the stress applies to the statement's year as in the other scenarios). Country multipliers: Bahrain, Kuwait and the
   UAE 1.3; Saudi Arabia, Qatar and Oman 1.0; Jordan and Egypt 0.9; any other country 0.5.
4. **EV-06 is read as a freeze, not a withdrawal**: the banks stop the undrawn limits and keep the drawn ones. If the
   owner also meant a withdrawal of part of the drawn lines, only `StLinesWithdrawnPct` of the scenario changes.
5. **The sectors of EV-05 come from the sensitivities**: the activities most sensitive to conflict and imports lose
   most; no separate sector list is kept, so a new activity is stressed by its own sensitivities.
6. **The lender's stance in every scenario** (the owner's answer of 2026-10-19, docs/31 decision 32): a bank that sees
   a sector's risk rise does not withdraw drawn facilities; it may stop the limits it approved but has not released,
   cut them, or raise its margin and administrative fees, each at its own discretion. The system estimates that stance
   from the sector's risk with a lender factor = the activity's credit sensitivity ÷ 3 × the country's credit exposure
   × the scenario's country multiplier:
   - short-term uncommitted lines are cut at renewal by `StLinesWithdrawnPct` × the factor (at most 80%), as before;
   - the committed undrawn limits that stay available are `UndrawnAvailablePct` − `UndrawnCutPct` × the factor (not
     below zero);
   - the margin and fees, (`LenderMarginBp` + `LenderFeesBp`) × the factor, are added to the cost of the short-term
     facilities and acceptances repriced at renewal; a term loan keeps its contract price (floating debt still follows
     `RateBp`). A first version applied them to all bank debt and took a property investor with long-term debt below
     the reviewer's range in the real estate correction; repricing a term loan before maturity is not the practice,
     so the base was corrected, not the range.

   | Scenario | Undrawn stop % | Margin bp | Fees bp |
   |---|---|---|---|
   | Stagnant market | 10 | 25 | 5 |
   | Financial crisis | 50 | 150 | 25 |
   | Fiscal squeeze | 15 | 50 | 10 |
   | Real estate correction | 20 | 75 | 10 |
   | Regional conflict | 25 | 100 | 15 |
   | Oil price collapse | 20 | 75 | 10 |
   | Gulf conflict | (none available) | 100 | 15 |

   The system cannot know each lender's actual decision; it is an estimate for the assessment, and every facility
   remains subject to its lender's own criteria.
7. The scenario is not the resilience base; resilience and the outlook still read the stagnant market. The rule
   `POS_RESILIENT` reads all seven scenarios.

## Consequences

- 244 tables: `fin.MacroScenarioCountry` is new; six columns on `fin.MacroScenario` (`UndrawnAvailablePct`,
  `UndrawnCutPct`, `LenderMarginBp`, `LenderFeesBp`, `DurationMonths`, `OtherCountryMult`) and three on
  `fin.CreditAssessmentScenario` (`UndrawnAvailablePct`, `LenderCostBp`, `CountryMult`), shown by
  `fin.v_CreditAssessmentScenarios`.
- The engine (047) and the reference (`tools/dbgen/credit_reference.py`) apply the multiplier and the share of undrawn
  limits; the generated cases compare both, and a new variant (V19, a staple food importer in Kuwait with committed
  undrawn limits) reaches the freeze: in the Gulf scenario it falls to Caa1 (its lender factor gives 224 basis points of
  margin and fees), against B3 had its limits stayed open and its lines not been repriced.
- With the lender's stance, the 51 review cases stay within the reviewer's ranges; five scenario cells moved by one
  notch.
- Tests: CA12 counts the scenario and its eight country rows, CA14 reads seven scenarios; 140 engine cases (step 19d).
- The 51 review cases have no reviewer range in the new scenario; docs/35 section 22 shows their grade in it as
  "without a range".

Note (2026-10-20): the platform serves companies, not banks (docs/31 decision 34, docs/36). The lender's stance is
read as what the company expects of its lenders in a crisis, to build its liquidity buffer before it happens; the
computation is unchanged.

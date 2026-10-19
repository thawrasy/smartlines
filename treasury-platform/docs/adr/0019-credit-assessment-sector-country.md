# ADR 0019: The credit assessment, version 2.1: sector families, detailed activities, country risk and macro scenarios

Status: decided by the database architect on the owner's answers of 2026-10-19. The content (activities, countries,
families, sector qualitative factors, stress cases) was drafted and reviewed by separate AI agents in the role of
senior analysts, not by a human. The company's treasury department, as its risk function, validates the calibration
before a grade is used in a credit decision. Extends ADR 0018; the life cycle, the guards, the remedies and the
strengthening plans stay.

## Context

The owner found the industry treatment of version 2.0 far too shallow: one activity per division, three scorecards,
two scenarios per activity, and one sovereign ceiling. They asked for the standard practice of the rating agencies:
- finished building materials (ceramics, marble, sanitary ware) differ from steel, cement and blocks, and those from
  pharmaceuticals, food, retail, general trade, car trading, aviation, tourism, hospitality and restaurants; each
  activity has its own risks and weight, especially in crises;
- real estate falls or rises differently from one city to another, under wars and crises;
- contracting depends on real estate development and government spending, and is hit by contractions, spending cuts
  and budget deficits;
- the weights must follow the Arab region and each country, as a country may be hit in one sector and not another;
- revenues range from 10 million to 10 billion; Moody's 21-grade scale stays; the calibration stays the system's
  own; the treasury department validates it.

## Decision

1. **Sixteen sector family scorecards.** Each family has its own metrics, weights and grids over the same eight
   factors, and its own business profile sub-factors. A card with a `base` inherits the item rules, parameters,
   haircuts, fixed cost rule and financial policy sub-factors of one of the three base cards
   (`tools/dbgen/credit_methodology.py` expands them for every tool; the seed writes each card in full).
2. **Detailed activities.** `ref.Industry` holds sections, divisions and activities (a division code and two digits).
   Each activity has its family card, industry risk 1 to 6, cyclicality, ceiling, products, disclosures and a
   sensitivity 0 to 5 to each of seven drivers (`fin.IndustrySensitivity`). A division without its own sensitivities
   takes the median of its activities.
3. **Country risk.** `fin.CountryRiskProfile` holds, for the 22 Arab League states and a default row, the country
   risk 1 to 6, the published sovereign rating and its month (verified and kept current by the platform operator),
   the ceiling of a company's grade (the sovereign rating, or the ceiling of the country risk when unrated) and the
   exposure to each driver. `fin.CountryRegion` holds the cities and regions with their real estate and conflict
   multipliers. The assessment records the market country and region (`MarketCountryId`, `MarketRegionCode`; the
   company's country when empty) and writes the country risk, industry risk, anchor and country ceiling it read.
4. **The anchor.** `fin.RiskAnchor` maps country risk and industry risk to a notch: the computed SECTOR_RISK
   sub-factor and the centre of the expected range (anchor − 3 to anchor + 4), replacing the fixed expected grades of
   each activity.
5. **Macro scenarios.** Six scenarios (`fin.MacroScenario`) set an intensity 0 to 1 for each of seven drivers
   (`fin.ShockDriver`, `fin.MacroScenarioIntensity`). The stress on a company is intensity × activity sensitivity ÷ 5
   × country exposure × region multiplier per driver, summed into the revenue fall, the margin fall and the collection
   days; the product mix replaces the activity's demand sensitivity. `fin.IndustryScenario` is dropped. Each scenario
   result keeps the stress it applied. Resilience and the outlook read the stagnant market as before.
6. **Size.** The REVENUE_SIZE grid of each family spans 10 million to 10 billion; the size ceilings are B1 below 50
   million, Ba2 below 250 million, Baa3 below one billion and A3 below five billion.
7. **The self-assessment bound is one way.** A qualitative grade better than the financial grade by more than three
   notches needs a document; a worse one does not, as it is conservative.
8. **No agency content.** Only the public structure of standard practice is used; every number is this system's
   calibration. The owner's documents of ADR 0018 were not used either.

## Consequences

- 243 tables: seven new global tables (drivers, macro scenarios and their intensities, industry sensitivities, country
  profiles, regions, the anchor), `fin.IndustryScenario` dropped; new columns on the assessment, its scenario rows,
  the activity profile and the product category.
- The engine (047) reads the country and region in its context, computes the scenario stress, applies the country
  ceiling and the micro size ceiling, and loops over the macro scenarios; the reference does the same, and the
  generated cases compare them, including six variants on countries, regions and size.
- An independent AI reviewer found content and engine problems that were fixed before release: two inventory metrics
  that were constants per product category, a generous trading scale grid, a sovereign rating in default (C) outside
  the scale of a company's grade (now Ca), a maturity share computed from the first bucket alone, line withdrawals
  blind to the activity's credit sensitivity, fixed-point margin shocks that crushed thin margins, investment property
  never revalued in a real estate correction, and size ceilings blind to the card. The reviewer wrote 16 new cases
  with ranges set before running the model; all 51 cases fall within range, 24 cells accepted outside by the reviewer
  with a written reason, none widened (docs/35 section 22).
- A qualitative grade better than the financial grade by more than three notches needs a document (BR-FIN-034).
- Tests: CA1 to CA16 (step 19c) and 138 engine cases (step 19d).
- Known limits: docs/35 section 25.

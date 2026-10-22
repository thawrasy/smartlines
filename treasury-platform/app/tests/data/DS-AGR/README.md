# DS-AGR: the four agreements, synthetic (DOC-B06 section 6)

Each pack keeps the structure of one of the four agreements of docs/04 (A to D) and replaces everything that could
identify it (DOC-B06 section 6.3): bank and company names are synthetic, amounts are scaled by one factor per pack
that is not recorded here, dates are shifted by whole years, and the text of clauses is generated. The tree of
limits and lines, the distribution modes, the pricing methods, the reporting lags and anchors, the covenant
thresholds (and the empty ones, still empty), the scan marks and the page references are kept.

A pack is `vN/manifest.json` (preparer, reviewer, approver, fingerprints), `vN/agreement.json` (the facility as the
API takes it) and `vN/summary.csv` (what the loaded facility must show, row for row). The packs were written by an AI
agent from the structure in docs/04 and are proposed defaults (🟡): the preparer, reviewer and approver roles of
DOC-B06 section 6.2 are to be signed before UAT. The integration test AgreementPackTests (AC-FAC-11) loads each pack
through the API, submits it with no error, has another user approve it, and checks every summary row.

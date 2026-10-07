# Database design and ERD

Source: Analysis and Design Study v3.0 (English) and the Use Case and Data Flow Diagrams v1.0, applied to the
schema in `db/schema` (files 000 to 1049).

- `Masslak_Database_Design_and_ERD_v3.9.docx`: changes in 3.9 (the re-audit of 3.8: monitoring, sensitive report links, device-bound positions, approved resends and payment reconciliation, the outbound connection controls, and the evidence of recovery, migration and load runs; see DESIGN_AUDIT_T3_RECHECK.md), in 3.8 (the technical audit of design 3.7: references checked when written, break-glass expiry, daily position partitions and evidence, two-person requirement changes, file quarantine, numbers taken from the verification run; see DESIGN_AUDIT_T3.md), in 3.7 (route compliance with requirements switched by configuration, school transport as its own phase, PostGIS, see ROUTE_COMPLIANCE_AND_SCHOOL.md; and every item of the third-party technical audit, see THIRD_PARTY_AUDIT.md), in 3.6 (contact center and AI assistant in a later phase; the shuttle opened city by city), in 3.5 (the model divided by project phase; every module and table names its phase), in 3.4 (integrity audit of every relationship: composite keys for the sale chain, guards for manifests, cargo legs, wallets and leased vehicles, see INTEGRITY_AUDIT.md), in 3.3 (hardening after the database architecture review: RLS and a data class on every table, typed references, tenant checks, ledger, seat and business rules, retention, scopes and keys, see REVIEW_RESPONSE.md), in 3.2 (passenger categories and family accounts, carrier-issued manifests and their routing, company data isolation), in 3.1 (reports, payment integration, integration API) and in 3.0, architecture, relationship rules R1 to R4, security model, data stores D1 to D17,
  39 module ERDs and 3 focus diagrams with their relationship tables (cardinality, delete rule, index), every
  table definition, traceability to the study, verification, and the references without a foreign key (appendix C).
- `erd/svg`, `erd/png`: the diagrams, in the study's colours (overview `E00_overview`, modules `E01` to `E39`, focus
  diagrams `F01` travel documents, `F02` booking spine and `F03` wallet top-up and partner integration, `legend`).
- `generator/`: `diagrams.py` (diagram groups, every table in exactly one, which `render.py` checks; focus diagrams), `render.py` (reads the built
  database, draws with graphviz), `trace.py` (maps every study entity to its tables), `verification.py` (the test counts,
  commit, migration and schema hash of the run, so the document never carries numbers typed by hand), `build.js` (the document).

Regenerate after a schema change (needs graphviz, Pillow and the `docx` npm package):

```sh
createdb masslak_doc && ./db/build.sh masslak_doc
cd docs/database/generator
python3 render.py masslak_doc
python3 trace.py ../../Masslak_Analysis_and_Design_EN_v3.0.docx
# the console output of the same build's test runs (db/tests/run.sh and pytest -q)
python3 verification.py masslak_doc --db-log db-tests.log --api-log api-tests.log
node build.js
```

Responses to reviews: `REVIEW_RESPONSE.md` (database architecture review v1.0, file 1039), `INTEGRITY_AUDIT.md`
(strategic review and its audit register of the 1,304 relationships, file 1040), `THIRD_PARTY_AUDIT.md` (third-party
audit of 3.6, files 1046 and 1047) `DESIGN_AUDIT_T3.md` (technical audit of 3.7, file 1048) and `DESIGN_AUDIT_T3_RECHECK.md` (its re-audit of 3.8, file 1049,
with the evidence pack `db/tools/evidence_pack.sh`). Migration plans: `MIGRATION_PLANS.md`. Rules for every schema change:
`STANDARDS.md`.

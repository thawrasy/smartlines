# Database design and ERD

Source: Analysis and Design Study v2.7 (English) and the Use Case and Data Flow Diagrams v1.0, applied to the
schema in `db/schema` (files 000 to 1033).

- `Masslak_Database_Design_and_ERD_v3.0.docx`: changes in 3.0, architecture, relationship rules R1 to R4, security model, data stores D1 to D17,
  37 module ERDs and 2 focus diagrams with their relationship tables (cardinality, delete rule, index), every
  table definition, traceability to the study, verification, and the references without a foreign key (appendix C).
- `erd/svg`, `erd/png`: the diagrams, in the study's colours (overview `E00_overview`, modules `E01` to `E37`, focus
  diagrams `F01` travel documents and `F02` booking spine, `legend`).
- `generator/`: `diagrams.py` (diagram groups, every table in exactly one; focus diagrams), `render.py` (reads the built
  database, draws with graphviz), `trace.py` (maps every study entity to its tables), `build.js` (the document).

Regenerate after a schema change (needs graphviz, Pillow and the `docx` npm package):

```sh
createdb masslak_doc && ./db/build.sh masslak_doc
cd docs/database/generator
python3 render.py masslak_doc
python3 trace.py ../../Masslak_Analysis_and_Design_EN_v2.7.docx
node build.js
```

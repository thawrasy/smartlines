# Database design and ERD

Source: Analysis and Design Study v2.6 (English) and the Use Case and Data Flow Diagrams v1.0, applied to the
schema in `db/schema` (files 000 to 1029).

- `Masslak_Database_Design_and_ERD_v2.0.docx`: architecture, design rules, security model, data stores D1 to D17,
  37 module ERDs with their relationship tables, every table definition, traceability to the study, verification.
- `erd/svg`, `erd/png`: the diagrams, in the study's colours (overview `E00_overview`, modules `E01` to `E37`, `legend`).
- `generator/`: `diagrams.py` (diagram groups; every table belongs to exactly one), `render.py` (reads the built
  database, draws with graphviz), `trace.py` (maps every study entity to its tables), `build.js` (the document).

Regenerate after a schema change (needs graphviz, Pillow and the `docx` npm package):

```sh
createdb masslak_doc && ./db/build.sh masslak_doc
cd docs/database/generator
python3 render.py masslak_doc
python3 trace.py ../../Masslak_Analysis_and_Design_EN_v2.6.docx
node build.js
```

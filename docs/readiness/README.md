# Readiness document set (October 2026)

Three Arabic Word documents for the systems company that will study the platform before the real implementation. They
start from the code and the database as they are after commit `b983b22` (schema files up to 1099).

| File | What it is |
|---|---|
| `Masslak_Readiness_Document_Register_AR_v1.0.docx` | The register: the 40 documents an implementation needs, grouped by kind, with the state of each one (complete, partial, needs an update, prepared in this set, missing, owner input), where it is, and what the systems company should provide |
| `Masslak_System_Models_Addendum_AR_v1.0.docx` | Addendum to `../Masslak_Use_Case_and_Data_Flow_Diagrams_v1.0.docx`: use cases UC-11 to UC-13, six use case specifications, level-2 data flows DFD-15 and DFD-16 (processes P15 and P16, stores D18 to D22), state diagrams ST-1 to ST-6, sequence diagrams SQ-1 to SQ-4, glossary |
| `Masslak_Test_and_Acceptance_Plan_AR_v1.0.docx` | The test and acceptance plan: the test levels that run today, environments and data, entry and exit criteria, 37 acceptance scenarios mapped to the automated tests, the non-functional acceptance (launch gates 1 to 8), defect severity, sign-off, results record |

## Diagrams

`png/` holds the 17 diagrams the addendum embeds. `generator/models.py` is their model: the new actors, use cases,
processes and stores (added to the v1.0 model in `../diagrams/uc-dfd/generator`, so the notation and the look stay the
same), and the state and sequence diagrams in Mermaid. The states and transitions follow the database rules
(`sales.tg_booking_transition`, `sales.tg_ticket_transition`, `fin.tg_payment_transition`, the photo rule and policy change
functions of 1087 to 1096, and 1097 to 1098 for the grants and references); the trip transitions are the API's.

Regenerate after a change to the model (needs Graphviz, cairosvg and the Mermaid CLI with a Chromium):

    cd docs/readiness/generator
    MMDC=/path/to/mmdc PUPPETEER_CONFIG=/path/to/puppeteer.json python3 render.py

## The Word documents

The Word files are binary deliverables. Their build scripts (`generator/*.js`, with the `docx` npm package) hold the Arabic
text of the documents, so they are kept out of the repository under the language policy (`scripts/check_language.py`)
and listed in `.gitignore`. When the code changes what a document says (a new migration, a new test, a changed rule),
the document is rebuilt and its version raised; the facts each one states are checked against the code at that commit.

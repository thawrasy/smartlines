# Readiness document set (October 2026)

Arabic documents for the systems company that will study the platform before the real implementation. They start from
the code and the database as they are after commit `b983b22` (schema files up to 1099), and each states its facts from
the code at that commit. Every document of the set was then brought up to commit `c7528af` (schema files up to 1112:
the six closed gaps, the station counter, station sales and screens, and the owner's decisions on the cancellation
penalty, partner redemption, taxes, signing keys and the counter photo), except the addendum, whose content edition 2.1
of the use cases carries. The register, at 1.7, also records the design review of the station screens (file 1113) and the owner's decisions built after it (files 1114 and 1115,
`../design/STATION_SCREENS_REVIEW.md`).

| File | What it is |
|---|---|
| `Masslak_Readiness_Document_Register_AR_v2.3.docx` | The register: the 43 documents an implementation needs, the state of each (complete, prepared in this set, draft awaiting approval, partial, needs an update, missing, owner input), where it is, and what completes it |
| `Masslak_Use_Case_and_Data_Flow_Diagrams_AR_v2.1.docx` | Use cases and data flows, edition 2.1: the v1.0 model (study 2.5) reviewed case by case against the code, 18 use case diagrams with 220 cases, each with its build status and evidence (route, table, test); context, three level-1 and 13 level-2 data flow diagrams; stores D1 to D23 as database tables; specifications of the main cases as built, the station counter, sale and departure board among them; the list of what is not built or only partly built and what became of the gaps edition 2.0 named. Replaces edition 2.0, `../Masslak_Use_Case_and_Data_Flow_Diagrams_v1.0.docx` and the addendum |
| `Masslak_Behaviour_Models_AR_v1.1.docx` | State diagrams of 19 entities with where each transition is enforced, 10 sequence diagrams, 9 activity diagrams of daily operations (the station counter, SOS and incidents and a carrier's trip cancellation among them) |
| `Masslak_Software_Requirements_Specification_AR_v1.1.docx` | Requirements baseline as built: 220 functional requirements (FR-xx.yy = UC-x.y), 32 non-functional requirements with their measure and verification, external interfaces, data requirements |
| `Masslak_Requirements_Traceability_Matrix_AR_v1.1.xlsx` | Each requirement to its use case, actors, processes, data flow diagrams, status, priority, evidence, tests and acceptance scenario |
| `Masslak_Business_Rules_Catalog_AR_v1.1.docx` and `.xlsx` | The rules the platform enforces: 350 raised by database functions, 504 by the API, 1,603 CHECK constraints, with their codes, places and the tests that name them |
| `Masslak_Test_and_Acceptance_Plan_AR_v1.1.docx` | Test levels that run today, environments, entry and exit criteria, 45 acceptance scenarios mapped to the automated tests, non-functional acceptance (launch gates), defect severity, sign-off |
| `Masslak_System_Models_Addendum_AR_v1.0.docx` | The addendum of October 2026 (UC-11 to UC-13 and their specifications, glossary); its diagrams are now part of edition 2.0 |
| `Masslak_DPIA_Boarding_Photo_AR_v0.2.docx` | Draft data protection impact assessment of the boarding photo, the station counter role included, for the data protection officer |
| `Masslak_RACI_Matrix_AR_v0.2.docx` | Draft responsibility matrix: 25 activities, 9 roles |
| `Masslak_Initial_Data_Load_Plan_AR_v0.2.docx` | Draft plan for loading reference data, carriers, stations, fleet, network, tax schemes and loyalty partners before the pilot, with the bulk import tool |
| `Masslak_Training_Plan_AR_v0.2.docx` | Draft training plan: ten role paths with pass criteria |

The current database design document is `../database/Masslak_Database_Design_and_ERD_v3.17.docx` (schema file 1136); the requirements, rules and test documents above describe schema file 1112.

## Diagrams and extracted data

- `generator/models_v2.py`: the model of edition 2.0, every case with its status and evidence, the cases added since
  study 2.5, UC-14 to UC-17, DFD-1C and the new level-2 diagrams. It extends the v1.0 model in
  `../diagrams/uc-dfd/generator`, whose renderers draw the diagrams (`ucsvg.CASE_LOOK` colours each case by status).
- `generator/models.py` and `generator/models_beh.py`: state, sequence and activity diagrams in Mermaid.
- `generator/rules_catalog.py`: extracts the business rules from the database and the API (`work2/rules.json`).
- `png/v2/`: the diagrams the documents embed; `png/`: those of the addendum.

Regenerate (needs Graphviz, cairosvg, the Mermaid CLI with a Chromium, and a database built with `db/build.sh`):

    cd docs/readiness/generator
    python3 render_v2.py
    MMDC=/path/to/mmdc PUPPETEER_CONFIG=/path/to/puppeteer.json python3 render_beh.py
    PGPASSWORD=... python3 rules_catalog.py <database> -h localhost -U postgres

## The Word and Excel files

The Word and Excel files are binary deliverables. Their build scripts (`generator/*.js` with the `docx` npm package,
and `generator/*_ar.py` with openpyxl) hold the Arabic text of the documents, so they are kept out of the repository
under the language policy (`scripts/check_language.py`) and listed in `.gitignore`. When the code changes what a
document says, the document is rebuilt and its version raised.

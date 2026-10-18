# Independent review without repository access

The four evaluation reports of 18 October 2026 (TEM, GP, GIMI, MANU) asked for read access to the repository for an
independent reviewer. The owner declined: no access to the repository is opened. Instead the reviewer receives a
document pack built from one commit, and a follow-up report answers the reviewer's findings after the review.

## What the reviewer receives

| Item | Source |
|---|---|
| Analysis and design study 3.9 (English and Arabic) | `docs/Masslak_Analysis_and_Design_EN_v3.9.docx` and its Arabic edition |
| Database design and ERD 3.16 | `docs/database/` |
| Readiness document register | the latest register edition |
| The consolidated reply to the four reports | delivered with the pack |
| Evidence pack, reviewer edition | `evidence-pack-reviewer` artifact of the CI run of the delivered commit; attached to every release as `masslak-<tag>-evidence.tar.gz`, inside the signed checksums |

The reviewer edition (`db/tools/evidence_pack.sh --reviewer`) holds:

- `critical/CRITICAL_CONTROLS.md`: the nine critical controls of `docs/operations/evidence/critical_controls.json`, each
  quoted from the code of the commit (Python functions through `ast`, SQL functions from the last schema file that
  defines them), with the names of the tests that prove it and their result in the same run
  (`db/tools/critical_excerpts.py`). The pack fails to build if a quoted function is missing or one of its tests failed.
- `tests/`: the console output of the database checks and the API tests, every API test with its result
  (`api_results.csv`) and the coverage summary. The test sources and the database checks' script are left out, and so
  is `audit_pack/` (the schema, grants, policies and function bodies of the built database), by the owner's decision.
- `evidence/`, `monitoring/`, `docs/`: measurements, alert rules with their tests, runbooks, SLOs and audit responses.
- `SHA256SUMS` over every file, and the commit and tree hash it was built from.

## Procedure

1. Build the pack from the commit being delivered: the `evidence` job of `ci.yml` does it on every push; a release adds
   it to its signed assets.
2. Check `SHA256SUMS`, then hand the documents and the pack to the reviewer. Record the date and the commit.
3. The reviewer's questions are answered from the pack, or with a further excerpt added to `critical_controls.json`, so
   the next pack carries it with its tests.
4. The reviewer's report is answered point by point in a follow-up report, against the same commit or a later one that
   names what changed.

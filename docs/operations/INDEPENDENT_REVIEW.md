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
  (`db/tools/critical_excerpts.py`), counted as passed, skipped and failed. The pack fails to build if a quoted function
  is missing or one of its tests failed or was skipped; a test the suite skips and a later CI step runs (the live event
  contract check) is taken from that step's own JUnit report.
- `tests/`: the console output of the database checks and the API tests, every API test with its result
  (`api_results.csv`) and the coverage summary. The test sources and the database checks' script are left out, and so
  is `audit_pack/` (the schema, grants, policies and function bodies of the built database), by the owner's decision.
- `evidence/`, `monitoring/`, `docs/`: measurements, alert rules with their tests, runbooks, SLOs and audit responses.
- `evidence/verification.json`: the figures of this build (commit, database checks, API tests, schema files, schema
  hash), made by the pack from the same database and logs; the pack never copies one left by an earlier build.
- `SHA256SUMS` over every file, and the commit and tree hash it was built from.

## Procedure

1. Build the pack from the commit being delivered: the `evidence` job of `ci.yml` does it on every push; a release adds
   it to its signed assets.
2. Check `SHA256SUMS`, then run `python3 db/tools/check_delivery.py <unpacked pack> <each .docx of the delivery>`: every
   document must name the pack's commit and its database check, API test and schema file counts, and the pack's
   verification and critical controls must be of the same commit (independent review of 18 October 2026). Hand the
   documents and the pack to the reviewer only when it passes. Record the date and the commit.
3. The reviewer's questions are answered from the pack, or with a further excerpt added to `critical_controls.json`, so
   the next pack carries it with its tests.
4. The reviewer's report is answered point by point in a follow-up report, against the same commit or a later one that
   names what changed.

## Delivery record

The follow-up report answers the reviewer against the commit of the delivery it names.

| Delivery | Date | Commit | Contents (SHA-256 of each file in the delivery's `SHA256SUMS`) |
|---|---|---|---|
| 1 | 18 October 2026 | `e6dbeb8b00e1ce35b5a6c3c6c123a74bcb1bd5a4` | Study 3.9 (English and Arabic, Word and PDF), database design and ERD 3.16 and readiness register 2.2 as handed over (3.17 and 2.3, built from this commit the same day, did not reach the reviewer; see below), reply to the four evaluations 1.1 (Word and PDF), evidence pack reviewer edition without `audit_pack/` (`masslak-evidence-reviewer-e6dbeb8.tar.gz`, `ef011b645c708db6d970590fd3799ac72ae6270a6a6dc68508bfb2ec49fdba03`); tests of that commit: 924 database checks passed, 773 API tests passed and 11 skipped, coverage 87.5 % |

Delivery 1 reached the reviewer as its first archive (SHA-256 `974152db9c86a2f77dc9a1b665f4355b3e1bc3865612ddfbb6beb5fb09ae114a`):
design 3.16 and register 2.2, issued before 3.17 and 2.3, with the same evidence pack. The reviewer's report on it (18 October
2026, 87.1 of 100: not ready for a public launch, ready to be built for operation) found the pack's `verification.json` left by
an earlier build (commit `840b3dc`, schema file 1132) and the event contract check of C-08 shown as skipped. Both were defects of
the evidence tools, fixed in commit `921369d` (the pack makes its own verification; skipped tests of a critical control fail the
pack; `check_delivery.py`). The follow-up report answers the review point by point.

| Delivery | Date | Commit | Contents |
|---|---|---|---|
| 2 | 18 October 2026 | `921369d872757ecae2d659b54ad28de6b36df73b` (tested; the documents are of `71def24`, documentation only since) | Follow-up report on the independent review 1.0 (Word and PDF), database design and ERD 3.18, readiness register 2.4 (Word and PDF), evidence pack reviewer edition (`masslak-evidence-reviewer-921369d.tar.gz`, `cba0e3dd10eaf93cd96bb2790d93af2c637b0ab3d362b0c63d04916753fb9aa4`); archive `Masslak_Independent_Review_Delivery2_921369d.zip`, `05c55c7ff4c4c22c682b797c419023077bdf7bdab9c76b8dea108832a473602a`. Tests of that commit: 924 database checks passed, 773 API tests passed and 11 skipped, the live event contract check 5 of 5; critical controls 142 of 142 passed, none skipped. `check_delivery.py`: 0 problems |

The reviewer may study delivery 2 again and compare the two reviews.

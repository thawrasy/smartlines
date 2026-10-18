# Independent review without repository access

The four evaluation reports of 18 October 2026 (TEM, GP, GIMI, MANU) asked for read access to the repository for an
independent reviewer. The owner declined: no access to the repository is opened. Instead the reviewer receives a
document pack built from one commit, and a follow-up report answers the reviewer's findings after the review.

## What the reviewer receives

| Item | Source |
|---|---|
| Analysis and design study 3.11 (English and Arabic) | `docs/Masslak_Analysis_and_Design_EN_v3.11.docx` and its Arabic edition |
| Database design and ERD 3.20 | `docs/database/` |
| Readiness document register | the latest register edition |
| The follow-up reports on the reviewer's reports | delivered with the pack |
| Evidence pack, reviewer edition | `evidence-pack-reviewer` artifact of the CI run of the delivered commit; attached to every release as `masslak-<tag>-evidence.tar.gz`, inside the signed checksums |

The reviewer edition (`db/tools/evidence_pack.sh --reviewer`) holds:

- `critical/CRITICAL_CONTROLS.md`: the critical controls of `docs/operations/evidence/critical_controls.json`, each
  quoted from the code of the commit (Python functions through `ast`, SQL functions from the last schema file that
  defines them), with the names of the tests that prove it and their result in the same run
  (`db/tools/critical_excerpts.py`), counted as passed, skipped and failed. The pack fails to build if a quoted function
  is missing or one of its tests failed or was skipped; a test the suite skips and a later CI step runs (the live event
  contract check) is taken from that step's own JUnit report.
- `critical/THREAT_CONTROL_MAP.md`: each threat of `docs/operations/evidence/threat_control_map.json` with its controls
  and their passing tests, or the launch gate that closes it. The pack fails to build if a threat has neither, or a
  control it names has no passing test (independent review, round 8, T-04).
- `tests/`: the console output of the database checks and the API tests, every API test with its result
  (`api_results.csv`) and the coverage summary. The test sources and the database checks' script are left out, and so
  is `audit_pack/` (the schema, grants, policies and function bodies of the built database), by the owner's decision.
- `evidence/`, `monitoring/`, `docs/`: measurements, alert rules with their tests, runbooks, SLOs and audit responses.
- `evidence/settings_guard.txt`: `shared_preload_libraries`, `sys.guard_status()` and the protected settings of the
  database the tests ran on, with the SHA-256 of the guard's source and build files (`db/guard`); the pack fails to
  build if the guard is not loaded (round 8, T-06).
- `evidence/verification.json`: the figures of this build (commit, database checks, API tests, schema files, schema
  hash), made by the pack from the same database and logs; the pack never copies one left by an earlier build.
- `SHA256SUMS` over every file, and the commit and tree hash it was built from.

## Procedure

1. Deliver the reviewer edition that the `evidence` job of `ci.yml` built for the delivered commit (artifact
   `evidence-pack-reviewer` of that run; `source/CI_RUN.txt` names the run, so the reviewer can open its log). The pack's
   commit and the tested commit are then the same: CI tested exactly that commit (second review of 18 October 2026). The
   documents of the delivery are generated afterwards from that run's figures and name that commit; they are kept in the
   repository by a later, documentation-only commit, which is a record and not the delivered code. A release adds the pack
   to its signed assets.
2. Check `SHA256SUMS`, then run `python3 db/tools/check_delivery.py <unpacked pack> <each .docx of the delivery>`: every
   document must name the pack's commit and its database check, API test and schema file counts, and the pack's
   verification and critical controls must be of the same commit (independent review of 18 October 2026). A current
   figure (schema files, tables, database checks, API tests, interface operations) that differs from the pack is a
   problem, unless it stands in a historical chapter (an earlier "Changes in version" chapter, or one opening with
   "Historical record") or in a paragraph that dates it by schema file, commit, release, version or delivery (round 8,
   T-01 to T-03). Hand the
   documents and the pack to the reviewer only when it passes. Record the date and the commit.
3. The reviewer's questions are answered from the pack, or with a further excerpt added to `critical_controls.json`, so
   the next pack carries it with its tests.
4. The reviewer's report is answered point by point in a follow-up report, against the same commit or a later one that
   names what changed. Its figures, like those of the study, the database design and the register, come from
   `db/tools/doc_figures.py` of the delivered commit, never typed by hand (reviewer's plan item A1).

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

Delivery 2 also exists as a complete edition, `Masslak_Independent_Review_Complete_921369d.zip` (SHA-256
`7e6a4853f3739685bea4a07d4cdd694ade37c559052fdea6abcdc7124d673987`): the same files, plus study 3.9 (English and Arabic) and
the reply to the four evaluations 1.1 in `earlier_documents/`, which keep the figures of the commits they were measured at.

The reviewer may study delivery 2 again and compare the two reviews.

The reviewer's detailed reply on delivery 2 (18 October 2026, round 7, 89.1 of 100) asked for a pack whose commit is the tested
one with a link to its CI run (A2), no figure unless generated (A1) and a wider prompt-injection set of 40 checks or more (B2).
The owner approved the three proposals that followed, and the repository stays closed. Widening the set found four gaps in
schema file 1134, closed by 1137. The reply named three critical controls wrongly (C-05 is step-up, C-07 the definer EXECUTE
revoke, C-09 production TLS and the key service) and listed as open four plan items that already existed (B1, B3, B4, A3);
follow-up report 2 answers it.

| Delivery | Date | Commit | Contents |
|---|---|---|---|
| 3 | 18 October 2026 | `6857d7a740bdb4063f79ebc43f9a661e1667e0e7` (tested and packed: the same commit; CI run https://github.com/thawrasy/smartlines/actions/runs/39135414851) | Follow-up report 2 on the independent review 1.0, study 3.10 (English and Arabic), database design and ERD 3.19, readiness register 2.5 (each Word and PDF), the evidence pack reviewer edition CI built for that commit (artifact `evidence-pack-reviewer` of the run, id 12139762093, zip digest `sha256:b773aef5ad294c8f6b423f5d60fe393a85c7e8c69c69ece9b337ffb4b944661f`), and `CHECK_DELIVERY.txt` (run against a pack built locally at the same commit, `SAME CODE`). Tests of that commit: 962 database checks passed, 773 API tests passed and 11 skipped, the live event contract check 5 of 5; critical controls 180 of 180 passed, none skipped (C-06: 51). `check_delivery.py`: 0 problems |

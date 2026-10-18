# ADR 0015: The fixes of the self-review of 2026-10-18

Status: decided by the database architect, at the owner's request to review the whole package before the external
review. Where a fix builds an owner decision (DQ-F12-7, DQ-F14-1, DQ-F14-5, DQ-F15-1, DQ-F15-9, DQ-F15-11, DQ-F15-12)
the decision is the owner's; DQ-F15-2 was the architect's. The register of findings is
`docs/34-self-review-2026-10-18.md` (Arabic).

## Context

A review in five lenses (guards and isolation, model against the specs, tests and CI, documents, deployment and
security) found 63 findings. The ones that change what the database allows:

- **An approved facility revision could still change.** The rows of a revision at or before
  `Facility.ApprovedRevisionNo` and the approved `FacilityRevision` row were editable, so the record of what was
  approved could be rewritten (A1).
- **Several guards read their parent row without a lock**, so an approval and a write to its rows could interleave,
  and the two copy triggers of a request could deadlock each other (A2).
- **A covenant evaluation could hide a breach** by saying "no threshold" on a covenant that has one, or apply another
  threshold than the covenant's (A3).
- **A restricted LC field could be copied** into an amendment under a key in other letters, a repeated key or a value
  longer than 4,000 characters, and raising a field to RESTRICTED left its old copies (A4).
- **The reporting role could call internal functions** that read the status of any tenant and IBAN hashes (A5).
- **Agenda items, covenant tests and breaches were keyed to the revision row**, not to the obligation's node, so a new
  revision generated a period again and the breach register broke at each revision (B1).
- **Owner decisions not yet in the model:** the waiver recorded before its approval, renewal moving utilisations to the
  successor, a waived agenda item's reason and document, ENDED derived, the lifecycle permission codes, the bank's
  confirmation for a withdrawn amendment (B2, B6, B7).
- **Deployment and audit gaps:** any login could declare a deployment window and silence the deployment login's
  alerts; the deployment login could stop the database audit specification inside its window; the preflight let a
  database prepared by someone else through; `deploy.sql` ran by hand without the preflight; server settings,
  credentials, linked servers and renamed logins raised no alert (E1, E2, E4, E5, E6).

## Decision

1. **Approved means final in the database.** For each of the 13 revisioned tables, 044 generates a trigger from the
   table's columns: a row with `FromRevision <= ApprovedRevisionNo` is not inserted, deleted or changed, but for its
   `ToRevision`, which moves only between NULL and revisions after the approved one (50049). The approved revision row
   is final in every column but its audit columns, and the junction rows of an approved obligation or covenant follow
   it. The facility row is read under an update lock.
2. **Every parent read in a guard takes `UPDLOCK, HOLDLOCK`.** The request's copy trigger reads the stage instance only
   on an insert or a change of the pointers or the copies.
3. **An evaluation applies the covenant's own threshold and operator**, a set threshold is always judged, and an unset
   one never is (50054).
4. **Restricted fields** are matched in every top-level key of the amendment, without regard to case; a field raised to
   RESTRICTED rewrites the copies already written.
5. **`090_readonly_denies.sql`** denies `tp_readonly` every function of `rls`, `sec`, `plat` and `cfg` and
   `lc.BeneficiaryIbanChange`; the row filters do not need the reader's permission.
6. **Tests, agenda items and breaches carry their node's root** (`CovenantRootId`, `ReportingObligationRootId`,
   `ObligationRootId`) through composite keys, and their uniques are on the root; a breach copies its test's root and
   period, and one breach per covenant root and period stays open.
7. **The owner decisions are in the model:** waiver fields on OPEN and IN_CURE with `WaiverApprovedBy/On` set by the move
   to WAIVED; `Utilization.Status = TRANSFERRED` to a row of the successor facility, proved by two composite keys, with
   a TRANSFER movement and its reason; WAIVED agenda items with reason and document; `Obligation.Status` without ENDED;
   `fac.lifecycle.manage` and `fac.lifecycle.suspend`; `LcAmendment.WithdrawalDocumentId`; `CovenantTest.State =
   CANCELLED` with its reason. Every source-stamped value without a document has `NoSourceReason` (generator).
8. **Deployment:** `deploy.sql` starts only after the preflight's mark in the same session (50146) and creates no
   database; the preflight refuses a server role or a server-wide right (50140), a database that holds anything but
   what `prepare_database.sh` leaves (50142), and `RECURSIVE_TRIGGERS ON` (50145); `SQLCMD_OPTS` takes an allowlist;
   `deploy.ps1` runs the same preflight.
9. **Audit (AL-18):** a deployment window counts only when the login that declared it enabled the deployment login
   within a minute (WINDOW otherwise); AUDIT is never silenced for the deployment login; new rules SERVER_CONFIG and
   LOGINS.
10. **CI:** results are matched anywhere on a line and each case is counted once; the post-deployment check also
    counts triggers, disabled triggers, open internal functions and the deployment login's state (14 rows); a final
    step checks that nothing the tests switched off is left off; the Arabic seed text is compared by its SHA-256; the
    workflow pins its actions and image.

## Consequences

- A change to an approved facility is always a new revision; a tool or a person that edited rows in place now gets
  50049. The tests that added rows to an approved revision now write them before the approval (`#Approve1`).
- The application writes the root copies; the composite keys refuse a wrong one.
- Each guard fix has a test (SR1 to SR9, T2b, X7, PF6 to PF8, SA8, SA9), and each was checked by mutation: 16 of 17
  mutations make their test fail. The one that does not is the old reservation copy under a MERGE: SQL Server chose the
  new row with the old code in the three statement shapes tried, though the order is undefined; the fix makes it
  defined.
- Left as documented limits: partial branch coverage of some guards, two timing-based tests, CI allowances that any
  operator can set, and open questions not all marked with their status (docs/34 section 7).

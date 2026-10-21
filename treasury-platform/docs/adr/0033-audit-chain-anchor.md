# ADR 0033: The audit hash chain and its anchor outside the database

Status: decided by the database architect on the owner's request of 2026-10-21 to build item 2 of the open points of
the external review (DOC-S12 section 5.3; FR-PLT-025, BR-PLT-009; DR-41 with O-13). Builds on ADR 0007 (the audit log
written by the database).

## Context

`aud.AuditLog` had the chain columns (ChainSeq, PrevHash, RowHash) but nothing wrote them. A chain alone does not reveal
tampering either: whoever can change a row can compute every hash again. DOC-S12 section 5.3 proposed a daily job that
verifies the chain and pushes its head to a store nobody with access to the database can rewrite.

## Decision

1. **The chain** (`db/static/055_audit_chain.sql`). One chain per tenant and one for the platform events (TenantId
   NULL, chain key 0). For each row:
   `RowHash = SHA-256(PrevHash ‖ ChainSeq as 8 bytes, big-endian ‖ the canonical text of the row in UTF-16LE)`.
   The canonical text (`aud.fn_AuditCanonical`) is the row's columns, except the three chain columns, as one JSON object
   in table order with nulls included. The first row of a chain has no PrevHash.
2. **Written by a trigger** (`aud.TR_AuditLog_Chain`). It runs on every insert, whoever writes: the binding and login
   procedures, the application, the jobs and the platform. It runs as tp_auth_exec, which the audit filter lets see
   every row. It takes the chain's head in `aud.AuditChainHead` under an update lock, so two writers never take the same
   number; what a writer put in the chain columns is replaced. The cost is that the audit writes of one tenant wait on
   each other until commit. Rows written before this script are chained once by `aud.usp_ChainExistingRows`; a chain
   that already has a head and has unchained rows was written with the trigger off, so that is refused (50099) and
   reported.
3. **The anchors.** The platform job JOB-PLT-AUDIT-CHAIN (`aud.usp_TakeAuditAnchors`) records the head of each chain that
   moved since its last anchor, in `aud.AuditChainAnchor`. `tools/deploy/audit_anchor.sh take <store>` writes them to a
   new read-only file in a store outside the database: a write-once bucket or WORM volume in another administrative
   domain. The database copy is for convenience; the store's copy is what counts.
4. **The verification** (`aud.usp_VerifyAuditChain`, `audit_anchor.sh verify <store>`) checks a chain against its latest
   anchor read back from the store. Each row's hash is computed again, each row must link to the one before, the
   numbers run from 1 without a gap, no row is left unnumbered, the head matches the last row, and the row at the
   anchor's number still has the anchor's hash. The results are OK, BROKEN, GAP, UNCHAINED, HEAD_MISMATCH,
   ANCHOR_MISMATCH and ANCHOR_MISSING. Each run is audited as AUDIT_CHAIN_VERIFIED, or as AUDIT_CHAIN_BROKEN with high
   severity, which AL-12 alerts on.
   - *Added on 2026-10-21 after the performance run (ADR 0036, docs/40).* A full check costs about 40 microseconds a
     row (2 s for a tenant of 50,000 rows), so its daily cost would grow without end. The daily check therefore runs
     from the latest anchor (`@FromAnchor = 1`, `audit_anchor.sh verify`). It reads the anchor's row and the rows after
     it: 206.40 ms at p50 and 244.25 ms at p95 for a day of 500 rows in the committed run (J4, `docs/perf/perf-run.txt`).
     A probe after the committed run, once the chain's filter seeks on its index (ADR 0036 section 4), gave about
     0.17 s; it is not in `perf-run.txt` and will appear in the next run.
   - A rewrite of older rows that computes the hashes again still changes the anchor's row, so the daily check catches
     it. An old row changed *without* its hash computed again is seen only by the full check, which runs weekly
     (`audit_anchor.sh verify --full`). Tests AC7 and AA3 show both.
5. Only tp_jobs may execute the two job procedures, with the job's own key. No role is granted the head or the anchor
   table.

6. *Amended on 2026-10-21 by ADR 0039 (internal review v6).* The store, not the database, judges the anchors: `take`
   verifies every chain from its latest store anchor before anchoring and refuses a rewritten chain; what moved is
   decided against the store's latest anchors (`@StoreLatest`, 50148); the store carries `.bankfas-anchor-store`, files
   have unique names and are read back; `verify` fails STALE and NOT_ANCHORED chains, `verify --full` checks every
   anchor of the store; `restored` records the heads after a restore. The verification reads up to the head it read
   first; the anchor job holds no lock; heads are locked in key order; unchained rows no longer stop a deployment;
   `tp_readonly` is denied the head and anchor tables. Tests AA1 to AA7 and AC1 to AC10.

## Limits

- An administrator of the database can still change rows and compute every hash again. What they cannot change is the
  anchors in the store, so the first anchor after the change no longer matches.
- Rows removed after the last anchor are found only at the next anchor. The job therefore anchors daily, and SQL Server
  Audit (ADR 0012, AL-18) records the change itself.
- The notification to the tenant (PLT.INTEGRITY_FAIL) is not built. It waits for the notification dispatcher (DOC-F17).

## Tests

- `db/tests/integrity_tests.sql` AC1 to AC7: the chain; the anchors; a changed row, and every hash rewritten (caught by
  the anchor); rows removed from the middle and the end; a row written with the trigger off; the job's rights; the
  daily check from the anchor and what it leaves to the full check.
- `tools/ci/audit_anchor_check.sh` AA1 to AA3: files in the store, the daily check, and an old row changed: passed by
  the daily check, caught by the full check, put back.

# ADR 0042: Slice S1-b of the application, its defaults and the gaps it closed

Status: built on 2026-10-22 on the owner's request "I approve the defaults and start building S1-b" (docs/31, row 39).
The defaults below were taken from the S1-b brief and wait for the owner's approval. Written by an AI agent.

## Context

S1-b is the structure of a company and its signing powers: ownership, governing bodies and members, authority grants,
bank signatories and their authorities, and the comparison of the two. The brief found nineteen gaps between the
specifications and the database (S1B-GAP-1 to 19) and nineteen open questions (OQ-1 to 19).

## Decision

### 1. Batches

| Batch | Content |
|---|---|
| S1B-A | NTF.BASE v3, CORE.EXPIRY v2, the segregation-of-duties setting, static script 061, the AuthorityConflict model change, the expiry provider registry, the merge collision check, the document-in-use check, active usages, server-side module gating |
| S1B-B | Ownership: the change wizard, the 100% check, effective ownership, the mismatch report and notice |
| S1B-C | Governing bodies, members, authority grants and their lifecycle, the authority and holder queries, the matrix, the integrity report, body and grant expiry |
| S1B-D | Signatories, authorities, SVC-03, the signatory expiry provider and JOB-ACC-EXPIRY, the specimen, relationship closing |
| S1B-E | The governance comparer, the conflicts and R-ACC-04, the exit test, these documents |

### 2. Database changes

- `db/static/061_s1b_guards.sql`: `org.TR_AuthorityGrant_Lifecycle` keeps REVOKED and SUPERSEDED final and an ACTIVE
  grant's substance (error 50175, mapped to 409 GRANT_FINAL); column DENYs to tp_app on the terms of
  `acc.SignatoryAuthority` and on the keys of `acc.AuthorityConflict`.
- `acc.AuthorityConflict` gains `AuthorityGrantId` (the candidate grant compared) and `ResolvedOn`, with a check that
  RESOLVED has a resolution time and no other status has one. No database is deployed, so the baseline was regenerated
  without a migration (as in S1-C).
- `org.grant.segregation_of_duties` (BOOL, default true) in seed 100.

### 3. Notable rules in the application

- An ownership change is the whole distribution from a date, written up to the next recorded change; rows are never
  deleted, so a change on a date where one already starts is refused.
- The governance comparison runs on every authority save (a warning, never a refusal), on `authority.granted` and
  `authority.revoked`, and nightly. Its fingerprint is the SHA-256 of both sides and their row versions, so any change
  on either side opens a new row and the old one resolves.
- The expiry job takes its items from providers (company document, identity document, body term, authority grant,
  signatory); a provider that has two kinds of rows under one rule gives the second a negative id in the alert log.
- A statement with OUTPUT on a table with triggers writes OUTPUT INTO a table variable.

### 4. The defaults taken

OQ-1 to OQ-19 as listed in docs/44 section 4, waiting for the owner's approval.

## Consequences

- S3 adds the sufficiency check of signatures (SVC-04) on top of SVC-03 and the authorities.
- The nightly digest of conflicts arrives with JOB-NTF-DIGEST.
- A change of a default is a later change, not a rebuild.

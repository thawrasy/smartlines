# ADR 0041: Slice S1 of the application, its defaults and the gaps it closed

Status: built on 2026-10-22 on the owner's request "start building S1" (docs/31, row 38). The defaults below are
assumptions taken from the S1 brief; they stand until the owner confirms or changes them. Written by an AI agent.

## Context

S1 is the first business slice: companies with their documents, persons and entities, banks with their contacts,
relationships and accounts, the catalogues and base rates, and the notifications they raise. Its exit is two flows
(DOC-B02 section 4): a bank onboarded with one wizard (AC-INS-1) and a company onboarded with its documents and their
expiry alert (AC-ORG-6). The S1 brief found eighteen gaps between the specifications and the database (S1-GAP-1 to
18) and eleven open questions (OQ-1 to 11), each with a proposed default.

## Decision

### 1. Batches

S1 was built in six batches, each with its tests and its own commit:

| Batch | Content |
|---|---|
| S1-A | The tenant seed packs (CAT.*, CORE.NUMBERING, CORE.EXPIRY, CORE.DEPARTMENTS), the insert-only seeder and its daily UPGRADE run, the catalogue guards in the database (060), the catalogue API and screens |
| S1-B | The document store (chunked AES-256-GCM, content sniffing, malware scan), companies with their mirror party, tree, fiscal periods, tax rates, contacts and departments |
| S1-C | Persons and entities: identity documents encrypted, masked and found by blind index, the audited reveal, renewal, images, custom fields, duplicates and the merge |
| S1-D | Institutions, units, contacts, relationships, coverage, products and channels, the bank set-up wizard, bank accounts, base rates |
| S1-E | The notification pipeline, NTF.BASE v2, the expiry alerts, the security events, the bell and the preferences |
| S1-F | The exit-path tests, the browser flow, these documents |

### 2. The defaults taken (to be confirmed)

| Question | Default |
|---|---|
| OQ-1 malware scanner | ClamAV (clamd INSTREAM) in production; a stub that only flags the EICAR test file in development and tests |
| OQ-2 party code | `P{seq:000000}`, per tenant, gaps allowed |
| OQ-3 expiry rule granularity | One rule per generic item type (COMPANY_DOCUMENT, IDENTITY_DOCUMENT) |
| OQ-4 search by identity number | Kind and country, the country defaulting to the tenant's home country |
| OQ-6 mirror party | Names only are synced; the CR stays on the company |
| OQ-7 thumbnails | None stored |
| OQ-8 audit categories | org, pty, ins, acc: TREASURY; catalogues, notification rules: CONFIG; reveals and images: IDENTITY_ACCESS |
| S1-GAP-12 CreatedBy | Set by the application on every S1 write |
| S1-GAP-15 account reveal | An audit event (ACCOUNT_REVEALED or ACCOUNT_REVEAL_DENIED, IDENTITY_ACCESS), without a new value in `aud.SensitiveAccessLog.AccessKind`; the anomaly count adds both |
| Digests (FR-NTF-014) | Not in S1: a preference is IMMEDIATE or OFF |

### 3. Notifications (S1-GAP-2, 3, 9)

- A notification starts as an outbox event `notification.requested`, written in the transaction of the change: the
  event code, the target, the company, the deduplication key and the values of the placeholders. A value is text or
  `{ar, en}`; no restricted value is ever a placeholder (BR-NTF-008).
- Its aggregate is `ntf.<target type>`, so the request is not held behind the target's own domain events.
- JOB-PLT-OUTBOX consumes it:
  - recipients from the event's rules (role, permission, user) and from the request (the roles of an expiry rule, the user concerned);
  - active users only, within the company scope when the rule asks for it, never the actor;
  - one notification per user and deduplication key; the template of the user's language, the tenant's override first;
  - an in-app delivery always for a mandatory event, an e-mail delivery when the event has the channel and the user did not switch it off.
- The domain events with no consumer in S1 are listed and delivered as they are; any other event name fails and
  becomes DEAD, so it is seen, never lost silently.
- JOB-NTF-DISPATCH sends the e-mails from the EMAIL template, with the retries of BR-NTF-009; after five failures
  the delivery is DEAD and the administrators hear (NTF.DELIVERY_DEAD).
- JOB-NTF-EXPIRY, daily:
  - the nearest lead threshold crossed is sent once, and the farther ones are recorded so they never come later;
  - on the expiry date, EXPIRED; then a reminder every ReminderAfterExpiryDays;
  - each alert is a row of `cfg.ExpiryAlertLog` keyed by the expiry date, so a renewal starts again.
- NTF.BASE v2 keeps every row of v1 and adds the S1 events. The tenant seeder applies each pack at its latest version.
- SEC.LOCKOUT is written by `sec.usp_RecordAuthFailure` (030) in the same statement as the lockout. The other
  security events are written by the application where they happen: a sensitive permission given or taken, an MFA
  reset, support access, the 21st reveal within an hour.

### 4. Banks and accounts

- The wizard (`POST /bank-setup`) does everything in one serializable transaction. A dry run does the same work
  and rolls it back, so the review shows exactly what "create" will make, with its warnings.
- Account numbers and IBANs:
  - encrypted with the DATA key and bound to the row and column (AAD);
  - masked when written: the country and the last four for an IBAN, "•••• 1234" for a number;
  - unique through blind indexes (HMAC with the BLIND_INDEX key over the kind and the normal form).
- The IBAN has the length of its country (ISO 13616 registry) and passes mod 97.
- Direct integration is refused as a channel until an adapter exists (BR-INS-010).

### 5. A gap found on the way

The deployment check `tools/dbgen/check_deployed.py` did not count the per-catalogue triggers that 060 builds in a
loop (S1-A), so it expected 122 triggers where 140 are deployed. The family `_SeedRows` is now counted like those
of 044 and 054.

## Consequences

- The S1 defaults above are listed for the owner in docs/31 and docs/43; changing one is a later change, not a
  rebuild.
- Facilities (S2) join the closing check of a relationship (BR-INS-011) and the usage of accounts. The signatories
  (S1-b) join the accounts with their signing rules.
- The digest job, the reminders of required actions and the retention job of notifications remain for later
  slices. Their jobs are in the catalogue already.

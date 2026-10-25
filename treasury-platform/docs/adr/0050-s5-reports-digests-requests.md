# ADR 0050: Slice S5 of the application (reports, e-mail digests, the rest of the requests), its defaults and deviations

Status: built on 2026-10-24, at the owner's request "finish to the end without coming back to me". The eight open
questions (OQ-1 to OQ-8) were built on their recommended defaults, **pending the owner's approval** (docs/31, row 51;
docs/50 §4). Written by an AI agent.

## Context

S5 in the plan (docs/01 §8) is the reports, the e-mail notifications, the rest of the general requests and the
readiness for the pilot. The requirements index lists 24 items for S5 (1 Must, 13 Should, 10 Could). The e-mail
channel itself (FR-NTF-013, FR-NTF-019) was built in S1; S5 adds what the pilot needs on top of it.

## Decision

### 1. Reports as a catalogue of read-only queries

`ReportEndpoints` holds the seventeen letter of credit reports of spec 14 section 10 (R-LCI-01 to 09, R-LCE-01 to 08)
as a catalogue: code, module, titles, the permissions it needs, its columns and its query. Each query reads in the
user's company scope through one shared predicate and takes the same filters (company, period, days, status). The
catalogue endpoint lists only the reports the user may read; the same check guards a run and an export. A screen
shows up to 1,000 rows; an export up to 100,000, audited as REPORT_EXPORTED. There is no reporting database or
read-only login (DQ-S08-6 stays as decided: the reports go through the application).

### 2. CSV, not xlsx or PDF (OQ-2)

Exports are UTF-8 CSV with a byte order mark, so Excel opens Arabic text, and a cell that starts with `=`, `+`, `-` or
`@` is prefixed with `'`. No spreadsheet or PDF library is added; PDF output remains the browser's print (ADR 0049).

### 3. The digest holds the delivery, not the notification

A user who chose DIGEST_DAILY or DIGEST_WEEKLY for an e-mail group still gets the in-app notification at once; its
EMAIL delivery is written PENDING without a send time, which JOB-NTF-DISPATCH never picks. JOB-NTF-DIGEST, hourly,
gathers them at `ntf.digest.daily_at` in the tenant's time zone (and on `ntf.digest.weekly_day`), sends one e-mail per
user and period, marks the deliveries DIGESTED with their batch, and records the batch SENT. The unique key of
`ntf.DigestBatch` (user, channel, kind, period end) makes a second run a no-op. A mandatory event is never held. A
failed send leaves the items for the next period (OQ-6).

### 4. Archive without delete

JOB-NTF-RETENTION archives a notification read more than `ntf.retention.archive_days` ago (180). It never deletes and
never archives an unread one (BR-NTF-011).

### 5. Copy of any top-level request

The copy of S4 (proforma only) becomes the copy of any request whose type has no parent: the fields editable in DRAFT
and the current terms go into a new draft; the treasury's fields, the attachments and the references do not. A child
request is raised again from its parent. The endpoint moves from the sales endpoints to the request endpoints.

### 6. Example request types without templates

WFL.BASE v3 seeds BANK_GUARANTEE, FX_REQUEST, PAYMENT_APPROVAL, BANK_LETTER_REQUEST and FACILITY_DRAWDOWN with their
audiences and no template, so they stay inactive (Q-REQ-01, approved on 2026-10-19). Publishing a template for one
activates it.

### 7. The template installer skips a seeded key at any version

`WorkflowSeed` skipped a template seeded at this pack version or an earlier one; an earlier version run again on an
account seeded at a later one would have published its templates a second time. It now skips a template already
seeded under its SeedKey at any version.

## Consequences

- Settings: 44 (three new: `ntf.digest.daily_at`, `ntf.digest.weekly_day`, `ntf.retention.archive_days`).
- Not built in S5, with the reason for each: docs/50 §5 (tenant data export and retention, hosting package, SSO,
  tenant default preferences, template preview, the general type designer, PDF timeline, catalogue import, and the
  Could items of the letters of credit).

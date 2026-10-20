# ADR 0027: The early warning job and its notifications

Status: decided by the database architect on the owner's request of 2026-10-20 to build the notification job of the
early warning (docs/36-internal-perspective-study.md gap F4, phase D follow-up). Builds on ADR 0024 (the readiness file
and the early warning view) and on the notification path of DOC-F17 (the outbox, the notification builder, the jobs).

## Context

ADR 0024 listed the early warnings of a day in `fin.v_CreditEarlyWarnings`, and left the sending to "the notification
job of the application". Nothing sent them: the company had to open the readiness file to learn that a lender date was
coming and that it was not ready for it. A view also has no memory, so a job reading it daily would send the same
warning every morning for six months.

## Decision

1. **The job** `JOB-FIN-READINESS` joins the closed catalogue `cfg.JobDefinition` (TENANT, TRIAL and ACTIVE), daily at
   05:20 in the tenant's time: after JOB-FIN-EVAL (04:30) and JOB-OBL-CALENDAR (05:00), whose covenant tests and
   reports it reads, and before JOB-NTF-DIGEST (07:30), which gathers the morning's notifications.
2. **The procedure** `fin.usp_RunEarlyWarnings(@AsOf, @Issued OUTPUT)` (db/static/051) runs only bound as this job to a
   tenant that allows it (`sec.fn_JobTenant`, 037 and 042); `@AsOf` is the tenant's local date, which the worker
   computes from the time zone of `plat.usp_ListTenantsForJobs`, and must be within a day of the UTC date. Error 50092.
   One run per tenant at a time (`sp_getapplock`).
3. **What it reads**: `fin.fn_CreditEarlyWarnings(@AsOf)`, the dated form of the view of 049, which adds the stage of
   the time left: LEAD (within the lead time), D90, D30 and D7 (90, 30 and 7 days or fewer).
4. **Once per stage and readiness** (BR-FIN-041): the log `fin.EarlyWarningAlert` holds each warning issued, unique by
   (company, kind of date, reference, date, stage, readiness).
   - A date warns when it enters the lead time, then at 90, 30 and 7 days left.
   - Within a stage it warns again only when its readiness worsens from AMBER to RED. A RED date that improves to
     AMBER does not warn again in that stage, and a date that becomes GREEN stops warning.
   - After a stop of several days a run issues the current stage only, never the missed ones (DOC-F17 5.5).
   - A date that moves (a renewal agreed to a new expiry) starts again from its first stage.
5. **What it sends**: for each new warning, in the same transaction as the log row, a row `notification.requested` in
   `cfg.OutboxEvent` with the same MessageId (DOC-F17 6.1: Emit writes the outbox only). The payload carries
   identifiers only (FR-NTF-021):
   - the event code FIN.READINESS_WARNING, the company, and the assessment as the target of the link;
   - the kind of date, its reference, the date, the stage and the readiness;
   - the severity: HIGH for RED, WARNING for AMBER;
   - the dedup key `FIN.READINESS_WARNING:<kind>:<reference>:<stage>.<readiness>:<yyyymmdd of the date>` (BR-NTF-002).
   The notification builder resolves the recipients by the rules of the event (spec 13 section 9.2: TM, FO and FA,
   within the company scope) and their preferences.
6. **Who writes the log**: the database only. The application role reads it (the history of the warnings) and is
   denied INSERT, UPDATE and DELETE; the procedure writes through its ownership chain.

## Consequences

- One new table (249 in all), one job in the catalogue (33), one static script (051), and a dated function in 049
  that the view now reads.
- Test CA23 covers five cases:
  - a RED renewal in the lead time gives one warning and its request in the outbox;
  - a second run of the day issues nothing;
  - the eve and the day of a threshold give two stages, and only the current one is issued;
  - an AMBER covenant test that worsens to RED warns again in the same stage;
  - the refusals: a user binding, a run date that is not today, and a direct write by the application.
- Left to the application:
  - the worker that runs the job and records `cfg.JobRun`;
  - the notification builder, with the seed of the event type FIN.READINESS_WARNING in the tenant pack NTF.BASE, its
    rules and its templates in Arabic and English.
- The stages and the rules of readiness are a first calibration of this system, not a lender's; the treasury
  validates them with the rest.

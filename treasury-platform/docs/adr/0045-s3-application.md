# ADR 0045: Slice S3 of the application (requests, workflow and purchase letters of credit), its defaults and deviations

Status: being built since 2026-10-23, at the owner's request "continue the rest of the system at once". The
nineteen open questions of the S3 brief (OQ-1 to OQ-19) were built on their recommended defaults, **pending the
owner's approval** (docs/31, row 42). Written by an AI agent.

## Context

S3 is the workflow engine and the requests that run on it (specs 13), the facility services the engine calls
(spec 12), and the purchase letter of credit from its terms to its issuance, amendments, drawings, expiry and close
(spec 14). The brief counts 141 functional requirements (121 Must) in eight batches, A to H, and an exit of
AC-REQ-1, AC-WFL-3 and AC-LCI-1 (OQ-19).

## Decision

### 1. Batches

| Batch | Content | Commit |
|---|---|---|
| S3-A | 064 guards; settings; packs CORE.NUMBERING v3, CAT.LOOKUPS v3, CORE.EXPIRY v4, NTF.BASE v6, LC.BASE v1, WFL.BASE v1 and the WorkflowSeed installer; error map; outbox names; user department and line manager; AmountInWords | cf52673 to 0523edf |
| S3-B | The engine (submit, slots and SoD, tasks, return and resubmit, reject, cancel, close, claim, release), the two projections, the request API and screens | 5ebba67 |
| S3-D, E, F core | Terms store and V-LCT checks, fac.check_availability, fac.reserve_limit with the override, fac.convert_reservation, lc.record_issuance; AC-REQ-1 | aa614ce |
| S3-C, D | Delegations, reassignment, sub-statuses with the SLA pause, priority, the inbox; JOB-WFL-SLA, JOB-WFL-DELEGATION, JOB-NTF-REMIND, JOB-FAC-RESERVATION, JOB-WFL-STALE; AC-WFL-1 (delegation), AC-WFL-2, AC-WFL-3, AC-WFL-5, AC-WFL-10 | f63a30e |
| S3-F, G | The register and card of credits, presentations and payments, the close, JOB-LC-EXPIRY, JOB-LC-RECONCILE, the drawing-due alerts; amendments as child requests with fac.adjust_utilization and lc.apply_amendment | eaff077 |
| OQ-9 | At the reservation point, the user who chose the facility does not approve its reservation; docs/48, docs/31 row 42 | the documents commit |

### 2. The engine is C# (OQ-1)

The pure parts (template validation, conditions, transition choice, snapshots, amount in words, terms rules) are in
`BankFas.Core`; the moves are in `BankFas.Data/Workflow/RequestEngine`. The database keeps the guards of 044 and the
checks of models 15 and 16, and copies the current stage, assignee, due time, SLA state and reservation onto the
request (the app cannot write those columns). Every engine time is the session's `EngineNow`, so the order checks
of the stage instances hold within one action.

### 3. Delegation (FR-WFL-020, BR-WFL-021)

A delegate acts on a pending slot of the delegator: the delegator's own slot, or one assigned to a role of theirs,
when the delegator holds the decision's permission. The slot records `Source = DELEGATE`, `ActedByUserId` the delegate,
`OnBehalfOfUserId` and `DelegationId`; the action log records the same. A delegation is at most
`wfl.delegation.max_days`, starts today or later, never overlaps the delegator's other periods and never chains (the
delegate has no delegation in the period, and the engine uses only the delegator's own slots). The delegate never
acts on their own request, and an override is decided by the delegate's own permissions, so `fac.override_limit` is
never delegated. Revoking is immediate. The delegate sees the request and its notice while the delegation is in force.

### 4. SLA, escalation and reminders (BR-WFL-010, 012; BR-NTF-006)

- **One function for business hours.** `WorkingDays.AddBusinessHours`, and its inverse `BusinessHoursBetween`, serve
  the due times, the at-risk point, the pause and the reminders.
- **AT_RISK and OVERDUE.** A stage is AT_RISK when what is left to its due time is at most a fifth of its hours, and
  OVERDUE from the due time.
- **Notices and escalation.** Entering AT_RISK records SLA_AT_RISK and notifies once. Entering OVERDUE records
  SLA_BREACHED and notifies (the TM by the pack rule). An overdue stage is escalated again once a working day, from
  the opening of the day (ESCALATED).
- **The pause.** A sub-status with `pausesSla` (AT_BANK) pauses the clock. Leaving it moves the due time by the
  business hours of the pause and adds the pause to `SlaPausedSeconds`.
- **Reminders.** An action-required notice is reminded at 24, 48 and 72 business hours (three at most), only within
  working hours, and stops when the request moves on. Any move or claim resolves the request's open notices for
  everyone (FR-NTF-007).

### 5. Facility hooks and the life of the credit

- **The reservation and the override.** The reservation is the one service of S2. The override needs the tenant's
  setting, the approver's `fac.override_limit` and a reason; a refusal refuses the approval, so no slot is decided
  (AC-WFL-3).
- **Expiry of a reservation.** A reservation past `ExpiresOn` is released as EXPIRED by JOB-FAC-RESERVATION, and the
  request then reads LOST.
- **The utilisation follows the credit.** A payment lowers it by the amount paid. The close, and the expiry when
  `lc.auto_release_on_expiry` holds, release what is not drawn. At expiry the drawn-and-unpaid part is kept.
- **Reconciliation.** JOB-LC-RECONCILE compares the cached drawn and settled totals with the drawings, and the
  utilisation with the exposure less what is paid. It reports and corrects nothing.
- **Amendments (OQ-4, OQ-5).** An amendment is the child request LC_AMENDMENT on the credit:
  - It carries the credit's allocation. Its terms are a copy of the credit's ISSUED terms with the changes, locked at
    submission. AmountDelta is the change of the exposure with the plus tolerance.
  - An increase goes to the TM, whose approval reserves the delta on the credit's line (fac.adjust_utilization).
  - The bank's result is recorded on the result stage. Leaving that stage applies the amendment
    (lc.apply_amendment): a new ISSUED terms version, the new amount and dates, the bank's amendment number as
    `AmendmentNo` (OQ-4), and the utilisation moved by the delta. The reservation is superseded into the utilisation.
  - A beneficiary's refusal rejects the amendment and releases its reservation. A cancelled or rejected request
    withdraws its amendment.
  - One amendment is open at a time (`lc.amendment.max_open`, V-LCI-07).

### 6. Jobs and their cadence (OQ-12)

- **Every 5 minutes:** JOB-WFL-SLA.
- **Hourly:** JOB-WFL-DELEGATION, JOB-NTF-REMIND (working hours only), JOB-FAC-RESERVATION.
- **Daily**, after the S2-b order: JOB-WFL-STALE, then JOB-LC-EXPIRY before JOB-LC-RECONCILE.

The T-7 and T-1 alerts of a reservation, the credit's expiry and latest shipment, and the drawings' maturities are
providers of the expiry job: RESERVATION, LC_EXPIRY, LC_LATEST_SHIPMENT and LC_DRAWING_DUE.

## Deviations and what is still open

- **SoD at the TM's approval (OQ-9).** Built: the assignee of the last facility-selection stage (the stage with
  fac.check_availability) does not decide the reservation point, nor does a delegate acting for them, unless the
  template allows the same person (tagged). A TM creator's approval is refused, not rerouted to another TM or TA.
- **The response hash of a replayed action (OQ-10).** The replay is keyed by Idempotency-Key in `wfl.RequestAction`,
  but the response hash is not stored.
- **Not yet run.** At the owner's request the last batch's tests are written and compiled, not run: AC-FAC-12
  over HTTP (100 concurrent TM approvals of 100,000 on 4,000,000), the exit on DS-LC-C, the IBAN, print, bank form
  and dashboards test, and the S3 part of the browser test. AC-REQ-1, the drawn credit and the amendment changed with
  the receipt. They run in one CI cycle once the build is complete.
- **Bank form templates.** Written and activated through the API; no screen writes a template or its maps, and the
  form has no visual layout (the sheet lists each target's value).
- **DS-AGR C moved in time.** The S3 exit test loads agreement C with its dates moved by whole months so that it is
  in force on the run date; the file and its fingerprint do not change.

## Batches E and H (built after the first draft of this record)

- **Execution.** The assignee of the execution or issuance stage records the channel, the bank's reference and the
  receipt (a stored BANK_ACKNOWLEDGEMENT of the company). The conversion refuses without the receipt (V-LCI-RECEIPT)
  unless `lc.execution.require_receipt` is false.
- **Beneficiary IBAN.** Checked (country length, check digits), sealed with the tenant's DATA key with an AAD bound
  to the tenant and the column (not the row), so a copied terms version keeps the same sealed value; masked and
  blind-indexed. The reveal needs lc.view.internal and a reason; the reveal and each refusal are audited.
- **Printed terms (OQ-14).** Server-rendered HTML with its own Content-Security-Policy that allows its one style by
  hash. The UCP footnote cannot be switched off while any article in use is UNVERIFIED (V-LCT-UCP-FOOTNOTE, in the
  settings PATCH and in the page itself).
- **Bank forms.** Versioned templates with field maps from a fixed set of roots and transforms; the most specific
  active template (company 4, bank 2, product 1) is resolved per request; missing required targets make the sheet
  unofficial; the print is audited with the terms hash.
- **Dashboards.** Requester, officer and manager views, each gated by its permission.
- **DS-LC-C (OQ-13).** Two suppliers and four credits on C's documentary credit line, with the expected line figures.

# ADR 0031: The optional close of a company's reporting periods

Status: decided by the database architect on the owner's request of 2026-10-20 to build item 2 of the study of the
external review v4.0 (docs/38-review-v4-study.md section 9). Builds on ADR 0016 (statements and their versions) and
ADR 0030 (confirmed monthly figures).

## Context

Each approved object was already frozen:
- an approved statement changes only through a new version with its reason (045);
- a confirmed monthly balance or bank flow changes only through a reasoned reopening by someone other than its
  author (052).

What was missing is a close of the period as a whole. Once a company has closed its year, no new version and no
reopening of that year should be possible without a second, deliberate decision.

## Decision

1. **The close.** `fin.ReportingPeriodLock` holds, for a company, the day through which its periods are closed
   (`LockedThrough`), the reason, who closed it and when, and its reopening.
   - The current close of a company is its latest LOCKED row (`fin.fn_PeriodLockedThrough`, `fin.v_ReportingPeriodStatus`).
   - Closing is optional: a company that never closes is not affected.
2. **Closing** (`fin.usp_LockReportingPeriod`), by a holder of the new permission `fin.period.lock` (TM and FO in the
   role matrix of spec 12), with a reason. It is allowed only when:
   - every actual statement of the company dated through the day is approved or superseded;
   - every monthly balance and bank flow through that day is confirmed;
   - the day has passed and is later than the current close.
   Audited as PERIOD_LOCKED, high severity.
3. **What a close refuses** (50096), by triggers:
   - an actual statement dated through the closed day: a new one, a new version, or a change of status;
   - a monthly balance or bank flow dated through that day: insert, update (including the reopening of ADR 0030) or
     delete.
   A budget is a plan, not a figure of the period, and is not closed.
4. **Reopening** (`fin.usp_ReopenReportingPeriod`) applies to the latest close of the company only. It is done by
   another holder of `fin.period.lock`, not the one who closed it (a CHECK as well), with a reason. Audited as
   PERIOD_REOPENED, high severity. The rows are kept: a close is reopened, never deleted.
5. **The evidence pack** (052) says through which day the company is closed and whether the assessed statement's
   period is closed.
6. The application cannot write `fin.ReportingPeriodLock`; it reads the close through the view.

## Consequences

- One table (252 in all), one permission (144 in all), one static script (053) with three triggers, two procedures,
  a function and a view.
- Test CA31 has eight cases:
  - the close and its audit row, then a statement of the period refused;
  - a close refused while a draft remains;
  - a flow after the close accepted, and one inside it refused;
  - a reopening refused to the one who closed;
  - a reopening by another user, after which a statement is accepted;
  - a close refused without the permission;
  - a direct write by the application refused.

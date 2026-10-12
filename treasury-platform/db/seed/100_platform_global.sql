/* ============================================================================
   BankFas - 100: platform seed for global tables (DOC-B05 section 4)

   Safe to run again: each block is a MERGE on the natural key, so a second run changes nothing, and a changed
   platform value is updated in place. Runs as the deploying login (the global tables have no row filter).
   Today it holds the security setting definitions (DOC-S04 section 13, DQ-S04-14, owner decision 2026-10-12) and
   the background job catalogue (DOC-F17 section 5.2, DOC-F04 section 7.4).
   The ISO lists, plans, reserved sub-domains and permission codes of DOC-B05 section 4.1 follow with their slices.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
-- Security settings a tenant may tighten (FR-PLT-043, BR-PLT-018). Min and Max are the platform bounds: a tenant
-- value outside them is refused (028) and never used. "Enforced by" says who reads the value.
MERGE cfg.SettingDefinition AS d
USING (VALUES
    ('security.password.min_length',         'INT', N'12', N'10', N'64', N'Minimum password length after NFKC normalisation. Enforced by the application (BR-PLT-004).'),
    ('security.password.history_count',      'INT', N'5',  N'5',  N'24', N'A new password differs from this many last passwords, the current one included. Enforced by sec.usp_ApplyNewPassword (BR-PLT-004).'),
    ('security.lockout.threshold',           'INT', N'5',  N'3',  N'5',  N'Failed proofs of identity within 15 minutes that lock the account. Enforced by sec.usp_RecordAuthFailure (BR-PLT-005).'),
    ('security.session.idle_minutes',        'INT', N'30', N'5',  N'30', N'Idle timeout of a session. Enforced by sec.usp_StartSession and sec.usp_TouchSession (FR-PLT-014).'),
    ('security.session.absolute_hours',      'INT', N'12', N'1',  N'12', N'Absolute lifetime of a session. Enforced by sec.usp_StartSession (FR-PLT-014).'),
    ('security.stepup.freshness_minutes',    'INT', N'5',  N'1',  N'5',  N'How recent a step-up check must be for a sensitive action. Enforced by the application (DOC-S04).')
) AS s ([Key], ValueType, DefaultValueJson, MinValueJson, MaxValueJson, Description)
   ON d.[Key] = s.[Key]
WHEN MATCHED AND (d.ValueType <> s.ValueType OR d.DefaultValueJson <> s.DefaultValueJson
                  OR ISNULL(d.MinValueJson, N'') <> s.MinValueJson OR ISNULL(d.MaxValueJson, N'') <> s.MaxValueJson
                  OR d.IsSecurity <> 1 OR d.IsTenantEditable <> 1 OR ISNULL(d.Description, N'') <> s.Description) THEN
    UPDATE SET ValueType = s.ValueType, DefaultValueJson = s.DefaultValueJson, MinValueJson = s.MinValueJson,
               MaxValueJson = s.MaxValueJson, IsSecurity = 1, IsTenantEditable = 1, Description = s.Description,
               UpdatedAt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT ([Key], ModuleCode, ValueType, DefaultValueJson, MinValueJson, MaxValueJson, IsSecurity, IsTenantEditable, Description)
    VALUES (s.[Key], 'CORE', s.ValueType, s.DefaultValueJson, s.MinValueJson, s.MaxValueJson, 1, 1, s.Description);
GO
-- The closed list of background jobs (DOC-F17 section 5.2, DQ-F17-2). A TENANT job binds to one tenant through
-- sec.usp_SetJobContext, only in the statuses listed (DOC-F04 section 7.4; CLOSED means within 30 days of closing).
-- A PLATFORM job runs without a tenant binding. Keys outside this list are refused.
MERGE cfg.JobDefinition AS d
USING (VALUES
    ('JOB-PLT-OUTBOX', 'TENANT', 'TRIAL,ACTIVE', N'Delivers cfg.OutboxEvent (DOC-F17 4).'),
    ('JOB-NTF-DISPATCH', 'TENANT', 'TRIAL,ACTIVE', N'Delivers ntf.NotificationDelivery (DOC-F17 6.5).'),
    ('JOB-WFL-SLA', 'TENANT', 'TRIAL,ACTIVE', N'SLA states and AT_RISK and BREACHED events, every 5 minutes.'),
    ('JOB-WFL-ASSIGN', 'TENANT', 'TRIAL,ACTIVE', N'Resolves assignments again, on events and hourly.'),
    ('JOB-WFL-DELEGATION', 'TENANT', 'TRIAL,ACTIVE', N'Delegation states, hourly and at midnight.'),
    ('JOB-WFL-STALE', 'TENANT', 'TRIAL,ACTIVE', N'Idle drafts and old reservations, 06:00.'),
    ('JOB-NTF-EXPIRY', 'TENANT', 'TRIAL,ACTIVE', N'Expiry providers and threshold events, 05:30 (FR-PLT-038).'),
    ('JOB-NTF-REMIND', 'TENANT', 'TRIAL,ACTIVE', N'Reminders of required actions, hourly in working hours.'),
    ('JOB-NTF-DIGEST', 'TENANT', 'TRIAL,ACTIVE', N'Digests, daily 07:30 and weekly on Sunday.'),
    ('JOB-NTF-RETENTION', 'TENANT', 'TRIAL,ACTIVE', N'Archives read notifications after 180 days, weekly.'),
    ('JOB-FAC-VALIDITY', 'TENANT', 'TRIAL,ACTIVE', N'Facility validity indicator, daily.'),
    ('JOB-FAC-RESERVATION', 'TENANT', 'TRIAL,ACTIVE', N'Reservation expiry and T-7 and T-1 alerts, hourly.'),
    ('JOB-OBL-CALENDAR', 'TENANT', 'TRIAL,ACTIVE', N'Obligation calendar items, nightly.'),
    ('JOB-FIN-EVAL', 'TENANT', 'TRIAL,ACTIVE', N'Financial statement evaluation, nightly.'),
    ('JOB-COL-DUE', 'TENANT', 'TRIAL,ACTIVE', N'Collateral due items, nightly.'),
    ('JOB-CMP-SYNC', 'TENANT', 'TRIAL,ACTIVE', N'Comparison projection sync, nightly.'),
    ('JOB-ACC-EXPIRY', 'TENANT', 'TRIAL,ACTIVE', N'Signatory expiry, daily.'),
    ('JOB-ACC-GOV', 'TENANT', 'TRIAL,ACTIVE', N'Governance checks, daily.'),
    ('JOB-CAT-STALE', 'TENANT', 'TRIAL,ACTIVE', N'Stale base rates, daily.'),
    ('JOB-LC-RECONCILE', 'TENANT', 'TRIAL,ACTIVE', N'Letters of credit reconciliation, 02:00.'),
    ('JOB-LC-EXPIRY', 'TENANT', 'TRIAL,ACTIVE', N'Letters of credit ACTIVE to EXPIRED and release of the undrawn part, 05:45.'),
    ('JOB-LC-MATURITY', 'TENANT', 'TRIAL,ACTIVE', N'Letters of credit maturities, 06:15.'),
    ('JOB-LCE-NOLC', 'TENANT', 'TRIAL,ACTIVE', N'Proformas without a letter of credit, 06:30.'),
    ('JOB-PLT-OUTBOX-PURGE', 'TENANT', 'TRIAL,ACTIVE', N'Deletes delivered outbox events after 30 days, weekly.'),
    ('JOB-PLT-JOBRUN-PURGE', 'TENANT', 'TRIAL,ACTIVE', N'Deletes job runs after 90 days, weekly.'),
    ('JOB-PLT-TRIAL-REMIND', 'TENANT', 'TRIAL', N'Trial end reminders 7, 3 and 1 days before (DOC-F05 6.3).'),
    ('JOB-PLT-EXPORT-EXPIRE', 'TENANT', 'TRIAL,ACTIVE,SUSPENDED,CLOSED', N'READY export packages to EXPIRED and the file deleted (DOC-F05 6.3).'),
    ('JOB-PLT-TRIAL-EXPIRE', 'PLATFORM', NULL, N'TRIAL to SUSPENDED when the trial ends, through plat.usp_SetTenantStatus (DOC-F05 6.3).'),
    ('JOB-PLT-ARCHIVE', 'PLATFORM', NULL, N'CLOSED to ARCHIVED_READ_ONLY 30 days after ClosedAt, through plat.usp_SetTenantStatus (DOC-F05 6.3).')
) AS s (JobKey, Scope, RunsInStatuses, Description)
   ON d.JobKey = s.JobKey
WHEN MATCHED AND (d.Scope <> s.Scope OR ISNULL(d.RunsInStatuses, '') <> ISNULL(s.RunsInStatuses, '')
                  OR ISNULL(d.Description, N'') <> s.Description) THEN
    UPDATE SET Scope = s.Scope, RunsInStatuses = s.RunsInStatuses, Description = s.Description, UpdatedAt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (JobKey, Scope, RunsInStatuses, Description) VALUES (s.JobKey, s.Scope, s.RunsInStatuses, s.Description);
GO

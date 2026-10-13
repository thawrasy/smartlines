/* ============================================================================
   BankFas - 100: platform seed for global tables (DOC-B05 section 4)

   Safe to run again: each block is a MERGE on the natural key, so a second run changes nothing, and a changed
   platform value is updated in place. Runs as the deploying login (the global tables have no row filter).
   Today it holds the setting definitions (DOC-S04 section 13, DQ-S04-14; the working day and re-mask timeout, DR-17), the background job catalogue
   (DOC-F17 section 5.2, DOC-F04 section 7.4), the STANDARD plan (DQ-B05-4) and the reserved sub-domains (FR-PLT-046),
   all owner decisions of 2026-10-12 or their proposals. The ISO lists (101, DQ-B05-5), the permission codes (102)
   and the letter-of-credit reference data (103) of DOC-B05 section 4.1 are in their own files.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
-- Settings a tenant may set within the platform bounds (FR-PLT-043, BR-PLT-018). Min and Max are the bounds: a
-- tenant value outside them is refused (028) and never used, and a key not defined here is refused too (DR-17).
-- "Enforced by" says who reads the value. work.end minus work.start is 4 to 12 hours (028).
MERGE cfg.SettingDefinition AS d
USING (VALUES
    ('security.password.min_length',         'INT', N'12', N'10', N'64', 1, N'Minimum password length after NFKC normalisation. Enforced by the application (BR-PLT-004).'),
    ('security.password.history_count',      'INT', N'5',  N'5',  N'24', 1, N'A new password differs from this many last passwords, the current one included. Enforced by sec.usp_ApplyNewPassword (BR-PLT-004).'),
    ('security.lockout.threshold',           'INT', N'5',  N'3',  N'5',  1, N'Failed proofs of identity within 15 minutes that lock the account. Enforced by sec.usp_RecordAuthFailure (BR-PLT-005).'),
    ('security.session.idle_minutes',        'INT', N'30', N'5',  N'30', 1, N'Idle timeout of a session. Enforced by sec.usp_StartSession and sec.usp_TouchSession (FR-PLT-014).'),
    ('security.session.absolute_hours',      'INT', N'12', N'1',  N'12', 1, N'Absolute lifetime of a session. Enforced by sec.usp_StartSession (FR-PLT-014).'),
    ('security.stepup.freshness_minutes',    'INT', N'5',  N'1',  N'5',  1, N'How recent a step-up check must be for a sensitive action. Enforced by the application (DOC-S04).'),
    ('security.reveal.remask_seconds',       'INT', N'60', N'15', N'300', 1, N'Seconds a revealed identity number stays visible before it is masked again. Enforced by the application (BR-PTY-009, AC-PLT-19).'),
    ('work.start',                           'TIME', N'"08:00"', NULL, NULL, 0, N'Start of the working day in the tenant time zone, for AddBusinessHours (BR-PLT-014, BR-PLT-018).'),
    ('work.end',                             'TIME', N'"17:00"', NULL, NULL, 0, N'End of the working day in the tenant time zone; 4 to 12 hours after work.start (BR-PLT-018).')
) AS s ([Key], ValueType, DefaultValueJson, MinValueJson, MaxValueJson, IsSecurity, Description)
   ON d.[Key] = s.[Key]
WHEN MATCHED AND (d.ValueType <> s.ValueType OR d.DefaultValueJson <> s.DefaultValueJson
                  OR ISNULL(d.MinValueJson, N'') <> ISNULL(s.MinValueJson, N'') OR ISNULL(d.MaxValueJson, N'') <> ISNULL(s.MaxValueJson, N'')
                  OR d.IsSecurity <> s.IsSecurity OR d.IsTenantEditable <> 1 OR ISNULL(d.Description, N'') <> s.Description) THEN
    UPDATE SET ValueType = s.ValueType, DefaultValueJson = s.DefaultValueJson, MinValueJson = s.MinValueJson,
               MaxValueJson = s.MaxValueJson, IsSecurity = s.IsSecurity, IsTenantEditable = 1, Description = s.Description,
               UpdatedAt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT ([Key], ModuleCode, ValueType, DefaultValueJson, MinValueJson, MaxValueJson, IsSecurity, IsTenantEditable, Description)
    VALUES (s.[Key], 'CORE', s.ValueType, s.DefaultValueJson, s.MinValueJson, s.MaxValueJson, s.IsSecurity, 1, s.Description);
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
    ('JOB-PLT-RECONCILE', 'TENANT', 'TRIAL,ACTIVE', N'Reads wfl.RequestCopyDrift and lc.ProformaTotalsDrift, nightly; a row is an incident (DR-44, DR-41).'),
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
    ('JOB-PLT-ONBOARD', 'TENANT', 'TRIAL,ACTIVE', N'Seeds a new tenant and invites its first administrator, woken by tenant.created (DOC-F05 4.3).'),
    ('JOB-PLT-EXPORT-EXPIRE', 'TENANT', 'TRIAL,ACTIVE,SUSPENDED,CLOSED', N'READY export packages to EXPIRED and the file deleted (DOC-F05 6.3).'),
    ('JOB-PLT-EXPORT', 'TENANT', 'TRIAL,ACTIVE,SUSPENDED,CLOSED', N'Builds approved tenant data exports into sealed packages (FR-PLT-039, DQ-F04-8, 042).'),
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
-- One plan with every module and no limits (DQ-B05-4, owner decision 2026-10-12).
MERGE plat.[Plan] AS d
USING (VALUES ('STANDARD', N'الباقة القياسية', N'Standard')) AS s (Code, NameAr, NameEn)
   ON d.Code = s.Code
WHEN NOT MATCHED THEN INSERT (Code, NameAr, NameEn, IsActive) VALUES (s.Code, s.NameAr, s.NameEn, 1);
MERGE plat.PlanModule AS d
USING (SELECT p.PlanId, m.ModuleCode
       FROM plat.[Plan] AS p
       CROSS JOIN (VALUES ('CORE'), ('INSTITUTIONS'), ('FACILITIES'), ('COVENANTS'), ('WORKFLOW'), ('LC_PURCHASE'),
                          ('LC_SALES'), ('REQUESTS'), ('REPORTS')) AS m (ModuleCode)
       WHERE p.Code = 'STANDARD') AS s
   ON d.PlanId = s.PlanId AND d.ModuleCode = s.ModuleCode
WHEN NOT MATCHED THEN INSERT (PlanId, ModuleCode) VALUES (s.PlanId, s.ModuleCode);
GO
-- Sub-domains no tenant may take (FR-PLT-046): the four the requirement names and the hosts the platform uses or
-- may use. plat.usp_CreateTenant refuses them (50025). The list is a proposal for OPS with SEC (DOC-B05 4.1).
MERGE plat.ReservedSubdomain AS d
USING (VALUES ('www', N'FR-PLT-046'), ('admin', N'FR-PLT-046'), ('api', N'FR-PLT-046'), ('app', N'FR-PLT-046'),
              ('operator', N'Operator panel host (DOC-S03)'), ('ops', N'Operations'), ('support', N'Support'),
              ('auth', N'Identity'), ('login', N'Identity'), ('sso', N'Identity'), ('mail', N'E-mail'), ('smtp', N'E-mail'),
              ('status', N'Status page'), ('static', N'Static files'), ('cdn', N'Static files'), ('docs', N'Documentation'),
              ('help', N'Help'), ('dev', N'Environment'), ('test', N'Environment'), ('uat', N'Environment'),
              ('staging', N'Environment'), ('demo', N'Environment'), ('bankfas', N'Product name')) AS s (Subdomain, Reason)
   ON d.Subdomain = s.Subdomain
WHEN NOT MATCHED THEN INSERT (Subdomain, Reason) VALUES (s.Subdomain, s.Reason);
GO

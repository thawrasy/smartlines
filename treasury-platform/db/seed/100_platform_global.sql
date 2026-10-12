/* ============================================================================
   BankFas - 100: platform seed for global tables (DOC-B05 section 4)

   Safe to run again: each block is a MERGE on the natural key, so a second run changes nothing, and a changed
   platform value is updated in place. Runs as the deploying login (the global tables have no row filter).
   Today it holds the security setting definitions (DOC-S04 section 13, DQ-S04-14, owner decision 2026-10-12).
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

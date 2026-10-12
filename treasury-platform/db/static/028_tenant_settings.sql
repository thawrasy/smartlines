/* ============================================================================
   BankFas - 028: tenant settings within the platform bounds (FR-PLT-043, BR-PLT-018, DQ-S03-6, DQ-S04-14)

   cfg.SettingDefinition (global, seeded by db/seed/100_platform_global.sql) gives each key its default and its
   platform bounds; cfg.TenantSetting holds a tenant's own value. Two guards:
     cfg.fn_SettingInt              the value the procedures use: the tenant's, held within the bounds, else the
                                    default. Used by 030 and 035 for the session timeouts, the lockout threshold and
                                    the password history.
     cfg.TR_TenantSetting_Bounds    refuses a tenant value outside the bounds, a value of the wrong type, a key the
                                    tenant may not edit, and an undefined security.* key (50020).
   Values are JSON scalars, for example 15 or "08:00" (the JSON checks accept scalars, tools/dbgen/dbgen.py).
   Auditing a security change with the old and new value (BR-PLT-018) stays with the application, which writes the
   chained audit log (FR-PLT-022).
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
/* A tenant's value of an integer setting. A tenant value outside the bounds (written before the bounds changed) is
   held at the nearest bound. Without a definition (platform seed not run) only @Fallback is used, so a tenant row
   cannot loosen a limit nobody has bounded. Values are JSON scalars (15 or "15"). */
CREATE OR ALTER FUNCTION cfg.fn_SettingInt (@TenantId INT, @Key VARCHAR(100), @Fallback INT)
RETURNS TABLE
AS RETURN
    SELECT COALESCE(CASE WHEN d.DefKey IS NULL THEN NULL
                         WHEN t.Val IS NULL THEN d.Def
                         WHEN d.MinV IS NOT NULL AND t.Val < d.MinV THEN d.MinV
                         WHEN d.MaxV IS NOT NULL AND t.Val > d.MaxV THEN d.MaxV
                         ELSE t.Val END, @Fallback) AS Value
    FROM (SELECT 1 AS One) AS o
    OUTER APPLY (SELECT sd.[Key] AS DefKey,
                        TRY_CAST(JSON_VALUE(N'[' + sd.DefaultValueJson + N']', '$[0]') AS INT) AS Def,
                        TRY_CAST(JSON_VALUE(N'[' + sd.MinValueJson + N']', '$[0]') AS INT) AS MinV,
                        TRY_CAST(JSON_VALUE(N'[' + sd.MaxValueJson + N']', '$[0]') AS INT) AS MaxV
                 FROM cfg.SettingDefinition AS sd
                 WHERE sd.[Key] = @Key AND sd.ValueType = 'INT') AS d
    OUTER APPLY (SELECT TRY_CAST(JSON_VALUE(N'[' + ts.ValueJson + N']', '$[0]') AS INT) AS Val
                 FROM cfg.TenantSetting AS ts
                 WHERE ts.TenantId = @TenantId AND ts.[Key] = @Key) AS t;
GO
-- An error raised in a trigger ends the caller's transaction; the application validates first and shows the bounds.
CREATE OR ALTER TRIGGER cfg.TR_TenantSetting_Bounds ON cfg.TenantSetting
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM inserted AS i
               LEFT JOIN cfg.SettingDefinition AS d ON d.[Key] = i.[Key]
               CROSS APPLY (SELECT TRY_CAST(JSON_VALUE(N'[' + i.ValueJson + N']', '$[0]') AS INT) AS Val) AS v
               WHERE (d.[Key] IS NULL AND i.[Key] LIKE 'security.%')
                  OR d.IsTenantEditable = 0
                  OR (d.ValueType = 'INT'
                      AND (v.Val IS NULL
                           OR v.Val < TRY_CAST(JSON_VALUE(N'[' + d.MinValueJson + N']', '$[0]') AS INT)
                           OR v.Val > TRY_CAST(JSON_VALUE(N'[' + d.MaxValueJson + N']', '$[0]') AS INT))))
        THROW 50020, 'Setting value outside the platform bounds, of the wrong type, or not editable by the tenant (BR-PLT-018)', 1;
END;
GO

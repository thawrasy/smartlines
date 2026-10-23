/* 063_s2b_guards.sql — what an approved formula and a system statement line keep is kept in the database, not only in
   the application (S2-b brief S2B-GAP-10, S2B-GAP-11; FR-FIN-001, FR-FIN-011).

     formulas      an APPROVED fin.MeasureFormula changes only to SUPERSEDED, and a SUPERSEDED one is final: a covenant
                   test names the formula version it used (044) and stores its id and version, not its expression, so an
                   edit in place would rewrite the meaning of past tests. A change is a new version. The trigger is
                   built from sys.columns, so a column added later is frozen too. Error 50176.
     line items    fin.LineCatalogItem is a tenant catalogue outside the cat schema, so 060 does not cover it: tp_app may
                   not change Code, Section, IsTotal, TotalFormula, IsSystem, IsLocked or SeedKey (the totals, the
                   formulas and the credit engine's join by Code, 047, read them), and a system or locked line comes
                   only from the seeder (50174, as in 060 and 062). The tenant names, orders and deactivates the lines
                   that are not locked, and adds its own. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
DECLARE @ci NVARCHAR(MAX), @cd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @ci = STRING_AGG(N'i.' + QUOTENAME(name), N', ') WITHIN GROUP (ORDER BY column_id),
       @cd = STRING_AGG(N'd.' + QUOTENAME(name), N', ') WITHIN GROUP (ORDER BY column_id)
  FROM sys.columns
 WHERE object_id = OBJECT_ID(N'fin.MeasureFormula') AND is_computed = 0 AND system_type_id <> 189   -- not the row version
   AND name NOT IN (N'Status', N'UpdatedAt', N'UpdatedBy');
SET @sql = N'CREATE OR ALTER TRIGGER fin.TR_MeasureFormula_Final ON fin.MeasureFormula
AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d
               JOIN inserted AS i ON i.TenantId = d.TenantId AND i.MeasureFormulaId = d.MeasureFormulaId
               WHERE d.Status IN (''APPROVED'', ''SUPERSEDED'')
                 AND (NOT (i.Status = d.Status OR (d.Status = ''APPROVED'' AND i.Status = ''SUPERSEDED''))
                      OR EXISTS (SELECT ' + @ci + N' EXCEPT SELECT ' + @cd + N')))
        THROW 50176, ''An approved formula is fixed: a change is a new version, and the approved one is superseded (FR-FIN-011)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
DENY UPDATE (Code, Section, IsTotal, TotalFormula, IsSystem, IsLocked, SeedKey) ON fin.LineCatalogItem TO [tp_app];
GO
CREATE OR ALTER TRIGGER fin.TR_LineCatalogItem_SeedRows ON fin.LineCatalogItem
AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted WHERE IsSystem = 1 OR IsLocked = 1) RETURN;
    IF ISNULL(CAST(SESSION_CONTEXT(N'JobKey') AS VARCHAR(80)), '') = 'JOB-PLT-ONBOARD'
       AND EXISTS (SELECT 1 FROM sec.SessionBinding WHERE SessionId = @@SPID AND BindingKind = 'JOB') RETURN;
    IF IS_ROLEMEMBER(N'tp_app') = 0 AND IS_MEMBER(N'db_owner') = 1 RETURN;   -- the deployment and its tests
    THROW 50174, 'A system or locked statement line comes only from the seed packs', 1;
END;
GO

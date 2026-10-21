/* 060_catalog_guards.sql — what protects the tenant catalogues is in the database, not only in the application
   (FR-CAT-001, FR-CAT-004, FR-CAT-020; S1 brief S1-GAP-10).

   The catalogues (cat.*) are the tenant's own copy of the seed packs (FR-CAT-002), which the tenant administrator
   edits through the application (tp_app). Here:
     column DENYs      on every cat.* table with them, tp_app may not change Code ("a fixed code", FR-CAT-001),
                       IsSystem, IsLocked or SeedKey, nor Scope and AllowTenantItems of a lookup list. So a system row stays a
                       system row, a locked row stays locked and, by the CHECK "locked => system and active", active;
                       and the seed's key of a row stays the one the seeder matches on (insert only).
     system rows       a row inserted as IsSystem = 1 or IsLocked = 1 comes only from the seeder, bound as the
                       onboarding job JOB-PLT-ONBOARD (the application's TenantSeeder, which also runs the UPGRADE of
                       the packs); the application cannot add one (50174). One trigger per table, built from
                       sys.columns, so a catalogue added later is covered when this script runs again.
     closed lists      an item of a system lookup list whose AllowTenantItems = 0 comes only from the seeder too (50174,
                       FR-CAT-020: "adding an item to a global list is refused").
   tp_app has no DELETE on the catalogues (FR-CAT-004: deactivate, never delete; 005). Errors: 50174. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
-- the column DENYs
DECLARE @sql NVARCHAR(MAX) = N'';
SELECT @sql += N'DENY UPDATE (' + STRING_AGG(QUOTENAME(c.name), N', ') WITHIN GROUP (ORDER BY c.name) + N') ON '
             + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N' TO [tp_app];' + CHAR(10)
  FROM sys.tables AS t
  JOIN sys.schemas AS s ON s.schema_id = t.schema_id AND s.name = N'cat'
  JOIN sys.columns AS c ON c.object_id = t.object_id AND c.name IN (N'Code', N'IsSystem', N'IsLocked', N'SeedKey', N'AllowTenantItems')
 GROUP BY s.name, t.name;
EXEC sys.sp_executesql @sql;
DENY UPDATE (Scope) ON cat.LookupList TO [tp_app];
GO
-- one trigger per catalogue with IsSystem: system and locked rows come from the seeder only
DECLARE @t SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.name FROM sys.tables AS t
      JOIN sys.schemas AS s ON s.schema_id = t.schema_id AND s.name = N'cat'
     WHERE EXISTS (SELECT 1 FROM sys.columns WHERE object_id = t.object_id AND name = N'IsSystem')
       AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = t.object_id AND name = N'IsLocked');
OPEN c; FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'CREATE OR ALTER TRIGGER cat.' + QUOTENAME(N'TR_' + @t + N'_SeedRows') + N' ON cat.' + QUOTENAME(@t) + N'
AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted WHERE IsSystem = 1 OR IsLocked = 1) RETURN;
    IF ISNULL(CAST(SESSION_CONTEXT(N''JobKey'') AS VARCHAR(80)), '''') = ''JOB-PLT-ONBOARD''
       AND EXISTS (SELECT 1 FROM sec.SessionBinding WHERE SessionId = @@SPID AND BindingKind = ''JOB'') RETURN;
    IF IS_ROLEMEMBER(N''tp_app'') = 0 AND IS_MEMBER(N''db_owner'') = 1 RETURN;   -- the deployment and its tests
    THROW 50174, ''A system or locked catalogue row comes only from the seed packs'', 1;
END;';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM c INTO @t;
END;
CLOSE c; DEALLOCATE c;
GO
CREATE OR ALTER TRIGGER cat.TR_LookupItem_ClosedList ON cat.LookupItem
AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted AS i JOIN cat.LookupList AS l ON l.LookupListId = i.LookupListId WHERE l.IsSystem = 1 AND l.AllowTenantItems = 0) RETURN;
    IF ISNULL(CAST(SESSION_CONTEXT(N'JobKey') AS VARCHAR(80)), '') = 'JOB-PLT-ONBOARD'
       AND EXISTS (SELECT 1 FROM sec.SessionBinding WHERE SessionId = @@SPID AND BindingKind = 'JOB') RETURN;
    IF IS_ROLEMEMBER(N'tp_app') = 0 AND IS_MEMBER(N'db_owner') = 1 RETURN;   -- the deployment and its tests
    THROW 50174, 'Items of this list come only from the seed packs', 1;
END;
GO

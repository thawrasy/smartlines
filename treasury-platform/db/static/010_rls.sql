/* ============================================================================
   BankFas - 010: row-level security (tenant isolation)
   Runs after the generated scripts 000..005, in the same session that created #rls_tables (see deploy.sql).

   A row of a tenant-owned table is visible or writable only when BOTH hold:
     1. its TenantId equals SESSION_CONTEXT(N'TenantId'), and
     2. this connection is bound to that tenant: sec.SessionBinding has a row for @@SPID whose BoundTenantId
        equals the row's TenantId and whose BindingToken equals SESSION_CONTEXT(N'BindingToken').
   Only sec.usp_SetSessionContext (030) writes the binding and the token. A caller that sets
   SESSION_CONTEXT itself, or reuses a stale binding, gets no rows (O-16).
   Members of tp_platform bypass the filters for platform work. tp_auth bypasses them only inside the
   context procedure, to check membership before the binding exists.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- policies and procedures keep these options when created
GO
IF SCHEMA_ID(N'rls') IS NULL EXEC(N'CREATE SCHEMA [rls] AUTHORIZATION dbo;');
GO
GRANT SELECT ON SCHEMA::[rls] TO [tp_app];   -- predicate functions: the query engine evaluates them in the caller's context
GO
-- Is the current connection bound to @TenantId? Used by every predicate below.
CREATE OR ALTER FUNCTION rls.fn_Bound (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS Bound
    WHERE EXISTS (SELECT 1
                  FROM sec.SessionBinding AS b
                  WHERE b.SessionId = @@SPID
                    AND b.BoundTenantId = @TenantId
                    AND @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT)
                    AND b.BindingToken = CAST(SESSION_CONTEXT(N'BindingToken') AS UNIQUEIDENTIFIER));
GO
-- Write check: the binding, and the tenant is open for writes (TRIAL or ACTIVE, BR-PLT-002).
-- SUSPENDED and ARCHIVED_READ_ONLY tenants keep reading; CLOSED tenants cannot bind (030).
CREATE OR ALTER FUNCTION rls.fn_BoundWrite (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS BoundWrite
    WHERE EXISTS (SELECT 1 FROM rls.fn_Bound(@TenantId))
      AND EXISTS (SELECT 1 FROM plat.Tenant AS t
                  WHERE t.TenantId = @TenantId AND t.Status IN (N'TRIAL', N'ACTIVE'));
GO
-- Block predicates of tenant-owned tables: writes need the write check (tp_platform and tp_auth bypass it)
CREATE OR ALTER FUNCTION rls.fn_TenantWrite (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1
       OR EXISTS (SELECT 1 FROM rls.fn_BoundWrite(@TenantId));
GO
-- Tenant-owned tables: a connection sees and changes only the rows of its bound tenant
CREATE OR ALTER FUNCTION rls.fn_TenantAccess (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1
       OR EXISTS (SELECT 1 FROM rls.fn_Bound(@TenantId));
GO
-- Mixed-scope tables: every connection reads the platform rows (TenantId NULL) and its own rows
CREATE OR ALTER FUNCTION rls.fn_MixedRead (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE @TenantId IS NULL
       OR IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1
       OR EXISTS (SELECT 1 FROM rls.fn_Bound(@TenantId));
GO
-- Mixed-scope tables: writes reach only the bound tenant's rows (with the write check); platform rows belong to tp_platform
CREATE OR ALTER FUNCTION rls.fn_MixedWrite (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1
       OR EXISTS (SELECT 1 FROM rls.fn_BoundWrite(@TenantId));
GO
-- Audit log aud.AuditLog: its own policy (BR-PLT-001, BR-PLT-009)
--   Read: a tenant reads its own rows; rows with TenantId NULL (platform events) are for tp_platform only.
--   Write (insert only): the tenant's own TenantId or NULL for a platform event; no update and no delete (DENY in 005/020).
CREATE OR ALTER FUNCTION rls.fn_AuditRead (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1
       OR EXISTS (SELECT 1 FROM rls.fn_Bound(@TenantId));
GO
CREATE OR ALTER FUNCTION rls.fn_AuditWrite (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE @TenantId IS NULL
       OR IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1
       OR EXISTS (SELECT 1 FROM rls.fn_Bound(@TenantId));
GO
IF EXISTS (SELECT 1 FROM sys.security_policies sp WHERE sp.name = N'TP_aud_AuditLog' AND sp.schema_id = SCHEMA_ID(N'rls'))
    DROP SECURITY POLICY rls.[TP_aud_AuditLog];
GO
CREATE SECURITY POLICY rls.[TP_aud_AuditLog]
    ADD FILTER PREDICATE rls.fn_AuditRead(TenantId) ON [aud].[AuditLog],
    ADD BLOCK  PREDICATE rls.fn_AuditWrite(TenantId) ON [aud].[AuditLog] AFTER INSERT
    WITH (STATE = ON);
GO
DECLARE @s sysname, @t sysname, @m bit, @pol sysname, @obj nvarchar(300), @sql nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT SchemaName, TableName, IsMixed FROM #rls_tables
    WHERE NOT (SchemaName = N'aud' AND TableName = N'AuditLog');   -- has its own policy above
OPEN c; FETCH NEXT FROM c INTO @s, @t, @m;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @pol = N'TP_' + @s + N'_' + @t;
    SET @obj = QUOTENAME(@s) + N'.' + QUOTENAME(@t);
    IF EXISTS (SELECT 1 FROM sys.security_policies sp WHERE sp.name = @pol AND sp.schema_id = SCHEMA_ID(N'rls'))
    BEGIN
        DECLARE @dsql nvarchar(400) = N'DROP SECURITY POLICY rls.' + N'[' + @pol + N']';
        EXEC (@dsql);
    END
    IF @m = 0
        SET @sql = N'CREATE SECURITY POLICY rls.[' + @pol + N'] '
                 + N'ADD FILTER PREDICATE rls.fn_TenantAccess(TenantId) ON ' + @obj + N', '
                 + N'ADD BLOCK PREDICATE rls.fn_TenantWrite(TenantId) ON ' + @obj + N' AFTER INSERT, '
                 + N'ADD BLOCK PREDICATE rls.fn_TenantWrite(TenantId) ON ' + @obj + N' AFTER UPDATE, '
                 + N'ADD BLOCK PREDICATE rls.fn_TenantWrite(TenantId) ON ' + @obj + N' BEFORE DELETE '
                 + N'WITH (STATE = ON);';
    ELSE
        SET @sql = N'CREATE SECURITY POLICY rls.[' + @pol + N'] '
                 + N'ADD FILTER PREDICATE rls.fn_MixedRead(TenantId) ON ' + @obj + N', '
                 + N'ADD BLOCK PREDICATE rls.fn_MixedWrite(TenantId) ON ' + @obj + N' AFTER INSERT, '
                 + N'ADD BLOCK PREDICATE rls.fn_MixedWrite(TenantId) ON ' + @obj + N' BEFORE UPDATE, '
                 + N'ADD BLOCK PREDICATE rls.fn_MixedWrite(TenantId) ON ' + @obj + N' AFTER UPDATE, '
                 + N'ADD BLOCK PREDICATE rls.fn_MixedWrite(TenantId) ON ' + @obj + N' BEFORE DELETE '
                 + N'WITH (STATE = ON);';
    EXEC(@sql);
    FETCH NEXT FROM c INTO @s, @t, @m;
END
CLOSE c; DEALLOCATE c;
GO

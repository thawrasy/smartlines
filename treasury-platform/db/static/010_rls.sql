/* ============================================================================
   BankFas - 010: عزل الصفوف بين المشتركين (Row-Level Security)
   يُنفَّذ بعد 000..005 المولَّدة، وفي الجلسة نفسها التي أنشأت #rls_tables (انظر deploy.sql).
   المبدأ: كل جدول مملوك للمشترك يُرشَّح بـ TenantId = SESSION_CONTEXT('TenantId').
           أعضاء دور tp_platform (المشغّل) يتجاوزون العزل لأعمال المنصة فقط.
   ============================================================================ */
SET NOCOUNT ON;
GO
IF SCHEMA_ID(N'rls') IS NULL EXEC(N'CREATE SCHEMA [rls] AUTHORIZATION dbo;');
GO
-- جداول المشترك العادية: لا ترى إلا صفوف مشتركها
CREATE OR ALTER FUNCTION rls.fn_TenantAccess (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT)
       OR IS_MEMBER(N'tp_platform') = 1;
GO
-- الجداول المختلطة النطاق: القراءة لصفوف المنصة (TenantId NULL) وصفوف المشترك
CREATE OR ALTER FUNCTION rls.fn_MixedRead (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE @TenantId IS NULL
       OR @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT)
       OR IS_MEMBER(N'tp_platform') = 1;
GO
-- ... أما الكتابة فلصفوف المشترك نفسه فقط؛ صفوف المنصة لأعضاء tp_platform
CREATE OR ALTER FUNCTION rls.fn_MixedWrite (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE (@TenantId IS NOT NULL AND @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT))
       OR IS_MEMBER(N'tp_platform') = 1;
GO
DECLARE @s sysname, @t sysname, @m bit, @pol sysname, @obj nvarchar(300), @sql nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT SchemaName, TableName, IsMixed FROM #rls_tables;
OPEN c; FETCH NEXT FROM c INTO @s, @t, @m;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @pol = N'TP_' + @s + N'_' + @t;
    SET @obj = QUOTENAME(@s) + N'.' + QUOTENAME(@t);
    IF EXISTS (SELECT 1 FROM sys.security_policies sp WHERE sp.name = @pol AND sp.schema_id = SCHEMA_ID(N'rls'))
        EXEC(N'DROP SECURITY POLICY rls.' + N'[' + @pol + N']');
    IF @m = 0
        SET @sql = N'CREATE SECURITY POLICY rls.[' + @pol + N'] '
                 + N'ADD FILTER PREDICATE rls.fn_TenantAccess(TenantId) ON ' + @obj + N', '
                 + N'ADD BLOCK PREDICATE rls.fn_TenantAccess(TenantId) ON ' + @obj + N' AFTER INSERT, '
                 + N'ADD BLOCK PREDICATE rls.fn_TenantAccess(TenantId) ON ' + @obj + N' AFTER UPDATE '
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

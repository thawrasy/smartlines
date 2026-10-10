/* ============================================================================
   BankFas - 010: عزل الصفوف بين المشتركين (Row-Level Security)
   يُنفَّذ بعد 000..005 المولَّدة، وفي الجلسة نفسها التي أنشأت #rls_tables (انظر deploy.sql).
   المبدأ: كل جدول مملوك للمشترك يُرشَّح بـ TenantId = SESSION_CONTEXT('TenantId').
           أعضاء دور tp_platform (المشغّل) يتجاوزون العزل لأعمال المنصة فقط، والدور tp_auth يتجاوزه
           داخل sec.usp_SetSessionContext فقط لفحص عضوية المستخدم قبل ضبط السياق (030).
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- سياسات RLS والإجراءات تحفظ هذه الخيارات عند الإنشاء
GO
IF SCHEMA_ID(N'rls') IS NULL EXEC(N'CREATE SCHEMA [rls] AUTHORIZATION dbo;');
GO
GRANT SELECT ON SCHEMA::[rls] TO [tp_app];   -- دوال السياسات: يحتاجها محرك الاستعلام في سياق المستخدم (بعد إنشاء المخطط)
GO
-- جداول المشترك العادية: لا ترى إلا صفوف مشتركها
CREATE OR ALTER FUNCTION rls.fn_TenantAccess (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT)
       OR IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1;
GO
-- الجداول المختلطة النطاق: القراءة لصفوف المنصة (TenantId NULL) وصفوف المشترك
CREATE OR ALTER FUNCTION rls.fn_MixedRead (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE @TenantId IS NULL
       OR @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT)
       OR IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1;
GO
-- ... أما الكتابة فلصفوف المشترك نفسه فقط؛ صفوف المنصة لأعضاء tp_platform
CREATE OR ALTER FUNCTION rls.fn_MixedWrite (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE (@TenantId IS NOT NULL AND @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT))
       OR IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1;
GO
-- سجل التدقيق aud.AuditLog: سياسة خاصة (BR-PLT-001/009)
--   القراءة: المشترك يرى صفوفه فقط؛ صفوف TenantId = NULL (أحداث المنصة) لأعضاء tp_platform فقط.
--   الكتابة (إدراج فقط): TenantId الخاص بالمشترك أو NULL لحدث منصة؛ لا تعديل ولا حذف (DENY في 005/020).
CREATE OR ALTER FUNCTION rls.fn_AuditRead (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE (@TenantId IS NOT NULL AND @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT))
       OR IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1;
GO
CREATE OR ALTER FUNCTION rls.fn_AuditWrite (@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessOk
    WHERE @TenantId IS NULL
       OR @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT)
       OR IS_MEMBER(N'tp_platform') = 1 OR IS_MEMBER(N'tp_auth') = 1;
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
    WHERE NOT (SchemaName = N'aud' AND TableName = N'AuditLog');   -- له سياسة خاصة أعلاه
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

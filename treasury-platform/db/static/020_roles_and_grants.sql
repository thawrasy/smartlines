/* ============================================================================
   BankFas - 020: الأدوار والمنح الثابتة (ما لا يولّده النموذج)
   الصلاحيات الجدولية نفسها تُولَّد في 007_table_grants.sql لكل جدول على حدة (لا منح على مستوى المخطط).

   tp_app       حساب تشغيل تطبيق المشترك: منح جدولية فقط (007)؛ لا كتابة على الجداول العالمية؛ لا plat.PlatformOperator
   tp_platform  مشغّلو المنصة: كتابة على الكتالوجات العالمية والمختلطة وplat؛ لا وصول مباشر لبيانات المشتركين (007)
   tp_auth      دور داخلي بلا تسجيل دخول: يُنفَّذ به إجراء ضبط السياق فقط (030) لفحص عضوية المستخدم في المشترك
   tp_readonly  تقارير/تحليل: قراءة فقط، دون الأعمدة الحساسة (006)
   tp_migrator  مالك مخطط النشر والترحيلات؛ لا منح تشغيلية له هنا

   لا منح على مستوى المخطط لـ tp_app أو tp_platform (تمنح كل جداول المخطط بلا استثناء).
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- سياسات RLS والإجراءات تحفظ هذه الخيارات عند الإنشاء
GO
DECLARE @r TABLE (n sysname);
INSERT @r VALUES (N'tp_app'), (N'tp_platform'), (N'tp_readonly'), (N'tp_migrator'), (N'tp_auth');
DECLARE @n sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT n FROM @r;
OPEN c; FETCH NEXT FROM c INTO @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DATABASE_PRINCIPAL_ID(@n) IS NULL
    BEGIN
        DECLARE @rsql nvarchar(400) = N'CREATE ROLE ' + QUOTENAME(@n) + N' AUTHORIZATION dbo;';
        EXEC (@rsql);
    END
    FETCH NEXT FROM c INTO @n;
END
CLOSE c; DEALLOCATE c;
GO
-- tp_auth لا يملك تسجيل دخول ولا عضوية في أي دور؛ يملك قراءة جدولي المشترك والمستخدم فقط. تجاوز RLS له محصور في 010 (IS_MEMBER)
-- EXECUTE AS needs a database user, not a role. tp_auth_exec is a user without login that is a member of tp_auth,
-- so IS_MEMBER(N'tp_auth') = 1 holds while the context procedure runs (030).
IF DATABASE_PRINCIPAL_ID(N'tp_auth_exec') IS NULL CREATE USER [tp_auth_exec] WITHOUT LOGIN;
IF IS_ROLEMEMBER(N'tp_auth', N'tp_auth_exec') <> 1 ALTER ROLE [tp_auth] ADD MEMBER [tp_auth_exec];
GO
GRANT SELECT ON [sec].[AppUser] TO [tp_auth];
GRANT SELECT ON [plat].[Tenant] TO [tp_auth];   -- فحص حالة المشترك في 030
GO
-- تقارير/تحليل: قراءة كل المخططات (الأعمدة الحساسة محجوبة في 006)، وسجل المشغّلين محجوب بالكامل
DECLARE @sch sysname, @sql nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.schemas WHERE name NOT IN (N'dbo', N'sys', N'INFORMATION_SCHEMA', N'guest', N'rls')
      AND name NOT LIKE N'db[_]%';
OPEN c; FETCH NEXT FROM c INTO @sch;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'GRANT SELECT ON SCHEMA::' + QUOTENAME(@sch) + N' TO [tp_readonly];';
    EXEC(@sql);
    FETCH NEXT FROM c INTO @sch;
END
CLOSE c; DEALLOCATE c;
GO
DENY SELECT ON [plat].[PlatformOperator] TO [tp_readonly];
-- sec.SessionBinding (O-16): written and read only by the context procedure (tp_auth, 030). The row filters
-- (010) read it through the owner chain, so no other role needs a grant. Tokens must not be readable by the
-- reporting or platform role: a copied token would let another connection read the bound tenant.
GRANT SELECT, INSERT, UPDATE, DELETE ON [sec].[SessionBinding] TO [tp_auth];
DENY SELECT ON [sec].[SessionBinding] TO [tp_readonly], [tp_platform];
-- مخطط rls يُنشأ في 010؛ منحه لـ tp_app هناك بعد إنشائه
GO

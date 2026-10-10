/* ============================================================================
   BankFas - 020: الأدوار والصلاحيات
   tp_app       حساب تشغيل التطبيق: قراءة وإدخال وتعديل؛ لا حذف إلا على الجداول المعلَّمة deletable (005)
   tp_platform  مشغّلو المنصة: يتجاوزون عزل الصفوف لأعمال المنصة؛ لا يُمنَح للتطبيق العادي
   tp_readonly  تقارير/تحليل: قراءة فقط، دون الأعمدة الحساسة (006)
   tp_migrator  مالك مخطط النشر والترحيلات
   لا DENY على الحذف على مستوى المخطط (فهو يُبطل GRANT الجداول)؛ الافتراضي «لا صلاحية حذف».
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- سياسات RLS والإجراءات تحفظ هذه الخيارات عند الإنشاء
GO
DECLARE @r TABLE (n sysname);
INSERT @r VALUES (N'tp_app'), (N'tp_platform'), (N'tp_readonly'), (N'tp_migrator');
DECLARE @n sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT n FROM @r;
OPEN c; FETCH NEXT FROM c INTO @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DATABASE_PRINCIPAL_ID(@n) IS NULL EXEC(N'CREATE ROLE ' + QUOTENAME(@n) + N' AUTHORIZATION dbo;');
    FETCH NEXT FROM c INTO @n;
END
CLOSE c; DEALLOCATE c;
GO
-- التطبيق: كل مخططات الأعمال قراءة/إدخال/تعديل (بلا مخططي rls وplat للكتابة)
DECLARE @sch sysname, @sql nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.schemas WHERE name NOT IN (N'dbo', N'sys', N'INFORMATION_SCHEMA', N'guest', N'rls')
      AND name NOT LIKE N'db[_]%';
OPEN c; FETCH NEXT FROM c INTO @sch;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'GRANT SELECT ON SCHEMA::' + QUOTENAME(@sch) + N' TO [tp_readonly];';
    EXEC(@sql);
    IF @sch = N'plat'
        SET @sql = N'GRANT SELECT ON SCHEMA::' + QUOTENAME(@sch) + N' TO [tp_app]; GRANT SELECT, INSERT, UPDATE ON SCHEMA::' + QUOTENAME(@sch) + N' TO [tp_platform];';
    ELSE IF @sch = N'aud'
        SET @sql = N'GRANT SELECT, INSERT ON SCHEMA::' + QUOTENAME(@sch) + N' TO [tp_app]; GRANT SELECT, INSERT ON SCHEMA::' + QUOTENAME(@sch) + N' TO [tp_platform];'; -- سجل التدقيق للإضافة فقط
    ELSE
        SET @sql = N'GRANT SELECT, INSERT, UPDATE, REFERENCES ON SCHEMA::' + QUOTENAME(@sch) + N' TO [tp_app]; GRANT SELECT, INSERT, UPDATE ON SCHEMA::' + QUOTENAME(@sch) + N' TO [tp_platform];';
    EXEC(@sql);
    FETCH NEXT FROM c INTO @sch;
END
CLOSE c; DEALLOCATE c;
GO
GRANT EXECUTE ON SCHEMA::[sec] TO [tp_app];
GRANT EXECUTE ON SCHEMA::[cfg] TO [tp_app];
GRANT SELECT ON SCHEMA::[rls] TO [tp_app];
GO

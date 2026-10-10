/* ============================================================================
   BankFas - 040: بحث نصي كامل على الطلبات (اختياري)
   يتطلب تثبيت ميزة Full-Text Search في SQL Server؛ شغِّل هذا الملف بعد النشر فقط إن كانت الميزة مثبَّتة.
   يغطي wfl.Request.SearchText (نص مطبَّع، لا يضم الحقول المقيَّدة — BR-REQ-003). لا يدخل في deploy.sql افتراضيًا.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- سياسات RLS والإجراءات تحفظ هذه الخيارات عند الإنشاء
GO
IF FULLTEXTSERVICEPROPERTY(N'IsFullTextInstalled') <> 1
BEGIN
    RAISERROR(N'Full-Text Search غير مثبَّتة على هذا الخادم؛ تُخطّى الفهرسة النصية.', 10, 1) WITH NOWAIT;
    SET NOEXEC ON;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = N'FTC_BankFas')
    CREATE FULLTEXT CATALOG [FTC_BankFas] WITH ACCENT_SENSITIVITY = OFF;
GO
IF NOT EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID(N'wfl.Request'))
    CREATE FULLTEXT INDEX ON [wfl].[Request] ([SearchText] LANGUAGE 1025)  -- 1025 = العربية؛ أضف عمودًا ثانيًا بلغة 1033 إن لزم
        KEY INDEX [PK_Request] ON [FTC_BankFas] WITH CHANGE_TRACKING AUTO;
GO
SET NOEXEC OFF;
GO

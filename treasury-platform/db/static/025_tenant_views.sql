/* ============================================================================
   BankFas - 025: عروض مُحدَّدة لتطبيق المشترك (بدل منح الجداول الأساسية)
   plat.Tenant عالمي ومحجوب عن tp_app (noapp)، فيقرأ التطبيق صفّ مشتركه فقط من هذا العرض.
   العرض يملكه نفس مالك الجدول الأساسي، فتعمل سلسلة الملكية (ownership chaining) دون منح للجدول.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER VIEW plat.v_CurrentTenant
AS
    SELECT t.TenantId, t.PublicId, t.Code, t.NameAr, t.NameEn, t.PlanId, t.Status,
           t.HomeCountryId, t.DefaultLanguage, t.TimeZone
    FROM plat.Tenant AS t
    WHERE t.TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT);
GO
GRANT SELECT ON plat.v_CurrentTenant TO [tp_app];
GO

/* DR-01: الوحدات المفعّلة للمشترك ملكية المنصة (عالمي، بلا منح للتطبيق على الجدول)؛
   يقرأ تطبيق المشترك صفوفه عبر هذا العرض فقط، ولا يكتبها إلا مشغّل المنصة (007). */
CREATE OR ALTER VIEW plat.v_TenantModule
AS
    SELECT m.TenantId, m.ModuleCode, m.IsEnabled, m.EnabledAt
    FROM plat.TenantModule AS m
    WHERE m.TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT);
GO
GRANT SELECT ON plat.v_TenantModule TO [tp_app];
GO

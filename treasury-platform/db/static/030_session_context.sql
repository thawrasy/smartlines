/* ============================================================================
   BankFas - 030: سياق الجلسة (يضبطه التطبيق عند فتح كل اتصال من المجمّع)
   الإجراء يربط المستخدم بالمشترك داخل القاعدة نفسها، ولا يقبل المشترك بمجرّد وجوده:
     1) المشترك موجود وحالته مقبولة (plat.Tenant)
     2) المستخدم نشط وينتمي إلى هذا المشترك بالذات (sec.AppUser)  ← BR-PLT-004، هذا ما لم يكن قبل التعديل
   التنفيذ بصفة tp_auth (WITH EXECUTE AS) حتى يرى جدول المستخدمين قبل ضبط السياق (RLS يحتاج السياق)،
   ويقتصر ذلك على هذا الإجراء. تعيين السياق للقراءة فقط (read_only) يمنع تغييره في الجلسة نفسها.
   عند الفشل يُرفع خطأ ويجب على التطبيق إعادة الاتصال (sp_reset_connection) ولا يُستعمل.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- سياسات RLS والإجراءات تحفظ هذه الخيارات عند الإنشاء
GO
CREATE OR ALTER PROCEDURE sec.usp_SetSessionContext
    @TenantId      INT,
    @UserId        BIGINT,
    @ClientIp      VARCHAR(45) = NULL,
    @CorrelationId UNIQUEIDENTIFIER = NULL
WITH EXECUTE AS N'tp_auth'
AS
BEGIN
    SET NOCOUNT ON;
    IF @TenantId IS NULL OR @UserId IS NULL THROW 50001, 'TenantId and UserId are required', 1;
    IF NOT EXISTS (SELECT 1 FROM plat.Tenant WHERE TenantId = @TenantId AND Status IN ('TRIAL','ACTIVE','SUSPENDED','ARCHIVED_READ_ONLY'))
        THROW 50002, 'Unknown or closed tenant', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.AppUser WHERE TenantId = @TenantId AND AppUserId = @UserId AND Status = 'ACTIVE')
        THROW 50003, 'User is not an active member of the tenant', 1;
    EXEC sp_set_session_context N'TenantId', @TenantId, @read_only = 1;
    EXEC sp_set_session_context N'UserId', @UserId, @read_only = 1;
    EXEC sp_set_session_context N'ClientIp', @ClientIp, @read_only = 1;
    EXEC sp_set_session_context N'CorrelationId', @CorrelationId, @read_only = 1;
END;
GO
GRANT EXECUTE ON sec.usp_SetSessionContext TO [tp_app];
GO

/* ============================================================================
   BankFas - 030: سياق الجلسة (يضبطه التطبيق عند فتح كل اتصال من المجمّع)
   read_only = 1: لا يستطيع أي استعلام لاحق تغيير المشترك أثناء الجلسة؛ يُعاد الضبط مع إعادة تدوير الاتصال.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- سياسات RLS والإجراءات تحفظ هذه الخيارات عند الإنشاء
GO
CREATE OR ALTER PROCEDURE sec.usp_SetSessionContext
    @TenantId INT,
    @UserId   BIGINT = NULL,
    @ClientIp VARCHAR(45) = NULL,
    @CorrelationId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @TenantId IS NULL THROW 50001, 'TenantId is required', 1;
    -- لا يُقبل مشترك غير موجود أو موقوف/مغلق
    IF NOT EXISTS (SELECT 1 FROM plat.Tenant WHERE TenantId = @TenantId AND Status IN ('TRIAL','ACTIVE','SUSPENDED','ARCHIVED_READ_ONLY'))
        THROW 50002, 'Unknown or closed tenant', 1;
    EXEC sp_set_session_context N'TenantId', @TenantId, @read_only = 1;
    EXEC sp_set_session_context N'UserId', @UserId, @read_only = 1;
    EXEC sp_set_session_context N'ClientIp', @ClientIp, @read_only = 1;
    EXEC sp_set_session_context N'CorrelationId', @CorrelationId, @read_only = 1;
END;
GO
GRANT EXECUTE ON sec.usp_SetSessionContext TO [tp_app];
GO

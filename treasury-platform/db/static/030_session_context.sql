/* ============================================================================
   BankFas - 030: connection context (the application calls this when it takes a connection from the pool)
   The procedure binds the connection to one tenant and one user. It trusts no tenant supplied by the caller:
     1) the tenant exists and is open (plat.Tenant)
     2) the user is active and belongs to that tenant (sec.AppUser)            [BR-PLT-004]
     3) the connection is not bound yet (SESSION_CONTEXT(N'TenantId') is empty)
   It then writes the binding for @@SPID (sec.SessionBinding) with a new random token and sets the session
   context read-only. The row filters (010) show rows only when the context and the binding agree (O-16).
   It runs as tp_auth_exec (WITH EXECUTE AS), so it can read the tenant and user tables before the context exists.
   On failure it raises an error. The application then resets the connection (sp_reset_connection) before it
   tries again. A reset clears the context, so a stale binding left for that connection grants nothing.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- policies and procedures keep these options when created
GO
CREATE OR ALTER PROCEDURE sec.usp_SetSessionContext
    @TenantId      INT,
    @UserId        BIGINT,
    @ClientIp      VARCHAR(45) = NULL,
    @CorrelationId UNIQUEIDENTIFIER = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF @TenantId IS NULL OR @UserId IS NULL THROW 50001, 'TenantId and UserId are required', 1;
    IF NOT EXISTS (SELECT 1 FROM plat.Tenant WHERE TenantId = @TenantId AND Status IN ('TRIAL','ACTIVE','SUSPENDED','ARCHIVED_READ_ONLY'))
        THROW 50002, 'Unknown or closed tenant', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.AppUser WHERE TenantId = @TenantId AND AppUserId = @UserId AND Status = 'ACTIVE')
        THROW 50003, 'User is not an active member of the tenant', 1;
    IF SESSION_CONTEXT(N'TenantId') IS NOT NULL
        THROW 50004, 'The connection is already bound; reset it (sp_reset_connection) before binding again', 1;

    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    MERGE sec.SessionBinding AS b
    USING (SELECT @@SPID AS SessionId) AS s
       ON b.SessionId = s.SessionId
    WHEN MATCHED THEN
        UPDATE SET BoundTenantId = @TenantId, BoundUserId = @UserId, BindingToken = @token, BoundAt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (s.SessionId, @TenantId, @UserId, @token);

    EXEC sp_set_session_context N'TenantId', @TenantId, @read_only = 1;
    EXEC sp_set_session_context N'BindingToken', @token, @read_only = 1;
    EXEC sp_set_session_context N'UserId', @UserId, @read_only = 1;
    EXEC sp_set_session_context N'ClientIp', @ClientIp, @read_only = 1;
    EXEC sp_set_session_context N'CorrelationId', @CorrelationId, @read_only = 1;
END;
GO
GRANT EXECUTE ON sec.usp_SetSessionContext TO [tp_app];
GO
/* Revocation (O-16 review): a binding ends when its user is no longer ACTIVE or its tenant is no longer
   TRIAL or ACTIVE. The connection then sees no rows, and it cannot bind again without a reset (50004 / 50002).
   The triggers run as tp_auth_exec, which may delete binding rows. */
CREATE OR ALTER TRIGGER sec.TR_AppUser_RevokeBinding ON sec.AppUser
WITH EXECUTE AS N'tp_auth_exec'
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(Status)
        DELETE b
        FROM sec.SessionBinding AS b
        JOIN inserted AS i ON i.AppUserId = b.BoundUserId AND i.TenantId = b.BoundTenantId
        WHERE i.Status <> 'ACTIVE';
END;
GO
CREATE OR ALTER TRIGGER plat.TR_Tenant_RevokeBinding ON plat.Tenant
WITH EXECUTE AS N'tp_auth_exec'
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(Status)
        DELETE b
        FROM sec.SessionBinding AS b
        JOIN inserted AS i ON i.TenantId = b.BoundTenantId
        WHERE i.Status NOT IN (N'TRIAL', N'ACTIVE');
END;
GO

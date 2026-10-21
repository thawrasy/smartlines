/* ============================================================================
   BankFas - 059: what the support screens and the operator panel need from the database (phase 2 S0, ADR 0040;
   GAP-5, GAP-6 and GAP-9 of the S0 brief)

   The tenant application may not read plat.PlatformOperator, and the panel may not read a tenant's rows, so the
   flows of support access (DOC-F04 section 6.2, FR-PLT-007, BR-PLT-017, AC-PLT-8) and of the tenant details in the
   panel (FR-PLT-005) each get a narrow procedure that returns only what the screen shows:
     sec.usp_ListSupportOperators       the ACTIVE operators a tenant administrator can grant support access to:
                                        id, public id, name and role, no e-mail (GAP-5a). Bound USER of the tenant.
                                                                                                    EXECUTE: tp_app
     plat.usp_ListOperatorSupportGrants the grants of the operator of a live panel session with MFA that are started,
                                        not ended and not revoked, with their tenant's public id, code and name
                                        (GAP-5b).                                                EXECUTE: tp_platform
     sec.usp_WriteSupportPageView       an audit row of the tenant for each page a support binding shows, naming the
                                        operator and the grant, and a HIGH row for a refused reveal (GAP-6,
                                        FR-PLT-007, AC-PLT-8). Only a SUPPORT binding writes it.   EXECUTE: tp_support
     plat.usp_GetTenantCounters         counters of one tenant for the panel, never business data (FR-PLT-005,
                                        GAP-9): users by status, roles, the first administrator's status, the
                                        onboarding event, the packs seeded and the last login.     EXECUTE: tp_platform
     plat.usp_ResendFirstAdminInvitation an operator administrator sends the first administrator's invitation again
                                        while that user is still INVITED: the onboarding event goes back to PENDING,
                                        so the job issues a new link and a new e-mail (GAP-9).     EXECUTE: tp_platform
   Errors: 50003 no valid session or binding, 50016 the first administrator is no longer invited, 50021 not an
   operator administrator with MFA.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER PROCEDURE sec.usp_ListSupportOperators
    @TenantId INT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@TenantId, 0))
        THROW 50003, 'The connection is not bound to a user of this tenant', 1;
    SELECT PlatformOperatorId AS OperatorId, PublicId, DisplayName, Role
    FROM plat.PlatformOperator
    WHERE Status = 'ACTIVE'
    ORDER BY DisplayName, PlatformOperatorId;
END;
GO
CREATE OR ALTER PROCEDURE plat.usp_ListOperatorSupportGrants
    @SessionToken VARBINARY(64)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @oid INT;
    SELECT @oid = o.PlatformOperatorId
    FROM plat.OperatorSession AS s
    JOIN plat.PlatformOperator AS o ON o.PlatformOperatorId = s.OperatorId
    WHERE s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
      AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now AND s.MfaVerifiedAt IS NOT NULL
      AND o.Status = 'ACTIVE';
    IF @oid IS NULL THROW 50003, 'No valid operator session', 1;
    SELECT g.SupportAccessGrantId, g.TenantId, t.PublicId AS TenantPublicId, t.Code, t.NameEn, t.NameAr, t.Status AS TenantStatus,
           g.StartsAt, g.EndsAt, g.Reason
    FROM plat.SupportAccessGrant AS g
    JOIN plat.Tenant AS t ON t.TenantId = g.TenantId
    WHERE g.OperatorId = @oid AND g.RevokedAt IS NULL AND g.StartsAt <= @now AND @now < g.EndsAt
    ORDER BY g.EndsAt;
END;
GO
CREATE OR ALTER PROCEDURE sec.usp_WriteSupportPageView
    @Page    VARCHAR(200),
    @Refused BIT = 0          -- 1: the page asked for what support may never see (a reveal); a HIGH row (FR-PLT-007)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tenant INT = CAST(SESSION_CONTEXT(N'TenantId') AS INT),
            @oid INT = CAST(SESSION_CONTEXT(N'OperatorId') AS INT),
            @gid BIGINT = CAST(SESSION_CONTEXT(N'SupportAccessGrantId') AS BIGINT),
            @ip VARCHAR(45) = CAST(SESSION_CONTEXT(N'ClientIp') AS VARCHAR(45)),
            @corr UNIQUEIDENTIFIER = CAST(SESSION_CONTEXT(N'CorrelationId') AS UNIQUEIDENTIFIER);
    IF @tenant IS NULL OR @oid IS NULL OR @gid IS NULL
       OR NOT EXISTS (SELECT 1 FROM sec.SessionBinding WHERE SessionId = @@SPID AND BindingKind = 'SUPPORT' AND BoundOperatorId = @oid)
       OR NOT EXISTS (SELECT 1 FROM rls.fn_Bound(@tenant))
        THROW 50003, 'The connection is not bound as support to this tenant', 1;
    IF @Page IS NULL OR LTRIM(@Page) = '' THROW 50001, 'The page is required', 1;
    DECLARE @after NVARCHAR(400) = (SELECT @Page AS page FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            @action VARCHAR(60) = CASE WHEN @Refused = 1 THEN 'SUPPORT_ACCESS_DENIED' ELSE 'SUPPORT_PAGE_VIEWED' END,
            @severity VARCHAR(4) = CASE WHEN @Refused = 1 THEN 'HIGH' ELSE 'INFO' END,
            @result VARCHAR(7) = CASE WHEN @Refused = 1 THEN 'DENIED' ELSE 'SUCCESS' END;
    EXEC aud.usp_WriteEvent @TenantId = @tenant, @Action = @action, @Category = 'SECURITY', @ActorType = 'OPERATOR',
         @ActorOperatorId = @oid, @Severity = @severity, @Result = @result, @EntityType = 'plat.SupportAccessGrant', @EntityId = @gid,
         @AfterJson = @after, @IpAddress = @ip, @CorrelationId = @corr;
END;
GO
CREATE OR ALTER PROCEDURE plat.usp_GetTenantCounters
    @SessionToken VARBINARY(64),
    @TenantId     INT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();
    IF NOT EXISTS (SELECT 1
                   FROM plat.OperatorSession AS s
                   JOIN plat.PlatformOperator AS o ON o.PlatformOperatorId = s.OperatorId
                   WHERE s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
                     AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now AND s.MfaVerifiedAt IS NOT NULL
                     AND o.Status = 'ACTIVE')
        THROW 50003, 'No valid operator session', 1;
    IF NOT EXISTS (SELECT 1 FROM plat.Tenant WHERE TenantId = @TenantId) THROW 50002, 'Unknown tenant', 1;
    DECLARE @admin BIGINT = (SELECT TOP (1) TRY_CAST(JSON_VALUE(PayloadJson, '$.adminUserId') AS BIGINT)
                             FROM cfg.OutboxEvent WHERE TenantId = @TenantId AND EventName = 'tenant.created' ORDER BY OutboxEventId);
    SELECT
        (SELECT COUNT(AppUserId) FROM sec.AppUser WHERE TenantId = @TenantId AND IsSystemUser = 0 AND Status = 'ACTIVE') AS UsersActive,
        (SELECT COUNT(AppUserId) FROM sec.AppUser WHERE TenantId = @TenantId AND IsSystemUser = 0 AND Status = 'INVITED') AS UsersInvited,
        (SELECT COUNT(AppUserId) FROM sec.AppUser WHERE TenantId = @TenantId AND IsSystemUser = 0 AND Status IN ('LOCKED', 'DISABLED')) AS UsersBlocked,
        (SELECT COUNT(RoleId) FROM sec.Role WHERE TenantId = @TenantId) AS Roles,
        (SELECT Status FROM sec.AppUser WHERE TenantId = @TenantId AND AppUserId = @admin) AS FirstAdminStatus,
        (SELECT TOP (1) Status FROM cfg.OutboxEvent WHERE TenantId = @TenantId AND EventName = 'tenant.created' ORDER BY OutboxEventId) AS OnboardingStatus,
        (SELECT TOP (1) SendStatus FROM sec.UserToken WHERE TenantId = @TenantId AND UserId = @admin AND Purpose = 'INVITATION'
         ORDER BY UserTokenId DESC) AS InvitationSendStatus,
        (SELECT COUNT(DISTINCT PackKey) FROM cfg.SeedRun WHERE TenantId = @TenantId AND Status = 'SUCCEEDED') AS PacksSeeded,
        (SELECT MAX(LastLoginAt) FROM sec.AppUser WHERE TenantId = @TenantId AND IsSystemUser = 0) AS LastLoginAt;
END;
GO
CREATE OR ALTER PROCEDURE plat.usp_ResendFirstAdminInvitation
    @SessionToken VARBINARY(64),
    @TenantId     INT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @caller INT = (SELECT PlatformOperatorId FROM plat.fn_OperatorAdminOfSession(@SessionToken)), @own BIT = 0, @ev BIGINT, @admin BIGINT;
    IF @caller IS NULL THROW 50021, 'An operator administrator session with MFA is required', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_ResendFirstAdminInvitation;
    BEGIN TRY
        SELECT TOP (1) @ev = OutboxEventId, @admin = TRY_CAST(JSON_VALUE(PayloadJson, '$.adminUserId') AS BIGINT)
        FROM cfg.OutboxEvent WITH (UPDLOCK, HOLDLOCK)
        WHERE TenantId = @TenantId AND EventName = 'tenant.created'
        ORDER BY OutboxEventId;
        IF @ev IS NULL THROW 50002, 'Unknown tenant', 1;
        IF NOT EXISTS (SELECT 1 FROM sec.AppUser WHERE TenantId = @TenantId AND AppUserId = @admin AND Status = 'INVITED')
            THROW 50016, 'The first administrator has already accepted the invitation', 1;
        UPDATE cfg.OutboxEvent
           SET Status = 'PENDING', NextAttemptAt = NULL, LockedBy = NULL, LockedUntil = NULL, DeliveredAt = NULL, LastError = NULL
         WHERE OutboxEventId = @ev AND Status <> 'PROCESSING';
        EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'FIRST_ADMIN_INVITATION_RESENT', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
             @ActorOperatorId = @caller, @EntityType = 'plat.Tenant', @EntityId = @TenantId;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ResendFirstAdminInvitation;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
GRANT EXECUTE ON sec.usp_ListSupportOperators TO [tp_app];
GRANT EXECUTE ON plat.usp_ListOperatorSupportGrants TO [tp_platform];
GRANT EXECUTE ON sec.usp_WriteSupportPageView TO [tp_support];
GRANT EXECUTE ON plat.usp_GetTenantCounters TO [tp_platform];
GRANT EXECUTE ON plat.usp_ResendFirstAdminInvitation TO [tp_platform];
GO

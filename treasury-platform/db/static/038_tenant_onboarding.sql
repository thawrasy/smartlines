/* ============================================================================
   BankFas - 038: creating a tenant and changing its status (O-12 in docs/20-database-design.md, DOC-F05,
   DQ-F05-1, DQ-F05-2, DQ-F05-4, DQ-F05-5, DQ-F05-6, DQ-F05-7, owner decisions of 2026-10-12)

   Onboarding runs in stages (DOC-F05 4.1):
     A. plat.usp_CreateTenant           an operator administrator, with an MFA check in the last 5 minutes, creates in
                                        one transaction: the tenant (TRIAL, 30 days), its modules from the plan with
                                        CORE, the service account, the first administrator (INVITED, no password)
                                        and the event tenant.created. EXECUTE: tp_platform
     B. the onboarding job              binds as the service account (sec.usp_SetJobContext, JOB-PLT-ONBOARD) and
                                        seeds the packs, the system roles among them (application code, FR-PLT-008).
     C. sec.usp_InviteFirstAdministrator the same job gives the first administrator the TA role and an invitation
                                        link, once the roles exist. EXECUTE: tp_jobs
     D-E. the e-mail and the acceptance (sec.usp_CompleteInvitation, 035), then MFA enrolment at the first login.
   Status changes (DOC-F05 6.2) go through one internal procedure, plat.usp_ApplyTenantStatus:
     plat.usp_SetTenantStatus           an operator administrator with a fresh MFA check. EXECUTE: tp_platform
     plat.usp_RunTenantTransitions      the daily platform jobs JOB-PLT-TRIAL-EXPIRE and JOB-PLT-ARCHIVE. EXECUTE: tp_jobs
   Closing an ACTIVE or SUSPENDED tenant is refused until the data export (FR-PLT-039) exists (DQ-F05-7, 50027);
   a TRIAL tenant whose onboarding is cancelled may be closed (DQ-F05-4).
   The operator panel can no longer insert a tenant or change its code, status or status dates directly (DENYs at
   the end, after the generated grants 007).

   Errors: 50001 arguments, 50002 unknown tenant, 50003 not bound as the onboarding job, 50016 user cannot be
   invited, 50019 status change not allowed, 50021 operator administrator with a fresh MFA check required,
   50024 not a status job, 50025 reserved code, 50026 code in use, 50027 closing waits for the data export,
   50028 roles not seeded yet or administrator already chosen.
   Dates: TrialEndsOn and the expiry check use the UTC date; the tenant's own time zone can move them by a day.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
-- An operator administrator whose session had its TOTP checked in the last 5 minutes (step-up, DQ-F05-2): the panel
-- calls plat.usp_ConfirmOperatorMfa again right before the action.
CREATE OR ALTER FUNCTION plat.fn_OperatorAdminStepUp (@SessionToken VARBINARY(64))
RETURNS TABLE
AS RETURN
    SELECT a.PlatformOperatorId
    FROM plat.fn_OperatorAdminOfSession(@SessionToken) AS a
    JOIN plat.OperatorSession AS s ON s.OperatorId = a.PlatformOperatorId AND s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
    WHERE s.MfaVerifiedAt >= DATEADD(MINUTE, -5, SYSUTCDATETIME());
GO
/* ---------- Stage A: create the tenant ---------- */

CREATE OR ALTER PROCEDURE plat.usp_CreateTenant
    @OperatorSessionToken VARBINARY(64),
    @Code                 VARCHAR(30),
    @NameAr               NVARCHAR(200),
    @NameEn               NVARCHAR(200),
    @PlanId               INT,
    @HomeCountryId        INT,
    @TimeZone             VARCHAR(64),
    @DefaultLanguage      VARCHAR(2) = 'en',
    @AdminEmail           NVARCHAR(254),
    @AdminDisplayName     NVARCHAR(200),
    @TenantId             INT = NULL OUTPUT,
    @AdminUserId          BIGINT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @TenantId = NULL, @AdminUserId = NULL;
    DECLARE @caller INT = (SELECT PlatformOperatorId FROM plat.fn_OperatorAdminStepUp(@OperatorSessionToken)),
            @slug VARCHAR(30) = LOWER(LTRIM(RTRIM(@Code))), @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @svc BIGINT;
    IF @caller IS NULL THROW 50021, 'An operator administrator with an MFA check in the last 5 minutes is required', 1;
    IF @slug IS NULL OR @slug = '' OR @NameAr IS NULL OR @NameEn IS NULL OR @TimeZone IS NULL OR @AdminEmail IS NULL
        THROW 50001, 'Code, names, time zone and the first administrator''s e-mail are required', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_CreateTenant;
    BEGIN TRY
        -- Every check comes before the first write.
        IF EXISTS (SELECT 1 FROM plat.ReservedSubdomain WHERE Subdomain = @slug)
            THROW 50025, 'This code is reserved', 1;
        IF EXISTS (SELECT 1 FROM plat.Tenant WITH (UPDLOCK, HOLDLOCK) WHERE Code = @slug)
            THROW 50026, 'This code is already used, also by a closed tenant', 1;
        IF NOT EXISTS (SELECT 1 FROM plat.[Plan] WHERE PlanId = @PlanId AND IsActive = 1)
            THROW 50001, 'Unknown or inactive plan', 1;

        INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, Status, TrialEndsOn, HomeCountryId, DefaultLanguage, TimeZone)
        VALUES (@slug, @NameAr, @NameEn, @PlanId, 'TRIAL', DATEADD(DAY, 30, CAST(@now AS DATE)), @HomeCountryId,
                ISNULL(@DefaultLanguage, 'en'), @TimeZone);
        SET @TenantId = SCOPE_IDENTITY();
        INSERT plat.TenantModule (TenantId, ModuleCode, IsEnabled, EnabledAt)
        SELECT @TenantId, m.ModuleCode, 1, @now
        FROM (SELECT ModuleCode FROM plat.PlanModule WHERE PlanId = @PlanId UNION SELECT 'CORE') AS m;
        -- The service account: no password, no interactive login (BR-PLT-004); jobs bind as it (037).
        INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, IsSystemUser)
        VALUES (@TenantId, CONCAT(N'service@', @slug, N'.invalid'), N'Service account', 'ACTIVE', 1);
        SET @svc = SCOPE_IDENTITY();
        -- The first administrator: invited, no password; the TA role and the link come at stage C.
        INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status)
        VALUES (@TenantId, @AdminEmail, @AdminDisplayName, 'INVITED');
        SET @AdminUserId = SCOPE_IDENTITY();
        INSERT cfg.OutboxEvent (TenantId, EventName, AggregateType, AggregateId, PayloadJson)
        VALUES (@TenantId, 'tenant.created', 'Tenant', @TenantId,
                CONCAT(N'{"tenantId":', @TenantId, N',"adminUserId":', @AdminUserId, N',"serviceUserId":', @svc,
                       N',"createdByOperatorId":', @caller, N'}'));
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateTenant;   -- undo this procedure only
        SELECT @TenantId = NULL, @AdminUserId = NULL;
        THROW;
    END CATCH;
END;
GO
/* ---------- Stage C: invite the first administrator ---------- */

-- Run by the onboarding job bound to the new tenant (JOB-PLT-ONBOARD) once the packs seeded the system roles.
-- Gives the user the TA role and an invitation link; called again, it replaces an unused link (a new e-mail).
CREATE OR ALTER PROCEDURE sec.usp_InviteFirstAdministrator
    @UserId BIGINT,
    @Token  VARBINARY(64),             -- random link token, at least 32 bytes; only its SHA-256 is stored
    @SentTo NVARCHAR(254) = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @SentTo = NULL;
    IF @Token IS NULL OR DATALENGTH(@Token) < 32 THROW 50001, 'A link token of at least 32 bytes is required', 1;
    DECLARE @tenant INT = CAST(SESSION_CONTEXT(N'TenantId') AS INT), @now DATETIME2(3) = SYSUTCDATETIME(),
            @own BIT = 0, @role BIGINT, @email NVARCHAR(254);
    IF @tenant IS NULL
       OR CAST(SESSION_CONTEXT(N'JobKey') AS VARCHAR(80)) IS NULL
       OR CAST(SESSION_CONTEXT(N'JobKey') AS VARCHAR(80)) <> 'JOB-PLT-ONBOARD'
       OR NOT EXISTS (SELECT 1 FROM sec.SessionBinding WHERE SessionId = @@SPID AND BindingKind = 'JOB')
       OR NOT EXISTS (SELECT 1 FROM rls.fn_BoundWrite(@tenant))
        THROW 50003, 'The connection is not bound as the onboarding job of an open tenant', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_InviteFirstAdministrator;
    BEGIN TRY
        SELECT @role = RoleId FROM sec.Role
        WHERE TenantId = @tenant AND Code = 'TA' AND IsSystem = 1 AND IsActive = 1;
        IF @role IS NULL THROW 50028, 'The system roles are not seeded yet', 1;
        SELECT @email = Email FROM sec.AppUser WITH (UPDLOCK, HOLDLOCK)
        WHERE TenantId = @tenant AND AppUserId = @UserId AND Status = 'INVITED' AND IsSystemUser = 0;
        IF @email IS NULL THROW 50016, 'This user cannot be invited as the first administrator', 1;
        IF EXISTS (SELECT 1 FROM sec.UserRole WITH (UPDLOCK, HOLDLOCK)
                   WHERE TenantId = @tenant AND RoleId = @role AND UserId <> @UserId)
            THROW 50028, 'The tenant already has an administrator', 1;

        IF NOT EXISTS (SELECT 1 FROM sec.UserRole WHERE TenantId = @tenant AND RoleId = @role AND UserId = @UserId)
            INSERT sec.UserRole (TenantId, UserId, RoleId) VALUES (@tenant, @UserId, @role);
        UPDATE sec.UserToken SET RevokedAt = @now
         WHERE TenantId = @tenant AND UserId = @UserId AND Purpose = 'INVITATION' AND UsedAt IS NULL AND RevokedAt IS NULL;
        INSERT sec.UserToken (TenantId, UserId, Purpose, TokenHash, ExpiresAt, SentTo)
        VALUES (@tenant, @UserId, 'INVITATION', HASHBYTES('SHA2_256', @Token), DATEADD(HOUR, 48, @now), @email);
        SET @SentTo = @email;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_InviteFirstAdministrator;   -- undo this procedure only
        SET @SentTo = NULL;
        THROW;
    END CATCH;
END;
GO
/* ---------- Status changes ---------- */

-- Internal: one status change with its columns, the end of the sessions the new status no longer admits, and the
-- event tenant.status_changed (DOC-F05 6.2). @Actor OPERATOR or JOB decides which transitions are allowed.
CREATE OR ALTER PROCEDURE plat.usp_ApplyTenantStatus
    @TenantId    INT,
    @Status      VARCHAR(18),
    @Actor       VARCHAR(8),
    @Reason      NVARCHAR(500) = NULL,
    @TrialEndsOn DATE = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @today DATE = CAST(SYSUTCDATETIME() AS DATE), @own BIT = 0,
            @old VARCHAR(18), @trialEnds DATE, @closedAt DATETIME2(3), @ok BIT = 0;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_ApplyTenantStatus;
    BEGIN TRY
        SELECT @old = Status, @trialEnds = TrialEndsOn, @closedAt = ClosedAt
        FROM plat.Tenant WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @TenantId;
        IF @old IS NULL THROW 50002, 'Unknown tenant', 1;
        IF @Actor = 'OPERATOR'
            SET @ok = CASE WHEN @old = 'TRIAL' AND @Status IN ('ACTIVE', 'CLOSED') THEN 1
                           WHEN @old = 'ACTIVE' AND @Status IN ('SUSPENDED', 'CLOSED') THEN 1
                           WHEN @old = 'SUSPENDED' AND @Status IN ('ACTIVE', 'TRIAL', 'CLOSED') THEN 1
                           ELSE 0 END;
        ELSE IF @Actor = 'JOB'
            SET @ok = CASE WHEN @old = 'TRIAL' AND @Status = 'SUSPENDED' AND @trialEnds < @today THEN 1
                           WHEN @old = 'CLOSED' AND @Status = 'ARCHIVED_READ_ONLY' AND DATEADD(DAY, 30, @closedAt) <= @now THEN 1
                           ELSE 0 END;
        IF @ok = 0 THROW 50019, 'This status change is not allowed', 1;
        IF @Status = 'CLOSED' AND @old <> 'TRIAL'
            THROW 50027, 'Closing an active or suspended tenant waits for the data export (FR-PLT-039, DQ-F05-7)', 1;
        IF @Status = 'SUSPENDED' AND (@Reason IS NULL OR LTRIM(@Reason) = N'')
            THROW 50001, 'A reason is required to suspend a tenant', 1;
        IF @Status = 'TRIAL' AND (@TrialEndsOn IS NULL OR @TrialEndsOn <= @today)
            THROW 50001, 'A new trial end date after today is required', 1;
        IF @Status = 'CLOSED' AND (@Reason IS NULL OR LTRIM(@Reason) = N'')
            THROW 50001, 'A reason is required to close a tenant', 1;

        UPDATE plat.Tenant
           SET Status = @Status,
               ActivatedAt = CASE WHEN @Status = 'ACTIVE' AND ActivatedAt IS NULL THEN @now ELSE ActivatedAt END,
               SuspendedReason = CASE WHEN @Status = 'SUSPENDED' THEN @Reason WHEN @old = 'SUSPENDED' THEN NULL ELSE SuspendedReason END,
               SuspendedAt = CASE WHEN @Status = 'SUSPENDED' THEN @now WHEN @old = 'SUSPENDED' THEN NULL ELSE SuspendedAt END,
               TrialEndsOn = CASE WHEN @Status = 'TRIAL' THEN @TrialEndsOn ELSE TrialEndsOn END,
               ClosedAt = CASE WHEN @Status = 'CLOSED' THEN @now ELSE ClosedAt END,
               ArchivedAt = CASE WHEN @Status = 'ARCHIVED_READ_ONLY' THEN DATEADD(DAY, 30, ClosedAt) ELSE ArchivedAt END
         WHERE TenantId = @TenantId;
        -- Sessions of users the new status does not admit end now (the bindings went with the status trigger, 030).
        IF @Status NOT IN ('TRIAL', 'ACTIVE')
            UPDATE s SET EndedAt = @now, EndReason = 'TENANT_SUSPENDED'
            FROM sec.UserSession AS s
            WHERE s.TenantId = @TenantId AND s.EndedAt IS NULL
              AND NOT EXISTS (SELECT 1 FROM sec.fn_TenantLoginAllowed(@TenantId, s.UserId));
        INSERT cfg.OutboxEvent (TenantId, EventName, AggregateType, AggregateId, PayloadJson)
        VALUES (@TenantId, 'tenant.status_changed', 'Tenant', @TenantId,
                CONCAT(N'{"from":"', @old, N'","to":"', @Status, N'","by":"', @Actor, N'"}'));
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ApplyTenantStatus;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE plat.usp_SetTenantStatus
    @OperatorSessionToken VARBINARY(64),
    @TenantId             INT,
    @Status               VARCHAR(18),
    @Reason               NVARCHAR(500) = NULL,
    @TrialEndsOn          DATE = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM plat.fn_OperatorAdminStepUp(@OperatorSessionToken))
        THROW 50021, 'An operator administrator with an MFA check in the last 5 minutes is required', 1;
    EXEC plat.usp_ApplyTenantStatus @TenantId, @Status, 'OPERATOR', @Reason, @TrialEndsOn;
END;
GO
-- The daily platform jobs (DOC-F05 6.3): trials that ended become SUSPENDED (reason TRIAL_EXPIRED), and tenants
-- closed 30 days ago become ARCHIVED_READ_ONLY. Each tenant in its own transaction; safe to run again.
CREATE OR ALTER PROCEDURE plat.usp_RunTenantTransitions
    @JobKey  VARCHAR(80),
    @Changed INT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @Changed = 0;
    IF @JobKey IS NULL OR @JobKey NOT IN ('JOB-PLT-TRIAL-EXPIRE', 'JOB-PLT-ARCHIVE')
       OR NOT EXISTS (SELECT 1 FROM cfg.JobDefinition WHERE JobKey = @JobKey AND Scope = 'PLATFORM' AND IsActive = 1)
        THROW 50024, 'Not a tenant status job', 1;
    DECLARE @due TABLE (TenantId INT PRIMARY KEY);
    IF @JobKey = 'JOB-PLT-TRIAL-EXPIRE'
        INSERT @due SELECT TenantId FROM plat.Tenant WHERE Status = 'TRIAL' AND TrialEndsOn < CAST(SYSUTCDATETIME() AS DATE);
    ELSE
        INSERT @due SELECT TenantId FROM plat.Tenant WHERE Status = 'CLOSED' AND DATEADD(DAY, 30, ClosedAt) <= SYSUTCDATETIME();
    DECLARE @t INT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT TenantId FROM @due ORDER BY TenantId;
    OPEN c; FETCH NEXT FROM c INTO @t;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @JobKey = 'JOB-PLT-TRIAL-EXPIRE'
            EXEC plat.usp_ApplyTenantStatus @t, 'SUSPENDED', 'JOB', N'TRIAL_EXPIRED';
        ELSE
            EXEC plat.usp_ApplyTenantStatus @t, 'ARCHIVED_READ_ONLY', 'JOB';
        SET @Changed = @Changed + 1;
        FETCH NEXT FROM c INTO @t;
    END;
    CLOSE c; DEALLOCATE c;
END;
GO
GRANT EXECUTE ON plat.usp_CreateTenant TO [tp_platform];
GRANT EXECUTE ON plat.usp_SetTenantStatus TO [tp_platform];
GRANT EXECUTE ON plat.usp_RunTenantTransitions TO [tp_jobs];
GRANT EXECUTE ON sec.usp_InviteFirstAdministrator TO [tp_jobs];
GO
-- A tenant is created and its status changed only through the procedures above (DQ-F05-5). These run after the
-- generated grants (007), which give tp_platform INSERT and UPDATE on plat.Tenant.
DENY INSERT ON [plat].[Tenant] TO [tp_platform];
DENY UPDATE ON [plat].[Tenant]([Code], [Status], [TrialEndsOn], [SuspendedReason], [SuspendedAt], [ActivatedAt], [ClosedAt], [ArchivedAt]) TO [tp_platform];
GO

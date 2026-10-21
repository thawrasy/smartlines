/* ============================================================================
   Creating a tenant and changing its status (db/static/038_tenant_onboarding.sql, ADR 0004, DOC-F05).
   The cases run as the operator panel (tp_platform), the job worker (tp_jobs) and the tenant application (tp_app).

   Run against a deployed BankFas database (with the platform seed) that holds no real data and no operators:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/tenant_onboarding_tests.sql
   One transaction with a savepoint per case, rolled back at the end. Only the country foreign key of plat.Tenant is
   switched off (no countries are seeded yet); every check constraint stays on. The onboarding job's binding is
   written here the way sec.usp_SetJobContext writes it, without read-only keys, so the cases can rebind.
   Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
BEGIN TRANSACTION;
CREATE USER [tp_test_panel] WITHOUT LOGIN;
CREATE USER [tp_test_job] WITHOUT LOGIN;
CREATE USER [tp_test_app] WITHOUT LOGIN;
ALTER ROLE [tp_platform] ADD MEMBER [tp_test_panel];
ALTER ROLE [tp_jobs] ADD MEMBER [tp_test_job];
ALTER ROLE [tp_app] ADD MEMBER [tp_test_app];
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT FK_Tenant_HomeCountryId;
GO
-- #JobBind: binds the connection as a job of a tenant (the service account, kind JOB), like sec.usp_SetJobContext.
CREATE PROCEDURE #JobBind @TenantId INT, @JobKey VARCHAR(80)
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID(), @svc BIGINT;
    MERGE sec.SessionBinding AS b
    USING (SELECT @@SPID AS SessionId) AS s ON b.SessionId = s.SessionId
    WHEN MATCHED THEN UPDATE SET BoundTenantId = @TenantId, BoundUserId = 0, BindingToken = @token, BoundAt = SYSUTCDATETIME(),
                                 BindingKind = 'JOB', BoundOperatorId = NULL
    WHEN NOT MATCHED THEN INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind)
                          VALUES (s.SessionId, @TenantId, 0, @token, 'JOB');
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
    -- bound now, so the tenant's service account is visible
    SELECT TOP (1) @svc = AppUserId FROM sec.AppUser WHERE TenantId = @TenantId AND IsSystemUser = 1 ORDER BY AppUserId;
    UPDATE sec.SessionBinding SET BoundUserId = ISNULL(@svc, 0) WHERE SessionId = @@SPID;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @svc;
    EXEC sys.sp_set_session_context @key = N'JobKey', @value = @JobKey;
END;
GO

DECLARE @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD');
DECLARE @op1 INT, @op2 INT, @t INT, @t2 INT, @admin BIGINT, @admin2 BIGINT, @svc BIGINT, @role BIGINT;
DECLARE @pw1 VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$b3Axcw$b3AxaA', @pw2 VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$b3Aycw$b3AyaA';
DECLARE @sec VARBINARY(256) = CRYPT_GEN_RANDOM(48);
DECLARE @lk1 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @lk2 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @lk3 VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @lk4 VARBINARY(64) = CRYPT_GEN_RANDOM(32);
DECLARE @os1 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @os2 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @tok VARBINARY(64) = CRYPT_GEN_RANDOM(32);
DECLARE @e1 INT, @e2 INT, @e3 INT, @e4 INT, @e5 INT, @e6 INT, @e7 INT, @n INT, @n2 INT, @n3 INT, @n4 INT, @sent NVARCHAR(254),
        @d DATE, @status VARCHAR(18), @changed INT, @x INT;
DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

-- Seed: an operator administrator (op1) and a support operator (op2), both logged in with MFA
EXEC plat.usp_BootstrapOperator @Email = N'op1@test.invalid', @DisplayName = N'Operator 1', @Token = @lk1, @OperatorId = @op1 OUTPUT;
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_CompleteOperatorSetup @Token = @lk1, @NewPasswordHash = @pw1, @MfaSecretEnc = @sec, @MfaKeyRef = 'kms/platform/1', @Step = 100;
EXEC plat.usp_StartOperatorSession @Email = N'op1@test.invalid', @PasswordHash = @pw1, @SessionToken = @os1;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os1, @Passed = 1, @Step = 101;
EXEC plat.usp_InviteOperator @SessionToken = @os1, @Email = N'op2@test.invalid', @DisplayName = N'Support', @Role = 'OPERATOR_SUPPORT', @Token = @lk2, @OperatorId = @op2 OUTPUT;
EXEC plat.usp_CompleteOperatorSetup @Token = @lk2, @NewPasswordHash = @pw2, @MfaSecretEnc = @sec, @MfaKeyRef = 'kms/platform/1', @Step = 200;
EXEC plat.usp_StartOperatorSession @Email = N'op2@test.invalid', @PasswordHash = @pw2, @SessionToken = @os2;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os2, @Passed = 1, @Step = 201;
REVERT;

/* O1: only an operator administrator with an MFA check in the last 5 minutes creates a tenant (50021); a reserved
   code is refused in any letter case (50025); the panel cannot insert a tenant or change its code or status. */
SAVE TRANSACTION o1;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @e4 = NULL, @e5 = NULL, @e6 = NULL;
EXECUTE AS USER = N'tp_test_panel';
BEGIN TRY EXEC plat.usp_CreateTenant @OperatorSessionToken = @os2, @Code = 'acme', @NameAr = N'أ', @NameEn = N'A', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'Asia/Riyadh', @AdminEmail = N'admin@acme.invalid', @AdminDisplayName = N'Admin'; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
UPDATE plat.OperatorSession SET MfaVerifiedAt = DATEADD(MINUTE, -6, SYSUTCDATETIME()) WHERE TokenHash = HASHBYTES('SHA2_256', @os1);
EXECUTE AS USER = N'tp_test_panel';
BEGIN TRY EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'acme', @NameAr = N'أ', @NameEn = N'A', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'Asia/Riyadh', @AdminEmail = N'admin@acme.invalid', @AdminDisplayName = N'Admin'; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os1, @Passed = 1, @Step = 102;      -- step-up again
BEGIN TRY EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'Admin', @NameAr = N'أ', @NameEn = N'A', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'Asia/Riyadh', @AdminEmail = N'admin@acme.invalid', @AdminDisplayName = N'Admin'; END TRY
BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TrialEndsOn, TimeZone)
          VALUES ('direct', N'D', N'D', @plan, 1, 'ACTIVE', @today, 'UTC'); END TRY
BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE plat.Tenant SET Status = 'ACTIVE' WHERE TenantId = -1; END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE plat.Tenant SET Code = 'x' WHERE TenantId = -1; END TRY BEGIN CATCH SET @e6 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM plat.Tenant WHERE Code IN ('acme', 'admin', 'direct');
IF @e1 = 50021 AND @e2 = 50021 AND @e3 = 50025 AND @e4 = 229 AND @e5 = 230 AND @e6 = 230 AND @n = 0
    PRINT 'PASS O1: only an operator administrator with a fresh MFA check creates a tenant, never with a reserved code';
ELSE PRINT 'FAIL O1: tenant creation guards (' + CONCAT(@e1, '/', @e2, '/', @e3, '/', @e4, '/', @e5, '/', @e6, '/', @n) + ')';
ROLLBACK TRANSACTION o1;

/* O2: stage A in one transaction: the tenant in TRIAL for 30 days with a lower-case code, the plan's modules with
   CORE, an active service account, the first administrator INVITED without a password, and tenant.created. The same
   code again is refused (50026), and a failure after the first insert leaves nothing behind. */
SAVE TRANSACTION o2;
SELECT @e1 = NULL, @e2 = NULL, @t = NULL, @admin = NULL;
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = ' NewCo ', @NameAr = N'شركة', @NameEn = N'NewCo', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'Asia/Riyadh', @AdminEmail = N'admin@newco.invalid', @AdminDisplayName = N'Admin',
     @TenantId = @t OUTPUT, @AdminUserId = @admin OUTPUT;
BEGIN TRY EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'NEWCO', @NameAr = N'ب', @NameEn = N'B', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'UTC', @AdminEmail = N'b@b.invalid', @AdminDisplayName = N'B'; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'halfway', @NameAr = N'ب', @NameEn = N'B', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'UTC', @AdminEmail = N'b@b.invalid', @AdminDisplayName = NULL; END TRY   -- the admin row fails
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #JobBind @t, 'JOB-PLT-ONBOARD';                         -- sa reads the new tenant's rows through a binding
SELECT @n = COUNT(*) FROM plat.Tenant WHERE TenantId = @t AND Code = 'newco' AND Status = 'TRIAL' AND TrialEndsOn = DATEADD(DAY, 30, @today);
SELECT @n2 = COUNT(*) FROM plat.TenantModule WHERE TenantId = @t AND IsEnabled = 1;
SELECT @n3 = COUNT(*) FROM sec.AppUser WHERE TenantId = @t
   AND ((IsSystemUser = 1 AND Status = 'ACTIVE') OR (AppUserId = @admin AND Status = 'INVITED' AND PasswordHash IS NULL));
SELECT @n4 = COUNT(*) FROM cfg.OutboxEvent WHERE TenantId = @t AND EventName = 'tenant.created'
   AND JSON_VALUE(PayloadJson, '$.adminUserId') = CAST(@admin AS VARCHAR(20));
SELECT @x = COUNT(*) FROM plat.Tenant WHERE Code = 'halfway';
IF @n = 1 AND @n2 = 9 AND @n3 = 2 AND @n4 = 1 AND @e1 = 50026 AND @e2 = 547 AND @x = 0
    PRINT 'PASS O2: a tenant is created in one transaction with its modules, service account, invited administrator and event';
ELSE PRINT 'FAIL O2: tenant creation (' + CONCAT(@n, '/', @n2, '/', @n3, '/', @n4, '/', @e1, '/', @e2, '/', @x) + ')';
ROLLBACK TRANSACTION o2;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;

/* O3: stage C: the onboarding job invites the first administrator once the system roles exist (50028 before), gives
   the TA role, and replaces an unused link when called again; another job, another user or a second administrator
   is refused; the link then activates the administrator (stage E). */
SAVE TRANSACTION o3;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @e4 = NULL, @e5 = NULL, @t = NULL, @admin = NULL, @sent = NULL;
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'onboard', @NameAr = N'ت', @NameEn = N'Onboard', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'UTC', @AdminEmail = N'admin@onboard.invalid', @AdminDisplayName = N'Admin',
     @TenantId = @t OUTPUT, @AdminUserId = @admin OUTPUT;
REVERT;
EXEC #JobBind @t, 'JOB-PLT-ONBOARD';
EXECUTE AS USER = N'tp_test_job';
BEGIN TRY EXEC sec.usp_InviteFirstAdministrator @UserId = @admin, @Token = @lk3; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
-- stage B: the onboarding job seeds the system roles with the pack CORE.ROLES (057, ADR 0035)
EXECUTE AS USER = N'tp_test_job';
EXEC sec.usp_SeedCoreRoles;
REVERT;
SELECT @role = RoleId FROM sec.Role WHERE TenantId = @t AND Code = 'TA';
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status) VALUES (@t, N'other@onboard.invalid', N'Other', 'INVITED');
SELECT @admin2 = AppUserId FROM sec.AppUser WHERE TenantId = @t AND Email = N'other@onboard.invalid';
EXECUTE AS USER = N'tp_test_job';
EXEC sec.usp_InviteFirstAdministrator @UserId = @admin, @Token = @lk3, @SentTo = @sent OUTPUT;
EXEC sec.usp_InviteFirstAdministrator @UserId = @admin, @Token = @lk4;                         -- a new e-mail
BEGIN TRY EXEC sec.usp_InviteFirstAdministrator @UserId = @admin2, @Token = @tok; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #JobBind @t, 'JOB-WFL-SLA';
EXECUTE AS USER = N'tp_test_job';
BEGIN TRY EXEC sec.usp_InviteFirstAdministrator @UserId = @admin, @Token = @tok; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
REVERT;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_CompleteInvitation @TenantId = @t, @Token = @lk3, @NewPasswordHash = @pw1; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_CompleteInvitation @TenantId = @t, @Token = @lk4, @NewPasswordHash = @pw1;
REVERT;
SELECT @n = COUNT(*) FROM sec.UserRole WHERE TenantId = @t AND RoleId = @role;
SELECT @n2 = COUNT(*) FROM sec.UserToken WHERE TenantId = @t AND UserId = @admin AND Purpose = 'INVITATION' AND RevokedAt IS NOT NULL;
SELECT @n3 = COUNT(*) FROM sec.AppUser WHERE AppUserId = @admin AND Status = 'ACTIVE';
IF @e1 = 50028 AND @sent = N'admin@onboard.invalid' AND @e2 = 50028 AND @e3 = 50003 AND @e4 = 50017 AND @n = 1 AND @n2 = 1 AND @n3 = 1
    PRINT 'PASS O3: the onboarding job invites one first administrator with the TA role, and the latest link activates it';
ELSE PRINT 'FAIL O3: first administrator invitation (' + CONCAT(@e1, '/', @sent, '/', @e2, '/', @e3, '/', @e4, '/', @n, '/', @n2, '/', @n3) + ')';
ROLLBACK TRANSACTION o3;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'JobKey', @value = NULL;

/* O4: the operator's status changes follow DOC-F05 6.2: TRIAL to ACTIVE sets ActivatedAt; suspending needs a reason,
   sets SuspendedAt and ends the sessions of users the status no longer admits; SUSPENDED to TRIAL needs a new end
   date; SUSPENDED to ACTIVE clears the suspension; closing an active tenant waits for the export (50027); a cancelled
   onboarding (TRIAL) closes; CLOSED never returns to ACTIVE (50019). */
SAVE TRANSACTION o4;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @e4 = NULL, @e5 = NULL, @t = NULL, @t2 = NULL, @admin = NULL;
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'life', @NameAr = N'ح', @NameEn = N'Life', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'UTC', @AdminEmail = N'admin@life.invalid', @AdminDisplayName = N'Admin',
     @TenantId = @t OUTPUT, @AdminUserId = @admin OUTPUT;
EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'cancelled', @NameAr = N'ل', @NameEn = N'Cancelled', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'UTC', @AdminEmail = N'admin@cancelled.invalid', @AdminDisplayName = N'Admin', @TenantId = @t2 OUTPUT;
EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t, @Status = 'ACTIVE';
REVERT;
EXEC #JobBind @t, 'JOB-WFL-SLA';
SELECT @svc = AppUserId FROM sec.AppUser WHERE TenantId = @t AND IsSystemUser = 1;
INSERT sec.UserSession (TenantId, UserId, TokenHash, IdleExpiresAt, AbsoluteExpiresAt)       -- a session of the service account
VALUES (@t, @svc, HASHBYTES('SHA2_256', @tok), DATEADD(MINUTE, 30, SYSUTCDATETIME()), DATEADD(HOUR, 12, SYSUTCDATETIME()));
EXECUTE AS USER = N'tp_test_panel';
BEGIN TRY EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t, @Status = 'SUSPENDED'; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t, @Status = 'SUSPENDED', @Reason = N'Unpaid';
SELECT @n = COUNT(*) FROM plat.Tenant WHERE TenantId = @t AND Status = 'SUSPENDED' AND SuspendedAt IS NOT NULL AND ActivatedAt IS NOT NULL;
REVERT;
EXEC #JobBind @t, 'JOB-PLT-EXPORT-EXPIRE';                   -- the suspension removed the binding; read again
SELECT @n2 = COUNT(*) FROM sec.UserSession WHERE TenantId = @t AND EndReason = 'TENANT_SUSPENDED';
EXECUTE AS USER = N'tp_test_panel';
BEGIN TRY EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t, @Status = 'TRIAL', @TrialEndsOn = @today; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
SET @d = DATEADD(DAY, 14, @today);
EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t, @Status = 'TRIAL', @TrialEndsOn = @d;
EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t, @Status = 'ACTIVE';
SELECT @n3 = COUNT(*) FROM plat.Tenant WHERE TenantId = @t AND Status = 'ACTIVE' AND SuspendedAt IS NULL AND SuspendedReason IS NULL AND TrialEndsOn = @d;
BEGIN TRY EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t, @Status = 'CLOSED', @Reason = N'End'; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t2, @Status = 'CLOSED', @Reason = N'Onboarding cancelled';
BEGIN TRY EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t2, @Status = 'ACTIVE'; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
SELECT @status = Status FROM plat.Tenant WHERE TenantId = @t2;
REVERT;
EXEC #JobBind @t, 'JOB-WFL-SLA';
SELECT @n4 = COUNT(*) FROM cfg.OutboxEvent WHERE TenantId = @t AND EventName = 'tenant.status_changed';
IF @e1 = 50001 AND @n = 1 AND @n2 = 1 AND @e2 = 50001 AND @n3 = 1 AND @e3 = 50027 AND @status = 'CLOSED' AND @e4 = 50019 AND @n4 = 4
    PRINT 'PASS O4: operator status changes follow the transition table, end sessions on suspension and wait for the export to close';
ELSE PRINT 'FAIL O4: tenant status changes (' + CONCAT(@e1, '/', @n, '/', @n2, '/', @e2, '/', @n3, '/', @e3, '/', @status, '/', @e4, '/', @n4) + ')';
ROLLBACK TRANSACTION o4;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;

/* O5: the daily platform jobs: an ended trial becomes SUSPENDED (TRIAL_EXPIRED), a tenant closed 30 days ago becomes
   ARCHIVED_READ_ONLY; tenants not yet due are untouched; a second run changes nothing; only the job worker runs it,
   and only for these two jobs (50024). */
SAVE TRANSACTION o5;
SELECT @e1 = NULL, @e2 = NULL, @t = NULL, @t2 = NULL, @changed = NULL;
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'expired', @NameAr = N'م', @NameEn = N'Expired', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'UTC', @AdminEmail = N'admin@expired.invalid', @AdminDisplayName = N'Admin', @TenantId = @t OUTPUT;
EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'oldclosed', @NameAr = N'ق', @NameEn = N'Old', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'UTC', @AdminEmail = N'admin@old.invalid', @AdminDisplayName = N'Admin', @TenantId = @t2 OUTPUT;
EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t2, @Status = 'CLOSED', @Reason = N'Cancelled';
BEGIN TRY EXEC plat.usp_RunTenantTransitions @JobKey = 'JOB-PLT-TRIAL-EXPIRE'; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
UPDATE plat.Tenant SET TrialEndsOn = DATEADD(DAY, -1, @today) WHERE TenantId = @t;
UPDATE plat.Tenant SET ClosedAt = DATEADD(DAY, -31, SYSUTCDATETIME()) WHERE TenantId = @t2;
EXECUTE AS USER = N'tp_test_job';
EXEC plat.usp_RunTenantTransitions @JobKey = 'JOB-PLT-TRIAL-EXPIRE', @Changed = @n OUTPUT;
EXEC plat.usp_RunTenantTransitions @JobKey = 'JOB-PLT-ARCHIVE', @Changed = @n2 OUTPUT;
EXEC plat.usp_RunTenantTransitions @JobKey = 'JOB-PLT-TRIAL-EXPIRE', @Changed = @n3 OUTPUT;
BEGIN TRY EXEC plat.usp_RunTenantTransitions @JobKey = 'JOB-WFL-SLA'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n4 = COUNT(*) FROM plat.Tenant
 WHERE (TenantId = @t AND Status = 'SUSPENDED' AND SuspendedReason = N'TRIAL_EXPIRED')
    OR (TenantId = @t2 AND Status = 'ARCHIVED_READ_ONLY' AND ArchivedAt = DATEADD(DAY, 30, ClosedAt));
IF @e1 = 229 AND @n >= 1 AND @n2 >= 1 AND @n3 = 0 AND @e2 = 50024 AND @n4 = 2
    PRINT 'PASS O5: the daily jobs suspend ended trials and archive closed tenants, once';
ELSE PRINT 'FAIL O5: tenant transition jobs (' + CONCAT(@e1, '/', @n, '/', @n2, '/', @n3, '/', @e2, '/', @n4) + ')';
ROLLBACK TRANSACTION o5;

/* O6: an operator extends a trial while the tenant is still in TRIAL (GAP-10): a later end date is accepted and
   audited with the old one, an end date that is not later is refused (50001). */
SAVE TRANSACTION o6;
SELECT @e1 = NULL, @t = NULL, @n = NULL, @n2 = NULL;
SET @d = DATEADD(DAY, 45, @today);
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'extend', @NameAr = N'ت', @NameEn = N'Extend', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'UTC', @AdminEmail = N'admin@extend.invalid', @AdminDisplayName = N'Admin', @TenantId = @t OUTPUT;
EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t, @Status = 'TRIAL', @TrialEndsOn = @d;
SET @d = DATEADD(DAY, 40, @today);
BEGIN TRY EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t, @Status = 'TRIAL', @TrialEndsOn = @d; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
SELECT @n2 = COUNT(AuditLogId) FROM aud.AuditLog                -- a platform row: the panel reads it, as the row filter says
 WHERE Action = 'TENANT_STATUS_CHANGED' AND EntityId = @t
   AND JSON_VALUE(BeforeJson, '$.trialEndsOn') = CONVERT(CHAR(10), DATEADD(DAY, 30, @today), 23)
   AND JSON_VALUE(AfterJson, '$.trialEndsOn') = CONVERT(CHAR(10), DATEADD(DAY, 45, @today), 23);
REVERT;
SELECT @n = COUNT(*) FROM plat.Tenant WHERE TenantId = @t AND Status = 'TRIAL' AND TrialEndsOn = DATEADD(DAY, 45, @today);
IF @n = 1 AND @n2 = 1 AND @e1 = 50001
    PRINT 'PASS O6: an operator extends a running trial to a later date only, and the old date is audited';
ELSE PRINT 'FAIL O6: trial extension (' + CONCAT(@n, '/', @n2, '/', @e1) + ')';
ROLLBACK TRANSACTION o6;

/* O7: the panel reads a tenant's counters, never its data (FR-PLT-005, GAP-9), and an operator administrator sends
   the first administrator's invitation again while it is unused: the onboarding event is pending again. Once the
   administrator is active it is refused (50016); without an administrator session too (50021). */
SAVE TRANSACTION o7;
SELECT @e1 = NULL, @e2 = NULL, @t = NULL, @admin = NULL;
DECLARE @cnt TABLE (UsersActive INT, UsersInvited INT, UsersBlocked INT, Roles INT, FirstAdminStatus VARCHAR(10), OnboardingStatus VARCHAR(10),
                    InvitationSendStatus VARCHAR(10), PacksSeeded INT, LastLoginAt DATETIME2(3));
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'counted', @NameAr = N'ع', @NameEn = N'Counted', @PlanId = @plan,
     @HomeCountryId = 1, @TimeZone = 'UTC', @AdminEmail = N'admin@counted.invalid', @AdminDisplayName = N'Admin',
     @TenantId = @t OUTPUT, @AdminUserId = @admin OUTPUT;
INSERT @cnt EXEC plat.usp_GetTenantCounters @SessionToken = @os1, @TenantId = @t;
REVERT;
EXEC #JobBind @t, 'JOB-PLT-ONBOARD';                      -- the tenant's rows are under the row filters, also for sa
UPDATE cfg.OutboxEvent SET Status = 'DELIVERED', DeliveredAt = SYSUTCDATETIME() WHERE TenantId = @t AND EventName = 'tenant.created';
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_ResendFirstAdminInvitation @SessionToken = @os1, @TenantId = @t;
BEGIN TRY EXEC plat.usp_ResendFirstAdminInvitation @SessionToken = 0x00, @TenantId = @t; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM cfg.OutboxEvent WHERE TenantId = @t AND EventName = 'tenant.created' AND Status = 'PENDING' AND DeliveredAt IS NULL;
ALTER TABLE sec.AppUser DISABLE TRIGGER ALL;
UPDATE sec.AppUser SET Status = 'ACTIVE', PasswordHash = @pw1 WHERE AppUserId = @admin;
ALTER TABLE sec.AppUser ENABLE TRIGGER ALL;
EXECUTE AS USER = N'tp_test_panel';
BEGIN TRY EXEC plat.usp_ResendFirstAdminInvitation @SessionToken = @os1, @TenantId = @t; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
IF EXISTS (SELECT 1 FROM @cnt WHERE UsersInvited = 1 AND UsersActive = 0 AND FirstAdminStatus = 'INVITED' AND OnboardingStatus = 'PENDING')
   AND @n = 1 AND @e1 = 50016 AND @e2 = 50021
    PRINT 'PASS O7: the panel reads a tenant''s counters and sends the first invitation again while it is unused';
ELSE
BEGIN
    DECLARE @cntText NVARCHAR(100) = (SELECT TOP (1) CONCAT(UsersInvited, '/', FirstAdminStatus, '/', OnboardingStatus) FROM @cnt);
    PRINT 'FAIL O7: tenant counters or resend (' + CONCAT(@n, '/', @e1, '/', @e2, '/', @cntText) + ')';
END;
ROLLBACK TRANSACTION o7;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'JobKey', @value = NULL;

ROLLBACK TRANSACTION;
GO
PRINT 'Tenant onboarding tests finished; every change is rolled back.';
GO

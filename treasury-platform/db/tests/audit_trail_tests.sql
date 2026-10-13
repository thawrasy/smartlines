/* ============================================================================
   Audit rows written by the database (db/static/029_audit_writer.sql and the procedures of 035 to 038; ADR 0007;
   FR-PLT-022, BR-PLT-009, O-25, DQ-F03-10). The flows run as the tenant application (tp_app), the operator panel
   (tp_platform) and the job worker (tp_jobs); the checks read the log as a test reader in tp_auth, which the row filters let see every row.
   The support and job bindings are checked in operator_support_tests.sql (P11) and job_context_tests.sql (J7),
   because a real binding makes the context read-only.

   Run against a deployed BankFas database (with the platform seed) that holds no real data and no operators:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/audit_trail_tests.sql
   One transaction, rolled back at the end. Each check prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
BEGIN TRANSACTION;
CREATE USER [tp_test_aapp] WITHOUT LOGIN;
CREATE USER [tp_test_apanel] WITHOUT LOGIN;
CREATE USER [tp_test_ajob] WITHOUT LOGIN;
CREATE USER [tp_test_aread] WITHOUT LOGIN;
ALTER ROLE [tp_app] ADD MEMBER [tp_test_aapp];
ALTER ROLE [tp_platform] ADD MEMBER [tp_test_apanel];
ALTER ROLE [tp_jobs] ADD MEMBER [tp_test_ajob];
ALTER ROLE [tp_auth] ADD MEMBER [tp_test_aread];          -- the row filters let tp_auth read every audit row
ALTER ROLE [db_datareader] ADD MEMBER [tp_test_aread];    -- tp_auth itself has no right on aud.AuditLog
ALTER TABLE sec.AppUser NOCHECK CONSTRAINT ALL;      -- the tenant key of the MFA secret is not seeded
GO
-- #Bind: binds the connection to a tenant and a user like the binding procedure, without read-only keys.
CREATE PROCEDURE #Bind @TenantId INT, @UserId BIGINT, @Kind VARCHAR(7) = 'USER', @JobKey VARCHAR(80) = NULL
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind)
    VALUES (@@SPID, @TenantId, @UserId, @token, @Kind);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @UserId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
    EXEC sys.sp_set_session_context @key = N'JobKey', @value = @JobKey;
END;
GO

DECLARE @t INT, @t2 INT, @adm BIGINT, @usr BIGINT, @admPid UNIQUEIDENTIFIER, @usrPid UNIQUEIDENTIFIER, @op1 INT, @op2 INT, @opPid UNIQUEIDENTIFIER,
        @admin2 BIGINT, @svc2 BIGINT, @svcPid UNIQUEIDENTIFIER, @usid BIGINT, @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'),
        @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA');
DECLARE @phcA VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$YWRtaW5zYWx0$YWRtaW5oYXNo',
        @phcU VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$dXNyc2FsdA$dXNyaGFzaA',
        @phcNew VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$bmV3c2FsdA$bmV3aGFzaA',
        @phcBad VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$YmFk$YmFk',
        @pwOp VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$b3Axcw$b3AxaA';
DECLARE @secret VARBINARY(256) = CRYPT_GEN_RANDOM(48);
DECLARE @sA VARBINARY(64) = CRYPT_GEN_RANDOM(32), @sU VARBINARY(64) = CRYPT_GEN_RANDOM(32), @sX VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @lnk VARBINARY(64) = CRYPT_GEN_RANDOM(32), @lnk2 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @lk1 VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @lk2 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @lk3 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @os1 VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @osBad VARBINARY(64) = CRYPT_GEN_RANDOM(32);
DECLARE @i INT, @e INT, @n INT, @n2 INT, @n3 INT, @n4 INT, @n5 INT, @n6 INT, @n7 INT, @n8 INT, @n9 INT, @before INT, @after INT;

-- Seed: one active tenant with an administrator and a user, both with a password and MFA.
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('tst-audit', N'ت', N'Audit', @plan, @country, 'ACTIVE', 'UTC');
SET @t = SCOPE_IDENTITY();
EXEC #Bind @t, 0;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash, MfaEnabled, MfaSecretEnc, MfaKeyId, MfaEnrolledAt)
VALUES (@t, N'adm@audit.invalid', N'Admin', 'ACTIVE', @phcA, 1, @secret, 1, SYSUTCDATETIME()),
       (@t, N'usr@audit.invalid', N'User', 'ACTIVE', @phcU, 1, @secret, 1, SYSUTCDATETIME());
SELECT @adm = AppUserId, @admPid = PublicId FROM sec.AppUser WHERE TenantId = @t AND Email = N'adm@audit.invalid';
SELECT @usr = AppUserId, @usrPid = PublicId FROM sec.AppUser WHERE TenantId = @t AND Email = N'usr@audit.invalid';
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;

/* Flow 1, before any binding, as the application: five wrong passwords lock the user, a sixth try is refused, an
   unknown address fails, the administrator logs in and then fails one TOTP code before passing. */
EXECUTE AS USER = N'tp_test_aapp';
SET @i = 1;
WHILE @i <= 6
BEGIN
    BEGIN TRY EXEC sec.usp_StartSession @TenantId = @t, @Email = N'usr@audit.invalid', @PasswordHash = @phcBad, @SessionToken = @sX,
                   @ClientIp = '198.51.100.9'; END TRY BEGIN CATCH END CATCH;
    SET @i = @i + 1;
END;
BEGIN TRY EXEC sec.usp_StartSession @TenantId = @t, @Email = N'nobody@audit.invalid', @PasswordHash = @phcBad, @SessionToken = @sX; END TRY BEGIN CATCH END CATCH;
EXEC sec.usp_StartSession @TenantId = @t, @Email = N'adm@audit.invalid', @PasswordHash = @phcA, @SessionToken = @sA,
     @ClientIp = '198.51.100.7', @UserAgent = N'TestBrowser/1.0';
EXEC sec.usp_ConfirmMfa @TenantId = @t, @SessionToken = @sA, @Passed = 0, @ClientIp = '198.51.100.7';
EXEC sec.usp_ConfirmMfa @TenantId = @t, @SessionToken = @sA, @Passed = 1, @ClientIp = '198.51.100.7', @Step = 500;
REVERT;

EXECUTE AS USER = N'tp_test_aread';
SELECT @n  = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'FAILED_PASSWORD' AND ActorId = @usrPid AND Result = 'FAILED'
                                          AND Category = 'SECURITY' AND IpAddress = '198.51.100.9' AND EntityId = @usr;
SELECT @n2 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'LOCKOUT' AND ActorId = @usrPid AND Result = 'DENIED';
SELECT @n3 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'DENIED_LOCKED' AND ActorId = @usrPid AND Result = 'DENIED';
SELECT @n4 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'FAILED_PASSWORD' AND ActorId IS NULL AND EntityId IS NULL;
SELECT @n5 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'LOGIN_SUCCESS' AND ActorId = @admPid AND Result = 'SUCCESS'
                                          AND IpAddress = '198.51.100.7' AND UserAgent = N'TestBrowser/1.0';
SELECT @n6 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'FAILED_MFA' AND ActorId = @admPid AND Result = 'FAILED';
REVERT;
IF @n = 5 AND @n2 = 1 AND @n3 = 1 AND @n4 = 1 AND @n5 = 1 AND @n6 = 1
    PRINT 'PASS AU1: every login attempt is audited: wrong passwords, the lockout, a locked try, an unknown address (no actor), a success and a TOTP failure';
ELSE PRINT CONCAT('FAIL AU1: login audit rows ', @n, '/', @n2, '/', @n3, '/', @n4, '/', @n5, '/', @n6);

/* AU2 (R6 of O-24): the application may delete login attempts, but their audit rows stay, and it can neither
   delete nor change an audit row. */
EXEC #Bind @t, @adm;
EXECUTE AS USER = N'tp_test_aread';
SELECT @before = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t;
REVERT;
SELECT @e = NULL, @n2 = NULL, @n3 = NULL;
EXECUTE AS USER = N'tp_test_aapp';
DELETE FROM sec.LoginAttempt WHERE TenantId = @t;
SET @n = @@ROWCOUNT;
BEGIN TRY DELETE FROM aud.AuditLog WHERE TenantId = @t; END TRY BEGIN CATCH SET @n2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE aud.AuditLog SET Result = 'SUCCESS' WHERE TenantId = @t; END TRY BEGIN CATCH SET @n3 = ERROR_NUMBER(); END CATCH;
REVERT;
EXECUTE AS USER = N'tp_test_aread';
SELECT @after = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t;
REVERT;
IF @n >= 9 AND @before >= 10 AND @after = @before AND @n2 = 229 AND @n3 = 229
    PRINT 'PASS AU2: deleting login attempts leaves their audit rows, which the application cannot delete or change';
ELSE PRINT CONCAT('FAIL AU2: attempts deleted ', @n, ', audit rows ', @before, ' then ', @after, ', errors ', @n2, ' ', @n3);

/* Flow 3, bound as the administrator: unlock the user, who logs in; end that session; reset the user's MFA and send
   a re-enrolment link; disable the user. */
EXECUTE AS USER = N'tp_test_aapp';
EXEC sec.usp_UnlockUser @TenantId = @t, @UserId = @usr;
EXEC sec.usp_StartSession @TenantId = @t, @Email = N'usr@audit.invalid', @PasswordHash = @phcU, @SessionToken = @sU;
REVERT;
SELECT @usid = UserSessionId FROM sec.UserSession WHERE TenantId = @t AND UserId = @usr AND EndedAt IS NULL;
EXECUTE AS USER = N'tp_test_aapp';
EXEC sec.usp_EndSession @TenantId = @t, @UserSessionId = @usid;
EXEC sec.usp_ResetMfa @TenantId = @t, @UserId = @usr;
EXEC sec.usp_IssueUserToken @TenantId = @t, @UserId = @usr, @Purpose = 'MFA_REENROLMENT', @Token = @lnk2;
EXEC sec.usp_SetUserStatus @TenantId = @t, @UserId = @usr, @Status = 'DISABLED';
REVERT;
EXECUTE AS USER = N'tp_test_aread';
SELECT @n  = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'USER_UNLOCKED' AND ActorId = @admPid AND EntityId = @usr;
SELECT @n2 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'SESSION_TERMINATED' AND ActorId = @admPid
                                          AND EntityType = 'sec.UserSession' AND EntityId = @usid;
SELECT @n3 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'MFA_RESET' AND ActorId = @admPid AND EntityId = @usr AND Severity = 'HIGH';
SELECT @n4 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'LINK_ISSUED' AND ActorId = @admPid AND EntityId = @usr
                                          AND JSON_VALUE(AfterJson, '$.purpose') = 'MFA_REENROLMENT';
SELECT @n5 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'USER_STATUS_CHANGED' AND ActorId = @admPid AND EntityId = @usr
                                          AND JSON_VALUE(BeforeJson, '$.status') = 'ACTIVE' AND JSON_VALUE(AfterJson, '$.status') = 'DISABLED';
REVERT;
IF @n = 1 AND @n2 = 1 AND @n3 = 1 AND @n4 = 1 AND @n5 = 1
    PRINT 'PASS AU3: administrator actions are audited with the administrator as actor: unlock, session end, MFA reset (high), link, status';
ELSE PRINT CONCAT('FAIL AU3: administrator audit rows ', @n, '/', @n2, '/', @n3, '/', @n4, '/', @n5);

/* Flow 4, the administrator's own account: logout, then a reset link requested anonymously and used. */
EXECUTE AS USER = N'tp_test_aapp';
EXEC sec.usp_EndSession @TenantId = @t, @SessionToken = @sA;
EXEC sec.usp_RequestPasswordReset @TenantId = @t, @Email = N'adm@audit.invalid', @Token = @lnk, @ClientIp = '203.0.113.4';
EXEC sec.usp_RequestPasswordReset @TenantId = @t, @Email = N'nobody@audit.invalid', @Token = @lk3;
EXEC sec.usp_ResetPassword @TenantId = @t, @Token = @lnk, @NewPasswordHash = @phcNew,
     @Candidates = N'["$argon2id$v=19$m=65536,t=3,p=4$YWRtaW5zYWx0$b3RoZXJoYXNo"]';
REVERT;
EXECUTE AS USER = N'tp_test_aread';
SELECT @n  = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'LOGOUT' AND ActorId = @admPid AND EntityType = 'sec.UserSession';
SELECT @n2 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'PASSWORD_RESET_REQUESTED' AND ActorId IS NULL AND EntityId = @adm
                                          AND IpAddress = '203.0.113.4';
SELECT @n3 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'PASSWORD_RESET_REQUESTED';
SELECT @n4 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'PASSWORD_RESET' AND ActorId = @admPid;
REVERT;
IF @n = 1 AND @n2 = 1 AND @n3 = 1 AND @n4 = 1
    PRINT 'PASS AU4: logout and a password reset are audited; a reset asked for an unknown address writes nothing';
ELSE PRINT CONCAT('FAIL AU4: self-service audit rows ', @n, '/', @n2, '/', @n3, '/', @n4);

/* Flow 5, the operators: the first operator is bootstrapped and sets up the account, fails a password and a TOTP
   code, logs in, invites a second operator and disables that invitation. */
EXEC plat.usp_BootstrapOperator @Email = N'op1@audit.invalid', @DisplayName = N'Operator 1', @Token = @lk1, @OperatorId = @op1 OUTPUT;
SELECT @opPid = PublicId FROM plat.PlatformOperator WHERE PlatformOperatorId = @op1;
EXECUTE AS USER = N'tp_test_apanel';
EXEC plat.usp_CompleteOperatorSetup @Token = @lk1, @NewPasswordHash = @pwOp, @MfaSecretEnc = @secret, @MfaKeyRef = 'kms/platform/1', @Step = 100;
BEGIN TRY EXEC plat.usp_StartOperatorSession @Email = N'op1@audit.invalid', @PasswordHash = @phcBad, @SessionToken = @osBad,
               @ClientIp = '192.0.2.10'; END TRY BEGIN CATCH END CATCH;
EXEC plat.usp_StartOperatorSession @Email = N'op1@audit.invalid', @PasswordHash = @pwOp, @SessionToken = @os1, @ClientIp = '192.0.2.10';
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os1, @Passed = 0;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os1, @Passed = 1, @Step = 101;
EXEC plat.usp_InviteOperator @SessionToken = @os1, @Email = N'op2@audit.invalid', @DisplayName = N'Support', @Role = 'OPERATOR_SUPPORT',
     @Token = @lk2, @OperatorId = @op2 OUTPUT;
EXEC plat.usp_SetOperatorStatus @SessionToken = @os1, @OperatorId = @op2, @Status = 'DISABLED';
REVERT;
EXECUTE AS USER = N'tp_test_aread';
SELECT @n  = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'OPERATOR_BOOTSTRAPPED' AND ActorType = 'SYSTEM' AND Severity = 'HIGH' AND EntityId = @op1;
SELECT @n2 = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'OPERATOR_SETUP_COMPLETED' AND ActorId = @opPid;
SELECT @n3 = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'OPERATOR_LOGIN_FAILED' AND ActorId = @opPid AND Result = 'FAILED' AND IpAddress = '192.0.2.10';
SELECT @n4 = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'OPERATOR_LOGIN_SUCCESS' AND ActorId = @opPid AND IpAddress = '192.0.2.10';
SELECT @n5 = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'OPERATOR_MFA_FAILED' AND ActorId = @opPid;
SELECT @n6 = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'OPERATOR_INVITED' AND ActorId = @opPid AND EntityId = @op2
                                          AND Severity = 'HIGH' AND JSON_VALUE(AfterJson, '$.role') = 'OPERATOR_SUPPORT';
SELECT @n7 = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'OPERATOR_STATUS_CHANGED' AND ActorId = @opPid AND EntityId = @op2
                                          AND JSON_VALUE(BeforeJson, '$.status') = 'INVITED' AND JSON_VALUE(AfterJson, '$.status') = 'DISABLED';
REVERT;
IF @n = 1 AND @n2 = 1 AND @n3 = 1 AND @n4 = 1 AND @n5 = 1 AND @n6 = 1 AND @n7 = 1
    PRINT 'PASS AU5: operator accounts and logins are audited as platform rows: bootstrap, setup, failures, login, invitation, status';
ELSE PRINT CONCAT('FAIL AU5: operator audit rows ', @n, '/', @n2, '/', @n3, '/', @n4, '/', @n5, '/', @n6, '/', @n7);

/* Flow 6, a tenant's life: created by the operator, its first administrator invited by the onboarding job, then
   activated and suspended. */
EXECUTE AS USER = N'tp_test_apanel';
EXEC plat.usp_CreateTenant @OperatorSessionToken = @os1, @Code = 'auditnew', @NameAr = N'ج', @NameEn = N'New', @PlanId = @plan,
     @HomeCountryId = @country, @TimeZone = 'UTC', @AdminEmail = N'admin@auditnew.invalid', @AdminDisplayName = N'Admin',
     @TenantId = @t2 OUTPUT, @AdminUserId = @admin2 OUTPUT;
REVERT;
EXEC #Bind @t2, 0;
-- the CORE.ROLES pack (application code) seeds the system roles; here only TA
INSERT sec.Role (TenantId, Code, NameAr, NameEn, IsSystem, SeedKey) VALUES (@t2, 'TA', N'مدير الحساب', N'Tenant administrator', 1, 'ROLE.TA');
SELECT @svc2 = AppUserId, @svcPid = PublicId FROM sec.AppUser WHERE TenantId = @t2 AND IsSystemUser = 1;
EXEC #Bind @t2, @svc2, 'JOB', 'JOB-PLT-ONBOARD';
EXECUTE AS USER = N'tp_test_ajob';
EXEC sec.usp_InviteFirstAdministrator @UserId = @admin2, @Token = @lk3;
REVERT;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXECUTE AS USER = N'tp_test_apanel';
EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t2, @Status = 'ACTIVE';
EXEC plat.usp_SetTenantStatus @OperatorSessionToken = @os1, @TenantId = @t2, @Status = 'SUSPENDED', @Reason = N'Unpaid "invoice"';
EXEC plat.usp_EndOperatorSession @SessionToken = @os1;
REVERT;
EXECUTE AS USER = N'tp_test_aread';
SELECT @n  = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'TENANT_CREATED' AND ActorId = @opPid AND EntityType = 'plat.Tenant'
                                          AND EntityId = @t2 AND JSON_VALUE(AfterJson, '$.code') = 'auditnew';
SELECT @n2 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t2 AND Action = 'FIRST_ADMIN_INVITED' AND ActorType = 'JOB' AND ActorId = @svcPid
                                          AND EntityId = @admin2 AND Severity = 'HIGH' AND Category = 'CONFIG';
SELECT @n3 = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'TENANT_STATUS_CHANGED' AND EntityId = @t2 AND ActorId = @opPid
                                          AND JSON_VALUE(AfterJson, '$.status') = 'ACTIVE' AND Severity = 'INFO';
SELECT @n4 = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'TENANT_STATUS_CHANGED' AND EntityId = @t2 AND Severity = 'HIGH'
                                          AND JSON_VALUE(BeforeJson, '$.status') = 'ACTIVE' AND JSON_VALUE(AfterJson, '$.status') = 'SUSPENDED'
                                          AND JSON_VALUE(AfterJson, '$.reason') = N'Unpaid "invoice"';
SELECT @n5 = COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = 'OPERATOR_LOGOUT' AND ActorId = @opPid;
REVERT;
IF @n = 1 AND @n2 = 1 AND @n3 = 1 AND @n4 = 1 AND @n5 = 1
    PRINT 'PASS AU6: tenant creation, the first administrator''s invitation (high, by the job) and status changes are audited';
ELSE PRINT CONCAT('FAIL AU6: tenant life audit rows ', @n, '/', @n2, '/', @n3, '/', @n4, '/', @n5);

/* AU7: a tenant reads its own rows and no platform row; the operator panel reads platform rows and no tenant row; no
   row holds an e-mail address, a password hash or a token. */
EXEC #Bind @t, @adm;
EXECUTE AS USER = N'tp_test_aapp';
SELECT @n = COUNT(AuditLogId), @n2 = SUM(CASE WHEN TenantId IS NULL OR TenantId <> @t THEN 1 ELSE 0 END) FROM aud.AuditLog;
REVERT;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXECUTE AS USER = N'tp_test_apanel';
SELECT @n3 = COUNT(AuditLogId), @n4 = SUM(CASE WHEN TenantId IS NOT NULL THEN 1 ELSE 0 END) FROM aud.AuditLog;
REVERT;
EXECUTE AS USER = N'tp_test_aread';
SELECT @n5 = COUNT(*) FROM aud.AuditLog
 WHERE CONCAT(BeforeJson, AfterJson, UserAgent) LIKE '%@%' OR CONCAT(BeforeJson, AfterJson) LIKE '%argon2%';
REVERT;
IF @n = 19 AND @n2 = 0 AND @n3 = 11 AND @n4 = 0 AND @n5 = 0
    PRINT 'PASS AU7: a tenant reads only its own audit rows, the operators only the platform rows, and no row holds an address or a hash';
ELSE PRINT CONCAT('FAIL AU7: tenant sees ', @n, ' (', @n2, ' foreign), panel sees ', @n3, ' (', @n4, ' tenant), leaking rows ', @n5);

ROLLBACK TRANSACTION;
GO
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'UserId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'JobKey', @value = NULL;
PRINT 'Audit trail tests finished; every change is rolled back.';
GO

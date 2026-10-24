/* ============================================================================
   Account-security flow tests (ADR 0003, db/static/035_account_security.sql, owner decisions of 2026-10-12).
   Each case drives the procedures as the application role (tp_app) the way the application will: invitation,
   first MFA enrolment, TOTP replay and failures, recovery codes, password change and reset with the history rule,
   administrator actions, sessions, and the guard on direct user inserts.

   Run against a deployed BankFas database that holds no real data, with a sysadmin login (CI uses sa):
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/auth_flow_tests.sql
   A1 runs first in its own transaction, because an error raised in a trigger ends the transaction it runs in.
   S1 and S2 (tenant setting bounds, also a trigger) follow in their own transactions. Cases A2-A13 and S3-S6 then run
   in one transaction with a savepoint each, rolled back at the end, then A15-A17 (the challenge key and step-up,
   the outcome of an MFA check, the password rules before binding); A14 binds the connection for real, which makes
   its context read-only, so it is the last case. S cases cover the tenant security settings (DQ-S03-6, DQ-S04-14).
   Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
/* A1: the application role cannot create a user that already has a password, MFA or lockout state (50012); the
   error comes from a trigger and ends the transaction, so this case has its own and runs first. An invited user
   without a password is accepted. */
SET NOCOUNT ON;
DECLARE @e INT, @ok INT;
BEGIN TRANSACTION;
CREATE USER [tp_test_app2] WITHOUT LOGIN;
ALTER ROLE [tp_app] ADD MEMBER [tp_test_app2];
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT ALL;
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('TST-GUARD', N'G', N'G', 1, 1, 'ACTIVE', 'UTC');
DECLARE @tg INT = SCOPE_IDENTITY(), @tk UNIQUEIDENTIFIER = NEWID();
INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (@@SPID, @tg, 0, @tk);
EXEC sys.sp_set_session_context @key = N'TenantId', @value = @tg;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @tk;
EXECUTE AS USER = N'tp_test_app2';
BEGIN TRY
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status) VALUES (@tg, N'ok@test.invalid', N'Ok', 'INVITED');
    SET @ok = 1;
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash)
    VALUES (@tg, N'bad@test.invalid', N'Bad', 'ACTIVE', '$argon2id$v=19$m=65536,t=3,p=4$YmFk$YmFk');
END TRY
BEGIN CATCH
    SET @e = ERROR_NUMBER();
    IF XACT_STATE() = -1 ROLLBACK TRANSACTION;     -- a doomed transaction must end before REVERT can run
END CATCH;
REVERT;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @ok = 1 AND @e = 50012 PRINT 'PASS A1: the application role cannot create a user with a password, MFA or lockout state';
ELSE PRINT 'FAIL A1: a privileged user was created directly (' + ISNULL(CAST(@e AS VARCHAR(10)), 'no error') + ')';
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
GO
/* S1: a tenant may tighten a security setting within the platform bounds (FR-PLT-043); a value looser than the
   bound is refused by the trigger (50020, BR-PLT-018). Own transaction, as for A1. */
SET NOCOUNT ON;
DECLARE @e INT, @ok INT;
BEGIN TRANSACTION;
CREATE USER [tp_test_app3] WITHOUT LOGIN;
ALTER ROLE [tp_app] ADD MEMBER [tp_test_app3];
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT ALL;
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('TST-SET', N'S', N'S', 1, 1, 'ACTIVE', 'UTC');
DECLARE @tg INT = SCOPE_IDENTITY(), @tk UNIQUEIDENTIFIER = NEWID();
INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (@@SPID, @tg, 0, @tk);
EXEC sys.sp_set_session_context @key = N'TenantId', @value = @tg;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @tk;
EXECUTE AS USER = N'tp_test_app3';
BEGIN TRY
    INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@tg, 'security.session.idle_minutes', N'10');
    SET @ok = 1;
    INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@tg, 'security.session.absolute_hours', N'24');
END TRY
BEGIN CATCH
    SET @e = ERROR_NUMBER();
    IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
END CATCH;
REVERT;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @ok = 1 AND @e = 50020 PRINT 'PASS S1: a tenant setting within the bounds is accepted and one outside them is refused';
ELSE PRINT 'FAIL S1: the setting bounds were not enforced (' + ISNULL(CAST(@e AS VARCHAR(10)), 'no error') + ')';
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
GO
/* S2: a security key with no platform definition is refused (50020), so a tenant cannot invent a security setting. */
SET NOCOUNT ON;
DECLARE @e INT, @ok INT;
BEGIN TRANSACTION;
CREATE USER [tp_test_app3] WITHOUT LOGIN;
ALTER ROLE [tp_app] ADD MEMBER [tp_test_app3];
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT ALL;
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('TST-SET', N'S', N'S', 1, 1, 'ACTIVE', 'UTC');
DECLARE @tg INT = SCOPE_IDENTITY(), @tk UNIQUEIDENTIFIER = NEWID();
INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (@@SPID, @tg, 0, @tk);
EXEC sys.sp_set_session_context @key = N'TenantId', @value = @tg;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @tk;
EXECUTE AS USER = N'tp_test_app3';
BEGIN TRY
    INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@tg, 'security.session.idle_minutes', N'10');
    SET @ok = 1;
    INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@tg, 'security.no.such.key', N'1');
END TRY
BEGIN CATCH
    SET @e = ERROR_NUMBER();
    IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
END CATCH;
REVERT;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @ok = 1 AND @e = 50020 PRINT 'PASS S2: an undefined security setting is refused';
ELSE PRINT 'FAIL S2: an undefined security setting was accepted (' + ISNULL(CAST(@e AS VARCHAR(10)), 'no error') + ')';
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
GO
SET NOCOUNT ON;
BEGIN TRANSACTION;
CREATE USER [tp_test_app] WITHOUT LOGIN;
ALTER ROLE [tp_app] ADD MEMBER [tp_test_app];
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT ALL;      -- plan and country rows are not seeded
ALTER TABLE sec.AppUser NOCHECK CONSTRAINT ALL;      -- the tenant key of the MFA secret is not seeded
GO
-- #Bind: binds the connection to a tenant and a user the way the binding procedure does, but without read-only keys,
-- so the cases can rebind. Administrator actions read the user from the context.
CREATE PROCEDURE #Bind @TenantId INT, @UserId BIGINT
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    MERGE sec.SessionBinding AS b
    USING (SELECT @@SPID AS SessionId) AS s ON b.SessionId = s.SessionId
    WHEN MATCHED THEN UPDATE SET BoundTenantId = @TenantId, BoundUserId = @UserId, BindingToken = @token, BoundAt = SYSUTCDATETIME(),
                                 BindingKind = 'USER', BoundOperatorId = NULL
    WHEN NOT MATCHED THEN INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (s.SessionId, @TenantId, @UserId, @token);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @UserId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
END;
GO

DECLARE @tf INT, @adm BIGINT, @usr BIGINT, @mfa BIGINT, @inv BIGINT, @lck BIGINT, @rTA BIGINT;
DECLARE @phcA VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$YWRtaW5zYWx0$YWRtaW5oYXNo',
        @phcU VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$dXNyc2FsdA$dXNyaGFzaA',
        @phcM VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$bWZhc2FsdA$bWZhaGFzaA',
        @phcL VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$bGNrc2FsdA$bGNraGFzaA',
        @phcNew VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$bmV3c2FsdA$bmV3aGFzaA';
DECLARE @secret VARBINARY(256) = CRYPT_GEN_RANDOM(48);
DECLARE @s1 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @s2 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @s3 VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @s4 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @sv VARBINARY(64) = CRYPT_GEN_RANDOM(32), @sv2 VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @lnk VARBINARY(64) = CRYPT_GEN_RANDOM(32), @lnk2 VARBINARY(64) = CRYPT_GEN_RANDOM(32);
DECLARE @e1 INT, @e2 INT, @e3 INT, @e4 INT, @n INT, @n2 INT, @n3 INT, @id INT, @st VARCHAR(18), @sent NVARCHAR(254),
        @uid BIGINT, @mreq BIT, @menr BIT, @enr BIT, @reenr BIT, @sec VARBINARY(256), @key BIGINT, @last BIGINT, @rem INT, @i INT;
DECLARE @codes10 NVARCHAR(MAX), @codes9 NVARCHAR(MAX);
SELECT @codes10 = N'[' + STRING_AGG(N'"' + CONVERT(NVARCHAR(64), HASHBYTES('SHA2_256', CONCAT('enrol-', v.n)), 2) + N'"', N',') + N']'
FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10)) AS v(n);
SELECT @codes9 = N'[' + STRING_AGG(N'"' + CONVERT(NVARCHAR(64), HASHBYTES('SHA2_256', CONCAT('enrol-', v.n)), 2) + N'"', N',') + N']'
FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9)) AS v(n);

-- Seed: one active tenant with an administrator (TA), a user without MFA, a user with MFA and ten recovery codes,
-- an invited user and a user locked by the third lockout.
-- MFA required of this tenant: A4 to A16 are the two-step path (ADR 0048 makes it a platform choice; A18 on is the other).
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone, MfaPolicy) VALUES ('TST-FLOW', N'F', N'F', 1, 1, 'ACTIVE', 'UTC', 'REQUIRED');
SET @tf = SCOPE_IDENTITY();
EXEC #Bind @tf, 0;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash, MfaEnabled, MfaSecretEnc, MfaKeyId, MfaEnrolledAt)
VALUES (@tf, N'adm@test.invalid', N'Admin', 'ACTIVE', @phcA, 1, @secret, 1, SYSUTCDATETIME());
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@tf, N'usr@test.invalid', N'User', 'ACTIVE', @phcU);
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash, MfaEnabled, MfaSecretEnc, MfaKeyId, MfaEnrolledAt, MfaLastUsedStep)
VALUES (@tf, N'mfa@test.invalid', N'Mfa', 'ACTIVE', @phcM, 1, @secret, 1, SYSUTCDATETIME(), 100);
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status) VALUES (@tf, N'inv@test.invalid', N'Invited', 'INVITED');
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash, LockedUntil, RequiresAdminUnlock, LockoutCount)
VALUES (@tf, N'lck@test.invalid', N'Locked', 'LOCKED', @phcL, DATEADD(MINUTE, 15, SYSUTCDATETIME()), 1, 3);
SELECT @adm = AppUserId FROM sec.AppUser WHERE Email = N'adm@test.invalid';
SELECT @usr = AppUserId FROM sec.AppUser WHERE Email = N'usr@test.invalid';
SELECT @mfa = AppUserId FROM sec.AppUser WHERE Email = N'mfa@test.invalid';
SELECT @inv = AppUserId FROM sec.AppUser WHERE Email = N'inv@test.invalid';
SELECT @lck = AppUserId FROM sec.AppUser WHERE Email = N'lck@test.invalid';
INSERT sec.Role (TenantId, Code, NameAr, NameEn, IsSystem, SeedKey) VALUES (@tf, 'TA', N'مدير الحساب', N'Tenant administrator', 1, 'ROLE.TA');
SELECT @rTA = RoleId FROM sec.Role WHERE TenantId = @tf AND Code = 'TA';
INSERT sec.UserRole (TenantId, UserId, RoleId) VALUES (@tf, @adm, @rTA);
INSERT sec.MfaRecoveryCode (TenantId, UserId, CodeHash)
SELECT @tf, @mfa, HASHBYTES('SHA2_256', CONCAT('rc-', v.n)) FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10)) AS v(n);
-- Two live, MFA-verified sessions of the MFA user (password change and logout cases)
INSERT sec.UserSession (TenantId, UserId, TokenHash, IdleExpiresAt, AbsoluteExpiresAt, MfaVerifiedAt)
VALUES (@tf, @mfa, HASHBYTES('SHA2_256', @sv),  DATEADD(MINUTE, 30, SYSUTCDATETIME()), DATEADD(HOUR, 12, SYSUTCDATETIME()), SYSUTCDATETIME()),
       (@tf, @mfa, HASHBYTES('SHA2_256', @sv2), DATEADD(MINUTE, 30, SYSUTCDATETIME()), DATEADD(HOUR, 12, SYSUTCDATETIME()), SYSUTCDATETIME());
EXEC #Bind @tf, @adm;

/* A2: the sub-domain code resolves to the tenant with its names for the login page (GAP-13); an unknown code to
   nothing. */
SAVE TRANSACTION a2;
DECLARE @nameEn NVARCHAR(200), @nameAr NVARCHAR(200), @lang VARCHAR(2), @nameX NVARCHAR(200);
SELECT @id = NULL, @st = NULL, @n = 1, @nameX = N'x';
UPDATE plat.Tenant SET NameEn = N'Flow Trading', NameAr = N'فلو للتجارة' WHERE TenantId = @tf;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_ResolveTenant @Code = 'TST-FLOW', @TenantId = @id OUTPUT, @Status = @st OUTPUT, @NameEn = @nameEn OUTPUT,
     @NameAr = @nameAr OUTPUT, @DefaultLanguage = @lang OUTPUT;
EXEC sec.usp_ResolveTenant @Code = 'NO-SUCH', @TenantId = @n OUTPUT, @NameEn = @nameX OUTPUT;
REVERT;
IF @id = @tf AND @st = 'ACTIVE' AND @n IS NULL AND @nameX IS NULL AND @nameEn = N'Flow Trading' AND @nameAr = N'فلو للتجارة' AND @lang = 'en'
    PRINT 'PASS A2: the sub-domain resolves to its tenant and names, an unknown code to nothing';
ELSE PRINT 'FAIL A2: tenant resolution';
ROLLBACK TRANSACTION a2;

/* A3: the administrator invites a user; the link sets the first password once and activates the user; a reset link
   cannot be issued for an invited user (50016), and the used link is refused (50017). */
SAVE TRANSACTION a3;
SELECT @e1 = NULL, @e2 = NULL, @sent = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_IssueUserToken @TenantId = @tf, @UserId = @inv, @Purpose = 'PASSWORD_RESET', @Token = @lnk; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_IssueUserToken @TenantId = @tf, @UserId = @inv, @Purpose = 'INVITATION', @Token = @lnk, @SentTo = @sent OUTPUT;
EXEC sec.usp_CompleteInvitation @TenantId = @tf, @Token = @lnk, @NewPasswordHash = @phcNew;
BEGIN TRY EXEC sec.usp_CompleteInvitation @TenantId = @tf, @Token = @lnk, @NewPasswordHash = @phcNew; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @inv AND Status = 'ACTIVE' AND PasswordHash = @phcNew;
SELECT @n2 = COUNT(*) FROM sec.UserToken WHERE UserId = @inv AND Purpose = 'INVITATION' AND UsedAt IS NOT NULL AND RequestedByUserId = @adm;
IF @e1 = 50016 AND @sent = N'inv@test.invalid' AND @n = 1 AND @n2 = 1 AND @e2 = 50017
    PRINT 'PASS A3: an invitation link sets the first password once and activates the user';
ELSE PRINT 'FAIL A3: invitation flow';
ROLLBACK TRANSACTION a3;

/* A4: first login of a user without MFA: the session does not bind until enrolment; enrolment needs ten recovery
   code hashes (50014); after it the session is verified and the user has MFA and ten codes. */
SAVE TRANSACTION a4;
SELECT @e1 = NULL, @e2 = NULL, @mreq = NULL, @menr = NULL, @enr = NULL, @reenr = NULL;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'usr@test.invalid', @PasswordHash = @phcU, @SessionToken = @s1,
     @MfaRequired = @mreq OUTPUT, @MfaEnrolmentRequired = @menr OUTPUT;
EXEC sec.usp_GetMfaChallenge @TenantId = @tf, @SessionToken = @s1, @EnrolmentRequired = @enr OUTPUT, @ReenrolmentRequired = @reenr OUTPUT;
BEGIN TRY EXEC sec.usp_CompleteMfaEnrolment @TenantId = @tf, @SessionToken = @s1, @MfaSecretEnc = @secret, @MfaKeyId = 1, @Step = 500, @RecoveryCodeHashes = @codes9; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_CompleteMfaEnrolment @TenantId = @tf, @SessionToken = @s1, @MfaSecretEnc = @secret, @MfaKeyId = 1, @Step = 500, @RecoveryCodeHashes = @codes10;
REVERT;
SELECT @n = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @s1) AND MfaVerifiedAt IS NOT NULL;
SELECT @n2 = COUNT(*) FROM sec.MfaRecoveryCode WHERE UserId = @usr AND UsedAt IS NULL;
SELECT @n3 = COUNT(*) FROM sec.AppUser WHERE AppUserId = @usr AND MfaEnabled = 1 AND MfaLastUsedStep = 500 AND MfaEnrolledAt IS NOT NULL;
IF @mreq = 1 AND @menr = 1 AND @enr = 1 AND @reenr = 0 AND @e1 = 50014 AND @n = 1 AND @n2 = 10 AND @n3 = 1
    PRINT 'PASS A4: first login requires MFA enrolment, which records the secret and ten recovery codes';
ELSE PRINT 'FAIL A4: first enrolment';
ROLLBACK TRANSACTION a4;

/* A5: a TOTP code whose step is not after the last accepted one is a replay and counts as a failure; the next step
   verifies the session. */
SAVE TRANSACTION a5;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s2;
EXEC sec.usp_ConfirmMfa @TenantId = @tf, @SessionToken = @s2, @Passed = 1, @Step = 100;
REVERT;
SELECT @n = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @s2) AND MfaVerifiedAt IS NULL;
SELECT @n2 = COUNT(*) FROM sec.LoginAttempt WHERE UserId = @mfa AND Outcome = 'FAILED_MFA';
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_ConfirmMfa @TenantId = @tf, @SessionToken = @s2, @Passed = 1, @Step = 101;
REVERT;
SELECT @n3 = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @s2) AND MfaVerifiedAt IS NOT NULL;
SELECT @last = MfaLastUsedStep FROM sec.AppUser WHERE AppUserId = @mfa;
IF @n = 1 AND @n2 = 1 AND @n3 = 1 AND @last = 101 PRINT 'PASS A5: a replayed TOTP step is refused and the next step verifies the session';
ELSE PRINT 'FAIL A5: TOTP replay check';
ROLLBACK TRANSACTION a5;

/* A6: five failed MFA checks lock the account and end the session (EndReason MFA_FAILED). */
SAVE TRANSACTION a6;
SET @i = 0;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s3;
WHILE @i < 5 BEGIN EXEC sec.usp_ConfirmMfa @TenantId = @tf, @SessionToken = @s3, @Passed = 0; SET @i = @i + 1; END;
REVERT;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @mfa AND Status = 'LOCKED';
SELECT @n2 = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @s3) AND EndReason = 'MFA_FAILED';
IF @n = 1 AND @n2 = 1 PRINT 'PASS A6: five failed MFA checks lock the account and end the session';
ELSE PRINT 'FAIL A6: MFA failures did not lock the account or end the session';
ROLLBACK TRANSACTION a6;

/* A7: a recovery code verifies the session once; the same code is then refused (50009). */
SAVE TRANSACTION a7;
SELECT @e1 = NULL, @rem = NULL;
DECLARE @rc1 VARBINARY(32) = HASHBYTES('SHA2_256', 'rc-1');
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s3;
EXEC sec.usp_UseRecoveryCode @TenantId = @tf, @SessionToken = @s3, @CodeHash = @rc1, @Remaining = @rem OUTPUT;
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s4;
BEGIN TRY EXEC sec.usp_UseRecoveryCode @TenantId = @tf, @SessionToken = @s4, @CodeHash = @rc1; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @s3) AND MfaVerifiedAt IS NOT NULL;
IF @rem = 9 AND @e1 = 50009 AND @n = 1 PRINT 'PASS A7: a recovery code verifies one session and cannot be used again';
ELSE PRINT 'FAIL A7: recovery code use';
ROLLBACK TRANSACTION a7;

/* A8: password change: the wrong current password is refused (50010), candidates must cover every stored salt
   (50015), reuse is refused (50011); a valid change stores the old hash in the history and ends the other sessions. */
SAVE TRANSACTION a8;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL;
DECLARE @candOk NVARCHAR(MAX) = N'["$argon2id$v=19$m=65536,t=3,p=4$bWZhc2FsdA$b3RoZXJoYXNo"]',
        @candReuse NVARCHAR(MAX) = N'["$argon2id$v=19$m=65536,t=3,p=4$bWZhc2FsdA$bWZhaGFzaA"]';
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_ChangePassword @TenantId = @tf, @SessionToken = @sv, @CurrentPasswordHash = @phcU, @NewPasswordHash = @phcNew, @Candidates = @candOk; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_ChangePassword @TenantId = @tf, @SessionToken = @sv, @CurrentPasswordHash = @phcM, @NewPasswordHash = @phcNew, @Candidates = N'[]'; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_ChangePassword @TenantId = @tf, @SessionToken = @sv, @CurrentPasswordHash = @phcM, @NewPasswordHash = @phcNew, @Candidates = @candReuse; END TRY
BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_ChangePassword @TenantId = @tf, @SessionToken = @sv, @CurrentPasswordHash = @phcM, @NewPasswordHash = @phcNew, @Candidates = @candOk;
REVERT;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @mfa AND PasswordHash = @phcNew;
SELECT @n2 = COUNT(*) FROM sec.UserPasswordHistory WHERE UserId = @mfa AND PasswordHash = @phcM;
SELECT @n3 = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @sv2) AND EndReason = 'PASSWORD_CHANGED';
SELECT @i = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @sv) AND EndedAt IS NULL;
IF @e1 = 50010 AND @e2 = 50015 AND @e3 = 50011 AND @n = 1 AND @n2 = 1 AND @n3 = 1 AND @i = 1
    PRINT 'PASS A8: password change proves the current password, applies the history rule and ends the other sessions';
ELSE PRINT 'FAIL A8: password change';
ROLLBACK TRANSACTION a8;

/* A9: self-service reset: an unknown address gets no link and no error; a reset link sets the password once, ends
   every session, and leaves an administrator's lock in place. */
SAVE TRANSACTION a9;
SELECT @e1 = NULL, @sent = N'x';
DECLARE @sentL NVARCHAR(254), @sentM NVARCHAR(254);
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_RequestPasswordReset @TenantId = @tf, @Login = N'nobody@test.invalid', @Token = @lnk2, @SentTo = @sent OUTPUT;
EXEC sec.usp_RequestPasswordReset @TenantId = @tf, @Login = N'mfa@test.invalid', @Token = @lnk, @SentTo = @sentM OUTPUT;
EXEC sec.usp_ResetPassword @TenantId = @tf, @Token = @lnk, @NewPasswordHash = @phcNew, @Candidates = N'["$argon2id$v=19$m=65536,t=3,p=4$bWZhc2FsdA$b3RoZXJoYXNo"]';
BEGIN TRY EXEC sec.usp_ResetPassword @TenantId = @tf, @Token = @lnk, @NewPasswordHash = @phcNew, @Candidates = N'[]'; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_RequestPasswordReset @TenantId = @tf, @Login = N'lck@test.invalid', @Token = @lnk2, @SentTo = @sentL OUTPUT;
EXEC sec.usp_ResetPassword @TenantId = @tf, @Token = @lnk2, @NewPasswordHash = @phcNew, @Candidates = N'["$argon2id$v=19$m=65536,t=3,p=4$bGNrc2FsdA$b3RoZXI"]';
REVERT;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @mfa AND PasswordHash = @phcNew;
SELECT @n2 = COUNT(*) FROM sec.UserSession WHERE UserId = @mfa AND EndedAt IS NULL;
SELECT @n3 = COUNT(*) FROM sec.AppUser WHERE AppUserId = @lck AND Status = 'LOCKED' AND RequiresAdminUnlock = 1 AND PasswordHash = @phcNew;
IF @sent IS NULL AND @sentM = N'mfa@test.invalid' AND @n = 1 AND @n2 = 0 AND @e1 = 50017 AND @sentL = N'lck@test.invalid' AND @n3 = 1
    PRINT 'PASS A9: a reset link works once, ends every session, reveals nothing for an unknown address, and keeps an administrator lock';
ELSE PRINT 'FAIL A9: password reset';
ROLLBACK TRANSACTION a9;

/* A10: administrator actions: unlock a locked user (and 50018 for one not locked); reset a user's MFA, which removes
   the secret, the codes and the sessions; re-enrolment then needs the e-mailed link (50013 without it). */
SAVE TRANSACTION a10;
SELECT @e1 = NULL, @e2 = NULL, @reenr = NULL;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_UnlockUser @TenantId = @tf, @UserId = @lck;
BEGIN TRY EXEC sec.usp_UnlockUser @TenantId = @tf, @UserId = @usr; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_ResetMfa @TenantId = @tf, @UserId = @mfa;
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s1;
EXEC sec.usp_GetMfaChallenge @TenantId = @tf, @SessionToken = @s1, @ReenrolmentRequired = @reenr OUTPUT;
BEGIN TRY EXEC sec.usp_CompleteMfaEnrolment @TenantId = @tf, @SessionToken = @s1, @MfaSecretEnc = @secret, @MfaKeyId = 1, @Step = 700, @RecoveryCodeHashes = @codes10; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_IssueUserToken @TenantId = @tf, @UserId = @mfa, @Purpose = 'MFA_REENROLMENT', @Token = @lnk;
EXEC sec.usp_CompleteMfaEnrolment @TenantId = @tf, @SessionToken = @s1, @MfaSecretEnc = @secret, @MfaKeyId = 1, @Step = 700,
     @RecoveryCodeHashes = @codes10, @ReenrolmentToken = @lnk;
REVERT;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @lck AND Status = 'ACTIVE' AND RequiresAdminUnlock = 0;
SELECT @n2 = COUNT(*) FROM sec.UserSession WHERE UserId = @mfa AND EndReason = 'MFA_RESET';
SELECT @n3 = COUNT(*) FROM sec.AppUser WHERE AppUserId = @mfa AND MfaEnabled = 1 AND MfaLastUsedStep = 700;
IF @n = 1 AND @e1 = 50018 AND @n2 = 2 AND @reenr = 1 AND @e2 = 50013 AND @n3 = 1
    PRINT 'PASS A10: unlock and MFA reset work, and re-enrolment needs the e-mailed link';
ELSE PRINT 'FAIL A10: administrator actions';
ROLLBACK TRANSACTION a10;

/* A11: disabling a user ends its sessions; an administrator cannot change their own status, and an invited user
   cannot be activated without the invitation (50019). */
SAVE TRANSACTION a11;
SELECT @e1 = NULL, @e2 = NULL;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_SetUserStatus @TenantId = @tf, @UserId = @mfa, @Status = 'DISABLED';
BEGIN TRY EXEC sec.usp_SetUserStatus @TenantId = @tf, @UserId = @adm, @Status = 'DISABLED'; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetUserStatus @TenantId = @tf, @UserId = @inv, @Status = 'ACTIVE'; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @mfa AND Status = 'DISABLED';
SELECT @n2 = COUNT(*) FROM sec.UserSession WHERE UserId = @mfa AND EndReason = 'USER_DISABLED';
IF @n = 1 AND @n2 = 2 AND @e1 = 50019 AND @e2 = 50019 PRINT 'PASS A11: disabling a user ends its sessions, and the status rules hold';
ELSE PRINT 'FAIL A11: user status';
ROLLBACK TRANSACTION a11;

/* A12: activity extends the idle expiry but never past the absolute one; logout ends the session; an ended session
   cannot be extended (50003); an administrator ends another session by id. */
SAVE TRANSACTION a12;
SELECT @e1 = NULL;
UPDATE sec.UserSession SET IdleExpiresAt = DATEADD(MINUTE, 1, SYSUTCDATETIME()), AbsoluteExpiresAt = DATEADD(MINUTE, 10, SYSUTCDATETIME())
 WHERE TokenHash = HASHBYTES('SHA2_256', @sv);
DECLARE @sid2 BIGINT = (SELECT UserSessionId FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @sv2));
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_TouchSession @TenantId = @tf, @SessionToken = @sv;
REVERT;
SELECT @n = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @sv) AND IdleExpiresAt = AbsoluteExpiresAt;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_EndSession @TenantId = @tf, @SessionToken = @sv;
BEGIN TRY EXEC sec.usp_TouchSession @TenantId = @tf, @SessionToken = @sv; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_EndSession @TenantId = @tf, @UserSessionId = @sid2;
REVERT;
SELECT @n2 = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @sv) AND EndReason = 'LOGOUT';
SELECT @n3 = COUNT(*) FROM sec.UserSession WHERE UserSessionId = @sid2 AND EndReason = 'TERMINATED_BY_ADMIN' AND EndedBy = @adm;
IF @n = 1 AND @n2 = 1 AND @e1 = 50003 AND @n3 = 1 PRINT 'PASS A12: sessions are extended up to the absolute expiry, ended by logout or by an administrator';
ELSE PRINT 'FAIL A12: session touch and end';
ROLLBACK TRANSACTION a12;

/* A13: the application role cannot run the internal procedures (229). */
SAVE TRANSACTION a13;
SELECT @e1 = NULL, @e2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_RecordAuthFailure @TenantId = @tf, @UserId = @usr; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_ApplyNewPassword @TenantId = @tf, @UserId = @usr, @NewPasswordHash = @phcNew, @Candidates = N'[]'; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @e1 = 229 AND @e2 = 229 PRINT 'PASS A13: the application role cannot run the internal account procedures';
ELSE PRINT 'FAIL A13: an internal procedure is executable by the application role';
ROLLBACK TRANSACTION a13;

/* S3: a tenant's shorter session timeouts (DQ-S03-6): the session gets them at login, and each touch extends it by
   the tenant's idle timeout. */
SAVE TRANSACTION s3;
SELECT @n = NULL, @n2 = NULL, @n3 = NULL;
INSERT cfg.TenantSetting (TenantId, [Key], ValueJson)
VALUES (@tf, 'security.session.idle_minutes', N'10'), (@tf, 'security.session.absolute_hours', N'2');
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s1;
REVERT;
SELECT @n = DATEDIFF(SECOND, LastSeenAt, IdleExpiresAt), @n2 = DATEDIFF(SECOND, LastSeenAt, AbsoluteExpiresAt)
FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @s1);
UPDATE sec.UserSession SET IdleExpiresAt = DATEADD(MINUTE, 1, SYSUTCDATETIME()) WHERE TokenHash = HASHBYTES('SHA2_256', @s1);
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_TouchSession @TenantId = @tf, @SessionToken = @s1;
REVERT;
SELECT @n3 = DATEDIFF(SECOND, LastSeenAt, IdleExpiresAt) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @s1);
IF @n = 600 AND @n2 = 7200 AND @n3 = 600 PRINT 'PASS S3: the tenant''s session timeouts apply at login and at each touch';
ELSE PRINT 'FAIL S3: tenant session timeouts (' + CONCAT(@n, '/', @n2, '/', @n3) + ')';
ROLLBACK TRANSACTION s3;

/* S4: a tenant lockout threshold of three: the third wrong password locks the account. */
SAVE TRANSACTION s4;
SELECT @e1 = NULL, @i = 0;
INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@tf, 'security.lockout.threshold', N'3');
EXECUTE AS USER = N'tp_test_app';
WHILE @i < 3
BEGIN
    BEGIN TRY EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'usr@test.invalid', @PasswordHash = @phcNew, @SessionToken = @s2; END TRY
    BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
    SET @i = @i + 1;
END;
REVERT;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @usr AND Status = 'LOCKED';
IF @e1 = 50005 AND @n = 1 PRINT 'PASS S4: the tenant''s lockout threshold applies';
ELSE PRINT 'FAIL S4: tenant lockout threshold';
ROLLBACK TRANSACTION s4;

/* S5: the history rule counts the current password among the last five (BR-PLT-004): with five earlier passwords
   stored, reusing the fourth newest is refused (50011), reusing the fifth is allowed, and four stay in the history. */
SAVE TRANSACTION s5;
SELECT @e1 = NULL;
INSERT sec.UserPasswordHistory (TenantId, UserId, PasswordHash, CreatedAt)
SELECT @tf, @mfa, CONCAT('$argon2id$v=19$m=65536,t=3,p=4$c2FsdA', v.n, '$aGFzaA', v.n), DATEADD(DAY, -v.n, SYSUTCDATETIME())
FROM (VALUES (1),(2),(3),(4),(5)) AS v(n);
DECLARE @cand4 NVARCHAR(MAX) = N'["$argon2id$v=19$m=65536,t=3,p=4$bWZhc2FsdA$bmV3","$argon2id$v=19$m=65536,t=3,p=4$c2FsdA1$bmV3",'
      + N'"$argon2id$v=19$m=65536,t=3,p=4$c2FsdA2$bmV3","$argon2id$v=19$m=65536,t=3,p=4$c2FsdA3$bmV3",'
      + N'"$argon2id$v=19$m=65536,t=3,p=4$c2FsdA4$aGFzaA4"]',
        @cand5 NVARCHAR(MAX) = N'["$argon2id$v=19$m=65536,t=3,p=4$bWZhc2FsdA$bmV3","$argon2id$v=19$m=65536,t=3,p=4$c2FsdA1$bmV3",'
      + N'"$argon2id$v=19$m=65536,t=3,p=4$c2FsdA2$bmV3","$argon2id$v=19$m=65536,t=3,p=4$c2FsdA3$bmV3",'
      + N'"$argon2id$v=19$m=65536,t=3,p=4$c2FsdA4$bmV3","$argon2id$v=19$m=65536,t=3,p=4$c2FsdA5$aGFzaA5"]';
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_ChangePassword @TenantId = @tf, @SessionToken = @sv, @CurrentPasswordHash = @phcM, @NewPasswordHash = @phcNew, @Candidates = @cand4; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_ChangePassword @TenantId = @tf, @SessionToken = @sv, @CurrentPasswordHash = @phcM, @NewPasswordHash = @phcNew, @Candidates = @cand5;
REVERT;
SELECT @n = COUNT(*) FROM sec.UserPasswordHistory WHERE UserId = @mfa;
SELECT @n2 = COUNT(*) FROM sec.UserPasswordHistory WHERE UserId = @mfa AND PasswordHash = @phcM;
SELECT @n3 = COUNT(*) FROM sec.AppUser WHERE AppUserId = @mfa AND PasswordHash = @phcNew;
IF @e1 = 50011 AND @n = 4 AND @n2 = 1 AND @n3 = 1 PRINT 'PASS S5: the last five passwords, the current one included, cannot be reused';
ELSE PRINT 'FAIL S5: password history count (' + CONCAT(@e1, '/', @n, '/', @n2, '/', @n3) + ')';
ROLLBACK TRANSACTION s5;

/* S6: a stored value outside the bounds (written before the bounds changed) is held at the nearest bound, and a key
   without a definition gives the platform fallback. */
SAVE TRANSACTION s6;
ALTER TABLE cfg.TenantSetting DISABLE TRIGGER TR_TenantSetting_Bounds;
INSERT cfg.TenantSetting (TenantId, [Key], ValueJson)
VALUES (@tf, 'security.session.idle_minutes', N'600'), (@tf, 'security.lockout.threshold', N'"1"'), (@tf, 'custom.undefined', N'7');
ALTER TABLE cfg.TenantSetting ENABLE TRIGGER TR_TenantSetting_Bounds;
SELECT @n = Value FROM cfg.fn_SettingInt(@tf, 'security.session.idle_minutes', 30);
SELECT @n2 = Value FROM cfg.fn_SettingInt(@tf, 'security.lockout.threshold', 5);
SELECT @n3 = Value FROM cfg.fn_SettingInt(@tf, 'custom.undefined', 99);
IF @n = 30 AND @n2 = 3 AND @n3 = 99 PRINT 'PASS S6: stored values are held within the platform bounds';
ELSE PRINT 'FAIL S6: setting bounds in cfg.fn_SettingInt (' + CONCAT(@n, '/', @n2, '/', @n3) + ')';
ROLLBACK TRANSACTION s6;

/* A15: the MFA challenge carries the wrapped tenant key, which the application cannot read before binding (GAP-2):
   the user's key for a TOTP check, the tenant's ACTIVE DATA key for an enrolment. A step-up challenge is only for a
   session whose check is done, and the first challenge only for one that waits for it (GAP-3). */
SAVE TRANSACTION a15;
DECLARE @k BIGINT, @wrap VARBINARY(512) = CRYPT_GEN_RANDOM(60), @wk VARBINARY(512), @mref VARCHAR(200), @kver INT, @kalg VARCHAR(30),
        @verAt DATETIME2(3), @pub UNIQUEIDENTIFIER, @acc BIT, @sec2 VARBINARY(256), @key2 BIGINT, @wk2 VARBINARY(512), @enr2 BIT, @e5 INT;
SELECT @e1 = NULL, @e2 = NULL, @sec = NULL, @key = NULL, @wk = NULL, @verAt = NULL;
INSERT sec.TenantKey (TenantId, Purpose, KeyVersion, Status, WrappedKey, MasterKeyRef) VALUES (@tf, 'DATA', 1, 'PENDING', @wrap, 'local:test/1');
SET @k = SCOPE_IDENTITY();
UPDATE sec.TenantKey SET Status = 'ACTIVE', ActivatedAt = SYSUTCDATETIME() WHERE TenantKeyId = @k;
UPDATE sec.AppUser SET MfaKeyId = @k WHERE AppUserId = @mfa;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s2;
BEGIN TRY EXEC sec.usp_GetMfaChallenge @TenantId = @tf, @SessionToken = @s2, @StepUp = 1; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_GetMfaChallenge @TenantId = @tf, @SessionToken = @s2, @MfaSecretEnc = @sec OUTPUT, @MfaKeyId = @key OUTPUT,
     @LastUsedStep = @last OUTPUT, @EnrolmentRequired = @enr OUTPUT, @WrappedKey = @wk OUTPUT, @MasterKeyRef = @mref OUTPUT,
     @KeyVersion = @kver OUTPUT, @KeyAlgorithm = @kalg OUTPUT, @UserPublicId = @pub OUTPUT;
EXEC sec.usp_ConfirmMfa @TenantId = @tf, @SessionToken = @s2, @Passed = 1, @Step = 101, @Accepted = @acc OUTPUT;
BEGIN TRY EXEC sec.usp_GetMfaChallenge @TenantId = @tf, @SessionToken = @s2; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_GetMfaChallenge @TenantId = @tf, @SessionToken = @s2, @StepUp = 1, @MfaSecretEnc = @sec2 OUTPUT, @MfaVerifiedAt = @verAt OUTPUT;
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'usr@test.invalid', @PasswordHash = @phcU, @SessionToken = @s1;
EXEC sec.usp_GetMfaChallenge @TenantId = @tf, @SessionToken = @s1, @MfaSecretEnc = @sec2 OUTPUT, @MfaKeyId = @key2 OUTPUT,
     @EnrolmentRequired = @enr2 OUTPUT, @WrappedKey = @wk2 OUTPUT;
REVERT;
IF @e1 = 50003 AND @e2 = 50003 AND @sec = @secret AND @key = @k AND @last = 100 AND @enr = 0 AND @wk = @wrap
   AND @mref = 'local:test/1' AND @kver = 1 AND @kalg = 'AES-256-GCM' AND @pub = (SELECT PublicId FROM sec.AppUser WHERE AppUserId = @mfa)
   AND @acc = 1 AND @verAt IS NOT NULL AND @enr2 = 1 AND @sec2 IS NULL AND @key2 = @k AND @wk2 = @wrap
    PRINT 'PASS A15: the MFA challenge carries the wrapped tenant key; step-up only after the first check';
ELSE PRINT 'FAIL A15: MFA challenge key or step-up (' + CONCAT(@e1, '/', @e2, '/', @acc, '/', @enr2, '/', IIF(@wk = @wrap, 1, 0), '/', IIF(@wk2 = @wrap, 1, 0)) + ')';
ROLLBACK TRANSACTION a15;

/* A16: sec.usp_ConfirmMfa says whether the check was recorded (GAP-4): a replayed step and a check without a step are
   refused and counted as failures, the next step is accepted. */
SAVE TRANSACTION a16;
DECLARE @acc1 BIT, @acc2 BIT, @acc3 BIT;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s2;
EXEC sec.usp_ConfirmMfa @TenantId = @tf, @SessionToken = @s2, @Passed = 1, @Step = 100, @Accepted = @acc1 OUTPUT;
EXEC sec.usp_ConfirmMfa @TenantId = @tf, @SessionToken = @s2, @Passed = 1, @Accepted = @acc2 OUTPUT;
EXEC sec.usp_ConfirmMfa @TenantId = @tf, @SessionToken = @s2, @Passed = 1, @Step = 102, @Accepted = @acc3 OUTPUT;
REVERT;
SELECT @n = COUNT(*) FROM sec.LoginAttempt WHERE UserId = @mfa AND Outcome = 'FAILED_MFA';
SELECT @last = MfaLastUsedStep FROM sec.AppUser WHERE AppUserId = @mfa;
IF @acc1 = 0 AND @acc2 = 0 AND @acc3 = 1 AND @n = 2 AND @last = 102
    PRINT 'PASS A16: the MFA check reports a replayed or stepless code as refused and the next step as accepted';
ELSE PRINT 'FAIL A16: MFA check outcome (' + CONCAT(@acc1, '/', @acc2, '/', @acc3, '/', @n, '/', @last) + ')';
ROLLBACK TRANSACTION a16;

/* A17: the password rules of a tenant can be read before binding (GAP-8): the platform defaults, a tenant's stricter
   minimum length, and an unknown tenant refused (50002). */
SAVE TRANSACTION a17;
DECLARE @min1 INT, @min2 INT, @hist INT;
SELECT @e1 = NULL;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_GetPasswordPolicy @TenantId = @tf, @MinLength = @min1 OUTPUT, @HistoryCount = @hist OUTPUT;
REVERT;
INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@tf, 'security.password.min_length', N'16');
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_GetPasswordPolicy @TenantId = @tf, @MinLength = @min2 OUTPUT;
BEGIN TRY EXEC sec.usp_GetPasswordPolicy @TenantId = -1; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @min1 = 12 AND @hist = 5 AND @min2 = 16 AND @e1 = 50002
    PRINT 'PASS A17: the password rules of a tenant are readable before binding';
ELSE PRINT 'FAIL A17: password policy (' + CONCAT(@min1, '/', @hist, '/', @min2, '/', @e1) + ')';
ROLLBACK TRANSACTION a17;

/* A18 (ADR 0048): with MFA off for the tenant, a user without MFA starts a session that needs nothing more, and a
   user who enrolled is still asked. The session records whether MFA was required. */
SAVE TRANSACTION a18;
DECLARE @s5 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @s6 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @step VARCHAR(30), @step2 VARCHAR(30),
        @mreq2 BIT, @menr2 BIT;
UPDATE plat.Tenant SET MfaPolicy = 'OFF' WHERE TenantId = @tf;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'usr@test.invalid', @PasswordHash = @phcU, @SessionToken = @s5,
     @MfaRequired = @mreq OUTPUT, @MfaEnrolmentRequired = @menr OUTPUT;
EXEC sec.usp_GetSessionStep @TenantId = @tf, @SessionToken = @s5, @NextStep = @step OUTPUT;
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s6,
     @MfaRequired = @mreq2 OUTPUT, @MfaEnrolmentRequired = @menr2 OUTPUT;
EXEC sec.usp_GetSessionStep @TenantId = @tf, @SessionToken = @s6, @NextStep = @step2 OUTPUT;
REVERT;
SELECT @n = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @s5) AND MfaRequired = 0;
IF @mreq = 0 AND @menr = 0 AND @step = 'DONE' AND @mreq2 = 1 AND @menr2 = 0 AND @step2 = 'MFA_REQUIRED' AND @n = 1
    PRINT 'PASS A18: with MFA off a user without MFA needs nothing more, and an enrolled user is still asked';
ELSE PRINT 'FAIL A18: MFA policy at sign-in (' + CONCAT(@mreq, '/', @menr, '/', @step, '/', @mreq2, '/', @menr2, '/', @step2, '/', @n) + ')';
ROLLBACK TRANSACTION a18;

/* A19 (ADR 0048): the sign-in name is the e-mail, the employee code or the mobile number (00 read as +, spaces dropped),
   as far as the tenant's security.login.identifiers allows; a name two users share names none. */
SAVE TRANSACTION a19;
DECLARE @p1 VARCHAR(255), @p2 VARCHAR(255), @p3 VARCHAR(255), @p4 VARCHAR(255), @p5 VARCHAR(255);
UPDATE sec.AppUser SET EmployeeCode = 'E-100', Mobile = '+966501112233' WHERE AppUserId = @usr;
UPDATE sec.AppUser SET EmployeeCode = 'adm@test.invalid' WHERE AppUserId = @mfa;   -- the same text as another user's e-mail
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_GetPasswordParams @TenantId = @tf, @Login = N'e-100', @Params = @p1 OUTPUT;
EXEC sec.usp_GetPasswordParams @TenantId = @tf, @Login = N'00966 50 111 2233', @Params = @p2 OUTPUT;
EXEC sec.usp_GetPasswordParams @TenantId = @tf, @Login = N'adm@test.invalid', @Params = @p3 OUTPUT;
REVERT;
INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@tf, 'security.login.identifiers', N'"EMAIL"');
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_GetPasswordParams @TenantId = @tf, @Login = N'E-100', @Params = @p4 OUTPUT;
EXEC sec.usp_GetPasswordParams @TenantId = @tf, @Login = N'adm@test.invalid', @Params = @p5 OUTPUT;
REVERT;
IF @p1 IS NOT NULL AND @p2 = @p1 AND @p3 IS NULL AND @p4 IS NULL AND @p5 IS NOT NULL
    PRINT 'PASS A19: the employee code and the mobile number sign in as the tenant allows, and a shared name names nobody';
ELSE PRINT 'FAIL A19: sign-in names (' + CONCAT(IIF(@p1 IS NULL, 0, 1), IIF(@p2 = @p1, 1, 0), IIF(@p3 IS NULL, 0, 1), IIF(@p4 IS NULL, 0, 1), IIF(@p5 IS NULL, 0, 1)) + ')';
ROLLBACK TRANSACTION a19;

/* A20 (ADR 0048): an administrator sets a temporary password; the user signs in, must change it before the session
   binds, and the change clears the flag. Not for the administrator's own account (50016). */
SAVE TRANSACTION a20;
DECLARE @s7 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @must BIT, @step3 VARCHAR(30), @step4 VARCHAR(30), @phcT VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$dG1wc2FsdA$dG1waGFzaA';
SELECT @e1 = NULL;
UPDATE plat.Tenant SET MfaPolicy = 'OFF' WHERE TenantId = @tf;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_SetTemporaryPassword @TenantId = @tf, @UserId = @inv, @PasswordHash = @phcT;
BEGIN TRY EXEC sec.usp_SetTemporaryPassword @TenantId = @tf, @UserId = @adm, @PasswordHash = @phcT; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'inv@test.invalid', @PasswordHash = @phcT, @SessionToken = @s7, @MustChangePassword = @must OUTPUT;
EXEC sec.usp_GetSessionStep @TenantId = @tf, @SessionToken = @s7, @NextStep = @step3 OUTPUT;
EXEC sec.usp_ChangePassword @TenantId = @tf, @SessionToken = @s7, @CurrentPasswordHash = @phcT, @NewPasswordHash = @phcNew,
     @Candidates = N'["$argon2id$v=19$m=65536,t=3,p=4$dG1wc2FsdA$b3RoZXJoYXNo"]';
EXEC sec.usp_GetSessionStep @TenantId = @tf, @SessionToken = @s7, @NextStep = @step4 OUTPUT;
REVERT;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @inv AND Status = 'ACTIVE' AND MustChangePassword = 0 AND PasswordHash = @phcNew;
SELECT @n2 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @tf AND Action = 'TEMPORARY_PASSWORD_SET' AND EntityId = @inv;
IF @e1 = 50016 AND @must = 1 AND @step3 = 'PASSWORD_CHANGE_REQUIRED' AND @step4 = 'DONE' AND @n = 1 AND @n2 = 1
    PRINT 'PASS A20: a temporary password signs in once and is changed before the session binds';
ELSE PRINT 'FAIL A20: temporary password (' + CONCAT(@e1, '/', @must, '/', @step3, '/', @step4, '/', @n, '/', @n2) + ')';
ROLLBACK TRANSACTION a20;

/* A21 (ADR 0048): a user without MFA steps up with the password; a wrong one is refused and counted; an enrolled user
   steps up with TOTP (50008). */
SAVE TRANSACTION a21;
DECLARE @s8 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @acc1 BIT, @acc2 BIT, @params VARCHAR(255), @menabled BIT;
SELECT @e1 = NULL;
UPDATE plat.Tenant SET MfaPolicy = 'OFF' WHERE TenantId = @tf;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'usr@test.invalid', @PasswordHash = @phcU, @SessionToken = @s8;
EXEC sec.usp_GetSessionPasswordParams @TenantId = @tf, @SessionToken = @s8, @Params = @params OUTPUT, @MfaEnabled = @menabled OUTPUT;
EXEC sec.usp_ConfirmPasswordStepUp @TenantId = @tf, @SessionToken = @s8, @PasswordHash = @phcU, @Accepted = @acc1 OUTPUT;
EXEC sec.usp_ConfirmPasswordStepUp @TenantId = @tf, @SessionToken = @s8, @PasswordHash = @phcM, @Accepted = @acc2 OUTPUT;
BEGIN TRY EXEC sec.usp_ConfirmPasswordStepUp @TenantId = @tf, @SessionToken = @sv, @PasswordHash = @phcM; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @usr AND FailedAttempts = 1;
IF @params = '$argon2id$v=19$m=65536,t=3,p=4$dXNyc2FsdA' AND @menabled = 0 AND @acc1 = 1 AND @acc2 = 0 AND @e1 = 50008 AND @n = 1
    PRINT 'PASS A21: a user without MFA steps up with the password, and a wrong one counts toward the lockout';
ELSE PRINT 'FAIL A21: password step-up (' + CONCAT(@params, '/', @menabled, '/', @acc1, '/', @acc2, '/', @e1, '/', @n) + ')';
ROLLBACK TRANSACTION a21;

/* A14: the whole path ends in a bound connection: login, enrolment, binding. Runs last, because the binding makes the
   connection's context read-only. */
SAVE TRANSACTION a14;
SELECT @e1 = NULL, @uid = NULL;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'UserId', @value = NULL;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    EXEC sec.usp_StartSession @TenantId = @tf, @Login = N'usr@test.invalid', @PasswordHash = @phcU, @SessionToken = @s4;
    EXEC sec.usp_CompleteMfaEnrolment @TenantId = @tf, @SessionToken = @s4, @MfaSecretEnc = @secret, @MfaKeyId = 1, @Step = 900, @RecoveryCodeHashes = @codes10;
    EXEC sec.usp_SetSessionContext @TenantId = @tf, @SessionToken = @s4;
    SET @uid = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
    SELECT @n = COUNT(AppUserId) FROM sec.AppUser;   -- its tenant's users; COUNT(*) is refused (230), as hash columns are denied
END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @e1 IS NULL AND @uid = @usr AND @n = 5 PRINT 'PASS A14: login, MFA enrolment and binding give a connection bound to the user and tenant';
ELSE PRINT 'FAIL A14: the full login path did not bind (' + ISNULL(CAST(@e1 AS VARCHAR(10)), 'no error') + ')';
ROLLBACK TRANSACTION a14;

ROLLBACK TRANSACTION;
GO
PRINT 'Account-security flow tests finished; every change is rolled back.';
GO

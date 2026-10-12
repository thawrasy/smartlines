/* ============================================================================
   Account-security flow tests (ADR 0003, db/static/035_account_security.sql, owner decisions of 2026-10-12).
   Each case drives the procedures as the application role (tp_app) the way the application will: invitation,
   first MFA enrolment, TOTP replay and failures, recovery codes, password change and reset with the history rule,
   administrator actions, sessions, and the guard on direct user inserts.

   Run against a deployed BankFas database that holds no real data, with a sysadmin login (CI uses sa):
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/auth_flow_tests.sql
   A1 runs first in its own transaction, because an error raised in a trigger ends the transaction it runs in.
   Cases A2-A14 then run in one transaction with a savepoint each, rolled back at the end; A14 binds the connection
   for real, which makes its context read-only, so it is the last case.
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
    WHEN MATCHED THEN UPDATE SET BoundTenantId = @TenantId, BoundUserId = @UserId, BindingToken = @token, BoundAt = SYSUTCDATETIME()
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
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('TST-FLOW', N'F', N'F', 1, 1, 'ACTIVE', 'UTC');
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

/* A2: the sub-domain code resolves to the tenant; an unknown code to nothing. */
SAVE TRANSACTION a2;
SELECT @id = NULL, @st = NULL, @n = 1;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_ResolveTenant @Code = 'TST-FLOW', @TenantId = @id OUTPUT, @Status = @st OUTPUT;
EXEC sec.usp_ResolveTenant @Code = 'NO-SUCH', @TenantId = @n OUTPUT;
REVERT;
IF @id = @tf AND @st = 'ACTIVE' AND @n IS NULL PRINT 'PASS A2: the sub-domain resolves to its tenant, an unknown code to nothing';
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
EXEC sec.usp_StartSession @TenantId = @tf, @Email = N'usr@test.invalid', @PasswordHash = @phcU, @SessionToken = @s1,
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
EXEC sec.usp_StartSession @TenantId = @tf, @Email = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s2;
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
EXEC sec.usp_StartSession @TenantId = @tf, @Email = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s3;
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
EXEC sec.usp_StartSession @TenantId = @tf, @Email = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s3;
EXEC sec.usp_UseRecoveryCode @TenantId = @tf, @SessionToken = @s3, @CodeHash = @rc1, @Remaining = @rem OUTPUT;
EXEC sec.usp_StartSession @TenantId = @tf, @Email = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s4;
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
EXEC sec.usp_RequestPasswordReset @TenantId = @tf, @Email = N'nobody@test.invalid', @Token = @lnk2, @SentTo = @sent OUTPUT;
EXEC sec.usp_RequestPasswordReset @TenantId = @tf, @Email = N'mfa@test.invalid', @Token = @lnk, @SentTo = @sentM OUTPUT;
EXEC sec.usp_ResetPassword @TenantId = @tf, @Token = @lnk, @NewPasswordHash = @phcNew, @Candidates = N'["$argon2id$v=19$m=65536,t=3,p=4$bWZhc2FsdA$b3RoZXJoYXNo"]';
BEGIN TRY EXEC sec.usp_ResetPassword @TenantId = @tf, @Token = @lnk, @NewPasswordHash = @phcNew, @Candidates = N'[]'; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC sec.usp_RequestPasswordReset @TenantId = @tf, @Email = N'lck@test.invalid', @Token = @lnk2, @SentTo = @sentL OUTPUT;
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
EXEC sec.usp_StartSession @TenantId = @tf, @Email = N'mfa@test.invalid', @PasswordHash = @phcM, @SessionToken = @s1;
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

/* A14: the whole path ends in a bound connection: login, enrolment, binding. Runs last, because the binding makes the
   connection's context read-only. */
SAVE TRANSACTION a14;
SELECT @e1 = NULL, @uid = NULL;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'UserId', @value = NULL;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    EXEC sec.usp_StartSession @TenantId = @tf, @Email = N'usr@test.invalid', @PasswordHash = @phcU, @SessionToken = @s4;
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

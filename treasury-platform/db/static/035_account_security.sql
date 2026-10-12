/* ============================================================================
   BankFas - 035: account security in the database (ADR 0003, O-24, owner decisions of 2026-10-12)

   Every change to a password, an MFA enrolment, a recovery code, a one-time link (invitation, password reset,
   MFA re-enrolment) or a user's status goes through a procedure here. The procedures run as tp_auth_exec; the
   application role keeps EXECUTE on them and loses the direct rights (DENYs at the end of this file, after the
   generated grants 007). So a bound application connection can no longer set a password, clear a lockout,
   enrol or reset MFA, read password-history or recovery-code hashes, mint a link, or reopen or extend a session.

   Callers:
     before binding (session token or link token):  usp_ResolveTenant, usp_GetMfaChallenge, usp_CompleteMfaEnrolment,
                                                     usp_UseRecoveryCode, usp_TouchSession, usp_EndSession (own),
                                                     usp_GetPasswordHistoryParams, usp_ChangePassword,
                                                     usp_RequestPasswordReset, usp_CompleteInvitation, usp_ResetPassword
     bound to the tenant (administrator actions):    usp_IssueUserToken, usp_UnlockUser, usp_ResetMfa, usp_SetUserStatus,
                                                     usp_EndSession (another user's session)
   The application checks the permission code of an administrator action (sec.user.manage, DOC-F07); the database
   checks that the caller is bound to the tenant with write access and that the target belongs to it.

   Residual (ADR 0003): the application sends the e-mail with each link, so it sees the raw link token. A fully
   compromised application server can therefore still take over an account through a reset link; the user is told
   by e-mail and the action is logged. What is closed is direct change through table rights.

   Errors: 50003 no valid session or not bound, 50008 MFA enrolment required, 50009 invalid recovery code,
   50010 current password wrong, 50011 password used recently, 50012 direct insert of a privileged user,
   50013 re-enrolment link required, 50014 ten recovery code hashes required, 50015 history candidates incomplete,
   50016 link cannot be issued for this user, 50017 invalid or expired link, 50018 user not locked,
   50019 status change not allowed.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
/* ---------- Tenant resolution and MFA before binding ---------- */

-- The sub-domain {Code}.bankfas.com gives the tenant (FR-PLT-046). plat.Tenant is not readable by tp_app.
CREATE OR ALTER PROCEDURE sec.usp_ResolveTenant
    @Code     VARCHAR(30),
    @TenantId INT = NULL OUTPUT,
    @Status   VARCHAR(18) = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @TenantId = NULL, @Status = NULL;
    SELECT @TenantId = TenantId, @Status = Status FROM plat.Tenant WHERE Code = @Code;
END;
GO
-- For a session that still waits for its MFA check: the encrypted TOTP secret to verify the code with, or a flag
-- that the user must enrol first (mandatory MFA, ADR 0003).
CREATE OR ALTER PROCEDURE sec.usp_GetMfaChallenge
    @TenantId          INT,
    @SessionToken      VARBINARY(64),
    @MfaSecretEnc      VARBINARY(256) = NULL OUTPUT,
    @MfaKeyId          BIGINT = NULL OUTPUT,
    @LastUsedStep      BIGINT = NULL OUTPUT,
    @EnrolmentRequired BIT = NULL OUTPUT,
    @ReenrolmentRequired BIT = NULL OUTPUT     -- 1 after an MFA reset: enrolment needs the e-mailed link
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @uid BIGINT, @enabled BIT, @enrolledAt DATETIME2(3);
    SELECT @MfaSecretEnc = NULL, @MfaKeyId = NULL, @LastUsedStep = NULL, @EnrolmentRequired = NULL, @ReenrolmentRequired = NULL;
    SELECT @uid = u.AppUserId, @enabled = u.MfaEnabled, @enrolledAt = u.MfaEnrolledAt,
           @MfaSecretEnc = u.MfaSecretEnc, @MfaKeyId = u.MfaKeyId, @LastUsedStep = u.MfaLastUsedStep
    FROM sec.UserSession AS s
    JOIN sec.AppUser AS u ON u.TenantId = s.TenantId AND u.AppUserId = s.UserId
    WHERE s.TenantId = @TenantId AND s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
      AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now AND s.MfaVerifiedAt IS NULL
      AND u.Status = 'ACTIVE' AND u.IsSystemUser = 0
      AND EXISTS (SELECT 1 FROM sec.fn_TenantLoginAllowed(@TenantId, u.AppUserId));
    IF @uid IS NULL THROW 50003, 'No session waiting for MFA for this tenant', 1;
    SET @EnrolmentRequired = CASE WHEN @enabled = 1 THEN 0 ELSE 1 END;
    SET @ReenrolmentRequired = CASE WHEN @enabled = 0 AND @enrolledAt IS NOT NULL THEN 1 ELSE 0 END;
END;
GO
-- First enrolment after the invitation, or re-enrolment after an MFA reset (then with the e-mailed link,
-- DQ-F03-8). The application has verified a code from the new secret; it passes the encrypted secret, the step of
-- that code and the SHA-256 of ten new recovery codes as a JSON array of 64-character hex strings.
CREATE OR ALTER PROCEDURE sec.usp_CompleteMfaEnrolment
    @TenantId           INT,
    @SessionToken       VARBINARY(64),
    @MfaSecretEnc       VARBINARY(256),
    @MfaKeyId           BIGINT,
    @Step               BIGINT,
    @RecoveryCodeHashes NVARCHAR(MAX),
    @ReenrolmentToken   VARBINARY(64) = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @sid BIGINT, @uid BIGINT, @enabled BIT,
            @enrolledAt DATETIME2(3), @tid BIGINT;
    DECLARE @codes TABLE (CodeHash VARBINARY(32) NOT NULL PRIMARY KEY);
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END;
    BEGIN TRY
        SELECT @sid = s.UserSessionId, @uid = u.AppUserId, @enabled = u.MfaEnabled, @enrolledAt = u.MfaEnrolledAt
        FROM sec.UserSession AS s WITH (UPDLOCK, HOLDLOCK)
        JOIN sec.AppUser AS u WITH (UPDLOCK, HOLDLOCK) ON u.TenantId = s.TenantId AND u.AppUserId = s.UserId
        WHERE s.TenantId = @TenantId AND s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
          AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now AND s.MfaVerifiedAt IS NULL
          AND u.Status = 'ACTIVE' AND u.IsSystemUser = 0
          AND EXISTS (SELECT 1 FROM sec.fn_TenantLoginAllowed(@TenantId, u.AppUserId));
        IF @uid IS NULL OR @enabled = 1 THROW 50003, 'No session waiting for MFA enrolment for this tenant', 1;

        IF @enrolledAt IS NOT NULL
        BEGIN
            SELECT @tid = UserTokenId FROM sec.UserToken WITH (UPDLOCK, HOLDLOCK)
            WHERE TenantId = @TenantId AND UserId = @uid AND Purpose = 'MFA_REENROLMENT'
              AND TokenHash = HASHBYTES('SHA2_256', @ReenrolmentToken)
              AND UsedAt IS NULL AND RevokedAt IS NULL AND ExpiresAt > @now;
            IF @tid IS NULL THROW 50013, 'A valid MFA re-enrolment link is required', 1;
            UPDATE sec.UserToken SET UsedAt = @now WHERE UserTokenId = @tid;
        END;

        INSERT @codes (CodeHash)
        SELECT DISTINCT TRY_CONVERT(VARBINARY(32), j.value, 2)
        FROM OPENJSON(@RecoveryCodeHashes) AS j
        WHERE LEN(j.value) = 64 AND TRY_CONVERT(VARBINARY(32), j.value, 2) IS NOT NULL;
        IF (SELECT COUNT(*) FROM @codes) <> 10 OR (SELECT COUNT(*) FROM OPENJSON(@RecoveryCodeHashes)) <> 10
            THROW 50014, 'Ten distinct recovery code hashes (64 hex characters each) are required', 1;

        DELETE FROM sec.MfaRecoveryCode WHERE TenantId = @TenantId AND UserId = @uid;
        INSERT sec.MfaRecoveryCode (TenantId, UserId, CodeHash) SELECT @TenantId, @uid, CodeHash FROM @codes;
        UPDATE sec.AppUser
           SET MfaEnabled = 1, MfaSecretEnc = @MfaSecretEnc, MfaKeyId = @MfaKeyId, MfaEnrolledAt = @now, MfaLastUsedStep = @Step
         WHERE TenantId = @TenantId AND AppUserId = @uid;
        UPDATE sec.UserSession SET MfaVerifiedAt = @now WHERE UserSessionId = @sid;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
-- A single-use recovery code instead of a TOTP code (FR-PLT-011). A wrong code counts toward the lockout.
CREATE OR ALTER PROCEDURE sec.usp_UseRecoveryCode
    @TenantId     INT,
    @SessionToken VARBINARY(64),
    @CodeHash     VARBINARY(32),       -- SHA-256 of the code the user typed
    @ClientIp     VARCHAR(45) = NULL,
    @Remaining    INT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @sid BIGINT, @uid BIGINT, @enabled BIT,
            @cid BIGINT, @locked BIT, @failed BIT = 0;
    SET @Remaining = NULL;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END;
    BEGIN TRY
        SELECT @sid = s.UserSessionId, @uid = u.AppUserId, @enabled = u.MfaEnabled
        FROM sec.UserSession AS s WITH (UPDLOCK, HOLDLOCK)
        JOIN sec.AppUser AS u WITH (UPDLOCK, HOLDLOCK) ON u.TenantId = s.TenantId AND u.AppUserId = s.UserId
        WHERE s.TenantId = @TenantId AND s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
          AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now AND s.MfaVerifiedAt IS NULL
          AND u.Status = 'ACTIVE' AND u.IsSystemUser = 0;
        IF @uid IS NULL THROW 50003, 'No session waiting for MFA for this tenant', 1;
        IF @enabled = 0 THROW 50008, 'MFA enrolment is required first', 1;

        SELECT @cid = MfaRecoveryCodeId FROM sec.MfaRecoveryCode WITH (UPDLOCK, HOLDLOCK)
        WHERE TenantId = @TenantId AND UserId = @uid AND CodeHash = @CodeHash AND UsedAt IS NULL;
        IF @cid IS NOT NULL
        BEGIN
            UPDATE sec.MfaRecoveryCode SET UsedAt = @now, UsedIp = @ClientIp WHERE MfaRecoveryCodeId = @cid;
            UPDATE sec.UserSession SET MfaVerifiedAt = @now WHERE UserSessionId = @sid;
            SELECT @Remaining = COUNT(*) FROM sec.MfaRecoveryCode WHERE TenantId = @TenantId AND UserId = @uid AND UsedAt IS NULL;
        END
        ELSE
        BEGIN
            SET @failed = 1;
            INSERT sec.LoginAttempt (TenantId, UserId, Outcome, IpAddress) VALUES (@TenantId, @uid, 'FAILED_MFA', @ClientIp);
            EXEC sec.usp_RecordAuthFailure @TenantId, @uid, @ClientIp, NULL, @locked OUTPUT;
            IF @locked = 1 UPDATE sec.UserSession SET EndedAt = @now, EndReason = 'MFA_FAILED' WHERE UserSessionId = @sid;
        END;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
    IF @failed = 1 THROW 50009, 'Invalid recovery code', 1;      -- after the failure is committed
END;
GO
/* ---------- Sessions ---------- */

-- Activity extends the idle expiry by the tenant's idle timeout (30 minutes unless the tenant set a shorter one,
-- FR-PLT-043), never past the absolute expiry (FR-PLT-014). Works in every tenant
-- status, because it writes only the user's own session (DQ-F04-8).
CREATE OR ALTER PROCEDURE sec.usp_TouchSession
    @TenantId     INT,
    @SessionToken VARBINARY(64)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(),
            @idle INT = (SELECT Value FROM cfg.fn_SettingInt(@TenantId, 'security.session.idle_minutes', 30));
    UPDATE sec.UserSession
       SET LastSeenAt = @now,
           IdleExpiresAt = CASE WHEN DATEADD(MINUTE, @idle, @now) < AbsoluteExpiresAt THEN DATEADD(MINUTE, @idle, @now) ELSE AbsoluteExpiresAt END
     WHERE TenantId = @TenantId AND TokenHash = HASHBYTES('SHA2_256', @SessionToken)
       AND EndedAt IS NULL AND IdleExpiresAt > @now AND AbsoluteExpiresAt > @now;
    IF @@ROWCOUNT = 0 THROW 50003, 'No valid session for this tenant', 1;
END;
GO
-- Logout of the caller's own session (by token, idempotent), or an administrator ending another session of the
-- bound tenant (by id). An ended session stays ended: the application cannot update sessions at all.
CREATE OR ALTER PROCEDURE sec.usp_EndSession
    @TenantId      INT,
    @SessionToken  VARBINARY(64) = NULL,
    @UserSessionId BIGINT = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();
    IF @SessionToken IS NOT NULL
        UPDATE sec.UserSession SET EndedAt = @now, EndReason = 'LOGOUT'
         WHERE TenantId = @TenantId AND TokenHash = HASHBYTES('SHA2_256', @SessionToken) AND EndedAt IS NULL;
    ELSE IF @UserSessionId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM rls.fn_Bound(@TenantId)) THROW 50003, 'The connection is not bound to this tenant', 1;
        UPDATE sec.UserSession
           SET EndedAt = @now, EndReason = 'TERMINATED_BY_ADMIN', EndedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
         WHERE TenantId = @TenantId AND UserSessionId = @UserSessionId AND EndedAt IS NULL;
    END
    ELSE THROW 50001, 'A session token or a session id is required', 1;
END;
GO
/* ---------- Passwords ---------- */

-- Internal: whom a session token (live, MFA done) or a password-reset link token belongs to.
CREATE OR ALTER PROCEDURE sec.usp_ResolvePasswordActor
    @TenantId     INT,
    @SessionToken VARBINARY(64) = NULL,
    @LinkToken    VARBINARY(64) = NULL,
    @UserId       BIGINT = NULL OUTPUT,
    @SessionId    BIGINT = NULL OUTPUT,
    @TokenId      BIGINT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();
    SELECT @UserId = NULL, @SessionId = NULL, @TokenId = NULL;
    IF @SessionToken IS NOT NULL
        SELECT @UserId = u.AppUserId, @SessionId = s.UserSessionId
        FROM sec.UserSession AS s WITH (UPDLOCK, HOLDLOCK)
        JOIN sec.AppUser AS u WITH (UPDLOCK, HOLDLOCK) ON u.TenantId = s.TenantId AND u.AppUserId = s.UserId
        WHERE s.TenantId = @TenantId AND s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
          AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now AND s.MfaVerifiedAt IS NOT NULL
          AND u.Status = 'ACTIVE' AND u.IsSystemUser = 0;
    ELSE IF @LinkToken IS NOT NULL
        SELECT @UserId = u.AppUserId, @TokenId = t.UserTokenId
        FROM sec.UserToken AS t WITH (UPDLOCK, HOLDLOCK)
        JOIN sec.AppUser AS u WITH (UPDLOCK, HOLDLOCK) ON u.TenantId = t.TenantId AND u.AppUserId = t.UserId
        WHERE t.TenantId = @TenantId AND t.Purpose = 'PASSWORD_RESET' AND t.TokenHash = HASHBYTES('SHA2_256', @LinkToken)
          AND t.UsedAt IS NULL AND t.RevokedAt IS NULL AND t.ExpiresAt > @now
          AND u.Status IN ('ACTIVE', 'LOCKED') AND u.IsSystemUser = 0;
END;
GO
-- The Argon2id parameters and salts of the passwords the new one may not repeat, without the hashes: the last N
-- including the current one (BR-PLT-004; N = security.password.history_count, 5 unless the tenant set more).
-- The application hashes the new password with each of them and passes the results to usp_ChangePassword or
-- usp_ResetPassword, which compare them with the stored hashes.
CREATE OR ALTER PROCEDURE sec.usp_GetPasswordHistoryParams
    @TenantId     INT,
    @SessionToken VARBINARY(64) = NULL,
    @LinkToken    VARBINARY(64) = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @uid BIGINT, @sid BIGINT, @tid BIGINT,
            @keep INT = (SELECT Value - 1 FROM cfg.fn_SettingInt(@TenantId, 'security.password.history_count', 5));
    EXEC sec.usp_ResolvePasswordActor @TenantId, @SessionToken, @LinkToken, @uid OUTPUT, @sid OUTPUT, @tid OUTPUT;
    IF @uid IS NULL THROW 50003, 'No valid session or link for this tenant', 1;
    SELECT DISTINCT LEFT(h.PasswordHash, LEN(h.PasswordHash) - CHARINDEX('$', REVERSE(h.PasswordHash))) AS Params
    FROM (SELECT PasswordHash FROM sec.AppUser WHERE TenantId = @TenantId AND AppUserId = @uid AND PasswordHash IS NOT NULL
          UNION ALL
          SELECT PasswordHash FROM (SELECT TOP (@keep) PasswordHash FROM sec.UserPasswordHistory
                                    WHERE TenantId = @TenantId AND UserId = @uid ORDER BY CreatedAt DESC, UserPasswordHistoryId DESC) AS l
         ) AS h;
END;
GO
-- Internal: BR-PLT-004 reuse check and the switch to the new hash. The history keeps the N-1 passwords before the
-- current one, so the new password differs from the last N including the current one. @Candidates is a JSON array with the new
-- password hashed under each parameter set from usp_GetPasswordHistoryParams; one is needed for each stored hash.
CREATE OR ALTER PROCEDURE sec.usp_ApplyNewPassword
    @TenantId        INT,
    @UserId          BIGINT,
    @NewPasswordHash VARCHAR(255),
    @Candidates      NVARCHAR(MAX),
    @KeepSessionId   BIGINT = NULL      -- the session that made the change stays; every other one ends
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @current VARCHAR(255),
            @keep INT = (SELECT Value - 1 FROM cfg.fn_SettingInt(@TenantId, 'security.password.history_count', 5));
    DECLARE @stored TABLE (Hash VARCHAR(255) COLLATE Latin1_General_BIN2 NOT NULL, Prefix VARCHAR(255) COLLATE Latin1_General_BIN2 NOT NULL);
    DECLARE @cand TABLE (Hash VARCHAR(255) COLLATE Latin1_General_BIN2 NOT NULL);

    SELECT @current = PasswordHash FROM sec.AppUser WHERE TenantId = @TenantId AND AppUserId = @UserId;
    INSERT @stored (Hash, Prefix)
    SELECT h.PasswordHash, LEFT(h.PasswordHash, LEN(h.PasswordHash) - CHARINDEX('$', REVERSE(h.PasswordHash)))
    FROM (SELECT @current AS PasswordHash WHERE @current IS NOT NULL
          UNION ALL
          SELECT PasswordHash FROM (SELECT TOP (@keep) PasswordHash FROM sec.UserPasswordHistory
                                    WHERE TenantId = @TenantId AND UserId = @UserId ORDER BY CreatedAt DESC, UserPasswordHistoryId DESC) AS l
         ) AS h;
    INSERT @cand (Hash) SELECT CAST(j.value AS VARCHAR(255)) FROM OPENJSON(ISNULL(@Candidates, N'[]')) AS j;
    INSERT @cand (Hash) VALUES (@NewPasswordHash);

    IF EXISTS (SELECT 1 FROM @stored AS s
               WHERE NOT EXISTS (SELECT 1 FROM @cand AS c WHERE LEFT(c.Hash, LEN(s.Prefix) + 1) = s.Prefix + '$'))
        THROW 50015, 'The new password must be hashed with every stored parameter set', 1;
    IF EXISTS (SELECT 1 FROM @stored AS s JOIN @cand AS c ON c.Hash = s.Hash)
        THROW 50011, 'The new password was used recently', 1;

    IF @current IS NOT NULL
        INSERT sec.UserPasswordHistory (TenantId, UserId, PasswordHash) VALUES (@TenantId, @UserId, @current);
    DELETE h FROM sec.UserPasswordHistory AS h
    WHERE h.TenantId = @TenantId AND h.UserId = @UserId
      AND h.UserPasswordHistoryId NOT IN (SELECT TOP (@keep) UserPasswordHistoryId FROM sec.UserPasswordHistory
                                          WHERE TenantId = @TenantId AND UserId = @UserId
                                          ORDER BY CreatedAt DESC, UserPasswordHistoryId DESC);
    UPDATE sec.AppUser SET PasswordHash = @NewPasswordHash, PasswordChangedAt = @now
     WHERE TenantId = @TenantId AND AppUserId = @UserId;
    UPDATE sec.UserSession SET EndedAt = @now, EndReason = 'PASSWORD_CHANGED'
     WHERE TenantId = @TenantId AND UserId = @UserId AND EndedAt IS NULL
       AND (@KeepSessionId IS NULL OR UserSessionId <> @KeepSessionId);
END;
GO
-- The user changes their own password: a live session with MFA done, and the current password proven.
CREATE OR ALTER PROCEDURE sec.usp_ChangePassword
    @TenantId            INT,
    @SessionToken        VARBINARY(64),
    @CurrentPasswordHash VARCHAR(255),
    @NewPasswordHash     VARCHAR(255),
    @Candidates          NVARCHAR(MAX),
    @ClientIp            VARCHAR(45) = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own BIT = 0, @uid BIGINT, @sid BIGINT, @tid BIGINT, @stored VARCHAR(255), @locked BIT, @wrong BIT = 0;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END;
    BEGIN TRY
        EXEC sec.usp_ResolvePasswordActor @TenantId, @SessionToken, NULL, @uid OUTPUT, @sid OUTPUT, @tid OUTPUT;
        IF @uid IS NULL THROW 50003, 'No valid session for this tenant', 1;
        SELECT @stored = PasswordHash FROM sec.AppUser WHERE TenantId = @TenantId AND AppUserId = @uid;
        IF @stored IS NULL OR @CurrentPasswordHash IS NULL
           OR @CurrentPasswordHash COLLATE Latin1_General_BIN2 <> @stored COLLATE Latin1_General_BIN2
        BEGIN
            SET @wrong = 1;
            INSERT sec.LoginAttempt (TenantId, UserId, Outcome, IpAddress) VALUES (@TenantId, @uid, 'FAILED_PASSWORD', @ClientIp);
            EXEC sec.usp_RecordAuthFailure @TenantId, @uid, @ClientIp, NULL, @locked OUTPUT;
        END
        ELSE
            EXEC sec.usp_ApplyNewPassword @TenantId, @uid, @NewPasswordHash, @Candidates, @sid;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
    IF @wrong = 1 THROW 50010, 'The current password is not correct', 1;
END;
GO
-- Self-service reset (FR-PLT-013): creates a 30-minute link for a known, active or locked user and returns the
-- address to send it to. An unknown address returns NULL and no error, so the answer reveals nothing.
CREATE OR ALTER PROCEDURE sec.usp_RequestPasswordReset
    @TenantId INT,
    @Email    NVARCHAR(254),
    @Token    VARBINARY(64),           -- random link token, at least 32 bytes; only its SHA-256 is stored
    @ClientIp VARCHAR(45) = NULL,
    @SentTo   NVARCHAR(254) = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @SentTo = NULL;
    IF @Token IS NULL OR DATALENGTH(@Token) < 32 THROW 50001, 'A link token of at least 32 bytes is required', 1;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @uid BIGINT, @addr NVARCHAR(254);
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END;
    BEGIN TRY
        SELECT @uid = AppUserId, @addr = Email FROM sec.AppUser WITH (UPDLOCK, HOLDLOCK)
        WHERE TenantId = @TenantId AND Email = @Email AND Status IN ('ACTIVE', 'LOCKED') AND IsSystemUser = 0
          AND EXISTS (SELECT 1 FROM sec.fn_TenantLoginAllowed(@TenantId, AppUserId));
        IF @uid IS NOT NULL
        BEGIN
            UPDATE sec.UserToken SET RevokedAt = @now
             WHERE TenantId = @TenantId AND UserId = @uid AND Purpose = 'PASSWORD_RESET' AND UsedAt IS NULL AND RevokedAt IS NULL;
            INSERT sec.UserToken (TenantId, UserId, Purpose, TokenHash, ExpiresAt, SentTo, RequestIp)
            VALUES (@TenantId, @uid, 'PASSWORD_RESET', HASHBYTES('SHA2_256', @Token), DATEADD(MINUTE, 30, @now), @addr, @ClientIp);
            SET @SentTo = @addr;
        END;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
-- A new password through a reset link: the history check, a cleared temporary lock (an administrator's lock
-- stays, DQ-S04-12), every session ended, and the link used up.
CREATE OR ALTER PROCEDURE sec.usp_ResetPassword
    @TenantId        INT,
    @Token           VARBINARY(64),
    @NewPasswordHash VARCHAR(255),
    @Candidates      NVARCHAR(MAX)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @uid BIGINT, @sid BIGINT, @tid BIGINT;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END;
    BEGIN TRY
        EXEC sec.usp_ResolvePasswordActor @TenantId, NULL, @Token, @uid OUTPUT, @sid OUTPUT, @tid OUTPUT;
        IF @uid IS NULL THROW 50017, 'Invalid or expired link', 1;
        EXEC sec.usp_ApplyNewPassword @TenantId, @uid, @NewPasswordHash, @Candidates, NULL;
        UPDATE sec.AppUser
           SET Status = CASE WHEN Status = 'LOCKED' AND RequiresAdminUnlock = 0 THEN 'ACTIVE' ELSE Status END,
               LockedUntil = CASE WHEN RequiresAdminUnlock = 0 THEN NULL ELSE LockedUntil END,
               FailedAttempts = 0, FirstFailedAt = NULL
         WHERE TenantId = @TenantId AND AppUserId = @uid;
        UPDATE sec.UserToken SET UsedAt = @now WHERE UserTokenId = @tid;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
-- The invited user sets the first password through the 48-hour link and becomes ACTIVE; MFA enrolment follows at
-- the first login (usp_GetMfaChallenge, usp_CompleteMfaEnrolment).
CREATE OR ALTER PROCEDURE sec.usp_CompleteInvitation
    @TenantId        INT,
    @Token           VARBINARY(64),
    @NewPasswordHash VARCHAR(255)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @uid BIGINT, @tid BIGINT;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END;
    BEGIN TRY
        SELECT @uid = u.AppUserId, @tid = t.UserTokenId
        FROM sec.UserToken AS t WITH (UPDLOCK, HOLDLOCK)
        JOIN sec.AppUser AS u WITH (UPDLOCK, HOLDLOCK) ON u.TenantId = t.TenantId AND u.AppUserId = t.UserId
        WHERE t.TenantId = @TenantId AND t.Purpose = 'INVITATION' AND t.TokenHash = HASHBYTES('SHA2_256', @Token)
          AND t.UsedAt IS NULL AND t.RevokedAt IS NULL AND t.ExpiresAt > @now
          AND u.Status = 'INVITED' AND u.IsSystemUser = 0
          AND EXISTS (SELECT 1 FROM sec.fn_TenantLoginAllowed(@TenantId, u.AppUserId));
        IF @uid IS NULL THROW 50017, 'Invalid or expired link', 1;
        UPDATE sec.AppUser SET PasswordHash = @NewPasswordHash, PasswordChangedAt = @now, Status = 'ACTIVE'
         WHERE TenantId = @TenantId AND AppUserId = @uid;
        UPDATE sec.UserToken SET UsedAt = @now WHERE UserTokenId = @tid;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
/* ---------- Administrator actions (bound to the tenant, with write access) ---------- */

-- Issues a one-time link and returns the address to send it to: INVITATION (48 hours, invited user),
-- PASSWORD_RESET (30 minutes, active or locked user), MFA_REENROLMENT (24 hours, after an MFA reset).
CREATE OR ALTER PROCEDURE sec.usp_IssueUserToken
    @TenantId INT,
    @UserId   BIGINT,
    @Purpose  VARCHAR(15),
    @Token    VARBINARY(64),
    @SentTo   NVARCHAR(254) = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @SentTo = NULL;
    IF @Token IS NULL OR DATALENGTH(@Token) < 32 THROW 50001, 'A link token of at least 32 bytes is required', 1;
    IF NOT EXISTS (SELECT 1 FROM rls.fn_BoundWrite(@TenantId)) THROW 50003, 'The connection is not bound to this tenant for writing', 1;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @email NVARCHAR(254), @ok BIT = 0, @expires DATETIME2(3);
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END;
    BEGIN TRY
        SELECT @email = Email,
               @ok = CASE WHEN @Purpose = 'INVITATION' AND Status = 'INVITED' THEN 1
                          WHEN @Purpose = 'PASSWORD_RESET' AND Status IN ('ACTIVE', 'LOCKED') THEN 1
                          WHEN @Purpose = 'MFA_REENROLMENT' AND Status IN ('ACTIVE', 'LOCKED')
                               AND MfaEnabled = 0 AND MfaEnrolledAt IS NOT NULL THEN 1
                          ELSE 0 END
        FROM sec.AppUser WITH (UPDLOCK, HOLDLOCK)
        WHERE TenantId = @TenantId AND AppUserId = @UserId AND IsSystemUser = 0;
        IF @ok = 0 THROW 50016, 'This link cannot be issued for this user', 1;
        SET @expires = CASE @Purpose WHEN 'INVITATION' THEN DATEADD(HOUR, 48, @now)
                                     WHEN 'PASSWORD_RESET' THEN DATEADD(MINUTE, 30, @now)
                                     ELSE DATEADD(HOUR, 24, @now) END;
        UPDATE sec.UserToken SET RevokedAt = @now
         WHERE TenantId = @TenantId AND UserId = @UserId AND Purpose = @Purpose AND UsedAt IS NULL AND RevokedAt IS NULL;
        INSERT sec.UserToken (TenantId, UserId, Purpose, TokenHash, ExpiresAt, SentTo, RequestedByUserId, RequestIp)
        VALUES (@TenantId, @UserId, @Purpose, HASHBYTES('SHA2_256', @Token), @expires, @email,
                CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), CAST(SESSION_CONTEXT(N'ClientIp') AS VARCHAR(45)));
        SET @SentTo = @email;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
-- Lifts a lock, including the third lockout that only an administrator may lift (BR-PLT-005).
CREATE OR ALTER PROCEDURE sec.usp_UnlockUser
    @TenantId INT,
    @UserId   BIGINT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM rls.fn_BoundWrite(@TenantId)) THROW 50003, 'The connection is not bound to this tenant for writing', 1;
    UPDATE sec.AppUser
       SET Status = 'ACTIVE', LockedUntil = NULL, RequiresAdminUnlock = 0, LockoutCount = 0, FailedAttempts = 0, FirstFailedAt = NULL
     WHERE TenantId = @TenantId AND AppUserId = @UserId AND IsSystemUser = 0
       AND (Status = 'LOCKED' OR RequiresAdminUnlock = 1);
    IF @@ROWCOUNT = 0 THROW 50018, 'The user is not locked', 1;
END;
GO
-- Clears the user's MFA (lost device, BR-PLT-006): secret and recovery codes removed, sessions ended. The user
-- enrols again through a MFA_REENROLMENT link (usp_IssueUserToken, DQ-F03-8).
CREATE OR ALTER PROCEDURE sec.usp_ResetMfa
    @TenantId INT,
    @UserId   BIGINT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM rls.fn_BoundWrite(@TenantId)) THROW 50003, 'The connection is not bound to this tenant for writing', 1;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END;
    BEGIN TRY
        UPDATE sec.AppUser SET MfaEnabled = 0, MfaSecretEnc = NULL, MfaKeyId = NULL, MfaLastUsedStep = NULL
         WHERE TenantId = @TenantId AND AppUserId = @UserId AND IsSystemUser = 0 AND MfaEnabled = 1;
        IF @@ROWCOUNT = 0 THROW 50016, 'The user has no MFA to reset', 1;
        DELETE FROM sec.MfaRecoveryCode WHERE TenantId = @TenantId AND UserId = @UserId;
        UPDATE sec.UserSession SET EndedAt = @now, EndReason = 'MFA_RESET', EndedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
         WHERE TenantId = @TenantId AND UserId = @UserId AND EndedAt IS NULL;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
-- Disable, re-activate or archive a user (FR-PLT-016). Not one's own account. Disabling ends the user's sessions.
CREATE OR ALTER PROCEDURE sec.usp_SetUserStatus
    @TenantId INT,
    @UserId   BIGINT,
    @Status   VARCHAR(10)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM rls.fn_BoundWrite(@TenantId)) THROW 50003, 'The connection is not bound to this tenant for writing', 1;
    IF @UserId = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) THROW 50019, 'A user cannot change the status of their own account', 1;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END;
    BEGIN TRY
        UPDATE sec.AppUser
           SET Status = @Status, ArchivedAt = CASE WHEN @Status = 'ARCHIVED' THEN @now ELSE ArchivedAt END
         WHERE TenantId = @TenantId AND AppUserId = @UserId AND IsSystemUser = 0
           AND (   (@Status = 'DISABLED' AND Status IN ('INVITED', 'ACTIVE', 'LOCKED'))
                OR (@Status = 'ACTIVE'   AND Status = 'DISABLED' AND PasswordHash IS NOT NULL)
                OR (@Status = 'ARCHIVED' AND Status IN ('INVITED', 'DISABLED')));
        IF @@ROWCOUNT = 0 THROW 50019, 'This status change is not allowed', 1;
        IF @Status <> 'ACTIVE'
            UPDATE sec.UserSession SET EndedAt = @now, EndReason = 'USER_DISABLED', EndedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE TenantId = @TenantId AND UserId = @UserId AND EndedAt IS NULL;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
/* A user created directly by the application starts as an invitation: no password, no MFA, no lockout state.
   Everything else comes through the procedures above (an error in a trigger ends the caller's transaction). */
CREATE OR ALTER TRIGGER sec.TR_AppUser_InsertGuard ON sec.AppUser
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    IF IS_MEMBER(N'tp_app') = 1 AND IS_MEMBER(N'tp_auth') = 0
       AND EXISTS (SELECT 1 FROM inserted
                   WHERE PasswordHash IS NOT NULL OR MfaEnabled = 1 OR MfaSecretEnc IS NOT NULL
                      OR (Status <> 'INVITED' AND IsSystemUser = 0)
                      OR FailedAttempts <> 0 OR LockoutCount <> 0 OR RequiresAdminUnlock = 1 OR LockedUntil IS NOT NULL)
        THROW 50012, 'A new user starts as INVITED without a password or MFA; use the invitation procedures', 1;
END;
GO
GRANT EXECUTE ON sec.usp_ResolveTenant TO [tp_app];
GRANT EXECUTE ON sec.usp_GetMfaChallenge TO [tp_app];
GRANT EXECUTE ON sec.usp_CompleteMfaEnrolment TO [tp_app];
GRANT EXECUTE ON sec.usp_UseRecoveryCode TO [tp_app];
GRANT EXECUTE ON sec.usp_TouchSession TO [tp_app];
GRANT EXECUTE ON sec.usp_EndSession TO [tp_app];
GRANT EXECUTE ON sec.usp_GetPasswordHistoryParams TO [tp_app];
GRANT EXECUTE ON sec.usp_ChangePassword TO [tp_app];
GRANT EXECUTE ON sec.usp_RequestPasswordReset TO [tp_app];
GRANT EXECUTE ON sec.usp_ResetPassword TO [tp_app];
GRANT EXECUTE ON sec.usp_CompleteInvitation TO [tp_app];
GRANT EXECUTE ON sec.usp_IssueUserToken TO [tp_app];
GRANT EXECUTE ON sec.usp_UnlockUser TO [tp_app];
GRANT EXECUTE ON sec.usp_ResetMfa TO [tp_app];
GRANT EXECUTE ON sec.usp_SetUserStatus TO [tp_app];
GO
-- The direct rights these procedures replace (O-24 R1, R3, R4, R5). They run after the generated grants (007),
-- which would otherwise remove them.
DENY UPDATE ON [sec].[AppUser]([Status], [IsSystemUser], [PasswordHash], [PasswordChangedAt], [MfaEnabled], [MfaSecretEnc],
    [MfaKeyPurpose], [MfaKeyId], [MfaEnrolledAt], [MfaLastUsedStep], [FailedAttempts], [FirstFailedAt], [LockedUntil],
    [LockoutCount], [LastLockoutAt], [RequiresAdminUnlock], [LastLoginAt], [ArchivedAt]) TO [tp_app];
DENY SELECT ON [sec].[AppUser]([MfaSecretEnc]) TO [tp_app];
DENY SELECT ON [sec].[UserPasswordHistory]([PasswordHash]) TO [tp_app];
DENY INSERT ON [sec].[UserPasswordHistory] TO [tp_app];
DENY SELECT ON [sec].[MfaRecoveryCode]([CodeHash]) TO [tp_app];
DENY INSERT, UPDATE ON [sec].[MfaRecoveryCode] TO [tp_app];
DENY INSERT ON [sec].[UserToken] TO [tp_app];
DENY UPDATE ON [sec].[UserToken]([UserId], [Purpose], [TokenHash], [ExpiresAt], [UsedAt], [RevokedAt], [RequestedByUserId]) TO [tp_app];
GO

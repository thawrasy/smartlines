/* ============================================================================
   BankFas - 036: platform operator login and the temporary support binding (FR-PLT-006, FR-PLT-007, BR-PLT-017,
   DQ-S04-10, DQ-F04-6, owner decisions of 2026-10-12)

   Operators (plat.PlatformOperator) log in on the operator panel, whose connection is tp_platform. The procedures
   follow ADR 0002: the password hash is compared inside the database, the session token is stored as SHA-256, and
   the session needs a recorded TOTP check (MFA is mandatory for operators, no recovery codes). Policy (DOC-S04
   section 12): five failures within 15 minutes lock the operator until another operator administrator unlocks;
   sessions last 15 minutes idle and 8 hours absolute.
     plat.usp_GetOperatorPasswordParams, plat.usp_StartOperatorSession, plat.usp_ConfirmOperatorMfa,
     plat.usp_TouchOperatorSession, plat.usp_EndOperatorSession, plat.usp_UnlockOperator   EXECUTE: tp_platform
   Operator accounts change only through procedures, so the operator panel cannot set a password, an MFA secret or
   a lock state (DENYs at the end of this file):
     plat.usp_BootstrapOperator      the first operator administrator, once, at deployment (DQ-F07-3): an invitation,
                                     never a password in a script. Run by the deploying login; no role may execute it.
     plat.usp_InviteOperator         an operator administrator invites a new operator (48-hour link).
     plat.usp_CompleteOperatorSetup  the invited or reset operator sets the password and enrols TOTP through the link.
     plat.usp_ResetOperator          another administrator clears an operator's password and MFA (lost device); the
                                     operator sets them again through a 24-hour link.
     plat.usp_SetOperatorStatus      another administrator disables, re-activates or archives an operator; at least
                                     two active administrators always remain.                EXECUTE: tp_platform

   Support (DOC-F04 section 6.2): a support connection logs in as a member of tp_support, which is a member of
   tp_readonly. It inherits read access without the restricted columns and no write right, and it stays under the
   row filters. sec.usp_SetSupportContext binds it to one tenant for one request, only with:
     - a live operator session with MFA recorded, of an ACTIVE operator;
     - a grant (plat.SupportAccessGrant) of that tenant to that operator, started, not ended, not revoked, and not
       longer than 72 hours (BR-PLT-017);
     - a tenant in TRIAL or ACTIVE, or SUSPENDED when the grant was made before the suspension (DOC-F04 7.4).
   The binding row says SUPPORT and names the operator. Revoking or changing the grant, ending the operator session,
   or an operator leaving ACTIVE removes the support bindings at once (triggers below).
                                                                                            EXECUTE: tp_support

   Every procedure here writes its audit row in the same transaction (029, ADR 0007): operator events as platform
   rows, a support binding as a row of the tenant, so the tenant sees who entered its data.

   Errors: 50001 arguments, 50002 tenant not available for support, 50003 no valid operator session, 50004 already
   bound, 50005 invalid e-mail or password, 50018 operator not locked, 50021 not an operator administrator,
   50022 no active support grant.
   Errors of the account procedures: 50016 link cannot be issued, 50017 invalid or expired link, 50019 change not
   allowed, 50023 operators already exist.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
IF DATABASE_PRINCIPAL_ID(N'tp_support') IS NULL CREATE ROLE [tp_support] AUTHORIZATION dbo;
IF IS_ROLEMEMBER(N'tp_readonly', N'tp_support') <> 1 ALTER ROLE [tp_readonly] ADD MEMBER [tp_support];
GO
/* ---------- Operator login ---------- */

-- Internal: one failed proof of identity of an operator. The fifth within 15 minutes locks the operator until
-- another operator administrator unlocks (DOC-S04 section 12).
CREATE OR ALTER PROCEDURE plat.usp_RecordOperatorFailure
    @OperatorId INT,
    @Locked     BIT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @Locked = 0;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @failed INT, @first DATETIME2(3), @found BIT = 0;
    SELECT @found = 1, @failed = FailedAttempts, @first = FirstFailedAt
    FROM plat.PlatformOperator WITH (UPDLOCK, HOLDLOCK)
    WHERE PlatformOperatorId = @OperatorId AND Status = 'ACTIVE';
    IF @found = 0 RETURN;
    IF @first IS NULL OR @first < DATEADD(MINUTE, -15, @now)
        SELECT @failed = 1, @first = @now;
    ELSE
        SET @failed = @failed + 1;
    IF @failed >= 5
    BEGIN
        UPDATE plat.PlatformOperator SET Status = 'LOCKED', FailedAttempts = 0, FirstFailedAt = NULL, LockedUntil = NULL
         WHERE PlatformOperatorId = @OperatorId;
        SET @Locked = 1;
        EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_LOCKOUT', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
             @ActorOperatorId = @OperatorId, @Severity = 'HIGH', @Result = 'DENIED',
             @EntityType = 'plat.PlatformOperator', @EntityId = @OperatorId;
    END
    ELSE
        UPDATE plat.PlatformOperator SET FailedAttempts = @failed, FirstFailedAt = @first WHERE PlatformOperatorId = @OperatorId;
END;
GO
-- The Argon2id parameters and salt of an operator, without the hash. NULL for an unknown operator; the panel then
-- answers as for a wrong password.
CREATE OR ALTER PROCEDURE plat.usp_GetOperatorPasswordParams
    @Email  NVARCHAR(254),
    @Params VARCHAR(255) OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @Params = NULL;
    SELECT @Params = LEFT(PasswordHash, LEN(PasswordHash) - CHARINDEX('$', REVERSE(PasswordHash)))
    FROM plat.PlatformOperator
    WHERE Email = @Email AND PasswordHash IS NOT NULL;
END;
GO
CREATE OR ALTER PROCEDURE plat.usp_StartOperatorSession
    @Email        NVARCHAR(254),
    @PasswordHash VARCHAR(255),
    @SessionToken VARBINARY(64),       -- random token held by the panel, at least 32 bytes
    @ClientIp     VARCHAR(45) = NULL,
    @UserAgent    NVARCHAR(400) = NULL,
    @OperatorId   INT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @OperatorId = NULL;
    IF @Email IS NULL OR @SessionToken IS NULL OR DATALENGTH(@SessionToken) < 32
        THROW 50001, 'Email and a session token of at least 32 bytes are required', 1;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @ok BIT = 0, @oid INT, @status VARCHAR(10),
            @stored VARCHAR(255), @locked BIT;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_StartOperatorSession;
    BEGIN TRY
        SELECT @oid = PlatformOperatorId, @status = Status, @stored = PasswordHash
        FROM plat.PlatformOperator WITH (UPDLOCK, HOLDLOCK)
        WHERE Email = @Email;
        IF @oid IS NOT NULL AND @status = 'ACTIVE'
        BEGIN
            IF @stored IS NOT NULL AND @PasswordHash IS NOT NULL
               AND @PasswordHash COLLATE Latin1_General_BIN2 = @stored COLLATE Latin1_General_BIN2
            BEGIN
                UPDATE plat.PlatformOperator SET FailedAttempts = 0, FirstFailedAt = NULL, LastLoginAt = @now
                 WHERE PlatformOperatorId = @oid;
                INSERT plat.OperatorSession (OperatorId, TokenHash, LastSeenAt, IdleExpiresAt, AbsoluteExpiresAt, IpAddress, UserAgent)
                VALUES (@oid, HASHBYTES('SHA2_256', @SessionToken), @now, DATEADD(MINUTE, 15, @now), DATEADD(HOUR, 8, @now),
                        @ClientIp, @UserAgent);
                SELECT @ok = 1, @OperatorId = @oid;
                EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_LOGIN_SUCCESS', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
                     @ActorOperatorId = @oid, @EntityType = 'plat.PlatformOperator', @EntityId = @oid,
                     @IpAddress = @ClientIp, @UserAgent = @UserAgent;
            END
            ELSE
            BEGIN
                EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_LOGIN_FAILED', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
                     @ActorOperatorId = @oid, @Result = 'FAILED', @EntityType = 'plat.PlatformOperator', @EntityId = @oid,
                     @IpAddress = @ClientIp, @UserAgent = @UserAgent;
                EXEC plat.usp_RecordOperatorFailure @oid, @locked OUTPUT;
            END;
        END
        ELSE IF @oid IS NOT NULL                                    -- locked, invited, disabled or archived
            EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_LOGIN_DENIED', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
                 @ActorOperatorId = @oid, @Result = 'DENIED', @EntityType = 'plat.PlatformOperator', @EntityId = @oid,
                 @IpAddress = @ClientIp, @UserAgent = @UserAgent;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_StartOperatorSession;   -- undo this procedure only
        THROW;
    END CATCH;
    IF @ok = 0 THROW 50005, 'Invalid e-mail or password', 1;     -- after the failure is committed
END;
GO
-- Records the TOTP check done by the panel (the secret is encrypted with the platform key). A step not after the
-- last accepted one is a replay; failures count toward the lock, and a lock ends the session.
CREATE OR ALTER PROCEDURE plat.usp_ConfirmOperatorMfa
    @SessionToken VARBINARY(64),
    @Passed       BIT,
    @Step         BIGINT = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @sid BIGINT, @oid INT, @last BIGINT, @locked BIT;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_ConfirmOperatorMfa;
    BEGIN TRY
        SELECT @sid = s.OperatorSessionId, @oid = o.PlatformOperatorId, @last = o.MfaLastUsedStep
        FROM plat.OperatorSession AS s WITH (UPDLOCK, HOLDLOCK)
        JOIN plat.PlatformOperator AS o WITH (UPDLOCK, HOLDLOCK) ON o.PlatformOperatorId = s.OperatorId
        WHERE s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
          AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now
          AND o.Status = 'ACTIVE' AND o.MfaEnabled = 1;
        IF @sid IS NULL THROW 50003, 'No valid operator session', 1;
        IF @Passed = 1 AND (@Step IS NULL OR (@last IS NOT NULL AND @Step <= @last))
            SET @Passed = 0;                                    -- a replayed code, or no step to check it against
        IF @Passed = 1
        BEGIN
            UPDATE plat.OperatorSession SET MfaVerifiedAt = @now WHERE OperatorSessionId = @sid;
            UPDATE plat.PlatformOperator SET MfaLastUsedStep = @Step WHERE PlatformOperatorId = @oid;
        END
        ELSE
        BEGIN
            EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_MFA_FAILED', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
                 @ActorOperatorId = @oid, @Result = 'FAILED', @EntityType = 'plat.OperatorSession', @EntityId = @sid;
            EXEC plat.usp_RecordOperatorFailure @oid, @locked OUTPUT;
            IF @locked = 1
                UPDATE plat.OperatorSession SET EndedAt = @now, EndReason = 'MFA_FAILED' WHERE OperatorSessionId = @sid;
        END;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ConfirmOperatorMfa;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE plat.usp_TouchOperatorSession
    @SessionToken VARBINARY(64)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();
    UPDATE plat.OperatorSession
       SET LastSeenAt = @now,
           IdleExpiresAt = CASE WHEN DATEADD(MINUTE, 15, @now) < AbsoluteExpiresAt THEN DATEADD(MINUTE, 15, @now) ELSE AbsoluteExpiresAt END
     WHERE TokenHash = HASHBYTES('SHA2_256', @SessionToken)
       AND EndedAt IS NULL AND IdleExpiresAt > @now AND AbsoluteExpiresAt > @now;
    IF @@ROWCOUNT = 0 THROW 50003, 'No valid operator session', 1;
END;
GO
CREATE OR ALTER PROCEDURE plat.usp_EndOperatorSession
    @SessionToken VARBINARY(64)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own BIT = 0, @sid BIGINT, @oid INT;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_EndOperatorSession;
    BEGIN TRY
        UPDATE plat.OperatorSession SET EndedAt = SYSUTCDATETIME(), EndReason = 'LOGOUT', @sid = OperatorSessionId, @oid = OperatorId
         WHERE TokenHash = HASHBYTES('SHA2_256', @SessionToken) AND EndedAt IS NULL;
        IF @sid IS NOT NULL
            EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_LOGOUT', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
                 @ActorOperatorId = @oid, @EntityType = 'plat.OperatorSession', @EntityId = @sid;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_EndOperatorSession;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
-- Another operator administrator, in a live session with MFA recorded, lifts a lock. Never one's own.
CREATE OR ALTER PROCEDURE plat.usp_UnlockOperator
    @SessionToken VARBINARY(64),
    @OperatorId   INT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @caller INT;
    SELECT @caller = o.PlatformOperatorId
    FROM plat.OperatorSession AS s
    JOIN plat.PlatformOperator AS o ON o.PlatformOperatorId = s.OperatorId
    WHERE s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
      AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now AND s.MfaVerifiedAt IS NOT NULL
      AND o.Status = 'ACTIVE' AND o.Role = 'OPERATOR_ADMIN';
    IF @caller IS NULL THROW 50021, 'An operator administrator session with MFA is required', 1;
    IF @caller = @OperatorId THROW 50021, 'An operator cannot unlock their own account', 1;
    DECLARE @own BIT = 0;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_UnlockOperator;
    BEGIN TRY
        UPDATE plat.PlatformOperator SET Status = 'ACTIVE', FailedAttempts = 0, FirstFailedAt = NULL, LockedUntil = NULL
         WHERE PlatformOperatorId = @OperatorId AND Status = 'LOCKED';
        IF @@ROWCOUNT = 0 THROW 50018, 'The operator is not locked', 1;
        EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_UNLOCKED', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
             @ActorOperatorId = @caller, @EntityType = 'plat.PlatformOperator', @EntityId = @OperatorId;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_UnlockOperator;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
/* ---------- Operator accounts ---------- */

-- Internal: the operator administrator of a live session with MFA recorded, or NULL.
CREATE OR ALTER FUNCTION plat.fn_OperatorAdminOfSession (@SessionToken VARBINARY(64))
RETURNS TABLE
AS RETURN
    SELECT o.PlatformOperatorId
    FROM plat.OperatorSession AS s
    JOIN plat.PlatformOperator AS o ON o.PlatformOperatorId = s.OperatorId
    WHERE s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
      AND s.EndedAt IS NULL AND s.IdleExpiresAt > SYSUTCDATETIME() AND s.AbsoluteExpiresAt > SYSUTCDATETIME()
      AND s.MfaVerifiedAt IS NOT NULL AND o.Status = 'ACTIVE' AND o.Role = 'OPERATOR_ADMIN';
GO
-- The first operator administrator (DQ-F07-3). Refused once any operator exists, so it cannot add a second way in.
CREATE OR ALTER PROCEDURE plat.usp_BootstrapOperator
    @Email       NVARCHAR(254),
    @DisplayName NVARCHAR(200),
    @Token       VARBINARY(64),        -- random link token, at least 32 bytes; only its SHA-256 is stored
    @OperatorId  INT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @OperatorId = NULL;
    IF @Email IS NULL OR @Token IS NULL OR DATALENGTH(@Token) < 32
        THROW 50001, 'Email and a link token of at least 32 bytes are required', 1;
    DECLARE @own BIT = 0;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_BootstrapOperator;
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM plat.PlatformOperator WITH (UPDLOCK, HOLDLOCK))
            THROW 50023, 'Operators already exist; an operator administrator invites new ones', 1;
        INSERT plat.PlatformOperator (Email, DisplayName, Role, Status) VALUES (@Email, @DisplayName, 'OPERATOR_ADMIN', 'INVITED');
        SET @OperatorId = SCOPE_IDENTITY();
        INSERT plat.OperatorToken (OperatorId, Purpose, TokenHash, ExpiresAt, SentTo)
        VALUES (@OperatorId, 'INVITATION', HASHBYTES('SHA2_256', @Token), DATEADD(HOUR, 48, SYSUTCDATETIME()), @Email);
        EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_BOOTSTRAPPED', @Category = 'PLATFORM', @ActorType = 'SYSTEM',
             @Severity = 'HIGH', @EntityType = 'plat.PlatformOperator', @EntityId = @OperatorId,
             @AfterJson = N'{"role":"OPERATOR_ADMIN"}';
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_BootstrapOperator;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE plat.usp_InviteOperator
    @SessionToken VARBINARY(64),
    @Email        NVARCHAR(254),
    @DisplayName  NVARCHAR(200),
    @Role         VARCHAR(16),
    @Token        VARBINARY(64),
    @OperatorId   INT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @OperatorId = NULL;
    IF @Email IS NULL OR @Token IS NULL OR DATALENGTH(@Token) < 32
        THROW 50001, 'Email and a link token of at least 32 bytes are required', 1;
    DECLARE @caller INT = (SELECT PlatformOperatorId FROM plat.fn_OperatorAdminOfSession(@SessionToken)), @own BIT = 0;
    IF @caller IS NULL THROW 50021, 'An operator administrator session with MFA is required', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_InviteOperator;
    BEGIN TRY
        INSERT plat.PlatformOperator (Email, DisplayName, Role, Status) VALUES (@Email, @DisplayName, @Role, 'INVITED');
        SET @OperatorId = SCOPE_IDENTITY();
        INSERT plat.OperatorToken (OperatorId, Purpose, TokenHash, ExpiresAt, SentTo, RequestedBy)
        VALUES (@OperatorId, 'INVITATION', HASHBYTES('SHA2_256', @Token), DATEADD(HOUR, 48, SYSUTCDATETIME()), @Email, @caller);
        DECLARE @after NVARCHAR(100) = (SELECT @Role AS role FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_INVITED', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
             @ActorOperatorId = @caller, @Severity = 'HIGH', @EntityType = 'plat.PlatformOperator', @EntityId = @OperatorId,
             @AfterJson = @after;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_InviteOperator;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
-- Through an invitation or reset link: the password and the TOTP enrolment together, since an operator is never
-- ACTIVE without MFA. The panel has verified a code from the new secret and passes its step.
CREATE OR ALTER PROCEDURE plat.usp_CompleteOperatorSetup
    @Token           VARBINARY(64),
    @NewPasswordHash VARCHAR(255),
    @MfaSecretEnc    VARBINARY(256),
    @MfaKeyRef       VARCHAR(200),
    @Step            BIGINT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @oid INT, @tid BIGINT;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_CompleteOperatorSetup;
    BEGIN TRY
        SELECT @oid = o.PlatformOperatorId, @tid = t.OperatorTokenId
        FROM plat.OperatorToken AS t WITH (UPDLOCK, HOLDLOCK)
        JOIN plat.PlatformOperator AS o WITH (UPDLOCK, HOLDLOCK) ON o.PlatformOperatorId = t.OperatorId
        WHERE t.TokenHash = HASHBYTES('SHA2_256', @Token) AND t.UsedAt IS NULL AND t.RevokedAt IS NULL AND t.ExpiresAt > @now
          AND o.Status = 'INVITED';
        IF @oid IS NULL THROW 50017, 'Invalid or expired link', 1;
        IF @NewPasswordHash IS NULL OR @MfaSecretEnc IS NULL OR @MfaKeyRef IS NULL OR @Step IS NULL
            THROW 50001, 'A password hash, an encrypted TOTP secret with its key reference and the step of a verified code are required', 1;
        UPDATE plat.PlatformOperator
           SET PasswordHash = @NewPasswordHash, PasswordChangedAt = @now, MfaEnabled = 1, MfaSecretEnc = @MfaSecretEnc,
               MfaKeyRef = @MfaKeyRef, MfaEnrolledAt = @now, MfaLastUsedStep = @Step, Status = 'ACTIVE',
               FailedAttempts = 0, FirstFailedAt = NULL, LockedUntil = NULL
         WHERE PlatformOperatorId = @oid;
        UPDATE plat.OperatorToken SET UsedAt = @now WHERE OperatorTokenId = @tid;
        EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_SETUP_COMPLETED', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
             @ActorOperatorId = @oid, @EntityType = 'plat.PlatformOperator', @EntityId = @oid;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CompleteOperatorSetup;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
-- Lost device or suspected compromise: another administrator clears the password and MFA and ends the sessions;
-- the operator sets both again through a 24-hour link (DOC-S04 section 12: no recovery codes for operators).
CREATE OR ALTER PROCEDURE plat.usp_ResetOperator
    @SessionToken VARBINARY(64),
    @OperatorId   INT,
    @Token        VARBINARY(64),
    @SentTo       NVARCHAR(254) = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @SentTo = NULL;
    IF @Token IS NULL OR DATALENGTH(@Token) < 32 THROW 50001, 'A link token of at least 32 bytes is required', 1;
    DECLARE @caller INT = (SELECT PlatformOperatorId FROM plat.fn_OperatorAdminOfSession(@SessionToken)),
            @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0;
    IF @caller IS NULL THROW 50021, 'An operator administrator session with MFA is required', 1;
    IF @caller = @OperatorId THROW 50019, 'An operator cannot reset their own account', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_ResetOperator;
    BEGIN TRY
        UPDATE plat.PlatformOperator
           SET Status = 'INVITED', PasswordHash = NULL, MfaEnabled = 0, MfaSecretEnc = NULL, MfaKeyRef = NULL,
               MfaLastUsedStep = NULL, FailedAttempts = 0, FirstFailedAt = NULL, LockedUntil = NULL,
               @SentTo = Email
         WHERE PlatformOperatorId = @OperatorId AND Status IN ('ACTIVE', 'LOCKED');
        IF @@ROWCOUNT = 0 THROW 50016, 'This operator cannot be reset', 1;
        UPDATE plat.OperatorSession SET EndedAt = @now, EndReason = 'OPERATOR_RESET'
         WHERE OperatorId = @OperatorId AND EndedAt IS NULL;
        UPDATE plat.OperatorToken SET RevokedAt = @now WHERE OperatorId = @OperatorId AND UsedAt IS NULL AND RevokedAt IS NULL;
        INSERT plat.OperatorToken (OperatorId, Purpose, TokenHash, ExpiresAt, SentTo, RequestedBy)
        VALUES (@OperatorId, 'RESET', HASHBYTES('SHA2_256', @Token), DATEADD(HOUR, 24, @now), @SentTo, @caller);
        EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_RESET', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
             @ActorOperatorId = @caller, @Severity = 'HIGH', @EntityType = 'plat.PlatformOperator', @EntityId = @OperatorId;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ResetOperator;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
-- DISABLED from INVITED, ACTIVE or LOCKED; ACTIVE again from DISABLED when set up; ARCHIVED from INVITED or DISABLED.
-- Never one's own account, and never below two active operator administrators (DOC-S04 section 12).
CREATE OR ALTER PROCEDURE plat.usp_SetOperatorStatus
    @SessionToken VARBINARY(64),
    @OperatorId   INT,
    @Status       VARCHAR(10)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @caller INT = (SELECT PlatformOperatorId FROM plat.fn_OperatorAdminOfSession(@SessionToken)),
            @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @wasActiveAdmin BIT = 0, @old VARCHAR(10);
    IF @caller IS NULL THROW 50021, 'An operator administrator session with MFA is required', 1;
    IF @caller = @OperatorId THROW 50019, 'An operator cannot change the status of their own account', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_SetOperatorStatus;
    BEGIN TRY
        -- Every check comes before the first write, so a refusal changes nothing even inside a caller's transaction.
        SELECT @wasActiveAdmin = CASE WHEN Role = 'OPERATOR_ADMIN' AND Status = 'ACTIVE' THEN 1 ELSE 0 END, @old = Status
        FROM plat.PlatformOperator WITH (UPDLOCK, HOLDLOCK) WHERE PlatformOperatorId = @OperatorId;
        IF @wasActiveAdmin = 1 AND @Status <> 'ACTIVE'
           AND (SELECT COUNT(*) FROM plat.PlatformOperator WITH (UPDLOCK, HOLDLOCK) WHERE Role = 'OPERATOR_ADMIN' AND Status = 'ACTIVE') <= 2
            THROW 50019, 'At least two active operator administrators must remain', 1;
        UPDATE plat.PlatformOperator
           SET Status = @Status
         WHERE PlatformOperatorId = @OperatorId
           AND (   (@Status = 'DISABLED' AND Status IN ('INVITED', 'ACTIVE', 'LOCKED'))
                OR (@Status = 'ACTIVE'   AND Status = 'DISABLED' AND PasswordHash IS NOT NULL AND MfaEnabled = 1)
                OR (@Status = 'ARCHIVED' AND Status IN ('INVITED', 'DISABLED')));
        IF @@ROWCOUNT = 0 THROW 50019, 'This status change is not allowed', 1;
        IF @Status <> 'ACTIVE'
        BEGIN
            UPDATE plat.OperatorSession SET EndedAt = @now, EndReason = 'OPERATOR_DISABLED'
             WHERE OperatorId = @OperatorId AND EndedAt IS NULL;
            UPDATE plat.OperatorToken SET RevokedAt = @now WHERE OperatorId = @OperatorId AND UsedAt IS NULL AND RevokedAt IS NULL;
        END;
        DECLARE @before NVARCHAR(100) = (SELECT @old AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                @after NVARCHAR(100) = (SELECT @Status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_STATUS_CHANGED', @Category = 'PLATFORM', @ActorType = 'OPERATOR',
             @ActorOperatorId = @caller, @EntityType = 'plat.PlatformOperator', @EntityId = @OperatorId,
             @BeforeJson = @before, @AfterJson = @after;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SetOperatorStatus;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
/* ---------- Support binding ---------- */

CREATE OR ALTER PROCEDURE sec.usp_SetSupportContext
    @TenantId             INT,
    @SupportAccessGrantId BIGINT,
    @OperatorSessionToken VARBINARY(64),
    @ClientIp             VARCHAR(45) = NULL,
    @CorrelationId        UNIQUEIDENTIFIER = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF @TenantId IS NULL OR @SupportAccessGrantId IS NULL OR @OperatorSessionToken IS NULL
        THROW 50001, 'TenantId, SupportAccessGrantId and the operator session token are required', 1;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @own BIT = 0, @oid INT, @gid BIGINT, @granted DATETIME2(3),
            @status VARCHAR(18), @suspendedAt DATETIME2(3), @token UNIQUEIDENTIFIER = NEWID();
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_SetSupportContext;
    BEGIN TRY
        -- Locks held until the binding commits, so a concurrent revocation waits and its trigger finds the binding.
        SELECT @oid = o.PlatformOperatorId
        FROM plat.OperatorSession AS s WITH (UPDLOCK, HOLDLOCK)
        JOIN plat.PlatformOperator AS o WITH (UPDLOCK, HOLDLOCK) ON o.PlatformOperatorId = s.OperatorId
        WHERE s.TokenHash = HASHBYTES('SHA2_256', @OperatorSessionToken)
          AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now AND s.MfaVerifiedAt IS NOT NULL
          AND o.Status = 'ACTIVE';
        IF @oid IS NULL THROW 50003, 'No valid operator session', 1;

        SELECT @gid = g.SupportAccessGrantId, @granted = g.CreatedAt
        FROM plat.SupportAccessGrant AS g WITH (UPDLOCK, HOLDLOCK)
        WHERE g.TenantId = @TenantId AND g.SupportAccessGrantId = @SupportAccessGrantId AND g.OperatorId = @oid
          AND g.RevokedAt IS NULL AND g.StartsAt <= @now AND @now < g.EndsAt
          AND DATEDIFF(MINUTE, g.StartsAt, g.EndsAt) <= 4320;           -- 72 hours at most (BR-PLT-017)
        IF @gid IS NULL THROW 50022, 'No active support grant of this tenant for this operator', 1;

        SELECT @status = Status, @suspendedAt = SuspendedAt
        FROM plat.Tenant WITH (UPDLOCK, HOLDLOCK)
        WHERE TenantId = @TenantId;
        IF NOT (@status IN ('TRIAL', 'ACTIVE') OR (@status = 'SUSPENDED' AND @granted < @suspendedAt))
            THROW 50002, 'This tenant is not available for support', 1;

        IF SESSION_CONTEXT(N'TenantId') IS NOT NULL
            THROW 50004, 'The connection is already bound; reset it (sp_reset_connection) before binding again', 1;

        -- No user: the support connection acts for no tenant user. The keys are read-only like a user binding's.
        EXEC sp_set_session_context N'UserId', NULL, @read_only = 1;
        EXEC sp_set_session_context N'OperatorId', @oid, @read_only = 1;
        EXEC sp_set_session_context N'SupportAccessGrantId', @gid, @read_only = 1;
        EXEC sp_set_session_context N'ClientIp', @ClientIp, @read_only = 1;
        EXEC sp_set_session_context N'CorrelationId', @CorrelationId, @read_only = 1;

        MERGE sec.SessionBinding AS b
        USING (SELECT @@SPID AS SessionId) AS s
           ON b.SessionId = s.SessionId
        WHEN MATCHED THEN
            UPDATE SET BoundTenantId = @TenantId, BoundUserId = 0, BindingToken = @token, BoundAt = SYSUTCDATETIME(),
                       BindingKind = 'SUPPORT', BoundOperatorId = @oid
        WHEN NOT MATCHED THEN
            INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind, BoundOperatorId)
            VALUES (s.SessionId, @TenantId, 0, @token, 'SUPPORT', @oid);
        -- A row of the tenant, with high severity: the tenant sees which operator entered its data (BR-PLT-009).
        EXEC aud.usp_WriteEvent @TenantId = @TenantId, @Action = 'SUPPORT_ACCESS_BOUND', @Category = 'SECURITY', @ActorType = 'OPERATOR',
             @ActorOperatorId = @oid, @Severity = 'HIGH', @EntityType = 'plat.SupportAccessGrant', @EntityId = @gid,
             @IpAddress = @ClientIp, @CorrelationId = @CorrelationId;

        EXEC sp_set_session_context N'BindingToken', @token, @read_only = 1;
        EXEC sp_set_session_context N'TenantId', @TenantId, @read_only = 1;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SetSupportContext;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
/* Revocation of support bindings: a grant revoked, shortened, moved or deleted; an operator session ended or
   deleted; an operator no longer ACTIVE. The next bind checks everything again. */
CREATE OR ALTER TRIGGER plat.TR_SupportAccessGrant_RevokeBinding ON plat.SupportAccessGrant
WITH EXECUTE AS N'tp_auth_exec'
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    DELETE b
    FROM sec.SessionBinding AS b
    WHERE b.BindingKind = 'SUPPORT'
      AND EXISTS (SELECT 1 FROM deleted AS d WHERE d.TenantId = b.BoundTenantId AND d.OperatorId = b.BoundOperatorId);
END;
GO
CREATE OR ALTER TRIGGER plat.TR_OperatorSession_RevokeBinding ON plat.OperatorSession
WITH EXECUTE AS N'tp_auth_exec'
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    DELETE b
    FROM sec.SessionBinding AS b
    WHERE b.BindingKind = 'SUPPORT'
      AND EXISTS (SELECT 1
                  FROM deleted AS d
                  LEFT JOIN inserted AS i ON i.OperatorSessionId = d.OperatorSessionId
                  WHERE d.OperatorId = b.BoundOperatorId
                    AND (i.OperatorSessionId IS NULL OR (i.EndedAt IS NOT NULL AND d.EndedAt IS NULL)));
END;
GO
CREATE OR ALTER TRIGGER plat.TR_PlatformOperator_RevokeBinding ON plat.PlatformOperator
WITH EXECUTE AS N'tp_auth_exec'
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(Status)
        DELETE b
        FROM sec.SessionBinding AS b
        JOIN inserted AS i ON i.PlatformOperatorId = b.BoundOperatorId
        WHERE b.BindingKind = 'SUPPORT' AND i.Status <> 'ACTIVE';
END;
GO
GRANT EXECUTE ON plat.usp_GetOperatorPasswordParams TO [tp_platform];
GRANT EXECUTE ON plat.usp_StartOperatorSession TO [tp_platform];
GRANT EXECUTE ON plat.usp_ConfirmOperatorMfa TO [tp_platform];
GRANT EXECUTE ON plat.usp_TouchOperatorSession TO [tp_platform];
GRANT EXECUTE ON plat.usp_EndOperatorSession TO [tp_platform];
GRANT EXECUTE ON plat.usp_UnlockOperator TO [tp_platform];
GRANT EXECUTE ON plat.usp_InviteOperator TO [tp_platform];
GRANT EXECUTE ON plat.usp_CompleteOperatorSetup TO [tp_platform];
GRANT EXECUTE ON plat.usp_ResetOperator TO [tp_platform];
GRANT EXECUTE ON plat.usp_SetOperatorStatus TO [tp_platform];
GRANT EXECUTE ON sec.usp_SetSupportContext TO [tp_support];
GO
-- The operator panel creates and changes operators only through the procedures above: it cannot insert an operator,
-- set a password, an MFA secret, a role, a status or a lock, or read the hash and the secret. These run after the
-- generated grants (007), which give tp_platform INSERT and UPDATE on plat.PlatformOperator.
DENY INSERT ON [plat].[PlatformOperator] TO [tp_platform];
DENY SELECT ON [plat].[PlatformOperator]([PasswordHash], [MfaSecretEnc]) TO [tp_platform];
DENY UPDATE ON [plat].[PlatformOperator]([Email], [Role], [Status], [PasswordHash], [PasswordChangedAt], [MfaEnabled], [MfaSecretEnc],
    [MfaKeyRef], [MfaEnrolledAt], [MfaLastUsedStep], [FailedAttempts], [FirstFailedAt], [LockedUntil], [LastLoginAt]) TO [tp_platform];
-- The reporting role, and so a support connection, reads no operator session or link (it reads plat by schema grant).
DENY SELECT ON [plat].[OperatorSession] TO [tp_readonly];
DENY SELECT ON [plat].[OperatorToken] TO [tp_readonly];
GO

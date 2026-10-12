/* ============================================================================
   BankFas - 030: login, sessions and connection context (O-01, O-16, O-17)

   Four procedures, all WITH EXECUTE AS N'tp_auth_exec', so they can read the tenant, user and session tables
   before a connection is bound:
     sec.usp_GetPasswordParams  returns the Argon2id parameters and salt of a user (the PHC string without the
                                hash). The application hashes the password the user typed with them (O-01).
     sec.usp_StartSession       compares that hash with the stored one inside the database, applies the lockout
                                rules (BR-PLT-005, FR-PLT-012), and stores the SHA-256 of a random session token
                                that the application holds (FR-PLT-014: 30 minutes idle, 12 hours absolute).
     sec.usp_ConfirmMfa         records the result of the MFA check. The application verifies the TOTP code,
                                because the secret is encrypted with application keys (BR-PLT-006).
     sec.usp_SetSessionContext  binds a connection to the tenant of a valid session. It takes the session token,
                                not a user id, so the caller cannot choose the user (O-17).
   The application role cannot read stored password hashes, insert sessions or change session tokens (020), so it
   cannot replay a hash or mint a session for another user: it needs the user's password.
   The row filters (010) show rows only when the context and the binding agree (O-16).
   The connection pool resets each connection (sp_reset_connection) before reuse, which clears the context.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- policies and procedures keep these options when created
GO
CREATE OR ALTER PROCEDURE sec.usp_GetPasswordParams
    @TenantId INT,
    @Email    NVARCHAR(254),
    @Params   VARCHAR(255) OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @Params = NULL;
    -- Everything before the last '$' of the PHC string: algorithm, version, parameters and salt, but not the hash.
    -- NULL for an unknown user. The application must then answer exactly as for a wrong password (FR-PLT-012).
    SELECT @Params = LEFT(PasswordHash, LEN(PasswordHash) - CHARINDEX('$', REVERSE(PasswordHash)))
    FROM sec.AppUser
    WHERE TenantId = @TenantId AND Email = @Email AND PasswordHash IS NOT NULL;
END;
GO
CREATE OR ALTER PROCEDURE sec.usp_StartSession
    @TenantId     INT,
    @Email        NVARCHAR(254),
    @PasswordHash VARCHAR(255),        -- PHC string the application computed from the typed password
    @SessionToken VARBINARY(64),       -- random token held by the application, at least 32 bytes
    @ClientIp     VARCHAR(45) = NULL,
    @UserAgent    NVARCHAR(400) = NULL,
    @UserId       BIGINT = NULL OUTPUT,
    @MfaRequired  BIT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @UserId = NULL; SET @MfaRequired = NULL;
    IF @TenantId IS NULL OR @Email IS NULL OR @SessionToken IS NULL OR DATALENGTH(@SessionToken) < 32
        THROW 50001, 'TenantId, Email and a session token of at least 32 bytes are required', 1;

    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @own BIT = 0, @outcome VARCHAR(15) = NULL;
    DECLARE @uid BIGINT, @status VARCHAR(10), @stored VARCHAR(255), @mfa BIT, @failed INT, @firstFailed DATETIME2(3),
            @lockedUntil DATETIME2(3), @adminUnlock BIT, @lockouts INT, @lastLockout DATETIME2(3);

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @own = 1;
    END;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM plat.Tenant WITH (UPDLOCK, HOLDLOCK)
                       WHERE TenantId = @TenantId AND Status IN ('TRIAL','ACTIVE','SUSPENDED','ARCHIVED_READ_ONLY'))
            SET @outcome = 'NO_TENANT';
        ELSE
        BEGIN
            SELECT @uid = AppUserId, @status = Status, @stored = PasswordHash, @mfa = MfaEnabled,
                   @failed = FailedAttempts, @firstFailed = FirstFailedAt, @lockedUntil = LockedUntil,
                   @adminUnlock = RequiresAdminUnlock, @lockouts = LockoutCount, @lastLockout = LastLockoutAt
            FROM sec.AppUser WITH (UPDLOCK, HOLDLOCK)
            WHERE TenantId = @TenantId AND Email = @Email;

            IF @uid IS NULL
                SET @outcome = 'FAILED_PASSWORD';                       -- unknown e-mail: logged without a user
            ELSE IF @adminUnlock = 1 OR (@status = 'LOCKED' AND (@lockedUntil IS NULL OR @lockedUntil > @now))
                SET @outcome = 'DENIED_LOCKED';                         -- refused even with the right password
            ELSE IF @status NOT IN ('ACTIVE', 'LOCKED')
                SET @outcome = 'FAILED_PASSWORD';                       -- invited, disabled or archived: no login
            -- The PHC string is base64 and case-sensitive; the database collation is not, so compare in binary.
            ELSE IF @stored IS NULL OR @PasswordHash IS NULL
                 OR @PasswordHash COLLATE Latin1_General_BIN2 <> @stored COLLATE Latin1_General_BIN2
            BEGIN
                -- Five failures within 15 minutes lock the account for 15 minutes; the third lockout within
                -- 24 hours needs an administrator (BR-PLT-005).
                IF @firstFailed IS NULL OR @firstFailed < DATEADD(MINUTE, -15, @now)
                    SELECT @failed = 1, @firstFailed = @now;
                ELSE
                    SET @failed = @failed + 1;
                IF @failed >= 5
                BEGIN
                    SET @lockouts = CASE WHEN @lastLockout >= DATEADD(HOUR, -24, @now) THEN @lockouts + 1 ELSE 1 END;
                    UPDATE sec.AppUser
                       SET Status = 'LOCKED', LockedUntil = DATEADD(MINUTE, 15, @now), FailedAttempts = 0, FirstFailedAt = NULL,
                           LockoutCount = @lockouts, LastLockoutAt = @now,
                           RequiresAdminUnlock = CASE WHEN @lockouts >= 3 THEN 1 ELSE 0 END
                     WHERE TenantId = @TenantId AND AppUserId = @uid;
                    SET @outcome = 'LOCKOUT';
                END
                ELSE
                BEGIN
                    UPDATE sec.AppUser SET FailedAttempts = @failed, FirstFailedAt = @firstFailed
                     WHERE TenantId = @TenantId AND AppUserId = @uid;
                    SET @outcome = 'FAILED_PASSWORD';
                END
            END
            ELSE
            BEGIN
                UPDATE sec.AppUser
                   SET Status = 'ACTIVE', LockedUntil = NULL, FailedAttempts = 0, FirstFailedAt = NULL, LastLoginAt = @now
                 WHERE TenantId = @TenantId AND AppUserId = @uid;
                INSERT sec.UserSession (TenantId, UserId, TokenHash, LastSeenAt, IdleExpiresAt, AbsoluteExpiresAt, IpAddress, UserAgent)
                VALUES (@TenantId, @uid, HASHBYTES('SHA2_256', @SessionToken), @now,
                        DATEADD(MINUTE, 30, @now), DATEADD(HOUR, 12, @now), @ClientIp, @UserAgent);
                SET @outcome = 'LOGIN_SUCCESS';
                SELECT @UserId = @uid, @MfaRequired = @mfa;
            END;

            -- Every attempt is logged (BR-PLT-005). A lockout logs the failed attempt and the lockout.
            INSERT sec.LoginAttempt (TenantId, UserId, LoginName, Outcome, IpAddress, UserAgent)
            VALUES (@TenantId, @uid, CASE WHEN @uid IS NULL THEN @Email END,
                    CASE WHEN @outcome = 'LOCKOUT' THEN 'FAILED_PASSWORD' ELSE @outcome END, @ClientIp, @UserAgent);
            IF @outcome = 'LOCKOUT'
                INSERT sec.LoginAttempt (TenantId, UserId, LoginName, Outcome, IpAddress, UserAgent)
                VALUES (@TenantId, @uid, NULL, 'LOCKOUT', @ClientIp, @UserAgent);
        END;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    -- One message for every failure, raised after the attempt is committed (FR-PLT-012).
    IF @outcome <> 'LOGIN_SUCCESS'
        THROW 50005, 'Invalid e-mail or password', 1;
END;
GO
CREATE OR ALTER PROCEDURE sec.usp_ConfirmMfa
    @TenantId     INT,
    @SessionToken VARBINARY(64),
    @Passed       BIT,                 -- result of the TOTP check done by the application
    @ClientIp     VARCHAR(45) = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @sid BIGINT, @uid BIGINT;
    SELECT @sid = UserSessionId, @uid = UserId
    FROM sec.UserSession
    WHERE TenantId = @TenantId AND TokenHash = HASHBYTES('SHA2_256', @SessionToken)
      AND EndedAt IS NULL AND IdleExpiresAt > @now AND AbsoluteExpiresAt > @now;
    IF @sid IS NULL THROW 50003, 'No valid session for this tenant', 1;

    IF @Passed = 1
        UPDATE sec.UserSession SET MfaVerifiedAt = @now WHERE UserSessionId = @sid;
    ELSE
        INSERT sec.LoginAttempt (TenantId, UserId, Outcome, IpAddress) VALUES (@TenantId, @uid, 'FAILED_MFA', @ClientIp);
END;
GO
CREATE OR ALTER PROCEDURE sec.usp_SetSessionContext
    @TenantId      INT,
    @SessionToken  VARBINARY(64),
    @ClientIp      VARCHAR(45) = NULL,
    @CorrelationId UNIQUEIDENTIFIER = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF @TenantId IS NULL OR @SessionToken IS NULL THROW 50001, 'TenantId and SessionToken are required', 1;

    DECLARE @own BIT = 0, @UserId BIGINT, @now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @own = 1;
    END;
    BEGIN TRY
        -- The locks last until the binding commits: a concurrent disable, close or logout waits here, and its
        -- revocation trigger then finds the new binding (OUT-01).
        IF NOT EXISTS (SELECT 1 FROM plat.Tenant WITH (UPDLOCK, HOLDLOCK)
                       WHERE TenantId = @TenantId AND Status IN ('TRIAL','ACTIVE','SUSPENDED','ARCHIVED_READ_ONLY'))
            THROW 50002, 'Unknown or closed tenant', 1;

        -- The user comes from the session, never from the caller (O-17).
        SELECT @UserId = s.UserId
        FROM sec.UserSession AS s WITH (UPDLOCK, HOLDLOCK)
        JOIN sec.AppUser AS u WITH (UPDLOCK, HOLDLOCK) ON u.TenantId = s.TenantId AND u.AppUserId = s.UserId
        WHERE s.TenantId = @TenantId
          AND s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
          AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now
          AND u.Status = 'ACTIVE'
          AND (u.MfaEnabled = 0 OR s.MfaVerifiedAt IS NOT NULL);
        IF @UserId IS NULL THROW 50003, 'No valid session for this tenant', 1;

        IF SESSION_CONTEXT(N'TenantId') IS NOT NULL
            THROW 50004, 'The connection is already bound; reset it (sp_reset_connection) before binding again', 1;

        -- Auxiliary keys first: a refused key stops the call before any binding is written (CTX-4).
        EXEC sp_set_session_context N'UserId', @UserId, @read_only = 1;
        EXEC sp_set_session_context N'ClientIp', @ClientIp, @read_only = 1;
        EXEC sp_set_session_context N'CorrelationId', @CorrelationId, @read_only = 1;

        MERGE sec.SessionBinding AS b
        USING (SELECT @@SPID AS SessionId) AS s
           ON b.SessionId = s.SessionId
        WHEN MATCHED THEN
            UPDATE SET BoundTenantId = @TenantId, BoundUserId = @UserId, BindingToken = @token, BoundAt = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (s.SessionId, @TenantId, @UserId, @token);

        -- The token and the tenant come last: the row filters need both.
        EXEC sp_set_session_context N'BindingToken', @token, @read_only = 1;
        EXEC sp_set_session_context N'TenantId', @TenantId, @read_only = 1;

        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
GRANT EXECUTE ON sec.usp_GetPasswordParams TO [tp_app];
GRANT EXECUTE ON sec.usp_StartSession TO [tp_app];
GRANT EXECUTE ON sec.usp_ConfirmMfa TO [tp_app];
GRANT EXECUTE ON sec.usp_SetSessionContext TO [tp_app];
GO
-- The application role cannot read stored password hashes (no replay), cannot create sessions, and cannot change the
-- tenant, user, token or MFA mark of a session; only the procedures above do that (O-17). These DENYs must run after
-- the generated table grants (007), which GRANT SELECT, INSERT and UPDATE on these tables and would remove them.
DENY SELECT ON [sec].[AppUser]([PasswordHash]) TO [tp_app];
DENY INSERT ON [sec].[UserSession] TO [tp_app];
DENY UPDATE ON [sec].[UserSession]([TenantId], [UserId], [TokenHash], [MfaVerifiedAt]) TO [tp_app];
GO
/* Revocation: a binding ends when its user is no longer ACTIVE or is deleted, when its tenant is no longer TRIAL
   or ACTIVE, or when a session of its user is ended or deleted (FR-PLT-014: an administrator's termination takes
   effect at once). The connection then sees no rows, and it cannot bind again without a reset.
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
CREATE OR ALTER TRIGGER sec.TR_AppUser_RevokeBindingOnDelete ON sec.AppUser
WITH EXECUTE AS N'tp_auth_exec'
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    DELETE b
    FROM sec.SessionBinding AS b
    JOIN deleted AS d ON d.AppUserId = b.BoundUserId AND d.TenantId = b.BoundTenantId;
END;
GO
CREATE OR ALTER TRIGGER sec.TR_UserSession_RevokeBinding ON sec.UserSession
WITH EXECUTE AS N'tp_auth_exec'
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    -- A session that is deleted, or whose EndedAt is set now, revokes the bindings of its user.
    DELETE b
    FROM sec.SessionBinding AS b
    WHERE EXISTS (SELECT 1
                  FROM deleted AS d
                  LEFT JOIN inserted AS i ON i.UserSessionId = d.UserSessionId
                  WHERE d.TenantId = b.BoundTenantId AND d.UserId = b.BoundUserId
                    AND (i.UserSessionId IS NULL OR (i.EndedAt IS NOT NULL AND d.EndedAt IS NULL)));
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

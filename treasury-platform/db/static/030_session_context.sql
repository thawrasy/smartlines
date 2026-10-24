/* ============================================================================
   BankFas - 030: login, sessions and connection context (O-01, O-16, O-17, O-18, ADR 0002, ADR 0003)

   Procedures, all WITH EXECUTE AS N'tp_auth_exec', so they can read the tenant, user and session tables
   before a connection is bound:
     sec.usp_GetPasswordParams  returns the Argon2id parameters and salt of a user (the PHC string without the
                                hash). The application hashes the password the user typed with them (O-01).
     sec.usp_StartSession       compares that hash with the stored one inside the database, applies the lockout
                                rules (BR-PLT-005, FR-PLT-012), checks the tenant status against the user's role
                                (O-18), and stores the SHA-256 of a random session token that the application holds
                                (FR-PLT-014: 30 minutes idle, 12 hours absolute; a tenant may set shorter ones,
                                FR-PLT-043, read through cfg.fn_SettingInt).
     sec.usp_ConfirmMfa         records the result of the TOTP check. The application verifies the code, because the
                                secret is encrypted with application keys (BR-PLT-006). A reused time step, or none,
                                counts as a failure, and failures count toward the lockout (ADR 0003); @Accepted says
                                which it was (GAP-4). A session whose check is done takes another one the same way
                                before a sensitive action (step-up, sec.usp_GetMfaChallenge @StepUp = 1).
     sec.usp_SetSessionContext  binds a connection to the tenant of a valid session. It takes the session token,
                                not a user id, so the caller cannot choose the user (O-17). Every non-system user
                                needs a recorded MFA check (ADR 0003), and the tenant status decides who may bind:
                                sec.fn_TenantLoginAllowed (O-18).
   Account changes (password, MFA enrolment, recovery codes, tokens, status) are in 035.
   The application role cannot read stored password hashes, insert sessions or change sessions (030, 035), so it
   cannot replay a hash or mint a session for another user: it needs the user's password.
   The row filters (010) show rows only when the context and the binding agree (O-16).
   The connection pool resets each connection (sp_reset_connection) before reuse, which clears the context.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- policies and procedures keep these options when created
GO
/* Who may use a tenant (O-18, DOC-F04 section 7.4, owner decision 2026-10-12):
     TRIAL, ACTIVE                 every active user of the tenant
     SUSPENDED                     the tenant administrator only (system role TA); writes stay refused (010)
     CLOSED, within 30 days        the tenant administrator only, for export (BR-PLT-002)
     CLOSED after 30 days,
     ARCHIVED_READ_ONLY            nobody from the tenant
   sec.fn_TenantOpen says whether the tenant can be used at all; sec.fn_TenantLoginAllowed adds the role check. */
CREATE OR ALTER FUNCTION sec.fn_TenantOpen (@TenantId INT)
RETURNS TABLE
AS RETURN
    SELECT t.Status
    FROM plat.Tenant AS t
    WHERE t.TenantId = @TenantId
      AND (t.Status IN ('TRIAL', 'ACTIVE', 'SUSPENDED')
           OR (t.Status = 'CLOSED' AND SYSUTCDATETIME() < DATEADD(DAY, 30, t.ClosedAt)));
GO
CREATE OR ALTER FUNCTION sec.fn_TenantLoginAllowed (@TenantId INT, @UserId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT 1 AS Allowed
    FROM sec.fn_TenantOpen(@TenantId) AS t
    WHERE t.Status IN ('TRIAL', 'ACTIVE')
       OR EXISTS (SELECT 1
                  FROM sec.UserRole AS ur
                  JOIN sec.Role AS r ON r.TenantId = ur.TenantId AND r.RoleId = ur.RoleId
                  WHERE ur.TenantId = @TenantId AND ur.UserId = @UserId
                    AND r.Code = 'TA' AND r.IsSystem = 1 AND r.IsActive = 1);
GO
/* One failed proof of identity (password, TOTP or recovery code): five within 15 minutes (a tenant may set three
   or four, security.lockout.threshold) lock the account for 15 minutes; the third lockout within 24 hours needs an administrator (BR-PLT-005). Service accounts are never
   counted, so nobody can lock them by guessing (they have no password). Internal: not granted to tp_app. */
CREATE OR ALTER PROCEDURE sec.usp_RecordAuthFailure
    @TenantId  INT,
    @UserId    BIGINT,
    @ClientIp  VARCHAR(45) = NULL,
    @UserAgent NVARCHAR(400) = NULL,
    @Locked    BIT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @Locked = 0;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @failed INT, @firstFailed DATETIME2(3), @lockouts INT,
            @lastLockout DATETIME2(3), @found BIT = 0,
            @threshold INT = (SELECT Value FROM cfg.fn_SettingInt(@TenantId, 'security.lockout.threshold', 5));
    SELECT @found = 1, @failed = FailedAttempts, @firstFailed = FirstFailedAt, @lockouts = LockoutCount, @lastLockout = LastLockoutAt
    FROM sec.AppUser WITH (UPDLOCK, HOLDLOCK)
    WHERE TenantId = @TenantId AND AppUserId = @UserId AND IsSystemUser = 0;
    IF @found = 0 RETURN;

    IF @firstFailed IS NULL OR @firstFailed < DATEADD(MINUTE, -15, @now)
        SELECT @failed = 1, @firstFailed = @now;
    ELSE
        SET @failed = @failed + 1;
    IF @failed >= @threshold
    BEGIN
        SET @lockouts = CASE WHEN @lastLockout >= DATEADD(HOUR, -24, @now) THEN @lockouts + 1 ELSE 1 END;
        UPDATE sec.AppUser
           SET Status = 'LOCKED', LockedUntil = DATEADD(MINUTE, 15, @now), FailedAttempts = 0, FirstFailedAt = NULL,
               LockoutCount = @lockouts, LastLockoutAt = @now,
               RequiresAdminUnlock = CASE WHEN @lockouts >= 3 THEN 1 ELSE 0 END
         WHERE TenantId = @TenantId AND AppUserId = @UserId;
        INSERT sec.LoginAttempt (TenantId, UserId, Outcome, IpAddress, UserAgent)
        VALUES (@TenantId, @UserId, 'LOCKOUT', @ClientIp, @UserAgent);
        -- SEC.LOCKOUT to the account administrators (spec 13 section 9.2, S1-GAP-9): a notification request in the outbox,
        -- with the user's name and the time only; JOB-PLT-OUTBOX turns it into notifications within the minute.
        INSERT cfg.OutboxEvent (TenantId, EventName, AggregateType, AggregateId, PayloadJson)
        SELECT @TenantId, 'notification.requested', 'sec.AppUser', @UserId,
               (SELECT 'SEC.LOCKOUT' AS eventCode, 'sec.AppUser' AS targetType, @UserId AS targetId,
                       CONCAT('SEC.LOCKOUT:sec.AppUser:', @UserId, ':', CONVERT(CHAR(8), @now, 112), REPLACE(CONVERT(CHAR(8), @now, 108), ':', '')) AS dedupKey,
                       JSON_QUERY((SELECT ISNULL(u.DisplayNameAr, u.Email) AS userName, CONCAT(CONVERT(CHAR(16), @now, 120), ' UTC') AS occurredAt
                                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS [values]
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
          FROM sec.AppUser AS u WHERE u.TenantId = @TenantId AND u.AppUserId = @UserId;
        SET @Locked = 1;
    END
    ELSE
        UPDATE sec.AppUser SET FailedAttempts = @failed, FirstFailedAt = @firstFailed
         WHERE TenantId = @TenantId AND AppUserId = @UserId;
END;
GO
/* The user a sign-in names (docs/31 row 46, ADR 0048): the e-mail, the employee code or the mobile number, as far as
   the tenant's security.login.identifiers allows (else the platform default; an empty or unknown list means EMAIL).
   A mobile number is compared without spaces, dashes or brackets, with 00 read as +. A login that names more than one
   user names none, so the answer is the same as for an unknown user. */
CREATE OR ALTER FUNCTION sec.fn_LoginUser (@TenantId INT, @Login NVARCHAR(254))
RETURNS TABLE
AS RETURN
    WITH listed AS (
        SELECT UPPER(LTRIM(RTRIM(x.value))) AS Kind
        FROM STRING_SPLIT(COALESCE(
                 (SELECT JSON_VALUE(N'[' + ts.ValueJson + N']', '$[0]') FROM cfg.TenantSetting AS ts
                  WHERE ts.TenantId = @TenantId AND ts.[Key] = 'security.login.identifiers'),
                 (SELECT JSON_VALUE(N'[' + sd.DefaultValueJson + N']', '$[0]') FROM cfg.SettingDefinition AS sd
                  WHERE sd.[Key] = 'security.login.identifiers'),
                 N'EMAIL'), ',') AS x),
    kinds AS (
        SELECT Kind FROM listed WHERE Kind IN ('EMAIL', 'EMPLOYEE_CODE', 'MOBILE')
        UNION
        SELECT 'EMAIL' WHERE NOT EXISTS (SELECT 1 FROM listed WHERE Kind IN ('EMAIL', 'EMPLOYEE_CODE', 'MOBILE'))),
    typed AS (
        SELECT LTRIM(RTRIM(@Login)) AS Login,
               REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Login)), N' ', N''), N'-', N''), N'(', N''), N')', N'') AS Digits),
    matched AS (
        SELECT DISTINCT u.AppUserId
        FROM sec.AppUser AS u CROSS JOIN typed AS t
        WHERE u.TenantId = @TenantId
          AND (   (u.Email = t.Login AND EXISTS (SELECT 1 FROM kinds WHERE Kind = 'EMAIL'))
               OR (u.EmployeeCode = t.Login AND EXISTS (SELECT 1 FROM kinds WHERE Kind = 'EMPLOYEE_CODE'))
               OR (u.Mobile = CASE WHEN t.Digits LIKE N'00%' THEN N'+' + SUBSTRING(t.Digits, 3, 20) ELSE t.Digits END
                   AND EXISTS (SELECT 1 FROM kinds WHERE Kind = 'MOBILE'))))
    SELECT AppUserId FROM matched WHERE (SELECT COUNT(*) FROM matched) = 1;
GO
/* Whether a tenant's users complete two-step verification at sign-in (docs/31 row 46, ADR 0048): the tenant's
   MfaPolicy set by the platform administration, else the platform setting security.mfa.required, else 1. A user who
   enrolled is asked in any case (sec.usp_StartSession). */
CREATE OR ALTER FUNCTION sec.fn_MfaRequired (@TenantId INT)
RETURNS TABLE
AS RETURN
    SELECT CAST(CASE t.MfaPolicy
                    WHEN 'REQUIRED' THEN 1
                    WHEN 'OFF' THEN 0
                    ELSE CASE WHEN (SELECT JSON_VALUE(N'[' + sd.DefaultValueJson + N']', '$[0]') FROM cfg.SettingDefinition AS sd
                                    WHERE sd.[Key] = 'security.mfa.required') = N'false' THEN 0 ELSE 1 END
                END AS BIT) AS Required
    FROM plat.Tenant AS t
    WHERE t.TenantId = @TenantId;
GO
CREATE OR ALTER PROCEDURE sec.usp_GetPasswordParams
    @TenantId INT,
    @Login    NVARCHAR(254),       -- the e-mail, employee code or mobile number (sec.fn_LoginUser)
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
    WHERE TenantId = @TenantId AND PasswordHash IS NOT NULL
      AND AppUserId = (SELECT AppUserId FROM sec.fn_LoginUser(@TenantId, @Login));
END;
GO
CREATE OR ALTER PROCEDURE sec.usp_StartSession
    @TenantId     INT,
    @Login        NVARCHAR(254),       -- the e-mail, employee code or mobile number (sec.fn_LoginUser)
    @PasswordHash VARCHAR(255),        -- PHC string the application computed from the typed password
    @SessionToken VARBINARY(64),       -- random token held by the application, at least 32 bytes
    @ClientIp     VARCHAR(45) = NULL,
    @UserAgent    NVARCHAR(400) = NULL,
    @UserId       BIGINT = NULL OUTPUT,
    @MfaRequired  BIT = NULL OUTPUT,   -- 1 when the user completes MFA before the session binds: enrolled, or required (sec.fn_MfaRequired)
    @MfaEnrolmentRequired BIT = NULL OUTPUT,  -- 1 when MFA is required and the user has none yet: enrol first (035)
    @MustChangePassword BIT = NULL OUTPUT     -- 1 for a temporary password: change it before the session binds (ADR 0048)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @UserId = NULL; SET @MfaRequired = NULL; SET @MfaEnrolmentRequired = NULL; SET @MustChangePassword = NULL;
    IF @TenantId IS NULL OR @Login IS NULL OR @SessionToken IS NULL OR DATALENGTH(@SessionToken) < 32
        THROW 50001, 'TenantId, Login and a session token of at least 32 bytes are required', 1;

    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @own BIT = 0, @outcome VARCHAR(15) = NULL, @locked BIT;
    DECLARE @uid BIGINT, @status VARCHAR(10), @stored VARCHAR(255), @mfa BIT, @system BIT,
            @lockedUntil DATETIME2(3), @adminUnlock BIT, @mustChange BIT, @mfaPolicy BIT;

    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_StartSession;
    BEGIN TRY
        -- Unknown tenants, and tenants nobody may use any more, fail before the password is looked at.
        IF NOT EXISTS (SELECT 1 FROM plat.Tenant WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @TenantId)
           OR NOT EXISTS (SELECT 1 FROM sec.fn_TenantOpen(@TenantId))
            SET @outcome = 'NO_TENANT';
        ELSE
        BEGIN
            SELECT @uid = AppUserId, @status = Status, @stored = PasswordHash, @mfa = MfaEnabled, @system = IsSystemUser,
                   @lockedUntil = LockedUntil, @adminUnlock = RequiresAdminUnlock, @mustChange = MustChangePassword
            FROM sec.AppUser WITH (UPDLOCK, HOLDLOCK)
            WHERE TenantId = @TenantId AND AppUserId = (SELECT AppUserId FROM sec.fn_LoginUser(@TenantId, @Login));

            IF @uid IS NULL OR @system = 1
                SET @outcome = 'FAILED_PASSWORD';                       -- unknown login or service account: not counted
            ELSE IF @adminUnlock = 1 OR (@status = 'LOCKED' AND (@lockedUntil IS NULL OR @lockedUntil > @now))
                SET @outcome = 'DENIED_LOCKED';                         -- refused even with the right password
            ELSE IF @status NOT IN ('ACTIVE', 'LOCKED')
                SET @outcome = 'FAILED_PASSWORD';                       -- invited, disabled or archived: no login
            -- The PHC string is base64 and case-sensitive; the database collation is not, so compare in binary.
            ELSE IF @stored IS NULL OR @PasswordHash IS NULL
                 OR @PasswordHash COLLATE Latin1_General_BIN2 <> @stored COLLATE Latin1_General_BIN2
            BEGIN
                EXEC sec.usp_RecordAuthFailure @TenantId, @uid, @ClientIp, @UserAgent, @locked OUTPUT;
                SET @outcome = 'FAILED_PASSWORD';
            END
            -- The password is right, but the tenant status does not admit this user (O-18). Said only now, so an
            -- unknown caller learns nothing about the tenant (DQ-F03-11).
            ELSE IF NOT EXISTS (SELECT 1 FROM sec.fn_TenantLoginAllowed(@TenantId, @uid))
                SET @outcome = 'DENIED_TENANT';
            ELSE
            BEGIN
                DECLARE @idle INT = (SELECT Value FROM cfg.fn_SettingInt(@TenantId, 'security.session.idle_minutes', 30)),
                        @absolute INT = (SELECT Value FROM cfg.fn_SettingInt(@TenantId, 'security.session.absolute_hours', 12));
                SET @mfaPolicy = ISNULL((SELECT Required FROM sec.fn_MfaRequired(@TenantId)), 1);
                UPDATE sec.AppUser
                   SET Status = 'ACTIVE', LockedUntil = NULL, FailedAttempts = 0, FirstFailedAt = NULL, LastLoginAt = @now
                 WHERE TenantId = @TenantId AND AppUserId = @uid;
                INSERT sec.UserSession (TenantId, UserId, TokenHash, LastSeenAt, IdleExpiresAt, AbsoluteExpiresAt, IpAddress, UserAgent, MfaRequired)
                VALUES (@TenantId, @uid, HASHBYTES('SHA2_256', @SessionToken), @now,
                        DATEADD(MINUTE, @idle, @now), DATEADD(HOUR, @absolute, @now), @ClientIp, @UserAgent,
                        CASE WHEN @mfa = 1 OR @mfaPolicy = 1 THEN 1 ELSE 0 END);
                SET @outcome = 'LOGIN_SUCCESS';
                SELECT @UserId = @uid, @MfaRequired = CASE WHEN @mfa = 1 OR @mfaPolicy = 1 THEN 1 ELSE 0 END,
                       @MfaEnrolmentRequired = CASE WHEN @mfa = 0 AND @mfaPolicy = 1 THEN 1 ELSE 0 END,
                       @MustChangePassword = @mustChange;
            END;

            -- Every attempt is logged (BR-PLT-005); a lockout adds its own row (usp_RecordAuthFailure).
            INSERT sec.LoginAttempt (TenantId, UserId, LoginName, Outcome, IpAddress, UserAgent)
            VALUES (@TenantId, @uid, CASE WHEN @uid IS NULL THEN LEFT(@Login, 200) END, @outcome, @ClientIp, @UserAgent);
        END;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_StartSession;   -- undo this procedure only
        THROW;
    END CATCH;

    -- Raised after the attempt is committed. One message for every failure before the password is proven
    -- (FR-PLT-012); a proven password in a tenant closed to this user gets its own error.
    IF @outcome = 'DENIED_TENANT'
        THROW 50006, 'This tenant is not available to this user', 1;
    IF @outcome <> 'LOGIN_SUCCESS'
        THROW 50005, 'Invalid sign-in name or password', 1;
END;
GO
CREATE OR ALTER PROCEDURE sec.usp_ConfirmMfa
    @TenantId     INT,
    @SessionToken VARBINARY(64),
    @Passed       BIT,                 -- result of the TOTP check done by the application
    @ClientIp     VARCHAR(45) = NULL,
    @Step         BIGINT = NULL,       -- TOTP time step of the accepted code; a step not after the last one is a replay
    @Accepted     BIT = NULL OUTPUT    -- 1 when the check was recorded; 0 for a failed or replayed code (GAP-4)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @sid BIGINT, @uid BIGINT, @enrolled BIT, @lastStep BIGINT,
            @own BIT = 0, @locked BIT;
    SET @Accepted = 0;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_ConfirmMfa;
    BEGIN TRY
        SELECT @sid = s.UserSessionId, @uid = s.UserId, @enrolled = u.MfaEnabled, @lastStep = u.MfaLastUsedStep
        FROM sec.UserSession AS s WITH (UPDLOCK, HOLDLOCK)
        JOIN sec.AppUser AS u WITH (UPDLOCK, HOLDLOCK) ON u.TenantId = s.TenantId AND u.AppUserId = s.UserId
        WHERE s.TenantId = @TenantId AND s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
          AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now
          AND u.Status = 'ACTIVE' AND u.IsSystemUser = 0;
        IF @sid IS NULL THROW 50003, 'No valid session for this tenant', 1;
        IF @enrolled = 0 THROW 50008, 'MFA enrolment is required first', 1;

        IF @Passed = 1 AND (@Step IS NULL OR (@lastStep IS NOT NULL AND @Step <= @lastStep))
            SET @Passed = 0;                                            -- a replayed code, or no step to check it against

        IF @Passed = 1
        BEGIN
            UPDATE sec.UserSession SET MfaVerifiedAt = @now WHERE UserSessionId = @sid;
            UPDATE sec.AppUser SET MfaLastUsedStep = COALESCE(@Step, MfaLastUsedStep)
             WHERE TenantId = @TenantId AND AppUserId = @uid;
            SET @Accepted = 1;
        END
        ELSE
        BEGIN
            INSERT sec.LoginAttempt (TenantId, UserId, Outcome, IpAddress) VALUES (@TenantId, @uid, 'FAILED_MFA', @ClientIp);
            EXEC sec.usp_RecordAuthFailure @TenantId, @uid, @ClientIp, NULL, @locked OUTPUT;
            IF @locked = 1                                              -- the lockout also ends this session
                UPDATE sec.UserSession SET EndedAt = @now, EndReason = 'MFA_FAILED' WHERE UserSessionId = @sid;
        END;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ConfirmMfa;   -- undo this procedure only
        SET @Accepted = 0;
        THROW;
    END CATCH;
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
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_SetSessionContext;
    BEGIN TRY
        -- The locks last until the binding commits: a concurrent disable, close or logout waits here, and its
        -- revocation trigger then finds the new binding (OUT-01).
        IF NOT EXISTS (SELECT 1 FROM plat.Tenant WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @TenantId)
           OR NOT EXISTS (SELECT 1 FROM sec.fn_TenantOpen(@TenantId))
            THROW 50002, 'Unknown or closed tenant', 1;

        -- The user comes from the session, never from the caller (O-17). A non-system user needs a recorded MFA check,
        -- unless the session started without one and MFA is still not required of this user now (ADR 0048); a
        -- temporary password must be changed first; and the tenant status must admit the user's role (O-18).
        SELECT @UserId = s.UserId
        FROM sec.UserSession AS s WITH (UPDLOCK, HOLDLOCK)
        JOIN sec.AppUser AS u WITH (UPDLOCK, HOLDLOCK) ON u.TenantId = s.TenantId AND u.AppUserId = s.UserId
        WHERE s.TenantId = @TenantId
          AND s.TokenHash = HASHBYTES('SHA2_256', @SessionToken)
          AND s.EndedAt IS NULL AND s.IdleExpiresAt > @now AND s.AbsoluteExpiresAt > @now
          AND u.Status = 'ACTIVE' AND u.IsSystemUser = 0 AND u.MustChangePassword = 0
          AND (s.MfaVerifiedAt IS NOT NULL
               OR (s.MfaRequired = 0 AND u.MfaEnabled = 0 AND EXISTS (SELECT 1 FROM sec.fn_MfaRequired(@TenantId) WHERE Required = 0)))
          AND EXISTS (SELECT 1 FROM sec.fn_TenantLoginAllowed(@TenantId, s.UserId));
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
            UPDATE SET BoundTenantId = @TenantId, BoundUserId = @UserId, BindingToken = @token, BoundAt = SYSUTCDATETIME(),
                       BindingKind = 'USER', BoundOperatorId = NULL
        WHEN NOT MATCHED THEN
            INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind)
            VALUES (s.SessionId, @TenantId, @UserId, @token, 'USER');

        -- The token and the tenant come last: the row filters need both.
        EXEC sp_set_session_context N'BindingToken', @token, @read_only = 1;
        EXEC sp_set_session_context N'TenantId', @TenantId, @read_only = 1;

        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SetSessionContext;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
GRANT EXECUTE ON sec.usp_GetPasswordParams TO [tp_app];
GRANT EXECUTE ON sec.usp_StartSession TO [tp_app];
GRANT EXECUTE ON sec.usp_ConfirmMfa TO [tp_app];
GRANT EXECUTE ON sec.usp_SetSessionContext TO [tp_app];
GO
-- The application role cannot read stored password hashes (no replay) and cannot create or change sessions; only
-- the procedures here and in 035 do that (O-17, ADR 0003). These DENYs must run after the generated table grants
-- (007), which GRANT SELECT, INSERT and UPDATE on these tables and would remove them.
DENY SELECT ON [sec].[AppUser]([PasswordHash]) TO [tp_app];
DENY INSERT ON [sec].[UserSession] TO [tp_app];
DENY UPDATE ON [sec].[UserSession] TO [tp_app];
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

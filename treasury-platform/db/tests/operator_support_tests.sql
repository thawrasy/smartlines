/* ============================================================================
   Operator login and accounts, and the temporary support binding (db/static/036_operator_and_support.sql,
   ADR 0004, DQ-S04-10, DQ-F04-6, DQ-F07-3). The cases run as the operator panel (tp_platform), the support
   connection (tp_support), the tenant application (tp_app) and the reporting role (tp_readonly).

   Run against a deployed BankFas database that holds no real data and no operators, with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/operator_support_tests.sql
   One transaction with a savepoint per case, rolled back at the end. A successful binding makes the context
   read-only, so P8 checks the tenant-status rule by presetting the context: the procedure then stops at 50004
   only after every other check has passed. P10 is the one real support binding and runs last; P11 checks the
   audit row it wrote (ADR 0007).
   Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
BEGIN TRANSACTION;
CREATE USER [tp_test_panel] WITHOUT LOGIN;
CREATE USER [tp_test_sup] WITHOUT LOGIN;
CREATE USER [tp_test_app] WITHOUT LOGIN;
CREATE USER [tp_test_ro] WITHOUT LOGIN;
CREATE USER [tp_test_oread] WITHOUT LOGIN;              -- reads every audit row (tp_auth passes the row filters)
ALTER ROLE [tp_platform] ADD MEMBER [tp_test_panel];
ALTER ROLE [tp_support] ADD MEMBER [tp_test_sup];
ALTER ROLE [tp_app] ADD MEMBER [tp_test_app];
ALTER ROLE [tp_readonly] ADD MEMBER [tp_test_ro];
ALTER ROLE [tp_auth] ADD MEMBER [tp_test_oread];
ALTER ROLE [db_datareader] ADD MEMBER [tp_test_oread];
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT ALL;      -- plan and country rows are not seeded
ALTER TABLE sec.AppUser NOCHECK CONSTRAINT ALL;
GO
CREATE PROCEDURE #Bind @TenantId INT
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    MERGE sec.SessionBinding AS b
    USING (SELECT @@SPID AS SessionId) AS s ON b.SessionId = s.SessionId
    WHEN MATCHED THEN UPDATE SET BoundTenantId = @TenantId, BoundUserId = 0, BindingToken = @token, BoundAt = SYSUTCDATETIME(),
                                 BindingKind = 'USER', BoundOperatorId = NULL
    WHEN NOT MATCHED THEN INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (s.SessionId, @TenantId, 0, @token);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
END;
GO

DECLARE @tA INT, @tB INT, @tS INT, @tC INT, @uA BIGINT, @uB BIGINT, @uS BIGINT, @uC BIGINT;
DECLARE @op1 INT, @op2 INT, @op3 INT, @x INT;
DECLARE @pw1 VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$b3Axcw$b3AxaA', @pw2 VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$b3Aycw$b3AyaA',
        @pw3 VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$b3Azcw$b3AzaA', @pwBad VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$b3Azcw$YmFk';
DECLARE @sec VARBINARY(256) = CRYPT_GEN_RANDOM(48);
DECLARE @lk1 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @lk2 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @lk3 VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @lk4 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @lk5 VARBINARY(64) = CRYPT_GEN_RANDOM(32);
DECLARE @os1 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @os2 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @os3 VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @os3u VARBINARY(64) = CRYPT_GEN_RANDOM(32), @os4 VARBINARY(64) = CRYPT_GEN_RANDOM(32);
DECLARE @gA BIGINT, @gOther BIGINT, @gRevoked BIGINT, @gExpired BIGINT, @gFuture BIGINT, @gLong BIGINT, @gSBefore BIGINT,
        @gSAfter BIGINT, @gC BIGINT, @g BIGINT;
DECLARE @e1 INT, @e2 INT, @e3 INT, @e4 INT, @e5 INT, @e6 INT, @e7 INT, @n INT, @n2 INT, @n3 INT, @i INT, @sent NVARCHAR(254);
DECLARE @now DATETIME2(3) = SYSUTCDATETIME();

-- Seed: four tenants with one user each. S and C are seeded while active (writes need an open tenant) and are
-- suspended (since yesterday) and closed (five days ago) at the end of the seed.
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone)
VALUES ('TST-SA', N'A', N'A', 1, 1, 'ACTIVE', 'UTC'), ('TST-SB', N'B', N'B', 1, 1, 'ACTIVE', 'UTC'),
       ('TST-SS', N'S', N'S', 1, 1, 'ACTIVE', 'UTC'), ('TST-SC', N'C', N'C', 1, 1, 'ACTIVE', 'UTC');
SELECT @tA = TenantId FROM plat.Tenant WHERE Code = 'TST-SA';
SELECT @tB = TenantId FROM plat.Tenant WHERE Code = 'TST-SB';
SELECT @tS = TenantId FROM plat.Tenant WHERE Code = 'TST-SS';
SELECT @tC = TenantId FROM plat.Tenant WHERE Code = 'TST-SC';
EXEC #Bind @tA; INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@tA, N'ta@a.invalid', N'TA', 'ACTIVE', @pw1);
SELECT @uA = AppUserId FROM sec.AppUser WHERE Email = N'ta@a.invalid';
EXEC #Bind @tB; INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status) VALUES (@tB, N'ta@b.invalid', N'TB', 'INVITED');
SELECT @uB = AppUserId FROM sec.AppUser WHERE Email = N'ta@b.invalid';

-- Seed: the first operator administrator at deployment, then two more through the panel's own procedures
EXEC plat.usp_BootstrapOperator @Email = N'op1@test.invalid', @DisplayName = N'Operator 1', @Token = @lk1, @OperatorId = @op1 OUTPUT;
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_CompleteOperatorSetup @Token = @lk1, @NewPasswordHash = @pw1, @MfaSecretEnc = @sec, @MfaKeyRef = 'kms/platform/1', @Step = 1000;
EXEC plat.usp_StartOperatorSession @Email = N'op1@test.invalid', @PasswordHash = @pw1, @SessionToken = @os1;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os1, @Passed = 1, @Step = 1001;
EXEC plat.usp_InviteOperator @SessionToken = @os1, @Email = N'op2@test.invalid', @DisplayName = N'Operator 2', @Role = 'OPERATOR_ADMIN', @Token = @lk2, @OperatorId = @op2 OUTPUT;
EXEC plat.usp_CompleteOperatorSetup @Token = @lk2, @NewPasswordHash = @pw2, @MfaSecretEnc = @sec, @MfaKeyRef = 'kms/platform/1', @Step = 2000;
EXEC plat.usp_InviteOperator @SessionToken = @os1, @Email = N'op3@test.invalid', @DisplayName = N'Support 3', @Role = 'OPERATOR_SUPPORT', @Token = @lk3, @OperatorId = @op3 OUTPUT;
EXEC plat.usp_CompleteOperatorSetup @Token = @lk3, @NewPasswordHash = @pw3, @MfaSecretEnc = @sec, @MfaKeyRef = 'kms/platform/1', @Step = 3000;
EXEC plat.usp_StartOperatorSession @Email = N'op2@test.invalid', @PasswordHash = @pw2, @SessionToken = @os2;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os2, @Passed = 1, @Step = 2001;
EXEC plat.usp_StartOperatorSession @Email = N'op3@test.invalid', @PasswordHash = @pw3, @SessionToken = @os3;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os3, @Passed = 1, @Step = 3001;
EXEC plat.usp_StartOperatorSession @Email = N'op3@test.invalid', @PasswordHash = @pw3, @SessionToken = @os3u;   -- no MFA yet
REVERT;

-- Seed: support grants made by the tenant administrator of tenant A (and of S and C)
EXEC #Bind @tA;
INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason)
VALUES (@tA, @op3, @uA, DATEADD(HOUR, -1, @now), DATEADD(HOUR, 3, @now), N'active');
SET @gA = SCOPE_IDENTITY();
INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason)
VALUES (@tA, @op2, @uA, DATEADD(HOUR, -1, @now), DATEADD(HOUR, 3, @now), N'another operator');
SET @gOther = SCOPE_IDENTITY();
INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason, RevokedAt, RevokedBy)
VALUES (@tA, @op3, @uA, DATEADD(HOUR, -1, @now), DATEADD(HOUR, 3, @now), N'revoked', @now, @uA);
SET @gRevoked = SCOPE_IDENTITY();
INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason)
VALUES (@tA, @op3, @uA, DATEADD(HOUR, -5, @now), DATEADD(HOUR, -1, @now), N'expired');
SET @gExpired = SCOPE_IDENTITY();
INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason)
VALUES (@tA, @op3, @uA, DATEADD(HOUR, 1, @now), DATEADD(HOUR, 5, @now), N'future');
SET @gFuture = SCOPE_IDENTITY();
-- The table refuses a grant longer than 72 hours (CK_SupportAccessGrant_2, DR-15); the binding procedure refuses one
-- too, so a row written before that check is not trusted. The check is off for this one row, inside the transaction.
ALTER TABLE plat.SupportAccessGrant NOCHECK CONSTRAINT CK_SupportAccessGrant_2;
INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason)
VALUES (@tA, @op3, @uA, DATEADD(HOUR, -1, @now), DATEADD(HOUR, 80, @now), N'longer than 72 hours');
SET @gLong = SCOPE_IDENTITY();
ALTER TABLE plat.SupportAccessGrant CHECK CONSTRAINT CK_SupportAccessGrant_2;
EXEC #Bind @tS;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@tS, N'ta@s.invalid', N'TS', 'ACTIVE', @pw1);
SELECT @uS = AppUserId FROM sec.AppUser WHERE Email = N'ta@s.invalid';
INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason, CreatedAt)
VALUES (@tS, @op3, @uS, DATEADD(HOUR, -1, @now), DATEADD(HOUR, 3, @now), N'made before the suspension', DATEADD(DAY, -2, @now));
SET @gSBefore = SCOPE_IDENTITY();
INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason)
VALUES (@tS, @op3, @uS, DATEADD(HOUR, -1, @now), DATEADD(HOUR, 3, @now), N'made after the suspension');
SET @gSAfter = SCOPE_IDENTITY();
EXEC #Bind @tC;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@tC, N'ta@c.invalid', N'TC', 'ACTIVE', @pw1);
SELECT @uC = AppUserId FROM sec.AppUser WHERE Email = N'ta@c.invalid';
INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason, CreatedAt)
VALUES (@tC, @op3, @uC, DATEADD(HOUR, -1, @now), DATEADD(HOUR, 3, @now), N'closed tenant', DATEADD(DAY, -6, @now));
SET @gC = SCOPE_IDENTITY();
UPDATE plat.Tenant SET Status = 'SUSPENDED', SuspendedReason = N'Test', SuspendedAt = DATEADD(DAY, -1, @now) WHERE TenantId = @tS;
UPDATE plat.Tenant SET Status = 'CLOSED', ClosedAt = DATEADD(DAY, -5, @now) WHERE TenantId = @tC;
-- sa leaves no binding: the cases below bind only through the procedures
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;

/* P1: the first administrator comes from a one-time bootstrap that issues an invitation; a second bootstrap is
   refused (50023), the panel may not run it (229), and every set-up link works once (50017). */
SAVE TRANSACTION p1;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL;
BEGIN TRY EXEC plat.usp_BootstrapOperator @Email = N'op9@test.invalid', @DisplayName = N'X', @Token = @lk4; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXECUTE AS USER = N'tp_test_panel';
BEGIN TRY EXEC plat.usp_BootstrapOperator @Email = N'op9@test.invalid', @DisplayName = N'X', @Token = @lk4; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC plat.usp_CompleteOperatorSetup @Token = @lk1, @NewPasswordHash = @pw2, @MfaSecretEnc = @sec, @MfaKeyRef = 'k', @Step = 5; END TRY
BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM plat.PlatformOperator
 WHERE PlatformOperatorId IN (@op1, @op2, @op3) AND Status = 'ACTIVE' AND MfaEnabled = 1 AND PasswordHash IS NOT NULL;
SELECT @n2 = COUNT(*) FROM plat.OperatorToken WHERE OperatorId IN (@op1, @op2, @op3) AND UsedAt IS NOT NULL;
SELECT @n3 = COUNT(*) FROM plat.OperatorToken WHERE OperatorId = @op1 AND RequestedBy IS NULL AND Purpose = 'INVITATION';
IF @e1 = 50023 AND @e2 = 229 AND @e3 = 50017 AND @n = 3 AND @n2 = 3 AND @n3 = 1
    PRINT 'PASS P1: the first operator comes from a one-time bootstrap invitation, and set-up links work once';
ELSE PRINT 'FAIL P1: operator bootstrap and set-up (' + CONCAT(@e1, '/', @e2, '/', @e3, '/', @n, '/', @n2, '/', @n3) + ')';
ROLLBACK TRANSACTION p1;

/* P2: an operator session needs a TOTP step after the last accepted one: a replayed step or a missing step does not
   verify it; the next step does. */
SAVE TRANSACTION p2;
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_StartOperatorSession @Email = N'op3@test.invalid', @PasswordHash = @pw3, @SessionToken = @os4;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os4, @Passed = 1, @Step = 3001;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os4, @Passed = 1, @Step = NULL;
REVERT;
SELECT @n = COUNT(*) FROM plat.OperatorSession WHERE TokenHash = HASHBYTES('SHA2_256', @os4) AND MfaVerifiedAt IS NULL;
SELECT @n2 = FailedAttempts FROM plat.PlatformOperator WHERE PlatformOperatorId = @op3;
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os4, @Passed = 1, @Step = 3002;
REVERT;
SELECT @n3 = COUNT(*) FROM plat.OperatorSession
 WHERE TokenHash = HASHBYTES('SHA2_256', @os4) AND MfaVerifiedAt IS NOT NULL
   AND DATEDIFF(MINUTE, LastSeenAt, IdleExpiresAt) = 15 AND DATEDIFF(HOUR, LastSeenAt, AbsoluteExpiresAt) = 8;
IF @n = 1 AND @n2 = 2 AND @n3 = 1 PRINT 'PASS P2: operator MFA refuses replayed steps, and sessions last 15 minutes idle and 8 hours';
ELSE PRINT 'FAIL P2: operator MFA (' + CONCAT(@n, '/', @n2, '/', @n3) + ')';
ROLLBACK TRANSACTION p2;

/* P12: the panel reads the operator's encrypted TOTP secret through its session only (GAP-1), learns whether each
   check was accepted (GAP-4), and each request's touch says who the operator is and whether MFA is done (GAP-7). */
SAVE TRANSACTION p12;
DECLARE @csec VARBINARY(256), @cref VARCHAR(200), @clast BIGINT, @cver DATETIME2(3), @cpub UNIQUEIDENTIFIER,
        @toid INT, @trole VARCHAR(20), @tver1 DATETIME2(3), @tver2 DATETIME2(3), @acc1 BIT, @acc2 BIT;
SELECT @e1 = NULL, @e2 = NULL, @cver = '2000-01-01', @tver1 = '2000-01-01';
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_GetOperatorMfaChallenge @SessionToken = @os3u, @MfaSecretEnc = @csec OUTPUT, @MfaKeyRef = @cref OUTPUT,
     @LastUsedStep = @clast OUTPUT, @MfaVerifiedAt = @cver OUTPUT, @OperatorPublicId = @cpub OUTPUT;
EXEC plat.usp_TouchOperatorSession @SessionToken = @os3u, @OperatorId = @toid OUTPUT, @Role = @trole OUTPUT, @MfaVerifiedAt = @tver1 OUTPUT;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os3u, @Passed = 1, @Step = 3001, @Accepted = @acc1 OUTPUT;
EXEC plat.usp_ConfirmOperatorMfa @SessionToken = @os3u, @Passed = 1, @Step = 3002, @Accepted = @acc2 OUTPUT;
EXEC plat.usp_TouchOperatorSession @SessionToken = @os3u, @MfaVerifiedAt = @tver2 OUTPUT;
BEGIN TRY EXEC plat.usp_GetOperatorMfaChallenge @SessionToken = @lk5; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC plat.usp_TouchOperatorSession @SessionToken = @lk5; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @csec = @sec AND @cref = 'kms/platform/1' AND @clast = 3001 AND @cver IS NULL
   AND @cpub = (SELECT PublicId FROM plat.PlatformOperator WHERE PlatformOperatorId = @op3)
   AND @toid = @op3 AND @trole = 'OPERATOR_SUPPORT' AND @tver1 IS NULL AND @acc1 = 0 AND @acc2 = 1 AND @tver2 IS NOT NULL
   AND @e1 = 50003 AND @e2 = 50003
    PRINT 'PASS P12: the panel reads the operator TOTP secret through the session, the check outcome and the MFA state';
ELSE PRINT 'FAIL P12: operator MFA challenge, outcome or touch (' + CONCAT(@clast, '/', @trole, '/', @acc1, '/', @acc2, '/', @e1, '/', @e2) + ')';
ROLLBACK TRANSACTION p12;

/* P3: five wrong passwords lock an operator, the right password is then refused, and only another operator
   administrator unlocks (50021 for oneself or a non-administrator, 50018 when not locked). */
SAVE TRANSACTION p3;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @e4 = NULL, @i = 0;
EXECUTE AS USER = N'tp_test_panel';
WHILE @i < 5
BEGIN
    BEGIN TRY EXEC plat.usp_StartOperatorSession @Email = N'op3@test.invalid', @PasswordHash = @pwBad, @SessionToken = @os4; END TRY
    BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
    SET @i = @i + 1;
END;
BEGIN TRY EXEC plat.usp_StartOperatorSession @Email = N'op3@test.invalid', @PasswordHash = @pw3, @SessionToken = @os4; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC plat.usp_UnlockOperator @SessionToken = @os1, @OperatorId = @op1; END TRY
BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
EXEC plat.usp_UnlockOperator @SessionToken = @os1, @OperatorId = @op3;
BEGIN TRY EXEC plat.usp_UnlockOperator @SessionToken = @os1, @OperatorId = @op3; END TRY
BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM plat.PlatformOperator WHERE PlatformOperatorId = @op3 AND Status = 'ACTIVE' AND FailedAttempts = 0;
IF @e1 = 50005 AND @e2 = 50005 AND @e3 = 50021 AND @e4 = 50018 AND @n = 1
    PRINT 'PASS P3: five failures lock an operator until another administrator unlocks';
ELSE PRINT 'FAIL P3: operator lockout (' + CONCAT(@e1, '/', @e2, '/', @e3, '/', @e4, '/', @n) + ')';
ROLLBACK TRANSACTION p3;

/* P4: an administrator resets another operator (lost device): password and MFA cleared, sessions ended, and the
   operator sets both again through a 24-hour link; nobody resets themselves (50019). */
SAVE TRANSACTION p4;
SELECT @e1 = NULL, @sent = NULL;
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_ResetOperator @SessionToken = @os1, @OperatorId = @op3, @Token = @lk4, @SentTo = @sent OUTPUT;
SELECT @n = COUNT(*) FROM plat.PlatformOperator WHERE PlatformOperatorId = @op3 AND Status = 'INVITED' AND MfaEnabled = 0;
REVERT;
SELECT @n2 = COUNT(*) FROM plat.OperatorSession WHERE OperatorId = @op3 AND EndReason = 'OPERATOR_RESET';
EXECUTE AS USER = N'tp_test_panel';
BEGIN TRY EXEC plat.usp_ResetOperator @SessionToken = @os1, @OperatorId = @op1, @Token = @lk5; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC plat.usp_CompleteOperatorSetup @Token = @lk4, @NewPasswordHash = @pw3, @MfaSecretEnc = @sec, @MfaKeyRef = 'kms/platform/1', @Step = 4000;
REVERT;
SELECT @n3 = COUNT(*) FROM plat.PlatformOperator WHERE PlatformOperatorId = @op3 AND Status = 'ACTIVE' AND MfaLastUsedStep = 4000;
IF @sent = N'op3@test.invalid' AND @n = 1 AND @n2 = 2 AND @e1 = 50019 AND @n3 = 1
    PRINT 'PASS P4: an administrator reset ends the sessions and the operator sets up again through a link';
ELSE PRINT 'FAIL P4: operator reset (' + CONCAT(@n, '/', @n2, '/', @e1, '/', @n3) + ')';
ROLLBACK TRANSACTION p4;

/* P5: status changes: disabling an operator ends its sessions; at least two active administrators remain (50019);
   a disabled operator can be re-activated. */
SAVE TRANSACTION p5;
SELECT @e1 = NULL, @e2 = NULL;
EXECUTE AS USER = N'tp_test_panel';
BEGIN TRY EXEC plat.usp_SetOperatorStatus @SessionToken = @os1, @OperatorId = @op2, @Status = 'DISABLED'; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC plat.usp_SetOperatorStatus @SessionToken = @os1, @OperatorId = @op1, @Status = 'DISABLED'; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
EXEC plat.usp_SetOperatorStatus @SessionToken = @os1, @OperatorId = @op3, @Status = 'DISABLED';
REVERT;
SELECT @n = COUNT(*) FROM plat.OperatorSession WHERE OperatorId = @op3 AND EndReason = 'OPERATOR_DISABLED';
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_SetOperatorStatus @SessionToken = @os1, @OperatorId = @op3, @Status = 'ACTIVE';
REVERT;
SELECT @n2 = COUNT(*) FROM plat.PlatformOperator WHERE PlatformOperatorId IN (@op2, @op3) AND Status = 'ACTIVE';
IF @e1 = 50019 AND @e2 = 50019 AND @n = 2 AND @n2 = 2 PRINT 'PASS P5: operator status changes keep two active administrators and end sessions';
ELSE PRINT 'FAIL P5: operator status (' + CONCAT(@e1, '/', @e2, '/', @n, '/', @n2) + ')';
ROLLBACK TRANSACTION p5;

/* P6: the operator panel cannot create an operator or set a status or password directly, cannot read the hash or
   the TOTP secret, and neither it nor the reporting role reads operator sessions or links. */
SAVE TRANSACTION p6;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @e4 = NULL, @e5 = NULL, @e6 = NULL, @e7 = NULL;
EXECUTE AS USER = N'tp_test_panel';
BEGIN TRY INSERT plat.PlatformOperator (Email, Role, Status) VALUES (N'op8@test.invalid', 'OPERATOR_ADMIN', 'INVITED'); END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE plat.PlatformOperator SET Status = 'ACTIVE' WHERE PlatformOperatorId = @op3; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE plat.PlatformOperator SET PasswordHash = @pw1 WHERE PlatformOperatorId = @op3; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY SELECT @x = DATALENGTH(MfaSecretEnc) FROM plat.PlatformOperator WHERE PlatformOperatorId = @op3; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
BEGIN TRY SELECT @x = COUNT(*) FROM plat.OperatorSession; END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH;
BEGIN TRY SELECT @x = COUNT(*) FROM plat.OperatorToken; END TRY BEGIN CATCH SET @e6 = ERROR_NUMBER(); END CATCH;
REVERT;
EXECUTE AS USER = N'tp_test_ro';
BEGIN TRY SELECT @x = COUNT(OperatorSessionId) FROM plat.OperatorSession; END TRY BEGIN CATCH SET @e7 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @e1 = 229 AND @e2 = 230 AND @e3 = 230 AND @e4 = 230 AND @e5 = 229 AND @e6 = 229 AND @e7 = 229
    PRINT 'PASS P6: the operator panel changes operators only through the procedures';
ELSE PRINT 'FAIL P6: direct operator rights (' + CONCAT(@e1, '/', @e2, '/', @e3, '/', @e4, '/', @e5, '/', @e6, '/', @e7) + ')';
ROLLBACK TRANSACTION p6;

/* P7: the support binding is refused without everything it needs: the right role, an operator session with MFA,
   and a grant of this tenant to this operator that has started, has not ended, is not revoked and is at most
   72 hours long. */
SAVE TRANSACTION p7;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @e4 = NULL, @e5 = NULL, @e6 = NULL, @e7 = NULL, @n = 0;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSupportContext @TenantId = @tA, @SupportAccessGrantId = @gA, @OperatorSessionToken = @os3; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
EXECUTE AS USER = N'tp_test_sup';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @tA, @SessionToken = @os3; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSupportContext @TenantId = @tA, @SupportAccessGrantId = @gA, @OperatorSessionToken = @os3u; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSupportContext @TenantId = @tA, @SupportAccessGrantId = @gOther, @OperatorSessionToken = @os3; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSupportContext @TenantId = @tB, @SupportAccessGrantId = @gA, @OperatorSessionToken = @os3; END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH;
SET @i = 0;
WHILE @i < 4
BEGIN
    SELECT @e6 = NULL, @g = CASE @i WHEN 0 THEN @gRevoked WHEN 1 THEN @gExpired WHEN 2 THEN @gFuture ELSE @gLong END;
    BEGIN TRY EXEC sec.usp_SetSupportContext @TenantId = @tA, @SupportAccessGrantId = @g, @OperatorSessionToken = @os3; END TRY
    BEGIN CATCH SET @e6 = ERROR_NUMBER(); END CATCH;
    IF @e6 = 50022 SET @n = @n + 1;
    SET @i = @i + 1;
END;
REVERT;
SELECT @n2 = COUNT(*) FROM sec.SessionBinding WHERE SessionId = @@SPID;
IF @e1 = 229 AND @e2 = 229 AND @e3 = 50003 AND @e4 = 50022 AND @e5 = 50022 AND @n = 4 AND @n2 = 0
    PRINT 'PASS P7: the support binding needs the support role, an operator session with MFA and a valid grant';
ELSE PRINT 'FAIL P7: support binding refusals (' + CONCAT(@e1, '/', @e2, '/', @e3, '/', @e4, '/', @e5, '/', @n, '/', @n2) + ')';
ROLLBACK TRANSACTION p7;

/* P8: tenant status (DOC-F04 7.4): support reads an active tenant, and a suspended one only with a grant made before
   the suspension; never a closed one. The context is preset, so a call that passes every check stops at 50004. */
SAVE TRANSACTION p8;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @e4 = NULL;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = -1;
EXECUTE AS USER = N'tp_test_sup';
BEGIN TRY EXEC sec.usp_SetSupportContext @TenantId = @tA, @SupportAccessGrantId = @gA, @OperatorSessionToken = @os3; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSupportContext @TenantId = @tS, @SupportAccessGrantId = @gSBefore, @OperatorSessionToken = @os3; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSupportContext @TenantId = @tS, @SupportAccessGrantId = @gSAfter, @OperatorSessionToken = @os3; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSupportContext @TenantId = @tC, @SupportAccessGrantId = @gC, @OperatorSessionToken = @os3; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
IF @e1 = 50004 AND @e2 = 50004 AND @e3 = 50002 AND @e4 = 50002
    PRINT 'PASS P8: support follows the tenant status: active, or suspended with a grant made before the suspension';
ELSE PRINT 'FAIL P8: support and tenant status (' + CONCAT(@e1, '/', @e2, '/', @e3, '/', @e4) + ')';
ROLLBACK TRANSACTION p8;

/* P9: support bindings end at once when the grant is revoked, the operator session ends, or the operator is no
   longer active; a user binding of the same tenant stays. Binding rows of other connections stand in for them. */
SAVE TRANSACTION p9;
SELECT @n = NULL, @n2 = NULL, @n3 = NULL;
INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind, BoundOperatorId)
VALUES (-11, @tA, 0, NEWID(), 'SUPPORT', @op3), (-12, @tA, @uA, NEWID(), 'USER', NULL);
EXEC #Bind @tA;
UPDATE plat.SupportAccessGrant SET RevokedAt = SYSUTCDATETIME(), RevokedBy = @uA WHERE SupportAccessGrantId = @gA;
SELECT @n = COUNT(*) FROM sec.SessionBinding WHERE SessionId IN (-11, -12);
INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind, BoundOperatorId)
VALUES (-13, @tB, 0, NEWID(), 'SUPPORT', @op3);
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_EndOperatorSession @SessionToken = @os3;
REVERT;
SELECT @n2 = COUNT(*) FROM sec.SessionBinding WHERE SessionId = -13;
INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind, BoundOperatorId)
VALUES (-14, @tB, 0, NEWID(), 'SUPPORT', @op3);
EXECUTE AS USER = N'tp_test_panel';
EXEC plat.usp_SetOperatorStatus @SessionToken = @os1, @OperatorId = @op3, @Status = 'DISABLED';
REVERT;
SELECT @n3 = COUNT(*) FROM sec.SessionBinding WHERE SessionId = -14;
IF @n = 1 AND @n2 = 0 AND @n3 = 0 PRINT 'PASS P9: support bindings end with the grant, the operator session or the operator';
ELSE PRINT 'FAIL P9: support binding revocation (' + CONCAT(@n, '/', @n2, '/', @n3) + ')';
ROLLBACK TRANSACTION p9;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;

/* P10: the real support binding (last, because it makes the context read-only): the support connection reads the
   granted tenant only, never a restricted column, writes nothing, and loses the rows when the grant is revoked. */
SAVE TRANSACTION p10;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @n = NULL, @n2 = NULL, @n3 = NULL, @x = NULL;
EXECUTE AS USER = N'tp_test_sup';
BEGIN TRY
    EXEC sec.usp_SetSupportContext @TenantId = @tA, @SupportAccessGrantId = @gA, @OperatorSessionToken = @os3;
    SELECT @n = COUNT(AppUserId) FROM sec.AppUser;                              -- the granted tenant's users
    SELECT @n2 = COUNT(AppUserId) FROM sec.AppUser WHERE TenantId <> @tA;       -- nobody else's
    SET @x = CAST(SESSION_CONTEXT(N'OperatorId') AS INT);
END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY SELECT TOP (1) @e3 = DATALENGTH(PasswordHash) FROM sec.AppUser; SET @e3 = NULL; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@tA, 'security.session.idle_minutes', N'10'); END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
UPDATE plat.SupportAccessGrant SET RevokedAt = SYSUTCDATETIME(), RevokedBy = @uA WHERE SupportAccessGrantId = @gA;
EXECUTE AS USER = N'tp_test_sup';
SELECT @n3 = COUNT(AppUserId) FROM sec.AppUser;
REVERT;
IF @e1 IS NULL AND @n = 1 AND @n2 = 0 AND @x = @op3 AND @e3 = 230 AND @e2 = 229 AND @n3 = 0
    PRINT 'PASS P10: a support binding reads the granted tenant only, without restricted columns or writes, until revoked';
ELSE PRINT 'FAIL P10: support binding (' + CONCAT(@e1, '/', @n, '/', @n2, '/', @x, '/', @e3, '/', @e2, '/', @n3) + ')';
/* P11: the binding wrote a high-severity row into the tenant's own audit log, naming the operator and the grant, so
   the tenant sees who entered its data (BR-PLT-009, ADR 0007). */
DECLARE @auditRows INT;
EXECUTE AS USER = N'tp_test_oread';
SELECT @auditRows = COUNT(*) FROM aud.AuditLog
 WHERE TenantId = @tA AND Action = 'SUPPORT_ACCESS_BOUND' AND Category = 'SECURITY' AND Severity = 'HIGH' AND ActorType = 'OPERATOR'
   AND ActorId = (SELECT PublicId FROM plat.PlatformOperator WHERE PlatformOperatorId = @op3)
   AND EntityType = 'plat.SupportAccessGrant' AND EntityId = @gA;
REVERT;
IF @auditRows = 1 PRINT 'PASS P11: a support binding is audited in the tenant''s log with high severity, naming the operator and the grant';
ELSE PRINT CONCAT('FAIL P11: support binding audit rows ', @auditRows);
ROLLBACK TRANSACTION p10;

ROLLBACK TRANSACTION;
GO
PRINT 'Operator and support tests finished; every change is rolled back.';
GO

/* ============================================================================
   Tenant-isolation tests (O-09, O-16): row-level security, the connection binding, the context procedure and
   the grants, exercised as the application role (tp_app) and the reporting role (tp_readonly). The cases run as
   those roles through EXECUTE AS. sa only seeds the data and binds the test connection (#Bind), because the
   tests need a bound connection for each tenant they check.

   Run against a deployed BankFas database that holds no real data, with a sysadmin login (CI uses sa):
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/tenant_isolation_tests.sql

   The whole run is one transaction, rolled back at the end, so the test principals, the seed rows, the
   temporary procedure and the constraint changes leave nothing behind. Each case has its own savepoint.
   Identifiers are captured once while seeding, because the row filters depend on the bound tenant.

   Each case prints one line that starts with PASS or FAIL. INFO lines describe what a case did and are not counted.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
BEGIN TRANSACTION;

-- Test principals: no login, one role each
CREATE USER [tp_test_app]  WITHOUT LOGIN;
CREATE USER [tp_test_ro]   WITHOUT LOGIN;
CREATE USER [tp_test_plat] WITHOUT LOGIN;
ALTER ROLE [tp_app]      ADD MEMBER [tp_test_app];
ALTER ROLE [tp_readonly] ADD MEMBER [tp_test_ro];
ALTER ROLE [tp_platform] ADD MEMBER [tp_test_plat];

-- Foreign keys to reference data that is not seeded, and the checks on the seeded rows, are switched off here.
-- The rollback at the end restores them.
ALTER TABLE plat.Tenant       NOCHECK CONSTRAINT ALL;
ALTER TABLE sec.AppUser       NOCHECK CONSTRAINT ALL;
ALTER TABLE fac.Facility      NOCHECK CONSTRAINT ALL;
ALTER TABLE cfg.NonWorkingDay NOCHECK CONSTRAINT ALL;
GO

-- #Bind: binds the test connection to one tenant the same way the context procedure does (a binding row for
-- @@SPID with a new token, and the context). The procedure is session-scoped and dropped by the rollback.
CREATE PROCEDURE #Bind @TenantId INT, @UserId BIGINT = 0
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    MERGE sec.SessionBinding AS b
    USING (SELECT @@SPID AS SessionId) AS s
       ON b.SessionId = s.SessionId
    WHEN MATCHED THEN
        UPDATE SET BoundTenantId = @TenantId, BoundUserId = @UserId, BindingToken = @token, BoundAt = SYSUTCDATETIME(),
                   BindingKind = 'USER', BoundOperatorId = NULL
    WHEN NOT MATCHED THEN
        INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (s.SessionId, @TenantId, @UserId, @token);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
END;
GO

DECLARE @t1 INT, @t2 INT, @t3 INT;
DECLARE @u1 BIGINT, @u1x BIGINT, @u2 BIGINT, @u1b BIGINT, @usys BIGINT, @rTA BIGINT;
DECLARE @f1 BIGINT, @f2 BIGINT;
DECLARE @err INT, @err2 INT, @n INT, @n2 INT, @rows INT, @ctx INT;
DECLARE @amt DECIMAL(19,4);
DECLARE @unfiltered INT, @disabled INT, @allowed INT, @tm INT;
DECLARE @other UNIQUEIDENTIFIER;
-- Session tokens held by the "application" in these tests, and a well-formed Argon2id PHC string for user 1
DECLARE @tok1 VARBINARY(64) = CRYPT_GEN_RANDOM(32), @tok1x VARBINARY(64) = CRYPT_GEN_RANDOM(32), @tok2 VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @tokIdle VARBINARY(64) = CRYPT_GEN_RANDOM(32), @tokEnded VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @tokBad VARBINARY(64) = CRYPT_GEN_RANDOM(32), @tokNew VARBINARY(64) = CRYPT_GEN_RANDOM(32),
        @tok1b VARBINARY(64) = CRYPT_GEN_RANDOM(32), @tokNoMfa VARBINARY(64) = CRYPT_GEN_RANDOM(32);
DECLARE @phc VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g';
DECLARE @params VARCHAR(255), @params2 VARCHAR(255), @outUser BIGINT, @mfaReq BIT, @err3 INT, @i INT, @uctx BIGINT;

-- Seed: three tenants (two open, one closed)
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone, ClosedAt)
VALUES (N'TST-A', N'Test A', N'Test A', 1, 1, 'ACTIVE', 'Asia/Riyadh', NULL),
       (N'TST-B', N'Test B', N'Test B', 1, 1, 'ACTIVE', 'Asia/Riyadh', NULL),
       (N'TST-C', N'Test C', N'Test C', 1, 1, 'CLOSED', 'Asia/Riyadh', DATEADD(DAY, -40, SYSUTCDATETIME()));   -- past the 30-day export window
SELECT @t1 = TenantId FROM plat.Tenant WHERE Code = N'TST-A';
SELECT @t2 = TenantId FROM plat.Tenant WHERE Code = N'TST-B';
SELECT @t3 = TenantId FROM plat.Tenant WHERE Code = N'TST-C';

-- Seed: tenant 1 (two users, a facility, a non-working day)
EXEC #Bind @t1;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t1, N'u1@test.invalid', N'User 1', 'ACTIVE', @phc);
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t1, N'u1x@test.invalid', N'User 1 disabled', 'DISABLED', 'TEST');
SELECT @u1 = AppUserId FROM sec.AppUser WHERE Email = N'u1@test.invalid';
SELECT @u1x = AppUserId FROM sec.AppUser WHERE Email = N'u1x@test.invalid';
-- A second active user without the TA role, and a service account (O-18, ADR 0003)
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t1, N'u1b@test.invalid', N'User 1b', 'ACTIVE', @phc);
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, IsSystemUser) VALUES (@t1, N'svc@test.invalid', N'Service', 'ACTIVE', 1);
SELECT @u1b = AppUserId FROM sec.AppUser WHERE Email = N'u1b@test.invalid';
SELECT @usys = AppUserId FROM sec.AppUser WHERE Email = N'svc@test.invalid';
-- User 1 is the tenant administrator (system role TA)
INSERT sec.Role (TenantId, Code, NameAr, NameEn, IsSystem, SeedKey) VALUES (@t1, 'TA', N'مدير الحساب', N'Tenant administrator', 1, 'ROLE.TA');
SELECT @rTA = RoleId FROM sec.Role WHERE TenantId = @t1 AND Code = 'TA';
INSERT sec.UserRole (TenantId, UserId, RoleId) VALUES (@t1, @u1, @rTA);
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (@t1, N'TST-F1', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f1 = SCOPE_IDENTITY();
INSERT cfg.NonWorkingDay (TenantId, CountryId, OnDate, NameEn) VALUES (@t1, 1, '2026-12-26', N'TEST-T1');
-- Sessions of tenant 1: user 1 (valid), the disabled user, an idle-expired one and an ended one
-- Sessions with MFA recorded are marked MfaVerifiedAt (MFA is mandatory, ADR 0003); @tokNoMfa has none.
INSERT sec.UserSession (TenantId, UserId, TokenHash, IdleExpiresAt, AbsoluteExpiresAt, EndedAt, EndReason, MfaVerifiedAt)
VALUES (@t1, @u1,  HASHBYTES('SHA2_256', @tok1),     DATEADD(MINUTE, 30, SYSUTCDATETIME()), DATEADD(HOUR, 12, SYSUTCDATETIME()), NULL, NULL, SYSUTCDATETIME()),
       (@t1, @u1x, HASHBYTES('SHA2_256', @tok1x),    DATEADD(MINUTE, 30, SYSUTCDATETIME()), DATEADD(HOUR, 12, SYSUTCDATETIME()), NULL, NULL, SYSUTCDATETIME()),
       (@t1, @u1b, HASHBYTES('SHA2_256', @tok1b),    DATEADD(MINUTE, 30, SYSUTCDATETIME()), DATEADD(HOUR, 12, SYSUTCDATETIME()), NULL, NULL, SYSUTCDATETIME()),
       (@t1, @u1,  HASHBYTES('SHA2_256', @tokNoMfa), DATEADD(MINUTE, 30, SYSUTCDATETIME()), DATEADD(HOUR, 12, SYSUTCDATETIME()), NULL, NULL, NULL);
INSERT sec.UserSession (TenantId, UserId, TokenHash, IdleExpiresAt, AbsoluteExpiresAt, EndedAt, EndReason)
VALUES
       (@t1, @u1,  HASHBYTES('SHA2_256', @tokIdle),  DATEADD(MINUTE, -1, SYSUTCDATETIME()), DATEADD(HOUR, 11, SYSUTCDATETIME()), NULL, NULL),
       (@t1, @u1,  HASHBYTES('SHA2_256', @tokEnded), DATEADD(MINUTE, 30, SYSUTCDATETIME()), DATEADD(HOUR, 12, SYSUTCDATETIME()), SYSUTCDATETIME(), 'LOGOUT');

-- Seed: tenant 2 (a user, a facility, a non-working day)
EXEC #Bind @t2;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t2, N'u2@test.invalid', N'User 2', 'ACTIVE', 'TEST');
SELECT @u2 = AppUserId FROM sec.AppUser WHERE Email = N'u2@test.invalid';
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (@t2, N'TST-F2', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f2 = SCOPE_IDENTITY();
INSERT cfg.NonWorkingDay (TenantId, CountryId, OnDate, NameEn) VALUES (@t2, 1, '2026-12-27', N'TEST-T2');
INSERT plat.TenantModule (TenantId, ModuleCode, IsEnabled) VALUES (@t2, 'CORE', 1);
INSERT sec.UserSession (TenantId, UserId, TokenHash, IdleExpiresAt, AbsoluteExpiresAt, MfaVerifiedAt)
VALUES (@t2, @u2, HASHBYTES('SHA2_256', @tok2), DATEADD(MINUTE, 30, SYSUTCDATETIME()), DATEADD(HOUR, 12, SYSUTCDATETIME()), SYSUTCDATETIME());

-- Seed: one global row (TenantId NULL), written by a platform operator
EXECUTE AS USER = N'tp_test_plat';
INSERT cfg.NonWorkingDay (TenantId, CountryId, OnDate, NameEn) VALUES (NULL, 1, '2026-12-25', N'TEST-GLOBAL');
REVERT;

/* ---------- Cases 1-3: reading without a binding and across tenants ---------- */

/* T1: without a tenant context and binding, the application role sees no facility rows. */
SAVE TRANSACTION sp_t01;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
SET @err = NULL; SET @n = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n = COUNT(*) FROM fac.Facility; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 0 PRINT 'PASS T1: without a tenant context the application role sees no facility rows';
ELSE PRINT 'FAIL T1: without a tenant context the application role saw rows or an error';
ROLLBACK TRANSACTION sp_t01;

/* T2: a tenant sees its own facility and no other. */
SAVE TRANSACTION sp_t02;
EXEC #Bind @t1;
SET @err = NULL; SET @n = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityNo LIKE N'TST-F%'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 1 PRINT 'PASS T2: a tenant sees its own facility and no other';
ELSE PRINT 'FAIL T2: a tenant did not see exactly its own facility';
ROLLBACK TRANSACTION sp_t02;

/* T3: a facility of another tenant cannot be read by key (no IDOR). */
SAVE TRANSACTION sp_t03;
EXEC #Bind @t1;
SET @err = NULL; SET @n = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId = @f2; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 0 PRINT 'PASS T3: a facility of another tenant is not returned when requested by key';
ELSE PRINT 'FAIL T3: a facility of another tenant was returned';
ROLLBACK TRANSACTION sp_t03;

/* ---------- Cases 4-8: writing across tenants ---------- */

/* T4: inserting a row for another tenant is refused (block predicate, 33504). */
SAVE TRANSACTION sp_t04;
EXEC #Bind @t1;
SET @err = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
    VALUES (@t2, N'TST-X4', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 33504 PRINT 'PASS T4: inserting a row for another tenant is refused';
ELSE PRINT 'FAIL T4: inserting a row for another tenant was not refused with 33504';
ROLLBACK TRANSACTION sp_t04;

/* T5: inserting a row for the own tenant is accepted (positive control for T4). */
SAVE TRANSACTION sp_t05;
EXEC #Bind @t1;
SET @err = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
    VALUES (@t1, N'TST-X5', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL PRINT 'PASS T5: inserting a row for the own tenant is accepted';
ELSE PRINT 'FAIL T5: inserting a row for the own tenant raised error ' + CAST(@err AS VARCHAR(10));
ROLLBACK TRANSACTION sp_t05;

/* T6: updating a facility of another tenant changes no row, and the row keeps its value. */
SAVE TRANSACTION sp_t06;
EXEC #Bind @t1;
SET @err = NULL; SET @rows = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    UPDATE fac.Facility SET TotalAmount = 1 WHERE FacilityId = @f2;
    SET @rows = @@ROWCOUNT;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #Bind @t2;
SELECT @amt = TotalAmount FROM fac.Facility WHERE FacilityId = @f2;
IF @err IS NULL AND @rows = 0 AND @amt = 1000 PRINT 'PASS T6: updating a facility of another tenant changes no row';
ELSE PRINT 'FAIL T6: an update of another tenant''s facility reached the row';
ROLLBACK TRANSACTION sp_t06;

/* T7: moving an own row to another tenant is refused (33504). */
SAVE TRANSACTION sp_t07;
EXEC #Bind @t1;
SET @err = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY UPDATE fac.Facility SET TenantId = @t2 WHERE FacilityId = @f1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 33504 PRINT 'PASS T7: moving an own row to another tenant is refused';
ELSE PRINT 'FAIL T7: moving an own row to another tenant was not refused with 33504';
ROLLBACK TRANSACTION sp_t07;

/* T8: deleting a facility of another tenant removes nothing (refused, or no row matched). */
SAVE TRANSACTION sp_t08;
EXEC #Bind @t1;
SET @err = NULL; SET @rows = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    DELETE FROM fac.Facility WHERE FacilityId = @f2;
    SET @rows = @@ROWCOUNT;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #Bind @t2;
SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId = @f2;
IF @n = 1 AND (@err IS NOT NULL OR @rows = 0) PRINT 'PASS T8: deleting a facility of another tenant removes nothing';
ELSE PRINT 'FAIL T8: a facility of another tenant was deleted';
ROLLBACK TRANSACTION sp_t08;

/* T8b: a tenant cannot delete another tenant's non-working day. The application role holds DELETE on this table,
   so only the row filter can stop the delete: the row is hidden, nothing is deleted, and no error is raised. */
SAVE TRANSACTION sp_t08b;
EXEC #Bind @t1;
SET @err = NULL; SET @rows = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    DELETE FROM cfg.NonWorkingDay WHERE NameEn = N'TEST-T2';
    SET @rows = @@ROWCOUNT;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #Bind @t2;
SELECT @n = COUNT(*) FROM cfg.NonWorkingDay WHERE NameEn = N'TEST-T2';
IF @err IS NULL AND @rows = 0 AND @n = 1 PRINT 'PASS T8b: a tenant cannot delete another tenant''s non-working day';
ELSE PRINT 'FAIL T8b: a non-working day of another tenant was deleted or the delete was refused';
ROLLBACK TRANSACTION sp_t08b;

/* ---------- Cases 9-12: global rows (TenantId NULL) in a mixed-scope table ---------- */

/* T9: a tenant reads the global row and not another tenant's row. */
SAVE TRANSACTION sp_t09;
EXEC #Bind @t1;
SET @err = NULL; SET @n = NULL; SET @n2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    SELECT @n = COUNT(*) FROM cfg.NonWorkingDay WHERE NameEn = N'TEST-GLOBAL';
    SELECT @n2 = COUNT(*) FROM cfg.NonWorkingDay WHERE NameEn = N'TEST-T2';
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 1 AND @n2 = 0 PRINT 'PASS T9: a tenant reads the global row and not another tenant''s row';
ELSE PRINT 'FAIL T9: global read or cross-tenant read of cfg.NonWorkingDay is wrong';
ROLLBACK TRANSACTION sp_t09;

/* T10: a tenant cannot insert a global row (33504). */
SAVE TRANSACTION sp_t10;
EXEC #Bind @t1;
SET @err = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY INSERT cfg.NonWorkingDay (TenantId, CountryId, OnDate, NameEn) VALUES (NULL, 1, '2026-12-28', N'TEST-X10'); END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 33504 PRINT 'PASS T10: a tenant cannot insert a global row';
ELSE PRINT 'FAIL T10: inserting a global row was not refused with 33504';
ROLLBACK TRANSACTION sp_t10;

/* T11: a tenant cannot change a global row (33504). */
SAVE TRANSACTION sp_t11;
EXEC #Bind @t1;
SET @err = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY UPDATE cfg.NonWorkingDay SET NameEn = N'CHANGED' WHERE NameEn = N'TEST-GLOBAL'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 33504 PRINT 'PASS T11: a tenant cannot change a global row';
ELSE PRINT 'FAIL T11: changing a global row was not refused with 33504';
ROLLBACK TRANSACTION sp_t11;

/* T12: a tenant cannot delete a global row (33504 or 229), and the row is still there afterwards. */
SAVE TRANSACTION sp_t12;
EXEC #Bind @t1;
SET @err = NULL; SET @n = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY DELETE FROM cfg.NonWorkingDay WHERE NameEn = N'TEST-GLOBAL'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM cfg.NonWorkingDay WHERE NameEn = N'TEST-GLOBAL';
IF (@err = 33504 OR @err = 229) AND @n = 1 PRINT 'PASS T12: a tenant cannot delete a global row';
ELSE PRINT 'FAIL T12: deleting a global row was not refused or the row is gone';
ROLLBACK TRANSACTION sp_t12;

/* ---------- Cases 13-15: the audit log is append-only and tenant-scoped ---------- */

/* T13: a tenant can append an audit row for itself. */
SAVE TRANSACTION sp_t13;
EXEC #Bind @t1;
SET @err = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, Action) VALUES (@t1, SYSUTCDATETIME(), 'USER', 'TEST_T13'); END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL PRINT 'PASS T13: a tenant can append an audit row for itself';
ELSE PRINT 'FAIL T13: appending an own audit row raised error ' + CAST(@err AS VARCHAR(10));
ROLLBACK TRANSACTION sp_t13;

/* T14: a tenant cannot append an audit row for another tenant (33504). */
SAVE TRANSACTION sp_t14;
EXEC #Bind @t1;
SET @err = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, Action) VALUES (@t2, SYSUTCDATETIME(), 'USER', 'TEST_T14'); END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 33504 PRINT 'PASS T14: a tenant cannot append an audit row for another tenant';
ELSE PRINT 'FAIL T14: appending an audit row for another tenant was not refused with 33504';
ROLLBACK TRANSACTION sp_t14;

/* T15: the application role cannot update or delete audit rows (229, no permission). */
SAVE TRANSACTION sp_t15;
EXEC #Bind @t1;
SET @err = NULL; SET @err2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY UPDATE aud.AuditLog SET Action = N'TEST_CHANGED' WHERE TenantId = @t1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY DELETE FROM aud.AuditLog WHERE TenantId = @t1; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 229 AND @err2 = 229 PRINT 'PASS T15: the application role cannot update or delete audit rows';
ELSE PRINT 'FAIL T15: update or delete of audit rows was not refused with 229';
ROLLBACK TRANSACTION sp_t15;

/* T38: the platform role reads platform audit events (TenantId NULL) and no tenant's audit rows (C-4, BR-PLT-009). */
SAVE TRANSACTION sp_t38;
EXEC #Bind @t1;
INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, Action) VALUES (@t1, SYSUTCDATETIME(), 'USER', 'TEST_T38');
EXECUTE AS USER = N'tp_test_plat';                                 -- only the platform writes platform events (O-19)
INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, Action) VALUES (NULL, SYSUTCDATETIME(), 'OPERATOR', 'TEST_T38');
REVERT;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;           -- unbound, so only the role decides what is visible
SET @err = NULL; SET @n = NULL; SET @n2 = NULL;
EXECUTE AS USER = N'tp_test_plat';
BEGIN TRY
    SELECT @n = COUNT(*) FROM aud.AuditLog WHERE Action = 'TEST_T38' AND TenantId = @t1;
    SELECT @n2 = COUNT(*) FROM aud.AuditLog WHERE Action = 'TEST_T38' AND TenantId IS NULL;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 0 AND @n2 = 1 PRINT 'PASS T38: the platform role reads platform audit events and no tenant audit rows';
ELSE PRINT 'FAIL T38: the platform role read a tenant audit row or missed a platform event';
ROLLBACK TRANSACTION sp_t38;

/* ---------- Cases 16-16c: the binding (O-16) ---------- */

/* T16: the application role sets TenantId itself and then reads a tenant-2 facility. The connection stays bound to
   tenant 1 (sec.SessionBinding), so the filter hides the tenant-2 row whatever the context says. */
SAVE TRANSACTION sp_t16;
EXEC #Bind @t1;
SET @err = NULL; SET @err2 = NULL; SET @n = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @t2;
    SET @err2 = 0;
END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId = @f2; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
PRINT 'INFO T16: direct change of TenantId by the application role returned ' + CAST(ISNULL(@err2, -1) AS VARCHAR(10)) + ' (0 = accepted)';
IF @err IS NULL AND @n = 0 PRINT 'PASS T16: a direct change of TenantId does not expose another tenant''s row';
ELSE PRINT 'FAIL T16: a direct change of TenantId exposed another tenant''s row';
ROLLBACK TRANSACTION sp_t16;

/* T16b: the application role can neither read nor write the binding table (229). */
SAVE TRANSACTION sp_t16b;
SET @err = NULL; SET @err2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n = COUNT(*) FROM sec.SessionBinding; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (999999, @t1, 0, NEWID()); END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 229 AND @err2 = 229 PRINT 'PASS T16b: the application role can neither read nor write the binding table';
ELSE PRINT 'FAIL T16b: reading or writing the binding table was not refused with 229';
ROLLBACK TRANSACTION sp_t16b;

/* T16c: a token that is not the connection's own, or no token at all, shows no row of the bound tenant. */
SAVE TRANSACTION sp_t16c;
EXEC #Bind @t1;
SET @other = NEWID();
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @other;
SET @err = NULL; SET @n = NULL; SET @n2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId = @f1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n2 = COUNT(*) FROM fac.Facility WHERE FacilityId = @f1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 0 AND @n2 = 0 PRINT 'PASS T16c: a wrong token or no token shows no row of the bound tenant';
ELSE PRINT 'FAIL T16c: a wrong or missing token exposed a row of the bound tenant';
ROLLBACK TRANSACTION sp_t16c;

/* T28: an unbound connection that sets TenantId itself reads no tenant row and no module row through the views (O-16). */
SAVE TRANSACTION sp_t28;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = @t2;     -- forged: this connection has no binding
SET @err = NULL; SET @n = NULL; SET @n2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    SELECT @n = COUNT(*) FROM plat.v_CurrentTenant;
    SELECT @n2 = COUNT(*) FROM plat.v_TenantModule;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 0 AND @n2 = 0 PRINT 'PASS T28: an unbound connection reads no tenant or module row through the views';
ELSE PRINT 'FAIL T28: an unbound connection read a tenant or module row through the views';
ROLLBACK TRANSACTION sp_t28;

/* ---------- Cases 17-20 and 32-36: login, sessions and the context procedure (O-01, O-17) ---------- */

/* T17: the procedure refuses an unknown tenant and a tenant closed for more than 30 days (50002, O-18). */
SAVE TRANSACTION sp_t17;
SET @err = NULL; SET @err2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = 999999, @SessionToken = @tok1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t3, @SessionToken = @tok1; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 50002 AND @err2 = 50002 PRINT 'PASS T17: the context procedure refuses an unknown and a closed tenant';
ELSE PRINT 'FAIL T17: unknown or closed tenant was not refused with 50002';
ROLLBACK TRANSACTION sp_t17;

/* T18: a session of tenant 1 does not bind tenant 2, and the session of a disabled user binds nothing (50003, O-17). */
SAVE TRANSACTION sp_t18;
SET @err = NULL; SET @err2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t2, @SessionToken = @tok1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tok1x; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 50003 AND @err2 = 50003 PRINT 'PASS T18: a session binds only its own tenant, and a disabled user''s session binds nothing';
ELSE PRINT 'FAIL T18: a session bound another tenant, or a disabled user''s session was accepted';
ROLLBACK TRANSACTION sp_t18;

/* T32: a wrong token, an idle-expired session and an ended session bind nothing (50003). */
SAVE TRANSACTION sp_t32;
SET @err = NULL; SET @err2 = NULL; SET @err3 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tokBad; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tokIdle; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tokEnded; END TRY
BEGIN CATCH SET @err3 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 50003 AND @err2 = 50003 AND @err3 = 50003 PRINT 'PASS T32: a wrong token, an idle-expired session and an ended session bind nothing';
ELSE PRINT 'FAIL T32: a wrong, expired or ended session was accepted';
ROLLBACK TRANSACTION sp_t32;

/* T33: login. The parameters come back without the hash; a wrong hash is refused with the one message (50005) and
   logged; the right hash creates a session for the token, logs the success and resets the failure counter. */
SAVE TRANSACTION sp_t33;
EXEC #Bind @t1;
SET @err = NULL; SET @err2 = NULL; SET @params = NULL; SET @params2 = 'not null'; SET @outUser = NULL; SET @mfaReq = NULL;
EXECUTE AS USER = N'tp_test_app';
EXEC sec.usp_GetPasswordParams @TenantId = @t1, @Email = N'u1@test.invalid', @Params = @params OUTPUT;
EXEC sec.usp_GetPasswordParams @TenantId = @t1, @Email = N'nobody@test.invalid', @Params = @params2 OUTPUT;
BEGIN TRY
    EXEC sec.usp_StartSession @TenantId = @t1, @Email = N'u1@test.invalid',
         @PasswordHash = '$argon2id$v=19$m=65536,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$d3Jvbmd3cm9uZ3dyb25nd3Jvbmd3cm9uZ3dyb25nd3I',
         @SessionToken = @tokNew;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY
    EXEC sec.usp_StartSession @TenantId = @t1, @Email = N'u1@test.invalid', @PasswordHash = @phc, @SessionToken = @tokNew,
         @UserId = @outUser OUTPUT, @MfaRequired = @mfaReq OUTPUT;
END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n2 = COUNT(*) FROM sec.UserSession WHERE TenantId = @t1 AND UserId = @u1 AND TokenHash = HASHBYTES('SHA2_256', @tokNew);
SELECT @rows = COUNT(*) FROM sec.LoginAttempt WHERE UserId = @u1 AND Outcome IN ('FAILED_PASSWORD', 'LOGIN_SUCCESS');
SELECT @i = FailedAttempts FROM sec.AppUser WHERE AppUserId = @u1;
IF @params = '$argon2id$v=19$m=65536,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA' AND @params2 IS NULL AND @err = 50005 AND @err2 IS NULL
   AND @outUser = @u1 AND @mfaReq = 1 AND @n2 = 1 AND @rows = 2 AND @i = 0
    PRINT 'PASS T33: login checks the hash in the database, logs both attempts and creates the session';
ELSE PRINT 'FAIL T33: login parameters, refusal, session or counters are wrong';
ROLLBACK TRANSACTION sp_t33;

/* T34: five wrong passwords within 15 minutes lock the account; the right password is then refused and logged as
   DENIED_LOCKED, and no session is created (BR-PLT-005, FR-PLT-012). */
SAVE TRANSACTION sp_t34;
EXEC #Bind @t1;
SET @err = NULL; SET @i = 0;
EXECUTE AS USER = N'tp_test_app';
WHILE @i < 5
BEGIN
    BEGIN TRY
        EXEC sec.usp_StartSession @TenantId = @t1, @Email = N'u1@test.invalid', @PasswordHash = 'wrong', @SessionToken = @tokNew;
    END TRY
    BEGIN CATCH SET @err3 = ERROR_NUMBER(); END CATCH;
    SET @i = @i + 1;
END;
BEGIN TRY EXEC sec.usp_StartSession @TenantId = @t1, @Email = N'u1@test.invalid', @PasswordHash = @phc, @SessionToken = @tokNew; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @u1 AND Status = 'LOCKED' AND LockedUntil > SYSUTCDATETIME();
SELECT @n2 = COUNT(*) FROM sec.LoginAttempt WHERE UserId = @u1 AND Outcome = 'LOCKOUT';
SELECT @rows = COUNT(*) FROM sec.LoginAttempt WHERE UserId = @u1 AND Outcome = 'DENIED_LOCKED';
SELECT @i = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @tokNew);
IF @err = 50005 AND @n = 1 AND @n2 = 1 AND @rows = 1 AND @i = 0 PRINT 'PASS T34: five failures lock the account and the right password is then refused';
ELSE PRINT 'FAIL T34: the lockout rule was not applied';
ROLLBACK TRANSACTION sp_t34;

/* T35: the application role cannot read stored password hashes (230), create sessions (229), or change a session at
   all: not its token and not its 12-hour absolute expiry (229, ADR 0003). */
DECLARE @err4 INT;
SAVE TRANSACTION sp_t35;
SET @err = NULL; SET @err2 = NULL; SET @err3 = NULL; SET @err4 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT TOP (1) PasswordHash FROM sec.AppUser; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY
    INSERT sec.UserSession (TenantId, UserId, TokenHash, IdleExpiresAt, AbsoluteExpiresAt)
    VALUES (@t1, @u1, 0x01, SYSUTCDATETIME(), SYSUTCDATETIME());
END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE sec.UserSession SET TokenHash = 0x01 WHERE UserId = @u1; END TRY
BEGIN CATCH SET @err3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE sec.UserSession SET AbsoluteExpiresAt = DATEADD(DAY, 30, SYSUTCDATETIME()) WHERE UserId = @u1; END TRY
BEGIN CATCH SET @err4 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 230 AND @err2 = 229 AND @err3 = 229 AND @err4 = 229 PRINT 'PASS T35: the application role cannot read password hashes, create sessions, change a session token or extend its absolute expiry';
ELSE PRINT 'FAIL T35: the application role read a hash, created a session, changed a token or extended a session';
ROLLBACK TRANSACTION sp_t35;

/* T36: a user with MFA cannot bind a session until the MFA check is recorded, and a failed check is logged (BR-PLT-006). */
SAVE TRANSACTION sp_t36;
EXEC #Bind @t1;
UPDATE sec.AppUser SET MfaEnabled = 1 WHERE AppUserId = @u1;
UPDATE sec.UserSession SET MfaVerifiedAt = NULL WHERE TokenHash = HASHBYTES('SHA2_256', @tok1);
SET @err = NULL; SET @err2 = NULL; SET @err3 = NULL; SET @n = NULL; SET @n2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tok1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_ConfirmMfa @TenantId = @t1, @SessionToken = @tok1, @Passed = 0; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_ConfirmMfa @TenantId = @t1, @SessionToken = @tok1, @Passed = 1; END TRY
BEGIN CATCH SET @err3 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM sec.UserSession WHERE TenantId = @t1 AND TokenHash = HASHBYTES('SHA2_256', @tok1) AND MfaVerifiedAt IS NOT NULL;
SELECT @n2 = COUNT(*) FROM sec.LoginAttempt WHERE UserId = @u1 AND Outcome = 'FAILED_MFA';
IF @err = 50003 AND @err2 IS NULL AND @err3 IS NULL AND @n = 1 AND @n2 = 1 PRINT 'PASS T36: a session needs a recorded MFA check before it binds, and a failed check is logged';
ELSE PRINT 'FAIL T36: a session without MFA bound, or the MFA result was not recorded';
ROLLBACK TRANSACTION sp_t36;

/* T25: disabling the user ends the binding of that user's connection: no row is visible and the binding row is gone. */
SAVE TRANSACTION sp_t25;
EXEC #Bind @t1, @u1;
UPDATE sec.AppUser SET Status = 'DISABLED' WHERE AppUserId = @u1;
SELECT @n2 = COUNT(*) FROM sec.SessionBinding WHERE SessionId = @@SPID;
SET @err = NULL; SET @n = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId = @f1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 0 AND @n2 = 0 PRINT 'PASS T25: disabling the user ends its binding';
ELSE PRINT 'FAIL T25: a disabled user''s connection still sees the tenant''s rows or keeps its binding';
ROLLBACK TRANSACTION sp_t25;

/* T26: closing the tenant ends the bindings of its connections: no row is visible and the binding row is gone. */
SAVE TRANSACTION sp_t26;
EXEC #Bind @t1;
UPDATE plat.Tenant SET Status = 'CLOSED', ClosedAt = SYSUTCDATETIME() WHERE TenantId = @t1;
SELECT @n2 = COUNT(*) FROM sec.SessionBinding WHERE SessionId = @@SPID;
SET @err = NULL; SET @n = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId = @f1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 0 AND @n2 = 0 PRINT 'PASS T26: closing the tenant ends its bindings';
ELSE PRINT 'FAIL T26: a connection of a closed tenant still sees rows or keeps its binding';
ROLLBACK TRANSACTION sp_t26;

/* T27: a suspended tenant keeps reads for its bound connections (BR-PLT-002), but writes are refused (33504). */
SAVE TRANSACTION sp_t27;
UPDATE plat.Tenant SET Status = 'SUSPENDED', SuspendedReason = N'test' WHERE TenantId = @t1;
EXEC #Bind @t1;
SET @err = NULL; SET @err2 = NULL; SET @n = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId = @f1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE fac.Facility SET TotalAmount = 1 WHERE FacilityId = @f1; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 1 AND @err2 = 33504 PRINT 'PASS T27: a suspended tenant reads but cannot write';
ELSE PRINT 'FAIL T27: a suspended tenant read or wrote in a way the write check does not allow';
ROLLBACK TRANSACTION sp_t27;

/* T30: deleting the user row ends the binding of that user's connection: no row is visible and the binding is gone (CTX-3). */
SAVE TRANSACTION sp_t30;
EXEC #Bind @t1;
DELETE FROM sec.UserSession WHERE TenantId = @t1 AND UserId = @u1;    -- the user's sessions reference it (foreign key)
DELETE FROM sec.UserRole WHERE TenantId = @t1 AND UserId = @u1;       -- and so does its role assignment
EXEC #Bind @t1, @u1;                                                  -- bind after that, so only the user delete can revoke
DELETE FROM sec.AppUser WHERE AppUserId = @u1;
SELECT @n2 = COUNT(*) FROM sec.SessionBinding WHERE SessionId = @@SPID;
SET @err = NULL; SET @n = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId = @f1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 0 AND @n2 = 0 PRINT 'PASS T30: deleting the user row ends its binding';
ELSE PRINT 'FAIL T30: a deleted user''s connection still sees rows or keeps its binding';
ROLLBACK TRANSACTION sp_t30;

/* T31: a suspended tenant keeps reads for its connections but cannot delete its own rows (33504, CTX-1). */
SAVE TRANSACTION sp_t31;
EXEC #Bind @t1, @u1;
INSERT sec.LoginAttempt (TenantId, LoginName, Outcome) VALUES (@t1, N'test-login', 'LOGIN_SUCCESS');
UPDATE plat.Tenant SET Status = 'SUSPENDED', SuspendedReason = N'test' WHERE TenantId = @t1;
EXEC #Bind @t1, @u1;
SET @err = NULL; SET @rows = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    DELETE FROM sec.LoginAttempt WHERE TenantId = @t1;
    SET @rows = @@ROWCOUNT;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @n = COUNT(*) FROM sec.LoginAttempt WHERE TenantId = @t1;
IF @err = 33504 AND @n = 1 PRINT 'PASS T31: a suspended tenant cannot delete its own rows';
ELSE PRINT 'FAIL T31: a suspended tenant deleted its own rows or the delete was refused with another error';
ROLLBACK TRANSACTION sp_t31;

/* T37: ending a session (an administrator's termination) revokes the bindings of its user at once (FR-PLT-014). */
SAVE TRANSACTION sp_t37;
EXEC #Bind @t1, @u1;
UPDATE sec.UserSession SET EndedAt = SYSUTCDATETIME(), EndReason = 'TERMINATED_BY_ADMIN'
 WHERE TenantId = @t1 AND TokenHash = HASHBYTES('SHA2_256', @tok1);
SELECT @n2 = COUNT(*) FROM sec.SessionBinding WHERE SessionId = @@SPID;
SET @err = NULL; SET @n = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId = @f1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL AND @n = 0 AND @n2 = 0 PRINT 'PASS T37: ending a session revokes the binding of its user';
ELSE PRINT 'FAIL T37: an ended session left a working binding';
ROLLBACK TRANSACTION sp_t37;

/* T40: in a SUSPENDED tenant the tenant administrator may still log in and is admitted by the access rule; another
   user is not admitted and its session does not bind (50003). Reads only for the administrator: T27. */
SAVE TRANSACTION sp_t40;
UPDATE plat.Tenant SET Status = 'SUSPENDED', SuspendedReason = N'test' WHERE TenantId = @t1;
EXEC #Bind @t1;                                                     -- sa reads the role rows only when bound
SET @err = NULL; SET @err2 = NULL; SET @outUser = NULL;
DECLARE @t40ta INT = (SELECT COUNT(*) FROM sec.fn_TenantLoginAllowed(@t1, @u1));
DECLARE @t40other INT = (SELECT COUNT(*) FROM sec.fn_TenantLoginAllowed(@t1, @u1b));
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tok1b; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_StartSession @TenantId = @t1, @Email = N'u1@test.invalid', @PasswordHash = @phc, @SessionToken = @tokNew, @UserId = @outUser OUTPUT; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @t40ta = 1 AND @t40other = 0 AND @err = 50003 AND @err2 IS NULL AND @outUser = @u1
    PRINT 'PASS T40: in a suspended tenant only the tenant administrator is admitted';
ELSE PRINT 'FAIL T40: the suspended-tenant rule was not applied';
ROLLBACK TRANSACTION sp_t40;

/* T41: a CLOSED tenant admits only its administrator, only within 30 days of closing; ARCHIVED_READ_ONLY admits nobody. */
SAVE TRANSACTION sp_t41;
SET @err = NULL; SET @err2 = NULL; SET @err3 = NULL;
UPDATE plat.Tenant SET Status = 'CLOSED', ClosedAt = DATEADD(DAY, -1, SYSUTCDATETIME()) WHERE TenantId = @t1;
EXEC #Bind @t1;                                  -- after the change, which revokes bindings; sa reads role rows only when bound
DECLARE @t41ok INT = (SELECT COUNT(*) FROM sec.fn_TenantLoginAllowed(@t1, @u1));
DECLARE @t41no INT = (SELECT COUNT(*) FROM sec.fn_TenantLoginAllowed(@t1, @u1b));
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tok1b; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
UPDATE plat.Tenant SET ClosedAt = DATEADD(DAY, -31, SYSUTCDATETIME()) WHERE TenantId = @t1;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tok1; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
UPDATE plat.Tenant SET Status = 'ARCHIVED_READ_ONLY', ArchivedAt = SYSUTCDATETIME() WHERE TenantId = @t1;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tok1; END TRY
BEGIN CATCH SET @err3 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @t41ok = 1 AND @t41no = 0 AND @err = 50003 AND @err2 = 50002 AND @err3 = 50002
    PRINT 'PASS T41: a closed tenant admits its administrator for 30 days only, and an archived tenant admits nobody';
ELSE PRINT 'FAIL T41: the closed or archived tenant rule was not applied (' + CONCAT(@t41ok, ',', @t41no, ',', @err, ',', @err2, ',', @err3) + ')';
ROLLBACK TRANSACTION sp_t41;

/* T42: login in a SUSPENDED tenant: a user other than the administrator who proves the password gets 50006 and no
   session; a wrong password still gets the one message (50005). */
SAVE TRANSACTION sp_t42;
UPDATE plat.Tenant SET Status = 'SUSPENDED', SuspendedReason = N'test' WHERE TenantId = @t1;
SET @err = NULL; SET @err2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_StartSession @TenantId = @t1, @Email = N'u1b@test.invalid', @PasswordHash = @phc, @SessionToken = @tokNew; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_StartSession @TenantId = @t1, @Email = N'u1b@test.invalid', @PasswordHash = 'wrong', @SessionToken = @tokNew; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #Bind @t1;
SELECT @n = COUNT(*) FROM sec.UserSession WHERE TokenHash = HASHBYTES('SHA2_256', @tokNew);
SELECT @n2 = COUNT(*) FROM sec.LoginAttempt WHERE UserId = @u1b AND Outcome = 'DENIED_TENANT';
IF @err = 50006 AND @err2 = 50005 AND @n = 0 AND @n2 = 1 PRINT 'PASS T42: a proven password in a tenant closed to the user gets 50006 and no session';
ELSE PRINT 'FAIL T42: the login did not apply the tenant status rule';
ROLLBACK TRANSACTION sp_t42;

/* T43: MFA is mandatory: a session without a recorded MFA check binds nothing, even for a user without MFA enabled. */
SAVE TRANSACTION sp_t43;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
SET @err = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tokNoMfa; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 50003 PRINT 'PASS T43: a session without a recorded MFA check binds nothing';
ELSE PRINT 'FAIL T43: a session without MFA was bound';
ROLLBACK TRANSACTION sp_t43;

/* T44: a tenant connection cannot write a platform audit event (TenantId NULL, O-19). */
SAVE TRANSACTION sp_t44;
EXEC #Bind @t1;
SET @err = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, Action) VALUES (NULL, SYSUTCDATETIME(), 'USER', 'TEST_T44'); END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 33504 PRINT 'PASS T44: a tenant connection cannot write a platform audit event';
ELSE PRINT 'FAIL T44: a tenant connection wrote an audit row without a tenant';
ROLLBACK TRANSACTION sp_t44;

/* T45: O-24 closed (ADR 0003): bound to its tenant, the application role cannot set a password or a status, read a
   password-history or recovery-code hash, mint a link, or reopen an ended session. */
SAVE TRANSACTION sp_t45;
EXEC #Bind @t1;
DECLARE @e1 INT, @e2 INT, @e3 INT, @e4 INT, @e5 INT, @e6 INT;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY UPDATE sec.AppUser SET PasswordHash = @phc WHERE AppUserId = @u1b; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE sec.AppUser SET Status = 'ACTIVE', FailedAttempts = 0 WHERE AppUserId = @u1x; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY SELECT TOP (1) PasswordHash FROM sec.UserPasswordHistory; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY SELECT TOP (1) CodeHash FROM sec.MfaRecoveryCode; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
BEGIN TRY
    INSERT sec.UserToken (TenantId, UserId, Purpose, TokenHash, ExpiresAt) VALUES (@t1, @u1b, 'PASSWORD_RESET', 0x01, SYSUTCDATETIME());
END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE sec.UserSession SET EndedAt = NULL, EndReason = NULL WHERE TokenHash = HASHBYTES('SHA2_256', @tokEnded); END TRY
BEGIN CATCH SET @e6 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @e1 = 230 AND @e2 = 230 AND @e3 = 230 AND @e4 = 230 AND @e5 = 229 AND @e6 = 229
    PRINT 'PASS T45: the application role cannot set passwords or status, read history or recovery hashes, mint links or reopen sessions';
ELSE PRINT 'FAIL T45: a direct right replaced by the account procedures is still open';
ROLLBACK TRANSACTION sp_t45;

/* T46: a service account cannot be locked by guessing: its failed logins are not counted (it has no password). */
SAVE TRANSACTION sp_t46;
SET @i = 0;
EXECUTE AS USER = N'tp_test_app';
WHILE @i < 6
BEGIN
    BEGIN TRY EXEC sec.usp_StartSession @TenantId = @t1, @Email = N'svc@test.invalid', @PasswordHash = 'guess', @SessionToken = @tokNew; END TRY
    BEGIN CATCH SET @err3 = ERROR_NUMBER(); END CATCH;
    SET @i = @i + 1;
END;
REVERT;
EXEC #Bind @t1;
SELECT @n = COUNT(*) FROM sec.AppUser WHERE AppUserId = @usys AND Status = 'ACTIVE' AND FailedAttempts = 0;
IF @n = 1 PRINT 'PASS T46: a service account is never locked by failed logins';
ELSE PRINT 'FAIL T46: failed logins locked or counted against a service account';
ROLLBACK TRANSACTION sp_t46;

/* T19: a valid session binds the connection to its tenant and its user; afterwards only that tenant's rows are visible. */
SAVE TRANSACTION sp_t19;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;        -- the procedure binds only an unbound connection
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
SET @err = NULL; SET @n = NULL; SET @n2 = NULL; SET @ctx = NULL; SET @uctx = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    EXEC sec.usp_SetSessionContext @TenantId = @t1, @SessionToken = @tok1;
    SET @err = 0;
    SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId IN (@f1, @f2);
    SELECT @n2 = COUNT(*) FROM cfg.NonWorkingDay WHERE NameEn = N'TEST-T2';
    SET @ctx = CAST(SESSION_CONTEXT(N'TenantId') AS INT);
    SET @uctx = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 0 AND @n = 1 AND @n2 = 0 AND @ctx = @t1 AND @uctx = @u1 PRINT 'PASS T19: a valid session binds its tenant and user, and only that tenant is visible';
ELSE PRINT 'FAIL T19: the procedure did not bind the session''s tenant and user, or rows of another tenant are visible';
ROLLBACK TRANSACTION sp_t19;

/* T20: once bound, the context cannot be changed in that connection, and a second binding is refused (50004).
   This case runs after T19, which left the connection bound to tenant 1. */
SET @err = NULL; SET @err2 = NULL;
BEGIN TRY EXEC sys.sp_set_session_context @key = N'TenantId', @value = @t2; SET @err = 0; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
SET @ctx = CAST(SESSION_CONTEXT(N'TenantId') AS INT);
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t2, @SessionToken = @tok2; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err <> 0 AND @ctx = @t1 AND @err2 = 50004 PRINT 'PASS T20: a bound context cannot be changed, and a second binding is refused';
ELSE PRINT 'FAIL T20: the bound context was changed, or a second binding was not refused with 50004';

/* ---------- Cases 21-23: the reporting role (tp_readonly) ---------- */

/* T29: the reporting role reads neither the tenant registry nor the module list of any tenant (PRED-04). */
SET @err = NULL; SET @err2 = NULL;
EXECUTE AS USER = N'tp_test_ro';
BEGIN TRY SELECT COUNT(*) FROM plat.Tenant; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY SELECT COUNT(*) FROM plat.TenantModule; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 229 AND @err2 = 229 PRINT 'PASS T29: the reporting role cannot read the tenant registry or the module list';
ELSE PRINT 'FAIL T29: the reporting role read the tenant registry or the module list';

/* T21: the reporting role cannot read a restricted column (230). */
SET @err = NULL;
EXECUTE AS USER = N'tp_test_ro';
BEGIN TRY SELECT TOP (1) AccountNoHash FROM acc.BankAccount; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 230 PRINT 'PASS T21: the reporting role cannot read a restricted column';
ELSE PRINT 'FAIL T21: reading a restricted column was not refused with 230';

/* T22: the reporting role cannot read the platform operator table or the binding table (229). */
SET @err = NULL; SET @err2 = NULL;
EXECUTE AS USER = N'tp_test_ro';
BEGIN TRY SELECT COUNT(*) FROM plat.PlatformOperator; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY SELECT COUNT(*) FROM sec.SessionBinding; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 229 AND @err2 = 229 PRINT 'PASS T22: the reporting role cannot read the platform operator table or the binding table';
ELSE PRINT 'FAIL T22: reading plat.PlatformOperator or sec.SessionBinding was not refused with 229';

/* T23: the reporting role can read a column that is not restricted (positive control for T21). */
SET @err = NULL;
EXECUTE AS USER = N'tp_test_ro';
BEGIN TRY SELECT TOP (1) Nickname FROM acc.BankAccount; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err IS NULL PRINT 'PASS T23: the reporting role can read an unrestricted column';
ELSE PRINT 'FAIL T23: reading an unrestricted column raised error ' + CAST(@err AS VARCHAR(10));

/* ---------- Case 24: coverage ---------- */

/* T24: every table with a TenantId column has an enabled filter, except the two listed tables:
   plat.Tenant (the tenant table itself) and plat.TenantModule (no grant to the application roles; the model
   marks it noapp). Every policy is enabled, and the application role has no permission on plat.TenantModule. */
SELECT @unfiltered = COUNT(*)
FROM sys.tables AS t JOIN sys.columns AS c ON c.object_id = t.object_id AND c.name = N'TenantId'
WHERE SCHEMA_NAME(t.schema_id) + N'.' + t.name NOT IN (N'plat.Tenant', N'plat.TenantModule')
  AND NOT EXISTS (SELECT 1 FROM sys.security_predicates AS p
                  JOIN sys.security_policies AS sp ON sp.object_id = p.object_id
                  WHERE p.target_object_id = t.object_id AND p.predicate_type_desc = N'FILTER' AND sp.is_enabled = 1);
SELECT @disabled = COUNT(*) FROM sys.security_policies WHERE is_enabled = 0;
SELECT @allowed = COUNT(*)
FROM sys.tables AS t JOIN sys.columns AS c ON c.object_id = t.object_id AND c.name = N'TenantId'
WHERE SCHEMA_NAME(t.schema_id) + N'.' + t.name IN (N'plat.Tenant', N'plat.TenantModule');
EXECUTE AS USER = N'tp_test_app';
SELECT @tm = HAS_PERMS_BY_NAME(N'plat.TenantModule', N'OBJECT', N'SELECT');
REVERT;
IF @unfiltered = 0 AND @disabled = 0 AND @allowed = 2 AND ISNULL(@tm, 0) = 0
    PRINT 'PASS T24: every tenant table is filtered, every policy is enabled, and plat.TenantModule is not readable by the application role';
ELSE PRINT 'FAIL T24: unfiltered tables ' + CAST(@unfiltered AS VARCHAR(10)) + ', disabled policies ' + CAST(@disabled AS VARCHAR(10))
         + ', allow-list tables ' + CAST(@allowed AS VARCHAR(10)) + ', permission on TenantModule ' + CAST(ISNULL(@tm, 0) AS VARCHAR(10));

PRINT 'Tenant-isolation tests finished; every change is rolled back.';
ROLLBACK TRANSACTION;

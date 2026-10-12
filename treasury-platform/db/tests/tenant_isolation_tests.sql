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
        UPDATE SET BoundTenantId = @TenantId, BoundUserId = @UserId, BindingToken = @token, BoundAt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (s.SessionId, @TenantId, @UserId, @token);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
END;
GO

DECLARE @t1 INT, @t2 INT, @t3 INT;
DECLARE @u1 BIGINT, @u1x BIGINT, @u2 BIGINT;
DECLARE @f1 BIGINT, @f2 BIGINT;
DECLARE @err INT, @err2 INT, @n INT, @n2 INT, @rows INT, @ctx INT;
DECLARE @amt DECIMAL(19,4);
DECLARE @unfiltered INT, @disabled INT, @allowed INT, @tm INT;
DECLARE @other UNIQUEIDENTIFIER;

-- Seed: three tenants (two open, one closed)
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone, ClosedAt)
VALUES (N'TST-A', N'Test A', N'Test A', 1, 1, 'ACTIVE', 'Asia/Riyadh', NULL),
       (N'TST-B', N'Test B', N'Test B', 1, 1, 'ACTIVE', 'Asia/Riyadh', NULL),
       (N'TST-C', N'Test C', N'Test C', 1, 1, 'CLOSED', 'Asia/Riyadh', SYSUTCDATETIME());
SELECT @t1 = TenantId FROM plat.Tenant WHERE Code = N'TST-A';
SELECT @t2 = TenantId FROM plat.Tenant WHERE Code = N'TST-B';
SELECT @t3 = TenantId FROM plat.Tenant WHERE Code = N'TST-C';

-- Seed: tenant 1 (two users, a facility, a non-working day)
EXEC #Bind @t1;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t1, N'u1@test.invalid', N'User 1', 'ACTIVE', 'TEST');
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t1, N'u1x@test.invalid', N'User 1 disabled', 'DISABLED', 'TEST');
SELECT @u1 = AppUserId FROM sec.AppUser WHERE Email = N'u1@test.invalid';
SELECT @u1x = AppUserId FROM sec.AppUser WHERE Email = N'u1x@test.invalid';
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (@t1, N'TST-F1', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f1 = SCOPE_IDENTITY();
INSERT cfg.NonWorkingDay (TenantId, CountryId, OnDate, NameEn) VALUES (@t1, 1, '2026-12-26', N'TEST-T1');

-- Seed: tenant 2 (a user, a facility, a non-working day)
EXEC #Bind @t2;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t2, N'u2@test.invalid', N'User 2', 'ACTIVE', 'TEST');
SELECT @u2 = AppUserId FROM sec.AppUser WHERE Email = N'u2@test.invalid';
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (@t2, N'TST-F2', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f2 = SCOPE_IDENTITY();
INSERT cfg.NonWorkingDay (TenantId, CountryId, OnDate, NameEn) VALUES (@t2, 1, '2026-12-27', N'TEST-T2');
INSERT plat.TenantModule (TenantId, ModuleCode, IsEnabled) VALUES (@t2, 'CORE', 1);

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

/* ---------- Cases 17-20: the context procedure sec.usp_SetSessionContext ---------- */

/* T17: the procedure refuses an unknown tenant and a closed tenant (50002). */
SAVE TRANSACTION sp_t17;
SET @err = NULL; SET @err2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = 999999, @UserId = @u1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t3, @UserId = @u1; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 50002 AND @err2 = 50002 PRINT 'PASS T17: the context procedure refuses an unknown and a closed tenant';
ELSE PRINT 'FAIL T17: unknown or closed tenant was not refused with 50002';
ROLLBACK TRANSACTION sp_t17;

/* T18: the procedure refuses a user who is not a member of the tenant, and a disabled member (50003). */
SAVE TRANSACTION sp_t18;
SET @err = NULL; SET @err2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t2, @UserId = @u1; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t1, @UserId = @u1x; END TRY
BEGIN CATCH SET @err2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 50003 AND @err2 = 50003 PRINT 'PASS T18: the context procedure refuses a non-member and a disabled member';
ELSE PRINT 'FAIL T18: a non-member or disabled user was not refused with 50003';
ROLLBACK TRANSACTION sp_t18;

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
EXEC #Bind @t1, @u1;
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

/* T19: an active member binds the connection to its tenant; afterwards only that tenant's rows are visible. */
SAVE TRANSACTION sp_t19;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;        -- the procedure binds only an unbound connection
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
SET @err = NULL; SET @n = NULL; SET @n2 = NULL; SET @ctx = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY
    EXEC sec.usp_SetSessionContext @TenantId = @t1, @UserId = @u1;
    SET @err = 0;
    SELECT @n = COUNT(*) FROM fac.Facility WHERE FacilityId IN (@f1, @f2);
    SELECT @n2 = COUNT(*) FROM cfg.NonWorkingDay WHERE NameEn = N'TEST-T2';
    SET @ctx = CAST(SESSION_CONTEXT(N'TenantId') AS INT);
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
IF @err = 0 AND @n = 1 AND @n2 = 0 AND @ctx = @t1 PRINT 'PASS T19: an active member is bound to its tenant and sees only that tenant';
ELSE PRINT 'FAIL T19: the procedure did not bind the connection to the tenant, or rows of another tenant are visible';
ROLLBACK TRANSACTION sp_t19;

/* T20: once bound, the context cannot be changed in that connection, and a second binding is refused (50004).
   This case runs after T19, which left the connection bound to tenant 1. */
SET @err = NULL; SET @err2 = NULL;
BEGIN TRY EXEC sys.sp_set_session_context @key = N'TenantId', @value = @t2; SET @err = 0; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
SET @ctx = CAST(SESSION_CONTEXT(N'TenantId') AS INT);
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetSessionContext @TenantId = @t2, @UserId = @u2; END TRY
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

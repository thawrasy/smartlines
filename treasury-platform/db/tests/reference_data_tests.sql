/* ============================================================================
   Platform reference data seen from a tenant (db/seed/101 and 103; FR-CAT-021, BR-CAT-015, BR-PLT-001, FR-LCT-006).
   R1  the tenant application reads the countries, currencies, Incoterms and the platform's UCP 600 articles
   R2  it writes none of the global lists (229)
   R3  it cannot change a platform UCP article, so it cannot mark one verified (33504, the row filter)
   R4  the seed leaves no user behind, and every platform UCP article is UNVERIFIED until an operator checks it
   R5  the application changes no code, system or locked flag or seed key of a catalogue row (230), and a locked row
       stays active (547); its names it may change (060, FR-CAT-001, FR-CAT-004)
   R6  the application adds no system row and no item to a closed system list (50174), and a locked row is a system
       row (547); its own rows and the items of its own lists it may add (FR-CAT-020)
   R7  the seeder, bound as the onboarding job, adds system rows and items of closed lists
   R8  the application deletes no catalogue row (229)

   Run against a deployed BankFas database that holds no real data, with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/reference_data_tests.sql
   The cases run in one transaction, rolled back at the end. Each prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
IF USER_ID(N'tp_test_ref') IS NULL
BEGIN
    CREATE USER [tp_test_ref] WITHOUT LOGIN;
    ALTER ROLE [tp_app] ADD MEMBER [tp_test_ref];
END;
GO
DECLARE @t INT, @tk UNIQUEIDENTIFIER = NEWID(), @pc INT, @n5 INT, @f1 INT, @f2 INT, @f3 INT, @f4 INT, @countries INT, @currencies INT, @inco INT, @legacy INT, @ucp INT,
        @e1 INT, @e2 INT, @e3 INT, @e4 INT, @e5 INT, @after NVARCHAR(10);
BEGIN TRANSACTION;
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT FK_Tenant_HomeCountryId;
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('tst-ref', N'R', N'R', 1, 1, 'ACTIVE', 'UTC');
SET @t = SCOPE_IDENTITY();
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (@@SPID, @t, 0, @tk);
EXEC sys.sp_set_session_context @key = N'TenantId', @value = @t;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @tk;

/* R1 */
EXECUTE AS USER = N'tp_test_ref';
SELECT @countries = COUNT(CountryId) FROM ref.Country;
SELECT @currencies = COUNT(CurrencyId) FROM ref.Currency;
SELECT @inco = COUNT(IncotermId), @legacy = SUM(CASE WHEN Status = 'LEGACY' THEN 1 ELSE 0 END) FROM ref.Incoterm;
SELECT @ucp = COUNT(UcpArticleId) FROM ref.UcpArticle WHERE TenantId IS NULL AND Version = 'UCP600';
REVERT;
IF @countries = 249 AND @currencies = 157 AND @inco = 16 AND @legacy = 5 AND @ucp = 39
    PRINT 'PASS R1: a tenant reads 249 countries, 157 currencies, 16 Incoterms (5 legacy) and the 39 UCP 600 articles';
ELSE PRINT CONCAT('FAIL R1: countries ', @countries, ', currencies ', @currencies, ', Incoterms ', @inco, ' (legacy ', @legacy, '), UCP articles ', @ucp);

/* R2 */
EXECUTE AS USER = N'tp_test_ref';
BEGIN TRY INSERT ref.Incoterm (Code, NameEn, RulesVersion) VALUES ('XXX', N'Test', '2020'); END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE ref.Incoterm SET Status = 'ACTIVE' WHERE Code = 'DAT'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE ref.Currency SET Decimals = 2 WHERE Code = 'KWD'; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE ref.Country SET DialCode = '+1' WHERE Iso2 = 'SA'; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @e1 = 229 AND @e2 = 229 AND @e3 = 229 AND @e4 = 229
    PRINT 'PASS R2: a tenant writes none of the global lists';
ELSE PRINT CONCAT('FAIL R2: errors ', @e1, ' ', @e2, ' ', @e3, ' ', @e4);

/* R3 */
SAVE TRANSACTION r3;
EXECUTE AS USER = N'tp_test_ref';
BEGIN TRY UPDATE ref.UcpArticle SET TitleEn = N'Changed' WHERE TenantId IS NULL AND ArticleNo = '14'; END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH;
REVERT;
IF XACT_STATE() = 1 ROLLBACK TRANSACTION r3;
SELECT @after = LEFT(TitleEn, 10) FROM ref.UcpArticle WHERE TenantId IS NULL AND Version = 'UCP600' AND ArticleNo = '14';
IF @e5 = 33504 AND @after = N'Standard f'
    PRINT 'PASS R3: a tenant cannot change a platform UCP article';
ELSE PRINT CONCAT('FAIL R3: error ', @e5, ', title now ', @after);

/* R4 */
IF USER_ID(N'tp_seed_platform') IS NULL
   AND NOT EXISTS (SELECT 1 FROM ref.UcpArticle WHERE TenantId IS NULL AND (VerificationStatus <> 'UNVERIFIED' OR VerifiedBy IS NOT NULL))
    PRINT 'PASS R4: the seed leaves no user behind, and every platform UCP article waits for verification';
ELSE PRINT 'FAIL R4: a seed user remains, or a platform UCP article is marked verified';

/* R5 */
INSERT cat.ProductCategory (TenantId, Code, NameAr, NameEn, IsSystem, IsLocked, SeedKey) VALUES (@t, 'TST_LOCKED', N'مقفل', N'Locked', 1, 1, 'TST.LOCKED');
SET @pc = SCOPE_IDENTITY();
EXECUTE AS USER = N'tp_test_ref';
BEGIN TRY UPDATE cat.ProductCategory SET Code = 'TST_OTHER' WHERE ProductCategoryId = @pc; END TRY BEGIN CATCH SET @f1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE cat.ProductCategory SET IsLocked = 0 WHERE ProductCategoryId = @pc; END TRY BEGIN CATCH SET @f2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE cat.ProductCategory SET SeedKey = 'TST.OTHER' WHERE ProductCategoryId = @pc; END TRY BEGIN CATCH SET @f3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE cat.ProductCategory SET IsActive = 0 WHERE ProductCategoryId = @pc; END TRY BEGIN CATCH SET @f4 = ERROR_NUMBER(); END CATCH;
UPDATE cat.ProductCategory SET NameAr = N'اسم جديد' WHERE ProductCategoryId = @pc;
SET @n5 = @@ROWCOUNT;
REVERT;
IF @f1 = 230 AND @f2 = 230 AND @f3 = 230 AND @f4 = 547 AND @n5 = 1
    PRINT 'PASS R5: the application changes no code, flag or seed key of a catalogue row, and a locked row stays active';
ELSE PRINT CONCAT('FAIL R5: errors ', @f1, ' ', @f2, ' ', @f3, ' ', @f4, ', renamed ', @n5);

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
GO
/* R6 to R8: a refusal raised in a trigger dooms its transaction, so each refusal is the last statement of its own
   transaction, on a tenant of its own (#CatCase), and its error is kept in #CatResult. */
CREATE TABLE #CatResult (k VARCHAR(10) PRIMARY KEY, e INT NULL, n INT NULL);
GO
CREATE PROCEDURE #CatCase @t INT OUTPUT, @list INT OUTPUT, @own INT OUTPUT, @job BIT = 0
AS
BEGIN
    DECLARE @tk UNIQUEIDENTIFIER = NEWID(), @jobKey VARCHAR(80) = CASE WHEN @job = 1 THEN 'JOB-PLT-ONBOARD' END;
    ALTER TABLE plat.Tenant NOCHECK CONSTRAINT FK_Tenant_HomeCountryId;
    INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('tst-cat', N'C', N'C', 1, 1, 'ACTIVE', 'UTC');
    SET @t = SCOPE_IDENTITY();
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind)
    VALUES (@@SPID, @t, 0, @tk, CASE WHEN @job = 1 THEN 'JOB' ELSE 'USER' END);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @t;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @tk;
    EXEC sys.sp_set_session_context @key = N'JobKey', @value = @jobKey;
    INSERT cat.LookupList (TenantId, Code, NameAr, NameEn, Scope, IsSystem, AllowTenantItems, SeedKey) VALUES (@t, 'TST_CLOSED', N'مغلقة', N'Closed', 'SYSTEM', 1, 0, 'TST.CLOSED');
    SET @list = SCOPE_IDENTITY();
    INSERT cat.LookupList (TenantId, Code, NameAr, Scope) VALUES (@t, 'TST_OWN_LIST', N'قائمتي', 'TENANT');
    SET @own = SCOPE_IDENTITY();
    INSERT cat.ProductCategory (TenantId, Code, NameAr) VALUES (@t, 'TST_OWN', N'خاص');
    INSERT cat.LookupItem (TenantId, LookupListId, Code, NameAr) VALUES (@t, @own, 'TST_OWN_ITEM', N'بندي');
END;
GO
DECLARE @t INT, @list INT, @own INT, @e INT;
BEGIN TRANSACTION; EXEC #CatCase @t OUTPUT, @list OUTPUT, @own OUTPUT;
EXECUTE AS USER = N'tp_test_ref';
BEGIN TRY INSERT cat.ProductCategory (TenantId, Code, NameAr, NameEn, IsSystem) VALUES (@t, 'TST_SYS', N'نظام', N'System', 1); END TRY
BEGIN CATCH SET @e = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT; IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT #CatResult (k, e) VALUES ('sys', @e);
GO
DECLARE @t INT, @list INT, @own INT, @e INT;
BEGIN TRANSACTION; EXEC #CatCase @t OUTPUT, @list OUTPUT, @own OUTPUT;
EXECUTE AS USER = N'tp_test_ref';
BEGIN TRY INSERT cat.ProductCategory (TenantId, Code, NameAr, NameEn, IsLocked) VALUES (@t, 'TST_LOCK2', N'مقفل', N'Locked', 1); END TRY
BEGIN CATCH SET @e = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT; IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT #CatResult (k, e) VALUES ('locked', @e);
GO
DECLARE @t INT, @list INT, @own INT, @e INT, @n INT;
BEGIN TRANSACTION; EXEC #CatCase @t OUTPUT, @list OUTPUT, @own OUTPUT;
EXECUTE AS USER = N'tp_test_ref';
INSERT cat.ProductCategory (TenantId, Code, NameAr) VALUES (@t, 'TST_OWN2', N'خاص');
INSERT cat.LookupItem (TenantId, LookupListId, Code, NameAr) VALUES (@t, @own, 'TST_OWN_ITEM2', N'بندي');
SELECT @n = COUNT(*) FROM cat.LookupItem WHERE TenantId = @t AND Code LIKE 'TST_OWN_ITEM%';
BEGIN TRY INSERT cat.LookupItem (TenantId, LookupListId, Code, NameAr) VALUES (@t, @list, 'TST_ITEM', N'بند'); END TRY
BEGIN CATCH SET @e = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT; IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT #CatResult (k, e, n) VALUES ('closed', @e, @n);
GO
DECLARE @t INT, @list INT, @own INT, @e INT, @n INT;
BEGIN TRANSACTION; EXEC #CatCase @t OUTPUT, @list OUTPUT, @own OUTPUT, @job = 1;
EXECUTE AS USER = N'tp_test_ref';
BEGIN TRY
    INSERT cat.ProductCategory (TenantId, Code, NameAr, NameEn, IsSystem, IsLocked, SeedKey) VALUES (@t, 'TST_SEEDED', N'مبذور', N'Seeded', 1, 1, 'TST.SEEDED');
    INSERT cat.LookupItem (TenantId, LookupListId, Code, NameAr, NameEn, IsSystem, SeedKey) VALUES (@t, @list, 'TST_SEEDED', N'مبذور', N'Seeded', 1, 'TST.ITEM');
    SET @n = 2;
END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT; IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
EXEC sys.sp_set_session_context @key = N'JobKey', @value = NULL;
INSERT #CatResult (k, e, n) VALUES ('seeder', @e, @n);
GO
DECLARE @t INT, @list INT, @own INT, @e1 INT, @e2 INT;
BEGIN TRANSACTION; EXEC #CatCase @t OUTPUT, @list OUTPUT, @own OUTPUT;
EXECUTE AS USER = N'tp_test_ref';
BEGIN TRY DELETE FROM cat.ProductCategory WHERE Code = 'TST_OWN'; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY DELETE FROM cat.LookupItem WHERE Code = 'TST_OWN_ITEM'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT; IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT #CatResult (k, e, n) VALUES ('delete', @e1, @e2);
GO
DECLARE @sys INT = (SELECT e FROM #CatResult WHERE k = 'sys'), @locked INT = (SELECT e FROM #CatResult WHERE k = 'locked'),
        @closed INT = (SELECT e FROM #CatResult WHERE k = 'closed'), @own INT = (SELECT n FROM #CatResult WHERE k = 'closed'),
        @se INT = (SELECT e FROM #CatResult WHERE k = 'seeder'), @sn INT = (SELECT n FROM #CatResult WHERE k = 'seeder'),
        @d1 INT = (SELECT e FROM #CatResult WHERE k = 'delete'), @d2 INT = (SELECT n FROM #CatResult WHERE k = 'delete');
IF @sys = 50174 AND @locked = 547 AND @closed = 50174 AND @own = 2
    PRINT 'PASS R6: the application adds no system or locked row and no item to a closed list, but its own rows and items';
ELSE PRINT CONCAT('FAIL R6: system ', @sys, ', locked ', @locked, ', closed list ', @closed, ', own items ', @own);
IF @se IS NULL AND @sn = 2
    PRINT 'PASS R7: the seeder, bound as the onboarding job, adds system rows and items of closed lists';
ELSE PRINT CONCAT('FAIL R7: error ', @se);
IF @d1 = 229 AND @d2 = 229
    PRINT 'PASS R8: the application deletes no catalogue row';
ELSE PRINT CONCAT('FAIL R8: errors ', @d1, ' ', @d2);
GO
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
DROP USER [tp_test_ref];
PRINT 'Reference data tests finished; every change is rolled back.';
GO

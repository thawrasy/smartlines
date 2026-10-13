/* ============================================================================
   Platform reference data seen from a tenant (db/seed/101 and 103; FR-CAT-021, BR-CAT-015, BR-PLT-001, FR-LCT-006).
   R1  the tenant application reads the countries, currencies, Incoterms and the platform's UCP 600 articles
   R2  it writes none of the global lists (229)
   R3  it cannot change a platform UCP article, so it cannot mark one verified (33504, the row filter)
   R4  the seed leaves no user behind, and every platform UCP article is UNVERIFIED until an operator checks it

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
DECLARE @t INT, @tk UNIQUEIDENTIFIER = NEWID(), @countries INT, @currencies INT, @inco INT, @legacy INT, @ucp INT,
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

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
GO
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
DROP USER [tp_test_ref];
PRINT 'Reference data tests finished; every change is rolled back.';
GO

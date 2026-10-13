/* ============================================================================
   KYC history and cascade deletes (O-13 in tools/dbgen/erd_open_items.py; db/static/041_kyc_profile_versions.sql).
   K1  a company's KYC financial profile is not deleted with its sources of funds by cascade, and the application
       cannot delete it; the only cascade left in the database is an item's legal-form conditions
   K2  a DRAFT completeness profile is edited freely, and deleting an item removes its conditions
   K3  the items and conditions of an ACTIVE profile do not change (50033)
   K4  an ACTIVE or RETIRED profile does not return to DRAFT (50033); retiring and re-activating work

   Run against a deployed BankFas database that holds no real data, with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/kyc_history_tests.sql
   A trigger error ends the transaction, so every case runs in its own transaction, rolled back at the end.
   Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
IF USER_ID(N'tp_test_kyc') IS NULL
BEGIN
    CREATE USER [tp_test_kyc] WITHOUT LOGIN;
    ALTER ROLE [tp_app] ADD MEMBER [tp_test_kyc];
END;
GO
CREATE PROCEDURE #Bind @TenantId INT
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (@@SPID, @TenantId, 0, @token);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
END;
GO
-- One tenant with a company, its KYC financial profile with one source of funds, and a DRAFT completeness profile
-- with one item and one legal-form condition. Catalogue rows are not seeded, so those references are not checked.
CREATE PROCEDURE #Setup @t INT OUTPUT, @fp BIGINT OUTPUT, @p BIGINT OUTPUT, @i BIGINT OUTPUT
AS
BEGIN
    ALTER TABLE plat.Tenant NOCHECK CONSTRAINT FK_Tenant_HomeCountryId;
    ALTER TABLE org.Company NOCHECK CONSTRAINT ALL;
    ALTER TABLE org.CompanyWealthSource NOCHECK CONSTRAINT FK_CompanyWealthSource_WealthSourceId;
    ALTER TABLE pty.KycProfileItemLegalForm NOCHECK CONSTRAINT FK_KycProfileItemLegalForm_LegalEntityTypeId;
    INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('tst-kyc', N'K', N'K', 1, 1, 'ACTIVE', 'UTC');
    SET @t = SCOPE_IDENTITY();
    EXEC #Bind @t;
    DECLARE @c BIGINT;
    INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth)
    VALUES (@t, 'K1', N'ك1', N'K1', 1, 1, 1, 12);
    SET @c = SCOPE_IDENTITY();
    INSERT org.CompanyKycFinancialProfile (TenantId, CompanyId, EffectiveFrom) VALUES (@t, @c, '2026-01-01');
    SET @fp = SCOPE_IDENTITY();
    INSERT org.CompanyWealthSource (TenantId, FinancialProfileId, WealthSourceId) VALUES (@t, @fp, 1);
    INSERT pty.KycProfile (TenantId, NameAr, NameEn, AppliesToRole, IsBaseline) VALUES (@t, N'أساس', N'Baseline', 'ANY', 1);
    SET @p = SCOPE_IDENTITY();
    INSERT pty.KycProfileItem (TenantId, ProfileId, ItemKind, RefCode) VALUES (@t, @p, 'PARTY_FIELD', 'NameAr');
    SET @i = SCOPE_IDENTITY();
    INSERT pty.KycProfileItemLegalForm (TenantId, KycProfileItemId, LegalEntityTypeId) VALUES (@t, @i, 1);
END;
GO

/* K1: the financial profile keeps its sources of funds: deleting it fails on the foreign key (547) for the owner and on
   the right (229) for the application; one cascade remains in the database. */
DECLARE @t INT, @fp BIGINT, @p BIGINT, @i BIGINT, @e1 INT, @e2 INT, @left INT, @cascades INT, @name SYSNAME;
BEGIN TRANSACTION;
EXEC #Setup @t OUTPUT, @fp OUTPUT, @p OUTPUT, @i OUTPUT;
BEGIN TRY DELETE FROM org.CompanyKycFinancialProfile WHERE TenantId = @t AND CompanyKycFinancialProfileId = @fp; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXECUTE AS USER = N'tp_test_kyc';
BEGIN TRY DELETE FROM org.CompanyKycFinancialProfile WHERE TenantId = @t AND CompanyKycFinancialProfileId = @fp; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @left = COUNT(WealthSourceId) FROM org.CompanyWealthSource WHERE TenantId = @t AND FinancialProfileId = @fp;
SELECT @cascades = COUNT(*), @name = MAX(name) FROM sys.foreign_keys WHERE delete_referential_action <> 0 OR update_referential_action <> 0;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 229 AND @left = 1 AND @cascades = 1 AND @name = N'FK_KycProfileItemLegalForm_KycProfileItemId'
    PRINT 'PASS K1: a KYC financial profile is not deleted with its sources of funds; one cascade remains (item conditions)';
ELSE PRINT CONCAT('FAIL K1: delete errors ', @e1, ' and ', @e2, ', sources left ', @left, ', cascades ', @cascades, ' (', @name, ')');
GO

/* K2: in a DRAFT version the application adds, changes and deletes items and conditions; deleting an item removes its
   conditions. */
DECLARE @t INT, @fp BIGINT, @p BIGINT, @i BIGINT, @i2 BIGINT, @e INT, @items INT, @conds INT, @conds2 INT;
BEGIN TRANSACTION;
EXEC #Setup @t OUTPUT, @fp OUTPUT, @p OUTPUT, @i OUTPUT;
EXECUTE AS USER = N'tp_test_kyc';
BEGIN TRY
    INSERT pty.KycProfileItem (TenantId, ProfileId, ItemKind, RefCode) VALUES (@t, @p, 'PARTY_FIELD', 'NameEn');
    SET @i2 = SCOPE_IDENTITY();
    INSERT pty.KycProfileItemLegalForm (TenantId, KycProfileItemId, LegalEntityTypeId) VALUES (@t, @i2, 2);
    UPDATE pty.KycProfileItem SET IsMandatory = 0 WHERE TenantId = @t AND KycProfileItemId = @i2;
    DELETE FROM pty.KycProfileItem WHERE TenantId = @t AND KycProfileItemId = @i;
END TRY
BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @items = COUNT(KycProfileItemId) FROM pty.KycProfileItem WHERE TenantId = @t AND ProfileId = @p;
SELECT @conds = COUNT(LegalEntityTypeId) FROM pty.KycProfileItemLegalForm WHERE TenantId = @t AND KycProfileItemId = @i;
SELECT @conds2 = COUNT(LegalEntityTypeId) FROM pty.KycProfileItemLegalForm WHERE TenantId = @t AND KycProfileItemId = @i2;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e IS NULL AND @items = 1 AND @conds = 0 AND @conds2 = 1
    PRINT 'PASS K2: a draft completeness profile is edited freely, and an item takes its conditions with it';
ELSE PRINT CONCAT('FAIL K2: error ', @e, ', items ', @items, ', conditions of the deleted item ', @conds, ', of the new item ', @conds2);
GO

/* K3: once the version is ACTIVE, every change to its items or conditions is refused (50033). */
DECLARE @cases TABLE (n INT, Stmt NVARCHAR(400));
INSERT @cases VALUES
    (1, N'INSERT pty.KycProfileItem (TenantId, ProfileId, ItemKind, RefCode) VALUES (@t, @p, ''PARTY_FIELD'', ''NameEn'');'),
    (2, N'UPDATE pty.KycProfileItem SET IsMandatory = 0 WHERE TenantId = @t AND KycProfileItemId = @i;'),
    (3, N'DELETE FROM pty.KycProfileItem WHERE TenantId = @t AND KycProfileItemId = @i;'),
    (4, N'INSERT pty.KycProfileItemLegalForm (TenantId, KycProfileItemId, LegalEntityTypeId) VALUES (@t, @i, 2);'),
    (5, N'DELETE FROM pty.KycProfileItemLegalForm WHERE TenantId = @t AND KycProfileItemId = @i;');
DECLARE @n INT = 1, @stmt NVARCHAR(400), @t INT, @fp BIGINT, @p BIGINT, @i BIGINT, @e INT, @good INT = 0;
WHILE @n <= 5
BEGIN
    SELECT @stmt = Stmt, @e = NULL FROM @cases WHERE n = @n;
    BEGIN TRANSACTION;
    EXEC #Setup @t OUTPUT, @fp OUTPUT, @p OUTPUT, @i OUTPUT;
    UPDATE pty.KycProfile SET Status = 'ACTIVE' WHERE TenantId = @t AND KycProfileId = @p;
    EXECUTE AS USER = N'tp_test_kyc';
    BEGIN TRY
        EXEC sys.sp_executesql @stmt, N'@t INT, @p BIGINT, @i BIGINT', @t = @t, @p = @p, @i = @i;
    END TRY
    BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;       -- before REVERT: the trigger error has doomed the transaction
    REVERT;
    IF @e = 50033 SET @good = @good + 1;
    ELSE PRINT CONCAT('INFO K3 case ', @n, ': error ', ISNULL(CAST(@e AS VARCHAR(10)), 'none'));
    SET @n = @n + 1;
END;
IF @good = 5 PRINT 'PASS K3: the items and conditions of an active completeness profile do not change';
ELSE PRINT CONCAT('FAIL K3: ', @good, ' of 5 changes refused');
GO

/* K4: ACTIVE does not return to DRAFT; ACTIVE to RETIRED and back to ACTIVE work; RETIRED does not return to DRAFT. */
DECLARE @t INT, @fp BIGINT, @p BIGINT, @i BIGINT, @e1 INT, @e2 INT, @e3 INT;
BEGIN TRANSACTION;
EXEC #Setup @t OUTPUT, @fp OUTPUT, @p OUTPUT, @i OUTPUT;
UPDATE pty.KycProfile SET Status = 'ACTIVE' WHERE TenantId = @t AND KycProfileId = @p;
EXECUTE AS USER = N'tp_test_kyc';
BEGIN TRY UPDATE pty.KycProfile SET Status = 'DRAFT' WHERE TenantId = @t AND KycProfileId = @p; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
REVERT;
BEGIN TRANSACTION;
EXEC #Setup @t OUTPUT, @fp OUTPUT, @p OUTPUT, @i OUTPUT;
UPDATE pty.KycProfile SET Status = 'ACTIVE' WHERE TenantId = @t AND KycProfileId = @p;
EXECUTE AS USER = N'tp_test_kyc';
BEGIN TRY
    UPDATE pty.KycProfile SET Status = 'RETIRED' WHERE TenantId = @t AND KycProfileId = @p;
    UPDATE pty.KycProfile SET Status = 'ACTIVE' WHERE TenantId = @t AND KycProfileId = @p;
    UPDATE pty.KycProfile SET Status = 'RETIRED' WHERE TenantId = @t AND KycProfileId = @p;
END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE pty.KycProfile SET Status = 'DRAFT' WHERE TenantId = @t AND KycProfileId = @p; END TRY
BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
REVERT;
IF @e1 = 50033 AND @e2 IS NULL AND @e3 = 50033
    PRINT 'PASS K4: an active or retired completeness profile does not return to draft';
ELSE PRINT CONCAT('FAIL K4: errors ', @e1, ', ', @e2, ', ', @e3);
GO

DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
DROP USER [tp_test_kyc];
PRINT 'KYC history tests finished; every change is rolled back.';
GO

/* ============================================================================
   Document numbering without gaps (db/static/039_numbering.sql; FR-PLT-026, BR-PLT-010, AC-PLT-3; O-12).
   The cases run as the tenant application (tp_app). Concurrency and the refusal outside a transaction need
   committed data and several connections: tools/ci/numbering_concurrency.sh covers them.

   Run against a deployed BankFas database that holds no real data, with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/numbering_tests.sql
   N1 runs first, one transaction per pattern, because the pattern check is a trigger and its error ends the
   transaction. N2 to N8 run in one transaction with a savepoint each, rolled back at the end.
   Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
/* N1: a pattern needs exactly one {seq} or {seq:000} tag and only the known tags; {erp} needs the company scope; request
   (req:<TypeCode>) and PROFORMA sequences must be gap-free (50031). */
SET NOCOUNT ON;
DECLARE @cases TABLE (n INT, SeqKey VARCHAR(50), Pattern NVARCHAR(100), Scope VARCHAR(7), Gap VARCHAR(10), Ok BIT);
INSERT @cases VALUES (1, 'CHECK', N'{seq:000}-{erp}-{yy}', 'COMPANY', 'GAP_FREE', 1), (2, 'CHECK', N'REQ-{yyyy}-{seq}', 'TENANT', 'GAP_FREE', 1),
                     (3, 'CHECK', N'P-{seq:00}-{seq}', 'TENANT', 'GAP_FREE', 0), (4, 'CHECK', N'X-{foo}-{seq}', 'TENANT', 'GAP_FREE', 0),
                     (5, 'CHECK', N'{erp}-{seq}', 'TENANT', 'GAP_FREE', 0), (6, 'CHECK', N'NO-SEQ-{yy}', 'TENANT', 'GAP_FREE', 0),
                     (7, 'CHECK', N'{seq:0a0}', 'TENANT', 'GAP_FREE', 0), (8, 'CHECK', N'{seq:000', 'TENANT', 'GAP_FREE', 0),
                     (9, 'req:LCP', N'LCP-{yy}-{seq:0000}', 'TENANT', 'ALLOW_GAPS', 0), (10, 'PROFORMA', N'{seq:000}-{erp}-{yy}', 'COMPANY', 'ALLOW_GAPS', 0),
                     (11, 'req:LCP', N'LCP-{yy}-{seq:0000}', 'TENANT', 'GAP_FREE', 1), (12, 'CHECK', N'G-{seq}', 'TENANT', 'ALLOW_GAPS', 1);
DECLARE @n INT = 1, @k VARCHAR(50), @p NVARCHAR(100), @sc VARCHAR(7), @gp VARCHAR(10), @ok BIT, @e INT, @good INT = 0, @tk UNIQUEIDENTIFIER, @t INT;
WHILE @n <= 12
BEGIN
    SELECT @k = SeqKey, @p = Pattern, @sc = Scope, @gp = Gap, @ok = Ok, @e = NULL FROM @cases WHERE n = @n;
    BEGIN TRANSACTION;
    ALTER TABLE plat.Tenant NOCHECK CONSTRAINT FK_Tenant_HomeCountryId;
    INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('tst-pattern', N'P', N'P', 1, 1, 'ACTIVE', 'UTC');
    SELECT @t = SCOPE_IDENTITY(), @tk = NEWID();
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (@@SPID, @t, 0, @tk);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @t;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @tk;
    BEGIN TRY
        INSERT cfg.NumberSequenceDefinition (TenantId, SequenceKey, Pattern, ScopeLevel, PeriodBasis, GapPolicy)
        VALUES (@t, @k, @p, @sc, CASE WHEN @sc = 'COMPANY' THEN 'CALENDAR_YEAR' ELSE 'NONE' END, @gp);
    END TRY
    BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    IF (@ok = 1 AND @e IS NULL) OR (@ok = 0 AND @e = 50031) SET @good = @good + 1;
    ELSE PRINT CONCAT('INFO N1 case ', @n, ' (', @p, '): error ', ISNULL(CAST(@e AS VARCHAR(10)), 'none'));
    SET @n = @n + 1;
END;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;
IF @good = 12 PRINT 'PASS N1: numbering patterns are checked (one {seq} tag, known tags only, {erp} at company scope), and request and proforma sequences are gap-free';
ELSE PRINT CONCAT('FAIL N1: definition check (', @good, ' of 12)');
GO
SET NOCOUNT ON;
BEGIN TRANSACTION;
CREATE USER [tp_test_app] WITHOUT LOGIN;
ALTER ROLE [tp_app] ADD MEMBER [tp_test_app];
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT FK_Tenant_HomeCountryId;
ALTER TABLE org.Company NOCHECK CONSTRAINT ALL;       -- party, legal form and country rows are not seeded
GO
CREATE PROCEDURE #Bind @TenantId INT, @UserId BIGINT = 0
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    MERGE sec.SessionBinding AS b
    USING (SELECT @@SPID AS SessionId) AS s ON b.SessionId = s.SessionId
    WHEN MATCHED THEN UPDATE SET BoundTenantId = @TenantId, BoundUserId = @UserId, BindingToken = @token, BoundAt = SYSUTCDATETIME(),
                                 BindingKind = 'USER', BoundOperatorId = NULL
    WHEN NOT MATCHED THEN INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (s.SessionId, @TenantId, @UserId, @token);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @UserId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
END;
GO

DECLARE @tA INT, @tB INT, @c1 BIGINT, @c2 BIGINT, @u BIGINT;
DECLARE @n1 NVARCHAR(60), @n2 NVARCHAR(60), @n3 NVARCHAR(60), @n4 NVARCHAR(60), @n5 NVARCHAR(60), @n6 NVARCHAR(60),
        @id4 BIGINT, @id BIGINT, @e1 INT, @e2 INT, @e3 INT, @e4 INT, @e5 INT, @cnt INT, @x INT;
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone)
VALUES ('tst-num-a', N'A', N'A', 1, 1, 'ACTIVE', 'UTC'), ('tst-num-b', N'B', N'B', 1, 1, 'ACTIVE', 'UTC');
SELECT @tA = TenantId FROM plat.Tenant WHERE Code = 'tst-num-a';
SELECT @tB = TenantId FROM plat.Tenant WHERE Code = 'tst-num-b';
EXEC #Bind @tB;
INSERT cfg.NumberSequenceDefinition (TenantId, SequenceKey, Pattern, ScopeLevel, PeriodBasis) VALUES (@tB, 'ONLYB', N'B-{seq}', 'TENANT', 'NONE');
EXEC #Bind @tA;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash)
VALUES (@tA, N'ta@num.invalid', N'TA', 'ACTIVE', '$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA');
SELECT @u = AppUserId FROM sec.AppUser WHERE TenantId = @tA;
EXEC #Bind @tA, @u;
-- ErpCodeNormalized is computed from ErpCompanyCode (DR-47): ' xx01 ' gives XX01.
INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, ErpCompanyCode, FiscalYearEndMonth)
VALUES (@tA, 'C1', N'ش1', N'C1', 1, 1, 1, ' xx01 ', 12), (@tA, 'C2', N'ش2', N'C2', 2, 1, 1, 'XX02', 3);
SELECT @c1 = CompanyId FROM org.Company WHERE TenantId = @tA AND CompanyCode = 'C1';
SELECT @c2 = CompanyId FROM org.Company WHERE TenantId = @tA AND CompanyCode = 'C2';
INSERT cfg.NumberSequenceDefinition (TenantId, SequenceKey, Pattern, ScopeLevel, PeriodBasis, GapPolicy)
VALUES (@tA, 'PROFORMA', N'{seq:000}-{erp}-{yy}', 'COMPANY', 'CALENDAR_YEAR', 'GAP_FREE'),
       (@tA, 'REQUEST', N'REQ-{yyyy}-{seq:0000}', 'TENANT', 'CALENDAR_YEAR', 'GAP_FREE'),
       (@tA, 'NARROW', N'{seq:00}', 'TENANT', 'NONE', 'GAP_FREE'),
       (@tA, 'FYDOC', N'{seq:00}/{yy}', 'COMPANY', 'FISCAL_YEAR', 'GAP_FREE');

/* N2: AC-PLT-3: after two numbers in 2026 the next ones are 003-XX01-26 and 004-XX01-26; a voided number stays VOID
   with its reason and is not issued again, so the next one is 005-XX01-26; the first number of 2027 is 001-XX01-27. */
SAVE TRANSACTION n2;
SELECT @e1 = NULL;
EXECUTE AS USER = N'tp_test_app';
EXEC cfg.usp_AllocateNumber @SequenceKey = 'PROFORMA', @CompanyId = @c1, @OnDate = '2026-03-01';
EXEC cfg.usp_AllocateNumber @SequenceKey = 'PROFORMA', @CompanyId = @c1, @OnDate = '2026-03-02';
EXEC cfg.usp_AllocateNumber @SequenceKey = 'PROFORMA', @CompanyId = @c1, @OnDate = '2026-10-12', @IssuedNumber = @n1 OUTPUT;
EXEC cfg.usp_AllocateNumber @SequenceKey = 'PROFORMA', @CompanyId = @c1, @OnDate = '2026-10-12', @IssuedNumber = @n2 OUTPUT, @NumberIssueId = @id4 OUTPUT;
BEGIN TRY EXEC cfg.usp_VoidNumber @NumberIssueId = @id4, @Reason = N' '; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC cfg.usp_VoidNumber @NumberIssueId = @id4, @Reason = N'Customer cancelled the order';
EXEC cfg.usp_AllocateNumber @SequenceKey = 'PROFORMA', @CompanyId = @c1, @OnDate = '2026-12-31', @IssuedNumber = @n3 OUTPUT;
EXEC cfg.usp_AllocateNumber @SequenceKey = 'PROFORMA', @CompanyId = @c1, @OnDate = '2027-01-01', @IssuedNumber = @n4 OUTPUT;
REVERT;
SELECT @cnt = COUNT(*) FROM cfg.NumberIssue WHERE NumberIssueId = @id4 AND Status = 'VOID' AND VoidReason IS NOT NULL AND VoidedBy = @u;
IF @n1 = N'003-XX01-26' AND @n2 = N'004-XX01-26' AND @n3 = N'005-XX01-26' AND @n4 = N'001-XX01-27' AND @e1 = 50032 AND @cnt = 1
    PRINT 'PASS N2: AC-PLT-3: consecutive numbers per company and year, a voided number is never reused, a new year starts at 001';
ELSE PRINT 'FAIL N2: AC-PLT-3 (' + CONCAT(@n1, ' ', @n2, ' ', @n3, ' ', @n4, ' ', @e1, ' ', @cnt) + ')';
ROLLBACK TRANSACTION n2;

/* N3: a rollback of the caller's transaction takes the number back: the next allocation gets the same number. */
SAVE TRANSACTION n3;
SELECT @n1 = NULL, @n2 = NULL, @n3 = NULL;
EXECUTE AS USER = N'tp_test_app';
EXEC cfg.usp_AllocateNumber @SequenceKey = 'REQUEST', @OnDate = '2026-10-12', @IssuedNumber = @n1 OUTPUT;
SAVE TRANSACTION business_row;
EXEC cfg.usp_AllocateNumber @SequenceKey = 'REQUEST', @OnDate = '2026-10-12', @IssuedNumber = @n2 OUTPUT;
ROLLBACK TRANSACTION business_row;                    -- the business insert failed
EXEC cfg.usp_AllocateNumber @SequenceKey = 'REQUEST', @OnDate = '2026-10-12', @IssuedNumber = @n3 OUTPUT;
REVERT;
SELECT @cnt = COUNT(*) FROM cfg.NumberIssue WHERE TenantId = @tA AND IssuedNumber LIKE N'REQ-2026-%';
IF @n1 = N'REQ-2026-0001' AND @n2 = N'REQ-2026-0002' AND @n3 = N'REQ-2026-0002' AND @cnt = 2
    PRINT 'PASS N3: a rolled-back number is issued again, so no gap appears';
ELSE PRINT 'FAIL N3: rollback (' + CONCAT(@n1, ' ', @n2, ' ', @n3, ' ', @cnt) + ')';
ROLLBACK TRANSACTION n3;

/* N4: a number longer than the pattern's width widens and is never truncated (BR-PLT-010). */
SAVE TRANSACTION n4;
SELECT @n1 = NULL, @n2 = NULL;
INSERT cfg.NumberSequence (TenantId, DefinitionId, PeriodKey, NextValue)
SELECT @tA, NumberSequenceDefinitionId, 'ALL', 99 FROM cfg.NumberSequenceDefinition WHERE TenantId = @tA AND SequenceKey = 'NARROW';
EXECUTE AS USER = N'tp_test_app';
EXEC cfg.usp_AllocateNumber @SequenceKey = 'NARROW', @IssuedNumber = @n1 OUTPUT;
EXEC cfg.usp_AllocateNumber @SequenceKey = 'NARROW', @IssuedNumber = @n2 OUTPUT;
REVERT;
IF @n1 = N'99' AND @n2 = N'100' PRINT 'PASS N4: numbers widen past the pattern width instead of being cut';
ELSE PRINT 'FAIL N4: widening (' + CONCAT(@n1, ' ', @n2) + ')';
ROLLBACK TRANSACTION n4;

/* N5: a fiscal-year sequence follows the company's fiscal year: with a year ending 31 March, 31 March 2026 is in
   FY2026 and 1 April 2026 starts FY2027 at 01. */
SAVE TRANSACTION n5;
SELECT @n1 = NULL, @n2 = NULL, @n3 = NULL;
EXECUTE AS USER = N'tp_test_app';
EXEC cfg.usp_AllocateNumber @SequenceKey = 'FYDOC', @CompanyId = @c2, @OnDate = '2026-03-31', @IssuedNumber = @n1 OUTPUT;
EXEC cfg.usp_AllocateNumber @SequenceKey = 'FYDOC', @CompanyId = @c2, @OnDate = '2026-04-01', @IssuedNumber = @n2 OUTPUT;
EXEC cfg.usp_AllocateNumber @SequenceKey = 'FYDOC', @CompanyId = @c2, @OnDate = '2026-12-31', @IssuedNumber = @n3 OUTPUT;
REVERT;
IF @n1 = N'01/26' AND @n2 = N'01/27' AND @n3 = N'02/27' PRINT 'PASS N5: fiscal-year periods follow the company''s year end';
ELSE PRINT 'FAIL N5: fiscal year (' + CONCAT(@n1, ' ', @n2, ' ', @n3) + ')';
ROLLBACK TRANSACTION n5;

/* N6: a company sequence needs a company of the tenant, and {erp} needs its ERP code (50030). */
SAVE TRANSACTION n6;
SELECT @e1 = NULL, @e2 = NULL;
UPDATE org.Company SET ErpCompanyCode = NULL WHERE CompanyId = @c2;   -- the normalised code follows
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC cfg.usp_AllocateNumber @SequenceKey = 'PROFORMA', @CompanyId = NULL; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC cfg.usp_AllocateNumber @SequenceKey = 'PROFORMA', @CompanyId = @c2; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @e1 = 50030 AND @e2 = 50030 PRINT 'PASS N6: company sequences need a company with an ERP code';
ELSE PRINT 'FAIL N6: company checks (' + CONCAT(@e1, ' ', @e2) + ')';
ROLLBACK TRANSACTION n6;

/* N7: the application cannot set a counter, insert an issued number or change one directly; it may link the
   number to its entity. */
SAVE TRANSACTION n7;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @e4 = NULL, @id = NULL;
EXECUTE AS USER = N'tp_test_app';
EXEC cfg.usp_AllocateNumber @SequenceKey = 'REQUEST', @OnDate = '2026-10-12', @NumberIssueId = @id OUTPUT;
BEGIN TRY UPDATE cfg.NumberSequence SET NextValue = 1; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT cfg.NumberIssue (TenantId, SequenceId, SeqValue, IssuedNumber) SELECT TenantId, SequenceId, 99, N'X' FROM cfg.NumberIssue WHERE NumberIssueId = @id; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE cfg.NumberIssue SET IssuedNumber = N'REQ-2026-0009' WHERE NumberIssueId = @id; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE cfg.NumberIssue SET EntityType = 'wfl.Request', EntityId = 42 WHERE NumberIssueId = @id; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @e1 = 229 AND @e2 = 229 AND @e3 = 230 AND @e4 IS NULL PRINT 'PASS N7: counters and issued numbers change only through the procedures';
ELSE PRINT 'FAIL N7: direct rights (' + CONCAT(@e1, ' ', @e2, ' ', @e3, ' ', @e4) + ')';
ROLLBACK TRANSACTION n7;

/* N8: a connection numbers with its own tenant's definitions only: another tenant's key is unknown (50030). */
SAVE TRANSACTION n8;
SELECT @e1 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC cfg.usp_AllocateNumber @SequenceKey = 'ONLYB'; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @e1 = 50030 PRINT 'PASS N8: another tenant''s sequences are out of reach';
ELSE PRINT 'FAIL N8: tenant isolation (' + CONCAT(@e1, '') + ')';
ROLLBACK TRANSACTION n8;

ROLLBACK TRANSACTION;
GO
PRINT 'Numbering tests finished; every change is rolled back.';
GO

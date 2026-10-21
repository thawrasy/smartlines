/* ============================================================================
   The financial statements module of M5 (db/static/045_financial_statements.sql; owner request of 2026-10-18;
   docs/adr/0016-financial-statements-module.md; spec 12 FR-FIN-015 to FR-FIN-019, BR-FIN-012 to BR-FIN-017).
   FS1  only a holding enters consolidated statements; any company enters standalone ones (BR-FIN-013)
   FS2  a consolidated statement is submitted with its holding as the PARENT unit and its other units (BR-FIN-013)
   FS3  a statement is written as a draft, changes only as a draft, moves through its states, and is approved by
        someone other than its preparer; an audited one names its auditor and opinion (FR-FIN-005/006, BR-FIN-012)
   FS4  the statements an automatic evaluation read are written by the database, never by the application (FR-FIN-017)
   FS5  the breach report lists the latest evaluation's breach or early warning with its statement, covenant, facility
        and bank (FR-FIN-017, R-FIN-05)
   FS6  liquidity routed to the bank: a kind of the FLOW_KIND list, one level per month, confirmed by someone else
        (BR-FIN-016, self-review B7f)
   FS7  the flow performance of a covenant: window, confirmed flows to the facility's bank, remaining, rate, state
        (FR-FIN-018, BR-FIN-007)
   FS8  a share-of-revenue covenant reads the revenue of the approved annual statement or the approved estimate
        (BR-FIN-008, Q-FIN-05)
   FS9  analysis measures: one per statement and formula, a DAYS formula is for analysis only, and a measure that
        could not be computed says why (FR-FIN-016, BR-FIN-014)
   FS10 one approved revenue estimate per company, year and basis, approved by someone else (Q-FIN-05)
   FS11 the units of a consolidated statement, with their own statements and the ownership on record (FR-FIN-015)

   Run against a deployed BankFas database that holds no real data, with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/financial_statements_tests.sql
   Every case runs in its own transaction and rolls it back. Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
IF USER_ID(N'tp_test_finapp') IS NULL
BEGIN
    CREATE USER [tp_test_finapp] WITHOUT LOGIN;
    ALTER ROLE [tp_app] ADD MEMBER [tp_test_finapp];
END;
GO
CREATE TABLE #F (k VARCHAR(20) PRIMARY KEY, v BIGINT NOT NULL);
GO
CREATE PROCEDURE #Bind @TenantId INT, @UserId BIGINT
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind)
    VALUES (@@SPID, @TenantId, @UserId, @token, 'USER');
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @UserId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
END;
GO
/* The fixture, inside the caller's transaction: a tenant with a preparer and an approver; a holding HOLD with its
   subsidiary SUB (80 percent on record) and a company OTHER; the catalogue lines REVENUE, TOTAL_CA and TOTAL_CL;
   the FLOW_KIND list with TRANSFERRED_TO_BANK and another list; a facility of HOLD with bank 1 at 100 percent, its
   limit, and revision 1 approved with two covenants: flows to the bank of at least 12,000,000 SAR a fiscal year
   ('cfl') and a current ratio of at least 1.2 on the statements ('crt'); the holding's approved standalone statement
   for 2025 ('fs') and the scheduled test of the ratio covenant for 2025 ('ct'). Institution references and the
   catalogue types are switched off for these rows. #F holds the ids. */
CREATE PROCEDURE #Fin
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM #F;
    DECLARE @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'), @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA'),
            @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR'), @pw VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA',
            @t INT, @u1 BIGINT, @u2 BIGINT, @ph BIGINT, @ps BIGINT, @po BIGINT, @hold BIGINT, @sub BIGINT, @oth BIGINT,
            @lst INT, @lst2 INT, @kind INT, @kind2 INT, @rev INT, @ca INT, @cl INT, @f BIGINT, @l BIGINT, @ot INT, @ob BIGINT,
            @fr BIGINT, @cfl BIGINT, @crt BIGINT, @fs BIGINT, @ct BIGINT;
    INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('tst-fin', N'م', N'Fin', @plan, @country, 'ACTIVE', 'UTC');
    SET @t = SCOPE_IDENTITY();
    EXEC #Bind @t, 0;
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t, N'fo@fin.invalid', N'Preparer', 'ACTIVE', @pw);
    SET @u1 = SCOPE_IDENTITY();
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t, N'tm@fin.invalid', N'Approver', 'ACTIVE', @pw);
    SET @u2 = SCOPE_IDENTITY();
    EXEC #Bind @t, @u1;
    ALTER TABLE org.Company NOCHECK CONSTRAINT FK_Company_LegalEntityTypeId;
    ALTER TABLE fac.Facility NOCHECK CONSTRAINT FK_Facility_FacilityTypeId;
    ALTER TABLE fac.FacilityLender NOCHECK CONSTRAINT FK_FacilityLender_InstitutionId;
    ALTER TABLE fac.Limit NOCHECK CONSTRAINT FK_Limit_LimitTypeId;
    ALTER TABLE fin.BankFlowEntry NOCHECK CONSTRAINT FK_BankFlowEntry_InstitutionId;
    INSERT pty.Party (TenantId, PartyCode, Kind, NameEn) VALUES (@t, 'P-HOLD', 'ORGANIZATION', N'Holding'), (@t, 'P-SUB', 'ORGANIZATION', N'Subsidiary'),
                                                              (@t, 'P-OTH', 'ORGANIZATION', N'Other');
    SELECT @ph = PartyId FROM pty.Party WHERE TenantId = @t AND PartyCode = 'P-HOLD';
    SELECT @ps = PartyId FROM pty.Party WHERE TenantId = @t AND PartyCode = 'P-SUB';
    SELECT @po = PartyId FROM pty.Party WHERE TenantId = @t AND PartyCode = 'P-OTH';
    INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth, IsHolding)
    VALUES (@t, 'HOLD', N'قابضة', N'Holding', @ph, 1, @country, 12, 1), (@t, 'SUB', N'تابعة', N'Subsidiary', @ps, 1, @country, 12, 0),
           (@t, 'OTH', N'أخرى', N'Other', @po, 1, @country, 12, 0);
    SELECT @hold = CompanyId FROM org.Company WHERE TenantId = @t AND CompanyCode = 'HOLD';
    SELECT @sub = CompanyId FROM org.Company WHERE TenantId = @t AND CompanyCode = 'SUB';
    SELECT @oth = CompanyId FROM org.Company WHERE TenantId = @t AND CompanyCode = 'OTH';
    INSERT org.Shareholding (TenantId, CompanyId, HolderPartyId, SharePercent, Layer, EffectiveFrom) VALUES (@t, @sub, @ph, 80, 1, '2020-01-01');
    INSERT fin.LineCatalogItem (TenantId, Code, NameAr, NameEn, Section) VALUES (@t, 'REVENUE', N'الإيرادات', N'Revenue', 'IS'),
           (@t, 'TOTAL_CA', N'الأصول المتداولة', N'Current assets', 'BS_ASSET'), (@t, 'TOTAL_CL', N'الخصوم المتداولة', N'Current liabilities', 'BS_LIABILITY');
    SELECT @rev = LineCatalogItemId FROM fin.LineCatalogItem WHERE TenantId = @t AND Code = 'REVENUE';
    SELECT @ca = LineCatalogItemId FROM fin.LineCatalogItem WHERE TenantId = @t AND Code = 'TOTAL_CA';
    SELECT @cl = LineCatalogItemId FROM fin.LineCatalogItem WHERE TenantId = @t AND Code = 'TOTAL_CL';
    INSERT cat.LookupList (TenantId, Code, NameAr, NameEn, Scope) VALUES (@t, 'FLOW_KIND', N'أنواع التحويل', N'Flow kinds', 'TENANT'),
                                                                        (@t, 'SUBMISSION_CHANNEL', N'قنوات التقديم', N'Submission channels', 'TENANT');
    SELECT @lst = LookupListId FROM cat.LookupList WHERE TenantId = @t AND Code = 'FLOW_KIND';
    SELECT @lst2 = LookupListId FROM cat.LookupList WHERE TenantId = @t AND Code = 'SUBMISSION_CHANNEL';
    INSERT cat.LookupItem (TenantId, LookupListId, Code, NameAr) VALUES (@t, @lst, 'TRANSFERRED_TO_BANK', N'محوَّل للبنك'), (@t, @lst2, 'PORTAL', N'منصة');
    SELECT @kind = LookupItemId FROM cat.LookupItem WHERE TenantId = @t AND LookupListId = @lst;
    SELECT @kind2 = LookupItemId FROM cat.LookupItem WHERE TenantId = @t AND LookupListId = @lst2;
    INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
    VALUES (@t, 'FAC-26-101', @hold, 1, @cur, 50000000, 'EN', '2026-01-01', '2027-12-31');
    SET @f = SCOPE_IDENTITY();
    INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (@t, @f, 1, 'LEAD', 100, 1);
    INSERT fac.Limit (TenantId, FacilityId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, FromRevision, NoSourceReason)
    VALUES (@t, @f, 1, 'L1', N'حد', 'ABSOLUTE', 50000000, 1, 1, N'test fixture');
    SET @l = SCOPE_IDENTITY();
    INSERT cat.ObligationType (TenantId, Code, NameAr, Family, MeasureKind) VALUES (@t, 'COV', N'تعهد', 'COVENANT', 'RATIO');
    SET @ot = SCOPE_IDENTITY();
    INSERT obl.Obligation (TenantId, FacilityId, Family, ObligationTypeId, TitleAr, ClauseRef, ValidFrom, NoSourceReason)
    VALUES (@t, @f, 'COVENANT', @ot, N'تعهدات مالية', N'14.2', '2026-01-01', N'test fixture');
    SET @ob = SCOPE_IDENTITY();
    INSERT fin.MeasureFormula (TenantId, Code, NameAr, Scope, FacilityId, Expression, InputKinds, ResultUnit, VersionNo, Status, ApprovedBy, ApprovedOn, NoSourceReason)
    VALUES (@t, 'CURRENT_RATIO', N'نسبة التداول', 'FACILITY_COPY', @f, 'TOTAL_CA / TOTAL_CL', 'STATEMENT', 'RATIO', 1, 'APPROVED', @u2, SYSUTCDATETIME(), N'test fixture');
    SET @fr = SCOPE_IDENTITY();
    INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, Operator, ThresholdState, ThresholdValue, ThresholdUnit, CurrencyId, TestFrequency,
                         AnnualWindowBasis, TestedCompanyId, FirstTestPeriodEnd, ValidFrom)
    VALUES (@t, @ob, 'FLOW_VOLUME', 'GE', 'SET', 12000000, 'AMOUNT', @cur, 'ANNUAL', 'FISCAL_YEAR', @hold, '2026-12-31', '2026-01-01');
    SET @cfl = SCOPE_IDENTITY();
    INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, FormulaId, FormulaResultUnit, FormulaUsesStatements, Operator, ThresholdState, ThresholdValue,
                         ThresholdUnit, TestFrequency, StatementBasis, RequiredAssurance, TestedCompanyId, FirstTestPeriodEnd, ValidFrom)
    VALUES (@t, @ob, 'RATIO', @fr, 'RATIO', 1, 'GE', 'SET', 1.2, 'RATIO', 'ANNUAL', 'STANDALONE', 'ANY', @hold, '2025-12-31', '2025-06-01');
    SET @crt = SCOPE_IDENTITY();
    INSERT fac.FacilityRevision (TenantId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn, SubmittedBy, SubmittedOn, ApprovedBy, ApprovedOn)
    VALUES (@t, @f, 1, 'INITIAL', 'APPROVED', '2026-01-01', @u1, SYSUTCDATETIME(), @u2, SYSUTCDATETIME());
    UPDATE fac.Facility SET ApprovedRevisionNo = 1 WHERE FacilityId = @f;
    INSERT fin.FinancialStatement (TenantId, CompanyId, PeriodType, PeriodEnd, FiscalYear, Basis, Assurance, CurrencyId, EntryMethod, PreparedBy, PreparedOn)
    VALUES (@t, @hold, 'ANNUAL', '2025-12-31', 2025, 'STANDALONE', 'MANAGEMENT', @cur, 'MANUAL', @u1, SYSUTCDATETIME());
    SET @fs = SCOPE_IDENTITY();
    INSERT fin.StatementLine (TenantId, StatementId, LineCatalogItemId, EnteredAmount) VALUES (@t, @fs, @ca, 11000000), (@t, @fs, @cl, 10000000), (@t, @fs, @rev, 50000000);
    UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @fs;
    UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @fs;
    INSERT obl.CovenantTest (TenantId, CovenantId, CovenantRootId, PeriodStart, PeriodEnd, DueDate, Method)
    VALUES (@t, @crt, (SELECT RootId FROM obl.Covenant WHERE CovenantId = @crt), '2025-01-01', '2025-12-31', '2026-03-31', 'AUTO');
    SET @ct = SCOPE_IDENTITY();
    INSERT #F (k, v) VALUES ('t', @t), ('u1', @u1), ('u2', @u2), ('hold', @hold), ('sub', @sub), ('oth', @oth), ('cur', @cur), ('lst', @lst),
                            ('lst2', @lst2), ('kind', @kind), ('kind2', @kind2), ('rev', @rev), ('ca', @ca), ('cl', @cl), ('f', @f), ('l', @l),
                            ('ob', @ob), ('fr', @fr), ('cfl', @cfl), ('crt', @crt), ('fs', @fs), ('ct', @ct);
END;
GO
-- Runs cases @From to @To of a case procedure, each in its own transaction on a new fixture, and returns case:error.
CREATE PROCEDURE #Cases @CaseProc SYSNAME, @From INT, @To INT, @Result NVARCHAR(800) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (CaseNo INT PRIMARY KEY, Err INT NOT NULL);
    DECLARE @i INT = @From, @e INT;
    WHILE @i <= @To
    BEGIN
        BEGIN TRANSACTION;
        BEGIN TRY EXEC #Fin; EXEC @CaseProc @i; SET @e = 0; END TRY
        BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
        WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        INSERT @r (CaseNo, Err) VALUES (@i, @e);
        SET @i += 1;
    END;
    SET @Result = (SELECT STRING_AGG(CONCAT(CaseNo, ':', Err), ' ') WITHIN GROUP (ORDER BY CaseNo) FROM @r);
END;
GO
-- A new draft statement of a company for 2026 ('s' in #F).
CREATE PROCEDURE #NewStatement @Company BIGINT, @Basis VARCHAR(20), @Assurance VARCHAR(20) = 'MANAGEMENT', @PeriodEnd DATE = '2026-12-31'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT, @u1 BIGINT, @cur INT, @s BIGINT;
    SELECT @t = v FROM #F WHERE k = 't'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @cur = v FROM #F WHERE k = 'cur';
    INSERT fin.FinancialStatement (TenantId, CompanyId, PeriodType, PeriodEnd, FiscalYear, Basis, Assurance, CurrencyId, EntryMethod, PreparedBy, PreparedOn)
    VALUES (@t, @Company, 'ANNUAL', @PeriodEnd, YEAR(@PeriodEnd), @Basis, @Assurance, @cur, 'MANUAL', @u1, SYSUTCDATETIME());
    SET @s = SCOPE_IDENTITY();
    DELETE FROM #F WHERE k = 's';
    INSERT #F (k, v) VALUES ('s', @s);
END;
GO
/* FS1-FS3 cases. */
CREATE PROCEDURE #StatementCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT, @u1 BIGINT, @u2 BIGINT, @hold BIGINT, @sub BIGINT, @oth BIGINT, @cur INT, @ca INT, @s BIGINT, @basis VARCHAR(20), @assurance VARCHAR(20);
    SELECT @t = v FROM #F WHERE k = 't'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @u2 = v FROM #F WHERE k = 'u2';
    SELECT @hold = v FROM #F WHERE k = 'hold'; SELECT @sub = v FROM #F WHERE k = 'sub'; SELECT @oth = v FROM #F WHERE k = 'oth';
    SELECT @cur = v FROM #F WHERE k = 'cur'; SELECT @ca = v FROM #F WHERE k = 'ca';
    -- FS1
    IF @Case = 1 EXEC #NewStatement @sub, 'CONSOLIDATED';
    IF @Case = 2 EXEC #NewStatement @hold, 'CONSOLIDATED';
    IF @Case = 3 EXEC #NewStatement @sub, 'STANDALONE';
    -- FS2
    IF @Case BETWEEN 10 AND 16
    BEGIN
        SET @basis = CASE WHEN @Case = 10 THEN 'STANDALONE' ELSE 'CONSOLIDATED' END;
        EXEC #NewStatement @hold, @basis;
        SELECT @s = v FROM #F WHERE k = 's';
        IF @Case = 10 INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method, OwnershipPct) VALUES (@t, @s, @sub, 'SUBSIDIARY', 'FULL', 80);
        IF @Case = 11 INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method) VALUES (@t, @s, @sub, 'PARENT', 'FULL');
        IF @Case = 12 INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method, OwnershipPct) VALUES (@t, @s, @hold, 'SUBSIDIARY', 'FULL', 100);
        IF @Case IN (14, 15, 16) INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method) VALUES (@t, @s, @hold, 'PARENT', 'FULL');
        IF @Case = 15 INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method, OwnershipPct) VALUES (@t, @s, @sub, 'SUBSIDIARY', 'FULL', 80);
        IF @Case = 16 INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method) VALUES (@t, @s, @hold, 'PARENT', 'FULL');
        IF @Case IN (13, 14, 15) UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @s;
    END;
    -- FS3
    IF @Case = 20 INSERT fin.FinancialStatement (TenantId, CompanyId, PeriodType, PeriodEnd, FiscalYear, Basis, Assurance, CurrencyId, EntryMethod, Status, PreparedBy, PreparedOn)
                  VALUES (@t, @oth, 'ANNUAL', '2026-12-31', 2026, 'STANDALONE', 'MANAGEMENT', @cur, 'MANUAL', 'SUBMITTED', @u1, SYSUTCDATETIME());
    IF @Case BETWEEN 21 AND 29
    BEGIN
        SET @assurance = CASE WHEN @Case = 29 THEN 'AUDITED' ELSE 'MANAGEMENT' END;
        EXEC #NewStatement @oth, 'STANDALONE', @assurance;
        SELECT @s = v FROM #F WHERE k = 's';
        INSERT fin.StatementLine (TenantId, StatementId, LineCatalogItemId, EnteredAmount) VALUES (@t, @s, @ca, 1000);
        IF @Case = 21 UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @s;
        IF @Case BETWEEN 22 AND 28 UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @s;
        IF @Case = 22 UPDATE fin.FinancialStatement SET UnitScale = 1000 WHERE FinancialStatementId = @s;
        IF @Case = 23 UPDATE fin.StatementLine SET EnteredAmount = 2000 WHERE StatementId = @s;
        IF @Case = 24 UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @u1, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @s;
        IF @Case IN (25, 26) UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @s;
        IF @Case = 26 UPDATE fin.FinancialStatement SET Status = 'DRAFT' WHERE FinancialStatementId = @s;
        IF @Case IN (27, 28)
        BEGIN
            UPDATE fin.FinancialStatement SET Status = 'REJECTED' WHERE FinancialStatementId = @s;
            UPDATE fin.FinancialStatement SET Status = 'DRAFT' WHERE FinancialStatementId = @s;
            UPDATE fin.StatementLine SET EnteredAmount = 2000 WHERE StatementId = @s;
        END;
        IF @Case = 28 UPDATE fin.FinancialStatement SET UnitScale = 1000, Status = 'SUBMITTED' WHERE FinancialStatementId = @s;
        IF @Case = 29 UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @s;
    END;
END;
GO
/* FS1 (BR-FIN-013): a consolidated statement of a company that is not a holding is refused (50061); the holding's
   consolidated statement and anyone's standalone one are accepted. */
DECLARE @got NVARCHAR(800);
EXEC #Cases '#StatementCase', 1, 3, @got OUTPUT;
IF @got = '1:50061 2:0 3:0'
    PRINT 'PASS FS1: only a holding enters consolidated statements, and any company enters standalone ones';
ELSE PRINT CONCAT('FAIL FS1: case:error ', @got, ' (expected 1:50061 2:0 3:0)');
GO
/* FS2 (BR-FIN-013): units belong to a consolidated statement only (547); the PARENT unit is the holding itself and the
   holding is no other unit (50061); a consolidated statement is submitted with its PARENT unit and another unit
   (50061 without units or with the PARENT alone); a company is one unit of a statement (2627). */
DECLARE @got NVARCHAR(800);
EXEC #Cases '#StatementCase', 10, 16, @got OUTPUT;
IF @got = '10:547 11:50061 12:50061 13:50061 14:50061 15:0 16:2627'
    PRINT 'PASS FS2: a consolidated statement is submitted with its holding as the PARENT unit and the units it consolidates';
ELSE PRINT CONCAT('FAIL FS2: case:error ', @got, ' (expected 10:547 11-14:50061 15:0 16:2627)');
GO
/* FS3 (FR-FIN-005/006, BR-FIN-012): a statement is not inserted already submitted and does not skip SUBMITTED
   (50060); once submitted its header and lines do not change (50060); it is approved by someone other than its
   preparer (547), an approved one goes back to no draft (50060), a rejected one goes back to draft and changes again;
   an audited statement is submitted with its auditor and opinion (547). */
DECLARE @got NVARCHAR(800);
EXEC #Cases '#StatementCase', 20, 29, @got OUTPUT;
IF @got = '20:50060 21:50060 22:50060 23:50060 24:547 25:0 26:50060 27:0 28:0 29:547'
    PRINT 'PASS FS3: a statement changes only as a draft, moves through its states, is approved by another user, and an audited one names its auditor';
ELSE PRINT CONCAT('FAIL FS3: case:error ', @got, ' (expected 20-23:50060 24:547 25:0 26:50060 27:0 28:0 29:547)');
GO
/* The ratio covenant's test for 2025 is evaluated on the holding's approved statement: 'BREACH' when the ratio is
   below 1.2, 'WARNING' or 'COMPLIANT' as the case says, with the snapshot of BR-FIN-010. */
CREATE PROCEDURE #Evaluate @Result VARCHAR(30), @Actual DECIMAL(19,6), @Test BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @fs BIGINT, @fr BIGINT, @ct BIGINT;
    SELECT @fs = v FROM #F WHERE k = 'fs'; SELECT @fr = v FROM #F WHERE k = 'fr'; SELECT @ct = ISNULL(@Test, v) FROM #F WHERE k = 'ct';
    UPDATE obl.CovenantTest
    SET State = 'EVALUATED', Result = @Result, ActualValue = @Actual, ThresholdApplied = 1.2, OperatorApplied = 'GE', Headroom = @Actual - 1.2,
        FormulaId = @fr, EvaluatedAt = SYSUTCDATETIME(),
        InputsSnapshot = CONCAT(N'{"formula":{"id":', @fr, N',"version":1},"threshold":{"value":1.2,"operator":"GE"},"statements":[{"statementId":', @fs,
                                N',"version":1,"basis":"STANDALONE"}]}')
    WHERE CovenantTestId = @ct;
END;
GO
/* FS4 (FR-FIN-017): evaluating the test writes its statement link, with the version and basis it read; the
   application cannot write a link (229). */
DECLARE @t INT, @u1 BIGINT, @fs BIGINT, @ct BIGINT, @n INT = -1, @e1 INT;
BEGIN TRANSACTION;
EXEC #Fin;
SELECT @t = v FROM #F WHERE k = 't'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @fs = v FROM #F WHERE k = 'fs'; SELECT @ct = v FROM #F WHERE k = 'ct';
EXEC #Evaluate 'BREACH', 1.1;
SELECT @n = COUNT(*) FROM obl.CovenantTestStatement WHERE CovenantTestId = @ct AND StatementId = @fs AND StatementVersionNo = 1 AND Basis = 'STANDALONE';
EXECUTE AS USER = N'tp_test_finapp';
BEGIN TRY INSERT obl.CovenantTestStatement (TenantId, CovenantTestId, StatementId, StatementVersionNo, Basis) VALUES (@t, @ct, @fs, 2, 'STANDALONE'); END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @n = 1 AND @e1 = 229
    PRINT 'PASS FS4: the statements an automatic evaluation read are written by the database, and the application cannot write them';
ELSE PRINT CONCAT('FAIL FS4: links ', @n, ' (expected 1), application insert ', @e1, ' (expected 229)');
GO
/* FS5 (FR-FIN-017, R-FIN-05): a breach found on the holding's statement is listed with that statement, the covenant's
   clause, the facility and its bank; a second evaluation of the period that complies takes it off the report (the
   latest evaluation counts); an early warning is listed as one. */
DECLARE @t INT, @fs BIGINT, @ct BIGINT, @crt BIGINT, @f BIGINT, @ct2 BIGINT, @a INT = -1, @b INT = -1, @c INT = -1, @sev VARCHAR(20);
BEGIN TRANSACTION;
EXEC #Fin;
SELECT @t = v FROM #F WHERE k = 't'; SELECT @fs = v FROM #F WHERE k = 'fs'; SELECT @ct = v FROM #F WHERE k = 'ct';
SELECT @crt = v FROM #F WHERE k = 'crt'; SELECT @f = v FROM #F WHERE k = 'f';
EXEC #Evaluate 'BREACH', 1.1;
SELECT @a = COUNT(*) FROM fin.v_StatementBreachReport
WHERE CovenantTestId = @ct AND StatementId = @fs AND FacilityId = @f AND BankInstitutionId = 1 AND ClauseRef = N'14.2' AND Severity = 'BREACH'
  AND FormulaCode = 'CURRENT_RATIO' AND StatementSuperseded = 0;
INSERT obl.CovenantTest (TenantId, CovenantId, CovenantRootId, PeriodStart, PeriodEnd, DueDate, Method, EvaluationNo)
VALUES (@t, @crt, (SELECT RootId FROM obl.Covenant WHERE CovenantId = @crt), '2025-01-01', '2025-12-31', '2026-03-31', 'AUTO', 2);
SET @ct2 = SCOPE_IDENTITY();
EXEC #Evaluate 'COMPLIANT', 1.3, @ct2;
SELECT @b = COUNT(*) FROM fin.v_StatementBreachReport WHERE CovenantRootId = (SELECT RootId FROM obl.Covenant WHERE CovenantId = @crt);
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
BEGIN TRANSACTION;
EXEC #Fin;
SELECT @ct = v FROM #F WHERE k = 'ct';
EXEC #Evaluate 'WARNING', 1.25;
SELECT @c = COUNT(*), @sev = MAX(Severity) FROM fin.v_StatementBreachReport WHERE CovenantTestId = (SELECT v FROM #F WHERE k = 'ct');
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @a = 1 AND @b = 0 AND @c = 1 AND @sev = 'EARLY_WARNING'
    PRINT 'PASS FS5: the breach report lists the latest evaluation''s breach or warning with its statement, clause, facility and bank';
ELSE PRINT CONCAT('FAIL FS5: breach listed ', @a, ', after a compliant re-evaluation ', @b, ', warning ', @c, ' ', @sev);
GO
/* FS6 and FS7 cases: flows of the holding to bank 1 (the facility's) for 2026. */
CREATE PROCEDURE #FlowCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT, @u1 BIGINT, @u2 BIGINT, @hold BIGINT, @cur INT, @lst INT, @lst2 INT, @kind INT, @kind2 INT, @f BIGINT;
    SELECT @t = v FROM #F WHERE k = 't'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @u2 = v FROM #F WHERE k = 'u2';
    SELECT @hold = v FROM #F WHERE k = 'hold'; SELECT @cur = v FROM #F WHERE k = 'cur'; SELECT @lst = v FROM #F WHERE k = 'lst';
    SELECT @lst2 = v FROM #F WHERE k = 'lst2'; SELECT @kind = v FROM #F WHERE k = 'kind'; SELECT @kind2 = v FROM #F WHERE k = 'kind2'; SELECT @f = v FROM #F WHERE k = 'f';
    IF @Case = 1 INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy)
                 VALUES (@t, @hold, 1, '2026-01-31', @lst2, @kind2, 1000000, @cur, @u1);
    IF @Case = 2 INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy)
                 VALUES (@t, @hold, 1, '2026-01-31', @lst, @kind2, 1000000, @cur, @u1);
    IF @Case = 3
    BEGIN
        INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy)
        VALUES (@t, @hold, 1, '2026-01-31', @lst, @kind, 1000000, @cur, @u1);
        INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, FacilityId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy)
        VALUES (@t, @hold, 1, @f, '2026-01-31', @lst, @kind, 500000, @cur, @u1);
    END;
    IF @Case = 4 INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy, Status)
                 VALUES (@t, @hold, 1, '2026-01-31', @lst, @kind, 1000000, @cur, @u1, 'CONFIRMED');
    IF @Case = 5 INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy, Status, ConfirmedBy, ConfirmedOn)
                 VALUES (@t, @hold, 1, '2026-01-31', @lst, @kind, 1000000, @cur, @u1, 'CONFIRMED', @u1, SYSUTCDATETIME());
    IF @Case = 6 INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy, Status, ConfirmedBy, ConfirmedOn)
                 VALUES (@t, @hold, 1, '2026-01-31', @lst, @kind, 1000000, @cur, @u1, 'CONFIRMED', @u2, SYSUTCDATETIME());
END;
GO
/* FS6 (BR-FIN-016, self-review B7f): a flow kind from another list (547, by the list's code) or an item of another
   list under FLOW_KIND (547) is refused; one month's flow to a bank at both levels is refused (50062); a confirmed
   entry names its confirmer (547), who is not the one who entered it (547). */
DECLARE @got NVARCHAR(800);
EXEC #Cases '#FlowCase', 1, 6, @got OUTPUT;
IF @got = '1:547 2:547 3:50062 4:547 5:547 6:0'
    PRINT 'PASS FS6: liquidity routed to the bank is of a FLOW_KIND, entered at one level a month, and confirmed by someone else';
ELSE PRINT CONCAT('FAIL FS6: case:error ', @got, ' (expected 1-2:547 3:50062 4-5:547 6:0)');
GO
/* FS7 (FR-FIN-018, BR-FIN-007, BR-FIN-016): on 2026-04-15 the flow covenant of 12,000,000 a fiscal year (to December)
   counts the confirmed flows of January to March to bank 1, at the bank's level or this facility's: 3 x 1,000,000;
   April's 500,000 awaits confirmation; a flow to bank 2 and one given to another facility do not count. Three months
   of the window are complete (April is not yet): remaining 9,000,000, 9,000,000 / 9 months = 1,000,000 a month,
   25 percent, ON_TRACK (3 of the 12,000,000 in 3 of 12 months; review E6: the month of the date is not counted as
   elapsed). */
DECLARE @t INT, @u1 BIGINT, @u2 BIGINT, @hold BIGINT, @cur INT, @lst INT, @kind INT, @f BIGINT, @cfl BIGINT, @f2 BIGINT, @ok INT = 0, @row NVARCHAR(400);
BEGIN TRANSACTION;
EXEC #Fin;
SELECT @t = v FROM #F WHERE k = 't'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @u2 = v FROM #F WHERE k = 'u2'; SELECT @hold = v FROM #F WHERE k = 'hold';
SELECT @cur = v FROM #F WHERE k = 'cur'; SELECT @lst = v FROM #F WHERE k = 'lst'; SELECT @kind = v FROM #F WHERE k = 'kind'; SELECT @f = v FROM #F WHERE k = 'f';
SELECT @cfl = v FROM #F WHERE k = 'cfl';
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (@t, 'FAC-26-102', @hold, 1, @cur, 1000000, 'EN', '2026-01-01', '2027-12-31');
SET @f2 = SCOPE_IDENTITY();
INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, FacilityId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy, Status, ConfirmedBy, ConfirmedOn)
VALUES (@t, @hold, 1, NULL, '2026-01-31', @lst, @kind, 1000000, @cur, @u1, 'CONFIRMED', @u2, SYSUTCDATETIME()),
       (@t, @hold, 1, NULL, '2026-02-28', @lst, @kind, 1000000, @cur, @u1, 'CONFIRMED', @u2, SYSUTCDATETIME()),
       (@t, @hold, 1, @f, '2026-03-31', @lst, @kind, 1000000, @cur, @u1, 'CONFIRMED', @u2, SYSUTCDATETIME()),
       (@t, @hold, 1, @f2, '2026-03-31', @lst, @kind, 700000, @cur, @u1, 'CONFIRMED', @u2, SYSUTCDATETIME()),
       (@t, @hold, 2, NULL, '2026-03-31', @lst, @kind, 900000, @cur, @u1, 'CONFIRMED', @u2, SYSUTCDATETIME()),
       (@t, @hold, 1, NULL, '2026-04-30', @lst, @kind, 500000, @cur, @u1, 'DRAFT', NULL, NULL);
SELECT @row = CONCAT(WindowStart, '/', WindowEnd, '/', CAST(Achieved AS DECIMAL(19,0)), '/', CAST(AwaitingConfirmation AS DECIMAL(19,0)), '/', MonthsConfirmed, '/',
                     MonthsElapsed, '/', MonthsInWindow, '/', CAST(Remaining AS DECIMAL(19,0)), '/', CAST(RequiredPerRemainingMonth AS DECIMAL(19,0)), '/',
                     CAST(AchievementPct AS DECIMAL(9,2)), '/', PerformanceState)
FROM fin.fn_BankFlowPerformance('2026-04-15') WHERE CovenantId = @cfl;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @row = '2026-01-01/2026-12-31/3000000/500000/3/3/12/9000000/1000000/25.00/ON_TRACK'
    PRINT 'PASS FS7: the flow covenant counts the confirmed flows of its window to the facility''s bank, with what remains and the rate it needs';
ELSE PRINT CONCAT('FAIL FS7: ', @row, ' (expected 2026-01-01/2026-12-31/3000000/500000/3/3/12/9000000/1000000/25.00/ON_TRACK)');
GO
/* FS8 (BR-FIN-008, Q-FIN-05): a share-of-revenue covenant of 15 percent reads the revenue of the holding's approved
   annual statement for the window's fiscal year (2025 here: 50,000,000, so 7,500,000 to route), or the approved
   estimate when the covenant says MANUAL_ESTIMATE (40,000,000, so 6,000,000); without either it is NO_REVENUE. A
   quarterly covenant of 15 percent of the prior year's revenue asks for the share of the quarter's months, 3/12 of
   7,500,000 = 1,875,000 (review E5), in the quarter of the fiscal year: April to June for a year to December, March to
   May for a year to February (review E6). */
DECLARE @t INT, @u1 BIGINT, @u2 BIGINT, @hold BIGINT, @cur INT, @ob BIGINT, @f BIGINT, @fp BIGINT, @c1 BIGINT, @c2 BIGINT, @c3 BIGINT, @r1 NVARCHAR(100), @r2 NVARCHAR(100),
        @r3 NVARCHAR(100), @r4 NVARCHAR(100), @r5 NVARCHAR(100);
BEGIN TRANSACTION;
EXEC #Fin;
SELECT @t = v FROM #F WHERE k = 't'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @u2 = v FROM #F WHERE k = 'u2'; SELECT @hold = v FROM #F WHERE k = 'hold';
SELECT @cur = v FROM #F WHERE k = 'cur'; SELECT @ob = v FROM #F WHERE k = 'ob'; SELECT @f = v FROM #F WHERE k = 'f';
INSERT fin.MeasureFormula (TenantId, Code, NameAr, Scope, FacilityId, Expression, InputKinds, ResultUnit, VersionNo, Status, ApprovedBy, ApprovedOn, NoSourceReason)
VALUES (@t, 'FLOW_TO_REVENUE_PCT', N'نسبة التحويل من الإيراد', 'FACILITY_COPY', @f, 'FLOW_TO_BANK / REVENUE * 100', 'STATEMENT,BANK_FLOWS', 'PERCENT', 1, 'APPROVED', @u2,
        SYSUTCDATETIME(), N'test fixture');
SET @fp = SCOPE_IDENTITY();
INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, FormulaId, FormulaResultUnit, FormulaUsesStatements, Operator, ThresholdState, ThresholdValue, ThresholdUnit,
                     TestFrequency, AnnualWindowBasis, StatementBasis, RequiredAssurance, RevenueBasisRule, TestedCompanyId, FirstTestPeriodEnd, ValidFrom, FromRevision)
VALUES (@t, @ob, 'PERCENT_OF_REVENUE', @fp, 'PERCENT', 1, 'GE', 'SET', 15, 'PERCENT', 'ANNUAL', 'FISCAL_YEAR', 'STANDALONE', 'ANY', 'PRIOR_YEAR', @hold, '2026-12-31', '2025-01-01', 2),
       (@t, @ob, 'PERCENT_OF_REVENUE', @fp, 'PERCENT', 1, 'GE', 'SET', 15, 'PERCENT', 'ANNUAL', 'FISCAL_YEAR', 'STANDALONE', 'ANY', 'MANUAL_ESTIMATE', @hold, '2026-12-31', '2025-02-01', 2),
       (@t, @ob, 'PERCENT_OF_REVENUE', @fp, 'PERCENT', 1, 'GE', 'SET', 15, 'PERCENT', 'QUARTERLY', 'FISCAL_YEAR', 'STANDALONE', 'ANY', 'PRIOR_YEAR', @hold, '2026-06-30', '2025-03-01', 2);
SELECT @c1 = CovenantId FROM obl.Covenant WHERE ObligationId = @ob AND RevenueBasisRule = 'PRIOR_YEAR' AND TestFrequency = 'ANNUAL';
SELECT @c3 = CovenantId FROM obl.Covenant WHERE ObligationId = @ob AND RevenueBasisRule = 'PRIOR_YEAR' AND TestFrequency = 'QUARTERLY';
SELECT @c2 = CovenantId FROM obl.Covenant WHERE ObligationId = @ob AND RevenueBasisRule = 'MANUAL_ESTIMATE';
-- the two covenants join revision 2, approved
INSERT fac.FacilityRevision (TenantId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn, SubmittedBy, SubmittedOn, ApprovedBy, ApprovedOn)
VALUES (@t, @f, 2, 'AMENDMENT', 'APPROVED', '2026-02-01', @u1, SYSUTCDATETIME(), @u2, SYSUTCDATETIME());
UPDATE fac.Facility SET ApprovedRevisionNo = 2 WHERE FacilityId = @f;
SELECT @r3 = CONCAT(PerformanceState, '/', Required) FROM fin.fn_BankFlowPerformance('2026-04-15') WHERE CovenantId = @c2;
INSERT fin.RevenueEstimate (TenantId, CompanyId, FiscalYear, Basis, Amount, CurrencyId, BasisNote, Status, PreparedBy, ApprovedBy, ApprovedOn)
VALUES (@t, @hold, 2026, 'STANDALONE', 40000000, @cur, N'Approved budget 2026', 'APPROVED', @u1, @u2, SYSUTCDATETIME());
SELECT @r1 = CONCAT(CAST(Revenue AS DECIMAL(19,0)), '/', CAST(Required AS DECIMAL(19,0)), '/', LEFT(RevenueSource, 9)) FROM fin.fn_BankFlowPerformance('2026-04-15') WHERE CovenantId = @c1;
SELECT @r2 = CONCAT(CAST(Revenue AS DECIMAL(19,0)), '/', CAST(Required AS DECIMAL(19,0)), '/', LEFT(RevenueSource, 8)) FROM fin.fn_BankFlowPerformance('2026-04-15') WHERE CovenantId = @c2;
SELECT @r4 = CONCAT(WindowStart, '/', WindowEnd, '/', MonthsInWindow, '/', CAST(Required AS DECIMAL(19,0))) FROM fin.fn_BankFlowPerformance('2026-04-15') WHERE CovenantId = @c3;
UPDATE org.Company SET FiscalYearEndMonth = 2 WHERE CompanyId = @hold;
SELECT @r5 = CONCAT(WindowStart, '/', WindowEnd) FROM fin.fn_BankFlowPerformance('2026-04-15') WHERE CovenantId = @c3;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @r1 = '50000000/7500000/STATEMENT' AND @r2 = '40000000/6000000/ESTIMATE' AND @r3 = 'NO_REVENUE/' AND @r4 = '2026-04-01/2026-06-30/3/1875000'
   AND @r5 = '2026-03-01/2026-05-31'
    PRINT 'PASS FS8: a share-of-revenue covenant reads the approved statement''s revenue or the approved estimate, as it says, for the months of its window';
ELSE PRINT CONCAT('FAIL FS8: prior year [', @r1, '], estimate [', @r2, '], no estimate yet [', @r3, '], quarterly [', @r4, '], fiscal year to February [', @r5, ']');
GO
/* FS9 (FR-FIN-016, BR-FIN-014): one analysis measure per statement and formula (2627); a DAYS formula is an analysis
   formula (547) and no covenant measures in days (547); a measure that could not be computed says why (547). */
CREATE PROCEDURE #AnalysisCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT, @u2 BIGINT, @fs BIGINT, @ob BIGINT, @hold BIGINT, @fa BIGINT;
    SELECT @t = v FROM #F WHERE k = 't'; SELECT @u2 = v FROM #F WHERE k = 'u2'; SELECT @fs = v FROM #F WHERE k = 'fs';
    SELECT @ob = v FROM #F WHERE k = 'ob'; SELECT @hold = v FROM #F WHERE k = 'hold';
    INSERT fin.MeasureFormula (TenantId, Code, NameAr, Scope, Expression, InputKinds, ResultUnit, Status, ApprovedBy, ApprovedOn, NoSourceReason)
    VALUES (@t, 'DSO', N'أيام التحصيل', CASE WHEN @Case = 2 THEN 'TEMPLATE' ELSE 'ANALYSIS' END, 'AR / REVENUE * 365', 'STATEMENT', 'DAYS', 'APPROVED', @u2, SYSUTCDATETIME(), N'library');
    SET @fa = SCOPE_IDENTITY();
    IF @Case IN (1, 4)
        INSERT fin.StatementRatio (TenantId, StatementId, FormulaId, ResultUnit, Status, Value, Reason, InputsSnapshot)
        VALUES (@t, @fs, @fa, 'DAYS', 'COMPUTED', CASE WHEN @Case = 1 THEN 45 END, NULL, N'{"statements":[]}');
    IF @Case = 1
        INSERT fin.StatementRatio (TenantId, StatementId, FormulaId, ResultUnit, Status, Value, InputsSnapshot) VALUES (@t, @fs, @fa, 'DAYS', 'COMPUTED', 46, N'{}');
    IF @Case = 3
        INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, FormulaId, FormulaResultUnit, FormulaUsesStatements, Operator, ThresholdState, ThresholdValue,
                             ThresholdUnit, TestFrequency, StatementBasis, RequiredAssurance, TestedCompanyId, FirstTestPeriodEnd, ValidFrom, FromRevision)
        VALUES (@t, @ob, 'RATIO', @fa, 'DAYS', 1, 'LE', 'SET', 60, 'RATIO', 'ANNUAL', 'STANDALONE', 'ANY', @hold, '2026-12-31', '2026-05-01', 2);
    IF @Case = 5
        INSERT fin.StatementRatio (TenantId, StatementId, FormulaId, ResultUnit, Status, Reason, InputsSnapshot)
        VALUES (@t, @fs, @fa, 'DAYS', 'NOT_COMPUTABLE', N'Revenue is zero', N'{"statements":[]}');
END;
GO
DECLARE @got NVARCHAR(800);
EXEC #Cases '#AnalysisCase', 1, 5, @got OUTPUT;
IF @got = '1:2627 2:547 3:547 4:547 5:0'
    PRINT 'PASS FS9: one analysis measure per statement and formula, days for analysis only, and a measure not computed says why';
ELSE PRINT CONCAT('FAIL FS9: case:error ', @got, ' (expected 1:2627 2:547 3:547 4:547 5:0)');
GO
/* FS10 (Q-FIN-05): two approved estimates of one company, year and basis are refused (2601); an estimate is approved
   by someone other than its preparer (547). */
CREATE PROCEDURE #EstimateCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT, @u1 BIGINT, @u2 BIGINT, @hold BIGINT, @cur INT;
    SELECT @t = v FROM #F WHERE k = 't'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @u2 = v FROM #F WHERE k = 'u2';
    SELECT @hold = v FROM #F WHERE k = 'hold'; SELECT @cur = v FROM #F WHERE k = 'cur';
    INSERT fin.RevenueEstimate (TenantId, CompanyId, FiscalYear, Basis, Amount, CurrencyId, BasisNote, Status, PreparedBy, ApprovedBy, ApprovedOn)
    VALUES (@t, @hold, 2026, 'STANDALONE', 40000000, @cur, N'Budget', 'APPROVED', @u1, CASE WHEN @Case = 2 THEN @u1 ELSE @u2 END, SYSUTCDATETIME());
    IF @Case = 1
        INSERT fin.RevenueEstimate (TenantId, CompanyId, FiscalYear, Basis, Amount, CurrencyId, BasisNote, Status, PreparedBy, ApprovedBy, ApprovedOn)
        VALUES (@t, @hold, 2026, 'STANDALONE', 42000000, @cur, N'Revised budget', 'APPROVED', @u1, @u2, SYSUTCDATETIME());
END;
GO
DECLARE @got NVARCHAR(800);
EXEC #Cases '#EstimateCase', 1, 3, @got OUTPUT;
IF @got = '1:2601 2:547 3:0'
    PRINT 'PASS FS10: one approved revenue estimate per company, year and basis, approved by another user';
ELSE PRINT CONCAT('FAIL FS10: case:error ', @got, ' (expected 1:2601 2:547 3:0)');
GO
/* FS11 (FR-FIN-015): the units of the holding's consolidated statement for 2026: the holding (its own unit) and the
   subsidiary at 80 percent, with the 80 percent on record and no standalone statement of its own yet; once the
   subsidiary's standalone statement for 2026 is approved, it is shown. */
DECLARE @t INT, @u2 BIGINT, @hold BIGINT, @sub BIGINT, @s BIGINT, @ss BIGINT, @r1 NVARCHAR(200), @r2 NVARCHAR(200);
BEGIN TRANSACTION;
EXEC #Fin;
SELECT @t = v FROM #F WHERE k = 't'; SELECT @u2 = v FROM #F WHERE k = 'u2'; SELECT @hold = v FROM #F WHERE k = 'hold'; SELECT @sub = v FROM #F WHERE k = 'sub';
EXEC #NewStatement @hold, 'CONSOLIDATED';
SELECT @s = v FROM #F WHERE k = 's';
INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method) VALUES (@t, @s, @hold, 'PARENT', 'FULL');
INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method, OwnershipPct) VALUES (@t, @s, @sub, 'SUBSIDIARY', 'FULL', 80);
SELECT @r1 = STRING_AGG(CONCAT(Role, ':', CAST(HasStandalone AS INT), ':', CAST(RecordedOwnershipPct AS DECIMAL(9,2))), ' ') WITHIN GROUP (ORDER BY Role)
FROM fin.v_ConsolidationUnits WHERE StatementId = @s;
EXEC #NewStatement @sub, 'STANDALONE';
SELECT @ss = v FROM #F WHERE k = 's';
UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @ss;
UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @ss;
SELECT @r2 = CONCAT(CAST(HasStandalone AS INT), ':', CASE WHEN StandaloneStatementId = @ss THEN 'own' ELSE 'other' END)
FROM fin.v_ConsolidationUnits WHERE StatementId = @s AND Role = 'SUBSIDIARY';
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @r1 = 'PARENT:1: SUBSIDIARY:0:80.00' AND @r2 = '1:own'
    PRINT 'PASS FS11: the units of a consolidated statement show their own statements and the ownership on record';
ELSE PRINT CONCAT('FAIL FS11: units [', @r1, '], after the subsidiary''s statement [', @r2, ']');
GO
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'UserId', @value = NULL;
DROP USER [tp_test_finapp];
PRINT 'Financial statements tests finished; every change is rolled back.';
GO

/* ============================================================================
   BankFas - tests of the credit assessment of a balance sheet on the Moody's scale, version 2, through the tables
   (046, 047, db/seed/104; docs/35-credit-assessment-methodology.md, docs/adr/0017-credit-assessment.md and
   0018-credit-assessment-v2.md; spec 12 FR-FIN-020 to FR-FIN-030, BR-FIN-018 to BR-FIN-030; owner requests of
   2026-10-18 and 2026-10-19). The engine itself is checked number for number against tools/dbgen/credit_reference.py
   by db/tests/credit_engine_cases.sql; these tests check what the computation reads from the tables and writes, and
   the guards. Every expected number below is what tools/dbgen/credit_reference.py gives for the same inputs.
   CA1  the linear continuum of a grid, its inverse, and the levels of an item rule
   CA2  the worked example of docs/35 section 14 entered as a statement, computed by the application role: factors,
        grades, liquidity, completeness, adjustments, remedies and outlook as the reference computes them
   CA3  an indicative grade without the qualitative factors, no grade without enough metrics, a notch for a missing
        cash flow statement, the sub-factors and the sector risk
   CA4  the disclosures and the data the report asks for, and an inconsistent line
   CA5  the notches and caps read from the statement, the evidence and the dates
   CA6  group support up to the parent's grade, and the override
   CA7  the life of an assessment, and what the application role cannot write
   CA8  the report views
   CA9  covenants, breaches and liquidity routed to the bank in the assessment
   CA10 the platform's methodology does not change once approved
   CA11 tenant isolation
   CA12 the seed of the methodology
   CA13 the company's facilities and collateral on the platform, the guarantors and the credit bureau report
   CA14 the company's activity and product lines: the scenarios, the resilience, the sector position and the
        strengthening plans with a balanced balance sheet at every step
   CA15 what the computation read: the guarantors, the bureau report and the product lines are in its hash
   CA16 the market country and city and the detailed activity: the anchor, the country ceiling, the requests, the stress
   CA17 to CA22 the company's perspective (docs/36): the lender's decisions, trial assessments, presentation versions,
        the readiness file, budgets and the lender's ratings
   CA23 the early warning job and its notification requests
   CA24 the message templates of the early warning in Arabic and English (the tenant pack NTF.BASE)

   Run against a deployed BankFas database that holds no real data, with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/credit_assessment_tests.sql
   Every case runs in its own transaction and rolls it back. Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
GO
/* The fixture. */
IF USER_ID(N'tp_test_crdapp') IS NULL
BEGIN
    CREATE USER [tp_test_crdapp] WITHOUT LOGIN;
    ALTER ROLE [tp_app] ADD MEMBER [tp_test_crdapp];
END;
IF USER_ID(N'tp_test_crdjob') IS NULL
BEGIN
    CREATE USER [tp_test_crdjob] WITHOUT LOGIN;
    ALTER ROLE [tp_jobs] ADD MEMBER [tp_test_crdjob];
END;
GO
CREATE TABLE #C (k VARCHAR(20) PRIMARY KEY, v BIGINT NOT NULL);
GO
CREATE PROCEDURE #CBind @TenantId INT, @UserId BIGINT
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind)
    VALUES (@@SPID, @TenantId, @UserId, @token, 'USER');
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @UserId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
    EXEC sys.sp_set_session_context @key = N'JobKey', @value = NULL;
END;
GO
-- Binds the connection as the tenant's service account for the early warning job, as sec.usp_SetJobContext does (037).
CREATE PROCEDURE #CJob
AS
BEGIN
    DECLARE @t INT = (SELECT v FROM #C WHERE k = 't'), @svc BIGINT, @token UNIQUEIDENTIFIER = NEWID();
    SET @svc = (SELECT AppUserId FROM sec.AppUser WHERE TenantId = @t AND IsSystemUser = 1);
    IF @svc IS NULL
    BEGIN
        INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, IsSystemUser) VALUES (@t, N'service@crd.invalid', N'Service', 'ACTIVE', 1);
        SET @svc = SCOPE_IDENTITY();
    END;
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind)
    VALUES (@@SPID, @t, @svc, @token, 'JOB');
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @t;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @svc;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
    EXEC sys.sp_set_session_context @key = N'JobKey', @value = 'JOB-FIN-READINESS';
END;
GO
-- The worked example's 2025 lines in SAR millions (docs/35 section 14).
CREATE PROCEDURE #CBase @Spec NVARCHAR(MAX) OUTPUT
AS
SET @Spec = N'CASH=45;AR=160;INVENTORY=130;DUE_FROM_RELATED=20;OTHER_CA=25;TOTAL_CA=380;PPE=520;INTANGIBLES=30;OTHER_NCA=70;TOTAL_ASSETS=1000;'
          + N'ST_LOANS=120;CURRENT_PORTION_LTD=60;AP=110;DUE_TO_RELATED=10;OTHER_CL=50;TOTAL_CL=350;LT_LOANS=180;LEASE_LIABS=20;'
          + N'SHAREHOLDER_LOANS_SUB=0;EOSB=18;OTHER_NCL=12;TOTAL_LIABS=580;SHARE_CAPITAL=250;RETAINED_EARNINGS=140;OTHER_EQUITY=30;'
          + N'MINORITY_INTEREST=0;TOTAL_EQUITY=420;REVENUE=900;COGS=650;GROSS_PROFIT=250;OPEX=160;DEPR_AMORT=40;EBITDA=130;'
          + N'OPERATING_PROFIT=90;FINANCE_COSTS=22;OTHER_INCOME=4;ZAKAT_TAX=8;NET_PROFIT=64;OP_CASH_FLOW=95;CAPEX=60;'
          + N'PRINCIPAL_REPAID=55;INTEREST_PAID=21;DIVIDENDS=30;LC_OUTSTANDING=90;LG_PERFORMANCE=100;LG_FINANCIAL=20;GUARANTEES_GIVEN=0';
GO
/* A statement of @Company for the year to @PeriodEnd: the base lines with @Override applied (a code with the value
   'NULL' is left out), in SAR, submitted and approved by u2 unless @Approve = 0 ('s' in #C). */
CREATE PROCEDURE #CStmt @Company BIGINT, @PeriodEnd DATE, @Override NVARCHAR(MAX) = N'', @Assurance VARCHAR(10) = 'AUDITED',
                        @Opinion VARCHAR(11) = 'UNQUALIFIED', @Approve BIT = 1, @PeriodType VARCHAR(10) = 'ANNUAL', @Basis VARCHAR(12) = 'STANDALONE',
                        @Currency CHAR(3) = 'SAR', @GoingConcern BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT, @u1 BIGINT, @u2 BIGINT, @s BIGINT, @base NVARCHAR(MAX), @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = @Currency COLLATE Arabic_100_CI_AS_SC);
    SELECT @t = v FROM #C WHERE k = 't'; SELECT @u1 = v FROM #C WHERE k = 'u1'; SELECT @u2 = v FROM #C WHERE k = 'u2';
    EXEC #CBase @base OUTPUT;
    INSERT fin.FinancialStatement (TenantId, CompanyId, PeriodType, PeriodEnd, FiscalYear, Basis, Assurance, CurrencyId, EntryMethod, PreparedBy, PreparedOn,
                                   AuditorName, AuditOpinion, GoingConcernUncertainty)
    VALUES (@t, @Company, @PeriodType, @PeriodEnd, YEAR(@PeriodEnd), @Basis, @Assurance, @cur, 'MANUAL', @u1, SYSUTCDATETIME(),
            CASE WHEN @Assurance COLLATE Arabic_100_CI_AS_SC = 'AUDITED' THEN N'Auditor (test)' END, CASE WHEN @Assurance COLLATE Arabic_100_CI_AS_SC = 'AUDITED' THEN @Opinion END,
            @GoingConcern);
    SET @s = SCOPE_IDENTITY();
    DECLARE @l TABLE (Code VARCHAR(40) COLLATE Arabic_100_CI_AS_SC PRIMARY KEY, Amount NVARCHAR(40) COLLATE Arabic_100_CI_AS_SC, Pri INT);
    INSERT @l (Code, Amount, Pri)
    SELECT Code, Amount, Pri
    FROM (SELECT LEFT(x.value, CHARINDEX(N'=', x.value) - 1) AS Code, SUBSTRING(x.value, CHARINDEX(N'=', x.value) + 1, 40) AS Amount, p.Pri,
                 ROW_NUMBER() OVER (PARTITION BY LEFT(x.value, CHARINDEX(N'=', x.value) - 1) ORDER BY p.Pri DESC) AS rn
          FROM (VALUES (0, @base COLLATE Arabic_100_CI_AS_SC), (1, @Override COLLATE Arabic_100_CI_AS_SC)) AS p (Pri, Spec)
          CROSS APPLY STRING_SPLIT(p.Spec COLLATE Arabic_100_CI_AS_SC, N';') AS x
          WHERE CHARINDEX(N'=', x.value) > 0) AS y
    WHERE y.rn = 1;
    INSERT fin.StatementLine (TenantId, StatementId, LineCatalogItemId, EnteredAmount)
    SELECT @t, @s, li.LineCatalogItemId, CAST(l.Amount AS DECIMAL(19,4)) * 1000000
    FROM @l AS l
    JOIN fin.LineCatalogItem AS li ON li.TenantId = @t AND li.Code = l.Code
    WHERE l.Amount <> N'NULL';
    IF @Approve = 1
    BEGIN
        UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @s;
        UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @s;
    END;
    DELETE FROM #C WHERE k = 's';
    INSERT #C (k, v) VALUES ('s', @s);
END;
GO
CREATE PROCEDURE #Crd
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM #C;
    DECLARE @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'), @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA'),
            @pw VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA',
            @t INT, @u1 BIGINT, @u2 BIGINT, @ph BIGINT, @pi BIGINT, @po BIGINT, @hold BIGINT, @ind BIGINT, @oth BIGINT, @s BIGINT;
    INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('tst-crd', N'م', N'Crd', @plan, @country, 'ACTIVE', 'UTC');
    SET @t = SCOPE_IDENTITY();
    EXEC #CBind @t, 0;
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t, N'fa@crd.invalid', N'Analyst', 'ACTIVE', @pw);
    SET @u1 = SCOPE_IDENTITY();
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t, N'tm@crd.invalid', N'Approver', 'ACTIVE', @pw);
    SET @u2 = SCOPE_IDENTITY();
    EXEC #CBind @t, @u1;
    ALTER TABLE org.Company NOCHECK CONSTRAINT FK_Company_LegalEntityTypeId;
    INSERT pty.Party (TenantId, PartyCode, Kind, NameEn) VALUES (@t, 'P-HOLD', 'ORGANIZATION', N'Holding'), (@t, 'P-IND', 'ORGANIZATION', N'Industrial'),
                                                              (@t, 'P-OTH', 'ORGANIZATION', N'Other');
    SELECT @ph = PartyId FROM pty.Party WHERE TenantId = @t AND PartyCode = 'P-HOLD';
    SELECT @pi = PartyId FROM pty.Party WHERE TenantId = @t AND PartyCode = 'P-IND';
    SELECT @po = PartyId FROM pty.Party WHERE TenantId = @t AND PartyCode = 'P-OTH';
    INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth, IsHolding)
    VALUES (@t, 'HOLD', N'قابضة', N'Holding', @ph, 1, @country, 12, 1), (@t, 'OTH', N'أخرى', N'Other', @po, 1, @country, 12, 0);
    SELECT @hold = CompanyId FROM org.Company WHERE TenantId = @t AND CompanyCode = 'HOLD';
    SELECT @oth = CompanyId FROM org.Company WHERE TenantId = @t AND CompanyCode = 'OTH';
    INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth, IsHolding, ParentCompanyId)
    VALUES (@t, 'IND', N'صناعية', N'Industrial', @pi, 1, @country, 12, 0, @hold);
    SELECT @ind = CompanyId FROM org.Company WHERE TenantId = @t AND CompanyCode = 'IND';
    -- the tenant's line catalogue holds every standard line of the credit assessment (db/seed/104)
    INSERT fin.LineCatalogItem (TenantId, Code, NameAr, NameEn, Section, SortOrder)
    SELECT @t, sl.Code, sl.NameAr, sl.NameEn, sl.Section, sl.SortOrder FROM fin.StandardLine AS sl;
    INSERT #C (k, v) VALUES ('t', @t), ('u1', @u1), ('u2', @u2), ('hold', @hold), ('ind', @ind), ('oth', @oth);
    EXEC #CStmt @ind, '2024-12-31', N'TOTAL_ASSETS=940;REVENUE=850;GROSS_PROFIT=245;CURRENT_PORTION_LTD=55;OP_CASH_FLOW=85';
    SELECT @s = v FROM #C WHERE k = 's';
    INSERT #C (k, v) VALUES ('p', @s);
END;
GO
/* A draft assessment of @Statement on @Card as of @AsOf, prepared by u1, with the qualitative grades @Business and
   @Policy (the worked example's Ba1 and Baa3) unless @Qualitative = 0 ('a' in #C). */
CREATE PROCEDURE #CAssess @Statement BIGINT, @Card VARCHAR(40) = 'GENERAL_CORPORATE', @AsOf DATE = '2026-04-30', @Qualitative BIT = 1,
                          @Fx DECIMAL(19,8) = NULL, @Prior BIGINT = NULL, @Business VARCHAR(4) = 'Ba1', @Policy VARCHAR(4) = 'Baa3'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT, @u1 BIGINT, @a BIGINT, @company BIGINT = (SELECT CompanyId FROM fin.FinancialStatement WHERE FinancialStatementId = @Statement);
    SELECT @t = v FROM #C WHERE k = 't'; SELECT @u1 = v FROM #C WHERE k = 'u1';
    INSERT fin.CreditAssessment (TenantId, CompanyId, StatementId, PriorStatementId, ScorecardId, AssessmentDate, FxRateToScorecard, PreparedBy)
    VALUES (@t, @company, @Statement, @Prior, (SELECT ScorecardId FROM fin.Scorecard WHERE Code = @Card COLLATE Arabic_100_CI_AS_SC AND Status = 'APPROVED'), @AsOf, @Fx, @u1);
    SET @a = SCOPE_IDENTITY();
    IF @Qualitative = 1
        INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, MetricId, GradeId, Justification, EnteredBy)
        SELECT @t, @a, 'QUALITATIVE', m.CreditMetricId, g.RatingGradeId, N'test fixture: the worked example of docs/35', @u1
        FROM (VALUES ('BUSINESS_PROFILE', @Business COLLATE Arabic_100_CI_AS_SC), ('FINANCIAL_POLICY', @Policy COLLATE Arabic_100_CI_AS_SC)) AS v (Metric, Grade)
        JOIN fin.CreditMetric AS m ON m.Code = v.Metric
        JOIN fin.RatingGrade AS g ON g.Code = v.Grade;
    DELETE FROM #C WHERE k = 'a';
    INSERT #C (k, v) VALUES ('a', @a);
END;
GO
-- Runs cases @From to @To of a case procedure, each in its own transaction on a new fixture, and returns
-- case:error=result, the result being what the case procedure gives back.
CREATE PROCEDURE #CCases @CaseProc SYSNAME, @From INT, @To INT, @Result NVARCHAR(2000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (CaseNo INT PRIMARY KEY, Err INT NOT NULL, Res NVARCHAR(300) NULL);
    DECLARE @i INT = @From, @e INT, @o NVARCHAR(300);
    WHILE @i <= @To
    BEGIN
        SET @o = NULL;
        BEGIN TRANSACTION;
        BEGIN TRY EXEC #Crd; EXEC @CaseProc @i, @o OUTPUT; SET @e = 0; END TRY
        BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
        WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        INSERT @r (CaseNo, Err, Res) VALUES (@i, @e, @o);
        SET @i += 1;
    END;
    SET @Result = (SELECT STRING_AGG(CONCAT(CaseNo, ':', Err, CASE WHEN Res IS NOT NULL THEN CONCAT('=', Res) END), ' ') WITHIN GROUP (ORDER BY CaseNo) FROM @r);
END;
GO
-- The final grade, the standalone grade and the adjustment findings of an assessment, after computing it.
CREATE PROCEDURE #CGrade @Assessment BIGINT, @Out NVARCHAR(300) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC fin.usp_ComputeCreditAssessment @Assessment;
    SELECT @Out = CONCAT(ISNULL(FinalGrade, ResultState), '|', StandaloneGrade, '|',
                         (SELECT STRING_AGG(x.RuleCode, ',') WITHIN GROUP (ORDER BY x.RuleCode)
                          FROM fin.CreditAssessmentFinding AS x WHERE x.AssessmentId = r.CreditAssessmentId AND x.Kind = 'ADJUSTMENT'))
    FROM fin.v_CreditAssessmentReport AS r WHERE r.CreditAssessmentId = @Assessment;
END;
GO
/* CA1 (BR-FIN-018, docs/35 sections 3 and 7): a value scores linearly between the boundaries of its grid, takes 0.5 at
   or beyond the best cap and 20.5 at or beyond the worst, in either direction; the inverse gives the value at a score
   (the triggers); a value on an item threshold belongs to the worse level. */
DECLARE @got NVARCHAR(600) = CONCAT(
    (SELECT Score FROM fin.fn_CreditGridScore(3.0, 0, 0.5, 1.5, 2.5, 3.5, 4.5, 6, 8, 12)), ' ',
    (SELECT Score FROM fin.fn_CreditGridScore(2.5, 0, 0.5, 1.5, 2.5, 3.5, 4.5, 6, 8, 12)), ' ',
    (SELECT Score FROM fin.fn_CreditGridScore(10, 0, 0.5, 1.5, 2.5, 3.5, 4.5, 6, 8, 12)), ' ',
    (SELECT Score FROM fin.fn_CreditGridScore(-1, 0, 0.5, 1.5, 2.5, 3.5, 4.5, 6, 8, 12)), ' ',
    (SELECT Score FROM fin.fn_CreditGridScore(20, 0, 0.5, 1.5, 2.5, 3.5, 4.5, 6, 8, 12)), ' ',
    (SELECT Score FROM fin.fn_CreditGridScore(5.909091, 40, 20, 12, 7, 4, 2.5, 1.5, 1, 0)), ' ',
    (SELECT Score FROM fin.fn_CreditGridScore(7, 40, 20, 12, 7, 4, 2.5, 1.5, 1, 0)), ' ',
    (SELECT Score FROM fin.fn_CreditGridScore(50, 40, 20, 12, 7, 4, 2.5, 1.5, 1, 0)), ' ',
    (SELECT Score FROM fin.fn_CreditGridScore(-3, 40, 20, 12, 7, 4, 2.5, 1.5, 1, 0)), ' ',
    (SELECT CAST(Value AS DECIMAL(9,4)) FROM fin.fn_CreditGridValue(9.0, 0, 0.5, 1.5, 2.5, 3.5, 4.5, 6, 8, 12)), ' ',
    (SELECT CAST(Value AS DECIMAL(9,4)) FROM fin.fn_CreditGridValue(8.5909, 40, 20, 12, 7, 4, 2.5, 1.5, 1, 0)), ' ',
    (SELECT CAST(Value AS DECIMAL(9,4)) FROM fin.fn_CreditGridValue(25, 40, 20, 12, 7, 4, 2.5, 1.5, 1, 0)), ' ',
    (SELECT RiskLevel FROM fin.fn_CreditItemLevel(59.9, 60, 90, 120, 180)), ' ',
    (SELECT RiskLevel FROM fin.fn_CreditItemLevel(60, 60, 90, 120, 180)), ' ',
    (SELECT RiskLevel FROM fin.fn_CreditItemLevel(180, 60, 90, 120, 180)), ' ',
    (SELECT RiskLevel FROM fin.fn_CreditItemLevel(0.76, 0.75, 0.4, 0.2, 0.1)), ' ',
    (SELECT RiskLevel FROM fin.fn_CreditItemLevel(0.75, 0.75, 0.4, 0.2, 0.1)), ' ',
    (SELECT RiskLevel FROM fin.fn_CreditItemLevel(0.25, 0.75, 0.4, 0.2, 0.1)), ' ',
    (SELECT RiskLevel FROM fin.fn_CreditItemLevel(0.1, 0.75, 0.4, 0.2, 0.1)));
IF @got = '9.0000 7.5000 20.0000 0.5000 20.5000 8.5909 7.5000 0.5000 20.5000 3.0000 5.9091 0.0000 LOW MODERATE CRITICAL LOW MODERATE ELEVATED CRITICAL'
    PRINT 'PASS CA1: a value scores linearly on its grid and caps at both ends, the inverse gives the value back, and a value on an item threshold takes the worse level';
ELSE PRINT CONCAT('FAIL CA1: ', @got);
GO
/* The result of an assessment in one line: state, coverage, financial score and grade, weighted score, indicated,
   standalone and final grades, liquidity label, completeness, outlook and its rules, and the adjustment findings. */
CREATE PROCEDURE #CHead @Assessment BIGINT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Out = CONCAT(ResultState, ' ', CoveragePct, ' ', FinancialScore, ' ', FinancialGrade, ' ', WeightedScore, ' ', IndicatedGrade, ' ', StandaloneGrade, ' ',
                         FinalGrade, ' ', LiquidityLabel, ' ', CompletenessPct, ' ', Outlook, ' ', OutlookRules, ' | ',
                         (SELECT STRING_AGG(x.RuleCode, ',') WITHIN GROUP (ORDER BY x.RuleCode)
                          FROM fin.CreditAssessmentFinding AS x WHERE x.AssessmentId = r.CreditAssessmentId AND x.Kind = 'ADJUSTMENT' AND x.Source = 'ADJUSTMENT'))
    FROM fin.v_CreditAssessmentReport AS r WHERE r.CreditAssessmentId = @Assessment;
END;
GO
/* CA2 (FR-FIN-020 to FR-FIN-023, BR-FIN-018 to BR-FIN-020): the worked example of docs/35 section 14, its 2024 statement
   as the comparison, computed by the application role: every factor's score, the grades, the liquidity label, the
   completeness of the disclosures, the outlook, the adjustments and the remedies are those of
   tools/dbgen/credit_reference.py for the same lines and inputs. */
DECLARE @s BIGINT, @a BIGINT, @ind BIGINT, @factors NVARCHAR(2000), @head NVARCHAR(1000), @rem NVARCHAR(1000), @cur INT, @nr INT, @nt INT;
BEGIN TRANSACTION;
EXEC #Crd;
SELECT @ind = v FROM #C WHERE k = 'ind';
EXEC #CStmt @ind, '2025-12-31';
SELECT @s = v FROM #C WHERE k = 's';
EXEC #CAssess @s;
SELECT @a = v FROM #C WHERE k = 'a';
EXECUTE AS USER = N'tp_test_crdapp';
EXEC fin.usp_ComputeCreditAssessment @a;
REVERT;
SELECT @factors = STRING_AGG(CONCAT(MetricCode, ':', ISNULL(CAST(Score AS VARCHAR(12)), '-')), ' ') WITHIN GROUP (ORDER BY SortOrder) FROM fin.v_CreditAssessmentFactors WHERE AssessmentId = @a;
EXEC #CHead @a, @head OUTPUT;
SELECT @rem = STRING_AGG(CONCAT(RemedyCode, ':', ISNULL(ProFormaGrade, '-')), ' ') WITHIN GROUP (ORDER BY SeqNo) FROM fin.v_CreditAssessmentRemedies WHERE AssessmentId = @a;
SELECT @cur = CAST(IsCurrent AS INT) FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
SELECT @nr = COUNT(*) FROM fin.v_CreditAssessmentReclass WHERE AssessmentId = @a;
SELECT @nt = COUNT(*) FROM fin.v_CreditAssessmentTriggers WHERE AssessmentId = @a;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @factors = 'REVENUE_SIZE:12.5000 BUSINESS_PROFILE:11.0000 REV_TOP5_SHARE:- EBITDA_MARGIN:8.4333 BREAKEVEN_SAFETY_MARGIN:6.7673 DEBT_TO_EBITDA:9.4154 EBITDA_TO_INTEREST:8.5909 RCF_TO_NET_DEBT:11.3149 TL_TO_TNW:9.7703 CONTINGENT_TO_TNW:8.3378 LIQUIDITY_COVERAGE:12.8228 CASH_CYCLE:9.1120 FUNDING_GAP:9.9444 RELATED_TO_TNW:8.4121 AR_OVER_180_SHARE:- FINANCIAL_POLICY:10.0000 PARTNER_DRAWINGS_TO_CFO:10.5000' AND @head = 'RATED 92.68 9.9901 Baa3 10.1322 Baa3 Ba2 Ba2 SGL-3 9.09 NEGATIVE NEG_LIQUIDITY,NEG_TREND | INFORMATION_RISK,INFORMATION_RISK_SEVERE' AND @rem = 'CONVERT_DUE_TO_RELATED_TO_SUB:Ba2 COMMITTED_FACILITY:- CREDIT_INSURANCE:- RETAIN_EARNINGS:Ba2 DISCLOSE_BREAKDOWNS:-' AND @cur = 1 AND @nr = 5 AND @nt = 15
    PRINT 'PASS CA2: the worked example entered as a statement gives the reference''s factors, grades, liquidity, completeness, outlook, adjustments and remedies';
ELSE PRINT CONCAT('FAIL CA2: factors ', @factors, ' | head ', @head, ' | remedies ', @rem, ' | current ', @cur, ' reclass ', @nr, ' triggers ', @nt);
GO
/* CA3 (BR-FIN-019, BR-FIN-021): without the qualitative grades the result is an indicative financial grade that is not
   submitted (547); a statement of revenue alone (its lines absent are zero and its totals the sums of its lines)
   scores what it can; without a cash flow statement the grade is a
   notch down (INCOMPLETE_STATEMENT); the business profile from three graded sub-factors with the sector risk of the
   company's activity. */
CREATE PROCEDURE #CoverageCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @t INT = (SELECT v FROM #C WHERE k = 't'), @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'),
            @u1 BIGINT = (SELECT v FROM #C WHERE k = 'u1');
    IF @Case IN (1, 2)
    BEGIN
        EXEC #CStmt @ind, '2025-12-31';
        SELECT @s = v FROM #C WHERE k = 's';
        EXEC #CAssess @s, @Qualitative = 0;
        SELECT @a = v FROM #C WHERE k = 'a';
        EXEC fin.usp_ComputeCreditAssessment @a;
        SELECT @Out = CONCAT(ResultState, ' ', FinancialScore, ' ', FinancialGrade, ' ', ISNULL(FinalGrade, '-')) FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
        IF @Case = 2 UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
    END;
    IF @Case = 3
    BEGIN
        EXEC #CStmt @ind, '2025-12-31', N'CASH=NULL;AR=NULL;INVENTORY=NULL;DUE_FROM_RELATED=NULL;OTHER_CA=NULL;TOTAL_CA=NULL;PPE=NULL;INTANGIBLES=NULL;OTHER_NCA=NULL;TOTAL_ASSETS=NULL;ST_LOANS=NULL;CURRENT_PORTION_LTD=NULL;AP=NULL;DUE_TO_RELATED=NULL;OTHER_CL=NULL;TOTAL_CL=NULL;LT_LOANS=NULL;LEASE_LIABS=NULL;SHAREHOLDER_LOANS_SUB=NULL;EOSB=NULL;OTHER_NCL=NULL;TOTAL_LIABS=NULL;SHARE_CAPITAL=NULL;RETAINED_EARNINGS=NULL;OTHER_EQUITY=NULL;MINORITY_INTEREST=NULL;TOTAL_EQUITY=NULL;COGS=NULL;GROSS_PROFIT=NULL;OPEX=NULL;OPERATING_PROFIT=NULL;DEPR_AMORT=NULL;EBITDA=NULL;FINANCE_COSTS=NULL;OTHER_INCOME=NULL;ZAKAT_TAX=NULL;NET_PROFIT=NULL;OP_CASH_FLOW=NULL;CAPEX=NULL;PRINCIPAL_REPAID=NULL;INTEREST_PAID=NULL;DIVIDENDS=NULL;LC_OUTSTANDING=NULL;LG_PERFORMANCE=NULL;LG_FINANCIAL=NULL;GUARANTEES_GIVEN=NULL';
        SELECT @s = v FROM #C WHERE k = 's';
        EXEC #CAssess @s, @Qualitative = 0;
        SELECT @a = v FROM #C WHERE k = 'a';
        EXEC fin.usp_ComputeCreditAssessment @a;
        SELECT @Out = CONCAT(ResultState, ' ', CoveragePct, ' ', ISNULL(FinalGrade, '-')) FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
    END;
    IF @Case = 4
    BEGIN
        EXEC #CStmt @ind, '2025-12-31', N'OP_CASH_FLOW=0;CAPEX=0;PRINCIPAL_REPAID=0;INTEREST_PAID=0;DIVIDENDS=0';
        SELECT @s = v FROM #C WHERE k = 's';
        EXEC #CAssess @s;
        SELECT @a = v FROM #C WHERE k = 'a';
        EXEC fin.usp_ComputeCreditAssessment @a;
        EXEC #CHead @a, @Out OUTPUT;
    END;
    IF @Case = 5
    BEGIN
        UPDATE org.Company SET IndustryId = (SELECT IndustryId FROM ref.Industry WHERE Code = 'C23') WHERE CompanyId = @ind;
        EXEC #CStmt @ind, '2025-12-31';
        SELECT @s = v FROM #C WHERE k = 's';
        EXEC #CAssess @s, @Qualitative = 0;
        SELECT @a = v FROM #C WHERE k = 'a';
        INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, MetricId, SubfactorId, GradeId, Justification, EnteredBy)
        SELECT TOP (3) @t, @a, 'SUBFACTOR', x.MetricId, x.ScorecardSubfactorId, g.RatingGradeId, N'test: a graded sub-factor of the business profile', @u1
        FROM fin.ScorecardSubfactor AS x
        JOIN fin.CreditMetric AS m ON m.CreditMetricId = x.MetricId AND m.Code = 'BUSINESS_PROFILE'
        JOIN fin.Scorecard AS sc ON sc.ScorecardId = x.ScorecardId AND sc.Code = 'GENERAL_CORPORATE' AND sc.Status = 'APPROVED'
        CROSS JOIN fin.RatingGrade AS g WHERE g.Code = 'Baa2'
        ORDER BY x.SortOrder;
        INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, MetricId, GradeId, Justification, EnteredBy)
        SELECT @t, @a, 'QUALITATIVE', m.CreditMetricId, g.RatingGradeId, N'test: the financial policy', @u1
        FROM fin.CreditMetric AS m CROSS JOIN fin.RatingGrade AS g WHERE m.Code = 'FINANCIAL_POLICY' AND g.Code = 'Baa3';
        EXEC fin.usp_ComputeCreditAssessment @a;
        SELECT @Out = CONCAT((SELECT Score FROM fin.v_CreditAssessmentFactors WHERE AssessmentId = @a AND MetricCode = 'BUSINESS_PROFILE'), ' ',
                             (SELECT FinalGrade FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a));
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#CoverageCase', 1, 5, @got OUTPUT;
IF @got = '1:0=INDICATIVE 10.0316 Baa3 - 2:547 3:0=INDICATIVE 81.71 - 4:0=RATED 85.37 9.8872 Baa3 10.0542 Baa3 Ba3 Ba3 SGL-3 9.09 NEGATIVE NEG_LIQUIDITY,NEG_TREND | INCOMPLETE_STATEMENT,INFORMATION_RISK,INFORMATION_RISK_SEVERE 5:0=10.2500 Ba3'
    PRINT 'PASS CA3: no final grade without the qualitative grades or enough quantitative metrics, a statement without cash flows costs a notch, and graded sub-factors give the business profile with the sector risk';
ELSE PRINT CONCAT('FAIL CA3: ', @got, ' (expected 1:0=INDICATIVE 10.0316 Baa3 - 2:547 3:0=INDICATIVE 81.71 - 4:0=RATED 85.37 9.8872 Baa3 10.0542 Baa3 Ba3 Ba3 SGL-3 9.09 NEGATIVE NEG_LIQUIDITY,NEG_TREND | INCOMPLETE_STATEMENT,INFORMATION_RISK,INFORMATION_RISK_SEVERE 5:0=10.2500 Ba3)');
GO
/* CA4 (FR-FIN-025, BR-FIN-026, docs/35 section 11): the disclosures the methodology asks of the statement and the data
   the report requests (the bureau report, the product lines, the activity), each a finding of its own; entering a
   breakdown answers its request and raises the completeness; an "of which" line larger than its line is reported as
   inconsistent and not read. */
CREATE PROCEDURE #DataCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'),
            @over NVARCHAR(400) = CASE @Case WHEN 2 THEN N'AR_AGE_0_90=120;AR_AGE_91_180=25;AR_AGE_181_365=10;AR_AGE_OVER_365=5;AR_GROSS=165;REV_TOP5=300;STAFF_COSTS=60;GENERAL_ADMIN=50;INV_SLOW_MOVING=10;DEBT_DUE_1Y=180;DEBT_SECURED=0'
                                             WHEN 3 THEN N'AR_GOVERNMENT=200' ELSE N'' END;
    EXEC #CStmt @ind, '2025-12-31', @over;
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    EXEC fin.usp_ComputeCreditAssessment @a;
    SELECT @Out = CONCAT((SELECT CompletenessPct FROM fin.CreditAssessment WHERE CreditAssessmentId = @a), ' ',
                         (SELECT STRING_AGG(CONCAT(RuleCode, CASE WHEN LineCode IS NOT NULL THEN CONCAT('/', LineCode) END), ',') WITHIN GROUP (ORDER BY SeqNo)
                          FROM fin.CreditAssessmentFinding WHERE AssessmentId = @a AND Source = 'DATA'));
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#DataCase', 1, 3, @got OUTPUT;
IF @got = '1:0=9.09 AR_AGING,AR_ALLOWANCE,COST_BREAKDOWN,CUSTOMER_CONCENTRATION,DEBT_MATURITY,DEBT_SECURED,INVENTORY_BREAKDOWN,PPE_BREAKDOWN,RELATED_BREAKDOWN,RESTRICTED_CASH,BUREAU_REPORT,PRODUCT_MIX,INDUSTRY 2:0=72.73 PPE_BREAKDOWN,RELATED_BREAKDOWN,RESTRICTED_CASH,BUREAU_REPORT,PRODUCT_MIX,INDUSTRY 3:0=9.09 AR_AGING,AR_ALLOWANCE,COST_BREAKDOWN,CUSTOMER_CONCENTRATION,DEBT_MATURITY,DEBT_SECURED,INVENTORY_BREAKDOWN,PPE_BREAKDOWN,RELATED_BREAKDOWN,RESTRICTED_CASH,BUREAU_REPORT,PRODUCT_MIX,INDUSTRY,INCONSISTENT/AR_GOVERNMENT'
    PRINT 'PASS CA4: the report asks for each missing disclosure and dataset, a breakdown entered answers it, and an inconsistent line is reported';
ELSE PRINT CONCAT('FAIL CA4: ', @got, ' (expected 1:0=9.09 AR_AGING,AR_ALLOWANCE,COST_BREAKDOWN,CUSTOMER_CONCENTRATION,DEBT_MATURITY,DEBT_SECURED,INVENTORY_BREAKDOWN,PPE_BREAKDOWN,RELATED_BREAKDOWN,RESTRICTED_CASH,BUREAU_REPORT,PRODUCT_MIX,INDUSTRY 2:0=72.73 PPE_BREAKDOWN,RELATED_BREAKDOWN,RESTRICTED_CASH,BUREAU_REPORT,PRODUCT_MIX,INDUSTRY 3:0=9.09 AR_AGING,AR_ALLOWANCE,COST_BREAKDOWN,CUSTOMER_CONCENTRATION,DEBT_MATURITY,DEBT_SECURED,INVENTORY_BREAKDOWN,PPE_BREAKDOWN,RELATED_BREAKDOWN,RESTRICTED_CASH,BUREAU_REPORT,PRODUCT_MIX,INDUSTRY,INCONSISTENT/AR_GOVERNMENT)');
GO
/* CA5 (docs/35 section 8): the adjustments the computation reads from the statement, its dates and the analyst's
   evidence: a qualified opinion, an unaudited annual statement, a stale statement, a going concern doubt, an adverse
   opinion, half the capital lost, cured by subordinated loans with their evidence, related-party exposure, and a
   holding's standalone statement. */
CREATE PROCEDURE #AdjustCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @t INT = (SELECT v FROM #C WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #C WHERE k = 'u1'),
            @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'), @hold BIGINT = (SELECT v FROM #C WHERE k = 'hold'),
            @co BIGINT, @over NVARCHAR(400) = N'', @assurance VARCHAR(10) = 'AUDITED', @opinion VARCHAR(11) = 'UNQUALIFIED', @asOf DATE = '2026-04-30',
            @gc BIT = CASE WHEN @Case = 5 THEN 1 ELSE 0 END;
    SET @co = CASE WHEN @Case = 10 THEN @hold ELSE @ind END;
    IF @Case = 2 SET @opinion = 'QUALIFIED';
    IF @Case = 3 SET @assurance = 'MANAGEMENT';
    IF @Case = 4 SET @asOf = '2027-06-30';
    IF @Case = 6 SET @opinion = 'ADVERSE';
    IF @Case = 7 SET @over = N'RETAINED_EARNINGS=-150;TOTAL_EQUITY=130';
    IF @Case = 8 SET @over = N'RETAINED_EARNINGS=-150;TOTAL_EQUITY=130;SHAREHOLDER_LOANS_SUB=200';
    IF @Case = 9 SET @over = N'DUE_FROM_RELATED=200';
    IF @Case = 10 EXEC #CStmt @hold, '2024-12-31', N'TOTAL_ASSETS=940;REVENUE=850;GROSS_PROFIT=245;CURRENT_PORTION_LTD=55;OP_CASH_FLOW=85';
    EXEC #CStmt @co, '2025-12-31', @over, @assurance, @opinion, @GoingConcern = @gc;
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s, @AsOf = @asOf;
    SELECT @a = v FROM #C WHERE k = 'a';
    IF @Case = 8
    BEGIN
        ALTER TABLE fin.CreditAssessmentInput NOCHECK CONSTRAINT FK_CreditAssessmentInput_DocumentId;
        INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, EvidenceCode, DocumentId, Justification, EnteredBy)
        VALUES (@t, @a, 'EVIDENCE', 'SUBORDINATION', 1, N'test: the signed subordination letter of the partners', @u1);
    END;
    EXEC fin.usp_ComputeCreditAssessment @a;
    SELECT @Out = CONCAT(r.FinalGrade, '|', r.StandaloneGrade, '|',
                         (SELECT STRING_AGG(x.RuleCode, ',') WITHIN GROUP (ORDER BY x.RuleCode)
                          FROM fin.CreditAssessmentFinding AS x WHERE x.AssessmentId = @a AND x.Kind = 'ADJUSTMENT' AND x.Source = 'ADJUSTMENT'))
    FROM fin.v_CreditAssessmentReport AS r WHERE r.CreditAssessmentId = @a;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#AdjustCase', 1, 10, @got OUTPUT;
IF @got = '1:0=Ba2|Ba2|INFORMATION_RISK,INFORMATION_RISK_SEVERE 2:0=Ba3|Ba3|AUDIT_QUALIFIED,INFORMATION_RISK,INFORMATION_RISK_SEVERE 3:0=Ba3|Ba3|INFORMATION_RISK,INFORMATION_RISK_SEVERE,UNAUDITED_ANNUAL 4:0=Ba3|Ba3|INFORMATION_RISK,INFORMATION_RISK_SEVERE,STALE_STATEMENT 5:0=Caa1|Caa1|GOING_CONCERN,INFORMATION_RISK,INFORMATION_RISK_SEVERE 6:0=Caa1|Ba2|AUDIT_ADVERSE,INFORMATION_RISK,INFORMATION_RISK_SEVERE 7:0=B3|B3|HALF_CAPITAL_LOST,INFORMATION_RISK,INFORMATION_RISK_SEVERE 8:0=Ba3|Ba3|HALF_CAPITAL_LOST_CURED,INFORMATION_RISK,INFORMATION_RISK_SEVERE 9:0=B1|B1|INFORMATION_RISK,INFORMATION_RISK_SEVERE,RELATED_PARTY_EXPOSURE 10:0=Ba3|Ba3|HOLDCO_STANDALONE,INFORMATION_RISK,INFORMATION_RISK_SEVERE'
    PRINT 'PASS CA5: each notch and cap the statement, its dates and the evidence call for moves the grade as the reference computes it';
ELSE PRINT CONCAT('FAIL CA5: ', @got, ' (expected 1:0=Ba2|Ba2|INFORMATION_RISK,INFORMATION_RISK_SEVERE 2:0=Ba3|Ba3|AUDIT_QUALIFIED,INFORMATION_RISK,INFORMATION_RISK_SEVERE 3:0=Ba3|Ba3|INFORMATION_RISK,INFORMATION_RISK_SEVERE,UNAUDITED_ANNUAL 4:0=Ba3|Ba3|INFORMATION_RISK,INFORMATION_RISK_SEVERE,STALE_STATEMENT 5:0=Caa1|Caa1|GOING_CONCERN,INFORMATION_RISK,INFORMATION_RISK_SEVERE 6:0=Caa1|Ba2|AUDIT_ADVERSE,INFORMATION_RISK,INFORMATION_RISK_SEVERE 7:0=B3|B3|HALF_CAPITAL_LOST,INFORMATION_RISK,INFORMATION_RISK_SEVERE 8:0=Ba3|Ba3|HALF_CAPITAL_LOST_CURED,INFORMATION_RISK,INFORMATION_RISK_SEVERE 9:0=B1|B1|INFORMATION_RISK,INFORMATION_RISK_SEVERE,RELATED_PARTY_EXPOSURE 10:0=Ba3|Ba3|HOLDCO_STANDALONE,INFORMATION_RISK,INFORMATION_RISK_SEVERE)');
GO
/* CA6 cases (BR-FIN-022): HOLD's consolidated statement for 2025 with HOLD as its PARENT and IND as a subsidiary, four
   times the worked example, assessed and approved ('ha' in #C) unless @Approve = 0. */
CREATE PROCEDURE #HoldAssessment @Approve BIT = 1, @AsOf DATE = '2026-04-30'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #C WHERE k = 't'), @u2 BIGINT = (SELECT v FROM #C WHERE k = 'u2'), @hold BIGINT = (SELECT v FROM #C WHERE k = 'hold'),
            @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'), @s BIGINT, @a BIGINT;
    EXEC #CStmt @hold, '2025-12-31', N'CASH=180;AR=640;INVENTORY=520;DUE_FROM_RELATED=80;OTHER_CA=100;TOTAL_CA=1520;PPE=2080;INTANGIBLES=120;OTHER_NCA=280;TOTAL_ASSETS=4000;ST_LOANS=480;CURRENT_PORTION_LTD=240;AP=440;DUE_TO_RELATED=40;OTHER_CL=200;TOTAL_CL=1400;LT_LOANS=720;LEASE_LIABS=80;SHAREHOLDER_LOANS_SUB=0;EOSB=72;OTHER_NCL=48;TOTAL_LIABS=2320;SHARE_CAPITAL=1000;RETAINED_EARNINGS=560;OTHER_EQUITY=120;MINORITY_INTEREST=0;TOTAL_EQUITY=1680;REVENUE=3600;COGS=2600;GROSS_PROFIT=1000;OPEX=640;DEPR_AMORT=160;EBITDA=520;OPERATING_PROFIT=360;FINANCE_COSTS=88;OTHER_INCOME=16;ZAKAT_TAX=32;NET_PROFIT=256;OP_CASH_FLOW=380;CAPEX=240;PRINCIPAL_REPAID=220;INTEREST_PAID=84;DIVIDENDS=120;LC_OUTSTANDING=360;LG_PERFORMANCE=400;LG_FINANCIAL=80;GUARANTEES_GIVEN=0',
                   @Approve = 0, @Basis = 'CONSOLIDATED';
    SELECT @s = v FROM #C WHERE k = 's';
    INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method, OwnershipPct)
    VALUES (@t, @s, @hold, 'PARENT', 'FULL', NULL), (@t, @s, @ind, 'SUBSIDIARY', 'FULL', 100);
    UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @s;
    UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @s;
    EXEC #CAssess @s, @AsOf = @AsOf, @Business = 'A3', @Policy = 'A3';
    SELECT @a = v FROM #C WHERE k = 'a';
    EXEC fin.usp_ComputeCreditAssessment @a;
    IF @Approve = 1
    BEGIN
        UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
        UPDATE fin.CreditAssessment SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
    END;
    DELETE FROM #C WHERE k = 'ha';
    INSERT #C (k, v) VALUES ('ha', @a);
END;
GO
/* CA6 (BR-FIN-022): IND lifted by its parent's support of two notches, never above the parent's grade; an override of
   one notch up or two down; an override of two up (547); support from a draft assessment, from a company that is
   neither the parent nor a holding that consolidates IND (50065), and from a parent assessment older than twelve
   months (50065, at the computation). */
CREATE PROCEDURE #SupportCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #C WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #C WHERE k = 'u1'), @u2 BIGINT = (SELECT v FROM #C WHERE k = 'u2'),
            @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'), @oth BIGINT = (SELECT v FROM #C WHERE k = 'oth'), @s BIGINT, @a BIGINT, @parent BIGINT, @pg VARCHAR(4);
    IF @Case = 6
    BEGIN
        EXEC #CStmt @oth, '2025-12-31';
        SELECT @s = v FROM #C WHERE k = 's';
        EXEC #CAssess @s;
        SELECT @parent = v FROM #C WHERE k = 'a';
        EXEC fin.usp_ComputeCreditAssessment @parent;
        UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @parent;
        UPDATE fin.CreditAssessment SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @parent;
    END
    ELSE
    BEGIN
        IF @Case = 5 EXEC #HoldAssessment @Approve = 0;
        ELSE IF @Case = 7 EXEC #HoldAssessment @AsOf = '2025-01-31';
        ELSE EXEC #HoldAssessment;
        SELECT @parent = v FROM #C WHERE k = 'ha';
        SELECT @pg = FinalGrade FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @parent;
    END;
    EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    IF @Case IN (1, 5, 6, 7)
        INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, Notches, ParentAssessmentId, Justification, EnteredBy)
        VALUES (@t, @a, 'GROUP_SUPPORT', 2, @parent, N'test: the parent''s support of its subsidiary', @u1);
    IF @Case IN (2, 3, 4)
        INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, Notches, Justification, EnteredBy)
        VALUES (@t, @a, 'OVERRIDE', CASE @Case WHEN 2 THEN 1 WHEN 3 THEN -2 ELSE 2 END, N'test: the analyst''s override', @u1);
    EXEC fin.usp_ComputeCreditAssessment @a;
    DECLARE @fg VARCHAR(4), @sg VARCHAR(4), @sn INT, @on INT;
    SELECT @fg = r.FinalGrade, @sg = r.StandaloneGrade, @sn = r.SupportNotches, @on = r.OverrideNotches FROM fin.v_CreditAssessmentReport AS r WHERE r.CreditAssessmentId = @a;
    SET @Out = CONCAT(CASE WHEN @Case = 1 THEN CONCAT(@pg COLLATE DATABASE_DEFAULT, N' ') END, @fg COLLATE DATABASE_DEFAULT, N'|', @sg COLLATE DATABASE_DEFAULT, N'|', @sn, N'|', @on);
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#SupportCase', 1, 7, @got OUTPUT;
IF @got = '1:0=Ba1 Ba1|Ba2|1| 2:0=Ba1|Ba2||1 3:0=B1|Ba2||-2 4:547 5:50065 6:50065 7:50065'
    PRINT 'PASS CA6: group support lifts a subsidiary only up to its parent''s grade, the override moves two down or one up, and support needs the parent''s recent approved assessment';
ELSE PRINT CONCAT('FAIL CA6: ', @got, ' (expected 1:0=Ba1 Ba1|Ba2|1| 2:0=Ba1|Ba2||1 3:0=B1|Ba2||-2 4:547 5:50065 6:50065 7:50065)');
GO
/* CA7 (BR-FIN-021, BR-FIN-024): the life of an assessment. A new one is a draft with no results (50063); it reads an
   approved statement, a rate for another currency and an earlier comparison (50064); it is submitted computed (547)
   on what it holds now (50063), and approved by someone other than its preparer (547); after the draft its inputs,
   its computation, its fields and every row of its results do not change (50065, 50063), and a rejection has a
   reason (547); one approved assessment per statement (2601); a qualitative grade far from the financial grade needs
   a document (50065); a sub-factor of another scorecard is refused (50065). The application role does not write the
   results (230 on a result column, 229 on the result tables). */
CREATE PROCEDURE #LifeCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #C WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #C WHERE k = 'u1'), @u2 BIGINT = (SELECT v FROM #C WHERE k = 'u2'),
            @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'), @s BIGINT, @s2 BIGINT, @a BIGINT, @b BIGINT,
            @card INT = (SELECT ScorecardId FROM fin.Scorecard WHERE Code = 'GENERAL_CORPORATE' AND Status = 'APPROVED');
    IF @Case = 3 EXEC #CStmt @ind, '2025-12-31', @Approve = 0;
    ELSE IF @Case = 4 EXEC #CStmt @ind, '2025-12-31', @Currency = 'USD';
    ELSE EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    IF @Case = 1
        INSERT fin.CreditAssessment (TenantId, CompanyId, StatementId, ScorecardId, AssessmentDate, ComputedAt) VALUES (@t, @ind, @s, @card, '2026-04-30', SYSUTCDATETIME());
    IF @Case = 2
        INSERT fin.CreditAssessment (TenantId, CompanyId, StatementId, ScorecardId, AssessmentDate, Status, RejectionReason) VALUES (@t, @ind, @s, @card, '2026-04-30', 'REJECTED', N'test');
    IF @Case = 5
    BEGIN
        EXEC #CStmt @ind, '2026-12-31';
        SELECT @s2 = v FROM #C WHERE k = 's';
        EXEC #CAssess @s, @Prior = @s2;
    END
    ELSE IF @Case = 16 EXEC #CAssess @s, @Business = 'Aaa';
    ELSE IF @Case > 2 EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    IF @Case IN (3, 4, 5, 16) EXEC fin.usp_ComputeCreditAssessment @a;
    IF @Case = 6 UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
    IF @Case = 19
        INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, MetricId, SubfactorId, GradeId, Justification, EnteredBy)
        SELECT TOP (1) @t, @a, 'SUBFACTOR', x.MetricId, x.ScorecardSubfactorId, (SELECT RatingGradeId FROM fin.RatingGrade WHERE Code = 'Baa1'), N'test: a sub-factor of another card', @u1
        FROM fin.ScorecardSubfactor AS x WHERE x.ScorecardId <> @card;
    IF @Case BETWEEN 7 AND 15 OR @Case IN (17, 18, 20, 21, 22)
    BEGIN
        EXEC fin.usp_ComputeCreditAssessment @a;
        IF @Case = 7 UPDATE fin.CreditAssessmentInput SET Justification = N'test: a justification changed after the computation' WHERE AssessmentId = @a;
        UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
        IF @Case = 8 UPDATE fin.CreditAssessment SET Status = 'APPROVED', ApprovedBy = @u1, ApprovedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
        IF @Case IN (9, 15) UPDATE fin.CreditAssessment SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
        IF @Case = 9 SELECT @Out = Status FROM fin.CreditAssessment WHERE CreditAssessmentId = @a;
        IF @Case = 10
            INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, Notches, Justification, EnteredBy) VALUES (@t, @a, 'OVERRIDE', 1, N'test: too late', @u1);
        IF @Case = 11 EXEC fin.usp_ComputeCreditAssessment @a;
        IF @Case = 12 UPDATE fin.CreditAssessment SET AssessmentDate = '2026-05-31' WHERE CreditAssessmentId = @a;
        IF @Case = 13 UPDATE fin.CreditAssessment SET Status = 'REJECTED' WHERE CreditAssessmentId = @a;
        IF @Case = 14 UPDATE fin.CreditAssessment SET Status = 'REJECTED', RejectionReason = N'test: rejected' WHERE CreditAssessmentId = @a;
        IF @Case = 14
        BEGIN
            UPDATE fin.CreditAssessment SET Status = 'DRAFT' WHERE CreditAssessmentId = @a;
            EXEC fin.usp_ComputeCreditAssessment @a;
            SELECT @Out = Status FROM fin.CreditAssessment WHERE CreditAssessmentId = @a;
        END;
        IF @Case = 17 DELETE fin.CreditAssessmentFinding WHERE AssessmentId = @a;
        IF @Case = 18 UPDATE fin.CreditAssessmentFactor SET Contribution = Contribution WHERE AssessmentId = @a;
        IF @Case = 20 DELETE fin.CreditAssessmentRemedy WHERE AssessmentId = @a;
        IF @Case = 21 DELETE fin.CreditAssessmentReclass WHERE AssessmentId = @a;
        IF @Case = 22 UPDATE fin.CreditAssessment SET StrengtheningRequested = 1 WHERE CreditAssessmentId = @a;
        IF @Case = 15
        BEGIN
            EXEC #CAssess @s;
            SELECT @b = v FROM #C WHERE k = 'a';
            EXEC fin.usp_ComputeCreditAssessment @b;
            UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @b;
            UPDATE fin.CreditAssessment SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @b;
        END;
    END;
END;
GO
DECLARE @got NVARCHAR(2000), @t INT, @a BIGINT, @s BIGINT, @ind BIGINT, @e1 INT = 0, @e2 INT = 0, @e3 INT = 0, @e4 INT = 0, @e5 INT = 0, @e6 INT = 0;
EXEC #CCases '#LifeCase', 1, 22, @got OUTPUT;
BEGIN TRANSACTION;
EXEC #Crd;
SELECT @t = v FROM #C WHERE k = 't'; SELECT @ind = v FROM #C WHERE k = 'ind';
EXEC #CStmt @ind, '2025-12-31';
SELECT @s = v FROM #C WHERE k = 's';
EXEC #CAssess @s;
SELECT @a = v FROM #C WHERE k = 'a';
EXEC fin.usp_ComputeCreditAssessment @a;
EXECUTE AS USER = N'tp_test_crdapp';
BEGIN TRY UPDATE fin.CreditAssessment SET FinalGradeId = (SELECT RatingGradeId FROM fin.RatingGrade WHERE Code = 'Aaa') WHERE CreditAssessmentId = @a; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT fin.CreditAssessmentFactor (TenantId, AssessmentId, MetricId, FactorCode, Weight, Status, Score, Reason)
          SELECT @t, @a, CreditMetricId, 'SCALE', 1, 'EXTREME', 0.5, N'test' FROM fin.CreditMetric WHERE Code = 'DSO'; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY DELETE fin.CreditAssessmentFinding WHERE AssessmentId = @a; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY DELETE fin.CreditAssessmentRemedy WHERE AssessmentId = @a; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE fin.CreditAssessment SET Outlook = 'POSITIVE' WHERE CreditAssessmentId = @a; END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH;
BEGIN TRY DELETE fin.CreditAssessmentTrigger WHERE AssessmentId = @a; END TRY BEGIN CATCH SET @e6 = ERROR_NUMBER(); END CATCH;
REVERT;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @got = '1:50063 2:50063 3:50064 4:50064 5:50064 6:547 7:50063 8:547 9:0=APPROVED 10:50065 11:50063 12:50063 13:547 14:0=DRAFT 15:2601 16:50065 17:50063 18:50063 19:50065 20:50063 21:50063 22:50063'
   AND @e1 = 230 AND @e2 = 229 AND @e3 = 229 AND @e4 = 229 AND @e5 = 230 AND @e6 = 229
    PRINT 'PASS CA7: an assessment is a draft until computed and submitted on what it holds, is approved by someone else, then does not change; the application cannot write its results';
ELSE PRINT CONCAT('FAIL CA7: ', @got, ' | application writes ', @e1, ' ', @e2, ' ', @e3, ' ', @e4, ' ', @e5, ' ', @e6, ' (expected 1:50063 2:50063 3:50064 4:50064 5:50064 6:547 7:50063 8:547 9:0=APPROVED 10:50065 11:50063 12:50063 13:547 14:0=DRAFT 15:2601 16:50065 17:50063 18:50063 19:50065 20:50063 21:50063 22:50063 | 230 229 229 229 230 229)');
GO
/* CA8 (FR-FIN-021, FR-FIN-023, FR-FIN-024): the report: the header with the disclaimer, the risk band, the Fitch
   equivalent and the summary; each line of the statement with its comparison, change, share and risk level; the
   register of the balance sheet items with their themes, weights and effects on cash and solvency; the factors with
   their factor names; the reconciliation with its texts; and an assessment that is no longer current once an input
   changes after its computation. */
DECLARE @s BIGINT, @a BIGINT, @ind BIGINT, @items NVARCHAR(600), @n INT, @nf INT, @nk INT, @head NVARCHAR(400), @cur1 INT, @cur2 INT, @reg NVARCHAR(400),
        @nreg INT, @rec NVARCHAR(600);
BEGIN TRANSACTION;
EXEC #Crd;
SELECT @ind = v FROM #C WHERE k = 'ind';
EXEC #CStmt @ind, '2025-12-31';
SELECT @s = v FROM #C WHERE k = 's';
EXEC #CAssess @s;
SELECT @a = v FROM #C WHERE k = 'a';
EXEC fin.usp_ComputeCreditAssessment @a;
SELECT @items = STRING_AGG(CONCAT(LineCode, ':', ChangePct, ':', SharePct, ':', ISNULL(RiskLevel, '-')), ' ') WITHIN GROUP (ORDER BY SortOrder),
       @n = (SELECT COUNT(*) FROM fin.v_CreditAssessmentItems WHERE AssessmentId = @a)
FROM fin.v_CreditAssessmentItems WHERE AssessmentId = @a AND LineCode IN ('CASH','AR','TOTAL_ASSETS','REVENUE','ST_LOANS');
SELECT @nf = COUNT(*) FROM fin.v_CreditAssessmentFactors WHERE AssessmentId = @a AND FactorNameAr IS NOT NULL;
SELECT @nk = COUNT(*) FROM fin.v_CreditAssessmentFindings WHERE AssessmentId = @a AND KindAr IS NOT NULL;
SELECT @nreg = COUNT(*), @reg = STRING_AGG(CASE WHEN MetricCode IN ('DSO','CURRENT_RATIO') THEN CONCAT(MetricCode, '/', LineCode, ':', ThemeCode, ':', ISNULL(RiskLevel, '-'), ':',
                                                CASE WHEN CashEffectAr IS NOT NULL AND SolvencyEffectAr IS NOT NULL THEN 'effects' END) END, ' ') WITHIN GROUP (ORDER BY MetricCode, LineCode)
FROM fin.v_CreditAssessmentItemRegister WHERE AssessmentId = @a;
SELECT @rec = STRING_AGG(CONCAT(AdjCode, ':', Bucket, ':', CAST(Amount / 1000000 AS DECIMAL(9,2)), CASE WHEN AdjNameAr IS NOT NULL THEN ':text' END), ' ') WITHIN GROUP (ORDER BY SeqNo)
FROM fin.v_CreditAssessmentReclass WHERE AssessmentId = @a;
SELECT @head = CONCAT(FinalGrade, ' ', FitchGrade, ' ', RiskBand, ' ', CASE WHEN DisclaimerAr LIKE N'%موديز%' THEN 'disclaimer' END, ' ',
                      CASE WHEN SummaryAr LIKE CONCAT(N'الدرجة النهائية ', FinalGrade, N'%') THEN 'summary' END, ' ', CompanyNameEn, ' ', ScorecardCode, ' ', LiquidityNameEn),
       @cur1 = CAST(IsCurrent AS INT)
FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
UPDATE fin.CreditAssessmentInput SET Justification = N'test: changed after the computation' WHERE AssessmentId = @a AND Kind = 'QUALITATIVE';
SELECT @cur2 = CAST(IsCurrent AS INT) FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @items = 'CASH:0.0000:4.5000:HIGH AR:0.0000:16.0000:MODERATE TOTAL_ASSETS:6.3830:100.0000:HIGH ST_LOANS:0.0000:12.0000:CRITICAL REVENUE:5.8824:100.0000:LOW'
   AND @n = 47 AND @nf = 17 AND @nk > 0 AND @head = 'Ba2 BB SUBSTANTIAL disclaimer summary Industrial GENERAL_CORPORATE Adequate liquidity relying on renewals' AND @nreg = 134
   AND @reg = 'CURRENT_RATIO/OTHER_CL:LIQUIDITY:ELEVATED:effects CURRENT_RATIO/TOTAL_CA:LIQUIDITY:ELEVATED:effects DSO/AR:RECEIVABLES:MODERATE:effects'
   AND @rec = 'ADJ_RELATED:NOT_TNW:20.00:text ADJ_INTANGIBLES:NOT_TNW:30.00:text ADJ_RELATED_DEBT:ST_DEBT:10.00:text ADJ_LEASE:DEBT:20.00:text ADJ_EOSB:DEBT:18.00:text'
   AND @cur1 = 1 AND @cur2 = 0
    PRINT 'PASS CA8: the report gives the grade with its band, Fitch equivalent, summary and disclaimer, each line with its change, share and risk level, the item register and the reconciliation, and whether it is still current';
ELSE PRINT CONCAT('FAIL CA8: items ', @items, ' | lines ', @n, ' factors ', @nf, ' findings ', @nk, ' | ', @head, ' | register ', @nreg, ' ', @reg, ' | reclass ', @rec, ' | current ', @cur1, '/', @cur2);
GO
/* CA9 fixture: a facility of IND with bank 1 at 100 percent and revision 1 approved, with two covenants: a current ratio
   of at least 1.2 on IND's standalone statements, whose 2025 test is evaluated as a breach on statement 's' (actual
   1.085714) with an open breach record, waived on request when @Waiver = 1; and liquidity of at least 12,000,000 SAR
   a fiscal year routed to the bank, of which 2,000,000 is confirmed by the end of March 2026. */
CREATE PROCEDURE #CCov @Waiver BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #C WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #C WHERE k = 'u1'), @u2 BIGINT = (SELECT v FROM #C WHERE k = 'u2'),
            @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'), @s BIGINT = (SELECT v FROM #C WHERE k = 's'),
            @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR'), @f BIGINT, @ot INT, @ob BIGINT, @fr BIGINT, @crt BIGINT, @ct BIGINT, @lst INT, @kind INT;
    ALTER TABLE fac.Facility NOCHECK CONSTRAINT FK_Facility_FacilityTypeId;
    ALTER TABLE fac.FacilityLender NOCHECK CONSTRAINT FK_FacilityLender_InstitutionId;
    ALTER TABLE fin.BankFlowEntry NOCHECK CONSTRAINT FK_BankFlowEntry_InstitutionId;
    INSERT cat.LookupList (TenantId, Code, NameAr, NameEn, Scope) VALUES (@t, 'FLOW_KIND', N'أنواع التحويل', N'Flow kinds', 'TENANT');
    SET @lst = SCOPE_IDENTITY();
    INSERT cat.LookupItem (TenantId, LookupListId, Code, NameAr) VALUES (@t, @lst, 'TRANSFERRED_TO_BANK', N'محوَّل للبنك');
    SET @kind = SCOPE_IDENTITY();
    INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
    VALUES (@t, 'FAC-26-201', @ind, 1, @cur, 50000000, 'EN', '2026-01-01', '2027-12-31');
    SET @f = SCOPE_IDENTITY();
    INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (@t, @f, 1, 'LEAD', 100, 1);
    INSERT cat.ObligationType (TenantId, Code, NameAr, Family, MeasureKind) VALUES (@t, 'COV', N'تعهد', 'COVENANT', 'RATIO');
    SET @ot = SCOPE_IDENTITY();
    INSERT obl.Obligation (TenantId, FacilityId, Family, ObligationTypeId, TitleAr, ClauseRef, ValidFrom, NoSourceReason)
    VALUES (@t, @f, 'COVENANT', @ot, N'تعهدات مالية', N'14.2', '2026-01-01', N'test fixture');
    SET @ob = SCOPE_IDENTITY();
    INSERT fin.MeasureFormula (TenantId, Code, NameAr, NameEn, Scope, FacilityId, Expression, InputKinds, ResultUnit, VersionNo, Status, ApprovedBy, ApprovedOn, NoSourceReason)
    VALUES (@t, 'CURRENT_RATIO', N'نسبة التداول', N'Current ratio', 'FACILITY_COPY', @f, 'TOTAL_CA / TOTAL_CL', 'STATEMENT', 'RATIO', 1, 'APPROVED', @u2, SYSUTCDATETIME(), N'test fixture');
    SET @fr = SCOPE_IDENTITY();
    INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, Operator, ThresholdState, ThresholdValue, ThresholdUnit, CurrencyId, TestFrequency,
                         AnnualWindowBasis, TestedCompanyId, FirstTestPeriodEnd, ValidFrom)
    VALUES (@t, @ob, 'FLOW_VOLUME', 'GE', 'SET', 12000000, 'AMOUNT', @cur, 'ANNUAL', 'FISCAL_YEAR', @ind, '2026-12-31', '2026-01-01');
    INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, FormulaId, FormulaResultUnit, FormulaUsesStatements, Operator, ThresholdState, ThresholdValue,
                         ThresholdUnit, TestFrequency, StatementBasis, RequiredAssurance, TestedCompanyId, FirstTestPeriodEnd, ValidFrom)
    VALUES (@t, @ob, 'RATIO', @fr, 'RATIO', 1, 'GE', 'SET', 1.2, 'RATIO', 'ANNUAL', 'STANDALONE', 'ANY', @ind, '2025-12-31', '2025-06-01');
    SET @crt = SCOPE_IDENTITY();
    INSERT fac.FacilityRevision (TenantId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn, SubmittedBy, SubmittedOn, ApprovedBy, ApprovedOn)
    VALUES (@t, @f, 1, 'INITIAL', 'APPROVED', '2026-01-01', @u1, SYSUTCDATETIME(), @u2, SYSUTCDATETIME());
    UPDATE fac.Facility SET ApprovedRevisionNo = 1 WHERE FacilityId = @f;
    INSERT obl.CovenantTest (TenantId, CovenantId, CovenantRootId, PeriodStart, PeriodEnd, DueDate, Method)
    VALUES (@t, @crt, (SELECT RootId FROM obl.Covenant WHERE CovenantId = @crt), '2025-01-01', '2025-12-31', '2026-03-31', 'AUTO');
    SET @ct = SCOPE_IDENTITY();
    UPDATE obl.CovenantTest
    SET State = 'EVALUATED', Result = 'BREACH', ActualValue = 1.085714, ThresholdApplied = 1.2, OperatorApplied = 'GE', Headroom = 1.085714 - 1.2,
        HeadroomPct = (1.085714 - 1.2) * 100 / 1.2, FormulaId = @fr, EvaluatedAt = SYSUTCDATETIME(),
        InputsSnapshot = CONCAT(N'{"formula":{"id":', @fr, N',"version":1},"threshold":{"value":1.2,"operator":"GE"},"statements":[{"statementId":', @s,
                                N',"version":1,"basis":"STANDALONE"}]}')
    WHERE CovenantTestId = @ct;
    INSERT obl.ObligationBreach (TenantId, ObligationId, ObligationRootId, Kind, CovenantTestId, CovenantRootId, TestPeriodEnd, DetectedOn, WaiverRef)
    VALUES (@t, @ob, (SELECT RootId FROM obl.Obligation WHERE ObligationId = @ob), 'COVENANT_BREACH', @ct, (SELECT RootId FROM obl.Covenant WHERE CovenantId = @crt),
            '2025-12-31', '2026-04-01', CASE WHEN @Waiver = 1 THEN N'W-2026-01' END);
    INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy, Status, ConfirmedBy, ConfirmedOn)
    VALUES (@t, @ind, 1, '2026-01-31', @lst, @kind, 1000000, @cur, @u1, 'CONFIRMED', @u2, SYSUTCDATETIME()),
           (@t, @ind, 1, '2026-03-31', @lst, @kind, 1000000, @cur, @u1, 'CONFIRMED', @u2, SYSUTCDATETIME());
END;
GO
/* CA9 (FR-FIN-022, FR-FIN-018, docs/35 sections 8 and 9): the assessment reads the covenants and the bank flows. The
   breach found on the assessed statement is a critical risk and listed with its breach record; an open breach without
   a waiver request costs two notches, with a request one; liquidity routed to the bank behind its covenant is a point
   to watch, and a shortfall of more than a quarter of what is due to date one notch more. */
CREATE PROCEDURE #CovCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'), @w BIT = CASE WHEN @Case = 2 THEN 1 ELSE 0 END;
    EXEC #CStmt @ind, '2025-12-31';
    EXEC #CCov @w;
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    EXEC fin.usp_ComputeCreditAssessment @a;
    SELECT @Out = CONCAT(r.FinalGrade, '|', r.StandaloneGrade, '|',
                         (SELECT STRING_AGG(x.RuleCode, ',') WITHIN GROUP (ORDER BY x.RuleCode)
                          FROM fin.CreditAssessmentFinding AS x WHERE x.AssessmentId = @a AND x.Kind = 'ADJUSTMENT' AND x.Source = 'ADJUSTMENT'), ' ',
                         (SELECT STRING_AGG(CONCAT(Source, ':', RuleCode, ':', Kind), ',') WITHIN GROUP (ORDER BY Source, RuleCode)
                          FROM fin.CreditAssessmentFinding WHERE AssessmentId = @a AND Source IN ('COVENANT','BANK_FLOW')), ' ',
                         (SELECT STRING_AGG(CONCAT(Result, ':', BreachStatus), ',') FROM fin.v_CreditAssessmentCovenants WHERE AssessmentId = @a))
    FROM fin.v_CreditAssessmentReport AS r WHERE r.CreditAssessmentId = @a;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#CovCase', 1, 2, @got OUTPUT;
IF @got = '1:0=B1|B1|FLOW_SHORTFALL,INFORMATION_RISK,INFORMATION_RISK_SEVERE,OPEN_BREACH BANK_FLOW:FLOW_BEHIND:WATCH,COVENANT:COVENANT_BREACH:CRITICAL_RISK BREACH:OPEN 2:0=B1|B1|BREACH_WAIVER_REQUESTED,FLOW_SHORTFALL,INFORMATION_RISK,INFORMATION_RISK_SEVERE BANK_FLOW:FLOW_BEHIND:WATCH,COVENANT:COVENANT_BREACH:CRITICAL_RISK BREACH:OPEN'
    PRINT 'PASS CA9: a breach on the assessed statement is a critical risk, open breaches cost two notches or one with a waiver request, and a bank flow shortfall one more';
ELSE PRINT CONCAT('FAIL CA9: ', @got, ' (expected 1:0=B1|B1|FLOW_SHORTFALL,INFORMATION_RISK,INFORMATION_RISK_SEVERE,OPEN_BREACH BANK_FLOW:FLOW_BEHIND:WATCH,COVENANT:COVENANT_BREACH:CRITICAL_RISK BREACH:OPEN 2:0=B1|B1|BREACH_WAIVER_REQUESTED,FLOW_SHORTFALL,INFORMATION_RISK,INFORMATION_RISK_SEVERE BANK_FLOW:FLOW_BEHIND:WATCH,COVENANT:COVENANT_BREACH:CRITICAL_RISK BREACH:OPEN)');
GO
/* CA10 (BR-FIN-023, BR-FIN-018): the platform's methodology does not change once approved. An approved scorecard's
   metrics, item rules, adjustments, parameters, sub-factors and fields are fixed and it only retires (50066); a
   scorecard is approved whole: weights of 100 and each grid in its metric's direction (50066), a grid that is not
   monotonic is refused at once (547); the grades keep their notch but not necessarily their description; a metric an
   approved scorecard uses keeps its definition. */
CREATE PROCEDURE #CardCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @gen INT = (SELECT ScorecardId FROM fin.Scorecard WHERE Code = 'GENERAL_CORPORATE' AND Status = 'APPROVED'),
            @rev INT = (SELECT CreditMetricId FROM fin.CreditMetric WHERE Code = 'REVENUE_SIZE'),
            @sar INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR'), @new INT;
    IF @Case = 1 UPDATE fin.ScorecardMetric SET Weight = 11 WHERE ScorecardId = @gen AND MetricId = @rev;
    IF @Case = 2 UPDATE fin.Scorecard SET NameAr = N'تجربة' WHERE ScorecardId = @gen;
    IF @Case = 3
    BEGIN
        UPDATE fin.Scorecard SET Status = 'RETIRED' WHERE ScorecardId = @gen;
        UPDATE fin.Scorecard SET Status = 'APPROVED' WHERE ScorecardId = @gen;
    END;
    IF @Case IN (4, 5, 6, 11)
    BEGIN
        INSERT fin.Scorecard (Code, VersionNo, NameAr, NameEn, CurrencyId, AmountUnit, MinCoveragePct, Status, DisclaimerAr, DisclaimerEn)
        VALUES ('TEST_CARD', 1, N'تجربة', N'Test', @sar, 1000000, 85, 'DRAFT', N'تجربة', N'Test');
        SET @new = SCOPE_IDENTITY();
        INSERT fin.ScorecardMetric (ScorecardId, MetricId, FactorCode, Weight, B0, B1, B2, B3, B4, B5, B6, B7, B8)
        SELECT @new, @rev, 'SCALE', CASE WHEN @Case = 4 THEN 50 ELSE 100 END, g.B0, g.B1, g.B2, g.B3, g.B4, g.B5, g.B6, g.B7, g.B8
        FROM (VALUES (4, 150000, 75000, 30000, 10000, 3000, 750, 100, 20, 2), (11, 150000, 75000, 30000, 10000, 3000, 750, 100, 20, 2),
                     (5, 2, 20, 100, 750, 3000, 10000, 30000, 75000, 150000), (6, 150000, 75000, 30000, 10000, 3000, 750, 100, 200, 2))
             AS g (c, B0, B1, B2, B3, B4, B5, B6, B7, B8)
        WHERE g.c = @Case;
        UPDATE fin.Scorecard SET Status = 'APPROVED', EffectiveFrom = '2026-10-18' WHERE ScorecardId = @new;
        IF @Case = 11 SELECT @Out = Status FROM fin.Scorecard WHERE ScorecardId = @new;
    END;
    IF @Case = 7 UPDATE fin.RatingGrade SET ScoreFrom = 19.6 WHERE Code = 'Ca';
    IF @Case = 8 UPDATE fin.RatingGrade SET DescriptionAr = N'وصف' WHERE Code = 'Baa3';
    IF @Case = 9 UPDATE fin.CreditMetric SET DefinitionAr = N'تعريف آخر' WHERE CreditMetricId = @rev;
    IF @Case = 10 UPDATE fin.ScorecardItemRule SET T1 = 50 WHERE ScorecardId = @gen AND MetricId = (SELECT CreditMetricId FROM fin.CreditMetric WHERE Code = 'DSO');
    IF @Case = 12 UPDATE fin.ScorecardAdjustment SET ParamValue = 18 WHERE ScorecardId = @gen AND RuleCode = 'STALE_STATEMENT';
    IF @Case = 13 UPDATE fin.ScorecardParameter SET Value = 50 WHERE ScorecardId = @gen AND GroupCode = 'CARD' AND ParamKey = 'unsecured_recovery_pct';
    IF @Case = 14 DELETE fin.ScorecardSubfactor WHERE ScorecardId = @gen;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#CardCase', 1, 14, @got OUTPUT;
IF @got = '1:50066 2:50066 3:50066 4:50066 5:50066 6:547 7:50066 8:0 9:50066 10:50066 11:0=APPROVED 12:50066 13:50066 14:50066'
    PRINT 'PASS CA10: an approved scorecard, its parameters and sub-factors, and the grades and metrics it uses do not change, and a scorecard is approved whole';
ELSE PRINT CONCAT('FAIL CA10: ', @got, ' (expected 1:50066 2:50066 3:50066 4:50066 5:50066 6:547 7:50066 8:0 9:50066 10:50066 11:0=APPROVED 12:50066 13:50066 14:50066)');
GO
/* CA11 (tenant isolation): another tenant sees none of the assessment, its factors, findings, remedies or
   reconciliation, and cannot compute it (50064). */
DECLARE @s BIGINT, @a BIGINT, @ind BIGINT, @t2 INT, @n1 INT = -1, @n2 INT = -1, @n3 INT = -1, @n4 INT = -1, @n5 INT = -1, @e INT = 0,
        @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'), @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA');
BEGIN TRANSACTION;
EXEC #Crd;
SELECT @ind = v FROM #C WHERE k = 'ind';
EXEC #CStmt @ind, '2025-12-31';
SELECT @s = v FROM #C WHERE k = 's';
EXEC #CAssess @s;
SELECT @a = v FROM #C WHERE k = 'a';
EXEC fin.usp_ComputeCreditAssessment @a;
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('tst-crd2', N'م', N'Crd2', @plan, @country, 'ACTIVE', 'UTC');
SET @t2 = SCOPE_IDENTITY();
EXEC #CBind @t2, 0;
EXECUTE AS USER = N'tp_test_crdapp';
SELECT @n1 = COUNT(*) FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
SELECT @n2 = COUNT(*) FROM fin.CreditAssessmentFactor WHERE AssessmentId = @a;
SELECT @n3 = COUNT(*) FROM fin.CreditAssessmentFinding WHERE AssessmentId = @a;
SELECT @n4 = COUNT(*) FROM fin.v_CreditAssessmentRemedies WHERE AssessmentId = @a;
SELECT @n5 = COUNT(*) FROM fin.v_CreditAssessmentReclass WHERE AssessmentId = @a;
-- The refused computation leaves the transaction uncommittable: roll it back before reverting the user.
BEGIN TRY EXEC fin.usp_ComputeCreditAssessment @a; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
REVERT;
IF @n1 = 0 AND @n2 = 0 AND @n3 = 0 AND @n4 = 0 AND @n5 = 0 AND @e = 50064
    PRINT 'PASS CA11: another tenant sees nothing of an assessment and cannot compute it';
ELSE PRINT CONCAT('FAIL CA11: report ', @n1, ', factors ', @n2, ', findings ', @n3, ', remedies ', @n4, ', reclass ', @n5, ', compute ', @e, ' (expected 0, 0, 0, 0, 0, 50064)');
GO
/* CA12 (db/seed/104): the methodology as tools/dbgen/credit_scorecard.json gives it: 21 grades with Baa3 the last
   investment grade, the standard lines, the metric dictionary, the activities with their profiles and sensitivities,
   the macro scenarios, the countries with their regions and the risk anchor, the product categories, the remedies, the
   strengthening plans and the report texts; sixteen approved sector family scorecards
   whose weights add up to 100 with a grid for each quantitative metric, their item rules and adjustments; the
   sovereign ceiling at Aa3 and the contracting ceiling on its own scorecard. */
DECLARE @got NVARCHAR(1000) = CONCAT(
    (SELECT COUNT(*) FROM fin.RatingGrade), ' ', (SELECT COUNT(*) FROM fin.RatingGrade WHERE IsInvestmentGrade = 1), ' ',
    (SELECT MAX(Code) FROM fin.RatingGrade WHERE NotchNo = 10 AND IsInvestmentGrade = 1), ' ',
    (SELECT COUNT(*) FROM fin.StandardLine), ' ', (SELECT COUNT(*) FROM fin.CreditMetric), ' ',
    (SELECT COUNT(*) FROM fin.IndustryProfile), ' ', (SELECT COUNT(*) FROM fin.IndustrySensitivity), ' ', (SELECT COUNT(*) FROM fin.MacroScenario), ' ',
    (SELECT COUNT(*) FROM fin.MacroScenarioIntensity), ' ', (SELECT COUNT(*) FROM fin.MacroScenarioCountry), ' ',
    (SELECT COUNT(*) FROM fin.CountryRiskProfile), ' ', (SELECT COUNT(*) FROM fin.CountryRegion), ' ',
    (SELECT COUNT(*) FROM fin.RiskAnchor), ' ', (SELECT COUNT(*) FROM fin.ProductCategory), ' ',
    (SELECT COUNT(*) FROM fin.CreditRemedy), ' ', (SELECT COUNT(*) FROM fin.StrengtheningPlan), ' ', (SELECT COUNT(*) FROM fin.CreditText), ' ',
    (SELECT STRING_AGG(CONCAT(sc.Code, ':', w.W, ':', w.Grids, ':', r.Items, ':', ad.Adj), ' ') WITHIN GROUP (ORDER BY sc.Code)
     FROM fin.Scorecard AS sc
     CROSS APPLY (SELECT CAST(SUM(sm.Weight) AS INT) AS W, SUM(CASE WHEN m.Kind = 'QUANTITATIVE' AND sm.B0 IS NOT NULL THEN 1 WHEN m.Kind = 'QUALITATIVE' AND sm.B0 IS NULL THEN 1 ELSE 0 END) AS Grids
                  FROM fin.ScorecardMetric AS sm JOIN fin.CreditMetric AS m ON m.CreditMetricId = sm.MetricId WHERE sm.ScorecardId = sc.ScorecardId) AS w
     CROSS APPLY (SELECT COUNT(*) AS Items FROM fin.ScorecardItemRule AS i WHERE i.ScorecardId = sc.ScorecardId) AS r
     CROSS APPLY (SELECT COUNT(*) AS Adj FROM fin.ScorecardAdjustment AS a WHERE a.ScorecardId = sc.ScorecardId) AS ad
     WHERE sc.Status = 'APPROVED'), ' ',
    (SELECT MIN(g.Code) FROM fin.ScorecardAdjustment AS a JOIN fin.RatingGrade AS g ON g.RatingGradeId = a.CapGradeId WHERE a.RuleCode = 'SOVEREIGN_CEILING'), ' ',
    (SELECT STRING_AGG(sc.Code, ',') FROM fin.ScorecardAdjustment AS a JOIN fin.Scorecard AS sc ON sc.ScorecardId = a.ScorecardId WHERE a.RuleCode = 'SECTOR_CEILING'));
IF @got = '21 10 Baa3 157 112 368 2576 7 49 8 23 127 36 15 39 10 70 AUTOMOTIVE_DISTRIBUTION:100:18:134:44 AVIATION:100:17:134:44 BUILDING_MATERIALS_MFG:100:18:134:44 BUILDING_MATERIALS_TRADE:100:16:134:44 BUSINESS_SERVICES:100:18:134:44 CONTRACTING:100:18:134:45 FOOD_BEVERAGE_MFG:100:18:134:44 GENERAL_CORPORATE:100:17:134:44 HEALTHCARE_PHARMA:100:18:134:44 HOSPITALITY_TOURISM:100:18:134:44 PROPERTY_DEVELOPMENT:100:18:134:44 PROPERTY_INVESTMENT:100:17:134:44 RESTAURANTS_FOOD_SERVICE:100:17:134:44 RETAIL:100:17:134:44 TRADING_DISTRIBUTION:100:18:134:44 TRANSPORT_LOGISTICS:100:18:134:44 Aa3 CONTRACTING'
    PRINT 'PASS CA12: the platform seed holds the scale, the lines, the metrics, the activities, the products, the remedies, the plans, the texts and the sixteen approved sector family scorecards of the methodology';
ELSE PRINT CONCAT('FAIL CA12: ', @got, ' (expected 21 10 Baa3 157 112 368 2576 7 49 8 23 127 36 15 39 10 70 AUTOMOTIVE_DISTRIBUTION:100:18:134:44 AVIATION:100:17:134:44 BUILDING_MATERIALS_MFG:100:18:134:44 BUILDING_MATERIALS_TRADE:100:16:134:44 BUSINESS_SERVICES:100:18:134:44 CONTRACTING:100:18:134:45 FOOD_BEVERAGE_MFG:100:18:134:44 GENERAL_CORPORATE:100:17:134:44 HEALTHCARE_PHARMA:100:18:134:44 HOSPITALITY_TOURISM:100:18:134:44 PROPERTY_DEVELOPMENT:100:18:134:44 PROPERTY_INVESTMENT:100:17:134:44 RESTAURANTS_FOOD_SERVICE:100:17:134:44 RETAIL:100:17:134:44 TRADING_DISTRIBUTION:100:18:134:44 TRANSPORT_LOGISTICS:100:18:134:44 Aa3 CONTRACTING)');
GO
/* CA13 fixture: IND's facility on the platform (revision 1 approved, bank 1 at 100 percent), a committed root limit of
   @Limit million SAR, an active utilisation of @Used million, and its collateral: a property covering @Property million
   and the joint guarantee of an individual partner covering the whole limit; the partner as guarantor with a net worth
   statement; and, when @Bureau = 1, a SIMAH report of the company. */
CREATE PROCEDURE #CPlatform @Limit INT = 300, @Used INT = 250, @Property INT = 200, @Bureau BIT = 0, @Expiry DATE = '2027-12-31'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #C WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #C WHERE k = 'u1'), @u2 BIGINT = (SELECT v FROM #C WHERE k = 'u2'),
            @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'), @a BIGINT = (SELECT v FROM #C WHERE k = 'a'),
            @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR'), @f BIGINT, @l BIGINT, @pp BIGINT, @tp INT, @tg INT, @cp BIGINT, @cg BIGINT;
    ALTER TABLE fac.Facility NOCHECK CONSTRAINT FK_Facility_FacilityTypeId;
    ALTER TABLE fac.FacilityLender NOCHECK CONSTRAINT FK_FacilityLender_InstitutionId;
    ALTER TABLE fac.Limit NOCHECK CONSTRAINT FK_Limit_LimitTypeId;
    ALTER TABLE fin.CreditAssessmentGuarantor NOCHECK CONSTRAINT FK_CreditAssessmentGuarantor_DocumentId;
    ALTER TABLE fin.CreditAssessmentBureau NOCHECK CONSTRAINT FK_CreditAssessmentBureau_DocumentId;
    ALTER TABLE fin.CreditAssessmentFacility NOCHECK CONSTRAINT FK_CreditAssessmentFacility_LenderInstitutionId;
    INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
    VALUES (@t, 'FAC-26-301', @ind, 1, @cur, @Limit * 1000000.0, 'EN', '2026-01-01', @Expiry);
    SET @f = SCOPE_IDENTITY();
    INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (@t, @f, 1, 'SOLE', 100, 1);
    INSERT fac.Limit (TenantId, FacilityId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, IsCommitted, FromRevision, NoSourceReason)
    VALUES (@t, @f, 1, 'L1', N'حد', 'ABSOLUTE', @Limit * 1000000.0, 1, 1, 1, N'test fixture');
    SET @l = SCOPE_IDENTITY();
    INSERT fac.Utilization (TenantId, FacilityId, LimitId, CompanyId, Reference, Amount, CurrencyId, StartDate)
    VALUES (@t, @f, @l, @ind, N'test utilisation', @Used * 1000000.0, @cur, '2026-02-01');
    INSERT pty.Party (TenantId, PartyCode, Kind, NameEn) VALUES (@t, 'P-PARTNER', 'INDIVIDUAL', N'Partner');
    SET @pp = SCOPE_IDENTITY();
    INSERT cat.CollateralType (TenantId, Code, NameAr, StructureKind) VALUES (@t, 'PROPERTY', N'عقار', 'REAL_ESTATE'), (@t, 'GUAR', N'كفالة', 'GUARANTEE');
    SELECT @tp = CollateralTypeId FROM cat.CollateralType WHERE TenantId = @t AND Code = 'PROPERTY';
    SELECT @tg = CollateralTypeId FROM cat.CollateralType WHERE TenantId = @t AND Code = 'GUAR';
    INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr, NoSourceReason) VALUES (@t, 'REAL_ESTATE', @tp, N'عقار', N'test fixture');
    SET @cp = SCOPE_IDENTITY();
    INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr, NoSourceReason) VALUES (@t, 'GUARANTEE', @tg, N'كفالة الشريك', N'test fixture');
    SET @cg = SCOPE_IDENTITY();
    INSERT col.Guarantee (TenantId, CollateralId, GuarantorPartyId, GuaranteeForm, IsJointSeveral, AmountMode)
    VALUES (@t, @cg, @pp, 'JOINT_SEVERAL_PAYMENT_PERFORMANCE', 1, 'UNSPECIFIED');
    UPDATE col.Collateral SET ApprovalState = 'APPROVED', Status = 'ACTIVE', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE CollateralId IN (@cp, @cg);
    IF @Property > 0
        INSERT col.CollateralLink (TenantId, CollateralId, FacilityId, CoverageAmount, LinkedOn, FromRevision) VALUES (@t, @cp, @f, @Property * 1000000.0, '2026-01-01', 1);
    INSERT col.CollateralLink (TenantId, CollateralId, FacilityId, CoverageAmount, LinkedOn, FromRevision) VALUES (@t, @cg, @f, @Limit * 1000000.0, '2026-01-01', 1);
    INSERT fac.FacilityRevision (TenantId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn, SubmittedBy, SubmittedOn, ApprovedBy, ApprovedOn)
    VALUES (@t, @f, 1, 'INITIAL', 'APPROVED', '2026-01-01', @u1, SYSUTCDATETIME(), @u2, SYSUTCDATETIME());
    UPDATE fac.Facility SET ApprovedRevisionNo = 1, LifecycleStatus = 'ACTIVE' WHERE FacilityId = @f;
    INSERT fin.CreditAssessmentGuarantor (TenantId, AssessmentId, PartyId, NetWorth, LiquidAssets, GuaranteesGiven, GuaranteedAmount, AsOfDate, DocumentId)
    VALUES (@t, @a, @pp, 400000000, 150000000, 40000000, @Limit * 1000000.0, '2026-03-31', 1);
    IF @Bureau = 1
        INSERT fin.CreditAssessmentBureau (TenantId, AssessmentId, ReportDate, DocumentId, TotalLimits, TotalOutstanding, LenderCount, WorstDpd12m, WorstDpd24m,
                                           BouncedCheques12mCount, BouncedCheques12mAmount, Inquiries6m)
        VALUES (@t, @a, '2026-03-15', 1, 500000000, 520000000, 3, 35, 35, 1, 100000, 2);
END;
GO
/* CA13 (FR-FIN-027, BR-FIN-027, docs/35 section 10): the company's facilities and collateral on the platform on the
   assessment date give the facility grade by the loss given default after the haircuts of each kind of collateral (a
   guarantee of an individual is a personal guarantee) and the guarantor's solvency; the platform's committed undrawn
   lines join the liquidity sources; the SIMAH report brings its own adjustments and the debt outside the statement. */
CREATE PROCEDURE #PlatformCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind');
    EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    IF @Case = 1 EXEC #CPlatform;
    IF @Case = 2 EXEC #CPlatform @Property = 0;
    IF @Case = 3 EXEC #CPlatform @Bureau = 1;
    EXEC fin.usp_ComputeCreditAssessment @a;
    SELECT @Out = CONCAT(r.FinalGrade, ' ', r.FacilityGrade, ' ', r.LgdPct, ' ', r.LgdBand, ' ', r.FitchRecoveryRating, ' ', r.LiquidityLabel, ' | ',
                         (SELECT STRING_AGG(CONCAT(CAST(LimitAmount / 1000000 AS INT), '/', CAST(OutstandingAmount / 1000000 AS INT), '/', CAST(SecuredCover / 1000000 AS INT), '/',
                                                   CAST(RecoverableCover / 1000000 AS INT), '/', CAST(IsCommitted AS INT)), ',') FROM fin.v_CreditAssessmentFacilities WHERE AssessmentId = @a),
                         ' | ', (SELECT STRING_AGG(x.RuleCode, ',') WITHIN GROUP (ORDER BY x.RuleCode)
                                 FROM fin.CreditAssessmentFinding AS x WHERE x.AssessmentId = @a AND x.Kind = 'ADJUSTMENT' AND x.Source = 'ADJUSTMENT'))
    FROM fin.v_CreditAssessmentReport AS r WHERE r.CreditAssessmentId = @a;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#PlatformCase', 1, 3, @got OUTPUT;
IF @got = '1:0=Ba2 Ba1 39.00 LGD3 RR3 SGL-2 | 300/250/500/120/1 | INFORMATION_RISK,INFORMATION_RISK_SEVERE 2:0=Ba2 Ba2 65.00 LGD4 RR4 SGL-2 | 300/250/300/0/1 | INFORMATION_RISK,INFORMATION_RISK_SEVERE 3:0=B1 Ba3 39.00 LGD3 RR3 SGL-2 | 300/250/500/120/1 | BUREAU_DPD30_59,BUREAU_HIDDEN_DEBT,BUREAU_LENDERS_NOT_ON_PLATFORM,INFORMATION_RISK,INFORMATION_RISK_SEVERE'
    PRINT 'PASS CA13: the facilities, collateral and guarantor on the platform give the facility grade, and the SIMAH report its adjustments, as the reference computes them';
ELSE PRINT CONCAT('FAIL CA13: ', @got, ' (expected 1:0=Ba2 Ba1 39.00 LGD3 RR3 SGL-2 | 300/250/500/120/1 | INFORMATION_RISK,INFORMATION_RISK_SEVERE 2:0=Ba2 Ba2 65.00 LGD4 RR4 SGL-2 | 300/250/300/0/1 | INFORMATION_RISK,INFORMATION_RISK_SEVERE 3:0=B1 Ba3 39.00 LGD3 RR3 SGL-2 | 300/250/500/120/1 | BUREAU_DPD30_59,BUREAU_HIDDEN_DEBT,BUREAU_LENDERS_NOT_ON_PLATFORM,INFORMATION_RISK,INFORMATION_RISK_SEVERE)');
GO
/* CA14 (FR-FIN-028 to FR-FIN-030, BR-FIN-028 to BR-FIN-030, docs/35 sections 5, 12, 13 and 15): IND's activity is the
   manufacture of non-metallic mineral products and its product lines for 2025 are building materials and capital
   goods. The assessment computes the two scenarios of the activity, the resilience, the sector position and the
   triggers of the grade; and, asked for them, the strengthening plans, each step applied to the pro-forma statement
   before it with the balance sheet balanced at every step. */
DECLARE @s BIGINT, @a BIGINT, @ind BIGINT, @t INT, @head NVARCHAR(1000), @scen NVARCHAR(600), @plans NVARCHAR(2000), @steps INT, @unbal INT, @trig INT;
BEGIN TRANSACTION;
EXEC #Crd;
SELECT @ind = v FROM #C WHERE k = 'ind'; SELECT @t = v FROM #C WHERE k = 't';
UPDATE org.Company SET IndustryId = (SELECT IndustryId FROM ref.Industry WHERE Code = 'C23') WHERE CompanyId = @ind;
INSERT fin.CompanyProductLine (TenantId, CompanyId, FiscalYear, NameAr, ProductCategoryId, RevenueSharePct, InventorySharePct, CashSalesPct)
SELECT @t, @ind, 2025, v.NameAr, pc.ProductCategoryId, v.Rev, v.Inv, v.Cash
FROM (VALUES (N'بلاط وأدوات صحية', 'BUILDING_MATERIALS', 70, 80, 20), (N'خطوط إنتاج', 'CAPITAL_GOODS', 30, 20, 0)) AS v (NameAr, Category, Rev, Inv, Cash)
JOIN fin.ProductCategory AS pc ON pc.Code = v.Category;
EXEC #CStmt @ind, '2025-12-31';
SELECT @s = v FROM #C WHERE k = 's';
EXEC #CAssess @s;
SELECT @a = v FROM #C WHERE k = 'a';
UPDATE fin.CreditAssessment SET StrengtheningRequested = 1 WHERE CreditAssessmentId = @a;
EXEC fin.usp_ComputeCreditAssessment @a;
SELECT @head = CONCAT(FinalGrade, ' ', IndustryCode, ' ', SectorTypicalGrade, ' ', SectorPosition, ' ', Resilience, ' ', Outlook, ' ', OutlookRules)
FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
SELECT @scen = STRING_AGG(CONCAT(Scenario, ':', Grade, ':', NotchesLost, ':', LiquidityLabel), ' ') WITHIN GROUP (ORDER BY Scenario) FROM fin.v_CreditAssessmentScenarios WHERE AssessmentId = @a;
SELECT @plans = STRING_AGG(CONCAT(PlanCode, ':', FinalGrade, ':+', NotchesGained, ':', Steps), ' ') WITHIN GROUP (ORDER BY SortOrder)
FROM (SELECT PlanCode, FinalGrade, NotchesGained, SortOrder, STRING_AGG(RemedyCode, ',') WITHIN GROUP (ORDER BY StepNo) AS Steps
      FROM fin.v_CreditAssessmentPlans WHERE AssessmentId = @a GROUP BY PlanCode, FinalGrade, NotchesGained, SortOrder) AS x;
SELECT @steps = COUNT(*), @unbal = SUM(CASE WHEN IsBalanced = 0 THEN 1 ELSE 0 END) FROM fin.v_CreditAssessmentPlans WHERE AssessmentId = @a;
SELECT @trig = COUNT(*) FROM fin.v_CreditAssessmentTriggers WHERE AssessmentId = @a;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @head = 'Ba3 C23 B1 WITHIN VULNERABLE NEGATIVE NEG_LIQUIDITY,NEG_SCENARIO,NEG_TREND' AND @scen = 'FINANCIAL_CRISIS:Caa3:7:SGL-4 FISCAL_SQUEEZE:Caa3:7:SGL-4 GULF_SHIPPING_CONFLICT:Caa2:6:SGL-4 OIL_PRICE_COLLAPSE:Caa3:7:SGL-4 REAL_ESTATE_CORRECTION:Caa2:6:SGL-4 REGIONAL_CONFLICT:Caa2:6:SGL-4 STAGNANT_MARKET:Caa2:6:SGL-4' AND @plans = 'OWNER_SUPPORT_NO_CASH:Ba3:+0:CONVERT_DUE_TO_RELATED_TO_SUB CAPITAL_STRENGTHENING:Ba3:+0:RETAIN_EARNINGS RELATED_PARTY_CLEANUP:Ba3:+0:CONVERT_DUE_TO_RELATED_TO_SUB OPTIMAL_NO_NEW_CASH:Ba3:+0:RETAIN_EARNINGS,CONVERT_DUE_TO_RELATED_TO_SUB' AND @unbal = 0 AND @steps > 0 AND @trig = 15
    PRINT 'PASS CA14: the activity and product lines give the scenarios, resilience, sector position and triggers, and the strengthening plans keep the balance sheet balanced at every step, as the reference computes them';
ELSE PRINT CONCAT('FAIL CA14: ', @head, ' | ', @scen, ' | ', @plans, ' | unbalanced ', @unbal, ' of ', @steps, ' | triggers ', @trig);
GO
/* CA15 (BR-FIN-024): what the computation read is in its hash: a guarantor, the bureau report or a product line changed
   after the computation makes the submission fail (50063) until the assessment is computed again; a guarantor of a
   submitted assessment does not change (50063). */
CREATE PROCEDURE #HashCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @t INT = (SELECT v FROM #C WHERE k = 't'), @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind');
    EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    EXEC #CPlatform @Bureau = 1;
    EXEC fin.usp_ComputeCreditAssessment @a;
    IF @Case = 1 UPDATE fin.CreditAssessmentGuarantor SET LiquidAssets = LiquidAssets + 1 WHERE AssessmentId = @a;
    IF @Case = 2 UPDATE fin.CreditAssessmentBureau SET WorstDpd12m = 95, WorstDpd24m = 95 WHERE AssessmentId = @a;
    IF @Case = 3
        INSERT fin.CompanyProductLine (TenantId, CompanyId, FiscalYear, NameAr, ProductCategoryId, RevenueSharePct)
        SELECT @t, @ind, 2025, N'منتج', ProductCategoryId, 100 FROM fin.ProductCategory WHERE Code = 'ESSENTIAL_STAPLE';
    IF @Case = 4
    BEGIN
        UPDATE fin.CreditAssessmentGuarantor SET LiquidAssets = LiquidAssets + 1 WHERE AssessmentId = @a;
        EXEC fin.usp_ComputeCreditAssessment @a;
    END;
    UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
    IF @Case = 5 UPDATE fin.CreditAssessmentGuarantor SET LiquidAssets = LiquidAssets + 1 WHERE AssessmentId = @a;
    SELECT @Out = Status FROM fin.CreditAssessment WHERE CreditAssessmentId = @a;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#HashCase', 1, 5, @got OUTPUT;
IF @got = '1:50063 2:50063 3:50063 4:0=SUBMITTED 5:50063'
    PRINT 'PASS CA15: a guarantor, the bureau report or a product line changed after the computation stops the submission until it is computed again';
ELSE PRINT CONCAT('FAIL CA15: ', @got, ' (expected 1:50063 2:50063 3:50063 4:0=SUBMITTED 5:50063)');
GO
/* CA16 (FR-FIN-031 to FR-FIN-033, BR-FIN-031 and BR-FIN-032, ADR 0019): the market country and city of the
   assessment and the detailed activity of the company: (1) a division with detailed activities, in the UAE without a
   city, asks for the activity and the city; (2) a finished building materials supplier in Dubai gives the Dubai real
   estate stress; (3) a country without a profile reads the default one and asks for it; (4) a strong company in
   Bahrain is capped at the sovereign rating. Each gives the country risk, the industry risk, the anchor, the country
   ceiling, the final grade, the requests and the revenue change of the real estate correction the reference gives. */
CREATE PROCEDURE #CountryCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind');
    UPDATE org.Company SET IndustryId = (SELECT IndustryId FROM ref.Industry WHERE Code = CASE @Case WHEN 1 THEN 'G4663' WHEN 4 THEN 'C2101' ELSE 'G466301' END)
    WHERE CompanyId = @ind;
    EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    UPDATE fin.CreditAssessment
       SET MarketCountryId = (SELECT CountryId FROM ref.Country WHERE Iso2 = CASE @Case WHEN 3 THEN 'TR' WHEN 4 THEN 'BH' ELSE 'AE' END),
           MarketRegionCode = CASE WHEN @Case = 2 THEN 'DXB' END
    WHERE CreditAssessmentId = @a;
    EXEC fin.usp_ComputeCreditAssessment @a;
    SELECT @Out = CONCAT(r.CountryRisk, ' ', r.IndustryRisk, ' ', r.SectorTypicalGrade, ' ', r.CountryCeilingGrade, ' ', r.FinalGrade, ' ',
                         ISNULL((SELECT STRING_AGG(x.RuleCode, ',') WITHIN GROUP (ORDER BY x.RuleCode) FROM fin.CreditAssessmentFinding AS x
                                 WHERE x.AssessmentId = @a AND x.Source = 'DATA' AND x.RuleCode IN ('COUNTRY_PROFILE', 'INDUSTRY_DETAIL', 'MARKET_REGION')), '-'), ' ',
                         (SELECT FORMAT(RevenuePct, 'N2', 'en-US') FROM fin.v_CreditAssessmentScenarios WHERE AssessmentId = @a AND Scenario = 'REAL_ESTATE_CORRECTION'))
    FROM fin.v_CreditAssessmentReport AS r WHERE r.CreditAssessmentId = @a;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#CountryCase', 1, 4, @got OUTPUT;
IF @got = '1:0=2 4 B1 Aa2 Ba3 INDUSTRY_DETAIL,MARKET_REGION -29.63 2:0=2 4 B1 Aa2 Ba3 - -42.55 3:0=4 4 B3 Ba2 Ba3 COUNTRY_PROFILE -26.30 4:0=4 2 Ba1 B2 B2 - -4.24'
    PRINT 'PASS CA16: the market country and city and the detailed activity give the country risk, the anchor, the country ceiling, the requests and the stress of the scenarios, as the reference computes them';
ELSE PRINT CONCAT('FAIL CA16: ', @got, ' (expected 1:0=2 4 B1 Aa2 Ba3 INDUSTRY_DETAIL,MARKET_REGION -29.63 2:0=2 4 B1 Aa2 Ba3 - -42.55 3:0=4 4 B3 Ba2 Ba3 COUNTRY_PROFILE -26.30 4:0=4 2 Ba1 B2 B2 - -4.24)');
GO
/* CA17 (FR-FIN-034, BR-FIN-035, ADR 0021): the lender's actual decision on a facility replaces the estimate of the
   scenarios for that facility. IND imports staple food; its facility of 300 million SAR, committed, has 250 million
   drawn: (1) no decision; (2) the lender stopped the undrawn limit; (3) it reduced the limit to 200 million, so the
   50 million drawn above it are due; (4) it kept the facility and raised the margin by 150 and the fees by 25 basis
   points; (5) a decision effective after the assessment date is not read. Each gives the final grade, the liquidity,
   the facility as the assessment read it, and the financial crisis: the cut of the short-term lines, the lender's
   estimated margin and fees, the share of the undrawn limits kept, and the grade. */
CREATE PROCEDURE #LenderCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @f BIGINT, @t INT = (SELECT v FROM #C WHERE k = 't'), @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind');
    UPDATE org.Company SET IndustryId = (SELECT IndustryId FROM ref.Industry WHERE Code = 'G463002') WHERE CompanyId = @ind;
    EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    EXEC #CPlatform;
    SET @f = (SELECT FacilityId FROM fac.Facility WHERE TenantId = @t AND FacilityNo = 'FAC-26-301');
    IF @Case > 1
        INSERT fac.FacilityLenderDecision (TenantId, FacilityId, LenderInstitutionId, DecisionDate, EffectiveDate, LimitAction, NewLimitAmount, MarginChangeBp,
                                           FeesChangeBp, NoSourceReason)
        VALUES (@t, @f, NULL, '2026-03-01', CASE @Case WHEN 5 THEN '2026-06-01' ELSE '2026-03-15' END,
                CASE @Case WHEN 2 THEN 'UNDRAWN_STOPPED' WHEN 3 THEN 'LIMIT_REDUCED' WHEN 4 THEN 'MAINTAINED' ELSE 'NOT_RENEWED' END,
                CASE WHEN @Case = 3 THEN 200000000 END, CASE WHEN @Case = 4 THEN 150 ELSE 0 END, CASE WHEN @Case = 4 THEN 25 ELSE 0 END, N'test fixture');
    EXEC fin.usp_ComputeCreditAssessment @a;
    SELECT @Out = CONCAT(r.FinalGrade, ' ', r.LiquidityLabel, ' | ',
                         (SELECT STRING_AGG(CONCAT(ISNULL(LimitAction, '-'), '/', ISNULL(CAST(CAST(DecidedLimitAmount / 1000000 AS INT) AS VARCHAR(10)), '-'), '/',
                                                   ISNULL(CAST(LenderCostChangeBp AS VARCHAR(10)), '-')), ',') FROM fin.v_CreditAssessmentFacilities WHERE AssessmentId = @a),
                         ' | ', (SELECT CONCAT(FORMAT(StLinesWithdrawnPct, 'N2', 'en-US'), ' ', FORMAT(LenderCostBp, 'N2', 'en-US'), ' ',
                                               FORMAT(UndrawnAvailablePct, 'N2', 'en-US'), ' ', Grade)
                                 FROM fin.v_CreditAssessmentScenarios WHERE AssessmentId = @a AND Scenario = 'FINANCIAL_CRISIS'))
    FROM fin.v_CreditAssessmentReport AS r WHERE r.CreditAssessmentId = @a;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#LenderCase', 1, 5, @got OUTPUT;
IF @got = '1:0=Ba2 SGL-2 | -/-/- | 60.00 262.50 25.00 Caa2 2:0=Ba2 SGL-3 | UNDRAWN_STOPPED/250/0 | 0.00 0.00 25.00 Caa2 3:0=Ba3 SGL-4 | LIMIT_REDUCED/200/0 | 0.00 0.00 25.00 Caa2 4:0=Ba2 SGL-2 | MAINTAINED/300/175 | 0.00 0.00 25.00 Caa1 5:0=Ba2 SGL-2 | -/-/- | 60.00 262.50 25.00 Caa2'
    PRINT 'PASS CA17: the actual decision of the lender on a facility replaces the estimate of the scenarios for it: a stopped or reduced limit, a repayment due, a new margin and fees';
ELSE PRINT CONCAT('FAIL CA17: ', @got, ' (expected 1:0=Ba2 SGL-2 | -/-/- | 60.00 262.50 25.00 Caa2 2:0=Ba2 SGL-3 | UNDRAWN_STOPPED/250/0 | 0.00 0.00 25.00 Caa2 3:0=Ba3 SGL-4 | LIMIT_REDUCED/200/0 | 0.00 0.00 25.00 Caa2 4:0=Ba2 SGL-2 | MAINTAINED/300/175 | 0.00 0.00 25.00 Caa1 5:0=Ba2 SGL-2 | -/-/- | 60.00 262.50 25.00 Caa2)');
GO
/* CA18 (FR-FIN-035, BR-FIN-036, ADR 0022): the trial assessment of a statement before its final approval. (1) An
   assessment of a draft statement is refused (50064); (2) a trial assessment of the same draft is computed, with the
   trial noted in its summary; (3) a line of the draft changed after the computation makes the trial no longer
   current, and computing it again makes it current with the new figures; (4) a trial assessment is not submitted
   (50063); (5) a trial and an official assessment of the same approved statement give the same grade. */
CREATE PROCEDURE #TrialCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @b BIGINT, @g1 NVARCHAR(10), @c1 BIT, @g2 NVARCHAR(10), @c2 BIT, @tr BIT, @t INT = (SELECT v FROM #C WHERE k = 't'), @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind');
    IF @Case = 5 EXEC #CStmt @ind, '2025-12-31'; ELSE EXEC #CStmt @ind, '2025-12-31', @Approve = 0;
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    IF @Case = 1 BEGIN EXEC fin.usp_ComputeCreditAssessment @a; RETURN; END;
    UPDATE fin.CreditAssessment SET IsTrial = 1 WHERE CreditAssessmentId = @a;
    EXEC fin.usp_ComputeCreditAssessment @a;
    SELECT @g1 = CONVERT(NVARCHAR(10), FinalGrade) COLLATE Arabic_100_CI_AS_SC, @c1 = IsCurrent FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
    IF @Case = 2
        SELECT @Out = CONCAT(FinalGrade, ' ', IsTrial, ' ', StatementStatus, ' ', IsCurrent, ' ', CASE WHEN SummaryAr LIKE N'تقييم تجريبي%' THEN 'noted' ELSE 'not noted' END)
        FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
    IF @Case = 3
    BEGIN
        UPDATE ln SET EnteredAmount = EnteredAmount * 3 FROM fin.StatementLine AS ln JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
        WHERE ln.TenantId = @t AND ln.StatementId = @s AND li.Code = 'CASH' COLLATE Arabic_100_CI_AS_SC;
        SELECT @c2 = IsCurrent FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
        EXEC fin.usp_ComputeCreditAssessment @a;
        SELECT @g2 = CONVERT(NVARCHAR(10), FinalGrade) COLLATE Arabic_100_CI_AS_SC, @tr = IsCurrent FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;
        SET @Out = CONCAT(@g1, N' ', @c1, N' ', @c2, N' ', @g2, N' ', @tr);
    END;
    IF @Case = 4 UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
    IF @Case = 5
    BEGIN
        EXEC #CAssess @s;
        SELECT @b = v FROM #C WHERE k = 'a';
        EXEC fin.usp_ComputeCreditAssessment @b;
        SELECT @g2 = CONVERT(NVARCHAR(10), FinalGrade) COLLATE Arabic_100_CI_AS_SC, @tr = IsTrial FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @b;
        SET @Out = CONCAT(@g1, N' ', @g2, N' ', @tr);
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#TrialCase', 1, 5, @got OUTPUT;
IF @got = '1:50064 2:0=Ba2 1 DRAFT 1 noted 3:0=Ba2 1 0 Ba2 1 4:50063 5:0=Ba2 Ba2 0'
    PRINT 'PASS CA18: a trial assessment reads a statement before its final approval, follows its changes and stays a draft; an official one needs the approved statement';
ELSE PRINT CONCAT('FAIL CA18: ', @got, ' (expected 1:50064 2:0=Ba2 1 DRAFT 1 noted 3:0=Ba2 1 0 Ba2 1 4:50063 5:0=Ba2 Ba2 0)');
GO
/* CA19 (FR-FIN-036, BR-FIN-037, ADR 0023): presentation versions of IND's draft statement for 2025, compared with
   its trial assessment. Version A subordinates the amounts due to related parties (an agreement of 2025-12-15) and
   retains the dividends (a resolution of 2026-02-10, after the period end); version B takes the same steps with both
   documents dated by the period end. (1) A is built: balanced, its moves written, not convertible, its trial
   assessment computed beside the source; (2) B is convertible, and its preparer cannot choose it (50090); (3) another
   user chooses B: B's draft replaces the source in the series and A is discarded; (4) A's draft is not submitted, its
   version not being chosen (50090); (5) a line of B's draft does not change by hand (50090); (6) the steps of a built
   version do not change (50090). */
CREATE PROCEDURE #VersionCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @va BIGINT, @vb BIGINT, @t INT = (SELECT v FROM #C WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #C WHERE k = 'u1'),
            @u2 BIGINT = (SELECT v FROM #C WHERE k = 'u2'), @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'),
            @sub INT = (SELECT CreditRemedyId FROM fin.CreditRemedy WHERE Code = 'CONVERT_DUE_TO_RELATED_TO_SUB'),
            @ret INT = (SELECT CreditRemedyId FROM fin.CreditRemedy WHERE Code = 'RETAIN_EARNINGS');
    ALTER TABLE fin.PresentationVersionStep NOCHECK CONSTRAINT FK_PresentationVersionStep_DocumentId;
    ALTER TABLE fin.CreditAssessmentInput NOCHECK CONSTRAINT FK_CreditAssessmentInput_DocumentId;
    EXEC #CStmt @ind, '2025-12-31', @Approve = 0;
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    UPDATE fin.CreditAssessment SET IsTrial = 1 WHERE CreditAssessmentId = @a;
    EXEC fin.usp_ComputeCreditAssessment @a;
    INSERT fin.PresentationVersion (TenantId, SourceStatementId, SourceAssessmentId, NameAr, PreparedBy) VALUES (@t, @s, @a, N'النسخة أ', @u1);
    SET @va = SCOPE_IDENTITY();
    INSERT fin.PresentationVersionStep (TenantId, VersionId, StepNo, RemedyId, DocumentId, EvidenceDate, Justification)
    VALUES (@t, @va, 1, @sub, 1, '2025-12-15', N'اتفاقية مساندة موقعة من الشركاء'), (@t, @va, 2, @ret, 1, '2026-02-10', N'قرار الجمعية بعدم التوزيع');
    INSERT fin.PresentationVersion (TenantId, SourceStatementId, SourceAssessmentId, NameAr, PreparedBy) VALUES (@t, @s, @a, N'النسخة ب', @u1);
    SET @vb = SCOPE_IDENTITY();
    INSERT fin.PresentationVersionStep (TenantId, VersionId, StepNo, RemedyId, DocumentId, EvidenceDate, Justification)
    VALUES (@t, @vb, 1, @sub, 1, '2025-12-15', N'اتفاقية مساندة موقعة من الشركاء'), (@t, @vb, 2, @ret, 1, '2025-12-20', N'قرار الشركاء بعدم التوزيع');
    EXEC fin.usp_BuildPresentationVersion @va;
    EXEC fin.usp_BuildPresentationVersion @vb;
    IF @Case = 1
        SELECT @Out = CONCAT(c.Status, ' ', c.IsConvertible, ' ', CAST(c.BalanceGap AS INT), ' ', c.SourceGrade, '>', c.VersionGrade, ' ', c.NotchesGained, ' ', c.StepCount, ' ',
                             (SELECT COUNT(*) FROM fin.PresentationVersionStep WHERE VersionId = @va AND MovedAmount > 0), ' ',
                             (SELECT STRING_AGG(CONCAT(LineCode, ':', CAST(Change / 1000000 AS INT)), ',') WITHIN GROUP (ORDER BY LineCode)
                              FROM fin.v_PresentationVersionLines WHERE PresentationVersionId = @va AND Change <> 0 AND LineCode IN ('DUE_TO_RELATED', 'SHAREHOLDER_LOANS_SUB')))
        FROM fin.v_PresentationComparison AS c WHERE c.PresentationVersionId = @va;
    IF @Case = 2
    BEGIN
        SELECT @Out = CONCAT((SELECT IsConvertible FROM fin.PresentationVersion WHERE PresentationVersionId = @vb), ' ');
        EXEC fin.usp_ChoosePresentationVersion @vb;
    END;
    IF @Case = 3
    BEGIN
        EXEC #CBind @t, @u2;
        EXEC fin.usp_ChoosePresentationVersion @vb;
        SELECT @Out = CONCAT((SELECT Status FROM fin.PresentationVersion WHERE PresentationVersionId = @vb), ' ',
                             (SELECT Status FROM fin.PresentationVersion WHERE PresentationVersionId = @va), ' ',
                             (SELECT CASE WHEN s2.SupersedesId = @s AND s2.VersionReason = 'RESTRUCTURED' AND s2.Status = 'DRAFT' THEN 'replaces' ELSE 'no' END
                              FROM fin.PresentationVersion AS v JOIN fin.FinancialStatement AS s2 ON s2.FinancialStatementId = v.ResultStatementId
                              WHERE v.PresentationVersionId = @vb));
    END;
    IF @Case = 4
        UPDATE s2 SET Status = 'SUBMITTED' FROM fin.FinancialStatement AS s2 JOIN fin.PresentationVersion AS v ON v.ResultStatementId = s2.FinancialStatementId
        WHERE v.PresentationVersionId = @va;
    IF @Case = 5
        UPDATE ln SET EnteredAmount = EnteredAmount + 1 FROM fin.StatementLine AS ln JOIN fin.PresentationVersion AS v ON v.ResultStatementId = ln.StatementId
        WHERE v.PresentationVersionId = @vb;
    IF @Case = 6 DELETE fin.PresentationVersionStep WHERE VersionId = @vb AND StepNo = 2;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#VersionCase', 1, 6, @got OUTPUT;
IF @got = '1:0=BUILT 0 0 Ba2>Ba2 0 2 2 DUE_TO_RELATED:-10,SHAREHOLDER_LOANS_SUB:10 2:50090 3:0=CHOSEN DISCARDED replaces 4:50090 5:50090 6:50090'
    PRINT 'PASS CA19: a presentation version applies the chosen remedies balanced, is compared with its source, becomes the statement only when chosen by another user on documents of the period, and its draft and steps are fixed';
ELSE PRINT CONCAT('FAIL CA19: ', @got, ' (expected 1:0=BUILT 0 0 Ba2>Ba2 0 2 2 DUE_TO_RELATED:-10,SHAREHOLDER_LOANS_SUB:10 2:50090 3:0=CHOSEN DISCARDED replaces 4:50090 5:50090 6:50090)');
GO
/* CA20 (FR-FIN-037, BR-FIN-038, ADR 0024): the readiness file of IND's assessment of 2026-04-30, with the lead time
   of six months. (1) IND's only facility expires on 2026-09-30: its renewal is a lender date 153 days ahead, RED, as
   a facility ending within the year gives no renewal to the liquidity (SGL-4, docs/35 section 10); (2) its lender
   notified that it will not renew it: RED with the notice; (3) a covenant test due on
   2026-07-31 whose last test was a breach: RED; (4) with a lead time of two months the renewal falls outside the
   file; (5) the timeline: the remedies before the fiscal year end 2026-12-31, the requests before 2026-08-31 (the
   renewal less 30 days), the bureau report asked for; (6) today, a facility expiring in three months raises an early
   warning on the latest assessment. */
CREATE PROCEDURE #ReadyCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @f BIGINT, @t INT = (SELECT v FROM #C WHERE k = 't'), @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'),
            @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    IF @Case = 6 EXEC #CAssess @s, @AsOf = @today; ELSE EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    IF @Case IN (1, 2, 4, 5) EXEC #CPlatform @Expiry = '2026-09-30';
    IF @Case = 6 BEGIN DECLARE @e DATE = DATEADD(DAY, 90, @today); EXEC #CPlatform @Expiry = @e; END;
    IF @Case = 2
    BEGIN
        SET @f = (SELECT FacilityId FROM fac.Facility WHERE TenantId = @t AND FacilityNo = 'FAC-26-301');
        INSERT fac.FacilityLenderDecision (TenantId, FacilityId, DecisionDate, EffectiveDate, LimitAction, NoSourceReason)
        VALUES (@t, @f, '2026-03-01', '2026-03-15', 'NOT_RENEWED', N'test fixture');
    END;
    IF @Case = 3
    BEGIN
        EXEC #CCov;
        DECLARE @cv BIGINT = (SELECT TOP (1) CovenantId FROM obl.Covenant WHERE TenantId = @t AND MeasureKind = 'RATIO');
        INSERT obl.CovenantTest (TenantId, CovenantId, CovenantRootId, PeriodStart, PeriodEnd, DueDate, Method)
        VALUES (@t, @cv, (SELECT RootId FROM obl.Covenant WHERE CovenantId = @cv), '2026-01-01', '2026-06-30', '2026-07-31', 'AUTO');
    END;
    IF @Case = 4 INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@t, 'fin.readiness.lead_months', N'2');
    EXEC fin.usp_ComputeCreditAssessment @a;
    IF @Case IN (1, 2, 3, 4)
        SET @Out = ISNULL((SELECT STRING_AGG(CONCAT(EventKind, ':', CONVERT(CHAR(10), EventDate, 23), ':', DaysLeft, ':', LiquidityLabel, ':',
                                                  ISNULL(LimitAction, '-'), ':', Readiness), ',')
                                  WITHIN GROUP (ORDER BY EventDate)
                           FROM fin.v_CreditReadinessEvents WHERE AssessmentId = @a), N'none');
    IF @Case = 5
        SELECT @Out = CONCAT('P', (SELECT COUNT(*) FROM fin.v_CreditReadinessActions WHERE AssessmentId = @a AND Phase = 'BEFORE_PERIOD_END'), ':',
                             (SELECT CONVERT(CHAR(10), MIN(Deadline), 23) FROM fin.v_CreditReadinessActions WHERE AssessmentId = @a AND Phase = 'BEFORE_PERIOD_END'),
                             ' S', (SELECT COUNT(*) FROM fin.v_CreditReadinessActions WHERE AssessmentId = @a AND Phase = 'BEFORE_SUBMISSION'), ':',
                             (SELECT CONVERT(CHAR(10), MIN(Deadline), 23) FROM fin.v_CreditReadinessActions WHERE AssessmentId = @a AND Phase = 'BEFORE_SUBMISSION'),
                             ' B', (SELECT COUNT(*) FROM fin.v_CreditReadinessRequests WHERE AssessmentId = @a AND RequestKind = 'BUREAU'));
    IF @Case = 6
        SELECT @Out = CONCAT(COUNT(*), ' ', MIN(EventKind), ' ', MIN(DaysLeft)) FROM fin.v_CreditEarlyWarnings WHERE AssessmentId = @a;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#ReadyCase', 1, 6, @got OUTPUT;
IF @got = '1:0=RENEWAL:2026-09-30:153:SGL-4:-:RED 2:0=RENEWAL:2026-09-30:153:SGL-4:NOT_RENEWED:RED 3:0=COVENANT_TEST:2026-07-31:92:SGL-3:-:RED 4:0=none 5:0=P12:2026-12-31 S14:2026-08-31 B1 6:0=1 RENEWAL 90'
    PRINT 'PASS CA20: the readiness file lists the lender dates in the lead time with their readiness, the timeline of actions and requests, and the early warning of today';
ELSE PRINT CONCAT('FAIL CA20: ', @got, ' (expected 1:0=RENEWAL:2026-09-30:153:SGL-4:-:RED 2:0=RENEWAL:2026-09-30:153:SGL-4:NOT_RENEWED:RED 3:0=COVENANT_TEST:2026-07-31:92:SGL-3:-:RED 4:0=none 5:0=P12:2026-12-31 S14:2026-08-31 B1 6:0=1 RENEWAL 90)');
GO
/* CA21 (FR-FIN-038, BR-FIN-039, ADR 0025): IND's budget for 2026, a management statement, beside its actual statement
   of 2025 and the official assessment of it. (1) An official assessment of the budget is refused (50064); (2) the
   budget is not submitted, it stays a draft (547); (3) a budget equal to the actual year gives a trial assessment
   noted as a budget, at the actual grade (read with the actual statement's assurance, so the plan alone shows);
   (4) a budget that borrows 300 million more to buy fixed assets loses notches, and its largest loss shows on the
   factor that moved most; (5) a budget raises no early warning: its lender dates are listed,
   but the warnings read the assessments of actual statements only. */
CREATE PROCEDURE #BudgetCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @b BIGINT, @ba BIGINT, @t INT = (SELECT v FROM #C WHERE k = 't'), @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'),
            @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    -- the actual year 2025, approved, and its official assessment (not computed in case 5)
    EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    IF @Case <> 5 EXEC fin.usp_ComputeCreditAssessment @a;
    -- the budget of 2026: the same lines, totals left to the engine
    EXEC #CStmt @ind, '2026-12-31', @Assurance = 'MANAGEMENT', @Approve = 0;
    SELECT @b = v FROM #C WHERE k = 's';
    UPDATE fin.FinancialStatement SET Nature = 'BUDGET' WHERE FinancialStatementId = @b;
    DELETE ln FROM fin.StatementLine AS ln JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
    WHERE ln.StatementId = @b AND li.Code IN (SELECT TotalCode FROM fin.StandardLineTotal);
    IF @Case = 4
        UPDATE ln SET EnteredAmount = EnteredAmount + 300000000
        FROM fin.StatementLine AS ln JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
        WHERE ln.StatementId = @b AND li.Code IN ('LT_LOANS' COLLATE Arabic_100_CI_AS_SC, 'PPE' COLLATE Arabic_100_CI_AS_SC);
    IF @Case = 2 BEGIN UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @b; RETURN; END;
    IF @Case = 5 EXEC #CAssess @b, @AsOf = @today; ELSE EXEC #CAssess @b;
    SELECT @ba = v FROM #C WHERE k = 'a';
    IF @Case = 5 BEGIN DECLARE @e DATE = DATEADD(DAY, 90, @today); EXEC #CPlatform @Expiry = @e; END;
    IF @Case <> 1 UPDATE fin.CreditAssessment SET IsTrial = 1 WHERE CreditAssessmentId = @ba;
    EXEC fin.usp_ComputeCreditAssessment @ba;
    IF @Case = 3
        SELECT @Out = CONCAT(c.ActualGrade, ' ', c.BudgetGrade, ' ', c.NotchesChange, ' ',
                             CASE WHEN (SELECT SummaryAr FROM fin.CreditAssessment WHERE CreditAssessmentId = @ba) LIKE N'تقييم تجريبي لقائمة تقديرية%' THEN 'noted' ELSE 'not noted' END)
        FROM fin.v_BudgetComparison AS c WHERE c.BudgetAssessmentId = @ba;
    IF @Case = 4
        SELECT @Out = CONCAT(c.ActualGrade, ' ', c.BudgetGrade, ' ', c.NotchesChange, ' ',
                             (SELECT TOP (1) f.FactorCode FROM fin.v_BudgetFactorComparison AS f WHERE f.BudgetAssessmentId = @ba ORDER BY f.ScoreGain * f.Weight, f.MetricCode))
        FROM fin.v_BudgetComparison AS c WHERE c.BudgetAssessmentId = @ba;
    IF @Case = 5
        SET @Out = CONCAT('events ', (SELECT COUNT(*) FROM fin.fn_CreditReadinessEvents(@today) WHERE AssessmentId = @ba),
                          ' warnings ', (SELECT COUNT(*) FROM fin.v_CreditEarlyWarnings WHERE CompanyId = @ind));
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#BudgetCase', 1, 5, @got OUTPUT;
IF @got = '1:50064 2:547 3:0=Ba2 Ba2 0 noted 4:0=Ba2 Ba3 -1 BALANCE_SHEET_QUALITY 5:0=events 1 warnings 0'
    PRINT 'PASS CA21: a budget is assessed by a trial only and stays a draft, compared with the actual year metric by metric, and raises no early warning';
ELSE PRINT CONCAT('FAIL CA21: ', @got, ' (expected 1:50064 2:547 3:0=Ba2 Ba2 0 noted 4:0=Ba2 Ba3 -1 BALANCE_SHEET_QUALITY 5:0=events 1 warnings 0)');
GO
/* CA22 (FR-FIN-039, BR-FIN-040, ADR 0026): the ratings a lender communicated to IND beside its official assessment of
   2026-04-30 (Ba2). (1) Bank 1 rates IND Ba1 on 2026-05-15: one notch more favourable, the metrics the assessment
   grades worse than Ba1 listed with the one that pulls most; (2) it rates IND B1 on its own scale (R6), mapped by the
   treasury: two notches more severe, the metrics graded better than B1 listed; (3) a rating mapped by the treasury
   keeps the lender's own label (547 without it); (4) the lender's latest rating, B3, shows on the renewal of its
   facility in the readiness file; (5) a rating at the assessment's grade is the same and lists no driver. */
CREATE PROCEDURE #LenderRatingCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @r BIGINT, @t INT = (SELECT v FROM #C WHERE k = 't'), @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind');
    ALTER TABLE fin.LenderRating NOCHECK CONSTRAINT FK_LenderRating_LenderInstitutionId;
    EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s;
    SELECT @a = v FROM #C WHERE k = 'a';
    IF @Case = 4 EXEC #CPlatform @Expiry = '2026-09-30';
    EXEC fin.usp_ComputeCreditAssessment @a;
    INSERT fin.LenderRating (TenantId, CompanyId, LenderInstitutionId, RatingDate, LenderGradeLabel, GradeId, MappingKind, LenderReasons, NoSourceReason)
    SELECT @t, @ind, 1, CASE @Case WHEN 4 THEN '2026-04-01' ELSE '2026-05-15' END,
           CASE @Case WHEN 2 THEN N'R6' ELSE NULL END,
           (SELECT RatingGradeId FROM fin.RatingGrade WHERE Code = CASE @Case WHEN 1 THEN 'Ba1' WHEN 2 THEN 'B1' WHEN 3 THEN 'B1' WHEN 4 THEN 'B3' ELSE 'Ba2' END),
           CASE WHEN @Case IN (2, 3) THEN 'MAPPED_BY_TREASURY' ELSE 'GIVEN_BY_LENDER' END, N'خطاب البنك بنتيجة المراجعة السنوية', N'test fixture';
    SET @r = SCOPE_IDENTITY();
    IF @Case IN (1, 2, 5)
        SELECT @Out = CONCAT(c.LenderGrade, ' ', c.AssessmentGrade, ' ', c.GapNotches, ' ', c.Direction, ' ',
                             (SELECT COUNT(*) FROM fin.v_LenderRatingGapDrivers WHERE LenderRatingId = @r AND DriverKind = 'METRIC'), ' ',
                             ISNULL((SELECT TOP (1) Code FROM fin.v_LenderRatingGapDrivers WHERE LenderRatingId = @r AND DriverKind = 'METRIC' ORDER BY Pull DESC, Code), '-'))
        FROM fin.v_LenderRatingComparison AS c WHERE c.LenderRatingId = @r;
    IF @Case = 4
        SET @Out = (SELECT STRING_AGG(CONCAT(EventKind, ':', LenderGrade, ':', Readiness), ',') FROM fin.v_CreditReadinessEvents WHERE AssessmentId = @a);
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#LenderRatingCase', 1, 5, @got OUTPUT;
IF @got = '1:0=Ba1 Ba2 -1 LENDER_MORE_FAVOURABLE 2 REVENUE_SIZE 2:0=B1 Ba2 2 LENDER_MORE_SEVERE 15 DEBT_TO_EBITDA 3:547 4:0=RENEWAL:B3:RED 5:0=Ba2 Ba2 0 SAME 0 -'
    PRINT 'PASS CA22: a rating a lender communicated is compared with the assessment of its date, where they part is listed, and it reaches the readiness of the lender''s renewals';
ELSE PRINT CONCAT('FAIL CA22: ', @got, ' (expected 1:0=Ba1 Ba2 -1 LENDER_MORE_FAVOURABLE 2 REVENUE_SIZE 2:0=B1 Ba2 2 LENDER_MORE_SEVERE 15 DEBT_TO_EBITDA 3:547 4:0=RENEWAL:B3:RED 5:0=Ba2 Ba2 0 SAME 0 -)');
GO
/* CA23 (FR-FIN-040, BR-FIN-041, ADR 0027): the early warning job JOB-FIN-READINESS on IND's assessment of today.
   (1) A facility expiring in 100 days is a RED renewal in the lead time: one warning LEAD RED, its notification
   request in the outbox with the same MessageId, the event code FIN.READINESS_RED, HIGH severity, the assessment as the target and the
   dedup key; (2) a second run of the day issues nothing; (3) a run on the eve with 31 days left issues D90, the run
   of today with 30 days left D30 (a stop of several days issues the current stage only); (4) a covenant test in 50
   days is AMBER (SGL-3); when a facility expiring within the year turns the liquidity to SGL-4 it worsens to RED in
   the same stage and warns again; (5) the procedure refuses a user binding and a run date that is not today (50092),
   and the application cannot write the log (229). */
CREATE PROCEDURE #WarnCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @f BIGINT, @n1 INT, @n2 INT, @t INT = (SELECT v FROM #C WHERE k = 't'), @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'),
            @u1 BIGINT = (SELECT v FROM #C WHERE k = 'u1'), @d DATE = CAST(SYSUTCDATETIME() AS DATE), @e DATE, @e1 INT, @e2 INT, @e3 INT, @r1 VARCHAR(200);
    EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s, @AsOf = @d;
    SELECT @a = v FROM #C WHERE k = 'a';
    IF @Case IN (1, 2, 5) BEGIN SET @e = DATEADD(DAY, 100, @d); EXEC #CPlatform @Expiry = @e; END;
    IF @Case = 3 BEGIN SET @e = DATEADD(DAY, 30, @d); EXEC #CPlatform @Expiry = @e; END;
    IF @Case = 4
    BEGIN
        EXEC #CCov;
        DECLARE @cv BIGINT = (SELECT TOP (1) CovenantId FROM obl.Covenant WHERE TenantId = @t AND MeasureKind = 'FLOW_VOLUME');
        SET @e = DATEADD(DAY, 50, @d);
        INSERT obl.CovenantTest (TenantId, CovenantId, CovenantRootId, PeriodStart, PeriodEnd, DueDate, Method)
        VALUES (@t, @cv, (SELECT RootId FROM obl.Covenant WHERE CovenantId = @cv), '2026-01-01', DATEADD(DAY, -30, @e), @e, 'AUTO');
    END;
    EXEC fin.usp_ComputeCreditAssessment @a;
    SET @f = (SELECT FacilityId FROM fac.Facility WHERE TenantId = @t AND FacilityNo = 'FAC-26-301');
    IF @Case IN (1, 2)
    BEGIN
        EXEC #CJob;
        EXECUTE AS USER = N'tp_test_crdjob';
        EXEC fin.usp_RunEarlyWarnings @d, @n1 OUTPUT;
        IF @Case = 2 EXEC fin.usp_RunEarlyWarnings @d, @n2 OUTPUT;
        REVERT;
        IF @Case = 1
            SELECT @Out = CONCAT(@n1, ' ', w.EventKind, ' ', w.Stage, ' ', w.Readiness, ' ', o.EventName, ' ', JSON_VALUE(o.PayloadJson, '$.eventCode'), ' ',
                                 JSON_VALUE(o.PayloadJson, '$.severity'), ' ',
                                 CASE WHEN JSON_VALUE(o.PayloadJson, '$.dedupKey') = CONCAT('FIN.READINESS_RED:RENEWAL:', @f, ':LEAD:', CONVERT(CHAR(8), @e, 112))
                                      THEN 'key' ELSE JSON_VALUE(o.PayloadJson, '$.dedupKey') END, ' ',
                                 CASE WHEN JSON_VALUE(o.PayloadJson, '$.targetId') = CAST(@a AS VARCHAR(20)) AND w.RefId = @f AND w.IssuedOn = @d THEN 'target' ELSE 'other' END)
            FROM fin.EarlyWarningAlert AS w
            JOIN cfg.OutboxEvent AS o ON o.TenantId = w.TenantId AND o.MessageId = w.MessageId
            WHERE w.TenantId = @t;
        IF @Case = 2
            SET @Out = CONCAT(@n1, ' ', @n2, ' ', (SELECT COUNT(*) FROM fin.EarlyWarningAlert WHERE TenantId = @t), ' ',
                              (SELECT COUNT(*) FROM cfg.OutboxEvent WHERE TenantId = @t AND EventName = 'notification.requested'));
    END;
    IF @Case = 3
    BEGIN
        DECLARE @eve DATE = DATEADD(DAY, -1, @d);
        EXEC #CJob;
        EXECUTE AS USER = N'tp_test_crdjob';
        EXEC fin.usp_RunEarlyWarnings @eve, @n1 OUTPUT;
        EXEC fin.usp_RunEarlyWarnings @d, @n2 OUTPUT;
        REVERT;
        SET @Out = CONCAT(@n1, ' ', (SELECT Stage FROM fin.EarlyWarningAlert WHERE TenantId = @t AND IssuedOn = @eve), ' ',
                          @n2, ' ', (SELECT Stage FROM fin.EarlyWarningAlert WHERE TenantId = @t AND IssuedOn = @d), ' ',
                          (SELECT COUNT(*) FROM fin.EarlyWarningAlert WHERE TenantId = @t));
    END;
    IF @Case = 4
    BEGIN
        EXEC #CJob;
        EXECUTE AS USER = N'tp_test_crdjob';
        EXEC fin.usp_RunEarlyWarnings @d, @n1 OUTPUT;
        REVERT;
        SET @r1 = (SELECT STRING_AGG(CONCAT(EventKind, ':', Stage, ':', Readiness), ',') FROM fin.EarlyWarningAlert WHERE TenantId = @t);
        EXEC #CBind @t, @u1;
        SET @e = DATEADD(DAY, 200, @d);
        EXEC #CPlatform @Expiry = @e;
        EXEC fin.usp_ComputeCreditAssessment @a;
        EXEC #CJob;
        EXECUTE AS USER = N'tp_test_crdjob';
        EXEC fin.usp_RunEarlyWarnings @d, @n2 OUTPUT;
        REVERT;
        SET @Out = CONCAT(@n1, ' ', @r1, ' ', @n2, ' ',
                          (SELECT STRING_AGG(CONCAT(EventKind, ':', Stage, ':', Readiness), ',') WITHIN GROUP (ORDER BY EarlyWarningAlertId) FROM fin.EarlyWarningAlert WHERE TenantId = @t));
    END;
    IF @Case = 5
    BEGIN
        EXECUTE AS USER = N'tp_test_crdjob';
        BEGIN TRY EXEC fin.usp_RunEarlyWarnings @d; SET @e1 = 0; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
        REVERT;
        EXEC #CJob;
        SET @e = DATEADD(DAY, 5, @d);
        EXECUTE AS USER = N'tp_test_crdjob';
        BEGIN TRY EXEC fin.usp_RunEarlyWarnings @e; SET @e2 = 0; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
        REVERT;
        EXEC #CBind @t, @u1;
        EXECUTE AS USER = N'tp_test_crdapp';
        BEGIN TRY
            INSERT fin.EarlyWarningAlert (TenantId, CompanyId, AssessmentId, EventKind, RefId, EventDate, Stage, Readiness, IssuedOn, MessageId)
            VALUES (@t, @ind, @a, 'RENEWAL', @f, DATEADD(DAY, 100, @d), 'LEAD', 'RED', @d, NEWID());
            SET @e3 = 0;
        END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
        REVERT;
        SET @Out = CONCAT(@e1, ' ', @e2, ' ', @e3);
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#WarnCase', 1, 5, @got OUTPUT;
IF @got = '1:0=1 RENEWAL LEAD RED notification.requested FIN.READINESS_RED HIGH key target 2:0=1 0 1 1 3:0=1 D90 1 D30 2 4:0=1 COVENANT_TEST:D90:AMBER 1 COVENANT_TEST:D90:AMBER,COVENANT_TEST:D90:RED 5:0=50092 50092 229'
    PRINT 'PASS CA23: the early warning job issues each lender date not ready once per stage and readiness, with its notification request in the outbox, and only as the job';
ELSE PRINT CONCAT('FAIL CA23: ', @got, ' (expected 1:0=1 RENEWAL LEAD RED notification.requested FIN.READINESS_RED HIGH key target 2:0=1 0 1 1 3:0=1 D90 1 D30 2 4:0=1 COVENANT_TEST:D90:AMBER 1 COVENANT_TEST:D90:AMBER,COVENANT_TEST:D90:RED 5:0=50092 50092 229)');
GO
-- BEGIN #CNtfPack (generated by tools/dbgen/ntf_pack.py --write-test from db/seed/packs/NTF.BASE/v1; do not edit)
CREATE PROCEDURE #CNtfPack
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #C WHERE k = 't');
    INSERT sec.Role (TenantId, Code, NameAr, NameEn, IsSystem, SeedKey)
    SELECT @t, v.Code, v.Code, v.Code, 1, v.SeedKey FROM (VALUES ('FA', 'ROLE.FA'), ('FO', 'ROLE.FO'), ('TM', 'ROLE.TM')) AS v (Code, SeedKey)
    WHERE NOT EXISTS (SELECT 1 FROM sec.Role AS r WHERE r.TenantId = @t AND r.SeedKey = v.SeedKey);
    INSERT ntf.NotificationEventType (TenantId, Code, OwnerModule, GroupKey, NameAr, NameEn, DefaultSeverity, IsMandatory, IsActionRequired, DefaultChannels, AllowedPlaceholdersJson, DedupWindowMinutes, CoalesceWindowMinutes, SeedKey) VALUES (@t, N'FIN.READINESS_RED', N'FIN', N'FIN_READINESS', N'إنذار أحمر: موعد لجهة تمويل والشركة غير جاهزة', N'Red warning: a lender date the company is not ready for', N'HIGH', 1, 0, N'["IN_APP", "EMAIL"]', N'["companyName", "eventLabel", "reference", "eventDate", "daysLeft", "stageLabel", "reason", "grade", "liquidity", "leadMonths"]', NULL, NULL, N'NTF.FIN.READINESS_RED');
    INSERT ntf.NotificationEventType (TenantId, Code, OwnerModule, GroupKey, NameAr, NameEn, DefaultSeverity, IsMandatory, IsActionRequired, DefaultChannels, AllowedPlaceholdersJson, DedupWindowMinutes, CoalesceWindowMinutes, SeedKey) VALUES (@t, N'FIN.READINESS_AMBER', N'FIN', N'FIN_READINESS', N'تنبيه أصفر: موعد لجهة تمويل وجاهزية الشركة ناقصة', N'Amber warning: a lender date the company is not fully ready for', N'WARNING', 0, 0, N'["IN_APP"]', N'["companyName", "eventLabel", "reference", "eventDate", "daysLeft", "stageLabel", "reason", "grade", "liquidity", "leadMonths"]', NULL, NULL, N'NTF.FIN.READINESS_AMBER');
    INSERT ntf.NotificationRule (TenantId, EventTypeId, RecipientKind, RoleId, RequireCompanyScope, IsMandatory, IsActive, SeedKey)
    SELECT @t, e.NotificationEventTypeId, N'ROLE', r.RoleId, 1, 1, 1, N'NTF.FIN.READINESS_RED.TM' FROM ntf.NotificationEventType AS e JOIN sec.Role AS r ON r.TenantId = e.TenantId AND r.SeedKey = N'ROLE.TM' WHERE e.TenantId = @t AND e.Code = N'FIN.READINESS_RED';
    INSERT ntf.NotificationRule (TenantId, EventTypeId, RecipientKind, RoleId, RequireCompanyScope, IsMandatory, IsActive, SeedKey)
    SELECT @t, e.NotificationEventTypeId, N'ROLE', r.RoleId, 1, 1, 1, N'NTF.FIN.READINESS_RED.FO' FROM ntf.NotificationEventType AS e JOIN sec.Role AS r ON r.TenantId = e.TenantId AND r.SeedKey = N'ROLE.FO' WHERE e.TenantId = @t AND e.Code = N'FIN.READINESS_RED';
    INSERT ntf.NotificationRule (TenantId, EventTypeId, RecipientKind, RoleId, RequireCompanyScope, IsMandatory, IsActive, SeedKey)
    SELECT @t, e.NotificationEventTypeId, N'ROLE', r.RoleId, 1, 0, 1, N'NTF.FIN.READINESS_RED.FA' FROM ntf.NotificationEventType AS e JOIN sec.Role AS r ON r.TenantId = e.TenantId AND r.SeedKey = N'ROLE.FA' WHERE e.TenantId = @t AND e.Code = N'FIN.READINESS_RED';
    INSERT ntf.NotificationRule (TenantId, EventTypeId, RecipientKind, RoleId, RequireCompanyScope, IsMandatory, IsActive, SeedKey)
    SELECT @t, e.NotificationEventTypeId, N'ROLE', r.RoleId, 1, 0, 1, N'NTF.FIN.READINESS_AMBER.TM' FROM ntf.NotificationEventType AS e JOIN sec.Role AS r ON r.TenantId = e.TenantId AND r.SeedKey = N'ROLE.TM' WHERE e.TenantId = @t AND e.Code = N'FIN.READINESS_AMBER';
    INSERT ntf.NotificationRule (TenantId, EventTypeId, RecipientKind, RoleId, RequireCompanyScope, IsMandatory, IsActive, SeedKey)
    SELECT @t, e.NotificationEventTypeId, N'ROLE', r.RoleId, 1, 0, 1, N'NTF.FIN.READINESS_AMBER.FO' FROM ntf.NotificationEventType AS e JOIN sec.Role AS r ON r.TenantId = e.TenantId AND r.SeedKey = N'ROLE.FO' WHERE e.TenantId = @t AND e.Code = N'FIN.READINESS_AMBER';
    INSERT ntf.NotificationRule (TenantId, EventTypeId, RecipientKind, RoleId, RequireCompanyScope, IsMandatory, IsActive, SeedKey)
    SELECT @t, e.NotificationEventTypeId, N'ROLE', r.RoleId, 1, 0, 1, N'NTF.FIN.READINESS_AMBER.FA' FROM ntf.NotificationEventType AS e JOIN sec.Role AS r ON r.TenantId = e.TenantId AND r.SeedKey = N'ROLE.FA' WHERE e.TenantId = @t AND e.Code = N'FIN.READINESS_AMBER';
    INSERT ntf.NotificationTemplate (TenantId, EventTypeId, Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride)
    SELECT @t, NotificationEventTypeId, N'IN_APP', N'ar', N'إنذار أحمر: {eventLabel} {reference} في {eventDate}', N'{companyName} غير جاهزة لموعد {eventLabel} {reference} في {eventDate} ({stageLabel}، الأيام الباقية: {daysLeft}). السبب: {reason}. درجة التقييم {grade} والسيولة {liquidity}. افتح ملف الجاهزية لترى ما ستطلبه جهة التمويل والإجراءات قبل الموعد.', 0 FROM ntf.NotificationEventType WHERE TenantId = @t AND Code = N'FIN.READINESS_RED';
    INSERT ntf.NotificationTemplate (TenantId, EventTypeId, Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride)
    SELECT @t, NotificationEventTypeId, N'IN_APP', N'en', N'Red warning: {eventLabel} {reference} on {eventDate}', N'{companyName} is not ready for the {eventLabel} {reference} on {eventDate} ({stageLabel}, days left: {daysLeft}). Reason: {reason}. Assessment grade {grade}, liquidity {liquidity}. Open the readiness file to see what the lender will ask for and the actions due before the date.', 0 FROM ntf.NotificationEventType WHERE TenantId = @t AND Code = N'FIN.READINESS_RED';
    INSERT ntf.NotificationTemplate (TenantId, EventTypeId, Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride)
    SELECT @t, NotificationEventTypeId, N'EMAIL', N'ar', N'إنذار أحمر من BankFas: {companyName} غير جاهزة لموعد {eventLabel} {reference}', N'موعد {eventLabel} {reference} في {eventDate}، والأيام الباقية: {daysLeft} ({stageLabel}).' + NCHAR(10) + N'' + NCHAR(10) + N'جاهزية {companyName} لهذا الموعد حمراء. السبب: {reason}.' + NCHAR(10) + N'درجة التقييم الداخلي للشركة {grade} والسيولة {liquidity}.' + NCHAR(10) + N'' + NCHAR(10) + N'ما يُنصح به قبل الموعد:' + NCHAR(10) + N'1. راجع في ملف الجاهزية ما ستطلبه جهة التمويل على الأغلب، وجهّز مستنداته.' + NCHAR(10) + N'2. نفّذ الحلول ذات الأثر قبل نهاية الفترة المالية، فالحل لا يُحتسب إلا بمستند مؤرخ قبل نهايتها.' + NCHAR(10) + N'3. تواصل مع جهة التمويل مبكرًا بخطة واضحة، ولا تنتظر طلبها.' + NCHAR(10) + N'' + NCHAR(10) + N'يصلك هذا الإنذار عند دخول الموعد مدة التنبيه (بالأشهر: {leadMonths})، ثم عند 90 و30 و7 أيام، ومرة إن ساءت الجاهزية. والدرجة معايرة النظام الداخلية للشركة، لا تصنيف جهة التمويل.' + NCHAR(10) + N'افتح ملف الجاهزية من الرابط في هذه الرسالة؛ ويلزم الدخول إلى المنصة.', 0 FROM ntf.NotificationEventType WHERE TenantId = @t AND Code = N'FIN.READINESS_RED';
    INSERT ntf.NotificationTemplate (TenantId, EventTypeId, Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride)
    SELECT @t, NotificationEventTypeId, N'EMAIL', N'en', N'BankFas red warning: {companyName} is not ready for the {eventLabel} {reference}', N'The {eventLabel} {reference} is on {eventDate}; days left: {daysLeft} ({stageLabel}).' + NCHAR(10) + N'' + NCHAR(10) + N'The readiness of {companyName} for this date is red. Reason: {reason}.' + NCHAR(10) + N'The company''s internal assessment grade is {grade}, its liquidity {liquidity}.' + NCHAR(10) + N'' + NCHAR(10) + N'Recommended before the date:' + NCHAR(10) + N'1. Review in the readiness file what the lender will most likely ask for, and prepare its documents.' + NCHAR(10) + N'2. Carry out the remedies with an effect before the fiscal period ends: a remedy counts only on a document dated by its end.' + NCHAR(10) + N'3. Contact the lender early with a clear plan; do not wait for its request.' + NCHAR(10) + N'' + NCHAR(10) + N'This warning comes when the date enters the lead time ({leadMonths} months), then at 90, 30 and 7 days, and once if the readiness worsens. The grade is the system''s internal calibration for the company, not the lender''s rating.' + NCHAR(10) + N'Open the readiness file from the link in this message; signing in to the platform is required.', 0 FROM ntf.NotificationEventType WHERE TenantId = @t AND Code = N'FIN.READINESS_RED';
    INSERT ntf.NotificationTemplate (TenantId, EventTypeId, Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride)
    SELECT @t, NotificationEventTypeId, N'IN_APP', N'ar', N'تنبيه أصفر: {eventLabel} {reference} في {eventDate}', N'جاهزية {companyName} لموعد {eventLabel} {reference} في {eventDate} ناقصة ({stageLabel}، الأيام الباقية: {daysLeft}). السبب: {reason}. درجة التقييم {grade} والسيولة {liquidity}. في ملف الجاهزية ما يمكن تداركه قبل الموعد.', 0 FROM ntf.NotificationEventType WHERE TenantId = @t AND Code = N'FIN.READINESS_AMBER';
    INSERT ntf.NotificationTemplate (TenantId, EventTypeId, Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride)
    SELECT @t, NotificationEventTypeId, N'IN_APP', N'en', N'Amber warning: {eventLabel} {reference} on {eventDate}', N'{companyName} is not fully ready for the {eventLabel} {reference} on {eventDate} ({stageLabel}, days left: {daysLeft}). Reason: {reason}. Assessment grade {grade}, liquidity {liquidity}. The readiness file shows what can still be fixed before the date.', 0 FROM ntf.NotificationEventType WHERE TenantId = @t AND Code = N'FIN.READINESS_AMBER';
    INSERT ntf.NotificationTemplate (TenantId, EventTypeId, Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride)
    SELECT @t, NotificationEventTypeId, N'EMAIL', N'ar', N'تنبيه أصفر من BankFas: جاهزية {companyName} لموعد {eventLabel} {reference} ناقصة', N'موعد {eventLabel} {reference} في {eventDate}، والأيام الباقية: {daysLeft} ({stageLabel}).' + NCHAR(10) + N'' + NCHAR(10) + N'جاهزية {companyName} لهذا الموعد صفراء. السبب: {reason}.' + NCHAR(10) + N'درجة التقييم الداخلي للشركة {grade} والسيولة {liquidity}.' + NCHAR(10) + N'' + NCHAR(10) + N'الوقت يتسع للتدارك: راجع في ملف الجاهزية الطلبات المتوقعة والحلول ومواعيدها، فإن ساءت الجاهزية إلى الأحمر وصلك إنذار.' + NCHAR(10) + N'' + NCHAR(10) + N'الدرجة معايرة النظام الداخلية للشركة، لا تصنيف جهة التمويل. افتح ملف الجاهزية من الرابط في هذه الرسالة؛ ويلزم الدخول إلى المنصة.', 0 FROM ntf.NotificationEventType WHERE TenantId = @t AND Code = N'FIN.READINESS_AMBER';
    INSERT ntf.NotificationTemplate (TenantId, EventTypeId, Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride)
    SELECT @t, NotificationEventTypeId, N'EMAIL', N'en', N'BankFas amber warning: {companyName} is not fully ready for the {eventLabel} {reference}', N'The {eventLabel} {reference} is on {eventDate}; days left: {daysLeft} ({stageLabel}).' + NCHAR(10) + N'' + NCHAR(10) + N'The readiness of {companyName} for this date is amber. Reason: {reason}.' + NCHAR(10) + N'The company''s internal assessment grade is {grade}, its liquidity {liquidity}.' + NCHAR(10) + N'' + NCHAR(10) + N'There is time to act: review in the readiness file the expected requests, the remedies and their deadlines. If the readiness worsens to red, you will receive a warning.' + NCHAR(10) + N'' + NCHAR(10) + N'The grade is the system''s internal calibration for the company, not the lender''s rating. Open the readiness file from the link in this message; signing in to the platform is required.', 0 FROM ntf.NotificationEventType WHERE TenantId = @t AND Code = N'FIN.READINESS_AMBER';
END;
GO
-- END #CNtfPack
/* A warning's message as the notification builder fills it: the template of the event, channel and language, each
   placeholder replaced by the value of fin.v_EarlyWarningMessageValues in that language (ADR 0028). */
CREATE PROCEDURE #CRender @MessageId UNIQUEIDENTIFIER, @Channel VARCHAR(6), @Lang VARCHAR(2), @Subject NVARCHAR(600) OUTPUT, @Body NVARCHAR(4000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ar BIT = CASE WHEN @Lang COLLATE DATABASE_DEFAULT = 'ar' THEN 1 ELSE 0 END;
    DECLARE @v TABLE (P NVARCHAR(30) COLLATE Arabic_100_CI_AS_SC, V NVARCHAR(400) COLLATE Arabic_100_CI_AS_SC);
    INSERT @v (P, V)
    SELECT x.P, x.V
    FROM fin.v_EarlyWarningMessageValues AS v
    CROSS APPLY (VALUES (N'{companyName}', CASE @ar WHEN 1 THEN v.CompanyNameAr ELSE v.CompanyNameEn END),
                        (N'{eventLabel}', CASE @ar WHEN 1 THEN v.EventLabelAr ELSE v.EventLabelEn END),
                        (N'{reference}', CASE @ar WHEN 1 THEN v.ReferenceAr ELSE v.ReferenceEn END),
                        (N'{eventDate}', v.EventDate), (N'{daysLeft}', CAST(v.DaysLeft AS NVARCHAR(10))),
                        (N'{stageLabel}', CASE @ar WHEN 1 THEN v.StageLabelAr ELSE v.StageLabelEn END),
                        (N'{reason}', CASE @ar WHEN 1 THEN v.ReasonAr ELSE v.ReasonEn END),
                        (N'{grade}', v.Grade), (N'{liquidity}', v.Liquidity), (N'{leadMonths}', CAST(v.LeadMonths AS NVARCHAR(10)))) AS x (P, V)
    WHERE v.MessageId = @MessageId;
    SELECT @Subject = t.SubjectTemplate, @Body = t.BodyTemplate
    FROM fin.v_EarlyWarningMessageValues AS v
    JOIN ntf.NotificationEventType AS e ON e.TenantId = v.TenantId AND e.Code = v.EventCode
    JOIN ntf.NotificationTemplate AS t ON t.TenantId = e.TenantId AND t.EventTypeId = e.NotificationEventTypeId
                                       AND t.Channel = @Channel COLLATE DATABASE_DEFAULT AND t.Lang = @Lang COLLATE DATABASE_DEFAULT AND t.IsTenantOverride = 0
    WHERE v.MessageId = @MessageId;
    SELECT @Subject = REPLACE(@Subject, P, V), @Body = REPLACE(@Body, P, V) FROM @v;
END;
GO
/* CA24 (FR-FIN-041, BR-FIN-042, ADR 0028): the messages of the early warning from the templates of the tenant pack
   NTF.BASE, in Arabic and English. (1) A RED renewal is the event FIN.READINESS_RED for the reason LIQUIDITY_SGL4;
   its Arabic notice in the application reads with the facility number and the date; (2) its English one; (3) its
   Arabic email gives the reason, the grade and the lead time; (4) an AMBER covenant test is the event
   FIN.READINESS_AMBER for the reason LIQUIDITY_SGL3, with the covenant's title; (5) all eight messages of the two
   warnings are filled (no placeholder left), the subjects fit 300 characters and the bodies 2000, and each event has
   its rules for TM, FO and FA. The date of each message is shown as D. */
CREATE PROCEDURE #MessageCase @Case INT, @Out NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s BIGINT, @a BIGINT, @n INT, @t INT = (SELECT v FROM #C WHERE k = 't'), @ind BIGINT = (SELECT v FROM #C WHERE k = 'ind'),
            @d DATE = CAST(SYSUTCDATETIME() AS DATE), @e DATE, @m UNIQUEIDENTIFIER, @m2 UNIQUEIDENTIFIER, @subj NVARCHAR(600), @body NVARCHAR(4000),
            @bad INT = 0, @ch VARCHAR(6), @lg VARCHAR(2), @k INT;
    EXEC #CNtfPack;
    EXEC #CStmt @ind, '2025-12-31';
    SELECT @s = v FROM #C WHERE k = 's';
    EXEC #CAssess @s, @AsOf = @d;
    SELECT @a = v FROM #C WHERE k = 'a';
    IF @Case IN (1, 2, 3, 5) BEGIN SET @e = DATEADD(DAY, 100, @d); EXEC #CPlatform @Expiry = @e; END;
    IF @Case IN (4, 5)
    BEGIN
        EXEC #CCov;
        DECLARE @cv BIGINT = (SELECT TOP (1) CovenantId FROM obl.Covenant WHERE TenantId = @t AND MeasureKind = 'FLOW_VOLUME');
        DECLARE @due DATE = DATEADD(DAY, 50, @d);
        INSERT obl.CovenantTest (TenantId, CovenantId, CovenantRootId, PeriodStart, PeriodEnd, DueDate, Method)
        VALUES (@t, @cv, (SELECT RootId FROM obl.Covenant WHERE CovenantId = @cv), '2026-01-01', DATEADD(DAY, -30, @due), @due, 'AUTO');
    END;
    EXEC fin.usp_ComputeCreditAssessment @a;
    EXEC #CJob;
    EXECUTE AS USER = N'tp_test_crdjob';
    EXEC fin.usp_RunEarlyWarnings @d, @n OUTPUT;
    REVERT;
    EXEC #CBind @t, 0;
    SELECT TOP (1) @m = MessageId FROM fin.EarlyWarningAlert WHERE TenantId = @t ORDER BY CASE EventKind WHEN 'RENEWAL' THEN 0 ELSE 1 END, EarlyWarningAlertId;
    IF @Case IN (1, 2, 3)
    BEGIN
        SELECT @ch = CASE WHEN @Case = 3 THEN 'EMAIL' ELSE 'IN_APP' END, @lg = CASE WHEN @Case = 2 THEN 'en' ELSE 'ar' END;
        EXEC #CRender @m, @ch, @lg, @subj OUTPUT, @body OUTPUT;
        SELECT @Out = CONCAT(JSON_VALUE(o.PayloadJson, '$.eventCode'), ' ', w.ReasonCode, ' | ',
                             REPLACE(REPLACE(CASE WHEN @Case = 3 THEN LEFT(SUBSTRING(@body COLLATE DATABASE_DEFAULT, CHARINDEX(N'جاهزية', @body COLLATE DATABASE_DEFAULT), 400), CHARINDEX(NCHAR(10) + NCHAR(10), SUBSTRING(@body COLLATE DATABASE_DEFAULT, CHARINDEX(N'جاهزية', @body COLLATE DATABASE_DEFAULT), 400) + NCHAR(10) + NCHAR(10)) - 1) ELSE @subj COLLATE DATABASE_DEFAULT END,
                                     CONVERT(CHAR(10), w.EventDate, 23), N'D'), NCHAR(10), N' / '))
        FROM fin.EarlyWarningAlert AS w JOIN cfg.OutboxEvent AS o ON o.TenantId = w.TenantId AND o.MessageId = w.MessageId
        WHERE w.MessageId = @m;
    END;
    IF @Case = 4
    BEGIN
        EXEC #CRender @m, 'IN_APP', 'ar', @subj OUTPUT, @body OUTPUT;
        SELECT @Out = CONCAT(JSON_VALUE(o.PayloadJson, '$.eventCode'), ' ', w.ReasonCode, ' | ', REPLACE(@subj COLLATE DATABASE_DEFAULT, CONVERT(CHAR(10), w.EventDate, 23), N'D'))
        FROM fin.EarlyWarningAlert AS w JOIN cfg.OutboxEvent AS o ON o.TenantId = w.TenantId AND o.MessageId = w.MessageId
        WHERE w.MessageId = @m;
    END;
    IF @Case = 5
    BEGIN
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT w.MessageId, c.Ch, l.Lg FROM fin.EarlyWarningAlert AS w
            CROSS JOIN (VALUES ('IN_APP'), ('EMAIL')) AS c (Ch) CROSS JOIN (VALUES ('ar'), ('en')) AS l (Lg)
            WHERE w.TenantId = @t;
        OPEN cur;
        FETCH NEXT FROM cur INTO @m2, @ch, @lg;
        SET @k = 0;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @subj = NULL, @body = NULL;
            EXEC #CRender @m2, @ch, @lg, @subj OUTPUT, @body OUTPUT;
            IF @subj IS NULL OR @body IS NULL OR @subj COLLATE DATABASE_DEFAULT LIKE N'%{%' OR @body COLLATE DATABASE_DEFAULT LIKE N'%{%' OR LEN(@subj) > 300 OR LEN(@body) > 2000 SET @bad += 1;
            SET @k += 1;
            FETCH NEXT FROM cur INTO @m2, @ch, @lg;
        END;
        CLOSE cur; DEALLOCATE cur;
        SET @Out = CONCAT(@k, ' rendered ', @bad, ' bad | ',
                          (SELECT STRING_AGG(CONCAT(Readiness, ':', EventKind), ',') WITHIN GROUP (ORDER BY Readiness DESC) FROM fin.EarlyWarningAlert WHERE TenantId = @t), ' | rules ',
                          (SELECT STRING_AGG(x, ',') WITHIN GROUP (ORDER BY x) FROM (SELECT CONCAT(e.Code, ':', COUNT(*)) AS x FROM ntf.NotificationRule AS r
                                  JOIN ntf.NotificationEventType AS e ON e.TenantId = r.TenantId AND e.NotificationEventTypeId = r.EventTypeId
                                  WHERE r.TenantId = @t GROUP BY e.Code) AS g));
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #CCases '#MessageCase', 1, 5, @got OUTPUT;
IF @got = N'1:0=FIN.READINESS_RED LIQUIDITY_SGL4 | إنذار أحمر: تجديد التسهيل FAC-26-301 في D 2:0=FIN.READINESS_RED LIQUIDITY_SGL4 | Red warning: renewal of facility FAC-26-301 on D 3:0=FIN.READINESS_RED LIQUIDITY_SGL4 | جاهزية صناعية لهذا الموعد حمراء. السبب: السيولة SGL-4: مصادرها لا تغطي ما يستحق خلال السنة. / درجة التقييم الداخلي للشركة Ba3 والسيولة SGL-4. 4:0=FIN.READINESS_AMBER LIQUIDITY_SGL3 | تنبيه أصفر: اختبار التعهد تعهدات مالية في D 5:0=8 rendered 0 bad | RED:COVENANT_TEST,RED:RENEWAL | rules FIN.READINESS_AMBER:3,FIN.READINESS_RED:3'
    PRINT 'PASS CA24: the messages of the early warning are filled from the templates of the pack NTF.BASE in Arabic and English, red and amber, within their lengths';
ELSE PRINT CONCAT('FAIL CA24: ', @got, N' (expected 1:0=FIN.READINESS_RED LIQUIDITY_SGL4 | إنذار أحمر: تجديد التسهيل FAC-26-301 في D 2:0=FIN.READINESS_RED LIQUIDITY_SGL4 | Red warning: renewal of facility FAC-26-301 on D 3:0=FIN.READINESS_RED LIQUIDITY_SGL4 | جاهزية صناعية لهذا الموعد حمراء. السبب: السيولة SGL-4: مصادرها لا تغطي ما يستحق خلال السنة. / درجة التقييم الداخلي للشركة Ba3 والسيولة SGL-4. 4:0=FIN.READINESS_AMBER LIQUIDITY_SGL3 | تنبيه أصفر: اختبار التعهد تعهدات مالية في D 5:0=8 rendered 0 bad | RED:COVENANT_TEST,RED:RENEWAL | rules FIN.READINESS_AMBER:3,FIN.READINESS_RED:3)');
GO
DROP PROCEDURE #MessageCase, #CRender, #CNtfPack, #WarnCase, #CJob, #LenderRatingCase, #BudgetCase, #ReadyCase, #VersionCase, #TrialCase, #LenderCase, #CountryCase, #HashCase, #PlatformCase, #CPlatform, #CardCase, #CovCase, #CCov, #LifeCase, #SupportCase, #HoldAssessment, #AdjustCase, #DataCase,
               #CoverageCase, #CHead, #CGrade, #CCases, #CAssess, #Crd, #CStmt, #CBase, #CBind;
DROP TABLE #C;
DROP USER [tp_test_crdapp];
DROP USER [tp_test_crdjob];
GO

/* ============================================================================
   BankFas - tests of the controls on the actors of the financial records and of what a closed period freezes
   (db/static/058_actor_controls.sql, 046, 048, 049, 052, 053; docs/adr/0037-actor-controls.md; the internal review
   of 2026-10-21, lens E).
   FC1  statements: the preparer and the approver are the user bound to the session and hold fin.stmt.enter and
        fin.stmt.approve; a job binding approves nothing (50170, 50171)
   FC2  assessments: computed, submitted and approved by the bound user with fin.credit.assess and fin.credit.approve;
        each input is stamped with the user who entered it (50170, 50171)
   FC3  presentation versions: never of an approved statement (50090); built by their preparer (50170); chosen by a
        holder of fin.stmt.approve (50171)
   FC4  monthly figures: entered as drafts (50173); after a reopening the next edit names the editor (50170), and
        neither the reopener nor the editor confirms (547); the confirmer changes nothing (50170)
   FC5  revenue estimates: written as drafts (50173), edited by their preparer (50170), approved as prepared (50172)
        by a holder of fin.stmt.approve (50171), and approved ones only superseded (50173)
   FC6  loss rates: a default of the pack is approved by a holder of fin.formula.approve; an approved rate does not
        change and is not deleted (50173); a user's rate has a preparer who does not approve it (547)
   FC7  a closed period, indirectly: an official assessment, a supersession, a revenue estimate, a lender rating, product
        lines, a loss rate, and a unit's statement of a period its holding closed are refused (50096); a trial and an
        endorsement are not
   FC8  lender ratings verified or read by an endorsement, and the product lines an approved assessment read, are
        frozen (50173)
   FC9  the calibration reads approved assessments only; the early warnings read the approved assessment and the latest
        computed one, and a renewal from the facility as it is now
   FC10 the evidence pack holds what the computation read and is built of the approved assessment only (50095)
   FC11 the hash of an assessment holds the platform data it read: a change after the computation refuses the
        submission (50063)
   FC12 group support from a holding that controls the company only (50065)
   FC13 the provision matrix is INCOMPLETE when the ageing does not add up to the gross receivables
   FC14 the endorser neither approved the statement nor chose its presentation (50093)

   Run against a deployed BankFas database that holds no real data, with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/finance_controls_tests.sql
   Every case runs in its own transaction and rolls it back. Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
GO
CREATE TABLE #K (k VARCHAR(20) COLLATE DATABASE_DEFAULT PRIMARY KEY, v BIGINT NOT NULL);
GO
CREATE PROCEDURE #KBind @TenantId INT, @UserId BIGINT, @Kind VARCHAR(7) = 'USER', @JobKey VARCHAR(80) = NULL
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind) VALUES (@@SPID, @TenantId, @UserId, @token, @Kind);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @UserId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
    EXEC sys.sp_set_session_context @key = N'JobKey', @value = @JobKey;
END;
GO
-- Binds the connection as user 'u<n>' of the fixture's tenant.
CREATE PROCEDURE #As @Who VARCHAR(10)
AS
BEGIN
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @u BIGINT = (SELECT v FROM #K WHERE k = @Who COLLATE DATABASE_DEFAULT);
    EXEC #KBind @t, @u;
END;
GO
/* The fixture: a tenant; u1 and u6 makers (fin.stmt.enter, fin.credit.assess, fin.stats.enter, fin.formula.manage),
   u2 and u4 checkers (fin.stmt.approve, fin.credit.approve, fin.stats.confirm, fin.formula.approve, fin.period.lock),
   u3 with no permission, u5 an endorser (fin.credit.endorse) who also approves statements, u7 an endorser only, and
   the service account; a holding HOLD, its subsidiary IND (ParentCompanyId) and OTH; the standard line catalogue. */
CREATE PROCEDURE #KFix
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM #K;
    DECLARE @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'), @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA'),
            @pw VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA', @t INT, @n INT = 1, @u BIGINT;
    INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('tst-fctl', N'م', N'Controls', @plan, @country, 'ACTIVE', 'UTC');
    SET @t = SCOPE_IDENTITY();
    INSERT #K VALUES ('t', @t);
    EXEC #KBind @t, 0;
    WHILE @n <= 7
    BEGIN
        INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t, CONCAT(N'u', @n, N'@fctl.invalid'), CONCAT(N'User ', @n), 'ACTIVE', @pw);
        SET @u = SCOPE_IDENTITY();
        INSERT #K VALUES (CONCAT('u', @n), @u);
        SET @n += 1;
    END;
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, IsSystemUser) VALUES (@t, N'service@fctl.invalid', N'Service', 'ACTIVE', 1);
    INSERT #K VALUES ('svc', SCOPE_IDENTITY());
    INSERT sec.Role (TenantId, Code, NameAr, NameEn) VALUES (@t, 'K_MAKER', N'مُعِدّ', N'Maker'), (@t, 'K_CHECKER', N'معتمِد', N'Checker'),
                                                          (@t, 'K_ENDORSE_STMT', N'مصدّق ومعتمد قوائم', N'Endorser approving statements'), (@t, 'K_ENDORSE', N'مصدّق', N'Endorser');
    INSERT sec.RolePermission (TenantId, RoleId, PermissionId)
    SELECT @t, r.RoleId, p.PermissionId
    FROM sec.Role AS r
    JOIN (VALUES ('K_MAKER', 'fin.stmt.enter'), ('K_MAKER', 'fin.credit.assess'), ('K_MAKER', 'fin.stats.enter'), ('K_MAKER', 'fin.formula.manage'),
                 ('K_CHECKER', 'fin.stmt.approve'), ('K_CHECKER', 'fin.credit.approve'), ('K_CHECKER', 'fin.stats.confirm'), ('K_CHECKER', 'fin.formula.approve'),
                 ('K_CHECKER', 'fin.period.lock'), ('K_ENDORSE_STMT', 'fin.credit.endorse'), ('K_ENDORSE_STMT', 'fin.stmt.approve'),
                 ('K_ENDORSE', 'fin.credit.endorse')) AS m (RoleCode, PermCode) ON m.RoleCode = r.Code COLLATE DATABASE_DEFAULT
    JOIN sec.Permission AS p ON p.Code = m.PermCode COLLATE DATABASE_DEFAULT
    WHERE r.TenantId = @t;
    INSERT sec.UserRole (TenantId, UserId, RoleId)
    SELECT @t, k.v, r.RoleId
    FROM (VALUES ('u1', 'K_MAKER'), ('u6', 'K_MAKER'), ('u2', 'K_CHECKER'), ('u4', 'K_CHECKER'), ('u5', 'K_ENDORSE_STMT'), ('u7', 'K_ENDORSE')) AS x (Who, RoleCode)
    JOIN #K AS k ON k.k = x.Who
    JOIN sec.Role AS r ON r.TenantId = @t AND r.Code = x.RoleCode COLLATE DATABASE_DEFAULT;
    EXEC #As 'u1';
    ALTER TABLE org.Company NOCHECK CONSTRAINT FK_Company_LegalEntityTypeId;
    INSERT pty.Party (TenantId, PartyCode, Kind, NameEn) VALUES (@t, 'P-HOLD', 'ORGANIZATION', N'Holding'), (@t, 'P-IND', 'ORGANIZATION', N'Industrial'),
                                                              (@t, 'P-OTH', 'ORGANIZATION', N'Other');
    INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth, IsHolding)
    SELECT @t, v.Code, v.NameAr, v.Code, p.PartyId, 1, @country, 12, v.IsHolding
    FROM (VALUES ('HOLD', N'قابضة', 1, 'P-HOLD'), ('OTH', N'أخرى', 0, 'P-OTH')) AS v (Code, NameAr, IsHolding, PartyCode)
    JOIN pty.Party AS p ON p.TenantId = @t AND p.PartyCode = v.PartyCode COLLATE DATABASE_DEFAULT;
    INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth, IsHolding, ParentCompanyId)
    SELECT @t, 'IND', N'صناعية', N'Industrial', p.PartyId, 1, @country, 12, 0, (SELECT CompanyId FROM org.Company WHERE TenantId = @t AND CompanyCode = 'HOLD')
    FROM pty.Party AS p WHERE p.TenantId = @t AND p.PartyCode = 'P-IND';
    INSERT #K SELECT LOWER(CompanyCode), CompanyId FROM org.Company WHERE TenantId = @t;
    INSERT fin.LineCatalogItem (TenantId, Code, NameAr, NameEn, Section, SortOrder)
    SELECT @t, sl.Code, sl.NameAr, sl.NameEn, sl.Section, sl.SortOrder FROM fin.StandardLine AS sl;
END;
GO
/* A statement of @Company to @PeriodEnd with the worked example's lines (docs/35 section 14) and @Override, entered by
   u1 and, unless @Approve = 0, submitted by u1 and approved by @Approver ('s' in #K). The binding ends on u1. */
CREATE PROCEDURE #KStmt @Company BIGINT, @PeriodEnd DATE, @Override NVARCHAR(MAX) = N'', @Approve BIT = 1, @Approver VARCHAR(10) = 'u2',
                        @Basis VARCHAR(12) = 'STANDALONE'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #K WHERE k = 'u1'), @ua BIGINT = (SELECT v FROM #K WHERE k = @Approver COLLATE DATABASE_DEFAULT),
            @s BIGINT, @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR'),
            @base NVARCHAR(MAX) = N'CASH=45;AR=160;INVENTORY=130;DUE_FROM_RELATED=20;OTHER_CA=25;TOTAL_CA=380;PPE=520;INTANGIBLES=30;OTHER_NCA=70;TOTAL_ASSETS=1000;'
          + N'ST_LOANS=120;CURRENT_PORTION_LTD=60;AP=110;DUE_TO_RELATED=10;OTHER_CL=50;TOTAL_CL=350;LT_LOANS=180;LEASE_LIABS=20;'
          + N'SHAREHOLDER_LOANS_SUB=0;EOSB=18;OTHER_NCL=12;TOTAL_LIABS=580;SHARE_CAPITAL=250;RETAINED_EARNINGS=140;OTHER_EQUITY=30;'
          + N'MINORITY_INTEREST=0;TOTAL_EQUITY=420;REVENUE=900;COGS=650;GROSS_PROFIT=250;OPEX=160;DEPR_AMORT=40;EBITDA=130;'
          + N'OPERATING_PROFIT=90;FINANCE_COSTS=22;OTHER_INCOME=4;ZAKAT_TAX=8;NET_PROFIT=64;OP_CASH_FLOW=95;CAPEX=60;'
          + N'PRINCIPAL_REPAID=55;INTEREST_PAID=21;DIVIDENDS=30;LC_OUTSTANDING=90;LG_PERFORMANCE=100;LG_FINANCIAL=20;GUARANTEES_GIVEN=0';
    EXEC #As 'u1';
    INSERT fin.FinancialStatement (TenantId, CompanyId, PeriodType, PeriodEnd, FiscalYear, Basis, Assurance, CurrencyId, EntryMethod, PreparedBy, PreparedOn,
                                   AuditorName, AuditOpinion)
    VALUES (@t, @Company, 'ANNUAL', @PeriodEnd, YEAR(@PeriodEnd), @Basis, 'AUDITED', @cur, 'MANUAL', @u1, SYSUTCDATETIME(), N'Auditor (test)', 'UNQUALIFIED');
    SET @s = SCOPE_IDENTITY();
    INSERT fin.StatementLine (TenantId, StatementId, LineCatalogItemId, EnteredAmount)
    SELECT @t, @s, li.LineCatalogItemId, CAST(y.Amount AS DECIMAL(19,4)) * 1000000
    FROM (SELECT LEFT(x.value, CHARINDEX(N'=', x.value) - 1) AS Code, SUBSTRING(x.value, CHARINDEX(N'=', x.value) + 1, 40) AS Amount,
                 ROW_NUMBER() OVER (PARTITION BY LEFT(x.value, CHARINDEX(N'=', x.value) - 1) ORDER BY p.Pri DESC) AS rn
          FROM (VALUES (0, @base COLLATE DATABASE_DEFAULT), (1, @Override COLLATE DATABASE_DEFAULT)) AS p (Pri, Spec)
          CROSS APPLY STRING_SPLIT(p.Spec, N';') AS x
          WHERE CHARINDEX(N'=', x.value) > 0) AS y
    JOIN fin.LineCatalogItem AS li ON li.TenantId = @t AND li.Code = y.Code COLLATE DATABASE_DEFAULT
    WHERE y.rn = 1;
    IF @Basis COLLATE DATABASE_DEFAULT = 'CONSOLIDATED'
        INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method) VALUES (@t, @s, @Company, 'PARENT', 'FULL');
    IF @Approve = 1
    BEGIN
        IF @Basis COLLATE DATABASE_DEFAULT = 'CONSOLIDATED'
            INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method, OwnershipPct)
            VALUES (@t, @s, (SELECT v FROM #K WHERE k = 'ind'), 'SUBSIDIARY', 'FULL', 80);
        UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @s;
        EXEC #As @Approver;
        UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @ua, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @s;
        EXEC #As 'u1';
    END;
    DELETE FROM #K WHERE k = 's';
    INSERT #K VALUES ('s', @s);
END;
GO
/* A draft assessment of @Statement by u1 with the worked example's qualitative grades, computed unless @Compute = 0
   ('a' in #K); @Trial = 1 for a trial. The binding ends on u1. */
CREATE PROCEDURE #KAssess @Statement BIGINT, @AsOf DATE = '2026-04-30', @Compute BIT = 1, @Trial BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #K WHERE k = 'u1'), @a BIGINT;
    EXEC #As 'u1';
    INSERT fin.CreditAssessment (TenantId, CompanyId, StatementId, ScorecardId, AssessmentDate, IsTrial, PreparedBy)
    SELECT @t, s.CompanyId, s.FinancialStatementId, (SELECT ScorecardId FROM fin.Scorecard WHERE Code = 'GENERAL_CORPORATE' AND Status = 'APPROVED'), @AsOf, @Trial, @u1
    FROM fin.FinancialStatement AS s WHERE s.FinancialStatementId = @Statement;
    SET @a = SCOPE_IDENTITY();
    INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, MetricId, GradeId, Justification, EnteredBy)
    SELECT @t, @a, 'QUALITATIVE', m.CreditMetricId, g.RatingGradeId, N'test fixture: the worked example of docs/35', @u1
    FROM (VALUES ('BUSINESS_PROFILE', 'Ba1'), ('FINANCIAL_POLICY', 'Baa3')) AS v (Metric, Grade)
    JOIN fin.CreditMetric AS m ON m.Code = v.Metric COLLATE DATABASE_DEFAULT
    JOIN fin.RatingGrade AS g ON g.Code = v.Grade COLLATE DATABASE_DEFAULT;
    IF @Compute = 1 EXEC fin.usp_ComputeCreditAssessment @a;
    DELETE FROM #K WHERE k = 'a';
    INSERT #K VALUES ('a', @a);
END;
GO
-- Submits @Assessment as u1 and approves it as @Approver; the binding ends on u1.
CREATE PROCEDURE #KApprove @Assessment BIGINT, @Approver VARCHAR(10) = 'u2'
AS
BEGIN
    DECLARE @ua BIGINT = (SELECT v FROM #K WHERE k = @Approver COLLATE DATABASE_DEFAULT);
    EXEC #As 'u1';
    UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @Assessment;
    EXEC #As @Approver;
    UPDATE fin.CreditAssessment SET Status = 'APPROVED', ApprovedBy = @ua, ApprovedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @Assessment;
    EXEC #As 'u1';
END;
GO
/* A facility of IND with bank 1 (100 percent), its limit, a use of 250 million and revision 1 approved, ACTIVE,
   expiring on @Expiry ('f' in #K). */
CREATE PROCEDURE #KFacility @Expiry DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @u1 BIGINT = (SELECT v FROM #K WHERE k = 'u1'),
            @u2 BIGINT = (SELECT v FROM #K WHERE k = 'u2'), @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR'), @f BIGINT, @l BIGINT;
    ALTER TABLE fac.Facility NOCHECK CONSTRAINT FK_Facility_FacilityTypeId;
    ALTER TABLE fac.FacilityLender NOCHECK CONSTRAINT FK_FacilityLender_InstitutionId;
    ALTER TABLE fac.Limit NOCHECK CONSTRAINT FK_Limit_LimitTypeId;
    ALTER TABLE fin.CreditAssessmentFacility NOCHECK CONSTRAINT FK_CreditAssessmentFacility_LenderInstitutionId;
    INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
    VALUES (@t, 'FAC-26-901', @ind, 1, @cur, 300000000, 'EN', '2026-01-01', @Expiry);
    SET @f = SCOPE_IDENTITY();
    INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (@t, @f, 1, 'SOLE', 100, 1);
    INSERT fac.Limit (TenantId, FacilityId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, IsCommitted, FromRevision, NoSourceReason)
    VALUES (@t, @f, 1, 'L1', N'حد', 'ABSOLUTE', 300000000, 1, 1, 1, N'test fixture');
    SET @l = SCOPE_IDENTITY();
    INSERT fac.Utilization (TenantId, FacilityId, LimitId, CompanyId, Reference, Amount, CurrencyId, StartDate)
    VALUES (@t, @f, @l, @ind, N'test utilisation', 250000000, @cur, '2026-02-01');
    INSERT fac.FacilityRevision (TenantId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn, SubmittedBy, SubmittedOn, ApprovedBy, ApprovedOn)
    VALUES (@t, @f, 1, 'INITIAL', 'APPROVED', '2026-01-01', @u1, SYSUTCDATETIME(), @u2, SYSUTCDATETIME());
    UPDATE fac.Facility SET ApprovedRevisionNo = 1, LifecycleStatus = 'ACTIVE', PlatformRef = CONCAT('TST-BNK-CAP-26-', FacilityId) WHERE FacilityId = @f;   -- BR-FAC-021
    DELETE FROM #K WHERE k = 'f';
    INSERT #K VALUES ('f', @f);
END;
GO
-- Runs cases @From to @To of a case procedure, each in its own transaction on a new fixture: case:error=result.
CREATE PROCEDURE #KCases @CaseProc SYSNAME, @From INT, @To INT, @Result NVARCHAR(2000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (CaseNo INT PRIMARY KEY, Err INT NOT NULL, Res NVARCHAR(400) NULL);
    DECLARE @i INT = @From, @e INT, @o NVARCHAR(400);
    WHILE @i <= @To
    BEGIN
        SET @o = NULL;
        BEGIN TRANSACTION;
        BEGIN TRY EXEC #KFix; EXEC @CaseProc @i, @o OUTPUT; SET @e = 0; END TRY
        BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
        WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        INSERT @r (CaseNo, Err, Res) VALUES (@i, @e, @o);
        SET @i += 1;
    END;
    SET @Result = (SELECT STRING_AGG(CONCAT(CaseNo, ':', Err, CASE WHEN Res IS NOT NULL THEN CONCAT('=', Res) END), ' ') WITHIN GROUP (ORDER BY CaseNo) FROM @r);
END;
GO
/* FC1: (1) a statement written with another user as its preparer (50170); (2) prepared and submitted by u1, approved
   by u2; (3) an approval naming u2 written while u1 is bound (50170); (4) an approval by u3, who lacks fin.stmt.approve
   (50171); (5) a submission by u2 of u1's statement (50170); (6) an approval under the service account's job binding
   (50170); (7) a rejection by u1, who lacks fin.stmt.approve (50171). */
CREATE PROCEDURE #StmtCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @oth BIGINT = (SELECT v FROM #K WHERE k = 'oth'), @u2 BIGINT = (SELECT v FROM #K WHERE k = 'u2'),
            @u3 BIGINT = (SELECT v FROM #K WHERE k = 'u3'), @svc BIGINT = (SELECT v FROM #K WHERE k = 'svc'), @s BIGINT,
            @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR');
    IF @Case = 1
        INSERT fin.FinancialStatement (TenantId, CompanyId, PeriodType, PeriodEnd, FiscalYear, Basis, Assurance, CurrencyId, EntryMethod, PreparedBy, PreparedOn)
        VALUES (@t, @oth, 'ANNUAL', '2025-12-31', 2025, 'STANDALONE', 'MANAGEMENT', @cur, 'MANUAL', @u2, SYSUTCDATETIME());
    IF @Case = 2
    BEGIN
        EXEC #KStmt @oth, '2025-12-31';
        SELECT @Out = Status FROM fin.FinancialStatement WHERE FinancialStatementId = (SELECT v FROM #K WHERE k = 's');
    END;
    IF @Case IN (3, 4, 5, 6, 7)
    BEGIN
        EXEC #KStmt @oth, '2025-12-31', @Approve = 0;
        SET @s = (SELECT v FROM #K WHERE k = 's');
        IF @Case = 5 EXEC #As 'u2';
        UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @s;
        IF @Case = 3 UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @s;
        IF @Case = 4
        BEGIN
            EXEC #As 'u3';
            UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @u3, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @s;
        END;
        IF @Case = 6
        BEGIN
            EXEC #KBind @t, @svc, 'JOB', 'JOB-FIN-READINESS';
            UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @svc, ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @s;
        END;
        IF @Case = 7 UPDATE fin.FinancialStatement SET Status = 'REJECTED' WHERE FinancialStatementId = @s;
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#StmtCase', 1, 7, @got OUTPUT;
IF @got = '1:50170 2:0=APPROVED 3:50170 4:50171 5:50170 6:50170 7:50171'
    PRINT 'PASS FC1: a statement is prepared, submitted and approved by the users bound to the session, each holding the permission of the act';
ELSE PRINT CONCAT('FAIL FC1: ', @got, ' (expected 1:50170 2:0=APPROVED 3:50170 4:50171 5:50170 6:50170 7:50171)');
GO
/* FC2: (1) a computation by u3, who lacks fin.credit.assess (50171); (2) an input entered under u2's name while u1 is
   bound (50170); (3) an approval naming u2 written while u1 is bound (50170); (4) computed and submitted by u1,
   approved by u2; (5) a submission by u2 of u1's assessment (50170). */
CREATE PROCEDURE #AssessCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @u2 BIGINT = (SELECT v FROM #K WHERE k = 'u2'),
            @a BIGINT;
    EXEC #KStmt @ind, '2025-12-31';
    DECLARE @s BIGINT = (SELECT v FROM #K WHERE k = 's');
    EXEC #KAssess @s, @Compute = 0;
    SET @a = (SELECT v FROM #K WHERE k = 'a');
    IF @Case = 1 BEGIN EXEC #As 'u3'; EXEC fin.usp_ComputeCreditAssessment @a; END;
    IF @Case = 2
        INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, Notches, Justification, EnteredBy) VALUES (@t, @a, 'OVERRIDE', -1, N'test: entered in another name', @u2);
    IF @Case IN (3, 4, 5)
    BEGIN
        EXEC fin.usp_ComputeCreditAssessment @a;
        IF @Case = 5 EXEC #As 'u2';
        UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
        IF @Case = 3 UPDATE fin.CreditAssessment SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
        IF @Case = 4
        BEGIN
            EXEC #As 'u2';
            UPDATE fin.CreditAssessment SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
            SELECT @Out = Status FROM fin.CreditAssessment WHERE CreditAssessmentId = @a;
        END;
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#AssessCase', 1, 5, @got OUTPUT;
IF @got = '1:50171 2:50170 3:50170 4:0=APPROVED 5:50170'
    PRINT 'PASS FC2: an assessment is computed, submitted and approved, and its inputs entered, by the users bound to the session with the permission of the act';
ELSE PRINT CONCAT('FAIL FC2: ', @got, ' (expected 1:50171 2:50170 3:50170 4:0=APPROVED 5:50170)');
GO
/* FC3: (1) a presentation version of an approved statement (50090, owner decision 34: before the final approval);
   (2) a version of a draft built by u6, not its preparer (50170); (3) built by u1, chosen by u3 who lacks
   fin.stmt.approve (50171); (4) chosen by u2. */
CREATE PROCEDURE #VersionCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @u1 BIGINT = (SELECT v FROM #K WHERE k = 'u1'),
            @s BIGINT, @v BIGINT, @sub INT = (SELECT CreditRemedyId FROM fin.CreditRemedy WHERE Code = 'CONVERT_DUE_TO_RELATED_TO_SUB');
    ALTER TABLE fin.PresentationVersionStep NOCHECK CONSTRAINT FK_PresentationVersionStep_DocumentId;
    DECLARE @approve BIT = CASE WHEN @Case = 1 THEN 1 ELSE 0 END;
    EXEC #KStmt @ind, '2025-12-31', @Approve = @approve;
    SET @s = (SELECT v FROM #K WHERE k = 's');
    INSERT fin.PresentationVersion (TenantId, SourceStatementId, NameAr, PreparedBy) VALUES (@t, @s, N'نسخة', @u1);
    SET @v = SCOPE_IDENTITY();
    INSERT fin.PresentationVersionStep (TenantId, VersionId, StepNo, RemedyId, DocumentId, EvidenceDate, Justification)
    VALUES (@t, @v, 1, @sub, 1, '2025-12-15', N'اتفاقية مساندة موقعة من الشركاء');
    IF @Case = 2 EXEC #As 'u6';
    EXEC fin.usp_BuildPresentationVersion @v;
    IF @Case = 3 BEGIN EXEC #As 'u3'; EXEC fin.usp_ChoosePresentationVersion @v, N'test: the stronger presentation'; END;
    IF @Case = 4
    BEGIN
        EXEC #As 'u2';
        EXEC fin.usp_ChoosePresentationVersion @v, N'test: the stronger presentation';
        SELECT @Out = Status FROM fin.PresentationVersion WHERE PresentationVersionId = @v;
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#VersionCase', 1, 4, @got OUTPUT;
IF @got = '1:50090 2:50170 3:50171 4:0=CHOSEN'
    PRINT 'PASS FC3: a presentation version is of a statement before its approval, built by its preparer and chosen by a holder of fin.stmt.approve';
ELSE PRINT CONCAT('FAIL FC3: ', @got, ' (expected 1:50090 2:50170 3:50171 4:0=CHOSEN)');
GO
/* FC4: a bank flow of IND entered by u1, confirmed by u2 and reopened by u4. (1) A flow inserted already confirmed
   (50173); (2) the reopener edits it in its own name (547: the reopener does not edit); (3) u6 edits it leaving u1 as its
   author (50170); (4) u6 edits it in its name and the reopener u4 confirms it (547); (5) u6 edits it, u2 confirms it;
   (6) the confirmer changes the amount while confirming: a change of the content names its author (50170). */
CREATE PROCEDURE #FlowCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @u1 BIGINT = (SELECT v FROM #K WHERE k = 'u1'),
            @u2 BIGINT = (SELECT v FROM #K WHERE k = 'u2'), @u4 BIGINT = (SELECT v FROM #K WHERE k = 'u4'), @u6 BIGINT = (SELECT v FROM #K WHERE k = 'u6'),
            @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR'), @lst INT, @kind INT, @f BIGINT;
    ALTER TABLE fin.BankFlowEntry NOCHECK CONSTRAINT FK_BankFlowEntry_InstitutionId;
    INSERT cat.LookupList (TenantId, Code, NameAr, NameEn, Scope) VALUES (@t, 'FLOW_KIND', N'أنواع التحويل', N'Flow kinds', 'TENANT');
    SET @lst = SCOPE_IDENTITY();
    INSERT cat.LookupItem (TenantId, LookupListId, Code, NameAr) VALUES (@t, @lst, 'TRANSFERRED_TO_BANK', N'محوَّل للبنك');
    SET @kind = SCOPE_IDENTITY();
    IF @Case = 1
    BEGIN
        INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy, Status, ConfirmedBy, ConfirmedOn)
        VALUES (@t, @ind, 1, '2026-01-31', @lst, @kind, 1000000, @cur, @u1, 'CONFIRMED', @u2, SYSUTCDATETIME());
        RETURN;
    END;
    INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy)
    VALUES (@t, @ind, 1, '2026-01-31', @lst, @kind, 1000000, @cur, @u1);
    SET @f = SCOPE_IDENTITY();
    EXEC #As 'u2';
    IF @Case = 6
    BEGIN
        UPDATE fin.BankFlowEntry SET Status = 'CONFIRMED', ConfirmedBy = @u2, ConfirmedOn = SYSUTCDATETIME(), Amount = 2000000 WHERE BankFlowEntryId = @f;
        RETURN;
    END;
    UPDATE fin.BankFlowEntry SET Status = 'CONFIRMED', ConfirmedBy = @u2, ConfirmedOn = SYSUTCDATETIME() WHERE BankFlowEntryId = @f;
    EXEC #As 'u4';
    EXEC fin.usp_ReopenMonthlyFigure 'FLOW', @f, N'test: the bank corrected its advice';
    IF @Case = 2 UPDATE fin.BankFlowEntry SET Amount = 900000, EnteredBy = @u4 WHERE BankFlowEntryId = @f;
    IF @Case = 3 BEGIN EXEC #As 'u6'; UPDATE fin.BankFlowEntry SET Amount = 900000 WHERE BankFlowEntryId = @f; END;
    IF @Case IN (4, 5)
    BEGIN
        EXEC #As 'u6';
        UPDATE fin.BankFlowEntry SET Amount = 900000, EnteredBy = @u6 WHERE BankFlowEntryId = @f;
        IF @Case = 4
        BEGIN
            EXEC #As 'u4';
            UPDATE fin.BankFlowEntry SET Status = 'CONFIRMED', ConfirmedBy = @u4, ConfirmedOn = SYSUTCDATETIME() WHERE BankFlowEntryId = @f;
        END;
        IF @Case = 5
        BEGIN
            EXEC #As 'u2';
            UPDATE fin.BankFlowEntry SET Status = 'CONFIRMED', ConfirmedBy = @u2, ConfirmedOn = SYSUTCDATETIME() WHERE BankFlowEntryId = @f;
            SELECT @Out = CONCAT(Status, ' ', CASE WHEN EnteredBy = @u6 THEN 'u6' ELSE 'other' END, ' ', CAST(Amount AS INT)) FROM fin.BankFlowEntry WHERE BankFlowEntryId = @f;
        END;
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#FlowCase', 1, 6, @got OUTPUT;
IF @got = '1:50173 2:547 3:50170 4:547 5:0=CONFIRMED u6 900000 6:50170'
    PRINT 'PASS FC4: a monthly figure is entered as a draft, the edit after a reopening names its editor, and neither the reopener nor the editor confirms it';
ELSE PRINT CONCAT('FAIL FC4: ', @got, ' (expected 1:50173 2:547 3:50170 4:547 5:0=CONFIRMED u6 900000 6:50170)');
GO
/* FC5: a revenue estimate of IND for 2026. (1) Inserted approved (50173); (2) approved by u3, who lacks
   fin.stmt.approve (50171); (3) its amount changed once approved (50173); (4) the approver changes the amount while
   approving (50172); (5) approved by u2 and superseded by u2; (6) a draft of u1 changed by u6 under u1's name (50170). */
CREATE PROCEDURE #EstimateCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @u1 BIGINT = (SELECT v FROM #K WHERE k = 'u1'),
            @u2 BIGINT = (SELECT v FROM #K WHERE k = 'u2'), @u3 BIGINT = (SELECT v FROM #K WHERE k = 'u3'), @e BIGINT,
            @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR');
    IF @Case = 1
    BEGIN
        INSERT fin.RevenueEstimate (TenantId, CompanyId, FiscalYear, Basis, Amount, CurrencyId, BasisNote, Status, PreparedBy, ApprovedBy, ApprovedOn)
        VALUES (@t, @ind, 2026, 'STANDALONE', 40000000, @cur, N'Budget', 'APPROVED', @u1, @u2, SYSUTCDATETIME());
        RETURN;
    END;
    INSERT fin.RevenueEstimate (TenantId, CompanyId, FiscalYear, Basis, Amount, CurrencyId, BasisNote, PreparedBy)
    VALUES (@t, @ind, 2026, 'STANDALONE', 40000000, @cur, N'Budget', @u1);
    SET @e = SCOPE_IDENTITY();
    IF @Case = 6 BEGIN EXEC #As 'u6'; UPDATE fin.RevenueEstimate SET Amount = 41000000 WHERE RevenueEstimateId = @e; RETURN; END;
    IF @Case = 2 BEGIN EXEC #As 'u3'; UPDATE fin.RevenueEstimate SET Status = 'APPROVED', ApprovedBy = @u3, ApprovedOn = SYSUTCDATETIME() WHERE RevenueEstimateId = @e; RETURN; END;
    EXEC #As 'u2';
    IF @Case = 4 BEGIN UPDATE fin.RevenueEstimate SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME(), Amount = 50000000 WHERE RevenueEstimateId = @e; RETURN; END;
    UPDATE fin.RevenueEstimate SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE RevenueEstimateId = @e;
    IF @Case = 3 UPDATE fin.RevenueEstimate SET Amount = 41000000 WHERE RevenueEstimateId = @e;
    IF @Case = 5
    BEGIN
        UPDATE fin.RevenueEstimate SET Status = 'SUPERSEDED' WHERE RevenueEstimateId = @e;
        SELECT @Out = Status FROM fin.RevenueEstimate WHERE RevenueEstimateId = @e;
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#EstimateCase', 1, 6, @got OUTPUT;
IF @got = '1:50173 2:50171 3:50173 4:50172 5:0=SUPERSEDED 6:50170'
    PRINT 'PASS FC5: a revenue estimate is a draft of its preparer, approved as prepared by a holder of fin.stmt.approve, and once approved only superseded';
ELSE PRINT CONCAT('FAIL FC5: ', @got, ' (expected 1:50173 2:50171 3:50173 4:50172 5:0=SUPERSEDED 6:50170)');
GO
/* FC6: (1) the pack's default rate approved by u2; (2) an approved rate changed (50173); (3) an approved rate deleted
   (50173); (4) a user's draft rate without a preparer (547); (5) a rate prepared by u1 and approved by u1 (547). */
CREATE PROCEDURE #RateCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #K WHERE k = 'u1'), @u2 BIGINT = (SELECT v FROM #K WHERE k = 'u2'), @r BIGINT;
    IF @Case = 4
    BEGIN
        INSERT fin.ReceivableLossRate (TenantId, BucketCode, LossRatePct, EffectiveFrom) VALUES (@t, 'AR_AGE_0_90', 1.5, '2026-01-01');
        RETURN;
    END;
    IF @Case = 5
    BEGIN
        INSERT fin.ReceivableLossRate (TenantId, BucketCode, LossRatePct, EffectiveFrom, PreparedBy) VALUES (@t, 'AR_AGE_0_90', 1.5, '2026-01-01', @u1);
        UPDATE fin.ReceivableLossRate SET Status = 'APPROVED', ApprovedBy = @u1, ApprovedOn = SYSUTCDATETIME() WHERE TenantId = @t;
        RETURN;
    END;
    INSERT fin.ReceivableLossRate (TenantId, BucketCode, LossRatePct, EffectiveFrom, Status, Note, SeedKey)
    VALUES (@t, 'AR_AGE_0_90', 1.0, '2000-01-01', 'DRAFT', N'Current receivables up to 90 days', 'FIN.PROVISION.AR_AGE_0_90');
    SET @r = SCOPE_IDENTITY();
    EXEC #As 'u2';
    UPDATE fin.ReceivableLossRate SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE ReceivableLossRateId = @r;
    IF @Case = 1 SELECT @Out = Status FROM fin.ReceivableLossRate WHERE ReceivableLossRateId = @r;
    IF @Case = 2 UPDATE fin.ReceivableLossRate SET LossRatePct = 2 WHERE ReceivableLossRateId = @r;
    IF @Case = 3 DELETE fin.ReceivableLossRate WHERE ReceivableLossRateId = @r;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#RateCase', 1, 5, @got OUTPUT;
IF @got = '1:0=APPROVED 2:50173 3:50173 4:547 5:547'
    PRINT 'PASS FC6: a loss rate is approved by a holder of fin.formula.approve who did not prepare it, and an approved rate stays as it is';
ELSE PRINT CONCAT('FAIL FC6: ', @got, ' (expected 1:0=APPROVED 2:50173 3:50173 4:547 5:547)');
GO
/* FC7: IND's statement of 2025 approved and assessed (approved), then IND's periods closed through 2025-12-31 by u2.
   (1) A new official assessment of the statement (50096); (2) a trial of it; (3) the approved assessment superseded
   (50096); (4) a revenue estimate of 2025 (50096); (5) a lender rating of November 2025 (50096); (6) product lines of 2024, a year the close covers
   (50096); (7) a loss rate effective in June 2025 (50096); (8) the holding closes 2025 with its approved
   consolidated statement that includes IND (IND itself not closed): a new statement of IND for 2025 (50096);
   (9) the approved assessment endorsed after the close. */
CREATE PROCEDURE #CloseCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @hold BIGINT = (SELECT v FROM #K WHERE k = 'hold'),
            @u1 BIGINT = (SELECT v FROM #K WHERE k = 'u1'), @s BIGINT, @a BIGINT, @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR');
    ALTER TABLE fin.LenderRating NOCHECK CONSTRAINT FK_LenderRating_LenderInstitutionId;
    IF @Case = 8
    BEGIN
        EXEC #KStmt @hold, '2025-12-31', @Basis = 'CONSOLIDATED';
        EXEC #As 'u2';
        EXEC fin.usp_LockReportingPeriod @hold, '2025-12-31', N'test: the consolidated statements of 2025 are approved';
        EXEC #KStmt @ind, '2025-12-31', @Approve = 0;
        RETURN;
    END;
    EXEC #KStmt @ind, '2025-12-31';
    SET @s = (SELECT v FROM #K WHERE k = 's');
    EXEC #KAssess @s;
    SET @a = (SELECT v FROM #K WHERE k = 'a');
    EXEC #KApprove @a;
    EXEC #As 'u2';
    EXEC fin.usp_LockReportingPeriod @ind, '2025-12-31', N'test: the audited statements of 2025 are approved';
    EXEC #As 'u1';
    IF @Case = 1 EXEC #KAssess @s, @Compute = 0;
    IF @Case = 2 BEGIN EXEC #KAssess @s, @Trial = 1; SELECT @Out = CONCAT(IsTrial, ' ', ResultState) FROM fin.CreditAssessment WHERE CreditAssessmentId = (SELECT v FROM #K WHERE k = 'a'); END;
    IF @Case = 3 BEGIN EXEC #As 'u2'; UPDATE fin.CreditAssessment SET Status = 'SUPERSEDED' WHERE CreditAssessmentId = @a; END;
    IF @Case = 4
        INSERT fin.RevenueEstimate (TenantId, CompanyId, FiscalYear, Basis, Amount, CurrencyId, BasisNote, PreparedBy)
        VALUES (@t, @ind, 2025, 'STANDALONE', 40000000, @cur, N'Budget', @u1);
    IF @Case = 5
        INSERT fin.LenderRating (TenantId, CompanyId, LenderInstitutionId, RatingDate, GradeId, MappingKind, NoSourceReason)
        VALUES (@t, @ind, 1, '2025-11-30', (SELECT RatingGradeId FROM fin.RatingGrade WHERE Code = 'Ba2'), 'GIVEN_BY_LENDER', N'test fixture');
    IF @Case = 6
        INSERT fin.CompanyProductLine (TenantId, CompanyId, FiscalYear, NameAr, ProductCategoryId, RevenueSharePct)
        SELECT @t, @ind, 2024, N'منتج', ProductCategoryId, 100 FROM fin.ProductCategory WHERE Code = 'ESSENTIAL_STAPLE';
    IF @Case = 7
        INSERT fin.ReceivableLossRate (TenantId, BucketCode, LossRatePct, EffectiveFrom, PreparedBy) VALUES (@t, 'AR_AGE_0_90', 1.5, '2025-06-30', @u1);
    IF @Case = 9
    BEGIN
        EXEC #As 'u7';
        EXEC fin.usp_EndorseCreditAssessment @a, N'For the lender, after the close';
        SELECT @Out = CASE WHEN EndorsedBy IS NOT NULL THEN 'endorsed' ELSE 'not' END FROM fin.CreditAssessment WHERE CreditAssessmentId = @a;
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#CloseCase', 1, 9, @got OUTPUT;
IF @got = '1:50096 2:0=1 RATED 3:50096 4:50096 5:50096 6:50096 7:50096 8:50096 9:0=endorsed'
    PRINT 'PASS FC7: a closed period refuses what changes it indirectly (assessments, estimates, ratings, product lines, loss rates, a unit of a closed consolidation), and keeps trials and endorsements';
ELSE PRINT CONCAT('FAIL FC7: ', @got, ' (expected 1:50096 2:0=1 RATED 3:50096 4:50096 5:50096 6:50096 7:50096 8:50096 9:0=endorsed)');
GO
/* FC8: (1) a lender rating confirmed against the lender's letter is changed (50173); (2) a rating that an endorsed
   assessment read is deleted (50173); (3) the product lines of 2025, read by IND's approved assessment of 2025, are
   changed (50173); (4) those of 2026 still change. */
CREATE PROCEDURE #FrozenCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @u2 BIGINT = (SELECT v FROM #K WHERE k = 'u2'),
            @s BIGINT, @a BIGINT, @r BIGINT, @cat INT = (SELECT ProductCategoryId FROM fin.ProductCategory WHERE Code = 'ESSENTIAL_STAPLE');
    ALTER TABLE fin.LenderRating NOCHECK CONSTRAINT FK_LenderRating_LenderInstitutionId;
    ALTER TABLE fin.LenderRating NOCHECK CONSTRAINT FK_LenderRating_SourceDocumentId;
    IF @Case = 1
    BEGIN
        INSERT fin.LenderRating (TenantId, CompanyId, LenderInstitutionId, RatingDate, GradeId, MappingKind, SourceDocumentId, SourcePage, Confidence, VerifiedBy, VerifiedOn)
        VALUES (@t, @ind, 1, '2026-05-15', (SELECT RatingGradeId FROM fin.RatingGrade WHERE Code = 'Ba2'), 'GIVEN_BY_LENDER', 1, '1', 'CONFIRMED_AGAINST_ORIGINAL', @u2, SYSUTCDATETIME());
        SET @r = SCOPE_IDENTITY();
        UPDATE fin.LenderRating SET LenderReasons = N'changed' WHERE LenderRatingId = @r;
        RETURN;
    END;
    INSERT fin.CompanyProductLine (TenantId, CompanyId, FiscalYear, NameAr, ProductCategoryId, RevenueSharePct)
    VALUES (@t, @ind, 2025, N'منتج', @cat, 100), (@t, @ind, 2026, N'منتج', @cat, 100);
    EXEC #KStmt @ind, '2025-12-31';
    SET @s = (SELECT v FROM #K WHERE k = 's');
    EXEC #KAssess @s;
    SET @a = (SELECT v FROM #K WHERE k = 'a');
    EXEC #KApprove @a;
    IF @Case = 2
    BEGIN
        INSERT fin.LenderRating (TenantId, CompanyId, LenderInstitutionId, RatingDate, GradeId, MappingKind, NoSourceReason)
        VALUES (@t, @ind, 1, '2026-05-15', (SELECT RatingGradeId FROM fin.RatingGrade WHERE Code = 'Ba2'), 'GIVEN_BY_LENDER', N'test fixture');
        SET @r = SCOPE_IDENTITY();
        EXEC #As 'u7';
        EXEC fin.usp_EndorseCreditAssessment @a, N'For the lender';
        EXEC #As 'u1';
        DELETE fin.LenderRating WHERE LenderRatingId = @r;
    END;
    IF @Case = 3 UPDATE fin.CompanyProductLine SET RevenueSharePct = 90 WHERE TenantId = @t AND FiscalYear = 2025;
    IF @Case = 4
    BEGIN
        UPDATE fin.CompanyProductLine SET RevenueSharePct = 90 WHERE TenantId = @t AND FiscalYear = 2026;
        SELECT @Out = CAST(RevenueSharePct AS INT) FROM fin.CompanyProductLine WHERE TenantId = @t AND FiscalYear = 2026;
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#FrozenCase', 1, 4, @got OUTPUT;
IF @got = '1:50173 2:50173 3:50173 4:0=90'
    PRINT 'PASS FC8: a verified lender rating, a rating an endorsement read and the product lines an approved assessment read stay as they were';
ELSE PRINT CONCAT('FAIL FC8: ', @got, ' (expected 1:50173 2:50173 3:50173 4:0=90)');
GO
/* FC9: IND's statement of 2025, a facility expiring in 100 days (RED, the liquidity SGL-4). (1) A lender rating beside a
   computed draft only: the comparison shows the draft, the calibration has no row; (2) the assessment approved, a
   newer draft computed: the warning of the renewal is the approved assessment's (a tie goes to the approved one);
   (3) the facility renewed to a year later after the computation: the early warning reads the facility as it is now and
   raises nothing, while the readiness on the assessment's date keeps what it read. */
CREATE PROCEDURE #WarnCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @s BIGINT, @a BIGINT, @b BIGINT, @r BIGINT,
            @d DATE = CAST(SYSUTCDATETIME() AS DATE), @e DATE;
    ALTER TABLE fin.LenderRating NOCHECK CONSTRAINT FK_LenderRating_LenderInstitutionId;
    SET @e = DATEADD(DAY, 100, @d);
    EXEC #KFacility @e;
    EXEC #KStmt @ind, '2025-12-31';
    SET @s = (SELECT v FROM #K WHERE k = 's');
    EXEC #KAssess @s, @AsOf = @d;
    SET @a = (SELECT v FROM #K WHERE k = 'a');
    IF @Case = 1
    BEGIN
        INSERT fin.LenderRating (TenantId, CompanyId, LenderInstitutionId, RatingDate, GradeId, MappingKind, NoSourceReason)
        VALUES (@t, @ind, 1, @d, (SELECT RatingGradeId FROM fin.RatingGrade WHERE Code = 'B1'), 'GIVEN_BY_LENDER', N'test fixture');
        SET @r = SCOPE_IDENTITY();
        SELECT @Out = CONCAT(CASE WHEN AssessmentId = @a THEN 'draft' ELSE 'other' END, ' ',
                             (SELECT COUNT(*) FROM fin.v_LenderRatingCalibration WHERE TenantId = @t AND CompanyId = @ind))
        FROM fin.v_LenderRatingComparison WHERE LenderRatingId = @r;
    END;
    IF @Case = 2
    BEGIN
        EXEC #KApprove @a;
        EXEC #KAssess @s, @AsOf = @d;
        SET @b = (SELECT v FROM #K WHERE k = 'a');
        SELECT @Out = CONCAT(COUNT(*), ' ', MIN(EventKind), ' ', MIN(Readiness), ' ', CASE WHEN MIN(AssessmentId) = @a AND MAX(AssessmentId) = @a THEN 'approved' ELSE 'draft' END)
        FROM fin.v_CreditEarlyWarnings WHERE CompanyId = @ind;
    END;
    IF @Case = 3
    BEGIN
        EXEC #KApprove @a;
        UPDATE fac.Facility SET ExpiryDate = DATEADD(YEAR, 1, @e) WHERE FacilityId = (SELECT v FROM #K WHERE k = 'f');
        SELECT @Out = CONCAT((SELECT COUNT(*) FROM fin.v_CreditEarlyWarnings WHERE CompanyId = @ind AND EventKind = 'RENEWAL'), ' ',
                             (SELECT COUNT(*) FROM fin.v_CreditReadinessEvents WHERE AssessmentId = @a AND EventKind = 'RENEWAL'));
    END;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#WarnCase', 1, 3, @got OUTPUT;
IF @got = '1:0=draft 0 2:0=1 RENEWAL RED approved 3:0=0 1'
    PRINT 'PASS FC9: the calibration reads approved assessments only, and the early warnings read the approved assessment and the facility as it is now';
ELSE PRINT CONCAT('FAIL FC9: ', @got, ' (expected 1:0=draft 0 2:0=1 RENEWAL RED approved 3:0=0 1)');
GO
/* FC10: IND's assessment, with a facility, approved and endorsed by u7. (1) Its evidence pack holds the hash of what the
   computation read, the two inputs with their justification, the facility it read, the scorecard by code and version
   with its methodology hash, and the covenants (none); (2) once superseded, no pack is built (50095). */
CREATE PROCEDURE #PackCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @s BIGINT, @a BIGINT, @pack NVARCHAR(MAX), @h VARBINARY(32);
    EXEC #KFacility '2027-12-31';
    EXEC #KStmt @ind, '2025-12-31';
    SET @s = (SELECT v FROM #K WHERE k = 's');
    EXEC #KAssess @s;
    SET @a = (SELECT v FROM #K WHERE k = 'a');
    EXEC #KApprove @a;
    EXEC #As 'u7';
    EXEC fin.usp_EndorseCreditAssessment @a, N'For the lender';
    IF @Case = 2 BEGIN EXEC #As 'u2'; UPDATE fin.CreditAssessment SET Status = 'SUPERSEDED' WHERE CreditAssessmentId = @a; EXEC #As 'u7'; END;
    EXEC fin.usp_BuildAssessmentEvidencePack @a, N'For the lender', @pack OUTPUT, @h OUTPUT;
    SET @Out = CONCAT(CASE WHEN JSON_VALUE(@pack COLLATE DATABASE_DEFAULT, '$.inputsHash') = (SELECT InputsHash FROM fin.CreditAssessment WHERE CreditAssessmentId = @a) THEN 'hash' ELSE 'nohash' END, ' ',
                      (SELECT COUNT(*) FROM OPENJSON(@pack COLLATE DATABASE_DEFAULT, '$.inputs')), ' ', JSON_VALUE(@pack COLLATE DATABASE_DEFAULT, '$.inputs[0].Justification'), ' ',
                      (SELECT COUNT(*) FROM OPENJSON(@pack COLLATE DATABASE_DEFAULT, '$.facilities')), ' ', JSON_VALUE(@pack COLLATE DATABASE_DEFAULT, '$.scorecard.Code'), ' ', JSON_VALUE(@pack COLLATE DATABASE_DEFAULT, '$.scorecard.VersionNo'), ' ',
                      LEN(JSON_VALUE(@pack COLLATE DATABASE_DEFAULT, '$.scorecard.MethodologySha256')), ' ', CASE WHEN JSON_QUERY(@pack COLLATE DATABASE_DEFAULT, '$.snapshot') IS NOT NULL THEN 'snapshot' ELSE 'nosnapshot' END);
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#PackCase', 1, 2, @got OUTPUT;
IF @got LIKE '1:0=hash 2 test fixture: the worked example of docs/35 1 GENERAL[_]CORPORATE % 64 snapshot 2:50095'
    PRINT 'PASS FC10: the evidence pack holds what the computation read, its inputs, facilities and methodology, and is built of the approved assessment only';
ELSE PRINT CONCAT('FAIL FC10: ', @got, ' (expected 1:0=hash 2 test fixture: the worked example of docs/35 1 GENERAL_CORPORATE <version> 64 snapshot 2:50095)');
GO
/* FC11: IND's assessment computed with its facility; (1) the use of the facility changed before the submission
   (50063); (2) a lender decision on the facility recorded before the submission (50063); (3) unchanged, it is
   submitted. */
CREATE PROCEDURE #HashCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @s BIGINT, @a BIGINT, @f BIGINT;
    EXEC #KFacility '2027-12-31';
    SET @f = (SELECT v FROM #K WHERE k = 'f');
    EXEC #KStmt @ind, '2025-12-31';
    SET @s = (SELECT v FROM #K WHERE k = 's');
    EXEC #KAssess @s;
    SET @a = (SELECT v FROM #K WHERE k = 'a');
    IF @Case = 1 UPDATE fac.Utilization SET Amount = 200000000 WHERE TenantId = @t AND FacilityId = @f;
    IF @Case = 2
        INSERT fac.FacilityLenderDecision (TenantId, FacilityId, DecisionDate, EffectiveDate, LimitAction, NoSourceReason)
        VALUES (@t, @f, '2026-03-01', '2026-03-15', 'NOT_RENEWED', N'test fixture');
    UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE CreditAssessmentId = @a;
    SELECT @Out = Status FROM fin.CreditAssessment WHERE CreditAssessmentId = @a;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#HashCase', 1, 3, @got OUTPUT;
IF @got = '1:50063 2:50063 3:0=SUBMITTED'
    PRINT 'PASS FC11: the platform data an assessment read is in its hash, so a change after the computation refuses the submission';
ELSE PRINT CONCAT('FAIL FC11: ', @got, ' (expected 1:50063 2:50063 3:0=SUBMITTED)');
GO
/* FC12: OTH, a company with no parent, in the holding's approved consolidated statement of 2025: (1) as an associate,
   the holding's approved assessment gives it no group support (50065); (2) as a subsidiary consolidated in full, it
   does. */
CREATE PROCEDURE #SupportCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #K WHERE k = 't'), @hold BIGINT = (SELECT v FROM #K WHERE k = 'hold'), @oth BIGINT = (SELECT v FROM #K WHERE k = 'oth'),
            @u1 BIGINT = (SELECT v FROM #K WHERE k = 'u1'), @hs BIGINT, @ha BIGINT, @os BIGINT, @oa BIGINT;
    EXEC #KStmt @hold, '2025-12-31', @Basis = 'CONSOLIDATED', @Approve = 0;
    SET @hs = (SELECT v FROM #K WHERE k = 's');
    INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method, OwnershipPct)
    VALUES (@t, @hs, @oth, CASE WHEN @Case = 1 THEN 'ASSOCIATE' ELSE 'SUBSIDIARY' END, CASE WHEN @Case = 1 THEN 'EQUITY' ELSE 'FULL' END, CASE WHEN @Case = 1 THEN 30 ELSE 90 END);
    UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE FinancialStatementId = @hs;
    EXEC #As 'u2';
    UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = (SELECT v FROM #K WHERE k = 'u2'), ApprovedOn = SYSUTCDATETIME() WHERE FinancialStatementId = @hs;
    EXEC #KAssess @hs;
    SET @ha = (SELECT v FROM #K WHERE k = 'a');
    EXEC #KApprove @ha;
    EXEC #KStmt @oth, '2025-12-31';
    SET @os = (SELECT v FROM #K WHERE k = 's');
    EXEC #KAssess @os, @Compute = 0;
    SET @oa = (SELECT v FROM #K WHERE k = 'a');
    INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, Notches, ParentAssessmentId, Justification, EnteredBy)
    VALUES (@t, @oa, 'GROUP_SUPPORT', 1, @ha, N'test: the holding supports the company', @u1);
    SET @Out = 'support';
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#SupportCase', 1, 2, @got OUTPUT;
IF @got = '1:50065 2:0=support'
    PRINT 'PASS FC12: group support comes from a holding that controls the company and consolidates it in full, not from an investor';
ELSE PRINT CONCAT('FAIL FC12: ', @got, ' (expected 1:50065 2:0=support)');
GO
/* FC13: IND's receivables (SAR millions, AR 160, allowance 2): (1) an ageing of 100, 30, 20 and 10 that adds up to the
   gross 162 within 1 percent is checked; (2) an ageing of 100 and 30 only, against the gross of 162, is INCOMPLETE; (3) a
   negative allowance is INCOMPLETE. */
CREATE PROCEDURE #ProvisionCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @s BIGINT,
            @ov NVARCHAR(400) = CASE @Case WHEN 1 THEN N'AR_AGE_0_90=100;AR_AGE_91_180=30;AR_AGE_181_365=21;AR_AGE_OVER_365=10;AR_ECL_ALLOWANCE=2'
                                           WHEN 2 THEN N'AR_AGE_0_90=100;AR_AGE_91_180=30;AR_ECL_ALLOWANCE=2'
                                           ELSE N'AR_AGE_0_90=100;AR_AGE_91_180=30;AR_AGE_181_365=21;AR_AGE_OVER_365=10;AR_ECL_ALLOWANCE=-2' END;
    EXEC #KStmt @ind, '2025-12-31', @ov, @Approve = 0;
    SET @s = (SELECT v FROM #K WHERE k = 's');
    SELECT @Out = Status FROM fin.v_ReceivableProvisionCheck WHERE StatementId = @s;
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#ProvisionCase', 1, 3, @got OUTPUT;
IF @got = '1:0=NO_RATES 2:0=INCOMPLETE 3:0=INCOMPLETE'
    PRINT 'PASS FC13: the provision matrix is INCOMPLETE when the ageing does not add up to the gross receivables or the allowance is negative';
ELSE PRINT CONCAT('FAIL FC13: ', @got, ' (expected 1:0=NO_RATES 2:0=INCOMPLETE 3:0=INCOMPLETE)');
GO
/* FC14: IND's statement approved by u5, who also holds fin.credit.endorse: (1) u5 cannot endorse its assessment
   (50093); (2) u7 can. */
CREATE PROCEDURE #EndorseCase @Case INT, @Out NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ind BIGINT = (SELECT v FROM #K WHERE k = 'ind'), @s BIGINT, @a BIGINT;
    EXEC #KStmt @ind, '2025-12-31', @Approver = 'u5';
    SET @s = (SELECT v FROM #K WHERE k = 's');
    EXEC #KAssess @s;
    SET @a = (SELECT v FROM #K WHERE k = 'a');
    EXEC #KApprove @a;
    DECLARE @who VARCHAR(10) = CASE WHEN @Case = 1 THEN 'u5' ELSE 'u7' END;
    EXEC #As @who;
    EXEC fin.usp_EndorseCreditAssessment @a, N'For the lender';
    SET @Out = 'endorsed';
END;
GO
DECLARE @got NVARCHAR(2000);
EXEC #KCases '#EndorseCase', 1, 2, @got OUTPUT;
IF @got = '1:50093 2:0=endorsed'
    PRINT 'PASS FC14: the endorser of an assessment did not approve its statement';
ELSE PRINT CONCAT('FAIL FC14: ', @got, ' (expected 1:50093 2:0=endorsed)');
GO
DROP PROCEDURE #EndorseCase, #ProvisionCase, #SupportCase, #HashCase, #PackCase, #WarnCase, #FrozenCase, #CloseCase, #RateCase, #EstimateCase, #FlowCase,
               #VersionCase, #AssessCase, #StmtCase, #KCases, #KFacility, #KApprove, #KAssess, #KStmt, #KFix, #As, #KBind;
DROP TABLE #K;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'UserId', @value = NULL;
PRINT 'Finance controls tests finished; every change is rolled back.';
GO

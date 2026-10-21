/* ============================================================================
   BankFas - synthetic data for the performance measurement (review v5.0 P0-2; NFR-SCL-01, NFR-SCL-02, DOC-B03
   section 6, DOC-B06; ADR 0036). Run by tools/perf/run_perf.sh on a throwaway database only, never on real data.

   Two kinds of tenant, each written through the same tables, keys, checks and triggers as the application's data:
     full tenants ($(FullTenants))   the volume of NFR-SCL-02 on the tables the database's own paths read:
                                     $(Companies) companies, each with $(Years) approved annual statements of 55 standard
                                     lines, a facility with its lender, limit, use and covenant, 57 confirmed monthly bank
                                     flows and a computed, approved credit assessment; $(AuditRows) audit rows and
                                     $(Sessions) past sessions; the roles of the pack CORE.ROLES (057).
     light tenants ($(LightTenants)) a company, a statement, $(LightAudit) audit rows and 500 sessions, so that the
                                     shared tables hold 300 tenants (NFR-SCL-01) as the measured tenant's neighbours.
   Every tenant has an ACTIVE data key, an MFA-enrolled treasury manager and 200 open, MFA-checked sessions whose
   tokens are 'perf-<tenant>-<n>' (used by the binding measurement, NFR-PERF-06).
   The writes run as sa bound to each tenant the way the binding procedure binds, so the row filters and triggers
   run on every row. Nothing is switched off, except where a test fixture would do it: nothing here.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF EXISTS (SELECT 1 FROM plat.Tenant WHERE Code LIKE 'perf-%') THROW 50990, 'perf_seed.sql runs once on a fresh throwaway database', 1;
GO
CREATE TABLE #P (k VARCHAR(20) COLLATE DATABASE_DEFAULT PRIMARY KEY, v BIGINT);
GO
CREATE PROCEDURE #Bind @TenantId INT, @UserId BIGINT, @Kind VARCHAR(7) = 'USER', @JobKey VARCHAR(80) = NULL
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
/* A tenant with its key, users, roles, catalogues and banks ('t', 'u1' analyst FA, 'u2' treasury manager TM, 'u3'
   risk officer RK, 'u4' treasury employee TE, 'svc', 'lst' and 'kind' the flow kind, 'ftype', 'ltype', 'otype',
   'bank1' in #P). */
CREATE PROCEDURE #Tenant @Code VARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM #P;
    DECLARE @t INT, @u1 BIGINT, @u2 BIGINT, @u3 BIGINT, @u4 BIGINT, @svc BIGINT, @key BIGINT, @lst INT, @x INT, @it INT,
            @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'), @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA'),
            @pw VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA';
    INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES (@Code, N'أداء', @Code, @plan, @country, 'ACTIVE', 'Asia/Riyadh');
    SET @t = SCOPE_IDENTITY();
    EXEC #Bind @t, 0;
    INSERT sec.TenantKey (TenantId, Purpose, KeyVersion, Status, WrappedKey, MasterKeyRef, ActivatedAt)
    VALUES (@t, 'DATA', 1, 'ACTIVE', CRYPT_GEN_RANDOM(64), 'kms/perf/data', SYSUTCDATETIME());
    SET @key = SCOPE_IDENTITY();
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, IsSystemUser) VALUES (@t, N'service@perf.invalid', N'Service', 'ACTIVE', 1);
    SET @svc = SCOPE_IDENTITY();
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t, N'fa@perf.invalid', N'Analyst', 'ACTIVE', @pw);
    SET @u1 = SCOPE_IDENTITY();
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash, MfaEnabled, MfaSecretEnc, MfaKeyId, MfaEnrolledAt)
    VALUES (@t, N'tm@perf.invalid', N'Treasury manager', 'ACTIVE', @pw, 1, CRYPT_GEN_RANDOM(48), @key, SYSUTCDATETIME());
    SET @u2 = SCOPE_IDENTITY();
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t, N'rk@perf.invalid', N'Risk officer', 'ACTIVE', @pw);
    SET @u3 = SCOPE_IDENTITY();
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash) VALUES (@t, N'te@perf.invalid', N'Treasury employee', 'ACTIVE', @pw);
    SET @u4 = SCOPE_IDENTITY();
    -- the system roles through the pack, as the onboarding job seeds them
    EXEC #Bind @t, @svc, 'JOB', 'JOB-PLT-ONBOARD';
    EXEC sec.usp_SeedCoreRoles;
    EXEC #Bind @t, @u1;
    INSERT sec.UserRole (TenantId, UserId, RoleId)
    SELECT @t, x.UserId, r.RoleId FROM (VALUES (@u1, 'FA'), (@u2, 'TM'), (@u3, 'RK'), (@u4, 'TE')) AS x (UserId, Code)
    JOIN sec.Role AS r ON r.TenantId = @t AND r.Code = x.Code COLLATE DATABASE_DEFAULT;
    -- catalogues
    INSERT cat.LegalEntityType (TenantId, Code, NameAr) VALUES (@t, 'LLC', N'ذات مسؤولية محدودة');
    INSERT cat.InstitutionType (TenantId, Code, NameAr) VALUES (@t, 'BANK', N'بنك');
    SET @it = SCOPE_IDENTITY();
    INSERT cat.FacilityType (TenantId, Code, NameAr, Compliance) VALUES (@t, 'WORKING_CAPITAL', N'رأس مال عامل', 'CONVENTIONAL');
    INSERT #P VALUES ('ftype', SCOPE_IDENTITY());
    INSERT cat.LimitType (TenantId, Code, NameAr, Kind) VALUES (@t, 'MAIN_LIMIT', N'حد رئيسي', 'MAIN');
    INSERT #P VALUES ('ltype', SCOPE_IDENTITY());
    INSERT cat.ObligationType (TenantId, Code, NameAr, Family, MeasureKind) VALUES (@t, 'COV', N'تعهد', 'COVENANT', 'RATIO');
    INSERT #P VALUES ('otype', SCOPE_IDENTITY());
    INSERT cat.LookupList (TenantId, Code, NameAr, NameEn, Scope) VALUES (@t, 'FLOW_KIND', N'أنواع التحويل', N'Flow kinds', 'TENANT');
    SET @lst = SCOPE_IDENTITY();
    INSERT cat.LookupItem (TenantId, LookupListId, Code, NameAr) VALUES (@t, @lst, 'TRANSFERRED_TO_BANK', N'محوَّل للبنك');
    INSERT #P VALUES ('lst', @lst), ('kind', SCOPE_IDENTITY());
    INSERT ins.Institution (TenantId, Code, NameAr, InstitutionTypeId, CountryId, Status)
    SELECT @t, CONCAT('BANK', n), CONCAT(N'بنك ', n), @it, @country, 'ACTIVE' FROM (VALUES (1), (2), (3), (4), (5)) AS v (n);
    INSERT #P SELECT 'bank1', MIN(InstitutionId) FROM ins.Institution WHERE TenantId = @t;
    INSERT fin.LineCatalogItem (TenantId, Code, NameAr, NameEn, Section, SortOrder)
    SELECT @t, sl.Code, sl.NameAr, sl.NameEn, sl.Section, sl.SortOrder FROM fin.StandardLine AS sl;
    INSERT #P VALUES ('t', @t), ('u1', @u1), ('u2', @u2), ('u3', @u3), ('u4', @u4), ('svc', @svc);
    -- 200 open sessions of the treasury manager, checked by MFA, for the binding measurement
    INSERT sec.UserSession (TenantId, UserId, TokenHash, IdleExpiresAt, AbsoluteExpiresAt, MfaVerifiedAt)
    SELECT @t, @u2, HASHBYTES('SHA2_256', CAST(CONCAT('perf-', @t, '-', n) AS VARBINARY(64))), DATEADD(DAY, 2, SYSUTCDATETIME()),
           DATEADD(DAY, 2, SYSUTCDATETIME()), SYSUTCDATETIME()
    FROM (SELECT TOP (200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) AS x;
END;
GO
/* @Count companies of the current tenant, each with @Years annual statements to 2025 (the base lines of docs/35
   section 14 scaled by the company, so every total still adds up), approved by u2; and, when @Platform = 1, a
   facility with its lender, limit, use, approved revision and an annual flow covenant, and 57 confirmed monthly flows
   to its bank. */
CREATE PROCEDURE #Companies @Count INT, @Years INT, @Platform BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #P WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #P WHERE k = 'u1'), @u2 BIGINT = (SELECT v FROM #P WHERE k = 'u2'),
            @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA'), @cur INT = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR'),
            @let INT;
    SET @let = (SELECT LegalEntityTypeId FROM cat.LegalEntityType WHERE TenantId = @t AND Code = 'LLC');
    DECLARE @n TABLE (n INT PRIMARY KEY);
    INSERT @n SELECT TOP (@Count) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;
    INSERT pty.Party (TenantId, PartyCode, Kind, NameEn) SELECT @t, CONCAT('P', n), 'ORGANIZATION', CONCAT(N'Company ', n) FROM @n;
    INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth, IsHolding)
    SELECT @t, CONCAT('C', n.n), CONCAT(N'شركة ', n.n), CONCAT(N'Company ', n.n), p.PartyId, @let, @country, 12, 0
    FROM @n AS n JOIN pty.Party AS p ON p.TenantId = @t AND p.PartyCode = CONCAT('P', n.n);
    -- statements
    DECLARE @base NVARCHAR(MAX) = N'CASH=45;AR=160;INVENTORY=130;DUE_FROM_RELATED=20;OTHER_CA=25;TOTAL_CA=380;PPE=520;INTANGIBLES=30;OTHER_NCA=70;TOTAL_ASSETS=1000;'
          + N'ST_LOANS=120;CURRENT_PORTION_LTD=60;AP=110;DUE_TO_RELATED=10;OTHER_CL=50;TOTAL_CL=350;LT_LOANS=180;LEASE_LIABS=20;'
          + N'SHAREHOLDER_LOANS_SUB=0;EOSB=18;OTHER_NCL=12;TOTAL_LIABS=580;SHARE_CAPITAL=250;RETAINED_EARNINGS=140;OTHER_EQUITY=30;'
          + N'MINORITY_INTEREST=0;TOTAL_EQUITY=420;REVENUE=900;COGS=650;GROSS_PROFIT=250;OPEX=160;DEPR_AMORT=40;EBITDA=130;'
          + N'OPERATING_PROFIT=90;FINANCE_COSTS=22;OTHER_INCOME=4;ZAKAT_TAX=8;NET_PROFIT=64;OP_CASH_FLOW=95;CAPEX=60;'
          + N'PRINCIPAL_REPAID=55;INTEREST_PAID=21;DIVIDENDS=30;LC_OUTSTANDING=90;LG_PERFORMANCE=100;LG_FINANCIAL=20;GUARANTEES_GIVEN=0';
    DECLARE @lines TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount DECIMAL(19,4));
    INSERT @lines SELECT LEFT(value, CHARINDEX(N'=', value) - 1), CAST(SUBSTRING(value, CHARINDEX(N'=', value) + 1, 20) AS DECIMAL(19,4))
    FROM STRING_SPLIT(@base COLLATE DATABASE_DEFAULT, N';');
    INSERT fin.FinancialStatement (TenantId, CompanyId, PeriodType, PeriodEnd, FiscalYear, Basis, Assurance, CurrencyId, EntryMethod, PreparedBy, PreparedOn,
                                   AuditorName, AuditOpinion)
    SELECT @t, c.CompanyId, 'ANNUAL', DATEFROMPARTS(2025 - y.n + 1, 12, 31), 2025 - y.n + 1, 'STANDALONE', 'AUDITED', @cur, 'MANUAL', @u1, SYSUTCDATETIME(),
           N'Auditor (synthetic)', 'UNQUALIFIED'
    FROM org.Company AS c CROSS JOIN (SELECT TOP (@Years) n FROM @n ORDER BY n) AS y
    WHERE c.TenantId = @t;
    INSERT fin.StatementLine (TenantId, StatementId, LineCatalogItemId, EnteredAmount)
    SELECT @t, s.FinancialStatementId, li.LineCatalogItemId,
           l.Amount * 1000000 * (1 + (c.CompanyId % 10) / 10.0) * (1 + (s.FiscalYear - 2021) / 20.0)
    FROM fin.FinancialStatement AS s
    JOIN org.Company AS c ON c.TenantId = s.TenantId AND c.CompanyId = s.CompanyId
    CROSS JOIN @lines AS l
    JOIN fin.LineCatalogItem AS li ON li.TenantId = @t AND li.Code = l.Code
    WHERE s.TenantId = @t;
    -- prepared by the analyst u1, approved by the treasury manager u2, each bound as itself (058, ADR 0037)
    EXEC #Bind @t, @u1;
    UPDATE fin.FinancialStatement SET Status = 'SUBMITTED' WHERE TenantId = @t AND Status = 'DRAFT';
    EXEC #Bind @t, @u2;
    UPDATE fin.FinancialStatement SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE TenantId = @t AND Status = 'SUBMITTED';
    EXEC #Bind @t, @u1;
    IF @Platform = 0 RETURN;
    -- the platform: a facility per company with one of the five banks, expiring over the next two years
    DECLARE @ftype INT = (SELECT v FROM #P WHERE k = 'ftype'), @ltype INT = (SELECT v FROM #P WHERE k = 'ltype'), @otype INT = (SELECT v FROM #P WHERE k = 'otype'),
            @lst INT = (SELECT v FROM #P WHERE k = 'lst'), @kind INT = (SELECT v FROM #P WHERE k = 'kind'), @bank1 BIGINT = (SELECT v FROM #P WHERE k = 'bank1');
    INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
    SELECT @t, CONCAT('FAC-', c.CompanyId), c.CompanyId, @ftype, @cur, 50000000, 'EN', '2025-01-01', DATEADD(DAY, (c.CompanyId * 7) % 730, '2026-11-01')
    FROM org.Company AS c WHERE c.TenantId = @t;
    INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision)
    SELECT @t, f.FacilityId, @bank1 + f.BorrowerCompanyId % 5, 'SOLE', 100, 1 FROM fac.Facility AS f WHERE f.TenantId = @t;
    INSERT fac.Limit (TenantId, FacilityId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, IsCommitted, FromRevision, NoSourceReason)
    SELECT @t, f.FacilityId, @ltype, 'L1', N'حد', 'ABSOLUTE', 50000000, 1, 1, 1, N'synthetic' FROM fac.Facility AS f WHERE f.TenantId = @t;
    INSERT fac.Utilization (TenantId, FacilityId, LimitId, CompanyId, Reference, Amount, CurrencyId, StartDate)
    SELECT @t, l.FacilityId, l.LimitId, f.BorrowerCompanyId, N'synthetic use', 30000000, @cur, '2025-02-01'
    FROM fac.Limit AS l JOIN fac.Facility AS f ON f.TenantId = l.TenantId AND f.FacilityId = l.FacilityId WHERE l.TenantId = @t;
    -- the covenant belongs to revision 1, so it is written before the revision is approved (BR-FAC-003)
    INSERT obl.Obligation (TenantId, FacilityId, Family, ObligationTypeId, TitleAr, ClauseRef, ValidFrom, NoSourceReason)
    SELECT @t, f.FacilityId, 'COVENANT', @otype, N'تعهدات مالية', N'14.2', '2025-01-01', N'synthetic' FROM fac.Facility AS f WHERE f.TenantId = @t;
    INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, Operator, ThresholdState, ThresholdValue, ThresholdUnit, CurrencyId, TestFrequency,
                         AnnualWindowBasis, TestedCompanyId, FirstTestPeriodEnd, ValidFrom)
    SELECT @t, o.ObligationId, 'FLOW_VOLUME', 'GE', 'SET', 12000000, 'AMOUNT', @cur, 'ANNUAL', 'FISCAL_YEAR', f.BorrowerCompanyId, '2026-12-31', '2025-01-01'
    FROM obl.Obligation AS o JOIN fac.Facility AS f ON f.TenantId = o.TenantId AND f.FacilityId = o.FacilityId WHERE o.TenantId = @t;
    INSERT fac.FacilityRevision (TenantId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn, SubmittedBy, SubmittedOn, ApprovedBy, ApprovedOn)
    SELECT @t, f.FacilityId, 1, 'INITIAL', 'APPROVED', '2025-01-01', @u1, SYSUTCDATETIME(), @u2, SYSUTCDATETIME() FROM fac.Facility AS f WHERE f.TenantId = @t;
    UPDATE fac.Facility SET ApprovedRevisionNo = 1, LifecycleStatus = 'ACTIVE' WHERE TenantId = @t;
    -- entered by the treasury employee u4, confirmed by the treasury manager u2 (058, ADR 0037)
    DECLARE @u4 BIGINT = (SELECT v FROM #P WHERE k = 'u4');
    EXEC #Bind @t, @u4;
    INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindListId, FlowKindId, Amount, CurrencyId, EnteredBy)
    SELECT @t, f.BorrowerCompanyId, @bank1 + f.BorrowerCompanyId % 5, EOMONTH(DATEADD(MONTH, m.n - 1, '2022-01-01')), @lst, @kind,
           900000 + (f.BorrowerCompanyId % 7) * 100000, @cur, @u4
    FROM fac.Facility AS f CROSS JOIN (SELECT TOP (57) n FROM @n ORDER BY n) AS m
    WHERE f.TenantId = @t;
    EXEC #Bind @t, @u2;
    UPDATE fin.BankFlowEntry SET Status = 'CONFIRMED', ConfirmedBy = @u2, ConfirmedOn = SYSUTCDATETIME() WHERE TenantId = @t AND Status = 'DRAFT';
    EXEC #Bind @t, @u1;
END;
GO
/* A computed and approved credit assessment of each company's 2025 statement, prepared by u1, approved by u2; the
   first @Endorse of them endorsed by the risk officer u3. Returns the computation times in #Compute. */
CREATE PROCEDURE #Assessments @Endorse INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #P WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #P WHERE k = 'u1'), @u2 BIGINT = (SELECT v FROM #P WHERE k = 'u2'),
            @u3 BIGINT = (SELECT v FROM #P WHERE k = 'u3'), @a BIGINT, @t0 DATETIME2(7), @i INT = 0;
    INSERT fin.CreditAssessment (TenantId, CompanyId, StatementId, ScorecardId, AssessmentDate, PreparedBy)
    SELECT @t, s.CompanyId, s.FinancialStatementId, (SELECT ScorecardId FROM fin.Scorecard WHERE Code = 'GENERAL_CORPORATE' AND Status = 'APPROVED'), '2026-04-30', @u1
    FROM fin.FinancialStatement AS s WHERE s.TenantId = @t AND s.FiscalYear = 2025;
    INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, MetricId, GradeId, Justification, EnteredBy)
    SELECT @t, a.CreditAssessmentId, 'QUALITATIVE', m.CreditMetricId, g.RatingGradeId, N'synthetic data for the performance run', @u1
    FROM fin.CreditAssessment AS a
    CROSS JOIN (VALUES ('BUSINESS_PROFILE', 'Ba1'), ('FINANCIAL_POLICY', 'Baa3')) AS v (Metric, Grade)
    JOIN fin.CreditMetric AS m ON m.Code = v.Metric COLLATE DATABASE_DEFAULT
    JOIN fin.RatingGrade AS g ON g.Code = v.Grade COLLATE DATABASE_DEFAULT
    WHERE a.TenantId = @t;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CreditAssessmentId FROM fin.CreditAssessment WHERE TenantId = @t ORDER BY CreditAssessmentId;
    OPEN c; FETCH NEXT FROM c INTO @a;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @t0 = SYSUTCDATETIME();
        EXEC fin.usp_ComputeCreditAssessment @a;
        INSERT #Compute VALUES (@t, DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
        FETCH NEXT FROM c INTO @a;
    END;
    CLOSE c; DEALLOCATE c;
    UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedOn = SYSUTCDATETIME() WHERE TenantId = @t AND Status = 'DRAFT';
    EXEC #Bind @t, @u2;
    UPDATE fin.CreditAssessment SET Status = 'APPROVED', ApprovedBy = @u2, ApprovedOn = SYSUTCDATETIME() WHERE TenantId = @t AND Status = 'SUBMITTED';
    EXEC #Bind @t, @u3;
    DECLARE e CURSOR LOCAL FAST_FORWARD FOR SELECT TOP (@Endorse) CreditAssessmentId FROM fin.CreditAssessment WHERE TenantId = @t ORDER BY CreditAssessmentId;
    OPEN e; FETCH NEXT FROM e INTO @a;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC fin.usp_EndorseCreditAssessment @a, N'For the lender (synthetic)';
        FETCH NEXT FROM e INTO @a;
    END;
    CLOSE e; DEALLOCATE e;
    EXEC #Bind @t, @u1;
END;
GO
/* @Rows audit rows and @Sessions ended sessions for the current tenant, in batches; the audit chain trigger numbers
   and hashes every row (055). */
CREATE PROCEDURE #Fill @Rows INT, @Sessions INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t INT = (SELECT v FROM #P WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #P WHERE k = 'u1'), @done INT = 0, @b INT;
    WHILE @done < @Rows
    BEGIN
        SET @b = CASE WHEN @Rows - @done < 5000 THEN @Rows - @done ELSE 5000 END;
        INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, Action, Category, Severity, EntityType, EntityId, AfterJson, Result)
        SELECT @t, DATEADD(SECOND, -(@done + n) * 37, SYSUTCDATETIME()), 'USER',
               CASE n % 4 WHEN 0 THEN 'LOGIN_SUCCESS' WHEN 1 THEN 'STATEMENT_APPROVED' WHEN 2 THEN 'FACILITY_UPDATED' ELSE 'REQUEST_ACTION' END,
               CASE n % 4 WHEN 0 THEN 'SECURITY' ELSE 'TREASURY' END, 'INFO', 'org.Company', n % 200 + 1,
               CONCAT(N'{"n":', @done + n, N'}'), 'SUCCESS'
        FROM (SELECT TOP (@b) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b2) AS x;
        SET @done += @b;
    END;
    INSERT sec.UserSession (TenantId, UserId, TokenHash, LastSeenAt, IdleExpiresAt, AbsoluteExpiresAt, MfaVerifiedAt, EndedAt, EndReason)
    SELECT @t, @u1, HASHBYTES('SHA2_256', CONCAT('ended-', @t, '-', n)), DATEADD(MINUTE, -n, SYSUTCDATETIME()), DATEADD(MINUTE, -n + 30, SYSUTCDATETIME()),
           DATEADD(MINUTE, -n + 720, SYSUTCDATETIME()), DATEADD(MINUTE, -n, SYSUTCDATETIME()), DATEADD(MINUTE, -n + 30, SYSUTCDATETIME()), 'IDLE_TIMEOUT'
    FROM (SELECT TOP (@Sessions) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b2) AS x;
END;
GO
CREATE TABLE #Compute (TenantId INT, Microseconds BIGINT);
CREATE TABLE #Gen (Step VARCHAR(40) COLLATE DATABASE_DEFAULT, Seconds DECIMAL(12,3));
GO
DECLARE @i INT = 1, @t0 DATETIME2(7), @code VARCHAR(30);
SET @t0 = SYSUTCDATETIME();
WHILE @i <= $(FullTenants)
BEGIN
    SET @code = CONCAT('perf-f', FORMAT(@i, '000'));
    EXEC #Tenant @code;
    EXEC #Companies $(Companies), $(Years), 1;
    EXEC #Assessments 20;
    EXEC #Fill $(AuditRows), $(Sessions);
    PRINT CONCAT('full tenant ', @code, ' done at ', DATEDIFF(SECOND, @t0, SYSUTCDATETIME()), ' s');
    SET @i += 1;
END;
INSERT #Gen VALUES ('full tenants', DATEDIFF_BIG(MILLISECOND, @t0, SYSUTCDATETIME()) / 1000.0);
SET @t0 = SYSUTCDATETIME();
SET @i = 1;
WHILE @i <= $(LightTenants)
BEGIN
    SET @code = CONCAT('perf-l', FORMAT(@i, '000'));
    EXEC #Tenant @code;
    EXEC #Companies 1, 1, 0;
    EXEC #Fill $(LightAudit), 500;
    IF @i % 50 = 0 PRINT CONCAT('light tenants: ', @i, ' at ', DATEDIFF(SECOND, @t0, SYSUTCDATETIME()), ' s');
    SET @i += 1;
END;
INSERT #Gen VALUES ('light tenants', DATEDIFF_BIG(MILLISECOND, @t0, SYSUTCDATETIME()) / 1000.0);
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
-- what was generated, and how fast the computation ran while it was
SELECT CONCAT('GEN|', Step, '|', Seconds) FROM #Gen;
SELECT CONCAT('GEN|compute|', COUNT(*), '|', CAST(AVG(Microseconds) / 1000.0 AS DECIMAL(12,1)), '|', CAST(MAX(Microseconds) / 1000.0 AS DECIMAL(12,1))) FROM #Compute;
GO

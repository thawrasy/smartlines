/* 048_presentation_versions.sql — the alternative presentations of a company's statement before its final approval
   (docs/36 gap F2, ADR 0023, FR-FIN-036, BR-FIN-037).

   The platform serves the company (docs/31 decision 34): it sees what a lender would see before the lender does, and
   prepares its statement in another form before its final approval. A presentation version is the remedies of the
   methodology (fin.CreditRemedy) the company chose, in order:
     - fin.usp_BuildPresentationVersion applies them to the source statement with the engine's own remedy steps
       (fin.usp_CreditApplyRemedy, 047), checks that the balance sheet stays balanced, writes the result as a new draft
       statement of the same series (version reason RESTRUCTURED), and, when the version names a source assessment,
       computes a trial assessment of the new draft with the same inputs (ADR 0022), so the two can be compared;
     - a version is convertible only when every step rests on a document dated by the period end: what was agreed or
       done after it is a later event and cannot be booked in the period, so such a version stays a plan to compare;
     - fin.usp_ChoosePresentationVersion lets someone other than its preparer choose a built, convertible version:
       its draft then replaces the source in the series and the other versions of the source are discarded;
     - the draft of a version is not submitted unless its version was chosen, and its lines do not change by hand
       (the steps are its reconciliation), 50090;
     - the version's results are written by the build only (the application role is denied UPDATE on them).
   The view fin.v_PresentationComparison sets each version beside its source.
   Since ADR 0037 (the internal review of 2026-10-21, lens E, findings 1 and 7): a version starts from a draft or a
   submitted statement only, never from an approved one (owner decision 34: a company restructures its presentation
   before the final approval; an approved, perhaps audited, statement keeps its assurance, auditor and opinion and is
   corrected by a new version of its own, 045), 50090; the build is run by the version's preparer, the user bound to
   the session, holder of fin.stmt.enter (and of fin.credit.assess when it computes a trial assessment), and the
   choice by a holder of fin.stmt.approve, 50170 and 50171 (058). */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
-- A version changes only as a draft but for its choice; its steps only while it is a draft.
CREATE OR ALTER TRIGGER fin.TR_PresentationVersion_Lifecycle ON fin.PresentationVersion
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    IF EXISTS (SELECT 1 FROM inserted AS i LEFT JOIN deleted AS d ON d.PresentationVersionId = i.PresentationVersionId
               WHERE (d.PresentationVersionId IS NULL AND (i.Status <> 'DRAFT' OR i.ResultStatementId IS NOT NULL OR i.TrialAssessmentId IS NOT NULL
                                                         OR i.BuiltAt IS NOT NULL OR i.IsConvertible IS NOT NULL OR i.ChosenBy IS NOT NULL))
                  OR (d.PresentationVersionId IS NOT NULL AND i.Status <> d.Status
                      AND NOT ((d.Status = 'DRAFT' AND i.Status IN ('BUILT', 'DISCARDED')) OR (d.Status = 'BUILT' AND i.Status IN ('CHOSEN', 'DISCARDED'))))
                  OR (d.PresentationVersionId IS NOT NULL AND d.Status <> 'DRAFT'
                      AND (i.SourceStatementId <> d.SourceStatementId OR ISNULL(i.SourceAssessmentId, -1) <> ISNULL(d.SourceAssessmentId, -1)
                           OR i.PreparedBy <> d.PreparedBy)))
        THROW 50090, 'A presentation version is written as a draft, built by the database, then chosen or discarded (BR-FIN-037)', 1;
    -- the source is a statement of the tenant before its final approval (a draft or a submitted one, ADR 0037), and
    -- the source assessment reads it; a discarded version keeps its history
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN fin.FinancialStatement AS s ON s.TenantId = i.TenantId AND s.FinancialStatementId = i.SourceStatementId
               LEFT JOIN fin.CreditAssessment AS a ON a.TenantId = i.TenantId AND a.CreditAssessmentId = i.SourceAssessmentId
               WHERE (i.Status IN ('DRAFT', 'BUILT', 'CHOSEN') AND s.Status NOT IN ('DRAFT', 'SUBMITTED'))
                  OR (i.SourceAssessmentId IS NOT NULL AND (a.CreditAssessmentId IS NULL OR a.StatementId <> i.SourceStatementId)))
        THROW 50090, 'A presentation version starts from a statement before its final approval (a draft or a submitted one), and its source assessment is an assessment of that statement (BR-FIN-037, ADR 0037)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_PresentationVersionStep_DraftOnly ON fin.PresentationVersionStep
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, VersionId FROM inserted UNION SELECT TenantId, VersionId FROM deleted) AS r
               JOIN fin.PresentationVersion AS v WITH (UPDLOCK, HOLDLOCK) ON v.TenantId = r.TenantId AND v.PresentationVersionId = r.VersionId
               WHERE v.Status <> 'DRAFT')
        THROW 50090, 'The steps of a presentation version change only while it is a draft (BR-FIN-037)', 1;
END;
GO
-- The draft of a version is submitted only when its version was chosen, and its lines change only by the build.
CREATE OR ALTER TRIGGER fin.TR_FinancialStatement_Presentation ON fin.FinancialStatement
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN deleted AS d ON d.FinancialStatementId = i.FinancialStatementId
               JOIN fin.PresentationVersion AS v WITH (UPDLOCK, HOLDLOCK) ON v.TenantId = i.TenantId AND v.ResultStatementId = i.FinancialStatementId
               WHERE d.Status = 'DRAFT' AND i.Status = 'SUBMITTED' AND v.Status <> 'CHOSEN')
        THROW 50090, 'The draft of a presentation version is submitted only when its version was chosen (BR-FIN-037)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_StatementLine_Presentation ON fin.StatementLine
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    -- the build writes the lines before it names the draft on its version, so once named they are fixed
    IF EXISTS (SELECT 1
                   FROM (SELECT TenantId, StatementId FROM inserted UNION SELECT TenantId, StatementId FROM deleted) AS r
                   JOIN fin.PresentationVersion AS v ON v.TenantId = r.TenantId AND v.ResultStatementId = r.StatementId)
        THROW 50090, 'The lines of a presentation version''s draft are written by its build; change its steps in a new version (BR-FIN-037)', 1;
END;
GO
/* The build: the source statement's lines on the standard codes, each step applied with the engine's remedy steps,
   the balance checked, the result written as a new draft statement of the series, and its trial assessment computed. */
CREATE OR ALTER PROCEDURE fin.usp_BuildPresentationVersion @VersionId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tenant INT, @src BIGINT, @srcA BIGINT, @status VARCHAR(10), @preparer BIGINT, @user BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
    BEGIN TRANSACTION;
    SELECT @tenant = TenantId, @src = SourceStatementId, @srcA = SourceAssessmentId, @status = Status, @preparer = PreparedBy
    FROM fin.PresentationVersion WITH (UPDLOCK, HOLDLOCK) WHERE PresentationVersionId = @VersionId;   -- the row filter shows the bound tenant's only
    IF @tenant IS NULL THROW 50091, 'No presentation version with this id for this tenant', 1;
    IF @status <> 'DRAFT' THROW 50090, 'Only a draft presentation version is built (BR-FIN-037)', 1;
    -- built by its preparer, who enters statements and, for the trial, assessments (ADR 0037)
    IF @user IS NULL OR @user <> @preparer OR NOT EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@tenant, 1))
        THROW 50170, 'A presentation version is built by its preparer, the user bound to the session (ADR 0037)', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@tenant, @user, 'fin.stmt.enter'))
       OR (@srcA IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@tenant, @user, 'fin.credit.assess')))
        THROW 50171, 'Building a presentation version needs fin.stmt.enter, and fin.credit.assess for its trial assessment (ADR 0037)', 1;
    IF (SELECT Status FROM fin.FinancialStatement WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @tenant AND FinancialStatementId = @src) NOT IN ('DRAFT', 'SUBMITTED')
        THROW 50090, 'A presentation version is built on a statement before its final approval (a draft or a submitted one) (BR-FIN-037, ADR 0037)', 1;
    IF NOT EXISTS (SELECT 1 FROM fin.PresentationVersionStep WHERE TenantId = @tenant AND VersionId = @VersionId)
        THROW 50091, 'A presentation version is built from at least one step', 1;
    DECLARE @pe DATE = (SELECT PeriodEnd FROM fin.FinancialStatement WHERE TenantId = @tenant AND FinancialStatementId = @src);

    -- the source lines on the standard codes, as the assessment reads them (047)
    CREATE TABLE #crL (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT NULL);
    INSERT #crL (Code, Amount)
    SELECT li.Code, CAST(COALESCE(ln.EnteredAmount, ln.ComputedAmount) AS FLOAT)
    FROM fin.StatementLine AS ln
    JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
    JOIN fin.StandardLine AS sl ON sl.Code = li.Code
    WHERE ln.TenantId = @tenant AND ln.StatementId = @src AND COALESCE(ln.EnteredAmount, ln.ComputedAmount) IS NOT NULL;
    EXEC fin.usp_CreditRebuildTotals @Income = 0;
    DECLARE @gap0 FLOAT = (SELECT SUM(CASE Code WHEN 'TOTAL_ASSETS' THEN Amount ELSE -Amount END) FROM #crL WHERE Code IN ('TOTAL_ASSETS','TOTAL_LIABS','TOTAL_EQUITY'));
    DECLARE @before TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT);
    INSERT @before SELECT Code, Amount FROM #crL;

    -- the steps in order
    DECLARE @moves TABLE (StepNo INT PRIMARY KEY, Moved FLOAT);
    DECLARE @n INT, @rid INT, @scale FLOAT, @moved FLOAT;
    DECLARE sc CURSOR LOCAL FAST_FORWARD FOR
        SELECT StepNo, RemedyId, CAST(ScalePct AS FLOAT) / 100 FROM fin.PresentationVersionStep WHERE TenantId = @tenant AND VersionId = @VersionId ORDER BY StepNo;
    OPEN sc; FETCH NEXT FROM sc INTO @n, @rid, @scale;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @moved = 0;
        IF EXISTS (SELECT 1 FROM fin.CreditRemedyStep WHERE RemedyId = @rid) EXEC fin.usp_CreditApplyRemedy @rid, @moved OUTPUT, @scale;
        INSERT @moves VALUES (@n, @moved);
        FETCH NEXT FROM sc INTO @n, @rid, @scale;
    END;
    CLOSE sc; DEALLOCATE sc;
    DECLARE @gap FLOAT = ABS((SELECT SUM(CASE Code WHEN 'TOTAL_ASSETS' THEN Amount ELSE -Amount END) FROM #crL
                              WHERE Code IN ('TOTAL_ASSETS','TOTAL_LIABS','TOTAL_EQUITY')) - @gap0);
    IF @gap > 1.0 THROW 50091, 'The steps of the presentation version left the balance sheet unbalanced', 1;
    -- every changed line has its line item in the tenant's catalogue
    DECLARE @missing VARCHAR(40) = (SELECT TOP (1) l.Code FROM #crL AS l LEFT JOIN @before AS b ON b.Code = l.Code
                                    WHERE ABS(ISNULL(l.Amount, 0) - ISNULL(b.Amount, 0)) > 0.005
                                      AND NOT EXISTS (SELECT 1 FROM fin.LineCatalogItem AS li WHERE li.TenantId = @tenant AND li.Code = l.Code)
                                    ORDER BY l.Code);
    IF @missing IS NOT NULL
    BEGIN
        DECLARE @msg NVARCHAR(400) = CONCAT(N'The line ', @missing, N' the steps change has no line item in the tenant''s catalogue');
        THROW 50091, @msg, 1;
    END;

    -- the new draft of the series, with the source lines and the changed amounts
    DECLARE @new BIGINT;
    INSERT fin.FinancialStatement (TenantId, CompanyId, PeriodType, PeriodStart, PeriodEnd, FiscalYear, Basis, Assurance, Nature, CurrencyId, UnitScale, AccountingStandard,
                                   AuditorName, AuditOpinion, GoingConcernUncertainty, VersionNo, VersionReason, Status, EntryMethod, BalanceReason, PreparedBy, PreparedOn)
    SELECT s.TenantId, s.CompanyId, s.PeriodType, s.PeriodStart, s.PeriodEnd, s.FiscalYear, s.Basis, s.Assurance, s.Nature, s.CurrencyId, s.UnitScale, s.AccountingStandard,
           s.AuditorName, s.AuditOpinion, s.GoingConcernUncertainty,
           (SELECT MAX(x.VersionNo) + 1 FROM fin.FinancialStatement AS x WITH (UPDLOCK, HOLDLOCK)
            WHERE x.TenantId = s.TenantId AND x.CompanyId = s.CompanyId AND x.PeriodType = s.PeriodType AND x.PeriodEnd = s.PeriodEnd AND x.Basis = s.Basis
              AND x.Assurance = s.Assurance AND x.Nature = s.Nature),
           'RESTRUCTURED', 'DRAFT', 'MANUAL', s.BalanceReason, @preparer, SYSUTCDATETIME()
    FROM fin.FinancialStatement AS s WHERE s.TenantId = @tenant AND s.FinancialStatementId = @src;
    SET @new = SCOPE_IDENTITY();
    INSERT fin.StatementLine (TenantId, StatementId, LineCatalogItemId, EnteredAmount, ComputedAmount)
    SELECT ln.TenantId, @new, ln.LineCatalogItemId,
           CASE WHEN l.Code IS NOT NULL THEN CAST(l.Amount AS DECIMAL(19,4)) ELSE ln.EnteredAmount END,
           CASE WHEN l.Code IS NOT NULL THEN NULL ELSE ln.ComputedAmount END
    FROM fin.StatementLine AS ln
    JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
    LEFT JOIN #crL AS l ON l.Code = li.Code
    WHERE ln.TenantId = @tenant AND ln.StatementId = @src;
    INSERT fin.StatementLine (TenantId, StatementId, LineCatalogItemId, EnteredAmount)
    SELECT @tenant, @new, li.LineCatalogItemId, CAST(l.Amount AS DECIMAL(19,4))
    FROM #crL AS l
    JOIN fin.LineCatalogItem AS li ON li.TenantId = @tenant AND li.Code = l.Code
    WHERE l.Amount IS NOT NULL AND ABS(l.Amount) > 0.005
      AND NOT EXISTS (SELECT 1 FROM fin.StatementLine AS x WHERE x.TenantId = @tenant AND x.StatementId = @new AND x.LineCatalogItemId = li.LineCatalogItemId);
    INSERT fin.ConsolidationMember (TenantId, StatementId, MemberCompanyId, Role, Method, OwnershipPct, IncludedFrom, IncludedTo)
    SELECT TenantId, @new, MemberCompanyId, Role, Method, OwnershipPct, IncludedFrom, IncludedTo
    FROM fin.ConsolidationMember WHERE TenantId = @tenant AND StatementId = @src;
    UPDATE st SET MovedAmount = CAST(m.Moved AS DECIMAL(19,4))
    FROM fin.PresentationVersionStep AS st JOIN @moves AS m ON m.StepNo = st.StepNo
    WHERE st.TenantId = @tenant AND st.VersionId = @VersionId;
    DROP TABLE #crL;

    -- the trial assessment of the new draft with the source assessment's inputs and the evidence of the steps
    DECLARE @trial BIGINT = NULL;
    IF @srcA IS NOT NULL
    BEGIN
        INSERT fin.CreditAssessment (TenantId, CompanyId, StatementId, PriorStatementId, ScorecardId, AssessmentDate, FxRateToScorecard, MarketCountryId,
                                     MarketRegionCode, IsTrial, PreparedBy)
        SELECT TenantId, CompanyId, @new, PriorStatementId, ScorecardId, AssessmentDate, FxRateToScorecard, MarketCountryId, MarketRegionCode, 1, @preparer
        FROM fin.CreditAssessment WHERE TenantId = @tenant AND CreditAssessmentId = @srcA;
        SET @trial = SCOPE_IDENTITY();
        INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, MetricId, SubfactorId, Amount, CurrencyId, Rate, EvidenceCode, GradeId, Notches,
                                          ParentAssessmentId, Justification, DocumentId, EnteredBy)
        SELECT TenantId, @trial, Kind, MetricId, SubfactorId, Amount, CurrencyId, Rate, EvidenceCode, GradeId, Notches, ParentAssessmentId, Justification,
               DocumentId, @user   -- the trial's inputs are the builder's (058, ADR 0037)
        FROM fin.CreditAssessmentInput WHERE TenantId = @tenant AND AssessmentId = @srcA;
        INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, EvidenceCode, Justification, DocumentId, EnteredBy)
        SELECT @tenant, @trial, 'EVIDENCE', r.SetsEvidence, st.Justification, st.DocumentId, @preparer
        FROM fin.PresentationVersionStep AS st
        JOIN fin.CreditRemedy AS r ON r.CreditRemedyId = st.RemedyId
        WHERE st.TenantId = @tenant AND st.VersionId = @VersionId AND r.SetsEvidence IS NOT NULL AND st.DocumentId IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM fin.CreditAssessmentInput AS x WHERE x.TenantId = @tenant AND x.AssessmentId = @trial AND x.Kind = 'EVIDENCE'
                                                                       AND x.EvidenceCode = r.SetsEvidence);
        INSERT fin.CreditAssessmentGuarantor (TenantId, AssessmentId, PartyId, NetWorth, LiquidAssets, GuaranteesGiven, GuaranteedAmount, AsOfDate, DocumentId)
        SELECT TenantId, @trial, PartyId, NetWorth, LiquidAssets, GuaranteesGiven, GuaranteedAmount, AsOfDate, DocumentId
        FROM fin.CreditAssessmentGuarantor WHERE TenantId = @tenant AND AssessmentId = @srcA;
        INSERT fin.CreditAssessmentBureau (TenantId, AssessmentId, ReportDate, DocumentId, TotalLimits, TotalOutstanding, LenderCount, WorstDpd12m, WorstDpd24m,
                                           CurrentDefault, Defaults24mCount, Defaults24mAmount, BouncedCheques12mCount, BouncedCheques12mAmount, JudgmentsCount,
                                           JudgmentsAmount, Inquiries6m, Restructured)
        SELECT TenantId, @trial, ReportDate, DocumentId, TotalLimits, TotalOutstanding, LenderCount, WorstDpd12m, WorstDpd24m, CurrentDefault, Defaults24mCount,
               Defaults24mAmount, BouncedCheques12mCount, BouncedCheques12mAmount, JudgmentsCount, JudgmentsAmount, Inquiries6m, Restructured
        FROM fin.CreditAssessmentBureau WHERE TenantId = @tenant AND AssessmentId = @srcA;
        EXEC fin.usp_ComputeCreditAssessment @trial;
    END;

    -- convertible: every step rests on a document dated by the period end (a later agreement is a later event)
    DECLARE @conv BIT = CASE WHEN EXISTS (SELECT 1 FROM fin.PresentationVersionStep
                                          WHERE TenantId = @tenant AND VersionId = @VersionId AND (DocumentId IS NULL OR EvidenceDate > @pe)) THEN 0 ELSE 1 END;
    UPDATE fin.PresentationVersion
       SET Status = 'BUILT', ResultStatementId = @new, TrialAssessmentId = @trial, IsConvertible = @conv, BalanceGap = CAST(@gap AS DECIMAL(19,4)),
           BuiltAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @user
    WHERE TenantId = @tenant AND PresentationVersionId = @VersionId;
    COMMIT;
END;
GO
/* The choice: someone other than the preparer chooses a built, convertible version, and says why (ADR 0029); its
   draft replaces the source in the series, and the other built versions of the source are discarded. */
CREATE OR ALTER PROCEDURE fin.usp_ChoosePresentationVersion @VersionId BIGINT, @Reason NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tenant INT, @src BIGINT, @res BIGINT, @status VARCHAR(10), @preparer BIGINT, @conv BIT, @user BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
    BEGIN TRANSACTION;
    SELECT @tenant = TenantId, @src = SourceStatementId, @res = ResultStatementId, @status = Status, @preparer = PreparedBy, @conv = IsConvertible
    FROM fin.PresentationVersion WITH (UPDLOCK, HOLDLOCK) WHERE PresentationVersionId = @VersionId;
    IF @tenant IS NULL THROW 50091, 'No presentation version with this id for this tenant', 1;
    IF @status <> 'BUILT' THROW 50090, 'Only a built presentation version is chosen (BR-FIN-037)', 1;
    IF @conv = 0 THROW 50090, 'A presentation version is chosen only when every step rests on a document dated by the period end (BR-FIN-037)', 1;
    IF @user IS NULL OR @user = @preparer THROW 50090, 'A presentation version is chosen by someone other than its preparer (BR-FIN-037)', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@tenant, 1))
        THROW 50170, 'A presentation version is chosen by the user bound to the session (ADR 0037)', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@tenant, @user, 'fin.stmt.approve'))
        THROW 50171, 'Choosing a presentation version needs fin.stmt.approve (ADR 0037)', 1;
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 50090, 'A presentation version is chosen with the reason for the choice (ADR 0029)', 1;
    UPDATE fin.PresentationVersion SET Status = 'CHOSEN', ChosenBy = @user, ChosenOn = SYSUTCDATETIME(), ChoiceReason = LTRIM(RTRIM(@Reason)), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @user
    WHERE TenantId = @tenant AND PresentationVersionId = @VersionId;
    UPDATE fin.PresentationVersion SET Status = 'DISCARDED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @user
    WHERE TenantId = @tenant AND SourceStatementId = @src AND Status = 'BUILT' AND PresentationVersionId <> @VersionId;
    UPDATE fin.FinancialStatement SET SupersedesId = @src WHERE TenantId = @tenant AND FinancialStatementId = @res;
    COMMIT;
END;
GO
/* Each version beside its source: the grade, the score, the liquidity and the coverage of the source assessment and of
   the version's trial, the notches gained, whether the balance held and whether the version can become the statement. */
CREATE OR ALTER VIEW fin.v_PresentationComparison
AS
SELECT v.TenantId, v.PresentationVersionId, v.PublicId, v.NameAr, v.Status, v.SourceStatementId, v.ResultStatementId, v.IsConvertible, v.BalanceGap,
       v.SourceAssessmentId, sg.Code AS SourceGrade, sa.WeightedScore AS SourceScore, sa.LiquidityLabel AS SourceLiquidity,
       v.TrialAssessmentId, tg.Code AS VersionGrade, ta.WeightedScore AS VersionScore, ta.LiquidityLabel AS VersionLiquidity,
       CAST(sg.NotchNo AS INT) - CAST(tg.NotchNo AS INT) AS NotchesGained, v.PreparedBy, v.ChosenBy, v.ChosenOn,
       (SELECT COUNT(*) FROM fin.PresentationVersionStep AS st WHERE st.TenantId = v.TenantId AND st.VersionId = v.PresentationVersionId) AS StepCount
FROM fin.PresentationVersion AS v
LEFT JOIN fin.CreditAssessment AS sa ON sa.TenantId = v.TenantId AND sa.CreditAssessmentId = v.SourceAssessmentId
LEFT JOIN fin.RatingGrade AS sg ON sg.RatingGradeId = sa.FinalGradeId
LEFT JOIN fin.CreditAssessment AS ta ON ta.TenantId = v.TenantId AND ta.CreditAssessmentId = v.TrialAssessmentId
LEFT JOIN fin.RatingGrade AS tg ON tg.RatingGradeId = ta.FinalGradeId;
GO
/* The steps of each version with their remedy, its kind (a real action or a presentation that follows the substance),
   its document and whether it can be booked in the period. */
CREATE OR ALTER VIEW fin.v_PresentationVersionSteps
AS
SELECT st.TenantId, st.VersionId, st.StepNo, r.Code AS RemedyCode, r.Kind AS RemedyKind, r.NameAr AS RemedyNameAr, r.NameEn AS RemedyNameEn,
       r.EvidenceAr, st.ScalePct, st.MovedAmount, st.DocumentId, st.EvidenceDate, st.Justification,
       CAST(CASE WHEN st.DocumentId IS NOT NULL AND st.EvidenceDate <= s.PeriodEnd THEN 1 ELSE 0 END AS BIT) AS InPeriod
FROM fin.PresentationVersionStep AS st
JOIN fin.PresentationVersion AS v ON v.TenantId = st.TenantId AND v.PresentationVersionId = st.VersionId
JOIN fin.FinancialStatement AS s ON s.TenantId = v.TenantId AND s.FinancialStatementId = v.SourceStatementId
JOIN fin.CreditRemedy AS r ON r.CreditRemedyId = st.RemedyId;
GO
/* Each line of a version's draft beside the source line. */
CREATE OR ALTER VIEW fin.v_PresentationVersionLines
AS
SELECT v.TenantId, v.PresentationVersionId, li.Code AS LineCode, li.NameAr AS LineNameAr,
       COALESCE(a.EnteredAmount, a.ComputedAmount) AS SourceAmount, COALESCE(b.EnteredAmount, b.ComputedAmount) AS VersionAmount,
       ISNULL(COALESCE(b.EnteredAmount, b.ComputedAmount), 0) - ISNULL(COALESCE(a.EnteredAmount, a.ComputedAmount), 0) AS Change
FROM fin.PresentationVersion AS v
JOIN fin.StatementLine AS b ON b.TenantId = v.TenantId AND b.StatementId = v.ResultStatementId
JOIN fin.LineCatalogItem AS li ON li.TenantId = b.TenantId AND li.LineCatalogItemId = b.LineCatalogItemId
LEFT JOIN fin.StatementLine AS a ON a.TenantId = v.TenantId AND a.StatementId = v.SourceStatementId AND a.LineCatalogItemId = b.LineCatalogItemId;
GO
-- The results of a version and the amount a step moved are written by the build only.
DENY UPDATE ON [fin].[PresentationVersion] ([ResultStatementId], [TrialAssessmentId], [IsConvertible], [BalanceGap], [BuiltAt], [ChosenBy], [ChosenOn], [ChoiceReason]) TO [tp_app];
DENY UPDATE ON [fin].[PresentationVersionStep] ([MovedAmount]) TO [tp_app];
GRANT EXECUTE ON fin.usp_BuildPresentationVersion TO [tp_app];
GRANT EXECUTE ON fin.usp_ChoosePresentationVersion TO [tp_app];
GRANT SELECT ON fin.v_PresentationComparison TO [tp_app];
GRANT SELECT ON fin.v_PresentationVersionSteps TO [tp_app];
GRANT SELECT ON fin.v_PresentationVersionLines TO [tp_app];
GO

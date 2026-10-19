/* ============================================================================
   BankFas - 046: the credit assessment of a balance sheet on the Moody's scale (owner request of 2026-10-18;
   docs/35-credit-assessment-methodology.md, spec 12 FR-FIN-020 to FR-FIN-024, BR-FIN-018 to BR-FIN-024,
   docs/adr/0017-credit-assessment.md)

   When an approved statement is studied, the system computes from its lines the ratios of the methodology, scores
   each scorecard ratio on the linear continuum of the Moody's scorecards (0.5 best to 20.5 worst, by the nine
   boundaries of its sector grid), weights them into an aggregate that gives the indicated grade (Aaa below 1.5,
   then one notch per point, Ca from 19.5), and applies in order: the notches (audit opinion, unaudited or stale or
   incomplete or restated statement, losses of half the capital cured, related-party exposure, a holding's standalone
   statement, open covenant breaches, a bank flow shortfall); the standalone caps (going concern, negative equity,
   half the capital lost, size, sector), which give the standalone grade; group support capped at the parent's
   grade; the analyst's override (two notches down, one up); and the absolute caps (an adverse opinion, the
   sovereign). The financial grade of the quantitative metrics alone is shown beside it, and there is no final
   grade until the analyst grades the qualitative factors (docs/35 sections 3 and 7). It reports the strengths, the points to
   watch, the weaknesses and the risks: those of the scorecard, of each balance sheet item, of the covenants tested
   on the statement and of the liquidity routed to the bank. The methodology is the platform's (db/seed/104, from
   tools/dbgen/credit_scorecard.json); tools/dbgen/credit_reference.py computes the same in Python and the tests
   expect its numbers.

   This script holds the guards of the assessment and of the methodology, the hash of what a computation reads, and
   the horizontal and vertical analysis of a statement (fin.fn_StatementItemAnalysis). The engine, the computation
   (fin.usp_ComputeCreditAssessment) and the report views are in 047 (version 2, owner requests of 2026-10-19).

   Guards:
     - an assessment is written as a draft, computed while a draft, submitted only computed on what it holds now
       (the hash of its statement, comparison statement, scorecard, date, rate and inputs), and approved by someone
       other than its preparer; after the draft nothing but its status and approval changes (50063);
     - it reads an approved statement and an approved scorecard; a rate is given when their currencies differ; a
       comparison statement is approved, of the same company and basis, and earlier (50064);
     - the analyst's inputs change only while the assessment is a draft: a qualitative factor of its scorecard,
       within the scorecard's bound of the financial grade unless a document supports it; group support from the
       approved assessment, of the twelve months before, of the parent or of a holding that consolidates the
       company; an override of at most two notches down or one up, as the company assesses itself; each with a
       justification (50065);
     - a scorecard is written as a draft and approved whole (weights of 100, a grid for each quantitative metric that
       runs in its direction, none for a qualitative one); approved, it never changes and is only retired; nor do
       the grades and the metrics an approved scorecard uses (50066).
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
/* The hash of what a computation reads from the assessment itself: its statement, comparison statement, scorecard,
   date, rate, the analyst's inputs, the guarantors, the bureau report, whether strengthening plans were asked for, and
   the company's activity and product lines of the statement's year. The approved statements, the scorecard and the
   parent's approved assessment do not change, so a submission whose hash differs from the computed one was changed
   after its computation. */
CREATE OR ALTER FUNCTION fin.fn_CreditAssessmentInputsHash (@TenantId INT, @AssessmentId BIGINT)
RETURNS TABLE
AS RETURN
SELECT CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONCAT(
           a.StatementId, '|', a.PriorStatementId, '|', a.ScorecardId, '|', CONVERT(CHAR(10), a.AssessmentDate, 23), '|',
           CONVERT(VARCHAR(40), a.FxRateToScorecard), '|',
           (SELECT i.Kind, i.MetricId, i.SubfactorId, i.GradeId, i.Notches, i.ParentAssessmentId, i.Amount, i.CurrencyId, i.Rate, i.EvidenceCode,
                   i.DocumentId, i.Justification
            FROM fin.CreditAssessmentInput AS i
            WHERE i.TenantId = a.TenantId AND i.AssessmentId = a.CreditAssessmentId
            ORDER BY i.Kind, i.MetricId, i.SubfactorId, i.CurrencyId, i.EvidenceCode
            FOR JSON PATH), '|',
           (SELECT g.PartyId, g.NetWorth, g.LiquidAssets, g.GuaranteesGiven, g.GuaranteedAmount, g.AsOfDate, g.DocumentId
            FROM fin.CreditAssessmentGuarantor AS g
            WHERE g.TenantId = a.TenantId AND g.AssessmentId = a.CreditAssessmentId
            ORDER BY g.PartyId
            FOR JSON PATH), '|',
           (SELECT b.ReportDate, b.DocumentId, b.TotalLimits, b.TotalOutstanding, b.LenderCount, b.WorstDpd12m, b.WorstDpd24m, b.CurrentDefault,
                   b.Defaults24mCount, b.Defaults24mAmount, b.BouncedCheques12mCount, b.BouncedCheques12mAmount, b.JudgmentsCount, b.JudgmentsAmount,
                   b.Inquiries6m, b.Restructured
            FROM fin.CreditAssessmentBureau AS b
            WHERE b.TenantId = a.TenantId AND b.AssessmentId = a.CreditAssessmentId
            FOR JSON PATH), '|', a.StrengtheningRequested, '|', co.IndustryId, '|', co.CountryId, '|', a.MarketCountryId, '|', a.MarketRegionCode, '|',
           (SELECT pl.ProductCategoryId, pl.RevenueSharePct, pl.InventorySharePct, pl.CashSalesPct, pl.GovernmentSalesPct, pl.ExportSalesPct, pl.TypicalCreditDays
            FROM fin.CompanyProductLine AS pl
            JOIN fin.FinancialStatement AS s ON s.TenantId = a.TenantId AND s.FinancialStatementId = a.StatementId
            WHERE pl.TenantId = a.TenantId AND pl.CompanyId = a.CompanyId AND pl.FiscalYear = s.FiscalYear
            ORDER BY pl.CompanyProductLineId
            FOR JSON PATH))), 2) AS InputsHash
FROM fin.CreditAssessment AS a
JOIN org.Company AS co ON co.TenantId = a.TenantId AND co.CompanyId = a.CompanyId
WHERE a.TenantId = @TenantId AND a.CreditAssessmentId = @AssessmentId;
GO
/* The assessment header. Built from the table's columns, so a column added later is frozen after the draft unless it
   is named in @may. The results are written by fin.usp_ComputeCreditAssessment only: the application role is
   denied UPDATE on them (end of this script) and a new row carries none. */
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);
INSERT @may VALUES (N'Status'), (N'ApprovedBy'), (N'ApprovedOn'), (N'RejectionReason'), (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'fin.CreditAssessment') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SET @sql = N'CREATE OR ALTER TRIGGER fin.TR_CreditAssessment_Lifecycle ON fin.CreditAssessment
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    IF EXISTS (SELECT 1 FROM inserted AS i LEFT JOIN deleted AS d ON d.CreditAssessmentId = i.CreditAssessmentId
               WHERE (d.CreditAssessmentId IS NULL
                      AND (i.Status <> ''DRAFT'' OR i.ComputedAt IS NOT NULL OR i.InputsHash IS NOT NULL OR i.ResultState IS NOT NULL
                           OR i.UsedPriorStatementId IS NOT NULL OR i.CoveragePct IS NOT NULL OR i.FinancialScore IS NOT NULL OR i.FinancialGradeId IS NOT NULL
                           OR i.StandaloneGradeId IS NOT NULL OR i.AdjustmentNotches IS NOT NULL
                           OR i.CapGradeId IS NOT NULL OR i.SupportNotches IS NOT NULL OR i.OverrideNotches IS NOT NULL
                           OR i.FacilityGradeId IS NOT NULL OR i.LgdPct IS NOT NULL OR i.LgdBand IS NOT NULL OR i.LiquidityLabel IS NOT NULL
                           OR i.CompletenessPct IS NOT NULL OR i.AdjustedDebt IS NOT NULL OR i.AdjustedTnw IS NOT NULL OR i.RealisableNetWorth IS NOT NULL
                           OR i.IndustryId IS NOT NULL OR i.SectorPosition IS NOT NULL OR i.Resilience IS NOT NULL OR i.Outlook IS NOT NULL
                           OR i.CountryRisk IS NOT NULL OR i.IndustryRisk IS NOT NULL OR i.AnchorGradeId IS NOT NULL OR i.CountryCeilingGradeId IS NOT NULL
                           OR i.OutlookRules IS NOT NULL OR i.UpHeadroom IS NOT NULL OR i.DownHeadroom IS NOT NULL
                           OR i.SummaryAr IS NOT NULL OR i.SummaryEn IS NOT NULL OR i.Snapshot IS NOT NULL))
                  OR (d.CreditAssessmentId IS NOT NULL AND i.Status <> d.Status
                      AND NOT ((d.Status = ''DRAFT'' AND i.Status = ''SUBMITTED'') OR (d.Status = ''SUBMITTED'' AND i.Status IN (''APPROVED'', ''REJECTED''))
                               OR (d.Status = ''REJECTED'' AND i.Status = ''DRAFT'') OR (d.Status = ''APPROVED'' AND i.Status = ''SUPERSEDED'')))
                  OR (d.CreditAssessmentId IS NOT NULL AND d.Status <> ''DRAFT'' AND EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')))
        THROW 50063, ''A credit assessment is written as a draft and changes only as a draft; its status moves DRAFT, SUBMITTED, APPROVED or REJECTED, SUPERSEDED (BR-FIN-024)'', 1;
    -- Submitted: computed on what it holds now, on a statement and a scorecard still approved.
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN deleted AS d ON d.CreditAssessmentId = i.CreditAssessmentId
               JOIN fin.FinancialStatement AS s WITH (UPDLOCK, HOLDLOCK) ON s.TenantId = i.TenantId AND s.FinancialStatementId = i.StatementId
               JOIN fin.Scorecard AS sc WITH (UPDLOCK, HOLDLOCK) ON sc.ScorecardId = i.ScorecardId
               CROSS APPLY fin.fn_CreditAssessmentInputsHash(i.TenantId, i.CreditAssessmentId) AS h
               WHERE d.Status = ''DRAFT'' AND i.Status = ''SUBMITTED''
                 AND (i.ComputedAt IS NULL OR i.InputsHash IS NULL OR i.InputsHash <> h.InputsHash OR s.Status <> ''APPROVED'' OR sc.Status <> ''APPROVED''))
        THROW 50063, ''An assessment is submitted computed on its current statement, scorecard, date, rate and inputs, while the statement and the scorecard are approved; compute it again (BR-FIN-024)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
-- The analyst's inputs: only while the assessment is a draft, and each of its kind.
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentInput_Guard ON fin.CreditAssessmentInput
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50065, 'The inputs of an assessment change only while it is a draft (BR-FIN-021)', 1;
    -- A qualitative grade is for a qualitative factor of the assessment's scorecard.
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN fin.CreditAssessment AS a ON a.TenantId = i.TenantId AND a.CreditAssessmentId = i.AssessmentId
               WHERE i.Kind = 'QUALITATIVE'
                 AND NOT EXISTS (SELECT 1 FROM fin.ScorecardMetric AS sm
                                 JOIN fin.CreditMetric AS m ON m.CreditMetricId = sm.MetricId
                                 WHERE sm.ScorecardId = a.ScorecardId AND sm.MetricId = i.MetricId AND m.Kind = 'QUALITATIVE'))
        THROW 50065, 'A qualitative grade is given to a qualitative factor of the assessment''s scorecard (BR-FIN-021)', 1;
    -- A sub-factor's grade is for a sub-factor of the assessment's scorecard (docs/35 section 5).
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN fin.CreditAssessment AS a ON a.TenantId = i.TenantId AND a.CreditAssessmentId = i.AssessmentId
               WHERE i.Kind = 'SUBFACTOR'
                 AND NOT EXISTS (SELECT 1 FROM fin.ScorecardSubfactor AS x WHERE x.ScorecardSubfactorId = i.SubfactorId AND x.ScorecardId = a.ScorecardId))
        THROW 50065, 'A sub-factor grade is given to a sub-factor of the assessment''s scorecard (BR-FIN-021)', 1;
    -- Group support comes from the approved, rated assessment of the company's parent, or of a holding whose
    -- consolidated statement has the company as a unit.
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN fin.CreditAssessment AS a ON a.TenantId = i.TenantId AND a.CreditAssessmentId = i.AssessmentId
               JOIN org.Company AS c ON c.TenantId = a.TenantId AND c.CompanyId = a.CompanyId
               LEFT JOIN fin.CreditAssessment AS p WITH (UPDLOCK, HOLDLOCK) ON p.TenantId = i.TenantId AND p.CreditAssessmentId = i.ParentAssessmentId
               WHERE i.Kind = 'GROUP_SUPPORT'
                 AND (p.CreditAssessmentId IS NULL OR p.Status <> 'APPROVED' OR p.ResultState <> 'RATED' OR p.CompanyId = a.CompanyId
                      OR NOT (p.CompanyId = ISNULL(c.ParentCompanyId, -1)
                              OR EXISTS (SELECT 1 FROM fin.ConsolidationMember AS m
                                         WHERE m.TenantId = p.TenantId AND m.StatementId = p.StatementId AND m.MemberCompanyId = a.CompanyId
                                           AND m.Role <> 'PARENT'))))
        THROW 50065, 'Group support comes from the approved assessment of the parent, or of a holding that consolidates the company (BR-FIN-022)', 1;
END;
GO
-- The factors and findings of an assessment are written by the computation, while the assessment is a draft.
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentFactor_DraftOnly ON fin.CreditAssessmentFactor
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The factors of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentFinding_DraftOnly ON fin.CreditAssessmentFinding
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The findings of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
/* The other rows of an assessment, the analyst's (guarantors, bureau report) and the computation's (reconciliation,
   facilities, remedies, scenarios, plans and their steps, triggers), change only while the assessment is a draft. */
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentGuarantor_DraftOnly ON fin.CreditAssessmentGuarantor
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The rows of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentBureau_DraftOnly ON fin.CreditAssessmentBureau
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The rows of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentReclass_DraftOnly ON fin.CreditAssessmentReclass
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The rows of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentFacility_DraftOnly ON fin.CreditAssessmentFacility
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The rows of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentRemedy_DraftOnly ON fin.CreditAssessmentRemedy
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The rows of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentScenario_DraftOnly ON fin.CreditAssessmentScenario
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The rows of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentPlan_DraftOnly ON fin.CreditAssessmentPlan
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The rows of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentPlanStep_DraftOnly ON fin.CreditAssessmentPlanStep
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The rows of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentTrigger_DraftOnly ON fin.CreditAssessmentTrigger
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, AssessmentId FROM inserted UNION SELECT TenantId, AssessmentId FROM deleted) AS r
               JOIN fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK) ON a.TenantId = r.TenantId AND a.CreditAssessmentId = r.AssessmentId
               WHERE a.Status <> 'DRAFT')
        THROW 50063, 'The rows of a submitted or approved assessment do not change (BR-FIN-024)', 1;
END;
GO
/* A scorecard is written as a draft and approved whole; approved, only its status moves to RETIRED. */
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);
INSERT @may VALUES (N'Status'), (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'fin.Scorecard') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SET @sql = N'CREATE OR ALTER TRIGGER fin.TR_Scorecard_Lifecycle ON fin.Scorecard
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d LEFT JOIN inserted AS i ON i.ScorecardId = d.ScorecardId
               WHERE i.ScorecardId IS NULL AND d.Status <> ''DRAFT'')
        THROW 50066, ''An approved or retired scorecard is not deleted (BR-FIN-023)'', 1;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    IF EXISTS (SELECT 1 FROM inserted AS i LEFT JOIN deleted AS d ON d.ScorecardId = i.ScorecardId
               WHERE (d.ScorecardId IS NULL AND i.Status <> ''DRAFT'')
                  OR (d.ScorecardId IS NOT NULL AND i.Status <> d.Status
                      AND NOT ((d.Status = ''DRAFT'' AND i.Status = ''APPROVED'') OR (d.Status = ''APPROVED'' AND i.Status = ''RETIRED'')))
                  OR (d.ScorecardId IS NOT NULL AND d.Status <> ''DRAFT'' AND EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')))
        THROW 50066, ''A scorecard is written as a draft and approved whole; approved, it never changes and is only retired, and a change is a new version (BR-FIN-023)'', 1;
    -- Approved whole: weights of 100, a grid for each quantitative metric in its direction and none for a
    -- qualitative one, item rules on quantitative metrics with thresholds in their direction.
    IF EXISTS (SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.ScorecardId = i.ScorecardId
               WHERE i.Status = ''APPROVED'' AND d.Status = ''DRAFT''
                 AND (ISNULL((SELECT SUM(sm.Weight) FROM fin.ScorecardMetric AS sm WHERE sm.ScorecardId = i.ScorecardId), 0) <> 100
                      OR NOT EXISTS (SELECT 1 FROM fin.ScorecardMetric AS sm JOIN fin.CreditMetric AS m ON m.CreditMetricId = sm.MetricId
                                     WHERE sm.ScorecardId = i.ScorecardId AND m.Kind = ''QUANTITATIVE'')
                      OR EXISTS (SELECT 1 FROM fin.ScorecardMetric AS sm JOIN fin.CreditMetric AS m ON m.CreditMetricId = sm.MetricId
                                 WHERE sm.ScorecardId = i.ScorecardId
                                   AND ((m.Kind = ''QUALITATIVE'' AND sm.B0 IS NOT NULL)
                                        OR (m.Kind = ''QUANTITATIVE'' AND (sm.B0 IS NULL
                                            OR NOT ((m.Direction = ''LOWER_BETTER'' AND sm.B0 < sm.B8) OR (m.Direction = ''HIGHER_BETTER'' AND sm.B0 > sm.B8))))))
                      OR EXISTS (SELECT 1 FROM fin.ScorecardItemRule AS r JOIN fin.CreditMetric AS m ON m.CreditMetricId = r.MetricId
                                 WHERE r.ScorecardId = i.ScorecardId
                                   AND NOT ((m.Direction = ''LOWER_BETTER'' AND r.T1 < r.T4) OR (m.Direction = ''HIGHER_BETTER'' AND r.T1 > r.T4)))))
        THROW 50066, ''A scorecard is approved with weights of 100 and a grid in each quantitative metric''''s direction (BR-FIN-023)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
-- The rows of a scorecard change only while it is a draft.
CREATE OR ALTER TRIGGER fin.TR_ScorecardMetric_DraftOnly ON fin.ScorecardMetric
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT ScorecardId FROM inserted UNION SELECT ScorecardId FROM deleted) AS r
               JOIN fin.Scorecard AS sc WITH (UPDLOCK, HOLDLOCK) ON sc.ScorecardId = r.ScorecardId
               WHERE sc.Status <> 'DRAFT')
        THROW 50066, 'The rows of an approved scorecard do not change; a change is a new version (BR-FIN-023)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_ScorecardItemRule_DraftOnly ON fin.ScorecardItemRule
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT ScorecardId FROM inserted UNION SELECT ScorecardId FROM deleted) AS r
               JOIN fin.Scorecard AS sc WITH (UPDLOCK, HOLDLOCK) ON sc.ScorecardId = r.ScorecardId
               WHERE sc.Status <> 'DRAFT')
        THROW 50066, 'The rows of an approved scorecard do not change; a change is a new version (BR-FIN-023)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_ScorecardAdjustment_DraftOnly ON fin.ScorecardAdjustment
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT ScorecardId FROM inserted UNION SELECT ScorecardId FROM deleted) AS r
               JOIN fin.Scorecard AS sc WITH (UPDLOCK, HOLDLOCK) ON sc.ScorecardId = r.ScorecardId
               WHERE sc.Status <> 'DRAFT')
        THROW 50066, 'The rows of an approved scorecard do not change; a change is a new version (BR-FIN-023)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_ScorecardParameter_DraftOnly ON fin.ScorecardParameter
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT ScorecardId FROM inserted UNION SELECT ScorecardId FROM deleted) AS r
               JOIN fin.Scorecard AS sc WITH (UPDLOCK, HOLDLOCK) ON sc.ScorecardId = r.ScorecardId
               WHERE sc.Status <> 'DRAFT')
        THROW 50066, 'The rows of an approved scorecard do not change; a change is a new version (BR-FIN-023)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_ScorecardSubfactor_DraftOnly ON fin.ScorecardSubfactor
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT ScorecardId FROM inserted UNION SELECT ScorecardId FROM deleted) AS r
               JOIN fin.Scorecard AS sc WITH (UPDLOCK, HOLDLOCK) ON sc.ScorecardId = r.ScorecardId
               WHERE sc.Status <> 'DRAFT')
        THROW 50066, 'The rows of an approved scorecard do not change; a change is a new version (BR-FIN-023)', 1;
END;
GO
-- The grades of the scale and the metrics an approved scorecard uses keep their meaning.
CREATE OR ALTER TRIGGER fin.TR_RatingGrade_Fixed ON fin.RatingGrade
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT d.RatingGradeId, d.Code, d.NotchNo, d.Category, d.ScoreFrom, d.ScoreTo, d.RiskBand, d.IsInvestmentGrade FROM deleted AS d
               EXCEPT
               SELECT i.RatingGradeId, i.Code, i.NotchNo, i.Category, i.ScoreFrom, i.ScoreTo, i.RiskBand, i.IsInvestmentGrade FROM inserted AS i)
        THROW 50066, 'The grades of the rating scale keep their code, notch, range and band; only their descriptions change (BR-FIN-018)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditMetric_Fixed ON fin.CreditMetric
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT d.CreditMetricId, d.Code, d.Kind, d.Unit, d.Direction, d.DefinitionAr FROM deleted AS d
                     EXCEPT
                     SELECT i.CreditMetricId, i.Code, i.Kind, i.Unit, i.Direction, i.DefinitionAr FROM inserted AS i) AS x
               WHERE EXISTS (SELECT 1 FROM fin.ScorecardMetric AS sm JOIN fin.Scorecard AS sc ON sc.ScorecardId = sm.ScorecardId
                             WHERE sm.MetricId = x.CreditMetricId AND sc.Status <> 'DRAFT')
                  OR EXISTS (SELECT 1 FROM fin.ScorecardItemRule AS r JOIN fin.Scorecard AS sc ON sc.ScorecardId = r.ScorecardId
                             WHERE r.MetricId = x.CreditMetricId AND sc.Status <> 'DRAFT'))
        THROW 50066, 'A metric that an approved scorecard uses keeps its code, kind, unit, direction and definition (BR-FIN-023)', 1;
END;
GO
/* The horizontal and vertical analysis of a statement against another (FR-FIN-021): each line, its amount, the
   amount of the same line in the other statement, the change and its percentage, and its share of total assets
   (balance sheet) or of revenue (income statement). Lines of other statements than the two are never read. */
CREATE OR ALTER FUNCTION fin.fn_StatementItemAnalysis (@StatementId BIGINT, @PriorStatementId BIGINT)
RETURNS TABLE
AS RETURN
WITH cur AS (
    SELECT ln.TenantId, ln.StatementId, li.LineCatalogItemId, li.Code, li.NameAr, li.NameEn, li.Section, li.IsTotal, li.SortOrder,
           COALESCE(ln.EnteredAmount, ln.ComputedAmount) AS Amount
    FROM fin.StatementLine AS ln
    JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
    WHERE ln.StatementId = @StatementId
), pri AS (
    SELECT li.Code, COALESCE(ln.EnteredAmount, ln.ComputedAmount) AS Amount
    FROM fin.StatementLine AS ln
    JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
    WHERE ln.StatementId = @PriorStatementId
), base AS (
    SELECT MAX(CASE WHEN Code = 'TOTAL_ASSETS' THEN Amount END) AS TotalAssets, MAX(CASE WHEN Code = 'REVENUE' THEN Amount END) AS Revenue
    FROM cur
)
SELECT cur.TenantId, cur.StatementId, @PriorStatementId AS PriorStatementId, cur.LineCatalogItemId, cur.Code AS LineCode, cur.NameAr, cur.NameEn,
       cur.Section, cur.IsTotal, cur.SortOrder, cur.Amount, pri.Amount AS PriorAmount,
       cur.Amount - pri.Amount AS Change,
       CAST(CASE WHEN pri.Amount IS NULL OR pri.Amount = 0 THEN NULL ELSE (cur.Amount - pri.Amount) * 100.0 / ABS(pri.Amount) END AS DECIMAL(19,4)) AS ChangePct,
       CAST(CASE WHEN cur.Section IN ('BS_ASSET','BS_LIABILITY','BS_EQUITY') AND base.TotalAssets <> 0 THEN cur.Amount * 100.0 / base.TotalAssets
                 WHEN cur.Section = 'IS' AND base.Revenue <> 0 THEN cur.Amount * 100.0 / base.Revenue END AS DECIMAL(19,4)) AS SharePct,
       CASE WHEN cur.Section IN ('BS_ASSET','BS_LIABILITY','BS_EQUITY') THEN 'TOTAL_ASSETS' WHEN cur.Section = 'IS' THEN 'REVENUE' END AS ShareBase
FROM cur
CROSS JOIN base
LEFT JOIN pri ON pri.Code = cur.Code;
GO

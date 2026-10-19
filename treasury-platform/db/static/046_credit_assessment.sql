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

     fin.usp_ComputeCreditAssessment   computes a draft assessment: factors, findings, grades, summary, snapshot,
                                       and the hash of what it read. Runs as the caller: the row filters keep it to
                                       the bound tenant, and the ownership chain lets it write what the application
                                       role may not (the DENYs at the end).
     fin.v_CreditAssessmentReport      the report: header, grades, risk band, counts, summary and disclaimer
     fin.v_CreditAssessmentFactors     the scorecard table of an assessment
     fin.v_CreditAssessmentFindings    its strengths, points to watch, weaknesses, risks and adjustments
     fin.v_CreditAssessmentItems       each line of the statement with the line it is compared with, its change,
                                       its share of total assets or revenue, and the risk level of its item rule
     fin.v_CreditAssessmentCovenants   the covenants tested on the assessed statement and how they fare
     fin.v_CreditAssessmentGroupUnits  for a consolidated statement, each unit with its own latest approved grade
     fin.fn_StatementItemAnalysis      the horizontal and vertical analysis of a statement against another

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
/* The score of a value on a grid of nine boundaries, best cap first (docs/35 section 3): 0.5 at the best cap or
   beyond, 20.5 at the worst cap or beyond, linear between two boundaries, whose scores are 0.5, 1.5, 4.5, 7.5,
   10.5, 13.5, 16.5, 19.5 and 20.5. The grid's order gives the direction. */
CREATE OR ALTER FUNCTION fin.fn_CreditGridScore (@v FLOAT, @b0 FLOAT, @b1 FLOAT, @b2 FLOAT, @b3 FLOAT, @b4 FLOAT, @b5 FLOAT, @b6 FLOAT, @b7 FLOAT, @b8 FLOAT)
RETURNS TABLE
AS RETURN
SELECT CAST(ROUND(CASE
         WHEN @v IS NULL OR @b0 IS NULL OR @b8 IS NULL THEN NULL
         WHEN @b0 < @b8 THEN
              CASE WHEN @v <= @b0 THEN 0.5 WHEN @v >= @b8 THEN 20.5
                   WHEN @v < @b1 THEN 0.5  + (@v - @b0) / (@b1 - @b0) * 1
                   WHEN @v < @b2 THEN 1.5  + (@v - @b1) / (@b2 - @b1) * 3
                   WHEN @v < @b3 THEN 4.5  + (@v - @b2) / (@b3 - @b2) * 3
                   WHEN @v < @b4 THEN 7.5  + (@v - @b3) / (@b4 - @b3) * 3
                   WHEN @v < @b5 THEN 10.5 + (@v - @b4) / (@b5 - @b4) * 3
                   WHEN @v < @b6 THEN 13.5 + (@v - @b5) / (@b6 - @b5) * 3
                   WHEN @v < @b7 THEN 16.5 + (@v - @b6) / (@b7 - @b6) * 3
                   ELSE               19.5 + (@v - @b7) / (@b8 - @b7) * 1 END
         ELSE CASE WHEN @v >= @b0 THEN 0.5 WHEN @v <= @b8 THEN 20.5
                   WHEN @v > @b1 THEN 0.5  + (@b0 - @v) / (@b0 - @b1) * 1
                   WHEN @v > @b2 THEN 1.5  + (@b1 - @v) / (@b1 - @b2) * 3
                   WHEN @v > @b3 THEN 4.5  + (@b2 - @v) / (@b2 - @b3) * 3
                   WHEN @v > @b4 THEN 7.5  + (@b3 - @v) / (@b3 - @b4) * 3
                   WHEN @v > @b5 THEN 10.5 + (@b4 - @v) / (@b4 - @b5) * 3
                   WHEN @v > @b6 THEN 13.5 + (@b5 - @v) / (@b5 - @b6) * 3
                   WHEN @v > @b7 THEN 16.5 + (@b6 - @v) / (@b6 - @b7) * 3
                   ELSE               19.5 + (@b7 - @v) / (@b7 - @b8) * 1 END
       END, 4) AS DECIMAL(9,4)) AS Score;
GO
/* The risk level of a value under the four thresholds of an item rule; a value on a threshold belongs to the worse
   level (docs/35 section 6). */
CREATE OR ALTER FUNCTION fin.fn_CreditItemLevel (@v FLOAT, @t1 FLOAT, @t2 FLOAT, @t3 FLOAT, @t4 FLOAT)
RETURNS TABLE
AS RETURN
SELECT CAST(CASE
         WHEN @v IS NULL THEN NULL
         WHEN @t1 < @t4 THEN CASE WHEN @v < @t1 THEN 'LOW' WHEN @v < @t2 THEN 'MODERATE' WHEN @v < @t3 THEN 'ELEVATED' WHEN @v < @t4 THEN 'HIGH' ELSE 'CRITICAL' END
         ELSE CASE WHEN @v > @t1 THEN 'LOW' WHEN @v > @t2 THEN 'MODERATE' WHEN @v > @t3 THEN 'ELEVATED' WHEN @v > @t4 THEN 'HIGH' ELSE 'CRITICAL' END
       END AS VARCHAR(8)) AS RiskLevel;
GO
/* The hash of what a computation reads from the assessment itself: its statement, comparison statement, scorecard,
   date, rate and the analyst's inputs. The approved statements, the scorecard and the parent's approved assessment
   do not change, so a submission whose hash differs from the computed one was changed after its computation. */
CREATE OR ALTER FUNCTION fin.fn_CreditAssessmentInputsHash (@TenantId INT, @AssessmentId BIGINT)
RETURNS TABLE
AS RETURN
SELECT CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONCAT(
           a.StatementId, '|', a.PriorStatementId, '|', a.ScorecardId, '|', CONVERT(CHAR(10), a.AssessmentDate, 23), '|',
           CONVERT(VARCHAR(40), a.FxRateToScorecard), '|',
           (SELECT i.Kind, i.MetricId, i.GradeId, i.Notches, i.ParentAssessmentId, i.Justification
            FROM fin.CreditAssessmentInput AS i
            WHERE i.TenantId = a.TenantId AND i.AssessmentId = a.CreditAssessmentId
            ORDER BY i.Kind, i.MetricId
            FOR JSON PATH))), 2) AS InputsHash
FROM fin.CreditAssessment AS a
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
/* ---------------------------------------------------------------------------------------------------------------
   The computation (FR-FIN-020 to FR-FIN-023, BR-FIN-018 to BR-FIN-022; docs/35 sections 3 to 9).
   --------------------------------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE fin.usp_ComputeCreditAssessment
    @AssessmentId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tenant INT, @company BIGINT, @stmt BIGINT, @priorIn BIGINT, @prior BIGINT, @card INT, @asOf DATE, @fxIn DECIMAL(19,8),
            @status VARCHAR(10), @user BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
    DECLARE @pt VARCHAR(10), @pe DATE, @basis VARCHAR(12), @assurance VARCHAR(10), @opinion VARCHAR(11), @goingConcern BIT, @cur INT, @sstatus VARCHAR(10),
            @versionReason VARCHAR(10), @supersedes BIGINT, @isHolding BIT, @ppt VARCHAR(10), @cardStatus VARCHAR(8), @cardCur INT, @unit FLOAT,
            @minCov DECIMAL(5,2), @qualBound INT, @supportAge INT, @cardCode VARCHAR(40), @cardVer INT;
    DECLARE @k FLOAT, @pk FLOAT, @fx FLOAT;

    BEGIN TRANSACTION;
    SELECT @tenant = TenantId, @company = CompanyId, @stmt = StatementId, @priorIn = PriorStatementId, @card = ScorecardId,
           @asOf = AssessmentDate, @fxIn = FxRateToScorecard, @status = Status
    FROM fin.CreditAssessment WITH (UPDLOCK, HOLDLOCK)
    WHERE CreditAssessmentId = @AssessmentId;                       -- the row filter shows the bound tenant's only
    IF @tenant IS NULL THROW 50064, 'No credit assessment with this id for this tenant', 1;
    IF @status <> 'DRAFT' THROW 50063, 'Only a draft assessment is computed (BR-FIN-024)', 1;

    SELECT @pt = s.PeriodType, @pe = s.PeriodEnd, @basis = s.Basis, @assurance = s.Assurance, @opinion = s.AuditOpinion, @goingConcern = s.GoingConcernUncertainty,
           @cur = s.CurrencyId, @sstatus = s.Status, @versionReason = s.VersionReason, @supersedes = s.SupersedesId, @isHolding = c.IsHolding
    FROM fin.FinancialStatement AS s
    JOIN org.Company AS c ON c.TenantId = s.TenantId AND c.CompanyId = s.CompanyId
    WHERE s.TenantId = @tenant AND s.FinancialStatementId = @stmt;
    IF @sstatus <> 'APPROVED' THROW 50064, 'An assessment reads an approved statement (BR-FIN-019)', 1;
    SELECT @cardStatus = Status, @cardCur = CurrencyId, @unit = AmountUnit, @minCov = MinCoveragePct, @qualBound = QualitativeBoundNotches,
           @supportAge = SupportMaxAgeMonths, @cardCode = Code, @cardVer = VersionNo
    FROM fin.Scorecard WHERE ScorecardId = @card;
    IF @cardStatus <> 'APPROVED' THROW 50064, 'An assessment uses an approved scorecard (BR-FIN-023)', 1;
    IF @cur <> @cardCur AND @fxIn IS NULL
        THROW 50064, 'The statement''s currency differs from the scorecard''s: give the exchange rate (BR-FIN-019)', 1;
    SET @fx = CASE WHEN @cur = @cardCur THEN 1 ELSE @fxIn END;

    -- The comparison statement: the one given, else the approved statement of the same company, basis and period type
    -- a year earlier (audited first).
    IF @priorIn IS NOT NULL
    BEGIN
        SELECT @prior = FinancialStatementId, @ppt = PeriodType FROM fin.FinancialStatement
        WHERE TenantId = @tenant AND FinancialStatementId = @priorIn AND CompanyId = @company AND Basis = @basis
          AND Status = 'APPROVED' AND PeriodEnd < @pe;
        IF @prior IS NULL THROW 50064, 'The comparison statement is an approved, earlier statement of the same company and basis (BR-FIN-019)', 1;
    END
    ELSE
        SELECT TOP (1) @prior = FinancialStatementId, @ppt = PeriodType FROM fin.FinancialStatement
        WHERE TenantId = @tenant AND CompanyId = @company AND Basis = @basis AND PeriodType = @pt AND Status = 'APPROVED'
          AND PeriodEnd = EOMONTH(@pe, -12)
        ORDER BY CASE Assurance WHEN 'AUDITED' THEN 0 WHEN 'REVIEWED' THEN 1 ELSE 2 END, VersionNo DESC;

    SET @k = 12.0 / CASE @pt WHEN 'ANNUAL' THEN 12 WHEN 'SEMIANNUAL' THEN 6 WHEN 'QUARTERLY' THEN 3 ELSE 1 END;
    SET @pk = 12.0 / CASE @ppt WHEN 'ANNUAL' THEN 12 WHEN 'SEMIANNUAL' THEN 6 WHEN 'QUARTERLY' THEN 3 ELSE 1 END;

    -- The lines read: an entered amount, else the computed one. A line missing is NULL, but the twelve optional lines
    -- of the credit assessment and the cash flow lines count as zero (docs/35 section 4).
    DECLARE @L TABLE (Which CHAR(1) NOT NULL, Code VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL, Amount FLOAT NULL, PRIMARY KEY (Which, Code));
    INSERT @L (Which, Code, Amount)
    SELECT CASE WHEN ln.StatementId = @stmt THEN 'C' WHEN ln.StatementId = @prior THEN 'P' ELSE 'O' END, li.Code,
           CAST(COALESCE(ln.EnteredAmount, ln.ComputedAmount) AS FLOAT)
    FROM fin.StatementLine AS ln
    JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
    WHERE ln.TenantId = @tenant AND ln.StatementId IN (@stmt, @prior, @supersedes);
    DECLARE @opt TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY);
    INSERT @opt VALUES ('DUE_FROM_RELATED'), ('CONTRACT_ASSETS'), ('DUE_TO_RELATED'), ('BANK_ACCEPTANCES'), ('SHAREHOLDER_LOANS_SUB'), ('EOSB'),
                       ('REVALUATION_RESERVE'), ('LC_OUTSTANDING'), ('LG_PERFORMANCE'), ('LG_FINANCIAL'), ('GUARANTEES_GIVEN'), ('ZAKAT_DISPUTED'),
                       ('OP_CASH_FLOW'), ('CAPEX'), ('PRINCIPAL_REPAID'), ('INTEREST_PAID'), ('DIVIDENDS');
    INSERT @L (Which, Code, Amount)
    SELECT w.Which, o.Code, 0 FROM @opt AS o CROSS JOIN (VALUES ('C'), ('P'), ('O')) AS w (Which)
    WHERE NOT EXISTS (SELECT 1 FROM @L AS l WHERE l.Which = w.Which AND l.Code = o.Code);

    DECLARE @CASH FLOAT, @AR FLOAT, @CONTRACT_ASSETS FLOAT, @INVENTORY FLOAT, @DUE_FROM_RELATED FLOAT, @OTHER_CA FLOAT, @TOTAL_CA FLOAT, @INTANGIBLES FLOAT,
            @TOTAL_ASSETS FLOAT, @ST_LOANS FLOAT, @BANK_ACCEPTANCES FLOAT, @CURRENT_PORTION_LTD FLOAT, @AP FLOAT, @DUE_TO_RELATED FLOAT, @TOTAL_CL FLOAT,
            @LT_LOANS FLOAT, @LEASE_LIABS FLOAT, @SHAREHOLDER_LOANS_SUB FLOAT, @EOSB FLOAT, @TOTAL_LIABS FLOAT, @SHARE_CAPITAL FLOAT, @RETAINED_EARNINGS FLOAT,
            @REVALUATION_RESERVE FLOAT, @TOTAL_EQUITY FLOAT, @REVENUE FLOAT, @COGS FLOAT, @GROSS_PROFIT FLOAT, @EBITDA_LINE FLOAT, @OPERATING_PROFIT FLOAT,
            @DEPR_AMORT FLOAT, @FINANCE_COSTS FLOAT, @ZAKAT_TAX FLOAT, @NET_PROFIT FLOAT, @OP_CASH_FLOW FLOAT, @INTEREST_PAID FLOAT, @DIVIDENDS FLOAT,
            @LC_OUTSTANDING FLOAT, @LG_PERFORMANCE FLOAT, @LG_FINANCIAL FLOAT, @GUARANTEES_GIVEN FLOAT, @ZAKAT_DISPUTED FLOAT, @cfNonZero INT,
            @P_REVENUE FLOAT, @P_GROSS_PROFIT FLOAT, @P_TOTAL_ASSETS FLOAT, @P_CURRENT_PORTION_LTD FLOAT, @P_OP_CASH_FLOW FLOAT, @P_cfNonZero INT,
            @O_NET_PROFIT FLOAT, @O_TOTAL_EQUITY FLOAT;
    SELECT @CASH = MAX(CASE WHEN Code = 'CASH' THEN Amount END), @AR = MAX(CASE WHEN Code = 'AR' THEN Amount END),
           @CONTRACT_ASSETS = MAX(CASE WHEN Code = 'CONTRACT_ASSETS' THEN Amount END), @INVENTORY = MAX(CASE WHEN Code = 'INVENTORY' THEN Amount END),
           @DUE_FROM_RELATED = MAX(CASE WHEN Code = 'DUE_FROM_RELATED' THEN Amount END), @OTHER_CA = MAX(CASE WHEN Code = 'OTHER_CA' THEN Amount END),
           @TOTAL_CA = MAX(CASE WHEN Code = 'TOTAL_CA' THEN Amount END), @INTANGIBLES = MAX(CASE WHEN Code = 'INTANGIBLES' THEN Amount END),
           @TOTAL_ASSETS = MAX(CASE WHEN Code = 'TOTAL_ASSETS' THEN Amount END), @ST_LOANS = MAX(CASE WHEN Code = 'ST_LOANS' THEN Amount END),
           @BANK_ACCEPTANCES = MAX(CASE WHEN Code = 'BANK_ACCEPTANCES' THEN Amount END),
           @CURRENT_PORTION_LTD = MAX(CASE WHEN Code = 'CURRENT_PORTION_LTD' THEN Amount END), @AP = MAX(CASE WHEN Code = 'AP' THEN Amount END),
           @DUE_TO_RELATED = MAX(CASE WHEN Code = 'DUE_TO_RELATED' THEN Amount END), @TOTAL_CL = MAX(CASE WHEN Code = 'TOTAL_CL' THEN Amount END),
           @LT_LOANS = MAX(CASE WHEN Code = 'LT_LOANS' THEN Amount END), @LEASE_LIABS = MAX(CASE WHEN Code = 'LEASE_LIABS' THEN Amount END),
           @SHAREHOLDER_LOANS_SUB = MAX(CASE WHEN Code = 'SHAREHOLDER_LOANS_SUB' THEN Amount END), @EOSB = MAX(CASE WHEN Code = 'EOSB' THEN Amount END),
           @TOTAL_LIABS = MAX(CASE WHEN Code = 'TOTAL_LIABS' THEN Amount END), @SHARE_CAPITAL = MAX(CASE WHEN Code = 'SHARE_CAPITAL' THEN Amount END),
           @RETAINED_EARNINGS = MAX(CASE WHEN Code = 'RETAINED_EARNINGS' THEN Amount END),
           @REVALUATION_RESERVE = MAX(CASE WHEN Code = 'REVALUATION_RESERVE' THEN Amount END), @TOTAL_EQUITY = MAX(CASE WHEN Code = 'TOTAL_EQUITY' THEN Amount END),
           @REVENUE = MAX(CASE WHEN Code = 'REVENUE' THEN Amount END) * @k, @COGS = ABS(MAX(CASE WHEN Code = 'COGS' THEN Amount END)) * @k,
           @GROSS_PROFIT = MAX(CASE WHEN Code = 'GROSS_PROFIT' THEN Amount END) * @k, @EBITDA_LINE = MAX(CASE WHEN Code = 'EBITDA' THEN Amount END) * @k,
           @OPERATING_PROFIT = MAX(CASE WHEN Code = 'OPERATING_PROFIT' THEN Amount END) * @k, @DEPR_AMORT = ABS(MAX(CASE WHEN Code = 'DEPR_AMORT' THEN Amount END)) * @k,
           @FINANCE_COSTS = ABS(MAX(CASE WHEN Code = 'FINANCE_COSTS' THEN Amount END)) * @k, @ZAKAT_TAX = ABS(MAX(CASE WHEN Code = 'ZAKAT_TAX' THEN Amount END)) * @k,
           @NET_PROFIT = MAX(CASE WHEN Code = 'NET_PROFIT' THEN Amount END) * @k, @OP_CASH_FLOW = MAX(CASE WHEN Code = 'OP_CASH_FLOW' THEN Amount END) * @k,
           @INTEREST_PAID = ABS(MAX(CASE WHEN Code = 'INTEREST_PAID' THEN Amount END)) * @k, @DIVIDENDS = ABS(MAX(CASE WHEN Code = 'DIVIDENDS' THEN Amount END)) * @k,
           @LC_OUTSTANDING = MAX(CASE WHEN Code = 'LC_OUTSTANDING' THEN Amount END), @LG_PERFORMANCE = MAX(CASE WHEN Code = 'LG_PERFORMANCE' THEN Amount END),
           @LG_FINANCIAL = MAX(CASE WHEN Code = 'LG_FINANCIAL' THEN Amount END), @GUARANTEES_GIVEN = MAX(CASE WHEN Code = 'GUARANTEES_GIVEN' THEN Amount END),
           @ZAKAT_DISPUTED = MAX(CASE WHEN Code = 'ZAKAT_DISPUTED' THEN Amount END),
           @cfNonZero = COUNT(CASE WHEN Code IN ('OP_CASH_FLOW','CAPEX','PRINCIPAL_REPAID','INTEREST_PAID','DIVIDENDS') AND Amount <> 0 THEN 1 END)
    FROM @L WHERE Which = 'C';
    SELECT @P_REVENUE = MAX(CASE WHEN Code = 'REVENUE' THEN Amount END) * @pk, @P_GROSS_PROFIT = MAX(CASE WHEN Code = 'GROSS_PROFIT' THEN Amount END) * @pk,
           @P_TOTAL_ASSETS = MAX(CASE WHEN Code = 'TOTAL_ASSETS' THEN Amount END), @P_CURRENT_PORTION_LTD = MAX(CASE WHEN Code = 'CURRENT_PORTION_LTD' AND @prior IS NOT NULL THEN Amount END),
           @P_OP_CASH_FLOW = MAX(CASE WHEN Code = 'OP_CASH_FLOW' THEN Amount END) * @pk,
           @P_cfNonZero = COUNT(CASE WHEN Code IN ('OP_CASH_FLOW','CAPEX','PRINCIPAL_REPAID','INTEREST_PAID','DIVIDENDS') AND Amount <> 0 THEN 1 END)
    FROM @L WHERE Which = 'P';
    SELECT @O_NET_PROFIT = MAX(CASE WHEN Code = 'NET_PROFIT' THEN Amount END), @O_TOTAL_EQUITY = MAX(CASE WHEN Code = 'TOTAL_EQUITY' THEN Amount END)
    FROM @L WHERE Which = 'O';

    DECLARE @cf BIT = CASE WHEN @cfNonZero > 0 THEN 1 ELSE 0 END,                   -- a cash flow statement was given
            @pcf BIT = CASE WHEN @prior IS NOT NULL AND @P_cfNonZero > 0 THEN 1 ELSE 0 END,
            @ebitda FLOAT = CASE WHEN @OPERATING_PROFIT IS NOT NULL AND @DEPR_AMORT IS NOT NULL THEN @OPERATING_PROFIT + @DEPR_AMORT ELSE @EBITDA_LINE END,
            @debt FLOAT = @ST_LOANS + @CURRENT_PORTION_LTD + @LT_LOANS + @LEASE_LIABS + @BANK_ACCEPTANCES + @DUE_TO_RELATED,
            @stDebt FLOAT = @ST_LOANS + @BANK_ACCEPTANCES + @CURRENT_PORTION_LTD,
            @quasi FLOAT = @TOTAL_EQUITY + @SHAREHOLDER_LOANS_SUB,
            @avgAssets FLOAT = CASE WHEN @P_TOTAL_ASSETS IS NOT NULL THEN (@TOTAL_ASSETS + @P_TOTAL_ASSETS) / 2 ELSE @TOTAL_ASSETS END,
            @interest FLOAT = CASE WHEN @FINANCE_COSTS >= @INTEREST_PAID THEN @FINANCE_COSTS ELSE @INTEREST_PAID END,
            @contingent FLOAT = @LC_OUTSTANDING + @LG_PERFORMANCE + @LG_FINANCIAL + @GUARANTEES_GIVEN;
    DECLARE @cfo FLOAT = CASE WHEN @cf = 1 THEN @OP_CASH_FLOW END,
            @tnwTang FLOAT = @quasi - @INTANGIBLES,
            @principal FLOAT = COALESCE(@P_CURRENT_PORTION_LTD, @CURRENT_PORTION_LTD),
            @arTotal FLOAT = @AR + @CONTRACT_ASSETS,
            @trade FLOAT = @AR + @INVENTORY;
    DECLARE @adjTnw FLOAT = @tnwTang - @DUE_FROM_RELATED - @REVALUATION_RESERVE,
            @cfoAvg FLOAT = CASE WHEN @cf = 1 AND @pcf = 1 THEN (@OP_CASH_FLOW + @P_OP_CASH_FLOW) / 2 ELSE @cfo END,
            @dso FLOAT = CASE WHEN @REVENUE > 0 THEN @arTotal / @REVENUE * 365 END,
            @dio FLOAT = CASE WHEN @COGS > 0 THEN @INVENTORY / @COGS * 365 END,
            @dpo FLOAT = CASE WHEN @COGS > 0 THEN @AP / @COGS * 365 END,
            @dsNum FLOAT = @ebitda - @ZAKAT_TAX, @dsDen FLOAT = @principal + @interest;

    -- Every metric: OK (computed), BEST or WORST (the ratio has no meaning and takes an end of the continuum), or NA
    -- (not computable), with its reason (docs/35 section 4).
    DECLARE @m TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, State VARCHAR(5) NOT NULL, Value FLOAT NULL, Reason NVARCHAR(300) NULL);
    INSERT @m (Code, State, Value, Reason)
    SELECT v.Code, v.State, CASE WHEN v.State = 'OK' THEN v.Value END, CASE WHEN v.State <> 'OK' THEN v.Reason END
    FROM (VALUES
        ('REVENUE_SIZE', CASE WHEN @REVENUE IS NULL THEN 'NA' WHEN @REVENUE <= 0 THEN 'WORST' ELSE 'OK' END, @REVENUE * @fx / @unit,
                         CASE WHEN @REVENUE IS NULL THEN N'بند الإيرادات غير مدخل' ELSE N'إيرادات غير موجبة' END),
        ('EBITDA_MARGIN', CASE WHEN @REVENUE IS NULL OR @ebitda IS NULL OR @REVENUE <= 0 THEN 'NA' ELSE 'OK' END, @ebitda / NULLIF(@REVENUE, 0) * 100,
                          N'الإيرادات أو الربح التشغيلي غير مدخلة، أو إيرادات غير موجبة'),
        ('NET_MARGIN', CASE WHEN @REVENUE IS NULL OR @NET_PROFIT IS NULL OR @REVENUE <= 0 THEN 'NA' ELSE 'OK' END, @NET_PROFIT / NULLIF(@REVENUE, 0) * 100,
                       N'الإيرادات أو صافي الربح غير مدخلة، أو إيرادات غير موجبة'),
        ('ROA', CASE WHEN @OPERATING_PROFIT IS NULL OR @TOTAL_ASSETS IS NULL OR @avgAssets <= 0 THEN 'NA' ELSE 'OK' END, @OPERATING_PROFIT / NULLIF(@avgAssets, 0) * 100,
                N'الربح التشغيلي أو إجمالي الأصول غير مدخل، أو أصول غير موجبة'),
        ('DEBT_TO_EBITDA', CASE WHEN @debt IS NULL OR @ebitda IS NULL THEN 'NA' WHEN @debt = 0 AND @ebitda > 0 THEN 'BEST' WHEN @debt = 0 OR @ebitda <= 0 THEN 'WORST' ELSE 'OK' END,
                           @debt / NULLIF(@ebitda, 0),
                           CASE WHEN @debt IS NULL OR @ebitda IS NULL THEN N'بنود الدين أو الربح التشغيلي غير مدخلة' WHEN @debt = 0 AND @ebitda > 0 THEN N'لا دين'
                                WHEN @debt = 0 THEN N'لا دين لكن EBITDA غير موجب' ELSE N'EBITDA غير موجب مع دين' END),
        ('TL_TO_TNW', CASE WHEN @TOTAL_LIABS IS NULL OR @adjTnw IS NULL THEN 'NA' WHEN @adjTnw <= 0 THEN 'WORST' ELSE 'OK' END,
                      (@TOTAL_LIABS - @SHAREHOLDER_LOANS_SUB) / NULLIF(@adjTnw, 0),
                      CASE WHEN @TOTAL_LIABS IS NULL OR @adjTnw IS NULL THEN N'بنود الخصوم أو حقوق الملكية غير مدخلة' ELSE N'صافي الثروة الملموسة المعدَّلة غير موجب' END),
        ('EBITDA_TO_INTEREST', CASE WHEN @ebitda IS NULL OR @interest IS NULL THEN 'NA' WHEN @interest = 0 AND @ebitda > 0 THEN 'BEST' WHEN @interest = 0 OR @ebitda <= 0 THEN 'WORST' ELSE 'OK' END,
                               @ebitda / NULLIF(@interest, 0),
                               CASE WHEN @ebitda IS NULL OR @interest IS NULL THEN N'الربح التشغيلي أو تكاليف التمويل غير مدخلة' WHEN @interest = 0 AND @ebitda > 0 THEN N'لا تكاليف تمويل'
                                    WHEN @interest = 0 THEN N'لا تكاليف تمويل لكن EBITDA غير موجب' ELSE N'EBITDA غير موجب' END),
        ('DSCR', CASE WHEN @dsNum IS NULL OR @dsDen IS NULL THEN 'NA' WHEN @dsDen = 0 AND @dsNum > 0 THEN 'BEST' WHEN @dsDen = 0 OR @dsNum <= 0 THEN 'WORST' ELSE 'OK' END,
                 @dsNum / NULLIF(@dsDen, 0),
                 CASE WHEN @dsNum IS NULL OR @dsDen IS NULL THEN N'بنود خدمة الدين غير مدخلة' WHEN @dsDen = 0 AND @dsNum > 0 THEN N'لا خدمة دين'
                      WHEN @dsDen = 0 THEN N'لا خدمة دين لكن البسط غير موجب' ELSE N'EBITDA بعد الزكاة والضريبة غير موجب' END),
        ('CFO_TO_DEBT', CASE WHEN @cf = 0 OR @debt IS NULL THEN 'NA' WHEN @debt = 0 AND @cfoAvg >= 0 THEN 'BEST' WHEN @debt = 0 THEN 'WORST' ELSE 'OK' END,
                        @cfoAvg / NULLIF(@debt, 0) * 100,
                        CASE WHEN @cf = 0 THEN N'لا قائمة تدفقات نقدية' WHEN @debt IS NULL THEN N'بنود الدين غير مدخلة' WHEN @cfoAvg >= 0 THEN N'لا دين'
                             ELSE N'لا دين لكن التدفق التشغيلي سالب' END),
        ('CURRENT_RATIO', CASE WHEN @TOTAL_CA IS NULL OR @TOTAL_CL IS NULL THEN 'NA' WHEN @TOTAL_CL = 0 THEN 'BEST' ELSE 'OK' END, @TOTAL_CA / NULLIF(@TOTAL_CL, 0),
                          CASE WHEN @TOTAL_CA IS NULL OR @TOTAL_CL IS NULL THEN N'إجماليات المتداول غير مدخلة' ELSE N'لا خصوم متداولة' END),
        ('DSO', CASE WHEN @dso IS NULL THEN 'NA' ELSE 'OK' END, @dso, N'الذمم أو الإيرادات غير مدخلة، أو إيرادات غير موجبة'),
        ('DIO', CASE WHEN @dio IS NULL THEN 'NA' ELSE 'OK' END, @dio, N'المخزون أو تكلفة المبيعات غير مدخلة، أو تكلفة غير موجبة'),
        ('DPO', CASE WHEN @dpo IS NULL THEN 'NA' ELSE 'OK' END, @dpo, N'الذمم الدائنة أو تكلفة المبيعات غير مدخلة، أو تكلفة غير موجبة'),
        ('CASH_CYCLE', CASE WHEN @dso IS NULL OR @dio IS NULL OR @dpo IS NULL THEN 'NA' ELSE 'OK' END, @dso + @dio - @dpo, N'أيام التحصيل أو المخزون أو السداد لا تُحسب'),
        ('CASH_TO_ST_DEBT', CASE WHEN @CASH IS NULL OR @stDebt IS NULL THEN 'NA' WHEN @stDebt = 0 THEN 'BEST' ELSE 'OK' END, @CASH / NULLIF(@stDebt, 0),
                            CASE WHEN @CASH IS NULL OR @stDebt IS NULL THEN N'النقد أو الدين قصير الأجل غير مدخل' ELSE N'لا دين قصير الأجل' END),
        ('RELATED_TO_TNW', CASE WHEN @tnwTang IS NULL THEN 'NA' WHEN @DUE_FROM_RELATED = 0 THEN 'OK' WHEN @tnwTang <= 0 THEN 'WORST' ELSE 'OK' END,
                           CASE WHEN @DUE_FROM_RELATED = 0 THEN 0 ELSE @DUE_FROM_RELATED / NULLIF(@tnwTang, 0) * 100 END,
                           CASE WHEN @tnwTang IS NULL THEN N'حقوق الملكية أو الأصول غير الملموسة غير مدخلة' ELSE N'حقوق ملكية ملموسة غير موجبة مع مستحقات' END),
        ('INTANGIBLES_TO_EQUITY', CASE WHEN @quasi IS NULL OR @INTANGIBLES IS NULL THEN 'NA' WHEN @INTANGIBLES = 0 THEN 'OK' WHEN @quasi <= 0 THEN 'WORST' ELSE 'OK' END,
                                  CASE WHEN @INTANGIBLES = 0 THEN 0 ELSE @INTANGIBLES / NULLIF(@quasi, 0) * 100 END,
                                  CASE WHEN @quasi IS NULL OR @INTANGIBLES IS NULL THEN N'حقوق الملكية أو الأصول غير الملموسة غير مدخلة' ELSE N'حقوق ملكية غير موجبة' END),
        ('EOSB_TO_TNW', CASE WHEN @adjTnw IS NULL THEN 'NA' WHEN @EOSB = 0 THEN 'OK' WHEN @adjTnw <= 0 THEN 'WORST' ELSE 'OK' END,
                        CASE WHEN @EOSB = 0 THEN 0 ELSE @EOSB / NULLIF(@adjTnw, 0) * 100 END,
                        CASE WHEN @adjTnw IS NULL THEN N'حقوق الملكية غير مدخلة' ELSE N'صافي ثروة ملموسة معدَّلة غير موجب' END),
        ('ZAKAT_DISPUTED_TO_TNW', CASE WHEN @adjTnw IS NULL THEN 'NA' WHEN @ZAKAT_DISPUTED = 0 THEN 'OK' WHEN @adjTnw <= 0 THEN 'WORST' ELSE 'OK' END,
                                  CASE WHEN @ZAKAT_DISPUTED = 0 THEN 0 ELSE @ZAKAT_DISPUTED / NULLIF(@adjTnw, 0) * 100 END,
                                  CASE WHEN @adjTnw IS NULL THEN N'حقوق الملكية غير مدخلة' ELSE N'صافي ثروة ملموسة معدَّلة غير موجب' END),
        ('DUE_TO_RELATED_TO_TNW', CASE WHEN @adjTnw IS NULL THEN 'NA' WHEN @DUE_TO_RELATED = 0 THEN 'OK' WHEN @adjTnw <= 0 THEN 'WORST' ELSE 'OK' END,
                                  CASE WHEN @DUE_TO_RELATED = 0 THEN 0 ELSE @DUE_TO_RELATED / NULLIF(@adjTnw, 0) * 100 END,
                                  CASE WHEN @adjTnw IS NULL THEN N'حقوق الملكية غير مدخلة' ELSE N'صافي ثروة ملموسة معدَّلة غير موجب' END),
        ('GUARANTEES_TO_TNW', CASE WHEN @adjTnw IS NULL THEN 'NA' WHEN @GUARANTEES_GIVEN = 0 THEN 'OK' WHEN @adjTnw <= 0 THEN 'WORST' ELSE 'OK' END,
                              CASE WHEN @GUARANTEES_GIVEN = 0 THEN 0 ELSE @GUARANTEES_GIVEN / NULLIF(@adjTnw, 0) * 100 END,
                              CASE WHEN @adjTnw IS NULL THEN N'حقوق الملكية غير مدخلة' ELSE N'صافي ثروة ملموسة معدَّلة غير موجب' END),
        ('CONTINGENT_TO_TNW', CASE WHEN @adjTnw IS NULL THEN 'NA' WHEN @contingent = 0 THEN 'OK' WHEN @adjTnw <= 0 THEN 'WORST' ELSE 'OK' END,
                              CASE WHEN @contingent = 0 THEN 0 ELSE @contingent / NULLIF(@adjTnw, 0) END,
                              CASE WHEN @adjTnw IS NULL THEN N'حقوق الملكية غير مدخلة' ELSE N'صافي ثروة ملموسة معدَّلة غير موجب مع التزامات محتملة' END),
        ('ST_DEBT_TO_TRADE_ASSETS', CASE WHEN @trade IS NULL OR @ST_LOANS IS NULL THEN 'NA' WHEN @ST_LOANS + @BANK_ACCEPTANCES = 0 THEN 'OK' WHEN @trade <= 0 THEN 'WORST' ELSE 'OK' END,
                                    CASE WHEN @ST_LOANS + @BANK_ACCEPTANCES = 0 THEN 0 ELSE (@ST_LOANS + @BANK_ACCEPTANCES) / NULLIF(@trade, 0) * 100 END,
                                    CASE WHEN @trade IS NULL OR @ST_LOANS IS NULL THEN N'الذمم أو المخزون أو القروض قصيرة الأجل غير مدخلة' ELSE N'لا ذمم ولا مخزون مع خطوط تجارة' END),
        ('OTHER_CA_SHARE', CASE WHEN @OTHER_CA IS NULL OR @TOTAL_CA IS NULL OR @TOTAL_CA <= 0 THEN 'NA' ELSE 'OK' END, @OTHER_CA / NULLIF(@TOTAL_CA, 0) * 100,
                           N'الأصول المتداولة غير مدخلة أو غير موجبة'),
        ('CONTRACT_ASSETS_TO_REVENUE', CASE WHEN @REVENUE IS NULL OR @REVENUE <= 0 THEN 'NA' ELSE 'OK' END, @CONTRACT_ASSETS / NULLIF(@REVENUE, 0) * 100,
                                       N'الإيرادات غير مدخلة أو غير موجبة'),
        ('NWC_TO_ASSETS', CASE WHEN @TOTAL_CA IS NULL OR @TOTAL_CL IS NULL OR @TOTAL_ASSETS IS NULL OR @TOTAL_ASSETS <= 0 THEN 'NA' ELSE 'OK' END,
                          (@TOTAL_CA - @TOTAL_CL) / NULLIF(@TOTAL_ASSETS, 0) * 100, N'إجماليات المتداول أو الأصول غير مدخلة'),
        ('EQUITY_RATIO', CASE WHEN @quasi IS NULL OR @TOTAL_ASSETS IS NULL OR @TOTAL_ASSETS <= 0 THEN 'NA' ELSE 'OK' END,
                         @quasi / NULLIF(@TOTAL_ASSETS, 0) * 100, N'حقوق الملكية أو الأصول غير مدخلة'),
        ('ST_DEBT_SHARE', CASE WHEN @debt IS NULL THEN 'NA' WHEN @debt = 0 THEN 'BEST' ELSE 'OK' END, @stDebt / NULLIF(@debt, 0) * 100,
                          CASE WHEN @debt IS NULL THEN N'بنود الدين غير مدخلة' ELSE N'لا دين' END),
        ('CFO_TO_CPLTD', CASE WHEN @cf = 0 OR @CURRENT_PORTION_LTD IS NULL THEN 'NA' WHEN @CURRENT_PORTION_LTD = 0 THEN 'BEST' ELSE 'OK' END,
                         @cfo / NULLIF(@CURRENT_PORTION_LTD, 0),
                         CASE WHEN @cf = 0 THEN N'لا قائمة تدفقات نقدية' WHEN @CURRENT_PORTION_LTD IS NULL THEN N'الجزء المتداول غير مدخل' ELSE N'لا أقساط مستحقة خلال سنة' END),
        ('ACC_LOSS_TO_CAPITAL', CASE WHEN @RETAINED_EARNINGS IS NULL OR @SHARE_CAPITAL IS NULL THEN 'NA' WHEN @RETAINED_EARNINGS >= 0 THEN 'BEST'
                                     WHEN @SHARE_CAPITAL <= 0 THEN 'NA' ELSE 'OK' END,
                                -@RETAINED_EARNINGS / NULLIF(@SHARE_CAPITAL, 0) * 100,
                                CASE WHEN @RETAINED_EARNINGS IS NULL OR @SHARE_CAPITAL IS NULL THEN N'الأرباح المبقاة أو رأس المال غير مدخل'
                                     WHEN @RETAINED_EARNINGS >= 0 THEN N'لا خسائر متراكمة' ELSE N'رأس مال غير موجب' END),
        ('REVENUE_GROWTH', CASE WHEN @prior IS NULL OR @REVENUE IS NULL OR @P_REVENUE IS NULL OR @P_REVENUE <= 0 THEN 'NA' ELSE 'OK' END,
                           (@REVENUE - @P_REVENUE) / NULLIF(@P_REVENUE, 0) * 100,
                           CASE WHEN @prior IS NULL THEN N'لا قائمة مقارنة' ELSE N'إيرادات المقارنة غير مدخلة أو غير موجبة' END),
        ('GROSS_MARGIN_CHANGE', CASE WHEN @prior IS NULL OR @GROSS_PROFIT IS NULL OR @P_GROSS_PROFIT IS NULL OR @REVENUE IS NULL OR @P_REVENUE IS NULL
                                          OR @REVENUE <= 0 OR @P_REVENUE <= 0 THEN 'NA' ELSE 'OK' END,
                                @GROSS_PROFIT / NULLIF(@REVENUE, 0) * 100 - @P_GROSS_PROFIT / NULLIF(@P_REVENUE, 0) * 100,
                                CASE WHEN @prior IS NULL THEN N'لا قائمة مقارنة' ELSE N'بنود المقارنة غير مدخلة أو إيرادات غير موجبة' END),
        ('CFO_TO_EBITDA', CASE WHEN @cf = 0 OR @ebitda IS NULL THEN 'NA' WHEN @ebitda <= 0 AND @cfo < 0 THEN 'WORST' WHEN @ebitda <= 0 THEN 'NA' ELSE 'OK' END,
                          @cfo / NULLIF(@ebitda, 0) * 100,
                          CASE WHEN @cf = 0 THEN N'لا قائمة تدفقات نقدية' WHEN @ebitda IS NULL THEN N'الربح التشغيلي غير مدخل'
                               WHEN @cfo < 0 THEN N'تدفق تشغيلي سالب وEBITDA غير موجب' ELSE N'EBITDA غير موجب' END),
        ('PAYOUT_RATIO', CASE WHEN @NET_PROFIT IS NULL THEN 'NA' WHEN @DIVIDENDS = 0 AND @NET_PROFIT > 0 THEN 'BEST' WHEN @DIVIDENDS = 0 THEN 'NA'
                              WHEN @NET_PROFIT <= 0 THEN 'WORST' ELSE 'OK' END,
                         @DIVIDENDS / NULLIF(@NET_PROFIT, 0) * 100,
                         CASE WHEN @NET_PROFIT IS NULL THEN N'صافي الربح غير مدخل' WHEN @DIVIDENDS = 0 AND @NET_PROFIT > 0 THEN N'لا توزيعات'
                              WHEN @DIVIDENDS = 0 THEN N'لا ربح ولا توزيعات' ELSE N'توزيعات مع ربح غير موجب' END)
    ) AS v (Code, State, Value, Reason);

    -- The factors: each scorecard metric scored on its grid, or graded by the analyst (docs/35 section 3).
    DECLARE @f TABLE (MetricId INT PRIMARY KEY, Code VARCHAR(40) COLLATE DATABASE_DEFAULT, Kind VARCHAR(12), FactorCode VARCHAR(30) COLLATE DATABASE_DEFAULT,
                      Weight DECIMAL(5,2), Status VARCHAR(14), Value FLOAT, Score DECIMAL(9,4), Reason NVARCHAR(300), SortOrder INT, HasDocument BIT);
    INSERT @f (MetricId, Code, Kind, FactorCode, Weight, Status, Value, Score, Reason, SortOrder, HasDocument)
    SELECT sm.MetricId, cm.Code, cm.Kind, sm.FactorCode, sm.Weight,
           CASE WHEN cm.Kind = 'QUALITATIVE' THEN CASE WHEN qi.GradeId IS NULL THEN 'NOT_COMPUTABLE' ELSE 'ANALYST' END
                WHEN m.State = 'OK' THEN 'COMPUTED' WHEN m.State IN ('BEST','WORST') THEN 'EXTREME' ELSE 'NOT_COMPUTABLE' END,
           CASE WHEN cm.Kind = 'QUANTITATIVE' AND m.State = 'OK' THEN m.Value END,
           CASE WHEN cm.Kind = 'QUALITATIVE' THEN CAST((qg.ScoreFrom + qg.ScoreTo) / 2 AS DECIMAL(9,4))
                WHEN m.State = 'BEST' THEN 0.5 WHEN m.State = 'WORST' THEN 20.5 WHEN m.State = 'OK' THEN gs.Score END,
           CASE WHEN cm.Kind = 'QUALITATIVE' THEN CASE WHEN qi.GradeId IS NULL THEN N'لم يُدخل المحلل درجة العامل' END ELSE m.Reason END,
           sm.SortOrder, CASE WHEN qi.DocumentId IS NOT NULL THEN 1 ELSE 0 END
    FROM fin.ScorecardMetric AS sm
    JOIN fin.CreditMetric AS cm ON cm.CreditMetricId = sm.MetricId
    LEFT JOIN @m AS m ON m.Code = cm.Code
    LEFT JOIN fin.CreditAssessmentInput AS qi ON qi.TenantId = @tenant AND qi.AssessmentId = @AssessmentId AND qi.Kind = 'QUALITATIVE' AND qi.MetricId = sm.MetricId
    LEFT JOIN fin.RatingGrade AS qg ON qg.RatingGradeId = qi.GradeId
    OUTER APPLY fin.fn_CreditGridScore(m.Value, sm.B0, sm.B1, sm.B2, sm.B3, sm.B4, sm.B5, sm.B6, sm.B7, sm.B8) AS gs
    WHERE sm.ScorecardId = @card;

    -- Coverage on the quantitative weight; the financial grade on the quantitative metrics alone; no final grade without
    -- both qualitative grades, each within the bound of the financial grade unless a document supports it (BR-FIN-019,
    -- BR-FIN-021).
    DECLARE @wQuant DECIMAL(9,4) = (SELECT SUM(Weight) FROM @f WHERE Kind = 'QUANTITATIVE'),
            @wQuantScored DECIMAL(9,4) = (SELECT SUM(Weight) FROM @f WHERE Kind = 'QUANTITATIVE' AND Score IS NOT NULL),
            @wScored DECIMAL(9,4) = (SELECT SUM(Weight) FROM @f WHERE Score IS NOT NULL);
    DECLARE @coverage DECIMAL(5,2) = CAST(ROUND(ISNULL(@wQuantScored, 0) * 100 / @wQuant, 2) AS DECIMAL(5,2));
    DECLARE @finScore DECIMAL(9,4) = CASE WHEN @coverage >= @minCov THEN CAST((SELECT SUM(Weight * Score) FROM @f WHERE Kind = 'QUANTITATIVE' AND Score IS NOT NULL) / @wQuantScored AS DECIMAL(9,4)) END;
    DECLARE @finNotch INT = CASE WHEN @finScore IS NOT NULL THEN CASE WHEN FLOOR(@finScore - 0.5) + 1 > 20 THEN 20 WHEN FLOOR(@finScore - 0.5) + 1 < 1 THEN 1 ELSE FLOOR(@finScore - 0.5) + 1 END END;
    DECLARE @state VARCHAR(17) = CASE WHEN @finScore IS NULL THEN 'INSUFFICIENT_DATA'
                                      WHEN EXISTS (SELECT 1 FROM @f WHERE Kind = 'QUALITATIVE' AND Score IS NULL) THEN 'INDICATIVE' ELSE 'RATED' END;
    IF @state = 'RATED' AND EXISTS (SELECT 1 FROM @f WHERE Kind = 'QUALITATIVE' AND HasDocument = 0
                                     AND ABS(CASE WHEN FLOOR(Score - 0.5) + 1 > 20 THEN 20 ELSE FLOOR(Score - 0.5) + 1 END - @finNotch) > @qualBound)
        THROW 50065, 'A qualitative grade more than the scorecard''s bound from the financial grade needs a supporting document (BR-FIN-021)', 1;
    DECLARE @rated BIT = CASE WHEN @state = 'RATED' THEN 1 ELSE 0 END;
    DECLARE @agg DECIMAL(9,4) = CASE WHEN @rated = 1 THEN CAST((SELECT SUM(Weight * Score) FROM @f WHERE Score IS NOT NULL) / @wScored AS DECIMAL(9,4)) END;
    DECLARE @n0 INT = CASE WHEN @rated = 1 THEN CASE WHEN FLOOR(@agg - 0.5) + 1 > 20 THEN 20 WHEN FLOOR(@agg - 0.5) + 1 < 1 THEN 1 ELSE FLOOR(@agg - 0.5) + 1 END END;

    -- The adjustments that apply (docs/35 section 7).
    DECLARE @restated FLOAT = CASE WHEN @versionReason = 'RESTATED' AND @supersedes IS NOT NULL THEN
            (SELECT MAX(x) FROM (VALUES (CASE WHEN @O_NET_PROFIT = 0 THEN CASE WHEN @NET_PROFIT / @k <> 0 THEN 100 ELSE 0 END ELSE ABS(@NET_PROFIT / @k - @O_NET_PROFIT) * 100 / ABS(@O_NET_PROFIT) END),
                                        (CASE WHEN @O_TOTAL_EQUITY = 0 THEN CASE WHEN @TOTAL_EQUITY <> 0 THEN 100 ELSE 0 END ELSE ABS(@TOTAL_EQUITY - @O_TOTAL_EQUITY) * 100 / ABS(@O_TOTAL_EQUITY) END)) AS v (x)) END;
    DECLARE @accLoss FLOAT = (SELECT Value FROM @m WHERE Code = 'ACC_LOSS_TO_CAPITAL' AND State = 'OK'),
            @revSize FLOAT = (SELECT Value FROM @m WHERE Code = 'REVENUE_SIZE' AND State = 'OK'),
            @revWorst BIT = CASE WHEN EXISTS (SELECT 1 FROM @m WHERE Code = 'REVENUE_SIZE' AND State = 'WORST') THEN 1 ELSE 0 END;
    DECLARE @breaches TABLE (Waiver BIT NOT NULL);
    INSERT @breaches (Waiver)
    SELECT CASE WHEN b.WaiverRef IS NOT NULL THEN 1 ELSE 0 END
    FROM obl.ObligationBreach AS b
    JOIN obl.Obligation AS o ON o.TenantId = b.TenantId AND o.ObligationId = b.ObligationId
    LEFT JOIN fac.Facility AS fa ON fa.TenantId = o.TenantId AND fa.FacilityId = o.FacilityId
    WHERE b.TenantId = @tenant AND b.Status IN ('OPEN','IN_CURE') AND b.Kind IN ('COVENANT_BREACH','RESTRICTION_VIOLATION') AND b.DetectedOn <= @asOf
      AND (fa.BorrowerCompanyId = @company
           OR EXISTS (SELECT 1 FROM obl.Covenant AS c WHERE c.TenantId = b.TenantId AND c.RootId = b.CovenantRootId AND c.TestedCompanyId = @company)
           OR EXISTS (SELECT 1 FROM obl.ObligationCompany AS oc WHERE oc.TenantId = o.TenantId AND oc.ObligationId = o.ObligationId AND oc.CompanyId = @company));
    DECLARE @flows TABLE (CovenantId BIGINT, PerformanceState VARCHAR(10), Achieved FLOAT, Required FLOAT, MonthsElapsed INT, MonthsInWindow INT, AchievementPct FLOAT);
    INSERT @flows SELECT p.CovenantId, p.PerformanceState, p.Achieved, p.Required, p.MonthsElapsed, p.MonthsInWindow, p.AchievementPct
                  FROM fin.fn_BankFlowPerformance(@asOf) AS p WHERE p.TenantId = @tenant AND p.CompanyId = @company;

    DECLARE @adj TABLE (RuleCode VARCHAR(23) COLLATE DATABASE_DEFAULT PRIMARY KEY, Stage VARCHAR(10), Notches INT, CapNotch INT, ParamValue FLOAT,
                        ShowWhen VARCHAR(12), TextAr NVARCHAR(500), TextEn NVARCHAR(500));
    INSERT @adj (RuleCode, Stage, Notches, CapNotch, ParamValue, ShowWhen, TextAr, TextEn)
    SELECT a.RuleCode, a.Stage, a.Notches, g.NotchNo, a.ParamValue, a.ShowWhen, a.TextAr, a.TextEn
    FROM fin.ScorecardAdjustment AS a
    LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = a.CapGradeId
    WHERE a.ScorecardId = @card AND a.IsActive = 1 AND @rated = 1
      AND CASE a.RuleCode
            WHEN 'AUDIT_QUALIFIED'         THEN CASE WHEN @assurance = 'AUDITED' AND @opinion = 'QUALIFIED' THEN 1 ELSE 0 END
            WHEN 'UNAUDITED_ANNUAL'        THEN CASE WHEN @assurance = 'MANAGEMENT' AND @pt = 'ANNUAL' THEN 1 ELSE 0 END
            WHEN 'STALE_STATEMENT'         THEN CASE WHEN DATEDIFF(MONTH, @pe, @asOf) > a.ParamValue THEN 1 ELSE 0 END
            WHEN 'INCOMPLETE_STATEMENT'    THEN CASE WHEN @cf = 0 THEN 1 ELSE 0 END
            WHEN 'RESTATEMENT'             THEN CASE WHEN @restated > a.ParamValue THEN 1 ELSE 0 END
            WHEN 'HALF_CAPITAL_LOST'       THEN CASE WHEN @accLoss >= a.ParamValue AND @quasi < @SHARE_CAPITAL THEN 1 ELSE 0 END
            WHEN 'HALF_CAPITAL_LOST_CURED' THEN CASE WHEN @accLoss >= a.ParamValue AND @quasi >= @SHARE_CAPITAL THEN 1 ELSE 0 END
            WHEN 'RELATED_PARTY_EXPOSURE'  THEN CASE WHEN @adjTnw IS NOT NULL AND @DUE_FROM_RELATED + @GUARANTEES_GIVEN > 0
                                                          AND (@adjTnw <= 0 OR @DUE_FROM_RELATED + @GUARANTEES_GIVEN > a.ParamValue / 100 * @adjTnw) THEN 1 ELSE 0 END
            WHEN 'HOLDCO_STANDALONE'       THEN CASE WHEN @isHolding = 1 AND @basis = 'STANDALONE' THEN 1 ELSE 0 END
            WHEN 'OPEN_BREACH'             THEN CASE WHEN EXISTS (SELECT 1 FROM @breaches WHERE Waiver = 0) THEN 1 ELSE 0 END
            WHEN 'BREACH_WAIVER_REQUESTED' THEN CASE WHEN EXISTS (SELECT 1 FROM @breaches WHERE Waiver = 1) AND NOT EXISTS (SELECT 1 FROM @breaches WHERE Waiver = 0) THEN 1 ELSE 0 END
            WHEN 'FLOW_SHORTFALL'          THEN CASE WHEN EXISTS (SELECT 1 FROM @flows WHERE PerformanceState = 'BEHIND' AND Required > 0 AND MonthsInWindow > 0
                                                                    AND Achieved < (1 - a.ParamValue / 100) * Required * MonthsElapsed / MonthsInWindow) THEN 1 ELSE 0 END
            WHEN 'GOING_CONCERN'           THEN CASE WHEN @goingConcern = 1 THEN 1 ELSE 0 END
            WHEN 'NEGATIVE_EQUITY'         THEN CASE WHEN @quasi <= 0 THEN 1 ELSE 0 END
            WHEN 'SIZE_CEILING'            THEN CASE WHEN @revSize < a.ParamValue OR @revWorst = 1 THEN 1 ELSE 0 END
            WHEN 'SECTOR_CEILING'          THEN 1
            WHEN 'AUDIT_ADVERSE'           THEN CASE WHEN @assurance = 'AUDITED' AND @opinion IN ('ADVERSE','DISCLAIMER') THEN 1 ELSE 0 END
            WHEN 'SOVEREIGN_CEILING'       THEN 1
          END = 1;

    -- Group support and the override (BR-FIN-022): notches, then the standalone caps give the standalone grade;
    -- support lifts it, never above the parent's grade and never lowers it; then the override; then the absolute caps.
    DECLARE @support INT, @parentNotch INT, @parentDate DATE, @override INT;
    SELECT @support = i.Notches, @parentNotch = pg.NotchNo, @parentDate = p.AssessmentDate
    FROM fin.CreditAssessmentInput AS i
    JOIN fin.CreditAssessment AS p ON p.TenantId = i.TenantId AND p.CreditAssessmentId = i.ParentAssessmentId
    JOIN fin.RatingGrade AS pg ON pg.RatingGradeId = p.FinalGradeId
    WHERE i.TenantId = @tenant AND i.AssessmentId = @AssessmentId AND i.Kind = 'GROUP_SUPPORT' AND p.Status = 'APPROVED';
    IF @support IS NOT NULL AND (@parentDate > @asOf OR DATEDIFF(MONTH, @parentDate, @asOf) > @supportAge)
        THROW 50065, 'Group support reads a parent assessment of the twelve months before the assessment date (BR-FIN-022)', 1;
    SELECT @override = Notches FROM fin.CreditAssessmentInput WHERE TenantId = @tenant AND AssessmentId = @AssessmentId AND Kind = 'OVERRIDE';
    DECLARE @notches INT = ISNULL((SELECT SUM(Notches) FROM @adj WHERE Stage = 'NOTCH'), 0),
            @capS INT = ISNULL((SELECT MAX(CapNotch) FROM @adj WHERE Stage = 'STANDALONE'), 1),
            @capA INT = ISNULL((SELECT MAX(CapNotch) FROM @adj WHERE Stage = 'ABSOLUTE'), 1);
    DECLARE @n1 INT = @n0 - @notches;                                       -- a notch down adds one
    DECLARE @n2 INT = CASE WHEN @n1 < @capS THEN @capS ELSE @n1 END;         -- the standalone grade
    DECLARE @n3 INT = CASE WHEN @support IS NULL THEN @n2
                           ELSE CASE WHEN @n2 < CASE WHEN @n2 - @support > @parentNotch THEN @n2 - @support ELSE @parentNotch END THEN @n2
                                     ELSE CASE WHEN @n2 - @support > @parentNotch THEN @n2 - @support ELSE @parentNotch END END END;
    DECLARE @n4 INT = @n3 - ISNULL(@override, 0);
    DECLARE @n5 INT = CASE WHEN @n4 < @capA THEN @capA ELSE @n4 END;
    DECLARE @final INT = CASE WHEN @n5 > 20 THEN 20 WHEN @n5 < 1 THEN 1 ELSE @n5 END,
            @standalone INT = CASE WHEN @n2 > 20 THEN 20 ELSE @n2 END,
            @capAll INT = CASE WHEN @capA > @capS THEN @capA ELSE @capS END;

    -- The findings, in the order of the report (docs/35 section 8).
    DECLARE @x TABLE (Ord INT IDENTITY(1,1) PRIMARY KEY, Kind VARCHAR(13), Source VARCHAR(10), RuleCode VARCHAR(40) COLLATE DATABASE_DEFAULT,
                      LineCode VARCHAR(40) COLLATE DATABASE_DEFAULT, RiskLevel VARCHAR(8), Value FLOAT, PriorValue FLOAT, Notches INT, RefId BIGINT,
                      TextAr NVARCHAR(1000), TextEn NVARCHAR(1000));
    -- the scorecard: A or better is a strength, B or worse a weakness
    INSERT @x (Kind, Source, RuleCode, Value, TextAr, TextEn)
    SELECT CASE WHEN f.Score <= 7.5 THEN 'STRENGTH' ELSE 'WEAKNESS' END, 'SCORECARD', f.Code, f.Value,
           CASE WHEN f.Status = 'EXTREME' THEN CONCAT(cm.NameAr, N': ', f.Reason, N' (', g.Code, N')')
                ELSE REPLACE(REPLACE(CASE WHEN f.Score <= 7.5 THEN cm.StrengthTextAr ELSE cm.WeaknessTextAr END, N'{v}', ISNULL(fv.Txt, N'')), N'{g}', g.Code) END,
           CASE WHEN f.Status = 'EXTREME' THEN CONCAT(cm.NameEn, N': ', g.Code)
                ELSE REPLACE(REPLACE(CASE WHEN f.Score <= 7.5 THEN cm.StrengthTextEn ELSE cm.WeaknessTextEn END, N'{v}', ISNULL(fv.Txt, N'')), N'{g}', g.Code) END
    FROM @f AS f
    JOIN fin.CreditMetric AS cm ON cm.CreditMetricId = f.MetricId
    JOIN fin.RatingGrade AS g ON g.NotchNo = CASE WHEN FLOOR(f.Score - 0.5) + 1 > 20 THEN 20 ELSE FLOOR(f.Score - 0.5) + 1 END
    OUTER APPLY (SELECT FORMAT(f.Value, CASE WHEN cm.Unit IN ('DAYS','AMOUNT') THEN 'N0' ELSE 'N2' END, 'en-US') AS Txt) AS fv
    WHERE f.Score IS NOT NULL AND (f.Score <= 7.5 OR f.Score > 13.5)
    ORDER BY CASE WHEN f.Score <= 7.5 THEN 0 ELSE 1 END, f.SortOrder;
    -- the balance sheet items
    INSERT @x (Kind, Source, RuleCode, LineCode, RiskLevel, Value, TextAr, TextEn)
    SELECT CASE WHEN lv.Lvl IS NULL THEN 'INFO' WHEN lv.Lvl = 'LOW' AND r.ReportStrength = 1 THEN 'STRENGTH' WHEN lv.Lvl IN ('LOW','MODERATE') THEN 'INFO'
                WHEN lv.Lvl = 'ELEVATED' THEN 'WATCH' WHEN lv.Lvl = 'HIGH' THEN 'WEAKNESS' ELSE 'CRITICAL_RISK' END,
           'ITEM_RULE', cm.Code, r.LineCode, lv.Lvl, m.Value,
           CASE WHEN lv.Lvl IS NULL THEN CONCAT(cm.NameAr, N': لم يُقيَّم (', m.Reason, N')')
                WHEN m.State IN ('BEST','WORST') THEN CONCAT(cm.NameAr, N': ', m.Reason)
                ELSE REPLACE(REPLACE(CASE WHEN lv.Lvl = 'LOW' THEN cm.StrengthTextAr ELSE cm.WeaknessTextAr END, N' ({g})', N''), N'{v}', ISNULL(fv.Txt, N'')) END,
           CASE WHEN lv.Lvl IS NULL THEN CONCAT(cm.NameEn, N': not assessed')
                WHEN m.State IN ('BEST','WORST') THEN cm.NameEn
                ELSE REPLACE(REPLACE(CASE WHEN lv.Lvl = 'LOW' THEN cm.StrengthTextEn ELSE cm.WeaknessTextEn END, N' ({g})', N''), N'{v}', ISNULL(fv.Txt, N'')) END
    FROM fin.ScorecardItemRule AS r
    JOIN fin.CreditMetric AS cm ON cm.CreditMetricId = r.MetricId
    JOIN @m AS m ON m.Code = cm.Code
    OUTER APPLY fin.fn_CreditItemLevel(m.Value, r.T1, r.T2, r.T3, r.T4) AS il
    OUTER APPLY (SELECT CASE m.State WHEN 'BEST' THEN 'LOW' WHEN 'WORST' THEN 'CRITICAL' WHEN 'OK' THEN il.RiskLevel END AS Lvl) AS lv
    OUTER APPLY (SELECT FORMAT(m.Value, CASE WHEN cm.Unit IN ('DAYS','AMOUNT') THEN 'N0' ELSE 'N2' END, 'en-US') AS Txt) AS fv
    WHERE r.ScorecardId = @card
    ORDER BY CASE lv.Lvl WHEN 'CRITICAL' THEN 0 WHEN 'HIGH' THEN 1 WHEN 'ELEVATED' THEN 2 WHEN 'LOW' THEN 3 WHEN 'MODERATE' THEN 4 ELSE 5 END, r.SortOrder;
    -- the covenants tested on this statement: their latest evaluation (FR-FIN-022)
    INSERT @x (Kind, Source, RuleCode, Value, RefId, TextAr, TextEn)
    SELECT CASE WHEN t.Result = 'BREACH' THEN 'CRITICAL_RISK' WHEN t.Result = 'WARNING' THEN 'WATCH'
                WHEN t.HeadroomPct IS NOT NULL AND t.HeadroomPct < 10 THEN 'WATCH' WHEN t.HeadroomPct >= 25 THEN 'STRENGTH' ELSE 'INFO' END,
           'COVENANT', CONCAT('COVENANT_', t.Result), t.ActualValue, t.CovenantTestId,
           CONCAT(N'تعهد ', ISNULL(mf.NameAr, c.MeasureKind), N' (', o.ClauseRef, N'): ',
                  CASE t.Result WHEN 'BREACH' THEN N'خرق' WHEN 'WARNING' THEN N'إنذار مبكر' ELSE N'ملتزم' END,
                  N'؛ الفعلي ', FORMAT(t.ActualValue, 'N2', 'en-US'), N' والحد ', op.Sym, N' ', FORMAT(t.ThresholdApplied, 'N2', 'en-US'),
                  CASE WHEN t.HeadroomPct IS NOT NULL THEN CONCAT(N'، والهامش ', FORMAT(t.HeadroomPct, 'N1', 'en-US'), N'%') END),
           CONCAT(N'Covenant ', ISNULL(mf.NameEn, c.MeasureKind), N': ', t.Result, N', actual ', FORMAT(t.ActualValue, 'N2', 'en-US'),
                  N' against ', op.Sym, N' ', FORMAT(t.ThresholdApplied, 'N2', 'en-US'))
    FROM (SELECT x.*, ROW_NUMBER() OVER (PARTITION BY x.CovenantRootId, x.PeriodEnd ORDER BY x.EvaluationNo DESC) AS rn
          FROM obl.CovenantTest AS x
          JOIN obl.CovenantTestStatement AS ts ON ts.TenantId = x.TenantId AND ts.CovenantTestId = x.CovenantTestId
          WHERE ts.TenantId = @tenant AND ts.StatementId = @stmt AND x.State IN ('EVALUATED','REVIEWED')) AS t
    JOIN obl.Covenant AS c ON c.TenantId = t.TenantId AND c.CovenantId = t.CovenantId
    JOIN obl.Obligation AS o ON o.TenantId = c.TenantId AND o.ObligationId = c.ObligationId
    LEFT JOIN fin.MeasureFormula AS mf ON mf.TenantId = t.TenantId AND mf.MeasureFormulaId = t.FormulaId
    CROSS APPLY (SELECT CASE t.OperatorApplied WHEN 'GE' THEN N'≥' WHEN 'LE' THEN N'≤' WHEN 'GT' THEN N'>' WHEN 'LT' THEN N'<' ELSE N'=' END AS Sym) AS op
    WHERE t.rn = 1 AND t.Result IN ('COMPLIANT','WARNING','BREACH')
    ORDER BY CASE t.Result WHEN 'BREACH' THEN 0 WHEN 'WARNING' THEN 1 ELSE 2 END, t.CovenantTestId;
    -- the liquidity routed to the bank on the assessment date (FR-FIN-018)
    INSERT @x (Kind, Source, RuleCode, Value, RefId, TextAr, TextEn)
    SELECT CASE p.PerformanceState WHEN 'BEHIND' THEN 'WATCH' WHEN 'MET' THEN 'STRENGTH' ELSE 'INFO' END,
           'BANK_FLOW', CONCAT('FLOW_', p.PerformanceState), p.AchievementPct, p.CovenantId,
           CONCAT(N'تحويل السيولة إلى البنك: ', CASE p.PerformanceState WHEN 'BEHIND' THEN N'متأخر' WHEN 'MET' THEN N'مستوفى' WHEN 'ON_TRACK' THEN N'على المسار'
                                                        WHEN 'NO_DATA' THEN N'بلا تحويلات مؤكدة' ELSE N'بلا إيراد يُقاس عليه' END,
                  N'؛ المؤكَّد ', FORMAT(p.Achieved, 'N0', 'en-US'), N' من ', FORMAT(p.Required, 'N0', 'en-US'),
                  CASE WHEN p.AchievementPct IS NOT NULL THEN CONCAT(N' (', FORMAT(p.AchievementPct, 'N1', 'en-US'), N'%)') END,
                  N' حتى ', CONVERT(CHAR(10), @asOf, 23)),
           CONCAT(N'Liquidity routed to the bank: ', p.PerformanceState, N', confirmed ', FORMAT(p.Achieved, 'N0', 'en-US'), N' of ', FORMAT(p.Required, 'N0', 'en-US'))
    FROM @flows AS p
    ORDER BY CASE p.PerformanceState WHEN 'BEHIND' THEN 0 ELSE 1 END, p.CovenantId;
    -- the adjustments: each notch, each cap the scorecard always reports, and each other cap that binds
    INSERT @x (Kind, Source, RuleCode, Notches, TextAr, TextEn)
    SELECT 'ADJUSTMENT', 'ADJUSTMENT', a.RuleCode, a.Notches,
           REPLACE(a.TextAr, N'{p}', ISNULL(FORMAT(a.ParamValue, 'G', 'en-US'), N'')), REPLACE(a.TextEn, N'{p}', ISNULL(FORMAT(a.ParamValue, 'G', 'en-US'), N''))
    FROM @adj AS a
    WHERE a.Stage = 'NOTCH' OR a.ShowWhen = 'ALWAYS'
       OR (a.Stage = 'STANDALONE' AND @n1 < a.CapNotch) OR (a.Stage = 'ABSOLUTE' AND @n4 < a.CapNotch)
    ORDER BY CASE a.Stage WHEN 'NOTCH' THEN 0 WHEN 'STANDALONE' THEN 1 ELSE 2 END, a.RuleCode;
    INSERT @x (Kind, Source, RuleCode, Notches, TextAr, TextEn)
    SELECT 'ADJUSTMENT', 'ANALYST', i.Kind, CASE WHEN i.Kind = 'OVERRIDE' THEN i.Notches ELSE @n2 - @n3 END,
           CONCAT(CASE i.Kind WHEN 'GROUP_SUPPORT' THEN N'دعم المجموعة: ' ELSE N'تجاوز المحلل: ' END, i.Justification),
           CONCAT(CASE i.Kind WHEN 'GROUP_SUPPORT' THEN N'Group support: ' ELSE N'Analyst override: ' END, i.Justification)
    FROM fin.CreditAssessmentInput AS i
    WHERE @rated = 1 AND i.TenantId = @tenant AND i.AssessmentId = @AssessmentId AND i.Kind IN ('GROUP_SUPPORT','OVERRIDE')
    ORDER BY i.Kind;

    -- The summary, in both languages.
    DECLARE @ig VARCHAR(4) = (SELECT Code FROM fin.RatingGrade WHERE NotchNo = @n0),
            @sg VARCHAR(4) = (SELECT Code FROM fin.RatingGrade WHERE NotchNo = @standalone),
            @fg VARCHAR(4) = (SELECT Code FROM fin.RatingGrade WHERE NotchNo = @final),
            @fing VARCHAR(4) = (SELECT Code FROM fin.RatingGrade WHERE NotchNo = @finNotch),
            @band VARCHAR(11) = (SELECT RiskBand FROM fin.RatingGrade WHERE NotchNo = @final);
    DECLARE @cS INT = (SELECT COUNT(*) FROM @x WHERE Kind = 'STRENGTH'), @cW INT = (SELECT COUNT(*) FROM @x WHERE Kind = 'WATCH'),
            @cK INT = (SELECT COUNT(*) FROM @x WHERE Kind = 'WEAKNESS'), @cR INT = (SELECT COUNT(*) FROM @x WHERE Kind = 'CRITICAL_RISK');
    DECLARE @sumAr NVARCHAR(1000) = CASE
            WHEN @state = 'RATED' THEN
            CONCAT(N'الدرجة النهائية ', @fg, N' (مخاطر ', CASE @band WHEN 'LOW' THEN N'منخفضة' WHEN 'MODERATE' THEN N'معتدلة' WHEN 'SUBSTANTIAL' THEN N'جوهرية'
                   WHEN 'HIGH' THEN N'مرتفعة' ELSE N'مرتفعة جدًا' END, N')؛ المؤشرة ', @ig, N' بمجموع ', FORMAT(@agg, 'N2', 'en-US'), N'، والمنفردة ', @sg,
                   N'، والمالية وحدها ', @fing, N'؛ تغطية المقاييس الكمية ', FORMAT(@coverage, 'N0', 'en-US'), N'%. نقاط القوة ', @cS, N'، ونقاط المراقبة ', @cW,
                   N'، ونقاط الضعف ', @cK, N'، والمخاطر الحرجة ', @cR, N'.')
            WHEN @state = 'INDICATIVE' THEN
            CONCAT(N'درجة مالية استرشادية ', @fing, N' بمجموع ', FORMAT(@finScore, 'N2', 'en-US'), N'، ولا درجة نهائية قبل أن يُدخل المحلل العوامل النوعية.')
            ELSE CONCAT(N'لا درجة: المقاييس الكمية ذات الدرجة تغطي ', FORMAT(@coverage, 'N0', 'en-US'), N'% من أوزانها، والحد الأدنى ', FORMAT(@minCov, 'N0', 'en-US'), N'%.') END;
    DECLARE @sumEn NVARCHAR(1000) = CASE
            WHEN @state = 'RATED' THEN
            CONCAT(N'Final grade ', @fg, N' (', LOWER(REPLACE(@band, '_', ' ')), N' risk); indicated ', @ig, N' at ', FORMAT(@agg, 'N2', 'en-US'), N', standalone ', @sg,
                   N', financial only ', @fing, N'; quantitative coverage ', FORMAT(@coverage, 'N0', 'en-US'), N'%. ', @cS, N' strengths, ', @cW, N' points to watch, ',
                   @cK, N' weaknesses, ', @cR, N' critical risks.')
            WHEN @state = 'INDICATIVE' THEN
            CONCAT(N'Indicative financial grade ', @fing, N' at ', FORMAT(@finScore, 'N2', 'en-US'), N'; no final grade until the analyst grades the qualitative factors.')
            ELSE CONCAT(N'Not rated: the scored quantitative metrics cover ', FORMAT(@coverage, 'N0', 'en-US'), N'% of their weights, below the minimum of ', FORMAT(@minCov, 'N0', 'en-US'), N'%.') END;

    DECLARE @snapshot NVARCHAR(MAX) = (
        SELECT @cardCode AS scorecard, @cardVer AS scorecardVersion, @stmt AS statementId, @prior AS priorStatementId, @pt AS periodType,
               @k AS annualisationFactor, @fx AS fxRate, CAST(@cf AS BIT) AS cashFlowStatement, @ebitda AS ebitda, @debt AS debt, @adjTnw AS adjustedTnw,
               (SELECT l.Code AS code, l.Amount AS amount FROM @L AS l WHERE l.Which = 'C' ORDER BY l.Code FOR JSON PATH) AS lines,
               (SELECT l.Code AS code, l.Amount AS amount FROM @L AS l WHERE l.Which = 'P' AND l.Code IN ('REVENUE','GROSS_PROFIT','TOTAL_ASSETS','CURRENT_PORTION_LTD','OP_CASH_FLOW')
                ORDER BY l.Code FOR JSON PATH) AS priorLines
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- The results replace those of an earlier computation of the draft.
    DELETE fin.CreditAssessmentFinding WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    DELETE fin.CreditAssessmentFactor WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    INSERT fin.CreditAssessmentFactor (TenantId, AssessmentId, MetricId, FactorCode, Weight, EffectiveWeight, Status, Value, Score, GradeId, Contribution, Reason, CreatedBy)
    SELECT @tenant, @AssessmentId, f.MetricId, f.FactorCode, f.Weight,
           CASE WHEN f.Score IS NOT NULL AND @rated = 1 THEN CAST(f.Weight * 100 / @wScored AS DECIMAL(9,4))
                WHEN f.Score IS NOT NULL AND f.Kind = 'QUANTITATIVE' AND @wQuantScored > 0 THEN CAST(f.Weight * 100 / @wQuantScored AS DECIMAL(9,4)) END,
           f.Status, CAST(f.Value AS DECIMAL(19,6)), f.Score, g.RatingGradeId,
           CASE WHEN f.Score IS NOT NULL AND @rated = 1 THEN CAST(f.Weight * f.Score / @wScored AS DECIMAL(9,4))
                WHEN f.Score IS NOT NULL AND f.Kind = 'QUANTITATIVE' AND @wQuantScored > 0 THEN CAST(f.Weight * f.Score / @wQuantScored AS DECIMAL(9,4)) END,
           f.Reason, @user
    FROM @f AS f
    LEFT JOIN fin.RatingGrade AS g ON f.Score IS NOT NULL AND g.NotchNo = CASE WHEN FLOOR(f.Score - 0.5) + 1 > 20 THEN 20 ELSE FLOOR(f.Score - 0.5) + 1 END;
    INSERT fin.CreditAssessmentFinding (TenantId, AssessmentId, SeqNo, Kind, Source, RuleCode, LineCode, RiskLevel, Value, PriorValue, Notches, RefId, TextAr, TextEn, CreatedBy)
    SELECT @tenant, @AssessmentId, x.Ord, x.Kind, x.Source, x.RuleCode, x.LineCode, x.RiskLevel, CAST(x.Value AS DECIMAL(19,6)), CAST(x.PriorValue AS DECIMAL(19,6)),
           x.Notches, x.RefId, x.TextAr, x.TextEn, @user
    FROM @x AS x;
    UPDATE a
       SET ComputedAt = SYSUTCDATETIME(), InputsHash = h.InputsHash, UsedPriorStatementId = @prior, ResultState = @state, CoveragePct = @coverage,
           FinancialScore = @finScore, FinancialGradeId = (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = @finNotch),
           WeightedScore = @agg, IndicatedGradeId = (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = @n0),
           AdjustmentNotches = CASE WHEN @rated = 1 THEN @notches END,
           CapGradeId = CASE WHEN @rated = 1 AND @capAll > 1 THEN (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = @capAll) END,
           StandaloneGradeId = CASE WHEN @rated = 1 THEN (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = @standalone) END,
           SupportNotches = CASE WHEN @rated = 1 AND @support IS NOT NULL THEN @n2 - @n3 END,
           OverrideNotches = CASE WHEN @rated = 1 THEN @override END,
           FinalGradeId = CASE WHEN @rated = 1 THEN (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = @final) END,
           SummaryAr = @sumAr, SummaryEn = @sumEn, Snapshot = @snapshot, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @user
    FROM fin.CreditAssessment AS a
    CROSS APPLY fin.fn_CreditAssessmentInputsHash(a.TenantId, a.CreditAssessmentId) AS h
    WHERE a.TenantId = @tenant AND a.CreditAssessmentId = @AssessmentId;
    COMMIT TRANSACTION;
END;
GO
/* ---------------------------------------------------------------------------------------------------------------
   The report (FR-FIN-023): readable by tp_app and tp_readonly; the row filters of the tables they read apply.
   --------------------------------------------------------------------------------------------------------------- */
CREATE OR ALTER VIEW fin.v_CreditAssessmentReport
AS
SELECT a.TenantId, a.CreditAssessmentId, a.PublicId, a.CompanyId, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn, co.IsHolding,
       a.StatementId, s.Basis, s.PeriodType, s.PeriodStart, s.PeriodEnd, s.FiscalYear, s.Assurance, s.AuditorName, s.AuditOpinion,
       s.VersionNo AS StatementVersionNo, s.Status AS StatementStatus, a.PriorStatementId, a.UsedPriorStatementId,
       sc.Code AS ScorecardCode, sc.VersionNo AS ScorecardVersionNo, sc.NameAr AS ScorecardNameAr, sc.NameEn AS ScorecardNameEn,
       a.AssessmentDate, a.FxRateToScorecard, a.Status, a.ResultState, a.CoveragePct, a.FinancialScore, fng.Code AS FinancialGrade, a.WeightedScore,
       ig.Code AS IndicatedGrade, a.AdjustmentNotches, cg.Code AS CapGrade, sg.Code AS StandaloneGrade, a.SupportNotches, a.OverrideNotches,
       fg.Code AS FinalGrade, fg.NotchNo AS FinalNotch, fg.Category AS FinalCategory, fg.RiskBand, fg.IsInvestmentGrade,
       fg.DescriptionAr AS FinalGradeDescriptionAr, fg.DescriptionEn AS FinalGradeDescriptionEn,
       n.Strengths, n.PointsToWatch, n.Weaknesses, n.CriticalRisks,
       a.SummaryAr, a.SummaryEn, sc.DisclaimerAr, sc.DisclaimerEn,
       CAST(CASE WHEN a.ComputedAt IS NOT NULL AND a.InputsHash = h.InputsHash THEN 1 ELSE 0 END AS BIT) AS IsCurrent,
       a.ComputedAt, a.PreparedBy, a.PreparedOn, a.ApprovedBy, a.ApprovedOn, a.RejectionReason
FROM fin.CreditAssessment AS a
JOIN org.Company AS co ON co.TenantId = a.TenantId AND co.CompanyId = a.CompanyId
JOIN fin.FinancialStatement AS s ON s.TenantId = a.TenantId AND s.FinancialStatementId = a.StatementId
JOIN fin.Scorecard AS sc ON sc.ScorecardId = a.ScorecardId
LEFT JOIN fin.RatingGrade AS fng ON fng.RatingGradeId = a.FinancialGradeId
LEFT JOIN fin.RatingGrade AS ig ON ig.RatingGradeId = a.IndicatedGradeId
LEFT JOIN fin.RatingGrade AS cg ON cg.RatingGradeId = a.CapGradeId
LEFT JOIN fin.RatingGrade AS sg ON sg.RatingGradeId = a.StandaloneGradeId
LEFT JOIN fin.RatingGrade AS fg ON fg.RatingGradeId = a.FinalGradeId
CROSS APPLY fin.fn_CreditAssessmentInputsHash(a.TenantId, a.CreditAssessmentId) AS h
OUTER APPLY (SELECT SUM(CASE WHEN x.Kind = 'STRENGTH' THEN 1 ELSE 0 END) AS Strengths, SUM(CASE WHEN x.Kind = 'WATCH' THEN 1 ELSE 0 END) AS PointsToWatch,
                    SUM(CASE WHEN x.Kind = 'WEAKNESS' THEN 1 ELSE 0 END) AS Weaknesses, SUM(CASE WHEN x.Kind = 'CRITICAL_RISK' THEN 1 ELSE 0 END) AS CriticalRisks
             FROM fin.CreditAssessmentFinding AS x WHERE x.TenantId = a.TenantId AND x.AssessmentId = a.CreditAssessmentId) AS n;
GO
CREATE OR ALTER VIEW fin.v_CreditAssessmentFactors
AS
SELECT f.TenantId, f.AssessmentId, f.CreditAssessmentFactorId, f.FactorCode,
       CASE f.FactorCode WHEN 'SCALE' THEN N'الحجم' WHEN 'PROFITABILITY' THEN N'الربحية' WHEN 'LEVERAGE' THEN N'الرفع المالي وهيكل رأس المال'
            WHEN 'COVERAGE' THEN N'التغطية وخدمة الدين' WHEN 'CASH_FLOW' THEN N'التدفق النقدي' WHEN 'LIQUIDITY' THEN N'السيولة ورأس المال العامل'
            ELSE N'العوامل النوعية (تقدير المحلل)' END AS FactorNameAr,
       m.Code AS MetricCode, m.NameAr AS MetricNameAr, m.NameEn AS MetricNameEn, m.Unit, m.Direction, f.Weight, f.EffectiveWeight,
       f.Status, f.Value, f.Score, g.Code AS Grade, g.Category AS GradeCategory, f.Contribution, f.Reason, sm.SortOrder
FROM fin.CreditAssessmentFactor AS f
JOIN fin.CreditMetric AS m ON m.CreditMetricId = f.MetricId
JOIN fin.CreditAssessment AS a ON a.TenantId = f.TenantId AND a.CreditAssessmentId = f.AssessmentId
LEFT JOIN fin.ScorecardMetric AS sm ON sm.ScorecardId = a.ScorecardId AND sm.MetricId = f.MetricId
LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = f.GradeId;
GO
CREATE OR ALTER VIEW fin.v_CreditAssessmentFindings
AS
SELECT x.TenantId, x.AssessmentId, x.SeqNo, x.Kind, x.Source, x.RuleCode, x.LineCode, x.RiskLevel, x.Value, x.PriorValue, x.Notches, x.RefId,
       x.TextAr, x.TextEn,
       CASE x.Kind WHEN 'STRENGTH' THEN N'نقطة قوة' WHEN 'INFO' THEN N'ملاحظة' WHEN 'WATCH' THEN N'للمراقبة' WHEN 'WEAKNESS' THEN N'نقطة ضعف'
            WHEN 'CRITICAL_RISK' THEN N'خطر حرج' ELSE N'تعديل على الدرجة' END AS KindAr
FROM fin.CreditAssessmentFinding AS x;
GO
/* Each line of the assessed statement with its comparison line, its change, its share, and the risk level of its item
   rule in this assessment. */
CREATE OR ALTER VIEW fin.v_CreditAssessmentItems
AS
SELECT a.TenantId, a.CreditAssessmentId AS AssessmentId, ia.LineCode, ia.NameAr, ia.NameEn, ia.Section, ia.IsTotal, ia.SortOrder,
       ia.Amount, ia.PriorAmount, ia.Change, ia.ChangePct, ia.SharePct, ia.ShareBase,
       r.RuleCode AS ItemRuleCode, r.RiskLevel, r.Kind AS FindingKind, r.TextAr AS FindingTextAr
FROM fin.CreditAssessment AS a
CROSS APPLY fin.fn_StatementItemAnalysis(a.StatementId, a.UsedPriorStatementId) AS ia
OUTER APPLY (SELECT TOP (1) x.RuleCode, x.RiskLevel, x.Kind, x.TextAr
             FROM fin.CreditAssessmentFinding AS x
             WHERE x.TenantId = a.TenantId AND x.AssessmentId = a.CreditAssessmentId AND x.Source = 'ITEM_RULE' AND x.LineCode = ia.LineCode
             ORDER BY x.SeqNo) AS r
WHERE ia.TenantId = a.TenantId;
GO
/* The covenants tested on the assessed statement (their latest evaluation) and the breach record of each. */
CREATE OR ALTER VIEW fin.v_CreditAssessmentCovenants
AS
SELECT a.TenantId, a.CreditAssessmentId AS AssessmentId, t.CovenantTestId, t.CovenantRootId, t.CovenantId, c.MeasureKind,
       mf.Code AS FormulaCode, mf.NameAr AS FormulaNameAr, o.ClauseRef, o.FacilityId, t.PeriodStart, t.PeriodEnd, t.EvaluationNo, t.Result,
       t.ActualValue, t.OperatorApplied, t.ThresholdApplied, t.Headroom, t.HeadroomPct, b.ObligationBreachId, b.Status AS BreachStatus
FROM fin.CreditAssessment AS a
JOIN obl.CovenantTestStatement AS ts ON ts.TenantId = a.TenantId AND ts.StatementId = a.StatementId
JOIN obl.CovenantTest AS t ON t.TenantId = ts.TenantId AND t.CovenantTestId = ts.CovenantTestId
JOIN obl.Covenant AS c ON c.TenantId = t.TenantId AND c.CovenantId = t.CovenantId
JOIN obl.Obligation AS o ON o.TenantId = c.TenantId AND o.ObligationId = c.ObligationId
LEFT JOIN fin.MeasureFormula AS mf ON mf.TenantId = t.TenantId AND mf.MeasureFormulaId = t.FormulaId
OUTER APPLY (SELECT TOP (1) x.ObligationBreachId, x.Status
             FROM obl.ObligationBreach AS x
             WHERE x.TenantId = t.TenantId AND x.CovenantRootId = t.CovenantRootId AND x.TestPeriodEnd = t.PeriodEnd
             ORDER BY CASE WHEN x.Status IN ('OPEN','IN_CURE') THEN 0 ELSE 1 END, x.ObligationBreachId DESC) AS b
WHERE t.State IN ('EVALUATED','REVIEWED')
  AND t.EvaluationNo = (SELECT MAX(y.EvaluationNo) FROM obl.CovenantTest AS y
                        WHERE y.TenantId = t.TenantId AND y.CovenantRootId = t.CovenantRootId AND y.PeriodEnd = t.PeriodEnd AND y.State IN ('EVALUATED','REVIEWED'));
GO
/* For an assessment of a consolidated statement: each unit, with the latest approved assessment of its own standalone
   statement for the period (FR-FIN-015, FR-FIN-022). */
CREATE OR ALTER VIEW fin.v_CreditAssessmentGroupUnits
AS
SELECT a.TenantId, a.CreditAssessmentId AS AssessmentId, u.MemberCompanyId, u.Role, u.Method, u.OwnershipPct, u.RecordedOwnershipPct,
       u.StandaloneStatementId, ua.CreditAssessmentId AS UnitAssessmentId, g.Code AS UnitFinalGrade, g.RiskBand AS UnitRiskBand
FROM fin.CreditAssessment AS a
JOIN fin.v_ConsolidationUnits AS u ON u.TenantId = a.TenantId AND u.StatementId = a.StatementId
OUTER APPLY (SELECT TOP (1) x.CreditAssessmentId, x.FinalGradeId
             FROM fin.CreditAssessment AS x
             WHERE x.TenantId = a.TenantId AND x.StatementId = u.StandaloneStatementId AND x.Status = 'APPROVED') AS ua
LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = ua.FinalGradeId;
GO
GRANT EXECUTE ON fin.usp_ComputeCreditAssessment TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentReport TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentFactors TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentFindings TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentItems TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentCovenants TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentGroupUnits TO [tp_app];
GRANT SELECT ON fin.fn_StatementItemAnalysis TO [tp_app];
GO
-- The application writes the assessment's own fields and inputs; its results only the computation writes.
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentFactor] TO [tp_app];
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentFinding] TO [tp_app];
DENY UPDATE ON [fin].[CreditAssessment]([ComputedAt], [InputsHash], [UsedPriorStatementId], [ResultState], [CoveragePct], [FinancialScore], [FinancialGradeId],
    [WeightedScore], [IndicatedGradeId], [AdjustmentNotches], [CapGradeId], [StandaloneGradeId], [SupportNotches], [OverrideNotches], [FinalGradeId],
    [SummaryAr], [SummaryEn], [Snapshot]) TO [tp_app];
GO

/* 049_credit_readiness.sql — the company's readiness file before its lenders, its timeline of actions and the early
   warning (docs/36 gaps F3 and F4, ADR 0024, FR-FIN-037, BR-FIN-038).

   From the company's side (docs/31 decision 34) an assessment answers: what will the lender see, and what do we do
   before it? Four views read an assessment (official or trial) with the facilities, covenants and reporting
   obligations of its company:
     fin.v_CreditReadinessEvents    the lender's dates within the lead time of the tenant (setting
                                    fin.readiness.lead_months, 6 by the owner's decision 34) after the assessment date:
                                    each facility that expires (its renewal), each scheduled covenant test with the
                                    last headroom of its covenant, and each scheduled report to a lender; each with its
                                    readiness RED, AMBER or GREEN by fixed rules;
     fin.v_CreditReadinessRequests  what the lender will most likely ask: each disclosure the assessment found missing
                                    or inconsistent, the bureau report when none was read, and the document of each
                                    remedy the report proposes;
     fin.v_CreditReadinessActions   the timeline: the remedies by their effect, before the period end (a remedy is
                                    booked in the period only on a document dated by its end, ADR 0023), then the
                                    requests before the first lender date less 30 days;
     fin.v_CreditEarlyWarnings      today, for the latest computed assessment of an actual statement of each company
                                    (a budget looks ahead and does not raise warnings, ADR 0025): every lender date
                                    within the lead time whose readiness is not GREEN, with the stage of the time left;
                                    fin.fn_CreditEarlyWarnings gives the same on any date, for the job of 051.
   Two views compare the ratings a lender communicated with the assessment (ADR 0026, FR-FIN-039, BR-FIN-040):
     fin.v_LenderRatingComparison   each lender rating beside the assessment of its date, with the gap in notches;
     fin.v_LenderRatingGapDrivers   where they part: the metrics on the side of the gap, the adjustments and ceilings.
   Two more views compare a budget statement with the actual ones (ADR 0025, FR-FIN-038, BR-FIN-039):
     fin.v_BudgetComparison         a budget's trial assessment beside the latest assessment of an earlier actual
                                    statement of its company, with the notches the plan gains or loses;
     fin.v_BudgetFactorComparison   each metric of the budget beside the same metric of the actual.
   Readiness of a date (BR-FIN-038):
     RED   the assessment is not rated, its liquidity is SGL-4 or its grade B3 or worse; or, for a covenant test, the
           last test was a breach or its headroom is below zero; or, for a renewal, the lender has notified a stop,
           a reduction or no renewal of the facility (ADR 0021), or the lender's latest rating of the company is B3
           or worse (ADR 0026);
     AMBER its liquidity is SGL-3, its outlook negative, a critical risk is open or a disclosure is missing; or, for a
           covenant test, the last headroom is below the covenant's early warning (10% when not set); or, for a
           renewal, the lender's latest rating is two notches or more below the assessment's grade (ADR 0026);
     GREEN otherwise. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
/* The signals of an assessment the readiness reads, and its window. */
CREATE OR ALTER FUNCTION fin.fn_CreditReadinessBase (@AsOf DATE)
RETURNS TABLE
AS RETURN
SELECT a.TenantId, a.CreditAssessmentId AS AssessmentId, a.CompanyId, a.IsTrial, a.ResultState, a.LiquidityLabel, a.Outlook, g.Code AS FinalGrade,
       g.NotchNo AS FinalNotch, ISNULL(@AsOf, a.AssessmentDate) AS FromDate, lm.Value AS LeadMonths,
       DATEADD(MONTH, lm.Value, ISNULL(@AsOf, a.AssessmentDate)) AS ToDate,
       (SELECT COUNT(*) FROM fin.CreditAssessmentFinding AS x WHERE x.TenantId = a.TenantId AND x.AssessmentId = a.CreditAssessmentId AND x.Kind = 'CRITICAL_RISK') AS CriticalRisks,
       (SELECT COUNT(*) FROM fin.CreditAssessmentFinding AS x WHERE x.TenantId = a.TenantId AND x.AssessmentId = a.CreditAssessmentId AND x.Source = 'DATA') AS DataRequests
FROM fin.CreditAssessment AS a
CROSS APPLY cfg.fn_SettingInt(a.TenantId, 'fin.readiness.lead_months', 6) AS lm
LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = a.FinalGradeId
WHERE a.ComputedAt IS NOT NULL;
GO
/* The lender's dates of an assessment's company in a window, each with its readiness; @AsOf NULL: the assessment date. */
CREATE OR ALTER FUNCTION fin.fn_CreditReadinessEvents (@AsOf DATE)
RETURNS TABLE
AS RETURN
WITH e AS (
    -- a facility that expires: its renewal, with what its lender notified and the latest rating it communicated
    SELECT b.*, 'RENEWAL' AS EventKind, f.ExpiryDate AS EventDate, f.FacilityId, CAST(f.FacilityId AS BIGINT) AS RefId, fa.FacilityNo AS Reference,
           f.LimitAction, CAST(NULL AS VARCHAR(30)) AS LastResult, CAST(NULL AS DECIMAL(19,6)) AS LastHeadroomPct, CAST(NULL AS DECIMAL(19,6)) AS EarlyWarningPct,
           lr.Code AS LenderGrade, CAST(lr.NotchNo AS INT) AS LenderNotch
    FROM fin.fn_CreditReadinessBase(@AsOf) AS b
    JOIN fin.CreditAssessmentFacility AS f ON f.TenantId = b.TenantId AND f.AssessmentId = b.AssessmentId
    JOIN fac.Facility AS fa ON fa.TenantId = f.TenantId AND fa.FacilityId = f.FacilityId
    OUTER APPLY (SELECT TOP (1) g.Code, g.NotchNo FROM fin.LenderRating AS r JOIN fin.RatingGrade AS g ON g.RatingGradeId = r.GradeId
                 WHERE r.TenantId = b.TenantId AND r.CompanyId = b.CompanyId AND r.LenderInstitutionId = f.LenderInstitutionId AND r.RatingDate <= b.FromDate
                 ORDER BY r.RatingDate DESC) AS lr
    WHERE f.ExpiryDate BETWEEN b.FromDate AND b.ToDate
    UNION ALL
    -- a scheduled covenant test of the company, with the last result and headroom of its covenant
    SELECT b.*, 'COVENANT_TEST', t.DueDate, o.FacilityId, t.CovenantTestId, o.TitleAr, NULL, lt.Result, lt.HeadroomPct, ISNULL(c.EarlyWarningPct, 10), NULL, NULL
    FROM fin.fn_CreditReadinessBase(@AsOf) AS b
    JOIN obl.Covenant AS c ON c.TenantId = b.TenantId AND c.TestedCompanyId = b.CompanyId
    JOIN obl.Obligation AS o ON o.TenantId = c.TenantId AND o.ObligationId = c.ObligationId
    JOIN obl.CovenantTest AS t ON t.TenantId = c.TenantId AND t.CovenantId = c.CovenantId AND t.State IN ('SCHEDULED', 'PENDING_DATA')
    OUTER APPLY (SELECT TOP (1) x.Result, x.HeadroomPct FROM obl.CovenantTest AS x
                 WHERE x.TenantId = t.TenantId AND x.CovenantRootId = t.CovenantRootId AND x.State IN ('EVALUATED', 'REVIEWED')
                 ORDER BY x.PeriodEnd DESC, x.EvaluationNo DESC) AS lt
    WHERE t.DueDate BETWEEN b.FromDate AND b.ToDate
    UNION ALL
    -- a scheduled report to a lender on a facility of the company (the audited statements, a valuation...)
    SELECT b.*, 'REPORTING', ri.DueDate, o.FacilityId, ri.ReportingInstanceId, o.TitleAr, NULL, NULL, NULL, NULL, NULL, NULL
    FROM fin.fn_CreditReadinessBase(@AsOf) AS b
    JOIN fac.Facility AS fa ON fa.TenantId = b.TenantId AND fa.BorrowerCompanyId = b.CompanyId
    JOIN obl.Obligation AS o ON o.TenantId = fa.TenantId AND o.FacilityId = fa.FacilityId
    JOIN obl.ReportingObligation AS ro ON ro.TenantId = o.TenantId AND ro.ObligationId = o.ObligationId
    JOIN obl.ReportingInstance AS ri ON ri.TenantId = ro.TenantId AND ri.ReportingObligationId = ro.ReportingObligationId AND ri.Status = 'SCHEDULED'
    WHERE ri.DueDate BETWEEN b.FromDate AND b.ToDate)
SELECT e.TenantId, e.AssessmentId, e.CompanyId, e.IsTrial, e.FinalGrade, e.LiquidityLabel, e.Outlook, e.LeadMonths, e.EventKind, e.EventDate,
       DATEDIFF(DAY, e.FromDate, e.EventDate) AS DaysLeft, e.FacilityId, e.RefId, e.Reference, e.LimitAction, e.LastResult, e.LastHeadroomPct,
       e.LenderGrade,
       CASE WHEN ISNULL(e.ResultState, '') <> 'RATED' OR e.LiquidityLabel = 'SGL-4' OR e.FinalNotch >= 16
                 OR (e.EventKind = 'COVENANT_TEST' AND (e.LastResult = 'BREACH' OR e.LastHeadroomPct < 0))
                 OR (e.EventKind = 'RENEWAL' AND (e.LimitAction IN ('UNDRAWN_STOPPED', 'LIMIT_REDUCED', 'NOT_RENEWED') OR e.LenderNotch >= 16)) THEN 'RED'
            WHEN e.LiquidityLabel = 'SGL-3' OR e.Outlook = 'NEGATIVE' OR e.CriticalRisks > 0 OR e.DataRequests > 0
                 OR (e.EventKind = 'COVENANT_TEST' AND e.LastHeadroomPct < e.EarlyWarningPct)
                 OR (e.EventKind = 'RENEWAL' AND e.LenderNotch - e.FinalNotch >= 2) THEN 'AMBER'
            ELSE 'GREEN' END AS Readiness
FROM e;
GO
CREATE OR ALTER VIEW fin.v_CreditReadinessEvents
AS
SELECT * FROM fin.fn_CreditReadinessEvents(NULL);
GO
/* What the lender will most likely ask before its dates. */
CREATE OR ALTER VIEW fin.v_CreditReadinessRequests
AS
SELECT x.TenantId, x.AssessmentId, 'DISCLOSURE' AS RequestKind, x.RuleCode AS Code, x.LineCode, x.TextAr, x.TextEn, x.SeqNo AS Ord
FROM fin.CreditAssessmentFinding AS x
WHERE x.Source = 'DATA'
UNION ALL
SELECT a.TenantId, a.CreditAssessmentId, 'BUREAU', 'BUREAU_REPORT', NULL, t.TextAr, t.TextEn, 1000
FROM fin.CreditAssessment AS a
CROSS APPLY (SELECT N'تقرير سمة التجاري للشركة: سيطلبه البنك ليقارن ديونها في السجل بقوائمها' AS TextAr,
                    N'The company''s SIMAH commercial report: the lender will ask for it to compare its recorded debt with the statements' AS TextEn) AS t
WHERE a.ComputedAt IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM fin.CreditAssessmentBureau AS b WHERE b.TenantId = a.TenantId AND b.AssessmentId = a.CreditAssessmentId)
UNION ALL
SELECT r.TenantId, r.AssessmentId, 'EVIDENCE', cr.Code, NULL, cr.EvidenceAr, cr.EvidenceEn, 2000 + r.SeqNo
FROM fin.CreditAssessmentRemedy AS r
JOIN fin.CreditRemedy AS cr ON cr.CreditRemedyId = r.RemedyId
WHERE cr.EvidenceAr IS NOT NULL;
GO
/* The timeline of actions: the remedies by their effect before the next fiscal year end of the company, then the
   requests before the first lender date less 30 days (the end of the lead time when no date falls in it). */
CREATE OR ALTER VIEW fin.v_CreditReadinessActions
AS
WITH b AS (
    SELECT a.TenantId, a.CreditAssessmentId AS AssessmentId, a.AssessmentDate,
           CASE WHEN EOMONTH(DATEFROMPARTS(YEAR(a.AssessmentDate), c.FiscalYearEndMonth, 1)) >= a.AssessmentDate
                THEN EOMONTH(DATEFROMPARTS(YEAR(a.AssessmentDate), c.FiscalYearEndMonth, 1))
                ELSE EOMONTH(DATEFROMPARTS(YEAR(a.AssessmentDate) + 1, c.FiscalYearEndMonth, 1)) END AS NextPeriodEnd,
           (SELECT MIN(ev.EventDate) FROM fin.v_CreditReadinessEvents AS ev WHERE ev.TenantId = a.TenantId AND ev.AssessmentId = a.CreditAssessmentId) AS FirstEvent,
           DATEADD(MONTH, lm.Value, a.AssessmentDate) AS WindowEnd
    FROM fin.CreditAssessment AS a
    JOIN org.Company AS c ON c.TenantId = a.TenantId AND c.CompanyId = a.CompanyId
    CROSS APPLY cfg.fn_SettingInt(a.TenantId, 'fin.readiness.lead_months', 6) AS lm
    WHERE a.ComputedAt IS NOT NULL)
SELECT b.TenantId, b.AssessmentId, 'BEFORE_PERIOD_END' AS Phase, b.NextPeriodEnd AS Deadline, cr.Code AS ActionCode, cr.Kind AS ActionKind,
       cr.NameAr, cr.NameEn, cr.EvidenceAr, r.NotchesGained, r.TriggerCode,
       ROW_NUMBER() OVER (PARTITION BY b.TenantId, b.AssessmentId ORDER BY ISNULL(r.NotchesGained, 0) DESC, r.SeqNo) AS Ord
FROM b
JOIN fin.CreditAssessmentRemedy AS r ON r.TenantId = b.TenantId AND r.AssessmentId = b.AssessmentId
JOIN fin.CreditRemedy AS cr ON cr.CreditRemedyId = r.RemedyId
UNION ALL
SELECT b.TenantId, b.AssessmentId, 'BEFORE_SUBMISSION',
       CASE WHEN DATEADD(DAY, -30, ISNULL(b.FirstEvent, b.WindowEnd)) < b.AssessmentDate THEN b.AssessmentDate ELSE DATEADD(DAY, -30, ISNULL(b.FirstEvent, b.WindowEnd)) END,
       q.Code, q.RequestKind, q.TextAr, q.TextEn, NULL, NULL, NULL, 1000 + q.Ord
FROM b
JOIN fin.v_CreditReadinessRequests AS q ON q.TenantId = b.TenantId AND q.AssessmentId = b.AssessmentId
WHERE q.RequestKind <> 'EVIDENCE';
GO
/* On @AsOf, for the latest computed assessment of each company, every lender date within the lead time that is not
   ready, with the stage of the time left (the lead time, then 90, 30 and 7 days) that the early warning job reads
   (051, ADR 0027). */
CREATE OR ALTER FUNCTION fin.fn_CreditEarlyWarnings (@AsOf DATE)
RETURNS TABLE
AS RETURN
SELECT ev.*, DATEADD(MONTH, -ev.LeadMonths, ev.EventDate) AS WarnFrom,
       CASE WHEN ev.DaysLeft <= 7 THEN 'D7' WHEN ev.DaysLeft <= 30 THEN 'D30' WHEN ev.DaysLeft <= 90 THEN 'D90' ELSE 'LEAD' END AS Stage
FROM fin.fn_CreditReadinessEvents(@AsOf) AS ev
WHERE ev.Readiness <> 'GREEN'
  AND ev.AssessmentId = (SELECT TOP (1) a.CreditAssessmentId FROM fin.CreditAssessment AS a
                         JOIN fin.FinancialStatement AS s ON s.TenantId = a.TenantId AND s.FinancialStatementId = a.StatementId AND s.Nature = 'ACTUAL'
                         WHERE a.TenantId = ev.TenantId AND a.CompanyId = ev.CompanyId AND a.ComputedAt IS NOT NULL
                           AND a.Status IN ('DRAFT', 'SUBMITTED', 'APPROVED')
                         ORDER BY a.ComputedAt DESC, a.CreditAssessmentId DESC);
GO
/* Today's early warnings. */
CREATE OR ALTER VIEW fin.v_CreditEarlyWarnings
AS
SELECT * FROM fin.fn_CreditEarlyWarnings(CAST(SYSUTCDATETIME() AS DATE));
GO
/* A budget beside the latest assessment of an actual statement of its company (ADR 0025): the grade, score,
   liquidity, outlook and critical risks of each, and the notches the plan gains (positive) or loses (negative). */
CREATE OR ALTER VIEW fin.v_BudgetComparison
AS
SELECT b.TenantId, b.CreditAssessmentId AS BudgetAssessmentId, b.CompanyId, bs.FinancialStatementId AS BudgetStatementId, bs.PeriodEnd AS BudgetPeriodEnd,
       bg.Code AS BudgetGrade, b.WeightedScore AS BudgetScore, b.LiquidityLabel AS BudgetLiquidity, b.Outlook AS BudgetOutlook,
       (SELECT COUNT(*) FROM fin.CreditAssessmentFinding AS x WHERE x.TenantId = b.TenantId AND x.AssessmentId = b.CreditAssessmentId AND x.Kind = 'CRITICAL_RISK') AS BudgetCriticalRisks,
       ba.CreditAssessmentId AS ActualAssessmentId, ba.PeriodEnd AS ActualPeriodEnd, ba.Grade AS ActualGrade, ba.WeightedScore AS ActualScore,
       ba.LiquidityLabel AS ActualLiquidity, ba.Outlook AS ActualOutlook, ba.CriticalRisks AS ActualCriticalRisks,
       CAST(ba.NotchNo AS INT) - CAST(bg.NotchNo AS INT) AS NotchesChange
FROM fin.CreditAssessment AS b
JOIN fin.FinancialStatement AS bs ON bs.TenantId = b.TenantId AND bs.FinancialStatementId = b.StatementId AND bs.Nature = 'BUDGET'
LEFT JOIN fin.RatingGrade AS bg ON bg.RatingGradeId = b.FinalGradeId
OUTER APPLY (SELECT TOP (1) a.CreditAssessmentId, s.PeriodEnd, g.Code AS Grade, g.NotchNo, a.WeightedScore, a.LiquidityLabel, a.Outlook,
                    (SELECT COUNT(*) FROM fin.CreditAssessmentFinding AS x WHERE x.TenantId = a.TenantId AND x.AssessmentId = a.CreditAssessmentId AND x.Kind = 'CRITICAL_RISK') AS CriticalRisks
             FROM fin.CreditAssessment AS a
             JOIN fin.FinancialStatement AS s ON s.TenantId = a.TenantId AND s.FinancialStatementId = a.StatementId AND s.Nature = 'ACTUAL'
             LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = a.FinalGradeId
             WHERE a.TenantId = b.TenantId AND a.CompanyId = b.CompanyId AND a.ComputedAt IS NOT NULL AND a.Status IN ('DRAFT', 'SUBMITTED', 'APPROVED')
               AND s.PeriodEnd < bs.PeriodEnd
             ORDER BY s.PeriodEnd DESC, CASE a.Status WHEN 'APPROVED' THEN 0 WHEN 'SUBMITTED' THEN 1 ELSE 2 END, a.ComputedAt DESC) AS ba
WHERE b.ComputedAt IS NOT NULL;
GO
/* Each scorecard metric of a budget beside the same metric of its actual comparison. */
CREATE OR ALTER VIEW fin.v_BudgetFactorComparison
AS
SELECT c.TenantId, c.BudgetAssessmentId, c.ActualAssessmentId, m.Code AS MetricCode, m.NameAr AS MetricNameAr, m.NameEn AS MetricNameEn, bf.FactorCode,
       bf.Weight, af.Value AS ActualValue, bf.Value AS BudgetValue, af.Score AS ActualScore, bf.Score AS BudgetScore,
       ag.Code AS ActualGrade, bg.Code AS BudgetGrade, af.Score - bf.Score AS ScoreGain
FROM fin.v_BudgetComparison AS c
JOIN fin.CreditAssessmentFactor AS bf ON bf.TenantId = c.TenantId AND bf.AssessmentId = c.BudgetAssessmentId
JOIN fin.CreditMetric AS m ON m.CreditMetricId = bf.MetricId
LEFT JOIN fin.CreditAssessmentFactor AS af ON af.TenantId = c.TenantId AND af.AssessmentId = c.ActualAssessmentId AND af.MetricId = bf.MetricId
LEFT JOIN fin.RatingGrade AS bg ON bg.RatingGradeId = bf.GradeId
LEFT JOIN fin.RatingGrade AS ag ON ag.RatingGradeId = af.GradeId;
GO
GRANT SELECT ON fin.v_BudgetComparison TO [tp_app];
GRANT SELECT ON fin.v_BudgetFactorComparison TO [tp_app];
GO
/* Each rating a lender communicated beside the company's assessment of that date (ADR 0026): the latest computed
   assessment of an actual statement on or before the rating date (else the earliest after it), and the gap in notches
   (positive: the lender is more severe than the assessment). */
CREATE OR ALTER VIEW fin.v_LenderRatingComparison
AS
SELECT r.TenantId, r.LenderRatingId, r.CompanyId, r.LenderInstitutionId, r.RatingDate, r.LenderGradeLabel, lg.Code AS LenderGrade, r.MappingKind,
       r.LenderReasons, a.CreditAssessmentId AS AssessmentId, a.AssessmentDate, a.Grade AS AssessmentGrade, a.FacilityGrade,
       CAST(lg.NotchNo AS INT) - CAST(a.NotchNo AS INT) AS GapNotches,
       CASE WHEN a.NotchNo IS NULL THEN 'NO_ASSESSMENT' WHEN lg.NotchNo > a.NotchNo THEN 'LENDER_MORE_SEVERE'
            WHEN lg.NotchNo < a.NotchNo THEN 'LENDER_MORE_FAVOURABLE' ELSE 'SAME' END AS Direction
FROM fin.LenderRating AS r
JOIN fin.RatingGrade AS lg ON lg.RatingGradeId = r.GradeId
OUTER APPLY (SELECT TOP (1) x.CreditAssessmentId, x.AssessmentDate, g.Code AS Grade, g.NotchNo, fg.Code AS FacilityGrade
             FROM fin.CreditAssessment AS x
             JOIN fin.FinancialStatement AS s ON s.TenantId = x.TenantId AND s.FinancialStatementId = x.StatementId AND s.Nature = 'ACTUAL'
             JOIN fin.RatingGrade AS g ON g.RatingGradeId = x.FinalGradeId
             LEFT JOIN fin.RatingGrade AS fg ON fg.RatingGradeId = x.FacilityGradeId
             WHERE x.TenantId = r.TenantId AND x.CompanyId = r.CompanyId AND x.ComputedAt IS NOT NULL AND x.Status IN ('DRAFT', 'SUBMITTED', 'APPROVED')
             ORDER BY CASE WHEN x.AssessmentDate <= r.RatingDate THEN 0 ELSE 1 END,
                      CASE WHEN x.AssessmentDate <= r.RatingDate THEN DATEDIFF(DAY, x.AssessmentDate, r.RatingDate) ELSE DATEDIFF(DAY, r.RatingDate, x.AssessmentDate) END,
                      CASE x.Status WHEN 'APPROVED' THEN 0 WHEN 'SUBMITTED' THEN 1 ELSE 2 END, x.ComputedAt DESC) AS a;
GO
/* Where the assessment and the lender part (ADR 0026): when the lender is more favourable, the metrics the assessment
   grades worse than the lender's grade; when it is more severe, the metrics the assessment grades better; each with
   its weight and how far it is from the lender's grade; then every adjustment and ceiling the assessment applied,
   which a lender may weigh otherwise. */
CREATE OR ALTER VIEW fin.v_LenderRatingGapDrivers
AS
SELECT c.TenantId, c.LenderRatingId, c.AssessmentId, 'METRIC' AS DriverKind, f.FactorCode, m.Code AS Code, m.NameAr, m.NameEn, g.Code AS AssessmentGrade,
       f.Weight, CAST(g.NotchNo AS INT) - CAST(lg.NotchNo AS INT) AS NotchesFromLender,
       f.Weight * ABS(CAST(g.NotchNo AS INT) - CAST(lg.NotchNo AS INT)) AS Pull
FROM fin.v_LenderRatingComparison AS c
JOIN fin.LenderRating AS r ON r.TenantId = c.TenantId AND r.LenderRatingId = c.LenderRatingId
JOIN fin.RatingGrade AS lg ON lg.RatingGradeId = r.GradeId
JOIN fin.CreditAssessmentFactor AS f ON f.TenantId = c.TenantId AND f.AssessmentId = c.AssessmentId
JOIN fin.CreditMetric AS m ON m.CreditMetricId = f.MetricId
JOIN fin.RatingGrade AS g ON g.RatingGradeId = f.GradeId
WHERE (c.Direction = 'LENDER_MORE_FAVOURABLE' AND g.NotchNo > lg.NotchNo) OR (c.Direction = 'LENDER_MORE_SEVERE' AND g.NotchNo < lg.NotchNo)
UNION ALL
SELECT c.TenantId, c.LenderRatingId, c.AssessmentId, 'ADJUSTMENT', NULL, x.RuleCode, x.TextAr, x.TextEn, NULL, NULL, x.Notches, NULL
FROM fin.v_LenderRatingComparison AS c
JOIN fin.CreditAssessmentFinding AS x ON x.TenantId = c.TenantId AND x.AssessmentId = c.AssessmentId AND x.Kind = 'ADJUSTMENT'
WHERE c.Direction IN ('LENDER_MORE_FAVOURABLE', 'LENDER_MORE_SEVERE')
UNION ALL
SELECT c.TenantId, c.LenderRatingId, c.AssessmentId, 'CEILING', NULL, 'CAP', N'سقف طبّقه التقييم على الدرجة', N'A ceiling the assessment applied to the grade',
       cg.Code, NULL, NULL, NULL
FROM fin.v_LenderRatingComparison AS c
JOIN fin.CreditAssessment AS a ON a.TenantId = c.TenantId AND a.CreditAssessmentId = c.AssessmentId
JOIN fin.RatingGrade AS cg ON cg.RatingGradeId = a.CapGradeId
WHERE c.Direction IN ('LENDER_MORE_FAVOURABLE', 'LENDER_MORE_SEVERE');
GO
GRANT SELECT ON fin.v_LenderRatingComparison TO [tp_app];
GRANT SELECT ON fin.v_LenderRatingGapDrivers TO [tp_app];
GO
GRANT SELECT ON fin.v_CreditReadinessEvents TO [tp_app];
GRANT SELECT ON fin.v_CreditReadinessRequests TO [tp_app];
GRANT SELECT ON fin.v_CreditReadinessActions TO [tp_app];
GRANT SELECT ON fin.v_CreditEarlyWarnings TO [tp_app];
GO

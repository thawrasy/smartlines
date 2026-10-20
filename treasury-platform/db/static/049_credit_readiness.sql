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
     fin.v_CreditEarlyWarnings      today, for the latest computed assessment of each company: every lender date
                                    within the lead time whose readiness is not GREEN.
   Readiness of a date (BR-FIN-038):
     RED   the assessment is not rated, its liquidity is SGL-4 or its grade B3 or worse; or, for a covenant test, the
           last test was a breach or its headroom is below zero; or, for a renewal, the lender has notified a stop,
           a reduction or no renewal of the facility (ADR 0021);
     AMBER its liquidity is SGL-3, its outlook negative, a critical risk is open or a disclosure is missing; or, for a
           covenant test, the last headroom is below the covenant's early warning (10% when not set);
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
    -- a facility that expires: its renewal, with what its lender notified
    SELECT b.*, 'RENEWAL' AS EventKind, f.ExpiryDate AS EventDate, f.FacilityId, CAST(f.FacilityId AS BIGINT) AS RefId, fa.FacilityNo AS Reference,
           f.LimitAction, CAST(NULL AS VARCHAR(30)) AS LastResult, CAST(NULL AS DECIMAL(19,6)) AS LastHeadroomPct, CAST(NULL AS DECIMAL(19,6)) AS EarlyWarningPct
    FROM fin.fn_CreditReadinessBase(@AsOf) AS b
    JOIN fin.CreditAssessmentFacility AS f ON f.TenantId = b.TenantId AND f.AssessmentId = b.AssessmentId
    JOIN fac.Facility AS fa ON fa.TenantId = f.TenantId AND fa.FacilityId = f.FacilityId
    WHERE f.ExpiryDate BETWEEN b.FromDate AND b.ToDate
    UNION ALL
    -- a scheduled covenant test of the company, with the last result and headroom of its covenant
    SELECT b.*, 'COVENANT_TEST', t.DueDate, o.FacilityId, t.CovenantTestId, o.TitleAr, NULL, lt.Result, lt.HeadroomPct, ISNULL(c.EarlyWarningPct, 10)
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
    SELECT b.*, 'REPORTING', ri.DueDate, o.FacilityId, ri.ReportingInstanceId, o.TitleAr, NULL, NULL, NULL, NULL
    FROM fin.fn_CreditReadinessBase(@AsOf) AS b
    JOIN fac.Facility AS fa ON fa.TenantId = b.TenantId AND fa.BorrowerCompanyId = b.CompanyId
    JOIN obl.Obligation AS o ON o.TenantId = fa.TenantId AND o.FacilityId = fa.FacilityId
    JOIN obl.ReportingObligation AS ro ON ro.TenantId = o.TenantId AND ro.ObligationId = o.ObligationId
    JOIN obl.ReportingInstance AS ri ON ri.TenantId = ro.TenantId AND ri.ReportingObligationId = ro.ReportingObligationId AND ri.Status = 'SCHEDULED'
    WHERE ri.DueDate BETWEEN b.FromDate AND b.ToDate)
SELECT e.TenantId, e.AssessmentId, e.CompanyId, e.IsTrial, e.FinalGrade, e.LiquidityLabel, e.Outlook, e.LeadMonths, e.EventKind, e.EventDate,
       DATEDIFF(DAY, e.FromDate, e.EventDate) AS DaysLeft, e.FacilityId, e.RefId, e.Reference, e.LimitAction, e.LastResult, e.LastHeadroomPct,
       CASE WHEN ISNULL(e.ResultState, '') <> 'RATED' OR e.LiquidityLabel = 'SGL-4' OR e.FinalNotch >= 16
                 OR (e.EventKind = 'COVENANT_TEST' AND (e.LastResult = 'BREACH' OR e.LastHeadroomPct < 0))
                 OR (e.EventKind = 'RENEWAL' AND e.LimitAction IN ('UNDRAWN_STOPPED', 'LIMIT_REDUCED', 'NOT_RENEWED')) THEN 'RED'
            WHEN e.LiquidityLabel = 'SGL-3' OR e.Outlook = 'NEGATIVE' OR e.CriticalRisks > 0 OR e.DataRequests > 0
                 OR (e.EventKind = 'COVENANT_TEST' AND e.LastHeadroomPct < e.EarlyWarningPct) THEN 'AMBER'
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
/* Today, for the latest computed assessment of each company, every lender date within the lead time that is not ready. */
CREATE OR ALTER VIEW fin.v_CreditEarlyWarnings
AS
SELECT ev.*, DATEADD(MONTH, -ev.LeadMonths, ev.EventDate) AS WarnFrom
FROM fin.fn_CreditReadinessEvents(CAST(SYSUTCDATETIME() AS DATE)) AS ev
WHERE ev.Readiness <> 'GREEN'
  AND ev.AssessmentId = (SELECT TOP (1) a.CreditAssessmentId FROM fin.CreditAssessment AS a
                         WHERE a.TenantId = ev.TenantId AND a.CompanyId = ev.CompanyId AND a.ComputedAt IS NOT NULL
                           AND a.Status IN ('DRAFT', 'SUBMITTED', 'APPROVED')
                         ORDER BY a.ComputedAt DESC, a.CreditAssessmentId DESC);
GO
GRANT SELECT ON fin.v_CreditReadinessEvents TO [tp_app];
GRANT SELECT ON fin.v_CreditReadinessRequests TO [tp_app];
GRANT SELECT ON fin.v_CreditReadinessActions TO [tp_app];
GRANT SELECT ON fin.v_CreditEarlyWarnings TO [tp_app];
GO

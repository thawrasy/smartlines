/* ============================================================================
   BankFas - 045: the financial statements module of M5 (owner request of 2026-10-18; docs/03 section 10, spec 12
   FR-FIN-015 to FR-FIN-019, BR-FIN-012 to BR-FIN-017; docs/adr/0016-financial-statements-module.md)

   A company's statements are entered into the system to study its balance sheet and to test the bank covenants on
   it. A company enters standalone statements; a holding (org.Company.IsHolding) may enter consolidated statements
   too, with every unit they consolidate (fin.ConsolidationMember). From the evaluated covenant tests the system
   reports every breach arising from the statements (fin.v_StatementBreachReport), and from the liquidity routed to
   the bank it measures how the company keeps its flow covenants (fin.fn_BankFlowPerformance).

   Guards:
     - a statement is written as DRAFT, and its content (header, lines, consolidation units) changes only while it
       is a draft; its status moves DRAFT -> SUBMITTED -> APPROVED -> SUPERSEDED, or SUBMITTED -> REJECTED -> DRAFT
       (spec 12 section 8) (50060);
     - a consolidated statement belongs to a holding; when submitted it has one PARENT unit, the holding itself, and
       at least one other unit (50061);
     - liquidity routed to a bank is entered for a month either at the level of the bank or per facility, not both
       for the same kind, so it is not counted twice (50062);
     - the statements an automatic evaluation read are written into obl.CovenantTestStatement by the database, from
       the test's snapshot, when the test is evaluated; the application cannot write them.
   The rows are read under an update lock, so a submission and a change to its lines do not interleave.
   Later phase (not built): the link to a credit rating system that rates the company on these statements and on
   its covenant record (spec 12 section 11).
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
/* The statement header. Built from the table's columns, so a column added later is frozen after the draft unless it
   is named in @may. */
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);
INSERT @may VALUES (N'Status'), (N'ApprovedBy'), (N'ApprovedOn'), (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'fin.FinancialStatement') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SET @sql = N'CREATE OR ALTER TRIGGER fin.TR_FinancialStatement_Lifecycle ON fin.FinancialStatement
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    IF EXISTS (SELECT 1 FROM inserted AS i LEFT JOIN deleted AS d ON d.FinancialStatementId = i.FinancialStatementId
               WHERE (d.FinancialStatementId IS NULL AND i.Status <> ''DRAFT'')
                  OR (d.FinancialStatementId IS NOT NULL AND i.Status <> d.Status
                      AND NOT ((d.Status = ''DRAFT'' AND i.Status = ''SUBMITTED'') OR (d.Status = ''SUBMITTED'' AND i.Status IN (''APPROVED'', ''REJECTED''))
                               OR (d.Status = ''REJECTED'' AND i.Status = ''DRAFT'') OR (d.Status = ''APPROVED'' AND i.Status = ''SUPERSEDED'')))
                  OR (d.FinancialStatementId IS NOT NULL AND d.Status <> ''DRAFT'' AND EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')))
        THROW 50060, ''A statement is written as a draft and changes only as a draft; its status moves DRAFT, SUBMITTED, APPROVED or REJECTED, SUPERSEDED (FR-FIN-005)'', 1;
    -- A consolidated statement belongs to a holding (BR-FIN-013).
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN org.Company AS c WITH (UPDLOCK, HOLDLOCK) ON c.TenantId = i.TenantId AND c.CompanyId = i.CompanyId
               WHERE i.Basis = ''CONSOLIDATED'' AND c.IsHolding = 0)
        THROW 50061, ''Only a holding enters consolidated statements; a company that is not a holding enters standalone ones (BR-FIN-013)'', 1;
    -- Submitted, a consolidated statement has its holding as the one PARENT unit and at least one other unit.
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN deleted AS d ON d.FinancialStatementId = i.FinancialStatementId
               -- The units'' trigger keeps the PARENT unit on the statement''s own company.
               OUTER APPLY (SELECT SUM(CASE WHEN m.Role = ''PARENT'' THEN 1 ELSE 0 END) AS Parents,
                                   SUM(CASE WHEN m.Role <> ''PARENT'' THEN 1 ELSE 0 END) AS Others
                            FROM fin.ConsolidationMember AS m WITH (UPDLOCK, HOLDLOCK)
                            WHERE m.TenantId = i.TenantId AND m.StatementId = i.FinancialStatementId) AS m
               WHERE i.Basis = ''CONSOLIDATED'' AND i.Status = ''SUBMITTED'' AND d.Status = ''DRAFT''
                 AND (ISNULL(m.Parents, 0) <> 1 OR ISNULL(m.Others, 0) = 0))
        THROW 50061, ''A consolidated statement is submitted with its holding as the PARENT unit and every unit it consolidates (BR-FIN-013)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
-- A statement's lines and units change only while it is a draft; the PARENT unit is the statement's own company.
CREATE OR ALTER TRIGGER fin.TR_StatementLine_DraftOnly ON fin.StatementLine
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, StatementId FROM inserted UNION SELECT TenantId, StatementId FROM deleted) AS r
               JOIN fin.FinancialStatement AS s WITH (UPDLOCK, HOLDLOCK) ON s.TenantId = r.TenantId AND s.FinancialStatementId = r.StatementId
               WHERE s.Status <> 'DRAFT')
        THROW 50060, 'The lines of a submitted or approved statement do not change; a change is a new version (FR-FIN-005)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_ConsolidationMember_DraftOnly ON fin.ConsolidationMember
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, StatementId FROM inserted UNION SELECT TenantId, StatementId FROM deleted) AS r
               JOIN fin.FinancialStatement AS s WITH (UPDLOCK, HOLDLOCK) ON s.TenantId = r.TenantId AND s.FinancialStatementId = r.StatementId
               WHERE s.Status <> 'DRAFT')
        THROW 50060, 'The units of a submitted or approved consolidated statement do not change; a change is a new version (FR-FIN-015)', 1;
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN fin.FinancialStatement AS s ON s.TenantId = i.TenantId AND s.FinancialStatementId = i.StatementId
               WHERE (i.Role = 'PARENT' AND i.MemberCompanyId <> s.CompanyId) OR (i.Role <> 'PARENT' AND i.MemberCompanyId = s.CompanyId))
        THROW 50061, 'The PARENT unit of a consolidated statement is its holding, and the holding is no other unit (BR-FIN-013)', 1;
END;
GO
/* Liquidity routed to a bank (BR-FIN-016): for one company, bank, month and kind, either one entry at the level of the
   bank or entries per facility, never both, so the performance never counts the same money twice. */
CREATE OR ALTER TRIGGER fin.TR_BankFlowEntry_OneLevel ON fin.BankFlowEntry
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    IF EXISTS (SELECT 1
               FROM (SELECT DISTINCT TenantId, CompanyId, InstitutionId, MonthEnd, FlowKindId FROM inserted) AS k
               CROSS APPLY (SELECT SUM(CASE WHEN e.FacilityId IS NULL THEN 1 ELSE 0 END) AS BankLevel,
                                   SUM(CASE WHEN e.FacilityId IS NOT NULL THEN 1 ELSE 0 END) AS FacilityLevel
                            FROM fin.BankFlowEntry AS e WITH (UPDLOCK, HOLDLOCK)
                            WHERE e.TenantId = k.TenantId AND e.CompanyId = k.CompanyId AND e.InstitutionId = k.InstitutionId
                              AND e.MonthEnd = k.MonthEnd AND e.FlowKindId = k.FlowKindId) AS n
               WHERE n.BankLevel > 0 AND n.FacilityLevel > 0)
        THROW 50062, 'A month''s flow to a bank is entered at the level of the bank or per facility, not both (BR-FIN-016)', 1;
END;
GO
/* The statements an automatic evaluation read (FR-FIN-017, BR-FIN-015): when a test becomes EVALUATED, its snapshot's
   statements are written into obl.CovenantTestStatement. 044 has checked that each one is a statement of the tested
   company with that version and basis, and an evaluated test does not change, so the rows are written once. */
CREATE OR ALTER TRIGGER obl.TR_CovenantTest_StatementLinks ON obl.CovenantTest
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted WHERE State = 'EVALUATED' AND Method = 'AUTO') RETURN;
    INSERT obl.CovenantTestStatement (TenantId, CovenantTestId, StatementId, StatementVersionNo, Basis)
    SELECT DISTINCT i.TenantId, i.CovenantTestId, TRY_CAST(s.StatementId AS BIGINT), TRY_CAST(s.VersionNo AS INT), s.Basis
    FROM inserted AS i
    LEFT JOIN deleted AS d ON d.CovenantTestId = i.CovenantTestId
    CROSS APPLY OPENJSON(i.InputsSnapshot, '$.statements')
         WITH (StatementId NVARCHAR(40) '$.statementId', VersionNo NVARCHAR(40) '$.version', Basis VARCHAR(20) '$.basis') AS s
    WHERE i.State = 'EVALUATED' AND i.Method = 'AUTO' AND (d.CovenantTestId IS NULL OR d.State NOT IN ('EVALUATED','REVIEWED'))
      AND ISJSON(i.InputsSnapshot, OBJECT) = 1
      AND TRY_CAST(s.StatementId AS BIGINT) IS NOT NULL AND TRY_CAST(s.VersionNo AS INT) IS NOT NULL AND s.Basis IN ('STANDALONE','CONSOLIDATED')
      AND NOT EXISTS (SELECT 1 FROM obl.CovenantTestStatement AS x
                      WHERE x.TenantId = i.TenantId AND x.CovenantTestId = i.CovenantTestId AND x.StatementId = TRY_CAST(s.StatementId AS BIGINT));
END;
GO
-- It runs after the checks of 044, so a snapshot they refuse never reaches it.
EXEC sys.sp_settriggerorder @triggername = N'obl.TR_CovenantTest_StatementLinks', @order = N'Last', @stmttype = N'INSERT';
EXEC sys.sp_settriggerorder @triggername = N'obl.TR_CovenantTest_StatementLinks', @order = N'Last', @stmttype = N'UPDATE';
GO
DENY INSERT, UPDATE, DELETE ON obl.CovenantTestStatement TO [tp_app];
GO
/* The breach report (FR-FIN-017, R-FIN-05): every breach, and every early warning, that an evaluation found on a
   covenant measured on financial statements, with the statement it read, the covenant and its clause, the facility
   and its bank, and the breach record. Only the latest evaluation of a covenant's period counts (BR-OBL-011); a
   statement superseded since the test is flagged, as the test then waits for its new evaluation (FR-FIN-014). */
CREATE OR ALTER VIEW fin.v_StatementBreachReport
AS
WITH latest AS (
    SELECT t.TenantId, t.CovenantTestId, t.CovenantId, t.CovenantRootId, t.PeriodStart, t.PeriodEnd, t.EvaluationNo, t.State, t.Result,
           t.ActualValue, t.OperatorApplied, t.ThresholdApplied, t.Headroom, t.HeadroomPct, t.FormulaId, t.EvaluatedAt,
           ROW_NUMBER() OVER (PARTITION BY t.TenantId, t.CovenantRootId, t.PeriodEnd ORDER BY t.EvaluationNo DESC) AS rn
    FROM obl.CovenantTest AS t
    WHERE t.State IN ('EVALUATED','REVIEWED'))
SELECT t.TenantId, c.TestedCompanyId AS CompanyId, o.FacilityId, f.FacilityNo, bank.InstitutionId AS BankInstitutionId,
       o.RootId AS ObligationRootId, o.ObligationId, o.TitleAr AS ObligationTitleAr, o.ClauseRef,
       t.CovenantRootId, t.CovenantId, c.MeasureKind, mf.Code AS FormulaCode, mf.VersionNo AS FormulaVersionNo,
       t.CovenantTestId, t.PeriodStart, t.PeriodEnd, t.EvaluationNo, t.State, t.Result,
       CASE WHEN t.Result = 'BREACH' THEN 'BREACH' ELSE 'EARLY_WARNING' END AS Severity,
       t.ActualValue, t.OperatorApplied, t.ThresholdApplied, t.Headroom, t.HeadroomPct, t.EvaluatedAt,
       ts.StatementId, ts.StatementVersionNo, fs.Basis, fs.Assurance, fs.PeriodType, fs.Status AS StatementStatus,
       CAST(CASE WHEN fs.Status = 'SUPERSEDED' THEN 1 ELSE 0 END AS BIT) AS StatementSuperseded,
       b.ObligationBreachId, b.Status AS BreachStatus, b.DetectedOn, b.CureDeadline, b.NeedsReview
FROM latest AS t
JOIN obl.Covenant AS c ON c.TenantId = t.TenantId AND c.CovenantId = t.CovenantId
JOIN obl.Obligation AS o ON o.TenantId = c.TenantId AND o.ObligationId = c.ObligationId
JOIN fac.Facility AS f ON f.TenantId = o.TenantId AND f.FacilityId = o.FacilityId
JOIN obl.CovenantTestStatement AS ts ON ts.TenantId = t.TenantId AND ts.CovenantTestId = t.CovenantTestId
JOIN fin.FinancialStatement AS fs ON fs.TenantId = ts.TenantId AND fs.FinancialStatementId = ts.StatementId
LEFT JOIN fin.MeasureFormula AS mf ON mf.TenantId = t.TenantId AND mf.MeasureFormulaId = t.FormulaId
-- The bank of the covenant: the facility's agent, else its lead lender, else its largest share, at the approved revision.
OUTER APPLY (SELECT TOP (1) l.InstitutionId
             FROM fac.FacilityLender AS l
             WHERE l.TenantId = f.TenantId AND l.FacilityId = f.FacilityId
               AND l.FromRevision <= f.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo)
             ORDER BY CASE WHEN l.Roles LIKE '%AGENT%' THEN 0 WHEN l.Roles LIKE '%LEAD%' THEN 1 ELSE 2 END, l.SharePct DESC, l.FacilityLenderId) AS bank
OUTER APPLY (SELECT TOP (1) x.ObligationBreachId, x.Status, x.DetectedOn, x.CureDeadline, x.NeedsReview
             FROM obl.ObligationBreach AS x
             WHERE x.TenantId = t.TenantId AND x.CovenantRootId = t.CovenantRootId AND x.TestPeriodEnd = t.PeriodEnd
             ORDER BY CASE WHEN x.Status IN ('OPEN','IN_CURE') THEN 0 ELSE 1 END, x.ObligationBreachId DESC) AS b
WHERE t.rn = 1 AND t.Result IN ('BREACH','WARNING');
GO
/* The units of each consolidated statement, and whether each has its own approved standalone statement for the
   period, so the study of a group can be done unit by unit (FR-FIN-015). The ownership recorded in org.Shareholding
   for the holding at the period end is shown beside the one the statement gives. */
CREATE OR ALTER VIEW fin.v_ConsolidationUnits
AS
SELECT s.TenantId, s.FinancialStatementId AS StatementId, s.CompanyId AS HoldingCompanyId, s.PeriodType, s.PeriodEnd, s.FiscalYear,
       s.Status AS StatementStatus, m.MemberCompanyId, m.Role, m.Method, m.OwnershipPct, m.IncludedFrom, m.IncludedTo,
       COALESCE(m.MemberStatementId, own.FinancialStatementId) AS StandaloneStatementId, own.Assurance AS StandaloneAssurance,
       CAST(CASE WHEN m.Role = 'PARENT' OR m.MemberStatementId IS NOT NULL OR own.FinancialStatementId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS HasStandalone,
       rec.SharePercent AS RecordedOwnershipPct
FROM fin.FinancialStatement AS s
JOIN fin.ConsolidationMember AS m ON m.TenantId = s.TenantId AND m.StatementId = s.FinancialStatementId
JOIN org.Company AS h ON h.TenantId = s.TenantId AND h.CompanyId = s.CompanyId
OUTER APPLY (SELECT TOP (1) x.FinancialStatementId, x.Assurance
             FROM fin.FinancialStatement AS x
             WHERE x.TenantId = s.TenantId AND x.CompanyId = m.MemberCompanyId AND x.Basis = 'STANDALONE'
               AND x.PeriodType = s.PeriodType AND x.PeriodEnd = s.PeriodEnd AND x.Status = 'APPROVED'
             ORDER BY CASE x.Assurance WHEN 'AUDITED' THEN 0 WHEN 'REVIEWED' THEN 1 ELSE 2 END) AS own
OUTER APPLY (SELECT SUM(sh.SharePercent) AS SharePercent
             FROM org.Shareholding AS sh
             WHERE sh.TenantId = s.TenantId AND sh.CompanyId = m.MemberCompanyId AND sh.HolderPartyId = h.PartyId
               AND sh.EffectiveFrom <= s.PeriodEnd AND (sh.EffectiveTo IS NULL OR sh.EffectiveTo >= s.PeriodEnd)) AS rec
WHERE s.Basis = 'CONSOLIDATED';
GO
/* How a company keeps its flow covenants (FR-FIN-018, BR-FIN-007, BR-FIN-008, BR-FIN-016): for each covenant on
   liquidity routed to the bank, of an approved facility revision, valid on @AsOf, with a set threshold: its window
   on @AsOf (the month of the date; the quarter or half of the company's fiscal year that holds it, counted from the
   month after FiscalYearEndMonth; else the year of AnnualWindowBasis: the fiscal year, the calendar year or the
   facility year; or the 12 months to @AsOf), the confirmed flows of the window in the covenant's currency to the
   facility's banks (at the level of the bank or of this facility; flows given to another facility count for that
   one), from the tested company or the companies the obligation applies to; the amount still to route and the monthly
   rate it needs; and for a share of revenue, the revenue it is read against (an approved annual statement of the
   fiscal year of the window, or the year before, or the approved estimate, as the covenant says), the required amount
   being that share of the revenue of the months of the window (an annual revenue times the months of the window over
   twelve, review E5). Flows not yet confirmed and flows in another currency are shown apart.
   The pace (review E6): MonthsElapsed counts the months of the window already complete on @AsOf (to the end of the
   month before it), AchievedElapsed the confirmed flows of those months, and the months still to route are the rest of
   the window, the month of @AsOf included; ON_TRACK compares the two on that same basis. */
CREATE OR ALTER FUNCTION fin.fn_BankFlowPerformance (@AsOf DATE)
RETURNS TABLE
AS
RETURN
WITH cov AS (
    SELECT c.TenantId, c.CovenantId, c.RootId AS CovenantRootId, c.ObligationId, o.FacilityId, c.TestedCompanyId, c.MeasureKind,
           c.ThresholdValue, c.Operator, c.ThresholdUnit, COALESCE(c.CurrencyId, f.CurrencyId) AS CurrencyId, c.TestFrequency,
           ISNULL(c.AnnualWindowBasis, 'FISCAL_YEAR') AS WindowBasis, ISNULL(c.RevenueBasisRule, 'SAME_PERIOD') AS RevenueBasisRule,
           ISNULL(c.StatementBasis, 'STANDALONE') AS StatementBasis, f.EffectiveFrom, co.FiscalYearEndMonth
    FROM obl.Covenant AS c
    JOIN obl.Obligation AS o ON o.TenantId = c.TenantId AND o.ObligationId = c.ObligationId
    JOIN fac.Facility AS f ON f.TenantId = o.TenantId AND f.FacilityId = o.FacilityId
    JOIN org.Company AS co ON co.TenantId = c.TenantId AND co.CompanyId = c.TestedCompanyId
    WHERE c.MeasureKind IN ('FLOW_VOLUME','PERCENT_OF_REVENUE') AND c.ThresholdState = 'SET'
      AND c.FromRevision <= f.ApprovedRevisionNo AND (c.ToRevision IS NULL OR c.ToRevision > f.ApprovedRevisionNo)
      AND o.FromRevision <= f.ApprovedRevisionNo AND (o.ToRevision IS NULL OR o.ToRevision > f.ApprovedRevisionNo)
      AND c.ValidFrom <= @AsOf AND (c.ValidTo IS NULL OR c.ValidTo >= @AsOf)
), win AS (
    SELECT cov.*, w.WindowStart, w.WindowEnd, w.FiscalYearEnd
    FROM cov
    CROSS APPLY (SELECT CASE WHEN MONTH(@AsOf) <= cov.FiscalYearEndMonth
                             THEN EOMONTH(DATEFROMPARTS(YEAR(@AsOf), cov.FiscalYearEndMonth, 1))
                             ELSE EOMONTH(DATEFROMPARTS(YEAR(@AsOf) + 1, cov.FiscalYearEndMonth, 1)) END AS Fye,
                        DATEADD(YEAR, DATEDIFF(YEAR, cov.EffectiveFrom, @AsOf)
                                      - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, cov.EffectiveFrom, @AsOf), cov.EffectiveFrom) > @AsOf THEN 1 ELSE 0 END,
                                cov.EffectiveFrom) AS FacilityYearStart,
                        -- the month of @AsOf in the fiscal year, 0 for its first month
                        (MONTH(@AsOf) + 11 - cov.FiscalYearEndMonth) % 12 AS FiscalMonthNo) AS y
    CROSS APPLY (SELECT CASE
                          WHEN cov.TestFrequency = 'MONTHLY' THEN DATEFROMPARTS(YEAR(@AsOf), MONTH(@AsOf), 1)
                          WHEN cov.TestFrequency = 'QUARTERLY' THEN DATEADD(MONTH, -(y.FiscalMonthNo % 3), DATEFROMPARTS(YEAR(@AsOf), MONTH(@AsOf), 1))
                          WHEN cov.TestFrequency = 'SEMIANNUAL' THEN DATEADD(MONTH, -(y.FiscalMonthNo % 6), DATEFROMPARTS(YEAR(@AsOf), MONTH(@AsOf), 1))
                          WHEN cov.TestFrequency = 'ROLLING_12M' THEN DATEADD(DAY, 1, EOMONTH(@AsOf, -12))
                          WHEN cov.WindowBasis = 'CALENDAR_YEAR' THEN DATEFROMPARTS(YEAR(@AsOf), 1, 1)
                          WHEN cov.WindowBasis = 'FACILITY_YEAR' THEN y.FacilityYearStart
                          ELSE DATEADD(DAY, 1, EOMONTH(y.Fye, -12)) END AS WindowStart,
                        CASE
                          WHEN cov.TestFrequency = 'MONTHLY' THEN EOMONTH(@AsOf)
                          WHEN cov.TestFrequency = 'QUARTERLY' THEN EOMONTH(@AsOf, 2 - y.FiscalMonthNo % 3)
                          WHEN cov.TestFrequency = 'SEMIANNUAL' THEN EOMONTH(@AsOf, 5 - y.FiscalMonthNo % 6)
                          WHEN cov.TestFrequency = 'ROLLING_12M' THEN EOMONTH(@AsOf)
                          WHEN cov.WindowBasis = 'CALENDAR_YEAR' THEN DATEFROMPARTS(YEAR(@AsOf), 12, 31)
                          WHEN cov.WindowBasis = 'FACILITY_YEAR' THEN DATEADD(DAY, -1, DATEADD(YEAR, 1, y.FacilityYearStart))
                          ELSE y.Fye END AS WindowEnd,
                        y.Fye AS FiscalYearEnd) AS w
), flows AS (
    SELECT win.TenantId, win.CovenantId,
           SUM(CASE WHEN e.Status = 'CONFIRMED' AND e.CurrencyId = win.CurrencyId THEN e.Amount ELSE 0 END) AS Achieved,
           SUM(CASE WHEN e.Status = 'DRAFT' AND e.CurrencyId = win.CurrencyId THEN e.Amount ELSE 0 END) AS AwaitingConfirmation,
           SUM(CASE WHEN e.CurrencyId <> win.CurrencyId THEN 1 ELSE 0 END) AS OtherCurrencyEntries,
           COUNT(DISTINCT CASE WHEN e.Status = 'CONFIRMED' THEN e.MonthEnd END) AS MonthsConfirmed,
           SUM(CASE WHEN e.Status = 'CONFIRMED' AND e.CurrencyId = win.CurrencyId AND e.MonthEnd <= EOMONTH(@AsOf, -1) THEN e.Amount ELSE 0 END) AS AchievedElapsed
    FROM win
    JOIN fin.BankFlowEntry AS e ON e.TenantId = win.TenantId
     AND e.MonthEnd BETWEEN win.WindowStart AND CASE WHEN EOMONTH(@AsOf) < win.WindowEnd THEN EOMONTH(@AsOf) ELSE win.WindowEnd END
     AND (e.FacilityId IS NULL OR e.FacilityId = win.FacilityId)
     AND (e.CompanyId = win.TestedCompanyId
          OR EXISTS (SELECT 1 FROM obl.ObligationCompany AS oc WHERE oc.TenantId = win.TenantId AND oc.ObligationId = win.ObligationId AND oc.CompanyId = e.CompanyId))
     AND EXISTS (SELECT 1 FROM fac.FacilityLender AS l
                 JOIN fac.Facility AS f ON f.TenantId = l.TenantId AND f.FacilityId = l.FacilityId
                 WHERE l.TenantId = win.TenantId AND l.FacilityId = win.FacilityId AND l.InstitutionId = e.InstitutionId
                   AND l.FromRevision <= f.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo))
    GROUP BY win.TenantId, win.CovenantId
), rev AS (
    SELECT win.TenantId, win.CovenantId, r.Revenue, r.RevenueSource
    FROM win
    OUTER APPLY (SELECT TOP (1) r0.Revenue, r0.RevenueSource
                 FROM (SELECT ln.EnteredAmount AS Revenue, CONCAT('STATEMENT ', fs.FinancialStatementId) AS RevenueSource,
                              CASE fs.Assurance WHEN 'AUDITED' THEN 0 WHEN 'REVIEWED' THEN 1 ELSE 2 END AS Rank
                       FROM fin.FinancialStatement AS fs
                       JOIN fin.StatementLine AS ln ON ln.TenantId = fs.TenantId AND ln.StatementId = fs.FinancialStatementId
                       JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId AND li.Code = 'REVENUE'
                       WHERE win.MeasureKind = 'PERCENT_OF_REVENUE' AND win.RevenueBasisRule IN ('SAME_PERIOD','PRIOR_YEAR')
                         AND fs.TenantId = win.TenantId AND fs.CompanyId = win.TestedCompanyId AND fs.Basis = win.StatementBasis
                         AND fs.PeriodType = 'ANNUAL' AND fs.Status = 'APPROVED' AND fs.CurrencyId = win.CurrencyId
                         AND fs.PeriodEnd = CASE WHEN win.RevenueBasisRule = 'PRIOR_YEAR' THEN EOMONTH(win.FiscalYearEnd, -12) ELSE win.FiscalYearEnd END
                       UNION ALL
                       SELECT re.Amount, CONCAT('ESTIMATE ', re.RevenueEstimateId), 3
                       FROM fin.RevenueEstimate AS re
                       WHERE win.MeasureKind = 'PERCENT_OF_REVENUE' AND win.RevenueBasisRule = 'MANUAL_ESTIMATE'
                         AND re.TenantId = win.TenantId AND re.CompanyId = win.TestedCompanyId AND re.Basis = win.StatementBasis
                         AND re.FiscalYear = YEAR(win.FiscalYearEnd) AND re.Status = 'APPROVED' AND re.CurrencyId = win.CurrencyId) AS r0
                 ORDER BY r0.Rank) AS r
)
SELECT win.TenantId, win.CovenantId, win.CovenantRootId, win.ObligationId, win.FacilityId, win.TestedCompanyId AS CompanyId,
       win.MeasureKind, win.TestFrequency, win.WindowBasis, win.WindowStart, win.WindowEnd, win.CurrencyId,
       win.Operator, win.ThresholdValue, win.ThresholdUnit,
       ISNULL(fl.Achieved, 0) AS Achieved, ISNULL(fl.AwaitingConfirmation, 0) AS AwaitingConfirmation,
       ISNULL(fl.OtherCurrencyEntries, 0) AS OtherCurrencyEntries, ISNULL(fl.MonthsConfirmed, 0) AS MonthsConfirmed,
       mo.Elapsed AS MonthsElapsed, mo.InWindow AS MonthsInWindow,
       rv.Revenue, rv.RevenueSource, req.Required,
       CASE WHEN req.Required IS NULL THEN NULL WHEN req.Required > ISNULL(fl.Achieved, 0) THEN req.Required - ISNULL(fl.Achieved, 0) ELSE 0 END AS Remaining,
       CASE WHEN req.Required IS NULL OR req.Required <= ISNULL(fl.Achieved, 0) OR mo.InWindow - mo.Elapsed <= 0 THEN NULL
            ELSE (req.Required - ISNULL(fl.Achieved, 0)) / (mo.InWindow - mo.Elapsed) END AS RequiredPerRemainingMonth,
       CASE WHEN req.Required IS NULL OR req.Required = 0 THEN NULL ELSE CAST(ISNULL(fl.Achieved, 0) * 100 / req.Required AS DECIMAL(19,4)) END AS AchievementPct,
       CASE WHEN win.MeasureKind = 'PERCENT_OF_REVENUE' AND rv.Revenue IS NULL THEN 'NO_REVENUE'
            WHEN ISNULL(fl.MonthsConfirmed, 0) = 0 THEN 'NO_DATA'
            WHEN ISNULL(fl.Achieved, 0) >= req.Required THEN 'MET'
            WHEN ISNULL(fl.AchievedElapsed, 0) * mo.InWindow >= req.Required * mo.Elapsed THEN 'ON_TRACK'
            ELSE 'BEHIND' END AS PerformanceState,
       ISNULL(fl.AchievedElapsed, 0) AS AchievedElapsed
FROM win
LEFT JOIN flows AS fl ON fl.TenantId = win.TenantId AND fl.CovenantId = win.CovenantId
LEFT JOIN rev AS rv ON rv.TenantId = win.TenantId AND rv.CovenantId = win.CovenantId
-- the months of the window, and those of it complete on @AsOf (none before its first month ends)
CROSS APPLY (SELECT DATEDIFF(MONTH, win.WindowStart, win.WindowEnd) + 1 AS InWindow,
                    CASE WHEN EOMONTH(@AsOf, -1) < win.WindowStart THEN 0
                         ELSE DATEDIFF(MONTH, win.WindowStart, CASE WHEN EOMONTH(@AsOf, -1) < win.WindowEnd THEN EOMONTH(@AsOf, -1) ELSE win.WindowEnd END) + 1 END AS Elapsed) AS mo
CROSS APPLY (SELECT CASE WHEN win.MeasureKind = 'FLOW_VOLUME' THEN win.ThresholdValue
                         WHEN rv.Revenue IS NOT NULL
                         THEN CAST(rv.Revenue * win.ThresholdValue / 100 * (DATEDIFF(MONTH, win.WindowStart, win.WindowEnd) + 1) / 12.0 AS DECIMAL(19,4)) END AS Required) AS req;
GO
GRANT SELECT ON fin.v_StatementBreachReport TO [tp_app];
GRANT SELECT ON fin.v_ConsolidationUnits TO [tp_app];
GRANT SELECT ON fin.fn_BankFlowPerformance TO [tp_app];
GO

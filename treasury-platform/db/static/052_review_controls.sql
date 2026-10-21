/* 052_review_controls.sql — the controls the external review v3.0 asked for that fit a company assessing itself
   (ADR 0029, FR-FIN-042 to FR-FIN-044, BR-FIN-043 to BR-FIN-045).

   1. Endorsement for use outside the company (BR-FIN-043). An approved assessment is the company's internal view; it
      is shown outside (to a lender, a shareholder, a board) only once someone outside the line that prepared and
      approved it endorses it:
        fin.usp_EndorseCreditAssessment  a user bound to the tenant who holds fin.credit.endorse and holds neither
                                         fin.credit.assess nor fin.credit.approve, and who is neither the preparer nor
                                         the approver of the assessment, nor the preparer or approver of its statement,
                                         nor the user who chose the presentation version that became the statement
                                         (ADR 0037), endorses an approved (not superseded) assessment of an actual
                                         statement once, with the reason and scope of the endorsement. Error 50093.
      The default holder is AU (the internal auditor) by the role matrix of spec 12; the tenant may grant it to a
      CFO or an audit committee member instead. The report shows whether an assessment is endorsed
      (fin.v_CreditAssessmentReport.UseScope: ENDORSED or INTERNAL_ONLY).
   2. The reason for choosing a presentation version is required (048, BR-FIN-044).
   3. The calibration against the lenders over time (BR-FIN-045), defined in 049 since ADR 0030 so that the readiness
      reads it:
        fin.v_LenderRatingCalibration    for each company, and for each company and lender, every rating a lender
                                         communicated beside the assessment of its date (049): their number, the mean
                                         gap in notches (positive: the lender is more severe), the mean of the latest
                                         three, the latest gap, and the bias:
                                           INSUFFICIENT  fewer than three ratings;
                                           OPTIMISTIC    the company rates itself one notch or more above its lenders
                                                         on average;
                                           CONSERVATIVE  one notch or more below them;
                                           ALIGNED       otherwise.
   Added by ADR 0030 (the study of the review v4.0, docs/38; owner decision 35):
   4. Confirmed monthly figures stay as confirmed (BR-FIN-048). A CONFIRMED row of fin.AccountMonthlyStat or
      fin.BankFlowEntry is neither changed nor deleted (50094); fin.usp_ReopenMonthlyFigure returns it to DRAFT with
      a reason, by a user who holds fin.stats.confirm and did not enter it, counted and audited (MONTHLY_FIGURE_REOPENED).
   5. The evidence pack of an endorsed assessment (BR-FIN-049). fin.usp_BuildAssessmentEvidencePack gives one JSON
      document of an endorsed assessment that is still the approved one (not superseded, not a trial): the report, the
      hash of what the computation read (InputsHash) and its snapshot, the analyst's inputs (qualitative grades,
      sub-factors, group support, override, market size, rates, evidence, each with its justification and the SHA-256
      of its document's current version when one is stored), the guarantors and the bureau report, the facilities and
      collateral the computation read, the scorecard by code and version with the SHA-256 of its weights, grids,
      adjustments and parameters, the statement and its versions, its lines, the factors, findings, reconciliation,
      remedies, scenarios, the covenant tests of the statement, the lender ratings and the calibration, the provision
      check, the close of the period and the audit rows of the assessment and statements (ADR 0037). Its SHA-256 is
      logged in fin.AssessmentEvidencePack with its purpose; the same content gives the same hash. Error 50095. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER PROCEDURE fin.usp_EndorseCreditAssessment
    @AssessmentId BIGINT,
    @Note         NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @t INT = CAST(SESSION_CONTEXT(N'TenantId') AS INT), @user BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
            @status VARCHAR(10), @trial BIT, @prep BIGINT, @appr BIGINT, @endorsed BIGINT, @nature VARCHAR(6),
            @sprep BIGINT, @sappr BIGINT, @chooser BIGINT;
    IF @t IS NULL OR @user IS NULL OR NOT EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@t, 0))
        THROW 50093, 'An assessment is endorsed by a user bound to its tenant', 1;
    IF NULLIF(LTRIM(RTRIM(@Note)), N'') IS NULL THROW 50093, 'An endorsement says why and for whom the assessment is shown outside the company', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.credit.endorse'))
        THROW 50093, 'The permission fin.credit.endorse is required', 1;
    IF EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.credit.assess'))
       OR EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.credit.approve'))
        THROW 50093, 'The endorser is outside the line that prepares and approves assessments (holds neither fin.credit.assess nor fin.credit.approve)', 1;
    BEGIN TRANSACTION;
    SELECT @status = a.Status, @trial = a.IsTrial, @prep = a.PreparedBy, @appr = a.ApprovedBy, @endorsed = a.EndorsedBy, @nature = s.Nature,
           @sprep = s.PreparedBy, @sappr = s.ApprovedBy,
           @chooser = (SELECT TOP (1) v.ChosenBy FROM fin.PresentationVersion AS v
                       WHERE v.TenantId = s.TenantId AND v.ResultStatementId = s.FinancialStatementId AND v.Status = 'CHOSEN')
    FROM fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK)
    JOIN fin.FinancialStatement AS s ON s.TenantId = a.TenantId AND s.FinancialStatementId = a.StatementId
    WHERE a.TenantId = @t AND a.CreditAssessmentId = @AssessmentId;
    IF @status IS NULL THROW 50093, 'No assessment with this id for this tenant', 1;
    IF @status <> 'APPROVED' OR @trial = 1 OR @nature <> 'ACTUAL'
        THROW 50093, 'Only an approved assessment of an actual statement is endorsed (a trial or a budget stays internal)', 1;
    IF @endorsed IS NOT NULL THROW 50093, 'The assessment is already endorsed', 1;
    IF @user IN (@prep, @appr) THROW 50093, 'The endorser is neither the preparer nor the approver of the assessment', 1;
    IF @user IN (@sprep, @sappr) OR @user = @chooser
        THROW 50093, 'The endorser neither prepared nor approved the statement, nor chose the presentation that became it (ADR 0037)', 1;
    -- the calibration of that day is kept with the endorsement and shown with the report (ADR 0030)
    UPDATE a SET EndorsedBy = @user, EndorsedOn = SYSUTCDATETIME(), EndorsementNote = LTRIM(RTRIM(@Note)),
                 EndorsedBias = ISNULL(c.Bias, 'INSUFFICIENT'), EndorsedRatings = ISNULL(c.Ratings, 0),
                 EndorsedLastRatingDate = (SELECT MAX(r.RatingDate) FROM fin.LenderRating AS r WHERE r.TenantId = a.TenantId AND r.CompanyId = a.CompanyId),
                 UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @user
    FROM fin.CreditAssessment AS a
    LEFT JOIN fin.v_LenderRatingCalibration AS c ON c.TenantId = a.TenantId AND c.CompanyId = a.CompanyId AND c.AllLenders = 1
    WHERE a.TenantId = @t AND a.CreditAssessmentId = @AssessmentId;
    COMMIT;
END;
GO
GRANT EXECUTE ON fin.usp_EndorseCreditAssessment TO [tp_app];
DENY UPDATE ON [fin].[CreditAssessment] ([EndorsedBy], [EndorsedOn], [EndorsementNote], [EndorsedBias], [EndorsedRatings], [EndorsedLastRatingDate]) TO [tp_app];
GO
/* ---------- 4. Confirmed monthly figures (ADR 0030) ---------- */
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);
INSERT @may VALUES (N'Status'), (N'ConfirmedBy'), (N'ConfirmedOn'), (N'ReopenCount'), (N'LastReopenedBy'), (N'LastReopenedOn'), (N'LastReopenReason'),
                   (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'fin.AccountMonthlyStat') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SET @sql = N'CREATE OR ALTER TRIGGER fin.TR_AccountMonthlyStat_ConfirmedFrozen ON fin.AccountMonthlyStat
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d LEFT JOIN inserted AS i ON i.AccountMonthlyStatId = d.AccountMonthlyStatId
               WHERE d.Status = ''CONFIRMED''
                 AND (i.AccountMonthlyStatId IS NULL
                      OR NOT (i.Status = d.Status AND i.ReopenCount = d.ReopenCount
                              OR (i.Status = ''DRAFT'' AND i.ReopenCount = d.ReopenCount + 1 AND i.LastReopenReason IS NOT NULL
                                  AND i.LastReopenedOn > ISNULL(d.LastReopenedOn, ''19000101'')))
                      OR EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')
                      OR (i.Status = d.Status AND (ISNULL(i.ConfirmedBy, -1) <> ISNULL(d.ConfirmedBy, -1) OR ISNULL(i.ConfirmedOn, ''19000101'') <> ISNULL(d.ConfirmedOn, ''19000101'')))))
        THROW 50094, ''A confirmed monthly figure is neither changed nor deleted; it is reopened with a reason by someone other than its author (BR-FIN-048)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);
INSERT @may VALUES (N'Status'), (N'ConfirmedBy'), (N'ConfirmedOn'), (N'ReopenCount'), (N'LastReopenedBy'), (N'LastReopenedOn'), (N'LastReopenReason'),
                   (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'fin.BankFlowEntry') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SET @sql = N'CREATE OR ALTER TRIGGER fin.TR_BankFlowEntry_ConfirmedFrozen ON fin.BankFlowEntry
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d LEFT JOIN inserted AS i ON i.BankFlowEntryId = d.BankFlowEntryId
               WHERE d.Status = ''CONFIRMED''
                 AND (i.BankFlowEntryId IS NULL
                      OR NOT (i.Status = d.Status AND i.ReopenCount = d.ReopenCount
                              OR (i.Status = ''DRAFT'' AND i.ReopenCount = d.ReopenCount + 1 AND i.LastReopenReason IS NOT NULL
                                  AND i.LastReopenedOn > ISNULL(d.LastReopenedOn, ''19000101'')))
                      OR EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')
                      OR (i.Status = d.Status AND (ISNULL(i.ConfirmedBy, -1) <> ISNULL(d.ConfirmedBy, -1) OR ISNULL(i.ConfirmedOn, ''19000101'') <> ISNULL(d.ConfirmedOn, ''19000101'')))))
        THROW 50094, ''A confirmed monthly figure is neither changed nor deleted; it is reopened with a reason by someone other than its author (BR-FIN-048)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
DENY UPDATE ON [fin].[AccountMonthlyStat] ([ReopenCount], [LastReopenedBy], [LastReopenedOn], [LastReopenReason]) TO [tp_app];
DENY UPDATE ON [fin].[BankFlowEntry] ([ReopenCount], [LastReopenedBy], [LastReopenedOn], [LastReopenReason]) TO [tp_app];
GO
/* Returns a confirmed balance (@Kind BALANCE) or bank flow (@Kind FLOW) to a draft, with its reason. */
CREATE OR ALTER PROCEDURE fin.usp_ReopenMonthlyFigure
    @Kind   VARCHAR(7),
    @Id     BIGINT,
    @Reason NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @t INT = CAST(SESSION_CONTEXT(N'TenantId') AS INT), @user BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
            @author BIGINT, @status VARCHAR(10), @n INT, @before NVARCHAR(400), @after NVARCHAR(800);
    IF @t IS NULL OR @user IS NULL OR NOT EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@t, 1))
        THROW 50094, 'A monthly figure is reopened by a user bound to its tenant', 1;
    IF @Kind NOT IN ('BALANCE', 'FLOW') THROW 50094, 'The kind is BALANCE or FLOW', 1;
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 50094, 'A confirmed monthly figure is reopened with a reason', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.stats.confirm'))
        THROW 50094, 'The permission fin.stats.confirm is required', 1;
    BEGIN TRANSACTION;
    IF @Kind = 'BALANCE'
        SELECT @status = Status, @author = ISNULL(EnteredBy, CreatedBy), @n = ReopenCount
        FROM fin.AccountMonthlyStat WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @t AND AccountMonthlyStatId = @Id;
    ELSE
        SELECT @status = Status, @author = ISNULL(EnteredBy, CreatedBy), @n = ReopenCount
        FROM fin.BankFlowEntry WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @t AND BankFlowEntryId = @Id;
    IF @status IS NULL THROW 50094, 'No monthly figure with this id for this tenant', 1;
    IF @status <> 'CONFIRMED' THROW 50094, 'Only a confirmed monthly figure is reopened', 1;
    IF @user = @author THROW 50094, 'A monthly figure is reopened by someone other than its author', 1;
    IF @Kind = 'BALANCE'
        UPDATE fin.AccountMonthlyStat
        SET Status = 'DRAFT', ConfirmedBy = NULL, ConfirmedOn = NULL, ReopenCount = ReopenCount + 1, LastReopenedBy = @user,
            LastReopenedOn = SYSUTCDATETIME(), LastReopenReason = LTRIM(RTRIM(@Reason)), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @user
        WHERE TenantId = @t AND AccountMonthlyStatId = @Id;
    ELSE
        UPDATE fin.BankFlowEntry
        SET Status = 'DRAFT', ConfirmedBy = NULL, ConfirmedOn = NULL, ReopenCount = ReopenCount + 1, LastReopenedBy = @user,
            LastReopenedOn = SYSUTCDATETIME(), LastReopenReason = LTRIM(RTRIM(@Reason)), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @user
        WHERE TenantId = @t AND BankFlowEntryId = @Id;
    SET @before = (SELECT 'CONFIRMED' AS status, @n AS reopenCount FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    SET @after = (SELECT 'DRAFT' AS status, @n + 1 AS reopenCount, LTRIM(RTRIM(@Reason)) AS reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @entity VARCHAR(60) = CASE @Kind WHEN 'BALANCE' THEN 'fin.AccountMonthlyStat' ELSE 'fin.BankFlowEntry' END;
    EXEC aud.usp_WriteEvent @TenantId = @t, @Action = 'MONTHLY_FIGURE_REOPENED', @Category = 'TREASURY', @ActorType = 'USER',
         @ActorUserId = @user, @Severity = 'HIGH', @EntityType = @entity, @EntityId = @Id, @BeforeJson = @before, @AfterJson = @after;
    COMMIT;
END;
GO
GRANT EXECUTE ON fin.usp_ReopenMonthlyFigure TO [tp_app];
GO
/* ---------- 5. The evidence pack of an endorsed assessment (ADR 0030) ---------- */
CREATE OR ALTER PROCEDURE fin.usp_BuildAssessmentEvidencePack
    @AssessmentId BIGINT,
    @Purpose      NVARCHAR(500),
    @Pack         NVARCHAR(MAX) = NULL OUTPUT,
    @Sha256       VARBINARY(32) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @t INT = CAST(SESSION_CONTEXT(N'TenantId') AS INT), @user BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
            @stmt BIGINT, @company BIGINT, @endorsed BIGINT, @id BIGINT, @status VARCHAR(10), @trial BIT, @card INT;
    SELECT @Pack = NULL, @Sha256 = NULL;
    IF @t IS NULL OR @user IS NULL OR NOT EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@t, 1))
        THROW 50095, 'An evidence pack is built by a user bound to the tenant', 1;
    IF NULLIF(LTRIM(RTRIM(@Purpose)), N'') IS NULL THROW 50095, 'An evidence pack names its purpose: for whom and why', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.credit.endorse'))
       AND NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.credit.approve'))
        THROW 50095, 'The permission fin.credit.endorse or fin.credit.approve is required', 1;
    SELECT @stmt = StatementId, @company = CompanyId, @endorsed = EndorsedBy, @status = Status, @trial = IsTrial, @card = ScorecardId
    FROM fin.CreditAssessment WHERE TenantId = @t AND CreditAssessmentId = @AssessmentId;
    IF @stmt IS NULL THROW 50095, 'No assessment with this id for this tenant', 1;
    IF @endorsed IS NULL THROW 50095, 'Only an endorsed assessment leaves the company in an evidence pack (BR-FIN-043)', 1;
    IF @status <> 'APPROVED' OR @trial = 1
        THROW 50095, 'An evidence pack is built of the approved assessment only; a superseded one has been replaced (ADR 0037)', 1;
    -- the statement and every version it supersedes
    DECLARE @chain TABLE (StatementId BIGINT PRIMARY KEY, Depth INT);
    WITH c AS (SELECT FinancialStatementId, SupersedesId, 0 AS Depth FROM fin.FinancialStatement WHERE TenantId = @t AND FinancialStatementId = @stmt
               UNION ALL
               SELECT s.FinancialStatementId, s.SupersedesId, c.Depth + 1 FROM fin.FinancialStatement AS s JOIN c ON s.FinancialStatementId = c.SupersedesId
               WHERE s.TenantId = @t)
    INSERT @chain SELECT FinancialStatementId, Depth FROM c OPTION (MAXRECURSION 100);
    SET @Pack = (SELECT
        'BankFas assessment evidence pack v1' AS format,
        JSON_QUERY((SELECT * FROM fin.v_CreditAssessmentReport WHERE TenantId = @t AND CreditAssessmentId = @AssessmentId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)) AS assessment,
        -- what the computation read, as it recorded it (ADR 0037)
        (SELECT InputsHash FROM fin.CreditAssessment WHERE TenantId = @t AND CreditAssessmentId = @AssessmentId) AS inputsHash,
        JSON_QUERY((SELECT Snapshot FROM fin.CreditAssessment WHERE TenantId = @t AND CreditAssessmentId = @AssessmentId AND ISJSON(Snapshot) = 1)) AS snapshot,
        (SELECT i.Kind, m.Code AS MetricCode, sf.Code AS SubfactorCode, g.Code AS Grade, i.Notches, i.ParentAssessmentId, i.Amount, cu.Code AS Currency, i.Rate,
                i.EvidenceCode, i.Justification, i.DocumentId, CONVERT(VARCHAR(64), dv.Sha256, 2) AS DocumentSha256, i.EnteredBy
         FROM fin.CreditAssessmentInput AS i
         LEFT JOIN fin.CreditMetric AS m ON m.CreditMetricId = i.MetricId
         LEFT JOIN fin.ScorecardSubfactor AS sf ON sf.ScorecardSubfactorId = i.SubfactorId
         LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = i.GradeId
         LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = i.CurrencyId
         LEFT JOIN doc.Document AS d ON d.TenantId = i.TenantId AND d.DocumentId = i.DocumentId
         LEFT JOIN doc.DocumentVersion AS dv ON dv.TenantId = d.TenantId AND dv.DocumentVersionId = d.CurrentVersionId
         WHERE i.TenantId = @t AND i.AssessmentId = @AssessmentId
         ORDER BY i.Kind, i.MetricId, i.SubfactorId, i.CurrencyId, i.EvidenceCode FOR JSON PATH, INCLUDE_NULL_VALUES) AS inputs,
        (SELECT g.PartyId, g.NetWorth, g.LiquidAssets, g.GuaranteesGiven, g.GuaranteedAmount, g.AsOfDate, g.DocumentId, CONVERT(VARCHAR(64), dv.Sha256, 2) AS DocumentSha256
         FROM fin.CreditAssessmentGuarantor AS g
         LEFT JOIN doc.Document AS d ON d.TenantId = g.TenantId AND d.DocumentId = g.DocumentId
         LEFT JOIN doc.DocumentVersion AS dv ON dv.TenantId = d.TenantId AND dv.DocumentVersionId = d.CurrentVersionId
         WHERE g.TenantId = @t AND g.AssessmentId = @AssessmentId ORDER BY g.PartyId FOR JSON PATH) AS guarantors,
        JSON_QUERY((SELECT b.ReportDate, b.DocumentId, CONVERT(VARCHAR(64), dv.Sha256, 2) AS DocumentSha256, b.TotalLimits, b.TotalOutstanding, b.LenderCount,
                           b.WorstDpd12m, b.WorstDpd24m, b.CurrentDefault, b.Defaults24mCount, b.Defaults24mAmount, b.BouncedCheques12mCount,
                           b.BouncedCheques12mAmount, b.JudgmentsCount, b.JudgmentsAmount, b.Inquiries6m, b.Restructured
                    FROM fin.CreditAssessmentBureau AS b
                    LEFT JOIN doc.Document AS d ON d.TenantId = b.TenantId AND d.DocumentId = b.DocumentId
                    LEFT JOIN doc.DocumentVersion AS dv ON dv.TenantId = d.TenantId AND dv.DocumentVersionId = d.CurrentVersionId
                    WHERE b.TenantId = @t AND b.AssessmentId = @AssessmentId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS bureau,
        (SELECT * FROM fin.v_CreditAssessmentFacilities WHERE TenantId = @t AND AssessmentId = @AssessmentId ORDER BY FacilityId FOR JSON PATH) AS facilities,
        -- the methodology by code and version, and the SHA-256 of its weights, grids, adjustments and parameters
        JSON_QUERY((SELECT sc.Code, sc.VersionNo,
                           CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONCAT(
                               (SELECT sm.MetricId, sm.FactorCode, sm.Weight, sm.B0, sm.B1, sm.B2, sm.B3, sm.B4, sm.B5, sm.B6, sm.B7, sm.B8
                                FROM fin.ScorecardMetric AS sm WHERE sm.ScorecardId = sc.ScorecardId ORDER BY sm.MetricId FOR JSON PATH), '|',
                               (SELECT ad.RuleCode, ad.Stage, ad.Notches, ad.CapGradeId, ad.ParamValue, ad.IsActive FROM fin.ScorecardAdjustment AS ad WHERE ad.ScorecardId = sc.ScorecardId ORDER BY ad.RuleCode FOR JSON PATH), '|',
                               (SELECT p.GroupCode, p.ParamKey, p.Value, p.Value2 FROM fin.ScorecardParameter AS p WHERE p.ScorecardId = sc.ScorecardId
                                ORDER BY p.GroupCode, p.ParamKey FOR JSON PATH))), 2) AS MethodologySha256
                    FROM fin.Scorecard AS sc WHERE sc.ScorecardId = @card FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS scorecard,
        (SELECT s.FinancialStatementId AS statementId, s.VersionNo, s.VersionReason, s.SupersedesId, s.Status, s.Nature, s.Basis, s.PeriodType, s.PeriodEnd,
                s.Assurance, s.AuditorName, s.AuditOpinion, s.PreparedBy, s.PreparedOn, s.ApprovedBy, s.ApprovedOn, ch.Depth
         FROM @chain AS ch JOIN fin.FinancialStatement AS s ON s.TenantId = @t AND s.FinancialStatementId = ch.StatementId
         ORDER BY ch.Depth FOR JSON PATH, INCLUDE_NULL_VALUES) AS statementVersions,
        (SELECT li.Code, ln.EnteredAmount, ln.ComputedAmount FROM fin.StatementLine AS ln
         JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
         WHERE ln.TenantId = @t AND ln.StatementId = @stmt ORDER BY li.Code FOR JSON PATH) AS statementLines,
        (SELECT * FROM fin.v_CreditAssessmentFactors WHERE TenantId = @t AND AssessmentId = @AssessmentId ORDER BY SortOrder, MetricCode FOR JSON PATH) AS factors,
        (SELECT x.Kind, x.Source, x.RuleCode, x.LineCode, x.Notches, x.TextAr, x.TextEn, x.SeqNo FROM fin.CreditAssessmentFinding AS x
         WHERE x.TenantId = @t AND x.AssessmentId = @AssessmentId ORDER BY x.Kind, x.SeqNo, x.RuleCode FOR JSON PATH) AS findings,
        (SELECT * FROM fin.v_CreditAssessmentReclass WHERE TenantId = @t AND AssessmentId = @AssessmentId ORDER BY SeqNo FOR JSON PATH) AS reconciliation,
        (SELECT * FROM fin.v_CreditAssessmentRemedies WHERE TenantId = @t AND AssessmentId = @AssessmentId ORDER BY SeqNo FOR JSON PATH) AS remedies,
        (SELECT * FROM fin.v_CreditAssessmentScenarios WHERE TenantId = @t AND AssessmentId = @AssessmentId ORDER BY SortOrder, Scenario FOR JSON PATH) AS scenarios,
        (SELECT * FROM fin.v_CreditAssessmentCovenants WHERE TenantId = @t AND AssessmentId = @AssessmentId ORDER BY CovenantTestId FOR JSON PATH) AS covenants,
        (SELECT * FROM fin.v_LenderRatingComparison WHERE TenantId = @t AND CompanyId = @company ORDER BY RatingDate, LenderRatingId FOR JSON PATH) AS lenderRatings,
        (SELECT * FROM fin.v_LenderRatingCalibration WHERE TenantId = @t AND CompanyId = @company ORDER BY AllLenders DESC, LenderInstitutionId FOR JSON PATH) AS calibration,
        JSON_QUERY((SELECT * FROM fin.v_ReceivableProvisionCheck WHERE TenantId = @t AND StatementId = @stmt FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS provisionCheck,
        JSON_QUERY((SELECT CONVERT(CHAR(10), MAX(l.LockedThrough), 23) AS lockedThrough,
                           CAST(CASE WHEN MAX(l.LockedThrough) >= (SELECT PeriodEnd FROM fin.FinancialStatement WHERE TenantId = @t AND FinancialStatementId = @stmt)
                                     THEN 1 ELSE 0 END AS BIT) AS statementPeriodClosed
                    FROM fin.ReportingPeriodLock AS l WHERE l.TenantId = @t AND l.CompanyId = @company AND l.Status = 'LOCKED'
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)) AS periodClose,   -- 053, ADR 0031
        (SELECT l.AuditLogId, l.OccurredAt, l.Action, l.ActorType, l.ActorId, l.EntityType, l.EntityId
         FROM aud.AuditLog AS l
         WHERE l.TenantId = @t AND l.Action <> 'EVIDENCE_PACK_BUILT'   -- the packs themselves are in fin.AssessmentEvidencePack
           AND ((l.EntityType = 'fin.CreditAssessment' AND l.EntityId = @AssessmentId)
                                     OR (l.EntityType = 'fin.FinancialStatement' AND l.EntityId IN (SELECT StatementId FROM @chain)))
         ORDER BY l.AuditLogId FOR JSON PATH) AS auditRows
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    SET @Sha256 = HASHBYTES('SHA2_256', @Pack);
    BEGIN TRANSACTION;
    INSERT fin.AssessmentEvidencePack (TenantId, AssessmentId, Purpose, Sha256, ContentChars, GeneratedBy)
    VALUES (@t, @AssessmentId, LTRIM(RTRIM(@Purpose)), @Sha256, LEN(@Pack), @user);
    SET @id = SCOPE_IDENTITY();
    DECLARE @after NVARCHAR(600) = (SELECT CONVERT(VARCHAR(64), @Sha256, 2) AS sha256, LTRIM(RTRIM(@Purpose)) AS purpose FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC aud.usp_WriteEvent @TenantId = @t, @Action = 'EVIDENCE_PACK_BUILT', @Category = 'TREASURY', @ActorType = 'USER', @ActorUserId = @user,
         @Severity = 'HIGH', @EntityType = 'fin.CreditAssessment', @EntityId = @AssessmentId, @AfterJson = @after;
    COMMIT;
END;
GO
GRANT EXECUTE ON fin.usp_BuildAssessmentEvidencePack TO [tp_app];
DENY INSERT, UPDATE, DELETE ON fin.AssessmentEvidencePack TO [tp_app];
GO

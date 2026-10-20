/* 052_review_controls.sql — the controls the external review v3.0 asked for that fit a company assessing itself
   (ADR 0029, FR-FIN-042 to FR-FIN-044, BR-FIN-043 to BR-FIN-045).

   1. Endorsement for use outside the company (BR-FIN-043). An approved assessment is the company's internal view; it
      is shown outside (to a lender, a shareholder, a board) only once someone outside the line that prepared and
      approved it endorses it:
        fin.usp_EndorseCreditAssessment  a user bound to the tenant who holds fin.credit.endorse and holds neither
                                         fin.credit.assess nor fin.credit.approve, and who is neither the preparer nor
                                         the approver, endorses an approved assessment of an actual statement once,
                                         with the reason and scope of the endorsement. Error 50093.
      The default holder is AU (the internal auditor) by the role matrix of spec 12; the tenant may grant it to a
      CFO or an audit committee member instead. The report shows whether an assessment is endorsed
      (fin.v_CreditAssessmentReport.UseScope: ENDORSED or INTERNAL_ONLY).
   2. The reason for choosing a presentation version is required (048, BR-FIN-044).
   3. The calibration against the lenders over time (BR-FIN-045):
        fin.v_LenderRatingCalibration    for each company, and for each company and lender, every rating a lender
                                         communicated beside the assessment of its date (049): their number, the mean
                                         gap in notches (positive: the lender is more severe), the mean of the latest
                                         three, the latest gap, and the bias:
                                           INSUFFICIENT  fewer than three ratings;
                                           OPTIMISTIC    the company rates itself one notch or more above its lenders
                                                         on average;
                                           CONSERVATIVE  one notch or more below them;
                                           ALIGNED       otherwise. */
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
            @status VARCHAR(10), @trial BIT, @prep BIGINT, @appr BIGINT, @endorsed BIGINT, @nature VARCHAR(6);
    IF @t IS NULL OR @user IS NULL OR NOT EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@t, 0))
        THROW 50093, 'An assessment is endorsed by a user bound to its tenant', 1;
    IF NULLIF(LTRIM(RTRIM(@Note)), N'') IS NULL THROW 50093, 'An endorsement says why and for whom the assessment is shown outside the company', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.credit.endorse'))
        THROW 50093, 'The permission fin.credit.endorse is required', 1;
    IF EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.credit.assess'))
       OR EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.credit.approve'))
        THROW 50093, 'The endorser is outside the line that prepares and approves assessments (holds neither fin.credit.assess nor fin.credit.approve)', 1;
    BEGIN TRANSACTION;
    SELECT @status = a.Status, @trial = a.IsTrial, @prep = a.PreparedBy, @appr = a.ApprovedBy, @endorsed = a.EndorsedBy, @nature = s.Nature
    FROM fin.CreditAssessment AS a WITH (UPDLOCK, HOLDLOCK)
    JOIN fin.FinancialStatement AS s ON s.TenantId = a.TenantId AND s.FinancialStatementId = a.StatementId
    WHERE a.TenantId = @t AND a.CreditAssessmentId = @AssessmentId;
    IF @status IS NULL THROW 50093, 'No assessment with this id for this tenant', 1;
    IF @status <> 'APPROVED' OR @trial = 1 OR @nature <> 'ACTUAL'
        THROW 50093, 'Only an approved assessment of an actual statement is endorsed (a trial or a budget stays internal)', 1;
    IF @endorsed IS NOT NULL THROW 50093, 'The assessment is already endorsed', 1;
    IF @user IN (@prep, @appr) THROW 50093, 'The endorser is neither the preparer nor the approver of the assessment', 1;
    UPDATE fin.CreditAssessment SET EndorsedBy = @user, EndorsedOn = SYSUTCDATETIME(), EndorsementNote = LTRIM(RTRIM(@Note)),
                                    UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @user
    WHERE TenantId = @t AND CreditAssessmentId = @AssessmentId;
    COMMIT;
END;
GO
GRANT EXECUTE ON fin.usp_EndorseCreditAssessment TO [tp_app];
DENY UPDATE ON [fin].[CreditAssessment] ([EndorsedBy], [EndorsedOn], [EndorsementNote]) TO [tp_app];
GO
CREATE OR ALTER VIEW fin.v_LenderRatingCalibration
AS
WITH c AS (
    SELECT r.TenantId, r.CompanyId, r.LenderInstitutionId, r.RatingDate, r.GapNotches, r.Direction,
           ROW_NUMBER() OVER (PARTITION BY r.TenantId, r.CompanyId ORDER BY r.RatingDate DESC, r.LenderRatingId DESC) AS RecentCompany,
           ROW_NUMBER() OVER (PARTITION BY r.TenantId, r.CompanyId, r.LenderInstitutionId ORDER BY r.RatingDate DESC, r.LenderRatingId DESC) AS RecentLender
    FROM fin.v_LenderRatingComparison AS r
    WHERE r.Direction <> 'NO_ASSESSMENT'),
k AS (   -- each rating once for its company (all lenders) and once for its company and lender
    SELECT TenantId, CompanyId, CAST(NULL AS BIGINT) AS LenderInstitutionId, CAST(1 AS BIT) AS AllLenders, RatingDate, GapNotches, Direction, RecentCompany AS Recent FROM c
    UNION ALL
    SELECT TenantId, CompanyId, LenderInstitutionId, CAST(0 AS BIT), RatingDate, GapNotches, Direction, RecentLender FROM c),
g AS (
    SELECT TenantId, CompanyId, LenderInstitutionId, AllLenders, COUNT(*) AS Ratings, MIN(RatingDate) AS FirstRatingDate, MAX(RatingDate) AS LastRatingDate,
           CAST(AVG(CAST(GapNotches AS DECIMAL(9,4))) AS DECIMAL(9,2)) AS MeanGapNotches,
           CAST(AVG(CASE WHEN Recent <= 3 THEN CAST(GapNotches AS DECIMAL(9,4)) END) AS DECIMAL(9,2)) AS RecentMeanGapNotches,
           MAX(CASE WHEN Recent = 1 THEN GapNotches END) AS LatestGapNotches,
           SUM(CASE WHEN Direction = 'LENDER_MORE_SEVERE' THEN 1 ELSE 0 END) AS LenderMoreSevere,
           SUM(CASE WHEN Direction = 'LENDER_MORE_FAVOURABLE' THEN 1 ELSE 0 END) AS LenderMoreFavourable,
           SUM(CASE WHEN Direction = 'SAME' THEN 1 ELSE 0 END) AS Same
    FROM k
    GROUP BY TenantId, CompanyId, LenderInstitutionId, AllLenders)
SELECT TenantId, CompanyId, LenderInstitutionId, AllLenders, Ratings, FirstRatingDate, LastRatingDate, MeanGapNotches, RecentMeanGapNotches,
       LatestGapNotches, LenderMoreSevere, LenderMoreFavourable, Same,
       CASE WHEN Ratings < 3 THEN 'INSUFFICIENT' WHEN MeanGapNotches >= 1 THEN 'OPTIMISTIC' WHEN MeanGapNotches <= -1 THEN 'CONSERVATIVE'
            ELSE 'ALIGNED' END AS Bias
FROM g;
GO
GRANT SELECT ON fin.v_LenderRatingCalibration TO [tp_app];
GO

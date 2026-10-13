/* ============================================================================
   BankFas - 044: the entry conditions of the slices, from the design review (O-15, batch B;
   docs/32-review-findings-decisions.md section 5, docs/adr/0011-design-review-fixes.md)

   Each finding of batch B must hold before its slice's code. The model carries the declarative part (columns,
   composite keys, checks); what a check cannot see is here:
     DR-22 (S1-b)  org.Shareholding: an indirect holding is entered per path through a named intermediate, and the
                   intermediate is never a company of the tenant, whose paths come from its own direct holdings
                   (BR-ORG-008). A party used as an intermediate in an open path becomes a company of the tenant only
                   after those paths are closed.
     DR-28 (S2)    the revisions of a facility (BR-FAC-003): Facility.ApprovedRevisionNo names an APPROVED row of
                   fac.FacilityRevision and only moves forward; an approved revision stays approved. When a revision
                   is approved, every revisioned row valid at it (FromRevision <= a < ToRevision) is the only row of its
                   node valid at it (the node is RootId, the stable identity the generator gives every revisioned
                   table, DQ-F13-4), and every such row that names a revisioned parent names a parent row valid at it.
                   The lender shares of the same approval are checked by 050.
     DR-27 (S2)    fac.ValueConflict: the target row exists in the tenant's table that TargetEntity names, and the
                   conflict carries the target's facility when the target belongs to one (a collateral and a tariff
                   item belong to none; a formula template may), so an open conflict blocks the right approval
                   (FR-FAC-026).
     DR-36 (S2)    col.Collateral versions share RootId, the id of the first version, through a composite key; the
                   model allows one current approved version and one open draft per collateral. A link names the
                   collateral by its root, so a new approved version needs no relinking.
     DR-39 (S2-b)  obl.CovenantTest: an evaluated test changes only by its review, an automatic evaluation names the
                   formula version it used and stores every input, threshold and operator it read (BR-FIN-010); and
                   obl.ReportingInstance: an item that left SCHEDULED keeps its status, obligation and period.
     DR-41 (S3)    lc.LcTerms, its clauses and charges, and wfl.WorkflowTemplate and its parts: a version is written as a
                   draft and frozen once locked or published, but for the treasury fields of locked terms until
                   TreasuryHash (BR-LCT-019) and the retirement of a published template.
     DR-49 (S3)    the versions of a template key belong to one request type (one current template per type is a key).
     DR-44 (S3)    wfl.Request: the copies of the current stage instance and of the reservation are written by the
                   database only, and wfl.RequestCopyDrift lists any that differ.
     DR-46 (S3)    a restricted LC field is never copied into a comparison line or an amendment's changed fields.
     DR-41 (S4)    lc.ProformaLine: lines written once, and the proforma totals follow them (BR-LCE-001).

   An error raised in a trigger ends the caller's transaction; the application validates first.
   Errors: 50047 an indirect path through a company of the tenant, 50048 a conflict on a missing target or with
   another facility than its target's, 50049 an approved revision that is missing,
   unapproved or moved back, 50050 a revision approved with two rows of one node or a row whose parent is not in it,
   50052 a collateral link to a version that is not the first, 50053 an evaluated covenant test changed other than by
   its review, 50054 an automatic evaluation without its formula version or with an incomplete snapshot, 50055 a final
   agenda item changed, 50056 locked LC terms, clauses or charges changed, 50057 a published template version or its
   parts changed, or a template key used by two request types, 50058 a restricted field's value copied, 50059 proforma
   lines written twice or totals that do not follow them.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
/* DR-22 */
CREATE OR ALTER TRIGGER org.TR_Shareholding_Intermediate ON org.Shareholding
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN org.Company AS c ON c.TenantId = i.TenantId AND c.PartyId = i.IntermediatePartyId)
        THROW 50047, 'An indirect path does not pass through a company of the tenant: it follows from that company''s own holdings (BR-ORG-008)', 1;
END;
GO
CREATE OR ALTER TRIGGER org.TR_Company_NotIntermediate ON org.Company
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS c
               LEFT JOIN deleted AS d ON d.TenantId = c.TenantId AND d.CompanyId = c.CompanyId
               JOIN org.Shareholding AS s ON s.TenantId = c.TenantId AND s.IntermediatePartyId = c.PartyId
               WHERE s.EffectiveTo IS NULL AND (d.CompanyId IS NULL OR d.PartyId <> c.PartyId))
        THROW 50047, 'This party is the intermediate of an open indirect holding: close those paths before it becomes a company of the tenant (BR-ORG-008)', 1;
END;
GO
/* DR-28 */
CREATE OR ALTER TRIGGER fac.TR_FacilityRevision_ApprovedFinal ON fac.FacilityRevision
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d
               JOIN inserted AS i ON i.TenantId = d.TenantId AND i.FacilityRevisionId = d.FacilityRevisionId
               WHERE d.Status = 'APPROVED'
                 AND (i.Status <> 'APPROVED' OR i.RevisionNo <> d.RevisionNo OR i.FacilityId <> d.FacilityId))
        THROW 50049, 'An approved facility revision stays approved; a change is a new revision (BR-FAC-003)', 1;
END;
GO
CREATE OR ALTER TRIGGER fac.TR_Facility_RevisionIntegrity ON fac.Facility
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i
               LEFT JOIN deleted AS d ON d.TenantId = i.TenantId AND d.FacilityId = i.FacilityId
               WHERE i.ApprovedRevisionNo < ISNULL(d.ApprovedRevisionNo, 0)
                  OR (i.ApprovedRevisionNo > 0 AND i.ApprovedRevisionNo <> ISNULL(d.ApprovedRevisionNo, -1)
                      AND NOT EXISTS (SELECT 1 FROM fac.FacilityRevision AS r
                                      WHERE r.TenantId = i.TenantId AND r.FacilityId = i.FacilityId
                                        AND r.RevisionNo = i.ApprovedRevisionNo AND r.Status = 'APPROVED')))
        THROW 50049, 'The approved revision of a facility is an APPROVED row of fac.FacilityRevision, and it only moves forward (BR-FAC-003)', 1;

    DECLARE @a TABLE (TenantId INT NOT NULL, FacilityId BIGINT NOT NULL, Rev INT NOT NULL);
    INSERT @a (TenantId, FacilityId, Rev)
    SELECT i.TenantId, i.FacilityId, i.ApprovedRevisionNo
    FROM inserted AS i
    LEFT JOIN deleted AS d ON d.TenantId = i.TenantId AND d.FacilityId = i.FacilityId
    WHERE i.ApprovedRevisionNo > 0 AND i.ApprovedRevisionNo <> ISNULL(d.ApprovedRevisionNo, -1);
    IF NOT EXISTS (SELECT 1 FROM @a) RETURN;

    DECLARE @bad TABLE (Problem NVARCHAR(200) NOT NULL);
    -- One row of each node valid at the approved revision.
    INSERT @bad (Problem)
    SELECT CONCAT(N'two rows of one node in ', q.T) FROM (
        SELECT N'fac.FacilityDocument' AS T, x.RootId, a.FacilityId FROM @a AS a JOIN fac.FacilityDocument AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'fac.FacilityLender', x.RootId, a.FacilityId FROM @a AS a JOIN fac.FacilityLender AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'fac.Limit', x.RootId, a.FacilityId FROM @a AS a JOIN fac.Limit AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'fac.LimitProductLine', x.RootId, a.FacilityId FROM @a AS a JOIN fac.LimitProductLine AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'fac.LimitCompanyRule', x.RootId, a.FacilityId FROM @a AS a JOIN fac.LimitCompanyRule AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'fac.ProductLineTerm', x.RootId, a.FacilityId FROM @a AS a JOIN fac.ProductLineTerm AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'prc.PricingRule', x.RootId, a.FacilityId FROM @a AS a JOIN prc.PricingRule AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'prc.PricingTier', x.RootId, a.FacilityId FROM @a AS a JOIN prc.PricingTier AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'cmp.TermValue', x.RootId, a.FacilityId FROM @a AS a JOIN cmp.TermValue AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'col.CollateralLink', x.RootId, a.FacilityId FROM @a AS a JOIN col.CollateralLink AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'obl.Obligation', x.RootId, a.FacilityId FROM @a AS a JOIN obl.Obligation AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'obl.ReportingObligation', x.RootId, a.FacilityId FROM @a AS a
         JOIN obl.Obligation AS o ON o.TenantId = a.TenantId AND o.FacilityId = a.FacilityId
         JOIN obl.ReportingObligation AS x ON x.TenantId = o.TenantId AND x.ObligationId = o.ObligationId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
        UNION ALL SELECT N'obl.Covenant', x.RootId, a.FacilityId FROM @a AS a
         JOIN obl.Obligation AS o ON o.TenantId = a.TenantId AND o.FacilityId = a.FacilityId
         JOIN obl.Covenant AS x ON x.TenantId = o.TenantId AND x.ObligationId = o.ObligationId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
    ) AS q
    GROUP BY q.T, q.FacilityId, q.RootId
    HAVING COUNT(*) > 1;
    -- Every row valid at the approved revision that names a revisioned parent names a parent row valid at it.
    INSERT @bad (Problem)
    SELECT CONCAT(N'a row of ', q.T, N' whose parent is not in the revision') FROM (
        SELECT N'fac.FacilityDocument' AS T FROM @a AS a
          JOIN fac.FacilityDocument AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.FacilityDocument AS p ON p.TenantId = x.TenantId AND p.FacilityDocumentId = x.AmendsFacilityDocumentId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'fac.Limit' FROM @a AS a
          JOIN fac.Limit AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.Limit AS p ON p.TenantId = x.TenantId AND p.LimitId = x.ParentLimitId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'fac.LimitProductLine' FROM @a AS a
          JOIN fac.LimitProductLine AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.Limit AS p ON p.TenantId = x.TenantId AND p.LimitId = x.LimitId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'fac.LimitCompanyRule' FROM @a AS a
          JOIN fac.LimitCompanyRule AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.Limit AS p ON p.TenantId = x.TenantId AND p.LimitId = x.LimitId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'fac.ProductLineTerm' FROM @a AS a
          JOIN fac.ProductLineTerm AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.LimitProductLine AS p ON p.TenantId = x.TenantId AND p.LimitProductLineId = x.LimitProductLineId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'prc.PricingRule' FROM @a AS a
          JOIN prc.PricingRule AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.Limit AS p ON p.TenantId = x.TenantId AND p.LimitId = x.ScopeLimitId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'prc.PricingRule' FROM @a AS a
          JOIN prc.PricingRule AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.LimitProductLine AS p ON p.TenantId = x.TenantId AND p.LimitProductLineId = x.ScopeLimitProductLineId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'prc.PricingTier' FROM @a AS a
          JOIN prc.PricingTier AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN prc.PricingRule AS p ON p.TenantId = x.TenantId AND p.PricingRuleId = x.PricingRuleId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'cmp.TermValue' FROM @a AS a
          JOIN cmp.TermValue AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.Limit AS p ON p.TenantId = x.TenantId AND p.LimitId = x.LimitId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'cmp.TermValue' FROM @a AS a
          JOIN cmp.TermValue AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.LimitProductLine AS p ON p.TenantId = x.TenantId AND p.LimitProductLineId = x.LimitProductLineId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'col.CollateralLink' FROM @a AS a
          JOIN col.CollateralLink AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.Limit AS p ON p.TenantId = x.TenantId AND p.LimitId = x.LimitId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'obl.Obligation' FROM @a AS a
          JOIN obl.Obligation AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.Limit AS p ON p.TenantId = x.TenantId AND p.LimitId = x.ScopeLimitId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'obl.Obligation' FROM @a AS a
          JOIN obl.Obligation AS x ON x.TenantId = a.TenantId AND x.FacilityId = a.FacilityId
          JOIN fac.LimitProductLine AS p ON p.TenantId = x.TenantId AND p.LimitProductLineId = x.ScopeProductLineId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'obl.ReportingObligation' FROM @a AS a
          JOIN obl.Obligation AS p ON p.TenantId = a.TenantId AND p.FacilityId = a.FacilityId
          JOIN obl.ReportingObligation AS x ON x.TenantId = p.TenantId AND x.ObligationId = p.ObligationId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
        UNION ALL SELECT N'obl.Covenant' FROM @a AS a
          JOIN obl.Obligation AS p ON p.TenantId = a.TenantId AND p.FacilityId = a.FacilityId
          JOIN obl.Covenant AS x ON x.TenantId = p.TenantId AND x.ObligationId = p.ObligationId
         WHERE x.FromRevision <= a.Rev AND (x.ToRevision IS NULL OR x.ToRevision > a.Rev)
           AND NOT (p.FromRevision <= a.Rev AND (p.ToRevision IS NULL OR p.ToRevision > a.Rev))
    ) AS q;
    IF EXISTS (SELECT 1 FROM @bad)
    BEGIN
        DECLARE @msg NVARCHAR(2048) = CONCAT(N'The approved facility revision is not whole: ',
            (SELECT STRING_AGG(Problem, N'; ') FROM (SELECT DISTINCT TOP 5 Problem FROM @bad ORDER BY Problem) AS b), N' (BR-FAC-003)');
        THROW 50050, @msg, 1;
    END;
END;
GO
/* DR-27 */
CREATE OR ALTER TRIGGER fac.TR_ValueConflict_Target ON fac.ValueConflict
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1
        FROM inserted AS i
        OUTER APPLY (
            SELECT TOP (1) t.HasFacility, t.TargetFacilityId
            FROM (
                SELECT 1, x.FacilityId FROM fac.Facility AS x WHERE i.TargetEntity = 'fac.Facility' AND x.TenantId = i.TenantId AND x.FacilityId = i.TargetId
                UNION ALL SELECT 1, x.FacilityId FROM fac.Limit AS x WHERE i.TargetEntity = 'fac.Limit' AND x.TenantId = i.TenantId AND x.LimitId = i.TargetId
                UNION ALL SELECT 1, x.FacilityId FROM fac.LimitProductLine AS x WHERE i.TargetEntity = 'fac.LimitProductLine' AND x.TenantId = i.TenantId AND x.LimitProductLineId = i.TargetId
                UNION ALL SELECT 1, x.FacilityId FROM fac.LimitCompanyRule AS x WHERE i.TargetEntity = 'fac.LimitCompanyRule' AND x.TenantId = i.TenantId AND x.LimitCompanyRuleId = i.TargetId
                UNION ALL SELECT 1, x.FacilityId FROM fac.ProductLineTerm AS x WHERE i.TargetEntity = 'fac.ProductLineTerm' AND x.TenantId = i.TenantId AND x.ProductLineTermId = i.TargetId
                UNION ALL SELECT 1, x.FacilityId FROM fac.OutstandingSnapshot AS x WHERE i.TargetEntity = 'fac.OutstandingSnapshot' AND x.TenantId = i.TenantId AND x.OutstandingSnapshotId = i.TargetId
                UNION ALL SELECT 1, x.FacilityId FROM prc.PricingRule AS x WHERE i.TargetEntity = 'prc.PricingRule' AND x.TenantId = i.TenantId AND x.PricingRuleId = i.TargetId
                UNION ALL SELECT 1, x.FacilityId FROM cmp.TermValue AS x WHERE i.TargetEntity = 'cmp.TermValue' AND x.TenantId = i.TenantId AND x.TermValueId = i.TargetId
                UNION ALL SELECT 1, x.FacilityId FROM obl.Obligation AS x WHERE i.TargetEntity = 'obl.Obligation' AND x.TenantId = i.TenantId AND x.ObligationId = i.TargetId
                UNION ALL SELECT 1, x.FacilityId FROM fin.MeasureFormula AS x WHERE i.TargetEntity = 'fin.MeasureFormula' AND x.TenantId = i.TenantId AND x.MeasureFormulaId = i.TargetId
                UNION ALL SELECT 0, NULL FROM col.Collateral AS x WHERE i.TargetEntity = 'col.Collateral' AND x.TenantId = i.TenantId AND x.CollateralId = i.TargetId
                UNION ALL SELECT 0, NULL FROM prc.TariffItem AS x WHERE i.TargetEntity = 'prc.TariffItem' AND x.TenantId = i.TenantId AND x.TariffItemId = i.TargetId
            ) AS t (HasFacility, TargetFacilityId)
        ) AS f
        WHERE f.HasFacility IS NULL
           OR (f.HasFacility = 1 AND NOT (f.TargetFacilityId = i.FacilityId OR (f.TargetFacilityId IS NULL AND i.FacilityId IS NULL))))
        THROW 50048, 'A value conflict names an existing row of its target table and carries that row''s facility (FR-FAC-026)', 1;
END;
GO
/* DR-36 */
CREATE OR ALTER TRIGGER col.TR_CollateralLink_Root ON col.CollateralLink
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN col.Collateral AS c ON c.TenantId = i.TenantId AND c.CollateralId = i.CollateralId
               WHERE c.SupersedesId IS NOT NULL)
        THROW 50052, 'A collateral link names the collateral by its first version, its root; the current approved version is read by RootId', 1;
END;
GO
/* DR-39: an evaluated covenant test changes only by its review. Its result, its inputs, the formula version and the
   covenant it was evaluated for stay as stored; EVALUATED may become REVIEWED once, with the reviewer's note, and
   only NextReviewOn changes after that. A new evaluation is a new row with the next EvaluationNo (BR-OBL-011). */
CREATE OR ALTER TRIGGER obl.TR_CovenantTest_Frozen ON obl.CovenantTest
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM deleted AS d
               LEFT JOIN inserted AS i ON i.CovenantTestId = d.CovenantTestId
               WHERE d.State IN ('EVALUATED','REVIEWED')
                 AND (i.CovenantTestId IS NULL
                      OR NOT (i.State = d.State OR (d.State = 'EVALUATED' AND i.State = 'REVIEWED'))
                      OR EXISTS (SELECT i.TenantId, i.PublicId, i.CovenantId, i.PeriodStart, i.PeriodEnd, i.DueDate, i.EvaluationNo,
                                        i.Result, i.Method, i.ActualValue, i.ThresholdApplied, i.OperatorApplied, i.Headroom,
                                        i.HeadroomPct, i.InputsSnapshot, i.FormulaId, i.EvaluatedAt, i.EvaluatedBy, i.EvidenceDocumentId
                                 EXCEPT
                                 SELECT d.TenantId, d.PublicId, d.CovenantId, d.PeriodStart, d.PeriodEnd, d.DueDate, d.EvaluationNo,
                                        d.Result, d.Method, d.ActualValue, d.ThresholdApplied, d.OperatorApplied, d.Headroom,
                                        d.HeadroomPct, d.InputsSnapshot, d.FormulaId, d.EvaluatedAt, d.EvaluatedBy, d.EvidenceDocumentId)
                      OR (d.State = 'REVIEWED'
                          AND EXISTS (SELECT i.ReviewNote, i.ReviewedBy, i.ReviewedOn EXCEPT SELECT d.ReviewNote, d.ReviewedBy, d.ReviewedOn))))
        THROW 50053, 'An evaluated covenant test changes only by its review; a new evaluation is a new row with the next EvaluationNo (BR-OBL-011)', 1;
END;
GO
/* DR-39: an automatic evaluation names the formula version it used and stores every input it read (BR-FIN-010,
   FR-FIN-013), so the result can be explained and reproduced. When the test becomes EVALUATED or REVIEWED:
   - FormulaId is a version of the covenant's formula (the same Code and FacilityId), not a draft, and empty when the
     covenant has no formula;
   - InputsSnapshot is a JSON object holding formula.id and formula.version of that version; threshold.value and
     threshold.operator equal ThresholdApplied and OperatorApplied, which are the covenant's own;
   - for each kind of input the formula reads (an average balance reads account figures and a flow volume bank flows
     when there is no formula) the snapshot holds an array: statements of {statementId, version, basis}, each a
     statement of the tested company with that version and basis; accounts of {accountId, month, value}; flows of
     {entryId, amount}. The array may be empty only when the result is MISSING_DATA.
   Manual results (MANUAL_VALUE, MANUAL_STATUS) carry their evidence instead and are not checked here. */
CREATE OR ALTER TRIGGER obl.TR_CovenantTest_Evaluation ON obl.CovenantTest
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted WHERE State IN ('EVALUATED','REVIEWED') AND Method = 'AUTO') RETURN;
    IF EXISTS (
        SELECT 1
        FROM inserted AS i
        LEFT JOIN deleted AS d ON d.CovenantTestId = i.CovenantTestId
        JOIN obl.Covenant AS c ON c.TenantId = i.TenantId AND c.CovenantId = i.CovenantId
        LEFT JOIN fin.MeasureFormula AS cf ON cf.TenantId = c.TenantId AND cf.MeasureFormulaId = c.FormulaId
        LEFT JOIN fin.MeasureFormula AS tf ON tf.TenantId = i.TenantId AND tf.MeasureFormulaId = i.FormulaId
        CROSS APPLY (SELECT CASE WHEN tf.MeasureFormulaId IS NOT NULL THEN tf.InputKinds
                                 WHEN c.MeasureKind = 'AVERAGE_BALANCE' THEN 'ACCOUNT_STATS'
                                 WHEN c.MeasureKind = 'FLOW_VOLUME' THEN 'BANK_FLOWS'
                                 ELSE '' END AS Kinds,
                            CASE WHEN i.Result = 'MISSING_DATA' THEN 0 ELSE 1 END AS NeedRows) AS k
        WHERE i.State IN ('EVALUATED','REVIEWED') AND i.Method = 'AUTO'
          AND (d.CovenantTestId IS NULL OR d.State NOT IN ('EVALUATED','REVIEWED'))
          AND (   (c.FormulaId IS NULL AND i.FormulaId IS NOT NULL)
               OR (c.FormulaId IS NOT NULL AND (tf.MeasureFormulaId IS NULL OR tf.Status = 'DRAFT' OR tf.Code <> cf.Code
                                                OR tf.FacilityId IS DISTINCT FROM cf.FacilityId))
               OR ISNULL(ISJSON(i.InputsSnapshot, OBJECT), 0) = 0
               OR (tf.MeasureFormulaId IS NOT NULL
                   AND (TRY_CAST(JSON_VALUE(i.InputsSnapshot, '$.formula.id') AS BIGINT) IS DISTINCT FROM tf.MeasureFormulaId
                        OR TRY_CAST(JSON_VALUE(i.InputsSnapshot, '$.formula.version') AS INT) IS DISTINCT FROM tf.VersionNo))
               OR (i.ThresholdApplied IS NOT NULL
                   AND (TRY_CAST(JSON_VALUE(i.InputsSnapshot, '$.threshold.value') AS DECIMAL(19,6)) IS DISTINCT FROM i.ThresholdApplied
                        OR JSON_VALUE(i.InputsSnapshot, '$.threshold.operator') IS DISTINCT FROM i.OperatorApplied
                        OR i.ThresholdApplied IS DISTINCT FROM c.ThresholdValue
                        OR i.OperatorApplied IS DISTINCT FROM c.Operator))
               OR (k.Kinds LIKE '%STATEMENT%'
                   AND (ISNULL(ISJSON(JSON_QUERY(i.InputsSnapshot, '$.statements'), ARRAY), 0) = 0
                        OR (k.NeedRows = 1 AND NOT EXISTS (SELECT 1 FROM OPENJSON(i.InputsSnapshot, '$.statements')))
                        OR EXISTS (SELECT 1
                                   FROM OPENJSON(i.InputsSnapshot, '$.statements')
                                        WITH (StatementId NVARCHAR(40) '$.statementId', VersionNo NVARCHAR(40) '$.version',
                                              Basis NVARCHAR(40) '$.basis') AS s
                                   WHERE NOT EXISTS (SELECT 1 FROM fin.FinancialStatement AS fs
                                                     WHERE fs.TenantId = i.TenantId
                                                       AND fs.FinancialStatementId = TRY_CAST(s.StatementId AS BIGINT)
                                                       AND fs.VersionNo = TRY_CAST(s.VersionNo AS INT)
                                                       AND fs.Basis = s.Basis
                                                       AND fs.CompanyId = c.TestedCompanyId))))
               OR (k.Kinds LIKE '%ACCOUNT_STATS%'
                   AND (ISNULL(ISJSON(JSON_QUERY(i.InputsSnapshot, '$.accounts'), ARRAY), 0) = 0
                        OR (k.NeedRows = 1 AND NOT EXISTS (SELECT 1 FROM OPENJSON(i.InputsSnapshot, '$.accounts')))
                        OR EXISTS (SELECT 1
                                   FROM OPENJSON(i.InputsSnapshot, '$.accounts')
                                        WITH (AccountId NVARCHAR(40) '$.accountId', MonthOf NVARCHAR(40) '$.month',
                                              Amount NVARCHAR(60) '$.value') AS a
                                   WHERE TRY_CAST(a.AccountId AS BIGINT) IS NULL OR a.MonthOf IS NULL
                                      OR TRY_CAST(a.Amount AS DECIMAL(19,4)) IS NULL)))
               OR (k.Kinds LIKE '%BANK_FLOWS%'
                   AND (ISNULL(ISJSON(JSON_QUERY(i.InputsSnapshot, '$.flows'), ARRAY), 0) = 0
                        OR (k.NeedRows = 1 AND NOT EXISTS (SELECT 1 FROM OPENJSON(i.InputsSnapshot, '$.flows')))
                        OR EXISTS (SELECT 1
                                   FROM OPENJSON(i.InputsSnapshot, '$.flows')
                                        WITH (EntryId NVARCHAR(40) '$.entryId', Amount NVARCHAR(60) '$.amount') AS b
                                   WHERE TRY_CAST(b.EntryId AS BIGINT) IS NULL OR TRY_CAST(b.Amount AS DECIMAL(19,4)) IS NULL)))))
        THROW 50054, 'An automatic covenant evaluation names the version of the covenant''s formula it used and stores all its inputs, its threshold and its operator in InputsSnapshot (BR-FIN-010)', 1;
END;
GO
/* DR-39: an agenda item that left SCHEDULED keeps its status, its obligation, its period and its reason, and is not
   deleted. A SUBMITTED item's submission details may be corrected (DQ-F15-13); the other final items may only gain
   their evidence document. */
CREATE OR ALTER TRIGGER obl.TR_ReportingInstance_Final ON obl.ReportingInstance
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM deleted AS d
               LEFT JOIN inserted AS i ON i.ReportingInstanceId = d.ReportingInstanceId
               WHERE d.Status <> 'SCHEDULED'
                 AND (i.ReportingInstanceId IS NULL
                      OR i.Status <> d.Status
                      OR EXISTS (SELECT i.TenantId, i.PublicId, i.ReportingObligationId, i.PeriodStart, i.PeriodEnd, i.EventDate, i.DueDate,
                                        i.DueDateOverrideReason, i.StatusReason, i.GeneratedBy
                                 EXCEPT
                                 SELECT d.TenantId, d.PublicId, d.ReportingObligationId, d.PeriodStart, d.PeriodEnd, d.EventDate, d.DueDate,
                                        d.DueDateOverrideReason, d.StatusReason, d.GeneratedBy)
                      OR (d.Status <> 'SUBMITTED'
                          AND (EXISTS (SELECT i.SubmittedOn, i.SubmissionChannelUsedId, i.SubmissionRef, i.ReportedAmount, i.CurrencyId
                                       EXCEPT
                                       SELECT d.SubmittedOn, d.SubmissionChannelUsedId, d.SubmissionRef, d.ReportedAmount, d.CurrencyId)
                               OR (d.EvidenceDocumentId IS NOT NULL AND i.EvidenceDocumentId IS DISTINCT FROM d.EvidenceDocumentId)))))
        THROW 50055, 'An agenda item that left SCHEDULED keeps its status, obligation and period; only a submission''s details are corrected', 1;
END;
GO
/* DR-41 (S3): a terms version is written as DRAFT, its document clauses and charges are added, and then it is
   locked (BR-LCT-019, FR-LCT-002). A LOCKED version never returns to DRAFT and changes in nothing but its treasury
   fields (I1-I4 and the bank's clauses), and only until TreasuryHash seals them after the treasury manager's approval;
   it may then become SUPERSEDED. A missing owner may be filled once, in the transaction that creates the owner. A
   SUPERSEDED version changes in nothing. A version that is not a draft is not deleted. The trigger is built from the
   table's columns, so a column added later is frozen unless it is named below. */
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);   -- what a LOCKED version may still change
DECLARE @treasury TABLE (name SYSNAME PRIMARY KEY);
INSERT @treasury VALUES (N'MarginPct'), (N'DebitAuthorization'), (N'MarginHeldCurrency'), (N'FacilityAccountId'), (N'MarginSettlementAccountId'),
                        (N'ChargesAccountId'), (N'PostDeferralFinancingDays'), (N'BankSpecificClauses'), (N'TreasuryHash');
INSERT @may SELECT name FROM @treasury;
INSERT @may VALUES (N'Status'), (N'OwnerId'), (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @ti NVARCHAR(MAX), @td NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'lc.LcTerms') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SELECT @ti = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(name)), N', '), @td = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(name)), N', ')
FROM @treasury;
SET @sql = N'CREATE OR ALTER TRIGGER lc.TR_LcTerms_Locked ON lc.LcTerms
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i WHERE i.Status <> ''DRAFT''
               AND NOT EXISTS (SELECT 1 FROM deleted AS d WHERE d.LcTermsId = i.LcTermsId))
        THROW 50056, ''A terms version is written as DRAFT, gets its clauses and charges, and is then locked (BR-LCT-019)'', 1;
    IF EXISTS (SELECT 1
               FROM deleted AS d
               LEFT JOIN inserted AS i ON i.LcTermsId = d.LcTermsId
               WHERE d.Status <> ''DRAFT''
                 AND (i.LcTermsId IS NULL
                      OR NOT (i.Status = d.Status OR (d.Status = ''LOCKED'' AND i.Status = ''SUPERSEDED''))
                      OR (d.OwnerId IS NOT NULL AND i.OwnerId IS DISTINCT FROM d.OwnerId)
                      OR EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')
                      OR ((d.Status <> ''LOCKED'' OR d.TreasuryHash IS NOT NULL)
                          AND EXISTS (SELECT ' + @ti + N' EXCEPT SELECT ' + @td + N'))))
        THROW 50056, ''Locked terms change only in their treasury fields until TreasuryHash; any other change is a new version (FR-LCT-002, BR-LCT-019)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
-- The clauses and charges of a terms version are part of its SnapshotHash: they change only while it is a draft.
CREATE OR ALTER TRIGGER lc.TR_LcTermsDocument_DraftOnly ON lc.LcTermsDocument
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, LcTermsId FROM inserted UNION SELECT TenantId, LcTermsId FROM deleted) AS r
               JOIN lc.LcTerms AS t ON t.TenantId = r.TenantId AND t.LcTermsId = r.LcTermsId
               WHERE t.Status <> 'DRAFT')
        THROW 50056, 'The document clauses of locked terms do not change; create a new version (BR-LCT-012, BR-LCT-019)', 1;
END;
GO
CREATE OR ALTER TRIGGER lc.TR_LcChargesMatrix_DraftOnly ON lc.LcChargesMatrix
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, LcTermsId FROM inserted UNION SELECT TenantId, LcTermsId FROM deleted) AS r
               JOIN lc.LcTerms AS t ON t.TenantId = r.TenantId AND t.LcTermsId = r.LcTermsId
               WHERE t.Status <> 'DRAFT')
        THROW 50056, 'The charges of locked terms do not change; create a new version (BR-LCT-014, BR-LCT-019)', 1;
END;
GO
/* DR-41 (S3): a workflow template version is written as DRAFT, its stages, approvers, transitions, hooks, fields and
   attachment rules are added, and then it is published (BR-WFL-019, AC-WFL-6). A PUBLISHED version only retires: it
   may lose IsCurrent and become RETIRED with its time; a RETIRED version changes in nothing; neither is deleted.
   DR-49: every version of a TemplateKey belongs to one request type, so the current version of the type is its
   default template. */
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);
INSERT @may VALUES (N'Status'), (N'IsCurrent'), (N'RetiredAt'), (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'wfl.WorkflowTemplate') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SET @sql = N'CREATE OR ALTER TRIGGER wfl.TR_WorkflowTemplate_Published ON wfl.WorkflowTemplate
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i WHERE i.Status <> ''DRAFT''
               AND NOT EXISTS (SELECT 1 FROM deleted AS d WHERE d.WorkflowTemplateId = i.WorkflowTemplateId))
        THROW 50057, ''A template version is written as DRAFT, gets its parts, and is then published (BR-WFL-019)'', 1;
    IF EXISTS (SELECT 1
               FROM deleted AS d
               LEFT JOIN inserted AS i ON i.WorkflowTemplateId = d.WorkflowTemplateId
               WHERE d.Status <> ''DRAFT''
                 AND (i.WorkflowTemplateId IS NULL
                      OR NOT (i.Status = d.Status OR (d.Status = ''PUBLISHED'' AND i.Status = ''RETIRED''))
                      OR (i.IsCurrent = 1 AND d.IsCurrent = 0)
                      OR (d.Status = ''RETIRED'' AND EXISTS (SELECT i.IsCurrent, i.RetiredAt EXCEPT SELECT d.IsCurrent, d.RetiredAt))
                      OR EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')))
        THROW 50057, ''A published template version only retires; any change is a new version (BR-WFL-019, AC-WFL-6)'', 1;
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN wfl.WorkflowTemplate AS o ON o.TenantId = i.TenantId AND o.TemplateKey = i.TemplateKey AND o.RequestTypeId <> i.RequestTypeId)
        THROW 50057, ''The versions of a template key belong to one request type (DR-49)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
/* The parts of a template version change only while it is a draft. A part deleted with its stage finds no stage here;
   the stage trigger has then checked the version. */
DECLARE @parts TABLE (TableName SYSNAME PRIMARY KEY, ViaStage BIT NOT NULL);
INSERT @parts VALUES (N'WorkflowStage', 0), (N'WorkflowTransition', 0), (N'TemplateField', 0), (N'TemplateAttachmentRule', 0),
                     (N'StageApprover', 1), (N'WorkflowStageHook', 1);
DECLARE @t SYSNAME, @via BIT, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT TableName, ViaStage FROM @parts;
OPEN c; FETCH NEXT FROM c INTO @t, @via;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'CREATE OR ALTER TRIGGER wfl.' + QUOTENAME(N'TR_' + @t + N'_DraftOnly') + N' ON wfl.' + QUOTENAME(@t) + N'
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, ' + CASE WHEN @via = 1 THEN N'StageId' ELSE N'TemplateId' END + N' AS k FROM inserted
                     UNION SELECT TenantId, ' + CASE WHEN @via = 1 THEN N'StageId' ELSE N'TemplateId' END + N' FROM deleted) AS r
               ' + CASE WHEN @via = 1
                        THEN N'JOIN wfl.WorkflowStage AS s ON s.TenantId = r.TenantId AND s.WorkflowStageId = r.k
               JOIN wfl.WorkflowTemplate AS t ON t.TenantId = s.TenantId AND t.WorkflowTemplateId = s.TemplateId'
                        ELSE N'JOIN wfl.WorkflowTemplate AS t ON t.TenantId = r.TenantId AND t.WorkflowTemplateId = r.k' END + N'
               WHERE t.Status <> ''DRAFT'')
        THROW 50057, ''The parts of a published or retired template version do not change; create a new version (BR-WFL-019)'', 1;
END;';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM c INTO @t, @via;
END;
CLOSE c; DEALLOCATE c;
GO
/* DR-44 (S3): a request keeps copies of its current stage instance (stage, assignee, queue time, claim time, due time,
   SLA state) and of its reservation (id, amount, state) for its queue and SLA indexes (DQ-F11-10). The database is
   their only writer: the application writes the stage instance, the request's pointer to it and the reservation, and
   these triggers copy the rest; tp_app cannot write the copies. The current instance is one of the request's own
   (composite key, DR-44), and its stage belongs to the request's template (the key of CurrentStageId).
   A reservation's state maps to the request: ACTIVE is RESERVED, CONVERTED is CONVERTED, a release the request caused
   (REJECTED, CANCELLED, SUPERSEDED) is RELEASED, and a release from outside (EXPIRED, MANUAL) is LOST (BR-WFL-017).
   wfl.RequestCopyDrift lists any request whose copies differ, for JOB-PLT-RECONCILE. */
CREATE OR ALTER TRIGGER wfl.TR_RequestStageInstance_Copy ON wfl.RequestStageInstance
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE r
    SET CurrentStageId = s.StageId, AssigneeUserId = s.AssigneeUserId, QueueEnteredAt = s.QueuedAt, ClaimedAt = s.ClaimedAt,
        DueAt = s.DueAt, SlaState = s.SlaState
    FROM wfl.Request AS r
    JOIN inserted AS s ON s.TenantId = r.TenantId AND s.RequestStageInstanceId = r.CurrentStageInstanceId
    WHERE EXISTS (SELECT r.CurrentStageId, r.AssigneeUserId, r.QueueEnteredAt, r.ClaimedAt, r.DueAt, r.SlaState
                  EXCEPT SELECT s.StageId, s.AssigneeUserId, s.QueuedAt, s.ClaimedAt, s.DueAt, s.SlaState);
END;
GO
CREATE OR ALTER TRIGGER fac.TR_LimitReservation_RequestCopy ON fac.LimitReservation
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE r
    SET ReservationId = lr.LimitReservationId, ReservedAmount = lr.Amount,
        ReservationState = CASE lr.Status WHEN 'ACTIVE' THEN 'RESERVED' WHEN 'CONVERTED' THEN 'CONVERTED'
                                ELSE CASE WHEN lr.ReleaseReason IN ('EXPIRED','MANUAL') THEN 'LOST' ELSE 'RELEASED' END END
    FROM wfl.Request AS r
    JOIN inserted AS lr ON lr.TenantId = r.TenantId AND lr.RequestId = r.RequestId
                       AND (lr.Status = 'ACTIVE' OR lr.LimitReservationId = r.ReservationId)
    WHERE EXISTS (SELECT r.ReservationId, r.ReservedAmount, r.ReservationState
                  EXCEPT SELECT lr.LimitReservationId, lr.Amount,
                                CASE lr.Status WHEN 'ACTIVE' THEN 'RESERVED' WHEN 'CONVERTED' THEN 'CONVERTED'
                                     ELSE CASE WHEN lr.ReleaseReason IN ('EXPIRED','MANUAL') THEN 'LOST' ELSE 'RELEASED' END END);
END;
GO
-- A write to the request itself (a new current instance, or any other change) takes the copies again from their sources.
CREATE OR ALTER TRIGGER wfl.TR_Request_Copies ON wfl.Request
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE r
    SET CurrentStageId = s.StageId, AssigneeUserId = s.AssigneeUserId, QueueEnteredAt = s.QueuedAt, ClaimedAt = s.ClaimedAt,
        DueAt = s.DueAt, SlaState = ISNULL(s.SlaState, 'NONE'),
        ReservedAmount = lr.Amount,
        ReservationState = CASE WHEN lr.LimitReservationId IS NULL THEN 'NONE' WHEN lr.Status = 'ACTIVE' THEN 'RESERVED'
                                WHEN lr.Status = 'CONVERTED' THEN 'CONVERTED'
                                WHEN lr.ReleaseReason IN ('EXPIRED','MANUAL') THEN 'LOST' ELSE 'RELEASED' END
    FROM wfl.Request AS r
    JOIN inserted AS i ON i.RequestId = r.RequestId
    LEFT JOIN wfl.RequestStageInstance AS s ON s.TenantId = r.TenantId AND s.RequestStageInstanceId = r.CurrentStageInstanceId
    LEFT JOIN fac.LimitReservation AS lr ON lr.TenantId = r.TenantId AND lr.LimitReservationId = r.ReservationId
    WHERE EXISTS (SELECT r.CurrentStageId, r.AssigneeUserId, r.QueueEnteredAt, r.ClaimedAt, r.DueAt, r.SlaState, r.ReservedAmount, r.ReservationState
                  EXCEPT SELECT s.StageId, s.AssigneeUserId, s.QueuedAt, s.ClaimedAt, s.DueAt, ISNULL(s.SlaState, 'NONE'), lr.Amount,
                                CASE WHEN lr.LimitReservationId IS NULL THEN 'NONE' WHEN lr.Status = 'ACTIVE' THEN 'RESERVED'
                                     WHEN lr.Status = 'CONVERTED' THEN 'CONVERTED'
                                     WHEN lr.ReleaseReason IN ('EXPIRED','MANUAL') THEN 'LOST' ELSE 'RELEASED' END);
END;
GO
DENY UPDATE ON wfl.Request (CurrentStageId, AssigneeUserId, QueueEnteredAt, ClaimedAt, DueAt, SlaState, ReservationId, ReservedAmount,
                            ReservationState) TO [tp_app];
GO
CREATE OR ALTER VIEW wfl.RequestCopyDrift
AS
SELECT r.TenantId, r.RequestId, r.Status,
       CAST(CASE WHEN EXISTS (SELECT r.CurrentStageId, r.AssigneeUserId, r.QueueEnteredAt, r.ClaimedAt, r.DueAt, r.SlaState
                              EXCEPT SELECT s.StageId, s.AssigneeUserId, s.QueuedAt, s.ClaimedAt, s.DueAt, ISNULL(s.SlaState, 'NONE'))
                 THEN 1 ELSE 0 END AS BIT) AS StageDrift,
       CAST(CASE WHEN EXISTS (SELECT r.ReservedAmount, r.ReservationState
                              EXCEPT SELECT lr.Amount,
                                            CASE WHEN lr.LimitReservationId IS NULL THEN 'NONE' WHEN lr.Status = 'ACTIVE' THEN 'RESERVED'
                                                 WHEN lr.Status = 'CONVERTED' THEN 'CONVERTED'
                                                 WHEN lr.ReleaseReason IN ('EXPIRED','MANUAL') THEN 'LOST' ELSE 'RELEASED' END)
                      OR (lr.Status = 'ACTIVE' AND lr.LimitReservationId IS NOT NULL
                          AND EXISTS (SELECT 1 FROM fac.LimitReservation AS a
                                      WHERE a.TenantId = r.TenantId AND a.RequestId = r.RequestId AND a.Status = 'ACTIVE'
                                        AND a.LimitReservationId <> lr.LimitReservationId))
                 THEN 1 ELSE 0 END AS BIT) AS ReservationDrift
FROM wfl.Request AS r
LEFT JOIN wfl.RequestStageInstance AS s ON s.TenantId = r.TenantId AND s.RequestStageInstanceId = r.CurrentStageInstanceId
LEFT JOIN fac.LimitReservation AS lr ON lr.TenantId = r.TenantId AND lr.LimitReservationId = r.ReservationId
WHERE EXISTS (SELECT r.CurrentStageId, r.AssigneeUserId, r.QueueEnteredAt, r.ClaimedAt, r.DueAt, r.SlaState, r.ReservedAmount, r.ReservationState
              EXCEPT SELECT s.StageId, s.AssigneeUserId, s.QueuedAt, s.ClaimedAt, s.DueAt, ISNULL(s.SlaState, 'NONE'), lr.Amount,
                            CASE WHEN lr.LimitReservationId IS NULL THEN 'NONE' WHEN lr.Status = 'ACTIVE' THEN 'RESERVED'
                                 WHEN lr.Status = 'CONVERTED' THEN 'CONVERTED'
                                 WHEN lr.ReleaseReason IN ('EXPIRED','MANUAL') THEN 'LOST' ELSE 'RELEASED' END);
GO
GRANT SELECT ON wfl.RequestCopyDrift TO [tp_app];
GO
/* DR-46 (S3): a restricted field (lc.LcFieldDefinition.Sensitivity = RESTRICTED; the beneficiary's IBAN always is)
   is never copied: a comparison line on it holds no value, only its verdict, and an amendment's ChangedFieldsJson, an
   object keyed by field key, holds the marker "CHANGED" for it. The verdict comes from the keyed hash
   (lc.BeneficiaryIbanChange), and from the decrypted values in memory only when the two versions use different keys
   (DOC-F12 section 8.3). */
CREATE OR ALTER TRIGGER lc.TR_LcTermsComparisonLine_Restricted ON lc.LcTermsComparisonLine
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN lc.LcFieldDefinition AS f ON f.TenantId = i.TenantId AND f.FieldKey = i.FieldKey
               WHERE f.Sensitivity = 'RESTRICTED' AND (i.BaselineValue IS NOT NULL OR i.ReceivedValue IS NOT NULL))
        THROW 50058, 'A comparison line on a restricted field holds its verdict only, never its values (DR-46)', 1;
END;
GO
CREATE OR ALTER TRIGGER lc.TR_LcAmendment_Restricted ON lc.LcAmendment
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i
               WHERE i.ChangedFieldsJson IS NOT NULL
                 AND (ISNULL(ISJSON(i.ChangedFieldsJson, OBJECT), 0) = 0
                      OR EXISTS (SELECT 1 FROM lc.LcFieldDefinition AS f
                                 CROSS APPLY (SELECT CONCAT(N'$."', f.FieldKey, N'"') AS p) AS k
                                 WHERE f.TenantId = i.TenantId AND f.Sensitivity = 'RESTRICTED'
                                   AND (JSON_QUERY(i.ChangedFieldsJson, k.p) IS NOT NULL
                                        OR JSON_VALUE(i.ChangedFieldsJson, k.p) <> N'CHANGED'))))
        THROW 50058, 'An amendment''s ChangedFieldsJson is an object keyed by field key, and a restricted field holds only "CHANGED" (DR-46)', 1;
END;
GO
CREATE OR ALTER FUNCTION lc.BeneficiaryIbanChange (@BaselineTermsId BIGINT, @ReceivedTermsId BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT CAST(CASE WHEN a.HashKeyId IS DISTINCT FROM b.HashKeyId AND a.BeneficiaryAccountIbanHash IS NOT NULL
                          AND b.BeneficiaryAccountIbanHash IS NOT NULL THEN NULL
                     WHEN a.BeneficiaryAccountIbanHash IS NOT DISTINCT FROM b.BeneficiaryAccountIbanHash THEN 0
                     ELSE 1 END AS BIT) AS Changed   -- NULL: different keys, compare the decrypted values in memory
    FROM lc.LcTerms AS a
    JOIN lc.LcTerms AS b ON b.TenantId = a.TenantId AND b.LcTermsId = @ReceivedTermsId
    WHERE a.LcTermsId = @BaselineTermsId;
GO
GRANT SELECT ON lc.BeneficiaryIbanChange TO [tp_app];
GO
/* DR-41 (S4): a proforma's lines are written once, in one statement, after its header; each line total is
   round(Qty x UnitPrice, d), the subtotal is their sum, and the VAT is round(Subtotal x Rate / 100, d), d being the
   currency's decimals and the rounding away from zero (BR-LCE-001). Total = Subtotal + VAT is a check on the header,
   and the header's totals cannot be updated by tp_app (043). A header still without lines is listed by
   lc.ProformaTotalsDrift, for JOB-PLT-RECONCILE. */
CREATE OR ALTER TRIGGER lc.TR_ProformaLine_Totals ON lc.ProformaLine
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, ProformaId, COUNT(*) AS NewLines FROM inserted GROUP BY TenantId, ProformaId) AS n
               JOIN lc.ProformaInvoice AS p ON p.TenantId = n.TenantId AND p.ProformaInvoiceId = n.ProformaId
               JOIN ref.Currency AS cur ON cur.CurrencyId = p.CurrencyId
               CROSS APPLY (SELECT COUNT(*) AS Lines, SUM(l.LineTotal) AS Subtotal,
                                   SUM(CASE WHEN l.LineTotal <> ROUND(l.Qty * l.UnitPrice, lcur.Decimals) THEN 1 ELSE 0 END) AS BadLines
                            FROM lc.ProformaLine AS l
                            JOIN ref.Currency AS lcur ON lcur.CurrencyId = l.CurrencyId   -- the proforma's currency (composite key)
                            WHERE l.TenantId = p.TenantId AND l.ProformaId = p.ProformaInvoiceId) AS s
               WHERE s.Lines <> n.NewLines OR s.BadLines > 0 OR s.Subtotal <> p.Subtotal
                  OR p.VatAmount <> ROUND(p.Subtotal * p.VatRatePct / 100, cur.Decimals))
        THROW 50059, 'A proforma''s lines are written once, and its line totals, subtotal and VAT follow BR-LCE-001', 1;
END;
GO
CREATE OR ALTER VIEW lc.ProformaTotalsDrift
AS
SELECT p.TenantId, p.ProformaInvoiceId, p.ProformaNo, s.Lines, s.Subtotal AS LinesSubtotal, p.Subtotal, p.VatAmount
FROM lc.ProformaInvoice AS p
JOIN ref.Currency AS cur ON cur.CurrencyId = p.CurrencyId
CROSS APPLY (SELECT COUNT(*) AS Lines, SUM(l.LineTotal) AS Subtotal FROM lc.ProformaLine AS l
             WHERE l.TenantId = p.TenantId AND l.ProformaId = p.ProformaInvoiceId) AS s
WHERE s.Lines = 0 OR s.Subtotal <> p.Subtotal OR p.VatAmount <> ROUND(p.Subtotal * p.VatRatePct / 100, cur.Decimals);
GO
GRANT SELECT ON lc.ProformaTotalsDrift TO [tp_app];
GO

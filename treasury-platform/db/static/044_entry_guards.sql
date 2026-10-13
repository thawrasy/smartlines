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

   An error raised in a trigger ends the caller's transaction; the application validates first.
   Errors: 50047 an indirect path through a company of the tenant, 50048 a conflict on a missing target or with
   another facility than its target's, 50049 an approved revision that is missing,
   unapproved or moved back, 50050 a revision approved with two rows of one node or a row whose parent is not in it,
   50052 a collateral link to a version that is not the first.
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

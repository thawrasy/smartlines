/* ============================================================================
   050 - Lender shares of an approved facility revision (V-FAC-02, BR-FAC-007)
   Hand-written; deployed by db/deploy.sql after the generated objects.

   STATUS: deployed and tested on SQL Server 2025: db/tests/fac_share_rule_tests.sql (seven cases) runs in step 6
   of tools/ci/db_ci.sh, locally and on GitHub. A lender of an approved revision is not changed in place (O-03,
   DQ-F13-7): since self-review A1 the freeze of 044 refuses it (50049), so this trigger is the last guard.

   Rule. For every facility with an approved revision (ApprovedRevisionNo >= 1)
   the lenders valid at that revision total 100 percent and at most one lender
   holds the AGENT role. A lender is valid at revision a when
       FromRevision <= a AND (ToRevision IS NULL OR ToRevision > a)
   which is the read rule of the revision model (BR-FAC-003).

   Draft revisions (FromRevision > a) are not checked, so lenders can be saved
   one row at a time while a revision is being edited.

   Required order when a revision is approved: insert or close the lender rows of
   the new revision first, then raise Facility.ApprovedRevisionNo in a separate
   statement. The facility trigger rejects the approval if the rows are missing.

   Runs in the caller's tenant context: the row-level security filter applies to
   the reads inside the trigger, so a job that changes tenant rows must set
   SESSION_CONTEXT('TenantId') first.
   ============================================================================ */

CREATE OR ALTER TRIGGER fac.TR_FacilityLender_ApprovedShares
ON fac.FacilityLender
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1
        FROM fac.Facility AS f
        JOIN (SELECT FacilityId FROM inserted
              UNION
              SELECT FacilityId FROM deleted) AS changed
          ON changed.FacilityId = f.FacilityId
        WHERE f.ApprovedRevisionNo >= 1
          AND (
                (SELECT COALESCE(SUM(l.SharePct), 0)
                   FROM fac.FacilityLender AS l
                  WHERE l.FacilityId = f.FacilityId
                    AND l.FromRevision <= f.ApprovedRevisionNo
                    AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo)) <> 100
             OR
                (SELECT COUNT(*)
                   FROM fac.FacilityLender AS l
                  WHERE l.FacilityId = f.FacilityId
                    AND l.FromRevision <= f.ApprovedRevisionNo
                    AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo)
                    AND l.Roles LIKE '%AGENT%') > 1
              )
    )
    BEGIN
        THROW 50071, 'Approved facility revision: lender shares must total 100 and at most one lender may hold AGENT (V-FAC-02).', 1;
    END
END;
GO
-- A row of an approved revision is refused by the freeze of 044 (50049) before its shares are summed here (50071):
-- the order of two triggers on a table is otherwise undefined.
EXEC sys.sp_settriggerorder @triggername = N'fac.TR_FacilityLender_ApprovedShares', @order = N'Last', @stmttype = N'INSERT';
EXEC sys.sp_settriggerorder @triggername = N'fac.TR_FacilityLender_ApprovedShares', @order = N'Last', @stmttype = N'UPDATE';
EXEC sys.sp_settriggerorder @triggername = N'fac.TR_FacilityLender_ApprovedShares', @order = N'Last', @stmttype = N'DELETE';
GO

CREATE OR ALTER TRIGGER fac.TR_Facility_ApprovedShares
ON fac.Facility
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1
        FROM inserted AS i
        JOIN deleted AS d
          ON d.FacilityId = i.FacilityId
        WHERE i.ApprovedRevisionNo <> d.ApprovedRevisionNo
          AND i.ApprovedRevisionNo >= 1
          AND (
                (SELECT COALESCE(SUM(l.SharePct), 0)
                   FROM fac.FacilityLender AS l
                  WHERE l.FacilityId = i.FacilityId
                    AND l.FromRevision <= i.ApprovedRevisionNo
                    AND (l.ToRevision IS NULL OR l.ToRevision > i.ApprovedRevisionNo)) <> 100
             OR
                (SELECT COUNT(*)
                   FROM fac.FacilityLender AS l
                  WHERE l.FacilityId = i.FacilityId
                    AND l.FromRevision <= i.ApprovedRevisionNo
                    AND (l.ToRevision IS NULL OR l.ToRevision > i.ApprovedRevisionNo)
                    AND l.Roles LIKE '%AGENT%') > 1
              )
    )
    BEGIN
        THROW 50072, 'Approving a facility revision requires lender shares that total 100 and at most one lender holding AGENT (V-FAC-02).', 1;
    END
END;
GO

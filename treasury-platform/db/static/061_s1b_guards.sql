/* 061_s1b_guards.sql — the lifecycle of authority grants, bank authorities and governance conflicts is kept in the
   database, not only in the application (S1-b brief S1B-GAP-11; BR-ORG-014, FR-ACC-017, BR-ACC-015).

     grants        org.AuthorityGrant: REVOKED and SUPERSEDED are final, and an ACTIVE grant keeps its substance
                   (grantee, power type, bank, ceiling, period and joint rule). A substantive change is a new grant
                   that supersedes the old one on its approval (BR-ORG-014). Error 50175.
     authorities   acc.SignatoryAuthority is never edited in place: a change closes the row (ValidTo, SupersededById)
                   and opens a new one (FR-ACC-017). tp_app may not update what the authority is.
     conflicts     acc.AuthorityConflict: the authority, the code, the fingerprint and the detection time of a
                   conflict do not change; a new fingerprint is a new row (BR-ACC-015). */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER TRIGGER org.TR_AuthorityGrant_Lifecycle ON org.AuthorityGrant
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d
               JOIN inserted AS i ON i.TenantId = d.TenantId AND i.AuthorityGrantId = d.AuthorityGrantId
               WHERE (d.Status IN ('REVOKED', 'SUPERSEDED') AND i.Status <> d.Status)
                  OR (d.Status = 'ACTIVE' AND i.Status IN ('DRAFT', 'PENDING_APPROVAL'))
                  OR (d.Status = 'ACTIVE'
                      AND (i.GranteeKind <> d.GranteeKind OR i.PowerTypeId <> d.PowerTypeId OR i.ValidFrom <> d.ValidFrom
                           OR i.RequiresJoint <> d.RequiresJoint
                           OR EXISTS (SELECT i.BodyId, i.BodyMemberId, i.PartyId, i.InstitutionId, i.CeilingAmount,
                                             i.CeilingCurrencyId, i.ValidTo, i.JointMinSignatories
                                      EXCEPT
                                      SELECT d.BodyId, d.BodyMemberId, d.PartyId, d.InstitutionId, d.CeilingAmount,
                                             d.CeilingCurrencyId, d.ValidTo, d.JointMinSignatories))))
        THROW 50175, 'A revoked or superseded grant is final, and an active grant keeps its substance; a change is a new grant that supersedes it (BR-ORG-014)', 1;
END;
GO
DENY UPDATE (SignatoryId, RelationshipId, BankAccountId, OperationTypeId, CeilingMode, MaxPerTransaction, DailyLimit,
             CurrencyId, IsJoint, JointMinCosigners, ValidFrom) ON acc.SignatoryAuthority TO [tp_app];
DENY UPDATE (SignatoryAuthorityId, ConflictCode, Fingerprint, DetectedOn) ON acc.AuthorityConflict TO [tp_app];
GO

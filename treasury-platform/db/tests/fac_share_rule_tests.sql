/* ============================================================================
   Tests for db/static/050_fac_share_rule.sql (V-FAC-02).
   Run against a deployed BankFas database that holds no real data:
       sqlcmd -S <server> -E -I -b -i db\tests\fac_share_rule_tests.sql
   Foreign-key and CHECK constraints are switched off for the two tables under test, so rows can be
   created without their parent rows. The triggers stay on. A trigger error makes the whole transaction
   uncommittable, so every test runs in its own transaction, with its own setup, and rolls back.
   Each test prints PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
ALTER TABLE fac.Facility NOCHECK CONSTRAINT ALL;
ALTER TABLE fac.FacilityLender NOCHECK CONSTRAINT ALL;
ALTER TABLE fac.FacilityRevision NOCHECK CONSTRAINT ALL;
GO
/* An approval records the APPROVED revision first, then raises the facility's ApprovedRevisionNo, as the facility
   trigger of 044 requires (DR-28). */
CREATE PROCEDURE #Approve @FacilityId BIGINT, @RevisionNo INT
AS
BEGIN
    INSERT fac.FacilityRevision (TenantId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn)
    VALUES (1, @FacilityId, @RevisionNo, CASE WHEN @RevisionNo = 1 THEN 'INITIAL' ELSE 'AMENDMENT' END, 'APPROVED', '2026-01-01');
    UPDATE fac.Facility SET ApprovedRevisionNo = @RevisionNo WHERE FacilityId = @FacilityId;
END;
GO
/* The row filters (010) show rows only to a connection bound to the tenant (sec.SessionBinding, O-16).
   Bind this session to tenant 1; tenant 1 is not seeded here, so the binding's foreign key is switched off too.
   The binding row is removed at the end. */
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT ALL;
SET IDENTITY_INSERT plat.Tenant ON;
INSERT plat.Tenant (TenantId, Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone)
VALUES (1, N'TST-TRG', N'Trigger test', N'Trigger test', 1, 1, 'ACTIVE', 'Asia/Riyadh');
SET IDENTITY_INSERT plat.Tenant OFF;
ALTER TABLE sec.SessionBinding NOCHECK CONSTRAINT ALL;
DECLARE @tok UNIQUEIDENTIFIER = NEWID();
MERGE sec.SessionBinding AS b
USING (SELECT @@SPID AS SessionId) AS s
   ON b.SessionId = s.SessionId
WHEN MATCHED THEN
    UPDATE SET BoundTenantId = 1, BoundUserId = 0, BindingToken = @tok, BoundAt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (s.SessionId, 1, 0, @tok);
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @tok;
GO

/* T1: shares totalling 100 for the approved revision: approval is accepted. */
BEGIN TRANSACTION;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = 1;
DECLARE @f BIGINT;
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (1, N'TEST-T1', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f = SCOPE_IDENTITY();
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 1, 'LEAD', 60, 1);
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 2, 'PARTICIPANT', 40, 1);
BEGIN TRY
    EXEC #Approve @f, 1;
    PRINT 'PASS T1: approval with shares totalling 100 is accepted';
END TRY
BEGIN CATCH
    PRINT 'FAIL T1: ' + ERROR_MESSAGE();
END CATCH;
ROLLBACK TRANSACTION;
GO

/* T2: approved at revision 1 with 60 + 40; a third lender at 5 for revision 1 is rejected: the rows of an approved
   revision do not change (044, self-review A1). */
BEGIN TRANSACTION;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = 1;
DECLARE @f BIGINT;
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (1, N'TEST-T2', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f = SCOPE_IDENTITY();
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 1, 'LEAD', 60, 1);
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 2, 'PARTICIPANT', 40, 1);
EXEC #Approve @f, 1;
BEGIN TRY
    INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 3, 'PARTICIPANT', 5, 1);
    PRINT 'FAIL T2: a total of 105 was accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50049 PRINT 'PASS T2: a lender added to the approved revision is rejected (50049)';
    ELSE PRINT 'FAIL T2: ' + ERROR_MESSAGE();
END CATCH;
ROLLBACK TRANSACTION;
GO

/* T2b: the share rule on its own: with the freeze of 044 switched off inside the transaction, a third lender at 5
   (total 105) on the approved revision is rejected by this trigger (50071). */
BEGIN TRANSACTION;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = 1;
DECLARE @f BIGINT;
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (1, N'TEST-T2B', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f = SCOPE_IDENTITY();
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 1, 'LEAD', 60, 1);
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 2, 'PARTICIPANT', 40, 1);
EXEC #Approve @f, 1;
DISABLE TRIGGER fac.TR_FacilityLender_ApprovedFrozen ON fac.FacilityLender;
BEGIN TRY
    INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 3, 'PARTICIPANT', 5, 1);
    PRINT 'FAIL T2b: a total of 105 was accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50071 PRINT 'PASS T2b: a total of 105 on the approved revision is rejected (50071)';
    ELSE PRINT 'FAIL T2b: ' + ERROR_MESSAGE();
END CATCH;
ROLLBACK TRANSACTION;
GO

/* T3: approved at revision 1; revision-1 rows closed at revision 2; approval of revision 2 without
   lenders for revision 2 is rejected. */
BEGIN TRANSACTION;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = 1;
DECLARE @f BIGINT;
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (1, N'TEST-T3', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f = SCOPE_IDENTITY();
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 1, 'LEAD', 60, 1);
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 2, 'PARTICIPANT', 40, 1);
EXEC #Approve @f, 1;
UPDATE fac.FacilityLender SET ToRevision = 2 WHERE FacilityId = @f;
BEGIN TRY
    EXEC #Approve @f, 2;
    PRINT 'FAIL T3: approval of revision 2 without lenders for revision 2 was accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50072 PRINT 'PASS T3: approval of revision 2 without lenders for it is rejected';
    ELSE PRINT 'FAIL T3: ' + ERROR_MESSAGE();
END CATCH;
ROLLBACK TRANSACTION;
GO

/* T4: revision-2 lenders totalling 100 are added after the revision-1 rows are closed; approval of revision 2 is accepted. */
BEGIN TRANSACTION;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = 1;
DECLARE @f BIGINT;
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (1, N'TEST-T4', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f = SCOPE_IDENTITY();
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 1, 'LEAD', 60, 1);
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 2, 'PARTICIPANT', 40, 1);
EXEC #Approve @f, 1;
UPDATE fac.FacilityLender SET ToRevision = 2 WHERE FacilityId = @f;
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 1, 'LEAD', 100, 2);
BEGIN TRY
    EXEC #Approve @f, 2;
    PRINT 'PASS T4: approval of revision 2 with shares totalling 100 is accepted';
END TRY
BEGIN CATCH
    PRINT 'FAIL T4: ' + ERROR_MESSAGE();
END CATCH;
ROLLBACK TRANSACTION;
GO

/* T5: two lenders with the AGENT role (shares total 100): approval is rejected. */
BEGIN TRANSACTION;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = 1;
DECLARE @f BIGINT;
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (1, N'TEST-T5', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f = SCOPE_IDENTITY();
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 1, 'AGENT,LEAD', 50, 1);
INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 2, 'AGENT,PARTICIPANT', 50, 1);
BEGIN TRY
    EXEC #Approve @f, 1;
    PRINT 'FAIL T5: approval with two agents was accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50072 PRINT 'PASS T5: approval with two agents is rejected';
    ELSE PRINT 'FAIL T5: ' + ERROR_MESSAGE();
END CATCH;
ROLLBACK TRANSACTION;
GO

/* T6: a draft that is not approved may hold partial shares; a single lender at 60 is accepted. */
BEGIN TRANSACTION;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = 1;
DECLARE @f BIGINT;
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (1, N'TEST-T6', 1, 1, 1, 1000, 'EN', '2026-01-01', '2027-01-01');
SET @f = SCOPE_IDENTITY();
BEGIN TRY
    INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (1, @f, 1, 'LEAD', 60, 1);
    PRINT 'PASS T6: a partial draft (60) is accepted before approval';
END TRY
BEGIN CATCH
    PRINT 'FAIL T6: ' + ERROR_MESSAGE();
END CATCH;
ROLLBACK TRANSACTION;
GO

DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
ALTER TABLE sec.SessionBinding WITH CHECK CHECK CONSTRAINT ALL;
DELETE FROM plat.Tenant WHERE TenantId = 1;
ALTER TABLE plat.Tenant WITH CHECK CHECK CONSTRAINT ALL;
ALTER TABLE fac.Facility WITH CHECK CHECK CONSTRAINT ALL;
ALTER TABLE fac.FacilityLender WITH CHECK CHECK CONSTRAINT ALL;
ALTER TABLE fac.FacilityRevision WITH CHECK CHECK CONSTRAINT ALL;
PRINT 'Tests finished; every test rolled back.';
GO

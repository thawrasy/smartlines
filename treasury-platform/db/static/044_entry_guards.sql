/* ============================================================================
   BankFas - 044: the entry conditions of the slices, from the design review (O-15, batch B;
   docs/32-review-findings-decisions.md section 5, docs/adr/0011-design-review-fixes.md)

   Each finding of batch B must hold before its slice's code. The model carries the declarative part (columns,
   composite keys, checks); what a check cannot see is here:
     DR-22 (S1-b)  org.Shareholding: an indirect holding is entered per path through a named intermediate, and the
                   intermediate is never a company of the tenant, whose paths come from its own direct holdings
                   (BR-ORG-008). A party used as an intermediate in an open path becomes a company of the tenant only
                   after those paths are closed.

   An error raised in a trigger ends the caller's transaction; the application validates first.
   Errors: 50047 an indirect path through a company of the tenant.
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

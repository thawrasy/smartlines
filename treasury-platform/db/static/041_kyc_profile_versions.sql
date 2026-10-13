/* ============================================================================
   BankFas - 041: a KYC completeness profile changes only while it is a DRAFT (O-13 in tools/dbgen/erd_open_items.py;
   FR-PTY-023, FR-PTY-024, UC-PTY-10)

   A profile version is written as DRAFT, its items and their legal-form conditions are added, and then it is
   activated, which retires the version before it (pty.KycProfile in db/model/11-organization-party.model). Past
   completeness checks were made against an ACTIVE or RETIRED version, so its items and conditions no longer change:
   a change is a new version. An ACTIVE or RETIRED version never returns to DRAFT.
   This also bounds the one cascade left in the model: the legal-form conditions of an item go with the item, and an
   item can be deleted only from a draft version.
   The rule holds for every caller, seeds included: a tenant pack writes a profile as DRAFT, adds its items, then
   activates it.

   Error: 50033 the items of an active or retired profile change, or a profile returns to DRAFT.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER TRIGGER pty.TR_KycProfile_NoReturnToDraft ON pty.KycProfile
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN deleted AS d ON d.TenantId = i.TenantId AND d.KycProfileId = i.KycProfileId
               WHERE i.Status = 'DRAFT' AND d.Status <> 'DRAFT')
        THROW 50033, 'An active or retired KYC profile does not return to draft; create a new version', 1;
END;
GO
CREATE OR ALTER TRIGGER pty.TR_KycProfileItem_DraftOnly ON pty.KycProfileItem
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, ProfileId FROM inserted UNION SELECT TenantId, ProfileId FROM deleted) AS r
               JOIN pty.KycProfile AS p ON p.TenantId = r.TenantId AND p.KycProfileId = r.ProfileId
               WHERE p.Status <> 'DRAFT')
        THROW 50033, 'The items of an active or retired KYC profile do not change; create a new version', 1;
END;
GO
-- A condition deleted by the cascade from its item finds no item here (the item is already gone); the item trigger
-- has then checked the profile.
CREATE OR ALTER TRIGGER pty.TR_KycProfileItemLegalForm_DraftOnly ON pty.KycProfileItemLegalForm
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, KycProfileItemId FROM inserted UNION SELECT TenantId, KycProfileItemId FROM deleted) AS r
               JOIN pty.KycProfileItem AS it ON it.TenantId = r.TenantId AND it.KycProfileItemId = r.KycProfileItemId
               JOIN pty.KycProfile AS p ON p.TenantId = it.TenantId AND p.KycProfileId = it.ProfileId
               WHERE p.Status <> 'DRAFT')
        THROW 50033, 'The item conditions of an active or retired KYC profile do not change; create a new version', 1;
END;
GO

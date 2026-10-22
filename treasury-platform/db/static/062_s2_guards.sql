/* 062_s2_guards.sql — what an approved tariff, an approved collateral and a system comparable term keep is kept in the
   database, not only in the application (S2 brief S2-GAP-7, S2-GAP-13, S2-GAP-15; FR-CMP-001, FR-PRC-001, FR-COL-014).

     term keys     cmp.TermType is a tenant catalogue outside the cat schema, so 060 does not cover it: tp_app may not
                   change Code, Unit, ValueKind, IsSystem, IsLocked or SeedKey ("the code and the unit do not change",
                   BR-CMP-001), and a system or locked key comes only from the seeder (50174, as in 060).
     tariffs       an APPROVED schedule changes only to SUPERSEDED, and only its EffectiveTo may be set, once; a
                   SUPERSEDED schedule is final; the items and tiers of a schedule that is not DRAFT do not change
                   (FR-PRC-001: "the approved schedule is fixed"). Error 50176.
     collateral    the typed parts of an APPROVED collateral version (guarantee, promissory note and its signers,
                   insurance assignment, valuation schedule) do not change; a change is a new version (FR-COL-014).
                   The exceptions: the last renewal of a note and the last valuation (operational dates), and the
                   guarantor and the signers when two parties are merged into one (FR-PTY-016: the same person).
                   Error 50176.
     utilisation   a RELEASED or TRANSFERRED utilisation is final (spec 12 section 8). Error 50176. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
DENY UPDATE (Code, Unit, ValueKind, IsSystem, IsLocked, SeedKey) ON cmp.TermType TO [tp_app];
GO
CREATE OR ALTER TRIGGER cmp.TR_TermType_SeedRows ON cmp.TermType
AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted WHERE IsSystem = 1 OR IsLocked = 1) RETURN;
    IF ISNULL(CAST(SESSION_CONTEXT(N'JobKey') AS VARCHAR(80)), '') = 'JOB-PLT-ONBOARD'
       AND EXISTS (SELECT 1 FROM sec.SessionBinding WHERE SessionId = @@SPID AND BindingKind = 'JOB') RETURN;
    IF IS_ROLEMEMBER(N'tp_app') = 0 AND IS_MEMBER(N'db_owner') = 1 RETURN;   -- the deployment and its tests
    THROW 50174, 'A system or locked comparable term comes only from the seed packs', 1;
END;
GO
CREATE OR ALTER TRIGGER prc.TR_TariffSchedule_Final ON prc.TariffSchedule
AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d
               JOIN inserted AS i ON i.TenantId = d.TenantId AND i.TariffScheduleId = d.TariffScheduleId
               WHERE d.Status = 'SUPERSEDED' AND (i.Status <> d.Status OR i.EffectiveTo IS DISTINCT FROM d.EffectiveTo)
                  OR d.Status = 'APPROVED' AND (i.Status = 'DRAFT'
                      OR (d.EffectiveTo IS NOT NULL AND i.EffectiveTo IS DISTINCT FROM d.EffectiveTo)
                      OR EXISTS (SELECT i.InstitutionId, i.FacilityId, i.NameAr, i.NameEn, i.VersionNo, i.EffectiveFrom, i.SourceDocumentId, i.ApprovedBy, i.ApprovedOn
                                 EXCEPT
                                 SELECT d.InstitutionId, d.FacilityId, d.NameAr, d.NameEn, d.VersionNo, d.EffectiveFrom, d.SourceDocumentId, d.ApprovedBy, d.ApprovedOn)))
        THROW 50176, 'An approved tariff schedule is fixed: it is superseded by a new version, and only its end date is set once (FR-PRC-001)', 1;
END;
GO
CREATE OR ALTER TRIGGER prc.TR_TariffItem_Frozen ON prc.TariffItem
AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM (SELECT TenantId, ScheduleId FROM inserted UNION ALL SELECT TenantId, ScheduleId FROM deleted) AS x
               JOIN prc.TariffSchedule AS s ON s.TenantId = x.TenantId AND s.TariffScheduleId = x.ScheduleId
               WHERE s.Status <> 'DRAFT')
        THROW 50176, 'The items of an approved tariff schedule are fixed; a change is a new version of the schedule (FR-PRC-001)', 1;
END;
GO
CREATE OR ALTER TRIGGER prc.TR_TariffTier_Frozen ON prc.TariffTier
AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM (SELECT TenantId, TariffItemId FROM inserted UNION ALL SELECT TenantId, TariffItemId FROM deleted) AS x
               JOIN prc.TariffItem AS t ON t.TenantId = x.TenantId AND t.TariffItemId = x.TariffItemId
               JOIN prc.TariffSchedule AS s ON s.TenantId = t.TenantId AND s.TariffScheduleId = t.ScheduleId
               WHERE s.Status <> 'DRAFT')
        THROW 50176, 'The tiers of an approved tariff schedule are fixed; a change is a new version of the schedule (FR-PRC-001)', 1;
END;
GO
-- The typed parts of a collateral version, one trigger per table, built from sys.columns so a column added later is
-- covered when this script runs again. @free lists the operational columns that may still change.
DECLARE @parts TABLE (TableName SYSNAME, FreeColumns NVARCHAR(400), KeyColumn SYSNAME, ViaNote BIT);
INSERT @parts VALUES (N'Guarantee', N'GuarantorPartyId,GuarantorIdentityDocumentId', N'CollateralId', 0), (N'PromissoryNote', N'LastRenewedOn', N'CollateralId', 0),
                     (N'InsurancePolicyAssignment', N'', N'CollateralId', 0), (N'ValuationSchedule', N'LastValuationOn,LastValuationAmount,CurrencyId', N'CollateralId', 0);
DECLARE @t SYSNAME, @free NVARCHAR(400), @key SYSNAME, @cols NVARCHAR(MAX), @ci NVARCHAR(MAX), @cd NVARCHAR(MAX), @pk SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT TableName, FreeColumns, KeyColumn FROM @parts;
OPEN c; FETCH NEXT FROM c INTO @t, @free, @key;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @pk = col.name FROM sys.indexes AS ix
      JOIN sys.index_columns AS ic ON ic.object_id = ix.object_id AND ic.index_id = ix.index_id
      JOIN sys.columns AS col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
     WHERE ix.object_id = OBJECT_ID(N'col.' + @t) AND ix.is_primary_key = 1 AND col.name <> N'TenantId';
    SELECT @ci = STRING_AGG(N'i.' + QUOTENAME(name), N', ') WITHIN GROUP (ORDER BY column_id),
           @cd = STRING_AGG(N'd.' + QUOTENAME(name), N', ') WITHIN GROUP (ORDER BY column_id)
      FROM sys.columns
     WHERE object_id = OBJECT_ID(N'col.' + @t) AND is_computed = 0 AND system_type_id <> 189   -- not the row version
       AND name NOT IN (N'UpdatedAt', N'UpdatedBy', N'CreatedAt', N'CreatedBy')
       AND name NOT IN (SELECT value FROM STRING_SPLIT(@free, N','));
    SET @sql = N'CREATE OR ALTER TRIGGER col.' + QUOTENAME(N'TR_' + @t + N'_VersionFrozen') + N' ON col.' + QUOTENAME(@t) + N'
AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i FULL JOIN deleted AS d ON d.TenantId = i.TenantId AND d.' + QUOTENAME(@pk) + N' = i.' + QUOTENAME(@pk) + N'
               JOIN col.Collateral AS k ON k.TenantId = ISNULL(i.TenantId, d.TenantId) AND k.CollateralId IN (i.' + QUOTENAME(@key) + N', d.' + QUOTENAME(@key) + N')
               WHERE k.ApprovalState = ''APPROVED''
                 AND (i.' + QUOTENAME(@pk) + N' IS NULL OR d.' + QUOTENAME(@pk) + N' IS NULL
                      OR EXISTS (SELECT ' + @ci + N' EXCEPT SELECT ' + @cd + N')))
        THROW 50176, ''The parts of an approved collateral version are fixed; a change is a new version (FR-COL-014)'', 1;
END;';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM c INTO @t, @free, @key;
END;
CLOSE c; DEALLOCATE c;
GO
CREATE OR ALTER TRIGGER col.TR_PromissoryNoteSigner_ApprovedFrozen ON col.PromissoryNoteSigner
AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    -- An update that moves a signer to the party it was merged into keeps the count of signers; adding or removing one does not.
    IF EXISTS (SELECT 1 FROM (SELECT TenantId, PromissoryNoteId, 1 AS n FROM inserted UNION ALL SELECT TenantId, PromissoryNoteId, -1 FROM deleted) AS x
               JOIN col.PromissoryNote AS n ON n.TenantId = x.TenantId AND n.PromissoryNoteId = x.PromissoryNoteId
               JOIN col.Collateral AS k ON k.TenantId = n.TenantId AND k.CollateralId = n.CollateralId
               WHERE k.ApprovalState = 'APPROVED'
               GROUP BY x.TenantId, x.PromissoryNoteId HAVING SUM(x.n) <> 0)
        THROW 50176, 'The signers of the note of an approved collateral version are fixed; a change is a new version (FR-COL-014)', 1;
END;
GO
CREATE OR ALTER TRIGGER fac.TR_Utilization_Final ON fac.Utilization
AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d
               JOIN inserted AS i ON i.TenantId = d.TenantId AND i.UtilizationId = d.UtilizationId
               WHERE d.Status IN ('RELEASED', 'TRANSFERRED') AND i.Status <> d.Status)
        THROW 50176, 'A released or transferred utilisation is final (spec 12 section 8)', 1;
END;
GO

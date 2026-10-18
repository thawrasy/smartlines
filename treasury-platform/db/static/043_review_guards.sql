/* ============================================================================
   BankFas - 043: guards from the design review (O-15, docs/32-review-findings-decisions.md,
   docs/adr/0011-design-review-fixes.md)

   The model carries the declarative part of each fix (checks, composite keys, the global StorageKey key). What a
   check cannot see, the previous value of a row, a row of another table or a column the application must not
   change, is here:
     DR-11  doc.DocumentVersion is immutable content: the application may update only the scan and integrity
            columns. Re-encrypting a file under a new FILE key (DOC-S02) writes a new version.
     DR-14  cfg.OutboxEvent: only a DELIVERED event may be deleted; a pending, failed or dead one is evidence.
     DR-15  plat.SupportAccessGrant: the tenant's consent record. The application may only revoke a grant, and a
            revocation is final.
     DR-16  sec.RolePermission: a locked permission (sec.Permission.LockedToRoleCodes) goes only to a system role
            whose code the lock names, and the application cannot change a role's Code, IsSystem or SeedKey, on
            which this rule and the account-administrator checks (030, 038) rest.
     DR-18  doc.Document: a document whose type is sensitive is RESTRICTED. Marking a type sensitive raises its
            existing documents to RESTRICTED.
     DR-19  acc.Signatory: a revoked or expired signatory stays so; a renewal is a new row (BR-ACC-009).
     DR-31  the verbatim text of agreements (OriginalText of every sourced row, the two candidate texts of a value
            conflict, an obligation's ClauseText) is confidential and may quote accounts: the reporting role
            tp_readonly, and the support role through it, does not read it.
     DR-41  lc.ProformaInvoice: after issue only its status, void reason and successor change; its lines are
            append-only in the model.

   An error raised in a trigger ends the caller's transaction; the application validates first.
   Errors: 50041 an undelivered outbox event is deleted, 50042 a revoked support grant changes, 50043 a locked
   permission is given to another role, 50045 a document below the sensitivity of its type, 50046 a revoked or expired
   signatory changes status.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
/* DR-11: the content of a version never changes (BR-PLT-011, FR-PLT-031). tp_jobs inherits the DENY through tp_app. */
DENY UPDATE ON doc.DocumentVersion (DocumentId, VersionNo, StorageKey, FileName, ContentType, SizeBytes, Sha256,
                                    KeyPurpose, KeyId, CreatedAt, CreatedBy) TO [tp_app];
GO
/* DR-14 */
CREATE OR ALTER TRIGGER cfg.TR_OutboxEvent_KeepUndelivered ON cfg.OutboxEvent
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted WHERE Status <> 'DELIVERED')
        THROW 50041, 'Only a delivered outbox event may be deleted; a pending, failed or dead event stays as evidence', 1;
END;
GO
/* DR-15: the grant's operator, period and reason are the tenant's consent; only the revocation columns change. */
DENY UPDATE ON plat.SupportAccessGrant (OperatorId, GrantedBy, StartsAt, EndsAt, Reason, CreatedAt, CreatedBy) TO [tp_app];
GO
CREATE OR ALTER TRIGGER plat.TR_SupportAccessGrant_RevocationFinal ON plat.SupportAccessGrant
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d
               JOIN inserted AS i ON i.TenantId = d.TenantId AND i.SupportAccessGrantId = d.SupportAccessGrantId
               WHERE d.RevokedAt IS NOT NULL
                 AND (i.RevokedAt IS NULL OR i.RevokedAt <> d.RevokedAt OR i.RevokedBy IS NULL OR i.RevokedBy <> d.RevokedBy))
        THROW 50042, 'A revoked support grant stays revoked; the tenant administrator makes a new grant', 1;
END;
GO
/* DR-16 */
DENY UPDATE ON sec.Role (Code, IsSystem, SeedKey) TO [tp_app];
GO
CREATE OR ALTER TRIGGER sec.TR_RolePermission_Locked ON sec.RolePermission
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM inserted AS i
               JOIN sec.Permission AS p ON p.PermissionId = i.PermissionId
               JOIN sec.Role AS r ON r.TenantId = i.TenantId AND r.RoleId = i.RoleId
               WHERE p.LockedToRoleCodes IS NOT NULL
                 AND (r.IsSystem = 0
                      OR NOT EXISTS (SELECT 1 FROM OPENJSON(p.LockedToRoleCodes) AS j
                                     WHERE j.[value] COLLATE DATABASE_DEFAULT = r.Code)))
        THROW 50043, 'A locked permission is given only to the system roles it names (BR-PLT-019)', 1;
END;
GO
/* DR-18: the sensitivity floor of a document type (DOC-S06 section 4). */
CREATE OR ALTER TRIGGER doc.TR_Document_SensitivityFloor ON doc.Document
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i
               JOIN cat.DocumentType AS t WITH (UPDLOCK, HOLDLOCK) ON t.TenantId = i.TenantId AND t.DocumentTypeId = i.DocumentTypeId
               WHERE t.IsSensitive = 1 AND i.Sensitivity <> 'RESTRICTED')
        THROW 50045, 'A document of a sensitive type is RESTRICTED (DOC-S06)', 1;
END;
GO
CREATE OR ALTER TRIGGER cat.TR_DocumentType_SensitivityFloor ON cat.DocumentType
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE d SET Sensitivity = 'RESTRICTED'
    FROM doc.Document AS d
    JOIN inserted AS i ON i.TenantId = d.TenantId AND i.DocumentTypeId = d.DocumentTypeId
    JOIN deleted AS o ON o.TenantId = i.TenantId AND o.DocumentTypeId = i.DocumentTypeId
    WHERE i.IsSensitive = 1 AND o.IsSensitive = 0 AND d.Sensitivity <> 'RESTRICTED';
END;
GO
/* DR-19 */
CREATE OR ALTER TRIGGER acc.TR_Signatory_FinalStatus ON acc.Signatory
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d
               JOIN inserted AS i ON i.TenantId = d.TenantId AND i.SignatoryId = d.SignatoryId
               WHERE d.Status IN ('REVOKED', 'EXPIRED') AND i.Status <> d.Status)
        THROW 50046, 'A revoked or expired signatory keeps its status; a renewal is a new signatory row', 1;
END;
GO
/* DR-31 */
DECLARE @deny NVARCHAR(MAX) = N'';
SELECT @deny += N'DENY SELECT ON ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N' (' + QUOTENAME(c.name) + N') TO [tp_readonly];' + CHAR(10)
FROM sys.columns AS c
JOIN sys.tables AS t ON t.object_id = c.object_id
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE s.name IN (N'fac', N'prc', N'cmp', N'col', N'obl', N'fin')
  AND c.name IN (N'OriginalText', N'CandidateAOriginalText', N'CandidateBOriginalText', N'ClauseText');
EXEC sys.sp_executesql @deny;
GO
/* DR-41 */
DENY UPDATE ON lc.ProformaInvoice (CompanyId, ProformaNo, NumberYear, NumberSeq, RequestId, ErpCompanyCodeSnapshot, BranchCode,
                                   BranchName, ProjectCode, ProjectName, ProjectSite, CustomerId, CustomerSnapshotJson, IssueDate,
                                   OfferValidityDays, CurrencyId, Subtotal, VatRatePct, VatAmount, Total, LcPaymentPct, PlacesJson,
                                   TermsPurpose, TermsId, ProceedsAccountId, PrintLanguage, DocumentId, PublicId, CreatedAt,
                                   CreatedBy) TO [tp_app];
GO

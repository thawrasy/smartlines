/* ============================================================================
   BankFas - 042: the tenant data export in every status that allows it (DQ-F04-8; FR-PLT-039, BR-PLT-002, BR-PLT-016;
   DOC-F04 section 7.4, DOC-F05 section 6.4; docs/adr/0008-data-export-in-read-only-states.md)

   The account administrator keeps the right to export in SUSPENDED and, for 30 days after ClosedAt, in CLOSED
   (BR-PLT-002). Those statuses refuse every direct write (rls.fn_BoundWrite), so the export moves through procedures
   run as tp_auth_exec, and the application role loses the direct rights on cfg.DataExportJob (DENYs at the end).
     cfg.usp_RequestDataExport    a user bound to the tenant (USER binding) asks for an export. The user needs the
                                  permission cfg.export.request through a role, and must still be admitted by the
                                  tenant status (sec.fn_TenantLoginAllowed: the account administrator alone in
                                  SUSPENDED and CLOSED). One export at a time. Without restricted data, or when the
                                  user also holds party.identity.reveal, it is APPROVED at once; otherwise it waits.
     cfg.usp_ApproveDataExport    a holder of party.identity.reveal approves an export with restricted data (BR-PLT-016).
     cfg.usp_StartDataExport      the export job (JOB-PLT-EXPORT, as the service account) takes an approved export:
                                  RUNNING; it returns the scope to build.
     cfg.usp_FinishDataExport     the job records the sealed package: a doc.Document of type DATA_EXPORT_PACKAGE with
                                  one version (the file is in the tenant's store, encrypted with its FILE key), READY,
                                  expiring after 7 days, or when the CLOSED window ends if that comes first.
     cfg.usp_FailDataExport       the job records a failure with its reason.
     cfg.usp_ExpireDataExports    JOB-PLT-EXPORT-EXPIRE: READY packages past ExpiresAt become EXPIRED, their document
                                  is soft-deleted, and the storage keys are returned so the job deletes the files.
   Every step writes its audit row (ADR 0007): EXPORT_REQUESTED, EXPORT_APPROVED and EXPORT_READY with high severity
   (BR-PLT-009), EXPORT_READY with the package's SHA-256 (FR-PLT-039); a package with restricted data also gets a row
   in aud.SensitiveAccessLog (DATA_EXPORT). The package password is never sent to the database.

   Errors: 50034 not allowed (binding, permission or tenant status), 50035 an export is already in progress,
   50036 no export in the expected state, 50037 the tenant has no DATA_EXPORT_PACKAGE document type or no active FILE
   key.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
-- Whether a user holds a permission through one of their active roles (sec.UserRole, sec.RolePermission).
CREATE OR ALTER FUNCTION sec.fn_UserHasPermission (@TenantId INT, @UserId BIGINT, @Code VARCHAR(80))
RETURNS TABLE
AS RETURN
    SELECT 1 AS HasPermission
    WHERE EXISTS (SELECT 1
                  FROM sec.UserRole AS ur
                  JOIN sec.Role AS r ON r.TenantId = ur.TenantId AND r.RoleId = ur.RoleId AND r.IsActive = 1
                  JOIN sec.RolePermission AS rp ON rp.TenantId = r.TenantId AND rp.RoleId = r.RoleId
                  JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId
                  WHERE ur.TenantId = @TenantId AND ur.UserId = @UserId AND p.Code = @Code);
GO
-- The bound user of a USER binding of this tenant, still admitted by the tenant status, or NULL.
CREATE OR ALTER FUNCTION sec.fn_ExportUser (@TenantId INT)
RETURNS TABLE
AS RETURN
    SELECT CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) AS UserId
    WHERE EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@TenantId, 0))
      AND EXISTS (SELECT 1 FROM sec.fn_TenantLoginAllowed(@TenantId, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)));
GO
-- The tenant of a JOB binding for this job, when the tenant status still allows the job, or NULL.
CREATE OR ALTER FUNCTION sec.fn_JobTenant (@JobKey VARCHAR(80))
RETURNS TABLE
AS RETURN
    SELECT b.BoundTenantId AS TenantId, b.BoundUserId AS ServiceUserId
    FROM sec.SessionBinding AS b
    WHERE b.SessionId = @@SPID AND b.BindingKind = 'JOB'
      AND CAST(SESSION_CONTEXT(N'JobKey') AS VARCHAR(80)) = @JobKey
      AND CAST(SESSION_CONTEXT(N'TenantId') AS INT) = b.BoundTenantId
      AND EXISTS (SELECT 1 FROM sec.fn_JobAllowed(b.BoundTenantId, @JobKey));
GO
/* ---------- The user's side ---------- */

CREATE OR ALTER PROCEDURE cfg.usp_RequestDataExport
    @TenantId           INT,
    @Scope              VARCHAR(7) = 'FULL',
    @ScopeDetailJson    NVARCHAR(MAX) = NULL,
    @IncludesRestricted BIT = 0,
    @DataExportJobId    BIGINT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @DataExportJobId = NULL;
    DECLARE @user BIGINT = (SELECT UserId FROM sec.fn_ExportUser(@TenantId)), @own BIT = 0, @reveal BIT = 0,
            @now DATETIME2(3) = SYSUTCDATETIME();
    IF @user IS NULL THROW 50034, 'A user bound to this tenant and admitted by its status is required', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@TenantId, @user, 'cfg.export.request'))
        THROW 50034, 'The permission cfg.export.request is required', 1;
    IF @IncludesRestricted = 1 AND EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@TenantId, @user, 'party.identity.reveal'))
        SET @reveal = 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_RequestDataExport;
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM cfg.DataExportJob WITH (UPDLOCK, HOLDLOCK)
                   WHERE TenantId = @TenantId AND Status IN ('REQUESTED', 'APPROVED', 'RUNNING'))
            THROW 50035, 'An export of this tenant is already in progress', 1;
        INSERT cfg.DataExportJob (TenantId, RequestedBy, RequestedAt, Scope, ScopeDetailJson, IncludesRestricted, Status,
                                  ApprovedBy, ApprovedAt)
        VALUES (@TenantId, @user, @now, @Scope, @ScopeDetailJson, @IncludesRestricted,
                CASE WHEN @IncludesRestricted = 0 OR @reveal = 1 THEN 'APPROVED' ELSE 'REQUESTED' END,
                CASE WHEN @reveal = 1 THEN @user END, CASE WHEN @reveal = 1 THEN @now END);
        SET @DataExportJobId = SCOPE_IDENTITY();
        DECLARE @category VARCHAR(15) = CASE WHEN @IncludesRestricted = 1 THEN 'IDENTITY_ACCESS' ELSE 'SECURITY' END,
                @after NVARCHAR(400) = (SELECT @Scope AS scope, CAST(@IncludesRestricted AS BIT) AS includesRestricted,
                                               CASE WHEN @IncludesRestricted = 0 OR @reveal = 1 THEN 'APPROVED' ELSE 'REQUESTED' END AS status
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC aud.usp_WriteEvent @TenantId = @TenantId, @Action = 'EXPORT_REQUESTED', @Category = @category, @ActorType = 'USER',
             @ActorUserId = @user, @Severity = 'HIGH', @EntityType = 'cfg.DataExportJob', @EntityId = @DataExportJobId,
             @AfterJson = @after;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_RequestDataExport;   -- undo this procedure only
        SET @DataExportJobId = NULL;
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE cfg.usp_ApproveDataExport
    @TenantId        INT,
    @DataExportJobId BIGINT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @user BIGINT = (SELECT UserId FROM sec.fn_ExportUser(@TenantId)), @own BIT = 0;
    IF @user IS NULL THROW 50034, 'A user bound to this tenant and admitted by its status is required', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@TenantId, @user, 'party.identity.reveal'))
        THROW 50034, 'Only a holder of party.identity.reveal approves an export with restricted data', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_ApproveDataExport;
    BEGIN TRY
        UPDATE cfg.DataExportJob SET Status = 'APPROVED', ApprovedBy = @user, ApprovedAt = SYSUTCDATETIME()
         WHERE TenantId = @TenantId AND DataExportJobId = @DataExportJobId AND Status = 'REQUESTED' AND IncludesRestricted = 1;
        IF @@ROWCOUNT = 0 THROW 50036, 'No export of this tenant waits for approval with this id', 1;
        EXEC aud.usp_WriteEvent @TenantId = @TenantId, @Action = 'EXPORT_APPROVED', @Category = 'IDENTITY_ACCESS', @ActorType = 'USER',
             @ActorUserId = @user, @Severity = 'HIGH', @EntityType = 'cfg.DataExportJob', @EntityId = @DataExportJobId;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ApproveDataExport;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
/* ---------- The export job's side (bound as the service account) ---------- */

-- Takes the oldest approved export of the bound tenant, or the given one: RUNNING. Returns its scope; no row when
-- there is nothing to do.
CREATE OR ALTER PROCEDURE cfg.usp_StartDataExport
    @DataExportJobId BIGINT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tenant INT, @svc BIGINT, @own BIT = 0, @id BIGINT;
    SELECT @tenant = TenantId, @svc = ServiceUserId FROM sec.fn_JobTenant('JOB-PLT-EXPORT');
    IF @tenant IS NULL THROW 50034, 'The connection is not bound as the export job of a tenant that allows it', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_StartDataExport;
    BEGIN TRY
        SELECT TOP (1) @id = DataExportJobId FROM cfg.DataExportJob WITH (UPDLOCK, HOLDLOCK)
        WHERE TenantId = @tenant AND Status = 'APPROVED' AND (@DataExportJobId IS NULL OR DataExportJobId = @DataExportJobId)
        ORDER BY RequestedAt, DataExportJobId;
        IF @id IS NOT NULL
            UPDATE cfg.DataExportJob SET Status = 'RUNNING', StartedAt = SYSUTCDATETIME()
             WHERE TenantId = @tenant AND DataExportJobId = @id;
        SET @DataExportJobId = @id;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_StartDataExport;   -- undo this procedure only
        THROW;
    END CATCH;
    SELECT DataExportJobId, Scope, ScopeDetailJson, IncludesRestricted, RequestedBy
    FROM cfg.DataExportJob WHERE TenantId = @tenant AND DataExportJobId = @id;
END;
GO
CREATE OR ALTER PROCEDURE cfg.usp_FinishDataExport
    @DataExportJobId BIGINT,
    @StorageKey      VARCHAR(300),     -- where the sealed package is in the tenant's store
    @FileName        NVARCHAR(260),
    @SizeBytes       BIGINT,
    @Sha256          VARBINARY(32)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tenant INT, @svc BIGINT, @own BIT = 0, @type INT, @key BIGINT, @restricted BIT, @requester BIGINT,
            @doc BIGINT, @ver BIGINT, @now DATETIME2(3) = SYSUTCDATETIME(), @expires DATETIME2(3), @closedAt DATETIME2(3),
            @status VARCHAR(18), @audit BIGINT;
    SELECT @tenant = TenantId, @svc = ServiceUserId FROM sec.fn_JobTenant('JOB-PLT-EXPORT');
    IF @tenant IS NULL THROW 50034, 'The connection is not bound as the export job of a tenant that allows it', 1;
    IF @StorageKey IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 OR @Sha256 IS NULL OR DATALENGTH(@Sha256) <> 32
        THROW 50001, 'The storage key, the size and the SHA-256 of the package are required', 1;
    SELECT @type = DocumentTypeId FROM cat.DocumentType WHERE TenantId = @tenant AND Code = 'DATA_EXPORT_PACKAGE' AND IsActive = 1;
    SELECT @key = TenantKeyId FROM sec.TenantKey WHERE TenantId = @tenant AND Purpose = 'FILE' AND Status = 'ACTIVE';
    IF @type IS NULL OR @key IS NULL
        THROW 50037, 'The tenant has no active DATA_EXPORT_PACKAGE document type or no active FILE key', 1;
    SELECT @status = Status, @closedAt = ClosedAt FROM plat.Tenant WHERE TenantId = @tenant;
    -- 7 days (FR-PLT-039), and never past the end of the export window of a closed tenant (DOC-F05 section 6.4).
    SET @expires = DATEADD(DAY, 7, @now);
    IF @status = 'CLOSED' AND DATEADD(DAY, 30, @closedAt) < @expires SET @expires = DATEADD(DAY, 30, @closedAt);
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_FinishDataExport;
    BEGIN TRY
        SELECT @restricted = IncludesRestricted, @requester = RequestedBy
        FROM cfg.DataExportJob WITH (UPDLOCK, HOLDLOCK)
        WHERE TenantId = @tenant AND DataExportJobId = @DataExportJobId AND Status = 'RUNNING';
        IF @requester IS NULL THROW 50036, 'No running export of this tenant with this id', 1;

        INSERT doc.Document (TenantId, DocumentTypeId, Title, IssueDate, Sensitivity, Status, CreatedBy)
        VALUES (@tenant, @type, CONCAT(N'Data export ', CONVERT(NVARCHAR(10), @now, 23)), CAST(@now AS DATE),
                -- A package type the tenant marked sensitive is RESTRICTED too: 043 refuses anything else (self-review A10).
                CASE WHEN @restricted = 1 OR EXISTS (SELECT 1 FROM cat.DocumentType WHERE TenantId = @tenant AND DocumentTypeId = @type AND IsSensitive = 1)
                     THEN 'RESTRICTED' ELSE 'CONFIDENTIAL' END, 'ACTIVE', @svc);
        SET @doc = SCOPE_IDENTITY();
        -- Generated by the platform, not uploaded: nothing to scan.
        INSERT doc.DocumentVersion (TenantId, DocumentId, VersionNo, StorageKey, FileName, ContentType, SizeBytes, Sha256,
                                    KeyPurpose, KeyId, ScanStatus, ScannedAt, ScanDetail, CreatedBy)
        VALUES (@tenant, @doc, 1, @StorageKey, @FileName, 'application/zip', @SizeBytes, @Sha256, 'FILE', @key,
                'CLEAN', @now, N'Generated by the platform (data export)', @svc);
        SET @ver = SCOPE_IDENTITY();
        UPDATE doc.Document SET CurrentVersionId = @ver WHERE TenantId = @tenant AND DocumentId = @doc;
        UPDATE cfg.DataExportJob
           SET Status = 'READY', FinishedAt = @now, ExpiresAt = @expires, PackageDocumentId = @doc, PackageSha256 = @Sha256
         WHERE TenantId = @tenant AND DataExportJobId = @DataExportJobId;

        DECLARE @category VARCHAR(15) = CASE WHEN @restricted = 1 THEN 'IDENTITY_ACCESS' ELSE 'SECURITY' END,
                @after NVARCHAR(400) = (SELECT CONVERT(VARCHAR(64), @Sha256, 2) AS sha256, @SizeBytes AS sizeBytes,
                                               CONVERT(VARCHAR(19), @expires, 126) AS expiresAt
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC aud.usp_WriteEvent @TenantId = @tenant, @Action = 'EXPORT_READY', @Category = @category, @ActorType = 'JOB',
             @ActorUserId = @svc, @Severity = 'HIGH', @EntityType = 'cfg.DataExportJob', @EntityId = @DataExportJobId,
             @AfterJson = @after, @AuditLogId = @audit OUTPUT;
        IF @restricted = 1                                       -- restricted data left the database (BR-PTY-009)
            INSERT aud.SensitiveAccessLog (TenantId, OccurredAt, AccessKind, ActorType, ActorUserId, SubjectEntityType,
                                           SubjectEntityId, Result, CorrelationId, AuditLogId)
            VALUES (@tenant, @now, 'DATA_EXPORT', 'USER', @requester, 'DataExportJob', @DataExportJobId, 'GRANTED',
                    CAST(SESSION_CONTEXT(N'CorrelationId') AS UNIQUEIDENTIFIER), @audit);
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_FinishDataExport;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE cfg.usp_FailDataExport
    @DataExportJobId BIGINT,
    @Reason          NVARCHAR(500)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tenant INT, @svc BIGINT, @own BIT = 0;
    SELECT @tenant = TenantId, @svc = ServiceUserId FROM sec.fn_JobTenant('JOB-PLT-EXPORT');
    IF @tenant IS NULL THROW 50034, 'The connection is not bound as the export job of a tenant that allows it', 1;
    IF @Reason IS NULL OR LTRIM(@Reason) = N'' THROW 50001, 'A reason is required', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_FailDataExport;
    BEGIN TRY
        UPDATE cfg.DataExportJob SET Status = 'FAILED', FinishedAt = SYSUTCDATETIME(), FailureReason = @Reason
         WHERE TenantId = @tenant AND DataExportJobId = @DataExportJobId AND Status = 'RUNNING';
        IF @@ROWCOUNT = 0 THROW 50036, 'No running export of this tenant with this id', 1;
        DECLARE @after NVARCHAR(1000) = (SELECT @Reason AS reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC aud.usp_WriteEvent @TenantId = @tenant, @Action = 'EXPORT_FAILED', @Category = 'SECURITY', @ActorType = 'JOB',
             @ActorUserId = @svc, @Result = 'FAILED', @EntityType = 'cfg.DataExportJob', @EntityId = @DataExportJobId,
             @AfterJson = @after;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_FailDataExport;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
-- JOB-PLT-EXPORT-EXPIRE: returns (DataExportJobId, StorageKey) of the packages it expired; the job deletes the files.
CREATE OR ALTER PROCEDURE cfg.usp_ExpireDataExports
    @Expired INT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET @Expired = 0;
    DECLARE @tenant INT, @svc BIGINT, @own BIT = 0, @now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @done TABLE (DataExportJobId BIGINT PRIMARY KEY, DocumentId BIGINT);
    SELECT @tenant = TenantId, @svc = ServiceUserId FROM sec.fn_JobTenant('JOB-PLT-EXPORT-EXPIRE');
    IF @tenant IS NULL THROW 50034, 'The connection is not bound as the export expiry job of a tenant that allows it', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_ExpireDataExports;
    BEGIN TRY
        UPDATE cfg.DataExportJob SET Status = 'EXPIRED'
        OUTPUT inserted.DataExportJobId, inserted.PackageDocumentId INTO @done (DataExportJobId, DocumentId)
         WHERE TenantId = @tenant AND Status = 'READY' AND ExpiresAt <= @now;
        SET @Expired = @@ROWCOUNT;
        UPDATE d SET Status = 'SOFT_DELETED', DeletedAt = @now, DeletedBy = @svc, DeleteReason = N'Data export package expired'
        FROM doc.Document AS d JOIN @done AS x ON d.TenantId = @tenant AND d.DocumentId = x.DocumentId;
        INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, ActorId, Action, Category, Severity, EntityType, EntityId, CorrelationId, Result)
        SELECT @tenant, @now, 'JOB', (SELECT PublicId FROM sec.AppUser WHERE TenantId = @tenant AND AppUserId = @svc),
               'EXPORT_EXPIRED', 'SECURITY', 'INFO', 'cfg.DataExportJob', x.DataExportJobId,
               CAST(SESSION_CONTEXT(N'CorrelationId') AS UNIQUEIDENTIFIER), 'SUCCESS'
        FROM @done AS x;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ExpireDataExports;   -- undo this procedure only
        THROW;
    END CATCH;
    SELECT x.DataExportJobId, v.StorageKey
    FROM @done AS x JOIN doc.DocumentVersion AS v ON v.TenantId = @tenant AND v.DocumentId = x.DocumentId;
END;
GO
GRANT EXECUTE ON cfg.usp_RequestDataExport TO [tp_app];
GRANT EXECUTE ON cfg.usp_ApproveDataExport TO [tp_app];
GRANT EXECUTE ON cfg.usp_StartDataExport TO [tp_jobs];
GRANT EXECUTE ON cfg.usp_FinishDataExport TO [tp_jobs];
GRANT EXECUTE ON cfg.usp_FailDataExport TO [tp_jobs];
GRANT EXECUTE ON cfg.usp_ExpireDataExports TO [tp_jobs];
GO
-- An export changes only through the procedures above, so nobody can approve a restricted export or mark a package
-- ready directly. These run after the generated grants (007), which give tp_app INSERT and UPDATE.
DENY INSERT, UPDATE ON [cfg].[DataExportJob] TO [tp_app];
GO

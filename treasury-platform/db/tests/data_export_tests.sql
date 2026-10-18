/* ============================================================================
   The tenant data export in every status that allows it (db/static/042_data_export.sql; ADR 0008; DQ-F04-8,
   FR-PLT-039, BR-PLT-002, BR-PLT-016). The flows run as the tenant application (tp_app) and the job worker (tp_jobs);
   the checks read, and the set-up changes write, as a test user in tp_auth, which the row filters let past in every
   tenant status.

   Run against a deployed BankFas database (with the platform seed) that holds no real data:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/data_export_tests.sql
   One transaction with a savepoint per case, rolled back at the end. Bindings are written here like the binding
   procedures write them, without read-only keys, so the cases can rebind. Each case prints one line that starts
   with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
BEGIN TRANSACTION;
CREATE USER [tp_test_xapp] WITHOUT LOGIN;
CREATE USER [tp_test_xjob] WITHOUT LOGIN;
CREATE USER [tp_test_xread] WITHOUT LOGIN;
ALTER ROLE [tp_app] ADD MEMBER [tp_test_xapp];
ALTER ROLE [tp_jobs] ADD MEMBER [tp_test_xjob];
ALTER ROLE [tp_auth] ADD MEMBER [tp_test_xread];
ALTER ROLE [db_datareader] ADD MEMBER [tp_test_xread];
ALTER ROLE [db_datawriter] ADD MEMBER [tp_test_xread];   -- sets up states directly, past the row filters, in any status
GO
CREATE PROCEDURE #Bind @TenantId INT, @UserId BIGINT, @Kind VARCHAR(7) = 'USER', @JobKey VARCHAR(80) = NULL
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind)
    VALUES (@@SPID, @TenantId, @UserId, @token, @Kind);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @UserId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
    EXEC sys.sp_set_session_context @key = N'JobKey', @value = @JobKey;
END;
GO

DECLARE @t INT, @ta BIGINT, @rev BIGINT, @plain BIGINT, @svc BIGINT, @rTA BIGINT, @rTM BIGINT, @id BIGINT, @id2 BIGINT,
        @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'), @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA');
DECLARE @pw VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA', @sha VARBINARY(32) = HASHBYTES('SHA2_256', 'package bytes');
DECLARE @e1 INT, @e2 INT, @e3 INT, @e4 INT, @e5 INT, @n INT, @n2 INT, @n3 INT, @n4 INT, @n5 INT, @st VARCHAR(10), @st2 VARCHAR(10),
        @exp DATETIME2(3), @closed DATETIME2(3), @doc BIGINT, @x INT;
DECLARE @keys TABLE (DataExportJobId BIGINT, StorageKey VARCHAR(300));
DECLARE @scope TABLE (DataExportJobId BIGINT, Scope VARCHAR(7), ScopeDetailJson NVARCHAR(MAX), IncludesRestricted BIT, RequestedBy BIGINT);

-- Seed: an active tenant with the account administrator (TA: may export), a reveal holder (TM: may export and
-- reveal), a user without these permissions, the service account, the package document type and a FILE key.
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone) VALUES ('tst-export', N'ص', N'Export', @plan, @country, 'ACTIVE', 'UTC');
SET @t = SCOPE_IDENTITY();
-- Paths in the shared file store start with the tenant's PublicId (DOC-S02); StorageKey is unique on the platform (DR-11).
DECLARE @pre VARCHAR(40) = (SELECT LOWER(CONVERT(VARCHAR(36), PublicId)) FROM plat.Tenant WHERE TenantId = @t);
DECLARE @k1 VARCHAR(300) = @pre + '/exports/1.zip', @k2 VARCHAR(300) = @pre + '/exports/2.zip', @k3 VARCHAR(300) = @pre + '/exports/3.zip',
        @k4 VARCHAR(300) = @pre + '/exports/4.zip', @k5 VARCHAR(300) = @pre + '/exports/5.zip';
EXEC #Bind @t, 0;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash)
VALUES (@t, N'ta@export.invalid', N'TA', 'ACTIVE', @pw), (@t, N'tm@export.invalid', N'TM', 'ACTIVE', @pw),
       (@t, N'plain@export.invalid', N'Plain', 'ACTIVE', @pw);
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, IsSystemUser) VALUES (@t, N'service@export.invalid', N'Service', 'ACTIVE', 1);
SELECT @ta = AppUserId FROM sec.AppUser WHERE TenantId = @t AND Email = N'ta@export.invalid';
SELECT @rev = AppUserId FROM sec.AppUser WHERE TenantId = @t AND Email = N'tm@export.invalid';
SELECT @plain = AppUserId FROM sec.AppUser WHERE TenantId = @t AND Email = N'plain@export.invalid';
SELECT @svc = AppUserId FROM sec.AppUser WHERE TenantId = @t AND IsSystemUser = 1;
INSERT sec.Role (TenantId, Code, NameAr, NameEn, IsSystem, SeedKey)
VALUES (@t, 'TA', N'مدير الحساب', N'Tenant administrator', 1, 'ROLE.TA'), (@t, 'TM', N'مدير الخزينة', N'Treasury manager', 1, 'ROLE.TM');
SELECT @rTA = RoleId FROM sec.Role WHERE TenantId = @t AND Code = 'TA';
SELECT @rTM = RoleId FROM sec.Role WHERE TenantId = @t AND Code = 'TM';
INSERT sec.RolePermission (TenantId, RoleId, PermissionId)
SELECT @t, @rTA, PermissionId FROM sec.Permission WHERE Code = 'cfg.export.request'
UNION ALL SELECT @t, @rTM, PermissionId FROM sec.Permission WHERE Code IN ('cfg.export.request', 'party.identity.reveal');
INSERT sec.UserRole (TenantId, UserId, RoleId) VALUES (@t, @ta, @rTA), (@t, @rev, @rTM);
INSERT cat.DocumentType (TenantId, Code, NameAr, NameEn, AppliesTo, IsSensitive, IsSystem, IsLocked)
VALUES (@t, 'DATA_EXPORT_PACKAGE', N'حزمة تصدير البيانات', N'Data export package', 'GENERAL', 0, 1, 1);   -- not sensitive: 042 marks a restricted package RESTRICTED itself (DR-18)
INSERT sec.TenantKey (TenantId, Purpose, KeyVersion, Status, WrappedKey, MasterKeyRef, ActivatedAt)
VALUES (@t, 'FILE', 1, 'ACTIVE', CRYPT_GEN_RANDOM(64), 'kms/test/file', SYSUTCDATETIME());

/* X1: in an active tenant, a user without cfg.export.request is refused (50034); the account administrator's export
   without restricted data is approved at once and audited with high severity; a second one waits for the first
   (50035); the application cannot insert or change an export directly (229). */
SAVE TRANSACTION x1;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @e4 = NULL, @id = NULL;
EXEC #Bind @t, @plain;
EXECUTE AS USER = N'tp_test_xapp';
BEGIN TRY EXEC cfg.usp_RequestDataExport @TenantId = @t; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #Bind @t, @ta;
EXECUTE AS USER = N'tp_test_xapp';
EXEC cfg.usp_RequestDataExport @TenantId = @t, @DataExportJobId = @id OUTPUT;
BEGIN TRY EXEC cfg.usp_RequestDataExport @TenantId = @t; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT cfg.DataExportJob (TenantId, RequestedBy, Status) VALUES (@t, @ta, 'APPROVED'); END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE cfg.DataExportJob SET Status = 'RUNNING' WHERE DataExportJobId = @id; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @st = Status FROM cfg.DataExportJob WHERE DataExportJobId = @id;
SELECT @n = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'EXPORT_REQUESTED' AND Severity = 'HIGH' AND Category = 'SECURITY'
                                         AND EntityId = @id AND ActorId = (SELECT PublicId FROM sec.AppUser WHERE AppUserId = @ta);
REVERT;
IF @e1 = 50034 AND @st = 'APPROVED' AND @n = 1 AND @e2 = 50035 AND @e3 = 229 AND @e4 = 229
    PRINT 'PASS X1: only a user with cfg.export.request exports, one export at a time, audited, never written directly';
ELSE PRINT CONCAT('FAIL X1: ', @e1, '/', @st, '/', @n, '/', @e2, '/', @e3, '/', @e4);
ROLLBACK TRANSACTION x1;

/* X2: an export with restricted data waits for a holder of party.identity.reveal (BR-PLT-016): the account
   administrator cannot approve it (50034), the treasury manager can, once (50036 after); a reveal holder's own
   request is approved at once. */
SAVE TRANSACTION x2;
SELECT @e1 = NULL, @e2 = NULL, @id = NULL, @id2 = NULL, @st = NULL, @st2 = NULL;
EXEC #Bind @t, @ta;
EXECUTE AS USER = N'tp_test_xapp';
EXEC cfg.usp_RequestDataExport @TenantId = @t, @IncludesRestricted = 1, @DataExportJobId = @id OUTPUT;
BEGIN TRY EXEC cfg.usp_ApproveDataExport @TenantId = @t, @DataExportJobId = @id; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @st = Status FROM cfg.DataExportJob WHERE DataExportJobId = @id;
REVERT;
EXEC #Bind @t, @rev;
EXECUTE AS USER = N'tp_test_xapp';
EXEC cfg.usp_ApproveDataExport @TenantId = @t, @DataExportJobId = @id;
BEGIN TRY EXEC cfg.usp_ApproveDataExport @TenantId = @t, @DataExportJobId = @id; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @n = COUNT(*) FROM cfg.DataExportJob WHERE DataExportJobId = @id AND Status = 'APPROVED' AND ApprovedBy = @rev;
SELECT @n2 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'EXPORT_APPROVED' AND Category = 'IDENTITY_ACCESS' AND EntityId = @id;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
UPDATE cfg.DataExportJob SET Status = 'EXPIRED', ExpiresAt = ISNULL(ExpiresAt, SYSUTCDATETIME()) WHERE DataExportJobId = @id;      -- out of the way for the next request
REVERT;
EXECUTE AS USER = N'tp_test_xapp';
EXEC cfg.usp_RequestDataExport @TenantId = @t, @IncludesRestricted = 1, @DataExportJobId = @id2 OUTPUT;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @n3 = COUNT(*) FROM cfg.DataExportJob WHERE DataExportJobId = @id2 AND Status = 'APPROVED' AND ApprovedBy = @rev;
REVERT;
IF @st = 'REQUESTED' AND @e1 = 50034 AND @n = 1 AND @n2 = 1 AND @e2 = 50036 AND @n3 = 1
    PRINT 'PASS X2: restricted data needs a reveal holder''s approval, given once, and a reveal holder''s own request needs none';
ELSE PRINT CONCAT('FAIL X2: ', @st, '/', @e1, '/', @n, '/', @n2, '/', @e2, '/', @n3);
ROLLBACK TRANSACTION x2;

/* X3: in a SUSPENDED tenant (no direct write at all), the account administrator still requests an export, another
   user cannot (50034), and the export job builds it: RUNNING, then READY with the package document, expiring in 7
   days, audited with the package's SHA-256. Another job may not touch exports (50034). */
SAVE TRANSACTION x3;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @id = NULL, @id2 = NULL, @st = NULL;
UPDATE plat.Tenant SET Status = 'SUSPENDED', SuspendedAt = SYSUTCDATETIME(), SuspendedReason = N'Test' WHERE TenantId = @t;
EXEC #Bind @t, @ta;
EXECUTE AS USER = N'tp_test_xapp';
BEGIN TRY INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@t, 'security.session.idle_minutes', N'10'); END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC cfg.usp_RequestDataExport @TenantId = @t, @DataExportJobId = @id OUTPUT;
REVERT;
EXEC #Bind @t, @rev;
EXECUTE AS USER = N'tp_test_xapp';
BEGIN TRY EXEC cfg.usp_RequestDataExport @TenantId = @t; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #Bind @t, @svc, 'JOB', 'JOB-WFL-SLA';
EXECUTE AS USER = N'tp_test_xjob';
BEGIN TRY EXEC cfg.usp_StartDataExport; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #Bind @t, @svc, 'JOB', 'JOB-PLT-EXPORT';
EXECUTE AS USER = N'tp_test_xjob';
INSERT @scope EXEC cfg.usp_StartDataExport @DataExportJobId = @id2 OUTPUT;
EXEC cfg.usp_FinishDataExport @DataExportJobId = @id2, @StorageKey = @k1, @FileName = N'export-1.zip',
     @SizeBytes = 1234, @Sha256 = @sha;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @st = Status, @exp = ExpiresAt, @doc = PackageDocumentId FROM cfg.DataExportJob WHERE DataExportJobId = @id;
SELECT @n = COUNT(*) FROM doc.Document AS d JOIN doc.DocumentVersion AS v ON v.TenantId = d.TenantId AND v.DocumentId = d.DocumentId
 WHERE d.DocumentId = @doc AND d.CurrentVersionId = v.DocumentVersionId AND d.Sensitivity = 'CONFIDENTIAL' AND v.Sha256 = @sha AND v.ScanStatus = 'CLEAN';
SELECT @n2 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'EXPORT_READY' AND Severity = 'HIGH' AND ActorType = 'JOB'
                                          AND JSON_VALUE(AfterJson, '$.sha256') = CONVERT(VARCHAR(64), @sha, 2);
SELECT @n3 = COUNT(*) FROM @scope WHERE DataExportJobId = @id AND Scope = 'FULL';
REVERT;
IF @e1 = 33504 AND @e2 = 50034 AND @e3 = 50034 AND @id2 = @id AND @n3 = 1 AND @st = 'READY' AND @n = 1 AND @n2 = 1
   AND DATEDIFF(HOUR, SYSUTCDATETIME(), @exp) BETWEEN 167 AND 168
    PRINT 'PASS X3: a suspended tenant''s administrator exports through the procedures, and the export job builds the package';
ELSE PRINT CONCAT('FAIL X3: ', @e1, '/', @e2, '/', @e3, '/', @id, '/', @id2, '/', @n3, '/', @st, '/', @n, '/', @n2, '/', @exp);
ROLLBACK TRANSACTION x3;

/* X4: in a CLOSED tenant the export window is 30 days from ClosedAt (BR-PLT-002): a package made 25 days in expires
   when the window ends, not after 7 days; a failure is recorded with its reason; after the window neither the
   administrator nor the job can act (50034). */
SAVE TRANSACTION x4;
SELECT @e1 = NULL, @e2 = NULL, @id = NULL, @id2 = NULL, @st = NULL;
SET @closed = DATEADD(DAY, -25, SYSUTCDATETIME());
UPDATE plat.Tenant SET Status = 'CLOSED', ClosedAt = @closed WHERE TenantId = @t;
EXEC #Bind @t, @ta;
EXECUTE AS USER = N'tp_test_xapp';
EXEC cfg.usp_RequestDataExport @TenantId = @t, @DataExportJobId = @id OUTPUT;
REVERT;
EXEC #Bind @t, @svc, 'JOB', 'JOB-PLT-EXPORT';
EXECUTE AS USER = N'tp_test_xjob';
INSERT @scope EXEC cfg.usp_StartDataExport;
EXEC cfg.usp_FinishDataExport @DataExportJobId = @id, @StorageKey = @k2, @FileName = N'export-2.zip',
     @SizeBytes = 99, @Sha256 = @sha;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @exp = ExpiresAt FROM cfg.DataExportJob WHERE DataExportJobId = @id;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
UPDATE cfg.DataExportJob SET Status = 'EXPIRED', ExpiresAt = ISNULL(ExpiresAt, SYSUTCDATETIME()) WHERE DataExportJobId = @id;
REVERT;
EXEC #Bind @t, @ta;
EXECUTE AS USER = N'tp_test_xapp';
EXEC cfg.usp_RequestDataExport @TenantId = @t, @DataExportJobId = @id2 OUTPUT;
REVERT;
EXEC #Bind @t, @svc, 'JOB', 'JOB-PLT-EXPORT';
EXECUTE AS USER = N'tp_test_xjob';
INSERT @scope EXEC cfg.usp_StartDataExport;
EXEC cfg.usp_FailDataExport @DataExportJobId = @id2, @Reason = N'Storage unavailable';
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @st = Status FROM cfg.DataExportJob WHERE DataExportJobId = @id2 AND FailureReason = N'Storage unavailable';
SELECT @n = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'EXPORT_FAILED' AND Result = 'FAILED' AND EntityId = @id2;
REVERT;
UPDATE plat.Tenant SET ClosedAt = DATEADD(DAY, -31, SYSUTCDATETIME()) WHERE TenantId = @t;
EXEC #Bind @t, @ta;
EXECUTE AS USER = N'tp_test_xapp';
BEGIN TRY EXEC cfg.usp_RequestDataExport @TenantId = @t; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #Bind @t, @svc, 'JOB', 'JOB-PLT-EXPORT';
EXECUTE AS USER = N'tp_test_xjob';
BEGIN TRY EXEC cfg.usp_StartDataExport; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @exp = DATEADD(DAY, 30, @closed) AND @st = 'FAILED' AND @n = 1 AND @e1 = 50034 AND @e2 = 50034
    PRINT 'PASS X4: a closed tenant exports until the 30-day window ends, and its package expires with the window';
ELSE PRINT CONCAT('FAIL X4: ', @exp, ' vs ', DATEADD(DAY, 30, @closed), '/', @st, '/', @n, '/', @e1, '/', @e2);
ROLLBACK TRANSACTION x4;

/* X5: a package with restricted data is RESTRICTED and leaves a DATA_EXPORT row in the sensitive access log, linked to
   its audit row (BR-PTY-009); without the package document type the job stops (50037) and the export stays RUNNING. */
SAVE TRANSACTION x5;
SELECT @e1 = NULL, @id = NULL, @id2 = NULL, @st = NULL;
EXEC #Bind @t, @rev;
EXECUTE AS USER = N'tp_test_xapp';
EXEC cfg.usp_RequestDataExport @TenantId = @t, @IncludesRestricted = 1, @DataExportJobId = @id OUTPUT;
REVERT;
EXEC #Bind @t, @svc, 'JOB', 'JOB-PLT-EXPORT';
EXECUTE AS USER = N'tp_test_xjob';
INSERT @scope EXEC cfg.usp_StartDataExport;
EXEC cfg.usp_FinishDataExport @DataExportJobId = @id, @StorageKey = @k3, @FileName = N'export-3.zip',
     @SizeBytes = 5000, @Sha256 = @sha;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @n = COUNT(*) FROM aud.SensitiveAccessLog AS s JOIN aud.AuditLog AS a ON a.AuditLogId = s.AuditLogId
 WHERE s.TenantId = @t AND s.AccessKind = 'DATA_EXPORT' AND s.ActorUserId = @rev AND s.SubjectEntityId = @id AND s.Result = 'GRANTED'
   AND a.Action = 'EXPORT_READY' AND a.Category = 'IDENTITY_ACCESS';
SELECT @n2 = COUNT(*) FROM doc.Document WHERE DocumentId = (SELECT PackageDocumentId FROM cfg.DataExportJob WHERE DataExportJobId = @id)
                                          AND Sensitivity = 'RESTRICTED';
REVERT;
EXECUTE AS USER = N'tp_test_xread';
UPDATE cfg.DataExportJob SET Status = 'EXPIRED', ExpiresAt = ISNULL(ExpiresAt, SYSUTCDATETIME()) WHERE DataExportJobId = @id;
UPDATE cat.DocumentType SET IsActive = 0, IsLocked = 0 WHERE TenantId = @t AND Code = 'DATA_EXPORT_PACKAGE';
REVERT;
EXEC #Bind @t, @ta;
EXECUTE AS USER = N'tp_test_xapp';
EXEC cfg.usp_RequestDataExport @TenantId = @t, @DataExportJobId = @id2 OUTPUT;
REVERT;
EXEC #Bind @t, @svc, 'JOB', 'JOB-PLT-EXPORT';
EXECUTE AS USER = N'tp_test_xjob';
INSERT @scope EXEC cfg.usp_StartDataExport;
BEGIN TRY EXEC cfg.usp_FinishDataExport @DataExportJobId = @id2, @StorageKey = @k4, @FileName = N'export-4.zip',
               @SizeBytes = 5000, @Sha256 = @sha; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @st = Status FROM cfg.DataExportJob WHERE DataExportJobId = @id2;
REVERT;
IF @n = 1 AND @n2 = 1 AND @e1 = 50037 AND @st = 'RUNNING'
    PRINT 'PASS X5: a restricted package is logged as sensitive access, and a tenant without the package type stops the job';
ELSE PRINT CONCAT('FAIL X5: ', @n, '/', @n2, '/', @e1, '/', @st);
ROLLBACK TRANSACTION x5;

/* X6: JOB-PLT-EXPORT-EXPIRE turns READY packages past their date into EXPIRED, soft-deletes the document and returns
   the storage key to delete, once; the export job cannot run it (50034). */
SAVE TRANSACTION x6;
SELECT @e1 = NULL, @id = NULL, @st = NULL, @n = NULL, @n2 = NULL;
DELETE FROM @keys;
EXEC #Bind @t, @ta;
EXECUTE AS USER = N'tp_test_xapp';
EXEC cfg.usp_RequestDataExport @TenantId = @t, @DataExportJobId = @id OUTPUT;
REVERT;
EXEC #Bind @t, @svc, 'JOB', 'JOB-PLT-EXPORT';
EXECUTE AS USER = N'tp_test_xjob';
INSERT @scope EXEC cfg.usp_StartDataExport;
EXEC cfg.usp_FinishDataExport @DataExportJobId = @id, @StorageKey = @k5, @FileName = N'export-5.zip',
     @SizeBytes = 10, @Sha256 = @sha;
BEGIN TRY EXEC cfg.usp_ExpireDataExports; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
UPDATE cfg.DataExportJob SET ExpiresAt = DATEADD(MINUTE, -1, SYSUTCDATETIME()) WHERE DataExportJobId = @id;
REVERT;
EXEC #Bind @t, @svc, 'JOB', 'JOB-PLT-EXPORT-EXPIRE';
EXECUTE AS USER = N'tp_test_xjob';
INSERT @keys EXEC cfg.usp_ExpireDataExports @Expired = @n OUTPUT;
INSERT @keys EXEC cfg.usp_ExpireDataExports @Expired = @n2 OUTPUT;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @st = Status, @doc = PackageDocumentId FROM cfg.DataExportJob WHERE DataExportJobId = @id;
SELECT @n3 = COUNT(*) FROM doc.Document WHERE DocumentId = @doc AND Status = 'SOFT_DELETED' AND DeletedBy = @svc;
SELECT @n4 = COUNT(*) FROM aud.AuditLog WHERE TenantId = @t AND Action = 'EXPORT_EXPIRED' AND EntityId = @id;
SELECT @n5 = COUNT(*) FROM @keys WHERE DataExportJobId = @id AND StorageKey = @k5;
REVERT;
IF @e1 = 50034 AND @n = 1 AND @n2 = 0 AND @st = 'EXPIRED' AND @n3 = 1 AND @n4 = 1 AND @n5 = 1
    PRINT 'PASS X6: the expiry job expires ready packages once, soft-deletes them and hands back the files to delete';
ELSE PRINT CONCAT('FAIL X6: ', @e1, '/', @n, '/', @n2, '/', @st, '/', @n3, '/', @n4, '/', @n5);
ROLLBACK TRANSACTION x6;

/* X7 (self-review A10): a tenant that marked the package type sensitive still gets its package: an export without
   restricted data is RESTRICTED like its type, as 043 requires of a document of a sensitive type (50045 otherwise). */
SAVE TRANSACTION x7;
SELECT @e1 = NULL, @id = NULL, @st = NULL, @n = NULL, @x = NULL, @doc = NULL;
DECLARE @k6 VARCHAR(300) = @pre + '/exports/6.zip';
EXECUTE AS USER = N'tp_test_xread';
UPDATE cat.DocumentType SET IsSensitive = 1 WHERE TenantId = @t AND Code = 'DATA_EXPORT_PACKAGE';
REVERT;
EXEC #Bind @t, @ta;
EXECUTE AS USER = N'tp_test_xapp';
EXEC cfg.usp_RequestDataExport @TenantId = @t, @DataExportJobId = @id OUTPUT;
REVERT;
EXEC #Bind @t, @svc, 'JOB', 'JOB-PLT-EXPORT';
EXECUTE AS USER = N'tp_test_xjob';
INSERT @scope EXEC cfg.usp_StartDataExport;
BEGIN TRY EXEC cfg.usp_FinishDataExport @DataExportJobId = @id, @StorageKey = @k6, @FileName = N'export-6.zip',
               @SizeBytes = 10, @Sha256 = @sha; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
REVERT;
EXECUTE AS USER = N'tp_test_xread';
SELECT @st = Status, @doc = PackageDocumentId, @x = CAST(IncludesRestricted AS INT) FROM cfg.DataExportJob WHERE DataExportJobId = @id;
SELECT @n = COUNT(*) FROM doc.Document WHERE DocumentId = @doc AND Sensitivity = 'RESTRICTED';
REVERT;
IF @e1 IS NULL AND @st = 'READY' AND @x = 0 AND @n = 1
    PRINT 'PASS X7: a package of a type the tenant marked sensitive is RESTRICTED, even without restricted data';
ELSE PRINT CONCAT('FAIL X7: ', @e1, '/', @st, '/', @x, '/', @n);
ROLLBACK TRANSACTION x7;

ROLLBACK TRANSACTION;
GO
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'UserId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'JobKey', @value = NULL;
PRINT 'Data export tests finished; every change is rolled back.';
GO

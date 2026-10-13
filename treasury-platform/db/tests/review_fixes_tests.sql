/* ============================================================================
   Fixes of the design-review findings approved by the owner on 2026-10-13 (O-15, docs/32-review-findings-decisions.md,
   docs/adr/0011-design-review-fixes.md).
   RF1  a list column (set{}) takes only distinct allowed values, in capitals, with no empty item or space (DR-32)
   RF2  a document version's content does not change, its scan state does, and a storage path is unique on the
        platform (DR-11)
   RF3  a sensitive-access row points at an audit event of its own tenant (DR-12)
   RF4  an export job carries its approval and expiry evidence (DR-13)
   RF5  an outbox event carries the evidence of its status, and only a delivered one may be deleted (DR-14)
   RF6  a support grant lasts 1 to 72 hours, the application may only revoke it, and a revocation is final (DR-15)
   RF7  a locked permission goes only to the system roles it names, and a role's code stays (DR-16)
   RF8  a tenant setting has a definition and a value of its type, and the working day is 4 to 12 hours (DR-17,
        AC-PLT-19)
   RF9  a document of a sensitive type is RESTRICTED, never PUBLIC, and its current version is its own (DR-18)
   RF10 codes are checked in capitals: a lower-case country or catalogue code is refused (DR-48)
   RF11 a signatory's revocation has its date and reason, an expiry its end date, and both are final (DR-19)
   RF12 an authority grant in force has its approver and time, and supersedes only a grant of its own company (DR-21)
   RF13 an identity document is superseded only by a document of the same party (DR-23)
   RF14 a company's mirror party is an organisation (DR-24)
   RF15 a base rate has a currency, and an alias stays in its rate's scope (DR-29)
   RF16 the normalised ERP code is computed from the code, unique while set, and freed when cleared (DR-47)

   Run against a deployed BankFas database that holds no real data, with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/review_fixes_tests.sql
   Every case runs in its own transaction and rolls it back: an error raised in a trigger ends the transaction.
   The fixture (#Fixture) makes two active tenants; bindings are written like the binding procedures write them,
   without read-only keys. Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
IF USER_ID(N'tp_test_rfapp') IS NULL
BEGIN
    CREATE USER [tp_test_rfapp] WITHOUT LOGIN;
    ALTER ROLE [tp_app] ADD MEMBER [tp_test_rfapp];
END;
GO
CREATE TABLE #F (k VARCHAR(20) PRIMARY KEY, v BIGINT NOT NULL);
GO
CREATE PROCEDURE #Bind @TenantId INT, @UserId BIGINT
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind)
    VALUES (@@SPID, @TenantId, @UserId, @token, 'USER');
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @UserId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
END;
GO
-- Two active tenants, each with its administrator, the system roles TA and TM, a custom role, a sensitive and a
-- plain document type and a FILE key. Runs inside the caller's transaction; #F holds the ids.
CREATE PROCEDURE #Fixture
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM #F;
    DECLARE @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'),
            @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA'),
            @pw VARCHAR(255) = '$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA', @i INT = 1, @t INT, @u BIGINT;
    WHILE @i <= 2
    BEGIN
        INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone)
        VALUES (CONCAT('tst-rf', @i), N'ر', CONCAT(N'RF ', @i), @plan, @country, 'ACTIVE', 'UTC');
        SET @t = SCOPE_IDENTITY();
        EXEC #Bind @t, 0;
        INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash)
        VALUES (@t, CONCAT(N'ta@rf', @i, N'.invalid'), N'TA', 'ACTIVE', @pw);
        SET @u = SCOPE_IDENTITY();
        INSERT sec.Role (TenantId, Code, NameAr, NameEn, IsSystem, SeedKey)
        VALUES (@t, 'TA', N'مدير الحساب', N'Tenant administrator', 1, 'ROLE.TA'),
               (@t, 'TM', N'مدير الخزينة', N'Treasury manager', 1, 'ROLE.TM'),
               (@t, 'CUSTOM', N'دور مخصص', N'Custom role', 0, NULL);
        INSERT cat.DocumentType (TenantId, Code, NameAr, NameEn, AppliesTo, IsSensitive)
        VALUES (@t, 'ID_CARD', N'بطاقة هوية', N'Identity card', 'PARTY', 1), (@t, 'CONTRACT', N'عقد', N'Contract', 'GENERAL', 0);
        INSERT sec.TenantKey (TenantId, Purpose, KeyVersion, Status, WrappedKey, MasterKeyRef, ActivatedAt)
        VALUES (@t, 'FILE', 1, 'ACTIVE', CRYPT_GEN_RANDOM(64), 'kms/test/file', SYSUTCDATETIME());
        INSERT #F (k, v)
        SELECT CONCAT('t', @i), @t UNION ALL SELECT CONCAT('u', @i), @u
        UNION ALL SELECT CONCAT('key', @i), TenantKeyId FROM sec.TenantKey WHERE TenantId = @t AND Purpose = 'FILE'
        UNION ALL SELECT CONCAT('sens', @i), DocumentTypeId FROM cat.DocumentType WHERE TenantId = @t AND Code = 'ID_CARD'
        UNION ALL SELECT CONCAT('plain', @i), DocumentTypeId FROM cat.DocumentType WHERE TenantId = @t AND Code = 'CONTRACT'
        UNION ALL SELECT CONCAT('rTA', @i), RoleId FROM sec.Role WHERE TenantId = @t AND Code = 'TA'
        UNION ALL SELECT CONCAT('rTM', @i), RoleId FROM sec.Role WHERE TenantId = @t AND Code = 'TM'
        UNION ALL SELECT CONCAT('rCU', @i), RoleId FROM sec.Role WHERE TenantId = @t AND Code = 'CUSTOM';
        SET @i += 1;
    END;
END;
GO
/* RF1: ref.Country.WeekendDays and cfg.JobDefinition.RunsInStatuses (global lists, written here as dbo) */
DECLARE @bad TABLE (v VARCHAR(40));
INSERT @bad VALUES ('XYZ'), ('FRI,FRI'), ('fri,sat'), (''), ('FRI, SAT'), ('FRI,SAT,'), (',FRI');
DECLARE @v VARCHAR(40), @refused INT = 0, @tried INT = 0, @good INT = 0, @job INT = 0;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT v FROM @bad;
OPEN c; FETCH NEXT FROM c INTO @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @tried += 1;
    BEGIN TRANSACTION;
    BEGIN TRY UPDATE ref.Country SET WeekendDays = @v WHERE Iso2 = 'SA'; END TRY
    BEGIN CATCH IF ERROR_NUMBER() = 547 SET @refused += 1; END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    FETCH NEXT FROM c INTO @v;
END;
CLOSE c; DEALLOCATE c;
BEGIN TRANSACTION;
BEGIN TRY UPDATE ref.Country SET WeekendDays = 'SAT,FRI' WHERE Iso2 = 'SA'; SET @good = @@ROWCOUNT; END TRY BEGIN CATCH SET @good = -1; END CATCH;
BEGIN TRY UPDATE cfg.JobDefinition SET RunsInStatuses = 'TRIAL,ACTIVE,TRIAL' WHERE JobKey = 'JOB-PLT-ONBOARD'; END TRY
BEGIN CATCH SET @job = ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @refused = @tried AND @good = 1 AND @job = 547
    PRINT CONCAT('PASS RF1: a list column refuses ', @tried, ' malformed values (unknown, repeated, lower case, empty, spaced) and takes distinct allowed ones in any order');
ELSE PRINT CONCAT('FAIL RF1: refused ', @refused, ' of ', @tried, ', valid list ', @good, ', repeated job status ', @job);
GO
/* RF2 (DR-11): as the tenant application, a version's hash and path are refused (230) and its scan state is
   accepted; the same path for another tenant's version is refused (2627). */
DECLARE @t1 INT, @t2 INT, @u1 BIGINT, @k1 BIGINT, @k2 BIGINT, @p1 BIGINT, @p2 BIGINT, @doc BIGINT, @ver BIGINT,
        @e1 INT, @e2 INT, @e3 INT, @ok INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @t2 = v FROM #F WHERE k = 't2'; SELECT @u1 = v FROM #F WHERE k = 'u1';
SELECT @k1 = v FROM #F WHERE k = 'key1'; SELECT @k2 = v FROM #F WHERE k = 'key2';
SELECT @p1 = v FROM #F WHERE k = 'plain1'; SELECT @p2 = v FROM #F WHERE k = 'plain2';
EXEC #Bind @t1, @u1;
INSERT doc.Document (TenantId, DocumentTypeId, Title, Sensitivity, CreatedBy) VALUES (@t1, @p1, N'Contract', 'CONFIDENTIAL', @u1);
SET @doc = SCOPE_IDENTITY();
INSERT doc.DocumentVersion (TenantId, DocumentId, VersionNo, StorageKey, FileName, ContentType, SizeBytes, Sha256, KeyId)
VALUES (@t1, @doc, 1, 'rf/shared/contract.pdf', N'contract.pdf', 'application/pdf', 10, HASHBYTES('SHA2_256', 'v1'), @k1);
SET @ver = SCOPE_IDENTITY();
EXECUTE AS USER = N'tp_test_rfapp';
BEGIN TRY UPDATE doc.DocumentVersion SET Sha256 = HASHBYTES('SHA2_256', 'v2') WHERE DocumentVersionId = @ver; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE doc.DocumentVersion SET StorageKey = 'rf/other.pdf' WHERE DocumentVersionId = @ver; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE doc.DocumentVersion SET ScanStatus = 'CLEAN', ScannedAt = SYSUTCDATETIME() WHERE DocumentVersionId = @ver; SET @ok = @@ROWCOUNT; END TRY
BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
REVERT;
EXEC #Bind @t2, 0;
INSERT doc.Document (TenantId, DocumentTypeId, Title, Sensitivity) VALUES (@t2, @p2, N'Contract', 'CONFIDENTIAL');
SET @doc = SCOPE_IDENTITY();
BEGIN TRY
    INSERT doc.DocumentVersion (TenantId, DocumentId, VersionNo, StorageKey, FileName, ContentType, SizeBytes, Sha256, KeyId)
    VALUES (@t2, @doc, 1, 'rf/shared/contract.pdf', N'contract.pdf', 'application/pdf', 10, HASHBYTES('SHA2_256', 'v1'), @k2);
END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 230 AND @e2 = 230 AND @ok = 1 AND @e3 = 2627
    PRINT 'PASS RF2: a version''s hash and path do not change, its scan state does, and a storage path is unique on the platform';
ELSE PRINT CONCAT('FAIL RF2: hash ', @e1, ', path ', @e2, ', scan ', @ok, ', same path in another tenant ', @e3);
GO
/* RF3 (DR-12): a sensitive-access row without an audit event (515) or with another tenant's event (547) is refused;
   with its own tenant's event it is accepted. */
DECLARE @t1 INT, @t2 INT, @u1 BIGINT, @a1 BIGINT, @a2 BIGINT, @e1 INT, @e2 INT, @ok INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @t2 = v FROM #F WHERE k = 't2'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t2, 0;
EXEC aud.usp_WriteEvent @TenantId = @t2, @Action = 'IDENTITY_REVEAL', @Category = 'IDENTITY_ACCESS', @ActorType = 'SYSTEM', @AuditLogId = @a2 OUTPUT;
EXEC #Bind @t1, @u1;
EXEC aud.usp_WriteEvent @TenantId = @t1, @Action = 'IDENTITY_REVEAL', @Category = 'IDENTITY_ACCESS', @ActorType = 'USER', @ActorUserId = @u1, @AuditLogId = @a1 OUTPUT;
BEGIN TRY
    INSERT aud.SensitiveAccessLog (TenantId, OccurredAt, AccessKind, ActorType, ActorUserId, SubjectEntityType, SubjectEntityId, Result)
    VALUES (@t1, SYSUTCDATETIME(), 'IDENTITY_REVEAL', 'USER', @u1, 'IdentityDocument', 1, 'GRANTED');
END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY
    INSERT aud.SensitiveAccessLog (TenantId, OccurredAt, AccessKind, ActorType, ActorUserId, SubjectEntityType, SubjectEntityId, Result, AuditLogId)
    VALUES (@t1, SYSUTCDATETIME(), 'IDENTITY_REVEAL', 'USER', @u1, 'IdentityDocument', 1, 'GRANTED', @a2);
END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY
    INSERT aud.SensitiveAccessLog (TenantId, OccurredAt, AccessKind, ActorType, ActorUserId, SubjectEntityType, SubjectEntityId, Result, AuditLogId)
    VALUES (@t1, SYSUTCDATETIME(), 'IDENTITY_REVEAL', 'USER', @u1, 'IdentityDocument', 1, 'GRANTED', @a1);
    SET @ok = @@ROWCOUNT;
END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 515 AND @e2 = 547 AND @ok = 1
    PRINT 'PASS RF3: a sensitive-access row needs an audit event of its own tenant';
ELSE PRINT CONCAT('FAIL RF3: no event ', @e1, ', other tenant''s event ', @e2, ', own event ', @ok);
GO
/* RF4 (DR-13): a restricted export that failed without approval, an approver without a time, and a READY package
   without an expiry are refused (547); the database's own procedures never write them. */
DECLARE @t1 INT, @u1 BIGINT, @e1 INT, @e2 INT, @e3 INT, @ok INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
BEGIN TRY INSERT cfg.DataExportJob (TenantId, RequestedBy, IncludesRestricted, Status) VALUES (@t1, @u1, 1, 'FAILED'); END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT cfg.DataExportJob (TenantId, RequestedBy, IncludesRestricted, Status, ApprovedBy) VALUES (@t1, @u1, 0, 'APPROVED', @u1); END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY
    INSERT cfg.DataExportJob (TenantId, RequestedBy, IncludesRestricted, Status, StartedAt, FinishedAt, PackageDocumentId, PackageSha256)
    VALUES (@t1, @u1, 0, 'EXPIRED', SYSUTCDATETIME(), SYSUTCDATETIME(), NULL, NULL);
END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY
    INSERT cfg.DataExportJob (TenantId, RequestedBy, IncludesRestricted, Status, ApprovedBy, ApprovedAt) VALUES (@t1, @u1, 1, 'APPROVED', @u1, SYSUTCDATETIME());
    SET @ok = @@ROWCOUNT;
END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 547 AND @e3 = 547 AND @ok = 1
    PRINT 'PASS RF4: an export job carries its approval for restricted data, the approval time, and the expiry of its package';
ELSE PRINT CONCAT('FAIL RF4: unapproved restricted ', @e1, ', approver without time ', @e2, ', expired without expiry ', @e3, ', approved ', @ok);
GO
/* RF5 (DR-14): PROCESSING without a lock, DELIVERED without a time and DEAD without an error are refused (547); the
   application deletes a delivered event, and deleting a dead one is refused (50041). */
DECLARE @t1 INT, @u1 BIGINT, @e1 INT, @e2 INT, @e3 INT, @e4 INT, @del INT, @left INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
BEGIN TRY INSERT cfg.OutboxEvent (TenantId, EventName, PayloadJson, Status) VALUES (@t1, 'rf.test', N'{}', 'PROCESSING'); END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT cfg.OutboxEvent (TenantId, EventName, PayloadJson, Status) VALUES (@t1, 'rf.test', N'{}', 'DELIVERED'); END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT cfg.OutboxEvent (TenantId, EventName, PayloadJson, Status) VALUES (@t1, 'rf.test', N'{}', 'DEAD'); END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
INSERT cfg.OutboxEvent (TenantId, EventName, PayloadJson, Status, DeliveredAt) VALUES (@t1, 'rf.delivered', N'{}', 'DELIVERED', SYSUTCDATETIME());
INSERT cfg.OutboxEvent (TenantId, EventName, PayloadJson, Status, LastError, AttemptCount) VALUES (@t1, 'rf.dead', N'{}', 'DEAD', N'gave up', 8);
EXECUTE AS USER = N'tp_test_rfapp';
DELETE FROM cfg.OutboxEvent WHERE TenantId = @t1 AND EventName = 'rf.delivered';
SET @del = @@ROWCOUNT;
REVERT;
SELECT @left = COUNT(*) FROM cfg.OutboxEvent WHERE TenantId = @t1 AND EventName IN ('rf.delivered', 'rf.dead');
EXECUTE AS USER = N'tp_test_rfapp';
BEGIN TRY DELETE FROM cfg.OutboxEvent WHERE TenantId = @t1 AND EventName = 'rf.dead'; END TRY
BEGIN CATCH SET @e4 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 547 AND @e3 = 547 AND @del = 1 AND @left = 1 AND @e4 = 50041
    PRINT 'PASS RF5: an outbox event carries the evidence of its status, and only a delivered one is deleted';
ELSE PRINT CONCAT('FAIL RF5: processing ', @e1, ', delivered ', @e2, ', dead ', @e3, ', delete delivered ', @del, '/', @left, ', delete dead ', @e4);
GO
/* RF6 (DR-15): grants of 73 hours and of 30 minutes (547) and a revocation without its author (547) are refused; the
   application cannot extend a grant (230) but revokes it, and cannot then reinstate it (50042). */
DECLARE @t1 INT, @u1 BIGINT, @op INT, @g BIGINT, @now DATETIME2(3) = SYSUTCDATETIME(), @e1 INT, @e2 INT, @e3 INT, @e4 INT, @e5 INT, @rev INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
INSERT plat.PlatformOperator (Email, DisplayName, Role, Status) VALUES (N'op@rf.invalid', N'Operator', 'OPERATOR_SUPPORT', 'INVITED');
SET @op = SCOPE_IDENTITY();
EXEC #Bind @t1, @u1;
BEGIN TRY INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason) VALUES (@t1, @op, @u1, @now, DATEADD(HOUR, 73, @now), N'too long'); END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason) VALUES (@t1, @op, @u1, @now, DATEADD(MINUTE, 30, @now), N'too short'); END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason, RevokedAt) VALUES (@t1, @op, @u1, @now, DATEADD(HOUR, 4, @now), N'no author', @now); END TRY
BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason) VALUES (@t1, @op, @u1, @now, DATEADD(HOUR, 72, @now), N'three days');
SET @g = SCOPE_IDENTITY();
EXECUTE AS USER = N'tp_test_rfapp';
BEGIN TRY UPDATE plat.SupportAccessGrant SET EndsAt = DATEADD(HOUR, 1, EndsAt) WHERE SupportAccessGrantId = @g; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
UPDATE plat.SupportAccessGrant SET RevokedAt = SYSUTCDATETIME(), RevokedBy = @u1 WHERE SupportAccessGrantId = @g;
SET @rev = @@ROWCOUNT;
BEGIN TRY UPDATE plat.SupportAccessGrant SET RevokedAt = NULL, RevokedBy = NULL WHERE SupportAccessGrantId = @g; END TRY
BEGIN CATCH SET @e5 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 547 AND @e3 = 547 AND @e4 = 230 AND @rev = 1 AND @e5 = 50042
    PRINT 'PASS RF6: a support grant lasts 1 to 72 hours, the application only revokes it, and a revocation is final';
ELSE PRINT CONCAT('FAIL RF6: 73 h ', @e1, ', 30 min ', @e2, ', no author ', @e3, ', extend ', @e4, ', revoke ', @rev, ', reinstate ', @e5);
GO
/* RF7 (DR-16): as the tenant application, party.identity.reveal (locked to TM and FO) is refused for a custom role
   and for the system role TA (50043) and accepted for TM; a role's code does not change (230). */
DECLARE @t1 INT, @u1 BIGINT, @rTA BIGINT, @rTM BIGINT, @rCU BIGINT, @p INT = (SELECT PermissionId FROM sec.Permission WHERE Code = 'party.identity.reveal'),
        @e1 INT, @e2 INT, @e3 INT, @ok INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
SELECT @rTA = v FROM #F WHERE k = 'rTA1'; SELECT @rTM = v FROM #F WHERE k = 'rTM1'; SELECT @rCU = v FROM #F WHERE k = 'rCU1';
EXEC #Bind @t1, @u1;
EXECUTE AS USER = N'tp_test_rfapp';
INSERT sec.RolePermission (TenantId, RoleId, PermissionId, AssignedBy) VALUES (@t1, @rTM, @p, @u1);
SET @ok = @@ROWCOUNT;
BEGIN TRY UPDATE sec.Role SET Code = 'TM2' WHERE RoleId = @rTM; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT sec.RolePermission (TenantId, RoleId, PermissionId, AssignedBy) VALUES (@t1, @rCU, @p, @u1); END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @rTA = v FROM #F WHERE k = 'rTA1';
EXEC #Bind @t1, @u1;
EXECUTE AS USER = N'tp_test_rfapp';
BEGIN TRY INSERT sec.RolePermission (TenantId, RoleId, PermissionId, AssignedBy) VALUES (@t1, @rTA, @p, @u1); END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @ok = 1 AND @e1 = 50043 AND @e2 = 50043 AND @e3 = 230
    PRINT 'PASS RF7: a locked permission goes only to the system roles it names, and a role''s code stays';
ELSE PRINT CONCAT('FAIL RF7: TM ', @ok, ', custom role ', @e1, ', TA ', @e2, ', change code ', @e3);
GO
/* RF8 (DR-17, AC-PLT-19): an undefined key (50020), a re-mask timeout of 5 seconds (50020), a time not written
   "HH:MM" (50020) and a working day of 2 hours (50044) are refused; 07:00 to 18:00 and 30 seconds are accepted. */
DECLARE @t1 INT, @u1 BIGINT, @e1 INT, @e2 INT, @e3 INT, @e4 INT, @n INT;
DECLARE @try TABLE (i INT IDENTITY, k VARCHAR(100), v NVARCHAR(20));
INSERT @try (k, v) VALUES ('ui.no.such.key', N'1'), ('security.reveal.remask_seconds', N'5'), ('work.start', N'"8:00"'), ('work.end', N'"10:00"');
DECLARE @i INT = 1, @k VARCHAR(100), @v NVARCHAR(20), @e INT;
WHILE @i <= 4
BEGIN
    SELECT @k = k, @v = v FROM @try WHERE i = @i;
    SET @e = NULL;
    BEGIN TRANSACTION;
    EXEC #Fixture;
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
    EXEC #Bind @t1, @u1;
    EXECUTE AS USER = N'tp_test_rfapp';
    BEGIN TRY INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@t1, @k, @v); END TRY
    BEGIN CATCH SET @e = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
    REVERT;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    IF @i = 1 SET @e1 = @e; IF @i = 2 SET @e2 = @e; IF @i = 3 SET @e3 = @e; IF @i = 4 SET @e4 = @e;
    SET @i += 1;
END;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
EXECUTE AS USER = N'tp_test_rfapp';
BEGIN TRY
    INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@t1, 'work.start', N'"07:00"');
    INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@t1, 'work.end', N'"18:00"');
    INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (@t1, 'security.reveal.remask_seconds', N'30');
    SELECT @n = COUNT(*) FROM cfg.TenantSetting WHERE TenantId = @t1;
END TRY BEGIN CATCH SET @n = -ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 50020 AND @e2 = 50020 AND @e3 = 50020 AND @e4 = 50044 AND @n = 3
    PRINT 'PASS RF8: a tenant setting has a definition and a value of its type within the bounds, and the working day is 4 to 12 hours';
ELSE PRINT CONCAT('FAIL RF8: undefined ', @e1, ', 5 s ', @e2, ', 8:00 ', @e3, ', 2 h day ', @e4, ', valid ', @n);
GO
/* RF9 (DR-18): a document of a sensitive type marked CONFIDENTIAL (50045), a PUBLIC document (547) and a current
   version of another document (547) are refused; marking a type sensitive raises its documents to RESTRICTED. */
DECLARE @t1 INT, @u1 BIGINT, @k1 BIGINT, @s1 BIGINT, @p1 BIGINT, @d1 BIGINT, @d2 BIGINT, @v2 BIGINT,
        @e1 INT, @e2 INT, @e3 INT, @raised VARCHAR(12);
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @k1 = v FROM #F WHERE k = 'key1';
SELECT @p1 = v FROM #F WHERE k = 'plain1';
EXEC #Bind @t1, @u1;
BEGIN TRY INSERT doc.Document (TenantId, DocumentTypeId, Title, Sensitivity) VALUES (@t1, @p1, N'Public', 'PUBLIC'); END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
INSERT doc.Document (TenantId, DocumentTypeId, Title) VALUES (@t1, @p1, N'One');
SET @d1 = SCOPE_IDENTITY();
INSERT doc.Document (TenantId, DocumentTypeId, Title) VALUES (@t1, @p1, N'Two');
SET @d2 = SCOPE_IDENTITY();
INSERT doc.DocumentVersion (TenantId, DocumentId, VersionNo, StorageKey, SizeBytes, Sha256, KeyId)
VALUES (@t1, @d2, 1, 'rf/two.pdf', 10, HASHBYTES('SHA2_256', 'two'), @k1);
SET @v2 = SCOPE_IDENTITY();
BEGIN TRY UPDATE doc.Document SET CurrentVersionId = @v2 WHERE DocumentId = @d1; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
UPDATE cat.DocumentType SET IsSensitive = 1 WHERE DocumentTypeId = @p1;
SELECT @raised = CONCAT(MIN(Sensitivity), '/', COUNT(*)) FROM doc.Document WHERE DocumentTypeId = @p1;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @s1 = v FROM #F WHERE k = 'sens1';
EXEC #Bind @t1, @u1;
EXECUTE AS USER = N'tp_test_rfapp';
BEGIN TRY INSERT doc.Document (TenantId, DocumentTypeId, Title, Sensitivity) VALUES (@t1, @s1, N'Identity card', 'CONFIDENTIAL'); END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 50045 AND @e2 = 547 AND @e3 = 547 AND @raised = 'RESTRICTED/2'
    PRINT 'PASS RF9: a document of a sensitive type is RESTRICTED, never PUBLIC, and its current version is one of its own';
ELSE PRINT CONCAT('FAIL RF9: sensitive type ', @e1, ', public ', @e2, ', other document''s version ', @e3, ', raised ', @raised);
GO
/* RF10 (DR-48): a lower-case ISO country code and a lower-case catalogue code are refused (547). */
DECLARE @t1 INT, @u1 BIGINT, @e1 INT, @e2 INT;
BEGIN TRANSACTION;
BEGIN TRY INSERT ref.Country (Iso2, Iso3, NameAr, NameEn) VALUES ('zq', 'ZQQ', N'تجربة', N'Test'); END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
BEGIN TRY INSERT cat.DocumentType (TenantId, Code, NameAr, NameEn, AppliesTo) VALUES (@t1, 'passport', N'جواز', N'Passport', 'PARTY'); END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 547
    PRINT 'PASS RF10: codes are checked in capitals: a lower-case country or catalogue code is refused';
ELSE PRINT CONCAT('FAIL RF10: country ', @e1, ', catalogue code ', @e2);
GO
/* RF11 (DR-19): REVOKED without date and reason, a revocation date on an active row and EXPIRED without an end date
   are refused (547); a revoked signatory does not return to ACTIVE (50046). Foreign keys to the relationship, party,
   class and document are off: they are not what is tested. */
DECLARE @t1 INT, @u1 BIGINT, @s BIGINT, @e1 INT, @e2 INT, @e3 INT, @e4 INT, @today DATE = CAST(SYSUTCDATETIME() AS DATE);
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
ALTER TABLE acc.Signatory NOCHECK CONSTRAINT FK_Signatory_RelationshipId, FK_Signatory_PartyId, FK_Signatory_SignatureClassId, FK_Signatory_AuthorizationDocumentId;
INSERT acc.Signatory (TenantId, RelationshipId, PartyId, SignatureClassId, AuthorizationDocumentId, ValidFrom, Status)
VALUES (@t1, 1, 1, 1, 1, @today, 'ACTIVE');
SET @s = SCOPE_IDENTITY();
BEGIN TRY UPDATE acc.Signatory SET Status = 'REVOKED' WHERE SignatoryId = @s; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE acc.Signatory SET RevokedAt = SYSUTCDATETIME() WHERE SignatoryId = @s; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE acc.Signatory SET Status = 'EXPIRED' WHERE SignatoryId = @s; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
UPDATE acc.Signatory SET Status = 'REVOKED', RevokedAt = SYSUTCDATETIME(), RevokedReason = N'Left the company' WHERE SignatoryId = @s;
BEGIN TRY UPDATE acc.Signatory SET Status = 'ACTIVE', RevokedAt = NULL, RevokedReason = NULL WHERE SignatoryId = @s; END TRY
BEGIN CATCH SET @e4 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 547 AND @e3 = 547 AND @e4 = 50046
    PRINT 'PASS RF11: a signatory''s revocation has its date and reason, an expiry its end date, and both are final';
ELSE PRINT CONCAT('FAIL RF11: revoked bare ', @e1, ', date on active ', @e2, ', expired open ', @e3, ', back to active ', @e4);
GO
/* RF12 (DR-21): an ACTIVE grant without its approver, an approver without a time, and a grant of company 2 that
   supersedes a grant of company 1 are refused (547); within company 1 the supersession is accepted. */
DECLARE @t1 INT, @u1 BIGINT, @g BIGINT, @e1 INT, @e2 INT, @e3 INT, @ok INT, @today DATE = CAST(SYSUTCDATETIME() AS DATE), @now DATETIME2(3) = SYSUTCDATETIME();
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
ALTER TABLE org.AuthorityGrant NOCHECK CONSTRAINT FK_AuthorityGrant_CompanyId, FK_AuthorityGrant_PartyId, FK_AuthorityGrant_PowerTypeId;
BEGIN TRY INSERT org.AuthorityGrant (TenantId, CompanyId, GranteeKind, PartyId, PowerTypeId, ValidFrom, Status, ExceptionReason)
          VALUES (@t1, 1, 'PARTY', 1, 1, @today, 'ACTIVE', N'Board minute pending'); END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT org.AuthorityGrant (TenantId, CompanyId, GranteeKind, PartyId, PowerTypeId, ValidFrom, Status, ApprovedBy)
          VALUES (@t1, 1, 'PARTY', 1, 1, @today, 'DRAFT', @u1); END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
INSERT org.AuthorityGrant (TenantId, CompanyId, GranteeKind, PartyId, PowerTypeId, ValidFrom, Status, ExceptionReason, ApprovedBy, ApprovedAt)
VALUES (@t1, 1, 'PARTY', 1, 1, @today, 'ACTIVE', N'Board minute pending', @u1, @now);
SET @g = SCOPE_IDENTITY();
BEGIN TRY INSERT org.AuthorityGrant (TenantId, CompanyId, GranteeKind, PartyId, PowerTypeId, ValidFrom, SupersedesGrantId)
          VALUES (@t1, 2, 'PARTY', 1, 1, @today, @g); END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT org.AuthorityGrant (TenantId, CompanyId, GranteeKind, PartyId, PowerTypeId, ValidFrom, SupersedesGrantId)
          VALUES (@t1, 1, 'PARTY', 1, 1, @today, @g); SET @ok = @@ROWCOUNT; END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 547 AND @e3 = 547 AND @ok = 1
    PRINT 'PASS RF12: an authority grant in force has its approver and time, and supersedes only a grant of its own company';
ELSE PRINT CONCAT('FAIL RF12: active without approver ', @e1, ', approver without time ', @e2, ', other company ', @e3, ', same company ', @ok);
GO
/* RF13 (DR-23): a document of party 1 superseded by a document of party 2 is refused (547); by a document of
   party 1 it is accepted. */
DECLARE @t1 INT, @u1 BIGINT, @d1 BIGINT, @d2 BIGINT, @d3 BIGINT, @e1 INT, @ok INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
ALTER TABLE pty.IdentityDocument NOCHECK CONSTRAINT FK_IdentityDocument_PartyId, FK_IdentityDocument_IssuingCountryId, FK_IdentityDocument_EncKeyId, FK_IdentityDocument_HashKeyId;
INSERT pty.IdentityDocument (TenantId, PartyId, DocKind, IssuingCountryId, NumberEnc, NumberMask, NumberHash, EncKeyId, HashKeyId)
VALUES (@t1, 1, 'PASSPORT', 1, CRYPT_GEN_RANDOM(40), N'****0001', HASHBYTES('SHA2_256', 'p1-a'), 1, 1);
SET @d1 = SCOPE_IDENTITY();
INSERT pty.IdentityDocument (TenantId, PartyId, DocKind, IssuingCountryId, NumberEnc, NumberMask, NumberHash, EncKeyId, HashKeyId)
VALUES (@t1, 2, 'PASSPORT', 1, CRYPT_GEN_RANDOM(40), N'****0002', HASHBYTES('SHA2_256', 'p2-a'), 1, 1);
SET @d2 = SCOPE_IDENTITY();
INSERT pty.IdentityDocument (TenantId, PartyId, DocKind, IssuingCountryId, NumberEnc, NumberMask, NumberHash, EncKeyId, HashKeyId)
VALUES (@t1, 1, 'PASSPORT', 1, CRYPT_GEN_RANDOM(40), N'****0003', HASHBYTES('SHA2_256', 'p1-b'), 1, 1);
SET @d3 = SCOPE_IDENTITY();
BEGIN TRY UPDATE pty.IdentityDocument SET IsSuperseded = 1, SupersededById = @d2 WHERE IdentityDocumentId = @d1; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE pty.IdentityDocument SET IsSuperseded = 1, SupersededById = @d3 WHERE IdentityDocumentId = @d1; SET @ok = @@ROWCOUNT; END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @ok = 1
    PRINT 'PASS RF13: an identity document is superseded only by a document of the same party';
ELSE PRINT CONCAT('FAIL RF13: other party ', @e1, ', same party ', @ok);
GO
/* RF14 (DR-24): a company whose mirror is an individual is refused (547); an organisation is accepted. */
DECLARE @t1 INT, @u1 BIGINT, @pi BIGINT, @po BIGINT, @e1 INT, @ok INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
ALTER TABLE org.Company NOCHECK CONSTRAINT FK_Company_LegalEntityTypeId, FK_Company_CountryId;
INSERT pty.Party (TenantId, PartyCode, Kind, NameEn) VALUES (@t1, 'P-IND', 'INDIVIDUAL', N'A person');
SET @pi = SCOPE_IDENTITY();
INSERT pty.Party (TenantId, PartyCode, Kind, NameEn) VALUES (@t1, 'P-ORG', 'ORGANIZATION', N'A company');
SET @po = SCOPE_IDENTITY();
BEGIN TRY INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth)
          VALUES (@t1, 'C1', N'شركة', N'Company', @pi, 1, 1, 12); END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth)
          VALUES (@t1, 'C1', N'شركة', N'Company', @po, 1, 1, 12); SET @ok = @@ROWCOUNT; END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @ok = 1
    PRINT 'PASS RF14: a company''s mirror party is an organisation';
ELSE PRINT CONCAT('FAIL RF14: individual mirror ', @e1, ', organisation ', @ok);
GO
/* RF15 (DR-29): a base rate without a currency (515) and an alias of a bank's rate in the market scope (547) are
   refused; the same alias in two scopes is accepted, twice in one scope is not (2627). */
DECLARE @t1 INT, @u1 BIGINT, @m INT, @b INT, @e1 INT, @e2 INT, @e3 INT, @ok INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
ALTER TABLE cat.BaseRate NOCHECK CONSTRAINT FK_BaseRate_InstitutionId, FK_BaseRate_CurrencyId;
BEGIN TRY INSERT cat.BaseRate (TenantId, Code, NameAr, Kind, FamilyCode, Tenor) VALUES (@t1, 'SAIBOR_3M', N'سايبور', 'MARKET', 'SAIBOR', '3M'); END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
INSERT cat.BaseRate (TenantId, Code, NameAr, Kind, FamilyCode, Tenor, CurrencyId) VALUES (@t1, 'SAIBOR_3M', N'سايبور', 'MARKET', 'SAIBOR', '3M', 1);
SET @m = SCOPE_IDENTITY();
INSERT cat.BaseRate (TenantId, Code, NameAr, Kind, InstitutionId, FamilyCode, Tenor, CurrencyId) VALUES (@t1, 'BANK7_3M', N'سعر البنك', 'BANK_INTERNAL', 7, 'BANK7', '3M', 1);
SET @b = SCOPE_IDENTITY();
BEGIN TRY INSERT cat.BaseRateAlias (TenantId, BaseRateId, Tenor, ScopeKey, Alias) VALUES (@t1, @b, '3M', 0, N'House rate'); END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY
    INSERT cat.BaseRateAlias (TenantId, BaseRateId, Tenor, ScopeKey, Alias) VALUES (@t1, @b, '3M', 7, N'SIBOR'), (@t1, @m, '3M', 0, N'SIBOR');
    SET @ok = @@ROWCOUNT;
END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT cat.BaseRateAlias (TenantId, BaseRateId, Tenor, ScopeKey, Alias) VALUES (@t1, @m, '3M', 0, N'sibor'); END TRY
BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 515 AND @e2 = 547 AND @ok = 2 AND @e3 = 2627
    PRINT 'PASS RF15: a base rate has a currency, and an alias stays in its rate''s scope, unique within it';
ELSE PRINT CONCAT('FAIL RF15: no currency ', @e1, ', alias out of scope ', @e2, ', two scopes ', @ok, ', same scope ', @e3);
GO
/* RF16 (DR-47): ' ab 1 ' gives AB1; a second company with 'AB 1' is refused (2601) until the first clears its code;
   a code of spaces is refused (547); a counterparty's Arabic-Indic digits become Latin. */
DECLARE @t1 INT, @u1 BIGINT, @c1 BIGINT, @n1 NVARCHAR(20), @e1 INT, @e2 INT, @ok INT, @cp NVARCHAR(40);
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
ALTER TABLE org.Company NOCHECK CONSTRAINT FK_Company_LegalEntityTypeId, FK_Company_CountryId, FK_Company_PartyId;
ALTER TABLE lc.Counterparty NOCHECK CONSTRAINT FK_Counterparty_CountryId;
INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth, ErpCompanyCode)
VALUES (@t1, 'C1', N'شركة', N'Company 1', 1, 1, 1, 12, N' ab 1 ');
SET @c1 = SCOPE_IDENTITY();
SELECT @n1 = ErpCodeNormalized FROM org.Company WHERE CompanyId = @c1;
BEGIN TRY INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth, ErpCompanyCode)
          VALUES (@t1, 'C2', N'شركة', N'Company 2', 2, 1, 1, 12, N'AB 1'); END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
UPDATE org.Company SET ErpCompanyCode = NULL WHERE CompanyId = @c1;
BEGIN TRY INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth, ErpCompanyCode)
          VALUES (@t1, 'C2', N'شركة', N'Company 2', 2, 1, 1, 12, N'AB 1'); SET @ok = @@ROWCOUNT; END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth, ErpCompanyCode)
          VALUES (@t1, 'C3', N'شركة', N'Company 3', 3, 1, 1, 12, N'   '); END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
INSERT lc.Counterparty (TenantId, Code, Kind, NameEn, NameNormalized, CountryId, ErpCode) VALUES (@t1, 'CP1', 'SUPPLIER', N'Supplier', N'SUPPLIER', 1, N'٤٥ x');
SELECT @cp = ErpCodeNormalized FROM lc.Counterparty WHERE TenantId = @t1 AND Code = 'CP1';
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @n1 = N'AB1' AND @e1 = 2601 AND @ok = 1 AND @e2 = 547 AND @cp = N'45X'
    PRINT 'PASS RF16: the normalised ERP code is computed from the code, unique while set, and freed when cleared';
ELSE PRINT CONCAT('FAIL RF16: normalised ', @n1, ', duplicate ', @e1, ', after clearing ', @ok, ', spaces ', @e2, ', counterparty ', @cp);
GO

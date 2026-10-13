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
   RF17 a collateral has its type's structure, a guarantee hangs only off a guarantee collateral, and a used type
        keeps its structure (DR-40)
   RF18 the reporting role reads no agreement text, and the application changes neither an issued proforma's content
        nor its lines (DR-31, DR-41)
   RF19 a product and a financing type pair only as the Shariah rule allows, and a used classification stays (DR-30)
   RF20 an alert rule's recipient roles are roles of its own tenant (DR-16)
   RF21 a company's tax numbers come from its mirror's current tax identity, for the bound tenant only (DR-25)
   RF22 an owner holds a company indirectly per path through a named intermediate, never a company of the tenant
        (DR-22, S1-b; 044)
   RF23 a value conflict names an existing target and carries its facility (DR-27, S2; 044)
   RF24 a facility revision is approved whole: its approved row, parents in the revision, one row per node, and no
        way back (DR-28, DQ-F13-4, S2; 044 and the generator's RootId)
   RF25 agreement text holds no unmasked IBAN or account number (DR-31, DQ-S06-7, S2)
   RF26 collateral versions share their root, with one draft and one current approved version, and links name the root
        (DR-36, S2; 044)
   RF27 a covenant's threshold unit is its formula's and its measure's, and a formula on statements fixes the basis
        (DR-38, S2)
   RF28 an evaluated covenant test changes only by its review, and an automatic evaluation names its formula version
        and stores all it read (DR-39, DQ-F15-4, S2-b; 044)
   RF29 an agenda item that left SCHEDULED keeps its status, obligation and period (DR-39, DQ-F15-13, S2-b; 044)
   RF30 locked LC terms change only in their treasury fields until TreasuryHash, and their clauses and charges not at
        all (DR-41, S3; 044)
   RF31 a published template version only retires, its parts do not change, and a request type has one current
        template (DR-41, DR-49, S3; 044)
   RF32 the request copies its stage instance and reservation through the database only, and a drift is reported
        (DR-44, DQ-F11-10, S3; 044)
   RF33 a restricted LC field is never copied into a comparison or an amendment, and its change is read from the keyed
        hash (DR-46, DQ-F12-11, S3; 044)
   RF34 a proforma's lines are written once and its totals follow them (DR-41, BR-LCE-001, S4; 044)
   The other declarative fixes of S2 to S4 (keys and checks) are verified on the generated DDL by
   tools/dbgen/check_review_fixes.py, CI step 3.

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
IF USER_ID(N'tp_test_rfread') IS NULL
BEGIN
    CREATE USER [tp_test_rfread] WITHOUT LOGIN;
    ALTER ROLE [tp_readonly] ADD MEMBER [tp_test_rfread];
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
/* RF17 (DR-40): a GUARANTEE collateral of a REAL_ESTATE type (547), a guarantee on a REAL_ESTATE collateral (547)
   and a change of a used type's structure (547) are refused; a guarantee on a GUARANTEE collateral is accepted. */
DECLARE @t1 INT, @u1 BIGINT, @tg INT, @tr INT, @cg BIGINT, @cr BIGINT, @e1 INT, @e2 INT, @e3 INT, @ok INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
INSERT cat.CollateralType (TenantId, Code, NameAr, StructureKind) VALUES (@t1, 'GUAR', N'كفالة', 'GUARANTEE'), (@t1, 'PROPERTY', N'عقار', 'REAL_ESTATE');
SELECT @tg = CollateralTypeId FROM cat.CollateralType WHERE TenantId = @t1 AND Code = 'GUAR';
SELECT @tr = CollateralTypeId FROM cat.CollateralType WHERE TenantId = @t1 AND Code = 'PROPERTY';
BEGIN TRY INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr) VALUES (@t1, 'GUARANTEE', @tr, N'ضمان'); END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr) VALUES (@t1, 'GUARANTEE', @tg, N'كفالة');
SET @cg = SCOPE_IDENTITY();
INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr) VALUES (@t1, 'REAL_ESTATE', @tr, N'عقار');
SET @cr = SCOPE_IDENTITY();
ALTER TABLE col.Guarantee NOCHECK CONSTRAINT FK_Guarantee_GuarantorPartyId;
BEGIN TRY INSERT col.Guarantee (TenantId, CollateralId, GuarantorPartyId, GuaranteeForm, IsJointSeveral, AmountMode)
          VALUES (@t1, @cr, 1, 'SIMPLE', 0, 'UNSPECIFIED'); END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT col.Guarantee (TenantId, CollateralId, GuarantorPartyId, GuaranteeForm, IsJointSeveral, AmountMode)
          VALUES (@t1, @cg, 1, 'SIMPLE', 0, 'UNSPECIFIED'); SET @ok = @@ROWCOUNT; END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE cat.CollateralType SET StructureKind = 'GENERIC' WHERE CollateralTypeId = @tg; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 547 AND @ok = 1 AND @e3 = 547
    PRINT 'PASS RF17: a collateral has its type''s structure, a guarantee hangs only off a guarantee collateral, and a used type keeps its structure';
ELSE PRINT CONCAT('FAIL RF17: collateral of another structure ', @e1, ', guarantee on property ', @e2, ', guarantee on guarantee ', @ok, ', type change ', @e3);
GO
/* RF18 (DR-31, DR-41): the reporting role reads a limit's code but not its source text, nor an obligation's clause
   or a conflict's candidate text (14 denied columns); the application may update an issued proforma's status but
   not its total, and may add proforma lines but not change them. */
DECLARE @a INT, @b INT, @c INT, @d INT, @e INT, @f INT, @g INT, @h INT, @n INT;
EXECUTE AS USER = N'tp_test_rfread';
SELECT @a = HAS_PERMS_BY_NAME('fac.Limit', 'OBJECT', 'SELECT', 'OriginalText', 'COLUMN'),
       @b = HAS_PERMS_BY_NAME('fac.Limit', 'OBJECT', 'SELECT', 'Code', 'COLUMN'),
       @c = HAS_PERMS_BY_NAME('obl.Obligation', 'OBJECT', 'SELECT', 'ClauseText', 'COLUMN'),
       @d = HAS_PERMS_BY_NAME('fac.ValueConflict', 'OBJECT', 'SELECT', 'CandidateAOriginalText', 'COLUMN');
REVERT;
EXECUTE AS USER = N'tp_test_rfapp';
SELECT @e = HAS_PERMS_BY_NAME('lc.ProformaInvoice', 'OBJECT', 'UPDATE', 'Total', 'COLUMN'),
       @f = HAS_PERMS_BY_NAME('lc.ProformaInvoice', 'OBJECT', 'UPDATE', 'Status', 'COLUMN'),
       @g = HAS_PERMS_BY_NAME('lc.ProformaLine', 'OBJECT', 'UPDATE'),
       @h = HAS_PERMS_BY_NAME('lc.ProformaLine', 'OBJECT', 'INSERT');
REVERT;
SELECT @n = COUNT(*)
FROM sys.database_permissions AS p
JOIN sys.columns AS c ON c.object_id = p.major_id AND c.column_id = p.minor_id
WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'tp_readonly') AND p.state = 'D' AND p.permission_name = 'SELECT'
  AND c.name IN (N'OriginalText', N'CandidateAOriginalText', N'CandidateBOriginalText', N'ClauseText');
IF @a = 0 AND @b = 1 AND @c = 0 AND @d = 0 AND @e = 0 AND @f = 1 AND @g = 0 AND @h = 1 AND @n = 14
    PRINT 'PASS RF18: the reporting role reads no agreement text, and an issued proforma''s content and lines do not change';
ELSE PRINT CONCAT('FAIL RF18: read source text ', @a, ', read code ', @b, ', clause ', @c, ', candidate ', @d, ', proforma total ', @e,
                  ', status ', @f, ', line update ', @g, ', line insert ', @h, ', denied columns ', @n);
GO
/* RF19 (DR-30): a conventional product with an Islamic financing type and an Islamic product with a conventional one
   are refused (547); a neutral product takes both; a used product's compliance and a used type's flag do not change
   (547). */
DECLARE @t1 INT, @u1 BIGINT, @pc INT, @pi INT, @pn INT, @fc INT, @fi INT, @e1 INT, @e2 INT, @e3 INT, @e4 INT, @ok INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
EXEC #Bind @t1, @u1;
ALTER TABLE cat.Product NOCHECK CONSTRAINT FK_Product_ProductCategoryId;
INSERT cat.Product (TenantId, Code, NameAr, ProductCategoryId, ProductFamily, ConsumesCreditLimit, Compliance)
VALUES (@t1, 'LC_CONV', N'اعتماد تقليدي', 1, 'LC', 1, 'CONVENTIONAL'), (@t1, 'LC_MURABAHA', N'اعتماد مرابحة', 1, 'LC', 1, 'ISLAMIC'),
       (@t1, 'COLLECTION', N'تحصيل', 1, 'COLLECTION', 0, 'NEUTRAL');
SELECT @pc = ProductId FROM cat.Product WHERE TenantId = @t1 AND Code = 'LC_CONV';
SELECT @pi = ProductId FROM cat.Product WHERE TenantId = @t1 AND Code = 'LC_MURABAHA';
SELECT @pn = ProductId FROM cat.Product WHERE TenantId = @t1 AND Code = 'COLLECTION';
INSERT cat.FinancingType (TenantId, Code, NameAr, IsIslamic, ReturnLabel)
VALUES (@t1, 'LOAN', N'قرض', 0, 'INTEREST'), (@t1, 'MURABAHA', N'مرابحة', 1, 'PROFIT');
SELECT @fc = FinancingTypeId FROM cat.FinancingType WHERE TenantId = @t1 AND Code = 'LOAN';
SELECT @fi = FinancingTypeId FROM cat.FinancingType WHERE TenantId = @t1 AND Code = 'MURABAHA';
BEGIN TRY INSERT cat.ProductFinancingType (TenantId, ProductCompliance, ProductId, FinancingIsIslamic, FinancingTypeId) VALUES (@t1, 'CONVENTIONAL', @pc, 1, @fi); END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT cat.ProductFinancingType (TenantId, ProductCompliance, ProductId, FinancingIsIslamic, FinancingTypeId) VALUES (@t1, 'ISLAMIC', @pi, 0, @fc); END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY
    INSERT cat.ProductFinancingType (TenantId, ProductCompliance, ProductId, FinancingIsIslamic, FinancingTypeId)
    VALUES (@t1, 'CONVENTIONAL', @pc, 0, @fc), (@t1, 'ISLAMIC', @pi, 1, @fi), (@t1, 'NEUTRAL', @pn, 0, @fc), (@t1, 'NEUTRAL', @pn, 1, @fi);
    SET @ok = @@ROWCOUNT;
END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE cat.Product SET Compliance = 'ISLAMIC' WHERE ProductId = @pc; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE cat.FinancingType SET IsIslamic = 1 WHERE FinancingTypeId = @fc; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 547 AND @ok = 4 AND @e3 = 547 AND @e4 = 547
    PRINT 'PASS RF19: a product and a financing type pair only as the Shariah rule allows, and a used classification stays';
ELSE PRINT CONCAT('FAIL RF19: conventional with Islamic ', @e1, ', Islamic with conventional ', @e2, ', allowed pairs ', @ok,
                  ', product change ', @e3, ', type change ', @e4);
GO
/* RF20 (DR-16): a recipient role of another tenant is refused (547); a role of the rule's tenant is accepted. */
DECLARE @t1 INT, @u1 BIGINT, @rTM BIGINT, @rOther BIGINT, @rule BIGINT, @e1 INT, @ok INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
SELECT @rTM = v FROM #F WHERE k = 'rTM1'; SELECT @rOther = v FROM #F WHERE k = 'rTM2';
EXEC #Bind @t1, @u1;
INSERT cfg.ExpiryAlertRule (TenantId, ItemType, LeadDays) VALUES (@t1, 'COMPANY_DOCUMENT', N'[90,60,30,7]');
SET @rule = SCOPE_IDENTITY();
BEGIN TRY INSERT cfg.ExpiryAlertRuleRole (TenantId, ExpiryAlertRuleId, RoleId) VALUES (@t1, @rule, @rOther); END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT cfg.ExpiryAlertRuleRole (TenantId, ExpiryAlertRuleId, RoleId) VALUES (@t1, @rule, @rTM); SET @ok = @@ROWCOUNT; END TRY
BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @ok = 1
    PRINT 'PASS RF20: an alert rule''s recipient roles are roles of its own tenant';
ELSE PRINT CONCAT('FAIL RF20: other tenant''s role ', @e1, ', own role ', @ok);
GO
/* RF21 (DR-25): through org.v_CompanyTaxIdentity the application bound to tenant 1 sees its company's current tax and
   VAT numbers, not the superseded declaration and not tenant 2's company. */
DECLARE @t1 INT, @t2 INT, @u1 BIGINT, @p1 BIGINT, @p2 BIGINT, @c1 BIGINT, @n INT, @tax VARCHAR(40), @vat VARCHAR(40), @country INT;
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @t2 = v FROM #F WHERE k = 't2'; SELECT @u1 = v FROM #F WHERE k = 'u1';
SET @country = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA');
ALTER TABLE org.Company NOCHECK CONSTRAINT FK_Company_LegalEntityTypeId;
EXEC #Bind @t2, 0;
INSERT pty.Party (TenantId, PartyCode, Kind, NameEn) VALUES (@t2, 'P-ORG', 'ORGANIZATION', N'Other tenant company');
SET @p2 = SCOPE_IDENTITY();
INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth)
VALUES (@t2, 'C2', N'شركة', N'Company 2', @p2, 1, @country, 12);
EXEC #Bind @t1, @u1;
INSERT pty.Party (TenantId, PartyCode, Kind, NameEn) VALUES (@t1, 'P-ORG', 'ORGANIZATION', N'Company 1');
SET @p1 = SCOPE_IDENTITY();
INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth)
VALUES (@t1, 'C1', N'شركة', N'Company 1', @p1, 1, @country, 12);
SET @c1 = SCOPE_IDENTITY();
INSERT pty.TaxIdentity (TenantId, PartyId, CountryId, TaxNumber, VatNumber, DeclarationDate, IsCurrent)
VALUES (@t1, @p1, @country, '300000000000001', '310000000000001', '2025-01-01', 0),
       (@t1, @p1, @country, '300000000000002', '310000000000002', '2026-01-01', 1);
EXECUTE AS USER = N'tp_test_rfapp';
SELECT @n = COUNT(*) FROM org.v_CompanyTaxIdentity;
SELECT @tax = TaxNumber, @vat = VatNumber FROM org.v_CompanyTaxIdentity WHERE CompanyId = @c1;
REVERT;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @n = 1 AND @tax = '300000000000002' AND @vat = '310000000000002'
    PRINT 'PASS RF21: a company''s tax numbers come from its mirror''s current tax identity, for the bound tenant only';
ELSE PRINT CONCAT('FAIL RF21: companies seen ', @n, ', tax ', @tax, ', VAT ', @vat);
GO
/* RF22 (DR-22, S1-b): an owner may hold a company indirectly through two named intermediates at once; a direct row
   has no intermediate and an indirect row has one that is not the owner; the same path is not entered twice; a path
   through a company of the tenant is refused (50047), and so is a company whose mirror is the intermediate of an
   open path. A trigger error ends its transaction, so the last case has its own. */
DECLARE @t1 INT, @u1 BIGINT, @country INT, @pc BIGINT, @c BIGINT, @pd BIGINT, @h BIGINT, @x BIGINT, @y BIGINT,
        @ok INT = 0, @dup INT, @e1 INT, @e2 INT, @e3 INT, @e4 INT, @e5 INT;
SET @country = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA');
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
ALTER TABLE org.Company NOCHECK CONSTRAINT FK_Company_LegalEntityTypeId;
EXEC #Bind @t1, @u1;
INSERT pty.Party (TenantId, PartyCode, Kind, NameEn)
VALUES (@t1, 'P-C', 'ORGANIZATION', N'Company C'), (@t1, 'P-D', 'ORGANIZATION', N'Company D'), (@t1, 'P-H', 'INDIVIDUAL', N'Holder'),
       (@t1, 'P-X', 'ORGANIZATION', N'Intermediate X'), (@t1, 'P-Y', 'ORGANIZATION', N'Intermediate Y');
SELECT @pc = PartyId FROM pty.Party WHERE TenantId = @t1 AND PartyCode = 'P-C';
SELECT @pd = PartyId FROM pty.Party WHERE TenantId = @t1 AND PartyCode = 'P-D';
SELECT @h = PartyId FROM pty.Party WHERE TenantId = @t1 AND PartyCode = 'P-H';
SELECT @x = PartyId FROM pty.Party WHERE TenantId = @t1 AND PartyCode = 'P-X';
SELECT @y = PartyId FROM pty.Party WHERE TenantId = @t1 AND PartyCode = 'P-Y';
INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth)
VALUES (@t1, 'C', N'شركة', N'Company C', @pc, 1, @country, 12), (@t1, 'D', N'شركة', N'Company D', @pd, 1, @country, 12);
SET @c = (SELECT CompanyId FROM org.Company WHERE TenantId = @t1 AND CompanyCode = 'C');
EXECUTE AS USER = N'tp_test_rfapp';
BEGIN TRY
    INSERT org.Shareholding (TenantId, CompanyId, HolderPartyId, SharePercent, Layer, IntermediatePartyId, EffectiveFrom)
    VALUES (@t1, @c, @h, 10, 1, NULL, '2026-01-01'), (@t1, @c, @h, 30, 2, @x, '2026-01-01'), (@t1, @c, @h, 5, 2, @y, '2026-01-01');
    SET @ok = @@ROWCOUNT;
END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT org.Shareholding (TenantId, CompanyId, HolderPartyId, SharePercent, Layer, IntermediatePartyId, EffectiveFrom)
          VALUES (@t1, @c, @h, 1, 2, @x, '2026-01-01'); END TRY BEGIN CATCH SET @dup = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT org.Shareholding (TenantId, CompanyId, HolderPartyId, SharePercent, Layer, IntermediatePartyId, EffectiveFrom)
          VALUES (@t1, @c, @x, 1, 2, NULL, '2026-01-01'); END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT org.Shareholding (TenantId, CompanyId, HolderPartyId, SharePercent, Layer, IntermediatePartyId, EffectiveFrom)
          VALUES (@t1, @c, @y, 1, 1, @x, '2026-01-01'); END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT org.Shareholding (TenantId, CompanyId, HolderPartyId, SharePercent, Layer, IntermediatePartyId, EffectiveFrom)
          VALUES (@t1, @c, @y, 1, 2, @y, '2026-01-01'); END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT org.Shareholding (TenantId, CompanyId, HolderPartyId, SharePercent, Layer, IntermediatePartyId, EffectiveFrom)
          VALUES (@t1, @c, @h, 2, 3, @pd, '2026-01-01'); END TRY
BEGIN CATCH SET @e4 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
REVERT;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
-- the last case: X is the intermediate of an open path, then a company with X as its mirror is added
BEGIN TRANSACTION;
EXEC #Fixture;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
ALTER TABLE org.Company NOCHECK CONSTRAINT FK_Company_LegalEntityTypeId;
EXEC #Bind @t1, @u1;
INSERT pty.Party (TenantId, PartyCode, Kind, NameEn)
VALUES (@t1, 'P-C', 'ORGANIZATION', N'Company C'), (@t1, 'P-H', 'INDIVIDUAL', N'Holder'), (@t1, 'P-X', 'ORGANIZATION', N'Intermediate X');
SELECT @pc = PartyId FROM pty.Party WHERE TenantId = @t1 AND PartyCode = 'P-C';
SELECT @h = PartyId FROM pty.Party WHERE TenantId = @t1 AND PartyCode = 'P-H';
SELECT @x = PartyId FROM pty.Party WHERE TenantId = @t1 AND PartyCode = 'P-X';
INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth)
VALUES (@t1, 'C', N'شركة', N'Company C', @pc, 1, @country, 12);
SET @c = SCOPE_IDENTITY();
INSERT org.Shareholding (TenantId, CompanyId, HolderPartyId, SharePercent, Layer, IntermediatePartyId, EffectiveFrom)
VALUES (@t1, @c, @h, 30, 2, @x, '2026-01-01');
BEGIN TRY
    INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth)
    VALUES (@t1, 'X', N'شركة', N'Company X', @x, 1, @country, 12);
END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @ok = 3 AND @dup = 2627 AND @e1 = 547 AND @e2 = 547 AND @e3 = 547 AND @e4 = 50047 AND @e5 = 50047
    PRINT 'PASS RF22: an owner holds a company through two named intermediates, never through a company of the tenant';
ELSE PRINT CONCAT('FAIL RF22: two paths and a direct row ', @ok, ', same path twice ', @dup, ', indirect without intermediate ', @e1,
                  ', direct with one ', @e2, ', owner as intermediate ', @e3, ', path through a tenant company ', @e4,
                  ', intermediate becoming a company ', @e5);
GO
/* The S2 fixture: in tenant 1, a company, a facility with one lender at 100 percent, a root limit and its child at
   revision 1, revision 1 approved. Runs inside the caller's transaction; #F holds 'f', 'l', 'lc', 'co', 'cur'.
   Catalogue and lender references are switched off for these rows (the transaction rolls the switch back). */
CREATE PROCEDURE #S2
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t1 INT, @u1 BIGINT, @country INT, @cur INT, @p BIGINT, @co BIGINT, @f BIGINT, @l BIGINT, @lc BIGINT;
    EXEC #Fixture;
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1';
    SET @country = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA');
    SET @cur = (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR');
    ALTER TABLE org.Company NOCHECK CONSTRAINT FK_Company_LegalEntityTypeId;
    ALTER TABLE fac.Facility NOCHECK CONSTRAINT FK_Facility_FacilityTypeId;
    ALTER TABLE fac.FacilityLender NOCHECK CONSTRAINT FK_FacilityLender_InstitutionId;
    ALTER TABLE fac.Limit NOCHECK CONSTRAINT FK_Limit_LimitTypeId;
    EXEC #Bind @t1, @u1;
    INSERT pty.Party (TenantId, PartyCode, Kind, NameEn) VALUES (@t1, 'P-CO', 'ORGANIZATION', N'Borrower');
    SET @p = SCOPE_IDENTITY();
    INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, CountryId, FiscalYearEndMonth)
    VALUES (@t1, 'CO', N'شركة', N'Borrower', @p, 1, @country, 12);
    SET @co = SCOPE_IDENTITY();
    INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
    VALUES (@t1, 'FAC-26-001', @co, 1, @cur, 1000000, 'EN', '2026-01-01', '2027-01-01');
    SET @f = SCOPE_IDENTITY();
    INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision) VALUES (@t1, @f, 1, 'LEAD', 100, 1);
    INSERT fac.Limit (TenantId, FacilityId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, FromRevision)
    VALUES (@t1, @f, 1, 'L1', N'حد', 'ABSOLUTE', 800000, 1, 1);
    SET @l = SCOPE_IDENTITY();
    INSERT fac.Limit (TenantId, FacilityId, ParentLimitId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, FromRevision)
    VALUES (@t1, @f, @l, 1, 'L1A', N'حد فرعي', 'ABSOLUTE', 300000, 1, 1);
    SET @lc = SCOPE_IDENTITY();
    INSERT fac.FacilityRevision (TenantId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn, SubmittedBy, SubmittedOn, ApprovedBy, ApprovedOn)
    VALUES (@t1, @f, 1, 'INITIAL', 'APPROVED', '2026-01-01', @u1, SYSUTCDATETIME(), @u1, SYSUTCDATETIME());
    UPDATE fac.Facility SET ApprovedRevisionNo = 1 WHERE FacilityId = @f;
    INSERT #F (k, v) VALUES ('f', @f), ('l', @l), ('lc', @lc), ('co', @co), ('cur', @cur);
END;
GO
/* RF23 (DR-27, S2): a conflict names an existing target and carries its facility: on a limit of facility 1 with
   facility 1 and on a collateral with no facility it is accepted; with another facility or on a missing row it is
   refused (50048). A trigger error ends its transaction, so each refusal has its own. */
DECLARE @t1 INT, @u1 BIGINT, @f BIGINT, @f2 BIGINT, @l BIGINT, @co BIGINT, @cur INT, @tg INT, @c BIGINT, @ok INT = 0, @e1 INT, @e2 INT;
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @f = v FROM #F WHERE k = 'f'; SELECT @l = v FROM #F WHERE k = 'l';
INSERT cat.CollateralType (TenantId, Code, NameAr, StructureKind) VALUES (@t1, 'GUAR', N'كفالة', 'GUARANTEE');
SET @tg = SCOPE_IDENTITY();
INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr) VALUES (@t1, 'GUARANTEE', @tg, N'كفالة');
SET @c = SCOPE_IDENTITY();
BEGIN TRY
    INSERT fac.ValueConflict (TenantId, FacilityId, TargetEntity, TargetId, FieldName, CandidateAValue, CandidateBValue)
    VALUES (@t1, @f, 'fac.Limit', @l, 'Amount', N'800000', N'850000'), (@t1, NULL, 'col.Collateral', @c, 'TitleAr', N'أ', N'ب');
    SET @ok = @@ROWCOUNT;
END TRY BEGIN CATCH SET @ok = -ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @l = v FROM #F WHERE k = 'l'; SELECT @co = v FROM #F WHERE k = 'co'; SELECT @cur = v FROM #F WHERE k = 'cur';
INSERT fac.Facility (TenantId, FacilityNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, PrecedenceLanguage, EffectiveFrom, ExpiryDate)
VALUES (@t1, 'FAC-26-002', @co, 1, @cur, 500000, 'EN', '2026-01-01', '2027-01-01');
SET @f2 = SCOPE_IDENTITY();
BEGIN TRY
    INSERT fac.ValueConflict (TenantId, FacilityId, TargetEntity, TargetId, FieldName, CandidateAValue, CandidateBValue)
    VALUES (@t1, @f2, 'fac.Limit', @l, 'Amount', N'800000', N'850000');
END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @f = v FROM #F WHERE k = 'f';
BEGIN TRY
    INSERT fac.ValueConflict (TenantId, FacilityId, TargetEntity, TargetId, FieldName, CandidateAValue, CandidateBValue)
    VALUES (@t1, @f, 'fac.Limit', 987654321, 'Amount', N'1', N'2');
END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @ok = 2 AND @e1 = 50048 AND @e2 = 50048
    PRINT 'PASS RF23: a value conflict names an existing target and carries its facility';
ELSE PRINT CONCAT('FAIL RF23: on a limit and on a collateral ', @ok, ', with another facility ', @e1, ', on a missing row ', @e2);
GO
/* RF24 (DR-28, S2): approving a revision needs its APPROVED row (50049) and never goes back (50049), and an approved
   revision stays approved (50049). At the approved revision a child points to a parent row valid at it (50050), and
   a node has one row valid at it (50050), and one open row (2601); a new row keeps its predecessor's root (547). */
DECLARE @t1 INT, @u1 BIGINT, @f BIGINT, @l BIGINT, @lc BIGINT, @l2 BIGINT, @root BIGINT, @lcroot BIGINT,
        @setup INT = 0, @e1 INT, @e2 INT, @ok INT = 0, @e3 INT, @e4 INT, @e5 INT, @e6 INT, @e7 INT, @e8 INT;
DECLARE @newRevision NVARCHAR(400) = N'INSERT fac.FacilityRevision (TenantId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn, SubmittedBy, SubmittedOn, ApprovedBy, ApprovedOn)
    VALUES (@t, @f, 2, ''AMENDMENT'', ''APPROVED'', ''2026-06-01'', @u, SYSUTCDATETIME(), @u, SYSUTCDATETIME());';
-- 1: revision 1 approved by the fixture; revision 2 without its row is refused
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @f = v FROM #F WHERE k = 'f';
SET @setup = (SELECT ApprovedRevisionNo FROM fac.Facility WHERE FacilityId = @f);
BEGIN TRY UPDATE fac.Facility SET ApprovedRevisionNo = 2 WHERE FacilityId = @f; END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
-- 2: the parent limit is amended in revision 2 and its child is left on the old row
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @f = v FROM #F WHERE k = 'f';
SELECT @l = v FROM #F WHERE k = 'l';
EXEC sys.sp_executesql @newRevision, N'@t INT, @f BIGINT, @u BIGINT', @t = @t1, @f = @f, @u = @u1;
SET @root = (SELECT RootId FROM fac.Limit WHERE LimitId = @l);
UPDATE fac.Limit SET ToRevision = 2 WHERE LimitId = @l;
INSERT fac.Limit (TenantId, FacilityId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, FromRevision, SupersedesId, InheritedRootId)
VALUES (@t1, @f, 1, 'L1', N'حد', 'ABSOLUTE', 900000, 1, 2, @l, @root);
BEGIN TRY UPDATE fac.Facility SET ApprovedRevisionNo = 2 WHERE FacilityId = @f; END TRY
BEGIN CATCH SET @e2 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
-- 3: the child follows its parent into revision 2: approved; then the approved revision cannot be reopened
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @f = v FROM #F WHERE k = 'f';
SELECT @l = v FROM #F WHERE k = 'l'; SELECT @lc = v FROM #F WHERE k = 'lc';
EXEC sys.sp_executesql @newRevision, N'@t INT, @f BIGINT, @u BIGINT', @t = @t1, @f = @f, @u = @u1;
SET @root = (SELECT RootId FROM fac.Limit WHERE LimitId = @l); SET @lcroot = (SELECT RootId FROM fac.Limit WHERE LimitId = @lc);
UPDATE fac.Limit SET ToRevision = 2 WHERE LimitId IN (@l, @lc);
INSERT fac.Limit (TenantId, FacilityId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, FromRevision, SupersedesId, InheritedRootId)
VALUES (@t1, @f, 1, 'L1', N'حد', 'ABSOLUTE', 900000, 1, 2, @l, @root);
SET @l2 = SCOPE_IDENTITY();
INSERT fac.Limit (TenantId, FacilityId, ParentLimitId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, FromRevision, SupersedesId, InheritedRootId)
VALUES (@t1, @f, @l2, 1, 'L1A', N'حد فرعي', 'ABSOLUTE', 300000, 1, 2, @lc, @lcroot);
BEGIN TRY UPDATE fac.Facility SET ApprovedRevisionNo = 2 WHERE FacilityId = @f; SET @ok = @@ROWCOUNT; END TRY
BEGIN CATCH SET @ok = -ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
IF @@TRANCOUNT > 0
BEGIN TRY UPDATE fac.FacilityRevision SET Status = 'DRAFT' WHERE FacilityId = @f AND RevisionNo = 2; END TRY
BEGIN CATCH SET @e3 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
-- 4: a second open row of a node (2601), a wrong root (547), and two rows of a node valid at revision 2 (50050)
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @f = v FROM #F WHERE k = 'f';
SELECT @l = v FROM #F WHERE k = 'l'; SELECT @lc = v FROM #F WHERE k = 'lc';
EXEC sys.sp_executesql @newRevision, N'@t INT, @f BIGINT, @u BIGINT', @t = @t1, @f = @f, @u = @u1;
SET @root = (SELECT RootId FROM fac.Limit WHERE LimitId = @l);
BEGIN TRY INSERT fac.Limit (TenantId, FacilityId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, FromRevision, SupersedesId, InheritedRootId)
          VALUES (@t1, @f, 1, 'L1B', N'حد', 'ABSOLUTE', 900000, 1, 2, @l, @root); END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT fac.Limit (TenantId, FacilityId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, FromRevision, SupersedesId, InheritedRootId)
          VALUES (@t1, @f, 1, 'L1C', N'حد', 'ABSOLUTE', 900000, 1, 2, @l, @root + 100000); END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH;
UPDATE fac.Limit SET ToRevision = 3 WHERE LimitId = @l;
INSERT fac.Limit (TenantId, FacilityId, LimitTypeId, Code, NameAr, AmountBasis, Amount, IsRevolving, FromRevision, SupersedesId, InheritedRootId)
VALUES (@t1, @f, 1, 'L1', N'حد', 'ABSOLUTE', 900000, 1, 2, @l, @root);
BEGIN TRY UPDATE fac.Facility SET ApprovedRevisionNo = 2 WHERE FacilityId = @f; END TRY
BEGIN CATCH SET @e6 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
-- 5: revision 2 approved without changes; going back to revision 1 is refused
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @f = v FROM #F WHERE k = 'f';
EXEC sys.sp_executesql @newRevision, N'@t INT, @f BIGINT, @u BIGINT', @t = @t1, @f = @f, @u = @u1;
BEGIN TRY UPDATE fac.Facility SET ApprovedRevisionNo = 2 WHERE FacilityId = @f; SET @e7 = 0; END TRY
BEGIN CATCH SET @e7 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
IF @@TRANCOUNT > 0
BEGIN TRY UPDATE fac.Facility SET ApprovedRevisionNo = 1 WHERE FacilityId = @f; END TRY
BEGIN CATCH SET @e8 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @setup = 1 AND @e1 = 50049 AND @e2 = 50050 AND @ok = 1 AND @e3 = 50049 AND @e4 = 2601 AND @e5 = 547 AND @e6 = 50050
   AND @e7 = 0 AND @e8 = 50049
    PRINT 'PASS RF24: a facility revision is approved whole: its approved row, parents in the revision, one row per node, and no way back';
ELSE PRINT CONCAT('FAIL RF24: setup ', @setup, ', no revision row ', @e1, ', child on the old parent ', @e2, ', whole revision ', @ok,
                  ', reopened ', @e3, ', second open row ', @e4, ', wrong root ', @e5, ', two rows valid ', @e6,
                  ', plain approval ', @e7, ', back to 1 ', @e8);
GO
/* RF25 (DR-31, S2): agreement text holds no unmasked IBAN or account number: a run of ten digits and an IBAN in groups
   are refused (547) in a limit's source text and a conflict's candidate text; the masked form is accepted. */
DECLARE @t1 INT, @f BIGINT, @l BIGINT, @e1 INT, @e2 INT, @e3 INT, @e4 INT, @ok INT = 0;
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @f = v FROM #F WHERE k = 'f'; SELECT @l = v FROM #F WHERE k = 'l';
BEGIN TRY UPDATE fac.Limit SET OriginalText = N'Proceeds to IBAN SA0380000000608010167519' WHERE LimitId = @l; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE fac.Limit SET OriginalText = N'Proceeds to IBAN SA03 8000 0000 6080 1016 7519' WHERE LimitId = @l; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE fac.Limit SET OriginalText = N'Account no. 6080101675 with the bank' WHERE LimitId = @l; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT fac.ValueConflict (TenantId, FacilityId, TargetEntity, TargetId, FieldName, CandidateAValue, CandidateBValue, CandidateAOriginalText)
          VALUES (@t1, @f, 'fac.Limit', @l, 'Amount', N'1', N'2', N'paid to SA0380000000608010167519'); END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE fac.Limit SET OriginalText = N'Proceeds to IBAN SA** **** **** **** **** 7519, amount SAR 1,000,000' WHERE LimitId = @l; SET @ok = @@ROWCOUNT; END TRY
BEGIN CATCH SET @ok = -ERROR_NUMBER(); END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 547 AND @e3 = 547 AND @e4 = 547 AND @ok = 1
    PRINT 'PASS RF25: agreement text holds no unmasked IBAN or account number; the masked form is accepted';
ELSE PRINT CONCAT('FAIL RF25: IBAN ', @e1, ', IBAN in groups ', @e2, ', account ', @e3, ', candidate text ', @e4, ', masked ', @ok);
GO
/* RF26 (DR-36, S2): collateral versions share their root: a new version keeps its predecessor's root (547 otherwise),
   one open draft (2601) and one current approved version (2601) per collateral, an approved version is never a draft
   or discarded (547), a release needs its document (547), and a link names the root, not a later version (50052). */
DECLARE @t1 INT, @u1 BIGINT, @f BIGINT, @tg INT, @v1 BIGINT, @v2 BIGINT, @v3 BIGINT, @e1 INT, @e2 INT, @e3 INT, @e4 INT,
        @e5 INT, @e6 INT, @e7 INT, @ok1 INT = 0, @ok2 INT = 0, @ok3 INT = 0;
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @f = v FROM #F WHERE k = 'f';
INSERT cat.CollateralType (TenantId, Code, NameAr, StructureKind) VALUES (@t1, 'GUAR', N'كفالة', 'GUARANTEE');
SET @tg = SCOPE_IDENTITY();
INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr) VALUES (@t1, 'GUARANTEE', @tg, N'كفالة');
SET @v1 = SCOPE_IDENTITY();
UPDATE col.Collateral SET ApprovalState = 'APPROVED', Status = 'ACTIVE', ApprovedBy = @u1, ApprovedOn = SYSUTCDATETIME() WHERE CollateralId = @v1;
BEGIN TRY INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr, SupersedesId, InheritedRootId)
          VALUES (@t1, 'GUARANTEE', @tg, N'كفالة', @v1, @v1 + 1000); END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr, SupersedesId, InheritedRootId)
VALUES (@t1, 'GUARANTEE', @tg, N'كفالة معدلة', @v1, @v1);
SET @v2 = SCOPE_IDENTITY();
BEGIN TRY INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr, SupersedesId, InheritedRootId)
          VALUES (@t1, 'GUARANTEE', @tg, N'مسودة ثانية', @v1, @v1); END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE col.Collateral SET ApprovalState = 'APPROVED', Status = 'ACTIVE', ApprovedBy = @u1, ApprovedOn = SYSUTCDATETIME() WHERE CollateralId = @v2; END TRY
BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
UPDATE col.Collateral SET Status = 'SUPERSEDED' WHERE CollateralId = @v1;
BEGIN TRY UPDATE col.Collateral SET ApprovalState = 'APPROVED', Status = 'ACTIVE', ApprovedBy = @u1, ApprovedOn = SYSUTCDATETIME() WHERE CollateralId = @v2;
          SET @ok1 = @@ROWCOUNT; END TRY BEGIN CATCH SET @ok1 = -ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE col.Collateral SET Status = 'DISCARDED' WHERE CollateralId = @v2; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr, SupersedesId, InheritedRootId)
VALUES (@t1, 'GUARANTEE', @tg, N'مسودة متروكة', @v2, @v1);
SET @v3 = SCOPE_IDENTITY();
BEGIN TRY UPDATE col.Collateral SET Status = 'DISCARDED' WHERE CollateralId = @v3; SET @ok2 = @@ROWCOUNT; END TRY BEGIN CATCH SET @ok2 = -ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE col.Collateral SET Status = 'RELEASED', ReleasedOn = '2026-09-01', ReleaseReason = N'سداد' WHERE CollateralId = @v2; END TRY
BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT col.CollateralLink (TenantId, CollateralId, FacilityId, LinkedOn) VALUES (@t1, @v1, @f, '2026-01-01'); SET @ok3 = @@ROWCOUNT; END TRY
BEGIN CATCH SET @ok3 = -ERROR_NUMBER(); END CATCH;
BEGIN TRY INSERT col.CollateralLink (TenantId, CollateralId, FacilityId, LinkedOn) VALUES (@t1, @v2, @f, '2026-01-01'); END TRY
BEGIN CATCH SET @e6 = ERROR_NUMBER(); IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @e1 = 547 AND @e2 = 2601 AND @e3 = 2601 AND @ok1 = 1 AND @e4 = 547 AND @ok2 = 1 AND @e5 = 547 AND @ok3 = 1 AND @e6 = 50052
    PRINT 'PASS RF26: collateral versions share their root, with one draft and one current approved version, and links name the root';
ELSE PRINT CONCAT('FAIL RF26: wrong root ', @e1, ', second draft ', @e2, ', second approved ', @e3, ', approval after superseding ', @ok1,
                  ', approved discarded ', @e4, ', draft discarded ', @ok2, ', release without document ', @e5, ', link to root ', @ok3,
                  ', link to a later version ', @e6);
GO
/* RF27 (DR-38, S2): a covenant's threshold unit is its formula's result unit (547) and fits its measure kind (547),
   each tried alone; its copy of the formula's unit is checked against the formula (547) and cannot be left out (547), a
   used formula keeps its unit (547), and a formula on statements needs the statement basis and assurance (547). */
DECLARE @t1 INT, @f BIGINT, @co BIGINT, @cur INT, @ot INT, @ob BIGINT, @fr BIGINT, @fa BIGINT,
        @ok1 INT = 0, @ok2 INT = 0, @e1 INT, @e2 INT, @e3 INT, @e4 INT, @e5 INT, @e6 INT;
DECLARE @cov NVARCHAR(MAX) = N'INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, FormulaId, FormulaResultUnit, FormulaUsesStatements, Operator,
    ThresholdState, ThresholdValue, ThresholdUnit, CurrencyId, TestFrequency, StatementBasis, RequiredAssurance, TestedCompanyId, FirstTestPeriodEnd, ValidFrom)
    VALUES (@t, @ob, @kind, @formula, @unitCopy, @stmtCopy, ''GE'', ''SET'', 1.2, @unit, @cur, ''ANNUAL'', @basis, @assurance, @co, ''2026-12-31'',
            DATEADD(DAY, (SELECT COUNT(*) FROM obl.Covenant WHERE ObligationId = @ob), ''2026-01-01''))';
DECLARE @p NVARCHAR(400) = N'@t INT, @ob BIGINT, @kind VARCHAR(30), @formula BIGINT, @unitCopy VARCHAR(10), @stmtCopy BIT, @unit VARCHAR(10), @cur INT, @basis VARCHAR(20), @assurance VARCHAR(20), @co BIGINT';
BEGIN TRANSACTION;
EXEC #S2;
SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @f = v FROM #F WHERE k = 'f'; SELECT @co = v FROM #F WHERE k = 'co'; SELECT @cur = v FROM #F WHERE k = 'cur';
INSERT cat.ObligationType (TenantId, Code, NameAr, Family, MeasureKind) VALUES (@t1, 'COV', N'تعهد', 'COVENANT', 'RATIO');
SET @ot = SCOPE_IDENTITY();
INSERT obl.Obligation (TenantId, FacilityId, Family, ObligationTypeId, TitleAr, ValidFrom) VALUES (@t1, @f, 'COVENANT', @ot, N'نسبة التداول', '2026-01-01');
SET @ob = SCOPE_IDENTITY();
INSERT fin.MeasureFormula (TenantId, Code, NameAr, Scope, Expression, InputKinds, ResultUnit) VALUES (@t1, 'CURRENT_RATIO', N'نسبة التداول', 'TEMPLATE', 'CA / CL', 'STATEMENT', 'RATIO');
SET @fr = SCOPE_IDENTITY();
INSERT fin.MeasureFormula (TenantId, Code, NameAr, Scope, Expression, InputKinds, ResultUnit) VALUES (@t1, 'AVG_BALANCE', N'متوسط الرصيد', 'TEMPLATE', 'AVG(B)', 'ACCOUNT_STATS', 'AMOUNT');
SET @fa = SCOPE_IDENTITY();
BEGIN TRY EXEC sys.sp_executesql @cov, @p, @t = @t1, @ob = @ob, @kind = 'RATIO', @formula = @fr, @unitCopy = 'RATIO', @stmtCopy = 1, @unit = 'RATIO',
          @cur = NULL, @basis = 'STANDALONE', @assurance = 'AUDITED_ONLY', @co = @co; SET @ok1 = 1; END TRY BEGIN CATCH SET @ok1 = -ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sys.sp_executesql @cov, @p, @t = @t1, @ob = @ob, @kind = 'RATIO', @formula = @fr, @unitCopy = 'AMOUNT', @stmtCopy = 1, @unit = 'AMOUNT',
          @cur = @cur, @basis = 'STANDALONE', @assurance = 'AUDITED_ONLY', @co = @co; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sys.sp_executesql @cov, @p, @t = @t1, @ob = @ob, @kind = 'RATIO', @formula = @fa, @unitCopy = 'AMOUNT', @stmtCopy = 0, @unit = 'RATIO',
          @cur = NULL, @basis = NULL, @assurance = NULL, @co = @co; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sys.sp_executesql @cov, @p, @t = @t1, @ob = @ob, @kind = 'AVERAGE_BALANCE', @formula = @fr, @unitCopy = 'RATIO', @stmtCopy = 1, @unit = 'RATIO',
          @cur = NULL, @basis = 'STANDALONE', @assurance = 'AUDITED_ONLY', @co = @co; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sys.sp_executesql @cov, @p, @t = @t1, @ob = @ob, @kind = 'RATIO', @formula = @fr, @unitCopy = 'RATIO', @stmtCopy = 1, @unit = 'RATIO',
          @cur = NULL, @basis = NULL, @assurance = NULL, @co = @co; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sys.sp_executesql @cov, @p, @t = @t1, @ob = @ob, @kind = 'AVERAGE_BALANCE', @formula = @fa, @unitCopy = 'AMOUNT', @stmtCopy = 0, @unit = 'AMOUNT',
          @cur = @cur, @basis = NULL, @assurance = NULL, @co = @co; SET @ok2 = 1; END TRY BEGIN CATCH SET @ok2 = -ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE fin.MeasureFormula SET ResultUnit = 'PERCENT' WHERE MeasureFormulaId = @fr; END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sys.sp_executesql @cov, @p, @t = @t1, @ob = @ob, @kind = 'RATIO', @formula = @fr, @unitCopy = NULL, @stmtCopy = NULL, @unit = 'RATIO',
          @cur = NULL, @basis = NULL, @assurance = NULL, @co = @co; END TRY BEGIN CATCH SET @e6 = ERROR_NUMBER(); END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @ok1 = 1 AND @e1 = 547 AND @e2 = 547 AND @e3 = 547 AND @e4 = 547 AND @ok2 = 1 AND @e5 = 547 AND @e6 = 547
    PRINT 'PASS RF27: a covenant''s threshold unit is its formula''s and its measure''s, and a formula on statements fixes their basis';
ELSE PRINT CONCAT('FAIL RF27: ratio covenant ', @ok1, ', wrong unit copy ', @e1, ', unit not the formula''s ', @e2, ', unit not the measure''s ', @e3,
                  ', statements without basis ', @e4, ', average balance ', @ok2, ', used formula''s unit changed ', @e5,
                  ', formula without its copies ', @e6);
GO
/* The S2-b fixture: #S2, a current ratio covenant on the approved formula version 1 (a draft version 2 exists), the
   borrower's audited statement for 2025, and a scheduled test of 2025. */
CREATE PROCEDURE #Cov
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t1 INT, @u1 BIGINT, @f BIGINT, @co BIGINT, @cur INT, @ot INT, @ob BIGINT, @fr BIGINT, @frd BIGINT, @fs BIGINT, @cv BIGINT, @ct BIGINT;
    EXEC #S2;
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @f = v FROM #F WHERE k = 'f';
    SELECT @co = v FROM #F WHERE k = 'co'; SELECT @cur = v FROM #F WHERE k = 'cur';
    INSERT cat.ObligationType (TenantId, Code, NameAr, Family, MeasureKind) VALUES (@t1, 'COV', N'COV', 'COVENANT', 'RATIO');
    SET @ot = SCOPE_IDENTITY();
    INSERT obl.Obligation (TenantId, FacilityId, Family, ObligationTypeId, TitleAr, ValidFrom) VALUES (@t1, @f, 'COVENANT', @ot, N'Current ratio', '2026-01-01');
    SET @ob = SCOPE_IDENTITY();
    INSERT fin.MeasureFormula (TenantId, Code, NameAr, Scope, FacilityId, Expression, InputKinds, ResultUnit, VersionNo, Status, ApprovedBy, ApprovedOn)
    VALUES (@t1, 'CURRENT_RATIO', N'Current ratio', 'FACILITY_COPY', @f, 'CA / CL', 'STATEMENT', 'RATIO', 1, 'APPROVED', @u1, SYSUTCDATETIME());
    SET @fr = SCOPE_IDENTITY();
    INSERT fin.MeasureFormula (TenantId, Code, NameAr, Scope, FacilityId, Expression, InputKinds, ResultUnit, VersionNo, Status)
    VALUES (@t1, 'CURRENT_RATIO', N'Current ratio', 'FACILITY_COPY', @f, 'CA / (CL + 1)', 'STATEMENT', 'RATIO', 2, 'DRAFT');
    SET @frd = SCOPE_IDENTITY();
    INSERT fin.FinancialStatement (TenantId, CompanyId, PeriodType, PeriodEnd, FiscalYear, Basis, Assurance, CurrencyId, EntryMethod)
    VALUES (@t1, @co, 'ANNUAL', '2025-12-31', 2025, 'STANDALONE', 'AUDITED', @cur, 'MANUAL');
    SET @fs = SCOPE_IDENTITY();
    INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, FormulaId, FormulaResultUnit, FormulaUsesStatements, Operator, ThresholdState,
                         ThresholdValue, ThresholdUnit, TestFrequency, StatementBasis, RequiredAssurance, TestedCompanyId, FirstTestPeriodEnd, ValidFrom)
    VALUES (@t1, @ob, 'RATIO', @fr, 'RATIO', 1, 'GE', 'SET', 1.2, 'RATIO', 'ANNUAL', 'STANDALONE', 'AUDITED_ONLY', @co, '2025-12-31', '2025-01-01');
    SET @cv = SCOPE_IDENTITY();
    INSERT obl.CovenantTest (TenantId, CovenantId, PeriodStart, PeriodEnd, DueDate, Method) VALUES (@t1, @cv, '2025-01-01', '2025-12-31', '2026-01-30', 'AUTO');
    SET @ct = SCOPE_IDENTITY();
    INSERT #F (k, v) VALUES ('ob', @ob), ('fr', @fr), ('frd', @frd), ('fs', @fs), ('cv', @cv), ('ct', @ct);
END;
GO
/* One case of RF28 on the fixture: evaluate the test as the case says, then change it. The snapshot names the
   formula version, the threshold and the statement it read (BR-FIN-010). */
CREATE PROCEDURE #CovCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t1 INT, @u1 BIGINT, @ob BIGINT, @fr BIGINT, @frd BIGINT, @fs BIGINT, @cv BIGINT, @ct BIGINT, @co BIGINT, @cv2 BIGINT,
            @formula BIGINT, @version INT = 1, @threshold DECIMAL(19,6) = 1.2, @result VARCHAR(30) = 'COMPLIANT', @statements NVARCHAR(400), @snapshot NVARCHAR(MAX);
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @ob = v FROM #F WHERE k = 'ob';
    SELECT @fr = v FROM #F WHERE k = 'fr'; SELECT @frd = v FROM #F WHERE k = 'frd'; SELECT @fs = v FROM #F WHERE k = 'fs';
    SELECT @cv = v FROM #F WHERE k = 'cv'; SELECT @ct = v FROM #F WHERE k = 'ct'; SELECT @co = v FROM #F WHERE k = 'co';
    SET @formula = @fr;
    SET @statements = CONCAT(N'[{"statementId":', @fs, N',"version":1,"basis":"STANDALONE"}]');
    IF @Case = 8 SET @formula = NULL;
    IF @Case = 9 SELECT @formula = @frd, @version = 2;
    IF @Case = 10 SET @statements = NULL;
    IF @Case = 11 SET @statements = CONCAT(N'[{"statementId":', @fs, N',"version":2,"basis":"STANDALONE"}]');
    IF @Case = 12 SET @threshold = 1.1;
    IF @Case = 13 SELECT @result = 'MISSING_DATA', @statements = N'[]';
    SET @snapshot = CONCAT(N'{"formula":{"id":', ISNULL(@formula, @fr), N',"version":', @version, N'},"threshold":{"value":', @threshold,
                           N',"operator":"GE"}', CASE WHEN @statements IS NOT NULL THEN CONCAT(N',"statements":', @statements) END, N'}');
    IF @Case = 13   -- a temporary procedure's variables take tempdb's collation, so no text is compared here
        UPDATE obl.CovenantTest SET State = 'EVALUATED', Result = 'MISSING_DATA', InputsSnapshot = @snapshot, FormulaId = @formula,
                                    EvaluatedAt = SYSUTCDATETIME()
        WHERE CovenantTestId = @ct;
    ELSE
        UPDATE obl.CovenantTest SET State = 'EVALUATED', Result = @result, ActualValue = 1.5, ThresholdApplied = @threshold, OperatorApplied = 'GE',
                                    Headroom = 1.5 - @threshold, HeadroomPct = 25, InputsSnapshot = @snapshot, FormulaId = @formula,
                                    EvaluatedAt = SYSUTCDATETIME()
        WHERE CovenantTestId = @ct;
    IF @Case IN (1, 2)
    BEGIN
        UPDATE obl.CovenantTest SET State = 'REVIEWED', ReviewNote = N'Checked against the audited statement', ReviewedBy = @u1, ReviewedOn = SYSUTCDATETIME()
        WHERE CovenantTestId = @ct;
        UPDATE obl.CovenantTest SET NextReviewOn = '2026-06-30' WHERE CovenantTestId = @ct;
    END;
    IF @Case = 2 UPDATE obl.CovenantTest SET ReviewNote = N'Changed later' WHERE CovenantTestId = @ct;
    IF @Case = 3 UPDATE obl.CovenantTest SET Result = 'BREACH' WHERE CovenantTestId = @ct;
    IF @Case = 4 UPDATE obl.CovenantTest SET InputsSnapshot = REPLACE(InputsSnapshot, N'"version":1,"basis"', N'"version":3,"basis"') WHERE CovenantTestId = @ct;
    IF @Case = 5 DELETE obl.CovenantTest WHERE CovenantTestId = @ct;
    IF @Case = 6 UPDATE obl.CovenantTest SET State = 'PENDING_DATA' WHERE CovenantTestId = @ct;
    IF @Case = 7
    BEGIN
        INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, FormulaId, FormulaResultUnit, FormulaUsesStatements, Operator, ThresholdState,
                             ThresholdValue, ThresholdUnit, TestFrequency, StatementBasis, RequiredAssurance, TestedCompanyId, FirstTestPeriodEnd, ValidFrom)
        VALUES (@t1, @ob, 'RATIO', @fr, 'RATIO', 1, 'GE', 'SET', 1.0, 'RATIO', 'ANNUAL', 'STANDALONE', 'AUDITED_ONLY', @co, '2026-12-31', '2026-01-01');
        SET @cv2 = SCOPE_IDENTITY();
        UPDATE obl.CovenantTest SET CovenantId = @cv2 WHERE CovenantTestId = @ct;
    END;
END;
GO
/* RF28 (DR-39, S2-b): an evaluated covenant test changes only by its review: once reviewed, only NextReviewOn changes
   (50053 for the note, the result, the snapshot, a deletion, a return to PENDING_DATA and another covenant). An
   automatic evaluation names a version of the covenant's formula that is not a draft, and its snapshot holds the
   formula version, the covenant's threshold and every statement it read with its version and basis (50054); a
   MISSING_DATA result may hold no statement. Each case has its own transaction. */
DECLARE @r TABLE (CaseNo INT PRIMARY KEY, Err INT NOT NULL);
DECLARE @i INT = 1, @e INT, @got NVARCHAR(400);
WHILE @i <= 13
BEGIN
    BEGIN TRANSACTION;
    EXEC #Cov;
    BEGIN TRY EXEC #CovCase @i; SET @e = 0; END TRY
    BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    INSERT @r (CaseNo, Err) VALUES (@i, @e);
    SET @i += 1;
END;
SET @got = (SELECT STRING_AGG(CONCAT(CaseNo, ':', Err), ' ') WITHIN GROUP (ORDER BY CaseNo) FROM @r);
IF @got = '1:0 2:50053 3:50053 4:50053 5:50053 6:50053 7:50053 8:50054 9:50054 10:50054 11:50054 12:50054 13:0'
    PRINT 'PASS RF28: an evaluated covenant test changes only by its review, and an automatic evaluation names its formula version and stores all it read';
ELSE PRINT CONCAT('FAIL RF28: case:error ', @got, ' (expected 1:0 2-7:50053 8-12:50054 13:0)');
GO
/* RF29 (DR-39, S2-b): an agenda item that left SCHEDULED keeps its status, obligation and period and is not deleted
   (50055); a submission's reference may be corrected, and a waived item may gain its evidence once. A scheduled item
   moves its due date with a reason. */
CREATE PROCEDURE #Agenda
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t1 INT, @f BIGINT, @ot INT, @ob BIGINT, @ro BIGINT, @ri BIGINT, @rw BIGINT;
    EXEC #S2;
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @f = v FROM #F WHERE k = 'f';
    ALTER TABLE obl.ReportingInstance NOCHECK CONSTRAINT FK_ReportingInstance_EvidenceDocumentId;
    INSERT cat.ObligationType (TenantId, Code, NameAr, Family) VALUES (@t1, 'FS_AUDITED', N'FS', 'REPORTING');
    SET @ot = SCOPE_IDENTITY();
    INSERT obl.Obligation (TenantId, FacilityId, Family, ObligationTypeId, TitleAr, ValidFrom) VALUES (@t1, @f, 'REPORTING', @ot, N'Audited statements', '2026-01-01');
    SET @ob = SCOPE_IDENTITY();
    INSERT obl.ReportingObligation (TenantId, ObligationId, Frequency, AnchorKind, OffsetValue, Direction, DocumentBasis, ExpectsEvidence)
    VALUES (@t1, @ob, 'ANNUAL', 'AFTER_FISCAL_YEAR_END', 120, 'WE_SUBMIT', 'AUDITED', 0);
    SET @ro = SCOPE_IDENTITY();
    INSERT obl.ReportingInstance (TenantId, ReportingObligationId, PeriodStart, PeriodEnd, DueDate) VALUES (@t1, @ro, '2025-01-01', '2025-12-31', '2026-04-30');
    SET @ri = SCOPE_IDENTITY();
    INSERT obl.ReportingInstance (TenantId, ReportingObligationId, PeriodStart, PeriodEnd, DueDate) VALUES (@t1, @ro, '2024-01-01', '2024-12-31', '2025-04-30');
    SET @rw = SCOPE_IDENTITY();
    UPDATE obl.ReportingInstance SET DueDate = '2026-05-15', DueDateOverrideReason = N'Extension letter' WHERE ReportingInstanceId = @ri;
    UPDATE obl.ReportingInstance SET Status = 'SUBMITTED', SubmittedOn = '2026-05-10', SubmissionRef = N'REF-1' WHERE ReportingInstanceId = @ri;
    UPDATE obl.ReportingInstance SET Status = 'WAIVED', StatusReason = N'Waived by the bank' WHERE ReportingInstanceId = @rw;
    INSERT #F (k, v) VALUES ('ri', @ri), ('rw', @rw);
END;
GO
CREATE PROCEDURE #AgendaCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ri BIGINT, @rw BIGINT;
    SELECT @ri = v FROM #F WHERE k = 'ri'; SELECT @rw = v FROM #F WHERE k = 'rw';
    IF @Case = 1
    BEGIN
        UPDATE obl.ReportingInstance SET SubmissionRef = N'REF-1A', SubmittedOn = '2026-05-11' WHERE ReportingInstanceId = @ri;
        UPDATE obl.ReportingInstance SET EvidenceDocumentId = 1 WHERE ReportingInstanceId = @rw;
    END;
    IF @Case = 2 UPDATE obl.ReportingInstance SET Status = 'SCHEDULED', SubmittedOn = NULL, SubmissionRef = NULL WHERE ReportingInstanceId = @ri;
    IF @Case = 3 UPDATE obl.ReportingInstance SET DueDate = '2026-06-30' WHERE ReportingInstanceId = @ri;
    IF @Case = 4 DELETE obl.ReportingInstance WHERE ReportingInstanceId = @ri;
    IF @Case = 5 UPDATE obl.ReportingInstance SET StatusReason = N'Another reason' WHERE ReportingInstanceId = @rw;
    IF @Case = 6
    BEGIN
        UPDATE obl.ReportingInstance SET EvidenceDocumentId = 1 WHERE ReportingInstanceId = @rw;
        UPDATE obl.ReportingInstance SET EvidenceDocumentId = 2 WHERE ReportingInstanceId = @rw;
    END;
END;
GO
DECLARE @r TABLE (CaseNo INT PRIMARY KEY, Err INT NOT NULL);
DECLARE @i INT = 0, @e INT, @got NVARCHAR(400);
WHILE @i <= 6
BEGIN
    BEGIN TRANSACTION;
    BEGIN TRY EXEC #Agenda; IF @i > 0 EXEC #AgendaCase @i; SET @e = 0; END TRY
    BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    INSERT @r (CaseNo, Err) VALUES (@i, @e);
    SET @i += 1;
END;
SET @got = (SELECT STRING_AGG(CONCAT(CaseNo, ':', Err), ' ') WITHIN GROUP (ORDER BY CaseNo) FROM @r);
IF @got = '0:0 1:0 2:50055 3:50055 4:50055 5:50055 6:50055'
    PRINT 'PASS RF29: an agenda item that left SCHEDULED keeps its status, obligation and period; only a submission''s details are corrected';
ELSE PRINT CONCAT('FAIL RF29: case:error ', @got, ' (expected 0:0 1:0 2-6:50055)');
GO
/* The S3 fixture: #S2, a counterparty, a request type with a published template (a draft stage, a task stage and
   an amount field), and a draft request of the borrower on it. Parts of the catalogue the tests do not need are left
   unchecked inside the transaction. */
CREATE PROCEDURE #S3
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t1 INT, @u1 BIGINT, @co BIGINT, @cur INT, @country INT, @rt INT, @tpl INT, @s1 INT, @s2 INT, @cp BIGINT, @r BIGINT;
    EXEC #S2;
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @co = v FROM #F WHERE k = 'co';
    SELECT @cur = v FROM #F WHERE k = 'cur';
    SET @country = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA');
    ALTER TABLE wfl.WorkflowStage NOCHECK CONSTRAINT FK_WorkflowStage_ExternalPhaseId;
    ALTER TABLE wfl.Request NOCHECK CONSTRAINT FK_Request_ExternalPhaseId;
    ALTER TABLE lc.LcTermsDocument NOCHECK CONSTRAINT FK_LcTermsDocument_ClauseId;
    ALTER TABLE lc.ProformaInvoice NOCHECK CONSTRAINT FK_ProformaInvoice_ProceedsAccountId;
    ALTER TABLE lc.ProformaInvoice NOCHECK CONSTRAINT FK_ProformaInvoice_DocumentId;
    ALTER TABLE lc.LcTerms NOCHECK CONSTRAINT FK_LcTerms_EncKeyId;
    ALTER TABLE lc.LcTerms NOCHECK CONSTRAINT FK_LcTerms_HashKeyId;
    ALTER TABLE lc.LcAmendment NOCHECK CONSTRAINT FK_LcAmendment_LcId;
    INSERT wfl.RequestType (TenantId, Code, NameAr, NameEn, Category, NumberSequenceKey)
    VALUES (@t1, 'PURCHASE_LC', N'Purchase LC', N'Purchase LC', 'PURCHASE', 'req:PURCHASE_LC');
    SET @rt = SCOPE_IDENTITY();
    INSERT wfl.WorkflowTemplate (TenantId, RequestTypeId, TemplateKey, VersionNo, NameEn) VALUES (@t1, @rt, 'PURCHASE_LC', 1, N'Purchase LC');
    SET @tpl = SCOPE_IDENTITY();
    INSERT wfl.WorkflowStage (TenantId, TemplateId, StageKey, NameAr, NameEn, Kind, SeqNo, ExternalPhaseId)
    VALUES (@t1, @tpl, 'DRAFT', N'Draft', N'Draft', 'DRAFT', 1, 1);
    SET @s1 = SCOPE_IDENTITY();
    INSERT wfl.WorkflowStage (TenantId, TemplateId, StageKey, NameAr, NameEn, Kind, SeqNo, ExternalPhaseId, AssigneeRule)
    VALUES (@t1, @tpl, 'PREPARE', N'Prepare', N'Prepare', 'TASK', 2, 1, 'REQUESTER');
    SET @s2 = SCOPE_IDENTITY();
    INSERT wfl.TemplateField (TenantId, TemplateId, FieldKey, LabelAr, LabelEn, DataType, IndexRole)
    VALUES (@t1, @tpl, 'amount', N'Amount', N'Amount', 'AMOUNT', 'AMOUNT');
    UPDATE wfl.WorkflowTemplate SET Status = 'PUBLISHED', IsCurrent = 1, PublishedAt = SYSUTCDATETIME(), PublishedBy = @u1 WHERE WorkflowTemplateId = @tpl;
    INSERT lc.Counterparty (TenantId, Code, Kind, NameEn, NameNormalized, CountryId) VALUES (@t1, 'CP1', 'BOTH', N'Supplier', N'supplier', @country);
    SET @cp = SCOPE_IDENTITY();
    INSERT wfl.Request (TenantId, DraftRef, RequestTypeId, TemplateId, CompanyId, RequesterUserId, CreatedByUserId, ExternalPhaseId, Amount, CurrencyId)
    VALUES (@t1, 'D-000001', @rt, @tpl, @co, @u1, @u1, 1, 100000, @cur);
    SET @r = SCOPE_IDENTITY();
    INSERT #F (k, v) VALUES ('rt', @rt), ('tpl', @tpl), ('s1', @s1), ('s2', @s2), ('cp', @cp), ('r', @r);
END;
GO
-- Runs cases @From to @To of a case procedure, each in its own transaction on a new fixture, and returns case:error.
CREATE PROCEDURE #Cases @Fixture SYSNAME, @CaseProc SYSNAME, @From INT, @To INT, @Result NVARCHAR(800) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (CaseNo INT PRIMARY KEY, Err INT NOT NULL);
    DECLARE @i INT = @From, @e INT;
    WHILE @i <= @To
    BEGIN
        BEGIN TRANSACTION;
        BEGIN TRY EXEC @Fixture; EXEC @CaseProc @i; SET @e = 0; END TRY
        BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
        WHILE @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        INSERT @r (CaseNo, Err) VALUES (@i, @e);
        SET @i += 1;
    END;
    SET @Result = (SELECT STRING_AGG(CONCAT(CaseNo, ':', Err), ' ') WITHIN GROUP (ORDER BY CaseNo) FROM @r);
END;
GO
/* RF30 cases (DR-41, S3): terms written as a draft with a clause and a charge, then locked. */
CREATE PROCEDURE #LcCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t1 INT, @u1 BIGINT, @co BIGINT, @cur INT, @cp BIGINT, @r BIGINT, @lt BIGINT;
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @co = v FROM #F WHERE k = 'co';
    SELECT @cur = v FROM #F WHERE k = 'cur'; SELECT @cp = v FROM #F WHERE k = 'cp'; SELECT @r = v FROM #F WHERE k = 'r';
    IF @Case = 8
    BEGIN
        INSERT lc.LcTerms (TenantId, OwnerType, OwnerId, Purpose, LcClass, Scope, Status, SnapshotHash, LockedAt, LockedBy, LcType, CurrencyId, Amount,
                           ExpiryRule, ExpiryDate, AmountInWordsAr, AmountInWordsEn, ApplicantCompanyId, BeneficiaryCounterpartyId)
        VALUES (@t1, 'REQUEST', @r, 'APPLICATION', 'PURCHASE', 'DOMESTIC', 'LOCKED', 0x01, SYSUTCDATETIME(), @u1, 'SIGHT', @cur, 100000,
                'ABSOLUTE', '2027-01-31', N'x', N'x', @co, @cp);
        RETURN;
    END;
    INSERT lc.LcTerms (TenantId, OwnerType, OwnerId, Purpose, LcClass, Scope) VALUES (@t1, 'REQUEST', @r, 'APPLICATION', 'PURCHASE', 'DOMESTIC');
    SET @lt = SCOPE_IDENTITY();
    INSERT lc.LcTermsDocument (TenantId, LcTermsId, SeqNo, ClauseId, ClauseVersion, Originals, Copies) VALUES (@t1, @lt, 1, 1, 1, 3, 1);
    INSERT lc.LcChargesMatrix (TenantId, LcTermsId, ChargeCategory, Payer) VALUES (@t1, @lt, 'ISSUING_BANK_LOCAL', 'APPLICANT');
    UPDATE lc.LcTerms SET Status = 'LOCKED', SnapshotHash = 0x01, LockedAt = SYSUTCDATETIME(), LockedBy = @u1, LcType = 'SIGHT', CurrencyId = @cur,
                          Amount = 100000, ExpiryRule = 'ABSOLUTE', ExpiryDate = '2027-01-31', AmountInWordsAr = N'x', AmountInWordsEn = N'x',
                          ApplicantCompanyId = @co, BeneficiaryCounterpartyId = @cp
    WHERE LcTermsId = @lt;
    IF @Case IN (1, 6)
    BEGIN
        UPDATE lc.LcTerms SET MarginPct = 20, DebitAuthorization = 'CHARGES_AND_MARGIN', BankSpecificClauses = N'Bank clause' WHERE LcTermsId = @lt;
        UPDATE lc.LcTerms SET TreasuryHash = 0x02 WHERE LcTermsId = @lt;
    END;
    IF @Case = 2 UPDATE lc.LcTerms SET Amount = 120000 WHERE LcTermsId = @lt;
    IF @Case = 3 UPDATE lc.LcTerms SET Status = 'DRAFT' WHERE LcTermsId = @lt;
    IF @Case = 4 INSERT lc.LcTermsDocument (TenantId, LcTermsId, SeqNo, ClauseId, ClauseVersion) VALUES (@t1, @lt, 2, 1, 1);
    IF @Case = 5 DELETE lc.LcChargesMatrix WHERE LcTermsId = @lt;
    IF @Case = 6 UPDATE lc.LcTerms SET MarginPct = 25 WHERE LcTermsId = @lt;
    IF @Case = 7   -- a locked version without clauses or charges, so that no key stops the deletion first
    BEGIN
        INSERT lc.LcTerms (TenantId, OwnerType, Purpose, LcClass, Scope) VALUES (@t1, 'PROFORMA', 'PROFORMA', 'SALES', 'DOMESTIC');
        SET @lt = SCOPE_IDENTITY();
        UPDATE lc.LcTerms SET Status = 'LOCKED', SnapshotHash = 0x01, LockedAt = SYSUTCDATETIME(), LockedBy = @u1, LcType = 'SIGHT', CurrencyId = @cur,
                              Amount = 100000, ExpiryRule = 'ABSOLUTE', ExpiryDate = '2027-01-31', AmountInWordsAr = N'x', AmountInWordsEn = N'x',
                              ApplicantCounterpartyId = @cp, BeneficiaryCompanyId = @co
        WHERE LcTermsId = @lt;
        DELETE lc.LcTerms WHERE LcTermsId = @lt;
    END;
    IF @Case IN (9, 10) UPDATE lc.LcTerms SET Status = 'SUPERSEDED' WHERE LcTermsId = @lt;
    IF @Case = 10 UPDATE lc.LcTerms SET MarginPct = 30 WHERE LcTermsId = @lt;
END;
GO
/* RF30 (DR-41, S3): terms are written as a draft with their clauses and charges and then locked; a locked version
   changes only in its treasury fields until TreasuryHash, then not at all (50056): not its amount, not back to draft,
   not its clauses or charges, not deleted, not inserted locked; it may become SUPERSEDED, and then nothing changes. */
DECLARE @got NVARCHAR(800);
EXEC #Cases '#S3', '#LcCase', 0, 10, @got OUTPUT;
IF @got = '0:0 1:0 2:50056 3:50056 4:50056 5:50056 6:50056 7:50056 8:50056 9:0 10:50056'
    PRINT 'PASS RF30: locked LC terms change only in their treasury fields until TreasuryHash, and their clauses and charges not at all';
ELSE PRINT CONCAT('FAIL RF30: case:error ', @got, ' (expected 0:0 1:0 2-8:50056 9:0 10:50056)');
GO
/* RF31 cases (DR-41, DR-49, S3): the fixture's template is published. */
CREATE PROCEDURE #TemplateCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t1 INT, @u1 BIGINT, @rt INT, @tpl INT, @s1 INT, @s2 INT, @rt2 INT, @tpl2 INT;
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @rt = v FROM #F WHERE k = 'rt';
    SELECT @tpl = v FROM #F WHERE k = 'tpl'; SELECT @s1 = v FROM #F WHERE k = 's1'; SELECT @s2 = v FROM #F WHERE k = 's2';
    IF @Case = 1 UPDATE wfl.WorkflowTemplate SET IsCurrent = 0, Status = 'RETIRED', RetiredAt = SYSUTCDATETIME() WHERE WorkflowTemplateId = @tpl;
    IF @Case = 2 UPDATE wfl.WorkflowTemplate SET NameEn = N'Changed' WHERE WorkflowTemplateId = @tpl;
    IF @Case = 3 INSERT wfl.WorkflowStage (TenantId, TemplateId, StageKey, NameAr, NameEn, Kind, SeqNo, ExternalPhaseId, AssigneeRule)
                 VALUES (@t1, @tpl, 'EXTRA', N'Extra', N'Extra', 'TASK', 3, 1, 'REQUESTER');
    IF @Case = 4 UPDATE wfl.TemplateField SET LabelEn = N'Value' WHERE TemplateId = @tpl;
    IF @Case = 5 DELETE wfl.WorkflowStage WHERE WorkflowStageId = @s2;
    IF @Case = 6 INSERT wfl.StageApprover (TenantId, StageId, SlotKey, LabelEn, SubjectRule) VALUES (@t1, @s2, 'TM', N'TM', 'REQUESTER_MANAGER');
    IF @Case = 7 INSERT wfl.WorkflowTemplate (TenantId, RequestTypeId, TemplateKey, VersionNo, NameEn, Status, PublishedAt, PublishedBy)
                 VALUES (@t1, @rt, 'PURCHASE_LC', 2, N'Purchase LC', 'PUBLISHED', SYSUTCDATETIME(), @u1);
    IF @Case = 8
    BEGIN
        INSERT wfl.WorkflowTemplate (TenantId, RequestTypeId, TemplateKey, VersionNo, NameEn) VALUES (@t1, @rt, 'PURCHASE_LC_B', 1, N'Second');
        SET @tpl2 = SCOPE_IDENTITY();
        UPDATE wfl.WorkflowTemplate SET Status = 'PUBLISHED', IsCurrent = 1, PublishedAt = SYSUTCDATETIME(), PublishedBy = @u1 WHERE WorkflowTemplateId = @tpl2;
    END;
    IF @Case = 9
    BEGIN
        INSERT wfl.RequestType (TenantId, Code, NameAr, NameEn, Category, NumberSequenceKey) VALUES (@t1, 'OTHER', N'Other', N'Other', 'GENERAL', 'req:OTHER');
        SET @rt2 = SCOPE_IDENTITY();
        INSERT wfl.WorkflowTemplate (TenantId, RequestTypeId, TemplateKey, VersionNo, NameEn) VALUES (@t1, @rt2, 'PURCHASE_LC', 2, N'Borrowed key');
    END;
    IF @Case = 10
    BEGIN
        INSERT wfl.WorkflowTemplate (TenantId, RequestTypeId, TemplateKey, VersionNo, NameEn) VALUES (@t1, @rt, 'PURCHASE_LC', 2, N'Purchase LC v2');
        SET @tpl2 = SCOPE_IDENTITY();
        INSERT wfl.WorkflowStage (TenantId, TemplateId, StageKey, NameAr, NameEn, Kind, SeqNo, ExternalPhaseId)
        VALUES (@t1, @tpl2, 'DRAFT', N'Draft', N'Draft', 'DRAFT', 1, 1);
        UPDATE wfl.WorkflowTemplate SET IsCurrent = 0, Status = 'RETIRED', RetiredAt = SYSUTCDATETIME() WHERE WorkflowTemplateId = @tpl;
        UPDATE wfl.WorkflowTemplate SET Status = 'PUBLISHED', IsCurrent = 1, PublishedAt = SYSUTCDATETIME(), PublishedBy = @u1 WHERE WorkflowTemplateId = @tpl2;
    END;
END;
GO
/* RF31 (DR-41, DR-49, S3): a published template version only retires (50057): its name, its stages, fields and
   approvers do not change and it is not written published; a second current template for one request type is
   refused (2601), and a template key stays with its request type (50057). A new version is a draft, then published. */
DECLARE @got NVARCHAR(800);
EXEC #Cases '#S3', '#TemplateCase', 0, 10, @got OUTPUT;
IF @got = '0:0 1:0 2:50057 3:50057 4:50057 5:50057 6:50057 7:50057 8:2601 9:50057 10:0'
    PRINT 'PASS RF31: a published template version only retires, its parts do not change, and a request type has one current template';
ELSE PRINT CONCAT('FAIL RF31: case:error ', @got, ' (expected 0:0 1:0 2-7:50057 8:2601 9:50057 10:0)');
GO
/* RF32 cases (DR-44, S3): the fixture's draft request enters its task stage. Failed expectations raise 50990. */
CREATE PROCEDURE #CopyCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t1 INT, @u1 BIGINT, @co BIGINT, @cur INT, @f BIGINT, @l BIGINT, @rt INT, @tpl INT, @s2 INT, @r BIGINT, @r2 BIGINT,
            @i1 BIGINT, @i2 BIGINT, @lr BIGINT, @due DATETIME2(3) = DATEADD(DAY, 2, SYSUTCDATETIME());
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @u1 = v FROM #F WHERE k = 'u1'; SELECT @co = v FROM #F WHERE k = 'co';
    SELECT @cur = v FROM #F WHERE k = 'cur'; SELECT @f = v FROM #F WHERE k = 'f'; SELECT @l = v FROM #F WHERE k = 'l';
    SELECT @rt = v FROM #F WHERE k = 'rt'; SELECT @tpl = v FROM #F WHERE k = 'tpl'; SELECT @s2 = v FROM #F WHERE k = 's2';
    SELECT @r = v FROM #F WHERE k = 'r';
    INSERT wfl.RequestStageInstance (TenantId, RequestId, TemplateId, StageId, Status, EnteredAt, QueuedAt, DueAt, SlaState)
    VALUES (@t1, @r, @tpl, @s2, 'QUEUED', SYSUTCDATETIME(), SYSUTCDATETIME(), @due, 'ON_TRACK');
    SET @i1 = SCOPE_IDENTITY();
    UPDATE wfl.Request SET Status = 'ACTIVE', SubmittedAt = SYSUTCDATETIME(), CurrentStageInstanceId = @i1 WHERE RequestId = @r;
    IF NOT EXISTS (SELECT 1 FROM wfl.Request WHERE RequestId = @r AND CurrentStageId = @s2 AND DueAt = @due AND SlaState = 'ON_TRACK' AND QueueEnteredAt IS NOT NULL)
        THROW 50990, 'the request did not take the copies of its new stage instance', 1;
    IF @Case = 1
    BEGIN
        UPDATE wfl.RequestStageInstance SET Status = 'CLAIMED', AssigneeUserId = @u1, ClaimedAt = SYSUTCDATETIME(), SlaState = 'AT_RISK' WHERE RequestStageInstanceId = @i1;
        IF NOT EXISTS (SELECT 1 FROM wfl.Request WHERE RequestId = @r AND AssigneeUserId = @u1 AND ClaimedAt IS NOT NULL AND SlaState = 'AT_RISK')
            THROW 50990, 'the request did not follow the claim of its stage instance', 1;
        IF EXISTS (SELECT 1 FROM wfl.RequestCopyDrift) THROW 50990, 'drift reported without a difference', 1;
    END;
    IF @Case = 2
    BEGIN
        EXECUTE AS USER = 'tp_test_rfapp';
        UPDATE wfl.Request SET DueAt = DATEADD(DAY, 9, SYSUTCDATETIME()) WHERE RequestId = @r;
        REVERT;
    END;
    IF @Case = 3
    BEGIN
        EXECUTE AS USER = 'tp_test_rfapp';
        UPDATE wfl.Request SET Title = N'Renamed' WHERE RequestId = @r;
        REVERT;
        IF NOT EXISTS (SELECT 1 FROM wfl.Request WHERE RequestId = @r AND Title = N'Renamed' AND DueAt = @due AND CurrentStageId = @s2)
            THROW 50990, 'a plain update by the application lost the copies', 1;
    END;
    IF @Case = 4
    BEGIN
        INSERT wfl.Request (TenantId, DraftRef, RequestTypeId, TemplateId, CompanyId, RequesterUserId, CreatedByUserId, ExternalPhaseId)
        VALUES (@t1, 'D-000002', @rt, @tpl, @co, @u1, @u1, 1);
        SET @r2 = SCOPE_IDENTITY();
        INSERT wfl.RequestStageInstance (TenantId, RequestId, TemplateId, StageId, Status, EnteredAt, QueuedAt)
        VALUES (@t1, @r2, @tpl, @s2, 'QUEUED', SYSUTCDATETIME(), SYSUTCDATETIME());
        SET @i2 = SCOPE_IDENTITY();
        UPDATE wfl.Request SET CurrentStageInstanceId = @i2 WHERE RequestId = @r;
    END;
    IF @Case = 5
    BEGIN
        INSERT fac.LimitReservation (TenantId, FacilityId, LimitId, CompanyId, RequestId, Amount, CurrencyId, IdempotencyKey)
        VALUES (@t1, @f, @l, @co, @r, 50000, @cur, CONCAT('req-', @r));
        SET @lr = SCOPE_IDENTITY();
        IF NOT EXISTS (SELECT 1 FROM wfl.Request WHERE RequestId = @r AND ReservationId = @lr AND ReservedAmount = 50000 AND ReservationState = 'RESERVED')
            THROW 50990, 'the request did not take its reservation', 1;
        UPDATE fac.LimitReservation SET Status = 'RELEASED', ReleasedOn = '2026-10-13', ReleaseReason = 'EXPIRED' WHERE LimitReservationId = @lr;
        IF NOT EXISTS (SELECT 1 FROM wfl.Request WHERE RequestId = @r AND ReservationId = @lr AND ReservationState = 'LOST')
            THROW 50990, 'an expired reservation did not make the request LOST', 1;
        IF EXISTS (SELECT 1 FROM wfl.RequestCopyDrift) THROW 50990, 'drift reported without a difference', 1;
    END;
    IF @Case = 6
    BEGIN
        ALTER TABLE wfl.RequestStageInstance DISABLE TRIGGER TR_RequestStageInstance_Copy;
        UPDATE wfl.RequestStageInstance SET DueAt = DATEADD(DAY, 5, SYSUTCDATETIME()) WHERE RequestStageInstanceId = @i1;
        IF NOT EXISTS (SELECT 1 FROM wfl.RequestCopyDrift WHERE RequestId = @r AND StageDrift = 1 AND ReservationDrift = 0)
            THROW 50990, 'the drift view missed a copy that differs', 1;
    END;
END;
GO
/* RF32 (DR-44, S3): the request's copies follow its stage instance (entry, claim) and its reservation (reserved, then
   LOST when it expires), the application cannot write them (230) and its other updates keep them, the current
   instance belongs to the request (547), and wfl.RequestCopyDrift reports a copy that differs. */
DECLARE @got NVARCHAR(800);
EXEC #Cases '#S3', '#CopyCase', 1, 6, @got OUTPUT;
IF @got = '1:0 2:230 3:0 4:547 5:0 6:0'
    PRINT 'PASS RF32: the request copies its stage instance and reservation through the database only, and a drift is reported';
ELSE PRINT CONCAT('FAIL RF32: case:error ', @got, ' (expected 1:0 2:230 3:0 4:547 5:0 6:0)');
GO
/* RF33 cases (DR-46, S3): field definitions with the IBAN and a second restricted field, two terms versions. */
CREATE PROCEDURE #RestrictedCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t1 INT, @co BIGINT, @cur INT, @r BIGINT, @a BIGINT, @b BIGINT, @c BIGINT, @cmp BIGINT, @am BIGINT, @changed INT;
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @co = v FROM #F WHERE k = 'co'; SELECT @cur = v FROM #F WHERE k = 'cur'; SELECT @r = v FROM #F WHERE k = 'r';
    IF @Case = 1
    BEGIN
        INSERT lc.LcFieldDefinition (TenantId, FieldKey, SectionKey, LabelAr, LabelEn, DataType, ApplicabilityJson)
        VALUES (@t1, 'beneficiaryAccountIban', 'PARTIES', N'IBAN', N'IBAN', 'STRING', N'{}');
        RETURN;
    END;
    INSERT lc.LcFieldDefinition (TenantId, FieldKey, SectionKey, LabelAr, LabelEn, DataType, ApplicabilityJson, Sensitivity)
    VALUES (@t1, 'beneficiaryAccountIban', 'PARTIES', N'IBAN', N'IBAN', 'STRING', N'{}', 'RESTRICTED'),
           (@t1, 'collectionAccount', 'PARTIES', N'Account', N'Account', 'STRING', N'{}', 'RESTRICTED'),
           (@t1, 'amount', 'AMOUNT', N'Amount', N'Amount', 'DECIMAL', N'{}', 'NORMAL');
    INSERT lc.LcTerms (TenantId, OwnerType, OwnerId, Purpose, LcClass, Scope, BeneficiaryAccountIbanEnc, BeneficiaryAccountIbanMask,
                       BeneficiaryAccountIbanHash, EncKeyId, HashKeyId)
    VALUES (@t1, 'PROFORMA', NULL, 'PROFORMA', 'SALES', 'DOMESTIC', CRYPT_GEN_RANDOM(64), N'SA** **** 7519', 0xAA, 1, 1);
    SET @a = SCOPE_IDENTITY();
    INSERT lc.LcTerms (TenantId, OwnerType, OwnerId, Purpose, LcClass, Scope, BeneficiaryAccountIbanEnc, BeneficiaryAccountIbanMask,
                       BeneficiaryAccountIbanHash, EncKeyId, HashKeyId)
    VALUES (@t1, 'PROFORMA', NULL, 'PROFORMA', 'SALES', 'DOMESTIC', CRYPT_GEN_RANDOM(64), N'SA** **** 7519', CASE WHEN @Case = 5 THEN 0xBB ELSE 0xAA END, 1,
            CASE WHEN @Case = 6 THEN 2 ELSE 1 END);
    SET @b = SCOPE_IDENTITY();
    INSERT lc.LcTermsComparison (TenantId, BaselineTermsId, ReceivedTermsId, RunAt) VALUES (@t1, @a, @b, SYSUTCDATETIME());
    SET @cmp = SCOPE_IDENTITY();
    IF @Case = 2
    BEGIN
        INSERT lc.LcTermsComparisonLine (TenantId, ComparisonId, FieldKey, BaselineValue, ReceivedValue, Verdict)
        VALUES (@t1, @cmp, 'amount', N'100000', N'120000', 'MORE_FAVOURABLE'), (@t1, @cmp, 'beneficiaryAccountIban', NULL, NULL, 'REVIEW');
        INSERT lc.LcTerms (TenantId, OwnerType, Purpose, LcClass, Scope, CurrencyId) VALUES (@t1, 'AMENDMENT', 'AMENDMENT', 'PURCHASE', 'DOMESTIC', @cur);
        SET @c = SCOPE_IDENTITY();
        INSERT lc.LcAmendment (TenantId, CompanyId, LcId, Origin, ChangeKinds, TermsId, ChangedFieldsJson, CurrencyId, AmountDelta)
        VALUES (@t1, @co, 1, 'OUR_REQUEST', 'CHANGE_TERMS', @c, N'{"amount":{"old":"100000","new":"120000"},"beneficiaryAccountIban":"CHANGED"}', @cur, 0);
    END;
    IF @Case = 3 INSERT lc.LcTermsComparisonLine (TenantId, ComparisonId, FieldKey, BaselineValue, ReceivedValue, Verdict)
                 VALUES (@t1, @cmp, 'collectionAccount', N'SA** 7519', N'SA** 7520', 'REVIEW');
    IF @Case IN (4, 7, 8)
    BEGIN
        INSERT lc.LcTerms (TenantId, OwnerType, Purpose, LcClass, Scope, CurrencyId) VALUES (@t1, 'AMENDMENT', 'AMENDMENT', 'PURCHASE', 'DOMESTIC', @cur);
        SET @c = SCOPE_IDENTITY();
        INSERT lc.LcAmendment (TenantId, CompanyId, LcId, Origin, ChangeKinds, TermsId, ChangedFieldsJson, CurrencyId, AmountDelta)
        VALUES (@t1, @co, 1, 'OUR_REQUEST', 'CHANGE_TERMS', @c,
                CASE @Case WHEN 4 THEN N'{"beneficiaryAccountIban":{"old":"SA0380000000608010167519","new":"SA0380000000608010167520"}}'
                           WHEN 7 THEN N'{"collectionAccount":"SA0380000000608010167519"}'
                           ELSE N'["amount","beneficiaryAccountIban"]' END, @cur, 0);
    END;
    IF @Case IN (5, 6, 9)
    BEGIN
        SET @changed = (SELECT ISNULL(CAST(Changed AS INT), -1) FROM lc.BeneficiaryIbanChange(@a, @b));
        IF @changed <> CASE @Case WHEN 5 THEN 1 WHEN 6 THEN -1 ELSE 0 END
            THROW 50990, 'the IBAN change from the keyed hash is wrong', 1;
    END;
END;
GO
/* RF33 (DR-46, S3): the IBAN field is always restricted (547); a comparison line on a restricted field holds no
   value and an amendment's changed fields hold only "CHANGED" for it, in an object keyed by field (50058); the
   change of the IBAN is read from the keyed hash: changed, unchanged, or unknown when the keys differ. */
DECLARE @got NVARCHAR(800);
EXEC #Cases '#S3', '#RestrictedCase', 1, 9, @got OUTPUT;
IF @got = '1:547 2:0 3:50058 4:50058 5:0 6:0 7:50058 8:50058 9:0'
    PRINT 'PASS RF33: a restricted LC field is never copied into a comparison or an amendment, and its change is read from the keyed hash';
ELSE PRINT CONCAT('FAIL RF33: case:error ', @got, ' (expected 1:547 2:0 3:50058 4:50058 5:0 6:0 7:50058 8:50058 9:0)');
GO
/* RF34 cases (DR-41, S4): an issued proforma of 3,534,720 + 15% VAT (sample 02), or of 3 x 33.335. */
CREATE PROCEDURE #ProformaCase @Case INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t1 INT, @co BIGINT, @cur INT, @cp BIGINT, @r BIGINT, @lt BIGINT, @p BIGINT,
            @sub DECIMAL(19,4) = 3534720, @vat DECIMAL(19,4) = 530208;
    SELECT @t1 = v FROM #F WHERE k = 't1'; SELECT @co = v FROM #F WHERE k = 'co'; SELECT @cur = v FROM #F WHERE k = 'cur';
    SELECT @cp = v FROM #F WHERE k = 'cp'; SELECT @r = v FROM #F WHERE k = 'r';
    IF @Case = 5 SET @vat = 530000;
    IF @Case = 7 SELECT @sub = 100.01, @vat = 15.00;
    INSERT lc.LcTerms (TenantId, OwnerType, OwnerId, Purpose, LcClass, Scope, CurrencyId) VALUES (@t1, 'REQUEST', @r, 'PROFORMA', 'SALES', 'DOMESTIC', @cur);
    SET @lt = SCOPE_IDENTITY();
    INSERT lc.ProformaInvoice (TenantId, CompanyId, ProformaNo, NumberYear, NumberSeq, RequestId, ErpCompanyCodeSnapshot, CustomerId, CustomerSnapshotJson,
                               IssueDate, CurrencyId, Subtotal, VatRatePct, VatAmount, Total, TermsId, ProceedsAccountId, DocumentId)
    VALUES (@t1, @co, '001-ERP1-26', 2026, 1, @r, 'ERP1', @cp, N'{}', '2026-10-13', @cur, @sub, 15, @vat, @sub + @vat, @lt, 1, 1);
    SET @p = SCOPE_IDENTITY();
    IF @Case = 6
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM lc.ProformaTotalsDrift WHERE ProformaInvoiceId = @p AND Lines = 0)
            THROW 50990, 'a proforma without lines is not reported', 1;
        RETURN;
    END;
    IF @Case = 7
    BEGIN
        INSERT lc.ProformaLine (TenantId, ProformaId, [LineNo], Description, Qty, UnitCode, UnitPrice, LineTotal, CurrencyId)
        VALUES (@t1, @p, 1, N'Cable', 3, 'M', 33.335, 100.01, @cur);
        RETURN;
    END;
    INSERT lc.ProformaLine (TenantId, ProformaId, [LineNo], Description, Qty, UnitCode, UnitPrice, LineTotal, CurrencyId)
    VALUES (@t1, @p, 1, N'Transformers', 3, 'PCS', 1000000, 3000000, @cur),
           (@t1, @p, 2, N'Installation', 2, 'LOT', 267360, CASE WHEN @Case = 3 THEN 534000 WHEN @Case = 4 THEN 534721 ELSE 534720 END, @cur);
    IF @Case = 4 RETURN;
    IF @Case = 2 INSERT lc.ProformaLine (TenantId, ProformaId, [LineNo], Description, Qty, UnitCode, UnitPrice, LineTotal, CurrencyId)
                 VALUES (@t1, @p, 3, N'Late line', 1, 'LOT', 0, 0, @cur);
    IF @Case = 1 AND EXISTS (SELECT 1 FROM lc.ProformaTotalsDrift) THROW 50990, 'drift reported for matching totals', 1;
END;
GO
/* RF34 (DR-41, S4): a proforma's lines are written once, each line total is round(Qty x UnitPrice), the subtotal is
   their sum and the VAT is round(Subtotal x Rate / 100) away from zero (50059); 3 x 33.335 = 100.01 with VAT 15.00 is
   accepted, and a header without lines is reported by lc.ProformaTotalsDrift. */
DECLARE @got NVARCHAR(800);
EXEC #Cases '#S3', '#ProformaCase', 1, 7, @got OUTPUT;
IF @got = '1:0 2:50059 3:50059 4:50059 5:50059 6:0 7:0'
    PRINT 'PASS RF34: a proforma''s lines are written once and its totals follow them (BR-LCE-001)';
ELSE PRINT CONCAT('FAIL RF34: case:error ', @got, ' (expected 1:0 2-5:50059 6:0 7:0)');
GO

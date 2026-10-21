/* ============================================================================
   The key guard (db/static/054_key_guard.sql; the rest of DR-20, ADR 0032) and the audit hash chain with its
   anchors (db/static/055_audit_chain.sql; FR-PLT-025, DOC-S12 section 5.3, ADR 0033).

   Run against a deployed BankFas database (with the platform seed) that holds no real data:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/integrity_tests.sql
   A refusal raised in a trigger or under XACT_ABORT ends the transaction, so each case runs in a transaction of
   its own, on a fixture made again inside it, and is rolled back (#Try). The test users are made first and dropped
   at the end. Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
IF DATABASE_PRINCIPAL_ID(N'tp_test_ijob') IS NULL CREATE USER [tp_test_ijob] WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID(N'tp_test_iapp') IS NULL CREATE USER [tp_test_iapp] WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID(N'tp_test_iread') IS NULL CREATE USER [tp_test_iread] WITHOUT LOGIN;
ALTER ROLE [tp_auth] ADD MEMBER [tp_test_iread];          -- the row filters let tp_auth read every audit row
ALTER ROLE [db_datareader] ADD MEMBER [tp_test_iread];    -- tp_auth itself has no right on aud.AuditLog
ALTER ROLE [tp_jobs] ADD MEMBER [tp_test_ijob];
ALTER ROLE [tp_app] ADD MEMBER [tp_test_iapp];
GO
CREATE TABLE #K (k VARCHAR(20) COLLATE DATABASE_DEFAULT PRIMARY KEY, v BIGINT);
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
/* The fixture: a tenant (#K t), bound as its user u1; two DATA keys, k1 ACTIVE and k2 PENDING; u1's MFA secret
   encrypted with k1; three tenant audit rows. */
CREATE PROCEDURE #Fix
AS
BEGIN
    DECLARE @t INT, @u BIGINT, @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'),
            @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA');
    DELETE FROM #K;
    INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone)
    VALUES ('tst-integrity', N'س', N'Integrity', @plan, @country, 'ACTIVE', 'UTC');
    SET @t = SCOPE_IDENTITY();
    EXEC #Bind @t, 0;
    INSERT sec.TenantKey (TenantId, Purpose, KeyVersion, Status, WrappedKey, MasterKeyRef, ActivatedAt)
    VALUES (@t, 'DATA', 1, 'ACTIVE', CRYPT_GEN_RANDOM(64), 'kms/test/data', SYSUTCDATETIME()),
           (@t, 'DATA', 2, 'PENDING', CRYPT_GEN_RANDOM(64), 'kms/test/data', NULL);
    INSERT #K SELECT 't', @t
    UNION ALL SELECT 'k1', TenantKeyId FROM sec.TenantKey WHERE TenantId = @t AND KeyVersion = 1
    UNION ALL SELECT 'k2', TenantKeyId FROM sec.TenantKey WHERE TenantId = @t AND KeyVersion = 2;
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, MfaSecretEnc, MfaKeyId)
    VALUES (@t, N'u1@integrity.invalid', N'U1', 'INVITED', CRYPT_GEN_RANDOM(48), (SELECT v FROM #K WHERE k = 'k1'));
    SET @u = SCOPE_IDENTITY();
    INSERT #K VALUES ('u1', @u);
    EXEC #Bind @t, @u;
    EXEC aud.usp_WriteEvent @TenantId = @t, @Action = 'TEST_ONE', @Category = 'SYSTEM', @ActorType = 'USER', @ActorUserId = @u;
    EXEC aud.usp_WriteEvent @TenantId = @t, @Action = 'TEST_TWO', @Category = 'SYSTEM', @ActorType = 'USER', @ActorUserId = @u,
         @AfterJson = N'{"n":2}';
    EXEC aud.usp_WriteEvent @TenantId = @t, @Action = 'TEST_THREE', @Category = 'SYSTEM', @ActorType = 'USER', @ActorUserId = @u;
END;
GO
-- One case: the fixture, then @sql, in a transaction that is rolled back. @err is 0 or the error number.
CREATE PROCEDURE #Try @sql NVARCHAR(MAX), @err INT OUTPUT, @out NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SELECT @err = NULL, @out = NULL;
    BEGIN TRANSACTION;
    EXEC #Fix;
    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@out NVARCHAR(1000) OUTPUT', @out OUTPUT;
        SET @err = 0;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER();
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
END;
GO
-- A job run of the chain procedures, as tp_jobs.
CREATE PROCEDURE #Verify @ChainKey INT, @AnchorSeq BIGINT = NULL, @AnchorHash VARBINARY(32) = NULL,
                         @Status VARCHAR(20) OUTPUT, @BadSeq BIGINT OUTPUT, @FromAnchor BIT = 0, @Rows BIGINT = NULL OUTPUT
AS
BEGIN
    EXECUTE AS USER = N'tp_test_ijob';
    EXEC aud.usp_VerifyAuditChain @JobKey = 'JOB-PLT-AUDIT-CHAIN', @ChainKey = @ChainKey, @AnchorSeq = @AnchorSeq,
         @AnchorHash = @AnchorHash, @Status = @Status OUTPUT, @BadSeq = @BadSeq OUTPUT, @Rows = @Rows OUTPUT, @FromAnchor = @FromAnchor;
    REVERT;
END;
GO
-- Rewrites the hashes of a chain from @FromSeq on, and its head, as an administrator of the database could.
CREATE PROCEDURE #Rehash @ChainKey INT, @FromSeq BIGINT
AS
BEGIN
    DECLARE @seq BIGINT = @FromSeq, @prev VARBINARY(32), @hash VARBINARY(32), @id BIGINT;
    SET @prev = (SELECT RowHash FROM aud.AuditLog WHERE ISNULL(TenantId, 0) = @ChainKey AND ChainSeq = @FromSeq - 1);
    WHILE 1 = 1
    BEGIN
        SET @id = (SELECT AuditLogId FROM aud.AuditLog WHERE ISNULL(TenantId, 0) = @ChainKey AND ChainSeq = @seq);
        IF @id IS NULL BREAK;
        SELECT @hash = h.RowHash FROM aud.fn_AuditCanonical(@id) AS a CROSS APPLY aud.fn_AuditRowHash(@prev, @seq, a.Canonical) AS h;
        UPDATE aud.AuditLog SET PrevHash = @prev, RowHash = @hash WHERE AuditLogId = @id;
        SELECT @prev = @hash, @seq += 1;
    END;
    UPDATE aud.AuditChainHead SET LastSeq = @seq - 1, LastHash = @prev WHERE ChainKey = @ChainKey;
END;
GO

DECLARE @e INT, @e2 INT, @e3 INT, @o NVARCHAR(1000), @o2 NVARCHAR(1000), @n INT;

/* KG1: a new row names an ACTIVE key only: a user on the PENDING key is refused, on the ACTIVE key accepted. */
EXEC #Try N'INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, MfaSecretEnc, MfaKeyId)
            VALUES ((SELECT v FROM #K WHERE k = ''t''), N''u2@integrity.invalid'', N''U2'', ''INVITED'', CRYPT_GEN_RANDOM(48), (SELECT v FROM #K WHERE k = ''k2''));',
          @e OUTPUT;
EXEC #Try N'INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, MfaSecretEnc, MfaKeyId)
            VALUES ((SELECT v FROM #K WHERE k = ''t''), N''u2@integrity.invalid'', N''U2'', ''INVITED'', CRYPT_GEN_RANDOM(48), (SELECT v FROM #K WHERE k = ''k1''));',
          @e2 OUTPUT;
IF @e = 50098 AND @e2 = 0 PRINT 'PASS KG1: a new row is written with an ACTIVE key only (a PENDING key is refused, 50098)';
ELSE PRINT CONCAT('FAIL KG1: pending key ', @e, ', active key ', @e2);

/* KG2: a row moved onto a key that is not ACTIVE is refused; a row that keeps a RETIRING key can still change. */
EXEC #Try N'UPDATE sec.AppUser SET MfaKeyId = (SELECT v FROM #K WHERE k = ''k2'') WHERE AppUserId = (SELECT v FROM #K WHERE k = ''u1'');', @e OUTPUT;
EXEC #Try N'UPDATE sec.TenantKey SET Status = ''RETIRING'' WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');
            UPDATE sec.TenantKey SET Status = ''ACTIVE'', ActivatedAt = SYSUTCDATETIME() WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k2'');
            UPDATE sec.AppUser SET DisplayNameEn = N''U1 renamed'' WHERE AppUserId = (SELECT v FROM #K WHERE k = ''u1'');', @e2 OUTPUT;
EXEC #Try N'UPDATE sec.TenantKey SET Status = ''RETIRING'' WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');
            UPDATE sec.AppUser SET MfaKeyId = (SELECT v FROM #K WHERE k = ''k1''), MfaSecretEnc = CRYPT_GEN_RANDOM(48)
            WHERE AppUserId = (SELECT v FROM #K WHERE k = ''u1'');', @e3 OUTPUT;
IF @e = 50098 AND @e2 = 0 AND @e3 = 0
    PRINT 'PASS KG2: a row cannot move onto a key that is not ACTIVE; a row on a RETIRING key keeps it and can still change';
ELSE PRINT CONCAT('FAIL KG2: moved to pending ', @e, ', rename on retiring ', @e2, ', rewrite keeping retiring ', @e3);

/* KG3: a key retires only when no row references it: refused while the user is on it; after the rotation moves the
   user to the new key, it retires, and sec.v_KeyReferences shows the user on the new key only. */
EXEC #Try N'UPDATE sec.TenantKey SET Status = ''RETIRING'' WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');
            UPDATE sec.TenantKey SET Status = ''RETIRED'', RetiredAt = SYSUTCDATETIME() WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');', @e OUTPUT;
EXEC #Try N'UPDATE sec.TenantKey SET Status = ''RETIRING'' WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');
            UPDATE sec.TenantKey SET Status = ''ACTIVE'', ActivatedAt = SYSUTCDATETIME() WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k2'');
            UPDATE sec.AppUser SET MfaKeyId = (SELECT v FROM #K WHERE k = ''k2''), MfaSecretEnc = CRYPT_GEN_RANDOM(48)
            WHERE AppUserId = (SELECT v FROM #K WHERE k = ''u1'');
            UPDATE sec.TenantKey SET Status = ''RETIRED'', RetiredAt = SYSUTCDATETIME() WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');
            SET @out = (SELECT STRING_AGG(CONCAT(KeyVersion, '':'', Status, '':'', TableName, ''.'', KeyColumn, ''='', RowCnt), '','')
                        FROM sec.v_KeyReferences WHERE TenantId = (SELECT v FROM #K WHERE k = ''t''));', @e2 OUTPUT, @o OUTPUT;
IF @e = 50098 AND @e2 = 0 AND @o = '2:ACTIVE:sec.AppUser.MfaKeyId=1'
    PRINT 'PASS KG3: a key retires only when no row is left on it, and sec.v_KeyReferences lists where rows still are';
ELSE PRINT CONCAT('FAIL KG3: retire while used ', @e, ', rotation ', @e2, ', references ', @o);

/* KG4: the status moves only forward: PENDING to RETIRING, and RETIRED or REVOKED back to ACTIVE, are refused. */
EXEC #Try N'UPDATE sec.TenantKey SET Status = ''RETIRING'', ActivatedAt = SYSUTCDATETIME() WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k2'');', @e OUTPUT;
EXEC #Try N'UPDATE sec.TenantKey SET Status = ''REVOKED'' WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');
            UPDATE sec.TenantKey SET Status = ''ACTIVE'' WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');', @e2 OUTPUT;
EXEC #Try N'UPDATE sec.AppUser SET MfaSecretEnc = NULL, MfaKeyId = NULL WHERE AppUserId = (SELECT v FROM #K WHERE k = ''u1'');
            UPDATE sec.TenantKey SET Status = ''RETIRING'' WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');
            UPDATE sec.TenantKey SET Status = ''RETIRED'', RetiredAt = SYSUTCDATETIME() WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');
            UPDATE sec.TenantKey SET Status = ''ACTIVE'' WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');', @e3 OUTPUT;
IF @e = 50098 AND @e2 = 50098 AND @e3 = 50098
    PRINT 'PASS KG4: a key''s status moves only forward; RETIRED and REVOKED are final (50098)';
ELSE PRINT CONCAT('FAIL KG4: pending to retiring ', @e, ', revoked to active ', @e2, ', retired to active ', @e3);

/* KG5: revocation is never held back: an ACTIVE key with a row on it is revoked, the row is listed as on a
   REVOKED key, and no row can be written onto it. */
EXEC #Try N'UPDATE sec.TenantKey SET Status = ''REVOKED'' WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');
            SET @out = (SELECT STRING_AGG(CONCAT(KeyVersion, '':'', Status, ''='', RowCnt), '','')
                        FROM sec.v_KeyReferences WHERE TenantId = (SELECT v FROM #K WHERE k = ''t''));', @e OUTPUT, @o OUTPUT;
EXEC #Try N'UPDATE sec.TenantKey SET Status = ''REVOKED'' WHERE TenantKeyId = (SELECT v FROM #K WHERE k = ''k1'');
            INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, MfaSecretEnc, MfaKeyId)
            VALUES ((SELECT v FROM #K WHERE k = ''t''), N''u3@integrity.invalid'', N''U3'', ''INVITED'', CRYPT_GEN_RANDOM(48), (SELECT v FROM #K WHERE k = ''k1''));', @e2 OUTPUT;
IF @e = 0 AND @o = '1:REVOKED=1' AND @e2 = 50098
    PRINT 'PASS KG5: a key in use can be revoked at once; its rows are listed for the rotation job, and no new row goes onto it';
ELSE PRINT CONCAT('FAIL KG5: revoke ', @e, ' (', @o, '), new row on revoked ', @e2);

/* KG6: every key column of the model is guarded: one trigger per table that references sec.TenantKey (but the key
   log), each naming all its key columns. */
SELECT @n = COUNT(*) FROM sys.foreign_keys AS fk
WHERE fk.referenced_object_id = OBJECT_ID(N'sec.TenantKey') AND fk.parent_object_id <> OBJECT_ID(N'sec.KeyEvent');
SELECT @e = COUNT(*)
FROM sys.foreign_keys AS fk
JOIN sys.foreign_key_columns AS fc ON fc.constraint_object_id = fk.object_id
JOIN sys.columns AS rc ON rc.object_id = fk.referenced_object_id AND rc.column_id = fc.referenced_column_id AND rc.name = N'TenantKeyId'
JOIN sys.columns AS c ON c.object_id = fk.parent_object_id AND c.column_id = fc.parent_column_id
JOIN sys.triggers AS tr ON tr.parent_id = fk.parent_object_id AND tr.name = N'TR_' + OBJECT_NAME(fk.parent_object_id) + N'_KeyStatus' AND tr.is_disabled = 0
WHERE fk.referenced_object_id = OBJECT_ID(N'sec.TenantKey') AND fk.parent_object_id <> OBJECT_ID(N'sec.KeyEvent')
  AND CHARINDEX(N'i.' + QUOTENAME(c.name), OBJECT_DEFINITION(tr.object_id)) > 0;
SELECT @e2 = COUNT(*) FROM sys.triggers WHERE name LIKE N'TR[_]%[_]KeyStatus' AND parent_class = 1;
IF @n = 9 AND @e = 9 AND @e2 = 6
    PRINT 'PASS KG6: the 9 key columns of the 6 tables that reference sec.TenantKey are all guarded';
ELSE PRINT CONCAT('FAIL KG6: key columns ', @n, ', guarded ', @e, ', triggers ', @e2);

/* AC1: each row joins its tenant's chain: numbers 1, 2, 3; each links to the one before; each hash computes again;
   the head is the last row; what a writer puts in the chain columns is replaced. */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t'');
    INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, Action, Category, ChainSeq, PrevHash, RowHash)
    VALUES (@t, SYSUTCDATETIME(), ''SYSTEM'', ''TEST_FOUR'', ''SYSTEM'', 999, 0x01, 0x02);
    SET @out = (SELECT CONCAT(COUNT(*), ''/'', MIN(a.ChainSeq), ''-'', MAX(a.ChainSeq), ''/'',
                              SUM(CASE WHEN a.RowHash = h.RowHash THEN 1 ELSE 0 END), ''/'',
                              SUM(CASE WHEN (a.ChainSeq = 1 AND a.PrevHash IS NULL) OR a.PrevHash = p.RowHash THEN 1 ELSE 0 END), ''/'',
                              (SELECT CONCAT(LastSeq, CASE WHEN LastHash = (SELECT RowHash FROM aud.AuditLog WHERE TenantId = @t AND ChainSeq = 4) THEN ''=last'' END)
                               FROM aud.AuditChainHead WHERE ChainKey = @t))
                FROM aud.AuditLog AS a
                CROSS APPLY aud.fn_AuditCanonical(a.AuditLogId) AS c
                CROSS APPLY aud.fn_AuditRowHash(a.PrevHash, a.ChainSeq, c.Canonical) AS h
                LEFT JOIN aud.AuditLog AS p ON p.TenantId = a.TenantId AND p.ChainSeq = a.ChainSeq - 1
                WHERE a.TenantId = @t);', @e OUTPUT, @o OUTPUT;
IF @e = 0 AND @o = '4/1-4/4/4/4=last'
    PRINT 'PASS AC1: audit rows form the tenant''s chain: numbered from 1 without a gap, linked, hashed, the head on the last row; a writer''s own chain values are replaced';
ELSE PRINT CONCAT('FAIL AC1: ', @e, ' ', @o);

/* AC2: the job anchors each chain that moved, once: a second run anchors the platform chain (the first run's own
   audit row moved it) and not the tenant's again; the chain verifies against its anchor. */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t''), @st VARCHAR(20), @bad BIGINT, @h VARBINARY(32);
    DECLARE @a TABLE (ChainKey INT, ChainSeq BIGINT, RowHash CHAR(64), TakenAt CHAR(23));
    DECLARE @b TABLE (ChainKey INT, ChainSeq BIGINT, RowHash CHAR(64), TakenAt CHAR(23));
    EXECUTE AS USER = N''tp_test_ijob'';
    INSERT @a EXEC aud.usp_TakeAuditAnchors @JobKey = ''JOB-PLT-AUDIT-CHAIN'', @StoreRef = N''worm://test/1'';
    INSERT @b EXEC aud.usp_TakeAuditAnchors @JobKey = ''JOB-PLT-AUDIT-CHAIN'', @StoreRef = N''worm://test/2'';
    REVERT;
    SET @h = CONVERT(VARBINARY(32), (SELECT RowHash FROM @a WHERE ChainKey = @t), 2);
    EXEC #Verify @t, 3, @h, @st OUTPUT, @bad OUTPUT;
    SET @out = CONCAT((SELECT ChainSeq FROM @a WHERE ChainKey = @t), ''/'', (SELECT COUNT(*) FROM aud.AuditChainHead WHERE ChainKey = 0), ''/'',
                      (SELECT COUNT(*) FROM @b WHERE ChainKey = @t), ''/'', (SELECT COUNT(*) FROM @b WHERE ChainKey = 0), ''/'', @st, ''/'',
                      (SELECT COUNT(*) FROM aud.AuditChainAnchor WHERE ChainKey = @t AND StoreRef = N''worm://test/1''));', @e OUTPUT, @o OUTPUT;
IF @e = 0 AND @o = '3/1/0/1/OK/1'
    PRINT 'PASS AC2: JOB-PLT-AUDIT-CHAIN anchors each chain that moved, once, and a chain verifies against its anchor';
ELSE PRINT CONCAT('FAIL AC2: ', @e, ' ', @o);

/* AC3: a changed row is found: an administrator changes row 2 (BROKEN at 2); then computes every hash again and the
   head, so the chain alone holds again (OK), but the anchor kept outside no longer matches (ANCHOR_MISMATCH at 3). */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t''), @h VARBINARY(32), @s1 VARCHAR(20), @b1 BIGINT, @s2 VARCHAR(20), @b2 BIGINT,
                    @s3 VARCHAR(20), @b3 BIGINT;
    SET @h = (SELECT RowHash FROM aud.AuditLog WHERE TenantId = @t AND ChainSeq = 3);
    UPDATE aud.AuditLog SET AfterJson = N''{"n":20}'' WHERE TenantId = @t AND ChainSeq = 2;
    EXEC #Verify @t, NULL, NULL, @s1 OUTPUT, @b1 OUTPUT;
    EXEC #Rehash @t, 2;
    EXEC #Verify @t, NULL, NULL, @s2 OUTPUT, @b2 OUTPUT;
    EXEC #Verify @t, 3, @h, @s3 OUTPUT, @b3 OUTPUT;
    EXECUTE AS USER = N''tp_test_iread'';   -- platform rows are read past the audit filter (tp_auth)
    SET @out = CONCAT(@s1, '':'', @b1, ''/'', @s2, ''/'', @s3, '':'', @b3,
                      ''/'', (SELECT COUNT(*) FROM aud.AuditLog WHERE TenantId IS NULL AND Action = ''AUDIT_CHAIN_BROKEN'' AND Severity = ''HIGH''
                                                                AND JSON_VALUE(AfterJson, ''$.chainKey'') = CAST(@t AS VARCHAR(12))));
    REVERT;', @e OUTPUT, @o OUTPUT;
IF @e = 0 AND @o = 'BROKEN:2/OK/ANCHOR_MISMATCH:3/2'
    PRINT 'PASS AC3: a changed audit row breaks the chain, and rewriting every hash is caught by the anchor kept outside (each failure audited HIGH)';
ELSE PRINT CONCAT('FAIL AC3: ', @e, ' ', @o);

/* AC4: removed rows are found: a row taken out of the middle (GAP at 2); the last row taken out (HEAD_MISMATCH),
   and with the head rewritten too, the anchor's row is missing (ANCHOR_MISSING at 3). */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t''), @h VARBINARY(32), @s1 VARCHAR(20), @b1 BIGINT, @s2 VARCHAR(20), @b2 BIGINT,
                    @s3 VARCHAR(20), @b3 BIGINT;
    SET @h = (SELECT RowHash FROM aud.AuditLog WHERE TenantId = @t AND ChainSeq = 3);
    DELETE FROM aud.AuditLog WHERE TenantId = @t AND ChainSeq = 3;
    EXEC #Verify @t, NULL, NULL, @s2 OUTPUT, @b2 OUTPUT;
    EXEC #Rehash @t, 3;
    EXEC #Verify @t, 3, @h, @s3 OUTPUT, @b3 OUTPUT;
    DELETE FROM aud.AuditLog WHERE TenantId = @t AND ChainSeq = 1;
    EXEC #Verify @t, NULL, NULL, @s1 OUTPUT, @b1 OUTPUT;
    SET @out = CONCAT(@s1, '':'', @b1, ''/'', @s2, '':'', @b2, ''/'', @s3, '':'', @b3);', @e OUTPUT, @o OUTPUT;
IF @e = 0 AND @o = 'GAP:2/HEAD_MISMATCH:2/ANCHOR_MISSING:3'
    PRINT 'PASS AC4: removed audit rows are found: a gap in the numbers, a head past the last row, an anchor whose row is gone';
ELSE PRINT CONCAT('FAIL AC4: ', @e, ' ', @o);

/* AC5: a row written with the chain trigger off has no number: the verification reports UNCHAINED, and chaining it
   later is refused (50099), since it would hide the gap in time. */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t''), @s VARCHAR(20), @b BIGINT;
    DISABLE TRIGGER aud.TR_AuditLog_Chain ON aud.AuditLog;
    INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, Action, Category) VALUES (@t, SYSUTCDATETIME(), ''SYSTEM'', ''TEST_HIDDEN'', ''SYSTEM'');
    ENABLE TRIGGER aud.TR_AuditLog_Chain ON aud.AuditLog;
    EXEC #Verify @t, NULL, NULL, @s OUTPUT, @b OUTPUT;
    SET @out = @s;', @e OUTPUT, @o OUTPUT;
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t'');
    DISABLE TRIGGER aud.TR_AuditLog_Chain ON aud.AuditLog;
    INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, Action, Category) VALUES (@t, SYSUTCDATETIME(), ''SYSTEM'', ''TEST_HIDDEN'', ''SYSTEM'');
    ENABLE TRIGGER aud.TR_AuditLog_Chain ON aud.AuditLog;
    EXEC aud.usp_ChainExistingRows;', @e2 OUTPUT;
IF @e = 0 AND @o = 'UNCHAINED' AND @e2 = 50099
    PRINT 'PASS AC5: a row written with the chain trigger off is reported (UNCHAINED) and cannot be chained afterwards (50099)';
ELSE PRINT CONCAT('FAIL AC5: ', @e, ' ', @o, ', chain afterwards ', @e2);

/* AC7: the daily check from the anchor reads the anchor's row and the rows after it only (2 of 3). An old row changed
   without its hash computed again passes it (the limit of the daily check) and fails the full check (BROKEN at 1);
   the same change with every hash computed again is caught from the anchor (ANCHOR_MISMATCH at 2). */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t''), @h VARBINARY(32), @s1 VARCHAR(20), @b1 BIGINT, @n1 BIGINT, @s2 VARCHAR(20), @b2 BIGINT,
                    @s3 VARCHAR(20), @b3 BIGINT, @s4 VARCHAR(20), @b4 BIGINT;
    SET @h = (SELECT RowHash FROM aud.AuditLog WHERE TenantId = @t AND ChainSeq = 2);
    EXEC #Verify @t, 2, @h, @s1 OUTPUT, @b1 OUTPUT, 1, @n1 OUTPUT;
    UPDATE aud.AuditLog SET AfterJson = N''{"n":1}'' WHERE TenantId = @t AND ChainSeq = 1;
    EXEC #Verify @t, 2, @h, @s2 OUTPUT, @b2 OUTPUT, 1;
    EXEC #Verify @t, 2, @h, @s3 OUTPUT, @b3 OUTPUT;
    EXEC #Rehash @t, 1;
    EXEC #Verify @t, 2, @h, @s4 OUTPUT, @b4 OUTPUT, 1;
    SET @out = CONCAT(@s1, '':'', @n1, ''/'', @s2, ''/'', @s3, '':'', @b3, ''/'', @s4, '':'', @b4);', @e OUTPUT, @o OUTPUT;
IF @e = 0 AND @o = 'OK:2/OK/BROKEN:1/ANCHOR_MISMATCH:2'
    PRINT 'PASS AC7: the daily check from the anchor reads only the new rows, still catches a rewrite with every hash again, and leaves old rows to the full check';
ELSE PRINT CONCAT('FAIL AC7: ', @e, ' ', @o);

/* AC6: only the job runs the chain procedures, with its own key: the tenant application has no right (229), and
   another job key is refused (50099). Nobody but the trigger and procedures writes the head or the anchors. */
EXEC #Try N'EXECUTE AS USER = N''tp_test_iapp''; BEGIN TRY EXEC aud.usp_TakeAuditAnchors @JobKey = ''JOB-PLT-AUDIT-CHAIN''; END TRY BEGIN CATCH REVERT; THROW; END CATCH; REVERT;', @e OUTPUT;
EXEC #Try N'EXEC aud.usp_TakeAuditAnchors @JobKey = ''JOB-PLT-ARCHIVE'';', @e2 OUTPUT;
SELECT @e3 = COUNT(*) FROM sys.database_permissions
WHERE major_id IN (OBJECT_ID(N'aud.AuditChainHead'), OBJECT_ID(N'aud.AuditChainAnchor'), OBJECT_ID(N'plat.SchemaMigration')) AND state IN ('G', 'W');
IF @e = 229 AND @e2 = 50099 AND @e3 = 0
    PRINT 'PASS AC6: only JOB-PLT-AUDIT-CHAIN runs the chain procedures; no role is granted the chain head, the anchors or the migration journal';
ELSE PRINT CONCAT('FAIL AC6: application ', @e, ', other job ', @e2, ', grants ', @e3);
GO
ALTER ROLE [tp_jobs] DROP MEMBER [tp_test_ijob];
ALTER ROLE [tp_app] DROP MEMBER [tp_test_iapp];
ALTER ROLE [tp_auth] DROP MEMBER [tp_test_iread];
ALTER ROLE [db_datareader] DROP MEMBER [tp_test_iread];
DROP USER [tp_test_iread];
DROP USER [tp_test_ijob];
DROP USER [tp_test_iapp];
GO

/* 055_audit_chain.sql — the hash chain of the audit log and its anchors outside the database (FR-PLT-025,
   BR-PLT-009, DOC-S12 section 5.3, ADR 0033; DR-41 with O-13).

   Each row of aud.AuditLog is linked to the one before it in its chain: one chain per tenant, and one for the
   platform events (TenantId NULL, chain key 0).
       RowHash = SHA-256( PrevHash ‖ ChainSeq as 8 bytes, big-endian ‖ the canonical text of the row in UTF-16LE )
   The canonical text is aud.fn_AuditCanonical: the row's columns, but the three chain columns, as one JSON object
   (FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) in the order of the table. The first row of a chain
   has no PrevHash (empty bytes).
     aud.TR_AuditLog_Chain       every inserted row gets its ChainSeq, PrevHash and RowHash in the same transaction,
                                 under a lock on its chain's head (aud.AuditChainHead), so two writers of one tenant
                                 never take the same number. It runs as tp_auth_exec, which the audit filter lets see
                                 every row (rls.fn_AuditRead), whoever wrote it. Audit writes of one tenant wait on each
                                 other until commit: that is the price of a chain.
     aud.usp_ChainExistingRows   chains the rows written before this script, in AuditLogId order, for a chain that has
                                 no head yet. A chain that has a head and unchained rows was written with the trigger
                                 off: that is refused here (50099) and reported by the verification.
     aud.usp_TakeAuditAnchors    the job JOB-PLT-AUDIT-CHAIN: records the head of each chain that moved since its last
                                 anchor (aud.AuditChainAnchor) and returns them. tools/ops/audit_anchor.sh writes them
                                 to a store outside the database that nobody with access to the database can rewrite
                                 (a write-once object store or a WORM volume, DOC-S12 section 5.3). Audited
                                 (AUDIT_CHAIN_ANCHORED).
     aud.usp_VerifyAuditChain    the same job: checks a chain against an anchor read back from that store. Every
                                 row's hash is computed again, each row must link to the one before it, the numbers run
                                 from 1 without a gap, no row of the chain is left without a number, the head matches
                                 the last row, and the row at the anchor's number still has the anchor's hash. The
                                 daily check runs from the anchor (@FromAnchor = 1): the anchor's row and the rows after
                                 it, so its cost follows the day's rows, not the size of the log; a full check (weekly)
                                 reads every row, since only it sees an old row changed without its hash computed
                                 again (the performance run, docs/40: a full check costs about 33 microseconds a row). An
                                 administrator of the database can change rows and compute every hash again, but not
                                 the anchors held outside it: the first anchor after the change no longer matches.
                                 Rows removed after the last anchor are found by the next anchor only, so the job
                                 anchors daily. Audited: AUDIT_CHAIN_VERIFIED, or AUDIT_CHAIN_BROKEN (high severity).
   EXECUTE on the two job procedures: tp_jobs. Errors: 50099. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER FUNCTION aud.fn_AuditCanonical (@AuditLogId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT a.AuditLogId, ISNULL(a.TenantId, 0) AS ChainKey, a.ChainSeq, a.PrevHash, a.RowHash,
           (SELECT a.AuditLogId, a.TenantId, a.OccurredAt, a.ActorType, a.ActorId, a.Action, a.Category, a.Severity,
                   a.EntityType, a.EntityId, a.CompanyId, a.BeforeJson, a.AfterJson, a.CorrelationId, a.IpAddress,
                   a.UserAgent, a.Result, a.CreatedAt, a.CreatedBy
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) AS Canonical
    FROM aud.AuditLog AS a
    WHERE a.AuditLogId = @AuditLogId;
GO
CREATE OR ALTER FUNCTION aud.fn_AuditRowHash (@PrevHash VARBINARY(32), @ChainSeq BIGINT, @Canonical NVARCHAR(MAX))
RETURNS TABLE
AS RETURN
    SELECT CAST(HASHBYTES('SHA2_256', ISNULL(@PrevHash, 0x) + CAST(@ChainSeq AS BINARY(8)) + CAST(@Canonical AS VARBINARY(MAX))) AS VARBINARY(32)) AS RowHash;
GO
-- Links the rows given, in AuditLogId order, to the end of their chains. Internal: no role may execute it.
CREATE OR ALTER PROCEDURE aud.usp_ChainRows
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id BIGINT, @key INT, @seq BIGINT, @prev VARBINARY(32), @hash VARBINARY(32);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT AuditLogId, ChainKey FROM #AuditChainRows ORDER BY AuditLogId;
    OPEN c; FETCH NEXT FROM c INTO @id, @key;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @seq = NULL, @prev = NULL, @hash = NULL;
        SELECT @seq = LastSeq, @prev = LastHash FROM aud.AuditChainHead WITH (UPDLOCK, HOLDLOCK) WHERE ChainKey = @key;
        SET @seq = ISNULL(@seq, 0) + 1;
        SELECT @hash = h.RowHash
        FROM aud.fn_AuditCanonical(@id) AS a CROSS APPLY aud.fn_AuditRowHash(@prev, @seq, a.Canonical) AS h;
        UPDATE aud.AuditLog SET ChainSeq = @seq, PrevHash = @prev, RowHash = @hash WHERE AuditLogId = @id AND ChainSeq IS NULL;
        IF @@ROWCOUNT <> 1 OR @hash IS NULL THROW 50099, 'An audit row could not be linked to its chain', 1;
        IF @seq = 1 INSERT aud.AuditChainHead (ChainKey, LastSeq, LastHash) VALUES (@key, @seq, @hash);
        ELSE UPDATE aud.AuditChainHead SET LastSeq = @seq, LastHash = @hash WHERE ChainKey = @key;
        FETCH NEXT FROM c INTO @id, @key;
    END;
    CLOSE c; DEALLOCATE c;
END;
GO
CREATE OR ALTER TRIGGER aud.TR_AuditLog_Chain ON aud.AuditLog
WITH EXECUTE AS N'tp_auth_exec'
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    CREATE TABLE #AuditChainRows (AuditLogId BIGINT PRIMARY KEY, ChainKey INT NOT NULL);
    INSERT #AuditChainRows (AuditLogId, ChainKey) SELECT AuditLogId, ISNULL(TenantId, 0) FROM inserted;
    -- whatever the writer put in the chain columns is replaced
    UPDATE a SET ChainSeq = NULL, PrevHash = NULL, RowHash = NULL
    FROM aud.AuditLog AS a JOIN #AuditChainRows AS r ON r.AuditLogId = a.AuditLogId
    WHERE a.ChainSeq IS NOT NULL OR a.PrevHash IS NOT NULL OR a.RowHash IS NOT NULL;
    EXEC aud.usp_ChainRows;
END;
GO
CREATE OR ALTER PROCEDURE aud.usp_ChainExistingRows
    @Chained INT = NULL OUTPUT
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    CREATE TABLE #AuditChainRows (AuditLogId BIGINT PRIMARY KEY, ChainKey INT NOT NULL);
    INSERT #AuditChainRows (AuditLogId, ChainKey)
    SELECT a.AuditLogId, ISNULL(a.TenantId, 0) FROM aud.AuditLog AS a WITH (TABLOCKX) WHERE a.ChainSeq IS NULL;
    IF EXISTS (SELECT 1 FROM #AuditChainRows AS r JOIN aud.AuditChainHead AS h ON h.ChainKey = r.ChainKey)
        THROW 50099, 'A chain that has a head has rows without a number: they were written with the chain trigger off; aud.usp_VerifyAuditChain reports them', 1;
    SET @Chained = (SELECT COUNT(*) FROM #AuditChainRows);
    EXEC aud.usp_ChainRows;
    COMMIT;
END;
GO
CREATE OR ALTER PROCEDURE aud.usp_TakeAuditAnchors
    @JobKey   VARCHAR(80),
    @StoreRef NVARCHAR(400) = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @JobKey IS NULL OR @JobKey <> 'JOB-PLT-AUDIT-CHAIN'
       OR NOT EXISTS (SELECT 1 FROM cfg.JobDefinition WHERE JobKey = @JobKey AND Scope = 'PLATFORM' AND IsActive = 1)
        THROW 50099, 'Anchors are taken by the job JOB-PLT-AUDIT-CHAIN', 1;
    DECLARE @new TABLE (ChainKey INT, ChainSeq BIGINT, RowHash VARBINARY(32), TakenAt DATETIME2(3));
    DECLARE @after NVARCHAR(400);
    BEGIN TRANSACTION;
    INSERT aud.AuditChainAnchor (ChainKey, ChainSeq, RowHash, StoreRef)
    OUTPUT inserted.ChainKey, inserted.ChainSeq, inserted.RowHash, inserted.TakenAt INTO @new
    SELECT h.ChainKey, h.LastSeq, h.LastHash, @StoreRef
    FROM aud.AuditChainHead AS h WITH (UPDLOCK, HOLDLOCK)
    WHERE h.LastSeq > ISNULL((SELECT MAX(x.ChainSeq) FROM aud.AuditChainAnchor AS x WHERE x.ChainKey = h.ChainKey), 0);
    SET @after = (SELECT (SELECT COUNT(*) FROM @new) AS anchors, @StoreRef AS storeRef FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'AUDIT_CHAIN_ANCHORED', @Category = 'PLATFORM', @ActorType = 'JOB',
         @EntityType = 'aud.AuditChainAnchor', @AfterJson = @after;
    COMMIT;
    SELECT ChainKey, ChainSeq, CONVERT(CHAR(64), RowHash, 2) AS RowHash, CONVERT(CHAR(23), TakenAt, 126) AS TakenAt
    FROM @new ORDER BY ChainKey;
END;
GO
CREATE OR ALTER PROCEDURE aud.usp_VerifyAuditChain
    @JobKey      VARCHAR(80),
    @ChainKey    INT,                       -- the TenantId, or 0 for the platform events
    @AnchorSeq   BIGINT = NULL,             -- an anchor read back from the store outside the database
    @AnchorHash  VARBINARY(32) = NULL,
    @Status      VARCHAR(20) = NULL OUTPUT, -- OK, BROKEN, GAP, UNCHAINED, HEAD_MISMATCH, ANCHOR_MISMATCH, ANCHOR_MISSING
    @BadSeq      BIGINT = NULL OUTPUT,      -- the first number found wrong
    @Rows        BIGINT = NULL OUTPUT,
    @FromAnchor  BIT = 0                    -- 1: the anchor's row and the rows after it only (the daily check)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @JobKey IS NULL OR @JobKey <> 'JOB-PLT-AUDIT-CHAIN'
       OR NOT EXISTS (SELECT 1 FROM cfg.JobDefinition WHERE JobKey = @JobKey AND Scope = 'PLATFORM' AND IsActive = 1)
        THROW 50099, 'The audit chain is verified by the job JOB-PLT-AUDIT-CHAIN', 1;
    IF @FromAnchor = 1 AND @AnchorSeq IS NULL THROW 50099, 'A check from the anchor needs the anchor', 1;
    IF @ChainKey IS NULL OR @ChainKey < 0 THROW 50099, 'A chain key is a TenantId, or 0 for the platform events', 1;
    IF (@AnchorSeq IS NULL AND @AnchorHash IS NOT NULL) OR (@AnchorSeq IS NOT NULL AND @AnchorHash IS NULL) THROW 50099, 'An anchor is given with its number and its hash', 1;
    SELECT @Status = 'OK', @BadSeq = NULL, @Rows = 0;
    DECLARE @headSeq BIGINT, @headHash VARBINARY(32), @after NVARCHAR(800), @maxSeq BIGINT, @unchained BIGINT,
            @from BIGINT = CASE WHEN @FromAnchor = 1 THEN @AnchorSeq ELSE 1 END, @fromPrev VARBINARY(32), @fromId BIGINT;
    SELECT @headSeq = LastSeq, @headHash = LastHash FROM aud.AuditChainHead WHERE ChainKey = @ChainKey;
    -- from the anchor: the row before it is taken as stored; a rewrite of the rows before the anchor that computes the
    -- hashes again changes the anchor's row, which no longer matches the anchor kept outside
    SELECT @fromPrev = RowHash FROM aud.AuditLog
    WHERE (TenantId = @ChainKey OR (@ChainKey = 0 AND TenantId IS NULL)) AND ChainSeq = @from - 1 OPTION (RECOMPILE);
    SELECT @fromId = AuditLogId FROM aud.AuditLog
    WHERE (TenantId = @ChainKey OR (@ChainKey = 0 AND TenantId IS NULL)) AND ChainSeq = @from OPTION (RECOMPILE);
    SELECT x.ChainSeq, x.RowHash, x.PrevHash, LAG(x.RowHash) OVER (ORDER BY x.ChainSeq) AS PriorHash,
           h.RowHash AS Computed, ROW_NUMBER() OVER (ORDER BY x.ChainSeq) + @from - 1 AS Pos
    INTO #rows
    FROM aud.AuditLog AS a
    CROSS APPLY aud.fn_AuditCanonical(a.AuditLogId) AS x
    CROSS APPLY aud.fn_AuditRowHash(x.PrevHash, x.ChainSeq, x.Canonical) AS h
    -- a filter the index (TenantId, ChainSeq) can seek on; ISNULL(TenantId, 0) = @ChainKey would scan the whole log
    -- (the performance run, docs/40)
    WHERE (a.TenantId = @ChainKey OR (@ChainKey = 0 AND a.TenantId IS NULL)) AND a.ChainSeq >= @from
    OPTION (RECOMPILE);
    SELECT @Rows = COUNT_BIG(*), @maxSeq = MAX(ChainSeq) FROM #rows;
    -- rows without a number: all of the chain's, or those written after the anchor's row
    SELECT @unchained = COUNT_BIG(*) FROM aud.AuditLog
    WHERE (TenantId = @ChainKey OR (@ChainKey = 0 AND TenantId IS NULL)) AND ChainSeq IS NULL
      AND (@FromAnchor = 0 OR AuditLogId > @fromId) OPTION (RECOMPILE);
    -- the first row whose number, link or hash is wrong
    SELECT TOP (1) @BadSeq = ChainSeq,
           @Status = CASE WHEN ChainSeq <> Pos THEN 'GAP' ELSE 'BROKEN' END
    FROM #rows
    WHERE ChainSeq <> Pos
       OR RowHash IS NULL OR RowHash <> Computed
       OR (Pos = @from AND @from = 1 AND PrevHash IS NOT NULL)
       OR (Pos = @from AND @from > 1 AND (PrevHash IS NULL OR PrevHash <> @fromPrev))
       OR (Pos > @from AND (PrevHash IS NULL OR PrevHash <> PriorHash))
    ORDER BY ChainSeq;
    IF @Status = 'OK' AND @unchained > 0 SET @Status = 'UNCHAINED';
    IF @Status = 'OK' AND (ISNULL(@headSeq, 0) <> ISNULL(@maxSeq, 0)
                           OR @headHash <> (SELECT RowHash FROM #rows WHERE ChainSeq = @maxSeq))
        SELECT @Status = 'HEAD_MISMATCH', @BadSeq = @maxSeq;
    IF @Status = 'OK' AND @AnchorSeq IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM #rows WHERE ChainSeq = @AnchorSeq)
            SELECT @Status = 'ANCHOR_MISSING', @BadSeq = @AnchorSeq;
        ELSE IF (SELECT RowHash FROM #rows WHERE ChainSeq = @AnchorSeq) <> @AnchorHash
            SELECT @Status = 'ANCHOR_MISMATCH', @BadSeq = @AnchorSeq;
    END;
    SET @after = (SELECT @ChainKey AS chainKey, CASE WHEN @FromAnchor = 1 THEN 'FROM_ANCHOR' ELSE 'FULL' END AS mode,
                         @Rows AS rowsChecked, @unchained AS unchained, @AnchorSeq AS anchorSeq,
                         @Status AS status, @BadSeq AS badSeq FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    IF @Status = 'OK'
        EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'AUDIT_CHAIN_VERIFIED', @Category = 'PLATFORM', @ActorType = 'JOB',
             @EntityType = 'aud.AuditChainHead', @EntityId = @ChainKey, @AfterJson = @after;
    ELSE
        EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'AUDIT_CHAIN_BROKEN', @Category = 'PLATFORM', @ActorType = 'JOB',
             @Severity = 'HIGH', @Result = 'FAILED', @EntityType = 'aud.AuditChainHead', @EntityId = @ChainKey, @AfterJson = @after;
END;
GO
GRANT EXECUTE ON aud.usp_TakeAuditAnchors TO [tp_jobs];
GRANT EXECUTE ON aud.usp_VerifyAuditChain TO [tp_jobs];
GO
-- The rows written before the chain existed (a database deployed before this script) join their chains now.
EXEC aud.usp_ChainExistingRows;
GO

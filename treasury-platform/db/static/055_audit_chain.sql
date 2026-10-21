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
                                 off: those rows are left as they are and the verification reports them (UNCHAINED);
                                 they do not stop a deployment (internal review v6, A13). It looks for headless chains
                                 through plat.Tenant first, so a run with nothing to chain reads no audit row.
     aud.usp_TakeAuditAnchors    the job JOB-PLT-AUDIT-CHAIN: records the head of each chain that moved past the latest
                                 anchor of the STORE, which the job passes in (@StoreLatest), and returns them;
                                 aud.AuditChainAnchor is the database's own record of them, never the judge of what
                                 moved (internal review v6, D1, D2): a forged row there cannot stop a chain from being
                                 anchored, and an anchor whose file was never written is taken again the next day.
                                 tools/deploy/audit_anchor.sh verifies each chain from its latest store anchor before
                                 it takes new ones, and writes them to a store outside the database that nobody with
                                 access to the database can rewrite (a write-once object store or a WORM volume,
                                 DOC-S12 section 5.3). It reads the heads without holding locks on them, so audit
                                 writes do not wait on it (A3). Audited (AUDIT_CHAIN_ANCHORED).
     aud.usp_VerifyAuditChain    the same job: checks a chain against an anchor read back from that store. Every
                                 row's hash is computed again, each row must link to the one before it, the numbers run
                                 from 1 without a gap, no row of the chain is left without a number, the head matches
                                 the last row, and the row at the anchor's number still has the anchor's hash (and,
                                 with @MoreAnchors, the rows at every other anchor of the store in the range read). It
                                 reads the rows up to the head it read first, then reads the head again: rows that
                                 writers add meanwhile are not a mismatch, rows beyond the new head are (A2). The
                                 daily check runs from the anchor (@FromAnchor = 1): the anchor's row and the rows after
                                 it, so its cost follows the day's rows, not the size of the log; a full check (weekly)
                                 reads every row, since only it sees an old row changed without its hash computed
                                 again (the performance run, docs/40: a full check costs about 40 microseconds a row). An
                                 administrator of the database can change rows and compute every hash again, but not
                                 the anchors held outside it: the first anchor after the change no longer matches.
                                 Rows removed after the last anchor are found by the next anchor only, so the job
                                 anchors daily. Audited: AUDIT_CHAIN_VERIFIED, or AUDIT_CHAIN_BROKEN (high severity).
     aud.usp_ListAuditChains     the same job: each chain's head and the time of its first row, so that a chain never
                                 anchored, or anchored too long ago, fails the check (D2).
   EXECUTE on the three job procedures: tp_jobs. Errors: 50099, 50148 (the store's latest anchors not passed). */
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
    DECLARE @id BIGINT, @key INT, @seq BIGINT, @prev VARBINARY(32), @hash VARBINARY(32), @locked INT;
    -- the heads of every chain the rows go to, locked in ChainKey order: two writers that write rows of the same
    -- chains in another order wait on each other instead of deadlocking (A12)
    SELECT @locked = COUNT(*) FROM aud.AuditChainHead WITH (UPDLOCK, HOLDLOCK)
    WHERE ChainKey IN (SELECT ChainKey FROM #AuditChainRows);
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
    SET @Chained = 0;
    -- the chains without a head that have rows: a seek a tenant, so a run with nothing to chain reads no audit row
    DECLARE @keys TABLE (ChainKey INT PRIMARY KEY);
    INSERT @keys (ChainKey)
    SELECT t.TenantId FROM plat.Tenant AS t
    WHERE NOT EXISTS (SELECT 1 FROM aud.AuditChainHead AS h WHERE h.ChainKey = t.TenantId)
      AND EXISTS (SELECT 1 FROM aud.AuditLog AS a WHERE a.TenantId = t.TenantId);
    IF NOT EXISTS (SELECT 1 FROM aud.AuditChainHead WHERE ChainKey = 0)
       AND EXISTS (SELECT 1 FROM aud.AuditLog WHERE TenantId IS NULL)
        INSERT @keys (ChainKey) VALUES (0);
    IF NOT EXISTS (SELECT 1 FROM @keys) RETURN;
    BEGIN TRANSACTION;
    CREATE TABLE #AuditChainRows (AuditLogId BIGINT PRIMARY KEY, ChainKey INT NOT NULL);
    INSERT #AuditChainRows (AuditLogId, ChainKey)
    SELECT a.AuditLogId, ISNULL(a.TenantId, 0) FROM aud.AuditLog AS a WITH (TABLOCKX)
    WHERE a.ChainSeq IS NULL AND ISNULL(a.TenantId, 0) IN (SELECT ChainKey FROM @keys)
      AND NOT EXISTS (SELECT 1 FROM aud.AuditChainHead AS h WHERE h.ChainKey = ISNULL(a.TenantId, 0));
    SET @Chained = (SELECT COUNT(*) FROM #AuditChainRows);
    EXEC aud.usp_ChainRows;
    COMMIT;
END;
GO
CREATE OR ALTER PROCEDURE aud.usp_TakeAuditAnchors
    @JobKey      VARCHAR(80),
    @StoreRef    NVARCHAR(400) = NULL,
    @StoreLatest NVARCHAR(MAX) = NULL     -- the latest anchor of each chain in the store: [{"k":0,"s":12},...], or []
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @JobKey IS NULL OR @JobKey <> 'JOB-PLT-AUDIT-CHAIN'
       OR NOT EXISTS (SELECT 1 FROM cfg.JobDefinition WHERE JobKey = @JobKey AND Scope = 'PLATFORM' AND IsActive = 1)
        THROW 50099, 'Anchors are taken by the job JOB-PLT-AUDIT-CHAIN', 1;
    IF @StoreLatest IS NULL OR ISJSON(@StoreLatest) = 0
        THROW 50148, 'The job passes the latest anchor of each chain in the store (@StoreLatest, [] for an empty store): what moved is decided by the store, not by the database', 1;
    DECLARE @store TABLE (ChainKey INT PRIMARY KEY, ChainSeq BIGINT NOT NULL);
    INSERT @store (ChainKey, ChainSeq) SELECT k, MAX(s) FROM OPENJSON(@StoreLatest) WITH (k INT '$.k', s BIGINT '$.s') GROUP BY k;
    DECLARE @new TABLE (ChainKey INT, ChainSeq BIGINT, RowHash VARBINARY(32), TakenAt DATETIME2(3));
    DECLARE @after NVARCHAR(400);
    BEGIN TRANSACTION;
    INSERT aud.AuditChainAnchor (ChainKey, ChainSeq, RowHash, StoreRef)
    OUTPUT inserted.ChainKey, inserted.ChainSeq, inserted.RowHash, inserted.TakenAt INTO @new
    SELECT h.ChainKey, h.LastSeq, h.LastHash, @StoreRef
    FROM aud.AuditChainHead AS h
    WHERE h.LastSeq > ISNULL((SELECT x.ChainSeq FROM @store AS x WHERE x.ChainKey = h.ChainKey), 0);
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
    @FromAnchor  BIT = 0,                   -- 1: the anchor's row and the rows after it only (the daily check)
    @MoreAnchors NVARCHAR(MAX) = NULL       -- the store's other anchors of this chain, [{"s":5,"h":"<64 hex>"},...]
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
    IF @MoreAnchors IS NOT NULL AND ISJSON(@MoreAnchors) = 0 THROW 50099, 'The other anchors are a JSON array', 1;
    SELECT @Status = 'OK', @BadSeq = NULL, @Rows = 0;
    DECLARE @headSeq BIGINT, @headHash VARBINARY(32), @after NVARCHAR(800), @maxSeq BIGINT, @unchained BIGINT,
            @from BIGINT = CASE WHEN @FromAnchor = 1 THEN @AnchorSeq ELSE 1 END, @fromPrev VARBINARY(32), @fromId BIGINT;
    -- the head first: the rows are read up to it, so a row written meanwhile is not taken for a mismatch (A2)
    SELECT @headSeq = LastSeq, @headHash = LastHash FROM aud.AuditChainHead WHERE ChainKey = @ChainKey;
    SET @headSeq = ISNULL(@headSeq, 0);
    -- from the anchor: the row before it is taken as stored; a rewrite of the rows before the anchor that computes the
    -- hashes again changes the anchor's row, which no longer matches the anchor kept outside.
    -- Each read comes twice, for a tenant's chain and for the platform's (TenantId NULL): with OPTION (RECOMPILE) the
    -- branch that does not apply drops out and the other seeks on (TenantId, ChainSeq); one statement with an OR, or
    -- ISNULL(TenantId, 0), reads the tenant's whole range (the performance run, docs/40).
    SELECT @fromPrev = RowHash FROM aud.AuditLog WHERE @ChainKey > 0 AND TenantId = @ChainKey AND ChainSeq = @from - 1 OPTION (RECOMPILE);
    SELECT @fromPrev = RowHash FROM aud.AuditLog WHERE @ChainKey = 0 AND TenantId IS NULL AND ChainSeq = @from - 1 OPTION (RECOMPILE);
    SELECT @fromId = AuditLogId FROM aud.AuditLog WHERE @ChainKey > 0 AND TenantId = @ChainKey AND ChainSeq = @from OPTION (RECOMPILE);
    SELECT @fromId = AuditLogId FROM aud.AuditLog WHERE @ChainKey = 0 AND TenantId IS NULL AND ChainSeq = @from OPTION (RECOMPILE);
    CREATE TABLE #rows (ChainSeq BIGINT PRIMARY KEY, RowHash VARBINARY(32), PrevHash VARBINARY(32), PriorHash VARBINARY(32),
                        Computed VARBINARY(32), Pos BIGINT);
    INSERT #rows (ChainSeq, RowHash, PrevHash, PriorHash, Computed, Pos)
    SELECT x.ChainSeq, x.RowHash, x.PrevHash, LAG(x.RowHash) OVER (ORDER BY x.ChainSeq), h.RowHash, ROW_NUMBER() OVER (ORDER BY x.ChainSeq) + @from - 1
    FROM aud.AuditLog AS a
    CROSS APPLY aud.fn_AuditCanonical(a.AuditLogId) AS x
    CROSS APPLY aud.fn_AuditRowHash(x.PrevHash, x.ChainSeq, x.Canonical) AS h
    WHERE @ChainKey > 0 AND a.TenantId = @ChainKey AND a.ChainSeq >= @from AND a.ChainSeq <= @headSeq
    OPTION (RECOMPILE);
    INSERT #rows (ChainSeq, RowHash, PrevHash, PriorHash, Computed, Pos)
    SELECT x.ChainSeq, x.RowHash, x.PrevHash, LAG(x.RowHash) OVER (ORDER BY x.ChainSeq), h.RowHash, ROW_NUMBER() OVER (ORDER BY x.ChainSeq) + @from - 1
    FROM aud.AuditLog AS a
    CROSS APPLY aud.fn_AuditCanonical(a.AuditLogId) AS x
    CROSS APPLY aud.fn_AuditRowHash(x.PrevHash, x.ChainSeq, x.Canonical) AS h
    WHERE @ChainKey = 0 AND a.TenantId IS NULL AND a.ChainSeq >= @from AND a.ChainSeq <= @headSeq
    OPTION (RECOMPILE);
    SELECT @Rows = COUNT_BIG(*), @maxSeq = MAX(ChainSeq) FROM #rows;
    -- rows without a number: all of the chain's, or those written after the anchor's row
    SELECT @unchained = COUNT_BIG(*) FROM aud.AuditLog
    WHERE @ChainKey > 0 AND TenantId = @ChainKey AND ChainSeq IS NULL AND (@FromAnchor = 0 OR AuditLogId > @fromId) OPTION (RECOMPILE);
    SELECT @unchained += COUNT_BIG(*) FROM aud.AuditLog
    WHERE @ChainKey = 0 AND TenantId IS NULL AND ChainSeq IS NULL AND (@FromAnchor = 0 OR AuditLogId > @fromId) OPTION (RECOMPILE);
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
    -- an anchor past the head: the rows it anchored are gone (a removed tail, or a restore to an earlier time)
    IF @Status = 'OK' AND @AnchorSeq > @headSeq SELECT @Status = 'ANCHOR_MISSING', @BadSeq = @AnchorSeq;
    IF @Status = 'OK' AND (@headSeq <> ISNULL(@maxSeq, 0)
                           OR @headHash <> (SELECT RowHash FROM #rows WHERE ChainSeq = @maxSeq))
        SELECT @Status = 'HEAD_MISMATCH', @BadSeq = @maxSeq;
    -- the head again: a row above it was not written through the trigger (A2)
    DECLARE @nowSeq BIGINT = ISNULL((SELECT LastSeq FROM aud.AuditChainHead WHERE ChainKey = @ChainKey), 0), @above BIGINT;
    SELECT @above = MAX(ChainSeq) FROM aud.AuditLog WHERE @ChainKey > 0 AND TenantId = @ChainKey AND ChainSeq > @nowSeq OPTION (RECOMPILE);
    SELECT @above = MAX(ChainSeq) FROM aud.AuditLog WHERE @ChainKey = 0 AND TenantId IS NULL AND ChainSeq > @nowSeq OPTION (RECOMPILE);
    IF @Status = 'OK' AND @above IS NOT NULL SELECT @Status = 'HEAD_MISMATCH', @BadSeq = @above;
    IF @Status = 'OK' AND @AnchorSeq IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM #rows WHERE ChainSeq = @AnchorSeq)
            SELECT @Status = 'ANCHOR_MISSING', @BadSeq = @AnchorSeq;
        ELSE IF (SELECT RowHash FROM #rows WHERE ChainSeq = @AnchorSeq) <> @AnchorHash
            SELECT @Status = 'ANCHOR_MISMATCH', @BadSeq = @AnchorSeq;
    END;
    -- the store's other anchors in the range read (all of them in a full check)
    IF @Status = 'OK' AND @MoreAnchors IS NOT NULL
        SELECT TOP (1) @BadSeq = m.s, @Status = CASE WHEN r.ChainSeq IS NULL THEN 'ANCHOR_MISSING' ELSE 'ANCHOR_MISMATCH' END
        FROM OPENJSON(@MoreAnchors) WITH (s BIGINT '$.s', h CHAR(64) '$.h') AS m
        LEFT JOIN #rows AS r ON r.ChainSeq = m.s
        WHERE m.s >= @from AND (r.ChainSeq IS NULL OR r.RowHash <> CONVERT(VARBINARY(32), m.h, 2) OR m.h IS NULL)
        ORDER BY m.s;
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
-- The chains and their heads, for the job's checks of anchors that are missing or too old (internal review v6, D2).
CREATE OR ALTER PROCEDURE aud.usp_ListAuditChains
    @JobKey VARCHAR(80)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF @JobKey IS NULL OR @JobKey <> 'JOB-PLT-AUDIT-CHAIN'
       OR NOT EXISTS (SELECT 1 FROM cfg.JobDefinition WHERE JobKey = @JobKey AND Scope = 'PLATFORM' AND IsActive = 1)
        THROW 50099, 'The audit chains are listed by the job JOB-PLT-AUDIT-CHAIN', 1;
    SELECT h.ChainKey, h.LastSeq, CONVERT(CHAR(64), h.LastHash, 2) AS LastHash, CONVERT(CHAR(23), f.OccurredAt, 126) AS FirstAt
    FROM aud.AuditChainHead AS h
    OUTER APPLY (SELECT a.OccurredAt FROM aud.AuditLog AS a WHERE h.ChainKey > 0 AND a.TenantId = h.ChainKey AND a.ChainSeq = 1
                 UNION ALL
                 SELECT a.OccurredAt FROM aud.AuditLog AS a WHERE h.ChainKey = 0 AND a.TenantId IS NULL AND a.ChainSeq = 1) AS f
    ORDER BY h.ChainKey;
END;
GO
GRANT EXECUTE ON aud.usp_TakeAuditAnchors TO [tp_jobs];
GRANT EXECUTE ON aud.usp_ListAuditChains TO [tp_jobs];
GRANT EXECUTE ON aud.usp_VerifyAuditChain TO [tp_jobs];
-- tp_readonly (and tp_support, a member) reads the aud schema (020), but the heads and anchors have no row filter: they
-- would show every tenant's key and the volume of its activity (internal review v6, A11, B3).
DENY SELECT ON aud.AuditChainHead TO [tp_readonly];
DENY SELECT ON aud.AuditChainAnchor TO [tp_readonly];
GO
-- The rows written before the chain existed (a database deployed before this script) join their chains now.
EXEC aud.usp_ChainExistingRows;
GO

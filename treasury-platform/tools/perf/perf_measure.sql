/* ============================================================================
   BankFas - the performance measurement of the database's own paths (review v5.0 P0-2; NFR-PERF-01, NFR-PERF-06,
   NFR-SCL-01, NFR-SCL-02; ADR 0036). Run by tools/perf/run_perf.sh after tools/perf/perf_seed.sql, on the measured
   tenant perf-f001 (a full tenant) and, where a path covers every tenant, on all of them.

   Each scenario runs $(Iterations) times unless said otherwise, as a user bound to the tenant the way
   sec.usp_SetSessionContext binds, so the row filters run as they do for the application. A sample is the server-side
   time of one call. The server's clock moves in steps of a few milliseconds, so a fast read (Q1 to Q4, R1, R3) is run
   20 times in a sample and the sample is the mean of the 20. Output: one line per scenario,
       RESULT|<id>|<samples>|<p50 ms>|<p95 ms>|<max ms>
   then the tables' sizes (SIZE|...), the costliest statements of the run (TOP|...) and the indexes the optimiser
   asked for (MISSING|...). What a scenario writes stays: the database is a throwaway one.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
GO
CREATE TABLE #S (Id VARCHAR(12) COLLATE DATABASE_DEFAULT, Us BIGINT);
CREATE TABLE #P (k VARCHAR(20) COLLATE DATABASE_DEFAULT PRIMARY KEY, v BIGINT);
GO
CREATE PROCEDURE #Bind @TenantId INT, @UserId BIGINT, @Kind VARCHAR(7) = 'USER', @JobKey VARCHAR(80) = NULL
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind) VALUES (@@SPID, @TenantId, @UserId, @token, @Kind);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @UserId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
    EXEC sys.sp_set_session_context @key = N'JobKey', @value = @JobKey;
END;
GO
-- the measured tenant and its users
DECLARE @t INT = (SELECT TenantId FROM plat.Tenant WHERE Code = 'perf-f001');
EXEC #Bind @t, 0;
INSERT #P SELECT 't', @t
UNION ALL SELECT 'u1', AppUserId FROM sec.AppUser WHERE TenantId = @t AND Email = N'fa@perf.invalid'
UNION ALL SELECT 'u2', AppUserId FROM sec.AppUser WHERE TenantId = @t AND Email = N'tm@perf.invalid'
UNION ALL SELECT 'u3', AppUserId FROM sec.AppUser WHERE TenantId = @t AND Email = N'rk@perf.invalid'
UNION ALL SELECT 'svc', AppUserId FROM sec.AppUser WHERE TenantId = @t AND IsSystemUser = 1;
DBCC FREEPROCCACHE WITH NO_INFOMSGS;   -- the TOP list below is this run's
GO
/* Q1-Q4: what screens read (NFR-PERF-01): the audit viewer's latest page, all and by category; a page of the company
   list; the statements of a company with their lines. R1, R3: the credit report of an assessment (header and
   findings), and the covenant breach report. R2: the tenant's early warnings (the readiness screen), 10 samples of one
   call. A read of Q and R1, R3 is run @r times in a sample, and the sample is the mean. */
DECLARE @t INT = (SELECT v FROM #P WHERE k = 't'), @u2 BIGINT = (SELECT v FROM #P WHERE k = 'u2'), @i INT = 0, @j INT, @r INT = 20,
        @t0 DATETIME2(7), @x INT, @c BIGINT, @a BIGINT, @n INT = $(Iterations);
EXEC #Bind @t, @u2;
WHILE @i < @n
BEGIN
    SET @c = (SELECT CompanyId FROM org.Company WHERE TenantId = @t AND CompanyCode = CONCAT('C', @i % 200 + 1));
    SET @a = (SELECT CreditAssessmentId FROM fin.CreditAssessment WHERE TenantId = @t ORDER BY CreditAssessmentId OFFSET @i % 200 ROWS FETCH NEXT 1 ROWS ONLY);
    SELECT @j = 0, @t0 = SYSUTCDATETIME();
    WHILE @j < @r BEGIN SELECT @x = COUNT(*) FROM (SELECT TOP (50) AuditLogId FROM aud.AuditLog WHERE TenantId = @t ORDER BY OccurredAt DESC) AS q; SET @j += 1; END;
    INSERT #S VALUES ('Q1', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / @r);
    SELECT @j = 0, @t0 = SYSUTCDATETIME();
    WHILE @j < @r BEGIN SELECT @x = COUNT(*) FROM (SELECT TOP (50) AuditLogId FROM aud.AuditLog WHERE TenantId = @t AND Category = 'TREASURY' ORDER BY OccurredAt DESC) AS q; SET @j += 1; END;
    INSERT #S VALUES ('Q2', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / @r);
    SELECT @j = 0, @t0 = SYSUTCDATETIME();
    WHILE @j < @r BEGIN SELECT @x = COUNT(*) FROM (SELECT CompanyId FROM org.Company WHERE TenantId = @t ORDER BY NameEn OFFSET ((@i + @j) % 4) * 50 ROWS FETCH NEXT 50 ROWS ONLY) AS q; SET @j += 1; END;
    INSERT #S VALUES ('Q3', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / @r);
    SELECT @j = 0, @t0 = SYSUTCDATETIME();
    WHILE @j < @r
    BEGIN
        SELECT @x = COUNT(*) FROM fin.FinancialStatement AS s JOIN fin.StatementLine AS l ON l.TenantId = s.TenantId AND l.StatementId = s.FinancialStatementId
        WHERE s.TenantId = @t AND s.CompanyId = @c;
        SET @j += 1;
    END;
    INSERT #S VALUES ('Q4', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / @r);
    SELECT @j = 0, @t0 = SYSUTCDATETIME();
    WHILE @j < @r
    BEGIN
        SELECT @x = COUNT(*) FROM fin.v_CreditAssessmentReport WHERE TenantId = @t AND CreditAssessmentId = @a;
        SELECT @x = COUNT(*) FROM fin.v_CreditAssessmentFindings WHERE TenantId = @t AND AssessmentId = @a;
        SET @j += 1;
    END;
    INSERT #S VALUES ('R1', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / @r);
    SELECT @j = 0, @t0 = SYSUTCDATETIME();
    WHILE @j < @r BEGIN SELECT @x = COUNT(*) FROM fin.v_StatementBreachReport WHERE TenantId = @t; SET @j += 1; END;
    INSERT #S VALUES ('R3', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / @r);
    IF @i < 10
    BEGIN
        SET @t0 = SYSUTCDATETIME();
        SELECT @x = COUNT(*) FROM fin.fn_CreditEarlyWarnings(CAST(SYSUTCDATETIME() AS DATE)) WHERE TenantId = @t;
        INSERT #S VALUES ('R2', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
    END;
    SET @i += 1;
END;
GO
/* W1: one audit row written by the database (aud.usp_WriteEvent), with its place in the hash chain (055).
   W2: the credit computation of a new draft assessment (fin.usp_ComputeCreditAssessment), 20 times.
   W3: the evidence pack of an endorsed assessment, built by the risk officer, 20 times. */
DECLARE @t INT = (SELECT v FROM #P WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #P WHERE k = 'u1'), @u3 BIGINT = (SELECT v FROM #P WHERE k = 'u3'),
        @i INT = 0, @t0 DATETIME2(7), @a BIGINT, @pack NVARCHAR(MAX), @sha VARBINARY(32), @n INT = $(Iterations);
EXEC #Bind @t, @u1;
WHILE @i < @n
BEGIN
    SET @t0 = SYSUTCDATETIME();
    EXEC aud.usp_WriteEvent @TenantId = @t, @Action = 'PERF_PROBE', @Category = 'SYSTEM', @ActorType = 'USER', @ActorUserId = @u1;
    INSERT #S VALUES ('W1', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
    SET @i += 1;
END;
SET @i = 0;
WHILE @i < 20 AND @i < (SELECT COUNT(*) FROM fin.FinancialStatement WHERE TenantId = @t AND FiscalYear = 2024)
BEGIN
    INSERT fin.CreditAssessment (TenantId, CompanyId, StatementId, ScorecardId, AssessmentDate, PreparedBy)
    SELECT @t, s.CompanyId, s.FinancialStatementId, (SELECT ScorecardId FROM fin.Scorecard WHERE Code = 'GENERAL_CORPORATE' AND Status = 'APPROVED'), '2026-05-31', @u1
    FROM fin.FinancialStatement AS s WHERE s.TenantId = @t AND s.FiscalYear = 2024 ORDER BY s.FinancialStatementId OFFSET @i ROWS FETCH NEXT 1 ROWS ONLY;
    SET @a = SCOPE_IDENTITY();
    SET @t0 = SYSUTCDATETIME();
    EXEC fin.usp_ComputeCreditAssessment @a;
    INSERT #S VALUES ('W2', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
    SET @i += 1;
END;
EXEC #Bind @t, @u3;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CreditAssessmentId FROM fin.CreditAssessment WHERE TenantId = @t AND EndorsedBy IS NOT NULL ORDER BY CreditAssessmentId;
OPEN c; FETCH NEXT FROM c INTO @a;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @t0 = SYSUTCDATETIME();
    EXEC fin.usp_BuildAssessmentEvidencePack @a, N'Performance measurement', @pack OUTPUT, @sha OUTPUT;
    INSERT #S VALUES ('W3', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
    FETCH NEXT FROM c INTO @a;
END;
CLOSE c; DEALLOCATE c;
GO
/* J1: the daily early warning job of the measured tenant (fin.usp_RunEarlyWarnings), three runs: the first issues the
   warnings, the next find them issued.
   J2: the full audit chain verification of the measured tenant (all its rows), three runs.
   J3: the anchors of all 300 chains, then again with one chain moved. */
DECLARE @t INT = (SELECT v FROM #P WHERE k = 't'), @svc BIGINT = (SELECT v FROM #P WHERE k = 'svc'), @i INT = 0, @t0 DATETIME2(7), @issued INT,
        @st VARCHAR(20), @bad BIGINT, @rows BIGINT, @today DATE = CAST(SYSUTCDATETIME() AS DATE);
EXEC #Bind @t, @svc, 'JOB', 'JOB-FIN-READINESS';
WHILE @i < 3
BEGIN
    SET @t0 = SYSUTCDATETIME();
    EXEC fin.usp_RunEarlyWarnings @AsOf = @today, @Issued = @issued OUTPUT;
    INSERT #S VALUES ('J1', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
    IF @i = 0 PRINT CONCAT('INFO|J1|warnings issued on the first run|', @issued);
    SET @i += 1;
END;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
SET @i = 0;
WHILE @i < 3
BEGIN
    SET @t0 = SYSUTCDATETIME();
    EXEC aud.usp_VerifyAuditChain @JobKey = 'JOB-PLT-AUDIT-CHAIN', @ChainKey = @t, @Status = @st OUTPUT, @BadSeq = @bad OUTPUT, @Rows = @rows OUTPUT;
    INSERT #S VALUES ('J2', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
    IF @i = 0 PRINT CONCAT('INFO|J2|chain rows verified, status|', @rows, ' ', @st);
    SET @i += 1;
END;
DECLARE @anchors TABLE (ChainKey INT, ChainSeq BIGINT, RowHash CHAR(64), TakenAt CHAR(23));
SET @t0 = SYSUTCDATETIME();
INSERT @anchors EXEC aud.usp_TakeAuditAnchors @JobKey = 'JOB-PLT-AUDIT-CHAIN', @StoreRef = N'perf';
INSERT #S VALUES ('J3', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
SET @rows = (SELECT COUNT(*) FROM @anchors);
PRINT CONCAT('INFO|J3|chains anchored|', @rows);
SET @t0 = SYSUTCDATETIME();
INSERT @anchors EXEC aud.usp_TakeAuditAnchors @JobKey = 'JOB-PLT-AUDIT-CHAIN', @StoreRef = N'perf';
INSERT #S VALUES ('J3', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
GO
/* J4: the daily chain check from the anchor (055): the tenant's latest anchor, a day of 500 more audit rows, then the
   anchor's row and the rows after it verified, three runs. */
DECLARE @t INT = (SELECT v FROM #P WHERE k = 't'), @u1 BIGINT = (SELECT v FROM #P WHERE k = 'u1'), @i INT = 0, @t0 DATETIME2(7), @seq BIGINT,
        @h VARBINARY(32), @st VARCHAR(20), @bad BIGINT, @rows BIGINT;
-- the tenant's latest anchor (J3 has just taken it; its copy in the database stands for the one kept outside)
SELECT TOP (1) @seq = ChainSeq, @h = RowHash FROM aud.AuditChainAnchor WHERE ChainKey = @t ORDER BY ChainSeq DESC;
IF @seq IS NULL THROW 50990, 'J4 needs an anchor of the measured tenant', 1;
EXEC #Bind @t, @u1;
WHILE @i < 500
BEGIN
    EXEC aud.usp_WriteEvent @TenantId = @t, @Action = 'PERF_DAY', @Category = 'SYSTEM', @ActorType = 'USER', @ActorUserId = @u1;
    SET @i += 1;
END;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
SET @i = 0;
WHILE @i < 3
BEGIN
    SET @t0 = SYSUTCDATETIME();
    EXEC aud.usp_VerifyAuditChain @JobKey = 'JOB-PLT-AUDIT-CHAIN', @ChainKey = @t, @AnchorSeq = @seq, @AnchorHash = @h, @FromAnchor = 1,
         @Status = @st OUTPUT, @BadSeq = @bad OUTPUT, @Rows = @rows OUTPUT;
    INSERT #S VALUES ('J4', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
    IF @i = 0 PRINT CONCAT('INFO|J4|rows verified from the anchor, status|', @rows, ' ', @st);
    SET @i += 1;
END;
GO
/* D1: the schema fingerprint the migration journal records after every step (056). */
DECLARE @i INT = 0, @t0 DATETIME2(7), @f VARBINARY(32);
WHILE @i < 3
BEGIN
    SET @t0 = SYSUTCDATETIME();
    SELECT @f = Fingerprint FROM plat.fn_SchemaFingerprint();
    INSERT #S VALUES ('D1', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));
    SET @i += 1;
END;
GO
SELECT CONCAT('RESULT|', Id, '|', COUNT(*), '|', CAST(MAX(p50) / 1000.0 AS DECIMAL(12,2)), '|', CAST(MAX(p95) / 1000.0 AS DECIMAL(12,2)), '|',
              CAST(MAX(Us) / 1000.0 AS DECIMAL(12,2)))
FROM (SELECT Id, Us, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY Us) OVER (PARTITION BY Id) AS p50,
             PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY Us) OVER (PARTITION BY Id) AS p95 FROM #S) AS x
GROUP BY Id ORDER BY Id;
-- sizes: rows of the largest tables, and the database
SELECT TOP (15) CONCAT('SIZE|', s.name, '.', t.name, '|', SUM(p.rows))
FROM sys.tables AS t JOIN sys.schemas AS s ON s.schema_id = t.schema_id
JOIN sys.partitions AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
GROUP BY s.name, t.name ORDER BY SUM(p.rows) DESC;
SELECT CONCAT('SIZE|database MB|', CAST(SUM(size) * 8 / 1024.0 AS DECIMAL(12,1))) FROM sys.database_files WHERE type = 0;
SELECT CONCAT('SIZE|tenants|', COUNT(*)) FROM plat.Tenant;
-- the costliest statements of this run (by total CPU), and the indexes the optimiser asked for
SELECT TOP (12) CONCAT('TOP|', ISNULL(OBJECT_SCHEMA_NAME(st.objectid, st.dbid) + '.' + OBJECT_NAME(st.objectid, st.dbid), 'batch'), '|', qs.execution_count, '|',
              CAST(qs.total_worker_time / 1000.0 AS DECIMAL(12,1)), '|', qs.total_logical_reads, '|',
              REPLACE(REPLACE(LEFT(LTRIM(SUBSTRING(st.text, qs.statement_start_offset / 2 + 1,
                  (CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2 + 1)), 110), CHAR(13), ' '), CHAR(10), ' '))
FROM sys.dm_exec_query_stats AS qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE st.dbid = DB_ID() OR st.dbid IS NULL
ORDER BY qs.total_worker_time DESC;
SELECT TOP (10) CONCAT('MISSING|', d.statement, '|', ISNULL(d.equality_columns, ''), '|', ISNULL(d.inequality_columns, ''), '|', ISNULL(d.included_columns, ''), '|',
              CAST(s.avg_user_impact AS DECIMAL(5,1)), '|', s.user_seeks + s.user_scans)
FROM sys.dm_db_missing_index_details AS d
JOIN sys.dm_db_missing_index_groups AS g ON g.index_handle = d.index_handle
JOIN sys.dm_db_missing_index_group_stats AS s ON s.group_handle = g.index_group_handle
WHERE d.database_id = DB_ID()
ORDER BY s.avg_user_impact * (s.user_seeks + s.user_scans) DESC;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
GO

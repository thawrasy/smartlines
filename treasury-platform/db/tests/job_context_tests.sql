/* ============================================================================
   Binding background jobs to a tenant (db/static/037_job_context.sql, ADR 0004, DQ-F04-4, DOC-F04 7.4).
   The cases run as the job worker (tp_jobs) and the tenant application (tp_app).

   Run against a deployed BankFas database that holds no real data, with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/job_context_tests.sql
   One transaction with a savepoint per case, rolled back at the end. J4 presets the context, so a call that passes
   every check stops at 50004 instead of binding; J6 is the one real binding and runs last; J7 checks its audit row.
   Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
BEGIN TRANSACTION;
CREATE USER [tp_test_job] WITHOUT LOGIN;
CREATE USER [tp_test_app] WITHOUT LOGIN;
CREATE USER [tp_test_jread] WITHOUT LOGIN;              -- reads every audit row (tp_auth passes the row filters)
ALTER ROLE [tp_auth] ADD MEMBER [tp_test_jread];
ALTER ROLE [db_datareader] ADD MEMBER [tp_test_jread];
ALTER ROLE [tp_jobs] ADD MEMBER [tp_test_job];
ALTER ROLE [tp_app] ADD MEMBER [tp_test_app];
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT ALL;
ALTER TABLE sec.AppUser NOCHECK CONSTRAINT ALL;
CREATE TABLE #listed (TenantId INT, Status VARCHAR(18), TimeZone VARCHAR(64));
GO
CREATE PROCEDURE #Bind @TenantId INT
AS
BEGIN
    DECLARE @token UNIQUEIDENTIFIER = NEWID();
    MERGE sec.SessionBinding AS b
    USING (SELECT @@SPID AS SessionId) AS s ON b.SessionId = s.SessionId
    WHEN MATCHED THEN UPDATE SET BoundTenantId = @TenantId, BoundUserId = 0, BindingToken = @token, BoundAt = SYSUTCDATETIME(),
                                 BindingKind = 'USER', BoundOperatorId = NULL
    WHEN NOT MATCHED THEN INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (s.SessionId, @TenantId, 0, @token);
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @TenantId;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
END;
GO

DECLARE @tA INT, @tT INT, @tS INT, @tC5 INT, @tC40 INT, @tR INT, @tN INT, @tD INT, @svcA BIGINT, @t INT;
DECLARE @e1 INT, @e2 INT, @e3 INT, @e4 INT, @e5 INT, @e6 INT, @e7 INT, @e8 INT, @n INT, @n2 INT, @n3 INT, @uid BIGINT, @key VARCHAR(80);
DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @corr UNIQUEIDENTIFIER = NEWID();

-- Seed: eight tenants, each with a service account while still open; then the statuses under test
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone, TrialEndsOn)
VALUES ('TST-JA', N'A', N'A', 1, 1, 'ACTIVE', 'Asia/Riyadh', NULL), ('TST-JT', N'T', N'T', 1, 1, 'TRIAL', 'UTC', DATEADD(DAY, 10, CAST(@now AS DATE))),
       ('TST-JS', N'S', N'S', 1, 1, 'ACTIVE', 'UTC', NULL), ('TST-JC5', N'C5', N'C5', 1, 1, 'ACTIVE', 'UTC', NULL),
       ('TST-JC40', N'C40', N'C40', 1, 1, 'ACTIVE', 'UTC', NULL), ('TST-JR', N'R', N'R', 1, 1, 'ACTIVE', 'UTC', NULL),
       ('TST-JN', N'N', N'N', 1, 1, 'ACTIVE', 'UTC', NULL), ('TST-JD', N'D', N'D', 1, 1, 'ACTIVE', 'UTC', NULL);
SELECT @tA = TenantId FROM plat.Tenant WHERE Code = 'TST-JA';
SELECT @tT = TenantId FROM plat.Tenant WHERE Code = 'TST-JT';
SELECT @tS = TenantId FROM plat.Tenant WHERE Code = 'TST-JS';
SELECT @tC5 = TenantId FROM plat.Tenant WHERE Code = 'TST-JC5';
SELECT @tC40 = TenantId FROM plat.Tenant WHERE Code = 'TST-JC40';
SELECT @tR = TenantId FROM plat.Tenant WHERE Code = 'TST-JR';
SELECT @tN = TenantId FROM plat.Tenant WHERE Code = 'TST-JN';
SELECT @tD = TenantId FROM plat.Tenant WHERE Code = 'TST-JD';
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT TenantId FROM plat.Tenant WHERE Code LIKE 'TST-J%' AND TenantId <> @tN;
OPEN c; FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC #Bind @t;
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, IsSystemUser)
    VALUES (@t, CONCAT(N'svc', @t, N'@test.invalid'), N'Service', CASE WHEN @t = @tD THEN 'DISABLED' ELSE 'ACTIVE' END, 1);
    FETCH NEXT FROM c INTO @t;
END;
CLOSE c; DEALLOCATE c;
EXEC #Bind @tA;
INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, PasswordHash)
VALUES (@tA, N'user@ja.invalid', N'User', 'ACTIVE', '$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA');
SELECT @svcA = AppUserId FROM sec.AppUser WHERE TenantId = @tA AND IsSystemUser = 1;
UPDATE plat.Tenant SET Status = 'SUSPENDED', SuspendedReason = N'Test', SuspendedAt = @now WHERE TenantId = @tS;
UPDATE plat.Tenant SET Status = 'CLOSED', ClosedAt = DATEADD(DAY, -5, @now) WHERE TenantId = @tC5;
UPDATE plat.Tenant SET Status = 'CLOSED', ClosedAt = DATEADD(DAY, -40, @now) WHERE TenantId = @tC40;
UPDATE plat.Tenant SET Status = 'ARCHIVED_READ_ONLY', ClosedAt = DATEADD(DAY, -40, @now), ArchivedAt = DATEADD(DAY, -10, @now) WHERE TenantId = @tR;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = NULL;

/* J1: only the job worker role runs the job procedures (229 for the tenant application). */
SAVE TRANSACTION j1;
SELECT @e1 = NULL, @e2 = NULL;
EXECUTE AS USER = N'tp_test_app';
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tA, @JobKey = 'JOB-WFL-SLA'; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC plat.usp_ListTenantsForJobs @JobKey = 'JOB-WFL-SLA'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @e1 = 229 AND @e2 = 229 PRINT 'PASS J1: only the job worker runs the job binding procedures';
ELSE PRINT 'FAIL J1: job procedures open to the application (' + CONCAT(@e1, '/', @e2) + ')';
ROLLBACK TRANSACTION j1;

/* J2: the job must be in the closed catalogue and bind a tenant: an unknown key and a platform job are refused (50024). */
SAVE TRANSACTION j2;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL;
EXECUTE AS USER = N'tp_test_job';
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tA, @JobKey = 'JOB-NO-SUCH'; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tA, @JobKey = 'JOB-PLT-ARCHIVE'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC plat.usp_ListTenantsForJobs @JobKey = 'JOB-NO-SUCH'; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
REVERT;
IF @e1 = 50024 AND @e2 = 50024 AND @e3 = 50024 PRINT 'PASS J2: only catalogued tenant jobs bind';
ELSE PRINT 'FAIL J2: job catalogue (' + CONCAT(@e1, '/', @e2, '/', @e3) + ')';
ROLLBACK TRANSACTION j2;

/* J3: a tenant without an active service account cannot run jobs (50003). */
SAVE TRANSACTION j3;
SELECT @e1 = NULL, @e2 = NULL;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = -1;
EXECUTE AS USER = N'tp_test_job';
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tN, @JobKey = 'JOB-WFL-SLA'; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tD, @JobKey = 'JOB-WFL-SLA'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
IF @e1 = 50003 AND @e2 = 50003 PRINT 'PASS J3: a job binds only through an active service account';
ELSE PRINT 'FAIL J3: service account check (' + CONCAT(@e1, '/', @e2) + ')';
ROLLBACK TRANSACTION j3;

/* J4: the tenant status decides which jobs run (DOC-F04 7.4): all listed jobs in TRIAL and ACTIVE, the trial reminder
   only in TRIAL, the export expiry also in SUSPENDED and in CLOSED within 30 days, nothing after that. The context is
   preset, so a call that passes every check stops at 50004. */
SAVE TRANSACTION j4;
SELECT @e1 = NULL, @e2 = NULL, @e3 = NULL, @e4 = NULL, @e5 = NULL, @e6 = NULL, @e7 = NULL, @e8 = NULL;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = -1;
EXECUTE AS USER = N'tp_test_job';
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tA, @JobKey = 'JOB-WFL-SLA'; END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tT, @JobKey = 'JOB-PLT-TRIAL-REMIND'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tA, @JobKey = 'JOB-PLT-TRIAL-REMIND'; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tS, @JobKey = 'JOB-WFL-SLA'; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tS, @JobKey = 'JOB-PLT-EXPORT-EXPIRE'; END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tC5, @JobKey = 'JOB-PLT-EXPORT-EXPIRE'; END TRY BEGIN CATCH SET @e6 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tC40, @JobKey = 'JOB-PLT-EXPORT-EXPIRE'; END TRY BEGIN CATCH SET @e7 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetJobContext @TenantId = @tR, @JobKey = 'JOB-PLT-EXPORT-EXPIRE'; END TRY BEGIN CATCH SET @e8 = ERROR_NUMBER(); END CATCH;
REVERT;
EXEC sys.sp_set_session_context @key = N'TenantId', @value = NULL;
IF @e1 = 50004 AND @e2 = 50004 AND @e3 = 50002 AND @e4 = 50002 AND @e5 = 50004 AND @e6 = 50004 AND @e7 = 50002 AND @e8 = 50002
    PRINT 'PASS J4: each job runs only in the tenant statuses its catalogue row allows';
ELSE PRINT 'FAIL J4: job and tenant status (' + CONCAT(@e1, '/', @e2, '/', @e3, '/', @e4, '/', @e5, '/', @e6, '/', @e7, '/', @e8) + ')';
ROLLBACK TRANSACTION j4;

/* J5: the worker learns which tenants a job runs for, with status and time zone only. */
SAVE TRANSACTION j5;
DELETE FROM #listed;
EXECUTE AS USER = N'tp_test_job';
INSERT #listed (TenantId, Status, TimeZone) EXEC plat.usp_ListTenantsForJobs @JobKey = 'JOB-PLT-EXPORT-EXPIRE';
REVERT;
SELECT @n = COUNT(*) FROM #listed WHERE TenantId IN (@tA, @tT, @tS, @tC5);
SELECT @n2 = COUNT(*) FROM #listed WHERE TenantId IN (@tC40, @tR, @tN, @tD);
SELECT @n3 = COUNT(*) FROM #listed WHERE TenantId = @tA AND Status = 'ACTIVE' AND TimeZone = 'Asia/Riyadh';
IF @n = 4 AND @n2 = 0 AND @n3 = 1 PRINT 'PASS J5: the tenant list follows the job catalogue, the status and the service account';
ELSE PRINT 'FAIL J5: tenant list for jobs (' + CONCAT(@n, '/', @n2, '/', @n3) + ')';
ROLLBACK TRANSACTION j5;

/* J6: the real job binding (last, because it makes the context read-only): the connection acts as the tenant's
   service account for that job, reads and writes its tenant only, cannot use the administrator procedures (50003),
   and loses the rows when the account is disabled. */
SAVE TRANSACTION j6;
SELECT @e1 = NULL, @n = NULL, @n2 = NULL, @n3 = NULL, @uid = NULL, @key = NULL;
EXECUTE AS USER = N'tp_test_job';
BEGIN TRY
    EXEC sec.usp_SetJobContext @TenantId = @tA, @JobKey = 'JOB-WFL-SLA', @CorrelationId = @corr;
    SELECT @uid = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), @key = CAST(SESSION_CONTEXT(N'JobKey') AS VARCHAR(80));
    INSERT cfg.JobRun (TenantId, JobKey) VALUES (@tA, 'JOB-WFL-SLA');
    SELECT @n = COUNT(AppUserId) FROM sec.AppUser;
    SELECT @n2 = COUNT(JobRunId) FROM cfg.JobRun;
END TRY
BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH;
-- the service account may not act as an administrator: no MFA reset, link or user change (ADR 0004)
SELECT @e2 = NULL, @e3 = NULL;
DECLARE @user BIGINT = (SELECT AppUserId FROM sec.AppUser WHERE TenantId = @tA AND IsSystemUser = 0);
BEGIN TRY EXEC sec.usp_ResetMfa @TenantId = @tA, @UserId = @user; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH;
BEGIN TRY EXEC sec.usp_SetUserStatus @TenantId = @tA, @UserId = @user, @Status = 'DISABLED'; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH;
REVERT;
UPDATE sec.AppUser SET Status = 'DISABLED' WHERE AppUserId = @svcA;
EXECUTE AS USER = N'tp_test_job';
SELECT @n3 = COUNT(AppUserId) FROM sec.AppUser;
REVERT;
IF @e1 IS NULL AND @uid = @svcA AND @key = 'JOB-WFL-SLA' AND @n = 2 AND @n2 = 1 AND @e2 = 50003 AND @e3 = 50003 AND @n3 = 0
    PRINT 'PASS J6: a job binds as the tenant''s service account, works in that tenant only, cannot act as an administrator, and loses the tenant when the account is disabled';
ELSE PRINT 'FAIL J6: job binding (' + CONCAT(@e1, '/', @uid, '/', @key, '/', @n, '/', @n2, '/', @e2, '/', @e3, '/', @n3) + ')';
/* J7: the binding wrote a row of the tenant with its JobKey and correlation id; the actor is the service account
   (DOC-F04 section 5.2, ADR 0007). */
DECLARE @auditRows INT;
EXECUTE AS USER = N'tp_test_jread';
SELECT @auditRows = COUNT(*) FROM aud.AuditLog
 WHERE TenantId = @tA AND Action = 'JOB_BOUND' AND Category = 'SYSTEM' AND ActorType = 'JOB'
   AND ActorId = (SELECT PublicId FROM sec.AppUser WHERE AppUserId = @svcA)
   AND JSON_VALUE(AfterJson, '$.jobKey') = 'JOB-WFL-SLA' AND CorrelationId = @corr;
REVERT;
IF @auditRows = 1 PRINT 'PASS J7: a job binding is audited in the tenant''s log with its JobKey, correlation id and service account';
ELSE PRINT CONCAT('FAIL J7: job binding audit rows ', @auditRows);
ROLLBACK TRANSACTION j6;

ROLLBACK TRANSACTION;
GO
PRINT 'Job binding tests finished; every change is rolled back.';
GO

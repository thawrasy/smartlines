/* ============================================================================
   BankFas - 037: binding a background job to a tenant (FR-PLT-044, DQ-F04-4, DOC-F04 section 5.2, DOC-F17 5)

   The job worker logs in with its own login, a member of tp_jobs; the web server never holds it (DOC-S08). tp_jobs
   is a member of tp_app, so a bound job has the application's table rights and its row filters, and it may run:
     plat.usp_ListTenantsForJobs  the tenants a job may run for now: TenantId, status and time zone only.
     sec.usp_SetJobContext        binds the connection to one tenant as that tenant's service account
                                  (sec.AppUser.IsSystemUser = 1, ACTIVE), for one job of the closed catalogue
                                  cfg.JobDefinition, in a status the job allows (DOC-F04 7.4).
   The keys UserId (the service account), JobKey and CorrelationId are read-only, as for a user binding, and the
   binding row says JOB. Disabling the service account or a status change removes the binding (triggers in 030).
   Writes still need TRIAL or ACTIVE (rls.fn_BoundWrite): a job bound in SUSPENDED or CLOSED reads; the writes it
   needs there go through procedures, as for users (DQ-F04-8).

   Errors: 50001 arguments, 50002 the tenant status does not allow this job, 50003 no active service account,
   50004 already bound, 50024 unknown or platform job.
   Residual risk (DQ-F04-4, accepted with an owner): whoever holds the worker login can bind any tenant as its
   service account for a listed job, without a user session. Controls: a separate login and secret, the closed job
   list, and the worker's audit of each run (cfg.JobRun, aud.AuditLog).
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
IF DATABASE_PRINCIPAL_ID(N'tp_jobs') IS NULL CREATE ROLE [tp_jobs] AUTHORIZATION dbo;
IF IS_ROLEMEMBER(N'tp_app', N'tp_jobs') <> 1 ALTER ROLE [tp_app] ADD MEMBER [tp_jobs];
GO
-- The tenant status a job sees: CLOSED counts only within 30 days of ClosedAt (after that the tenant waits for the
-- platform archive job), and the job's catalogue row must list it.
CREATE OR ALTER FUNCTION sec.fn_JobAllowed (@TenantId INT, @JobKey VARCHAR(80))
RETURNS TABLE
AS RETURN
    SELECT t.Status
    FROM plat.Tenant AS t
    JOIN cfg.JobDefinition AS j ON j.JobKey = @JobKey AND j.Scope = 'TENANT' AND j.IsActive = 1
    WHERE t.TenantId = @TenantId
      AND NOT (t.Status = 'CLOSED' AND SYSUTCDATETIME() >= DATEADD(DAY, 30, t.ClosedAt))
      AND ',' + j.RunsInStatuses + ',' LIKE '%,' + t.Status + ',%';
GO
CREATE OR ALTER PROCEDURE plat.usp_ListTenantsForJobs
    @JobKey VARCHAR(80)
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM cfg.JobDefinition WHERE JobKey = @JobKey AND Scope = 'TENANT' AND IsActive = 1)
        THROW 50024, 'Unknown job, or a platform job that binds no tenant', 1;
    SELECT t.TenantId, t.Status, t.TimeZone
    FROM plat.Tenant AS t
    WHERE EXISTS (SELECT 1 FROM sec.fn_JobAllowed(t.TenantId, @JobKey))
      AND EXISTS (SELECT 1 FROM sec.AppUser AS u WHERE u.TenantId = t.TenantId AND u.IsSystemUser = 1 AND u.Status = 'ACTIVE')
    ORDER BY t.TenantId;
END;
GO
CREATE OR ALTER PROCEDURE sec.usp_SetJobContext
    @TenantId      INT,
    @JobKey        VARCHAR(80),
    @CorrelationId UNIQUEIDENTIFIER = NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    IF @TenantId IS NULL OR @JobKey IS NULL THROW 50001, 'TenantId and JobKey are required', 1;
    DECLARE @own BIT = 0, @svc BIGINT, @token UNIQUEIDENTIFIER = NEWID();
    IF NOT EXISTS (SELECT 1 FROM cfg.JobDefinition WHERE JobKey = @JobKey AND Scope = 'TENANT' AND IsActive = 1)
        THROW 50024, 'Unknown job, or a platform job that binds no tenant', 1;
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_SetJobContext;
    BEGIN TRY
        -- Locks held until the binding commits, as in sec.usp_SetSessionContext (OUT-01).
        IF NOT EXISTS (SELECT 1 FROM plat.Tenant WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @TenantId)
           OR NOT EXISTS (SELECT 1 FROM sec.fn_JobAllowed(@TenantId, @JobKey))
            THROW 50002, 'The tenant status does not allow this job', 1;
        SELECT TOP (1) @svc = AppUserId
        FROM sec.AppUser WITH (UPDLOCK, HOLDLOCK)
        WHERE TenantId = @TenantId AND IsSystemUser = 1 AND Status = 'ACTIVE'
        ORDER BY AppUserId;
        IF @svc IS NULL THROW 50003, 'The tenant has no active service account', 1;
        IF SESSION_CONTEXT(N'TenantId') IS NOT NULL
            THROW 50004, 'The connection is already bound; reset it (sp_reset_connection) before binding again', 1;

        EXEC sp_set_session_context N'UserId', @svc, @read_only = 1;
        EXEC sp_set_session_context N'JobKey', @JobKey, @read_only = 1;
        EXEC sp_set_session_context N'CorrelationId', @CorrelationId, @read_only = 1;

        MERGE sec.SessionBinding AS b
        USING (SELECT @@SPID AS SessionId) AS s
           ON b.SessionId = s.SessionId
        WHEN MATCHED THEN
            UPDATE SET BoundTenantId = @TenantId, BoundUserId = @svc, BindingToken = @token, BoundAt = SYSUTCDATETIME(),
                       BindingKind = 'JOB', BoundOperatorId = NULL
        WHEN NOT MATCHED THEN
            INSERT (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind)
            VALUES (s.SessionId, @TenantId, @svc, @token, 'JOB');
        -- Every job binding is audited with its JobKey (DOC-F04 section 5.2); the actor is the service account.
        DECLARE @after NVARCHAR(200) = (SELECT @JobKey AS jobKey FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC aud.usp_WriteEvent @TenantId = @TenantId, @Action = 'JOB_BOUND', @Category = 'SYSTEM', @ActorType = 'JOB',
             @ActorUserId = @svc, @AfterJson = @after, @CorrelationId = @CorrelationId;

        EXEC sp_set_session_context N'BindingToken', @token, @read_only = 1;
        EXEC sp_set_session_context N'TenantId', @TenantId, @read_only = 1;
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SetJobContext;   -- undo this procedure only
        THROW;
    END CATCH;
END;
GO
GRANT EXECUTE ON plat.usp_ListTenantsForJobs TO [tp_jobs];
GRANT EXECUTE ON sec.usp_SetJobContext TO [tp_jobs];
GO

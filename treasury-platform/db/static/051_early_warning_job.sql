/* 051_early_warning_job.sql — the early warning job: the company learns, without opening the readiness file, that a
   lender date is coming and the company is not ready for it (docs/36 gap F4, ADR 0027, FR-FIN-040, BR-FIN-041).

   049 lists the warnings of a day (fin.fn_CreditEarlyWarnings): every renewal, covenant test and report to a lender
   within the lead time of the tenant (fin.readiness.lead_months, 6 by the owner's decision 34) whose readiness on
   the latest computed assessment of an actual statement is AMBER or RED. This script sends them:
     fin.usp_RunEarlyWarnings  run daily by the job JOB-FIN-READINESS (05:20 in the tenant's time, after JOB-FIN-EVAL
                               and JOB-OBL-CALENDAR, before JOB-NTF-DIGEST gathers the morning), bound to the tenant
                               as its service account (037). For each warning not yet issued it writes a row in
                               fin.EarlyWarningAlert and, in the same transaction, a notification request in
                               cfg.OutboxEvent (DOC-F17 6.1: Emit writes the outbox only; the notification builder
                               resolves the recipients of FIN.READINESS_WARNING by its rules and preferences).
   One warning per stage of the time left and readiness (BR-FIN-041):
     - a lender date warns when it enters the lead time (LEAD), then again at 90, 30 and 7 days left (D90, D30, D7);
     - within a stage it warns again only when its readiness worsens from AMBER to RED; a RED date that improves to
       AMBER does not warn again in that stage, and one that becomes GREEN stops warning;
     - after a stop of several days a run issues the current stage only, never the missed ones (DOC-F17 5.5);
     - a date the lender moves (a renewal agreed to a new expiry) starts again from its first stage.
   The request carries identifiers only (FR-NTF-021): the company, the assessment as the target of the link, the kind
   of date, its reference, the date, the stage, the readiness, the severity (HIGH for RED, WARNING for AMBER) and the
   dedup key FIN.READINESS_WARNING:<kind>:<reference>:<stage>.<readiness>:<yyyymmdd of the date> (BR-NTF-002).
   @AsOf is the tenant's local date, which the worker computes from the time zone usp_ListTenantsForJobs returns; it
   must be within a day of the UTC date, so that no run issues warnings for another day.
   The application cannot write fin.EarlyWarningAlert; it reads it (the history of the warnings).
   Errors: 50092 not bound as JOB-FIN-READINESS for a tenant that allows it, or @AsOf not within a day of today. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER PROCEDURE fin.usp_RunEarlyWarnings
    @AsOf   DATE,
    @Issued INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Issued = 0;
    DECLARE @t INT = (SELECT TenantId FROM sec.fn_JobTenant('JOB-FIN-READINESS')), @own BIT = 0,
            @today DATE = CAST(SYSUTCDATETIME() AS DATE), @lock NVARCHAR(100), @rc INT;
    IF @t IS NULL THROW 50092, 'The early warning job must be bound as JOB-FIN-READINESS to a tenant that allows it', 1;
    IF @AsOf IS NULL OR @AsOf NOT BETWEEN DATEADD(DAY, -1, @today) AND DATEADD(DAY, 1, @today)
        THROW 50092, 'The run date must be the tenant''s date, within a day of today', 1;
    DECLARE @new TABLE (CompanyId BIGINT NOT NULL, AssessmentId BIGINT NOT NULL, EventKind VARCHAR(13) NOT NULL, RefId BIGINT NOT NULL,
                        EventDate DATE NOT NULL, Stage VARCHAR(4) NOT NULL, Readiness VARCHAR(5) NOT NULL, MessageId UNIQUEIDENTIFIER NOT NULL);
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_RunEarlyWarnings;
    BEGIN TRY
        -- one run of this tenant at a time; the unique key of the log is the last guard
        SET @lock = CONCAT(N'JOB-FIN-READINESS:', @t);
        EXEC @rc = sys.sp_getapplock @Resource = @lock, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 30000;
        IF @rc < 0 THROW 50092, 'Another run of the early warning job holds this tenant', 1;
        INSERT @new (CompanyId, AssessmentId, EventKind, RefId, EventDate, Stage, Readiness, MessageId)
        SELECT w.CompanyId, w.AssessmentId, w.EventKind, w.RefId, w.EventDate, w.Stage, w.Readiness, NEWID()
        FROM fin.fn_CreditEarlyWarnings(@AsOf) AS w
        WHERE w.TenantId = @t AND w.DaysLeft >= 0
          AND NOT EXISTS (SELECT 1 FROM fin.EarlyWarningAlert AS x
                          WHERE x.TenantId = @t AND x.CompanyId = w.CompanyId AND x.EventKind = w.EventKind AND x.RefId = w.RefId
                            AND x.EventDate = w.EventDate AND x.Stage = w.Stage AND (x.Readiness = w.Readiness OR x.Readiness = 'RED'));
        INSERT fin.EarlyWarningAlert (TenantId, CompanyId, AssessmentId, EventKind, RefId, EventDate, Stage, Readiness, IssuedOn, MessageId)
        SELECT @t, CompanyId, AssessmentId, EventKind, RefId, EventDate, Stage, Readiness, @AsOf, MessageId FROM @new;
        INSERT cfg.OutboxEvent (TenantId, MessageId, EventName, AggregateType, AggregateId, PayloadJson)
        SELECT @t, n.MessageId, 'notification.requested', 'fin.CreditAssessment', n.AssessmentId,
               (SELECT 'FIN.READINESS_WARNING' AS eventCode, n.CompanyId AS companyId, 'fin.CreditAssessment' AS targetType,
                       n.AssessmentId AS targetId, n.EventKind AS eventKind, n.RefId AS refId, CONVERT(CHAR(10), n.EventDate, 23) AS eventDate,
                       n.Stage AS stage, n.Readiness AS readiness, CASE n.Readiness WHEN 'RED' THEN 'HIGH' ELSE 'WARNING' END AS severity,
                       CONCAT('FIN.READINESS_WARNING:', n.EventKind, ':', n.RefId, ':', n.Stage, '.', n.Readiness, ':', CONVERT(CHAR(8), n.EventDate, 112)) AS dedupKey
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        FROM @new AS n;
        SET @Issued = (SELECT COUNT(*) FROM @new);
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_RunEarlyWarnings;   -- undo this procedure only
        SET @Issued = 0;
        THROW;
    END CATCH;
END;
GO
GRANT EXECUTE ON fin.usp_RunEarlyWarnings TO [tp_jobs];
DENY INSERT, UPDATE, DELETE ON fin.EarlyWarningAlert TO [tp_app];
GO

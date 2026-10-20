/* 051_early_warning_job.sql — the early warning job: the company learns, without opening the readiness file, that a
   lender date is coming and the company is not ready for it (docs/36 gap F4, ADR 0027 and ADR 0028, FR-FIN-040, FR-FIN-041, BR-FIN-041, BR-FIN-042).

   049 lists the warnings of a day (fin.fn_CreditEarlyWarnings): every renewal, covenant test and report to a lender
   within the lead time of the tenant (fin.readiness.lead_months, 6 by the owner's decision 34) whose readiness on
   the latest computed assessment of an actual statement is AMBER or RED. This script sends them:
     fin.usp_RunEarlyWarnings  run daily by the job JOB-FIN-READINESS (05:20 in the tenant's time, after JOB-FIN-EVAL
                               and JOB-OBL-CALENDAR, before JOB-NTF-DIGEST gathers the morning), bound to the tenant
                               as its service account (037). For each warning not yet issued it writes a row in
                               fin.EarlyWarningAlert and, in the same transaction, a notification request in
                               cfg.OutboxEvent (DOC-F17 6.1: Emit writes the outbox only; the notification builder
                               resolves the recipients by the rules of the event and their preferences).
     fin.v_EarlyWarningMessageValues  the values of the placeholders of the message templates of each warning, in
                               Arabic and English (ADR 0028): the notification builder reads them by MessageId and
                               fills the template of the recipient's language (the tenant pack NTF.BASE).
   Two events, by readiness (ADR 0028): FIN.READINESS_RED, severity HIGH, mandatory, in the application and by email;
   FIN.READINESS_AMBER, severity WARNING, in the application, which a user may take in the daily digest.
   One warning per stage of the time left and readiness (BR-FIN-041):
     - a lender date warns when it enters the lead time (LEAD), then again at 90, 30 and 7 days left (D90, D30, D7);
     - within a stage it warns again only when its readiness worsens from AMBER to RED; a RED date that improves to
       AMBER does not warn again in that stage, and one that becomes GREEN stops warning;
     - after a stop of several days a run issues the current stage only, never the missed ones (DOC-F17 5.5);
     - a date the lender moves (a renewal agreed to a new expiry) starts again from its first stage.
   The request carries identifiers and codes only (FR-NTF-021): the event code, the company, the assessment as the
   target of the link, the kind of date, its reference, the date, the stage, the readiness and its reason, the
   severity and the dedup key <event code>:<kind>:<reference>:<stage>:<yyyymmdd of the date> (BR-NTF-002).
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
                        EventDate DATE NOT NULL, Stage VARCHAR(4) NOT NULL, Readiness VARCHAR(5) NOT NULL, ReasonCode VARCHAR(30) NOT NULL, MessageId UNIQUEIDENTIFIER NOT NULL);
    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_RunEarlyWarnings;
    BEGIN TRY
        -- one run of this tenant at a time; the unique key of the log is the last guard
        SET @lock = CONCAT(N'JOB-FIN-READINESS:', @t);
        EXEC @rc = sys.sp_getapplock @Resource = @lock, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 30000;
        IF @rc < 0 THROW 50092, 'Another run of the early warning job holds this tenant', 1;
        INSERT @new (CompanyId, AssessmentId, EventKind, RefId, EventDate, Stage, Readiness, ReasonCode, MessageId)
        SELECT w.CompanyId, w.AssessmentId, w.EventKind, w.RefId, w.EventDate, w.Stage, w.Readiness, w.ReasonCode, NEWID()
        FROM fin.fn_CreditEarlyWarnings(@AsOf) AS w
        WHERE w.TenantId = @t AND w.DaysLeft >= 0
          AND NOT EXISTS (SELECT 1 FROM fin.EarlyWarningAlert AS x
                          WHERE x.TenantId = @t AND x.CompanyId = w.CompanyId AND x.EventKind = w.EventKind AND x.RefId = w.RefId
                            AND x.EventDate = w.EventDate AND x.Stage = w.Stage AND (x.Readiness = w.Readiness OR x.Readiness = 'RED'));
        INSERT fin.EarlyWarningAlert (TenantId, CompanyId, AssessmentId, EventKind, RefId, EventDate, Stage, Readiness, ReasonCode, IssuedOn, MessageId)
        SELECT @t, CompanyId, AssessmentId, EventKind, RefId, EventDate, Stage, Readiness, ReasonCode, @AsOf, MessageId FROM @new;
        INSERT cfg.OutboxEvent (TenantId, MessageId, EventName, AggregateType, AggregateId, PayloadJson)
        SELECT @t, n.MessageId, 'notification.requested', 'fin.CreditAssessment', n.AssessmentId,
               (SELECT c.EventCode AS eventCode, n.CompanyId AS companyId, 'fin.CreditAssessment' AS targetType,
                       n.AssessmentId AS targetId, n.EventKind AS eventKind, n.RefId AS refId, CONVERT(CHAR(10), n.EventDate, 23) AS eventDate,
                       n.Stage AS stage, n.Readiness AS readiness, n.ReasonCode AS reasonCode,
                       CASE n.Readiness WHEN 'RED' THEN 'HIGH' ELSE 'WARNING' END AS severity,
                       CONCAT(c.EventCode, ':', n.EventKind, ':', n.RefId, ':', n.Stage, ':', CONVERT(CHAR(8), n.EventDate, 112)) AS dedupKey
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        FROM @new AS n
        CROSS APPLY (SELECT CONCAT('FIN.READINESS_', n.Readiness) AS EventCode) AS c;
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
/* The values of the placeholders of a warning's message, in Arabic and English (ADR 0028, BR-FIN-042). The templates
   of the tenant pack NTF.BASE may use these placeholders only (AllowedPlaceholdersJson): {companyName} {eventLabel}
   {reference} {eventDate} {daysLeft} {stageLabel} {reason} {grade} {liquidity} {leadMonths}. No restricted value is
   among them (FR-NTF-021): names, a facility number or an obligation's title, a date, the grade and liquidity of the
   company's own assessment. The link is the assessment's readiness file, which checks the reader's rights. */
CREATE OR ALTER VIEW fin.v_EarlyWarningMessageValues
AS
SELECT w.TenantId, w.EarlyWarningAlertId, w.MessageId, w.CompanyId, w.AssessmentId, CONCAT('FIN.READINESS_', w.Readiness) AS EventCode,
       w.EventKind, w.Stage, w.Readiness, w.ReasonCode,
       c.NameAr AS CompanyNameAr, ISNULL(c.NameEn, c.NameAr) AS CompanyNameEn,
       k.LabelAr AS EventLabelAr, k.LabelEn AS EventLabelEn,
       COALESCE(fa.FacilityNo, o.TitleAr) AS ReferenceAr, COALESCE(fa.FacilityNo, o.TitleEn, o.TitleAr) AS ReferenceEn,
       CONVERT(CHAR(10), w.EventDate, 23) AS EventDate, DATEDIFF(DAY, w.IssuedOn, w.EventDate) AS DaysLeft,
       g.LabelAr AS StageLabelAr, g.LabelEn AS StageLabelEn, r.TextAr AS ReasonAr, r.TextEn AS ReasonEn,
       ISNULL(rg.Code, '-') AS Grade, ISNULL(a.LiquidityLabel, '-') AS Liquidity, lm.Value AS LeadMonths,
       CONCAT('/fin/assessments/', a.PublicId, '/readiness') AS DeepLink
FROM fin.EarlyWarningAlert AS w
JOIN org.Company AS c ON c.TenantId = w.TenantId AND c.CompanyId = w.CompanyId
JOIN fin.CreditAssessment AS a ON a.TenantId = w.TenantId AND a.CreditAssessmentId = w.AssessmentId
LEFT JOIN fin.RatingGrade AS rg ON rg.RatingGradeId = a.FinalGradeId
CROSS APPLY cfg.fn_SettingInt(w.TenantId, 'fin.readiness.lead_months', 6) AS lm
LEFT JOIN fac.Facility AS fa ON w.EventKind = 'RENEWAL' AND fa.TenantId = w.TenantId AND fa.FacilityId = w.RefId
LEFT JOIN obl.CovenantTest AS ct ON w.EventKind = 'COVENANT_TEST' AND ct.TenantId = w.TenantId AND ct.CovenantTestId = w.RefId
LEFT JOIN obl.Covenant AS cv ON cv.TenantId = ct.TenantId AND cv.CovenantId = ct.CovenantId
LEFT JOIN obl.ReportingInstance AS ri ON w.EventKind = 'REPORTING' AND ri.TenantId = w.TenantId AND ri.ReportingInstanceId = w.RefId
LEFT JOIN obl.ReportingObligation AS ro ON ro.TenantId = ri.TenantId AND ro.ReportingObligationId = ri.ReportingObligationId
LEFT JOIN obl.Obligation AS o ON o.TenantId = w.TenantId AND o.ObligationId = COALESCE(cv.ObligationId, ro.ObligationId)
JOIN (VALUES ('RENEWAL', N'تجديد التسهيل', N'renewal of facility'),
             ('COVENANT_TEST', N'اختبار التعهد', N'covenant test'),
             ('REPORTING', N'تقرير لجهة التمويل', N'report to the lender')) AS k (EventKind, LabelAr, LabelEn) ON k.EventKind = w.EventKind
JOIN (VALUES ('LEAD', N'دخل مدة التنبيه', N'within the lead time'),
             ('D90', N'بقي 90 يومًا أو أقل', N'90 days or fewer left'),
             ('D30', N'بقي 30 يومًا أو أقل', N'30 days or fewer left'),
             ('D7', N'بقي 7 أيام أو أقل', N'7 days or fewer left')) AS g (Stage, LabelAr, LabelEn) ON g.Stage = w.Stage
JOIN (VALUES ('NOT_RATED', N'التقييم لم يصل إلى درجة لنقص البيانات', N'the assessment has no grade, for lack of data'),
             ('LIQUIDITY_SGL4', N'السيولة SGL-4: مصادرها لا تغطي ما يستحق خلال السنة', N'liquidity SGL-4: its sources do not cover what falls due within the year'),
             ('GRADE_B3', N'درجة التقييم B3 أو أدنى', N'the assessment grade is B3 or below'),
             ('COVENANT_BREACH', N'آخر اختبار لهذا التعهد كان خرقًا', N'the last test of this covenant was a breach'),
             ('HEADROOM_NEGATIVE', N'هامش التعهد في آخر اختبار دون الصفر', N'the covenant headroom at the last test is below zero'),
             ('LENDER_ACTION', N'أبلغت جهة التمويل بإيقاف الحد أو تخفيضه أو عدم تجديده', N'the lender notified a stop, a reduction or no renewal of the limit'),
             ('LENDER_RATING_B3', N'آخر تصنيف أبلغت به جهة التمويل B3 أو أدنى', N'the latest rating the lender communicated is B3 or below'),
             ('LIQUIDITY_SGL3', N'السيولة SGL-3: تغطي ما يستحق بهامش ضيق', N'liquidity SGL-3: it covers what falls due with a thin margin'),
             ('OUTLOOK_NEGATIVE', N'النظرة المستقبلية سلبية', N'the outlook is negative'),
             ('CRITICAL_RISK', N'في التقييم خطر حرج مفتوح', N'the assessment has an open critical risk'),
             ('DATA_MISSING', N'بيانات أو إفصاحات ستطلبها جهة التمويل ناقصة', N'data or disclosures the lender will ask for are missing'),
             ('HEADROOM_LOW', N'هامش التعهد دون حد الإنذار المبكر', N'the covenant headroom is below its early warning'),
             ('LENDER_RATING_GAP', N'تصنيف جهة التمويل أدنى من درجة التقييم بدرجتين أو أكثر', N'the lender''s rating is two notches or more below the assessment grade'),
             ('CALIBRATION_OPTIMISTIC', N'تقييم الشركة أعلى من تصنيفات جهاتها بدرجة أو أكثر في المتوسط', N'the company rates itself one notch or more above its lenders on average'),
             ('CALIBRATION_STALE', N'آخر تصنيف أبلغت به جهة تمويل أقدم من مدة المعايرة', N'the latest rating a lender communicated is older than the calibration age')
     ) AS r (ReasonCode, TextAr, TextEn) ON r.ReasonCode = w.ReasonCode;
GO
GRANT SELECT ON fin.v_EarlyWarningMessageValues TO [tp_app];
GO
GRANT EXECUTE ON fin.usp_RunEarlyWarnings TO [tp_jobs];
DENY INSERT, UPDATE, DELETE ON fin.EarlyWarningAlert TO [tp_app];
GO

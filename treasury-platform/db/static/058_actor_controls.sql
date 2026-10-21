/* 058_actor_controls.sql — the maker and the checker are the user of the session (ADR 0037; the internal review of
   2026-10-21, lens E, findings 1, 2, 15 and 9).

   The columns that name who prepared, entered, approved, confirmed or chose a record (PreparedBy, EnteredBy,
   ApprovedBy, ConfirmedBy, ChosenBy, EndorsedBy) are written by the application, and a CHECK alone compared them: an
   application that wrote another user's id could prepare and approve alone. Here the database compares them with the
   user the connection is bound to (SESSION_CONTEXT UserId of a USER binding, sec.fn_BoundAsUser) and with the
   permissions that user holds through an active role (sec.fn_UserHasPermission, as 052 and 053 do):
     fin.fn_ActingUser                      the bound user, whether the binding is a USER one, whether the user holds a
                                            permission.
     statements (fin.FinancialStatement)    the preparer set or changed, and the submission: the preparer is the bound
                                            user, holder of fin.stmt.enter; the approval: the approver is the bound user,
                                            holder of fin.stmt.approve (and not the preparer, the CHECK of the model); a
                                            rejection and a supersession by a holder of fin.stmt.approve. A statement is
                                            written as a draft (045), so it is never inserted approved.
     assessments (fin.CreditAssessment)     the same with fin.credit.assess and fin.credit.approve; the computation (the
                                            results written by fin.usp_ComputeCreditAssessment, 047) by a holder of
                                            fin.credit.assess; the endorsement by the bound user, holder of
                                            fin.credit.endorse (052).
     the analyst's inputs                   every input written is stamped with the bound user, holder of
     (fin.CreditAssessmentInput)            fin.credit.assess (EnteredBy).
     presentation versions                  the preparer is the bound user, holder of fin.stmt.enter; the choice by the
     (fin.PresentationVersion)              bound user, holder of fin.stmt.approve (048).
     revenue estimates (fin.RevenueEstimate) written as a draft; every change of a draft is stamped with its preparer,
                                            the bound user, holder of fin.stmt.enter; approved as prepared by the bound
                                            user, holder of fin.stmt.approve and not the preparer; an approved or
                                            superseded estimate does not change and is not deleted, but an approved one
                                            moves to SUPERSEDED (by a holder of fin.stmt.approve); a change is a new
                                            estimate.
     monthly figures (fin.AccountMonthlyStat, fin.BankFlowEntry)
                                            entered as a draft; every change of a figure's content is stamped with its
                                            author (EnteredBy), the bound user, holder of fin.stats.enter, so after a
                                            reopening (052) the next edit names the editor; the confirmation by the bound
                                            user, holder of fin.stats.confirm, who is neither the author nor the user
                                            who reopened it last (the CHECKs of the model); the reopening by a holder of
                                            fin.stats.confirm (052).
     loss rates (fin.ReceivableLossRate)    written as a draft; every change of a draft is stamped with its preparer, the
                                            bound user, holder of fin.formula.manage (a default of the pack FIN.PROVISION,
                                            SeedKey set, is inserted without one); approved as prepared by the bound
                                            user, holder of fin.formula.approve and not its preparer; an approved rate
                                            does not change and is not deleted: a change is a rate with a later
                                            EffectiveFrom.
     lender ratings (fin.LenderRating)      a rating confirmed against the lender's letter (VerifiedBy), or read by an
                                            endorsed assessment (on or before its EndorsedLastRatingDate), does not
                                            change and is not deleted.
     product lines (fin.CompanyProductLine) the lines of a year that an approved or superseded assessment of the company
                                            read (its statement's fiscal year) do not change and are not deleted.
   What a job writes (the early warnings of 051) names no actor; the onboarding seeds no row of these tables but the
   pack defaults of the loss rates, which carry no preparer.
   Errors (ADR 0037): 50170 the actor is not the user bound to the session, or the session is not a user's;
   50171 the bound user lacks the permission of the action; 50172 the same person would act twice (a separation of
   duties the CHECKs of the model cannot see); 50173 an approved, confirmed, verified or used record is changed,
   deleted, or written directly in a final state. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
-- The user the connection is bound to, whether by a USER binding of the tenant, and whether the user holds @Permission.
CREATE OR ALTER FUNCTION fin.fn_ActingUser (@TenantId INT, @Permission VARCHAR(80))
RETURNS TABLE
AS RETURN
    SELECT CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) AS UserId,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@TenantId, 0)) THEN 1 ELSE 0 END AS BIT) AS IsUser,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@TenantId, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), @Permission))
                     THEN 1 ELSE 0 END AS BIT) AS Holds;
GO
/* ---------- statements ---------- */
CREATE OR ALTER TRIGGER fin.TR_FinancialStatement_Actors ON fin.FinancialStatement
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    DECLARE @bad INT;
    -- P the preparer set or changed, or the statement submitted; A the approver set or changed, or the statement
    -- approved; C a rejection or a supersession
    SELECT @bad = MAX(CASE WHEN u.IsUser = 0 OR (x.Act <> 'C' AND ISNULL(x.Actor, -1) <> u.UserId) THEN 1 WHEN u.Holds = 0 THEN 2 ELSE 0 END)
    FROM (SELECT i.TenantId, 'P' AS Act, i.PreparedBy AS Actor, 'fin.stmt.enter' AS Perm
          FROM inserted AS i LEFT JOIN deleted AS d ON d.FinancialStatementId = i.FinancialStatementId
          WHERE (i.PreparedBy IS NOT NULL AND (d.FinancialStatementId IS NULL OR ISNULL(d.PreparedBy, -1) <> i.PreparedBy))
             OR (d.Status = 'DRAFT' AND i.Status = 'SUBMITTED')
          UNION ALL
          SELECT i.TenantId, 'A', i.ApprovedBy, 'fin.stmt.approve'
          FROM inserted AS i LEFT JOIN deleted AS d ON d.FinancialStatementId = i.FinancialStatementId
          WHERE (i.ApprovedBy IS NOT NULL AND ISNULL(d.ApprovedBy, -1) <> i.ApprovedBy) OR (d.Status = 'SUBMITTED' AND i.Status = 'APPROVED')
          UNION ALL
          SELECT i.TenantId, 'C', NULL, 'fin.stmt.approve'
          FROM inserted AS i JOIN deleted AS d ON d.FinancialStatementId = i.FinancialStatementId
          WHERE (d.Status = 'SUBMITTED' AND i.Status = 'REJECTED') OR (d.Status = 'APPROVED' AND i.Status = 'SUPERSEDED')) AS x
    CROSS APPLY fin.fn_ActingUser(x.TenantId, x.Perm) AS u;
    IF @bad = 1 THROW 50170, 'A statement is prepared and submitted by its preparer, and approved by its approver, each the user bound to the session (ADR 0037)', 1;
    IF @bad = 2 THROW 50171, 'Preparing a statement needs fin.stmt.enter; approving, rejecting or superseding it needs fin.stmt.approve (ADR 0037)', 1;
END;
GO
/* ---------- assessments and the analyst's inputs ---------- */
CREATE OR ALTER TRIGGER fin.TR_CreditAssessment_Actors ON fin.CreditAssessment
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    DECLARE @bad INT;
    -- P preparer or submission; K the computation (its results written); A approver or approval; C a rejection or a
    -- supersession; E the endorsement
    SELECT @bad = MAX(CASE WHEN u.IsUser = 0 OR (x.Act NOT IN ('C', 'K') AND ISNULL(x.Actor, -1) <> u.UserId) THEN 1 WHEN u.Holds = 0 THEN 2 ELSE 0 END)
    FROM (SELECT i.TenantId, 'P' AS Act, i.PreparedBy AS Actor, 'fin.credit.assess' AS Perm
          FROM inserted AS i LEFT JOIN deleted AS d ON d.CreditAssessmentId = i.CreditAssessmentId
          WHERE (i.PreparedBy IS NOT NULL AND (d.CreditAssessmentId IS NULL OR ISNULL(d.PreparedBy, -1) <> i.PreparedBy))
             OR (d.Status = 'DRAFT' AND i.Status = 'SUBMITTED')
          UNION ALL
          SELECT i.TenantId, 'K', NULL, 'fin.credit.assess'
          FROM inserted AS i JOIN deleted AS d ON d.CreditAssessmentId = i.CreditAssessmentId
          WHERE i.ComputedAt IS NOT NULL AND ISNULL(d.ComputedAt, '19000101') <> i.ComputedAt
          UNION ALL
          SELECT i.TenantId, 'A', i.ApprovedBy, 'fin.credit.approve'
          FROM inserted AS i LEFT JOIN deleted AS d ON d.CreditAssessmentId = i.CreditAssessmentId
          WHERE (i.ApprovedBy IS NOT NULL AND ISNULL(d.ApprovedBy, -1) <> i.ApprovedBy) OR (d.Status = 'SUBMITTED' AND i.Status = 'APPROVED')
          UNION ALL
          SELECT i.TenantId, 'C', NULL, 'fin.credit.approve'
          FROM inserted AS i JOIN deleted AS d ON d.CreditAssessmentId = i.CreditAssessmentId
          WHERE (d.Status = 'SUBMITTED' AND i.Status = 'REJECTED') OR (d.Status = 'APPROVED' AND i.Status = 'SUPERSEDED')
          UNION ALL
          SELECT i.TenantId, 'E', i.EndorsedBy, 'fin.credit.endorse'
          FROM inserted AS i LEFT JOIN deleted AS d ON d.CreditAssessmentId = i.CreditAssessmentId
          WHERE i.EndorsedBy IS NOT NULL AND ISNULL(d.EndorsedBy, -1) <> i.EndorsedBy) AS x
    CROSS APPLY fin.fn_ActingUser(x.TenantId, x.Perm) AS u;
    IF @bad = 1 THROW 50170, 'An assessment is prepared, computed and submitted by its preparer, approved by its approver and endorsed by its endorser, each the user bound to the session (ADR 0037)', 1;
    IF @bad = 2 THROW 50171, 'Preparing or computing an assessment needs fin.credit.assess; approving, rejecting or superseding it fin.credit.approve; endorsing it fin.credit.endorse (ADR 0037)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CreditAssessmentInput_Actors ON fin.CreditAssessmentInput
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    DECLARE @bad INT;
    SELECT @bad = MAX(CASE WHEN u.IsUser = 0 OR ISNULL(i.EnteredBy, -1) <> u.UserId THEN 1 WHEN u.Holds = 0 THEN 2 ELSE 0 END)
    FROM inserted AS i
    CROSS APPLY fin.fn_ActingUser(i.TenantId, 'fin.credit.assess') AS u;
    IF @bad = 1 THROW 50170, 'An input of an assessment is entered by the user bound to the session, who is its EnteredBy (ADR 0037)', 1;
    IF @bad = 2 THROW 50171, 'Entering the inputs of an assessment needs fin.credit.assess (ADR 0037)', 1;
END;
GO
/* ---------- presentation versions ---------- */
CREATE OR ALTER TRIGGER fin.TR_PresentationVersion_Actors ON fin.PresentationVersion
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    DECLARE @bad INT;
    SELECT @bad = MAX(CASE WHEN u.IsUser = 0 OR ISNULL(x.Actor, -1) <> u.UserId THEN 1 WHEN u.Holds = 0 THEN 2 ELSE 0 END)
    FROM (SELECT i.TenantId, i.PreparedBy AS Actor, 'fin.stmt.enter' AS Perm
          FROM inserted AS i LEFT JOIN deleted AS d ON d.PresentationVersionId = i.PresentationVersionId
          WHERE d.PresentationVersionId IS NULL OR d.PreparedBy <> i.PreparedBy
          UNION ALL
          SELECT i.TenantId, i.ChosenBy, 'fin.stmt.approve'
          FROM inserted AS i JOIN deleted AS d ON d.PresentationVersionId = i.PresentationVersionId
          WHERE i.ChosenBy IS NOT NULL AND ISNULL(d.ChosenBy, -1) <> i.ChosenBy) AS x
    CROSS APPLY fin.fn_ActingUser(x.TenantId, x.Perm) AS u;
    IF @bad = 1 THROW 50170, 'A presentation version is prepared by its preparer and chosen by its chooser, each the user bound to the session (ADR 0037)', 1;
    IF @bad = 2 THROW 50171, 'Preparing a presentation version needs fin.stmt.enter, choosing it fin.stmt.approve (ADR 0037)', 1;
END;
GO
/* ---------- revenue estimates ---------- */
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);
INSERT @may VALUES (N'Status'), (N'PreparedBy'), (N'ApprovedBy'), (N'ApprovedOn'), (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'fin.RevenueEstimate') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SET @sql = N'CREATE OR ALTER TRIGGER fin.TR_RevenueEstimate_Actors ON fin.RevenueEstimate
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    -- an approved or superseded estimate stays: it is not deleted, and an approved one only moves to SUPERSEDED
    IF EXISTS (SELECT 1 FROM deleted AS d LEFT JOIN inserted AS i ON i.RevenueEstimateId = d.RevenueEstimateId
               WHERE d.Status <> ''DRAFT''
                 AND (i.RevenueEstimateId IS NULL
                      OR NOT (i.Status = d.Status OR (d.Status = ''APPROVED'' AND i.Status = ''SUPERSEDED''))
                      OR ISNULL(i.PreparedBy, -1) <> ISNULL(d.PreparedBy, -1) OR ISNULL(i.ApprovedBy, -1) <> ISNULL(d.ApprovedBy, -1)
                      OR ISNULL(i.ApprovedOn, ''19000101'') <> ISNULL(d.ApprovedOn, ''19000101'')
                      OR EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')))
        THROW 50173, ''An approved revenue estimate does not change and is not deleted; a change is a new estimate that supersedes it (ADR 0037)'', 1;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    IF EXISTS (SELECT 1 FROM inserted AS i LEFT JOIN deleted AS d ON d.RevenueEstimateId = i.RevenueEstimateId
               WHERE d.RevenueEstimateId IS NULL AND i.Status <> ''DRAFT'')
        THROW 50173, ''A revenue estimate is written as a draft and approved by someone else (ADR 0037)'', 1;
    -- approved as prepared: the approver changes nothing of it
    IF EXISTS (SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.RevenueEstimateId = i.RevenueEstimateId
               WHERE d.Status = ''DRAFT'' AND i.Status <> ''DRAFT''
                 AND (ISNULL(i.PreparedBy, -1) <> ISNULL(d.PreparedBy, -1) OR EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')))
        THROW 50172, ''A revenue estimate is approved as its preparer wrote it (ADR 0037)'', 1;
    IF EXISTS (SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.RevenueEstimateId = i.RevenueEstimateId
               WHERE d.Status = ''DRAFT'' AND i.Status = ''APPROVED'' AND i.PreparedBy IS NULL)
        THROW 50172, ''A revenue estimate is approved once someone prepared it (ADR 0037)'', 1;
    DECLARE @bad INT;
    SELECT @bad = MAX(CASE WHEN u.IsUser = 0 OR (x.Act <> ''C'' AND ISNULL(x.Actor, -1) <> u.UserId) THEN 1 WHEN u.Holds = 0 THEN 2 ELSE 0 END)
    FROM (SELECT i.TenantId, ''P'' AS Act, i.PreparedBy AS Actor, ''fin.stmt.enter'' AS Perm
          FROM inserted AS i LEFT JOIN deleted AS d ON d.RevenueEstimateId = i.RevenueEstimateId
          WHERE d.RevenueEstimateId IS NULL OR (d.Status = ''DRAFT'' AND i.Status = ''DRAFT'')
          UNION ALL
          SELECT i.TenantId, ''A'', i.ApprovedBy, ''fin.stmt.approve''
          FROM inserted AS i JOIN deleted AS d ON d.RevenueEstimateId = i.RevenueEstimateId
          WHERE d.Status = ''DRAFT'' AND i.Status = ''APPROVED''
          UNION ALL
          SELECT i.TenantId, ''C'', NULL, ''fin.stmt.approve''
          FROM inserted AS i JOIN deleted AS d ON d.RevenueEstimateId = i.RevenueEstimateId
          WHERE d.Status = ''APPROVED'' AND i.Status = ''SUPERSEDED'') AS x
    CROSS APPLY fin.fn_ActingUser(x.TenantId, x.Perm) AS u;
    IF @bad = 1 THROW 50170, ''A revenue estimate is prepared by its preparer and approved by its approver, each the user bound to the session (ADR 0037)'', 1;
    IF @bad = 2 THROW 50171, ''Preparing a revenue estimate needs fin.stmt.enter; approving or superseding it fin.stmt.approve (ADR 0037)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
/* ---------- monthly figures ---------- */
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);
INSERT @may VALUES (N'Status'), (N'ConfirmedBy'), (N'ConfirmedOn'), (N'ReopenCount'), (N'LastReopenedBy'), (N'LastReopenedOn'), (N'LastReopenReason'),
                   (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'fin.AccountMonthlyStat') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SET @sql = N'CREATE OR ALTER TRIGGER fin.TR_AccountMonthlyStat_Actors ON fin.AccountMonthlyStat
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    IF EXISTS (SELECT 1 FROM inserted AS i LEFT JOIN deleted AS d ON d.AccountMonthlyStatId = i.AccountMonthlyStatId
               WHERE d.AccountMonthlyStatId IS NULL AND i.Status <> ''DRAFT'')
        THROW 50173, ''A monthly figure is entered as a draft and confirmed by someone else (ADR 0037)'', 1;
    DECLARE @bad INT;
    -- E the content written (a new figure or a change of its content: its author is the editor); C the confirmation;
    -- R the reopening
    SELECT @bad = MAX(CASE WHEN u.IsUser = 0 OR ISNULL(x.Actor, -1) <> u.UserId THEN 1 WHEN u.Holds = 0 THEN 2 ELSE 0 END)
    FROM (SELECT i.TenantId, i.EnteredBy AS Actor, ''fin.stats.enter'' AS Perm
          FROM inserted AS i LEFT JOIN deleted AS d ON d.AccountMonthlyStatId = i.AccountMonthlyStatId
          WHERE d.AccountMonthlyStatId IS NULL OR EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')
          UNION ALL
          SELECT i.TenantId, i.ConfirmedBy, ''fin.stats.confirm''
          FROM inserted AS i JOIN deleted AS d ON d.AccountMonthlyStatId = i.AccountMonthlyStatId
          WHERE (d.Status = ''DRAFT'' AND i.Status = ''CONFIRMED'') OR (i.ConfirmedBy IS NOT NULL AND ISNULL(d.ConfirmedBy, -1) <> i.ConfirmedBy)
          UNION ALL
          SELECT i.TenantId, i.LastReopenedBy, ''fin.stats.confirm''
          FROM inserted AS i JOIN deleted AS d ON d.AccountMonthlyStatId = i.AccountMonthlyStatId
          WHERE i.ReopenCount <> d.ReopenCount OR (i.LastReopenedBy IS NOT NULL AND ISNULL(d.LastReopenedBy, -1) <> i.LastReopenedBy)) AS x
    CROSS APPLY fin.fn_ActingUser(x.TenantId, x.Perm) AS u;
    IF @bad = 1 THROW 50170, ''A monthly balance is entered or changed by its author, confirmed by its confirmer and reopened by its reopener, each the user bound to the session (ADR 0037)'', 1;
    IF @bad = 2 THROW 50171, ''Entering a monthly balance needs fin.stats.enter; confirming or reopening it fin.stats.confirm (ADR 0037)'', 1;
    -- confirmed as entered: the confirmer changes nothing of it
    IF EXISTS (SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.AccountMonthlyStatId = i.AccountMonthlyStatId
               WHERE d.Status = ''DRAFT'' AND i.Status = ''CONFIRMED'' AND EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N'))
        THROW 50172, ''A monthly balance is confirmed as its author entered it (ADR 0037)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);
INSERT @may VALUES (N'Status'), (N'ConfirmedBy'), (N'ConfirmedOn'), (N'ReopenCount'), (N'LastReopenedBy'), (N'LastReopenedOn'), (N'LastReopenReason'),
                   (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'fin.BankFlowEntry') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SET @sql = N'CREATE OR ALTER TRIGGER fin.TR_BankFlowEntry_Actors ON fin.BankFlowEntry
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    IF EXISTS (SELECT 1 FROM inserted AS i LEFT JOIN deleted AS d ON d.BankFlowEntryId = i.BankFlowEntryId
               WHERE d.BankFlowEntryId IS NULL AND i.Status <> ''DRAFT'')
        THROW 50173, ''A bank flow is entered as a draft and confirmed by someone else (ADR 0037)'', 1;
    DECLARE @bad INT;
    SELECT @bad = MAX(CASE WHEN u.IsUser = 0 OR ISNULL(x.Actor, -1) <> u.UserId THEN 1 WHEN u.Holds = 0 THEN 2 ELSE 0 END)
    FROM (SELECT i.TenantId, i.EnteredBy AS Actor, ''fin.stats.enter'' AS Perm
          FROM inserted AS i LEFT JOIN deleted AS d ON d.BankFlowEntryId = i.BankFlowEntryId
          WHERE d.BankFlowEntryId IS NULL OR EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')
          UNION ALL
          SELECT i.TenantId, i.ConfirmedBy, ''fin.stats.confirm''
          FROM inserted AS i JOIN deleted AS d ON d.BankFlowEntryId = i.BankFlowEntryId
          WHERE (d.Status = ''DRAFT'' AND i.Status = ''CONFIRMED'') OR (i.ConfirmedBy IS NOT NULL AND ISNULL(d.ConfirmedBy, -1) <> i.ConfirmedBy)
          UNION ALL
          SELECT i.TenantId, i.LastReopenedBy, ''fin.stats.confirm''
          FROM inserted AS i JOIN deleted AS d ON d.BankFlowEntryId = i.BankFlowEntryId
          WHERE i.ReopenCount <> d.ReopenCount OR (i.LastReopenedBy IS NOT NULL AND ISNULL(d.LastReopenedBy, -1) <> i.LastReopenedBy)) AS x
    CROSS APPLY fin.fn_ActingUser(x.TenantId, x.Perm) AS u;
    IF @bad = 1 THROW 50170, ''A bank flow is entered or changed by its author, confirmed by its confirmer and reopened by its reopener, each the user bound to the session (ADR 0037)'', 1;
    IF @bad = 2 THROW 50171, ''Entering a bank flow needs fin.stats.enter; confirming or reopening it fin.stats.confirm (ADR 0037)'', 1;
    IF EXISTS (SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.BankFlowEntryId = i.BankFlowEntryId
               WHERE d.Status = ''DRAFT'' AND i.Status = ''CONFIRMED'' AND EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N'))
        THROW 50172, ''A bank flow is confirmed as its author entered it (ADR 0037)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
/* ---------- loss rates of the provision matrix ---------- */
DECLARE @may TABLE (name SYSNAME PRIMARY KEY);
INSERT @may VALUES (N'Status'), (N'PreparedBy'), (N'ApprovedBy'), (N'ApprovedOn'), (N'UpdatedAt'), (N'UpdatedBy');
DECLARE @fi NVARCHAR(MAX), @fd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @fi = STRING_AGG(CONVERT(NVARCHAR(MAX), N'i.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id),
       @fd = STRING_AGG(CONVERT(NVARCHAR(MAX), N'd.' + QUOTENAME(c.name)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'fin.ReceivableLossRate') AND c.is_computed = 0 AND TYPE_NAME(c.system_type_id) <> N'timestamp'
  AND c.name NOT IN (SELECT name FROM @may);
SET @sql = N'CREATE OR ALTER TRIGGER fin.TR_ReceivableLossRate_Actors ON fin.ReceivableLossRate
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted WHERE Status = ''APPROVED'')
        THROW 50173, ''An approved loss rate does not change and is not deleted; a change is a new rate with a later EffectiveFrom (ADR 0037)'', 1;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    IF EXISTS (SELECT 1 FROM inserted AS i LEFT JOIN deleted AS d ON d.ReceivableLossRateId = i.ReceivableLossRateId
               WHERE d.ReceivableLossRateId IS NULL AND i.Status <> ''DRAFT'')
        THROW 50173, ''A loss rate is written as a draft and approved by someone else (ADR 0037)'', 1;
    IF EXISTS (SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.ReceivableLossRateId = i.ReceivableLossRateId
               WHERE d.Status = ''DRAFT'' AND i.Status <> ''DRAFT''
                 AND (ISNULL(i.PreparedBy, -1) <> ISNULL(d.PreparedBy, -1) OR EXISTS (SELECT ' + @fi + N' EXCEPT SELECT ' + @fd + N')))
        THROW 50172, ''A loss rate is approved as its preparer wrote it (ADR 0037)'', 1;
    DECLARE @bad INT;
    -- P a draft written (but a default of the pack, inserted without a preparer); A the approval
    SELECT @bad = MAX(CASE WHEN u.IsUser = 0 OR ISNULL(x.Actor, -1) <> u.UserId THEN 1 WHEN u.Holds = 0 THEN 2 ELSE 0 END)
    FROM (SELECT i.TenantId, i.PreparedBy AS Actor, ''fin.formula.manage'' AS Perm
          FROM inserted AS i LEFT JOIN deleted AS d ON d.ReceivableLossRateId = i.ReceivableLossRateId
          WHERE (d.ReceivableLossRateId IS NULL AND NOT (i.SeedKey IS NOT NULL AND i.PreparedBy IS NULL))
             OR (d.Status = ''DRAFT'' AND i.Status = ''DRAFT'')
          UNION ALL
          SELECT i.TenantId, i.ApprovedBy, ''fin.formula.approve''
          FROM inserted AS i JOIN deleted AS d ON d.ReceivableLossRateId = i.ReceivableLossRateId
          WHERE d.Status = ''DRAFT'' AND i.Status = ''APPROVED'') AS x
    CROSS APPLY fin.fn_ActingUser(x.TenantId, x.Perm) AS u;
    IF @bad = 1 THROW 50170, ''A loss rate is prepared by its preparer and approved by its approver, each the user bound to the session (ADR 0037)'', 1;
    IF @bad = 2 THROW 50171, ''Preparing a loss rate needs fin.formula.manage, approving it fin.formula.approve (ADR 0037)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
/* ---------- lender ratings and product lines once used ---------- */
CREATE OR ALTER TRIGGER fin.TR_LenderRating_Frozen ON fin.LenderRating
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    -- confirmed against the lender's letter, or read by an endorsed assessment's calibration (052)
    IF EXISTS (SELECT 1 FROM deleted AS d
               WHERE d.VerifiedBy IS NOT NULL
                  OR EXISTS (SELECT 1 FROM fin.CreditAssessment AS a
                             WHERE a.TenantId = d.TenantId AND a.CompanyId = d.CompanyId AND a.EndorsedBy IS NOT NULL
                               AND a.EndorsedLastRatingDate >= d.RatingDate))
        THROW 50173, 'A lender rating confirmed against the lender''s letter, or read by an endorsed assessment, does not change and is not deleted (ADR 0037)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_CompanyProductLine_Frozen ON fin.CompanyProductLine
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    -- the lines of a year an approved assessment read (its statement's fiscal year, 046) stay as it read them
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, CompanyId, FiscalYear FROM inserted UNION SELECT TenantId, CompanyId, FiscalYear FROM deleted) AS r
               WHERE EXISTS (SELECT 1 FROM fin.CreditAssessment AS a
                             JOIN fin.FinancialStatement AS s ON s.TenantId = a.TenantId AND s.FinancialStatementId = a.StatementId
                             WHERE a.TenantId = r.TenantId AND a.CompanyId = r.CompanyId AND a.IsTrial = 0 AND a.Status IN ('APPROVED', 'SUPERSEDED')
                               AND s.FiscalYear = r.FiscalYear))
        THROW 50173, 'The product lines of a year that an approved assessment read do not change; reassess in a new assessment of a new statement version (ADR 0037)', 1;
END;
GO

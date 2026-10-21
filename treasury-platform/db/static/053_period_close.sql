/* 053_period_close.sql — the optional close of a company's reporting periods (docs/38 item 2, ADR 0031, FR-FIN-049,
   BR-FIN-050).

   Approved statements are already frozen (045) and corrected by a new version; confirmed monthly figures are frozen
   and reopened with a reason (052). A company that closes its books adds one more guarantee: once a period is closed,
   nothing of it is added, changed or removed, not even a new version or a reopening, until someone other than the one
   who closed it reopens the period with a reason.
     fin.fn_PeriodLockedThrough      the last closed day of a company (the latest LOCKED row), or NULL.
     fin.usp_LockReportingPeriod     closes a company's periods through a date, by a holder of fin.period.lock, with a
                                     reason; only when every actual statement of the company through that date is
                                     approved (or superseded) and every monthly balance and bank flow is confirmed,
                                     the date is not in the future and not before the current close. Audited
                                     (PERIOD_LOCKED, high severity).
     fin.usp_ReopenReportingPeriod   reopens the latest close of a company, by another holder of fin.period.lock, with
                                     a reason. Audited (PERIOD_REOPENED, high severity).
     triggers                        an actual statement (a new one, a new version, a status change), a monthly balance
                                     or a bank flow dated through the closed day is refused (50096). A budget is a plan,
                                     not a figure of the period, and is not closed.
     fin.v_ReportingPeriodStatus     each company's current close.
   Since ADR 0037 (the internal review of 2026-10-21, lens E, findings 8 and 23) the close also reaches what changes a
   closed period indirectly, where the row carries a date tied to a period (50096):
     - a statement of a unit of a holding's consolidated statement: once the holding's period is closed through the
       end of an approved consolidated statement, the unit's actual statements of that period (its standalone
       statement named on the unit, or any with a period end within the consolidated period) are closed too;
     - an official assessment (not a trial) of an actual statement of a closed period: none is added, and none moves
       from one status to another (submitted, approved, superseded); a trial stays possible, and the endorsement of an
       approved one too (it changes no figure);
     - a revenue estimate of a fiscal year that ends in a closed period (the year Y ends on the last day of the
       company's fiscal year end month of Y);
     - a lender rating dated in a closed period;
     - the product lines of a fiscal year that ends in a closed period;
     - a loss rate of the provision matrix effective on or before the latest closed day of any company of the tenant
       (the rates are the tenant's, the statements the companies'): a new rate takes effect after the close.
   The close itself has no second person: it only freezes, and its reopening, which unfreezes, is by someone else (an
   open point of ADR 0037). Monthly figures of a unit are closed by the unit's own close, not by the holding's.
   The application cannot write fin.ReportingPeriodLock. Errors: 50096 the period is closed, 50097 the close or the
   reopening is refused. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER FUNCTION fin.fn_PeriodLockedThrough (@TenantId INT, @CompanyId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT MAX(l.LockedThrough) AS LockedThrough
    FROM fin.ReportingPeriodLock AS l
    WHERE l.TenantId = @TenantId AND l.CompanyId = @CompanyId AND l.Status = 'LOCKED';
GO
CREATE OR ALTER TRIGGER fin.TR_FinancialStatement_PeriodLock ON fin.FinancialStatement
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, CompanyId, PeriodEnd, Nature FROM inserted
                     UNION ALL SELECT TenantId, CompanyId, PeriodEnd, Nature FROM deleted) AS r
               CROSS APPLY fin.fn_PeriodLockedThrough(r.TenantId, r.CompanyId) AS p
               WHERE r.Nature = 'ACTUAL' AND r.PeriodEnd <= p.LockedThrough)
        THROW 50096, 'The reporting period of this statement is closed; reopen the period to add or change a statement or a version (BR-FIN-050)', 1;
    -- a unit's statement of a period its holding closed with an approved consolidated statement that includes it (ADR 0037)
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, FinancialStatementId, CompanyId, PeriodEnd, Nature FROM inserted
                     UNION ALL SELECT TenantId, FinancialStatementId, CompanyId, PeriodEnd, Nature FROM deleted) AS r
               JOIN fin.ConsolidationMember AS m ON m.TenantId = r.TenantId AND m.MemberCompanyId = r.CompanyId AND m.Role <> 'PARENT'
               JOIN fin.FinancialStatement AS cs ON cs.TenantId = m.TenantId AND cs.FinancialStatementId = m.StatementId
               CROSS APPLY fin.fn_PeriodLockedThrough(cs.TenantId, cs.CompanyId) AS hp
               WHERE r.Nature = 'ACTUAL' AND cs.Nature = 'ACTUAL' AND cs.Status IN ('APPROVED', 'SUPERSEDED') AND cs.PeriodEnd <= hp.LockedThrough
                 AND (m.MemberStatementId = r.FinancialStatementId
                      OR (r.PeriodEnd <= cs.PeriodEnd AND r.PeriodEnd > ISNULL(cs.PeriodStart, DATEADD(YEAR, -1, cs.PeriodEnd)))))
        THROW 50096, 'The holding closed the period of a consolidated statement that includes this company: its statements of that period are closed too (ADR 0037)', 1;
END;
GO
-- An official assessment of a statement of a closed period is not added and does not change status (ADR 0037).
CREATE OR ALTER TRIGGER fin.TR_CreditAssessment_PeriodLock ON fin.CreditAssessment
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM inserted AS i
               LEFT JOIN deleted AS d ON d.CreditAssessmentId = i.CreditAssessmentId
               JOIN fin.FinancialStatement AS s ON s.TenantId = i.TenantId AND s.FinancialStatementId = i.StatementId
               CROSS APPLY fin.fn_PeriodLockedThrough(s.TenantId, s.CompanyId) AS p
               WHERE i.IsTrial = 0 AND s.Nature = 'ACTUAL' AND s.PeriodEnd <= p.LockedThrough
                 AND (d.CreditAssessmentId IS NULL OR d.Status <> i.Status OR d.StatementId <> i.StatementId OR d.IsTrial <> i.IsTrial))
        THROW 50096, 'The reporting period of this statement is closed: an official assessment of it is not added, submitted, approved or superseded until the period is reopened (ADR 0037)', 1;
END;
GO
-- A revenue estimate of a fiscal year that ends in a closed period (ADR 0037).
CREATE OR ALTER TRIGGER fin.TR_RevenueEstimate_PeriodLock ON fin.RevenueEstimate
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, CompanyId, FiscalYear FROM inserted UNION ALL SELECT TenantId, CompanyId, FiscalYear FROM deleted) AS r
               JOIN org.Company AS c ON c.TenantId = r.TenantId AND c.CompanyId = r.CompanyId
               CROSS APPLY fin.fn_PeriodLockedThrough(r.TenantId, r.CompanyId) AS p
               WHERE EOMONTH(DATEFROMPARTS(r.FiscalYear, c.FiscalYearEndMonth, 1)) <= p.LockedThrough)
        THROW 50096, 'The fiscal year of this revenue estimate ends in a closed period; reopen the period first (ADR 0037)', 1;
END;
GO
-- A lender rating dated in a closed period (ADR 0037).
CREATE OR ALTER TRIGGER fin.TR_LenderRating_PeriodLock ON fin.LenderRating
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, CompanyId, RatingDate FROM inserted UNION ALL SELECT TenantId, CompanyId, RatingDate FROM deleted) AS r
               CROSS APPLY fin.fn_PeriodLockedThrough(r.TenantId, r.CompanyId) AS p
               WHERE r.RatingDate <= p.LockedThrough)
        THROW 50096, 'This lender rating is dated in a closed period; reopen the period first (ADR 0037)', 1;
END;
GO
-- The product lines of a fiscal year that ends in a closed period (ADR 0037).
CREATE OR ALTER TRIGGER fin.TR_CompanyProductLine_PeriodLock ON fin.CompanyProductLine
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, CompanyId, FiscalYear FROM inserted UNION ALL SELECT TenantId, CompanyId, FiscalYear FROM deleted) AS r
               JOIN org.Company AS c ON c.TenantId = r.TenantId AND c.CompanyId = r.CompanyId
               CROSS APPLY fin.fn_PeriodLockedThrough(r.TenantId, r.CompanyId) AS p
               WHERE EOMONTH(DATEFROMPARTS(r.FiscalYear, c.FiscalYearEndMonth, 1)) <= p.LockedThrough)
        THROW 50096, 'The fiscal year of these product lines ends in a closed period; reopen the period first (ADR 0037)', 1;
END;
GO
-- A loss rate effective on or before the latest closed day of a company of the tenant (ADR 0037).
CREATE OR ALTER TRIGGER fin.TR_ReceivableLossRate_PeriodLock ON fin.ReceivableLossRate
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, EffectiveFrom FROM inserted UNION ALL SELECT TenantId, EffectiveFrom FROM deleted) AS r
               WHERE r.EffectiveFrom <= (SELECT MAX(l.LockedThrough) FROM fin.ReportingPeriodLock AS l WHERE l.TenantId = r.TenantId AND l.Status = 'LOCKED'))
        THROW 50096, 'A company of the tenant closed a period this loss rate would apply to; a new rate takes effect after the close (ADR 0037)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_BankFlowEntry_PeriodLock ON fin.BankFlowEntry
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, CompanyId, MonthEnd FROM inserted UNION ALL SELECT TenantId, CompanyId, MonthEnd FROM deleted) AS r
               CROSS APPLY fin.fn_PeriodLockedThrough(r.TenantId, r.CompanyId) AS p
               WHERE r.MonthEnd <= p.LockedThrough)
        THROW 50096, 'The reporting period of this bank flow is closed; reopen the period first (BR-FIN-050)', 1;
END;
GO
CREATE OR ALTER TRIGGER fin.TR_AccountMonthlyStat_PeriodLock ON fin.AccountMonthlyStat
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT TenantId, BankAccountId, MonthEnd FROM inserted UNION ALL SELECT TenantId, BankAccountId, MonthEnd FROM deleted) AS r
               JOIN acc.BankAccount AS b ON b.TenantId = r.TenantId AND b.BankAccountId = r.BankAccountId
               CROSS APPLY fin.fn_PeriodLockedThrough(r.TenantId, b.CompanyId) AS p
               WHERE r.MonthEnd <= p.LockedThrough)
        THROW 50096, 'The reporting period of this monthly balance is closed; reopen the period first (BR-FIN-050)', 1;
END;
GO
CREATE OR ALTER PROCEDURE fin.usp_LockReportingPeriod
    @CompanyId     BIGINT,
    @LockedThrough DATE,
    @Reason        NVARCHAR(500),
    @LockId        BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @LockId = NULL;
    DECLARE @t INT = CAST(SESSION_CONTEXT(N'TenantId') AS INT), @user BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), @current DATE,
            @open INT, @after NVARCHAR(800);
    IF @t IS NULL OR @user IS NULL OR NOT EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@t, 1))
        THROW 50097, 'A period is closed by a user bound to its tenant', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.period.lock'))
        THROW 50097, 'The permission fin.period.lock is required', 1;
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 50097, 'A period is closed with a reason', 1;
    IF @LockedThrough IS NULL OR @LockedThrough > CAST(SYSUTCDATETIME() AS DATE) THROW 50097, 'A period is closed through a day that has passed', 1;
    BEGIN TRANSACTION;
    IF NOT EXISTS (SELECT 1 FROM org.Company WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @t AND CompanyId = @CompanyId)
        THROW 50097, 'No company with this id for this tenant', 1;
    SET @current = (SELECT LockedThrough FROM fin.fn_PeriodLockedThrough(@t, @CompanyId));
    IF @current >= @LockedThrough THROW 50097, 'The company''s periods are already closed through this day or later', 1;
    SET @open = (SELECT COUNT(*) FROM fin.FinancialStatement WITH (UPDLOCK, HOLDLOCK)
                 WHERE TenantId = @t AND CompanyId = @CompanyId AND Nature = 'ACTUAL' AND PeriodEnd <= @LockedThrough
                   AND Status NOT IN ('APPROVED', 'SUPERSEDED'))
              + (SELECT COUNT(*) FROM fin.BankFlowEntry WITH (UPDLOCK, HOLDLOCK)
                 WHERE TenantId = @t AND CompanyId = @CompanyId AND MonthEnd <= @LockedThrough AND Status <> 'CONFIRMED')
              + (SELECT COUNT(*) FROM fin.AccountMonthlyStat AS m WITH (UPDLOCK, HOLDLOCK)
                 JOIN acc.BankAccount AS b ON b.TenantId = m.TenantId AND b.BankAccountId = m.BankAccountId
                 WHERE m.TenantId = @t AND b.CompanyId = @CompanyId AND m.MonthEnd <= @LockedThrough AND m.Status <> 'CONFIRMED');
    IF @open > 0 THROW 50097, 'A period is closed once every statement of it is approved and every monthly balance and bank flow confirmed', 1;
    INSERT fin.ReportingPeriodLock (TenantId, CompanyId, LockedThrough, Status, LockReason, LockedBy, LockedOn, CreatedBy)
    VALUES (@t, @CompanyId, @LockedThrough, 'LOCKED', LTRIM(RTRIM(@Reason)), @user, SYSUTCDATETIME(), @user);
    SET @LockId = SCOPE_IDENTITY();
    SET @after = (SELECT CONVERT(CHAR(10), @LockedThrough, 23) AS lockedThrough, LTRIM(RTRIM(@Reason)) AS reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC aud.usp_WriteEvent @TenantId = @t, @Action = 'PERIOD_LOCKED', @Category = 'TREASURY', @ActorType = 'USER', @ActorUserId = @user,
         @Severity = 'HIGH', @EntityType = 'org.Company', @EntityId = @CompanyId, @AfterJson = @after;
    COMMIT;
END;
GO
CREATE OR ALTER PROCEDURE fin.usp_ReopenReportingPeriod
    @LockId BIGINT,
    @Reason NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @t INT = CAST(SESSION_CONTEXT(N'TenantId') AS INT), @user BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
            @company BIGINT, @through DATE, @status VARCHAR(10), @locker BIGINT, @after NVARCHAR(800);
    IF @t IS NULL OR @user IS NULL OR NOT EXISTS (SELECT 1 FROM sec.fn_BoundAsUser(@t, 1))
        THROW 50097, 'A period is reopened by a user bound to its tenant', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@t, @user, 'fin.period.lock'))
        THROW 50097, 'The permission fin.period.lock is required', 1;
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 50097, 'A period is reopened with a reason', 1;
    BEGIN TRANSACTION;
    SELECT @company = CompanyId, @through = LockedThrough, @status = Status, @locker = LockedBy
    FROM fin.ReportingPeriodLock WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @t AND ReportingPeriodLockId = @LockId;
    IF @status IS NULL THROW 50097, 'No period close with this id for this tenant', 1;
    IF @status <> 'LOCKED' THROW 50097, 'This close is already reopened', 1;
    IF @user = @locker THROW 50097, 'A period is reopened by someone other than the one who closed it', 1;
    IF EXISTS (SELECT 1 FROM fin.ReportingPeriodLock WHERE TenantId = @t AND CompanyId = @company AND Status = 'LOCKED' AND LockedThrough > @through)
        THROW 50097, 'Reopen the latest close of the company first', 1;
    UPDATE fin.ReportingPeriodLock
    SET Status = 'REOPENED', ReopenedBy = @user, ReopenedOn = SYSUTCDATETIME(), ReopenReason = LTRIM(RTRIM(@Reason)), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @user
    WHERE TenantId = @t AND ReportingPeriodLockId = @LockId;
    SET @after = (SELECT CONVERT(CHAR(10), @through, 23) AS lockedThrough, LTRIM(RTRIM(@Reason)) AS reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC aud.usp_WriteEvent @TenantId = @t, @Action = 'PERIOD_REOPENED', @Category = 'TREASURY', @ActorType = 'USER', @ActorUserId = @user,
         @Severity = 'HIGH', @EntityType = 'org.Company', @EntityId = @company, @AfterJson = @after;
    COMMIT;
END;
GO
CREATE OR ALTER VIEW fin.v_ReportingPeriodStatus
AS
SELECT l.TenantId, l.CompanyId, l.ReportingPeriodLockId, l.LockedThrough, l.LockReason, l.LockedBy, l.LockedOn
FROM fin.ReportingPeriodLock AS l
WHERE l.Status = 'LOCKED'
  AND NOT EXISTS (SELECT 1 FROM fin.ReportingPeriodLock AS x
                  WHERE x.TenantId = l.TenantId AND x.CompanyId = l.CompanyId AND x.Status = 'LOCKED' AND x.LockedThrough > l.LockedThrough);
GO
GRANT EXECUTE ON fin.usp_LockReportingPeriod TO [tp_app];
GRANT EXECUTE ON fin.usp_ReopenReportingPeriod TO [tp_app];
GRANT SELECT ON fin.v_ReportingPeriodStatus TO [tp_app];
DENY INSERT, UPDATE, DELETE ON fin.ReportingPeriodLock TO [tp_app];
GO

/* ============================================================================
   BankFas - 039: document numbering without gaps (FR-PLT-026, BR-PLT-010, BR-ORG-001, AC-PLT-3; O-12 in
   tools/dbgen/erd_open_items.py, owner decision 2026-10-12: requests and proformas are gap-free, Q-PLT-08)

   A number comes from one counter row per (tenant, definition, company when the scope is COMPANY, period). The
   allocation locks that row inside the caller's own transaction and writes the issued number in the same
   transaction, so a rollback takes the number back with the business row: no number is lost and none is taken
   twice. Two callers asking at once are serialised on the row lock.
     cfg.usp_AllocateNumber   the next number of a sequence, formatted, recorded in cfg.NumberIssue. A GAP_FREE
                              sequence is refused outside a transaction (50029), because a number committed alone
                              would leave a gap when the business insert then fails.
     cfg.usp_VoidNumber       a number becomes VOID with a reason and is never issued again.
   Both run as the caller (no EXECUTE AS): the row filters keep them to the bound tenant, and the ownership chain
   lets them write the counters the application role may no longer write directly (DENYs at the end).

   Pattern tags: {seq} or {seq:000} (the zeros give the minimum width; a longer number widens, never truncates,
   BR-PLT-010), {erp} (the company's normalised ERP code; COMPANY scope only), {yy} and {yyyy} (the period's year).
   Periods: CALENDAR_YEAR, the year of @OnDate; FISCAL_YEAR (COMPANY scope), the year in which the company's fiscal
   year containing @OnDate ends (FiscalYearEndMonth and Day, BR-ORG-004); NONE, one counter. @OnDate is the date in
   the tenant's time zone, which the application passes; without it the UTC date is used.
   A definition's pattern is checked when it is written (trigger, 50031), and the request (req:<TypeCode>) and
   PROFORMA definitions must be GAP_FREE. BR-WFL-013 writes request patterns as {prefix}-{yy}-{seq:0000}: each request
   type has its own definition, so the pack writes the prefix as text (LCP-{yy}-{seq:0000}); there is no {prefix} tag.

   Errors: 50029 gap-free allocation outside a transaction, 50030 no active definition or no company or ERP code
   for it, 50031 invalid pattern, a request or proforma sequence that allows gaps, or a number longer than 60 characters, 50032 number not issued or reason missing.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
-- The pattern with every known tag removed: a valid pattern leaves no brace behind. One {seq} tag is required.
CREATE OR ALTER FUNCTION cfg.fn_NumberPatternOk (@Pattern NVARCHAR(100), @ScopeLevel VARCHAR(7))
RETURNS TABLE
AS RETURN
    SELECT 1 AS Ok
    FROM (SELECT REPLACE(REPLACE(REPLACE(REPLACE(@Pattern, N'{erp}', N''), N'{yyyy}', N''), N'{yy}', N''), N'{seq}', N'') AS Rest,
                 (LEN(@Pattern) - LEN(REPLACE(@Pattern, N'{seq', N''))) / 4 AS SeqTags) AS p
    CROSS APPLY (SELECT CHARINDEX(N'{seq:', p.Rest) AS At) AS s
    CROSS APPLY (SELECT CASE WHEN s.At = 0 THEN p.Rest
                             ELSE STUFF(p.Rest, s.At, CHARINDEX(N'}', p.Rest + N'}', s.At) - s.At + 1, N'') END AS Rest2,
                        CASE WHEN s.At = 0 THEN N''
                             ELSE SUBSTRING(p.Rest, s.At + 5, CHARINDEX(N'}', p.Rest + N'}', s.At) - s.At - 5) END AS Zeros) AS z
    WHERE p.SeqTags = 1
      AND z.Rest2 NOT LIKE N'%[{}]%'
      AND (s.At = 0 OR (CHARINDEX(N'}', p.Rest, s.At) > 0 AND LEN(z.Zeros) BETWEEN 1 AND 18 AND z.Zeros NOT LIKE N'%[^0]%'))
      AND (@ScopeLevel = 'COMPANY' OR @Pattern NOT LIKE N'%{erp}%');
GO
CREATE OR ALTER TRIGGER cfg.TR_NumberSequenceDefinition_Pattern ON cfg.NumberSequenceDefinition
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted AS i WHERE NOT EXISTS (SELECT 1 FROM cfg.fn_NumberPatternOk(i.Pattern, i.ScopeLevel)))
        THROW 50031, 'Invalid numbering pattern: one {seq} or {seq:000} tag, and only {erp} (company scope), {yy} and {yyyy}', 1;
    -- Owner decision 2026-10-12 (Q-PLT-08): request numbers (req:<TypeCode>, BR-WFL-013) and proforma numbers are gap-free.
    IF EXISTS (SELECT 1 FROM inserted WHERE (SequenceKey = 'PROFORMA' OR SequenceKey LIKE 'req:%') AND GapPolicy <> 'GAP_FREE')
        THROW 50031, 'Request and proforma numbers are gap-free', 1;
END;
GO
CREATE OR ALTER PROCEDURE cfg.usp_AllocateNumber
    @SequenceKey   VARCHAR(50),
    @CompanyId     BIGINT = NULL,
    @OnDate        DATE = NULL,
    @EntityType    VARCHAR(60) = NULL,
    @EntityId      BIGINT = NULL,
    @IssuedNumber  NVARCHAR(60) = NULL OUTPUT,
    @NumberIssueId BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @IssuedNumber = NULL, @NumberIssueId = NULL;
    DECLARE @tenant INT, @def BIGINT, @pattern NVARCHAR(100), @scope VARCHAR(7), @basis VARCHAR(13), @gap VARCHAR(10),
            @minWidth INT, @erp NVARCHAR(20), @fyMonth TINYINT, @fyDay TINYINT, @year INT, @period VARCHAR(10),
            @seqId BIGINT, @value BIGINT, @own BIT = 0, @digits NVARCHAR(20), @width INT, @at INT, @close INT,
            @fyEnd DATE, @number NVARCHAR(200);
    SET @OnDate = ISNULL(@OnDate, CAST(SYSUTCDATETIME() AS DATE));

    SELECT @tenant = TenantId, @def = NumberSequenceDefinitionId, @pattern = Pattern, @scope = ScopeLevel,
           @basis = PeriodBasis, @gap = GapPolicy, @minWidth = MinWidth
    FROM cfg.NumberSequenceDefinition
    WHERE SequenceKey = @SequenceKey AND IsActive = 1;               -- the row filter shows the bound tenant's only
    IF @def IS NULL THROW 50030, 'No active numbering definition with this key for this tenant', 1;
    IF @gap = 'GAP_FREE' AND @@TRANCOUNT = 0
        THROW 50029, 'A gap-free number is allocated inside the transaction that writes the numbered row', 1;
    IF @scope = 'COMPANY'
    BEGIN
        SELECT @erp = ErpCodeNormalized, @fyMonth = FiscalYearEndMonth, @fyDay = FiscalYearEndDay
        FROM org.Company WHERE TenantId = @tenant AND CompanyId = @CompanyId AND Status <> 'ARCHIVED';
        IF @@ROWCOUNT = 0 THROW 50030, 'A company of this tenant is required for this sequence', 1;
        IF @pattern LIKE N'%{erp}%' AND @erp IS NULL THROW 50030, 'The company has no ERP code for this sequence', 1;
    END
    ELSE
        SET @CompanyId = NULL;

    IF @basis = 'FISCAL_YEAR'
    BEGIN
        SET @fyEnd = DATEFROMPARTS(YEAR(@OnDate), @fyMonth, 1);
        SET @fyEnd = CASE WHEN @fyDay IS NULL OR @fyDay > DAY(EOMONTH(@fyEnd)) THEN EOMONTH(@fyEnd)
                          ELSE DATEFROMPARTS(YEAR(@OnDate), @fyMonth, @fyDay) END;
        SET @year = CASE WHEN @OnDate <= @fyEnd THEN YEAR(@OnDate) ELSE YEAR(@OnDate) + 1 END;
        SET @period = CONCAT('FY', @year);
    END
    ELSE
    BEGIN
        SET @year = YEAR(@OnDate);
        SET @period = CASE WHEN @basis = 'NONE' THEN 'ALL' ELSE CAST(@year AS VARCHAR(4)) END;
    END;

    IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @own = 1; END ELSE SAVE TRANSACTION sp_AllocateNumber;
    BEGIN TRY
        -- The counter row stays locked until the caller's transaction ends; a missing row is created under a key
        -- range lock, so two first allocations of a period cannot both create it.
        SELECT @seqId = NumberSequenceId, @value = NextValue
        FROM cfg.NumberSequence WITH (UPDLOCK, HOLDLOCK)
        WHERE TenantId = @tenant AND DefinitionId = @def AND PeriodKey = @period
          AND ((@CompanyId IS NULL AND CompanyId IS NULL) OR CompanyId = @CompanyId);
        IF @seqId IS NULL
        BEGIN
            INSERT cfg.NumberSequence (TenantId, DefinitionId, CompanyId, PeriodKey, NextValue)
            VALUES (@tenant, @def, @CompanyId, @period, 1);
            SELECT @seqId = SCOPE_IDENTITY(), @value = 1;
        END;
        UPDATE cfg.NumberSequence SET NextValue = @value + 1 WHERE NumberSequenceId = @seqId;

        -- Format: {seq} or {seq:000}, widened rather than truncated; then {erp}, {yyyy}, {yy}.
        SET @at = CHARINDEX(N'{seq', @pattern);
        SET @close = CHARINDEX(N'}', @pattern, @at);
        SET @width = CASE WHEN SUBSTRING(@pattern, @at, 5) = N'{seq:' THEN @close - @at - 5 ELSE ISNULL(@minWidth, 1) END;
        SET @digits = CAST(@value AS NVARCHAR(20));
        IF LEN(@digits) < @width SET @digits = RIGHT(REPLICATE(N'0', @width) + @digits, @width);
        SET @number = STUFF(@pattern, @at, @close - @at + 1, @digits);
        SET @number = REPLACE(REPLACE(REPLACE(@number, N'{erp}', ISNULL(@erp, N'')),
                                      N'{yyyy}', CAST(@year AS NVARCHAR(4))), N'{yy}', RIGHT(CAST(@year AS NVARCHAR(4)), 2));
        IF LEN(@number) > 60 THROW 50031, 'The formatted number is longer than 60 characters', 1;
        SET @IssuedNumber = @number;

        INSERT cfg.NumberIssue (TenantId, SequenceId, SeqValue, IssuedNumber, EntityType, EntityId, CreatedBy)
        VALUES (@tenant, @seqId, @value, @IssuedNumber, @EntityType, @EntityId, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
        SET @NumberIssueId = SCOPE_IDENTITY();
        IF @own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_AllocateNumber;   -- undo this procedure only
        SELECT @IssuedNumber = NULL, @NumberIssueId = NULL;
        THROW;
    END CATCH;
END;
GO
-- A documented cancellation: the number stays taken (BR-PLT-010). The application checks cfg.numbering.manage.
CREATE OR ALTER PROCEDURE cfg.usp_VoidNumber
    @NumberIssueId BIGINT,
    @Reason        NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    IF @Reason IS NULL OR LTRIM(@Reason) = N'' THROW 50032, 'A reason is required to void a number', 1;
    UPDATE cfg.NumberIssue
       SET Status = 'VOID', VoidReason = @Reason, VoidedAt = SYSUTCDATETIME(), VoidedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
     WHERE NumberIssueId = @NumberIssueId AND Status = 'ISSUED';
    IF @@ROWCOUNT = 0 THROW 50032, 'No issued number with this id for this tenant', 1;
END;
GO
GRANT EXECUTE ON cfg.usp_AllocateNumber TO [tp_app];
GRANT EXECUTE ON cfg.usp_VoidNumber TO [tp_app];
GO
-- Counters and issued numbers change only through the procedures above, which reach them through the ownership
-- chain. These run after the generated grants (007), which give tp_app INSERT and UPDATE on both tables.
DENY INSERT, UPDATE ON [cfg].[NumberSequence] TO [tp_app];
DENY INSERT ON [cfg].[NumberIssue] TO [tp_app];
DENY UPDATE ON [cfg].[NumberIssue]([SequenceId], [SeqValue], [IssuedNumber], [Status], [VoidReason], [VoidedAt], [VoidedBy]) TO [tp_app];
GO

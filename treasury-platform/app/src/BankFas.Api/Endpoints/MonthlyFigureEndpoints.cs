using System.Data;
using System.Globalization;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record AccountStatInput(Guid? Account, string? Month, decimal? AvgDailyBalance, decimal? MinBalance, decimal? EndBalance, string? SourceKind,
    string? SourceRef, string? Note, Guid? Document);
public sealed record AccountStatsRequest(AccountStatInput[]? Items);
public sealed record FigureIdsRequest(Guid[]? Ids);
public sealed record FigureReasonRequest(string? Reason);
public sealed record BankFlowRequest(Guid? Company, Guid? Institution, Guid? Facility, string? Month, string? Kind, decimal? Amount, string? Currency, string? BasisNote,
    Guid? Document);
public sealed record PeriodLockRequest(string? LockedThrough, string? Reason);

/// <summary>
/// The monthly figures of the companies (spec 12 section 6, FR-FIN-008, 009, 045, 049; FR-ACC-021; BR-FIN-005, 006, 016,
/// 048, 050; V-FIN-02): the average, minimum and closing balance of an account for a month, and the liquidity routed to
/// a bank, entered as drafts by a holder of fin.stats.enter and confirmed as entered by another user with
/// fin.stats.confirm (the database checks both, 058). A confirmed figure is frozen (052) and reopened with a reason by
/// someone other than its author through fin.usp_ReopenMonthlyFigure, which writes its own audit row. A company's
/// periods are closed and reopened through 053; a closed month refuses its figures. A treasury employee sees the
/// figures of the companies in scope, every author's, so a month's gaps show in one grid (OQ-12).
/// </summary>
public static class MonthlyFigureEndpoints
{
    private const string StatsEnter = "fin.stats.enter";
    private const string StatsConfirm = "fin.stats.confirm";
    private const string PeriodLock = "fin.period.lock";
    private static readonly string[] Sources = ["BANK_STATEMENT", "BANK_NOTICE", "INTERNAL_CALC"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/account-stats", StatsAsync);
        api.MapPut("/account-stats", SaveStatsAsync);
        api.MapPost("/account-stats/actions/confirm", ConfirmStatsAsync);
        api.MapPost("/account-stats/{id:guid}/actions/reopen", (Guid id, FigureReasonRequest b, HttpContext http, SqlConnectionFactory db) => ReopenAsync("BALANCE", id, b, http, db));
        api.MapGet("/bank-flows", FlowsAsync);
        api.MapPost("/bank-flows", AddFlowAsync);
        api.MapPatch("/bank-flows/{id:guid}", ChangeFlowAsync);
        api.MapPost("/bank-flows/actions/confirm", ConfirmFlowsAsync);
        api.MapPost("/bank-flows/{id:guid}/actions/reopen", (Guid id, FigureReasonRequest b, HttpContext http, SqlConnectionFactory db) => ReopenAsync("FLOW", id, b, http, db));
        api.MapGet("/bank-flows/performance", PerformanceAsync);
        api.MapGet("/reporting-periods", PeriodsAsync);
        api.MapPost("/reporting-periods/{company:guid}/actions/lock", LockAsync);
        api.MapPost("/reporting-periods/{company:guid}/actions/reopen", ReopenPeriodAsync);
    }

    internal static string? D(DateTime? d) => FacilityEndpoints.D(d);

    /// <summary>A month as YYYY-MM or a month end YYYY-MM-DD; the stored day is the month's last (DR-37).</summary>
    internal static DateTime Month(string? text, string label = "month")
    {
        var t = text?.Trim() ?? "";
        if (DateTime.TryParseExact(t, "yyyy-MM", CultureInfo.InvariantCulture, DateTimeStyles.None, out var m)) return m.AddMonths(1).AddDays(-1);
        if (DateTime.TryParseExact(t, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) && d.AddDays(1).Day == 1) return d;
        throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {label} is YYYY-MM or the last day of the month.");
    }

    private static DateTime EndOfMonth(DateTime d) => new DateTime(d.Year, d.Month, 1).AddMonths(1).AddDays(-1);

    private static DateTime Today(TimeProvider clock) => clock.GetUtcNow().UtcDateTime.Date;

    // ---------- monthly balances ----------

    private sealed record AccountRow(long BankAccountId, Guid PublicId, long CompanyId, Guid CompanyPublicId, string CompanyNameAr, string? CompanyNameEn, string InstitutionCode,
        string AccountNoMask, string? Nickname, string Currency, string Status, DateTime? OpenedOn, DateTime? ClosedOn);

    private sealed class StatRow
    {
        public long AccountMonthlyStatId { get; init; }
        public Guid PublicId { get; init; }
        public long BankAccountId { get; init; }
        public DateTime MonthEnd { get; init; }
        public decimal AvgDailyBalance { get; init; }
        public decimal? MinBalance { get; init; }
        public decimal? EndBalance { get; init; }
        public string SourceKind { get; init; } = "";
        public string? SourceRef { get; init; }
        public string? Note { get; init; }
        public string Status { get; init; } = "";
        public long? EnteredBy { get; init; }
        public long? LastReopenedBy { get; init; }
        public int ReopenCount { get; init; }
        public string? LastReopenReason { get; init; }
    }

    private const string AccountSelect = """
        SELECT a.BankAccountId, a.PublicId, a.CompanyId, c.PublicId AS CompanyPublicId, c.NameAr AS CompanyNameAr, c.NameEn AS CompanyNameEn, i.Code AS InstitutionCode,
               a.AccountNoMask, a.Nickname, cu.Code AS Currency, a.Status, a.OpenedOn, a.ClosedOn
          FROM acc.BankAccount AS a
          JOIN org.Company AS c ON c.CompanyId = a.CompanyId
          JOIN ins.Institution AS i ON i.InstitutionId = a.InstitutionId
          JOIN ref.Currency AS cu ON cu.CurrencyId = a.CurrencyId
        """;

    private const string StatSelect = """
        SELECT AccountMonthlyStatId, PublicId, BankAccountId, MonthEnd, AvgDailyBalance, MinBalance, EndBalance, SourceKind, SourceRef, Note, Status, EnteredBy,
               LastReopenedBy, ReopenCount, LastReopenReason
          FROM fin.AccountMonthlyStat
        """;

    /// <summary>The months an account is expected to have a figure (FR-ACC-021, OQ-14): from its opening, or its first figure, to its closing and the last month that ended.</summary>
    private static bool Expected(AccountRow a, DateTime month, DateTime? firstFigure, DateTime today)
    {
        var start = a.OpenedOn is { } o ? EndOfMonth(o) : firstFigure;
        if (start is null || month < start) return false;
        if (a.ClosedOn is { } c && month > EndOfMonth(c)) return false;
        return month < EndOfMonth(today);
    }

    /// <summary>R-FIN-02: the accounts of the companies in scope by month, each cell with its figure and state; an expected month without a figure is missing (the red dot).</summary>
    private static async Task<IResult> StatsAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "company", "from", "to");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        var q = http.Request.Query;
        var today = Today(clock);
        var to = q["to"].Count > 0 ? Month(q["to"], "end month") : EndOfMonth(today).AddDays(1).AddMonths(-1).AddDays(-1);
        var from = q["from"].Count > 0 ? Month(q["from"], "first month") : EndOfMonth(to.AddDays(1).AddMonths(-11).AddDays(-1));
        if (from > to || (to.Year - from.Year) * 12 + to.Month - from.Month > 36)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Show from one to 36 months, the first month before the last.");
        Guid? company = q["company"].Count > 0 ? (Guid.TryParse(q["company"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "company is an id.")) : null;
        var accounts = (await u.Connection.QueryAsync<AccountRow>(new CommandDefinition(AccountSelect + """
             WHERE (@company IS NULL OR c.PublicId = @company) AND (@all = 1 OR a.CompanyId IN @ids)
               AND NOT EXISTS (SELECT 1 FROM cat.AccountType AS t WHERE t.AccountTypeId = a.AccountTypeId AND t.IsVirtual = 1)
             ORDER BY c.NameAr, i.Code, a.AccountNoMask;
            """, new { company, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: ct))).ToList();
        var ids = accounts.Select(a => a.BankAccountId).DefaultIfEmpty(-1).ToArray();
        var stats = (await u.Connection.QueryAsync<StatRow>(new CommandDefinition(StatSelect + " WHERE BankAccountId IN @ids AND MonthEnd BETWEEN @from AND @to;",
            new { ids, from, to }, cancellationToken: ct))).ToLookup(s => s.BankAccountId);
        var first = (await u.Connection.QueryAsync<(long Id, DateTime First)>(new CommandDefinition(
            "SELECT BankAccountId, MIN(MonthEnd) FROM fin.AccountMonthlyStat WHERE BankAccountId IN @ids GROUP BY BankAccountId;", new { ids }, cancellationToken: ct)))
            .ToDictionary(x => x.Id, x => x.First);
        var months = new List<DateTime>();
        for (var m = from; m <= to; m = EndOfMonth(m.AddDays(1))) months.Add(m);
        return Results.Ok(new
        {
            months = months.Select(m => D(m)),
            accounts = accounts.Select(a =>
            {
                var byMonth = stats[a.BankAccountId].ToDictionary(s => s.MonthEnd);
                var firstFigure = first.TryGetValue(a.BankAccountId, out var f) ? f : (DateTime?)null;
                return new
                {
                    id = a.PublicId, company = new { id = a.CompanyPublicId, nameAr = a.CompanyNameAr, nameEn = a.CompanyNameEn }, bank = a.InstitutionCode,
                    accountNumber = a.AccountNoMask, nickname = a.Nickname, currency = a.Currency, status = a.Status, openedOn = D(a.OpenedOn), closedOn = D(a.ClosedOn),
                    cells = months.Select(m =>
                    {
                        var s = byMonth.GetValueOrDefault(m);
                        var expected = Expected(a, m, firstFigure, today);
                        return new
                        {
                            month = D(m), expected, missing = expected && s is null, id = s?.PublicId, avgDailyBalance = s?.AvgDailyBalance, minBalance = s?.MinBalance,
                            endBalance = s?.EndBalance, sourceKind = s?.SourceKind, sourceRef = s?.SourceRef, status = s?.Status, enteredByMe = s is not null && s.EnteredBy == u.UserId,
                            reopenReason = s?.LastReopenReason,
                        };
                    }),
                };
            }),
        });
    }

    /// <summary>
    /// The grid's save (FR-FIN-008, V-FIN-02): each figure a draft in the name of its editor; a month that ended and in
    /// which the account was open; a confirmed figure is reopened first. A negative balance is accepted with a warning.
    /// </summary>
    private static async Task<IResult> SaveStatsAsync(AccountStatsRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, StatsEnter, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Items is null || b.Items.Length == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the figures to save.");
        if (b.Items.Length > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A save has at most 500 figures.");
        var today = Today(clock);
        var warnings = new List<string>();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        foreach (var item in b.Items)
        {
            if (item.Account is null || item.AvgDailyBalance is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Each figure has its account, month and average daily balance.");
            var month = Month(item.Month);
            var a = await u.Connection.QuerySingleOrDefaultAsync<AccountRow>(new CommandDefinition(AccountSelect + " WHERE a.PublicId = @id;", new { id = item.Account },
                tx, cancellationToken: ct));
            if (a is null || !scope.Allows(a.CompanyId)) throw ApiProblemException.NotFound();
            if (month >= EndOfMonth(today)) throw ApiProblemException.Invalid("V-FIN-02", $"{D(month)}: a month is entered once it has ended.");
            if (a.OpenedOn is { } o && month < EndOfMonth(o)) throw ApiProblemException.Invalid("V-FIN-02", $"{D(month)}: the account was opened on {D(o)}.");
            if (a.ClosedOn is { } c && month > EndOfMonth(c)) throw ApiProblemException.Invalid("V-FIN-02", $"{D(month)}: the account was closed on {D(c)}.");
            var source = item.SourceKind?.Trim().ToUpperInvariant() ?? "BANK_STATEMENT";
            if (!Sources.Contains(source)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The source is BANK_STATEMENT, BANK_NOTICE or INTERNAL_CALC.");
            if (item.AvgDailyBalance < 0 || item.MinBalance < 0 || item.EndBalance < 0) warnings.Add($"{a.AccountNoMask} {D(month)}: a negative balance");
            long? doc = null;
            if (item.Document is { } dd)
                doc = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                    "SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE' AND (OwnerCompanyId IS NULL OR OwnerCompanyId = @c);", new { d = dd, c = a.CompanyId }, tx,
                    cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is not an active document of the company.");
            var was = await u.Connection.QuerySingleOrDefaultAsync<StatRow>(new CommandDefinition(
                StatSelect.Replace("FROM fin.AccountMonthlyStat", "FROM fin.AccountMonthlyStat WITH (UPDLOCK, HOLDLOCK)", StringComparison.Ordinal)
                + " WHERE BankAccountId = @a AND MonthEnd = @m;", new { a = a.BankAccountId, m = month }, tx, cancellationToken: ct));
            var p = new
            {
                a = a.BankAccountId, m = month, avg = item.AvgDailyBalance, min = item.MinBalance, end = item.EndBalance, src = source,
                sref = item.SourceRef?.Trim() is { Length: > 0 } r ? (r.Length <= 100 ? r : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The source reference has at most 100 characters.")) : null,
                note = item.Note?.Trim() is { Length: > 0 } n ? (n.Length <= 500 ? n : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The note has at most 500 characters.")) : null, doc,
            };
            if (was is null)
                await u.Connection.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT fin.AccountMonthlyStat (TenantId, BankAccountId, MonthEnd, AvgDailyBalance, MinBalance, EndBalance, SourceKind, SourceRef, DocumentId, Note, Status, EnteredBy, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @a, @m, @avg, @min, @end, @src, @sref, @doc, @note, 'DRAFT', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
                            CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                    """, p, tx, cancellationToken: ct));
            else
            {
                if (was.Status == "CONFIRMED") throw new ApiProblemException(409, "FIGURE_CONFIRMED", $"{a.AccountNoMask} {D(month)} is confirmed; reopen it with a reason to change it.");
                if (was.LastReopenedBy == u.UserId)
                    throw ApiProblemException.Forbidden("V-FIN-SOD", "Who reopened a figure does not enter it again; another user does (BR-FIN-048).");
                await u.Connection.ExecuteAsync(new CommandDefinition(
                    """
                    UPDATE fin.AccountMonthlyStat
                       SET AvgDailyBalance = @avg, MinBalance = @min, EndBalance = @end, SourceKind = @src, SourceRef = @sref, DocumentId = ISNULL(@doc, DocumentId), Note = @note,
                           EnteredBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                     WHERE BankAccountId = @a AND MonthEnd = @m;
                    """, p, tx, cancellationToken: ct));
            }
        }
        await tx.CommitAsync(ct);
        return Results.Ok(new { saved = b.Items.Length, warnings });
    }

    /// <summary>Confirms drafts as their authors entered them (BR-FIN-048): another holder of fin.stats.confirm, not the one who reopened them last.</summary>
    private static async Task<IResult> ConfirmStatsAsync(FigureIdsRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, StatsConfirm, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Ids is null || b.Ids.Length is 0 or > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give from 1 to 500 figures to confirm.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var rows = (await u.Connection.QueryAsync<(long Id, long Company, string Status, long? EnteredBy, long? Reopener)>(new CommandDefinition(
            """
            SELECT m.AccountMonthlyStatId, a.CompanyId, m.Status, m.EnteredBy, m.LastReopenedBy
              FROM fin.AccountMonthlyStat AS m WITH (UPDLOCK, HOLDLOCK) JOIN acc.BankAccount AS a ON a.BankAccountId = m.BankAccountId
             WHERE m.PublicId IN @ids;
            """, new { ids = b.Ids }, tx, cancellationToken: ct))).ToList();
        Check(rows.Select(r => (r.Company, r.Status, r.EnteredBy, r.Reopener)).ToList(), b.Ids.Distinct().Count(), scope, u.UserId);
        var ids = rows.Select(r => r.Id).ToArray();
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.AccountMonthlyStat SET Status = 'CONFIRMED', ConfirmedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ConfirmedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE AccountMonthlyStatId IN @ids;
            """, new { ids }, tx, cancellationToken: ct));
        foreach (var r in rows)
            await Outbox.EmitAsync(u.Connection, tx, "monthly.figure.confirmed", "fin.AccountMonthlyStat", r.Id, new { company = r.Company }, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("MONTHLY_BALANCES_CONFIRMED", "TREASURY", "fin.AccountMonthlyStat", null,
            AfterJson: JsonSerializer.Serialize(new { count = rows.Count })), rows.Select(r => (long?)r.Company).Distinct().Count() == 1 ? rows[0].Company : null, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { confirmed = rows.Count });
    }

    private static void Check(List<(long Company, string Status, long? EnteredBy, long? Reopener)> rows, int asked, CompanyScope scope, long me)
    {
        if (rows.Count != asked || rows.Any(r => !scope.Allows(r.Company))) throw ApiProblemException.NotFound();
        if (rows.Any(r => r.Status != "DRAFT")) throw new ApiProblemException(409, "FIGURE_CONFIRMED", "A figure among these is already confirmed.");
        if (rows.Any(r => r.EnteredBy == me || r.Reopener == me))
            throw ApiProblemException.Forbidden("V-FIN-SOD", "A figure is confirmed by someone other than the one who entered it or reopened it last (BR-FIN-048).");
    }

    /// <summary>BR-FIN-048: a confirmed figure reopened with a reason by someone other than its author (the procedure writes the audit row).</summary>
    private static async Task<IResult> ReopenAsync(string kind, Guid id, FigureReasonRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, StatsConfirm, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        var reason = b.Reason?.Trim();
        if (string.IsNullOrEmpty(reason) || reason.Length > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason for reopening, at most 500 characters.");
        var row = kind == "BALANCE"
            ? await u.Connection.QuerySingleOrDefaultAsync<(long Id, long Company, string Status, long? Author)>(new CommandDefinition(
                """
                SELECT m.AccountMonthlyStatId, a.CompanyId, m.Status, ISNULL(m.EnteredBy, m.CreatedBy)
                  FROM fin.AccountMonthlyStat AS m JOIN acc.BankAccount AS a ON a.BankAccountId = m.BankAccountId WHERE m.PublicId = @id;
                """, new { id }, cancellationToken: ct))
            : await u.Connection.QuerySingleOrDefaultAsync<(long Id, long Company, string Status, long? Author)>(new CommandDefinition(
                "SELECT BankFlowEntryId, CompanyId, Status, ISNULL(EnteredBy, CreatedBy) FROM fin.BankFlowEntry WHERE PublicId = @id;", new { id }, cancellationToken: ct));
        if (row.Id == 0 || !scope.Allows(row.Company)) throw ApiProblemException.NotFound();
        if (row.Status != "CONFIRMED") throw new ApiProblemException(409, "FIGURE_STATE", "Only a confirmed figure is reopened.");
        if (row.Author == u.UserId) throw ApiProblemException.Forbidden("V-FIN-SOD", "A figure is reopened by someone other than its author (BR-FIN-048).");
        await u.Connection.ExecuteAsync(new CommandDefinition("fin.usp_ReopenMonthlyFigure", new { Kind = kind, Id = row.Id, Reason = reason },
            commandType: CommandType.StoredProcedure, cancellationToken: ct));
        return Results.Ok(new { status = "DRAFT" });
    }

    // ---------- bank flows ----------

    private sealed class FlowRow
    {
        public long BankFlowEntryId { get; init; }
        public Guid PublicId { get; init; }
        public long CompanyId { get; init; }
        public Guid CompanyPublicId { get; init; }
        public string CompanyNameAr { get; init; } = "";
        public long InstitutionId { get; init; }
        public Guid InstitutionPublicId { get; init; }
        public string InstitutionCode { get; init; } = "";
        public long? FacilityId { get; init; }
        public Guid? FacilityPublicId { get; init; }
        public string? FacilityNo { get; init; }
        public DateTime MonthEnd { get; init; }
        public string Kind { get; init; } = "";
        public decimal Amount { get; init; }
        public string Currency { get; init; } = "";
        public string? BasisNote { get; init; }
        public string Status { get; init; } = "";
        public long? EnteredBy { get; init; }
        public long? LastReopenedBy { get; init; }
        public string? LastReopenReason { get; init; }
    }

    private const string FlowSelect = """
        SELECT e.BankFlowEntryId, e.PublicId, e.CompanyId, c.PublicId AS CompanyPublicId, c.NameAr AS CompanyNameAr, e.InstitutionId, i.PublicId AS InstitutionPublicId,
               i.Code AS InstitutionCode, e.FacilityId, f.PublicId AS FacilityPublicId, ISNULL(f.PlatformRef, f.FacilityNo) AS FacilityNo, e.MonthEnd, k.Code AS Kind, e.Amount, cu.Code AS Currency, e.BasisNote,
               e.Status, e.EnteredBy, e.LastReopenedBy, e.LastReopenReason
          FROM fin.BankFlowEntry AS e
          JOIN org.Company AS c ON c.CompanyId = e.CompanyId
          JOIN ins.Institution AS i ON i.InstitutionId = e.InstitutionId
          JOIN cat.LookupItem AS k ON k.LookupItemId = e.FlowKindId
          JOIN ref.Currency AS cu ON cu.CurrencyId = e.CurrencyId
          LEFT JOIN fac.Facility AS f ON f.FacilityId = e.FacilityId
        """;

    private static object Shape(FlowRow e, long me) => new
    {
        id = e.PublicId, company = new { id = e.CompanyPublicId, nameAr = e.CompanyNameAr }, institution = new { id = e.InstitutionPublicId, code = e.InstitutionCode },
        facility = e.FacilityPublicId is null ? null : new { id = e.FacilityPublicId, facilityNo = e.FacilityNo }, month = D(e.MonthEnd), kind = e.Kind, amount = e.Amount,
        currency = e.Currency, basisNote = e.BasisNote, status = e.Status, enteredByMe = e.EnteredBy == me, reopenReason = e.LastReopenReason,
    };

    /// <summary>R-FIN-03: the flows of a year (by month end) with their totals by bank and currency, confirmed and awaiting confirmation apart.</summary>
    private static async Task<IResult> FlowsAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "company", "year");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: false);
        await using var _ = u;
        var q = http.Request.Query;
        Guid? company = q["company"].Count > 0 ? (Guid.TryParse(q["company"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "company is an id.")) : null;
        var year = q["year"].Count > 0 ? (int.TryParse(q["year"], CultureInfo.InvariantCulture, out var y) ? y : throw new ApiProblemException(400, "MALFORMED_REQUEST", "year is a year."))
            : Today(clock).Year;
        var rows = (await u.Connection.QueryAsync<FlowRow>(new CommandDefinition(FlowSelect + """
             WHERE (@company IS NULL OR c.PublicId = @company) AND YEAR(e.MonthEnd) = @year AND (@all = 1 OR e.CompanyId IN @ids)
             ORDER BY e.MonthEnd, c.NameAr, i.Code, f.FacilityNo;
            """, new { company, year, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted))).ToList();
        var totals = rows.GroupBy(r => (r.CompanyPublicId, r.InstitutionCode, r.Currency)).Select(x => new
        {
            company = x.Key.CompanyPublicId, bank = x.Key.InstitutionCode, currency = x.Key.Currency,
            confirmed = x.Where(r => r.Status == "CONFIRMED").Sum(r => r.Amount), awaitingConfirmation = x.Where(r => r.Status == "DRAFT").Sum(r => r.Amount),
        });
        return Results.Ok(new { year, items = rows.Select(r => Shape(r, u.UserId)), totals });
    }

    private static async Task<(int ListId, int ItemId)> KindAsync(BoundUser u, SqlTransaction tx, string? kind, CancellationToken ct) =>
        await u.Connection.QuerySingleOrDefaultAsync<(int, int)?>(new CommandDefinition(
            """
            SELECT l.LookupListId, i.LookupItemId FROM cat.LookupList AS l JOIN cat.LookupItem AS i ON i.LookupListId = l.LookupListId
             WHERE l.Code = 'FLOW_KIND' AND i.Code = @k AND i.IsActive = 1 AND i.Status = 'ACTIVE';
            """, new { k = (kind ?? "TRANSFERRED_TO_BANK").Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The kind of flow is an active item of the list FLOW_KIND.");

    /// <summary>
    /// FR-FIN-009, BR-FIN-016: a flow of a company to a bank for a month, at the level of the bank or of one of its
    /// facilities with that bank, never both for the same month and kind; a bank that lends the company nothing is a warning.
    /// </summary>
    private static async Task<IResult> AddFlowAsync(BankFlowRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, StatsEnter, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Company is null || b.Institution is null || b.Amount is null || b.Currency is null)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the company, the bank, the month, the amount and the currency.");
        if (b.Amount < 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The amount routed is zero or more.");
        var month = Month(b.Month);
        if (month >= EndOfMonth(Today(clock))) throw ApiProblemException.Invalid("V-FIN-02", "A month is entered once it has ended.");
        var note = b.BasisNote?.Trim() is { Length: > 0 } n ? (n.Length <= 500 ? n : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The basis has at most 500 characters.")) : null;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var company = await CompanyEndpoints.FindAsync(u, tx, b.Company.Value, scope, ct);
        var bank = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @i;", new { i = b.Institution },
            tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank is not an institution of the account.");
        long? facility = null;
        var warnings = new List<string>();
        if (b.Facility is { } fid)
        {
            facility = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                """
                SELECT f.FacilityId FROM fac.Facility AS f
                 WHERE f.PublicId = @f AND f.BorrowerCompanyId = @c AND f.ApprovedRevisionNo > 0
                   AND EXISTS (SELECT 1 FROM fac.FacilityLender AS l WHERE l.FacilityId = f.FacilityId AND l.InstitutionId = @i
                                 AND l.FromRevision <= f.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo));
                """, new { f = fid, c = company.CompanyId, i = bank }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The facility is an approved facility of the company with this bank among its lenders.");
        }
        else if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                     """
                     SELECT COUNT(*) FROM fac.Facility AS f JOIN fac.FacilityLender AS l ON l.FacilityId = f.FacilityId
                      WHERE f.BorrowerCompanyId = @c AND l.InstitutionId = @i AND f.ApprovedRevisionNo > 0
                        AND l.FromRevision <= f.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo);
                     """, new { c = company.CompanyId, i = bank }, tx, cancellationToken: ct)) == 0)
            warnings.Add("This bank has no approved facility of the company: the flow counts for no covenant.");
        var (listId, kindId) = await KindAsync(u, tx, b.Kind, ct);
        var levels = await u.Connection.QueryAsync<long?>(new CommandDefinition(
            "SELECT FacilityId FROM fin.BankFlowEntry WITH (UPDLOCK, HOLDLOCK) WHERE CompanyId = @c AND InstitutionId = @i AND MonthEnd = @m AND FlowKindId = @k;",
            new { c = company.CompanyId, i = bank, m = month, k = kindId }, tx, cancellationToken: ct));
        foreach (var level in levels)
        {
            if (level == facility) throw new ApiProblemException(409, "V-FIN-DUPLICATE", "This flow is already entered for the month; change it instead (FR-FIN-009).");
            if (level is null || facility is null)
                throw new ApiProblemException(409, "FLOW_LEVEL", "A month's flows to a bank are entered at the level of the bank or per facility, not both (BR-FIN-016).");
        }
        var currency = await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency, ct);
        long? doc = null;
        if (b.Document is { } dd)
            doc = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE' AND (OwnerCompanyId IS NULL OR OwnerCompanyId = @c);", new { d = dd, c = company.CompanyId }, tx,
                cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is not an active document of the company.");
        var made = await u.Connection.QuerySingleAsync<Guid>(new CommandDefinition(
            """
            DECLARE @o TABLE (PublicId UNIQUEIDENTIFIER);
            INSERT fin.BankFlowEntry (TenantId, CompanyId, InstitutionId, FacilityId, MonthEnd, FlowKindListCode, FlowKindListId, FlowKindId, Amount, CurrencyId, BasisNote,
                                      DocumentId, Status, EnteredBy, CreatedBy)
            OUTPUT inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @i, @f, @m, 'FLOW_KIND', @l, @k, @a, @cur, @n, @doc, 'DRAFT', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT PublicId FROM @o;
            """, new { c = company.CompanyId, i = bank, f = facility, m = month, l = listId, k = kindId, a = b.Amount, cur = currency, n = note, doc }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/bank-flows/{made}", new { id = made, warnings });
    }

    private static async Task<IResult> ChangeFlowAsync(Guid id, BankFlowRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, StatsEnter, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Company is not null || b.Institution is not null || b.Facility is not null || b.Month is not null || b.Kind is not null || b.Currency is not null)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The company, bank, facility, month, kind and currency of a flow do not change; another flow is a new entry.");
        if (b.Amount is < 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The amount routed is zero or more.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var e = await u.Connection.QuerySingleOrDefaultAsync<FlowRow>(new CommandDefinition(
            FlowSelect.Replace("FROM fin.BankFlowEntry AS e", "FROM fin.BankFlowEntry AS e WITH (UPDLOCK, HOLDLOCK)", StringComparison.Ordinal) + " WHERE e.PublicId = @id;",
            new { id }, tx, cancellationToken: ct));
        if (e is null || !scope.Allows(e.CompanyId)) throw ApiProblemException.NotFound();
        if (e.Status == "CONFIRMED") throw new ApiProblemException(409, "FIGURE_CONFIRMED", "This flow is confirmed; reopen it with a reason to change it.");
        if (e.LastReopenedBy == u.UserId) throw ApiProblemException.Forbidden("V-FIN-SOD", "Who reopened a figure does not enter it again; another user does (BR-FIN-048).");
        var note = b.BasisNote is null ? e.BasisNote : b.BasisNote.Trim() is { Length: > 0 } n ? (n.Length <= 500 ? n
            : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The basis has at most 500 characters.")) : null;
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.BankFlowEntry SET Amount = @a, BasisNote = @n, EnteredBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE BankFlowEntryId = @id;
            """, new { a = b.Amount ?? e.Amount, n = note, id = e.BankFlowEntryId }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> ConfirmFlowsAsync(FigureIdsRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, StatsConfirm, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Ids is null || b.Ids.Length is 0 or > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give from 1 to 500 figures to confirm.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var rows = (await u.Connection.QueryAsync<(long Id, long Company, string Status, long? EnteredBy, long? Reopener)>(new CommandDefinition(
            "SELECT BankFlowEntryId, CompanyId, Status, EnteredBy, LastReopenedBy FROM fin.BankFlowEntry WITH (UPDLOCK, HOLDLOCK) WHERE PublicId IN @ids;",
            new { ids = b.Ids }, tx, cancellationToken: ct))).ToList();
        Check(rows.Select(r => (r.Company, r.Status, r.EnteredBy, r.Reopener)).ToList(), b.Ids.Distinct().Count(), scope, u.UserId);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.BankFlowEntry SET Status = 'CONFIRMED', ConfirmedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ConfirmedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE BankFlowEntryId IN @ids;
            """, new { ids = rows.Select(r => r.Id).ToArray() }, tx, cancellationToken: ct));
        foreach (var r in rows)
            await Outbox.EmitAsync(u.Connection, tx, "bank.flow.confirmed", "fin.BankFlowEntry", r.Id, new { company = r.Company }, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("BANK_FLOWS_CONFIRMED", "TREASURY", "fin.BankFlowEntry", null,
            AfterJson: JsonSerializer.Serialize(new { count = rows.Count })), rows.Select(r => r.Company).Distinct().Count() == 1 ? rows[0].Company : null, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { confirmed = rows.Count });
    }

    /// <summary>FR-FIN-018, BR-FIN-017: how the flow covenants of approved facilities stand on a day (fin.fn_BankFlowPerformance), within the company scope.</summary>
    private static async Task<IResult> PerformanceAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "asOf", "facility");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: false);
        await using var _ = u;
        var q = http.Request.Query;
        var asOf = q["asOf"].Count > 0 ? LimitEndpoints.Date(q["asOf"], "date") ?? Today(clock) : Today(clock);
        Guid? facility = q["facility"].Count > 0 ? (Guid.TryParse(q["facility"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "facility is an id.")) : null;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT f.PublicId AS facility, f.FacilityNo AS facilityNo, c.PublicId AS company, c.NameAr AS companyNameAr, p.MeasureKind AS measureKind,
                   p.TestFrequency AS testFrequency, p.WindowBasis AS windowBasis, p.WindowStart AS windowStart, p.WindowEnd AS windowEnd, cu.Code AS currency,
                   p.Operator AS operator, p.ThresholdValue AS thresholdValue, p.ThresholdUnit AS thresholdUnit, p.Achieved AS achieved,
                   p.AwaitingConfirmation AS awaitingConfirmation, p.OtherCurrencyEntries AS otherCurrencyEntries, p.MonthsConfirmed AS monthsConfirmed,
                   p.MonthsElapsed AS monthsElapsed, p.MonthsInWindow AS monthsInWindow, p.Revenue AS revenue, p.Required AS required, p.Remaining AS remaining,
                   p.RequiredPerRemainingMonth AS requiredPerRemainingMonth, p.AchievementPct AS achievementPct, p.PerformanceState AS state
              FROM fin.fn_BankFlowPerformance(@asOf) AS p
              JOIN fac.Facility AS f ON f.FacilityId = p.FacilityId
              JOIN org.Company AS c ON c.CompanyId = p.CompanyId
              JOIN ref.Currency AS cu ON cu.CurrencyId = p.CurrencyId
             WHERE (@facility IS NULL OR f.PublicId = @facility) AND (@all = 1 OR p.CompanyId IN @ids)
             ORDER BY f.FacilityNo;
            """, new { asOf, facility, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { asOf = D(asOf), items = rows });
    }

    // ---------- reporting periods ----------

    private static async Task<IResult> PeriodsAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: false);
        await using var _ = u;
        var q = http.Request.Query;
        Guid? company = q["company"].Count > 0 ? (Guid.TryParse(q["company"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "company is an id.")) : null;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT c.PublicId AS company, c.NameAr AS companyNameAr, l.LockedThrough AS lockedThrough, l.Status AS status, l.LockReason AS reason, l.LockedOn AS lockedOn,
                   l.ReopenedOn AS reopenedOn, l.ReopenReason AS reopenReason, CAST(CASE WHEN l.LockedBy = @me THEN 1 ELSE 0 END AS BIT) AS lockedByMe
              FROM fin.ReportingPeriodLock AS l JOIN org.Company AS c ON c.CompanyId = l.CompanyId
             WHERE (@company IS NULL OR c.PublicId = @company) AND (@all = 1 OR l.CompanyId IN @ids)
             ORDER BY c.NameAr, l.LockedThrough DESC, l.LockedOn DESC;
            """, new { company, me = u.UserId, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    /// <summary>BR-FIN-050: closes a company's periods through a day that passed, once every statement of them is approved and every figure confirmed (053 checks and audits).</summary>
    private static async Task<IResult> LockAsync(Guid company, PeriodLockRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, PeriodLock, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        var through = LimitEndpoints.Date(b.LockedThrough, "day closed through") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the day the periods are closed through.");
        var reason = b.Reason?.Trim();
        if (string.IsNullOrEmpty(reason) || reason.Length > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason for the close, at most 500 characters.");
        var c = await CompanyEndpoints.FindAsync(u, null, company, scope, ct);
        var p = new DynamicParameters(new { CompanyId = c.CompanyId, LockedThrough = through, Reason = reason });
        p.Add("@LockId", null, DbType.Int64, ParameterDirection.Output);
        await u.Connection.ExecuteAsync(new CommandDefinition("fin.usp_LockReportingPeriod", p, commandType: CommandType.StoredProcedure, cancellationToken: ct));
        return Results.Ok(new { lockedThrough = D(through) });
    }

    private static async Task<IResult> ReopenPeriodAsync(Guid company, FigureReasonRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, PeriodLock, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        var reason = b.Reason?.Trim();
        if (string.IsNullOrEmpty(reason) || reason.Length > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason for reopening, at most 500 characters.");
        var c = await CompanyEndpoints.FindAsync(u, null, company, scope, ct);
        var lockId = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT ReportingPeriodLockId FROM fin.v_ReportingPeriodStatus WHERE CompanyId = @c;", new { c = c.CompanyId }, cancellationToken: ct))
            ?? throw new ApiProblemException(409, "CLOSE_REFUSED", "The company has no closed period.");
        await u.Connection.ExecuteAsync(new CommandDefinition("fin.usp_ReopenReportingPeriod", new { LockId = lockId, Reason = reason },
            commandType: CommandType.StoredProcedure, cancellationToken: ct));
        return Results.Ok(new { reopened = true });
    }
}

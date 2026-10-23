using System.Globalization;
using System.Text.Json;
using BankFas.Core.Finance;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Finance;

/// <summary>
/// The covenant test calendar and the verification engine (FR-OBL-011, FR-FIN-010, 012 to 014; BR-FIN-003, 005 to
/// 011; BR-OBL-005 to 008 and 011; S2-b brief S2B-GAP-1, 8, OQ-4, 7, 8, 13, 15).
///
/// The calendar: each measured covenant of a facility's approved revision has one test per period end, counted from
/// the tested company's fiscal year end from FirstTestPeriodEnd to 24 months ahead, the facility's expiry or the
/// covenant's end; DueDate = PeriodEnd + SubmissionLagDays (the tenant's 30 by default). On a new revision the tests not
/// yet evaluated move to the covenant's new row with their dates recomputed, and those that leave the schedule are
/// cancelled with their reason.
///
/// The evaluation, once the period has ended: the latest approved version of the covenant's formula; the approved
/// statement of the tested company for the period end and the covenant's basis, audited first or only as the covenant
/// requires, with no silent fall back to another basis; the confirmed monthly balances of the accounts in scope, each
/// expected month present; the confirmed flows of the period to the facility's banks; the revenue by the covenant's
/// rule. An input missing keeps the test PENDING_DATA until its due date, then makes it MISSING_DATA with its reason; a
/// currency other than the covenant's makes it NOT_COMPARABLE. The judgement is at full precision and stored with six
/// decimals, with the inputs, the formula version and the threshold and operator applied (044 checks the snapshot). A
/// test once evaluated is a fact: a later evaluation is a new row with the next EvaluationNo.
///
/// Breaches: a BREACH opens a covenant breach (IN_CURE when the obligation gives cure days) unless one is open or in
/// cure for the covenant and period, which is then marked NeedsReview; a closed one is marked NeedsReview and none is
/// reopened (OQ-7). A later evaluation that no longer breaches marks the open one NeedsReview and never closes it
/// (BR-OBL-011). A WARNING sends CMP.WARNING once per evaluation; MISSING_DATA sends FIN.DATA_MISSING, weekly while the
/// data stays missing.
/// </summary>
public static class CovenantEngine
{
    public const int HorizonMonths = 24;

    internal sealed class CovenantRow
    {
        public long CovenantId { get; init; }
        public long RootId { get; init; }
        public long ObligationId { get; init; }
        public long ObligationRootId { get; init; }
        public long FacilityId { get; init; }
        public string FacilityNo { get; init; } = "";
        public int ApprovedRevisionNo { get; init; }
        public DateTime FacilityExpiry { get; init; }
        public DateTime FacilityEffective { get; init; }
        public string MeasureKind { get; init; } = "";
        public long? FormulaId { get; init; }
        public string? Operator { get; init; }
        public string ThresholdState { get; init; } = "";
        public decimal? ThresholdValue { get; init; }
        public string? ThresholdUnit { get; init; }
        public int? CurrencyId { get; init; }
        public int FacilityCurrencyId { get; init; }
        public string TestFrequency { get; init; } = "";
        public string? AggregationMode { get; init; }
        public string? StatementBasis { get; init; }
        public string? RequiredAssurance { get; init; }
        public string? RevenueBasisRule { get; init; }
        public string? AccountScopeKind { get; init; }
        public long TestedCompanyId { get; init; }
        public int? SubmissionLagDays { get; init; }
        public DateTime FirstTestPeriodEnd { get; init; }
        public decimal? EarlyWarningPct { get; init; }
        public DateTime ValidFrom { get; init; }
        public DateTime? ValidTo { get; init; }
        public int? CureDays { get; init; }
        public byte FyeMonth { get; init; }
        public string TitleAr { get; init; } = "";
        public string? TitleEn { get; init; }
        public long BorrowerCompanyId { get; init; }
        public int Currency => CurrencyId ?? FacilityCurrencyId;
    }

    private const string CovenantSelect = """
        SELECT c.CovenantId, c.RootId, o.ObligationId, o.RootId AS ObligationRootId, f.FacilityId, f.FacilityNo, f.ApprovedRevisionNo, f.ExpiryDate AS FacilityExpiry,
               f.EffectiveFrom AS FacilityEffective, c.MeasureKind, c.FormulaId, c.Operator, c.ThresholdState, c.ThresholdValue, c.ThresholdUnit, c.CurrencyId,
               f.CurrencyId AS FacilityCurrencyId, c.TestFrequency, c.AggregationMode, c.StatementBasis, c.RequiredAssurance, c.RevenueBasisRule, c.AccountScopeKind,
               c.TestedCompanyId, c.SubmissionLagDays, c.FirstTestPeriodEnd, c.EarlyWarningPct, c.ValidFrom, c.ValidTo, o.CureDays, co.FiscalYearEndMonth AS FyeMonth,
               o.TitleAr, o.TitleEn, f.BorrowerCompanyId
          FROM obl.Covenant AS c
          JOIN obl.Obligation AS o ON o.ObligationId = c.ObligationId
          JOIN fac.Facility AS f ON f.FacilityId = o.FacilityId
          JOIN org.Company AS co ON co.CompanyId = c.TestedCompanyId
        """;

    private static async Task<(int Lag, decimal Warning)> DefaultsAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct)
    {
        var rows = (await c.QueryAsync<(string Key, string? Value)>(new CommandDefinition(
            """
            SELECT d.[Key], ISNULL(t.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key]
             WHERE d.[Key] IN ('obl.submission_lag_days', 'obl.early_warning_pct');
            """, transaction: tx, cancellationToken: ct)).ConfigureAwait(false)).ToDictionary(r => r.Key, r => r.Value);
        var lag = int.TryParse(rows.GetValueOrDefault("obl.submission_lag_days"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var l) ? l : 30;
        var warning = decimal.TryParse(rows.GetValueOrDefault("obl.early_warning_pct"), NumberStyles.Number, CultureInfo.InvariantCulture, out var w) ? w : 10m;
        return (lag, warning);
    }

    // ---------- the calendar ----------

    private sealed record TestRef(long CovenantTestId, long CovenantRootId, long CovenantId, DateTime PeriodEnd, int EvaluationNo, string State);

    /// <summary>The tests of the measured covenants of a facility's approved revision, to the horizon; returns the rows written.</summary>
    public static async Task<int> ScheduleAsync(SqlConnection c, SqlTransaction tx, long facilityId, DateTime today, CancellationToken ct)
    {
        var (defaultLag, _) = await DefaultsAsync(c, tx, ct).ConfigureAwait(false);
        var covenants = (await c.QueryAsync<CovenantRow>(new CommandDefinition(CovenantSelect + """
             WHERE f.FacilityId = @f AND f.ApprovedRevisionNo >= 1 AND c.MeasureKind <> 'NONE'
               AND c.FromRevision <= f.ApprovedRevisionNo AND (c.ToRevision IS NULL OR c.ToRevision > f.ApprovedRevisionNo)
               AND o.FromRevision <= f.ApprovedRevisionNo AND (o.ToRevision IS NULL OR o.ToRevision > f.ApprovedRevisionNo);
            """, new { f = facilityId }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var tests = (await c.QueryAsync<TestRef>(new CommandDefinition(
            """
            SELECT t.CovenantTestId, t.CovenantRootId, t.CovenantId, t.PeriodEnd, t.EvaluationNo, t.State
              FROM obl.CovenantTest AS t WITH (UPDLOCK, HOLDLOCK)
              JOIN obl.Covenant AS cv ON cv.CovenantId = t.CovenantId
              JOIN obl.Obligation AS o ON o.ObligationId = cv.ObligationId
             WHERE o.FacilityId = @f AND t.Method = 'AUTO';
            """, new { f = facilityId }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var n = 0;
        var live = covenants.Select(k => k.RootId).ToHashSet();
        foreach (var k in covenants)
        {
            // The periods the covenant tests to its end; those within the rolling horizon are written (OQ-4).
            var last = k.ValidTo is { } to && to < k.FacilityExpiry ? to : k.FacilityExpiry;
            var horizon = today.AddMonths(HorizonMonths) < last ? today.AddMonths(HorizonMonths) : last;
            var first = k.FirstTestPeriodEnd < k.ValidFrom ? k.ValidFrom : k.FirstTestPeriodEnd;
            var ends = CovenantPeriods.PeriodEnds(first, last, k.TestFrequency, k.FyeMonth).ToHashSet();
            var lag = k.SubmissionLagDays ?? defaultLag;
            var mine = tests.Where(t => t.CovenantRootId == k.RootId).ToList();
            foreach (var end in ends.Where(e => e <= horizon && mine.All(t => t.PeriodEnd != e)).Order())
            {
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT obl.CovenantTest (TenantId, CovenantRootId, CovenantId, PeriodStart, PeriodEnd, DueDate, EvaluationNo, State, Method, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @root, @cov, @start, @end, @due, 1, 'SCHEDULED', 'AUTO', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                    """, new { root = k.RootId, cov = k.CovenantId, start = CovenantPeriods.PeriodStart(end, k.TestFrequency), end, due = end.AddDays(lag) }, tx,
                    cancellationToken: ct)).ConfigureAwait(false);
                n++;
            }
            foreach (var t in mine.Where(t => t.State is "SCHEDULED" or "PENDING_DATA"))
            {
                if (!ends.Contains(t.PeriodEnd))
                    n += await CancelAsync(c, tx, t.CovenantTestId, "The period is no longer tested by the covenant's approved revision.", ct).ConfigureAwait(false);
                else if (t.CovenantId != k.CovenantId)
                {
                    await c.ExecuteAsync(new CommandDefinition(
                        """
                        UPDATE obl.CovenantTest SET CovenantId = @cov, PeriodStart = @start, DueDate = @due, UpdatedAt = SYSUTCDATETIME(),
                               UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                         WHERE CovenantTestId = @id;
                        """, new { cov = k.CovenantId, start = CovenantPeriods.PeriodStart(t.PeriodEnd, k.TestFrequency), due = t.PeriodEnd.AddDays(lag), id = t.CovenantTestId }, tx,
                        cancellationToken: ct)).ConfigureAwait(false);
                    n++;
                }
            }
        }
        foreach (var t in tests.Where(t => !live.Contains(t.CovenantRootId) && t.State is "SCHEDULED" or "PENDING_DATA"))
            n += await CancelAsync(c, tx, t.CovenantTestId, "The covenant was removed by the approved revision.", ct).ConfigureAwait(false);
        return n;
    }

    private static Task<int> CancelAsync(SqlConnection c, SqlTransaction tx, long test, string reason, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE obl.CovenantTest SET State = 'CANCELLED', CancelReason = @reason, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CovenantTestId = @id AND State IN ('SCHEDULED', 'PENDING_DATA');
            """, new { id = test, reason }, tx, cancellationToken: ct));

    // ---------- the inputs ----------

    private sealed class Snapshot
    {
        public object? Formula { get; set; }
        public object? Threshold { get; set; }
        public object Period { get; set; } = new();
        public List<object>? Statements { get; set; }
        public List<object>? Accounts { get; set; }
        public List<object>? Flows { get; set; }
        public object? Revenue { get; set; }
        public Dictionary<string, decimal?> Inputs { get; } = new(StringComparer.Ordinal);
        public string? Reason { get; set; }
        public string? Note { get; set; }
    }

    private sealed record Outcome(decimal? Actual, string? Missing, bool NotComparable, Snapshot Snapshot, long? FormulaVersionId);

    private sealed record FormulaVersion(long MeasureFormulaId, int VersionNo, string Code, string Expression, string InputKinds);

    private static async Task<FormulaVersion?> FormulaAsync(SqlConnection c, SqlTransaction? tx, long formulaId, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<FormulaVersion>(new CommandDefinition(
            """
            SELECT TOP (1) m.MeasureFormulaId, m.VersionNo, m.Code, m.Expression, m.InputKinds
              FROM fin.MeasureFormula AS b
              JOIN fin.MeasureFormula AS m ON m.Code = b.Code AND ((m.FacilityId IS NULL AND b.FacilityId IS NULL) OR m.FacilityId = b.FacilityId)
             WHERE b.MeasureFormulaId = @id AND m.Status = 'APPROVED'
             ORDER BY m.VersionNo DESC;
            """, new { id = formulaId }, tx, cancellationToken: ct)).ConfigureAwait(false);

    private static string PeriodType(string frequency) => frequency switch { "SEMIANNUAL" => "SEMIANNUAL", "QUARTERLY" => "QUARTERLY", "MONTHLY" => "MONTHLY", _ => "ANNUAL" };

    /// <summary>BR-FIN-003: the approved statement of the company for the period end and basis; audited only, audited first, or the latest approved.</summary>
    private static async Task<long?> SelectStatementAsync(SqlConnection c, SqlTransaction? tx, long company, string basis, string periodType, DateTime periodEnd, string assurance,
        CancellationToken ct) =>
        await c.ExecuteScalarAsync<long?>(new CommandDefinition(
            """
            SELECT TOP (1) FinancialStatementId FROM fin.FinancialStatement
             WHERE CompanyId = @c AND Basis = @b AND PeriodType = @p AND PeriodEnd = @e AND Status = 'APPROVED' AND Nature = 'ACTUAL'
               AND (@a <> 'AUDITED_ONLY' OR Assurance = 'AUDITED')
             ORDER BY CASE WHEN @a = 'ANY' THEN 0 ELSE CASE Assurance WHEN 'AUDITED' THEN 0 WHEN 'REVIEWED' THEN 1 ELSE 2 END END, ApprovedOn DESC;
            """, new { c = company, b = basis, p = periodType, e = periodEnd, a = assurance }, tx, cancellationToken: ct)).ConfigureAwait(false);

    private static IEnumerable<DateTime> MonthEnds(DateTime start, DateTime end)
    {
        for (var m = new DateTime(start.Year, start.Month, 1).AddMonths(1).AddDays(-1); m <= end; m = m.AddDays(1).AddMonths(1).AddDays(-1)) yield return m;
    }

    private static async Task<Outcome> InputsAsync(SqlConnection c, SqlTransaction? tx, CovenantRow k, DateTime start, DateTime end, CancellationToken ct)
    {
        var snap = new Snapshot { Period = new { start = Day(start), end = Day(end) } };
        FormulaVersion? fv = null;
        ParsedFormula? parsed = null;
        if (k.FormulaId is { } fid)
        {
            fv = await FormulaAsync(c, tx, fid, ct).ConfigureAwait(false);
            if (fv is null) return new Outcome(null, "The covenant's formula has no approved version.", false, snap, null);
            snap.Formula = new { id = fv.MeasureFormulaId, version = fv.VersionNo, code = fv.Code, expression = fv.Expression };
            parsed = Formula.Parse(fv.Expression, await FinanceInputs.CodesAsync(c, tx, ct).ConfigureAwait(false));
            if (!parsed.IsValid) return new Outcome(null, "The formula is not valid: " + parsed.Errors[0].Message, false, snap, fv.MeasureFormulaId);
        }
        if (k.ThresholdState == "SET") snap.Threshold = new { value = k.ThresholdValue, @operator = k.Operator };
        var kinds = fv is not null ? fv.InputKinds.Split(',').ToHashSet() : k.MeasureKind switch
        {
            "AVERAGE_BALANCE" => ["ACCOUNT_STATS"], "FLOW_VOLUME" => ["BANK_FLOWS"], _ => new HashSet<string>(),
        };
        if (kinds.Contains("STATEMENT")) snap.Statements = [];
        if (kinds.Contains("ACCOUNT_STATS")) snap.Accounts = [];
        if (kinds.Contains("BANK_FLOWS")) snap.Flows = [];
        string? missing = null;
        var notComparable = false;
        var extra = new Dictionary<string, decimal?>(StringComparer.Ordinal);
        StatementInput? statement = null;

        // The statements (BR-FIN-003), with no silent fall back to another basis.
        if (kinds.Contains("STATEMENT"))
        {
            var basis = k.StatementBasis ?? "STANDALONE";
            var id = await SelectStatementAsync(c, tx, k.TestedCompanyId, basis, PeriodType(k.TestFrequency), end, k.RequiredAssurance ?? "PREFER_AUDITED", ct).ConfigureAwait(false);
            if (id is { } sid)
            {
                statement = await FinanceInputs.StatementAsync(c, tx, sid, ct).ConfigureAwait(false);
                snap.Statements!.Add(new { statementId = statement!.Id, version = statement.VersionNo, basis = statement.Basis, assurance = statement.Assurance });
                if (statement.CurrencyId != k.Currency && (k.ThresholdUnit == "AMOUNT" || kinds.Count > 1)) notComparable = true;
            }
            else if (k.RevenueBasisRule != "MANUAL_ESTIMATE")
                missing = $"No approved {basis.ToLowerInvariant()} statement for the period ending {Day(end)}{(k.RequiredAssurance == "AUDITED_ONLY" ? ", audited" : "")}.";
        }

        // The revenue of a share of revenue covenant (BR-FIN-008).
        if (k.MeasureKind == "PERCENT_OF_REVENUE" && missing is null)
        {
            switch (k.RevenueBasisRule ?? "SAME_PERIOD")
            {
                case "PRIOR_YEAR" when statement is not null:
                {
                    var prior = await FinanceInputs.PriorAsync(c, tx, statement, 12 / FinanceInputs.Months(statement.PeriodType), ct).ConfigureAwait(false);
                    if (prior?.Lines.GetValueOrDefault("REVENUE") is { } r)
                    {
                        extra["REVENUE"] = r;
                        snap.Statements!.Add(new { statementId = prior.Id, version = prior.VersionNo, basis = prior.Basis, assurance = prior.Assurance });
                        snap.Revenue = new { source = "PRIOR_YEAR", statementId = prior.Id, amount = r };
                    }
                    else missing = "No approved statement of the year before with its revenue.";
                    break;
                }
                case "MANUAL_ESTIMATE":
                {
                    var est = await c.QuerySingleOrDefaultAsync<(long Id, decimal Amount, int Currency)?>(new CommandDefinition(
                        """
                        SELECT RevenueEstimateId, Amount, CurrencyId FROM fin.RevenueEstimate
                         WHERE CompanyId = @c AND FiscalYear = @y AND Basis = @b AND Status = 'APPROVED';
                        """, new { c = k.TestedCompanyId, y = end.Year, b = k.StatementBasis ?? "STANDALONE" }, tx, cancellationToken: ct)).ConfigureAwait(false);
                    if (est is { } e)
                    {
                        extra["REVENUE"] = e.Amount;
                        snap.Revenue = new { source = "MANUAL_ESTIMATE", estimateId = e.Id, amount = e.Amount, estimated = true };
                        if (e.Currency != k.Currency) notComparable = true;
                    }
                    else missing = $"No approved revenue estimate for {end.Year}.";
                    break;
                }
                default:
                    if (statement is not null) snap.Revenue = new { source = "SAME_PERIOD", statementId = statement.Id };
                    break;
            }
        }

        // The monthly balances of the accounts in scope (BR-FIN-005, BR-FIN-006).
        var monthly = new List<(DateTime Month, decimal Avg, decimal? Min, decimal? End)>();
        if (kinds.Contains("ACCOUNT_STATS") && missing is null)
        {
            var accounts = (await c.QueryAsync<(long Id, int Currency, DateTime? Opened, DateTime? Closed)>(new CommandDefinition(
                """
                SELECT a.BankAccountId, a.CurrencyId, a.OpenedOn, a.ClosedOn FROM acc.BankAccount AS a
                 WHERE (   (@scope = 'SELECTED_ACCOUNTS' AND EXISTS (SELECT 1 FROM obl.CovenantAccount AS x WHERE x.CovenantId = @cov AND x.BankAccountId = a.BankAccountId))
                        OR (@scope <> 'SELECTED_ACCOUNTS'
                            AND (a.CompanyId = @co OR (@scope = 'GROUP_ACCOUNTS' AND a.CompanyId IN (SELECT CompanyId FROM org.Company WHERE ParentCompanyId = @co)))
                            AND EXISTS (SELECT 1 FROM fac.FacilityLender AS l WHERE l.FacilityId = @f AND l.InstitutionId = a.InstitutionId
                                          AND l.FromRevision <= @rev AND (l.ToRevision IS NULL OR l.ToRevision > @rev))))
                   AND (a.OpenedOn IS NULL OR a.OpenedOn <= @end) AND (a.ClosedOn IS NULL OR a.ClosedOn >= @start);
                """, new { scope = k.AccountScopeKind ?? "ALL_COMPANY_ACCOUNTS_AT_BANK", cov = k.CovenantId, co = k.TestedCompanyId, f = k.FacilityId, rev = k.ApprovedRevisionNo, start, end },
                tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
            var inCurrency = accounts.Where(a => a.Currency == k.Currency).ToList();
            if (accounts.Count == 0) missing = "No account of the covenant's scope.";
            else if (inCurrency.Count == 0) notComparable = true;
            else
            {
                if (inCurrency.Count < accounts.Count) snap.Note = "Accounts in another currency are left out (BR-FIN-006).";
                var ids = inCurrency.Select(a => a.Id).ToArray();
                var stats = (await c.QueryAsync<(long Account, DateTime Month, decimal Avg, decimal? Min, decimal? End)>(new CommandDefinition(
                    """
                    SELECT BankAccountId, MonthEnd, AvgDailyBalance, MinBalance, EndBalance FROM fin.AccountMonthlyStat
                     WHERE BankAccountId IN @ids AND MonthEnd BETWEEN @start AND @end AND Status = 'CONFIRMED';
                    """, new { ids, start, end }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToDictionary(s => (s.Account, s.Month));
                foreach (var m in MonthEnds(start, end))
                {
                    decimal avg = 0, min = 0, close = 0;
                    var haveMin = true;
                    var haveEnd = true;
                    foreach (var a in inCurrency)
                    {
                        var expected = (a.Opened is null || a.Opened <= m) && (a.Closed is null || a.Closed >= m.AddDays(1).AddMonths(-1));
                        if (!expected) continue;
                        if (!stats.TryGetValue((a.Id, m), out var s)) { missing ??= $"The confirmed balance of an account for {m:yyyy-MM} is missing."; continue; }
                        avg += s.Avg;
                        if (s.Min is { } mn) min += mn; else haveMin = false;
                        if (s.End is { } en) close += en; else haveEnd = false;
                        snap.Accounts!.Add(new { accountId = a.Id, month = Day(m), value = s.Avg });
                    }
                    monthly.Add((m, avg, haveMin ? min : null, haveEnd ? close : null));
                }
            }
            if (missing is null && monthly.Count > 0)
            {
                var mode = k.AggregationMode ?? "PERIOD_AVERAGE";
                extra[Formula.AvgBalance] = CovenantJudge.Aggregate([.. monthly.Select(x => x.Avg)], mode);
                extra[Formula.MinBalance] = monthly.All(x => x.Min is not null) ? monthly.Min(x => x.Min!.Value) : null;
                extra[Formula.EndBalance] = monthly[^1].End;
            }
        }

        // The confirmed flows of the period to the facility's banks (OQ-8, BR-FIN-016).
        if (kinds.Contains("BANK_FLOWS") && missing is null)
        {
            var flows = (await c.QueryAsync<(long Id, decimal Amount)>(new CommandDefinition(
                """
                SELECT e.BankFlowEntryId, e.Amount FROM fin.BankFlowEntry AS e
                 WHERE e.Status = 'CONFIRMED' AND e.CurrencyId = @cur AND e.MonthEnd BETWEEN @start AND @end AND (e.FacilityId IS NULL OR e.FacilityId = @f)
                   AND (e.CompanyId = @co OR EXISTS (SELECT 1 FROM obl.ObligationCompany AS oc WHERE oc.ObligationId = @o AND oc.CompanyId = e.CompanyId))
                   AND EXISTS (SELECT 1 FROM fac.FacilityLender AS l WHERE l.FacilityId = @f AND l.InstitutionId = e.InstitutionId
                                 AND l.FromRevision <= @rev AND (l.ToRevision IS NULL OR l.ToRevision > @rev));
                """, new { cur = k.Currency, start, end, f = k.FacilityId, co = k.TestedCompanyId, o = k.ObligationId, rev = k.ApprovedRevisionNo }, tx, cancellationToken: ct))
                .ConfigureAwait(false)).ToList();
            if (flows.Count == 0) missing = $"No confirmed flow to the facility's banks between {Day(start)} and {Day(end)}.";
            else
            {
                foreach (var x in flows) snap.Flows!.Add(new { entryId = x.Id, amount = x.Amount });
                extra[Formula.FlowToBank] = flows.Sum(x => x.Amount);
            }
        }

        if (missing is not null || notComparable) return new Outcome(null, missing, notComparable && missing is null, snap, fv?.MeasureFormulaId);

        decimal? actual;
        if (parsed is not null)
        {
            var current = statement?.Lines ?? new Dictionary<string, decimal?>();
            var (inputs, read) = statement is not null
                ? await FinanceInputs.ForStatementAsync(c, tx, statement, parsed.Tree!, extra, ct).ConfigureAwait(false)
                : (new DictionaryInputs(extra), new List<StatementInput>());
            foreach (var r in read.Skip(1)) snap.Statements?.Add(new { statementId = r.Id, version = r.VersionNo, basis = r.Basis, assurance = r.Assurance });
            foreach (var code in parsed.Codes.Order()) snap.Inputs[code] = extra.TryGetValue(code, out var ev) ? ev : current.GetValueOrDefault(code);
            var v = Formula.Evaluate(parsed.Tree!, inputs);
            if (v.Value is null) return new Outcome(null, $"The formula is undefined: {v.Undefined}.", false, snap, fv!.MeasureFormulaId);
            actual = v.Value;
        }
        else
        {
            actual = k.MeasureKind == "AVERAGE_BALANCE" ? extra.GetValueOrDefault(Formula.AvgBalance) : extra.GetValueOrDefault(Formula.FlowToBank);
            foreach (var (code, value) in extra) snap.Inputs[code] = value;
        }
        return new Outcome(actual, actual is null ? "No value." : null, false, snap, fv?.MeasureFormulaId);
    }

    private static string Day(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    // ---------- the evaluation ----------

    internal sealed class TestRow
    {
        public long CovenantTestId { get; init; }
        public Guid PublicId { get; init; }
        public long CovenantRootId { get; init; }
        public long CovenantId { get; init; }
        public DateTime PeriodStart { get; init; }
        public DateTime PeriodEnd { get; init; }
        public DateTime DueDate { get; init; }
        public int EvaluationNo { get; init; }
        public string State { get; init; } = "";
        public string? Result { get; init; }
        public string Method { get; init; } = "";
        public string? InputsSnapshot { get; init; }
    }

    /// <summary>What an evaluation did: the test row written (the same or a new one) and its result, or none when the data is still awaited.</summary>
    public sealed record Evaluated(long? TestId, Guid? PublicId, string? Result, bool NewRow);

    /// <summary>
    /// Evaluates the latest test of a covenant and period. A test not yet evaluated is evaluated in place, or becomes
    /// PENDING_DATA while its data is missing before its due date; an evaluated one is re-evaluated as a new row when
    /// <paramref name="again"/>, or when its result was MISSING_DATA and the data has come.
    /// </summary>
    public static async Task<Evaluated> EvaluateAsync(SqlConnection c, SqlTransaction tx, long testId, DateTime today, long? actor, bool again, CancellationToken ct)
    {
        var t = await c.QuerySingleAsync<TestRow>(new CommandDefinition(
            """
            SELECT CovenantTestId, PublicId, CovenantRootId, CovenantId, PeriodStart, PeriodEnd, DueDate, EvaluationNo, State, Result, Method, InputsSnapshot
              FROM obl.CovenantTest WITH (UPDLOCK, HOLDLOCK) WHERE CovenantTestId = @id;
            """, new { id = testId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (t.State == "CANCELLED") return new Evaluated(null, null, null, false);
        var k = await c.QuerySingleAsync<CovenantRow>(new CommandDefinition(CovenantSelect + " WHERE c.CovenantId = @id;", new { id = t.CovenantId }, tx, cancellationToken: ct))
            .ConfigureAwait(false);
        var evaluated = t.State is "EVALUATED" or "REVIEWED";
        if (evaluated && t.Method == "AUTO" && t.Result != "MISSING_DATA" && !again) return new Evaluated(t.CovenantTestId, t.PublicId, t.Result, false);
        if (!evaluated && t.PeriodEnd >= today) return new Evaluated(null, null, null, false);
        var o = await InputsAsync(c, tx, k, t.PeriodStart, t.PeriodEnd, ct).ConfigureAwait(false);
        if (o.Missing is not null && !o.NotComparable)
        {
            if (evaluated) return new Evaluated(t.CovenantTestId, t.PublicId, t.Result, false);   // still missing: the result stays
            if (today <= t.DueDate)
            {
                if (t.State == "SCHEDULED")
                    await c.ExecuteAsync(new CommandDefinition(
                        "UPDATE obl.CovenantTest SET State = 'PENDING_DATA', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE CovenantTestId = @id;",
                        new { id = t.CovenantTestId }, tx, cancellationToken: ct)).ConfigureAwait(false);
                return new Evaluated(null, null, null, false);
            }
            o.Snapshot.Reason = o.Missing;
        }
        var (_, defaultWarning) = await DefaultsAsync(c, tx, ct).ConfigureAwait(false);
        string result;
        decimal? actual = null, headroom = null, pct = null, threshold = null;
        string? op = null;
        if (o.NotComparable) { result = "NOT_COMPARABLE"; o.Snapshot.Reason ??= "An input is in a currency other than the covenant's."; }
        else if (o.Missing is not null) result = "MISSING_DATA";
        else
        {
            var j = CovenantJudge.Judge(o.Actual!.Value, k.ThresholdState == "SET" ? k.ThresholdValue : null, k.ThresholdState == "SET" ? k.Operator : null,
                k.EarlyWarningPct ?? defaultWarning);
            result = j.Result;
            actual = CovenantJudge.Stored(o.Actual.Value);
            if (k.ThresholdState == "SET") { threshold = k.ThresholdValue; op = k.Operator; }
            headroom = j.Headroom is { } h ? CovenantJudge.Stored(h) : null;
            pct = j.HeadroomPct is { } p ? CovenantJudge.Stored(p) : null;
            o.Snapshot.Inputs["ACTUAL"] = o.Actual;
        }
        var snapshot = JsonSerializer.Serialize(o.Snapshot, Json);
        var p0 = new
        {
            id = t.CovenantTestId, root = t.CovenantRootId, cov = k.CovenantId, start = t.PeriodStart, end = t.PeriodEnd, due = t.DueDate, result, actual, threshold, op, headroom, pct,
            snap = snapshot, formula = o.FormulaVersionId, actor,
        };
        long id;
        Guid publicId;
        if (!evaluated)
        {
            await c.ExecuteAsync(new CommandDefinition(
                """
                UPDATE obl.CovenantTest
                   SET State = 'EVALUATED', CovenantId = @cov, Result = @result, ActualValue = @actual, ThresholdApplied = @threshold, OperatorApplied = @op, Headroom = @headroom,
                       HeadroomPct = @pct, InputsSnapshot = @snap, FormulaId = @formula, EvaluatedAt = SYSUTCDATETIME(), EvaluatedBy = @actor,
                       UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE CovenantTestId = @id;
                """, p0, tx, cancellationToken: ct)).ConfigureAwait(false);
            (id, publicId) = (t.CovenantTestId, t.PublicId);
        }
        else
        {
            (id, publicId) = await c.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
                DECLARE @n INT = (SELECT MAX(EvaluationNo) FROM obl.CovenantTest WITH (UPDLOCK, HOLDLOCK) WHERE CovenantRootId = @root AND PeriodEnd = @end) + 1;
                INSERT obl.CovenantTest (TenantId, CovenantRootId, CovenantId, PeriodStart, PeriodEnd, DueDate, EvaluationNo, State, Result, Method, ActualValue, ThresholdApplied,
                                         OperatorApplied, Headroom, HeadroomPct, InputsSnapshot, FormulaId, EvaluatedAt, EvaluatedBy, CreatedBy)
                OUTPUT inserted.CovenantTestId, inserted.PublicId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @root, @cov, @start, @end, @due, @n, 'EVALUATED', @result, 'AUTO', @actual, @threshold, @op, @headroom, @pct,
                        @snap, @formula, SYSUTCDATETIME(), @actor, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id, PublicId FROM @o;
                """, p0, tx, cancellationToken: ct)).ConfigureAwait(false);
        }
        await AfterAsync(c, tx, k, id, t.PeriodEnd, t.DueDate, result, evaluated, today, ct).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "covenant.test.evaluated", "obl.CovenantTest", id, new { test = publicId, result }, ct).ConfigureAwait(false);
        return new Evaluated(id, publicId, result, evaluated);
    }

    /// <summary>
    /// A value entered by hand with its evidence (Method MANUAL_VALUE, FR-FIN-012 "manually"): a new evaluation of the
    /// test's covenant and period, judged on the covenant's own threshold and operator, with its breach and alerts.
    /// </summary>
    public static async Task<Evaluated> ManualValueAsync(SqlConnection c, SqlTransaction tx, long testId, decimal value, long evidence, string? note, DateTime today, long actor,
        CancellationToken ct)
    {
        var t = await c.QuerySingleAsync<TestRow>(new CommandDefinition(
            """
            SELECT CovenantTestId, PublicId, CovenantRootId, CovenantId, PeriodStart, PeriodEnd, DueDate, EvaluationNo, State, Result, Method, InputsSnapshot
              FROM obl.CovenantTest WITH (UPDLOCK, HOLDLOCK) WHERE CovenantTestId = @id;
            """, new { id = testId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var k = await c.QuerySingleAsync<CovenantRow>(new CommandDefinition(CovenantSelect + " WHERE c.CovenantId = @id;", new { id = t.CovenantId }, tx, cancellationToken: ct))
            .ConfigureAwait(false);
        var (_, defaultWarning) = await DefaultsAsync(c, tx, ct).ConfigureAwait(false);
        var set = k.ThresholdState == "SET";
        var j = CovenantJudge.Judge(value, set ? k.ThresholdValue : null, set ? k.Operator : null, k.EarlyWarningPct ?? defaultWarning);
        var snap = JsonSerializer.Serialize(new { manual = new { value, evidenceDocumentId = evidence, note }, threshold = set ? new { value = k.ThresholdValue, @operator = k.Operator } : null }, Json);
        var p = new
        {
            id = t.CovenantTestId, root = t.CovenantRootId, cov = k.CovenantId, start = t.PeriodStart, end = t.PeriodEnd, due = t.DueDate, result = j.Result,
            actual = CovenantJudge.Stored(value), threshold = set ? k.ThresholdValue : null, op = set ? k.Operator : null,
            headroom = j.Headroom is { } h ? CovenantJudge.Stored(h) : (decimal?)null, pct = j.HeadroomPct is { } x ? CovenantJudge.Stored(x) : (decimal?)null, snap, evidence, actor,
            note,
        };
        long id;
        Guid publicId;
        var inPlace = t.State is "SCHEDULED" or "PENDING_DATA";
        if (inPlace)
        {
            await c.ExecuteAsync(new CommandDefinition(
                """
                UPDATE obl.CovenantTest
                   SET State = 'EVALUATED', CovenantId = @cov, Result = @result, Method = 'MANUAL_VALUE', ActualValue = @actual, ThresholdApplied = @threshold, OperatorApplied = @op,
                       Headroom = @headroom, HeadroomPct = @pct, InputsSnapshot = @snap, EvidenceDocumentId = @evidence, EvaluatedAt = SYSUTCDATETIME(), EvaluatedBy = @actor,
                       UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @actor
                 WHERE CovenantTestId = @id;
                """, p, tx, cancellationToken: ct)).ConfigureAwait(false);
            (id, publicId) = (t.CovenantTestId, t.PublicId);
        }
        else
            (id, publicId) = await c.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
                DECLARE @n INT = (SELECT MAX(EvaluationNo) FROM obl.CovenantTest WITH (UPDLOCK, HOLDLOCK) WHERE CovenantRootId = @root AND PeriodEnd = @end) + 1;
                INSERT obl.CovenantTest (TenantId, CovenantRootId, CovenantId, PeriodStart, PeriodEnd, DueDate, EvaluationNo, State, Result, Method, ActualValue, ThresholdApplied,
                                         OperatorApplied, Headroom, HeadroomPct, InputsSnapshot, EvidenceDocumentId, EvaluatedAt, EvaluatedBy, CreatedBy)
                OUTPUT inserted.CovenantTestId, inserted.PublicId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @root, @cov, @start, @end, @due, @n, 'EVALUATED', @result, 'MANUAL_VALUE', @actual, @threshold, @op, @headroom,
                        @pct, @snap, @evidence, SYSUTCDATETIME(), @actor, @actor);
                SELECT Id, PublicId FROM @o;
                """, p, tx, cancellationToken: ct)).ConfigureAwait(false);
        await AfterAsync(c, tx, k, id, t.PeriodEnd, t.DueDate, j.Result, !inPlace, today, ct).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "covenant.test.evaluated", "obl.CovenantTest", id, new { test = publicId, result = j.Result }, ct).ConfigureAwait(false);
        return new Evaluated(id, publicId, j.Result, !inPlace);
    }

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };

    /// <summary>The breach and the alerts of a result (BR-OBL-008, BR-OBL-011, OQ-7).</summary>
    private static async Task AfterAsync(SqlConnection c, SqlTransaction tx, CovenantRow k, long testId, DateTime periodEnd, DateTime due, string result, bool again, DateTime today,
        CancellationToken ct)
    {
        var breaches = (await c.QueryAsync<(long Id, string Status)>(new CommandDefinition(
            "SELECT ObligationBreachId, Status FROM obl.ObligationBreach WITH (UPDLOCK, HOLDLOCK) WHERE CovenantRootId = @root AND TestPeriodEnd = @end ORDER BY ObligationBreachId DESC;",
            new { root = k.RootId, end = periodEnd }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var open = breaches.FirstOrDefault(b => b.Status is "OPEN" or "IN_CURE");
        if (result == "BREACH" || (again && open.Id != 0))
        {
            var mark = open.Id != 0 ? open.Id : breaches.Count > 0 ? breaches[0].Id : 0;
            if (mark != 0)
                await c.ExecuteAsync(new CommandDefinition(
                    "UPDATE obl.ObligationBreach SET NeedsReview = 1, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ObligationBreachId = @id;",
                    new { id = mark }, tx, cancellationToken: ct)).ConfigureAwait(false);
            else if (result == "BREACH")
                await OpenBreachAsync(c, tx, k, testId, periodEnd, today, ct).ConfigureAwait(false);
        }
        var values = await ValuesAsync(c, tx, k, ct).ConfigureAwait(false);
        if (result == "WARNING")
        {
            values["periodEnd"] = Day(periodEnd);
            var facility = await c.ExecuteScalarAsync<Guid>(new CommandDefinition("SELECT PublicId FROM fac.Facility WHERE FacilityId = @f;", new { f = k.FacilityId }, tx,
                cancellationToken: ct)).ConfigureAwait(false);
            await Notifier.RequestAsync(c, tx, new NotificationRequest("CMP.WARNING", "obl.CovenantTest", testId, $"CMP.WARNING:{testId}", k.BorrowerCompanyId, values,
                $"/facilities/{facility}"), ct).ConfigureAwait(false);
        }
        if (result == "MISSING_DATA") await DataMissingAsync(c, tx, k, testId, periodEnd, due, today, ct).ConfigureAwait(false);
    }

    private static async Task<Dictionary<string, object?>> ValuesAsync(SqlConnection c, SqlTransaction tx, CovenantRow k, CancellationToken ct)
    {
        var co = await c.QuerySingleAsync<(string Ar, string? En)>(new CommandDefinition("SELECT NameAr, NameEn FROM org.Company WHERE CompanyId = @c;", new { c = k.BorrowerCompanyId },
            tx, cancellationToken: ct)).ConfigureAwait(false);
        var bank = await c.QuerySingleOrDefaultAsync<(string? Ar, string? En)?>(new CommandDefinition(
            """
            SELECT TOP (1) i.NameAr, i.NameEn FROM fac.FacilityLender AS l JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId
             WHERE l.FacilityId = @f AND l.FromRevision <= @rev AND (l.ToRevision IS NULL OR l.ToRevision > @rev)
             ORDER BY CASE WHEN l.Roles LIKE '%AGENT%' OR l.Roles LIKE '%SOLE%' OR l.Roles LIKE '%LEAD%' THEN 0 ELSE 1 END;
            """, new { f = k.FacilityId, rev = k.ApprovedRevisionNo }, tx, cancellationToken: ct)).ConfigureAwait(false);
        return new Dictionary<string, object?>
        {
            ["facilityNo"] = k.FacilityNo,
            ["companyName"] = new Dictionary<string, string?> { ["ar"] = co.Ar, ["en"] = co.En ?? co.Ar },
            ["bankName"] = new Dictionary<string, string?> { ["ar"] = bank?.Ar ?? bank?.En ?? "", ["en"] = bank?.En ?? bank?.Ar ?? "" },
            ["obligationTitle"] = new Dictionary<string, string?> { ["ar"] = k.TitleAr, ["en"] = k.TitleEn ?? k.TitleAr },
        };
    }

    private static async Task OpenBreachAsync(SqlConnection c, SqlTransaction tx, CovenantRow k, long testId, DateTime periodEnd, DateTime today, CancellationToken ct)
    {
        var cure = k.CureDays is > 0 ? today.AddDays(k.CureDays.Value) : (DateTime?)null;
        var (id, publicId) = await c.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT obl.ObligationBreach (TenantId, ObligationRootId, ObligationId, Kind, CovenantRootId, TestPeriodEnd, CovenantTestId, DetectedOn, Description, Status, CureDeadline,
                                         CreatedBy)
            OUTPUT inserted.ObligationBreachId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @oroot, @o2, 'COVENANT_BREACH', @root, @end, @test, @today, @desc, @status, @cure,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new
        {
            oroot = k.ObligationRootId, o2 = k.ObligationId, root = k.RootId, end = periodEnd, test = testId, today, status = cure is null ? "OPEN" : "IN_CURE", cure,
            desc = $"The covenant test of the period ending {Day(periodEnd)} is a breach.",
        }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var values = await ValuesAsync(c, tx, k, ct).ConfigureAwait(false);
        values["breachLabel"] = new Dictionary<string, string> { ["ar"] = "خرق تعهد", ["en"] = "covenant breach" };
        values["dueDate"] = Day(periodEnd);
        await Notifier.RequestAsync(c, tx, new NotificationRequest("CMP.BREACH", "obl.ObligationBreach", id, $"CMP.BREACH:{id}", k.BorrowerCompanyId, values, "/breaches"), ct)
            .ConfigureAwait(false);
        await AuditWriter.WriteAsync(c, tx, new AuditEntry("BREACH_OPENED", "TREASURY", "obl.ObligationBreach", id,
            AfterJson: JsonSerializer.Serialize(new { kind = "COVENANT_BREACH", periodEnd = Day(periodEnd), cureDeadline = cure is { } x ? Day(x) : null })), k.BorrowerCompanyId, ct)
            .ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "breach.opened", "obl.ObligationBreach", id, new { breach = publicId }, ct).ConfigureAwait(false);
    }

    /// <summary>NTF-OBL-05: FIN.DATA_MISSING the day after the due date, then weekly while the data stays missing (OQ-15).</summary>
    private static async Task DataMissingAsync(SqlConnection c, SqlTransaction tx, CovenantRow k, long testId, DateTime periodEnd, DateTime due, DateTime today, CancellationToken ct)
    {
        var week = (today - due).Days / 7;
        var values = await ValuesAsync(c, tx, k, ct).ConfigureAwait(false);
        values["periodEnd"] = Day(periodEnd);
        values["dueDate"] = Day(due);
        await Notifier.RequestAsync(c, tx, new NotificationRequest("FIN.DATA_MISSING", "obl.CovenantTest", testId, $"FIN.DATA_MISSING:{k.RootId}:{Day(periodEnd)}:{week}",
            k.BorrowerCompanyId, values, "/breaches"), ct).ConfigureAwait(false);
    }

    // ---------- the runs ----------

    /// <summary>
    /// JOB-FIN-EVAL's pass (OQ-5, OQ-15): the calendar of each active facility; the tests whose period ended are evaluated;
    /// the MISSING_DATA results are tried again (a new row once the data has come) and recalled weekly.
    /// </summary>
    public static async Task<int> RunAsync(SqlConnection c, DateTime today, CancellationToken ct)
    {
        var n = 0;
        var facilities = (await c.QueryAsync<long>(new CommandDefinition(
            "SELECT FacilityId FROM fac.Facility WHERE LifecycleStatus = 'ACTIVE' AND ApprovedRevisionNo >= 1;", cancellationToken: ct)).ConfigureAwait(false)).ToList();
        foreach (var f in facilities)
        {
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            n += await ScheduleAsync(c, tx, f, today, ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        var due = (await c.QueryAsync<(long Id, string State, DateTime Due, string? Result)>(new CommandDefinition(
            """
            SELECT t.CovenantTestId, t.State, t.DueDate, t.Result FROM obl.CovenantTest AS t
             WHERE t.Method = 'AUTO' AND t.PeriodEnd < @today
               AND (t.State IN ('SCHEDULED', 'PENDING_DATA')
                    OR (t.State = 'EVALUATED' AND t.Result = 'MISSING_DATA'
                        AND t.EvaluationNo = (SELECT MAX(x.EvaluationNo) FROM obl.CovenantTest AS x WHERE x.CovenantRootId = t.CovenantRootId AND x.PeriodEnd = t.PeriodEnd)));
            """, new { today }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        foreach (var t in due)
        {
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            var r = await EvaluateAsync(c, tx, t.Id, today, null, again: false, ct).ConfigureAwait(false);
            if (r.TestId is not null && (r.NewRow || t.State != "EVALUATED")) n++;
            else if (t.Result == "MISSING_DATA")
            {
                var k = await c.QuerySingleAsync<CovenantRow>(new CommandDefinition(CovenantSelect +
                    " WHERE c.CovenantId = (SELECT CovenantId FROM obl.CovenantTest WHERE CovenantTestId = @id);", new { id = t.Id }, tx, cancellationToken: ct)).ConfigureAwait(false);
                var end = await c.ExecuteScalarAsync<DateTime>(new CommandDefinition("SELECT PeriodEnd FROM obl.CovenantTest WHERE CovenantTestId = @id;", new { id = t.Id }, tx,
                    cancellationToken: ct)).ConfigureAwait(false);
                await DataMissingAsync(c, tx, k, t.Id, end, t.Due, today, ct).ConfigureAwait(false);
            }
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        n += await BalancesMissingAsync(c, today, ct).ConfigureAwait(false);
        return n;
    }

    /// <summary>
    /// NTF-FIN-01 (FR-FIN-008): from the 7th of a month, FIN.BALANCES_MISSING for each account expected to have a figure
    /// for the month before and without one, weekly while it stays missing. An account is expected from its opening (or
    /// its first figure) to its closing.
    /// </summary>
    public static async Task<int> BalancesMissingAsync(SqlConnection c, DateTime today, CancellationToken ct)
    {
        if (today.Day < 7) return 0;
        var month = new DateTime(today.Year, today.Month, 1).AddDays(-1);
        var rows = (await c.QueryAsync<(long Id, long Company, string Mask, string? CoAr, string? CoEn, string? BankAr, string? BankEn)>(new CommandDefinition(
            """
            SELECT a.BankAccountId, a.CompanyId, a.AccountNoMask, co.NameAr, co.NameEn, i.NameAr, i.NameEn
              FROM acc.BankAccount AS a
              JOIN org.Company AS co ON co.CompanyId = a.CompanyId
              JOIN ins.Institution AS i ON i.InstitutionId = a.InstitutionId
             WHERE a.Status <> 'CLOSED' AND (a.ClosedOn IS NULL OR a.ClosedOn >= DATEADD(DAY, 1, EOMONTH(@m, -1)))
               AND (a.OpenedOn <= @m OR (a.OpenedOn IS NULL AND EXISTS (SELECT 1 FROM fin.AccountMonthlyStat AS s WHERE s.BankAccountId = a.BankAccountId AND s.MonthEnd < @m)))
               AND NOT EXISTS (SELECT 1 FROM fin.AccountMonthlyStat AS s WHERE s.BankAccountId = a.BankAccountId AND s.MonthEnd = @m)
               AND NOT EXISTS (SELECT 1 FROM cat.AccountType AS t WHERE t.AccountTypeId = a.AccountTypeId AND t.IsVirtual = 1);
            """, new { m = month }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var week = (today.Day - 7) / 7;
        foreach (var r in rows)
            await Notifier.RequestAsync(c, null, new NotificationRequest("FIN.BALANCES_MISSING", "acc.BankAccount", r.Id, $"FIN.BALANCES_MISSING:{r.Id}:{Day(month)}:{week}", r.Company,
                new Dictionary<string, object?>
                {
                    ["companyName"] = new Dictionary<string, string?> { ["ar"] = r.CoAr, ["en"] = r.CoEn ?? r.CoAr },
                    ["bankName"] = new Dictionary<string, string?> { ["ar"] = r.BankAr ?? r.BankEn, ["en"] = r.BankEn ?? r.BankAr },
                    ["accountLabel"] = r.Mask,
                    ["monthLabel"] = month.ToString("yyyy-MM", CultureInfo.InvariantCulture),
                }, "/monthly-figures"), ct).ConfigureAwait(false);
        return rows.Count;
    }

    /// <summary>
    /// The statement.approved consumer (OQ-13, FR-FIN-014): the tests of the company's covenants for the statement's
    /// period end that read statements are evaluated, or re-evaluated as a new row when they had read another statement
    /// or missed it.
    /// </summary>
    public static async Task<int> StatementApprovedAsync(SqlConnection c, long statementId, DateTime today, CancellationToken ct)
    {
        var s = await c.QuerySingleOrDefaultAsync<(long Company, DateTime End, string Basis)?>(new CommandDefinition(
            "SELECT CompanyId, PeriodEnd, Basis FROM fin.FinancialStatement WHERE FinancialStatementId = @s AND Status = 'APPROVED';", new { s = statementId },
            cancellationToken: ct)).ConfigureAwait(false);
        if (s is not { } st) return 0;
        var tests = (await c.QueryAsync<(long Id, string State, string? Snapshot)>(new CommandDefinition(
            """
            SELECT t.CovenantTestId, t.State, t.InputsSnapshot FROM obl.CovenantTest AS t
              JOIN obl.Covenant AS cv ON cv.CovenantId = t.CovenantId
             WHERE cv.TestedCompanyId = @c AND t.PeriodEnd = @e AND ISNULL(cv.StatementBasis, 'STANDALONE') = @b AND t.Method = 'AUTO' AND t.State <> 'CANCELLED'
               AND (cv.FormulaUsesStatements = 1 OR cv.MeasureKind = 'PERCENT_OF_REVENUE')
               AND t.EvaluationNo = (SELECT MAX(x.EvaluationNo) FROM obl.CovenantTest AS x WHERE x.CovenantRootId = t.CovenantRootId AND x.PeriodEnd = t.PeriodEnd);
            """, new { c = st.Company, e = st.End, b = st.Basis }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var n = 0;
        foreach (var t in tests)
        {
            var read = t.Snapshot is not null && t.Snapshot.Contains($"\"statementId\":{statementId},", StringComparison.Ordinal);
            if (read) continue;
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            var r = await EvaluateAsync(c, tx, t.Id, today, null, again: t.State is "EVALUATED" or "REVIEWED", ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
            if (r.TestId is not null) n++;
        }
        return n;
    }
}

/// <summary>JOB-FIN-EVAL (OQ-5): after JOB-OBL-CALENDAR, on the tenant's local date, the covenant calendar, the evaluations and the missing-data alerts.</summary>
public sealed class FinanceEvaluationJob(SqlConnectionFactory db, TimeProvider clock) : Jobs.TenantJob(db)
{
    public override string JobKey => "JOB-FIN-EVAL";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var n = await CovenantEngine.RunAsync(c, tenant.LocalDate(clock.GetUtcNow()), ct).ConfigureAwait(false);
        return n == 0 ? null : $"tests and alerts {n}";
    }
}

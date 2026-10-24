using System.Data;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Finance;
using BankFas.Core.Obligations;
using BankFas.Data;
using BankFas.Data.Facilities;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record ReportingRequest(string? Frequency, string? AnchorKind, int? OffsetValue, string? OffsetUnit, string? FixedDueDate, string? Direction, string? DocumentBasis,
    string? StatementScope, string? ChannelNote, string? AlertLeadDays, string? FirstPeriodEnd, int? HorizonMonths, bool? ExpectsEvidence);
public sealed record CovenantRequest(string? MeasureKind, string? Formula, string? Operator, string? ThresholdState, decimal? ThresholdValue, string? ThresholdUnit, string? Currency,
    string? TestFrequency, Guid? TestedCompany, string? FirstTestPeriodEnd, string? StatementBasis, string? RequiredAssurance, string? ValidFrom, string? AggregationMode = null,
    string? AnnualWindowBasis = null, string? RevenueBasisRule = null, string? AccountScope = null, Guid[]? Accounts = null, int? SubmissionLagDays = null,
    decimal? EarlyWarningPct = null, string? ValidTo = null);
public sealed record ObligationRequest(string? ObligationType, string? TitleAr, string? TitleEn, string? Phase, string? ScopeLimit, string? ClauseRef, string? ClauseText,
    string? ConsequenceText, int? GraceDays, int? CureDays, decimal? ParamValue, string? ParamUnit, string? ParamCurrency, string? CheckMode, string? ValidFrom, string? ValidTo,
    Guid[]? Companies, Guid? SourceDocument, string? SourcePage, bool? ReadFromScan, string? OriginalText, string? NoSourceReason, ReportingRequest? Reporting,
    CovenantRequest? Covenant);
public sealed record SubmitRequest(string? SubmittedOn, string? SubmissionRef, Guid? EvidenceDocument, decimal? ReportedAmount, string? Currency);
public sealed record ReasonRequest(string? Reason, Guid? Document);
public sealed record RescheduleRequest(string? DueDate, string? Reason);
public sealed record EventRequest(string? EventDate, string? Note);

public sealed record CovenantReviewRequest(string? Status, string? ReviewDate, string? Note, Guid? Evidence, string? NextReviewOn);
public sealed record BreachRequest(Guid? Facility, string? Obligation, string? Kind, string? DetectedOn, string? Description);
public sealed record BreachActionRequest(string? On, string? Reason, string? WaiverRef, string? WaiverDate, Guid? BankContact, string? Conditions, string? ValidUntil, Guid? Document);

/// <summary>
/// Obligations, the agenda and breaches (spec 12 section 5, FR-OBL-001 to 016; BR-OBL-001 to 010; S2 part per OQ-16).
/// Obligations are rows of the facility revision: their family comes from the type; a reporting rule or a covenant
/// is written with its obligation in the draft and approved with it, and the approval generates the agenda. Items are
/// submitted (late ones open a LATE_REPORT breach and raise CMP.BREACH), waived by obl.waiver.approve with a reason and
/// a document, marked not applicable, or rescheduled with a reason. An event-based notice is due N working days before
/// its logged event. Breaches: LATE_REPORT and manual ones, cure with its deadline (BR-OBL-009), the bank notice, and a
/// waiver recorded with its reference, date, bank contact and document, then approved by a treasury manager who did
/// not record it. Covenant tests and their breaches are S2-b.
/// </summary>
public static class ObligationEndpoints
{
    internal const string View = "obl.view";
    private const string Manage = "obl.manage";
    internal const string Record = "obl.record";
    private const string WaiverApprove = "obl.waiver.approve";
    private const string BreachManage = "obl.breach.manage";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/facilities/{id:guid}/obligations", ListAsync);
        api.MapPost("/facilities/{id:guid}/obligations", AddAsync);
        api.MapPut("/facilities/{id:guid}/obligations/{reference}", ChangeAsync);
        api.MapDelete("/facilities/{id:guid}/obligations/{reference}", RemoveAsync);
        api.MapGet("/facilities/{id:guid}/agenda", AgendaAsync);
        api.MapPost("/facilities/{id:guid}/obligations/{reference}/events", EventAsync);
        api.MapGet("/facilities/{id:guid}/obligations/{reference}/reviews", ReviewsAsync);
        api.MapPost("/facilities/{id:guid}/obligations/{reference}/reviews", ReviewAsync);
        api.MapPost("/reporting-instances/{id:guid}/actions/submit", SubmitAsync);
        api.MapPost("/reporting-instances/{id:guid}/actions/waive", WaiveAsync);
        api.MapPost("/reporting-instances/{id:guid}/actions/not-applicable", NotApplicableAsync);
        api.MapPost("/reporting-instances/{id:guid}/actions/reschedule", RescheduleAsync);
        api.MapGet("/breaches", BreachesAsync);
        api.MapPost("/breaches", OpenBreachAsync);
        api.MapPost("/breaches/{id:guid}/actions/{action}", BreachActionAsync);
        api.MapGet("/facilities/{id:guid}/compliance", ComplianceAsync);
        api.MapGet("/reports/compliance", GroupComplianceAsync);
    }

    // ---------- the obligations of a revision ----------

    internal sealed class ObligationRow
    {
        public long ObligationId { get; init; }
        public long RootId { get; init; }
        public string Family { get; init; } = "";
        public string TypeCode { get; init; } = "";
        public string TitleAr { get; init; } = "";
        public string? TitleEn { get; init; }
        public string Phase { get; init; } = "";
        public long? ScopeLimitRoot { get; init; }
        public string? ScopeLimitCode { get; init; }
        public string? ClauseRef { get; init; }
        public string? ClauseText { get; init; }
        public int? GraceDays { get; init; }
        public int? CureDays { get; init; }
        public decimal? ParamValue { get; init; }
        public string? ParamUnit { get; init; }
        public string? CheckMode { get; init; }
        public string Status { get; init; } = "";
        public DateTime ValidFrom { get; init; }
        public DateTime? ValidTo { get; init; }
        public int FromRevision { get; init; }
        public long? ReportingObligationId { get; init; }
        public string? Frequency { get; init; }
        public string? AnchorKind { get; init; }
        public int? OffsetValue { get; init; }
        public string? OffsetUnit { get; init; }
        public DateTime? FixedDueDate { get; init; }
        public string? Direction { get; init; }
        public string? DocumentBasis { get; init; }
        public string? AlertLeadDays { get; init; }
        public long? CovenantId { get; init; }
        public string? MeasureKind { get; init; }
        public string? FormulaCode { get; init; }
        public string? Operator { get; init; }
        public string? ThresholdState { get; init; }
        public decimal? ThresholdValue { get; init; }
        public string? ThresholdUnit { get; init; }
        public string? TestFrequency { get; init; }
        public string? AggregationMode { get; init; }
        public string? AnnualWindowBasis { get; init; }
        public string? RevenueBasisRule { get; init; }
        public string? AccountScopeKind { get; init; }
        public string? StatementBasis { get; init; }
        public string? RequiredAssurance { get; init; }
        public int? SubmissionLagDays { get; init; }
        public decimal? EarlyWarningPct { get; init; }
        public DateTime? FirstTestPeriodEnd { get; init; }
    }

    private static string Valid(string a, int rev) => rev == int.MaxValue ? $"{a}.ToRevision IS NULL" : $"{a}.FromRevision <= {rev} AND ({a}.ToRevision IS NULL OR {a}.ToRevision > {rev})";

    internal static async Task<List<ObligationRow>> RowsAsync(SqlConnection c, SqlTransaction? tx, long facility, int rev, CancellationToken ct) =>
        [.. await c.QueryAsync<ObligationRow>(new CommandDefinition(
            $"""
            SELECT o.ObligationId, o.RootId, o.Family, t.Code AS TypeCode, o.TitleAr, o.TitleEn, o.Phase, l.RootId AS ScopeLimitRoot, l.Code AS ScopeLimitCode, o.ClauseRef,
                   o.ClauseText, o.GraceDays, o.CureDays, o.ParamValue, o.ParamUnit, o.CheckMode, o.Status, o.ValidFrom, o.ValidTo, o.FromRevision,
                   r.ReportingObligationId, r.Frequency, r.AnchorKind, r.OffsetValue, r.OffsetUnit, r.FixedDueDate, r.Direction, r.DocumentBasis, r.AlertLeadDays,
                   cv.CovenantId, cv.MeasureKind, mf.Code AS FormulaCode, cv.Operator, cv.ThresholdState, cv.ThresholdValue, cv.ThresholdUnit, cv.TestFrequency,
                   cv.AggregationMode, cv.AnnualWindowBasis, cv.RevenueBasisRule, cv.AccountScopeKind, cv.StatementBasis, cv.RequiredAssurance, cv.SubmissionLagDays,
                   cv.EarlyWarningPct, cv.FirstTestPeriodEnd
              FROM obl.Obligation AS o
              JOIN cat.ObligationType AS t ON t.ObligationTypeId = o.ObligationTypeId
              LEFT JOIN fac.Limit AS l ON l.LimitId = o.ScopeLimitId
              LEFT JOIN obl.ReportingObligation AS r ON r.ObligationId = o.ObligationId AND {Valid("r", rev)}
              LEFT JOIN obl.Covenant AS cv ON cv.ObligationId = o.ObligationId AND {Valid("cv", rev)}
              LEFT JOIN fin.MeasureFormula AS mf ON mf.MeasureFormulaId = cv.FormulaId
             WHERE o.FacilityId = @f AND {Valid("o", rev)}
             ORDER BY o.Family, o.ValidFrom, o.ObligationId;
            """, new { f = facility }, tx, cancellationToken: ct)).ConfigureAwait(false)];

    private static object Shape(ObligationRow o, int tenant, OpaqueRefs refs) => new
    {
        id = refs.ItemRef(tenant, "obligation", o.RootId), family = o.Family, type = o.TypeCode, titleAr = o.TitleAr, titleEn = o.TitleEn, phase = o.Phase,
        scopeLimit = o.ScopeLimitCode, clauseRef = o.ClauseRef, graceDays = o.GraceDays, cureDays = o.CureDays, paramValue = o.ParamValue, paramUnit = o.ParamUnit,
        checkMode = o.CheckMode, status = o.Status, validFrom = FacilityEndpoints.D(o.ValidFrom), validTo = FacilityEndpoints.D(o.ValidTo), fromRevision = o.FromRevision,
        reporting = o.ReportingObligationId is null ? null : new
        {
            frequency = o.Frequency, anchorKind = o.AnchorKind, offsetValue = o.OffsetValue, offsetUnit = o.OffsetUnit, fixedDueDate = FacilityEndpoints.D(o.FixedDueDate),
            direction = o.Direction, documentBasis = o.DocumentBasis, alertLeadDays = o.AlertLeadDays,
        },
        covenant = o.CovenantId is null ? null : new
        {
            measureKind = o.MeasureKind, formula = o.FormulaCode, @operator = o.Operator, thresholdState = o.ThresholdState, thresholdValue = o.ThresholdValue,
            thresholdUnit = o.ThresholdUnit, testFrequency = o.TestFrequency, aggregationMode = o.AggregationMode, annualWindowBasis = o.AnnualWindowBasis,
            revenueBasisRule = o.RevenueBasisRule, accountScope = o.AccountScopeKind, statementBasis = o.StatementBasis, requiredAssurance = o.RequiredAssurance,
            submissionLagDays = o.SubmissionLagDays, earlyWarningPct = o.EarlyWarningPct, firstTestPeriodEnd = FacilityEndpoints.D(o.FirstTestPeriodEnd),
        },
    };

    private static async Task<IResult> ListAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "view");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, View);
        await using var _ = u;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, http.RequestAborted);
        var draft = http.Request.Query["view"] == "draft";
        var rows = await RowsAsync(u.Connection, null, f.FacilityId, draft ? int.MaxValue : f.ApprovedRevisionNo, http.RequestAborted);
        return Results.Ok(new { view = draft ? "draft" : "approved", items = rows.Select(o => Shape(o, u.TenantId, refs)) });
    }

    private sealed record Values(int TypeId, string Family, string TitleAr, string? TitleEn, string Phase, long? Limit, string? ClauseRef, string? ClauseText, string? Consequence,
        int? Grace, int? Cure, decimal? Param, string? ParamUnit, int? ParamCurrency, string? CheckMode, DateTime From, DateTime? To, long[] Companies, long? Doc, string? Page,
        bool Scan, string? Original, string? Reason, string Confidence, object? Reporting, object? Covenant);

    private static DateTime? Date(string? text, string label) => LimitEndpoints.Date(text, label);

    /// <summary>V-OBL-01: an obligation of its type's family, with the rule or the covenant that family needs; the checks of the model before any write.</summary>
    private static async Task<Values> ValuesAsync(BoundUser u, SqlTransaction tx, LimitEndpoints.Draft d, ObligationRequest b, OpaqueRefs refs, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(b.ObligationType) || string.IsNullOrWhiteSpace(b.TitleAr))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the type and the Arabic title of the obligation.");
        var (typeId, family) = await u.Connection.QuerySingleOrDefaultAsync<(int, string)?>(new CommandDefinition(
            "SELECT ObligationTypeId, Family FROM cat.ObligationType WHERE Code = @c AND IsActive = 1;", new { c = b.ObligationType.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The obligation type is not an active type of the catalogue.");
        var phase = b.Phase?.ToUpperInvariant() ?? "ONGOING";
        if (phase is not ("PRECEDENT" or "ONGOING" or "SUBSEQUENT")) throw ApiProblemException.Invalid("V-OBL-01", "The phase is PRECEDENT, ONGOING or SUBSEQUENT.");
        long? limit = null;
        if (b.ScopeLimit is not null)
            limit = d.Rows.Limits.FirstOrDefault(l => l.RootId == refs.ItemId(u.TenantId, "limit", b.ScopeLimit))?.LimitId
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The limit is not a limit of the facility.");
        if (b.GraceDays is < 0 || b.CureDays is < 0) throw ApiProblemException.Invalid("V-OBL-01", "Grace and cure days are zero or more.");
        var unit = b.ParamUnit?.ToUpperInvariant();
        if ((b.ParamValue is null) != (unit is null) || b.ParamValue < 0 || (unit is not null and not ("DAYS" or "BUSINESS_DAYS" or "MONTHS" or "PCT" or "AMOUNT"))
            || (unit == "AMOUNT") != (b.ParamCurrency is not null))
            throw ApiProblemException.Invalid("V-OBL-01", "A parameter has its value and its unit (DAYS, BUSINESS_DAYS, MONTHS, PCT or AMOUNT with its currency).");
        var check = b.CheckMode?.ToUpperInvariant();
        if (check is not (null or "OFF" or "WARN" or "BLOCK")) throw ApiProblemException.Invalid("V-OBL-01", "The check mode is OFF, WARN or BLOCK.");
        var header = d.Rev.Header(d.F);
        var from = Date(b.ValidFrom, "start date") ?? header.Effective;
        var to = Date(b.ValidTo, "end date");
        if (to < from) throw ApiProblemException.Invalid("V-OBL-01", "An obligation ends on or after it starts.");
        var companies = new List<long>();
        foreach (var co in (b.Companies ?? []).Distinct())
            companies.Add(await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT CompanyId FROM org.Company WHERE PublicId = @c;", new { c = co }, tx,
                cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "A company of the obligation is not a company of the account."));
        var src = await LimitEndpoints.SourceAsync(u, tx, d.F, b.SourceDocument, b.SourcePage, b.ReadFromScan, b.OriginalText, b.NoSourceReason, ct);

        object? reporting = null, covenant = null;
        if (family == "REPORTING")
        {
            var r = b.Reporting ?? throw ApiProblemException.Invalid("V-OBL-01", "A reporting obligation has its rule: frequency, anchor and offset (FR-OBL-002).");
            var freq = r.Frequency?.ToUpperInvariant();
            var anchor = r.AnchorKind?.ToUpperInvariant();
            var offsetUnit = r.OffsetUnit?.ToUpperInvariant() ?? "CALENDAR_DAYS";
            var fixedDate = Date(r.FixedDueDate, "due date");
            var ok = freq is "ANNUAL" or "SEMIANNUAL" or "QUARTERLY" or "MONTHLY" or "ONE_TIME" or "EVENT_BASED" or "ON_DEMAND"
                && anchor is "AFTER_PERIOD_END" or "AFTER_FISCAL_YEAR_END" or "BEFORE_EVENT" or "AFTER_EVENT" or "ON_DEMAND_REQUEST" or "FIXED_DATE"
                && offsetUnit is "CALENDAR_DAYS" or "BUSINESS_DAYS" or "MONTHS"
                && (anchor == "FIXED_DATE" ? fixedDate is not null && r.OffsetValue is null : fixedDate is null && r.OffsetValue is >= 0)
                && (freq == "EVENT_BASED") == (anchor is "BEFORE_EVENT" or "AFTER_EVENT")
                && (freq == "ON_DEMAND") == (anchor == "ON_DEMAND_REQUEST");
            if (!ok) throw ApiProblemException.Invalid("V-OBL-01", "The rule's frequency, anchor and offset do not fit together (a fixed date has no offset; an event has an event anchor).");
            var direction = r.Direction?.ToUpperInvariant() ?? "WE_SUBMIT";
            var basis = r.DocumentBasis?.ToUpperInvariant() ?? "ANY";
            if (direction is not ("WE_SUBMIT" or "WE_RESPOND") || basis is not ("AUDITED" or "INTERNAL" or "ANY" or "NOT_APPLICABLE"))
                throw ApiProblemException.Invalid("V-OBL-01", "The direction is WE_SUBMIT or WE_RESPOND and the basis AUDITED, INTERNAL, ANY or NOT_APPLICABLE.");
            var lead = r.AlertLeadDays?.Replace(" ", "", StringComparison.Ordinal);
            if (lead is { Length: > 0 } && lead.Split(',').Any(x => x is not ("30" or "14" or "7" or "3" or "1")))
                throw ApiProblemException.Invalid("V-OBL-01", "The alert days are among 30, 14, 7, 3 and 1.");
            reporting = new
            {
                freq, anchor, offset = r.OffsetValue, offsetUnit, fixedDate, direction, basis, scope = r.StatementScope?.ToUpperInvariant(), note = r.ChannelNote, lead = lead ?? "30,14,7,3,1",
                first = Date(r.FirstPeriodEnd, "first period end"), horizon = r.HorizonMonths ?? 24, evidence = r.ExpectsEvidence ?? true,
            };
        }
        else if (b.Reporting is not null) throw ApiProblemException.Invalid("V-OBL-01", "Only a reporting obligation has a reporting rule.");
        if (family == "COVENANT")
        {
            var cv = b.Covenant ?? throw ApiProblemException.Invalid("V-OBL-01", "A covenant has its measure and threshold (FR-OBL-006).");
            var kind = cv.MeasureKind?.ToUpperInvariant() ?? "NONE";
            var state = cv.ThresholdState?.ToUpperInvariant() ?? (kind == "NONE" ? "NOT_SPECIFIED_IN_AGREEMENT" : "SET");
            if (kind is not ("RATIO" or "AMOUNT" or "PERCENT_OF_REVENUE" or "AVERAGE_BALANCE" or "FLOW_VOLUME" or "NONE")
                || state is not ("SET" or "NOT_SPECIFIED_IN_AGREEMENT" or "TO_BE_DETERMINED") || (kind == "NONE" && state == "SET"))
                throw ApiProblemException.Invalid("V-OBL-01", "The measure is one of its kinds; a descriptive covenant (NONE) has no threshold.");
            (long Id, string Unit, bool Statements)? formula = null;
            if (kind is "RATIO" or "AMOUNT" or "PERCENT_OF_REVENUE")
                formula = await u.Connection.QuerySingleOrDefaultAsync<(long, string, bool)?>(new CommandDefinition(
                    "SELECT TOP (1) MeasureFormulaId, ResultUnit, UsesStatements FROM fin.MeasureFormula WHERE Code = @c AND Status = 'APPROVED' AND (FacilityId IS NULL OR FacilityId = @f) ORDER BY CASE WHEN FacilityId IS NULL THEN 1 ELSE 0 END, VersionNo DESC;",
                    new { c = cv.Formula?.Trim().ToUpperInvariant(), f = d.F.FacilityId }, tx, cancellationToken: ct))
                    ?? throw ApiProblemException.Invalid("V-OBL-01", "A measurable covenant names an approved formula (CK_Covenant_1).");
            var tUnit = cv.ThresholdUnit?.ToUpperInvariant() ?? (state == "SET" ? formula?.Unit : null);
            var op = cv.Operator?.ToUpperInvariant();
            if (state == "SET" && (op is not ("GE" or "LE" or "GT" or "LT" or "EQ") || cv.ThresholdValue is null || tUnit is null))
                throw ApiProblemException.Invalid("V-OBL-01", "A set threshold has its operator, value and unit.");
            if (state != "SET" && cv.ThresholdValue is not null) throw ApiProblemException.Invalid("V-OBL-01", "A threshold not set in the agreement has no value.");
            var fitting = tUnit is null || (kind == "RATIO" && tUnit == "RATIO") || (kind is "AMOUNT" or "AVERAGE_BALANCE" or "FLOW_VOLUME" && tUnit == "AMOUNT")
                || (kind == "PERCENT_OF_REVENUE" && tUnit == "PERCENT");
            if (!fitting || (formula is { } fu && tUnit is not null && fu.Unit != tUnit)) throw ApiProblemException.Invalid("V-OBL-01", "The threshold's unit fits the measure and its formula (DR-38).");
            if ((tUnit == "AMOUNT" && state == "SET") != (cv.Currency is not null)) throw ApiProblemException.Invalid("V-OBL-01", "An amount threshold has its currency, and only it.");
            var freq = cv.TestFrequency?.ToUpperInvariant() ?? "ANNUAL";
            if (freq is not ("MONTHLY" or "QUARTERLY" or "SEMIANNUAL" or "ANNUAL" or "ROLLING_12M")) throw ApiProblemException.Invalid("V-OBL-01", "The test frequency is one of its kinds.");
            var tested = cv.TestedCompany is null ? d.F.BorrowerCompanyId : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT CompanyId FROM org.Company WHERE PublicId = @c;", new { c = cv.TestedCompany }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The tested company is not a company of the account.");
            var covFrom = Date(cv.ValidFrom, "covenant start") ?? from;
            var covTo = Date(cv.ValidTo, "covenant end");
            if (covTo < covFrom) throw ApiProblemException.Invalid("V-OBL-01", "A covenant ends on or after it starts.");
            var fye = await u.Connection.ExecuteScalarAsync<byte>(new CommandDefinition("SELECT FiscalYearEndMonth FROM org.Company WHERE CompanyId = @c;", new { c = tested }, tx,
                cancellationToken: ct));
            var firstTest = Date(cv.FirstTestPeriodEnd, "first test period") ?? CovenantPeriods.FirstPeriodEnd(covFrom, freq, fye);
            // The evaluation fields of the engine (S2-b brief S2B-GAP-9, OQ-9; BR-FIN-005 to 008).
            string? Pick(string? value, string[] allowed, string label)
            {
                var x = value?.Trim().ToUpperInvariant();
                return x is null || allowed.Contains(x) ? x : throw ApiProblemException.Invalid("V-OBL-01", $"The {label} is one of {string.Join(", ", allowed)}.");
            }
            var aggregation = Pick(cv.AggregationMode, ["POINT_IN_TIME", "PERIOD_AVERAGE", "EACH_MONTH_MIN", "PERIOD_SUM"], "aggregation");
            if (kind == "AVERAGE_BALANCE" && aggregation is null)
                throw ApiProblemException.Invalid("V-OBL-01", "An average balance covenant says how the months are taken: each month, the period average, the last month or the sum (BR-FIN-005).");
            if (aggregation is not null && kind is not ("AVERAGE_BALANCE" or "FLOW_VOLUME")) throw ApiProblemException.Invalid("V-OBL-01", "Only a balance or flow covenant aggregates months.");
            var window = Pick(cv.AnnualWindowBasis, ["FISCAL_YEAR", "CALENDAR_YEAR", "FACILITY_YEAR"], "annual window")
                ?? (kind is "FLOW_VOLUME" or "PERCENT_OF_REVENUE" ? "FISCAL_YEAR" : null);
            var revenueRule = Pick(cv.RevenueBasisRule, ["SAME_PERIOD", "PRIOR_YEAR", "MANUAL_ESTIMATE"], "revenue basis") ?? (kind == "PERCENT_OF_REVENUE" ? "SAME_PERIOD" : null);
            if (revenueRule is not null && kind != "PERCENT_OF_REVENUE") throw ApiProblemException.Invalid("V-OBL-01", "A revenue basis belongs to a share of revenue covenant (BR-FIN-008).");
            var accountScope = Pick(cv.AccountScope, ["ALL_COMPANY_ACCOUNTS_AT_BANK", "SELECTED_ACCOUNTS", "GROUP_ACCOUNTS"], "account scope")
                ?? (kind == "AVERAGE_BALANCE" ? "ALL_COMPANY_ACCOUNTS_AT_BANK" : null);
            if (accountScope is not null && kind != "AVERAGE_BALANCE") throw ApiProblemException.Invalid("V-OBL-01", "An account scope belongs to an average balance covenant (BR-FIN-006).");
            var accounts = new List<long>();
            if ((cv.Accounts?.Length ?? 0) > 0 != (accountScope == "SELECTED_ACCOUNTS"))
                throw ApiProblemException.Invalid("V-OBL-01", "Selected accounts are given with the scope SELECTED_ACCOUNTS, and only with it (BR-FIN-006).");
            foreach (var acc in (cv.Accounts ?? []).Distinct())
                accounts.Add(await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                    "SELECT BankAccountId FROM acc.BankAccount WHERE PublicId = @a AND CompanyId = @c;", new { a = acc, c = tested }, tx, cancellationToken: ct))
                    ?? throw ApiProblemException.Invalid("V-OBL-01", "A selected account is an account of the tested company."));
            if (cv.SubmissionLagDays is < 0 or > 365) throw ApiProblemException.Invalid("V-OBL-01", "The submission lag is from 0 to 365 days.");
            if (cv.EarlyWarningPct is < 0 or > 100) throw ApiProblemException.Invalid("V-OBL-01", "The early warning is from 0 to 100 percent of the threshold.");
            covenant = new
            {
                kind, formula = formula?.Id, fUnit = formula?.Unit, fStatements = formula?.Statements, op = state == "SET" ? op : null, state, value = cv.ThresholdValue, tUnit = state == "SET" ? tUnit : null,
                currency = cv.Currency is null || state != "SET" ? (int?)null : await FacilityEndpoints.CurrencyAsync(u, tx, cv.Currency, ct), freq, tested, firstTest,
                basis = formula is { Statements: true } ? cv.StatementBasis?.ToUpperInvariant() ?? "STANDALONE" : cv.StatementBasis?.ToUpperInvariant(),
                assurance = formula is { Statements: true } ? cv.RequiredAssurance?.ToUpperInvariant() ?? "PREFER_AUDITED" : cv.RequiredAssurance?.ToUpperInvariant(),
                from = covFrom, to = covTo, aggregation, window, revenueRule, accountScope, accounts, lag = cv.SubmissionLagDays, warning = cv.EarlyWarningPct,
            };
        }
        else if (b.Covenant is not null) throw ApiProblemException.Invalid("V-OBL-01", "Only a covenant has a measure and a threshold.");
        return new Values(typeId, family, b.TitleAr.Trim(), b.TitleEn?.Trim(), phase, limit, b.ClauseRef?.Trim(), b.ClauseText?.Trim(), b.ConsequenceText?.Trim(), b.GraceDays,
            b.CureDays, b.ParamValue, unit, b.ParamCurrency is null ? null : await FacilityEndpoints.CurrencyAsync(u, tx, b.ParamCurrency, ct), check, from, to, [.. companies],
            src.Doc, src.Page, src.Scan, src.Original, src.Reason, src.Confidence, reporting, covenant);
    }

    private static async Task WritePartsAsync(BoundUser u, SqlTransaction tx, long obligation, int rev, Values v, CancellationToken ct)
    {
        var c = u.Connection;
        await c.ExecuteAsync(new CommandDefinition("DELETE FROM obl.ObligationCompany WHERE ObligationId = @o;", new { o = obligation }, tx, cancellationToken: ct));
        foreach (var co in v.Companies)
            await c.ExecuteAsync(new CommandDefinition(
                "INSERT obl.ObligationCompany (TenantId, ObligationId, CompanyId, CreatedBy) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @o, @c, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));",
                new { o = obligation, c = co }, tx, cancellationToken: ct));
        if (v.Reporting is not null)
        {
            dynamic r = v.Reporting;
            await c.ExecuteAsync(new CommandDefinition(
                """
                DECLARE @me BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
                UPDATE obl.ReportingObligation SET Frequency = @freq, AnchorKind = @anchor, OffsetValue = @offset, OffsetUnit = @unit, FixedDueDate = @fixedDate, Direction = @direction,
                       DocumentBasis = @basis, StatementScope = @scope, ChannelNote = @note, AlertLeadDays = @lead, FirstPeriodEnd = @first, HorizonMonths = @horizon,
                       ExpectsEvidence = @evidence, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me
                 WHERE ObligationId = @o AND ToRevision IS NULL;
                IF @@ROWCOUNT = 0
                    INSERT obl.ReportingObligation (TenantId, ObligationId, Frequency, AnchorKind, OffsetValue, OffsetUnit, FixedDueDate, Direction, DocumentBasis, StatementScope,
                                                    ChannelNote, AlertLeadDays, FirstPeriodEnd, HorizonMonths, ExpectsEvidence, FromRevision, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @o, @freq, @anchor, @offset, @unit, @fixedDate, @direction, @basis, @scope, @note, @lead, @first, @horizon,
                            @evidence, @rev, @me);
                """, new
                {
                    o = obligation, rev, freq = (string)r.freq, anchor = (string)r.anchor, offset = (int?)r.offset, unit = (string)r.offsetUnit, fixedDate = (DateTime?)r.fixedDate,
                    direction = (string)r.direction, basis = (string)r.basis, scope = (string?)r.scope, note = (string?)r.note, lead = (string)r.lead, first = (DateTime?)r.first,
                    horizon = (int)r.horizon, evidence = (bool)r.evidence,
                }, tx, cancellationToken: ct));
        }
        if (v.Covenant is not null)
        {
            dynamic k = v.Covenant;
            await c.ExecuteAsync(new CommandDefinition(
                """
                DECLARE @me BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
                UPDATE obl.Covenant SET MeasureKind = @kind, FormulaId = @formula, FormulaResultUnit = @fUnit, FormulaUsesStatements = @fStatements, Operator = @op,
                       ThresholdState = @state, ThresholdValue = @value, ThresholdUnit = @tUnit, CurrencyId = @currency, TestFrequency = @freq, TestedCompanyId = @tested,
                       FirstTestPeriodEnd = @firstTest, StatementBasis = @basis, RequiredAssurance = @assurance, ValidFrom = @from, ValidTo = @to, AggregationMode = @aggregation,
                       AnnualWindowBasis = @window, RevenueBasisRule = @revenueRule, AccountScopeKind = @accountScope, SubmissionLagDays = @lag, EarlyWarningPct = @warning,
                       UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me
                 WHERE ObligationId = @o AND ToRevision IS NULL;
                IF @@ROWCOUNT = 0
                    INSERT obl.Covenant (TenantId, ObligationId, MeasureKind, FormulaId, FormulaResultUnit, FormulaUsesStatements, Operator, ThresholdState, ThresholdValue, ThresholdUnit,
                                         CurrencyId, TestFrequency, TestedCompanyId, FirstTestPeriodEnd, StatementBasis, RequiredAssurance, ValidFrom, ValidTo, AggregationMode,
                                         AnnualWindowBasis, RevenueBasisRule, AccountScopeKind, SubmissionLagDays, EarlyWarningPct, FromRevision, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @o, @kind, @formula, @fUnit, @fStatements, @op, @state, @value, @tUnit, @currency, @freq, @tested, @firstTest,
                            @basis, @assurance, @from, @to, @aggregation, @window, @revenueRule, @accountScope, @lag, @warning, @rev, @me);
                DECLARE @k BIGINT = (SELECT CovenantId FROM obl.Covenant WHERE ObligationId = @o AND ToRevision IS NULL);
                DELETE obl.CovenantAccount WHERE CovenantId = @k;
                INSERT obl.CovenantAccount (TenantId, CovenantId, BankAccountId, CreatedBy)
                SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), @k, value, @me FROM OPENJSON(@accounts) WITH (value BIGINT '$');
                """, new
                {
                    o = obligation, rev, kind = (string)k.kind, formula = (long?)k.formula, fUnit = (string?)k.fUnit, fStatements = (bool?)k.fStatements, op = (string?)k.op,
                    state = (string)k.state, value = (decimal?)k.value, tUnit = (string?)k.tUnit, currency = (int?)k.currency, freq = (string)k.freq, tested = (long)k.tested,
                    firstTest = (DateTime)k.firstTest, basis = (string?)k.basis, assurance = (string?)k.assurance, from = (DateTime)k.from, to = (DateTime?)k.to,
                    aggregation = (string?)k.aggregation, window = (string?)k.window, revenueRule = (string?)k.revenueRule, accountScope = (string?)k.accountScope,
                    lag = (int?)k.lag, warning = (decimal?)k.warning, accounts = System.Text.Json.JsonSerializer.Serialize((List<long>)k.accounts),
                }, tx, cancellationToken: ct));
        }
    }

    private static async Task<IResult> AddAsync(Guid id, ObligationRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, Manage);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await LimitEndpoints.DraftAsync(u, tx, id, scope, ct);
        var v = await ValuesAsync(u, tx, d, b, refs, ct);
        var rows = await RowsAsync(u.Connection, tx, d.F.FacilityId, int.MaxValue, ct);
        var warnings = rows.Any(o => string.Equals(o.TypeCode, b.ObligationType!.Trim(), StringComparison.OrdinalIgnoreCase) && o.ValidFrom == v.From && o.ScopeLimitRoot == d.Rows.Limits.FirstOrDefault(l => l.LimitId == v.Limit)?.RootId)
            ? new[] { "V-OBL-DUPLICATE" } : [];
        var (oid, root) = await u.Connection.QuerySingleAsync<(long, long)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, RootId BIGINT);
            INSERT obl.Obligation (TenantId, FacilityId, Family, ObligationTypeId, TitleAr, TitleEn, Phase, ScopeLimitId, ClauseRef, ClauseText, ConsequenceText, GraceDays, CureDays,
                                   ParamValue, ParamUnit, ParamCurrencyId, CheckMode, Status, ValidFrom, ValidTo, FromRevision, SourceDocumentId, SourcePage, ReadFromScan, OriginalText,
                                   NoSourceReason, Confidence, CreatedBy)
            OUTPUT inserted.ObligationId, inserted.RootId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @family, @type, @ar, @en, @phase, @limit, @clauseRef, @clause, @consequence, @grace, @cure, @param, @unit, @cur, @check,
                    'ACTIVE', @from, @to, @rev, @doc, @page, @scan, @orig, @reason, @conf, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, RootId FROM @o;
            """, new
            {
                f = d.F.FacilityId, family = v.Family, type = v.TypeId, ar = v.TitleAr, en = v.TitleEn, phase = v.Phase, limit = v.Limit, clauseRef = v.ClauseRef, clause = v.ClauseText,
                consequence = v.Consequence, grace = v.Grace, cure = v.Cure, param = v.Param, unit = v.ParamUnit, cur = v.ParamCurrency, check = v.CheckMode, from = v.From, to = v.To,
                rev = d.Rev.RevisionNo, doc = v.Doc, page = v.Page, scan = v.Scan, orig = v.Original, reason = v.Reason, conf = v.Confidence,
            }, tx, cancellationToken: ct));
        await WritePartsAsync(u, tx, oid, d.Rev.RevisionNo, v, ct);
        await LimitEndpoints.DoneAsync(u, tx, d, "OBLIGATION_ADDED", new { type = b.ObligationType, title = v.TitleAr }, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/obligations", new { id = refs.ItemRef(u.TenantId, "obligation", root), warnings });
    }

    /// <summary>A change in the draft: the draft's row is rewritten (the approved one is closed at the draft and stays as it was).</summary>
    private static async Task<IResult> ChangeAsync(Guid id, string reference, ObligationRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, Manage);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await LimitEndpoints.DraftAsync(u, tx, id, scope, ct);
        var o = (await RowsAsync(u.Connection, tx, d.F.FacilityId, int.MaxValue, ct)).FirstOrDefault(x => x.RootId == refs.ItemId(u.TenantId, "obligation", reference))
            ?? throw ApiProblemException.NotFound();
        if (!string.Equals(b.ObligationType, o.TypeCode, StringComparison.OrdinalIgnoreCase)) throw ApiProblemException.Invalid("V-OBL-01", "The type of an obligation does not change.");
        var v = await ValuesAsync(u, tx, d, b, refs, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE obl.Obligation SET TitleAr = @ar, TitleEn = @en, Phase = @phase, ScopeLimitId = @limit, ClauseRef = @clauseRef, ClauseText = @clause, ConsequenceText = @consequence,
                   GraceDays = @grace, CureDays = @cure, ParamValue = @param, ParamUnit = @unit, ParamCurrencyId = @cur, CheckMode = @check, ValidFrom = @from, ValidTo = @to,
                   SourceDocumentId = @doc, SourcePage = @page, ReadFromScan = @scan, OriginalText = @orig, NoSourceReason = @reason, Confidence = @conf, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE ObligationId = @id;
            """, new
            {
                id = o.ObligationId, ar = v.TitleAr, en = v.TitleEn, phase = v.Phase, limit = v.Limit, clauseRef = v.ClauseRef, clause = v.ClauseText, consequence = v.Consequence,
                grace = v.Grace, cure = v.Cure, param = v.Param, unit = v.ParamUnit, cur = v.ParamCurrency, check = v.CheckMode, from = v.From, to = v.To, doc = v.Doc, page = v.Page,
                scan = v.Scan, orig = v.Original, reason = v.Reason, conf = v.Confidence,
            }, tx, cancellationToken: ct));
        await WritePartsAsync(u, tx, o.ObligationId, d.Rev.RevisionNo, v, ct);
        await LimitEndpoints.DoneAsync(u, tx, d, "OBLIGATION_CHANGED", new { type = o.TypeCode, title = v.TitleAr }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> RemoveAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, Manage);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await LimitEndpoints.DraftAsync(u, tx, id, scope, ct);
        var o = (await RowsAsync(u.Connection, tx, d.F.FacilityId, int.MaxValue, ct)).FirstOrDefault(x => x.RootId == refs.ItemId(u.TenantId, "obligation", reference))
            ?? throw ApiProblemException.NotFound();
        if (o.ReportingObligationId is { } r) await LimitEndpoints.DeleteDraftRowAsync(u, tx, "obl.ReportingObligation", "ReportingObligationId", r, ct);
        if (o.CovenantId is { } k)
        {
            await u.Connection.ExecuteAsync(new CommandDefinition("DELETE obl.CovenantAccount WHERE CovenantId = @k;", new { k }, tx, cancellationToken: ct));
            await LimitEndpoints.DeleteDraftRowAsync(u, tx, "obl.Covenant", "CovenantId", k, ct);
        }
        await LimitEndpoints.DeleteDraftRowAsync(u, tx, "obl.Obligation", "ObligationId", o.ObligationId, ct);
        await LimitEndpoints.DoneAsync(u, tx, d, "OBLIGATION_REMOVED", new { type = o.TypeCode, title = o.TitleAr }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- the agenda ----------

    private sealed class ItemRow
    {
        public long ReportingInstanceId { get; init; }
        public Guid PublicId { get; init; }
        public long ReportingObligationRootId { get; init; }
        public long ObligationId { get; init; }
        public long ObligationRootId { get; init; }
        public long FacilityId { get; init; }
        public Guid FacilityPublicId { get; init; }
        public string FacilityNo { get; init; } = "";
        public long BorrowerCompanyId { get; init; }
        public string TitleAr { get; init; } = "";
        public string? TitleEn { get; init; }
        public string Frequency { get; init; } = "";
        public DateTime? PeriodStart { get; init; }
        public DateTime? PeriodEnd { get; init; }
        public DateTime? EventDate { get; init; }
        public DateTime DueDate { get; init; }
        public string? DueDateOverrideReason { get; init; }
        public string Status { get; init; } = "";
        public string? StatusReason { get; init; }
        public DateTime? SubmittedOn { get; init; }
        public int? GraceDays { get; init; }
        public int? CureDays { get; init; }
        public bool ExpectsEvidence { get; init; }
        public bool HasEvidence { get; init; }
    }

    private const string ItemSelect = """
        SELECT i.ReportingInstanceId, i.PublicId, i.ReportingObligationRootId, o.ObligationId, o.RootId AS ObligationRootId, f.FacilityId, f.PublicId AS FacilityPublicId, ISNULL(f.PlatformRef, f.FacilityNo) AS FacilityNo,
               f.BorrowerCompanyId, o.TitleAr, o.TitleEn, r.Frequency, i.PeriodStart, i.PeriodEnd, i.EventDate, i.DueDate, i.DueDateOverrideReason, i.Status, i.StatusReason,
               i.SubmittedOn, o.GraceDays, o.CureDays, r.ExpectsEvidence, CAST(CASE WHEN i.EvidenceDocumentId IS NULL THEN 0 ELSE 1 END AS BIT) AS HasEvidence
          FROM obl.ReportingInstance AS i
          JOIN obl.ReportingObligation AS r ON r.ReportingObligationId = i.ReportingObligationId
          JOIN obl.Obligation AS o ON o.ObligationId = r.ObligationId
          JOIN fac.Facility AS f ON f.FacilityId = o.FacilityId
        """;

    /// <summary>DUE_SOON and OVERDUE are derived from a SCHEDULED item's date (spec 12 section 8): overdue after the due date, due soon within 30 days.</summary>
    private static string Derived(ItemRow i, DateTime today) =>
        i.Status != "SCHEDULED" ? i.Status : i.DueDate < today ? "OVERDUE" : i.DueDate <= today.AddDays(30) ? "DUE_SOON" : "SCHEDULED";

    private static object ItemShape(ItemRow i, DateTime today) => new
    {
        id = i.PublicId, facility = i.FacilityPublicId, facilityNo = i.FacilityNo, titleAr = i.TitleAr, titleEn = i.TitleEn, frequency = i.Frequency,
        periodStart = FacilityEndpoints.D(i.PeriodStart), periodEnd = FacilityEndpoints.D(i.PeriodEnd), eventDate = FacilityEndpoints.D(i.EventDate),
        dueDate = FacilityEndpoints.D(i.DueDate), dueDateOverrideReason = i.DueDateOverrideReason, status = Derived(i, today), statusReason = i.StatusReason,
        submittedOn = FacilityEndpoints.D(i.SubmittedOn), daysLate = i.SubmittedOn is { } s && s > i.DueDate ? (s - i.DueDate).Days : (int?)null,
        expectsEvidence = i.ExpectsEvidence, hasEvidence = i.HasEvidence,
    };

    private static async Task<IResult> AgendaAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "from", "to", "status");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, View);
        await using var _ = u;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, http.RequestAborted);
        var q = http.Request.Query;
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var rows = await u.Connection.QueryAsync<ItemRow>(new CommandDefinition(
            ItemSelect + " WHERE f.FacilityId = @f AND i.Status <> 'CANCELLED' AND (@from IS NULL OR i.DueDate >= @from) AND (@to IS NULL OR i.DueDate <= @to) ORDER BY i.DueDate, i.ReportingInstanceId;",
            new { f = f.FacilityId, from = Date(q["from"], "from"), to = Date(q["to"], "to") }, cancellationToken: http.RequestAborted));
        var status = q["status"].ToString();
        return Results.Ok(new { items = rows.Where(i => status.Length == 0 || Derived(i, today) == status).Select(i => ItemShape(i, today)) });
    }

    private static async Task<ItemRow> ItemAsync(BoundUser u, SqlTransaction tx, Guid id, CancellationToken ct)
    {
        var i = await u.Connection.QuerySingleOrDefaultAsync<ItemRow>(new CommandDefinition(
            ItemSelect.Replace("FROM obl.ReportingInstance AS i", "FROM obl.ReportingInstance AS i WITH (UPDLOCK, HOLDLOCK)", StringComparison.Ordinal) + " WHERE i.PublicId = @id;",
            new { id }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (!(await CompanyScope.OfAsync(u, ct, tx)).Allows(i.BorrowerCompanyId)) throw ApiProblemException.NotFound();
        return i;
    }

    private static async Task<long?> DocAsync(BoundUser u, SqlTransaction tx, Guid? document, CancellationToken ct) =>
        document is null ? null
        : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE';", new { d = document }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is not an active document.");

    /// <summary>
    /// FR-OBL-004: a submission with its date (and its evidence when the rule expects it). A date after the due date and
    /// the grace days opens a LATE_REPORT breach (in cure when the obligation has cure days) and raises CMP.BREACH.
    /// </summary>
    private static async Task<IResult> SubmitAsync(Guid id, SubmitRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var on = Date(b.SubmittedOn, "submission date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date of the submission.");
        await using var u = await BoundUser.OpenAsync(http, db, Record);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var i = await ItemAsync(u, tx, id, ct);
        if (i.Status != "SCHEDULED") throw new ApiProblemException(409, "V-OBL-STATE", "Only a scheduled item is submitted.");
        if (on > clock.GetUtcNow().UtcDateTime.Date) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A submission is not dated in the future.");
        var evidence = await DocAsync(u, tx, b.EvidenceDocument, ct);
        if (i.ExpectsEvidence && evidence is null) throw ApiProblemException.Invalid("V-OBL-EVIDENCE", "This obligation expects its evidence: attach the document submitted.");
        if ((b.ReportedAmount is null) != (b.Currency is null)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A reported amount has its currency.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE obl.ReportingInstance SET Status = 'SUBMITTED', SubmittedOn = @on, SubmissionRef = @ref, EvidenceDocumentId = @doc, ReportedAmount = @amount, CurrencyId = @cur,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE ReportingInstanceId = @id;
            """, new
            {
                id = i.ReportingInstanceId, on, @ref = b.SubmissionRef?.Trim(), doc = evidence, amount = b.ReportedAmount,
                cur = b.Currency is null ? (int?)null : await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency, ct),
            }, tx, cancellationToken: ct));
        var late = (on - i.DueDate).Days;
        Guid? breach = null;
        if (late > (i.GraceDays ?? 0))
            breach = await OpenAsync(u, tx, i.FacilityId, i.ObligationRootId, i.ObligationId, "LATE_REPORT", i.ReportingInstanceId, on, i.CureDays,
                $"Submitted {late} days after the due date {FacilityEndpoints.D(i.DueDate)}.", ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("OBLIGATION_SUBMITTED", "TREASURY", "obl.ReportingInstance", i.ReportingInstanceId,
            AfterJson: JsonSerializer.Serialize(new { submittedOn = FacilityEndpoints.D(on), late, breach })), i.BorrowerCompanyId, ct);
        await Outbox.EmitAsync(u.Connection, tx, "obligation.instance.submitted", "obl.ReportingInstance", i.ReportingInstanceId, new { item = i.PublicId }, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "SUBMITTED", daysLate = Math.Max(late, 0), breach });
    }

    private static async Task<IResult> WaiveAsync(Guid id, ReasonRequest b, HttpContext http, SqlConnectionFactory db)
    {
        if (string.IsNullOrWhiteSpace(b.Reason) || b.Document is null) throw ApiProblemException.Invalid("V-OBL-WAIVER", "A waiver has its reason and its document (DQ-F15-12).");
        await using var u = await BoundUser.OpenAsync(http, db, WaiverApprove);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var i = await ItemAsync(u, tx, id, ct);
        if (i.Status != "SCHEDULED") throw new ApiProblemException(409, "V-OBL-STATE", "Only a scheduled item is waived.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE obl.ReportingInstance SET Status = 'WAIVED', StatusReason = @r, EvidenceDocumentId = @doc, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ReportingInstanceId = @id;",
            new { id = i.ReportingInstanceId, r = b.Reason.Trim(), doc = await DocAsync(u, tx, b.Document, ct) }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("OBLIGATION_WAIVED", "TREASURY", "obl.ReportingInstance", i.ReportingInstanceId,
            AfterJson: JsonSerializer.Serialize(new { reason = b.Reason.Trim() })), i.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> NotApplicableAsync(Guid id, ReasonRequest b, HttpContext http, SqlConnectionFactory db)
    {
        if (string.IsNullOrWhiteSpace(b.Reason)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason the item does not apply.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var i = await ItemAsync(u, tx, id, ct);
        if (i.Status != "SCHEDULED") throw new ApiProblemException(409, "V-OBL-STATE", "Only a scheduled item is marked not applicable.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE obl.ReportingInstance SET Status = 'NOT_APPLICABLE', StatusReason = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ReportingInstanceId = @id;",
            new { id = i.ReportingInstanceId, r = b.Reason.Trim() }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("OBLIGATION_NOT_APPLICABLE", "TREASURY", "obl.ReportingInstance", i.ReportingInstanceId,
            AfterJson: JsonSerializer.Serialize(new { reason = b.Reason.Trim() })), i.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>A due date moved by the user, with its reason; regeneration leaves it where the user put it.</summary>
    private static async Task<IResult> RescheduleAsync(Guid id, RescheduleRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var due = Date(b.DueDate, "due date");
        if (due is null || string.IsNullOrWhiteSpace(b.Reason)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the new due date and the reason.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var i = await ItemAsync(u, tx, id, ct);
        if (i.Status != "SCHEDULED") throw new ApiProblemException(409, "V-OBL-STATE", "Only a scheduled item is rescheduled.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE obl.ReportingInstance SET DueDate = @due, DueDateOverrideReason = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ReportingInstanceId = @id;",
            new { id = i.ReportingInstanceId, due, r = b.Reason.Trim() }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("OBLIGATION_RESCHEDULED", "TREASURY", "obl.ReportingInstance", i.ReportingInstanceId,
            BeforeJson: JsonSerializer.Serialize(new { dueDate = FacilityEndpoints.D(i.DueDate) }), AfterJson: JsonSerializer.Serialize(new { dueDate = FacilityEndpoints.D(due), reason = b.Reason.Trim() })),
            i.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>FR-OBL-005: an event of an event-based rule (a planned change of ownership) gives an item due N working days before it (BR-OBL-004).</summary>
    private static async Task<IResult> EventAsync(Guid id, string reference, EventRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var on = Date(b.EventDate, "event date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date of the event.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, Record);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FacilityEndpoints.FindAsync(u, tx, id, scope, ct);
        var root = refs.ItemId(u.TenantId, "obligation", reference);
        var rule = (await ObligationStore.RulesAsync(u.Connection, tx, f.FacilityId, f.ApprovedRevisionNo, ct)).FirstOrDefault(r => r.ObligationRootId == root)
            ?? throw ApiProblemException.NotFound();
        if (rule.Frequency != "EVENT_BASED") throw new ApiProblemException(409, "V-OBL-STATE", "Only an event-based rule takes an event.");
        var (days, _, expiry) = await ObligationStore.ContextAsync(u.Connection, tx, f.FacilityId, clock.GetUtcNow().UtcDateTime.Date, ct);
        var item = Agenda.ForEvent(rule.Rule(expiry), on, ObligationStore.Adder(days));
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM obl.ReportingInstance WHERE ReportingObligationRootId = @r AND EventDate = @e AND PeriodEnd IS NULL AND Status <> 'CANCELLED';",
                new { r = rule.RootId, e = on }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-OBL-EVENT-EXISTS", "This event is already logged.");
        var publicId = await u.Connection.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            DECLARE @o TABLE (PublicId UNIQUEIDENTIFIER);
            INSERT obl.ReportingInstance (TenantId, ReportingObligationRootId, ReportingObligationId, EventDate, DueDate, Status, StatusReason, GeneratedBy, CreatedBy)
            OUTPUT inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @root, @id, @e, @due, 'SCHEDULED', NULL, 'MANUAL_EVENT', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT PublicId FROM @o;
            """, new { root = rule.RootId, id = rule.ReportingObligationId, e = on, due = item.DueDate }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("OBLIGATION_EVENT_LOGGED", "TREASURY", "obl.Obligation", rule.ObligationId,
            AfterJson: JsonSerializer.Serialize(new { eventDate = FacilityEndpoints.D(on), dueDate = FacilityEndpoints.D(item.DueDate), note = b.Note })), f.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/agenda", new { id = publicId, dueDate = FacilityEndpoints.D(item.DueDate) });
    }

    // ---------- the manual status of a descriptive covenant (FR-OBL-007, OQ-4) ----------

    private sealed class ReviewRow
    {
        public Guid PublicId { get; init; }
        public long CovenantRootId { get; init; }
        public DateTime PeriodEnd { get; init; }
        public int EvaluationNo { get; init; }
        public string Result { get; init; } = "";
        public string? ReviewNote { get; init; }
        public DateTime ReviewedOn { get; init; }
        public Guid? ReviewerId { get; init; }
        public DateTime? NextReviewOn { get; init; }
        public Guid? EvidenceId { get; init; }
    }

    private const string ReviewSelect = """
        SELECT t.PublicId, t.CovenantRootId, t.PeriodEnd, t.EvaluationNo, t.Result, t.ReviewNote, t.ReviewedOn, ru.PublicId AS ReviewerId, t.NextReviewOn, d.PublicId AS EvidenceId
          FROM obl.CovenantTest AS t
          LEFT JOIN sec.AppUser AS ru ON ru.AppUserId = t.ReviewedBy
          LEFT JOIN doc.Document AS d ON d.DocumentId = t.EvidenceDocumentId
        """;

    /// <summary>The approved descriptive covenant (MeasureKind NONE) of an obligation of the facility, or 404.</summary>
    private static async Task<(long ObligationId, long CovenantId, long CovenantRootId)> DescriptiveAsync(BoundUser u, SqlTransaction? tx, FacilityEndpoints.FacilityRow f,
        long? root, CancellationToken ct)
    {
        var row = await u.Connection.QuerySingleOrDefaultAsync<(long, long, long, string)?>(new CommandDefinition(
            """
            SELECT o.ObligationId, cv.CovenantId, cv.RootId, cv.MeasureKind FROM obl.Obligation AS o
              JOIN obl.Covenant AS cv ON cv.ObligationId = o.ObligationId AND cv.FromRevision <= @a AND (cv.ToRevision IS NULL OR cv.ToRevision > @a)
             WHERE o.FacilityId = @f AND o.RootId = @root AND o.FromRevision <= @a AND (o.ToRevision IS NULL OR o.ToRevision > @a);
            """, new { f = f.FacilityId, root, a = f.ApprovedRevisionNo }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (row.Item4 != "NONE") throw new ApiProblemException(409, "V-OBL-NOT-DESCRIPTIVE", "Only a descriptive covenant takes a manual status; a measured one is tested (S2-b).");
        return (row.Item1, row.Item2, row.Item3);
    }

    private static object ReviewShape(ReviewRow r, DateTime today) => new
    {
        id = r.PublicId, reviewDate = FacilityEndpoints.D(r.PeriodEnd), status = r.Result.StartsWith("MANUAL_", StringComparison.Ordinal) ? r.Result["MANUAL_".Length..] : r.Result,
        note = r.ReviewNote, reviewer = r.ReviewerId, reviewedOn = r.ReviewedOn, nextReviewOn = r.NextReviewOn is { } n ? FacilityEndpoints.D(n) : null,
        reviewOverdue = r.NextReviewOn is { } m && m < today, evidence = r.EvidenceId,
    };

    private static async Task<IResult> ReviewsAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, ct);
        var cv = await DescriptiveAsync(u, null, f, refs.ItemId(u.TenantId, "obligation", reference), ct);
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var rows = (await u.Connection.QueryAsync<ReviewRow>(new CommandDefinition(ReviewSelect + " WHERE t.CovenantRootId = @r AND t.Method = 'MANUAL_STATUS' ORDER BY t.PeriodEnd DESC, t.EvaluationNo DESC;",
            new { r = cv.CovenantRootId }, cancellationToken: ct))).ToList();
        return Results.Ok(new { current = rows.Count == 0 ? null : ReviewShape(rows[0], today), items = rows.Select(r => ReviewShape(r, today)) });
    }

    /// <summary>
    /// A review of a descriptive covenant is a REVIEWED CovenantTest row with Method MANUAL_STATUS, written by obl.record
    /// (OQ-4): one row per review date, a second review on the same date the next EvaluationNo. Rows are never changed
    /// (044 freezes them); the latest is the covenant's status, and its NextReviewOn passed makes the review overdue.
    /// </summary>
    private static async Task<IResult> ReviewAsync(Guid id, string reference, CovenantReviewRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var status = b.Status?.Trim().ToUpperInvariant();
        if (status is not ("COMPLIANT" or "NON_COMPLIANT" or "UNDER_REVIEW"))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The status is COMPLIANT, NON_COMPLIANT or UNDER_REVIEW.");
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var on = Date(b.ReviewDate, "review date") ?? today;
        var next = Date(b.NextReviewOn, "next review date");
        if (on > today) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A review is recorded on or before today.");
        if (next is { } nx && nx <= on) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The next review comes after this one.");
        if (b.Note is { Length: > 1000 }) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The note has at most 1000 characters.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, Record);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FacilityEndpoints.FindAsync(u, tx, id, scope, ct);
        var cv = await DescriptiveAsync(u, tx, f, refs.ItemId(u.TenantId, "obligation", reference), ct);
        long? evidence = null;
        if (b.Evidence is { } e)
            evidence = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT DocumentId FROM doc.Document WHERE PublicId = @e AND Status <> 'SOFT_DELETED';", new { e }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The evidence is a document on file.");
        var publicId = await u.Connection.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            DECLARE @o TABLE (PublicId UNIQUEIDENTIFIER);
            DECLARE @n INT = ISNULL((SELECT MAX(EvaluationNo) FROM obl.CovenantTest WITH (UPDLOCK, HOLDLOCK) WHERE CovenantRootId = @root AND PeriodEnd = @on), 0) + 1;
            INSERT obl.CovenantTest (TenantId, CovenantRootId, CovenantId, PeriodStart, PeriodEnd, DueDate, EvaluationNo, State, Result, Method, InputsSnapshot,
                                     EvaluatedAt, EvaluatedBy, EvidenceDocumentId, ReviewNote, ReviewedBy, ReviewedOn, NextReviewOn, CreatedBy)
            OUTPUT inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @root, @cov, @on, @on, @on, @n, 'REVIEWED', @result, 'MANUAL_STATUS', @snap,
                    SYSUTCDATETIME(), CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), @evidence, @note, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), SYSUTCDATETIME(), @next,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT PublicId FROM @o;
            """, new
            {
                root = cv.CovenantRootId, cov = cv.CovenantId, on, result = status == "UNDER_REVIEW" ? status : "MANUAL_" + status, evidence, note = b.Note?.Trim(), next,
                snap = JsonSerializer.Serialize(new { manual = new { status, reviewDate = FacilityEndpoints.D(on), evidence = b.Evidence } }),
            }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COVENANT_REVIEWED", "TREASURY", "obl.Obligation", cv.ObligationId,
            AfterJson: JsonSerializer.Serialize(new { status, reviewDate = FacilityEndpoints.D(on), nextReviewOn = next is { } x ? FacilityEndpoints.D(x) : null })), f.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/obligations/{reference}/reviews", new { id = publicId });
    }

    // ---------- breaches ----------

    /// <summary>A breach is opened (IN_CURE with its deadline when the obligation gives cure days, BR-OBL-009) and CMP.BREACH sent to the event's roles in scope.</summary>
    private static async Task<Guid> OpenAsync(BoundUser u, SqlTransaction tx, long facility, long obligationRoot, long obligation, string kind, long? instance, DateTime detected,
        int? cureDays, string description, CancellationToken ct)
    {
        var cure = cureDays is > 0 ? detected.AddDays(cureDays.Value) : (DateTime?)null;
        var (id, publicId) = await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT obl.ObligationBreach (TenantId, ObligationRootId, ObligationId, Kind, ReportingInstanceId, DetectedOn, Description, Status, CureDeadline, CreatedBy)
            OUTPUT inserted.ObligationBreachId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @root, @o2, @kind, @inst, @detected, @desc, @status, @cure, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new { root = obligationRoot, o2 = obligation, kind, inst = instance, detected, desc = description, status = cure is null ? "OPEN" : "IN_CURE", cure }, tx,
            cancellationToken: ct));
        var f = await u.Connection.QuerySingleAsync<(string FacilityNo, long Company, string? CoAr, string? CoEn, string TitleAr, string? TitleEn, DateTime? Due)>(new CommandDefinition(
            """
            SELECT ISNULL(f.PlatformRef, f.FacilityNo) AS FacilityNo, f.BorrowerCompanyId, co.NameAr, co.NameEn, o.TitleAr, o.TitleEn, i.DueDate
              FROM fac.Facility AS f JOIN org.Company AS co ON co.CompanyId = f.BorrowerCompanyId JOIN obl.Obligation AS o ON o.ObligationId = @o
              LEFT JOIN obl.ReportingInstance AS i ON i.ReportingInstanceId = @inst
             WHERE f.FacilityId = @f;
            """, new { f = facility, o = obligation, inst = instance }, tx, cancellationToken: ct));
        var bank = await u.Connection.QuerySingleOrDefaultAsync<(string? Ar, string? En)?>(new CommandDefinition(
            """
            SELECT TOP (1) i.NameAr, i.NameEn FROM fac.FacilityLender AS l JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId JOIN fac.Facility AS f ON f.FacilityId = l.FacilityId
             WHERE l.FacilityId = @f AND l.FromRevision <= f.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo)
             ORDER BY CASE WHEN l.Roles LIKE '%AGENT%' OR l.Roles LIKE '%SOLE%' OR l.Roles LIKE '%LEAD%' THEN 0 ELSE 1 END;
            """, new { f = facility }, tx, cancellationToken: ct));
        var label = kind switch
        {
            "LATE_REPORT" => ("تأخر في التقديم", "late report"),
            "RESTRICTION_VIOLATION" => ("مخالفة قيد", "restriction violated"),
            _ => ("خرق", "breach"),
        };
        await Notifier.RequestAsync(u.Connection, tx, new NotificationRequest("CMP.BREACH", "obl.ObligationBreach", id, $"CMP.BREACH:{id}", f.Company, new Dictionary<string, object?>
        {
            ["facilityNo"] = f.FacilityNo,
            ["companyName"] = new Dictionary<string, string?> { ["ar"] = f.CoAr ?? f.CoEn, ["en"] = f.CoEn ?? f.CoAr },
            ["bankName"] = new Dictionary<string, string?> { ["ar"] = bank?.Ar ?? bank?.En ?? "", ["en"] = bank?.En ?? bank?.Ar ?? "" },
            ["obligationTitle"] = new Dictionary<string, string?> { ["ar"] = f.TitleAr, ["en"] = f.TitleEn ?? f.TitleAr },
            ["breachLabel"] = new Dictionary<string, string> { ["ar"] = label.Item1, ["en"] = label.Item2 },
            ["dueDate"] = FacilityEndpoints.D(f.Due ?? detected),
        }, "/breaches", u.UserId), ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("BREACH_OPENED", "TREASURY", "obl.ObligationBreach", id,
            AfterJson: JsonSerializer.Serialize(new { kind, detectedOn = FacilityEndpoints.D(detected), cureDeadline = FacilityEndpoints.D(cure) })), f.Company, ct);
        await Outbox.EmitAsync(u.Connection, tx, "breach.opened", "obl.ObligationBreach", id, new { breach = publicId }, ct);
        return publicId;
    }

    private sealed class BreachRow
    {
        public long ObligationBreachId { get; init; }
        public Guid PublicId { get; init; }
        public Guid FacilityPublicId { get; init; }
        public string FacilityNo { get; init; } = "";
        public long BorrowerCompanyId { get; init; }
        public string TitleAr { get; init; } = "";
        public string Kind { get; init; } = "";
        public DateTime DetectedOn { get; init; }
        public string? Description { get; init; }
        public string Status { get; init; } = "";
        public DateTime? CureDeadline { get; init; }
        public DateTime? BankNotifiedOn { get; init; }
        public string? WaiverRef { get; init; }
        public DateTime? WaiverDate { get; init; }
        public long? WaiverDocumentId { get; init; }
        public long? UpdatedBy { get; init; }
        public DateTime? ResolvedOn { get; init; }
        public int? CureDays { get; init; }
        public Guid? Item { get; init; }
    }

    private const string BreachSelect = """
        SELECT b.ObligationBreachId, b.PublicId, f.PublicId AS FacilityPublicId, ISNULL(f.PlatformRef, f.FacilityNo) AS FacilityNo, f.BorrowerCompanyId, o.TitleAr, b.Kind, b.DetectedOn, b.Description, b.Status,
               b.CureDeadline, b.BankNotifiedOn, b.WaiverRef, b.WaiverDate, b.WaiverDocumentId, b.UpdatedBy, b.ResolvedOn, o.CureDays, i.PublicId AS Item
          FROM obl.ObligationBreach AS b
          JOIN obl.Obligation AS o ON o.ObligationId = b.ObligationId
          JOIN fac.Facility AS f ON f.FacilityId = o.FacilityId
          LEFT JOIN obl.ReportingInstance AS i ON i.ReportingInstanceId = b.ReportingInstanceId
        """;

    private static object BreachShape(BreachRow b) => new
    {
        id = b.PublicId, facility = b.FacilityPublicId, facilityNo = b.FacilityNo, obligation = b.TitleAr, kind = b.Kind, detectedOn = FacilityEndpoints.D(b.DetectedOn),
        description = b.Description, status = b.Status, cureDeadline = FacilityEndpoints.D(b.CureDeadline), bankNotifiedOn = FacilityEndpoints.D(b.BankNotifiedOn),
        waiverRef = b.WaiverRef, waiverDate = FacilityEndpoints.D(b.WaiverDate), resolvedOn = FacilityEndpoints.D(b.ResolvedOn), item = b.Item,
    };

    private static async Task<IResult> BreachesAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "facility", "status");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var q = http.Request.Query;
        var rows = await u.Connection.QueryAsync<BreachRow>(new CommandDefinition(
            BreachSelect + " WHERE (@f IS NULL OR f.PublicId = @f) AND (@s IS NULL OR b.Status = @s) ORDER BY b.DetectedOn DESC, b.ObligationBreachId DESC;",
            new { f = Guid.TryParse(q["facility"], out var g) ? g : (Guid?)null, s = q["status"].ToString() is { Length: > 0 } s ? s : null }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Where(r => scope.Allows(r.BorrowerCompanyId)).Select(BreachShape) });
    }

    /// <summary>A breach entered by hand (FR-OBL-012): a restriction violated or another breach of an obligation of the approved revision.</summary>
    private static async Task<IResult> OpenBreachAsync(BreachRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var kind = b.Kind?.ToUpperInvariant();
        var on = Date(b.DetectedOn, "detection date");
        if (b.Facility is null || b.Obligation is null || kind is not ("RESTRICTION_VIOLATION" or "OTHER") || on is null || string.IsNullOrWhiteSpace(b.Description))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the facility, the obligation, the kind (RESTRICTION_VIOLATION or OTHER), the date and the description.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, BreachManage);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FacilityEndpoints.FindAsync(u, tx, b.Facility.Value, scope, ct);
        var o = (await RowsAsync(u.Connection, tx, f.FacilityId, f.ApprovedRevisionNo, ct)).FirstOrDefault(x => x.RootId == refs.ItemId(u.TenantId, "obligation", b.Obligation))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The obligation is not an obligation of the approved facility.");
        var id = await OpenAsync(u, tx, f.FacilityId, o.RootId, o.ObligationId, kind, null, on.Value, o.CureDays, b.Description.Trim(), ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/breaches/{id}", new { id });
    }

    /// <summary>
    /// The life of a breach: notify-bank (its date), start-cure (BR-OBL-009), cure, record-waiver (the bank's reference,
    /// date, contact and document), approve-waiver (obl.waiver.approve, not the one who recorded it), close (no action).
    /// </summary>
    private static async Task<IResult> BreachActionAsync(Guid id, string action, BreachActionRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, action == "approve-waiver" ? WaiverApprove : BreachManage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var br = await u.Connection.QuerySingleOrDefaultAsync<BreachRow>(new CommandDefinition(
            BreachSelect.Replace("FROM obl.ObligationBreach AS b", "FROM obl.ObligationBreach AS b WITH (UPDLOCK, HOLDLOCK)", StringComparison.Ordinal) + " WHERE b.PublicId = @id;",
            new { id }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (!(await CompanyScope.OfAsync(u, ct, tx)).Allows(br.BorrowerCompanyId)) throw ApiProblemException.NotFound();
        var open = br.Status is "OPEN" or "IN_CURE";
        if (!open) throw new ApiProblemException(409, "V-OBL-STATE", "The breach is resolved.");
        // The tenant's date, as the breach's detection date is (not the UTC date, which differs near midnight).
        var on = Date(b.On, "date") ?? await BankFas.Data.Workflow.Delegations.TodayAsync(u.Connection, tx, clock.GetUtcNow(), ct);
        if (on < br.DetectedOn) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The date is on or after the breach was detected.");
        string sql;
        object args;
        switch (action)
        {
            case "notify-bank":
                (sql, args) = ("BankNotifiedOn = @on", new { on });
                break;
            case "start-cure":
                if (br.Status == "IN_CURE") throw new ApiProblemException(409, "V-OBL-STATE", "The breach is already in cure.");
                (sql, args) = ("Status = 'IN_CURE', CureDeadline = @cure", new { cure = br.DetectedOn.AddDays(br.CureDays ?? 0) });
                break;
            case "cure":
                (sql, args) = ("Status = 'CURED', ResolvedOn = @on, WaiverRef = NULL, WaiverDate = NULL, WaiverBankContactId = NULL, WaiverConditions = NULL, WaiverValidUntil = NULL, WaiverDocumentId = NULL",
                    new { on });
                break;
            case "record-waiver":
                var date = Date(b.WaiverDate, "waiver date");
                if (string.IsNullOrWhiteSpace(b.WaiverRef) || date is null || b.BankContact is null || b.Document is null)
                    throw ApiProblemException.Invalid("V-OBL-WAIVER", "A waiver has the bank's reference, its date, the bank contact and its document (DQ-F15-9).");
                var contact = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT ContactId FROM ins.Contact WHERE PublicId = @c;", new { c = b.BankContact }, tx,
                    cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-OBL-WAIVER", "The contact is not a contact of a bank of the account.");
                (sql, args) = ("WaiverRef = @ref, WaiverDate = @date, WaiverBankContactId = @contact, WaiverConditions = @cond, WaiverValidUntil = @until, WaiverDocumentId = @doc",
                    new { @ref = b.WaiverRef.Trim(), date, contact, cond = b.Conditions?.Trim(), until = Date(b.ValidUntil, "valid until"), doc = await DocAsync(u, tx, b.Document, ct) });
                break;
            case "approve-waiver":
                if (br.WaiverRef is null) throw new ApiProblemException(409, "V-OBL-WAIVER", "Record the waiver before its approval.");
                if (br.UpdatedBy == u.UserId && !await FacilityRevisionEndpoints.SamePersonAllowedAsync(u, tx, ct))
                    throw ApiProblemException.Forbidden("V-OBL-SOD", "The one who recorded the waiver does not approve it.");
                (sql, args) = ("Status = 'WAIVED', ResolvedOn = @on, WaiverApprovedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), WaiverApprovedOn = SYSUTCDATETIME()", new { on });
                break;
            case "close":
                if (string.IsNullOrWhiteSpace(b.Reason)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason the breach is closed with no action.");
                (sql, args) = ("Status = 'CLOSED_NO_ACTION', ResolvedOn = @on, ConsequenceApplied = @reason, WaiverRef = NULL, WaiverDate = NULL, WaiverBankContactId = NULL, WaiverConditions = NULL, WaiverValidUntil = NULL, WaiverDocumentId = NULL",
                    new { on, reason = b.Reason.Trim() });
                break;
            default:
                throw ApiProblemException.NotFound();
        }
        var p = new DynamicParameters(args);
        p.Add("id", br.ObligationBreachId);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            $"UPDATE obl.ObligationBreach SET {sql}, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ObligationBreachId = @id;", p, tx,
            cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("BREACH_" + action.Replace('-', '_').ToUpperInvariant(), "TREASURY", "obl.ObligationBreach", br.ObligationBreachId,
            AfterJson: JsonSerializer.Serialize(new { on = FacilityEndpoints.D(on), reason = b.Reason, waiverRef = b.WaiverRef })), br.BorrowerCompanyId, ct);
        if (action == "approve-waiver") await Outbox.EmitAsync(u.Connection, tx, "breach.waived", "obl.ObligationBreach", br.ObligationBreachId, new { breach = br.PublicId }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    internal sealed class MeasureRow
    {
        public long CovenantRootId { get; init; }
        public long ObligationRootId { get; init; }
        public string Family { get; init; } = "";
        public string TitleAr { get; init; } = "";
        public string? TitleEn { get; init; }
        public string MeasureKind { get; init; } = "";
        public string? FormulaCode { get; init; }
        public string ThresholdState { get; init; } = "";
        public long? CovenantTestId { get; init; }
        public Guid? TestId { get; init; }
        public DateTime? PeriodEnd { get; init; }
        public DateTime? DueDate { get; init; }
        public int? EvaluationNo { get; init; }
        public string? State { get; init; }
        public string? Result { get; init; }
        public decimal? ActualValue { get; init; }
        public decimal? ThresholdApplied { get; init; }
        public string? OperatorApplied { get; init; }
        public decimal? Headroom { get; init; }
        public decimal? HeadroomPct { get; init; }
        public string? ThresholdUnit { get; init; }
        public Guid? BreachId { get; init; }
        public string? BreachStatus { get; init; }
        public bool? NeedsReview { get; init; }
    }

    /// <summary>
    /// BR-OBL-010 on a date: RED with an open or in-cure breach, an overdue item, a descriptive covenant reviewed as not
    /// compliant, or a measured covenant whose latest result is a BREACH not waived; else AMBER with a WARNING or
    /// MISSING_DATA as the latest result, an item due within 30 days, a facility whose validity is NOT_CONFIRMED or a
    /// review overdue; GREY with no obligation in force; GREEN otherwise. NOT_ASSESSED (no threshold) and NOT_COMPARABLE
    /// are counters and never move the colour. The reasons name each rule that set it, with its count.
    /// </summary>
    internal static async Task<object> ComplianceOfAsync(BoundUser u, FacilityEndpoints.FacilityRow f, DateTime asOf, int expiringDays, CancellationToken ct)
    {
        var items = (await u.Connection.QueryAsync<ItemRow>(new CommandDefinition(ItemSelect + " WHERE f.FacilityId = @f AND i.Status <> 'CANCELLED';", new { f = f.FacilityId },
            cancellationToken: ct))).ToList();
        var breaches = (await u.Connection.QueryAsync<BreachRow>(new CommandDefinition(BreachSelect + " WHERE f.FacilityId = @f;", new { f = f.FacilityId }, cancellationToken: ct))).ToList();
        var families = (await u.Connection.QueryAsync<(string Family, int Count)>(new CommandDefinition(
            """
            SELECT o.Family, COUNT(*) FROM obl.Obligation AS o
             WHERE o.FacilityId = @f AND o.FromRevision <= @a AND (o.ToRevision IS NULL OR o.ToRevision > @a) GROUP BY o.Family;
            """, new { f = f.FacilityId, a = f.ApprovedRevisionNo }, cancellationToken: ct))).ToList();
        // The latest result on the date of each measured covenant in force: the latest evaluation of its latest period that has one.
        var measures = (await u.Connection.QueryAsync<MeasureRow>(new CommandDefinition(
            """
            SELECT cv.RootId AS CovenantRootId, o.RootId AS ObligationRootId, o.Family, o.TitleAr, o.TitleEn, cv.MeasureKind, mf.Code AS FormulaCode, cv.ThresholdState,
                   t.CovenantTestId, t.PublicId AS TestId, t.PeriodEnd, t.DueDate, t.EvaluationNo, t.State, t.Result, t.ActualValue, t.ThresholdApplied, t.OperatorApplied,
                   t.Headroom, t.HeadroomPct, cv.ThresholdUnit, b.PublicId AS BreachId, b.Status AS BreachStatus, b.NeedsReview
              FROM obl.Obligation AS o
              JOIN obl.Covenant AS cv ON cv.ObligationId = o.ObligationId AND cv.MeasureKind <> 'NONE' AND cv.FromRevision <= @a AND (cv.ToRevision IS NULL OR cv.ToRevision > @a)
              LEFT JOIN fin.MeasureFormula AS mf ON mf.MeasureFormulaId = cv.FormulaId
             OUTER APPLY (SELECT TOP (1) x.* FROM obl.CovenantTest AS x
                           WHERE x.CovenantRootId = cv.RootId AND x.PeriodEnd <= @asOf AND x.State NOT IN ('SCHEDULED', 'CANCELLED')
                           ORDER BY x.PeriodEnd DESC, x.EvaluationNo DESC) AS t
             OUTER APPLY (SELECT TOP (1) y.PublicId, y.Status, y.NeedsReview FROM obl.ObligationBreach AS y
                           WHERE y.CovenantRootId = cv.RootId AND y.TestPeriodEnd = t.PeriodEnd ORDER BY y.DetectedOn DESC, y.ObligationBreachId DESC) AS b
             WHERE o.FacilityId = @f AND o.FromRevision <= @a AND (o.ToRevision IS NULL OR o.ToRevision > @a)
             ORDER BY o.TitleAr;
            """, new { f = f.FacilityId, a = f.ApprovedRevisionNo, asOf }, cancellationToken: ct))).ToList();
        // The evaluations of each measure's latest period, oldest first: the trend after a restatement.
        var tests = measures.Where(m => m.PeriodEnd is not null).Select(m => m.CovenantRootId).ToArray();
        var trend = tests.Length == 0 ? [] : (await u.Connection.QueryAsync<(long Root, DateTime PeriodEnd, int EvaluationNo, string? Result, decimal? ActualValue)>(new CommandDefinition(
            "SELECT CovenantRootId, PeriodEnd, EvaluationNo, Result, ActualValue FROM obl.CovenantTest WHERE CovenantRootId IN @tests AND State NOT IN ('SCHEDULED', 'CANCELLED') ORDER BY EvaluationNo;",
            new { tests }, cancellationToken: ct))).ToList();
        var statements = measures.Where(m => m.CovenantTestId is not null).Select(m => m.CovenantTestId!.Value).ToArray();
        var read = statements.Length == 0 ? [] : (await u.Connection.QueryAsync<(long Test, Guid Statement, int VersionNo)>(new CommandDefinition(
            """
            SELECT s.CovenantTestId, fs.PublicId, fs.VersionNo FROM obl.CovenantTestStatement AS s
              JOIN fin.FinancialStatement AS fs ON fs.FinancialStatementId = s.StatementId WHERE s.CovenantTestId IN @statements;
            """, new { statements }, cancellationToken: ct))).ToList();
        var reviews = (await u.Connection.QueryAsync<(string Result, DateTime? Next)>(new CommandDefinition(
            """
            SELECT t.Result, t.NextReviewOn FROM obl.Obligation AS o
              JOIN obl.Covenant AS cv ON cv.ObligationId = o.ObligationId AND cv.MeasureKind = 'NONE' AND cv.FromRevision <= @a AND (cv.ToRevision IS NULL OR cv.ToRevision > @a)
             CROSS APPLY (SELECT TOP (1) x.Result, x.NextReviewOn FROM obl.CovenantTest AS x WHERE x.CovenantRootId = cv.RootId AND x.Method = 'MANUAL_STATUS'
                           ORDER BY x.PeriodEnd DESC, x.EvaluationNo DESC) AS t
             WHERE o.FacilityId = @f AND o.FromRevision <= @a AND (o.ToRevision IS NULL OR o.ToRevision > @a);
            """, new { f = f.FacilityId, a = f.ApprovedRevisionNo }, cancellationToken: ct))).ToList();

        var overdue = items.Count(i => Derived(i, asOf) == "OVERDUE");
        var dueSoon = items.Count(i => Derived(i, asOf) == "DUE_SOON");
        var openBreaches = breaches.Count(b => b.Status is "OPEN" or "IN_CURE");
        var nonCompliant = reviews.Count(r => r.Result == "MANUAL_NON_COMPLIANT");
        var reviewsOverdue = reviews.Count(r => r.Next is { } n && n < asOf);
        var unwaived = measures.Count(m => m.Result == "BREACH" && m.BreachStatus != "WAIVED");
        var warnings = measures.Count(m => m.Result == "WARNING");
        var missing = measures.Count(m => m.Result == "MISSING_DATA");
        var validity = FacilityValidity.Indicator(f.LifecycleStatus, f.EffectiveFrom, f.ExpiryDate, asOf, expiringDays);
        var reasons = new List<object>();
        void Reason(string code, int n) { if (n > 0) reasons.Add(new { code, count = n }); }
        Reason("OPEN_BREACH", openBreaches); Reason("OVERDUE", overdue); Reason("NON_COMPLIANT_REVIEW", nonCompliant); Reason("BREACH_NOT_WAIVED", unwaived);
        var red = reasons.Count > 0;
        Reason("WARNING", warnings); Reason("MISSING_DATA", missing); Reason("DUE_SOON", dueSoon); Reason("NOT_CONFIRMED", validity == "NOT_CONFIRMED" ? 1 : 0);
        Reason("REVIEW_OVERDUE", reviewsOverdue);
        var colour = families.Count == 0 ? "GREY" : red ? "RED" : reasons.Count > 0 ? "AMBER" : "GREEN";
        string? Day(DateTime? d) => d is { } x ? FacilityEndpoints.D(x) : null;
        return new
        {
            facility = f.PublicId, facilityNo = f.FacilityNo, asOf = FacilityEndpoints.D(asOf), status = colour, colour, reasons, validity,
            overdue, dueSoon, openBreaches, nonCompliant, reviewsOverdue,
            inCure = breaches.Count(b => b.Status == "IN_CURE"), submittedLateLastYear = items.Count(i => i.SubmittedOn is { } s && s > i.DueDate && s >= asOf.AddYears(-1)),
            notAssessed = measures.Count(m => m.Result == "NOT_ASSESSED_NO_THRESHOLD"), notComparable = measures.Count(m => m.Result == "NOT_COMPARABLE"),
            needsReview = measures.Count(m => m.NeedsReview == true),
            families = families.Select(x => new
            {
                family = x.Family, obligations = x.Count,
                measured = measures.Count(m => m.Family == x.Family),
                breaches = measures.Count(m => m.Family == x.Family && m.Result == "BREACH"),
                warnings = measures.Count(m => m.Family == x.Family && m.Result == "WARNING"),
            }),
            measures = measures.Select(m => new
            {
                obligationTitleAr = m.TitleAr, obligationTitleEn = m.TitleEn, family = m.Family, measureKind = m.MeasureKind, formula = m.FormulaCode, thresholdState = m.ThresholdState,
                test = m.TestId, periodEnd = Day(m.PeriodEnd), dueDate = Day(m.DueDate), evaluationNo = m.EvaluationNo, state = m.State, result = m.Result,
                actualValue = m.ActualValue, threshold = m.ThresholdApplied, @operator = m.OperatorApplied, unit = m.ThresholdUnit, headroom = m.Headroom, headroomPct = m.HeadroomPct,
                trend = trend.Where(x => x.Root == m.CovenantRootId && x.PeriodEnd == m.PeriodEnd).Select(x => new { evaluationNo = x.EvaluationNo, result = x.Result, actualValue = x.ActualValue }),
                statements = read.Where(x => x.Test == m.CovenantTestId).Select(x => new { id = x.Statement, versionNo = x.VersionNo }),
                breach = m.BreachId is null ? null : new { id = m.BreachId, status = m.BreachStatus, needsReview = m.NeedsReview },
            }),
            next = items.Where(i => i.Status == "SCHEDULED" && i.DueDate >= asOf).OrderBy(i => i.DueDate).Take(5).Select(i => ItemShape(i, asOf)),
            breaches = breaches.Where(b => b.Status is "OPEN" or "IN_CURE").Select(BreachShape),
        };
    }

    private static DateTime AsOf(HttpRequest r, TimeProvider clock) =>
        LimitEndpoints.Date(r.Query["asOf"].Count > 0 ? r.Query["asOf"].ToString() : null, "asOf") ?? clock.GetUtcNow().UtcDateTime.Date;

    /// <summary>SVC-FAC-06 and R-OBL-04: the compliance of a facility on a date (today by default).</summary>
    private static async Task<IResult> ComplianceAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "asOf");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, ct);
        return Results.Ok(await ComplianceOfAsync(u, f, AsOf(http.Request, clock), await FacilityValidity.ExpiringDaysAsync(u.Connection, null, ct), ct));
    }

    /// <summary>R-OBL-05: the compliance of the group's active facilities on a date, by company, bank and colour.</summary>
    private static async Task<IResult> GroupComplianceAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "asOf", "company", "bank", "colour");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var q = http.Request.Query;
        var asOf = AsOf(http.Request, clock);
        Guid? company = q["company"].Count > 0 ? (Guid.TryParse(q["company"], out var c) ? c : throw new ApiProblemException(400, "MALFORMED_REQUEST", "company is an id.")) : null;
        var bank = q["bank"].Count > 0 ? q["bank"].ToString() : null;
        var colour = q["colour"].Count > 0 ? q["colour"].ToString().ToUpperInvariant() : null;
        var ids = await u.Connection.QueryAsync<Guid>(new CommandDefinition(
            """
            SELECT f.PublicId FROM fac.Facility AS f JOIN org.Company AS co ON co.CompanyId = f.BorrowerCompanyId
             WHERE f.LifecycleStatus = 'ACTIVE' AND f.ApprovedRevisionNo > 0 AND (@company IS NULL OR co.PublicId = @company) AND (@all = 1 OR f.BorrowerCompanyId IN @ids)
             ORDER BY co.NameAr, f.FacilityNo;
            """, new { company, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: ct));
        var days = await FacilityValidity.ExpiringDaysAsync(u.Connection, null, ct);
        var rows = new List<object>();
        foreach (var fid in ids)
        {
            var f = await FacilityEndpoints.FindAsync(u, null, fid, scope, ct);
            var lenders = (await FacilityEndpoints.LendersAtAsync(u, null, [(f.FacilityId, f.ApprovedRevisionNo)], ct)).GetValueOrDefault(f.FacilityId, []);
            if (bank is not null && !lenders.Any(l => string.Equals(l.Code, bank, StringComparison.OrdinalIgnoreCase) || l.InstitutionPublicId.ToString() == bank)) continue;
            var one = await ComplianceOfAsync(u, f, asOf, days, ct);
            var json = JsonSerializer.SerializeToElement(one);
            if (colour is not null && json.GetProperty("colour").GetString() != colour) continue;
            rows.Add(new
            {
                company = f.BorrowerId, companyNameAr = f.BorrowerNameAr, banks = lenders.Select(l => l.Code), compliance = json,
            });
        }
        return Results.Ok(new { asOf = FacilityEndpoints.D(asOf), items = rows });
    }
}

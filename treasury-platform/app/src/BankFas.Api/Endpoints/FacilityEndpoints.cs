using System.Data;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using BankFas.Api.Infrastructure;
using BankFas.Core.Calendar;
using BankFas.Data;
using BankFas.Data.Facilities;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record FacilityRequest(Guid? Borrower, string? FacilityType, string? Currency, decimal? TotalAmount, bool? IsSyndicated, string? PrecedenceLanguage,
    string? PrecedenceClauseRef, string? BankReferenceNo, string? BankStructureNo, string? AgreementDate, string? AgreementDateHijri, string? EffectiveFrom,
    string? EffectiveFromHijri, string? ExpiryDate, string? ExpiryDateHijri, string? OperativeCalendar, bool? HijriAdjusted, string? HijriAdjustReason,
    string[]? BankUnilateralRights, int? NoticeDays, bool? UsageBlockOnBreach, bool? UsageBlockOnUnconfirmed, int[]? AlertLeadDays, string? ChangeSummary,
    string? FacilityClass = null);
public sealed record LenderRequest(Guid? Institution, string[]? Roles, decimal? SharePct);
public sealed record FacilityDocumentRequest(Guid? Document, string? DocumentDate, string? DocumentDateHijri, string? Language, int? PrecedenceRank, string? Amends,
    int? PageCount, bool? IsSignedCopy, bool? IsScanned);
public sealed record FacilityAccountRequest(Guid? Account, string? Purpose, bool? IsDefault, string? ValidFrom, string? ValidTo, string? Notes);
public sealed record LifecycleRequest(string? Reason);
public sealed record RenewRequest(string? EffectiveFrom, string? ExpiryDate, decimal? TotalAmount, string? BankReferenceNo);

/// <summary>
/// The facility package (FR-FAC-001 to 008, 022 to 024; BR-FAC-001 to 007; spec 12 sections 3 and 8; S2 brief batch S2-B):
/// the header, its lenders and documents, the renewal chain, the accounts linked to it and its lifecycle. A facility
/// is written as revisions (BR-FAC-003): every lender and document row belongs to the revision that wrote it
/// (FromRevision) until the one that replaced it (ToRevision), and an approved revision is fixed (044). The header is
/// written directly while the facility is a draft, and after the first approval only through the open revision's
/// HeaderChanges, applied when that revision is approved (DQ-F13-1). The revision cycle is in
/// <see cref="FacilityRevisionEndpoints"/>. Amounts of a company outside the user's scope are not shown (Q-FAC-11):
/// a facility is listed and read only when its borrower is in scope.
/// </summary>
public static class FacilityEndpoints
{
    internal const string View = "fac.view";
    internal const string Edit = "fac.edit";
    internal const string Module = "FACILITIES";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/facilities", ListAsync);
        api.MapPost("/facilities", CreateAsync);
        api.MapGet("/facilities/{id:guid}", GetAsync);
        api.MapPatch("/facilities/{id:guid}", PatchAsync);
        api.MapPost("/facilities/{id:guid}/lenders", AddLenderAsync);
        api.MapPatch("/facilities/{id:guid}/lenders/{reference}", ChangeLenderAsync);
        api.MapDelete("/facilities/{id:guid}/lenders/{reference}", RemoveLenderAsync);
        api.MapPost("/facilities/{id:guid}/documents", AddDocumentAsync);
        api.MapPatch("/facilities/{id:guid}/documents/{reference}", ChangeDocumentAsync);
        api.MapDelete("/facilities/{id:guid}/documents/{reference}", RemoveDocumentAsync);
        api.MapGet("/facilities/{id:guid}/chain", ChainAsync);
        api.MapGet("/facilities/{id:guid}/accounts", AccountsAsync);
        api.MapPost("/facilities/{id:guid}/accounts", AddAccountAsync);
        api.MapPost("/facilities/{id:guid}/accounts/{reference}/actions/end", EndAccountAsync);
        api.MapPost("/facilities/{id:guid}/actions/suspend", (Guid id, LifecycleRequest b, HttpContext h, SqlConnectionFactory d) => LifecycleAsync(id, b, "SUSPEND", h, d));
        api.MapPost("/facilities/{id:guid}/actions/resume", (Guid id, LifecycleRequest b, HttpContext h, SqlConnectionFactory d) => LifecycleAsync(id, b, "RESUME", h, d));
        api.MapPost("/facilities/{id:guid}/actions/expire", (Guid id, LifecycleRequest b, HttpContext h, SqlConnectionFactory d) => LifecycleAsync(id, b, "EXPIRE", h, d));
        api.MapPost("/facilities/{id:guid}/actions/terminate", (Guid id, LifecycleRequest b, HttpContext h, SqlConnectionFactory d) => LifecycleAsync(id, b, "TERMINATE", h, d));
        api.MapPost("/facilities/{id:guid}/actions/renew", RenewAsync);
    }

    // ---------- the header ----------

    internal sealed class FacilityRow
    {
        public long FacilityId { get; init; }
        public Guid PublicId { get; init; }
        public string FacilityNo { get; init; } = "";
        public string? PlatformRef { get; init; }
        public int? FacilityClassId { get; init; }
        public string? FacilityClass { get; init; }
        public long BorrowerCompanyId { get; init; }
        public Guid BorrowerId { get; init; }
        public string? BorrowerNameAr { get; init; }
        public string? BorrowerNameEn { get; init; }
        public int FacilityTypeId { get; init; }
        public string FacilityTypeCode { get; init; } = "";
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = "";
        public long? PreviousFacilityId { get; init; }
        public Guid? PreviousId { get; init; }
        public string LifecycleStatus { get; init; } = "";
        public string? LifecycleReason { get; init; }
        public int ApprovedRevisionNo { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public long? CreatedBy { get; init; }
        // The header values, as the table holds them.
        public decimal TotalAmount { get; init; }
        public bool IsSyndicated { get; init; }
        public string PrecedenceLanguage { get; init; } = "";
        public string? PrecedenceClauseRef { get; init; }
        public string? BankReferenceNo { get; init; }
        public string? BankStructureNo { get; init; }
        public DateTime? AgreementDate { get; init; }
        public string? AgreementDateHijri { get; init; }
        public DateTime EffectiveFrom { get; init; }
        public string? EffectiveFromHijri { get; init; }
        public DateTime ExpiryDate { get; init; }
        public string? ExpiryDateHijri { get; init; }
        public string OperativeCalendar { get; init; } = "";
        public bool HijriAdjusted { get; init; }
        public string? HijriAdjustReason { get; init; }
        public string? BankUnilateralRights { get; init; }
        public int? NoticeDays { get; init; }
        public bool UsageBlockOnBreach { get; init; }
        public bool UsageBlockOnUnconfirmed { get; init; }
        public string? AlertLeadDays { get; init; }

        public FacilityHeader Header() => new()
        {
            TotalAmount = TotalAmount, IsSyndicated = IsSyndicated, PrecedenceLanguage = PrecedenceLanguage, PrecedenceClauseRef = PrecedenceClauseRef,
            BankReferenceNo = BankReferenceNo, BankStructureNo = BankStructureNo, AgreementDate = D(AgreementDate), AgreementDateHijri = AgreementDateHijri,
            EffectiveFrom = D(EffectiveFrom)!, EffectiveFromHijri = EffectiveFromHijri, ExpiryDate = D(ExpiryDate)!, ExpiryDateHijri = ExpiryDateHijri,
            OperativeCalendar = OperativeCalendar, HijriAdjusted = HijriAdjusted, HijriAdjustReason = HijriAdjustReason, BankUnilateralRights = BankUnilateralRights,
            NoticeDays = NoticeDays, UsageBlockOnBreach = UsageBlockOnBreach, UsageBlockOnUnconfirmed = UsageBlockOnUnconfirmed, AlertLeadDays = AlertLeadDays,
        };
    }

    /// <summary>
    /// The header values a revision may change (DQ-F13-1): stored in the facility while it is a draft, and in the open
    /// revision's HeaderChanges (the whole set, as it will be after approval) once it has been approved. The borrower,
    /// the type and the currency of a facility do not change; a different one is a new facility.
    /// </summary>
    internal sealed record FacilityHeader
    {
        public decimal TotalAmount { get; init; }
        public bool IsSyndicated { get; init; }
        public string PrecedenceLanguage { get; init; } = "";
        public string? PrecedenceClauseRef { get; init; }
        public string? BankReferenceNo { get; init; }
        public string? BankStructureNo { get; init; }
        public string? AgreementDate { get; init; }
        public string? AgreementDateHijri { get; init; }
        public string EffectiveFrom { get; init; } = "";
        public string? EffectiveFromHijri { get; init; }
        public string ExpiryDate { get; init; } = "";
        public string? ExpiryDateHijri { get; init; }
        public string OperativeCalendar { get; init; } = "GREGORIAN";
        public bool HijriAdjusted { get; init; }
        public string? HijriAdjustReason { get; init; }
        public string? BankUnilateralRights { get; init; }
        public int? NoticeDays { get; init; }
        public bool UsageBlockOnBreach { get; init; }
        public bool UsageBlockOnUnconfirmed { get; init; }
        public string? AlertLeadDays { get; init; }

        [JsonIgnore] public DateTime Effective => DateTime.ParseExact(EffectiveFrom, "yyyy-MM-dd", CultureInfo.InvariantCulture);
        [JsonIgnore] public DateTime Expiry => DateTime.ParseExact(ExpiryDate, "yyyy-MM-dd", CultureInfo.InvariantCulture);
    }

    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { DefaultIgnoreCondition = JsonIgnoreCondition.Never };

    internal static string? D(DateTime? d) => d?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    internal const string FacilitySelect =
        """
        SELECT f.FacilityId, f.PublicId, f.FacilityNo, f.PlatformRef, f.FacilityClassId, fc.Code AS FacilityClass, f.BorrowerCompanyId, co.PublicId AS BorrowerId, co.NameAr AS BorrowerNameAr, co.NameEn AS BorrowerNameEn,
               f.FacilityTypeId, ft.Code AS FacilityTypeCode, f.CurrencyId, cu.Code AS CurrencyCode, f.PreviousFacilityId, pf.PublicId AS PreviousId,
               f.LifecycleStatus, f.LifecycleReason, f.ApprovedRevisionNo, f.RowVersion, f.CreatedBy,
               f.TotalAmount, f.IsSyndicated, f.PrecedenceLanguage, f.PrecedenceClauseRef, f.BankReferenceNo, f.BankStructureNo, f.AgreementDate, f.AgreementDateHijri,
               f.EffectiveFrom, f.EffectiveFromHijri, f.ExpiryDate, f.ExpiryDateHijri, f.OperativeCalendar, f.HijriAdjusted, f.HijriAdjustReason,
               f.BankUnilateralRights, f.NoticeDays, f.UsageBlockOnBreach, f.UsageBlockOnUnconfirmed, f.AlertLeadDays
          FROM fac.Facility AS f
          JOIN org.Company AS co ON co.CompanyId = f.BorrowerCompanyId
          JOIN cat.FacilityType AS ft ON ft.FacilityTypeId = f.FacilityTypeId
          JOIN ref.Currency AS cu ON cu.CurrencyId = f.CurrencyId
          LEFT JOIN fac.Facility AS pf ON pf.FacilityId = f.PreviousFacilityId
          LEFT JOIN cat.LookupItem AS fc ON fc.LookupItemId = f.FacilityClassId
        """;

    /// <summary>The facility, 404 when it does not exist or its borrower is outside the user's scope; locked for update in a write.</summary>
    internal static async Task<FacilityRow> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct, bool lockRow = false)
    {
        var f = await u.Connection.QuerySingleOrDefaultAsync<FacilityRow>(new CommandDefinition(
            FacilitySelect.Replace("FROM fac.Facility AS f", lockRow ? "FROM fac.Facility AS f WITH (UPDLOCK, HOLDLOCK)" : "FROM fac.Facility AS f", StringComparison.Ordinal)
            + " WHERE f.PublicId = @id;", new { id }, tx, cancellationToken: ct));
        if (f is null || !scope.Allows(f.BorrowerCompanyId)) throw ApiProblemException.NotFound();
        return f;
    }

    internal static async Task<(BoundUser U, CompanyScope Scope)> OpenAsync(HttpContext http, SqlConnectionFactory db, string permission)
    {
        var u = await BoundUser.OpenAsync(http, db, permission);
        try
        {
            await u.RequireModuleAsync(Module, http.RequestAborted);
            return (u, await CompanyScope.OfAsync(u, http.RequestAborted));
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }

    /// <summary>A date and its Hijri text (FR-FAC-002, FR-PLT-033, Q-FAC-10): the Gregorian date rules; a Hijri text alone gives it; both must agree unless adjusted.</summary>
    internal static (string? Date, string? Hijri, bool Differs) DatePair(string? gregorian, string? hijri, string label)
    {
        string? g = null;
        if (!string.IsNullOrWhiteSpace(gregorian))
        {
            if (!DateTime.TryParseExact(gregorian.Trim(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d))
                throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {label} is a date YYYY-MM-DD.");
            g = D(d);
        }
        if (string.IsNullOrWhiteSpace(hijri)) return (g, g is null ? null : HijriDates.FromGregorian(DateOnly.ParseExact(g, "yyyy-MM-dd", CultureInfo.InvariantCulture)), false);
        var fromHijri = HijriDates.ToGregorian(hijri) ?? throw ApiProblemException.Invalid("V-PLT-HIJRI", "This Hijri date does not exist.");
        var h = HijriDates.FromGregorian(fromHijri);
        var fromHijriText = fromHijri.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        return g is null ? (fromHijriText, h, false) : (g, h, g != fromHijriText);
    }

    private static readonly string[] Rights = ["EXTEND", "CHANGE_PRICING", "CANCEL", "REDUCE_LIMITS"];
    private static readonly int[] LeadOptions = [90, 60, 30, 15, 7, 0];

    /// <summary>The header after a request: the values given replace those of <paramref name="was"/>; checked as the database checks them, before it does.</summary>
    internal static FacilityHeader Merge(FacilityHeader was, FacilityRequest b)
    {
        var differs = false;
        string? Pick(string? g, string? h, string? oldG, string? oldH, string label, out string? hijri)
        {
            if (g is null && h is null) { hijri = oldH; return oldG; }
            var p = DatePair(g, h, label);
            differs |= p.Differs;
            hijri = p.Hijri;
            return p.Date;
        }
        var agreement = Pick(b.AgreementDate, b.AgreementDateHijri, was.AgreementDate, was.AgreementDateHijri, "agreement date", out var agreementH);
        var effective = Pick(b.EffectiveFrom, b.EffectiveFromHijri, was.EffectiveFrom is { Length: > 0 } e ? e : null, was.EffectiveFromHijri, "start date", out var effectiveH);
        var expiry = Pick(b.ExpiryDate, b.ExpiryDateHijri, was.ExpiryDate is { Length: > 0 } x ? x : null, was.ExpiryDateHijri, "expiry date", out var expiryH);
        if (effective is null || expiry is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the start and expiry dates of the facility.");
        var adjusted = b.HijriAdjusted ?? (differs || was.HijriAdjusted);
        var adjustReason = b.HijriAdjustReason is null ? was.HijriAdjustReason : b.HijriAdjustReason.Trim() is { Length: > 0 } r ? r : null;
        if (differs && !adjusted) throw ApiProblemException.Invalid("V-FAC-HIJRI", "The Hijri and Gregorian dates differ: mark the Hijri date adjusted and give the reason, or correct it.");
        if (adjusted && adjustReason is null) throw ApiProblemException.Invalid("V-FAC-HIJRI", "An adjusted Hijri date has its reason.");
        string? rights = was.BankUnilateralRights;
        if (b.BankUnilateralRights is not null)
        {
            var set = b.BankUnilateralRights.Select(x => x.Trim().ToUpperInvariant()).Distinct(StringComparer.Ordinal).ToArray();
            if (set.Any(x => !Rights.Contains(x, StringComparer.Ordinal))) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A bank right is EXTEND, CHANGE_PRICING, CANCEL or REDUCE_LIMITS.");
            rights = set.Length == 0 ? null : string.Join(',', Rights.Where(set.Contains));
        }
        string? lead = was.AlertLeadDays;
        if (b.AlertLeadDays is not null)
        {
            if (b.AlertLeadDays.Any(x => !LeadOptions.Contains(x))) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The alert days are among 90, 60, 30, 15, 7 and 0.");
            lead = b.AlertLeadDays.Length == 0 ? null : string.Join(',', LeadOptions.Where(b.AlertLeadDays.Contains).Select(x => x.ToString(CultureInfo.InvariantCulture)));
        }
        var h = was with
        {
            TotalAmount = b.TotalAmount ?? was.TotalAmount,
            IsSyndicated = b.IsSyndicated ?? was.IsSyndicated,
            PrecedenceLanguage = b.PrecedenceLanguage?.Trim().ToUpperInvariant() ?? was.PrecedenceLanguage,
            PrecedenceClauseRef = b.PrecedenceClauseRef ?? was.PrecedenceClauseRef,
            BankReferenceNo = b.BankReferenceNo is null ? was.BankReferenceNo : b.BankReferenceNo.Trim() is { Length: > 0 } br ? br : null,
            BankStructureNo = b.BankStructureNo is null ? was.BankStructureNo : b.BankStructureNo.Trim() is { Length: > 0 } bs ? bs : null,
            AgreementDate = agreement, AgreementDateHijri = agreementH, EffectiveFrom = effective, EffectiveFromHijri = effectiveH, ExpiryDate = expiry, ExpiryDateHijri = expiryH,
            OperativeCalendar = b.OperativeCalendar?.Trim().ToUpperInvariant() ?? was.OperativeCalendar,
            HijriAdjusted = adjusted, HijriAdjustReason = adjusted ? adjustReason : null,
            BankUnilateralRights = rights, NoticeDays = b.NoticeDays ?? was.NoticeDays,
            UsageBlockOnBreach = b.UsageBlockOnBreach ?? was.UsageBlockOnBreach, UsageBlockOnUnconfirmed = b.UsageBlockOnUnconfirmed ?? was.UsageBlockOnUnconfirmed,
            AlertLeadDays = lead,
        };
        if (h.TotalAmount <= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The total of the facility is above zero.");
        if (h.PrecedenceLanguage is not ("AR" or "EN" or "EQUAL")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The language that prevails is AR, EN or EQUAL.");
        if (h.OperativeCalendar is not ("GREGORIAN" or "HIJRI")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The operative calendar is GREGORIAN or HIJRI.");
        if (h.Expiry < h.Effective) throw ApiProblemException.Invalid("V-FAC-DATES", "The facility expires on or after its start.");
        if (h.AgreementDate is not null && string.CompareOrdinal(h.AgreementDate, h.EffectiveFrom) > 0)
            throw ApiProblemException.Invalid("V-FAC-DATES", "The agreement is dated on or before the start of the facility.");
        if (h.NoticeDays is < 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The notice is a number of days from zero.");
        if (h.BankUnilateralRights?.Contains("CHANGE_PRICING", StringComparison.Ordinal) == true && h.NoticeDays is null)
            throw ApiProblemException.Invalid("V-FAC-NOTICE", "A bank that may change the pricing gives notice: enter the notice days.");
        return h;
    }

    internal static Task WriteHeaderAsync(BoundUser u, SqlTransaction tx, long facilityId, FacilityHeader h, CancellationToken ct, string extraSet = "", object? extra = null)
    {
        var p = new DynamicParameters(new
        {
            f = facilityId, h.TotalAmount, h.IsSyndicated, h.PrecedenceLanguage, h.PrecedenceClauseRef, h.BankReferenceNo, h.BankStructureNo,
            AgreementDate = h.AgreementDate, h.AgreementDateHijri, EffectiveFrom = h.EffectiveFrom, h.EffectiveFromHijri, ExpiryDate = h.ExpiryDate, h.ExpiryDateHijri,
            h.OperativeCalendar, h.HijriAdjusted, h.HijriAdjustReason, h.BankUnilateralRights, h.NoticeDays, h.UsageBlockOnBreach, h.UsageBlockOnUnconfirmed, h.AlertLeadDays,
        });
        if (extra is not null) p.AddDynamicParams(extra);
        return u.Connection.ExecuteAsync(new CommandDefinition(
            $"""
            UPDATE fac.Facility SET TotalAmount = @TotalAmount, IsSyndicated = @IsSyndicated, PrecedenceLanguage = @PrecedenceLanguage, PrecedenceClauseRef = @PrecedenceClauseRef,
                   BankReferenceNo = @BankReferenceNo, BankStructureNo = @BankStructureNo, AgreementDate = @AgreementDate, AgreementDateHijri = @AgreementDateHijri,
                   EffectiveFrom = @EffectiveFrom, EffectiveFromHijri = @EffectiveFromHijri, ExpiryDate = @ExpiryDate, ExpiryDateHijri = @ExpiryDateHijri,
                   OperativeCalendar = @OperativeCalendar, HijriAdjusted = @HijriAdjusted, HijriAdjustReason = @HijriAdjustReason, BankUnilateralRights = @BankUnilateralRights,
                   NoticeDays = @NoticeDays, UsageBlockOnBreach = @UsageBlockOnBreach, UsageBlockOnUnconfirmed = @UsageBlockOnUnconfirmed, AlertLeadDays = @AlertLeadDays{extraSet},
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE FacilityId = @f;
            """, p, tx, cancellationToken: ct));
    }

    /// <summary>The next facility number (FR-FAC-001, CORE.NUMBERING FACILITY), in the transaction of the facility it numbers; the year of allocation (OQ-2).</summary>
    private static async Task<(string No, long IssueId)> AllocateAsync(BoundUser u, SqlTransaction tx, CancellationToken ct)
    {
        var p = new DynamicParameters();
        p.Add("@SequenceKey", "FACILITY", DbType.AnsiString, size: 50);
        p.Add("@IssuedNumber", null, DbType.String, ParameterDirection.Output, 60);
        p.Add("@NumberIssueId", null, DbType.Int64, ParameterDirection.Output);
        await u.Connection.ExecuteAsync(new CommandDefinition("cfg.usp_AllocateNumber", p, tx, commandType: CommandType.StoredProcedure, cancellationToken: ct));
        return (p.Get<string>("@IssuedNumber"), p.Get<long>("@NumberIssueId"));
    }

    private static async Task<IResult> CreateAsync(FacilityRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Borrower is null || string.IsNullOrWhiteSpace(b.FacilityType) || string.IsNullOrWhiteSpace(b.Currency) || b.TotalAmount is null)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the borrower, the facility type, the currency and the total.");
        var header = Merge(new FacilityHeader { PrecedenceLanguage = "AR" }, b);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var company = await CompanyEndpoints.FindAsync(u, tx, b.Borrower.Value, scope, ct);
        if (company.Status is "ARCHIVED" or "LIQUIDATED") throw new ApiProblemException(409, "V-ORG-ARCHIVED", "The borrower is archived or liquidated.");
        var type = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT FacilityTypeId FROM cat.FacilityType WHERE Code = @c AND IsActive = 1;", new { c = b.FacilityType.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The facility type is not an active type of the catalogue.");
        var currency = await CurrencyAsync(u, tx, b.Currency, ct);
        int? facilityClass = string.IsNullOrWhiteSpace(b.FacilityClass) ? null : await FacilityRefs.ClassAsync(u.Connection, tx, b.FacilityClass, ct);
        var (no, issue) = await AllocateAsync(u, tx, ct);
        var id = await InsertFacilityAsync(u, tx, no, company.CompanyId, type, currency, header, null, ct, facilityClass);
        await u.Connection.ExecuteAsync(new CommandDefinition("UPDATE cfg.NumberIssue SET EntityType = 'fac.Facility', EntityId = @f WHERE NumberIssueId = @i;",
            new { f = id.FacilityId, i = issue }, tx, cancellationToken: ct));
        var rev = await FacilityRevisionEndpoints.InsertRevisionAsync(u, tx, id.FacilityId, 1, "INITIAL", header.EffectiveFrom, b.ChangeSummary, null, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FACILITY_CREATED", "TREASURY", "fac.Facility", id.FacilityId,
            AfterJson: JsonSerializer.Serialize(new { facilityNo = no, type = b.FacilityType, currency = b.Currency, revision = rev })), company.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id.PublicId}", new { id = id.PublicId, facilityNo = no });
    }

    internal static async Task<int> CurrencyAsync(BoundUser u, SqlTransaction? tx, string code, CancellationToken ct) =>
        await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @c;",
            new { c = code.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The currency is an ISO code of the reference list.");

    internal static async Task<(long FacilityId, Guid PublicId)> InsertFacilityAsync(BoundUser u, SqlTransaction tx, string no, long company, int type, int currency,
        FacilityHeader h, long? previous, CancellationToken ct, int? facilityClass = null) =>
        await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT fac.Facility (TenantId, FacilityNo, BankReferenceNo, BankStructureNo, BorrowerCompanyId, FacilityTypeId, CurrencyId, TotalAmount, IsSyndicated,
                                 PrecedenceLanguage, PrecedenceClauseRef, AgreementDate, AgreementDateHijri, EffectiveFrom, EffectiveFromHijri, ExpiryDate, ExpiryDateHijri,
                                 OperativeCalendar, HijriAdjusted, HijriAdjustReason, PreviousFacilityId, LifecycleStatus, BankUnilateralRights, NoticeDays,
                                 UsageBlockOnBreach, UsageBlockOnUnconfirmed, AlertLeadDays, FacilityClassId, CreatedBy)
            OUTPUT inserted.FacilityId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @no, @BankReferenceNo, @BankStructureNo, @company, @type, @currency, @TotalAmount, @IsSyndicated,
                    @PrecedenceLanguage, @PrecedenceClauseRef, @AgreementDate, @AgreementDateHijri, @EffectiveFrom, @EffectiveFromHijri, @ExpiryDate, @ExpiryDateHijri,
                    @OperativeCalendar, @HijriAdjusted, @HijriAdjustReason, @previous, 'DRAFT', @BankUnilateralRights, @NoticeDays,
                    @UsageBlockOnBreach, @UsageBlockOnUnconfirmed, @AlertLeadDays, @facilityClass, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new
            {
                no, company, type, currency, previous, facilityClass, h.BankReferenceNo, h.BankStructureNo, h.TotalAmount, h.IsSyndicated, h.PrecedenceLanguage, h.PrecedenceClauseRef,
                h.AgreementDate, h.AgreementDateHijri, h.EffectiveFrom, h.EffectiveFromHijri, h.ExpiryDate, h.ExpiryDateHijri, h.OperativeCalendar, h.HijriAdjusted,
                h.HijriAdjustReason, h.BankUnilateralRights, h.NoticeDays, h.UsageBlockOnBreach, h.UsageBlockOnUnconfirmed, h.AlertLeadDays,
            }, tx, cancellationToken: ct));

    /// <summary>
    /// The header is edited in the facility while it is a draft, and in the open draft revision once approved (its
    /// HeaderChanges). An EXTENSION moves only the expiry date and the alerts; any revision may correct the rest.
    /// </summary>
    private static async Task<IResult> PatchAsync(Guid id, FacilityRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Borrower is not null || b.FacilityType is not null || b.Currency is not null)
            throw ApiProblemException.Invalid("V-FAC-FIXED", "The borrower, the type and the currency of a facility do not change; a different one is a new facility.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (!expected.AsSpan().SequenceEqual(f.RowVersion)) throw ETags.Conflict();
        var rev = await FacilityRevisionEndpoints.DraftAsync(u, tx, f, ct);
        // BR-FAC-021: the class is chosen until the reference is written; after, the reference stays as it is.
        if (!string.IsNullOrWhiteSpace(b.FacilityClass))
        {
            var cls = await FacilityRefs.ClassAsync(u.Connection, tx, b.FacilityClass, ct);
            if (cls != f.FacilityClassId)
            {
                if (f.PlatformRef is not null)
                    throw ApiProblemException.Invalid("V-FAC-REF-FIXED", $"The facility's reference {f.PlatformRef} is written; its class does not change.");
                await u.Connection.ExecuteAsync(new CommandDefinition(
                    "UPDATE fac.Facility SET FacilityClassId = @c, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE FacilityId = @f;",
                    new { c = cls, f = f.FacilityId }, tx, cancellationToken: ct));
            }
        }
        var was = rev.Header(f);
        var now = Merge(was, b);
        if (rev.ReasonKind == "EXTENSION" && (now with { ExpiryDate = was.ExpiryDate, ExpiryDateHijri = was.ExpiryDateHijri, AlertLeadDays = was.AlertLeadDays }) != was)
            throw ApiProblemException.Invalid("V-FAC-EXTENSION", "An extension moves the expiry date only; correct other terms with an amendment or a correction.");
        if (f.ApprovedRevisionNo == 0) await WriteHeaderAsync(u, tx, f.FacilityId, now, ct);
        else
        {
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE fac.FacilityRevision SET HeaderChanges = @h, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE FacilityRevisionId = @r;",
                new { h = now == f.Header() ? null : JsonSerializer.Serialize(now, Json), r = rev.FacilityRevisionId }, tx, cancellationToken: ct));
            // The facility row's version moves so a second editor of the same header learns of the change.
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE fac.Facility SET UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE FacilityId = @f;",
                new { f = f.FacilityId }, tx, cancellationToken: ct));
        }
        await FacilityRevisionEndpoints.EditedAsync(u, tx, f, rev, "HEADER", JsonSerializer.Serialize(new { before = was, after = now }, Json), ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- reading ----------

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "company", "status", "institution", "validity", "q");
        var (u, scope) = await OpenAsync(http, db, View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var q = http.Request.Query;
        Guid? company = Guid.TryParse(q["company"], out var cg) ? cg : null;
        Guid? institution = Guid.TryParse(q["institution"], out var ig) ? ig : null;
        var status = q["status"].ToString() is { Length: > 0 } s ? s.ToUpperInvariant() : null;
        var text = q["q"].ToString() is { Length: > 0 } t ? "%" + t.Replace("[", "[[]", StringComparison.Ordinal).Replace("%", "[%]", StringComparison.Ordinal) + "%" : null;
        var rows = (await u.Connection.QueryAsync<FacilityRow>(new CommandDefinition(
            FacilitySelect +
            """
             WHERE (@all = 1 OR f.BorrowerCompanyId IN @ids)
               AND (@company IS NULL OR co.PublicId = @company)
               AND (@status IS NULL OR f.LifecycleStatus = @status)
               AND (@text IS NULL OR f.FacilityNo LIKE @text OR f.BankReferenceNo LIKE @text OR f.PlatformRef LIKE @text)
               AND (@institution IS NULL OR EXISTS (SELECT 1 FROM fac.FacilityLender AS l JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId
                                                    WHERE l.FacilityId = f.FacilityId AND i.PublicId = @institution AND l.ToRevision IS NULL))
             ORDER BY f.FacilityNo DESC;
            """, new { all = scope.All, ids = scope.SqlIds, company, status, text, institution }, cancellationToken: ct))).ToList();
        var lenders = await LendersAtAsync(u, null, rows.Select(r => (r.FacilityId, r.ApprovedRevisionNo == 0 ? int.MaxValue : r.ApprovedRevisionNo)).ToList(), ct);
        var settings = await FacilityValidity.ExpiringDaysAsync(u.Connection, null, ct);
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var validity = q["validity"].ToString() is { Length: > 0 } v ? v.ToUpperInvariant() : null;
        var items = rows.Select(f => new
        {
            id = f.PublicId, facilityNo = f.FacilityNo, platformRef = f.PlatformRef, facilityClass = f.FacilityClass,
            borrower = new { id = f.BorrowerId, nameAr = f.BorrowerNameAr, nameEn = f.BorrowerNameEn },
            type = f.FacilityTypeCode, currency = f.CurrencyCode, totalAmount = f.TotalAmount, status = f.LifecycleStatus,
            validity = FacilityValidity.Indicator(f.LifecycleStatus, f.EffectiveFrom, f.ExpiryDate, today, settings),
            effectiveFrom = D(f.EffectiveFrom), expiryDate = D(f.ExpiryDate), bankReferenceNo = f.BankReferenceNo, approvedRevision = f.ApprovedRevisionNo,
            lenders = lenders.GetValueOrDefault(f.FacilityId, []).Select(l => new { code = l.Code, nameAr = l.NameAr, nameEn = l.NameEn, roles = l.Roles, sharePct = l.SharePct }),
        }).Where(x => validity is null || x.validity == validity);
        return Results.Ok(new { items });
    }

    internal sealed class LenderRow
    {
        public long FacilityLenderId { get; init; }
        public long RootId { get; init; }
        public long FacilityId { get; init; }
        public long InstitutionId { get; init; }
        public Guid InstitutionPublicId { get; init; }
        public string Code { get; init; } = "";
        public string? NameAr { get; init; }
        public string? NameEn { get; init; }
        public string Roles { get; init; } = "";
        public decimal SharePct { get; init; }
        public int FromRevision { get; init; }
        public int? ToRevision { get; init; }
        public long? SupersedesId { get; init; }
    }

    private const string LenderSelect =
        """
        SELECT l.FacilityLenderId, l.RootId, l.FacilityId, l.InstitutionId, i.PublicId AS InstitutionPublicId, i.Code, i.NameAr, i.NameEn, l.Roles, l.SharePct,
               l.FromRevision, l.ToRevision, l.SupersedesId
          FROM fac.FacilityLender AS l JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId
        """;

    /// <summary>The lenders valid at a revision: FromRevision &lt;= a &lt; ToRevision (BR-FAC-003); int.MaxValue reads the open rows.</summary>
    internal static async Task<Dictionary<long, List<LenderRow>>> LendersAtAsync(BoundUser u, SqlTransaction? tx, IReadOnlyList<(long Facility, int Rev)> at, CancellationToken ct)
    {
        if (at.Count == 0) return [];
        var rows = await u.Connection.QueryAsync<LenderRow>(new CommandDefinition(LenderSelect + " WHERE l.FacilityId IN @ids ORDER BY l.SharePct DESC, i.Code;",
            new { ids = at.Select(a => a.Facility).Distinct().ToArray() }, tx, cancellationToken: ct));
        var rev = at.ToDictionary(a => a.Facility, a => a.Rev);
        return rows.Where(l => ValidAt(l.FromRevision, l.ToRevision, rev[l.FacilityId])).GroupBy(l => l.FacilityId).ToDictionary(g => g.Key, g => g.ToList());
    }

    internal static bool ValidAt(int from, int? to, int a) => a == int.MaxValue ? to is null : from <= a && (to is null || to > a);

    internal sealed class DocRow
    {
        public long FacilityDocumentId { get; init; }
        public long RootId { get; init; }
        public long DocumentId { get; init; }
        public Guid DocumentPublicId { get; init; }
        public string Title { get; init; } = "";
        public string DocumentType { get; init; } = "";
        public DateTime? DocumentDate { get; init; }
        public string? DocumentDateHijri { get; init; }
        public string Language { get; init; } = "";
        public int PrecedenceRank { get; init; }
        public long? AmendsFacilityDocumentId { get; init; }
        public long? AmendsRootId { get; init; }
        public int? PageCount { get; init; }
        public bool IsSignedCopy { get; init; }
        public bool IsScanned { get; init; }
        public int FromRevision { get; init; }
        public int? ToRevision { get; init; }
    }

    private const string DocSelect =
        """
        SELECT fd.FacilityDocumentId, fd.RootId, fd.DocumentId, d.PublicId AS DocumentPublicId, d.Title, dt.Code AS DocumentType, fd.DocumentDate, fd.DocumentDateHijri,
               fd.Language, fd.PrecedenceRank, fd.AmendsFacilityDocumentId, am.RootId AS AmendsRootId, fd.PageCount, fd.IsSignedCopy, fd.IsScanned, fd.FromRevision, fd.ToRevision
          FROM fac.FacilityDocument AS fd
          JOIN doc.Document AS d ON d.DocumentId = fd.DocumentId
          JOIN cat.DocumentType AS dt ON dt.DocumentTypeId = d.DocumentTypeId
          LEFT JOIN fac.FacilityDocument AS am ON am.FacilityDocumentId = fd.AmendsFacilityDocumentId
        """;

    internal static async Task<List<DocRow>> DocumentsAtAsync(BoundUser u, SqlTransaction? tx, long facility, int rev, CancellationToken ct) =>
        [.. (await u.Connection.QueryAsync<DocRow>(new CommandDefinition(DocSelect + " WHERE fd.FacilityId = @f ORDER BY fd.PrecedenceRank;",
            new { f = facility }, tx, cancellationToken: ct))).Where(d => ValidAt(d.FromRevision, d.ToRevision, rev))];

    private static object Lender(LenderRow l, int tenant, OpaqueRefs refs) => new
    {
        id = refs.ItemRef(tenant, "lender", l.RootId), institution = new { id = l.InstitutionPublicId, code = l.Code, nameAr = l.NameAr, nameEn = l.NameEn },
        roles = l.Roles.Split(','), sharePct = l.SharePct, fromRevision = l.FromRevision,
    };

    private static object Document(DocRow d, int tenant, OpaqueRefs refs) => new
    {
        id = refs.ItemRef(tenant, "fac-doc", d.RootId), document = d.DocumentPublicId, title = d.Title, documentType = d.DocumentType, documentDate = D(d.DocumentDate),
        documentDateHijri = d.DocumentDateHijri, language = d.Language, precedenceRank = d.PrecedenceRank,
        amends = d.AmendsRootId is { } a ? refs.ItemRef(tenant, "fac-doc", a) : null, pageCount = d.PageCount, isSignedCopy = d.IsSignedCopy, isScanned = d.IsScanned,
        fromRevision = d.FromRevision,
    };

    private static object HeaderShape(FacilityHeader h) => new
    {
        totalAmount = h.TotalAmount, isSyndicated = h.IsSyndicated, precedenceLanguage = h.PrecedenceLanguage, precedenceClauseRef = h.PrecedenceClauseRef,
        bankReferenceNo = h.BankReferenceNo, bankStructureNo = h.BankStructureNo, agreementDate = h.AgreementDate, agreementDateHijri = h.AgreementDateHijri,
        effectiveFrom = h.EffectiveFrom, effectiveFromHijri = h.EffectiveFromHijri, expiryDate = h.ExpiryDate, expiryDateHijri = h.ExpiryDateHijri,
        operativeCalendar = h.OperativeCalendar, hijriAdjusted = h.HijriAdjusted, hijriAdjustReason = h.HijriAdjustReason,
        bankUnilateralRights = h.BankUnilateralRights?.Split(',') ?? [], noticeDays = h.NoticeDays, usageBlockOnBreach = h.UsageBlockOnBreach,
        usageBlockOnUnconfirmed = h.UsageBlockOnUnconfirmed,
        alertLeadDays = h.AlertLeadDays?.Split(',').Select(x => int.Parse(x, CultureInfo.InvariantCulture)).ToArray() ?? [],
    };

    /// <summary>
    /// The facility card (SCR-FAC-02): the approved header, lenders and documents, the derived validity (BR-FAC-005),
    /// its revisions, and the open draft as it stands (header, lenders, documents) for those who edit it.
    /// </summary>
    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var (u, scope) = await OpenAsync(http, db, View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var f = await FindAsync(u, null, id, scope, ct);
        var revisions = await FacilityRevisionEndpoints.RevisionsAsync(u, null, f.FacilityId, ct);
        var open = revisions.FirstOrDefault(r => r.Status is "DRAFT" or "SUBMITTED" or "REJECTED");
        var approved = f.ApprovedRevisionNo;
        var lenders = approved == 0 ? [] : (await LendersAtAsync(u, null, [(f.FacilityId, approved)], ct)).GetValueOrDefault(f.FacilityId, []);
        var docs = approved == 0 ? [] : await DocumentsAtAsync(u, null, f.FacilityId, approved, ct);
        object? draft = null;
        if (open is not null)
        {
            var dl = (await LendersAtAsync(u, null, [(f.FacilityId, int.MaxValue)], ct)).GetValueOrDefault(f.FacilityId, []);
            var dd = await DocumentsAtAsync(u, null, f.FacilityId, int.MaxValue, ct);
            draft = new
            {
                revision = refs.ItemRef(u.TenantId, "revision", open.FacilityRevisionId), revisionNo = open.RevisionNo, header = HeaderShape(open.Header(f)),
                lenders = dl.Select(l => Lender(l, u.TenantId, refs)), documents = dd.Select(d => Document(d, u.TenantId, refs)),
            };
        }
        var settings = await FacilityValidity.ExpiringDaysAsync(u.Connection, null, ct);
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var successor = await u.Connection.QuerySingleOrDefaultAsync<(Guid Id, string No, string Status)?>(new CommandDefinition(
            "SELECT PublicId, FacilityNo, LifecycleStatus FROM fac.Facility WHERE PreviousFacilityId = @f;", new { f = f.FacilityId }, cancellationToken: ct));
        ETags.Set(http.Response, f.RowVersion);
        return Results.Ok(new
        {
            id = f.PublicId, facilityNo = f.FacilityNo, platformRef = f.PlatformRef, facilityClass = f.FacilityClass,
            referenceParts = f.PlatformRef is null ? await ReferencePartsAsync(u, f, ct) : null,
            borrower = new { id = f.BorrowerId, nameAr = f.BorrowerNameAr, nameEn = f.BorrowerNameEn },
            type = f.FacilityTypeCode, currency = f.CurrencyCode, status = f.LifecycleStatus, statusReason = f.LifecycleReason,
            validity = FacilityValidity.Indicator(f.LifecycleStatus, f.EffectiveFrom, f.ExpiryDate, today, settings),
            daysToExpiry = (f.ExpiryDate - today).Days, approvedRevision = approved, header = HeaderShape(f.Header()),
            previous = f.PreviousId, successor = successor is { } s ? new { id = s.Id, facilityNo = s.No, status = s.Status } : null,
            lenders = lenders.Select(l => Lender(l, u.TenantId, refs)), documents = docs.Select(d => Document(d, u.TenantId, refs)),
            revisions = revisions.Select(r => FacilityRevisionEndpoints.Shape(r, u.TenantId, refs)), draft,
            permissions = new
            {
                edit = (await u.PermissionsAsync(ct)).Contains(Edit), approve = (await u.PermissionsAsync(ct)).Contains("fac.approve"),
                lifecycle = (await u.PermissionsAsync(ct)).Contains("fac.lifecycle.manage"), suspend = (await u.PermissionsAsync(ct)).Contains("fac.lifecycle.suspend"),
            },
        });
    }

    /// <summary>Before its reference is written: the parts it will take and what is still missing (BR-FAC-021).</summary>
    private static async Task<object> ReferencePartsAsync(BoundUser u, FacilityRow f, CancellationToken ct)
    {
        var p = await FacilityRefs.PartsAsync(u.Connection, null, f.FacilityId, ct);
        return new
        {
            company = p.Company, bank = p.Bank, facilityClass = p.Class, stem = p.Stem,
            preview = p.Stem is null ? null : BankFas.Core.Facilities.FacilityReference.Compose(p.Stem, f.EffectiveFrom.Year), missing = FacilityRefs.Missing(p).ToArray(),
        };
    }

    /// <summary>The renewal chain (FR-FAC-005, BR-FAC-006): every predecessor and successor, oldest first.</summary>
    private static async Task<IResult> ChainAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await OpenAsync(http, db, View);
        await using var _ = u;
        var f = await FindAsync(u, null, id, scope, http.RequestAborted);
        var chain = await u.Connection.QueryAsync<(Guid Id, string No, string Status, DateTime From, DateTime To, int Depth)>(new CommandDefinition(
            """
            WITH up AS (SELECT FacilityId, PreviousFacilityId, 0 AS Depth FROM fac.Facility WHERE FacilityId = @f
                        UNION ALL SELECT p.FacilityId, p.PreviousFacilityId, up.Depth - 1 FROM fac.Facility AS p JOIN up ON p.FacilityId = up.PreviousFacilityId),
                 down AS (SELECT FacilityId, 0 AS Depth FROM fac.Facility WHERE FacilityId = @f
                          UNION ALL SELECT n.FacilityId, down.Depth + 1 FROM fac.Facility AS n JOIN down ON n.PreviousFacilityId = down.FacilityId)
            SELECT x.PublicId, ISNULL(x.PlatformRef, x.FacilityNo) AS FacilityNo, x.LifecycleStatus, x.EffectiveFrom, x.ExpiryDate, c.Depth
              FROM (SELECT FacilityId, Depth FROM up UNION SELECT FacilityId, Depth FROM down) AS c JOIN fac.Facility AS x ON x.FacilityId = c.FacilityId
             ORDER BY c.Depth OPTION (MAXRECURSION 50);
            """, new { f = f.FacilityId }, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = chain.Select(c => new { id = c.Id, facilityNo = c.No, status = c.Status, effectiveFrom = D(c.From), expiryDate = D(c.To), current = c.Depth == 0 }),
        });
    }

    // ---------- lenders (FR-FAC-003, V-FAC-02) ----------

    private static readonly string[] LenderRoles = ["SOLE", "LEAD", "AGENT", "ARRANGER", "PARTICIPANT"];

    private static string RolesOf(string[]? roles)
    {
        var set = (roles ?? []).Select(r => r.Trim().ToUpperInvariant()).Distinct(StringComparer.Ordinal).ToArray();
        if (set.Length == 0 || set.Any(r => !LenderRoles.Contains(r, StringComparer.Ordinal)))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "A lender has one or more roles among SOLE, LEAD, AGENT, ARRANGER and PARTICIPANT.");
        return string.Join(',', LenderRoles.Where(set.Contains));
    }

    private static void CheckShare(string roles, decimal share)
    {
        if (share is <= 0 or > 100) throw ApiProblemException.Invalid("V-FAC-02", "A lender's share is above 0 and at most 100 percent.");
        if (roles.Contains("SOLE", StringComparison.Ordinal) && share != 100) throw ApiProblemException.Invalid("V-FAC-02", "A sole lender holds 100 percent.");
    }

    private static async Task<IResult> AddLenderAsync(Guid id, LenderRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Institution is null || b.SharePct is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the bank and its share.");
        var roles = RolesOf(b.Roles);
        CheckShare(roles, b.SharePct.Value);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        var rev = await FacilityRevisionEndpoints.DraftAsync(u, tx, f, ct);
        var institution = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT InstitutionId FROM ins.Institution WHERE PublicId = @i AND Status = 'ACTIVE';", new { i = b.Institution }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank is not an active institution.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM fac.FacilityLender WHERE FacilityId = @f AND InstitutionId = @i AND ToRevision IS NULL;", new { f = f.FacilityId, i = institution }, tx,
                cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-FAC-LENDER-EXISTS", "This bank is already a lender of the facility; change its share.");
        var root = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (RootId BIGINT);
            INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, FromRevision, CreatedBy) OUTPUT inserted.RootId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @i, @roles, @share, @r, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT RootId FROM @o;
            """, new { f = f.FacilityId, i = institution, roles, share = b.SharePct, r = rev.RevisionNo }, tx, cancellationToken: ct));
        await FacilityRevisionEndpoints.EditedAsync(u, tx, f, rev, "LENDER_ADDED", JsonSerializer.Serialize(new { institution = b.Institution, roles, share = b.SharePct }), ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/lenders", new { id = refs.ItemRef(u.TenantId, "lender", root) });
    }

    private static async Task<IResult> ChangeLenderAsync(Guid id, string reference, LenderRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Institution is not null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank of a lender does not change; remove it and add the other bank.");
        var root = refs.ItemId(u.TenantId, "lender", reference) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        var rev = await FacilityRevisionEndpoints.DraftAsync(u, tx, f, ct);
        var row = await u.Connection.QuerySingleOrDefaultAsync<LenderRow>(new CommandDefinition(
            LenderSelect + " WHERE l.FacilityId = @f AND l.RootId = @root AND l.ToRevision IS NULL;", new { f = f.FacilityId, root }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        var roles = b.Roles is null ? row.Roles : RolesOf(b.Roles);
        var share = b.SharePct ?? row.SharePct;
        CheckShare(roles, share);
        if (row.FromRevision == rev.RevisionNo)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE fac.FacilityLender SET Roles = @roles, SharePct = @share, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE FacilityLenderId = @id;",
                new { roles, share, id = row.FacilityLenderId }, tx, cancellationToken: ct));
        else
        {
            // An approved row is closed at this revision before its successor opens (one open row per root, 003).
            await CloseAsync(u, tx, "fac.FacilityLender", "FacilityLenderId", row.FacilityLenderId, rev.RevisionNo, ct);
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, ContactId, FromRevision, SupersedesId, InheritedRootId, CreatedBy)
                SELECT TenantId, FacilityId, InstitutionId, @roles, @share, ContactId, @r, FacilityLenderId, RootId, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                  FROM fac.FacilityLender WHERE FacilityLenderId = @id;
                """, new { roles, share, r = rev.RevisionNo, id = row.FacilityLenderId }, tx, cancellationToken: ct));
        }
        await FacilityRevisionEndpoints.EditedAsync(u, tx, f, rev, "LENDER_CHANGED", JsonSerializer.Serialize(new { before = new { row.Roles, row.SharePct }, after = new { roles, share } }), ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    internal static Task CloseAsync(BoundUser u, SqlTransaction tx, string table, string pk, long id, int revision, CancellationToken ct) =>
        u.Connection.ExecuteAsync(new CommandDefinition(
            $"UPDATE {table} SET ToRevision = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE {pk} = @id;",
            new { r = revision, id }, tx, cancellationToken: ct));

    /// <summary>
    /// A row written in this draft is voided (ToRevision = FromRevision: valid at no revision; tp_app deletes nothing
    /// here, 005); an approved row is closed at this revision (it stays in the history of the earlier ones).
    /// </summary>
    private static Task RemoveRowAsync(BoundUser u, SqlTransaction tx, string table, string pk, long id, int from, int revision, CancellationToken ct) =>
        CloseAsync(u, tx, table, pk, id, from == revision ? from : revision, ct);

    private static async Task<IResult> RemoveLenderAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        var root = refs.ItemId(u.TenantId, "lender", reference) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        var rev = await FacilityRevisionEndpoints.DraftAsync(u, tx, f, ct);
        var row = await u.Connection.QuerySingleOrDefaultAsync<LenderRow>(new CommandDefinition(
            LenderSelect + " WHERE l.FacilityId = @f AND l.RootId = @root AND l.ToRevision IS NULL;", new { f = f.FacilityId, root }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        await RemoveRowAsync(u, tx, "fac.FacilityLender", "FacilityLenderId", row.FacilityLenderId, row.FromRevision, rev.RevisionNo, ct);
        await FacilityRevisionEndpoints.EditedAsync(u, tx, f, rev, "LENDER_REMOVED", JsonSerializer.Serialize(new { institution = row.InstitutionPublicId }), ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- documents (FR-FAC-004) ----------

    private static async Task<IResult> AddDocumentAsync(Guid id, FacilityDocumentRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Document is null || b.PrecedenceRank is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the document and its rank of precedence.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        var rev = await FacilityRevisionEndpoints.DraftAsync(u, tx, f, ct);
        var doc = await u.Connection.QuerySingleOrDefaultAsync<(long Id, string AppliesTo)?>(new CommandDefinition(
            """
            SELECT d.DocumentId, ISNULL(dt.AppliesTo, '') FROM doc.Document AS d JOIN cat.DocumentType AS dt ON dt.DocumentTypeId = d.DocumentTypeId
             WHERE d.PublicId = @d AND d.Status = 'ACTIVE' AND (d.OwnerCompanyId IS NULL OR d.OwnerCompanyId = @c);
            """, new { d = b.Document, c = f.BorrowerCompanyId }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is not an active document of the borrower.");
        if (!doc.AppliesTo.Split(',').Contains("FACILITY", StringComparer.Ordinal))
            throw ApiProblemException.Invalid("V-FAC-DOC-TYPE", "This document type is not a facility document.");
        var current = await DocumentsAtAsync(u, tx, f.FacilityId, int.MaxValue, ct);
        if (current.Any(d => d.DocumentId == doc.Id)) throw new ApiProblemException(409, "V-FAC-DOC-EXISTS", "This document is already in the facility.");
        var fields = await DocumentFieldsAsync(b, null, current, u, refs, ct);
        var root = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (RootId BIGINT);
            INSERT fac.FacilityDocument (TenantId, FacilityId, DocumentId, DocumentDate, DocumentDateHijri, Language, PrecedenceRank, AmendsFacilityDocumentId, PageCount,
                                         IsSignedCopy, IsScanned, FromRevision, CreatedBy)
            OUTPUT inserted.RootId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @doc, @date, @hijri, @lang, @rank, @amends, @pages, @signed, @scanned, @r, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT RootId FROM @o;
            """, new
            {
                f = f.FacilityId, doc = doc.Id, fields.date, fields.hijri, fields.lang, fields.rank, fields.amends, fields.pages, fields.signed, fields.scanned, r = rev.RevisionNo,
            }, tx, cancellationToken: ct));
        await FacilityRevisionEndpoints.EditedAsync(u, tx, f, rev, "DOCUMENT_ADDED", JsonSerializer.Serialize(new { document = b.Document, fields.rank }), ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/documents", new { id = refs.ItemRef(u.TenantId, "fac-doc", root) });
    }

    private static Task<(string? date, string? hijri, string lang, int rank, long? amends, int? pages, bool signed, bool scanned)> DocumentFieldsAsync(FacilityDocumentRequest b,
        DocRow? was, List<DocRow> current, BoundUser u, OpaqueRefs refs, CancellationToken ct)
    {
        _ = ct;
        var (date, hijri, _) = b.DocumentDate is null && b.DocumentDateHijri is null ? (D(was?.DocumentDate), was?.DocumentDateHijri, false) : DatePair(b.DocumentDate, b.DocumentDateHijri, "document date");
        var lang = b.Language?.Trim().ToUpperInvariant() ?? was?.Language ?? "AR";
        if (lang is not ("AR" or "EN" or "BILINGUAL")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The language is AR, EN or BILINGUAL.");
        var rank = b.PrecedenceRank ?? was!.PrecedenceRank;
        if (rank < 1) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The rank of precedence is 1 or more.");
        if (current.Any(d => d.PrecedenceRank == rank && d.RootId != was?.RootId))
            throw new ApiProblemException(409, "V-FAC-DOC-RANK", "Another document of the facility has this rank of precedence.");
        long? amends = was?.AmendsFacilityDocumentId;
        if (b.Amends is not null)
        {
            if (b.Amends.Length == 0) amends = null;
            else
            {
                var target = refs.ItemId(u.TenantId, "fac-doc", b.Amends);
                amends = current.FirstOrDefault(d => d.RootId == target && d.RootId != was?.RootId)?.FacilityDocumentId
                    ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The amended document is another document of this facility.");
            }
        }
        if (b.PageCount is <= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The number of pages is above zero.");
        return Task.FromResult((date, hijri, lang, rank, amends, b.PageCount ?? was?.PageCount, b.IsSignedCopy ?? was?.IsSignedCopy ?? false, b.IsScanned ?? was?.IsScanned ?? false));
    }

    private static async Task<IResult> ChangeDocumentAsync(Guid id, string reference, FacilityDocumentRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Document is not null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document of a row does not change; remove it and add the other document.");
        var root = refs.ItemId(u.TenantId, "fac-doc", reference) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        var rev = await FacilityRevisionEndpoints.DraftAsync(u, tx, f, ct);
        var current = await DocumentsAtAsync(u, tx, f.FacilityId, int.MaxValue, ct);
        var row = current.FirstOrDefault(d => d.RootId == root) ?? throw ApiProblemException.NotFound();
        var x = await DocumentFieldsAsync(b, row, current, u, refs, ct);
        var p = new { x.date, x.hijri, x.lang, x.rank, x.amends, x.pages, x.signed, x.scanned, id = row.FacilityDocumentId, r = rev.RevisionNo };
        if (row.FromRevision == rev.RevisionNo)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE fac.FacilityDocument SET DocumentDate = @date, DocumentDateHijri = @hijri, Language = @lang, PrecedenceRank = @rank, AmendsFacilityDocumentId = @amends,
                       PageCount = @pages, IsSignedCopy = @signed, IsScanned = @scanned, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE FacilityDocumentId = @id;
                """, p, tx, cancellationToken: ct));
        else
        {
            await CloseAsync(u, tx, "fac.FacilityDocument", "FacilityDocumentId", row.FacilityDocumentId, rev.RevisionNo, ct);
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT fac.FacilityDocument (TenantId, FacilityId, DocumentId, DocumentDate, DocumentDateHijri, Language, PrecedenceRank, AmendsFacilityDocumentId, PageCount,
                                             IsSignedCopy, IsScanned, FromRevision, SupersedesId, InheritedRootId, CreatedBy)
                SELECT TenantId, FacilityId, DocumentId, @date, @hijri, @lang, @rank, @amends, @pages, @signed, @scanned, @r, FacilityDocumentId, RootId,
                       CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                  FROM fac.FacilityDocument WHERE FacilityDocumentId = @id;
                """, p, tx, cancellationToken: ct));
        }
        // Re-ordering is audited (FR-FAC-004).
        await FacilityRevisionEndpoints.EditedAsync(u, tx, f, rev, "DOCUMENT_CHANGED",
            JsonSerializer.Serialize(new { document = row.DocumentPublicId, before = new { row.PrecedenceRank, row.Language }, after = new { x.rank, x.lang } }), ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> RemoveDocumentAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        var root = refs.ItemId(u.TenantId, "fac-doc", reference) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        var rev = await FacilityRevisionEndpoints.DraftAsync(u, tx, f, ct);
        var current = await DocumentsAtAsync(u, tx, f.FacilityId, int.MaxValue, ct);
        var row = current.FirstOrDefault(d => d.RootId == root) ?? throw ApiProblemException.NotFound();
        if (current.Any(d => d.AmendsRootId == root)) throw new ApiProblemException(409, "V-FAC-DOC-AMENDED", "Another document of the facility amends this one; change that one first.");
        await RemoveRowAsync(u, tx, "fac.FacilityDocument", "FacilityDocumentId", row.FacilityDocumentId, row.FromRevision, rev.RevisionNo, ct);
        await FacilityRevisionEndpoints.EditedAsync(u, tx, f, rev, "DOCUMENT_REMOVED", JsonSerializer.Serialize(new { document = row.DocumentPublicId }), ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- accounts (FR-FAC-022, BR-ACC-007, SVC-FAC-07) ----------

    private sealed class AccountRow
    {
        public long FacilityAccountId { get; init; }
        public Guid Account { get; init; }
        public string? Nickname { get; init; }
        public string AccountNoMask { get; init; } = "";
        public string Currency { get; init; } = "";
        public string Purpose { get; init; } = "";
        public string? PurposeAr { get; init; }
        public string? PurposeEn { get; init; }
        public bool IsDefault { get; init; }
        public DateTime? ValidFrom { get; init; }
        public DateTime? ValidTo { get; init; }
        public string? Notes { get; init; }
        public string AccountStatus { get; init; } = "";
        public string InstitutionCode { get; init; } = "";
    }

    private static async Task<IResult> AccountsAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var (u, scope) = await OpenAsync(http, db, View);
        await using var _ = u;
        var f = await FindAsync(u, null, id, scope, http.RequestAborted);
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var rows = await u.Connection.QueryAsync<AccountRow>(new CommandDefinition(
            """
            SELECT fa.FacilityAccountId, a.PublicId AS Account, a.Nickname, a.AccountNoMask, cu.Code AS Currency, li.Code AS Purpose, li.NameAr AS PurposeAr, li.NameEn AS PurposeEn,
                   fa.IsDefault, fa.ValidFrom, fa.ValidTo, fa.Notes, a.Status AS AccountStatus, i.Code AS InstitutionCode
              FROM acc.FacilityAccount AS fa
              JOIN acc.BankAccount AS a ON a.BankAccountId = fa.BankAccountId
              JOIN ins.Institution AS i ON i.InstitutionId = a.InstitutionId
              JOIN ref.Currency AS cu ON cu.CurrencyId = fa.CurrencyId
              JOIN cat.LookupItem AS li ON li.LookupItemId = fa.PurposeId
             WHERE fa.FacilityId = @f ORDER BY li.SortOrder, fa.IsDefault DESC;
            """, new { f = f.FacilityId }, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = rows.Select(a => new
            {
                id = refs.ItemRef(u.TenantId, "fac-account", a.FacilityAccountId), account = a.Account, nickname = a.Nickname, accountNoMask = a.AccountNoMask,
                currency = a.Currency, purpose = a.Purpose, purposeAr = a.PurposeAr, purposeEn = a.PurposeEn, isDefault = a.IsDefault, validFrom = D(a.ValidFrom),
                validTo = D(a.ValidTo), notes = a.Notes, accountStatus = a.AccountStatus, institution = a.InstitutionCode,
                open = a.ValidTo is null || a.ValidTo >= today,
            }),
        });
    }

    /// <summary>
    /// A facility account (FR-FAC-022): an active account of the borrower, in its own currency, for a purpose; one
    /// default per purpose and currency while open (BR-ACC-007). Its bank is a lender of the approved facility; in a
    /// syndicated facility another bank is a warning (11m:224).
    /// </summary>
    private static async Task<IResult> AddAccountAsync(Guid id, FacilityAccountRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Account is null || string.IsNullOrWhiteSpace(b.Purpose)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the account and its purpose.");
        var (from, _, _) = DatePair(b.ValidFrom, null, "start date");
        var (to, _, _) = DatePair(b.ValidTo, null, "end date");
        if (from is not null && to is not null && string.CompareOrdinal(to, from) < 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The link ends on or after its start.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var f = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (f.LifecycleStatus is "EXPIRED" or "TERMINATED" or "SUPERSEDED") throw new ApiProblemException(409, "V-FAC-ENDED", "The facility has ended.");
        var account = await u.Connection.QuerySingleOrDefaultAsync<(long Id, int Currency, long Institution, string Status)?>(new CommandDefinition(
            "SELECT BankAccountId, CurrencyId, InstitutionId, Status FROM acc.BankAccount WHERE PublicId = @a AND CompanyId = @c;",
            new { a = b.Account, c = f.BorrowerCompanyId }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The account is not an account of the borrower.");
        if (account.Status != "ACTIVE") throw ApiProblemException.Invalid("V-FAC-ACCOUNT", "A frozen, dormant or closed account is not linked to a facility.");
        var purpose = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition(
            """
            SELECT li.LookupItemId FROM cat.LookupItem AS li JOIN cat.LookupList AS ll ON ll.LookupListId = li.LookupListId
             WHERE ll.Code = 'ACCOUNT_PURPOSE' AND li.Code = @p AND li.Status = 'ACTIVE';
            """, new { p = b.Purpose.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The purpose is one of the account purposes of the catalogue.");
        var lenders = (await LendersAtAsync(u, tx, [(f.FacilityId, f.ApprovedRevisionNo == 0 ? int.MaxValue : f.ApprovedRevisionNo)], ct)).GetValueOrDefault(f.FacilityId, []);
        var warnings = new List<string>();
        if (lenders.All(l => l.InstitutionId != account.Institution))
        {
            if (!f.IsSyndicated) throw ApiProblemException.Invalid("V-FAC-ACCOUNT", "The account is held at a bank that is not the lender of the facility.");
            warnings.Add("V-FAC-ACCOUNT-BANK");
        }
        var today = D(clock.GetUtcNow().UtcDateTime.Date)!;
        if (b.IsDefault == true)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE acc.FacilityAccount SET IsDefault = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE FacilityId = @f AND PurposeId = @p AND CurrencyId = @c AND IsDefault = 1 AND (ValidTo IS NULL OR ValidTo >= @today);
                """, new { f = f.FacilityId, p = purpose, c = account.Currency, today }, tx, cancellationToken: ct));
        long faId;
        try
        {
            faId = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT acc.FacilityAccount (TenantId, FacilityId, BankAccountId, CurrencyId, PurposeId, IsDefault, ValidFrom, ValidTo, Notes, CreatedBy)
                OUTPUT inserted.FacilityAccountId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @a, @c, @p, @def, @from, @to, @notes, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new { f = f.FacilityId, a = account.Id, c = account.Currency, p = purpose, def = b.IsDefault ?? false, from, to, notes = b.Notes?.Trim() },
                tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            throw new ApiProblemException(409, "V-FAC-ACCOUNT-EXISTS", "This account is already linked to the facility for this purpose.");
        }
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FACILITY_ACCOUNT_LINKED", "TREASURY", "acc.FacilityAccount", faId,
            AfterJson: JsonSerializer.Serialize(new { facility = f.PublicId, account = b.Account, purpose = b.Purpose, isDefault = b.IsDefault ?? false })), f.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/accounts", new { id = refs.ItemRef(u.TenantId, "fac-account", faId), warnings });
    }

    /// <summary>A link ends on a date (today by default); it stays in the history.</summary>
    private static async Task<IResult> EndAccountAsync(Guid id, string reference, FacilityAccountRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        var faId = refs.ItemId(u.TenantId, "fac-account", reference) ?? throw ApiProblemException.NotFound();
        var (to, _, _) = DatePair(b.ValidTo ?? D(clock.GetUtcNow().UtcDateTime.Date), null, "end date");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FindAsync(u, tx, id, scope, ct);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE acc.FacilityAccount SET ValidTo = @to, IsDefault = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE FacilityAccountId = @id AND FacilityId = @f AND (ValidFrom IS NULL OR ValidFrom <= @to);
            """, new { to, id = faId, f = f.FacilityId }, tx, cancellationToken: ct));
        if (n == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The link ends on or after its start.");
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FACILITY_ACCOUNT_ENDED", "TREASURY", "acc.FacilityAccount", faId,
            AfterJson: JsonSerializer.Serialize(new { validTo = to })), f.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- lifecycle (spec 12 section 8; DQ-F14-1, DQ-F14-2) ----------

    /// <summary>
    /// ACTIVE and SUSPENDED move between each other by a treasury manager (fac.lifecycle.suspend); an ACTIVE or
    /// SUSPENDED facility is ended (EXPIRED or TERMINATED) with fac.lifecycle.manage, which also resolves
    /// NOT_CONFIRMED. Each takes a reason. EXPIRED returns to ACTIVE only through an approved EXTENSION; SUPERSEDED
    /// comes only from the renewal (JOB-FAC-VALIDITY).
    /// </summary>
    private static async Task<IResult> LifecycleAsync(Guid id, LifecycleRequest b, string action, HttpContext http, SqlConnectionFactory db)
    {
        if (string.IsNullOrWhiteSpace(b.Reason) || b.Reason.Length > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason.");
        var permission = action is "SUSPEND" or "RESUME" ? "fac.lifecycle.suspend" : "fac.lifecycle.manage";
        var (u, scope) = await OpenAsync(http, db, permission);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        var (from, to) = action switch
        {
            "SUSPEND" => (new[] { "ACTIVE" }, "SUSPENDED"),
            "RESUME" => (["SUSPENDED"], "ACTIVE"),
            "EXPIRE" => (["ACTIVE", "SUSPENDED"], "EXPIRED"),
            _ => (["ACTIVE", "SUSPENDED"], "TERMINATED"),
        };
        if (!from.Contains(f.LifecycleStatus))
            throw new ApiProblemException(409, "V-FAC-LIFECYCLE", $"A {f.LifecycleStatus.ToLowerInvariant()} facility cannot be {to.ToLowerInvariant()} this way.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fac.Facility SET LifecycleStatus = @to, LifecycleReason = @reason, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE FacilityId = @f;
            """, new { to, reason = to == "ACTIVE" ? null : b.Reason.Trim(), f = f.FacilityId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FACILITY_" + to, "TREASURY", "fac.Facility", f.FacilityId,
            BeforeJson: JsonSerializer.Serialize(new { status = f.LifecycleStatus }), AfterJson: JsonSerializer.Serialize(new { status = to, reason = b.Reason.Trim() })),
            f.BorrowerCompanyId, ct);
        await BankFas.Data.Outbox.EmitAsync(u.Connection, tx, "facility.validity.changed", "fac.Facility", f.FacilityId,
            new { facility = f.PublicId, status = to }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>
    /// The renewal (FR-FAC-005): a successor facility, a draft with its own number, that copies the predecessor's
    /// approved header, lenders and documents into its first revision (RENEWAL_COPY). The chain is linear: one
    /// successor per facility (UQ on PreviousFacilityId). The predecessor stays valid until the successor's start,
    /// when it becomes SUPERSEDED (JOB-FAC-VALIDITY; OQ-15).
    /// </summary>
    private static async Task<IResult> RenewAsync(Guid id, RenewRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await OpenAsync(http, db, Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var f = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (f.ApprovedRevisionNo == 0 || f.LifecycleStatus is "TERMINATED" or "SUPERSEDED")
            throw new ApiProblemException(409, "V-FAC-RENEW", "Only an approved facility that has not ended or been replaced is renewed.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM fac.Facility WHERE PreviousFacilityId = @f;",
                new { f = f.FacilityId }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-FAC-RENEW", "This facility already has a successor (BR-FAC-006).");
        var was = f.Header();
        var start = b.EffectiveFrom ?? D(f.ExpiryDate.AddDays(1));
        var expiry = b.ExpiryDate ?? D(DateTime.ParseExact(start!, "yyyy-MM-dd", CultureInfo.InvariantCulture).AddYears(1).AddDays(-1));
        var header = Merge(was with { AgreementDate = null, AgreementDateHijri = null, HijriAdjusted = false, HijriAdjustReason = null }, new FacilityRequest(
            null, null, null, b.TotalAmount, null, null, null, b.BankReferenceNo, null, null, null, start, null, expiry, null, null, null, null, null, null, null, null, null, null));
        var (no, issue) = await AllocateAsync(u, tx, ct);
        var next = await InsertFacilityAsync(u, tx, no, f.BorrowerCompanyId, f.FacilityTypeId, f.CurrencyId, header, f.FacilityId, ct, f.FacilityClassId);
        await u.Connection.ExecuteAsync(new CommandDefinition("UPDATE cfg.NumberIssue SET EntityType = 'fac.Facility', EntityId = @f WHERE NumberIssueId = @i;",
            new { f = next.FacilityId, i = issue }, tx, cancellationToken: ct));
        var rev = await FacilityRevisionEndpoints.InsertRevisionAsync(u, tx, next.FacilityId, 1, "RENEWAL_COPY", header.EffectiveFrom, $"Renewal of {f.FacilityNo}", null, ct);
        await CopyApprovedAsync(u, tx, f.FacilityId, f.ApprovedRevisionNo, next.FacilityId, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FACILITY_RENEWED", "TREASURY", "fac.Facility", next.FacilityId,
            AfterJson: JsonSerializer.Serialize(new { predecessor = f.PublicId, facilityNo = no, revision = rev })), f.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{next.PublicId}", new { id = next.PublicId, facilityNo = no });
    }

    /// <summary>The rows valid at the approved revision of one facility, as new roots of revision 1 of another (a renewal copy).</summary>
    private static async Task CopyApprovedAsync(BoundUser u, SqlTransaction tx, long from, int rev, long to, CancellationToken ct)
    {
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT fac.FacilityLender (TenantId, FacilityId, InstitutionId, Roles, SharePct, ContactId, FromRevision, CreatedBy)
            SELECT TenantId, @to, InstitutionId, Roles, SharePct, ContactId, 1, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
              FROM fac.FacilityLender WHERE FacilityId = @from AND FromRevision <= @rev AND (ToRevision IS NULL OR ToRevision > @rev);
            """, new { from, to, rev }, tx, cancellationToken: ct));
        // The limit tree: new roots in the successor, the parents and the rows they belong to found by code (the key of the transfer, BR-FAC-006).
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            DECLARE @me BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), @n INT = 1;
            WHILE @n > 0
            BEGIN
                INSERT fac.Limit (TenantId, FacilityId, ParentLimitId, LimitTypeId, Code, NameAr, NameEn, BankStructureNo, AmountBasis, Amount, PctOfParent, EffectiveAmount,
                                  DistributionMode, IsRevolving, IsCommitted, StartDate, EndDate, DueDate, PricingMode, CompanyAllocationMode, FromRevision, SourceDocumentId,
                                  SourcePage, ReadFromScan, OriginalText, NoSourceReason, Confidence, CreatedBy)
                SELECT o.TenantId, @to, np.LimitId, o.LimitTypeId, o.Code, o.NameAr, o.NameEn, o.BankStructureNo, o.AmountBasis, o.Amount, o.PctOfParent, o.EffectiveAmount,
                       o.DistributionMode, o.IsRevolving, o.IsCommitted, NULL, NULL, NULL, o.PricingMode, o.CompanyAllocationMode, 1, o.SourceDocumentId, o.SourcePage,
                       o.ReadFromScan, o.OriginalText, ISNULL(o.NoSourceReason, N'Copied from the renewed facility'), o.Confidence, @me
                  FROM fac.Limit AS o
                  LEFT JOIN fac.Limit AS op ON op.LimitId = o.ParentLimitId
                  LEFT JOIN fac.Limit AS np ON np.FacilityId = @to AND np.Code = op.Code
                 WHERE o.FacilityId = @from AND o.FromRevision <= @rev AND (o.ToRevision IS NULL OR o.ToRevision > @rev)
                   AND NOT EXISTS (SELECT 1 FROM fac.Limit AS d WHERE d.FacilityId = @to AND d.Code = o.Code)
                   AND (o.ParentLimitId IS NULL OR np.LimitId IS NOT NULL);
                SET @n = @@ROWCOUNT;
            END;
            INSERT fac.LimitProductLine (TenantId, FacilityId, LimitId, ProductId, BankProductCode, AmountBasis, Amount, PctOfParent, IsRevolving, DueDate, IsActive, FromRevision,
                                         SourceDocumentId, SourcePage, ReadFromScan, OriginalText, NoSourceReason, Confidence, CreatedBy)
            SELECT o.TenantId, @to, nl.LimitId, o.ProductId, o.BankProductCode, o.AmountBasis, o.Amount, o.PctOfParent, o.IsRevolving, NULL, o.IsActive, 1, o.SourceDocumentId,
                   o.SourcePage, o.ReadFromScan, o.OriginalText, ISNULL(o.NoSourceReason, N'Copied from the renewed facility'), o.Confidence, @me
              FROM fac.LimitProductLine AS o JOIN fac.Limit AS ol ON ol.LimitId = o.LimitId JOIN fac.Limit AS nl ON nl.FacilityId = @to AND nl.Code = ol.Code
             WHERE o.FacilityId = @from AND o.FromRevision <= @rev AND (o.ToRevision IS NULL OR o.ToRevision > @rev);
            INSERT fac.LimitCompanyRule (TenantId, FacilityId, LimitId, CompanyId, RuleKind, AllocationAmount, AllocationPct, Reason, ValidFrom, ValidTo, FromRevision,
                                         SourceDocumentId, SourcePage, NoSourceReason, Confidence, CreatedBy)
            SELECT o.TenantId, @to, nl.LimitId, o.CompanyId, o.RuleKind, o.AllocationAmount, o.AllocationPct, o.Reason, o.ValidFrom, NULL, 1, o.SourceDocumentId, o.SourcePage,
                   ISNULL(o.NoSourceReason, N'Copied from the renewed facility'), o.Confidence, @me
              FROM fac.LimitCompanyRule AS o JOIN fac.Limit AS ol ON ol.LimitId = o.LimitId JOIN fac.Limit AS nl ON nl.FacilityId = @to AND nl.Code = ol.Code
             WHERE o.FacilityId = @from AND o.FromRevision <= @rev AND (o.ToRevision IS NULL OR o.ToRevision > @rev) AND (o.ValidTo IS NULL OR o.ValidTo >= SYSUTCDATETIME());
            """, new { from, to, rev }, tx, cancellationToken: ct));
        // The documents keep their order; what they amend is left to the user, since an amendment of the old agreement may not apply.
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT fac.FacilityDocument (TenantId, FacilityId, DocumentId, DocumentDate, DocumentDateHijri, Language, PrecedenceRank, PageCount, IsSignedCopy, IsScanned,
                                         FromRevision, CreatedBy)
            SELECT TenantId, @to, DocumentId, DocumentDate, DocumentDateHijri, Language, PrecedenceRank, PageCount, IsSignedCopy, IsScanned, 1,
                   CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
              FROM fac.FacilityDocument WHERE FacilityId = @from AND FromRevision <= @rev AND (ToRevision IS NULL OR ToRevision > @rev);
            """, new { from, to, rev }, tx, cancellationToken: ct));
    }
}

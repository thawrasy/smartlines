using System.Data;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record TariffScheduleRequest(Guid? Institution, Guid? Facility, string? NameAr, string? NameEn, string? EffectiveFrom, Guid? SourceDocument);
public sealed record TariffItemRequest(string? FeeType, string? ItemCode, string? NameAr, string? NameEn, string? Product, string? ChargeKind, decimal? Rate, decimal? FixedAmount,
    decimal? PerMillionAmount, string? PeriodBasis, int? PeriodDays, decimal? MinAmount, decimal? MaxAmount, string? Locality, string? TierCalcMode, string? PerMillionMode,
    string? VatTreatment, string? Currency, Guid? SourceDocument, string? SourcePage, bool? ReadFromScan, string? NoSourceReason);
public sealed record TariffTierRequest(decimal? AmountFrom, decimal? AmountTo, int? PeriodFromDays, int? PeriodToDays, decimal? Rate, decimal? FixedAmount, decimal? MinAmount);

/// <summary>
/// The tariff schedules of a bank, or of one facility (FR-PRC-001 to 004; BR-PRC-001): a version is a draft until a
/// treasury manager other than its preparer approves it (prc.tariff.approve); approving it closes the open approved
/// version of the same bank and facility the day before, which becomes SUPERSEDED. An approved schedule, its items and
/// its tiers do not change (062, 50176); a change is a new version. Two tiers of an item do not overlap (V-PRC-01).
/// </summary>
public static class TariffEndpoints
{
    private const string View = "prc.view";
    private const string Manage = "prc.manage";
    private const string Approve = "prc.tariff.approve";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/tariff-schedules", ListAsync);
        api.MapPost("/tariff-schedules", CreateAsync);
        api.MapGet("/tariff-schedules/{id:guid}", GetAsync);
        api.MapPost("/tariff-schedules/{id:guid}/items", AddItemAsync);
        api.MapPost("/tariff-schedules/{id:guid}/items/{item}/tiers", AddTierAsync);
        api.MapPost("/tariff-schedules/{id:guid}/actions/approve", ApproveAsync);
    }

    private sealed class ScheduleRow
    {
        public long TariffScheduleId { get; init; }
        public Guid PublicId { get; init; }
        public long InstitutionId { get; init; }
        public Guid InstitutionPublicId { get; init; }
        public string InstitutionCode { get; init; } = "";
        public long? FacilityId { get; init; }
        public Guid? FacilityPublicId { get; init; }
        public string? FacilityNo { get; init; }
        public string NameAr { get; init; } = "";
        public string? NameEn { get; init; }
        public int VersionNo { get; init; }
        public DateTime EffectiveFrom { get; init; }
        public DateTime? EffectiveTo { get; init; }
        public string Status { get; init; } = "";
        public long? CreatedBy { get; init; }
        public DateTime? ApprovedOn { get; init; }
    }

    private const string Select =
        """
        SELECT s.TariffScheduleId, s.PublicId, s.InstitutionId, i.PublicId AS InstitutionPublicId, i.Code AS InstitutionCode, s.FacilityId, f.PublicId AS FacilityPublicId,
               f.FacilityNo, s.NameAr, s.NameEn, s.VersionNo, s.EffectiveFrom, s.EffectiveTo, s.Status, s.CreatedBy, s.ApprovedOn
          FROM prc.TariffSchedule AS s JOIN ins.Institution AS i ON i.InstitutionId = s.InstitutionId LEFT JOIN fac.Facility AS f ON f.FacilityId = s.FacilityId
        """;

    private static object Shape(ScheduleRow s) => new
    {
        id = s.PublicId, institution = new { id = s.InstitutionPublicId, code = s.InstitutionCode }, facility = s.FacilityPublicId, facilityNo = s.FacilityNo, nameAr = s.NameAr,
        nameEn = s.NameEn, versionNo = s.VersionNo, effectiveFrom = FacilityEndpoints.D(s.EffectiveFrom), effectiveTo = FacilityEndpoints.D(s.EffectiveTo), status = s.Status,
        approvedOn = s.ApprovedOn,
    };

    private static async Task<(BoundUser U, CompanyScope Scope)> OpenAsync(HttpContext http, SqlConnectionFactory db, string permission) =>
        await FacilityEndpoints.OpenAsync(http, db, permission);

    private static async Task<ScheduleRow> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct, bool lockRow = false) =>
        await u.Connection.QuerySingleOrDefaultAsync<ScheduleRow>(new CommandDefinition(
            Select.Replace("FROM prc.TariffSchedule AS s", lockRow ? "FROM prc.TariffSchedule AS s WITH (UPDLOCK, HOLDLOCK)" : "FROM prc.TariffSchedule AS s", StringComparison.Ordinal)
            + " WHERE s.PublicId = @id;", new { id }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "institution", "facility");
        var (u, _) = await OpenAsync(http, db, View);
        await using var _u = u;
        Guid? inst = Guid.TryParse(http.Request.Query["institution"], out var ig) ? ig : null;
        Guid? fac = Guid.TryParse(http.Request.Query["facility"], out var fg) ? fg : null;
        var rows = await u.Connection.QueryAsync<ScheduleRow>(new CommandDefinition(
            Select + " WHERE (@inst IS NULL OR i.PublicId = @inst) AND (@fac IS NULL OR f.PublicId = @fac) ORDER BY i.Code, s.FacilityId, s.VersionNo DESC;",
            new { inst, fac }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(Shape) });
    }

    private static async Task<IResult> CreateAsync(TariffScheduleRequest b, HttpContext http, SqlConnectionFactory db)
    {
        if (b.Institution is null || string.IsNullOrWhiteSpace(b.NameAr)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the bank and the Arabic name of the schedule.");
        var from = LimitEndpoints.Date(b.EffectiveFrom, "start date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the start date of the schedule.");
        var (u, scope) = await OpenAsync(http, db, Manage);
        await using var _u = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var inst = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @i;", new { i = b.Institution }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank is not an institution of the account.");
        long? facility = b.Facility is null ? null : (await FacilityEndpoints.FindAsync(u, tx, b.Facility.Value, scope, ct)).FacilityId;
        var version = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT ISNULL(MAX(VersionNo), 0) + 1 FROM prc.TariffSchedule WHERE InstitutionId = @i AND (FacilityId = @f OR (FacilityId IS NULL AND @f IS NULL));",
            new { i = inst, f = facility }, tx, cancellationToken: ct));
        var (id, publicId) = await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT prc.TariffSchedule (TenantId, InstitutionId, FacilityId, NameAr, NameEn, VersionNo, EffectiveFrom, Status, SourceDocumentId, CreatedBy)
            OUTPUT inserted.TariffScheduleId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @i, @f, @ar, @en, @v, @from, 'DRAFT', @doc, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new
            {
                i = inst, f = facility, ar = b.NameAr.Trim(), en = b.NameEn?.Trim(), v = version, from,
                doc = b.SourceDocument is null ? null : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                    "SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE';", new { d = b.SourceDocument }, tx, cancellationToken: ct)),
            }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("TARIFF_SCHEDULE_CREATED", "TREASURY", "prc.TariffSchedule", id,
            AfterJson: JsonSerializer.Serialize(new { institution = b.Institution, facility = b.Facility, version })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/tariff-schedules/{publicId}", new { id = publicId, versionNo = version });
    }

    private sealed class ItemRow
    {
        public long TariffItemId { get; init; }
        public string FeeType { get; init; } = "";
        public string ItemCode { get; init; } = "";
        public string NameAr { get; init; } = "";
        public string? NameEn { get; init; }
        public string? Product { get; init; }
        public string ChargeKind { get; init; } = "";
        public decimal? Rate { get; init; }
        public decimal? FixedAmount { get; init; }
        public decimal? PerMillionAmount { get; init; }
        public string PeriodBasis { get; init; } = "";
        public int? PeriodDays { get; init; }
        public decimal? MinAmount { get; init; }
        public decimal? MaxAmount { get; init; }
        public string Locality { get; init; } = "";
        public string? TierCalcMode { get; init; }
        public string VatTreatment { get; init; } = "";
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, _) = await OpenAsync(http, db, View);
        await using var _u = u;
        var ct = http.RequestAborted;
        var s = await FindAsync(u, null, id, ct);
        var items = (await u.Connection.QueryAsync<ItemRow>(new CommandDefinition(
            """
            SELECT t.TariffItemId, ft.Code AS FeeType, t.ItemCode, t.NameAr, t.NameEn, p.Code AS Product, t.ChargeKind, t.Rate, t.FixedAmount, t.PerMillionAmount, t.PeriodBasis,
                   t.PeriodDays, t.MinAmount, t.MaxAmount, t.Locality, t.TierCalcMode, t.VatTreatment
              FROM prc.TariffItem AS t JOIN cat.FeeType AS ft ON ft.FeeTypeId = t.FeeTypeId LEFT JOIN cat.Product AS p ON p.ProductId = t.ProductId
             WHERE t.ScheduleId = @s ORDER BY t.ItemCode;
            """, new { s = s.TariffScheduleId }, cancellationToken: ct))).ToList();
        var tiers = (await u.Connection.QueryAsync<(long Item, decimal? AmountFrom, decimal? AmountTo, int? PeriodFrom, int? PeriodTo, decimal? Rate, decimal? Fixed, int Sort)>(new CommandDefinition(
            """
            SELECT r.TariffItemId, r.AmountFrom, r.AmountTo, r.PeriodFromDays, r.PeriodToDays, r.Rate, r.FixedAmount, r.SortOrder
              FROM prc.TariffTier AS r JOIN prc.TariffItem AS t ON t.TariffItemId = r.TariffItemId WHERE t.ScheduleId = @s ORDER BY r.SortOrder;
            """, new { s = s.TariffScheduleId }, cancellationToken: ct))).ToLookup(t => t.Item);
        return Results.Ok(new
        {
            schedule = Shape(s),
            items = items.Select(i => new
            {
                id = refs.ItemRef(u.TenantId, "tariff-item", i.TariffItemId), feeType = i.FeeType, itemCode = i.ItemCode, nameAr = i.NameAr, nameEn = i.NameEn, product = i.Product,
                chargeKind = i.ChargeKind, rate = i.Rate, fixedAmount = i.FixedAmount, perMillionAmount = i.PerMillionAmount, periodBasis = i.PeriodBasis, periodDays = i.PeriodDays,
                minAmount = i.MinAmount, maxAmount = i.MaxAmount, locality = i.Locality, tierCalcMode = i.TierCalcMode, vatTreatment = i.VatTreatment,
                tiers = tiers[i.TariffItemId].Select(t => new { amountFrom = t.AmountFrom, amountTo = t.AmountTo, periodFromDays = t.PeriodFrom, periodToDays = t.PeriodTo, rate = t.Rate, fixedAmount = t.Fixed }),
            }),
        });
    }

    private static readonly string[] ChargeKinds = ["PERCENT", "FIXED", "PER_MILLION", "TIERED"];

    private static async Task<IResult> AddItemAsync(Guid id, TariffItemRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var kind = b.ChargeKind?.Trim().ToUpperInvariant();
        if (string.IsNullOrWhiteSpace(b.FeeType) || string.IsNullOrWhiteSpace(b.ItemCode) || string.IsNullOrWhiteSpace(b.NameAr) || kind is null || !ChargeKinds.Contains(kind))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the fee type, the item code, the Arabic name and the charge: PERCENT, FIXED, PER_MILLION or TIERED.");
        // The value of the charge kind, and only it (FR-PRC-002).
        var ok = kind switch
        {
            "PERCENT" => b.Rate is >= 0 and <= 100 && b.FixedAmount is null && b.PerMillionAmount is null,
            "FIXED" => b.FixedAmount is >= 0 && b.Rate is null && b.PerMillionAmount is null,
            "PER_MILLION" => b.PerMillionAmount is >= 0 && b.Rate is null && b.FixedAmount is null,
            _ => b.Rate is null && b.FixedAmount is null && b.PerMillionAmount is null,
        };
        if (!ok) throw ApiProblemException.Invalid("V-PRC-02", "Give the value of the charge kind, and only it.");
        var basis = b.PeriodBasis?.Trim().ToUpperInvariant() ?? "FLAT";
        if (basis is not ("FLAT" or "PER_ANNUM" or "PER_PERIOD_OR_PART")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The period basis is FLAT, PER_ANNUM or PER_PERIOD_OR_PART.");
        if (basis == "PER_PERIOD_OR_PART" && b.PeriodDays is not > 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A charge per period or part gives the days of a period.");
        if (b.MinAmount is < 0 || (b.MinAmount is not null && b.MaxAmount is not null && b.MinAmount > b.MaxAmount))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The minimum is from zero and at most the maximum.");
        var (u, _) = await OpenAsync(http, db, Manage);
        await using var _u = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await FindAsync(u, tx, id, ct, lockRow: true);
        if (s.Status != "DRAFT") throw new ApiProblemException(409, "APPROVED_FINAL", "An approved schedule is fixed; change it with a new version.");
        var fee = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT FeeTypeId FROM cat.FeeType WHERE Code = @c AND IsActive = 1;",
            new { c = b.FeeType.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The fee type is not in the catalogue.");
        int? product = b.Product is null ? null : await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT ProductId FROM cat.Product WHERE Code = @c;",
            new { c = b.Product.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The product is not in the catalogue.");
        if (b.SourceDocument is null && string.IsNullOrWhiteSpace(b.NoSourceReason))
            throw ApiProblemException.Invalid("V-FAC-SOURCE", "Name the document and its page the value comes from, or give the reason it has none (BR-FAC-018).");
        long? doc = b.SourceDocument is null ? null : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE';", new { d = b.SourceDocument }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is not an active document.");
        if (doc is not null && string.IsNullOrWhiteSpace(b.SourcePage)) throw ApiProblemException.Invalid("V-FAC-SOURCE", "A value from a document names its page.");
        long item;
        try
        {
            item = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT prc.TariffItem (TenantId, ScheduleId, FeeTypeId, ItemCode, NameAr, NameEn, ProductId, ChargeKind, Rate, FixedAmount, PerMillionAmount, PeriodBasis, PeriodDays,
                                       MinAmount, MaxAmount, Locality, TierCalcMode, PerMillionMode, VatTreatment, CurrencyId, SourceDocumentId, SourcePage, ReadFromScan,
                                       NoSourceReason, Confidence, CreatedBy)
                OUTPUT inserted.TariffItemId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @s, @fee, @code, @ar, @en, @product, @kind, @rate, @fixed, @pm, @basis, @days, @min, @max, @loc, @tier, @pmm,
                        @vat, @cur, @doc, @page, @scan, @nsr, @conf, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new
                {
                    s = s.TariffScheduleId, fee, code = b.ItemCode.Trim().ToUpperInvariant(), ar = b.NameAr.Trim(), en = b.NameEn?.Trim(), product, kind, rate = b.Rate, @fixed = b.FixedAmount,
                    pm = b.PerMillionAmount, basis, days = b.PeriodDays, min = b.MinAmount, max = b.MaxAmount, loc = b.Locality?.ToUpperInvariant() ?? "ANY",
                    tier = b.TierCalcMode?.ToUpperInvariant() ?? "BAND", pmm = b.PerMillionMode?.ToUpperInvariant() ?? "PRORATA", vat = b.VatTreatment?.ToUpperInvariant() ?? "EXCLUSIVE",
                    cur = b.Currency is null ? null : (int?)await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency, ct), doc, page = b.SourcePage?.Trim(), scan = b.ReadFromScan ?? false,
                    nsr = b.NoSourceReason?.Trim(), conf = b.ReadFromScan == true ? "READ_FROM_SCAN_UNVERIFIED" : "ENTERED_NO_DOCUMENT",
                }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            throw new ApiProblemException(409, "V-PRC-ITEM-EXISTS", "The schedule already has an item with this code.");
        }
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/tariff-schedules/{id}", new { id = refs.ItemRef(u.TenantId, "tariff-item", item) });
    }

    /// <summary>A tier of a TIERED item; its band does not overlap another of the same dimension (V-PRC-01, FR-PRC-003).</summary>
    private static async Task<IResult> AddTierAsync(Guid id, string item, TariffTierRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        if ((b.Rate is null) == (b.FixedAmount is null)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A tier has a rate or a fixed amount.");
        var byAmount = b.AmountFrom is not null || b.AmountTo is not null;
        var byPeriod = b.PeriodFromDays is not null || b.PeriodToDays is not null;
        if (byAmount == byPeriod) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A tier is a band of amounts or a band of days.");
        var (u, _) = await OpenAsync(http, db, Manage);
        await using var _u = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await FindAsync(u, tx, id, ct, lockRow: true);
        if (s.Status != "DRAFT") throw new ApiProblemException(409, "APPROVED_FINAL", "An approved schedule is fixed; change it with a new version.");
        var itemId = refs.ItemId(u.TenantId, "tariff-item", item) ?? throw ApiProblemException.NotFound();
        var kind = await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT ChargeKind FROM prc.TariffItem WHERE TariffItemId = @i AND ScheduleId = @s;",
            new { i = itemId, s = s.TariffScheduleId }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (kind != "TIERED") throw ApiProblemException.Invalid("VALIDATION_FAILED", "Only a TIERED item has tiers.");
        var existing = (await u.Connection.QueryAsync<(decimal? AF, decimal? AT, int? PF, int? PT, int Sort)>(new CommandDefinition(
            "SELECT AmountFrom, AmountTo, PeriodFromDays, PeriodToDays, SortOrder FROM prc.TariffTier WHERE TariffItemId = @i;", new { i = itemId }, tx, cancellationToken: ct))).ToList();
        static bool Overlap(decimal from, decimal to, decimal f2, decimal t2) => from < t2 && f2 < to;
        var overlaps = byAmount
            ? existing.Where(e => e.AF is not null || e.AT is not null).Any(e => Overlap(b.AmountFrom ?? 0, b.AmountTo ?? decimal.MaxValue, e.AF ?? 0, e.AT ?? decimal.MaxValue))
            : existing.Where(e => e.PF is not null || e.PT is not null).Any(e => Overlap(b.PeriodFromDays ?? 0, b.PeriodToDays ?? int.MaxValue, e.PF ?? 0, e.PT ?? int.MaxValue));
        if (overlaps) throw ApiProblemException.Invalid("V-PRC-01", "This tier overlaps another tier of the item.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT prc.TariffTier (TenantId, TariffItemId, AmountFrom, AmountTo, PeriodFromDays, PeriodToDays, Rate, FixedAmount, MinAmount, SortOrder, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @i, @af, @at, @pf, @pt, @rate, @fixed, @min, @sort, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new
            {
                i = itemId, af = b.AmountFrom, at = b.AmountTo, pf = b.PeriodFromDays, pt = b.PeriodToDays, rate = b.Rate, @fixed = b.FixedAmount, min = b.MinAmount,
                sort = existing.Count == 0 ? 1 : existing.Max(e => e.Sort) + 1,
            }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> ApproveAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, _) = await OpenAsync(http, db, Approve);
        await using var _u = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var s = await FindAsync(u, tx, id, ct, lockRow: true);
        if (s.Status != "DRAFT") throw new ApiProblemException(409, "V-PRC-STATE", "Only a draft schedule is approved.");
        if (s.CreatedBy == u.UserId && !await u.Connection.ExecuteScalarAsync<bool>(new CommandDefinition(
                "SELECT CASE WHEN ISNULL(t.ValueJson, d.DefaultValueJson) = 'true' THEN 1 ELSE 0 END FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key] WHERE d.[Key] = 'wf.sod.allow_same_person';",
                transaction: tx, cancellationToken: ct)))
            throw ApiProblemException.Forbidden("V-PRC-SOD", "The preparer of a schedule does not approve it.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM prc.TariffItem WHERE ScheduleId = @s;", new { s = s.TariffScheduleId }, tx,
                cancellationToken: ct)) == 0)
            throw ApiProblemException.Invalid("V-PRC-01", "A schedule without items is not approved.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM prc.TariffItem AS t WHERE t.ScheduleId = @s AND t.ChargeKind = 'TIERED' AND NOT EXISTS (SELECT 1 FROM prc.TariffTier AS r WHERE r.TariffItemId = t.TariffItemId);",
                new { s = s.TariffScheduleId }, tx, cancellationToken: ct)) > 0)
            throw ApiProblemException.Invalid("V-PRC-01", "A tiered item has its tiers.");
        var others = (await u.Connection.QueryAsync<(long Id, DateTime From, DateTime? To)>(new CommandDefinition(
            """
            SELECT TariffScheduleId, EffectiveFrom, EffectiveTo FROM prc.TariffSchedule WITH (UPDLOCK, HOLDLOCK)
             WHERE InstitutionId = @i AND (FacilityId = @f OR (FacilityId IS NULL AND @f IS NULL)) AND Status IN ('APPROVED', 'SUPERSEDED') AND TariffScheduleId <> @s;
            """, new { i = s.InstitutionId, f = s.FacilityId, s = s.TariffScheduleId }, tx, cancellationToken: ct))).ToList();
        // A closed version that covers the new start overlaps it (V-PRC-01); the open one ends the day before.
        if (others.Any(o => o.To is { } to && o.From <= s.EffectiveFrom && to >= s.EffectiveFrom))
            throw ApiProblemException.Invalid("V-PRC-01", "Another version of this tariff covers the start of this one.");
        foreach (var open in others.Where(o => o.To is null))
        {
            if (open.From >= s.EffectiveFrom) throw ApiProblemException.Invalid("V-PRC-01", "The current version starts on or after this one: start this one later.");
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE prc.TariffSchedule SET Status = 'SUPERSEDED', EffectiveTo = @to, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE TariffScheduleId = @id;",
                new { to = s.EffectiveFrom.AddDays(-1), id = open.Id }, tx, cancellationToken: ct));
        }
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE prc.TariffSchedule SET Status = 'APPROVED', ApprovedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ApprovedOn = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE TariffScheduleId = @s;
            """, new { s = s.TariffScheduleId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("TARIFF_SCHEDULE_APPROVED", "TREASURY", "prc.TariffSchedule", s.TariffScheduleId,
            AfterJson: JsonSerializer.Serialize(new { version = s.VersionNo, superseded = others.Count(o => o.To is null) })), null, ct);
        await Outbox.EmitAsync(u.Connection, tx, "tariff.approved", "prc.TariffSchedule", s.TariffScheduleId, new { schedule = s.PublicId }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }
}

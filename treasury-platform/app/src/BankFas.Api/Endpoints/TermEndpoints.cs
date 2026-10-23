using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Facilities;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record TermValueRequest(string? TermType, string? OtherLabel, string? Limit, string? ValueState, decimal? ValueNumber, string? ValueText, bool? ValueBool, string? ValueEnum,
    string? Bound, string? EffectiveFrom, string? EffectiveTo, Guid? SourceDocument, string? SourcePage, bool? ReadFromScan, string? OriginalText, string? NoSourceReason);
public sealed record TermTypeRequest(string? Code, string? NameAr, string? NameEn, string? Category, string? ValueKind, string? Unit, string? DefaultBound, string? Direction,
    string? ScopeKinds, string[]? EnumOptions, string? Description);

/// <summary>
/// Comparable terms (spec 12 section 5, FR-CMP-001 to 008; BR-CMP-001 to 004). The approval projects the typed keys
/// (<see cref="TermStore"/>); the user enters the others in the facility's draft, and an OTHER value carries its own
/// label until a key is proposed (cmp.term.propose) and promoted (cmp.manage). A PROJECTED row is never edited
/// (V-CMP-01). The comparison ranks the specified values of a key by its direction on their normalised value (days,
/// percentage points); a value not specified in the agreement, not applicable or unknown is shown with its state and
/// out of the ranking and the averages (BR-CMP-002).
/// </summary>
public static class TermEndpoints
{
    private const string View = "cmp.view";
    private const string Propose = "cmp.term.propose";
    private const string Manage = "cmp.manage";

    /// <summary>The keys the approval projects: no user writes them (BR-CMP-004).</summary>
    internal static readonly HashSet<string> Projected =
    [
        "PRC.MARGIN_PCT", "PRC.BASE_RATE_FAMILY", "PRC.FIXED_FOR_CONTRACT", "PRC.ZERO_FLOOR", "PRC.LC_COMMISSION_ADDON_PCT", "PRC.TREASURY_FEE_PER_MILLION",
        "PRC.ARRANGEMENT_FEE_PCT", "PRC.DAY_COUNT", "PRC.BANK_MAY_CHANGE_UNILATERALLY", "PRC.OBJECTION_DAYS", "DUR.FACILITY_TERM_MONTHS", "DUR.MAX_TOTAL_TENOR_DAYS",
        "DUR.MAX_DEFERRAL_DAYS", "DUR.LC_VALIDITY_DAYS", "DUR.ADVANCE_NOTICE_DAYS", "DUR.AUDITED_FS_LAG_DAYS", "DUR.INTERIM_FS_LAG_DAYS", "COL.CASH_COVER_PCT",
        "COL.FINANCING_RATIO_PCT", "COL.PN_PCT_OF_LIMIT", "COL.GUARANTORS_INDIVIDUAL", "COL.GUARANTORS_CORPORATE", "COL.INSURANCE_PCT", "COL.VALUERS_FIRST_YEAR", "COL.SET_OFF",
        "COL.NEGATIVE_PLEDGE", "COV.REVENUE_CHANNELLING_PCT", "COV.CAPITAL_PRESERVATION_AMOUNT", "COV.MIN_AVG_BALANCE",
    ];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/facilities/{id:guid}/terms", ListAsync);
        api.MapPost("/facilities/{id:guid}/terms", AddAsync);
        api.MapDelete("/facilities/{id:guid}/terms/{reference}", RemoveAsync);
        api.MapGet("/terms/compare", CompareAsync);
        api.MapGet("/terms/quality", QualityAsync);
        api.MapGet("/term-types", TypesAsync);
        api.MapPost("/term-types", ProposeAsync);
        api.MapPost("/term-types/{code}/actions/promote", PromoteAsync);
    }

    private sealed class TermRow
    {
        public long TermValueId { get; init; }
        public long RootId { get; init; }
        public long FacilityId { get; init; }
        public Guid FacilityPublicId { get; init; }
        public string FacilityNo { get; init; } = "";
        public long BorrowerCompanyId { get; init; }
        public string Code { get; init; } = "";
        public string NameAr { get; init; } = "";
        public string? NameEn { get; init; }
        public string Direction { get; init; } = "";
        public string? OtherLabel { get; init; }
        public string? LimitCode { get; init; }
        public string ValueState { get; init; } = "";
        public decimal? ValueNumber { get; init; }
        public string? ValueText { get; init; }
        public bool? ValueBool { get; init; }
        public string? ValueEnum { get; init; }
        public string Unit { get; init; } = "";
        public string Bound { get; init; } = "";
        public decimal? NormalizedValue { get; init; }
        public string Origin { get; init; } = "";
        public string? ProjectedFrom { get; init; }
        public DateTime EffectiveFrom { get; init; }
        public DateTime? EffectiveTo { get; init; }
        public string Confidence { get; init; } = "";
        public int FromRevision { get; init; }
    }

    private const string Select = """
        SELECT v.TermValueId, v.RootId, f.FacilityId, f.PublicId AS FacilityPublicId, ISNULL(f.PlatformRef, f.FacilityNo) AS FacilityNo, f.BorrowerCompanyId, t.Code, t.NameAr, t.NameEn, t.Direction, v.OtherLabel,
               l.Code AS LimitCode, v.ValueState, v.ValueNumber, v.ValueText, v.ValueBool, v.ValueEnum, v.Unit, v.Bound, v.NormalizedValue, v.Origin, v.ProjectedFrom, v.EffectiveFrom,
               v.EffectiveTo, v.Confidence, v.FromRevision
          FROM cmp.TermValue AS v JOIN cmp.TermType AS t ON t.TermTypeId = v.TermTypeId JOIN fac.Facility AS f ON f.FacilityId = v.FacilityId
          LEFT JOIN fac.Limit AS l ON l.LimitId = v.LimitId
        """;

    private static object Shape(TermRow v, int tenant, OpaqueRefs refs) => new
    {
        id = refs.ItemRef(tenant, "term", v.RootId), facility = v.FacilityPublicId, facilityNo = v.FacilityNo, key = v.Code, nameAr = v.NameAr, nameEn = v.NameEn,
        otherLabel = v.OtherLabel, limit = v.LimitCode, valueState = v.ValueState,
        value = v.ValueNumber ?? (object?)v.ValueText ?? (object?)v.ValueBool ?? v.ValueEnum, unit = v.Unit, bound = v.Bound, normalized = v.NormalizedValue, origin = v.Origin,
        projectedFrom = v.ProjectedFrom, effectiveFrom = FacilityEndpoints.D(v.EffectiveFrom), effectiveTo = FacilityEndpoints.D(v.EffectiveTo), confidence = v.Confidence,
    };

    /// <summary>The terms of the approved revision; view=draft gives the entered values of the draft (the projected ones are written again on approval).</summary>
    private static async Task<IResult> ListAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "view");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, View);
        await using var _ = u;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, http.RequestAborted);
        var draft = http.Request.Query["view"] == "draft";
        var rows = await u.Connection.QueryAsync<TermRow>(new CommandDefinition(
            Select + (draft
                ? " WHERE v.FacilityId = @f AND v.ToRevision IS NULL AND v.Origin = 'ENTERED'"
                : " WHERE v.FacilityId = @f AND v.FromRevision <= @rev AND (v.ToRevision IS NULL OR v.ToRevision > @rev)") + " ORDER BY t.Category, t.SortOrder, v.EffectiveFrom;",
            new { f = f.FacilityId, rev = f.ApprovedRevisionNo }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { view = draft ? "draft" : "approved", items = rows.Select(v => Shape(v, u.TenantId, refs)) });
    }

    /// <summary>FR-CMP-003: a value of a key that is not projected (or an OTHER label), written into the facility's draft with its source.</summary>
    private static async Task<IResult> AddAsync(Guid id, TermValueRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        if (string.IsNullOrWhiteSpace(b.TermType)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the key of the term.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await LimitEndpoints.DraftAsync(u, tx, id, scope, ct);
        var code = b.TermType.Trim().ToUpperInvariant();
        if (Projected.Contains(code)) throw new ApiProblemException(409, "V-CMP-01", "This key is projected from the agreement's typed fields on approval; change the field, not the term.");
        var t = await u.Connection.QuerySingleOrDefaultAsync<(int Id, string Kind, string Unit, string Bound, string Scope, string? Options)?>(new CommandDefinition(
            "SELECT TermTypeId, ValueKind, Unit, DefaultBound, ScopeKinds, EnumOptions FROM cmp.TermType WHERE Code = @c AND IsActive = 1;", new { c = code }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The key is not an active key of the comparable terms.");
        var state = b.ValueState?.ToUpperInvariant() ?? "SPECIFIED";
        if (state is not ("SPECIFIED" or "NOT_SPECIFIED_IN_AGREEMENT" or "NOT_APPLICABLE" or "UNKNOWN")) throw ApiProblemException.Invalid("V-CMP-01", "The state is one of the value states.");
        var given = new object?[] { b.ValueNumber, b.ValueText, b.ValueBool, b.ValueEnum }.Count(x => x is not null);
        if (state == "SPECIFIED" ? given != 1 : given != 0)
            throw ApiProblemException.Invalid("V-CMP-01", "A specified value has exactly one value; a value not specified holds none (BR-CMP-002).");
        var kindOk = state != "SPECIFIED" || t.Kind switch
        {
            "TEXT" => b.ValueText is not null,
            "BOOLEAN" => b.ValueBool is not null,
            "ENUM" => b.ValueEnum is not null && t.Options is not null && JsonSerializer.Deserialize<string[]>(t.Options)!.Contains(b.ValueEnum),
            _ => b.ValueNumber is >= 0,
        };
        if (!kindOk) throw ApiProblemException.Invalid("V-CMP-01", "The value is of the key's kind.");
        long? limit = null;
        if (b.Limit is not null)
        {
            if (!t.Scope.Split(',').Contains("LIMIT")) throw ApiProblemException.Invalid("V-CMP-01", "This key is not set per limit.");
            limit = d.Rows.Limits.FirstOrDefault(l => l.RootId == refs.ItemId(u.TenantId, "limit", b.Limit))?.LimitId
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The limit is not a limit of the facility.");
        }
        var bound = b.Bound?.ToUpperInvariant() ?? t.Bound;
        var from = LimitEndpoints.Date(b.EffectiveFrom, "start date") ?? d.Rev.Header(d.F).Effective;
        var src = await LimitEndpoints.SourceAsync(u, tx, d.F, b.SourceDocument, b.SourcePage, b.ReadFromScan, b.OriginalText, b.NoSourceReason, ct);
        var label = code == "OTHER" ? b.OtherLabel?.Trim() is { Length: > 0 } ol ? ol : throw ApiProblemException.Invalid("V-CMP-01", "An OTHER term has its label (FR-CMP-004).") : null;
        var normalized = state == "SPECIFIED" && b.ValueNumber is { } n ? t.Kind == "MONTHS" ? n * 30 : n : (decimal?)null;
        var root = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (RootId BIGINT);
            INSERT cmp.TermValue (TenantId, FacilityId, TermTypeId, OtherLabel, LimitId, ValueState, ValueNumber, ValueText, ValueBool, ValueEnum, Unit, CurrencyId, Bound,
                                  NormalizedValue, Origin, EffectiveFrom, EffectiveTo, FromRevision, SourceDocumentId, SourcePage, ReadFromScan, OriginalText, NoSourceReason,
                                  Confidence, CreatedBy)
            OUTPUT inserted.RootId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @t, @label, @limit, @state, @n, @text, @flag, @en, @unit, @cur, @bound, @norm, 'ENTERED', @from, @to, @r, @doc,
                    @page, @scan, @orig, @reason, @conf, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT RootId FROM @o;
            """, new
            {
                f = d.F.FacilityId, t = t.Id, label, limit, state, n = b.ValueNumber, text = b.ValueText, flag = b.ValueBool, en = b.ValueEnum, unit = t.Unit,
                cur = t.Kind == "AMOUNT" ? d.F.CurrencyId : (int?)null, bound, norm = normalized, from, to = LimitEndpoints.Date(b.EffectiveTo, "end date"), r = d.Rev.RevisionNo,
                doc = src.Doc, page = src.Page, scan = src.Scan, orig = src.Original, reason = src.Reason, conf = src.Confidence,
            }, tx, cancellationToken: ct));
        await LimitEndpoints.DoneAsync(u, tx, d, "TERM_ENTERED", new { key = code, label, state }, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/terms", new { id = refs.ItemRef(u.TenantId, "term", root) });
    }

    private static async Task<IResult> RemoveAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await LimitEndpoints.DraftAsync(u, tx, id, scope, ct);
        var root = refs.ItemId(u.TenantId, "term", reference);
        var row = await u.Connection.QuerySingleOrDefaultAsync<(long Id, string Origin)?>(new CommandDefinition(
            "SELECT TermValueId, Origin FROM cmp.TermValue WHERE FacilityId = @f AND RootId = @r AND ToRevision IS NULL;", new { f = d.F.FacilityId, r = root }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        if (row.Origin == "PROJECTED") throw new ApiProblemException(409, "V-CMP-01", "A projected term is never edited (V-CMP-01).");
        await LimitEndpoints.DeleteDraftRowAsync(u, tx, "cmp.TermValue", "TermValueId", row.Id, ct);
        await LimitEndpoints.DoneAsync(u, tx, d, "TERM_REMOVED", new { term = reference }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>
    /// FR-CMP-008 (GET /terms/compare): the values of one key across the facilities in scope on a date, from their approved
    /// revisions. The specified values are ranked by the key's direction (LOWER_BETTER ascending) and the first is the
    /// best; the others keep their state and stand outside the ranking (BR-CMP-002).
    /// </summary>
    private static async Task<IResult> CompareAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "key", "asOf", "label");
        var key = http.Request.Query["key"].ToString().ToUpperInvariant();
        if (key.Length == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the key to compare.");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var scope = await CompanyScope.OfAsync(u, ct);
        var asOf = LimitEndpoints.Date(http.Request.Query["asOf"], "date") ?? DateTime.UtcNow.Date;
        // The direction is the key's, whether or not any facility has a value for it yet.
        var direction = await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT Direction FROM cmp.TermType WHERE Code = @key;", new { key }, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        var rows = (await u.Connection.QueryAsync<TermRow>(new CommandDefinition(
            Select + """
             WHERE t.Code = @key AND (@label IS NULL OR v.OtherLabel = @label) AND f.ApprovedRevisionNo >= 1
               AND v.FromRevision <= f.ApprovedRevisionNo AND (v.ToRevision IS NULL OR v.ToRevision > f.ApprovedRevisionNo)
               AND v.EffectiveFrom <= @asOf AND (v.EffectiveTo IS NULL OR v.EffectiveTo >= @asOf) AND f.LifecycleStatus NOT IN ('TERMINATED', 'SUPERSEDED');
            """, new { key, asOf, label = http.Request.Query["label"].ToString() is { Length: > 0 } l ? l : null }, cancellationToken: ct))).Where(r => scope.Allows(r.BorrowerCompanyId)).ToList();
        var ranked = rows.Where(r => r.ValueState == "SPECIFIED" && r.NormalizedValue is not null);
        ranked = direction == "HIGHER_BETTER" ? ranked.OrderByDescending(r => r.NormalizedValue) : ranked.OrderBy(r => r.NormalizedValue);
        var list = ranked.ToList();
        return Results.Ok(new
        {
            key, direction, asOf = FacilityEndpoints.D(asOf), best = list.FirstOrDefault() is { } best && direction != "NEUTRAL" ? Shape(best, u.TenantId, refs) : null,
            average = list.Count == 0 ? (decimal?)null : Math.Round(list.Average(r => r.NormalizedValue!.Value), 4),
            ranked = list.Select((r, i) => new { rank = i + 1, term = Shape(r, u.TenantId, refs) }),
            unranked = rows.Where(r => r.ValueState != "SPECIFIED" || r.NormalizedValue is null).Select(r => Shape(r, u.TenantId, refs)),
        });
    }

    /// <summary>R-CMP-00 (FR-CMP-007) and the nightly check JOB-CMP-SYNC reports: per facility, values by state, unverified scans, and projected values the sources no longer give.</summary>
    private static async Task<IResult> QualityAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var scope = await CompanyScope.OfAsync(u, ct);
        var facilities = (await u.Connection.QueryAsync<(long Id, Guid PublicId, string No, long Company, int Rev, DateTime From, DateTime Expiry, decimal Total)>(new CommandDefinition(
            "SELECT FacilityId, PublicId, FacilityNo, BorrowerCompanyId, ApprovedRevisionNo, EffectiveFrom, ExpiryDate, TotalAmount FROM fac.Facility WHERE ApprovedRevisionNo >= 1 AND LifecycleStatus IN ('ACTIVE', 'SUSPENDED');",
            cancellationToken: ct))).Where(x => scope.Allows(x.Company)).ToList();
        var result = new List<object>();
        foreach (var f in facilities)
        {
            var stored = (await u.Connection.QueryAsync<TermRow>(new CommandDefinition(
                Select + " WHERE v.FacilityId = @f AND v.FromRevision <= @rev AND (v.ToRevision IS NULL OR v.ToRevision > @rev);", new { f = f.Id, rev = f.Rev }, cancellationToken: ct))).ToList();
            var now = await TermStore.ComputeAsync(u.Connection, null, f.Id, f.Rev, f.From, f.Expiry, f.Total, ct);
            var drift = now.Where(n => !stored.Any(s => s.Origin == "PROJECTED" && s.Code == n.Code && s.EffectiveFrom == n.From && s.ValueState == n.State
                    && (s.ValueNumber ?? 0) == (n.Number ?? 0) && s.ValueText == n.Text && s.ValueBool == n.Flag && s.ValueEnum == n.Enum))
                .Select(n => n.Code).Distinct().ToList();
            result.Add(new
            {
                facility = f.PublicId, facilityNo = f.No, values = stored.Count, byState = stored.GroupBy(s => s.ValueState).ToDictionary(g => g.Key, g => g.Count()),
                unverifiedScans = stored.Count(s => s.Confidence == "READ_FROM_SCAN_UNVERIFIED"), drift,
            });
        }
        return Results.Ok(new { items = result });
    }

    // ---------- the keys (FR-CMP-001, 004) ----------

    private static async Task<IResult> TypesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT Code AS code, NameAr AS nameAr, NameEn AS nameEn, Category AS category, ValueKind AS valueKind, Unit AS unit, DefaultBound AS defaultBound, Direction AS direction,
                   ScopeKinds AS scopeKinds, IsSystem AS isSystem, IsActive AS isActive, CASE WHEN SourceBinding IS NULL THEN 0 ELSE 1 END AS bound
              FROM cmp.TermType ORDER BY Category, SortOrder, Code;
            """, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(r => new { r.code, r.nameAr, r.nameEn, r.category, r.valueKind, r.unit, r.defaultBound, r.direction, r.scopeKinds, r.isSystem, r.isActive,
            projected = Projected.Contains((string)r.code) }) });
    }

    /// <summary>FR-CMP-004: a key proposed from an OTHER label waits inactive until a treasury manager or administrator promotes it.</summary>
    private static async Task<IResult> ProposeAsync(TermTypeRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var code = b.Code?.Trim().ToUpperInvariant();
        var kind = b.ValueKind?.ToUpperInvariant();
        if (code is null || !System.Text.RegularExpressions.Regex.IsMatch(code, "^[A-Z][A-Z0-9_.]{1,79}$") || string.IsNullOrWhiteSpace(b.NameAr) || string.IsNullOrWhiteSpace(b.Unit)
            || kind is not ("PERCENT" or "AMOUNT" or "DAYS" or "MONTHS" or "COUNT" or "BOOLEAN" or "ENUM" or "TEXT") || (kind == "ENUM") != (b.EnumOptions is { Length: > 0 }))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the code, the Arabic name, the kind and the unit of the key (and the options of an ENUM).");
        var category = b.Category?.ToUpperInvariant() ?? "OTHER";
        var direction = b.Direction?.ToUpperInvariant() ?? "NEUTRAL";
        var boundKind = b.DefaultBound?.ToUpperInvariant() ?? "EXACT";
        if (category is not ("PRICING" or "DURATION" or "COLLATERAL" or "COVENANT" or "OTHER") || direction is not ("LOWER_BETTER" or "HIGHER_BETTER" or "NEUTRAL")
            || boundKind is not ("EXACT" or "MAX" or "MIN"))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The category, direction and bound are of their lists.");
        await using var u = await BoundUser.OpenAsync(http, db, Propose);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM cmp.TermType WHERE Code = @c;", new { c = code }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-CMP-KEY-EXISTS", "A key with this code exists.");
        var id = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id INT);
            INSERT cmp.TermType (TenantId, Code, NameAr, NameEn, Description, IsActive, IsSystem, IsLocked, Category, ValueKind, Unit, DefaultBound, Direction, ScopeKinds, EnumOptions,
                                 CreatedBy)
            OUTPUT inserted.TermTypeId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @ar, @en, @desc, 0, 0, 0, @cat, @kind, @unit, @bound, @dir, @scope, @opts, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new
            {
                c = code, ar = b.NameAr.Trim(), en = b.NameEn?.Trim(), desc = b.Description, cat = category, kind, unit = b.Unit.Trim().ToUpperInvariant(), bound = boundKind, dir = direction,
                scope = b.ScopeKinds?.ToUpperInvariant() ?? "FACILITY", opts = b.EnumOptions is { Length: > 0 } o ? JsonSerializer.Serialize(o) : null,
            }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("TERM_KEY_PROPOSED", "CONFIG", "cmp.TermType", id, AfterJson: JsonSerializer.Serialize(new { code, kind })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/term-types/{code}", new { code, isActive = false });
    }

    private static async Task<IResult> PromoteAsync(string code, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var t = await u.Connection.QuerySingleOrDefaultAsync<(int Id, bool Active, long? CreatedBy)?>(new CommandDefinition(
            "SELECT TermTypeId, IsActive, CreatedBy FROM cmp.TermType WITH (UPDLOCK) WHERE Code = @c;", new { c = code.ToUpperInvariant() }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        if (t.Active) throw new ApiProblemException(409, "V-CMP-STATE", "The key is already active.");
        if (t.CreatedBy == u.UserId && !await FacilityRevisionEndpoints.SamePersonAllowedAsync(u, tx, ct))
            throw ApiProblemException.Forbidden("V-CMP-SOD", "The one who proposed a key does not promote it.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE cmp.TermType SET IsActive = 1, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE TermTypeId = @id;", new { id = t.Id }, tx,
            cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("TERM_KEY_PROMOTED", "CONFIG", "cmp.TermType", t.Id), null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }
}

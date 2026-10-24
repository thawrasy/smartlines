using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record SettingsPatch(Dictionary<string, JsonElement>? Values);
public sealed record SequenceRequest(string? SequenceKey, string? Pattern, string? ScopeLevel, string? PeriodBasis, string? GapPolicy, int? MinWidth, bool? IsActive);
public sealed record PreviewRequest(string? Pattern, string? ScopeLevel);
public sealed record VoidRequest(string? Reason);
public sealed record AuditExportRequest(string? From, string? To, string? Category, string? StepUpCode);

/// <summary>
/// Tenant settings within the platform bounds (SCR-PLT-11, FR-PLT-043, BR-PLT-018), numbering definitions and issued
/// numbers (SCR-PLT-12, FR-PLT-026), the audit log (SCR-PLT-13, FR-PLT-022 to 025) and the job runs (SCR-PLT-14,
/// FR-PLT-044). The database triggers hold the same rules (50020, 50044, 50031); the application checks first, because
/// a trigger error ends the transaction, and shows the bounds.
/// </summary>
public static partial class ConfigEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/settings", GetSettingsAsync);
        api.MapPatch("/settings", PatchSettingsAsync);
        api.MapGet("/number-sequences", ListSequencesAsync);
        api.MapPost("/number-sequences", CreateSequenceAsync);
        api.MapPatch("/number-sequences/{key}", PatchSequenceAsync);
        api.MapPost("/number-sequences/preview", Preview);
        api.MapGet("/number-sequences/{key}/issues", IssuesAsync);
        api.MapPost("/number-issues/{reference}/actions/void", VoidAsync);
        api.MapGet("/audit-events", AuditAsync);
        api.MapPost("/audit-events/exports", AuditExportAsync);
        api.MapGet("/jobs", JobsAsync);
        api.MapGet("/jobs/{jobKey}/runs", JobRunsAsync);
    }

    // ---------- settings ----------

    private sealed record SettingRow(string Key, string ModuleCode, string ValueType, string DefaultValueJson, string? MinValueJson,
        string? MaxValueJson, bool IsSecurity, bool IsTenantEditable, string? Description, string? ValueJson);

    private static Task<IEnumerable<SettingRow>> SettingRowsAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct) =>
        c.QueryAsync<SettingRow>(new CommandDefinition(
            """
            SELECT d.[Key], d.ModuleCode, d.ValueType, d.DefaultValueJson, d.MinValueJson, d.MaxValueJson, d.IsSecurity, d.IsTenantEditable,
                   d.Description, t.ValueJson
            FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key]
            ORDER BY d.ModuleCode, d.[Key];
            """, transaction: tx, cancellationToken: ct));

    private static JsonElement? Json(string? text) => text is null ? null : JsonDocument.Parse(text).RootElement.Clone();

    private static async Task<IResult> GetSettingsAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, "cfg.settings.manage");
        var rows = await SettingRowsAsync(u.Connection, null, http.RequestAborted);
        return Results.Ok(new
        {
            items = rows.Select(r => new
            {
                key = r.Key, module = r.ModuleCode, valueType = r.ValueType, defaultValue = Json(r.DefaultValueJson), min = Json(r.MinValueJson),
                max = Json(r.MaxValueJson), isSecurity = r.IsSecurity, editable = r.IsTenantEditable,
                description = r.Description, value = Json(r.ValueJson), effective = Json(r.ValueJson ?? r.DefaultValueJson),
            }),
        });
    }

    private static async Task<IResult> PatchSettingsAsync(SettingsPatch body, HttpContext http, SqlConnectionFactory db)
    {
        if (body.Values is not { Count: > 0 }) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Send at least one setting.");
        await using var u = await BoundUser.OpenAsync(http, db, "cfg.settings.manage");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var defs = (await SettingRowsAsync(u.Connection, tx, http.RequestAborted)).ToDictionary(r => r.Key, StringComparer.Ordinal);
        var effective = defs.ToDictionary(d => d.Key, d => d.Value.ValueJson ?? d.Value.DefaultValueJson, StringComparer.Ordinal);
        var changes = new List<(SettingRow Def, string? NewJson)>();
        foreach (var (key, value) in body.Values)
        {
            if (!defs.TryGetValue(key, out var d) || !d.IsTenantEditable)
                throw ApiProblemException.Invalid("V-PLT-08", $"{key} is not a setting this account can change.");
            string? newJson = value.ValueKind == JsonValueKind.Null ? null : value.GetRawText();
            if (newJson is not null) CheckValue(d, value);
            changes.Add((d, newJson));
            effective[key] = newJson ?? d.DefaultValueJson;
        }
        if (TimeOfDay(effective["work.start"]) is { } start && TimeOfDay(effective["work.end"]) is { } end
            && (end - start).TotalMinutes is < 240 or > 720)
            throw ApiProblemException.Invalid("V-PLT-09", "The working day is 4 to 12 hours long.");
        // AC-LCT-4, FR-LCT-005: the footnote on UCP texts stays while any article in use is unverified.
        if (effective.TryGetValue("lc.print.ucp_disclaimer", out var footnote) && footnote == "false" && await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                """
                SELECT COUNT(*) FROM ref.UcpArticle AS a
                 WHERE a.VerificationStatus = 'UNVERIFIED'
                   AND (EXISTS (SELECT 1 FROM lc.LcFieldUcpRef AS r WHERE r.UcpArticleId = a.UcpArticleId)
                        OR EXISTS (SELECT 1 FROM lc.LcDocumentClauseUcpRef AS r WHERE r.UcpArticleId = a.UcpArticleId));
                """, transaction: tx, cancellationToken: http.RequestAborted)) > 0)
            throw ApiProblemException.Invalid("V-LCT-UCP-FOOTNOTE", "The UCP footnote stays printed while an article in use is not verified (FR-LCT-005).");
        foreach (var (d, newJson) in changes.Where(x => x.Def.ValueJson != x.NewJson))
        {
            // null is the platform default; tp_app may not delete a setting row (007), so the default is stored.
            if (newJson is null && d.ValueJson is null) continue;
            await u.Connection.ExecuteAsync(new CommandDefinition(
                    """
                    UPDATE cfg.TenantSetting SET ValueJson = @v WHERE [Key] = @k;
                    IF @@ROWCOUNT = 0 INSERT cfg.TenantSetting (TenantId, [Key], ValueJson) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @k, @v);
                    """, new { k = d.Key, v = newJson ?? d.DefaultValueJson }, tx, cancellationToken: http.RequestAborted));
            await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("SETTING_CHANGED", d.IsSecurity ? "SECURITY" : "CONFIG",
                "cfg.TenantSetting", null,
                BeforeJson: JsonSerializer.Serialize(new { key = d.Key, value = Json(d.ValueJson ?? d.DefaultValueJson) }),
                AfterJson: JsonSerializer.Serialize(new { key = d.Key, value = Json(newJson ?? d.DefaultValueJson) }),
                Severity: d.IsSecurity ? "HIGH" : "INFO"), http.RequestAborted);
        }
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    private static void CheckValue(SettingRow d, JsonElement v)
    {
        var bad = ApiProblemException.Invalid("V-PLT-08", $"{d.Key}: the value is outside what the platform allows.");
        switch (d.ValueType)
        {
            case "INT":
                var n = v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i
                    : v.ValueKind == JsonValueKind.String && int.TryParse(v.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var j) ? j
                    : throw bad;
                if (Int(d.MinValueJson) is { } min && n < min) throw bad;
                if (Int(d.MaxValueJson) is { } max && n > max) throw bad;
                break;
            case "BOOL":
                if (v.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw bad;
                break;
            case "TIME":
                if (v.ValueKind != JsonValueKind.String || TimeOfDay(v.GetRawText()) is not { } t) throw bad;
                if (TimeOfDay(d.MinValueJson) is { } tmin && t < tmin) throw bad;
                if (TimeOfDay(d.MaxValueJson) is { } tmax && t > tmax) throw bad;
                break;
            case "DECIMAL":
                if (!decimal.TryParse(v.ValueKind == JsonValueKind.String ? v.GetString() : v.GetRawText(), NumberStyles.Number, CultureInfo.InvariantCulture, out _)) throw bad;
                break;
            case "STRING":
                if (v.ValueKind != JsonValueKind.String) throw bad;
                // The sign-in lists (ADR 0048): known words only, at least one.
                SignInIdentity.CheckList(d.Key, v.GetString()!);
                break;
            default:
                if (v.ValueKind is JsonValueKind.Object or JsonValueKind.Array) throw bad;
                break;
        }
    }

    private static int? Int(string? json) => json is null ? null
        : int.TryParse(json.Trim('"'), NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : null;

    private static TimeSpan? TimeOfDay(string? json) =>
        json is not null && TimeRegex().IsMatch(json.Trim('"')) && TimeSpan.TryParseExact(json.Trim('"'), @"hh\:mm", CultureInfo.InvariantCulture, out var t) ? t : null;

    [GeneratedRegex("^[0-2][0-9]:[0-5][0-9]$")]
    private static partial Regex TimeRegex();

    // ---------- numbering ----------

    private const string Numbering = "cfg.numbering.manage";

    private sealed record SequenceRow(long NumberSequenceDefinitionId, string SequenceKey, string Pattern, string ScopeLevel, string PeriodBasis,
        string GapPolicy, int? MinWidth, bool IsActive, byte[] RowVersion);

    private static async Task<IResult> ListSequencesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Numbering);
        var rows = await u.Connection.QueryAsync<SequenceRow>(new CommandDefinition(
            "SELECT NumberSequenceDefinitionId, SequenceKey, Pattern, ScopeLevel, PeriodBasis, GapPolicy, MinWidth, IsActive, RowVersion FROM cfg.NumberSequenceDefinition ORDER BY SequenceKey;",
            cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = rows.Select(r => new
            {
                sequenceKey = r.SequenceKey, pattern = r.Pattern, scopeLevel = r.ScopeLevel, periodBasis = r.PeriodBasis, gapPolicy = r.GapPolicy,
                minWidth = r.MinWidth, isActive = r.IsActive, etag = ETags.Of(r.RowVersion), example = Render(r.Pattern, 1, 2026),
            }),
        });
    }

    private static async Task<IResult> CreateSequenceAsync(SequenceRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var key = body.SequenceKey?.Trim();
        if (string.IsNullOrEmpty(key) || key.Length > 50) throw ApiProblemException.Invalid("V-PLT-10", "Enter a sequence key.");
        var scope = body.ScopeLevel ?? "TENANT";
        var period = body.PeriodBasis ?? "CALENDAR_YEAR";
        var gaps = body.GapPolicy ?? "GAP_FREE";
        CheckSequence(key, body.Pattern, scope, period, gaps, body.MinWidth);
        await using var u = await BoundUser.OpenAsync(http, db, Numbering);
        try
        {
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT cfg.NumberSequenceDefinition (TenantId, SequenceKey, Pattern, ScopeLevel, PeriodBasis, GapPolicy, MinWidth, IsActive)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @key, @pattern, @scope, @period, @gaps, @w, @active);
                """, new { key, pattern = body.Pattern, scope, period, gaps, w = body.MinWidth, active = body.IsActive ?? true }, cancellationToken: http.RequestAborted));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "DUPLICATE", "A sequence with this key already exists.");
        }
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("NUMBER_SEQUENCE_CREATED", "CONFIG", "cfg.NumberSequenceDefinition", null,
            AfterJson: JsonSerializer.Serialize(new { key, pattern = body.Pattern, scope, period, gaps })), http.RequestAborted);
        return Results.Created($"/api/v1/number-sequences/{Uri.EscapeDataString(key)}", new { sequenceKey = key });
    }

    private static async Task<IResult> PatchSequenceAsync(string key, SequenceRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, Numbering);
        var row = await u.Connection.QuerySingleOrDefaultAsync<SequenceRow>(new CommandDefinition(
            "SELECT NumberSequenceDefinitionId, SequenceKey, Pattern, ScopeLevel, PeriodBasis, GapPolicy, MinWidth, IsActive, RowVersion FROM cfg.NumberSequenceDefinition WHERE SequenceKey = @key;",
            new { key }, cancellationToken: http.RequestAborted)) ?? throw ApiProblemException.NotFound();
        var pattern = body.Pattern ?? row.Pattern;
        var gaps = body.GapPolicy ?? row.GapPolicy;
        CheckSequence(row.SequenceKey, pattern, row.ScopeLevel, row.PeriodBasis, gaps, body.MinWidth ?? row.MinWidth);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE cfg.NumberSequenceDefinition SET Pattern = @pattern, GapPolicy = @gaps, MinWidth = COALESCE(@w, MinWidth), IsActive = COALESCE(@active, IsActive)
             WHERE NumberSequenceDefinitionId = @id AND RowVersion = @rv;
            """, new { pattern, gaps, w = body.MinWidth, active = body.IsActive, id = row.NumberSequenceDefinitionId, rv = expected }, cancellationToken: http.RequestAborted));
        if (n == 0) throw ETags.Conflict();
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("NUMBER_SEQUENCE_CHANGED", "CONFIG", "cfg.NumberSequenceDefinition",
            row.NumberSequenceDefinitionId, BeforeJson: JsonSerializer.Serialize(new { pattern = row.Pattern, gaps = row.GapPolicy, active = row.IsActive }),
            AfterJson: JsonSerializer.Serialize(new { pattern, gaps, active = body.IsActive ?? row.IsActive })), http.RequestAborted);
        return Results.NoContent();
    }

    private static IResult Preview(PreviewRequest body)
    {
        var scope = body.ScopeLevel ?? "TENANT";
        if (!PatternOk(body.Pattern, scope)) throw ApiProblemException.Invalid("V-PLT-10", "The pattern needs one {seq} or {seq:000} tag, and only {erp} (company scope), {yy} and {yyyy}.");
        return Results.Ok(new { examples = new[] { Render(body.Pattern!, 1, 2026), Render(body.Pattern!, 42, 2026), Render(body.Pattern!, 12345, 2027) } });
    }

    private static void CheckSequence(string key, string? pattern, string scope, string period, string gaps, int? minWidth)
    {
        if (scope is not ("TENANT" or "COMPANY") || period is not ("CALENDAR_YEAR" or "FISCAL_YEAR" or "NONE") || gaps is not ("GAP_FREE" or "ALLOW_GAPS"))
            throw ApiProblemException.Invalid("V-PLT-10", "Choose the scope, the period and the gap policy from the lists.");
        if (period == "FISCAL_YEAR" && scope != "COMPANY") throw ApiProblemException.Invalid("V-PLT-10", "A fiscal-year sequence is per company.");
        if (minWidth is < 1 or > 18) throw ApiProblemException.Invalid("V-PLT-10", "The minimum width is 1 to 18.");
        if ((key == "PROFORMA" || key.StartsWith("req:", StringComparison.Ordinal)) && gaps != "GAP_FREE")
            throw ApiProblemException.Invalid("V-PLT-10", "Request and proforma numbers are gap-free.");
        if (!PatternOk(pattern, scope))
            throw ApiProblemException.Invalid("V-PLT-10", "The pattern needs one {seq} or {seq:000} tag, and only {erp} (company scope), {yy} and {yyyy}.");
    }

    /// <summary>The rule of cfg.fn_NumberPatternOk (039): one {seq} or {seq:0…} tag (1 to 18 zeros), {erp} only for a company scope.</summary>
    internal static bool PatternOk(string? pattern, string scope)
    {
        if (string.IsNullOrEmpty(pattern) || pattern.Length > 100) return false;
        if (pattern.Split("{seq").Length - 1 != 1) return false;
        if (scope != "COMPANY" && pattern.Contains("{erp}", StringComparison.Ordinal)) return false;
        var rest = SeqTag().Replace(pattern.Replace("{erp}", "", StringComparison.Ordinal).Replace("{yyyy}", "", StringComparison.Ordinal)
            .Replace("{yy}", "", StringComparison.Ordinal), "", 1);
        return !rest.Contains('{', StringComparison.Ordinal) && !rest.Contains('}', StringComparison.Ordinal);
    }

    [GeneratedRegex(@"\{seq(?::0{1,18})?\}")]
    private static partial Regex SeqTag();

    internal static string Render(string pattern, long seq, int year) =>
        SeqTag().Replace(pattern.Replace("{yyyy}", year.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
                .Replace("{yy}", (year % 100).ToString("00", CultureInfo.InvariantCulture), StringComparison.Ordinal)
                .Replace("{erp}", "ERP01", StringComparison.Ordinal),
            m => m.Value.Length > 5 ? seq.ToString(new string('0', m.Value.Length - 6), CultureInfo.InvariantCulture) : seq.ToString(CultureInfo.InvariantCulture), 1);

    private static async Task<IResult> IssuesAsync(string key, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "limit", "cursor");
        var limit = Query.Limit(http.Request);
        var before = refs.AfterId("issues:" + key, http.Request.Query["cursor"]);
        await using var u = await BoundUser.OpenAsync(http, db, Numbering);
        var rows = (await u.Connection.QueryAsync<(long Id, string Number, long SeqValue, string Status, string? Reason, DateTime CreatedAt, string PeriodKey)>(
            new CommandDefinition(
                """
                SELECT TOP (@take) i.NumberIssueId, i.IssuedNumber, i.SeqValue, i.Status, i.VoidReason, i.CreatedAt, s.PeriodKey
                FROM cfg.NumberIssue AS i
                JOIN cfg.NumberSequence AS s ON s.NumberSequenceId = i.SequenceId
                JOIN cfg.NumberSequenceDefinition AS d ON d.NumberSequenceDefinitionId = s.DefinitionId
                WHERE d.SequenceKey = @key AND (@before IS NULL OR i.NumberIssueId < @before)
                ORDER BY i.NumberIssueId DESC;
                """, new { key, take = limit + 1, before }, cancellationToken: http.RequestAborted))).ToList();
        var page = rows.Take(limit).ToList();
        return Results.Ok(new
        {
            items = page.Select(r => new { id = refs.Cursor("issue", r.Id), number = r.Number, seqValue = r.SeqValue, period = r.PeriodKey, status = r.Status,
                voidReason = r.Reason, issuedAt = r.CreatedAt }),
            nextCursor = rows.Count > limit ? refs.Cursor("issues:" + key, page[^1].Id) : null,
        });
    }

    private static async Task<IResult> VoidAsync(string reference, VoidRequest body, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        if (string.IsNullOrWhiteSpace(body.Reason)) throw ApiProblemException.Invalid("V-PLT-10", "Give the reason for voiding the number.");
        var id = refs.AfterId("issue", reference) ?? throw ApiProblemException.NotFound();
        await using var u = await BoundUser.OpenAsync(http, db, Numbering);
        try
        {
            await u.Connection.ExecuteAsync(new CommandDefinition("cfg.usp_VoidNumber", new { NumberIssueId = id, Reason = body.Reason.Trim() },
                commandType: System.Data.CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
        }
        catch (SqlException ex) when (ex.Number == 50032)
        {
            throw new ApiProblemException(409, "STATE_CONFLICT", "The number is not issued, or it belongs to another account.");
        }
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("NUMBER_VOIDED", "CONFIG", "cfg.NumberIssue", id,
            AfterJson: JsonSerializer.Serialize(new { reason = body.Reason.Trim() })), http.RequestAborted);
        return Results.NoContent();
    }

    // ---------- audit ----------

    private sealed record AuditRow(long AuditLogId, DateTime OccurredAt, string ActorType, Guid? ActorId, string Action, string Category, string Severity,
        string? EntityType, long? EntityId, string? BeforeJson, string? AfterJson, string? IpAddress, string Result, Guid? CorrelationId);

    /// <summary>The categories the user may see: audit.view for all but TREASURY, audit.view.treasury for TREASURY (BR-PLT-008).</summary>
    private static async Task<string[]> VisibleCategoriesAsync(BoundUser u, CancellationToken ct)
    {
        var p = await u.PermissionsAsync(ct);
        var cats = new List<string>();
        if (p.Contains("audit.view")) cats.AddRange(["SECURITY", "CONFIG", "IDENTITY_ACCESS", "PLATFORM", "SYSTEM"]);
        if (p.Contains("audit.view.treasury")) cats.Add("TREASURY");
        if (cats.Count == 0) throw ApiProblemException.Forbidden();
        return [.. cats];
    }

    private static async Task<IResult> AuditAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "limit", "cursor", "category", "severity", "action", "actor", "from", "to");
        var limit = Query.Limit(http.Request);
        var before = refs.AfterId("audit", http.Request.Query["cursor"]);
        var (from, to) = (DateArg(http, "from"), DateArg(http, "to"));
        string? Arg(string n) => http.Request.Query[n].ToString() is { Length: > 0 } v ? v : null;
        Guid? actor = Arg("actor") is { } a ? Guid.TryParse(a, out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "actor is an id.") : null;
        await using var u = await BoundUser.OpenAsync(http, db);
        var cats = await VisibleCategoriesAsync(u, http.RequestAborted);
        if (Arg("category") is { } cat)
        {
            if (!cats.Contains(cat)) throw ApiProblemException.Forbidden();
            cats = [cat];
        }
        var rows = (await u.Connection.QueryAsync<AuditRow>(new CommandDefinition(
            """
            SELECT TOP (@take) AuditLogId, OccurredAt, ActorType, ActorId, Action, Category, Severity, EntityType, EntityId, BeforeJson, AfterJson,
                   IpAddress, Result, CorrelationId
            FROM aud.AuditLog
            WHERE Category IN @cats AND (@before IS NULL OR AuditLogId < @before) AND (@sev IS NULL OR Severity = @sev)
              AND (@act IS NULL OR Action = @act) AND (@actor IS NULL OR ActorId = @actor)
              AND (@from IS NULL OR OccurredAt >= @from) AND (@to IS NULL OR OccurredAt < DATEADD(DAY, 1, @to))
            ORDER BY AuditLogId DESC;
            """, new { take = limit + 1, cats, before, sev = Arg("severity"), act = Arg("action"), actor, from, to }, cancellationToken: http.RequestAborted))).ToList();
        var page = rows.Take(limit).ToList();
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("AUDIT_VIEWED", "SECURITY", "aud.AuditLog", null,
            AfterJson: JsonSerializer.Serialize(new { categories = cats, from, to, rows = page.Count })), http.RequestAborted);
        return Results.Ok(new
        {
            items = page.Select(r => new
            {
                id = refs.Cursor("audit-row", r.AuditLogId), occurredAt = r.OccurredAt, actorType = r.ActorType, actorId = r.ActorId, action = r.Action,
                category = r.Category, severity = r.Severity, entityType = r.EntityType, before = Json(r.BeforeJson), after = Json(r.AfterJson),
                ipAddress = r.IpAddress, result = r.Result, correlationId = r.CorrelationId,
            }),
            nextCursor = rows.Count > limit ? refs.Cursor("audit", page[^1].AuditLogId) : null,
        });
    }

    /// <summary>A CSV of the audit rows of a period, with audit.export and a fresh code; audited HIGH (AC-PLT-14).</summary>
    private static async Task<IResult> AuditExportAsync(AuditExportRequest body, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, TimeProvider clock)
    {
        DateOnly? Parse(string? s) => s is null ? null : DateOnly.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
            : throw ApiProblemException.Invalid("VALIDATION_FAILED", "Dates are YYYY-MM-DD.");
        var from = Parse(body.From) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the first day.");
        var to = Parse(body.To) ?? DateOnly.FromDateTime(clock.GetUtcNow().UtcDateTime);
        if (to < from || to.DayNumber - from.DayNumber > 366) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Export one year at most.");
        await using (var check = await BoundUser.OpenAsync(http, db, "audit.export")) { }
        await StepUp.RequireAsync(http, db, keys, clock, body.StepUpCode);
        await using var u = await BoundUser.OpenAsync(http, db, "audit.export");
        var cats = await VisibleCategoriesAsync(u, http.RequestAborted);
        if (body.Category is { } cat) cats = cats.Contains(cat) ? [cat] : throw ApiProblemException.Forbidden();
        var rows = await u.Connection.QueryAsync<AuditRow>(new CommandDefinition(
            """
            SELECT AuditLogId, OccurredAt, ActorType, ActorId, Action, Category, Severity, EntityType, EntityId, BeforeJson, AfterJson, IpAddress, Result, CorrelationId
            FROM aud.AuditLog
            WHERE Category IN @cats AND OccurredAt >= @from AND OccurredAt < DATEADD(DAY, 1, @to)
            ORDER BY AuditLogId;
            """, new { cats, from = from.ToDateTime(TimeOnly.MinValue), to = to.ToDateTime(TimeOnly.MinValue) }, cancellationToken: http.RequestAborted));
        var csv = new StringBuilder("occurredAt,actorType,actorId,action,category,severity,entityType,result,ipAddress,before,after,correlationId\r\n");
        var count = 0;
        foreach (var r in rows)
        {
            count++;
            csv.AppendJoin(',', Csv(r.OccurredAt.ToString("O", CultureInfo.InvariantCulture)), Csv(r.ActorType), Csv(r.ActorId?.ToString()), Csv(r.Action),
                Csv(r.Category), Csv(r.Severity), Csv(r.EntityType), Csv(r.Result), Csv(r.IpAddress), Csv(r.BeforeJson), Csv(r.AfterJson), Csv(r.CorrelationId?.ToString()));
            csv.Append("\r\n");
        }
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("AUDIT_EXPORTED", "SECURITY", "aud.AuditLog", null,
            AfterJson: JsonSerializer.Serialize(new { from, to, categories = cats, rows = count }), Severity: "HIGH"), http.RequestAborted);
        return Results.File(Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(csv.ToString())).ToArray(), "text/csv; charset=utf-8",
            $"audit-{from:yyyyMMdd}-{to:yyyyMMdd}.csv");
    }

    /// <summary>A CSV field; a leading =, +, - or @ is prefixed with ' so a spreadsheet never runs it as a formula.</summary>
    private static string Csv(string? v)
    {
        if (string.IsNullOrEmpty(v)) return "";
        if (v[0] is '=' or '+' or '-' or '@') v = "'" + v;
        return "\"" + v.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
    }

    private static DateTime? DateArg(HttpContext http, string name)
    {
        var v = http.Request.Query[name].ToString();
        if (v.Length == 0) return null;
        return DateOnly.TryParseExact(v, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d.ToDateTime(TimeOnly.MinValue)
            : throw new ApiProblemException(400, "MALFORMED_REQUEST", $"{name} is a date YYYY-MM-DD.");
    }

    // ---------- jobs ----------

    private static async Task<IResult> JobsAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, "cfg.jobs.view");
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT r.JobKey AS jobKey, r.Status AS lastStatus, r.StartedAt AS lastStartedAt, r.FinishedAt AS lastFinishedAt, r.DurationMs AS lastDurationMs,
                   r.ResultSummary AS lastResult, r.ErrorMessage AS lastError, r.NextRetryAt AS nextRetryAt,
                   (SELECT MAX(s.FinishedAt) FROM cfg.JobRun AS s WHERE s.JobKey = r.JobKey AND s.Status = 'SUCCEEDED') AS lastSucceededAt
            FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY JobKey ORDER BY StartedAt DESC, JobRunId DESC) AS rn FROM cfg.JobRun) AS r
            WHERE r.rn = 1 ORDER BY r.JobKey;
            """, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    private static async Task<IResult> JobRunsAsync(string jobKey, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "limit", "cursor");
        var limit = Query.Limit(http.Request);
        var before = refs.AfterId("runs:" + jobKey, http.Request.Query["cursor"]);
        await using var u = await BoundUser.OpenAsync(http, db, "cfg.jobs.view");
        var rows = (await u.Connection.QueryAsync<(long Id, string Status, string TriggerKind, int AttemptNo, DateTime StartedAt, DateTime? FinishedAt, int? DurationMs, string? ResultSummary, string? ErrorMessage)>(
            new CommandDefinition(
                """
                SELECT TOP (@take) JobRunId, Status, TriggerKind, AttemptNo, StartedAt, FinishedAt, DurationMs, ResultSummary, ErrorMessage
                FROM cfg.JobRun WHERE JobKey = @jobKey AND (@before IS NULL OR JobRunId < @before) ORDER BY JobRunId DESC;
                """, new { take = limit + 1, jobKey, before }, cancellationToken: http.RequestAborted))).ToList();
        var page = rows.Take(limit).ToList();
        return Results.Ok(new
        {
            items = page.Select(r => new { status = r.Status, triggerKind = r.TriggerKind, attemptNo = r.AttemptNo, startedAt = r.StartedAt, finishedAt = r.FinishedAt,
                durationMs = r.DurationMs, result = r.ResultSummary, error = r.ErrorMessage }),
            nextCursor = rows.Count > limit ? refs.Cursor("runs:" + jobKey, page[^1].Id) : null,
        });
    }
}

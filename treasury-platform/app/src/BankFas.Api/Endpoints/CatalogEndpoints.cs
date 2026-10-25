using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record CatalogItemRequest(string? Code, string? NameAr, string? NameEn, string? Description, int? SortOrder, bool? IsActive,
    string? ExternalCode, Dictionary<string, JsonElement>? Fields, bool? ConfirmImpact);
public sealed record CatalogOrderRequest(List<string>? Items);
public sealed record CatalogLinksRequest(List<string>? Codes);
public sealed record TenantCurrenciesRequest(List<string>? Codes);

/// <summary>
/// The tenant's catalogues (SCR-CAT-01 to 04, FR-CAT-001 to 023, SVC-07 and SVC-08): one generic surface over the
/// cat.* tables of a closed registry. Every item has the common fields of FR-CAT-001 and the fields of its kind;
/// items are addressed by an opaque reference (catalogue rows have no PublicId). The database holds the protection:
/// codes, system and locked flags never change (060), system rows come only from the seed packs, and nothing is
/// deleted (FR-CAT-004). Every change is audited with its old and new values (FR-CAT-025). Table and column names
/// come from the registry below, never from the request; values are parameters.
/// </summary>
public static partial class CatalogEndpoints
{
    private const string View = "cat.view";
    private const string General = "cat.manage.general";
    private const string Financial = "cat.manage.financial";

    private enum FieldType { Bool, Int, Text, Json, Ref }

    /// <summary>A field of a kind: its JSON name, its column, its type, and for a Ref the kind (or global table) it names by code.</summary>
    private sealed record Field(string Name, string Column, FieldType Type, int MaxLength = 0, string? RefKind = null, bool HighImpact = false);

    /// <summary>A catalogue kind: the URL segment, the table and its key, the permission that manages it, and its own fields.</summary>
    private sealed record Kind(string Segment, string Table, string IdColumn, string Manage, Field[] Fields, string? ListFilter = null);

    private static readonly Field[] None = [];

    private static readonly Dictionary<string, Kind> Kinds = new Kind[]
    {
        new("institution-types", "cat.InstitutionType", "InstitutionTypeId", General, [new("requiresParty", "RequiresParty", FieldType.Bool)]),
        new("account-types", "cat.AccountType", "AccountTypeId", General, [new("isVirtual", "IsVirtual", FieldType.Bool)]),
        new("legal-entity-types", "cat.LegalEntityType", "LegalEntityTypeId", General,
            [new("abbreviationAr", "AbbreviationAr", FieldType.Text, 30), new("abbreviationEn", "AbbreviationEn", FieldType.Text, 30),
             new("country", "CountryId", FieldType.Ref, RefKind: "ref.Country"), new("defaultBodyTypes", "DefaultBodyTypes", FieldType.Text, 65)]),
        new("document-types", "cat.DocumentType", "DocumentTypeId", General,
            [new("appliesTo", "AppliesTo", FieldType.Text, 72), new("requiresExpiry", "RequiresExpiry", FieldType.Bool),
             new("isSensitive", "IsSensitive", FieldType.Bool), new("allowedMime", "AllowedMime", FieldType.Json),
             new("maxSizeMb", "MaxSizeMb", FieldType.Int), new("retentionYears", "RetentionYears", FieldType.Int), new("maxAgeDays", "MaxAgeDays", FieldType.Int)]),
        new("positions", "cat.Position", "PositionId", General,
            [new("applicableBodyTypes", "ApplicableBodyTypes", FieldType.Text, 65), new("isSingleHolder", "IsSingleHolder", FieldType.Bool)]),
        new("power-types", "cat.PowerType", "PowerTypeId", General,
            [new("category", "Category", FieldType.Text, 14), new("allowsCeiling", "AllowsCeiling", FieldType.Bool)]),
        new("operation-types", "cat.OperationType", "OperationTypeId", General,
            [new("supportsCeiling", "SupportsCeiling", FieldType.Bool), new("operationGroup", "OperationGroup", FieldType.Text, 14)]),
        new("product-categories", "cat.ProductCategory", "ProductCategoryId", Financial, None),
        new("products", "cat.Product", "ProductId", Financial,
            [new("category", "ProductCategoryId", FieldType.Ref, RefKind: "product-categories"), new("productFamily", "ProductFamily", FieldType.Text, 15),
             new("consumesCreditLimit", "ConsumesCreditLimit", FieldType.Bool, HighImpact: true), new("isTradeFinance", "IsTradeFinance", FieldType.Bool),
             new("compliance", "Compliance", FieldType.Text, 12), new("variantGroupCode", "VariantGroupCode", FieldType.Text, 40)]),
        new("fee-types", "cat.FeeType", "FeeTypeId", Financial,
            [new("nature", "Nature", FieldType.Text, 18, HighImpact: true), new("calcHint", "CalcHint", FieldType.Text, 11)]),
        new("financing-types", "cat.FinancingType", "FinancingTypeId", Financial,
            [new("isIslamic", "IsIslamic", FieldType.Bool), new("returnLabel", "ReturnLabel", FieldType.Text, 10)]),
        new("facility-types", "cat.FacilityType", "FacilityTypeId", Financial, [new("compliance", "Compliance", FieldType.Text, 12)]),
        new("limit-types", "cat.LimitType", "LimitTypeId", Financial,
            [new("kind", "Kind", FieldType.Text, 10), new("parent", "ParentLimitTypeId", FieldType.Ref, RefKind: "limit-types"),
             new("defaultDistributionMode", "DefaultDistributionMode", FieldType.Text, 13), new("defaultIsRevolving", "DefaultIsRevolving", FieldType.Bool)]),
        new("collateral-types", "cat.CollateralType", "CollateralTypeId", Financial, [new("structureKind", "StructureKind", FieldType.Text, 20)]),
        new("obligation-types", "cat.ObligationType", "ObligationTypeId", Financial,
            [new("family", "Family", FieldType.Text, 23), new("measureKind", "MeasureKind", FieldType.Text, 18),
             new("isQualitative", "IsQualitative", FieldType.Bool), new("defaultDeadlineBasis", "DefaultDeadlineBasis", FieldType.Text, 21),
             new("defaultUnit", "DefaultUnit", FieldType.Text, 30)]),
        new("lookup-lists", "cat.LookupList", "LookupListId", General,
            [new("allowTenantItems", "AllowTenantItems", FieldType.Bool), new("attributeSchema", "AttributeSchema", FieldType.Json)]),
    }.ToDictionary(k => k.Segment, StringComparer.Ordinal);

    /// <summary>The items of one lookup list: a kind of its own, filtered by the list.</summary>
    private static Kind LookupItems(int listId) => new("lookup-items", "cat.LookupItem", "LookupItemId", General,
        [new("status", "Status", FieldType.Text, 10), new("attributes", "Attributes", FieldType.Json)],
        ListFilter: "LookupListId = " + listId.ToString(CultureInfo.InvariantCulture));

    /// <summary>The link tables of SVC-08: an item of the kind and the kind whose codes it allows.</summary>
    private sealed record Link(string Segment, string Kind, string Table, string OwnerColumn, string TargetKind, string TargetColumn);

    private static readonly Link[] Links =
    [
        new("fee-types", "products", "cat.ProductFeeType", "ProductId", "fee-types", "FeeTypeId"),
        new("financing-types", "products", "cat.ProductFinancingType", "ProductId", "financing-types", "FinancingTypeId"),
        new("products", "limit-types", "cat.LimitTypeProduct", "LimitTypeId", "products", "ProductId"),
        new("power-types", "operation-types", "cat.OperationTypePowerType", "OperationTypeId", "power-types", "PowerTypeId"),
    ];

    [GeneratedRegex("^[A-Z][A-Z0-9_]{1,79}$", RegexOptions.CultureInvariant)]
    private static partial Regex CodePattern();

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/catalogs", KindsAsync);
        api.MapGet("/catalogs/{kind}", ListAsync);
        api.MapPost("/catalogs/{kind}/items", CreateAsync);
        api.MapPatch("/catalogs/{kind}/items/{reference}", PatchAsync);
        api.MapPut("/catalogs/{kind}/order", OrderAsync);
        api.MapGet("/catalogs/{kind}/items/{reference}/usage", UsageAsync);
        api.MapGet("/catalogs/{kind}/items/{reference}/{link}", LinksAsync);
        api.MapPut("/catalogs/{kind}/items/{reference}/{link}", SetLinksAsync);
        api.MapGet("/lookups/{list}", LookupListAsync);
        api.MapPost("/lookups/{list}/items", LookupCreateAsync);
        api.MapPatch("/lookups/{list}/items/{reference}", LookupPatchAsync);
        api.MapPut("/lookups/{list}/order", LookupOrderAsync);
        api.MapGet("/countries", CountriesAsync);
        api.MapGet("/currencies", CurrenciesAsync);
        api.MapGet("/tenant-currencies", TenantCurrenciesAsync);
        api.MapPut("/tenant-currencies", SetTenantCurrenciesAsync);
        MapCsv(api);
    }

    private static Kind KindOf(string segment) => Kinds.TryGetValue(segment, out var k) ? k : throw ApiProblemException.NotFound();

    private static string Where(Kind k, string? more = null) =>
        string.Join(" AND ", new[] { k.ListFilter, more }.Where(s => s is not null)) is { Length: > 0 } w ? " WHERE " + w : "";

    // ---------- reading ----------

    private static async Task<IResult> KindsAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var perms = await u.PermissionsAsync(http.RequestAborted);
        return Results.Ok(new
        {
            items = Kinds.Values.Where(k => k.Segment != "lookup-lists").Select(k => new { kind = k.Segment, canManage = perms.Contains(k.Manage) }),
            lookups = perms.Contains(General),
        });
    }

    private static async Task<IReadOnlyList<IDictionary<string, object?>>> RowsAsync(SqlConnection c, SqlTransaction? tx, Kind k, bool includeInactive,
        string? q, CancellationToken ct, long? onlyId = null)
    {
        var cols = string.Join(", ", new[] { k.IdColumn, "Code", "NameAr", "NameEn", "Description", "IsActive", "IsSystem", "IsLocked", "SortOrder",
            "ExternalCode", "SeedKey", "RowVersion" }.Concat(k.Fields.Select(f => f.Column)).Select(Q));
        var filters = new List<string>();
        if (!includeInactive) filters.Add("IsActive = 1");
        if (!string.IsNullOrWhiteSpace(q)) filters.Add("(Code LIKE @q OR NameAr LIKE @q OR NameEn LIKE @q)");
        if (onlyId is not null) filters.Add($"{Q(k.IdColumn)} = @id");
        var sql = $"SELECT {cols} FROM {k.Table}{Where(k, filters.Count > 0 ? string.Join(" AND ", filters) : null)} ORDER BY SortOrder, Code;";
        var rows = await c.QueryAsync(new CommandDefinition(sql, new { q = "%" + q?.Trim() + "%", id = onlyId }, tx, cancellationToken: ct));
        return [.. rows.Cast<IDictionary<string, object?>>()];
    }

    /// <summary>The code of each referenced row, for the Ref fields of the rows (one query per referenced kind).</summary>
    private static async Task<Dictionary<(string, long), string>> RefCodesAsync(SqlConnection c, SqlTransaction? tx, Kind k,
        IReadOnlyList<IDictionary<string, object?>> rows, CancellationToken ct)
    {
        var map = new Dictionary<(string, long), string>();
        foreach (var f in k.Fields.Where(f => f.Type == FieldType.Ref))
        {
            var ids = rows.Select(r => r[f.Column]).Where(v => v is not null).Select(Convert.ToInt64).Distinct().ToArray();
            if (ids.Length == 0) continue;
            var (table, idCol, codeCol) = RefTarget(f.RefKind!);
            var found = await c.QueryAsync<(long Id, string Code)>(new CommandDefinition(
                $"SELECT CAST({Q(idCol)} AS BIGINT), {Q(codeCol)} FROM {table} WHERE {Q(idCol)} IN @ids;", new { ids }, tx, cancellationToken: ct));
            foreach (var (id, code) in found) map[(f.RefKind!, id)] = code;
        }
        return map;
    }

    private static (string Table, string IdColumn, string CodeColumn) RefTarget(string refKind) => refKind switch
    {
        "ref.Country" => ("ref.Country", "CountryId", "Iso2"),
        "ref.Currency" => ("ref.Currency", "CurrencyId", "Code"),
        _ => (KindOf(refKind).Table, KindOf(refKind).IdColumn, "Code"),
    };

    private static object Shape(Kind k, IDictionary<string, object?> r, OpaqueRefs refs, int tenantId, Dictionary<(string, long), string> codes)
    {
        var fields = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var f in k.Fields)
        {
            var v = r[f.Column];
            fields[f.Name] = f.Type switch
            {
                FieldType.Ref => v is null ? null : codes.GetValueOrDefault((f.RefKind!, Convert.ToInt64(v, CultureInfo.InvariantCulture))),
                FieldType.Json => v is string s ? JsonDocument.Parse(s).RootElement.Clone() : null,
                _ => v,
            };
        }
        return new
        {
            id = refs.ItemRef(tenantId, k.Segment, Convert.ToInt64(r[k.IdColumn], CultureInfo.InvariantCulture)),
            code = r["Code"], nameAr = r["NameAr"], nameEn = r["NameEn"], description = r["Description"], isActive = r["IsActive"],
            isSystem = r["IsSystem"], isLocked = r["IsLocked"], sortOrder = r["SortOrder"], externalCode = r["ExternalCode"],
            fromDefaults = r["SeedKey"] is not null, etag = ETags.Of((byte[])r["RowVersion"]!), fields,
        };
    }

    private static async Task<IResult> ListAsync(string kind, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
        await ListKindAsync(KindOf(kind), http, db, refs, null);

    private static async Task<IResult> ListKindAsync(Kind k, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, Func<BoundUser, Task<Kind>>? resolve)
    {
        Query.Allow(http.Request, "includeInactive", "q");
        var includeInactive = string.Equals(http.Request.Query["includeInactive"], "true", StringComparison.OrdinalIgnoreCase);
        await using var u = await BoundUser.OpenAsync(http, db, View);
        if (resolve is not null) k = await resolve(u);
        if (includeInactive) await u.RequireAsync(k.Manage, http.RequestAborted);   // the selection lists show active items only (FR-CAT-004)
        var rows = await RowsAsync(u.Connection, null, k, includeInactive, http.Request.Query["q"], http.RequestAborted);
        var codes = await RefCodesAsync(u.Connection, null, k, rows, http.RequestAborted);
        return Results.Ok(new { kind = k.Segment, items = rows.Select(r => Shape(k, r, refs, u.TenantId, codes)) });
    }

    // ---------- writing ----------

    /// <summary>The column values of the request's fields, checked against the kind; a Ref names its target by code.</summary>
    private static async Task<Dictionary<string, object?>> FieldValuesAsync(BoundUser u, SqlTransaction tx, Kind k, Dictionary<string, JsonElement>? fields,
        CancellationToken ct)
    {
        var values = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (fields is null) return values;
        foreach (var (name, v) in fields)
        {
            var f = k.Fields.FirstOrDefault(x => x.Name == name)
                ?? throw ApiProblemException.Invalid("UNKNOWN_FIELD", "A field is not one of this catalogue.");
            values[f.Column] = v.ValueKind == JsonValueKind.Null ? null : f.Type switch
            {
                FieldType.Bool when v.ValueKind is JsonValueKind.True or JsonValueKind.False => v.GetBoolean(),
                FieldType.Int when v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) => i,
                FieldType.Text when v.ValueKind == JsonValueKind.String && v.GetString()!.Trim().Length <= f.MaxLength => v.GetString()!.Trim(),
                FieldType.Json => v.GetRawText(),
                FieldType.Ref when v.ValueKind == JsonValueKind.String => await RefIdAsync(u, tx, f.RefKind!, v.GetString()!, ct),
                _ => throw ApiProblemException.Invalid("VALIDATION_FAILED", "A value is not valid."),
            };
        }
        return values;
    }

    private static async Task<object> RefIdAsync(BoundUser u, SqlTransaction tx, string refKind, string code, CancellationToken ct)
    {
        var (table, idCol, codeCol) = RefTarget(refKind);
        return await u.Connection.ExecuteScalarAsync<object?>(new CommandDefinition(
            $"SELECT {Q(idCol)} FROM {table} WHERE {Q(codeCol)} = @code;", new { code }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("REFERENCE_NOT_FOUND", "A referenced item does not exist.");
    }

    private static string? Names(string? nameAr, string? nameEn, bool required)
    {
        if (nameAr is not null && (nameAr.Trim().Length is 0 or > 200)) return "Enter the Arabic name (up to 200 characters).";
        if (nameEn is not null && nameEn.Trim().Length > 200) return "The English name is up to 200 characters.";
        return required && string.IsNullOrWhiteSpace(nameAr) ? "Enter the Arabic name (up to 200 characters)." : null;
    }

    private static async Task<IResult> CreateAsync(string kind, CatalogItemRequest body, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
        await CreateKindAsync(KindOf(kind), body, http, db, refs, null);

    private static async Task<IResult> CreateKindAsync(Kind k, CatalogItemRequest body, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs,
        Func<BoundUser, SqlTransaction, Task<(Kind Kind, string Column, int Id)>>? scope)
    {
        var code = body.Code?.Trim().ToUpperInvariant();
        if (code is null || !CodePattern().IsMatch(code))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The code is 2 to 80 capital letters, digits and _, starting with a letter.");
        if (Names(body.NameAr, body.NameEn, true) is { } error) throw ApiProblemException.Invalid("VALIDATION_FAILED", error);
        await using var u = await BoundUser.OpenAsync(http, db, View);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var extra = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (scope is not null)
        {
            var (scoped, column, listId) = await scope(u, tx);
            k = scoped;
            extra[column] = listId;
        }
        await u.RequireAsync(k.Manage, http.RequestAborted);
        var values = await FieldValuesAsync(u, tx, k, body.Fields, http.RequestAborted);
        foreach (var (col, v) in extra) values[col] = v;
        await CheckVariantGroupAsync(u, tx, k, values, null, http.RequestAborted);
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                $"SELECT COUNT(*) FROM {k.Table}{Where(k, "Code = @code")};", new { code }, tx, cancellationToken: http.RequestAborted)) > 0)
            throw new ApiProblemException(409, "CODE_TAKEN", "An item with this code already exists.");
        var cols = new List<string> { "TenantId", "Code", "NameAr", "NameEn", "Description", "SortOrder", "ExternalCode", "CreatedBy" };
        var p = new DynamicParameters(new
        {
            code, ar = body.NameAr!.Trim(), en = body.NameEn?.Trim(), d = body.Description, sort = body.SortOrder ?? 0, ext = body.ExternalCode?.Trim(),
        });
        var vals = new List<string> { "CAST(SESSION_CONTEXT(N'TenantId') AS INT)", "@code", "@ar", "@en", "@d", "@sort", "@ext", "CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)" };
        var i = 0;
        foreach (var (col, v) in values)
        {
            cols.Add(col); vals.Add("@f" + i.ToString(CultureInfo.InvariantCulture)); p.Add("@f" + i.ToString(CultureInfo.InvariantCulture), v); i++;
        }
        var id = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            $"DECLARE @o TABLE (Id BIGINT); INSERT {k.Table} ({string.Join(", ", cols.Select(Q))}) OUTPUT CAST(inserted.{Q(k.IdColumn)} AS BIGINT) INTO @o " +
            $"VALUES ({string.Join(", ", vals)}); SELECT Id FROM @o;", p, tx, cancellationToken: http.RequestAborted));
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("CATALOG_ITEM_CREATED", "CONFIG", k.Table, id,
            AfterJson: JsonSerializer.Serialize(new { code, nameAr = body.NameAr, nameEn = body.NameEn, fields = body.Fields })), http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/catalogs/{k.Segment}/items/{refs.ItemRef(u.TenantId, k.Segment, id)}",
            new { id = refs.ItemRef(u.TenantId, k.Segment, id), code });
    }

    /// <summary>FR-CAT-007: the products of one variant group differ in compliance (a conventional and a Murabaha letter of credit).</summary>
    private static async Task CheckVariantGroupAsync(BoundUser u, SqlTransaction tx, Kind k, Dictionary<string, object?> values, long? id, CancellationToken ct)
    {
        if (k.Segment != "products") return;
        (string? Group, string? Compliance)? current = id is null ? null : await u.Connection.QuerySingleAsync<(string? Group, string? Compliance)>(new CommandDefinition(
            "SELECT VariantGroupCode, Compliance FROM cat.Product WHERE ProductId = @id;", new { id }, tx, cancellationToken: ct));
        var group = values.TryGetValue("VariantGroupCode", out var g) ? g as string : current?.Group;
        var compliance = values.TryGetValue("Compliance", out var c) ? c as string : current?.Compliance;
        if (group is null) return;
        var clash = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM cat.Product WHERE VariantGroupCode = @group AND ISNULL(Compliance, '') = ISNULL(@compliance, '') AND ProductId <> ISNULL(@id, -1);",
            new { group, compliance, id }, tx, cancellationToken: ct));
        if (clash > 0) throw ApiProblemException.Invalid("VARIANT_TAKEN", "The variant group already has a product of this compliance.");
    }

    private static async Task<IResult> PatchAsync(string kind, string reference, CatalogItemRequest body, HttpContext http, SqlConnectionFactory db,
        OpaqueRefs refs) => await PatchKindAsync(KindOf(kind), reference, body, http, db, refs, null);

    private static async Task<IResult> PatchKindAsync(Kind k, string reference, CatalogItemRequest body, HttpContext http, SqlConnectionFactory db,
        OpaqueRefs refs, Func<BoundUser, Task<Kind>>? resolve)
    {
        var expected = ETags.Required(http.Request);
        if (body.Code is not null) throw ApiProblemException.Invalid("CODE_FIXED", "The code of an item does not change.");
        if (Names(body.NameAr, body.NameEn, false) is { } error) throw ApiProblemException.Invalid("VALIDATION_FAILED", error);
        await using var u = await BoundUser.OpenAsync(http, db, View);
        if (resolve is not null) k = await resolve(u);
        await u.RequireAsync(k.Manage, http.RequestAborted);
        var id = refs.ItemId(u.TenantId, k.Segment, reference) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var before = (await RowsAsync(u.Connection, tx, k, true, null, http.RequestAborted, id)).SingleOrDefault() ?? throw ApiProblemException.NotFound();
        if (body.IsActive == false && (bool)before["IsLocked"]!)
            throw new ApiProblemException(409, "ITEM_LOCKED", "A locked item stays active.");
        var values = await FieldValuesAsync(u, tx, k, body.Fields, http.RequestAborted);
        if (before["IsSystem"] is true && values.Count > 0 && k.Segment == "lookup-lists")
            throw new ApiProblemException(409, "ITEM_LOCKED", "A system list keeps its settings.");
        await CheckVariantGroupAsync(u, tx, k, values, id, http.RequestAborted);

        // FR-CAT-022: a flag with effect changes on a used item only when the treasury manager confirms it.
        var impact = k.Fields.Where(f => f.HighImpact && values.TryGetValue(f.Column, out var v) && !Equals(v, before[f.Column])).ToList();
        if (impact.Count > 0 && (await UsageCountsAsync(u.Connection, tx, k, id, http.RequestAborted)).Sum(x => x.Count) > 0)
        {
            var isTm = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM sec.UserRole AS ur JOIN sec.Role AS r ON r.RoleId = ur.RoleId AND r.Code = 'TM' AND r.IsActive = 1 WHERE ur.UserId = @u;",
                new { u = u.UserId }, tx, cancellationToken: http.RequestAborted)) > 0;
            if (body.ConfirmImpact != true || !isTm)
                throw new ApiProblemException(409, "IMPACT_CONFIRMATION_REQUIRED", "This item is in use: the treasury manager confirms a change of this flag.");
        }

        var sets = new List<string> { "UpdatedAt = SYSUTCDATETIME()", "UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)" };
        var p = new DynamicParameters(new { id, rv = expected });
        void Set(string column, object? value) { sets.Add($"{Q(column)} = @s{sets.Count}"); p.Add("@s" + (sets.Count - 1).ToString(CultureInfo.InvariantCulture), value); }
        if (body.NameAr is not null) Set("NameAr", body.NameAr.Trim());
        if (body.NameEn is not null) Set("NameEn", body.NameEn.Trim().Length == 0 ? null : body.NameEn.Trim());
        if (body.Description is not null) Set("Description", body.Description.Length == 0 ? null : body.Description);
        if (body.SortOrder is not null) Set("SortOrder", body.SortOrder);
        if (body.IsActive is not null) Set("IsActive", body.IsActive);
        if (body.ExternalCode is not null) Set("ExternalCode", body.ExternalCode.Trim().Length == 0 ? null : body.ExternalCode.Trim());
        foreach (var (col, v) in values) Set(col, v);
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            $"DECLARE @o TABLE (RowVersion BINARY(8)); UPDATE {k.Table} SET {string.Join(", ", sets)} OUTPUT inserted.RowVersion INTO @o " +
            $"WHERE {Q(k.IdColumn)} = @id AND RowVersion = @rv; SELECT RowVersion FROM @o;", p, tx, cancellationToken: http.RequestAborted))
            ?? throw ETags.Conflict();
        var after = (await RowsAsync(u.Connection, tx, k, true, null, http.RequestAborted, id)).Single();
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("CATALOG_ITEM_UPDATED", "CONFIG", k.Table, id,
            BeforeJson: AuditJson(before), AfterJson: AuditJson(after), Severity: impact.Count > 0 ? "HIGH" : "INFO"), http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    private static string AuditJson(IDictionary<string, object?> row) =>
        JsonSerializer.Serialize(row.Where(kv => kv.Key is not "RowVersion").ToDictionary(kv => kv.Key, kv => kv.Value));

    private static async Task<IResult> OrderAsync(string kind, CatalogOrderRequest body, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
        await OrderKindAsync(KindOf(kind), body, http, db, refs, null);

    /// <summary>FR-CAT-005: the order of the selection lists; the items given get 10, 20, 30 in that order.</summary>
    private static async Task<IResult> OrderKindAsync(Kind k, CatalogOrderRequest body, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs,
        Func<BoundUser, Task<Kind>>? resolve)
    {
        if (body.Items is not { Count: > 0 and <= 500 }) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Send the items in their new order.");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        if (resolve is not null) k = await resolve(u);
        await u.RequireAsync(k.Manage, http.RequestAborted);
        var ids = body.Items.Select(r => refs.ItemId(u.TenantId, k.Segment, r) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "An item is not of this catalogue.")).ToList();
        if (ids.Distinct().Count() != ids.Count) throw ApiProblemException.Invalid("VALIDATION_FAILED", "An item is given twice.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        for (var i = 0; i < ids.Count; i++)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                $"UPDATE {k.Table} SET SortOrder = @s, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE {Q(k.IdColumn)} = @id;",
                new { s = (i + 1) * 10, id = ids[i] }, tx, cancellationToken: http.RequestAborted));
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("CATALOG_REORDERED", "CONFIG", k.Table, null,
            AfterJson: JsonSerializer.Serialize(new { count = ids.Count })), http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    // ---------- where used (FR-CAT-006) ----------

    /// <summary>The rows that reference the item, per referencing table, from the foreign keys on its key column.</summary>
    private static async Task<IReadOnlyList<(string Table, int Count)>> UsageCountsAsync(SqlConnection c, SqlTransaction? tx, Kind k, long id, CancellationToken ct)
    {
        var refsTo = await c.QueryAsync<(string Schema, string Table, string Column)>(new CommandDefinition(
            """
            SELECT OBJECT_SCHEMA_NAME(fkc.parent_object_id), OBJECT_NAME(fkc.parent_object_id), pc.name
              FROM sys.foreign_key_columns AS fkc
              JOIN sys.columns AS rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
              JOIN sys.columns AS pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
             WHERE fkc.referenced_object_id = OBJECT_ID(@t) AND rc.name = @col AND fkc.parent_object_id <> fkc.referenced_object_id;
            """, new { t = k.Table, col = k.IdColumn }, tx, cancellationToken: ct));
        var counts = new List<(string, int)>();
        foreach (var (schema, table, column) in refsTo.Distinct())
        {
            var n = await c.ExecuteScalarAsync<int>(new CommandDefinition(
                $"SELECT COUNT(*) FROM {Q(schema)}.{Q(table)} WHERE {Q(column)} = @id;", new { id }, tx, cancellationToken: ct));
            if (n > 0) counts.Add(($"{schema}.{table}", n));
        }
        return counts;
    }

    private static async Task<IResult> UsageAsync(string kind, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var k = KindOf(kind);
        await using var u = await BoundUser.OpenAsync(http, db, k.Manage);
        var id = refs.ItemId(u.TenantId, k.Segment, reference) ?? throw ApiProblemException.NotFound();
        var counts = await UsageCountsAsync(u.Connection, null, k, id, http.RequestAborted);
        return Results.Ok(new { total = counts.Sum(x => x.Count), items = counts.Select(x => new { table = x.Table, count = x.Count }) });
    }

    // ---------- links (FR-CAT-010, FR-CAT-012, FR-CAT-019; SVC-08) ----------

    private static Link LinkOf(string kind, string link) =>
        Links.FirstOrDefault(l => l.Kind == kind && l.Segment == link) ?? throw ApiProblemException.NotFound();

    private static async Task<IResult> LinksAsync(string kind, string reference, string link, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var l = LinkOf(kind, link);
        var target = KindOf(l.TargetKind);
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var id = refs.ItemId(u.TenantId, kind, reference) ?? throw ApiProblemException.NotFound();
        var items = await u.Connection.QueryAsync<(string Code, string NameAr, string? NameEn, bool IsActive)>(new CommandDefinition(
            $"SELECT t.Code, t.NameAr, t.NameEn, t.IsActive FROM {l.Table} AS x JOIN {target.Table} AS t ON t.{Q(target.IdColumn)} = x.{Q(l.TargetColumn)} " +
            $"WHERE x.{Q(l.OwnerColumn)} = @id ORDER BY t.SortOrder, t.Code;", new { id }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = items.Select(i => new { code = i.Code, nameAr = i.NameAr, nameEn = i.NameEn, isActive = i.IsActive }) });
    }

    /// <summary>Replaces the allowed items: links not listed are removed, new ones added; an inactive item is not linked anew.</summary>
    private static async Task<IResult> SetLinksAsync(string kind, string reference, string link, CatalogLinksRequest body, HttpContext http,
        SqlConnectionFactory db, OpaqueRefs refs)
    {
        var l = LinkOf(kind, link);
        var owner = KindOf(kind);
        var target = KindOf(l.TargetKind);
        var codes = (body.Codes ?? []).Select(c => c.Trim().ToUpperInvariant()).ToList();
        if (codes.Distinct().Count() != codes.Count) throw ApiProblemException.Invalid("DUPLICATE_LINK", "An item is linked twice.");
        await using var u = await BoundUser.OpenAsync(http, db, owner.Manage);
        var id = refs.ItemId(u.TenantId, kind, reference) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var wanted = (await u.Connection.QueryAsync<(long Id, string Code, bool IsActive)>(new CommandDefinition(
            $"SELECT CAST({Q(target.IdColumn)} AS BIGINT), Code, IsActive FROM {target.Table} WHERE Code IN @codes;", new { codes = codes.DefaultIfEmpty("").ToArray() }, tx,
            cancellationToken: http.RequestAborted))).ToList();
        if (wanted.Count != codes.Count) throw ApiProblemException.Invalid("REFERENCE_NOT_FOUND", "A referenced item does not exist.");
        var current = (await u.Connection.QueryAsync<long>(new CommandDefinition(
            $"SELECT CAST({Q(l.TargetColumn)} AS BIGINT) FROM {l.Table} WHERE {Q(l.OwnerColumn)} = @id;", new { id }, tx, cancellationToken: http.RequestAborted))).ToHashSet();
        if (wanted.Any(w => !w.IsActive && !current.Contains(w.Id)))
            throw ApiProblemException.Invalid("ITEM_INACTIVE", "An inactive item cannot be linked.");
        var keep = wanted.Select(w => w.Id).ToHashSet();
        await u.Connection.ExecuteAsync(new CommandDefinition(
            $"DELETE FROM {l.Table} WHERE {Q(l.OwnerColumn)} = @id AND {Q(l.TargetColumn)} NOT IN @keep;",
            new { id, keep = keep.DefaultIfEmpty(-1).ToArray() }, tx, cancellationToken: http.RequestAborted));
        foreach (var w in wanted.Where(w => !current.Contains(w.Id)))
            await u.Connection.ExecuteAsync(new CommandDefinition(
                $"INSERT {l.Table} (TenantId, {Q(l.OwnerColumn)}, {Q(l.TargetColumn)}) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @id, @t);",
                new { id, t = w.Id }, tx, cancellationToken: http.RequestAborted));
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("CATALOG_LINKS_CHANGED", "CONFIG", l.Table, id,
            AfterJson: JsonSerializer.Serialize(new { link, codes })), http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    // ---------- lookup lists (FR-CAT-020) ----------

    private static async Task<(int Id, bool IsSystem, bool AllowTenantItems)> ListOfAsync(BoundUser u, SqlTransaction? tx, string list, CancellationToken ct) =>
        await u.Connection.QuerySingleOrDefaultAsync<(int, bool, bool)>(new CommandDefinition(
            "SELECT LookupListId, IsSystem, AllowTenantItems FROM cat.LookupList WHERE Code = @list;", new { list = list.ToUpperInvariant() }, tx,
            cancellationToken: ct)) is { Item1: > 0 } found ? found : throw ApiProblemException.NotFound();

    private static Task<IResult> LookupListAsync(string list, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
        ListKindAsync(LookupItems(0), http, db, refs, async u => LookupItems((await ListOfAsync(u, null, list, http.RequestAborted)).Id));

    private static Task<IResult> LookupCreateAsync(string list, CatalogItemRequest body, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
        CreateKindAsync(LookupItems(0), body, http, db, refs, async (u, tx) =>
        {
            var l = await ListOfAsync(u, tx, list, http.RequestAborted);
            if (l.IsSystem && !l.AllowTenantItems)
                throw new ApiProblemException(409, "LIST_CLOSED", "Items of this list come from the defaults only.");
            return (LookupItems(l.Id), "LookupListId", l.Id);
        });

    private static Task<IResult> LookupPatchAsync(string list, string reference, CatalogItemRequest body, HttpContext http, SqlConnectionFactory db,
        OpaqueRefs refs) =>
        PatchKindAsync(LookupItems(0), reference, body, http, db, refs, async u => LookupItems((await ListOfAsync(u, null, list, http.RequestAborted)).Id));

    private static Task<IResult> LookupOrderAsync(string list, CatalogOrderRequest body, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
        OrderKindAsync(LookupItems(0), body, http, db, refs, async u => LookupItems((await ListOfAsync(u, null, list, http.RequestAborted)).Id));

    // ---------- global references and the tenant's currencies (FR-CAT-021, FR-CAT-023, FR-CAT-026) ----------

    private static async Task<IResult> CountriesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var rows = await u.Connection.QueryAsync<(string Iso2, string Iso3, string NameAr, string NameEn, bool IsGcc, string? WeekendDays, string? DialCode)>(
            new CommandDefinition("SELECT Iso2, Iso3, NameAr, NameEn, IsGcc, WeekendDays, DialCode FROM ref.Country WHERE IsActive = 1 ORDER BY NameEn;",
                cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = rows.Select(r => new { iso2 = r.Iso2, iso3 = r.Iso3, nameAr = r.NameAr, nameEn = r.NameEn, isGcc = r.IsGcc, weekendDays = r.WeekendDays, dialCode = r.DialCode }),
        });
    }

    private static async Task<IResult> CurrenciesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var rows = await u.Connection.QueryAsync<(string Code, string NameAr, string NameEn, int Decimals, bool Enabled)>(new CommandDefinition(
            """
            SELECT c.Code, c.NameAr, c.NameEn, c.Decimals, CAST(CASE WHEN tc.IsEnabled = 1 THEN 1 ELSE 0 END AS BIT)
              FROM ref.Currency AS c LEFT JOIN cat.TenantCurrency AS tc ON tc.CurrencyId = c.CurrencyId
             WHERE c.IsActive = 1 ORDER BY c.Code;
            """, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(r => new { code = r.Code, nameAr = r.NameAr, nameEn = r.NameEn, decimals = r.Decimals, enabled = r.Enabled }) });
    }

    private static async Task<IResult> TenantCurrenciesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var codes = await u.Connection.QueryAsync<string>(new CommandDefinition(
            "SELECT c.Code FROM cat.TenantCurrency AS tc JOIN ref.Currency AS c ON c.CurrencyId = tc.CurrencyId WHERE tc.IsEnabled = 1 ORDER BY c.Code;",
            cancellationToken: http.RequestAborted));
        return Results.Ok(new { codes });
    }

    /// <summary>The currencies offered in the tenant's forms; one disabled stays on the records that use it (FR-CAT-023).</summary>
    private static async Task<IResult> SetTenantCurrenciesAsync(TenantCurrenciesRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var codes = (body.Codes ?? []).Select(c => c.Trim().ToUpperInvariant()).Distinct().ToList();
        if (codes.Count == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enable one currency at least.");
        await using var u = await BoundUser.OpenAsync(http, db, General);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var ids = (await u.Connection.QueryAsync<(int Id, string Code)>(new CommandDefinition(
            "SELECT CurrencyId, Code FROM ref.Currency WHERE IsActive = 1 AND Code IN @codes;", new { codes }, tx, cancellationToken: http.RequestAborted))).ToList();
        if (ids.Count != codes.Count) throw ApiProblemException.Invalid("REFERENCE_NOT_FOUND", "A currency code is not known.");
        var before = (await u.Connection.QueryAsync<string>(new CommandDefinition(
            "SELECT c.Code FROM cat.TenantCurrency AS tc JOIN ref.Currency AS c ON c.CurrencyId = tc.CurrencyId WHERE tc.IsEnabled = 1;", transaction: tx,
            cancellationToken: http.RequestAborted))).Order(StringComparer.Ordinal).ToList();
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE cat.TenantCurrency SET IsEnabled = CASE WHEN CurrencyId IN @keep THEN 1 ELSE 0 END;", new { keep = ids.Select(i => i.Id).ToArray() }, tx,
            cancellationToken: http.RequestAborted));
        foreach (var (id, _) in ids)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                IF NOT EXISTS (SELECT 1 FROM cat.TenantCurrency WHERE CurrencyId = @id)
                    INSERT cat.TenantCurrency (TenantId, CurrencyId, IsEnabled) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @id, 1);
                """, new { id }, tx, cancellationToken: http.RequestAborted));
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("TENANT_CURRENCIES_CHANGED", "CONFIG", "cat.TenantCurrency", null,
            BeforeJson: JsonSerializer.Serialize(before), AfterJson: JsonSerializer.Serialize(codes.Order(StringComparer.Ordinal))), http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    private static string Q(string name) => "[" + name.Replace("]", "]]", StringComparison.Ordinal) + "]";
}

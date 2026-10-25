using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Seeding;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record CatalogDefaultsApplyRequest(List<string>? Keys);

/// <summary>
/// New catalogue defaults (FR-CAT-003, owner's decision of 2026-10-25, docs/31 row 57): the daily upgrade adds at once
/// what the platform needs and holds the optional catalogue rows; this lists them for the administrator, who adds the
/// ones they want. Nothing the tenant changed is overwritten: a row is added only when its seed key is not there. The
/// packs are read from the folder on each call, so a release's new version is offered at once.
/// </summary>
public static partial class CatalogEndpoints
{
    private static void MapDefaults(RouteGroupBuilder api)
    {
        api.MapGet("/catalogs/defaults", DefaultsAsync);
        api.MapPost("/catalogs/defaults/apply", ApplyDefaultsAsync);
    }

    private static IReadOnlyList<TenantPack> Packs(IConfiguration config) =>
        TenantSeeder.LoadS1(TenantSeeder.PacksDirectory(config["Seed:PacksDirectory"]));

    /// <summary>The catalogue kind of a table, for its permission and its screen; a lookup item is managed with the general catalogues.</summary>
    private static Kind? KindOfTable(string table) =>
        table == "cat.LookupItem" ? LookupItems(0) : Kinds.Values.FirstOrDefault(k => k.Table == table);

    private static async Task<IResult> DefaultsAsync(HttpContext http, SqlConnectionFactory db, IConfiguration config)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var perms = await u.PermissionsAsync(http.RequestAborted);
        var items = (await TenantSeeder.OptionalAsync(u.Connection, null, Packs(config), http.RequestAborted))
            .Select(d => (d, k: KindOfTable(d.Table)))
            .Where(x => x.k is not null && perms.Contains(x.k.Manage))
            .Select(x => new { key = x.d.SeedKey, pack = x.d.PackKey, kind = x.k!.Segment, code = x.d.Code, nameAr = x.d.NameAr, nameEn = x.d.NameEn })
            .ToList();
        return Results.Ok(new { items });
    }

    /// <summary>Adds the chosen defaults (all those the user may manage when none is named). Audited as CATALOG_DEFAULTS_APPLIED.</summary>
    private static async Task<IResult> ApplyDefaultsAsync(CatalogDefaultsApplyRequest body, HttpContext http, SqlConnectionFactory db, IConfiguration config)
    {
        var ct = http.RequestAborted;
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var perms = await u.PermissionsAsync(ct);
        var packs = Packs(config);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var available = (await TenantSeeder.OptionalAsync(u.Connection, tx, packs, ct)).ToDictionary(d => d.SeedKey, StringComparer.Ordinal);
        var asked = body.Keys is { Count: > 0 } k ? k.Distinct(StringComparer.Ordinal).ToList() : null;
        if (asked?.FirstOrDefault(x => !available.ContainsKey(x)) is { } unknown)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", $"{unknown} is not a default this account can add.");
        var chosen = (asked ?? [.. available.Keys]).Where(x => KindOfTable(available[x].Table) is { } kind && perms.Contains(kind.Manage)).ToHashSet(StringComparer.Ordinal);
        if (asked is not null && chosen.Count < asked.Count) throw ApiProblemException.Forbidden();
        if (chosen.Count == 0) return Results.Ok(new { added = 0 });
        var added = await TenantSeeder.ApplyOptionalAsync(u.Connection, tx, packs, chosen, ct);
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("CATALOG_DEFAULTS_APPLIED", "CONFIG", "cat", null,
            AfterJson: JsonSerializer.Serialize(new { keys = chosen.Order(StringComparer.Ordinal), added })), ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { added });
    }
}

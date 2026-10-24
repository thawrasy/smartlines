using BankFas.Core.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Workflow;

/// <summary>
/// The installer of the pack WFL.BASE (FR-WFL-002, S3 brief S3-GAP-2 and OQ-2): after the CSV rows of the pack (the
/// visible phases, the request types, their audiences), each file of templates/ is a template graph. It is checked
/// (V-WFL-01 to 03), written as a draft with its parts, published as the tenant's service user (DR-50: packs are
/// published by the job account) and its request type is activated. A template already seeded under its SeedKey, at
/// this pack version or an earlier one, is skipped (a later version of the pack adds templates; a changed graph comes
/// with a new SeedKey), and so is a type whose current template the tenant modified (FR-WFL-030), so a re-seed adds
/// nothing and replaces nothing of the tenant's.
/// </summary>
public static class WorkflowSeed
{
    public const string InstallerName = "WFL.TEMPLATES";

    public static async Task<(int Created, int Skipped, List<string> Diff)> InstallAsync(SqlConnection c, SqlTransaction tx, string packDirectory, int seedVersion,
        CancellationToken ct)
    {
        var files = Directory.GetFiles(Path.Combine(packDirectory, "templates"), "*.json").OrderBy(f => f, StringComparer.Ordinal).ToList();
        var phases = (await c.QueryAsync<string>(new CommandDefinition(
            "SELECT Code FROM wfl.ExternalPhase WHERE IsActive = 1;", transaction: tx, cancellationToken: ct)).ConfigureAwait(false)).ToHashSet(StringComparer.Ordinal);
        var publisher = await c.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);", transaction: tx, cancellationToken: ct)).ConfigureAwait(false)
            ?? throw new InvalidOperationException("The workflow templates are published by the tenant's service user; the connection names no user.");
        int created = 0, skipped = 0;
        var diff = new List<string>();
        foreach (var file in files)
        {
            var g = TemplateGraph.Parse(await File.ReadAllTextAsync(file, ct).ConfigureAwait(false));
            var errors = TemplateValidator.Validate(g, HookKeys.All, phases);
            if (errors.Count > 0) throw new InvalidDataException($"{Path.GetFileName(file)}: {string.Join(" ", errors)}");
            var seedKey = g.SeedKey ?? g.TemplateKey;
            var state = await c.QuerySingleAsync<(int Seeded, int Modified)>(new CommandDefinition(
                """
                SELECT (SELECT COUNT(*) FROM wfl.WorkflowTemplate AS t JOIN wfl.RequestType AS rt ON rt.TenantId = t.TenantId AND rt.RequestTypeId = t.RequestTypeId
                         WHERE rt.Code = @type AND t.SeedKey = @seed AND t.SourceSeedVersion <= @v),
                       (SELECT COUNT(*) FROM wfl.WorkflowTemplate AS t JOIN wfl.RequestType AS rt ON rt.TenantId = t.TenantId AND rt.RequestTypeId = t.RequestTypeId
                         WHERE rt.Code = @type AND t.IsCurrent = 1 AND t.IsTenantModified = 1);
                """, new { type = g.RequestType, seed = seedKey, v = seedVersion }, tx, cancellationToken: ct)).ConfigureAwait(false);
            if (state.Seeded > 0 || state.Modified > 0) { skipped++; diff.Add($"{g.TemplateKey}: present"); continue; }
            var w = await TemplateStore.WriteDraftAsync(c, tx, g, seedKey, seedVersion, ct).ConfigureAwait(false);
            if (!await TemplateStore.PublishAsync(c, tx, w.TemplateId, publisher, ct).ConfigureAwait(false))
                throw new InvalidOperationException($"The template {g.TemplateKey} could not be published.");
            await c.ExecuteAsync(new CommandDefinition(
                "UPDATE wfl.RequestType SET IsActive = 1, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE Code = @type AND IsActive = 0;",
                new { type = g.RequestType, u = publisher }, tx, cancellationToken: ct)).ConfigureAwait(false);
            created++;
            diff.Add($"{g.TemplateKey}: version {w.VersionNo} published");
        }
        return (created, skipped, diff);
    }
}

using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Seeding;

/// <summary>One table of a pack: its rows, and the columns that name a referenced row by a key instead of an id.</summary>
public sealed record PackTable(string Table, IReadOnlyList<string> Header, IReadOnlyList<string?[]> Rows, IReadOnlyDictionary<string, PackReference> References);

/// <summary>A CSV column whose value is the key of a row of another table (manifest.json, "References").</summary>
public sealed record PackReference(string Column, string Table, string Key);

/// <summary>A tenant seed pack of db/seed/packs/&lt;PackKey&gt;/v&lt;n&gt; (DOC-B05 section 5.1, FR-PLT-008).</summary>
public sealed record TenantPack(string PackKey, int SeedVersion, IReadOnlyList<string> DependsOn, IReadOnlyList<PackTable> Tables)
{
    private static readonly Regex TableName = new(@"^[a-z]{2,4}\.[A-Z][A-Za-z0-9]{1,80}$", RegexOptions.CultureInvariant);

    /// <summary>Reads a pack folder: manifest.json and its CSV files, in the manifest's order.</summary>
    public static TenantPack Load(string directory)
    {
        using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "manifest.json")));
        var root = manifest.RootElement;
        var refs = root.TryGetProperty("References", out var r) && r.ValueKind == JsonValueKind.Object ? r : default;
        var tables = new List<PackTable>();
        foreach (var file in root.GetProperty(nameof(Tables)).EnumerateArray().Select(e => e.GetString()!))
        {
            var table = file.EndsWith(".csv", StringComparison.Ordinal) ? file[..^4] : file;
            if (!TableName.IsMatch(table)) throw new InvalidDataException($"{directory}: {file} does not name a table.");
            var rows = Csv.Read(File.ReadAllText(Path.Combine(directory, file), Encoding.UTF8));
            if (rows.Count == 0) throw new InvalidDataException($"{directory}: {file} has no header.");
            var fileRefs = new Dictionary<string, PackReference>(StringComparer.Ordinal);
            if (refs.ValueKind == JsonValueKind.Object && refs.TryGetProperty(file, out var fr))
            {
                foreach (var p in fr.EnumerateObject())
                    fileRefs[p.Name] = new PackReference(p.Value.GetProperty("Column").GetString()!, p.Value.GetProperty("Table").GetString()!,
                        p.Value.TryGetProperty("Key", out var k) ? k.GetString()! : "SeedKey");
            }
            tables.Add(new PackTable(table, rows[0]!.Select(h => h ?? "").ToList(), rows.Skip(1).ToList(), fileRefs));
        }
        var depends = root.TryGetProperty(nameof(DependsOn), out var d) ? d.EnumerateArray().Select(e => e.GetString()!).ToList() : [];
        return new TenantPack(root.GetProperty(nameof(PackKey)).GetString()!, root.GetProperty(nameof(SeedVersion)).GetInt32(), depends, tables);
    }
}

/// <summary>The result of one pack on one tenant.</summary>
public sealed record SeedResult(string PackKey, int SeedVersion, bool AlreadyRun, int Created, int Skipped);

/// <summary>
/// The application's tenant seeder (FR-PLT-008, DOC-B05 section 5.1): applies the packs of a folder to the tenant the
/// connection is bound to, insert only. A row whose SeedKey (or, in a link table, whose every value) is already there
/// is skipped, so what the tenant renamed or deactivated stays as it is. A pack that has a SUCCEEDED run of its
/// version is not run again; each run is a row of cfg.SeedRun. Values are parameters; table and column names come
/// from the packs in the repository and are checked against sys.columns before any statement uses them.
/// </summary>
public static class TenantSeeder
{
    /// <summary>The packs of S1, in dependency order; each is applied at the latest version of its folder.</summary>
    public static readonly string[] S1Packs = ["CAT.ORG", "CAT.BANKING", "CAT.DOCTYPES", "CAT.LOOKUPS", "CAT.CURRENCY", "CORE.NUMBERING", "CORE.EXPIRY", "CORE.DEPARTMENTS",
        "NTF.BASE"];

    /// <summary>The packs folder: configuration Seed:PacksDirectory, else "packs" next to the application.</summary>
    public static string PacksDirectory(string? configured) =>
        string.IsNullOrEmpty(configured) ? Path.Combine(AppContext.BaseDirectory, "packs") : configured;

    /// <summary>
    /// Loads the S1 packs present in the folder (a pack not written yet is left out), each at its latest version vN: a
    /// later version keeps every row of the earlier ones, so a tenant that never ran the earlier one gets them all.
    /// </summary>
    public static IReadOnlyList<TenantPack> LoadS1(string packsDirectory) =>
        [.. S1Packs.Select(k => Latest(Path.Combine(packsDirectory, k))).OfType<string>().Select(TenantPack.Load)];

    private static string? Latest(string pack) =>
        !Directory.Exists(pack) ? null
        : Directory.GetDirectories(pack, "v*")
            .Select(d => (Dir: d, Ok: int.TryParse(Path.GetFileName(d)[1..], NumberStyles.None, CultureInfo.InvariantCulture, out var n), N: n))
            .Where(x => x.Ok && File.Exists(Path.Combine(x.Dir, "manifest.json")))
            .OrderByDescending(x => x.N).Select(x => x.Dir).FirstOrDefault();

    /// <summary>Applies the packs in order inside the transaction; the connection is bound to the tenant (a job binding).</summary>
    public static async Task<IReadOnlyList<SeedResult>> ApplyAsync(SqlConnection c, SqlTransaction tx, IEnumerable<TenantPack> packs, CancellationToken ct)
    {
        var results = new List<SeedResult>();
        var columns = new Dictionary<string, TableInfo>(StringComparer.Ordinal);
        foreach (var pack in packs)
        {
            var done = await c.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM cfg.SeedRun WHERE PackKey = @k AND SeedVersion = @v AND Status = 'SUCCEEDED';",
                new { k = pack.PackKey, v = pack.SeedVersion }, tx, cancellationToken: ct)).ConfigureAwait(false);
            if (done > 0) { results.Add(new SeedResult(pack.PackKey, pack.SeedVersion, true, 0, 0)); continue; }
            var earlier = await c.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM cfg.SeedRun WHERE PackKey = @k;", new { k = pack.PackKey }, tx, cancellationToken: ct)).ConfigureAwait(false);
            var started = DateTime.UtcNow;
            int created = 0, skipped = 0;
            var diff = new List<string>();
            foreach (var t in pack.Tables)
            {
                var info = await TableInfoAsync(c, tx, t.Table, columns, ct).ConfigureAwait(false);
                var (n, s) = await ApplyTableAsync(c, tx, pack, t, info, columns, ct).ConfigureAwait(false);
                created += n; skipped += s;
                diff.Add($"{t.Table}: {n} created, {s} present");
            }
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT cfg.SeedRun (TenantId, PackKey, SeedVersion, RunKind, Status, CreatedCount, UpdatedCount, SkippedModifiedCount, DiffJson, StartedAt, FinishedAt, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @k, @v, @kind, 'SUCCEEDED', @created, 0, 0, @diff, @started, SYSUTCDATETIME(),
                        CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """,
                new { k = pack.PackKey, v = pack.SeedVersion, kind = earlier > 0 ? "UPGRADE" : "INITIAL", created, diff = JsonSerializer.Serialize(diff), started },
                tx, cancellationToken: ct)).ConfigureAwait(false);
            results.Add(new SeedResult(pack.PackKey, pack.SeedVersion, false, created, skipped));
        }
        return results;
    }

    private sealed record TableInfo(string Table, IReadOnlySet<string> Columns, string PrimaryKey);

    private static async Task<TableInfo> TableInfoAsync(SqlConnection c, SqlTransaction tx, string table, Dictionary<string, TableInfo> cache, CancellationToken ct)
    {
        if (cache.TryGetValue(table, out var hit)) return hit;
        var cols = (await c.QueryAsync<string>(new CommandDefinition(
            "SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(@t);", new { t = table }, tx, cancellationToken: ct)).ConfigureAwait(false))
            .ToHashSet(StringComparer.Ordinal);
        if (cols.Count == 0) throw new InvalidDataException($"The table {table} of a pack does not exist.");
        var pk = await c.QuerySingleAsync<string>(new CommandDefinition(
            """
            SELECT TOP (1) col.name FROM sys.indexes AS i
              JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
              JOIN sys.columns AS col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
             WHERE i.object_id = OBJECT_ID(@t) AND i.is_primary_key = 1 ORDER BY ic.key_ordinal;
            """, new { t = table }, tx, cancellationToken: ct)).ConfigureAwait(false);
        return cache[table] = new TableInfo(table, cols, pk);
    }

    private static string Q(string name) => "[" + name.Replace("]", "]]", StringComparison.Ordinal) + "]";
    private static string QT(string table) => string.Join('.', table.Split('.').Select(Q));

    private static async Task<(int Created, int Skipped)> ApplyTableAsync(SqlConnection c, SqlTransaction tx, TenantPack pack, PackTable t, TableInfo info,
        Dictionary<string, TableInfo> cache, CancellationToken ct)
    {
        // The target column of each CSV column, checked against the table.
        var targets = new string[t.Header.Count];
        for (var i = 0; i < t.Header.Count; i++)
        {
            var h = t.Header[i];
            targets[i] = t.References.TryGetValue(h, out var r) ? r.Column : h;
            if (!info.Columns.Contains(targets[i])) throw new InvalidDataException($"{pack.PackKey}: {t.Table} has no column {targets[i]}.");
        }
        foreach (var r in t.References.Values)
        {
            var target = await TableInfoAsync(c, tx, r.Table, cache, ct).ConfigureAwait(false);
            if (!target.Columns.Contains(r.Key)) throw new InvalidDataException($"{pack.PackKey}: {r.Table} has no column {r.Key}.");
        }
        var hasTenant = info.Columns.Contains("TenantId");
        var hasCreatedBy = info.Columns.Contains("CreatedBy");
        var seedKey = Array.IndexOf(targets, "SeedKey");
        var resolved = new Dictionary<(string, string), object>();
        int created = 0, skipped = 0;
        foreach (var row in t.Rows)
        {
            var p = new DynamicParameters();
            var values = new object?[targets.Length];
            for (var i = 0; i < targets.Length; i++)
            {
                var raw = i < row.Length && !string.IsNullOrEmpty(row[i]) ? row[i] : null;
                if (raw is not null && t.References.TryGetValue(t.Header[i], out var r))
                {
                    if (!resolved.TryGetValue((r.Table + "." + r.Key, raw), out var id))
                    {
                        var target = cache[r.Table];
                        id = await c.ExecuteScalarAsync<object?>(new CommandDefinition(
                            $"SELECT {Q(target.PrimaryKey)} FROM {QT(r.Table)} WHERE {Q(r.Key)} = @v;", new { v = raw }, tx, cancellationToken: ct)).ConfigureAwait(false)
                            ?? throw new InvalidDataException($"{pack.PackKey}: {t.Table} refers to {r.Table} {r.Key} = {raw}, which does not exist.");
                        resolved[(r.Table + "." + r.Key, raw)] = id;
                    }
                    values[i] = id;
                }
                else values[i] = raw;
                p.Add("@p" + i.ToString(CultureInfo.InvariantCulture), values[i]);
            }
            // Present already: the same SeedKey, or in a table without one the same values.
            var match = seedKey >= 0 && values[seedKey] is not null
                ? $"{Q("SeedKey")} = @p{seedKey}"
                : string.Join(" AND ", targets.Select((col, i) => values[i] is null ? $"{Q(col)} IS NULL" : $"{Q(col)} = @p{i}"));
            var exists = await c.ExecuteScalarAsync<int>(new CommandDefinition(
                $"SELECT COUNT(*) FROM {QT(t.Table)} WHERE {match};", p, tx, cancellationToken: ct)).ConfigureAwait(false);
            if (exists > 0) { skipped++; continue; }
            var cols = new List<string>(targets.Select(Q));
            var vals = new List<string>(targets.Select((_, i) => "@p" + i.ToString(CultureInfo.InvariantCulture)));
            if (hasTenant) { cols.Insert(0, Q("TenantId")); vals.Insert(0, "CAST(SESSION_CONTEXT(N'TenantId') AS INT)"); }
            if (hasCreatedBy) { cols.Add(Q("CreatedBy")); vals.Add("CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)"); }
            await c.ExecuteAsync(new CommandDefinition(
                $"INSERT {QT(t.Table)} ({string.Join(", ", cols)}) VALUES ({string.Join(", ", vals)});", p, tx, cancellationToken: ct)).ConfigureAwait(false);
            created++;
        }
        return (created, skipped);
    }
}

/// <summary>An RFC 4180 reader: commas, double-quoted fields with "" inside, CRLF or LF line ends.</summary>
public static class Csv
{
    public static List<string?[]> Read(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (text.Length > 0 && text[0] == '﻿') text = text[1..];
        var rows = new List<string?[]>();
        var row = new List<string?>();
        var field = new StringBuilder();
        bool quoted = false, inQuotes = false;
        for (var i = 0; i < text.Length; i++)
        {
            var ch = text[i];
            if (inQuotes)
            {
                if (ch == '"' && i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                else if (ch == '"') inQuotes = false;
                else field.Append(ch);
                continue;
            }
            switch (ch)
            {
                case '"': inQuotes = true; quoted = true; break;
                case ',': row.Add(quoted || field.Length > 0 ? field.ToString() : null); field.Clear(); quoted = false; break;
                case '\r': break;
                case '\n':
                    row.Add(quoted || field.Length > 0 ? field.ToString() : null); field.Clear(); quoted = false;
                    if (row.Count > 1 || row[0] is not null) rows.Add([.. row]);
                    row.Clear();
                    break;
                default: field.Append(ch); break;
            }
        }
        if (field.Length > 0 || quoted || row.Count > 0)
        {
            row.Add(quoted || field.Length > 0 ? field.ToString() : null);
            if (row.Count > 1 || row[0] is not null) rows.Add([.. row]);
        }
        return rows;
    }
}

/// <summary>The packs the jobs apply, read once from the packs folder.</summary>
public sealed class SeedPacks(string directory)
{
    private readonly Lazy<IReadOnlyList<TenantPack>> _s1 = new(() => TenantSeeder.LoadS1(directory));

    public IReadOnlyList<TenantPack> S1 => _s1.Value;
}

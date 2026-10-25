using System.Globalization;
using System.Text;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record CatalogImportRequest(string? Csv, bool? Apply);
public sealed record CatalogImportRow(int Line, string? Code, string Action, string? Error = null, string? Message = null);

/// <summary>
/// The catalogues as CSV (FR-CAT-024): the export holds every item of a kind, active or not, with its common fields
/// and the fields of its kind (a reference by its code); the import reads the same columns. A row whose code exists
/// updates that item and a new code adds one: the code is the key and never changes. The import first answers a
/// preview of each row (add, change, unchanged, or the error); only <c>apply</c> with no error saves, all rows in one
/// transaction. A flag with effect on an item in use is changed on the screen, with the treasury manager's
/// confirmation (FR-CAT-022), never by import. Each saved row is audited as on the screen, marked as imported.
/// </summary>
public static partial class CatalogEndpoints
{
    private const int MaxImportRows = 2000;
    private static readonly string[] Common = ["code", "nameAr", "nameEn", "description", "sortOrder", "isActive", "externalCode"];

    private static void MapCsv(RouteGroupBuilder api)
    {
        api.MapGet("/catalogs/{kind}/export", ExportCsvAsync);
        api.MapPost("/catalogs/{kind}/import", ImportCsvAsync);
    }

    private static Kind CsvKind(string kind) => kind == "lookup-lists" ? throw ApiProblemException.NotFound() : KindOf(kind);

    private static async Task<IResult> ExportCsvAsync(string kind, HttpContext http, SqlConnectionFactory db)
    {
        var k = CsvKind(kind);
        await using var u = await BoundUser.OpenAsync(http, db, View);
        await u.RequireAsync(k.Manage, http.RequestAborted);
        var rows = await RowsAsync(u.Connection, null, k, true, null, http.RequestAborted);
        var codes = await RefCodesAsync(u.Connection, null, k, rows, http.RequestAborted);
        var sb = new StringBuilder();
        sb.AppendJoin(',', Common.Concat(k.Fields.Select(f => f.Name))).Append("\r\n");
        foreach (var r in rows)
        {
            var cells = new List<string?>
            {
                (string?)r["Code"], (string?)r["NameAr"], (string?)r["NameEn"], (string?)r["Description"],
                Convert.ToString(r["SortOrder"], CultureInfo.InvariantCulture), (bool)r["IsActive"]! ? "true" : "false", (string?)r["ExternalCode"],
            };
            foreach (var f in k.Fields)
            {
                var v = r[f.Column];
                cells.Add(v switch
                {
                    null => null,
                    bool b => b ? "true" : "false",
                    _ when f.Type == FieldType.Ref => codes.GetValueOrDefault((f.RefKind!, Convert.ToInt64(v, CultureInfo.InvariantCulture))),
                    _ => Convert.ToString(v, CultureInfo.InvariantCulture),
                });
            }
            sb.AppendJoin(',', cells.Select(CsvCell)).Append("\r\n");
        }
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("CATALOG_EXPORTED", "CONFIG", k.Table, null,
            AfterJson: JsonSerializer.Serialize(new { kind = k.Segment, rows = rows.Count })), http.RequestAborted);
        return Results.File(Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(sb.ToString())).ToArray(), "text/csv; charset=utf-8", $"catalog-{k.Segment}.csv");
    }

    /// <summary>A CSV cell; a leading =, +, - or @ is prefixed with ' so a spreadsheet never runs it as a formula (the import removes it again).</summary>
    private static string CsvCell(string? v)
    {
        if (string.IsNullOrEmpty(v)) return "";
        if (v[0] is '=' or '+' or '-' or '@') v = "'" + v;
        return "\"" + v.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
    }

    /// <summary>RFC 4180 records: quoted cells may hold commas, quotes and line breaks; a leading byte order mark is skipped.</summary>
    internal static List<List<string>> ParseCsv(string text)
    {
        var records = new List<List<string>>();
        var row = new List<string>();
        var cell = new StringBuilder();
        var quoted = false;
        var i = text.Length > 0 && text[0] == '﻿' ? 1 : 0;
        for (; i < text.Length; i++)
        {
            var ch = text[i];
            if (quoted)
            {
                if (ch == '"' && i + 1 < text.Length && text[i + 1] == '"') { cell.Append('"'); i++; }
                else if (ch == '"') quoted = false;
                else cell.Append(ch);
            }
            else if (ch == '"' && cell.Length == 0) quoted = true;
            else if (ch == ',') { row.Add(cell.ToString()); cell.Clear(); }
            else if (ch is '\r' or '\n')
            {
                if (ch == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                row.Add(cell.ToString()); cell.Clear();
                if (row.Count > 1 || row[0].Length > 0) records.Add(row);
                row = [];
            }
            else cell.Append(ch);
        }
        if (quoted) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The file ends inside a quoted cell.");
        if (cell.Length > 0 || row.Count > 0) { row.Add(cell.ToString()); records.Add(row); }
        return records;
    }

    private static string? Unguard(string v) => v.Length == 0 ? null : v.Length > 1 && v[0] == '\'' && v[1] is '=' or '+' or '-' or '@' ? v[1..] : v;

    private static JsonElement CellJson(Field f, string? v)
    {
        if (v is null) return JsonDocument.Parse("null").RootElement.Clone();
        var bad = ApiProblemException.Invalid("VALIDATION_FAILED", $"{f.Name}: the value is not valid.");
        return f.Type switch
        {
            FieldType.Bool => v.Trim().ToUpperInvariant() switch
            {
                "TRUE" or "1" or "YES" => JsonDocument.Parse("true").RootElement.Clone(),
                "FALSE" or "0" or "NO" => JsonDocument.Parse("false").RootElement.Clone(),
                _ => throw bad,
            },
            FieldType.Int => int.TryParse(v.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? JsonSerializer.SerializeToElement(n) : throw bad,
            FieldType.Json => Try(() => JsonDocument.Parse(v).RootElement.Clone()) ?? throw bad,
            _ => JsonSerializer.SerializeToElement(v.Trim()),
        };
    }

    private static JsonElement? Try(Func<JsonElement> f)
    {
        try { return f(); }
        catch (JsonException) { return null; }
    }

    private static bool Same(object? a, object? b) =>
        string.Equals(Convert.ToString(a, CultureInfo.InvariantCulture), Convert.ToString(b, CultureInfo.InvariantCulture), StringComparison.Ordinal);

    private static async Task<IResult> ImportCsvAsync(string kind, CatalogImportRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var k = CsvKind(kind);
        var ct = http.RequestAborted;
        if (body.Csv is not { Length: > 0 } text || text.Length > 2_000_000) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Send the CSV file, up to 2 MB.");
        var records = ParseCsv(text);
        if (records.Count < 2) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The file has no rows under its header.");
        if (records.Count - 1 > MaxImportRows) throw ApiProblemException.Invalid("VALIDATION_FAILED", $"Import up to {MaxImportRows} rows at a time.");
        var header = records[0].Select(h => h.Trim()).ToList();
        var known = Common.Concat(k.Fields.Select(f => f.Name)).ToHashSet(StringComparer.Ordinal);
        if (header.FirstOrDefault(h => !known.Contains(h)) is { } unknown) throw ApiProblemException.Invalid("UNKNOWN_FIELD", $"The column {unknown} is not one of this catalogue.");
        if (!header.Contains("code") || header.Distinct(StringComparer.Ordinal).Count() != header.Count)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The header names each column once, and code is one of them.");
        var apply = body.Apply == true;

        await using var u = await BoundUser.OpenAsync(http, db, View);
        await u.RequireAsync(k.Manage, ct);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var existing = (await RowsAsync(u.Connection, tx, k, true, null, ct)).ToDictionary(r => (string)r["Code"]!, StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var results = new List<CatalogImportRow>();
        var errors = 0;
        for (var line = 1; line < records.Count; line++)
        {
            var rec = records[line];
            string? Cell(string name) => header.IndexOf(name) is var ix and >= 0 && ix < rec.Count ? Unguard(rec[ix]) : null;
            bool Has(string name) => header.Contains(name);
            var code = Cell("code")?.Trim().ToUpperInvariant();
            string action;
            try
            {
                if (rec.Count > header.Count) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The row has more cells than the header.");
                if (code is null || !CodePattern().IsMatch(code))
                    throw ApiProblemException.Invalid("VALIDATION_FAILED", "The code is 2 to 80 capital letters, digits and _, starting with a letter.");
                if (!seen.Add(code)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The code appears twice in the file.");
                var fields = k.Fields.Where(f => Has(f.Name)).ToDictionary(f => f.Name, f => CellJson(f, Cell(f.Name)), StringComparer.Ordinal);
                int? sort = Has("sortOrder") && Cell("sortOrder") is { } so
                    ? int.TryParse(so.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var sv) ? sv : throw ApiProblemException.Invalid("VALIDATION_FAILED", "sortOrder: a whole number.")
                    : null;
                bool? active = Has("isActive") && Cell("isActive") is { } ac ? CellJson(new Field("isActive", "IsActive", FieldType.Bool), ac).GetBoolean() : null;
                await u.Connection.ExecuteAsync(new CommandDefinition("SAVE TRANSACTION import_row;", transaction: tx, cancellationToken: ct));
                try
                {
                    var values = await FieldValuesAsync(u, tx, k, fields, ct);
                    if (existing.TryGetValue(code, out var before))
                    {
                        var id = Convert.ToInt64(before[k.IdColumn], CultureInfo.InvariantCulture);
                        var nameAr = Has("nameAr") ? Cell("nameAr")?.Trim() : (string?)before["NameAr"];
                        var nameEn = Has("nameEn") ? Cell("nameEn")?.Trim() : (string?)before["NameEn"];
                        if (Names(nameAr, nameEn, true) is { } nameError) throw ApiProblemException.Invalid("VALIDATION_FAILED", nameError);
                        var sets = new Dictionary<string, object?>(StringComparer.Ordinal) { ["NameAr"] = nameAr, ["NameEn"] = nameEn };
                        if (Has("description")) sets["Description"] = Cell("description");
                        if (sort is not null) sets["SortOrder"] = sort;
                        if (active is not null) sets["IsActive"] = active;
                        if (Has("externalCode")) sets["ExternalCode"] = Cell("externalCode")?.Trim();
                        foreach (var (col, v) in values) sets[col] = v;
                        var changed = sets.Where(s => !Same(s.Value, before[s.Key])).ToDictionary(s => s.Key, s => s.Value, StringComparer.Ordinal);
                        if (changed.Count == 0) action = "UNCHANGED";
                        else
                        {
                            if (changed.TryGetValue("IsActive", out var a) && a is false && (bool)before["IsLocked"]!)
                                throw new ApiProblemException(409, "ITEM_LOCKED", "A locked item stays active.");
                            if (before["IsSystem"] is true && k.Fields.Any(f => changed.ContainsKey(f.Column)) && k.Segment == "lookup-lists")
                                throw new ApiProblemException(409, "ITEM_LOCKED", "A system list keeps its settings.");
                            if (k.Fields.Any(f => f.HighImpact && changed.ContainsKey(f.Column))
                                && (await UsageCountsAsync(u.Connection, tx, k, id, ct)).Sum(x => x.Count) > 0)
                                throw new ApiProblemException(409, "IMPACT_CONFIRMATION_REQUIRED", "This item is in use: change this flag on the screen, with the treasury manager's confirmation.");
                            await CheckVariantGroupAsync(u, tx, k, values, id, ct);
                            var p = new DynamicParameters(new { id });
                            var i = 0;
                            var assignments = changed.Select(c => { var n = "@s" + (i++).ToString(CultureInfo.InvariantCulture); p.Add(n, c.Value); return $"{Q(c.Key)} = {n}"; }).ToList();
                            await u.Connection.ExecuteAsync(new CommandDefinition(
                                $"UPDATE {k.Table} SET {string.Join(", ", assignments)}, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) " +
                                $"WHERE {Q(k.IdColumn)} = @id;", p, tx, cancellationToken: ct));
                            var after = (await RowsAsync(u.Connection, tx, k, true, null, ct, id)).Single();
                            await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("CATALOG_ITEM_UPDATED", "CONFIG", k.Table, id,
                                BeforeJson: AuditJson(before), AfterJson: AuditJson(after.Append(new KeyValuePair<string, object?>("source", "import")).ToDictionary())), ct);
                            action = "UPDATE";
                        }
                    }
                    else
                    {
                        var nameAr = Cell("nameAr")?.Trim();
                        var nameEn = Cell("nameEn")?.Trim();
                        if (Names(nameAr, nameEn, true) is { } nameError) throw ApiProblemException.Invalid("VALIDATION_FAILED", nameError);
                        await CheckVariantGroupAsync(u, tx, k, values, null, ct);
                        var cols = new List<string> { "TenantId", "Code", "NameAr", "NameEn", "Description", "SortOrder", "IsActive", "ExternalCode", "CreatedBy" };
                        var p = new DynamicParameters(new { code, ar = nameAr, en = nameEn, d = Cell("description"), sort = sort ?? 0, act = active ?? true, ext = Cell("externalCode")?.Trim() });
                        var vals = new List<string> { "CAST(SESSION_CONTEXT(N'TenantId') AS INT)", "@code", "@ar", "@en", "@d", "@sort", "@act", "@ext", "CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)" };
                        var i = 0;
                        foreach (var (col, v) in values)
                        {
                            var n = "@f" + (i++).ToString(CultureInfo.InvariantCulture);
                            cols.Add(col); vals.Add(n); p.Add(n, v);
                        }
                        var id = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
                            $"DECLARE @o TABLE (Id BIGINT); INSERT {k.Table} ({string.Join(", ", cols.Select(Q))}) OUTPUT CAST(inserted.{Q(k.IdColumn)} AS BIGINT) INTO @o " +
                            $"VALUES ({string.Join(", ", vals)}); SELECT Id FROM @o;", p, tx, cancellationToken: ct));
                        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("CATALOG_ITEM_CREATED", "CONFIG", k.Table, id,
                            AfterJson: JsonSerializer.Serialize(new { code, nameAr, nameEn, fields, source = "import" })), ct);
                        action = "CREATE";
                    }
                }
                catch (Exception e) when (e is ApiProblemException or SqlException)
                {
                    if (e is SqlException { Class: >= 20 } || tx.Connection is null) throw;
                    await u.Connection.ExecuteAsync(new CommandDefinition("IF XACT_STATE() = 1 ROLLBACK TRANSACTION import_row;", transaction: tx, cancellationToken: ct));
                    throw;
                }
                results.Add(new CatalogImportRow(line, code, action));
            }
            catch (ApiProblemException e)
            {
                errors++;
                results.Add(new CatalogImportRow(line, code, "ERROR", e.Code, e.Message));
            }
            catch (SqlException e) when (DbProblemMap.Map(e.Number) is { } m)
            {
                errors++;
                results.Add(new CatalogImportRow(line, code, "ERROR", m.Code, m.Title));
                if (tx.Connection is null
                    || await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT XACT_STATE();", transaction: tx, cancellationToken: ct)) != 1)
                {
                    results.Add(new CatalogImportRow(line, code, "STOPPED", "IMPORT_STOPPED", "The database stopped the import at this row; correct it and import again."));
                    break;
                }
            }
        }
        var saved = apply && errors == 0 && tx.Connection is not null;
        if (saved) await tx.CommitAsync(ct);
        else if (tx.Connection is not null) await tx.RollbackAsync(ct);
        return Results.Ok(new
        {
            kind = k.Segment, applied = saved, errors, rows = results,
            creates = results.Count(r => r.Action == "CREATE"), updates = results.Count(r => r.Action == "UPDATE"),
        });
    }
}

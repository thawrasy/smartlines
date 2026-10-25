using System.Data;
using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using BankFas.Core.Files;
using BankFas.Core.Security;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Jobs;

/// <summary>
/// JOB-PLT-EXPORT (FR-PLT-039, BR-PLT-016; db/static/042): an approved export of a tenant becomes one zip package: a
/// manifest, one JSON file per table of the tenant's data (every column the job may read, without the sealed values,
/// the hashes and the row versions), and the current version of every clean document with its file. Restricted
/// documents (identity images) go in only when the export was approved with restricted data. The package is stored
/// encrypted with the tenant's FILE key and recorded by cfg.usp_FinishDataExport (READY for 7 days); the API hands it
/// out sealed with a password the requester chooses at download, which the platform never keeps. A failure is recorded
/// by cfg.usp_FailDataExport with its kind and the file removed.
/// </summary>
public sealed class DataExportJob(SqlConnectionFactory db, IKeyWrapper wrapper, FileStore store) : TenantJob(db)
{
    public override string JobKey => "JOB-PLT-EXPORT";

    /// <summary>The schemas of a tenant's data; the platform's own (plat, rls), the credentials (sec) and the audit (aud, exported by its own export) are not in it.</summary>
    private static readonly string[] Schemas = ["org", "pty", "ins", "acc", "cat", "ref", "fac", "col", "obl", "fin", "cmp", "lc", "wfl", "doc", "ntf", "cfg"];

    private sealed record Started(long DataExportJobId, string Scope, string? ScopeDetailJson, bool IncludesRestricted, long RequestedBy);

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var p = new DynamicParameters();
        p.Add("@DataExportJobId", null, DbType.Int64, ParameterDirection.InputOutput);
        var job = await c.QuerySingleOrDefaultAsync<Started>(new CommandDefinition("cfg.usp_StartDataExport", p, commandType: CommandType.StoredProcedure,
            cancellationToken: ct)).ConfigureAwait(false);
        if (job is null) return null;
        string? storageKey = null;
        try
        {
            var zip = await BuildAsync(c, tenant.TenantId, job, ct).ConfigureAwait(false);
            var tenantRef = await c.ExecuteScalarAsync<Guid>(new CommandDefinition("SELECT PublicId FROM plat.v_CurrentTenant;", cancellationToken: ct)).ConfigureAwait(false);
            var key = await KeyAsync(c, tenant.TenantId, null, ct).ConfigureAwait(false);
            storageKey = string.Create(CultureInfo.InvariantCulture,
                $"{tenantRef:N}/export-{job.DataExportJobId}/v1-{Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant()}");
            await store.WriteAsync(storageKey, FileCrypto.Encrypt(key, zip, tenant.TenantId, storageKey, 1), ct).ConfigureAwait(false);
            await c.ExecuteAsync(new CommandDefinition("cfg.usp_FinishDataExport", new
            {
                DataExportJobId = job.DataExportJobId, StorageKey = storageKey,
                FileName = $"data-export-{DateTime.UtcNow:yyyyMMdd}-{job.DataExportJobId}.zip", SizeBytes = (long)zip.Length, Sha256 = SHA256.HashData(zip),
            }, commandType: CommandType.StoredProcedure, cancellationToken: ct)).ConfigureAwait(false);
            return $"export {job.DataExportJobId}: {zip.Length} bytes";
        }
        catch (Exception ex) when (ex is SqlException or IOException or InvalidOperationException or CryptographicException or JsonException)
        {
            if (storageKey is not null) store.DeleteUncommitted(storageKey);
            await c.ExecuteAsync(new CommandDefinition("cfg.usp_FailDataExport", new { DataExportJobId = job.DataExportJobId, Reason = ex.GetType().Name },
                commandType: CommandType.StoredProcedure, cancellationToken: ct)).ConfigureAwait(false);
            return $"export {job.DataExportJobId} failed: {ex.GetType().Name}";
        }
    }

    /// <summary>The tenant's FILE key: the ACTIVE one, or the one of a given id.</summary>
    private async Task<byte[]> KeyAsync(SqlConnection c, int tenantId, long? keyId, CancellationToken ct)
    {
        var k = await c.QuerySingleOrDefaultAsync<(long Id, string Purpose, int Version, byte[] Wrapped, string Ref)>(new CommandDefinition(
            keyId is null
                ? "SELECT TenantKeyId, Purpose, KeyVersion, WrappedKey, MasterKeyRef FROM sec.TenantKey WHERE Purpose = 'FILE' AND Status = 'ACTIVE';"
                : "SELECT TenantKeyId, Purpose, KeyVersion, WrappedKey, MasterKeyRef FROM sec.TenantKey WHERE TenantKeyId = @id AND Status IN ('ACTIVE', 'RETIRING');",
            new { id = keyId }, cancellationToken: ct)).ConfigureAwait(false);
        if (k.Id == 0) throw new InvalidOperationException("The tenant has no usable FILE key.");
        return wrapper.Unwrap(k.Ref, k.Wrapped, EnvelopeAad.ForTenantKey(tenantId, k.Purpose, k.Version));
    }

    private async Task<byte[]> BuildAsync(SqlConnection c, int tenantId, Started job, CancellationToken ct)
    {
        var tables = (await c.QueryAsync<(string Schema, string Table)>(new CommandDefinition(
            """
            SELECT s.name, t.name FROM sys.tables AS t JOIN sys.schemas AS s ON s.schema_id = t.schema_id
             WHERE s.name IN @schemas AND EXISTS (SELECT 1 FROM sys.columns AS c WHERE c.object_id = t.object_id AND c.name = 'TenantId')
               AND HAS_PERMS_BY_NAME(QUOTENAME(s.name) + '.' + QUOTENAME(t.name), 'OBJECT', 'SELECT') = 1
             ORDER BY s.name, t.name;
            """, new { schemas = Schemas }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        using var buffer = new MemoryStream();
        var manifestTables = new List<object>();
        var manifestFiles = new List<object>();
        using (var zip = new ZipArchive(buffer, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var (schema, table) in tables)
            {
                var full = $"[{schema}].[{table}]";
                var columns = (await c.QueryAsync<string>(new CommandDefinition(
                    """
                    SELECT c.name FROM sys.columns AS c JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
                     WHERE c.object_id = OBJECT_ID(@t) AND ty.name NOT IN ('timestamp', 'varbinary', 'binary', 'image')
                       AND c.name NOT LIKE '%Enc' AND c.name NOT LIKE '%Hash' AND c.name <> 'TenantId'
                       AND HAS_PERMS_BY_NAME(@t, 'OBJECT', 'SELECT', c.name, 'COLUMN') = 1
                     ORDER BY c.column_id;
                    """, new { t = full }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
                if (columns.Count == 0) continue;
                var rows = await c.QueryAsync(new CommandDefinition($"SELECT {string.Join(", ", columns.Select(x => "[" + x + "]"))} FROM {full};",
                    cancellationToken: ct, commandTimeout: 600)).ConfigureAwait(false);
                var entry = zip.CreateEntry($"data/{schema}.{table}.json", CompressionLevel.Optimal);
                var count = 0;
                await using (var s = entry.Open())
                await using (var w = new Utf8JsonWriter(s, new JsonWriterOptions { Indented = false }))
                {
                    w.WriteStartArray();
                    foreach (IDictionary<string, object?> r in rows)
                    {
                        JsonSerializer.Serialize(w, r);
                        count++;
                    }
                    w.WriteEndArray();
                }
                manifestTables.Add(new { table = $"{schema}.{table}", rows = count, columns });
            }
            var docs = await c.QueryAsync<(Guid PublicId, string Title, string Type, string Sensitivity, int VersionNo, string StorageKey, string? FileName, long KeyId, byte[] Sha256)>(
                new CommandDefinition(
                    """
                    SELECT d.PublicId, d.Title, t.Code, d.Sensitivity, v.VersionNo, v.StorageKey, v.FileName, v.KeyId, v.Sha256
                      FROM doc.Document AS d JOIN doc.DocumentVersion AS v ON v.DocumentVersionId = d.CurrentVersionId
                      JOIN cat.DocumentType AS t ON t.DocumentTypeId = d.DocumentTypeId
                     WHERE d.Status = 'ACTIVE' AND v.ScanStatus = 'CLEAN' AND t.Code <> 'DATA_EXPORT_PACKAGE' AND (@restricted = 1 OR d.Sensitivity <> 'RESTRICTED')
                     ORDER BY d.DocumentId;
                    """, new { restricted = job.IncludesRestricted }, cancellationToken: ct)).ConfigureAwait(false);
            var keys = new Dictionary<long, byte[]>();
            foreach (var d in docs)
            {
                if (!keys.TryGetValue(d.KeyId, out var key)) keys[d.KeyId] = key = await KeyAsync(c, tenantId, d.KeyId, ct).ConfigureAwait(false);
                var stored = await store.ReadAsync(d.StorageKey, ct).ConfigureAwait(false);
                var content = FileCrypto.Decrypt(key, stored, tenantId, d.StorageKey, d.VersionNo);
                if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(content), d.Sha256)) throw new InvalidOperationException("A stored file does not match its SHA-256.");
                var name = string.Concat((d.FileName ?? "file").Split(Path.GetInvalidFileNameChars()));
                var path = $"files/{d.PublicId:N}/{name}";
                var e = zip.CreateEntry(path, CompressionLevel.Optimal);
                await using (var s = e.Open()) await s.WriteAsync(content, ct).ConfigureAwait(false);
                manifestFiles.Add(new { document = d.PublicId, title = d.Title, type = d.Type, sensitivity = d.Sensitivity, version = d.VersionNo, path, sha256 = Convert.ToHexString(d.Sha256) });
            }
            var manifest = zip.CreateEntry("manifest.json");
            await using (var s = manifest.Open())
                await JsonSerializer.SerializeAsync(s, new
                {
                    format = "BankFas data export 1", generatedAt = DateTime.UtcNow, export = job.DataExportJobId, includesRestricted = job.IncludesRestricted,
                    note = "Sealed columns (…Enc), hashes and row versions are not exported; a restricted value is in the package only through its document when the export was approved with restricted data.",
                    tables = manifestTables, files = manifestFiles,
                }, cancellationToken: ct).ConfigureAwait(false);
        }
        return buffer.ToArray();
    }
}

/// <summary>JOB-PLT-EXPORT-EXPIRE (DOC-F05 6.3): READY packages past their 7 days become EXPIRED, their document soft-deleted and their file removed.</summary>
public sealed class DataExportExpiryJob(SqlConnectionFactory db, FileStore store) : TenantJob(db)
{
    public override string JobKey => "JOB-PLT-EXPORT-EXPIRE";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var p = new DynamicParameters();
        p.Add("@Expired", null, DbType.Int32, ParameterDirection.Output);
        var keys = (await c.QueryAsync<(long Id, string StorageKey)>(new CommandDefinition("cfg.usp_ExpireDataExports", p, commandType: CommandType.StoredProcedure,
            cancellationToken: ct)).ConfigureAwait(false)).ToList();
        foreach (var k in keys) store.DeleteUncommitted(k.StorageKey);
        return keys.Count == 0 ? null : $"{keys.Count} package(s) expired";
    }
}

/// <summary>
/// The sealed download of an export package: AES-256-CBC with a key and IV from PBKDF2-HMAC-SHA256 (600,000 rounds) of
/// the requester's password and a random salt, in the "Salted__" format of OpenSSL, so the package opens with
/// <c>openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -in package.zip.enc -out package.zip</c>.
/// </summary>
public static class ExportSeal
{
    public const int Iterations = 600_000;

    public static byte[] Seal(byte[] content, string password)
    {
        ArgumentNullException.ThrowIfNull(content);
        ArgumentNullException.ThrowIfNull(password);
        var salt = RandomNumberGenerator.GetBytes(8);
        var material = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), salt, Iterations, HashAlgorithmName.SHA256, 48);
        using var aes = Aes.Create();
        aes.Key = material[..32];
        var cipher = aes.EncryptCbc(content, material.AsSpan(32, 16), PaddingMode.PKCS7);
        return [.. Encoding.ASCII.GetBytes("Salted__"), .. salt, .. cipher];
    }

    public static byte[] Open(byte[] sealedContent, string password)
    {
        ArgumentNullException.ThrowIfNull(sealedContent);
        ArgumentNullException.ThrowIfNull(password);
        var salt = sealedContent.AsSpan(8, 8).ToArray();
        var material = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), salt, Iterations, HashAlgorithmName.SHA256, 48);
        using var aes = Aes.Create();
        aes.Key = material[..32];
        return aes.DecryptCbc(sealedContent.AsSpan(16), material.AsSpan(32, 16), PaddingMode.PKCS7);
    }
}

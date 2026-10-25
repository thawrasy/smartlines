using System.Data;
using System.Security.Cryptography;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Files;
using BankFas.Data;
using BankFas.Data.Jobs;
using Dapper;

namespace BankFas.Api.Endpoints;

public sealed record DataExportBody(bool? IncludesRestricted);
public sealed record DataExportDownloadBody(string? Password, string? StepUpCode);

/// <summary>
/// The tenant data export (FR-PLT-039, BR-PLT-016; db/static/042): a holder of cfg.export.request asks for an export
/// of the account (one at a time); one with restricted data waits for a holder of party.identity.reveal; the worker
/// builds the package (JOB-PLT-EXPORT); for 7 days the requester downloads it with a fresh confirmation, sealed with a
/// password of at least 12 characters chosen at that moment (never stored), and opens it with OpenSSL. Every step is
/// audited by the procedures; the download as EXPORT_DOWNLOADED.
/// </summary>
public static class DataExportEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/data-exports", ListAsync);
        api.MapPost("/data-exports", RequestAsync);
        api.MapPost("/data-exports/{id:guid}/approve", ApproveAsync);
        api.MapPost("/data-exports/{id:guid}/download", DownloadAsync);
    }

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, "cfg.export.request");
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT TOP (50) j.PublicId AS id, j.Status AS status, j.Scope AS scope, j.IncludesRestricted AS includesRestricted, j.RequestedAt AS requestedAt,
                   r.DisplayNameEn AS requestedByEn, r.DisplayNameAr AS requestedByAr, j.ApprovedAt AS approvedAt, j.FinishedAt AS finishedAt, j.ExpiresAt AS expiresAt,
                   v.SizeBytes AS sizeBytes, CONVERT(VARCHAR(64), j.PackageSha256, 2) AS sha256, j.FailureReason AS failureReason,
                   CASE WHEN j.RequestedBy = @u THEN 1 ELSE 0 END AS mine
              FROM cfg.DataExportJob AS j JOIN sec.AppUser AS r ON r.AppUserId = j.RequestedBy
              LEFT JOIN doc.Document AS d ON d.DocumentId = j.PackageDocumentId LEFT JOIN doc.DocumentVersion AS v ON v.DocumentVersionId = d.CurrentVersionId
             ORDER BY j.RequestedAt DESC;
            """, new { u = u.UserId }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    private static async Task<IResult> RequestAsync(DataExportBody b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, "cfg.export.request");
        var p = new DynamicParameters(new { TenantId = u.TenantId, Scope = "FULL", ScopeDetailJson = (string?)null, IncludesRestricted = b.IncludesRestricted == true });
        p.Add("@DataExportJobId", null, DbType.Int64, ParameterDirection.Output);
        await u.Connection.ExecuteAsync(new CommandDefinition("cfg.usp_RequestDataExport", p, commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
        var id = await u.Connection.ExecuteScalarAsync<Guid>(new CommandDefinition("SELECT PublicId FROM cfg.DataExportJob WHERE DataExportJobId = @id;",
            new { id = p.Get<long>("@DataExportJobId") }, cancellationToken: http.RequestAborted));
        var status = await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition("SELECT Status FROM cfg.DataExportJob WHERE PublicId = @id;", new { id },
            cancellationToken: http.RequestAborted));
        return Results.Created($"/api/v1/data-exports/{id}", new { id, status });
    }

    private static async Task<long> IdAsync(BoundUser u, Guid id, CancellationToken ct) =>
        await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT DataExportJobId FROM cfg.DataExportJob WHERE PublicId = @id;", new { id },
            cancellationToken: ct)) ?? throw ApiProblemException.NotFound();

    private static async Task<IResult> ApproveAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, "party.identity.reveal");
        await u.Connection.ExecuteAsync(new CommandDefinition("cfg.usp_ApproveDataExport", new { TenantId = u.TenantId, DataExportJobId = await IdAsync(u, id, http.RequestAborted) },
            commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
        return Results.NoContent();
    }

    private static async Task<IResult> DownloadAsync(Guid id, DataExportDownloadBody b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, FileStore store,
        TimeProvider clock)
    {
        if (b.Password is not { Length: >= 12 and <= 128 }) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a password of 12 to 128 characters for the package.");
        await (await BoundUser.OpenAsync(http, db, "cfg.export.request")).DisposeAsync();
        await StepUp.RequireAsync(http, db, keys, clock, b.StepUpCode);
        await using var u = await BoundUser.OpenAsync(http, db, "cfg.export.request");
        var ct = http.RequestAborted;
        var jobId = await IdAsync(u, id, ct);
        var job = await u.Connection.QuerySingleAsync<(string Status, long RequestedBy, DateTime? ExpiresAt, long? Doc)>(new CommandDefinition(
            "SELECT Status, RequestedBy, ExpiresAt, PackageDocumentId FROM cfg.DataExportJob WHERE DataExportJobId = @id;", new { id = jobId }, cancellationToken: ct));
        if (job.RequestedBy != u.UserId) throw ApiProblemException.Forbidden("NOT_REQUESTER", "Only the user who asked for the export downloads it.");
        if (job.Status != "READY" || job.Doc is null || job.ExpiresAt <= clock.GetUtcNow().UtcDateTime)
            throw new ApiProblemException(409, "INVALID_STATE", "The package is not ready, or it has expired.");
        var v = await u.Connection.QuerySingleAsync<(int VersionNo, string StorageKey, string FileName, long KeyId, byte[] Sha256)>(new CommandDefinition(
            """
            SELECT v.VersionNo, v.StorageKey, v.FileName, v.KeyId, v.Sha256 FROM doc.Document AS d JOIN doc.DocumentVersion AS v ON v.DocumentVersionId = d.CurrentVersionId
             WHERE d.DocumentId = @d;
            """, new { d = job.Doc }, cancellationToken: ct));
        var key = await keys.ByIdAsync(u.Connection, null, u.TenantId, v.KeyId, ct);
        var stored = await store.ReadAsync(v.StorageKey, ct);
        var zip = FileCrypto.Decrypt(key, stored, u.TenantId, v.StorageKey, v.VersionNo);
        if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(zip), v.Sha256)) throw new InvalidOperationException("The package does not match its SHA-256.");
        var sealedPackage = ExportSeal.Seal(zip, b.Password);
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("EXPORT_DOWNLOADED", "SECURITY", "cfg.DataExportJob", jobId,
            AfterJson: JsonSerializer.Serialize(new { sha256 = Convert.ToHexString(v.Sha256), sealedBytes = sealedPackage.Length }), Severity: "HIGH"), null, ct);
        http.Response.Headers.CacheControl = "no-store";
        return Results.File(sealedPackage, "application/octet-stream", v.FileName + ".enc");
    }
}

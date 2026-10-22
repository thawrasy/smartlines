using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Files;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record DocumentPatch(string? Title, string? DocumentNumber, string? IssueDate, string? IssueDateHijriText, string? ExpiryDate,
    string? ExpiryDateHijriText, string? IssuingAuthority);
public sealed record DocumentDeleteRequest(string? Reason);

/// <summary>
/// The document store (FR-PLT-027 to 030; FR-ORG-011 to 013; SCR-PLT-16): an upload is checked by its content, size
/// and the flags of its DocumentType, scanned for malware, encrypted with the tenant's FILE key and written once; its
/// rows (Document, Version 1, CurrentVersionId, the link to its company, the outbox event and the audit row) are one
/// transaction. A new file is a new version; nothing is replaced. Only a CLEAN version downloads, through this
/// endpoint only; a RESTRICTED document needs a sensitive permission, and each download is logged.
/// </summary>
public static class DocumentEndpoints
{
    private const string View = "org.document.view";
    private const string Manage = "org.document.manage";
    private static readonly string[] Restricted = ["party.identity.image.view", "acc.signature.image.view"];
    private const int DefaultMaxMb = 25;
    private static readonly string[] DefaultMime = ["application/pdf", "image/png", "image/jpeg"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/documents", ListAsync);
        api.MapPost("/documents", UploadAsync);
        api.MapGet("/documents/{id:guid}", GetAsync);
        api.MapPatch("/documents/{id:guid}", PatchAsync);
        api.MapPost("/documents/{id:guid}/versions", NewVersionAsync);
        api.MapGet("/documents/{id:guid}/content", ContentAsync);
        api.MapPost("/documents/{id:guid}/actions/delete", DeleteAsync);
    }

    internal sealed record DocType(int DocumentTypeId, string Code, string NameAr, string? NameEn, bool RequiresExpiry, bool IsSensitive, string? AllowedMime,
        int? MaxSizeMb, string? AppliesTo, bool IsActive);

    internal sealed record DocRow(long DocumentId, Guid PublicId, string TypeCode, string TypeNameAr, string? TypeNameEn, bool IsSensitive, string Title,
        string? DocumentNumber, DateTime? IssueDate, string? IssueDateHijriText, DateTime? ExpiryDate, string? ExpiryDateHijriText, string? IssuingAuthority,
        long? OwnerCompanyId, Guid? CompanyPublicId, string? CompanyNameAr, string? CompanyNameEn, string Sensitivity, string Status,
        int? VersionNo, string? FileName, string? ContentType, long? SizeBytes, string? ScanStatus, DateTime CreatedAt, byte[] RowVersion);

    private const string Select =
        """
        SELECT d.DocumentId, d.PublicId, t.Code AS TypeCode, t.NameAr AS TypeNameAr, t.NameEn AS TypeNameEn, t.IsSensitive, d.Title, d.DocumentNumber,
               d.IssueDate, d.IssueDateHijriText, d.ExpiryDate, d.ExpiryDateHijriText, d.IssuingAuthority, d.OwnerCompanyId, c.PublicId AS CompanyPublicId,
               c.NameAr AS CompanyNameAr, c.NameEn AS CompanyNameEn, d.Sensitivity, d.Status, v.VersionNo, v.FileName, v.ContentType, v.SizeBytes,
               v.ScanStatus, d.CreatedAt, d.RowVersion
          FROM doc.Document AS d
          JOIN cat.DocumentType AS t ON t.DocumentTypeId = d.DocumentTypeId
          LEFT JOIN org.Company AS c ON c.CompanyId = d.OwnerCompanyId
          LEFT JOIN doc.DocumentVersion AS v ON v.DocumentVersionId = d.CurrentVersionId
        """;

    /// <summary>Valid, expiring (within the first threshold of the expiry rule) or expired (FR-ORG-013).</summary>
    internal static string Validity(DateTime? expiry, DateOnly today, int horizonDays) =>
        expiry is null ? "NO_EXPIRY"
        : DateOnly.FromDateTime(expiry.Value) < today ? "EXPIRED"
        : DateOnly.FromDateTime(expiry.Value).DayNumber - today.DayNumber <= horizonDays ? "EXPIRING" : "VALID";

    /// <summary>The first threshold, in days, of the expiry rule of company documents (CORE.EXPIRY), 30 without one.</summary>
    internal static async Task<int> HorizonAsync(SqlConnection c, CancellationToken ct)
    {
        var json = await c.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT LeadDays FROM cfg.ExpiryAlertRule WHERE ItemType = 'COMPANY_DOCUMENT' AND IsActive = 1;", cancellationToken: ct));
        if (json is null) return 30;
        var days = JsonSerializer.Deserialize<int[]>(json);
        return days is { Length: > 0 } ? days.Max() : 30;
    }

    internal static object Shape(DocRow d, DateOnly today, int horizon) => new
    {
        id = d.PublicId, type = new { code = d.TypeCode, nameAr = d.TypeNameAr, nameEn = d.TypeNameEn }, title = d.Title, documentNumber = d.DocumentNumber,
        issueDate = d.IssueDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), issueDateHijri = d.IssueDateHijriText,
        expiryDate = d.ExpiryDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), expiryDateHijri = d.ExpiryDateHijriText,
        issuingAuthority = d.IssuingAuthority,
        company = d.CompanyPublicId is null ? null : new { id = d.CompanyPublicId, nameAr = d.CompanyNameAr, nameEn = d.CompanyNameEn },
        sensitivity = d.Sensitivity, status = d.Status, validity = Validity(d.ExpiryDate, today, horizon),
        daysLeft = d.ExpiryDate is null ? (int?)null : DateOnly.FromDateTime(d.ExpiryDate.Value).DayNumber - today.DayNumber,
        version = d.VersionNo, fileName = d.FileName, contentType = d.ContentType, sizeBytes = d.SizeBytes, scanStatus = d.ScanStatus,
        createdAt = d.CreatedAt, etag = ETags.Of(d.RowVersion),
    };

    internal static DateOnly Today(TimeProvider clock) => DateOnly.FromDateTime(clock.GetUtcNow().UtcDateTime);

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "type", "company", "validity", "q", "status");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var q = http.Request.Query;
        Guid? company = Guid.TryParse(q["company"], out var cg) ? cg : null;
        var rows = await u.Connection.QueryAsync<DocRow>(new CommandDefinition(
            Select + """
             WHERE d.Status = ISNULL(@status, 'ACTIVE')
               AND (@type IS NULL OR t.Code = @type)
               AND (@company IS NULL OR c.PublicId = @company)
               AND (@q IS NULL OR d.Title LIKE @q OR d.DocumentNumber LIKE @q)
               AND (@all = 1 OR d.OwnerCompanyId IS NULL OR d.OwnerCompanyId IN @ids)
               AND (@restricted = 1 OR d.Sensitivity <> 'RESTRICTED')
             ORDER BY d.ExpiryDate, d.DocumentId DESC;
            """,
            new
            {
                status = q["status"].ToString() is { Length: > 0 } st ? st.ToUpperInvariant() : null, type = q["type"].ToString() is { Length: > 0 } ty ? ty : null,
                company, q = q["q"].ToString() is { Length: > 0 } text ? "%" + text + "%" : null, all = scope.All, ids = scope.SqlIds,
                restricted = Restricted.Any((await u.PermissionsAsync(http.RequestAborted)).Contains),
            }, cancellationToken: http.RequestAborted));
        var today = Today(clock);
        var horizon = await HorizonAsync(u.Connection, http.RequestAborted);
        var validity = q["validity"].ToString().ToUpperInvariant();
        return Results.Ok(new
        {
            items = rows.Where(r => validity.Length == 0 || Validity(r.ExpiryDate, today, horizon) == validity).Select(r => Shape(r, today, horizon)),
        });
    }

    private static async Task<DocRow> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct)
    {
        var d = await u.Connection.QuerySingleOrDefaultAsync<DocRow>(new CommandDefinition(Select + " WHERE d.PublicId = @id;", new { id }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        return scope.Allows(d.OwnerCompanyId) ? d : throw ApiProblemException.NotFound();
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var d = await FindAsync(u, null, id, scope, http.RequestAborted);
        var versions = await u.Connection.QueryAsync<(int VersionNo, string? FileName, string? ContentType, long SizeBytes, string ScanStatus, DateTime CreatedAt)>(
            new CommandDefinition("SELECT VersionNo, FileName, ContentType, SizeBytes, ScanStatus, CreatedAt FROM doc.DocumentVersion WHERE DocumentId = @d ORDER BY VersionNo DESC;",
                new { d = d.DocumentId }, cancellationToken: http.RequestAborted));
        ETags.Set(http.Response, d.RowVersion);
        return Results.Ok(new
        {
            document = Shape(d, Today(clock), await HorizonAsync(u.Connection, http.RequestAborted)),
            versions = versions.Select(v => new { version = v.VersionNo, fileName = v.FileName, contentType = v.ContentType, sizeBytes = v.SizeBytes, scanStatus = v.ScanStatus, createdAt = v.CreatedAt }),
        });
    }

    // ---------- upload ----------

    internal sealed record Checked(byte[] Content, string ContentType, string FileName, byte[] Sha256);

    /// <summary>The file of the form, checked against the type: content not name, allowed types, size (FR-PLT-029, BR-PLT-011).</summary>
    internal static async Task<Checked> ReadFileAsync(IFormFile? file, DocType type, CancellationToken ct)
    {
        if (file is null || file.Length == 0) throw ApiProblemException.Invalid("FILE_REQUIRED", "Choose a file.");
        var maxMb = type.MaxSizeMb ?? DefaultMaxMb;
        if (file.Length > maxMb * 1024L * 1024L) throw ApiProblemException.Invalid("FILE_TOO_LARGE", $"The file is larger than {maxMb} MB.");
        using var ms = new MemoryStream();
        await file.CopyToAsync(ms, ct);
        var content = ms.ToArray();
        var detected = ContentSniffer.Detect(content);
        var allowed = type.AllowedMime is { Length: > 0 } json ? JsonSerializer.Deserialize<string[]>(json) ?? DefaultMime : DefaultMime;
        if (detected is null || !allowed.Contains(detected, StringComparer.OrdinalIgnoreCase))
            throw ApiProblemException.Invalid("FILE_TYPE_NOT_ALLOWED", "This kind of file is not accepted for this document type.");
        var name = Path.GetFileName(file.FileName);
        return new Checked(content, detected, name.Length > 260 ? name[^260..] : name, SHA256.HashData(content));
    }

    private static DateTime? Date(string? text, string field) =>
        string.IsNullOrWhiteSpace(text) ? null
        : DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
        : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is a date YYYY-MM-DD.");

    internal static async Task<DocType> TypeAsync(BoundUser u, SqlTransaction? tx, string? code, CancellationToken ct) =>
        await u.Connection.QuerySingleOrDefaultAsync<DocType>(new CommandDefinition(
            "SELECT DocumentTypeId, Code, NameAr, NameEn, RequiresExpiry, IsSensitive, AllowedMime, MaxSizeMb, AppliesTo, IsActive FROM cat.DocumentType WHERE Code = @code;",
            new { code }, tx, cancellationToken: ct)) is { IsActive: true } t ? t
        : throw ApiProblemException.Invalid("DOCUMENT_TYPE_UNKNOWN", "Choose a document type from the list.");

    private static async Task RequireRestrictedAsync(BoundUser u, DocType type, CancellationToken ct)
    {
        if (!type.IsSensitive) return;
        var perms = await u.PermissionsAsync(ct);
        if (!Restricted.Any(perms.Contains)) throw ApiProblemException.Forbidden("RESTRICTED_DOCUMENT", "Only the treasury manager and the financial officer handle this document type.");
    }

    /// <summary>The path of a version in the store: the tenant's PublicId first, never its code (DOC-S02 section 8).</summary>
    private static string StorageKey(Guid tenant, Guid document, int version) =>
        string.Create(CultureInfo.InvariantCulture, $"{tenant:N}/{document:N}/v{version}-{Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant()}");

    /// <summary>Scans, encrypts and writes a version; returns its row values. The file is removed if the transaction does not commit.</summary>
    private static async Task<(string StorageKey, long KeyId, ScanResult Scan)> StoreAsync(BoundUser u, SqlTransaction tx, TenantKeyRing keys, FileStore store,
        IMalwareScanner scanner, Checked file, Guid tenant, Guid document, int version, CancellationToken ct)
    {
        var scan = await scanner.ScanAsync(file.Content, ct);
        var (keyId, key) = await keys.ActiveAsync(u.Connection, tx, u.TenantId, "FILE", ct);
        var storageKey = StorageKey(tenant, document, version);
        await store.WriteAsync(storageKey, FileCrypto.Encrypt(key, file.Content, u.TenantId, storageKey, version), ct);
        return (storageKey, keyId, scan);
    }

    private static Task<long> InsertVersionAsync(BoundUser u, SqlTransaction tx, long documentId, int version, Checked file, string storageKey, long keyId,
        ScanResult scan, CancellationToken ct) =>
        u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT doc.DocumentVersion (TenantId, DocumentId, VersionNo, StorageKey, FileName, ContentType, SizeBytes, Sha256, KeyId, ScanStatus, ScannedAt, ScanDetail, CreatedBy)
            OUTPUT inserted.DocumentVersionId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @d, @v, @key, @name, @type, @size, @sha, @keyId, @scan, SYSUTCDATETIME(), @detail,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            UPDATE doc.Document SET CurrentVersionId = (SELECT Id FROM @o), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE DocumentId = @d;
            SELECT Id FROM @o;
            """,
            new
            {
                d = documentId, v = version, key = storageKey, name = file.FileName, type = file.ContentType, size = (long)file.Content.Length, sha = file.Sha256,
                keyId, scan = scan.Clean ? "CLEAN" : "QUARANTINED", detail = scan.Detail.Length > 300 ? scan.Detail[..300] : scan.Detail,
            }, tx, cancellationToken: ct));

    /// <summary>Another document of the tenant with the same bytes (FR-PLT-029: a warning, not a refusal).</summary>
    private static Task<Guid?> DuplicateOfAsync(BoundUser u, SqlTransaction tx, byte[] sha, long? exceptDocument, CancellationToken ct) =>
        u.Connection.ExecuteScalarAsync<Guid?>(new CommandDefinition(
            """
            SELECT TOP (1) d.PublicId FROM doc.DocumentVersion AS v JOIN doc.Document AS d ON d.DocumentId = v.DocumentId
             WHERE v.Sha256 = @sha AND d.Status <> 'SOFT_DELETED' AND d.DocumentId <> ISNULL(@except, -1);
            """, new { sha, except = exceptDocument }, tx, cancellationToken: ct));

    internal static async Task<IResult> UploadAsync(HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, FileStore store, IMalwareScanner scanner)
    {
        if (!http.Request.HasFormContentType) throw ApiProblemException.Invalid("FILE_REQUIRED", "Send the file as multipart/form-data.");
        var form = await http.Request.ReadFormAsync(http.RequestAborted);
        string? F(string k) => form[k].ToString() is { Length: > 0 } v ? v.Trim() : null;
        var title = F("title");
        if (title is null || title.Length > 200) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter a title (up to 200 characters).");
        var issue = Date(F("issueDate"), "issue date");
        var expiry = Date(F("expiryDate"), "expiry date");
        if (issue is not null && expiry is not null && expiry <= issue) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The expiry date comes after the issue date.");

        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var type = await TypeAsync(u, null, F("documentType"), http.RequestAborted);
        await RequireRestrictedAsync(u, type, http.RequestAborted);
        if (type.RequiresExpiry && expiry is null) throw ApiProblemException.Invalid("EXPIRY_REQUIRED", "This document type needs an expiry date.");
        (long Id, Guid PublicId)? company = null;
        if (Guid.TryParse(F("company"), out var cid))
        {
            company = await u.Connection.QuerySingleOrDefaultAsync<(long, Guid)>(new CommandDefinition(
                "SELECT CompanyId, PublicId FROM org.Company WHERE PublicId = @cid AND Status <> 'ARCHIVED';", new { cid }, cancellationToken: http.RequestAborted));
            if (company is not { Item1: > 0 } || !scope.Allows(company.Value.Id)) throw ApiProblemException.Invalid("COMPANY_NOT_FOUND", "The company does not exist or is outside your scope.");
        }
        else if (!scope.All) throw ApiProblemException.Invalid("COMPANY_REQUIRED", "Choose the company the document belongs to.");
        var file = await ReadFileAsync(form.Files["file"], type, http.RequestAborted);
        var meta = new DocMeta(title, F("documentNumber"), issue, F("issueDateHijri"), expiry, F("expiryDateHijri"), F("issuingAuthority"));
        var created = await CreateAsync(u, type, file, meta, company, company is null ? null : ("org.Company", company.Value.Id, "ATTACHMENT"), keys, store, scanner,
            http.RequestAborted);
        return Results.Created($"/api/v1/documents/{created.Id}", new { id = created.Id, version = 1, scanStatus = created.ScanStatus, duplicateOf = created.DuplicateOf });
    }

    internal sealed record DocMeta(string Title, string? Number, DateTime? Issue, string? IssueHijri, DateTime? Expiry, string? ExpiryHijri, string? Authority);

    /// <summary>
    /// A new document with its first version in one transaction: the Document row, the encrypted file, Version 1 and
    /// CurrentVersionId, the link to its entity, the outbox event and the audit row. Shared by the register, the company
    /// tab and the identity images (FR-PTY-009).
    /// </summary>
    internal static async Task<(Guid Id, long DocumentId, string ScanStatus, Guid? DuplicateOf)> CreateAsync(BoundUser u, DocType type, Checked file, DocMeta meta,
        (long Id, Guid PublicId)? company, (string EntityType, long EntityId, string Role)? link, TenantKeyRing keys, FileStore store, IMalwareScanner scanner,
        CancellationToken ct)
    {
        var tenant = await u.Connection.ExecuteScalarAsync<Guid>(new CommandDefinition("SELECT PublicId FROM plat.v_CurrentTenant;", cancellationToken: ct));
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var doc = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT doc.Document (TenantId, DocumentTypeId, Title, DocumentNumber, IssueDate, IssueDateHijriText, ExpiryDate, ExpiryDateHijriText, IssuingAuthority,
                                 OwnerCompanyId, Sensitivity, CreatedBy)
            OUTPUT inserted.DocumentId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @type, @title, @num, @issue, @issueH, @expiry, @expiryH, @auth, @company, @sens,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """,
            new
            {
                type = type.DocumentTypeId, title = meta.Title, num = meta.Number, issue = meta.Issue, issueH = meta.IssueHijri, expiry = meta.Expiry,
                expiryH = meta.ExpiryHijri, auth = meta.Authority, company = company?.Id, sens = type.IsSensitive ? "RESTRICTED" : "CONFIDENTIAL",
            }, tx, cancellationToken: ct));
        var (storageKey, keyId, scan) = await StoreAsync(u, tx, keys, store, scanner, file, tenant, doc.PublicId, 1, ct);
        try
        {
            await InsertVersionAsync(u, tx, doc.Id, 1, file, storageKey, keyId, scan, ct);
            if (link is { } l)
                await u.Connection.ExecuteAsync(new CommandDefinition(
                    "INSERT doc.DocumentLink (TenantId, DocumentId, EntityType, EntityId, LinkRole, CreatedBy) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @d, @t, @e, @r, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));",
                    new { d = doc.Id, t = l.EntityType, e = l.EntityId, r = l.Role }, tx, cancellationToken: ct));
            var duplicate = await DuplicateOfAsync(u, tx, file.Sha256, doc.Id, ct);
            await Outbox.EmitAsync(u.Connection, tx, "document.uploaded", "doc.Document", doc.Id,
                new { document = doc.PublicId, type = type.Code, version = 1, scan = scan.Clean ? "CLEAN" : "QUARANTINED" }, ct);
            await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("DOCUMENT_UPLOADED", type.IsSensitive ? "IDENTITY_ACCESS" : "TREASURY", "doc.Document", doc.Id,
                AfterJson: JsonSerializer.Serialize(new { type = type.Code, title = meta.Title, version = 1, sizeBytes = file.Content.Length, scan = scan.Detail, duplicateOf = duplicate, link = link?.EntityType }),
                Severity: scan.Clean ? "INFO" : "HIGH"), company?.Id, ct);
            await tx.CommitAsync(ct);
            return (doc.PublicId, doc.Id, scan.Clean ? "CLEAN" : "QUARANTINED", duplicate);
        }
        catch
        {
            store.DeleteUncommitted(storageKey);
            throw;
        }
    }

    private static async Task<IResult> NewVersionAsync(Guid id, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, FileStore store, IMalwareScanner scanner)
    {
        if (!http.Request.HasFormContentType) throw ApiProblemException.Invalid("FILE_REQUIRED", "Send the file as multipart/form-data.");
        var form = await http.Request.ReadFormAsync(http.RequestAborted);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var d = await FindAsync(u, null, id, scope, http.RequestAborted);
        if (d.Status != "ACTIVE") throw new ApiProblemException(409, "DOCUMENT_NOT_ACTIVE", "This document is not active.");
        var type = await TypeAsync(u, null, d.TypeCode, http.RequestAborted);
        await RequireRestrictedAsync(u, type, http.RequestAborted);
        var file = await ReadFileAsync(form.Files["file"], type, http.RequestAborted);
        var tenant = await u.Connection.ExecuteScalarAsync<Guid>(new CommandDefinition("SELECT PublicId FROM plat.v_CurrentTenant;", cancellationToken: http.RequestAborted));
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var version = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT ISNULL(MAX(VersionNo), 0) + 1 FROM doc.DocumentVersion WITH (UPDLOCK, HOLDLOCK) WHERE DocumentId = @d;", new { d = d.DocumentId }, tx,
            cancellationToken: http.RequestAborted));
        var (storageKey, keyId, scan) = await StoreAsync(u, tx, keys, store, scanner, file, tenant, d.PublicId, version, http.RequestAborted);
        try
        {
            await InsertVersionAsync(u, tx, d.DocumentId, version, file, storageKey, keyId, scan, http.RequestAborted);
            await Outbox.EmitAsync(u.Connection, tx, "document.version_added", "doc.Document", d.DocumentId,
                new { document = d.PublicId, version, scan = scan.Clean ? "CLEAN" : "QUARANTINED" }, http.RequestAborted);
            await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("DOCUMENT_VERSION_ADDED", "TREASURY", "doc.Document", d.DocumentId,
                AfterJson: JsonSerializer.Serialize(new { version, sizeBytes = file.Content.Length, scan = scan.Detail })), d.OwnerCompanyId, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
        }
        catch
        {
            store.DeleteUncommitted(storageKey);
            throw;
        }
        return Results.Created($"/api/v1/documents/{d.PublicId}", new { id = d.PublicId, version, scanStatus = scan.Clean ? "CLEAN" : "QUARANTINED" });
    }

    // ---------- metadata, download, delete ----------

    private static async Task<IResult> PatchAsync(Guid id, DocumentPatch body, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var d = await FindAsync(u, null, id, scope, http.RequestAborted);
        var type = await TypeAsync(u, null, d.TypeCode, http.RequestAborted);
        await RequireRestrictedAsync(u, type, http.RequestAborted);
        var issue = body.IssueDate is null ? d.IssueDate : Date(body.IssueDate, "issue date");
        var expiry = body.ExpiryDate is null ? d.ExpiryDate : Date(body.ExpiryDate, "expiry date");
        if (type.RequiresExpiry && expiry is null) throw ApiProblemException.Invalid("EXPIRY_REQUIRED", "This document type needs an expiry date.");
        if (issue is not null && expiry is not null && expiry <= issue) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The expiry date comes after the issue date.");
        if (body.Title is not null && (body.Title.Trim().Length is 0 or > 200)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter a title (up to 200 characters).");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE doc.Document SET Title = ISNULL(@title, Title), DocumentNumber = ISNULL(@num, DocumentNumber), IssueDate = @issue,
                   IssueDateHijriText = ISNULL(@issueH, IssueDateHijriText), ExpiryDate = @expiry, ExpiryDateHijriText = ISNULL(@expiryH, ExpiryDateHijriText),
                   IssuingAuthority = ISNULL(@auth, IssuingAuthority), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.RowVersion INTO @o WHERE DocumentId = @id AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """,
            new
            {
                title = body.Title?.Trim(), num = body.DocumentNumber, issue, issueH = body.IssueDateHijriText, expiry, expiryH = body.ExpiryDateHijriText,
                auth = body.IssuingAuthority, id = d.DocumentId, rv = expected,
            }, tx, cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("DOCUMENT_UPDATED", "TREASURY", "doc.Document", d.DocumentId,
            BeforeJson: JsonSerializer.Serialize(new { d.Title, d.DocumentNumber, d.IssueDate, d.ExpiryDate, d.IssuingAuthority }),
            AfterJson: JsonSerializer.Serialize(body)), d.OwnerCompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    private static async Task<IResult> ContentAsync(Guid id, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, FileStore store)
    {
        Query.Allow(http.Request, "version");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var d = await FindAsync(u, null, id, scope, http.RequestAborted);
        var restricted = d.Sensitivity == "RESTRICTED";
        if (restricted)
        {
            var perms = await u.PermissionsAsync(http.RequestAborted);
            if (!Restricted.Any(perms.Contains))
            {
                await AuditWriter.SensitiveAccessAsync(u.Connection, null, "SENSITIVE_DOCUMENT_DOWNLOAD", "DOCUMENT_DOWNLOAD_DENIED", "doc.Document", d.DocumentId,
                    null, d.OwnerCompanyId, false, "NO_PERMISSION", null, http.Request.Headers.UserAgent.ToString(), http.RequestAborted);
                throw ApiProblemException.Forbidden("RESTRICTED_DOCUMENT", "Only the treasury manager and the financial officer handle this document type.");
            }
        }
        int? wanted = int.TryParse(http.Request.Query["version"], CultureInfo.InvariantCulture, out var vn) ? vn : null;
        var v = await u.Connection.QuerySingleOrDefaultAsync<(int VersionNo, string StorageKey, string? FileName, string? ContentType, long KeyId, string ScanStatus, byte[] Sha256)>(
            new CommandDefinition(
                """
                SELECT VersionNo, StorageKey, FileName, ContentType, KeyId, ScanStatus, Sha256 FROM doc.DocumentVersion
                 WHERE DocumentId = @d AND (VersionNo = @v OR (@v IS NULL AND DocumentVersionId = (SELECT CurrentVersionId FROM doc.Document WHERE DocumentId = @d)));
                """, new { d = d.DocumentId, v = wanted }, cancellationToken: http.RequestAborted));
        if (v.StorageKey is null) throw ApiProblemException.NotFound();
        if (v.ScanStatus != "CLEAN") throw new ApiProblemException(409, "FILE_NOT_CLEAN", "This file is held in quarantine and cannot be downloaded.");
        var key = await keys.ByIdAsync(u.Connection, null, u.TenantId, v.KeyId, http.RequestAborted);
        var encrypted = await store.ReadAsync(v.StorageKey, http.RequestAborted);
        var content = FileCrypto.Decrypt(key, encrypted, u.TenantId, v.StorageKey, v.VersionNo);
        if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(content), v.Sha256))
            throw new InvalidOperationException("A stored file does not match its SHA-256.");
        if (restricted)
            await AuditWriter.SensitiveAccessAsync(u.Connection, null, "SENSITIVE_DOCUMENT_DOWNLOAD", "DOCUMENT_DOWNLOADED", "doc.Document", d.DocumentId, null,
                d.OwnerCompanyId, true, null, null, http.Request.Headers.UserAgent.ToString(), http.RequestAborted);
        else
            await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("DOCUMENT_DOWNLOADED", "TREASURY", "doc.Document", d.DocumentId,
                AfterJson: JsonSerializer.Serialize(new { version = v.VersionNo })), d.OwnerCompanyId, http.RequestAborted);
        http.Response.Headers.CacheControl = "no-store";
        return Results.File(content, v.ContentType ?? "application/octet-stream", v.FileName ?? $"document-v{v.VersionNo}");
    }

    private static async Task<IResult> DeleteAsync(Guid id, DocumentDeleteRequest body, HttpContext http, SqlConnectionFactory db)
    {
        if (string.IsNullOrWhiteSpace(body.Reason) || body.Reason.Length > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason (up to 500 characters).");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var d = await FindAsync(u, null, id, scope, http.RequestAborted);
        if (d.Status == "SOFT_DELETED") throw new ApiProblemException(409, "DOCUMENT_NOT_ACTIVE", "This document is not active.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE doc.Document SET Status = 'SOFT_DELETED', DeletedAt = SYSUTCDATETIME(), DeletedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), DeleteReason = @r,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE DocumentId = @id;
            """, new { r = body.Reason.Trim(), id = d.DocumentId }, tx, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("DOCUMENT_DELETED", "TREASURY", "doc.Document", d.DocumentId,
            AfterJson: JsonSerializer.Serialize(new { reason = body.Reason.Trim() }), Severity: "HIGH"), d.OwnerCompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }
}

using System.Data;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record SignatoryRequest(Guid? Party, string? SignatureClass, string? Position, string? JobTitle, string? AuthorisationBasis, string? SignatureType,
    Guid? AuthorizationDocument, Guid? SpecimenDocument, string? ValidFrom, string? ValidTo, string? Notes);
public sealed record SignatoryActionRequest(string? Reason);
public sealed record AuthorityRequest(Guid? Account, string? OperationType, string? CeilingMode, decimal? MaxPerTransaction, decimal? DailyLimit, string? Currency,
    bool? IsJoint, int? JointMinCosigners, List<string>? JointClasses, string? ValidFrom, string? ValidTo, Guid? SourceDocument);

/// <summary>
/// Bank signatories and their authorities (FR-ACC-012 to 017, 019, 022, 023; BR-ACC-008 to 013, 017; SCR-ACC-02 to 05).
/// A signatory is a natural person of an active relationship, one open row per (relationship, person, class). It stays
/// PENDING until its authorisation document is clean and of a type that applies to signatories and its start date has
/// come (owner default OQ-14); then it is ACTIVE. ACTIVE and SUSPENDED move both ways; REVOKED and EXPIRED are final
/// (043). A renewal is a new row with a new document and period that copies the open authorities and their joint
/// classes. An authority is never edited in place: a change closes the row the day before and opens the new one,
/// pointing back with SupersededById (FR-ACC-017; 061 denies the update of its terms). SVC-03 answers the effective
/// authority: the account's own row, then its master's, then the bank row (BR-ACC-012).
/// </summary>
public static class SignatoryEndpoints
{
    private const string View = "sig.view";
    private const string Manage = "sig.manage";
    private const string Module = "INSTITUTIONS";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/relationships/{id:guid}/signatories", ListAsync);
        api.MapPost("/relationships/{id:guid}/signatories", CreateAsync);
        api.MapGet("/signatories/{id:guid}", GetAsync);
        api.MapPatch("/signatories/{id:guid}", PatchAsync);
        api.MapPost("/signatories/{id:guid}/actions/suspend", (Guid id, SignatoryActionRequest b, HttpContext http, SqlConnectionFactory db) => StatusAsync(id, b, http, db, "SUSPENDED"));
        api.MapPost("/signatories/{id:guid}/actions/resume", (Guid id, SignatoryActionRequest b, HttpContext http, SqlConnectionFactory db) => StatusAsync(id, b, http, db, "ACTIVE"));
        api.MapPost("/signatories/{id:guid}/actions/revoke", (Guid id, SignatoryActionRequest b, HttpContext http, SqlConnectionFactory db) => StatusAsync(id, b, http, db, "REVOKED"));
        api.MapPost("/signatories/{id:guid}/actions/renew", RenewAsync);
        api.MapGet("/signatories/{id:guid}/authorities", AuthoritiesAsync);
        api.MapPost("/signatories/{id:guid}/authorities", AddAuthorityAsync);
        api.MapPost("/signatories/{id:guid}/authorities/{reference}/actions/end", EndAuthorityAsync);
        api.MapGet("/services/effective-authority", EffectiveAsync);
        api.MapGet("/reports/accounts-without-signatory", WithoutSignatoryAsync);
        api.MapGet("/reports/signatory-expiries", ExpiriesAsync);
    }

    internal sealed class SignatoryRow
    {
        public long SignatoryId { get; init; }
        public Guid PublicId { get; init; }
        public long RelationshipId { get; init; }
        public Guid RelationshipPublicId { get; init; }
        public long CompanyId { get; init; }
        public string RelationshipStatus { get; init; } = "";
        public long PartyId { get; init; }
        public Guid PartyPublicId { get; init; }
        public string PartyNameAr { get; init; } = "";
        public string? PartyNameEn { get; init; }
        public long SignatureClassId { get; init; }
        public string SignatureClass { get; init; } = "";
        public string? Position { get; init; }
        public string? JobTitle { get; init; }
        public string? AuthorisationBasis { get; init; }
        public string? SignatureType { get; init; }
        public long? AuthorizationDocumentId { get; init; }
        public Guid? AuthorizationDocument { get; init; }
        public DateTime? DocumentExpiry { get; init; }
        public Guid? SpecimenDocument { get; init; }
        public DateTime ValidFrom { get; init; }
        public DateTime? ValidTo { get; init; }
        public string Status { get; init; } = "";
        public DateTime? RevokedAt { get; init; }
        public string? RevokedReason { get; init; }
        public string? Notes { get; init; }
        public byte[] RowVersion { get; init; } = [];
    }

    private const string Select =
        """
        SELECT s.SignatoryId, s.PublicId, s.RelationshipId, r.PublicId AS RelationshipPublicId, r.CompanyId, r.Status AS RelationshipStatus, s.PartyId,
               p.PublicId AS PartyPublicId, p.NameAr AS PartyNameAr, p.NameEn AS PartyNameEn, s.SignatureClassId, cls.Code AS SignatureClass, pos.Code AS Position,
               s.JobTitle, ab.Code AS AuthorisationBasis, s.SignatureType, s.AuthorizationDocumentId, d.PublicId AS AuthorizationDocument, d.ExpiryDate AS DocumentExpiry,
               sp.PublicId AS SpecimenDocument, s.ValidFrom, s.ValidTo, s.Status, s.RevokedAt, s.RevokedReason, s.Notes, s.RowVersion
          FROM acc.Signatory AS s
          JOIN ins.Relationship AS r ON r.RelationshipId = s.RelationshipId
          JOIN pty.Party AS p ON p.PartyId = s.PartyId
          JOIN cat.LookupItem AS cls ON cls.LookupItemId = s.SignatureClassId
          LEFT JOIN cat.Position AS pos ON pos.PositionId = s.PositionId
          LEFT JOIN cat.LookupItem AS ab ON ab.LookupItemId = s.AuthorisationBasisId
          LEFT JOIN doc.Document AS d ON d.DocumentId = s.AuthorizationDocumentId
          LEFT JOIN doc.Document AS sp ON sp.DocumentId = s.SpecimenDocumentId
        """;

    internal sealed class AuthorityRow
    {
        public long SignatoryAuthorityId { get; init; }
        public long SignatoryId { get; init; }
        public long RelationshipId { get; init; }
        public long? BankAccountId { get; init; }
        public Guid? Account { get; init; }
        public string? AccountMask { get; init; }
        public int OperationTypeId { get; init; }
        public string OperationType { get; init; } = "";
        public string CeilingMode { get; init; } = "";
        public decimal? MaxPerTransaction { get; init; }
        public decimal? DailyLimit { get; init; }
        public int? CurrencyId { get; init; }
        public string? Currency { get; init; }
        public bool IsJoint { get; init; }
        public int? JointMinCosigners { get; init; }
        public string? JointClasses { get; init; }
        public DateTime ValidFrom { get; init; }
        public DateTime? ValidTo { get; init; }
        public long? SourceDocumentId { get; init; }
        public long? SupersededById { get; init; }
    }

    internal const string AuthoritySelect =
        """
        SELECT a.SignatoryAuthorityId, a.SignatoryId, a.RelationshipId, a.BankAccountId, ba.PublicId AS Account, ba.AccountNoMask AS AccountMask, a.OperationTypeId,
               o.Code AS OperationType, a.CeilingMode, a.MaxPerTransaction, a.DailyLimit, a.CurrencyId, cu.Code AS Currency, a.IsJoint, a.JointMinCosigners,
               (SELECT STRING_AGG(li.Code, ',') FROM acc.SignatoryAuthorityJointClass AS j JOIN cat.LookupItem AS li ON li.LookupItemId = j.SignatureClassId
                 WHERE j.SignatoryAuthorityId = a.SignatoryAuthorityId) AS JointClasses,
               a.ValidFrom, a.ValidTo, a.SourceDocumentId, a.SupersededById
          FROM acc.SignatoryAuthority AS a
          JOIN cat.OperationType AS o ON o.OperationTypeId = a.OperationTypeId
          LEFT JOIN acc.BankAccount AS ba ON ba.BankAccountId = a.BankAccountId
          LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = a.CurrencyId
        """;

    private static string D(DateTime d) => GovernanceEndpoints.D(d);

    /// <summary>Derived (11m:455): SCHEDULED, EFFECTIVE, EXPIRED or SUPERSEDED.</summary>
    internal static string State(AuthorityRow a, DateTime today) =>
        a.SupersededById is not null ? "SUPERSEDED" : a.ValidFrom > today ? "SCHEDULED" : a.ValidTo is { } t && t < today ? "EXPIRED" : "EFFECTIVE";

    private static object ShapeAuthority(AuthorityRow a, DateTime today, int tenant, OpaqueRefs refs) => new
    {
        id = refs.ItemRef(tenant, "signatory-authority", a.SignatoryAuthorityId),
        account = a.Account is null ? null : new { id = a.Account, mask = a.AccountMask },
        operationType = a.OperationType, ceilingMode = a.CeilingMode, maxPerTransaction = a.MaxPerTransaction, dailyLimit = a.DailyLimit, currency = a.Currency,
        isJoint = a.IsJoint, jointMinCosigners = a.JointMinCosigners, jointClasses = a.JointClasses?.Split(',') ?? [],
        validFrom = D(a.ValidFrom), validTo = a.ValidTo is { } t ? D(t) : null, state = State(a, today),
    };

    private static object Shape(SignatoryRow s, bool images) => new
    {
        id = s.PublicId, relationship = s.RelationshipPublicId, party = new { id = s.PartyPublicId, nameAr = s.PartyNameAr, nameEn = s.PartyNameEn },
        signatureClass = s.SignatureClass, position = s.Position, jobTitle = s.JobTitle, authorisationBasis = s.AuthorisationBasis, signatureType = s.SignatureType,
        authorizationDocument = s.AuthorizationDocument, documentExpiry = s.DocumentExpiry is { } e ? D(e) : null,
        // The specimen is a restricted image (FR-ACC-022): its id is given only to those who may view it.
        hasSpecimen = s.SpecimenDocument is not null, specimenDocument = images ? s.SpecimenDocument : null,
        validFrom = D(s.ValidFrom), validTo = s.ValidTo is { } t ? D(t) : null, status = s.Status, revokedAt = s.RevokedAt, revokedReason = s.RevokedReason,
        notes = s.Notes, etag = ETags.Of(s.RowVersion),
    };

    private static async Task<BoundUser> OpenAsync(HttpContext http, SqlConnectionFactory db, string permission)
    {
        var u = await BoundUser.OpenAsync(http, db, permission);
        try
        {
            await u.RequireModuleAsync(Module, http.RequestAborted);
            return u;
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }

    private static async Task<(long Id, long CompanyId, long InstitutionId, string Status)> RelationshipAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope,
        CancellationToken ct)
    {
        var r = await u.Connection.QuerySingleOrDefaultAsync<(long Id, long CompanyId, long InstitutionId, string Status)>(new CommandDefinition(
            "SELECT RelationshipId, CompanyId, InstitutionId, Status FROM ins.Relationship WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct));
        return r.Id != 0 && scope.Allows(r.CompanyId) ? r : throw ApiProblemException.NotFound();
    }

    internal static async Task<SignatoryRow> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct)
    {
        var s = await u.Connection.QuerySingleOrDefaultAsync<SignatoryRow>(new CommandDefinition(Select + " WHERE s.PublicId = @id;", new { id }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        return scope.Allows(s.CompanyId) ? s : throw ApiProblemException.NotFound();
    }

    private static async Task<long> LookupAsync(BoundUser u, SqlTransaction tx, string list, string? code, string what, CancellationToken ct) =>
        await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            """
            SELECT i.LookupItemId FROM cat.LookupItem AS i JOIN cat.LookupList AS l ON l.LookupListId = i.LookupListId
             WHERE l.Code = @list AND i.Code = @code AND i.Status = 'ACTIVE';
            """, new { list, code = code?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {what} is not an active item of its list.");

    /// <summary>OQ-14: the authorisation document is an active document whose current version is clean and whose type applies to signatories.</summary>
    private static async Task<(long Id, bool Clean)?> AuthorisationDocumentAsync(BoundUser u, SqlTransaction tx, Guid? id, long companyId, CancellationToken ct)
    {
        if (id is null) return null;
        var d = await u.Connection.QuerySingleOrDefaultAsync<(long Id, string? AppliesTo, string? Scan)>(new CommandDefinition(
            """
            SELECT d.DocumentId, t.AppliesTo, v.ScanStatus FROM doc.Document AS d JOIN cat.DocumentType AS t ON t.DocumentTypeId = d.DocumentTypeId
              LEFT JOIN doc.DocumentVersion AS v ON v.DocumentVersionId = d.CurrentVersionId
             WHERE d.PublicId = @d AND d.Status = 'ACTIVE' AND (d.OwnerCompanyId IS NULL OR d.OwnerCompanyId = @c);
            """, new { d = id, c = companyId }, tx, cancellationToken: ct));
        if (d.Id == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is not an active document of this company.");
        if (d.AppliesTo is { Length: > 0 } a && !a.Split(',').Contains("SIGNATORY", StringComparer.Ordinal))
            throw ApiProblemException.Invalid("V-ACC-DOC-TYPE", "The document is not of a type that authorises a signatory.");
        return (d.Id, d.Scan == "CLEAN");
    }

    /// <summary>BR-ACC-009: PENDING becomes ACTIVE once its document is clean and its start date has come.</summary>
    internal static async Task<bool> TryActivateAsync(SqlConnection c, SqlTransaction tx, long signatoryId, DateTime today, CancellationToken ct)
    {
        var id = await c.ExecuteScalarAsync<Guid?>(new CommandDefinition(
            """
            DECLARE @o TABLE (PublicId UNIQUEIDENTIFIER);
            UPDATE s SET Status = 'ACTIVE', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.PublicId INTO @o
              FROM acc.Signatory AS s JOIN doc.Document AS d ON d.DocumentId = s.AuthorizationDocumentId AND d.Status = 'ACTIVE'
              JOIN doc.DocumentVersion AS v ON v.DocumentVersionId = d.CurrentVersionId AND v.ScanStatus = 'CLEAN'
             WHERE s.SignatoryId = @s AND s.Status = 'PENDING' AND s.ValidFrom <= @d AND (s.ValidTo IS NULL OR s.ValidTo >= @d);
            SELECT PublicId FROM @o;
            """, new { s = signatoryId, d = today }, tx, cancellationToken: ct));
        if (id is null) return false;
        await Outbox.EmitAsync(c, tx, "signatory.activated", "acc.Signatory", signatoryId, new { signatory = id }, ct);
        return true;
    }

    // ---------- reading ----------

    private static async Task<IResult> ListAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        await using var u = await OpenAsync(http, db, View);
        var rel = await RelationshipAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var images = (await u.PermissionsAsync(http.RequestAborted)).Contains("acc.signature.image.view");
        var rows = await u.Connection.QueryAsync<SignatoryRow>(new CommandDefinition(Select + " WHERE s.RelationshipId = @r ORDER BY cls.SortOrder, p.NameAr, s.ValidFrom;",
            new { r = rel.Id }, cancellationToken: http.RequestAborted));
        var authorities = (await u.Connection.QueryAsync<AuthorityRow>(new CommandDefinition(AuthoritySelect + " WHERE a.RelationshipId = @r ORDER BY o.SortOrder, a.ValidFrom;",
            new { r = rel.Id }, cancellationToken: http.RequestAborted))).ToLookup(a => a.SignatoryId);
        var today = GovernanceEndpoints.Today(clock);
        return Results.Ok(new
        {
            items = rows.Select(s => new
            {
                signatory = Shape(s, images),
                authorities = authorities[s.SignatoryId].Where(a => a.SupersededById is null).Select(a => ShapeAuthority(a, today, u.TenantId, refs)),
            }),
        });
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db, View);
        var s = await FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        ETags.Set(http.Response, s.RowVersion);
        return Results.Ok(Shape(s, (await u.PermissionsAsync(http.RequestAborted)).Contains("acc.signature.image.view")));
    }

    // ---------- signatories ----------

    private static async Task<IResult> CreateAsync(Guid id, SignatoryRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var from = GovernanceEndpoints.Date(b.ValidFrom, "start date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the start date.");
        var to = GovernanceEndpoints.Date(b.ValidTo, "end date");
        if (to is not null && to < from) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The mandate ends on or after its start.");
        var type = b.SignatureType?.Trim().ToUpperInvariant();
        if (type is not (null or "INDIVIDUAL" or "WITH_PRIMARY_SIGNATORY")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The signature is individual or with the primary signatory.");
        await using var u = await OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, http.RequestAborted);
        var rel = await RelationshipAsync(u, tx, id, scope, http.RequestAborted);
        if (rel.Status != "ACTIVE") throw new ApiProblemException(409, "V-ACC-RELATIONSHIP", "Signatories are added to an active relationship.");
        var party = await u.Connection.QuerySingleOrDefaultAsync<(long Id, string Kind, bool Active)>(new CommandDefinition(
            "SELECT PartyId, Kind, IsActive FROM pty.Party WHERE PublicId = @p;", new { p = b.Party }, tx, cancellationToken: http.RequestAborted));
        if (party.Id == 0 || !party.Active) throw ApiProblemException.Invalid("V-ACC-SIGNATORY-PERSON", "The signatory is an active person.");
        if (party.Kind != "INDIVIDUAL") throw ApiProblemException.Invalid("V-ACC-SIGNATORY-PERSON", "A signatory is a natural person (BR-ACC-008).");
        var cls = await LookupAsync(u, tx, "SIGNATURE_CLASS", b.SignatureClass, "signature class", http.RequestAborted);
        long? basis = b.AuthorisationBasis is null ? null : await LookupAsync(u, tx, "AUTHORISATION_BASIS", b.AuthorisationBasis, "authorisation basis", http.RequestAborted);
        int? position = b.Position is null ? null : await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT PositionId FROM cat.Position WHERE Code = @c AND IsActive = 1;", new { c = b.Position.Trim().ToUpperInvariant() }, tx, cancellationToken: http.RequestAborted))
            ?? throw ApiProblemException.Invalid("V-ORG-POSITION", "The position is not an active position of the catalogue.");
        var doc = await AuthorisationDocumentAsync(u, tx, b.AuthorizationDocument, rel.CompanyId, http.RequestAborted);
        long? specimen = b.SpecimenDocument is null ? null : await GovernanceEndpoints.DocumentAsync(u, tx, b.SpecimenDocument, rel.CompanyId, http.RequestAborted);
        // BR-ACC-008: no two periods of the same person and class in a relationship overlap.
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                """
                SELECT COUNT(*) FROM acc.Signatory WHERE RelationshipId = @r AND PartyId = @p AND SignatureClassId = @c AND Status <> 'REVOKED'
                   AND ValidFrom <= ISNULL(@to, '9999-12-31') AND ISNULL(ValidTo, '9999-12-31') >= @from;
                """, new { r = rel.Id, p = party.Id, c = cls, from, to }, tx, cancellationToken: http.RequestAborted)) > 0)
            throw ApiProblemException.Invalid("V-ACC-SIGNATORY-OVERLAP", "The person is already a signatory of this class in the relationship for part of the period.");
        var created = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (SignatoryId BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT acc.Signatory (TenantId, RelationshipId, PartyId, SignatureClassId, PositionId, JobTitle, AuthorisationBasisId, SignatureType, AuthorizationDocumentId,
                                  SpecimenDocumentId, ValidFrom, ValidTo, Status, Notes, CreatedBy)
            OUTPUT inserted.SignatoryId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @p, @c, @pos, @job, @basis, @type, @doc, @spec, @from, @to, 'PENDING', @notes, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT SignatoryId, PublicId FROM @o;
            """, new { r = rel.Id, p = party.Id, c = cls, pos = position, job = b.JobTitle?.Trim(), basis, type, doc = doc?.Id, spec = specimen, from, to, notes = b.Notes?.Trim() },
            tx, cancellationToken: http.RequestAborted));
        var active = await TryActivateAsync(u.Connection, tx, created.Id, GovernanceEndpoints.Today(clock), http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("SIGNATORY_ADDED", "TREASURY", "acc.Signatory", created.Id,
            AfterJson: JsonSerializer.Serialize(new { relationship = id, signatureClass = b.SignatureClass, from = D(from), active })), rel.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/signatories/{created.PublicId}", new { id = created.PublicId, status = active ? "ACTIVE" : "PENDING" });
    }

    /// <summary>The documents, the end date and the notes; attaching a clean authorisation document activates a pending signatory.</summary>
    private static async Task<IResult> PatchAsync(Guid id, SignatoryRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var s = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (!expected.AsSpan().SequenceEqual(s.RowVersion)) throw ETags.Conflict();
        if (s.Status is "REVOKED" or "EXPIRED") throw new ApiProblemException(409, "V-ACC-SIGNATORY-FINAL", "A revoked or expired signatory is not changed; renew it.");
        if (b.SpecimenDocument is not null && !(await u.PermissionsAsync(http.RequestAborted)).Contains("acc.signature.image.view"))
            throw ApiProblemException.Forbidden("RESTRICTED_DOCUMENT", "Only the treasury manager and the financial officer handle the specimen signature.");
        var doc = await AuthorisationDocumentAsync(u, tx, b.AuthorizationDocument, s.CompanyId, http.RequestAborted);
        long? specimen = b.SpecimenDocument is null ? null : await GovernanceEndpoints.DocumentAsync(u, tx, b.SpecimenDocument, s.CompanyId, http.RequestAborted);
        var to = b.ValidTo is null ? s.ValidTo : GovernanceEndpoints.Date(b.ValidTo, "end date");
        if (to is not null && to < s.ValidFrom) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The mandate ends on or after its start.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE acc.Signatory SET AuthorizationDocumentId = ISNULL(@doc, AuthorizationDocumentId), SpecimenDocumentId = ISNULL(@spec, SpecimenDocumentId), ValidTo = @to,
                   Notes = ISNULL(@notes, Notes), JobTitle = ISNULL(@job, JobTitle), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE SignatoryId = @s;
            """, new { s = s.SignatoryId, doc = doc?.Id, spec = specimen, to, notes = b.Notes?.Trim(), job = b.JobTitle?.Trim() }, tx, cancellationToken: http.RequestAborted));
        var active = await TryActivateAsync(u.Connection, tx, s.SignatoryId, GovernanceEndpoints.Today(clock), http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("SIGNATORY_UPDATED", "TREASURY", "acc.Signatory", s.SignatoryId,
            AfterJson: JsonSerializer.Serialize(new { document = b.AuthorizationDocument, specimen = b.SpecimenDocument is not null, validTo = to is { } t ? D(t) : null, activated = active })),
            s.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    private static async Task<IResult> StatusAsync(Guid id, SignatoryActionRequest b, HttpContext http, SqlConnectionFactory db, string to)
    {
        if (to == "REVOKED" && (string.IsNullOrWhiteSpace(b.Reason) || b.Reason.Length > 500)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason (up to 500 characters).");
        await using var u = await OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var s = await FindAsync(u, tx, id, scope, http.RequestAborted);
        var allowed = to switch
        {
            "SUSPENDED" => s.Status == "ACTIVE",
            "ACTIVE" => s.Status == "SUSPENDED",
            _ => s.Status is "PENDING" or "ACTIVE" or "SUSPENDED",
        };
        if (!allowed) throw new ApiProblemException(409, "V-ACC-SIGNATORY-STATE", "The signatory is not in a state that allows this.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE acc.Signatory SET Status = @to, RevokedAt = CASE WHEN @to = 'REVOKED' THEN SYSUTCDATETIME() END, RevokedReason = CASE WHEN @to = 'REVOKED' THEN @r END,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE SignatoryId = @s;
            """, new { s = s.SignatoryId, to, r = b.Reason?.Trim() }, tx, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(to switch { "SUSPENDED" => "SIGNATORY_SUSPENDED", "ACTIVE" => "SIGNATORY_RESUMED", _ => "SIGNATORY_REVOKED" },
            "TREASURY", "acc.Signatory", s.SignatoryId, AfterJson: JsonSerializer.Serialize(new { reason = b.Reason?.Trim() }), Severity: to == "REVOKED" ? "HIGH" : "INFO"),
            s.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>BR-ACC-008, FR-ACC-017: a renewal is a new row with its document and period; the open authorities and their joint classes are copied.</summary>
    private static async Task<IResult> RenewAsync(Guid id, SignatoryRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var from = GovernanceEndpoints.Date(b.ValidFrom, "start date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the start date.");
        var to = GovernanceEndpoints.Date(b.ValidTo, "end date");
        if (to is not null && to < from) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The mandate ends on or after its start.");
        if (b.AuthorizationDocument is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A renewal has its new authorisation document.");
        await using var u = await OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, http.RequestAborted);
        var s = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (s.Status == "REVOKED") throw new ApiProblemException(409, "V-ACC-SIGNATORY-FINAL", "A revoked signatory is not renewed; add a new one.");
        if (from <= s.ValidFrom) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The renewal starts after the start of the current mandate.");
        var doc = await AuthorisationDocumentAsync(u, tx, b.AuthorizationDocument, s.CompanyId, http.RequestAborted);
        // The current mandate ends the day before, unless it has ended already.
        if (s.Status is not "EXPIRED" && (s.ValidTo is null || s.ValidTo >= from))
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE acc.Signatory SET ValidTo = @end, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE SignatoryId = @s;",
                new { s = s.SignatoryId, end = from.AddDays(-1) }, tx, cancellationToken: http.RequestAborted));
        var created = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (SignatoryId BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT acc.Signatory (TenantId, RelationshipId, PartyId, SignatureClassId, PositionId, JobTitle, AuthorisationBasisId, SignatureType, CashWithdrawalMode,
                                  CashWithdrawalLimit, CashWithdrawalCurrencyId, AuthorizationDocumentId, SpecimenDocumentId, ValidFrom, ValidTo, Status, Notes, CreatedBy)
            OUTPUT inserted.SignatoryId, inserted.PublicId INTO @o
            SELECT TenantId, RelationshipId, PartyId, SignatureClassId, PositionId, JobTitle, AuthorisationBasisId, SignatureType, CashWithdrawalMode, CashWithdrawalLimit,
                   CashWithdrawalCurrencyId, @doc, SpecimenDocumentId, @from, @to, 'PENDING', Notes, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
              FROM acc.Signatory WHERE SignatoryId = @s;
            SELECT SignatoryId, PublicId FROM @o;
            """, new { s = s.SignatoryId, doc = doc!.Value.Id, from, to }, tx, cancellationToken: http.RequestAborted));
        var copied = 0;
        foreach (var a in await u.Connection.QueryAsync<AuthorityRow>(new CommandDefinition(AuthoritySelect +
                     " WHERE a.SignatoryId = @s AND a.SupersededById IS NULL AND (a.ValidTo IS NULL OR a.ValidTo >= @from);", new { s = s.SignatoryId, from }, tx,
                     cancellationToken: http.RequestAborted)))
        {
            var start = a.ValidFrom > from ? a.ValidFrom : from;
            var end = to is { } t && (a.ValidTo is null || a.ValidTo > t) ? t : a.ValidTo;
            var newId = await InsertAuthorityAsync(u.Connection, tx, created.Id, a.RelationshipId, a.BankAccountId, a.OperationTypeId, a.CeilingMode, a.MaxPerTransaction,
                a.DailyLimit, a.CurrencyId, a.IsJoint, a.JointMinCosigners, start, end, a.SourceDocumentId, http.RequestAborted);
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT acc.SignatoryAuthorityJointClass (TenantId, SignatoryAuthorityId, SignatureClassId)
                SELECT TenantId, @n, SignatureClassId FROM acc.SignatoryAuthorityJointClass WHERE SignatoryAuthorityId = @o;
                """, new { n = newId, o = a.SignatoryAuthorityId }, tx, cancellationToken: http.RequestAborted));
            copied++;
        }
        var active = await TryActivateAsync(u.Connection, tx, created.Id, GovernanceEndpoints.Today(clock), http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("SIGNATORY_RENEWED", "TREASURY", "acc.Signatory", created.Id,
            AfterJson: JsonSerializer.Serialize(new { renews = s.PublicId, from = D(from), copied })), s.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/signatories/{created.PublicId}", new { id = created.PublicId, status = active ? "ACTIVE" : "PENDING", copiedAuthorities = copied });
    }

    // ---------- authorities ----------

    private static async Task<long> InsertAuthorityAsync(SqlConnection c, SqlTransaction tx, long signatory, long relationship, long? account, int operation, string mode,
        decimal? max, decimal? daily, int? currency, bool joint, int? cosigners, DateTime from, DateTime? to, long? doc, CancellationToken ct) =>
        await c.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            INSERT acc.SignatoryAuthority (TenantId, RelationshipId, SignatoryId, BankAccountId, OperationTypeId, CeilingMode, MaxPerTransaction, DailyLimit, CurrencyId,
                                           IsJoint, JointMinCosigners, ValidFrom, ValidTo, SourceDocumentId, CreatedBy)
            OUTPUT inserted.SignatoryAuthorityId
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @s, @a, @o, @mode, @max, @daily, @cur, @joint, @co, @from, @to, @doc, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new { r = relationship, s = signatory, a = account, o = operation, mode, max, daily, cur = currency, joint, co = cosigners, from, to, doc }, tx,
            cancellationToken: ct));

    private static async Task<IResult> AuthoritiesAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        Query.Allow(http.Request, "includeHistory");
        await using var u = await OpenAsync(http, db, View);
        var s = await FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var history = string.Equals(http.Request.Query["includeHistory"], "true", StringComparison.OrdinalIgnoreCase);
        var rows = await u.Connection.QueryAsync<AuthorityRow>(new CommandDefinition(AuthoritySelect +
            " WHERE a.SignatoryId = @s AND (@h = 1 OR a.SupersededById IS NULL) ORDER BY o.SortOrder, a.ValidFrom;", new { s = s.SignatoryId, h = history },
            cancellationToken: http.RequestAborted));
        var today = GovernanceEndpoints.Today(clock);
        return Results.Ok(new { items = rows.Select(a => ShapeAuthority(a, today, u.TenantId, refs)) });
    }

    /// <summary>
    /// FR-ACC-013, 014, 017: an authority on an account of the relationship or on the whole bank. When an open row exists for
    /// the same account and operation, it closes the day before and the new row supersedes it. V-ACC-05 refuses, V-ACC-06
    /// warns when the period runs past the authorisation document's expiry.
    /// </summary>
    private static async Task<IResult> AddAuthorityAsync(Guid id, AuthorityRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var from = GovernanceEndpoints.Date(b.ValidFrom, "start date") ?? throw ApiProblemException.Invalid("V-ACC-05", "Give the start date.");
        var to = GovernanceEndpoints.Date(b.ValidTo, "end date");
        if (to is not null && to < from) throw ApiProblemException.Invalid("V-ACC-05", "The authority ends on or after its start.");
        var mode = b.CeilingMode?.Trim().ToUpperInvariant() ?? "UNSPECIFIED";
        if (mode is not ("LIMITED" or "UNLIMITED" or "UNSPECIFIED")) throw ApiProblemException.Invalid("V-ACC-05", "The ceiling is limited, unlimited or unspecified.");
        if (mode == "LIMITED" && b.MaxPerTransaction is null && b.DailyLimit is null)
            throw ApiProblemException.Invalid("V-ACC-05", "A limited authority has a ceiling per transaction or a daily limit.");
        if (mode != "LIMITED" && (b.MaxPerTransaction is not null || b.DailyLimit is not null))
            throw ApiProblemException.Invalid("V-ACC-05", "Only a limited authority has amounts.");
        if (b.MaxPerTransaction is <= 0 || b.DailyLimit is <= 0) throw ApiProblemException.Invalid("V-ACC-05", "The amounts are above zero.");
        if (b.MaxPerTransaction is { } m && b.DailyLimit is { } dl && dl < m)
            throw ApiProblemException.Invalid("V-ACC-05", "The daily limit is not below the ceiling per transaction (FR-ACC-014).");
        var joint = b.IsJoint == true;
        var cosigners = joint ? b.JointMinCosigners ?? 1 : (int?)null;
        if (cosigners is < 1) throw ApiProblemException.Invalid("V-ACC-05", "A joint authority needs at least one co-signer.");
        await using var u = await OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, http.RequestAborted);
        var s = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (s.Status is "REVOKED" or "EXPIRED") throw new ApiProblemException(409, "V-ACC-SIGNATORY-FINAL", "A revoked or expired signatory takes no authority.");
        if (from < s.ValidFrom || (s.ValidTo is { } sv && (to is null || to > sv)))
            throw ApiProblemException.Invalid("V-ACC-05", "The authority lies within the signatory's period (BR-ACC-010).");
        var op = await u.Connection.QuerySingleOrDefaultAsync<(int Id, bool SupportsCeiling)>(new CommandDefinition(
            "SELECT OperationTypeId, SupportsCeiling FROM cat.OperationType WHERE Code = @c AND IsActive = 1;", new { c = b.OperationType?.Trim().ToUpperInvariant() }, tx,
            cancellationToken: http.RequestAborted));
        if (op.Id == 0) throw ApiProblemException.Invalid("V-ACC-05", "The operation is not an active operation of the catalogue.");
        if (!op.SupportsCeiling && mode == "LIMITED") throw ApiProblemException.Invalid("V-ACC-05", "This operation takes no ceiling.");
        int? currency = null;
        if (mode == "LIMITED")
            currency = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @c;",
                new { c = b.Currency?.Trim().ToUpperInvariant() }, tx, cancellationToken: http.RequestAborted))
                ?? throw ApiProblemException.Invalid("V-ACC-05", "A limited authority has its currency.");
        long? account = null;
        if (b.Account is { } acc)
        {
            // The composite foreign key refuses an account of another relationship too (FR-ACC-013).
            account = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT BankAccountId FROM acc.BankAccount WHERE PublicId = @a AND RelationshipId = @r;", new { a = acc, r = s.RelationshipId }, tx, cancellationToken: http.RequestAborted))
                ?? throw ApiProblemException.Invalid("V-ACC-05", "The account is not an account of this relationship.");
        }
        var classes = new List<long>();
        if (joint)
            foreach (var code in b.JointClasses ?? [])
                classes.Add(await LookupAsync(u, tx, "SIGNATURE_CLASS", code, "signature class", http.RequestAborted));
        long? doc = b.SourceDocument is null ? s.AuthorizationDocumentId : await GovernanceEndpoints.DocumentAsync(u, tx, b.SourceDocument, s.CompanyId, http.RequestAborted);

        var open = await u.Connection.QuerySingleOrDefaultAsync<AuthorityRow>(new CommandDefinition(AuthoritySelect +
            " WHERE a.SignatoryId = @s AND a.OperationTypeId = @o AND ((a.BankAccountId IS NULL AND @a IS NULL) OR a.BankAccountId = @a) AND a.SupersededById IS NULL AND (a.ValidTo IS NULL OR a.ValidTo >= @from);",
            new { s = s.SignatoryId, o = op.Id, a = account, from }, tx, cancellationToken: http.RequestAborted));
        if (open is not null && open.ValidFrom >= from)
            throw ApiProblemException.Invalid("V-ACC-05", "An authority for this operation and account already starts on or after this date.");
        if (open is not null)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE acc.SignatoryAuthority SET ValidTo = @end, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE SignatoryAuthorityId = @id;",
                new { id = open.SignatoryAuthorityId, end = from.AddDays(-1) }, tx, cancellationToken: http.RequestAborted));
        var newId = await InsertAuthorityAsync(u.Connection, tx, s.SignatoryId, s.RelationshipId, account, op.Id, mode, b.MaxPerTransaction, b.DailyLimit, currency, joint,
            cosigners, from, to, doc, http.RequestAborted);
        foreach (var c in classes.Distinct())
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "INSERT acc.SignatoryAuthorityJointClass (TenantId, SignatoryAuthorityId, SignatureClassId) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @a, @c);",
                new { a = newId, c }, tx, cancellationToken: http.RequestAborted));
        if (open is not null)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE acc.SignatoryAuthority SET SupersededById = @n, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE SignatoryAuthorityId = @id;",
                new { id = open.SignatoryAuthorityId, n = newId }, tx, cancellationToken: http.RequestAborted));
        var warnings = new List<string>();
        if (s.DocumentExpiry is { } e && (to is null || to > e)) warnings.Add("V-ACC-06");
        await Outbox.EmitAsync(u.Connection, tx, "signatory.authority.changed", "acc.Signatory", s.SignatoryId, new { signatory = s.PublicId }, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(open is null ? "AUTHORITY_ADDED" : "AUTHORITY_SUPERSEDED", "TREASURY", "acc.SignatoryAuthority", newId,
            AfterJson: JsonSerializer.Serialize(new { operation = b.OperationType, mode, from = D(from), supersedes = open?.SignatoryAuthorityId })), s.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/signatories/{s.PublicId}/authorities", new { id = refs.ItemRef(u.TenantId, "signatory-authority", newId), warnings });
    }

    private static async Task<IResult> EndAuthorityAsync(Guid id, string reference, MemberEndRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var on = GovernanceEndpoints.Date(b.On, "end date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date.");
        await using var u = await OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var s = await FindAsync(u, tx, id, scope, http.RequestAborted);
        var aid = refs.ItemId(u.TenantId, "signatory-authority", reference) ?? throw ApiProblemException.NotFound();
        var a = await u.Connection.QuerySingleOrDefaultAsync<AuthorityRow>(new CommandDefinition(AuthoritySelect + " WHERE a.SignatoryAuthorityId = @a AND a.SignatoryId = @s;",
            new { a = aid, s = s.SignatoryId }, tx, cancellationToken: http.RequestAborted)) ?? throw ApiProblemException.NotFound();
        if (a.SupersededById is not null || (a.ValidTo is { } t && t <= on)) throw new ApiProblemException(409, "V-ACC-AUTHORITY-ENDED", "The authority has already ended.");
        if (on < a.ValidFrom) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The date is on or after the start of the authority.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE acc.SignatoryAuthority SET ValidTo = @on, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE SignatoryAuthorityId = @a;",
            new { a = aid, on }, tx, cancellationToken: http.RequestAborted));
        await Outbox.EmitAsync(u.Connection, tx, "signatory.authority.changed", "acc.Signatory", s.SignatoryId, new { signatory = s.PublicId }, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("AUTHORITY_ENDED", "TREASURY", "acc.SignatoryAuthority", aid,
            AfterJson: JsonSerializer.Serialize(new { on = D(on) })), s.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    // ---------- SVC-03 and the reports ----------

    /// <summary>
    /// SVC-03 (FR-ACC-015, BR-ACC-012): the signatory's authority for an operation on an account on a date: the account's
    /// own row, else its master account's (a virtual account inherits, Q-ACC-04), else the bank row; NONE otherwise.
    /// </summary>
    private static async Task<IResult> EffectiveAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "signatory", "account", "operation", "date");
        if (!Guid.TryParse(http.Request.Query["signatory"], out var sid) || !Guid.TryParse(http.Request.Query["account"], out var accountId))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the signatory and the account.");
        var on = GovernanceEndpoints.Date(http.Request.Query["date"].ToString() is { Length: > 0 } d ? d : null, "date") ?? GovernanceEndpoints.Today(clock);
        await using var u = await OpenAsync(http, db, View);
        var s = await FindAsync(u, null, sid, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var account = await u.Connection.QuerySingleOrDefaultAsync<(long Id, long? Master)>(new CommandDefinition(
            "SELECT BankAccountId, MasterAccountId FROM acc.BankAccount WHERE PublicId = @a AND RelationshipId = @r;", new { a = accountId, r = s.RelationshipId },
            cancellationToken: http.RequestAborted));
        if (account.Id == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The account is not an account of the signatory's relationship.");
        var rows = (await u.Connection.QueryAsync<AuthorityRow>(new CommandDefinition(AuthoritySelect +
            " WHERE a.SignatoryId = @s AND o.Code = @o AND a.ValidFrom <= @d AND (a.ValidTo IS NULL OR a.ValidTo >= @d);",
            new { s = s.SignatoryId, o = http.Request.Query["operation"].ToString().ToUpperInvariant(), d = on }, cancellationToken: http.RequestAborted))).ToList();
        var active = s.Status == "ACTIVE" && s.ValidFrom <= on && (s.ValidTo is null || s.ValidTo >= on);
        (string Level, AuthorityRow? Row) found =
            !active ? ("NONE", null)
            : rows.FirstOrDefault(r => r.BankAccountId == account.Id) is { } own ? ("ACCOUNT", own)
            : account.Master is { } m && rows.FirstOrDefault(r => r.BankAccountId == m) is { } master ? ("MASTER", master)
            : rows.FirstOrDefault(r => r.BankAccountId is null) is { } bank ? ("BANK", bank)
            : ("NONE", null);
        var a = found.Row;
        return Results.Ok(new
        {
            level = found.Level, signatoryStatus = s.Status, date = D(on),
            authority = a is null ? null : new
            {
                ceilingMode = a.CeilingMode, maxPerTransaction = a.MaxPerTransaction, dailyLimit = a.DailyLimit, currency = a.Currency, isJoint = a.IsJoint,
                jointMinCosigners = a.JointMinCosigners, jointClasses = a.JointClasses?.Split(',') ?? [], validTo = a.ValidTo is { } t ? D(t) : null,
            },
        });
    }

    /// <summary>R-ACC-05 (first part): active accounts whose relationship has no active signatory today.</summary>
    private static async Task<IResult> WithoutSignatoryAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var rows = await u.Connection.QueryAsync<(Guid Account, string Mask, string Company, string Institution)>(new CommandDefinition(
            """
            SELECT ba.PublicId, ba.AccountNoMask, co.CompanyCode, i.Code
              FROM acc.BankAccount AS ba JOIN org.Company AS co ON co.CompanyId = ba.CompanyId JOIN ins.Institution AS i ON i.InstitutionId = ba.InstitutionId
             WHERE ba.Status = 'ACTIVE' AND (@all = 1 OR ba.CompanyId IN @ids)
               AND NOT EXISTS (SELECT 1 FROM acc.Signatory AS s WHERE s.RelationshipId = ba.RelationshipId AND s.Status = 'ACTIVE')
             ORDER BY co.CompanyCode, i.Code;
            """, new { all = scope.All, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(r => new { account = r.Account, mask = r.Mask, company = r.Company, institution = r.Institution }) });
    }

    /// <summary>R-ACC-06: the expiries of the next 90 days, the earliest of the mandate, its authorities and its document (BR-ACC-017).</summary>
    private static async Task<IResult> ExpiriesAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var today = GovernanceEndpoints.Today(clock);
        var rows = await u.Connection.QueryAsync<(Guid Signatory, string NameAr, string? NameEn, string Company, string Institution, DateTime Expiry)>(new CommandDefinition(
            "SELECT x.Signatory, x.NameAr, x.NameEn, x.Company, x.Institution, x.ExpiryDate FROM (" + Data.Jobs.SignatoryExpiry.Earliest + ") AS x WHERE x.ExpiryDate <= @h AND (@all = 1 OR x.CompanyId IN @ids) ORDER BY x.ExpiryDate;",
            new { h = today.AddDays(90), all = scope.All, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = rows.Select(r => new { signatory = r.Signatory, nameAr = r.NameAr, nameEn = r.NameEn, company = r.Company, institution = r.Institution, expiryDate = D(r.Expiry) }),
        });
    }
}

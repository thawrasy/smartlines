using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using BankFas.Api.Infrastructure;
using BankFas.Core.Files;
using BankFas.Core.Security;
using BankFas.Core.Text;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record PartyRequest(string? Kind, string? NameAr, string? NameEn, string? Country, string? ResidencyStatus, string? BirthDate, string? BirthDateHijri,
    string? BirthPlace, string? BirthCountry, string? MaritalStatus, string? Gender, bool? ConfirmDuplicate);
public sealed record IdentityDocumentRequest(string? DocKind, string? IssuingCountry, string? Number, string? IssueDate, string? IssueDateHijri, string? ExpiryDate,
    string? ExpiryDateHijri, string? IssuingAuthority, string? IssuePlace, bool? IsPrimary, string? PrimaryReason);
public sealed record RevealRequest(string? Reason);
public sealed record CustomFieldDefinitionRequest(string? FieldKey, string? LabelAr, string? LabelEn, string? DataType, List<string>? ListValues, string? Sensitivity,
    string? AppliesToKind, bool? IsActive);
public sealed record CustomFieldValueRequest(JsonElement Value, string? Currency);
public sealed record MergeRequest(Guid? Into, string? Reason);

/// <summary>
/// Persons and legal entities (FR-PTY-001 to 022, 028; screens 21 to 23 of spec 10). A party has no stored role: its
/// roles come from what uses it (FR-PTY-017). Identity numbers are encrypted with the tenant's DATA key, bound to their
/// row by the associated data, masked to the last four, and found by a blind index (BR-PTY-002); a reveal needs its
/// permission, is logged with the sensitive-access log and is masked again after the tenant's setting. A renewal makes
/// a new document that supersedes the old one (FR-PTY-022). The mirror party of a company is read-only and never
/// merged (BR-PTY-016, BR-PTY-018). A merge moves every reference to the surviving party in one transaction.
/// </summary>
public static partial class PartyEndpoints
{
    private const string View = "party.view";
    private const string Manage = "party.manage";
    private const string IdentityWrite = "party.identity.write";
    private const string Reveal = "party.identity.reveal";
    private const string ImageView = "party.identity.image.view";
    private const string FieldManage = "party.field.manage";
    private const string Merge = "party.merge";
    private static readonly string[] DocKinds = ["NATIONAL_ID", "RESIDENCE", "PASSPORT", "GCC_ID", "COMMERCIAL_REG", "OTHER_ORG"];
    private static readonly string[] OwnTables = ["pty.IdentityDocument", "pty.Address", "pty.ContactMethod", "pty.PartyCustomField", "pty.PartyCompliance", "pty.TaxIdentity", "pty.Party"];

    /// <summary>The role a party has through a table that references it (FR-PTY-017).</summary>
    private static readonly Dictionary<string, string> Roles = new(StringComparer.Ordinal)
    {
        ["org.Company"] = "COMPANY", ["org.Shareholding"] = "SHAREHOLDER", ["org.BodyMember"] = "BODY_MEMBER", ["org.AuthorityGrant"] = "AUTHORITY_HOLDER",
        ["ins.Institution"] = "INSTITUTION", ["ins.Contact"] = "CONTACT", ["acc.Signatory"] = "SIGNATORY", ["col.Collateral"] = "COLLATERAL_OWNER",
        ["col.Guarantee"] = "GUARANTOR", ["col.PromissoryNoteSigner"] = "NOTE_SIGNER", ["fin.CreditAssessmentGuarantor"] = "GUARANTOR", ["lc.Counterparty"] = "COUNTERPARTY",
    };

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/parties", SearchAsync);
        api.MapPost("/parties", CreateAsync);
        api.MapGet("/parties/duplicates", DuplicatesAsync);
        api.MapGet("/parties/{id:guid}", GetAsync);
        api.MapPatch("/parties/{id:guid}", PatchAsync);
        api.MapPost("/parties/{id:guid}/actions/deactivate", DeactivateAsync);
        api.MapPost("/parties/{id:guid}/actions/merge", MergeAsync);
        api.MapPost("/parties/{id:guid}/identity-documents", AddIdentityAsync);
        api.MapPatch("/parties/{id:guid}/identity-documents/{doc:guid}", PatchIdentityAsync);
        api.MapPost("/parties/{id:guid}/identity-documents/{doc:guid}/actions/reveal", RevealAsync);
        api.MapPost("/parties/{id:guid}/identity-documents/{doc:guid}/actions/renew", RenewAsync);
        api.MapPost("/parties/{id:guid}/identity-documents/{doc:guid}/actions/verify", VerifyAsync);
        api.MapPost("/parties/{id:guid}/identity-documents/{doc:guid}/images", AddImageAsync);
        api.MapPost("/parties/{id:guid}/addresses", AddAddressAsync);
        api.MapPost("/parties/{id:guid}/addresses/{reference}/actions/retire", RetireAddressAsync);
        api.MapPost("/parties/{id:guid}/contact-methods", AddContactMethodAsync);
        api.MapDelete("/parties/{id:guid}/contact-methods/{reference}", DeleteContactMethodAsync);
        api.MapPut("/parties/{id:guid}/custom-fields/{key}", SetCustomFieldAsync);
        api.MapPost("/parties/{id:guid}/custom-fields/{key}/actions/reveal", RevealCustomFieldAsync);
        api.MapGet("/custom-field-definitions", DefinitionsAsync);
        api.MapPost("/custom-field-definitions", CreateDefinitionAsync);
        api.MapPatch("/custom-field-definitions/{key}", PatchDefinitionAsync);
    }

    internal sealed record PartyRow(long PartyId, Guid PublicId, string PartyCode, string Kind, string? NameAr, string? NameEn, string? Country,
        string? ResidencyStatus, DateTime? BirthDate, string? BirthDateHijriText, string? BirthPlace, string? BirthCountry, string? MaritalStatus, string? Gender,
        bool IsActive, Guid? MergedInto, long? MirrorCompanyId, Guid? MirrorCompany, long? CreatedBy, byte[] RowVersion);

    private const string Select =
        """
        SELECT p.PartyId, p.PublicId, p.PartyCode, p.Kind, p.NameAr, p.NameEn, co.Iso2 AS Country, p.ResidencyStatus, p.BirthDate, p.BirthDateHijriText,
               p.BirthPlace, bc.Iso2 AS BirthCountry, p.MaritalStatus, p.Gender, p.IsActive, m.PublicId AS MergedInto, c.CompanyId AS MirrorCompanyId,
               c.PublicId AS MirrorCompany, p.CreatedBy, p.RowVersion
          FROM pty.Party AS p
          LEFT JOIN ref.Country AS co ON co.CountryId = p.CountryId
          LEFT JOIN ref.Country AS bc ON bc.CountryId = p.BirthCountryId
          LEFT JOIN pty.Party AS m ON m.PartyId = p.MergedIntoPartyId
          LEFT JOIN org.Company AS c ON c.PartyId = p.PartyId
        """;

    private static string? D(DateTime? d) => d?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static object Shape(PartyRow p) => new
    {
        id = p.PublicId, partyCode = p.PartyCode, kind = p.Kind, nameAr = p.NameAr, nameEn = p.NameEn, country = p.Country, residencyStatus = p.ResidencyStatus,
        birthDate = D(p.BirthDate), birthDateHijri = p.BirthDateHijriText, birthPlace = p.BirthPlace, birthCountry = p.BirthCountry, maritalStatus = p.MaritalStatus,
        gender = p.Gender, isActive = p.IsActive, mergedInto = p.MergedInto, mirrorOfCompany = p.MirrorCompany, etag = ETags.Of(p.RowVersion),
    };

    /// <summary>
    /// FR-PTY-019 in S1: a mirror party is seen within the company scope; any other party by the holders of party.view
    /// (its other usage providers, facilities and the like, join the rule in their slices).
    /// </summary>
    private static async Task<PartyRow> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct)
    {
        var p = await u.Connection.QuerySingleOrDefaultAsync<PartyRow>(new CommandDefinition(Select + " WHERE p.PublicId = @id;", new { id }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        if (p.MirrorCompanyId is not null && !(await CompanyScope.OfAsync(u, ct, tx)).Allows(p.MirrorCompanyId)) throw ApiProblemException.NotFound();
        return p;
    }

    private static DateTime? Date(string? text, string field) =>
        string.IsNullOrWhiteSpace(text) ? null
        : DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
        : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is a date YYYY-MM-DD.");

    private static async Task<int?> CountryAsync(SqlConnection c, SqlTransaction? tx, string? iso2, CancellationToken ct) =>
        string.IsNullOrWhiteSpace(iso2) ? null
        : await c.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CountryId FROM ref.Country WHERE Iso2 = @c AND IsActive = 1;", new { c = iso2.Trim().ToUpperInvariant() },
            tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("COUNTRY_UNKNOWN", "Choose a country from the list.");

    // ---------- search, read ----------

    /// <summary>By normalised name, or by an exact identity number through the blind index (FR-PTY-002): nothing is decrypted.</summary>
    private static async Task<IResult> SearchAsync(HttpContext http, SqlConnectionFactory db, TenantKeyRing keys)
    {
        Query.Allow(http.Request, "q", "kind", "number", "docKind", "country", "includeInactive");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var q = http.Request.Query;
        byte[][] hashes = [];
        if (q["number"].ToString() is { Length: > 0 } number)
        {
            var normalized = IdentityNumbers.Normalize(number);
            var country = q["country"].ToString() is { Length: > 0 } cty ? cty.ToUpperInvariant()
                : await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition(
                    "SELECT c.Iso2 FROM plat.v_CurrentTenant AS t JOIN ref.Country AS c ON c.CountryId = t.HomeCountryId;", cancellationToken: http.RequestAborted)) ?? "SA";
            var kinds = q["docKind"].ToString() is { Length: > 0 } dk ? [dk.ToUpperInvariant()] : DocKinds;
            var (_, key) = await keys.ActiveAsync(u.Connection, null, u.TenantId, "BLIND_INDEX", http.RequestAborted);
            hashes = [.. kinds.Select(k => IdentityNumbers.BlindIndex(key, k, country, normalized))];
        }
        var name = Normalizer.Name(q["q"]);
        var rows = await u.Connection.QueryAsync<PartyRow>(new CommandDefinition(
            Select + """
             WHERE (@inactive = 1 OR p.IsActive = 1)
               AND (@kind IS NULL OR p.Kind = @kind)
               AND (@name = '' OR p.NameNormalized LIKE @nameLike OR p.PartyCode = @code)
               AND (@byNumber = 0 OR EXISTS (SELECT 1 FROM pty.IdentityDocument AS d WHERE d.PartyId = p.PartyId AND d.IsSuperseded = 0 AND d.NumberHash IN @hashes))
               AND (c.CompanyId IS NULL OR @all = 1 OR c.CompanyId IN @ids)
             ORDER BY p.NameNormalized
             OFFSET 0 ROWS FETCH NEXT 100 ROWS ONLY;
            """,
            new
            {
                inactive = string.Equals(q["includeInactive"], "true", StringComparison.OrdinalIgnoreCase), kind = q["kind"].ToString() is { Length: > 0 } k2 ? k2.ToUpperInvariant() : null,
                name, nameLike = "%" + name + "%", code = q["q"].ToString().Trim().ToUpperInvariant(), byNumber = hashes.Length > 0,
                hashes = hashes.Length > 0 ? hashes : [new byte[32]], all = scope.All, ids = scope.SqlIds,
            }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(Shape) });
    }

    private sealed record IdRow(long IdentityDocumentId, Guid PublicId, string DocKind, string IssuingCountry, string NumberMask, string? IssuingAuthority,
        string? IssuePlace, DateTime? IssueDate, string? IssueDateHijriText, DateTime? ExpiryDate, string? ExpiryDateHijriText, bool IsPrimary, bool IsSuperseded,
        Guid? SupersededBy, DateTime? VerifiedAt, byte[] RowVersion);

    private const string IdSelect =
        """
        SELECT d.IdentityDocumentId, d.PublicId, d.DocKind, c.Iso2 AS IssuingCountry, d.NumberMask, d.IssuingAuthority, d.IssuePlace, d.IssueDate, d.IssueDateHijriText,
               d.ExpiryDate, d.ExpiryDateHijriText, d.IsPrimary, d.IsSuperseded, s.PublicId AS SupersededBy, d.VerifiedAt, d.RowVersion
          FROM pty.IdentityDocument AS d JOIN ref.Country AS c ON c.CountryId = d.IssuingCountryId
          LEFT JOIN pty.IdentityDocument AS s ON s.IdentityDocumentId = d.SupersededById
        """;

    /// <summary>The usage providers of a party, from the foreign keys that reference it (FR-PTY-017).</summary>
    private static async Task<List<(string Table, string Role, int Count)>> UsagesAsync(SqlConnection c, SqlTransaction? tx, long partyId, CancellationToken ct)
    {
        var refs = await c.QueryAsync<(string Schema, string Table, string Column)>(new CommandDefinition(
            """
            SELECT OBJECT_SCHEMA_NAME(fkc.parent_object_id), OBJECT_NAME(fkc.parent_object_id), pc.name
              FROM sys.foreign_key_columns AS fkc
              JOIN sys.columns AS rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
              JOIN sys.columns AS pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
             WHERE fkc.referenced_object_id = OBJECT_ID(N'pty.Party') AND rc.name = N'PartyId';
            """, transaction: tx, cancellationToken: ct));
        var usages = new List<(string, string, int)>();
        foreach (var (schema, table, column) in refs.Distinct())
        {
            var full = schema + "." + table;
            if (OwnTables.Contains(full)) continue;
            var n = await c.ExecuteScalarAsync<int>(new CommandDefinition($"SELECT COUNT(*) FROM [{schema}].[{table}] WHERE [{column}] = @p;", new { p = partyId }, tx,
                cancellationToken: ct));
            if (n > 0) usages.Add((full, Roles.GetValueOrDefault(full, full), n));
        }
        return usages;
    }

    /// <summary>Party 360 (FR-PTY-028): the party, its documents masked, addresses, contacts, custom fields and roles.</summary>
    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var p = await FindAsync(u, null, id, http.RequestAborted);
        var perms = await u.PermissionsAsync(http.RequestAborted);
        var docs = (await u.Connection.QueryAsync<IdRow>(new CommandDefinition(IdSelect + " WHERE d.PartyId = @p ORDER BY d.IsSuperseded, d.IsPrimary DESC, d.IdentityDocumentId DESC;",
            new { p = p.PartyId }, cancellationToken: http.RequestAborted))).ToList();
        var images = await u.Connection.QueryAsync<(long Owner, Guid Document, string Role)>(new CommandDefinition(
            """
            SELECT l.EntityId, d.PublicId, l.LinkRole FROM doc.DocumentLink AS l JOIN doc.Document AS d ON d.DocumentId = l.DocumentId
             WHERE l.EntityType = 'pty.IdentityDocument' AND l.UnlinkedAt IS NULL AND d.Status = 'ACTIVE' AND l.EntityId IN @ids;
            """, new { ids = docs.Select(d => d.IdentityDocumentId).DefaultIfEmpty(-1).ToArray() }, cancellationToken: http.RequestAborted));
        var imageMap = images.GroupBy(i => i.Owner).ToDictionary(g => g.Key, g => g.ToList());
        var fields = await u.Connection.QueryAsync<(string FieldKey, string LabelAr, string LabelEn, string DataType, string Sensitivity, string? ValueText, string? ValueMask, string? Currency)>(
            new CommandDefinition(
                """
                SELECT d.FieldKey, d.LabelAr, d.LabelEn, d.DataType, d.Sensitivity, v.ValueText, v.ValueMask, cu.Code
                  FROM pty.PartyCustomField AS v JOIN pty.CustomFieldDefinition AS d ON d.CustomFieldDefinitionId = v.DefinitionId
                  LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = v.CurrencyId
                 WHERE v.PartyId = @p ORDER BY d.FieldKey;
                """, new { p = p.PartyId }, cancellationToken: http.RequestAborted));
        var usages = await UsagesAsync(u.Connection, null, p.PartyId, http.RequestAborted);
        ETags.Set(http.Response, p.RowVersion);
        return Results.Ok(new
        {
            party = Shape(p),
            identityDocuments = docs.Select(d => new
            {
                id = d.PublicId, docKind = d.DocKind, issuingCountry = d.IssuingCountry, number = d.NumberMask, issuingAuthority = d.IssuingAuthority, issuePlace = d.IssuePlace,
                issueDate = D(d.IssueDate), issueDateHijri = d.IssueDateHijriText, expiryDate = D(d.ExpiryDate), expiryDateHijri = d.ExpiryDateHijriText,
                isPrimary = d.IsPrimary, isSuperseded = d.IsSuperseded, supersededBy = d.SupersededBy, verified = d.VerifiedAt is not null, etag = ETags.Of(d.RowVersion),
                // Images for those who may see them; the others see how many there are (FR-PLT-030: no thumbnail for the others).
                images = perms.Contains(ImageView)
                    ? imageMap.GetValueOrDefault(d.IdentityDocumentId)?.Select(i => (object)new { document = i.Document, side = i.Role })
                    : null,
                imageCount = imageMap.GetValueOrDefault(d.IdentityDocumentId)?.Count ?? 0,
            }),
            contacts = await PartyContacts.ListAsync(u.Connection, p.PartyId, refs, u.TenantId, http.RequestAborted),
            customFields = fields.Select(f => new
            {
                key = f.FieldKey, labelAr = f.LabelAr, labelEn = f.LabelEn, dataType = f.DataType, restricted = f.Sensitivity == "RESTRICTED",
                value = f.Sensitivity == "RESTRICTED" ? f.ValueMask : f.ValueText, currency = f.Currency,
            }),
            roles = usages.Select(x => new { role = x.Role, table = x.Table, count = x.Count }),
        });
    }

    // ---------- create, edit, deactivate ----------

    private sealed record PartyValues(string Kind, string? NameAr, string? NameEn, int? CountryId, string? Residency, DateTime? BirthDate, string? BirthHijri,
        string? BirthPlace, int? BirthCountryId, string? Marital, string? Gender);

    private static async Task<PartyValues> ValuesAsync(SqlConnection c, SqlTransaction? tx, PartyRequest b, PartyRow? current, CancellationToken ct)
    {
        var kind = (b.Kind ?? current?.Kind)?.ToUpperInvariant();
        if (kind is not ("INDIVIDUAL" or "ORGANIZATION")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The party is an individual or an organisation.");
        if (current is not null && b.Kind is not null && !string.Equals(b.Kind, current.Kind, StringComparison.OrdinalIgnoreCase)) throw ApiProblemException.Invalid("V-PTY-KIND-FIXED", "The kind of a party does not change.");
        var ar = b.NameAr is null ? current?.NameAr : b.NameAr.Trim() is { Length: > 0 } a ? a : null;
        var en = b.NameEn is null ? current?.NameEn : b.NameEn.Trim() is { Length: > 0 } e ? e : null;
        if (ar is null && en is null) throw ApiProblemException.Invalid("V-PTY-NAME", "Enter a name in Arabic or English.");
        if ((ar?.Length ?? 0) > 200 || (en?.Length ?? 0) > 200) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A name is up to 200 characters.");
        var individual = kind == "INDIVIDUAL";
        if (!individual && (b.ResidencyStatus ?? b.BirthDate ?? b.MaritalStatus ?? b.Gender) is not null)
            throw ApiProblemException.Invalid("V-PTY-INDIVIDUAL-FIELDS", "Residency, birth date, marital status and gender are for individuals.");
        return new PartyValues(kind, ar, en,
            b.Country is null ? await CountryAsync(c, tx, current?.Country, ct) : await CountryAsync(c, tx, b.Country, ct),
            individual ? (b.ResidencyStatus?.ToUpperInvariant() ?? current?.ResidencyStatus) : null,
            individual ? (b.BirthDate is null ? current?.BirthDate : Date(b.BirthDate, "birth date")) : null,
            individual ? (b.BirthDateHijri ?? current?.BirthDateHijriText) : null,
            individual ? (b.BirthPlace ?? current?.BirthPlace) : null,
            individual ? (b.BirthCountry is null ? await CountryAsync(c, tx, current?.BirthCountry, ct) : await CountryAsync(c, tx, b.BirthCountry, ct)) : null,
            individual ? (b.MaritalStatus?.ToUpperInvariant() ?? current?.MaritalStatus) : null,
            individual ? (b.Gender?.ToUpperInvariant() ?? current?.Gender) : null);
    }

    /// <summary>BR-PTY-004: same normalised name and same birth date (or two entities of the same name) is probably the same party.</summary>
    private static async Task<List<object>> SimilarAsync(SqlConnection c, SqlTransaction? tx, PartyValues v, long? except, CancellationToken ct)
    {
        // The stored form is the Arabic name then the English one: either name alone may match.
        var ar = Normalizer.Name(v.NameAr);
        var en = Normalizer.Name(v.NameEn);
        var rows = await c.QueryAsync<(Guid Id, string Code, string? NameAr, string? NameEn)>(new CommandDefinition(
            """
            SELECT TOP (10) p.PublicId, p.PartyCode, p.NameAr, p.NameEn FROM pty.Party AS p
             WHERE p.IsActive = 1 AND p.Kind = @kind AND p.PartyId <> ISNULL(@except, -1)
               AND ((@ar <> '' AND (p.NameNormalized = @ar OR p.NameNormalized LIKE @ar + ' %'))
                    OR (@en <> '' AND (p.NameNormalized = @en OR p.NameNormalized LIKE '% ' + @en)))
               AND (@kind = 'ORGANIZATION' OR p.BirthDate = @birth OR (p.BirthDate IS NULL AND @birth IS NULL));
            """, new { kind = v.Kind, except, ar, en, birth = v.BirthDate }, tx, cancellationToken: ct));
        return [.. rows.Select(r => (object)new { id = r.Id, partyCode = r.Code, nameAr = r.NameAr, nameEn = r.NameEn })];
    }

    private static async Task<IResult> CreateAsync(PartyRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var v = await ValuesAsync(u.Connection, tx, b, null, http.RequestAborted);
        var similar = await SimilarAsync(u.Connection, tx, v, null, http.RequestAborted);
        if (similar.Count > 0 && b.ConfirmDuplicate != true)
            return Results.Json(new { status = 409, code = "V-PTY-POSSIBLE-DUPLICATE", title = "A party with this name (and birth date) exists. Confirm to create another.", similar },
                statusCode: 409, contentType: "application/problem+json");
        var (code, issueId) = await CompanyEndpoints.AllocatePartyCodeAsync(u.Connection, tx, http.RequestAborted);
        var party = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT pty.Party (TenantId, PartyCode, Kind, NameAr, NameEn, NameNormalized, CountryId, ResidencyStatus, BirthDate, BirthDateHijriText, BirthPlace,
                              BirthCountryId, MaritalStatus, Gender, CreatedBy)
            OUTPUT inserted.PartyId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @kind, @ar, @en, @norm, @country, @res, @birth, @birthH, @birthPlace, @birthCountry, @marital,
                    @gender, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """,
            new
            {
                code, kind = v.Kind, ar = v.NameAr, en = v.NameEn, norm = CompanyEndpoints.Norm(v.NameAr, v.NameEn), country = v.CountryId, res = v.Residency,
                birth = v.BirthDate, birthH = v.BirthHijri, birthPlace = v.BirthPlace, birthCountry = v.BirthCountryId, marital = v.Marital, gender = v.Gender,
            }, tx, cancellationToken: http.RequestAborted));
        await CompanyEndpoints.RecordPartyAsync(u.Connection, tx, issueId, party.Id, http.RequestAborted);
        await Outbox.EmitAsync(u.Connection, tx, "party.created", "pty.Party", party.Id, new { party = party.PublicId, kind = v.Kind }, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("PARTY_CREATED", "TREASURY", "pty.Party", party.Id,
            AfterJson: JsonSerializer.Serialize(new { code, v.Kind, v.NameAr, v.NameEn, duplicateConfirmed = similar.Count > 0 })), null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/parties/{party.PublicId}", new { id = party.PublicId, partyCode = code });
    }

    private static async Task<IResult> PatchAsync(Guid id, PartyRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var p = await FindAsync(u, tx, id, http.RequestAborted);
        if (p.MirrorCompanyId is not null) throw new ApiProblemException(409, "V-PTY-MIRROR", "This party mirrors a company: edit the company.");
        if (!p.IsActive) throw new ApiProblemException(409, "V-PTY-INACTIVE", "An inactive party is read-only.");
        var v = await ValuesAsync(u.Connection, tx, b, p, http.RequestAborted);
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE pty.Party SET NameAr = @ar, NameEn = @en, NameNormalized = @norm, CountryId = @country, ResidencyStatus = @res, BirthDate = @birth,
                   BirthDateHijriText = @birthH, BirthPlace = @birthPlace, BirthCountryId = @birthCountry, MaritalStatus = @marital, Gender = @gender,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.RowVersion INTO @o WHERE PartyId = @id AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """,
            new
            {
                ar = v.NameAr, en = v.NameEn, norm = CompanyEndpoints.Norm(v.NameAr, v.NameEn), country = v.CountryId, res = v.Residency, birth = v.BirthDate,
                birthH = v.BirthHijri, birthPlace = v.BirthPlace, birthCountry = v.BirthCountryId, marital = v.Marital, gender = v.Gender, id = p.PartyId, rv = expected,
            }, tx, cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("PARTY_UPDATED", "TREASURY", "pty.Party", p.PartyId,
            BeforeJson: JsonSerializer.Serialize(new { p.NameAr, p.NameEn, p.Country, p.ResidencyStatus }), AfterJson: JsonSerializer.Serialize(new { v.NameAr, v.NameEn, b.Country, v.Residency })),
            null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    /// <summary>FR-PTY-018: a party in active use stays active; the refusal names the uses.</summary>
    private static async Task<IResult> DeactivateAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var p = await FindAsync(u, tx, id, http.RequestAborted);
        var usages = await UsagesAsync(u.Connection, tx, p.PartyId, http.RequestAborted);
        if (usages.Count > 0)
            throw new ApiProblemException(409, "V-PTY-IN-USE", "The party is in use: " + string.Join(", ", usages.Select(x => $"{x.Role} {x.Count}")) + ".");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE pty.Party SET IsActive = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE PartyId = @p;",
            new { p = p.PartyId }, tx, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("PARTY_DEACTIVATED", "TREASURY", "pty.Party", p.PartyId), null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    // ---------- duplicates and merge (FR-PTY-015, FR-PTY-016) ----------

    private static async Task<IResult> DuplicatesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Merge);
        var pairs = await u.Connection.QueryAsync<(Guid A, string ACode, string? AName, Guid B, string BCode, string? BName)>(new CommandDefinition(
            """
            SELECT TOP (100) a.PublicId, a.PartyCode, ISNULL(a.NameAr, a.NameEn), b.PublicId, b.PartyCode, ISNULL(b.NameAr, b.NameEn)
              FROM pty.Party AS a JOIN pty.Party AS b ON b.NameNormalized = a.NameNormalized AND b.Kind = a.Kind AND b.PartyId > a.PartyId
               AND (a.Kind = 'ORGANIZATION' OR b.BirthDate = a.BirthDate)
             WHERE a.IsActive = 1 AND b.IsActive = 1 AND a.NameNormalized IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM org.Company WHERE PartyId IN (a.PartyId, b.PartyId))
             ORDER BY a.NameNormalized;
            """, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = pairs.Select(p => new { a = new { id = p.A, partyCode = p.ACode, name = p.AName }, b = new { id = p.B, partyCode = p.BCode, name = p.BName } }),
        });
    }

    /// <summary>
    /// Moves every reference of the merged party to the surviving one, through the foreign keys on pty.Party, in one
    /// transaction; the merged party becomes inactive and points at the survivor, and never comes back (BR-PTY-016).
    /// Its primary flags yield to the survivor's; a contact method the survivor already has and a custom field it
    /// already holds stay on the merged party.
    /// </summary>
    private static async Task<IResult> MergeAsync(Guid id, MergeRequest b, HttpContext http, SqlConnectionFactory db)
    {
        if (b.Into is null || b.Into == id) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the party to keep.");
        if (string.IsNullOrWhiteSpace(b.Reason)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason.");
        await using var u = await BoundUser.OpenAsync(http, db, Merge);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, http.RequestAborted);
        var src = await FindAsync(u, tx, id, http.RequestAborted);
        var dst = await FindAsync(u, tx, b.Into.Value, http.RequestAborted);
        if (src.MirrorCompanyId is not null || dst.MirrorCompanyId is not null) throw new ApiProblemException(409, "V-PTY-MIRROR", "The mirror party of a company is never merged.");
        if (!src.IsActive || !dst.IsActive) throw new ApiProblemException(409, "V-PTY-INACTIVE", "Both parties must be active.");
        if (src.Kind != dst.Kind) throw ApiProblemException.Invalid("V-PTY-KIND", "Only parties of the same kind merge.");
        var p = new { s = src.PartyId, d = dst.PartyId };
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE pty.IdentityDocument SET IsPrimary = 0 WHERE PartyId = @s AND IsPrimary = 1 AND EXISTS (SELECT 1 FROM pty.IdentityDocument WHERE PartyId = @d AND IsPrimary = 1);
            UPDATE pty.Address SET IsPrimary = 0 WHERE PartyId = @s AND IsPrimary = 1 AND EXISTS (SELECT 1 FROM pty.Address WHERE PartyId = @d AND IsPrimary = 1 AND IsCurrent = 1);
            UPDATE m SET IsPrimary = 0 FROM pty.ContactMethod AS m
             WHERE m.PartyId = @s AND m.IsPrimary = 1 AND EXISTS (SELECT 1 FROM pty.ContactMethod WHERE PartyId = @d AND Kind = m.Kind AND IsPrimary = 1);
            """, p, tx, cancellationToken: http.RequestAborted));
        var refs = await u.Connection.QueryAsync<(string Schema, string Table, string Column)>(new CommandDefinition(
            """
            SELECT OBJECT_SCHEMA_NAME(fkc.parent_object_id), OBJECT_NAME(fkc.parent_object_id), pc.name
              FROM sys.foreign_key_columns AS fkc
              JOIN sys.columns AS rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
              JOIN sys.columns AS pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
             WHERE fkc.referenced_object_id = OBJECT_ID(N'pty.Party') AND rc.name = N'PartyId' AND pc.name <> N'MergedIntoPartyId';
            """, transaction: tx, cancellationToken: http.RequestAborted));
        var moved = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var (schema, table, column) in refs.Distinct())
        {
            var keep = (schema, table) switch
            {
                ("pty", "ContactMethod") => " AND NOT EXISTS (SELECT 1 FROM pty.ContactMethod AS x WHERE x.PartyId = @d AND x.Kind = t.Kind AND x.NormalizedValue = t.NormalizedValue)",
                ("pty", "PartyCustomField") => " AND NOT EXISTS (SELECT 1 FROM pty.PartyCustomField AS x WHERE x.PartyId = @d AND x.DefinitionId = t.DefinitionId)",
                _ => "",
            };
            var n = await u.Connection.ExecuteAsync(new CommandDefinition(
                $"UPDATE t SET [{column}] = @d FROM [{schema}].[{table}] AS t WHERE t.[{column}] = @s{keep};", p, tx, cancellationToken: http.RequestAborted));
            if (n > 0) moved[$"{schema}.{table}.{column}"] = n;
        }
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE pty.Party SET IsActive = 0, MergedIntoPartyId = @d, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE PartyId = @s;",
            p, tx, cancellationToken: http.RequestAborted));
        await Outbox.EmitAsync(u.Connection, tx, "party.merged", "pty.Party", dst.PartyId, new { merged = src.PublicId, into = dst.PublicId }, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("PARTY_MERGED", "TREASURY", "pty.Party", src.PartyId,
            AfterJson: JsonSerializer.Serialize(new { merged = src.PartyCode, into = dst.PartyCode, reason = b.Reason.Trim(), moved }), Severity: "HIGH"), null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Ok(new { into = dst.PublicId, moved });
    }

    // ---------- identity documents ----------

    /// <summary>The kind a party's primary document is expected to be (FR-PTY-005, BR-PTY-005).</summary>
    /// <remarks>A citizen of the tenant's home country: the national ID. Of another Gulf state: the GCC ID or the national ID of that state. A resident: the residence permit. Anyone else: the passport.</remarks>
    private static async Task<string[]> ExpectedPrimaryAsync(SqlConnection c, SqlTransaction tx, PartyRow p, CancellationToken ct)
    {
        if (p.Kind == "ORGANIZATION") return ["COMMERCIAL_REG"];
        var home = await c.ExecuteScalarAsync<string>(new CommandDefinition(
            "SELECT co.Iso2 FROM plat.v_CurrentTenant AS t JOIN ref.Country AS co ON co.CountryId = t.HomeCountryId;", transaction: tx, cancellationToken: ct));
        if (p.Country == home) return ["NATIONAL_ID"];
        var gcc = p.Country is not null && await c.ExecuteScalarAsync<bool>(new CommandDefinition("SELECT IsGcc FROM ref.Country WHERE Iso2 = @c;", new { c = p.Country }, tx, cancellationToken: ct));
        return gcc ? ["GCC_ID", "NATIONAL_ID"] : p.ResidencyStatus == "RESIDENT" ? ["RESIDENCE"] : ["PASSPORT"];
    }

    /// <summary>FR-PTY-010: the number formats of the lookup list ID_NUMBER_FORMAT, WARN (a warning) or BLOCK (a refusal).</summary>
    private static async Task<List<string>> CheckFormatAsync(SqlConnection c, SqlTransaction tx, string kind, string country, string normalized, CancellationToken ct)
    {
        var formats = await c.QueryAsync<string>(new CommandDefinition(
            """
            SELECT i.Attributes FROM cat.LookupItem AS i JOIN cat.LookupList AS l ON l.LookupListId = i.LookupListId
             WHERE l.Code = 'ID_NUMBER_FORMAT' AND i.IsActive = 1 AND i.Attributes IS NOT NULL
               AND JSON_VALUE(i.Attributes, '$.docKind') = @kind AND JSON_VALUE(i.Attributes, '$.countryIso2') = @country;
            """, new { kind, country }, tx, cancellationToken: ct));
        var warnings = new List<string>();
        foreach (var json in formats)
        {
            using var f = JsonDocument.Parse(json);
            var pattern = f.RootElement.TryGetProperty("regex", out var r) ? r.GetString() : null;
            if (pattern is null || Regex.IsMatch(normalized, pattern, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100))) continue;
            if (f.RootElement.TryGetProperty("mode", out var mode) && mode.GetString() == "BLOCK")
                throw ApiProblemException.Invalid("V-PTY-NUMBER-FORMAT", "The number does not have the format of this document.");
            warnings.Add("NUMBER_FORMAT");
        }
        return warnings;
    }


    private static async Task<IResult> AddIdentityAsync(Guid id, IdentityDocumentRequest b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys)
    {
        await using var u = await BoundUser.OpenAsync(http, db, IdentityWrite);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var p = await FindAsync(u, tx, id, http.RequestAborted);
        if (!p.IsActive) throw new ApiProblemException(409, "V-PTY-INACTIVE", "An inactive party is read-only.");
        var (docId, publicId, warnings) = await InsertIdentityAsync(u, tx, keys, p, b, null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/parties/{p.PublicId}", new { id = publicId, warnings });
    }

    /// <summary>The checks, the envelope, the mask and the blind index of a new identity document, and its row.</summary>
    private static async Task<(long Id, Guid PublicId, List<string> Warnings)> InsertIdentityAsync(BoundUser u, SqlTransaction tx, TenantKeyRing keys, PartyRow p,
        IdentityDocumentRequest b, (long Id, bool WasPrimary)? replaces, CancellationToken ct)
    {
        var kind = b.DocKind?.ToUpperInvariant();
        if (kind is null || !DocKinds.Contains(kind)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the kind of document.");
        if ((p.Kind == "ORGANIZATION") != kind is "COMMERCIAL_REG" or "OTHER_ORG")
            throw ApiProblemException.Invalid("V-PTY-DOC-KIND", "This kind of document is not for this kind of party.");
        var country = b.IssuingCountry?.Trim().ToUpperInvariant() ?? throw ApiProblemException.Invalid("COUNTRY_UNKNOWN", "Choose a country from the list.");
        var countryId = await CountryAsync(u.Connection, tx, country, ct);
        var normalized = IdentityNumbers.Normalize(b.Number ?? "");
        if (normalized.Length is < 4 or > 40) throw ApiProblemException.Invalid("V-PTY-NUMBER", "Enter the document number.");
        var issue = Date(b.IssueDate, "issue date");
        var expiry = Date(b.ExpiryDate, "expiry date");
        if (issue is not null && expiry is not null && expiry <= issue) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The expiry date comes after the issue date.");
        var warnings = await CheckFormatAsync(u.Connection, tx, kind, country, normalized, ct);
        var (dataKeyId, dataKey) = await keys.ActiveAsync(u.Connection, tx, u.TenantId, "DATA", ct);
        var (hashKeyId, hashKey) = await keys.ActiveAsync(u.Connection, tx, u.TenantId, "BLIND_INDEX", ct);
        var hash = IdentityNumbers.BlindIndex(hashKey, kind, country, normalized);
        var holder = await u.Connection.QuerySingleOrDefaultAsync<(Guid Party, string Code)?>(new CommandDefinition(
            """
            SELECT p.PublicId, p.PartyCode FROM pty.IdentityDocument AS d JOIN pty.Party AS p ON p.PartyId = d.PartyId
             WHERE d.DocKind = @kind AND d.IssuingCountryId = @country AND d.NumberHash = @hash AND d.IsSuperseded = 0 AND d.IdentityDocumentId <> ISNULL(@old, -1);
            """, new { kind, country = countryId, hash, old = replaces?.Id }, tx, cancellationToken: ct));
        if (holder is { } h)
            throw new ApiProblemException(409, "V-PTY-DUPLICATE-NUMBER", $"This number is already recorded for party {h.Code}.");

        // FR-PTY-005: the primary document is the one the party's nationality and residency call for; another needs a reason.
        var expected = await ExpectedPrimaryAsync(u.Connection, tx, p, ct);
        var hasPrimary = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM pty.IdentityDocument WHERE PartyId = @p AND IsPrimary = 1 AND IdentityDocumentId <> ISNULL(@old, -1);",
            new { p = p.PartyId, old = replaces?.Id }, tx, cancellationToken: ct)) > 0;
        var primary = replaces?.WasPrimary ?? (b.IsPrimary ?? (!hasPrimary && expected.Contains(kind)));
        if (primary && replaces is null && !expected.Contains(kind) && string.IsNullOrWhiteSpace(b.PrimaryReason))
            throw ApiProblemException.Invalid("V-PTY-PRIMARY-REASON", $"The primary document of this party is expected to be {string.Join(" or ", expected)}: give the reason for another.");
        if (primary && hasPrimary)
            await u.Connection.ExecuteAsync(new CommandDefinition("UPDATE pty.IdentityDocument SET IsPrimary = 0 WHERE PartyId = @p AND IsPrimary = 1;",
                new { p = p.PartyId }, tx, cancellationToken: ct));

        var publicId = Guid.NewGuid();
        var envelope = Envelope.Seal(dataKey, Encoding.UTF8.GetBytes(normalized), EnvelopeAad.ForColumn(u.TenantId, "pty.IdentityDocument", "NumberEnc", publicId));
        long docId;
        try
        {
            docId = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT pty.IdentityDocument (TenantId, PublicId, PartyId, DocKind, IssuingCountryId, IssuingAuthority, IssuePlace, NumberEnc, NumberMask, NumberHash,
                                             EncKeyId, HashKeyId, IssueDate, IssueDateHijriText, ExpiryDate, ExpiryDateHijriText, IsPrimary, CreatedBy)
                OUTPUT inserted.IdentityDocumentId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @pub, @p, @kind, @country, @auth, @place, @enc, @mask, @hash, @encKey, @hashKey, @issue, @issueH,
                        @expiry, @expiryH, @primary, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """,
                new
                {
                    pub = publicId, p = p.PartyId, kind, country = countryId, auth = b.IssuingAuthority, place = b.IssuePlace, enc = envelope,
                    mask = IdentityNumbers.Mask(normalized), hash, encKey = dataKeyId, hashKey = hashKeyId, issue, issueH = b.IssueDateHijri, expiry,
                    expiryH = b.ExpiryDateHijri, primary,
                }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "V-PTY-DUPLICATE-NUMBER", "This number is already recorded.");
        }
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(replaces is null ? "IDENTITY_DOCUMENT_ADDED" : "IDENTITY_DOCUMENT_RENEWED", "IDENTITY_ACCESS",
            "pty.IdentityDocument", docId,
            AfterJson: JsonSerializer.Serialize(new { party = p.PartyCode, kind, country, number = IdentityNumbers.Mask(normalized), primary, primaryReason = b.PrimaryReason, warnings })),
            p.MirrorCompanyId, ct);
        return (docId, publicId, warnings);
    }

    private static async Task<IdRow> DocAsync(BoundUser u, SqlTransaction? tx, PartyRow p, Guid doc, CancellationToken ct) =>
        await u.Connection.QuerySingleOrDefaultAsync<IdRow>(new CommandDefinition(IdSelect + " WHERE d.PublicId = @doc AND d.PartyId = @p;",
            new { doc, p = p.PartyId }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();

    /// <summary>Dates and issuer of a document; a change of a date clears the "original verified" flag (FR-PTY-020).</summary>
    private static async Task<IResult> PatchIdentityAsync(Guid id, Guid doc, IdentityDocumentRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        if (b.Number is not null || b.DocKind is not null || b.IssuingCountry is not null)
            throw ApiProblemException.Invalid("V-PTY-RENEW", "A new number is a renewal of the document.");
        await using var u = await BoundUser.OpenAsync(http, db, IdentityWrite);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var p = await FindAsync(u, tx, id, http.RequestAborted);
        var d = await DocAsync(u, tx, p, doc, http.RequestAborted);
        if (d.IsSuperseded) throw new ApiProblemException(409, "V-PTY-SUPERSEDED", "A superseded document is read-only.");
        var issue = b.IssueDate is null ? d.IssueDate : Date(b.IssueDate, "issue date");
        var expiry = b.ExpiryDate is null ? d.ExpiryDate : Date(b.ExpiryDate, "expiry date");
        if (issue is not null && expiry is not null && expiry <= issue) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The expiry date comes after the issue date.");
        var datesChanged = issue != d.IssueDate || expiry != d.ExpiryDate;
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE pty.IdentityDocument SET IssueDate = @issue, ExpiryDate = @expiry, IssueDateHijriText = ISNULL(@issueH, IssueDateHijriText),
                   ExpiryDateHijriText = ISNULL(@expiryH, ExpiryDateHijriText), IssuingAuthority = ISNULL(@auth, IssuingAuthority), IssuePlace = ISNULL(@place, IssuePlace),
                   VerifiedAt = CASE WHEN @clear = 1 THEN NULL ELSE VerifiedAt END, VerifiedBy = CASE WHEN @clear = 1 THEN NULL ELSE VerifiedBy END,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.RowVersion INTO @o WHERE IdentityDocumentId = @id AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """,
            new
            {
                issue, expiry, issueH = b.IssueDateHijri, expiryH = b.ExpiryDateHijri, auth = b.IssuingAuthority, place = b.IssuePlace, clear = datesChanged,
                id = d.IdentityDocumentId, rv = expected,
            }, tx, cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("IDENTITY_DOCUMENT_UPDATED", "IDENTITY_ACCESS", "pty.IdentityDocument", d.IdentityDocumentId,
            BeforeJson: JsonSerializer.Serialize(new { issue = D(d.IssueDate), expiry = D(d.ExpiryDate), verified = d.VerifiedAt is not null }),
            AfterJson: JsonSerializer.Serialize(new { issue = D(issue), expiry = D(expiry), verificationCleared = datesChanged && d.VerifiedAt is not null })), p.MirrorCompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    /// <summary>FR-PTY-007 and 008: the full number, for the holders of the permission, logged; masked again after the setting.</summary>
    private static async Task<IResult> RevealAsync(Guid id, Guid doc, RevealRequest b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var p = await FindAsync(u, null, id, http.RequestAborted);
        var d = await DocAsync(u, null, p, doc, http.RequestAborted);
        var ua = http.Request.Headers.UserAgent.ToString();
        if (!(await u.PermissionsAsync(http.RequestAborted)).Contains(Reveal))
        {
            await AuditWriter.SensitiveAccessAsync(u.Connection, null, "IDENTITY_REVEAL", "IDENTITY_REVEAL_DENIED", "pty.IdentityDocument", d.IdentityDocumentId, p.PartyId,
                p.MirrorCompanyId, false, "NO_PERMISSION", b.Reason, ua, http.RequestAborted);
            throw ApiProblemException.Forbidden();
        }
        var row = await u.Connection.QuerySingleAsync<(byte[] Enc, long KeyId)>(new CommandDefinition(
            "SELECT NumberEnc, EncKeyId FROM pty.IdentityDocument WHERE IdentityDocumentId = @id;", new { id = d.IdentityDocumentId }, cancellationToken: http.RequestAborted));
        var key = await keys.ByIdAsync(u.Connection, null, u.TenantId, row.KeyId, http.RequestAborted);
        var number = Encoding.UTF8.GetString(Envelope.Open(key, row.Enc, EnvelopeAad.ForColumn(u.TenantId, "pty.IdentityDocument", "NumberEnc", d.PublicId)));
        await AuditWriter.SensitiveAccessAsync(u.Connection, null, "IDENTITY_REVEAL", "IDENTITY_REVEALED", "pty.IdentityDocument", d.IdentityDocumentId, p.PartyId,
            p.MirrorCompanyId, true, null, b.Reason, ua, http.RequestAborted);
        var remask = await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition(
            "SELECT ISNULL(t.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key] WHERE d.[Key] = 'security.reveal.remask_seconds';",
            cancellationToken: http.RequestAborted));
        http.Response.Headers.CacheControl = "no-store";
        return Results.Ok(new { number, remaskSeconds = int.TryParse(remask, CultureInfo.InvariantCulture, out var s) ? s : 60 });
    }

    /// <summary>FR-PTY-022: a new document of the same kind and country replaces the old; the old stays, superseded and linked to the new.</summary>
    private static async Task<IResult> RenewAsync(Guid id, Guid doc, IdentityDocumentRequest b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys)
    {
        await using var u = await BoundUser.OpenAsync(http, db, IdentityWrite);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var p = await FindAsync(u, tx, id, http.RequestAborted);
        var d = await DocAsync(u, tx, p, doc, http.RequestAborted);
        if (d.IsSuperseded) throw new ApiProblemException(409, "V-PTY-SUPERSEDED", "This document was already renewed.");
        // Mark the old superseded first (the same number may come again), then the new, then the link (RF13).
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE pty.IdentityDocument SET IsSuperseded = 1, IsPrimary = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE IdentityDocumentId = @id;",
            new { id = d.IdentityDocumentId }, tx, cancellationToken: http.RequestAborted));
        var renewed = b with { DocKind = d.DocKind, IssuingCountry = d.IssuingCountry };
        var (newId, publicId, warnings) = await InsertIdentityAsync(u, tx, keys, p, renewed, (d.IdentityDocumentId, d.IsPrimary), http.RequestAborted);
        await u.Connection.ExecuteAsync(new CommandDefinition("UPDATE pty.IdentityDocument SET SupersededById = @n WHERE IdentityDocumentId = @id;",
            new { n = newId, id = d.IdentityDocumentId }, tx, cancellationToken: http.RequestAborted));
        await Outbox.EmitAsync(u.Connection, tx, "identity_document.renewed", "pty.IdentityDocument", newId, new { party = p.PublicId, document = publicId, replaces = d.PublicId },
            http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/parties/{p.PublicId}", new { id = publicId, replaces = d.PublicId, warnings });
    }

    private static async Task<IResult> VerifyAsync(Guid id, Guid doc, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, IdentityWrite);
        var p = await FindAsync(u, null, id, http.RequestAborted);
        var d = await DocAsync(u, null, p, doc, http.RequestAborted);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE pty.IdentityDocument SET VerifiedAt = SYSUTCDATETIME(), VerifiedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE IdentityDocumentId = @id;",
            new { id = d.IdentityDocumentId }, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("IDENTITY_DOCUMENT_VERIFIED", "IDENTITY_ACCESS", "pty.IdentityDocument", d.IdentityDocumentId), p.MirrorCompanyId,
            http.RequestAborted);
        return Results.NoContent();
    }

    private static readonly Dictionary<string, string> ImageTypes = new(StringComparer.Ordinal)
    {
        ["NATIONAL_ID"] = "NATIONAL_ID_IMAGE", ["RESIDENCE"] = "RESIDENCE_PERMIT_IMAGE", ["PASSPORT"] = "PASSPORT_IMAGE", ["GCC_ID"] = "GCC_ID_IMAGE",
    };

    /// <summary>FR-PTY-009: an image of a document is a restricted, encrypted document of the store, linked as its front, back or another side.</summary>
    private static async Task<IResult> AddImageAsync(Guid id, Guid doc, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, FileStore store, IMalwareScanner scanner)
    {
        if (!http.Request.HasFormContentType) throw ApiProblemException.Invalid("FILE_REQUIRED", "Send the file as multipart/form-data.");
        var form = await http.Request.ReadFormAsync(http.RequestAborted);
        var side = form["side"].ToString().ToUpperInvariant() switch { "FRONT" => "IMAGE_FRONT", "BACK" => "IMAGE_BACK", _ => "IMAGE_OTHER" };
        await using var u = await BoundUser.OpenAsync(http, db, IdentityWrite);
        await u.RequireAsync(ImageView, http.RequestAborted);
        var p = await FindAsync(u, null, id, http.RequestAborted);
        var d = await DocAsync(u, null, p, doc, http.RequestAborted);
        var type = await DocumentEndpoints.TypeAsync(u, null, ImageTypes.GetValueOrDefault(d.DocKind, "OTHER"), http.RequestAborted);
        var file = await DocumentEndpoints.ReadFileAsync(form.Files["file"], type, http.RequestAborted);
        var created = await DocumentEndpoints.CreateAsync(u, type, file, new DocumentEndpoints.DocMeta($"{d.DocKind} {d.NumberMask} {side}", null, null, null, d.ExpiryDate, null, null),
            null, ("pty.IdentityDocument", d.IdentityDocumentId, side), keys, store, scanner, http.RequestAborted);
        return Results.Created($"/api/v1/documents/{created.Id}", new { id = created.Id, scanStatus = created.ScanStatus });
    }

    // ---------- addresses and contacts (FR-PTY-011, FR-PTY-012) ----------

    private static async Task<IResult> ChangeContactsAsync(Guid id, HttpContext http, SqlConnectionFactory db, string action, Func<BoundUser, SqlTransaction, PartyRow, Task<object?>> change)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var p = await FindAsync(u, null, id, http.RequestAborted);
        if (p.MirrorCompanyId is not null) throw new ApiProblemException(409, "V-PTY-MIRROR", "This party mirrors a company: edit the company.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var detail = await change(u, tx, p);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(action, "TREASURY", "pty.Party", p.PartyId, AfterJson: JsonSerializer.Serialize(detail)), null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    private static Task<IResult> AddAddressAsync(Guid id, AddressRequest b, HttpContext http, SqlConnectionFactory db) =>
        ChangeContactsAsync(id, http, db, "ADDRESS_ADDED", async (u, tx, p) => { await PartyContacts.AddAddressAsync(u.Connection, tx, p.PartyId, b, http.RequestAborted); return new { b.AddressType, b.Country }; });

    private static Task<IResult> RetireAddressAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
        ChangeContactsAsync(id, http, db, "ADDRESS_RETIRED", async (u, tx, p) =>
        {
            await PartyContacts.RetireAddressAsync(u.Connection, tx, p.PartyId, refs.ItemId(u.TenantId, "address", reference) ?? throw ApiProblemException.NotFound(), http.RequestAborted);
            return null;
        });

    private static Task<IResult> AddContactMethodAsync(Guid id, ContactMethodRequest b, HttpContext http, SqlConnectionFactory db) =>
        ChangeContactsAsync(id, http, db, "CONTACT_METHOD_ADDED", async (u, tx, p) => { await PartyContacts.AddContactMethodAsync(u.Connection, tx, p.PartyId, p.Country, b, http.RequestAborted); return new { b.Kind }; });

    private static Task<IResult> DeleteContactMethodAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
        ChangeContactsAsync(id, http, db, "CONTACT_METHOD_REMOVED", async (u, tx, p) =>
        {
            await PartyContacts.DeleteContactMethodAsync(u.Connection, tx, p.PartyId, refs.ItemId(u.TenantId, "contact-method", reference) ?? throw ApiProblemException.NotFound(), http.RequestAborted);
            return null;
        });

    // ---------- custom fields (FR-PTY-013, FR-PTY-014) ----------

    private sealed record Definition(long CustomFieldDefinitionId, string FieldKey, string LabelAr, string LabelEn, string DataType, string? ListValues, string Sensitivity,
        string? AppliesToKind, bool IsActive, byte[] RowVersion);

    private static async Task<Definition> DefinitionAsync(SqlConnection c, SqlTransaction? tx, string key, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<Definition>(new CommandDefinition(
            "SELECT CustomFieldDefinitionId, FieldKey, LabelAr, LabelEn, DataType, ListValues, Sensitivity, AppliesToKind, IsActive, RowVersion FROM pty.CustomFieldDefinition WHERE FieldKey = @key;",
            new { key }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();

    private static async Task<IResult> DefinitionsAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var rows = await u.Connection.QueryAsync<Definition>(new CommandDefinition(
            "SELECT CustomFieldDefinitionId, FieldKey, LabelAr, LabelEn, DataType, ListValues, Sensitivity, AppliesToKind, IsActive, RowVersion FROM pty.CustomFieldDefinition ORDER BY FieldKey;",
            cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = rows.Select(d => new
            {
                key = d.FieldKey, labelAr = d.LabelAr, labelEn = d.LabelEn, dataType = d.DataType, listValues = d.ListValues is null ? null : JsonSerializer.Deserialize<string[]>(d.ListValues),
                sensitivity = d.Sensitivity, appliesToKind = d.AppliesToKind, isActive = d.IsActive, etag = ETags.Of(d.RowVersion),
            }),
        });
    }

    [GeneratedRegex("^[a-z][a-z0-9_]{1,59}$", RegexOptions.CultureInvariant)] private static partial Regex FieldKeyPattern();
    private static readonly string[] DataTypes = ["TEXT", "NUMBER", "DATE", "LIST", "BOOLEAN", "AMOUNT"];

    private static async Task<IResult> CreateDefinitionAsync(CustomFieldDefinitionRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var key = b.FieldKey?.Trim().ToLowerInvariant();
        if (key is null || !FieldKeyPattern().IsMatch(key)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The field key is 2 to 60 small letters, digits and _.");
        var type = b.DataType?.ToUpperInvariant();
        if (type is null || !DataTypes.Contains(type)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the type of the field.");
        if ((type == "LIST") != (b.ListValues is { Count: > 0 })) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A list field has its values; another field has none.");
        if (string.IsNullOrWhiteSpace(b.LabelAr) || string.IsNullOrWhiteSpace(b.LabelEn)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter both labels.");
        var sensitivity = b.Sensitivity?.ToUpperInvariant() ?? "CONFIDENTIAL";
        if (sensitivity is not ("CONFIDENTIAL" or "RESTRICTED")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The sensitivity is confidential or restricted.");
        await using var u = await BoundUser.OpenAsync(http, db, FieldManage);
        try
        {
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT pty.CustomFieldDefinition (TenantId, FieldKey, LabelAr, LabelEn, DataType, ListValues, Sensitivity, AppliesToKind, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @key, @ar, @en, @type, @list, @sens, @kind, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """,
                new
                {
                    key, ar = b.LabelAr.Trim(), en = b.LabelEn.Trim(), type, list = b.ListValues is null ? null : JsonSerializer.Serialize(b.ListValues), sens = sensitivity,
                    kind = b.AppliesToKind?.ToUpperInvariant(),
                }, cancellationToken: http.RequestAborted));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "CODE_TAKEN", "An item with this code already exists.");
        }
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("CUSTOM_FIELD_DEFINED", "CONFIG", "pty.CustomFieldDefinition", null,
            AfterJson: JsonSerializer.Serialize(new { key, type, sensitivity })), null, http.RequestAborted);
        return Results.Created("/api/v1/custom-field-definitions", new { key });
    }

    /// <summary>Labels, list values and activity; the key, the type and the sensitivity stay (values were written by them).</summary>
    private static async Task<IResult> PatchDefinitionAsync(string key, CustomFieldDefinitionRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        if (b.FieldKey is not null || b.DataType is not null || b.Sensitivity is not null)
            throw ApiProblemException.Invalid("V-PTY-FIELD-FIXED", "The key, type and sensitivity of a field do not change.");
        await using var u = await BoundUser.OpenAsync(http, db, FieldManage);
        var d = await DefinitionAsync(u.Connection, null, key, http.RequestAborted);
        if (b.ListValues is not null && d.DataType != "LIST") throw ApiProblemException.Invalid("VALIDATION_FAILED", "A list field has its values; another field has none.");
        _ = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE pty.CustomFieldDefinition SET LabelAr = ISNULL(@ar, LabelAr), LabelEn = ISNULL(@en, LabelEn), ListValues = ISNULL(@list, ListValues),
                   IsActive = ISNULL(@active, IsActive), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.RowVersion INTO @o WHERE CustomFieldDefinitionId = @id AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """,
            new { ar = b.LabelAr, en = b.LabelEn, list = b.ListValues is null ? null : JsonSerializer.Serialize(b.ListValues), active = b.IsActive, id = d.CustomFieldDefinitionId, rv = expected },
            cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        return Results.NoContent();
    }

    /// <summary>The value as text, checked against the field's type; null clears it.</summary>
    private static string? ValueText(Definition d, JsonElement v)
    {
        if (v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
        string? text = d.DataType switch
        {
            "NUMBER" or "AMOUNT" when v.ValueKind == JsonValueKind.Number => v.GetDecimal().ToString(CultureInfo.InvariantCulture),
            "BOOLEAN" when v.ValueKind is JsonValueKind.True or JsonValueKind.False => v.GetBoolean() ? "true" : "false",
            "DATE" when v.ValueKind == JsonValueKind.String && DateTime.TryParseExact(v.GetString(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _) => v.GetString(),
            "LIST" when v.ValueKind == JsonValueKind.String && (JsonSerializer.Deserialize<string[]>(d.ListValues ?? "[]") ?? []).Contains(v.GetString()) => v.GetString(),
            "TEXT" when v.ValueKind == JsonValueKind.String && v.GetString()!.Length <= 1000 => v.GetString(),
            _ => throw ApiProblemException.Invalid("V-PTY-FIELD-VALUE", "The value does not fit the type of the field."),
        };
        return text;
    }

    private static async Task<IResult> SetCustomFieldAsync(Guid id, string key, CustomFieldValueRequest b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var p = await FindAsync(u, null, id, http.RequestAborted);
        var d = await DefinitionAsync(u.Connection, null, key, http.RequestAborted);
        if (!d.IsActive) throw new ApiProblemException(409, "ITEM_INACTIVE", "An inactive item cannot be linked.");
        if (d.AppliesToKind is not null && d.AppliesToKind != p.Kind) throw ApiProblemException.Invalid("V-PTY-FIELD-KIND", "This field is not for this kind of party.");
        var restricted = d.Sensitivity == "RESTRICTED";
        if (restricted) await u.RequireAsync(IdentityWrite, http.RequestAborted);
        var text = ValueText(d, b.Value);
        int? currency = null;
        if (d.DataType == "AMOUNT" && text is not null)
            currency = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @c;", new { c = b.Currency?.ToUpperInvariant() },
                cancellationToken: http.RequestAborted)) ?? throw ApiProblemException.Invalid("V-ORG-CURRENCY", "The currency is not known.");
        byte[]? enc = null;
        long? keyId = null;
        string? mask = null;
        if (restricted && text is not null)
        {
            // The associated data names the party and the field: one value per party and field (the unique key of the table).
            var (k, key0) = await keys.ActiveAsync(u.Connection, null, u.TenantId, "DATA", http.RequestAborted);
            enc = Envelope.Seal(key0, Encoding.UTF8.GetBytes(text), EnvelopeAad.ForColumn(u.TenantId, "pty.PartyCustomField", "ValueEnc:" + d.FieldKey, p.PublicId));
            keyId = k;
            mask = IdentityNumbers.Mask(text.Length > 32 ? text[^32..] : text);
        }
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE pty.PartyCustomField SET ValueText = @text, ValueEnc = @enc, EncKeyId = @key, ValueMask = @mask, CurrencyId = @cur, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE PartyId = @p AND DefinitionId = @d;
            IF @@ROWCOUNT = 0
                INSERT pty.PartyCustomField (TenantId, PartyId, DefinitionId, ValueText, ValueEnc, EncKeyId, ValueMask, CurrencyId, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @p, @d, @text, @enc, @key, @mask, @cur, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """,
            new { text = restricted ? null : text, enc, key = keyId, mask, cur = currency, p = p.PartyId, d = d.CustomFieldDefinitionId }, tx, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("CUSTOM_FIELD_SET", restricted ? "IDENTITY_ACCESS" : "TREASURY", "pty.Party", p.PartyId,
            AfterJson: JsonSerializer.Serialize(new { field = d.FieldKey, value = restricted ? mask : text })), null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    private static async Task<IResult> RevealCustomFieldAsync(Guid id, string key, RevealRequest b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var p = await FindAsync(u, null, id, http.RequestAborted);
        var d = await DefinitionAsync(u.Connection, null, key, http.RequestAborted);
        var row = await u.Connection.QuerySingleOrDefaultAsync<(byte[]? Enc, long? KeyId, string? Text)>(new CommandDefinition(
            "SELECT ValueEnc, EncKeyId, ValueText FROM pty.PartyCustomField WHERE PartyId = @p AND DefinitionId = @d;", new { p = p.PartyId, d = d.CustomFieldDefinitionId },
            cancellationToken: http.RequestAborted));
        if (row.Enc is null) return Results.Ok(new { value = row.Text });
        var ua = http.Request.Headers.UserAgent.ToString();
        if (!(await u.PermissionsAsync(http.RequestAborted)).Contains(Reveal))
        {
            await AuditWriter.SensitiveAccessAsync(u.Connection, null, "CUSTOM_FIELD_REVEAL", "CUSTOM_FIELD_REVEAL_DENIED", "pty.PartyCustomField", p.PartyId, p.PartyId, null, false,
                "NO_PERMISSION", b.Reason, ua, http.RequestAborted);
            throw ApiProblemException.Forbidden();
        }
        var k = await keys.ByIdAsync(u.Connection, null, u.TenantId, row.KeyId!.Value, http.RequestAborted);
        var value = Encoding.UTF8.GetString(Envelope.Open(k, row.Enc, EnvelopeAad.ForColumn(u.TenantId, "pty.PartyCustomField", "ValueEnc:" + d.FieldKey, p.PublicId)));
        await AuditWriter.SensitiveAccessAsync(u.Connection, null, "CUSTOM_FIELD_REVEAL", "CUSTOM_FIELD_REVEALED", "pty.PartyCustomField", p.PartyId, p.PartyId, null, true, null,
            b.Reason, ua, http.RequestAborted);
        http.Response.Headers.CacheControl = "no-store";
        return Results.Ok(new { value });
    }
}

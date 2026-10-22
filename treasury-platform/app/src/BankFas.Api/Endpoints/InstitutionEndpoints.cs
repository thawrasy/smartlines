using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using BankFas.Api.Infrastructure;
using BankFas.Core.Text;
using BankFas.Data;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record InstitutionRequest(string? Code, string? NameAr, string? NameEn, string? Type, string? Country, string? SwiftBic, string? Website, Guid? Party,
    string? Notes);
public sealed record UnitRequest(string? Parent, bool? ToRoot, string? UnitType, string? NameAr, string? NameEn, bool? IsActive);
public sealed record ContactRequest(string? FullNameAr, string? FullNameEn, string? JobTitleAr, string? JobTitleEn, string? Unit, Guid? ReportsTo, bool? ClearReportsTo,
    string? Notes, List<ContactMethodRequest>? ContactMethods);
public sealed record ContactDeactivateRequest(string? Reason, Dictionary<string, Guid?>? ProductReplacements, Guid? SubordinatesReportTo, bool? LeaveSubordinatesEmpty);
public sealed record LinkPartyRequest(Guid? Party);
public sealed record RelationshipRequest(Guid? Company, Guid? Institution, string? CustomerNo, string? Status, string? StartedOn, string? Notes);
public sealed record CloseRequest(string? ClosedOn, string? Reason, bool? RevokeSignatories = null);
public sealed record CoverageRequest(Guid? Contact, string? Role, int? Rank, bool? IsPrimary, string? ValidFrom, string? Notes);
public sealed record ReplaceCoverageRequest(Guid? Contact, string? ValidFrom);
public sealed record EndCoverageRequest(string? ValidTo);
public sealed record RelationshipProductRequest(Guid? DefaultContact, bool? ClearDefaultContact, string? Channel, string? ChannelNotes, bool? IsActive, string? SinceDate);
public sealed record BankSetupRequest(InstitutionRequest? Institution, List<BankSetupCompany>? Companies, List<BankSetupContact>? Contacts, List<BankSetupProduct>? Products,
    bool? DryRun);
public sealed record BankSetupCompany(Guid? Company, string? CustomerNo, string? StartedOn, List<BankSetupCoverage>? Coverage);
public sealed record BankSetupCoverage(string? ContactKey, string? Role, int? Rank, bool? IsPrimary);
public sealed record BankSetupContact(string? Key, string? FullNameAr, string? FullNameEn, string? JobTitleAr, string? JobTitleEn, List<ContactMethodRequest>? ContactMethods);
public sealed record BankSetupProduct(Guid? Company, string? Product, string? Channel, string? DefaultContactKey);

/// <summary>
/// Financial institutions, their units and contacts, and the company–institution relationships with their coverage,
/// products and channels (FR-INS-001 to 016, 019, 021; spec 11 section 5.1), the services SVC-01 ResolveContact and
/// SVC-02 GetPreferredChannel, and the atomic bank set-up wizard (FR-INS-014, BR-INS-013). Institutions are the
/// tenant's; a relationship belongs to a company and is seen within the user's company scope. Locality is derived from
/// the tenant's home country and never stored (BR-INS-002). A contact is a light record with no identity; linking it
/// to a party (promotion) makes it a usage provider of that party, and a merge re-points it (BR-INS-014).
/// </summary>
public static partial class InstitutionEndpoints
{
    private const string View = "ins.view";
    private const string Manage = "ins.manage";
    private const string ContactsManage = "ins.contacts.manage";
    private const string RelationshipManage = "ins.relationship.manage";
    private const string Deactivate = "ins.deactivate";
    private const string Export = "ins.export";
    private const string Wizard = "ins.wizard.run";
    private static readonly string[] Channels = ["BANK_PORTAL", "MANUAL_FORM", "DIRECT_INTEGRATION"];
    private static readonly string[] OpenStatuses = ["PROSPECT", "ACTIVE", "SUSPENDED"];
    private static readonly string[] InactiveReasons = ["LEFT_BANK", "TRANSFERRED", "OTHER"];

    /// <summary>BR-INS-008: the default rank of the four coverage roles.</summary>
    private static readonly Dictionary<string, int> DefaultRanks = new(StringComparer.Ordinal) { ["RM"] = 1, ["TEAM_LEAD"] = 2, ["REGIONAL_MGR"] = 3, ["DEPT_HEAD"] = 4 };

    [GeneratedRegex("^[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?$", RegexOptions.CultureInvariant)]
    private static partial Regex Bic();

    [GeneratedRegex("^[A-Z0-9][A-Z0-9_.-]{0,39}$", RegexOptions.CultureInvariant)]
    private static partial Regex CodePattern();

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/institutions", ListAsync);
        api.MapPost("/institutions", CreateAsync);
        api.MapGet("/institutions/{id:guid}", GetAsync);
        api.MapPatch("/institutions/{id:guid}", PatchAsync);
        api.MapPost("/institutions/{id:guid}/actions/activate", ActivateAsync);
        api.MapPost("/institutions/{id:guid}/actions/deactivate", DeactivateAsync);
        api.MapPost("/institutions/{id:guid}/contact-methods", (Guid id, ContactMethodRequest b, HttpContext h, SqlConnectionFactory d, OpaqueRefs r) =>
            AddOwnerMethodAsync(id, null, b, h, d, r));
        api.MapPost("/institutions/{id:guid}/units", AddUnitAsync);
        api.MapPatch("/institutions/{id:guid}/units/{unit}", PatchUnitAsync);
        api.MapPost("/institutions/{id:guid}/units/{unit}/contact-methods", (Guid id, string unit, ContactMethodRequest b, HttpContext h, SqlConnectionFactory d, OpaqueRefs r) =>
            AddOwnerMethodAsync(id, unit, b, h, d, r));
        api.MapPost("/institutions/{id:guid}/contacts", AddContactAsync);
        api.MapGet("/contacts/{id:guid}", GetContactAsync);
        api.MapPatch("/contacts/{id:guid}", PatchContactAsync);
        api.MapPost("/contacts/{id:guid}/contact-methods", AddContactMethodAsync);
        api.MapDelete("/contacts/{id:guid}/contact-methods/{reference}", DeleteContactMethodAsync);
        api.MapPost("/contacts/{id:guid}/actions/link-party", LinkPartyAsync);
        api.MapPost("/contacts/{id:guid}/actions/unlink-party", UnlinkPartyAsync);
        api.MapPost("/contacts/{id:guid}/actions/deactivate", DeactivateContactAsync);
        api.MapGet("/relationships", RelationshipsAsync);
        api.MapPost("/relationships", CreateRelationshipAsync);
        api.MapGet("/relationships/{id:guid}", GetRelationshipAsync);
        api.MapPatch("/relationships/{id:guid}", PatchRelationshipAsync);
        api.MapPost("/relationships/{id:guid}/actions/close", CloseRelationshipAsync);
        api.MapPost("/relationships/{id:guid}/actions/reopen", ReopenRelationshipAsync);
        api.MapGet("/relationships/{id:guid}/escalation", EscalationAsync);
        api.MapPost("/relationships/{id:guid}/coverage", AddCoverageAsync);
        api.MapPost("/relationships/{id:guid}/coverage/{reference}/actions/replace", ReplaceCoverageAsync);
        api.MapPost("/relationships/{id:guid}/coverage/{reference}/actions/end", EndCoverageAsync);
        api.MapPut("/relationships/{id:guid}/products/{product}", SetProductAsync);
        api.MapGet("/services/resolve-contact", ResolveContactAsync);
        api.MapGet("/services/preferred-channel", PreferredChannelAsync);
        api.MapPost("/bank-setup", BankSetupAsync);
    }

    // ---------- shared lookups ----------

    private static DateTime? Date(string? text, string field) =>
        string.IsNullOrWhiteSpace(text) ? null
        : DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
        : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is a date YYYY-MM-DD.");

    private static string? D(DateTime? d) => d?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static string? T(string? text, int max, string field)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var t = text.Trim();
        return t.Length <= max ? t : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is up to {max} characters.");
    }

    private static DateTime Today(TimeProvider clock) => clock.GetUtcNow().UtcDateTime.Date;

    /// <summary>An active item of a lookup list, by code: its id and sort order.</summary>
    internal static async Task<(int Id, string Code, int SortOrder)> LookupAsync(SqlConnection c, SqlTransaction? tx, string list, string? code, CancellationToken ct) =>
        string.IsNullOrWhiteSpace(code) ? throw ApiProblemException.Invalid("VALIDATION_FAILED", $"Choose the {list.ToLowerInvariant().Replace('_', ' ')}.")
        : await c.QuerySingleOrDefaultAsync<(int, string, int)?>(new CommandDefinition(
            """
            SELECT i.LookupItemId, i.Code, i.SortOrder FROM cat.LookupItem AS i JOIN cat.LookupList AS l ON l.LookupListId = i.LookupListId
             WHERE l.Code = @list AND i.Code = @code AND i.IsActive = 1 AND i.Status = 'ACTIVE';
            """, new { list, code = code.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
          ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", $"Choose the {list.ToLowerInvariant().Replace('_', ' ')} from the list.");

    /// <summary>A company within the user's scope, by its public id.</summary>
    internal static async Task<(long Id, Guid PublicId, string Name)> CompanyAsync(BoundUser u, SqlTransaction? tx, CompanyScope scope, Guid? id, CancellationToken ct)
    {
        if (id is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the company.");
        var row = await u.Connection.QuerySingleOrDefaultAsync<(long, Guid, string, string)?>(new CommandDefinition(
            "SELECT CompanyId, PublicId, ISNULL(NameAr, NameEn), Status FROM org.Company WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct));
        if (row is not { } r || !scope.Allows(r.Item1)) throw ApiProblemException.Invalid("COMPANY_UNKNOWN", "Choose a company you may work on.");
        if (r.Item4 == "ARCHIVED") throw new ApiProblemException(409, "V-ORG-ARCHIVED", "The company is archived.");
        return (r.Item1, r.Item2, r.Item3);
    }

    // ---------- institutions ----------

    internal sealed record InstitutionRow(long InstitutionId, Guid PublicId, string Code, string NameAr, string? NameEn, string Type, bool RequiresParty, string Country,
        string Locality, string? SwiftBic, string? Website, long? PartyId, Guid? Party, string? PartyCode, string Status, string? Notes, byte[] RowVersion);

    private const string InstitutionSelect =
        """
        SELECT i.InstitutionId, i.PublicId, i.Code, i.NameAr, i.NameEn, t.Code AS Type, t.RequiresParty, co.Iso2 AS Country,
               CASE WHEN i.CountryId = ct.HomeCountryId THEN 'LOCAL' ELSE 'FOREIGN' END AS Locality, i.SwiftBic, i.Website, i.PartyId, p.PublicId AS Party,
               p.PartyCode, i.Status, i.Notes, i.RowVersion
          FROM ins.Institution AS i
          JOIN cat.InstitutionType AS t ON t.InstitutionTypeId = i.InstitutionTypeId
          JOIN ref.Country AS co ON co.CountryId = i.CountryId
          CROSS JOIN plat.v_CurrentTenant AS ct
          LEFT JOIN pty.Party AS p ON p.PartyId = i.PartyId
        """;

    private static object Shape(InstitutionRow i) => new
    {
        id = i.PublicId, code = i.Code, nameAr = i.NameAr, nameEn = i.NameEn, type = i.Type, country = i.Country, locality = i.Locality, swiftBic = i.SwiftBic,
        website = i.Website, party = i.Party, partyCode = i.PartyCode, status = i.Status, notes = i.Notes, etag = ETags.Of(i.RowVersion),
    };

    internal static async Task<InstitutionRow> FindAsync(SqlConnection c, SqlTransaction? tx, Guid id, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<InstitutionRow>(new CommandDefinition(InstitutionSelect + " WHERE i.PublicId = @id;", new { id }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.NotFound();

    /// <summary>FR-INS-019 in part: by code, name, BIC or a customer number at the bank.</summary>
    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "q", "type", "status", "locality", "country");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var q = http.Request.Query;
        var text = q["q"].ToString().Trim();
        var rows = await u.Connection.QueryAsync<InstitutionRow>(new CommandDefinition(
            InstitutionSelect + """
             WHERE (@type IS NULL OR t.Code = @type) AND (@status IS NULL OR i.Status = @status) AND (@country IS NULL OR co.Iso2 = @country)
               AND (@locality IS NULL OR (@locality = 'LOCAL' AND i.CountryId = ct.HomeCountryId) OR (@locality = 'FOREIGN' AND i.CountryId <> ct.HomeCountryId))
               AND (@q = '' OR i.Code = @code OR i.SwiftBic = @code OR i.NameAr LIKE @like OR i.NameEn LIKE @like
                    OR EXISTS (SELECT 1 FROM ins.Relationship AS r WHERE r.InstitutionId = i.InstitutionId AND r.CustomerNoAtBank = @code))
             ORDER BY i.Code
             OFFSET 0 ROWS FETCH NEXT 200 ROWS ONLY;
            """,
            new
            {
                type = Up(q["type"]), status = Up(q["status"]), country = Up(q["country"]), locality = Up(q["locality"]), q = text,
                code = Normalizer.Code(text), like = "%" + text + "%",
            }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(Shape) });
    }

    private static string? Up(Microsoft.Extensions.Primitives.StringValues v) => v.ToString() is { Length: > 0 } s ? s.Trim().ToUpperInvariant() : null;

    private sealed record InstitutionValues(string NameAr, string? NameEn, int TypeId, bool RequiresParty, int CountryId, string? Bic, string? Website, long? PartyId,
        string? Notes);

    private static async Task<InstitutionValues> InstitutionValuesAsync(SqlConnection c, SqlTransaction? tx, InstitutionRequest b, InstitutionRow? current, CancellationToken ct)
    {
        var nameAr = (b.NameAr is null ? current?.NameAr : T(b.NameAr, 200, "Arabic name")) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter the Arabic name.");
        var type = await c.QuerySingleOrDefaultAsync<(int Id, bool RequiresParty)?>(new CommandDefinition(
            "SELECT InstitutionTypeId, RequiresParty FROM cat.InstitutionType WHERE Code = @code AND IsActive = 1;",
            new { code = (b.Type ?? current?.Type)?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the type of institution.");
        var country = (b.Country ?? current?.Country)?.Trim().ToUpperInvariant();
        var countryId = await c.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CountryId FROM ref.Country WHERE Iso2 = @c AND IsActive = 1;", new { c = country }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.Invalid("COUNTRY_UNKNOWN", "Choose a country from the list.");
        var bic = b.SwiftBic is null ? current?.SwiftBic : Normalizer.Code(b.SwiftBic) is { Length: > 0 } x ? x : null;
        if (bic is not null && !Bic().IsMatch(bic)) throw ApiProblemException.Invalid("V-INS-01", "The BIC has 8 or 11 characters: 4 letters for the bank, 2 for the country, then letters or digits.");
        long? partyId = current?.PartyId;
        if (b.Party is not null)
            partyId = await c.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT PartyId FROM pty.Party WHERE PublicId = @p AND IsActive = 1 AND Kind = 'INDIVIDUAL';",
                new { p = b.Party }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-INS-07", "Choose an active individual party.");
        // BR-INS-003: a type that requires a party has one; the others have none.
        if (type.RequiresParty && partyId is null) throw ApiProblemException.Invalid("V-INS-PARTY", "An institution of this type is linked to a party.");
        if (!type.RequiresParty && partyId is not null) throw ApiProblemException.Invalid("V-INS-PARTY", "Only an individual lender is linked to a party.");
        return new InstitutionValues(nameAr, b.NameEn is null ? current?.NameEn : T(b.NameEn, 200, "English name"), type.Id, type.RequiresParty, countryId, bic,
            b.Website is null ? current?.Website : T(b.Website, 300, "web site"), partyId, b.Notes is null ? current?.Notes : T(b.Notes, 2000, "notes"));
    }

    /// <summary>V-INS-02 (a warning): another institution with the same BIC or a similar name.</summary>
    private static async Task<List<object>> InstitutionWarningsAsync(SqlConnection c, SqlTransaction? tx, InstitutionValues v, long? except, CancellationToken ct)
    {
        var rows = await c.QueryAsync<(string Code, string NameAr, bool SameBic)>(new CommandDefinition(
            """
            SELECT TOP (5) Code, NameAr, CASE WHEN SwiftBic = @bic THEN 1 ELSE 0 END FROM ins.Institution
             WHERE InstitutionId <> ISNULL(@except, -1) AND ((@bic IS NOT NULL AND SwiftBic = @bic) OR NameAr = @ar OR (@en IS NOT NULL AND NameEn = @en));
            """, new { bic = v.Bic, ar = v.NameAr, en = v.NameEn, except }, tx, cancellationToken: ct));
        return [.. rows.Select(r => (object)new { code = r.SameBic ? "V-INS-02-BIC" : "V-INS-02-NAME", institution = r.Code, name = r.NameAr })];
    }

    internal static async Task<(long Id, Guid PublicId, List<object> Warnings)> InsertInstitutionAsync(BoundUser u, SqlTransaction tx, InstitutionRequest b, string status,
        CancellationToken ct)
    {
        var code = Normalizer.Code(b.Code ?? "");
        if (!CodePattern().IsMatch(code)) throw ApiProblemException.Invalid("V-INS-01", "The code is up to 40 letters, digits, dots, dashes or underscores, without spaces.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM ins.Institution WHERE Code = @code;", new { code }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-INS-01", $"An institution with the code {code} exists.");
        var v = await InstitutionValuesAsync(u.Connection, tx, b, null, ct);
        if (v.PartyId is not null && await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM ins.Institution WHERE PartyId = @p;",
                new { p = v.PartyId }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-INS-07", "This party is already an institution.");
        var warnings = await InstitutionWarningsAsync(u.Connection, tx, v, null, ct);
        var row = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT ins.Institution (TenantId, Code, NameAr, NameEn, InstitutionTypeId, CountryId, SwiftBic, Website, PartyId, Status, Notes, CreatedBy)
            OUTPUT inserted.InstitutionId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @ar, @en, @type, @country, @bic, @web, @party, @status, @notes, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """,
            new { code, ar = v.NameAr, en = v.NameEn, type = v.TypeId, country = v.CountryId, bic = v.Bic, web = v.Website, party = v.PartyId, status, notes = v.Notes },
            tx, cancellationToken: ct));
        await Outbox.EmitAsync(u.Connection, tx, "institution.created", "ins.Institution", row.Id, new { institution = row.PublicId, code }, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("INSTITUTION_CREATED", "TREASURY", "ins.Institution", row.Id,
            AfterJson: JsonSerializer.Serialize(new { code, v.NameAr, v.NameEn, status, v.Bic })), null, ct);
        return (row.Id, row.PublicId, warnings);
    }

    private static async Task<IResult> CreateAsync(InstitutionRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var (_, publicId, warnings) = await InsertInstitutionAsync(u, tx, b, "ACTIVE", http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/institutions/{publicId}", new { id = publicId, warnings });
    }

    private sealed record UnitRow(long InstitutionUnitId, long? ParentUnitId, string UnitType, string NameAr, string? NameEn, bool IsActive, byte[] RowVersion);
    private sealed record ContactRow(long ContactId, Guid PublicId, long InstitutionId, long? UnitId, string FullNameAr, string? FullNameEn, string? JobTitleAr,
        string? JobTitleEn, long? ReportsToContactId, Guid? ReportsTo, long? PartyId, Guid? Party, string? PartyCode, string Status, string? InactiveReason, string? Notes,
        byte[] RowVersion);

    private const string ContactSelect =
        """
        SELECT k.ContactId, k.PublicId, k.InstitutionId, k.UnitId, k.FullNameAr, k.FullNameEn, k.JobTitleAr, k.JobTitleEn, k.ReportsToContactId, m.PublicId AS ReportsTo,
               k.PartyId, p.PublicId AS Party, p.PartyCode, k.Status, k.InactiveReason, k.Notes, k.RowVersion
          FROM ins.Contact AS k
          LEFT JOIN ins.Contact AS m ON m.ContactId = k.ReportsToContactId
          LEFT JOIN pty.Party AS p ON p.PartyId = k.PartyId
        """;

    private static object ShapeContact(ContactRow k, OpaqueRefs refs, int tenant, object? methods = null) => new
    {
        id = k.PublicId, unit = k.UnitId is { } unit ? refs.ItemRef(tenant, "unit", unit) : null, fullNameAr = k.FullNameAr, fullNameEn = k.FullNameEn,
        jobTitleAr = k.JobTitleAr, jobTitleEn = k.JobTitleEn, reportsTo = k.ReportsTo, party = k.Party, partyCode = k.PartyCode, status = k.Status,
        inactiveReason = k.InactiveReason, notes = k.Notes, contactMethods = methods, etag = ETags.Of(k.RowVersion),
    };

    /// <summary>The institution with its units, contacts, relationships in scope and contact methods (SCR-INS-02).</summary>
    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var i = await FindAsync(u.Connection, null, id, ct);
        var scope = await CompanyScope.OfAsync(u, ct);
        var units = await u.Connection.QueryAsync<UnitRow>(new CommandDefinition(
            """
            SELECT n.InstitutionUnitId, n.ParentUnitId, t.Code AS UnitType, n.NameAr, n.NameEn, n.IsActive, n.RowVersion
              FROM ins.InstitutionUnit AS n JOIN cat.LookupItem AS t ON t.LookupItemId = n.UnitTypeId
             WHERE n.InstitutionId = @i ORDER BY n.ParentUnitId, n.NameAr;
            """, new { i = i.InstitutionId }, cancellationToken: ct));
        var contacts = (await u.Connection.QueryAsync<ContactRow>(new CommandDefinition(ContactSelect + " WHERE k.InstitutionId = @i ORDER BY k.Status, k.FullNameAr;",
            new { i = i.InstitutionId }, cancellationToken: ct))).ToList();
        var methods = (await u.Connection.QueryAsync<(long ContactId, string Kind, string Value, bool IsPrimary)>(new CommandDefinition(
            "SELECT m.ContactId, m.Kind, m.Value, m.IsPrimary FROM pty.ContactMethod AS m JOIN ins.Contact AS k ON k.ContactId = m.ContactId WHERE k.InstitutionId = @i;",
            new { i = i.InstitutionId }, cancellationToken: ct))).ToLookup(m => m.ContactId);
        var relationships = await u.Connection.QueryAsync<(Guid Id, Guid Company, string CompanyName, string? CustomerNo, string Status)>(new CommandDefinition(
            """
            SELECT r.PublicId, c.PublicId, ISNULL(c.NameAr, c.NameEn), r.CustomerNoAtBank, r.Status
              FROM ins.Relationship AS r JOIN org.Company AS c ON c.CompanyId = r.CompanyId
             WHERE r.InstitutionId = @i AND (@all = 1 OR r.CompanyId IN @ids) ORDER BY 3;
            """, new { i = i.InstitutionId, all = scope.All, ids = scope.SqlIds }, cancellationToken: ct));
        ETags.Set(http.Response, i.RowVersion);
        return Results.Ok(new
        {
            institution = Shape(i),
            contactMethods = await PartyContacts.MethodsAsync(u.Connection, null, PartyContacts.Owner.Institution, i.InstitutionId, refs, u.TenantId, ct),
            units = units.Select(n => new
            {
                id = refs.ItemRef(u.TenantId, "unit", n.InstitutionUnitId), parent = n.ParentUnitId is { } p ? refs.ItemRef(u.TenantId, "unit", p) : null,
                unitType = n.UnitType, nameAr = n.NameAr, nameEn = n.NameEn, isActive = n.IsActive, etag = ETags.Of(n.RowVersion),
            }),
            contacts = contacts.Select(k => ShapeContact(k, refs, u.TenantId,
                methods[k.ContactId].Select(m => new { kind = m.Kind, value = m.Value, isPrimary = m.IsPrimary }))),
            relationships = relationships.Select(r => new { id = r.Id, company = r.Company, companyName = r.CompanyName, customerNo = r.CustomerNo, status = r.Status }),
        });
    }

    private static async Task<IResult> PatchAsync(Guid id, InstitutionRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var i = await FindAsync(u.Connection, tx, id, http.RequestAborted);
        if (b.Code is not null && Normalizer.Code(b.Code) != i.Code) throw ApiProblemException.Invalid("V-INS-01", "The code of an institution does not change.");
        if (i.Status == "INACTIVE") throw new ApiProblemException(409, "V-INS-INACTIVE", "An inactive institution is read-only.");
        var v = await InstitutionValuesAsync(u.Connection, tx, b, i, http.RequestAborted);
        var warnings = await InstitutionWarningsAsync(u.Connection, tx, v, i.InstitutionId, http.RequestAborted);
        byte[] rv;
        try
        {
            rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
                """
                DECLARE @o TABLE (RowVersion BINARY(8));
                UPDATE ins.Institution SET NameAr = @ar, NameEn = @en, InstitutionTypeId = @type, CountryId = @country, SwiftBic = @bic, Website = @web, PartyId = @party,
                       Notes = @notes, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                OUTPUT inserted.RowVersion INTO @o WHERE InstitutionId = @id AND RowVersion = @rv;
                SELECT RowVersion FROM @o;
                """,
                new { ar = v.NameAr, en = v.NameEn, type = v.TypeId, country = v.CountryId, bic = v.Bic, web = v.Website, party = v.PartyId, notes = v.Notes, id = i.InstitutionId, rv = expected },
                tx, cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "V-INS-07", "This party is already an institution.");
        }
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("INSTITUTION_UPDATED", "TREASURY", "ins.Institution", i.InstitutionId,
            BeforeJson: JsonSerializer.Serialize(new { i.NameAr, i.NameEn, i.Type, i.Country, i.SwiftBic }),
            AfterJson: JsonSerializer.Serialize(new { v.NameAr, v.NameEn, b.Type, b.Country, v.Bic })), null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.Ok(new { warnings });
    }

    private static async Task<IResult> ActivateAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var i = await FindAsync(u.Connection, tx, id, http.RequestAborted);
        if (i.Status == "ACTIVE") return Results.NoContent();
        await SetInstitutionStatusAsync(u, tx, i, "ACTIVE", http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>BR-INS-012: an institution is deactivated once all its relationships are closed.</summary>
    private static async Task<IResult> DeactivateAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Deactivate);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var i = await FindAsync(u.Connection, tx, id, http.RequestAborted);
        var open = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM ins.Relationship WHERE InstitutionId = @i AND Status <> 'CLOSED';",
            new { i = i.InstitutionId }, tx, cancellationToken: http.RequestAborted));
        if (open > 0) throw new ApiProblemException(409, "V-INS-OPEN-RELATIONSHIPS", $"Close the {open} open relationship(s) with this institution first.");
        await SetInstitutionStatusAsync(u, tx, i, "INACTIVE", http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    private static async Task SetInstitutionStatusAsync(BoundUser u, SqlTransaction tx, InstitutionRow i, string status, CancellationToken ct)
    {
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE ins.Institution SET Status = @status, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE InstitutionId = @i;",
            new { status, i = i.InstitutionId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("INSTITUTION_STATUS_CHANGED", "TREASURY", "ins.Institution", i.InstitutionId,
            BeforeJson: JsonSerializer.Serialize(new { i.Status }), AfterJson: JsonSerializer.Serialize(new { status })), null, ct);
    }

    /// <summary>FR-INS-006: the phone, e-mail and web site of the institution or of one of its units.</summary>
    private static async Task<IResult> AddOwnerMethodAsync(Guid id, string? unit, ContactMethodRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var i = await FindAsync(u.Connection, tx, id, http.RequestAborted);
        long owner = i.InstitutionId;
        if (unit is not null) owner = (await UnitAsync(u, tx, i, unit, refs, http.RequestAborted)).Id;
        var methodId = await PartyContacts.AddContactMethodAsync(u.Connection, tx, unit is null ? PartyContacts.Owner.Institution : PartyContacts.Owner.Unit, owner, i.Country, b,
            http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created((string?)null, new { id = refs.ItemRef(u.TenantId, "contact-method", methodId) });
    }

    // ---------- units (FR-INS-005, BR-INS-004) ----------

    private static async Task<(long Id, long? ParentId, string Type)> UnitAsync(BoundUser u, SqlTransaction? tx, InstitutionRow i, string reference, OpaqueRefs refs,
        CancellationToken ct)
    {
        var unitId = refs.ItemId(u.TenantId, "unit", reference) ?? throw ApiProblemException.NotFound();
        return await u.Connection.QuerySingleOrDefaultAsync<(long, long?, string)?>(new CommandDefinition(
            """
            SELECT n.InstitutionUnitId, n.ParentUnitId, t.Code FROM ins.InstitutionUnit AS n JOIN cat.LookupItem AS t ON t.LookupItemId = n.UnitTypeId
             WHERE n.InstitutionUnitId = @n AND n.InstitutionId = @i;
            """, new { n = unitId, i = i.InstitutionId }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
    }

    /// <summary>The ancestors of a unit, itself first, up to the root.</summary>
    private static async Task<List<long>> AncestorsAsync(SqlConnection c, SqlTransaction? tx, long unitId, CancellationToken ct) =>
        [.. await c.QueryAsync<long>(new CommandDefinition(
            """
            WITH up AS (SELECT InstitutionUnitId, ParentUnitId, 1 AS Depth FROM ins.InstitutionUnit WHERE InstitutionUnitId = @n
                        UNION ALL
                        SELECT p.InstitutionUnitId, p.ParentUnitId, up.Depth + 1 FROM ins.InstitutionUnit AS p JOIN up ON p.InstitutionUnitId = up.ParentUnitId WHERE up.Depth < 10)
            SELECT InstitutionUnitId FROM up ORDER BY Depth OPTION (MAXRECURSION 10);
            """, new { n = unitId }, tx, cancellationToken: ct))];

    /// <summary>The height of the subtree under a unit, itself counted.</summary>
    private static Task<int> HeightAsync(SqlConnection c, SqlTransaction? tx, long unitId, CancellationToken ct) =>
        c.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            WITH down AS (SELECT InstitutionUnitId, 1 AS Depth FROM ins.InstitutionUnit WHERE InstitutionUnitId = @n
                          UNION ALL
                          SELECT ch.InstitutionUnitId, down.Depth + 1 FROM ins.InstitutionUnit AS ch JOIN down ON ch.ParentUnitId = down.InstitutionUnitId WHERE down.Depth < 10)
            SELECT MAX(Depth) FROM down OPTION (MAXRECURSION 10);
            """, new { n = unitId }, tx, cancellationToken: ct));

    /// <summary>BR-INS-004: a section sits under a department or a branch, a department under a branch or the root, a branch under a branch or the root.</summary>
    private static void CheckUnitType(string type, string? parentType)
    {
        var allowed = type switch
        {
            "SECTION" => parentType is "DEPARTMENT" or "BRANCH",
            "DEPARTMENT" => parentType is null or "BRANCH",
            "BRANCH" => parentType is null or "BRANCH",
            _ => true,
        };
        if (!allowed) throw ApiProblemException.Invalid("V-INS-03", $"A unit of type {type} cannot sit under {parentType ?? "the institution itself"}.");
    }

    private static async Task<IResult> AddUnitAsync(Guid id, UnitRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var i = await FindAsync(u.Connection, tx, id, ct);
        var type = await LookupAsync(u.Connection, tx, "UNIT_TYPE", b.UnitType, ct);
        (long Id, long? ParentId, string Type)? parent = b.Parent is null ? null : await UnitAsync(u, tx, i, b.Parent, refs, ct);
        CheckUnitType(type.Code, parent?.Type);
        if (parent is { } p && (await AncestorsAsync(u.Connection, tx, p.Id, ct)).Count >= 4)
            throw ApiProblemException.Invalid("V-INS-03", "The structure of an institution is at most four levels deep.");
        var nameAr = T(b.NameAr, 200, "Arabic name") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter the Arabic name.");
        long unitId;
        try
        {
            unitId = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT ins.InstitutionUnit (TenantId, InstitutionId, ParentUnitId, UnitTypeId, NameAr, NameEn, CreatedBy)
                OUTPUT inserted.InstitutionUnitId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @i, @parent, @type, @ar, @en, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new { i = i.InstitutionId, parent = parent?.Id, type = type.Id, ar = nameAr, en = T(b.NameEn, 200, "English name") }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "V-INS-UNIT-EXISTS", "A unit with this name exists at this place.");
        }
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("INSTITUTION_UNIT_CREATED", "TREASURY", "ins.InstitutionUnit", unitId,
            AfterJson: JsonSerializer.Serialize(new { institution = i.Code, type = type.Code, nameAr })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created((string?)null, new { id = refs.ItemRef(u.TenantId, "unit", unitId) });
    }

    private static async Task<IResult> PatchUnitAsync(Guid id, string unit, UnitRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var i = await FindAsync(u.Connection, tx, id, ct);
        var n = await UnitAsync(u, tx, i, unit, refs, ct);
        if (b.UnitType is not null && !string.Equals(b.UnitType, n.Type, StringComparison.OrdinalIgnoreCase))
            throw ApiProblemException.Invalid("V-INS-03", "The type of a unit does not change: add a new unit.");
        var parentId = n.ParentId;
        if (b.ToRoot == true) parentId = null;
        else if (b.Parent is not null)
        {
            var p = await UnitAsync(u, tx, i, b.Parent, refs, ct);
            var ancestors = await AncestorsAsync(u.Connection, tx, p.Id, ct);
            if (ancestors.Contains(n.Id)) throw ApiProblemException.Invalid("V-INS-03", "A unit cannot sit under itself or under one of its own units.");
            CheckUnitType(n.Type, p.Type);
            if (ancestors.Count + await HeightAsync(u.Connection, tx, n.Id, ct) > 4)
                throw ApiProblemException.Invalid("V-INS-03", "The structure of an institution is at most four levels deep.");
            parentId = p.Id;
        }
        if (parentId is null) CheckUnitType(n.Type, null);
        byte[] rv;
        try
        {
            rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
                """
                DECLARE @o TABLE (RowVersion BINARY(8));
                UPDATE ins.InstitutionUnit SET ParentUnitId = @parent, NameAr = ISNULL(@ar, NameAr), NameEn = CASE WHEN @setEn = 1 THEN @en ELSE NameEn END,
                       IsActive = ISNULL(@active, IsActive), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                OUTPUT inserted.RowVersion INTO @o WHERE InstitutionUnitId = @n AND RowVersion = @rv;
                SELECT RowVersion FROM @o;
                """,
                new { parent = parentId, ar = T(b.NameAr, 200, "Arabic name"), setEn = b.NameEn is not null, en = T(b.NameEn, 200, "English name"), active = b.IsActive, n = n.Id, rv = expected },
                tx, cancellationToken: ct)) ?? throw ETags.Conflict();
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "V-INS-UNIT-EXISTS", "A unit with this name exists at this place.");
        }
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("INSTITUTION_UNIT_UPDATED", "TREASURY", "ins.InstitutionUnit", n.Id,
            AfterJson: JsonSerializer.Serialize(new { b.NameAr, b.NameEn, b.IsActive, moved = parentId != n.ParentId })), null, ct);
        await tx.CommitAsync(ct);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    // ---------- contacts (FR-INS-007, 008, 016; BR-INS-005, 006, 014) ----------

    private static async Task<(ContactRow Contact, InstitutionRow Institution)> ContactAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct)
    {
        var k = await u.Connection.QuerySingleOrDefaultAsync<ContactRow>(new CommandDefinition(ContactSelect + " WHERE k.PublicId = @id;", new { id }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        var i = await u.Connection.QuerySingleAsync<InstitutionRow>(new CommandDefinition(InstitutionSelect + " WHERE i.InstitutionId = @i;", new { i = k.InstitutionId }, tx,
            cancellationToken: ct));
        return (k, i);
    }

    /// <summary>BR-INS-005: the manager is another contact of the same institution and no chain of managers leads back.</summary>
    private static async Task<long> ManagerAsync(SqlConnection c, SqlTransaction tx, long institutionId, long? self, Guid manager, CancellationToken ct)
    {
        var m = await c.QuerySingleOrDefaultAsync<(long Id, long InstitutionId)?>(new CommandDefinition(
            "SELECT ContactId, InstitutionId FROM ins.Contact WHERE PublicId = @m;", new { m = manager }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("V-INS-03", "Choose a contact of this institution.");
        if (m.InstitutionId != institutionId) throw ApiProblemException.Invalid("V-INS-03", "A contact reports to a contact of the same institution.");
        if (self is null) return m.Id;
        if (m.Id == self) throw ApiProblemException.Invalid("V-INS-03", "A contact does not report to itself.");
        var chain = await c.QueryAsync<long>(new CommandDefinition(
            """
            WITH up AS (SELECT ContactId, ReportsToContactId, 1 AS Depth FROM ins.Contact WHERE ContactId = @m
                        UNION ALL
                        SELECT k.ContactId, k.ReportsToContactId, up.Depth + 1 FROM ins.Contact AS k JOIN up ON k.ContactId = up.ReportsToContactId WHERE up.Depth < 20)
            SELECT ContactId FROM up OPTION (MAXRECURSION 20);
            """, new { m = m.Id }, tx, cancellationToken: ct));
        if (chain.Contains(self.Value)) throw ApiProblemException.Invalid("V-INS-03", "This would make a circle of managers.");
        return m.Id;
    }

    private static readonly string[] ReachKinds = ["MOBILE", "PHONE", "EMAIL"];

    internal static async Task<(long Id, Guid PublicId)> InsertContactAsync(BoundUser u, SqlTransaction tx, InstitutionRow i, ContactRequest b, long? unitId,
        CancellationToken ct)
    {
        var nameAr = T(b.FullNameAr, 200, "Arabic name") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter the name in Arabic.");
        var methods = b.ContactMethods ?? [];
        // BR-INS-006: a phone, a mobile or an e-mail, at least.
        if (!methods.Any(m => ReachKinds.Contains(m.Kind?.Trim().ToUpperInvariant())))
            throw ApiProblemException.Invalid("V-INS-04", "Give a phone, a mobile or an e-mail for the contact.");
        long? manager = b.ReportsTo is { } r ? await ManagerAsync(u.Connection, tx, i.InstitutionId, null, r, ct) : null;
        var row = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT ins.Contact (TenantId, InstitutionId, UnitId, FullNameAr, FullNameEn, JobTitleAr, JobTitleEn, ReportsToContactId, Notes, CreatedBy)
            OUTPUT inserted.ContactId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @i, @unit, @ar, @en, @jar, @jen, @manager, @notes, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """,
            new
            {
                i = i.InstitutionId, unit = unitId, ar = nameAr, en = T(b.FullNameEn, 200, "English name"), jar = T(b.JobTitleAr, 200, "job title"),
                jen = T(b.JobTitleEn, 200, "job title"), manager, notes = T(b.Notes, 1000, "notes"),
            }, tx, cancellationToken: ct));
        foreach (var m in methods)
            await PartyContacts.AddContactMethodAsync(u.Connection, tx, PartyContacts.Owner.Contact, row.Id, i.Country, m, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("INSTITUTION_CONTACT_CREATED", "TREASURY", "ins.Contact", row.Id,
            AfterJson: JsonSerializer.Serialize(new { institution = i.Code, nameAr, methods = methods.Count })), null, ct);
        return row;
    }

    private static async Task<IResult> AddContactAsync(Guid id, ContactRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, ContactsManage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var i = await FindAsync(u.Connection, tx, id, http.RequestAborted);
        if (i.Status == "INACTIVE") throw new ApiProblemException(409, "V-INS-INACTIVE", "An inactive institution is read-only.");
        long? unitId = b.Unit is null ? null : (await UnitAsync(u, tx, i, b.Unit, refs, http.RequestAborted)).Id;
        var row = await InsertContactAsync(u, tx, i, b, unitId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/contacts/{row.PublicId}", new { id = row.PublicId });
    }

    private static async Task<IResult> GetContactAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var (k, i) = await ContactAsync(u, null, id, http.RequestAborted);
        var coverage = await u.Connection.QueryAsync<(Guid Relationship, string Company, string Role, int Rank, DateTime ValidFrom, DateTime? ValidTo)>(new CommandDefinition(
            """
            SELECT r.PublicId, ISNULL(c.NameAr, c.NameEn), ro.Code, rc.Rank, rc.ValidFrom, rc.ValidTo
              FROM ins.RelationshipContact AS rc JOIN ins.Relationship AS r ON r.RelationshipId = rc.RelationshipId
              JOIN org.Company AS c ON c.CompanyId = r.CompanyId JOIN cat.LookupItem AS ro ON ro.LookupItemId = rc.RoleId
             WHERE rc.ContactId = @k ORDER BY rc.ValidTo, rc.Rank;
            """, new { k = k.ContactId }, cancellationToken: http.RequestAborted));
        ETags.Set(http.Response, k.RowVersion);
        return Results.Ok(new
        {
            contact = ShapeContact(k, refs, u.TenantId,
                await PartyContacts.MethodsAsync(u.Connection, null, PartyContacts.Owner.Contact, k.ContactId, refs, u.TenantId, http.RequestAborted)),
            institution = new { id = i.PublicId, code = i.Code, nameAr = i.NameAr },
            coverage = coverage.Select(c => new { relationship = c.Relationship, company = c.Company, role = c.Role, rank = c.Rank, validFrom = D(c.ValidFrom), validTo = D(c.ValidTo) }),
        });
    }

    private static async Task<IResult> PatchContactAsync(Guid id, ContactRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, ContactsManage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var (k, i) = await ContactAsync(u, tx, id, ct);
        if (k.Status == "INACTIVE") throw new ApiProblemException(409, "V-INS-CONTACT-INACTIVE", "An inactive contact is read-only.");
        long? manager = b.ClearReportsTo == true ? null : b.ReportsTo is { } r ? await ManagerAsync(u.Connection, tx, i.InstitutionId, k.ContactId, r, ct) : k.ReportsToContactId;
        long? unitId = b.Unit is null ? k.UnitId : (await UnitAsync(u, tx, i, b.Unit, refs, ct)).Id;
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE ins.Contact SET FullNameAr = ISNULL(@ar, FullNameAr), FullNameEn = CASE WHEN @setEn = 1 THEN @en ELSE FullNameEn END,
                   JobTitleAr = CASE WHEN @setJar = 1 THEN @jar ELSE JobTitleAr END, JobTitleEn = CASE WHEN @setJen = 1 THEN @jen ELSE JobTitleEn END,
                   UnitId = @unit, ReportsToContactId = @manager, Notes = CASE WHEN @setNotes = 1 THEN @notes ELSE Notes END,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.RowVersion INTO @o WHERE ContactId = @k AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """,
            new
            {
                ar = T(b.FullNameAr, 200, "Arabic name"), setEn = b.FullNameEn is not null, en = T(b.FullNameEn, 200, "English name"), setJar = b.JobTitleAr is not null,
                jar = T(b.JobTitleAr, 200, "job title"), setJen = b.JobTitleEn is not null, jen = T(b.JobTitleEn, 200, "job title"), unit = unitId, manager,
                setNotes = b.Notes is not null, notes = T(b.Notes, 1000, "notes"), k = k.ContactId, rv = expected,
            }, tx, cancellationToken: ct)) ?? throw ETags.Conflict();
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("INSTITUTION_CONTACT_UPDATED", "TREASURY", "ins.Contact", k.ContactId,
            BeforeJson: JsonSerializer.Serialize(new { k.FullNameAr, reportsTo = k.ReportsTo }), AfterJson: JsonSerializer.Serialize(new { b.FullNameAr, b.ReportsTo, b.ClearReportsTo })),
            null, ct);
        await tx.CommitAsync(ct);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    private static async Task<IResult> AddContactMethodAsync(Guid id, ContactMethodRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, ContactsManage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var (k, i) = await ContactAsync(u, tx, id, http.RequestAborted);
        var methodId = await PartyContacts.AddContactMethodAsync(u.Connection, tx, PartyContacts.Owner.Contact, k.ContactId, i.Country, b, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created((string?)null, new { id = refs.ItemRef(u.TenantId, "contact-method", methodId) });
    }

    /// <summary>BR-INS-006: the last phone, mobile or e-mail of a contact stays.</summary>
    private static async Task<IResult> DeleteContactMethodAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, ContactsManage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var (k, _) = await ContactAsync(u, tx, id, http.RequestAborted);
        var methodId = refs.ItemId(u.TenantId, "contact-method", reference) ?? throw ApiProblemException.NotFound();
        await PartyContacts.DeleteContactMethodAsync(u.Connection, tx, PartyContacts.Owner.Contact, k.ContactId, methodId, http.RequestAborted);
        var left = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM pty.ContactMethod WHERE ContactId = @k AND Kind IN ('MOBILE', 'PHONE', 'EMAIL');", new { k = k.ContactId }, tx, cancellationToken: http.RequestAborted));
        if (left == 0) throw ApiProblemException.Invalid("V-INS-04", "A contact keeps a phone, a mobile or an e-mail.");
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>BR-INS-014: promotion links an existing party; nothing of its identity is copied, and the pair (institution, party) is unique (V-INS-07).</summary>
    private static async Task<IResult> LinkPartyAsync(Guid id, LinkPartyRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, ContactsManage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var (k, i) = await ContactAsync(u, tx, id, ct);
        var party = await u.Connection.QuerySingleOrDefaultAsync<(long Id, string Kind)?>(new CommandDefinition(
            "SELECT PartyId, Kind FROM pty.Party WHERE PublicId = @p AND IsActive = 1;", new { p = b.Party }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("V-INS-07", "Choose an active party.");
        if (party.Kind != "INDIVIDUAL") throw ApiProblemException.Invalid("V-INS-07", "A contact is linked to an individual party.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM ins.Contact WHERE InstitutionId = @i AND PartyId = @p AND ContactId <> @k;", new { i = i.InstitutionId, p = party.Id, k = k.ContactId }, tx,
                cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-INS-07", "Another contact of this institution is already linked to this party.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE ins.Contact SET PartyId = @p, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ContactId = @k;",
            new { p = party.Id, k = k.ContactId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("INSTITUTION_CONTACT_LINKED", "TREASURY", "ins.Contact", k.ContactId,
            AfterJson: JsonSerializer.Serialize(new { party = b.Party })), null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> UnlinkPartyAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, ContactsManage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var (k, _) = await ContactAsync(u, tx, id, http.RequestAborted);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE ins.Contact SET PartyId = NULL, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ContactId = @k;",
            new { k = k.ContactId }, tx, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("INSTITUTION_CONTACT_UNLINKED", "TREASURY", "ins.Contact", k.ContactId,
            BeforeJson: JsonSerializer.Serialize(new { party = k.Party })), null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>
    /// FR-INS-016, AC-INS-2: a contact that is the default for products needs a replacement for each, keyed
    /// "{relationship}/{product}" (or null to fall
    /// back to the relationship manager, BR-INS-009); its reports need a new manager or an explicit "leave empty". Its
    /// open coverage ends on the day.
    /// </summary>
    private static async Task<IResult> DeactivateContactAsync(Guid id, ContactDeactivateRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, ContactsManage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var (k, i) = await ContactAsync(u, tx, id, ct);
        if (k.Status == "INACTIVE") return Results.NoContent();
        var reason = b.Reason?.Trim().ToUpperInvariant();
        if (reason is null || !InactiveReasons.Contains(reason)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason: LEFT_BANK, TRANSFERRED or OTHER.");
        var products = (await u.Connection.QueryAsync<(long Id, string Product, string Company, Guid Relationship)>(new CommandDefinition(
            """
            SELECT rp.RelationshipProductId, p.Code, ISNULL(c.NameAr, c.NameEn), r.PublicId
              FROM ins.RelationshipProduct AS rp JOIN cat.Product AS p ON p.ProductId = rp.ProductId
              JOIN ins.Relationship AS r ON r.RelationshipId = rp.RelationshipId JOIN org.Company AS c ON c.CompanyId = r.CompanyId
             WHERE rp.DefaultContactId = @k AND rp.IsActive = 1;
            """, new { k = k.ContactId }, tx, cancellationToken: ct))).ToList();
        var reports = (await u.Connection.QueryAsync<(long Id, Guid PublicId, string Name)>(new CommandDefinition(
            "SELECT ContactId, PublicId, FullNameAr FROM ins.Contact WHERE ReportsToContactId = @k AND Status = 'ACTIVE';", new { k = k.ContactId }, tx, cancellationToken: ct))).ToList();
        var given = b.ProductReplacements ?? [];
        // A product row is named by its relationship and product code: "{relationship}/{product}".
        static string Key((long Id, string Product, string Company, Guid Relationship) p) => $"{p.Relationship}/{p.Product}";
        var missing = products.Where(p => !given.ContainsKey(Key(p))).ToList();
        if (missing.Count > 0 || (reports.Count > 0 && b.SubordinatesReportTo is null && b.LeaveSubordinatesEmpty != true))
            return Results.Json(new
            {
                status = 409, code = "V-INS-REPLACEMENT-REQUIRED", title = "Choose who replaces this contact for its products and its reports.",
                products = missing.Select(p => new { id = Key(p), relationship = p.Relationship, product = p.Product, company = p.Company }),
                reports = reports.Select(r => new { id = r.PublicId, name = r.Name }),
            }, statusCode: 409, contentType: "application/problem+json");
        foreach (var p in products)
        {
            var replacement = given[Key(p)];
            long? newId = null;
            if (replacement is { } g)
            {
                newId = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                    "SELECT ContactId FROM ins.Contact WHERE PublicId = @g AND InstitutionId = @i AND Status = 'ACTIVE' AND ContactId <> @k;",
                    new { g, i = i.InstitutionId, k = k.ContactId }, tx, cancellationToken: ct))
                    ?? throw ApiProblemException.Invalid("V-INS-06", "The replacement is an active contact of the same institution.");
            }
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE ins.RelationshipProduct SET DefaultContactId = @n, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE RelationshipProductId = @p;",
                new { n = newId, p = p.Id }, tx, cancellationToken: ct));
        }
        var warnings = new List<object>();
        if (reports.Count > 0)
        {
            long? manager = b.SubordinatesReportTo is { } m ? await ManagerAsync(u.Connection, tx, i.InstitutionId, null, m, ct) : null;
            if (manager == k.ContactId || reports.Any(r => r.Id == manager)) throw ApiProblemException.Invalid("V-INS-03", "Choose another manager for the reports.");
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE ins.Contact SET ReportsToContactId = @m, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ReportsToContactId = @k;",
                new { m = manager, k = k.ContactId }, tx, cancellationToken: ct));
            if (manager is null) warnings.Add(new { code = "W-INS-NO-MANAGER", count = reports.Count });
        }
        var today = Today(clock);
        var covered = await u.Connection.QueryAsync<long>(new CommandDefinition(
            "SELECT DISTINCT RelationshipId FROM ins.RelationshipContact WHERE ContactId = @k AND (ValidTo IS NULL OR ValidTo > @today);",
            new { k = k.ContactId, today }, tx, cancellationToken: ct));
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ins.RelationshipContact SET ValidTo = CASE WHEN ValidFrom > @today THEN ValidFrom ELSE @today END, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE ContactId = @k AND (ValidTo IS NULL OR ValidTo > @today);
            UPDATE ins.Contact SET Status = 'INACTIVE', InactiveReason = @reason, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE ContactId = @k;
            """, new { today, k = k.ContactId, reason }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("INSTITUTION_CONTACT_DEACTIVATED", "TREASURY", "ins.Contact", k.ContactId,
            AfterJson: JsonSerializer.Serialize(new { reason, products = products.Count, reports = reports.Count })), null, ct);
        await NoRelationshipManagerAsync(u, tx, covered, today, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { warnings });
    }

    // ---------- relationships (FR-INS-009, 016; BR-INS-007, 011) ----------

    internal sealed record RelationshipRow(long RelationshipId, Guid PublicId, long CompanyId, Guid Company, string CompanyName, long InstitutionId, Guid Institution,
        string InstitutionCode, string InstitutionName, string? CustomerNoAtBank, string Status, DateTime? StartedOn, DateTime? ClosedOn, string? ClosureReason, string? Notes,
        byte[] RowVersion);

    private const string RelationshipSelect =
        """
        SELECT r.RelationshipId, r.PublicId, r.CompanyId, c.PublicId AS Company, ISNULL(c.NameAr, c.NameEn) AS CompanyName, r.InstitutionId, i.PublicId AS Institution,
               i.Code AS InstitutionCode, i.NameAr AS InstitutionName, r.CustomerNoAtBank, r.Status, r.StartedOn, r.ClosedOn, r.ClosureReason, r.Notes, r.RowVersion
          FROM ins.Relationship AS r JOIN org.Company AS c ON c.CompanyId = r.CompanyId JOIN ins.Institution AS i ON i.InstitutionId = r.InstitutionId
        """;

    private static object Shape(RelationshipRow r) => new
    {
        id = r.PublicId, company = r.Company, companyName = r.CompanyName, institution = r.Institution, institutionCode = r.InstitutionCode,
        institutionName = r.InstitutionName, customerNo = r.CustomerNoAtBank, status = r.Status, startedOn = D(r.StartedOn), closedOn = D(r.ClosedOn),
        closureReason = r.ClosureReason, notes = r.Notes, etag = ETags.Of(r.RowVersion),
    };

    internal static async Task<RelationshipRow> RelationshipAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct)
    {
        var r = await u.Connection.QuerySingleOrDefaultAsync<RelationshipRow>(new CommandDefinition(RelationshipSelect + " WHERE r.PublicId = @id;", new { id }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (!(await CompanyScope.OfAsync(u, ct, tx)).Allows(r.CompanyId)) throw ApiProblemException.NotFound();
        return r;
    }

    private static async Task<IResult> RelationshipsAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company", "institution", "status");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var q = http.Request.Query;
        var rows = await u.Connection.QueryAsync<RelationshipRow>(new CommandDefinition(
            RelationshipSelect + """
             WHERE (@all = 1 OR r.CompanyId IN @ids) AND (@company IS NULL OR c.PublicId = @company) AND (@institution IS NULL OR i.PublicId = @institution)
               AND (@status IS NULL OR r.Status = @status)
             ORDER BY i.Code, 5;
            """,
            new
            {
                all = scope.All, ids = scope.SqlIds, company = Guid.TryParse(q["company"], out var c) ? c : (Guid?)null,
                institution = Guid.TryParse(q["institution"], out var i) ? i : (Guid?)null, status = Up(q["status"]),
            }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(Shape) });
    }

    /// <summary>V-INS-05: a customer number already used at this institution is a warning only (BR-INS-007).</summary>
    private static async Task<List<object>> CustomerNoWarningsAsync(SqlConnection c, SqlTransaction tx, long institutionId, string? customerNo, long? except, CancellationToken ct)
    {
        if (customerNo is null) return [];
        var others = await c.QueryAsync<string>(new CommandDefinition(
            """
            SELECT ISNULL(co.NameAr, co.NameEn) FROM ins.Relationship AS r JOIN org.Company AS co ON co.CompanyId = r.CompanyId
             WHERE r.InstitutionId = @i AND r.CustomerNoAtBank = @n AND r.RelationshipId <> ISNULL(@except, -1);
            """, new { i = institutionId, n = customerNo, except }, tx, cancellationToken: ct));
        return [.. others.Select(o => (object)new { code = "V-INS-05-CUSTOMER-NO", company = o })];
    }

    internal static async Task<(long Id, Guid PublicId, List<object> Warnings)> InsertRelationshipAsync(BoundUser u, SqlTransaction tx, long companyId, long institutionId,
        string? customerNo, string status, DateTime? startedOn, string? notes, CancellationToken ct)
    {
        var number = customerNo is null ? null : Normalizer.Code(customerNo) is { Length: > 0 } n ? n : null;
        if (number is { Length: > 40 }) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The customer number is up to 40 characters.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM ins.Relationship WHERE CompanyId = @c AND InstitutionId = @i;",
                new { c = companyId, i = institutionId }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-INS-05", "This company already has a relationship with this institution: reopen it if it is closed.");
        var warnings = await CustomerNoWarningsAsync(u.Connection, tx, institutionId, number, null, ct);
        var row = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT ins.Relationship (TenantId, CompanyId, InstitutionId, CustomerNoAtBank, Status, StartedOn, Notes, CreatedBy)
            OUTPUT inserted.RelationshipId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @i, @n, @status, @started, @notes, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new { c = companyId, i = institutionId, n = number, status, started = startedOn, notes }, tx, cancellationToken: ct));
        await Outbox.EmitAsync(u.Connection, tx, "relationship.created", "ins.Relationship", row.Id, new { relationship = row.PublicId }, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("RELATIONSHIP_CREATED", "TREASURY", "ins.Relationship", row.Id,
            AfterJson: JsonSerializer.Serialize(new { customerNo = number, status })), companyId, ct);
        return (row.Id, row.PublicId, warnings);
    }

    private static string OpenStatus(string? status) =>
        status is null ? "ACTIVE"
        : status.Trim().ToUpperInvariant() is var s && OpenStatuses.Contains(s) ? s
        : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The status is PROSPECT, ACTIVE or SUSPENDED; close a relationship with its action.");

    private static async Task<IResult> CreateRelationshipAsync(RelationshipRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, RelationshipManage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var company = await CompanyAsync(u, tx, await CompanyScope.OfAsync(u, ct, tx), b.Company, ct);
        var i = await FindAsync(u.Connection, tx, b.Institution ?? Guid.Empty, ct);
        if (i.Status == "INACTIVE") throw new ApiProblemException(409, "V-INS-INACTIVE", "The institution is inactive.");
        var (_, publicId, warnings) = await InsertRelationshipAsync(u, tx, company.Id, i.InstitutionId, b.CustomerNo, OpenStatus(b.Status), Date(b.StartedOn, "start date"),
            T(b.Notes, 2000, "notes"), ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/relationships/{publicId}", new { id = publicId, warnings });
    }

    private static async Task<IResult> GetRelationshipAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var r = await RelationshipAsync(u, null, id, ct);
        var coverage = await CoverageAsync(u.Connection, r.RelationshipId, refs, u.TenantId, false, ct);
        var products = await u.Connection.QueryAsync<(long Id, string Product, string NameAr, Guid? Contact, string? ContactName, string Channel, string? Notes, bool IsActive,
            DateTime? Since, byte[] RowVersion)>(new CommandDefinition(
            """
            SELECT rp.RelationshipProductId, p.Code, p.NameAr, k.PublicId, k.FullNameAr, rp.PreferredChannel, rp.ChannelNotes, rp.IsActive, rp.SinceDate, rp.RowVersion
              FROM ins.RelationshipProduct AS rp JOIN cat.Product AS p ON p.ProductId = rp.ProductId LEFT JOIN ins.Contact AS k ON k.ContactId = rp.DefaultContactId
             WHERE rp.RelationshipId = @r ORDER BY p.SortOrder, p.Code;
            """, new { r = r.RelationshipId }, cancellationToken: ct));
        var accounts = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM acc.BankAccount WHERE RelationshipId = @r AND Status <> 'CLOSED';",
            new { r = r.RelationshipId }, cancellationToken: ct));
        ETags.Set(http.Response, r.RowVersion);
        return Results.Ok(new
        {
            relationship = Shape(r),
            coverage,
            products = products.Select(p => new
            {
                id = refs.ItemRef(u.TenantId, "relationship-product", p.Id), product = p.Product, productName = p.NameAr, defaultContact = p.Contact,
                defaultContactName = p.ContactName, channel = p.Channel, channelNotes = p.Notes, isActive = p.IsActive, sinceDate = D(p.Since), etag = ETags.Of(p.RowVersion),
            }),
            openAccounts = accounts,
        });
    }

    private static async Task<List<object>> CoverageAsync(SqlConnection c, long relationshipId, OpaqueRefs refs, int tenant, bool activeOnly, CancellationToken ct)
    {
        var rows = await c.QueryAsync<(long Id, Guid Contact, string Name, string? Title, string Status, string Role, string RoleName, int Rank, bool IsPrimary, DateTime ValidFrom,
            DateTime? ValidTo, string? Notes)>(new CommandDefinition(
            """
            SELECT rc.RelationshipContactId, k.PublicId, k.FullNameAr, k.JobTitleAr, k.Status, ro.Code, ro.NameAr, rc.Rank, rc.IsPrimary, rc.ValidFrom, rc.ValidTo, rc.Notes
              FROM ins.RelationshipContact AS rc JOIN ins.Contact AS k ON k.ContactId = rc.ContactId JOIN cat.LookupItem AS ro ON ro.LookupItemId = rc.RoleId
             WHERE rc.RelationshipId = @r AND (@active = 0 OR rc.ValidTo IS NULL)
             ORDER BY CASE WHEN rc.ValidTo IS NULL THEN 0 ELSE 1 END, rc.Rank, rc.ValidFrom DESC;
            """, new { r = relationshipId, active = activeOnly }, cancellationToken: ct));
        return [.. rows.Select(x => (object)new
        {
            id = refs.ItemRef(tenant, "coverage", x.Id), contact = x.Contact, contactName = x.Name, jobTitle = x.Title, contactStatus = x.Status, role = x.Role,
            roleName = x.RoleName, rank = x.Rank, isPrimary = x.IsPrimary, validFrom = D(x.ValidFrom), validTo = D(x.ValidTo), notes = x.Notes,
        })];
    }

    private static async Task<IResult> PatchRelationshipAsync(Guid id, RelationshipRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, RelationshipManage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await RelationshipAsync(u, tx, id, ct);
        if (r.Status == "CLOSED") throw new ApiProblemException(409, "V-INS-CLOSED", "A closed relationship is read-only: reopen it first.");
        if (b.Company is not null || b.Institution is not null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The company and the institution of a relationship do not change.");
        var number = b.CustomerNo is null ? r.CustomerNoAtBank : Normalizer.Code(b.CustomerNo) is { Length: > 0 } n ? n : null;
        var warnings = await CustomerNoWarningsAsync(u.Connection, tx, r.InstitutionId, number, r.RelationshipId, ct);
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE ins.Relationship SET CustomerNoAtBank = @n, Status = @status, StartedOn = @started, Notes = @notes, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.RowVersion INTO @o WHERE RelationshipId = @r AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """,
            new
            {
                n = number, status = b.Status is null ? r.Status : OpenStatus(b.Status), started = b.StartedOn is null ? r.StartedOn : Date(b.StartedOn, "start date"),
                notes = b.Notes is null ? r.Notes : T(b.Notes, 2000, "notes"), r = r.RelationshipId, rv = expected,
            }, tx, cancellationToken: ct)) ?? throw ETags.Conflict();
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("RELATIONSHIP_UPDATED", "TREASURY", "ins.Relationship", r.RelationshipId,
            BeforeJson: JsonSerializer.Serialize(new { customerNo = r.CustomerNoAtBank, r.Status }), AfterJson: JsonSerializer.Serialize(new { customerNo = number, b.Status })),
            r.CompanyId, ct);
        await tx.CommitAsync(ct);
        ETags.Set(http.Response, rv);
        return Results.Ok(new { warnings });
    }

    /// <summary>BR-INS-011: not with an account that is not closed; the coverage ends and the products stop on the closing date.</summary>
    private static async Task<IResult> CloseRelationshipAsync(Guid id, CloseRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Deactivate);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await RelationshipAsync(u, tx, id, ct);
        if (r.Status == "CLOSED") return Results.NoContent();
        var reason = T(b.Reason, 300, "reason") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason for closing.");
        var closedOn = Date(b.ClosedOn, "closing date") ?? Today(clock);
        if (r.StartedOn is { } s && closedOn < s) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The closing date comes after the start date.");
        var accounts = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM acc.BankAccount WHERE RelationshipId = @r AND Status <> 'CLOSED';",
            new { r = r.RelationshipId }, tx, cancellationToken: ct));
        if (accounts > 0) throw new ApiProblemException(409, "V-INS-OPEN-ACCOUNTS", $"Close the {accounts} account(s) of this relationship first.");
        // OQ-16: the signatories in force are listed, and revoked with the closing once the user confirms.
        var signatories = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM acc.Signatory WHERE RelationshipId = @r AND Status IN ('PENDING', 'ACTIVE', 'SUSPENDED');", new { r = r.RelationshipId }, tx, cancellationToken: ct));
        if (signatories > 0 && b.RevokeSignatories != true)
            throw new ApiProblemException(409, "V-INS-OPEN-SIGNATORIES", $"The relationship has {signatories} signatory(ies) in force; confirm to revoke them with the closing.");
        if (signatories > 0)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE acc.Signatory SET Status = 'REVOKED', RevokedAt = SYSUTCDATETIME(), RevokedReason = N'Relationship closed', UpdatedAt = SYSUTCDATETIME(),
                       UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE RelationshipId = @r AND Status IN ('PENDING', 'ACTIVE', 'SUSPENDED');
                """, new { r = r.RelationshipId }, tx, cancellationToken: ct));
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ins.RelationshipContact SET ValidTo = CASE WHEN ValidFrom > @d THEN ValidFrom ELSE @d END, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE RelationshipId = @r AND (ValidTo IS NULL OR ValidTo > @d);
            UPDATE ins.RelationshipProduct SET IsActive = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE RelationshipId = @r AND IsActive = 1;
            UPDATE ins.Relationship SET Status = 'CLOSED', ClosedOn = @d, ClosureReason = @reason, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE RelationshipId = @r;
            """, new { r = r.RelationshipId, d = closedOn, reason }, tx, cancellationToken: ct));
        await Outbox.EmitAsync(u.Connection, tx, "relationship.closed", "ins.Relationship", r.RelationshipId, new { relationship = r.PublicId }, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("RELATIONSHIP_CLOSED", "TREASURY", "ins.Relationship", r.RelationshipId,
            BeforeJson: JsonSerializer.Serialize(new { r.Status }), AfterJson: JsonSerializer.Serialize(new { closedOn = D(closedOn), reason, revokedSignatories = signatories })), r.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>BR-INS-007: reopening keeps the history; the products and the coverage are set again.</summary>
    private static async Task<IResult> ReopenRelationshipAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, RelationshipManage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var r = await RelationshipAsync(u, tx, id, http.RequestAborted);
        if (r.Status != "CLOSED") return Results.NoContent();
        var i = await FindAsync(u.Connection, tx, r.Institution, http.RequestAborted);
        if (i.Status == "INACTIVE") throw new ApiProblemException(409, "V-INS-INACTIVE", "The institution is inactive.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ins.Relationship SET Status = 'ACTIVE', ClosedOn = NULL, ClosureReason = NULL, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE RelationshipId = @r;
            """, new { r = r.RelationshipId }, tx, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("RELATIONSHIP_REOPENED", "TREASURY", "ins.Relationship", r.RelationshipId,
            BeforeJson: JsonSerializer.Serialize(new { closedOn = D(r.ClosedOn), r.ClosureReason })), r.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>FR-INS-017: the escalation sheet, the active coverage by rank with each contact's ways to reach them.</summary>
    private static async Task<IResult> EscalationAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Export);
        var r = await RelationshipAsync(u, null, id, http.RequestAborted);
        var rows = await u.Connection.QueryAsync<(int Rank, string Role, string Name, string? Title, string? Unit, string? Methods)>(new CommandDefinition(
            """
            SELECT rc.Rank, ro.NameAr, k.FullNameAr, k.JobTitleAr, n.NameAr,
                   (SELECT STRING_AGG(m.Kind + ': ' + m.Value, N' · ') FROM pty.ContactMethod AS m WHERE m.ContactId = k.ContactId)
              FROM ins.RelationshipContact AS rc JOIN ins.Contact AS k ON k.ContactId = rc.ContactId AND k.Status = 'ACTIVE'
              JOIN cat.LookupItem AS ro ON ro.LookupItemId = rc.RoleId LEFT JOIN ins.InstitutionUnit AS n ON n.InstitutionUnitId = k.UnitId
             WHERE rc.RelationshipId = @r AND rc.ValidTo IS NULL ORDER BY rc.Rank;
            """, new { r = r.RelationshipId }, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("ESCALATION_SHEET_PRINTED", "TREASURY", "ins.Relationship", r.RelationshipId), r.CompanyId,
            http.RequestAborted);
        return Results.Ok(new
        {
            relationship = Shape(r),
            levels = rows.Select(x => new { rank = x.Rank, role = x.Role, name = x.Name, jobTitle = x.Title, unit = x.Unit, contactMethods = x.Methods }),
        });
    }

    // ---------- coverage (FR-INS-010, BR-INS-008) ----------

    internal static async Task<long> InsertCoverageAsync(BoundUser u, SqlTransaction tx, RelationshipRow r, long contactId, string? role, int? rank, bool primary,
        DateTime validFrom, string? notes, CancellationToken ct)
    {
        var roleItem = await LookupAsync(u.Connection, tx, "CONTACT_ROLE", role, ct);
        var active = await u.Connection.QueryAsync<(int Rank, int RoleId, long ContactId, bool IsPrimary)>(new CommandDefinition(
            "SELECT Rank, RoleId, ContactId, IsPrimary FROM ins.RelationshipContact WHERE RelationshipId = @r AND ValidTo IS NULL;", new { r = r.RelationshipId }, tx,
            cancellationToken: ct));
        var taken = active.Select(a => a.Rank).ToHashSet();
        int chosen;
        if (rank is { } given)
        {
            if (given < 1) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The rank is 1 or more.");
            if (taken.Contains(given)) throw new ApiProblemException(409, "V-INS-RANK", $"Rank {given} is taken in this relationship.");
            chosen = given;
        }
        else
        {
            // BR-INS-008: RM 1, team lead 2, regional manager 3, department head 4; the next free rank after that.
            chosen = DefaultRanks.TryGetValue(roleItem.Code, out var d) && !taken.Contains(d) ? d : Enumerable.Range(Math.Max(5, d), 1000).First(x => !taken.Contains(x));
        }
        if (active.Any(a => a.ContactId == contactId && a.RoleId == roleItem.Id))
            throw new ApiProblemException(409, "V-INS-COVERAGE-EXISTS", "This contact already has this role in the relationship.");
        if (primary && active.Any(a => a.RoleId == roleItem.Id && a.IsPrimary))
            throw new ApiProblemException(409, "V-INS-PRIMARY", "The relationship already has a primary contact in this role.");
        var id = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT ins.RelationshipContact (TenantId, InstitutionId, RelationshipId, ContactId, RoleId, Rank, IsPrimary, ValidFrom, Notes, CreatedBy)
            OUTPUT inserted.RelationshipContactId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @i, @r, @k, @role, @rank, @primary, @from, @notes, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new { i = r.InstitutionId, r = r.RelationshipId, k = contactId, role = roleItem.Id, rank = chosen, primary, from = validFrom, notes }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("RELATIONSHIP_COVERAGE_ADDED", "TREASURY", "ins.RelationshipContact", id,
            AfterJson: JsonSerializer.Serialize(new { role = roleItem.Code, rank = chosen, validFrom = D(validFrom) })), r.CompanyId, ct);
        return id;
    }

    private static async Task<long> ActiveContactAsync(SqlConnection c, SqlTransaction tx, long institutionId, Guid? contact, CancellationToken ct) =>
        await c.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT ContactId FROM ins.Contact WHERE PublicId = @k AND InstitutionId = @i AND Status = 'ACTIVE';",
            new { k = contact, i = institutionId }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.Invalid("V-INS-06", "Choose an active contact of the relationship's institution.");

    private static async Task<IResult> AddCoverageAsync(Guid id, CoverageRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, RelationshipManage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await RelationshipAsync(u, tx, id, ct);
        if (r.Status == "CLOSED") throw new ApiProblemException(409, "V-INS-CLOSED", "A closed relationship is read-only: reopen it first.");
        var contactId = await ActiveContactAsync(u.Connection, tx, r.InstitutionId, b.Contact, ct);
        var rowId = await InsertCoverageAsync(u, tx, r, contactId, b.Role, b.Rank, b.IsPrimary == true, Date(b.ValidFrom, "start date") ?? Today(clock),
            T(b.Notes, 500, "notes"), ct);
        await tx.CommitAsync(ct);
        return Results.Created((string?)null, new { id = refs.ItemRef(u.TenantId, "coverage", rowId) });
    }

    private static async Task<(long Id, long ContactId, string Role, int Rank, bool IsPrimary, DateTime ValidFrom, DateTime? ValidTo)> CoverageRowAsync(BoundUser u,
        SqlTransaction tx, RelationshipRow r, string reference, OpaqueRefs refs, CancellationToken ct)
    {
        var rowId = refs.ItemId(u.TenantId, "coverage", reference) ?? throw ApiProblemException.NotFound();
        return await u.Connection.QuerySingleOrDefaultAsync<(long, long, string, int, bool, DateTime, DateTime?)?>(new CommandDefinition(
            """
            SELECT rc.RelationshipContactId, rc.ContactId, ro.Code, rc.Rank, rc.IsPrimary, rc.ValidFrom, rc.ValidTo
              FROM ins.RelationshipContact AS rc JOIN cat.LookupItem AS ro ON ro.LookupItemId = rc.RoleId
             WHERE rc.RelationshipContactId = @id AND rc.RelationshipId = @r;
            """, new { id = rowId, r = r.RelationshipId }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
    }

    /// <summary>F-INS-2: the replacement takes the role, rank and primary flag from its start date; the old row ends the day before.</summary>
    private static async Task<IResult> ReplaceCoverageAsync(Guid id, string reference, ReplaceCoverageRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs,
        TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, RelationshipManage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await RelationshipAsync(u, tx, id, ct);
        var old = await CoverageRowAsync(u, tx, r, reference, refs, ct);
        if (old.ValidTo is not null) throw new ApiProblemException(409, "V-INS-COVERAGE-ENDED", "This coverage has ended.");
        var from = Date(b.ValidFrom, "start date") ?? Today(clock);
        if (from <= old.ValidFrom) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The replacement starts after the current coverage started.");
        var contactId = await ActiveContactAsync(u.Connection, tx, r.InstitutionId, b.Contact, ct);
        if (contactId == old.ContactId) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose another contact.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE ins.RelationshipContact SET ValidTo = @to, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE RelationshipContactId = @id;",
            new { to = from.AddDays(-1), id = old.Id }, tx, cancellationToken: ct));
        var rowId = await InsertCoverageAsync(u, tx, r, contactId, old.Role, old.Rank, old.IsPrimary, from, null, ct);
        await tx.CommitAsync(ct);
        return Results.Created((string?)null, new { id = refs.ItemRef(u.TenantId, "coverage", rowId) });
    }

    private static async Task<IResult> EndCoverageAsync(Guid id, string reference, EndCoverageRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs,
        TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, RelationshipManage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await RelationshipAsync(u, tx, id, ct);
        var row = await CoverageRowAsync(u, tx, r, reference, refs, ct);
        if (row.ValidTo is not null) return Results.NoContent();
        var to = Date(b.ValidTo, "end date") ?? Today(clock);
        if (to < row.ValidFrom) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The end date comes after the start date.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE ins.RelationshipContact SET ValidTo = @to, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE RelationshipContactId = @id;",
            new { to, id = row.Id }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("RELATIONSHIP_COVERAGE_ENDED", "TREASURY", "ins.RelationshipContact", row.Id,
            AfterJson: JsonSerializer.Serialize(new { validTo = D(to) })), r.CompanyId, ct);
        await NoRelationshipManagerAsync(u, tx, [r.RelationshipId], Today(clock), ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>
    /// INS.RELATIONSHIP_NO_RM (spec 13 section 9.2): an active relationship of these that is left without an active
    /// relationship manager after today tells TM and FO of its company, once a day.
    /// </summary>
    private static async Task NoRelationshipManagerAsync(BoundUser u, SqlTransaction tx, IEnumerable<long> relationshipIds, DateTime today, CancellationToken ct)
    {
        var ids = relationshipIds.Distinct().ToArray();
        if (ids.Length == 0) return;
        var bare = await u.Connection.QueryAsync<(long Id, long CompanyId, string? CompanyAr, string? CompanyEn, string Code, string NameAr, string? NameEn)>(new CommandDefinition(
            """
            SELECT r.RelationshipId, r.CompanyId, c.NameAr, c.NameEn, i.Code, i.NameAr, i.NameEn
              FROM ins.Relationship AS r JOIN org.Company AS c ON c.CompanyId = r.CompanyId JOIN ins.Institution AS i ON i.InstitutionId = r.InstitutionId
             WHERE r.RelationshipId IN @ids AND r.Status = 'ACTIVE'
               AND NOT EXISTS (SELECT 1 FROM ins.RelationshipContact AS rc JOIN cat.LookupItem AS ro ON ro.LookupItemId = rc.RoleId AND ro.Code = 'RM'
                                 JOIN ins.Contact AS k ON k.ContactId = rc.ContactId AND k.Status = 'ACTIVE'
                                WHERE rc.RelationshipId = r.RelationshipId AND (rc.ValidTo IS NULL OR rc.ValidTo > @today));
            """, new { ids, today }, tx, cancellationToken: ct));
        foreach (var r in bare)
            await Notifier.RequestAsync(u.Connection, tx, new NotificationRequest("INS.RELATIONSHIP_NO_RM", "ins.Relationship", r.Id,
                $"INS.RELATIONSHIP_NO_RM:ins.Relationship:{r.Id}:{today:yyyyMMdd}", r.CompanyId, new Dictionary<string, object?>
                {
                    ["companyName"] = new Dictionary<string, string?> { ["ar"] = r.CompanyAr ?? r.CompanyEn, ["en"] = r.CompanyEn ?? r.CompanyAr },
                    ["institutionCode"] = r.Code, ["institutionName"] = new Dictionary<string, string?> { ["ar"] = r.NameAr, ["en"] = r.NameEn ?? r.NameAr },
                }, ActorUserId: u.UserId), ct);
    }

    // ---------- products and channels (FR-INS-011 to 013, BR-INS-010) ----------

    private static string Channel(string? channel)
    {
        var c = string.IsNullOrWhiteSpace(channel) ? "MANUAL_FORM" : channel.Trim().ToUpperInvariant();
        if (!Channels.Contains(c)) throw ApiProblemException.Invalid("V-INS-06", "The channel is BANK_PORTAL or MANUAL_FORM.");
        // BR-INS-010: no integration adapter exists yet, so direct integration is refused.
        if (c == "DIRECT_INTEGRATION") throw ApiProblemException.Invalid("V-INS-06", "Direct integration needs an adapter, which is not available.");
        return c;
    }

    internal static async Task UpsertProductAsync(BoundUser u, SqlTransaction tx, RelationshipRow r, string? productCode, long? contactId, bool setContact, string? channel,
        string? notes, bool? isActive, DateTime? since, CancellationToken ct)
    {
        var product = await u.Connection.QuerySingleOrDefaultAsync<(int Id, string Code)?>(new CommandDefinition(
            "SELECT ProductId, Code FROM cat.Product WHERE Code = @c AND IsActive = 1;", new { c = productCode?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("V-INS-06", "Choose an active product.");
        var c = channel is null ? null : Channel(channel);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ins.RelationshipProduct SET DefaultContactId = CASE WHEN @setContact = 1 THEN @contact ELSE DefaultContactId END,
                   PreferredChannel = ISNULL(@channel, PreferredChannel), ChannelNotes = ISNULL(@notes, ChannelNotes), IsActive = ISNULL(@active, IsActive),
                   SinceDate = ISNULL(@since, SinceDate), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE RelationshipId = @r AND ProductId = @p;
            """, new { setContact, contact = contactId, channel = c, notes, active = isActive, since, r = r.RelationshipId, p = product.Id }, tx, cancellationToken: ct));
        if (n == 0)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT ins.RelationshipProduct (TenantId, InstitutionId, RelationshipId, ProductId, DefaultContactId, PreferredChannel, ChannelNotes, IsActive, SinceDate, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @i, @r, @p, @contact, ISNULL(@channel, 'MANUAL_FORM'), @notes, ISNULL(@active, 1), @since,
                        CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """, new { i = r.InstitutionId, r = r.RelationshipId, p = product.Id, contact = contactId, channel = c, notes, active = isActive, since }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(n == 0 ? "RELATIONSHIP_PRODUCT_ADDED" : "RELATIONSHIP_PRODUCT_UPDATED", "TREASURY", "ins.Relationship",
            r.RelationshipId, AfterJson: JsonSerializer.Serialize(new { product = product.Code, channel = c, defaultContact = setContact ? contactId is not null : (bool?)null, isActive })),
            r.CompanyId, ct);
    }

    private static async Task<IResult> SetProductAsync(Guid id, string product, RelationshipProductRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, RelationshipManage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await RelationshipAsync(u, tx, id, ct);
        if (r.Status == "CLOSED") throw new ApiProblemException(409, "V-INS-CLOSED", "A closed relationship is read-only: reopen it first.");
        long? contact = b.DefaultContact is null ? null : await ActiveContactAsync(u.Connection, tx, r.InstitutionId, b.DefaultContact, ct);
        await UpsertProductAsync(u, tx, r, product, contact, b.DefaultContact is not null || b.ClearDefaultContact == true, b.Channel, T(b.ChannelNotes, 500, "channel notes"),
            b.IsActive, Date(b.SinceDate, "start date"), ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- SVC-01 and SVC-02 ----------

    private static async Task<RelationshipRow> RelationshipFromQueryAsync(BoundUser u, HttpRequest request, CancellationToken ct)
    {
        var q = request.Query;
        if (Guid.TryParse(q["relationship"], out var rel)) return await RelationshipAsync(u, null, rel, ct);
        if (!Guid.TryParse(q["company"], out var company) || !Guid.TryParse(q["institution"], out var institution))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the relationship, or the company and the institution.");
        var id = await u.Connection.ExecuteScalarAsync<Guid?>(new CommandDefinition(
            """
            SELECT r.PublicId FROM ins.Relationship AS r JOIN org.Company AS c ON c.CompanyId = r.CompanyId JOIN ins.Institution AS i ON i.InstitutionId = r.InstitutionId
             WHERE c.PublicId = @company AND i.PublicId = @institution;
            """, new { company, institution }, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        return await RelationshipAsync(u, null, id, ct);
    }

    /// <summary>
    /// SVC-01, BR-INS-009: the default contact of the product when it is active; else the active relationship manager
    /// of the lowest rank on the date; else none.
    /// </summary>
    internal static async Task<(Guid? Contact, string? Name, string Source)> ResolveContactForAsync(SqlConnection c, long relationshipId, string? productCode, DateTime date,
        CancellationToken ct)
    {
        if (productCode is not null)
        {
            var d = await c.QuerySingleOrDefaultAsync<(Guid Id, string Name)?>(new CommandDefinition(
                """
                SELECT k.PublicId, k.FullNameAr FROM ins.RelationshipProduct AS rp JOIN cat.Product AS p ON p.ProductId = rp.ProductId
                  JOIN ins.Contact AS k ON k.ContactId = rp.DefaultContactId AND k.Status = 'ACTIVE'
                 WHERE rp.RelationshipId = @r AND p.Code = @p AND rp.IsActive = 1;
                """, new { r = relationshipId, p = productCode.Trim().ToUpperInvariant() }, cancellationToken: ct));
            if (d is { } x) return (x.Id, x.Name, "DEFAULT");
        }
        var rm = await c.QuerySingleOrDefaultAsync<(Guid Id, string Name)?>(new CommandDefinition(
            """
            SELECT TOP (1) k.PublicId, k.FullNameAr FROM ins.RelationshipContact AS rc JOIN cat.LookupItem AS ro ON ro.LookupItemId = rc.RoleId AND ro.Code = 'RM'
              JOIN ins.Contact AS k ON k.ContactId = rc.ContactId AND k.Status = 'ACTIVE'
             WHERE rc.RelationshipId = @r AND rc.ValidFrom <= @d AND (rc.ValidTo IS NULL OR rc.ValidTo >= @d)
             ORDER BY rc.Rank;
            """, new { r = relationshipId, d = date }, cancellationToken: ct));
        return rm is { } y ? (y.Id, y.Name, "RM") : (null, null, "NONE");
    }

    private static async Task<IResult> ResolveContactAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "relationship", "company", "institution", "product", "date");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var r = await RelationshipFromQueryAsync(u, http.Request, http.RequestAborted);
        var date = Date(http.Request.Query["date"], "date") ?? Today(clock);
        var (contact, name, source) = await ResolveContactForAsync(u.Connection, r.RelationshipId, http.Request.Query["product"].ToString() is { Length: > 0 } p ? p : null, date,
            http.RequestAborted);
        return Results.Ok(new { contact, name, source });
    }

    /// <summary>SVC-02: the channel set for the product in the relationship, or MANUAL_FORM by default.</summary>
    private static async Task<IResult> PreferredChannelAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "relationship", "company", "institution", "product");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var r = await RelationshipFromQueryAsync(u, http.Request, http.RequestAborted);
        var channel = await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition(
            """
            SELECT rp.PreferredChannel FROM ins.RelationshipProduct AS rp JOIN cat.Product AS p ON p.ProductId = rp.ProductId
             WHERE rp.RelationshipId = @r AND p.Code = @p AND rp.IsActive = 1;
            """, new { r = r.RelationshipId, p = http.Request.Query["product"].ToString().Trim().ToUpperInvariant() }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { channel = channel ?? "MANUAL_FORM", source = channel is null ? "DEFAULT" : "CONFIGURED" });
    }

    // ---------- the bank set-up wizard (FR-INS-014, BR-INS-013, AC-INS-1) ----------

    /// <summary>
    /// Institution, then a relationship per company, the contacts, the coverage and the product matrix, in one
    /// transaction: everything or nothing. A dry run does the same work and rolls it back, so the review shows exactly
    /// what "create" will make and its warnings (products without a default contact, a repeated customer number, a
    /// similar institution). Nothing is created when the code exists.
    /// </summary>
    private static async Task<IResult> BankSetupAsync(BankSetupRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Wizard);
        var ct = http.RequestAborted;
        if (b.Institution is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Describe the institution.");
        var companies = b.Companies ?? [];
        if (companies.Count == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose at least one company.");
        if (companies.Select(c => c.Company).Distinct().Count() != companies.Count) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A company is chosen once.");
        var today = Today(clock);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, ct);
        var scope = await CompanyScope.OfAsync(u, ct, tx);
        var warnings = new List<object>();
        var (institutionId, institutionPublicId, institutionWarnings) = await InsertInstitutionAsync(u, tx, b.Institution, "ACTIVE", ct);
        warnings.AddRange(institutionWarnings);
        var institution = await FindAsync(u.Connection, tx, institutionPublicId, ct);

        var contacts = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var k in b.Contacts ?? [])
        {
            var key = k.Key?.Trim() is { Length: > 0 } x ? x : throw ApiProblemException.Invalid("VALIDATION_FAILED", "Each contact has a key the coverage and products refer to.");
            if (contacts.ContainsKey(key)) throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The contact key {key} is used twice.");
            contacts[key] = (await InsertContactAsync(u, tx, institution,
                new ContactRequest(k.FullNameAr, k.FullNameEn, k.JobTitleAr, k.JobTitleEn, null, null, null, null, k.ContactMethods), null, ct)).Id;
        }
        long ContactOf(string? key) => key is not null && contacts.TryGetValue(key, out var id) ? id
            : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"No contact with the key {key}.");

        var relationships = new Dictionary<Guid, RelationshipRow>();
        var coverageCount = 0;
        foreach (var c in companies)
        {
            var company = await CompanyAsync(u, tx, scope, c.Company, ct);
            var (_, relId, relWarnings) = await InsertRelationshipAsync(u, tx, company.Id, institutionId, c.CustomerNo, "ACTIVE", Date(c.StartedOn, "start date") ?? today, null, ct);
            warnings.AddRange(relWarnings);
            var rel = await RelationshipAsync(u, tx, relId, ct);
            relationships[company.PublicId] = rel;
            foreach (var cov in c.Coverage ?? [])
            {
                await InsertCoverageAsync(u, tx, rel, ContactOf(cov.ContactKey), cov.Role, cov.Rank, cov.IsPrimary == true, rel.StartedOn ?? today, null, ct);
                coverageCount++;
            }
            if (!(c.Coverage ?? []).Any(x => string.Equals(x.Role, "RM", StringComparison.OrdinalIgnoreCase)))
                warnings.Add(new { code = "W-INS-NO-RM", company = company.Name });
        }

        var productCount = 0;
        var withoutDefault = 0;
        foreach (var p in b.Products ?? [])
        {
            if (p.Company is not { } companyId || !relationships.TryGetValue(companyId, out var rel))
                throw ApiProblemException.Invalid("VALIDATION_FAILED", "A product row names one of the chosen companies.");
            long? contact = p.DefaultContactKey is null ? null : ContactOf(p.DefaultContactKey);
            await UpsertProductAsync(u, tx, rel, p.Product, contact, true, p.Channel ?? "MANUAL_FORM", null, true, rel.StartedOn ?? today, ct);
            productCount++;
            if (contact is null) withoutDefault++;
        }
        var rows = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM ins.RelationshipProduct WHERE InstitutionId = @i;",
            new { i = institutionId }, tx, cancellationToken: ct));
        if (rows != productCount) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A product is chosen once per company.");
        if (withoutDefault > 0) warnings.Add(new { code = "W-INS-NO-DEFAULT-CONTACT", count = withoutDefault });

        var summary = new { institutions = 1, relationships = relationships.Count, contacts = contacts.Count, relationshipProducts = productCount, coverage = coverageCount };
        if (b.DryRun == true)
        {
            await tx.RollbackAsync(ct);
            return Results.Ok(new { dryRun = true, summary, warnings });
        }
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/institutions/{institutionPublicId}", new
        {
            id = institutionPublicId, summary, warnings,
            relationships = relationships.Select(kv => new { company = kv.Key, relationship = kv.Value.PublicId }),
        });
    }
}

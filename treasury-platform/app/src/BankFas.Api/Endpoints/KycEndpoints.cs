using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Parties;
using BankFas.Core.Security;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record KycProfileRequest(Guid? Institution, string? NameAr, string? NameEn, string? AppliesToRole, string? AppliesToKind, decimal? OwnerThresholdPct);
public sealed record KycItemRequest(string? ItemKind, string? RefCode, JsonElement? Condition, bool? IsMandatory, int? MinValidityDays, int? MaxAgeDays, bool? RequiresImage,
    int? SortOrder, string? HelpTextAr, string? HelpTextEn);
public sealed record PackRequest(Guid? Bank, Guid? Facility, bool? Full, bool? IncludeImages);

/// <summary>
/// KYC completeness (FR-PTY-023 to 026, FR-COL-012 and 013; BR-PTY-011 to 013). A bank's profile for a role is data:
/// a DRAFT version takes its items and is activated, which retires the version before it (041). A person is checked
/// against the active profile of the bank and role, or the baseline profile (PTY.KYC) when the bank has none. The pack
/// of a guarantor is generated on request and not stored: full numbers only for a user with party.identity.reveal and
/// party.pack.export, otherwise a draft with masked numbers and a watermark; images only with the full pack and
/// party.identity.image.view; every generation is audited with its fingerprint. The pack is returned as data, and the
/// screen prints it as an Arabic RTL page (the PDF is the browser's print of that page).
/// </summary>
public static class KycEndpoints
{
    private const string View = "party.view";
    private const string ManageProfiles = "party.kyc.manage";
    private const string PackDraft = "party.pack.draft";
    private const string PackExport = "party.pack.export";
    private const string Reveal = "party.identity.reveal";
    private const string ImageView = "party.identity.image.view";
    private static readonly string[] Kinds = ["PARTY_FIELD", "IDENTITY_DOC", "DOCUMENT_TYPE", "ADDRESS_TYPE", "CONTACT_KIND", "CUSTOM_FIELD", "COMPANY_FIELD", "RELATED_PARTY_SET"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/kyc-profiles", ProfilesAsync);
        api.MapPost("/kyc-profiles", CreateProfileAsync);
        api.MapPost("/kyc-profiles/{id:guid}/items", AddItemAsync);
        api.MapPost("/kyc-profiles/{id:guid}/actions/activate", ActivateAsync);
        api.MapGet("/parties/{id:guid}/completeness", CompletenessAsync);
        api.MapPost("/parties/{id:guid}/pack", PackAsync);
        api.MapGet("/facilities/{id:guid}/guarantor-completeness", DashboardAsync);
    }

    internal sealed record Profile(long Id, Guid PublicId, string NameAr, string NameEn, int Version, bool IsBaseline, long? InstitutionId);

    /// <summary>The active profile of the bank for the role and kind (ANY counts for every role), else the baseline one.</summary>
    internal static async Task<(Profile Profile, List<KycItem> Items)?> ProfileAsync(SqlConnection c, SqlTransaction? tx, long? bank, string role, string kind, CancellationToken ct)
    {
        var p = await c.QueryFirstOrDefaultAsync<Profile>(new CommandDefinition(
            """
            SELECT KycProfileId AS Id, PublicId, NameAr, NameEn, Version, IsBaseline, InstitutionId FROM pty.KycProfile
             WHERE Status = 'ACTIVE' AND AppliesToRole IN (@role, 'ANY') AND (AppliesToKind IS NULL OR AppliesToKind = @kind)
               AND ((@bank IS NOT NULL AND InstitutionId = @bank) OR (InstitutionId IS NULL AND IsBaseline = 1))
             ORDER BY CASE WHEN InstitutionId IS NULL THEN 1 ELSE 0 END, CASE WHEN AppliesToRole = @role THEN 0 ELSE 1 END, Version DESC;
            """, new { bank, role, kind }, tx, cancellationToken: ct));
        if (p is null) return null;
        var items = await c.QueryAsync<KycItem>(new CommandDefinition(
            """
            SELECT ItemKind AS Kind, RefCode, ConditionJson, IsMandatory, MinValidityDays, MaxAgeDays, RequiresImage, SortOrder
              FROM pty.KycProfileItem WHERE ProfileId = @p ORDER BY SortOrder, KycProfileItemId;
            """, new { p = p.Id }, tx, cancellationToken: ct));
        return (p, items.ToList());
    }

    /// <summary>What completeness reads of a person: which fields hold a value, the current identity documents with their image count, addresses, contacts and custom fields.</summary>
    internal static async Task<KycFacts> FactsAsync(SqlConnection c, SqlTransaction? tx, long party, CancellationToken ct)
    {
        var p = await c.QuerySingleAsync<(string Kind, string? NameAr, string? NameEn, int? Country, bool IsGcc, string? Residency, DateTime? Birth, string? BirthPlace,
            string? Marital, string? Gender)>(new CommandDefinition(
            """
            SELECT p.Kind, p.NameAr, p.NameEn, p.CountryId, ISNULL(co.IsGcc, 0), p.ResidencyStatus, p.BirthDate, p.BirthPlace, p.MaritalStatus, p.Gender
              FROM pty.Party AS p LEFT JOIN ref.Country AS co ON co.CountryId = p.CountryId WHERE p.PartyId = @p;
            """, new { p = party }, tx, cancellationToken: ct));
        var fields = new HashSet<string>(StringComparer.Ordinal);
        void Add(string key, bool has) { if (has) fields.Add(key); }
        Add("NAME_AR", p.NameAr is not null); Add("NAME_EN", p.NameEn is not null); Add("NATIONALITY", p.Country is not null); Add("RESIDENCY", p.Residency is not null);
        Add("BIRTH_DATE", p.Birth is not null); Add("BIRTH_PLACE", !string.IsNullOrWhiteSpace(p.BirthPlace)); Add("MARITAL_STATUS", p.Marital is not null); Add("GENDER", p.Gender is not null);
        var ids = await c.QueryAsync<KycIdentity>(new CommandDefinition(
            """
            SELECT d.DocKind, d.IsPrimary, d.ExpiryDate,
                   (SELECT COUNT(*) FROM doc.DocumentLink AS l JOIN doc.Document AS x ON x.DocumentId = l.DocumentId
                     WHERE l.EntityType = 'pty.IdentityDocument' AND l.EntityId = d.IdentityDocumentId AND l.UnlinkedAt IS NULL AND x.Status = 'ACTIVE') AS ImageCount
              FROM pty.IdentityDocument AS d WHERE d.PartyId = @p AND d.IsSuperseded = 0 ORDER BY d.IsPrimary DESC, d.IdentityDocumentId DESC;
            """, new { p = party }, tx, cancellationToken: ct));
        var addresses = await c.QueryAsync<string>(new CommandDefinition("SELECT DISTINCT AddressType FROM pty.Address WHERE PartyId = @p AND IsCurrent = 1;", new { p = party }, tx,
            cancellationToken: ct));
        var contacts = await c.QueryAsync<string>(new CommandDefinition("SELECT DISTINCT Kind FROM pty.ContactMethod WHERE PartyId = @p;", new { p = party }, tx, cancellationToken: ct));
        var custom = await c.QueryAsync<string>(new CommandDefinition(
            """
            SELECT d.FieldKey FROM pty.PartyCustomField AS v JOIN pty.CustomFieldDefinition AS d ON d.CustomFieldDefinitionId = v.DefinitionId
             WHERE v.PartyId = @p AND (NULLIF(LTRIM(RTRIM(v.ValueText)), N'') IS NOT NULL OR v.ValueEnc IS NOT NULL);
            """, new { p = party }, tx, cancellationToken: ct));
        var documents = (await c.QueryAsync<(string Type, DateTime On)>(new CommandDefinition(
            """
            SELECT t.Code, ISNULL(x.IssueDate, CAST(x.CreatedAt AS DATE)) FROM doc.DocumentLink AS l JOIN doc.Document AS x ON x.DocumentId = l.DocumentId
              JOIN cat.DocumentType AS t ON t.DocumentTypeId = x.DocumentTypeId
             WHERE l.EntityType = 'pty.Party' AND l.EntityId = @p AND l.UnlinkedAt IS NULL AND x.Status = 'ACTIVE';
            """, new { p = party }, tx, cancellationToken: ct))).GroupBy(d => d.Type).ToDictionary(g => g.Key, g => g.Max(d => d.On), StringComparer.Ordinal);
        return new KycFacts(p.Kind, p.IsGcc, p.Residency, fields, [.. ids], addresses.ToHashSet(StringComparer.Ordinal), contacts.ToHashSet(StringComparer.Ordinal),
            custom.ToHashSet(StringComparer.Ordinal), documents);
    }

    internal static async Task<(Profile Profile, KycResult Result)?> EvaluateAsync(SqlConnection c, SqlTransaction? tx, long party, long? bank, string role, DateTime today,
        CancellationToken ct)
    {
        var facts = await FactsAsync(c, tx, party, ct);
        var profile = await ProfileAsync(c, tx, bank, role, facts.PartyKind, ct);
        return profile is { } p ? (p.Profile, Completeness.Evaluate(p.Items, facts, today)) : null;
    }

    private static object ResultShape(Profile p, KycResult r) => new
    {
        profile = new { id = p.PublicId, nameAr = p.NameAr, nameEn = p.NameEn, version = p.Version, baseline = p.IsBaseline },
        applicable = r.Applicable, done = r.Done, pct = r.Pct, ready = r.Ready, nearestExpiry = FacilityEndpoints.D(r.NearestExpiry),
        warnings = r.Items.Where(i => i.Status == "EXPIRING_SOON").Select(i => new { kind = i.Item.Kind, refCode = i.Item.RefCode, expiryDate = FacilityEndpoints.D(i.ExpiryDate) }),
        items = r.Items.Select(i => new
        {
            kind = i.Item.Kind, refCode = i.Item.RefCode, mandatory = i.Item.IsMandatory, status = i.Status, reason = i.Reason, expiryDate = FacilityEndpoints.D(i.ExpiryDate),
        }),
    };

    private static async Task<long?> BankAsync(BoundUser u, Guid? bank, CancellationToken ct) =>
        bank is null ? null
        : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @b;", new { b = bank }, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank is not an institution of the account.");

    private static async Task<(long Id, long? Mirror)> PartyAsync(BoundUser u, Guid id, CancellationToken ct)
    {
        var p = await u.Connection.QuerySingleOrDefaultAsync<(long Id, long? Mirror)?>(new CommandDefinition(
            "SELECT p.PartyId, c.CompanyId FROM pty.Party AS p LEFT JOIN org.Company AS c ON c.PartyId = p.PartyId WHERE p.PublicId = @p;", new { p = id }, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        if (p.Mirror is not null && !(await CompanyScope.OfAsync(u, ct)).Allows(p.Mirror)) throw ApiProblemException.NotFound();
        return p;
    }

    // ---------- profiles (FR-PTY-023) ----------

    private static async Task<IResult> ProfilesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var profiles = (await u.Connection.QueryAsync<(long Id, Guid PublicId, Guid? Bank, string? BankCode, string NameAr, string NameEn, string Role, string? Kind, int Version,
            string Status, bool IsBaseline)>(new CommandDefinition(
            """
            SELECT p.KycProfileId, p.PublicId, i.PublicId, i.Code, p.NameAr, p.NameEn, p.AppliesToRole, p.AppliesToKind, p.Version, p.Status, p.IsBaseline
              FROM pty.KycProfile AS p LEFT JOIN ins.Institution AS i ON i.InstitutionId = p.InstitutionId
             ORDER BY CASE WHEN p.InstitutionId IS NULL THEN 0 ELSE 1 END, i.Code, p.AppliesToRole, p.Version DESC;
            """, cancellationToken: ct))).ToList();
        var items = (await u.Connection.QueryAsync<(long Profile, string Kind, string RefCode, string? Condition, bool Mandatory, int? MinValidity, int? MaxAge, bool Image, int Sort,
            string? HelpAr, string? HelpEn)>(new CommandDefinition(
            """
            SELECT ProfileId, ItemKind, RefCode, ConditionJson, IsMandatory, MinValidityDays, MaxAgeDays, RequiresImage, SortOrder, HelpTextAr, HelpTextEn
              FROM pty.KycProfileItem ORDER BY SortOrder, KycProfileItemId;
            """, cancellationToken: ct))).ToLookup(i => i.Profile);
        return Results.Ok(new
        {
            items = profiles.Select(p => new
            {
                id = p.PublicId, bank = p.Bank is null ? null : new { id = p.Bank, code = p.BankCode }, nameAr = p.NameAr, nameEn = p.NameEn, appliesToRole = p.Role, appliesToKind = p.Kind,
                version = p.Version, status = p.Status, baseline = p.IsBaseline,
                items = items[p.Id].Select(i => new
                {
                    kind = i.Kind, refCode = i.RefCode, condition = i.Condition is null ? (JsonElement?)null : JsonSerializer.Deserialize<JsonElement>(i.Condition), mandatory = i.Mandatory,
                    minValidityDays = i.MinValidity, maxAgeDays = i.MaxAge, requiresImage = i.Image, sortOrder = i.Sort, helpTextAr = i.HelpAr, helpTextEn = i.HelpEn,
                }),
            }),
        });
    }

    /// <summary>A new DRAFT version of the profile of a bank (or the baseline) for a role and kind.</summary>
    private static async Task<IResult> CreateProfileAsync(KycProfileRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var role = b.AppliesToRole?.ToUpperInvariant();
        var kind = b.AppliesToKind?.ToUpperInvariant();
        if (string.IsNullOrWhiteSpace(b.NameAr) || string.IsNullOrWhiteSpace(b.NameEn) || role is not ("GUARANTOR" or "SHAREHOLDER" or "SIGNATORY" or "ANY")
            || kind is not (null or "INDIVIDUAL" or "ORGANIZATION"))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the Arabic and English names, the role (GUARANTOR, SHAREHOLDER, SIGNATORY or ANY) and the kind.");
        if (b.OwnerThresholdPct is <= 0 or > 100) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The owner threshold is above 0 and at most 100.");
        await using var u = await BoundUser.OpenAsync(http, db, ManageProfiles);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, ct);
        long? bank = b.Institution is null ? null : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @b;",
            new { b = b.Institution }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank is not an institution of the account.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM pty.KycProfile WHERE (InstitutionId = @b OR (InstitutionId IS NULL AND @b IS NULL)) AND AppliesToRole = @role AND (AppliesToKind = @kind OR (AppliesToKind IS NULL AND @kind IS NULL)) AND Status = 'DRAFT';",
                new { b = bank, role, kind }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-KYC-DRAFT-EXISTS", "This profile already has a draft version.");
        var version = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT ISNULL(MAX(Version), 0) + 1 FROM pty.KycProfile WHERE (InstitutionId = @b OR (InstitutionId IS NULL AND @b IS NULL)) AND AppliesToRole = @role AND (AppliesToKind = @kind OR (AppliesToKind IS NULL AND @kind IS NULL));",
            new { b = bank, role, kind }, tx, cancellationToken: ct));
        var (id, publicId) = await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT pty.KycProfile (TenantId, InstitutionId, NameAr, NameEn, AppliesToRole, AppliesToKind, Version, Status, IsBaseline, OwnerThresholdPct, CreatedBy)
            OUTPUT inserted.KycProfileId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @b, @ar, @en, @role, @kind, @v, 'DRAFT', @baseline, @owner, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new { b = bank, ar = b.NameAr.Trim(), en = b.NameEn.Trim(), role, kind, v = version, baseline = bank is null, owner = b.OwnerThresholdPct }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("KYC_PROFILE_CREATED", "CONFIG", "pty.KycProfile", id,
            AfterJson: JsonSerializer.Serialize(new { bank = b.Institution, role, kind, version })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/kyc-profiles/{publicId}", new { id = publicId, version });
    }

    private static async Task<IResult> AddItemAsync(Guid id, KycItemRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var kind = b.ItemKind?.ToUpperInvariant();
        if (kind is null || !Kinds.Contains(kind) || string.IsNullOrWhiteSpace(b.RefCode))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the kind of the item and the code it checks.");
        if (b.MinValidityDays is < 0 || b.MaxAgeDays is <= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The minimum validity is from 0 days and the maximum age above 0.");
        string? condition = null;
        if (b.Condition is { ValueKind: JsonValueKind.Object } c)
        {
            condition = c.GetRawText();
            foreach (var p in c.EnumerateObject())
                if (p.Name is not ("kind" or "nationality" or "residency")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A condition names kind, nationality or residency.");
        }
        await using var u = await BoundUser.OpenAsync(http, db, ManageProfiles);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var (profile, status) = await u.Connection.QuerySingleOrDefaultAsync<(long, string)?>(new CommandDefinition(
            "SELECT KycProfileId, Status FROM pty.KycProfile WITH (UPDLOCK) WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (status != "DRAFT") throw new ApiProblemException(409, "APPROVED_FINAL", "The items of an active or retired profile do not change; create a new version.");
        var code = b.RefCode.Trim().ToUpperInvariant();
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM pty.KycProfileItem WHERE ProfileId = @p AND ItemKind = @k AND RefCode = @c;",
                new { p = profile, k = kind, c = code }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-KYC-ITEM-EXISTS", "The profile already has this item.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT pty.KycProfileItem (TenantId, ProfileId, ItemKind, RefCode, ConditionJson, IsMandatory, MinValidityDays, MaxAgeDays, RequiresImage, SortOrder, HelpTextAr, HelpTextEn, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @p, @k, @c, @cond, @m, @min, @age, @img, @sort, @ar, @en, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new
            {
                p = profile, k = kind, c = code, cond = condition, m = b.IsMandatory ?? true, min = b.MinValidityDays, age = b.MaxAgeDays, img = b.RequiresImage ?? false,
                sort = b.SortOrder ?? 0, ar = b.HelpTextAr, en = b.HelpTextEn,
            }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>The draft becomes the active version; the active one before it of the same bank, role and kind is retired (041).</summary>
    private static async Task<IResult> ActivateAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, ManageProfiles);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, ct);
        var p = await u.Connection.QuerySingleOrDefaultAsync<(long Id, long? Bank, string Role, string? Kind, string Status)?>(new CommandDefinition(
            "SELECT KycProfileId, InstitutionId, AppliesToRole, AppliesToKind, Status FROM pty.KycProfile WITH (UPDLOCK) WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct)) is { } found
            ? found : throw ApiProblemException.NotFound();
        if (p.Status != "DRAFT") throw new ApiProblemException(409, "V-KYC-STATE", "Only a draft profile is activated.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM pty.KycProfileItem WHERE ProfileId = @p;", new { p = p.Id }, tx,
                cancellationToken: ct)) == 0)
            throw ApiProblemException.Invalid("V-KYC-EMPTY", "A profile without items is not activated.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            DECLARE @me BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
            UPDATE pty.KycProfile SET Status = 'RETIRED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me
             WHERE Status = 'ACTIVE' AND (InstitutionId = @b OR (InstitutionId IS NULL AND @b IS NULL)) AND AppliesToRole = @role
               AND (AppliesToKind = @kind OR (AppliesToKind IS NULL AND @kind IS NULL));
            UPDATE pty.KycProfile SET Status = 'ACTIVE', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me WHERE KycProfileId = @p;
            """, new { p = p.Id, b = p.Bank, role = p.Role, kind = p.Kind }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("KYC_PROFILE_ACTIVATED", "CONFIG", "pty.KycProfile", p.Id), null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- completeness (FR-PTY-024, 025) ----------

    private static async Task<IResult> CompletenessAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "bank", "role");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var (party, _) = await PartyAsync(u, id, ct);
        var bank = await BankAsync(u, Guid.TryParse(http.Request.Query["bank"], out var g) ? g : null, ct);
        var role = http.Request.Query["role"].ToString() is { Length: > 0 } r ? r.ToUpperInvariant() : "GUARANTOR";
        var result = await EvaluateAsync(u.Connection, null, party, bank, role, clock.GetUtcNow().UtcDateTime.Date, ct)
            ?? throw new ApiProblemException(409, "V-KYC-NO-PROFILE", "There is no active profile for this role, and no baseline profile.");
        return Results.Ok(ResultShape(result.Profile, result.Result));
    }

    /// <summary>FR-PTY-025: the guarantors of a facility against its lead bank's profile, the least complete first.</summary>
    private static async Task<IResult> DashboardAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, CollateralEndpoints.View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, ct);
        var bank = await LeadBankAsync(u.Connection, null, f.FacilityId, f.ApprovedRevisionNo, ct);
        var guarantors = await u.Connection.QueryAsync<(long Party, Guid PublicId, string? NameAr, string? NameEn)>(new CommandDefinition(
            """
            SELECT DISTINCT g.GuarantorPartyId, p.PublicId, p.NameAr, p.NameEn
              FROM col.CollateralLink AS l
              JOIN col.Collateral AS k ON k.RootId = l.CollateralId AND k.ApprovalState = 'APPROVED' AND k.Status = 'ACTIVE'
              JOIN col.Guarantee AS g ON g.CollateralId = k.CollateralId JOIN pty.Party AS p ON p.PartyId = g.GuarantorPartyId
             WHERE l.FacilityId = @f AND l.FromRevision <= @rev AND (l.ToRevision IS NULL OR l.ToRevision > @rev) AND l.UnlinkedOn IS NULL;
            """, new { f = f.FacilityId, rev = f.ApprovedRevisionNo }, cancellationToken: ct));
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var rows = new List<(Guid Id, string? NameAr, string? NameEn, decimal? Pct, bool Ready, DateTime? Nearest)>();
        foreach (var g in guarantors)
        {
            var r = await EvaluateAsync(u.Connection, null, g.Party, bank, "GUARANTOR", today, ct);
            rows.Add((g.PublicId, g.NameAr, g.NameEn, r?.Result.Pct, r?.Result.Ready ?? false, r?.Result.NearestExpiry));
        }
        return Results.Ok(new
        {
            items = rows.OrderBy(r => r.Pct ?? 0).ThenBy(r => r.Nearest ?? DateTime.MaxValue)
                .Select(r => new { party = r.Id, nameAr = r.NameAr, nameEn = r.NameEn, pct = r.Pct, ready = r.Ready, nearestExpiry = FacilityEndpoints.D(r.Nearest) }),
        });
    }

    /// <summary>The lead lender of a revision: the sole, lead or agent bank, else the first.</summary>
    internal static Task<long?> LeadBankAsync(SqlConnection c, SqlTransaction? tx, long facility, int rev, CancellationToken ct) =>
        c.ExecuteScalarAsync<long?>(new CommandDefinition(
            """
            SELECT TOP (1) InstitutionId FROM fac.FacilityLender
             WHERE FacilityId = @f AND (@rev = 2147483647 AND ToRevision IS NULL OR @rev < 2147483647 AND FromRevision <= @rev AND (ToRevision IS NULL OR ToRevision > @rev))
             ORDER BY CASE WHEN Roles LIKE '%SOLE%' OR Roles LIKE '%LEAD%' OR Roles LIKE '%AGENT%' THEN 0 ELSE 1 END, FacilityLenderId;
            """, new { f = facility, rev }, tx, cancellationToken: ct));

    // ---------- the guarantor pack (FR-PTY-026, BR-PTY-011, BR-COL-007) ----------

    private static async Task<IResult> PackAsync(Guid id, PackRequest b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var perms = await u.PermissionsAsync(ct);
        if (!perms.Contains(PackDraft) && !perms.Contains(PackExport)) throw ApiProblemException.Forbidden();
        var (party, mirror) = await PartyAsync(u, id, ct);
        long? bank = await BankAsync(u, b.Bank, ct);
        Guid? facility = null;
        if (b.Facility is { } fid)
        {
            var scope = await CompanyScope.OfAsync(u, ct);
            var f = await FacilityEndpoints.FindAsync(u, null, fid, scope, ct);
            bank ??= await LeadBankAsync(u.Connection, null, f.FacilityId, f.ApprovedRevisionNo, ct);
            facility = f.PublicId;
        }
        // BR-PTY-011: the full pack needs both permissions; without them the request gets the masked draft, not a refusal.
        var full = b.Full == true && perms.Contains(Reveal) && perms.Contains(PackExport);
        var images = full && b.IncludeImages == true && perms.Contains(ImageView);
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var check = await EvaluateAsync(u.Connection, null, party, bank, "GUARANTOR", today, ct);
        var p = await u.Connection.QuerySingleAsync(new CommandDefinition(
            """
            SELECT p.PartyCode, p.Kind, p.NameAr, p.NameEn, c.NameAr AS CountryAr, c.NameEn AS CountryEn, p.ResidencyStatus, p.BirthDate, p.BirthDateHijriText, p.BirthPlace,
                   p.MaritalStatus, p.Gender
              FROM pty.Party AS p LEFT JOIN ref.Country AS c ON c.CountryId = p.CountryId WHERE p.PartyId = @p;
            """, new { p = party }, cancellationToken: ct));
        var docs = (await u.Connection.QueryAsync<(long Id, Guid PublicId, string DocKind, string Country, string Mask, byte[] Enc, long KeyId, DateTime? Issue, DateTime? Expiry, bool Primary)>(
            new CommandDefinition(
                """
                SELECT d.IdentityDocumentId, d.PublicId, d.DocKind, c.Iso2, d.NumberMask, d.NumberEnc, d.EncKeyId, d.IssueDate, d.ExpiryDate, d.IsPrimary
                  FROM pty.IdentityDocument AS d JOIN ref.Country AS c ON c.CountryId = d.IssuingCountryId
                 WHERE d.PartyId = @p AND d.IsSuperseded = 0 ORDER BY d.IsPrimary DESC, d.IdentityDocumentId;
                """, new { p = party }, cancellationToken: ct))).ToList();
        var imageRows = images
            ? (await u.Connection.QueryAsync<(long Owner, Guid Document, string Role)>(new CommandDefinition(
                """
                SELECT l.EntityId, x.PublicId, l.LinkRole FROM doc.DocumentLink AS l JOIN doc.Document AS x ON x.DocumentId = l.DocumentId
                 WHERE l.EntityType = 'pty.IdentityDocument' AND l.UnlinkedAt IS NULL AND x.Status = 'ACTIVE' AND l.EntityId IN @ids;
                """, new { ids = docs.Select(d => d.Id).DefaultIfEmpty(-1).ToArray() }, cancellationToken: ct))).ToLookup(i => i.Owner)
            : null;
        var identity = new List<object>();
        foreach (var d in docs)
        {
            string number = d.Mask;
            if (full)
            {
                var key = await keys.ByIdAsync(u.Connection, null, u.TenantId, d.KeyId, ct);
                number = Encoding.UTF8.GetString(Envelope.Open(key, d.Enc, EnvelopeAad.ForColumn(u.TenantId, "pty.IdentityDocument", "NumberEnc", d.PublicId)));
            }
            identity.Add(new
            {
                docKind = d.DocKind, issuingCountry = d.Country, number, issueDate = FacilityEndpoints.D(d.Issue), expiryDate = FacilityEndpoints.D(d.Expiry), isPrimary = d.Primary,
                images = imageRows?[d.Id].Select(i => new { document = i.Document, side = i.Role }),
            });
        }
        var addresses = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT a.AddressType AS type, c.Iso2 AS country, a.City AS city, a.District AS district, a.Street AS street, a.BuildingNumber AS building, a.PostalCode AS postalCode,
                   a.AdditionalNumber AS additionalNumber, a.ShortCode AS shortCode, a.PoBoxNumber AS poBox
              FROM pty.Address AS a JOIN ref.Country AS c ON c.CountryId = a.CountryId WHERE a.PartyId = @p AND a.IsCurrent = 1 ORDER BY a.IsPrimary DESC, a.AddressId;
            """, new { p = party }, cancellationToken: ct));
        var contacts = await u.Connection.QueryAsync(new CommandDefinition(
            "SELECT Kind AS kind, Value AS value, Label AS label FROM pty.ContactMethod WHERE PartyId = @p ORDER BY IsPrimary DESC, ContactMethodId;", new { p = party },
            cancellationToken: ct));
        var custom = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT d.FieldKey AS [key], d.LabelAr AS labelAr, d.LabelEn AS labelEn, CASE WHEN d.Sensitivity = 'RESTRICTED' THEN v.ValueMask ELSE v.ValueText END AS value
              FROM pty.PartyCustomField AS v JOIN pty.CustomFieldDefinition AS d ON d.CustomFieldDefinitionId = v.DefinitionId WHERE v.PartyId = @p ORDER BY d.FieldKey;
            """, new { p = party }, cancellationToken: ct));
        var pack = new
        {
            kind = full ? "FULL" : "DRAFT", watermark = full ? null : "DRAFT_MASKED", generatedAt = clock.GetUtcNow().UtcDateTime, facility,
            party = new
            {
                code = (string)p.PartyCode, kind = (string)p.Kind, nameAr = (string?)p.NameAr, nameEn = (string?)p.NameEn, nationalityAr = (string?)p.CountryAr,
                nationalityEn = (string?)p.CountryEn, residency = (string?)p.ResidencyStatus, birthDate = FacilityEndpoints.D((DateTime?)p.BirthDate),
                birthDateHijri = (string?)p.BirthDateHijriText, birthPlace = (string?)p.BirthPlace, maritalStatus = (string?)p.MaritalStatus, gender = (string?)p.Gender,
            },
            completeness = check is { } c ? ResultShape(c.Profile, c.Result) : null,
            identityDocuments = identity, addresses, contacts, customFields = custom,
        };
        var json = JsonSerializer.Serialize(pack);
        var fingerprint = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json))).ToLowerInvariant();
        await AuditWriter.SensitiveAccessAsync(u.Connection, null, "PACK_EXPORT", "PARTY_PACK_GENERATED", "pty.Party", party, party, mirror, true, null,
            string.Create(CultureInfo.InvariantCulture,
                $"{(full ? "FULL" : "DRAFT")} profile {(check is { } x ? $"{x.Profile.PublicId} v{x.Profile.Version}" : "none")} images={images} sha256={fingerprint}"),
            http.Request.Headers.UserAgent.ToString(), ct);
        http.Response.Headers.CacheControl = "no-store";
        return Results.Ok(new { pack, fingerprint });
    }
}

using System.Data;
using System.Globalization;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record AuthorityGrantRequest(string? GranteeKind, Guid? Body, string? Member, Guid? Party, string? PowerType, Guid? Institution, decimal? CeilingAmount,
    string? CeilingCurrency, bool? RequiresJoint, int? JointMinSignatories, string? JointNote, string? ValidFrom, string? ValidFromHijri, string? ValidTo,
    Guid? SourceDocument, string? SourcePage, string? ExceptionReason);
public sealed record GrantReasonRequest(string? Reason, string? On);

/// <summary>
/// Authority grants (FR-ORG-023 to 029, BR-ORG-011 to 014; screens 14, 17 and 20 of spec 10). A grant goes DRAFT, then
/// PENDING_APPROVAL, then ACTIVE on the approval of another user; without segregation of duties (the tenant setting)
/// a DRAFT may be activated directly and the activator is recorded. Activation needs the source document or a
/// documented exception, which only a treasury manager other than the creator approves (owner default OQ-15). REVOKED
/// and SUPERSEDED are final; a substantive change of an active grant (ceiling, period, power type, bank, grantee or
/// joint rule) is a new grant that supersedes it on approval (BR-ORG-014, OQ-6; guarded by 061). "Expired" and
/// "expiring" are derived, never stored. The query of FR-ORG-025 answers who may act for an amount on a date: single
/// grants first, then joint ones with their condition; a different currency is returned for manual review, never
/// converted; joint ceilings are never added up (BR-ORG-012).
/// </summary>
public static class GrantEndpoints
{
    private const string View = "org.company.view";
    private const string Create = "org.grant.create";
    private const string Approve = "org.grant.approve";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/companies/{id:guid}/grants", ListAsync);
        api.MapPost("/companies/{id:guid}/grants", CreateAsync);
        api.MapGet("/grants/{id:guid}", GetAsync);
        api.MapPatch("/grants/{id:guid}", PatchAsync);
        api.MapPost("/grants/{id:guid}/actions/submit", SubmitAsync);
        api.MapPost("/grants/{id:guid}/actions/activate", ActivateAsync);
        api.MapPost("/grants/{id:guid}/actions/approve", ApproveAsync);
        api.MapPost("/grants/{id:guid}/actions/reject", RejectAsync);
        api.MapPost("/grants/{id:guid}/actions/revoke", RevokeAsync);
        api.MapPost("/grants/{id:guid}/actions/supersede", SupersedeAsync);
        api.MapGet("/companies/{id:guid}/grants/query", QueryAsync);
        api.MapGet("/parties/{id:guid}/grants", HolderAsync);
        api.MapGet("/companies/{id:guid}/authority-matrix", MatrixAsync);
        api.MapGet("/reports/structure-integrity", IntegrityAsync);
    }

    internal sealed class GrantRow
    {
        public long AuthorityGrantId { get; init; }
        public Guid PublicId { get; init; }
        public long CompanyId { get; init; }
        public string GranteeKind { get; init; } = "";
        public long? BodyId { get; init; }
        public long? BodyMemberId { get; init; }
        public long? PartyId { get; init; }
        public long? HolderPartyId { get; init; }
        public Guid? HolderId { get; init; }
        public string? HolderNameAr { get; init; }
        public string? HolderNameEn { get; init; }
        public Guid? BodyPublicId { get; init; }
        public string? BodyType { get; init; }
        public string? BodyStatus { get; init; }
        public string? PositionCode { get; init; }
        public DateTime? MemberStart { get; init; }
        public DateTime? MemberEnd { get; init; }
        public DateTime? MemberResigned { get; init; }
        public int PowerTypeId { get; init; }
        public string PowerTypeCode { get; init; } = "";
        public string PowerTypeNameAr { get; init; } = "";
        public string? PowerTypeNameEn { get; init; }
        public bool AllowsCeiling { get; init; }
        public long? InstitutionId { get; init; }
        public Guid? InstitutionPublicId { get; init; }
        public string? InstitutionCode { get; init; }
        public decimal? CeilingAmount { get; init; }
        public int? CeilingCurrencyId { get; init; }
        public string? CeilingCurrency { get; init; }
        public bool RequiresJoint { get; init; }
        public int? JointMinSignatories { get; init; }
        public string? JointNote { get; init; }
        public DateTime ValidFrom { get; init; }
        public string? ValidFromHijriText { get; init; }
        public DateTime? ValidTo { get; init; }
        public string Status { get; init; } = "";
        public long? CreatedBy { get; init; }
        public long? ApprovedBy { get; init; }
        public DateTime? ApprovedAt { get; init; }
        public DateTime? RevokedAt { get; init; }
        public string? RevokedReason { get; init; }
        public long? SourceDocumentId { get; init; }
        public Guid? SourceDocument { get; init; }
        public string? SourcePage { get; init; }
        public string? ExceptionReason { get; init; }
        public long? SupersedesGrantId { get; init; }
        public Guid? Supersedes { get; init; }
        public byte[] RowVersion { get; init; } = [];
    }

    /// <summary>The holder of a grant is the party, the member's party, or the body itself (a body's grant is never a person's, FR-ORG-025).</summary>
    internal const string Select =
        """
        SELECT g.AuthorityGrantId, g.PublicId, g.CompanyId, g.GranteeKind, g.BodyId, g.BodyMemberId, g.PartyId,
               COALESCE(g.PartyId, m.PartyId) AS HolderPartyId, hp.PublicId AS HolderId, COALESCE(hp.NameAr, gb.NameAr, mb.NameAr) AS HolderNameAr,
               COALESCE(hp.NameEn, gb.NameEn, mb.NameEn) AS HolderNameEn, COALESCE(gb.PublicId, mb.PublicId) AS BodyPublicId, COALESCE(gb.BodyType, mb.BodyType) AS BodyType,
               COALESCE(gb.Status, mb.Status) AS BodyStatus, pos.Code AS PositionCode, m.TermStart AS MemberStart, m.TermEnd AS MemberEnd, m.ResignedOn AS MemberResigned,
               g.PowerTypeId, pt.Code AS PowerTypeCode, pt.NameAr AS PowerTypeNameAr, pt.NameEn AS PowerTypeNameEn, pt.AllowsCeiling,
               g.InstitutionId, i.PublicId AS InstitutionPublicId, i.Code AS InstitutionCode, g.CeilingAmount, g.CeilingCurrencyId, cu.Code AS CeilingCurrency,
               g.RequiresJoint, g.JointMinSignatories, g.JointNote, g.ValidFrom, g.ValidFromHijriText, g.ValidTo, g.Status, g.CreatedBy, g.ApprovedBy, g.ApprovedAt,
               g.RevokedAt, g.RevokedReason, g.SourceDocumentId, d.PublicId AS SourceDocument, g.SourcePage, g.ExceptionReason, g.SupersedesGrantId,
               sg.PublicId AS Supersedes, g.RowVersion
          FROM org.AuthorityGrant AS g
          JOIN cat.PowerType AS pt ON pt.PowerTypeId = g.PowerTypeId
          LEFT JOIN org.BodyMember AS m ON m.BodyMemberId = g.BodyMemberId
          LEFT JOIN cat.Position AS pos ON pos.PositionId = m.PositionId
          LEFT JOIN pty.Party AS hp ON hp.PartyId = COALESCE(g.PartyId, m.PartyId)
          LEFT JOIN org.GoverningBody AS gb ON gb.GoverningBodyId = g.BodyId
          LEFT JOIN org.GoverningBody AS mb ON mb.GoverningBodyId = m.BodyId
          LEFT JOIN ins.Institution AS i ON i.InstitutionId = g.InstitutionId
          LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = g.CeilingCurrencyId
          LEFT JOIN doc.Document AS d ON d.DocumentId = g.SourceDocumentId
          LEFT JOIN org.AuthorityGrant AS sg ON sg.AuthorityGrantId = g.SupersedesGrantId
        """;

    private static string D(DateTime d) => GovernanceEndpoints.D(d);

    /// <summary>BR-ORG-011: effective on the date when active, within its dates, and (for a member) the member active that day.</summary>
    internal static bool EffectiveOn(GrantRow g, DateTime d) =>
        g.Status == "ACTIVE" && g.ValidFrom <= d && (g.ValidTo is null || g.ValidTo >= d)
        && (g.GranteeKind != "BODY_MEMBER" || (g.MemberStart <= d && (g.MemberEnd is null || g.MemberEnd >= d) && (g.MemberResigned is null || g.MemberResigned > d)));

    /// <summary>The derived state shown on screens (never stored, BR-ORG-011): expired, expiring within 60 days, the holder left the position.</summary>
    internal static string Derived(GrantRow g, DateTime today) =>
        g.Status != "ACTIVE" ? g.Status
        : g.ValidFrom > today ? "NOT_YET_VALID"
        : g.ValidTo is { } t && t < today ? "EXPIRED"
        : g.GranteeKind == "BODY_MEMBER" && !EffectiveOn(g, today) ? "HOLDER_LEFT"
        : g.GranteeKind == "BODY" && g.BodyStatus == "CLOSED" ? "BODY_CLOSED"
        : g.ValidTo is { } s && (s - today).Days <= 60 ? "EXPIRING"
        : "ACTIVE";

    private static object Shape(GrantRow g, DateTime today, long? viewer) => new
    {
        id = g.PublicId, granteeKind = g.GranteeKind,
        holder = new { party = g.HolderId, nameAr = g.HolderNameAr, nameEn = g.HolderNameEn, body = g.BodyPublicId, bodyType = g.BodyType, position = g.PositionCode },
        powerType = new { code = g.PowerTypeCode, nameAr = g.PowerTypeNameAr, nameEn = g.PowerTypeNameEn },
        institution = g.InstitutionPublicId is null ? null : new { id = g.InstitutionPublicId, code = g.InstitutionCode },
        ceiling = g.CeilingAmount is null ? null : new { amount = g.CeilingAmount, currency = g.CeilingCurrency },
        requiresJoint = g.RequiresJoint, jointMinSignatories = g.JointMinSignatories, jointNote = g.JointNote,
        validFrom = D(g.ValidFrom), validFromHijri = g.ValidFromHijriText, validTo = g.ValidTo is { } t ? D(t) : null,
        status = g.Status, state = Derived(g, today), approvedAt = g.ApprovedAt, revokedAt = g.RevokedAt, revokedReason = g.RevokedReason,
        sourceDocument = g.SourceDocument, sourcePage = g.SourcePage, exceptionReason = g.ExceptionReason, supersedes = g.Supersedes,
        // FR-ORG-026: the creator does not see the approval of their own grant.
        createdByYou = viewer is not null && g.CreatedBy == viewer,
        etag = ETags.Of(g.RowVersion),
    };

    private static async Task<GrantRow> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct)
    {
        var g = await u.Connection.QuerySingleOrDefaultAsync<GrantRow>(new CommandDefinition(Select + " WHERE g.PublicId = @id;", new { id }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        return scope.Allows(g.CompanyId) ? g : throw ApiProblemException.NotFound();
    }

    private static async Task<bool> SegregationAsync(BoundUser u, SqlTransaction tx, CancellationToken ct) =>
        await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition(
            "SELECT ISNULL(t.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key] WHERE d.[Key] = 'org.grant.segregation_of_duties';",
            transaction: tx, cancellationToken: ct)) != "false";

    // ---------- reading ----------

    private static async Task<IResult> ListAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "status");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var company = await CompanyEndpoints.FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var status = http.Request.Query["status"].ToString() is { Length: > 0 } s ? s.ToUpperInvariant() : null;
        var rows = await u.Connection.QueryAsync<GrantRow>(new CommandDefinition(
            Select + " WHERE g.CompanyId = @c AND (@s IS NULL OR g.Status = @s) ORDER BY pt.SortOrder, g.ValidFrom DESC;", new { c = company.CompanyId, s = status },
            cancellationToken: http.RequestAborted));
        var today = GovernanceEndpoints.Today(clock);
        return Results.Ok(new { items = rows.Select(g => Shape(g, today, u.UserId)) });
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var g = await FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        ETags.Set(http.Response, g.RowVersion);
        return Results.Ok(Shape(g, GovernanceEndpoints.Today(clock), u.UserId));
    }

    // ---------- writing ----------

    private sealed record Resolved(string Kind, long? BodyId, long? MemberId, long? PartyId, int PowerTypeId, long? InstitutionId, decimal? Ceiling, int? CurrencyId,
        bool Joint, int? JointMin, string? JointNote, DateTime From, string? FromHijri, DateTime? To, long? DocumentId, string? Page, string? Exception);

    /// <summary>The grant as asked, its references resolved and the rules the database does not see checked (BR-ORG-011 to 013).</summary>
    private static async Task<Resolved> ResolveAsync(BoundUser u, SqlTransaction tx, long companyId, AuthorityGrantRequest b, OpaqueRefs refs, CancellationToken ct)
    {
        var kind = b.GranteeKind?.Trim().ToUpperInvariant();
        long? body = null, member = null, party = null;
        switch (kind)
        {
            case "BODY":
                body = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                    "SELECT GoverningBodyId FROM org.GoverningBody WHERE PublicId = @b AND CompanyId = @c AND Status = 'ACTIVE';", new { b = b.Body, c = companyId }, tx,
                    cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-ORG-GRANTEE", "The body is not an active body of this company.");
                break;
            case "BODY_MEMBER":
                var mid = refs.ItemId(u.TenantId, "body-member", b.Member) ?? throw ApiProblemException.Invalid("V-ORG-GRANTEE", "Choose the member.");
                member = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                    "SELECT BodyMemberId FROM org.BodyMember WHERE BodyMemberId = @m AND CompanyId = @c;", new { m = mid, c = companyId }, tx, cancellationToken: ct))
                    ?? throw ApiProblemException.Invalid("V-ORG-GRANTEE", "The member is not a member of a body of this company.");
                break;
            case "PARTY":
                party = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                    "SELECT PartyId FROM pty.Party WHERE PublicId = @p AND IsActive = 1;", new { p = b.Party }, tx, cancellationToken: ct))
                    ?? throw ApiProblemException.Invalid("V-ORG-GRANTEE", "The holder is not an active party.");
                break;
            default:
                throw ApiProblemException.Invalid("V-ORG-GRANTEE", "The grantee is a body, a member of a body, or a person or entity by power of attorney.");
        }
        var pt = await u.Connection.QuerySingleOrDefaultAsync<(int Id, bool AllowsCeiling, bool Active)>(new CommandDefinition(
            "SELECT PowerTypeId, AllowsCeiling, IsActive FROM cat.PowerType WHERE Code = @c;", new { c = b.PowerType?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct));
        if (pt.Id == 0 || !pt.Active) throw ApiProblemException.Invalid("V-ORG-POWER-TYPE", "The power type is not an active type of the catalogue.");
        if (b.CeilingAmount is not null && !pt.AllowsCeiling) throw ApiProblemException.Invalid("V-ORG-CEILING", "This power type takes no ceiling.");
        if (b.CeilingAmount is <= 0) throw ApiProblemException.Invalid("V-ORG-CEILING", "A ceiling is above zero; leave it empty when it is not specified.");
        int? currency = null;
        if (b.CeilingAmount is not null)
            currency = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @c;",
                new { c = b.CeilingCurrency?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("V-ORG-CEILING", "A ceiling has its currency.");
        long? institution = null;
        if (b.Institution is { } inst)
        {
            if (!await u.ModuleEnabledAsync("INSTITUTIONS", ct, tx)) throw ApiProblemException.Forbidden("MODULE_DISABLED", "This module is not enabled for the account.");
            institution = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @i;",
                new { i = inst }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank is not known.");
        }
        var joint = b.RequiresJoint == true;
        var jointMin = joint ? b.JointMinSignatories ?? 2 : (int?)null;
        if (jointMin is < 2) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A joint grant needs at least two signatories.");
        var from = GovernanceEndpoints.Date(b.ValidFrom, "start date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the start date.");
        var to = GovernanceEndpoints.Date(b.ValidTo, "end date");
        if (to is not null && to < from) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The grant ends on or after its start.");
        var doc = await GovernanceEndpoints.DocumentAsync(u, tx, b.SourceDocument, companyId, ct);
        if (b.ExceptionReason is { Length: > 500 }) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The exception reason is up to 500 characters.");
        return new Resolved(kind, body, member, party, pt.Id, institution, b.CeilingAmount, currency, joint, jointMin, joint ? b.JointNote?.Trim() : null, from,
            b.ValidFromHijri?.Trim(), to, doc, b.SourcePage?.Trim(), string.IsNullOrWhiteSpace(b.ExceptionReason) ? null : b.ExceptionReason.Trim());
    }

    private static async Task<(long Id, Guid PublicId)> InsertAsync(BoundUser u, SqlTransaction tx, long companyId, Resolved r, long? supersedes, CancellationToken ct) =>
        await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
            """
            INSERT org.AuthorityGrant (TenantId, CompanyId, GranteeKind, BodyId, BodyMemberId, PartyId, PowerTypeId, InstitutionId, CeilingAmount, CeilingCurrencyId,
                                       RequiresJoint, JointMinSignatories, JointNote, ValidFrom, ValidFromHijriText, ValidTo, Status, SourceDocumentId, SourcePage,
                                       ExceptionReason, SupersedesGrantId, CreatedBy)
            OUTPUT inserted.AuthorityGrantId, inserted.PublicId
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @kind, @body, @member, @party, @pt, @inst, @ceiling, @cur, @joint, @jmin, @jnote, @from, @hijri, @to,
                    'DRAFT', @doc, @page, @ex, @sup, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new
            {
                c = companyId, kind = r.Kind, body = r.BodyId, member = r.MemberId, party = r.PartyId, pt = r.PowerTypeId, inst = r.InstitutionId, ceiling = r.Ceiling,
                cur = r.CurrencyId, joint = r.Joint, jmin = r.JointMin, jnote = r.JointNote, from = r.From, hijri = r.FromHijri, to = r.To, doc = r.DocumentId,
                page = r.Page, ex = r.Exception, sup = supersedes,
            }, tx, cancellationToken: ct));

    private static async Task<IResult> CreateAsync(Guid id, AuthorityGrantRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Create);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var company = await CompanyEndpoints.FindAsync(u, tx, id, scope, http.RequestAborted);
        if (company.Status == "ARCHIVED") throw new ApiProblemException(409, "V-ORG-ARCHIVED", "The company is archived.");
        var r = await ResolveAsync(u, tx, company.CompanyId, b, refs, http.RequestAborted);
        var g = await InsertAsync(u, tx, company.CompanyId, r, null, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("GRANT_CREATED", "TREASURY", "org.AuthorityGrant", g.Id,
            AfterJson: JsonSerializer.Serialize(new { kind = r.Kind, powerType = b.PowerType, from = D(r.From) })), company.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/grants/{g.PublicId}", new { id = g.PublicId });
    }

    /// <summary>A draft is edited in place: its source document and page, the exception, the note, the end date and the ceiling.</summary>
    private static async Task<IResult> PatchAsync(Guid id, AuthorityGrantRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, Create);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var g = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (!expected.AsSpan().SequenceEqual(g.RowVersion)) throw ETags.Conflict();
        if (g.Status != "DRAFT") throw new ApiProblemException(409, "V-ORG-GRANT-STATE", "Only a draft is edited; change an active grant with a new grant that replaces it.");
        var doc = b.SourceDocument is null ? g.SourceDocumentId : await GovernanceEndpoints.DocumentAsync(u, tx, b.SourceDocument, g.CompanyId, http.RequestAborted);
        var to = b.ValidTo is null ? g.ValidTo : GovernanceEndpoints.Date(b.ValidTo, "end date");
        if (to is not null && to < g.ValidFrom) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The grant ends on or after its start.");
        var ceiling = b.CeilingAmount ?? g.CeilingAmount;
        if (b.CeilingAmount is <= 0) throw ApiProblemException.Invalid("V-ORG-CEILING", "A ceiling is above zero; leave it empty when it is not specified.");
        if (b.CeilingAmount is not null && !g.AllowsCeiling) throw ApiProblemException.Invalid("V-ORG-CEILING", "This power type takes no ceiling.");
        var currency = b.CeilingCurrency is null ? g.CeilingCurrencyId : await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT CurrencyId FROM ref.Currency WHERE Code = @c;", new { c = b.CeilingCurrency.Trim().ToUpperInvariant() }, tx, cancellationToken: http.RequestAborted))
            ?? throw ApiProblemException.Invalid("V-ORG-CEILING", "A ceiling has its currency.");
        if (ceiling is not null && currency is null) throw ApiProblemException.Invalid("V-ORG-CEILING", "A ceiling has its currency.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE org.AuthorityGrant SET SourceDocumentId = @doc, SourcePage = @page, ExceptionReason = @ex, JointNote = @note, ValidTo = @to, CeilingAmount = @ceiling,
                   CeilingCurrencyId = @cur, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE AuthorityGrantId = @g;
            """, new
            {
                g = g.AuthorityGrantId, doc, page = b.SourcePage ?? g.SourcePage, ex = b.ExceptionReason is null ? g.ExceptionReason : b.ExceptionReason.Trim() is { Length: > 0 } e ? e : null,
                note = b.JointNote ?? g.JointNote, to, ceiling, cur = currency,
            }, tx, cancellationToken: http.RequestAborted));
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    private static void NeedsBasis(GrantRow g)
    {
        if (g.SourceDocumentId is null && g.ExceptionReason is null)
            throw ApiProblemException.Invalid("V-ORG-GRANT-SOURCE", "Link the source document (power of attorney, board resolution) or record a documented exception first (BR-ORG-013).");
    }

    private static async Task<bool> IsTreasuryManagerAsync(BoundUser u, SqlTransaction tx, CancellationToken ct) =>
        await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM sec.UserRole AS ur JOIN sec.Role AS r ON r.RoleId = ur.RoleId AND r.IsActive = 1 WHERE ur.UserId = @u AND r.Code = 'TM';",
            new { u = u.UserId }, tx, cancellationToken: ct)) > 0;

    private static async Task<IResult> SubmitAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Create);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var g = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (g.Status != "DRAFT") throw new ApiProblemException(409, "V-ORG-GRANT-STATE", "Only a draft is sent for approval.");
        NeedsBasis(g);
        await SetStatusAsync(u, tx, g.AuthorityGrantId, "PENDING_APPROVAL", http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("GRANT_SUBMITTED", "TREASURY", "org.AuthorityGrant", g.AuthorityGrantId), g.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    private static Task<int> SetStatusAsync(BoundUser u, SqlTransaction tx, long grantId, string status, CancellationToken ct) =>
        u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE org.AuthorityGrant SET Status = @s, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE AuthorityGrantId = @g;",
            new { g = grantId, s = status }, tx, cancellationToken: ct));

    /// <summary>The grant becomes ACTIVE with its approver; the grant it supersedes becomes SUPERSEDED in the same transaction.</summary>
    private static async Task ActivateCoreAsync(BoundUser u, SqlTransaction tx, GrantRow g, string action, CancellationToken ct)
    {
        if (g.ExceptionReason is not null && g.SourceDocumentId is null && !await IsTreasuryManagerAsync(u, tx, ct))
            throw ApiProblemException.Forbidden("V-ORG-EXCEPTION", "A grant without its source document is approved by a treasury manager (BR-ORG-013).");
        if (g.SupersedesGrantId is { } old)
        {
            var oldStatus = await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition("SELECT Status FROM org.AuthorityGrant WHERE AuthorityGrantId = @g;",
                new { g = old }, tx, cancellationToken: ct));
            if (oldStatus != "ACTIVE") throw new ApiProblemException(409, "V-ORG-GRANT-STATE", "The grant this one replaces is no longer active.");
            await SetStatusAsync(u, tx, old, "SUPERSEDED", ct);
            await Outbox.EmitAsync(u.Connection, tx, "authority.revoked", "org.AuthorityGrant", old, new { grant = g.Supersedes, reason = "SUPERSEDED", by = g.PublicId }, ct);
        }
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE org.AuthorityGrant SET Status = 'ACTIVE', ApprovedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ApprovedAt = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE AuthorityGrantId = @g;
            """, new { g = g.AuthorityGrantId }, tx, cancellationToken: ct));
        await Outbox.EmitAsync(u.Connection, tx, "authority.granted", "org.AuthorityGrant", g.AuthorityGrantId, new { grant = g.PublicId, supersedes = g.Supersedes }, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(action, "TREASURY", "org.AuthorityGrant", g.AuthorityGrantId,
            AfterJson: JsonSerializer.Serialize(new { supersedes = g.Supersedes, exception = g.ExceptionReason is not null && g.SourceDocumentId is null }), Severity: "HIGH"),
            g.CompanyId, ct);
    }

    /// <summary>FR-ORG-026: approval by another user than the creator while segregation of duties is on.</summary>
    private static async Task<IResult> ApproveAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Approve);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, http.RequestAborted);
        var g = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (g.Status != "PENDING_APPROVAL") throw new ApiProblemException(409, "V-ORG-GRANT-STATE", "The grant is not waiting for approval.");
        if (g.CreatedBy == u.UserId && await SegregationAsync(u, tx, http.RequestAborted))
            throw ApiProblemException.Forbidden("V-ORG-SOD", "The creator of a grant does not approve it.");
        NeedsBasis(g);
        await ActivateCoreAsync(u, tx, g, "GRANT_APPROVED", http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>Without segregation of duties a draft is activated directly, and the activator recorded as its approver (BR-ORG-014, DR-21).</summary>
    private static async Task<IResult> ActivateAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Approve);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, http.RequestAborted);
        var g = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (await SegregationAsync(u, tx, http.RequestAborted)) throw ApiProblemException.Forbidden("V-ORG-SOD", "Segregation of duties is on: send the grant for approval.");
        if (g.Status is not ("DRAFT" or "PENDING_APPROVAL")) throw new ApiProblemException(409, "V-ORG-GRANT-STATE", "Only a draft or a pending grant is activated.");
        NeedsBasis(g);
        await ActivateCoreAsync(u, tx, g, "GRANT_ACTIVATED", http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>A rejection returns the grant to DRAFT; its reason is kept in the audit (the table has no column for it).</summary>
    private static async Task<IResult> RejectAsync(Guid id, GrantReasonRequest b, HttpContext http, SqlConnectionFactory db)
    {
        if (string.IsNullOrWhiteSpace(b.Reason)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason.");
        await using var u = await BoundUser.OpenAsync(http, db, Approve);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var g = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (g.Status != "PENDING_APPROVAL") throw new ApiProblemException(409, "V-ORG-GRANT-STATE", "The grant is not waiting for approval.");
        await SetStatusAsync(u, tx, g.AuthorityGrantId, "DRAFT", http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("GRANT_REJECTED", "TREASURY", "org.AuthorityGrant", g.AuthorityGrantId,
            AfterJson: JsonSerializer.Serialize(new { reason = b.Reason.Trim() })), g.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>FR-ORG-028: a revoked grant keeps its row, its date and its reason, and stays in the historical reports.</summary>
    private static async Task<IResult> RevokeAsync(Guid id, GrantReasonRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        if (string.IsNullOrWhiteSpace(b.Reason) || b.Reason.Length > 1000) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason.");
        var on = GovernanceEndpoints.Date(b.On, "revocation date");
        await using var u = await BoundUser.OpenAsync(http, db, Approve);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var g = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (g.Status != "ACTIVE") throw new ApiProblemException(409, "V-ORG-GRANT-STATE", "Only an active grant is revoked.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE org.AuthorityGrant SET Status = 'REVOKED', RevokedAt = @at, RevokedReason = @r, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE AuthorityGrantId = @g;
            """, new { g = g.AuthorityGrantId, at = on ?? clock.GetUtcNow().UtcDateTime, r = b.Reason.Trim() }, tx, cancellationToken: http.RequestAborted));
        await Outbox.EmitAsync(u.Connection, tx, "authority.revoked", "org.AuthorityGrant", g.AuthorityGrantId, new { grant = g.PublicId, reason = "REVOKED" }, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("GRANT_REVOKED", "TREASURY", "org.AuthorityGrant", g.AuthorityGrantId,
            AfterJson: JsonSerializer.Serialize(new { reason = b.Reason.Trim(), on = on is { } d ? D(d) : null }), Severity: "HIGH"), g.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>BR-ORG-014: a substantive change is a new draft that replaces the active grant once approved; the fields not given are kept.</summary>
    private static async Task<IResult> SupersedeAsync(Guid id, AuthorityGrantRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Create);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, http.RequestAborted);
        var g = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (g.Status != "ACTIVE") throw new ApiProblemException(409, "V-ORG-GRANT-STATE", "Only an active grant is replaced.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM org.AuthorityGrant WHERE SupersedesGrantId = @g AND Status IN ('DRAFT', 'PENDING_APPROVAL');", new { g = g.AuthorityGrantId }, tx,
                cancellationToken: http.RequestAborted)) > 0)
            throw new ApiProblemException(409, "V-ORG-GRANT-PENDING", "A replacement of this grant is already waiting.");
        var bodyId = g.BodyPublicId;
        var merged = new AuthorityGrantRequest(
            b.GranteeKind ?? g.GranteeKind,
            b.Body ?? (g.GranteeKind == "BODY" ? bodyId : null),
            b.Member ?? (g.GranteeKind == "BODY_MEMBER" ? refs.ItemRef(u.TenantId, "body-member", g.BodyMemberId!.Value) : null),
            b.Party ?? (g.GranteeKind == "PARTY" ? g.HolderId : null),
            b.PowerType ?? g.PowerTypeCode,
            b.Institution ?? g.InstitutionPublicId,
            b.CeilingAmount ?? g.CeilingAmount,
            b.CeilingCurrency ?? g.CeilingCurrency,
            b.RequiresJoint ?? g.RequiresJoint,
            b.JointMinSignatories ?? g.JointMinSignatories,
            b.JointNote ?? g.JointNote,
            b.ValidFrom ?? D(g.ValidFrom),
            b.ValidFromHijri ?? g.ValidFromHijriText,
            b.ValidTo ?? (g.ValidTo is { } t ? D(t) : null),
            b.SourceDocument ?? g.SourceDocument,
            b.SourcePage ?? g.SourcePage,
            b.ExceptionReason ?? g.ExceptionReason);
        var r = await ResolveAsync(u, tx, g.CompanyId, merged, refs, http.RequestAborted);
        // An unrestricted bank can be set again by sending the empty id.
        if (b.Institution == Guid.Empty) r = r with { InstitutionId = null };
        var n = await InsertAsync(u, tx, g.CompanyId, r, g.AuthorityGrantId, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("GRANT_SUPERSEDE_PROPOSED", "TREASURY", "org.AuthorityGrant", n.Id,
            AfterJson: JsonSerializer.Serialize(new { supersedes = g.PublicId })), g.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/grants/{n.PublicId}", new { id = n.PublicId });
    }

    // ---------- the queries (FR-ORG-025) ----------

    private static DateTime AsOf(HttpRequest r, string key, TimeProvider clock) =>
        GovernanceEndpoints.Date(r.Query[key].ToString() is { Length: > 0 } s ? s : null, key) ?? GovernanceEndpoints.Today(clock);

    private static async Task<long?> InstitutionFilterAsync(BoundUser u, HttpRequest r, CancellationToken ct)
    {
        if (r.Query["institution"].ToString() is not { Length: > 0 } text) return null;
        // With the INSTITUTIONS module off, the bank filter is ignored and hidden (S1B-GAP-16).
        if (!await u.ModuleEnabledAsync("INSTITUTIONS", ct)) return null;
        if (!Guid.TryParse(text, out var id)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank is an id.");
        return await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @i;", new { i = id },
            cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank is not known.");
    }

    /// <summary>"Who may do X for amount Y on date D for company Z" (FR-ORG-025, AC-ORG-2).</summary>
    private static async Task<IResult> QueryAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "powerType", "amount", "currency", "date", "institution");
        var on = AsOf(http.Request, "date", clock);
        var power = http.Request.Query["powerType"].ToString().Trim().ToUpperInvariant();
        if (power.Length == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the power type.");
        decimal? amount = http.Request.Query["amount"].ToString() is { Length: > 0 } a
            ? decimal.TryParse(a, NumberStyles.Number, CultureInfo.InvariantCulture, out var x) && x > 0 ? x : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The amount is a positive number.")
            : null;
        var currency = http.Request.Query["currency"].ToString().Trim().ToUpperInvariant();
        if (amount is not null && currency.Length != 3) throw ApiProblemException.Invalid("VALIDATION_FAILED", "An amount has its currency.");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var company = await CompanyEndpoints.FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var institution = await InstitutionFilterAsync(u, http.Request, http.RequestAborted);
        var grants = (await u.Connection.QueryAsync<GrantRow>(new CommandDefinition(Select + " WHERE g.CompanyId = @c AND pt.Code = @p AND g.Status = 'ACTIVE';",
            new { c = company.CompanyId, p = power }, cancellationToken: http.RequestAborted)))
            .Where(g => EffectiveOn(g, on) && (institution is null || g.InstitutionId is null || g.InstitutionId == institution)).ToList();
        var results = new List<(GrantRow G, string[] Flags)>();
        foreach (var g in grants)
        {
            var flags = new List<string>();
            if (amount is not null)
            {
                if (g.CeilingAmount is null) flags.Add("CEILING_UNSPECIFIED");
                else if (!string.Equals(g.CeilingCurrency, currency, StringComparison.Ordinal)) flags.Add("MANUAL_CURRENCY_REVIEW");
                else if (amount > g.CeilingAmount) continue;
            }
            if (g.GranteeKind == "BODY" && g.BodyStatus == "CLOSED") flags.Add("BODY_CLOSED");
            if (g.RequiresJoint) flags.Add("JOINT");
            results.Add((g, [.. flags]));
        }
        var ordered = results.OrderBy(r => r.G.RequiresJoint).ThenByDescending(r => r.G.CeilingAmount ?? decimal.MaxValue).ToList();
        var today = GovernanceEndpoints.Today(clock);
        return Results.Ok(new
        {
            date = D(on),
            items = ordered.Select(r => new { grant = Shape(r.G, today, null), flags = r.Flags }),
            // Joint ceilings are never added up (BR-ORG-012): when nothing qualifies, a joint combination is for a person to review.
            suggestion = ordered.Count == 0 && grants.Any(g => g.RequiresJoint) ? "REVIEW_JOINT_COMBINATION_MANUALLY" : null,
        });
    }

    /// <summary>
    /// The holder mode of FR-ORG-025, on which the governance comparison builds (FR-ACC-018): the valid and the expired
    /// grants of a person, alone or as a member (or as the natural representative of a member entity, OQ-5), for the
    /// power types and the bank asked; a body's grant is never a person's.
    /// </summary>
    private static async Task<IResult> HolderAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "powerTypes", "date", "institution");
        var on = AsOf(http.Request, "date", clock);
        var types = http.Request.Query["powerTypes"].ToString().Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(t => t.ToUpperInvariant()).ToArray();
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var party = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT PartyId FROM pty.Party WHERE PublicId = @p;", new { p = id },
            cancellationToken: http.RequestAborted)) ?? throw ApiProblemException.NotFound();
        var institution = await InstitutionFilterAsync(u, http.Request, http.RequestAborted);
        var rows = (await u.Connection.QueryAsync<GrantRow>(new CommandDefinition(Select +
            """
             WHERE g.GranteeKind <> 'BODY' AND (g.PartyId = @p OR m.PartyId = @p OR m.RepresentedPartyId = @p)
               AND g.Status IN ('ACTIVE', 'SUPERSEDED', 'REVOKED') AND (@any = 1 OR pt.Code IN @types)
             ORDER BY g.ValidFrom;
            """, new { p = party, any = types.Length == 0, types = types.Length == 0 ? [""] : types }, cancellationToken: http.RequestAborted)))
            .Where(g => scope.Allows(g.CompanyId) && (institution is null || g.InstitutionId is null || g.InstitutionId == institution)).ToList();
        var today = GovernanceEndpoints.Today(clock);
        return Results.Ok(new
        {
            date = D(on),
            items = rows.Select(g => new { grant = Shape(g, today, null), effective = EffectiveOn(g, on) }),
        });
    }

    /// <summary>FR-ORG-027: holders by power type on a date, as printed; a body is a row of its own.</summary>
    private static async Task<IResult> MatrixAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "asOf");
        var on = AsOf(http.Request, "asOf", clock);
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var company = await CompanyEndpoints.FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var grants = (await u.Connection.QueryAsync<GrantRow>(new CommandDefinition(Select + " WHERE g.CompanyId = @c AND g.Status = 'ACTIVE';",
            new { c = company.CompanyId }, cancellationToken: http.RequestAborted))).Where(g => EffectiveOn(g, on)).ToList();
        var types = await u.Connection.QueryAsync<(string Code, string NameAr, string? NameEn)>(new CommandDefinition(
            "SELECT Code, NameAr, NameEn FROM cat.PowerType WHERE IsActive = 1 ORDER BY SortOrder, Code;", cancellationToken: http.RequestAborted));
        var rows = grants.GroupBy(g => (g.HolderId, g.BodyPublicId, Body: g.GranteeKind == "BODY"))
            .Select(h => new
            {
                holder = new { party = h.Key.Body ? null : h.Key.HolderId, body = h.Key.Body ? h.Key.BodyPublicId : null, nameAr = h.First().HolderNameAr, nameEn = h.First().HolderNameEn },
                cells = h.GroupBy(g => g.PowerTypeCode).ToDictionary(c => c.Key, c => c.Select(g => new
                {
                    grant = g.PublicId, ceiling = g.CeilingAmount is null ? null : new { amount = g.CeilingAmount, currency = g.CeilingCurrency }, joint = g.RequiresJoint,
                    jointNote = g.JointNote, institution = g.InstitutionCode, validTo = g.ValidTo is { } t ? D(t) : null,
                })),
            });
        return Results.Ok(new { asOf = D(on), company = new { id = company.PublicId, code = company.CompanyCode, nameAr = company.NameAr, nameEn = company.NameEn },
            powerTypes = types.Select(t => new { code = t.Code, nameAr = t.NameAr, nameEn = t.NameEn }), rows });
    }

    /// <summary>
    /// FR-ORG-029 (screen 20): ownership not at 100%, a company without its basic documents (an active commercial
    /// registration and articles of association, owner default OQ-17), an active body without an active member, a
    /// grant to a member who left or to a closed body, and a parent company that holds none of its subsidiary.
    /// </summary>
    private static async Task<IResult> IntegrityAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var today = GovernanceEndpoints.Today(clock);
        var rows = await u.Connection.QueryAsync<(string Item, Guid Company, string Code, string NameAr, string? NameEn, string? Detail)>(new CommandDefinition(
            """
            WITH co AS (SELECT * FROM org.Company WHERE Status = 'ACTIVE' AND (@all = 1 OR CompanyId IN @ids))
            SELECT 'OWNERSHIP_NOT_100', co.PublicId, co.CompanyCode, co.NameAr, co.NameEn, CONVERT(VARCHAR(40), ISNULL(t.Total, 0))
              FROM co OUTER APPLY (SELECT SUM(SharePercent) AS Total FROM org.Shareholding AS s
                                    WHERE s.CompanyId = co.CompanyId AND s.Layer = 1 AND s.EffectiveFrom <= @d AND (s.EffectiveTo IS NULL OR s.EffectiveTo >= @d)) AS t
             WHERE ISNULL(t.Total, 0) <> 100
            UNION ALL
            SELECT 'MISSING_BASIC_DOCUMENTS', co.PublicId, co.CompanyCode, co.NameAr, co.NameEn, x.Code
              FROM co CROSS JOIN (VALUES ('COMMERCIAL_REGISTRATION'), ('ARTICLES_OF_ASSOCIATION')) AS x (Code)
             WHERE NOT EXISTS (SELECT 1 FROM doc.Document AS d JOIN cat.DocumentType AS dt ON dt.DocumentTypeId = d.DocumentTypeId
                                WHERE d.OwnerCompanyId = co.CompanyId AND dt.Code = x.Code AND d.Status = 'ACTIVE' AND d.SupersededByDocumentId IS NULL
                                  AND (d.ExpiryDate IS NULL OR d.ExpiryDate >= @d))
            UNION ALL
            SELECT 'BODY_WITHOUT_MEMBERS', co.PublicId, co.CompanyCode, co.NameAr, co.NameEn, b.BodyType
              FROM co JOIN org.GoverningBody AS b ON b.CompanyId = co.CompanyId AND b.Status = 'ACTIVE'
             WHERE NOT EXISTS (SELECT 1 FROM org.BodyMember AS m WHERE m.BodyId = b.GoverningBodyId AND m.TermStart <= @d AND (m.TermEnd IS NULL OR m.TermEnd >= @d)
                                 AND (m.ResignedOn IS NULL OR m.ResignedOn > @d))
            UNION ALL
            SELECT 'GRANT_TO_FORMER_MEMBER', co.PublicId, co.CompanyCode, co.NameAr, co.NameEn, CONVERT(VARCHAR(40), g.PublicId)
              FROM co JOIN org.AuthorityGrant AS g ON g.CompanyId = co.CompanyId AND g.Status = 'ACTIVE' AND g.GranteeKind = 'BODY_MEMBER'
              JOIN org.BodyMember AS m ON m.BodyMemberId = g.BodyMemberId
             WHERE (m.TermEnd IS NOT NULL AND m.TermEnd < @d) OR (m.ResignedOn IS NOT NULL AND m.ResignedOn <= @d)
            UNION ALL
            SELECT 'GRANT_TO_CLOSED_BODY', co.PublicId, co.CompanyCode, co.NameAr, co.NameEn, CONVERT(VARCHAR(40), g.PublicId)
              FROM co JOIN org.AuthorityGrant AS g ON g.CompanyId = co.CompanyId AND g.Status = 'ACTIVE' AND g.GranteeKind = 'BODY'
              JOIN org.GoverningBody AS b ON b.GoverningBodyId = g.BodyId AND b.Status = 'CLOSED'
            UNION ALL
            SELECT 'PARENT_NOT_OWNER', co.PublicId, co.CompanyCode, co.NameAr, co.NameEn, p.CompanyCode
              FROM co JOIN org.Company AS p ON p.CompanyId = co.ParentCompanyId
             WHERE NOT EXISTS (SELECT 1 FROM org.Shareholding AS s WHERE s.CompanyId = co.CompanyId AND s.HolderPartyId = p.PartyId AND s.Layer = 1
                                 AND s.EffectiveFrom <= @d AND (s.EffectiveTo IS NULL OR s.EffectiveTo >= @d));
            """, new { d = today, all = scope.All, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        var items = rows.GroupBy(r => r.Item).Select(g => new
        {
            item = g.Key, count = g.Count(),
            rows = g.Select(r => new { company = r.Company, code = r.Code, nameAr = r.NameAr, nameEn = r.NameEn, detail = r.Detail }),
        });
        return Results.Ok(new { date = D(today), items });
    }
}

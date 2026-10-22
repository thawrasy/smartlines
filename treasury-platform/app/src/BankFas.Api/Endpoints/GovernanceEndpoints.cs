using System.Data;
using System.Globalization;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record BodyRequest(string? BodyType, string? NameAr, string? NameEn, string? TermStart, string? TermEnd, string? QuorumRuleText,
    string? DecisionRuleText, Guid? SourceDocument, bool? Replace, bool? CarryMembers);
public sealed record BodyCloseRequest(string? ClosedOn);
public sealed record MemberRequest(Guid? Party, string? Position, string? TermStart, string? TermEnd, Guid? RepresentedBy, Guid? AppointmentDocument);
public sealed record MemberEndRequest(string? On);

/// <summary>
/// Governing bodies and their members (FR-ORG-019 to 022, BR-ORG-009, BR-ORG-010; screens 14 and 16 of spec 10). One
/// active body per type and company; a replacement closes the previous body and ends its open terms the day before the
/// new term, and may carry its members to the new body (owner default OQ-4). A member's term lies within the body's,
/// its position applies to the body's type, and a single-holder position has one holder at a time: a new chairman from
/// 2027-03-01 ends the previous term on 2027-02-28. The member of a legal entity is the entity; RepresentedBy is the
/// natural person who represents it (owner default OQ-5). Member states are derived: upcoming, active, ended, resigned.
/// </summary>
public static class GovernanceEndpoints
{
    private const string View = "org.company.view";
    private const string Manage = "org.body.manage";
    private static readonly string[] BodyTypes = ["BOARD_OF_DIRECTORS", "BOARD_OF_MANAGERS", "MANAGEMENT", "GENERAL_ASSEMBLY"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/companies/{id:guid}/bodies", ListAsync);
        api.MapPost("/companies/{id:guid}/bodies", CreateAsync);
        api.MapPost("/bodies/{id:guid}/actions/close", CloseAsync);
        api.MapPost("/bodies/{id:guid}/members", AddMemberAsync);
        api.MapPost("/bodies/{id:guid}/members/{reference}/actions/end", (Guid id, string reference, MemberEndRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
            EndMemberAsync(id, reference, b, http, db, refs, resign: false));
        api.MapPost("/bodies/{id:guid}/members/{reference}/actions/resign", (Guid id, string reference, MemberEndRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
            EndMemberAsync(id, reference, b, http, db, refs, resign: true));
    }

    internal static string D(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    internal static DateTime? Date(string? text, string field) =>
        string.IsNullOrWhiteSpace(text) ? null
        : DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
        : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is a date YYYY-MM-DD.");

    internal static DateTime Today(TimeProvider clock) => clock.GetUtcNow().UtcDateTime.Date;

    internal sealed class BodyRow
    {
        public long GoverningBodyId { get; init; }
        public Guid PublicId { get; init; }
        public long CompanyId { get; init; }
        public string BodyType { get; init; } = "";
        public string? NameAr { get; init; }
        public string? NameEn { get; init; }
        public DateTime? TermStart { get; init; }
        public DateTime? TermEnd { get; init; }
        public string? QuorumRuleText { get; init; }
        public string? DecisionRuleText { get; init; }
        public string Status { get; init; } = "";
        public Guid? SourceDocument { get; init; }
    }

    internal sealed class MemberRow
    {
        public long BodyMemberId { get; init; }
        public long BodyId { get; init; }
        public long PartyId { get; init; }
        public Guid PartyPublicId { get; init; }
        public string PartyCode { get; init; } = "";
        public string PartyNameAr { get; init; } = "";
        public string? PartyNameEn { get; init; }
        public string PositionCode { get; init; } = "";
        public string PositionNameAr { get; init; } = "";
        public string? PositionNameEn { get; init; }
        public bool IsSingleHolder { get; init; }
        public DateTime TermStart { get; init; }
        public DateTime? TermEnd { get; init; }
        public DateTime? ResignedOn { get; init; }
        public Guid? RepresentedBy { get; init; }
        public string? RepresentedByNameAr { get; init; }
        public string? RepresentedByNameEn { get; init; }
    }

    private const string BodySelect =
        """
        SELECT b.GoverningBodyId, b.PublicId, b.CompanyId, b.BodyType, b.NameAr, b.NameEn, b.TermStart, b.TermEnd, b.QuorumRuleText, b.DecisionRuleText, b.Status,
               d.PublicId AS SourceDocument
          FROM org.GoverningBody AS b LEFT JOIN doc.Document AS d ON d.DocumentId = b.SourceDocumentId
        """;

    internal const string MemberSelect =
        """
        SELECT m.BodyMemberId, m.BodyId, m.PartyId, p.PublicId AS PartyPublicId, p.PartyCode, p.NameAr AS PartyNameAr, p.NameEn AS PartyNameEn,
               pos.Code AS PositionCode, pos.NameAr AS PositionNameAr, pos.NameEn AS PositionNameEn, pos.IsSingleHolder, m.TermStart, m.TermEnd, m.ResignedOn,
               r.PublicId AS RepresentedBy, r.NameAr AS RepresentedByNameAr, r.NameEn AS RepresentedByNameEn
          FROM org.BodyMember AS m JOIN pty.Party AS p ON p.PartyId = m.PartyId JOIN cat.Position AS pos ON pos.PositionId = m.PositionId
          LEFT JOIN pty.Party AS r ON r.PartyId = m.RepresentedPartyId
        """;

    /// <summary>BR-ORG-010: a member is active when the day is within the term and the member has not resigned.</summary>
    internal static bool ActiveOn(MemberRow m, DateTime d) => m.TermStart <= d && (m.TermEnd is null || m.TermEnd >= d) && (m.ResignedOn is null || m.ResignedOn > d);

    internal static string State(MemberRow m, DateTime today) =>
        m.ResignedOn is { } r && r <= today ? "RESIGNED" : m.TermStart > today ? "UPCOMING" : m.TermEnd is { } e && e < today ? "ENDED" : "ACTIVE";

    private static object Shape(MemberRow m, DateTime today, int tenant, OpaqueRefs refs) => new
    {
        id = refs.ItemRef(tenant, "body-member", m.BodyMemberId),
        party = new { id = m.PartyPublicId, code = m.PartyCode, nameAr = m.PartyNameAr, nameEn = m.PartyNameEn },
        position = new { code = m.PositionCode, nameAr = m.PositionNameAr, nameEn = m.PositionNameEn, isSingleHolder = m.IsSingleHolder },
        termStart = D(m.TermStart), termEnd = m.TermEnd is { } e ? D(e) : null, resignedOn = m.ResignedOn is { } r ? D(r) : null,
        representedBy = m.RepresentedBy is null ? null : new { id = m.RepresentedBy, nameAr = m.RepresentedByNameAr, nameEn = m.RepresentedByNameEn },
        state = State(m, today),
    };

    private static async Task<BodyRow> BodyAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct)
    {
        var b = await u.Connection.QuerySingleOrDefaultAsync<BodyRow>(new CommandDefinition(BodySelect + " WHERE b.PublicId = @id;", new { id }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        return scope.Allows(b.CompanyId) ? b : throw ApiProblemException.NotFound();
    }

    internal static async Task<long?> DocumentAsync(BoundUser u, SqlTransaction tx, Guid? id, long companyId, CancellationToken ct) =>
        id is null ? null
        : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE' AND (OwnerCompanyId IS NULL OR OwnerCompanyId = @c);",
            new { d = id, c = companyId }, tx, cancellationToken: ct))
          ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is not an active document of this company.");

    private static async Task<IResult> ListAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        Query.Allow(http.Request, "includeClosed");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var company = await CompanyEndpoints.FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var closed = string.Equals(http.Request.Query["includeClosed"], "true", StringComparison.OrdinalIgnoreCase);
        var bodies = (await u.Connection.QueryAsync<BodyRow>(new CommandDefinition(
            BodySelect + " WHERE b.CompanyId = @c AND (@closed = 1 OR b.Status = 'ACTIVE') ORDER BY b.Status, b.BodyType, b.TermStart DESC;",
            new { c = company.CompanyId, closed }, cancellationToken: http.RequestAborted))).ToList();
        var members = (await u.Connection.QueryAsync<MemberRow>(new CommandDefinition(MemberSelect + " WHERE m.CompanyId = @c ORDER BY pos.SortOrder, m.TermStart;",
            new { c = company.CompanyId }, cancellationToken: http.RequestAborted))).ToLookup(m => m.BodyId);
        var today = Today(clock);
        return Results.Ok(new
        {
            items = bodies.Select(b => new
            {
                id = b.PublicId, bodyType = b.BodyType, nameAr = b.NameAr, nameEn = b.NameEn, termStart = b.TermStart is { } s ? D(s) : null,
                termEnd = b.TermEnd is { } e ? D(e) : null,
                durationMonths = b.TermStart is { } a && b.TermEnd is { } z ? (z.Year - a.Year) * 12 + z.Month - a.Month + (z.Day >= a.Day - 1 ? 0 : -1) : (int?)null,
                quorumRuleText = b.QuorumRuleText, decisionRuleText = b.DecisionRuleText, status = b.Status, sourceDocument = b.SourceDocument,
                members = members[b.GoverningBodyId].Select(m => Shape(m, today, u.TenantId, refs)),
            }),
        });
    }

    /// <summary>FR-ORG-019, BR-ORG-009: a new body; with replace, the active body of the type closes and its open terms end the day before.</summary>
    private static async Task<IResult> CreateAsync(Guid id, BodyRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var type = b.BodyType?.Trim().ToUpperInvariant();
        if (type is null || !BodyTypes.Contains(type)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The body is a board of directors, a board of managers, the management or the general assembly.");
        var start = Date(b.TermStart, "term start");
        var end = Date(b.TermEnd, "term end");
        if (start is not null && end is not null && end < start) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The term ends on or after its start.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, http.RequestAborted);
        var company = await CompanyEndpoints.FindAsync(u, tx, id, scope, http.RequestAborted);
        if (company.Status == "ARCHIVED") throw new ApiProblemException(409, "V-ORG-ARCHIVED", "The company is archived.");
        var doc = await DocumentAsync(u, tx, b.SourceDocument, company.CompanyId, http.RequestAborted);
        var previous = await u.Connection.QuerySingleOrDefaultAsync<BodyRow>(new CommandDefinition(
            BodySelect + " WHERE b.CompanyId = @c AND b.BodyType = @t AND b.Status = 'ACTIVE';", new { c = company.CompanyId, t = type }, tx, cancellationToken: http.RequestAborted));
        var carried = 0;
        if (previous is not null)
        {
            if (b.Replace != true)
                throw new ApiProblemException(409, "V-ORG-BODY-ACTIVE", "The company already has an active body of this type; replace it with the new term.");
            var from = start ?? Today(clock);
            if (previous.TermStart is { } ps && from <= ps) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The new term starts after the start of the term it replaces.");
            await CloseBodyAsync(u, tx, previous.GoverningBodyId, from.AddDays(-1), http.RequestAborted);
            start = from;
        }
        var created = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            INSERT org.GoverningBody (TenantId, CompanyId, BodyType, NameAr, NameEn, TermStart, TermEnd, QuorumRuleText, DecisionRuleText, Status, SourceDocumentId, CreatedBy)
            OUTPUT inserted.GoverningBodyId, inserted.PublicId
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @t, @ar, @en, @start, @end, @q, @dr, 'ACTIVE', @doc, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new { c = company.CompanyId, t = type, ar = b.NameAr?.Trim(), en = b.NameEn?.Trim(), start, end, q = b.QuorumRuleText, dr = b.DecisionRuleText, doc },
            tx, cancellationToken: http.RequestAborted));
        if (previous is not null && b.CarryMembers == true)
            carried = await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT org.BodyMember (TenantId, CompanyId, BodyId, PartyId, PositionId, TermStart, TermEnd, RepresentedPartyId, CreatedBy)
                SELECT m.TenantId, m.CompanyId, @new, m.PartyId, m.PositionId, @from, @end, m.RepresentedPartyId, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                  FROM org.BodyMember AS m
                 WHERE m.BodyId = @old AND m.TermEnd = @closed AND m.ResignedOn IS NULL AND m.TermStart <= @closed;
                """, new { @new = created.Id, old = previous.GoverningBodyId, from = start, end, closed = start!.Value.AddDays(-1) }, tx, cancellationToken: http.RequestAborted));
        await Outbox.EmitAsync(u.Connection, tx, "body.changed", "org.GoverningBody", created.Id, new { body = created.PublicId, replaced = previous?.PublicId }, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(previous is null ? "BODY_CREATED" : "BODY_REPLACED", "TREASURY", "org.GoverningBody", created.Id,
            BeforeJson: previous is null ? null : JsonSerializer.Serialize(new { replaced = previous.PublicId }),
            AfterJson: JsonSerializer.Serialize(new { type, start = start is { } st ? D(st) : null, end = end is { } en ? D(en) : null, carried })), company.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/bodies/{created.PublicId}", new { id = created.PublicId, carriedMembers = carried });
    }

    /// <summary>Closes a body and ends its open terms on the date (OQ-4); a term that starts later is left to its own end.</summary>
    private static async Task CloseBodyAsync(BoundUser u, SqlTransaction tx, long bodyId, DateTime on, CancellationToken ct) =>
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE org.GoverningBody SET Status = 'CLOSED', TermEnd = CASE WHEN TermEnd IS NULL OR TermEnd > @on THEN CASE WHEN TermStart > @on THEN TermStart ELSE @on END ELSE TermEnd END,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE GoverningBodyId = @b;
            UPDATE org.BodyMember SET TermEnd = @on, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE BodyId = @b AND ResignedOn IS NULL AND TermStart <= @on AND (TermEnd IS NULL OR TermEnd > @on);
            """, new { b = bodyId, on }, tx, cancellationToken: ct));

    private static async Task<IResult> CloseAsync(Guid id, BodyCloseRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var on = Date(b.ClosedOn, "closing date") ?? Today(clock);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, http.RequestAborted);
        var body = await BodyAsync(u, tx, id, scope, http.RequestAborted);
        if (body.Status != "ACTIVE") throw new ApiProblemException(409, "V-ORG-BODY-CLOSED", "The body is already closed.");
        await CloseBodyAsync(u, tx, body.GoverningBodyId, on, http.RequestAborted);
        await Outbox.EmitAsync(u.Connection, tx, "body.changed", "org.GoverningBody", body.GoverningBodyId, new { body = body.PublicId, closed = D(on) }, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("BODY_CLOSED", "TREASURY", "org.GoverningBody", body.GoverningBodyId,
            AfterJson: JsonSerializer.Serialize(new { closedOn = D(on) })), body.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>FR-ORG-020, BR-ORG-010: a member, within the body's term, in a position of the body's type.</summary>
    private static async Task<IResult> AddMemberAsync(Guid id, MemberRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        if (b.Party is null || string.IsNullOrWhiteSpace(b.Position)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the person and the position.");
        var start = Date(b.TermStart, "term start") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the start of the term.");
        var end = Date(b.TermEnd, "term end");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, http.RequestAborted);
        var body = await BodyAsync(u, tx, id, scope, http.RequestAborted);
        if (body.Status != "ACTIVE") throw new ApiProblemException(409, "V-ORG-BODY-CLOSED", "The body is closed; add members to the body that replaced it.");
        end ??= body.TermEnd;
        if (end is not null && end < start) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The term ends on or after its start.");
        if ((body.TermStart is { } bs && start < bs) || (body.TermEnd is { } be && (end is null || end > be)))
            throw ApiProblemException.Invalid("V-ORG-MEMBER-TERM", "The member's term lies within the body's term.");
        var pos = await u.Connection.QuerySingleOrDefaultAsync<(int Id, string? Types, bool Single, bool Active)>(new CommandDefinition(
            "SELECT PositionId, ApplicableBodyTypes, IsSingleHolder, IsActive FROM cat.Position WHERE Code = @c;", new { c = b.Position.Trim().ToUpperInvariant() }, tx,
            cancellationToken: http.RequestAborted));
        if (pos.Id == 0 || !pos.Active) throw ApiProblemException.Invalid("V-ORG-POSITION", "The position is not an active position of the catalogue.");
        if (pos.Types is { Length: > 0 } types && !types.Split(',').Contains(body.BodyType, StringComparer.Ordinal))
            throw ApiProblemException.Invalid("V-ORG-POSITION", "The position does not apply to this kind of body.");
        var party = await u.Connection.QuerySingleOrDefaultAsync<(long Id, string Kind, bool Active)>(new CommandDefinition(
            "SELECT PartyId, Kind, IsActive FROM pty.Party WHERE PublicId = @p;", new { p = b.Party }, tx, cancellationToken: http.RequestAborted));
        if (party.Id == 0 || !party.Active) throw ApiProblemException.Invalid("V-ORG-OWN-PARTY", "The member is not an active party.");
        long? representative = null;
        if (b.RepresentedBy is { } rep)
        {
            var r = await u.Connection.QuerySingleOrDefaultAsync<(long Id, string Kind)>(new CommandDefinition(
                "SELECT PartyId, Kind FROM pty.Party WHERE PublicId = @p AND IsActive = 1;", new { p = rep }, tx, cancellationToken: http.RequestAborted));
            if (r.Id == 0 || r.Kind != "INDIVIDUAL" || party.Kind != "ORGANIZATION")
                throw ApiProblemException.Invalid("V-ORG-REPRESENTATIVE", "A representative is a natural person who represents a member that is an entity.");
            representative = r.Id;
        }
        var doc = await DocumentAsync(u, tx, b.AppointmentDocument, body.CompanyId, http.RequestAborted);
        var others = (await u.Connection.QueryAsync<MemberRow>(new CommandDefinition(MemberSelect + " WHERE m.BodyId = @b AND m.PositionId = @pos;",
            new { b = body.GoverningBodyId, pos = pos.Id }, tx, cancellationToken: http.RequestAborted))).ToList();
        bool Overlaps(MemberRow m) => m.TermStart <= (end ?? DateTime.MaxValue) && start <= (m.ResignedOn?.AddDays(-1) ?? m.TermEnd ?? DateTime.MaxValue);
        if (others.Any(m => m.PartyId == party.Id && Overlaps(m)))
            throw ApiProblemException.Invalid("V-ORG-MEMBER-OVERLAP", "The person already holds this position in the body for part of the period.");
        var closedPrevious = 0;
        if (pos.Single)
        {
            foreach (var m in others.Where(Overlaps))
            {
                // The holder who started earlier hands over the day before; a later or equal start is a conflict.
                if (m.TermStart >= start) throw ApiProblemException.Invalid("V-ORG-SINGLE-HOLDER", "The position has one holder at a time, and another holder starts on or after this date.");
                closedPrevious += await u.Connection.ExecuteAsync(new CommandDefinition(
                    "UPDATE org.BodyMember SET TermEnd = @to, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE BodyMemberId = @m;",
                    new { m = m.BodyMemberId, to = start.AddDays(-1) }, tx, cancellationToken: http.RequestAborted));
            }
        }
        var memberId = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            INSERT org.BodyMember (TenantId, CompanyId, BodyId, PartyId, PositionId, TermStart, TermEnd, RepresentedPartyId, AppointmentDocumentId, CreatedBy)
            OUTPUT inserted.BodyMemberId
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @b, @p, @pos, @start, @end, @rep, @doc, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new { c = body.CompanyId, b = body.GoverningBodyId, p = party.Id, pos = pos.Id, start, end, rep = representative, doc }, tx, cancellationToken: http.RequestAborted));
        await Outbox.EmitAsync(u.Connection, tx, "body.changed", "org.GoverningBody", body.GoverningBodyId, new { body = body.PublicId, member = "added" }, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("BODY_MEMBER_ADDED", "TREASURY", "org.BodyMember", memberId,
            AfterJson: JsonSerializer.Serialize(new { body = body.PublicId, position = b.Position, start = D(start), end = end is { } e ? D(e) : null, closedPrevious })),
            body.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/bodies/{body.PublicId}", new { id = refs.ItemRef(u.TenantId, "body-member", memberId), closedPrevious });
    }

    /// <summary>Ends or records the resignation of a term; the grants to the membership are then flagged (FR-ORG-028).</summary>
    private static async Task<IResult> EndMemberAsync(Guid id, string reference, MemberEndRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, bool resign)
    {
        var on = Date(b.On, resign ? "resignation date" : "end of the term") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var body = await BodyAsync(u, tx, id, scope, http.RequestAborted);
        var memberId = refs.ItemId(u.TenantId, "body-member", reference) ?? throw ApiProblemException.NotFound();
        var m = await u.Connection.QuerySingleOrDefaultAsync<MemberRow>(new CommandDefinition(MemberSelect + " WHERE m.BodyMemberId = @m AND m.BodyId = @b;",
            new { m = memberId, b = body.GoverningBodyId }, tx, cancellationToken: http.RequestAborted)) ?? throw ApiProblemException.NotFound();
        if (on < m.TermStart) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The date is on or after the start of the term.");
        if (m.ResignedOn is not null || (m.TermEnd is { } e && e < on)) throw new ApiProblemException(409, "V-ORG-MEMBER-ENDED", "The term has already ended.");
        await u.Connection.ExecuteAsync(new CommandDefinition(resign
            ? "UPDATE org.BodyMember SET ResignedOn = @on, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE BodyMemberId = @m;"
            : "UPDATE org.BodyMember SET TermEnd = @on, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE BodyMemberId = @m;",
            new { m = memberId, on }, tx, cancellationToken: http.RequestAborted));
        var grants = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM org.AuthorityGrant WHERE BodyMemberId = @m AND Status IN ('DRAFT', 'PENDING_APPROVAL', 'ACTIVE');", new { m = memberId }, tx,
            cancellationToken: http.RequestAborted));
        await Outbox.EmitAsync(u.Connection, tx, "body.changed", "org.GoverningBody", body.GoverningBodyId, new { body = body.PublicId, member = resign ? "resigned" : "ended" }, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(resign ? "BODY_MEMBER_RESIGNED" : "BODY_MEMBER_ENDED", "TREASURY", "org.BodyMember", memberId,
            AfterJson: JsonSerializer.Serialize(new { on = D(on), grantsToReview = grants })), body.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Ok(new { grantsToReview = grants });
    }
}

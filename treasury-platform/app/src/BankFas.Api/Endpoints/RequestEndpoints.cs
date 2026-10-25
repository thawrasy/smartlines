using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Text;
using BankFas.Data;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record NewRequestBody(string? Type, Guid? Company, Guid? Requester, JsonElement? Data, string? Priority, string? UrgentReason);
public sealed record RequestFormBody(JsonElement? Data);
public sealed record RequestActionBody(string? Comment, string? InternalComment, string? ToStage, bool? OverrideRequested, string? OverrideReason, string[]? AcknowledgeWarnings,
    Guid? AssignTo = null, string? SubStatus = null, string? Priority = null);
public sealed record RequestCommentBody(string? Body, string? Visibility);
public sealed record RequestAttachmentBody(Guid? Document, string? Slot);
public sealed record RequestExternalRefBody(string? SystemCode, string? RefType, string? Value);
public sealed record RequestAllocationBody(Guid? Facility, string? Limit, string? Line);

/// <summary>
/// The requests (spec 13; S3 batch B): the types a user may raise, drafts and their form, the actions of the engine,
/// comments, attachments and external references, and two projections built in the server (BR-WFL-024): the staff
/// view for holders of req.view.internal, and the requester view, which carries the visible phase, the requester's
/// own form, the visible comments, attachments and timeline only, never the internal stage, sub-status, assignee,
/// allocation or reservation. A request outside what the user may see is 404. Gated by the REQUESTS module.
/// </summary>
public static class RequestEndpoints
{
    // The platform's clock (the TimeProvider of the services): a delegate's period is read on the same day as the inbox's.
    private static TimeProvider Clock { get; set; } = TimeProvider.System;

    public static void Map(RouteGroupBuilder api)
    {
        Clock = ((IEndpointRouteBuilder)api).ServiceProvider.GetService<TimeProvider>() ?? TimeProvider.System;
        api.MapGet("/request-types", TypesAsync);
        api.MapPost("/requests", CreateAsync);
        api.MapGet("/requests", ListAsync);
        api.MapGet("/requests/{id:guid}", GetAsync);
        api.MapPatch("/requests/{id:guid}", PatchAsync);
        api.MapPost("/requests/{id:guid}/actions/{action}", ActAsync);
        api.MapPost("/requests/{id:guid}/comments", CommentAsync);
        api.MapPost("/requests/{id:guid}/attachments", AttachAsync);
        api.MapPost("/requests/{id:guid}/external-refs", ExternalRefAsync);
        api.MapGet("/requests/{id:guid}/availability", AvailabilityAsync);
        api.MapPut("/requests/{id:guid}/allocation", AllocateAsync);
        api.MapPost("/requests/{id:guid}/copy", CopyAsync);
    }

    internal static async Task<BoundUser> OpenAsync(HttpContext http, SqlConnectionFactory db)
    {
        var u = await BoundUser.OpenAsync(http, db);
        try
        {
            await u.RequireModuleAsync("REQUESTS", http.RequestAborted);
            await u.PermissionsAsync(http.RequestAborted);   // read before any transaction, then cached for the request
            return u;
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }

    internal static async Task<Actor> ActorAsync(BoundUser u, SqlTransaction? tx, CancellationToken ct)
    {
        var roles = await u.Connection.QueryAsync<long>(new CommandDefinition(
            "SELECT ur.RoleId FROM sec.UserRole AS ur JOIN sec.Role AS r ON r.RoleId = ur.RoleId AND r.IsActive = 1 WHERE ur.UserId = @u;", new { u = u.UserId }, tx,
            cancellationToken: ct));
        return new Actor(u.UserId, await u.PermissionsAsync(ct), roles.ToHashSet());
    }

    private static async Task<long> IdOfAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct) =>
        await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT RequestId FROM wfl.Request WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.NotFound();

    /// <summary>
    /// Who may see a request (FR-REQ-015, 016; BR-REQ-013): a holder of req.view.all within the company scope; its requester
    /// or creator; a user who holds or held one of its slots or stages; a member of the group of its current queue; a
    /// holder of req.view.department for a request of their department. The staff view needs req.view.internal as well.
    /// </summary>
    private static async Task<(bool Visible, bool Staff)> AccessAsync(BoundUser u, SqlTransaction? tx, RequestEngine.RequestRow r, Actor actor, CancellationToken ct)
    {
        var scope = await CompanyScope.OfAsync(u, ct, tx);
        var staff = actor.Permissions.Contains("req.view.internal") && actor.Permissions.Contains("req.view.all") && scope.Allows(r.CompanyId);
        if (staff) return (true, true);
        if (actor.UserId == r.RequesterUserId || actor.UserId == r.CreatedByUserId) return (true, false);
        var involved = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT CASE WHEN EXISTS (SELECT 1 FROM wfl.RequestApproval WHERE RequestId = @r AND (AssignedUserId = @u OR ActedByUserId = @u OR AssignedRoleId IN @roles))
                          OR EXISTS (SELECT 1 FROM wfl.RequestStageInstance WHERE RequestId = @r AND AssigneeUserId = @u)
                        THEN 1 ELSE 0 END;
            """, new { r = r.RequestId, u = actor.UserId, roles = actor.RoleIds.DefaultIfEmpty(-1).ToArray() }, tx, cancellationToken: ct));
        if (involved == 1 || await Delegations.SeesAsync(u.Connection, tx, r.RequestId, r.RequestTypeId, actor.UserId, Clock.GetUtcNow(), ct))
            return (true, actor.Permissions.Contains("req.view.internal") && scope.Allows(r.CompanyId));
        var inst = await RequestEngine.CurrentInstanceAsync(u.Connection, tx, r.RequestId, ct);
        if (inst is { Status: "QUEUED" } && scope.Allows(r.CompanyId)
            && (inst.PoolPermission is { } p ? actor.Permissions.Contains(p) : inst.AssigneeRoleId is { } role && actor.RoleIds.Contains(role)))
            return (true, actor.Permissions.Contains("req.view.internal"));
        if (actor.Permissions.Contains("req.view.department") && r.DepartmentId is { } d && await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM org.Department WHERE DepartmentId = @d AND HeadUserId = @u;", new { d, u = actor.UserId }, tx, cancellationToken: ct)) > 0)
            return (true, false);
        return (false, false);
    }

    // ---------- types ----------

    private static async Task<IResult> TypesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db);
        var actor = await ActorAsync(u, null, http.RequestAborted);
        var dept = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT DepartmentId FROM sec.AppUser WHERE AppUserId = @u;", new { u = u.UserId },
            cancellationToken: http.RequestAborted));
        var rows = await u.Connection.QueryAsync<(string Code, string NameAr, string NameEn, string Category, string? Description, bool Consumes)>(new CommandDefinition(
            """
            SELECT rt.Code, rt.NameAr, rt.NameEn, rt.Category, rt.Description, rt.ConsumesCreditLimit FROM wfl.RequestType AS rt
             WHERE rt.IsActive = 1 AND rt.Category <> 'CHILD'
               AND EXISTS (SELECT 1 FROM wfl.RequestTypeAudience AS a WHERE a.RequestTypeId = rt.RequestTypeId
                            AND ((a.SubjectKind = 'ROLE' AND a.RoleId IN @roles) OR (a.SubjectKind = 'USER' AND a.UserId = @u) OR (a.SubjectKind = 'DEPARTMENT' AND a.DepartmentId = @d)))
             ORDER BY rt.SortOrder, rt.Code;
            """, new { roles = actor.RoleIds.DefaultIfEmpty(-1).ToArray(), u = u.UserId, d = dept ?? -1 }, cancellationToken: http.RequestAborted));
        var canCreate = actor.Permissions.Contains("req.create");
        return Results.Ok(new
        {
            items = canCreate ? rows.Select(t => new { code = t.Code, nameAr = t.NameAr, nameEn = t.NameEn, category = t.Category, description = t.Description }) : [],
        });
    }

    // ---------- drafts ----------

    private static async Task<IResult> CreateAsync(NewRequestBody b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        if (string.IsNullOrWhiteSpace(b.Type) || b.Company is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the request type and the company.");
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await ActorAsync(u, tx, ct);
        var scope = await CompanyScope.OfAsync(u, ct, tx);
        var company = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT CompanyId FROM org.Company WHERE PublicId = @c AND Status <> 'ARCHIVED';", new { c = b.Company }, tx, cancellationToken: ct));
        if (company is null || !scope.Allows(company)) throw ApiProblemException.Invalid("COMPANY_NOT_FOUND", "The company does not exist or is outside your scope.");
        long? requester = null;
        if (b.Requester is { } rq)
            requester = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT AppUserId FROM sec.AppUser WHERE PublicId = @rq AND IsSystemUser = 0;",
                new { rq }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-REQ-02", "The requester is not an active user.");
        var draft = await RequestEngine.CreateDraftAsync(u.Connection, tx, actor, new NewRequest(b.Type.Trim(), company.Value, requester, b.Data?.GetRawText(),
            b.Priority, b.UrgentReason), clock.GetUtcNow(), ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REQUEST_CREATED", "TREASURY", "wfl.Request", draft.RequestId,
            AfterJson: JsonSerializer.Serialize(new { type = b.Type, draftRef = draft.DraftRef })), company, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/requests/{draft.PublicId}", new { id = draft.PublicId, draftRef = draft.DraftRef });
    }

    private static async Task<IResult> PatchAsync(Guid id, RequestFormBody b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await ActorAsync(u, tx, ct);
        var requestId = await IdOfAsync(u, tx, id, ct);
        var rv = await RequestEngine.UpdateFormAsync(u.Connection, tx, actor, requestId, expected, b.Data?.GetRawText(), ct);
        await tx.CommitAsync(ct);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    // ---------- actions ----------

    private static readonly string[] Actions = ["submit", "approve", "return", "reject", "complete", "resubmit", "cancel", "close", "claim", "release", "reassign", "substatus", "priority"];

    private static async Task<IResult> ActAsync(Guid id, string action, RequestActionBody b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        if (!Actions.Contains(action)) throw ApiProblemException.NotFound();
        var expected = ETags.Required(http.Request);
        var key = http.Request.Headers["Idempotency-Key"].ToString();
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        var rc = RequestContext.Of(http);
        ActResult result;
        await using (var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct))
        {
            var actor = await ActorAsync(u, tx, ct);
            var requestId = await IdOfAsync(u, tx, id, ct);
            var r = await RequestEngine.FindAsync(u.Connection, tx, requestId, false, ct) ?? throw ApiProblemException.NotFound();
            var (visible, _) = await AccessAsync(u, tx, r, actor, ct);
            if (!visible) throw ApiProblemException.NotFound();
            long? assignTo = b.AssignTo is { } who
                ? await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT AppUserId FROM sec.AppUser WHERE PublicId = @who;", new { who }, tx, cancellationToken: ct))
                  ?? throw ApiProblemException.Invalid("V-WFL-ASSIGNEE", "The user to assign is not known.")
                : null;
            result = await RequestEngine.ActAsync(u.Connection, tx, actor, requestId, new ActCommand(action, expected, b.Comment?.Trim(), b.InternalComment?.Trim(), b.ToStage,
                key.Length is > 0 and <= 100 ? key : null, rc.ClientIp, b.OverrideRequested == true, b.OverrideReason?.Trim(),
                b.AcknowledgeWarnings is { Length: > 0 } ack ? JsonSerializer.Serialize(ack) : null, assignTo, b.SubStatus?.Trim(), b.Priority?.Trim()), clock.GetUtcNow(), ct);
            if (!result.Replayed)
                await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REQUEST_" + action.ToUpperInvariant(), "TREASURY", "wfl.Request", requestId,
                    AfterJson: JsonSerializer.Serialize(new { status = result.Status, stage = result.StageKey, requestNo = result.RequestNo }),
                    Severity: action is "cancel" && !(actor.UserId == r.RequesterUserId || actor.UserId == r.CreatedByUserId) ? "HIGH" : "INFO"), r.CompanyId, ct);
            await tx.CommitAsync(ct);
        }
        var rv = await u.Connection.ExecuteScalarAsync<byte[]>(new CommandDefinition("SELECT RowVersion FROM wfl.Request WHERE PublicId = @id;", new { id }, cancellationToken: ct));
        ETags.Set(http.Response, rv ?? []);
        return Results.Ok(new { status = result.Status, requestNo = result.RequestNo, replayed = result.Replayed });
    }

    // ---------- reading ----------

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "view", "q", "status", "limit", "format");
        var csv = http.Request.Query["format"].ToString() switch { "" => false, "csv" => true, _ => throw ApiProblemException.Invalid("VALIDATION_FAILED", "The format is csv.") };
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        var actor = await ActorAsync(u, null, ct);
        var view = http.Request.Query["view"].ToString() is { Length: > 0 } v ? v : "mine";
        var q = http.Request.Query["q"].ToString();
        var scope = await CompanyScope.OfAsync(u, ct);
        var staff = actor.Permissions.Contains("req.view.all") && actor.Permissions.Contains("req.view.internal");
        var filter = view switch
        {
            "mine" => "(r.RequesterUserId = @u OR r.CreatedByUserId = @u)",
            // Waiting for me: a pending slot of mine, a stage held by me, or a queue I may take (FR-WFL-036).
            "tasks" => """
                       (EXISTS (SELECT 1 FROM wfl.RequestApproval AS a WHERE a.StageInstanceId = r.CurrentStageInstanceId AND a.Decision = 'PENDING'
                                 AND (a.AssignedUserId = @u OR (a.AssignedUserId IS NULL AND a.AssignedRoleId IN @roles)))
                        OR EXISTS (SELECT 1 FROM wfl.RequestStageInstance AS i WHERE i.RequestStageInstanceId = r.CurrentStageInstanceId AND i.ExitedAt IS NULL
                                    AND i.AssigneeUserId = @u)
                        OR EXISTS (SELECT 1 FROM wfl.RequestStageInstance AS i JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId
                                    LEFT JOIN sec.Permission AS p ON p.PermissionId = s.PoolPermissionId
                                    WHERE i.RequestStageInstanceId = r.CurrentStageInstanceId AND i.Status = 'QUEUED' AND s.Kind <> 'TERMINAL'
                                      AND (p.Code IN @perms OR s.AssigneeRoleId IN @roles) AND (@all = 1 OR r.CompanyId IN @scope))
                        OR (r.Status = 'AWAITING_CLOSE' AND @close = 1 AND (@all = 1 OR r.CompanyId IN @scope)))
                       """,
            "all" when staff => "(@all = 1 OR r.CompanyId IN @scope)",
            _ => throw ApiProblemException.Invalid("VALIDATION_FAILED", "The view is mine, tasks or all."),
        };
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT TOP (@take) r.PublicId AS id, r.DraftRef AS draftRef, r.RequestNo AS requestNo, rt.Code AS type, rt.NameAr AS typeNameAr, rt.NameEn AS typeNameEn,
                   r.Title AS title, r.Amount AS amount, cur.Code AS currency, ph.Code AS phase, ph.NameAr AS phaseNameAr, ph.NameEn AS phaseNameEn, r.Status AS status,
                   r.Priority AS priority, r.CreatedAt AS createdAt, r.UpdatedAt AS updatedAt, co.NameAr AS companyNameAr, co.NameEn AS companyNameEn,
                   CASE WHEN @staff = 1 THEN s.StageKey END AS stage, CASE WHEN @staff = 1 THEN r.DueAt END AS dueAt, CASE WHEN @staff = 1 THEN r.SlaState END AS slaState
              FROM wfl.Request AS r
              JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
              JOIN wfl.ExternalPhase AS ph ON ph.ExternalPhaseId = r.ExternalPhaseId
              JOIN org.Company AS co ON co.CompanyId = r.CompanyId
              LEFT JOIN ref.Currency AS cur ON cur.CurrencyId = r.CurrencyId
              LEFT JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = r.CurrentStageId
             WHERE {filter} AND (@q = '' OR r.SearchText LIKE '%' + @nq + '%' OR r.RequestNo = @q OR r.DraftRef = @q)
             ORDER BY r.UpdatedAt DESC, r.RequestId DESC;
            """,
            new
            {
                u = u.UserId, roles = actor.RoleIds.DefaultIfEmpty(-1).ToArray(), perms = actor.Permissions.DefaultIfEmpty("-").ToArray(), all = scope.All, scope = scope.SqlIds,
                close = actor.Permissions.Contains("req.treasury.close"), staff, q, nq = Normalizer.Name(q), take = csv ? 5000 : 200,
            }, cancellationToken: ct));
        if (!csv) return Results.Ok(new { items = rows });
        // FR-REQ-026: the same list as a CSV file, at most 5,000 rows, audited; the treasury's columns only for its staff.
        string[] cols = staff
            ? ["requestNo", "draftRef", "type", "title", "companyNameEn", "amount", "currency", "phase", "status", "stage", "slaState", "dueAt", "createdAt", "updatedAt"]
            : ["requestNo", "draftRef", "type", "title", "companyNameEn", "amount", "currency", "phase", "createdAt", "updatedAt"];
        var text = new System.Text.StringBuilder(string.Join(',', cols)).Append("\r\n");
        var count = 0;
        foreach (IDictionary<string, object?> row in rows)
        {
            count++;
            text.AppendJoin(',', cols.Select(c => CsvField(row.TryGetValue(c, out var v) ? v : null))).Append("\r\n");
        }
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("REQUESTS_EXPORTED", "TREASURY", "wfl.Request", null,
            AfterJson: JsonSerializer.Serialize(new { view, q, rows = count })), null, ct);
        return Results.File(System.Text.Encoding.UTF8.GetPreamble().Concat(System.Text.Encoding.UTF8.GetBytes(text.ToString())).ToArray(), "text/csv; charset=utf-8",
            $"requests-{view}.csv");
    }

    /// <summary>
    /// FR-REQ-025: a visible request of a top-level type copied into a new draft of the user, with req.create and the
    /// type's audience: the requester's fields and the terms, never the treasury's fields, the attachments or the references.
    /// </summary>
    private static async Task<IResult> CopyAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await ActorAsync(u, tx, ct);
        if (!actor.Permissions.Contains("req.create")) throw ApiProblemException.Forbidden();
        var r = await RequestEngine.FindAsync(u.Connection, tx, await IdOfAsync(u, tx, id, ct), false, ct) ?? throw ApiProblemException.NotFound();
        if (!(await AccessAsync(u, tx, r, actor, ct)).Visible) throw ApiProblemException.NotFound();
        var (requestId, publicId) = await BankFas.Data.Lc.ProformaStore.CopyRequestAsync(u.Connection, tx, actor, r.RequestId, Clock.GetUtcNow(), ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REQUEST_COPIED", "TREASURY", "wfl.Request", requestId,
            AfterJson: JsonSerializer.Serialize(new { from = id, type = r.TypeCode })), r.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/requests/{publicId}", new { id = publicId });
    }

    /// <summary>A CSV field; text that starts with =, +, - or @ is prefixed with ' so a spreadsheet never runs it as a formula.</summary>
    private static string CsvField(object? v)
    {
        var s = v switch
        {
            null => "",
            DateTime d => d.ToString("O", System.Globalization.CultureInfo.InvariantCulture),
            IFormattable x => x.ToString(null, System.Globalization.CultureInfo.InvariantCulture),
            _ => v.ToString() ?? "",
        };
        if (s.Length == 0) return "";
        if (v is string && s[0] is '=' or '+' or '-' or '@') s = "'" + s;
        return "\"" + s.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        var actor = await ActorAsync(u, null, ct);
        var requestId = await IdOfAsync(u, null, id, ct);
        var r = await RequestEngine.FindAsync(u.Connection, null, requestId, false, ct) ?? throw ApiProblemException.NotFound();
        var (visible, staff) = await AccessAsync(u, null, r, actor, ct);
        if (!visible) throw ApiProblemException.NotFound();
        var inst = await RequestEngine.CurrentInstanceAsync(u.Connection, null, requestId, ct);
        var head = await u.Connection.QuerySingleAsync(new CommandDefinition(
            """
            SELECT rt.Code AS type, rt.NameAr AS typeNameAr, rt.NameEn AS typeNameEn, rt.ParentEntityType AS parentEntityType, ph.Code AS phase, ph.NameAr AS phaseNameAr, ph.NameEn AS phaseNameEn,
                   ph.RequiresRequesterAction AS awaitingYou, co.PublicId AS company, co.NameAr AS companyNameAr, co.NameEn AS companyNameEn, r.Priority AS priority,
                   r.SubmittedAt AS submittedAt, r.CompletedAt AS completedAt, r.OutcomeReason AS outcomeReason, r.CycleNo AS cycleNo, r.RequiredByDate AS requiredByDate,
                   r.CounterpartyName AS counterpartyName, r.CounterpartyCode AS counterpartyCode, req.PublicId AS requester, req.DisplayNameEn AS requesterNameEn,
                   req.DisplayNameAr AS requesterNameAr, (SELECT MAX(EnteredAt) FROM wfl.RequestStageInstance AS i JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId
                                                          WHERE i.RequestId = r.RequestId AND s.ExternalPhaseId = r.ExternalPhaseId) AS phaseSince
              FROM wfl.Request AS r
              JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
              JOIN wfl.ExternalPhase AS ph ON ph.ExternalPhaseId = r.ExternalPhaseId
              JOIN org.Company AS co ON co.CompanyId = r.CompanyId
              JOIN sec.AppUser AS req ON req.AppUserId = r.RequesterUserId
             WHERE r.RequestId = @id;
            """, new { id = requestId }, cancellationToken: ct));
        var fields = await RequestEngine.FieldsAsync(u.Connection, null, r.TemplateId, ct);
        using var formDoc = JsonDocument.Parse(r.FormDataJson ?? "{}");
        // The requester sees the form without the treasury's own fields (the allocation, FR-REQ-013).
        var hidden = staff ? [] : fields.Where(f => f.DataType is "LIMIT_SELECTION").Select(f => f.FieldKey).ToHashSet();
        var form = formDoc.RootElement.EnumerateObject().Where(p => !hidden.Contains(p.Name)).ToDictionary(p => p.Name, p => p.Value.Clone());
        var comments = await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT c.RequestCommentId AS n, c.Visibility AS visibility, CASE WHEN c.RetractedAt IS NULL THEN c.Body END AS body, c.CreatedAt AS at,
                   a.DisplayNameEn AS authorEn, a.DisplayNameAr AS authorAr, CASE WHEN c.RetractedAt IS NULL THEN 0 ELSE 1 END AS retracted
              FROM wfl.RequestComment AS c JOIN sec.AppUser AS a ON a.AppUserId = c.AuthorUserId
             WHERE c.RequestId = @id {(staff ? "" : "AND c.Visibility = 'REQUESTER_VISIBLE'")} ORDER BY c.CreatedAt;
            """, new { id = requestId }, cancellationToken: ct));
        var attachments = await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT d.PublicId AS document, d.Title AS title, a.SlotKey AS slot, a.Visibility AS visibility, a.CreatedAt AS at
              FROM wfl.RequestAttachment AS a JOIN doc.Document AS d ON d.DocumentId = a.DocumentId
             WHERE a.RequestId = @id AND a.IsActive = 1 {(staff ? "" : "AND a.Visibility = 'REQUESTER_VISIBLE'")} ORDER BY a.CreatedAt;
            """, new { id = requestId }, cancellationToken: ct));
        var timeline = await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT a.ActionType AS action, a.OccurredAt AS at, a.Comment AS comment, a.CycleNo AS cycle
                   {(staff ? ", a.FromStageKey AS fromStage, a.ToStageKey AS toStage, u.DisplayNameEn AS actorEn, u.DisplayNameAr AS actorAr, a.IsSodException AS sodException" : "")}
              FROM wfl.RequestAction AS a LEFT JOIN sec.AppUser AS u ON u.AppUserId = a.ActorUserId
             WHERE a.RequestId = @id {(staff ? "" : "AND a.Visibility = 'REQUESTER_VISIBLE'")} ORDER BY a.OccurredAt, a.RequestActionId;
            """, new { id = requestId }, cancellationToken: ct));
        var approvals = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT a.SlotKey AS slot, a.Decision AS decision, a.ActedAt AS at, a.CycleNo AS cycle, a.Source AS source,
                   CASE WHEN a.AssignedUserId = @me OR (a.AssignedUserId IS NULL AND a.AssignedRoleId IN @roles) THEN 1 ELSE 0 END AS mine
              FROM wfl.RequestApproval AS a WHERE a.StageInstanceId = @i ORDER BY a.SlotKey;
            """, new { i = r.CurrentStageInstanceId ?? -1, me = u.UserId, roles = actor.RoleIds.DefaultIfEmpty(-1).ToArray() }, cancellationToken: ct));
        var mine = actor.UserId == r.RequesterUserId || actor.UserId == r.CreatedByUserId;
        var editable = mine && (r.Status == "DRAFT" || inst?.StageKey == "RETURNED");
        var actions = new List<string>();
        if (inst is not null && r.Status is "DRAFT" or "ACTIVE")
        {
            if (mine && inst.Kind == "DRAFT") actions.Add("submit");
            if (mine && inst.StageKey == "RETURNED") actions.Add("resubmit");
            if (inst.Kind == "APPROVAL" && (approvals.Any(a => (int)a.mine == 1 && (string)a.decision == "PENDING")
                    || (!mine && await Delegations.SeesAsync(u.Connection, null, r.RequestId, r.RequestTypeId, actor.UserId, Clock.GetUtcNow(), ct))))
                actions.AddRange(["approve", "return", "reject"]);
            var eligible = inst.PoolPermission is { } pool ? actor.Permissions.Contains(pool)
                : inst.AssigneeRoleId is { } ar ? actor.RoleIds.Contains(ar) : actor.Permissions.Contains("req.claim");
            if (inst.Status == "QUEUED" && inst.Kind != "TERMINAL" && eligible) actions.Add("claim");
            if (inst.Status == "CLAIMED" && inst.AssigneeUserId == actor.UserId && inst.Kind is "TASK" or "TREASURY_QUEUE" && inst.StageKey != "RETURNED")
            {
                actions.Add("complete");
                if (inst.AllowReturn) actions.Add("return");
                if (inst.Kind == "TREASURY_QUEUE" || inst.AssigneeRule == "CLAIMER") actions.Add("release");
            }
            if ((mine && (r.Status == "DRAFT" || inst.AllowRequesterCancel)) || actor.Permissions.Contains("req.cancel.any")) actions.Add("cancel");
        }
        if (r.Status == "AWAITING_CLOSE" && staff && actor.Permissions.Contains("req.treasury.close")) actions.Add("close");
        var formFields = fields.Where(f => !hidden.Contains(f.FieldKey)).Select(f => new
        {
            key = f.FieldKey, labelAr = f.LabelAr, labelEn = f.LabelEn, type = f.DataType, required = f.IsRequired,
            editable = editable && f.DataType is not ("LIMIT_SELECTION" or "MODULE_FORM" or "EXTERNAL_REF" or "FILE_SLOT")
                       && (f.EditableStagesJson is null || f.EditableStagesJson.Contains("\"" + (inst?.StageKey ?? "") + "\"", StringComparison.Ordinal)),
            config = f.ConfigJson is null ? (JsonElement?)null : JsonDocument.Parse(f.ConfigJson).RootElement.Clone(),
        });
        var common = new
        {
            actions, fields = formFields,
            id = r.PublicId, draftRef = r.DraftRef, requestNo = r.RequestNo, status = PublicStatus(r.Status, staff), title = r.Title, amount = r.Amount, currency = r.CurrencyCode,
            head, form, comments, attachments, timeline,
            myApprovals = approvals.Where(a => (int)a.mine == 1).Select(a => new { slot = (string)a.slot, decision = (string)a.decision }),
        };
        ETags.Set(http.Response, r.RowVersion);
        if (!staff) return Results.Ok(new { view = "REQUESTER", request = common });
        var staffPart = await u.Connection.QuerySingleAsync(new CommandDefinition(
            """
            SELECT s.StageKey AS stage, s.NameAr AS stageNameAr, s.NameEn AS stageNameEn, s.Kind AS stageKind, r.SubStatusKey AS subStatus, r.DueAt AS dueAt,
                   r.SlaState AS slaState, r.QueueEnteredAt AS queueEnteredAt, r.ReservationState AS reservationState, r.ReservedAmount AS reservedAmount,
                   asg.PublicId AS assignee, asg.DisplayNameEn AS assigneeNameEn, asg.DisplayNameAr AS assigneeNameAr, t.TemplateKey AS templateKey, t.VersionNo AS templateVersion,
                   r.HasSodException AS sodException
              FROM wfl.Request AS r
              JOIN wfl.WorkflowTemplate AS t ON t.WorkflowTemplateId = r.TemplateId
              LEFT JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = r.CurrentStageId
              LEFT JOIN sec.AppUser AS asg ON asg.AppUserId = r.AssigneeUserId
             WHERE r.RequestId = @id;
            """, new { id = requestId }, cancellationToken: ct));
        return Results.Ok(new { view = "STAFF", request = common, staff = staffPart, approvals, instance = inst is null ? null : new { status = inst.Status, cycle = inst.CycleNo } });
    }

    /// <summary>The requester sees "in progress" until the treasury closes the request (BR-WFL-027).</summary>
    private static string PublicStatus(string status, bool staff) => !staff && status == "AWAITING_CLOSE" ? "ACTIVE" : status;

    // ---------- comments, attachments, external references ----------

    private static async Task<(RequestEngine.RequestRow R, Actor Actor, bool Staff)> VisibleForWriteAsync(BoundUser u, SqlTransaction tx, Guid id, CancellationToken ct)
    {
        var actor = await ActorAsync(u, tx, ct);
        var requestId = await IdOfAsync(u, tx, id, ct);
        var r = await RequestEngine.FindAsync(u.Connection, tx, requestId, true, ct) ?? throw ApiProblemException.NotFound();
        var (visible, staff) = await AccessAsync(u, tx, r, actor, ct);
        if (!visible) throw ApiProblemException.NotFound();
        if (r.Status is "COMPLETED" or "REJECTED" or "CANCELLED") throw new ApiProblemException(409, "INVALID_STATE", "The request is closed.");
        return (r, actor, staff);
    }

    /// <summary>A comment (FR-REQ-017): plain text up to 4,000 characters; an internal one needs req.comment.internal and never reaches the requester.</summary>
    private static async Task<IResult> CommentAsync(Guid id, RequestCommentBody b, HttpContext http, SqlConnectionFactory db)
    {
        var body = b.Body?.Trim();
        if (string.IsNullOrEmpty(body) || body.Length > 4000 || body.Contains('<', StringComparison.Ordinal))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "A comment is plain text of up to 4,000 characters.");
        var visibility = b.Visibility is "INTERNAL" ? "INTERNAL" : "REQUESTER_VISIBLE";
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var (r, actor, staff) = await VisibleForWriteAsync(u, tx, id, ct);
        if (!actor.Permissions.Contains("req.comment")) throw ApiProblemException.Forbidden();
        if (visibility == "INTERNAL" && (!staff || !actor.Permissions.Contains("req.comment.internal"))) throw ApiProblemException.Forbidden();
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT wfl.RequestComment (TenantId, RequestId, StageInstanceId, Visibility, Body, AuthorUserId, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @vis, @body, @u, @u);
            INSERT wfl.RequestAction (TenantId, RequestId, StageInstanceId, CycleNo, ActionType, ActorType, ActorUserId, OccurredAt, Visibility, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, 'COMMENT_ADDED', 'USER', @u, SYSUTCDATETIME(), @vis, @u);
            """, new { r = r.RequestId, i = r.CurrentStageInstanceId, vis = visibility, body, u = u.UserId, cycle = r.CycleNo }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/requests/{id}", new { visibility });
    }

    /// <summary>
    /// An attachment (FR-REQ-006, FR-WFL-024, 025): a stored document of the request's company in a slot of the template;
    /// it is visible to the requester when the slot says so or the requester attached it. A DocumentLink records the use.
    /// </summary>
    private static async Task<IResult> AttachAsync(Guid id, RequestAttachmentBody b, HttpContext http, SqlConnectionFactory db)
    {
        if (b.Document is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the document.");
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var (r, actor, _) = await VisibleForWriteAsync(u, tx, id, ct);
        var doc = await u.Connection.QuerySingleOrDefaultAsync<(long Id, int TypeId)?>(new CommandDefinition(
            "SELECT DocumentId, DocumentTypeId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE' AND (OwnerCompanyId IS NULL OR OwnerCompanyId = @c);",
            new { d = b.Document, c = r.CompanyId }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("DOCUMENT_NOT_FOUND", "The document is not a stored document of the company.");
        bool visibleToRequester = actor.UserId == r.RequesterUserId || actor.UserId == r.CreatedByUserId;
        if (b.Slot is { } slot)
        {
            var rule = await u.Connection.QuerySingleOrDefaultAsync<(int DocumentTypeId, int? MaxCount, bool Visible)?>(new CommandDefinition(
                "SELECT DocumentTypeId, MaxCount, VisibleToRequester FROM wfl.TemplateAttachmentRule WHERE TemplateId = @t AND SlotKey = @slot;",
                new { t = r.TemplateId, slot }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-REQ-SLOT", "The template has no such attachment slot.");
            if (rule.DocumentTypeId != doc.TypeId) throw ApiProblemException.Invalid("V-REQ-SLOT-TYPE", "The document is not of the type this slot takes.");
            var count = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM wfl.RequestAttachment WHERE RequestId = @r AND SlotKey = @slot AND IsActive = 1;", new { r = r.RequestId, slot }, tx, cancellationToken: ct));
            if (rule.MaxCount is { } max && count >= max) throw ApiProblemException.Invalid("V-REQ-SLOT-FULL", "The slot holds no more documents.");
            visibleToRequester |= rule.Visible;
        }
        try
        {
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT wfl.RequestAttachment (TenantId, RequestId, DocumentId, SlotKey, StageInstanceId, Visibility, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @d, @slot, @i, @vis, @u);
                IF NOT EXISTS (SELECT 1 FROM doc.DocumentLink WHERE DocumentId = @d AND EntityType = 'wfl.Request' AND EntityId = @r AND LinkRole = 'ATTACHMENT' AND UnlinkedAt IS NULL)
                    INSERT doc.DocumentLink (TenantId, DocumentId, EntityType, EntityId, LinkRole, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @d, 'wfl.Request', @r, 'ATTACHMENT', @u);
                INSERT wfl.RequestAction (TenantId, RequestId, StageInstanceId, CycleNo, ActionType, ActorType, ActorUserId, OccurredAt, Visibility, MetaJson, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, 'ATTACHMENT_ADDED', 'USER', @u, SYSUTCDATETIME(), @vis, @meta, @u);
                """,
                new
                {
                    r = r.RequestId, d = doc.Id, slot = b.Slot, i = r.CurrentStageInstanceId, vis = visibleToRequester ? "REQUESTER_VISIBLE" : "INTERNAL", u = u.UserId,
                    cycle = r.CycleNo, meta = JsonSerializer.Serialize(new { slot = b.Slot }),
                }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "DUPLICATE", "The document is already attached.");
        }
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/requests/{id}", new { slot = b.Slot });
    }

    /// <summary>An external reference (FR-REQ-010, BR-REQ-006): free text kept as entered and normalised for search; a new value for the same system and type replaces the active one and keeps it.</summary>
    private static async Task<IResult> ExternalRefAsync(Guid id, RequestExternalRefBody b, HttpContext http, SqlConnectionFactory db)
    {
        var system = b.SystemCode?.Trim();
        var type = b.RefType?.Trim();
        var value = b.Value?.Trim();
        if (string.IsNullOrEmpty(system) || string.IsNullOrEmpty(type) || string.IsNullOrEmpty(value) || system.Length > 40 || type.Length > 60 || value.Length > 100)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the system, the kind and the value of the reference.");
        var normalised = NormaliseRef(value);
        if (normalised.Length == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The reference has no letters or digits.");
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var (r, actor, _) = await VisibleForWriteAsync(u, tx, id, ct);
        if (!actor.Permissions.Contains("req.extref.edit")) throw ApiProblemException.Forbidden();
        var stage = (await RequestEngine.CurrentInstanceAsync(u.Connection, tx, r.RequestId, ct))?.StageKey;
        var newId = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT wfl.RequestExternalRef (TenantId, RequestId, SystemCode, RefType, RefValue, NormalizedValue, EnteredAtStageKey, IsActive, EnteredBy, CreatedBy)
            OUTPUT inserted.RequestExternalRefId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @system, @type, @value, @norm, @stage, 1, @u, @u);
            DECLARE @new BIGINT = (SELECT Id FROM @o);
            UPDATE wfl.RequestExternalRef SET IsActive = 0, SupersededById = @new
             WHERE RequestId = @r AND SystemCode = @system AND RefType = @type AND IsActive = 1 AND RequestExternalRefId <> @new;
            INSERT wfl.RequestAction (TenantId, RequestId, StageInstanceId, CycleNo, ActionType, ActorType, ActorUserId, OccurredAt, Visibility, MetaJson, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, CASE WHEN @@ROWCOUNT > 0 THEN 'EXTREF_CHANGED' ELSE 'EXTREF_ADDED' END, 'USER', @u,
                    SYSUTCDATETIME(), 'REQUESTER_VISIBLE', @meta, @u);
            SELECT @new;
            """,
            new
            {
                r = r.RequestId, system, type, value, norm = normalised, stage, u = u.UserId, i = r.CurrentStageInstanceId, cycle = r.CycleNo,
                meta = JsonSerializer.Serialize(new { system, type }),
            }, tx, cancellationToken: ct));
        // V-REQ-04: the same reference on another active request is a warning, not a refusal.
        var duplicate = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT COUNT(*) FROM wfl.RequestExternalRef AS e JOIN wfl.Request AS o ON o.RequestId = e.RequestId
             WHERE e.SystemCode = @system AND e.RefType = @type AND e.NormalizedValue = @norm AND e.IsActive = 1 AND e.RequestId <> @r
               AND o.Status IN ('DRAFT', 'ACTIVE', 'AWAITING_CLOSE');
            """, new { system, type, norm = normalised, r = r.RequestId }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/requests/{id}", new { warning = duplicate > 0 ? "V-REQ-04" : null, normalised, id = newId });
    }

    // ---------- the availability panel and the allocation (FR-REQ-013, FR-FAC-021, FR-FAC-031) ----------

    /// <summary>
    /// The staff panel of a request: the lines and limits of the company's active facilities with what is available to it
    /// now, without the request's own reservation (BR-FAC-014), the allocated one marked. The requester gets 404 (AC-WFL-9).
    /// </summary>
    private static async Task<IResult> AvailabilityAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        var actor = await ActorAsync(u, null, ct);
        var requestId = await IdOfAsync(u, null, id, ct);
        var r = await RequestEngine.FindAsync(u.Connection, null, requestId, false, ct) ?? throw ApiProblemException.NotFound();
        var (visible, staff) = await AccessAsync(u, null, r, actor, ct);
        if (!visible || !staff || !actor.Permissions.Contains("fac.view")) throw ApiProblemException.NotFound();
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var allocated = await u.Connection.QuerySingleOrDefaultAsync<(long? FacilityId, long? LimitRoot, long? LineRoot)>(new CommandDefinition(
            """
            SELECT r.FacilityId, l.RootId, pl.RootId FROM wfl.Request AS r LEFT JOIN fac.Limit AS l ON l.LimitId = r.LimitId
              LEFT JOIN fac.LimitProductLine AS pl ON pl.LimitProductLineId = r.LimitProductLineId WHERE r.RequestId = @r;
            """, new { r = requestId }, cancellationToken: ct));
        var facilities = await u.Connection.QueryAsync<(long FacilityId, Guid PublicId, string? FacilityNo, int Rev, decimal Total, string Currency)>(new CommandDefinition(
            """
            SELECT f.FacilityId, f.PublicId, ISNULL(f.PlatformRef, f.FacilityNo) AS FacilityNo, f.ApprovedRevisionNo, f.TotalAmount, c.Code FROM fac.Facility AS f JOIN ref.Currency AS c ON c.CurrencyId = f.CurrencyId
             WHERE f.LifecycleStatus = 'ACTIVE' AND f.ApprovedRevisionNo > 0 AND (f.BorrowerCompanyId = @co OR f.FacilityId = @fac);
            """, new { co = r.CompanyId, fac = allocated.FacilityId ?? -1 }, cancellationToken: ct));
        var items = new List<object>();
        foreach (var f in facilities)
        {
            var rows = await BankFas.Data.Facilities.FacilityTreeStore.LoadAsync(u.Connection, null, f.FacilityId, f.Rev, ct);
            var tree = rows.Tree(f.Total, today);
            var exposures = await BankFas.Data.Facilities.FacilityTreeStore.ExposuresAsync(u.Connection, null, f.FacilityId, ct);
            foreach (var l in rows.Limits.Where(l => tree.Eligible(l.RootId, r.CompanyId)))
            {
                var lines = rows.Lines.Where(x => x.LimitRootId == l.RootId && x.IsActive).ToList();
                foreach (var line in lines.Count == 0 ? [null] : lines.Cast<BankFas.Data.Facilities.LineRow?>())
                {
                    var a = tree.Available(l.RootId, line?.RootId, r.CompanyId, exposures, requestId);
                    items.Add(new
                    {
                        facility = f.PublicId, facilityNo = f.FacilityNo, limit = refs.ItemRef(u.TenantId, "limit", l.RootId), limitCode = l.Code, limitNameAr = l.NameAr,
                        limitNameEn = l.NameEn, line = line is null ? null : refs.ItemRef(u.TenantId, "line", line.RootId), product = line?.ProductCode, currency = f.Currency,
                        cap = a.Cap, used = a.Used, reservedForOthers = a.ReservedForOthers, available = Math.Max(0, a.Avail), reason = a.Reason,
                        allocated = allocated.FacilityId == f.FacilityId && allocated.LimitRoot == l.RootId && allocated.LineRoot == line?.RootId,
                    });
                }
            }
        }
        decimal? exposure = null;
        if (r.TypeCode == "PURCHASE_LC" && await BankFas.Data.Lc.TermsStore.CurrentAsync(u.Connection, null, requestId, ct) is { } t)
            exposure = await LcTermsEndpoints.ExposureAsync(u.Connection, null, t, ct);
        return Results.Ok(new { exposureAmount = exposure ?? r.Amount, currency = r.CurrencyCode, items });
    }

    /// <summary>The facility selection (FR-REQ-013): the claimer of the stage that edits the LIMIT_SELECTION field chooses a limit or line of the company's facility.</summary>
    private static async Task<IResult> AllocateAsync(Guid id, RequestAllocationBody b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        if (b.Facility is null || (b.Limit is null && b.Line is null)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the facility and its limit or line.");
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var (r, actor, staff) = await VisibleForWriteAsync(u, tx, id, ct);
        if (!staff || !actor.Permissions.Contains("req.facility.select")) throw ApiProblemException.Forbidden();
        var inst = await RequestEngine.CurrentInstanceAsync(u.Connection, tx, r.RequestId, ct) ?? throw ApiProblemException.NotFound();
        var fields = await RequestEngine.FieldsAsync(u.Connection, tx, r.TemplateId, ct);
        if (!fields.Any(f => f.DataType == "LIMIT_SELECTION" && f.EditableStagesJson?.Contains("\"" + inst.StageKey + "\"", StringComparison.Ordinal) == true))
            throw new ApiProblemException(409, "INVALID_STATE", "The facility is chosen at the facility selection stage.");
        if (inst.Status != "CLAIMED" || inst.AssigneeUserId != u.UserId) throw new ApiProblemException(409, "INVALID_STATE", "Claim the request first (BR-WFL-007).");
        var f = await u.Connection.QuerySingleOrDefaultAsync<(long FacilityId, int Rev, decimal Total)?>(new CommandDefinition(
            "SELECT FacilityId, ApprovedRevisionNo, TotalAmount FROM fac.Facility WHERE PublicId = @f AND LifecycleStatus = 'ACTIVE';", new { f = b.Facility }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("V-REQ-ALLOCATION", "The facility is not an active facility.");
        var rows = await BankFas.Data.Facilities.FacilityTreeStore.LoadAsync(u.Connection, tx, f.FacilityId, f.Rev, ct);
        var lineRoot = refs.ItemId(u.TenantId, "line", b.Line);
        var line = lineRoot is null ? null : rows.Lines.FirstOrDefault(x => x.RootId == lineRoot && x.IsActive)
            ?? throw ApiProblemException.Invalid("V-REQ-ALLOCATION", "The line is not a line of the approved facility.");
        var limitRoot = line?.LimitRootId ?? refs.ItemId(u.TenantId, "limit", b.Limit);
        var limit = rows.Limits.FirstOrDefault(x => x.RootId == limitRoot) ?? throw ApiProblemException.Invalid("V-REQ-ALLOCATION", "The limit is not a limit of the approved facility.");
        if (!rows.Tree(f.Total, clock.GetUtcNow().UtcDateTime.Date).Eligible(limit.RootId, r.CompanyId))
            throw ApiProblemException.Invalid("COMPANY_EXCLUDED", "The company may not use this limit (BR-FAC-012).");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.Request SET FacilityId = @f, LimitId = @l, LimitProductLineId = @ln, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE RequestId = @r;
            INSERT wfl.RequestAction (TenantId, RequestId, StageInstanceId, CycleNo, ActionType, ActorType, ActorUserId, OccurredAt, Visibility, MetaJson, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, 'FIELD_EDITED', 'USER', @u, SYSUTCDATETIME(), 'INTERNAL', @meta, @u);
            """,
            new
            {
                f = f.FacilityId, l = limit.LimitId, ln = line?.LimitProductLineId, u = u.UserId, r = r.RequestId, i = r.CurrentStageInstanceId, cycle = r.CycleNo,
                meta = JsonSerializer.Serialize(new { allocation = new { facility = f.FacilityId, limit = limit.Code, product = line?.ProductCode } }),
            }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        var rv = await u.Connection.ExecuteScalarAsync<byte[]>(new CommandDefinition("SELECT RowVersion FROM wfl.Request WHERE PublicId = @id;", new { id }, cancellationToken: ct));
        ETags.Set(http.Response, rv ?? []);
        return Results.Ok(new { limitCode = limit.Code, product = line?.ProductCode });
    }

    /// <summary>BR-REQ-006: trimmed, Arabic-Indic digits as 0-9, Latin letters in capitals, without spaces and dashes.</summary>
    public static string NormaliseRef(string value)
    {
        var b = new System.Text.StringBuilder(value.Length);
        foreach (var ch in value.Normalize(System.Text.NormalizationForm.FormKC))
        {
            if (ch is >= '٠' and <= '٩') b.Append((char)('0' + (ch - '٠')));
            else if (ch is >= '۰' and <= '۹') b.Append((char)('0' + (ch - '۰')));
            else if (char.IsAsciiLetterOrDigit(ch)) b.Append(char.ToUpperInvariant(ch));
            else if (char.IsWhiteSpace(ch) || ch is '-' or '_' or '/' or '.') continue;
            else b.Append(ch);
        }
        return b.ToString();
    }
}

using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record DelegationBody(Guid? From, Guid To, DateOnly StartsOn, DateOnly EndsOn, string? Scope, string? RequestType, string? Reason);

/// <summary>
/// The unified inbox (FR-WFL-036, BR-REQ-016; S3 batch C) and the delegations (FR-WFL-020, BR-WFL-021). The inbox is one
/// query per list, with its counters: the approvals waiting for the user (their own slots, a role of theirs, and the
/// slots of whoever delegated to them in the period, marked onBehalfOf), the tasks they hold, the queue they may claim
/// (urgent first, then the oldest, BR-REQ-011), and their own requests waiting for them. Every list is within the
/// user's company scope.
/// </summary>
public static class InboxEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/inbox", InboxAsync);
        api.MapGet("/delegations", DelegationsAsync);
        api.MapPost("/delegations", DelegateAsync);
        api.MapPost("/delegations/{id:guid}/revoke", RevokeAsync);
        api.MapGet("/delegations/people", PeopleAsync);
    }

    /// <summary>The active users to pick as a delegate or an assignee, by name or e-mail (20 at most); for holders of the delegation or reassignment permissions.</summary>
    private static async Task<IResult> PeopleAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "q");
        await using var u = await RequestEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var perms = await u.PermissionsAsync(ct);
        if (!perms.Contains("req.delegate.own") && !perms.Contains("req.delegate.manage") && !perms.Contains("req.reassign")) throw ApiProblemException.Forbidden();
        var q = http.Request.Query["q"].ToString() is { Length: > 0 } qq
            ? "%" + qq.Replace("[", "[[]", StringComparison.Ordinal).Replace("%", "[%]", StringComparison.Ordinal).Replace("_", "[_]", StringComparison.Ordinal) + "%" : null;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT TOP (20) PublicId AS id, DisplayNameEn AS displayNameEn, DisplayNameAr AS displayNameAr FROM sec.AppUser
             WHERE IsSystemUser = 0 AND ArchivedAt IS NULL AND Status = 'ACTIVE' AND AppUserId <> @me
               AND (@q IS NULL OR Email LIKE @q OR DisplayNameEn LIKE @q OR DisplayNameAr LIKE @q)
             ORDER BY DisplayNameEn;
            """, new { q, me = u.UserId }, cancellationToken: ct));
        return Results.Ok(new { items = rows });
    }

    private sealed class Item
    {
        public Guid Id { get; init; }
        public string? RequestNo { get; init; }
        public string DraftRef { get; init; } = "";
        public string? Title { get; init; }
        public string Type { get; init; } = "";
        public string Stage { get; init; } = "";
        public string Priority { get; init; } = "NORMAL";
        public DateTime? DueAt { get; init; }
        public string SlaState { get; init; } = "NONE";
        public DateTime EnteredAt { get; init; }
        public DateTime? QueuedAt { get; init; }
        public long CompanyId { get; init; }
        public long? OnBehalfOf { get; init; }
        public int? RoleId { get; init; }
        public string? PoolPermission { get; init; }
    }

    private const string Columns = """
        r.PublicId AS Id, r.RequestNo, r.DraftRef, r.Title, rt.Code AS Type, s.StageKey AS Stage, r.Priority, i.DueAt, i.SlaState, i.EnteredAt, i.QueuedAt, r.CompanyId
        """;

    private static async Task<IResult> InboxAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request);
        await using var u = await RequestEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var actor = await RequestEndpoints.ActorAsync(u, null, ct);
        var scope = await CompanyScope.OfAsync(u, ct);
        var today = await Delegations.TodayAsync(u.Connection, null, clock.GetUtcNow(), ct);
        var roles = actor.RoleIds.DefaultIfEmpty(-1).ToArray();
        var approvals = (await u.Connection.QueryAsync<Item>(new CommandDefinition(
            $"""
            SELECT {Columns}, CAST(NULL AS BIGINT) AS OnBehalfOf, a.AssignedRoleId AS RoleId, CAST(NULL AS VARCHAR(100)) AS PoolPermission
              FROM wfl.RequestApproval AS a JOIN wfl.RequestStageInstance AS i ON i.RequestStageInstanceId = a.StageInstanceId AND i.ExitedAt IS NULL
              JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId JOIN wfl.Request AS r ON r.RequestId = a.RequestId
              JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
             WHERE a.Decision = 'PENDING' AND (a.AssignedUserId = @u OR (a.AssignedUserId IS NULL AND a.AssignedRoleId IN @roles))
               AND r.RequesterUserId <> @u AND r.CreatedByUserId <> @u
            UNION ALL
            SELECT {Columns}, d.FromUserId, a.AssignedRoleId, NULL
              FROM wfl.UserDelegation AS d JOIN wfl.RequestApproval AS a ON a.Decision = 'PENDING'
               AND (a.AssignedUserId = d.FromUserId OR (a.AssignedUserId IS NULL AND a.AssignedRoleId IN (SELECT ur.RoleId FROM sec.UserRole AS ur WHERE ur.UserId = d.FromUserId)))
              JOIN wfl.RequestStageInstance AS i ON i.RequestStageInstanceId = a.StageInstanceId AND i.ExitedAt IS NULL
              JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId JOIN wfl.Request AS r ON r.RequestId = a.RequestId
              JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
             WHERE d.ToUserId = @u AND d.Status IN ('SCHEDULED', 'ACTIVE') AND @today BETWEEN d.StartsOn AND d.EndsOn
               AND (d.Scope <> 'REQUEST_TYPE' OR d.RequestTypeId = r.RequestTypeId) AND r.RequesterUserId <> @u AND r.CreatedByUserId <> @u;
            """, new { u = actor.UserId, roles, today }, cancellationToken: ct))).Where(x => scope.Allows(x.CompanyId)).DistinctBy(x => x.Id).ToList();
        var tasks = (await u.Connection.QueryAsync<Item>(new CommandDefinition(
            $"""
            SELECT {Columns}, CAST(NULL AS BIGINT) AS OnBehalfOf, CAST(NULL AS INT) AS RoleId, CAST(NULL AS VARCHAR(100)) AS PoolPermission
              FROM wfl.RequestStageInstance AS i JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId JOIN wfl.Request AS r ON r.RequestId = i.RequestId
              JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
             WHERE i.ExitedAt IS NULL AND i.Status = 'CLAIMED' AND i.AssigneeUserId = @u AND s.Kind IN ('TASK', 'TREASURY_QUEUE', 'DRAFT');
            """, new { u = actor.UserId }, cancellationToken: ct))).Where(x => scope.Allows(x.CompanyId)).ToList();
        var queue = (await u.Connection.QueryAsync<Item>(new CommandDefinition(
            $"""
            SELECT {Columns}, CAST(NULL AS BIGINT) AS OnBehalfOf, s.AssigneeRoleId AS RoleId, p.Code AS PoolPermission
              FROM wfl.RequestStageInstance AS i JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId JOIN wfl.Request AS r ON r.RequestId = i.RequestId
              JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId LEFT JOIN sec.Permission AS p ON p.PermissionId = s.PoolPermissionId
             WHERE i.ExitedAt IS NULL AND i.Status = 'QUEUED' AND s.Kind <> 'TERMINAL'
             ORDER BY CASE r.Priority WHEN 'URGENT' THEN 0 ELSE 1 END, ISNULL(i.QueuedAt, i.EnteredAt);
            """, cancellationToken: ct)))
            .Where(x => scope.Allows(x.CompanyId) && (x.PoolPermission is { } pool ? actor.Permissions.Contains(pool)
                : x.RoleId is { } role ? actor.RoleIds.Contains(role) : actor.Permissions.Contains("req.claim")))
            .ToList();
        var mine = (await u.Connection.QueryAsync<Item>(new CommandDefinition(
            $"""
            SELECT {Columns}, CAST(NULL AS BIGINT) AS OnBehalfOf, CAST(NULL AS INT) AS RoleId, CAST(NULL AS VARCHAR(100)) AS PoolPermission
              FROM wfl.Request AS r JOIN wfl.RequestStageInstance AS i ON i.RequestStageInstanceId = r.CurrentStageInstanceId AND i.ExitedAt IS NULL
              JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
             WHERE (r.RequesterUserId = @u OR r.CreatedByUserId = @u) AND r.Status IN ('DRAFT', 'ACTIVE')
               AND (s.StageKey = 'RETURNED' OR (s.AssigneeRule = 'REQUESTER' AND s.Kind = 'TASK'));
            """, new { u = actor.UserId }, cancellationToken: ct))).ToList();
        var names = await NamesAsync(u.Connection, approvals.Where(a => a.OnBehalfOf is not null).Select(a => a.OnBehalfOf!.Value), ct);
        object Row(Item x) => new
        {
            id = x.Id, requestNo = x.RequestNo ?? x.DraftRef, title = x.Title, type = x.Type, stage = x.Stage, priority = x.Priority, dueAt = x.DueAt, slaState = x.SlaState,
            enteredAt = x.EnteredAt, queuedAt = x.QueuedAt,
            onBehalfOf = x.OnBehalfOf is { } f && names.TryGetValue(f, out var n) ? new { id = n.PublicId, displayNameEn = n.NameEn, displayNameAr = n.NameAr } : null,
        };
        return Results.Ok(new
        {
            counters = new
            {
                approvals = approvals.Count, tasks = tasks.Count, queue = queue.Count, awaitingMe = mine.Count,
                overdue = approvals.Concat(tasks).Count(x => x.SlaState == "OVERDUE"), atRisk = approvals.Concat(tasks).Count(x => x.SlaState == "AT_RISK"),
            },
            approvals = approvals.Select(Row), tasks = tasks.Select(Row), queue = queue.Select(Row), awaitingMe = mine.Select(Row),
        });
    }

    private static async Task<Dictionary<long, (Guid PublicId, string? NameEn, string? NameAr)>> NamesAsync(SqlConnection c, IEnumerable<long> ids, CancellationToken ct)
    {
        var list = ids.Distinct().ToArray();
        if (list.Length == 0) return [];
        return (await c.QueryAsync<(long Id, Guid PublicId, string? NameEn, string? NameAr)>(new CommandDefinition(
            "SELECT AppUserId, PublicId, DisplayNameEn, DisplayNameAr FROM sec.AppUser WHERE AppUserId IN @list;", new { list }, cancellationToken: ct)))
            .ToDictionary(x => x.Id, x => (x.PublicId, x.NameEn, x.NameAr));
    }

    private static async Task<IResult> DelegationsAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "view");
        await using var u = await RequestEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var perms = await u.PermissionsAsync(ct);
        var all = http.Request.Query["view"].ToString() == "all";
        if (all && !perms.Contains("req.delegate.manage")) throw ApiProblemException.Forbidden();
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT d.PublicId AS id, f.PublicId AS fromId, f.DisplayNameEn AS fromNameEn, f.DisplayNameAr AS fromNameAr, t.PublicId AS toId, t.DisplayNameEn AS toNameEn,
                   t.DisplayNameAr AS toNameAr, d.StartsOn AS startsOn, d.EndsOn AS endsOn, d.Scope AS scope, rt.Code AS requestType, d.Reason AS reason, d.Status AS status,
                   d.RevokedAt AS revokedAt
              FROM wfl.UserDelegation AS d JOIN sec.AppUser AS f ON f.AppUserId = d.FromUserId JOIN sec.AppUser AS t ON t.AppUserId = d.ToUserId
              LEFT JOIN wfl.RequestType AS rt ON rt.RequestTypeId = d.RequestTypeId
             WHERE @all = 1 OR d.FromUserId = @u OR d.ToUserId = @u
             ORDER BY d.StartsOn DESC, d.UserDelegationId DESC;
            """, new { all, u = u.UserId }, cancellationToken: ct));
        return Results.Ok(new { items = rows });
    }

    private static async Task<IResult> DelegateAsync(DelegationBody b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await RequestEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        async Task<long> UserAsync(Guid id) => await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT AppUserId FROM sec.AppUser WHERE PublicId = @id AND IsSystemUser = 0 AND ArchivedAt IS NULL;", new { id }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("V-WFL-06", "The user is not known.");
        var from = b.From is { } fid ? await UserAsync(fid) : u.UserId;
        var to = await UserAsync(b.To);
        var today = DateOnly.FromDateTime(await Delegations.TodayAsync(u.Connection, tx, clock.GetUtcNow(), ct));
        var (id, publicId) = await Delegations.CreateAsync(u.Connection, tx, actor, new NewDelegation(from, to, b.StartsOn, b.EndsOn, b.Scope ?? "ALL", b.RequestType, b.Reason?.Trim()),
            today, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("DELEGATION_CREATED", "TREASURY", "wfl.UserDelegation", id,
            AfterJson: System.Text.Json.JsonSerializer.Serialize(new { from, to, b.StartsOn, b.EndsOn, scope = b.Scope ?? "ALL", b.RequestType })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/delegations/{publicId}", new { id = publicId });
    }

    private static async Task<IResult> RevokeAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await RequestEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        await Delegations.RevokeAsync(u.Connection, tx, actor, id, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("DELEGATION_REVOKED", "TREASURY", "wfl.UserDelegation", null,
            AfterJson: System.Text.Json.JsonSerializer.Serialize(new { delegation = id })), null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }
}

using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Facilities;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

/// <summary>
/// The three dashboards of the requests (FR-REQ-018 to 020; spec 13 section 7): the requester's (what they asked for in
/// its visible phase, what waits for them, what came back and what ended lately), the treasury officer's (their tasks by
/// sub-status, the queue they may claim in the order of BR-REQ-011, what is overdue and what waits at the bank) and the
/// treasury manager's (the approvals waiting for them with the available amount of the allocated line, the SLA
/// breaches, the age of the queue, the load of each officer, and the old reservations of R-WFL-07). Counters are the
/// lengths of their lists. Every list is within the user's company scope.
/// </summary>
public static class DashboardEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/dashboards/requester", RequesterAsync);
        api.MapGet("/dashboards/officer", OfficerAsync);
        api.MapGet("/dashboards/manager", ManagerAsync);
    }

    private const string Base = """
        r.PublicId AS id, ISNULL(r.RequestNo, r.DraftRef) AS requestNo, r.Title AS title, rt.Code AS type, r.Status AS status, r.Priority AS priority,
        r.CompanyId AS companyId, ISNULL(r.UpdatedAt, r.CreatedAt) AS updatedAt
        """;

    private static async Task<IResult> RequesterAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request);
        await using var u = await RequestEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var perms = await u.PermissionsAsync(ct);
        if (!perms.Contains("req.view.own")) throw ApiProblemException.Forbidden();
        var rows = (await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT {Base}, ph.Code AS phase, ph.NameAr AS phaseNameAr, ph.NameEn AS phaseNameEn,
                   CAST(CASE WHEN s.StageKey = 'RETURNED' THEN 1 ELSE 0 END AS BIT) AS returned,
                   CAST(CASE WHEN r.Status IN ('DRAFT', 'ACTIVE') AND (s.Kind = 'DRAFT' OR s.StageKey = 'RETURNED' OR (s.AssigneeRule = 'REQUESTER' AND s.Kind = 'TASK'))
                             THEN 1 ELSE 0 END AS BIT) AS waitsForMe,
                   r.CompletedAt AS completedAt
              FROM wfl.Request AS r JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
              LEFT JOIN wfl.ExternalPhase AS ph ON ph.ExternalPhaseId = r.ExternalPhaseId
              LEFT JOIN wfl.RequestStageInstance AS i ON i.RequestStageInstanceId = r.CurrentStageInstanceId
              LEFT JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId
             WHERE (r.RequesterUserId = @u OR r.CreatedByUserId = @u) AND r.ArchivedAt IS NULL
               AND (r.Status NOT IN ('COMPLETED', 'REJECTED', 'CANCELLED') OR r.CompletedAt >= DATEADD(DAY, -30, SYSUTCDATETIME()) OR r.ReadyToCloseAt >= DATEADD(DAY, -30, SYSUTCDATETIME()))
             ORDER BY ISNULL(r.UpdatedAt, r.CreatedAt) DESC;
            """, new { u = u.UserId }, cancellationToken: ct))).Cast<IDictionary<string, object?>>().ToList();
        // The requester's projection: AWAITING_CLOSE reads as in progress, and nothing internal is shown (BR-WFL-024).
        foreach (var r in rows) if ((string?)r["status"] == "AWAITING_CLOSE") r["status"] = "ACTIVE";
        var open = rows.Where(r => (string?)r["status"] is "DRAFT" or "ACTIVE").ToList();
        var waits = rows.Where(r => (bool)r["waitsForMe"]!).ToList();
        var returned = rows.Where(r => (bool)r["returned"]!).ToList();
        var ended = rows.Where(r => (string?)r["status"] is "COMPLETED" or "REJECTED" or "CANCELLED").ToList();
        return Results.Ok(new
        {
            counters = new { open = open.Count, waitsForMe = waits.Count, returned = returned.Count, endedLately = ended.Count },
            open, waitsForMe = waits, returned, endedLately = ended,
        });
    }

    private static async Task<IResult> OfficerAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request);
        await using var u = await RequestEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var actor = await RequestEndpoints.ActorAsync(u, null, ct);
        if (!actor.Permissions.Contains("req.claim") && !actor.Permissions.Contains("req.execute")) throw ApiProblemException.Forbidden();
        var scope = await CompanyScope.OfAsync(u, ct);
        var tasks = (await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT {Base}, s.StageKey AS stage, r.SubStatusKey AS subStatus, i.DueAt AS dueAt, i.SlaState AS slaState, i.EnteredAt AS enteredAt
              FROM wfl.RequestStageInstance AS i JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId JOIN wfl.Request AS r ON r.RequestId = i.RequestId
              JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
             WHERE i.ExitedAt IS NULL AND i.Status = 'CLAIMED' AND i.AssigneeUserId = @u AND s.Kind IN ('TASK', 'TREASURY_QUEUE')
             ORDER BY CASE r.Priority WHEN 'URGENT' THEN 0 ELSE 1 END, i.DueAt;
            """, new { u = u.UserId }, cancellationToken: ct))).Cast<IDictionary<string, object?>>().Where(x => scope.Allows((long)x["companyId"]!)).ToList();
        var queue = (await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT {Base}, s.StageKey AS stage, ISNULL(i.QueuedAt, i.EnteredAt) AS queuedAt, i.SlaState AS slaState, s.AssigneeRoleId AS roleId, p.Code AS pool
              FROM wfl.RequestStageInstance AS i JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId JOIN wfl.Request AS r ON r.RequestId = i.RequestId
              JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId LEFT JOIN sec.Permission AS p ON p.PermissionId = s.PoolPermissionId
             WHERE i.ExitedAt IS NULL AND i.Status = 'QUEUED' AND s.Kind <> 'TERMINAL'
             ORDER BY CASE r.Priority WHEN 'URGENT' THEN 0 ELSE 1 END, ISNULL(i.QueuedAt, i.EnteredAt);
            """, cancellationToken: ct))).Cast<IDictionary<string, object?>>()
            .Where(x => scope.Allows((long)x["companyId"]!) && (x["pool"] is string pool ? actor.Permissions.Contains(pool)
                : x["roleId"] is int role ? actor.RoleIds.Contains(role) : actor.Permissions.Contains("req.claim")))
            .ToList();
        foreach (var x in queue) { x.Remove("roleId"); x.Remove("pool"); }
        var bySub = tasks.GroupBy(t => (string?)t["subStatus"] ?? "").ToDictionary(g => g.Key, g => g.Count());
        var overdue = tasks.Where(t => (string?)t["slaState"] == "OVERDUE").ToList();
        var atBank = tasks.Where(t => (string?)t["subStatus"] == "AT_BANK").ToList();
        return Results.Ok(new
        {
            counters = new { tasks = tasks.Count, queue = queue.Count, overdue = overdue.Count, atBank = atBank.Count },
            tasksBySubStatus = bySub, tasks, queue, overdue, atBank,
        });
    }

    private static async Task<IResult> ManagerAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request);
        await using var u = await RequestEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var actor = await RequestEndpoints.ActorAsync(u, null, ct);
        if (!actor.Permissions.Contains("req.dashboard.manager")) throw ApiProblemException.Forbidden();
        var scope = await CompanyScope.OfAsync(u, ct);
        var roles = actor.RoleIds.DefaultIfEmpty(-1).ToArray();
        var approvals = (await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT {Base}, s.StageKey AS stage, i.DueAt AS dueAt, i.SlaState AS slaState, r.Amount AS amount, cur.Code AS currency, r.RequestId AS rid,
                   r.FacilityId AS facilityId, l.RootId AS limitRoot, pl.RootId AS lineRoot, CAST(s.IsReservationPoint AS BIT) AS reservationPoint
              FROM wfl.RequestApproval AS a JOIN wfl.RequestStageInstance AS i ON i.RequestStageInstanceId = a.StageInstanceId AND i.ExitedAt IS NULL
              JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId JOIN wfl.Request AS r ON r.RequestId = a.RequestId
              JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId LEFT JOIN ref.Currency AS cur ON cur.CurrencyId = r.CurrencyId
              LEFT JOIN fac.Limit AS l ON l.LimitId = r.LimitId LEFT JOIN fac.LimitProductLine AS pl ON pl.LimitProductLineId = r.LimitProductLineId
             WHERE a.Decision = 'PENDING' AND (a.AssignedUserId = @u OR (a.AssignedUserId IS NULL AND a.AssignedRoleId IN @roles));
            """, new { u = u.UserId, roles }, cancellationToken: ct))).Cast<IDictionary<string, object?>>().Where(x => scope.Allows((long)x["companyId"]!)).ToList();
        // FR-REQ-020: the available amount of the allocated line, computed as the availability panel does, without the request's own reservation.
        var today = clock.GetUtcNow().UtcDateTime.Date;
        foreach (var g in approvals.Where(a => a["facilityId"] is long).GroupBy(a => (long)a["facilityId"]!))
        {
            var f = await u.Connection.QuerySingleAsync<(int Rev, decimal Total)>(new CommandDefinition(
                "SELECT ApprovedRevisionNo, TotalAmount FROM fac.Facility WHERE FacilityId = @f;", new { f = g.Key }, cancellationToken: ct));
            var rows = await FacilityTreeStore.LoadAsync(u.Connection, null, g.Key, f.Rev, ct);
            var tree = rows.Tree(f.Total, today);
            var exposures = await FacilityTreeStore.ExposuresAsync(u.Connection, null, g.Key, ct);
            foreach (var a in g)
            {
                if (a["limitRoot"] is not long limit) continue;
                var av = tree.Available(limit, a["lineRoot"] as long?, (long)a["companyId"]!, exposures, (long)a["rid"]!);
                a["available"] = Math.Max(0, av.Avail);
                a["availabilityReason"] = av.Reason;
            }
        }
        foreach (var a in approvals) { a.Remove("rid"); a.Remove("facilityId"); a.Remove("limitRoot"); a.Remove("lineRoot"); }
        var breaches = (await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT {Base}, s.StageKey AS stage, i.DueAt AS dueAt, i.SlaState AS slaState, asg.DisplayNameEn AS assigneeNameEn, asg.DisplayNameAr AS assigneeNameAr
              FROM wfl.RequestStageInstance AS i JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId JOIN wfl.Request AS r ON r.RequestId = i.RequestId
              JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId LEFT JOIN sec.AppUser AS asg ON asg.AppUserId = i.AssigneeUserId
             WHERE i.ExitedAt IS NULL AND i.SlaState IN ('OVERDUE', 'AT_RISK')
             ORDER BY CASE i.SlaState WHEN 'OVERDUE' THEN 0 ELSE 1 END, i.DueAt;
            """, cancellationToken: ct))).Cast<IDictionary<string, object?>>().Where(x => scope.Allows((long)x["companyId"]!)).ToList();
        var queue = (await u.Connection.QueryAsync<(long CompanyId, DateTime Since)>(new CommandDefinition(
            """
            SELECT r.CompanyId, ISNULL(i.QueuedAt, i.EnteredAt) FROM wfl.RequestStageInstance AS i JOIN wfl.Request AS r ON r.RequestId = i.RequestId
             WHERE i.ExitedAt IS NULL AND i.Status = 'QUEUED';
            """, cancellationToken: ct))).Where(x => scope.Allows(x.CompanyId)).ToList();
        var now = clock.GetUtcNow().UtcDateTime;
        var load = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT asg.PublicId AS id, asg.DisplayNameEn AS displayNameEn, asg.DisplayNameAr AS displayNameAr, COUNT(*) AS open,
                   SUM(CASE WHEN i.SlaState = 'OVERDUE' THEN 1 ELSE 0 END) AS overdue
              FROM wfl.RequestStageInstance AS i JOIN sec.AppUser AS asg ON asg.AppUserId = i.AssigneeUserId
             WHERE i.ExitedAt IS NULL AND i.Status = 'CLAIMED'
             GROUP BY asg.PublicId, asg.DisplayNameEn, asg.DisplayNameAr ORDER BY COUNT(*) DESC;
            """, cancellationToken: ct));
        var s = await BankFas.Data.Workflow.Delegations.TodayAsync(u.Connection, null, clock.GetUtcNow(), ct);
        var aging = int.TryParse(await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition(
            """
            SELECT ISNULL(t.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key]
             WHERE d.[Key] = 'wfl.reservation.aging_days';
            """, cancellationToken: ct)), out var ad) ? ad : 14;
        // R-WFL-07: the reservations made by requests, with their age and state; the old ones flagged.
        var reservations = (await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT r.PublicId AS requestId, ISNULL(r.RequestNo, r.DraftRef) AS requestNo, rt.Code AS type, f.FacilityNo AS facilityNo, lr.Amount AS amount, cur.Code AS currency,
                   lr.CreatedAt AS reservedAt, lr.ExpiresOn AS expiresOn, lr.OverLimit AS overLimit, DATEDIFF(DAY, lr.CreatedAt, @today) AS ageDays, lr.CompanyId AS companyId
              FROM fac.LimitReservation AS lr JOIN wfl.Request AS r ON r.RequestId = lr.RequestId JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
              JOIN fac.Facility AS f ON f.FacilityId = lr.FacilityId JOIN ref.Currency AS cur ON cur.CurrencyId = lr.CurrencyId
             WHERE lr.Status = 'ACTIVE' ORDER BY lr.CreatedAt;
            """, new { today = s }, cancellationToken: ct))).Cast<IDictionary<string, object?>>().Where(x => scope.Allows((long)x["companyId"]!)).ToList();
        foreach (var r in reservations) r["old"] = Convert.ToInt32(r["ageDays"], System.Globalization.CultureInfo.InvariantCulture) > aging;
        return Results.Ok(new
        {
            counters = new
            {
                approvals = approvals.Count, overdue = breaches.Count(b => (string?)b["slaState"] == "OVERDUE"), atRisk = breaches.Count(b => (string?)b["slaState"] == "AT_RISK"),
                queue = queue.Count, oldReservations = reservations.Count(r => (bool)r["old"]!),
            },
            approvals, breaches,
            queueAge = new
            {
                count = queue.Count, oldestHours = queue.Count == 0 ? 0 : Math.Round((now - queue.Min(q => q.Since)).TotalHours, 1),
                averageHours = queue.Count == 0 ? 0 : Math.Round(queue.Average(q => (now - q.Since).TotalHours), 1),
            },
            load, reservations,
        });
    }
}

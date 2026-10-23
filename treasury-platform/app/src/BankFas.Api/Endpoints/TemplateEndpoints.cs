using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Workflow;
using BankFas.Data;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

/// <summary>
/// Workflow templates (FR-WFL-001, 028 to 030; BR-WFL-019, 020; SCR-REQ-12): the versions of each key with their
/// status; one version's stages, slots, hooks and transitions; a new version written as a draft from a template graph
/// (wfl.template.manage), checked before it is stored (V-WFL-01 to 03); and its publication (wfl.template.publish) by a
/// user other than its author, which retires the current version and leaves requests already submitted on theirs. A
/// version the tenant writes is its own (IsTenantModified), so a later seed does not replace it. Gated by WORKFLOW.
/// </summary>
public static class TemplateEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/templates", ListAsync);
        api.MapGet("/templates/{id:guid}", GetAsync);
        api.MapPost("/templates", CreateAsync);
        api.MapPost("/templates/{id:guid}/actions/publish", PublishAsync);
    }

    private static async Task<BoundUser> OpenAsync(HttpContext http, SqlConnectionFactory db, string permission)
    {
        var u = await BoundUser.OpenAsync(http, db, permission);
        try
        {
            await u.RequireModuleAsync("WORKFLOW", http.RequestAborted);
            return u;
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db, "wfl.template.view");
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT t.PublicId AS id, t.TemplateKey AS templateKey, t.VersionNo AS versionNo, t.Status AS status, t.IsCurrent AS isCurrent, rt.Code AS requestType,
                   t.NameAr AS nameAr, t.NameEn AS nameEn, t.PublishedAt AS publishedAt, t.IsTenantModified AS tenantModified, t.SourceSeedVersion AS seedVersion
              FROM wfl.WorkflowTemplate AS t JOIN wfl.RequestType AS rt ON rt.RequestTypeId = t.RequestTypeId
             ORDER BY t.TemplateKey, t.VersionNo DESC;
            """, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db, "wfl.template.view");
        var ct = http.RequestAborted;
        var t = await u.Connection.QuerySingleOrDefaultAsync<(int Id, string Key, int Version, string Status)?>(new CommandDefinition(
            "SELECT WorkflowTemplateId, TemplateKey, VersionNo, Status FROM wfl.WorkflowTemplate WHERE PublicId = @id;", new { id }, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        var stages = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT s.StageKey AS stageKey, s.Kind AS kind, s.NameAr AS nameAr, s.NameEn AS nameEn, p.Code AS phase, s.AssigneeRule AS assigneeRule, s.ApprovalMode AS approvalMode,
                   s.SlaHours AS slaHours, s.ClaimSlaHours AS claimSlaHours, s.IsReservationPoint AS reservationPoint, s.TerminalOutcome AS outcome,
                   (SELECT STRING_AGG(CONCAT(h.TriggerKind, ':', ISNULL(h.ActionFilter, '-'), ':', h.HookKey), ', ') FROM wfl.WorkflowStageHook AS h WHERE h.StageId = s.WorkflowStageId) AS hooks,
                   (SELECT STRING_AGG(CONCAT(a.SlotKey, ':', a.SubjectRule), ', ') FROM wfl.StageApprover AS a WHERE a.StageId = s.WorkflowStageId) AS slots
              FROM wfl.WorkflowStage AS s JOIN wfl.ExternalPhase AS p ON p.ExternalPhaseId = s.ExternalPhaseId
             WHERE s.TemplateId = @t ORDER BY s.SeqNo, s.StageKey;
            """, new { t = t.Id }, cancellationToken: ct));
        var transitions = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT f.StageKey AS fromStage, tr.Action AS action, d.StageKey AS toStage, tr.Priority AS priority, tr.ConditionJson AS condition, r.StageKey AS resume
              FROM wfl.WorkflowTransition AS tr JOIN wfl.WorkflowStage AS f ON f.WorkflowStageId = tr.FromStageId JOIN wfl.WorkflowStage AS d ON d.WorkflowStageId = tr.ToStageId
              LEFT JOIN wfl.WorkflowStage AS r ON r.WorkflowStageId = tr.ResumeStageId
             WHERE tr.TemplateId = @t ORDER BY f.SeqNo, tr.Action, tr.Priority;
            """, new { t = t.Id }, cancellationToken: ct));
        return Results.Ok(new { id, templateKey = t.Key, versionNo = t.Version, status = t.Status, stages, transitions });
    }

    /// <summary>A new draft version of a key from a template graph; refused with every problem found when the graph would not publish.</summary>
    private static async Task<IResult> CreateAsync(JsonElement body, HttpContext http, SqlConnectionFactory db)
    {
        TemplateGraph g;
        try { g = TemplateGraph.Parse(body.GetRawText()); }
        catch (Exception ex) when (ex is JsonException or InvalidDataException) { throw ApiProblemException.Invalid("VALIDATION_FAILED", "The template is not a template graph."); }
        await using var u = await OpenAsync(http, db, "wfl.template.manage");
        var ct = http.RequestAborted;
        var phases = (await u.Connection.QueryAsync<string>(new CommandDefinition("SELECT Code FROM wfl.ExternalPhase WHERE IsActive = 1;", cancellationToken: ct)))
            .ToHashSet(StringComparer.Ordinal);
        var errors = TemplateValidator.Validate(g, HookKeys.All, phases);
        if (errors.Count > 0) return Results.Problem(statusCode: 422, title: string.Join(" ", errors), extensions: new Dictionary<string, object?> { ["code"] = "V-WFL-01", ["errors"] = errors });
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        TemplateStore.Written w;
        try { w = await TemplateStore.WriteDraftAsync(u.Connection, tx, g, null, null, ct, tenantModified: true); }
        catch (InvalidDataException ex) { throw ApiProblemException.Invalid("V-WFL-01", ex.Message); }
        var publicId = await u.Connection.ExecuteScalarAsync<Guid>(new CommandDefinition("SELECT PublicId FROM wfl.WorkflowTemplate WHERE WorkflowTemplateId = @id;",
            new { id = w.TemplateId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("TEMPLATE_DRAFTED", "CONFIG", "wfl.WorkflowTemplate", w.TemplateId,
            AfterJson: JsonSerializer.Serialize(new { g.TemplateKey, w.VersionNo })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/templates/{publicId}", new { id = publicId, versionNo = w.VersionNo, status = "DRAFT" });
    }

    /// <summary>Q-WFL-14: the publisher is not the draft's author unless the template allows the same person; HIGH audit.</summary>
    private static async Task<IResult> PublishAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db, "wfl.template.publish");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var t = await u.Connection.QuerySingleOrDefaultAsync<(int Id, string Key, long? Author, bool Sod, string Status)?>(new CommandDefinition(
            "SELECT WorkflowTemplateId, TemplateKey, CreatedBy, SodAllowSamePerson, Status FROM wfl.WorkflowTemplate WITH (UPDLOCK) WHERE PublicId = @id;", new { id }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (t.Status != "DRAFT") throw new ApiProblemException(409, "TEMPLATE_PUBLISHED", "Only a draft version is published.");
        if (t.Author == u.UserId && !t.Sod) throw new ApiProblemException(403, "SAME_PERSON", "Another user publishes the version this user wrote (Q-WFL-14).");
        if (!await TemplateStore.PublishAsync(u.Connection, tx, t.Id, u.UserId, ct)) throw ETags.Conflict();
        await Outbox.EmitAsync(u.Connection, tx, "template.published", "wfl.WorkflowTemplate", t.Id, new { templateId = t.Id }, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("TEMPLATE_PUBLISHED", "CONFIG", "wfl.WorkflowTemplate", t.Id,
            AfterJson: JsonSerializer.Serialize(new { t.Key }), Severity: "HIGH"), null, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "PUBLISHED" });
    }
}

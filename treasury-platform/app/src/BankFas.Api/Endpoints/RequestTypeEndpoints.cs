using System.Text.Json;
using System.Text.RegularExpressions;
using BankFas.Api.Infrastructure;
using BankFas.Core.Workflow;
using BankFas.Data;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

/// <summary>
/// The request types and their workflows as the tenant's administrator defines them (docs/31 row 73; FR-REQ-001, 007,
/// 021; BR-REQ-001; FR-WFL-001): every type with its category (the screen it shows on: PURCHASE the import credits,
/// SALES the export credits, GENERAL the general requests, TREASURY the others), its audience, its current and draft
/// workflow; a new type of the tenant's own with its gap-free number sequence; its names, category and order; its
/// audience by role and department; its activation, which needs a published workflow, an audience and an active
/// sequence; and a workflow drawn from steps (approvals in order, the treasury queue held by a role or by everyone who
/// may claim, the execution) written as a draft version that another user publishes (Q-WFL-14). The seeded credit
/// types keep their seeded workflows here; the steps builder is for the tenant's own types and the general ones.
/// The platform operator holds none of these permissions, so it never sees the tenant's types (row 73).
/// </summary>
public static partial class RequestTypeEndpoints
{
    private static readonly HashSet<string> Categories = ["PURCHASE", "SALES", "GENERAL", "TREASURY"];
    private static readonly HashSet<string> Subjects = ["REQUESTER_MANAGER", "DEPARTMENT_HEAD", "ROLE"];

    [GeneratedRegex("^[A-Z][A-Z0-9_]{2,39}$")]
    private static partial Regex CodeRule();

    [GeneratedRegex("^[A-Z]{2,6}$")]
    private static partial Regex PrefixRule();

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/request-type-definitions", ListAsync);
        api.MapGet("/request-type-definitions/{code}", GetAsync);
        api.MapPost("/request-type-definitions", CreateAsync);
        api.MapPatch("/request-type-definitions/{code}", PatchAsync);
        api.MapPut("/request-type-definitions/{code}/audience", AudienceAsync);
        api.MapPost("/request-type-definitions/{code}/actions/{action}", ActAsync);
        api.MapPost("/request-type-definitions/{code}/workflow", WorkflowAsync);
    }

    public sealed record NewTypeBody(string? Code, string? NameAr, string? NameEn, string? Description, string? Category, string? NumberPrefix);
    public sealed record TypePatch(string? NameAr, string? NameEn, string? Description, string? Category, int? SortOrder);
    public sealed record AudienceBody(IReadOnlyList<string>? Roles, IReadOnlyList<string>? Departments);
    public sealed record ApprovalStep(string? Subject, string? Role, string? NameAr, string? NameEn, decimal? SlaHours);
    public sealed record WorkflowBody(IReadOnlyList<ApprovalStep>? Approvals, string? TreasuryRole, decimal? ClaimSlaHours, decimal? ExecutionSlaHours, string? ChangeNote);

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

    internal sealed record TypeRow(int RequestTypeId, string Code, string NameAr, string NameEn, string? Description, string Category, bool IsActive, int SortOrder,
        string? SeedKey, string NumberSequenceKey, bool ConsumesCreditLimit);

    private static Task<TypeRow?> TypeAsync(BoundUser u, string code, SqlTransaction? tx, CancellationToken ct) =>
        u.Connection.QuerySingleOrDefaultAsync<TypeRow>(new CommandDefinition(
            """
            SELECT RequestTypeId, Code, NameAr, NameEn, Description, Category, IsActive, SortOrder, SeedKey, NumberSequenceKey, ConsumesCreditLimit
              FROM wfl.RequestType WHERE Code = @code;
            """, new { code }, tx, cancellationToken: ct));

    /// <summary>The steps builder serves the tenant's own types and the general ones; the seeded credit types keep their hooks.</summary>
    private static bool Buildable(TypeRow t) => t.SeedKey is null || t.Category is "GENERAL" or "TREASURY";

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db, "wfl.template.view");
        var ct = http.RequestAborted;
        var types = (await u.Connection.QueryAsync<TypeRow>(new CommandDefinition(
            """
            SELECT RequestTypeId, Code, NameAr, NameEn, Description, Category, IsActive, SortOrder, SeedKey, NumberSequenceKey, ConsumesCreditLimit
              FROM wfl.RequestType ORDER BY SortOrder, Code;
            """, cancellationToken: ct))).ToList();
        var audience = (await u.Connection.QueryAsync<(int TypeId, string Kind, string? Code)>(new CommandDefinition(
            """
            SELECT a.RequestTypeId, a.SubjectKind, COALESCE(r.Code, d.Code, CAST(a.UserId AS NVARCHAR(20)))
              FROM wfl.RequestTypeAudience AS a LEFT JOIN sec.Role AS r ON r.RoleId = a.RoleId LEFT JOIN org.Department AS d ON d.DepartmentId = a.DepartmentId;
            """, cancellationToken: ct))).ToLookup(a => a.TypeId);
        var templates = (await u.Connection.QueryAsync<(int TypeId, Guid Id, string Key, int Version, string Status, bool IsCurrent, int Stages)>(new CommandDefinition(
            """
            SELECT t.RequestTypeId, t.PublicId, t.TemplateKey, t.VersionNo, t.Status, t.IsCurrent,
                   (SELECT COUNT(*) FROM wfl.WorkflowStage AS s WHERE s.TemplateId = t.WorkflowTemplateId)
              FROM wfl.WorkflowTemplate AS t WHERE t.IsCurrent = 1 OR t.Status = 'DRAFT';
            """, cancellationToken: ct))).ToLookup(t => t.TypeId);
        var sequences = (await u.Connection.QueryAsync<string>(new CommandDefinition(
            "SELECT SequenceKey FROM cfg.NumberSequenceDefinition WHERE IsActive = 1 AND SequenceKey LIKE 'req:%';", cancellationToken: ct))).ToHashSet(StringComparer.Ordinal);
        return Results.Ok(new
        {
            items = types.Select(t =>
            {
                var current = templates[t.RequestTypeId].FirstOrDefault(x => x.IsCurrent);
                var draft = templates[t.RequestTypeId].Where(x => x.Status == "DRAFT").OrderByDescending(x => x.Version).FirstOrDefault();
                return new
                {
                    code = t.Code, nameAr = t.NameAr, nameEn = t.NameEn, description = t.Description, category = t.Category, isActive = t.IsActive,
                    sortOrder = t.SortOrder, isCustom = t.SeedKey is null, buildable = Buildable(t), consumesCreditLimit = t.ConsumesCreditLimit,
                    roles = audience[t.RequestTypeId].Where(a => a.Kind == "ROLE").Select(a => a.Code),
                    departments = audience[t.RequestTypeId].Where(a => a.Kind == "DEPARTMENT").Select(a => a.Code),
                    hasSequence = sequences.Contains(t.NumberSequenceKey),
                    current = current.Key is null ? null : new { id = current.Id, templateKey = current.Key, versionNo = current.Version, stages = current.Stages },
                    draft = draft.Key is null ? null : new { id = draft.Id, templateKey = draft.Key, versionNo = draft.Version, stages = draft.Stages },
                };
            }),
        });
    }

    private static async Task<IResult> GetAsync(string code, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db, "wfl.template.view");
        var t = await TypeAsync(u, code, null, http.RequestAborted) ?? throw ApiProblemException.NotFound();
        var versions = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT t.PublicId AS id, t.TemplateKey AS templateKey, t.VersionNo AS versionNo, t.Status AS status, t.IsCurrent AS isCurrent, t.PublishedAt AS publishedAt,
                   t.ChangeNote AS changeNote, COALESCE(a.DisplayNameEn, a.DisplayNameAr) AS author
              FROM wfl.WorkflowTemplate AS t LEFT JOIN sec.AppUser AS a ON a.AppUserId = t.CreatedBy
             WHERE t.RequestTypeId = @id ORDER BY t.VersionNo DESC;
            """, new { id = t.RequestTypeId }, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            code = t.Code, nameAr = t.NameAr, nameEn = t.NameEn, description = t.Description, category = t.Category, isActive = t.IsActive, sortOrder = t.SortOrder,
            isCustom = t.SeedKey is null, buildable = Buildable(t), versions,
        });
    }

    /// <summary>A type of the tenant's own, inactive until it has a published workflow and an audience, with its gap-free sequence {prefix}-{yy}-{seq:0000}.</summary>
    private static async Task<IResult> CreateAsync(NewTypeBody b, HttpContext http, SqlConnectionFactory db)
    {
        var code = b.Code?.Trim().ToUpperInvariant() ?? "";
        if (!CodeRule().IsMatch(code)) throw ApiProblemException.Invalid("V-REQ-01", "The code is 3 to 40 capital letters, digits or underscores, starting with a letter.");
        if (string.IsNullOrWhiteSpace(b.NameAr) || string.IsNullOrWhiteSpace(b.NameEn)) throw ApiProblemException.Invalid("V-REQ-01", "Enter the Arabic and English names.");
        if (b.Category is null || !Categories.Contains(b.Category)) throw ApiProblemException.Invalid("V-REQ-01", "Choose the screen the type shows on.");
        var prefix = b.NumberPrefix?.Trim().ToUpperInvariant() ?? "";
        if (!PrefixRule().IsMatch(prefix)) throw ApiProblemException.Invalid("V-PLT-10", "The number prefix is 2 to 6 capital letters.");
        await using var u = await OpenAsync(http, db, "wfl.template.manage");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        int id;
        try
        {
            id = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id INT);
                INSERT wfl.RequestType (TenantId, Code, NameAr, NameEn, Description, Category, NumberSequenceKey, ConsumesCreditLimit, LimitCheckMode, RequiresSignedOriginal,
                                        IsActive, SortOrder, CreatedBy)
                OUTPUT inserted.RequestTypeId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @ar, @en, @d, @cat, CONCAT('req:', @code), 0, 'NONE', 0, 0,
                        (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM wfl.RequestType), CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new { code, ar = b.NameAr.Trim(), en = b.NameEn.Trim(), d = b.Description?.Trim(), cat = b.Category }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "DUPLICATE", "A request type with this code already exists.");
        }
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            IF NOT EXISTS (SELECT 1 FROM cfg.NumberSequenceDefinition WHERE SequenceKey = CONCAT('req:', @code))
                INSERT cfg.NumberSequenceDefinition (TenantId, SequenceKey, Pattern, ScopeLevel, PeriodBasis, GapPolicy, MinWidth, IsActive)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), CONCAT('req:', @code), CONCAT(@prefix, '-{yy}-{seq:0000}'), 'TENANT', 'CALENDAR_YEAR', 'GAP_FREE', 4, 1);
            """, new { code, prefix }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REQUEST_TYPE_CREATED", "CONFIG", "wfl.RequestType", id,
            AfterJson: JsonSerializer.Serialize(new { code, category = b.Category, prefix })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/request-type-definitions/{code}", new { code });
    }

    private static async Task<IResult> PatchAsync(string code, TypePatch b, HttpContext http, SqlConnectionFactory db)
    {
        if (b.Category is not null && !Categories.Contains(b.Category)) throw ApiProblemException.Invalid("V-REQ-01", "Choose the screen the type shows on.");
        if (b.NameAr is { } ar && string.IsNullOrWhiteSpace(ar) || b.NameEn is { } en && string.IsNullOrWhiteSpace(en))
            throw ApiProblemException.Invalid("V-REQ-01", "Enter the Arabic and English names.");
        await using var u = await OpenAsync(http, db, "wfl.template.manage");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var t = await TypeAsync(u, code, tx, ct) ?? throw ApiProblemException.NotFound();
        // A child type follows its parent object, and a seeded credit type keeps its screen: its hooks act on the credits of that screen.
        if (b.Category is not null && b.Category != t.Category && (t.Category == "CHILD" || t.SeedKey is not null && t.Category is "PURCHASE" or "SALES"))
            throw ApiProblemException.Invalid("V-REQ-01", "This type keeps its screen.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.RequestType SET NameAr = COALESCE(@ar, NameAr), NameEn = COALESCE(@en, NameEn), Description = COALESCE(@d, Description),
                   Category = COALESCE(@cat, Category), SortOrder = COALESCE(@sort, SortOrder), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE RequestTypeId = @id;
            """, new { ar = b.NameAr?.Trim(), en = b.NameEn?.Trim(), d = b.Description?.Trim(), cat = b.Category, sort = b.SortOrder, id = t.RequestTypeId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REQUEST_TYPE_CHANGED", "CONFIG", "wfl.RequestType", t.RequestTypeId,
            BeforeJson: JsonSerializer.Serialize(new { t.NameAr, t.NameEn, t.Category, t.SortOrder }), AfterJson: JsonSerializer.Serialize(b)), null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>FR-REQ-007: who may raise the type, by role and by department; no row means nobody, and an active type keeps one.</summary>
    private static async Task<IResult> AudienceAsync(string code, AudienceBody b, HttpContext http, SqlConnectionFactory db)
    {
        var roles = (b.Roles ?? []).Select(r => r.Trim()).Where(r => r.Length > 0).Distinct(StringComparer.Ordinal).ToArray();
        var depts = (b.Departments ?? []).Select(d => d.Trim()).Where(d => d.Length > 0).Distinct(StringComparer.Ordinal).ToArray();
        await using var u = await OpenAsync(http, db, "wfl.template.manage");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var t = await TypeAsync(u, code, tx, ct) ?? throw ApiProblemException.NotFound();
        if (t.IsActive && roles.Length + depts.Length == 0) throw ApiProblemException.Invalid("BR-REQ-001", "An active type keeps at least one role or department in its audience.");
        var roleIds = roles.Length == 0 ? [] : (await u.Connection.QueryAsync<(string Code, int Id)>(new CommandDefinition(
            "SELECT Code, RoleId FROM sec.Role WHERE Code IN @roles AND IsActive = 1;", new { roles }, tx, cancellationToken: ct))).ToList();
        if (roleIds.Count != roles.Length) throw ApiProblemException.Invalid("V-REQ-01", "A role in the audience does not exist or is inactive.");
        var deptIds = depts.Length == 0 ? [] : (await u.Connection.QueryAsync<(string Code, long Id)>(new CommandDefinition(
            "SELECT Code, DepartmentId FROM org.Department WHERE Code IN @depts AND IsActive = 1;", new { depts }, tx, cancellationToken: ct))).ToList();
        if (deptIds.Count != depts.Length) throw ApiProblemException.Invalid("V-REQ-01", "A department in the audience does not exist or is inactive.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "DELETE FROM wfl.RequestTypeAudience WHERE RequestTypeId = @id AND SubjectKind IN ('ROLE', 'DEPARTMENT');", new { id = t.RequestTypeId }, tx, cancellationToken: ct));
        foreach (var r in roleIds)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "INSERT wfl.RequestTypeAudience (TenantId, RequestTypeId, SubjectKind, RoleId) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @t, 'ROLE', @r);",
                new { t = t.RequestTypeId, r = r.Id }, tx, cancellationToken: ct));
        foreach (var d in deptIds)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "INSERT wfl.RequestTypeAudience (TenantId, RequestTypeId, SubjectKind, DepartmentId) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @t, 'DEPARTMENT', @d);",
                new { t = t.RequestTypeId, d = d.Id }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REQUEST_TYPE_AUDIENCE_SET", "CONFIG", "wfl.RequestType", t.RequestTypeId,
            AfterJson: JsonSerializer.Serialize(new { roles, departments = depts })), null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>BR-REQ-001: a type is activated with a published workflow, an audience and an active number sequence; deactivation keeps its requests.</summary>
    private static async Task<IResult> ActAsync(string code, string action, HttpContext http, SqlConnectionFactory db)
    {
        if (action is not ("activate" or "deactivate")) throw ApiProblemException.NotFound();
        await using var u = await OpenAsync(http, db, "wfl.template.manage");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var t = await TypeAsync(u, code, tx, ct) ?? throw ApiProblemException.NotFound();
        if (action == "activate")
        {
            var ready = await u.Connection.QuerySingleAsync<(int Template, int Audience, int Sequence)>(new CommandDefinition(
                """
                SELECT (SELECT COUNT(*) FROM wfl.WorkflowTemplate WHERE RequestTypeId = @id AND IsCurrent = 1),
                       (SELECT COUNT(*) FROM wfl.RequestTypeAudience WHERE RequestTypeId = @id),
                       (SELECT COUNT(*) FROM cfg.NumberSequenceDefinition WHERE SequenceKey = @seq AND IsActive = 1);
                """, new { id = t.RequestTypeId, seq = t.NumberSequenceKey }, tx, cancellationToken: ct));
            var missing = new List<string>();
            if (ready.Template == 0) missing.Add("a published workflow");
            if (ready.Audience == 0) missing.Add("an audience");
            if (ready.Sequence == 0) missing.Add("an active number sequence");
            if (missing.Count > 0) throw ApiProblemException.Invalid("BR-REQ-001", $"The type needs {string.Join(", ", missing)} before it is activated.");
        }
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.RequestType SET IsActive = @on, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE RequestTypeId = @id;",
            new { on = action == "activate", id = t.RequestTypeId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(action == "activate" ? "REQUEST_TYPE_ACTIVATED" : "REQUEST_TYPE_DEACTIVATED", "CONFIG",
            "wfl.RequestType", t.RequestTypeId, Severity: "HIGH"), null, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { isActive = action == "activate" });
    }

    /// <summary>The workflow of the steps as a draft version of the type's template key; published from /templates/{id}/actions/publish by another user.</summary>
    private static async Task<IResult> WorkflowAsync(string code, WorkflowBody b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db, "wfl.template.manage");
        var ct = http.RequestAborted;
        var t = await TypeAsync(u, code, null, ct) ?? throw ApiProblemException.NotFound();
        if (!Buildable(t)) throw ApiProblemException.Invalid("V-WFL-01", "This type keeps its seeded workflow: its stages act on the letters of credit.");
        var key = await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT TOP (1) TemplateKey FROM wfl.WorkflowTemplate WHERE RequestTypeId = @id ORDER BY IsCurrent DESC, VersionNo DESC;", new { id = t.RequestTypeId },
            cancellationToken: ct)) ?? t.Code;
        var g = Build(t, key, b);
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
            AfterJson: JsonSerializer.Serialize(new { g.TemplateKey, w.VersionNo, approvals = b.Approvals?.Count ?? 0, treasuryRole = b.TreasuryRole })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/templates/{publicId}", new { id = publicId, versionNo = w.VersionNo, status = "DRAFT" });
    }

    /// <summary>
    /// The graph of the steps: the draft; each approval in order (approve to the next, return to the requester and back
    /// to the same approval, reject); the treasury queue, numbered on entry (BR-WFL-013), held by the role named or by
    /// everyone with req.claim; the execution by the claimer with the sub-statuses of the general requests; the three ends.
    /// </summary>
    internal static TemplateGraph Build(TypeRow t, string key, WorkflowBody b)
    {
        var approvals = b.Approvals ?? [];
        if (approvals.Count > 5) throw ApiProblemException.Invalid("V-WFL-01", "A workflow has at most five approvals.");
        foreach (var a in approvals)
        {
            if (a.Subject is null || !Subjects.Contains(a.Subject)) throw ApiProblemException.Invalid("V-WFL-01", "Choose who approves each step.");
            if (a.Subject == "ROLE" && string.IsNullOrWhiteSpace(a.Role)) throw ApiProblemException.Invalid("V-WFL-01", "Choose the role of each approval by role.");
            if (a.SlaHours is <= 0 or > 720) throw ApiProblemException.Invalid("V-WFL-01", "The hours of a step are 1 to 720.");
        }
        if (b.ClaimSlaHours is <= 0 or > 720 || b.ExecutionSlaHours is <= 0 or > 720) throw ApiProblemException.Invalid("V-WFL-01", "The hours of a step are 1 to 720.");
        var stages = new List<StageDef>
        {
            new() { Key = "DRAFT", Kind = "DRAFT", NameAr = "مسودة", NameEn = "Draft", Phase = "DRAFT", Seq = 1, Assignee = new AssigneeDef("REQUESTER"), AllowRequesterCancel = true },
        };
        var transitions = new List<TransitionDef>();
        var keys = approvals.Select((_, i) => $"APPROVAL_{i + 1}").ToList();
        var next = keys.Count > 0 ? keys[0] : "TREASURY_QUEUE";
        transitions.Add(new() { From = "DRAFT", Action = "SUBMIT", To = next });
        for (var i = 0; i < approvals.Count; i++)
        {
            var a = approvals[i];
            var (ar, en) = a.Subject switch
            {
                "REQUESTER_MANAGER" => ("موافقة مدير الطالب", "Requester's manager approval"),
                "DEPARTMENT_HEAD" => ("موافقة رئيس الإدارة", "Department head approval"),
                _ => ("موافقة", "Approval"),
            };
            stages.Add(new()
            {
                Key = keys[i], Kind = "APPROVAL", NameAr = string.IsNullOrWhiteSpace(a.NameAr) ? ar : a.NameAr.Trim(), NameEn = string.IsNullOrWhiteSpace(a.NameEn) ? en : a.NameEn.Trim(),
                Phase = "IN_APPROVAL", Seq = 2 + i, ApprovalMode = "ANY", SlaHours = a.SlaHours ?? 8, AllowReturn = true, AllowRequesterCancel = true,
                Slots = [new SlotDef
                {
                    Key = "APPROVER", LabelAr = ar, LabelEn = en, Subject = a.Subject!, Role = a.Subject == "ROLE" ? a.Role!.Trim() : null,
                    FallbackRole = a.Subject == "ROLE" ? null : "TM",
                }],
            });
            transitions.Add(new() { From = keys[i], Action = "APPROVE", To = i + 1 < keys.Count ? keys[i + 1] : "TREASURY_QUEUE" });
            transitions.Add(new() { From = keys[i], Action = "RETURN", To = "RETURNED", Resume = keys[i], RequiresComment = true });
            transitions.Add(new() { From = keys[i], Action = "REJECT", To = "REJECTED", RequiresComment = true });
        }
        if (keys.Count > 0)
        {
            stages.Add(new()
            {
                Key = "RETURNED", Kind = "TASK", NameAr = "معاد للطالب", NameEn = "Returned to the requester", Phase = "RETURNED", Seq = 10,
                Assignee = new AssigneeDef("REQUESTER"), AllowRequesterCancel = true,
            });
            transitions.Add(new() { From = "RETURNED", Action = "RESUBMIT", To = keys[0] });
        }
        var role = string.IsNullOrWhiteSpace(b.TreasuryRole) ? null : b.TreasuryRole.Trim();
        stages.Add(new()
        {
            Key = "TREASURY_QUEUE", Kind = "TREASURY_QUEUE", NameAr = "طابور الخزينة", NameEn = "Treasury queue", Phase = "IN_PROGRESS", Seq = 20,
            Assignee = new AssigneeDef("ROLE", Role: role, PoolPermission: role is null ? "req.claim" : null), ClaimSlaHours = b.ClaimSlaHours ?? 4,
        });
        stages.Add(new()
        {
            Key = "EXECUTION", Kind = "TASK", NameAr = "التنفيذ", NameEn = "Execution", Phase = "IN_PROGRESS", Seq = 21, Assignee = new AssigneeDef("CLAIMER"),
            SlaHours = b.ExecutionSlaHours ?? 24,
            SubStatuses =
            [
                new("PREPARATION", "إعداد", "Preparation", false), new("SIGNING", "توقيع", "Signing", false),
                new("BANK_COMMUNICATION", "تواصل مع البنك", "Bank communication", false), new("AT_BANK", "في البنك", "At the bank", true),
                new("FOLLOW_UP", "متابعة", "Follow-up", false),
            ],
        });
        transitions.Add(new() { From = "TREASURY_QUEUE", Action = "COMPLETE", To = "EXECUTION" });
        transitions.Add(new() { From = "EXECUTION", Action = "COMPLETE", To = "COMPLETED" });
        stages.Add(new() { Key = "COMPLETED", Kind = "TERMINAL", NameAr = "مكتمل", NameEn = "Completed", Phase = "COMPLETED", Seq = 30, Outcome = "COMPLETED" });
        stages.Add(new() { Key = "REJECTED", Kind = "TERMINAL", NameAr = "مرفوض", NameEn = "Rejected", Phase = "REJECTED", Seq = 31, Outcome = "REJECTED" });
        stages.Add(new() { Key = "CANCELLED", Kind = "TERMINAL", NameAr = "ملغى", NameEn = "Cancelled", Phase = "CANCELLED", Seq = 32, Outcome = "CANCELLED" });
        return new TemplateGraph
        {
            TemplateKey = key, RequestType = t.Code, NameAr = t.NameAr, NameEn = t.NameEn, NumberOnStageKey = "TREASURY_QUEUE", ChangeNote = b.ChangeNote?.Trim(),
            Stages = stages, Transitions = transitions,
            Fields =
            [
                new() { Key = "title", LabelAr = "عنوان الطلب", LabelEn = "Title", Type = "TEXT", Required = true, IndexRole = "TITLE", Seq = 1,
                    Validation = JsonSerializer.SerializeToElement(new { maxLength = 200 }) },
                new() { Key = "amount", LabelAr = "المبلغ", LabelEn = "Amount", Type = "AMOUNT", IndexRole = "AMOUNT", Seq = 2 },
                new() { Key = "requiredByDate", LabelAr = "مطلوب قبل", LabelEn = "Required by", Type = "DATE", IndexRole = "REQUIRED_BY_DATE", Seq = 3 },
                new() { Key = "notes", LabelAr = "تفاصيل", LabelEn = "Details", Type = "LONGTEXT", Seq = 9, Validation = JsonSerializer.SerializeToElement(new { maxLength = 4000 }) },
            ],
            Attachments = [new() { Slot = "SUPPORTING", LabelAr = "مرفقات", LabelEn = "Supporting documents", DocumentType = "OTHER", Max = 10, VisibleToRequester = true }],
        };
    }
}

using System.Text.Json;
using BankFas.Core.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Workflow;

/// <summary>
/// Writes a template graph as a DRAFT version with its parts, and publishes a draft (FR-WFL-001, 002, 028, 029;
/// BR-WFL-019; S3 brief section 0.1 item 2). The database refuses a version inserted other than DRAFT and any change to
/// a published one (044, 50057), so the order is: the draft row, its stages, slots, hooks, transitions, fields and
/// attachment rules, the checks, then one UPDATE that retires the current version of the key (and of the type) and one that publishes
/// the draft with its publisher and time. Codes are resolved to rows in the caller's tenant; an unknown one is an error.
/// </summary>
public static class TemplateStore
{
    public sealed record Written(int TemplateId, int VersionNo);

    /// <summary>Inserts the graph as a new DRAFT version of its key; returns its id and version number.</summary>
    public static async Task<Written> WriteDraftAsync(SqlConnection c, SqlTransaction tx, TemplateGraph g, string? seedKey, int? sourceSeedVersion, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(g);
        var typeId = await c.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT RequestTypeId FROM wfl.RequestType WHERE Code = @code;", new { code = g.RequestType }, tx, cancellationToken: ct)).ConfigureAwait(false)
            ?? throw new InvalidDataException($"The template {g.TemplateKey} names the request type {g.RequestType}, which does not exist.");
        var version = await c.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT ISNULL(MAX(VersionNo), 0) + 1 FROM wfl.WorkflowTemplate WITH (UPDLOCK, HOLDLOCK) WHERE TemplateKey = @k;",
            new { k = g.TemplateKey }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var templateId = await c.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id INT);
            INSERT wfl.WorkflowTemplate (TenantId, RequestTypeId, TemplateKey, VersionNo, Status, NameAr, NameEn, NumberOnStageKey, ResetApprovalsOnResubmit,
                                         SodAllowSamePerson, SourceSeedVersion, SeedKey, CreatedBy)
            OUTPUT inserted.WorkflowTemplateId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @type, @key, @version, 'DRAFT', @ar, @en, @num, @reset, @sod, @src, @seed,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """,
            new
            {
                type = typeId, key = g.TemplateKey, version, ar = g.NameAr, en = g.NameEn, num = g.NumberOnStageKey, reset = g.ResetApprovalsOnResubmit,
                sod = g.SodAllowSamePerson, src = sourceSeedVersion, seed = seedKey,
            }, tx, cancellationToken: ct)).ConfigureAwait(false);

        var phases = (await c.QueryAsync<(string Code, int Id)>(new CommandDefinition(
            "SELECT Code, ExternalPhaseId FROM wfl.ExternalPhase WHERE IsActive = 1;", transaction: tx, cancellationToken: ct)).ConfigureAwait(false))
            .ToDictionary(x => x.Code, x => x.Id, StringComparer.Ordinal);
        var roles = new Dictionary<string, int>(StringComparer.Ordinal);
        var perms = new Dictionary<string, int>(StringComparer.Ordinal);
        async Task<int?> Role(string? code)
        {
            if (code is null) return null;
            if (roles.TryGetValue(code, out var id)) return id;
            return roles[code] = await c.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT RoleId FROM sec.Role WHERE Code = @code AND IsActive = 1;", new { code }, tx, cancellationToken: ct)).ConfigureAwait(false)
                ?? throw new InvalidDataException($"The template {g.TemplateKey} names the role {code}, which does not exist.");
        }
        async Task<int?> Permission(string? code)
        {
            if (code is null) return null;
            if (perms.TryGetValue(code, out var id)) return id;
            return perms[code] = await c.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT PermissionId FROM sec.Permission WHERE Code = @code;", new { code }, tx, cancellationToken: ct)).ConfigureAwait(false)
                ?? throw new InvalidDataException($"The template {g.TemplateKey} names the permission {code}, which does not exist.");
        }
        static string? J(object? v) => v is null ? null : JsonSerializer.Serialize(v, TemplateGraph.Json);
        static string? E(JsonElement? e) => e is { ValueKind: not JsonValueKind.Undefined and not JsonValueKind.Null } x ? x.GetRawText() : null;

        var stageIds = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var s in g.Stages)
        {
            var a = s.Assignee;
            stageIds[s.Key] = await c.ExecuteScalarAsync<int>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id INT);
                INSERT wfl.WorkflowStage (TenantId, TemplateId, StageKey, NameAr, NameEn, Kind, SeqNo, ExternalPhaseId, AssigneeRule, AssigneeRoleId, PoolPermissionId,
                                          AssigneeUserId, FallbackRoleId, ApprovalMode, SlaHours, ClaimSlaHours, SlaMode, IsTerminal, TerminalOutcome,
                                          AllowRequesterCancel, AllowReturn, RequiresComment, IsReservationPoint, SodAllowSamePerson, SubStatusSetJson,
                                          EditableFieldKeysJson, CreatedBy)
                OUTPUT inserted.WorkflowStageId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @t, @key, @ar, @en, @kind, @seq, @phase, @rule, @role, @pool, @user, @fallback, @mode, @sla,
                        @claim, @slaMode, @terminal, @outcome, @cancel, @ret, @comment, @reserve, @sod, @subs, @editable, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """,
                new
                {
                    t = templateId, key = s.Key, ar = s.NameAr, en = s.NameEn, kind = s.Kind, seq = s.Seq,
                    phase = phases.TryGetValue(s.Phase ?? "", out var p) ? p : throw new InvalidDataException($"The stage {s.Key} names the unknown phase {s.Phase}."),
                    rule = a?.Rule, role = await Role(a?.Role).ConfigureAwait(false), pool = await Permission(a?.PoolPermission).ConfigureAwait(false), user = a?.User,
                    fallback = await Role(a?.FallbackRole).ConfigureAwait(false), mode = s.ApprovalMode, sla = s.SlaHours, claim = s.ClaimSlaHours, slaMode = s.SlaMode,
                    terminal = s.Kind == "TERMINAL", outcome = s.Outcome, cancel = s.AllowRequesterCancel, ret = s.AllowReturn, comment = s.RequiresComment,
                    reserve = s.IsReservationPoint, sod = s.SodAllowSamePerson, subs = s.SubStatuses.Count == 0 ? null : J(s.SubStatuses),
                    editable = s.EditableFieldKeys is null ? null : J(s.EditableFieldKeys),
                }, tx, cancellationToken: ct)).ConfigureAwait(false);
            foreach (var slot in s.Slots)
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT wfl.StageApprover (TenantId, StageId, SlotKey, LabelAr, LabelEn, WorkflowRole, SubjectRule, RoleId, FallbackRoleId, AutoCompleteBySubmitter,
                                              AllowDelegation, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @stage, @key, @ar, @en, @wr, @subject, @role, @fallback, @auto, @deleg,
                            CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                    """,
                    new
                    {
                        stage = stageIds[s.Key], key = slot.Key, ar = slot.LabelAr, en = slot.LabelEn, wr = slot.WorkflowRole, subject = slot.Subject,
                        role = await Role(slot.Role).ConfigureAwait(false), fallback = await Role(slot.FallbackRole).ConfigureAwait(false),
                        auto = slot.AutoCompleteBySubmitter, deleg = slot.AllowDelegation,
                    }, tx, cancellationToken: ct)).ConfigureAwait(false);
            foreach (var h in s.Hooks)
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT wfl.WorkflowStageHook (TenantId, StageId, TriggerKind, ActionFilter, HookKey, ParamsJson, ExecMode, OnFailure, SeqNo, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @stage, @trigger, @action, @key, @params, @mode, @fail, @seq, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                    """,
                    new { stage = stageIds[s.Key], trigger = h.Trigger, action = h.Action, key = h.Key, @params = E(h.Params), mode = h.Mode, fail = h.OnFailure, seq = h.Seq },
                    tx, cancellationToken: ct)).ConfigureAwait(false);
        }
        foreach (var t in g.Transitions)
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT wfl.WorkflowTransition (TenantId, TemplateId, FromStageId, Action, ToStageId, Priority, ConditionJson, ResumeStageId, LabelAr, LabelEn,
                                               RequiresComment, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @t, @from, @action, @to, @priority, @cond, @resume, @ar, @en, @comment,
                        CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """,
                new
                {
                    t = templateId, from = stageIds[t.From], action = t.Action, to = stageIds[t.To], priority = t.Priority, cond = E(t.Condition),
                    resume = t.Resume is null ? (int?)null : stageIds[t.Resume], ar = t.LabelAr, en = t.LabelEn,
                    comment = t.RequiresComment || t.Action is "RETURN" or "REJECT",
                }, tx, cancellationToken: ct)).ConfigureAwait(false);
        foreach (var f in g.Fields)
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT wfl.TemplateField (TenantId, TemplateId, FieldKey, LabelAr, LabelEn, HelpAr, HelpEn, SectionKey, SeqNo, DataType, ConfigJson, IsRequired,
                                          RequiredWhenJson, VisibleWhenJson, VisibleStagesJson, EditableStagesJson, Sensitivity, IndexRole, KeepWhenHidden, ValidationJson, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @t, @key, @ar, @en, @har, @hen, @section, @seq, @type, @config, @req, @reqWhen, @visWhen, @visStages,
                        @editStages, @sens, @index, @keep, @valid, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """,
                new
                {
                    t = templateId, key = f.Key, ar = f.LabelAr, en = f.LabelEn, har = f.HelpAr, hen = f.HelpEn, section = f.Section, seq = f.Seq, type = f.Type,
                    config = E(f.Config), req = f.Required, reqWhen = E(f.RequiredWhen), visWhen = E(f.VisibleWhen),
                    visStages = f.VisibleStages is null ? null : J(f.VisibleStages), editStages = f.EditableStages is null ? null : J(f.EditableStages),
                    sens = f.Sensitivity, index = f.IndexRole, keep = f.KeepWhenHidden, valid = E(f.Validation),
                }, tx, cancellationToken: ct)).ConfigureAwait(false);
        foreach (var a in g.Attachments)
        {
            var docType = await c.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT DocumentTypeId FROM cat.DocumentType WHERE Code = @code;", new { code = a.DocumentType }, tx, cancellationToken: ct)).ConfigureAwait(false)
                ?? throw new InvalidDataException($"The template {g.TemplateKey} names the document type {a.DocumentType}, which does not exist.");
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT wfl.TemplateAttachmentRule (TenantId, TemplateId, SlotKey, LabelAr, LabelEn, DocumentTypeId, MinCount, MaxCount, RequiredBeforeStageKey,
                                                   RequiredWhenJson, VisibleToRequester, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @t, @slot, @ar, @en, @doc, @min, @max, @before, @when, @visible, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """,
                new
                {
                    t = templateId, slot = a.Slot, ar = a.LabelAr, en = a.LabelEn, doc = docType, min = a.Min, max = a.Max, before = a.RequiredBeforeStage,
                    when = E(a.RequiredWhen), visible = a.VisibleToRequester,
                }, tx, cancellationToken: ct)).ConfigureAwait(false);
        }
        return new Written(templateId, version);
    }

    /// <summary>
    /// Publishes a draft: the current version of its key retires first, then the draft becomes PUBLISHED and current
    /// with its publisher and time in one UPDATE (044 accepts it because the row was a draft). Zero rows: the draft
    /// changed meanwhile, which the caller reports as a conflict.
    /// </summary>
    public static async Task<bool> PublishAsync(SqlConnection c, SqlTransaction tx, int templateId, long publisherUserId, CancellationToken ct)
    {
        var draft = await c.QuerySingleOrDefaultAsync<(string TemplateKey, int RequestTypeId)?>(new CommandDefinition(
            "SELECT TemplateKey, RequestTypeId FROM wfl.WorkflowTemplate WITH (UPDLOCK, HOLDLOCK) WHERE WorkflowTemplateId = @id AND Status = 'DRAFT';",
            new { id = templateId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (draft is not { } d) return false;
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.WorkflowTemplate SET IsCurrent = 0, Status = 'RETIRED', RetiredAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE (TemplateKey = @key OR RequestTypeId = @type) AND IsCurrent = 1;
            """, new { key = d.TemplateKey, type = d.RequestTypeId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        // One current version per key and one per request type (M15:84-85): both are retired above.
        var n = await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.WorkflowTemplate SET Status = 'PUBLISHED', IsCurrent = 1, PublishedAt = SYSUTCDATETIME(), PublishedBy = @by, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE WorkflowTemplateId = @id AND Status = 'DRAFT';
            """, new { id = templateId, by = publisherUserId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        return n == 1;
    }
}

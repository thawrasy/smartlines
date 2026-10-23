using System.Data;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using BankFas.Core.Calendar;
using BankFas.Core.Text;
using BankFas.Core.Workflow;
using BankFas.Data.Calendar;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

using SlotState = (long Id, string SlotKey, long? UserId, int? RoleId, string Decision, long? ActedBy, string? Subject);

namespace BankFas.Data.Workflow;

/// <summary>Who acts: the bound user and the codes of their permissions and roles.</summary>
public sealed record Actor(long UserId, IReadOnlySet<string> Permissions, IReadOnlySet<long> RoleIds);

/// <summary>A new draft (FR-REQ-001, 002, 009; BR-REQ-002).</summary>
public sealed record NewRequest(string TypeCode, long CompanyId, long? RequesterUserId, string? FormJson, string? Priority = null, string? UrgentReason = null,
    long? ParentRequestId = null, string? ParentEntityType = null, long? ParentEntityId = null);

/// <summary>An action on a request (FR-WFL-006 to 014, 033, 035; BR-WFL-023).</summary>
public sealed record ActCommand(string Action, byte[]? RowVersion, string? Comment = null, string? InternalComment = null, string? ToStageKey = null,
    string? IdempotencyKey = null, string? ClientIp = null, bool OverrideRequested = false, string? OverrideReason = null, string? AckWarningsJson = null,
    long? AssignToUserId = null, string? SubStatus = null, string? Priority = null);

/// <summary>What an action did: the request's status and stage afterwards, its number, and whether it was a replay.</summary>
public sealed record ActResult(long RequestId, string Status, string StageKey, string? RequestNo, bool Replayed, bool NotComparable = false);

/// <summary>
/// The workflow engine (S3 brief OQ-1; spec 13 sections 5.1 and 8): the database checks the shapes of every row and
/// copies the current stage, its assignee and times onto the request (044); this class makes the moves. Every move is a
/// state-conditional write in the caller's transaction: the request is read with an update lock and its row version
/// checked (BR-WFL-023), the open stage instance is closed, the next one inserted, and the request's pointer, visible
/// phase and status written in one UPDATE (section 0.1 item 1). Entering a stage (BR-WFL-002) resolves its assignee or
/// approval slots (BR-WFL-005), computes its due time in business hours (BR-WFL-012), allocates the request number on
/// the template's numbering stage (BR-WFL-013), and runs its ON_ENTER hooks; the action itself runs the ON_ACTION hooks
/// first and the ON_EXIT hooks of the stage it leaves forward. CANCEL is added by the engine from every non-terminal
/// stage (OQ-6); CLOSE ends AWAITING_CLOSE (BR-WFL-027). Each action is one wfl.RequestAction with its idempotency key
/// (OQ-10), so a replay returns without a second effect.
/// </summary>
public static class RequestEngine
{
    public sealed class RequestRow
    {
        public long RequestId { get; init; }
        public Guid PublicId { get; init; }
        public string DraftRef { get; init; } = "";
        public string? RequestNo { get; init; }
        public int RequestTypeId { get; init; }
        public string TypeCode { get; init; } = "";
        public int TemplateId { get; init; }
        public string TemplateKey { get; init; } = "";
        public string? NumberOnStageKey { get; init; }
        public bool ResetApprovalsOnResubmit { get; init; }
        public bool TemplateSod { get; init; }
        public long CompanyId { get; init; }
        public long? DepartmentId { get; init; }
        public long RequesterUserId { get; init; }
        public long CreatedByUserId { get; init; }
        public long? SubmittedByUserId { get; init; }
        public string Status { get; init; } = "";
        public long? CurrentStageInstanceId { get; init; }
        public int CycleNo { get; init; }
        public decimal? Amount { get; init; }
        public int? CurrencyId { get; init; }
        public string? CurrencyCode { get; init; }
        public string? FormDataJson { get; init; }
        public string? Title { get; init; }
        public bool HasSodException { get; init; }
        public byte[] RowVersion { get; init; } = [];
    }

    public sealed class InstanceRow
    {
        public long RequestStageInstanceId { get; init; }
        public int StageId { get; init; }
        public string StageKey { get; init; } = "";
        public string Kind { get; init; } = "";
        public string ApprovalMode { get; init; } = "";
        public string Status { get; init; } = "";
        public long? AssigneeUserId { get; init; }
        public int CycleNo { get; init; }
        public int? ResumeStageId { get; init; }
        public DateTime EnteredAt { get; init; }
        public DateTime? QueuedAt { get; init; }
        public DateTime? DueAt { get; init; }
        public string? AssigneeRule { get; init; }
        public int? AssigneeRoleId { get; init; }
        public int? PoolPermissionId { get; init; }
        public string? PoolPermission { get; init; }
        public bool AllowRequesterCancel { get; init; }
        public bool AllowReturn { get; init; }
        public bool IsReservationPoint { get; init; }
        public bool? StageSod { get; init; }
        public string? TerminalOutcome { get; init; }
    }

    private sealed class StageRow
    {
        public int WorkflowStageId { get; init; }
        public string StageKey { get; init; } = "";
        public string Kind { get; init; } = "";
        public int ExternalPhaseId { get; init; }
        public string? AssigneeRule { get; init; }
        public int? AssigneeRoleId { get; init; }
        public int? PoolPermissionId { get; init; }
        public long? AssigneeUserId { get; init; }
        public long? AssigneeDepartmentId { get; init; }
        public int? FallbackRoleId { get; init; }
        public decimal? SlaHours { get; init; }
        public decimal? ClaimSlaHours { get; init; }
        public string SlaMode { get; init; } = "BUSINESS";
        public string? TerminalOutcome { get; init; }
        public string? SubStatusSetJson { get; init; }
    }

    private sealed class SlotRow
    {
        public string SlotKey { get; init; } = "";
        public string SubjectRule { get; init; } = "";
        public int? RoleId { get; init; }
        public long? UserId { get; init; }
        public long? DepartmentId { get; init; }
        public int? FallbackRoleId { get; init; }
        public bool AutoCompleteBySubmitter { get; init; }
    }

    private const string RequestSelect =
        """
        SELECT r.RequestId, r.PublicId, r.DraftRef, r.RequestNo, r.RequestTypeId, rt.Code AS TypeCode, r.TemplateId, t.TemplateKey, t.NumberOnStageKey,
               t.ResetApprovalsOnResubmit, t.SodAllowSamePerson AS TemplateSod, r.CompanyId, r.DepartmentId, r.RequesterUserId, r.CreatedByUserId,
               r.SubmittedByUserId, r.Status, r.CurrentStageInstanceId, r.CycleNo, r.Amount, r.CurrencyId, cur.Code AS CurrencyCode, r.FormDataJson, r.Title,
               r.HasSodException, r.RowVersion
          FROM wfl.Request AS r {0}
          JOIN wfl.RequestType AS rt ON rt.TenantId = r.TenantId AND rt.RequestTypeId = r.RequestTypeId
          JOIN wfl.WorkflowTemplate AS t ON t.TenantId = r.TenantId AND t.WorkflowTemplateId = r.TemplateId
          LEFT JOIN ref.Currency AS cur ON cur.CurrencyId = r.CurrencyId
        """;

    public static async Task<RequestRow?> FindAsync(SqlConnection c, SqlTransaction? tx, long requestId, bool forUpdate, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<RequestRow>(new CommandDefinition(
            RequestSelect.Replace("{0}", forUpdate ? "WITH (UPDLOCK, HOLDLOCK)" : "", StringComparison.Ordinal) + " WHERE r.RequestId = @id;",
            new { id = requestId }, tx, cancellationToken: ct)).ConfigureAwait(false);

    public static async Task<InstanceRow?> CurrentInstanceAsync(SqlConnection c, SqlTransaction? tx, long requestId, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<InstanceRow>(new CommandDefinition(
            """
            SELECT i.RequestStageInstanceId, i.StageId, s.StageKey, s.Kind, s.ApprovalMode, i.Status, i.AssigneeUserId, i.CycleNo, i.ResumeStageId, i.EnteredAt,
                   i.QueuedAt, i.DueAt, s.AssigneeRule, s.AssigneeRoleId, s.PoolPermissionId, p.Code AS PoolPermission, s.AllowRequesterCancel, s.AllowReturn,
                   s.IsReservationPoint, s.SodAllowSamePerson AS StageSod, s.TerminalOutcome
              FROM wfl.Request AS r
              JOIN wfl.RequestStageInstance AS i ON i.TenantId = r.TenantId AND i.RequestStageInstanceId = r.CurrentStageInstanceId
              JOIN wfl.WorkflowStage AS s ON s.TenantId = i.TenantId AND s.WorkflowStageId = i.StageId
              LEFT JOIN sec.Permission AS p ON p.PermissionId = s.PoolPermissionId
             WHERE r.RequestId = @id;
            """, new { id = requestId }, tx, cancellationToken: ct)).ConfigureAwait(false);

    // ---------- the tenant's clock and calendar ----------

    /// <summary>
    /// One clock for an action: every time the engine writes (entry, exit, decision, close) is the action's own instant,
    /// set once in the session, so an exit is never before its entry and the tests' clock drives the due times.
    /// </summary>
    private static Task<int> SetNowAsync(SqlConnection c, SqlTransaction tx, DateTimeOffset now, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition("EXEC sys.sp_set_session_context @key = N'EngineNow', @value = @now;",
            new { now = DateTime.SpecifyKind(now.UtcDateTime, DateTimeKind.Unspecified) }, tx, cancellationToken: ct));

    internal sealed record TenantTime(TimeZoneInfo Zone, int CountryId, TimeOnly Start, TimeOnly End);

    internal static async Task<TenantTime> TimeAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct)
    {
        var t = await c.QuerySingleAsync<(string TimeZone, int HomeCountryId)>(new CommandDefinition(
            "SELECT TimeZone, HomeCountryId FROM plat.v_CurrentTenant;", transaction: tx, cancellationToken: ct)).ConfigureAwait(false);
        var hours = (await c.QueryAsync<(string Key, string? Value)>(new CommandDefinition(
            """
            SELECT d.[Key], ISNULL(t.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key]
             WHERE d.[Key] IN ('work.start', 'work.end');
            """, transaction: tx, cancellationToken: ct)).ConfigureAwait(false)).ToDictionary(r => r.Key, r => r.Value?.Trim('"'));
        static TimeOnly Parse(string? v, TimeOnly d) => TimeOnly.TryParse(v, CultureInfo.InvariantCulture, out var x) ? x : d;
        var zone = TimeZoneInfo.TryFindSystemTimeZoneById(t.TimeZone, out var z) ? z : TimeZoneInfo.Utc;
        return new TenantTime(zone, t.HomeCountryId, Parse(hours.GetValueOrDefault("work.start"), new TimeOnly(8, 0)), Parse(hours.GetValueOrDefault("work.end"), new TimeOnly(17, 0)));
    }

    /// <summary>BR-WFL-012: the due time of a stage entered now, in business hours of the tenant's calendar (or calendar hours), as UTC.</summary>
    private static async Task<DateTime?> DueAsync(SqlConnection c, SqlTransaction tx, TenantTime tt, DateTimeOffset now, decimal? hours, string mode, CancellationToken ct)
    {
        if (hours is not { } h) return null;
        if (mode == "CALENDAR") return now.UtcDateTime.AddHours((double)h);
        var local = TimeZoneInfo.ConvertTime(now, tt.Zone).DateTime;
        var from = DateOnly.FromDateTime(local);
        var cal = await WorkingCalendar.LoadAsync(c, tx, tt.CountryId, from.AddDays(-1), from.AddDays((int)Math.Ceiling((double)h / 4) + 30), ct).ConfigureAwait(false);
        var due = cal.AddBusinessHours(local, (double)h, tt.Start, tt.End);
        return TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(due, DateTimeKind.Unspecified), tt.Zone);
    }

    // ---------- drafts ----------

    /// <summary>
    /// A new draft of an active type (FR-REQ-001, 007): the actor is in the type's audience and holds req.create; the
    /// requester is the actor unless another active user is named (BR-REQ-002). The template is the type's current one
    /// (BR-WFL-019); the draft has its DRAFT stage instance held by the requester and a local number D-xxxxxxxx.
    /// </summary>
    public static async Task<(long RequestId, Guid PublicId, string DraftRef)> CreateDraftAsync(SqlConnection c, SqlTransaction tx, Actor actor, NewRequest n,
        DateTimeOffset now, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        ArgumentNullException.ThrowIfNull(n);
        if (!actor.Permissions.Contains("req.create")) throw WorkflowRefusalException.Forbidden("You may not raise requests.");
        await SetNowAsync(c, tx, now, ct).ConfigureAwait(false);
        var type = await c.QuerySingleOrDefaultAsync<(int RequestTypeId, int TemplateId, string Category)?>(new CommandDefinition(
            """
            SELECT rt.RequestTypeId, t.WorkflowTemplateId, rt.Category FROM wfl.RequestType AS rt
              JOIN wfl.WorkflowTemplate AS t ON t.TenantId = rt.TenantId AND t.RequestTypeId = rt.RequestTypeId AND t.IsCurrent = 1
             WHERE rt.Code = @code AND rt.IsActive = 1;
            """, new { code = n.TypeCode }, tx, cancellationToken: ct)).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.Missing("V-REQ-01", "This request type is not available.");
        var dept = await c.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT DepartmentId FROM sec.AppUser WHERE AppUserId = @u;",
            new { u = actor.UserId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var inAudience = await c.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT COUNT(*) FROM wfl.RequestTypeAudience AS a
             WHERE a.RequestTypeId = @type
               AND ((a.SubjectKind = 'ROLE' AND a.RoleId IN @roles) OR (a.SubjectKind = 'USER' AND a.UserId = @u) OR (a.SubjectKind = 'DEPARTMENT' AND a.DepartmentId = @d));
            """, new { type = type.RequestTypeId, roles = actor.RoleIds.DefaultIfEmpty(-1).ToArray(), u = actor.UserId, d = dept ?? -1 }, tx, cancellationToken: ct))
            .ConfigureAwait(false);
        if (inAudience == 0) throw WorkflowRefusalException.Forbidden("This request type is not open to you (FR-REQ-007).");
        if (type.Category == "CHILD" && (n.ParentEntityType is null || n.ParentEntityId is null))
            throw WorkflowRefusalException.Missing("V-REQ-03", "A child request is raised from its parent (FR-REQ-012).");
        var requester = n.RequesterUserId ?? actor.UserId;
        var requesterRow = await c.QuerySingleOrDefaultAsync<(long Id, long? DepartmentId)?>(new CommandDefinition(
            "SELECT AppUserId, DepartmentId FROM sec.AppUser WHERE AppUserId = @u AND Status = 'ACTIVE' AND IsSystemUser = 0 AND ArchivedAt IS NULL;",
            new { u = requester }, tx, cancellationToken: ct)).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.Missing("V-REQ-02", "The requester is not an active user.");
        if (n.Priority == "URGENT" && string.IsNullOrWhiteSpace(n.UrgentReason)) throw WorkflowRefusalException.Missing("V-REQ-06", "An urgent request gives its reason.");
        var fields = await FieldsAsync(c, tx, type.TemplateId, ct).ConfigureAwait(false);
        var form = Normalise(n.FormJson);
        var index = await IndexAsync(c, tx, fields, form, ct).ConfigureAwait(false);
        var draft = await c.QuerySingleAsync<(long Id, Guid PublicId, string DraftRef)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER, DraftRef VARCHAR(20));
            INSERT wfl.Request (TenantId, DraftRef, RequestTypeId, TemplateId, CompanyId, DepartmentId, RequesterUserId, CreatedByUserId, Title, Status, ExternalPhaseId,
                                Priority, UrgentReason, RequiredByDate, Amount, CurrencyId, CounterpartyName, CounterpartyCode, SearchText, FormDataJson,
                                ParentEntityType, ParentEntityId, ParentRequestId, CreatedBy)
            OUTPUT inserted.RequestId, inserted.PublicId, inserted.DraftRef INTO @o
            SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), @draftRef, @type, @template, @company, @dept, @requester, @actor, @title, 'DRAFT', s.ExternalPhaseId,
                   @priority, @urgent, @by, @amount, @currency, @cpName, @cpCode, @search, @form, @pType, @pId, @parent, @actor
              FROM wfl.WorkflowStage AS s WHERE s.TemplateId = @template AND s.Kind = 'DRAFT';
            SELECT Id, PublicId, DraftRef FROM @o;
            """,
            new
            {
                draftRef = "D-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(4)), type = type.RequestTypeId, template = type.TemplateId,
                company = n.CompanyId, dept = requesterRow.DepartmentId, requester, actor = actor.UserId, title = index.Title,
                priority = n.Priority ?? "NORMAL", urgent = n.UrgentReason, by = index.RequiredBy, amount = index.Amount, currency = index.CurrencyId,
                cpName = index.CounterpartyName, cpCode = index.CounterpartyCode, search = index.Search, form, pType = n.ParentEntityType, pId = n.ParentEntityId,
                parent = n.ParentRequestId,
            }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var stage = await StageAsync(c, tx, type.TemplateId, "DRAFT", ct, byKind: true).ConfigureAwait(false);
        var instance = await InsertInstanceAsync(c, tx, draft.Id, type.TemplateId, stage, 1, "CLAIMED", requester, now.UtcDateTime, null, null, null, null, ct)
            .ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.Request SET CurrentStageInstanceId = @i WHERE RequestId = @r AND Status = 'DRAFT';", new { i = instance, r = draft.Id }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        await ActionAsync(c, tx, draft.Id, instance, 1, "CREATED", null, "DRAFT", actor.UserId, "REQUESTER_VISIBLE", null, null, null, ct).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "request.created", "wfl.Request", draft.Id, new { requestId = draft.Id }, ct).ConfigureAwait(false);
        return draft;
    }

    /// <summary>The form of a draft or a returned request, by its requester or creator, with the row version (FR-REQ-002, BR-WFL-023).</summary>
    public static async Task<byte[]> UpdateFormAsync(SqlConnection c, SqlTransaction tx, Actor actor, long requestId, byte[]? rowVersion, string? formJson,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        await SetNowAsync(c, tx, DateTimeOffset.UtcNow, ct).ConfigureAwait(false);
        var r = await FindAsync(c, tx, requestId, true, ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        if (rowVersion is null || !r.RowVersion.SequenceEqual(rowVersion)) throw WorkflowRefusalException.Conflict();
        var inst = await CurrentInstanceAsync(c, tx, requestId, ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.State("The request has no current stage.");
        var editable = r.Status == "DRAFT" || (r.Status == "ACTIVE" && inst.StageKey == "RETURNED");
        if (!editable) throw WorkflowRefusalException.State("Only a draft or a returned request is edited by its requester.");
        if (actor.UserId != r.RequesterUserId && actor.UserId != r.CreatedByUserId) throw WorkflowRefusalException.Forbidden("Only the requester or the creator edits the request.");
        var fields = await FieldsAsync(c, tx, r.TemplateId, ct).ConfigureAwait(false);
        var form = Normalise(formJson);
        var index = await IndexAsync(c, tx, fields, form, ct).ConfigureAwait(false);
        var rv = await c.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE wfl.Request SET FormDataJson = @form, Title = @title, Amount = @amount, CurrencyId = @currency, RequiredByDate = @by, CounterpartyName = @cpName,
                   CounterpartyCode = @cpCode, SearchText = @search, UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @actor
            OUTPUT inserted.RowVersion INTO @o
             WHERE RequestId = @r AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """,
            new
            {
                form, title = index.Title, amount = index.Amount, currency = index.CurrencyId, by = index.RequiredBy, cpName = index.CounterpartyName,
                cpCode = index.CounterpartyCode, search = index.Search, actor = actor.UserId, r = requestId, rv = rowVersion,
            }, tx, cancellationToken: ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.Conflict();
        await ActionAsync(c, tx, requestId, inst.RequestStageInstanceId, r.CycleNo, "FIELD_EDITED", inst.StageKey, inst.StageKey, actor.UserId, "INTERNAL", null, null,
            null, ct).ConfigureAwait(false);
        return rv;
    }

    // ---------- fields and their index columns ----------

    public sealed record FieldRow(string FieldKey, string DataType, bool IsRequired, string IndexRole, string? EditableStagesJson, string? VisibleStagesJson,
        string Sensitivity, string LabelEn, string LabelAr, string? ConfigJson);

    public static async Task<IReadOnlyList<FieldRow>> FieldsAsync(SqlConnection c, SqlTransaction? tx, int templateId, CancellationToken ct) =>
        [.. await c.QueryAsync<FieldRow>(new CommandDefinition(
            """
            SELECT FieldKey, DataType, IsRequired, IndexRole, EditableStagesJson, VisibleStagesJson, Sensitivity, LabelEn, LabelAr, ConfigJson
              FROM wfl.TemplateField WHERE TemplateId = @t ORDER BY SeqNo, FieldKey;
            """, new { t = templateId }, tx, cancellationToken: ct)).ConfigureAwait(false)];

    private static string Normalise(string? formJson)
    {
        if (string.IsNullOrWhiteSpace(formJson)) return "{}";
        using var doc = JsonDocument.Parse(formJson);
        if (doc.RootElement.ValueKind != JsonValueKind.Object) throw WorkflowRefusalException.Missing("VALIDATION_FAILED", "The form is an object keyed by field.");
        return doc.RootElement.GetRawText();
    }

    private sealed record Index(string? Title, decimal? Amount, int? CurrencyId, DateTime? RequiredBy, string? CounterpartyName, string? CounterpartyCode, string? Search);

    /// <summary>FR-REQ-009: the index roles of the fields copied to the request's columns; a restricted field is never indexed (BR-REQ-003).</summary>
    private static async Task<Index> IndexAsync(SqlConnection c, SqlTransaction tx, IReadOnlyList<FieldRow> fields, string formJson, CancellationToken ct)
    {
        using var doc = JsonDocument.Parse(formJson);
        var form = doc.RootElement;
        string? Text(string role) => fields.FirstOrDefault(f => f.IndexRole == role) is { } f && form.TryGetProperty(f.FieldKey, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() : null;
        decimal? amount = null;
        int? currency = null;
        if (fields.FirstOrDefault(f => f.IndexRole == "AMOUNT") is { } af && form.TryGetProperty(af.FieldKey, out var a) && a.ValueKind == JsonValueKind.Object)
        {
            if (!a.TryGetProperty("value", out var av) || av.ValueKind != JsonValueKind.Number || av.GetDecimal() <= 0
                || !a.TryGetProperty("currency", out var ac) || ac.GetString() is not { Length: 3 } code)
                throw WorkflowRefusalException.Missing("V-REQ-02", $"{af.LabelEn}: an amount above zero with its currency.");
            currency = await c.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @code AND IsActive = 1;", new { code }, tx,
                cancellationToken: ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.Missing("V-REQ-02", $"{af.LabelEn}: the currency is not known.");
            amount = av.GetDecimal();
        }
        DateTime? by = Text("REQUIRED_BY_DATE") is { } d && DateOnly.TryParse(d, CultureInfo.InvariantCulture, out var day) ? day.ToDateTime(TimeOnly.MinValue) : null;
        var title = Text("TITLE");
        if (title is { Length: > 200 }) throw WorkflowRefusalException.Missing("VALIDATION_FAILED", "The title is up to 200 characters.");
        var cpName = Text("COUNTERPARTY_NAME");
        var cpCode = Text("COUNTERPARTY_CODE");
        var search = string.Join(' ', new[] { title, cpName, cpCode }.Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => Normalizer.Name(x)));
        return new Index(title, amount, currency, by, cpName is { Length: > 200 } ? cpName[..200] : cpName, cpCode is { Length: > 60 } ? cpCode[..60] : cpCode,
            search.Length == 0 ? null : search);
    }

    private static bool Listed(string? json, string key)
    {
        if (string.IsNullOrEmpty(json)) return false;
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.ValueKind == JsonValueKind.Array && doc.RootElement.EnumerateArray().Any(x => x.GetString() == key);
    }

    /// <summary>BR-WFL-014: leaving a stage needs, in order, its required fields, its attachments and its external references; the first missing one is named.</summary>
    private static async Task ExitChecksAsync(SqlConnection c, SqlTransaction tx, RequestRow r, InstanceRow inst, CancellationToken ct)
    {
        var fields = await FieldsAsync(c, tx, r.TemplateId, ct).ConfigureAwait(false);
        using var doc = JsonDocument.Parse(r.FormDataJson ?? "{}");
        var form = doc.RootElement;
        foreach (var f in fields.Where(f => f.IsRequired && f.DataType is not ("EXTERNAL_REF" or "FILE_SLOT" or "MODULE_FORM" or "LIMIT_SELECTION")))
        {
            // A field is required where it is edited: at the draft when no stage is named, else at the stages named (FR-REQ-003).
            var here = f.EditableStagesJson is null ? inst.Kind == "DRAFT" || inst.StageKey == "RETURNED" : Listed(f.EditableStagesJson, inst.StageKey);
            if (!here) continue;
            var ok = form.TryGetProperty(f.FieldKey, out var v) && v.ValueKind != JsonValueKind.Null && !(v.ValueKind == JsonValueKind.String && v.GetString()!.Trim().Length == 0);
            if (!ok) throw WorkflowRefusalException.Missing("V-REQ-REQUIRED", $"{f.LabelEn} is required.");
        }
        var missing = await c.QuerySingleOrDefaultAsync<(string? LabelEn, string SlotKey)?>(new CommandDefinition(
            """
            SELECT TOP (1) ar.LabelEn, ar.SlotKey FROM wfl.TemplateAttachmentRule AS ar
             WHERE ar.TemplateId = @t AND ar.RequiredBeforeStageKey = @stage AND ar.MinCount > 0
               AND (SELECT COUNT(*) FROM wfl.RequestAttachment AS a WHERE a.RequestId = @r AND a.SlotKey = ar.SlotKey AND a.IsActive = 1) < ar.MinCount
             ORDER BY ar.SlotKey;
            """, new { t = r.TemplateId, stage = inst.StageKey, r = r.RequestId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (missing is { } m) throw WorkflowRefusalException.Missing("V-WFL-ATTACHMENT", $"{m.LabelEn ?? m.SlotKey} is required.");
        foreach (var f in fields.Where(f => f.IsRequired && f.DataType == "EXTERNAL_REF" && Listed(f.EditableStagesJson, inst.StageKey)))
        {
            using var cfg = JsonDocument.Parse(f.ConfigJson ?? "{}");
            var system = cfg.RootElement.TryGetProperty("systemCode", out var s) ? s.GetString() : null;
            var refType = cfg.RootElement.TryGetProperty("refType", out var rt) ? rt.GetString() : null;
            var n = await c.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM wfl.RequestExternalRef WHERE RequestId = @r AND IsActive = 1 AND (@s IS NULL OR SystemCode = @s) AND (@t IS NULL OR RefType = @t);",
                new { r = r.RequestId, s = system, t = refType }, tx, cancellationToken: ct)).ConfigureAwait(false);
            if (n == 0) throw WorkflowRefusalException.Missing("V-WFL-EXTREF", $"{f.LabelEn} is required.");
        }
    }

    // ---------- the stages ----------

    private static async Task<StageRow> StageAsync(SqlConnection c, SqlTransaction tx, int templateId, string key, CancellationToken ct, bool byKind = false) =>
        await c.QuerySingleOrDefaultAsync<StageRow>(new CommandDefinition(
            $"""
            SELECT WorkflowStageId, StageKey, Kind, ExternalPhaseId, AssigneeRule, AssigneeRoleId, PoolPermissionId, AssigneeUserId, AssigneeDepartmentId, FallbackRoleId,
                   SlaHours, ClaimSlaHours, SlaMode, TerminalOutcome, SubStatusSetJson
              FROM wfl.WorkflowStage WHERE TemplateId = @t AND {(byKind ? "Kind" : "StageKey")} = @k;
            """, new { t = templateId, k = key }, tx, cancellationToken: ct)).ConfigureAwait(false)
        ?? throw new InvalidOperationException($"The template {templateId} has no stage {key}.");

    private static async Task<StageRow> StageByIdAsync(SqlConnection c, SqlTransaction tx, int stageId, CancellationToken ct) =>
        await c.QuerySingleAsync<StageRow>(new CommandDefinition(
            """
            SELECT WorkflowStageId, StageKey, Kind, ExternalPhaseId, AssigneeRule, AssigneeRoleId, PoolPermissionId, AssigneeUserId, AssigneeDepartmentId, FallbackRoleId,
                   SlaHours, ClaimSlaHours, SlaMode, TerminalOutcome, SubStatusSetJson
              FROM wfl.WorkflowStage WHERE WorkflowStageId = @s;
            """, new { s = stageId }, tx, cancellationToken: ct)).ConfigureAwait(false);

    private static async Task<long> InsertInstanceAsync(SqlConnection c, SqlTransaction tx, long requestId, int templateId, StageRow s, int cycle, string status,
        long? assignee, DateTime enteredAt, DateTime? queuedAt, DateTime? dueAt, DateTime? claimDueAt, int? resumeStageId, CancellationToken ct) =>
        await c.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT wfl.RequestStageInstance (TenantId, RequestId, TemplateId, StageId, CycleNo, Status, EnteredAt, QueuedAt, ClaimedAt, AssigneeUserId, DueAt, ClaimDueAt,
                                             SlaState, ResumeStageId, CreatedBy)
            OUTPUT inserted.RequestStageInstanceId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @t, @s, @cycle, @status, @at, @queued, NULL, @assignee, @due, @claimDue,
                    CASE WHEN @due IS NULL THEN 'NONE' ELSE 'ON_TRACK' END, @resume, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """,
            new
            {
                r = requestId, t = templateId, s = s.WorkflowStageId, cycle, status, at = enteredAt, queued = queuedAt, assignee, due = dueAt, claimDue = claimDueAt,
                resume = resumeStageId,
            }, tx, cancellationToken: ct)).ConfigureAwait(false);

    private static Task<int> ActionAsync(SqlConnection c, SqlTransaction tx, long requestId, long? instanceId, int cycle, string type, string? from, string? to, long? actor,
        string visibility, string? comment, object? meta, string? idempotencyKey, CancellationToken ct, long? onBehalfOf = null, bool sod = false) =>
        c.ExecuteAsync(new CommandDefinition(
            """
            INSERT wfl.RequestAction (TenantId, RequestId, StageInstanceId, CycleNo, ActionType, FromStageKey, ToStageKey, ActorType, ActorUserId, OnBehalfOfUserId,
                                      OccurredAt, Visibility, Comment, MetaJson, CorrelationId, IdempotencyKey, IsSodException, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, @type, @from, @to, CASE WHEN @actor IS NULL THEN 'SYSTEM' ELSE 'USER' END, @actor, @obo,
                    CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), @vis, @comment, @meta, CAST(SESSION_CONTEXT(N'CorrelationId') AS UNIQUEIDENTIFIER), @key, @sod, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """,
            new
            {
                r = requestId, i = instanceId, cycle, type, from, to, actor, obo = onBehalfOf, vis = visibility, comment,
                meta = meta is null ? null : JsonSerializer.Serialize(meta), key = idempotencyKey, sod,
            }, tx, cancellationToken: ct));

    // ---------- assignees (BR-WFL-005) ----------

    private sealed record Assigned(long? UserId, int? RoleId, string Source);

    private static async Task<int> RoleIdAsync(SqlConnection c, SqlTransaction tx, string code, CancellationToken ct) =>
        await c.ExecuteScalarAsync<int>(new CommandDefinition("SELECT RoleId FROM sec.Role WHERE Code = @code;", new { code }, tx, cancellationToken: ct)).ConfigureAwait(false);

    /// <summary>REQUESTER_MANAGER: the active line manager, then the head of the requester's department (not the requester), then the fallback role, then TM.</summary>
    private static async Task<Assigned> ManagerAsync(SqlConnection c, SqlTransaction tx, RequestRow r, int? fallbackRoleId, CancellationToken ct)
    {
        var m = await c.QuerySingleAsync<(long? Manager, long? Head)>(new CommandDefinition(
            """
            SELECT (SELECT m.AppUserId FROM sec.AppUser AS u JOIN sec.AppUser AS m ON m.AppUserId = u.LineManagerUserId
                     WHERE u.AppUserId = @u AND m.Status = 'ACTIVE' AND m.ArchivedAt IS NULL),
                   (SELECT h.AppUserId FROM sec.AppUser AS u JOIN org.Department AS d ON d.DepartmentId = u.DepartmentId
                      JOIN sec.AppUser AS h ON h.AppUserId = d.HeadUserId
                     WHERE u.AppUserId = @u AND h.AppUserId <> @u AND h.Status = 'ACTIVE' AND h.ArchivedAt IS NULL);
            """, new { u = r.RequesterUserId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (m.Manager is { } line) return new Assigned(line, null, "LINE_MANAGER");
        if (m.Head is { } head) return new Assigned(head, null, "DEPARTMENT_HEAD");
        if (fallbackRoleId is { } f) return new Assigned(null, f, "FALLBACK_ROLE");
        return new Assigned(null, await RoleIdAsync(c, tx, "TM", ct).ConfigureAwait(false), "TM");
    }

    private static async Task<Assigned> SlotSubjectAsync(SqlConnection c, SqlTransaction tx, RequestRow r, SlotRow s, CancellationToken ct) => s.SubjectRule switch
    {
        "REQUESTER" => new Assigned(r.RequesterUserId, null, "REQUESTER"),
        "REQUESTER_MANAGER" => await ManagerAsync(c, tx, r, s.FallbackRoleId, ct).ConfigureAwait(false),
        "USER" => new Assigned(s.UserId, null, "USER"),
        "ROLE" => new Assigned(null, s.RoleId, "ROLE"),
        "DEPARTMENT_HEAD" => await c.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT HeadUserId FROM org.Department WHERE DepartmentId = ISNULL(@d, @rd);", new { d = s.DepartmentId, rd = r.DepartmentId }, tx, cancellationToken: ct))
            .ConfigureAwait(false) is { } h ? new Assigned(h, null, "DEPARTMENT_HEAD") : new Assigned(null, s.FallbackRoleId ?? await RoleIdAsync(c, tx, "TM", ct).ConfigureAwait(false), "FALLBACK_ROLE"),
        _ => throw new InvalidOperationException($"Unknown slot subject {s.SubjectRule}."),
    };

    // ---------- the action ----------

    /// <summary>Acts on a request. Refusals are <see cref="WorkflowRefusalException"/>; nothing is written by a refused action.</summary>
    public static async Task<ActResult> ActAsync(SqlConnection c, SqlTransaction tx, Actor actor, long requestId, ActCommand cmd, DateTimeOffset now, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        ArgumentNullException.ThrowIfNull(cmd);
        var action = cmd.Action.ToUpperInvariant();
        await SetNowAsync(c, tx, now, ct).ConfigureAwait(false);
        var r = await FindAsync(c, tx, requestId, true, ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        // A replay of the same key returns the state it left, with no second effect (FR-WFL-035, OQ-10).
        if (cmd.IdempotencyKey is { Length: > 0 } key && await c.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM wfl.RequestAction WHERE RequestId = @r AND IdempotencyKey = @key;", new { r = requestId, key }, tx, cancellationToken: ct)).ConfigureAwait(false) > 0)
        {
            var at = await CurrentInstanceAsync(c, tx, requestId, ct).ConfigureAwait(false);
            return new ActResult(requestId, r.Status, at?.StageKey ?? "", r.RequestNo, true);
        }
        if (cmd.RowVersion is null || !r.RowVersion.SequenceEqual(cmd.RowVersion)) throw WorkflowRefusalException.Conflict();
        var inst = await CurrentInstanceAsync(c, tx, requestId, ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.State("The request has no current stage.");
        var tt = await TimeAsync(c, tx, ct).ConfigureAwait(false);
        var ctx = new Ctx(c, tx, actor, r, inst, cmd, tt, now, ct);
        if (r.Status is "COMPLETED" or "REJECTED" or "CANCELLED") throw WorkflowRefusalException.State("The request is closed.");
        if (action is "RETURN" or "REJECT" && string.IsNullOrWhiteSpace(cmd.Comment))
            throw WorkflowRefusalException.Missing("V-WFL-REASON", "A return or a rejection gives its reason (FR-WFL-010, 012).");
        switch (action)
        {
            case "CLOSE": return await CloseAsync(ctx).ConfigureAwait(false);
            case "CANCEL": return await CancelAsync(ctx).ConfigureAwait(false);
            case "CLAIM": return await ClaimAsync(ctx).ConfigureAwait(false);
            case "RELEASE": return await ReleaseAsync(ctx).ConfigureAwait(false);
            case "REASSIGN": return await ReassignAsync(ctx).ConfigureAwait(false);
            case "SUBSTATUS": return await SubStatusAsync(ctx).ConfigureAwait(false);
            case "PRIORITY": return await PriorityAsync(ctx).ConfigureAwait(false);
        }
        if (r.Status == "AWAITING_CLOSE") throw WorkflowRefusalException.State("The request waits for the treasury's close; a correction is a child request (BR-WFL-027).");
        return inst.Kind switch
        {
            "DRAFT" when action == "SUBMIT" => await SubmitAsync(ctx).ConfigureAwait(false),
            "APPROVAL" when action is "APPROVE" or "RETURN" or "REJECT" => await DecideAsync(ctx, action).ConfigureAwait(false),
            "TASK" or "TREASURY_QUEUE" when action is "COMPLETE" or "RETURN" or "REJECT" or "RESUBMIT" => await TaskAsync(ctx, action).ConfigureAwait(false),
            _ => throw WorkflowRefusalException.State($"The action {action} is not allowed at this stage."),
        };
    }

    private sealed record Ctx(SqlConnection C, SqlTransaction Tx, Actor Actor, RequestRow R, InstanceRow Inst, ActCommand Cmd, TenantTime Time, DateTimeOffset Now,
        CancellationToken Ct);

    private static bool IsRequesterSide(Ctx x) => x.Actor.UserId == x.R.RequesterUserId || x.Actor.UserId == x.R.CreatedByUserId;

    private static async Task<ActResult> SubmitAsync(Ctx x)
    {
        if (!IsRequesterSide(x)) throw WorkflowRefusalException.Forbidden("Only the requester or the creator submits the request.");
        x = await RepinAsync(x).ConfigureAwait(false);
        await ExitChecksAsync(x.C, x.Tx, x.R, x.Inst, x.Ct).ConfigureAwait(false);
        await HooksAsync(x, x.Inst, "ON_ACTION", "SUBMIT").ConfigureAwait(false);
        await x.C.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.Request SET SubmittedByUserId = @u, SubmittedAt = ISNULL(SubmittedAt, CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3))) WHERE RequestId = @r;",
            new { u = x.Actor.UserId, r = x.R.RequestId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        var r = await FindAsync(x.C, x.Tx, x.R.RequestId, true, x.Ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        await ActionAsync(x.C, x.Tx, r.RequestId, x.Inst.RequestStageInstanceId, r.CycleNo, "SUBMITTED", x.Inst.StageKey, null, x.Actor.UserId, "REQUESTER_VISIBLE",
            x.Cmd.Comment, SnapshotMeta(r), x.Cmd.IdempotencyKey, x.Ct).ConfigureAwait(false);
        return await ForwardAsync(x with { R = r }, "SUBMIT", "DONE", null).ConfigureAwait(false);
    }

    /// <summary>
    /// BR-WFL-019 and AC-WFL-6: a draft follows the type's current template until its first submission, which pins it. A
    /// draft written on an older version moves to the current one: its DRAFT instance is closed, the current version's
    /// is opened, and the template and the pointer change in one UPDATE after the pointer is cleared, so the copied stage (044) never
    /// names a stage of the other version.
    /// </summary>
    private static async Task<Ctx> RepinAsync(Ctx x)
    {
        if (x.R.Status != "DRAFT") return x;
        var current = await x.C.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT WorkflowTemplateId FROM wfl.WorkflowTemplate WHERE RequestTypeId = @t AND IsCurrent = 1;", new { t = x.R.RequestTypeId }, x.Tx, cancellationToken: x.Ct))
            .ConfigureAwait(false);
        if (current is not { } templateId || templateId == x.R.TemplateId) return x;
        await CloseInstanceAsync(x, "DONE", "SUBMIT").ConfigureAwait(false);
        var draft = await StageAsync(x.C, x.Tx, templateId, "DRAFT", x.Ct, byKind: true).ConfigureAwait(false);
        var instance = await InsertInstanceAsync(x.C, x.Tx, x.R.RequestId, templateId, draft, x.R.CycleNo, "CLAIMED", x.R.RequesterUserId, x.Now.UtcDateTime, null, null,
            null, null, x.Ct).ConfigureAwait(false);
        await x.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.Request SET CurrentStageInstanceId = NULL WHERE RequestId = @r AND Status = 'DRAFT';
            UPDATE wfl.Request SET TemplateId = @t, CurrentStageInstanceId = @i, ExternalPhaseId = @p WHERE RequestId = @r AND Status = 'DRAFT';
            """,
            new { t = templateId, i = instance, p = draft.ExternalPhaseId, r = x.R.RequestId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        await ActionAsync(x.C, x.Tx, x.R.RequestId, instance, x.R.CycleNo, "TEMPLATE_MIGRATED", null, null, x.Actor.UserId, "INTERNAL", null,
            new { from = x.R.TemplateId, to = templateId }, null, x.Ct).ConfigureAwait(false);
        var r = await FindAsync(x.C, x.Tx, x.R.RequestId, true, x.Ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        var inst = await CurrentInstanceAsync(x.C, x.Tx, x.R.RequestId, x.Ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.Conflict();
        return x with { R = r, Inst = inst };
    }

    private static object SnapshotMeta(RequestRow r) => new { amount = r.Amount, currency = r.CurrencyCode, title = r.Title };

    /// <summary>A TASK or queue stage: COMPLETE by its assignee (the claimer for a queue), RETURN or REJECT where the template allows, RESUBMIT of a returned request.</summary>
    private static async Task<ActResult> TaskAsync(Ctx x, string action)
    {
        if (action == "RESUBMIT")
        {
            if (x.Inst.StageKey != "RETURNED") throw WorkflowRefusalException.State("Only a returned request is resubmitted.");
            if (!IsRequesterSide(x)) throw WorkflowRefusalException.Forbidden("Only the requester or the creator resubmits the request.");
        }
        else if (x.Inst.Status == "QUEUED") throw WorkflowRefusalException.State("Claim the request first (BR-WFL-007).");
        else if (x.Inst.AssigneeUserId != x.Actor.UserId) throw WorkflowRefusalException.Forbidden("The stage is assigned to someone else.");
        if (action is "COMPLETE" or "RESUBMIT") await ExitChecksAsync(x.C, x.Tx, x.R, x.Inst, x.Ct).ConfigureAwait(false);
        await HooksAsync(x, x.Inst, "ON_ACTION", action).ConfigureAwait(false);
        var type = action switch { "COMPLETE" => "STAGE_CHANGED", "RESUBMIT" => "RESUBMITTED", "RETURN" => "RETURNED", _ => "REJECTED" };
        await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, type, x.Inst.StageKey, null, x.Actor.UserId,
            action is "COMPLETE" ? "INTERNAL" : "REQUESTER_VISIBLE", x.Cmd.Comment, action == "RESUBMIT" ? SnapshotMeta(x.R) : null, x.Cmd.IdempotencyKey, x.Ct)
            .ConfigureAwait(false);
        return action switch
        {
            "COMPLETE" => await ForwardAsync(x, "COMPLETE", "DONE", null).ConfigureAwait(false),
            "RESUBMIT" => await ForwardAsync(x, "RESUBMIT", "DONE", x.Inst.ResumeStageId).ConfigureAwait(false),
            "RETURN" => await ReturnAsync(x).ConfigureAwait(false),
            _ => await RejectAsync(x).ConfigureAwait(false),
        };
    }

    /// <summary>
    /// An approval stage (FR-WFL-007, 008; BR-WFL-003, 006, 026): the actor holds a pending slot of the current cycle, by
    /// their user or a role of theirs. Separation of duties: no approval of a request one created or asked for (the
    /// requester's own slot aside), and no two slots of one stage by one user, unless the template or the stage allows
    /// the same person, which is tagged. ANY completes with one approval and supersedes the others; ALL with all; a
    /// return or a rejection by any slot ends the stage and voids the pending slots.
    /// </summary>
    private static async Task<ActResult> DecideAsync(Ctx x, string action)
    {
        var needs = x.Inst.IsReservationPoint ? "req.treasury.approve" : "req.approve";
        var slots = (await x.C.QueryAsync<SlotState>(new CommandDefinition(
            """
            SELECT a.RequestApprovalId, a.SlotKey, a.AssignedUserId, a.AssignedRoleId, a.Decision, a.ActedByUserId, sa.SubjectRule
              FROM wfl.RequestApproval AS a WITH (UPDLOCK, HOLDLOCK)
              LEFT JOIN wfl.StageApprover AS sa ON sa.StageId = @stage AND sa.SlotKey = a.SlotKey
             WHERE a.StageInstanceId = @i;
            """, new { i = x.Inst.RequestStageInstanceId, stage = x.Inst.StageId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false)).ToList();
        var mine = x.Actor.Permissions.Contains(needs)
            ? slots.Where(s => s.Decision == "PENDING" && (s.UserId == x.Actor.UserId || (s.UserId is null && s.RoleId is { } role && x.Actor.RoleIds.Contains(role))))
                .OrderBy(s => s.UserId is null ? 1 : 0).ToList()
            : [];
        // FR-WFL-020, BR-WFL-021: without a slot of one's own, a pending slot of a user who delegated to the actor.
        var via = mine.Count == 0 ? await DelegatedSlotAsync(x, slots, needs).ConfigureAwait(false) : null;
        if (mine.Count == 0 && via is null)
            throw WorkflowRefusalException.Forbidden(x.Actor.Permissions.Contains(needs) ? "No approval of this stage waits for you." : "You may not decide on this stage.");
        var slot = via?.Slot ?? mine[0];
        var sodAllowed = x.Inst.StageSod ?? x.R.TemplateSod;
        var sod = false;
        if (via is not null && (via.FromUserId == x.R.CreatedByUserId || via.FromUserId == x.R.RequesterUserId) && slot.Subject != "REQUESTER" && !sodAllowed)
            throw WorkflowRefusalException.Forbidden("The delegator may not approve this request (BR-WFL-006).");
        if (slot.Subject != "REQUESTER" && (x.Actor.UserId == x.R.CreatedByUserId || x.Actor.UserId == x.R.RequesterUserId))
        {
            if (!sodAllowed) throw WorkflowRefusalException.Forbidden("You may not approve a request you created or asked for (BR-WFL-006).");
            sod = true;
        }
        if (slots.Any(s => s.Id != slot.Id && s.ActedBy == x.Actor.UserId && s.Decision == "APPROVED"))
        {
            if (!sodAllowed) throw WorkflowRefusalException.Forbidden("One user does not fill two approvals of one stage (BR-WFL-006).");
            sod = true;
        }
        if (action == "APPROVE") await HooksAsync(x, x.Inst, "ON_ACTION", "APPROVE").ConfigureAwait(false);
        else await HooksAsync(x, x.Inst, "ON_ACTION", action).ConfigureAwait(false);
        var decision = action switch { "APPROVE" => "APPROVED", "RETURN" => "RETURNED", _ => "REJECTED" };
        var hash = action == "APPROVE" ? Snapshot.Hash(x.Inst.StageKey, x.R.CycleNo, x.R.FormDataJson, x.R.Amount, x.R.CurrencyCode) : null;
        var n = await x.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.RequestApproval SET Decision = @d, Source = CASE WHEN @dlg IS NULL THEN 'USER' ELSE 'DELEGATE' END, ActedByUserId = @u, OnBehalfOfUserId = @obo, DelegationId = @dlg, ActedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), Comment = @comment, SnapshotHash = @hash,
                   ClientIp = @ip, AckWarningsJson = @ack, OverrideRequested = @ovr, OverrideReason = @ovrReason, IsSodException = @sod, UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)),
                   UpdatedBy = @u
             WHERE RequestApprovalId = @id AND Decision = 'PENDING';
            """,
            new
            {
                d = decision, u = x.Actor.UserId, comment = x.Cmd.Comment, hash, ip = x.Cmd.ClientIp, ack = x.Cmd.AckWarningsJson, ovr = x.Cmd.OverrideRequested,
                ovrReason = x.Cmd.OverrideReason, sod, id = slot.Id, obo = via?.FromUserId, dlg = via?.DelegationId,
            }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        if (n == 0) throw WorkflowRefusalException.Conflict();
        await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, decision, x.Inst.StageKey, null, x.Actor.UserId,
            action == "APPROVE" ? "INTERNAL" : "REQUESTER_VISIBLE", x.Cmd.Comment, new { slot = slot.SlotKey }, x.Cmd.IdempotencyKey, x.Ct, onBehalfOf: via?.FromUserId, sod: sod)
            .ConfigureAwait(false);
        if (sod) await SodTagAsync(x).ConfigureAwait(false);
        if (action == "RETURN") return await ReturnAsync(x).ConfigureAwait(false);
        if (action == "REJECT") return await RejectAsync(x).ConfigureAwait(false);
        var pending = slots.Count(s => s.Id != slot.Id && s.Decision == "PENDING");
        if (x.Inst.ApprovalMode == "ALL" && pending > 0)
            return new ActResult(x.R.RequestId, x.R.Status, x.Inst.StageKey, x.R.RequestNo, false);
        await x.C.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.RequestApproval SET Decision = 'SUPERSEDED', ActedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), Source = 'SYSTEM' WHERE StageInstanceId = @i AND Decision = 'PENDING';",
            new { i = x.Inst.RequestStageInstanceId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        return await ForwardAsync(x, "APPROVE", "DONE", null).ConfigureAwait(false);
    }

    private sealed record Delegated(SlotState Slot, long FromUserId, long DelegationId);

    /// <summary>
    /// The slot the actor fills by a delegation (FR-WFL-020, BR-WFL-021): a delegation to the actor in force on the
    /// tenant's date (scheduled or active, not revoked or ended), in scope for the request's type, from a user who holds
    /// the decision's permission and whose pending slot this is (their own or by a role of theirs). Never for the
    /// actor's own request; the delegate's own permissions decide an override (fac.override_limit is not delegated).
    /// </summary>
    private static async Task<Delegated?> DelegatedSlotAsync(Ctx x, List<SlotState> slots, string needs)
    {
        if (IsRequesterSide(x) || !slots.Any(s => s.Decision == "PENDING")) return null;
        var today = TimeZoneInfo.ConvertTime(x.Now, x.Time.Zone).Date;
        var from = (await x.C.QueryAsync<(long DelegationId, long FromUserId)>(new CommandDefinition(
            """
            SELECT d.UserDelegationId, d.FromUserId FROM wfl.UserDelegation AS d JOIN sec.AppUser AS u ON u.AppUserId = d.FromUserId
             WHERE d.ToUserId = @me AND d.Status IN ('SCHEDULED', 'ACTIVE') AND @today BETWEEN d.StartsOn AND d.EndsOn
               AND (d.Scope <> 'REQUEST_TYPE' OR d.RequestTypeId = @type)
             ORDER BY d.UserDelegationId;
            """, new { me = x.Actor.UserId, today, type = x.R.RequestTypeId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false)).ToList();
        foreach (var (delegationId, fromUser) in from)
        {
            var grants = (await x.C.QueryAsync<(int RoleId, string? Permission)>(new CommandDefinition(
                """
                SELECT ur.RoleId, p.Code FROM sec.UserRole AS ur JOIN sec.Role AS ro ON ro.RoleId = ur.RoleId AND ro.IsActive = 1
                  LEFT JOIN sec.RolePermission AS rp ON rp.RoleId = ur.RoleId LEFT JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId AND p.Code = @needs
                 WHERE ur.UserId = @u;
                """, new { u = fromUser, needs }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false)).ToList();
            if (!grants.Any(g => g.Permission == needs)) continue;
            var roles = grants.Select(g => (int?)g.RoleId).ToHashSet();
            var slot = slots.Where(s => s.Decision == "PENDING" && (s.UserId == fromUser || (s.UserId is null && roles.Contains(s.RoleId))))
                .OrderBy(s => s.UserId is null ? 1 : 0).Select(s => (SlotState?)s).FirstOrDefault();
            if (slot is { } found) return new Delegated(found, fromUser, delegationId);
        }
        return null;
    }

    /// <summary>BR-WFL-026: the first use of the exception on a request marks it and alerts the manager once.</summary>
    private static async Task SodTagAsync(Ctx x)
    {
        var first = await x.C.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.Request SET HasSodException = 1 WHERE RequestId = @r AND HasSodException = 0;", new { r = x.R.RequestId }, x.Tx, cancellationToken: x.Ct))
            .ConfigureAwait(false);
        if (first == 1)
            await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, "SOD_EXCEPTION_USED", x.Inst.StageKey, null, x.Actor.UserId, "INTERNAL",
                null, null, null, x.Ct, sod: true).ConfigureAwait(false);
    }

    private static async Task<IReadOnlyList<TransitionCandidate>> TransitionsAsync(Ctx x, string action) =>
        [.. await x.C.QueryAsync<TransitionCandidate>(new CommandDefinition(
            """
            SELECT tr.WorkflowTransitionId AS TransitionId, tr.Priority, s.StageKey AS ToStageKey, tr.ConditionJson AS Condition
              FROM wfl.WorkflowTransition AS tr JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = tr.ToStageId
             WHERE tr.FromStageId = @from AND tr.Action = @action ORDER BY tr.Priority;
            """, new { from = x.Inst.StageId, action }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false)];

    /// <summary>Leaves the current stage forward by the first transition that holds, or to the resume stage of a return.</summary>
    private static async Task<ActResult> ForwardAsync(Ctx x, string action, string exitStatus, int? resumeStageId)
    {
        StageRow next;
        var notComparable = false;
        if (resumeStageId is { } resume) next = await StageByIdAsync(x.C, x.Tx, resume, x.Ct).ConfigureAwait(false);
        else
        {
            using var doc = JsonDocument.Parse(x.R.FormDataJson ?? "{}");
            var (chosen, nc) = TransitionChooser.Choose(await TransitionsAsync(x, action).ConfigureAwait(false), doc.RootElement);
            if (chosen is null) throw WorkflowRefusalException.Missing("V-WFL-NO-PATH", $"No path of the template takes {action} from this stage.");
            notComparable = nc;
            next = await StageAsync(x.C, x.Tx, x.R.TemplateId, chosen.ToStageKey, x.Ct).ConfigureAwait(false);
            if (nc)
                await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, "STAGE_CHANGED", x.Inst.StageKey, next.StageKey, null, "INTERNAL",
                    null, new { condition = "NOT_COMPARABLE" }, null, x.Ct).ConfigureAwait(false);
        }
        await HooksAsync(x, x.Inst, "ON_EXIT", null).ConfigureAwait(false);
        await CloseInstanceAsync(x, exitStatus, action).ConfigureAwait(false);
        var cycle = action == "RESUBMIT" ? x.R.CycleNo + 1 : x.R.CycleNo;
        var result = await EnterAsync(x, next, cycle, null).ConfigureAwait(false);
        return result with { NotComparable = notComparable };
    }

    /// <summary>
    /// RETURN (FR-WFL-010, BR-WFL-008): to the stage the actor chose among the template's RETURN paths of this stage (the
    /// first by default). A return to the requester's RETURNED stage keeps the resume stage; a return inside the treasury
    /// keeps the cycle.
    /// </summary>
    private static async Task<ActResult> ReturnAsync(Ctx x)
    {
        var paths = await TransitionsAsync(x, "RETURN").ConfigureAwait(false);
        var chosen = x.Cmd.ToStageKey is { } k ? paths.FirstOrDefault(p => p.ToStageKey == k) : paths.Count > 0 ? paths[0] : null;
        if (chosen is null) throw WorkflowRefusalException.Missing("V-WFL-NO-PATH", "This stage has no such return path.");
        var resume = await x.C.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT ResumeStageId FROM wfl.WorkflowTransition WHERE WorkflowTransitionId = @id;",
            new { id = chosen.TransitionId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        await x.C.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.RequestApproval SET Decision = 'VOIDED', ActedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), Source = 'SYSTEM' WHERE StageInstanceId = @i AND Decision = 'PENDING';",
            new { i = x.Inst.RequestStageInstanceId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        await CloseInstanceAsync(x, "RETURNED", "RETURN").ConfigureAwait(false);
        var next = await StageAsync(x.C, x.Tx, x.R.TemplateId, chosen.ToStageKey, x.Ct).ConfigureAwait(false);
        return await EnterAsync(x, next, x.R.CycleNo, resume).ConfigureAwait(false);
    }

    private static async Task<ActResult> RejectAsync(Ctx x)
    {
        var paths = await TransitionsAsync(x, "REJECT").ConfigureAwait(false);
        if (paths.Count == 0) throw WorkflowRefusalException.State("This stage cannot be rejected.");
        await x.C.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.RequestApproval SET Decision = 'VOIDED', ActedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), Source = 'SYSTEM' WHERE StageInstanceId = @i AND Decision = 'PENDING';",
            new { i = x.Inst.RequestStageInstanceId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        await CloseInstanceAsync(x, "REJECTED", "REJECT").ConfigureAwait(false);
        var next = await StageAsync(x.C, x.Tx, x.R.TemplateId, paths[0].ToStageKey, x.Ct).ConfigureAwait(false);
        return await EnterAsync(x, next, x.R.CycleNo, null).ConfigureAwait(false);
    }

    /// <summary>
    /// CANCEL (OQ-6, BR-WFL-009): from any stage before the close, by the requester or creator where the stage allows
    /// it, or by a holder of req.cancel.any. The release of a reservation runs on entering the CANCELLED stage.
    /// </summary>
    private static async Task<ActResult> CancelAsync(Ctx x)
    {
        if (x.R.Status == "AWAITING_CLOSE") throw WorkflowRefusalException.State("A request waiting for its close is not cancelled; a correction is a child request (BR-WFL-027).");
        var asRequester = IsRequesterSide(x) && (x.R.Status == "DRAFT" || x.Inst.AllowRequesterCancel);
        if (!asRequester && !x.Actor.Permissions.Contains("req.cancel.any")) throw WorkflowRefusalException.Forbidden("You may not cancel the request at this stage.");
        await HooksAsync(x, x.Inst, "ON_ACTION", "CANCEL").ConfigureAwait(false);
        await x.C.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.RequestApproval SET Decision = 'VOIDED', ActedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), Source = 'SYSTEM' WHERE StageInstanceId = @i AND Decision = 'PENDING';",
            new { i = x.Inst.RequestStageInstanceId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, "CANCELLED", x.Inst.StageKey, "CANCELLED", x.Actor.UserId,
            "REQUESTER_VISIBLE", x.Cmd.Comment, null, x.Cmd.IdempotencyKey, x.Ct).ConfigureAwait(false);
        await CloseInstanceAsync(x, "CANCELLED", "CANCEL").ConfigureAwait(false);
        var next = await x.C.QuerySingleAsync<StageRow>(new CommandDefinition(
            """
            SELECT WorkflowStageId, StageKey, Kind, ExternalPhaseId, AssigneeRule, AssigneeRoleId, PoolPermissionId, AssigneeUserId, AssigneeDepartmentId, FallbackRoleId,
                   SlaHours, ClaimSlaHours, SlaMode, TerminalOutcome, SubStatusSetJson
              FROM wfl.WorkflowStage WHERE TemplateId = @t AND Kind = 'TERMINAL' AND TerminalOutcome = 'CANCELLED';
            """, new { t = x.R.TemplateId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        return await EnterAsync(x, next, x.R.CycleNo, null).ConfigureAwait(false);
    }

    /// <summary>
    /// CLOSE (BR-WFL-027, FR-WFL-042): a request waiting for its close is closed by a holder of req.treasury.close who is
    /// not its requester, creator or the assignee of its last stage, unless the same person is allowed (tagged).
    /// </summary>
    private static async Task<ActResult> CloseAsync(Ctx x)
    {
        if (x.R.Status != "AWAITING_CLOSE") throw WorkflowRefusalException.State("Only a request waiting for its close is closed.");
        if (!x.Actor.Permissions.Contains("req.treasury.close")) throw WorkflowRefusalException.Forbidden("You may not close requests.");
        var lastAssignee = await x.C.ExecuteScalarAsync<long?>(new CommandDefinition(
            """
            SELECT TOP (1) AssigneeUserId FROM wfl.RequestStageInstance WHERE RequestId = @r AND ExitedAt IS NOT NULL AND AssigneeUserId IS NOT NULL
             ORDER BY ExitedAt DESC, RequestStageInstanceId DESC;
            """, new { r = x.R.RequestId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        var sod = false;
        if (IsRequesterSide(x) || lastAssignee == x.Actor.UserId)
        {
            if (!(x.Inst.StageSod ?? x.R.TemplateSod)) throw WorkflowRefusalException.Forbidden("The requester, the creator or the last assignee does not close the request (BR-WFL-027).");
            sod = true;
        }
        var n = await x.C.ExecuteAsync(new CommandDefinition(
            """
            DECLARE @at DATETIME2(3) = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3));
            UPDATE wfl.RequestStageInstance SET Status = 'DONE', ExitedAt = @at, ExitAction = 'CLOSE', UpdatedAt = @at, UpdatedBy = @u
             WHERE RequestStageInstanceId = @i AND ExitedAt IS NULL;
            UPDATE r SET Status = 'COMPLETED', ClosedByUserId = @u, ClosedAt = @at, CompletedAt = @at, ExternalPhaseId = s.ExternalPhaseId, UpdatedAt = @at, UpdatedBy = @u
              FROM wfl.Request AS r JOIN wfl.RequestStageInstance AS i ON i.RequestStageInstanceId = @i JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId
             WHERE r.RequestId = @r AND r.Status = 'AWAITING_CLOSE';
            """, new { u = x.Actor.UserId, i = x.Inst.RequestStageInstanceId, r = x.R.RequestId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        if (n < 2) throw WorkflowRefusalException.Conflict();
        await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, "CLOSED", x.Inst.StageKey, null, x.Actor.UserId, "REQUESTER_VISIBLE",
            x.Cmd.Comment, null, x.Cmd.IdempotencyKey, x.Ct, sod: sod).ConfigureAwait(false);
        if (sod) await SodTagAsync(x).ConfigureAwait(false);
        await Outbox.EmitAsync(x.C, x.Tx, "request.closed", "wfl.Request", x.R.RequestId, new { requestId = x.R.RequestId }, x.Ct).ConfigureAwait(false);
        await NotifyAsync(x, "REQ.COMPLETED", [x.R.RequesterUserId, x.R.CreatedByUserId], "COMPLETED").ConfigureAwait(false);
        return new ActResult(x.R.RequestId, "COMPLETED", x.Inst.StageKey, x.R.RequestNo, false);
    }

    /// <summary>
    /// CLAIM (BR-WFL-007): a queued instance is taken by one eligible user with a conditional write (no assignee yet), so
    /// of two at once one wins and the other gets 409. A pure queue (TREASURY_QUEUE with nothing to fill in) completes
    /// into its next stage assigned to the claimer (OQ-7); a queue with work of its own stays claimed.
    /// </summary>
    private static async Task<ActResult> ClaimAsync(Ctx x)
    {
        if (x.Inst.Status != "QUEUED" || x.R.Status != "ACTIVE") throw WorkflowRefusalException.State("The request is not waiting in a queue.");
        if (!await EligibleAsync(x, x.Inst).ConfigureAwait(false)) throw WorkflowRefusalException.Forbidden("You are not in the group that takes this queue.");
        var n = await x.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.RequestStageInstance SET Status = 'CLAIMED', AssigneeUserId = @u, ClaimedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @u
             WHERE RequestStageInstanceId = @i AND Status = 'QUEUED' AND AssigneeUserId IS NULL AND ExitedAt IS NULL;
            """, new { u = x.Actor.UserId, i = x.Inst.RequestStageInstanceId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        if (n == 0) throw new WorkflowRefusalException(409, "ALREADY_CLAIMED", "Someone else took the request first.");
        await TouchAsync(x).ConfigureAwait(false);
        await ResolveNoticesAsync(x).ConfigureAwait(false);
        await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, "CLAIMED", x.Inst.StageKey, null, x.Actor.UserId, "INTERNAL", null, null,
            x.Cmd.IdempotencyKey, x.Ct).ConfigureAwait(false);
        await Outbox.EmitAsync(x.C, x.Tx, "request.claimed", "wfl.Request", x.R.RequestId, new { requestId = x.R.RequestId }, x.Ct).ConfigureAwait(false);
        var pure = x.Inst.Kind == "TREASURY_QUEUE" && (await FieldsAsync(x.C, x.Tx, x.R.TemplateId, x.Ct).ConfigureAwait(false)).All(f => !Listed(f.EditableStagesJson, x.Inst.StageKey))
                   && !await x.C.QueryFirstOrDefaultAsync<bool>(new CommandDefinition(
                       "SELECT TOP (1) CAST(1 AS BIT) FROM wfl.TemplateAttachmentRule WHERE TemplateId = @t AND RequiredBeforeStageKey = @k;",
                       new { t = x.R.TemplateId, k = x.Inst.StageKey }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        if (!pure) return new ActResult(x.R.RequestId, x.R.Status, x.Inst.StageKey, x.R.RequestNo, false);
        var claimed = await CurrentInstanceAsync(x.C, x.Tx, x.R.RequestId, x.Ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.Conflict();
        return await ForwardAsync(x with { Inst = claimed }, "COMPLETE", "DONE", null).ConfigureAwait(false);
    }

    /// <summary>RELEASE (BR-WFL-007): the claimer returns a claimed queue or claimer stage to the queue; its age is kept and ReleaseCount counts it.</summary>
    private static async Task<ActResult> ReleaseAsync(Ctx x)
    {
        if (x.Inst.Status != "CLAIMED" || (x.Inst.Kind != "TREASURY_QUEUE" && x.Inst.AssigneeRule != "CLAIMER"))
            throw WorkflowRefusalException.State("Only a claimed queue task is released.");
        if (x.Inst.AssigneeUserId != x.Actor.UserId && !x.Actor.Permissions.Contains("req.reassign")) throw WorkflowRefusalException.Forbidden("Only its claimer releases the task.");
        var n = await x.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.RequestStageInstance SET Status = 'QUEUED', AssigneeUserId = NULL, ClaimedAt = NULL, QueuedAt = ISNULL(QueuedAt, EnteredAt),
                   ReleaseCount = ReleaseCount + 1, UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @u
             WHERE RequestStageInstanceId = @i AND Status = 'CLAIMED' AND ExitedAt IS NULL;
            """, new { u = x.Actor.UserId, i = x.Inst.RequestStageInstanceId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        if (n == 0) throw WorkflowRefusalException.Conflict();
        await TouchAsync(x).ConfigureAwait(false);
        await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, "RELEASED", x.Inst.StageKey, null, x.Actor.UserId, "INTERNAL",
            x.Cmd.Comment, null, x.Cmd.IdempotencyKey, x.Ct).ConfigureAwait(false);
        await Outbox.EmitAsync(x.C, x.Tx, "request.released", "wfl.Request", x.R.RequestId, new { requestId = x.R.RequestId }, x.Ct).ConfigureAwait(false);
        return new ActResult(x.R.RequestId, x.R.Status, x.Inst.StageKey, x.R.RequestNo, false);
    }

    /// <summary>
    /// FR-NTF-007, BR-NTF-007: when the request moves on or its queue is taken, the open action-required notices about it
    /// are resolved for everyone, so one approval of an ANY stage clears the others' notices and their reminders stop.
    /// </summary>
    private static Task<int> ResolveNoticesAsync(Ctx x) => x.C.ExecuteAsync(new CommandDefinition(
        """
        UPDATE ntf.Notification SET ActionState = 'RESOLVED', ResolvedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), NextReminderAt = NULL,
               UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3))
         WHERE TargetEntityType = 'wfl.Request' AND TargetEntityId = @r AND ActionState = 'OPEN';
        """, new { r = x.R.RequestId }, x.Tx, cancellationToken: x.Ct));

    /// <summary>The roles and permissions of a user other than the actor, as an actor (for an assignee's eligibility).</summary>
    private static async Task<Actor> GrantsAsync(SqlConnection c, SqlTransaction tx, long userId, CancellationToken ct)
    {
        var rows = (await c.QueryAsync<(int RoleId, string? Code)>(new CommandDefinition(
            """
            SELECT ur.RoleId, p.Code FROM sec.UserRole AS ur JOIN sec.Role AS ro ON ro.RoleId = ur.RoleId AND ro.IsActive = 1
              LEFT JOIN sec.RolePermission AS rp ON rp.RoleId = ur.RoleId LEFT JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId
             WHERE ur.UserId = @u;
            """, new { u = userId }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        return new Actor(userId, rows.Where(r => r.Code is not null).Select(r => r.Code!).ToHashSet(StringComparer.Ordinal), rows.Select(r => (long)r.RoleId).ToHashSet());
    }

    /// <summary>
    /// REASSIGN (FR-WFL-014, BR-WFL-007): a holder of req.reassign gives an open task or queue to another user, with a
    /// reason. The user is active, takes the stage (its pool permission, role or req.claim), sees the request's company
    /// and is not its requester or creator. The stage becomes CLAIMED by them; its queue age is kept, ReassignCount counts
    /// it, and the new assignee hears REQ.REASSIGNED (internal: nothing reaches the requester).
    /// </summary>
    private static async Task<ActResult> ReassignAsync(Ctx x)
    {
        if (!x.Actor.Permissions.Contains("req.reassign")) throw WorkflowRefusalException.Forbidden("You may not reassign requests.");
        if (x.R.Status != "ACTIVE" || x.Inst.Kind is not ("TASK" or "TREASURY_QUEUE") || x.Inst.Status is not ("QUEUED" or "CLAIMED"))
            throw WorkflowRefusalException.State("Only an open task or queue is reassigned.");
        if (string.IsNullOrWhiteSpace(x.Cmd.Comment)) throw WorkflowRefusalException.Missing("V-WFL-REASON", "A reassignment gives its reason (FR-WFL-014).");
        var to = x.Cmd.AssignToUserId ?? throw WorkflowRefusalException.Missing("V-WFL-ASSIGNEE", "The user to assign is required.");
        if (to == x.Inst.AssigneeUserId) throw WorkflowRefusalException.State("The request is already with this user.");
        if (to == x.R.RequesterUserId || to == x.R.CreatedByUserId) throw WorkflowRefusalException.Missing("V-WFL-ASSIGNEE", "A request is not assigned to its requester (BR-WFL-006).");
        var user = await x.C.QuerySingleOrDefaultAsync<(string Status, string CompanyScopeMode, bool InScope)?>(new CommandDefinition(
            """
            SELECT u.Status, u.CompanyScopeMode,
                   CAST(CASE WHEN EXISTS (SELECT 1 FROM sec.UserCompanyScope AS s WHERE s.UserId = u.AppUserId AND s.CompanyId = @c) THEN 1 ELSE 0 END AS BIT)
              FROM sec.AppUser AS u WHERE u.AppUserId = @u AND u.ArchivedAt IS NULL AND u.IsSystemUser = 0;
            """, new { u = to, c = x.R.CompanyId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        if (user is not { Status: "ACTIVE" } found || (found.CompanyScopeMode != "ALL" && !found.InScope))
            throw WorkflowRefusalException.Missing("V-WFL-ASSIGNEE", "The user is not active or does not see the request's company.");
        if (!await EligibleAsync(x with { Actor = await GrantsAsync(x.C, x.Tx, to, x.Ct).ConfigureAwait(false) }, x.Inst).ConfigureAwait(false))
            throw WorkflowRefusalException.Missing("V-WFL-ASSIGNEE", "The user is not in the group that takes this stage.");
        var n = await x.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.RequestStageInstance SET Status = 'CLAIMED', AssigneeUserId = @to, QueuedAt = ISNULL(QueuedAt, EnteredAt),
                   ClaimedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), ReassignCount = ReassignCount + 1,
                   UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @u
             WHERE RequestStageInstanceId = @i AND Status IN ('QUEUED', 'CLAIMED') AND ExitedAt IS NULL;
            """, new { to, u = x.Actor.UserId, i = x.Inst.RequestStageInstanceId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        if (n == 0) throw WorkflowRefusalException.Conflict();
        await TouchAsync(x).ConfigureAwait(false);
        await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, "REASSIGNED", x.Inst.StageKey, null, x.Actor.UserId, "INTERNAL",
            x.Cmd.Comment, new { from = x.Inst.AssigneeUserId, to }, x.Cmd.IdempotencyKey, x.Ct).ConfigureAwait(false);
        await Outbox.EmitAsync(x.C, x.Tx, "request.reassigned", "wfl.Request", x.R.RequestId, new { requestId = x.R.RequestId }, x.Ct).ConfigureAwait(false);
        await NotifyAsync(x, "REQ.REASSIGNED", [to], $"reassigned:{x.Inst.RequestStageInstanceId}:{to}:{x.Now.UtcTicks}").ConfigureAwait(false);
        return new ActResult(x.R.RequestId, x.R.Status, x.Inst.StageKey, x.R.RequestNo, false);
    }

    /// <summary>
    /// SUBSTATUS (FR-WFL-015, BR-WFL-010): the assignee of a claimed stage moves among the stage's sub-statuses in any
    /// order; each change records how long the previous one lasted. A sub-status that pauses the SLA (AT_BANK by default)
    /// stops its clock: the stage is PAUSED, and on leaving it the due time moves on by the business hours of the pause
    /// (calendar hours for a CALENDAR stage) and SlaPausedSeconds counts the pause.
    /// </summary>
    private static async Task<ActResult> SubStatusAsync(Ctx x)
    {
        if (x.R.Status != "ACTIVE" || x.Inst.Status != "CLAIMED" || x.Inst.AssigneeUserId != x.Actor.UserId)
            throw WorkflowRefusalException.Forbidden("Only the assignee of the stage changes its sub-status.");
        var stage = await x.C.QuerySingleAsync<(string? Set, string SlaMode)>(new CommandDefinition(
            "SELECT SubStatusSetJson, SlaMode FROM wfl.WorkflowStage WHERE WorkflowStageId = @s;", new { s = x.Inst.StageId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        var set = new Dictionary<string, bool>(StringComparer.Ordinal);
        if (!string.IsNullOrEmpty(stage.Set))
        {
            using var doc = JsonDocument.Parse(stage.Set);
            foreach (var e in doc.RootElement.EnumerateArray())
                set[e.GetProperty("key").GetString()!] = e.TryGetProperty("pausesSla", out var p) && p.ValueKind == JsonValueKind.True;
        }
        var to = x.Cmd.SubStatus ?? "";
        if (!set.TryGetValue(to, out var pauses)) throw WorkflowRefusalException.Missing("V-WFL-SUBSTATUS", "The sub-status is not one of the stage's.");
        var from = await x.C.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT SubStatusKey FROM wfl.Request WHERE RequestId = @r;", new { r = x.R.RequestId }, x.Tx,
            cancellationToken: x.Ct)).ConfigureAwait(false);
        if (from == to) throw WorkflowRefusalException.State("The request is already in this sub-status.");
        var since = await x.C.ExecuteScalarAsync<DateTime?>(new CommandDefinition(
            "SELECT MAX(OccurredAt) FROM wfl.RequestAction WHERE StageInstanceId = @i AND ActionType = 'SUBSTATUS_CHANGED';", new { i = x.Inst.RequestStageInstanceId }, x.Tx,
            cancellationToken: x.Ct)).ConfigureAwait(false) ?? x.Inst.EnteredAt;
        var now = x.Now.UtcDateTime;
        var paused = from is not null && set.GetValueOrDefault(from);
        if (!paused && pauses)
            await x.C.ExecuteAsync(new CommandDefinition(
                "UPDATE wfl.RequestStageInstance SET SlaState = 'PAUSED', UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @u WHERE RequestStageInstanceId = @i AND DueAt IS NOT NULL;",
                new { u = x.Actor.UserId, i = x.Inst.RequestStageInstanceId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        else if (paused && !pauses && x.Inst.DueAt is { } due)
        {
            DateTime moved;
            if (stage.SlaMode == "CALENDAR") moved = due + (now - since);
            else
            {
                var start = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(since, DateTimeKind.Utc), x.Time.Zone);
                var end = TimeZoneInfo.ConvertTimeFromUtc(now, x.Time.Zone);
                var localDue = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(due, DateTimeKind.Utc), x.Time.Zone);
                var cal = await WorkingCalendar.LoadAsync(x.C, x.Tx, x.Time.CountryId, DateOnly.FromDateTime(start).AddDays(-1), DateOnly.FromDateTime(localDue > end ? localDue : end).AddDays(60), x.Ct)
                    .ConfigureAwait(false);
                var lost = cal.BusinessHoursBetween(start, end, x.Time.Start, x.Time.End);
                moved = TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(cal.AddBusinessHours(localDue, lost, x.Time.Start, x.Time.End), DateTimeKind.Unspecified), x.Time.Zone);
            }
            await x.C.ExecuteAsync(new CommandDefinition(
                """
                UPDATE wfl.RequestStageInstance SET DueAt = @due, SlaPausedSeconds = SlaPausedSeconds + @secs, SlaState = CASE WHEN @due > @now THEN 'ON_TRACK' ELSE 'OVERDUE' END,
                       UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @u
                 WHERE RequestStageInstanceId = @i;
                """, new { due = moved, secs = (int)Math.Max(0, (now - since).TotalSeconds), now, u = x.Actor.UserId, i = x.Inst.RequestStageInstanceId }, x.Tx, cancellationToken: x.Ct))
                .ConfigureAwait(false);
        }
        await x.C.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.Request SET SubStatusKey = @k, UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @u WHERE RequestId = @r;",
            new { k = to, u = x.Actor.UserId, r = x.R.RequestId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, "SUBSTATUS_CHANGED", x.Inst.StageKey, null, x.Actor.UserId, "INTERNAL",
            x.Cmd.Comment, new { from, to, previousSeconds = (int)Math.Max(0, (now - since).TotalSeconds), pausesSla = pauses }, x.Cmd.IdempotencyKey, x.Ct).ConfigureAwait(false);
        await Outbox.EmitAsync(x.C, x.Tx, "request.substatus.changed", "wfl.Request", x.R.RequestId, new { requestId = x.R.RequestId }, x.Ct).ConfigureAwait(false);
        return new ActResult(x.R.RequestId, x.R.Status, x.Inst.StageKey, x.R.RequestNo, false);
    }

    /// <summary>PRIORITY (BR-REQ-011, V-REQ-06): the requester on a draft, or a holder of req.reassign, sets NORMAL or URGENT; URGENT gives its reason.</summary>
    private static async Task<ActResult> PriorityAsync(Ctx x)
    {
        if (!(IsRequesterSide(x) && x.R.Status == "DRAFT") && !x.Actor.Permissions.Contains("req.reassign"))
            throw WorkflowRefusalException.Forbidden("You may not change the request's priority.");
        if (x.Cmd.Priority is not ("NORMAL" or "URGENT")) throw WorkflowRefusalException.Missing("V-REQ-06", "The priority is NORMAL or URGENT.");
        if (x.Cmd.Priority == "URGENT" && string.IsNullOrWhiteSpace(x.Cmd.Comment)) throw WorkflowRefusalException.Missing("V-REQ-06", "An urgent request gives its reason (BR-REQ-011).");
        var reason = x.Cmd.Priority == "URGENT" ? (x.Cmd.Comment!.Length > 500 ? x.Cmd.Comment[..500] : x.Cmd.Comment) : null;
        await x.C.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.Request SET Priority = @p, UrgentReason = @reason, UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @u WHERE RequestId = @r;",
            new { p = x.Cmd.Priority, reason, u = x.Actor.UserId, r = x.R.RequestId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        await ActionAsync(x.C, x.Tx, x.R.RequestId, x.Inst.RequestStageInstanceId, x.R.CycleNo, "PRIORITY_CHANGED", x.Inst.StageKey, null, x.Actor.UserId, "INTERNAL",
            x.Cmd.Comment, new { priority = x.Cmd.Priority }, x.Cmd.IdempotencyKey, x.Ct).ConfigureAwait(false);
        await Outbox.EmitAsync(x.C, x.Tx, "request.priority.changed", "wfl.Request", x.R.RequestId, new { requestId = x.R.RequestId }, x.Ct).ConfigureAwait(false);
        return new ActResult(x.R.RequestId, x.R.Status, x.Inst.StageKey, x.R.RequestNo, false);
    }

    /// <summary>The request's row version moves with every action, so a second action sent on the same version gets 409 (BR-WFL-023).</summary>
    private static Task<int> TouchAsync(Ctx x) => x.C.ExecuteAsync(new CommandDefinition(
        "UPDATE wfl.Request SET UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @u WHERE RequestId = @r;", new { u = x.Actor.UserId, r = x.R.RequestId }, x.Tx,
        cancellationToken: x.Ct));

    /// <summary>Who takes a queue: the holders of its pool permission, or of its role, or of req.claim for a claimer stage.</summary>
    private static async Task<bool> EligibleAsync(Ctx x, InstanceRow i)
    {
        if (i.PoolPermission is { } p) return x.Actor.Permissions.Contains(p);
        if (i.AssigneeRoleId is { } role) return x.Actor.RoleIds.Contains(role);
        await Task.CompletedTask.ConfigureAwait(false);
        return x.Actor.Permissions.Contains("req.claim");
    }

    private static async Task CloseInstanceAsync(Ctx x, string status, string exitAction)
    {
        var n = await x.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.RequestStageInstance
               SET Status = @status, ExitedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), ExitAction = @action,
                   SlaMet = CASE WHEN DueAt IS NULL THEN NULL WHEN CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)) <= DueAt THEN 1 ELSE 0 END, UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @u
             WHERE RequestStageInstanceId = @i AND ExitedAt IS NULL;
            """, new { status, action = exitAction, i = x.Inst.RequestStageInstanceId, u = x.Actor.UserId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        if (n == 0) throw WorkflowRefusalException.Conflict();
    }

    /// <summary>
    /// Enters a stage (BR-WFL-002): the instance with its status, assignee, due times and resume stage; the approval
    /// slots; the number on the numbering stage; the request's pointer, phase and status in one UPDATE; the ON_ENTER hooks;
    /// the action row; and the notices. A terminal COMPLETED stage leaves the request AWAITING_CLOSE with an open
    /// instance; REJECTED and CANCELLED end it at once.
    /// </summary>
    private static async Task<ActResult> EnterAsync(Ctx x, StageRow s, int cycle, int? resumeStageId)
    {
        var now = x.Now.UtcDateTime;
        string status;
        long? assignee = null;
        DateTime? queued = null;
        switch (s.Kind)
        {
            case "APPROVAL": status = "AWAITING_APPROVAL"; break;
            case "TREASURY_QUEUE": status = "QUEUED"; queued = now; break;
            case "TERMINAL": status = "QUEUED"; break;
            default:
                assignee = s.AssigneeRule switch
                {
                    "REQUESTER" => x.R.RequesterUserId,
                    "USER" => s.AssigneeUserId,
                    "CLAIMER" => x.Inst.AssigneeUserId ?? await x.C.ExecuteScalarAsync<long?>(new CommandDefinition(
                        """
                        SELECT TOP (1) i.AssigneeUserId FROM wfl.RequestStageInstance AS i JOIN wfl.WorkflowStage AS st ON st.WorkflowStageId = i.StageId
                         WHERE i.RequestId = @r AND st.Kind = 'TREASURY_QUEUE' AND i.AssigneeUserId IS NOT NULL ORDER BY i.RequestStageInstanceId DESC;
                        """, new { r = x.R.RequestId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false),
                    "REQUESTER_MANAGER" => (await ManagerAsync(x.C, x.Tx, x.R, s.FallbackRoleId, x.Ct).ConfigureAwait(false)).UserId,
                    _ => null,
                };
                status = assignee is null ? "QUEUED" : "CLAIMED";
                if (assignee is null) queued = x.Inst.QueuedAt ?? now;
                break;
        }
        var due = s.Kind == "TERMINAL" ? null : await DueAsync(x.C, x.Tx, x.Time, x.Now, s.SlaHours, s.SlaMode, x.Ct).ConfigureAwait(false);
        var claimDue = s.Kind == "TREASURY_QUEUE" ? await DueAsync(x.C, x.Tx, x.Time, x.Now, s.ClaimSlaHours, s.SlaMode, x.Ct).ConfigureAwait(false) : null;
        var instance = await InsertInstanceAsync(x.C, x.Tx, x.R.RequestId, x.R.TemplateId, s, cycle, status, assignee, now, queued, due, claimDue, resumeStageId, x.Ct)
            .ConfigureAwait(false);
        var outcome = s.Kind == "TERMINAL" ? s.TerminalOutcome : null;
        var newStatus = outcome switch { "COMPLETED" => "AWAITING_CLOSE", "REJECTED" => "REJECTED", "CANCELLED" => "CANCELLED", _ => "ACTIVE" };
        if (outcome is "REJECTED" or "CANCELLED")
            await x.C.ExecuteAsync(new CommandDefinition(
                """
                UPDATE wfl.RequestStageInstance SET Status = 'DONE', ExitedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), ExitAction = @a WHERE RequestStageInstanceId = @i;
                """, new { a = outcome == "REJECTED" ? "REJECT" : "CANCEL", i = instance }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        var subStatus = FirstSubStatus(s.SubStatusSetJson);
        var reason = outcome is "REJECTED" or "CANCELLED" ? x.Cmd.Comment is { Length: > 500 } t ? t[..500] : x.Cmd.Comment : null;
        var n = await x.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.Request
               SET CurrentStageInstanceId = @i, ExternalPhaseId = @phase, SubStatusKey = @sub, Status = @status, CycleNo = @cycle,
                   ReadyToCloseAt = CASE WHEN @status = 'AWAITING_CLOSE' THEN CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)) ELSE ReadyToCloseAt END,
                   CompletedAt = CASE WHEN @status IN ('REJECTED', 'CANCELLED') THEN CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)) ELSE CompletedAt END,
                   OutcomeReason = CASE WHEN @status IN ('REJECTED', 'CANCELLED') THEN @reason ELSE OutcomeReason END,
                   UpdatedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), UpdatedBy = @u
             WHERE RequestId = @r;
            """, new { i = instance, phase = outcome == "COMPLETED" ? await InProgressPhaseAsync(x, s.ExternalPhaseId).ConfigureAwait(false) : s.ExternalPhaseId, sub = subStatus, status = newStatus, cycle, reason, u = x.Actor.UserId, r = x.R.RequestId }, x.Tx,
            cancellationToken: x.Ct)).ConfigureAwait(false);
        if (n == 0) throw WorkflowRefusalException.Conflict();
        await ResolveNoticesAsync(x).ConfigureAwait(false);
        var r = await FindAsync(x.C, x.Tx, x.R.RequestId, true, x.Ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        var entered = await CurrentInstanceAsync(x.C, x.Tx, x.R.RequestId, x.Ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.Conflict();
        var y = x with { R = r, Inst = entered };
        var approvers = s.Kind == "APPROVAL" ? await SlotsAsync(y, s, instance, cycle).ConfigureAwait(false) : [];
        if (r.NumberOnStageKey == s.StageKey && r.RequestNo is null) await NumberAsync(y, instance).ConfigureAwait(false);
        await HooksAsync(y, entered, "ON_ENTER", null).ConfigureAwait(false);
        await ActionAsync(x.C, x.Tx, r.RequestId, instance, cycle, outcome == "COMPLETED" ? "READY_TO_CLOSE" : "STAGE_CHANGED", x.Inst.StageKey, s.StageKey, x.Actor.UserId,
            "INTERNAL", null, null, null, x.Ct).ConfigureAwait(false);
        await Outbox.EmitAsync(x.C, x.Tx, outcome switch
        {
            "COMPLETED" => "request.ready_to_close", "REJECTED" => "request.rejected", "CANCELLED" => "request.cancelled", _ => "request.stage.entered",
        }, "wfl.Request", r.RequestId, new { requestId = r.RequestId, stage = s.StageKey }, x.Ct).ConfigureAwait(false);
        await EnterNoticesAsync(y, s, outcome, approvers).ConfigureAwait(false);
        // ALL slots already complete (the originator's own slot at submission, BR-WFL-004) move the request on in the same transaction.
        if (s.Kind == "APPROVAL" && await x.C.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM wfl.RequestApproval WHERE StageInstanceId = @i AND Decision = 'PENDING';", new { i = instance }, x.Tx, cancellationToken: x.Ct))
            .ConfigureAwait(false) == 0)
            return await ForwardAsync(y, "APPROVE", "DONE", null).ConfigureAwait(false);
        return new ActResult(r.RequestId, newStatus, s.StageKey, r.RequestNo, false);
    }

    /// <summary>Until the treasury closes it, the requester sees a finished request "in progress" (BR-WFL-011, 027).</summary>
    private static async Task<int> InProgressPhaseAsync(Ctx x, int fallback) =>
        await x.C.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT ExternalPhaseId FROM wfl.ExternalPhase WHERE Code = 'IN_PROGRESS' AND IsActive = 1;",
            transaction: x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false) ?? fallback;

    private static string? FirstSubStatus(string? json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.ValueKind == JsonValueKind.Array && doc.RootElement.GetArrayLength() > 0 && doc.RootElement[0].TryGetProperty("key", out var k) ? k.GetString() : null;
    }

    /// <summary>The slots of an approval stage, each frozen to its subject (BR-WFL-003, 004, 005); the originator's own slot completes by submission.</summary>
    private static async Task<List<long>> SlotsAsync(Ctx x, StageRow s, long instance, int cycle)
    {
        var slots = await x.C.QueryAsync<SlotRow>(new CommandDefinition(
            "SELECT SlotKey, SubjectRule, RoleId, UserId, DepartmentId, FallbackRoleId, AutoCompleteBySubmitter FROM wfl.StageApprover WHERE StageId = @s ORDER BY SlotKey;",
            new { s = s.WorkflowStageId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        var users = new List<long>();
        foreach (var slot in slots)
        {
            var who = await SlotSubjectAsync(x.C, x.Tx, x.R, slot, x.Ct).ConfigureAwait(false);
            var auto = slot.AutoCompleteBySubmitter && x.R.SubmittedByUserId == x.R.RequesterUserId;
            await x.C.ExecuteAsync(new CommandDefinition(
                """
                INSERT wfl.RequestApproval (TenantId, RequestId, StageInstanceId, CycleNo, SlotKey, AssignedUserId, AssignedRoleId, Decision, Source, ActedByUserId, ActedAt,
                                            SnapshotHash, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, @slot, @user, @role, @d, @src, @actedBy, @actedAt, @hash,
                        CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """,
                new
                {
                    r = x.R.RequestId, i = instance, cycle, slot = slot.SlotKey, user = who.UserId, role = who.RoleId, d = auto ? "APPROVED" : "PENDING",
                    src = auto ? "SUBMISSION" : null, actedBy = auto ? x.R.RequesterUserId : (long?)null, actedAt = auto ? x.Now.UtcDateTime : (DateTime?)null,
                    hash = auto ? Snapshot.Hash(s.StageKey, cycle, x.R.FormDataJson, x.R.Amount, x.R.CurrencyCode) : null,
                }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
            if (!auto && who.UserId is { } u) users.Add(u);
            if (!auto && who.RoleId is { } role)
                users.AddRange(await x.C.QueryAsync<long>(new CommandDefinition(
                    "SELECT ur.UserId FROM sec.UserRole AS ur JOIN sec.AppUser AS a ON a.AppUserId = ur.UserId WHERE ur.RoleId = @role AND a.Status = 'ACTIVE';",
                    new { role }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false));
            if (who.Source is not ("REQUESTER" or "USER" or "ROLE"))
                await ActionAsync(x.C, x.Tx, x.R.RequestId, instance, cycle, "STAGE_CHANGED", s.StageKey, s.StageKey, null, "INTERNAL", null,
                    new { slot = slot.SlotKey, assigneeSource = who.Source }, null, x.Ct).ConfigureAwait(false);
        }
        return users;
    }

    /// <summary>
    /// The request number (BR-WFL-013): allocated once, on entering the numbering stage, from the gap-free sequence of the
    /// type in this transaction, for the tenant's calendar year; the sequence value and year are read from the issue.
    /// </summary>
    private static async Task NumberAsync(Ctx x, long instance)
    {
        var p = new DynamicParameters();
        p.Add("@SequenceKey", "req:" + x.R.TypeCode, DbType.AnsiString, size: 50);
        p.Add("@OnDate", TimeZoneInfo.ConvertTime(x.Now, x.Time.Zone).Date, DbType.Date);
        p.Add("@EntityType", "wfl.Request", DbType.AnsiString, size: 60);
        p.Add("@EntityId", x.R.RequestId, DbType.Int64);
        p.Add("@IssuedNumber", null, DbType.String, ParameterDirection.Output, 60);
        p.Add("@NumberIssueId", null, DbType.Int64, ParameterDirection.Output);
        await x.C.ExecuteAsync(new CommandDefinition("cfg.usp_AllocateNumber", p, x.Tx, commandType: CommandType.StoredProcedure, cancellationToken: x.Ct)).ConfigureAwait(false);
        var number = p.Get<string>("@IssuedNumber");
        var issue = await x.C.QuerySingleAsync<(long SeqValue, string Period)>(new CommandDefinition(
            "SELECT i.SeqValue, q.PeriodKey FROM cfg.NumberIssue AS i JOIN cfg.NumberSequence AS q ON q.NumberSequenceId = i.SequenceId WHERE i.NumberIssueId = @id;", new { id = p.Get<long>("@NumberIssueId") }, x.Tx, cancellationToken: x.Ct))
            .ConfigureAwait(false);
        var year = short.TryParse(issue.Period[..Math.Min(4, issue.Period.Length)], NumberStyles.None, CultureInfo.InvariantCulture, out var y) ? y
            : (short)TimeZoneInfo.ConvertTime(x.Now, x.Time.Zone).Year;
        await x.C.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.Request SET RequestNo = @no, NumberYear = @year, NumberSeq = @seq WHERE RequestId = @r AND RequestNo IS NULL;",
            new { no = number, year, seq = (int)issue.SeqValue, r = x.R.RequestId }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        await ActionAsync(x.C, x.Tx, x.R.RequestId, instance, x.R.CycleNo, "NUMBER_ASSIGNED", null, null, null, "REQUESTER_VISIBLE", null, new { number }, null, x.Ct)
            .ConfigureAwait(false);
        await Outbox.EmitAsync(x.C, x.Tx, "request.numbered", "wfl.Request", x.R.RequestId, new { requestId = x.R.RequestId }, x.Ct).ConfigureAwait(false);
    }

    // ---------- hooks (FR-WFL-021, BR-WFL-015) ----------

    /// <summary>A hook's code: given the request and the stage, it does its work in the transaction and returns its stored result.</summary>
    public delegate Task<object?> HookBody(HookContext h);

    public sealed record HookContext(SqlConnection C, SqlTransaction Tx, Actor Actor, RequestRow Request, long StageInstanceId, string StageKey, string? ParamsJson,
        ActCommand Command, DateTimeOffset Now, string IdempotencyKey, CancellationToken Ct);

    private static readonly Dictionary<string, HookBody> Bodies = new(StringComparer.Ordinal)
    {
        [HookKeys.ReleaseReservation] = ReleaseReservationAsync,
        [HookKeys.ValidateTerms] = Lc.TermsStore.ValidateHookAsync,
        [HookKeys.CheckAvailability] = FacilityHooks.CheckAvailabilityAsync,
        [HookKeys.ReserveLimit] = FacilityHooks.ReserveLimitAsync,
        [HookKeys.ConvertReservation] = Lc.IssuanceHooks.ConvertAsync,
        [HookKeys.RecordIssuance] = Lc.IssuanceHooks.RecordAsync,
    };

    /// <summary>Registers the code of a hook key (the facility and letter-of-credit modules do, S3 batches D to G).</summary>
    public static void Register(string key, HookBody body)
    {
        if (!HookKeys.All.Contains(key)) throw new ArgumentException($"The hook {key} is not a registered key.", nameof(key));
        lock (Bodies) Bodies[key] = body;
    }

    /// <summary>
    /// Runs the hooks of a stage for a trigger (and action), in order, once per stage instance: a hook that already
    /// succeeded here is not run again. A SYNC_TX hook that fails with BLOCK throws, which rolls the action back; a WARN
    /// failure is recorded and the action goes on. A key with no code yet refuses the action (HOOK_NOT_AVAILABLE).
    /// </summary>
    private static async Task HooksAsync(Ctx x, InstanceRow at, string trigger, string? action)
    {
        var hooks = await x.C.QueryAsync<(string HookKey, string? ParamsJson, string ExecMode, string OnFailure)>(new CommandDefinition(
            """
            SELECT HookKey, ParamsJson, ExecMode, OnFailure FROM wfl.WorkflowStageHook
             WHERE StageId = @s AND TriggerKind = @trigger AND (@action IS NULL OR ActionFilter = @action) ORDER BY SeqNo, HookKey;
            """, new { s = at.StageId, trigger, action }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
        foreach (var h in hooks)
        {
            var done = await x.C.ExecuteScalarAsync<int>(new CommandDefinition(
                """
                SELECT COUNT(*) FROM wfl.HookExecution WHERE RequestId = @r AND StageInstanceId = @i AND HookKey = @k AND TriggerKind = @trigger
                   AND ISNULL(ActionFilter, '') = ISNULL(@action, '') AND Status = 'SUCCEEDED';
                """, new { r = x.R.RequestId, i = at.RequestStageInstanceId, k = h.HookKey, trigger, action }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
            if (done > 0) continue;
            HookBody? body;
            lock (Bodies) Bodies.TryGetValue(h.HookKey, out body);
            if (body is null) throw new WorkflowRefusalException(409, "HOOK_NOT_AVAILABLE", $"The step {h.HookKey} of this stage is not available yet.");
            var key = $"{x.R.RequestId}:{at.RequestStageInstanceId}:{h.HookKey}:{trigger}:{action}";
            object? result;
            try
            {
                result = await body(new HookContext(x.C, x.Tx, x.Actor, x.R, at.RequestStageInstanceId, at.StageKey, h.ParamsJson, x.Cmd, x.Now, key, x.Ct)).ConfigureAwait(false);
            }
            catch (WorkflowRefusalException) when (h.OnFailure == "WARN")
            {
                result = new { warning = true };
            }
            await x.C.ExecuteAsync(new CommandDefinition(
                """
                MERGE wfl.HookExecution AS t
                USING (SELECT @r AS RequestId, @i AS StageInstanceId, @k AS HookKey, @trigger AS TriggerKind, @action AS ActionFilter) AS s
                   ON t.RequestId = s.RequestId AND t.StageInstanceId = s.StageInstanceId AND t.HookKey = s.HookKey AND t.TriggerKind = s.TriggerKind
                  AND ISNULL(t.ActionFilter, '') = ISNULL(s.ActionFilter, '')
                WHEN MATCHED THEN UPDATE SET Status = 'SUCCEEDED', AttemptCount = t.AttemptCount + 1, ResultJson = @result, ExecutedAt = CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)), ErrorCode = NULL,
                     LastError = NULL
                WHEN NOT MATCHED THEN INSERT (TenantId, RequestId, StageInstanceId, HookKey, TriggerKind, ActionFilter, ExecMode, OnFailure, Status, AttemptCount, IdempotencyKey,
                     ResultJson, ExecutedAt, CreatedBy)
                     VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @k, @trigger, @action, @mode, @fail, 'SUCCEEDED', 1, @key, @result, CAST(SESSION_CONTEXT(N'EngineNow') AS DATETIME2(3)),
                             CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """,
                new
                {
                    r = x.R.RequestId, i = at.RequestStageInstanceId, k = h.HookKey, trigger, action, mode = h.ExecMode, fail = h.OnFailure,
                    key = key.Length > 100 ? key[..100] : key, result = result is null ? null : JsonSerializer.Serialize(result),
                }, x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
            await ActionAsync(x.C, x.Tx, x.R.RequestId, at.RequestStageInstanceId, x.R.CycleNo, "HOOK_EXECUTED", at.StageKey, null, null, "INTERNAL", null,
                new { hook = h.HookKey, trigger, action }, null, x.Ct).ConfigureAwait(false);
        }
    }

    /// <summary>fac.release_reservation (OQ-6): the request's active reservation, if any, is released with the reason of the stage; without one it does nothing.</summary>
    private static async Task<object?> ReleaseReservationAsync(HookContext h)
    {
        var reservation = await h.C.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT LimitReservationId FROM fac.LimitReservation WHERE RequestId = @r AND Status = 'ACTIVE';", new { r = h.Request.RequestId }, h.Tx, cancellationToken: h.Ct))
            .ConfigureAwait(false);
        if (reservation is not { } id) return new { released = false };
        var reason = "CANCELLED";
        if (h.ParamsJson is { } p)
        {
            using var doc = JsonDocument.Parse(p);
            if (doc.RootElement.TryGetProperty("reason", out var r) && r.GetString() is "REJECTED" or "CANCELLED") reason = r.GetString()!;
        }
        var released = await Facilities.ReservationService.ReleaseAsync(h.C, h.Tx, id, reason, h.Actor.UserId, h.Now.UtcDateTime.Date, h.Ct).ConfigureAwait(false);
        return new { released, reservationId = id };
    }

    // ---------- notices ----------

    private static Task NotifyAsync(Ctx x, string eventCode, IEnumerable<long> users, string key) =>
        Notifier.RequestAsync(x.C, x.Tx, new NotificationRequest(eventCode, "wfl.Request", x.R.RequestId, $"{eventCode}:{x.R.RequestId}:{x.R.CycleNo}:{key}", x.R.CompanyId,
            new Dictionary<string, object?>
            {
                ["requestNo"] = x.R.RequestNo ?? x.R.DraftRef, ["typeName"] = x.R.TypeCode, ["amount"] = x.R.Amount?.ToString("N2", CultureInfo.InvariantCulture),
                ["currency"] = x.R.CurrencyCode,
            }, $"/requests/{x.R.PublicId}", x.Actor.UserId, [.. users.Distinct()]), x.Ct);

    private static async Task EnterNoticesAsync(Ctx x, StageRow s, string? outcome, List<long> approvers)
    {
        var requester = new[] { x.R.RequesterUserId, x.R.CreatedByUserId };
        switch (outcome)
        {
            case "REJECTED": await NotifyAsync(x, "REQ.REJECTED", requester, "rejected").ConfigureAwait(false); return;
            case "CANCELLED": await NotifyAsync(x, "REQ.CANCELLED", requester, "cancelled").ConfigureAwait(false); return;
            case "COMPLETED":
                await Notifier.RequestAsync(x.C, x.Tx, new NotificationRequest("REQ.READY_TO_CLOSE", "wfl.Request", x.R.RequestId, $"REQ.READY_TO_CLOSE:{x.R.RequestId}",
                    x.R.CompanyId, new Dictionary<string, object?> { ["requestNo"] = x.R.RequestNo ?? x.R.DraftRef, ["typeName"] = x.R.TypeCode },
                    $"/requests/{x.R.PublicId}", x.Actor.UserId), x.Ct).ConfigureAwait(false);
                return;
        }
        if (approvers.Count > 0)
        {
            // FR-WFL-020: the slot shows to the delegate of an approver for the delegation's period, and so does its notice.
            var delegates = await x.C.QueryAsync<long>(new CommandDefinition(
                """
                SELECT d.ToUserId FROM wfl.UserDelegation AS d
                 WHERE d.FromUserId IN @users AND d.Status IN ('SCHEDULED', 'ACTIVE') AND @today BETWEEN d.StartsOn AND d.EndsOn
                   AND (d.Scope <> 'REQUEST_TYPE' OR d.RequestTypeId = @type) AND d.ToUserId NOT IN (@rq, @cr);
                """, new { users = approvers, today = TimeZoneInfo.ConvertTime(x.Now, x.Time.Zone).Date, type = x.R.RequestTypeId, rq = x.R.RequesterUserId, cr = x.R.CreatedByUserId },
                x.Tx, cancellationToken: x.Ct)).ConfigureAwait(false);
            await NotifyAsync(x, "REQ.APPROVAL_NEEDED", approvers.Concat(delegates), s.StageKey).ConfigureAwait(false);
        }
        if (s.StageKey == "RETURNED") await NotifyAsync(x, "REQ.RETURNED", requester, "returned").ConfigureAwait(false);
        else if (s.AssigneeRule == "REQUESTER" && s.Kind == "TASK") await NotifyAsync(x, "REQ.ACTION_REQUIRED_REQUESTER", requester, s.StageKey).ConfigureAwait(false);
        if (s.Kind == "TREASURY_QUEUE")
            await Notifier.RequestAsync(x.C, x.Tx, new NotificationRequest("REQ.QUEUED", "wfl.Request", x.R.RequestId, $"REQ.QUEUED:{x.R.RequestId}:{s.StageKey}:{x.R.CycleNo}",
                x.R.CompanyId, new Dictionary<string, object?> { ["requestNo"] = x.R.RequestNo ?? x.R.DraftRef, ["typeName"] = x.R.TypeCode, ["stageLabel"] = s.StageKey },
                $"/requests/{x.R.PublicId}", x.Actor.UserId), x.Ct).ConfigureAwait(false);
    }
}

using System.Text.Json;
using System.Text.Json.Serialization;

namespace BankFas.Core.Workflow;

/// <summary>
/// A workflow template version as data (FR-WFL-001, spec 13 section 5.5): its stages with their slots, hooks and
/// sub-statuses, its transitions, fields and attachment rules. Stages, roles, permissions, document types and phases
/// are named by their keys and codes; the installer and the publisher resolve them to rows. The seed pack WFL.BASE
/// writes one file of this shape per template (S3 brief OQ-2).
/// </summary>
public sealed record TemplateGraph
{
    public required string TemplateKey { get; init; }
    public required string RequestType { get; init; }
    /// <summary>The SeedKey of the seeded row; the template key when absent (CHILD_STANDARD serves two types, OQ-8).</summary>
    public string? SeedKey { get; init; }
    public string? NameAr { get; init; }
    public string? NameEn { get; init; }
    public string? NumberOnStageKey { get; init; }
    public bool ResetApprovalsOnResubmit { get; init; } = true;
    public bool SodAllowSamePerson { get; init; }
    public IReadOnlyList<StageDef> Stages { get; init; } = [];
    public IReadOnlyList<TransitionDef> Transitions { get; init; } = [];
    public IReadOnlyList<FieldDef> Fields { get; init; } = [];
    public IReadOnlyList<AttachmentDef> Attachments { get; init; } = [];

    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public static TemplateGraph Parse(string json) => JsonSerializer.Deserialize<TemplateGraph>(json, Json) ?? throw new InvalidDataException("An empty template.");
}

public sealed record StageDef
{
    public required string Key { get; init; }
    public required string Kind { get; init; }
    public string? NameAr { get; init; }
    public string? NameEn { get; init; }
    public string? Phase { get; init; }
    public int Seq { get; init; }
    public AssigneeDef? Assignee { get; init; }
    public string ApprovalMode { get; init; } = "NONE";
    public decimal? SlaHours { get; init; }
    public decimal? ClaimSlaHours { get; init; }
    public string SlaMode { get; init; } = "BUSINESS";
    public string? Outcome { get; init; }
    public bool AllowRequesterCancel { get; init; }
    public bool AllowReturn { get; init; }
    public bool RequiresComment { get; init; }
    public bool IsReservationPoint { get; init; }
    public bool? SodAllowSamePerson { get; init; }
    public IReadOnlyList<SubStatusDef> SubStatuses { get; init; } = [];
    public IReadOnlyList<string>? EditableFieldKeys { get; init; }
    public IReadOnlyList<SlotDef> Slots { get; init; } = [];
    public IReadOnlyList<HookDef> Hooks { get; init; } = [];
}

/// <summary>Who holds a stage (FR-WFL-005): a rule, and its role, pool permission, user or department.</summary>
public sealed record AssigneeDef(string Rule, string? Role = null, string? PoolPermission = null, long? User = null, string? Department = null, string? FallbackRole = null);

public sealed record SubStatusDef(string Key, string NameAr, string NameEn, bool PausesSla);

public sealed record SlotDef
{
    public required string Key { get; init; }
    public string? LabelAr { get; init; }
    public string? LabelEn { get; init; }
    public string WorkflowRole { get; init; } = "APPROVER";
    public required string Subject { get; init; }
    public string? Role { get; init; }
    public string? FallbackRole { get; init; }
    public bool AutoCompleteBySubmitter { get; init; }
    public bool AllowDelegation { get; init; } = true;
}

public sealed record HookDef
{
    public required string Trigger { get; init; }
    public string? Action { get; init; }
    public required string Key { get; init; }
    public JsonElement? Params { get; init; }
    public string Mode { get; init; } = "SYNC_TX";
    public string OnFailure { get; init; } = "BLOCK";
    public int Seq { get; init; } = 1;
}

public sealed record TransitionDef
{
    public required string From { get; init; }
    public required string Action { get; init; }
    public required string To { get; init; }
    public int Priority { get; init; } = 1;
    public JsonElement? Condition { get; init; }
    public string? Resume { get; init; }
    public string? LabelAr { get; init; }
    public string? LabelEn { get; init; }
    public bool RequiresComment { get; init; }
}

public sealed record FieldDef
{
    public required string Key { get; init; }
    public required string LabelAr { get; init; }
    public required string LabelEn { get; init; }
    public string? HelpAr { get; init; }
    public string? HelpEn { get; init; }
    public string? Section { get; init; }
    public int Seq { get; init; }
    public required string Type { get; init; }
    public JsonElement? Config { get; init; }
    public bool Required { get; init; }
    public JsonElement? RequiredWhen { get; init; }
    public JsonElement? VisibleWhen { get; init; }
    public IReadOnlyList<string>? VisibleStages { get; init; }
    public IReadOnlyList<string>? EditableStages { get; init; }
    public string Sensitivity { get; init; } = "NORMAL";
    public string IndexRole { get; init; } = "NONE";
    public bool KeepWhenHidden { get; init; }
    public JsonElement? Validation { get; init; }
}

public sealed record AttachmentDef
{
    public required string Slot { get; init; }
    public string? LabelAr { get; init; }
    public string? LabelEn { get; init; }
    public required string DocumentType { get; init; }
    public int Min { get; init; }
    public int? Max { get; init; }
    public string? RequiredBeforeStage { get; init; }
    public JsonElement? RequiredWhen { get; init; }
    public bool VisibleToRequester { get; init; }
}

/// <summary>
/// The checks of a template before it is published (V-WFL-01 to 03; FR-WFL-003, 028, 029): one start, every stage
/// named, phased and reachable, every non-terminal stage with a way out, the three outcomes present, the approval
/// slots, the registered hooks, the conditions over known non-restricted fields, and the numbering stage. Returns
/// every problem found, an empty list when the graph may be published.
/// </summary>
public static class TemplateValidator
{
    private static readonly HashSet<string> Kinds = ["DRAFT", "TASK", "APPROVAL", "TREASURY_QUEUE", "TERMINAL"];
    private static readonly HashSet<string> Actions = ["SUBMIT", "APPROVE", "COMPLETE", "RETURN", "REJECT", "CANCEL", "RESUBMIT"];
    private static readonly HashSet<string> Triggers = ["ON_ENTER", "ON_EXIT", "ON_ACTION"];

    public static IReadOnlyList<string> Validate(TemplateGraph g, IReadOnlySet<string> knownHooks, IReadOnlySet<string> phases)
    {
        ArgumentNullException.ThrowIfNull(g);
        ArgumentNullException.ThrowIfNull(knownHooks);
        ArgumentNullException.ThrowIfNull(phases);
        var errors = new List<string>();
        var stages = new Dictionary<string, StageDef>(StringComparer.Ordinal);
        foreach (var s in g.Stages)
        {
            if (!stages.TryAdd(s.Key, s)) errors.Add($"V-WFL-01: the stage {s.Key} appears twice.");
            if (!Kinds.Contains(s.Kind)) errors.Add($"V-WFL-01: the stage {s.Key} has an unknown kind {s.Kind}.");
            if (string.IsNullOrWhiteSpace(s.NameAr) || string.IsNullOrWhiteSpace(s.NameEn)) errors.Add($"FR-WFL-003: the stage {s.Key} has no name.");
            if (s.Phase is null || !phases.Contains(s.Phase)) errors.Add($"FR-WFL-003: the stage {s.Key} has no visible phase.");
            if (s.Kind == "APPROVAL" && (s.ApprovalMode is not ("ANY" or "ALL") || s.Slots.Count == 0))
                errors.Add($"FR-WFL-007: the approval stage {s.Key} needs ANY or ALL and at least one slot.");
            if (s.Kind != "APPROVAL" && (s.ApprovalMode != "NONE" || s.Slots.Count > 0)) errors.Add($"FR-WFL-007: only an approval stage has slots ({s.Key}).");
            if (s.Kind == "TERMINAL" && s.Outcome is not ("COMPLETED" or "REJECTED" or "CANCELLED")) errors.Add($"V-WFL-01: the terminal stage {s.Key} has no outcome.");
            if (s.Kind != "TERMINAL" && s.Outcome is not null) errors.Add($"V-WFL-01: only a terminal stage has an outcome ({s.Key}).");
            if (s.Kind == "TREASURY_QUEUE" && (s.Assignee is not { Rule: "ROLE" } a || (a.Role is null) == (a.PoolPermission is null)))
                errors.Add($"FR-WFL-004: the queue {s.Key} starts with a role or a pool permission.");
            if (s.Kind is "TASK" or "DRAFT" && s.Assignee is null) errors.Add($"FR-WFL-005: the stage {s.Key} has no assignee rule.");
            if (s.IsReservationPoint && s.Kind != "APPROVAL") errors.Add($"BR-WFL-016: the reservation point {s.Key} is an approval stage.");
            var slotKeys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var slot in s.Slots)
            {
                if (!slotKeys.Add(slot.Key)) errors.Add($"FR-WFL-007: the slot {slot.Key} of {s.Key} appears twice.");
                if (slot.Subject == "ROLE" && slot.Role is null) errors.Add($"FR-WFL-007: the slot {slot.Key} of {s.Key} names no role.");
                if (slot.AutoCompleteBySubmitter && slot.Subject != "REQUESTER") errors.Add($"BR-WFL-004: only a requester slot completes by submission ({s.Key}).");
            }
            var hookKeys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var h in s.Hooks)
            {
                if (!knownHooks.Contains(h.Key)) errors.Add($"V-WFL-02: the hook {h.Key} of {s.Key} is not registered.");
                if (!Triggers.Contains(h.Trigger) || (h.Trigger == "ON_ACTION") != (h.Action is not null) || (h.Action is not null && !Actions.Contains(h.Action)))
                    errors.Add($"V-WFL-02: the hook {h.Key} of {s.Key} has a wrong trigger or action.");
                if (!hookKeys.Add($"{h.Trigger}|{h.Action}|{h.Key}")) errors.Add($"V-WFL-02: the hook {h.Key} of {s.Key} appears twice.");
            }
        }
        if (g.Stages.Count(s => s.Kind == "DRAFT") != 1) errors.Add("V-WFL-01: a template has exactly one DRAFT stage.");
        foreach (var o in new[] { "COMPLETED", "REJECTED", "CANCELLED" })
            if (!g.Stages.Any(s => s.Kind == "TERMINAL" && s.Outcome == o)) errors.Add($"V-WFL-01: no terminal stage for {o}.");

        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var t in g.Transitions)
        {
            if (!stages.ContainsKey(t.From) || !stages.ContainsKey(t.To)) { errors.Add($"V-WFL-01: the transition {t.From} {t.Action} {t.To} names an unknown stage."); continue; }
            if (!Actions.Contains(t.Action)) errors.Add($"V-WFL-01: unknown action {t.Action}.");
            if (t.Action == "CANCEL") errors.Add("OQ-6: CANCEL is added by the engine from every stage; it is not a transition of the template.");
            if (t.From == t.To) errors.Add($"V-WFL-01: the transition {t.From} {t.Action} loops on itself.");
            if (stages[t.From].Kind == "TERMINAL") errors.Add($"V-WFL-01: a terminal stage has no way out ({t.From}).");
            if (t.Resume is not null && (t.Action is not ("RETURN" or "RESUBMIT") || !stages.ContainsKey(t.Resume)))
                errors.Add($"FR-WFL-010: the resume stage of {t.From} {t.Action} is wrong.");
            if (t.Priority < 1 || !seen.Add($"{t.From}|{t.Action}|{t.Priority}")) errors.Add($"BR-WFL-001: {t.From} {t.Action} repeats priority {t.Priority}.");
            if (t.Condition is { } cond)
                foreach (var f in ConditionFields(cond))
                {
                    var field = g.Fields.FirstOrDefault(x => x.Key == f);
                    if (field is null) errors.Add($"FR-REQ-004: the condition of {t.From} {t.Action} reads the unknown field {f}.");
                    else if (field.Sensitivity == "RESTRICTED") errors.Add($"V-WFL-03: the condition of {t.From} {t.Action} reads the restricted field {f}.");
                }
        }
        // Every non-terminal stage has a way out (CANCEL aside), and every stage can be reached from the start.
        foreach (var s in g.Stages.Where(s => s.Kind != "TERMINAL"))
            if (!g.Transitions.Any(t => t.From == s.Key)) errors.Add($"V-WFL-01: the stage {s.Key} has no way out.");
        var start = g.Stages.FirstOrDefault(s => s.Kind == "DRAFT")?.Key;
        if (start is not null)
        {
            var reach = new HashSet<string>(StringComparer.Ordinal) { start };
            var queue = new Queue<string>([start]);
            while (queue.Count > 0)
            {
                var k = queue.Dequeue();
                foreach (var t in g.Transitions.Where(t => t.From == k))
                    foreach (var n in new[] { t.To, t.Resume }.OfType<string>())
                        if (reach.Add(n)) queue.Enqueue(n);
            }
            // A terminal stage may be reached by the engine alone (CANCEL from every stage), the completed one never.
            foreach (var s in g.Stages)
                if (!reach.Contains(s.Key) && (s.Kind != "TERMINAL" || s.Outcome == "COMPLETED")) errors.Add($"V-WFL-01: the stage {s.Key} cannot be reached.");
        }
        if (g.NumberOnStageKey is { } ns && !stages.ContainsKey(ns)) errors.Add($"BR-WFL-013: the numbering stage {ns} is not a stage.");

        var fieldKeys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var f in g.Fields)
        {
            if (!fieldKeys.Add(f.Key)) errors.Add($"FR-REQ-002: the field {f.Key} appears twice.");
            if (f.Sensitivity == "RESTRICTED" && f.IndexRole != "NONE") errors.Add($"BR-REQ-003: the restricted field {f.Key} is not indexed.");
            foreach (var k in (f.VisibleStages ?? []).Concat(f.EditableStages ?? []))
                if (!stages.ContainsKey(k)) errors.Add($"FR-REQ-002: the field {f.Key} names the unknown stage {k}.");
        }
        foreach (var r in g.Fields.Where(f => f.IndexRole != "NONE").GroupBy(f => f.IndexRole).Where(x => x.Count() > 1))
            errors.Add($"FR-REQ-009: two fields have the index role {r.Key}.");
        foreach (var a in g.Attachments)
            if (a.RequiredBeforeStage is { } k && !stages.ContainsKey(k)) errors.Add($"BR-WFL-014: the attachment {a.Slot} names the unknown stage {k}.");
            else if (a.Min > 0 && a.RequiredBeforeStage is null) errors.Add($"BR-WFL-014: the attachment {a.Slot} is required but names no stage.");
        return errors;
    }

    /// <summary>The field keys a condition reads (FR-REQ-004: field/op/value leaves under all, any and not).</summary>
    public static IEnumerable<string> ConditionFields(JsonElement e)
    {
        if (e.ValueKind == JsonValueKind.Array)
            foreach (var x in e.EnumerateArray()) foreach (var f in ConditionFields(x)) yield return f;
        if (e.ValueKind != JsonValueKind.Object) yield break;
        if (e.TryGetProperty("field", out var field) && field.GetString() is { } name) yield return name;
        foreach (var k in new[] { "all", "any", "not" })
            if (e.TryGetProperty(k, out var sub)) foreach (var f in ConditionFields(sub)) yield return f;
    }
}

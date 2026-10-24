using System.Text.Json;
using BankFas.Core.Workflow;

namespace BankFas.Core.Tests.Workflow;

public sealed class ConditionTests
{
    private static JsonElement J(string json) => JsonDocument.Parse(json).RootElement.Clone();
    private const string OverFive = """{"field": "amount", "op": "gt", "value": 5000000, "currency": "SAR"}""";

    // FR-WFL-006 and BR-WFL-001: Amount > 5,000,000 SAR adds an approval for 6,000,000 and not for 4,000,000; in USD it is not comparable.
    [Theory]
    [InlineData("""{"amount": {"value": 6000000, "currency": "SAR"}}""", Truth.True)]
    [InlineData("""{"amount": {"value": 4000000, "currency": "SAR"}}""", Truth.False)]
    [InlineData("""{"amount": {"value": 1000000, "currency": "USD"}}""", Truth.NotComparable)]
    [InlineData("""{}""", Truth.False)]
    public void The_amount_condition_of_FR_WFL_006(string form, Truth expected) => Assert.Equal(expected, ConditionEvaluator.Evaluate(J(OverFive), J(form)));

    [Fact]
    public void The_chooser_takes_the_first_holding_path_and_the_stricter_one_when_not_comparable()
    {
        TransitionCandidate[] paths = [new(1, 1, "EXTRA_APPROVAL", OverFive), new(2, 2, "TREASURY_QUEUE", null)];
        Assert.Equal(("EXTRA_APPROVAL", false), Pick(paths, """{"amount": {"value": 6000000, "currency": "SAR"}}"""));
        Assert.Equal(("TREASURY_QUEUE", false), Pick(paths, """{"amount": {"value": 4000000, "currency": "SAR"}}"""));
        Assert.Equal(("EXTRA_APPROVAL", true), Pick(paths, """{"amount": {"value": 1000000, "currency": "USD"}}"""));
        Assert.Null(TransitionChooser.Choose([new(1, 1, "X", OverFive)], J("{}")).Chosen);
    }

    private static (string?, bool) Pick(TransitionCandidate[] paths, string form)
    {
        var (t, nc) = TransitionChooser.Choose(paths, J(form));
        return (t?.ToStageKey, nc);
    }

    [Fact]
    public void All_any_not_in_and_empty()
    {
        var form = J("""{"kind": "CANCEL", "amountDelta": 0, "tags": [], "note": ""}""");
        Assert.Equal(Truth.True, ConditionEvaluator.Evaluate(J("""{"any": [{"field": "amountDelta", "op": "gt", "value": 0}, {"field": "kind", "op": "eq", "value": "CANCEL"}]}"""), form));
        Assert.Equal(Truth.False, ConditionEvaluator.Evaluate(J("""{"all": [{"field": "amountDelta", "op": "gt", "value": 0}, {"field": "kind", "op": "eq", "value": "CANCEL"}]}"""), form));
        Assert.Equal(Truth.True, ConditionEvaluator.Evaluate(J("""{"not": {"field": "kind", "op": "in", "value": ["AMEND", "EXTEND"]}}"""), form));
        Assert.Equal(Truth.True, ConditionEvaluator.Evaluate(J("""{"field": "note", "op": "empty"}"""), form));
        Assert.Equal(Truth.True, ConditionEvaluator.Evaluate(J("""{"field": "missing", "op": "empty"}"""), form));
        Assert.Equal(Truth.False, ConditionEvaluator.Evaluate(J("""{"field": "kind", "op": "empty"}"""), form));
        Assert.Equal(Truth.NotComparable, ConditionEvaluator.Evaluate(J($$"""{"all": [{{OverFive}}, {"field": "kind", "op": "eq", "value": "CANCEL"}]}"""),
            J("""{"kind": "CANCEL", "amount": {"value": 1, "currency": "USD"}}""")));
    }

    [Fact]
    public void The_snapshot_hash_ignores_key_order_and_sees_every_value()
    {
        var a = Snapshot.Hash("TM_APPROVAL", 1, """{"b": 1, "a": {"y": 2, "x": [1, 2]}}""", 3_000_000m, "SAR");
        var b = Snapshot.Hash("TM_APPROVAL", 1, """{"a": {"x": [1, 2], "y": 2}, "b": 1}""", 3_000_000m, "SAR");
        Assert.Equal(a, b);
        Assert.NotEqual(a, Snapshot.Hash("TM_APPROVAL", 2, """{"b": 1, "a": {"y": 2, "x": [1, 2]}}""", 3_000_000m, "SAR"));
        Assert.NotEqual(a, Snapshot.Hash("TM_APPROVAL", 1, """{"b": 1, "a": {"y": 2, "x": [2, 1]}}""", 3_000_000m, "SAR"));
        Assert.Equal(32, a.Length);
    }

    [Fact]
    public void The_seeded_templates_pass_the_publication_checks()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "db", "seed", "packs", "WFL.BASE", "v2", "templates");
        var phases = new HashSet<string> { "DRAFT", "IN_APPROVAL", "RETURNED", "AWAITING_REQUESTER", "IN_PROGRESS", "COMPLETED", "REJECTED", "CANCELLED" };
        var files = Directory.GetFiles(dir, "*.json");
        Assert.Equal(9, files.Length);
        foreach (var f in files) Assert.Empty(TemplateValidator.Validate(TemplateGraph.Parse(File.ReadAllText(f)), HookKeys.All, phases));
        // A broken graph: an unregistered hook, a stage without a way out, a condition on an unknown field.
        var bad = TemplateGraph.Parse(File.ReadAllText(Path.Combine(dir, "GENERIC_SIMPLE.json"))) with
        {
            Transitions = [new TransitionDef { From = "DRAFT", Action = "SUBMIT", To = "TREASURY_QUEUE", Condition = J("""{"field": "nope", "op": "eq", "value": 1}""") }],
        };
        var errors = TemplateValidator.Validate(bad, HookKeys.All, phases);
        Assert.Contains(errors, e => e.Contains("unknown field nope", StringComparison.Ordinal));
        Assert.Contains(errors, e => e.Contains("has no way out", StringComparison.Ordinal));
    }
}

using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace BankFas.Core.Workflow;

/// <summary>The value of a condition: an amount condition on another currency is not comparable (BR-WFL-001).</summary>
public enum Truth { False, True, NotComparable }

/// <summary>
/// The restricted condition language of a template (FR-REQ-004, BR-WFL-001): leaves {field, op, value[, currency]}
/// with eq, ne, in, gt, gte, lt, lte and empty, combined by all, any and not; no code. A field is read from the
/// request's form data by its key; an AMOUNT field holds {value, currency}, and a leaf on it that names a currency
/// other than the request's is NOT_COMPARABLE. all is false if a part is false, any is true if a part is true, and a
/// not-comparable part otherwise makes the whole not comparable.
/// </summary>
public static class ConditionEvaluator
{
    public static Truth Evaluate(JsonElement condition, JsonElement form)
    {
        if (condition.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null) return Truth.True;
        if (condition.ValueKind != JsonValueKind.Object) throw new InvalidDataException("A condition is an object.");
        if (condition.TryGetProperty("all", out var all)) return All(all.EnumerateArray().Select(x => Evaluate(x, form)));
        if (condition.TryGetProperty("any", out var any)) return Any(any.EnumerateArray().Select(x => Evaluate(x, form)));
        if (condition.TryGetProperty("not", out var not)) return Evaluate(not, form) switch { Truth.True => Truth.False, Truth.False => Truth.True, _ => Truth.NotComparable };
        return Leaf(condition, form);
    }

    private static Truth All(IEnumerable<Truth> parts)
    {
        var nc = false;
        foreach (var p in parts) { if (p == Truth.False) return Truth.False; nc |= p == Truth.NotComparable; }
        return nc ? Truth.NotComparable : Truth.True;
    }

    private static Truth Any(IEnumerable<Truth> parts)
    {
        var nc = false;
        foreach (var p in parts) { if (p == Truth.True) return Truth.True; nc |= p == Truth.NotComparable; }
        return nc ? Truth.NotComparable : Truth.False;
    }

    private static Truth Leaf(JsonElement leaf, JsonElement form)
    {
        var field = leaf.GetProperty("field").GetString() ?? throw new InvalidDataException("A condition names its field.");
        var op = leaf.GetProperty("op").GetString();
        var hasValue = form.ValueKind == JsonValueKind.Object && form.TryGetProperty(field, out var v) && v.ValueKind != JsonValueKind.Null;
        var actual = hasValue ? form.GetProperty(field) : default;
        // An amount: {value, currency}; the leaf's currency, when given, must be the amount's.
        if (hasValue && actual.ValueKind == JsonValueKind.Object && actual.TryGetProperty("value", out var amount))
        {
            if (leaf.TryGetProperty("currency", out var cur) && actual.TryGetProperty("currency", out var ac)
                && !string.Equals(cur.GetString(), ac.GetString(), StringComparison.Ordinal))
                return Truth.NotComparable;
            actual = amount;
        }
        if (op == "empty")
        {
            var isEmpty = !hasValue || (actual.ValueKind == JsonValueKind.String && actual.GetString()!.Length == 0)
                          || (actual.ValueKind == JsonValueKind.Array && actual.GetArrayLength() == 0);
            var want = !leaf.TryGetProperty("value", out var w) || w.ValueKind != JsonValueKind.False;
            return isEmpty == want ? Truth.True : Truth.False;
        }
        if (!hasValue) return op == "ne" ? Truth.True : Truth.False;
        var expected = leaf.GetProperty("value");
        return op switch
        {
            "eq" => Same(actual, expected) ? Truth.True : Truth.False,
            "ne" => Same(actual, expected) ? Truth.False : Truth.True,
            "in" => expected.EnumerateArray().Any(e => Same(actual, e)) ? Truth.True : Truth.False,
            "gt" or "gte" or "lt" or "lte" => Number(actual) is { } a && Number(expected) is { } b
                ? (op switch { "gt" => a > b, "gte" => a >= b, "lt" => a < b, _ => a <= b }) ? Truth.True : Truth.False
                : Truth.False,
            _ => throw new InvalidDataException($"Unknown condition operator {op}."),
        };
    }

    private static decimal? Number(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Number => e.GetDecimal(),
        JsonValueKind.String when decimal.TryParse(e.GetString(), NumberStyles.Number, CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };

    private static bool Same(JsonElement a, JsonElement b) =>
        Number(a) is { } x && Number(b) is { } y ? x == y
        : a.ValueKind is JsonValueKind.True or JsonValueKind.False || b.ValueKind is JsonValueKind.True or JsonValueKind.False ? a.ValueKind == b.ValueKind
        : string.Equals(a.ToString(), b.ToString(), StringComparison.Ordinal);
}

/// <summary>A candidate transition of a stage and action, in priority order.</summary>
public sealed record TransitionCandidate(int TransitionId, int Priority, string ToStageKey, string? Condition);

/// <summary>
/// BR-WFL-001: the transitions of (stage, action) are tried in ascending priority and the first whose condition holds is
/// taken; an empty condition always holds. A not-comparable amount condition takes that path (it is the stricter one,
/// the one that adds an approval) and is reported so the engine records NOT_COMPARABLE. None: the action is not allowed.
/// </summary>
public static class TransitionChooser
{
    public static (TransitionCandidate? Chosen, bool NotComparable) Choose(IEnumerable<TransitionCandidate> candidates, JsonElement form)
    {
        foreach (var t in candidates.OrderBy(c => c.Priority))
        {
            if (t.Condition is null) return (t, false);
            using var doc = JsonDocument.Parse(t.Condition);
            switch (ConditionEvaluator.Evaluate(doc.RootElement, form))
            {
                case Truth.True: return (t, false);
                case Truth.NotComparable: return (t, true);
            }
        }
        return (null, false);
    }
}

/// <summary>
/// The fingerprint of what an approver saw (BR-WFL-003): SHA-256 of the canonical JSON of the request's form data,
/// amount, currency and the stage and cycle; keys sorted at every level, no spaces, numbers as written.
/// </summary>
public static class Snapshot
{
    public static byte[] Hash(string stageKey, int cycleNo, string? formJson, decimal? amount, string? currency)
    {
        using var doc = JsonDocument.Parse(string.IsNullOrEmpty(formJson) ? "{}" : formJson);
        var b = new StringBuilder();
        b.Append("{\"amount\":").Append(amount?.ToString(CultureInfo.InvariantCulture) ?? "null")
         .Append(",\"currency\":").Append(currency is null ? "null" : JsonSerializer.Serialize(currency))
         .Append(",\"cycle\":").Append(cycleNo.ToString(CultureInfo.InvariantCulture))
         .Append(",\"form\":");
        Canonical(doc.RootElement, b);
        b.Append(",\"stage\":").Append(JsonSerializer.Serialize(stageKey)).Append('}');
        return SHA256.HashData(Encoding.UTF8.GetBytes(b.ToString()));
    }

    public static void Canonical(JsonElement e, StringBuilder b)
    {
        ArgumentNullException.ThrowIfNull(b);
        switch (e.ValueKind)
        {
            case JsonValueKind.Object:
                b.Append('{');
                var first = true;
                foreach (var p in e.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                {
                    if (!first) b.Append(',');
                    first = false;
                    b.Append(JsonSerializer.Serialize(p.Name)).Append(':');
                    Canonical(p.Value, b);
                }
                b.Append('}');
                break;
            case JsonValueKind.Array:
                b.Append('[');
                var i = 0;
                foreach (var x in e.EnumerateArray()) { if (i++ > 0) b.Append(','); Canonical(x, b); }
                b.Append(']');
                break;
            default:
                b.Append(e.GetRawText());
                break;
        }
    }
}

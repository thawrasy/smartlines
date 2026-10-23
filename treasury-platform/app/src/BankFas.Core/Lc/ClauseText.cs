using System.Globalization;
using System.Text;
using System.Text.Json;

namespace BankFas.Core.Lc;

/// <summary>
/// The text of a document clause (BR-LCT-012, FR-LCT-017): the library's template with its placeholders filled. The
/// placeholders are {originals}, {copies} and the keys of the clause's parameters; a number reads in words beside its
/// digits for the counts ("3 (three)"), and a placeholder with no value is left visible as [key] so a missing parameter
/// is seen on the printed page rather than silently dropped.
/// </summary>
public static class ClauseText
{
    private static readonly string[] En = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
    private static readonly string[] Ar = ["صفر", "واحد", "اثنان", "ثلاثة", "أربعة", "خمسة", "ستة", "سبعة", "ثمانية", "تسعة", "عشرة"];

    private static string Count(int n, bool arabic) =>
        n is >= 0 and <= 10 ? $"{n.ToString(CultureInfo.InvariantCulture)} ({(arabic ? Ar[n] : En[n])})" : n.ToString(CultureInfo.InvariantCulture);

    public static string Render(string template, string? paramsJson, int? originals, int? copies, bool arabic)
    {
        ArgumentNullException.ThrowIfNull(template);
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        if (originals is { } o) values["originals"] = Count(o, arabic);
        if (copies is { } c) values["copies"] = Count(c, arabic);
        if (!string.IsNullOrWhiteSpace(paramsJson))
        {
            using var doc = JsonDocument.Parse(paramsJson);
            if (doc.RootElement.ValueKind == JsonValueKind.Object)
                foreach (var p in doc.RootElement.EnumerateObject())
                    values[p.Name] = p.Value.ValueKind switch
                    {
                        JsonValueKind.String => p.Value.GetString() ?? "",
                        JsonValueKind.Number => p.Value.GetRawText(),
                        JsonValueKind.True => arabic ? "نعم" : "yes",
                        JsonValueKind.False => arabic ? "لا" : "no",
                        _ => p.Value.GetRawText(),
                    };
        }
        var b = new StringBuilder(template.Length + 32);
        for (var i = 0; i < template.Length; i++)
        {
            if (template[i] == '{' && template.IndexOf('}', i + 1) is var end and > 0 && end - i <= 41)
            {
                var key = template[(i + 1)..end];
                if (key.Length > 0 && key.All(ch => char.IsAsciiLetterOrDigit(ch) || ch == '_'))
                {
                    b.Append(values.TryGetValue(key, out var v) ? v : $"[{key}]");
                    i = end;
                    continue;
                }
            }
            b.Append(template[i]);
        }
        return b.ToString();
    }

    /// <summary>A UCP 600 reference as printed: "UCP 600 art. 14(b)" or "UCP 600 م 14(ب)".</summary>
    public static string Reference(string articleNo, string? paragraph, bool arabic) =>
        (arabic ? "UCP 600 م " : "UCP 600 art. ") + articleNo + (string.IsNullOrEmpty(paragraph) ? "" : $"({paragraph})");
}

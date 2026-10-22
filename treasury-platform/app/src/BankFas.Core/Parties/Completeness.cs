using System.Text.Json;

namespace BankFas.Core.Parties;

/// <summary>An item of a KYC completeness profile (pty.KycProfileItem).</summary>
public sealed record KycItem(string Kind, string RefCode, string? ConditionJson, bool IsMandatory, int? MinValidityDays, int? MaxAgeDays, bool RequiresImage, int SortOrder);

/// <summary>An identity document of the person as completeness sees it: no number, only its kind, dates and how many images it has.</summary>
public sealed record KycIdentity(string DocKind, bool IsPrimary, DateTime? ExpiryDate, int ImageCount);

/// <summary>What is known of a person for a completeness check (FR-PTY-024).</summary>
public sealed record KycFacts(
    string PartyKind, bool IsGccNational, string? ResidencyStatus, IReadOnlySet<string> Fields, IReadOnlyList<KycIdentity> Identities,
    IReadOnlySet<string> AddressTypes, IReadOnlySet<string> ContactKinds, IReadOnlySet<string> CustomFields, IReadOnlyDictionary<string, DateTime> Documents);

/// <summary>The state of one item: COMPLETE, MISSING, EXPIRED, EXPIRING_SOON or NOT_APPLICABLE, and why.</summary>
public sealed record KycItemResult(KycItem Item, string Status, string? Reason, DateTime? ExpiryDate);

/// <summary>The result of a check: every item, the percentage of the mandatory items that apply, and whether the file can be submitted.</summary>
public sealed record KycResult(IReadOnlyList<KycItemResult> Items, int Applicable, int Done, decimal Pct, bool Ready, DateTime? NearestExpiry);

/// <summary>
/// FR-PTY-024: a person against a profile. An item that does not apply (its condition) is NOT_APPLICABLE; an identity
/// document past its date is EXPIRED, one that expires within MinValidityDays is EXPIRING_SOON (it counts as done and
/// warns), one without the images it needs is MISSING. The percentage counts the mandatory items that apply; the file
/// is ready when none of them is MISSING or EXPIRED (AC-PTY-3: 9 complete, 1 expiring soon and 2 missing of 12 give
/// 83.3%, not ready).
/// </summary>
public static class Completeness
{
    public static KycResult Evaluate(IEnumerable<KycItem> items, KycFacts facts, DateTime today)
    {
        var results = items.OrderBy(i => i.SortOrder).Select(i => One(i, facts, today.Date)).ToList();
        var counted = results.Where(r => r.Item.IsMandatory && r.Status != "NOT_APPLICABLE").ToList();
        var done = counted.Count(r => r.Status is "COMPLETE" or "EXPIRING_SOON");
        var pct = counted.Count == 0 ? 100m : Math.Round(done * 100m / counted.Count, 1, MidpointRounding.AwayFromZero);
        var nearest = results.Where(r => r.ExpiryDate is not null && r.Status != "NOT_APPLICABLE").Select(r => r.ExpiryDate).Min();
        return new KycResult(results, counted.Count, done, pct, done == counted.Count, nearest);
    }

    private static KycItemResult One(KycItem i, KycFacts f, DateTime today)
    {
        if (!Applies(i.ConditionJson, f)) return new(i, "NOT_APPLICABLE", null, null);
        switch (i.Kind)
        {
            case "IDENTITY_DOC":
                var doc = i.RefCode == "PRIMARY" ? f.Identities.FirstOrDefault(d => d.IsPrimary) : f.Identities.FirstOrDefault(d => d.DocKind == i.RefCode);
                if (doc is null) return new(i, "MISSING", "NO_DOCUMENT", null);
                if (doc.ExpiryDate is { } e && e.Date < today) return new(i, "EXPIRED", "EXPIRED", e);
                if (i.RequiresImage && doc.ImageCount == 0) return new(i, "MISSING", "NO_IMAGE", doc.ExpiryDate);
                if (doc.ExpiryDate is { } soon && i.MinValidityDays is { } min && soon.Date < today.AddDays(min)) return new(i, "EXPIRING_SOON", "VALIDITY_BELOW_MINIMUM", soon);
                return new(i, "COMPLETE", null, doc.ExpiryDate);
            case "DOCUMENT_TYPE":
                if (!f.Documents.TryGetValue(i.RefCode, out var dated)) return new(i, "MISSING", "NO_DOCUMENT", null);
                if (i.MaxAgeDays is { } age && dated.Date < today.AddDays(-age)) return new(i, "EXPIRED", "TOO_OLD", null);
                return new(i, "COMPLETE", null, null);
            case "PARTY_FIELD": return Present(i, f.Fields.Contains(i.RefCode));
            case "ADDRESS_TYPE": return Present(i, f.AddressTypes.Contains(i.RefCode));
            case "CONTACT_KIND": return Present(i, f.ContactKinds.Contains(i.RefCode));
            case "CUSTOM_FIELD": return Present(i, f.CustomFields.Contains(i.RefCode));
            default: return new(i, "MISSING", "NOT_EVALUATED", null);  // COMPANY_FIELD and RELATED_PARTY_SET are for company forms (S2 has none)
        }
    }

    private static KycItemResult Present(KycItem i, bool present) => new(i, present ? "COMPLETE" : "MISSING", present ? null : "NO_VALUE", null);

    /// <summary>The conditions of an item: {"kind": "INDIVIDUAL"}, {"nationality": "GCC" | "NON_GCC"}, {"residency": ["RESIDENT", ...]}; all must hold.</summary>
    public static bool Applies(string? conditionJson, KycFacts f)
    {
        if (string.IsNullOrWhiteSpace(conditionJson)) return true;
        using var doc = JsonDocument.Parse(conditionJson);
        foreach (var c in doc.RootElement.EnumerateObject())
        {
            var ok = c.Name switch
            {
                "kind" => c.Value.GetString() == f.PartyKind,
                "nationality" => c.Value.GetString() switch { "GCC" => f.IsGccNational, "NON_GCC" => !f.IsGccNational, _ => false },
                "residency" => c.Value.ValueKind == JsonValueKind.Array && c.Value.EnumerateArray().Any(v => v.GetString() == f.ResidencyStatus),
                _ => false,
            };
            if (!ok) return false;
        }
        return true;
    }
}

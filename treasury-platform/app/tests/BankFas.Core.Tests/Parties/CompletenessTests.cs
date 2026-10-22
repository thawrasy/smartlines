using BankFas.Core.Parties;

namespace BankFas.Core.Tests.Parties;

public sealed class CompletenessTests
{
    // The baseline profile of BR-PTY-013 for an individual guarantor: 13 items, the passport for a GCC national only.
    private static readonly KycItem[] Baseline =
    [
        new("PARTY_FIELD", "NAME_AR", null, true, null, null, false, 1), new("PARTY_FIELD", "NAME_EN", null, true, null, null, false, 2),
        new("PARTY_FIELD", "NATIONALITY", null, true, null, null, false, 3), new("PARTY_FIELD", "BIRTH_DATE", null, true, null, null, false, 4),
        new("PARTY_FIELD", "BIRTH_PLACE", null, true, null, null, false, 5), new("PARTY_FIELD", "MARITAL_STATUS", null, true, null, null, false, 6),
        new("IDENTITY_DOC", "PRIMARY", null, true, 90, null, true, 7), new("IDENTITY_DOC", "PASSPORT", """{"nationality":"GCC"}""", true, null, null, false, 8),
        new("ADDRESS_TYPE", "NATIONAL", null, true, null, null, false, 9), new("CONTACT_KIND", "MOBILE", null, true, null, null, false, 10),
        new("CONTACT_KIND", "EMAIL", null, true, null, null, false, 11), new("CUSTOM_FIELD", "EMPLOYER", null, true, null, null, false, 12),
        new("CUSTOM_FIELD", "OCCUPATION", null, true, null, null, false, 13),
    ];

    private static KycFacts Resident(string[] custom) => new("INDIVIDUAL", false, "RESIDENT",
        new HashSet<string> { "NAME_AR", "NAME_EN", "NATIONALITY", "BIRTH_DATE", "BIRTH_PLACE", "MARITAL_STATUS" },
        [new("RESIDENCE", true, new DateTime(2026, 11, 5), 2)], new HashSet<string> { "NATIONAL" }, new HashSet<string> { "MOBILE", "EMAIL" },
        custom.ToHashSet(), new Dictionary<string, DateTime>());

    [Fact]
    public void AC_PTY_3_nine_complete_one_expiring_and_two_missing_of_twelve()
    {
        var r = Completeness.Evaluate(Baseline, Resident([]), new DateTime(2026, 10, 10));
        Assert.Equal((12, 10, 83.3m, false), (r.Applicable, r.Done, r.Pct, r.Ready));
        Assert.Equal("NOT_APPLICABLE", r.Items.Single(i => i.Item.RefCode == "PASSPORT").Status);
        Assert.Equal(("EXPIRING_SOON", (DateTime?)new DateTime(2026, 11, 5)), r.Items.Single(i => i.Item.RefCode == "PRIMARY") is var p ? (p.Status, p.ExpiryDate) : default);
        Assert.Equal(2, r.Items.Count(i => i.Status == "MISSING"));
        var done = Completeness.Evaluate(Baseline, Resident(["EMPLOYER", "OCCUPATION"]), new DateTime(2026, 10, 10));
        Assert.Equal((100m, true, (DateTime?)new DateTime(2026, 11, 5)), (done.Pct, done.Ready, done.NearestExpiry));
    }

    [Fact]
    public void An_expired_document_or_one_without_its_images_is_not_done()
    {
        var expired = Resident(["EMPLOYER", "OCCUPATION"]) with { Identities = [new("RESIDENCE", true, new DateTime(2026, 10, 1), 2)] };
        Assert.Equal("EXPIRED", Completeness.Evaluate(Baseline, expired, new DateTime(2026, 10, 10)).Items.Single(i => i.Item.RefCode == "PRIMARY").Status);
        var noImage = Resident(["EMPLOYER", "OCCUPATION"]) with { Identities = [new("RESIDENCE", true, new DateTime(2028, 1, 1), 0)] };
        var r = Completeness.Evaluate(Baseline, noImage, new DateTime(2026, 10, 10));
        Assert.Equal(("MISSING", "NO_IMAGE", false), r.Items.Single(i => i.Item.RefCode == "PRIMARY") is var p ? (p.Status, p.Reason, r.Ready) : default);
        var gcc = Resident(["EMPLOYER", "OCCUPATION"]) with { IsGccNational = true, ResidencyStatus = "CITIZEN", Identities = [new("NATIONAL_ID", true, new DateTime(2030, 1, 1), 2)] };
        Assert.Equal((13, 12), Completeness.Evaluate(Baseline, gcc, new DateTime(2026, 10, 10)) is var g ? (g.Applicable, g.Done) : default);
    }
}

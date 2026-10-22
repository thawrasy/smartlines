using BankFas.Core.Facilities;

namespace BankFas.Core.Tests.Facilities;

public sealed class LimitTreeTests
{
    private static LimitNode Abs(long root, long? parent, string code, decimal amount, string mode = "SHARED_CAP", string kind = "SUB") =>
        new(root, parent, code, kind, mode, "ABSOLUTE", amount, null);

    private static LimitNode Pct(long root, long? parent, string code, decimal pct, string mode = "SHARED_CAP") =>
        new(root, parent, code, "SUB", mode, "PCT_OF_PARENT", null, pct);

    private static string? Kind(LimitTree t, long root) => t.Nodes.Single(n => n.Root == root).Kind;

    [Fact]
    public void AC_FAC_1_shared_caps_partitions_and_a_limit_outside_the_total()
    {
        // L0 45M; L1 and L2 at 95% (shared cap); L3 an FX limit of 1.5M outside the total; 15 lines of 40M under L1.
        var nodes = new[] { Abs(1, null, "L0", 45_000_000, kind: "MAIN"), Pct(2, 1, "L1", 95), Pct(3, 1, "L2", 95), Abs(4, 1, "L3", 1_500_000, "OUTSIDE_TOTAL") };
        var lines = Enumerable.Range(1, 15).Select(i => new ProductLine(100 + i, 2, 7, $"P{i}", "ABSOLUTE", 40_000_000, null)).ToList();
        var t = new LimitTree(45_000_000, nodes, lines);
        Assert.Equal(42_750_000m, t.Cap(2));
        Assert.Equal(42_750_000m, t.Cap(3));
        Assert.Equal((45_000_000m, 1_500_000m), t.Totals());
        Assert.DoesNotContain(t.Check(r => Kind(t, r)), x => x.Severity == "E");

        // L2 at an absolute 46M is above its parent.
        var above = new LimitTree(45_000_000, [nodes[0], nodes[1], Abs(3, 1, "L2", 46_000_000), nodes[3]]);
        Assert.Contains(above.Check(r => Kind(above, r)), x => x.Code == "V-FAC-04" && x.Severity == "E");

        // Partitions of 30M and 10M leave 5M unallocated (a warning); 30M and 20M are above 45M (an error).
        var part = new LimitTree(45_000_000, [nodes[0], Abs(2, 1, "L1", 30_000_000, "PARTITION"), Abs(3, 1, "L2", 10_000_000, "PARTITION"), nodes[3]]);
        var findings = part.Check(r => Kind(part, r));
        Assert.DoesNotContain(findings, x => x.Severity == "E");
        Assert.Contains(findings, x => x.Code == "V-FAC-05" && x.Severity == "W" && x.Message.StartsWith("5,000,000.00", StringComparison.Ordinal));
        var over = new LimitTree(45_000_000, [nodes[0], Abs(2, 1, "L1", 30_000_000, "PARTITION"), Abs(3, 1, "L2", 20_000_000, "PARTITION"), nodes[3]]);
        Assert.Contains(over.Check(r => Kind(over, r)), x => x.Code == "V-FAC-05" && x.Severity == "E");
    }

    [Fact]
    public void The_tree_checks_depth_kinds_lines_and_company_rules()
    {
        var deep = Enumerable.Range(1, 7).Select(i => Abs(i, i == 1 ? null : i - 1, $"D{i}", 1_000_000, kind: i == 1 ? "MAIN" : "SUB")).ToList();
        var t = new LimitTree(1_000_000, deep);
        Assert.Contains(t.Check(r => Kind(t, r)), x => x.Code == "V-FAC-07" && x.Message.Contains("six", StringComparison.Ordinal));
        var noParent = new LimitTree(1_000_000, [Abs(1, null, "S", 1_000_000)]);
        Assert.Contains(noParent.Check(r => Kind(noParent, r)), x => x.Code == "V-FAC-07");

        var withProducts = new LimitNode(1, null, "LC", "MAIN", "SHARED_CAP", "ABSOLUTE", 10_000_000, null, new DateTime(2026, 12, 31), new HashSet<int> { 7 });
        var lines = new LimitTree(10_000_000, [withProducts],
            [new ProductLine(10, 1, 8, null, null, null, null), new ProductLine(11, 1, 7, null, "ABSOLUTE", 11_000_000, null, new DateTime(2027, 1, 1))]);
        var codes = lines.Check(r => Kind(lines, r)).Where(x => x.Code == "V-FAC-08" && x.Severity == "E").ToList();
        Assert.Equal(3, codes.Count);

        var rules = new LimitTree(10_000_000, [Abs(1, null, "P", 10_000_000, kind: "MAIN"), Abs(2, 1, "C", 5_000_000)], null,
            [new CompanyRule(1, 100, "ALLOWED", null, null), new CompanyRule(2, 200, "ALLOWED", null, null), new CompanyRule(2, 100, "EXCLUDED", null, null),
             new CompanyRule(2, 100, "ALLOWED", null, null), new CompanyRule(1, 100, "ALLOCATION", 11_000_000, null)]);
        var found = rules.Check(r => Kind(rules, r)).Where(x => x.Code == "V-FAC-09").Select(x => x.Message).ToList();
        Assert.Equal(3, found.Count);
        Assert.False(rules.Eligible(2, 100));
        Assert.False(rules.Eligible(2, 300));
        Assert.True(rules.Eligible(1, 100));
    }

    [Fact]
    public void AC_FAC_2_availability_with_its_binding_node()
    {
        // A limit of 10M with 6M used: 4M; a reservation of 3M leaves 1M; the request's own reservation is left out.
        var one = new LimitTree(10_000_000, [Abs(1, null, "LC", 10_000_000, kind: "MAIN")]);
        List<Exposure> xs = [new(1, null, 1, 6_000_000, false)];
        Assert.Equal(4_000_000m, one.Available(1, null, 1, xs).Avail);
        xs.Add(new(1, null, 1, 3_000_000, true, 77));
        Assert.Equal(1_000_000m, one.Available(1, null, 1, xs).Avail);
        var own = one.Available(1, null, 1, xs, excludeRequest: 77);
        Assert.Equal((4_000_000m, 0m), (own.Avail, own.ReservedForOthers));

        // P=10M with shared caps C1=8M and C2=6M; C1 used 2M and C2 5M: Used(P)=7M, Avail(C1)=3M bound by P, Avail(C2)=1M bound by C2.
        var tree = new LimitTree(10_000_000, [Abs(1, null, "P", 10_000_000, kind: "MAIN"), Abs(2, 1, "C1", 8_000_000), Abs(3, 1, "C2", 6_000_000)]);
        List<Exposure> used = [new(2, null, 1, 2_000_000, false), new(3, null, 1, 5_000_000, false)];
        var c1 = tree.Available(2, null, 1, used);
        var c2 = tree.Available(3, null, 1, used);
        Assert.Equal((3_000_000m, "P"), (c1.Avail, c1.BindingNode));
        Assert.Equal((1_000_000m, "C2"), (c2.Avail, c2.BindingNode));

        // Outside the total: its own room only, and not in its parent's use.
        var fx = new LimitTree(10_000_000, [Abs(1, null, "P", 10_000_000, kind: "MAIN"), Abs(2, 1, "FX", 1_500_000, "OUTSIDE_TOTAL")]);
        List<Exposure> fxUse = [new(2, null, 1, 500_000, false), new(1, null, 1, 9_500_000, false)];
        Assert.Equal((1_000_000m, "FX"), (fx.Available(2, null, 1, fxUse).Avail, fx.Available(2, null, 1, fxUse).BindingNode));
        Assert.Equal(500_000m, fx.Available(1, null, 1, fxUse).Avail);

        // A line's own cap, and a company's allocation.
        var lined = new LimitTree(10_000_000, [Abs(1, null, "LC", 10_000_000, kind: "MAIN")], [new ProductLine(9, 1, 7, "SIGHT", "ABSOLUTE", 2_000_000, null)],
            [new CompanyRule(1, 2, "ALLOCATION", null, 30)]);
        List<Exposure> lu = [new(1, 9, 1, 1_500_000, false), new(1, null, 2, 2_500_000, false)];
        Assert.Equal((500_000m, "LC/SIGHT"), (lined.Available(1, 9, 1, lu).Avail, lined.Available(1, 9, 1, lu).BindingNode));
        Assert.Equal((500_000m, "LC:allocation"), (lined.Available(1, null, 2, lu).Avail, lined.Available(1, null, 2, lu).BindingNode));
    }
}

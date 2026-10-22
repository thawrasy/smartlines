namespace BankFas.Core.Facilities;

/// <summary>A limit of a facility, by its root (the identity it keeps across revisions, DQ-F13-4).</summary>
public sealed record LimitNode(long Root, long? ParentRoot, string Code, string Kind, string Mode, string Basis, decimal? Amount, decimal? Pct,
    DateTime? EndDate = null, IReadOnlySet<int>? AllowedProducts = null);

/// <summary>A product line under a limit; no cap means the limit's.</summary>
public sealed record ProductLine(long Root, long LimitRoot, int ProductId, string? BankProductCode, string? Basis, decimal? Amount, decimal? Pct, DateTime? DueDate = null);

/// <summary>A company rule on a limit (BR-FAC-012): ALLOWED, EXCLUDED or ALLOCATION (an amount or a percent of the limit's cap).</summary>
public sealed record CompanyRule(long LimitRoot, long CompanyId, string Kind, decimal? Amount, decimal? Pct);

/// <summary>An active utilisation or reservation, in the facility's currency.</summary>
public sealed record Exposure(long LimitRoot, long? LineRoot, long CompanyId, decimal Amount, bool IsReservation, long? RequestId = null);

public sealed record Finding(string Code, string Severity, string Message);

/// <summary>The answer of SVC-FAC-03 (BR-FAC-014): the cap, the used and reserved amounts, the available amount and the node that binds it.</summary>
public sealed record Availability(decimal Cap, decimal Used, decimal ReservedForOthers, decimal Avail, string BindingNode, string? Reason);

/// <summary>
/// The limit tree of one revision of a facility and the one availability formula of the platform (BR-FAC-009 to 014,
/// spec 12 section 5.1.1; FR-FAC-010, 011, 019, 025). Caps are computed root to leaf: an absolute amount, or a percent
/// of the parent's cap (the facility's total for a root), rounded half up to two decimals. SHARED_CAP and PARTITION
/// children count in their parent's use; OUTSIDE_TOTAL does not, and stands alone. Avail(n) = Own(n) for
/// OUTSIDE_TOTAL, else min(Own(n), Avail(parent)), the facility being the root of all; a line takes the smaller of its
/// own room and its limit's; an allocation of the company at the nearest node caps it again. The binding node is the
/// one whose room is the smallest on that path (the nearest on a tie).
/// </summary>
public sealed class LimitTree
{
    public const string FacilityNode = "FACILITY";

    private readonly decimal _total;
    private readonly Dictionary<long, LimitNode> _nodes;
    private readonly Dictionary<long, ProductLine> _lines;
    private readonly IReadOnlyList<CompanyRule> _rules;
    private readonly Dictionary<long, decimal> _cap = [];

    public LimitTree(decimal total, IEnumerable<LimitNode> nodes, IEnumerable<ProductLine>? lines = null, IEnumerable<CompanyRule>? rules = null)
    {
        _total = total;
        _nodes = nodes.ToDictionary(n => n.Root);
        _lines = (lines ?? []).ToDictionary(l => l.Root);
        _rules = [.. rules ?? []];
        foreach (var n in _nodes.Values) Cap(n.Root);
    }

    public IReadOnlyCollection<LimitNode> Nodes => _nodes.Values;
    public IReadOnlyCollection<ProductLine> Lines => _lines.Values;

    public static decimal Round(decimal x) => Math.Round(x, 2, MidpointRounding.AwayFromZero);

    /// <summary>Cap(n) (BR-FAC-009); a node in a cycle or under a missing parent counts its own amount, and the checks report it.</summary>
    public decimal Cap(long root) => Cap(root, 0);

    private decimal Cap(long root, int guard)
    {
        if (_cap.TryGetValue(root, out var known)) return known;
        var n = _nodes[root];
        decimal parent = n.ParentRoot is { } p && _nodes.ContainsKey(p) && guard < 64 ? Cap(p, guard + 1) : _total;
        var cap = n.Basis == "PCT_OF_PARENT" ? Round((n.Pct ?? 0) / 100m * parent) : n.Amount ?? 0;
        _cap[root] = cap;
        return cap;
    }

    public decimal ParentCap(LimitNode n) => n.ParentRoot is { } p && _nodes.ContainsKey(p) ? Cap(p) : _total;

    /// <summary>A line's own cap, or null when the line takes its limit's.</summary>
    public decimal? LineCap(ProductLine l) => l.Basis switch
    {
        "ABSOLUTE" => l.Amount,
        "PCT_OF_PARENT" => Round((l.Pct ?? 0) / 100m * Cap(l.LimitRoot)),
        _ => null,
    };

    private IEnumerable<LimitNode> Children(long? parent) => _nodes.Values.Where(n => n.ParentRoot == parent);

    /// <summary>The path from the node up to its root (the node first).</summary>
    public IReadOnlyList<LimitNode> PathUp(long root)
    {
        var path = new List<LimitNode>();
        var seen = new HashSet<long>();
        for (long? r = root; r is { } x && _nodes.TryGetValue(x, out var n) && seen.Add(x); r = n.ParentRoot) path.Add(n);
        return path;
    }

    public int Depth(long root) => PathUp(root).Count;

    /// <summary>The facility's total and, shown apart, the caps of the limits outside it (V-FAC-06).</summary>
    public (decimal Inside, decimal Outside) Totals() => (_total, _nodes.Values.Where(n => n.Mode == "OUTSIDE_TOTAL").Sum(n => Cap(n.Root)));

    // ---------- integrity (V-FAC-04 to 09) ----------

    public List<Finding> Check(Func<long, string?> limitTypeKind)
    {
        var f = new List<Finding>();
        foreach (var n in _nodes.Values.OrderBy(n => n.Code, StringComparer.Ordinal))
        {
            var path = PathUp(n.Root);
            if (path.Count > 0 && path[^1].ParentRoot is not null) f.Add(new("V-FAC-07", "E", $"The limit {n.Code} is in a cycle or under a limit that is not in this revision."));
            if (path.Count > 6) f.Add(new("V-FAC-07", "E", $"The limit {n.Code} is deeper than six levels."));
            var kind = limitTypeKind(n.Root);
            if (kind == "MAIN" && n.ParentRoot is not null) f.Add(new("V-FAC-07", "E", $"The limit {n.Code} is a main limit and has no parent."));
            if (kind == "SUB" && n.ParentRoot is null) f.Add(new("V-FAC-07", "E", $"The limit {n.Code} is a sub-limit and has a parent."));
            if (n.Mode == "SHARED_CAP" && Cap(n.Root) > ParentCap(n))
                f.Add(new("V-FAC-04", "E", $"The limit {n.Code} ({Cap(n.Root):N2}) is above its parent ({ParentCap(n):N2})."));
            if (n.Mode == "OUTSIDE_TOTAL" && Cap(n.Root) <= 0) f.Add(new("V-FAC-06", "W", $"The limit {n.Code} outside the total has no amount."));
        }
        foreach (var group in _nodes.Values.GroupBy(n => n.ParentRoot))
        {
            var parentCap = group.Key is { } p && _nodes.ContainsKey(p) ? Cap(p) : _total;
            var parentCode = group.Key is { } q && _nodes.TryGetValue(q, out var pn) ? pn.Code : FacilityNode;
            var parts = group.Where(n => n.Mode == "PARTITION").ToList();
            if (parts.Count == 0) continue;
            var sum = parts.Sum(n => Cap(n.Root));
            if (sum > parentCap) f.Add(new("V-FAC-05", "E", $"The partitions under {parentCode} total {sum:N2}, above its {parentCap:N2}."));
            else if (sum < parentCap) f.Add(new("V-FAC-05", "W", $"{parentCap - sum:N2} under {parentCode} is not allocated to a partition."));
            if (group.Any(n => n.Mode == "SHARED_CAP")) f.Add(new("V-FAC-05", "W", $"Partitions and shared caps are mixed under {parentCode}: a shared cap does not protect a partition's share."));
        }
        foreach (var l in _lines.Values)
        {
            if (!_nodes.TryGetValue(l.LimitRoot, out var n)) { f.Add(new("V-FAC-08", "E", "A product line is under a limit that is not in this revision.")); continue; }
            if (LineCap(l) is { } lc && lc > Cap(n.Root)) f.Add(new("V-FAC-08", "E", $"A line of {n.Code} ({lc:N2}) is above its limit ({Cap(n.Root):N2})."));
            if (n.AllowedProducts is { Count: > 0 } allowed && !allowed.Contains(l.ProductId)) f.Add(new("V-FAC-08", "E", $"A line of {n.Code} is for a product its limit type does not allow."));
            if (l.DueDate is { } due && n.EndDate is { } end && due > end) f.Add(new("V-FAC-08", "E", $"A line of {n.Code} is due after its limit ends."));
        }
        foreach (var n in _nodes.Values.Where(n => n.AllowedProducts is not { Count: > 0 } && _lines.Values.Any(l => l.LimitRoot == n.Root)))
            f.Add(new("V-FAC-08", "W", $"The limit type of {n.Code} lists no products: its lines may be for any product."));
        foreach (var byNode in _rules.GroupBy(r => r.LimitRoot))
        {
            if (!_nodes.TryGetValue(byNode.Key, out var n)) continue;
            foreach (var c in byNode.GroupBy(r => r.CompanyId).Where(g => g.Any(r => r.Kind == "ALLOWED") && g.Any(r => r.Kind == "EXCLUDED")))
                f.Add(new("V-FAC-09", "E", $"A company is both allowed and excluded on {n.Code}."));
            var allowed = byNode.Where(r => r.Kind == "ALLOWED").Select(r => r.CompanyId).ToHashSet();
            if (allowed.Count > 0 && NearestAllowed(n.ParentRoot) is { } up && !allowed.IsSubsetOf(up))
                f.Add(new("V-FAC-09", "E", $"The companies allowed on {n.Code} are not all allowed on its parent."));
            var alloc = byNode.Where(r => r.Kind == "ALLOCATION").Select(r => AllocationOf(r)).ToList();
            if (alloc.Any(a => a > Cap(n.Root))) f.Add(new("V-FAC-09", "E", $"An allocation on {n.Code} is above its cap."));
        }
        return f;
    }

    private HashSet<long>? NearestAllowed(long? from)
    {
        for (var r = from; r is { } x && _nodes.TryGetValue(x, out var n); r = n.ParentRoot)
        {
            var set = _rules.Where(q => q.LimitRoot == x && q.Kind == "ALLOWED").Select(q => q.CompanyId).ToHashSet();
            if (set.Count > 0) return set;
        }
        return null;
    }

    private decimal AllocationOf(CompanyRule r) => r.Amount ?? Round((r.Pct ?? 0) / 100m * Cap(r.LimitRoot));

    /// <summary>BR-FAC-012: excluded on the node or an ancestor; else, when the nearest node with ALLOWED rows has some, the company is among them.</summary>
    public bool Eligible(long limitRoot, long company)
    {
        var path = PathUp(limitRoot);
        if (path.Any(n => _rules.Any(r => r.LimitRoot == n.Root && r.CompanyId == company && r.Kind == "EXCLUDED"))) return false;
        return NearestAllowed(limitRoot) is not { } set || set.Contains(company);
    }

    // ---------- availability (BR-FAC-013, 014) ----------

    private decimal UsedOn(long root, IReadOnlyList<Exposure> xs, bool reservations, long? company = null)
    {
        var own = xs.Where(x => x.LimitRoot == root && x.IsReservation == reservations && (company is null || x.CompanyId == company)).Sum(x => x.Amount);
        return own + Children(root).Where(c => c.Mode != "OUTSIDE_TOTAL").Sum(c => UsedOn(c.Root, xs, reservations, company));
    }

    private decimal UsedOnFacility(IReadOnlyList<Exposure> xs, bool reservations) =>
        Children(null).Where(c => c.Mode != "OUTSIDE_TOTAL").Sum(c => UsedOn(c.Root, xs, reservations));

    /// <summary>
    /// The availability of a limit or a line for a company (null: any), with the request's own reservation left out.
    /// A company that is not eligible has none (COMPANY_EXCLUDED).
    /// </summary>
    public Availability Available(long limitRoot, long? lineRoot, long? company, IReadOnlyList<Exposure> exposures, long? excludeRequest = null)
    {
        var xs = excludeRequest is null ? exposures : [.. exposures.Where(x => !(x.IsReservation && x.RequestId == excludeRequest))];
        var node = _nodes[limitRoot];
        var candidates = new List<(string Node, decimal Room)>();
        decimal cap, used, reserved;
        if (lineRoot is { } lr && _lines.TryGetValue(lr, out var line) && LineCap(line) is { } lc)
        {
            var lu = xs.Where(x => x.LineRoot == lr && !x.IsReservation).Sum(x => x.Amount);
            var lres = xs.Where(x => x.LineRoot == lr && x.IsReservation).Sum(x => x.Amount);
            candidates.Add(($"{node.Code}/{line.BankProductCode ?? line.ProductId.ToString(System.Globalization.CultureInfo.InvariantCulture)}", lc - lu - lres));
            (cap, used, reserved) = (lc, lu, lres);
        }
        else (cap, used, reserved) = (Cap(limitRoot), UsedOn(limitRoot, xs, false), UsedOn(limitRoot, xs, true));
        var outside = false;
        foreach (var n in PathUp(limitRoot))
        {
            candidates.Add((n.Code, Cap(n.Root) - UsedOn(n.Root, xs, false) - UsedOn(n.Root, xs, true)));
            if (n.Mode == "OUTSIDE_TOTAL") { outside = true; break; }
        }
        if (!outside) candidates.Add((FacilityNode, _total - UsedOnFacility(xs, false) - UsedOnFacility(xs, true)));
        if (company is { } c)
        {
            foreach (var n in PathUp(limitRoot))
            {
                var rule = _rules.FirstOrDefault(r => r.LimitRoot == n.Root && r.CompanyId == c && r.Kind == "ALLOCATION");
                if (rule is null) continue;
                candidates.Add(($"{n.Code}:allocation", AllocationOf(rule) - UsedOn(n.Root, xs, false, c) - UsedOn(n.Root, xs, true, c)));
                break;
            }
            if (!Eligible(limitRoot, c)) return new Availability(cap, used, reserved, 0, node.Code, "COMPANY_EXCLUDED");
        }
        var bind = candidates[0];
        foreach (var x in candidates.Skip(1)) if (x.Room < bind.Room) bind = x;
        return new Availability(cap, used, reserved, bind.Room, bind.Node, null);
    }
}

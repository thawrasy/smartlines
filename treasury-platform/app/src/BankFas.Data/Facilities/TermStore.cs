using BankFas.Core.Collateral;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Facilities;

/// <summary>A comparable value the approval projects from a typed field (BR-CMP-004): its key, scope, value or state, dates and the row it comes from.</summary>
public sealed record ProjectedTerm(string Code, long? LimitId, long? LineId, int? ProductId, long? CompanyId, string State, decimal? Number, string? Text, bool? Flag, string? Enum,
    DateTime From, DateTime? To, string ProjectedFrom, long? SourceDocumentId = null, string? SourcePage = null, string Confidence = "ENTERED_NO_DOCUMENT");

/// <summary>
/// The projection of comparable terms (FR-CMP-003; DQ-F13-6, F13:374): on the approval of revision R, inside its
/// transaction and before the facility's approved number moves, every PROJECTED row still open is closed at R and the
/// values of the revision are written again with FromRevision R, each following the row of the same key it replaces.
/// The map from typed fields to keys is the code below (the bound keys of CMP.TERMS and the collateral, duration and
/// covenant keys derived from the revision); a value the agreement leaves blank is NOT_SPECIFIED_IN_AGREEMENT, never 0
/// (BR-CMP-002). PROJECTED rows are never edited by a user (V-CMP-01).
/// </summary>
public static class TermStore
{
    private static readonly HashSet<string> LcFees = ["ISSUANCE", "LC_AMENDMENT", "CONFIRMATION", "ACCEPTANCE"];

    private sealed class PricingRow
    {
        public long RootId { get; init; }
        public long? ScopeLimitId { get; init; }
        public long? ScopeLimitProductLineId { get; init; }
        public int? ScopeProductId { get; init; }
        public long? ScopeCompanyId { get; init; }
        public string RateState { get; init; } = "";
        public string? FeeType { get; init; }
        public string Method { get; init; } = "";
        public decimal? AddOnPct { get; init; }
        public string? BaseRate { get; init; }
        public decimal? MarginPct { get; init; }
        public decimal? BaseFloorPct { get; init; }
        public decimal? RatePct { get; init; }
        public decimal? PerMillionAmount { get; init; }
        public string? RateFixing { get; init; }
        public string? DayCount { get; init; }
        public string BankMayChange { get; init; } = "";
        public int? ObjectionDays { get; init; }
        public DateTime EffectiveFrom { get; init; }
        public DateTime? EffectiveTo { get; init; }
        public long? SourceDocumentId { get; init; }
        public string? SourcePage { get; init; }
        public string Confidence { get; init; } = "";
        public string ComponentKind { get; init; } = "";
    }

    /// <summary>The values revision rev (int.MaxValue: the open rows, the draft being approved) gives, with the header's dates.</summary>
    public static async Task<List<ProjectedTerm>> ComputeAsync(SqlConnection c, SqlTransaction? tx, long facility, int rev, DateTime from, DateTime expiry, decimal total,
        CancellationToken ct)
    {
        string V(string a) => rev == int.MaxValue ? $"{a}.ToRevision IS NULL" : $"{a}.FromRevision <= {rev} AND ({a}.ToRevision IS NULL OR {a}.ToRevision > {rev})";
        var p = new { f = facility };
        var terms = new List<ProjectedTerm>();
        void Add(ProjectedTerm t) => terms.Add(t);

        // Pricing (the bound keys of CMP.TERMS).
        var rules = await c.QueryAsync<PricingRow>(new CommandDefinition(
            $"""
            SELECT r.RootId, r.ScopeLimitId, r.ScopeLimitProductLineId, r.ScopeProductId, r.ScopeCompanyId, r.RateState, ft.Code AS FeeType, r.Method, r.AddOnPct, br.Code AS BaseRate,
                   r.MarginPct, r.BaseFloorPct, r.RatePct, r.PerMillionAmount, r.RateFixing, r.DayCount, r.BankMayChange, r.ObjectionDays, r.EffectiveFrom, r.EffectiveTo,
                   r.SourceDocumentId, r.SourcePage, r.Confidence, r.ComponentKind
              FROM prc.PricingRule AS r LEFT JOIN cat.FeeType AS ft ON ft.FeeTypeId = r.FeeTypeId LEFT JOIN cat.BaseRate AS br ON br.BaseRateId = r.BaseRateId
             WHERE r.FacilityId = @f AND {V("r")} AND r.ToRevision IS DISTINCT FROM r.FromRevision;
            """, p, tx, cancellationToken: ct)).ConfigureAwait(false);
        foreach (var r in rules)
        {
            ProjectedTerm T(string code, string state, decimal? n = null, string? text = null, bool? flag = null, string? en = null) =>
                new(code, r.ScopeLimitId, r.ScopeLimitProductLineId, r.ScopeProductId, r.ScopeCompanyId, state, n, text, flag, en, r.EffectiveFrom, r.EffectiveTo,
                    $"prc.PricingRule:{r.RootId}", r.SourceDocumentId, r.SourcePage, r.Confidence);
            var set = r.RateState == "SET";
            var state = set ? "SPECIFIED" : "NOT_SPECIFIED_IN_AGREEMENT";
            if (r.Method == "BASE_PLUS_MARGIN")
            {
                Add(T("PRC.MARGIN_PCT", state, set ? r.MarginPct : null));
                if (r.BaseRate is not null) Add(T("PRC.BASE_RATE_FAMILY", "SPECIFIED", text: r.BaseRate));
                if (r.RateFixing is not null) Add(T("PRC.FIXED_FOR_CONTRACT", "SPECIFIED", flag: r.RateFixing == "FIXED_FOR_CONTRACT"));
                Add(T("PRC.ZERO_FLOOR", "SPECIFIED", flag: r.BaseFloorPct == 0));
            }
            if (r.Method == "TARIFF_PLUS_ADDON" && r.FeeType is { } fee && LcFees.Contains(fee)) Add(T("PRC.LC_COMMISSION_ADDON_PCT", state, set ? r.AddOnPct : null));
            if (r.Method == "PER_MILLION") Add(T("PRC.TREASURY_FEE_PER_MILLION", state, set ? r.PerMillionAmount : null));
            if (r.FeeType == "ARRANGEMENT") Add(T("PRC.ARRANGEMENT_FEE_PCT", state, set ? r.RatePct : null));
            if (r.ComponentKind == "FINANCING_RETURN")
            {
                if (r.DayCount is not null) Add(T("PRC.DAY_COUNT", "SPECIFIED", en: r.DayCount));
                Add(T("PRC.BANK_MAY_CHANGE_UNILATERALLY", "SPECIFIED", flag: r.BankMayChange == "UNILATERAL"));
                if (r.ObjectionDays is not null) Add(T("PRC.OBJECTION_DAYS", "SPECIFIED", r.ObjectionDays));
            }
        }

        // Durations and line terms.
        // Whole months from the start to the day after the expiry (2026-01-01 to 2027-12-31 is 24).
        var end = expiry.AddDays(1);
        var months = (end.Year - from.Year) * 12 + end.Month - from.Month - (end.Day < from.Day ? 1 : 0);
        Add(new("DUR.FACILITY_TERM_MONTHS", null, null, null, null, "SPECIFIED", months, null, null, null, from, null, "fac.Facility"));
        var lineTerms = await c.QueryAsync<(long Root, long Limit, long Line, int? Tenor, int? Deferral, int? LcValidity, int? Notice, string? NoticeUnit, decimal? CashCover,
            decimal? Financing, DateTime? From, DateTime? To)>(new CommandDefinition(
            $"""
            SELECT t.RootId, l.LimitId, l.LimitProductLineId, t.MaxTotalTenorDays, t.MaxDeferralDays, t.LcValidityDays, t.AdvanceNoticeDays, t.AdvanceNoticeUnit, t.CashCoverPct,
                   t.FinancingRatioPct, t.EffectiveFrom, t.EffectiveTo
              FROM fac.ProductLineTerm AS t JOIN fac.LimitProductLine AS l ON l.LimitProductLineId = t.LimitProductLineId
             WHERE t.FacilityId = @f AND {V("t")} AND t.ToRevision IS DISTINCT FROM t.FromRevision;
            """, p, tx, cancellationToken: ct)).ConfigureAwait(false);
        foreach (var t in lineTerms)
        {
            void Line(string code, decimal? n) { if (n is not null) Add(new(code, t.Limit, t.Line, null, null, "SPECIFIED", n, null, null, null, t.From ?? from, t.To, $"fac.ProductLineTerm:{t.Root}")); }
            Line("DUR.MAX_TOTAL_TENOR_DAYS", t.Tenor);
            Line("DUR.MAX_DEFERRAL_DAYS", t.Deferral);
            Line("DUR.LC_VALIDITY_DAYS", t.LcValidity);
            Line("DUR.ADVANCE_NOTICE_DAYS", t.Notice);
            Line("COL.CASH_COVER_PCT", t.CashCover);
            Line("COL.FINANCING_RATIO_PCT", t.Financing);
        }

        // Reporting lags and covenant thresholds.
        var obligations = await c.QueryAsync<(long Root, string Type, int? Offset, string? Unit, string? State, decimal? Value, DateTime From, DateTime? To, long? Doc, string? Page,
            string Confidence)>(new CommandDefinition(
            $"""
            SELECT o.RootId, t.Code, r.OffsetValue, r.OffsetUnit, cv.ThresholdState, cv.ThresholdValue, o.ValidFrom, o.ValidTo, o.SourceDocumentId, o.SourcePage, o.Confidence
              FROM obl.Obligation AS o JOIN cat.ObligationType AS t ON t.ObligationTypeId = o.ObligationTypeId
              LEFT JOIN obl.ReportingObligation AS r ON r.ObligationId = o.ObligationId AND {V("r")}
              LEFT JOIN obl.Covenant AS cv ON cv.ObligationId = o.ObligationId AND {V("cv")}
             WHERE o.FacilityId = @f AND {V("o")} AND o.ToRevision IS DISTINCT FROM o.FromRevision;
            """, p, tx, cancellationToken: ct)).ConfigureAwait(false);
        foreach (var o in obligations)
        {
            var days = o.Offset is { } n ? o.Unit == "MONTHS" ? n * 30 : n : (int?)null;
            ProjectedTerm O(string code, string state, decimal? v) => new(code, null, null, null, null, state, v, null, null, null, o.From, o.To, $"obl.Obligation:{o.Root}", o.Doc, o.Page,
                o.Confidence);
            switch (o.Type)
            {
                case "AUDITED_ANNUAL_FS" when days is not null: Add(O("DUR.AUDITED_FS_LAG_DAYS", "SPECIFIED", days)); break;
                case "INTERNAL_SEMIANNUAL_FS" or "QUARTERLY_FS" when days is not null: Add(O("DUR.INTERIM_FS_LAG_DAYS", "SPECIFIED", days)); break;
                case "REVENUE_CHANNELLING_PCT": Add(O("COV.REVENUE_CHANNELLING_PCT", o.State == "SET" ? "SPECIFIED" : "NOT_SPECIFIED_IN_AGREEMENT", o.State == "SET" ? o.Value : null)); break;
                case "CAPITAL_PRESERVATION": Add(O("COV.CAPITAL_PRESERVATION_AMOUNT", o.State == "SET" ? "SPECIFIED" : "NOT_SPECIFIED_IN_AGREEMENT", o.State == "SET" ? o.Value : null)); break;
                case "MIN_AVG_BALANCE": Add(O("COV.MIN_AVG_BALANCE", o.State == "SET" ? "SPECIFIED" : "NOT_SPECIFIED_IN_AGREEMENT", o.State == "SET" ? o.Value : null)); break;
            }
        }

        // Collateral: the current approved version of each collateral the revision links.
        var tree = (await FacilityTreeStore.LoadAsync(c, tx, facility, rev, ct).ConfigureAwait(false)).Tree(total);
        var col = (await c.QueryAsync<(long Collateral, string Structure, long? LimitId, long? LimitRoot, decimal? Note, string? PartyKind, decimal? Pct, decimal? Sum, string? Basis,
            int? FirstYearValuers)>(new CommandDefinition(
            $"""
            SELECT k.RootId, k.StructureKind, l.LimitId, lm.RootId, n.NoteAmount, p.Kind, i.CoveragePct, i.SumInsured, i.CoverageBasis,
                   (SELECT MAX(v.RequiredValuerCount) FROM col.ValuationSchedule AS v WHERE v.CollateralId = k.CollateralId AND v.FromYear = 1)
              FROM col.CollateralLink AS l
              JOIN col.Collateral AS k ON k.RootId = l.CollateralId AND k.ApprovalState = 'APPROVED' AND k.Status = 'ACTIVE'
              LEFT JOIN fac.Limit AS lm ON lm.LimitId = l.LimitId
              LEFT JOIN col.PromissoryNote AS n ON n.CollateralId = k.CollateralId
              LEFT JOIN col.Guarantee AS g ON g.CollateralId = k.CollateralId LEFT JOIN pty.Party AS p ON p.PartyId = g.GuarantorPartyId
              LEFT JOIN col.InsurancePolicyAssignment AS i ON i.CollateralId = k.CollateralId
             WHERE l.FacilityId = @f AND {V("l")} AND l.ToRevision IS DISTINCT FROM l.FromRevision AND l.UnlinkedOn IS NULL;
            """, p, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        ProjectedTerm C(string code, long? limit, decimal? n, bool? flag = null) => new(code, limit, null, null, null, "SPECIFIED", n, null, flag, null, from, null, "col.CollateralLink");
        foreach (var n in col.Where(x => x.Note is not null).GroupBy(x => x.LimitId))
            Add(C("COL.PN_PCT_OF_LIMIT", n.Key, CollateralMath.NoteRatioPct(n.Sum(x => x.Note!.Value), n.First().LimitRoot is { } lr ? tree.Cap(lr) : total)));
        if (col.Any(x => x.Structure == "GUARANTEE"))
        {
            Add(C("COL.GUARANTORS_INDIVIDUAL", null, col.Count(x => x.Structure == "GUARANTEE" && x.PartyKind == "INDIVIDUAL")));
            Add(C("COL.GUARANTORS_CORPORATE", null, col.Count(x => x.Structure == "GUARANTEE" && x.PartyKind == "ORGANIZATION")));
        }
        foreach (var i in col.Where(x => x.Structure == "INSURANCE_ASSIGNMENT" && x.Sum is not null).GroupBy(x => x.LimitId))
        {
            var x = i.First();
            var cap = x.LimitRoot is { } r ? tree.Cap(r) : total;
            var required = x.Basis == "PCT_OF_LIMIT" ? cap * (x.Pct ?? 0) / 100m : cap;
            Add(C("COL.INSURANCE_PCT", i.Key, required <= 0 ? null : Math.Round(i.Sum(y => y.Sum!.Value) / required * 100m, 2)));
        }
        if (col.Max(x => x.FirstYearValuers) is { } valuers) Add(C("COL.VALUERS_FIRST_YEAR", null, valuers));
        Add(C("COL.SET_OFF", null, null, col.Any(x => x.Structure == "SET_OFF")));
        Add(C("COL.NEGATIVE_PLEDGE", null, null, col.Any(x => x.Structure == "NEGATIVE_PLEDGE")));

        // One value per key, scope, bound and start (the unique key of cmp.TermValue).
        return [.. terms.Where(t => t.State != "SPECIFIED" || t.Number is not null || t.Text is not null || t.Flag is not null || t.Enum is not null)
            .GroupBy(t => (t.Code, t.LimitId, t.LineId, t.ProductId, t.CompanyId, t.From)).Select(g => g.First())];
    }

    /// <summary>The approval's projection (before ApprovedRevisionNo moves to rev): the open projected rows close at rev and the new values open at it.</summary>
    public static async Task<int> ProjectAsync(SqlConnection c, SqlTransaction tx, long facility, int rev, DateTime from, DateTime expiry, decimal total, int currencyId,
        CancellationToken ct)
    {
        var values = await ComputeAsync(c, tx, facility, int.MaxValue, from, expiry, total, ct).ConfigureAwait(false);
        var types = (await c.QueryAsync<(int Id, string Code, string Kind, string Unit, string Bound)>(new CommandDefinition(
            "SELECT TermTypeId, Code, ValueKind, Unit, DefaultBound FROM cmp.TermType;", transaction: tx, cancellationToken: ct)).ConfigureAwait(false))
            .ToDictionary(t => t.Code, StringComparer.Ordinal);
        var old = (await c.QueryAsync<(long Id, long Root, int Type, long? Limit, long? Line, int? Product, long? Company, string Bound, DateTime From)>(new CommandDefinition(
            """
            SELECT TermValueId, RootId, TermTypeId, LimitId, LimitProductLineId, ProductId, CompanyId, Bound, EffectiveFrom FROM cmp.TermValue
             WHERE FacilityId = @f AND Origin = 'PROJECTED' AND ToRevision IS NULL AND FromRevision < @r;
            """, new { f = facility, r = rev }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE cmp.TermValue SET ToRevision = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE FacilityId = @f AND Origin = 'PROJECTED' AND ToRevision IS NULL AND FromRevision < @r;
            """, new { f = facility, r = rev }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var n = 0;
        foreach (var v in values)
        {
            if (!types.TryGetValue(v.Code, out var t)) continue;   // a key the tenant retired
            // Limits and lines are named by the open (draft) row; the old projected row of the same key and root scope is the one this follows.
            // Each old row is followed once: two lines with the same key take two roots.
            var prev = old.FirstOrDefault(o => o.Type == t.Id && o.Product == v.ProductId && o.Company == v.CompanyId && o.Bound == t.Bound && o.From == v.From);
            if (prev.Id != 0) old.Remove(prev);
            var number = t.Kind is "PERCENT" or "AMOUNT" or "DAYS" or "MONTHS" or "COUNT" ? v.Number : null;
            var normalized = number is null ? (decimal?)null : t.Kind == "MONTHS" ? number * 30 : number;
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT cmp.TermValue (TenantId, FacilityId, TermTypeId, LimitId, LimitProductLineId, ProductId, CompanyId, ValueState, ValueNumber, ValueText, ValueBool, ValueEnum, Unit,
                                      CurrencyId, Bound, NormalizedValue, Origin, ProjectedFrom, EffectiveFrom, EffectiveTo, FromRevision, SupersedesId, InheritedRootId,
                                      SourceDocumentId, SourcePage, NoSourceReason, Confidence, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @type, @limit, @line, @product, @company, @state, @number, @text, @flag, @enum, @unit, @cur, @bound, @norm,
                        'PROJECTED', @from_, @eff, @to, @r, @sup, @root, @doc, @page, @reason, @conf, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """, new
                {
                    f = facility, type = t.Id, limit = v.LimitId, line = v.LineId, product = v.ProductId, company = v.CompanyId, state = v.State,
                    number = v.State == "SPECIFIED" ? number : null, text = v.State == "SPECIFIED" && t.Kind == "TEXT" ? v.Text : null,
                    flag = v.State == "SPECIFIED" && t.Kind == "BOOLEAN" ? v.Flag : null, @enum = v.State == "SPECIFIED" && t.Kind == "ENUM" ? v.Enum : null, unit = t.Unit,
                    cur = t.Kind == "AMOUNT" ? currencyId : (int?)null, bound = t.Bound, norm = v.State == "SPECIFIED" ? normalized : null, from_ = v.ProjectedFrom, eff = v.From,
                    to = v.To, r = rev, sup = prev.Id == 0 ? (long?)null : prev.Id, root = prev.Id == 0 ? (long?)null : prev.Root, doc = v.SourceDocumentId,
                    page = v.SourceDocumentId is null ? null : v.SourcePage, reason = v.SourceDocumentId is null ? "Projected from the approved revision" : null,
                    conf = v.SourceDocumentId is null ? "ENTERED_NO_DOCUMENT" : v.Confidence,
                }, tx, cancellationToken: ct)).ConfigureAwait(false);
            n++;
        }
        return n;
    }
}

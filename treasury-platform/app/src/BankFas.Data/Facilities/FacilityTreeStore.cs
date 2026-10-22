using BankFas.Core.Facilities;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Facilities;

public sealed class LimitRow
{
    public long LimitId { get; init; }
    public long RootId { get; init; }
    public long? ParentLimitId { get; init; }
    public long? ParentRootId { get; init; }
    public int LimitTypeId { get; init; }
    public string LimitTypeCode { get; init; } = "";
    public string Kind { get; init; } = "";
    public string Code { get; init; } = "";
    public string NameAr { get; init; } = "";
    public string? NameEn { get; init; }
    public string? BankStructureNo { get; init; }
    public string AmountBasis { get; init; } = "";
    public decimal? Amount { get; init; }
    public decimal? PctOfParent { get; init; }
    public decimal? EffectiveAmount { get; init; }
    public string DistributionMode { get; init; } = "";
    public bool IsRevolving { get; init; }
    public bool? IsCommitted { get; init; }
    public DateTime? StartDate { get; init; }
    public DateTime? EndDate { get; init; }
    public DateTime? DueDate { get; init; }
    public string CompanyAllocationMode { get; init; } = "";
    public string PricingMode { get; init; } = "INHERIT";
    public int FromRevision { get; init; }
    public int? ToRevision { get; init; }
    public long? SourceDocumentId { get; init; }
    public string? SourcePage { get; init; }
    public bool ReadFromScan { get; init; }
    public string? NoSourceReason { get; init; }
    public string Confidence { get; init; } = "";
}

public sealed class LineRow
{
    public long LimitProductLineId { get; init; }
    public long RootId { get; init; }
    public long LimitId { get; init; }
    public long LimitRootId { get; init; }
    public int ProductId { get; init; }
    public string ProductCode { get; init; } = "";
    public string? ProductNameAr { get; init; }
    public string? ProductNameEn { get; init; }
    public bool ConsumesCreditLimit { get; init; }
    public string? BankProductCode { get; init; }
    public string? AmountBasis { get; init; }
    public decimal? Amount { get; init; }
    public decimal? PctOfParent { get; init; }
    public bool? IsRevolving { get; init; }
    public DateTime? DueDate { get; init; }
    public bool IsActive { get; init; }
    public int FromRevision { get; init; }
    public int? ToRevision { get; init; }
    public string? NoSourceReason { get; init; }
}

public sealed class RuleRow
{
    public long LimitCompanyRuleId { get; init; }
    public long RootId { get; init; }
    public long LimitId { get; init; }
    public long LimitRootId { get; init; }
    public long CompanyId { get; init; }
    public Guid CompanyPublicId { get; init; }
    public string? CompanyNameAr { get; init; }
    public string? CompanyNameEn { get; init; }
    public string RuleKind { get; init; } = "";
    public decimal? AllocationAmount { get; init; }
    public decimal? AllocationPct { get; init; }
    public string? Reason { get; init; }
    public DateTime ValidFrom { get; init; }
    public DateTime? ValidTo { get; init; }
    public int FromRevision { get; init; }
    public int? ToRevision { get; init; }
}

public sealed class TermRow
{
    public long ProductLineTermId { get; init; }
    public long RootId { get; init; }
    public long LimitProductLineId { get; init; }
    public long LineRootId { get; init; }
    public int? MaxTotalTenorDays { get; init; }
    public int? MaxDeferralDays { get; init; }
    public int? MaxPostDeferralFinancingDays { get; init; }
    public int? LcValidityDays { get; init; }
    public decimal? CashCoverPct { get; init; }
    public decimal? FinancingRatioPct { get; init; }
    public int? AdvanceNoticeDays { get; init; }
    public string AdvanceNoticeUnit { get; init; } = "";
    public string CheckMode { get; init; } = "";
    public DateTime EffectiveFrom { get; init; }
    public DateTime? EffectiveTo { get; init; }
    public int FromRevision { get; init; }
    public int? ToRevision { get; init; }
}

/// <summary>The limit tree of one revision as stored, and the tree it makes (<see cref="LimitTree"/>).</summary>
public sealed record TreeRows(List<LimitRow> Limits, List<LineRow> Lines, List<RuleRow> Rules, List<TermRow> Terms, Dictionary<int, HashSet<int>> TypeProducts)
{
    public LimitTree Tree(decimal total, DateTime? on = null) => new(total,
        Limits.Select(l => new LimitNode(l.RootId, l.ParentRootId, l.Code, l.Kind, l.DistributionMode, l.AmountBasis, l.Amount, l.PctOfParent, l.EndDate,
            TypeProducts.GetValueOrDefault(l.LimitTypeId))),
        Lines.Where(l => l.IsActive).Select(l => new ProductLine(l.RootId, l.LimitRootId, l.ProductId, l.BankProductCode, l.AmountBasis, l.Amount, l.PctOfParent, l.DueDate)),
        Rules.Where(r => on is null || (r.ValidFrom <= on && (r.ValidTo is null || r.ValidTo >= on)))
            .Select(r => new CompanyRule(r.LimitRootId, r.CompanyId, r.RuleKind, r.AllocationAmount, r.AllocationPct)));
}

/// <summary>
/// Reading and writing the revisioned limit tree of a facility (fac.Limit, LimitProductLine, LimitCompanyRule and
/// ProductLineTerm; BR-FAC-003). A row is valid at revision a when FromRevision &lt;= a &lt; ToRevision; the open rows
/// (ToRevision NULL) are the draft as it stands. The rows point to their parents by row id, so a draft revision that
/// changes the tree first copies the whole approved tree into itself (<see cref="CopyIntoDraftAsync"/>): every row is
/// closed at the draft and succeeded by a copy with the same root that points to the copied parents; the draft then
/// edits its own rows. An approval moves the active utilisations and reservations to the rows of the approved
/// revision (<see cref="RelinkAsync"/>).
/// </summary>
public static class FacilityTreeStore
{
    private static string Valid(string alias) => $"{alias}.FromRevision <= @rev AND ({alias}.ToRevision IS NULL OR {alias}.ToRevision > @rev)";

    public static async Task<TreeRows> LoadAsync(SqlConnection c, SqlTransaction? tx, long facility, int rev, CancellationToken ct)
    {
        // int.MaxValue reads the open rows (the draft); FromRevision <= MaxValue holds for every row.
        var open = rev == int.MaxValue;
        string V(string a) => open ? $"{a}.ToRevision IS NULL" : Valid(a);
        var p = new { f = facility, rev };
        var limits = (await c.QueryAsync<LimitRow>(new CommandDefinition(
            $"""
            SELECT l.LimitId, l.RootId, l.ParentLimitId, pl.RootId AS ParentRootId, l.LimitTypeId, lt.Code AS LimitTypeCode, lt.Kind, l.Code, l.NameAr, l.NameEn,
                   l.BankStructureNo, l.AmountBasis, l.Amount, l.PctOfParent, l.EffectiveAmount, l.DistributionMode, l.IsRevolving, l.IsCommitted, l.StartDate, l.EndDate,
                   l.DueDate, l.CompanyAllocationMode, l.PricingMode, l.FromRevision, l.ToRevision, l.SourceDocumentId, l.SourcePage, l.ReadFromScan, l.NoSourceReason, l.Confidence
              FROM fac.Limit AS l
              JOIN cat.LimitType AS lt ON lt.LimitTypeId = l.LimitTypeId
              LEFT JOIN fac.Limit AS pl ON pl.LimitId = l.ParentLimitId
             WHERE l.FacilityId = @f AND {V("l")}
             ORDER BY l.Code;
            """, p, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var lines = (await c.QueryAsync<LineRow>(new CommandDefinition(
            $"""
            SELECT x.LimitProductLineId, x.RootId, x.LimitId, l.RootId AS LimitRootId, x.ProductId, pr.Code AS ProductCode, pr.NameAr AS ProductNameAr,
                   pr.NameEn AS ProductNameEn, pr.ConsumesCreditLimit, x.BankProductCode, x.AmountBasis, x.Amount, x.PctOfParent, x.IsRevolving, x.DueDate, x.IsActive,
                   x.FromRevision, x.ToRevision, x.NoSourceReason
              FROM fac.LimitProductLine AS x JOIN fac.Limit AS l ON l.LimitId = x.LimitId JOIN cat.Product AS pr ON pr.ProductId = x.ProductId
             WHERE x.FacilityId = @f AND {V("x")}
             ORDER BY l.Code, pr.Code, x.BankProductCode;
            """, p, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var rules = (await c.QueryAsync<RuleRow>(new CommandDefinition(
            $"""
            SELECT x.LimitCompanyRuleId, x.RootId, x.LimitId, l.RootId AS LimitRootId, x.CompanyId, co.PublicId AS CompanyPublicId, co.NameAr AS CompanyNameAr,
                   co.NameEn AS CompanyNameEn, x.RuleKind, x.AllocationAmount, x.AllocationPct, x.Reason, x.ValidFrom, x.ValidTo, x.FromRevision, x.ToRevision
              FROM fac.LimitCompanyRule AS x JOIN fac.Limit AS l ON l.LimitId = x.LimitId JOIN org.Company AS co ON co.CompanyId = x.CompanyId
             WHERE x.FacilityId = @f AND {V("x")};
            """, p, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var terms = (await c.QueryAsync<TermRow>(new CommandDefinition(
            $"""
            SELECT x.ProductLineTermId, x.RootId, x.LimitProductLineId, ln.RootId AS LineRootId, x.MaxTotalTenorDays, x.MaxDeferralDays, x.MaxPostDeferralFinancingDays,
                   x.LcValidityDays, x.CashCoverPct, x.FinancingRatioPct, x.AdvanceNoticeDays, x.AdvanceNoticeUnit, x.CheckMode, x.EffectiveFrom, x.EffectiveTo,
                   x.FromRevision, x.ToRevision
              FROM fac.ProductLineTerm AS x JOIN fac.LimitProductLine AS ln ON ln.LimitProductLineId = x.LimitProductLineId
             WHERE x.FacilityId = @f AND {V("x")}
             ORDER BY x.EffectiveFrom;
            """, p, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var types = (await c.QueryAsync<(int Type, int Product)>(new CommandDefinition(
            "SELECT LimitTypeId, ProductId FROM cat.LimitTypeProduct;", transaction: tx, cancellationToken: ct)).ConfigureAwait(false))
            .GroupBy(x => x.Type).ToDictionary(g => g.Key, g => g.Select(x => x.Product).ToHashSet());
        return new TreeRows(limits, lines, rules, terms, types);
    }

    /// <summary>The active utilisations and reservations of a facility, by root, in its currency (BR-FAC-002: a fixed rate for another currency).</summary>
    public static async Task<List<Exposure>> ExposuresAsync(SqlConnection c, SqlTransaction? tx, long facility, CancellationToken ct) =>
        [.. await c.QueryAsync<Exposure>(new CommandDefinition(
            """
            SELECT l.RootId AS LimitRoot, ln.RootId AS LineRoot, u.CompanyId, ROUND(u.Amount * ISNULL(u.RateToFacilityCcy, 1), 2) AS Amount, CAST(0 AS BIT) AS IsReservation,
                   CAST(NULL AS BIGINT) AS RequestId
              FROM fac.Utilization AS u JOIN fac.Limit AS l ON l.LimitId = u.LimitId LEFT JOIN fac.LimitProductLine AS ln ON ln.LimitProductLineId = u.LimitProductLineId
             WHERE u.FacilityId = @f AND u.Status = 'ACTIVE'
            UNION ALL
            SELECT l.RootId, ln.RootId, r.CompanyId, ROUND(r.Amount * ISNULL(r.RateToFacilityCcy, 1), 2), CAST(1 AS BIT), r.RequestId
              FROM fac.LimitReservation AS r JOIN fac.Limit AS l ON l.LimitId = r.LimitId LEFT JOIN fac.LimitProductLine AS ln ON ln.LimitProductLineId = r.LimitProductLineId
             WHERE r.FacilityId = @f AND r.Status = 'ACTIVE';
            """, new { f = facility }, tx, cancellationToken: ct)).ConfigureAwait(false)];

    /// <summary>
    /// The first change to the tree in a draft: every approved row still open is closed at the draft and succeeded by a
    /// copy that points to the copied parents (limits level by level from the roots, then lines, rules and terms).
    /// A no-op once the draft holds the tree. The pricing rules, terms and obligations that point to limits and lines
    /// are copied by their own batches when they exist.
    /// </summary>
    public static async Task CopyIntoDraftAsync(SqlConnection c, SqlTransaction tx, long facility, int rev, CancellationToken ct)
    {
        var p = new { f = facility, r = rev };
        var pending = await c.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT (SELECT COUNT(*) FROM fac.Limit WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r)
                 + (SELECT COUNT(*) FROM fac.LimitProductLine WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r)
                 + (SELECT COUNT(*) FROM fac.LimitCompanyRule WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r)
                 + (SELECT COUNT(*) FROM fac.ProductLineTerm WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r)
                 + (SELECT COUNT(*) FROM prc.PricingRule WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r)
                 + (SELECT COUNT(*) FROM prc.PricingTier WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r)
                 + (SELECT COUNT(*) FROM col.CollateralLink WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r);
            """, p, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (pending == 0) return;
        await c.ExecuteAsync(new CommandDefinition(
            """
            DECLARE @me BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
            DECLARE @old TABLE (Id BIGINT NOT NULL, Kind TINYINT NOT NULL, PRIMARY KEY (Kind, Id));
            INSERT @old SELECT LimitId, 1 FROM fac.Limit WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r;
            INSERT @old SELECT LimitProductLineId, 2 FROM fac.LimitProductLine WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r;
            INSERT @old SELECT LimitCompanyRuleId, 3 FROM fac.LimitCompanyRule WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r;
            INSERT @old SELECT ProductLineTermId, 4 FROM fac.ProductLineTerm WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r;
            INSERT @old SELECT PricingRuleId, 5 FROM prc.PricingRule WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r;
            INSERT @old SELECT PricingTierId, 6 FROM prc.PricingTier WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r;
            INSERT @old SELECT CollateralLinkId, 7 FROM col.CollateralLink WHERE FacilityId = @f AND ToRevision IS NULL AND FromRevision < @r;
            -- One open row per root: the old rows close first.
            UPDATE fac.Limit SET ToRevision = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me WHERE LimitId IN (SELECT Id FROM @old WHERE Kind = 1);
            UPDATE fac.LimitProductLine SET ToRevision = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me WHERE LimitProductLineId IN (SELECT Id FROM @old WHERE Kind = 2);
            UPDATE fac.LimitCompanyRule SET ToRevision = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me WHERE LimitCompanyRuleId IN (SELECT Id FROM @old WHERE Kind = 3);
            UPDATE fac.ProductLineTerm SET ToRevision = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me WHERE ProductLineTermId IN (SELECT Id FROM @old WHERE Kind = 4);
            UPDATE prc.PricingRule SET ToRevision = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me WHERE PricingRuleId IN (SELECT Id FROM @old WHERE Kind = 5);
            UPDATE prc.PricingTier SET ToRevision = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me WHERE PricingTierId IN (SELECT Id FROM @old WHERE Kind = 6);
            UPDATE col.CollateralLink SET ToRevision = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me WHERE CollateralLinkId IN (SELECT Id FROM @old WHERE Kind = 7);
            -- The limits, level by level: a copy whose parent was copied points to the parent's copy.
            DECLARE @n INT = 1;
            WHILE @n > 0
            BEGIN
                INSERT fac.Limit (TenantId, FacilityId, ParentLimitId, LimitTypeId, Code, NameAr, NameEn, BankStructureNo, AmountBasis, Amount, PctOfParent, EffectiveAmount,
                                  DistributionMode, IsRevolving, IsCommitted, StartDate, EndDate, DueDate, PricingMode, CompanyAllocationMode, FromRevision, SupersedesId,
                                  InheritedRootId, SourceDocumentId, SourcePage, ReadFromScan, OriginalText, NoSourceReason, Confidence, VerifiedBy, VerifiedOn, ConflictId, CreatedBy)
                SELECT o.TenantId, o.FacilityId, np.LimitId, o.LimitTypeId, o.Code, o.NameAr, o.NameEn, o.BankStructureNo, o.AmountBasis, o.Amount, o.PctOfParent, o.EffectiveAmount,
                       o.DistributionMode, o.IsRevolving, o.IsCommitted, o.StartDate, o.EndDate, o.DueDate, o.PricingMode, o.CompanyAllocationMode, @r, o.LimitId, o.RootId,
                       o.SourceDocumentId, o.SourcePage, o.ReadFromScan, o.OriginalText, o.NoSourceReason, o.Confidence, o.VerifiedBy, o.VerifiedOn, o.ConflictId, @me
                  FROM fac.Limit AS o
                  LEFT JOIN fac.Limit AS np ON np.FacilityId = o.FacilityId AND np.FromRevision = @r AND np.SupersedesId = o.ParentLimitId
                 WHERE o.LimitId IN (SELECT Id FROM @old WHERE Kind = 1)
                   AND NOT EXISTS (SELECT 1 FROM fac.Limit AS d WHERE d.FacilityId = o.FacilityId AND d.FromRevision = @r AND d.SupersedesId = o.LimitId)
                   AND (o.ParentLimitId IS NULL OR np.LimitId IS NOT NULL OR o.ParentLimitId NOT IN (SELECT Id FROM @old WHERE Kind = 1));
                SET @n = @@ROWCOUNT;
            END;
            INSERT fac.LimitProductLine (TenantId, FacilityId, LimitId, ProductId, BankProductCode, AmountBasis, Amount, PctOfParent, IsRevolving, DueDate, IsActive, FromRevision,
                                         SupersedesId, InheritedRootId, SourceDocumentId, SourcePage, ReadFromScan, OriginalText, NoSourceReason, Confidence, VerifiedBy,
                                         VerifiedOn, ConflictId, CreatedBy)
            SELECT o.TenantId, o.FacilityId, ISNULL(nl.LimitId, o.LimitId), o.ProductId, o.BankProductCode, o.AmountBasis, o.Amount, o.PctOfParent, o.IsRevolving, o.DueDate,
                   o.IsActive, @r, o.LimitProductLineId, o.RootId, o.SourceDocumentId, o.SourcePage, o.ReadFromScan, o.OriginalText, o.NoSourceReason, o.Confidence,
                   o.VerifiedBy, o.VerifiedOn, o.ConflictId, @me
              FROM fac.LimitProductLine AS o
              LEFT JOIN fac.Limit AS nl ON nl.FacilityId = o.FacilityId AND nl.FromRevision = @r AND nl.SupersedesId = o.LimitId
             WHERE o.LimitProductLineId IN (SELECT Id FROM @old WHERE Kind = 2);
            INSERT fac.LimitCompanyRule (TenantId, FacilityId, LimitId, CompanyId, RuleKind, AllocationAmount, AllocationPct, Reason, ValidFrom, ValidTo, FromRevision,
                                         SupersedesId, InheritedRootId, SourceDocumentId, SourcePage, ReadFromScan, OriginalText, NoSourceReason, Confidence, VerifiedBy,
                                         VerifiedOn, ConflictId, CreatedBy)
            SELECT o.TenantId, o.FacilityId, ISNULL(nl.LimitId, o.LimitId), o.CompanyId, o.RuleKind, o.AllocationAmount, o.AllocationPct, o.Reason, o.ValidFrom, o.ValidTo, @r,
                   o.LimitCompanyRuleId, o.RootId, o.SourceDocumentId, o.SourcePage, o.ReadFromScan, o.OriginalText, o.NoSourceReason, o.Confidence, o.VerifiedBy,
                   o.VerifiedOn, o.ConflictId, @me
              FROM fac.LimitCompanyRule AS o
              LEFT JOIN fac.Limit AS nl ON nl.FacilityId = o.FacilityId AND nl.FromRevision = @r AND nl.SupersedesId = o.LimitId
             WHERE o.LimitCompanyRuleId IN (SELECT Id FROM @old WHERE Kind = 3);
            INSERT fac.ProductLineTerm (TenantId, FacilityId, LimitProductLineId, MaxTotalTenorDays, MaxDeferralDays, MaxPostDeferralFinancingDays, LcValidityDays, CashCoverPct,
                                        FinancingRatioPct, AdvanceNoticeDays, AdvanceNoticeUnit, CheckMode, EffectiveFrom, EffectiveTo, FromRevision, SupersedesId,
                                        InheritedRootId, SourceDocumentId, SourcePage, ReadFromScan, OriginalText, NoSourceReason, Confidence, VerifiedBy, VerifiedOn,
                                        ConflictId, CreatedBy)
            SELECT o.TenantId, o.FacilityId, ISNULL(nl.LimitProductLineId, o.LimitProductLineId), o.MaxTotalTenorDays, o.MaxDeferralDays, o.MaxPostDeferralFinancingDays,
                   o.LcValidityDays, o.CashCoverPct, o.FinancingRatioPct, o.AdvanceNoticeDays, o.AdvanceNoticeUnit, o.CheckMode, o.EffectiveFrom, o.EffectiveTo, @r,
                   o.ProductLineTermId, o.RootId, o.SourceDocumentId, o.SourcePage, o.ReadFromScan, o.OriginalText, o.NoSourceReason, o.Confidence, o.VerifiedBy,
                   o.VerifiedOn, o.ConflictId, @me
              FROM fac.ProductLineTerm AS o
              LEFT JOIN fac.LimitProductLine AS nl ON nl.FacilityId = o.FacilityId AND nl.FromRevision = @r AND nl.SupersedesId = o.LimitProductLineId
             WHERE o.ProductLineTermId IN (SELECT Id FROM @old WHERE Kind = 4);
            -- The pricing rules point to the copied limit and line; their tiers to the copied rule.
            INSERT prc.PricingRule (TenantId, FacilityId, ScopeLimitId, ScopeLimitProductLineId, ScopeProductId, ScopeCompanyId, ComponentKind, RateState, FeeTypeId, FinancingTypeId,
                                    Method, TariffItemId, AddOnPct, BaseRateId, MarginPct, BaseFloorPct, RatePct, RateRangeLowPct, RateRangeHighPct, FixedAmount, PerMillionAmount,
                                    CurrencyId, PeriodBasis, PeriodDays, MinFeeAmount, MaxFeeAmount, RateFixing, RepricingMonths, DayCount, VatExclusive, BenchmarkReplacement,
                                    ReplacementText, BankMayChange, ObjectionDays, ObjectionDaysKind, TriggerEvent, EffectiveFrom, EffectiveTo, Retroactive, RetroactiveReason,
                                    FromRevision, SupersedesId, InheritedRootId, SourceDocumentId, SourcePage, ReadFromScan, OriginalText, NoSourceReason, Confidence, VerifiedBy,
                                    VerifiedOn, ConflictId, CreatedBy)
            SELECT o.TenantId, o.FacilityId, ISNULL(nl.LimitId, o.ScopeLimitId), ISNULL(nln.LimitProductLineId, o.ScopeLimitProductLineId), o.ScopeProductId, o.ScopeCompanyId,
                   o.ComponentKind, o.RateState, o.FeeTypeId, o.FinancingTypeId, o.Method, o.TariffItemId, o.AddOnPct, o.BaseRateId, o.MarginPct, o.BaseFloorPct, o.RatePct,
                   o.RateRangeLowPct, o.RateRangeHighPct, o.FixedAmount, o.PerMillionAmount, o.CurrencyId, o.PeriodBasis, o.PeriodDays, o.MinFeeAmount, o.MaxFeeAmount, o.RateFixing,
                   o.RepricingMonths, o.DayCount, o.VatExclusive, o.BenchmarkReplacement, o.ReplacementText, o.BankMayChange, o.ObjectionDays, o.ObjectionDaysKind, o.TriggerEvent,
                   o.EffectiveFrom, o.EffectiveTo, o.Retroactive, o.RetroactiveReason, @r, o.PricingRuleId, o.RootId, o.SourceDocumentId, o.SourcePage, o.ReadFromScan,
                   o.OriginalText, o.NoSourceReason, o.Confidence, o.VerifiedBy, o.VerifiedOn, o.ConflictId, @me
              FROM prc.PricingRule AS o
              LEFT JOIN fac.Limit AS nl ON nl.FacilityId = o.FacilityId AND nl.FromRevision = @r AND nl.SupersedesId = o.ScopeLimitId
              LEFT JOIN fac.LimitProductLine AS nln ON nln.FacilityId = o.FacilityId AND nln.FromRevision = @r AND nln.SupersedesId = o.ScopeLimitProductLineId
             WHERE o.PricingRuleId IN (SELECT Id FROM @old WHERE Kind = 5);
            INSERT prc.PricingTier (TenantId, FacilityId, PricingRuleId, AmountFrom, AmountTo, PeriodFromDays, PeriodToDays, RatePct, MarginPct, FixedAmount, SortOrder, FromRevision,
                                    SupersedesId, InheritedRootId, CreatedBy)
            SELECT o.TenantId, o.FacilityId, ISNULL(nr.PricingRuleId, o.PricingRuleId), o.AmountFrom, o.AmountTo, o.PeriodFromDays, o.PeriodToDays, o.RatePct, o.MarginPct,
                   o.FixedAmount, o.SortOrder, @r, o.PricingTierId, o.RootId, @me
              FROM prc.PricingTier AS o
              LEFT JOIN prc.PricingRule AS nr ON nr.FacilityId = o.FacilityId AND nr.FromRevision = @r AND nr.SupersedesId = o.PricingRuleId
             WHERE o.PricingTierId IN (SELECT Id FROM @old WHERE Kind = 6);
            -- The collateral links point to the copied limit; the collateral is named by its root (DR-36).
            INSERT col.CollateralLink (TenantId, CollateralId, FacilityId, LimitId, CoverageAmount, LienRank, LinkedOn, UnlinkedOn, FromRevision, SupersedesId, InheritedRootId, CreatedBy)
            SELECT o.TenantId, o.CollateralId, o.FacilityId, ISNULL(nl.LimitId, o.LimitId), o.CoverageAmount, o.LienRank, o.LinkedOn, o.UnlinkedOn, @r, o.CollateralLinkId, o.RootId, @me
              FROM col.CollateralLink AS o
              LEFT JOIN fac.Limit AS nl ON nl.FacilityId = o.FacilityId AND nl.FromRevision = @r AND nl.SupersedesId = o.LimitId
             WHERE o.CollateralLinkId IN (SELECT Id FROM @old WHERE Kind = 7);
            """, p, tx, cancellationToken: ct)).ConfigureAwait(false);
    }

    /// <summary>Writes the cached caps (EffectiveAmount) of the draft's limits, root to leaf (BR-FAC-009).</summary>
    public static async Task WriteCapsAsync(SqlConnection c, SqlTransaction tx, long facility, decimal total, CancellationToken ct)
    {
        var rows = await LoadAsync(c, tx, facility, int.MaxValue, ct).ConfigureAwait(false);
        var tree = rows.Tree(total);
        foreach (var l in rows.Limits)
        {
            var cap = tree.Cap(l.RootId);
            if (l.EffectiveAmount == cap) continue;
            await c.ExecuteAsync(new CommandDefinition(
                "UPDATE fac.Limit SET EffectiveAmount = @cap, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE LimitId = @id;",
                new { cap, id = l.LimitId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// The approval of revision R moves every active utilisation and reservation from a row closed at R to the row of
    /// the same root that R opened (spec 13 section 8 note 11; S2 brief section 0.1 item 6). Released, transferred and
    /// converted rows keep the row they were written against.
    /// </summary>
    public static Task RelinkAsync(SqlConnection c, SqlTransaction tx, long facility, int rev, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE u SET LimitId = nl.LimitId, LimitProductLineId = nln.LimitProductLineId, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
              FROM fac.Utilization AS u
              JOIN fac.Limit AS ol ON ol.LimitId = u.LimitId AND ol.ToRevision = @r
              JOIN fac.Limit AS nl ON nl.FacilityId = ol.FacilityId AND nl.RootId = ol.RootId AND nl.FromRevision = @r AND nl.ToRevision IS NULL
              LEFT JOIN fac.LimitProductLine AS oln ON oln.LimitProductLineId = u.LimitProductLineId
              LEFT JOIN fac.LimitProductLine AS nln ON nln.FacilityId = ol.FacilityId AND nln.RootId = oln.RootId AND nln.FromRevision <= @r AND nln.ToRevision IS NULL
             WHERE u.FacilityId = @f AND u.Status = 'ACTIVE';
            UPDATE r SET LimitId = nl.LimitId, LimitProductLineId = nln.LimitProductLineId
              FROM fac.LimitReservation AS r
              JOIN fac.Limit AS ol ON ol.LimitId = r.LimitId AND ol.ToRevision = @r
              JOIN fac.Limit AS nl ON nl.FacilityId = ol.FacilityId AND nl.RootId = ol.RootId AND nl.FromRevision = @r AND nl.ToRevision IS NULL
              LEFT JOIN fac.LimitProductLine AS oln ON oln.LimitProductLineId = r.LimitProductLineId
              LEFT JOIN fac.LimitProductLine AS nln ON nln.FacilityId = ol.FacilityId AND nln.RootId = oln.RootId AND nln.FromRevision <= @r AND nln.ToRevision IS NULL
             WHERE r.FacilityId = @f AND r.Status = 'ACTIVE';
            """, new { f = facility, r = rev }, tx, cancellationToken: ct));

    /// <summary>The roots of limits and lines closed by the draft (no row of theirs is open) that still carry an active utilisation or reservation (DQ-F13-9).</summary>
    public static async Task<List<string>> ClosedInUseAsync(SqlConnection c, SqlTransaction? tx, long facility, CancellationToken ct) =>
        [.. await c.QueryAsync<string>(new CommandDefinition(
            """
            SELECT DISTINCT l.Code FROM fac.Limit AS l
             WHERE l.FacilityId = @f AND NOT EXISTS (SELECT 1 FROM fac.Limit AS o WHERE o.FacilityId = l.FacilityId AND o.RootId = l.RootId AND o.ToRevision IS NULL)
               AND (EXISTS (SELECT 1 FROM fac.Utilization AS u JOIN fac.Limit AS x ON x.LimitId = u.LimitId WHERE x.RootId = l.RootId AND u.Status = 'ACTIVE')
                    OR EXISTS (SELECT 1 FROM fac.LimitReservation AS r JOIN fac.Limit AS x ON x.LimitId = r.LimitId WHERE x.RootId = l.RootId AND r.Status = 'ACTIVE'))
            UNION
            SELECT DISTINCT CONCAT(l.Code, '/', ISNULL(ln.BankProductCode, pr.Code)) FROM fac.LimitProductLine AS ln JOIN fac.Limit AS l ON l.LimitId = ln.LimitId
              JOIN cat.Product AS pr ON pr.ProductId = ln.ProductId
             WHERE ln.FacilityId = @f AND NOT EXISTS (SELECT 1 FROM fac.LimitProductLine AS o WHERE o.FacilityId = ln.FacilityId AND o.RootId = ln.RootId AND o.ToRevision IS NULL)
               AND (EXISTS (SELECT 1 FROM fac.Utilization AS u JOIN fac.LimitProductLine AS x ON x.LimitProductLineId = u.LimitProductLineId WHERE x.RootId = ln.RootId AND u.Status = 'ACTIVE')
                    OR EXISTS (SELECT 1 FROM fac.LimitReservation AS r JOIN fac.LimitProductLine AS x ON x.LimitProductLineId = r.LimitProductLineId WHERE x.RootId = ln.RootId AND r.Status = 'ACTIVE'));
            """, new { f = facility }, tx, cancellationToken: ct)).ConfigureAwait(false)];
}

using BankFas.Core.Collateral;
using BankFas.Data.Jobs;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Facilities;

/// <summary>
/// COL_NOTE_RENEWAL, COL_INSURANCE and COL_VALUATION (CORE.EXPIRY v3; OQ-3): the dates of the current approved version
/// of an ACTIVE collateral that the approved revision of an ACTIVE facility links on the day: the yearly renewal of a
/// note (BR-COL-002), the expiry of an assigned policy (BR-COL-003, alerts at 60, 30 and 7 days) and the next valuation
/// of a schedule (BR-COL-004). They raise COL.RENEWAL_DUE for the borrower's company. The item is the collateral's
/// root, and a new date (a renewal, a new policy) starts its alerts again. A collateral linked to two facilities is
/// reported once, for the first facility.
/// </summary>
internal sealed class CollateralExpiry(string kind) : IExpiryItemProvider
{
    public string ItemType => kind;
    public string EventCode => "COL.RENEWAL_DUE";
    public string TargetType => "col.Collateral";
    public bool ValidThroughExpiryDate => kind == "COL_INSURANCE";

    private sealed class Row
    {
        public long Id { get; init; }
        public long CollateralId { get; init; }
        public string TitleAr { get; init; } = "";
        public long CompanyId { get; init; }
        public string FacilityNo { get; init; } = "";
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string? BankNameAr { get; init; }
        public string? BankNameEn { get; init; }
    }

    private const string Linked = """
        SELECT k.RootId AS Id, k.CollateralId, k.TitleAr, f.BorrowerCompanyId AS CompanyId, f.FacilityNo, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn,
               b.NameAr AS BankNameAr, b.NameEn AS BankNameEn
          FROM col.Collateral AS k
          CROSS APPLY (SELECT TOP (1) x.FacilityId FROM col.CollateralLink AS l JOIN fac.Facility AS x ON x.FacilityId = l.FacilityId
                        WHERE l.CollateralId = k.RootId AND x.LifecycleStatus = 'ACTIVE' AND l.FromRevision <= x.ApprovedRevisionNo
                          AND (l.ToRevision IS NULL OR l.ToRevision > x.ApprovedRevisionNo) AND l.LinkedOn <= @today AND (l.UnlinkedOn IS NULL OR l.UnlinkedOn > @today)
                        ORDER BY x.FacilityId) AS fl
          JOIN fac.Facility AS f ON f.FacilityId = fl.FacilityId
          JOIN org.Company AS co ON co.CompanyId = f.BorrowerCompanyId
          OUTER APPLY (SELECT TOP (1) i.NameAr, i.NameEn FROM fac.FacilityLender AS l JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId
                        WHERE l.FacilityId = f.FacilityId AND l.FromRevision <= f.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo)
                        ORDER BY CASE WHEN l.Roles LIKE '%AGENT%' OR l.Roles LIKE '%SOLE%' THEN 0 WHEN l.Roles LIKE '%LEAD%' THEN 1 ELSE 2 END, l.SharePct DESC) AS b
         WHERE k.ApprovalState = 'APPROVED' AND k.Status = 'ACTIVE'
        """;

    public async Task<IReadOnlyList<ExpiryItem>> ItemsAsync(SqlConnection c, DateTime today, DateTime horizon, CancellationToken ct)
    {
        var rows = (await c.QueryAsync<Row>(new CommandDefinition(Linked + ";", new { today }, cancellationToken: ct)).ConfigureAwait(false)).ToDictionary(r => r.CollateralId);
        if (rows.Count == 0) return [];
        var ids = rows.Keys.ToArray();
        var dates = new List<(long Collateral, DateTime Date, string Ar, string En)>();
        switch (kind)
        {
            case "COL_NOTE_RENEWAL":
                foreach (var n in await c.QueryAsync<(long Collateral, DateTime IssuedOn, DateTime? Last)>(new CommandDefinition(
                             "SELECT CollateralId, IssuedOn, LastRenewedOn FROM col.PromissoryNote WHERE RenewalCycle = 'ANNUAL' AND CollateralId IN @ids;", new { ids },
                             cancellationToken: ct)).ConfigureAwait(false))
                    dates.Add((n.Collateral, CollateralMath.NextRenewalDue("ANNUAL", n.IssuedOn, n.Last)!.Value, "تجديد السند لأمر", "promissory note renewal"));
                break;
            case "COL_INSURANCE":
                foreach (var p in await c.QueryAsync<(long Collateral, DateTime Expiry)>(new CommandDefinition(
                             "SELECT CollateralId, PolicyExpiry FROM col.InsurancePolicyAssignment WHERE CollateralId IN @ids;", new { ids }, cancellationToken: ct)).ConfigureAwait(false))
                    dates.Add((p.Collateral, p.Expiry, "انتهاء وثيقة التأمين", "insurance policy expiry"));
                break;
            case "COL_VALUATION":
                var phases = (await c.QueryAsync<(long Collateral, int PhaseNo, int FromYear, int? ToYear, int Valuers, int Freq, DateTime Ref, DateTime? Last)>(new CommandDefinition(
                    """
                    SELECT CollateralId, PhaseNo, FromYear, ToYear, RequiredValuerCount, FrequencyMonths, ReferenceDate, LastValuationOn
                      FROM col.ValuationSchedule WHERE CollateralId IN @ids;
                    """, new { ids }, cancellationToken: ct)).ConfigureAwait(false)).GroupBy(p => p.Collateral);
                foreach (var g in phases)
                {
                    // The next valuation not yet made: after the last valuation of the schedule, or from the reference date.
                    var last = g.Max(p => p.Last);
                    var next = CollateralMath.Valuations(g.Select(p => new ValuationPhase(p.PhaseNo, p.FromYear, p.ToYear, p.Valuers, p.Freq, p.Ref)),
                        last?.AddDays(1) ?? DateTime.MinValue, horizon);
                    if (next.Count > 0) dates.Add((g.Key, next[0].Date, "موعد تقييم العقار", "property valuation"));
                }
                break;
        }
        return [.. dates.Where(d => d.Date <= horizon).Select(d =>
        {
            var r = rows[d.Collateral];
            return new ExpiryItem(r.Id, d.Date, r.CompanyId, new Dictionary<string, object?>
            {
                ["facilityNo"] = r.FacilityNo,
                ["itemLabel"] = ExpiryItemProviders.Text(d.Ar, d.En),
                ["companyName"] = ExpiryItemProviders.Text(r.CompanyNameAr, r.CompanyNameEn),
                ["bankName"] = ExpiryItemProviders.Text(r.BankNameAr, r.BankNameEn),
            });
        })];
    }
}

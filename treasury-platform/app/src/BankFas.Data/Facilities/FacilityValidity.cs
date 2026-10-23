using System.Globalization;
using BankFas.Data.Jobs;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Facilities;

/// <summary>
/// The validity of a facility (BR-FAC-005, BR-FAC-006; FR-FAC-007, 008): derived each day, never stored. An ACTIVE
/// facility is SCHEDULED before its start, EXPIRING within the tenant's setting of days before its expiry
/// (fac.validity.expiring_days, 90 by default; OQ-8), VALID before that, and NOT_CONFIRMED after its expiry date
/// until the user records an extension, the expiry or the end (DQ-F14-6). Other lifecycles have no indicator.
/// </summary>
public static class FacilityValidity
{
    public static string? Indicator(string lifecycle, DateTime effectiveFrom, DateTime expiry, DateTime today, int expiringDays)
    {
        if (lifecycle != "ACTIVE") return null;
        if (today < effectiveFrom.Date) return "SCHEDULED";
        if (today > expiry.Date) return "NOT_CONFIRMED";
        return (expiry.Date - today).Days <= expiringDays ? "EXPIRING" : "VALID";
    }

    public static async Task<int> ExpiringDaysAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct)
    {
        var raw = await c.ExecuteScalarAsync<string?>(new CommandDefinition(
            """
            SELECT ISNULL(t.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key]
             WHERE d.[Key] = 'fac.validity.expiring_days';
            """, transaction: tx, cancellationToken: ct)).ConfigureAwait(false);
        return int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var days) ? days : 90;
    }

    /// <summary>
    /// The predecessors whose approved successor has started become SUPERSEDED (BR-FAC-006, OQ-15): all of the tenant's
    /// when <paramref name="successor"/> is null (JOB-FAC-VALIDITY), or the one of this successor (its approval).
    /// The transfer of the predecessor's active utilisation to the successor comes with the utilisations.
    /// </summary>
    public static async Task<int> SupersedeDueAsync(SqlConnection c, SqlTransaction? tx, DateTime today, long? successor, CancellationToken ct)
    {
        var rows = (await c.QueryAsync<(long Previous, Guid PreviousId, string SuccessorNo, string Was)>(new CommandDefinition(
            """
            SELECT p.FacilityId, p.PublicId, ISNULL(s.PlatformRef, s.FacilityNo) AS FacilityNo, p.LifecycleStatus
              FROM fac.Facility AS s JOIN fac.Facility AS p WITH (UPDLOCK) ON p.FacilityId = s.PreviousFacilityId
             WHERE s.ApprovedRevisionNo >= 1 AND s.LifecycleStatus = 'ACTIVE' AND s.EffectiveFrom <= @today
               AND p.LifecycleStatus IN ('ACTIVE', 'SUSPENDED', 'EXPIRED') AND (@s IS NULL OR s.FacilityId = @s);
            """, new { today, s = successor }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        foreach (var r in rows)
        {
            await c.ExecuteAsync(new CommandDefinition(
                """
                UPDATE fac.Facility SET LifecycleStatus = 'SUPERSEDED', LifecycleReason = @reason, UpdatedAt = SYSUTCDATETIME(),
                       UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE FacilityId = @p;
                """, new { p = r.Previous, reason = $"Renewed by {r.SuccessorNo}" }, tx, cancellationToken: ct)).ConfigureAwait(false);
            await Outbox.EmitAsync(c, tx, "facility.validity.changed", "fac.Facility", r.Previous, new { facility = r.PreviousId, status = "SUPERSEDED", was = r.Was }, ct)
                .ConfigureAwait(false);
        }
        return rows.Count;
    }
}

/// <summary>
/// JOB-FAC-VALIDITY (seed100:60), daily before JOB-NTF-EXPIRY (DQ-F14-15): a predecessor whose renewal has started is
/// SUPERSEDED. The indicator itself is derived when it is read, and its alerts come from the FACILITY expiry rule.
/// </summary>
public sealed class FacilityValidityJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-FAC-VALIDITY";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
        var n = await FacilityValidity.SupersedeDueAsync(c, tx, clock.GetUtcNow().UtcDateTime.Date, null, ct).ConfigureAwait(false);
        await tx.CommitAsync(ct).ConfigureAwait(false);
        return n == 0 ? null : $"superseded {n}";
    }
}

/// <summary>
/// FACILITY (CORE.EXPIRY v3; S2-GAP-4): an ACTIVE approved facility with its expiry date. Before the date the alerts
/// are FAC.EXPIRY_DUE at the facility's own lead days (Facility.AlertLeadDays, OQ-9) or the rule's; from the day after,
/// FAC.VALIDITY_UNCONFIRMED and its weekly reminder, until the user resolves it (an extension moves the date and the
/// thresholds start again; EXPIRED, TERMINATED or SUPERSEDED takes it out of the list).
/// </summary>
internal sealed class FacilityExpiry : IExpiryItemProvider
{
    public string ItemType => "FACILITY";
    public string EventCode => "FAC.EXPIRY_DUE";
    public string TargetType => "fac.Facility";
    public string EventCodeFor(string kind) => kind == "LEAD" ? "FAC.EXPIRY_DUE" : "FAC.VALIDITY_UNCONFIRMED";
    public bool ValidThroughExpiryDate => true;
    public bool ExpiredFromNextDay => true;

    private sealed class Row
    {
        public long Id { get; init; }
        public DateTime ExpiryDate { get; init; }
        public long CompanyId { get; init; }
        public string FacilityNo { get; init; } = "";
        public string? AlertLeadDays { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string? BankNameAr { get; init; }
        public string? BankNameEn { get; init; }
    }

    public async Task<IReadOnlyList<ExpiryItem>> ItemsAsync(SqlConnection c, DateTime today, DateTime horizon, CancellationToken ct) =>
        [.. (await c.QueryAsync<Row>(new CommandDefinition(
            """
            SELECT f.FacilityId AS Id, f.ExpiryDate, f.BorrowerCompanyId AS CompanyId, ISNULL(f.PlatformRef, f.FacilityNo) AS FacilityNo, f.AlertLeadDays, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn,
                   b.NameAr AS BankNameAr, b.NameEn AS BankNameEn
              FROM fac.Facility AS f
              JOIN org.Company AS co ON co.CompanyId = f.BorrowerCompanyId
              OUTER APPLY (SELECT TOP (1) i.NameAr, i.NameEn FROM fac.FacilityLender AS l JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId
                            WHERE l.FacilityId = f.FacilityId AND l.FromRevision <= f.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo)
                            ORDER BY CASE WHEN l.Roles LIKE '%AGENT%' OR l.Roles LIKE '%SOLE%' THEN 0 WHEN l.Roles LIKE '%LEAD%' THEN 1 ELSE 2 END, l.SharePct DESC) AS b
             WHERE f.LifecycleStatus = 'ACTIVE' AND f.ApprovedRevisionNo >= 1 AND f.ExpiryDate <= @h;
            """, new { h = horizon }, cancellationToken: ct)).ConfigureAwait(false))
            .Select(r => new ExpiryItem(r.Id, r.ExpiryDate, r.CompanyId, new Dictionary<string, object?>
            {
                ["facilityNo"] = r.FacilityNo,
                ["itemLabel"] = ExpiryItemProviders.Text("التسهيل", "facility"),
                ["companyName"] = ExpiryItemProviders.Text(r.CompanyNameAr, r.CompanyNameEn),
                ["bankName"] = ExpiryItemProviders.Text(r.BankNameAr, r.BankNameEn),
            }, LeadDays: r.AlertLeadDays is { Length: > 0 } own ? [.. own.Split(',').Select(x => int.Parse(x, CultureInfo.InvariantCulture))] : null))];
}

/// <summary>
/// LIMIT and PRODUCT_LINE (CORE.EXPIRY v3; S2-GAP-4): the end date of a limit and the due date of a line of the
/// approved revision of an ACTIVE facility, at the facility's own lead days or the rule's. The item is the root, so a
/// new revision of the same limit keeps its alerts (M10:579).
/// </summary>
internal sealed class LimitExpiry(bool lines) : IExpiryItemProvider
{
    public string ItemType => lines ? "PRODUCT_LINE" : "LIMIT";
    public string EventCode => "FAC.EXPIRY_DUE";
    public string TargetType => lines ? "fac.LimitProductLine" : "fac.Limit";
    public bool ValidThroughExpiryDate => true;
    public bool ExpiredFromNextDay => true;

    private sealed class Row
    {
        public long Id { get; init; }
        public DateTime ExpiryDate { get; init; }
        public long CompanyId { get; init; }
        public string FacilityNo { get; init; } = "";
        public string Code { get; init; } = "";
        public string? AlertLeadDays { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string? BankNameAr { get; init; }
        public string? BankNameEn { get; init; }
    }

    public async Task<IReadOnlyList<ExpiryItem>> ItemsAsync(SqlConnection c, DateTime today, DateTime horizon, CancellationToken ct) =>
        [.. (await c.QueryAsync<Row>(new CommandDefinition(
            $"""
            SELECT x.RootId AS Id, x.{(lines ? "DueDate" : "EndDate")} AS ExpiryDate, f.BorrowerCompanyId AS CompanyId, ISNULL(f.PlatformRef, f.FacilityNo) AS FacilityNo,
                   {(lines ? "CONCAT(l.Code, '/', ISNULL(x.BankProductCode, pr.Code))" : "x.Code")} AS Code, f.AlertLeadDays,
                   co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn, b.NameAr AS BankNameAr, b.NameEn AS BankNameEn
              FROM {(lines ? "fac.LimitProductLine AS x JOIN fac.Limit AS l ON l.LimitId = x.LimitId JOIN cat.Product AS pr ON pr.ProductId = x.ProductId" : "fac.Limit AS x")}
              JOIN fac.Facility AS f ON f.FacilityId = x.FacilityId
              JOIN org.Company AS co ON co.CompanyId = f.BorrowerCompanyId
              OUTER APPLY (SELECT TOP (1) i.NameAr, i.NameEn FROM fac.FacilityLender AS fl JOIN ins.Institution AS i ON i.InstitutionId = fl.InstitutionId
                            WHERE fl.FacilityId = f.FacilityId AND fl.FromRevision <= f.ApprovedRevisionNo AND (fl.ToRevision IS NULL OR fl.ToRevision > f.ApprovedRevisionNo)
                            ORDER BY fl.SharePct DESC) AS b
             WHERE f.LifecycleStatus = 'ACTIVE' AND f.ApprovedRevisionNo >= 1 AND x.FromRevision <= f.ApprovedRevisionNo
               AND (x.ToRevision IS NULL OR x.ToRevision > f.ApprovedRevisionNo) AND x.{(lines ? "DueDate" : "EndDate")} <= @h
               {(lines ? "AND x.IsActive = 1" : "")};
            """, new { h = horizon }, cancellationToken: ct)).ConfigureAwait(false))
            .Select(r => new ExpiryItem(r.Id, r.ExpiryDate, r.CompanyId, new Dictionary<string, object?>
            {
                ["facilityNo"] = r.FacilityNo,
                ["itemLabel"] = ExpiryItemProviders.Text(lines ? $"خط المنتج {r.Code} في التسهيل" : $"الحد {r.Code} في التسهيل",
                    lines ? $"product line {r.Code} of facility" : $"limit {r.Code} of facility"),
                ["companyName"] = ExpiryItemProviders.Text(r.CompanyNameAr, r.CompanyNameEn),
                ["bankName"] = ExpiryItemProviders.Text(r.BankNameAr, r.BankNameEn),
            }, TargetType, r.AlertLeadDays is { Length: > 0 } own ? [.. own.Split(',').Select(x => int.Parse(x, CultureInfo.InvariantCulture))] : null))];
}

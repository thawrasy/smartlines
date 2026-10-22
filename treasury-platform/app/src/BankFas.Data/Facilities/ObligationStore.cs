using System.Globalization;
using BankFas.Core.Calendar;
using BankFas.Core.Obligations;
using BankFas.Data.Calendar;
using BankFas.Data.Jobs;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Facilities;

/// <summary>A reporting rule of a revision with its obligation (obl.ReportingObligation joined to obl.Obligation).</summary>
public sealed class ReportingRuleRow
{
    public long ReportingObligationId { get; init; }
    public long RootId { get; init; }
    public long ObligationId { get; init; }
    public long ObligationRootId { get; init; }
    public string TitleAr { get; init; } = "";
    public string? TitleEn { get; init; }
    public string Frequency { get; init; } = "";
    public string AnchorKind { get; init; } = "";
    public int? OffsetValue { get; init; }
    public string OffsetUnit { get; init; } = "";
    public DateTime? FixedDueDate { get; init; }
    public DateTime? FirstPeriodEnd { get; init; }
    public int? HorizonMonths { get; init; }
    public string? AlertLeadDays { get; init; }
    public DateTime ValidFrom { get; init; }
    public DateTime? ValidTo { get; init; }
    public string Status { get; init; } = "";
    public int? GraceDays { get; init; }
    public int? CureDays { get; init; }
    public bool ExpectsEvidence { get; init; }

    public ReportingRule Rule(DateTime facilityEnd) => new(Frequency, AnchorKind, OffsetValue, OffsetUnit, FixedDueDate, FirstPeriodEnd, HorizonMonths ?? 24, ValidFrom,
        ValidTo is { } to && to < facilityEnd ? to : facilityEnd);
}

/// <summary>
/// The agenda of a facility (FR-OBL-003, BR-OBL-002 to 004; OQ-7): generated on the approval of a revision, inside its
/// transaction, and extended every night by JOB-OBL-CALENDAR. Only future SCHEDULED items change: a submitted,
/// waived or not-applicable item, and a scheduled one already past its due date, keep their dates; an item a rule no
/// longer has is CANCELLED with its reason; a due date the user moved (DueDateOverrideReason) stays. An event-based
/// item is created when its event is logged and follows the rule's offset while it is in the future.
/// </summary>
public static class ObligationStore
{
    private static string Valid(string a) => $"{a}.FromRevision <= @rev AND ({a}.ToRevision IS NULL OR {a}.ToRevision > @rev)";

    public static async Task<List<ReportingRuleRow>> RulesAsync(SqlConnection c, SqlTransaction? tx, long facility, int rev, CancellationToken ct) =>
        [.. await c.QueryAsync<ReportingRuleRow>(new CommandDefinition(
            $"""
            SELECT r.ReportingObligationId, r.RootId, o.ObligationId, o.RootId AS ObligationRootId, o.TitleAr, o.TitleEn, r.Frequency, r.AnchorKind, r.OffsetValue, r.OffsetUnit,
                   r.FixedDueDate, r.FirstPeriodEnd, r.HorizonMonths, r.AlertLeadDays, o.ValidFrom, o.ValidTo, o.Status, o.GraceDays, o.CureDays, r.ExpectsEvidence
              FROM obl.ReportingObligation AS r JOIN obl.Obligation AS o ON o.ObligationId = r.ObligationId
             WHERE o.FacilityId = @f AND {(rev == int.MaxValue ? "r.ToRevision IS NULL" : Valid("r"))};
            """, new { f = facility, rev }, tx, cancellationToken: ct)).ConfigureAwait(false)];

    /// <summary>The working days of the borrower's country, for the years around the agenda.</summary>
    public static async Task<(WorkingDays Days, int FiscalYearEndMonth, DateTime Expiry)> ContextAsync(SqlConnection c, SqlTransaction? tx, long facility, DateTime today,
        CancellationToken ct)
    {
        var x = await c.QuerySingleAsync<(int Country, int FyEnd, DateTime Expiry)>(new CommandDefinition(
            """
            SELECT co.CountryId, co.FiscalYearEndMonth, f.ExpiryDate FROM fac.Facility AS f JOIN org.Company AS co ON co.CompanyId = f.BorrowerCompanyId WHERE f.FacilityId = @f;
            """, new { f = facility }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var days = await WorkingCalendar.LoadAsync(c, tx, x.Country, DateOnly.FromDateTime(today.AddYears(-3)), DateOnly.FromDateTime(today.AddYears(4)), ct).ConfigureAwait(false);
        return (days, x.FyEnd, x.Expiry);
    }

    public static Func<DateTime, int, DateTime> Adder(WorkingDays days) => (d, n) => days.AddWorkingDays(DateOnly.FromDateTime(d), n).ToDateTime(TimeOnly.MinValue);

    private sealed class Instance
    {
        public long ReportingInstanceId { get; init; }
        public long ReportingObligationRootId { get; init; }
        public long ReportingObligationId { get; init; }
        public DateTime? PeriodEnd { get; init; }
        public DateTime? EventDate { get; init; }
        public DateTime DueDate { get; init; }
        public string Status { get; init; } = "";
        public string GeneratedBy { get; init; } = "";
        public string? DueDateOverrideReason { get; init; }
    }

    /// <summary>Brings the agenda of the facility in line with its rules at revision rev; returns how many items it added, moved or cancelled.</summary>
    public static async Task<int> GenerateAsync(SqlConnection c, SqlTransaction tx, long facility, int rev, DateTime today, CancellationToken ct)
    {
        var rules = (await RulesAsync(c, tx, facility, rev, ct).ConfigureAwait(false)).Where(r => r.Status == "ACTIVE").ToList();
        var (days, fyEnd, expiry) = await ContextAsync(c, tx, facility, today, ct).ConfigureAwait(false);
        var add = Adder(days);
        var existing = (await c.QueryAsync<Instance>(new CommandDefinition(
            """
            SELECT i.ReportingInstanceId, i.ReportingObligationRootId, i.ReportingObligationId, i.PeriodEnd, i.EventDate, i.DueDate, i.Status, i.GeneratedBy, i.DueDateOverrideReason
              FROM obl.ReportingInstance AS i
             WHERE i.Status <> 'CANCELLED' AND i.ReportingObligationRootId IN (SELECT r.RootId FROM obl.ReportingObligation AS r JOIN obl.Obligation AS o ON o.ObligationId = r.ObligationId
                                                                           WHERE o.FacilityId = @f);
            """, new { f = facility }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var changed = 0;
        bool Movable(Instance i) => i.Status == "SCHEDULED" && i.DueDate >= today.Date && i.DueDateOverrideReason is null;
        async Task CancelAsync(Instance i, string reason)
        {
            await c.ExecuteAsync(new CommandDefinition(
                "UPDATE obl.ReportingInstance SET Status = 'CANCELLED', StatusReason = @reason, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ReportingInstanceId = @id;",
                new { id = i.ReportingInstanceId, reason }, tx, cancellationToken: ct)).ConfigureAwait(false);
            changed++;
        }
        foreach (var rule in rules)
        {
            var mine = existing.Where(i => i.ReportingObligationRootId == rule.RootId).ToList();
            var generated = Agenda.Generate(rule.Rule(expiry), fyEnd, today, add);
            var kept = new HashSet<long>();
            foreach (var g in generated)
            {
                var e = mine.FirstOrDefault(i => i.GeneratedBy == "JOB" && (g.PeriodEnd is { } pe ? i.PeriodEnd == pe : i.PeriodEnd is null && i.EventDate is null && i.DueDate == g.DueDate));
                if (e is null)
                {
                    // A due date another (cancelled or kept) item of the rule already holds is not added twice.
                    if (g.PeriodEnd is null && mine.Any(i => i.PeriodEnd is null && i.EventDate is null && i.DueDate == g.DueDate)) continue;
                    await c.ExecuteAsync(new CommandDefinition(
                        """
                        INSERT obl.ReportingInstance (TenantId, ReportingObligationRootId, ReportingObligationId, PeriodStart, PeriodEnd, DueDate, Status, GeneratedBy, CreatedBy)
                        VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @root, @id, @ps, @pe, @due, 'SCHEDULED', 'JOB', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                        """, new { root = rule.RootId, id = rule.ReportingObligationId, ps = g.PeriodStart, pe = g.PeriodEnd, due = g.DueDate }, tx, cancellationToken: ct)).ConfigureAwait(false);
                    changed++;
                    continue;
                }
                kept.Add(e.ReportingInstanceId);
                if (Movable(e) && (e.DueDate != g.DueDate || e.ReportingObligationId != rule.ReportingObligationId))
                {
                    await c.ExecuteAsync(new CommandDefinition(
                        "UPDATE obl.ReportingInstance SET DueDate = @due, ReportingObligationId = @id, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ReportingInstanceId = @i;",
                        new { due = g.DueDate, id = rule.ReportingObligationId, i = e.ReportingInstanceId }, tx, cancellationToken: ct)).ConfigureAwait(false);
                    changed++;
                }
            }
            foreach (var e in mine.Where(i => i.GeneratedBy == "JOB" && !kept.Contains(i.ReportingInstanceId) && Movable(i)))
                await CancelAsync(e, "The rule no longer has this period (regenerated on approval).");
            // Logged events follow the rule's offset while they are in the future.
            foreach (var e in mine.Where(i => i.GeneratedBy == "MANUAL_EVENT" && i.EventDate is not null && Movable(i)))
            {
                var due = Agenda.ForEvent(rule.Rule(expiry), e.EventDate!.Value, add).DueDate;
                if (due == e.DueDate && e.ReportingObligationId == rule.ReportingObligationId) continue;
                await c.ExecuteAsync(new CommandDefinition(
                    "UPDATE obl.ReportingInstance SET DueDate = @due, ReportingObligationId = @id, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ReportingInstanceId = @i;",
                    new { due, id = rule.ReportingObligationId, i = e.ReportingInstanceId }, tx, cancellationToken: ct)).ConfigureAwait(false);
                changed++;
            }
        }
        // The future items of a rule the revision removed or suspended.
        var live = rules.Select(r => r.RootId).ToHashSet();
        foreach (var e in existing.Where(i => !live.Contains(i.ReportingObligationRootId) && Movable(i)))
            await CancelAsync(e, "The rule was removed or suspended by a revision.");
        return changed;
    }
}

/// <summary>JOB-OBL-CALENDAR: every night the agenda of each ACTIVE facility is extended to its horizon at its approved revision (OQ-7).</summary>
public sealed class ObligationCalendarJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-OBL-CALENDAR";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var facilities = (await c.QueryAsync<(long Id, int Rev)>(new CommandDefinition(
            "SELECT FacilityId, ApprovedRevisionNo FROM fac.Facility WHERE LifecycleStatus = 'ACTIVE' AND ApprovedRevisionNo >= 1;", cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var n = 0;
        foreach (var (id, rev) in facilities)
        {
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            n += await ObligationStore.GenerateAsync(c, tx, id, rev, today, ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        return n == 0 ? null : $"agenda items {n}";
    }
}

/// <summary>
/// OBL_DUE (CORE.EXPIRY v3; NTF-OBL-01, 02): a SCHEDULED agenda item of an ACTIVE facility, at its rule's lead days
/// (ReportingObligation.AlertLeadDays) or the rule's; OBL.DUE before and on the due date, OBL.OVERDUE from the day
/// after and every day while it stays open (the rule's reminder of 1 day).
/// </summary>
internal sealed class ObligationExpiry : IExpiryItemProvider
{
    public string ItemType => "OBL_DUE";
    public string EventCode => "OBL.DUE";
    public string TargetType => "obl.ReportingInstance";
    public string EventCodeFor(string kind) => kind == "LEAD" ? "OBL.DUE" : "OBL.OVERDUE";
    public bool ValidThroughExpiryDate => true;
    public bool ExpiredFromNextDay => true;

    private sealed class Row
    {
        public long Id { get; init; }
        public DateTime ExpiryDate { get; init; }
        public long CompanyId { get; init; }
        public string FacilityNo { get; init; } = "";
        public string TitleAr { get; init; } = "";
        public string? TitleEn { get; init; }
        public string? AlertLeadDays { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string? BankNameAr { get; init; }
        public string? BankNameEn { get; init; }
    }

    public async Task<IReadOnlyList<ExpiryItem>> ItemsAsync(SqlConnection c, DateTime today, DateTime horizon, CancellationToken ct) =>
        [.. (await c.QueryAsync<Row>(new CommandDefinition(
            """
            SELECT i.ReportingInstanceId AS Id, i.DueDate AS ExpiryDate, f.BorrowerCompanyId AS CompanyId, f.FacilityNo, o.TitleAr, o.TitleEn, r.AlertLeadDays,
                   co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn, b.NameAr AS BankNameAr, b.NameEn AS BankNameEn
              FROM obl.ReportingInstance AS i
              JOIN obl.ReportingObligation AS r ON r.ReportingObligationId = i.ReportingObligationId
              JOIN obl.Obligation AS o ON o.ObligationId = r.ObligationId
              JOIN fac.Facility AS f ON f.FacilityId = o.FacilityId
              JOIN org.Company AS co ON co.CompanyId = f.BorrowerCompanyId
              OUTER APPLY (SELECT TOP (1) x.NameAr, x.NameEn FROM fac.FacilityLender AS l JOIN ins.Institution AS x ON x.InstitutionId = l.InstitutionId
                            WHERE l.FacilityId = f.FacilityId AND l.FromRevision <= f.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo)
                            ORDER BY CASE WHEN l.Roles LIKE '%AGENT%' OR l.Roles LIKE '%SOLE%' THEN 0 WHEN l.Roles LIKE '%LEAD%' THEN 1 ELSE 2 END, l.SharePct DESC) AS b
             WHERE i.Status = 'SCHEDULED' AND i.DueDate <= @h AND f.LifecycleStatus = 'ACTIVE' AND r.Direction = 'WE_SUBMIT';
            """, new { h = horizon }, cancellationToken: ct)).ConfigureAwait(false))
            .Select(r => new ExpiryItem(r.Id, r.ExpiryDate, r.CompanyId, new Dictionary<string, object?>
            {
                ["facilityNo"] = r.FacilityNo,
                ["obligationTitle"] = ExpiryItemProviders.Text(r.TitleAr, r.TitleEn),
                ["companyName"] = ExpiryItemProviders.Text(r.CompanyNameAr, r.CompanyNameEn),
                ["bankName"] = ExpiryItemProviders.Text(r.BankNameAr, r.BankNameEn),
            }, LeadDays: r.AlertLeadDays is { Length: > 0 } own ? [.. own.Split(',', StringSplitOptions.RemoveEmptyEntries).Select(x => int.Parse(x, CultureInfo.InvariantCulture))] : null))];
}

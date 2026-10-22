using System.Data;
using System.Globalization;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record HoldingInput(Guid? Holder, decimal? SharePercent, decimal? SharesCount, decimal? NominalValue, string? Currency, int? Layer,
    Guid? Intermediate, bool? IsBeneficialOwner);
public sealed record OwnershipChangeRequest(string? EffectiveFrom, List<HoldingInput>? Holdings, Guid? SourceDocument, bool? Retroactive, string? Reason,
    bool? DryRun);

/// <summary>
/// Ownership of a company (FR-ORG-015 to 018, BR-ORG-006 to 008; screens 14 and 15 of spec 10). A change is the whole
/// distribution from a date, written by one wizard in one transaction: the rows in force on that date close the day
/// before and the new ones open, up to the next change already recorded (so a retroactive correction fills its own
/// period and leaves the later ones as they are). Rows are never deleted. The direct holdings (Layer 1) total exactly
/// 100.000000 on the date; the indirect paths (Layer 2 and up) name the external intermediate that holds the company
/// directly, and their share is the holder's effective share through that path (owner default OQ-1). The effective
/// ownership follows the tenant's own companies through their mirror parties and stops at a cycle with a warning.
/// </summary>
public static class OwnershipEndpoints
{
    private const string View = "org.company.view";
    private const string Manage = "org.ownership.manage";
    private static readonly string[] Retro = ["RETROACTIVE"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/companies/{id:guid}/ownership", GetAsync);
        api.MapPost("/companies/{id:guid}/ownership/changes", ChangeAsync);
        api.MapGet("/companies/{id:guid}/ownership/effective", EffectiveAsync);
        api.MapGet("/reports/ownership-mismatch", MismatchAsync);
    }

    internal sealed class HoldingRow
    {
        public long ShareholdingId { get; init; }
        public long HolderPartyId { get; init; }
        public Guid HolderId { get; init; }
        public string HolderCode { get; init; } = "";
        public string HolderNameAr { get; init; } = "";
        public string? HolderNameEn { get; init; }
        public string HolderKind { get; init; } = "";
        public Guid? HolderCompany { get; init; }
        public decimal SharePercent { get; init; }
        public decimal? SharesCount { get; init; }
        public decimal? NominalValue { get; init; }
        public string? Currency { get; init; }
        public byte Layer { get; init; }
        public long? IntermediatePartyId { get; init; }
        public Guid? IntermediateId { get; init; }
        public string? IntermediateNameAr { get; init; }
        public string? IntermediateNameEn { get; init; }
        public bool IsBeneficialOwner { get; init; }
        public DateTime EffectiveFrom { get; init; }
        public DateTime? EffectiveTo { get; init; }
        public Guid? SourceDocument { get; init; }
    }

    private const string Select =
        """
        SELECT s.ShareholdingId, s.HolderPartyId, h.PublicId AS HolderId, h.PartyCode AS HolderCode, h.NameAr AS HolderNameAr, h.NameEn AS HolderNameEn,
               h.Kind AS HolderKind, hc.PublicId AS HolderCompany, s.SharePercent, s.SharesCount, s.NominalValue, cu.Code AS Currency, s.Layer,
               s.IntermediatePartyId, m.PublicId AS IntermediateId, m.NameAr AS IntermediateNameAr, m.NameEn AS IntermediateNameEn, s.IsBeneficialOwner,
               s.EffectiveFrom, s.EffectiveTo, d.PublicId AS SourceDocument
          FROM org.Shareholding AS s
          JOIN pty.Party AS h ON h.PartyId = s.HolderPartyId
          LEFT JOIN org.Company AS hc ON hc.PartyId = s.HolderPartyId
          LEFT JOIN pty.Party AS m ON m.PartyId = s.IntermediatePartyId
          LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = s.CurrencyId
          LEFT JOIN doc.Document AS d ON d.DocumentId = s.SourceDocumentId
        """;

    private static string D(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static DateTime Today(TimeProvider clock) => clock.GetUtcNow().UtcDateTime.Date;

    private static DateTime AsOf(HttpRequest r, TimeProvider clock) =>
        r.Query["asOf"].ToString() is { Length: > 0 } text
            ? DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
              : throw ApiProblemException.Invalid("VALIDATION_FAILED", "asOf is a date YYYY-MM-DD.")
            : Today(clock);

    private static bool InForce(HoldingRow r, DateTime d) => r.EffectiveFrom <= d && (r.EffectiveTo is null || r.EffectiveTo >= d);

    private static object Shape(HoldingRow r) => new
    {
        holder = new { id = r.HolderId, code = r.HolderCode, nameAr = r.HolderNameAr, nameEn = r.HolderNameEn, kind = r.HolderKind, company = r.HolderCompany },
        sharePercent = r.SharePercent, sharesCount = r.SharesCount, nominalValue = r.NominalValue, currency = r.Currency, layer = r.Layer,
        intermediate = r.IntermediateId is null ? null : new { id = r.IntermediateId, nameAr = r.IntermediateNameAr, nameEn = r.IntermediateNameEn },
        isBeneficialOwner = r.IsBeneficialOwner, effectiveFrom = D(r.EffectiveFrom), effectiveTo = r.EffectiveTo is { } t ? D(t) : null,
        sourceDocument = r.SourceDocument,
    };

    internal static async Task<List<HoldingRow>> RowsAsync(SqlConnection c, SqlTransaction? tx, long companyId, CancellationToken ct) =>
        [.. await c.QueryAsync<HoldingRow>(new CommandDefinition(Select + " WHERE s.CompanyId = @c ORDER BY s.EffectiveFrom, s.Layer, h.PartyCode;",
            new { c = companyId }, tx, cancellationToken: ct))];

    /// <summary>The direct holdings in force on the date, to six places (BR-ORG-006).</summary>
    internal static decimal Total(IEnumerable<HoldingRow> rows, DateTime d) => rows.Where(r => r.Layer == 1 && InForce(r, d)).Sum(r => r.SharePercent);

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "asOf");
        var asOf = AsOf(http.Request, clock);
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var company = await CompanyEndpoints.FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var rows = await RowsAsync(u.Connection, null, company.CompanyId, http.RequestAborted);
        var total = Total(rows, asOf);
        return Results.Ok(new
        {
            asOf = D(asOf), total, difference = 100m - total, status = company.OwnershipStatus,
            current = rows.Where(r => InForce(r, asOf)).Select(Shape),
            planned = rows.Where(r => r.EffectiveFrom > asOf).Select(Shape),
            history = rows.Where(r => r.EffectiveTo < asOf).Select(Shape),
        });
    }

    private sealed record Party(long PartyId, Guid PublicId, string Kind, bool IsActive, long? CompanyId);

    private static async Task<Party> PartyAsync(BoundUser u, SqlTransaction tx, Guid id, CancellationToken ct) =>
        await u.Connection.QuerySingleOrDefaultAsync<Party>(new CommandDefinition(
            "SELECT p.PartyId, p.PublicId, p.Kind, p.IsActive, c.CompanyId FROM pty.Party AS p LEFT JOIN org.Company AS c ON c.PartyId = p.PartyId WHERE p.PublicId = @id;",
            new { id }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.Invalid("V-ORG-OWN-PARTY", "A holder or an intermediate is not a known party.");

    private sealed record NewRow(long HolderId, decimal Percent, decimal? Shares, decimal? Nominal, int? CurrencyId, int Layer, long? IntermediateId, bool Beneficial);

    /// <summary>
    /// The wizard (FR-ORG-015): the new distribution from EffectiveFrom. With dryRun it checks and answers what it would
    /// write, without writing. An earlier date than the last change is a retroactive correction: it needs the flag and a
    /// reason, and is audited HIGH (BR-ORG-007, owner default OQ-2).
    /// </summary>
    private static async Task<IResult> ChangeAsync(Guid id, OwnershipChangeRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        if (!DateTime.TryParseExact(b.EffectiveFrom, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var from))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The effective date is a date YYYY-MM-DD.");
        if (b.Holdings is not { Count: > 0 }) throw ApiProblemException.Invalid("VALIDATION_FAILED", "List the holders from that date.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, http.RequestAborted);
        var company = await CompanyEndpoints.FindAsync(u, tx, id, scope, http.RequestAborted);
        if (company.Status == "ARCHIVED") throw new ApiProblemException(409, "V-ORG-ARCHIVED", "The company is archived.");
        var rows = await RowsAsync(u.Connection, tx, company.CompanyId, http.RequestAborted);

        // The date: after the last change, or a correction of an earlier period.
        if (rows.Any(r => r.EffectiveFrom == from))
            throw new ApiProblemException(409, "V-ORG-OWN-SAME-DATE", "A change already starts on this date; choose another date.");
        var last = rows.Count == 0 ? (DateTime?)null : rows.Max(r => r.EffectiveFrom);
        var retroactive = last is { } l && from < l;
        if (retroactive && b.Retroactive != true)
            throw ApiProblemException.Invalid("V-ORG-OWN-DATE", $"The date is before the last change ({D(last!.Value)}); a correction of an earlier period is marked retroactive with its reason.");
        if (retroactive && string.IsNullOrWhiteSpace(b.Reason)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason of the retroactive correction.");

        // The new rows.
        var resolved = new List<(HoldingInput In, Party Holder, Party? Intermediate, int Layer, int? CurrencyId)>();
        foreach (var h in b.Holdings)
        {
            if (h.Holder is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Each line names its holder.");
            var holder = await PartyAsync(u, tx, h.Holder.Value, http.RequestAborted);
            if (!holder.IsActive) throw ApiProblemException.Invalid("V-ORG-OWN-PARTY", "A holder is not an active party.");
            if (holder.PartyId == company.PartyId) throw ApiProblemException.Invalid("V-ORG-OWN-SELF", "A company does not hold itself.");
            var layer = h.Layer ?? 1;
            if (layer < 1 || layer > 9) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The layer is 1 for a direct holder, 2 to 9 for an indirect path.");
            Party? via = null;
            if (layer >= 2)
            {
                if (h.Intermediate is null) throw ApiProblemException.Invalid("V-ORG-OWN-PATH", "An indirect path names the intermediate that holds the company directly.");
                via = await PartyAsync(u, tx, h.Intermediate.Value, http.RequestAborted);
                if (via.CompanyId is not null)
                    throw ApiProblemException.Invalid("V-ORG-OWN-PATH", "A path through a company of the account follows from that company's own holdings; record its holders there (BR-ORG-008).");
                if (via.PartyId == holder.PartyId) throw ApiProblemException.Invalid("V-ORG-OWN-PATH", "The intermediate is not the holder itself.");
            }
            else if (h.Intermediate is not null) throw ApiProblemException.Invalid("V-ORG-OWN-PATH", "A direct holder has no intermediate.");
            int? currency = null;
            if (h.NominalValue is not null)
            {
                if (h.NominalValue < 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The nominal value is not negative.");
                currency = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @c;",
                    new { c = h.Currency?.ToUpperInvariant() }, tx, cancellationToken: http.RequestAborted))
                    ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The nominal value needs its currency.");
            }
            if (h.SharesCount is <= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The number of shares is positive.");
            resolved.Add((h, holder, via, layer, currency));
        }
        if (resolved.GroupBy(r => (r.Holder.PartyId, r.Layer, r.Intermediate?.PartyId)).Any(g => g.Count() > 1))
            throw ApiProblemException.Invalid("V-ORG-OWN-DUP", "A holder appears twice on the same path.");
        var direct = resolved.Where(r => r.Layer == 1).ToList();
        if (direct.Count == 0) throw ApiProblemException.Invalid("V-ORG-OWN-TOTAL", "The direct holders total 0%, a difference of 100%.");

        // Shares give the percentages when every direct holder has them and none has a percentage (BR-ORG-006).
        var percents = new Dictionary<int, decimal>();
        if (direct.All(r => r.In.SharesCount is > 0 && r.In.SharePercent is null))
        {
            var totalShares = direct.Sum(r => r.In.SharesCount!.Value);
            foreach (var r in direct) percents[resolved.IndexOf(r)] = Math.Round(r.In.SharesCount!.Value * 100m / totalShares, 6, MidpointRounding.ToEven);
            var largest = direct.OrderByDescending(r => r.In.SharesCount).First();
            percents[resolved.IndexOf(largest)] += 100m - percents.Values.Sum();
        }
        var lines = new List<NewRow>();
        for (var i = 0; i < resolved.Count; i++)
        {
            var r = resolved[i];
            var pct = percents.TryGetValue(i, out var p) ? p : r.In.SharePercent
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Each line has its percentage, or every direct holder its number of shares.");
            if (pct <= 0 || pct > 100 || decimal.Round(pct, 6) != pct)
                throw ApiProblemException.Invalid("VALIDATION_FAILED", "A percentage is above 0 and at most 100, to six decimal places.");
            lines.Add(new NewRow(r.Holder.PartyId, pct, r.In.SharesCount, r.In.NominalValue, r.CurrencyId, r.Layer, r.Intermediate?.PartyId, r.In.IsBeneficialOwner ?? false));
        }
        var total = lines.Where(x => x.Layer == 1).Sum(x => x.Percent);
        if (total != 100m)
            throw ApiProblemException.Invalid("V-ORG-OWN-TOTAL",
                $"The direct holders total {total.ToString("0.######", CultureInfo.InvariantCulture)}%, a difference of {(100m - total).ToString("0.######", CultureInfo.InvariantCulture)}%.");

        long? sourceId = null;
        if (b.SourceDocument is { } docId)
            sourceId = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE' AND (OwnerCompanyId IS NULL OR OwnerCompanyId = @c);",
                new { d = docId, c = company.CompanyId }, tx, cancellationToken: http.RequestAborted))
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The source document is not an active document of this company.");

        // The period of the change: up to the next change already recorded.
        var next = rows.Where(r => r.EffectiveFrom > from).Select(r => (DateTime?)r.EffectiveFrom).Min();
        var until = next?.AddDays(-1);
        var closing = rows.Where(r => InForce(r, from)).ToList();
        var plan = new
        {
            effectiveFrom = D(from), effectiveTo = until is { } t ? D(t) : null, retroactive, total,
            closes = closing.Select(r => new { holder = r.HolderCode, layer = r.Layer, effectiveFrom = D(r.EffectiveFrom), closesOn = D(from.AddDays(-1)) }),
            opens = lines.Count,
        };
        if (b.DryRun == true)
        {
            await tx.RollbackAsync(http.RequestAborted);
            return Results.Ok(new { dryRun = true, plan });
        }

        foreach (var r in closing)
        {
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE org.Shareholding SET EffectiveTo = @to, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE ShareholdingId = @id;
                """, new { id = r.ShareholdingId, to = from.AddDays(-1) }, tx, cancellationToken: http.RequestAborted));
            // A row that ran past the next change keeps its later part (rows written by this wizard always end before it).
            if (next is { } n && (r.EffectiveTo is null || r.EffectiveTo >= n))
                await u.Connection.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT org.Shareholding (TenantId, CompanyId, HolderPartyId, SharePercent, SharesCount, NominalValue, CurrencyId, Layer, IntermediatePartyId,
                                             IsBeneficialOwner, EffectiveFrom, EffectiveTo, SourceDocumentId, CreatedBy)
                    SELECT TenantId, CompanyId, HolderPartyId, SharePercent, SharesCount, NominalValue, CurrencyId, Layer, IntermediatePartyId, IsBeneficialOwner,
                           @n, @to, SourceDocumentId, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                      FROM org.Shareholding WHERE ShareholdingId = @id;
                    """, new { id = r.ShareholdingId, n, to = r.EffectiveTo }, tx, cancellationToken: http.RequestAborted));
        }
        foreach (var x in lines)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT org.Shareholding (TenantId, CompanyId, HolderPartyId, SharePercent, SharesCount, NominalValue, CurrencyId, Layer, IntermediatePartyId,
                                         IsBeneficialOwner, EffectiveFrom, EffectiveTo, SourceDocumentId, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @h, @p, @s, @nv, @cur, @l, @m, @bo, @from, @until, @doc, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """, new { c = company.CompanyId, h = x.HolderId, p = x.Percent, s = x.Shares, nv = x.Nominal, cur = x.CurrencyId, l = x.Layer, m = x.IntermediateId,
                    bo = x.Beneficial, from, until, doc = sourceId }, tx, cancellationToken: http.RequestAborted));

        var today = Today(clock);
        var status = await StatusAsync(u.Connection, tx, company.CompanyId, today, http.RequestAborted);
        await Outbox.EmitAsync(u.Connection, tx, "ownership.changed", "org.Company", company.CompanyId,
            new { company = company.PublicId, effectiveFrom = D(from), retroactive }, http.RequestAborted);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(retroactive ? "OWNERSHIP_CORRECTED" : "OWNERSHIP_CHANGED", "TREASURY", "org.Company", company.CompanyId,
            BeforeJson: JsonSerializer.Serialize(closing.Select(r => new { holder = r.HolderCode, r.Layer, r.SharePercent, from = D(r.EffectiveFrom) })),
            AfterJson: JsonSerializer.Serialize(new { from = D(from), until = until is { } ut ? D(ut) : null, lines = lines.Count, total, reason = b.Reason?.Trim() }),
            Severity: retroactive ? "HIGH" : "INFO"), company.CompanyId, http.RequestAborted);
        if (status.Total != 100m && status.HasRows) await MismatchNoticeAsync(u.Connection, tx, company.CompanyId, status.Total, today, u.UserId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Ok(new { dryRun = false, plan, ownershipStatus = status.Status, flags = retroactive ? Retro : [] });
    }

    /// <summary>OwnershipStatus from today's direct total: COMPLETE at exactly 100%, otherwise UNDOCUMENTED (FR-ORG-016).</summary>
    internal static async Task<(string Status, decimal Total, bool HasRows)> StatusAsync(SqlConnection c, SqlTransaction tx, long companyId, DateTime today, CancellationToken ct)
    {
        var (total, rows) = await c.QuerySingleAsync<(decimal, int)>(new CommandDefinition(
            """
            SELECT ISNULL(SUM(CASE WHEN Layer = 1 AND EffectiveFrom <= @d AND (EffectiveTo IS NULL OR EffectiveTo >= @d) THEN SharePercent END), 0), COUNT(*)
              FROM org.Shareholding WHERE CompanyId = @c;
            """, new { c = companyId, d = today }, tx, cancellationToken: ct));
        var status = total == 100m ? "COMPLETE" : "UNDOCUMENTED";
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE org.Company SET OwnershipStatus = @s, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CompanyId = @c AND OwnershipStatus <> @s;
            """, new { c = companyId, s = status }, tx, cancellationToken: ct));
        return (status, total, rows > 0);
    }

    /// <summary>OWN.TOTAL_MISMATCH to TM and FO of the company, once a day (spec 13 section 9.2).</summary>
    internal static async Task MismatchNoticeAsync(SqlConnection c, SqlTransaction tx, long companyId, decimal total, DateTime today, long? actor, CancellationToken ct)
    {
        var (ar, en) = await c.QuerySingleAsync<(string, string?)>(new CommandDefinition("SELECT NameAr, NameEn FROM org.Company WHERE CompanyId = @c;",
            new { c = companyId }, tx, cancellationToken: ct));
        await Notifier.RequestAsync(c, tx, new NotificationRequest("OWN.TOTAL_MISMATCH", "org.Company", companyId, $"OWN.TOTAL_MISMATCH:{companyId}:{today:yyyyMMdd}",
            companyId, new Dictionary<string, object?>
            {
                ["companyName"] = new Dictionary<string, string?> { ["ar"] = ar ?? en, ["en"] = en ?? ar },
                ["totalPercent"] = total.ToString("0.######", CultureInfo.InvariantCulture),
            }, DeepLink: null, ActorUserId: actor), ct);
    }

    /// <summary>
    /// Effective ownership on a date (FR-ORG-018, BR-ORG-008): the sum over every path of the products of the shares. A
    /// holder that is a company of the account is followed through its own holdings; the indirect paths recorded on a
    /// company (Layer 2 and up) add their effective share. A cycle is not followed and is reported.
    /// </summary>
    private static async Task<IResult> EffectiveAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "asOf");
        var asOf = AsOf(http.Request, clock);
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var company = await CompanyEndpoints.FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var holdings = (await u.Connection.QueryAsync<HoldingRow>(new CommandDefinition(Select + " WHERE s.EffectiveFrom <= @d AND (s.EffectiveTo IS NULL OR s.EffectiveTo >= @d);", new { d = asOf }, cancellationToken: http.RequestAborted))).ToList();
        var byCompany = (await u.Connection.QueryAsync<(long CompanyId, long ShareholdingId)>(new CommandDefinition(
            "SELECT CompanyId, ShareholdingId FROM org.Shareholding WHERE EffectiveFrom <= @d AND (EffectiveTo IS NULL OR EffectiveTo >= @d);",
            new { d = asOf }, cancellationToken: http.RequestAborted))).ToLookup(x => x.CompanyId, x => x.ShareholdingId);
        var byId = holdings.ToDictionary(h => h.ShareholdingId);
        var companyOfParty = (await u.Connection.QueryAsync<(long PartyId, long CompanyId)>(new CommandDefinition(
            "SELECT PartyId, CompanyId FROM org.Company;", cancellationToken: http.RequestAborted))).ToDictionary(x => x.PartyId, x => x.CompanyId);

        var result = new Dictionary<long, (HoldingRow Holder, decimal Pct, bool Direct, bool Indirect)>();
        var cycles = new List<string>();
        void Walk(long companyId, decimal weight, HashSet<long> path, int depth)
        {
            foreach (var hid in byCompany[companyId])
            {
                var h = byId[hid];
                var share = weight * h.SharePercent / 100m;
                var throughCompany = depth > 0 || h.Layer >= 2;
                result[h.HolderPartyId] = result.TryGetValue(h.HolderPartyId, out var had)
                    ? (had.Holder, had.Pct + share, had.Direct || !throughCompany, had.Indirect || throughCompany)
                    : (h, share, !throughCompany, throughCompany);
                if (h.Layer == 1 && companyOfParty.TryGetValue(h.HolderPartyId, out var owner))
                {
                    if (path.Contains(owner)) { cycles.Add(h.HolderCode); continue; }
                    Walk(owner, share, [.. path, owner], depth + 1);
                }
            }
        }
        Walk(company.CompanyId, 100m, [company.CompanyId], 0);
        return Results.Ok(new
        {
            asOf = D(asOf),
            items = result.Values.OrderByDescending(x => x.Pct).Select(x => new
            {
                holder = new { id = x.Holder.HolderId, code = x.Holder.HolderCode, nameAr = x.Holder.HolderNameAr, nameEn = x.Holder.HolderNameEn, kind = x.Holder.HolderKind,
                    company = x.Holder.HolderCompany },
                effectivePercent = Math.Round(x.Pct, 6), direct = x.Direct, indirect = x.Indirect,
                // A suggestion only: the user confirms a beneficial owner (owner default OQ-18).
                suggestBeneficialOwner = x.Holder.HolderKind == "INDIVIDUAL" && x.Pct >= 25m,
            }),
            warnings = cycles.Distinct().Select(c => $"A cycle of ownership through {c} is not followed."),
        });
    }

    /// <summary>The companies whose direct holdings do not total 100% on the date (FR-ORG-016), within the user's scope.</summary>
    private static async Task<IResult> MismatchAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "asOf");
        var asOf = AsOf(http.Request, clock);
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var rows = await u.Connection.QueryAsync<(Guid Id, string Code, string NameAr, string? NameEn, decimal Total, int Rows)>(new CommandDefinition(
            """
            SELECT c.PublicId, c.CompanyCode, c.NameAr, c.NameEn,
                   ISNULL(SUM(CASE WHEN s.Layer = 1 AND s.EffectiveFrom <= @d AND (s.EffectiveTo IS NULL OR s.EffectiveTo >= @d) THEN s.SharePercent END), 0),
                   COUNT(s.ShareholdingId)
              FROM org.Company AS c LEFT JOIN org.Shareholding AS s ON s.CompanyId = c.CompanyId
             WHERE c.Status = 'ACTIVE' AND (@all = 1 OR c.CompanyId IN @ids)
             GROUP BY c.PublicId, c.CompanyCode, c.NameAr, c.NameEn
            HAVING ISNULL(SUM(CASE WHEN s.Layer = 1 AND s.EffectiveFrom <= @d AND (s.EffectiveTo IS NULL OR s.EffectiveTo >= @d) THEN s.SharePercent END), 0) <> 100
             ORDER BY c.CompanyCode;
            """, new { d = asOf, all = scope.All, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            asOf = D(asOf),
            items = rows.Select(r => new { company = r.Id, code = r.Code, nameAr = r.NameAr, nameEn = r.NameEn, total = r.Total, difference = 100m - r.Total, recorded = r.Rows > 0 }),
        });
    }
}

using System.Security.Cryptography;
using System.Text;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Governance;

/// <summary>
/// The governance comparison (FR-ACC-018, BR-ACC-015; owner defaults OQ-7, OQ-8, OQ-9): each open bank authority of a
/// signatory against the governance grants of the person in the relationship's company. The candidates are the ACTIVE
/// grants (a draft or a pending grant never counts) to the person alone or as a member (or as the natural representative
/// of a member entity), for a power type linked to the operation, unrestricted or restricted to the relationship's bank;
/// a body's grant is never a person's. One candidate that covers the authority is enough. Otherwise the codes of the best
/// candidate are recorded, the best being the one whose most severe code is the least severe, in the order NOT_MAPPED,
/// NO_GRANT, GRANT_EXPIRED, NOT_COMPARABLE_CURRENCY, GRANT_CEILING_UNSPECIFIED, CEILING_EXCEEDS, JOINT_MISMATCH. There is
/// no conversion between currencies. The fingerprint is the SHA-256 of the authority and its version, the candidates and
/// their versions, and the code, so a change of either side opens a new row; a cause that is gone resolves its rows. The
/// save of an authority is never refused: a conflict is a warning with a recorded decision (Q-ACC-06).
/// </summary>
public static class GovernanceComparer
{
    public static readonly string[] Severity =
        ["NOT_MAPPED", "NO_GRANT", "GRANT_EXPIRED", "NOT_COMPARABLE_CURRENCY", "GRANT_CEILING_UNSPECIFIED", "CEILING_EXCEEDS", "JOINT_MISMATCH"];

    private sealed class AuthorityRow
    {
        public long SignatoryAuthorityId { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public long CompanyId { get; init; }
        public long InstitutionId { get; init; }
        public long PartyId { get; init; }
        public int OperationTypeId { get; init; }
        public string CeilingMode { get; init; } = "";
        public decimal? MaxPerTransaction { get; init; }
        public decimal? DailyLimit { get; init; }
        public string? Currency { get; init; }
        public bool IsJoint { get; init; }
        public bool Open { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string? PartyNameAr { get; init; }
        public string? PartyNameEn { get; init; }
        public string? InstitutionNameAr { get; init; }
        public string? InstitutionNameEn { get; init; }
        public string? OperationAr { get; init; }
        public string? OperationEn { get; init; }
    }

    private sealed class Candidate
    {
        public long AuthorityGrantId { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public long CompanyId { get; init; }
        public long HolderPartyId { get; init; }
        public long? RepresentativeId { get; init; }
        public int PowerTypeId { get; init; }
        public long? InstitutionId { get; init; }
        public decimal? CeilingAmount { get; init; }
        public string? CeilingCurrency { get; init; }
        public bool RequiresJoint { get; init; }
        public DateTime ValidFrom { get; init; }
        public DateTime? ValidTo { get; init; }
        public string GranteeKind { get; init; } = "";
        public DateTime? MemberStart { get; init; }
        public DateTime? MemberEnd { get; init; }
        public DateTime? MemberResigned { get; init; }
    }

    public sealed record Finding(long AuthorityId, string Code, string Fingerprint, long? GrantId);

    /// <summary>The conflicts of one authority on the date; empty when a candidate covers it.</summary>
    private static List<Finding> Compare(AuthorityRow a, IReadOnlyCollection<int> powers, IReadOnlyList<Candidate> all, DateTime on)
    {
        if (powers.Count == 0) return [Make(a, [], "NOT_MAPPED", null)];
        var mine = all.Where(g => g.CompanyId == a.CompanyId && powers.Contains(g.PowerTypeId) && (g.InstitutionId is null || g.InstitutionId == a.InstitutionId)
                                  && (g.HolderPartyId == a.PartyId || g.RepresentativeId == a.PartyId)).ToList();
        if (mine.Count == 0) return [Make(a, mine, "NO_GRANT", null)];
        var valid = mine.Where(g => g.ValidFrom <= on && (g.ValidTo is null || g.ValidTo >= on)
                                    && (g.GranteeKind != "BODY_MEMBER" || (g.MemberStart <= on && (g.MemberEnd is null || g.MemberEnd >= on) && (g.MemberResigned is null || g.MemberResigned > on))))
            .ToList();
        if (valid.Count == 0) return [Make(a, mine, "GRANT_EXPIRED", mine.OrderByDescending(g => g.ValidTo).First().AuthorityGrantId)];
        var amount = a.CeilingMode == "LIMITED" ? a.MaxPerTransaction ?? a.DailyLimit : null;
        List<string>? best = null;
        Candidate? bestGrant = null;
        foreach (var g in valid)
        {
            var codes = new List<string>();
            if (g.CeilingAmount is null)
            {
                if (a.CeilingMode != "UNSPECIFIED") codes.Add("GRANT_CEILING_UNSPECIFIED");
            }
            else if (a.CeilingMode == "UNLIMITED") codes.Add("CEILING_EXCEEDS");
            else if (a.CeilingMode == "LIMITED")
            {
                if (!string.Equals(a.Currency, g.CeilingCurrency, StringComparison.Ordinal)) codes.Add("NOT_COMPARABLE_CURRENCY");
                else if (amount > g.CeilingAmount) codes.Add("CEILING_EXCEEDS");
            }
            if (g.RequiresJoint && !a.IsJoint) codes.Add("JOINT_MISMATCH");
            if (codes.Count == 0) return [];
            if (best is null || codes.Min(Rank) > best.Min(Rank) || (codes.Min(Rank) == best.Min(Rank) && codes.Count < best.Count))
            {
                best = codes;
                bestGrant = g;
            }
        }
        return [.. best!.OrderBy(Rank).Select(code => Make(a, mine, code, bestGrant!.AuthorityGrantId))];
    }

    private static int Rank(string code) => Array.IndexOf(Severity, code);

    private static Finding Make(AuthorityRow a, IEnumerable<Candidate> candidates, string code, long? grant)
    {
        var text = new StringBuilder();
        text.Append(a.SignatoryAuthorityId).Append('|').Append(Convert.ToHexString(a.RowVersion));
        foreach (var g in candidates.OrderBy(g => g.AuthorityGrantId)) text.Append('|').Append(g.AuthorityGrantId).Append(':').Append(Convert.ToHexString(g.RowVersion));
        text.Append('|').Append(code);
        return new Finding(a.SignatoryAuthorityId, code, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString()))).ToLowerInvariant(), grant);
    }

    /// <summary>
    /// Compares the authorities of a company (or of one signatory) and brings acc.AuthorityConflict in line: new findings
    /// are OPEN and notified (ACC.GOV_CONFLICT), open or acknowledged rows whose cause is gone are RESOLVED. Returns the
    /// conflicts now open or acknowledged of the authorities compared.
    /// </summary>
    public static async Task<(int Opened, int Resolved, IReadOnlyList<Finding> Current)> ReconcileAsync(SqlConnection c, SqlTransaction tx, long? companyId, long? signatoryId,
        DateTime today, long? actor, CancellationToken ct)
    {
        var authorities = (await c.QueryAsync<AuthorityRow>(new CommandDefinition(
            """
            SELECT a.SignatoryAuthorityId, a.RowVersion, r.CompanyId, r.InstitutionId, s.PartyId, a.OperationTypeId, a.CeilingMode, a.MaxPerTransaction, a.DailyLimit,
                   cu.Code AS Currency, a.IsJoint,
                   CAST(CASE WHEN a.SupersededById IS NULL AND (a.ValidTo IS NULL OR a.ValidTo >= @d) AND s.Status IN ('PENDING', 'ACTIVE', 'SUSPENDED') THEN 1 ELSE 0 END AS BIT) AS [Open],
                   co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn, p.NameAr AS PartyNameAr, p.NameEn AS PartyNameEn, i.NameAr AS InstitutionNameAr,
                   i.NameEn AS InstitutionNameEn, o.NameAr AS OperationAr, o.NameEn AS OperationEn
              FROM acc.SignatoryAuthority AS a JOIN acc.Signatory AS s ON s.SignatoryId = a.SignatoryId JOIN ins.Relationship AS r ON r.RelationshipId = a.RelationshipId
              JOIN org.Company AS co ON co.CompanyId = r.CompanyId JOIN ins.Institution AS i ON i.InstitutionId = r.InstitutionId JOIN pty.Party AS p ON p.PartyId = s.PartyId
              JOIN cat.OperationType AS o ON o.OperationTypeId = a.OperationTypeId LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = a.CurrencyId
             WHERE (@c IS NULL OR r.CompanyId = @c) AND (@s IS NULL OR a.SignatoryId = @s)
               AND (a.SupersededById IS NULL AND (a.ValidTo IS NULL OR a.ValidTo >= @d)
                    OR EXISTS (SELECT 1 FROM acc.AuthorityConflict AS x WHERE x.SignatoryAuthorityId = a.SignatoryAuthorityId AND x.Status <> 'RESOLVED'));
            """, new { c = companyId, s = signatoryId, d = today }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        if (authorities.Count == 0) return (0, 0, []);
        var links = (await c.QueryAsync<(int Operation, int Power)>(new CommandDefinition(
            "SELECT OperationTypeId, PowerTypeId FROM cat.OperationTypePowerType;", transaction: tx, cancellationToken: ct)).ConfigureAwait(false))
            .ToLookup(x => x.Operation, x => x.Power);
        var companies = authorities.Select(a => a.CompanyId).Distinct().ToArray();
        var candidates = (await c.QueryAsync<Candidate>(new CommandDefinition(
            """
            SELECT g.AuthorityGrantId, g.RowVersion, g.CompanyId, COALESCE(g.PartyId, m.PartyId) AS HolderPartyId, m.RepresentedPartyId AS RepresentativeId, g.PowerTypeId,
                   g.InstitutionId, g.CeilingAmount, cu.Code AS CeilingCurrency, g.RequiresJoint, g.ValidFrom, g.ValidTo, g.GranteeKind, m.TermStart AS MemberStart,
                   m.TermEnd AS MemberEnd, m.ResignedOn AS MemberResigned
              FROM org.AuthorityGrant AS g LEFT JOIN org.BodyMember AS m ON m.BodyMemberId = g.BodyMemberId LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = g.CeilingCurrencyId
             WHERE g.Status = 'ACTIVE' AND g.GranteeKind <> 'BODY' AND g.CompanyId IN @companies;
            """, new { companies }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var findings = authorities.Where(a => a.Open)
            .SelectMany(a => Compare(a, [.. links[a.OperationTypeId]], candidates, today)).ToList();
        var existing = (await c.QueryAsync<(long Id, long AuthorityId, string Code, string Fingerprint, string Status)>(new CommandDefinition(
            "SELECT AuthorityConflictId, SignatoryAuthorityId, ConflictCode, Fingerprint, Status FROM acc.AuthorityConflict WHERE SignatoryAuthorityId IN @ids;",
            new { ids = authorities.Select(a => a.SignatoryAuthorityId).ToArray() }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var keys = findings.Select(f => (f.AuthorityId, f.Code, f.Fingerprint)).ToHashSet();
        var resolved = 0;
        foreach (var x in existing.Where(x => x.Status != "RESOLVED" && !keys.Contains((x.AuthorityId, x.Code, x.Fingerprint))))
        {
            resolved += await c.ExecuteAsync(new CommandDefinition(
                "UPDATE acc.AuthorityConflict SET Status = 'RESOLVED', ResolvedOn = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME() WHERE AuthorityConflictId = @id;",
                new { id = x.Id }, tx, cancellationToken: ct)).ConfigureAwait(false);
            await Outbox.EmitAsync(c, tx, "authority.conflict.resolved", "acc.AuthorityConflict", x.Id, new { conflict = x.Id, code = x.Code }, ct).ConfigureAwait(false);
        }
        var opened = 0;
        var byId = authorities.ToDictionary(a => a.SignatoryAuthorityId);
        foreach (var f in findings.Where(f => !existing.Any(x => x.AuthorityId == f.AuthorityId && x.Code == f.Code && x.Fingerprint == f.Fingerprint)))
        {
            var id = await c.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT acc.AuthorityConflict (TenantId, SignatoryAuthorityId, ConflictCode, Fingerprint, Status, DetectedOn, AuthorityGrantId, CreatedBy)
                OUTPUT inserted.AuthorityConflictId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @a, @code, @fp, 'OPEN', SYSUTCDATETIME(), @g, @actor);
                SELECT Id FROM @o;
                """, new { a = f.AuthorityId, code = f.Code, fp = f.Fingerprint, g = f.GrantId, actor }, tx, cancellationToken: ct)).ConfigureAwait(false);
            await Outbox.EmitAsync(c, tx, "authority.conflict.opened", "acc.AuthorityConflict", id, new { conflict = id, code = f.Code }, ct).ConfigureAwait(false);
            var a = byId[f.AuthorityId];
            await Notifier.RequestAsync(c, tx, new NotificationRequest("ACC.GOV_CONFLICT", "acc.AuthorityConflict", id, $"ACC.GOV_CONFLICT:{id}", a.CompanyId,
                new Dictionary<string, object?>
                {
                    ["companyName"] = Text(a.CompanyNameAr, a.CompanyNameEn), ["partyName"] = Text(a.PartyNameAr, a.PartyNameEn),
                    ["institutionName"] = Text(a.InstitutionNameAr, a.InstitutionNameEn), ["operationLabel"] = Text(a.OperationAr, a.OperationEn),
                    ["conflictCodeLabel"] = Labels.TryGetValue(f.Code, out var l) ? Text(l.Ar, l.En) : Text(f.Code, f.Code),
                }, ActorUserId: actor), ct).ConfigureAwait(false);
            opened++;
        }
        return (opened, resolved, findings);
    }

    public static readonly Dictionary<string, (string Ar, string En)> Labels = new(StringComparer.Ordinal)
    {
        ["NOT_MAPPED"] = ("العملية غير مربوطة بنوع صلاحية", "the operation is not linked to a power type"),
        ["NO_GRANT"] = ("لا منحة حوكمة للشخص", "no governance grant for the person"),
        ["GRANT_EXPIRED"] = ("منحة الحوكمة منتهية", "the governance grant has expired"),
        ["NOT_COMPARABLE_CURRENCY"] = ("عملة المنحة غير عملة الصلاحية", "the grant is in another currency"),
        ["GRANT_CEILING_UNSPECIFIED"] = ("سقف المنحة غير محدد", "the grant's ceiling is not specified"),
        ["CEILING_EXCEEDS"] = ("سقف الصلاحية يتجاوز سقف المنحة", "the authority's ceiling exceeds the grant's"),
        ["JOINT_MISMATCH"] = ("المنحة تشترط توقيعًا مشتركًا والصلاحية منفردة", "the grant requires joint signing, the authority is sole"),
    };

    private static Dictionary<string, string?> Text(string? ar, string? en) => new(StringComparer.Ordinal) { ["ar"] = ar ?? en, ["en"] = en ?? ar };
}

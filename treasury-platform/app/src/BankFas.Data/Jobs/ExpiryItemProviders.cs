using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Jobs;

/// <summary>An item that expires: its id (the ItemId of cfg.ExpiryAlertLog), its date, its company and the values of its message.</summary>
public sealed record ExpiryItem(long Id, DateTime ExpiryDate, long? CompanyId, IReadOnlyDictionary<string, object?> Values);

/// <summary>
/// One item type of cfg.ExpiryAlertRule (S1B-GAP-3): which rows expire within the horizon, the event they raise and the
/// type of their target. The job adds expiryDate, daysLeft and stageLabel to the values; a provider adds the names
/// only, never a number of an identity document, an account or an amount (BR-NTF-008).
/// </summary>
public interface IExpiryItemProvider
{
    string ItemType { get; }
    string EventCode { get; }
    string TargetType { get; }

    /// <summary>True when the item is valid through its expiry date, so the day-0 alert says "expires today".</summary>
    bool ValidThroughExpiryDate => false;

    Task<IReadOnlyList<ExpiryItem>> ItemsAsync(SqlConnection c, DateTime today, DateTime horizon, CancellationToken ct);
}

/// <summary>The providers of the expiry job; a slice adds its own here.</summary>
public static class ExpiryItemProviders
{
    public static readonly IReadOnlyList<IExpiryItemProvider> All = [new CompanyDocumentExpiry(), new IdentityDocumentExpiry()];

    internal static Dictionary<string, string?> Text(string? ar, string? en) => new(StringComparer.Ordinal) { ["ar"] = ar ?? en, ["en"] = en ?? ar };
}

/// <summary>COMPANY_DOCUMENT: the current version of an active document of a company that is not archived.</summary>
internal sealed class CompanyDocumentExpiry : IExpiryItemProvider
{
    public string ItemType => "COMPANY_DOCUMENT";
    public string EventCode => "DOC.EXPIRY";
    public string TargetType => "doc.Document";

    private sealed class Row
    {
        public long Id { get; init; }
        public DateTime ExpiryDate { get; init; }
        public long CompanyId { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string? TypeAr { get; init; }
        public string? TypeEn { get; init; }
        public string? Title { get; init; }
    }

    public async Task<IReadOnlyList<ExpiryItem>> ItemsAsync(SqlConnection c, DateTime today, DateTime horizon, CancellationToken ct) =>
        [.. (await c.QueryAsync<Row>(new CommandDefinition(
            """
            SELECT d.DocumentId AS Id, d.ExpiryDate, d.OwnerCompanyId AS CompanyId, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn, t.NameAr AS TypeAr,
                   t.NameEn AS TypeEn, d.Title
              FROM doc.Document AS d JOIN cat.DocumentType AS t ON t.DocumentTypeId = d.DocumentTypeId JOIN org.Company AS co ON co.CompanyId = d.OwnerCompanyId
             WHERE d.Status = 'ACTIVE' AND d.SupersededByDocumentId IS NULL AND d.ExpiryDate IS NOT NULL AND d.ExpiryDate <= @horizon AND co.Status <> 'ARCHIVED';
            """, new { horizon }, cancellationToken: ct)).ConfigureAwait(false))
            .Select(r => new ExpiryItem(r.Id, r.ExpiryDate, r.CompanyId, new Dictionary<string, object?>
            {
                ["companyName"] = ExpiryItemProviders.Text(r.CompanyNameAr, r.CompanyNameEn),
                ["documentType"] = ExpiryItemProviders.Text(r.TypeAr, r.TypeEn),
                ["documentTitle"] = r.Title,
            }))];
}

/// <summary>IDENTITY_DOCUMENT: the current identity document of an active party; the number is never in the message.</summary>
internal sealed class IdentityDocumentExpiry : IExpiryItemProvider
{
    public string ItemType => "IDENTITY_DOCUMENT";
    public string EventCode => "IDDOC.EXPIRY";
    public string TargetType => "pty.IdentityDocument";

    private static readonly Dictionary<string, (string Ar, string En)> DocKinds = new(StringComparer.Ordinal)
    {
        ["NATIONAL_ID"] = ("الهوية الوطنية", "national ID"), ["RESIDENCE"] = ("الإقامة", "residence permit"), ["PASSPORT"] = ("جواز السفر", "passport"),
        ["GCC_ID"] = ("هوية مجلس التعاون", "GCC ID"), ["COMMERCIAL_REG"] = ("السجل التجاري", "commercial registration"), ["OTHER_ORG"] = ("وثيقة الجهة", "organisation document"),
    };

    private sealed class Row
    {
        public long Id { get; init; }
        public DateTime ExpiryDate { get; init; }
        public long? CompanyId { get; init; }
        public string? PartyNameAr { get; init; }
        public string? PartyNameEn { get; init; }
        public string? Kind { get; init; }
    }

    public async Task<IReadOnlyList<ExpiryItem>> ItemsAsync(SqlConnection c, DateTime today, DateTime horizon, CancellationToken ct) =>
        [.. (await c.QueryAsync<Row>(new CommandDefinition(
            """
            SELECT i.IdentityDocumentId AS Id, i.ExpiryDate, co.CompanyId, p.NameAr AS PartyNameAr, p.NameEn AS PartyNameEn, i.DocKind AS Kind
              FROM pty.IdentityDocument AS i JOIN pty.Party AS p ON p.PartyId = i.PartyId LEFT JOIN org.Company AS co ON co.PartyId = p.PartyId
             WHERE i.IsSuperseded = 0 AND i.ExpiryDate IS NOT NULL AND i.ExpiryDate <= @horizon AND p.IsActive = 1;
            """, new { horizon }, cancellationToken: ct)).ConfigureAwait(false))
            .Select(r =>
            {
                var label = DocKinds.TryGetValue(r.Kind ?? "", out var known) ? known : (Ar: r.Kind ?? "", En: r.Kind ?? "");
                return new ExpiryItem(r.Id, r.ExpiryDate, r.CompanyId, new Dictionary<string, object?>
                {
                    ["partyName"] = ExpiryItemProviders.Text(r.PartyNameAr, r.PartyNameEn),
                    ["docKindLabel"] = ExpiryItemProviders.Text(label.Ar, label.En),
                });
            })];
}

using System.Globalization;
using System.Net;
using System.Text;
using BankFas.Core.Lc;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Lc;

/// <summary>
/// The printed terms of a purchase request (OQ-14; FR-LCT-005, 017 to 019, 028; AC-LCT-4): an HTML page the browser
/// prints. It shows the request's header, the fields of the version in the order of the field dictionary (the
/// requester's fields, or all of them for the treasury), the amount in words, the documents with their clause text
/// rendered from the library, the charges matrix and the terms hash. Each field carries its SWIFT MT700 field (the
/// dictionary's SwiftTagHint), the documents 46A and the charges 71D, and no UCP reference (the owner, docs/60 section
/// 6); sections, list values and statuses print as words (TermsLabels). A clause not legally reviewed carries its
/// banner. Every value is HTML-encoded.
/// </summary>
public static class TermsPrint
{
    private sealed class FieldDef
    {
        public long LcFieldDefinitionId { get; init; }
        public string FieldKey { get; init; } = "";
        public string SectionKey { get; init; } = "";
        public string LabelAr { get; init; } = "";
        public string LabelEn { get; init; } = "";
        public bool VisibleToRequester { get; init; }
        public string Sensitivity { get; init; } = "NORMAL";
        public string? SwiftTagHint { get; init; }
    }

    /// <summary>The page's only style, allowed by its hash in the response's Content-Security-Policy (no inline style otherwise).</summary>
    public const string Style =
        PrintStyle.Base + "body{font-size:11pt;margin:2cm}h1{font-size:15pt}h2{font-size:12pt;margin-top:1.2em}" +
        "td,th{padding:3px 6px}th.label{width:35%}.tag{color:#4E6660;font-family:'IBM Plex Mono',monospace;font-size:9pt;border:1px solid #DCE5E1;border-radius:3px;padding:0 3px}.foot{font-size:9pt;margin-top:2em}";

    private static string H(object? v) => WebUtility.HtmlEncode(v switch
    {
        null => "",
        DateTime d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        decimal m => m.ToString("#,0.##", CultureInfo.InvariantCulture),
        bool b => b ? "✓" : "—",
        _ => Convert.ToString(v, CultureInfo.InvariantCulture) ?? "",
    });

    public static async Task<(string Html, string? Hash)> BuildAsync(SqlConnection c, SqlTransaction? tx, long requestId, TermsStore.TermsRow t, bool treasury, bool arabic,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(t);
        var values = await TermsStore.ReadAsync(c, tx, t.LcTermsId, treasury, ct).ConfigureAwait(false);
        var head = await c.QuerySingleAsync<(string? RequestNo, string DraftRef, string? CompanyAr, string? CompanyEn, string? WordsAr, string? WordsEn, byte[]? Hash, string? IbanMask)>(
            new CommandDefinition(
                """
                SELECT r.RequestNo, r.DraftRef, co.NameAr, co.NameEn, t.AmountInWordsAr, t.AmountInWordsEn, t.SnapshotHash, t.BeneficiaryAccountIbanMask
                  FROM wfl.Request AS r JOIN org.Company AS co ON co.CompanyId = r.CompanyId JOIN lc.LcTerms AS t ON t.LcTermsId = @t WHERE r.RequestId = @r;
                """, new { r = requestId, t = t.LcTermsId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var defs = (await c.QueryAsync<FieldDef>(new CommandDefinition(
            "SELECT LcFieldDefinitionId, FieldKey, SectionKey, LabelAr, LabelEn, VisibleToRequester, Sensitivity, SwiftTagHint FROM lc.LcFieldDefinition ORDER BY SectionKey, SortOrder, FieldKey;",
            transaction: tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var docs = (await c.QueryAsync<(long ClauseId, string Code, string NameAr, string NameEn, string TextAr, string TextEn, string Review, int? Originals, int? Copies, string? Params,
            bool IsFree, string? FreeText)>(new CommandDefinition(
            """
            SELECT k.LcDocumentClauseId, k.Code, k.NameAr, k.NameEn, k.TemplateTextAr, k.TemplateTextEn, k.LegalReviewStatus, d.Originals, d.Copies, d.ParamsJson, d.IsFreeText, d.[FreeText]
              FROM lc.LcTermsDocument AS d JOIN lc.LcDocumentClause AS k ON k.LcDocumentClauseId = d.ClauseId WHERE d.LcTermsId = @t ORDER BY d.SeqNo;
            """, new { t = t.LcTermsId }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var charges = await c.QueryAsync<(string Category, string Payer, decimal? Share)>(new CommandDefinition(
            "SELECT ChargeCategory, Payer, ApplicantSharePct FROM lc.LcChargesMatrix WHERE LcTermsId = @t ORDER BY ChargeCategory;", new { t = t.LcTermsId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        var lcType = values.TryGetValue("lcType", out var type) ? type as string : null;
        string Tag(string? code) => code is null ? "" : " <span class=\"tag\" dir=\"ltr\">" + H(code) + "</span>";

        var b = new StringBuilder();
        b.Append("<!doctype html><html lang=\"").Append(arabic ? "ar\" dir=\"rtl" : "en\" dir=\"ltr").Append("\"><head><meta charset=\"utf-8\"><title>")
            .Append(H(head.RequestNo ?? head.DraftRef)).Append("</title><style>").Append(Style).Append("</style></head><body>");
        b.Append("<h1>").Append(arabic ? "شروط الاعتماد المستندي" : "Letter of credit terms").Append(" — ").Append(H(head.RequestNo ?? head.DraftRef)).Append("</h1>");
        b.Append("<p>").Append(H(arabic ? head.CompanyAr ?? head.CompanyEn : head.CompanyEn ?? head.CompanyAr)).Append(" · ")
            .Append(arabic ? "الإصدار " : "Version ").Append(t.VersionNo).Append(" · ").Append(H(TermsLabels.Of(t.Status, arabic))).Append("</p>");
        foreach (var section in defs.Where(d => treasury || d.VisibleToRequester).GroupBy(d => d.SectionKey))
        {
            var rows = section.Where(d => d.Sensitivity != "RESTRICTED" && values.TryGetValue(d.FieldKey, out var v) && v is not null && (v is not string s || s.Length > 0)).ToList();
            if (rows.Count == 0) continue;
            b.Append("<h2>").Append(H(TermsLabels.Of(section.Key, arabic))).Append("</h2><table>");
            foreach (var d in rows)
            {
                var v = values[d.FieldKey];
                b.Append("<tr><th class=\"label\">").Append(H(arabic ? d.LabelAr : d.LabelEn)).Append(Tag(TermsLabels.Tag(d.SwiftTagHint, lcType))).Append("</th><td>")
                    .Append(v is string word ? H(TermsLabels.Of(word, arabic)) : H(v)).Append("</td></tr>");
            }
            b.Append("</table>");
        }
        if (head.IbanMask is { } mask)
            b.Append("<p>").Append(arabic ? "حساب المستفيد (IBAN): " : "Beneficiary's IBAN: ").Append("<span dir=\"ltr\">").Append(H(mask)).Append("</span></p>");
        if ((arabic ? head.WordsAr : head.WordsEn) is { } words) b.Append("<p><strong>").Append(H(words)).Append("</strong></p>");
        b.Append("<h2>").Append(arabic ? "المستندات المطلوبة" : "Documents required").Append(Tag("46A")).Append("</h2><ol>");
        foreach (var d in docs)
        {
            var text = d.IsFree ? d.FreeText ?? "" : ClauseText.Render(arabic ? d.TextAr : d.TextEn, d.Params, d.Originals, d.Copies, arabic);
            b.Append("<li>").Append(H(text));
            if (d.Review != "REVIEWED") b.Append(" <span class=\"banner\">").Append(arabic ? "لم يُراجَع قانونيًا" : "Not legally reviewed").Append("</span>");
            b.Append("</li>");
        }
        b.Append("</ol><h2>").Append(arabic ? "الرسوم" : "Charges").Append(Tag("71D")).Append("</h2><table>");
        foreach (var (category, payer, share) in charges)
            b.Append("<tr><th>").Append(H(TermsLabels.Of(category, arabic))).Append("</th><td>").Append(H(TermsLabels.Of(payer, arabic))).Append(share is { } s ? $" ({H(s)}%)" : "").Append("</td></tr>");
        b.Append("</table>");
        var hash = head.Hash is null ? null : Convert.ToHexString(head.Hash);
        b.Append("<div class=\"foot\">");
        if (hash is not null) b.Append("<p dir=\"ltr\">SHA-256 ").Append(hash).Append("</p>");
        b.Append("</div></body></html>");
        return (b.ToString(), hash);
    }
}

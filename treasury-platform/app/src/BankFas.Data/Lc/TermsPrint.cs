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
/// rendered from the library, the charges matrix and the terms hash. A field or clause carries its UCP 600 references
/// when lc.print.show_ucp holds; the footnote on unverified UCP texts is printed when lc.print.ucp_disclaimer holds and
/// always while any article referred to is UNVERIFIED, so it cannot be switched off before the platform has verified
/// them. A clause not legally reviewed carries its banner. Every value is HTML-encoded.
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
    }

    /// <summary>The page's only style, allowed by its hash in the response's Content-Security-Policy (no inline style otherwise).</summary>
    public const string Style =
        "body{font-family:system-ui,sans-serif;font-size:11pt;margin:2cm}h1{font-size:15pt}h2{font-size:12pt;margin-top:1.2em;border-bottom:1px solid #999}" +
        "table{border-collapse:collapse;width:100%}td,th{border:1px solid #bbb;padding:3px 6px;vertical-align:top;text-align:start}th.label{width:35%}.ucp{color:#555;font-size:9pt}" +
        ".banner{color:#a00;font-weight:bold}.foot{font-size:9pt;color:#444;margin-top:2em}";

    private sealed record Ucp(long OwnerId, string ArticleNo, string? Paragraph, string Status);

    private static string H(object? v) => WebUtility.HtmlEncode(v switch
    {
        null => "",
        DateTime d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        decimal m => m.ToString("#,0.##", CultureInfo.InvariantCulture),
        bool b => b ? "✓" : "✗",
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
            "SELECT LcFieldDefinitionId, FieldKey, SectionKey, LabelAr, LabelEn, VisibleToRequester, Sensitivity FROM lc.LcFieldDefinition ORDER BY SectionKey, SortOrder, FieldKey;",
            transaction: tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var fieldUcp = (await c.QueryAsync<Ucp>(new CommandDefinition(
            """
            SELECT r.LcFieldDefinitionId AS OwnerId, a.ArticleNo, r.Paragraph, a.VerificationStatus AS Status
              FROM lc.LcFieldUcpRef AS r JOIN ref.UcpArticle AS a ON a.UcpArticleId = r.UcpArticleId;
            """, transaction: tx, cancellationToken: ct)).ConfigureAwait(false)).ToLookup(u => u.OwnerId);
        var docs = (await c.QueryAsync<(long ClauseId, string Code, string NameAr, string NameEn, string TextAr, string TextEn, string Review, int? Originals, int? Copies, string? Params,
            bool IsFree, string? FreeText)>(new CommandDefinition(
            """
            SELECT k.LcDocumentClauseId, k.Code, k.NameAr, k.NameEn, k.TemplateTextAr, k.TemplateTextEn, k.LegalReviewStatus, d.Originals, d.Copies, d.ParamsJson, d.IsFreeText, d.[FreeText]
              FROM lc.LcTermsDocument AS d JOIN lc.LcDocumentClause AS k ON k.LcDocumentClauseId = d.ClauseId WHERE d.LcTermsId = @t ORDER BY d.SeqNo;
            """, new { t = t.LcTermsId }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var clauseUcp = (await c.QueryAsync<Ucp>(new CommandDefinition(
            """
            SELECT r.LcDocumentClauseId AS OwnerId, a.ArticleNo, r.Paragraph, a.VerificationStatus AS Status
              FROM lc.LcDocumentClauseUcpRef AS r JOIN ref.UcpArticle AS a ON a.UcpArticleId = r.UcpArticleId;
            """, transaction: tx, cancellationToken: ct)).ConfigureAwait(false)).ToLookup(u => u.OwnerId);
        var charges = await c.QueryAsync<(string Category, string Payer, decimal? Share)>(new CommandDefinition(
            "SELECT ChargeCategory, Payer, ApplicantSharePct FROM lc.LcChargesMatrix WHERE LcTermsId = @t ORDER BY ChargeCategory;", new { t = t.LcTermsId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        var settings = await Workflow.FacilityHooks.SettingsAsync(c, tx, ct, "lc.print.show_ucp", "lc.print.ucp_disclaimer").ConfigureAwait(false);
        var showUcp = settings.GetValueOrDefault("lc.print.show_ucp") != "false";
        var disclaimer = settings.GetValueOrDefault("lc.print.ucp_disclaimer") != "false";

        var used = new List<Ucp>();
        string Badges(IEnumerable<Ucp> refs)
        {
            var list = refs.ToList();
            used.AddRange(list);
            if (!showUcp || list.Count == 0) return "";
            return " <span class=\"ucp\">" + string.Join(" · ", list.Select(u => H(ClauseText.Reference(u.ArticleNo, u.Paragraph, arabic)) + (u.Status == "VERIFIED" ? "" : "*"))) + "</span>";
        }

        var b = new StringBuilder();
        b.Append("<!doctype html><html lang=\"").Append(arabic ? "ar\" dir=\"rtl" : "en\" dir=\"ltr").Append("\"><head><meta charset=\"utf-8\"><title>")
            .Append(H(head.RequestNo ?? head.DraftRef)).Append("</title><style>").Append(Style).Append("</style></head><body>");
        b.Append("<h1>").Append(arabic ? "شروط الاعتماد المستندي" : "Letter of credit terms").Append(" — ").Append(H(head.RequestNo ?? head.DraftRef)).Append("</h1>");
        b.Append("<p>").Append(H(arabic ? head.CompanyAr ?? head.CompanyEn : head.CompanyEn ?? head.CompanyAr)).Append(" · ")
            .Append(arabic ? "الإصدار " : "Version ").Append(t.VersionNo).Append(" · ").Append(H(t.Status)).Append("</p>");
        foreach (var section in defs.Where(d => treasury || d.VisibleToRequester).GroupBy(d => d.SectionKey))
        {
            var rows = section.Where(d => d.Sensitivity != "RESTRICTED" && values.TryGetValue(d.FieldKey, out var v) && v is not null && (v is not string s || s.Length > 0)).ToList();
            if (rows.Count == 0) continue;
            b.Append("<h2>").Append(H(section.Key)).Append("</h2><table>");
            foreach (var d in rows)
                b.Append("<tr><th class=\"label\">").Append(H(arabic ? d.LabelAr : d.LabelEn)).Append(Badges(fieldUcp[d.LcFieldDefinitionId])).Append("</th><td>")
                    .Append(H(values[d.FieldKey])).Append("</td></tr>");
            b.Append("</table>");
        }
        if (head.IbanMask is { } mask)
            b.Append("<p>").Append(arabic ? "حساب المستفيد (IBAN): " : "Beneficiary's IBAN: ").Append("<span dir=\"ltr\">").Append(H(mask)).Append("</span></p>");
        if ((arabic ? head.WordsAr : head.WordsEn) is { } words) b.Append("<p><strong>").Append(H(words)).Append("</strong></p>");
        b.Append("<h2>").Append(arabic ? "المستندات المطلوبة" : "Documents required").Append("</h2><ol>");
        foreach (var d in docs)
        {
            var text = d.IsFree ? d.FreeText ?? "" : ClauseText.Render(arabic ? d.TextAr : d.TextEn, d.Params, d.Originals, d.Copies, arabic);
            b.Append("<li>").Append(H(text)).Append(Badges(clauseUcp[d.ClauseId]));
            if (d.Review != "REVIEWED") b.Append(" <span class=\"banner\">").Append(arabic ? "لم يُراجَع قانونيًا" : "Not legally reviewed").Append("</span>");
            b.Append("</li>");
        }
        b.Append("</ol><h2>").Append(arabic ? "الرسوم" : "Charges").Append("</h2><table>");
        foreach (var (category, payer, share) in charges)
            b.Append("<tr><th>").Append(H(category)).Append("</th><td>").Append(H(payer)).Append(share is { } s ? $" ({H(s)}%)" : "").Append("</td></tr>");
        b.Append("</table>");
        var unverified = used.Any(u => u.Status != "VERIFIED");
        var hash = head.Hash is null ? null : Convert.ToHexString(head.Hash);
        b.Append("<div class=\"foot\">");
        if (disclaimer || unverified)
            b.Append("<p>* ").Append(arabic
                ? "مراجع UCP 600 إرشادية؛ والنصوص المعلَّمة بنجمة لم يتحقق منها مشغّل المنصة بعد، ولا تُغني عن نص غرفة التجارة الدولية."
                : "UCP 600 references are a guide; the texts marked with a star are not yet verified by the platform operator and do not replace the ICC text.").Append("</p>");
        if (hash is not null) b.Append("<p dir=\"ltr\">SHA-256 ").Append(hash).Append("</p>");
        b.Append("</div></body></html>");
        return (b.ToString(), hash);
    }
}

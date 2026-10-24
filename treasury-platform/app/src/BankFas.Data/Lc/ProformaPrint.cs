using System.Globalization;
using System.Net;
using System.Text;
using BankFas.Core.Lc;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Lc;

/// <summary>
/// The printed proforma (FR-LCT-029; spec 02 section 7.1): a self-contained HTML page, stored as the PROFORMA_ISSUED
/// document with its hash and printed by the browser. It carries the company's heading, the number, the dates, the
/// customer as snapshot at the issue, the branch and project, the lines and totals with the total in words, the payment
/// by credit, the terms asked of the customer in the order of the field dictionary, the documents with their clause
/// text, the charges, and the proceeds account with its IBAN, printed for the customer on purpose (BR-LCE-004). The
/// language is Arabic, English or both. Every value is HTML-encoded and the page has no script.
/// </summary>
public static class ProformaPrint
{
    public sealed record Data(string Number, DateTime IssueDate, ProformaStore.ProformaForm Form, ProformaTotals Totals, string Currency, int Decimals,
        (string Ar, string En) AmountInWords, string CompanyNameAr, string CompanyNameEn, string? CompanyCr, string? CompanyAddress, IDictionary<string, object?> Customer,
        string BankNameEn, string BankNameAr, string? BankBic, string? Iban, string AccountMask, string Language, DateTime? ValidUntil);

    private const string Style =
        "body{font-family:system-ui,sans-serif;font-size:10.5pt;margin:1.5cm}h1{font-size:16pt;margin:0}h2{font-size:12pt;margin-top:1.2em;border-bottom:1px solid #999}" +
        "table{border-collapse:collapse;width:100%}td,th{border:1px solid #bbb;padding:3px 6px;vertical-align:top;text-align:start}.num{text-align:end;white-space:nowrap}" +
        ".head{display:flex;justify-content:space-between;border-bottom:2px solid #333;padding-bottom:6px}.muted{color:#555}.banner{color:#a00;font-weight:bold}.foot{font-size:8.5pt;color:#444;margin-top:2em}";

    private static string H(object? v) => WebUtility.HtmlEncode(v switch
    {
        null => "",
        DateTime d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        bool b => b ? "✓" : "✗",
        _ => Convert.ToString(v, CultureInfo.InvariantCulture) ?? "",
    });

    public static async Task<string> BuildAsync(SqlConnection c, SqlTransaction tx, long termsId, Data d, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(d);
        var ar = d.Language is "ar" or "both";
        var en = d.Language is "en" or "both";
        string L(string arText, string enText) => d.Language switch { "ar" => arText, "en" => enText, _ => $"{enText} / {arText}" };
        string M(decimal v) => H(v.ToString("N" + d.Decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture));
        string? C(string k) => d.Customer.TryGetValue(k, out var v) ? v as string : null;

        var values = await TermsStore.ReadAsync(c, tx, termsId, false, ct).ConfigureAwait(false);
        var defs = await c.QueryAsync<(string FieldKey, string LabelAr, string LabelEn, string Sensitivity)>(new CommandDefinition(
            "SELECT FieldKey, LabelAr, LabelEn, Sensitivity FROM lc.LcFieldDefinition WHERE IsActive = 1 AND VisibleToRequester = 1 ORDER BY SectionKey, SortOrder, FieldKey;",
            transaction: tx, cancellationToken: ct)).ConfigureAwait(false);
        var docs = await c.QueryAsync<(string NameAr, string NameEn, string TextAr, string TextEn, string Review, int? Originals, int? Copies, string? Params, bool IsFree, string? FreeText)>(
            new CommandDefinition(
                """
                SELECT k.NameAr, k.NameEn, k.TemplateTextAr, k.TemplateTextEn, k.LegalReviewStatus, d.Originals, d.Copies, d.ParamsJson, d.IsFreeText, d.[FreeText]
                  FROM lc.LcTermsDocument AS d JOIN lc.LcDocumentClause AS k ON k.LcDocumentClauseId = d.ClauseId WHERE d.LcTermsId = @t ORDER BY d.SeqNo;
                """, new { t = termsId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var charges = await c.QueryAsync<(string Category, string Payer, decimal? Share)>(new CommandDefinition(
            "SELECT ChargeCategory, Payer, ApplicantSharePct FROM lc.LcChargesMatrix WHERE LcTermsId = @t ORDER BY ChargeCategory;", new { t = termsId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        var hash = await c.ExecuteScalarAsync<byte[]?>(new CommandDefinition("SELECT SnapshotHash FROM lc.LcTerms WHERE LcTermsId = @t;", new { t = termsId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);

        var b = new StringBuilder();
        b.Append("<!doctype html><html lang=\"").Append(d.Language == "en" ? "en\" dir=\"ltr" : "ar\" dir=\"rtl").Append("\"><head><meta charset=\"utf-8\"><title>")
            .Append(H(d.Number)).Append("</title><style>").Append(Style).Append("</style></head><body>");
        b.Append("<div class=\"head\"><div><h1>");
        if (ar) b.Append(H(d.CompanyNameAr));
        if (ar && en) b.Append("<br>");
        if (en) b.Append(H(d.CompanyNameEn));
        b.Append("</h1><div class=\"muted\">");
        if (d.CompanyCr is not null) b.Append(L("السجل التجاري", "CR")).Append(' ').Append(H(d.CompanyCr)).Append(" · ");
        b.Append(H(d.CompanyAddress)).Append("</div></div><div><h1>").Append(L("فاتورة مبدئية", "PROFORMA INVOICE")).Append("</h1><div><span dir=\"ltr\">").Append(H(d.Number))
            .Append("</span></div><div>").Append(L("التاريخ", "Date")).Append(": ").Append(H(d.IssueDate)).Append("</div>");
        if (d.ValidUntil is { } vu) b.Append("<div>").Append(L("صالحة حتى", "Valid until")).Append(": ").Append(H(vu)).Append("</div>");
        b.Append("</div></div>");

        b.Append("<h2>").Append(L("العميل", "Customer")).Append("</h2><table><tr><td>");
        if (ar && C("nameAr") is { } na) b.Append(H(na)).Append("<br>");
        b.Append(H(C("nameEn")));
        if (C("erpCode") is { } erp) b.Append(" <span class=\"muted\">(").Append(H(erp)).Append(")</span>");
        b.Append("<br>").Append(H(string.Join(", ", new[] { C("addressLine"), C("city"), C("postalCode"), C("country") }.Where(x => !string.IsNullOrEmpty(x)))));
        if (C("poBox") is { } po) b.Append("<br>").Append(L("ص.ب.", "P.O. Box")).Append(' ').Append(H(po));
        if (C("phone") is { } ph) b.Append("<br>").Append(L("هاتف", "Tel")).Append(" <span dir=\"ltr\">").Append(H(ph)).Append("</span>");
        if (C("fax") is { } fx) b.Append(" · ").Append(L("فاكس", "Fax")).Append(" <span dir=\"ltr\">").Append(H(fx)).Append("</span>");
        if (C("taxNumber") is { } tn) b.Append("<br>").Append(L("الرقم الضريبي", "Tax number")).Append(' ').Append(H(tn));
        b.Append("</td><td>");
        if (d.Form.BranchCode is not null || d.Form.BranchName is not null)
            b.Append(L("الفرع", "Branch")).Append(": ").Append(H(string.Join(" — ", new[] { d.Form.BranchCode, d.Form.BranchName }.OfType<string>()))).Append("<br>");
        if (d.Form.ProjectCode is not null || d.Form.ProjectName is not null)
            b.Append(L("المشروع", "Project")).Append(": ").Append(H(string.Join(" — ", new[] { d.Form.ProjectCode, d.Form.ProjectName, d.Form.ProjectSite }.OfType<string>()))).Append("<br>");
        if (d.Form.PlaceOfReceipt is { } pr) b.Append(L("مكان الاستلام", "Place of receipt")).Append(": ").Append(H(pr)).Append("<br>");
        if (d.Form.PlaceOfDelivery is { } pd) b.Append(L("مكان التسليم", "Place of delivery")).Append(": ").Append(H(pd));
        b.Append("</td></tr></table>");

        b.Append("<h2>").Append(L("البنود", "Items")).Append("</h2><table><tr><th>#</th><th>").Append(L("الوصف", "Description")).Append("</th><th class=\"num\">")
            .Append(L("الكمية", "Qty")).Append("</th><th>").Append(L("الوحدة", "Unit")).Append("</th><th class=\"num\">").Append(L("سعر الوحدة", "Unit price"))
            .Append("</th><th class=\"num\">").Append(L("الإجمالي", "Total")).Append(" (").Append(H(d.Currency)).Append(")</th></tr>");
        foreach (var l in d.Totals.Lines)
            b.Append("<tr><td>").Append(l.LineNo).Append("</td><td>").Append(H(l.Description)).Append(l.Notes is { } n ? $"<br><span class=\"muted\">{H(n)}</span>" : "")
                .Append("</td><td class=\"num\">").Append(H(l.Qty.ToString("0.####", CultureInfo.InvariantCulture))).Append("</td><td>").Append(H(l.UnitCode))
                .Append("</td><td class=\"num\">").Append(H(l.UnitPrice.ToString("#,0.####", CultureInfo.InvariantCulture))).Append("</td><td class=\"num\">").Append(M(l.LineTotal))
                .Append("</td></tr>");
        b.Append("<tr><th colspan=\"5\">").Append(L("المجموع", "Subtotal")).Append("</th><td class=\"num\">").Append(M(d.Totals.Subtotal)).Append("</td></tr>");
        b.Append("<tr><th colspan=\"5\">").Append(L("ضريبة القيمة المضافة", "VAT")).Append(' ').Append(H(d.Totals.VatRatePct.ToString("0.##", CultureInfo.InvariantCulture)))
            .Append("%</th><td class=\"num\">").Append(M(d.Totals.VatAmount)).Append("</td></tr>");
        b.Append("<tr><th colspan=\"5\">").Append(L("الإجمالي", "Total")).Append("</th><td class=\"num\"><strong>").Append(M(d.Totals.Total)).Append("</strong></td></tr></table>");
        if (ar) b.Append("<p><strong>").Append(H(d.AmountInWords.Ar)).Append("</strong></p>");
        if (en) b.Append("<p><strong>").Append(H(d.AmountInWords.En)).Append("</strong></p>");

        b.Append("<h2>").Append(L("الدفع", "Payment")).Append("</h2><p>");
        b.Append(H(d.Form.LcPaymentPct.ToString("0.##", CultureInfo.InvariantCulture))).Append("% ")
            .Append(L("بموجب اعتماد مستندي غير قابل للإلغاء", "by an irrevocable documentary letter of credit")).Append(": ").Append(M(d.Totals.LcAmount)).Append(' ').Append(H(d.Currency))
            .Append("</p><table>");
        foreach (var f in defs)
            if (f.Sensitivity != "RESTRICTED" && values.TryGetValue(f.FieldKey, out var v) && v is not null && (v is not string s || s.Length > 0)
                && f.FieldKey is not ("amount" or "currencyId" or "lcClass" or "applicant" or "beneficiary"))
                b.Append("<tr><th>").Append(H(L(f.LabelAr, f.LabelEn))).Append("</th><td>").Append(H(v)).Append("</td></tr>");
        b.Append("</table>");

        b.Append("<h2>").Append(L("المستندات المطلوبة", "Documents required")).Append("</h2><ol>");
        foreach (var x in docs)
        {
            b.Append("<li>");
            if (ar) b.Append(H(x.IsFree ? x.FreeText ?? "" : ClauseText.Render(x.TextAr, x.Params, x.Originals, x.Copies, true)));
            if (ar && en) b.Append("<br>");
            if (en) b.Append(H(x.IsFree ? x.FreeText ?? "" : ClauseText.Render(x.TextEn, x.Params, x.Originals, x.Copies, false)));
            if (x.Review != "REVIEWED") b.Append(" <span class=\"banner\">").Append(L("لم يُراجَع قانونيًا", "Not legally reviewed")).Append("</span>");
            b.Append("</li>");
        }
        b.Append("</ol><h2>").Append(L("الرسوم", "Charges")).Append("</h2><table>");
        foreach (var (category, payer, share) in charges)
            b.Append("<tr><th>").Append(H(category)).Append("</th><td>").Append(H(payer)).Append(share is { } sh ? $" ({H(sh.ToString("0.##", CultureInfo.InvariantCulture))}%)" : "").Append("</td></tr>");
        b.Append("</table>");

        b.Append("<h2>").Append(L("حساب المتحصلات", "Proceeds account")).Append("</h2><table><tr><th>").Append(L("المستفيد", "Beneficiary")).Append("</th><td>")
            .Append(H(ar && !en ? d.CompanyNameAr : d.CompanyNameEn)).Append("</td></tr><tr><th>").Append(L("البنك", "Bank")).Append("</th><td>")
            .Append(H(ar && !en ? d.BankNameAr : d.BankNameEn)).Append(d.BankBic is { } bic ? $" <span dir=\"ltr\">({H(bic)})</span>" : "").Append("</td></tr>");
        if (d.Iban is { } iban) b.Append("<tr><th>IBAN</th><td dir=\"ltr\">").Append(H(iban)).Append("</td></tr>");
        b.Append("<tr><th>").Append(L("رقم الحساب", "Account")).Append("</th><td dir=\"ltr\">").Append(H(d.AccountMask)).Append("</td></tr></table>");
        b.Append("<p>").Append(L("تأكدوا أن مدة الاعتماد كافية لشحن كل المواد.", "Please make sure the validity of the credit is enough to ship all the items.")).Append("</p>");
        b.Append("<div class=\"foot\">").Append(L("أعدّتها المنصة؛ لا تُعدَّل بعد إصدارها.", "Prepared by the platform; not changed after its issue."));
        if (hash is not null) b.Append("<p dir=\"ltr\">SHA-256 ").Append(Convert.ToHexString(hash)).Append("</p>");
        b.Append("</div></body></html>");
        return b.ToString();
    }
}

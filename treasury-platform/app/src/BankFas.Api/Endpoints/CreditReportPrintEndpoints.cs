using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;

namespace BankFas.Api.Endpoints;

/// <summary>
/// The printed credit assessment report (identity guide p.24, ADR 0055, docs/56 §7): a cover in vault green with the
/// slant pattern, the company as its title and the final grade, then white pages with the summary and the grade's
/// steps, the recommendation in the box of its risk band, the factors with their figures in mono, the findings and the
/// methodology's disclaimer. Everything comes from the database's report views (fin.v_CreditAssessment*), the same the
/// screen reads; every value is HTML-encoded and the page has no script. An assessment that is not approved, or a
/// trial, carries the draft mark on every page; one that is not endorsed says it is for internal use (ADR 0029).
/// </summary>
public static class CreditReportPrintEndpoints
{
    public static void Map(RouteGroupBuilder api) => api.MapGet("/fin/assessments/{id:guid}/print", PrintAsync);

    private static readonly Lazy<string> LogoInverse = new(() => Resource("brand.logo-inverse.svg"));
    private static readonly Lazy<string> Symbol = new(() => Resource("brand.symbol.svg"));

    private static string Resource(string name)
    {
        using var s = typeof(CreditReportPrintEndpoints).Assembly.GetManifestResourceStream(name) ?? throw new InvalidOperationException($"The resource {name} is missing.");
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        return "data:image/svg+xml;base64," + Convert.ToBase64String(ms.ToArray());
    }

    /// <summary>The page's style: the shared print style, a full-bleed cover and A4 pages with their own margins.</summary>
    public const string Style = PrintStyle.Base +
        "@page{size:A4;margin:0}*{-webkit-print-color-adjust:exact;print-color-adjust:exact}body{margin:0;font-size:10.5pt}" +
        ".cover{box-sizing:border-box;width:210mm;height:297mm;background:#062A22;color:#F4F7F5;padding:22mm 20mm;display:flex;flex-direction:column;page-break-after:always;position:relative;overflow:hidden}" +
        ".cover .logo{height:12mm}.cover .slants{display:grid;grid-template-columns:repeat(7,1fr);gap:4mm 5mm;width:120mm;margin:28mm 0 auto}" +
        ".cover .slants i{display:block;height:7mm;background:#0B3A2F;transform:skewX(-17deg);border-radius:.6mm}.cover .slants i.lit{background:#37DDB1}" +
        ".cover .slants i:nth-child(14n+8),.cover .slants i:nth-child(14n+9),.cover .slants i:nth-child(14n+10),.cover .slants i:nth-child(14n+11),.cover .slants i:nth-child(14n+12),.cover .slants i:nth-child(14n+13),.cover .slants i:nth-child(14n+14){margin-inline-start:5mm}" +
        ".cover .kind{color:#37DDB1;font-weight:600;font-size:13pt;margin:0 0 3mm}.cover h1{color:#fff;font-size:28pt;line-height:1.25;margin:0 0 5mm;border:0}" +
        ".cover .meta{color:#C9D6D1;font-size:11pt;margin:0 0 1.5mm}.cover .meta .mono{font-family:\"IBM Plex Mono\",monospace}" +
        ".cover .grade{display:flex;gap:8mm;align-items:center;margin-top:12mm;padding-top:8mm;border-top:1px solid #0B3A2F}" +
        ".cover .grade b{font-size:40pt;font-weight:700;color:#fff;line-height:1}.cover .grade span{display:block;color:#C9D6D1}.cover .grade strong{color:#37DDB1;font-size:12pt}" +
        ".cover .use{position:absolute;inset-block-end:12mm;inset-inline-start:20mm;inset-inline-end:20mm;font-size:8.5pt;color:#8FA9A1;display:flex;justify-content:space-between}" +
        ".page{box-sizing:border-box;width:210mm;min-height:297mm;padding:18mm 18mm 16mm;position:relative;page-break-after:always}.page:last-child{page-break-after:auto}" +
        ".runhead{display:flex;align-items:center;gap:3mm;border-bottom:2px solid #00A97F;padding-bottom:3mm;margin-bottom:8mm;color:#4E6660;font-size:9pt}.runhead img{height:7mm}.runhead span{flex:1}" +
        "h2{font-size:14pt;margin:7mm 0 3mm}td,th{padding:2.2mm 3mm;font-size:9.5pt}td.n{direction:ltr;text-align:end;white-space:nowrap}" +
        ".steps{display:grid;grid-template-columns:repeat(5,1fr);gap:2mm;margin:2mm 0 4mm}.steps div{border:1px solid #DCE5E1;border-radius:2mm;padding:3mm;text-align:center}" +
        ".steps small{display:block;color:#4E6660;font-size:8pt}.steps b{font-family:\"IBM Plex Mono\",monospace;font-size:15pt;color:#062A22}.steps .final{background:#062A22;border-color:#062A22}.steps .final b,.steps .final small{color:#fff}" +
        ".box{border-radius:2mm;padding:4mm 5mm;margin:4mm 0}.box h3{margin:0 0 1.5mm;font-size:11pt}.box p{margin:0}" +
        ".box.done{background:#F0FAF7;color:#016D52}.box.review{background:#FCF7F0;color:#A26308}.box.stop{background:#FBF3F2;color:#C2362B}.box.draft{background:#EEF2F0;color:#4E6660}" +
        ".facts{display:grid;grid-template-columns:repeat(3,1fr);gap:2mm 6mm;margin:3mm 0}.facts div{border-bottom:1px solid #DCE5E1;padding:1.5mm 0}.facts small{display:block;color:#4E6660;font-size:8pt}" +
        ".kind-h{font-weight:600;color:#062A22;margin:4mm 0 1mm;break-after:avoid}ul.find{margin:0;padding-inline-start:5mm;columns:2;column-gap:8mm;font-size:8.5pt}ul.find li{margin:0 0 1mm;break-inside:avoid}" +
        ".mark{position:absolute;top:120mm;left:0;right:0;text-align:center;font-size:34pt;color:rgba(194,54,43,.10);transform:rotate(-24deg);pointer-events:none}" +
        ".foot{font-size:8pt;margin-top:8mm}";

    private static string H(object? v) => WebUtility.HtmlEncode(v switch
    {
        null => "",
        DateTime d => d.ToString("dd/MM/yyyy", CultureInfo.InvariantCulture),
        decimal m => m.ToString("#,0.##", CultureInfo.InvariantCulture),
        _ => Convert.ToString(v, CultureInfo.InvariantCulture) ?? "",
    });

    private static string Tone(string? band) => band switch
    {
        "LOW" or "MODERATE" => "done",
        "SUBSTANTIAL" => "review",
        "HIGH" or "VERY_HIGH" => "stop",
        _ => "draft",
    };

    private static async Task<IResult> PrintAsync(Guid id, HttpContext http, SqlConnectionFactory db, PdfRenderer pdf, TimeProvider clock)
    {
        Query.Allow(http.Request, "lang", "format");
        var asPdf = Pdf.Wanted(http.Request);
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var a = await CreditEndpoints.FindAsync(u, null, id, scope, ct);
        var lang = http.Request.Query["lang"].ToString();
        if (lang is not ("" or "ar" or "en")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The language is ar or en.");
        var userLang = await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT PreferredLanguage FROM sec.AppUser WHERE AppUserId = @u;", new { u = u.UserId },
            cancellationToken: ct));
        var ar = lang.Length > 0 ? lang == "ar" : userLang == "ar";
        var r = (IDictionary<string, object?>)await u.Connection.QuerySingleAsync(new CommandDefinition(
            "SELECT * FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;", new { a = a.CreditAssessmentId }, cancellationToken: ct));
        var factors = (await u.Connection.QueryAsync(new CommandDefinition(
            "SELECT * FROM fin.v_CreditAssessmentFactors WHERE AssessmentId = @a ORDER BY SortOrder, MetricCode;", new { a = a.CreditAssessmentId }, cancellationToken: ct)))
            .Cast<IDictionary<string, object?>>().ToList();
        var findings = (await u.Connection.QueryAsync(new CommandDefinition(
            "SELECT * FROM fin.v_CreditAssessmentFindings WHERE AssessmentId = @a ORDER BY SeqNo;", new { a = a.CreditAssessmentId }, cancellationToken: ct)))
            .Cast<IDictionary<string, object?>>().ToList();
        var html = Build(r, factors, findings, ar, clock.GetUtcNow());
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("CREDIT_REPORT_PRINTED", "TREASURY", "fin.CreditAssessment", a.CreditAssessmentId,
            AfterJson: JsonSerializer.Serialize(new { format = asPdf ? "pdf" : "html", lang = ar ? "ar" : "en" })), a.CompanyId, ct);
        http.Response.Headers.CacheControl = "no-store";
        if (asPdf) return await Pdf.FileAsync(pdf, html, $"credit-assessment-{Reference(a.PublicId)}.pdf", ct);
        http.Response.Headers.ContentSecurityPolicy =
            "default-src 'none'; style-src 'unsafe-inline'; img-src data:; " + PrintStyle.FontSource + "; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";
        return Results.Content(html, "text/html; charset=utf-8");
    }

    /// <summary>The report's reference: CA and the first eight characters of the assessment's id.</summary>
    public static string Reference(Guid id) => "CA-" + id.ToString("N")[..8].ToUpperInvariant();

    internal static string Build(IDictionary<string, object?> r, IReadOnlyList<IDictionary<string, object?>> factors, IReadOnlyList<IDictionary<string, object?>> findings,
        bool ar, DateTimeOffset now)
    {
        string T(string a, string e) => ar ? a : e;
        object? V(string k) => r.TryGetValue(k, out var v) ? v : null;
        string? S(string k) => V(k) as string;
        string L(string arKey, string enKey) => (ar ? S(arKey) ?? S(enKey) : S(enKey) ?? S(arKey)) ?? "";

        var company = L("CompanyNameAr", "CompanyNameEn");
        var status = S("Status") ?? "DRAFT";
        var trial = V("IsTrial") is true;
        var approved = status == "APPROVED" && !trial;
        var result = S("ResultState");
        var final = S("FinalGrade") ?? S("FinancialGrade");
        var band = S("RiskBand");
        var reference = Reference((Guid)V("PublicId")!);
        var bandText = band switch
        {
            "LOW" => T("منخفضة", "Low"), "MODERATE" => T("معتدلة", "Moderate"), "SUBSTANTIAL" => T("ملحوظة", "Substantial"),
            "HIGH" => T("مرتفعة", "High"), "VERY_HIGH" => T("مرتفعة جدًا", "Very high"), _ => "",
        };
        var resultText = result switch
        {
            "RATED" => "", "INDICATIVE" => T("درجة مالية مؤشرة فقط: العوامل النوعية ناقصة", "A financial grade only: the qualitative factors are missing"),
            "INSUFFICIENT_DATA" => T("البيانات غير كافية لدرجة", "Not enough data for a grade"), _ => T("لم يُحسب التقييم بعد", "The assessment is not computed yet"),
        };
        var statusText = trial ? T("تقييم تجريبي", "Trial assessment") : status switch
        {
            "APPROVED" => T("معتمد", "Approved"), "SUBMITTED" => T("مقدَّم للاعتماد", "Submitted for approval"), "SUPERSEDED" => T("مستبدل", "Superseded"),
            _ => T("مسودة", "Draft"),
        };
        var internalUse = S("UseScope") != "ENDORSED";
        var mark = approved ? "" : $"<div class=\"mark\">{H(trial ? T("تجريبي — غير معتمد", "TRIAL — NOT APPROVED") : T("مسودة — غير معتمد", "DRAFT — NOT APPROVED"))}</div>";
        var period = $"{H(V("FiscalYear"))} · {H(V("PeriodEnd"))}";

        var b = new StringBuilder();
        b.Append("<!doctype html><html lang=\"").Append(ar ? "ar\" dir=\"rtl" : "en\" dir=\"ltr").Append("\"><head><meta charset=\"utf-8\"><title>")
         .Append(H(reference)).Append("</title><style>").Append(Style).Append("</style></head><body>");

        // The cover (guide p.24): vault green, the pattern with two mint slots, the company as the title.
        b.Append("<section class=\"cover\"><img class=\"logo\" alt=\"BankFas\" src=\"").Append(LogoInverse.Value).Append("\"><div class=\"slants\">");
        for (var i = 0; i < 28; i++) b.Append(i is 9 or 24 ? "<i class=\"lit\"></i>" : "<i></i>");
        b.Append("</div><p class=\"kind\">").Append(T("تقرير تقييم ائتماني", "Credit assessment report")).Append("</p><h1>").Append(H(company)).Append("</h1>")
         .Append("<p class=\"meta\">").Append(T("القوائم المالية", "Financial statements")).Append(' ').Append(period).Append("</p>")
         .Append("<p class=\"meta\"><span class=\"mono\">").Append(H(reference)).Append(" · ").Append(H(V("AssessmentDate"))).Append("</span> · ").Append(H(L("ScorecardNameAr", "ScorecardNameEn"))).Append("</p>");
        b.Append("<div class=\"grade\"><b dir=\"ltr\">").Append(H(final ?? "—")).Append("</b><div><strong>").Append(H(statusText)).Append("</strong>");
        if (bandText.Length > 0) b.Append("<span>").Append(T("درجة المخاطر: ", "Risk: ")).Append(H(bandText)).Append("</span>");
        if (S("Outlook") is not null) b.Append("<span>").Append(T("النظرة: ", "Outlook: ")).Append(H(L("OutlookNameAr", "OutlookNameEn"))).Append("</span>");
        if (resultText.Length > 0) b.Append("<span>").Append(H(resultText)).Append("</span>");
        b.Append("</div></div><div class=\"use\"><span>").Append(internalUse ? T("للاستخدام الداخلي في الشركة", "For the company's internal use") : T("معتمد للعرض على جهات التمويل", "Endorsed for lenders"))
         .Append("</span><span>BankFas</span></div></section>");

        string Head() => $"<div class=\"runhead\"><img alt=\"\" src=\"{Symbol.Value}\"><span>{H(T("تقرير تقييم ائتماني", "Credit assessment report"))} · {H(company)}</span><span dir=\"ltr\" class=\"num\">{H(reference)}</span></div>";
        string Foot() => $"<p class=\"foot\">BankFas · {H(T("طُبع", "Printed"))} {H(now.UtcDateTime.ToString("dd/MM/yyyy HH:mm", CultureInfo.InvariantCulture))} UTC</p>";

        // Page 2: the summary, the grade's steps and the recommendation in the box of its risk band.
        b.Append("<section class=\"page\">").Append(mark).Append(Head()).Append("<h2>").Append(T("الملخص", "Summary")).Append("</h2><div class=\"steps\">");
        foreach (var (k, a, e) in new[] { ("FinancialGrade", "المالية", "Financial"), ("IndicatedGrade", "المؤشرة", "Indicated"), ("StandaloneGrade", "المستقلة", "Standalone"),
                     ("FinalGrade", "النهائية", "Final"), ("FacilityGrade", "التسهيل", "Facility") })
            b.Append(k == "FinalGrade" ? "<div class=\"final\">" : "<div>").Append("<small>").Append(T("الدرجة " + a, e + " grade")).Append("</small><b dir=\"ltr\">")
             .Append(H(S(k) ?? "—")).Append("</b></div>");
        b.Append("</div>");
        var description = L("FinalGradeDescriptionAr", "FinalGradeDescriptionEn");
        b.Append("<div class=\"box ").Append(Tone(band)).Append("\"><h3>").Append(T("درجة المخاطر", "Risk")).Append(": ").Append(H(bandText.Length > 0 ? bandText : resultText)).Append("</h3>");
        if (description.Length > 0) b.Append("<p>").Append(H(description)).Append("</p>");
        b.Append("</div>");
        var summary = L("SummaryAr", "SummaryEn");
        if (summary.Length > 0) b.Append("<p>").Append(H(summary)).Append("</p>");
        b.Append("<div class=\"facts\">");
        void Fact(string a, string e, string? v, bool mono = false)
        {
            if (string.IsNullOrEmpty(v)) return;
            b.Append("<div><small>").Append(T(a, e)).Append("</small>").Append(mono ? "<span class=\"num\" dir=\"ltr\">" : "<span>").Append(H(v)).Append("</span></div>");
        }
        Fact("السيولة", "Liquidity", S("LiquidityLabel") is { } lq ? $"{lq} · {L("LiquidityNameAr", "LiquidityNameEn")}" : null);
        Fact("النظرة", "Outlook", S("Outlook") is null ? null : L("OutlookNameAr", "OutlookNameEn"));
        Fact("القطاع", "Industry", L("IndustryNameAr", "IndustryNameEn"));
        Fact("التغطية", "Coverage", V("CoveragePct") is decimal c ? c.ToString("0.##", CultureInfo.InvariantCulture) + "%" : null, true);
        Fact("الاكتمال", "Completeness", V("CompletenessPct") is decimal p ? p.ToString("0.##", CultureInfo.InvariantCulture) + "%" : null, true);
        Fact("الدرجة المرجعية للمكافئ (استرشادي)", "Indicative equivalent", S("FitchEquivalentIndicative"), true);
        Fact("درجة التأكيد", "Assurance", S("Assurance") switch
        {
            "AUDITED" => T("مدققة", "Audited"), "REVIEWED" => T("مراجعة", "Reviewed"), "MANAGEMENT" => T("إدارية", "Management accounts"), var x => x,
        });
        Fact("المراجع", "Auditor", S("AuditorName"));
        Fact("الحالة", "Status", statusText);
        b.Append("</div>");
        b.Append("<h2>").Append(T("النتائج", "Findings")).Append("</h2><table><tr><th>").Append(T("نقاط القوة", "Strengths")).Append("</th><th>").Append(T("للمراقبة", "To watch"))
         .Append("</th><th>").Append(T("نقاط الضعف", "Weaknesses")).Append("</th><th>").Append(T("مخاطر حرجة", "Critical risks")).Append("</th><th>").Append(T("بيانات مطلوبة", "Data requests"))
         .Append("</th></tr><tr>");
        foreach (var k in new[] { "Strengths", "PointsToWatch", "Weaknesses", "CriticalRisks", "DataRequests" }) b.Append("<td class=\"n\">").Append(H(V(k) ?? 0)).Append("</td>");
        b.Append("</tr></table>").Append(Foot()).Append("</section>");

        // Page 3: the factors with their figures, then the findings by kind, and the methodology's disclaimer.
        b.Append("<section class=\"page\">").Append(mark).Append(Head()).Append("<h2>").Append(T("العوامل", "Factors")).Append("</h2><table><tr><th>")
         .Append(T("العامل", "Factor")).Append("</th><th>").Append(T("المقياس", "Metric")).Append("</th><th>").Append(T("القيمة", "Value")).Append("</th><th>")
         .Append(T("الدرجة", "Grade")).Append("</th><th>").Append(T("الوزن", "Weight")).Append("</th><th>").Append(T("المساهمة", "Contribution")).Append("</th></tr>");
        foreach (var f in factors)
        {
            string F(string k) => f.TryGetValue(k, out var v) ? H(v) : "";
            var factorName = ar ? F("FactorNameAr") : F("FactorCode").Replace('_', ' ');
            var metric = ar ? (f.TryGetValue("MetricNameAr", out var mA) ? H(mA) : "") : (f.TryGetValue("MetricNameEn", out var mE) ? H(mE) : "");
            b.Append("<tr><td>").Append(factorName).Append("</td><td>").Append(metric).Append("</td><td class=\"n\">").Append(F("Value")).Append("</td><td class=\"n\">")
             .Append(F("Grade")).Append("</td><td class=\"n\">").Append(F("EffectiveWeight")).Append("</td><td class=\"n\">").Append(F("Contribution")).Append("</td></tr>");
        }
        if (factors.Count == 0) b.Append("<tr><td colspan=\"6\" class=\"muted\">").Append(T("لم تُحسب العوامل بعد.", "The factors are not computed yet.")).Append("</td></tr>");
        b.Append("</table>");
        foreach (var group in findings.GroupBy(x => x.TryGetValue("KindAr", out var k) ? k as string ?? "" : ""))
        {
            var kindEn = group.First().TryGetValue("Kind", out var ke) ? (ke as string ?? "").Replace('_', ' ') : "";
            b.Append("<p class=\"kind-h\">").Append(H(ar ? group.Key : kindEn)).Append("</p><ul class=\"find\">");
            foreach (var x in group)
                b.Append("<li>").Append(H(ar ? (x.TryGetValue("TextAr", out var ta) ? ta : null) ?? (x.TryGetValue("TextEn", out var te0) ? te0 : null)
                                          : (x.TryGetValue("TextEn", out var te) ? te : null) ?? (x.TryGetValue("TextAr", out var ta0) ? ta0 : null))).Append("</li>");
            b.Append("</ul>");
        }
        var disclaimer = L("DisclaimerAr", "DisclaimerEn");
        if (disclaimer.Length > 0) b.Append("<h2>").Append(T("تنبيه", "Disclaimer")).Append("</h2><p class=\"muted\">").Append(H(disclaimer)).Append("</p>");
        b.Append(Foot()).Append("</section></body></html>");
        return b.ToString();
    }
}

using System.Globalization;
using System.Text;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Workflow;
using Dapper;

namespace BankFas.Api.Endpoints;

/// <summary>
/// The letter of credit reports (spec 14 section 10; FR-LCI-033, FR-LCE-028; S5): R-LCI-01 to 09 for the purchases and
/// R-LCE-01 to 08 for the sales, each read in the user's company scope, as JSON for the screen or as a CSV file. Every
/// report needs lc.report.view; the purchase reports also lc.view.all (and lc.view.internal for those that show the
/// facility's reservation and utilisation), the sales reports lc.export.view; the module of the report must be on. An
/// export is audited (REPORT_EXPORTED) with its filters and row count.
/// </summary>
public static class ReportEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/reports", CatalogAsync);
        api.MapGet("/reports/{code}", RunAsync);
        api.MapGet("/reports/{code}/export", ExportAsync);
    }

    /// <summary>The filters a report reads: the company, a period, a number of days and a status.</summary>
    private sealed record Filters(Guid? Company, DateTime? From, DateTime? To, int Days, string? Status, DateTime Today);

    private sealed record Report(string Code, string Module, string TitleEn, string TitleAr, string[] Needs, string[] Columns, int DefaultDays,
        Func<Filters, string> Sql);

    /// <summary>The company scope of a report's rows on the alias of their table, and the company filter.</summary>
    private static string In(string a) =>
        $"(@scopeAll = 1 OR {a}.CompanyId IN @scope) AND (@company IS NULL OR {a}.CompanyId = (SELECT CompanyId FROM org.Company WHERE PublicId = @company))";

    private const string Purchase = "lc.view.all";
    private const string Internal = "lc.view.internal";
    private const string Sales = "lc.export.view";

    private static readonly Report[] Reports =
    [
        new("R-LCI-01", "LC_PURCHASE", "Register of letters of credit", "سجل الاعتمادات", [Purchase],
            ["lcNumber", "company", "bank", "product", "supplier", "status", "currency", "amount", "issueDate", "expiryDate"], 0, _ => $"""
            SELECT l.LcNumber AS lcNumber, co.NameEn AS company, i.NameEn AS bank, p.Code AS product, cp.NameEn AS supplier, l.Status AS status, cur.Code AS currency,
                   l.Amount AS amount, l.IssueDate AS issueDate, l.ExpiryDate AS expiryDate
              FROM lc.LetterOfCredit AS l JOIN org.Company AS co ON co.CompanyId = l.CompanyId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = l.CounterpartyId
              JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId LEFT JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId
              LEFT JOIN cat.Product AS p ON p.ProductId = l.ProductId
             WHERE l.LcClass = 'PURCHASE' AND {In("l")} AND (@status IS NULL OR l.Status = @status)
             ORDER BY l.IssueDate DESC, l.LetterOfCreditId DESC
            """),
        new("R-LCI-02", "LC_PURCHASE", "Outstanding utilisation per letter of credit", "الاستغلال القائم لكل اعتماد", [Purchase, Internal],
            ["lcNumber", "company", "currency", "exposure", "drawn", "settled", "undrawn", "unsettled", "outstanding", "utilization", "difference"], 0, _ => $"""
            SELECT x.*, x.outstanding - x.utilization AS difference FROM (
            SELECT l.LcNumber AS lcNumber, co.NameEn AS company, cur.Code AS currency, l.ExposureAmount AS exposure, l.DrawnAmount AS drawn, l.SettledAmount AS settled,
                   CASE WHEN l.UndrawnReleasedOn IS NOT NULL OR l.ExposureAmount < l.DrawnAmount THEN 0 ELSE l.ExposureAmount - l.DrawnAmount END AS undrawn,
                   l.DrawnAmount - l.SettledAmount AS unsettled,
                   CASE WHEN l.UndrawnReleasedOn IS NOT NULL OR l.ExposureAmount < l.DrawnAmount THEN 0 ELSE l.ExposureAmount - l.DrawnAmount END + l.DrawnAmount - l.SettledAmount AS outstanding,
                   ISNULL((SELECT u.Amount FROM fac.Utilization AS u WHERE u.UtilizationId = l.UtilizationId AND u.Status = 'ACTIVE'), 0) AS utilization
              FROM lc.LetterOfCredit AS l JOIN org.Company AS co ON co.CompanyId = l.CompanyId JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId
             WHERE l.LcClass = 'PURCHASE' AND l.Status IN ('ACTIVE', 'EXPIRED') AND {In("l")}) AS x
             ORDER BY x.lcNumber
            """),
        new("R-LCI-03", "LC_PURCHASE", "Maturities and payments due", "الاستحقاقات والسداد القادم", [Purchase],
            ["lcNumber", "drawingNo", "company", "currency", "amount", "settled", "unpaid", "maturityDate", "status"], 90, _ => $"""
            SELECT l.LcNumber AS lcNumber, d.DrawingNo AS drawingNo, co.NameEn AS company, cur.Code AS currency, d.Amount AS amount, d.SettledAmount AS settled,
                   d.Amount - d.SettledAmount AS unpaid, d.MaturityDate AS maturityDate, d.Status AS status
              FROM lc.LcDrawing AS d JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = d.LcId JOIN org.Company AS co ON co.CompanyId = d.CompanyId
              JOIN ref.Currency AS cur ON cur.CurrencyId = d.CurrencyId
             WHERE l.LcClass = 'PURCHASE' AND {In("d")} AND d.Status IN ('PRESENTED', 'DISCREPANT', 'ACCEPTED') AND d.MaturityDate IS NOT NULL
               AND d.MaturityDate <= DATEADD(DAY, @days, @today)
             ORDER BY d.MaturityDate, l.LcNumber
            """),
        new("R-LCI-04", "LC_PURCHASE", "Expiries", "الانتهاءات", [Purchase],
            ["lcNumber", "company", "status", "currency", "amount", "undrawn", "unsettled", "expiryDate", "daysLeft"], 30, _ => $"""
            SELECT l.LcNumber AS lcNumber, co.NameEn AS company, l.Status AS status, cur.Code AS currency, l.Amount AS amount,
                   CASE WHEN l.Amount > l.DrawnAmount THEN l.Amount - l.DrawnAmount ELSE 0 END AS undrawn, l.DrawnAmount - l.SettledAmount AS unsettled,
                   l.ExpiryDate AS expiryDate, DATEDIFF(DAY, @today, l.ExpiryDate) AS daysLeft
              FROM lc.LetterOfCredit AS l JOIN org.Company AS co ON co.CompanyId = l.CompanyId JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId
             WHERE l.LcClass = 'PURCHASE' AND {In("l")}
               AND ((l.Status = 'ACTIVE' AND l.ExpiryDate <= DATEADD(DAY, @days, @today)) OR l.Status = 'EXPIRED')
             ORDER BY l.ExpiryDate
            """),
        new("R-LCI-05", "LC_PURCHASE", "Reservations before issuance", "الحجوزات قبل الإصدار", [Purchase, Internal],
            ["requestNo", "company", "facility", "currency", "amount", "ageDays", "expiresOn", "requestStatus", "overLimit"], 0, _ => $"""
            SELECT r.RequestNo AS requestNo, co.NameEn AS company, ISNULL(f.PlatformRef, f.FacilityNo) AS facility, cur.Code AS currency, v.Amount AS amount,
                   DATEDIFF(DAY, CAST(v.CreatedAt AS date), @today) AS ageDays, v.ExpiresOn AS expiresOn, r.Status AS requestStatus, v.OverLimit AS overLimit
              FROM fac.LimitReservation AS v JOIN wfl.Request AS r ON r.RequestId = v.RequestId JOIN org.Company AS co ON co.CompanyId = v.CompanyId
              JOIN fac.Facility AS f ON f.FacilityId = v.FacilityId JOIN ref.Currency AS cur ON cur.CurrencyId = v.CurrencyId
             WHERE v.Status = 'ACTIVE' AND {In("v")}
             ORDER BY v.CreatedAt
            """),
        new("R-LCI-06", "LC_PURCHASE", "Volume of letters of credit", "حجم الاعتمادات", [Purchase],
            ["bank", "product", "supplier", "currency", "count", "amount"], 0, _ => $"""
            SELECT ISNULL(i.NameEn, l.OtherBankText) AS bank, p.Code AS product, cp.NameEn AS supplier, cur.Code AS currency, COUNT(*) AS [count], SUM(l.Amount) AS amount
              FROM lc.LetterOfCredit AS l JOIN lc.Counterparty AS cp ON cp.CounterpartyId = l.CounterpartyId JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId
              LEFT JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId LEFT JOIN cat.Product AS p ON p.ProductId = l.ProductId
             WHERE l.LcClass = 'PURCHASE' AND {In("l")} AND (@from IS NULL OR l.IssueDate >= @from) AND (@to IS NULL OR l.IssueDate <= @to)
             GROUP BY ISNULL(i.NameEn, l.OtherBankText), p.Code, cp.NameEn, cur.Code
             ORDER BY SUM(l.Amount) DESC
            """),
        new("R-LCI-07", "LC_PURCHASE", "Amendments and their effect", "سجل التعديلات وأثرها", [Purchase],
            ["lcNumber", "amendmentNo", "changeKinds", "currency", "amountDelta", "newAmount", "newExpiryDate", "beneficiaryResponse", "status", "appliedOn", "reservationDeltaApplied"], 0,
            _ => $"""
            SELECT l.LcNumber AS lcNumber, a.AmendmentNo AS amendmentNo, a.ChangeKinds AS changeKinds, cur.Code AS currency, a.AmountDelta AS amountDelta, a.NewAmount AS newAmount,
                   a.NewExpiryDate AS newExpiryDate, a.BeneficiaryResponse AS beneficiaryResponse, a.Status AS status, a.AppliedOn AS appliedOn,
                   a.ReservationDeltaApplied AS reservationDeltaApplied
              FROM lc.LcAmendment AS a JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = a.LcId JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId
             WHERE l.LcClass = 'PURCHASE' AND {In("a")} AND (@from IS NULL OR a.CreatedAt >= @from) AND (@to IS NULL OR a.CreatedAt < DATEADD(DAY, 1, @to))
             ORDER BY a.LcAmendmentId DESC
            """),
        new("R-LCI-08", "LC_PURCHASE", "Discrepancies", "المخالفات", [Purchase],
            ["lcNumber", "drawingNo", "description", "status", "raisedOn", "decidedOn", "daysToDecision"], 0, _ => Discrepancies("PURCHASE")),
        new("R-LCI-09", "LC_PURCHASE", "Cycle time from submission to issuance", "زمن الدورة من التقديم إلى الإصدار", [Purchase],
            ["bank", "product", "count", "averageDays", "longestDays"], 0, _ => $"""
            SELECT ISNULL(i.NameEn, N'—') AS bank, ISNULL(p.Code, N'—') AS product, COUNT(*) AS [count],
                   CAST(AVG(CAST(DATEDIFF(DAY, CAST(r.SubmittedAt AS date), l.IssueDate) AS decimal(9, 2))) AS decimal(9, 1)) AS averageDays,
                   MAX(DATEDIFF(DAY, CAST(r.SubmittedAt AS date), l.IssueDate)) AS longestDays
              FROM lc.LetterOfCredit AS l JOIN wfl.Request AS r ON r.RequestId = l.RequestId
              LEFT JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId LEFT JOIN cat.Product AS p ON p.ProductId = l.ProductId
             WHERE l.LcClass = 'PURCHASE' AND {In("l")} AND r.SubmittedAt IS NOT NULL AND l.IssueDate IS NOT NULL
               AND (@from IS NULL OR l.IssueDate >= @from) AND (@to IS NULL OR l.IssueDate <= @to)
             GROUP BY ISNULL(i.NameEn, N'—'), ISNULL(p.Code, N'—')
             ORDER BY bank, product
            """),
        new("R-LCE-01", "LC_SALES", "Active received credits with their balances", "الاعتمادات النشطة بأرصدتها", [Sales],
            ["lcNumber", "company", "customer", "customerCode", "currency", "amount", "earmarked", "drawn", "available", "expiryDate"], 0, _ => $"""
            SELECT l.LcNumber AS lcNumber, co.NameEn AS company, cp.NameEn AS customer, cp.ErpCode AS customerCode, cur.Code AS currency, l.Amount AS amount,
                   l.EarmarkedRemaining AS earmarked, l.DrawnAmount AS drawn, l.Amount - l.EarmarkedRemaining - l.DrawnAmount AS available, l.ExpiryDate AS expiryDate
              FROM lc.LetterOfCredit AS l JOIN org.Company AS co ON co.CompanyId = l.CompanyId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = l.CounterpartyId
              JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId
             WHERE l.LcClass = 'SALES' AND l.Status = 'ACTIVE' AND {In("l")}
             ORDER BY l.ExpiryDate, l.LcNumber
            """),
        new("R-LCE-02", "LC_SALES", "Earmarks not converted", "تخصيصات لم تتحول", [Sales],
            ["lcNumber", "orderRef", "company", "currency", "amount", "converted", "remaining", "orderDate", "ageDays", "status"], 30, _ => $"""
            SELECT l.LcNumber AS lcNumber, o.OrderRef AS orderRef, co.NameEn AS company, cur.Code AS currency, o.Amount AS amount, o.ConvertedAmount AS converted,
                   o.Amount - o.ConvertedAmount - o.ReleasedAmount AS remaining, o.OrderDate AS orderDate, DATEDIFF(DAY, o.OrderDate, @today) AS ageDays, o.Status AS status
              FROM lc.LcSalesOrder AS o JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = o.LcId JOIN org.Company AS co ON co.CompanyId = l.CompanyId
              JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId
             WHERE o.Status IN ('EARMARKED', 'PARTIALLY_CONVERTED') AND {In("l")} AND DATEDIFF(DAY, o.OrderDate, @today) > @days
             ORDER BY o.OrderDate
            """),
        new("R-LCE-03", "LC_SALES", "Register of proformas", "سجل البروفورمات", [Sales],
            ["proformaNo", "company", "customer", "project", "currency", "total", "issueDate", "status", "credits"], 0, _ => $"""
            SELECT p.ProformaNo AS proformaNo, co.NameEn AS company, cp.NameEn AS customer, ISNULL(p.ProjectName, p.ProjectCode) AS project, cur.Code AS currency,
                   p.Total AS total, p.IssueDate AS issueDate, p.Status AS status,
                   (SELECT COUNT(*) FROM lc.LetterOfCredit AS l WHERE l.ProformaId = p.ProformaInvoiceId) AS credits
              FROM lc.ProformaInvoice AS p JOIN org.Company AS co ON co.CompanyId = p.CompanyId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = p.CustomerId
              JOIN ref.Currency AS cur ON cur.CurrencyId = p.CurrencyId
             WHERE {In("p")} AND (@status IS NULL OR p.Status = @status) AND (@from IS NULL OR p.IssueDate >= @from) AND (@to IS NULL OR p.IssueDate <= @to)
             ORDER BY p.IssueDate DESC, p.ProformaInvoiceId DESC
            """),
        new("R-LCE-04", "LC_SALES", "Proformas without a letter of credit", "بروفورمات بلا اعتماد", [Sales],
            ["proformaNo", "company", "customer", "currency", "total", "issueDate", "ageDays"], 30, _ => $"""
            SELECT p.ProformaNo AS proformaNo, co.NameEn AS company, cp.NameEn AS customer, cur.Code AS currency, p.Total AS total, p.IssueDate AS issueDate,
                   DATEDIFF(DAY, p.IssueDate, @today) AS ageDays
              FROM lc.ProformaInvoice AS p JOIN org.Company AS co ON co.CompanyId = p.CompanyId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = p.CustomerId
              JOIN ref.Currency AS cur ON cur.CurrencyId = p.CurrencyId
             WHERE p.Status = 'ISSUED' AND {In("p")} AND DATEDIFF(DAY, p.IssueDate, @today) > @days
               AND NOT EXISTS (SELECT 1 FROM lc.LetterOfCredit AS l WHERE l.ProformaId = p.ProformaInvoiceId)
             ORDER BY p.IssueDate
            """),
        new("R-LCE-05", "LC_SALES", "Expiry and latest shipment of received credits", "انتهاء الاعتمادات المستلَمة وآخر شحنها", [Sales],
            ["lcNumber", "company", "customer", "currency", "expiryDate", "latestShipmentDate", "daysLeft", "openOrders", "earmarked"], 30, _ => $"""
            SELECT l.LcNumber AS lcNumber, co.NameEn AS company, cp.NameEn AS customer, cur.Code AS currency, l.ExpiryDate AS expiryDate, l.LatestShipmentDate AS latestShipmentDate,
                   DATEDIFF(DAY, @today, l.ExpiryDate) AS daysLeft,
                   (SELECT COUNT(*) FROM lc.LcSalesOrder AS o WHERE o.LcId = l.LetterOfCreditId AND o.Status IN ('EARMARKED', 'PARTIALLY_CONVERTED')) AS openOrders,
                   l.EarmarkedRemaining AS earmarked
              FROM lc.LetterOfCredit AS l JOIN org.Company AS co ON co.CompanyId = l.CompanyId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = l.CounterpartyId
              JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId
             WHERE l.LcClass = 'SALES' AND l.Status = 'ACTIVE' AND {In("l")}
               AND (l.ExpiryDate <= DATEADD(DAY, @days, @today) OR l.LatestShipmentDate <= DATEADD(DAY, @days, @today))
             ORDER BY l.ExpiryDate
            """),
        new("R-LCE-06", "LC_SALES", "Drawings and collection", "السحوبات والتحصيل", [Sales],
            ["lcNumber", "drawingNo", "company", "currency", "amount", "presentationDate", "status", "settled", "lastSettledOn"], 0, _ => $"""
            SELECT l.LcNumber AS lcNumber, d.DrawingNo AS drawingNo, co.NameEn AS company, cur.Code AS currency, d.Amount AS amount, d.PresentationDate AS presentationDate,
                   d.Status AS status, d.SettledAmount AS settled, d.LastSettledOn AS lastSettledOn
              FROM lc.LcDrawing AS d JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = d.LcId JOIN org.Company AS co ON co.CompanyId = d.CompanyId
              JOIN ref.Currency AS cur ON cur.CurrencyId = d.CurrencyId
             WHERE l.LcClass = 'SALES' AND {In("d")} AND (@status IS NULL OR d.Status = @status)
               AND (@from IS NULL OR d.PresentationDate >= @from) AND (@to IS NULL OR d.PresentationDate <= @to)
             ORDER BY d.PresentationDate DESC, l.LcNumber
            """),
        new("R-LCE-07", "LC_SALES", "Discrepancies and amendments", "المخالفات والتعديلات", [Sales],
            ["kind", "lcNumber", "reference", "detail", "status", "raisedOn", "decidedOn"], 0, _ => $"""
            SELECT u.* FROM (
            SELECT N'DISCREPANCY' AS kind, l.LcNumber AS lcNumber, CAST(d.DrawingNo AS nvarchar(20)) AS reference, x.Description AS detail, x.Status AS status,
                   CAST(x.CreatedAt AS date) AS raisedOn, CAST(x.DecidedOn AS date) AS decidedOn
              FROM lc.LcDiscrepancy AS x JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = x.LcId LEFT JOIN lc.LcDrawing AS d ON d.LcDrawingId = x.DrawingId
             WHERE l.LcClass = 'SALES' AND {In("l")}
            UNION ALL
            SELECT N'AMENDMENT', l.LcNumber, CAST(a.AmendmentNo AS nvarchar(20)), a.ChangeKinds, a.Status, CAST(a.CreatedAt AS date), a.AppliedOn
              FROM lc.LcAmendment AS a JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = a.LcId
             WHERE l.LcClass = 'SALES' AND {In("l")}) AS u
             ORDER BY u.raisedOn DESC
            """),
        new("R-LCE-08", "LC_SALES", "Balance invariant check", "مطابقة ثوابت الرصيد", [Sales],
            ["lcNumber", "company", "currency", "amount", "earmarked", "earmarkedByOrders", "drawn", "drawnByDrawings", "available"], 0, _ => $"""
            SELECT x.* FROM (
            SELECT l.LcNumber AS lcNumber, co.NameEn AS company, cur.Code AS currency, l.Amount AS amount, l.EarmarkedRemaining AS earmarked,
                   ISNULL((SELECT SUM(o.Amount - o.ConvertedAmount - o.ReleasedAmount) FROM lc.LcSalesOrder AS o
                            WHERE o.LcId = l.LetterOfCreditId AND o.Status IN ('EARMARKED', 'PARTIALLY_CONVERTED')), 0) AS earmarkedByOrders,
                   l.DrawnAmount AS drawn,
                   ISNULL((SELECT SUM(d.Amount) FROM lc.LcDrawing AS d WHERE d.LcId = l.LetterOfCreditId AND d.Status NOT IN ('REFUSED', 'CANCELLED')), 0) AS drawnByDrawings,
                   l.Amount - l.EarmarkedRemaining - l.DrawnAmount AS available
              FROM lc.LetterOfCredit AS l JOIN org.Company AS co ON co.CompanyId = l.CompanyId JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId
             WHERE l.LcClass = 'SALES' AND l.Status IN ('ACTIVE', 'EXPIRED') AND {In("l")}) AS x
             WHERE x.available < 0 OR x.earmarked < x.earmarkedByOrders OR x.drawn <> x.drawnByDrawings
             ORDER BY x.lcNumber
            """),
    ];

    private static string Discrepancies(string lcClass) => $"""
        SELECT l.LcNumber AS lcNumber, d.DrawingNo AS drawingNo, x.Description AS description, x.Status AS status, CAST(x.CreatedAt AS date) AS raisedOn,
               CAST(x.DecidedOn AS date) AS decidedOn, CASE WHEN x.DecidedOn IS NULL THEN NULL ELSE DATEDIFF(DAY, x.CreatedAt, x.DecidedOn) END AS daysToDecision
          FROM lc.LcDiscrepancy AS x JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = x.LcId LEFT JOIN lc.LcDrawing AS d ON d.LcDrawingId = x.DrawingId
         WHERE l.LcClass = '{lcClass}' AND {In("l")} AND (@status IS NULL OR x.Status = @status)
         ORDER BY x.CreatedAt DESC
        """;

    /// <summary>Whether the user may read a report: its permissions and its module.</summary>
    private static async Task<bool> MayAsync(BoundUser u, Report r, IReadOnlySet<string> perms, CancellationToken ct) =>
        perms.Contains("lc.report.view") && r.Needs.All(perms.Contains) && await u.ModuleEnabledAsync(r.Module, ct);

    /// <summary>The reports this user may read, with their filters.</summary>
    private static async Task<IResult> CatalogAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var perms = await u.PermissionsAsync(ct);
        var items = new List<object>();
        foreach (var r in Reports)
            if (await MayAsync(u, r, perms, ct))
                items.Add(new { code = r.Code, titleEn = r.TitleEn, titleAr = r.TitleAr, columns = r.Columns, defaultDays = r.DefaultDays > 0 ? r.DefaultDays : (int?)null });
        return Results.Ok(new { items });
    }

    private static async Task<(BoundUser U, Report R, Filters F, List<IDictionary<string, object?>> Rows)> ReadAsync(string code, HttpContext http, SqlConnectionFactory db,
        TimeProvider clock, int max)
    {
        Query.Allow(http.Request, "company", "from", "to", "days", "status", "format");
        var report = Reports.FirstOrDefault(x => string.Equals(x.Code, code, StringComparison.OrdinalIgnoreCase)) ?? throw ApiProblemException.NotFound();
        var u = await BoundUser.OpenAsync(http, db);
        try
        {
            var ct = http.RequestAborted;
            if (!await MayAsync(u, report, await u.PermissionsAsync(ct), ct)) throw ApiProblemException.Forbidden();
            DateTime? Date(string k) => http.Request.Query[k].ToString() is { Length: > 0 } s
                ? DateTime.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
                : throw ApiProblemException.Invalid("VALIDATION_FAILED", "Dates are YYYY-MM-DD.")
                : null;
            var days = http.Request.Query["days"].ToString() is { Length: > 0 } ds
                ? int.TryParse(ds, NumberStyles.None, CultureInfo.InvariantCulture, out var n) && n is >= 0 and <= 3650 ? n
                : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The days are 0 to 3650.")
                : report.DefaultDays;
            var f = new Filters(Guid.TryParse(http.Request.Query["company"], out var co) ? co : null, Date("from"), Date("to"), days,
                http.Request.Query["status"].ToString() is { Length: > 0 } st ? st.Trim().ToUpperInvariant() : null,
                await Delegations.TodayAsync(u.Connection, null, clock.GetUtcNow(), ct));
            var scope = await CompanyScope.OfAsync(u, ct);
            var p = new DynamicParameters(new { scopeAll = scope.All, scope = scope.SqlIds, company = f.Company, from = f.From, to = f.To, days = f.Days, status = f.Status, today = f.Today, max });
            var rows = (await u.Connection.QueryAsync(new CommandDefinition(Top(report.Sql(f)) + ";", p, cancellationToken: ct)))
                .Select(r => (IDictionary<string, object?>)r).ToList();
            return (u, report, f, rows);
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }

    /// <summary>The report's query with TOP (@max) on its outer SELECT.</summary>
    private static string Top(string sql)
    {
        var i = sql.IndexOf("SELECT ", StringComparison.Ordinal);
        return sql[..i] + "SELECT TOP (@max) " + sql[(i + 7)..];
    }

    private static async Task<IResult> RunAsync(string code, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var (u, report, f, rows) = await ReadAsync(code, http, db, clock, 1001);
        await using (u)
        {
            var more = rows.Count > 1000;
            return Results.Ok(new
            {
                code = report.Code, titleEn = report.TitleEn, titleAr = report.TitleAr, columns = report.Columns, days = f.Days, asOf = f.Today,
                items = rows.Take(1000), truncated = more,
            });
        }
    }

    private static async Task<IResult> ExportAsync(string code, HttpContext http, SqlConnectionFactory db, TimeProvider clock, PdfRenderer pdf)
    {
        // CSV by default; format=pdf prints the report as a table (docs/31 row 52), at most 5,000 rows.
        var asPdf = http.Request.Query["format"].ToString() switch
        {
            "" or "csv" => false,
            "pdf" => true,
            _ => throw ApiProblemException.Invalid("VALIDATION_FAILED", "The format is csv or pdf."),
        };
        var (u, report, f, rows) = await ReadAsync(code, http, db, clock, asPdf ? 5_000 : 100_000);
        await using (u)
        {
            if (asPdf)
            {
                var arabic = await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT PreferredLanguage FROM sec.AppUser WHERE AppUserId = @u;",
                    new { u = u.UserId }, cancellationToken: http.RequestAborted)) == "ar";
                await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("REPORT_EXPORTED", "TREASURY", "report", null,
                    AfterJson: JsonSerializer.Serialize(new { report = report.Code, format = "pdf", company = f.Company, from = f.From, to = f.To, days = f.Days, status = f.Status, rows = rows.Count })),
                    null, http.RequestAborted);
                return await Pdf.FileAsync(pdf, Html(report, rows, f, arabic), $"{report.Code}-{f.Today:yyyyMMdd}.pdf", http.RequestAborted);
            }
            var csv = new StringBuilder(string.Join(',', report.Columns)).Append("\r\n");
            foreach (var r in rows)
                csv.AppendJoin(',', report.Columns.Select(c => Csv(r.TryGetValue(c, out var v) ? v : null))).Append("\r\n");
            await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("REPORT_EXPORTED", "TREASURY", "report", null,
                AfterJson: JsonSerializer.Serialize(new { report = report.Code, company = f.Company, from = f.From, to = f.To, days = f.Days, status = f.Status, rows = rows.Count })),
                null, http.RequestAborted);
            return Results.File(Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(csv.ToString())).ToArray(), "text/csv; charset=utf-8",
                $"{report.Code}-{f.Today:yyyyMMdd}.csv");
        }
    }

    private static string Html(Report report, List<IDictionary<string, object?>> rows, Filters f, bool arabic)
    {
        static string E(object? v) => System.Net.WebUtility.HtmlEncode(v switch
        {
            null => "",
            DateTime d => d.TimeOfDay == TimeSpan.Zero ? d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : d.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture),
            decimal m => m.ToString("#,0.##", CultureInfo.InvariantCulture),
            IFormattable x => x.ToString(null, CultureInfo.InvariantCulture),
            _ => v.ToString() ?? "",
        });
        var sb = new StringBuilder();
        sb.Append(CultureInfo.InvariantCulture, $"<!doctype html><html lang=\"{(arabic ? "ar" : "en")}\" dir=\"{(arabic ? "rtl" : "ltr")}\"><head><meta charset=\"utf-8\"><style>")
          .Append(BankFas.Data.PrintStyle.Base).Append("@page{size:A4 landscape;margin:1cm}body{font-size:8.5pt}h1{font-size:13pt;border-bottom:2px solid #00A97F;padding-bottom:4px}")
          .Append("td,th{padding:2px 4px}td.n{direction:ltr;text-align:end}</style></head><body>")
          .Append(CultureInfo.InvariantCulture, $"<h1>{E(report.Code)} · {E(arabic ? report.TitleAr : report.TitleEn)}</h1><p>{E(f.Today)} · {rows.Count}</p><table><tr>");
        foreach (var c in report.Columns) sb.Append("<th>").Append(E(c)).Append("</th>");
        sb.Append("</tr>");
        foreach (var r in rows)
        {
            sb.Append("<tr>");
            foreach (var c in report.Columns)
            {
                var v = r.TryGetValue(c, out var x) ? x : null;
                sb.Append(v is decimal or int or long or double ? "<td class=\"n\">" : "<td>").Append(E(v)).Append("</td>");
            }
            sb.Append("</tr>");
        }
        return sb.Append("</table></body></html>").ToString();
    }

    /// <summary>A CSV field; text that starts with =, +, - or @ is prefixed with ' so a spreadsheet never runs it as a formula.</summary>
    private static string Csv(object? v)
    {
        var s = v switch
        {
            null => "",
            DateTime d => d.TimeOfDay == TimeSpan.Zero ? d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : d.ToString("O", CultureInfo.InvariantCulture),
            bool b => b ? "1" : "0",
            IFormattable x => x.ToString(null, CultureInfo.InvariantCulture),
            _ => v.ToString() ?? "",
        };
        if (s.Length == 0) return "";
        if (v is string && s[0] is '=' or '+' or '-' or '@') s = "'" + s;
        return "\"" + s.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
    }
}

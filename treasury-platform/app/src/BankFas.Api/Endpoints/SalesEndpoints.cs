using System.Globalization;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Lc;
using BankFas.Core.Text;
using BankFas.Data;
using BankFas.Data.Lc;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record ProformaIssueBody(Guid? ProceedsAccount, string? PrintLanguage);
public sealed record ProformaVoidBody(string? Reason, string? StepUpCode);

/// <summary>
/// The sales of S4 (spec 14 section 4.3, screens 16 and 17): the proforma's totals while it is prepared, the treasury's
/// choices at its issue (the proceeds account among the company's LC_COLLECTION accounts, SVC-06, and the print
/// language), the register of proformas with its search (number, customer by code or name, project, company, status,
/// whether a credit came), the card, the void by the treasury manager and the copy of a proforma request
/// (FR-REQ-025). The module is LC_SALES. A holder of lc.view.all sees the proformas of their company scope; a holder of
/// lc.view.own those of their own requests.
/// </summary>
public static class SalesEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/sales/proformas", ProformasAsync);
        api.MapGet("/sales/proformas/{id:guid}", ProformaAsync);
        api.MapPost("/sales/proformas/{id:guid}/void", VoidAsync);
        api.MapGet("/sales/proceeds-accounts", ProceedsAccountsAsync);
        api.MapGet("/requests/{id:guid}/proforma-totals", TotalsAsync);
        api.MapPut("/requests/{id:guid}/proforma-issue", PutIssueAsync);
    }

    internal static async Task<BoundUser> OpenAsync(HttpContext http, SqlConnectionFactory db, string? permission = null)
    {
        var u = permission is null ? await BoundUser.OpenAsync(http, db) : await BoundUser.OpenAsync(http, db, permission);
        try
        {
            await u.RequireModuleAsync("LC_SALES", http.RequestAborted);
            await u.PermissionsAsync(http.RequestAborted);
            return u;
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }

    /// <summary>Who sees which proformas: the treasury (lc.view.all) those of its company scope; the sales (lc.view.own) those of their own requests.</summary>
    internal static async Task<DynamicParameters> ScopeAsync(BoundUser u, CancellationToken ct, SqlTransaction? tx = null)
    {
        var perms = await u.PermissionsAsync(ct);
        var scope = await CompanyScope.OfAsync(u, ct, tx);
        var all = perms.Contains("lc.view.all");
        if (!all && !perms.Contains("lc.view.own")) throw ApiProblemException.Forbidden();
        return new DynamicParameters(new { all, scopeAll = scope.All, scope = scope.SqlIds, u = u.UserId });
    }

    private const string ProformaVisible = """
        ((@all = 1 AND (@scopeAll = 1 OR p.CompanyId IN @scope))
         OR EXISTS (SELECT 1 FROM wfl.Request AS own WHERE own.RequestId = p.RequestId AND (own.RequesterUserId = @u OR own.CreatedByUserId = @u)))
        """;

    private static string Like(string q) => "%" + q.Replace("[", "[[]", StringComparison.Ordinal).Replace("%", "[%]", StringComparison.Ordinal).Replace("_", "[_]", StringComparison.Ordinal) + "%";

    /// <summary>FR-LCE-008: the register, searched by number, customer code or name, project or request number; with the credits received for each.</summary>
    private static async Task<IResult> ProformasAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "q", "status", "company", "hasLc", "limit");
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        var p = await ScopeAsync(u, ct);
        var q = http.Request.Query["q"].ToString().Trim();
        p.Add("q", q.Length == 0 ? null : Like(q));
        p.Add("nq", q.Length == 0 ? null : Like(Normalizer.Name(q)));
        p.Add("eq", q.Length == 0 ? null : RequestEndpoints.NormaliseRef(q));
        p.Add("status", http.Request.Query["status"].ToString() is { Length: > 0 } s ? s.ToUpperInvariant() : null);
        p.Add("company", Guid.TryParse(http.Request.Query["company"], out var co) ? co : null);
        p.Add("hasLc", http.Request.Query["hasLc"].ToString() switch { "true" => 1, "false" => 0, _ => (int?)null });
        p.Add("take", Query.Limit(http.Request));
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT TOP (@take) p.PublicId AS id, p.ProformaNo AS proformaNo, p.Status AS status, p.IssueDate AS issueDate, cur.Code AS currency, p.Total AS total,
                   p.ProjectCode AS projectCode, p.ProjectName AS projectName, cp.NameEn AS customerNameEn, cp.NameAr AS customerNameAr, cp.ErpCode AS customerCode,
                   co.NameEn AS companyNameEn, co.NameAr AS companyNameAr, r.RequestNo AS requestNo, r.PublicId AS requestId,
                   (SELECT COUNT(*) FROM lc.LetterOfCredit AS l WHERE l.ProformaId = p.ProformaInvoiceId) AS credits,
                   CASE WHEN p.OfferValidityDays IS NULL THEN NULL ELSE DATEADD(DAY, p.OfferValidityDays, p.IssueDate) END AS validUntil
              FROM lc.ProformaInvoice AS p JOIN ref.Currency AS cur ON cur.CurrencyId = p.CurrencyId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = p.CustomerId
              JOIN org.Company AS co ON co.CompanyId = p.CompanyId JOIN wfl.Request AS r ON r.RequestId = p.RequestId
             WHERE {ProformaVisible} AND (@status IS NULL OR p.Status = @status) AND (@company IS NULL OR co.PublicId = @company)
               AND (@hasLc IS NULL OR (@hasLc = 1 AND EXISTS (SELECT 1 FROM lc.LetterOfCredit AS l WHERE l.ProformaId = p.ProformaInvoiceId))
                    OR (@hasLc = 0 AND NOT EXISTS (SELECT 1 FROM lc.LetterOfCredit AS l WHERE l.ProformaId = p.ProformaInvoiceId)))
               AND (@q IS NULL OR p.ProformaNo LIKE @q OR cp.NameNormalized LIKE @nq OR cp.ErpCodeNormalized = @eq OR p.ProjectCode LIKE @q OR p.ProjectName LIKE @q
                    OR r.RequestNo LIKE @q)
             ORDER BY p.IssueDate DESC, p.ProformaInvoiceId DESC;
            """, p, cancellationToken: ct));
        return Results.Ok(new { items = rows });
    }

    private static async Task<long> ProformaIdAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct)
    {
        var p = await ScopeAsync(u, ct, tx);
        p.Add("id", id);
        return await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                   $"SELECT p.ProformaInvoiceId FROM lc.ProformaInvoice AS p WHERE p.PublicId = @id AND {ProformaVisible};", p, tx, cancellationToken: ct))
               ?? throw ApiProblemException.NotFound();
    }

    /// <summary>The card: the header, the lines, the customer as issued, the document, and the credits received against it (BR-LCE-018).</summary>
    private static async Task<IResult> ProformaAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request);
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        var pid = await ProformaIdAsync(u, null, id, ct);
        var head = await u.Connection.QuerySingleAsync(new CommandDefinition(
            """
            SELECT p.PublicId AS id, p.ProformaNo AS proformaNo, p.Status AS status, p.VoidReason AS voidReason, p.IssueDate AS issueDate, p.OfferValidityDays AS offerValidityDays,
                   cur.Code AS currency, cur.Decimals AS decimals, p.Subtotal AS subtotal, p.VatRatePct AS vatRatePct, p.VatAmount AS vatAmount, p.Total AS total,
                   p.LcPaymentPct AS lcPaymentPct, p.BranchCode AS branchCode, p.BranchName AS branchName, p.ProjectCode AS projectCode, p.ProjectName AS projectName,
                   p.ProjectSite AS projectSite, p.PlacesJson AS places, p.CustomerSnapshotJson AS customer, p.PrintLanguage AS printLanguage, d.PublicId AS documentId,
                   co.NameEn AS companyNameEn, co.NameAr AS companyNameAr, r.RequestNo AS requestNo, r.PublicId AS requestId, s.ProformaNo AS supersededBy, t.Amount AS lcAmount
              FROM lc.ProformaInvoice AS p JOIN ref.Currency AS cur ON cur.CurrencyId = p.CurrencyId JOIN doc.Document AS d ON d.DocumentId = p.DocumentId
              JOIN org.Company AS co ON co.CompanyId = p.CompanyId JOIN wfl.Request AS r ON r.RequestId = p.RequestId JOIN lc.LcTerms AS t ON t.LcTermsId = p.TermsId
              LEFT JOIN lc.ProformaInvoice AS s ON s.ProformaInvoiceId = p.SupersededById
             WHERE p.ProformaInvoiceId = @pid;
            """, new { pid }, cancellationToken: ct));
        var lines = await u.Connection.QueryAsync(new CommandDefinition(
            "SELECT [LineNo] AS [lineNo], Description AS description, Qty AS qty, UnitCode AS unitCode, UnitPrice AS unitPrice, LineTotal AS lineTotal, Notes AS notes FROM lc.ProformaLine WHERE ProformaId = @pid ORDER BY [LineNo];",
            new { pid }, cancellationToken: ct));
        var credits = await u.Connection.QueryAsync(new CommandDefinition(
            "SELECT l.PublicId AS id, l.LcNumber AS lcNumber, l.Status AS status, l.Amount AS amount, l.ReceivedDate AS receivedDate FROM lc.LetterOfCredit AS l WHERE l.ProformaId = @pid ORDER BY l.ReceivedDate;",
            new { pid }, cancellationToken: ct));
        return Results.Ok(new { proforma = head, lines, credits });
    }

    /// <summary>BR-LCE-003: the void, by a holder of lc.proforma.void with a fresh proof, audited HIGH; the number stays used.</summary>
    private static async Task<IResult> VoidAsync(Guid id, ProformaVoidBody b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, TimeProvider clock)
    {
        await using (var check = await OpenAsync(http, db, "lc.proforma.void")) { }
        await StepUp.RequireAsync(http, db, keys, clock, b.StepUpCode);
        await using var u = await OpenAsync(http, db, "lc.proforma.void");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        var pid = await ProformaIdAsync(u, tx, id, ct);
        await ProformaStore.VoidAsync(u.Connection, tx, actor, pid, b.Reason ?? "", ct);
        var (no, company) = await u.Connection.QuerySingleAsync<(string, long)>(new CommandDefinition(
            "SELECT ProformaNo, CompanyId FROM lc.ProformaInvoice WHERE ProformaInvoiceId = @pid;", new { pid }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("PROFORMA_VOIDED", "TREASURY", "lc.ProformaInvoice", pid,
            AfterJson: JsonSerializer.Serialize(new { proformaNo = no, reason = b.Reason?.Trim() }), Severity: "HIGH"), company, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "VOID", proformaNo = no });
    }

    /// <summary>SVC-06 (FR-ACC-011): the company's active letter of credit collection accounts, for the proceeds of a proforma.</summary>
    private static async Task<IResult> ProceedsAccountsAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company", "currency");
        await using var u = await OpenAsync(http, db, "lc.proforma.issue");
        var ct = http.RequestAborted;
        if (!Guid.TryParse(http.Request.Query["company"], out var company)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the company.");
        var scope = await CompanyScope.OfAsync(u, ct);
        var rows = (await u.Connection.QueryAsync<(long CompanyId, Guid Id, string? Nickname, string AccountNoMask, string? IbanMask, string Currency, string BankEn, string BankAr)>(
            new CommandDefinition(
                """
                SELECT a.CompanyId, a.PublicId, a.Nickname, a.AccountNoMask, a.IbanMask, cur.Code, i.NameEn, i.NameAr
                  FROM acc.BankAccount AS a JOIN org.Company AS co ON co.CompanyId = a.CompanyId JOIN cat.AccountType AS t ON t.AccountTypeId = a.AccountTypeId
                  JOIN ref.Currency AS cur ON cur.CurrencyId = a.CurrencyId JOIN ins.Institution AS i ON i.InstitutionId = a.InstitutionId
                 WHERE co.PublicId = @company AND a.Status = 'ACTIVE' AND t.Code = 'LC_COLLECTION'
                 ORDER BY CASE WHEN cur.Code = @currency THEN 0 ELSE 1 END, i.NameEn;
                """, new { company, currency = http.Request.Query["currency"].ToString() }, cancellationToken: ct)))
            .Where(r => scope.Allows(r.CompanyId))
            .Select(r => new { id = r.Id, nickname = r.Nickname, accountNo = r.AccountNoMask, iban = r.IbanMask, currency = r.Currency, bankNameEn = r.BankEn, bankNameAr = r.BankAr });
        return Results.Ok(new { items = rows });
    }

    /// <summary>
    /// The totals of a proforma request as its form stands (BR-LCE-001): the lines, the VAT at the rate in force today and
    /// the credit's amount; for the preparer while editing and for the treasury at the issue.
    /// </summary>
    private static async Task<IResult> TotalsAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request);
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        var r = await RequestAsync(u, null, id, ct);
        var form = ProformaStore.Parse(r.FormDataJson);
        var t = await TermsStore.CurrentAsync(u.Connection, null, r.RequestId, ct);
        var decimals = t?.CurrencyId is { } c
            ? await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT Decimals FROM ref.Currency WHERE CurrencyId = @c;", new { c }, cancellationToken: ct))
            : 2;
        var today = await Delegations.TodayAsync(u.Connection, null, clock.GetUtcNow(), ct);
        var rate = await ProformaStore.VatRateAsync(u.Connection, null, r.CompanyId, today, ct);
        if (rate is null) return Results.Ok(new { vatRatePct = (decimal?)null, problem = "V-LCE-02" });
        try
        {
            var totals = SalesRules.Totals(form.Lines, rate.Value, form.LcPaymentPct, decimals);
            return Results.Ok(new
            {
                lines = totals.Lines.Select(l => new { l.LineNo, l.LineTotal }), totals.Subtotal, vatRatePct = totals.VatRatePct, totals.VatAmount, totals.Total, totals.LcAmount,
                currency = t?.CurrencyId is null ? null : await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition("SELECT Code FROM ref.Currency WHERE CurrencyId = @c;",
                    new { c = t.CurrencyId }, cancellationToken: ct)),
            });
        }
        catch (ArgumentException ex)
        {
            return Results.Ok(new { vatRatePct = rate, problem = "V-LCE-03", message = ex.Message.Split(" (Parameter", 2)[0] });
        }
    }

    /// <summary>A proforma request visible to the user: its requester or creator, an approver, or the treasury of its company.</summary>
    private static async Task<RequestEngine.RequestRow> RequestAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct)
    {
        var rid = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT RequestId FROM wfl.Request WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct));
        var r = rid is { } x ? await RequestEngine.FindAsync(u.Connection, tx, x, tx is not null, ct) : null;
        if (r is null || r.TypeCode != "PROFORMA_REQUEST") throw ApiProblemException.NotFound();
        var perms = await u.PermissionsAsync(ct);
        var scope = await CompanyScope.OfAsync(u, ct, tx);
        var involved = u.UserId == r.RequesterUserId || u.UserId == r.CreatedByUserId
            || ((perms.Contains("req.view.all") || perms.Contains("lc.export.view")) && scope.Allows(r.CompanyId))
            || await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM wfl.RequestApproval WHERE RequestId = @r AND (AssignedUserId = @u OR ActedByUserId = @u);", new { r = r.RequestId, u = u.UserId }, tx,
                cancellationToken: ct)) > 0;
        if (!involved) throw ApiProblemException.NotFound();
        return r;
    }

    /// <summary>FR-LCE-005: the treasury's choices at the issue, by the assignee of ISSUE_PROFORMA; read by lc.issue_proforma when the stage completes.</summary>
    private static async Task<IResult> PutIssueAsync(Guid id, ProformaIssueBody b, HttpContext http, SqlConnectionFactory db)
    {
        var lang = b.PrintLanguage?.Trim().ToLowerInvariant() ?? "both";
        if (lang is not ("ar" or "en" or "both") || b.ProceedsAccount is null)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the proceeds account and the print language (ar, en or both).");
        await using var u = await OpenAsync(http, db, "lc.proforma.issue");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await RequestAsync(u, tx, id, ct);
        var inst = await RequestEngine.CurrentInstanceAsync(u.Connection, tx, r.RequestId, ct);
        if (inst is not { StageKey: "ISSUE_PROFORMA", Status: "CLAIMED" } || inst.AssigneeUserId != u.UserId)
            throw new ApiProblemException(409, "INVALID_STATE", "The issue is prepared by the assignee of the issue stage.");
        var ok = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT COUNT(*) FROM acc.BankAccount AS a JOIN cat.AccountType AS t ON t.AccountTypeId = a.AccountTypeId
             WHERE a.PublicId = @a AND a.CompanyId = @co AND a.Status = 'ACTIVE' AND t.Code = 'LC_COLLECTION';
            """, new { a = b.ProceedsAccount, co = r.CompanyId }, tx, cancellationToken: ct));
        if (ok == 0) throw ApiProblemException.Invalid("V-LCE-04", "Choose an active letter of credit collection account of the company (BR-LCE-004).");
        var json = JsonSerializer.Serialize(new { proceedsAccount = b.ProceedsAccount, printLanguage = lang });
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.Request SET FormDataJson = JSON_MODIFY(ISNULL(FormDataJson, N'{}'), '$.proformaIssue', JSON_QUERY(@j)), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE RequestId = @r;
            """, new { j = json, u = u.UserId, r = r.RequestId }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        var rv = await u.Connection.ExecuteScalarAsync<byte[]>(new CommandDefinition("SELECT RowVersion FROM wfl.Request WHERE PublicId = @id;", new { id }, cancellationToken: ct));
        ETags.Set(http.Response, rv ?? []);
        return Results.Ok(new { proceedsAccount = b.ProceedsAccount, printLanguage = lang });
    }

    internal static string Money(decimal v, int decimals) => v.ToString("N" + decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
}

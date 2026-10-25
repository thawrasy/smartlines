using System.Data;
using System.Globalization;
using System.Text.Json;
using BankFas.Core.Lc;
using BankFas.Data.Notifications;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Lc;

/// <summary>A document the platform writes itself (the issued proforma): stored encrypted like an upload, with its type, owner company and link.</summary>
public sealed record GeneratedDocument(string TypeCode, long CompanyId, string Title, string? Number, DateTime? IssueDate, string FileName, string ContentType, byte[] Content,
    string LinkEntityType, long LinkEntityId);

/// <summary>
/// What the issue of a proforma needs from the application, which holds the tenant's keys and the file store: the IBAN
/// of the proceeds account in clear, printed for the customer on purpose (BR-LCE-004), and the store of the printed
/// document (FR-LCE-005). The API registers it when it starts.
/// </summary>
public interface IProformaServices
{
    Task<string?> AccountIbanAsync(SqlConnection c, SqlTransaction tx, long bankAccountId, CancellationToken ct);

    Task<long> StoreAsync(SqlConnection c, SqlTransaction tx, GeneratedDocument document, CancellationToken ct);
}

/// <summary>
/// Proformas (spec 14 section 4.3, FR-LCE-001 to 008; BR-LCE-001 to 006; S4 batch B). The request PROFORMA_REQUEST
/// carries the proforma in its form (key "proforma": the customer, branch, project, offer validity, the part paid by
/// credit, the places and the lines) and the terms asked of the customer (lc.LcTerms, purpose PROFORMA). At the
/// submission the terms take the customer as applicant and their amount from the lines, the tax rate in force and the
/// part paid by credit. lc.issue_proforma, on the treasury's completion of ISSUE_PROFORMA, writes in one transaction
/// the number {seq:000}-{erp}-{yy} of the company's gap-free sequence, the lines (once, in one statement, 044), a locked
/// copy of the terms, the snapshot of the customer, the proceeds account and the printed document; the proforma never
/// changes after (043). A treasury manager voids it with a reason and its number stays used; a copy of its request
/// issues a successor with a new number and the earlier one becomes SUPERSEDED (BR-LCE-003).
/// </summary>
public static class ProformaStore
{
    /// <summary>Set by the API at its start; without it the issue refuses (the worker never issues).</summary>
    public static IProformaServices? Services { get; set; }

    public sealed record ProformaForm(Guid? Customer, string? BranchCode, string? BranchName, string? ProjectCode, string? ProjectName, string? ProjectSite,
        int? OfferValidityDays, decimal LcPaymentPct, string? PlaceOfReceipt, string? PlaceOfDelivery, IReadOnlyList<ProformaLineInput> Lines);

    private static string? Str(JsonElement o, string k, int max)
    {
        if (!o.TryGetProperty(k, out var v) || v.ValueKind != JsonValueKind.String) return null;
        var s = v.GetString()!.Trim();
        if (s.Length > max) throw WorkflowRefusalException.Missing("V-LCE-FIELD", $"The proforma's {k} is up to {max} characters.");
        return s.Length == 0 ? null : s;
    }

    /// <summary>The proforma of a request's form (key "proforma"); an absent one reads as empty.</summary>
    public static ProformaForm Parse(string? formJson)
    {
        using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(formJson) ? "{}" : formJson);
        if (!doc.RootElement.TryGetProperty("proforma", out var p) || p.ValueKind != JsonValueKind.Object)
            return new ProformaForm(null, null, null, null, null, null, null, 100m, null, null, []);
        var lines = new List<ProformaLineInput>();
        if (p.TryGetProperty("lines", out var ls) && ls.ValueKind == JsonValueKind.Array)
            foreach (var l in ls.EnumerateArray())
            {
                decimal Num(string k) => l.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDecimal() : 0m;
                lines.Add(new ProformaLineInput(Str(l, "description", 4000) ?? "", Num("qty"), Str(l, "unitCode", 80) ?? "", Num("unitPrice"), Str(l, "notes", 500)));
            }
        if (lines.Count > 200) throw WorkflowRefusalException.Missing("V-LCE-03", "A proforma has at most 200 lines.");
        int? validity = p.TryGetProperty("offerValidityDays", out var ov) && ov.ValueKind == JsonValueKind.Number && ov.TryGetInt32(out var d) ? d : null;
        if (validity is <= 0 or > 3650) throw WorkflowRefusalException.Missing("V-LCE-FIELD", "The offer's validity is 1 to 3650 days.");
        var pct = p.TryGetProperty("lcPaymentPct", out var lp) && lp.ValueKind == JsonValueKind.Number ? lp.GetDecimal() : 100m;
        if (pct is <= 0 or > 100) throw WorkflowRefusalException.Missing("V-LCE-FIELD", "The part paid by the letter of credit is above 0 and at most 100 percent.");
        return new ProformaForm(Guid.TryParse(Str(p, "customer", 40), out var cu) ? cu : null, Str(p, "branchCode", 40), Str(p, "branchName", 200), Str(p, "projectCode", 40),
            Str(p, "projectName", 200), Str(p, "projectSite", 200), validity, pct, Str(p, "placeOfReceipt", 200), Str(p, "placeOfDelivery", 200), lines);
    }

    /// <summary>The VAT rate in force on a date (BR-LCE-001): the company's own, else the tenant's default; null when none is in force (V-LCE-02).</summary>
    public static Task<decimal?> VatRateAsync(SqlConnection c, SqlTransaction? tx, long companyId, DateTime on, CancellationToken ct) =>
        c.ExecuteScalarAsync<decimal?>(new CommandDefinition(
            """
            SELECT TOP (1) RatePercent FROM org.CompanyTaxRate
             WHERE TaxCode = 'VAT' AND (CompanyId = @co OR CompanyId IS NULL) AND EffectiveFrom <= @on AND (EffectiveTo IS NULL OR EffectiveTo >= @on)
             ORDER BY CASE WHEN CompanyId IS NULL THEN 1 ELSE 0 END, EffectiveFrom DESC;
            """, new { co = companyId, on = on.Date }, tx, cancellationToken: ct));

    private static async Task<long> CustomerAsync(SqlConnection c, SqlTransaction tx, Guid? customer, CancellationToken ct) =>
        customer is { } id
            ? await c.ExecuteScalarAsync<long?>(new CommandDefinition(
                  "SELECT CounterpartyId FROM lc.Counterparty WHERE PublicId = @id AND IsActive = 1 AND Kind IN ('CUSTOMER', 'BOTH');", new { id }, tx, cancellationToken: ct))
                  .ConfigureAwait(false) ?? throw WorkflowRefusalException.Missing("V-LCE-CUSTOMER", "The customer is not an active customer of the counterparties.")
            : throw WorkflowRefusalException.Missing("V-LCE-CUSTOMER", "Choose the customer of the proforma (FR-LCE-002).");

    private static ProformaTotals TotalsOf(ProformaForm f, decimal rate, int decimals)
    {
        try { return SalesRules.Totals(f.Lines, rate, f.LcPaymentPct, decimals); }
        catch (ArgumentException ex) { throw WorkflowRefusalException.Missing("V-LCE-03", ex.Message.Split(" (Parameter", 2)[0].Replace("V-LCE-03: ", "", StringComparison.Ordinal)); }
    }

    /// <summary>
    /// At the submission (lc.validate_terms): the terms' applicant is the proforma's customer and their amount the part of
    /// the proforma's total paid by credit, at the tax rate in force today; a proforma without a customer, a line or a
    /// currency, or a company without a rate in force, is refused (FR-LCE-001, 003).
    /// </summary>
    public static async Task PrepareTermsAsync(SqlConnection c, SqlTransaction tx, long requestId, long companyId, long termsId, DateTimeOffset now, CancellationToken ct)
    {
        var form = Parse(await c.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT FormDataJson FROM wfl.Request WHERE RequestId = @r;", new { r = requestId }, tx,
            cancellationToken: ct)).ConfigureAwait(false));
        var customer = await CustomerAsync(c, tx, form.Customer, ct).ConfigureAwait(false);
        var decimals = await c.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT cur.Decimals FROM lc.LcTerms AS t JOIN ref.Currency AS cur ON cur.CurrencyId = t.CurrencyId WHERE t.LcTermsId = @t;", new { t = termsId }, tx,
            cancellationToken: ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.Missing("V-LCT-REQUIRED", "Choose the currency of the proforma in its terms.");
        var today = await Delegations.TodayAsync(c, tx, now, ct).ConfigureAwait(false);
        var rate = await VatRateAsync(c, tx, companyId, today, ct).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.Missing("V-LCE-02", "The company has no VAT rate in force; add one, even zero, before the proforma.");
        var totals = TotalsOf(form, rate, decimals);
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcTerms SET ApplicantCounterpartyId = @cu, BeneficiaryCompanyId = @co, Amount = @amount, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE LcTermsId = @t AND Status = 'DRAFT';
            """, new { cu = customer, co = companyId, amount = totals.LcAmount, t = termsId }, tx, cancellationToken: ct)).ConfigureAwait(false);
    }

    /// <summary>The treasury's choices at the issue (form key "proformaIssue"): the proceeds account and the print language.</summary>
    public sealed record IssueChoice(Guid? ProceedsAccount, string PrintLanguage);

    public static IssueChoice ParseIssue(string? formJson)
    {
        using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(formJson) ? "{}" : formJson);
        if (!doc.RootElement.TryGetProperty("proformaIssue", out var p) || p.ValueKind != JsonValueKind.Object) return new IssueChoice(null, "both");
        var lang = p.TryGetProperty("printLanguage", out var l) && l.GetString() is "ar" or "en" or "both" ? l.GetString()! : "both";
        return new IssueChoice(p.TryGetProperty("proceedsAccount", out var a) && Guid.TryParse(a.GetString(), out var g) ? g : null, lang);
    }

    private sealed class Company
    {
        public string NameAr { get; init; } = "";
        public string NameEn { get; init; } = "";
        public string? ErpCompanyCode { get; init; }
        public string? ErpCodeNormalized { get; init; }
        public string? CrNumber { get; init; }
        public string? AddressText { get; init; }
    }

    /// <summary>
    /// lc.issue_proforma (FR-LCE-005, 006; BR-LCE-002 to 005), in the transaction of the completion of ISSUE_PROFORMA.
    /// A replay returns the proforma already issued. Refused, before any number is taken, when the company has no ERP code
    /// (V-LCE-01), no tax rate is in force (V-LCE-02), the proceeds account is not an active LC_COLLECTION account of the
    /// company (V-LCE-04), or the totals no longer give the locked terms' amount (the tax rate changed: return the request).
    /// </summary>
    public static async Task<object?> IssueHookAsync(RequestEngine.HookContext h)
    {
        ArgumentNullException.ThrowIfNull(h);
        if (await h.C.QuerySingleOrDefaultAsync<(long Id, string No)?>(new CommandDefinition(
                "SELECT ProformaInvoiceId, ProformaNo FROM lc.ProformaInvoice WHERE RequestId = @r;", new { r = h.Request.RequestId }, h.Tx, cancellationToken: h.Ct))
                .ConfigureAwait(false) is { } done)
            return new { proformaId = done.Id, proformaNo = done.No, replay = true };
        if (!h.Actor.Permissions.Contains("lc.proforma.issue")) throw WorkflowRefusalException.Forbidden("You may not issue proformas.");
        var services = Services ?? throw new WorkflowRefusalException(409, "HOOK_NOT_AVAILABLE", "The issue of proformas is not available here.");
        var formJson = await h.C.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT FormDataJson FROM wfl.Request WHERE RequestId = @r;", new { r = h.Request.RequestId },
            h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        var form = Parse(formJson);
        var choice = ParseIssue(formJson);
        var company = await h.C.QuerySingleAsync<Company>(new CommandDefinition(
            """
            SELECT co.NameAr, co.NameEn, co.ErpCompanyCode, co.ErpCodeNormalized, co.CrNumber, ctry.NameEn AS AddressText
              FROM org.Company AS co JOIN ref.Country AS ctry ON ctry.CountryId = co.CountryId WHERE co.CompanyId = @co;
            """, new { co = h.Request.CompanyId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        if (string.IsNullOrEmpty(company.ErpCodeNormalized))
            throw WorkflowRefusalException.Missing("V-LCE-01", "The company has no ERP code, which the proforma's number carries (BR-LCE-002).");
        var terms = await TermsStore.CurrentAsync(h.C, h.Tx, h.Request.RequestId, h.Ct).ConfigureAwait(false);
        if (terms is not { Status: "LOCKED", Purpose: "PROFORMA" }) throw WorkflowRefusalException.State("The proforma's terms are not locked.");
        var cur = await h.C.QuerySingleAsync<(string Code, string NameAr, string NameEn, int Decimals)>(new CommandDefinition(
            "SELECT Code, NameAr, NameEn, Decimals FROM ref.Currency WHERE CurrencyId = @c;", new { c = terms.CurrencyId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        var today = await Delegations.TodayAsync(h.C, h.Tx, h.Now, h.Ct).ConfigureAwait(false);
        var rate = await VatRateAsync(h.C, h.Tx, h.Request.CompanyId, today, h.Ct).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.Missing("V-LCE-02", "The company has no VAT rate in force on the issue date.");
        var totals = TotalsOf(form, rate, cur.Decimals);
        if (totals.LcAmount != terms.Amount)
            throw WorkflowRefusalException.Missing("V-LCE-TOTALS", "The proforma's total no longer gives the amount of its locked terms (the tax rate changed); return the request to its requester.");
        var account = choice.ProceedsAccount is { } pa
            ? await h.C.QuerySingleOrDefaultAsync<(long Id, int CurrencyId, string? IbanMask, string AccountNoMask, string BankEn, string BankAr, string? Bic)?>(new CommandDefinition(
                """
                SELECT a.BankAccountId, a.CurrencyId, a.IbanMask, a.AccountNoMask, i.NameEn, i.NameAr, i.SwiftBic
                  FROM acc.BankAccount AS a JOIN cat.AccountType AS t ON t.AccountTypeId = a.AccountTypeId JOIN ins.Institution AS i ON i.InstitutionId = a.InstitutionId
                 WHERE a.PublicId = @pa AND a.CompanyId = @co AND a.Status = 'ACTIVE' AND t.Code = 'LC_COLLECTION';
                """, new { pa, co = h.Request.CompanyId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false)
            : null;
        if (account is not { } acc)
            throw WorkflowRefusalException.Missing("V-LCE-04", "Choose an active letter of credit collection account of the company for the proceeds (BR-LCE-004).");
        var warnings = new List<string>();
        if (acc.CurrencyId != terms.CurrencyId) warnings.Add("V-LCE-04");
        var customer = await h.C.QuerySingleAsync(new CommandDefinition(
            """
            SELECT cp.CounterpartyId AS id, cp.Code AS code, cp.NameEn AS nameEn, cp.NameAr AS nameAr, cp.ErpCode AS erpCode, cp.AddressLine AS addressLine, cp.City AS city,
                   cp.PoBox AS poBox, cp.PostalCode AS postalCode, cp.Phone AS phone, cp.Fax AS fax, cp.TaxNumber AS taxNumber, co.Iso2 AS country
              FROM lc.LcTerms AS t JOIN lc.Counterparty AS cp ON cp.CounterpartyId = t.ApplicantCounterpartyId JOIN ref.Country AS co ON co.CountryId = cp.CountryId
             WHERE t.LcTermsId = @t;
            """, new { t = terms.LcTermsId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        var customerRow = (IDictionary<string, object?>)customer;
        var customerId = (long)customerRow["id"]!;
        customerRow.Remove("id");
        var snapshot = JsonSerializer.Serialize(customerRow);

        // The number: the company's gap-free sequence for the year of the issue in the tenant's time zone (BR-LCE-002).
        var p = new DynamicParameters();
        p.Add("@SequenceKey", "PROFORMA", DbType.AnsiString, size: 50);
        p.Add("@CompanyId", h.Request.CompanyId, DbType.Int64);
        p.Add("@OnDate", today, DbType.Date);
        p.Add("@IssuedNumber", null, DbType.String, ParameterDirection.Output, 60);
        p.Add("@NumberIssueId", null, DbType.Int64, ParameterDirection.Output);
        await h.C.ExecuteAsync(new CommandDefinition("cfg.usp_AllocateNumber", p, h.Tx, commandType: CommandType.StoredProcedure, cancellationToken: h.Ct)).ConfigureAwait(false);
        var number = p.Get<string>("@IssuedNumber");
        var issueId = p.Get<long>("@NumberIssueId");
        var seq = await h.C.ExecuteScalarAsync<long>(new CommandDefinition("SELECT SeqValue FROM cfg.NumberIssue WHERE NumberIssueId = @id;", new { id = issueId }, h.Tx,
            cancellationToken: h.Ct)).ConfigureAwait(false);

        var proformaTerms = await TermsStore.CopyAsync(h.C, h.Tx, terms.LcTermsId, "PROFORMA", null, "PROFORMA", 1, "LOCKED", h.Ct).ConfigureAwait(false);
        var iban = await services.AccountIbanAsync(h.C, h.Tx, acc.Id, h.Ct).ConfigureAwait(false);
        var print = new ProformaPrint.Data(number, today, form, totals, cur.Code, cur.Decimals,
            AmountInWords: (BankFas.Core.Text.AmountInWords.Arabic(totals.Total, cur.NameAr, cur.Decimals), BankFas.Core.Text.AmountInWords.English(totals.Total, cur.NameEn, cur.Decimals)),
            CompanyNameAr: company.NameAr, CompanyNameEn: company.NameEn, CompanyCr: company.CrNumber, CompanyAddress: company.AddressText, Customer: customerRow,
            BankNameEn: acc.BankEn, BankNameAr: acc.BankAr, BankBic: acc.Bic, Iban: iban ?? acc.IbanMask, AccountMask: acc.AccountNoMask, Language: choice.PrintLanguage,
            ValidUntil: form.OfferValidityDays is { } v ? today.AddDays(v) : null);
        var html = await ProformaPrint.BuildAsync(h.C, h.Tx, proformaTerms, print, h.Ct).ConfigureAwait(false);
        var documentId = await services.StoreAsync(h.C, h.Tx, new GeneratedDocument("PROFORMA_ISSUED", h.Request.CompanyId, $"Proforma {number}", number, today,
            $"proforma-{number}.html", "text/html", System.Text.Encoding.UTF8.GetBytes(html), "wfl.Request", h.Request.RequestId), h.Ct).ConfigureAwait(false);

        var proformaId = await h.C.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT lc.ProformaInvoice (TenantId, CompanyId, ProformaNo, NumberYear, NumberSeq, RequestId, ErpCompanyCodeSnapshot, BranchCode, BranchName, ProjectCode, ProjectName,
                                       ProjectSite, CustomerId, CustomerSnapshotJson, IssueDate, OfferValidityDays, CurrencyId, Subtotal, VatRatePct, VatAmount, Total, LcPaymentPct,
                                       PlacesJson, TermsId, ProceedsAccountId, PrintLanguage, DocumentId, CreatedBy)
            OUTPUT inserted.ProformaInvoiceId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @co, @no, @year, @seq, @r, @erp, @bc, @bn, @pc, @pn, @ps, @cu, @snap, @issue, @validity, @cur, @sub, @rate, @vat,
                    @total, @pct, @places, @terms, @acc, @lang, @doc, @u);
            DECLARE @id BIGINT = (SELECT Id FROM @o);
            UPDATE lc.LcTerms SET OwnerId = @id WHERE LcTermsId = @terms AND OwnerId IS NULL;
            INSERT lc.ProformaLine (TenantId, ProformaId, [LineNo], Description, Qty, UnitCode, UnitPrice, LineTotal, CurrencyId, Notes, CreatedBy)
            SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), @id, j.[LineNo], j.Description, j.Qty, j.UnitCode, j.UnitPrice, j.LineTotal, @cur, j.Notes, @u
              FROM OPENJSON(@lines) WITH ([LineNo] INT, Description NVARCHAR(MAX), Qty DECIMAL(19,4), UnitCode VARCHAR(80), UnitPrice DECIMAL(19,4), LineTotal DECIMAL(19,4),
                                          Notes NVARCHAR(500)) AS j;
            UPDATE cfg.NumberIssue SET EntityType = 'lc.ProformaInvoice', EntityId = @id WHERE NumberIssueId = @issueId AND EntityId IS NULL;
            SELECT @id;
            """,
            new
            {
                co = h.Request.CompanyId, no = number, year = (short)today.Year, seq = (int)seq, r = h.Request.RequestId, erp = company.ErpCodeNormalized,
                bc = form.BranchCode, bn = form.BranchName, pc = form.ProjectCode, pn = form.ProjectName, ps = form.ProjectSite, cu = customerId, snap = snapshot,
                issue = today, validity = form.OfferValidityDays, cur = terms.CurrencyId, sub = totals.Subtotal, rate, vat = totals.VatAmount, total = totals.Total,
                pct = form.LcPaymentPct, places = JsonSerializer.Serialize(new { receipt = form.PlaceOfReceipt, delivery = form.PlaceOfDelivery }), terms = proformaTerms,
                acc = acc.Id, lang = choice.PrintLanguage, doc = documentId, u = h.Actor.UserId,
                lines = JsonSerializer.Serialize(totals.Lines.Select(l => new { l.LineNo, l.Description, l.Qty, l.UnitCode, l.UnitPrice, l.LineTotal, l.Notes })), issueId,
            }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);

        // A copy of an issued proforma's request replaces it (BR-LCE-003): the earlier one becomes SUPERSEDED, its number kept.
        await h.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE p SET Status = 'SUPERSEDED', SupersededById = @id, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
              FROM lc.ProformaInvoice AS p JOIN wfl.Request AS r ON r.CopiedFromRequestId = p.RequestId
             WHERE r.RequestId = @r AND p.Status = 'ISSUED' AND p.CompanyId = @co;
            """, new { id = proformaId, u = h.Actor.UserId, r = h.Request.RequestId, co = h.Request.CompanyId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(h.C, h.Tx, "lc.proforma.issued", "lc.ProformaInvoice", proformaId, new { proformaId, requestId = h.Request.RequestId }, h.Ct).ConfigureAwait(false);
        await Notifier.RequestAsync(h.C, h.Tx, new NotificationRequest("LC.PROFORMA_ISSUED", "lc.ProformaInvoice", proformaId, $"LC.PROFORMA_ISSUED:{proformaId}", h.Request.CompanyId,
            new Dictionary<string, object?>
            {
                ["proformaNo"] = number, ["requestNo"] = h.Request.RequestNo, ["customerName"] = customerRow["nameEn"], ["currency"] = cur.Code,
                ["amount"] = totals.Total.ToString("N" + cur.Decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture),
            }, $"/sales/proformas/{proformaId}", h.Actor.UserId, [h.Request.RequesterUserId]), h.Ct).ConfigureAwait(false);
        return new { proformaId, proformaNo = number, warnings };
    }

    /// <summary>BR-LCE-003: a treasury manager voids an issued proforma with a reason; its number is never given again.</summary>
    public static async Task VoidAsync(SqlConnection c, SqlTransaction tx, Actor actor, long proformaId, string reason, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        if (!actor.Permissions.Contains("lc.proforma.void")) throw WorkflowRefusalException.Forbidden("Only the treasury manager voids a proforma.");
        reason = reason.Trim();
        if (reason.Length is 0 or > 500) throw WorkflowRefusalException.Missing("V-WFL-REASON", "A void gives its reason (up to 500 characters).");
        var n = await c.ExecuteAsync(new CommandDefinition(
            "UPDATE lc.ProformaInvoice SET Status = 'VOID', VoidReason = @reason, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE ProformaInvoiceId = @id AND Status = 'ISSUED';",
            new { reason, u = actor.UserId, id = proformaId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (n == 0) throw WorkflowRefusalException.State("Only an issued proforma is voided.");
        await Outbox.EmitAsync(c, tx, "lc.proforma.voided", "lc.ProformaInvoice", proformaId, new { proformaId }, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// FR-REQ-025: a new draft copied from a request of a top-level type: the fields the requester fills (those editable
    /// in DRAFT), never the treasury's, the attachments or the references; the terms are copied as a new draft (their
    /// amount in words cleared). A child request (an amendment, a sales order) is raised again from its parent.
    /// </summary>
    public static async Task<(long RequestId, Guid PublicId)> CopyRequestAsync(SqlConnection c, SqlTransaction tx, Actor actor, long fromRequestId, DateTimeOffset now,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        var from = await RequestEngine.FindAsync(c, tx, fromRequestId, false, ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        var parent = await c.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT ParentEntityType FROM wfl.RequestType WHERE RequestTypeId = @t;",
            new { t = from.RequestTypeId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (parent is not null) throw WorkflowRefusalException.State("A child request is raised again from its parent, not copied (FR-REQ-025).");
        var fields = await RequestEngine.FieldsAsync(c, tx, from.TemplateId, ct).ConfigureAwait(false);
        var mine = fields.Where(f => f.EditableStagesJson is null || f.EditableStagesJson.Contains("\"DRAFT\"", StringComparison.Ordinal))
            .Select(f => f.FieldKey).ToHashSet(StringComparer.Ordinal);
        var form = from.FormDataJson ?? "{}";
        using (var doc = JsonDocument.Parse(form))
        {
            var kept = doc.RootElement.EnumerateObject().Where(x => mine.Contains(x.Name)).ToDictionary(x => x.Name, x => x.Value.Clone());
            form = JsonSerializer.Serialize(kept);
        }
        var (requestId, publicId, _) = await RequestEngine.CreateDraftAsync(c, tx, actor, new NewRequest(from.TypeCode, from.CompanyId, null, form), now, ct).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition("UPDATE wfl.Request SET CopiedFromRequestId = @from WHERE RequestId = @r;", new { from = fromRequestId, r = requestId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        if (await TermsStore.CurrentAsync(c, tx, fromRequestId, ct).ConfigureAwait(false) is { } t)
        {
            var copy = await TermsStore.CopyAsync(c, tx, t.LcTermsId, "REQUEST", requestId, t.Purpose, 1, "DRAFT", ct).ConfigureAwait(false);
            await c.ExecuteAsync(new CommandDefinition("UPDATE lc.LcTerms SET AmountInWordsAr = NULL, AmountInWordsEn = NULL, CopiedFromTermsId = @t WHERE LcTermsId = @n;",
                new { t = t.LcTermsId, n = copy }, tx, cancellationToken: ct)).ConfigureAwait(false);
        }
        return (requestId, publicId);
    }
}

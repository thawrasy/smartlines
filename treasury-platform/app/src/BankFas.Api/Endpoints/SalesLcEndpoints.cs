using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Text;
using BankFas.Data;
using BankFas.Data.Lc;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record ReceivedLcBody(Guid? Company, string? LcNumber, Guid? Customer, Guid? Institution, string? OtherBankText, string? OtherBankBic, DateOnly? ReceivedDate,
    Guid? Proforma, JsonElement? Terms, JsonElement? Documents, string? BankReference, string? ErpReference, string[]? Acknowledge, string? WarningReason);
public sealed record SalesOrderBody(string? Title, string? OrderRef, DateOnly? OrderDate, decimal? Amount, DateOnly? DeliveryDate, string? Notes);
public sealed record CollectionAllocationBody(Guid Order, decimal Amount);
public sealed record CollectionBody(string? Title, decimal? Amount, DateOnly? ShipmentDate, string? InvoiceRefs, CollectionAllocationBody[]? Allocations, string? Notes);
public sealed record OrderCloseBody(string? Reason, bool? Cancel);
public sealed record DiscrepancyBody(string? Description);
public sealed record DiscrepancyDecisionBody(string? Status, string? Note);
public sealed record SalesAmendmentBody(string? Origin, decimal? NewAmount, DateOnly? NewExpiryDate, DateOnly? NewLatestShipmentDate, string? BankAmendmentRef, DateOnly? BankIssuedOn,
    string? Decision, string? Reason);
public sealed record LcDocumentBody(Guid? Document);
public sealed record ComparisonDecisionBody(string? Decision, string? Note);

/// <summary>
/// The received letters of credit (spec 14 section 4.3, screens 18 to 22): the treasury records a customer's credit;
/// the sales search the active ones with their balance (BR-LCE-008, 009) and raise sales orders and collection
/// documents on them; the treasury follows the documents with the customer's bank, the discrepancies, the amendments
/// and the close. The module is LC_SALES. A holder of lc.export.view sees the received credits of their company scope;
/// the bank, the references, the accounts and the terms are for holders of lc.view.internal (BR-LCE-015).
/// </summary>
public static class SalesLcEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/sales/lcs", ListAsync);
        api.MapPost("/sales/lcs", RecordAsync);
        api.MapGet("/sales/lcs/{id:guid}", GetAsync);
        api.MapPost("/sales/lcs/{id:guid}/documents", AttachAsync);
        api.MapPost("/sales/lcs/{id:guid}/sales-orders", OrderAsync);
        api.MapPost("/sales/lcs/{id:guid}/collections", CollectionAsync);
        api.MapPost("/sales/orders/{id:guid}/close", CloseOrderAsync);
        api.MapPost("/sales/lcs/{id:guid}/drawings/{no:int}/decision", DecideAsync);
        api.MapPost("/sales/lcs/{id:guid}/drawings/{no:int}/settlements", SettleAsync);
        api.MapPost("/sales/lcs/{id:guid}/drawings/{no:int}/discrepancies", DiscrepancyAsync);
        api.MapPost("/sales/lcs/{id:guid}/drawings/{no:int}/discrepancy-decision", DiscrepancyDecisionAsync);
        api.MapPost("/sales/lcs/{id:guid}/amendments", AmendAsync);
        api.MapPost("/sales/lcs/{id:guid}/close", CloseAsync);
        api.MapPost("/sales/lcs/{id:guid}/compare", CompareAsync);
        api.MapGet("/sales/lcs/{id:guid}/comparison", ComparisonAsync);
        api.MapPut("/sales/lcs/{id:guid}/comparison/lines/{field}", DecideLineAsync);
    }

    private static readonly string[] JsonLists = ["allocations", "discrepancies"];
    private static readonly string[] InternalOfRow = ["bankNameEn", "bankNameAr", "bankReference", "erpReference"];
    private static readonly string[] InternalOfCard = ["bankNameEn", "bankNameAr", "customerBank", "customerBankBic", "bankReference", "erpReference"];

    private const string Visible = "l.LcClass = 'SALES' AND (@scopeAll = 1 OR l.CompanyId IN @scope)";

    private static async Task<DynamicParameters> ScopeAsync(BoundUser u, CancellationToken ct, SqlTransaction? tx = null)
    {
        var perms = await u.PermissionsAsync(ct);
        if (!perms.Contains("lc.export.view")) throw ApiProblemException.Forbidden();
        var scope = await CompanyScope.OfAsync(u, ct, tx);
        return new DynamicParameters(new { scopeAll = scope.All, scope = scope.SqlIds });
    }

    internal static async Task<long> IdAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct)
    {
        var p = await ScopeAsync(u, ct, tx);
        p.Add("id", id);
        return await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition($"SELECT l.LetterOfCreditId FROM lc.LetterOfCredit AS l WHERE l.PublicId = @id AND {Visible};", p, tx,
                   cancellationToken: ct))
               ?? throw ApiProblemException.NotFound();
    }

    private static string Like(string q) => "%" + q.Replace("[", "[[]", StringComparison.Ordinal).Replace("%", "[%]", StringComparison.Ordinal).Replace("_", "[_]", StringComparison.Ordinal) + "%";

    /// <summary>
    /// FR-LCE-011, BR-LCE-008: one field searches the number (exact first), the ERP reference, the customer's code and
    /// name; by default the active credits not expired with something available; "all=true" lifts that filter. Each row
    /// carries the four balances; the bank and the references only for holders of lc.view.internal.
    /// </summary>
    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "q", "status", "company", "all", "limit");
        await using var u = await SalesEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var p = await ScopeAsync(u, ct);
        var q = http.Request.Query["q"].ToString().Trim();
        var internalView = (await u.PermissionsAsync(ct)).Contains("lc.view.internal");
        p.Add("q", q.Length == 0 ? null : Like(q));
        p.Add("n", q.Length == 0 ? null : IssuanceHooks.Normalise(q));
        p.Add("nq", q.Length == 0 ? null : Like(Normalizer.Name(q)));
        p.Add("eq", q.Length == 0 ? null : SalesLcStore.NormaliseRef(q));
        p.Add("status", http.Request.Query["status"].ToString() is { Length: > 0 } s ? s.ToUpperInvariant() : null);
        p.Add("company", Guid.TryParse(http.Request.Query["company"], out var co) ? co : null);
        p.Add("all", http.Request.Query["all"] == "true");
        p.Add("today", await Delegations.TodayAsync(u.Connection, null, clock.GetUtcNow(), ct));
        p.Add("take", Query.Limit(http.Request));
        var rows = (await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT TOP (@take) l.PublicId AS id, l.LcNumber AS lcNumber, l.Status AS status, cur.Code AS currency, l.Amount AS amount, l.EarmarkedRemaining AS earmarked,
                   l.DrawnAmount AS drawn, l.Amount - l.EarmarkedRemaining - l.DrawnAmount AS available, l.ReceivedDate AS receivedDate, l.ExpiryDate AS expiryDate,
                   l.LatestShipmentDate AS latestShipmentDate, cp.NameEn AS customerNameEn, cp.NameAr AS customerNameAr, cp.ErpCode AS customerCode,
                   co.NameEn AS companyNameEn, co.NameAr AS companyNameAr, i.NameEn AS bankNameEn, i.NameAr AS bankNameAr, l.BankReference AS bankReference,
                   (SELECT TOP (1) x.RefValue FROM lc.LcExternalRef AS x WHERE x.LcId = l.LetterOfCreditId AND x.IsActive = 1) AS erpReference, pf.ProformaNo AS proformaNo,
                   CASE WHEN @n IS NULL THEN 0 WHEN l.LcNumberNormalized = @n THEN 0
                        WHEN EXISTS (SELECT 1 FROM lc.LcExternalRef AS x WHERE x.LcId = l.LetterOfCreditId AND x.NormalizedValue = @eq) THEN 1
                        WHEN cp.ErpCodeNormalized = @eq THEN 2 ELSE 3 END AS rank
              FROM lc.LetterOfCredit AS l JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = l.CounterpartyId
              JOIN org.Company AS co ON co.CompanyId = l.CompanyId LEFT JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId
              LEFT JOIN lc.ProformaInvoice AS pf ON pf.ProformaInvoiceId = l.ProformaId
             WHERE {Visible} AND (@company IS NULL OR co.PublicId = @company) AND (@status IS NULL OR l.Status = @status)
               AND (@all = 1 OR (l.Status = 'ACTIVE' AND l.ExpiryDate >= @today AND l.Amount - l.EarmarkedRemaining - l.DrawnAmount > 0))
               AND (@q IS NULL OR l.LcNumberNormalized LIKE '%' + @n + '%' OR cp.NameNormalized LIKE @nq OR cp.ErpCodeNormalized = @eq
                    OR EXISTS (SELECT 1 FROM lc.LcExternalRef AS x WHERE x.LcId = l.LetterOfCreditId AND x.NormalizedValue LIKE '%' + @eq + '%'))
             ORDER BY rank, l.ExpiryDate, l.LetterOfCreditId;
            """, p, cancellationToken: ct))).Select(r => (IDictionary<string, object?>)r).ToList();
        foreach (var r in rows)
        {
            r.Remove("rank");
            if (!internalView) foreach (var k in InternalOfRow) r.Remove(k);
        }
        return Results.Ok(new { items = rows });
    }

    /// <summary>FR-LCE-009: the treasury records a received credit; the warnings V-LCE-12 and 13 are acknowledged with a reason, or come back as 409.</summary>
    private static async Task<IResult> RecordAsync(ReceivedLcBody b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        if (b.Company is null || string.IsNullOrWhiteSpace(b.LcNumber) || b.Customer is null || b.ReceivedDate is null)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the company, the credit's number, the customer and the date it was received.");
        await using var u = await SalesEndpoints.OpenAsync(http, db, "lc.export.record");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        var scope = await CompanyScope.OfAsync(u, ct, tx);
        var company = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT CompanyId FROM org.Company WHERE PublicId = @c AND Status <> 'ARCHIVED';",
            new { c = b.Company }, tx, cancellationToken: ct));
        if (company is null || !scope.Allows(company)) throw ApiProblemException.Invalid("COMPANY_NOT_FOUND", "The company does not exist or is outside your scope.");
        var customer = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT CounterpartyId FROM lc.Counterparty WHERE PublicId = @c AND IsActive = 1 AND Kind IN ('CUSTOMER', 'BOTH');", new { c = b.Customer }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("V-LCE-CUSTOMER", "The customer is not an active customer of the counterparties.");
        long? institution = b.Institution is { } i
            ? await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @i;", new { i }, tx, cancellationToken: ct))
              ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank is not known.")
            : null;
        long? proforma = b.Proforma is { } pf
            ? await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT ProformaInvoiceId FROM lc.ProformaInvoice WHERE PublicId = @pf;", new { pf }, tx,
                  cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The proforma is not known.")
            : null;
        var (lcId, warnings) = await SalesLcStore.RecordAsync(u.Connection, tx, actor, new NewReceivedLc(company.Value, b.LcNumber, customer, institution, b.OtherBankText,
            b.OtherBankBic?.Trim().ToUpperInvariant(), b.ReceivedDate.Value.ToDateTime(TimeOnly.MinValue), proforma, b.Terms, b.Documents, b.BankReference, b.ErpReference,
            b.Acknowledge ?? [], b.WarningReason), clock.GetUtcNow(), ct);
        var publicId = await u.Connection.ExecuteScalarAsync<Guid>(new CommandDefinition("SELECT PublicId FROM lc.LetterOfCredit WHERE LetterOfCreditId = @lcId;", new { lcId }, tx,
            cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LC_RECEIVED_RECORDED", "TREASURY", "lc.LetterOfCredit", lcId,
            AfterJson: JsonSerializer.Serialize(new { lcNumber = b.LcNumber.Trim(), warnings, reason = warnings.Count > 0 ? b.WarningReason?.Trim() : null }),
            Severity: warnings.Count > 0 ? "HIGH" : "INFO"), company, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/sales/lcs/{publicId}", new { id = publicId, warnings });
    }

    /// <summary>
    /// The credit's card (screen 19): its balance, its orders with their conversions, its drawings with their allocations,
    /// its amendments and discrepancies; the bank, the references and the terms for holders of lc.view.internal.
    /// </summary>
    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request);
        await using var u = await SalesEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var lcId = await IdAsync(u, null, id, ct);
        var internalView = (await u.PermissionsAsync(ct)).Contains("lc.view.internal");
        var lc = (IDictionary<string, object?>)await u.Connection.QuerySingleAsync(new CommandDefinition(
            """
            SELECT l.PublicId AS id, l.LcNumber AS lcNumber, l.Status AS status, l.Scope AS scope, cur.Code AS currency, cur.Decimals AS decimals, l.Amount AS amount,
                   l.OriginalAmount AS originalAmount, l.TolerancePlusPct AS tolerancePlusPct, l.ToleranceMinusPct AS toleranceMinusPct, l.EarmarkedRemaining AS earmarked,
                   l.DrawnAmount AS drawn, l.SettledAmount AS settled, l.Amount - l.EarmarkedRemaining - l.DrawnAmount AS available, l.ReceivedDate AS receivedDate,
                   l.ExpiryDate AS expiryDate, l.LatestShipmentDate AS latestShipmentDate, l.AmendmentNo AS amendmentNo, l.ClosedOn AS closedOn, l.ClosedReason AS closedReason,
                   cp.NameEn AS customerNameEn, cp.NameAr AS customerNameAr, cp.ErpCode AS customerCode, co.NameEn AS companyNameEn, co.NameAr AS companyNameAr,
                   co.PublicId AS companyId, pf.ProformaNo AS proformaNo, pf.PublicId AS proformaId,
                   i.NameEn AS bankNameEn, i.NameAr AS bankNameAr, l.OtherBankText AS customerBank, l.OtherBankBic AS customerBankBic, l.BankReference AS bankReference,
                   (SELECT TOP (1) x.RefValue FROM lc.LcExternalRef AS x WHERE x.LcId = l.LetterOfCreditId AND x.IsActive = 1) AS erpReference, l.CurrentTermsId AS termsId
              FROM lc.LetterOfCredit AS l JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = l.CounterpartyId
              JOIN org.Company AS co ON co.CompanyId = l.CompanyId LEFT JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId
              LEFT JOIN lc.ProformaInvoice AS pf ON pf.ProformaInvoiceId = l.ProformaId
             WHERE l.LetterOfCreditId = @lcId;
            """, new { lcId }, cancellationToken: ct));
        var termsId = (long)lc["termsId"]!;
        lc.Remove("termsId");
        object? terms = null;
        if (internalView) terms = await TermsStore.ReadAsync(u.Connection, null, termsId, false, ct);
        else foreach (var k in InternalOfCard) lc.Remove(k);
        var orders = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT o.PublicId AS id, o.OrderRef AS orderRef, o.OrderDate AS orderDate, o.Amount AS amount, o.ConvertedAmount AS converted, o.ReleasedAmount AS released,
                   o.Amount - o.ConvertedAmount - o.ReleasedAmount AS remaining, o.Status AS status, o.DeliveryDate AS deliveryDate, r.RequestNo AS requestNo, r.PublicId AS requestId
              FROM lc.LcSalesOrder AS o JOIN wfl.Request AS r ON r.RequestId = o.RequestId WHERE o.LcId = @lcId ORDER BY o.OrderDate, o.LcSalesOrderId;
            """, new { lcId }, cancellationToken: ct));
        var drawings = (await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT d.DrawingNo AS drawingNo, d.Amount AS amount, d.PresentationDate AS presentationDate, d.Status AS status, d.SettledAmount AS settled, d.InvoiceRefsText AS invoiceRefs,
                   r.RequestNo AS requestNo, r.PublicId AS requestId,
                   (SELECT o.OrderRef AS orderRef, a.Amount AS amount FROM lc.LcDrawingAllocation AS a JOIN lc.LcSalesOrder AS o ON o.LcSalesOrderId = a.SalesOrderId
                     WHERE a.DrawingId = d.LcDrawingId FOR JSON PATH) AS allocations,
                   (SELECT x.Description AS description, x.Status AS status, x.DecisionNote AS note FROM lc.LcDiscrepancy AS x WHERE x.DrawingId = d.LcDrawingId FOR JSON PATH) AS discrepancies
              FROM lc.LcDrawing AS d LEFT JOIN wfl.Request AS r ON r.RequestId = d.RequestId WHERE d.LcId = @lcId ORDER BY d.DrawingNo;
            """, new { lcId }, cancellationToken: ct))).Select(r =>
        {
            var d = (IDictionary<string, object?>)r;
            foreach (var k in JsonLists)
                d[k] = d[k] is string json ? JsonSerializer.Deserialize<JsonElement>(json) : JsonSerializer.Deserialize<JsonElement>("[]");
            return d;
        });
        var amendments = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT AmendmentNo AS amendmentNo, Origin AS origin, ChangeKinds AS changeKinds, AmountDelta AS amountDelta, NewAmount AS newAmount, NewExpiryDate AS newExpiryDate,
                   Status AS status, BankIssuedOn AS bankIssuedOn, Reason AS reason
              FROM lc.LcAmendment WHERE LcId = @lcId ORDER BY LcAmendmentId;
            """, new { lcId }, cancellationToken: ct));
        var documents = await LcDocuments.ListAsync(u.Connection, lcId, internalView, ct);
        return Results.Ok(new { lc, terms, orders, drawings, amendments, documents });
    }

    private static async Task<IResult> AttachAsync(Guid id, LcDocumentBody b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await SalesEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        await LcDocuments.LinkAsync(u, tx, await IdAsync(u, tx, id, ct), b.Document, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>FR-LCE-013: a sales order's approval request on the credit, refused at once when the credit has not enough available.</summary>
    private static async Task<IResult> OrderAsync(Guid id, SalesOrderBody b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        if (string.IsNullOrWhiteSpace(b.OrderRef) || b.OrderDate is null || b.Amount is not > 0)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the sales order's reference, date and amount.");
        await using var u = await SalesEndpoints.OpenAsync(http, db, "req.create");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        var lcId = await IdAsync(u, tx, id, ct);
        var (lcNo, currency, customer) = await u.Connection.QuerySingleAsync<(string, string, string)>(new CommandDefinition(
            """
            SELECT l.LcNumber, cur.Code, cp.NameEn FROM lc.LetterOfCredit AS l JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId
              JOIN lc.Counterparty AS cp ON cp.CounterpartyId = l.CounterpartyId WHERE l.LetterOfCreditId = @lcId;
            """, new { lcId }, tx, cancellationToken: ct));
        var form = JsonSerializer.Serialize(new
        {
            title = string.IsNullOrWhiteSpace(b.Title) ? $"Sales order {b.OrderRef.Trim()} on {lcNo}" : b.Title.Trim(), orderRef = b.OrderRef.Trim(),
            orderDate = b.OrderDate.Value.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture), amount = new { value = b.Amount, currency },
            deliveryDate = b.DeliveryDate?.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture), customerName = customer, notes = b.Notes?.Trim(),
        });
        var (requestId, publicId) = await SalesLcStore.RaiseOrderAsync(u.Connection, tx, actor, lcId, form, clock.GetUtcNow(), ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REQUEST_CREATED", "TREASURY", "wfl.Request", requestId,
            AfterJson: JsonSerializer.Serialize(new { type = "SALES_ORDER_APPROVAL", lc = id, b.OrderRef, b.Amount })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/requests/{publicId}", new { id = publicId });
    }

    /// <summary>FR-LCE-016: the collection documents' request on the credit, with the documents' amount and its allocation to the earmarked orders.</summary>
    private static async Task<IResult> CollectionAsync(Guid id, CollectionBody b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        if (b.Amount is not > 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the documents' amount.");
        await using var u = await SalesEndpoints.OpenAsync(http, db, "req.create");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        var lcId = await IdAsync(u, tx, id, ct);
        var (lcNo, currency, customer) = await u.Connection.QuerySingleAsync<(string, string, string)>(new CommandDefinition(
            """
            SELECT l.LcNumber, cur.Code, cp.NameEn FROM lc.LetterOfCredit AS l JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId
              JOIN lc.Counterparty AS cp ON cp.CounterpartyId = l.CounterpartyId WHERE l.LetterOfCreditId = @lcId;
            """, new { lcId }, tx, cancellationToken: ct));
        var form = JsonSerializer.Serialize(new
        {
            title = string.IsNullOrWhiteSpace(b.Title) ? $"Collection documents on {lcNo}" : b.Title.Trim(), amount = new { value = b.Amount, currency },
            shipmentDate = b.ShipmentDate?.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture), invoiceRefs = b.InvoiceRefs?.Trim(), customerName = customer,
            collection = new { allocations = (b.Allocations ?? []).Select(a => new { order = a.Order, amount = a.Amount }) }, notes = b.Notes?.Trim(),
        });
        var (requestId, publicId) = await SalesLcStore.RaiseCollectionAsync(u.Connection, tx, actor, lcId, form, clock.GetUtcNow(), ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REQUEST_CREATED", "TREASURY", "wfl.Request", requestId,
            AfterJson: JsonSerializer.Serialize(new { type = "COLLECTION_DOCS_REQUEST", lc = id, b.Amount })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/requests/{publicId}", new { id = publicId });
    }

    private static async Task<IResult> CloseOrderAsync(Guid id, OrderCloseBody b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await SalesEndpoints.OpenAsync(http, db, "lc.order.release");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        var p = await ScopeAsync(u, ct, tx);
        p.Add("id", id);
        var order = await u.Connection.QuerySingleOrDefaultAsync<(long Id, long CompanyId)?>(new CommandDefinition(
            $"SELECT o.LcSalesOrderId, l.CompanyId FROM lc.LcSalesOrder AS o JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = o.LcId WHERE o.PublicId = @id AND {Visible};", p, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        await SalesLcStore.CloseOrderAsync(u.Connection, tx, actor, order.Id, b.Cancel == true, b.Reason ?? "", await Delegations.TodayAsync(u.Connection, tx, clock.GetUtcNow(), ct), ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(b.Cancel == true ? "SALES_ORDER_CANCELLED" : "SALES_ORDER_RELEASED", "TREASURY", "lc.LcSalesOrder", order.Id,
            AfterJson: JsonSerializer.Serialize(new { reason = b.Reason?.Trim() })), order.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> InTxAsync(Guid id, HttpContext http, SqlConnectionFactory db, string audit, Func<BoundUser, SqlTransaction, Actor, long, CancellationToken, Task<object?>> act)
    {
        await using var u = await SalesEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        var lcId = await IdAsync(u, tx, id, ct);
        var result = await act(u, tx, actor, lcId, ct);
        var company = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition("SELECT CompanyId FROM lc.LetterOfCredit WHERE LetterOfCreditId = @lcId;", new { lcId }, tx,
            cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(audit, "TREASURY", "lc.LetterOfCredit", lcId, AfterJson: JsonSerializer.Serialize(result)), company, ct);
        await tx.CommitAsync(ct);
        return result is null ? Results.NoContent() : Results.Ok(result);
    }

    private static Task<IResult> DecideAsync(Guid id, int no, DrawingDecisionBody b, HttpContext http, SqlConnectionFactory db) =>
        InTxAsync(id, http, db, "LC_DRAWING_DECIDED", async (u, tx, actor, lcId, ct) =>
        {
            await SalesLcStore.DecideDrawingAsync(u.Connection, tx, actor, lcId, no, b.Status?.Trim().ToUpperInvariant() ?? "", ct);
            return new { drawingNo = no, status = b.Status };
        });

    private static Task<IResult> SettleAsync(Guid id, int no, SettlementBody b, HttpContext http, SqlConnectionFactory db) =>
        InTxAsync(id, http, db, "LC_DRAWING_SETTLED", async (u, tx, actor, lcId, ct) =>
        {
            await SalesLcStore.SettleDrawingAsync(u.Connection, tx, actor, lcId, no, b.Amount, b.SettledOn.ToDateTime(TimeOnly.MinValue), ct);
            return new { drawingNo = no, amount = b.Amount };
        });

    private static Task<IResult> DiscrepancyAsync(Guid id, int no, DiscrepancyBody b, HttpContext http, SqlConnectionFactory db) =>
        InTxAsync(id, http, db, "LC_DISCREPANCY_OPENED", async (u, tx, actor, lcId, ct) =>
        {
            await SalesLcStore.OpenDiscrepancyAsync(u.Connection, tx, actor, lcId, no, b.Description ?? "", ct);
            return new { drawingNo = no };
        });

    private static Task<IResult> DiscrepancyDecisionAsync(Guid id, int no, DiscrepancyDecisionBody b, HttpContext http, SqlConnectionFactory db) =>
        InTxAsync(id, http, db, "LC_DISCREPANCY_DECIDED", async (u, tx, actor, lcId, ct) =>
        {
            var open = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                """
                SELECT TOP (1) x.LcDiscrepancyId FROM lc.LcDiscrepancy AS x JOIN lc.LcDrawing AS d ON d.LcDrawingId = x.DrawingId
                 WHERE x.LcId = @lcId AND d.DrawingNo = @no AND x.Status = 'OPEN' ORDER BY x.LcDiscrepancyId;
                """, new { lcId, no }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
            await SalesLcStore.DecideDiscrepancyAsync(u.Connection, tx, actor, lcId, open, b.Status?.Trim().ToUpperInvariant() ?? "", b.Note ?? "", ct);
            return new { drawingNo = no, status = b.Status, note = b.Note };
        });

    private static Task<IResult> AmendAsync(Guid id, SalesAmendmentBody b, HttpContext http, SqlConnectionFactory db) =>
        InTxAsync(id, http, db, "LC_AMENDMENT_RECORDED", async (u, tx, actor, lcId, ct) =>
        {
            if (b.BankIssuedOn is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date of the amendment.");
            var (amendment, warnings) = await SalesLcStore.AmendAsync(u.Connection, tx, actor, lcId, new SalesAmendment(b.Origin?.Trim().ToUpperInvariant() ?? "RECEIVED_FROM_CUSTOMER",
                b.NewAmount, b.NewExpiryDate?.ToDateTime(TimeOnly.MinValue), b.NewLatestShipmentDate?.ToDateTime(TimeOnly.MinValue), b.BankAmendmentRef,
                b.BankIssuedOn.Value.ToDateTime(TimeOnly.MinValue), b.Decision?.Trim().ToUpperInvariant() ?? "", b.Reason), ct);
            return new { amendment, decision = b.Decision, b.NewAmount, warnings };
        });

    private static Task<IResult> CloseAsync(Guid id, LcCloseBody b, HttpContext http, SqlConnectionFactory db, TimeProvider clock) =>
        InTxAsync(id, http, db, "LC_CLOSED", async (u, tx, actor, lcId, ct) =>
        {
            await SalesLcStore.CloseAsync(u.Connection, tx, actor, lcId, b.Reason ?? "", await Delegations.TodayAsync(u.Connection, tx, clock.GetUtcNow(), ct), ct);
            return new { status = "CLOSED" };
        });

    /// <summary>FR-LCE-023: the comparison of the credit with its proforma, run now; returns the lines with their verdicts.</summary>
    private static Task<IResult> CompareAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock) =>
        InTxAsync(id, http, db, "LC_TERMS_COMPARED", async (u, tx, actor, lcId, ct) =>
        {
            var lines = await SalesLcStore.CompareAsync(u.Connection, tx, actor, lcId, clock.GetUtcNow(), ct);
            return new { lines = lines.Select(l => new { field = l.FieldKey, baseline = l.Baseline, received = l.Received, verdict = l.Verdict }) };
        });

    /// <summary>The latest comparison of the credit's current terms, with the treasury's decisions.</summary>
    private static async Task<IResult> ComparisonAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request);
        await using var u = await SalesEndpoints.OpenAsync(http, db, "lc.compare");
        var ct = http.RequestAborted;
        var lcId = await IdAsync(u, null, id, ct);
        var head = await u.Connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT TOP (1) c.LcTermsComparisonId AS id, c.RunAt AS runAt, c.Status AS status, c.SummaryJson AS summary
              FROM lc.LcTermsComparison AS c JOIN lc.LetterOfCredit AS l ON l.CurrentTermsId = c.ReceivedTermsId
             WHERE l.LetterOfCreditId = @lcId ORDER BY c.RunAt DESC, c.LcTermsComparisonId DESC;
            """, new { lcId }, cancellationToken: ct));
        if (head is null) return Results.Ok(new { comparison = (object?)null, lines = Array.Empty<object>() });
        var row = (IDictionary<string, object?>)head;
        var lines = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT FieldKey AS field, BaselineValue AS baseline, ReceivedValue AS received, Verdict AS verdict, Decision AS decision, DecisionNote AS note
              FROM lc.LcTermsComparisonLine WHERE ComparisonId = @c ORDER BY LcTermsComparisonLineId;
            """, new { c = row["id"] }, cancellationToken: ct));
        row.Remove("id");
        return Results.Ok(new { comparison = row, lines });
    }

    private static Task<IResult> DecideLineAsync(Guid id, string field, ComparisonDecisionBody b, HttpContext http, SqlConnectionFactory db) =>
        InTxAsync(id, http, db, "LC_COMPARISON_DECIDED", async (u, tx, actor, lcId, ct) =>
        {
            await SalesLcStore.DecideComparisonAsync(u.Connection, tx, actor, lcId, field, b.Decision?.Trim().ToUpperInvariant() ?? "", b.Note, ct);
            return new { field, decision = b.Decision };
        });
}

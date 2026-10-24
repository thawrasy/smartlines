using System.Globalization;
using System.Text.Json;
using BankFas.Core.Lc;
using BankFas.Data.Notifications;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Lc;

/// <summary>A letter of credit received from a customer, as the treasury records it (FR-LCE-009).</summary>
public sealed record NewReceivedLc(long CompanyId, string LcNumber, long CustomerId, long? InstitutionId, string? OtherBankText, string? OtherBankBic, DateTime ReceivedDate,
    long? ProformaId, JsonElement? Terms, JsonElement? Documents, string? BankReference, string? ErpReference, IReadOnlyCollection<string> Acknowledged, string? WarningReason);

/// <summary>An amendment of a received credit, recorded with our decision (FR-LCE-020).</summary>
public sealed record SalesAmendment(string Origin, decimal? NewAmount, DateTime? NewExpiryDate, DateTime? NewLatestShipmentDate, string? BankAmendmentRef, DateTime BankIssuedOn,
    string Decision, string? Reason);

/// <summary>
/// The letters of credit received from customers (spec 14 section 4.3 and 5.3; S4 batches C to E). A received credit
/// is a LetterOfCredit of class SALES with locked RECEIVED terms, ACTIVE from its recording; it consumes no credit
/// limit and has no reservation (FR-LCE-027). Its balance is LCAmount = EarmarkedRemaining + Drawn + Available
/// (BR-LCE-009): a sales order approved through SALES_ORDER_APPROVAL earmarks part of it under the credit's row lock
/// (lc.earmark_sales_order); the collection documents of COLLECTION_DOCS_REQUEST convert earmarks into a drawing
/// (lc.convert_earmark), and the part of the drawing earmarked to no order comes out of what is available; a refusal of
/// the documents gives everything back (BR-LCE-013). The cached EarmarkedRemaining and DrawnAmount move in the same
/// statement as their rows, and JOB-LC-RECONCILE checks them nightly.
/// </summary>
public static class SalesLcStore
{
    public sealed class Lc
    {
        public long LetterOfCreditId { get; init; }
        public long CompanyId { get; init; }
        public string Status { get; init; } = "";
        public string LcNumber { get; init; } = "";
        public int CurrencyId { get; init; }
        public decimal Amount { get; init; }
        public decimal TolerancePlusPct { get; init; }
        public decimal DrawnAmount { get; init; }
        public decimal SettledAmount { get; init; }
        public decimal EarmarkedRemaining { get; init; }
        public DateTime ExpiryDate { get; init; }
        public DateTime? LatestShipmentDate { get; init; }
        public long CurrentTermsId { get; init; }
        public long CounterpartyId { get; init; }
        public long? ProformaId { get; init; }
        public int AmendmentNo { get; init; }
    }

    /// <summary>The credit's row, locked for the rest of the transaction (BR-LCE-010: every earmark and conversion reads the balance under this lock).</summary>
    public static async Task<Lc> LockAsync(SqlConnection c, SqlTransaction tx, long lcId, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<Lc>(new CommandDefinition(
            """
            SELECT LetterOfCreditId, CompanyId, Status, LcNumber, CurrencyId, Amount, TolerancePlusPct, DrawnAmount, SettledAmount, EarmarkedRemaining, ExpiryDate,
                   LatestShipmentDate, CurrentTermsId, CounterpartyId, ProformaId, AmendmentNo
              FROM lc.LetterOfCredit WITH (UPDLOCK, HOLDLOCK) WHERE LetterOfCreditId = @id AND LcClass = 'SALES';
            """, new { id = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false)
        ?? throw new WorkflowRefusalException(404, "NOT_FOUND", "The letter of credit does not exist or is not visible to you.");

    private static async Task<int> DecimalsAsync(SqlConnection c, SqlTransaction? tx, int currency, CancellationToken ct) =>
        await c.ExecuteScalarAsync<int>(new CommandDefinition("SELECT Decimals FROM ref.Currency WHERE CurrencyId = @c;", new { c = currency }, tx, cancellationToken: ct)).ConfigureAwait(false);

    /// <summary>What may still be earmarked: the cap (the amount, with the plus tolerance when lc.earmark.cap_includes_tolerance holds) less the earmarks and the drawn (BR-LCE-009, 010).</summary>
    public static async Task<decimal> AvailableAsync(SqlConnection c, SqlTransaction tx, Lc lc, CancellationToken ct)
    {
        var s = await FacilityHooks.SettingsAsync(c, tx, ct, "lc.earmark.cap_includes_tolerance").ConfigureAwait(false);
        var cap = SalesRules.EarmarkCap(lc.Amount, lc.TolerancePlusPct, s.GetValueOrDefault("lc.earmark.cap_includes_tolerance") == "true",
            await DecimalsAsync(c, tx, lc.CurrencyId, ct).ConfigureAwait(false));
        return cap - lc.EarmarkedRemaining - lc.DrawnAmount;
    }

    // ---------- recording a received credit ----------

    /// <summary>
    /// FR-LCE-009, BR-LCE-007: the credit with its RECEIVED terms (a copy of the proforma's when it is linked, with the
    /// values given), locked at once; ACTIVE, the customer the applicant and the company the beneficiary; no utilisation.
    /// A number already recorded for the same customer (V-LCE-12) or an amount above the proforma's total with its
    /// tolerance (V-LCE-13) is a warning the treasury acknowledges with a written reason. LC.RECEIVED goes to the proforma's
    /// requester and to the treasury.
    /// </summary>
    public static async Task<(long LcId, IReadOnlyList<string> Warnings)> RecordAsync(SqlConnection c, SqlTransaction tx, Actor actor, NewReceivedLc r, DateTimeOffset now,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        ArgumentNullException.ThrowIfNull(r);
        if (!actor.Permissions.Contains("lc.export.record")) throw WorkflowRefusalException.Forbidden("You may not record received letters of credit.");
        var number = r.LcNumber.Trim();
        if (number.Length is 0 or > 60) throw WorkflowRefusalException.Missing("V-LCE-FIELD", "Give the number of the letter of credit (up to 60 characters).");
        var normalised = IssuanceHooks.Normalise(number);
        var today = await Delegations.TodayAsync(c, tx, now, ct).ConfigureAwait(false);
        if (r.ReceivedDate.Date > today) throw WorkflowRefusalException.Missing("V-LCE-FIELD", "The credit is received today or earlier.");
        if (r.OtherBankBic is { } bic && !System.Text.RegularExpressions.Regex.IsMatch(bic, "^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$"))
            throw WorkflowRefusalException.Missing("V-LCT-20", "The customer's bank BIC has 8 or 11 letters and digits.");

        // The proforma, when linked, must be the same company's and customer's (BR-LCE-018: one proforma may take several credits).
        (long TermsId, decimal Total, int CurrencyId, DateTime IssueDate, int? Validity)? proforma = null;
        if (r.ProformaId is { } pid)
            proforma = await c.QuerySingleOrDefaultAsync<(long, decimal, int, DateTime, int?)?>(new CommandDefinition(
                "SELECT TermsId, Total, CurrencyId, IssueDate, OfferValidityDays FROM lc.ProformaInvoice WHERE ProformaInvoiceId = @pid AND CompanyId = @co AND CustomerId = @cu AND Status <> 'VOID';",
                new { pid, co = r.CompanyId, cu = r.CustomerId }, tx, cancellationToken: ct)).ConfigureAwait(false)
                ?? throw WorkflowRefusalException.Missing("V-LCE-FIELD", "The proforma is not one of this company and customer, or it is void.");

        long terms;
        if (proforma is { } pf)
            terms = await TermsStore.CopyAsync(c, tx, pf.TermsId, "LETTER_OF_CREDIT", null, "RECEIVED", 1, "DRAFT", ct).ConfigureAwait(false);
        else
        {
            terms = await c.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT lc.LcTerms (TenantId, OwnerType, Purpose, VersionNo, Status, LcClass, Scope, ApplicantCounterpartyId, BeneficiaryCompanyId, PresentationDays, CreatedBy)
                OUTPUT inserted.LcTermsId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), 'LETTER_OF_CREDIT', 'RECEIVED', 1, 'DRAFT', 'SALES', 'INTERNATIONAL', @cu, @co, 21,
                        CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new { cu = r.CustomerId, co = r.CompanyId }, tx, cancellationToken: ct)).ConfigureAwait(false);
            await TermsStore.ChargesPresetAsync(c, tx, terms, "OWN_BANK", ct).ConfigureAwait(false);
        }
        await c.ExecuteAsync(new CommandDefinition(
            "UPDATE lc.LcTerms SET ApplicantCounterpartyId = @cu, BeneficiaryCompanyId = @co, CopiedFromTermsId = @src WHERE LcTermsId = @t;",
            new { cu = r.CustomerId, co = r.CompanyId, src = proforma?.TermsId, t = terms }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (r.Terms is { ValueKind: JsonValueKind.Object } values) await TermsStore.WriteDraftAsync(c, tx, terms, values, ct).ConfigureAwait(false);
        var row = await TermsStore.RowAsync(c, tx, terms, ct).ConfigureAwait(false);
        if (r.Documents is { ValueKind: JsonValueKind.Array } docs) await TermsStore.SetDocumentsAsync(c, tx, row, docs, ct).ConfigureAwait(false);
        var facts = await c.QuerySingleAsync<(decimal? Amount, int? CurrencyId, string? ExpiryRule, DateTime? ExpiryDate, int? ExpiryDays, string? ShipRule, DateTime? ShipDate,
            int? ShipDays, string Scope, decimal Plus, decimal Minus)>(new CommandDefinition(
            """
            SELECT Amount, CurrencyId, ExpiryRule, ExpiryDate, ExpiryDaysAfterIssue, LatestShipmentRule, LatestShipmentDate, LatestShipmentDaysAfterIssue, Scope, TolerancePlusPct,
                   ToleranceMinusPct
              FROM lc.LcTerms WHERE LcTermsId = @t;
            """, new { t = terms }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (facts.Amount is not > 0 || facts.CurrencyId is null) throw WorkflowRefusalException.Missing("V-LCT-REQUIRED", "Give the amount and the currency of the credit.");
        var expiry = facts.ExpiryRule == "DAYS_AFTER_ISSUE" && facts.ExpiryDays is { } ed ? r.ReceivedDate.Date.AddDays(ed) : facts.ExpiryDate
            ?? throw WorkflowRefusalException.Missing("V-LCT-REQUIRED", "Give the expiry of the credit.");
        DateTime? ship = facts.ShipRule == "DAYS_AFTER_ISSUE" && facts.ShipDays is { } sd ? r.ReceivedDate.Date.AddDays(sd) : facts.ShipDate;
        await TermsStore.LockAsync(c, tx, row, actor.UserId, DateOnly.FromDateTime(today), ct).ConfigureAwait(false);

        // The warnings (V-LCE-12, 13): acknowledged with a written reason, or the recording stops and names them.
        var warnings = new List<string>();
        if (await c.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM lc.LetterOfCredit WHERE LcClass = 'SALES' AND CounterpartyId = @cu AND LcNumberNormalized = @n;", new { cu = r.CustomerId, n = normalised }, tx,
                cancellationToken: ct)).ConfigureAwait(false) > 0)
            warnings.Add("V-LCE-12");
        if (proforma is { } p && p.CurrencyId == facts.CurrencyId)
        {
            var linked = await c.ExecuteScalarAsync<decimal>(new CommandDefinition(
                "SELECT ISNULL(SUM(Amount), 0) FROM lc.LetterOfCredit WHERE ProformaId = @pid AND Status <> 'CANCELLED';", new { pid = r.ProformaId }, tx, cancellationToken: ct))
                .ConfigureAwait(false);
            if (linked + facts.Amount.Value > p.Total * (1 + facts.Plus / 100m)) warnings.Add("V-LCE-13");
            if (p.Validity is { } v && p.IssueDate.AddDays(v) < r.ReceivedDate.Date) warnings.Add("V-LCE-18");
        }
        var unacknowledged = warnings.Where(w => !r.Acknowledged.Contains(w)).ToList();
        if (unacknowledged.Count > 0 || (warnings.Count > 0 && string.IsNullOrWhiteSpace(r.WarningReason)))
            throw new WorkflowRefusalException(409, unacknowledged.FirstOrDefault() ?? warnings[0], unacknowledged.Count > 0
                ? $"Acknowledge with a written reason: {string.Join(", ", unacknowledged.Select(WarningText))}."
                : "Give the reason of the acknowledged warnings.");

        var relationship = r.InstitutionId is { } inst
            ? await c.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT RelationshipId FROM ins.Relationship WHERE CompanyId = @co AND InstitutionId = @i;",
                new { co = r.CompanyId, i = inst }, tx, cancellationToken: ct)).ConfigureAwait(false)
            : null;
        var lcId = await c.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT lc.LetterOfCredit (TenantId, LcClass, Scope, CompanyId, LcNumber, LcNumberNormalized, Status, CounterpartyId, InstitutionId, RelationshipId, OtherBankText,
                                      OtherBankBic, BankReference, ProductId, ProformaId, CurrentTermsId, CurrencyId, Amount, OriginalAmount, TolerancePlusPct, ToleranceMinusPct,
                                      ReceivedDate, ExpiryDate, LatestShipmentDate, CreatedBy)
            OUTPUT inserted.LetterOfCreditId INTO @o
            SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), 'SALES', t.Scope, @co, @no, @norm, 'ACTIVE', @cu, @inst, @rel, @otherText, @otherBic, @bankRef,
                   (SELECT ProductId FROM cat.Product WHERE Code = 'LC_SALES_RECEIVED'), @pf, t.LcTermsId, t.CurrencyId, t.Amount, t.Amount, t.TolerancePlusPct, t.ToleranceMinusPct,
                   @received, @expiry, @ship, @u
              FROM lc.LcTerms AS t WHERE t.LcTermsId = @terms;
            DECLARE @id BIGINT = (SELECT Id FROM @o);
            UPDATE lc.LcTerms SET OwnerId = @id WHERE LcTermsId = @terms AND OwnerId IS NULL;
            IF @erp IS NOT NULL
                INSERT lc.LcExternalRef (TenantId, LcId, SystemCode, RefType, RefValue, NormalizedValue, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @id, 'ERP', 'SALES_CONTRACT', @erp, @erpNorm, @u);
            SELECT @id;
            """,
            new
            {
                co = r.CompanyId, no = number, norm = normalised, cu = r.CustomerId, inst = r.InstitutionId, rel = relationship, otherText = r.OtherBankText?.Trim(),
                otherBic = r.OtherBankBic, bankRef = r.BankReference?.Trim(), pf = r.ProformaId, received = r.ReceivedDate.Date, expiry = expiry.Date, ship = ship?.Date, u = actor.UserId,
                terms, erp = r.ErpReference?.Trim() is { Length: > 0 } e ? e : null, erpNorm = r.ErpReference is { } x ? NormaliseRef(x) : null,
            }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "lc.received", "lc.LetterOfCredit", lcId, new { lcId }, ct).ConfigureAwait(false);
        var requester = r.ProformaId is { } ppid
            ? await c.QuerySingleOrDefaultAsync<(long User, string No)?>(new CommandDefinition(
                "SELECT rq.RequesterUserId, p.ProformaNo FROM lc.ProformaInvoice AS p JOIN wfl.Request AS rq ON rq.RequestId = p.RequestId WHERE p.ProformaInvoiceId = @ppid;",
                new { ppid }, tx, cancellationToken: ct)).ConfigureAwait(false)
            : null;
        var cur = await c.QuerySingleAsync<(string Code, int Decimals)>(new CommandDefinition("SELECT Code, Decimals FROM ref.Currency WHERE CurrencyId = @c;", new { c = facts.CurrencyId },
            tx, cancellationToken: ct)).ConfigureAwait(false);
        await Notifier.RequestAsync(c, tx, new NotificationRequest("LC.RECEIVED", "lc.LetterOfCredit", lcId, $"LC.RECEIVED:{lcId}", r.CompanyId,
            new Dictionary<string, object?>
            {
                ["lcNo"] = number, ["proformaNo"] = requester?.No ?? "—", ["customerName"] = await CustomerNameAsync(c, tx, r.CustomerId, ct).ConfigureAwait(false),
                ["amount"] = facts.Amount.Value.ToString("N" + cur.Decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture), ["currency"] = cur.Code,
            }, $"/sales/lcs/{lcId}", actor.UserId, requester is { } rq ? [rq.User] : null), ct).ConfigureAwait(false);
        return (lcId, warnings);
    }

    private static string WarningText(string code) => code switch
    {
        "V-LCE-12" => "V-LCE-12 this customer already has a credit with this number",
        "V-LCE-13" => "V-LCE-13 the credits exceed the proforma's total with its tolerance",
        "V-LCE-18" => "V-LCE-18 the proforma's offer had expired when the credit came",
        _ => code,
    };

    private static async Task<string?> CustomerNameAsync(SqlConnection c, SqlTransaction tx, long customer, CancellationToken ct) =>
        await c.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT NameEn FROM lc.Counterparty WHERE CounterpartyId = @cu;", new { cu = customer }, tx, cancellationToken: ct))
            .ConfigureAwait(false);

    /// <summary>BR-REQ-006: Arabic-Indic digits to Latin, trimmed, upper case, without spaces.</summary>
    public static string NormaliseRef(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var chars = value.Trim().Select(ch => ch is >= '٠' and <= '٩' ? (char)('0' + (ch - '٠')) : char.ToUpperInvariant(ch)).Where(ch => ch != ' ');
        return new string([.. chars]);
    }

    // ---------- sales orders: the earmark ----------

    /// <summary>
    /// The sales order's request on a received credit (FR-LCE-013): the credit is the request's parent; an amount above what
    /// is available now, a currency other than the credit's, or a credit not active or expired is refused already here
    /// (the binding check is the earmark's).
    /// </summary>
    public static async Task<(long RequestId, Guid PublicId)> RaiseOrderAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, string formJson, DateTimeOffset now,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        var lc = await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        var (requestId, publicId, _) = await RequestEngine.CreateDraftAsync(c, tx, actor, new NewRequest("SALES_ORDER_APPROVAL", lc.CompanyId, null, formJson,
            ParentEntityType: "LETTER_OF_CREDIT", ParentEntityId: lcId), now, ct).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition("UPDATE wfl.Request SET LcId = @lc WHERE RequestId = @r;", new { lc = lcId, r = requestId }, tx, cancellationToken: ct))
            .ConfigureAwait(false);
        var r = await RequestEngine.FindAsync(c, tx, requestId, false, ct).ConfigureAwait(false);
        var today = DateOnly.FromDateTime(await Delegations.TodayAsync(c, tx, now, ct).ConfigureAwait(false));
        var problem = SalesRules.EarmarkProblem(lc.Status, DateOnly.FromDateTime(lc.ExpiryDate), today, r!.CurrencyId == lc.CurrencyId, r.Amount ?? 0,
            await AvailableAsync(c, tx, lc, ct).ConfigureAwait(false));
        if (problem is not null) throw EarmarkRefusal(problem, r.Amount ?? 0, await AvailableAsync(c, tx, lc, ct).ConfigureAwait(false));
        return (requestId, publicId);
    }

    private static WorkflowRefusalException EarmarkRefusal(string code, decimal asked, decimal available) => code switch
    {
        "V-LCE-05" => new WorkflowRefusalException(422, "INSUFFICIENT_LC_BALANCE",
            $"The order asks {asked.ToString("N2", CultureInfo.InvariantCulture)} and the credit has {available.ToString("N2", CultureInfo.InvariantCulture)} available (V-LCE-05)."),
        "V-LCE-06" => WorkflowRefusalException.Missing("CURRENCY_MISMATCH", "The order is in the credit's currency (V-LCE-06)."),
        _ => new WorkflowRefusalException(409, "LC_NOT_ACTIVE", "The credit is not active or has expired (V-LCE-07)."),
    };

    /// <summary>
    /// lc.earmark_sales_order (FR-LCE-014, BR-LCE-010), on the completion of EARMARK, under the credit's row lock: an active
    /// credit not expired, the same currency, an amount within what is available; the order becomes EARMARKED and the
    /// credit's EarmarkedRemaining grows by it. A reference already used on the credit, or a delivery after the latest
    /// shipment, is a warning recorded with the result (V-LCE-08). A replay returns the same order.
    /// </summary>
    public static async Task<object?> EarmarkHookAsync(RequestEngine.HookContext h)
    {
        ArgumentNullException.ThrowIfNull(h);
        if (await h.C.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT LcSalesOrderId FROM lc.LcSalesOrder WHERE RequestId = @r;", new { r = h.Request.RequestId }, h.Tx,
                cancellationToken: h.Ct)).ConfigureAwait(false) is { } done)
            return new { salesOrderId = done, replay = true };
        var lcId = await h.C.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT LcId FROM wfl.Request WHERE RequestId = @r;", new { r = h.Request.RequestId }, h.Tx,
            cancellationToken: h.Ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.State("The sales order names no letter of credit.");
        var lc = await LockAsync(h.C, h.Tx, lcId, h.Ct).ConfigureAwait(false);
        using var form = JsonDocument.Parse(h.Request.FormDataJson ?? "{}");
        string? S(string k) => form.RootElement.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()!.Trim() : null;
        var orderRef = S("orderRef") is { Length: > 0 and <= 60 } o ? o : throw WorkflowRefusalException.Missing("V-REQ-REQUIRED", "Give the sales order's reference.");
        var orderDate = DateTime.TryParse(S("orderDate"), CultureInfo.InvariantCulture, DateTimeStyles.None, out var od) ? od.Date
            : throw WorkflowRefusalException.Missing("V-REQ-REQUIRED", "Give the sales order's date.");
        DateTime? delivery = DateTime.TryParse(S("deliveryDate"), CultureInfo.InvariantCulture, DateTimeStyles.None, out var dd) ? dd.Date : null;
        var amount = h.Request.Amount ?? 0;
        var today = DateOnly.FromDateTime(await Delegations.TodayAsync(h.C, h.Tx, h.Now, h.Ct).ConfigureAwait(false));
        var available = await AvailableAsync(h.C, h.Tx, lc, h.Ct).ConfigureAwait(false);
        if (SalesRules.EarmarkProblem(lc.Status, DateOnly.FromDateTime(lc.ExpiryDate), today, h.Request.CurrencyId == lc.CurrencyId, amount, available) is { } problem)
            throw EarmarkRefusal(problem, amount, available);
        var warnings = new List<string>();
        if (await h.C.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM lc.LcSalesOrder WHERE LcId = @lc AND OrderRef = @o AND Status <> 'CANCELLED';", new { lc = lcId, o = orderRef }, h.Tx, cancellationToken: h.Ct))
                .ConfigureAwait(false) > 0)
            warnings.Add("V-LCE-08 order reference already used on the credit");
        if (delivery is { } d && lc.LatestShipmentDate is { } ls && d > ls.Date) warnings.Add("V-LCE-08 delivery after the latest shipment");
        var id = await h.C.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT lc.LcSalesOrder (TenantId, CompanyId, LcId, RequestId, OrderRef, OrderDate, Amount, CurrencyId, Status, DeliveryDate, CreatedBy)
            OUTPUT inserted.LcSalesOrderId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @co, @lc, @r, @ref, @date, @a, @cur, 'EARMARKED', @delivery, @u);
            UPDATE lc.LetterOfCredit SET EarmarkedRemaining = EarmarkedRemaining + @a, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LetterOfCreditId = @lc;
            SELECT Id FROM @o;
            """, new { co = lc.CompanyId, lc = lcId, r = h.Request.RequestId, @ref = orderRef, date = orderDate, a = amount, cur = lc.CurrencyId, delivery, u = h.Actor.UserId },
            h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(h.C, h.Tx, "lc.order.earmarked", "lc.LcSalesOrder", id, new { salesOrderId = id, lcId }, h.Ct).ConfigureAwait(false);
        return new { salesOrderId = id, available = available - amount, warnings };
    }

    /// <summary>BR-LCE-012: an order is closed with its remaining earmark freed (lc.order.release), or cancelled whole while nothing of it is converted.</summary>
    public static async Task CloseOrderAsync(SqlConnection c, SqlTransaction tx, Actor actor, long orderId, bool cancel, string reason, DateTime today, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        if (!actor.Permissions.Contains("lc.order.release")) throw WorkflowRefusalException.Forbidden("You may not close sales orders.");
        reason = reason.Trim();
        if (reason.Length is 0 or > 500) throw WorkflowRefusalException.Missing("V-WFL-REASON", "Give the reason (up to 500 characters).");
        var lcId = await c.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT LcId FROM lc.LcSalesOrder WHERE LcSalesOrderId = @id;", new { id = orderId }, tx, cancellationToken: ct))
            .ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        var o = await c.QuerySingleAsync<(string Status, decimal Amount, decimal Converted, decimal Released)>(new CommandDefinition(
            "SELECT Status, Amount, ConvertedAmount, ReleasedAmount FROM lc.LcSalesOrder WITH (UPDLOCK) WHERE LcSalesOrderId = @id;", new { id = orderId }, tx, cancellationToken: ct))
            .ConfigureAwait(false);
        if (o.Status is not ("EARMARKED" or "PARTIALLY_CONVERTED")) throw WorkflowRefusalException.State("Only an earmarked order is closed or cancelled.");
        if (cancel && o.Converted > 0) throw WorkflowRefusalException.State("An order with a conversion is closed, not cancelled (BR-LCE-012).");
        var remaining = o.Amount - o.Converted - o.Released;
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcSalesOrder SET Status = @status, ReleasedAmount = ReleasedAmount + @rel, ClosedOn = @on, ClosedReason = @reason, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE LcSalesOrderId = @id;
            UPDATE lc.LetterOfCredit SET EarmarkedRemaining = EarmarkedRemaining - @remaining, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LetterOfCreditId = @lc;
            """, new { status = cancel ? "CANCELLED" : "RELEASED", rel = cancel ? 0 : remaining, on = today.Date, reason, u = actor.UserId, id = orderId, remaining, lc = lcId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, cancel ? "lc.order.cancelled" : "lc.order.released", "lc.LcSalesOrder", orderId, new { salesOrderId = orderId, freed = remaining }, ct)
            .ConfigureAwait(false);
    }

    // ---------- collection documents: the conversion ----------

    public sealed record Allocation(Guid Order, decimal Amount);

    /// <summary>The allocations of a collection documents request's form (key "collection": allocations of orders and amounts).</summary>
    public static IReadOnlyList<Allocation> Allocations(string? formJson)
    {
        using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(formJson) ? "{}" : formJson);
        var list = new List<Allocation>();
        if (doc.RootElement.TryGetProperty("collection", out var col) && col.ValueKind == JsonValueKind.Object && col.TryGetProperty("allocations", out var a)
            && a.ValueKind == JsonValueKind.Array)
            foreach (var x in a.EnumerateArray())
                if (x.TryGetProperty("order", out var o) && Guid.TryParse(o.GetString(), out var g) && x.TryGetProperty("amount", out var m) && m.ValueKind == JsonValueKind.Number)
                    list.Add(new Allocation(g, m.GetDecimal()));
        return list;
    }

    /// <summary>The collection documents' request on a received credit (FR-LCE-016): the credit is its parent.</summary>
    public static async Task<(long RequestId, Guid PublicId)> RaiseCollectionAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, string formJson, DateTimeOffset now,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        var lc = await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        if (lc.Status != "ACTIVE") throw new WorkflowRefusalException(409, "LC_NOT_ACTIVE", "The credit is not active (V-LCE-07).");
        var (requestId, publicId, _) = await RequestEngine.CreateDraftAsync(c, tx, actor, new NewRequest("COLLECTION_DOCS_REQUEST", lc.CompanyId, null, formJson,
            ParentEntityType: "LETTER_OF_CREDIT", ParentEntityId: lcId), now, ct).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition("UPDATE wfl.Request SET LcId = @lc WHERE RequestId = @r;", new { lc = lcId, r = requestId }, tx, cancellationToken: ct))
            .ConfigureAwait(false);
        return (requestId, publicId);
    }

    /// <summary>
    /// lc.convert_earmark (FR-LCE-017, BR-LCE-011), on the completion of DOCS_ISSUED, under the credit's row lock: each
    /// part is within its order's remaining earmark and their sum within the documents' amount (V-LCE-09), and the rest is
    /// within what is available (V-LCE-10). It writes the drawing (PRESENTED, on today), its allocations, the orders'
    /// conversions and states, and the credit's drawn and earmarked totals; LC.DOCS_DELIVERED goes to the requester.
    /// </summary>
    public static async Task<object?> ConvertHookAsync(RequestEngine.HookContext h)
    {
        ArgumentNullException.ThrowIfNull(h);
        if (await h.C.QuerySingleOrDefaultAsync<(long Id, int No)?>(new CommandDefinition("SELECT LcDrawingId, DrawingNo FROM lc.LcDrawing WHERE RequestId = @r;",
                new { r = h.Request.RequestId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false) is { } done)
            return new { drawingId = done.Id, drawingNo = done.No, replay = true };
        var lcId = await h.C.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT LcId FROM wfl.Request WHERE RequestId = @r;", new { r = h.Request.RequestId }, h.Tx,
            cancellationToken: h.Ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.State("The documents name no letter of credit.");
        var lc = await LockAsync(h.C, h.Tx, lcId, h.Ct).ConfigureAwait(false);
        if (lc.Status != "ACTIVE") throw new WorkflowRefusalException(409, "LC_NOT_ACTIVE", "The credit is not active (V-LCE-07).");
        if (h.Request.CurrencyId != lc.CurrencyId) throw WorkflowRefusalException.Missing("CURRENCY_MISMATCH", "The documents are in the credit's currency.");
        var drawing = h.Request.Amount ?? 0;
        var allocations = Allocations(h.Request.FormDataJson);
        var orders = (await h.C.QueryAsync<(Guid PublicId, long Id, decimal Amount, decimal Converted, decimal Released, string Status)>(new CommandDefinition(
            "SELECT PublicId, LcSalesOrderId, Amount, ConvertedAmount, ReleasedAmount, Status FROM lc.LcSalesOrder WITH (UPDLOCK) WHERE LcId = @lc;", new { lc = lcId }, h.Tx,
            cancellationToken: h.Ct)).ConfigureAwait(false)).ToDictionary(o => o.PublicId);
        var parts = new List<ConversionPart>();
        foreach (var a in allocations)
        {
            if (!orders.TryGetValue(a.Order, out var o) || o.Status is not ("EARMARKED" or "PARTIALLY_CONVERTED"))
                throw WorkflowRefusalException.Missing("V-LCE-09", "An allocation names an order that is not earmarked on this credit.");
            parts.Add(new ConversionPart(o.Id, a.Amount, o.Amount - o.Converted - o.Released));
        }
        var available = await AvailableAsync(h.C, h.Tx, lc, h.Ct).ConfigureAwait(false);
        switch (SalesRules.ConversionProblem(drawing, parts, available))
        {
            case "V-LCE-09": throw WorkflowRefusalException.Missing("V-LCE-09", "Each allocation is within its order's remaining earmark and all of them within the documents' amount.");
            case "V-LCE-10":
                throw WorkflowRefusalException.Missing("V-LCE-10",
                    $"The part earmarked to no order ({(drawing - parts.Sum(p => p.Amount)).ToString("N2", CultureInfo.InvariantCulture)}) is above what the credit has available ({available.ToString("N2", CultureInfo.InvariantCulture)}).");
        }
        using var form = JsonDocument.Parse(h.Request.FormDataJson ?? "{}");
        var invoices = form.RootElement.TryGetProperty("invoiceRefs", out var iv) && iv.ValueKind == JsonValueKind.String ? iv.GetString() : null;
        var today = await Delegations.TodayAsync(h.C, h.Tx, h.Now, h.Ct).ConfigureAwait(false);
        var no = await h.C.ExecuteScalarAsync<int>(new CommandDefinition("SELECT ISNULL(MAX(DrawingNo), 0) + 1 FROM lc.LcDrawing WHERE LcId = @lc;", new { lc = lcId }, h.Tx,
            cancellationToken: h.Ct)).ConfigureAwait(false);
        var id = await h.C.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT lc.LcDrawing (TenantId, CompanyId, LcId, DrawingNo, Amount, CurrencyId, PresentationDate, InvoiceRefsText, Status, RequestId, CreatedBy)
            OUTPUT inserted.LcDrawingId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @co, @lc, @no, @d, @cur, @today, @inv, 'PRESENTED', @r, @u);
            SELECT Id FROM @o;
            """, new { co = lc.CompanyId, lc = lcId, no, d = drawing, cur = lc.CurrencyId, today, inv = invoices is { Length: > 1000 } ? invoices[..1000] : invoices, r = h.Request.RequestId,
                u = h.Actor.UserId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        foreach (var p in parts)
            await h.C.ExecuteAsync(new CommandDefinition(
                """
                INSERT lc.LcDrawingAllocation (TenantId, LcId, DrawingId, SalesOrderId, Amount, CurrencyId, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @lc, @dr, @so, @a, @cur, @u);
                UPDATE lc.LcSalesOrder SET ConvertedAmount = ConvertedAmount + @a,
                       Status = CASE WHEN ConvertedAmount + @a + ReleasedAmount >= Amount AND ConvertedAmount + @a = Amount THEN 'CONVERTED' ELSE 'PARTIALLY_CONVERTED' END,
                       UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
                 WHERE LcSalesOrderId = @so;
                """, new { lc = lcId, dr = id, so = p.SalesOrderId, a = p.Amount, cur = lc.CurrencyId, u = h.Actor.UserId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        var allocated = parts.Sum(p => p.Amount);
        await h.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LetterOfCredit SET DrawnAmount = DrawnAmount + @d, EarmarkedRemaining = EarmarkedRemaining - @allocated, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE LetterOfCreditId = @lc;
            """, new { d = drawing, allocated, u = h.Actor.UserId, lc = lcId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(h.C, h.Tx, "lc.drawing.recorded", "lc.LetterOfCredit", lcId, new { lc = lcId, drawing = id }, h.Ct).ConfigureAwait(false);
        var cur = await h.C.QuerySingleAsync<(string Code, int Decimals)>(new CommandDefinition("SELECT Code, Decimals FROM ref.Currency WHERE CurrencyId = @c;", new { c = lc.CurrencyId },
            h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        await Notifier.RequestAsync(h.C, h.Tx, new NotificationRequest("LC.DOCS_DELIVERED", "lc.LetterOfCredit", lcId, $"LC.DOCS_DELIVERED:{id}", lc.CompanyId,
            new Dictionary<string, object?>
            {
                ["lcNo"] = lc.LcNumber, ["requestNo"] = h.Request.RequestNo, ["customerName"] = await CustomerNameAsync(h.C, h.Tx, lc.CounterpartyId, h.Ct).ConfigureAwait(false),
                ["amount"] = drawing.ToString("N" + cur.Decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture), ["currency"] = cur.Code,
            }, $"/requests/{h.Request.PublicId}", h.Actor.UserId, [h.Request.RequesterUserId]), h.Ct).ConfigureAwait(false);
        return new { drawingId = id, drawingNo = no, allocated, unallocated = drawing - allocated };
    }

    // ---------- drawings after the hand-over ----------

    /// <summary>
    /// FR-LCE-019, BR-LCE-013: the customer's bank accepts, finds discrepancies in, refuses or the treasury cancels the
    /// documents. A refusal or cancellation gives back the drawn amount and the orders' conversions: each order returns to
    /// PARTIALLY_CONVERTED or EARMARKED with its remaining earmark, so the balance holds.
    /// </summary>
    public static async Task DecideDrawingAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, int drawingNo, string status, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        if (!actor.Permissions.Contains("lc.drawing.record")) throw WorkflowRefusalException.Forbidden("You may not record drawings.");
        if (status is not ("ACCEPTED" or "DISCREPANT" or "REFUSED" or "CANCELLED")) throw WorkflowRefusalException.Missing("V-LCE-FIELD", "The status is ACCEPTED, DISCREPANT, REFUSED or CANCELLED.");
        await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        var dr = await c.QuerySingleOrDefaultAsync<(long Id, string Status, decimal Amount, decimal Settled)?>(new CommandDefinition(
            "SELECT LcDrawingId, Status, Amount, SettledAmount FROM lc.LcDrawing WITH (UPDLOCK) WHERE LcId = @lc AND DrawingNo = @no;", new { lc = lcId, no = drawingNo }, tx,
            cancellationToken: ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        if (dr.Status is not ("PRESENTED" or "DISCREPANT" or "ACCEPTED")) throw WorkflowRefusalException.State("The drawing is settled, refused or cancelled.");
        if (status is "REFUSED" or "CANCELLED" && dr.Settled > 0) throw WorkflowRefusalException.State("A drawing with a payment is not refused.");
        await c.ExecuteAsync(new CommandDefinition(
            "UPDATE lc.LcDrawing SET Status = @s, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LcDrawingId = @id;", new { s = status, u = actor.UserId, id = dr.Id }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        if (status is not ("REFUSED" or "CANCELLED")) return;
        var back = await c.ExecuteScalarAsync<decimal>(new CommandDefinition(
            """
            UPDATE o SET ConvertedAmount = o.ConvertedAmount - a.Amount,
                   Status = CASE WHEN o.ConvertedAmount - a.Amount = 0 THEN 'EARMARKED' ELSE 'PARTIALLY_CONVERTED' END, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
              FROM lc.LcSalesOrder AS o JOIN lc.LcDrawingAllocation AS a ON a.SalesOrderId = o.LcSalesOrderId
             WHERE a.DrawingId = @id;
            SELECT ISNULL(SUM(Amount), 0) FROM lc.LcDrawingAllocation WHERE DrawingId = @id;
            """, new { u = actor.UserId, id = dr.Id }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LetterOfCredit SET DrawnAmount = DrawnAmount - @d, EarmarkedRemaining = EarmarkedRemaining + @back, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE LetterOfCreditId = @lc;
            """, new { d = dr.Amount, back, u = actor.UserId, lc = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "lc.drawing.refused", "lc.LetterOfCredit", lcId, new { lc = lcId, drawing = dr.Id, status }, ct).ConfigureAwait(false);
    }

    /// <summary>The customer's bank pays an accepted drawing (FR-LCE-019): within the drawing; SETTLED when paid in full.</summary>
    public static async Task SettleDrawingAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, int drawingNo, decimal amount, DateTime on, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        if (!actor.Permissions.Contains("lc.drawing.record")) throw WorkflowRefusalException.Forbidden("You may not record drawings.");
        await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        var dr = await c.QuerySingleOrDefaultAsync<(long Id, string Status, decimal Amount, decimal Settled)?>(new CommandDefinition(
            "SELECT LcDrawingId, Status, Amount, SettledAmount FROM lc.LcDrawing WITH (UPDLOCK) WHERE LcId = @lc AND DrawingNo = @no;", new { lc = lcId, no = drawingNo }, tx,
            cancellationToken: ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        if (dr.Status != "ACCEPTED") throw WorkflowRefusalException.State("Only accepted documents are paid.");
        if (amount <= 0 || dr.Settled + amount > dr.Amount) throw WorkflowRefusalException.Missing("V-LCE-FIELD", "The payment is above zero and within the drawing.");
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcDrawing SET SettledAmount = SettledAmount + @a, LastSettledOn = @on, Status = CASE WHEN SettledAmount + @a = Amount THEN 'SETTLED' ELSE Status END,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE LcDrawingId = @id;
            UPDATE lc.LetterOfCredit SET SettledAmount = SettledAmount + @a, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LetterOfCreditId = @lc;
            """, new { a = amount, on = on.Date, u = actor.UserId, id = dr.Id, lc = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false);
    }

    /// <summary>FR-LCE-021: a discrepancy the customer's bank found in our documents; the drawing waits as DISCREPANT and LC.DISCREPANCY_OPEN goes out.</summary>
    public static async Task<long> OpenDiscrepancyAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, int drawingNo, string description, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        if (!actor.Permissions.Contains("lc.drawing.record")) throw WorkflowRefusalException.Forbidden("You may not record drawings.");
        description = description.Trim();
        if (description.Length is 0 or > 4000) throw WorkflowRefusalException.Missing("V-LCE-FIELD", "Describe the discrepancy (up to 4000 characters).");
        var lc = await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        var dr = await c.QuerySingleOrDefaultAsync<(long Id, string Status)?>(new CommandDefinition(
            "SELECT LcDrawingId, Status FROM lc.LcDrawing WITH (UPDLOCK) WHERE LcId = @lc AND DrawingNo = @no;", new { lc = lcId, no = drawingNo }, tx, cancellationToken: ct))
            .ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        if (dr.Status is not ("PRESENTED" or "DISCREPANT")) throw WorkflowRefusalException.State("A discrepancy is recorded on documents waiting for the bank's decision.");
        var id = await c.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT lc.LcDiscrepancy (TenantId, LcId, DrawingId, Source, Description, Status, CreatedBy)
            OUTPUT inserted.LcDiscrepancyId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @lc, @dr, 'BANK_NOTICE', @text, 'OPEN', @u);
            UPDATE lc.LcDrawing SET Status = 'DISCREPANT', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LcDrawingId = @dr;
            SELECT Id FROM @o;
            """, new { lc = lcId, dr = dr.Id, text = description, u = actor.UserId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await Notifier.RequestAsync(c, tx, new NotificationRequest("LC.DISCREPANCY_OPEN", "lc.LetterOfCredit", lcId, $"LC.DISCREPANCY_OPEN:{id}", lc.CompanyId,
            new Dictionary<string, object?> { ["lcNo"] = lc.LcNumber }, $"/sales/lcs/{lcId}", actor.UserId), ct).ConfigureAwait(false);
        return id;
    }

    /// <summary>The decision on a discrepancy (lc.discrepancy.decide): WAIVED or CORRECTED leave the documents with the bank; REFUSED refuses them (BR-LCE-013).</summary>
    public static async Task DecideDiscrepancyAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, long discrepancyId, string status, string note, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        if (!actor.Permissions.Contains("lc.discrepancy.decide")) throw WorkflowRefusalException.Forbidden("You may not decide discrepancies.");
        if (status is not ("WAIVED" or "CORRECTED" or "REFUSED")) throw WorkflowRefusalException.Missing("V-LCE-FIELD", "The decision is WAIVED, CORRECTED or REFUSED.");
        note = note.Trim();
        if (note.Length is 0 or > 1000) throw WorkflowRefusalException.Missing("V-WFL-REASON", "Give the note of the decision (up to 1000 characters).");
        await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        var d = await c.QuerySingleOrDefaultAsync<(string Status, int? DrawingNo)?>(new CommandDefinition(
            """
            SELECT x.Status, dr.DrawingNo FROM lc.LcDiscrepancy AS x WITH (UPDLOCK) LEFT JOIN lc.LcDrawing AS dr ON dr.LcDrawingId = x.DrawingId
             WHERE x.LcDiscrepancyId = @id AND x.LcId = @lc;
            """, new { id = discrepancyId, lc = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        if (d.Status != "OPEN") throw WorkflowRefusalException.State("The discrepancy is decided.");
        await c.ExecuteAsync(new CommandDefinition(
            "UPDATE lc.LcDiscrepancy SET Status = @s, DecidedBy = @u, DecidedOn = SYSUTCDATETIME(), DecisionNote = @note, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LcDiscrepancyId = @id;",
            new { s = status, u = actor.UserId, note, id = discrepancyId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (status == "REFUSED" && d.DrawingNo is { } no) await DecideDrawingAsync(c, tx, actor, lcId, no, "REFUSED", ct).ConfigureAwait(false);
        else if (d.DrawingNo is { } n2)
            await c.ExecuteAsync(new CommandDefinition(
                """
                UPDATE lc.LcDrawing SET Status = 'PRESENTED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
                 WHERE LcId = @lc AND DrawingNo = @no AND Status = 'DISCREPANT'
                   AND NOT EXISTS (SELECT 1 FROM lc.LcDiscrepancy AS x WHERE x.DrawingId = lc.LcDrawing.LcDrawingId AND x.Status = 'OPEN');
                """, new { u = actor.UserId, lc = lcId, no = n2 }, tx, cancellationToken: ct)).ConfigureAwait(false);
    }

    // ---------- amendments of a received credit ----------

    /// <summary>
    /// FR-LCE-020, BR-LCE-014: an amendment received from the customer (or one we asked for), recorded with our decision.
    /// Accepted, it applies at once: the new amount never below what is earmarked and drawn (V-LCE-11, with the shortfall),
    /// the dates, a new RECEIVED terms version and the next amendment number; a shorter expiry than a pending order's
    /// delivery is a warning. Rejected, it is kept as REJECTED and changes nothing.
    /// </summary>
    public static async Task<(long Id, IReadOnlyList<string> Warnings)> AmendAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, SalesAmendment a, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        ArgumentNullException.ThrowIfNull(a);
        if (!actor.Permissions.Contains("lc.amendment.record")) throw WorkflowRefusalException.Forbidden("You may not record amendments.");
        if (a.Origin is not ("OUR_REQUEST" or "RECEIVED_FROM_CUSTOMER") || a.Decision is not ("ACCEPT" or "REJECT"))
            throw WorkflowRefusalException.Missing("V-LCE-FIELD", "The origin is OUR_REQUEST or RECEIVED_FROM_CUSTOMER and the decision ACCEPT or REJECT.");
        var lc = await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        if (lc.Status != "ACTIVE") throw WorkflowRefusalException.State("Only an active credit is amended.");
        var kinds = new List<string>();
        var delta = a.NewAmount is { } na ? na - lc.Amount : 0;
        if (delta > 0) kinds.Add("INCREASE_AMOUNT");
        if (delta < 0) kinds.Add("DECREASE_AMOUNT");
        if (a.NewExpiryDate is { } ne && ne.Date != lc.ExpiryDate.Date) kinds.Add("EXTEND_EXPIRY");
        if (a.NewLatestShipmentDate is { } ns && ns.Date != lc.LatestShipmentDate?.Date) kinds.Add("CHANGE_SHIPMENT_DATE");
        if (kinds.Count == 0) throw WorkflowRefusalException.Missing("V-LCE-FIELD", "The amendment changes the amount, the expiry or the latest shipment.");
        if (a.NewAmount is <= 0) throw WorkflowRefusalException.Missing("V-LCE-FIELD", "The new amount is above zero.");
        var warnings = new List<string>();
        if (a.Decision == "ACCEPT")
        {
            var shortfall = SalesRules.AmendmentShortfall(a.NewAmount ?? lc.Amount, lc.EarmarkedRemaining, lc.DrawnAmount);
            if (shortfall > 0)
                throw WorkflowRefusalException.Missing("V-LCE-11",
                    $"The new amount is {shortfall.ToString("N2", CultureInfo.InvariantCulture)} below what is earmarked and drawn ({(lc.EarmarkedRemaining + lc.DrawnAmount).ToString("N2", CultureInfo.InvariantCulture)}).");
            if (a.NewExpiryDate is { } exp && await c.ExecuteScalarAsync<int>(new CommandDefinition(
                    "SELECT COUNT(*) FROM lc.LcSalesOrder WHERE LcId = @lc AND Status IN ('EARMARKED', 'PARTIALLY_CONVERTED') AND DeliveryDate > @exp;", new { lc = lcId, exp = exp.Date }, tx,
                    cancellationToken: ct)).ConfigureAwait(false) > 0)
                warnings.Add("V-LCE-11 the expiry falls before a pending order's delivery");
        }
        var terms = await TermsStore.CopyAsync(c, tx, lc.CurrentTermsId, "AMENDMENT", null, "AMENDMENT", 1, "DRAFT", ct).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcTerms SET Amount = ISNULL(@amount, Amount), ExpiryRule = CASE WHEN @exp IS NULL THEN ExpiryRule ELSE 'ABSOLUTE' END,
                   ExpiryDate = ISNULL(@exp, ExpiryDate), ExpiryDaysAfterIssue = CASE WHEN @exp IS NULL THEN ExpiryDaysAfterIssue ELSE NULL END,
                   LatestShipmentRule = CASE WHEN @ship IS NULL THEN LatestShipmentRule ELSE 'ABSOLUTE' END, LatestShipmentDate = ISNULL(@ship, LatestShipmentDate),
                   LatestShipmentDaysAfterIssue = CASE WHEN @ship IS NULL THEN LatestShipmentDaysAfterIssue ELSE NULL END, AmountInWordsAr = NULL, AmountInWordsEn = NULL
             WHERE LcTermsId = @t;
            """, new { amount = a.NewAmount, exp = a.NewExpiryDate?.Date, ship = a.NewLatestShipmentDate?.Date, t = terms }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var row = await TermsStore.RowAsync(c, tx, terms, ct).ConfigureAwait(false);
        await TermsStore.LockAsync(c, tx, row, actor.UserId, DateOnly.FromDateTime(a.BankIssuedOn), ct).ConfigureAwait(false);
        var accepted = a.Decision == "ACCEPT";
        var no = lc.AmendmentNo + 1;
        var id = await c.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT lc.LcAmendment (TenantId, CompanyId, LcId, AmendmentNo, Origin, ChangeKinds, TermsId, CurrencyId, AmountDelta, NewAmount, NewExpiryDate, Status, BankAmendmentRef,
                                   BankIssuedOn, BeneficiaryResponse, RespondedOn, AppliedOn, AppliedBy, Reason, CreatedBy)
            OUTPUT inserted.LcAmendmentId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @co, @lc, @no, @origin, @kinds, @terms, @cur, @delta, @newAmount, @exp, @status, @ref, @issued,
                    @response, @issued, CASE WHEN @accepted = 1 THEN SYSUTCDATETIME() END, CASE WHEN @accepted = 1 THEN @u END, @reason, @u);
            DECLARE @id BIGINT = (SELECT Id FROM @o);
            UPDATE lc.LcTerms SET OwnerId = @id WHERE LcTermsId = @terms AND OwnerId IS NULL;
            SELECT @id;
            """,
            new
            {
                co = lc.CompanyId, lc = lcId, no, origin = a.Origin, kinds = string.Join(',', kinds), terms, cur = lc.CurrencyId, delta, newAmount = a.NewAmount, exp = a.NewExpiryDate?.Date,
                status = accepted ? "APPLIED" : "REJECTED", @ref = a.BankAmendmentRef?.Trim(), issued = a.BankIssuedOn.Date, response = accepted ? "ACCEPTED" : "REJECTED", accepted,
                u = actor.UserId, reason = a.Reason?.Trim(),
            }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (!accepted) return (id, warnings);
        // The credit's next RECEIVED version is the amendment's terms; the earlier one is superseded first (one current version per owner).
        var version = await c.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            UPDATE lc.LcTerms SET Status = 'SUPERSEDED' WHERE LcTermsId = @old;
            SELECT VersionNo FROM lc.LcTerms WHERE LcTermsId = @old;
            """, new { old = lc.CurrentTermsId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var next = await TermsStore.CopyAsync(c, tx, terms, "LETTER_OF_CREDIT", lcId, "RECEIVED", version + 1, "LOCKED", ct, supersedes: lc.CurrentTermsId).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE l SET CurrentTermsId = @next, Amount = t.Amount, ExpiryDate = ISNULL(@exp, l.ExpiryDate), LatestShipmentDate = ISNULL(@ship, l.LatestShipmentDate),
                   AmendmentNo = @no, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
              FROM lc.LetterOfCredit AS l JOIN lc.LcTerms AS t ON t.LcTermsId = @next WHERE l.LetterOfCreditId = @lc;
            """, new { lc = lcId, next, exp = a.NewExpiryDate?.Date, ship = a.NewLatestShipmentDate?.Date, no, u = actor.UserId }, tx, cancellationToken: ct))
            .ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "lc.amended", "lc.LetterOfCredit", lcId, new { lc = lcId, amendment = id }, ct).ConfigureAwait(false);
        return (id, warnings);
    }

    // ---------- close and expiry ----------

    /// <summary>BR-LCE-012, 016: the manual close frees every remaining earmark (the orders become RELEASED); not while documents wait for the bank or a payment.</summary>
    public static async Task CloseAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, string reason, DateTime on, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        if (!actor.Permissions.Contains("lc.close")) throw WorkflowRefusalException.Forbidden("You may not close letters of credit.");
        reason = reason.Trim();
        if (reason.Length is 0 or > 500) throw WorkflowRefusalException.Missing("V-WFL-REASON", "A close gives its reason.");
        var lc = await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        if (lc.Status is "CLOSED" or "CANCELLED") throw WorkflowRefusalException.State("The letter of credit is closed.");
        if (await c.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM lc.LcDrawing WHERE LcId = @lc AND Status IN ('PRESENTED', 'DISCREPANT', 'ACCEPTED');",
                new { lc = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false) > 0)
            throw WorkflowRefusalException.State("Documents of the credit wait for the bank's decision or its payment.");
        await ReleaseOrdersAsync(c, tx, lcId, "CLOSED: " + reason, actor.UserId, on, ct).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LetterOfCredit SET Status = 'CLOSED', ClosedOn = @on, ClosedReason = @reason, UndrawnReleasedOn = ISNULL(UndrawnReleasedOn, @on), UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = @u
             WHERE LetterOfCreditId = @lc;
            """, new { on = on.Date, reason, u = actor.UserId, lc = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "lc.closed", "lc.LetterOfCredit", lcId, new { lc = lcId }, ct).ConfigureAwait(false);
    }

    private static async Task ReleaseOrdersAsync(SqlConnection c, SqlTransaction tx, long lcId, string reason, long actor, DateTime on, CancellationToken ct) =>
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcSalesOrder SET Status = 'RELEASED', ReleasedAmount = Amount - ConvertedAmount, ClosedOn = @on, ClosedReason = @reason, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE LcId = @lc AND Status IN ('EARMARKED', 'PARTIALLY_CONVERTED') AND Amount - ConvertedAmount - ReleasedAmount > 0;
            UPDATE lc.LetterOfCredit SET EarmarkedRemaining = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LetterOfCreditId = @lc;
            """, new { lc = lcId, on = on.Date, reason = reason.Length > 500 ? reason[..500] : reason, u = actor }, tx, cancellationToken: ct)).ConfigureAwait(false);

    /// <summary>
    /// JOB-LC-EXPIRY for the sales (BR-LCE-016): an ACTIVE received credit past its expiry is EXPIRED and takes no new
    /// earmark; its pending orders stay earmarked until the treasury closes it (the manual close frees them), and an
    /// expired credit not closed is reminded every lc.expired.reminder_days (LC.EXPIRED_UNCLOSED).
    /// </summary>
    public static async Task<(int Expired, int Reminded)> ExpireAsync(SqlConnection c, DateTime today, CancellationToken ct)
    {
        var expired = await c.ExecuteAsync(new CommandDefinition(
            "UPDATE lc.LetterOfCredit SET Status = 'EXPIRED', UpdatedAt = SYSUTCDATETIME() WHERE LcClass = 'SALES' AND Status = 'ACTIVE' AND ExpiryDate < @today;", new { today = today.Date },
            cancellationToken: ct)).ConfigureAwait(false);
        var s = await FacilityHooks.SettingsAsync(c, null, ct, "lc.expired.reminder_days").ConfigureAwait(false);
        var every = int.TryParse(s.GetValueOrDefault("lc.expired.reminder_days"), out var r) ? r : 7;
        var reminded = 0;
        foreach (var x in await c.QueryAsync<(long Id, long CompanyId, string LcNumber, DateTime ExpiryDate)>(new CommandDefinition(
                     "SELECT LetterOfCreditId, CompanyId, LcNumber, ExpiryDate FROM lc.LetterOfCredit WHERE LcClass = 'SALES' AND Status = 'EXPIRED';", cancellationToken: ct)).ConfigureAwait(false))
        {
            var since = (today.Date - x.ExpiryDate.Date).Days;
            if (since <= 0 || (since - 1) % every != 0) continue;
            await Notifier.RequestAsync(c, null, new NotificationRequest("LC.EXPIRED_UNCLOSED", "lc.LetterOfCredit", x.Id, $"LC.EXPIRED_UNCLOSED:{x.Id}:{today:yyyyMMdd}", x.CompanyId,
                new Dictionary<string, object?> { ["lcNo"] = x.LcNumber }, $"/sales/lcs/{x.Id}"), ct).ConfigureAwait(false);
            reminded++;
        }
        return (expired, reminded);
    }

    /// <summary>
    /// JOB-LC-RECONCILE for the sales (FR-LCE-025): each received credit's cached totals against its rows (the earmarks
    /// of its active orders, its drawings not refused, the conversions of each order against its allocations of drawings
    /// not refused), and a balance that would go negative; a mismatch is reported once a day (LC.RECONCILE_MISMATCH).
    /// </summary>
    public static async Task<int> ReconcileAsync(SqlConnection c, DateTime today, CancellationToken ct)
    {
        var rows = await c.QueryAsync<(long Id, long CompanyId, string LcNumber, decimal Amount, decimal Earmarked, decimal Drawn, decimal SumEarmarked, decimal SumDrawn, int BadOrders)>(
            new CommandDefinition(
                """
                SELECT l.LetterOfCreditId, l.CompanyId, l.LcNumber, l.Amount, l.EarmarkedRemaining, l.DrawnAmount,
                       ISNULL((SELECT SUM(o.Amount - o.ConvertedAmount - o.ReleasedAmount) FROM lc.LcSalesOrder AS o
                                WHERE o.LcId = l.LetterOfCreditId AND o.Status IN ('EARMARKED', 'PARTIALLY_CONVERTED')), 0),
                       ISNULL((SELECT SUM(d.Amount) FROM lc.LcDrawing AS d WHERE d.LcId = l.LetterOfCreditId AND d.Status NOT IN ('REFUSED', 'CANCELLED')), 0),
                       (SELECT COUNT(*) FROM lc.LcSalesOrder AS o
                         WHERE o.LcId = l.LetterOfCreditId
                           AND o.ConvertedAmount <> ISNULL((SELECT SUM(a.Amount) FROM lc.LcDrawingAllocation AS a JOIN lc.LcDrawing AS d ON d.LcDrawingId = a.DrawingId
                                                             WHERE a.SalesOrderId = o.LcSalesOrderId AND d.Status NOT IN ('REFUSED', 'CANCELLED')), 0))
                  FROM lc.LetterOfCredit AS l WHERE l.LcClass = 'SALES' AND l.Status IN ('ACTIVE', 'EXPIRED');
                """, cancellationToken: ct)).ConfigureAwait(false);
        var found = 0;
        foreach (var r in rows)
        {
            var issues = new List<string>();
            if (r.Earmarked != r.SumEarmarked) issues.Add("EARMARKED");
            if (r.Drawn != r.SumDrawn) issues.Add("DRAWN");
            if (r.BadOrders > 0) issues.Add("CONVERSIONS");
            if (r.Amount - r.Earmarked - r.Drawn < 0) issues.Add("NEGATIVE_AVAILABLE");
            if (issues.Count == 0) continue;
            found++;
            await Notifier.RequestAsync(c, null, new NotificationRequest("LC.RECONCILE_MISMATCH", "lc.LetterOfCredit", r.Id, $"LC.RECONCILE_MISMATCH:{r.Id}:{today:yyyyMMdd}", r.CompanyId,
                new Dictionary<string, object?> { ["lcNo"] = r.LcNumber, ["issues"] = string.Join(", ", issues) }, $"/sales/lcs/{r.Id}"), ct).ConfigureAwait(false);
            await Outbox.EmitAsync(c, null, "lc.reconcile.mismatch", "lc.LetterOfCredit", r.Id, new { lc = r.Id, issues }, ct).ConfigureAwait(false);
        }
        return found;
    }

    /// <summary>
    /// JOB-LCE-NOLC (FR-LCE-024): a proforma still ISSUED without any received credit lc.proforma.no_lc_days after its
    /// issue reminds its requester once (LC.PROFORMA_NO_LC, one per proforma and threshold).
    /// </summary>
    public static async Task<int> ProformaNoLcAsync(SqlConnection c, DateTime today, CancellationToken ct)
    {
        var s = await FacilityHooks.SettingsAsync(c, null, ct, "lc.proforma.no_lc_days").ConfigureAwait(false);
        var days = int.TryParse(s.GetValueOrDefault("lc.proforma.no_lc_days"), out var d) ? d : 30;
        var due = await c.QueryAsync<(long Id, long CompanyId, string No, long Requester, string? Customer)>(new CommandDefinition(
            """
            SELECT p.ProformaInvoiceId, p.CompanyId, p.ProformaNo, r.RequesterUserId, cp.NameEn
              FROM lc.ProformaInvoice AS p JOIN wfl.Request AS r ON r.RequestId = p.RequestId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = p.CustomerId
             WHERE p.Status = 'ISSUED' AND DATEADD(DAY, @days, p.IssueDate) <= @today
               AND NOT EXISTS (SELECT 1 FROM lc.LetterOfCredit AS l WHERE l.ProformaId = p.ProformaInvoiceId);
            """, new { days, today = today.Date }, cancellationToken: ct)).ConfigureAwait(false);
        var n = 0;
        foreach (var p in due)
        {
            await Notifier.RequestAsync(c, null, new NotificationRequest("LC.PROFORMA_NO_LC", "lc.ProformaInvoice", p.Id, $"LC.PROFORMA_NO_LC:{p.Id}:{days}", p.CompanyId,
                new Dictionary<string, object?> { ["proformaNo"] = p.No, ["customerName"] = p.Customer, ["days"] = days }, $"/sales/proformas/{p.Id}", null, [p.Requester]), ct)
                .ConfigureAwait(false);
            n++;
        }
        return n;
    }
}

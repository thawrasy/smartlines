using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Lc;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record DrawingBody(decimal Amount, DateOnly PresentationDate, string? BankAdviceRef, DateOnly? MaturityBasisDate, string? Notes, string? OverrideReason);
public sealed record DrawingDecisionBody(string Status);
public sealed record SettlementBody(decimal Amount, DateOnly SettledOn);
public sealed record LcCloseBody(string? Reason);
public sealed record AmendmentBody(string[]? ChangeKinds, decimal? AmountDelta, DateOnly? NewExpiryDate, DateOnly? NewLatestShipmentDate, string? Reason);
public sealed record AmendmentResultBody(int AmendmentNo, DateOnly BankIssuedOn, string? BankAmendmentRef, string? BeneficiaryResponse);

/// <summary>
/// The register of purchase letters of credit (FR-LCI-030, 031; spec 14 section 7, screens 13 and 14): the list with its
/// search (the normalised number, the counterparty, the request number), the card, and the life after issuance: the
/// presentations with the bank's decision and their payments, and the manual close. A holder of lc.view.all sees the
/// credits of their company scope; a holder of lc.view.own the credits of their own requests. The facility, margin
/// and utilisation of the card are for holders of lc.view.internal.
/// </summary>
public static class LcEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/lcs", ListAsync);
        api.MapGet("/lcs/{id:guid}", GetAsync);
        api.MapPost("/lcs/{id:guid}/drawings", DrawAsync);
        api.MapPost("/lcs/{id:guid}/drawings/{no:int}/decision", DecideAsync);
        api.MapPost("/lcs/{id:guid}/drawings/{no:int}/settlements", SettleAsync);
        api.MapPost("/lcs/{id:guid}/close", CloseAsync);
        api.MapPost("/lcs/{id:guid}/amendments", AmendAsync);
        api.MapPost("/lcs/{id:guid}/documents", DocumentAsync);
        api.MapPut("/requests/{id:guid}/amendment-result", AmendmentResultAsync);
    }

    /// <summary>FR-LCI-018: the amendment's child request on the credit; the requester then submits it through /requests.</summary>
    private static async Task<IResult> AmendAsync(Guid id, AmendmentBody b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        var lcId = await IdAsync(u, tx, id, ct);
        var (requestId, publicId) = await AmendmentStore.CreateAsync(u.Connection, tx, actor, lcId, new NewAmendment(b.ChangeKinds ?? [], b.AmountDelta,
            b.NewExpiryDate?.ToDateTime(TimeOnly.MinValue), b.NewLatestShipmentDate?.ToDateTime(TimeOnly.MinValue), b.Reason?.Trim()), clock.GetUtcNow(), ct);
        var company = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition("SELECT CompanyId FROM lc.LetterOfCredit WHERE LetterOfCreditId = @lcId;", new { lcId }, tx,
            cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LC_AMENDMENT_RAISED", "TREASURY", "wfl.Request", requestId,
            AfterJson: JsonSerializer.Serialize(new { lc = id, b.ChangeKinds, b.AmountDelta, b.NewExpiryDate })), company, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/requests/{publicId}", new { id = publicId });
    }

    /// <summary>FR-LCI-019: the bank's result of the amendment, by the assignee of the result stage.</summary>
    private static async Task<IResult> AmendmentResultAsync(Guid id, AmendmentResultBody b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        var requestId = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT RequestId FROM wfl.Request WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        await AmendmentStore.RecordResultAsync(u.Connection, tx, actor, requestId, new AmendmentResult(b.AmendmentNo, b.BankIssuedOn.ToDateTime(TimeOnly.MinValue),
            b.BankAmendmentRef?.Trim(), b.BeneficiaryResponse?.Trim().ToUpperInvariant() ?? ""), ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    internal static async Task<BoundUser> OpenAsync(HttpContext http, SqlConnectionFactory db)
    {
        var u = await BoundUser.OpenAsync(http, db);
        try
        {
            await u.RequireModuleAsync("LC_PURCHASE", http.RequestAborted);
            await u.PermissionsAsync(http.RequestAborted);
            return u;
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }

    private const string Visible = """
        l.LcClass = 'PURCHASE' AND (
          (@all = 1 AND (@scopeAll = 1 OR l.CompanyId IN @scope))
          OR (@own = 1 AND EXISTS (SELECT 1 FROM wfl.Request AS rq WHERE rq.RequestId = l.RequestId AND (rq.RequesterUserId = @u OR rq.CreatedByUserId = @u))))
        """;

    private static async Task<object> ScopeAsync(BoundUser u, CancellationToken ct, SqlTransaction? tx = null)
    {
        var perms = await u.PermissionsAsync(ct);
        var scope = await CompanyScope.OfAsync(u, ct, tx);
        if (!perms.Contains("lc.view.all") && !perms.Contains("lc.view.own")) throw ApiProblemException.Forbidden();
        return new { all = perms.Contains("lc.view.all"), own = perms.Contains("lc.view.own"), scopeAll = scope.All, scope = scope.SqlIds, u = u.UserId };
    }

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "q", "status", "limit");
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        var p = new DynamicParameters(await ScopeAsync(u, ct));
        var q = http.Request.Query["q"].ToString().Trim();
        p.Add("q", q.Length == 0 ? null : "%" + q.Replace("[", "[[]", StringComparison.Ordinal).Replace("%", "[%]", StringComparison.Ordinal).Replace("_", "[_]", StringComparison.Ordinal) + "%");
        p.Add("number", q.Length == 0 ? null : "%" + IssuanceHooks.Normalise(q).Replace("[", "[[]", StringComparison.Ordinal).Replace("%", "[%]", StringComparison.Ordinal).Replace("_", "[_]", StringComparison.Ordinal) + "%");
        p.Add("status", http.Request.Query["status"].ToString() is { Length: > 0 } s ? s : null);
        p.Add("take", Query.Limit(http.Request));
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT TOP (@take) l.PublicId AS id, l.LcNumber AS lcNumber, l.Status AS status, cur.Code AS currency, l.Amount AS amount, l.DrawnAmount AS drawn,
                   l.SettledAmount AS settled, l.IssueDate AS issueDate, l.ExpiryDate AS expiryDate, cp.NameEn AS counterpartyNameEn, cp.NameAr AS counterpartyNameAr,
                   co.NameEn AS companyNameEn, co.NameAr AS companyNameAr, i.NameEn AS bankNameEn, i.NameAr AS bankNameAr, r.RequestNo AS requestNo, r.PublicId AS requestId
              FROM lc.LetterOfCredit AS l JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = l.CounterpartyId
              JOIN org.Company AS co ON co.CompanyId = l.CompanyId LEFT JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId
              LEFT JOIN wfl.Request AS r ON r.RequestId = l.RequestId
             WHERE {Visible} AND (@status IS NULL OR l.Status = @status)
               AND (@q IS NULL OR l.LcNumberNormalized LIKE @number OR cp.NameEn LIKE @q OR cp.NameAr LIKE @q OR r.RequestNo LIKE @q)
             ORDER BY l.ExpiryDate, l.LetterOfCreditId;
            """, p, cancellationToken: ct));
        return Results.Ok(new { items = rows });
    }

    internal static async Task<long> IdAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct)
    {
        var p = new DynamicParameters(await ScopeAsync(u, ct, tx));
        p.Add("id", id);
        return await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition($"SELECT l.LetterOfCreditId FROM lc.LetterOfCredit AS l WHERE l.PublicId = @id AND {Visible};", p, tx,
                   cancellationToken: ct))
               ?? throw ApiProblemException.NotFound();
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request);
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        var lcId = await IdAsync(u, null, id, ct);
        var internalView = (await u.PermissionsAsync(ct)).Contains("lc.view.internal");
        var lc = await u.Connection.QuerySingleAsync(new CommandDefinition(
            """
            SELECT l.PublicId AS id, l.LcNumber AS lcNumber, l.InternalRef AS internalRef, l.Status AS status, l.Scope AS scope, cur.Code AS currency, l.Amount AS amount,
                   l.OriginalAmount AS originalAmount, l.ExposureAmount AS exposureAmount, l.DrawnAmount AS drawn, l.SettledAmount AS settled, l.TolerancePlusPct AS tolerancePlusPct,
                   l.ToleranceMinusPct AS toleranceMinusPct, l.IssueDate AS issueDate, l.ExpiryDate AS expiryDate, l.LatestShipmentDate AS latestShipmentDate,
                   l.AmendmentNo AS amendmentNo, l.ClosedOn AS closedOn, l.ClosedReason AS closedReason, l.BankReference AS bankReference, l.IssuingBranch AS issuingBranch,
                   cp.NameEn AS counterpartyNameEn, cp.NameAr AS counterpartyNameAr, co.NameEn AS companyNameEn, co.NameAr AS companyNameAr, i.NameEn AS bankNameEn,
                   i.NameAr AS bankNameAr, r.RequestNo AS requestNo, r.PublicId AS requestId, t.LcType AS lcType, t.DeferralDays AS deferralDays,
                   l.MarginPct AS marginPct, l.MarginAmount AS marginAmount, f.FacilityNo AS facilityNo, f.PublicId AS facilityId,
                   (SELECT u2.Amount FROM fac.Utilization AS u2 WHERE u2.UtilizationId = l.UtilizationId AND u2.Status = 'ACTIVE') AS utilized
              FROM lc.LetterOfCredit AS l JOIN ref.Currency AS cur ON cur.CurrencyId = l.CurrencyId JOIN lc.Counterparty AS cp ON cp.CounterpartyId = l.CounterpartyId
              JOIN org.Company AS co ON co.CompanyId = l.CompanyId JOIN lc.LcTerms AS t ON t.LcTermsId = l.CurrentTermsId
              LEFT JOIN ins.Institution AS i ON i.InstitutionId = l.InstitutionId LEFT JOIN wfl.Request AS r ON r.RequestId = l.RequestId
              LEFT JOIN fac.Facility AS f ON f.FacilityId = l.FacilityId
             WHERE l.LetterOfCreditId = @lcId;
            """, new { lcId }, cancellationToken: ct));
        var row = (IDictionary<string, object?>)lc;
        if (!internalView)
            foreach (var k in new[] { "marginPct", "marginAmount", "facilityNo", "facilityId", "utilized" }) row.Remove(k);
        var drawings = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT DrawingNo AS drawingNo, Amount AS amount, PresentationDate AS presentationDate, BankAdviceRef AS bankAdviceRef, Status AS status, MaturityDate AS maturityDate,
                   ExaminationDeadline AS examinationDeadline, SettledAmount AS settled, LastSettledOn AS lastSettledOn
              FROM lc.LcDrawing WHERE LcId = @lcId ORDER BY DrawingNo;
            """, new { lcId }, cancellationToken: ct));
        var amendments = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT AmendmentNo AS amendmentNo, ChangeKinds AS changeKinds, AmountDelta AS amountDelta, NewExpiryDate AS newExpiryDate, Status AS status,
                   BeneficiaryResponse AS beneficiaryResponse, BankIssuedOn AS bankIssuedOn
              FROM lc.LcAmendment WHERE LcId = @lcId ORDER BY LcAmendmentId;
            """, new { lcId }, cancellationToken: ct));
        var documents = await LcDocuments.ListAsync(u.Connection, lcId, internalView, ct);
        return Results.Ok(new { lc = row, drawings, amendments, documents });
    }

    /// <summary>A file of the credit (docs/31 row 52): its copy, a SWIFT, an amendment copy, a bank advice or an approval.</summary>
    private static async Task<IResult> DocumentAsync(Guid id, LcDocumentBody b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        await LcDocuments.LinkAsync(u, tx, await IdAsync(u, tx, id, ct), b.Document, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> InTxAsync(Guid id, HttpContext http, SqlConnectionFactory db, string audit, Func<BoundUser, SqlTransaction, Actor, long, CancellationToken, Task<object?>> act)
    {
        await using var u = await OpenAsync(http, db);
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

    private static Task<IResult> DrawAsync(Guid id, DrawingBody b, HttpContext http, SqlConnectionFactory db) =>
        InTxAsync(id, http, db, "LC_DRAWING_RECORDED", async (u, tx, actor, lcId, ct) =>
        {
            var (_, no) = await LcStore.RecordDrawingAsync(u.Connection, tx, actor, lcId, new NewDrawing(b.Amount, b.PresentationDate.ToDateTime(TimeOnly.MinValue), b.BankAdviceRef?.Trim(),
                b.MaturityBasisDate?.ToDateTime(TimeOnly.MinValue), b.Notes?.Trim(), b.OverrideReason?.Trim()), ct);
            return new { drawingNo = no };
        });

    private static Task<IResult> DecideAsync(Guid id, int no, DrawingDecisionBody b, HttpContext http, SqlConnectionFactory db) =>
        InTxAsync(id, http, db, "LC_DRAWING_DECIDED", async (u, tx, actor, lcId, ct) =>
        {
            await LcStore.DecideDrawingAsync(u.Connection, tx, actor, lcId, no, b.Status?.Trim().ToUpperInvariant() ?? "", ct);
            return new { drawingNo = no, status = b.Status };
        });

    private static Task<IResult> SettleAsync(Guid id, int no, SettlementBody b, HttpContext http, SqlConnectionFactory db) =>
        InTxAsync(id, http, db, "LC_DRAWING_SETTLED", async (u, tx, actor, lcId, ct) =>
        {
            await LcStore.SettleDrawingAsync(u.Connection, tx, actor, lcId, no, b.Amount, b.SettledOn.ToDateTime(TimeOnly.MinValue), ct);
            return new { drawingNo = no, amount = b.Amount };
        });

    private static Task<IResult> CloseAsync(Guid id, LcCloseBody b, HttpContext http, SqlConnectionFactory db, TimeProvider clock) =>
        InTxAsync(id, http, db, "LC_CLOSED", async (u, tx, actor, lcId, ct) =>
        {
            await LcStore.CloseAsync(u.Connection, tx, actor, lcId, b.Reason ?? "", await Delegations.TodayAsync(u.Connection, tx, clock.GetUtcNow(), ct), ct);
            return new { status = "CLOSED" };
        });
}

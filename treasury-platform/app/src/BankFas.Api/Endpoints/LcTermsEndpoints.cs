using System.Security.Cryptography;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Text;
using BankFas.Data;
using BankFas.Data.Lc;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record CounterpartyBody(string? Kind, string? NameEn, string? NameAr, string? Country, string? City, string? ErpCode);
public sealed record TermsBody(JsonElement? Fields);
public sealed record ChargesBody(string? Preset);
public sealed record IssuanceBody(string? LcNumber, DateOnly? IssueDate, Guid? Institution, string? BankReference, string? IssuingBranch, decimal? IssuedAmount);

/// <summary>
/// Letter-of-credit terms of a request and their counterparties (spec 14 sections 5 and 7; S3 batch E): the suppliers
/// (lc.Counterparty, FR-LCT-036, searched by name or ERP code, quick-created with a duplicate warning), the terms of a
/// purchase request read as field keys with their findings (V-LCT), written while the request is a draft or returned,
/// the treasury's own fields written by the treasury also after the lock (FR-LCT-021), the document clauses and the
/// charges presets, and the clause library. The requester never reads the treasury's fields. Gated by LC_PURCHASE.
/// </summary>
public static class LcTermsEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/counterparties", CounterpartiesAsync);
        api.MapPost("/counterparties", CreateCounterpartyAsync);
        api.MapGet("/document-clauses", ClausesAsync);
        api.MapGet("/requests/{id:guid}/terms", GetTermsAsync);
        api.MapPut("/requests/{id:guid}/terms", PutTermsAsync);
        api.MapPut("/requests/{id:guid}/terms/documents", PutDocumentsAsync);
        api.MapPut("/requests/{id:guid}/terms/charges", PutChargesAsync);
        api.MapPut("/requests/{id:guid}/issuance", PutIssuanceAsync);
    }

    private static async Task<BoundUser> OpenAsync(HttpContext http, SqlConnectionFactory db, string? permission = null)
    {
        var u = permission is null ? await BoundUser.OpenAsync(http, db) : await BoundUser.OpenAsync(http, db, permission);
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

    // ---------- counterparties ----------

    private static async Task<IResult> CounterpartiesAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "q", "kind");
        await using var u = await OpenAsync(http, db);
        var perms = await u.PermissionsAsync(http.RequestAborted);
        if (!perms.Contains("lc.counterparty.manage") && !perms.Contains("lc.terms.edit")) throw ApiProblemException.Forbidden();
        var q = http.Request.Query["q"].ToString();
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT TOP (50) cp.PublicId AS id, cp.Code AS code, cp.Kind AS kind, cp.NameEn AS nameEn, cp.NameAr AS nameAr, co.Iso2 AS country, cp.ErpCode AS erpCode
              FROM lc.Counterparty AS cp JOIN ref.Country AS co ON co.CountryId = cp.CountryId
             WHERE cp.IsActive = 1 AND (@q = '' OR cp.NameNormalized LIKE '%' + @nq + '%' OR cp.ErpCodeNormalized = @eq)
             ORDER BY cp.NameEn;
            """, new { q, nq = Normalizer.Name(q), eq = RequestEndpoints.NormaliseRef(q) }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    /// <summary>BR-LCT-022: a quick supplier; the same normalised name and country, or the same ERP code, is a warning, not a refusal.</summary>
    private static async Task<IResult> CreateCounterpartyAsync(CounterpartyBody b, HttpContext http, SqlConnectionFactory db)
    {
        var name = b.NameEn?.Trim();
        var kind = (b.Kind ?? "SUPPLIER").ToUpperInvariant();
        if (string.IsNullOrEmpty(name) || name.Length > 300 || kind is not ("SUPPLIER" or "CUSTOMER" or "BOTH") || string.IsNullOrWhiteSpace(b.Country))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the name, the kind and the country of the counterparty.");
        await using var u = await OpenAsync(http, db, "lc.counterparty.manage");
        var ct = http.RequestAborted;
        var country = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CountryId FROM ref.Country WHERE Iso2 = @c;", new { c = b.Country.Trim().ToUpperInvariant() },
            cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The country is not known.");
        var normalised = Normalizer.Name(b.NameAr is { Length: > 0 } ar ? ar + " " + name : name);
        var erp = b.ErpCode?.Trim() is { Length: > 0 } e ? e : null;
        var duplicate = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT COUNT(*) FROM lc.Counterparty WHERE IsActive = 1 AND ((NameNormalized = @n AND CountryId = @c)
                OR (@erp IS NOT NULL AND ErpCodeNormalized = CAST(UPPER(REPLACE(TRANSLATE(@erp, N'٠١٢٣٤٥٦٧٨٩', N'0123456789'), N' ', N'')) AS NVARCHAR(40))));
            """, new { n = normalised, c = country, erp }, cancellationToken: ct));
        var row = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId, string Code)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER, Code VARCHAR(20));
            INSERT lc.Counterparty (TenantId, Code, Kind, NameEn, NameAr, NameNormalized, CountryId, City, ErpCode, CreatedBy)
            OUTPUT inserted.CounterpartyId, inserted.PublicId, inserted.Code INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @kind, @en, @ar, @n, @c, @city, @erp, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId, Code FROM @o;
            """,
            new { code = "CP-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(5)), kind, en = name, ar = b.NameAr?.Trim(), n = normalised, c = country, city = b.City?.Trim(), erp },
            cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("COUNTERPARTY_CREATED", "TREASURY", "lc.Counterparty", row.Id,
            AfterJson: JsonSerializer.Serialize(new { row.Code, kind })), null, ct);
        return Results.Created($"/api/v1/counterparties/{row.PublicId}", new { id = row.PublicId, code = row.Code, warning = duplicate > 0 ? "V-LCT-DUPLICATE" : null });
    }

    private static async Task<IResult> ClausesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db);
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT c.Code AS code, c.VersionNo AS versionNo, c.NameAr AS nameAr, c.NameEn AS nameEn, c.Category AS category, c.DefaultOriginals AS originals,
                   c.DefaultCopies AS copies, c.LegalReviewStatus AS legalReview, c.ParamSchemaJson AS paramSchema
              FROM lc.LcDocumentClause AS c
             WHERE c.Status = 'ACTIVE' AND c.VersionNo = (SELECT MAX(VersionNo) FROM lc.LcDocumentClause AS x WHERE x.Code = c.Code AND x.Status = 'ACTIVE')
             ORDER BY c.Code;
            """, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    // ---------- the terms of a request ----------

    private sealed record Ctx(BoundUser U, RequestEngine.RequestRow R, bool Staff, bool Requester, bool Editable, bool Treasury);

    private static async Task<Ctx> RequestAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct)
    {
        var r = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT RequestId FROM wfl.Request WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct))
            is { } rid ? await RequestEngine.FindAsync(u.Connection, tx, rid, tx is not null, ct) : null;
        if (r is null || r.TypeCode is not ("PURCHASE_LC" or "LC_AMENDMENT")) throw ApiProblemException.NotFound();
        var perms = await u.PermissionsAsync(ct);
        var scope = await CompanyScope.OfAsync(u, ct, tx);
        var requester = u.UserId == r.RequesterUserId || u.UserId == r.CreatedByUserId;
        var staff = perms.Contains("lc.view.internal") && perms.Contains("req.view.all") && scope.Allows(r.CompanyId);
        var involved = requester || staff || await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM wfl.RequestApproval WHERE RequestId = @r AND (AssignedUserId = @u OR ActedByUserId = @u);", new { r = r.RequestId, u = u.UserId }, tx,
            cancellationToken: ct)) > 0;
        if (!involved) throw ApiProblemException.NotFound();
        var inst = await RequestEngine.CurrentInstanceAsync(u.Connection, tx, r.RequestId, ct);
        var editable = requester && perms.Contains("lc.terms.edit") && (r.Status == "DRAFT" || inst?.StageKey == "RETURNED");
        return new Ctx(u, r, staff, requester, editable, staff && perms.Contains("lc.terms.treasury.edit") && r.Status is "ACTIVE");
    }

    private static async Task<IResult> GetTermsAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var x = await RequestAsync(u, tx, id, ct);
        var t = x.Editable ? await TermsStore.EnsureAsync(u.Connection, tx, x.R.RequestId, x.R.CompanyId, ct) : await TermsStore.CurrentAsync(u.Connection, tx, x.R.RequestId, ct);
        if (t is null) { await tx.CommitAsync(ct); return Results.Ok(new { status = (string?)null }); }
        var fields = await TermsStore.ReadAsync(u.Connection, tx, t.LcTermsId, x.Staff, ct);
        var documents = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT d.SeqNo AS seq, c.Code AS clause, c.NameEn AS nameEn, c.NameAr AS nameAr, d.Originals AS originals, d.Copies AS copies, d.ParamsJson AS params,
                   d.[FreeText] AS [freeText], c.LegalReviewStatus AS legalReview
              FROM lc.LcTermsDocument AS d JOIN lc.LcDocumentClause AS c ON c.LcDocumentClauseId = d.ClauseId WHERE d.LcTermsId = @t ORDER BY d.SeqNo;
            """, new { t = t.LcTermsId }, tx, cancellationToken: ct));
        var charges = await u.Connection.QueryAsync(new CommandDefinition(
            "SELECT ChargeCategory AS category, Payer AS payer, ApplicantSharePct AS applicantSharePct, PresetCode AS preset FROM lc.LcChargesMatrix WHERE LcTermsId = @t ORDER BY ChargeCategory;",
            new { t = t.LcTermsId }, tx, cancellationToken: ct));
        var findings = t.Status == "DRAFT" ? await TermsStore.CheckAsync(u.Connection, tx, t, DateOnly.FromDateTime(clock.GetUtcNow().UtcDateTime), ct) : [];
        var exposure = await ExposureAsync(u.Connection, tx, t, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new
        {
            id = t.PublicId, version = t.VersionNo, status = t.Status, editable = x.Editable, treasuryEditable = x.Treasury && t.TreasuryHash is null, fields, documents, charges,
            findings = findings.Select(f => new { code = f.Code, severity = f.Severity, field = f.Field, message = f.Message }),
            exposureAmount = x.Staff ? exposure : null,
        });
    }

    /// <summary>BR-LCI-004: the exposure of the terms, with the plus tolerance when lc.reserve.include_tolerance is on.</summary>
    internal static async Task<decimal?> ExposureAsync(SqlConnection c, SqlTransaction? tx, TermsStore.TermsRow t, CancellationToken ct)
    {
        if (t.Amount is not { } amount || t.CurrencyId is not { } cur) return null;
        var row = await c.QuerySingleAsync<(int Decimals, string? Include)>(new CommandDefinition(
            """
            SELECT (SELECT Decimals FROM ref.Currency WHERE CurrencyId = @c),
                   (SELECT ISNULL(s.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS s ON s.[Key] = d.[Key] WHERE d.[Key] = 'lc.reserve.include_tolerance');
            """, new { c = cur }, tx, cancellationToken: ct));
        return BankFas.Core.Lc.TermsRules.Exposure(amount, t.TolerancePlusPct, row.Include != "false", row.Decimals);
    }

    private static async Task<IResult> PutTermsAsync(Guid id, TermsBody b, HttpContext http, SqlConnectionFactory db)
    {
        if (b.Fields is not { ValueKind: JsonValueKind.Object } fields) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the fields of the terms as an object.");
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var x = await RequestAsync(u, tx, id, ct);
        if (!x.Editable && !x.Treasury) throw ApiProblemException.Forbidden();
        var t = await TermsStore.UpdateAsync(u.Connection, tx, x.R.RequestId, x.R.CompanyId, fields, x.Treasury, x.Editable, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LC_TERMS_EDITED", "TREASURY", "lc.LcTerms", t.LcTermsId,
            AfterJson: JsonSerializer.Serialize(new { keys = fields.EnumerateObject().Select(p => p.Name) })), x.R.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { id = t.PublicId, version = t.VersionNo, status = t.Status });
    }

    private static async Task<IResult> PutDocumentsAsync(Guid id, JsonElement items, HttpContext http, SqlConnectionFactory db)
    {
        if (items.ValueKind != JsonValueKind.Array) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the documents as a list.");
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var x = await RequestAsync(u, tx, id, ct);
        if (!x.Editable) throw ApiProblemException.Forbidden();
        var t = await TermsStore.EnsureAsync(u.Connection, tx, x.R.RequestId, x.R.CompanyId, ct);
        if (t.Status == "LOCKED") t = await TermsStore.UpdateAsync(u.Connection, tx, x.R.RequestId, x.R.CompanyId, JsonDocument.Parse("{\"scope\": \"" + t.Scope + "\"}").RootElement, false, true, ct);
        await TermsStore.SetDocumentsAsync(u.Connection, tx, t, items, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { count = items.GetArrayLength() });
    }

    private static async Task<IResult> PutChargesAsync(Guid id, ChargesBody b, HttpContext http, SqlConnectionFactory db)
    {
        if (b.Preset is not ("OWN_BANK" or "ALL_APPLICANT" or "ALL_BENEFICIARY" or "SPLIT_50")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a preset of the charges.");
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var x = await RequestAsync(u, tx, id, ct);
        if (!x.Editable) throw ApiProblemException.Forbidden();
        var t = await TermsStore.EnsureAsync(u.Connection, tx, x.R.RequestId, x.R.CompanyId, ct);
        if (t.Status != "DRAFT") throw new WorkflowRefusalException(409, "TERMS_LOCKED", "Locked terms do not change; a change is a new version (BR-LCT-019).");
        await TermsStore.ChargesPresetAsync(u.Connection, tx, t.LcTermsId, b.Preset, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { preset = b.Preset });
    }

    /// <summary>
    /// The lc.issuance form (FR-LCI-011): the claimer of the ISSUANCE stage records the bank's number, the issue date, the
    /// issuing bank and, when it differs, the issued exposure. The conversion and the credit are written when the stage is
    /// completed (BR-WFL-018), not here.
    /// </summary>
    private static async Task<IResult> PutIssuanceAsync(Guid id, IssuanceBody b, HttpContext http, SqlConnectionFactory db)
    {
        var number = b.LcNumber?.Trim();
        if (string.IsNullOrEmpty(number) || number.Length > 60 || b.IssueDate is null || b.Institution is null)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the letter of credit number, the issue date and the issuing bank.");
        if (b.IssuedAmount is <= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The issued exposure is above zero.");
        await using var u = await OpenAsync(http, db, "lc.issuance.record");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var x = await RequestAsync(u, tx, id, ct);
        var inst = await RequestEngine.CurrentInstanceAsync(u.Connection, tx, x.R.RequestId, ct);
        if (inst is not { StageKey: "ISSUANCE", Status: "CLAIMED" } || inst.AssigneeUserId != u.UserId)
            throw new ApiProblemException(409, "INVALID_STATE", "The issuance is recorded by the assignee of the issuance stage.");
        var institution = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @i;", new { i = b.Institution },
            tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The issuing bank is not known.");
        var json = JsonSerializer.Serialize(new
        {
            lcNumber = number, issueDate = b.IssueDate.Value.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture), institutionId = institution,
            bankReference = b.BankReference?.Trim(), issuingBranch = b.IssuingBranch?.Trim(), issuedAmount = b.IssuedAmount,
        });
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.Request SET FormDataJson = JSON_MODIFY(ISNULL(FormDataJson, N'{}'), '$.issuance', JSON_QUERY(@j)), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE RequestId = @r;
            INSERT wfl.RequestAction (TenantId, RequestId, StageInstanceId, CycleNo, ActionType, ActorType, ActorUserId, OccurredAt, Visibility, MetaJson, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, 'FIELD_EDITED', 'USER', @u, SYSUTCDATETIME(), 'INTERNAL', N'{"field":"issuance"}', @u);
            """, new { j = json, u = u.UserId, r = x.R.RequestId, i = inst.RequestStageInstanceId, cycle = x.R.CycleNo }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        var rv = await u.Connection.ExecuteScalarAsync<byte[]>(new CommandDefinition("SELECT RowVersion FROM wfl.Request WHERE PublicId = @id;", new { id }, cancellationToken: ct));
        ETags.Set(http.Response, rv ?? []);
        return Results.Ok(new { lcNumber = number });
    }
}

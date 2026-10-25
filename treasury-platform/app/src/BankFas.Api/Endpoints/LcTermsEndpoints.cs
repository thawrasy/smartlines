using System.Security.Cryptography;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Security;
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
public sealed record IbanBody(string? Iban);
public sealed record IbanRevealBody(string? Reason);
public sealed record ExecutionBody(string? Channel, string? BankReference, Guid? Receipt, string? Notes);
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
        api.MapPut("/requests/{id:guid}/execution", PutExecutionAsync);
        api.MapPut("/requests/{id:guid}/terms/beneficiary-iban", PutIbanAsync);
        api.MapPost("/requests/{id:guid}/terms/beneficiary-iban/reveal", RevealIbanAsync);
        api.MapGet("/requests/{id:guid}/terms/print", PrintAsync);
    }

    /// <summary>OQ-14: the printable terms page (lc.print), in the user's or the asked language; the print is audited with the terms hash and version.</summary>
    private static async Task<IResult> PrintAsync(Guid id, HttpContext http, SqlConnectionFactory db, PdfRenderer pdf)
    {
        Query.Allow(http.Request, "lang", "format");
        var asPdf = Pdf.Wanted(http.Request);
        await using var u = await OpenAsync(http, db, "lc.print");
        var ct = http.RequestAborted;
        var x = await RequestAsync(u, null, id, ct);
        var t = await TermsStore.CurrentAsync(u.Connection, null, x.R.RequestId, ct) ?? throw ApiProblemException.NotFound();
        var arabic = http.Request.Query["lang"].ToString() is { Length: > 0 } l ? l == "ar"
            : await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT PreferredLanguage FROM sec.AppUser WHERE AppUserId = @u;", new { u = u.UserId },
                cancellationToken: ct)) == "ar";
        var (html, hash) = await TermsPrint.BuildAsync(u.Connection, null, x.R.RequestId, t, x.Staff, arabic, ct);
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("LC_TERMS_PRINTED", "TREASURY", "lc.LcTerms", t.LcTermsId,
            AfterJson: JsonSerializer.Serialize(new { version = t.VersionNo, status = t.Status, hash, lang = arabic ? "ar" : "en", format = asPdf ? "pdf" : "html" })), x.R.CompanyId, ct);
        http.Response.Headers.CacheControl = "no-store";
        if (asPdf) return await Pdf.FileAsync(pdf, html, $"terms-v{t.VersionNo}.pdf", ct);
        var styleHash = Convert.ToBase64String(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(TermsPrint.Style)));
        http.Response.Headers.ContentSecurityPolicy =
            $"default-src 'none'; style-src 'sha256-{styleHash}'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";
        return Results.Content(html, "text/html; charset=utf-8");
    }

    // The ciphertext is bound to the tenant and the column, not the row: a terms version copied to its next version, an
    // amendment or the issued credit keeps the same sealed value (BR-LCT-019), and the hash finds the same IBAN everywhere.
    private static byte[] IbanAad(int tenant) => EnvelopeAad.ForColumn(tenant, "lc.LcTerms", "BeneficiaryAccountIbanEnc", Guid.Empty);

    /// <summary>
    /// FR-REQ-024, DR-02: the beneficiary's IBAN of a draft terms version, checked (its country length and check digits),
    /// sealed with the tenant's DATA key, masked and indexed with its BLIND_INDEX key; never stored or returned in clear.
    /// An empty value removes it. The terms show only the mask.
    /// </summary>
    private static async Task<IResult> PutIbanAsync(Guid id, IbanBody b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys)
    {
        var iban = string.IsNullOrWhiteSpace(b.Iban) ? null : BankFas.Core.Banking.BankAccountNumbers.Normalize(b.Iban);
        if (iban is not null && BankFas.Core.Banking.BankAccountNumbers.IbanProblem(iban) is { } problem)
            throw ApiProblemException.Invalid("V-LCT-IBAN", problem switch
            {
                "LENGTH" => "The IBAN does not have the length of its country.",
                "CHECKSUM" => "The IBAN check digits do not match: check the number.",
                _ => "The IBAN starts with the country code and two check digits.",
            });
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var x = await RequestAsync(u, tx, id, ct);
        if (!x.Editable) throw ApiProblemException.Forbidden();
        var t = await TermsStore.CurrentAsync(u.Connection, tx, x.R.RequestId, ct) ?? throw ApiProblemException.NotFound();
        if (t.Status != "DRAFT") throw new ApiProblemException(409, "TERMS_LOCKED", "Locked terms do not change; a change is a new version (BR-LCT-019).");
        byte[]? enc = null, hash = null;
        long? encKey = null, hashKey = null;
        if (iban is not null)
        {
            var (dataKeyId, dataKey) = await keys.ActiveAsync(u.Connection, tx, u.TenantId, "DATA", ct);
            var (hashKeyId, blind) = await keys.ActiveAsync(u.Connection, tx, u.TenantId, "BLIND_INDEX", ct);
            enc = Envelope.Seal(dataKey, System.Text.Encoding.UTF8.GetBytes(iban), IbanAad(u.TenantId));
            hash = BankFas.Core.Banking.BankAccountNumbers.BlindIndex(blind, "IBAN", iban);
            (encKey, hashKey) = (dataKeyId, hashKeyId);
        }
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcTerms SET BeneficiaryAccountIbanEnc = @enc, BeneficiaryAccountIbanMask = @mask, BeneficiaryAccountIbanHash = @hash,
                   EncKeyId = @ek, HashKeyId = @hk, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE LcTermsId = @t AND Status = 'DRAFT';
            """, new { enc, mask = iban is null ? null : BankFas.Core.Banking.BankAccountNumbers.MaskIban(iban), hash, ek = encKey, hk = hashKey, u = u.UserId, t = t.LcTermsId },
            tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LC_TERMS_IBAN_SET", "TREASURY", "lc.LcTerms", t.LcTermsId,
            AfterJson: JsonSerializer.Serialize(new { mask = iban is null ? null : BankFas.Core.Banking.BankAccountNumbers.MaskIban(iban) })), x.R.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { iban = iban is null ? null : BankFas.Core.Banking.BankAccountNumbers.MaskIban(iban) });
    }

    /// <summary>The beneficiary's IBAN in clear to a holder of lc.view.internal, with a written reason; the reveal and every refusal are audited (14m section 12).</summary>
    private static async Task<IResult> RevealIbanAsync(Guid id, IbanRevealBody b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys)
    {
        var reason = b.Reason?.Trim();
        if (string.IsNullOrEmpty(reason) || reason.Length > 300) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason of the reveal (up to 300 characters).");
        await using var u = await OpenAsync(http, db);
        var ct = http.RequestAborted;
        var x = await RequestAsync(u, null, id, ct);
        var t = await TermsStore.CurrentAsync(u.Connection, null, x.R.RequestId, ct) ?? throw ApiProblemException.NotFound();
        if (!(await u.PermissionsAsync(ct)).Contains("lc.view.internal"))
        {
            await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("LC_TERMS_IBAN_REVEAL_DENIED", "IDENTITY_ACCESS", "lc.LcTerms", t.LcTermsId,
                AfterJson: JsonSerializer.Serialize(new { reason }), Severity: "HIGH", Result: "DENIED"), x.R.CompanyId, ct);
            throw ApiProblemException.Forbidden();
        }
        var row = await u.Connection.QuerySingleAsync<(byte[]? Enc, long? KeyId)>(new CommandDefinition(
            "SELECT BeneficiaryAccountIbanEnc, EncKeyId FROM lc.LcTerms WHERE LcTermsId = @t;", new { t = t.LcTermsId }, cancellationToken: ct));
        if (row.Enc is null || row.KeyId is not { } keyId) throw ApiProblemException.NotFound();
        var key = await keys.ByIdAsync(u.Connection, null, u.TenantId, keyId, ct);
        var iban = System.Text.Encoding.UTF8.GetString(Envelope.Open(key, row.Enc, IbanAad(u.TenantId)));
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("LC_TERMS_IBAN_REVEALED", "IDENTITY_ACCESS", "lc.LcTerms", t.LcTermsId,
            AfterJson: JsonSerializer.Serialize(new { reason })), x.R.CompanyId, ct);
        await AuditWriter.RevealAnomalyAsync(u.Connection, null, ct);
        http.Response.Headers.CacheControl = "no-store";
        return Results.Ok(new { iban });
    }

    /// <summary>
    /// FR-LCI-010, FR-WFL-027: the execution of a purchase request by the assignee of its execution or issuance stage: the
    /// channel (BANK_PORTAL or MANUAL_FORM; DIRECT_INTEGRATION is reserved), the bank's reference and the bank's receipt
    /// (a stored BANK_ACKNOWLEDGEMENT of the company), which the issuance needs while lc.execution.require_receipt holds.
    /// </summary>
    private static async Task<IResult> PutExecutionAsync(Guid id, ExecutionBody b, HttpContext http, SqlConnectionFactory db)
    {
        var channel = b.Channel?.Trim().ToUpperInvariant();
        if (channel is not (null or "BANK_PORTAL" or "MANUAL_FORM"))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The channel is BANK_PORTAL or MANUAL_FORM.");
        if (b.BankReference is { Length: > 60 }) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank's reference is up to 60 characters.");
        await using var u = await OpenAsync(http, db, "req.execute");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var x = await RequestAsync(u, tx, id, ct);
        var inst = await RequestEngine.CurrentInstanceAsync(u.Connection, tx, x.R.RequestId, ct);
        if (inst is not { StageKey: "EXECUTION" or "ISSUANCE", Status: "CLAIMED" } || inst.AssigneeUserId != u.UserId)
            throw new ApiProblemException(409, "INVALID_STATE", "The execution is recorded by the assignee of the execution stage.");
        Guid? receipt = null;
        if (b.Receipt is { } r)
        {
            var ok = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                """
                SELECT COUNT(*) FROM doc.Document AS d JOIN cat.DocumentType AS t ON t.DocumentTypeId = d.DocumentTypeId
                 WHERE d.PublicId = @d AND d.Status = 'ACTIVE' AND (d.OwnerCompanyId IS NULL OR d.OwnerCompanyId = @c) AND t.Code = 'BANK_ACKNOWLEDGEMENT';
                """, new { d = r, c = x.R.CompanyId }, tx, cancellationToken: ct));
            if (ok == 0) throw ApiProblemException.Invalid("DOCUMENT_NOT_FOUND", "The receipt is a stored bank acknowledgement of the company.");
            receipt = r;
        }
        var json = JsonSerializer.Serialize(new { bankReference = b.BankReference?.Trim(), receiptDocument = receipt, notes = b.Notes?.Trim() });
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.Request SET ExecutionChannel = ISNULL(@ch, ISNULL(ExecutionChannel, 'MANUAL_FORM')),
                   FormDataJson = JSON_MODIFY(ISNULL(FormDataJson, N'{}'), '$.execution', JSON_QUERY(@j)), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE RequestId = @r;
            INSERT wfl.RequestAction (TenantId, RequestId, StageInstanceId, CycleNo, ActionType, ActorType, ActorUserId, OccurredAt, Visibility, MetaJson, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, 'CHANNEL_CHANGED', 'USER', @u, SYSUTCDATETIME(), 'INTERNAL', @meta, @u);
            """, new { ch = channel, j = json, u = u.UserId, r = x.R.RequestId, i = inst.RequestStageInstanceId, cycle = x.R.CycleNo,
                meta = JsonSerializer.Serialize(new { channel, receipt = receipt is not null }) }, tx, cancellationToken: ct));
        if (receipt is { } doc)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                DECLARE @d BIGINT = (SELECT DocumentId FROM doc.Document WHERE PublicId = @doc);
                IF NOT EXISTS (SELECT 1 FROM doc.DocumentLink WHERE DocumentId = @d AND EntityType = 'wfl.Request' AND EntityId = @r AND LinkRole = 'ATTACHMENT' AND UnlinkedAt IS NULL)
                    INSERT doc.DocumentLink (TenantId, DocumentId, EntityType, EntityId, LinkRole, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @d, 'wfl.Request', @r, 'ATTACHMENT', @u);
                """, new { doc, r = x.R.RequestId, u = u.UserId }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        var rv = await u.Connection.ExecuteScalarAsync<byte[]>(new CommandDefinition("SELECT RowVersion FROM wfl.Request WHERE PublicId = @id;", new { id }, cancellationToken: ct));
        ETags.Set(http.Response, rv ?? []);
        return Results.Ok(new { channel = channel ?? "MANUAL_FORM", receipt = receipt is not null });
    }

    private static async Task<BoundUser> OpenAsync(HttpContext http, SqlConnectionFactory db, string? permission = null)
    {
        var u = permission is null ? await BoundUser.OpenAsync(http, db) : await BoundUser.OpenAsync(http, db, permission);
        try
        {
            // The terms serve the purchase requests and, from S4, the proforma requests of the sales: either module opens them,
            // and each request is then checked against its own module.
            if (!await u.ModuleEnabledAsync("LC_PURCHASE", http.RequestAborted)) await u.RequireModuleAsync("LC_SALES", http.RequestAborted);
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
               AND (@kind = '' OR cp.Kind = @kind OR cp.Kind = 'BOTH')
             ORDER BY cp.NameEn;
            """, new { q, nq = Normalizer.Name(q), eq = RequestEndpoints.NormaliseRef(q), kind = http.Request.Query["kind"].ToString().ToUpperInvariant() switch
            {
                "CUSTOMER" => "CUSTOMER", "SUPPLIER" => "SUPPLIER", _ => "",
            } }, cancellationToken: http.RequestAborted));
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
        if (r is null || r.TypeCode is not ("PURCHASE_LC" or "LC_AMENDMENT" or "PROFORMA_REQUEST")) throw ApiProblemException.NotFound();
        if (!await u.ModuleEnabledAsync(r.TypeCode == "PROFORMA_REQUEST" ? "LC_SALES" : "LC_PURCHASE", ct, tx)) throw ApiProblemException.NotFound();
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
            beneficiaryIban = await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition(
                "SELECT BeneficiaryAccountIbanMask FROM lc.LcTerms WHERE LcTermsId = @t;", new { t = t.LcTermsId }, cancellationToken: ct)),
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

using System.Globalization;
using System.Text;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Banking;
using BankFas.Core.Security;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record AccountRequest(Guid? Company, Guid? Institution, string? Type, string? Currency, string? AccountNumber, string? Iban, string? Nickname,
    string? BranchUnit, string? SigningRuleText, int? MinSignatures, string? OpenedOn, Guid? Master, bool? CreateRelationship);
public sealed record AccountStatusRequest(string? Status);

/// <summary>
/// Company bank accounts (FR-ACC-001 to 009; BR-ACC-001 to 006, 016). The number and the IBAN are encrypted with the
/// tenant's DATA key, bound to their row and column, masked when written, and unique through blind indexes: the number
/// per institution, the IBAN per tenant, a closed account keeping its number. An account follows the relationship of
/// its company and institution, which the user may create in the same step (BR-ACC-003). A virtual account sits under
/// a master of the same company, institution and currency, one level only; the master closes after its virtual
/// accounts (BR-ACC-004). A closed account is final and read-only. The full number is shown only to the holders of
/// acc.reveal, and every reveal, or attempt, is in the audit log (FR-ACC-009; S1 brief S1-GAP-15).
/// </summary>
public static class AccountEndpoints
{
    private const string View = "acc.view";
    private const string Manage = "acc.manage";
    private const string Close = "acc.close";
    private const string Reveal = "acc.reveal";
    private static readonly string[] Statuses = ["ACTIVE", "DORMANT", "FROZEN"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/accounts", ListAsync);
        api.MapPost("/accounts", CreateAsync);
        api.MapGet("/accounts/{id:guid}", GetAsync);
        api.MapPatch("/accounts/{id:guid}", PatchAsync);
        api.MapPost("/accounts/{id:guid}/actions/status", StatusAsync);
        api.MapPost("/accounts/{id:guid}/actions/close", CloseAsync);
        api.MapPost("/accounts/{id:guid}/actions/reveal", RevealAsync);
    }

    private static DateTime? Date(string? text, string field) =>
        string.IsNullOrWhiteSpace(text) ? null
        : DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
        : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is a date YYYY-MM-DD.");

    private static string? D(DateTime? d) => d?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static string? T(string? text, int max, string field)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var t = text.Trim();
        return t.Length <= max ? t : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is up to {max} characters.");
    }

    internal sealed record AccountRow(long BankAccountId, Guid PublicId, long CompanyId, Guid Company, string CompanyName, long InstitutionId, Guid Institution,
        string InstitutionCode, Guid Relationship, string Type, bool IsVirtual, long? MasterAccountId, Guid? Master, string Currency, string? Nickname, string AccountNoMask,
        string AccountNoLast4, string? IbanMask, long? BranchUnitId, string? BranchName, string? SigningRuleText, int MinSignatures, string Status, DateTime? OpenedOn,
        DateTime? ClosedOn, string? ClosureReason, byte[] RowVersion);

    private const string Select =
        """
        SELECT a.BankAccountId, a.PublicId, a.CompanyId, c.PublicId AS Company, ISNULL(c.NameAr, c.NameEn) AS CompanyName, a.InstitutionId, i.PublicId AS Institution,
               i.Code AS InstitutionCode, r.PublicId AS Relationship, t.Code AS Type, t.IsVirtual, a.MasterAccountId, m.PublicId AS Master, cu.Code AS Currency, a.Nickname,
               a.AccountNoMask, a.AccountNoLast4, a.IbanMask, a.BranchUnitId, n.NameAr AS BranchName, a.SigningRuleText, a.MinSignatures, a.Status, a.OpenedOn, a.ClosedOn,
               a.ClosureReason, a.RowVersion
          FROM acc.BankAccount AS a
          JOIN org.Company AS c ON c.CompanyId = a.CompanyId
          JOIN ins.Institution AS i ON i.InstitutionId = a.InstitutionId
          JOIN ins.Relationship AS r ON r.RelationshipId = a.RelationshipId
          JOIN cat.AccountType AS t ON t.AccountTypeId = a.AccountTypeId
          JOIN ref.Currency AS cu ON cu.CurrencyId = a.CurrencyId
          LEFT JOIN acc.BankAccount AS m ON m.BankAccountId = a.MasterAccountId
          LEFT JOIN ins.InstitutionUnit AS n ON n.InstitutionUnitId = a.BranchUnitId
        """;

    private static object Shape(AccountRow a, OpaqueRefs refs, int tenant) => new
    {
        id = a.PublicId, company = a.Company, companyName = a.CompanyName, institution = a.Institution, institutionCode = a.InstitutionCode, relationship = a.Relationship,
        type = a.Type, isVirtual = a.IsVirtual, master = a.Master, currency = a.Currency, nickname = a.Nickname, accountNumber = a.AccountNoMask, last4 = a.AccountNoLast4,
        iban = a.IbanMask, branchUnit = a.BranchUnitId is { } b ? refs.ItemRef(tenant, "unit", b) : null, branchName = a.BranchName, signingRuleText = a.SigningRuleText,
        minSignatures = a.MinSignatures, status = a.Status, openedOn = D(a.OpenedOn), closedOn = D(a.ClosedOn), closureReason = a.ClosureReason, etag = ETags.Of(a.RowVersion),
    };

    private static async Task<AccountRow> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct)
    {
        var a = await u.Connection.QuerySingleOrDefaultAsync<AccountRow>(new CommandDefinition(Select + " WHERE a.PublicId = @id;", new { id }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        if (!(await CompanyScope.OfAsync(u, ct, tx)).Allows(a.CompanyId)) throw ApiProblemException.NotFound();
        return a;
    }

    /// <summary>SCR-ACC-01 and SVC-06 FindAccounts: masked, within the company scope; "last4" finds by the last four digits.</summary>
    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "company", "institution", "type", "currency", "status", "last4");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var q = http.Request.Query;
        static string? Up(Microsoft.Extensions.Primitives.StringValues v) => v.ToString() is { Length: > 0 } s ? s.Trim().ToUpperInvariant() : null;
        var rows = await u.Connection.QueryAsync<AccountRow>(new CommandDefinition(
            Select + """
             WHERE (@all = 1 OR a.CompanyId IN @ids) AND (@company IS NULL OR c.PublicId = @company) AND (@institution IS NULL OR i.PublicId = @institution)
               AND (@type IS NULL OR t.Code = @type) AND (@currency IS NULL OR cu.Code = @currency) AND (@status IS NULL OR a.Status = @status)
               AND (@last4 IS NULL OR a.AccountNoLast4 = @last4)
             ORDER BY 5, i.Code, a.BankAccountId
             OFFSET 0 ROWS FETCH NEXT 500 ROWS ONLY;
            """,
            new
            {
                all = scope.All, ids = scope.SqlIds, company = Guid.TryParse(q["company"], out var c) ? c : (Guid?)null,
                institution = Guid.TryParse(q["institution"], out var i) ? i : (Guid?)null, type = Up(q["type"]), currency = Up(q["currency"]), status = Up(q["status"]),
                last4 = Up(q["last4"]),
            }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(a => Shape(a, refs, u.TenantId)) });
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var a = await FindAsync(u, null, id, http.RequestAborted);
        var virtuals = await u.Connection.QueryAsync<(Guid Id, string Mask, string Status)>(new CommandDefinition(
            "SELECT PublicId, AccountNoMask, Status FROM acc.BankAccount WHERE MasterAccountId = @a ORDER BY BankAccountId;", new { a = a.BankAccountId },
            cancellationToken: http.RequestAborted));
        ETags.Set(http.Response, a.RowVersion);
        return Results.Ok(new { account = Shape(a, refs, u.TenantId), virtualAccounts = virtuals.Select(v => new { id = v.Id, accountNumber = v.Mask, status = v.Status }) });
    }

    private static async Task<IResult> CreateAsync(AccountRequest b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, OpaqueRefs refs, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var scope = await CompanyScope.OfAsync(u, ct, tx);
        var company = await InstitutionEndpoints.CompanyAsync(u, tx, scope, b.Company, ct);
        var institution = await InstitutionEndpoints.FindAsync(u.Connection, tx, b.Institution ?? Guid.Empty, ct);
        if (institution.Status == "INACTIVE") throw new ApiProblemException(409, "V-INS-INACTIVE", "The institution is inactive.");

        // BR-ACC-003: the account follows the relationship, created here when the user agrees.
        var relationship = await u.Connection.QuerySingleOrDefaultAsync<(long Id, string Status)?>(new CommandDefinition(
            "SELECT RelationshipId, Status FROM ins.Relationship WHERE CompanyId = @c AND InstitutionId = @i;", new { c = company.Id, i = institution.InstitutionId }, tx,
            cancellationToken: ct));
        if (relationship is { Status: "CLOSED" }) throw new ApiProblemException(409, "V-INS-CLOSED", "The relationship with this institution is closed: reopen it first.");
        long relationshipId;
        if (relationship is { } existing) relationshipId = existing.Id;
        else if (b.CreateRelationship == true)
            relationshipId = (await InstitutionEndpoints.InsertRelationshipAsync(u, tx, company.Id, institution.InstitutionId, null, "ACTIVE",
                DateTime.SpecifyKind(clock.GetUtcNow().UtcDateTime.Date, DateTimeKind.Unspecified), null, ct)).Id;
        else throw new ApiProblemException(409, "V-ACC-RELATIONSHIP-REQUIRED", "The company has no relationship with this institution: confirm to create it.");

        var type = await u.Connection.QuerySingleOrDefaultAsync<(int Id, string Code, bool IsVirtual)?>(new CommandDefinition(
            "SELECT AccountTypeId, Code, IsVirtual FROM cat.AccountType WHERE Code = @c AND IsActive = 1;", new { c = b.Type?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the type of account.");
        var currencyId = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @c AND IsActive = 1;",
            new { c = b.Currency?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-ACC-01", "Choose the currency.");

        // BR-ACC-004: a virtual account under a master that is not virtual, not closed, of the same company, institution and currency.
        long? masterId = null;
        if (type.IsVirtual)
        {
            if (b.Master is null) throw ApiProblemException.Invalid("V-ACC-02", "A virtual account sits under a master account.");
            var m = await u.Connection.QuerySingleOrDefaultAsync<(long Id, long CompanyId, long InstitutionId, int CurrencyId, string Status, bool IsVirtual)?>(new CommandDefinition(
                """
                SELECT a.BankAccountId, a.CompanyId, a.InstitutionId, a.CurrencyId, a.Status, t.IsVirtual FROM acc.BankAccount AS a
                  JOIN cat.AccountType AS t ON t.AccountTypeId = a.AccountTypeId WHERE a.PublicId = @m;
                """, new { m = b.Master }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-ACC-02", "Choose the master account.");
            if (m.IsVirtual) throw ApiProblemException.Invalid("V-ACC-02", "The master account is not itself virtual.");
            if (m.Status == "CLOSED") throw ApiProblemException.Invalid("V-ACC-02", "The master account is closed.");
            if (m.CompanyId != company.Id || m.InstitutionId != institution.InstitutionId || m.CurrencyId != currencyId)
                throw ApiProblemException.Invalid("V-ACC-02", "The master account is of the same company, institution and currency.");
            masterId = m.Id;
        }
        else if (b.Master is not null) throw ApiProblemException.Invalid("V-ACC-02", "Only a virtual account has a master account.");

        var number = BankAccountNumbers.Normalize(b.AccountNumber);
        if (number.Length is < 4 or > 34) throw ApiProblemException.Invalid("V-ACC-01", "Enter the account number.");
        var iban = string.IsNullOrWhiteSpace(b.Iban) ? null : BankAccountNumbers.Normalize(b.Iban);
        if (iban is not null && BankAccountNumbers.IbanProblem(iban) is { } problem)
            throw ApiProblemException.Invalid("V-ACC-01", problem switch
            {
                "LENGTH" => "The IBAN does not have the length of its country.",
                "CHECKSUM" => "The IBAN check digits do not match: check the number.",
                _ => "The IBAN starts with the country code and two check digits.",
            });
        var minSignatures = b.MinSignatures ?? 1;
        if (minSignatures < 1) throw ApiProblemException.Invalid("V-ACC-03", "At least one signature is required.");
        long? branchId = null;
        if (b.BranchUnit is not null)
        {
            var unit = refs.ItemId(u.TenantId, "unit", b.BranchUnit) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a branch of the institution.");
            branchId = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT InstitutionUnitId FROM ins.InstitutionUnit WHERE InstitutionUnitId = @n AND InstitutionId = @i AND IsActive = 1;",
                new { n = unit, i = institution.InstitutionId }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a branch of the institution.");
        }

        var (dataKeyId, dataKey) = await keys.ActiveAsync(u.Connection, tx, u.TenantId, "DATA", ct);
        var (hashKeyId, hashKey) = await keys.ActiveAsync(u.Connection, tx, u.TenantId, "BLIND_INDEX", ct);
        var numberHash = BankAccountNumbers.BlindIndex(hashKey, "ACCOUNT", number);
        var ibanHash = iban is null ? null : BankAccountNumbers.BlindIndex(hashKey, "IBAN", iban);
        // BR-ACC-001: the number per institution, the IBAN per tenant, closed accounts included.
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM acc.BankAccount WHERE InstitutionId = @i AND AccountNoHash = @h;",
                new { i = institution.InstitutionId, h = numberHash }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-ACC-01", "This account number is already recorded at this institution.");
        if (ibanHash is not null && await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM acc.BankAccount WHERE IbanHash = @h;",
                new { h = ibanHash }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-ACC-01", "This IBAN is already recorded.");

        var publicId = Guid.NewGuid();
        var numberEnc = Envelope.Seal(dataKey, Encoding.UTF8.GetBytes(number), EnvelopeAad.ForColumn(u.TenantId, "acc.BankAccount", "AccountNoEnc", publicId));
        var ibanEnc = iban is null ? null : Envelope.Seal(dataKey, Encoding.UTF8.GetBytes(iban), EnvelopeAad.ForColumn(u.TenantId, "acc.BankAccount", "IbanEnc", publicId));
        long accountId;
        try
        {
            accountId = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT acc.BankAccount (TenantId, PublicId, CompanyId, InstitutionId, RelationshipId, AccountTypeId, MasterAccountId, CurrencyId, Nickname, AccountNoEnc,
                                        AccountNoMask, AccountNoHash, AccountNoLast4, IbanEnc, IbanMask, IbanHash, EncKeyId, HashKeyId, BranchUnitId, SigningRuleText,
                                        MinSignatures, OpenedOn, CreatedBy)
                OUTPUT inserted.BankAccountId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @pub, @c, @i, @r, @type, @master, @currency, @nick, @numberEnc, @numberMask, @numberHash, @last4,
                        @ibanEnc, @ibanMask, @ibanHash, @encKey, @hashKey, @branch, @rule, @min, @opened, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """,
                new
                {
                    pub = publicId, c = company.Id, i = institution.InstitutionId, r = relationshipId, type = type.Id, master = masterId, currency = currencyId,
                    nick = T(b.Nickname, 100, "nickname"), numberEnc, numberMask = BankAccountNumbers.MaskNumber(number), numberHash, last4 = BankAccountNumbers.Last4(number),
                    ibanEnc, ibanMask = iban is null ? null : BankAccountNumbers.MaskIban(iban), ibanHash, encKey = dataKeyId, hashKey = hashKeyId, branch = branchId,
                    rule = T(b.SigningRuleText, 500, "signing rule"), min = minSignatures, opened = Date(b.OpenedOn, "opening date"),
                }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "V-ACC-01", "This account number or IBAN is already recorded.");
        }
        await Outbox.EmitAsync(u.Connection, tx, "account.created", "acc.BankAccount", accountId, new { account = publicId, type = type.Code }, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("ACCOUNT_CREATED", "TREASURY", "acc.BankAccount", accountId,
            AfterJson: JsonSerializer.Serialize(new { institution = institution.Code, type = type.Code, currency = b.Currency, last4 = BankAccountNumbers.Last4(number), virtualAccount = type.IsVirtual })),
            company.Id, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/accounts/{publicId}", new { id = publicId, relationshipCreated = relationship is null });
    }

    /// <summary>FR-ACC-007: nickname, branch, signing rule and minimum signatures; a closed account is read-only.</summary>
    private static async Task<IResult> PatchAsync(Guid id, AccountRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var a = await FindAsync(u, tx, id, ct);
        if (a.Status == "CLOSED") throw new ApiProblemException(409, "V-ACC-CLOSED", "A closed account is read-only.");
        if ((b.Company ?? b.Institution) is not null || (b.Type ?? b.Currency ?? b.AccountNumber ?? b.Iban) is not null || b.Master is not null)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The company, institution, type, currency, number, IBAN and master do not change: open another account.");
        if (b.MinSignatures is < 1) throw ApiProblemException.Invalid("V-ACC-03", "At least one signature is required.");
        long? branchId = a.BranchUnitId;
        if (b.BranchUnit is not null)
            branchId = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT InstitutionUnitId FROM ins.InstitutionUnit WHERE InstitutionUnitId = @n AND InstitutionId = @i AND IsActive = 1;",
                new { n = refs.ItemId(u.TenantId, "unit", b.BranchUnit) ?? -1, i = a.InstitutionId }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a branch of the institution.");
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE acc.BankAccount SET Nickname = CASE WHEN @setNick = 1 THEN @nick ELSE Nickname END, BranchUnitId = @branch,
                   SigningRuleText = CASE WHEN @setRule = 1 THEN @rule ELSE SigningRuleText END, MinSignatures = ISNULL(@min, MinSignatures),
                   OpenedOn = ISNULL(@opened, OpenedOn), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.RowVersion INTO @o WHERE BankAccountId = @a AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """,
            new
            {
                setNick = b.Nickname is not null, nick = T(b.Nickname, 100, "nickname"), branch = branchId, setRule = b.SigningRuleText is not null,
                rule = T(b.SigningRuleText, 500, "signing rule"), min = b.MinSignatures, opened = Date(b.OpenedOn, "opening date"), a = a.BankAccountId, rv = expected,
            }, tx, cancellationToken: ct)) ?? throw ETags.Conflict();
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("ACCOUNT_UPDATED", "TREASURY", "acc.BankAccount", a.BankAccountId,
            BeforeJson: JsonSerializer.Serialize(new { a.Nickname, a.MinSignatures, a.SigningRuleText }), AfterJson: JsonSerializer.Serialize(new { b.Nickname, b.MinSignatures, b.SigningRuleText })),
            a.CompanyId, ct);
        await tx.CommitAsync(ct);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    /// <summary>FR-ACC-008: ACTIVE, DORMANT or FROZEN; freezing takes acc.close.</summary>
    private static async Task<IResult> StatusAsync(Guid id, AccountStatusRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var status = b.Status?.Trim().ToUpperInvariant();
        if (status is null || !Statuses.Contains(status)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The status is ACTIVE, DORMANT or FROZEN; close an account with its action.");
        await using var u = await BoundUser.OpenAsync(http, db, status == "FROZEN" ? Close : Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var a = await FindAsync(u, tx, id, http.RequestAborted);
        if (a.Status == "CLOSED") throw new ApiProblemException(409, "V-ACC-CLOSED", "A closed account is final: open another account.");
        if (a.Status == status) return Results.NoContent();
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE acc.BankAccount SET Status = @status, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE BankAccountId = @a;",
            new { status, a = a.BankAccountId }, tx, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("ACCOUNT_STATUS_CHANGED", "TREASURY", "acc.BankAccount", a.BankAccountId,
            BeforeJson: JsonSerializer.Serialize(new { a.Status }), AfterJson: JsonSerializer.Serialize(new { status })), a.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>BR-ACC-004, BR-ACC-006: with a date and a reason, after the virtual accounts under it; final.</summary>
    private static async Task<IResult> CloseAsync(Guid id, CloseRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Close);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var a = await FindAsync(u, tx, id, ct);
        if (a.Status == "CLOSED") return Results.NoContent();
        var reason = T(b.Reason, 300, "reason") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason for closing.");
        var closedOn = Date(b.ClosedOn, "closing date") ?? clock.GetUtcNow().UtcDateTime.Date;
        if (a.OpenedOn is { } o && closedOn < o) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The closing date comes after the opening date.");
        var open = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM acc.BankAccount WHERE MasterAccountId = @a AND Status <> 'CLOSED';",
            new { a = a.BankAccountId }, tx, cancellationToken: ct));
        if (open > 0) throw new ApiProblemException(409, "V-ACC-02", $"Close the {open} virtual account(s) under this account first.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE acc.BankAccount SET Status = 'CLOSED', ClosedOn = @d, ClosureReason = @reason, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE BankAccountId = @a;
            """, new { d = closedOn, reason, a = a.BankAccountId }, tx, cancellationToken: ct));
        await Outbox.EmitAsync(u.Connection, tx, "account.closed", "acc.BankAccount", a.BankAccountId, new { account = a.PublicId }, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("ACCOUNT_CLOSED", "TREASURY", "acc.BankAccount", a.BankAccountId,
            BeforeJson: JsonSerializer.Serialize(new { a.Status }), AfterJson: JsonSerializer.Serialize(new { closedOn = D(closedOn), reason })), a.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>FR-ACC-009, BR-ACC-016: the full number and IBAN to the holders of acc.reveal; the reveal and every refusal are audited.</summary>
    private static async Task<IResult> RevealAsync(Guid id, RevealRequest b, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var a = await FindAsync(u, null, id, ct);
        var ua = http.Request.Headers.UserAgent.ToString();
        var reason = T(b.Reason, 300, "reason");
        if (!(await u.PermissionsAsync(ct)).Contains(Reveal))
        {
            await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("ACCOUNT_REVEAL_DENIED", "IDENTITY_ACCESS", "acc.BankAccount", a.BankAccountId,
                AfterJson: JsonSerializer.Serialize(new { reason, denyReason = "NO_PERMISSION" }), Severity: "HIGH", Result: "DENIED", UserAgent: ua), a.CompanyId, ct);
            throw ApiProblemException.Forbidden();
        }
        var row = await u.Connection.QuerySingleAsync<(byte[] NumberEnc, byte[]? IbanEnc, long KeyId)>(new CommandDefinition(
            "SELECT AccountNoEnc, IbanEnc, EncKeyId FROM acc.BankAccount WHERE BankAccountId = @a;", new { a = a.BankAccountId }, cancellationToken: ct));
        var key = await keys.ByIdAsync(u.Connection, null, u.TenantId, row.KeyId, ct);
        var number = Encoding.UTF8.GetString(Envelope.Open(key, row.NumberEnc, EnvelopeAad.ForColumn(u.TenantId, "acc.BankAccount", "AccountNoEnc", a.PublicId)));
        var iban = row.IbanEnc is null ? null
            : Encoding.UTF8.GetString(Envelope.Open(key, row.IbanEnc, EnvelopeAad.ForColumn(u.TenantId, "acc.BankAccount", "IbanEnc", a.PublicId)));
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("ACCOUNT_REVEALED", "IDENTITY_ACCESS", "acc.BankAccount", a.BankAccountId,
            AfterJson: JsonSerializer.Serialize(new { reason, last4 = a.AccountNoLast4 }), UserAgent: ua), a.CompanyId, ct);
        await AuditWriter.RevealAnomalyAsync(u.Connection, null, ct);
        var remask = await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition(
            "SELECT ISNULL(t.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key] WHERE d.[Key] = 'security.reveal.remask_seconds';",
            cancellationToken: ct));
        http.Response.Headers.CacheControl = "no-store";
        return Results.Ok(new { accountNumber = number, iban, remaskSeconds = int.TryParse(remask, CultureInfo.InvariantCulture, out var s) ? s : 60 });
    }
}

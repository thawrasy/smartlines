using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Lc;
using BankFas.Core.Text;
using BankFas.Data;
using BankFas.Data.Lc;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record FormTemplateBody(string? Code, string? FormKind, Guid? Institution, string? Product, string? Scope, string? Channel, string? Language, DateOnly? EffectiveFrom,
    DateOnly? EffectiveTo, string? AnnexVersion, string? FooterTextAr, string? FooterTextEn);
public sealed record FieldMapBody(string? TargetName, string? SourceExpr, string? Transform, string? TransformArg, bool? IsRequired, int? SeqNo);

/// <summary>
/// The bank form templates and their field maps (FR-LCT-025 to 027, BR-LCT-017, 020; OQ-16: by API with a read
/// screen). A holder of lc.template.manage writes a DRAFT version and its maps, then activates it; activation retires
/// the active version of the same key, and the database refuses two active templates for one key and start date.
/// A request's data sheet resolves the most specific active template in force (bank and product before the default)
/// and fills each target from its source path (terms., company., counterparty., facility.) with its transform; a
/// required target without a value is listed, as it stops the official print.
/// </summary>
public static class FormTemplateEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/lc-form-templates", ListAsync);
        api.MapGet("/lc-form-templates/{id:guid}", GetAsync);
        api.MapPost("/lc-form-templates", CreateAsync);
        api.MapPut("/lc-form-templates/{id:guid}/field-maps", MapsAsync);
        api.MapPost("/lc-form-templates/{id:guid}/activate", ActivateAsync);
        api.MapGet("/requests/{id:guid}/bank-form", SheetAsync);
    }

    // The list and a template read for who prints the forms (lc.print) and who keeps them (lc.template.manage).
    private const string Readers = "lc.print|lc.template.manage";

    private static async Task<BoundUser> OpenAsync(HttpContext http, SqlConnectionFactory db, string permission)
    {
        var anyOf = permission.Split('|');
        var u = anyOf.Length == 1 ? await BoundUser.OpenAsync(http, db, permission) : await BoundUser.OpenAsync(http, db);
        try
        {
            if (anyOf.Length > 1 && !(await u.PermissionsAsync(http.RequestAborted)).Overlaps(anyOf)) throw ApiProblemException.Forbidden();
            await u.RequireModuleAsync("LC_PURCHASE", http.RequestAborted);
            return u;
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }

    private const string Columns = """
        t.PublicId AS id, t.Code AS code, t.VersionNo AS version, t.FormKind AS formKind, i.NameEn AS bankNameEn, i.NameAr AS bankNameAr, p.Code AS product,
        t.Scope AS scope, t.Channel AS channel, t.LayoutKind AS layoutKind, t.Language AS language, t.EffectiveFrom AS effectiveFrom, t.EffectiveTo AS effectiveTo,
        t.AnnexVersion AS annexVersion, t.LegalReviewStatus AS legalReview, t.Status AS status
        """;

    private const string From = """
        lc.LcFormTemplate AS t LEFT JOIN ins.Institution AS i ON i.InstitutionId = t.InstitutionId LEFT JOIN cat.Product AS p ON p.ProductId = t.ProductId
        """;

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request);
        await using var u = await OpenAsync(http, db, Readers);
        var rows = await u.Connection.QueryAsync(new CommandDefinition($"SELECT {Columns} FROM {From} ORDER BY t.Code, t.VersionNo DESC;", cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    private static async Task<long> IdAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct) =>
        await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT LcFormTemplateId FROM lc.LcFormTemplate WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.NotFound();

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request);
        await using var u = await OpenAsync(http, db, Readers);
        var ct = http.RequestAborted;
        var tid = await IdAsync(u, null, id, ct);
        var head = await u.Connection.QuerySingleAsync(new CommandDefinition($"SELECT {Columns} FROM {From} WHERE t.LcFormTemplateId = @tid;", new { tid }, cancellationToken: ct));
        var maps = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT TargetName AS targetName, SourceExpr AS sourceExpr, Transform AS transform, TransformArg AS transformArg, IsRequired AS isRequired, SeqNo AS seqNo
              FROM lc.LcFormFieldMap WHERE TemplateId = @tid ORDER BY ISNULL(SeqNo, 2147483647), TargetName;
            """, new { tid }, cancellationToken: ct));
        return Results.Ok(new { template = head, maps });
    }

    private static async Task<IResult> CreateAsync(FormTemplateBody b, HttpContext http, SqlConnectionFactory db)
    {
        var code = b.Code?.Trim().ToUpperInvariant();
        if (string.IsNullOrEmpty(code) || code.Length > 40 || b.FormKind is not ("LC_APPLICATION" or "LC_AMENDMENT") || b.EffectiveFrom is null)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the code, the form kind (LC_APPLICATION or LC_AMENDMENT) and the start date.");
        if (b.EffectiveTo is { } to && to < b.EffectiveFrom) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The template ends on or after its start.");
        await using var u = await OpenAsync(http, db, "lc.template.manage");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        long? institution = b.Institution is { } inst
            ? await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @inst;", new { inst }, tx, cancellationToken: ct))
              ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank is not known.")
            : null;
        int? product = b.Product is { Length: > 0 } pc
            ? await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT ProductId FROM cat.Product WHERE Code = @pc;", new { pc }, tx, cancellationToken: ct))
              ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The product is not known.")
            : null;
        var version = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT ISNULL(MAX(VersionNo), 0) + 1 FROM lc.LcFormTemplate WHERE Code = @code;", new { code }, tx,
            cancellationToken: ct));
        var publicId = await u.Connection.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            DECLARE @o TABLE (PublicId UNIQUEIDENTIFIER, Id BIGINT);
            INSERT lc.LcFormTemplate (TenantId, Code, VersionNo, FormKind, InstitutionId, ProductId, Scope, Channel, LayoutKind, Language, EffectiveFrom, EffectiveTo, AnnexVersion,
                                      FooterTextAr, FooterTextEn, Status, CreatedBy)
            OUTPUT inserted.PublicId, inserted.LcFormTemplateId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @version, @kind, @institution, @product, ISNULL(@scope, 'ANY'), ISNULL(@channel, 'ANY'), 'SYSTEM_PRINT',
                    @lang, @from, @to, @annex, @fAr, @fEn, 'DRAFT', @u);
            SELECT PublicId FROM @o;
            """,
            new
            {
                code, version, kind = b.FormKind, institution, product, scope = b.Scope, channel = b.Channel, lang = b.Language, from = b.EffectiveFrom.Value.ToDateTime(TimeOnly.MinValue),
                to = b.EffectiveTo?.ToDateTime(TimeOnly.MinValue), annex = b.AnnexVersion, fAr = b.FooterTextAr, fEn = b.FooterTextEn, u = u.UserId,
            }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LC_FORM_TEMPLATE_CREATED", "TREASURY", "lc.LcFormTemplate", null,
            AfterJson: JsonSerializer.Serialize(new { code, version, b.FormKind })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/lc-form-templates/{publicId}", new { id = publicId, version });
    }

    private static readonly string[] Transforms = ["NONE", "UPPER", "DATE_DMY", "DATE_HIJRI", "AMOUNT_WORDS_AR", "AMOUNT_WORDS_EN", "CHECKBOX_EQ", "CONCAT_DOCS", "CHARGES_SUMMARY"];
    private static readonly string[] Roots = ["terms.", "company.", "counterparty.", "facility."];

    private static async Task<IResult> MapsAsync(Guid id, FieldMapBody[] maps, HttpContext http, SqlConnectionFactory db)
    {
        ArgumentNullException.ThrowIfNull(maps);
        foreach (var m in maps)
        {
            if (string.IsNullOrWhiteSpace(m.TargetName) || m.TargetName.Length > 120 || string.IsNullOrWhiteSpace(m.SourceExpr) || m.SourceExpr.Length > 200
                || !Roots.Any(r => m.SourceExpr.StartsWith(r, StringComparison.Ordinal)) || m.SourceExpr.Any(ch => !(char.IsAsciiLetterOrDigit(ch) || ch is '.' or '_')))
                throw ApiProblemException.Invalid("V-LCT-MAP", "A map gives its target and a source path under terms., company., counterparty. or facility. (BR-LCT-020).");
            if (!Transforms.Contains(m.Transform ?? "NONE") || (m.Transform == "CHECKBOX_EQ" && string.IsNullOrWhiteSpace(m.TransformArg)))
                throw ApiProblemException.Invalid("V-LCT-MAP", "The transform is one of the list; CHECKBOX_EQ gives the value it ticks for.");
        }
        await using var u = await OpenAsync(http, db, "lc.template.manage");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var tid = await IdAsync(u, tx, id, ct);
        if (await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition("SELECT Status FROM lc.LcFormTemplate WITH (UPDLOCK) WHERE LcFormTemplateId = @tid;", new { tid }, tx,
                cancellationToken: ct)) != "DRAFT")
            throw new ApiProblemException(409, "TEMPLATE_PUBLISHED", "Only a draft template's maps change; a change is a new version.");
        await u.Connection.ExecuteAsync(new CommandDefinition("DELETE FROM lc.LcFormFieldMap WHERE TemplateId = @tid;", new { tid }, tx, cancellationToken: ct));
        foreach (var m in maps)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT lc.LcFormFieldMap (TenantId, TemplateId, TargetName, SourceExpr, Transform, TransformArg, IsRequired, SeqNo, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @tid, @target, @src, @tr, @arg, @req, @seq, @u);
                """, new { tid, target = m.TargetName!.Trim(), src = m.SourceExpr, tr = m.Transform ?? "NONE", arg = m.TransformArg, req = m.IsRequired ?? false, seq = m.SeqNo, u = u.UserId },
                tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.Ok(new { count = maps.Length });
    }

    private static async Task<IResult> ActivateAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await OpenAsync(http, db, "lc.template.manage");
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var tid = await IdAsync(u, tx, id, ct);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            DECLARE @t TABLE (InstitutionId BIGINT, ProductId INT, CompanyId BIGINT, FormKind VARCHAR(20), Scope VARCHAR(20), Channel VARCHAR(20), Code VARCHAR(40));
            INSERT @t SELECT InstitutionId, ProductId, CompanyId, FormKind, Scope, Channel, Code FROM lc.LcFormTemplate WITH (UPDLOCK) WHERE LcFormTemplateId = @tid AND Status = 'DRAFT';
            UPDATE x SET Status = 'RETIRED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
              FROM lc.LcFormTemplate AS x JOIN @t AS k ON k.Code = x.Code
             WHERE x.Status = 'ACTIVE' AND x.LcFormTemplateId <> @tid;
            UPDATE lc.LcFormTemplate SET Status = 'ACTIVE', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LcFormTemplateId = @tid AND Status = 'DRAFT';
            """, new { tid, u = u.UserId }, tx, cancellationToken: ct));
        if (n == 0) throw new ApiProblemException(409, "INVALID_STATE", "Only a draft template is activated.");
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LC_FORM_TEMPLATE_ACTIVATED", "TREASURY", "lc.LcFormTemplate", tid), null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>FR-LCT-025: the portal data sheet of a purchase request: the template resolved by BR-LCT-017 and each target's value.</summary>
    private static async Task<IResult> SheetAsync(Guid id, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request);
        await using var u = await OpenAsync(http, db, "lc.print");
        var ct = http.RequestAborted;
        var r = await u.Connection.QuerySingleOrDefaultAsync<(long RequestId, long CompanyId, long? FacilityId, string? Channel, int? ProductId)?>(new CommandDefinition(
            """
            SELECT r.RequestId, r.CompanyId, r.FacilityId, r.ExecutionChannel, pl.ProductId FROM wfl.Request AS r
              LEFT JOIN fac.LimitProductLine AS pl ON pl.LimitProductLineId = r.LimitProductLineId WHERE r.PublicId = @id;
            """, new { id }, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (!(await CompanyScope.OfAsync(u, ct)).Allows(r.CompanyId)) throw ApiProblemException.NotFound();
        var terms = await TermsStore.CurrentAsync(u.Connection, null, r.RequestId, ct) ?? throw ApiProblemException.NotFound();
        var bank = r.FacilityId is { } f
            ? await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                """
                SELECT TOP (1) l.InstitutionId FROM fac.FacilityLender AS l JOIN fac.Facility AS x ON x.FacilityId = l.FacilityId
                 WHERE l.FacilityId = @f AND l.FromRevision <= x.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > x.ApprovedRevisionNo)
                 ORDER BY CASE WHEN l.Roles LIKE '%AGENT%' OR l.Roles LIKE '%SOLE%' THEN 0 ELSE 1 END, l.SharePct DESC;
                """, new { f }, cancellationToken: ct))
            : null;
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var template = await u.Connection.QuerySingleOrDefaultAsync<(long Id, Guid PublicId, string Code, int Version, string? Annex)?>(new CommandDefinition(
            """
            SELECT TOP (1) LcFormTemplateId, PublicId, Code, VersionNo, AnnexVersion FROM lc.LcFormTemplate
             WHERE Status = 'ACTIVE' AND FormKind = 'LC_APPLICATION' AND EffectiveFrom <= @today AND (EffectiveTo IS NULL OR EffectiveTo >= @today)
               AND (InstitutionId IS NULL OR InstitutionId = @bank) AND (ProductId IS NULL OR ProductId = @product) AND (CompanyId IS NULL OR CompanyId = @co)
               AND (Scope = 'ANY' OR Scope = @scope) AND (Channel = 'ANY' OR Channel = @channel)
             ORDER BY CASE WHEN CompanyId IS NULL THEN 0 ELSE 4 END + CASE WHEN InstitutionId IS NULL THEN 0 ELSE 2 END + CASE WHEN ProductId IS NULL THEN 0 ELSE 1 END DESC,
                      EffectiveFrom DESC;
            """, new { today, bank, product = r.ProductId, co = r.CompanyId, scope = terms.Scope, channel = r.Channel ?? "MANUAL_FORM" }, cancellationToken: ct))
            ?? throw new ApiProblemException(409, "NO_FORM_TEMPLATE", "No active bank form applies to this request.");
        var maps = await u.Connection.QueryAsync<(string Target, string Source, string Transform, string? Arg, bool Required)>(new CommandDefinition(
            "SELECT TargetName, SourceExpr, Transform, TransformArg, IsRequired FROM lc.LcFormFieldMap WHERE TemplateId = @t ORDER BY ISNULL(SeqNo, 2147483647), TargetName;",
            new { t = template.Id }, cancellationToken: ct));
        var values = await TermsStore.ReadAsync(u.Connection, null, terms.LcTermsId, true, ct);
        var context = await u.Connection.QuerySingleAsync<(string? CoAr, string? CoEn, string? CpEn, string? CpAr, string? CpCountry, string? FacNo, string? Cur, int Dec, string? CurAr, string? CurEn)>(
            new CommandDefinition(
                """
                SELECT co.NameAr, co.NameEn, cp.NameEn, cp.NameAr, ctry.Iso2, f.FacilityNo, cur.Code, ISNULL(cur.Decimals, 2), cur.NameAr, cur.NameEn
                  FROM lc.LcTerms AS t JOIN org.Company AS co ON co.CompanyId = @co
                  LEFT JOIN lc.Counterparty AS cp ON cp.CounterpartyId = t.BeneficiaryCounterpartyId LEFT JOIN ref.Country AS ctry ON ctry.CountryId = cp.CountryId
                  LEFT JOIN fac.Facility AS f ON f.FacilityId = @f LEFT JOIN ref.Currency AS cur ON cur.CurrencyId = t.CurrencyId
                 WHERE t.LcTermsId = @t;
                """, new { co = r.CompanyId, f = r.FacilityId, t = terms.LcTermsId }, cancellationToken: ct));
        object? Source(string path) => path switch
        {
            _ when path.StartsWith("terms.", StringComparison.Ordinal) => values.GetValueOrDefault(path[6..]),
            "company.nameAr" => context.CoAr, "company.nameEn" => context.CoEn,
            "counterparty.nameEn" => context.CpEn, "counterparty.nameAr" => context.CpAr, "counterparty.country" => context.CpCountry,
            "facility.facilityNo" => context.FacNo,
            _ => null,
        };
        var docs = await u.Connection.QueryAsync<string>(new CommandDefinition(
            "SELECT k.NameEn FROM lc.LcTermsDocument AS d JOIN lc.LcDocumentClause AS k ON k.LcDocumentClauseId = d.ClauseId WHERE d.LcTermsId = @t ORDER BY d.SeqNo;",
            new { t = terms.LcTermsId }, cancellationToken: ct));
        var charges = await u.Connection.QueryAsync<string>(new CommandDefinition(
            "SELECT CONCAT(ChargeCategory, ': ', Payer) FROM lc.LcChargesMatrix WHERE LcTermsId = @t ORDER BY ChargeCategory;", new { t = terms.LcTermsId }, cancellationToken: ct));
        var items = new List<object>();
        var missing = new List<string>();
        foreach (var m in maps)
        {
            var raw = Source(m.Source);
            var text = m.Transform switch
            {
                "AMOUNT_WORDS_AR" => raw is decimal a ? AmountInWords.Arabic(a, context.CurAr ?? context.Cur ?? "", context.Dec) : "",
                "AMOUNT_WORDS_EN" => raw is decimal e ? AmountInWords.English(e, context.CurEn ?? context.Cur ?? "", context.Dec) : "",
                "CONCAT_DOCS" => string.Join("; ", docs),
                "CHARGES_SUMMARY" => string.Join("; ", charges),
                _ => FormFieldTransform.Apply(m.Transform, raw, m.Arg),
            };
            if (m.Required && string.IsNullOrEmpty(text)) missing.Add(m.Target);
            items.Add(new { target = m.Target, value = text, required = m.Required });
        }
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("LC_BANK_FORM_PRINTED", "TREASURY", "lc.LcTerms", terms.LcTermsId,
            AfterJson: JsonSerializer.Serialize(new { template = template.Code, version = template.Version, annex = template.Annex,
                hash = terms.SnapshotHash is null ? null : Convert.ToHexString(terms.SnapshotHash) })), r.CompanyId, ct);
        return Results.Ok(new
        {
            template = new { id = template.PublicId, code = template.Code, version = template.Version, annexVersion = template.Annex },
            items, missingRequired = missing, official = missing.Count == 0,
        });
    }
}

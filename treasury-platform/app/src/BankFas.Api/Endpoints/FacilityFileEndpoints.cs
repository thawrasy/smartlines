using System.Data;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record FacilityFileEntryRequest(string? EntryDate, string? Direction, string? Kind, string? Subject, string? BankRef, Guid? Document, Guid? Facility);

/// <summary>
/// The facility file of a company with a bank (docs/31 row 75): COMPANY-BANK-NNNN, opened by the first approval of a
/// facility of the pair (<see cref="FacilityRefs"/>). It holds every contract of the relation over its life, by class
/// (CAP, STL, MTL, LTL ...) and renewal, and the correspondence with the bank: letters, e-mails, offers and renewal
/// requests, incoming or outgoing, with a document of the company. A file is read when its company is in the user's scope.
/// </summary>
public static class FacilityFileEndpoints
{
    private static readonly string[] Directions = ["INCOMING", "OUTGOING"];
    private static readonly string[] Kinds = ["LETTER", "EMAIL", "OFFER", "RENEWAL_REQUEST", "OTHER"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/facility-files", ListAsync);
        api.MapGet("/facility-files/{id:guid}", GetAsync);
        api.MapPost("/facility-files/{id:guid}/entries", AddEntryAsync);
    }

    private sealed record FileRow(long FacilityFileId, Guid PublicId, string FileRef, long CompanyId, Guid CompanyPublicId, string CompanyNameAr, string? CompanyNameEn,
        Guid BankPublicId, string BankNameAr, string? BankNameEn, string? BankCode, string Status, DateTime OpenedOn, int Contracts);

    private const string Select =
        """
        SELECT ff.FacilityFileId, ff.PublicId, ff.FileRef, ff.CompanyId, co.PublicId AS CompanyPublicId, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn,
               i.PublicId AS BankPublicId, i.NameAr AS BankNameAr, i.NameEn AS BankNameEn, i.RefCode AS BankCode, ff.Status, ff.OpenedOn,
               (SELECT COUNT(*) FROM fac.FacilityFileFacility AS m WHERE m.FacilityFileId = ff.FacilityFileId) AS Contracts
          FROM fac.FacilityFile AS ff JOIN org.Company AS co ON co.CompanyId = ff.CompanyId JOIN ins.Institution AS i ON i.InstitutionId = ff.InstitutionId
        """;

    private static object Head(FileRow r) => new
    {
        id = r.PublicId, fileRef = r.FileRef, status = r.Status, openedOn = r.OpenedOn.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture), contracts = r.Contracts,
        company = new { id = r.CompanyPublicId, nameAr = r.CompanyNameAr, nameEn = r.CompanyNameEn },
        bank = new { id = r.BankPublicId, nameAr = r.BankNameAr, nameEn = r.BankNameEn, code = r.BankCode },
    };

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db, Guid? company, Guid? bank, string? q)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.View);
        await using var _ = u;
        var rows = await u.Connection.QueryAsync<FileRow>(new CommandDefinition(
            Select + """

             WHERE (@company IS NULL OR co.PublicId = @company) AND (@bank IS NULL OR i.PublicId = @bank) AND (@q IS NULL OR ff.FileRef LIKE @q + '%')
             ORDER BY ff.FileRef;
            """, new { company, bank, q = string.IsNullOrWhiteSpace(q) ? null : q.Trim().ToUpperInvariant() }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Where(r => scope.Allows(r.CompanyId)).Select(Head) });
    }

    private static async Task<FileRow> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct)
    {
        var r = await u.Connection.QuerySingleOrDefaultAsync<FileRow>(new CommandDefinition(Select + "\n WHERE ff.PublicId = @id;", new { id }, tx, cancellationToken: ct));
        if (r is null || !scope.Allows(r.CompanyId)) throw ApiProblemException.NotFound();
        return r;
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var r = await FindAsync(u, null, id, scope, ct);
        var contracts = await u.Connection.QueryAsync<(string Class, int Seq, Guid Id, string? Ref, string Status, DateTime From, DateTime To, decimal Amount, string Currency)>(
            new CommandDefinition(
                """
                SELECT m.ClassCode, m.SeqInClass, f.PublicId, f.PlatformRef, f.LifecycleStatus, f.EffectiveFrom, f.ExpiryDate, f.TotalAmount, cu.Code
                  FROM fac.FacilityFileFacility AS m JOIN fac.Facility AS f ON f.FacilityId = m.FacilityId JOIN ref.Currency AS cu ON cu.CurrencyId = f.CurrencyId
                 WHERE m.FacilityFileId = @file ORDER BY m.ClassCode, m.SeqInClass;
                """, new { file = r.FacilityFileId }, cancellationToken: ct));
        var entries = await u.Connection.QueryAsync<(DateTime Date, string Direction, string Kind, string Subject, string? BankRef, Guid? Document, string? DocumentTitle, string? FacilityRef)>(
            new CommandDefinition(
                """
                SELECT e.EntryDate, e.Direction, e.Kind, e.Subject, e.BankRef, d.PublicId, d.Title, f.PlatformRef
                  FROM fac.FacilityFileEntry AS e LEFT JOIN doc.Document AS d ON d.DocumentId = e.DocumentId LEFT JOIN fac.Facility AS f ON f.FacilityId = e.FacilityId
                 WHERE e.FacilityFileId = @file ORDER BY e.EntryDate DESC, e.FacilityFileEntryId DESC;
                """, new { file = r.FacilityFileId }, cancellationToken: ct));
        return Results.Ok(new
        {
            file = Head(r),
            contracts = contracts.Select(c => new
            {
                facilityClass = c.Class, seq = c.Seq, id = c.Id, platformRef = c.Ref, status = c.Status, effectiveFrom = c.From.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture),
                expiryDate = c.To.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture), totalAmount = c.Amount, currency = c.Currency,
            }),
            entries = entries.Select(e => new
            {
                entryDate = e.Date.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture), direction = e.Direction, kind = e.Kind, subject = e.Subject, bankRef = e.BankRef,
                document = e.Document is null ? null : new { id = e.Document, title = e.DocumentTitle }, facilityRef = e.FacilityRef,
            }),
            canEdit = (await u.PermissionsAsync(ct)).Contains(FacilityEndpoints.Edit),
        });
    }

    private static async Task<IResult> AddEntryAsync(Guid id, FacilityFileEntryRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        var direction = b.Direction?.Trim().ToUpperInvariant();
        var kind = b.Kind?.Trim().ToUpperInvariant();
        if (direction is null || !Directions.Contains(direction)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The direction is INCOMING or OUTGOING.");
        if (kind is null || !Kinds.Contains(kind)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The kind is LETTER, EMAIL, OFFER, RENEWAL_REQUEST or OTHER.");
        if (string.IsNullOrWhiteSpace(b.Subject) || b.Subject.Trim().Length > 300) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the subject, up to 300 characters.");
        if (b.BankRef?.Trim().Length > 80) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bank's reference is up to 80 characters.");
        if (!DateTime.TryParseExact(b.EntryDate, "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var date))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date of the letter as yyyy-MM-dd.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        var r = await FindAsync(u, tx, id, scope, ct);
        long? document = null, facility = null;
        if (b.Document is not null)
            document = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND OwnerCompanyId = @c;", new { d = b.Document, c = r.CompanyId }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is not a document of the company.");
        if (b.Facility is not null)
            facility = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                """
                SELECT f.FacilityId FROM fac.Facility AS f JOIN fac.FacilityFileFacility AS m ON m.FacilityId = f.FacilityId
                 WHERE f.PublicId = @f AND m.FacilityFileId = @file;
                """, new { f = b.Facility, file = r.FacilityFileId }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The facility is not a contract of this file.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT fac.FacilityFileEntry (TenantId, FacilityFileId, EntryDate, Direction, Kind, Subject, BankRef, DocumentId, FacilityId, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @file, @date, @direction, @kind, @subject, @bankRef, @document, @facility, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new { file = r.FacilityFileId, date = date.Date, direction, kind, subject = b.Subject.Trim(), bankRef = b.BankRef?.Trim(), document, facility },
            tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facility-files/{id}", new { id });
    }
}

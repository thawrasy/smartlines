using BankFas.Api.Infrastructure;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

/// <summary>
/// The files of a letter of credit (docs/31 row 52): the copy of the credit, its SWIFT messages, the amendment copies and
/// SWIFTs, the bank's advices and the special approvals of an authorised person, kept in the encrypted document store
/// and linked to the credit; the card shows them with the attachments of the credit's requests (its issue and its
/// child requests). A holder of lc.view.internal sees the internal attachments of the requests too.
/// </summary>
internal static class LcDocuments
{
    /// <summary>Who may file a document on a credit: the treasury that records its issue, amendments, drawings or the received credit.</summary>
    internal static readonly string[] Recorders = ["lc.issuance.record", "lc.amendment.record", "lc.drawing.record", "lc.export.record"];

    internal static async Task<IEnumerable<dynamic>> ListAsync(SqlConnection c, long lcId, bool internalView, CancellationToken ct) =>
        await c.QueryAsync(new CommandDefinition(
            $"""
            SELECT d.PublicId AS id, d.Title AS title, t.Code AS type, t.NameAr AS typeNameAr, t.NameEn AS typeNameEn, v.FileName AS fileName, v.ScanStatus AS scanStatus,
                   x.source, x.requestNo, x.at
              FROM (SELECT k.DocumentId, N'LC' AS source, CAST(NULL AS nvarchar(30)) AS requestNo, k.CreatedAt AS at
                      FROM doc.DocumentLink AS k WHERE k.EntityType = 'lc.LetterOfCredit' AND k.EntityId = @lcId AND k.UnlinkedAt IS NULL
                    UNION
                    SELECT a.DocumentId, N'REQUEST', r.RequestNo, a.CreatedAt
                      FROM wfl.RequestAttachment AS a JOIN wfl.Request AS r ON r.RequestId = a.RequestId
                      JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = @lcId
                     WHERE a.IsActive = 1 AND (r.RequestId = l.RequestId OR r.LcId = @lcId) {(internalView ? "" : "AND a.Visibility = 'REQUESTER_VISIBLE'")}) AS x
              JOIN doc.Document AS d ON d.DocumentId = x.DocumentId AND d.Status = 'ACTIVE'
              JOIN cat.DocumentType AS t ON t.DocumentTypeId = d.DocumentTypeId
              LEFT JOIN doc.DocumentVersion AS v ON v.DocumentVersionId = d.CurrentVersionId
             ORDER BY x.at;
            """, new { lcId }, cancellationToken: ct)).ConfigureAwait(false);

    /// <summary>Links a stored document of the credit's company to the credit; a second link of the same document does nothing.</summary>
    internal static async Task LinkAsync(BoundUser u, SqlTransaction tx, long lcId, Guid? document, CancellationToken ct)
    {
        var perms = await u.PermissionsAsync(ct).ConfigureAwait(false);
        if (!Recorders.Any(perms.Contains)) throw ApiProblemException.Forbidden();
        if (document is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the document.");
        var d = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            """
            SELECT d.DocumentId FROM doc.Document AS d JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = @lcId
             WHERE d.PublicId = @doc AND d.Status = 'ACTIVE' AND (d.OwnerCompanyId IS NULL OR d.OwnerCompanyId = l.CompanyId);
            """, new { doc = document, lcId }, tx, cancellationToken: ct)).ConfigureAwait(false)
            ?? throw ApiProblemException.Invalid("DOCUMENT_NOT_FOUND", "The document is not a stored document of the company.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            IF NOT EXISTS (SELECT 1 FROM doc.DocumentLink WHERE DocumentId = @d AND EntityType = 'lc.LetterOfCredit' AND EntityId = @lcId AND UnlinkedAt IS NULL)
                INSERT doc.DocumentLink (TenantId, DocumentId, EntityType, EntityId, LinkRole, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @d, 'lc.LetterOfCredit', @lcId, 'ATTACHMENT', @u);
            """, new { d, lcId, u = u.UserId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var company = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition("SELECT CompanyId FROM lc.LetterOfCredit WHERE LetterOfCreditId = @lcId;",
            new { lcId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await BankFas.Data.AuditWriter.WriteAsync(u.Connection, tx, new BankFas.Data.AuditEntry("LC_DOCUMENT_FILED", "TREASURY", "lc.LetterOfCredit", lcId,
            AfterJson: System.Text.Json.JsonSerializer.Serialize(new { document })), company, ct).ConfigureAwait(false);
    }
}

using BankFas.Api.Infrastructure;
using BankFas.Core.Files;
using BankFas.Data;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

/// <summary>
/// A file uploaded straight onto a request or a letter of credit (docs/31 row 52): the requester sends the request with
/// its files, and the treasury files the SWIFT of the credit, the amendment copies, the bank's advices and the approvals
/// of an authorised person. The file goes into the encrypted document store as a document of the request's (or the
/// credit's) company, scanned like any upload, then is attached: to a slot of the template or as an extra attachment of
/// the request, or to the credit. Access is the request's or the credit's, not the document register's, so a requester
/// uploads to their own request without seeing the company's other documents. Restricted types stay with their holders.
/// </summary>
public static class AttachmentUploadEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapPost("/requests/{id:guid}/attachments/upload", RequestAsync);
        api.MapPost("/lcs/{id:guid}/documents/upload", (Guid id, HttpContext h, SqlConnectionFactory d, TenantKeyRing k, FileStore s, IMalwareScanner m) =>
            LcAsync(id, false, h, d, k, s, m));
        api.MapPost("/sales/lcs/{id:guid}/documents/upload", (Guid id, HttpContext h, SqlConnectionFactory d, TenantKeyRing k, FileStore s, IMalwareScanner m) =>
            LcAsync(id, true, h, d, k, s, m));
    }

    private static bool AppliesTo(DocumentEndpoints.DocType t, string entity) =>
        string.IsNullOrEmpty(t.AppliesTo) || t.AppliesTo.Split(',').Any(x => x.Trim() is var v && (v == entity || v == "GENERAL"));

    private static async Task<(IFormCollection Form, string Title)> FormAsync(HttpContext http)
    {
        if (!http.Request.HasFormContentType) throw ApiProblemException.Invalid("FILE_REQUIRED", "Send the file as multipart/form-data.");
        var form = await http.Request.ReadFormAsync(http.RequestAborted);
        var title = form["title"].ToString().Trim();
        if (title.Length is 0 or > 200) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter a title (up to 200 characters).");
        return (form, title);
    }

    private static async Task<IResult> RequestAsync(Guid id, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, FileStore store, IMalwareScanner scanner)
    {
        var (form, title) = await FormAsync(http);
        var slot = form["slot"].ToString() is { Length: > 0 } sl ? sl.Trim() : null;
        Guid document;
        await using (var u = await RequestEndpoints.OpenAsync(http, db))
        {
            var ct = http.RequestAborted;
            var actor = await RequestEndpoints.ActorAsync(u, null, ct);
            var requestId = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT RequestId FROM wfl.Request WHERE PublicId = @id;", new { id },
                cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
            var r = await RequestEngine.FindAsync(u.Connection, null, requestId, false, ct) ?? throw ApiProblemException.NotFound();
            if (!(await RequestEndpoints.AccessForAsync(u, null, r, actor, ct)).Visible) throw ApiProblemException.NotFound();
            if (r.Status is "COMPLETED" or "REJECTED" or "CANCELLED") throw new ApiProblemException(409, "INVALID_STATE", "The request is closed.");
            // A slot takes its own type; an extra attachment takes the type chosen.
            var code = slot is null ? form["documentType"].ToString()
                : await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition(
                      "SELECT t.Code FROM wfl.TemplateAttachmentRule AS a JOIN cat.DocumentType AS t ON t.DocumentTypeId = a.DocumentTypeId WHERE a.TemplateId = @t AND a.SlotKey = @slot;",
                      new { t = r.TemplateId, slot }, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-REQ-SLOT", "The template has no such attachment slot.");
            var type = await DocumentEndpoints.TypeAsync(u, null, code, ct);
            if (slot is null && !AppliesTo(type, "REQUEST")) throw ApiProblemException.Invalid("V-REQ-SLOT-TYPE", "This document type is not for requests.");
            await DocumentEndpoints.RequireRestrictedAsync(u, type, ct);
            var file = await DocumentEndpoints.ReadFileAsync(form.Files["file"], type, ct);
            var company = await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition("SELECT CompanyId, PublicId FROM org.Company WHERE CompanyId = @c;",
                new { c = r.CompanyId }, cancellationToken: ct));
            var created = await DocumentEndpoints.CreateAsync(u, type, file, new DocumentEndpoints.DocMeta(title, null, null, null, null, null, null), company,
                ("wfl.Request", r.RequestId, "ATTACHMENT"), keys, store, scanner, ct);
            if (created.ScanStatus != "CLEAN") throw new ApiProblemException(422, "FILE_QUARANTINED", "The file is held in quarantine and is not attached.");
            document = created.Id;
        }
        await RequestEndpoints.AttachAsync(id, new RequestAttachmentBody(document, slot), http, db);
        return Results.Created($"/api/v1/documents/{document}", new { document, slot });
    }

    private static async Task<IResult> LcAsync(Guid id, bool sales, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, FileStore store, IMalwareScanner scanner)
    {
        var (form, title) = await FormAsync(http);
        await using var u = sales ? await SalesEndpoints.OpenAsync(http, db) : await LcEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        if (!LcDocuments.Recorders.Any((await u.PermissionsAsync(ct)).Contains)) throw ApiProblemException.Forbidden();
        var lcId = sales ? await SalesLcEndpoints.IdAsync(u, null, id, ct) : await LcEndpoints.IdAsync(u, null, id, ct);
        var type = await DocumentEndpoints.TypeAsync(u, null, form["documentType"].ToString(), ct);
        if (!AppliesTo(type, "LC")) throw ApiProblemException.Invalid("V-LC-DOC-TYPE", "This document type is not for letters of credit.");
        await DocumentEndpoints.RequireRestrictedAsync(u, type, ct);
        var file = await DocumentEndpoints.ReadFileAsync(form.Files["file"], type, ct);
        var company = await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
            "SELECT co.CompanyId, co.PublicId FROM lc.LetterOfCredit AS l JOIN org.Company AS co ON co.CompanyId = l.CompanyId WHERE l.LetterOfCreditId = @lcId;",
            new { lcId }, cancellationToken: ct));
        var created = await DocumentEndpoints.CreateAsync(u, type, file, new DocumentEndpoints.DocMeta(title, form["documentNumber"].ToString() is { Length: > 0 } n ? n : null,
            null, null, null, null, null), company, ("lc.LetterOfCredit", lcId, "ATTACHMENT"), keys, store, scanner, ct);
        await using (var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct))
        {
            await LcDocuments.LinkAsync(u, tx, lcId, created.Id, ct);
            await tx.CommitAsync(ct);
        }
        return Results.Created($"/api/v1/documents/{created.Id}", new { document = created.Id, scanStatus = created.ScanStatus });
    }
}

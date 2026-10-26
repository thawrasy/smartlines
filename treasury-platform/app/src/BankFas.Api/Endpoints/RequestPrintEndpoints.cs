using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Lc;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

/// <summary>
/// The printed request (FR-REQ-026, docs/31 row 52): its header, the fields of its form, its attachments and its
/// timeline, in the viewer's view (the requester never sees the treasury's stage, internal notes or internal files),
/// with a watermark of who printed it and when. As HTML for the browser, as PDF, or saved as a PDF in the document
/// store and attached to the request (REQUEST_PRINT), so the copy that was sent or signed stays in the system. A
/// restricted field is never printed. Each print is audited.
/// </summary>
public static class RequestPrintEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/requests/{id:guid}/print", PrintAsync);
        api.MapPost("/requests/{id:guid}/print/save", SaveAsync);
    }

    private static string H(object? v) => WebUtility.HtmlEncode(v switch
    {
        null => "",
        DateTime d => d.TimeOfDay == TimeSpan.Zero ? d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : d.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture),
        decimal m => m.ToString("#,0.##", CultureInfo.InvariantCulture),
        _ => Convert.ToString(v, CultureInfo.InvariantCulture) ?? "",
    });

    private const string Style =
        BankFas.Data.PrintStyle.Base + "body{font-size:11pt;margin:1.6cm}h1{font-size:15pt}h2{font-size:12pt;margin-top:1.2em}" +
        "td,th{padding:3px 6px}th.label{width:32%}" +
        ".mark{position:fixed;top:45%;left:0;right:0;text-align:center;font-size:28pt;color:rgba(160,0,0,.12);transform:rotate(-24deg);pointer-events:none}" +
        ".foot{font-size:9pt;margin-top:2em}";

    private static string FieldText(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.String => v.GetString() ?? "",
        JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False => v.GetRawText(),
        JsonValueKind.Object when v.TryGetProperty("value", out var a) && v.TryGetProperty("currency", out var c) => $"{a.GetRawText()} {c.GetString()}",
        JsonValueKind.Null or JsonValueKind.Undefined => "",
        _ => "",
    };

    internal static async Task<(string Html, RequestEngine.RequestRow R, Actor Actor, bool Staff, bool Arabic)> BuildAsync(BoundUser u, SqlTransaction? tx, Guid id, string? lang,
        DateTimeOffset now, CancellationToken ct)
    {
        var actor = await RequestEndpoints.ActorAsync(u, tx, ct);
        var requestId = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT RequestId FROM wfl.Request WHERE PublicId = @id;", new { id }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        var r = await RequestEngine.FindAsync(u.Connection, tx, requestId, false, ct) ?? throw ApiProblemException.NotFound();
        var (visible, staff) = await RequestEndpoints.AccessForAsync(u, tx, r, actor, ct);
        if (!visible) throw ApiProblemException.NotFound();
        var me = await u.Connection.QuerySingleAsync<(string? Lang, string? NameAr, string? NameEn, string Email)>(new CommandDefinition(
            "SELECT PreferredLanguage, DisplayNameAr, DisplayNameEn, Email FROM sec.AppUser WHERE AppUserId = @u;", new { u = u.UserId }, tx, cancellationToken: ct));
        var ar = lang is { Length: > 0 } ? lang == "ar" : me.Lang == "ar";
        string T(string a, string e) => ar ? a : e;
        var head = await u.Connection.QuerySingleAsync<(string TypeAr, string? TypeEn, string CompanyAr, string? CompanyEn, string PhaseAr, string? PhaseEn, string? ReqAr, string? ReqEn,
            DateTime CreatedAt, DateTime? SubmittedAt, DateTime? CompletedAt, string? Stage)>(new CommandDefinition(
            """
            SELECT rt.NameAr, rt.NameEn, co.NameAr, co.NameEn, ph.NameAr, ph.NameEn, req.DisplayNameAr, req.DisplayNameEn, r.CreatedAt, r.SubmittedAt, r.CompletedAt, s.StageKey
              FROM wfl.Request AS r JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId JOIN org.Company AS co ON co.CompanyId = r.CompanyId
              JOIN wfl.ExternalPhase AS ph ON ph.ExternalPhaseId = r.ExternalPhaseId JOIN sec.AppUser AS req ON req.AppUserId = r.RequesterUserId
              LEFT JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = r.CurrentStageId
             WHERE r.RequestId = @id;
            """, new { id = requestId }, tx, cancellationToken: ct));
        var fields = await RequestEngine.FieldsAsync(u.Connection, tx, r.TemplateId, ct);
        using var form = JsonDocument.Parse(r.FormDataJson ?? "{}");
        var attachments = await u.Connection.QueryAsync<(string Title, string? Slot, string Type, DateTime At)>(new CommandDefinition(
            $"""
            SELECT d.Title, a.SlotKey, t.Code, a.CreatedAt FROM wfl.RequestAttachment AS a JOIN doc.Document AS d ON d.DocumentId = a.DocumentId
              JOIN cat.DocumentType AS t ON t.DocumentTypeId = d.DocumentTypeId
             WHERE a.RequestId = @id AND a.IsActive = 1 {(staff ? "" : "AND a.Visibility = 'REQUESTER_VISIBLE'")} ORDER BY a.CreatedAt;
            """, new { id = requestId }, tx, cancellationToken: ct));
        var timeline = await u.Connection.QueryAsync<(string Action, DateTime At, string? Comment, string? ActorAr, string? ActorEn, string? ToStage)>(new CommandDefinition(
            $"""
            SELECT a.ActionType, a.OccurredAt, a.Comment, u.DisplayNameAr, u.DisplayNameEn, a.ToStageKey
              FROM wfl.RequestAction AS a LEFT JOIN sec.AppUser AS u ON u.AppUserId = a.ActorUserId
             WHERE a.RequestId = @id {(staff ? "" : "AND a.Visibility = 'REQUESTER_VISIBLE'")} ORDER BY a.OccurredAt, a.RequestActionId;
            """, new { id = requestId }, tx, cancellationToken: ct));

        var number = r.RequestNo ?? r.DraftRef;
        var who = (ar ? me.NameAr ?? me.NameEn : me.NameEn ?? me.NameAr) ?? me.Email;
        var at = now.UtcDateTime.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) + " UTC";
        var sb = new StringBuilder();
        sb.Append(CultureInfo.InvariantCulture, $"<!doctype html><html lang=\"{(ar ? "ar" : "en")}\" dir=\"{(ar ? "rtl" : "ltr")}\"><head><meta charset=\"utf-8\"><title>{H(number)}</title><style>{Style}</style></head><body>");
        sb.Append(CultureInfo.InvariantCulture, $"<div class=\"mark\">{H(T("نسخة مطبوعة", "Printed copy"))} · {H(who)} · {H(at)}</div>");
        sb.Append(CultureInfo.InvariantCulture, $"<h1>{H(ar ? head.TypeAr : head.TypeEn ?? head.TypeAr)} <span dir=\"ltr\">{H(number)}</span></h1><table>");
        void Row(string label, object? value) => sb.Append(CultureInfo.InvariantCulture, $"<tr><th class=\"label\">{H(label)}</th><td>{H(value)}</td></tr>");
        Row(T("الشركة", "Company"), ar ? head.CompanyAr : head.CompanyEn ?? head.CompanyAr);
        Row(T("الطالب", "Requester"), ar ? head.ReqAr ?? head.ReqEn : head.ReqEn ?? head.ReqAr);
        Row(T("المرحلة الظاهرة", "Phase"), ar ? head.PhaseAr : head.PhaseEn ?? head.PhaseAr);
        if (staff) Row(T("المرحلة الداخلية", "Stage"), head.Stage);
        Row(T("أُنشئ", "Created"), head.CreatedAt);
        Row(T("قُدّم", "Submitted"), head.SubmittedAt);
        Row(T("أُنجز", "Completed"), head.CompletedAt);
        sb.Append("</table><h2>").Append(H(T("بيانات الطلب", "The request"))).Append("</h2><table>");
        foreach (var f in fields)
        {
            if (f.Sensitivity == "RESTRICTED" || f.DataType is "MODULE_FORM" or "LIMIT_SELECTION" or "FILE_SLOT") continue;
            if (!form.RootElement.TryGetProperty(f.FieldKey, out var v)) continue;
            Row(ar ? f.LabelAr : f.LabelEn, FieldText(v));
        }
        sb.Append("</table><h2>").Append(H(T("المرفقات", "Attachments"))).Append("</h2><table>");
        foreach (var a in attachments) Row($"{a.Type}{(a.Slot is null ? "" : " · " + a.Slot)}", $"{a.Title} ({a.At:yyyy-MM-dd})");
        if (!attachments.Any()) Row("—", T("لا مرفقات", "No attachment"));
        sb.Append("</table><h2>").Append(H(T("الخط الزمني", "Timeline"))).Append("</h2><table>");
        foreach (var e in timeline)
            sb.Append(CultureInfo.InvariantCulture,
                $"<tr><td dir=\"ltr\">{H(e.At)}</td><td>{H(e.Action)}{(staff && e.ToStage is not null ? " → " + H(e.ToStage) : "")}</td><td>{H(staff ? (ar ? e.ActorAr ?? e.ActorEn : e.ActorEn ?? e.ActorAr) : "")}</td><td>{H(e.Comment)}</td></tr>");
        sb.Append("</table>");
        sb.Append(CultureInfo.InvariantCulture, $"<p class=\"foot\">{H(T("طبعه", "Printed by"))} {H(who)} · {H(at)} · BankFas</p></body></html>");
        return (sb.ToString(), r, actor, staff, ar);
    }

    private static async Task<IResult> PrintAsync(Guid id, HttpContext http, SqlConnectionFactory db, PdfRenderer pdf, TimeProvider clock)
    {
        Query.Allow(http.Request, "lang", "format");
        var asPdf = Pdf.Wanted(http.Request);
        await using var u = await RequestEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var (html, r, _, staff, ar) = await BuildAsync(u, null, id, http.Request.Query["lang"], clock.GetUtcNow(), ct);
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("REQUEST_PRINTED", "TREASURY", "wfl.Request", r.RequestId,
            AfterJson: JsonSerializer.Serialize(new { format = asPdf ? "pdf" : "html", view = staff ? "STAFF" : "REQUESTER", lang = ar ? "ar" : "en" })), r.CompanyId, ct);
        http.Response.Headers.CacheControl = "no-store";
        if (asPdf) return await Pdf.FileAsync(pdf, html, $"request-{r.RequestNo ?? r.DraftRef}.pdf", ct);
        http.Response.Headers.ContentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; " + BankFas.Data.PrintStyle.FontSource + "; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";
        return Results.Content(html, "text/html; charset=utf-8");
    }

    /// <summary>The PDF of the request saved in the document store and attached to it (REQUEST_PRINT), with the viewer's visibility.</summary>
    private static async Task<IResult> SaveAsync(Guid id, HttpContext http, SqlConnectionFactory db, PdfRenderer pdf, ProformaServices files, TimeProvider clock)
    {
        if (!pdf.Available) throw new ApiProblemException(503, "PDF_UNAVAILABLE", "The PDF output is not installed on this server.");
        await using var u = await RequestEndpoints.OpenAsync(http, db);
        var ct = http.RequestAborted;
        var now = clock.GetUtcNow();
        var (html, _, _, _, _) = await BuildAsync(u, null, id, null, now, ct);
        byte[] bytes;
        try { bytes = await pdf.RenderAsync(html, ct); }
        catch (InvalidOperationException) { throw new ApiProblemException(503, "PDF_UNAVAILABLE", "The PDF could not be made; try again."); }
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var (_, r, actor, staff, _) = await BuildAsync(u, tx, id, null, now, ct);
        if (r.Status is "COMPLETED" or "REJECTED" or "CANCELLED" && !staff) throw new ApiProblemException(409, "INVALID_STATE", "The request is closed.");
        var number = r.RequestNo ?? r.DraftRef;
        var stamp = now.UtcDateTime.ToString("yyyyMMdd-HHmm", CultureInfo.InvariantCulture);
        var docId = await files.StoreAsync(u.Connection, tx, new GeneratedDocument("REQUEST_PRINT", r.CompanyId, $"{number} · {stamp}", number, now.UtcDateTime.Date,
            $"request-{number}-{stamp}.pdf", "application/pdf", bytes, "wfl.Request", r.RequestId), ct);
        var visible = !staff || actor.UserId == r.RequesterUserId || actor.UserId == r.CreatedByUserId;
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT wfl.RequestAttachment (TenantId, RequestId, DocumentId, SlotKey, StageInstanceId, Visibility, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @d, NULL, @i, @vis, @u);
            INSERT wfl.RequestAction (TenantId, RequestId, StageInstanceId, CycleNo, ActionType, ActorType, ActorUserId, OccurredAt, Visibility, MetaJson, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, 'ATTACHMENT_ADDED', 'USER', @u, SYSUTCDATETIME(), @vis, @meta, @u);
            """, new
            {
                r = r.RequestId, d = docId, i = r.CurrentStageInstanceId, vis = visible ? "REQUESTER_VISIBLE" : "INTERNAL", u = u.UserId, cycle = r.CycleNo,
                meta = JsonSerializer.Serialize(new { kind = "REQUEST_PRINT" }),
            }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REQUEST_PRINT_SAVED", "TREASURY", "wfl.Request", r.RequestId,
            AfterJson: JsonSerializer.Serialize(new { document = docId })), r.CompanyId, ct);
        await tx.CommitAsync(ct);
        var publicId = await u.Connection.ExecuteScalarAsync<Guid>(new CommandDefinition("SELECT PublicId FROM doc.Document WHERE DocumentId = @d;", new { d = docId },
            cancellationToken: ct));
        return Results.Created($"/api/v1/documents/{publicId}", new { document = publicId });
    }
}

using System.Data;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Facilities;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record RevisionRequest(string? ReasonKind, string? EffectiveOn, string? ChangeSummary, string? ExpiryDate, string? ExpiryDateHijri);
public sealed record RevisionActionRequest(string? Reason, string[]? Acknowledge);

/// <summary>
/// The revisions of a facility (FR-FAC-024 to 027; BR-FAC-003, BR-FAC-004; spec 12 section 8; DOC-F13). One revision is
/// open at a time (DRAFT, SUBMITTED or REJECTED; 003). A draft is edited by fac.edit; submitting runs the integrity
/// checks, where an error blocks and a warning is acknowledged by the approver; the approver holds fac.approve and
/// neither edited nor submitted the revision, unless the tenant allows one person (wf.sod.allow_same_person; OQ-6:
/// the editors are the users of the revision's FAC_REVISION_* audit rows). A rejected revision is reopened as a draft
/// or discarded; a discarded draft voids its rows and reopens the rows it had replaced.
///
/// The approval writes in the order the database accepts (S2 brief S2-GAP-2; the order of DOC-F13 section 8 is
/// corrected by it): the rows of the revision are already written (FromRevision = R, with the rows they replace closed
/// at R), so the approval sets the revision APPROVED and then, last and in one statement, raises the facility's
/// ApprovedRevisionNo with its lifecycle and the header changes. The triggers of 044 and 050 then check that every
/// node has one row valid at R, every parent is in R, and the lender shares total 100 with at most one agent; the
/// checks below run first, so an approval never learns a rule from a trigger.
/// </summary>
public static class FacilityRevisionEndpoints
{
    private const string Approve = "fac.approve";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapPost("/facilities/{id:guid}/revisions", OpenAsync);
        api.MapGet("/facilities/{id:guid}/revisions/{reference}/check", DryRunAsync);
        api.MapPost("/facilities/{id:guid}/revisions/{reference}/actions/{action}", ActAsync);
    }

    internal sealed class RevisionRow
    {
        public long FacilityRevisionId { get; init; }
        public long FacilityId { get; init; }
        public int RevisionNo { get; init; }
        public string ReasonKind { get; init; } = "";
        public string Status { get; init; } = "";
        public DateTime EffectiveOn { get; init; }
        public string? ChangeSummary { get; init; }
        public string? HeaderChanges { get; init; }
        public long? SubmittedBy { get; init; }
        public DateTime? SubmittedOn { get; init; }
        public long? ApprovedBy { get; init; }
        public DateTime? ApprovedOn { get; init; }
        public string? RejectionReason { get; init; }
        public string? IntegrityResult { get; init; }
        public long? CreatedBy { get; init; }
        public DateTime CreatedAt { get; init; }

        /// <summary>The header as this revision will make it: its HeaderChanges, or the facility's own header.</summary>
        public FacilityEndpoints.FacilityHeader Header(FacilityEndpoints.FacilityRow f) =>
            HeaderChanges is { Length: > 0 } h ? JsonSerializer.Deserialize<FacilityEndpoints.FacilityHeader>(h, FacilityEndpoints.Json)! : f.Header();
    }

    private const string RevisionSelect =
        """
        SELECT FacilityRevisionId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn, ChangeSummary, HeaderChanges, SubmittedBy, SubmittedOn, ApprovedBy, ApprovedOn,
               RejectionReason, IntegrityResult, CreatedBy, CreatedAt
          FROM fac.FacilityRevision
        """;

    internal static async Task<List<RevisionRow>> RevisionsAsync(BoundUser u, SqlTransaction? tx, long facility, CancellationToken ct) =>
        [.. await u.Connection.QueryAsync<RevisionRow>(new CommandDefinition(RevisionSelect + " WHERE FacilityId = @f ORDER BY RevisionNo DESC;",
            new { f = facility }, tx, cancellationToken: ct))];

    internal static object Shape(RevisionRow r, int tenant, OpaqueRefs refs) => new
    {
        id = refs.ItemRef(tenant, "revision", r.FacilityRevisionId), revisionNo = r.RevisionNo, reasonKind = r.ReasonKind, status = r.Status,
        effectiveOn = FacilityEndpoints.D(r.EffectiveOn), changeSummary = r.ChangeSummary, submittedOn = r.SubmittedOn, approvedOn = r.ApprovedOn,
        rejectionReason = r.RejectionReason, headerChanged = r.HeaderChanges is not null,
        integrity = r.IntegrityResult is { Length: > 0 } j ? JsonSerializer.Deserialize<JsonElement>(j) : (JsonElement?)null,
    };

    internal static async Task<long> InsertRevisionAsync(BoundUser u, SqlTransaction tx, long facility, int no, string kind, string effectiveOn, string? summary,
        string? headerChanges, CancellationToken ct)
    {
        var id = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT fac.FacilityRevision (TenantId, FacilityId, RevisionNo, ReasonKind, Status, EffectiveOn, ChangeSummary, HeaderChanges, CreatedBy)
            OUTPUT inserted.FacilityRevisionId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @no, @kind, 'DRAFT', @on, @summary, @h, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new { f = facility, no, kind, on = effectiveOn, summary = summary?.Trim() is { Length: > 0 } s ? s : null, h = headerChanges }, tx, cancellationToken: ct));
        // The one who opens a revision is one of its editors (BR-FAC-004).
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FAC_REVISION_OPENED", "TREASURY", "fac.FacilityRevision", id,
            AfterJson: JsonSerializer.Serialize(new { revisionNo = no, reasonKind = kind })), null, ct);
        return id;
    }

    /// <summary>The open revision of the facility, which must be a draft for an edit (409 V-FAC-NO-DRAFT otherwise).</summary>
    internal static async Task<RevisionRow> DraftAsync(BoundUser u, SqlTransaction tx, FacilityEndpoints.FacilityRow f, CancellationToken ct)
    {
        var open = await u.Connection.QuerySingleOrDefaultAsync<RevisionRow>(new CommandDefinition(
            RevisionSelect + " WITH (UPDLOCK, HOLDLOCK) WHERE FacilityId = @f AND Status IN ('DRAFT', 'SUBMITTED', 'REJECTED');", new { f = f.FacilityId }, tx, cancellationToken: ct));
        return open switch
        {
            null => throw new ApiProblemException(409, "V-FAC-NO-DRAFT", "The facility is approved: open a revision (amendment, extension or correction) to change it."),
            { Status: "SUBMITTED" } => throw new ApiProblemException(409, "V-FAC-NO-DRAFT", "The revision is waiting for approval: withdraw it to change it."),
            { Status: "REJECTED" } => throw new ApiProblemException(409, "V-FAC-NO-DRAFT", "The revision was rejected: reopen it as a draft to change it."),
            _ => open,
        };
    }

    /// <summary>Every save of a draft is one audit row on the revision; its users are the revision's editors (OQ-6, DQ-F13-2).</summary>
    internal static Task EditedAsync(BoundUser u, SqlTransaction tx, FacilityEndpoints.FacilityRow f, RevisionRow rev, string what, string detail, CancellationToken ct) =>
        AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FAC_REVISION_EDITED", "TREASURY", "fac.FacilityRevision", rev.FacilityRevisionId,
            AfterJson: JsonSerializer.Serialize(new { facility = f.PublicId, revisionNo = rev.RevisionNo, what, detail })), f.BorrowerCompanyId, ct);

    /// <summary>
    /// A new revision of an approved facility (FR-FAC-006, DQ-F13-11): an AMENDMENT (with its addendum), an EXTENSION
    /// (a later expiry date; the only way back from EXPIRED) or a CORRECTION. One revision is open at a time.
    /// </summary>
    private static async Task<IResult> OpenAsync(Guid id, RevisionRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var kind = b.ReasonKind?.Trim().ToUpperInvariant();
        if (kind is not ("AMENDMENT" or "EXTENSION" or "CORRECTION")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A revision is an AMENDMENT, an EXTENSION or a CORRECTION.");
        var (on, _, _) = FacilityEndpoints.DatePair(b.EffectiveOn ?? FacilityEndpoints.D(clock.GetUtcNow().UtcDateTime.Date), null, "date of the revision");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var f = await FacilityEndpoints.FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (f.ApprovedRevisionNo == 0) throw new ApiProblemException(409, "V-FAC-NOT-APPROVED", "The facility is still a draft: edit its first revision.");
        var allowed = kind == "EXTENSION" ? new[] { "ACTIVE", "SUSPENDED", "EXPIRED" } : ["ACTIVE", "SUSPENDED"];
        if (!allowed.Contains(f.LifecycleStatus))
            throw new ApiProblemException(409, "V-FAC-LIFECYCLE", "This facility is not revised this way: an ended facility comes back only by an extension.");
        var revisions = await RevisionsAsync(u, tx, f.FacilityId, ct);
        if (revisions.Any(r => r.Status is "DRAFT" or "SUBMITTED" or "REJECTED"))
            throw new ApiProblemException(409, "OPEN_REVISION_EXISTS", "The facility has an open revision: finish or discard it first.");
        string? header = null;
        if (kind == "EXTENSION" && (b.ExpiryDate is not null || b.ExpiryDateHijri is not null))
        {
            var next = FacilityEndpoints.Merge(f.Header(), new FacilityRequest(null, null, null, null, null, null, null, null, null, null, null, null, null, b.ExpiryDate,
                b.ExpiryDateHijri, null, null, null, null, null, null, null, null, null));
            header = JsonSerializer.Serialize(next, FacilityEndpoints.Json);
        }
        var no = revisions.Max(r => r.RevisionNo) + 1;
        var revId = await InsertRevisionAsync(u, tx, f.FacilityId, no, kind, on!, b.ChangeSummary, header, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}", new { id = refs.ItemRef(u.TenantId, "revision", revId), revisionNo = no });
    }

    // ---------- integrity (V-FAC-01 to 03, the revision's own rules) ----------

    internal sealed record Finding(string Code, string Message);

    internal sealed record Integrity(List<Finding> Errors, List<Finding> Warnings);

    internal static async Task<Integrity> CheckAsync(BoundUser u, SqlTransaction? tx, FacilityEndpoints.FacilityRow f, RevisionRow rev, CancellationToken ct)
    {
        var errors = new List<Finding>();
        var warnings = new List<Finding>();
        var header = rev.Header(f);
        var lenders = (await FacilityEndpoints.LendersAtAsync(u, tx, [(f.FacilityId, int.MaxValue)], ct)).GetValueOrDefault(f.FacilityId, []);
        if (lenders.Count == 0) errors.Add(new("V-FAC-03", "The facility has no lender."));
        else
        {
            var sum = lenders.Sum(l => l.SharePct);
            if (sum != 100) errors.Add(new("V-FAC-02", $"The lenders' shares total {sum:0.######} percent, not 100."));
            if (lenders.Count(l => l.Roles.Split(',').Contains("AGENT")) > 1) errors.Add(new("V-FAC-02", "More than one lender is the agent."));
            if (header.IsSyndicated && lenders.Count < 2) errors.Add(new("V-FAC-02", "A syndicated facility has two lenders or more."));
            if (!header.IsSyndicated && lenders.Count != 1) errors.Add(new("V-FAC-02", "A facility that is not syndicated has one lender."));
            if (header.IsSyndicated && lenders.Any(l => l.Roles.Split(',').Contains("SOLE"))) errors.Add(new("V-FAC-02", "A syndicated facility has no sole lender."));
            // BR-FAC-001: the same lead lender with the same bank reference in another facility is a warning.
            var lead = lenders.FirstOrDefault(l => l.Roles.Split(',').Any(r => r is "SOLE" or "LEAD" or "AGENT")) ?? lenders[0];
            if (header.BankReferenceNo is not null && await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                    """
                    SELECT COUNT(*) FROM fac.Facility AS o JOIN fac.FacilityLender AS l ON l.FacilityId = o.FacilityId AND l.ToRevision IS NULL
                     WHERE o.FacilityId <> @f AND o.BankReferenceNo = @ref AND l.InstitutionId = @i AND o.LifecycleStatus NOT IN ('TERMINATED', 'SUPERSEDED')
                       AND (o.FacilityId <> ISNULL(@prev, -1));
                    """, new { f = f.FacilityId, @ref = header.BankReferenceNo, i = lead.InstitutionId, prev = f.PreviousFacilityId }, tx, cancellationToken: ct)) > 0)
                warnings.Add(new("V-FAC-01", "Another facility of the same lead bank has this bank reference."));
        }
        var docs = await FacilityEndpoints.DocumentsAtAsync(u, tx, f.FacilityId, int.MaxValue, ct);
        if (rev.ReasonKind == "AMENDMENT" && !docs.Any(d => d.FromRevision == rev.RevisionNo && d.DocumentType == "FACILITY_ADDENDUM"))
            errors.Add(new("V-FAC-ADDENDUM", "An amendment carries its addendum: add the addendum document to this revision (FR-FAC-006)."));
        if (rev.ReasonKind == "EXTENSION" && header.Expiry <= f.ExpiryDate)
            errors.Add(new("V-FAC-EXTENSION", "An extension moves the expiry date later."));
        if (!docs.Any(d => d.DocumentType is "FACILITY_AGREEMENT" or "FACILITY_STATEMENT"))
            warnings.Add(new("V-FAC-NO-AGREEMENT", "The facility has no agreement or statement document."));
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM fac.ValueConflict WHERE FacilityId = @f AND Status = 'OPEN';", new { f = f.FacilityId }, tx, cancellationToken: ct)) > 0)
            errors.Add(new("V-FAC-CONFLICT", "A value of the facility has two readings that are not decided (FR-FAC-026)."));
        // The limit tree (V-FAC-04 to 10), and no limit or line closed while it carries a utilisation or a reservation (DQ-F13-9).
        var rows = await FacilityTreeStore.LoadAsync(u.Connection, tx, f.FacilityId, int.MaxValue, ct);
        foreach (var x in LimitEndpoints.CheckTree(rows, rows.Tree(header.TotalAmount)))
            (x.Severity == "E" ? errors : warnings).Add(new(x.Code, x.Message));
        foreach (var (code, message) in await PricingEndpoints.WarningsAsync(u.Connection, tx, f.FacilityId, ct)) warnings.Add(new(code, message));
        var bank = await KycEndpoints.LeadBankAsync(u.Connection, tx, f.FacilityId, int.MaxValue, ct);
        foreach (var (code, message) in await CollateralEndpoints.WarningsAsync(u, tx, f, bank, ct)) warnings.Add(new(code, message));
        foreach (var code in await FacilityTreeStore.ClosedInUseAsync(u.Connection, tx, f.FacilityId, ct))
            errors.Add(new("V-FAC-IN-USE", $"The limit or line {code} carries a utilisation or a reservation: reduce its cap instead of closing it."));
        if (f.PreviousFacilityId is { } prev)
        {
            // BR-FAC-006: a successor that overlaps its predecessor by more than 31 days is a warning.
            var predecessorEnd = await u.Connection.ExecuteScalarAsync<DateTime>(new CommandDefinition("SELECT ExpiryDate FROM fac.Facility WHERE FacilityId = @p;",
                new { p = prev }, tx, cancellationToken: ct));
            if ((predecessorEnd - header.Effective).Days > 31) warnings.Add(new("V-FAC-OVERLAP", "The renewal starts more than 31 days before its predecessor ends."));
        }
        return new Integrity(errors, warnings);
    }

    private static async Task<(FacilityEndpoints.FacilityRow F, RevisionRow Rev)> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, string reference, CompanyScope scope,
        OpaqueRefs refs, CancellationToken ct, bool lockRow = false)
    {
        var f = await FacilityEndpoints.FindAsync(u, tx, id, scope, ct, lockRow);
        var revId = refs.ItemId(u.TenantId, "revision", reference) ?? throw ApiProblemException.NotFound();
        var rev = await u.Connection.QuerySingleOrDefaultAsync<RevisionRow>(new CommandDefinition(
            RevisionSelect + (lockRow ? " WITH (UPDLOCK, HOLDLOCK)" : "") + " WHERE FacilityRevisionId = @r AND FacilityId = @f;", new { r = revId, f = f.FacilityId }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        return (f, rev);
    }

    private static object IntegrityShape(Integrity i) => new
    {
        errors = i.Errors.Select(e => new { code = e.Code, message = e.Message }), warnings = i.Warnings.Select(w => new { code = w.Code, message = w.Message }),
    };

    /// <summary>The integrity checks of the revision as it stands, without changing it (the dry run of the submit and approve screens).</summary>
    private static async Task<IResult> DryRunAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.View);
        await using var _ = u;
        var (f, rev) = await FindAsync(u, null, id, reference, scope, refs, http.RequestAborted);
        return Results.Ok(IntegrityShape(await CheckAsync(u, null, f, rev, http.RequestAborted)));
    }

    // ---------- actions ----------

    private static async Task<IResult> ActAsync(Guid id, string reference, string action, RevisionActionRequest b, HttpContext http, SqlConnectionFactory db,
        OpaqueRefs refs, TimeProvider clock)
    {
        var permission = action switch
        {
            "submit" or "withdraw" or "reopen" or "discard" => FacilityEndpoints.Edit,
            "approve" or "reject" => Approve,
            _ => throw ApiProblemException.NotFound(),
        };
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, permission);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var (f, rev) = await FindAsync(u, tx, id, reference, scope, refs, ct, lockRow: true);
        object? result = null;
        switch (action)
        {
            case "submit":
                {
                    if (rev.Status != "DRAFT") throw new ApiProblemException(409, "REVISION_NOT_DRAFT", "Only a draft revision is submitted.");
                    var check = await CheckAsync(u, tx, f, rev, ct);
                    if (check.Errors.Count > 0) throw ApiProblemException.Invalid("V-FAC-INTEGRITY", string.Join(" ", check.Errors.Select(e => $"{e.Code}: {e.Message}")));
                    await SetAsync(u, tx, rev, "SUBMITTED", "SubmittedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), SubmittedOn = SYSUTCDATETIME(), IntegrityResult = @json",
                        new { json = JsonSerializer.Serialize(IntegrityShape(check)) }, ct);
                    await StateAsync(u, tx, f, rev, "SUBMITTED", "FAC_REVISION_SUBMITTED", null, ct);
                    result = IntegrityShape(check);
                    break;
                }
            case "withdraw":
                if (rev.Status != "SUBMITTED") throw new ApiProblemException(409, "REVISION_NOT_SUBMITTED", "Only a submitted revision is withdrawn.");
                await SetAsync(u, tx, rev, "DRAFT", "SubmittedBy = NULL, SubmittedOn = NULL", null, ct);
                await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FAC_REVISION_WITHDRAWN", "TREASURY", "fac.FacilityRevision", rev.FacilityRevisionId), f.BorrowerCompanyId, ct);
                break;
            case "reopen":
                if (rev.Status != "REJECTED") throw new ApiProblemException(409, "REVISION_NOT_REJECTED", "Only a rejected revision is reopened as a draft.");
                await SetAsync(u, tx, rev, "DRAFT", "SubmittedBy = NULL, SubmittedOn = NULL", null, ct);
                await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FAC_REVISION_REOPENED", "TREASURY", "fac.FacilityRevision", rev.FacilityRevisionId), f.BorrowerCompanyId, ct);
                break;
            case "discard":
                if (rev.Status is not ("DRAFT" or "REJECTED")) throw new ApiProblemException(409, "REVISION_NOT_DRAFT", "Only a draft or a rejected revision is discarded.");
                if (f.ApprovedRevisionNo == 0) throw new ApiProblemException(409, "V-FAC-DISCARD-FIRST", "The first revision of a facility is edited, not discarded.");
                await DiscardRowsAsync(u, tx, f.FacilityId, rev.RevisionNo, ct);
                await SetAsync(u, tx, rev, "DISCARDED", null, null, ct);
                await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FAC_REVISION_DISCARDED", "TREASURY", "fac.FacilityRevision", rev.FacilityRevisionId), f.BorrowerCompanyId, ct);
                break;
            case "reject":
                if (rev.Status != "SUBMITTED") throw new ApiProblemException(409, "REVISION_NOT_SUBMITTED", "The revision is not waiting for approval.");
                if (string.IsNullOrWhiteSpace(b.Reason) || b.Reason.Length > 1000) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason of the rejection.");
                await SetAsync(u, tx, rev, "REJECTED", "RejectionReason = @reason", new { reason = b.Reason.Trim() }, ct);
                await StateAsync(u, tx, f, rev, "REJECTED", "FAC_REVISION_REJECTED", b.Reason.Trim(), ct);
                break;
            case "approve":
                result = await ApproveAsync(u, tx, f, rev, b, clock, ct);
                break;
        }
        await tx.CommitAsync(ct);
        return result is null ? Results.NoContent() : Results.Ok(result);
    }

    private static Task<int> SetAsync(BoundUser u, SqlTransaction tx, RevisionRow rev, string status, string? set, object? args, CancellationToken ct)
    {
        var p = new DynamicParameters(new { r = rev.FacilityRevisionId, status });
        if (args is not null) p.AddDynamicParams(args);
        return u.Connection.ExecuteAsync(new CommandDefinition(
            $"UPDATE fac.FacilityRevision SET Status = @status{(set is null ? "" : ", " + set)}, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE FacilityRevisionId = @r;",
            p, tx, cancellationToken: ct));
    }

    /// <summary>The revisioned tables of a facility that carry its FacilityId; a later batch adds its own (limits, lines, terms, pricing).</summary>
    internal static readonly (string Table, string Key)[] RevisionedTables =
    [
        ("cmp.TermValue", "TermValueId"), ("obl.Covenant", "CovenantId"), ("obl.ReportingObligation", "ReportingObligationId"), ("obl.Obligation", "ObligationId"),
        ("col.CollateralLink", "CollateralLinkId"),
        ("fac.FacilityLender", "FacilityLenderId"), ("fac.FacilityDocument", "FacilityDocumentId"), ("prc.PricingTier", "PricingTierId"), ("prc.PricingRule", "PricingRuleId"),
        ("fac.ProductLineTerm", "ProductLineTermId"),
        ("fac.LimitCompanyRule", "LimitCompanyRuleId"), ("fac.LimitProductLine", "LimitProductLineId"), ("fac.Limit", "LimitId"),
    ];

    /// <summary>A discarded draft: its rows are voided (ToRevision = FromRevision, valid at no revision) and the rows it closed are open again (M13:10).</summary>
    private static async Task DiscardRowsAsync(BoundUser u, SqlTransaction tx, long facility, int revision, CancellationToken ct)
    {
        foreach (var (table, _) in RevisionedTables)
        {
            // The rule and the covenant of an obligation reach the facility through it.
            var of = table is "obl.ReportingObligation" or "obl.Covenant" ? "ObligationId IN (SELECT ObligationId FROM obl.Obligation WHERE FacilityId = @f)" : "FacilityId = @f";
            await u.Connection.ExecuteAsync(new CommandDefinition(
                $"""
                UPDATE {table} SET ToRevision = FromRevision, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE {of} AND FromRevision = @r AND ToRevision IS NULL;
                UPDATE {table} SET ToRevision = NULL, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE {of} AND ToRevision = @r AND FromRevision < @r;
                """, new { f = facility, r = revision }, tx, cancellationToken: ct));
        }
    }

    /// <summary>The users who opened, edited or submitted the revision (BR-FAC-004).</summary>
    private static async Task<bool> TookPartAsync(BoundUser u, SqlTransaction tx, RevisionRow rev, CancellationToken ct) =>
        rev.SubmittedBy == u.UserId || await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT COUNT(*) FROM aud.AuditLog AS a JOIN sec.AppUser AS x ON x.PublicId = a.ActorId
             WHERE a.EntityType = 'fac.FacilityRevision' AND a.EntityId = @r AND a.Action IN ('FAC_REVISION_OPENED', 'FAC_REVISION_EDITED') AND x.AppUserId = @u;
            """, new { r = rev.FacilityRevisionId, u = u.UserId }, tx, cancellationToken: ct)) > 0;

    internal static async Task<bool> SamePersonAllowedAsync(BoundUser u, SqlTransaction tx, CancellationToken ct) =>
        await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition(
            "SELECT ISNULL(t.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key] WHERE d.[Key] = 'wf.sod.allow_same_person';",
            transaction: tx, cancellationToken: ct)) == "true";

    private static async Task<object> ApproveAsync(BoundUser u, SqlTransaction tx, FacilityEndpoints.FacilityRow f, RevisionRow rev, RevisionActionRequest b, TimeProvider clock,
        CancellationToken ct)
    {
        if (rev.Status != "SUBMITTED") throw new ApiProblemException(409, "REVISION_NOT_SUBMITTED", "The revision is not waiting for approval.");
        if (await TookPartAsync(u, tx, rev, ct) && !await SamePersonAllowedAsync(u, tx, ct))
            throw ApiProblemException.Forbidden("V-FAC-SOD", "The approver of a revision did not open, edit or submit it (BR-FAC-004).");
        var check = await CheckAsync(u, tx, f, rev, ct);
        if (check.Errors.Count > 0) throw ApiProblemException.Invalid("V-FAC-INTEGRITY", string.Join(" ", check.Errors.Select(e => $"{e.Code}: {e.Message}")));
        var acknowledged = (b.Acknowledge ?? []).ToHashSet(StringComparer.Ordinal);
        var open = check.Warnings.Where(w => !acknowledged.Contains(w.Code)).Select(w => w.Code).Distinct().ToList();
        if (open.Count > 0) throw ApiProblemException.Invalid("V-FAC-ACK", "Acknowledge the warnings of the revision first: " + string.Join(", ", open) + ".");

        // (0) The active utilisations and reservations follow their limits and lines into this revision (S2 brief 0.1 item 6).
        await FacilityTreeStore.RelinkAsync(u.Connection, tx, f.FacilityId, rev.RevisionNo, ct);
        // (0b) The comparable terms of the revision, projected from its typed fields (DQ-F13-6), before the approved number moves.
        var header = rev.Header(f);
        var projected = await TermStore.ProjectAsync(u.Connection, tx, f.FacilityId, rev.RevisionNo, header.Effective, header.Expiry, header.TotalAmount, f.CurrencyId, ct);
        // (1) The revision is APPROVED, with what the approver saw and acknowledged (DQ-F13-3).
        await SetAsync(u, tx, rev, "APPROVED", "ApprovedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ApprovedOn = SYSUTCDATETIME(), IntegrityResult = @json",
            new { json = JsonSerializer.Serialize(new { errors = Array.Empty<object>(), warnings = check.Warnings.Select(w => new { code = w.Code, message = w.Message }), acknowledged }) }, ct);
        // (2) Last, in one statement: the approved revision number, the lifecycle and the header (S2-GAP-2 step 6).
        var status = f.LifecycleStatus switch
        {
            "DRAFT" => "ACTIVE",
            "EXPIRED" when rev.ReasonKind == "EXTENSION" => "ACTIVE",
            var s => s,
        };
        await FacilityEndpoints.WriteHeaderAsync(u, tx, f.FacilityId, rev.Header(f), ct,
            ", ApprovedRevisionNo = @rev, LifecycleStatus = @status, LifecycleReason = CASE WHEN @status = 'ACTIVE' THEN NULL ELSE LifecycleReason END",
            new { rev = rev.RevisionNo, status });
        // (3) The agenda of the approved rules, up to the horizon (DQ-F13-5, OQ-7); only future scheduled items change (FR-OBL-003).
        var agenda = await ObligationStore.GenerateAsync(u.Connection, tx, f.FacilityId, rev.RevisionNo, clock.GetUtcNow().UtcDateTime.Date, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FAC_REVISION_APPROVED", "TREASURY", "fac.FacilityRevision", rev.FacilityRevisionId,
            AfterJson: JsonSerializer.Serialize(new { facility = f.PublicId, revisionNo = rev.RevisionNo, reasonKind = rev.ReasonKind, status, acknowledged })), f.BorrowerCompanyId, ct);
        if (projected > 0) await Outbox.EmitAsync(u.Connection, tx, "term.value.changed", "fac.Facility", f.FacilityId, new { facility = f.PublicId, revisionNo = rev.RevisionNo }, ct);
        await Outbox.EmitAsync(u.Connection, tx, "facility.revision.approved", "fac.Facility", f.FacilityId,
            new { facility = f.PublicId, revisionNo = rev.RevisionNo, reasonKind = rev.ReasonKind }, ct);
        if (status != f.LifecycleStatus)
            await Outbox.EmitAsync(u.Connection, tx, "facility.validity.changed", "fac.Facility", f.FacilityId, new { facility = f.PublicId, status }, ct);
        await StateAsync(u, tx, f, rev, "APPROVED", null, null, ct);
        // A renewal approved on or after its start replaces its predecessor now (OQ-15).
        var superseded = await FacilityValidity.SupersedeDueAsync(u.Connection, tx, clock.GetUtcNow().UtcDateTime.Date, f.FacilityId, ct);
        return new { revisionNo = rev.RevisionNo, status, superseded, agenda };
    }

    private static readonly Dictionary<string, (string Ar, string En)> StateLabels = new(StringComparer.Ordinal)
    {
        ["SUBMITTED"] = ("بانتظار الاعتماد", "waiting for approval"),
        ["APPROVED"] = ("اعتُمدت", "approved"),
        ["REJECTED"] = ("رُفضت", "rejected"),
    };

    /// <summary>FAC.REVISION_STATE to the event's roles within the borrower's scope; the names of the borrower and of the lead bank only, never an amount.</summary>
    private static async Task StateAsync(BoundUser u, SqlTransaction tx, FacilityEndpoints.FacilityRow f, RevisionRow rev, string state, string? auditAction, string? reason,
        CancellationToken ct)
    {
        if (auditAction is not null)
            await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(auditAction, "TREASURY", "fac.FacilityRevision", rev.FacilityRevisionId,
                AfterJson: reason is null ? null : JsonSerializer.Serialize(new { reason })), f.BorrowerCompanyId, ct);
        var lenders = (await FacilityEndpoints.LendersAtAsync(u, tx, [(f.FacilityId, int.MaxValue)], ct)).GetValueOrDefault(f.FacilityId, []);
        var lead = lenders.FirstOrDefault(l => l.Roles.Split(',').Any(r => r is "SOLE" or "LEAD" or "AGENT")) ?? lenders.FirstOrDefault();
        var label = StateLabels[state];
        await Notifier.RequestAsync(u.Connection, tx, new NotificationRequest("FAC.REVISION_STATE", "fac.Facility", f.FacilityId,
            $"FAC.REVISION_STATE:{rev.FacilityRevisionId}:{state}:{DateTime.UtcNow:yyyyMMddHHmmss}", f.BorrowerCompanyId, new Dictionary<string, object?>
            {
                ["facilityNo"] = f.FacilityNo, ["revisionNo"] = rev.RevisionNo,
                ["companyName"] = new Dictionary<string, string?> { ["ar"] = f.BorrowerNameAr ?? f.BorrowerNameEn, ["en"] = f.BorrowerNameEn ?? f.BorrowerNameAr },
                ["bankName"] = new Dictionary<string, string?> { ["ar"] = lead?.NameAr ?? lead?.NameEn ?? "", ["en"] = lead?.NameEn ?? lead?.NameAr ?? "" },
                ["stateLabel"] = new Dictionary<string, string> { ["ar"] = label.Ar, ["en"] = label.En },
            }, $"/facilities/{f.PublicId}", u.UserId), ct);
    }
}

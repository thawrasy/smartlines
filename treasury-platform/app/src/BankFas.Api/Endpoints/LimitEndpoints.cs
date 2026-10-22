using System.Data;
using System.Globalization;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Facilities;
using BankFas.Data;
using BankFas.Data.Facilities;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record SourceStamp(Guid? SourceDocument, string? SourcePage, bool? ReadFromScan, string? OriginalText, string? NoSourceReason);
public sealed record LimitRequest(string? Code, string? LimitType, string? Parent, string? NameAr, string? NameEn, string? BankStructureNo, string? AmountBasis, decimal? Amount,
    decimal? PctOfParent, string? DistributionMode, bool? IsRevolving, bool? IsCommitted, string? StartDate, string? EndDate, string? DueDate, string? CompanyAllocationMode,
    Guid? SourceDocument, string? SourcePage, bool? ReadFromScan, string? OriginalText, string? NoSourceReason);
public sealed record LineRequest(string? Product, string? BankProductCode, string? AmountBasis, decimal? Amount, decimal? PctOfParent, bool? IsRevolving, string? DueDate,
    bool? IsActive, Guid? SourceDocument, string? SourcePage, bool? ReadFromScan, string? OriginalText, string? NoSourceReason);
public sealed record CompanyRuleRequest(Guid? Company, string? RuleKind, decimal? AllocationAmount, decimal? AllocationPct, string? Reason, string? ValidFrom, string? ValidTo,
    Guid? SourceDocument, string? SourcePage, string? NoSourceReason);
public sealed record TermRequest(int? MaxTotalTenorDays, int? MaxDeferralDays, int? MaxPostDeferralFinancingDays, int? LcValidityDays, decimal? CashCoverPct,
    decimal? FinancingRatioPct, int? AdvanceNoticeDays, string? AdvanceNoticeUnit, string? CheckMode, string? EffectiveFrom, Guid? SourceDocument, string? SourcePage,
    string? NoSourceReason);
public sealed record UtilizationRequest(string? Limit, string? Line, Guid? Company, string? Reference, string? Description, decimal? Amount, string? Currency,
    decimal? RateToFacilityCcy, string? StartDate, string? MaturityDate, decimal? Delta, string? Reason);
public sealed record SnapshotRequest(string? Limit, string? Product, string? AsOfDate, decimal? AcknowledgedAmount, string? Currency, string? SourceKind, decimal? StatedPct,
    Guid? SourceDocument, string? SourcePage, bool? ReadFromScan, string? NoSourceReason);

/// <summary>
/// The limit tree of a facility, its product lines, company rules and operational terms, written in the facility's
/// draft revision (FR-FAC-010 to 014; BR-FAC-009 to 012; V-FAC-04 to 10), the one availability service (SVC-FAC-03,
/// FR-FAC-019, BR-FAC-013 and 014), the manual utilisations (FR-FAC-016) and the recognised balances (FR-FAC-009,
/// BR-FAC-017). Limits, lines, rules and terms are addressed by their roots, which they keep across revisions. Every
/// value read from a document carries its source, or the reason it has none (BR-FAC-018).
/// </summary>
public static class LimitEndpoints
{
    private const string UtilManage = "fac.util.manage";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/facilities/{id:guid}/limits", TreeAsync);
        api.MapPost("/facilities/{id:guid}/limits", AddLimitAsync);
        api.MapPatch("/facilities/{id:guid}/limits/{reference}", ChangeLimitAsync);
        api.MapDelete("/facilities/{id:guid}/limits/{reference}", RemoveLimitAsync);
        api.MapPost("/facilities/{id:guid}/limits/{reference}/lines", AddLineAsync);
        api.MapPatch("/facilities/{id:guid}/lines/{reference}", ChangeLineAsync);
        api.MapDelete("/facilities/{id:guid}/lines/{reference}", RemoveLineAsync);
        api.MapPost("/facilities/{id:guid}/limits/{reference}/company-rules", AddRuleAsync);
        api.MapDelete("/facilities/{id:guid}/company-rules/{reference}", RemoveRuleAsync);
        api.MapPost("/facilities/{id:guid}/lines/{reference}/terms", AddTermAsync);
        api.MapDelete("/facilities/{id:guid}/terms/{reference}", RemoveTermAsync);
        api.MapGet("/facilities/{id:guid}/availability", AvailabilityAsync);
        api.MapGet("/facilities/{id:guid}/utilizations", UtilizationsAsync);
        api.MapPost("/facilities/{id:guid}/utilizations", AddUtilizationAsync);
        api.MapPost("/facilities/{id:guid}/utilizations/{uid:guid}/actions/adjust", (Guid id, Guid uid, UtilizationRequest b, HttpContext h, SqlConnectionFactory d, TimeProvider c) =>
            ChangeUtilizationAsync(id, uid, b, false, h, d, c));
        api.MapPost("/facilities/{id:guid}/utilizations/{uid:guid}/actions/release", (Guid id, Guid uid, UtilizationRequest b, HttpContext h, SqlConnectionFactory d, TimeProvider c) =>
            ChangeUtilizationAsync(id, uid, b, true, h, d, c));
        api.MapGet("/facilities/{id:guid}/snapshots", SnapshotsAsync);
        api.MapPost("/facilities/{id:guid}/snapshots", AddSnapshotAsync);
    }

    private static string? D(DateTime? d) => FacilityEndpoints.D(d);

    private static DateTime? Date(string? text, string label) => FacilityEndpoints.DatePair(text, null, label).Date is { } s
        ? DateTime.ParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture) : null;

    /// <summary>BR-FAC-018: a value from a document names it and its page; a value without one gives the reason.</summary>
    private static async Task<(long? Doc, string? Page, bool Scan, string? Original, string? Reason, string Confidence)> SourceAsync(BoundUser u, SqlTransaction tx,
        FacilityEndpoints.FacilityRow f, Guid? document, string? page, bool? scan, string? original, string? reason, CancellationToken ct)
    {
        if (document is null)
        {
            if (string.IsNullOrWhiteSpace(reason))
                throw ApiProblemException.Invalid("V-FAC-SOURCE", "Name the document and its page the value comes from, or give the reason it has none (BR-FAC-018).");
            return (null, null, false, original?.Trim(), reason.Trim(), "ENTERED_NO_DOCUMENT");
        }
        if (string.IsNullOrWhiteSpace(page)) throw ApiProblemException.Invalid("V-FAC-SOURCE", "A value from a document names its page.");
        var doc = await GovernanceEndpoints.DocumentAsync(u, tx, document, f.BorrowerCompanyId, ct);
        return (doc, page.Trim(), scan ?? false, original?.Trim(), reason?.Trim() is { Length: > 0 } r ? r : null, scan == true ? "READ_FROM_SCAN_UNVERIFIED" : "ENTERED_NO_DOCUMENT");
    }

    private sealed record Draft(FacilityEndpoints.FacilityRow F, FacilityRevisionEndpoints.RevisionRow Rev, TreeRows Rows, decimal Total);

    /// <summary>The facility locked, its draft revision, and the tree copied into the draft (the first change copies it).</summary>
    private static async Task<Draft> DraftAsync(BoundUser u, SqlTransaction tx, Guid id, CompanyScope scope, CancellationToken ct)
    {
        var f = await FacilityEndpoints.FindAsync(u, tx, id, scope, ct, lockRow: true);
        var rev = await FacilityRevisionEndpoints.DraftAsync(u, tx, f, ct);
        await FacilityTreeStore.CopyIntoDraftAsync(u.Connection, tx, f.FacilityId, rev.RevisionNo, ct);
        return new Draft(f, rev, await FacilityTreeStore.LoadAsync(u.Connection, tx, f.FacilityId, int.MaxValue, ct), rev.Header(f).TotalAmount);
    }

    private static async Task DoneAsync(BoundUser u, SqlTransaction tx, Draft d, string what, object detail, CancellationToken ct)
    {
        await FacilityTreeStore.WriteCapsAsync(u.Connection, tx, d.F.FacilityId, d.Total, ct);
        await FacilityRevisionEndpoints.EditedAsync(u, tx, d.F, d.Rev, what, JsonSerializer.Serialize(detail), ct);
    }

    // ---------- the tree ----------

    private static object LimitShape(LimitRow l, LimitTree tree, int tenant, OpaqueRefs refs) => new
    {
        id = refs.ItemRef(tenant, "limit", l.RootId), parent = l.ParentRootId is { } p ? refs.ItemRef(tenant, "limit", p) : null, code = l.Code, type = l.LimitTypeCode,
        kind = l.Kind, nameAr = l.NameAr, nameEn = l.NameEn, bankStructureNo = l.BankStructureNo, amountBasis = l.AmountBasis, amount = l.Amount, pctOfParent = l.PctOfParent,
        cap = tree.Cap(l.RootId), distributionMode = l.DistributionMode, isRevolving = l.IsRevolving, isCommitted = l.IsCommitted, startDate = D(l.StartDate),
        endDate = D(l.EndDate), dueDate = D(l.DueDate), companyAllocationMode = l.CompanyAllocationMode, depth = tree.Depth(l.RootId), fromRevision = l.FromRevision,
        source = new { document = l.SourceDocumentId is not null, page = l.SourcePage, readFromScan = l.ReadFromScan, noSourceReason = l.NoSourceReason, confidence = l.Confidence },
    };

    /// <summary>
    /// SCR-FAC-03: the tree of the approved revision (or the draft with view=draft), with caps, lines, rules and terms;
    /// the approved view adds the use and the availability of every node and line (R-FAC-03), the draft view its checks.
    /// </summary>
    private static async Task<IResult> TreeAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        Query.Allow(http.Request, "view");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, ct);
        var draft = http.Request.Query["view"] == "draft";
        var revisions = draft ? await FacilityRevisionEndpoints.RevisionsAsync(u, null, f.FacilityId, ct) : [];
        var open = revisions.FirstOrDefault(r => r.Status is "DRAFT" or "SUBMITTED" or "REJECTED");
        if (draft && open is null) throw new ApiProblemException(409, "V-FAC-NO-DRAFT", "The facility has no open revision.");
        var rev = draft ? int.MaxValue : f.ApprovedRevisionNo;
        var total = draft ? open!.Header(f).TotalAmount : f.TotalAmount;
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var rows = await FacilityTreeStore.LoadAsync(u.Connection, null, f.FacilityId, rev, ct);
        var tree = rows.Tree(total, today);
        var exposures = draft ? [] : await FacilityTreeStore.ExposuresAsync(u.Connection, null, f.FacilityId, ct);
        var permissions = await u.PermissionsAsync(ct);
        var showAmounts = scope.Allows(f.BorrowerCompanyId);
        object? Use(long limit, long? line)
        {
            if (draft) return null;
            var a = tree.Available(limit, line, null, exposures);
            return new { used = a.Used, reserved = a.ReservedForOthers, avail = a.Avail, bindingNode = a.BindingNode };
        }
        var (inside, outside) = tree.Totals();
        return Results.Ok(new
        {
            view = draft ? "draft" : "approved", revisionNo = draft ? open!.RevisionNo : f.ApprovedRevisionNo, currency = f.CurrencyCode, total = inside, outsideTotal = outside,
            limits = rows.Limits.Select(l => new
            {
                limit = LimitShape(l, tree, u.TenantId, refs), use = showAmounts ? Use(l.RootId, null) : null,
                lines = rows.Lines.Where(x => x.LimitRootId == l.RootId).Select(x => new
                {
                    id = refs.ItemRef(u.TenantId, "line", x.RootId), product = x.ProductCode, productNameAr = x.ProductNameAr, productNameEn = x.ProductNameEn,
                    bankProductCode = x.BankProductCode, amountBasis = x.AmountBasis, amount = x.Amount, pctOfParent = x.PctOfParent,
                    cap = tree.LineCap(new ProductLine(x.RootId, x.LimitRootId, x.ProductId, x.BankProductCode, x.AmountBasis, x.Amount, x.PctOfParent)),
                    isRevolving = x.IsRevolving, dueDate = D(x.DueDate), isActive = x.IsActive, consumesCreditLimit = x.ConsumesCreditLimit,
                    use = showAmounts && x.IsActive ? Use(l.RootId, x.RootId) : null,
                    terms = rows.Terms.Where(t => t.LineRootId == x.RootId).Select(t => new
                    {
                        id = refs.ItemRef(u.TenantId, "line-term", t.RootId), t.MaxTotalTenorDays, t.MaxDeferralDays, t.MaxPostDeferralFinancingDays, t.LcValidityDays,
                        t.CashCoverPct, t.FinancingRatioPct, t.AdvanceNoticeDays, t.AdvanceNoticeUnit, t.CheckMode, effectiveFrom = D(t.EffectiveFrom), effectiveTo = D(t.EffectiveTo),
                    }),
                }),
                companyRules = rows.Rules.Where(r => r.LimitRootId == l.RootId).Select(r => new
                {
                    id = refs.ItemRef(u.TenantId, "company-rule", r.RootId), company = new { id = r.CompanyPublicId, nameAr = r.CompanyNameAr, nameEn = r.CompanyNameEn },
                    kind = r.RuleKind, allocationAmount = r.AllocationAmount, allocationPct = r.AllocationPct, reason = r.Reason, validFrom = D(r.ValidFrom), validTo = D(r.ValidTo),
                }),
            }),
            checks = draft ? CheckTree(rows, tree).Select(x => new { code = x.Code, severity = x.Severity, message = x.Message }) : null,
            canEdit = permissions.Contains(FacilityEndpoints.Edit) && open?.Status == "DRAFT",
        });
    }

    /// <summary>The checks of the tree of a revision (V-FAC-04 to 10), for the submit and the approval.</summary>
    internal static List<Finding> CheckTree(TreeRows rows, LimitTree tree)
    {
        var kinds = rows.Limits.ToDictionary(l => l.RootId, l => l.Kind);
        var findings = tree.Check(r => kinds.GetValueOrDefault(r));
        foreach (var t in rows.Terms)
            if (t.MaxTotalTenorDays is { } total && t.MaxDeferralDays is { } deferral && total < deferral)
                findings.Add(new("V-FAC-10", "W", "A line's total tenor is shorter than its deferral."));
        return findings;
    }

    // ---------- limits ----------

    private static async Task<(int TypeId, string Kind, string? Mode, bool? Revolving)> LimitTypeAsync(BoundUser u, SqlTransaction tx, string code, CancellationToken ct) =>
        await u.Connection.QuerySingleOrDefaultAsync<(int, string, string?, bool?)?>(new CommandDefinition(
            "SELECT LimitTypeId, Kind, DefaultDistributionMode, DefaultIsRevolving FROM cat.LimitType WHERE Code = @c AND IsActive = 1;",
            new { c = code.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The limit type is not an active type of the catalogue.");

    private static (string Basis, decimal? Amount, decimal? Pct) Basis(string? basis, decimal? amount, decimal? pct, bool lineMayHaveNone)
    {
        var b = basis?.Trim().ToUpperInvariant() ?? (pct is not null ? "PCT_OF_PARENT" : amount is not null ? "ABSOLUTE" : lineMayHaveNone ? "" : "ABSOLUTE");
        return b switch
        {
            "" => ("", null, null),
            "ABSOLUTE" when amount is >= 0 => (b, amount, null),
            "PCT_OF_PARENT" when pct is > 0 and <= 100 => (b, null, pct),
            _ => throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give an amount from zero, or a percent of the parent above 0 and up to 100."),
        };
    }

    private static string Mode(string? mode, string? fallback)
    {
        var m = mode?.Trim().ToUpperInvariant() ?? fallback ?? "SHARED_CAP";
        return m is "SHARED_CAP" or "PARTITION" or "OUTSIDE_TOTAL" ? m : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The distribution is SHARED_CAP, PARTITION or OUTSIDE_TOTAL.");
    }

    private static LimitRow Find(Draft d, OpaqueRefs refs, int tenant, string reference) =>
        d.Rows.Limits.FirstOrDefault(l => l.RootId == refs.ItemId(tenant, "limit", reference)) ?? throw ApiProblemException.NotFound();

    private static async Task<IResult> AddLimitAsync(Guid id, LimitRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        if (string.IsNullOrWhiteSpace(b.Code) || string.IsNullOrWhiteSpace(b.LimitType) || string.IsNullOrWhiteSpace(b.NameAr))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the code, the type and the Arabic name of the limit.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await DraftAsync(u, tx, id, scope, ct);
        var code = b.Code.Trim().ToUpperInvariant();
        if (d.Rows.Limits.Any(l => l.Code == code)) throw new ApiProblemException(409, "V-FAC-LIMIT-CODE", "Another limit of the facility has this code.");
        var type = await LimitTypeAsync(u, tx, b.LimitType, ct);
        var parent = b.Parent is null ? null : Find(d, refs, u.TenantId, b.Parent);
        var (basis, amount, pct) = Basis(b.AmountBasis, b.Amount, b.PctOfParent, false);
        var src = await SourceAsync(u, tx, d.F, b.SourceDocument, b.SourcePage, b.ReadFromScan, b.OriginalText, b.NoSourceReason, ct);
        var start = Date(b.StartDate, "start date");
        var end = Date(b.EndDate, "end date");
        if (start is not null && end is not null && end < start) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The limit ends on or after its start.");
        var root = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (RootId BIGINT);
            INSERT fac.Limit (TenantId, FacilityId, ParentLimitId, LimitTypeId, Code, NameAr, NameEn, BankStructureNo, AmountBasis, Amount, PctOfParent, DistributionMode,
                              IsRevolving, IsCommitted, StartDate, EndDate, DueDate, CompanyAllocationMode, FromRevision, SourceDocumentId, SourcePage, ReadFromScan,
                              OriginalText, NoSourceReason, Confidence, CreatedBy)
            OUTPUT inserted.RootId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @parent, @type, @code, @ar, @en, @bsn, @basis, @amount, @pct, @mode, @rev, @committed, @start, @end, @due,
                    @alloc, @r, @doc, @page, @scan, @orig, @reason, @conf, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT RootId FROM @o;
            """, new
            {
                f = d.F.FacilityId, parent = parent?.LimitId, type = type.TypeId, code, ar = b.NameAr.Trim(), en = b.NameEn?.Trim(), bsn = b.BankStructureNo?.Trim(), basis, amount,
                pct, mode = Mode(b.DistributionMode, type.Mode), rev = b.IsRevolving ?? type.Revolving ?? true, committed = b.IsCommitted, start, end, due = Date(b.DueDate, "due date"),
                alloc = (b.CompanyAllocationMode ?? "NONE").ToUpperInvariant(), r = d.Rev.RevisionNo, doc = src.Doc, page = src.Page, scan = src.Scan, orig = src.Original,
                reason = src.Reason, conf = src.Confidence,
            }, tx, cancellationToken: ct));
        await DoneAsync(u, tx, d, "LIMIT_ADDED", new { code, type = b.LimitType, basis, amount, pct }, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/limits", new { id = refs.ItemRef(u.TenantId, "limit", root) });
    }

    private static async Task<IResult> ChangeLimitAsync(Guid id, string reference, LimitRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await DraftAsync(u, tx, id, scope, ct);
        var l = Find(d, refs, u.TenantId, reference);
        if (b.Code is not null && !string.Equals(b.Code.Trim(), l.Code, StringComparison.OrdinalIgnoreCase))
        {
            // The code is the key a renewal transfers by (BR-FAC-006): an approved limit keeps it.
            if (l.RootId != l.LimitId || l.FromRevision < d.Rev.RevisionNo) throw ApiProblemException.Invalid("V-FAC-LIMIT-CODE", "The code of an approved limit does not change.");
            if (d.Rows.Limits.Any(x => string.Equals(x.Code, b.Code.Trim(), StringComparison.OrdinalIgnoreCase))) throw new ApiProblemException(409, "V-FAC-LIMIT-CODE", "Another limit of the facility has this code.");
        }
        if (b.LimitType is not null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The type of a limit does not change; remove it and add another.");
        long? parent = l.ParentLimitId;
        if (b.Parent is not null) parent = b.Parent.Length == 0 ? null : Find(d, refs, u.TenantId, b.Parent).LimitId;
        var (basis, amount, pct) = b.AmountBasis is null && b.Amount is null && b.PctOfParent is null
            ? (l.AmountBasis, l.Amount, l.PctOfParent) : Basis(b.AmountBasis, b.Amount, b.PctOfParent, false);
        var stamped = b.SourceDocument is not null || b.NoSourceReason is not null;
        var src = stamped ? await SourceAsync(u, tx, d.F, b.SourceDocument, b.SourcePage, b.ReadFromScan, b.OriginalText, b.NoSourceReason, ct) : default;
        await u.Connection.ExecuteAsync(new CommandDefinition(
            $"""
            UPDATE fac.Limit SET Code = @code, ParentLimitId = @parent, NameAr = @ar, NameEn = @en, BankStructureNo = @bsn, AmountBasis = @basis, Amount = @amount,
                   PctOfParent = @pct, DistributionMode = @mode, IsRevolving = @rev, IsCommitted = @committed, StartDate = @start, EndDate = @end, DueDate = @due,
                   CompanyAllocationMode = @alloc{(stamped ? ", SourceDocumentId = @doc, SourcePage = @page, ReadFromScan = @scan, OriginalText = @orig, NoSourceReason = @reason, Confidence = @conf" : "")},
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE LimitId = @id;
            """, new
            {
                id = l.LimitId, code = b.Code?.Trim().ToUpperInvariant() ?? l.Code, parent, ar = b.NameAr?.Trim() ?? l.NameAr, en = b.NameEn ?? l.NameEn,
                bsn = b.BankStructureNo ?? l.BankStructureNo, basis, amount, pct, mode = Mode(b.DistributionMode, l.DistributionMode), rev = b.IsRevolving ?? l.IsRevolving,
                committed = b.IsCommitted ?? l.IsCommitted, start = b.StartDate is null ? l.StartDate : Date(b.StartDate, "start date"),
                end = b.EndDate is null ? l.EndDate : Date(b.EndDate, "end date"), due = b.DueDate is null ? l.DueDate : Date(b.DueDate, "due date"),
                alloc = b.CompanyAllocationMode?.ToUpperInvariant() ?? l.CompanyAllocationMode, doc = src.Doc, page = src.Page, scan = src.Scan, orig = src.Original,
                reason = src.Reason, conf = src.Confidence,
            }, tx, cancellationToken: ct));
        await DoneAsync(u, tx, d, "LIMIT_CHANGED", new { code = l.Code, before = new { l.AmountBasis, l.Amount, l.PctOfParent, l.DistributionMode }, after = new { basis, amount, pct } }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> RemoveLimitAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await DraftAsync(u, tx, id, scope, ct);
        var l = Find(d, refs, u.TenantId, reference);
        if (d.Rows.Limits.Any(x => x.ParentRootId == l.RootId) || d.Rows.Lines.Any(x => x.LimitRootId == l.RootId) || d.Rows.Rules.Any(x => x.LimitRootId == l.RootId))
            throw new ApiProblemException(409, "V-FAC-LIMIT-CHILDREN", "Remove the sub-limits, lines and company rules of this limit first.");
        await DeleteDraftRowAsync(u, tx, "fac.Limit", "LimitId", l.LimitId, ct);
        await DoneAsync(u, tx, d, "LIMIT_REMOVED", new { code = l.Code }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>
    /// The draft holds a copy of every open row, so a removal voids the draft's row (ToRevision = FromRevision: valid at no
    /// revision; tp_app deletes nothing here, 005); the approved row it copied stays closed at the draft.
    /// </summary>
    private static Task<int> DeleteDraftRowAsync(BoundUser u, SqlTransaction tx, string table, string pk, long id, CancellationToken ct) =>
        u.Connection.ExecuteAsync(new CommandDefinition(
            $"UPDATE {table} SET ToRevision = FromRevision, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE {pk} = @id;",
            new { id }, tx, cancellationToken: ct));

    // ---------- lines ----------

    private static async Task<IResult> AddLineAsync(Guid id, string reference, LineRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        if (string.IsNullOrWhiteSpace(b.Product)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the product of the line.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await DraftAsync(u, tx, id, scope, ct);
        var l = Find(d, refs, u.TenantId, reference);
        var product = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT ProductId FROM cat.Product WHERE Code = @c AND IsActive = 1;",
            new { c = b.Product.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The product is not an active product of the catalogue.");
        var bankCode = b.BankProductCode?.Trim() is { Length: > 0 } bc ? bc : null;
        if (d.Rows.Lines.Any(x => x.LimitRootId == l.RootId && x.ProductId == product && x.BankProductCode == bankCode))
            throw new ApiProblemException(409, "V-FAC-LINE-EXISTS", "The limit already has a line for this product and bank code.");
        var (basis, amount, pct) = Basis(b.AmountBasis, b.Amount, b.PctOfParent, true);
        var src = await SourceAsync(u, tx, d.F, b.SourceDocument, b.SourcePage, b.ReadFromScan, b.OriginalText, b.NoSourceReason, ct);
        var root = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (RootId BIGINT);
            INSERT fac.LimitProductLine (TenantId, FacilityId, LimitId, ProductId, BankProductCode, AmountBasis, Amount, PctOfParent, IsRevolving, DueDate, IsActive, FromRevision,
                                         SourceDocumentId, SourcePage, ReadFromScan, OriginalText, NoSourceReason, Confidence, CreatedBy)
            OUTPUT inserted.RootId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @l, @p, @bc, @basis, @amount, @pct, @rev, @due, @active, @r, @doc, @page, @scan, @orig, @reason, @conf,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT RootId FROM @o;
            """, new
            {
                f = d.F.FacilityId, l = l.LimitId, p = product, bc = bankCode, basis = basis.Length == 0 ? null : basis, amount, pct, rev = b.IsRevolving, due = Date(b.DueDate, "due date"),
                active = b.IsActive ?? true, r = d.Rev.RevisionNo, doc = src.Doc, page = src.Page, scan = src.Scan, orig = src.Original, reason = src.Reason, conf = src.Confidence,
            }, tx, cancellationToken: ct));
        await DoneAsync(u, tx, d, "LINE_ADDED", new { limit = l.Code, product = b.Product, bankCode, amount, pct }, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/limits", new { id = refs.ItemRef(u.TenantId, "line", root) });
    }

    private static LineRow FindLine(Draft d, OpaqueRefs refs, int tenant, string reference) =>
        d.Rows.Lines.FirstOrDefault(l => l.RootId == refs.ItemId(tenant, "line", reference)) ?? throw ApiProblemException.NotFound();

    private static async Task<IResult> ChangeLineAsync(Guid id, string reference, LineRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Product is not null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The product of a line does not change; remove it and add another.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await DraftAsync(u, tx, id, scope, ct);
        var x = FindLine(d, refs, u.TenantId, reference);
        var (basis, amount, pct) = b.AmountBasis is null && b.Amount is null && b.PctOfParent is null ? (x.AmountBasis ?? "", x.Amount, x.PctOfParent) : Basis(b.AmountBasis, b.Amount, b.PctOfParent, true);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fac.LimitProductLine SET BankProductCode = @bc, AmountBasis = @basis, Amount = @amount, PctOfParent = @pct, IsRevolving = @rev, DueDate = @due, IsActive = @active,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE LimitProductLineId = @id;
            """, new
            {
                id = x.LimitProductLineId, bc = b.BankProductCode ?? x.BankProductCode, basis = basis.Length == 0 ? null : basis, amount, pct, rev = b.IsRevolving ?? x.IsRevolving,
                due = b.DueDate is null ? x.DueDate : Date(b.DueDate, "due date"), active = b.IsActive ?? x.IsActive,
            }, tx, cancellationToken: ct));
        await DoneAsync(u, tx, d, "LINE_CHANGED", new { product = x.ProductCode, before = new { x.Amount, x.PctOfParent }, after = new { amount, pct } }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> RemoveLineAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await DraftAsync(u, tx, id, scope, ct);
        var x = FindLine(d, refs, u.TenantId, reference);
        foreach (var t in d.Rows.Terms.Where(t => t.LineRootId == x.RootId)) await DeleteDraftRowAsync(u, tx, "fac.ProductLineTerm", "ProductLineTermId", t.ProductLineTermId, ct);
        await DeleteDraftRowAsync(u, tx, "fac.LimitProductLine", "LimitProductLineId", x.LimitProductLineId, ct);
        await DoneAsync(u, tx, d, "LINE_REMOVED", new { product = x.ProductCode, bankCode = x.BankProductCode }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- company rules (BR-FAC-012) and terms ----------

    private static async Task<IResult> AddRuleAsync(Guid id, string reference, CompanyRuleRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var kind = b.RuleKind?.Trim().ToUpperInvariant();
        if (b.Company is null || kind is not ("ALLOWED" or "EXCLUDED" or "ALLOCATION")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the company and the rule: ALLOWED, EXCLUDED or ALLOCATION.");
        if (kind == "ALLOCATION" && (b.AllocationAmount is null) == (b.AllocationPct is null)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "An allocation is an amount or a percent.");
        if (kind != "ALLOCATION" && (b.AllocationAmount is not null || b.AllocationPct is not null)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Only an allocation has an amount.");
        if (b.AllocationAmount is <= 0 || b.AllocationPct is <= 0 or > 100) throw ApiProblemException.Invalid("VALIDATION_FAILED", "An allocation is above zero, and a percent at most 100.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await DraftAsync(u, tx, id, scope, ct);
        var l = Find(d, refs, u.TenantId, reference);
        var company = await CompanyEndpoints.FindAsync(u, tx, b.Company.Value, scope, ct);
        var from = Date(b.ValidFrom, "start date") ?? d.Rev.Header(d.F).Effective;
        var to = Date(b.ValidTo, "end date");
        if (to < from) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The rule ends on or after its start.");
        var src = await SourceAsync(u, tx, d.F, b.SourceDocument, b.SourcePage, false, null, b.NoSourceReason, ct);
        long root;
        try
        {
            root = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (RootId BIGINT);
                INSERT fac.LimitCompanyRule (TenantId, FacilityId, LimitId, CompanyId, RuleKind, AllocationAmount, AllocationPct, Reason, ValidFrom, ValidTo, FromRevision,
                                             SourceDocumentId, SourcePage, NoSourceReason, Confidence, CreatedBy)
                OUTPUT inserted.RootId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @l, @c, @kind, @amt, @pct, @reason, @from, @to, @r, @doc, @page, @nsr, @conf, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT RootId FROM @o;
                """, new
                {
                    f = d.F.FacilityId, l = l.LimitId, c = company.CompanyId, kind, amt = b.AllocationAmount, pct = b.AllocationPct, reason = b.Reason?.Trim(), from, to,
                    r = d.Rev.RevisionNo, doc = src.Doc, page = src.Page, nsr = src.Reason, conf = src.Confidence,
                }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            throw new ApiProblemException(409, "V-FAC-RULE-EXISTS", "The limit already has this rule for the company from this date.");
        }
        await DoneAsync(u, tx, d, "COMPANY_RULE_ADDED", new { limit = l.Code, company = b.Company, kind }, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/limits", new { id = refs.ItemRef(u.TenantId, "company-rule", root) });
    }

    private static async Task<IResult> RemoveRuleAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await DraftAsync(u, tx, id, scope, ct);
        var r = d.Rows.Rules.FirstOrDefault(x => x.RootId == refs.ItemId(u.TenantId, "company-rule", reference)) ?? throw ApiProblemException.NotFound();
        await DeleteDraftRowAsync(u, tx, "fac.LimitCompanyRule", "LimitCompanyRuleId", r.LimitCompanyRuleId, ct);
        await DoneAsync(u, tx, d, "COMPANY_RULE_REMOVED", new { kind = r.RuleKind, company = r.CompanyPublicId }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>The operational terms of a line from a date (FR-FAC-014); the previous terms end the day before. NULL is "not specified", never zero.</summary>
    private static async Task<IResult> AddTermAsync(Guid id, string reference, TermRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        foreach (var days in new[] { b.MaxTotalTenorDays, b.MaxDeferralDays, b.MaxPostDeferralFinancingDays, b.LcValidityDays, b.AdvanceNoticeDays })
            if (days is < 0) throw ApiProblemException.Invalid("V-FAC-10", "A number of days is from zero.");
        if (b.CashCoverPct is < 0 or > 100 || b.FinancingRatioPct is < 0 or > 100) throw ApiProblemException.Invalid("V-FAC-10", "A percent is from 0 to 100.");
        var mode = b.CheckMode?.Trim().ToUpperInvariant() ?? "WARN";
        if (mode is not ("OFF" or "WARN" or "BLOCK")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The check is OFF, WARN or BLOCK.");
        var unit = b.AdvanceNoticeUnit?.Trim().ToUpperInvariant() ?? "BUSINESS";
        if (unit is not ("BUSINESS" or "CALENDAR")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The notice is in BUSINESS or CALENDAR days.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await DraftAsync(u, tx, id, scope, ct);
        var line = FindLine(d, refs, u.TenantId, reference);
        var from = Date(b.EffectiveFrom, "start date") ?? d.Rev.Header(d.F).Effective;
        var current = d.Rows.Terms.Where(t => t.LineRootId == line.RootId && t.EffectiveTo is null).OrderByDescending(t => t.EffectiveFrom).FirstOrDefault();
        if (current is not null)
        {
            if (current.EffectiveFrom >= from) throw new ApiProblemException(409, "V-FAC-TERM-DATE", "The new terms start after the current ones.");
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE fac.ProductLineTerm SET EffectiveTo = @to, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE ProductLineTermId = @id;",
                new { to = from.AddDays(-1), id = current.ProductLineTermId }, tx, cancellationToken: ct));
        }
        var src = await SourceAsync(u, tx, d.F, b.SourceDocument, b.SourcePage, false, null, b.NoSourceReason, ct);
        var root = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (RootId BIGINT);
            INSERT fac.ProductLineTerm (TenantId, FacilityId, LimitProductLineId, MaxTotalTenorDays, MaxDeferralDays, MaxPostDeferralFinancingDays, LcValidityDays, CashCoverPct,
                                        FinancingRatioPct, AdvanceNoticeDays, AdvanceNoticeUnit, CheckMode, EffectiveFrom, FromRevision, SourceDocumentId, SourcePage,
                                        NoSourceReason, Confidence, CreatedBy)
            OUTPUT inserted.RootId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @ln, @tenor, @deferral, @post, @validity, @cash, @ratio, @notice, @unit, @mode, @from, @r, @doc, @page, @nsr,
                    @conf, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT RootId FROM @o;
            """, new
            {
                f = d.F.FacilityId, ln = line.LimitProductLineId, tenor = b.MaxTotalTenorDays, deferral = b.MaxDeferralDays, post = b.MaxPostDeferralFinancingDays,
                validity = b.LcValidityDays, cash = b.CashCoverPct, ratio = b.FinancingRatioPct, notice = b.AdvanceNoticeDays, unit, mode, from, r = d.Rev.RevisionNo,
                doc = src.Doc, page = src.Page, nsr = src.Reason, conf = src.Confidence,
            }, tx, cancellationToken: ct));
        await DoneAsync(u, tx, d, "LINE_TERMS_ADDED", new { product = line.ProductCode, from = D(from) }, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/limits", new { id = refs.ItemRef(u.TenantId, "line-term", root) });
    }

    private static async Task<IResult> RemoveTermAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await DraftAsync(u, tx, id, scope, ct);
        var t = d.Rows.Terms.FirstOrDefault(x => x.RootId == refs.ItemId(u.TenantId, "line-term", reference)) ?? throw ApiProblemException.NotFound();
        await DeleteDraftRowAsync(u, tx, "fac.ProductLineTerm", "ProductLineTermId", t.ProductLineTermId, ct);
        await DoneAsync(u, tx, d, "LINE_TERMS_REMOVED", new { from = D(t.EffectiveFrom) }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- availability (SVC-FAC-03) ----------

    /// <summary>
    /// The availability of a limit or a line for a company on the approved revision (BR-FAC-014): Cap, Used,
    /// ReservedForOthers, Avail, the binding node and the validity indicator. A facility that is not ACTIVE, or not yet
    /// started, has none (LIMIT_NOT_ACTIVE); NOT_CONFIRMED gives the value with its indicator.
    /// </summary>
    private static async Task<IResult> AvailabilityAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        Query.Allow(http.Request, "limit", "line", "company", "date", "request");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, ct);
        var q = http.Request.Query;
        var limitRoot = refs.ItemId(u.TenantId, "limit", q["limit"]);
        var lineRoot = refs.ItemId(u.TenantId, "line", q["line"]);
        var date = Date(q["date"], "date") ?? clock.GetUtcNow().UtcDateTime.Date;
        long? company = null;
        if (Guid.TryParse(q["company"], out var cg)) company = (await CompanyEndpoints.FindAsync(u, null, cg, scope, ct)).CompanyId;
        var rows = await FacilityTreeStore.LoadAsync(u.Connection, null, f.FacilityId, f.ApprovedRevisionNo, ct);
        if (lineRoot is { } lr) limitRoot ??= rows.Lines.FirstOrDefault(l => l.RootId == lr)?.LimitRootId;
        if (limitRoot is null || rows.Limits.All(l => l.RootId != limitRoot)) throw ApiProblemException.NotFound();
        var validity = FacilityValidity.Indicator(f.LifecycleStatus, f.EffectiveFrom, f.ExpiryDate, date, await FacilityValidity.ExpiringDaysAsync(u.Connection, null, ct));
        var tree = rows.Tree(f.TotalAmount, date);
        var a = tree.Available(limitRoot.Value, lineRoot, company, await FacilityTreeStore.ExposuresAsync(u.Connection, null, f.FacilityId, ct),
            long.TryParse(q["request"], NumberStyles.None, CultureInfo.InvariantCulture, out var rq) ? rq : null);
        var reason = f.LifecycleStatus != "ACTIVE" || validity == "SCHEDULED" ? "LIMIT_NOT_ACTIVE" : a.Reason;
        return Results.Ok(new
        {
            cap = a.Cap, used = a.Used, reservedForOthers = a.ReservedForOthers, avail = reason is null ? a.Avail : 0, shown = reason is null ? Math.Max(0, a.Avail) : 0,
            bindingNode = a.BindingNode, validityIndicator = validity, reason, currency = f.CurrencyCode,
        });
    }

    // ---------- utilisations (FR-FAC-016) ----------

    private sealed class UtilRow
    {
        public long UtilizationId { get; init; }
        public Guid PublicId { get; init; }
        public long LimitRootId { get; init; }
        public string LimitCode { get; init; } = "";
        public long? LineRootId { get; init; }
        public string? ProductCode { get; init; }
        public long CompanyId { get; init; }
        public Guid CompanyPublicId { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string Reference { get; init; } = "";
        public string? Description { get; init; }
        public decimal Amount { get; init; }
        public string Currency { get; init; } = "";
        public int CurrencyId { get; init; }
        public decimal? RateToFacilityCcy { get; init; }
        public DateTime StartDate { get; init; }
        public DateTime? MaturityDate { get; init; }
        public string SourceType { get; init; } = "";
        public string Status { get; init; } = "";
        public DateTime? ReleasedOn { get; init; }
        public string? ReleaseReason { get; init; }
    }

    private const string UtilSelect =
        """
        SELECT u.UtilizationId, u.PublicId, l.RootId AS LimitRootId, l.Code AS LimitCode, ln.RootId AS LineRootId, pr.Code AS ProductCode, u.CompanyId,
               co.PublicId AS CompanyPublicId, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn, u.Reference, u.Description, u.Amount, cu.Code AS Currency, u.CurrencyId,
               u.RateToFacilityCcy, u.StartDate, u.MaturityDate, u.SourceType, u.Status, u.ReleasedOn, u.ReleaseReason
          FROM fac.Utilization AS u
          JOIN fac.Limit AS l ON l.LimitId = u.LimitId
          LEFT JOIN fac.LimitProductLine AS ln ON ln.LimitProductLineId = u.LimitProductLineId
          LEFT JOIN cat.Product AS pr ON pr.ProductId = ln.ProductId
          JOIN org.Company AS co ON co.CompanyId = u.CompanyId
          JOIN ref.Currency AS cu ON cu.CurrencyId = u.CurrencyId
        """;

    private static async Task<IResult> UtilizationsAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.View);
        await using var _ = u;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, http.RequestAborted);
        var rows = await u.Connection.QueryAsync<UtilRow>(new CommandDefinition(UtilSelect + " WHERE u.FacilityId = @f ORDER BY u.StartDate DESC, u.UtilizationId DESC;",
            new { f = f.FacilityId }, cancellationToken: http.RequestAborted));
        // Q-FAC-11: the amounts of a company outside the user's scope are hidden inside a shared facility.
        return Results.Ok(new
        {
            items = rows.Select(x => new
            {
                id = x.PublicId, limit = refs.ItemRef(u.TenantId, "limit", x.LimitRootId), limitCode = x.LimitCode,
                line = x.LineRootId is { } lr ? refs.ItemRef(u.TenantId, "line", lr) : null, product = x.ProductCode,
                company = new { id = x.CompanyPublicId, nameAr = x.CompanyNameAr, nameEn = x.CompanyNameEn }, reference = x.Reference, description = x.Description,
                amount = scope.Allows(x.CompanyId) ? x.Amount : (decimal?)null, currency = x.Currency, rateToFacilityCcy = x.RateToFacilityCcy, startDate = D(x.StartDate),
                maturityDate = D(x.MaturityDate), sourceType = x.SourceType, status = x.Status, releasedOn = D(x.ReleasedOn), releaseReason = x.ReleaseReason,
            }),
        });
    }

    internal static Task UtilMovementAsync(BoundUser u, SqlTransaction tx, long facility, long util, string op, int currency, decimal? delta, decimal? before, decimal? after,
        string? reason, CancellationToken ct) =>
        u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT fac.LimitMovement (TenantId, FacilityId, TargetKind, UtilizationId, OpKind, CurrencyId, RequestedDelta, AppliedDelta, AmountBefore, AmountAfter, Reason,
                                      IdempotencyKey, ActorUserId)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, 'UTILIZATION', @u, @op, @cur, @d, @d, @b, @a, @reason, @key, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new { f = facility, u = util, op, cur = currency, d = delta, b = before, a = after, reason, key = $"util:{util}:{op}:{Guid.NewGuid():N}" }, tx, cancellationToken: ct));

    /// <summary>
    /// A manual utilisation (FR-FAC-016; OQ-10): on an approved limit or line of an ACTIVE facility, for an eligible
    /// company, in another currency only with its fixed rate (BR-FAC-002). It is not refused for want of availability:
    /// a negative availability after it is a warning.
    /// </summary>
    private static async Task<IResult> AddUtilizationAsync(Guid id, UtilizationRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        if (b.Company is null || string.IsNullOrWhiteSpace(b.Reference) || b.Amount is not > 0 || (b.Limit is null && b.Line is null))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the limit or the line, the company, the reference and an amount above zero.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, UtilManage);
        await using var _ = u;
        var ct = http.RequestAborted;
        var today = clock.GetUtcNow().UtcDateTime.Date;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FacilityEndpoints.FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (f.LifecycleStatus is not ("ACTIVE" or "SUSPENDED")) throw new ApiProblemException(409, "LIMIT_NOT_ACTIVE", "The facility is not active.");
        var company = await CompanyEndpoints.FindAsync(u, tx, b.Company.Value, scope, ct);
        var rows = await FacilityTreeStore.LoadAsync(u.Connection, tx, f.FacilityId, f.ApprovedRevisionNo, ct);
        var lineRoot = refs.ItemId(u.TenantId, "line", b.Line);
        var line = lineRoot is null ? null : rows.Lines.FirstOrDefault(x => x.RootId == lineRoot) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The line is not a line of the approved facility.");
        var limitRoot = line?.LimitRootId ?? refs.ItemId(u.TenantId, "limit", b.Limit);
        var limit = rows.Limits.FirstOrDefault(x => x.RootId == limitRoot) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The limit is not a limit of the approved facility.");
        var tree = rows.Tree(f.TotalAmount, today);
        if (!tree.Eligible(limit.RootId, company.CompanyId)) throw ApiProblemException.Invalid("COMPANY_EXCLUDED", "The company may not use this limit (BR-FAC-012).");
        var currency = b.Currency is null ? f.CurrencyId : await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency, ct);
        if (currency != f.CurrencyId && b.RateToFacilityCcy is not > 0) throw ApiProblemException.Invalid("CURRENCY_NO_RATE", "A utilisation in another currency has its fixed rate (BR-FAC-002).");
        var start = Date(b.StartDate, "start date") ?? today;
        var maturity = Date(b.MaturityDate, "maturity date");
        if (maturity < start) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The maturity is on or after the start.");
        var amount = b.Amount.Value;
        var before = tree.Available(limit.RootId, line?.RootId, company.CompanyId, await FacilityTreeStore.ExposuresAsync(u.Connection, tx, f.FacilityId, ct));
        var (utilId, publicId) = await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT fac.Utilization (TenantId, FacilityId, LimitId, LimitProductLineId, CompanyId, Reference, Description, Amount, CurrencyId, RateToFacilityCcy, StartDate,
                                    MaturityDate, SourceType, CreatedBy)
            OUTPUT inserted.UtilizationId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @l, @ln, @c, @ref, @desc, @a, @cur, @rate, @start, @maturity, 'MANUAL', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new
            {
                f = f.FacilityId, l = limit.LimitId, ln = line?.LimitProductLineId, c = company.CompanyId, @ref = b.Reference.Trim(), desc = b.Description?.Trim(), a = amount,
                cur = currency, rate = currency == f.CurrencyId ? null : b.RateToFacilityCcy, start, maturity,
            }, tx, cancellationToken: ct));
        await UtilMovementAsync(u, tx, f.FacilityId, utilId, "CREATE", currency, amount, 0, amount, null, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("UTILIZATION_CREATED", "TREASURY", "fac.Utilization", utilId,
            AfterJson: JsonSerializer.Serialize(new { limit = limit.Code, reference = b.Reference, amount, currency = b.Currency })), company.CompanyId, ct);
        await Outbox.EmitAsync(u.Connection, tx, "utilization.created", "fac.Utilization", utilId, new { utilization = publicId }, ct);
        await tx.CommitAsync(ct);
        var inFacility = LimitTree.Round(amount * (currency == f.CurrencyId ? 1 : b.RateToFacilityCcy!.Value));
        var warnings = before.Avail - inFacility < 0 ? new[] { "V-FAC-AVAIL-NEGATIVE" } : [];
        return Results.Created($"/api/v1/facilities/{id}/utilizations", new { id = publicId, warnings });
    }

    /// <summary>An adjustment (a signed delta, the balance staying above zero) or a release, each with its reason, its movement and its audit row (FR-FAC-016).</summary>
    private static async Task<IResult> ChangeUtilizationAsync(Guid id, Guid uid, UtilizationRequest b, bool release, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        if (string.IsNullOrWhiteSpace(b.Reason) || b.Reason.Length > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason.");
        if (!release && b.Delta is null or 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the change of the amount.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, UtilManage);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FacilityEndpoints.FindAsync(u, tx, id, scope, ct, lockRow: true);
        var x = await u.Connection.QuerySingleOrDefaultAsync<UtilRow>(new CommandDefinition(UtilSelect + " WHERE u.FacilityId = @f AND u.PublicId = @u;",
            new { f = f.FacilityId, u = uid }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (!scope.Allows(x.CompanyId)) throw ApiProblemException.NotFound();
        if (x.Status != "ACTIVE") throw new ApiProblemException(409, "V-FAC-UTIL-FINAL", "A released or transferred utilisation is final.");
        if (x.SourceType != "MANUAL") throw new ApiProblemException(409, "V-FAC-UTIL-SOURCE", "A utilisation of a letter of credit or a request changes through its own service.");
        var today = clock.GetUtcNow().UtcDateTime.Date;
        if (release)
        {
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE fac.Utilization SET Status = 'RELEASED', ReleasedOn = @d, ReleaseReason = @reason, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE UtilizationId = @id;
                """, new { d = today, reason = b.Reason.Trim(), id = x.UtilizationId }, tx, cancellationToken: ct));
            await UtilMovementAsync(u, tx, f.FacilityId, x.UtilizationId, "RELEASE", x.CurrencyId, -x.Amount, x.Amount, 0, b.Reason.Trim(), ct);
        }
        else
        {
            var after = x.Amount + b.Delta!.Value;
            if (after <= 0) throw ApiProblemException.Invalid("INVALID_DELTA", "The balance stays above zero; release the utilisation instead.");
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE fac.Utilization SET Amount = @a, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE UtilizationId = @id;",
                new { a = after, id = x.UtilizationId }, tx, cancellationToken: ct));
            await UtilMovementAsync(u, tx, f.FacilityId, x.UtilizationId, "ADJUST", x.CurrencyId, b.Delta, x.Amount, after, b.Reason.Trim(), ct);
        }
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(release ? "UTILIZATION_RELEASED" : "UTILIZATION_ADJUSTED", "TREASURY", "fac.Utilization", x.UtilizationId,
            BeforeJson: JsonSerializer.Serialize(new { amount = x.Amount, status = x.Status }),
            AfterJson: JsonSerializer.Serialize(new { delta = b.Delta, released = release, reason = b.Reason.Trim() })), x.CompanyId, ct);
        await Outbox.EmitAsync(u.Connection, tx, release ? "utilization.released" : "utilization.adjusted", "fac.Utilization", x.UtilizationId, new { utilization = x.PublicId }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- recognised balances (FR-FAC-009, BR-FAC-017) ----------

    private sealed class SnapRow
    {
        public long OutstandingSnapshotId { get; init; }
        public long? LimitRootId { get; init; }
        public string? LimitCode { get; init; }
        public string? ProductCode { get; init; }
        public DateTime AsOfDate { get; init; }
        public decimal AcknowledgedAmount { get; init; }
        public string Currency { get; init; } = "";
        public string SourceKind { get; init; } = "";
        public decimal? StatedPct { get; init; }
        public bool ReadFromScan { get; init; }
        public string Confidence { get; init; } = "";
    }

    private static async Task<IResult> SnapshotsAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, ct);
        var rows = await u.Connection.QueryAsync<SnapRow>(new CommandDefinition(
            """
            SELECT s.OutstandingSnapshotId, l.RootId AS LimitRootId, l.Code AS LimitCode, pr.Code AS ProductCode, s.AsOfDate, s.AcknowledgedAmount, cu.Code AS Currency,
                   s.SourceKind, s.StatedPct, s.ReadFromScan, s.Confidence
              FROM fac.OutstandingSnapshot AS s
              LEFT JOIN fac.Limit AS l ON l.LimitId = s.LimitId
              LEFT JOIN cat.Product AS pr ON pr.ProductId = s.ProductId
              JOIN ref.Currency AS cu ON cu.CurrencyId = s.CurrencyId
             WHERE s.FacilityId = @f ORDER BY s.AsOfDate DESC;
            """, new { f = f.FacilityId }, cancellationToken: ct));
        var tree = (await FacilityTreeStore.LoadAsync(u.Connection, null, f.FacilityId, f.ApprovedRevisionNo, ct)).Tree(f.TotalAmount);
        var exposures = await FacilityTreeStore.ExposuresAsync(u.Connection, null, f.FacilityId, ct);
        return Results.Ok(new
        {
            items = rows.Select(s =>
            {
                var cap = s.LimitRootId is { } lr && tree.Nodes.Any(n => n.Root == lr) ? tree.Cap(lr) : f.TotalAmount;
                var used = s.LimitRootId is { } r && tree.Nodes.Any(n => n.Root == r) ? tree.Available(r, null, null, exposures).Used : exposures.Where(x => !x.IsReservation).Sum(x => x.Amount);
                var ack = cap == 0 ? 0 : Math.Round(s.AcknowledgedAmount / cap * 100, 2, MidpointRounding.AwayFromZero);
                return new
                {
                    id = refs.ItemRef(u.TenantId, "snapshot", s.OutstandingSnapshotId), limit = s.LimitCode, product = s.ProductCode, asOfDate = D(s.AsOfDate),
                    acknowledgedAmount = s.AcknowledgedAmount, currency = s.Currency, sourceKind = s.SourceKind, statedPct = s.StatedPct, ackPct = ack,
                    variance = s.AcknowledgedAmount - used, flagged = s.StatedPct is { } st && Math.Abs(ack - st) >= 0.005m, readFromScan = s.ReadFromScan, confidence = s.Confidence,
                };
            }),
        });
    }

    private static async Task<IResult> AddSnapshotAsync(Guid id, SnapshotRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var kind = b.SourceKind?.Trim().ToUpperInvariant() ?? "BANK_STATEMENT";
        if (b.AcknowledgedAmount is not >= 0 || kind is not ("RENEWAL_ACKNOWLEDGEMENT" or "BANK_STATEMENT" or "INTERNAL") || b.StatedPct is < 0)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the acknowledged amount, its date and its source.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, UtilManage);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FacilityEndpoints.FindAsync(u, tx, id, scope, ct);
        var asOf = Date(b.AsOfDate, "date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date of the balance.");
        long? limitRow = null;
        if (b.Limit is not null)
        {
            var root = refs.ItemId(u.TenantId, "limit", b.Limit);
            limitRow = (await FacilityTreeStore.LoadAsync(u.Connection, tx, f.FacilityId, f.ApprovedRevisionNo, ct)).Limits.FirstOrDefault(l => l.RootId == root)?.LimitId
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The limit is not a limit of the approved facility.");
        }
        int? product = b.Product is null ? null : await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT ProductId FROM cat.Product WHERE Code = @c;",
            new { c = b.Product.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The product is not in the catalogue.");
        var src = await SourceAsync(u, tx, f, b.SourceDocument, b.SourcePage, b.ReadFromScan, null, b.NoSourceReason, ct);
        long snap;
        try
        {
            snap = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT fac.OutstandingSnapshot (TenantId, FacilityId, LimitId, ProductId, AsOfDate, AcknowledgedAmount, CurrencyId, SourceKind, StatedPct, SourceDocumentId,
                                                SourcePage, ReadFromScan, NoSourceReason, Confidence, CreatedBy)
                OUTPUT inserted.OutstandingSnapshotId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @l, @p, @asOf, @a, @cur, @kind, @pct, @doc, @page, @scan, @nsr, @conf, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new
                {
                    f = f.FacilityId, l = limitRow, p = product, asOf, a = b.AcknowledgedAmount, cur = b.Currency is null ? f.CurrencyId : await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency, ct),
                    kind, pct = b.StatedPct, doc = src.Doc, page = src.Page, scan = src.Scan, nsr = src.Reason, conf = src.Confidence,
                }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            throw new ApiProblemException(409, "V-FAC-SNAPSHOT-EXISTS", "This balance is already recorded for the date and source.");
        }
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("BALANCE_RECORDED", "TREASURY", "fac.OutstandingSnapshot", snap,
            AfterJson: JsonSerializer.Serialize(new { asOf = D(asOf), amount = b.AcknowledgedAmount, kind })), f.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/snapshots", new { id = refs.ItemRef(u.TenantId, "snapshot", snap) });
    }
}

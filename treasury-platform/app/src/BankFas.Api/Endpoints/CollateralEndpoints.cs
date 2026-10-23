using System.Data;
using System.Globalization;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Collateral;
using BankFas.Data;
using BankFas.Data.Facilities;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record GuaranteeRequest(Guid? Guarantor, Guid? IdentityDocument, string? Form, bool? IsJointSeveral, string? AmountMode, decimal? Amount, string? Currency,
    string? SignedOn, string? ValidTo, Guid? DeedDocument);
public sealed record NoteRequest(decimal? Amount, string? Currency, string? IssuedOn, string? DueKind, string? DueDate, string? RenewalCycle, string? LastRenewedOn,
    string? CustodyKind, Guid[]? Signers, Guid? NoteDocument);
public sealed record InsuranceRequest(string? PolicyNo, string? InsurerName, Guid? AssignedTo, string? CoverageBasis, decimal? CoveragePct, decimal? CoverageAmount,
    decimal? SumInsured, string? Currency, string? PolicyStart, string? PolicyExpiry, string? AssignmentDate, Guid? PolicyDocument);
public sealed record CashMarginRequest(decimal? Pct, decimal? Amount, Guid? Account);
public sealed record ValuationPhaseRequest(int? PhaseNo, int? FromYear, int? ToYear, int? RequiredValuerCount, int? FrequencyMonths, string? ReferenceDate);
public sealed record CollateralRequest(string? CollateralType, string? TitleAr, string? Description, Guid? Owner, Dictionary<string, JsonElement>? Attributes, string? GrantedOn,
    Guid? SourceDocument, string? SourcePage, bool? ReadFromScan, string? OriginalText, string? NoSourceReason, GuaranteeRequest? Guarantee, NoteRequest? Note,
    InsuranceRequest? Insurance, CashMarginRequest? CashMargin, ValuationPhaseRequest[]? Valuations);
public sealed record CollateralReleaseRequest(string? ReleasedOn, string? Reason, Guid? Document);
public sealed record NoteRenewalRequest(string? RenewedOn);
public sealed record ValuationRecordRequest(int? PhaseNo, string? On, decimal? Amount, string? Currency);
public sealed record CollateralLinkRequest(Guid? Collateral, string? Limit, decimal? CoverageAmount, int? LienRank, string? LinkedOn);
public sealed record CollateralUnlinkRequest(string? UnlinkedOn);

/// <summary>
/// Collateral and guarantors (spec 12 section 5, FR-COL-001 to 015; BR-COL-001 to 007). A collateral is a chain of
/// versions with one root (DR-36): a DRAFT is approved by a user with col.approve who did not prepare it (FR-COL-014),
/// and a change of an approved version is a new DRAFT that supersedes it on approval, while coverage reads the approved
/// one. The typed parts of an approved version are fixed (062). Links to a facility are rows of the facility's revision
/// (OQ-11): they are written into its draft and approved with it, and name the collateral by its root. Release is not a
/// revision: it needs a date, a reason and a document, and the collateral leaves the coverage from that date
/// (FR-COL-010). Coverage (R-COL-01) is a matrix by type with no single total (BR-COL-006).
/// </summary>
public static class CollateralEndpoints
{
    internal const string View = "col.view";
    internal const string Manage = "col.manage";
    internal const string Approve = "col.approve";
    private static readonly string[] Unapproved = ["DRAFT", "DISCARDED"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/collaterals", ListAsync);
        api.MapPost("/collaterals", CreateAsync);
        api.MapGet("/collaterals/{id:guid}", GetAsync);
        api.MapPut("/collaterals/{id:guid}", ReplaceAsync);
        api.MapPost("/collaterals/{id:guid}/versions", NewVersionAsync);
        api.MapPost("/collaterals/{id:guid}/actions/approve", ApproveAsync);
        api.MapPost("/collaterals/{id:guid}/actions/discard", DiscardAsync);
        api.MapPost("/collaterals/{id:guid}/actions/release", ReleaseAsync);
        api.MapPost("/collaterals/{id:guid}/actions/record-renewal", RecordRenewalAsync);
        api.MapPost("/collaterals/{id:guid}/actions/record-valuation", RecordValuationAsync);
        api.MapGet("/facilities/{id:guid}/collateral-links", LinksAsync);
        api.MapPost("/facilities/{id:guid}/collateral-links", LinkAsync);
        api.MapPost("/facilities/{id:guid}/collateral-links/{reference}/actions/unlink", UnlinkAsync);
        api.MapDelete("/facilities/{id:guid}/collateral-links/{reference}", RemoveLinkAsync);
        api.MapGet("/facilities/{id:guid}/coverage", CoverageAsync);
        api.MapGet("/parties/{id:guid}/guarantees", GuaranteesAsync);
    }

    internal sealed class Row
    {
        public long CollateralId { get; init; }
        public Guid PublicId { get; init; }
        public long RootId { get; init; }
        public Guid RootPublicId { get; init; }
        public long? SupersedesId { get; init; }
        public string StructureKind { get; init; } = "";
        public int CollateralTypeId { get; init; }
        public string TypeCode { get; init; } = "";
        public string TypeNameAr { get; init; } = "";
        public string? TypeNameEn { get; init; }
        public string TitleAr { get; init; } = "";
        public string? Description { get; init; }
        public long? OwnerPartyId { get; init; }
        public Guid? OwnerId { get; init; }
        public string? OwnerNameAr { get; init; }
        public string? OwnerNameEn { get; init; }
        public string? Attributes { get; init; }
        public long? CashMarginAccountId { get; init; }
        public string? CashMarginAccountMask { get; init; }
        public string Status { get; init; } = "";
        public string ApprovalState { get; init; } = "";
        public DateTime? ApprovedOn { get; init; }
        public DateTime? GrantedOn { get; init; }
        public DateTime? ReleasedOn { get; init; }
        public string? ReleaseReason { get; init; }
        public string? NoSourceReason { get; init; }
        public string? SourcePage { get; init; }
        public string Confidence { get; init; } = "";
        public long? CreatedBy { get; init; }
        public long? UpdatedBy { get; init; }
    }

    private const string Select = """
        SELECT k.CollateralId, k.PublicId, k.RootId, r.PublicId AS RootPublicId, k.SupersedesId, k.StructureKind, k.CollateralTypeId, t.Code AS TypeCode, t.NameAr AS TypeNameAr,
               t.NameEn AS TypeNameEn, k.TitleAr, k.Description, k.OwnerPartyId, o.PublicId AS OwnerId, o.NameAr AS OwnerNameAr, o.NameEn AS OwnerNameEn, k.Attributes,
               k.CashMarginAccountId, a.AccountNoMask AS CashMarginAccountMask, k.Status, k.ApprovalState, k.ApprovedOn, k.GrantedOn, k.ReleasedOn, k.ReleaseReason,
               k.NoSourceReason, k.SourcePage, k.Confidence, k.CreatedBy, k.UpdatedBy
          FROM col.Collateral AS k
          JOIN col.Collateral AS r ON r.CollateralId = k.RootId
          JOIN cat.CollateralType AS t ON t.CollateralTypeId = k.CollateralTypeId
          LEFT JOIN pty.Party AS o ON o.PartyId = k.OwnerPartyId
          LEFT JOIN acc.BankAccount AS a ON a.BankAccountId = k.CashMarginAccountId
        """;

    private static async Task<Row> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CancellationToken ct, bool lockRow = false) =>
        await u.Connection.QuerySingleOrDefaultAsync<Row>(new CommandDefinition(
            Select.Replace("FROM col.Collateral AS k", lockRow ? "FROM col.Collateral AS k WITH (UPDLOCK, HOLDLOCK)" : "FROM col.Collateral AS k", StringComparison.Ordinal)
            + " WHERE k.PublicId = @id;", new { id }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();

    private static object Shape(Row k) => new
    {
        id = k.PublicId, root = k.RootPublicId, type = new { code = k.TypeCode, nameAr = k.TypeNameAr, nameEn = k.TypeNameEn, structure = k.StructureKind }, titleAr = k.TitleAr,
        description = k.Description, owner = k.OwnerId is null ? null : new { id = k.OwnerId, nameAr = k.OwnerNameAr, nameEn = k.OwnerNameEn },
        attributes = k.Attributes is null ? (JsonElement?)null : JsonSerializer.Deserialize<JsonElement>(k.Attributes), cashMarginAccount = k.CashMarginAccountMask, status = k.Status,
        approvalState = k.ApprovalState, approvedOn = k.ApprovedOn, grantedOn = FacilityEndpoints.D(k.GrantedOn), releasedOn = FacilityEndpoints.D(k.ReleasedOn),
        releaseReason = k.ReleaseReason, supersedes = k.SupersedesId is not null, source = new { page = k.SourcePage, noSourceReason = k.NoSourceReason, confidence = k.Confidence },
    };

    // ---------- the typed parts ----------

    private sealed record Parts(GuaranteePart? Guarantee, NotePart? Note, InsurancePart? Insurance, List<ValuationPhase> Phases);
    private sealed record GuaranteePart(long Party, string PartyKind, long? IdentityDocument, string Form, bool JointSeveral, string Mode, decimal? Amount, int? Currency,
        DateTime? SignedOn, DateTime? ValidTo, long? Deed);
    private sealed record NotePart(decimal Amount, int Currency, DateTime IssuedOn, string DueKind, DateTime? DueDate, string Cycle, DateTime? LastRenewedOn, string Custody,
        long[] Signers, long? Document);
    private sealed record InsurancePart(string PolicyNo, string Insurer, long AssignedTo, string Basis, decimal? Pct, decimal? Amount, decimal SumInsured, int Currency,
        DateTime? Start, DateTime Expiry, DateTime? AssignedOn, long? Document);

    private sealed record Values(int TypeId, string Structure, string TitleAr, string? Description, long? Owner, string? Attributes, long? CashAccount, DateTime? GrantedOn,
        long? SourceDoc, string? SourcePage, bool Scan, string? Original, string? NoSourceReason, string Confidence, Parts Parts);

    private static DateTime? Date(string? text, string label) => LimitEndpoints.Date(text, label);

    private static async Task<long?> DocAsync(BoundUser u, SqlTransaction tx, Guid? document, CancellationToken ct) =>
        document is null ? null
        : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE';", new { d = document }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is not an active document.");

    private static async Task<(long Id, string Kind)> PartyAsync(BoundUser u, SqlTransaction tx, Guid? party, string label, CancellationToken ct)
    {
        if (party is null) throw ApiProblemException.Invalid("V-COL-01", $"Give the {label}: a person or an entity of the parties (BR-COL-001).");
        return await u.Connection.QuerySingleOrDefaultAsync<(long, string)?>(new CommandDefinition(
            "SELECT PartyId, Kind FROM pty.Party WHERE PublicId = @p AND IsActive = 1;", new { p = party }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("V-COL-01", $"The {label} is not an active party.");
    }

    /// <summary>V-COL-01 and the type template: the values of a version, checked before anything is written.</summary>
    private static async Task<Values> ValuesAsync(BoundUser u, SqlTransaction tx, CollateralRequest b, Row? current, CancellationToken ct)
    {
        (int Id, string Structure) type;
        if (current is not null)
        {
            if (b.CollateralType is not null && !string.Equals(b.CollateralType, current.TypeCode, StringComparison.OrdinalIgnoreCase))
                throw ApiProblemException.Invalid("V-COL-TYPE-FIXED", "The type of a collateral does not change; register a new one.");
            type = (current.CollateralTypeId, current.StructureKind);
        }
        else
        {
            if (string.IsNullOrWhiteSpace(b.CollateralType)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the type of the collateral.");
            type = await u.Connection.QuerySingleOrDefaultAsync<(int, string)?>(new CommandDefinition(
                "SELECT CollateralTypeId, StructureKind FROM cat.CollateralType WHERE Code = @c AND IsActive = 1;", new { c = b.CollateralType.Trim().ToUpperInvariant() }, tx,
                cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The collateral type is not an active type of the catalogue.");
        }
        if (string.IsNullOrWhiteSpace(b.TitleAr)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the Arabic title of the collateral.");
        long? owner = b.Owner is null ? null : (await PartyAsync(u, tx, b.Owner, "owner", ct)).Id;

        // The attributes of the type's template (FR-COL-001): known keys, values of their type; the required ones are checked at approval.
        var template = (await u.Connection.QueryAsync<(string Key, string DataType, string? Options)>(new CommandDefinition(
            "SELECT AttrKey, DataType, ListOptions FROM cat.CollateralTypeAttribute WHERE CollateralTypeId = @t AND IsRetired = 0;", new { t = type.Id }, tx,
            cancellationToken: ct))).ToDictionary(x => x.Key, StringComparer.OrdinalIgnoreCase);
        var attrs = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var (key, v) in b.Attributes ?? [])
        {
            if (!template.TryGetValue(key, out var a)) throw ApiProblemException.Invalid("V-COL-01", $"{key} is not an attribute of the type's template.");
            if (v.ValueKind == JsonValueKind.Null) continue;
            var ok = a.DataType switch
            {
                "NUMBER" or "AMOUNT" => v.ValueKind == JsonValueKind.Number,
                "BOOLEAN" => v.ValueKind is JsonValueKind.True or JsonValueKind.False,
                "DATE" => v.ValueKind == JsonValueKind.String && DateTime.TryParseExact(v.GetString(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _),
                "LIST" => v.ValueKind == JsonValueKind.String && a.Options is not null && JsonSerializer.Deserialize<JsonElement>(a.Options).EnumerateArray()
                    .Any(o => (o.ValueKind == JsonValueKind.String ? o.GetString() : o.TryGetProperty("code", out var c) ? c.GetString() : null) == v.GetString()),
                _ => v.ValueKind == JsonValueKind.String,
            };
            if (!ok) throw ApiProblemException.Invalid("V-COL-01", $"The value of {key} is not a {a.DataType}.");
            attrs[a.Key] = v;
        }
        long? cashAccount = null;
        if (b.CashMargin is { } cm)
        {
            if (type.Structure != "CASH_MARGIN") throw ApiProblemException.Invalid("V-COL-01", "Only a cash margin has a margin and its account.");
            if ((cm.Pct is null) == (cm.Amount is null) || cm.Pct is <= 0 or > 100 || cm.Amount is <= 0)
                throw ApiProblemException.Invalid("V-COL-01", "A cash margin is a percent (0 to 100) or an amount, one of them.");
            attrs["MARGIN_PCT"] = cm.Pct;
            attrs["MARGIN_AMOUNT"] = cm.Amount;
            cashAccount = cm.Account is null ? null : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT BankAccountId FROM acc.BankAccount WHERE PublicId = @a;", new { a = cm.Account }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("V-COL-01", "The margin account is not an account of the account.");
        }

        // The source (BR-FAC-018 applies to collateral as to the facility: a document and its page, or the reason there is none).
        long? srcDoc = await DocAsync(u, tx, b.SourceDocument, ct);
        if (srcDoc is null && string.IsNullOrWhiteSpace(b.NoSourceReason))
            throw ApiProblemException.Invalid("V-FAC-SOURCE", "Name the document and its page the value comes from, or give the reason it has none (BR-FAC-018).");
        if (srcDoc is not null && string.IsNullOrWhiteSpace(b.SourcePage)) throw ApiProblemException.Invalid("V-FAC-SOURCE", "A value from a document names its page.");

        var parts = new Parts(null, null, null, []);
        if (type.Structure == "GUARANTEE")
        {
            var g = b.Guarantee ?? throw ApiProblemException.Invalid("V-COL-01", "A guarantee names its guarantor and its amount (BR-COL-001).");
            var (party, kind) = await PartyAsync(u, tx, g.Guarantor, "guarantor", ct);
            var mode = g.AmountMode?.ToUpperInvariant();
            if (mode == "SPECIFIED" && (g.Amount is null or <= 0 || string.IsNullOrWhiteSpace(g.Currency)))
                throw ApiProblemException.Invalid("V-COL-01", "A specified guarantee has its amount, above zero, and its currency.");
            if (mode == "UNSPECIFIED" && (g.Amount is not null || g.Currency is not null))
                throw ApiProblemException.Invalid("V-COL-01", "An unspecified guarantee has no amount.");
            if (mode is not ("SPECIFIED" or "UNSPECIFIED")) throw ApiProblemException.Invalid("V-COL-01", "The amount of a guarantee is SPECIFIED or UNSPECIFIED.");
            var form = g.Form?.ToUpperInvariant() ?? "JOINT_SEVERAL_PAYMENT_PERFORMANCE";
            if (form is not ("JOINT_SEVERAL_PAYMENT_PERFORMANCE" or "SIMPLE" or "OTHER")) throw ApiProblemException.Invalid("V-COL-01", "The form of a guarantee is one of its forms.");
            var joint = form == "JOINT_SEVERAL_PAYMENT_PERFORMANCE" || g.IsJointSeveral == true;
            long? idDoc = g.IdentityDocument is null ? null : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT IdentityDocumentId FROM pty.IdentityDocument WHERE PublicId = @d AND PartyId = @p;", new { d = g.IdentityDocument, p = party }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("V-COL-01", "The identity document is a document of the guarantor (BR-PTY-006).");
            var signed = Date(g.SignedOn, "signing date");
            var validTo = Date(g.ValidTo, "end date");
            if (signed is not null && validTo < signed) throw ApiProblemException.Invalid("V-COL-01", "A guarantee ends on or after its signing.");
            parts = parts with
            {
                Guarantee = new(party, kind, idDoc, form, joint, mode, g.Amount, mode == "SPECIFIED" ? await FacilityEndpoints.CurrencyAsync(u, tx, g.Currency!, ct) : null, signed,
                    validTo, await DocAsync(u, tx, g.DeedDocument, ct)),
            };
        }
        else if (b.Guarantee is not null) throw ApiProblemException.Invalid("V-COL-01", "Only a guarantee has a guarantor.");
        if (type.Structure == "PROMISSORY_NOTE")
        {
            var n = b.Note ?? throw ApiProblemException.Invalid("V-COL-01", "A promissory note has its amount, currency and issue date.");
            if (n.Amount is null or <= 0 || string.IsNullOrWhiteSpace(n.Currency)) throw ApiProblemException.Invalid("V-COL-01", "A note has its amount, above zero, and its currency.");
            var issued = Date(n.IssuedOn, "issue date") ?? throw ApiProblemException.Invalid("V-COL-01", "Give the issue date of the note.");
            var due = n.DueKind?.ToUpperInvariant() ?? "ON_DEMAND";
            var dueDate = Date(n.DueDate, "due date");
            if (due == "FIXED_DATE" ? dueDate is null || dueDate < issued : dueDate is not null || due != "ON_DEMAND")
                throw ApiProblemException.Invalid("V-COL-01", "A note is due on demand, with no date, or on a fixed date on or after its issue.");
            var cycle = n.RenewalCycle?.ToUpperInvariant() ?? "NONE";
            var renewed = Date(n.LastRenewedOn, "renewal date");
            if (cycle is not ("NONE" or "ANNUAL") || (cycle == "NONE" && renewed is not null) || renewed < issued)
                throw ApiProblemException.Invalid("V-COL-01", "A note renews never or yearly; a renewal date is on or after the issue, and only for a yearly note.");
            var custody = n.CustodyKind?.ToUpperInvariant() ?? "BANK";
            if (custody is not ("BANK" or "COMPANY" or "OTHER")) throw ApiProblemException.Invalid("V-COL-01", "The note is held by the bank, the company or another.");
            var signers = new List<long>();
            foreach (var s in (n.Signers ?? []).Distinct()) signers.Add((await PartyAsync(u, tx, s, "signer", ct)).Id);
            parts = parts with
            {
                Note = new(n.Amount.Value, await FacilityEndpoints.CurrencyAsync(u, tx, n.Currency, ct), issued, due, dueDate, cycle, renewed, custody, [.. signers],
                    await DocAsync(u, tx, n.NoteDocument, ct)),
            };
        }
        else if (b.Note is not null) throw ApiProblemException.Invalid("V-COL-01", "Only a promissory note has a note.");
        if (type.Structure == "INSURANCE_ASSIGNMENT")
        {
            var i = b.Insurance ?? throw ApiProblemException.Invalid("V-COL-01", "An insurance assignment has its policy, insurer, bank and sum insured.");
            if (string.IsNullOrWhiteSpace(i.PolicyNo) || string.IsNullOrWhiteSpace(i.InsurerName) || i.AssignedTo is null || i.SumInsured is null or <= 0 || string.IsNullOrWhiteSpace(i.Currency))
                throw ApiProblemException.Invalid("V-COL-01", "An insurance assignment has its policy, insurer, bank and sum insured.");
            var basis = i.CoverageBasis?.ToUpperInvariant();
            var basisOk = basis switch
            {
                "PCT_OF_LIMIT" => i.CoveragePct is > 0 && i.CoverageAmount is null,
                "FIXED_AMOUNT" => i.CoverageAmount is > 0 && i.CoveragePct is null,
                "FULL_LIMITS" => i.CoveragePct is null && i.CoverageAmount is null,
                _ => false,
            };
            if (!basisOk) throw ApiProblemException.Invalid("V-COL-01", "The coverage is a percent of the limit, a fixed amount or the full limits, with only its own value.");
            var start = Date(i.PolicyStart, "policy start");
            var expiry = Date(i.PolicyExpiry, "policy expiry") ?? throw ApiProblemException.Invalid("V-COL-01", "Give the expiry of the policy.");
            if (start is not null && expiry < start) throw ApiProblemException.Invalid("V-COL-01", "A policy expires on or after its start.");
            var bank = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @i;", new { i = i.AssignedTo }, tx,
                cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-COL-01", "The bank is not an institution of the account.");
            parts = parts with
            {
                Insurance = new(i.PolicyNo.Trim(), i.InsurerName.Trim(), bank, basis!, i.CoveragePct, i.CoverageAmount, i.SumInsured.Value,
                    await FacilityEndpoints.CurrencyAsync(u, tx, i.Currency, ct), start, expiry, Date(i.AssignmentDate, "assignment date"), await DocAsync(u, tx, i.PolicyDocument, ct)),
            };
        }
        else if (b.Insurance is not null) throw ApiProblemException.Invalid("V-COL-01", "Only an insurance assignment has a policy.");
        if (b.Valuations is { Length: > 0 } vs)
        {
            if (type.Structure is not ("REAL_ESTATE" or "GENERIC")) throw ApiProblemException.Invalid("V-COL-01", "Only a property or a generic collateral has a valuation schedule.");
            var phases = vs.Select((v, n) => new ValuationPhase(v.PhaseNo ?? n + 1, v.FromYear ?? 0, v.ToYear, v.RequiredValuerCount ?? 0, v.FrequencyMonths ?? -1,
                Date(v.ReferenceDate, "reference date") ?? throw ApiProblemException.Invalid("V-COL-01", "A valuation phase has its reference date."))).ToList();
            if (phases.Any(p => p.FromYear < 1 || p.ToYear < p.FromYear || p.RequiredValuerCount < 1 || p.FrequencyMonths < 0) || phases.Select(p => p.PhaseNo).Distinct().Count() != phases.Count)
                throw ApiProblemException.Invalid("V-COL-01", "A phase has its number, its years from 1, its valuers (one or more) and its frequency (0 for once).");
            if (CollateralMath.PhasesOverlap(phases)) throw ApiProblemException.Invalid("V-COL-01", "The phases of a valuation schedule do not overlap, and only the last is open.");
            parts = parts with { Phases = phases };
        }
        var granted = Date(b.GrantedOn, "grant date");
        return new Values(type.Id, type.Structure, b.TitleAr.Trim(), b.Description?.Trim(), owner, attrs.Count == 0 ? null : JsonSerializer.Serialize(attrs), cashAccount, granted,
            srcDoc, b.SourcePage?.Trim(), b.ReadFromScan ?? false, b.OriginalText?.Trim(), b.NoSourceReason?.Trim() is { Length: > 0 } r ? r : null,
            b.ReadFromScan == true ? "READ_FROM_SCAN_UNVERIFIED" : "ENTERED_NO_DOCUMENT", parts);
    }

    private static async Task<(long Id, Guid PublicId)> InsertAsync(BoundUser u, SqlTransaction tx, Values v, Row? supersedes, CancellationToken ct)
    {
        var (id, publicId) = await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT col.Collateral (TenantId, StructureKind, CollateralTypeId, TitleAr, Description, OwnerPartyId, Attributes, CashMarginAccountId, Status, ApprovalState,
                                   SupersedesId, InheritedRootId, GrantedOn, SourceDocumentId, SourcePage, ReadFromScan, OriginalText, NoSourceReason, Confidence, CreatedBy)
            OUTPUT inserted.CollateralId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @s, @t, @title, @desc, @owner, @attrs, @cash, 'DRAFT', 'DRAFT', @sup, @root, @granted, @doc, @page, @scan, @orig,
                    @reason, @conf, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new
            {
                s = v.Structure, t = v.TypeId, title = v.TitleAr, desc = v.Description, owner = v.Owner, attrs = v.Attributes, cash = v.CashAccount, sup = supersedes?.CollateralId,
                root = supersedes?.RootId, granted = v.GrantedOn, doc = v.SourceDoc, page = v.SourcePage, scan = v.Scan, orig = v.Original, reason = v.NoSourceReason,
                conf = v.Confidence,
            }, tx, cancellationToken: ct));
        await WritePartsAsync(u, tx, id, v, ct);
        return (id, publicId);
    }

    /// <summary>The typed parts of a DRAFT version: each 1:1 part is updated in place or inserted; the note's signers and the valuation phases are replaced.</summary>
    private static async Task WritePartsAsync(BoundUser u, SqlTransaction tx, long id, Values v, CancellationToken ct)
    {
        var c = u.Connection;
        if (v.Parts.Guarantee is { } g)
            await c.ExecuteAsync(new CommandDefinition(
                """
                DECLARE @me BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
                UPDATE col.Guarantee SET GuarantorPartyId = @p, GuarantorIdentityDocumentId = @doc, GuaranteeForm = @form, IsJointSeveral = @joint, AmountMode = @mode, Amount = @amount,
                       CurrencyId = @cur, SignedOn = @signed, ValidTo = @to, DeedDocumentId = @deed, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me
                 WHERE CollateralId = @k;
                IF @@ROWCOUNT = 0
                    INSERT col.Guarantee (TenantId, CollateralId, GuarantorPartyId, GuarantorIdentityDocumentId, GuaranteeForm, IsJointSeveral, AmountMode, Amount, CurrencyId,
                                          SignedOn, ValidTo, DeedDocumentId, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @k, @p, @doc, @form, @joint, @mode, @amount, @cur, @signed, @to, @deed, @me);
                """, new
                {
                    k = id, p = g.Party, doc = g.IdentityDocument, form = g.Form, joint = g.JointSeveral, mode = g.Mode, amount = g.Amount, cur = g.Currency, signed = g.SignedOn,
                    to = g.ValidTo, deed = g.Deed,
                }, tx, cancellationToken: ct));
        if (v.Parts.Note is { } n)
        {
            var note = await c.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @me BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
                UPDATE col.PromissoryNote SET NoteAmount = @amount, CurrencyId = @cur, IssuedOn = @issued, DueKind = @due, DueDate = @dueDate, RenewalCycle = @cycle,
                       LastRenewedOn = @renewed, CustodyKind = @custody, NoteDocumentId = @doc, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me
                 WHERE CollateralId = @k;
                IF @@ROWCOUNT = 0
                    INSERT col.PromissoryNote (TenantId, CollateralId, NoteAmount, CurrencyId, IssuedOn, DueKind, DueDate, RenewalCycle, LastRenewedOn, CustodyKind, NoteDocumentId, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @k, @amount, @cur, @issued, @due, @dueDate, @cycle, @renewed, @custody, @doc, @me);
                SELECT PromissoryNoteId FROM col.PromissoryNote WHERE CollateralId = @k;
                """, new
                {
                    k = id, amount = n.Amount, cur = n.Currency, issued = n.IssuedOn, due = n.DueKind, dueDate = n.DueDate, cycle = n.Cycle, renewed = n.LastRenewedOn,
                    custody = n.Custody, doc = n.Document,
                }, tx, cancellationToken: ct));
            await c.ExecuteAsync(new CommandDefinition("DELETE FROM col.PromissoryNoteSigner WHERE PromissoryNoteId = @n;", new { n = note }, tx, cancellationToken: ct));
            foreach (var s in n.Signers)
                await c.ExecuteAsync(new CommandDefinition(
                    "INSERT col.PromissoryNoteSigner (TenantId, PromissoryNoteId, PartyId, CreatedBy) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @n, @p, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));",
                    new { n = note, p = s }, tx, cancellationToken: ct));
        }
        if (v.Parts.Insurance is { } i)
            await c.ExecuteAsync(new CommandDefinition(
                """
                DECLARE @me BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
                UPDATE col.InsurancePolicyAssignment SET PolicyNo = @no, InsurerName = @insurer, AssignedToInstitutionId = @bank, CoverageBasis = @basis, CoveragePct = @pct,
                       CoverageAmount = @amount, SumInsured = @sum, CurrencyId = @cur, PolicyStart = @start, PolicyExpiry = @expiry, AssignmentDate = @assigned,
                       PolicyDocumentId = @doc, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @me
                 WHERE CollateralId = @k;
                IF @@ROWCOUNT = 0
                    INSERT col.InsurancePolicyAssignment (TenantId, CollateralId, PolicyNo, InsurerName, AssignedToInstitutionId, CoverageBasis, CoveragePct, CoverageAmount, SumInsured,
                                                          CurrencyId, PolicyStart, PolicyExpiry, AssignmentDate, PolicyDocumentId, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @k, @no, @insurer, @bank, @basis, @pct, @amount, @sum, @cur, @start, @expiry, @assigned, @doc, @me);
                """, new
                {
                    k = id, no = i.PolicyNo, insurer = i.Insurer, bank = i.AssignedTo, basis = i.Basis, pct = i.Pct, amount = i.Amount, sum = i.SumInsured, cur = i.Currency,
                    start = i.Start, expiry = i.Expiry, assigned = i.AssignedOn, doc = i.Document,
                }, tx, cancellationToken: ct));
        foreach (var p in v.Parts.Phases)
            await c.ExecuteAsync(new CommandDefinition(
                """
                DECLARE @me BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
                UPDATE col.ValuationSchedule SET FromYear = @from, ToYear = @to, RequiredValuerCount = @n, FrequencyMonths = @freq, ReferenceDate = @ref, UpdatedAt = SYSUTCDATETIME(),
                       UpdatedBy = @me
                 WHERE CollateralId = @k AND PhaseNo = @phase;
                IF @@ROWCOUNT = 0
                    INSERT col.ValuationSchedule (TenantId, StructureKind, CollateralId, PhaseNo, FromYear, ToYear, RequiredValuerCount, FrequencyMonths, ReferenceDate, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @s, @k, @phase, @from, @to, @n, @freq, @ref, @me);
                """, new { k = id, s = v.Structure, phase = p.PhaseNo, from = p.FromYear, to = p.ToYear, n = p.RequiredValuerCount, freq = p.FrequencyMonths, @ref = p.ReferenceDate },
                tx, cancellationToken: ct));
    }

    // ---------- the register ----------

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "status", "type", "party");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var q = http.Request.Query;
        Guid? party = Guid.TryParse(q["party"], out var pg) ? pg : null;
        var rows = await u.Connection.QueryAsync<Row>(new CommandDefinition(
            Select + """
             WHERE (@status IS NULL OR k.Status = @status) AND (@type IS NULL OR t.Code = @type)
               AND (@party IS NULL OR o.PublicId = @party OR EXISTS (SELECT 1 FROM col.Guarantee AS g JOIN pty.Party AS gp ON gp.PartyId = g.GuarantorPartyId
                                                                      WHERE g.CollateralId = k.CollateralId AND gp.PublicId = @party))
               AND (k.Status = 'DRAFT' OR (k.ApprovalState = 'APPROVED' AND k.Status <> 'SUPERSEDED'))
             ORDER BY k.RootId, k.CollateralId;
            """, new { status = q["status"].ToString() is { Length: > 0 } s ? s : null, type = q["type"].ToString() is { Length: > 0 } t ? t : null, party },
            cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(Shape) });
    }

    private static async Task<IResult> CreateAsync(CollateralRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var v = await ValuesAsync(u, tx, b, null, ct);
        var (id, publicId) = await InsertAsync(u, tx, v, null, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COLLATERAL_CREATED", "TREASURY", "col.Collateral", id,
            AfterJson: JsonSerializer.Serialize(new { type = b.CollateralType, structure = v.Structure })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/collaterals/{publicId}", new { id = publicId });
    }

    /// <summary>A version with its typed parts, the other versions of its root and the facilities that link the root.</summary>
    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var k = await FindAsync(u, null, id, ct);
        var g = await u.Connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT p.PublicId AS Guarantor, p.NameAr, p.NameEn, p.Kind, g.GuaranteeForm, g.IsJointSeveral, g.AmountMode, g.Amount, cu.Code AS Currency, g.SignedOn, g.ValidTo,
                   d.NumberMask, d.ExpiryDate AS IdExpiry
              FROM col.Guarantee AS g JOIN pty.Party AS p ON p.PartyId = g.GuarantorPartyId LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = g.CurrencyId
              LEFT JOIN pty.IdentityDocument AS d ON d.IdentityDocumentId = g.GuarantorIdentityDocumentId
             WHERE g.CollateralId = @k;
            """, new { k = k.CollateralId }, cancellationToken: ct));
        var n = await u.Connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT n.PromissoryNoteId, n.NoteAmount, cu.Code AS Currency, n.IssuedOn, n.DueKind, n.DueDate, n.RenewalCycle, n.LastRenewedOn, n.CustodyKind
              FROM col.PromissoryNote AS n JOIN ref.Currency AS cu ON cu.CurrencyId = n.CurrencyId WHERE n.CollateralId = @k;
            """, new { k = k.CollateralId }, cancellationToken: ct));
        var signers = n is null ? [] : await u.Connection.QueryAsync(new CommandDefinition(
            "SELECT p.PublicId AS id, p.NameAr AS nameAr, p.NameEn AS nameEn FROM col.PromissoryNoteSigner AS s JOIN pty.Party AS p ON p.PartyId = s.PartyId WHERE s.PromissoryNoteId = @n;",
            new { n = (long)n.PromissoryNoteId }, cancellationToken: ct));
        var i = await u.Connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT i.PolicyNo, i.InsurerName, b.Code AS Bank, i.CoverageBasis, i.CoveragePct, i.CoverageAmount, i.SumInsured, cu.Code AS Currency, i.PolicyStart, i.PolicyExpiry,
                   i.AssignmentDate
              FROM col.InsurancePolicyAssignment AS i JOIN ins.Institution AS b ON b.InstitutionId = i.AssignedToInstitutionId JOIN ref.Currency AS cu ON cu.CurrencyId = i.CurrencyId
             WHERE i.CollateralId = @k;
            """, new { k = k.CollateralId }, cancellationToken: ct));
        var phases = await u.Connection.QueryAsync<(int PhaseNo, int FromYear, int? ToYear, int Valuers, int Freq, DateTime Ref, DateTime? LastOn, decimal? LastAmount)>(new CommandDefinition(
            """
            SELECT PhaseNo, FromYear, ToYear, RequiredValuerCount, FrequencyMonths, ReferenceDate, LastValuationOn, LastValuationAmount
              FROM col.ValuationSchedule WHERE CollateralId = @k ORDER BY PhaseNo;
            """, new { k = k.CollateralId }, cancellationToken: ct));
        var versions = await u.Connection.QueryAsync<(Guid Id, string Status, string Approval, DateTime CreatedAt)>(new CommandDefinition(
            "SELECT PublicId, Status, ApprovalState, CreatedAt FROM col.Collateral WHERE RootId = @r ORDER BY CollateralId;", new { r = k.RootId }, cancellationToken: ct));
        var links = await u.Connection.QueryAsync<(Guid Facility, string FacilityNo, DateTime LinkedOn, DateTime? UnlinkedOn)>(new CommandDefinition(
            """
            SELECT f.PublicId, ISNULL(f.PlatformRef, f.FacilityNo) AS FacilityNo, l.LinkedOn, l.UnlinkedOn FROM col.CollateralLink AS l JOIN fac.Facility AS f ON f.FacilityId = l.FacilityId
             WHERE l.CollateralId = @r AND l.FromRevision <= f.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo);
            """, new { r = k.RootId }, cancellationToken: ct));
        var phaseList = phases.Select(p => new ValuationPhase(p.PhaseNo, p.FromYear, p.ToYear, p.Valuers, p.Freq, p.Ref)).ToList();
        return Results.Ok(new
        {
            collateral = Shape(k),
            guarantee = g is null ? null : new
            {
                guarantor = new { id = (Guid)g.Guarantor, nameAr = (string?)g.NameAr, nameEn = (string?)g.NameEn, kind = (string)g.Kind }, form = (string)g.GuaranteeForm,
                isJointSeveral = (bool)g.IsJointSeveral, amountMode = (string)g.AmountMode, amount = (decimal?)g.Amount, currency = (string?)g.Currency,
                signedOn = FacilityEndpoints.D((DateTime?)g.SignedOn), validTo = FacilityEndpoints.D((DateTime?)g.ValidTo), identity = (string?)g.NumberMask,
                identityExpiry = FacilityEndpoints.D((DateTime?)g.IdExpiry),
            },
            note = n is null ? null : new
            {
                amount = (decimal)n.NoteAmount, currency = (string)n.Currency, issuedOn = FacilityEndpoints.D((DateTime)n.IssuedOn), dueKind = (string)n.DueKind,
                dueDate = FacilityEndpoints.D((DateTime?)n.DueDate), renewalCycle = (string)n.RenewalCycle, lastRenewedOn = FacilityEndpoints.D((DateTime?)n.LastRenewedOn),
                nextRenewalDue = FacilityEndpoints.D(CollateralMath.NextRenewalDue((string)n.RenewalCycle, (DateTime)n.IssuedOn, (DateTime?)n.LastRenewedOn)),
                custody = (string)n.CustodyKind, signers,
            },
            insurance = i is null ? null : new
            {
                policyNo = (string)i.PolicyNo, insurer = (string)i.InsurerName, bank = (string)i.Bank, coverageBasis = (string)i.CoverageBasis, coveragePct = (decimal?)i.CoveragePct,
                coverageAmount = (decimal?)i.CoverageAmount, sumInsured = (decimal)i.SumInsured, currency = (string)i.Currency, policyStart = FacilityEndpoints.D((DateTime?)i.PolicyStart),
                policyExpiry = FacilityEndpoints.D((DateTime)i.PolicyExpiry), assignmentDate = FacilityEndpoints.D((DateTime?)i.AssignmentDate),
            },
            valuations = phases.Select(p => new
            {
                phaseNo = p.PhaseNo, fromYear = p.FromYear, toYear = p.ToYear, requiredValuerCount = p.Valuers, frequencyMonths = p.Freq, referenceDate = FacilityEndpoints.D(p.Ref),
                lastValuationOn = FacilityEndpoints.D(p.LastOn), lastValuationAmount = p.LastAmount,
            }),
            nextValuations = CollateralMath.Valuations(phaseList, DateTime.UtcNow.Date, DateTime.UtcNow.Date.AddYears(3)).Take(3)
                .Select(d => new { date = FacilityEndpoints.D(d.Date), phaseNo = d.PhaseNo, valuers = d.Valuers }),
            versions = versions.Select(x => new { id = x.Id, status = x.Status, approvalState = x.Approval, createdAt = x.CreatedAt }),
            facilities = links.Select(l => new { id = l.Facility, facilityNo = l.FacilityNo, linkedOn = FacilityEndpoints.D(l.LinkedOn), unlinkedOn = FacilityEndpoints.D(l.UnlinkedOn) }),
        });
    }

    /// <summary>A DRAFT version is corrected in place; an approved one is changed by a new version.</summary>
    private static async Task<IResult> ReplaceAsync(Guid id, CollateralRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var k = await FindAsync(u, tx, id, ct, lockRow: true);
        if (k.Status != "DRAFT") throw new ApiProblemException(409, "APPROVED_FINAL", "An approved collateral is changed by a new version (FR-COL-014).");
        var v = await ValuesAsync(u, tx, b, k, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE col.Collateral SET TitleAr = @title, Description = @desc, OwnerPartyId = @owner, Attributes = @attrs, CashMarginAccountId = @cash, GrantedOn = @granted,
                   SourceDocumentId = @doc, SourcePage = @page, ReadFromScan = @scan, OriginalText = @orig, NoSourceReason = @reason, Confidence = @conf,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CollateralId = @k;
            """, new
            {
                k = k.CollateralId, title = v.TitleAr, desc = v.Description, owner = v.Owner, attrs = v.Attributes, cash = v.CashAccount, granted = v.GrantedOn, doc = v.SourceDoc,
                page = v.SourcePage, scan = v.Scan, orig = v.Original, reason = v.NoSourceReason, conf = v.Confidence,
            }, tx, cancellationToken: ct));
        await WritePartsAsync(u, tx, k.CollateralId, v, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COLLATERAL_UPDATED", "TREASURY", "col.Collateral", k.CollateralId), null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>FR-COL-014: a change of an approved collateral is a new DRAFT of the same root; the approved version stays in force until it is approved.</summary>
    private static async Task<IResult> NewVersionAsync(Guid id, CollateralRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var k = await FindAsync(u, tx, id, ct, lockRow: true);
        if (k.ApprovalState != "APPROVED" || k.Status != "ACTIVE") throw new ApiProblemException(409, "V-COL-STATE", "Only the active approved version is changed by a new version.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM col.Collateral WHERE RootId = @r AND Status = 'DRAFT';", new { r = k.RootId }, tx,
                cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-COL-DRAFT-EXISTS", "The collateral already has a draft version.");
        var v = await ValuesAsync(u, tx, b, k, ct);
        var (newId, publicId) = await InsertAsync(u, tx, v, k, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COLLATERAL_VERSION_OPENED", "TREASURY", "col.Collateral", newId,
            AfterJson: JsonSerializer.Serialize(new { supersedes = k.PublicId })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/collaterals/{publicId}", new { id = publicId });
    }

    /// <summary>The required attributes of the template and the typed part of the structure (FR-COL-001, V-COL-01).</summary>
    private static async Task<List<string>> MissingAsync(BoundUser u, SqlTransaction tx, Row k, CancellationToken ct)
    {
        var missing = new List<string>();
        var attrs = k.Attributes is null ? [] : JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(k.Attributes) ?? [];
        foreach (var key in await u.Connection.QueryAsync<string>(new CommandDefinition(
                     "SELECT AttrKey FROM cat.CollateralTypeAttribute WHERE CollateralTypeId = @t AND IsRequired = 1 AND IsRetired = 0 ORDER BY SortOrder;", new { t = k.CollateralTypeId },
                     tx, cancellationToken: ct)))
            if (!attrs.TryGetValue(key, out var v) || v.ValueKind == JsonValueKind.Null || (v.ValueKind == JsonValueKind.String && string.IsNullOrWhiteSpace(v.GetString())))
                missing.Add(key);
        var part = k.StructureKind switch
        {
            "GUARANTEE" => "col.Guarantee",
            "PROMISSORY_NOTE" => "col.PromissoryNote",
            "INSURANCE_ASSIGNMENT" => "col.InsurancePolicyAssignment",
            _ => null,
        };
        if (part is not null && await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition($"SELECT COUNT(*) FROM {part} WHERE CollateralId = @k;", new { k = k.CollateralId }, tx,
                cancellationToken: ct)) == 0)
            missing.Add(k.StructureKind);
        if (k.StructureKind == "CASH_MARGIN" && !attrs.ContainsKey("MARGIN_PCT") && !attrs.ContainsKey("MARGIN_AMOUNT")) missing.Add("MARGIN");
        return missing;
    }

    /// <summary>
    /// FR-COL-014: a user with col.approve who did not prepare the version approves it (unless the tenant allows one
    /// person). The version it supersedes becomes SUPERSEDED first, as one approved version per root is current (003).
    /// </summary>
    private static async Task<IResult> ApproveAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Approve);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var k = await FindAsync(u, tx, id, ct, lockRow: true);
        if (k.Status != "DRAFT") throw new ApiProblemException(409, "V-COL-STATE", "Only a draft version is approved.");
        if ((k.CreatedBy == u.UserId || k.UpdatedBy == u.UserId) && !await FacilityRevisionEndpoints.SamePersonAllowedAsync(u, tx, ct))
            throw ApiProblemException.Forbidden("V-COL-SOD", "The preparer of a collateral version does not approve it.");
        if (await MissingAsync(u, tx, k, ct) is { Count: > 0 } missing)
            throw ApiProblemException.Invalid("V-COL-01", $"Complete the collateral before its approval: {string.Join(", ", missing)}.");
        if (k.SupersedesId is { } old)
        {
            var oldStatus = await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition("SELECT Status FROM col.Collateral WITH (UPDLOCK) WHERE CollateralId = @o;", new { o = old },
                tx, cancellationToken: ct));
            if (oldStatus != "ACTIVE") throw new ApiProblemException(409, "V-COL-STATE", "The version this one changes is no longer active.");
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE col.Collateral SET Status = 'SUPERSEDED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE CollateralId = @o;",
                new { o = old }, tx, cancellationToken: ct));
        }
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE col.Collateral SET Status = 'ACTIVE', ApprovalState = 'APPROVED', ApprovedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ApprovedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CollateralId = @k;
            """, new { k = k.CollateralId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COLLATERAL_APPROVED", "TREASURY", "col.Collateral", k.CollateralId,
            AfterJson: JsonSerializer.Serialize(new { supersedes = k.SupersedesId is not null })), null, ct);
        await Outbox.EmitAsync(u.Connection, tx, "collateral.changed", "col.Collateral", k.RootId, new { collateral = k.RootPublicId }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> DiscardAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var k = await FindAsync(u, tx, id, ct, lockRow: true);
        if (k.Status != "DRAFT") throw new ApiProblemException(409, "V-COL-STATE", "Only a draft version is discarded.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE col.Collateral SET Status = 'DISCARDED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE CollateralId = @k;",
            new { k = k.CollateralId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COLLATERAL_DISCARDED", "TREASURY", "col.Collateral", k.CollateralId), null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>FR-COL-010: a release has its date, its reason and its document (DR-36); the record stays and leaves the coverage from that date.</summary>
    private static async Task<IResult> ReleaseAsync(Guid id, CollateralReleaseRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var on = Date(b.ReleasedOn, "release date");
        if (on is null || string.IsNullOrWhiteSpace(b.Reason) || b.Document is null)
            throw ApiProblemException.Invalid("V-COL-RELEASE", "A release has its date, its reason and its document (FR-COL-010).");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var k = await FindAsync(u, tx, id, ct, lockRow: true);
        if (k.Status != "ACTIVE") throw new ApiProblemException(409, "V-COL-STATE", "Only an active collateral is released.");
        if (k.GrantedOn is { } granted && on < granted) throw ApiProblemException.Invalid("V-COL-RELEASE", "A collateral is released on or after it was granted.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM col.Collateral WHERE RootId = @r AND Status = 'DRAFT';", new { r = k.RootId }, tx,
                cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-COL-DRAFT-EXISTS", "Approve or discard the draft version of the collateral first.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE col.Collateral SET Status = 'RELEASED', ReleasedOn = @on, ReleaseReason = @reason, ReleaseDocumentId = @doc, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CollateralId = @k;
            """, new { k = k.CollateralId, on, reason = b.Reason.Trim(), doc = await DocAsync(u, tx, b.Document, ct) }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COLLATERAL_RELEASED", "TREASURY", "col.Collateral", k.CollateralId,
            AfterJson: JsonSerializer.Serialize(new { releasedOn = FacilityEndpoints.D(on), reason = b.Reason.Trim() })), null, ct);
        await Outbox.EmitAsync(u.Connection, tx, "collateral.released", "col.Collateral", k.RootId, new { collateral = k.RootPublicId }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>The yearly renewal of a note: an operational date of the approved version (062 lets LastRenewedOn change), audited.</summary>
    private static async Task<IResult> RecordRenewalAsync(Guid id, NoteRenewalRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var on = Date(b.RenewedOn, "renewal date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the renewal date.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var k = await FindAsync(u, tx, id, ct, lockRow: true);
        var n = await u.Connection.QuerySingleOrDefaultAsync<(long Id, DateTime IssuedOn, string Cycle, DateTime? Last)?>(new CommandDefinition(
            "SELECT PromissoryNoteId, IssuedOn, RenewalCycle, LastRenewedOn FROM col.PromissoryNote WHERE CollateralId = @k;", new { k = k.CollateralId }, tx, cancellationToken: ct))
            ?? throw new ApiProblemException(409, "V-COL-STATE", "The collateral is not a promissory note.");
        if (n.Cycle != "ANNUAL" || on < (n.Last ?? n.IssuedOn)) throw ApiProblemException.Invalid("V-COL-01", "A yearly note is renewed after its issue and its last renewal.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE col.PromissoryNote SET LastRenewedOn = @on, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE PromissoryNoteId = @n;",
            new { on, n = n.Id }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COLLATERAL_NOTE_RENEWED", "TREASURY", "col.Collateral", k.CollateralId,
            BeforeJson: JsonSerializer.Serialize(new { lastRenewedOn = FacilityEndpoints.D(n.Last) }), AfterJson: JsonSerializer.Serialize(new { lastRenewedOn = FacilityEndpoints.D(on) })),
            null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>FR-COL-008: a new valuation updates the last valuation of its phase, audited.</summary>
    private static async Task<IResult> RecordValuationAsync(Guid id, ValuationRecordRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var on = Date(b.On, "valuation date");
        if (on is null || b.Amount is null or <= 0 || string.IsNullOrWhiteSpace(b.Currency))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date, the amount and the currency of the valuation.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var k = await FindAsync(u, tx, id, ct, lockRow: true);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE col.ValuationSchedule SET LastValuationOn = @on, LastValuationAmount = @amount, CurrencyId = @cur, UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CollateralId = @k AND (PhaseNo = @phase OR (@phase IS NULL AND ToYear IS NULL));
            """, new { k = k.CollateralId, on, amount = b.Amount, cur = await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency, ct), phase = b.PhaseNo }, tx, cancellationToken: ct));
        if (n == 0) throw new ApiProblemException(409, "V-COL-STATE", "The collateral has no such valuation phase.");
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COLLATERAL_VALUED", "TREASURY", "col.Collateral", k.CollateralId,
            AfterJson: JsonSerializer.Serialize(new { on = FacilityEndpoints.D(on), amount = b.Amount, currency = b.Currency, phase = b.PhaseNo })), null, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- links through the facility revision (OQ-11) ----------

    private sealed class LinkRow
    {
        public long CollateralLinkId { get; init; }
        public long RootId { get; init; }
        public long CollateralRoot { get; init; }
        public Guid CollateralPublicId { get; init; }
        public string TitleAr { get; init; } = "";
        public string TypeCode { get; init; } = "";
        public string StructureKind { get; init; } = "";
        public long? LimitRootId { get; init; }
        public string? LimitCode { get; init; }
        public decimal? CoverageAmount { get; init; }
        public int? LienRank { get; init; }
        public DateTime LinkedOn { get; init; }
        public DateTime? UnlinkedOn { get; init; }
        public int FromRevision { get; init; }
    }

    /// <summary>The links of a revision (or of the draft, rev = int.MaxValue), with the root collateral's title and type.</summary>
    private static async Task<List<LinkRow>> LinkRowsAsync(SqlConnection c, SqlTransaction? tx, long facility, int rev, CancellationToken ct) =>
        [.. await c.QueryAsync<LinkRow>(new CommandDefinition(
            $"""
            SELECT l.CollateralLinkId, l.RootId, l.CollateralId AS CollateralRoot, r.PublicId AS CollateralPublicId, r.TitleAr, t.Code AS TypeCode, r.StructureKind,
                   lm.RootId AS LimitRootId, lm.Code AS LimitCode, l.CoverageAmount, l.LienRank, l.LinkedOn, l.UnlinkedOn, l.FromRevision
              FROM col.CollateralLink AS l
              JOIN col.Collateral AS r ON r.CollateralId = l.CollateralId
              JOIN cat.CollateralType AS t ON t.CollateralTypeId = r.CollateralTypeId
              LEFT JOIN fac.Limit AS lm ON lm.LimitId = l.LimitId
             WHERE l.FacilityId = @f AND {(rev == int.MaxValue ? "l.ToRevision IS NULL" : "l.FromRevision <= @rev AND (l.ToRevision IS NULL OR l.ToRevision > @rev)")}
             ORDER BY l.LinkedOn, l.CollateralLinkId;
            """, new { f = facility, rev }, tx, cancellationToken: ct)).ConfigureAwait(false)];

    private static async Task<IResult> LinksAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "view");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, View);
        await using var _ = u;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, http.RequestAborted);
        var draft = http.Request.Query["view"] == "draft";
        var rows = await LinkRowsAsync(u.Connection, null, f.FacilityId, draft ? int.MaxValue : f.ApprovedRevisionNo, http.RequestAborted);
        return Results.Ok(new
        {
            view = draft ? "draft" : "approved",
            items = rows.Select(l => new
            {
                id = refs.ItemRef(u.TenantId, "collateral-link", l.RootId), collateral = l.CollateralPublicId, titleAr = l.TitleAr, type = l.TypeCode, structure = l.StructureKind,
                limit = l.LimitRootId is { } lr ? refs.ItemRef(u.TenantId, "limit", lr) : null, limitCode = l.LimitCode, coverageAmount = l.CoverageAmount, lienRank = l.LienRank,
                linkedOn = FacilityEndpoints.D(l.LinkedOn), unlinkedOn = FacilityEndpoints.D(l.UnlinkedOn), fromRevision = l.FromRevision,
            }),
        });
    }

    /// <summary>A link is a row of the draft revision (OQ-11): it names the collateral by its root, and the limit by the draft's row of that limit.</summary>
    private static async Task<IResult> LinkAsync(Guid id, CollateralLinkRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        if (b.Collateral is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the collateral to link.");
        if (b.CoverageAmount is <= 0 || b.LienRank is < 1) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A coverage amount is above zero and a lien rank is 1 or more.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await LimitEndpoints.DraftAsync(u, tx, id, scope, ct);
        var k = await FindAsync(u, tx, b.Collateral.Value, ct);
        if (k.Status is "RELEASED" or "EXPIRED" or "DISCARDED") throw new ApiProblemException(409, "V-COL-STATE", "A released, expired or discarded collateral is not linked.");
        long? limit = null;
        string? limitCode = null;
        if (b.Limit is not null)
        {
            var root = refs.ItemId(u.TenantId, "limit", b.Limit);
            var l = d.Rows.Limits.FirstOrDefault(x => x.RootId == root) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The limit is not a limit of the facility.");
            (limit, limitCode) = (l.LimitId, l.Code);
        }
        var current = await LinkRowsAsync(u.Connection, tx, d.F.FacilityId, int.MaxValue, ct);
        if (current.Any(x => x.CollateralRoot == k.RootId && x.LimitRootId == (limit is null ? null : d.Rows.Limits.First(l => l.LimitId == limit).RootId) && x.UnlinkedOn is null))
            throw new ApiProblemException(409, "V-COL-LINKED", "The collateral is already linked here.");
        var linkedOn = Date(b.LinkedOn, "link date") ?? d.Rev.Header(d.F).Effective;
        var linkRoot = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (RootId BIGINT);
            INSERT col.CollateralLink (TenantId, CollateralId, FacilityId, LimitId, CoverageAmount, LienRank, LinkedOn, FromRevision, CreatedBy)
            OUTPUT inserted.RootId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @k, @f, @l, @amount, @rank, @on, @r, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT RootId FROM @o;
            """, new { k = k.RootId, f = d.F.FacilityId, l = limit, amount = b.CoverageAmount, rank = b.LienRank, on = linkedOn, r = d.Rev.RevisionNo }, tx, cancellationToken: ct));
        await LimitEndpoints.DoneAsync(u, tx, d, "COLLATERAL_LINKED", new { collateral = k.RootPublicId, limit = limitCode }, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/collateral-links", new { id = refs.ItemRef(u.TenantId, "collateral-link", linkRoot) });
    }

    /// <summary>FR-COL-002: unlinking sets UnlinkedOn on the draft's row; nothing is deleted.</summary>
    private static async Task<IResult> UnlinkAsync(Guid id, string reference, CollateralUnlinkRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await LimitEndpoints.DraftAsync(u, tx, id, scope, ct);
        var root = refs.ItemId(u.TenantId, "collateral-link", reference);
        var l = (await LinkRowsAsync(u.Connection, tx, d.F.FacilityId, int.MaxValue, ct)).FirstOrDefault(x => x.RootId == root) ?? throw ApiProblemException.NotFound();
        if (l.UnlinkedOn is not null) throw new ApiProblemException(409, "V-COL-STATE", "The link is already ended.");
        var on = Date(b.UnlinkedOn, "unlink date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date the link ends.");
        if (on < l.LinkedOn) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A link ends on or after it starts.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE col.CollateralLink SET UnlinkedOn = @on, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE CollateralLinkId = @id;",
            new { on, id = l.CollateralLinkId }, tx, cancellationToken: ct));
        await LimitEndpoints.DoneAsync(u, tx, d, "COLLATERAL_UNLINKED", new { collateral = l.CollateralPublicId, unlinkedOn = FacilityEndpoints.D(on) }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>A link added in this draft by mistake is voided; a link of the approved revision is ended by unlink instead.</summary>
    private static async Task<IResult> RemoveLinkAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await LimitEndpoints.DraftAsync(u, tx, id, scope, ct);
        var root = refs.ItemId(u.TenantId, "collateral-link", reference);
        var l = (await LinkRowsAsync(u.Connection, tx, d.F.FacilityId, int.MaxValue, ct)).FirstOrDefault(x => x.RootId == root) ?? throw ApiProblemException.NotFound();
        if (l.RootId != l.CollateralLinkId) throw new ApiProblemException(409, "V-COL-LINK-APPROVED", "An approved link is ended by unlinking it, with its date (FR-COL-002).");
        await LimitEndpoints.DeleteDraftRowAsync(u, tx, "col.CollateralLink", "CollateralLinkId", l.CollateralLinkId, ct);
        await LimitEndpoints.DoneAsync(u, tx, d, "COLLATERAL_LINK_REMOVED", new { collateral = l.CollateralPublicId }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>
    /// The revision check (FR-COL-013, Should): a linked collateral that is not approved yet, and a guarantor whose file
    /// is not complete against the profile of the facility's lead bank, are warnings, never a block.
    /// </summary>
    internal static async Task<List<(string Code, string Message)>> WarningsAsync(BoundUser u, SqlTransaction? tx, FacilityEndpoints.FacilityRow f, long? bank, CancellationToken ct)
    {
        var warnings = new List<(string, string)>();
        foreach (var l in (await LinkRowsAsync(u.Connection, tx, f.FacilityId, int.MaxValue, ct)).Where(l => l.UnlinkedOn is null))
        {
            if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                    "SELECT COUNT(*) FROM col.Collateral WHERE RootId = @r AND ApprovalState = 'APPROVED' AND Status = 'ACTIVE';", new { r = l.CollateralRoot }, tx, cancellationToken: ct)) == 0)
                warnings.Add(("V-COL-NOT-APPROVED", $"The collateral {l.TitleAr} has no active approved version; it does not count in the coverage."));
        }
        var guarantors = await u.Connection.QueryAsync<(long Party, string? NameAr, string? NameEn)>(new CommandDefinition(
            """
            SELECT DISTINCT g.GuarantorPartyId, p.NameAr, p.NameEn
              FROM col.CollateralLink AS l
              JOIN col.Collateral AS k ON k.RootId = l.CollateralId AND k.ApprovalState = 'APPROVED' AND k.Status = 'ACTIVE'
              JOIN col.Guarantee AS g ON g.CollateralId = k.CollateralId JOIN pty.Party AS p ON p.PartyId = g.GuarantorPartyId
             WHERE l.FacilityId = @f AND l.ToRevision IS NULL AND l.UnlinkedOn IS NULL;
            """, new { f = f.FacilityId }, tx, cancellationToken: ct));
        foreach (var g in guarantors)
        {
            var r = await KycEndpoints.EvaluateAsync(u.Connection, tx, g.Party, bank, "GUARANTOR", DateTime.UtcNow.Date, ct);
            if (r is { Result.Ready: false })
                warnings.Add(("V-COL-KYC", $"The file of the guarantor {g.NameAr ?? g.NameEn} is {r.Value.Result.Pct.ToString("0.#", CultureInfo.InvariantCulture)}% complete (FR-COL-013)."));
        }
        return warnings;
    }

    // ---------- coverage (R-COL-01) ----------

    private sealed class CovRow
    {
        public long CollateralId { get; init; }
        public long RootId { get; init; }
        public Guid PublicId { get; init; }
        public string TitleAr { get; init; } = "";
        public string StructureKind { get; init; } = "";
        public string TypeCode { get; init; } = "";
        public string Status { get; init; } = "";
        public DateTime? ReleasedOn { get; init; }
        public string? Attributes { get; init; }
        public string? CashMarginAccountMask { get; init; }
        public long? LimitRootId { get; init; }
        public string? LimitCode { get; init; }
    }

    /// <summary>
    /// R-COL-01 (BR-COL-006): the collateral in force on a date, by type, against the limits; nothing is added across
    /// types. A collateral counts when its current approved version is ACTIVE (or released after the date) and its link
    /// of the approved revision is in force on the date (BR-COL-005). Guarantees: the specified ones summed by currency
    /// and the unspecified ones counted; notes with their percent of the cap and next renewal; insurance with what it
    /// must cover, its percent and its shortfall; cash margins; property with its last valuation; set-off and negative
    /// pledge as flags.
    /// </summary>
    private static async Task<IResult> CoverageAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "asOf");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, ct);
        var asOf = Date(http.Request.Query["asOf"], "date") ?? DateTime.UtcNow.Date;
        var rev = f.ApprovedRevisionNo;
        var rows = await FacilityTreeStore.LoadAsync(u.Connection, null, f.FacilityId, rev, ct);
        var tree = rows.Tree(f.TotalAmount);
        decimal CapOf(long? limitRoot) => limitRoot is { } r ? tree.Cap(r) : f.TotalAmount;
        var roots = rows.Limits.Where(l => l.ParentRootId is null && l.DistributionMode != "OUTSIDE_TOTAL").ToList();
        var fullLimits = roots.Count == 0 ? f.TotalAmount : roots.Sum(l => tree.Cap(l.RootId));
        var items = (await u.Connection.QueryAsync<CovRow>(new CommandDefinition(
            """
            SELECT k.CollateralId, k.RootId, k.PublicId, k.TitleAr, k.StructureKind, t.Code AS TypeCode, k.Status, k.ReleasedOn, k.Attributes, a.AccountNoMask AS CashMarginAccountMask,
                   lm.RootId AS LimitRootId, lm.Code AS LimitCode
              FROM col.CollateralLink AS l
              JOIN col.Collateral AS k ON k.RootId = l.CollateralId AND k.ApprovalState = 'APPROVED' AND k.Status <> 'SUPERSEDED'
              JOIN cat.CollateralType AS t ON t.CollateralTypeId = k.CollateralTypeId
              LEFT JOIN acc.BankAccount AS a ON a.BankAccountId = k.CashMarginAccountId
              LEFT JOIN fac.Limit AS lm ON lm.LimitId = l.LimitId
             WHERE l.FacilityId = @f AND l.FromRevision <= @rev AND (l.ToRevision IS NULL OR l.ToRevision > @rev)
               AND l.LinkedOn <= @asOf AND (l.UnlinkedOn IS NULL OR l.UnlinkedOn > @asOf);
            """, new { f = f.FacilityId, rev, asOf }, cancellationToken: ct))).ToList();
        var inForce = items.Where(k => k.Status == "ACTIVE" || (k.Status == "RELEASED" && k.ReleasedOn > asOf)).ToList();
        var released = items.Where(k => k.Status == "RELEASED" && k.ReleasedOn <= asOf).ToList();
        var ids = inForce.Select(k => k.CollateralId).DefaultIfEmpty(-1).ToArray();

        var guarantees = (await u.Connection.QueryAsync<(long Collateral, Guid Party, string? NameAr, string? NameEn, string Kind, string Mode, decimal? Amount, string? Currency,
            DateTime? ValidTo, string? Mask, DateTime? IdExpiry)>(new CommandDefinition(
            """
            SELECT g.CollateralId, p.PublicId, p.NameAr, p.NameEn, p.Kind, g.AmountMode, g.Amount, cu.Code, g.ValidTo,
                   ISNULL(d.NumberMask, pd.NumberMask), ISNULL(pd.ExpiryDate, d.ExpiryDate)
              FROM col.Guarantee AS g JOIN pty.Party AS p ON p.PartyId = g.GuarantorPartyId LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = g.CurrencyId
              LEFT JOIN pty.IdentityDocument AS d ON d.IdentityDocumentId = g.GuarantorIdentityDocumentId
              OUTER APPLY (SELECT TOP (1) x.NumberMask, x.ExpiryDate FROM pty.IdentityDocument AS x WHERE x.PartyId = g.GuarantorPartyId AND x.IsPrimary = 1 AND x.IsSuperseded = 0) AS pd
             WHERE g.CollateralId IN @ids;
            """, new { ids }, cancellationToken: ct))).ToList();
        var inTime = guarantees.Where(g => g.ValidTo is null || g.ValidTo >= asOf).ToList();
        string Badge(DateTime? expiry) => expiry is null ? "MISSING" : expiry < asOf ? "EXPIRED" : expiry < asOf.AddDays(90) ? "EXPIRING" : "VALID";
        var notes = await u.Connection.QueryAsync<(long Collateral, decimal Amount, string Currency, DateTime IssuedOn, string Cycle, DateTime? Last)>(new CommandDefinition(
            "SELECT n.CollateralId, n.NoteAmount, cu.Code, n.IssuedOn, n.RenewalCycle, n.LastRenewedOn FROM col.PromissoryNote AS n JOIN ref.Currency AS cu ON cu.CurrencyId = n.CurrencyId WHERE n.CollateralId IN @ids;",
            new { ids }, cancellationToken: ct));
        var policies = await u.Connection.QueryAsync<(long Collateral, string PolicyNo, string Insurer, string Basis, decimal? Pct, decimal? Amount, decimal SumInsured, string Currency, DateTime Expiry)>(
            new CommandDefinition(
                """
                SELECT i.CollateralId, i.PolicyNo, i.InsurerName, i.CoverageBasis, i.CoveragePct, i.CoverageAmount, i.SumInsured, cu.Code, i.PolicyExpiry
                  FROM col.InsurancePolicyAssignment AS i JOIN ref.Currency AS cu ON cu.CurrencyId = i.CurrencyId WHERE i.CollateralId IN @ids;
                """, new { ids }, cancellationToken: ct));
        var valuations = (await u.Connection.QueryAsync<(long Collateral, DateTime? On, decimal? Amount, string? Currency)>(new CommandDefinition(
            """
            SELECT v.CollateralId, v.LastValuationOn, v.LastValuationAmount, cu.Code FROM col.ValuationSchedule AS v LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = v.CurrencyId
             WHERE v.CollateralId IN @ids AND v.LastValuationOn IS NOT NULL;
            """, new { ids }, cancellationToken: ct))).GroupBy(v => v.Collateral).ToDictionary(g => g.Key, g => g.OrderByDescending(v => v.On).First());
        var byId = inForce.ToDictionary(k => k.CollateralId);
        static JsonElement? Attr(string? json, string key) =>
            json is not null && JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json) is { } a && a.TryGetValue(key, out var v) && v.ValueKind != JsonValueKind.Null ? v : null;
        return Results.Ok(new
        {
            facility = f.PublicId, facilityNo = f.FacilityNo, currency = f.CurrencyCode, asOf = FacilityEndpoints.D(asOf), totalAmount = f.TotalAmount,
            guarantees = new
            {
                specified = inTime.Where(g => g.Mode == "SPECIFIED").GroupBy(g => g.Currency).Select(x => new { currency = x.Key, total = x.Sum(g => g.Amount ?? 0), count = x.Count() }),
                unspecifiedCount = inTime.Count(g => g.Mode == "UNSPECIFIED"),
                individualCount = inTime.Where(g => g.Kind == "INDIVIDUAL").Select(g => g.Party).Distinct().Count(),
                items = guarantees.Select(g => new
                {
                    collateral = byId[g.Collateral].PublicId, guarantor = new { id = g.Party, nameAr = g.NameAr, nameEn = g.NameEn, kind = g.Kind }, amountMode = g.Mode,
                    amount = g.Amount, currency = g.Currency, validTo = FacilityEndpoints.D(g.ValidTo), inForce = g.ValidTo is null || g.ValidTo >= asOf,
                    // FR-COL-004: the badge of the guarantor's documents, and the number masked for every reader; the full number is revealed on the party only.
                    identity = g.Mask, documents = Badge(g.IdExpiry),
                }),
            },
            notes = notes.Select(n => new
            {
                collateral = byId[n.Collateral].PublicId, amount = n.Amount, currency = n.Currency, limit = byId[n.Collateral].LimitCode,
                pctOfLimit = CollateralMath.NoteRatioPct(n.Amount, CapOf(byId[n.Collateral].LimitRootId)),
                nextRenewalDue = FacilityEndpoints.D(CollateralMath.NextRenewalDue(n.Cycle, n.IssuedOn, n.Last)),
            }),
            insurance = policies.Select(p =>
            {
                var c = CollateralMath.Insurance(p.Basis, p.Pct, p.Amount, CapOf(byId[p.Collateral].LimitRootId), fullLimits, p.SumInsured, p.Expiry, asOf);
                return new
                {
                    collateral = byId[p.Collateral].PublicId, policyNo = p.PolicyNo, insurer = p.Insurer, basis = p.Basis, required = c.Required, sumInsured = p.SumInsured,
                    currency = p.Currency, coveragePct = c.CoveragePct, shortfall = c.Shortfall, expiry = FacilityEndpoints.D(p.Expiry), expired = c.Expired,
                };
            }),
            cashMargins = inForce.Where(k => k.StructureKind == "CASH_MARGIN").Select(k => new
            {
                collateral = k.PublicId, titleAr = k.TitleAr, pct = Attr(k.Attributes, "MARGIN_PCT")?.GetDecimal(), amount = Attr(k.Attributes, "MARGIN_AMOUNT")?.GetDecimal(),
                account = k.CashMarginAccountMask,
            }),
            properties = inForce.Where(k => k.StructureKind == "REAL_ESTATE").Select(k => new
            {
                collateral = k.PublicId, titleAr = k.TitleAr, lastValuationOn = FacilityEndpoints.D(valuations.GetValueOrDefault(k.CollateralId).On),
                lastValuationAmount = valuations.GetValueOrDefault(k.CollateralId).Amount, currency = valuations.GetValueOrDefault(k.CollateralId).Currency,
            }),
            others = inForce.Where(k => k.StructureKind == "GENERIC").Select(k => new { collateral = k.PublicId, titleAr = k.TitleAr, type = k.TypeCode }),
            flags = new { setOff = inForce.Any(k => k.StructureKind == "SET_OFF"), negativePledge = inForce.Any(k => k.StructureKind == "NEGATIVE_PLEDGE") },
            released = released.Select(k => new { collateral = k.PublicId, titleAr = k.TitleAr, type = k.TypeCode, releasedOn = FacilityEndpoints.D(k.ReleasedOn) }),
        });
    }

    /// <summary>SVC-FAC-08: the guarantees a party gives, with their versions in force and the facilities that link them.</summary>
    private static async Task<IResult> GuaranteesAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var party = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT PartyId FROM pty.Party WHERE PublicId = @p;", new { p = id }, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        var scope = await CompanyScope.OfAsync(u, ct);
        var rows = await u.Connection.QueryAsync<(Guid Collateral, string TitleAr, string Status, string Mode, decimal? Amount, string? Currency, Guid? Facility, string? FacilityNo,
            long? Borrower, string? FacilityStatus)>(new CommandDefinition(
            """
            SELECT k.PublicId, k.TitleAr, k.Status, g.AmountMode, g.Amount, cu.Code, f.PublicId, ISNULL(f.PlatformRef, f.FacilityNo) AS FacilityNo, f.BorrowerCompanyId, f.LifecycleStatus
              FROM col.Guarantee AS g
              JOIN col.Collateral AS k ON k.CollateralId = g.CollateralId AND (k.Status = 'DRAFT' OR (k.ApprovalState = 'APPROVED' AND k.Status <> 'SUPERSEDED'))
              LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = g.CurrencyId
              LEFT JOIN col.CollateralLink AS l ON l.CollateralId = k.RootId AND l.UnlinkedOn IS NULL
              LEFT JOIN fac.Facility AS f ON f.FacilityId = l.FacilityId AND l.FromRevision <= f.ApprovedRevisionNo AND (l.ToRevision IS NULL OR l.ToRevision > f.ApprovedRevisionNo)
             WHERE g.GuarantorPartyId = @p
             ORDER BY k.RootId;
            """, new { p = party }, cancellationToken: ct));
        return Results.Ok(new
        {
            items = rows.GroupBy(r => r.Collateral).Select(g => new
            {
                collateral = g.Key, titleAr = g.First().TitleAr, status = g.First().Status, amountMode = g.First().Mode, amount = g.First().Amount, currency = g.First().Currency,
                facilities = g.Where(r => r.Facility is not null && scope.Allows(r.Borrower)).Select(r => new { id = r.Facility, facilityNo = r.FacilityNo, status = r.FacilityStatus }),
            }),
        });
    }
}

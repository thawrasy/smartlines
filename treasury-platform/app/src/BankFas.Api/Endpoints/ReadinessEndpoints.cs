using System.Data;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record LenderRatingRequest(Guid? Company, Guid? Lender, string? RatingDate, string? LenderGradeLabel, string? Grade, string? MappingKind, string? LenderReasons,
    Guid? SourceDocument, string? SourcePage, string? OriginalText, bool? ReadFromScan, string? NoSourceReason);
public sealed record EndorseRequest(string? Note);
public sealed record EvidencePackRequest(string? Purpose);
public sealed record LossRateRequest(string? Bucket, decimal? LossRatePct, string? EffectiveFrom, string? Note);

/// <summary>
/// The company's side before its lenders (spec 12 FR-FIN-037, 039 to 043, 045 to 048; BR-FIN-038 to 049; docs/31
/// decision 34; ADR 0024 to 0030, 0037). The database decides (049, 051, 052, 058); the application reads and asks:
/// the readiness file of an assessment (its lender dates within the lead time with RED, AMBER or GREEN, what the lender
/// will ask, the timeline of actions, and the warnings issued); the ratings a lender communicated beside the
/// assessment of their date, where they part, and the calibration over time; the endorsement for use outside the
/// company by someone outside the line (fin.usp_EndorseCreditAssessment judges, 50093), with the reasons a user may
/// not endorse shown before trying; the evidence pack of an endorsed assessment with its SHA-256; the loss rates of
/// the provision matrix, prepared and approved by two users, and the provision check of a statement.
/// </summary>
public static class ReadinessEndpoints
{
    private const string Endorse = "fin.credit.endorse";
    private const string RatingKind = "lender-rating";
    private const string RateKind = "loss-rate";
    private static readonly string[] Buckets = ["AR_AGE_0_90", "AR_AGE_91_180", "AR_AGE_181_365", "AR_AGE_OVER_365", "AR_AGE_OVER_365_GOV"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/fin/assessments/{id:guid}/readiness", ReadinessAsync);
        api.MapGet("/fin/assessments/{id:guid}/endorsement", EndorsementAsync);
        api.MapPost("/fin/assessments/{id:guid}/actions/endorse", EndorseAsync);
        api.MapPost("/fin/assessments/{id:guid}/actions/evidence-pack", EvidencePackAsync);
        api.MapGet("/fin/early-warnings", WarningsAsync);
        api.MapGet("/fin/lender-ratings", RatingsAsync);
        api.MapPost("/fin/lender-ratings", AddRatingAsync);
        api.MapGet("/fin/lender-ratings/{id}/gap-drivers", GapDriversAsync);
        api.MapPost("/fin/lender-ratings/{id}/actions/verify", VerifyRatingAsync);
        api.MapDelete("/fin/lender-ratings/{id}", RemoveRatingAsync);
        api.MapGet("/fin/calibration", CalibrationAsync);
        api.MapGet("/fin/loss-rates", RatesAsync);
        api.MapPost("/fin/loss-rates", AddRateAsync);
        api.MapPost("/fin/loss-rates/{id}/actions/approve", ApproveRateAsync);
        api.MapGet("/fin/provision-check", ProvisionAsync);
    }

    private static Guid? CompanyParam(HttpRequest r) =>
        r.Query["company"].Count == 0 ? null : Guid.TryParse(r.Query["company"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "company is an id.");

    private static async Task<long> CompanyAsync(BoundUser u, SqlTransaction? tx, Guid? company, CompanyScope scope, CancellationToken ct)
    {
        if (company is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the company.");
        var id = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT CompanyId FROM org.Company WHERE PublicId = @c;", new { c = company }, tx, cancellationToken: ct));
        return id is { } x && scope.Allows(x) ? x : throw ApiProblemException.NotFound();
    }

    // ---------- the readiness file and the warnings ----------

    /// <summary>FR-FIN-037: the readiness file of an assessment (the deep link of the early warnings, 051).</summary>
    private static async Task<IResult> ReadinessAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var a = await CreditEndpoints.FindAsync(u, null, id, scope, ct);
        using var grid = await u.Connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT * FROM fin.v_CreditReadinessEvents WHERE AssessmentId = @a ORDER BY EventDate, EventKind, RefId;
            SELECT * FROM fin.v_CreditReadinessRequests WHERE AssessmentId = @a ORDER BY Ord;
            SELECT * FROM fin.v_CreditReadinessActions WHERE AssessmentId = @a ORDER BY Phase, Ord;
            SELECT w.EventKind, w.RefId, w.EventDate, w.Stage, w.Readiness, w.ReasonCode, w.IssuedOn
              FROM fin.EarlyWarningAlert AS w WHERE w.CompanyId = @c ORDER BY w.IssuedOn DESC, w.EarlyWarningAlertId DESC;
            """, new { a = a.CreditAssessmentId, c = a.CompanyId }, cancellationToken: ct));
        var events = (await grid.ReadAsync()).ToList();
        var requests = (await grid.ReadAsync()).ToList();
        var actions = (await grid.ReadAsync()).ToList();
        var warnings = (await grid.ReadAsync()).ToList();
        return Results.Ok(new { events, requests, actions, warnings });
    }

    /// <summary>R-FIN-07: today's warnings across the companies in scope (fin.v_CreditEarlyWarnings).</summary>
    private static async Task<IResult> WarningsAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var company = CompanyParam(http.Request);
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT co.PublicId AS company, co.NameAr AS companyNameAr, a.PublicId AS assessment, w.EventKind AS eventKind, w.EventDate AS eventDate, w.DaysLeft AS daysLeft,
                   w.Stage AS stage, w.Readiness AS readiness, w.ReasonCode AS reasonCode, w.FinalGrade AS grade, w.LiquidityLabel AS liquidity
              FROM fin.v_CreditEarlyWarnings AS w
              JOIN org.Company AS co ON co.CompanyId = w.CompanyId
              JOIN fin.CreditAssessment AS a ON a.CreditAssessmentId = w.AssessmentId
             WHERE (@company IS NULL OR co.PublicId = @company) AND (@all = 1 OR w.CompanyId IN @ids)
             ORDER BY w.EventDate, co.NameAr;
            """, new { company, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    // ---------- endorsement and the evidence pack ----------

    private sealed record EndorseFacts(string Status, bool IsTrial, string Nature, long? PreparedBy, long? ApprovedBy, long? EndorsedBy, DateTime? EndorsedOn, string? EndorsementNote,
        string? EndorsedBias, long? StatementPreparedBy, long? StatementApprovedBy, long? ChosenBy);

    /// <summary>The reasons this user may not endorse the assessment (052:6-11), in the order the procedure checks them; empty when it may.</summary>
    private static async Task<(EndorseFacts Facts, List<string> Reasons)> EndorseReasonsAsync(BoundUser u, CreditEndpoints.Head a, CancellationToken ct)
    {
        var f = await u.Connection.QuerySingleAsync<EndorseFacts>(new CommandDefinition(
            """
            SELECT a.Status, a.IsTrial, s.Nature, a.PreparedBy, a.ApprovedBy, a.EndorsedBy, a.EndorsedOn, a.EndorsementNote, a.EndorsedBias,
                   s.PreparedBy AS StatementPreparedBy, s.ApprovedBy AS StatementApprovedBy,
                   (SELECT TOP (1) v.ChosenBy FROM fin.PresentationVersion AS v WHERE v.ResultStatementId = s.FinancialStatementId AND v.Status = 'CHOSEN') AS ChosenBy
              FROM fin.CreditAssessment AS a JOIN fin.FinancialStatement AS s ON s.FinancialStatementId = a.StatementId
             WHERE a.CreditAssessmentId = @a;
            """, new { a = a.CreditAssessmentId }, cancellationToken: ct));
        var perms = await u.PermissionsAsync(ct);
        var reasons = new List<string>();
        if (!perms.Contains(Endorse)) reasons.Add("The permission fin.credit.endorse is required.");
        if (perms.Contains(CreditEndpoints.Assess) || perms.Contains(CreditEndpoints.ApproveCredit))
            reasons.Add("The endorser is outside the line that prepares and approves assessments (holds neither fin.credit.assess nor fin.credit.approve).");
        if (f.Status != "APPROVED" || f.IsTrial || f.Nature != "ACTUAL") reasons.Add("Only an approved assessment of an actual statement is endorsed (a trial or a budget stays internal).");
        if (f.EndorsedBy is not null) reasons.Add("The assessment is already endorsed.");
        if (u.UserId == f.PreparedBy || u.UserId == f.ApprovedBy) reasons.Add("The endorser is neither the preparer nor the approver of the assessment.");
        if (u.UserId == f.StatementPreparedBy || u.UserId == f.StatementApprovedBy || u.UserId == f.ChosenBy)
            reasons.Add("The endorser neither prepared nor approved the statement, nor chose the presentation that became it.");
        return (f, reasons);
    }

    /// <summary>Whether the assessment is endorsed, and whether this user may endorse it and why not (BR-FIN-043).</summary>
    private static async Task<IResult> EndorsementAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var a = await CreditEndpoints.FindAsync(u, null, id, scope, ct);
        var (f, reasons) = await EndorseReasonsAsync(u, a, ct);
        return Results.Ok(new
        {
            endorsed = f.EndorsedBy is not null, endorsedOn = f.EndorsedOn, note = f.EndorsementNote, bias = f.EndorsedBias, useScope = f.EndorsedBy is null ? "INTERNAL_ONLY" : "ENDORSED",
            canEndorse = reasons.Count == 0, reasons,
        });
    }

    /// <summary>The database judges (fin.usp_EndorseCreditAssessment, 50093): any reader may ask, and the refusal says why.</summary>
    private static async Task<IResult> EndorseAsync(Guid id, EndorseRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var note = b.Note?.Trim();
        if (string.IsNullOrEmpty(note) || note.Length > 1000)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Say why and for whom the assessment is shown outside the company, at most 1,000 characters.");
        var a = await CreditEndpoints.FindAsync(u, null, id, scope, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition("fin.usp_EndorseCreditAssessment", new { AssessmentId = a.CreditAssessmentId, Note = note },
            commandType: CommandType.StoredProcedure, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("CREDIT_ASSESSMENT_ENDORSED", "TREASURY", "fin.CreditAssessment", a.CreditAssessmentId,
            AfterJson: JsonSerializer.Serialize(new { note })), a.CompanyId, ct);
        return Results.Ok(new { useScope = "ENDORSED" });
    }

    /// <summary>BR-FIN-049: the evidence pack of an endorsed assessment, logged with its SHA-256 (fin.usp_BuildAssessmentEvidencePack); the same content gives the same hash.</summary>
    private static async Task<IResult> EvidencePackAsync(Guid id, EvidencePackRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var purpose = b.Purpose?.Trim();
        if (string.IsNullOrEmpty(purpose) || purpose.Length > 500)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Name the purpose of the pack, for whom and why, at most 500 characters.");
        var perms = await u.PermissionsAsync(ct);
        if (!perms.Contains(Endorse) && !perms.Contains(CreditEndpoints.ApproveCredit)) throw ApiProblemException.Forbidden();
        var a = await CreditEndpoints.FindAsync(u, null, id, scope, ct);
        var p = new DynamicParameters();
        p.Add("@AssessmentId", a.CreditAssessmentId, DbType.Int64);
        p.Add("@Purpose", purpose, DbType.String, size: 500);
        p.Add("@Pack", null, DbType.String, ParameterDirection.Output, size: -1);
        p.Add("@Sha256", null, DbType.Binary, ParameterDirection.Output, size: 32);
        await u.Connection.ExecuteAsync(new CommandDefinition("fin.usp_BuildAssessmentEvidencePack", p, commandType: CommandType.StoredProcedure, commandTimeout: 120, cancellationToken: ct));
        var sha = Convert.ToHexString(p.Get<byte[]>("@Sha256"));
        using var pack = JsonDocument.Parse(p.Get<string>("@Pack"));
        return Results.Ok(new { sha256 = sha, pack = pack.RootElement.Clone() });
    }

    // ---------- lender ratings and the calibration ----------

    private sealed record RatingRow(long LenderRatingId, long CompanyId, long? CreatedBy, long? VerifiedBy, long? SourceDocumentId);

    private static async Task<RatingRow> RatingAsync(BoundUser u, SqlTransaction? tx, string reference, OpaqueRefs refs, CompanyScope scope, CancellationToken ct)
    {
        var id = refs.ItemId(u.TenantId, RatingKind, reference) ?? throw ApiProblemException.NotFound();
        var r = await u.Connection.QuerySingleOrDefaultAsync<RatingRow>(new CommandDefinition(
            "SELECT LenderRatingId, CompanyId, CreatedBy, VerifiedBy, SourceDocumentId FROM fin.LenderRating WHERE LenderRatingId = @id;", new { id }, tx, cancellationToken: ct));
        return r is not null && scope.Allows(r.CompanyId) ? r : throw ApiProblemException.NotFound();
    }

    /// <summary>FR-FIN-039: each rating beside the assessment of its date, with the gap in notches and its direction (fin.v_LenderRatingComparison).</summary>
    private static async Task<IResult> RatingsAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "company");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var company = CompanyParam(http.Request);
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT r.LenderRatingId, co.PublicId AS Company, co.NameAr AS CompanyNameAr, i.PublicId AS Lender, i.NameAr AS LenderNameAr, i.NameEn AS LenderNameEn, r.RatingDate,
                   r.LenderGradeLabel, r.LenderGrade, r.MappingKind, r.LenderReasons, x.PublicId AS Assessment, r.AssessmentDate, r.AssessmentGrade, r.GapNotches, r.Direction,
                   lr.Confidence, lr.SourcePage, d.PublicId AS SourceDocument, CAST(CASE WHEN lr.CreatedBy = @me THEN 1 ELSE 0 END AS BIT) AS EnteredByMe
              FROM fin.v_LenderRatingComparison AS r
              JOIN fin.LenderRating AS lr ON lr.LenderRatingId = r.LenderRatingId
              JOIN org.Company AS co ON co.CompanyId = r.CompanyId
              JOIN ins.Institution AS i ON i.InstitutionId = r.LenderInstitutionId
              LEFT JOIN fin.CreditAssessment AS x ON x.CreditAssessmentId = r.AssessmentId
              LEFT JOIN doc.Document AS d ON d.DocumentId = lr.SourceDocumentId
             WHERE (@company IS NULL OR co.PublicId = @company) AND (@all = 1 OR r.CompanyId IN @ids)
             ORDER BY r.RatingDate DESC, i.NameAr;
            """, new { company, me = u.UserId, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = rows.Select(r => new
            {
                id = refs.ItemRef(u.TenantId, RatingKind, (long)r.LenderRatingId), company = r.Company, companyNameAr = r.CompanyNameAr, lender = r.Lender, lenderNameAr = r.LenderNameAr,
                lenderNameEn = r.LenderNameEn, ratingDate = r.RatingDate, lenderGradeLabel = r.LenderGradeLabel, lenderGrade = r.LenderGrade, mappingKind = r.MappingKind,
                lenderReasons = r.LenderReasons, assessment = r.Assessment, assessmentDate = r.AssessmentDate, assessmentGrade = r.AssessmentGrade, gapNotches = r.GapNotches,
                direction = r.Direction, confidence = r.Confidence, sourcePage = r.SourcePage, sourceDocument = r.SourceDocument, enteredByMe = r.EnteredByMe,
            }),
        });
    }

    /// <summary>A rating the lender communicated, with its date, its source (the letter and page, or why there is none) and its mapping on the 21-step scale.</summary>
    private static async Task<IResult> AddRatingAsync(LenderRatingRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, CreditEndpoints.Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var on = LimitEndpoints.Date(b.RatingDate, "rating date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date of the rating.");
        var kind = (b.MappingKind ?? "GIVEN_BY_LENDER").Trim().ToUpperInvariant();
        if (kind is not ("GIVEN_BY_LENDER" or "MAPPED_BY_TREASURY")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The mapping is GIVEN_BY_LENDER or MAPPED_BY_TREASURY.");
        var label = b.LenderGradeLabel?.Trim();
        if (kind == "MAPPED_BY_TREASURY" && string.IsNullOrEmpty(label))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "A grade the treasury mapped keeps the lender's own label.");
        if (label?.Length > 40 || b.LenderReasons?.Length > 2000 || b.OriginalText?.Length > 2000 || b.SourcePage?.Length > 40 || b.NoSourceReason?.Length > 300)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "A field is longer than allowed.");
        if (b.SourceDocument is null && string.IsNullOrWhiteSpace(b.NoSourceReason))
            throw ApiProblemException.Invalid("V-SOURCE", "Give the lender's letter and its page, or the reason there is none (BR-FAC-018).");
        if (b.SourceDocument is not null && string.IsNullOrWhiteSpace(b.SourcePage)) throw ApiProblemException.Invalid("V-SOURCE", "Give the page of the letter.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var company = await CompanyAsync(u, tx, b.Company, scope, ct);
        var lender = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @l;", new { l = b.Lender }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The lender is an institution on file.");
        var grade = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT RatingGradeId FROM fin.RatingGrade WHERE Code = @g;", new { g = b.Grade?.Trim() }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The grade is a grade of the scale (Aaa to C).");
        long? doc = null;
        if (b.SourceDocument is { } d)
            doc = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE';", new { d }, tx,
                cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-SOURCE", "The letter is an active document on file.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM fin.LenderRating WHERE CompanyId = @company AND LenderInstitutionId = @lender AND RatingDate = @on;", new { company, lender, on }, tx,
                cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "DUPLICATE", "This lender's rating of the company on this date is already recorded.");
        var id = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT fin.LenderRating (TenantId, CompanyId, LenderInstitutionId, RatingDate, LenderGradeLabel, GradeId, MappingKind, LenderReasons, SourceDocumentId, SourcePage,
                                     ReadFromScan, OriginalText, NoSourceReason, Confidence, CreatedBy)
            OUTPUT inserted.LenderRatingId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @company, @lender, @on, @label, @grade, @kind, @reasons, @doc, @page, @scan, @text, @none,
                    CASE WHEN @doc IS NULL THEN 'ENTERED_NO_DOCUMENT' ELSE 'READ_FROM_SCAN_UNVERIFIED' END,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new
            {
                company, lender, on, label, grade, kind, reasons = b.LenderReasons?.Trim(), doc, page = doc is null ? null : b.SourcePage?.Trim(), scan = b.ReadFromScan == true,
                text = b.OriginalText?.Trim(), none = doc is null ? b.NoSourceReason?.Trim() : null,
            }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LENDER_RATING_RECORDED", "TREASURY", "fin.LenderRating", id), company, ct);
        await tx.CommitAsync(ct);
        var reference = refs.ItemRef(u.TenantId, RatingKind, id);
        return Results.Created($"/api/v1/fin/lender-ratings/{reference}", new { id = reference });
    }

    /// <summary>FR-FIN-039: where the lender and the assessment part (fin.v_LenderRatingGapDrivers).</summary>
    private static async Task<IResult> GapDriversAsync(string id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var r = await RatingAsync(u, null, id, refs, scope, ct);
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            "SELECT DriverKind, FactorCode, Code, NameAr, NameEn, AssessmentGrade, Weight, NotchesFromLender, Pull FROM fin.v_LenderRatingGapDrivers WHERE LenderRatingId = @r ORDER BY DriverKind, Pull DESC;",
            new { r = r.LenderRatingId }, cancellationToken: ct));
        return Results.Ok(new { items = rows });
    }

    /// <summary>Confirmed against the lender's letter by another holder of fin.credit.approve; a confirmed rating no longer changes (058).</summary>
    private static async Task<IResult> VerifyRatingAsync(string id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, CreditEndpoints.ApproveCredit, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await RatingAsync(u, tx, id, refs, scope, ct);
        if (r.VerifiedBy is not null) throw new ApiProblemException(409, "APPROVED_FINAL", "The rating is already confirmed against the lender's letter.");
        if (r.SourceDocumentId is null) throw ApiProblemException.Invalid("V-SOURCE", "Only a rating with the lender's letter on file is confirmed against it.");
        if (r.CreatedBy == u.UserId) throw ApiProblemException.Forbidden("V-FIN-SOD", "Another user confirms the rating against the letter.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.LenderRating SET Confidence = 'CONFIRMED_AGAINST_ORIGINAL', VerifiedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), VerifiedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE LenderRatingId = @r;
            """, new { r = r.LenderRatingId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LENDER_RATING_VERIFIED", "TREASURY", "fin.LenderRating", r.LenderRatingId), r.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { confidence = "CONFIRMED_AGAINST_ORIGINAL" });
    }

    /// <summary>A rating entered by mistake is removed while nothing froze it (a confirmation or an endorsed assessment's calibration, 50173).</summary>
    private static async Task<IResult> RemoveRatingAsync(string id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, CreditEndpoints.Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await RatingAsync(u, tx, id, refs, scope, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition("DELETE fin.LenderRating WHERE LenderRatingId = @r;", new { r = r.LenderRatingId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LENDER_RATING_REMOVED", "TREASURY", "fin.LenderRating", r.LenderRatingId), r.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>FR-FIN-043: the bias of the company's assessments against its lenders, over all of them and per lender (fin.v_LenderRatingCalibration).</summary>
    private static async Task<IResult> CalibrationAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var company = await CompanyAsync(u, null, CompanyParam(http.Request), scope, ct);
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT i.PublicId AS lender, i.NameAr AS lenderNameAr, c.AllLenders AS allLenders, c.Ratings AS ratings, c.FirstRatingDate AS firstRatingDate,
                   c.LastRatingDate AS lastRatingDate, c.MeanGapNotches AS meanGapNotches, c.RecentMeanGapNotches AS recentMeanGapNotches, c.LatestGapNotches AS latestGapNotches,
                   c.LenderMoreSevere AS lenderMoreSevere, c.LenderMoreFavourable AS lenderMoreFavourable, c.Same AS same, c.Bias AS bias
              FROM fin.v_LenderRatingCalibration AS c LEFT JOIN ins.Institution AS i ON i.InstitutionId = c.LenderInstitutionId
             WHERE c.CompanyId = @company ORDER BY c.AllLenders DESC, i.NameAr;
            """, new { company }, cancellationToken: ct));
        return Results.Ok(new { items = rows });
    }

    // ---------- the provision matrix ----------

    private sealed record RateRow(int ReceivableLossRateId, string BucketCode, decimal LossRatePct, DateTime EffectiveFrom, string Status, long? PreparedBy, long? ApprovedBy,
        DateTime? ApprovedOn, string? Note, string? SeedKey);

    private static async Task<IResult> RatesAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, _) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var __ = u;
        var rows = await u.Connection.QueryAsync<RateRow>(new CommandDefinition(
            "SELECT ReceivableLossRateId, BucketCode, LossRatePct, EffectiveFrom, Status, PreparedBy, ApprovedBy, ApprovedOn, Note, SeedKey FROM fin.ReceivableLossRate ORDER BY BucketCode, EffectiveFrom DESC;",
            cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = rows.Select(r => new
            {
                id = refs.ItemRef(u.TenantId, RateKind, r.ReceivableLossRateId), bucket = r.BucketCode, lossRatePct = r.LossRatePct, effectiveFrom = r.EffectiveFrom.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture),
                status = r.Status, approvedOn = r.ApprovedOn, note = r.Note, fromPack = r.SeedKey is not null, preparedByMe = r.PreparedBy == u.UserId,
            }),
        });
    }

    /// <summary>A draft rate of a bucket from a date, prepared by a holder of fin.formula.manage; a change of an approved rate is a rate with a later date (058).</summary>
    private static async Task<IResult> AddRateAsync(LossRateRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, _) = await FinanceAccess.OpenAsync(http, db, "fin.formula.manage", statements: false);
        await using var __ = u;
        var ct = http.RequestAborted;
        var bucket = b.Bucket?.Trim().ToUpperInvariant();
        if (bucket is null || !Buckets.Contains(bucket)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The bucket is one of the ageing of the receivables.");
        if (b.LossRatePct is not (>= 0 and <= 100)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The loss rate is from 0 to 100 percent.");
        var from = LimitEndpoints.Date(b.EffectiveFrom, "effective date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date the rate applies from.");
        if (b.Note?.Length > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The note has at most 500 characters.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM fin.ReceivableLossRate WHERE BucketCode = @bucket AND EffectiveFrom = @from;",
                new { bucket, from }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "DUPLICATE", "A rate of this bucket from this date exists; give another date.");
        var id = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id INT);
            INSERT fin.ReceivableLossRate (TenantId, BucketCode, LossRatePct, EffectiveFrom, Status, PreparedBy, Note, CreatedBy)
            OUTPUT inserted.ReceivableLossRateId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @bucket, @pct, @from, 'DRAFT', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), @note, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new { bucket, pct = b.LossRatePct, from, note = b.Note?.Trim() }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LOSS_RATE_PREPARED", "TREASURY", "fin.ReceivableLossRate", id), null, ct);
        await tx.CommitAsync(ct);
        var reference = refs.ItemRef(u.TenantId, RateKind, id);
        return Results.Created($"/api/v1/fin/loss-rates/{reference}", new { id = reference });
    }

    /// <summary>Approved as prepared by another holder of fin.formula.approve (058, 50170 to 50172).</summary>
    private static async Task<IResult> ApproveRateAsync(string id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, _) = await FinanceAccess.OpenAsync(http, db, "fin.formula.approve", statements: false);
        await using var __ = u;
        var ct = http.RequestAborted;
        var rid = refs.ItemId(u.TenantId, RateKind, id) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await u.Connection.QuerySingleOrDefaultAsync<RateRow>(new CommandDefinition(
            "SELECT ReceivableLossRateId, BucketCode, LossRatePct, EffectiveFrom, Status, PreparedBy, ApprovedBy, ApprovedOn, Note, SeedKey FROM fin.ReceivableLossRate WITH (UPDLOCK) WHERE ReceivableLossRateId = @rid;",
            new { rid }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (r.Status != "DRAFT") throw new ApiProblemException(409, "APPROVED_FINAL", "The rate is already approved.");
        if (r.PreparedBy == u.UserId) throw ApiProblemException.Forbidden("V-FIN-SOD", "The preparer of a rate does not approve it; another user does.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.ReceivableLossRate SET Status = 'APPROVED', ApprovedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ApprovedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE ReceivableLossRateId = @rid;
            """, new { rid }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LOSS_RATE_APPROVED", "TREASURY", "fin.ReceivableLossRate", rid), null, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "APPROVED" });
    }

    /// <summary>FR-FIN-048: the allowance the loss rates give beside the one each statement records (fin.v_ReceivableProvisionCheck).</summary>
    private static async Task<IResult> ProvisionAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company", "statement");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var q = http.Request.Query;
        var company = CompanyParam(http.Request);
        Guid? statement = q["statement"].Count > 0 ? (Guid.TryParse(q["statement"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "statement is an id.")) : null;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT s.PublicId AS statement, co.PublicId AS company, co.NameAr AS companyNameAr, p.PeriodEnd AS periodEnd, p.Age0_90 AS age0To90, p.Age91_180 AS age91To180,
                   p.Age181_365 AS age181To365, p.AgeOver365 AS ageOver365, p.AgeOver365Gov AS ageOver365Gov, p.RecordedAllowance AS recordedAllowance,
                   p.ExpectedAllowance AS expectedAllowance, p.Shortfall AS shortfall, p.RatesStatus AS ratesStatus, p.Status AS status
              FROM fin.v_ReceivableProvisionCheck AS p
              JOIN fin.FinancialStatement AS s ON s.FinancialStatementId = p.StatementId
              JOIN org.Company AS co ON co.CompanyId = p.CompanyId
             WHERE (@company IS NULL OR co.PublicId = @company) AND (@statement IS NULL OR s.PublicId = @statement) AND (@all = 1 OR p.CompanyId IN @ids)
             ORDER BY p.PeriodEnd DESC, co.NameAr;
            """, new { company, statement, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }
}

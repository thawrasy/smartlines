using System.Data;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record AssessmentRequest(Guid? Statement, string? Scorecard, string? AssessmentDate, Guid? PriorStatement, decimal? FxRate, bool? IsTrial,
    bool? StrengtheningRequested, string? MarketCountry, string? MarketRegion);
public sealed record AssessmentInputRequest(string? Kind, string? Metric, string? Subfactor, string? Grade, int? Notches, Guid? ParentAssessment, decimal? Amount,
    string? Currency, decimal? Rate, string? EvidenceCode, string? Justification, Guid? Document);
public sealed record AssessmentReasonRequest(string? Reason);
public sealed record PresentationStepRequest(string? Remedy, decimal? ScalePct, Guid? Document, string? EvidenceDate, string? Justification);
public sealed record PresentationVersionRequest(Guid? SourceStatement, Guid? SourceAssessment, string? NameAr, string? Note, PresentationStepRequest[]? Steps);

/// <summary>
/// The credit self-assessment of a balance sheet (spec 12 FR-FIN-020 to 036, 038, 044; BR-FIN-018 to 024, 036, 037;
/// docs/35; ADR 0017, 0022, 0023, 0037). The database holds the methodology and computes (046 to 048); the application
/// wraps it: an assessment is a draft of a holder of fin.credit.assess on an approved statement (a trial on a draft or
/// submitted one, which stays a draft) with the analyst's inputs, each justified; fin.usp_ComputeCreditAssessment runs on
/// its own command and writes the results; it is submitted only computed on what it holds now (a change of anything it
/// read, a covenant test included, asks for a new computation, 50063), and approved or returned by a holder of
/// fin.credit.approve who did not prepare it. The report is the database's views, in Arabic and English. A
/// presentation version applies remedies the company chose to a statement before its approval, built and chosen by
/// the database's procedures, the choice with its reason by someone other than the preparer.
/// </summary>
public static class CreditEndpoints
{
    private const string Assess = "fin.credit.assess";
    private const string ApproveCredit = "fin.credit.approve";

    private static readonly Dictionary<string, (string View, string Key)> Parts = new(StringComparer.Ordinal)
    {
        ["factors"] = ("fin.v_CreditAssessmentFactors", "AssessmentId"), ["findings"] = ("fin.v_CreditAssessmentFindings", "AssessmentId"),
        ["items"] = ("fin.v_CreditAssessmentItems", "AssessmentId"), ["item-register"] = ("fin.v_CreditAssessmentItemRegister", "AssessmentId"),
        ["reclass"] = ("fin.v_CreditAssessmentReclass", "AssessmentId"), ["remedies"] = ("fin.v_CreditAssessmentRemedies", "AssessmentId"),
        ["scenarios"] = ("fin.v_CreditAssessmentScenarios", "AssessmentId"), ["facilities"] = ("fin.v_CreditAssessmentFacilities", "AssessmentId"),
        ["plans"] = ("fin.v_CreditAssessmentPlans", "AssessmentId"), ["triggers"] = ("fin.v_CreditAssessmentTriggers", "AssessmentId"),
        ["covenants"] = ("fin.v_CreditAssessmentCovenants", "AssessmentId"), ["group-units"] = ("fin.v_CreditAssessmentGroupUnits", "AssessmentId"),
    };

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/fin/scorecards", ScorecardsAsync);
        api.MapGet("/fin/assessments", ListAsync);
        api.MapPost("/fin/assessments", CreateAsync);
        api.MapGet("/fin/assessments/{id:guid}", GetAsync);
        api.MapGet("/fin/assessments/{id:guid}/report/{part}", PartAsync);
        api.MapPost("/fin/assessments/{id:guid}/inputs", AddInputAsync);
        api.MapDelete("/fin/assessments/{id:guid}/inputs/{input:long}", RemoveInputAsync);
        api.MapPost("/fin/assessments/{id:guid}/actions/compute", ComputeAsync);
        api.MapPost("/fin/assessments/{id:guid}/actions/submit", SubmitAsync);
        api.MapPost("/fin/assessments/{id:guid}/actions/approve", ApproveAsync);
        api.MapPost("/fin/assessments/{id:guid}/actions/reject", RejectAsync);
        api.MapPost("/fin/assessments/{id:guid}/actions/reopen", ReopenAsync);
        api.MapGet("/financial-statements/{id:guid}/item-analysis", ItemAnalysisAsync);
        api.MapGet("/fin/budget-comparison", BudgetAsync);
        api.MapGet("/fin/presentation-versions", VersionsAsync);
        api.MapPost("/fin/presentation-versions", CreateVersionAsync);
        api.MapPost("/fin/presentation-versions/{id:guid}/actions/build", BuildVersionAsync);
        api.MapPost("/fin/presentation-versions/{id:guid}/actions/choose", ChooseVersionAsync);
    }

    internal sealed record Head(long CreditAssessmentId, Guid PublicId, long CompanyId, long StatementId, string Status, bool IsTrial, string? ResultState, long? PreparedBy,
        DateTime? ComputedAt);

    internal static async Task<Head> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct, bool lockRow = false)
    {
        var a = await u.Connection.QuerySingleOrDefaultAsync<Head>(new CommandDefinition(
            $"SELECT CreditAssessmentId, PublicId, CompanyId, StatementId, Status, IsTrial, ResultState, PreparedBy, ComputedAt FROM fin.CreditAssessment{(lockRow ? " WITH (UPDLOCK, HOLDLOCK)" : "")} WHERE PublicId = @id;",
            new { id }, tx, cancellationToken: ct));
        return a is not null && scope.Allows(a.CompanyId) ? a : throw ApiProblemException.NotFound();
    }

    private static async Task<IResult> ScorecardsAsync(HttpContext http, SqlConnectionFactory db)
    {
        var (u, _) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var __ = u;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT s.Code AS code, s.VersionNo AS versionNo, s.NameAr AS nameAr, s.NameEn AS nameEn, c.Code AS currency
              FROM fin.Scorecard AS s JOIN ref.Currency AS c ON c.CurrencyId = s.CurrencyId WHERE s.Status = 'APPROVED' ORDER BY s.Code;
            """, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var q = http.Request.Query;
        Guid? company = q["company"].Count > 0 ? (Guid.TryParse(q["company"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "company is an id.")) : null;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT a.PublicId AS id, co.PublicId AS company, co.NameAr AS companyNameAr, s.PublicId AS statement, s.PeriodEnd AS periodEnd, s.Basis AS basis,
                   a.AssessmentDate AS assessmentDate, sc.Code AS scorecard, a.Status AS status, a.IsTrial AS isTrial, a.ResultState AS resultState,
                   g.Code AS finalGrade, fg.Code AS financialGrade, a.ComputedAt AS computedAt
              FROM fin.CreditAssessment AS a
              JOIN org.Company AS co ON co.CompanyId = a.CompanyId
              JOIN fin.FinancialStatement AS s ON s.FinancialStatementId = a.StatementId
              JOIN fin.Scorecard AS sc ON sc.ScorecardId = a.ScorecardId
              LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = a.FinalGradeId
              LEFT JOIN fin.RatingGrade AS fg ON fg.RatingGradeId = a.FinancialGradeId
             WHERE (@company IS NULL OR co.PublicId = @company) AND (@all = 1 OR a.CompanyId IN @ids)
             ORDER BY a.AssessmentDate DESC, co.NameAr;
            """, new { company, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    /// <summary>A draft on an approved statement, or a trial on one before its approval (BR-FIN-036); the scorecard by its code, the latest approved version.</summary>
    private static async Task<IResult> CreateAsync(AssessmentRequest b, HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Statement is null || string.IsNullOrWhiteSpace(b.Scorecard)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the statement and the scorecard.");
        var on = LimitEndpoints.Date(b.AssessmentDate, "assessment date") ?? clock.GetUtcNow().UtcDateTime.Date;
        if (b.FxRate is <= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The rate is above zero.");
        var trial = b.IsTrial ?? false;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await StatementEndpoints.FindAsync(u, tx, b.Statement.Value, scope, ct);
        if (trial ? s.Status is not ("DRAFT" or "SUBMITTED") : s.Status != "APPROVED")
            throw ApiProblemException.Invalid("V-FIN-ASSESSMENT", trial ? "A trial reads a statement before its approval (a draft or a submitted one)." : "An assessment reads an approved statement; a draft is assessed as a trial.");
        var card = await u.Connection.QuerySingleOrDefaultAsync<(int Id, int Currency)?>(new CommandDefinition(
            "SELECT TOP (1) ScorecardId, CurrencyId FROM fin.Scorecard WHERE Code = @c AND Status = 'APPROVED' ORDER BY VersionNo DESC;", new { c = b.Scorecard.Trim().ToUpperInvariant() },
            tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The scorecard is an approved scorecard of the methodology.");
        if (card.Currency != s.CurrencyId && b.FxRate is null)
            throw ApiProblemException.Invalid("V-FIN-ASSESSMENT", "The statement's currency is not the scorecard's: give the rate (BR-FIN-019).");
        long? prior = null;
        if (b.PriorStatement is { } p)
        {
            var ps = await StatementEndpoints.FindAsync(u, tx, p, scope, ct);
            if (ps.CompanyId != s.CompanyId || ps.Basis != s.Basis || ps.Status != "APPROVED" || ps.PeriodEnd >= s.PeriodEnd)
                throw ApiProblemException.Invalid("V-FIN-ASSESSMENT", "The comparison is an approved, earlier statement of the same company and basis.");
            prior = ps.FinancialStatementId;
        }
        int? country = b.MarketCountry is null ? null : await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT CountryId FROM ref.Country WHERE Iso2 = @c;", new { c = b.MarketCountry.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The market country is an ISO country code.");
        var made = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT fin.CreditAssessment (TenantId, CompanyId, StatementId, PriorStatementId, ScorecardId, AssessmentDate, FxRateToScorecard, StrengtheningRequested, IsTrial,
                                         MarketCountryId, MarketRegionCode, PreparedBy, CreatedBy)
            OUTPUT inserted.CreditAssessmentId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @s, @prior, @card, @on, @fx, @strength, @trial, @country, @region, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new
        {
            c = s.CompanyId, s = s.FinancialStatementId, prior, card = card.Id, on, fx = b.FxRate, strength = b.StrengtheningRequested ?? false, trial, country,
            region = b.MarketRegion?.Trim().ToUpperInvariant(),
        }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("CREDIT_ASSESSMENT_CREATED", "TREASURY", "fin.CreditAssessment", made.Id,
            AfterJson: JsonSerializer.Serialize(new { scorecard = b.Scorecard, trial, assessmentDate = FacilityEndpoints.D(on) })), s.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/fin/assessments/{made.PublicId}", new { id = made.PublicId });
    }

    /// <summary>The report header (fin.v_CreditAssessmentReport) and the analyst's inputs.</summary>
    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var a = await FindAsync(u, null, id, scope, ct);
        var report = await u.Connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            "SELECT * FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;", new { a = a.CreditAssessmentId }, cancellationToken: ct));
        var inputs = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT i.CreditAssessmentInputId AS id, i.Kind AS kind, m.Code AS metric, sf.Code AS subfactor, g.Code AS grade, i.Notches AS notches, i.Amount AS amount,
                   cu.Code AS currency, i.Rate AS rate, i.EvidenceCode AS evidenceCode, i.Justification AS justification, d.PublicId AS document
              FROM fin.CreditAssessmentInput AS i
              LEFT JOIN fin.CreditMetric AS m ON m.CreditMetricId = i.MetricId
              LEFT JOIN fin.ScorecardSubfactor AS sf ON sf.ScorecardSubfactorId = i.SubfactorId
              LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = i.GradeId
              LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = i.CurrencyId
              LEFT JOIN doc.Document AS d ON d.DocumentId = i.DocumentId
             WHERE i.AssessmentId = @a ORDER BY i.Kind, m.Code;
            """, new { a = a.CreditAssessmentId }, cancellationToken: ct));
        return Results.Ok(new { id = a.PublicId, status = a.Status, isTrial = a.IsTrial, preparedByMe = a.PreparedBy == u.UserId, report, inputs });
    }

    private static async Task<IResult> PartAsync(Guid id, string part, HttpContext http, SqlConnectionFactory db)
    {
        if (!Parts.TryGetValue(part, out var view)) throw ApiProblemException.NotFound();
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var a = await FindAsync(u, null, id, scope, http.RequestAborted);
        var rows = await u.Connection.QueryAsync(new CommandDefinition($"SELECT * FROM {view.View} WHERE {view.Key} = @a;", new { a = a.CreditAssessmentId },
            cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    private static void Draft(Head a)
    {
        if (a.Status != "DRAFT") throw new ApiProblemException(409, "ASSESSMENT_STATE", "An assessment changes only as a draft; a returned one is reopened first.");
    }

    /// <summary>An input of the analyst (BR-FIN-021, 022): one per factor, sub-factor, currency or evidence, replaced when given again; each justified.</summary>
    private static async Task<IResult> AddInputAsync(Guid id, AssessmentInputRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var kind = b.Kind?.Trim().ToUpperInvariant();
        if (kind is not ("QUALITATIVE" or "SUBFACTOR" or "GROUP_SUPPORT" or "OVERRIDE" or "MARKET_SIZE" or "FX_RATE" or "EVIDENCE"))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The kind is QUALITATIVE, SUBFACTOR, GROUP_SUPPORT, OVERRIDE, MARKET_SIZE, FX_RATE or EVIDENCE.");
        var why = b.Justification?.Trim();
        if (string.IsNullOrEmpty(why) || why.Length < 10 || why.Length > 1000) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Justify the input in 10 to 1,000 characters.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var a = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        Draft(a);
        int? metric = null, subfactor = null, grade = null, currency = null;
        long? parent = null, document = null;
        if (kind is "QUALITATIVE" or "SUBFACTOR")
        {
            metric = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CreditMetricId FROM fin.CreditMetric WHERE Code = @m;",
                new { m = b.Metric?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The factor is a metric of the methodology.");
            grade = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT RatingGradeId FROM fin.RatingGrade WHERE Code = @g;", new { g = b.Grade?.Trim() }, tx,
                cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The grade is a grade of the scale (Aaa to C).");
            if (kind == "SUBFACTOR")
                subfactor = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition(
                    "SELECT sf.ScorecardSubfactorId FROM fin.ScorecardSubfactor AS sf JOIN fin.CreditAssessment AS a ON a.ScorecardId = sf.ScorecardId WHERE a.CreditAssessmentId = @a AND sf.Code = @c;",
                    new { a = a.CreditAssessmentId, c = b.Subfactor?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
                    ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The sub-factor is one of the assessment's scorecard.");
        }
        if (kind == "GROUP_SUPPORT")
        {
            var p = await FindAsync(u, tx, b.ParentAssessment ?? Guid.Empty, scope, ct);
            parent = p.CreditAssessmentId;
        }
        if (kind == "FX_RATE") currency = await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency ?? "", ct);
        if (b.Document is { } d)
            document = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE' AND OwnerCompanyId = @c;", new { d, c = a.CompanyId }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is an active document of the assessed company.");
        var evidence = kind == "EVIDENCE" ? b.EvidenceCode?.Trim().ToUpperInvariant() : null;
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            DELETE fin.CreditAssessmentInput
             WHERE AssessmentId = @a AND Kind = @kind AND ISNULL(MetricId, -1) = ISNULL(@metric, -1) AND ISNULL(SubfactorId, -1) = ISNULL(@sub, -1)
               AND ISNULL(CurrencyId, -1) = ISNULL(@cur, -1) AND ISNULL(EvidenceCode, '') = ISNULL(@ev, '');
            INSERT fin.CreditAssessmentInput (TenantId, AssessmentId, Kind, MetricId, SubfactorId, Amount, CurrencyId, Rate, EvidenceCode, GradeId, Notches, ParentAssessmentId,
                                              Justification, DocumentId, EnteredBy, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @a, @kind, @metric, @sub, @amount, @cur, @rate, @ev, @grade, @notches, @parent, @why, @doc,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new
        {
            a = a.CreditAssessmentId, kind, metric, sub = subfactor, amount = kind == "MARKET_SIZE" ? b.Amount : null, cur = currency, rate = kind == "FX_RATE" ? b.Rate : null,
            ev = evidence, grade, notches = kind is "GROUP_SUPPORT" or "OVERRIDE" ? b.Notches : null, parent, why, doc = document,
        }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> RemoveInputAsync(Guid id, long input, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var a = await FindAsync(u, null, id, scope, ct);
        Draft(a);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition("DELETE fin.CreditAssessmentInput WHERE CreditAssessmentInputId = @i AND AssessmentId = @a;",
            new { i = input, a = a.CreditAssessmentId }, cancellationToken: ct));
        return n == 0 ? throw ApiProblemException.NotFound() : Results.NoContent();
    }

    /// <summary>The computation runs on its own command: the procedure owns its transaction (§0.1 item 7).</summary>
    private static async Task<IResult> ComputeAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var a = await FindAsync(u, null, id, scope, ct);
        Draft(a);
        await u.Connection.ExecuteAsync(new CommandDefinition("fin.usp_ComputeCreditAssessment", new { AssessmentId = a.CreditAssessmentId },
            commandType: CommandType.StoredProcedure, commandTimeout: 120, cancellationToken: ct));
        var head = await u.Connection.QuerySingleAsync(new CommandDefinition(
            "SELECT ResultState AS resultState, FinalGrade AS finalGrade, FinancialGrade AS financialGrade FROM fin.v_CreditAssessmentReport WHERE CreditAssessmentId = @a;",
            new { a = a.CreditAssessmentId }, cancellationToken: ct));
        return Results.Ok(head);
    }

    /// <summary>BR-FIN-024: a rated, non-trial draft, computed on what it holds now, submitted by an assessor who becomes its preparer.</summary>
    private static async Task<IResult> SubmitAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var a = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        Draft(a);
        if (a.IsTrial) throw new ApiProblemException(409, "ASSESSMENT_STATE", "A trial assessment stays a draft: it is computed again, not submitted (BR-FIN-036).");
        if (a.ResultState != "RATED")
            throw ApiProblemException.Invalid("V-FIN-ASSESSMENT", a.ResultState is null ? "Compute the assessment before submitting it." : "An assessment is submitted with a grade: grade its qualitative factors and compute it again.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.CreditAssessment SET Status = 'SUBMITTED', PreparedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), PreparedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CreditAssessmentId = @a;
            """, new { a = a.CreditAssessmentId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("CREDIT_ASSESSMENT_SUBMITTED", "TREASURY", "fin.CreditAssessment", a.CreditAssessmentId), a.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "SUBMITTED" });
    }

    /// <summary>Approved by another holder of fin.credit.approve; the approved assessment of the same statement is superseded first (one per statement).</summary>
    private static async Task<IResult> ApproveAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, ApproveCredit, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var a = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (a.Status != "SUBMITTED") throw new ApiProblemException(409, "ASSESSMENT_STATE", "Only a submitted assessment is approved.");
        if (a.PreparedBy == u.UserId) throw ApiProblemException.Forbidden("V-FIN-SOD", "The preparer of an assessment does not approve it; another user does (BR-FIN-024).");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.CreditAssessment SET Status = 'SUPERSEDED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE StatementId = @s AND Status = 'APPROVED' AND CreditAssessmentId <> @a;
            UPDATE fin.CreditAssessment SET Status = 'APPROVED', ApprovedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ApprovedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CreditAssessmentId = @a;
            """, new { s = a.StatementId, a = a.CreditAssessmentId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("CREDIT_ASSESSMENT_APPROVED", "TREASURY", "fin.CreditAssessment", a.CreditAssessmentId), a.CompanyId, ct);
        await Outbox.EmitAsync(u.Connection, tx, "credit.assessment.approved", "fin.CreditAssessment", a.CreditAssessmentId, new { assessment = a.PublicId }, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "APPROVED" });
    }

    private static async Task<IResult> RejectAsync(Guid id, AssessmentReasonRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, ApproveCredit, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var reason = b.Reason?.Trim();
        if (string.IsNullOrEmpty(reason) || reason.Length > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason for returning, at most 500 characters.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var a = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (a.Status != "SUBMITTED") throw new ApiProblemException(409, "ASSESSMENT_STATE", "Only a submitted assessment is returned.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.CreditAssessment SET Status = 'REJECTED', RejectionReason = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CreditAssessmentId = @a;
            """, new { r = reason, a = a.CreditAssessmentId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("CREDIT_ASSESSMENT_REJECTED", "TREASURY", "fin.CreditAssessment", a.CreditAssessmentId,
            AfterJson: JsonSerializer.Serialize(new { reason })), a.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "REJECTED" });
    }

    private static async Task<IResult> ReopenAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var a = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (a.Status != "REJECTED") throw new ApiProblemException(409, "ASSESSMENT_STATE", "Only a returned assessment is reopened as a draft.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE fin.CreditAssessment SET Status = 'DRAFT', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE CreditAssessmentId = @a;",
            new { a = a.CreditAssessmentId }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "DRAFT" });
    }

    // ---------- the statements' analysis, budgets and presentation versions ----------

    /// <summary>FR-FIN-021: the horizontal and vertical analysis of a statement's items against a comparison statement (fin.fn_StatementItemAnalysis).</summary>
    private static async Task<IResult> ItemAnalysisAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "prior");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var s = await StatementEndpoints.FindAsync(u, null, id, scope, ct);
        long? prior = null;
        if (http.Request.Query["prior"].Count > 0)
            prior = (await StatementEndpoints.FindAsync(u, null, Guid.TryParse(http.Request.Query["prior"], out var p) ? p : Guid.Empty, scope, ct)).FinancialStatementId;
        var rows = await u.Connection.QueryAsync(new CommandDefinition("SELECT * FROM fin.fn_StatementItemAnalysis(@s, @p);", new { s = s.FinancialStatementId, p = prior },
            cancellationToken: ct));
        return Results.Ok(new { items = rows });
    }

    /// <summary>FR-FIN-038: a budget beside the actual statement of its period (fin.v_BudgetComparison).</summary>
    private static async Task<IResult> BudgetAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var company = http.Request.Query["company"].Count > 0 && Guid.TryParse(http.Request.Query["company"], out var g) ? g : (Guid?)null;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT b.* FROM fin.v_BudgetComparison AS b JOIN org.Company AS c ON c.CompanyId = b.CompanyId
             WHERE (@company IS NULL OR c.PublicId = @company) AND (@all = 1 OR b.CompanyId IN @ids);
            """, new { company, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    private static async Task<IResult> VersionsAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "statement");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var statement = http.Request.Query["statement"].Count > 0 && Guid.TryParse(http.Request.Query["statement"], out var g) ? g : (Guid?)null;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT v.PublicId AS id, s.PublicId AS sourceStatement, v.NameAr AS nameAr, v.Note AS note, v.Status AS status, r.PublicId AS resultStatement,
                   t.PublicId AS trialAssessment, v.IsConvertible AS isConvertible, v.BalanceGap AS balanceGap, v.BuiltAt AS builtAt, v.ChoiceReason AS choiceReason,
                   CAST(CASE WHEN v.PreparedBy = @me THEN 1 ELSE 0 END AS BIT) AS preparedByMe
              FROM fin.PresentationVersion AS v
              JOIN fin.FinancialStatement AS s ON s.FinancialStatementId = v.SourceStatementId
              LEFT JOIN fin.FinancialStatement AS r ON r.FinancialStatementId = v.ResultStatementId
              LEFT JOIN fin.CreditAssessment AS t ON t.CreditAssessmentId = v.TrialAssessmentId
             WHERE (@statement IS NULL OR s.PublicId = @statement) AND (@all = 1 OR s.CompanyId IN @ids)
             ORDER BY v.CreatedAt DESC;
            """, new { statement, me = u.UserId, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: ct));
        return Results.Ok(new { items = rows });
    }

    /// <summary>FR-FIN-036, BR-FIN-037: the remedies the company chose for a statement before its approval, in order, each justified and supported or not by a dated document.</summary>
    private static async Task<IResult> CreateVersionAsync(PresentationVersionRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.SourceStatement is null || string.IsNullOrWhiteSpace(b.NameAr) || b.Steps is null || b.Steps.Length == 0)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the statement, a name and at least one remedy.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await StatementEndpoints.FindAsync(u, tx, b.SourceStatement.Value, scope, ct);
        if (s.Status is not ("DRAFT" or "SUBMITTED"))
            throw ApiProblemException.Invalid("V-FIN-VERSION", "A presentation version starts from a statement before its final approval (a draft or a submitted one).");
        long? assessment = b.SourceAssessment is { } sa ? (await FindAsync(u, tx, sa, scope, ct)).CreditAssessmentId : null;
        var made = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT fin.PresentationVersion (TenantId, SourceStatementId, SourceAssessmentId, NameAr, Note, Status, PreparedBy, CreatedBy)
            OUTPUT inserted.PresentationVersionId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @s, @a, @name, @note, 'DRAFT', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new { s = s.FinancialStatementId, a = assessment, name = b.NameAr.Trim(), note = b.Note?.Trim() }, tx, cancellationToken: ct));
        var n = 0;
        foreach (var step in b.Steps)
        {
            n++;
            var remedy = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CreditRemedyId FROM fin.CreditRemedy WHERE Code = @c;",
                new { c = step.Remedy?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "A remedy is one of the methodology.");
            var why = step.Justification?.Trim();
            if (string.IsNullOrEmpty(why) || why.Length > 1000) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Justify each step, at most 1,000 characters.");
            if (step.ScalePct is <= 0 or > 100) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The share of a remedy is above 0 and at most 100 percent.");
            long? doc = null;
            var on = LimitEndpoints.Date(step.EvidenceDate, "document date");
            if (step.Document is { } d)
                doc = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE';", new { d }, tx,
                    cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document of a step is an active document on file.");
            if ((doc is null) != (on is null)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A step's document is given with its date.");
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT fin.PresentationVersionStep (TenantId, VersionId, StepNo, RemedyId, ScalePct, DocumentId, EvidenceDate, Justification, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @v, @n, @r, @pct, @doc, @on, @why, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """, new { v = made.Id, n, r = remedy, pct = step.ScalePct ?? 100m, doc, on, why }, tx, cancellationToken: ct));
        }
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/fin/presentation-versions/{made.PublicId}", new { id = made.PublicId });
    }

    private static async Task<long> VersionAsync(BoundUser u, Guid id, CompanyScope scope, CancellationToken ct)
    {
        var v = await u.Connection.QuerySingleOrDefaultAsync<(long Id, long Company)?>(new CommandDefinition(
            "SELECT v.PresentationVersionId, s.CompanyId FROM fin.PresentationVersion AS v JOIN fin.FinancialStatement AS s ON s.FinancialStatementId = v.SourceStatementId WHERE v.PublicId = @id;",
            new { id }, cancellationToken: ct));
        return v is { } x && scope.Allows(x.Company) ? x.Id : throw ApiProblemException.NotFound();
    }

    private static async Task<IResult> BuildVersionAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var v = await VersionAsync(u, id, scope, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition("fin.usp_BuildPresentationVersion", new { VersionId = v }, commandType: CommandType.StoredProcedure, commandTimeout: 120,
            cancellationToken: ct));
        return Results.Ok(new { status = "BUILT" });
    }

    private static async Task<IResult> ChooseVersionAsync(Guid id, AssessmentReasonRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Approve, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var reason = b.Reason?.Trim();
        if (string.IsNullOrEmpty(reason) || reason.Length > 1000) throw ApiProblemException.Invalid("V-FIN-VERSION", "Give the reason for choosing this version, at most 1,000 characters.");
        var v = await VersionAsync(u, id, scope, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition("fin.usp_ChoosePresentationVersion", new { VersionId = v, Reason = reason }, commandType: CommandType.StoredProcedure,
            cancellationToken: ct));
        return Results.Ok(new { status = "CHOSEN" });
    }
}

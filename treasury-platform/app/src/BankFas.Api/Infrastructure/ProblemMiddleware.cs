using Microsoft.Data.SqlClient;

namespace BankFas.Api.Infrastructure;

/// <summary>Answers every failure as application/problem+json with a correlation id and never with internal detail.</summary>
public sealed partial class ProblemMiddleware(RequestDelegate next, ILogger<ProblemMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await next(context);
        }
        catch (ApiProblemException ex)
        {
            // The rule that refused the request, so a failure seen only in a log can be explained. Only the generic field
            // messages of VALIDATION_FAILED are written out; other titles may name amounts of a facility.
            LogProblem(logger, ex.Status, ex.Code, ex.Code == "VALIDATION_FAILED" ? ex.Message : "-");
            await WriteAsync(context, ex.Status, ex.Code, ex.Message);
        }
        catch (BankFas.Data.Workflow.WorkflowRefusalException ex)
        {
            LogProblem(logger, ex.Status, ex.Code, ex.Message);
            await WriteAsync(context, ex.Status, ex.Code, ex.Message);
        }
        catch (SqlException ex) when (DbProblemMap.Map(ex.Number) is { } p)
        {
            // A refused permission, or a key the application should have checked first, is logged with its detail.
            if (p.Status >= 500 || ex.Number is 229 or 230 or BankFas.Data.DbErrors.UniqueViolation or BankFas.Data.DbErrors.UniqueIndexViolation) LogRefused(logger, ex, ex.Number);
            await WriteAsync(context, p.Status, p.Code, p.Title);
        }
        catch (BadHttpRequestException)
        {
            await WriteAsync(context, 400, "BAD_REQUEST", "The request could not be read.");
        }
        catch (Exception ex) when (!context.Response.HasStarted && ex is not OperationCanceledException)
        {
            LogUnhandled(logger, ex);
            await WriteAsync(context, 500, "INTERNAL_ERROR", "Something went wrong. Quote the correlation id when you report it.");
        }
    }

    [LoggerMessage(Level = LogLevel.Information, Message = "Refused {Status} {Code}: {Title}")]
    private static partial void LogProblem(ILogger logger, int status, string code, string title);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Database refused the request ({Number})")]
    private static partial void LogRefused(ILogger logger, Exception ex, int number);

    [LoggerMessage(Level = LogLevel.Error, Message = "Unhandled error")]
    private static partial void LogUnhandled(ILogger logger, Exception ex);

    internal static Task WriteAsync(HttpContext context, int status, string code, string title)
    {
        // Headers set so far stay (a cleared session cookie, the correlation id); the body is the problem only.
        context.Response.StatusCode = status;
        return context.Response.WriteAsJsonAsync(new
        {
            type = "https://bankfas.com/problems/" + code.ToLowerInvariant().Replace('_', '-'),
            title,
            status,
            code,
            correlationId = RequestContext.CorrelationOf(context),
        }, (System.Text.Json.JsonSerializerOptions?)null, "application/problem+json");
    }
}

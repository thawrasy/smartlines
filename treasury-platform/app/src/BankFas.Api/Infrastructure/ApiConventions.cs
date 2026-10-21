using System.Security.Cryptography;
using System.Text;
using BankFas.Core.Security;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.Extensions.Caching.Memory;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// Optimistic concurrency (DOC-B04 section 4): a single read carries ETag = base64url(RowVersion); a change sends it
/// back in If-Match. Missing is 428 PRECONDITION_REQUIRED, different is 409 VERSION_CONFLICT.
/// </summary>
public static class ETags
{
    public static string Of(byte[] rowVersion) => "\"" + Base64Url.Encode(rowVersion) + "\"";

    public static void Set(HttpResponse response, byte[] rowVersion) => response.Headers.ETag = Of(rowVersion);

    public static byte[] Required(HttpRequest request)
    {
        var value = request.Headers.IfMatch.ToString();
        if (value.Length == 0) throw new ApiProblemException(428, "PRECONDITION_REQUIRED", "Send the ETag of the record in If-Match.");
        return Base64Url.TryDecode(value.Trim('"')) is { Length: 8 } rv ? rv
            : throw new ApiProblemException(409, "VERSION_CONFLICT", "The record changed since you read it. Reload it.");
    }

    public static ApiProblemException Conflict() => new(409, "VERSION_CONFLICT", "The record changed since you read it. Reload it.");
}

/// <summary>Opaque, signed references for things without a PublicId (sessions) and for list cursors (DOC-B04 section 3).</summary>
public sealed class OpaqueRefs(IDataProtectionProvider provider)
{
    private readonly IDataProtector _session = provider.CreateProtector("BankFas.SessionRef");
    private readonly IDataProtector _cursor = provider.CreateProtector("BankFas.Cursor");

    public string SessionRef(int tenantId, long sessionId) => Base64Url.Encode(_session.Protect(Encoding.UTF8.GetBytes($"{tenantId}:{sessionId}")));

    public long? SessionId(int tenantId, string reference)
    {
        try
        {
            var raw = Base64Url.TryDecode(reference);
            if (raw is null) return null;
            var parts = Encoding.UTF8.GetString(_session.Unprotect(raw)).Split(':');
            return parts.Length == 2 && parts[0] == tenantId.ToString(System.Globalization.CultureInfo.InvariantCulture)
                && long.TryParse(parts[1], System.Globalization.CultureInfo.InvariantCulture, out var id) ? id : null;
        }
        catch (CryptographicException) { return null; }
    }

    public string Cursor(string scope, long lastId) => Base64Url.Encode(_cursor.Protect(Encoding.UTF8.GetBytes($"{scope}:{lastId}")));

    /// <summary>The last id of the previous page, or 400 INVALID_CURSOR for a cursor this server did not issue for this list.</summary>
    public long? AfterId(string scope, string? cursor)
    {
        if (string.IsNullOrEmpty(cursor)) return null;
        try
        {
            var raw = Base64Url.TryDecode(cursor) ?? throw new CryptographicException();
            var text = Encoding.UTF8.GetString(_cursor.Unprotect(raw));
            if (text.StartsWith(scope + ":", StringComparison.Ordinal)
                && long.TryParse(text[(scope.Length + 1)..], System.Globalization.CultureInfo.InvariantCulture, out var id)) return id;
        }
        catch (CryptographicException) { }
        throw new ApiProblemException(400, "INVALID_CURSOR", "The list cursor is not valid.");
    }
}

/// <summary>Query parameters: unknown ones are refused (400 UNKNOWN_PARAMETER), the page size is 1 to 200 (default 50).</summary>
public static class Query
{
    public static void Allow(HttpRequest request, params string[] names)
    {
        foreach (var key in request.Query.Keys)
        {
            if (!names.Contains(key, StringComparer.Ordinal))
                throw new ApiProblemException(400, "UNKNOWN_PARAMETER", $"Unknown query parameter: {key}.");
        }
    }

    public static int Limit(HttpRequest request)
    {
        var text = request.Query["limit"].ToString();
        if (text.Length == 0) return 50;
        return int.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, out var n) && n is >= 1 and <= 200 ? n
            : throw new ApiProblemException(400, "MALFORMED_REQUEST", "limit is a number from 1 to 200.");
    }
}

/// <summary>
/// Idempotency-Key on every creating or acting POST outside /auth (DOC-B04 section 5): the same key with the same body
/// replays the first answer for 24 hours; with another body it is 422 IDEMPOTENCY_KEY_REUSED; while the first is
/// still running, 409 IDEMPOTENCY_IN_PROGRESS. The key is scoped to the host and the session. Kept in memory in S0
/// (DQ-B04-3): one instance.
/// </summary>
public sealed class IdempotencyMiddleware(RequestDelegate next, IMemoryCache cache)
{
    private sealed record Entry(string BodyHash, bool Done, int Status, string? ContentType, byte[] Body, string? Location);

    public async Task InvokeAsync(HttpContext context)
    {
        var path = context.Request.Path;
        if (!HttpMethods.IsPost(context.Request.Method) || !path.StartsWithSegments("/api/v1")
            || path.StartsWithSegments("/api/v1/auth") || path.StartsWithSegments("/api/v1/operator/auth") || path.StartsWithSegments("/api/v1/csrf"))
        {
            await next(context);
            return;
        }
        var key = context.Request.Headers["Idempotency-Key"].ToString();
        if (key.Length is 0 or > 100 || !key.All(char.IsAscii))
            throw new ApiProblemException(400, "IDEMPOTENCY_KEY_REQUIRED", "Send an Idempotency-Key header (up to 100 characters).");
        context.Request.EnableBuffering();
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[8192];
        int read;
        while ((read = await context.Request.Body.ReadAsync(buffer, context.RequestAborted)) > 0) sha.AppendData(buffer, 0, read);
        context.Request.Body.Position = 0;
        var bodyHash = Convert.ToHexString(sha.GetHashAndReset());
        var session = context.Request.Cookies[Cookies.Session] ?? "";
        var cacheKey = "idem:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{context.Request.Host}|{session}|{path}|{key}")));

        if (cache.TryGetValue(cacheKey, out Entry? existing) && existing is not null)
        {
            if (existing.BodyHash != bodyHash)
                throw new ApiProblemException(422, "IDEMPOTENCY_KEY_REUSED", "This Idempotency-Key was used with another request.");
            if (!existing.Done)
            {
                context.Response.Headers.RetryAfter = "1";
                throw new ApiProblemException(409, "IDEMPOTENCY_IN_PROGRESS", "The first request with this key is still running.");
            }
            context.Response.StatusCode = existing.Status;
            if (existing.ContentType is not null) context.Response.ContentType = existing.ContentType;
            if (existing.Location is not null) context.Response.Headers.Location = existing.Location;
            context.Response.Headers["Idempotent-Replayed"] = "true";
            await context.Response.Body.WriteAsync(existing.Body, context.RequestAborted);
            return;
        }
        cache.Set(cacheKey, new Entry(bodyHash, false, 0, null, [], null), TimeSpan.FromMinutes(5));
        var original = context.Response.Body;
        using var captured = new MemoryStream();
        context.Response.Body = captured;
        try
        {
            await next(context);
        }
        catch
        {
            cache.Remove(cacheKey);      // a refused or failed request may be sent again with the same key
            throw;
        }
        finally
        {
            context.Response.Body = original;
        }
        var body = captured.ToArray();
        if (context.Response.StatusCode < 500)
            cache.Set(cacheKey, new Entry(bodyHash, true, context.Response.StatusCode, context.Response.ContentType, body,
                context.Response.Headers.Location.ToString() is { Length: > 0 } l ? l : null), TimeSpan.FromHours(24));
        else
            cache.Remove(cacheKey);
        await original.WriteAsync(body, context.RequestAborted);
    }
}

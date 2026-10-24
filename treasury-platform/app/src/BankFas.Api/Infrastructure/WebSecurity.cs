using System.Security.Cryptography;
using System.Text;
using BankFas.Core.Security;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// Cookies of DOC-S03 section 3: the session token in __Host-bf_session (Secure, HttpOnly, SameSite=Lax, Path=/, no
/// Domain, so it never reaches another tenant's sub-domain) and the CSRF secret in __Host-bf_csrf, which the page
/// reads and echoes in X-CSRF-Token.
/// </summary>
public static class Cookies
{
    public const string Session = "__Host-bf_session";
    public const string Csrf = "__Host-bf_csrf";
    public const string CsrfHeader = "X-CSRF-Token";

    public static void SetSession(HttpResponse response, byte[] token) =>
        response.Cookies.Append(Session, Base64Url.Encode(token), new CookieOptions
        {
            Secure = true, HttpOnly = true, SameSite = SameSiteMode.Lax, Path = "/", IsEssential = true,
        });

    public static void ClearSession(HttpResponse response) =>
        response.Cookies.Delete(Session, new CookieOptions { Secure = true, HttpOnly = true, SameSite = SameSiteMode.Lax, Path = "/" });

    public static byte[]? SessionToken(HttpRequest request) => SecureTokens.Parse(request.Cookies[Session]);

    public static byte[] RequireSessionToken(HttpRequest request) => SessionToken(request) ?? throw ApiProblemException.Unauthorized();
}

/// <summary>
/// CSRF (DOC-S03 section 4): every unsafe request carries X-CSRF-Token equal to the __Host-bf_csrf cookie (compared in
/// constant time), and an Origin header, when the browser sends one, equal to the request's own origin.
/// GET /api/v1/csrf issues the cookie and returns the same value.
/// </summary>
public sealed class CsrfMiddleware(RequestDelegate next)
{
    public Task InvokeAsync(HttpContext context)
    {
        var method = context.Request.Method;
        if (HttpMethods.IsGet(method) || HttpMethods.IsHead(method) || HttpMethods.IsOptions(method)) return next(context);
        var origin = context.Request.Headers.Origin.ToString();
        if (origin.Length > 0 && !string.Equals(origin, context.Request.Scheme + "://" + context.Request.Host, StringComparison.OrdinalIgnoreCase))
            throw ApiProblemException.Forbidden("CSRF_FAILED", "The request did not come from this site.");
        var cookie = context.Request.Cookies[Cookies.Csrf];
        var header = context.Request.Headers[Cookies.CsrfHeader].ToString();
        if (string.IsNullOrEmpty(cookie) || header.Length == 0
            || !CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(cookie), Encoding.ASCII.GetBytes(header)))
            throw ApiProblemException.Forbidden("CSRF_FAILED", "Reload the page and try again.");
        return next(context);
    }

    public static string Issue(HttpContext context)
    {
        var existing = context.Request.Cookies[Cookies.Csrf];
        if (SecureTokens.Parse(existing) is not null) return existing!;
        var value = Base64Url.Encode(SecureTokens.NewToken());
        context.Response.Cookies.Append(Cookies.Csrf, value, new CookieOptions
        {
            Secure = true, HttpOnly = false, SameSite = SameSiteMode.Strict, Path = "/", IsEssential = true,
        });
        return value;
    }
}

/// <summary>The response headers of DOC-S03 section 5 on every response.</summary>
public sealed class SecurityHeadersMiddleware(RequestDelegate next)
{
    private const string Csp =
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; " +
        "frame-ancestors 'none'; form-action 'self'; base-uri 'none'; object-src 'none'";

    public Task InvokeAsync(HttpContext context)
    {
        var h = context.Response.Headers;
        h["Content-Security-Policy"] = Csp;
        h["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains";
        h["X-Content-Type-Options"] = "nosniff";
        h["X-Robots-Tag"] = "noindex, nofollow, noarchive, nosnippet";
        h["Referrer-Policy"] = "no-referrer";
        h["X-Frame-Options"] = "DENY";
        h["Cross-Origin-Opener-Policy"] = "same-origin";
        h["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()";
        if (context.Request.Path.StartsWithSegments("/api")) h["Cache-Control"] = "no-store";
        return next(context);
    }
}

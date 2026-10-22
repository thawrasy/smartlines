using System.Security.Cryptography;
using System.Text.Json;
using BankFas.Core.Security;
using BankFas.Data;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.Extensions.Caching.Memory;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// Unwrapped tenant keys, kept in memory for at most 15 minutes and never logged (DOC-S02 section 6). The wrapped key
/// comes from the database with the value it opens (sec.usp_GetMfaChallenge), so no key is read before binding.
/// </summary>
public sealed class TenantKeyRing(IKeyWrapper wrapper, IMemoryCache cache)
{
    public byte[] DataKey(int tenantId, long keyId, int version, byte[] wrapped, string masterKeyRef) =>
        Key(tenantId, "DATA", keyId, version, wrapped, masterKeyRef);

    /// <summary>A tenant key of any purpose (DATA, BLIND_INDEX, FILE), unwrapped with the associated data of its purpose.</summary>
    public byte[] Key(int tenantId, string purpose, long keyId, int version, byte[] wrapped, string masterKeyRef) =>
        cache.GetOrCreate(("tenant-key", tenantId, keyId), e =>
        {
            e.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(15);
            e.Size = 1;
            return wrapper.Unwrap(masterKeyRef, wrapped, EnvelopeAad.ForTenantKey(tenantId, purpose, version));
        })!;

    /// <summary>The ACTIVE key of a purpose of the bound tenant, read on the bound connection, and its bytes.</summary>
    public async Task<(long KeyId, byte[] Key)> ActiveAsync(Microsoft.Data.SqlClient.SqlConnection c, Microsoft.Data.SqlClient.SqlTransaction? tx,
        int tenantId, string purpose, CancellationToken ct)
    {
        var k = await Dapper.SqlMapper.QuerySingleOrDefaultAsync<(long Id, int Version, byte[] Wrapped, string Ref)>(c, new Dapper.CommandDefinition(
            "SELECT TenantKeyId, KeyVersion, WrappedKey, MasterKeyRef FROM sec.TenantKey WHERE Purpose = @p AND Status = 'ACTIVE';",
            new { p = purpose }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (k.Id == 0) throw new InvalidOperationException($"The tenant has no ACTIVE {purpose} key.");
        return (k.Id, Key(tenantId, purpose, k.Id, k.Version, k.Wrapped, k.Ref));
    }

    /// <summary>A key by its id (any status that may still be read), for a value written under it.</summary>
    public async Task<byte[]> ByIdAsync(Microsoft.Data.SqlClient.SqlConnection c, Microsoft.Data.SqlClient.SqlTransaction? tx, int tenantId, long keyId,
        CancellationToken ct)
    {
        var k = await Dapper.SqlMapper.QuerySingleAsync<(string Purpose, int Version, byte[] Wrapped, string Ref)>(c, new Dapper.CommandDefinition(
            "SELECT Purpose, KeyVersion, WrappedKey, MasterKeyRef FROM sec.TenantKey WHERE TenantKeyId = @id AND Status IN ('ACTIVE', 'RETIRING');",
            new { id = keyId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        return Key(tenantId, k.Purpose, keyId, k.Version, k.Wrapped, k.Ref);
    }
}

/// <summary>
/// A TOTP secret between "show the QR code" and "the first code checks out": the database keeps nothing until then
/// (DOC-S04 section 9), so it travels in a cookie encrypted and signed by ASP.NET Data Protection, tied to the session
/// (or set-up link) it was made for, for ten minutes.
/// </summary>
public sealed class PendingSecretProtector(IDataProtectionProvider provider)
{
    public const string Cookie = "__Host-bf_enrol";
    private readonly ITimeLimitedDataProtector _protector = provider.CreateProtector("BankFas.PendingTotpSecret").ToTimeLimitedDataProtector();

    private sealed record Pending(string Secret, string Binding);

    public void Store(HttpResponse response, byte[] secret, byte[] boundTo)
    {
        var json = JsonSerializer.Serialize(new Pending(Convert.ToBase64String(secret), Convert.ToBase64String(SHA256.HashData(boundTo))));
        response.Cookies.Append(Cookie, _protector.Protect(json, TimeSpan.FromMinutes(10)), new CookieOptions
        {
            Secure = true, HttpOnly = true, SameSite = SameSiteMode.Strict, Path = "/", MaxAge = TimeSpan.FromMinutes(10), IsEssential = true,
        });
    }

    public byte[]? Take(HttpRequest request, byte[] boundTo)
    {
        var value = request.Cookies[Cookie];
        if (string.IsNullOrEmpty(value)) return null;
        try
        {
            var p = JsonSerializer.Deserialize<Pending>(_protector.Unprotect(value));
            if (p is null || p.Binding != Convert.ToBase64String(SHA256.HashData(boundTo))) return null;
            return Convert.FromBase64String(p.Secret);
        }
        catch (CryptographicException) { return null; }
        catch (JsonException) { return null; }
    }

    public static void Clear(HttpResponse response) =>
        response.Cookies.Delete(Cookie, new CookieOptions { Secure = true, HttpOnly = true, SameSite = SameSiteMode.Strict, Path = "/" });
}

/// <summary>
/// The password rules the application enforces (DOC-S04 section 4): at least the tenant's minimum (12 by default, 14
/// for operators) and at most 128 code points after NFKC, any printable characters, and none of the obvious context
/// words, and not on the list of leaked passwords (DQ-S04-1), which is checked last so that the cheap rules answer first.
/// </summary>
public static class PasswordRules
{
    public const int MaxLength = 128;
    public const int OperatorMinLength = 14;

    public static void Check(BreachedPasswords breached, string? password, int minLength, params string?[] contextWords)
    {
        if (password is null) throw ApiProblemException.Invalid("PASSWORD_WEAK", "Enter a password.");
        var normalised = PasswordHasher.Normalise(password);
        var length = normalised.EnumerateRunes().Count();
        if (length < minLength || length > MaxLength)
            throw ApiProblemException.Invalid("PASSWORD_WEAK", $"Use between {minLength} and {MaxLength} characters.");
        if (normalised.EnumerateRunes().Any(r => System.Text.Rune.IsControl(r)))
            throw ApiProblemException.Invalid("PASSWORD_WEAK", "The password contains characters that cannot be typed.");
        var lower = normalised.ToLowerInvariant();
        foreach (var word in contextWords.Append("bankfas"))
        {
            if (!string.IsNullOrWhiteSpace(word) && word.Length >= 4 && lower.Contains(word.ToLowerInvariant(), StringComparison.Ordinal))
                throw ApiProblemException.Invalid("PASSWORD_WEAK", "Do not use your e-mail, your name or the account name in the password.");
        }
        ArgumentNullException.ThrowIfNull(breached);
        if (breached.Contains(password))
            throw ApiProblemException.Invalid("PASSWORD_BREACHED", "This password is on a list of leaked passwords. Choose another.");
    }
}

/// <summary>A connection bound to the signed-in user for one request; disposed at the end of the request (DOC-F04 section 5).</summary>
public sealed class BoundUser(Microsoft.Data.SqlClient.SqlConnection connection, int tenantId, long userId) : IAsyncDisposable
{
    private HashSet<string>? _permissions;

    public Microsoft.Data.SqlClient.SqlConnection Connection { get; } = connection;
    public int TenantId { get; } = tenantId;
    public long UserId { get; } = userId;

    public ValueTask DisposeAsync() => Connection.DisposeAsync();

    /// <summary>The union of the permissions of the user's active roles (BR-PLT-007).</summary>
    public async Task<IReadOnlySet<string>> PermissionsAsync(CancellationToken ct)
    {
        _permissions ??= [.. await Dapper.SqlMapper.QueryAsync<string>(Connection, new Dapper.CommandDefinition(
            """
            SELECT DISTINCT p.Code
            FROM sec.UserRole AS ur
            JOIN sec.Role AS r ON r.RoleId = ur.RoleId AND r.IsActive = 1
            JOIN sec.RolePermission AS rp ON rp.RoleId = r.RoleId
            JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId AND p.IsActive = 1
            WHERE ur.UserId = @id;
            """, new { id = UserId }, cancellationToken: ct))];
        return _permissions;
    }

    /// <summary>403 unless the user holds the permission; the database checks the binding and the tenant on top.</summary>
    public async Task RequireAsync(string permission, CancellationToken ct)
    {
        if (!(await PermissionsAsync(ct)).Contains(permission)) throw ApiProblemException.Forbidden();
    }

    /// <summary>Opens, binds and checks one permission.</summary>
    public static async Task<BoundUser> OpenAsync(HttpContext http, SqlConnectionFactory db, string permission)
    {
        var u = await OpenAsync(http, db);
        try
        {
            await u.RequireAsync(permission, http.RequestAborted);
            return u;
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }

    /// <summary>Opens and binds; a session that cannot bind answers 401.</summary>
    public static async Task<BoundUser> OpenAsync(HttpContext http, SqlConnectionFactory db)
    {
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        var token = Cookies.RequireSessionToken(http.Request);
        var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
        try
        {
            var userId = await TenantAuthProcedures.BindUserAsync(c, tenant.TenantId, token, rc.ClientIp, rc.CorrelationId, http.RequestAborted);
            return new BoundUser(c, tenant.TenantId, userId);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is DbErrors.NoValidSession or DbErrors.TenantUnavailable)
        {
            // The cookie stays: 50003 is also the answer for a session still waiting for its MFA check.
            await c.DisposeAsync();
            throw ApiProblemException.Unauthorized();
        }
        catch
        {
            await c.DisposeAsync();
            throw;
        }
    }
}

using System.Security.Cryptography;

namespace BankFas.Core.Security;

/// <summary>
/// Session tokens, link tokens and the CSRF secret: 32 random bytes from the operating system's CSPRNG (DOC-S03). The
/// database keeps only their SHA-256 (TokenHash), so the raw token exists in the cookie or the link alone.
/// </summary>
public static class SecureTokens
{
    public const int TokenBytes = 32;

    public static byte[] NewToken() => RandomNumberGenerator.GetBytes(TokenBytes);

    /// <summary>The token of a cookie or a link: exactly 32 bytes in base64url, else null.</summary>
    public static byte[]? Parse(string? text)
    {
        var bytes = Base64Url.TryDecode(text);
        return bytes is { Length: TokenBytes } ? bytes : null;
    }

    public static byte[] Sha256(ReadOnlySpan<byte> data) => SHA256.HashData(data);
}

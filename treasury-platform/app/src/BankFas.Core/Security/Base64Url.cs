namespace BankFas.Core.Security;

/// <summary>Base64url without padding (RFC 4648 section 5): the session cookie and the links carry tokens this way.</summary>
public static class Base64Url
{
    public static string Encode(ReadOnlySpan<byte> data) =>
        Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>Decodes a base64url string; null when it is not one, so a forged cookie is simply refused.</summary>
    public static byte[]? TryDecode(string? text)
    {
        if (string.IsNullOrEmpty(text) || text.Length > 4096) return null;
        foreach (var c in text)
        {
            if (!(c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_')) return null;
        }
        if (text.Length % 4 == 1) return null;
        var s = text.Replace('-', '+').Replace('_', '/');
        s = s.PadRight(s.Length + (4 - s.Length % 4) % 4, '=');
        try { return Convert.FromBase64String(s); }
        catch (FormatException) { return null; }
    }
}

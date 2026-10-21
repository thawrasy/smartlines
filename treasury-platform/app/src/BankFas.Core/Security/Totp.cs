using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace BankFas.Core.Security;

/// <summary>
/// Time-based one-time passwords (RFC 6238; DOC-S04 section 9): HMAC-SHA1, 6 digits, a 30-second step, the current
/// step and one on either side. The database keeps the last accepted step and refuses any step not after it
/// (sec.usp_ConfirmMfa), so each code works once.
/// </summary>
public static class Totp
{
    public const int SecretBytes = 20;
    public const int StepSeconds = 30;
    public const int Digits = 6;

    public static byte[] NewSecret() => RandomNumberGenerator.GetBytes(SecretBytes);

    public static long StepAt(DateTimeOffset time) => time.ToUnixTimeSeconds() / StepSeconds;

    /// <summary>The code of one time step.</summary>
    public static string Code(ReadOnlySpan<byte> secret, long step)
    {
        Span<byte> counter = stackalloc byte[8];
        BinaryPrimitives.WriteInt64BigEndian(counter, step);
        Span<byte> mac = stackalloc byte[20];
        // RFC 6238 with SHA-1 is what every authenticator app computes (DQ-S04-7); HMAC-SHA1 is not weakened by SHA-1
        // collisions.
#pragma warning disable CA5350
        HMACSHA1.HashData(secret, counter, mac);
#pragma warning restore CA5350
        var offset = mac[^1] & 0x0F;
        var binary = (BinaryPrimitives.ReadInt32BigEndian(mac.Slice(offset, 4)) & 0x7FFFFFFF) % 1_000_000;
        return binary.ToString("D6", CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// The step whose code matches, among the current one and one on either side, and after <paramref name="lastUsedStep"/>;
    /// null when none does. Every candidate is compared, in constant time, so timing does not tell which one matched.
    /// </summary>
    public static long? Verify(ReadOnlySpan<byte> secret, string? code, DateTimeOffset now, long? lastUsedStep)
    {
        if (code is null) return null;
        code = code.Replace(" ", "", StringComparison.Ordinal);
        if (code.Length != Digits || !code.All(char.IsAsciiDigit)) return null;
        var typed = Encoding.ASCII.GetBytes(code);
        var current = StepAt(now);
        long? match = null;
        for (var step = current - 1; step <= current + 1; step++)
        {
            var ok = CryptographicOperations.FixedTimeEquals(typed, Encoding.ASCII.GetBytes(Code(secret, step)));
            if (ok && (lastUsedStep is null || step > lastUsedStep) && match is null) match = step;
        }
        return match;
    }

    /// <summary>The otpauth URI an authenticator app reads from the enrolment QR code.</summary>
    public static Uri EnrolmentUri(ReadOnlySpan<byte> secret, string issuer, string accountLabel)
    {
        var label = Uri.EscapeDataString(issuer) + ":" + Uri.EscapeDataString(accountLabel);
        return new Uri(string.Create(CultureInfo.InvariantCulture,
            $"otpauth://totp/{label}?secret={Base32.Encode(secret)}&issuer={Uri.EscapeDataString(issuer)}&algorithm=SHA1&digits={Digits}&period={StepSeconds}"));
    }
}

/// <summary>RFC 4648 base32 without padding, as authenticator apps expect the TOTP secret.</summary>
public static class Base32
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    public static string Encode(ReadOnlySpan<byte> data)
    {
        var sb = new StringBuilder((data.Length * 8 + 4) / 5);
        int buffer = 0, bits = 0;
        foreach (var b in data)
        {
            buffer = (buffer << 8) | b;
            bits += 8;
            while (bits >= 5)
            {
                sb.Append(Alphabet[(buffer >> (bits - 5)) & 31]);
                bits -= 5;
            }
        }
        if (bits > 0) sb.Append(Alphabet[(buffer << (5 - bits)) & 31]);
        return sb.ToString();
    }
}

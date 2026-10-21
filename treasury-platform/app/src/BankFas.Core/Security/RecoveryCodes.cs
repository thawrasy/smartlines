using System.Security.Cryptography;
using System.Text;

namespace BankFas.Core.Security;

/// <summary>
/// The ten single-use recovery codes of an MFA enrolment (DOC-S04 section 9): 80 random bits each, 16 Crockford base32
/// characters shown in four groups (XXXX-XXXX-XXXX-XXXX). The database keeps the SHA-256 of the normalised code.
/// </summary>
public static class RecoveryCodes
{
    public const int Count = 10;
    private const string Crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    public static IReadOnlyList<string> Generate()
    {
        var codes = new List<string>(Count);
        while (codes.Count < Count)
        {
            var bytes = RandomNumberGenerator.GetBytes(10);
            var chars = new char[16];
            for (var i = 0; i < 16; i++)
            {
                // 80 bits, 5 per character, most significant first
                var bitIndex = i * 5;
                var value = 0;
                for (var b = 0; b < 5; b++)
                {
                    var bit = bitIndex + b;
                    value = (value << 1) | ((bytes[bit / 8] >> (7 - bit % 8)) & 1);
                }
                chars[i] = Crockford[value];
            }
            var code = string.Join('-', new string(chars, 0, 4), new string(chars, 4, 4), new string(chars, 8, 4), new string(chars, 12, 4));
            if (!codes.Contains(code)) codes.Add(code);
        }
        return codes;
    }

    /// <summary>
    /// What a user types, in the form that is hashed: upper case, without dashes and spaces, with the Crockford
    /// look-alikes read as digits (O as 0, I and L as 1). Null when it is not 16 Crockford characters.
    /// </summary>
    public static string? Normalise(string? typed)
    {
        if (typed is null) return null;
        var sb = new StringBuilder(16);
        foreach (var c in typed.ToUpperInvariant())
        {
            if (c is '-' or ' ') continue;
            var mapped = c switch { 'O' => '0', 'I' or 'L' => '1', _ => c };
            if (!Crockford.Contains(mapped, StringComparison.Ordinal)) return null;
            sb.Append(mapped);
        }
        return sb.Length == 16 ? sb.ToString() : null;
    }

    /// <summary>SHA-256 of the UTF-8 bytes of the normalised code (sec.MfaRecoveryCode.CodeHash).</summary>
    public static byte[] Hash(string normalised) => SHA256.HashData(Encoding.UTF8.GetBytes(normalised));

    /// <summary>The JSON array of ten 64-character hex hashes that sec.usp_CompleteMfaEnrolment takes.</summary>
    public static string HashesJson(IEnumerable<string> codes) =>
        "[" + string.Join(',', codes.Select(c => "\"" + Convert.ToHexStringLower(Hash(Normalise(c)!)) + "\"")) + "]";
}

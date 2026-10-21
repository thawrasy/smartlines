using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Konscious.Security.Cryptography;

namespace BankFas.Core.Security;

/// <summary>Argon2id cost parameters of a password hash (DOC-S04 section 3): memory in KiB, passes and lanes.</summary>
public sealed record Argon2Parameters(int MemoryKib, int Iterations, int Parallelism)
{
    /// <summary>The policy for new hashes: 64 MiB, 3 passes, 4 lanes (DOC-S04 section 3).</summary>
    public static Argon2Parameters Policy { get; } = new(65536, 3, 4);

    internal bool IsWithinBounds => MemoryKib is >= 19456 and <= 1048576 && Iterations is >= 1 and <= 10 && Parallelism is >= 1 and <= 16;
}

/// <summary>
/// Password hashes in the PHC string format of the reference implementation:
/// <c>$argon2id$v=19$m=65536,t=3,p=4$&lt;salt&gt;$&lt;hash&gt;</c>, standard base64 without padding, a 16-byte salt and a 32-byte
/// hash of the UTF-8 bytes of the NFKC-normalised password (DOC-S04 section 3). The database compares the whole string
/// (sec.usp_StartSession), so the string must be byte-identical to the stored one.
/// </summary>
public static class PasswordHasher
{
    public const int SaltBytes = 16;
    public const int HashBytes = 32;
    private const string Prefix = "$argon2id$v=19$";

    // A fixed salt for an unknown e-mail: the login still costs a full hash, so timing does not tell whether the
    // account exists (DOC-F03, FR-PLT-012).
    private static readonly byte[] DummySalt = "BankFas-no-user!"u8.ToArray();

    /// <summary>A new hash with a fresh salt under the current policy (invitation, reset, change).</summary>
    public static string HashNew(string password)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        return Format(Argon2Parameters.Policy, salt, Compute(password, salt, Argon2Parameters.Policy));
    }

    /// <summary>
    /// The hash of a password with the parameters and salt the database returns (sec.usp_GetPasswordParams,
    /// sec.usp_GetPasswordHistoryParams): the PHC string up to its last '$'. Null when the prefix is not one this
    /// application wrote.
    /// </summary>
    public static string? HashWithStoredParameters(string password, string storedParameters)
    {
        if (!TryParseParameters(storedParameters, out var parameters, out var salt)) return null;
        return Format(parameters, salt, Compute(password, salt, parameters));
    }

    /// <summary>A hash at the policy cost for a login whose e-mail is unknown; the database refuses it anyway.</summary>
    public static string HashForUnknownUser(string password) =>
        Format(Argon2Parameters.Policy, DummySalt, Compute(password, DummySalt, Argon2Parameters.Policy));

    /// <summary>The NFKC form every password is hashed and measured in (DOC-S04 section 4).</summary>
    public static string Normalise(string password) => password.Normalize(NormalizationForm.FormKC);

    internal static bool TryParseParameters(string text, out Argon2Parameters parameters, out byte[] salt)
    {
        parameters = Argon2Parameters.Policy;
        salt = [];
        if (!text.StartsWith(Prefix, StringComparison.Ordinal)) return false;
        var parts = text[Prefix.Length..].Split('$');
        if (parts.Length != 2) return false;
        int m = 0, t = 0, p = 0;
        foreach (var kv in parts[0].Split(','))
        {
            var pair = kv.Split('=');
            if (pair.Length != 2 || !int.TryParse(pair[1], NumberStyles.None, CultureInfo.InvariantCulture, out var v)) return false;
            switch (pair[0])
            {
                case "m": m = v; break;
                case "t": t = v; break;
                case "p": p = v; break;
                default: return false;
            }
        }
        parameters = new Argon2Parameters(m, t, p);
        var decoded = DecodeUnpadded(parts[1]);
        if (!parameters.IsWithinBounds || decoded is not { Length: >= 8 and <= 64 }) return false;
        salt = decoded;
        return true;
    }

    private static byte[] Compute(string password, byte[] salt, Argon2Parameters parameters)
    {
        var bytes = Encoding.UTF8.GetBytes(Normalise(password));
        try
        {
            using var argon = new Argon2id(bytes)
            {
                Salt = salt,
                MemorySize = parameters.MemoryKib,
                Iterations = parameters.Iterations,
                DegreeOfParallelism = parameters.Parallelism,
            };
            return argon.GetBytes(HashBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    private static string Format(Argon2Parameters p, byte[] salt, byte[] hash) =>
        string.Create(CultureInfo.InvariantCulture,
            $"{Prefix}m={p.MemoryKib},t={p.Iterations},p={p.Parallelism}${EncodeUnpadded(salt)}${EncodeUnpadded(hash)}");

    private static string EncodeUnpadded(byte[] data) => Convert.ToBase64String(data).TrimEnd('=');

    private static byte[]? DecodeUnpadded(string text)
    {
        if (text.Length % 4 == 1 || text.Contains('=', StringComparison.Ordinal)) return null;
        try { return Convert.FromBase64String(text.PadRight(text.Length + (4 - text.Length % 4) % 4, '=')); }
        catch (FormatException) { return null; }
    }
}

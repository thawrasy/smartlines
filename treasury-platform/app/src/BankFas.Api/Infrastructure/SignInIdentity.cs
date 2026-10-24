using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// The sign-in names besides the e-mail (docs/31 row 46, ADR 0048): the employee code and the mobile number, and the
/// tenant's lists of what a user may sign in with (security.login.identifiers) and how an administrator creates a user
/// (security.user.creation). The database finds the user by the same rules (sec.fn_LoginUser).
/// </summary>
public static partial class SignInIdentity
{
    public static readonly string[] Identifiers = ["EMAIL", "EMPLOYEE_CODE", "MOBILE"];
    public static readonly string[] CreationMethods = ["INVITATION", "TEMP_PASSWORD"];

    [GeneratedRegex(@"^[A-Za-z0-9._-]{2,30}$")]
    private static partial Regex EmployeeCodeShape();

    [GeneratedRegex(@"^\+[1-9][0-9]{7,14}$")]
    private static partial Regex MobileShape();

    /// <summary>The employee code as stored, or null when not given; refuses a code of the wrong shape.</summary>
    public static string? EmployeeCode(string? value)
    {
        var v = value?.Trim();
        if (string.IsNullOrEmpty(v)) return null;
        return EmployeeCodeShape().IsMatch(v) ? v
            : throw ApiProblemException.Invalid("V-USR-EMPLOYEE-CODE", "The employee code is 2 to 30 Latin letters, digits, dots, hyphens or underscores.");
    }

    /// <summary>The mobile number in international form (+9665…): spaces, dashes and brackets dropped, 00 read as +.</summary>
    public static string? Mobile(string? value)
    {
        var v = value?.Trim();
        if (string.IsNullOrEmpty(v)) return null;
        var digits = new string([.. v.Where(ch => ch is not (' ' or '-' or '(' or ')'))]);
        if (digits.StartsWith("00", StringComparison.Ordinal)) digits = "+" + digits[2..];
        return MobileShape().IsMatch(digits) ? digits
            : throw ApiProblemException.Invalid("V-USR-MOBILE", "Enter the mobile number in international form, starting with + and the country code.");
    }

    /// <summary>The words of a list setting of the bound tenant (its value, else the platform default) that are in the allowed set.</summary>
    public static async Task<HashSet<string>> ListSettingAsync(SqlConnection c, SqlTransaction? tx, string key, string[] allowed, CancellationToken ct)
    {
        var raw = await c.ExecuteScalarAsync<string?>(new CommandDefinition(
            """
            SELECT ISNULL(JSON_VALUE(N'[' + t.ValueJson + N']', '$[0]'), JSON_VALUE(N'[' + d.DefaultValueJson + N']', '$[0]'))
            FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key]
            WHERE d.[Key] = @key;
            """, new { key }, tx, cancellationToken: ct));
        return [.. (raw ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(w => w.ToUpperInvariant()).Where(allowed.Contains)];
    }

    /// <summary>A list setting written by the tenant: known words only, at least one, without repeats.</summary>
    public static string? CheckList(string key, string value)
    {
        string[]? allowed = key switch { "security.login.identifiers" => Identifiers, "security.user.creation" => CreationMethods, _ => null };
        if (allowed is null) return null;
        var words = value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0 || words.Any(w => !allowed.Contains(w)) || words.Distinct(StringComparer.Ordinal).Count() != words.Length)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", $"Use one or more of {string.Join(", ", allowed)}, separated by commas.");
        return string.Join(',', words);
    }

    /// <summary>
    /// A temporary password the administrator hands over: random, from letters and digits that cannot be mistaken for
    /// one another, in groups of four, and at least as long as the tenant's minimum.
    /// </summary>
    public static string TemporaryPassword(int minLength)
    {
        const string alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789";
        var sb = new System.Text.StringBuilder();
        while (sb.Length < Math.Max(19, minLength) || sb[^1] == '-')
            sb.Append(sb.Length % 5 == 4 ? '-' : alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)]);
        return sb.ToString();
    }
}

using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Notifications;

/// <summary>
/// The account's default notification preferences (FR-NTF-011): the setting <c>ntf.prefs.defaults</c> holds, per event
/// group, the mode of each channel, as <c>{"GROUP": {"IN_APP": "OFF", "EMAIL": "DIGEST_DAILY"}}</c>. A user's own
/// choice wins; without one the account's default applies, else IMMEDIATE. A mandatory group stays in the application
/// whatever the default (BR-NTF-003).
/// </summary>
public static class NotificationDefaults
{
    public const string Key = "ntf.prefs.defaults";

    public static Dictionary<(string Group, string Channel), string> Parse(string? json)
    {
        var map = new Dictionary<(string, string), string>();
        if (string.IsNullOrWhiteSpace(json)) return map;
        using var doc = JsonDocument.Parse(json);
        if (doc.RootElement.ValueKind != JsonValueKind.Object) return map;
        foreach (var g in doc.RootElement.EnumerateObject())
            if (g.Value.ValueKind == JsonValueKind.Object)
                foreach (var ch in g.Value.EnumerateObject())
                    if (ch.Value.ValueKind == JsonValueKind.String) map[(g.Name, ch.Name)] = ch.Value.GetString()!;
        return map;
    }

    public static string Serialize(IEnumerable<KeyValuePair<(string Group, string Channel), string>> map) =>
        JsonSerializer.Serialize(map.GroupBy(x => x.Key.Group).OrderBy(g => g.Key, StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.OrderBy(x => x.Key.Channel, StringComparer.Ordinal).ToDictionary(x => x.Key.Channel, x => x.Value)));

    public static async Task<string?> JsonAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct) =>
        await c.ExecuteScalarAsync<string?>(new CommandDefinition(
            """
            SELECT ISNULL(s.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS s ON s.[Key] = d.[Key]
             WHERE d.[Key] = @k;
            """, new { k = Key }, tx, cancellationToken: ct)).ConfigureAwait(false);

    public static async Task<Dictionary<(string Group, string Channel), string>> LoadAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct) =>
        Parse(await JsonAsync(c, tx, ct).ConfigureAwait(false));
}

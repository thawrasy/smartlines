using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// The network guard and the security page of the panel (docs/31 row 48, ADR 0047): only the trusted proxy names the
/// client, an address that keeps being refused is blocked for a while with a HIGH security event and an alert, the
/// API is limited per address, an operator blocks and lifts by hand but never the proxy, and incidents are numbered and
/// closed only with their root cause (DOC-S15).
/// </summary>
[Collection("database")]
public sealed class SecurityGuardTests(PlatformFixture f)
{
    private static string NewAddress() => $"198.18.{Random.Shared.Next(1, 255)}.{Random.Shared.Next(1, 255)}";

    /// <summary>A client behind the proxy: the test server's loopback is the proxy, the header names the client.</summary>
    private HttpClient Client(string ip)
    {
        var c = f.Env.CreateClient(new Microsoft.AspNetCore.Mvc.Testing.WebApplicationFactoryClientOptions { BaseAddress = new Uri("https://" + TestEnvironment.OperatorHost) });
        c.DefaultRequestHeaders.Add("X-Forwarded-For", ip);
        return c;
    }

    private static async Task<(int, string)> GetAsync(HttpClient c, string path)
    {
        var r = await c.GetAsync(path, TestContext.Current.CancellationToken);
        var text = await r.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        var code = text.Length > 0 && text[0] == '{' && JsonDocument.Parse(text).RootElement.TryGetProperty("code", out var x) ? x.GetString()! : "";
        return ((int)r.StatusCode, code);
    }

    [Fact]
    public async Task An_address_refused_again_and_again_is_blocked_logged_alerted_and_lifted_by_an_operator()
    {
        f.RequireDatabase();
        var ip = NewAddress();
        var other = NewAddress();
        using var bad = Client(ip);
        using var good = Client(other);
        for (var i = 0; i < 41; i++) Assert.Equal(401, (await GetAsync(bad, "/api/v1/operator/tenants")).Item1);
        Assert.Equal((403, "IP_BLOCKED"), await GetAsync(bad, "/api/v1/operator/tenants"));
        Assert.Equal((403, "IP_BLOCKED"), await GetAsync(bad, "/api/v1/csrf"));
        // Another client behind the same proxy, and the proxy itself, go on.
        Assert.Equal(401, (await GetAsync(good, "/api/v1/operator/tenants")).Item1);
        Assert.Equal(HttpStatusCode.OK, (await f.Panel.GetAsync("/api/v1/operator/tenants", TestContext.Current.CancellationToken)).StatusCode);

        var overview = await f.Panel.GetJsonAsync("/api/v1/operator/security/overview");
        var block = overview.GetProperty("blocks").EnumerateArray().Single(b => b.GetProperty("clientIp").GetString() == ip);
        Assert.Equal("AUTO", block.GetProperty("source").GetString());
        Assert.Contains(overview.GetProperty("events").EnumerateArray(), e =>
            e.GetProperty("action").GetString() == "IP_BLOCKED" && e.GetProperty("ipAddress").GetString() == ip && e.GetProperty("severity").GetString() == "HIGH");
        Assert.True(overview.GetProperty("counts").GetProperty("autoBlocks24h").GetInt32() >= 1);
        Assert.Contains(Directory.EnumerateFiles(f.Env.MailDir, "*.eml"), m =>
        {
            var text = File.ReadAllText(m);
            return text.Contains("To: " + TestEnvironment.SecurityAlertEmail, StringComparison.Ordinal) && text.Contains(ip, StringComparison.Ordinal);
        });

        // The lift needs an administrator's fresh code, and opens the address at once.
        Assert.Equal((403, "STEP_UP_REQUIRED"), await f.Panel.PostProblemAsync($"/api/v1/operator/security/blocks/{PlatformFixture.Id(block)}/actions/lift", new { }));
        Assert.Equal(HttpStatusCode.NoContent, (await f.Panel.SendAsync(HttpMethod.Post, $"/api/v1/operator/security/blocks/{PlatformFixture.Id(block)}/actions/lift",
            new { mfaCode = f.NextCode(f.OperatorSecret) })).StatusCode);
        Assert.Equal(401, (await GetAsync(bad, "/api/v1/operator/tenants")).Item1);
        Assert.Equal((404, "NOT_FOUND"), await f.Panel.PostProblemAsync($"/api/v1/operator/security/blocks/{PlatformFixture.Id(block)}/actions/lift",
            new { mfaCode = f.NextCode(f.OperatorSecret) }));
    }

    [Fact]
    public async Task A_client_cannot_name_itself_and_the_api_is_limited_per_address()
    {
        f.RequireDatabase();
        // A header with two addresses: only the hop the proxy added counts, so the first one the client wrote is ignored.
        var ip = NewAddress();
        using var c = Client("10.9.8.7, " + ip);
        for (var i = 0; i < 60; i++) Assert.Equal(200, (await GetAsync(c, "/api/v1/csrf")).Item1);
        Assert.Equal(429, (await GetAsync(c, "/api/v1/csrf")).Item1);
        using var spoof = Client("10.9.8.7");
        Assert.Equal(200, (await GetAsync(spoof, "/api/v1/csrf")).Item1);
        // The front end's own files and the health check are not limited.
        Assert.NotEqual(429, (await GetAsync(c, "/health/live")).Item1);
    }

    [Fact]
    public async Task An_operator_blocks_by_hand_but_never_the_proxy_or_loopback()
    {
        f.RequireDatabase();
        Assert.Equal((409, "V-SEC-TRUSTED"), await f.Panel.PostProblemAsync("/api/v1/operator/security/blocks",
            new { clientIp = "127.0.0.1", reason = "test", hours = 1, mfaCode = f.NextCode(f.OperatorSecret) }));
        Assert.Equal((409, "V-SEC-TRUSTED"), await f.Panel.PostProblemAsync("/api/v1/operator/security/blocks",
            new { clientIp = "::1", reason = "test", hours = 1, mfaCode = f.NextCode(f.OperatorSecret) }));
        Assert.Equal((422, "VALIDATION_FAILED"), await f.Panel.PostProblemAsync("/api/v1/operator/security/blocks",
            new { clientIp = "not an address", reason = "test", hours = 1, mfaCode = f.NextCode(f.OperatorSecret) }));
        var ip = NewAddress();
        using var c = Client(ip);
        Assert.Equal(200, (await GetAsync(c, "/api/v1/csrf")).Item1);
        var created = await f.Panel.PostOkAsync("/api/v1/operator/security/blocks",
            new { clientIp = ip, reason = "Scanning the sign-in page", hours = 2, mfaCode = f.NextCode(f.OperatorSecret) });
        Assert.Equal((403, "IP_BLOCKED"), await GetAsync(c, "/api/v1/csrf"));
        var overview = await f.Panel.GetJsonAsync("/api/v1/operator/security/overview");
        var row = overview.GetProperty("blocks").EnumerateArray().Single(b => b.GetProperty("clientIp").GetString() == ip);
        Assert.Equal("MANUAL", row.GetProperty("source").GetString());
        Assert.Equal(PlatformFixture.OperatorEmail, row.GetProperty("blockedBy").GetString());
        Assert.Equal(HttpStatusCode.NoContent, (await f.Panel.SendAsync(HttpMethod.Post, $"/api/v1/operator/security/blocks/{PlatformFixture.Id(created)}/actions/lift",
            new { mfaCode = f.NextCode(f.OperatorSecret) })).StatusCode);
        Assert.Equal(200, (await GetAsync(c, "/api/v1/csrf")).Item1);
    }

    [Fact]
    public async Task Incidents_are_numbered_by_year_and_closed_only_with_their_root_cause()
    {
        f.RequireDatabase();
        Assert.Equal((422, "VALIDATION_FAILED"), await f.Panel.PostProblemAsync("/api/v1/operator/security/incidents",
            new { title = "x", severity = "SEVERE", description = "y", mfaCode = f.NextCode(f.OperatorSecret) }));
        var a = await f.Panel.PostOkAsync("/api/v1/operator/security/incidents", new
        {
            title = "Repeated sign-in failures", severity = "HIGH", description = "Forty refused sign-ins from one address in five minutes.",
            clientIps = "198.18.0.9", mfaCode = f.NextCode(f.OperatorSecret),
        });
        var b = await f.Panel.PostOkAsync("/api/v1/operator/security/incidents", new
        {
            title = "Port scan", severity = "LOW", description = "A scan of the public ports.", mfaCode = f.NextCode(f.OperatorSecret),
        });
        var year = f.Env.Clock.Now.UtcDateTime.Year;
        var na = a.GetProperty("incidentNo").GetString()!;
        var nb = b.GetProperty("incidentNo").GetString()!;
        Assert.Matches($"^INC-{year}-\\d{{3}}$", na);
        Assert.Equal(int.Parse(na[9..], System.Globalization.CultureInfo.InvariantCulture) + 1, int.Parse(nb[9..], System.Globalization.CultureInfo.InvariantCulture));

        var id = PlatformFixture.Id(a);
        Assert.Equal((422, "V-SEC-INC-ROOT"), await f.Panel.ProblemAsync(HttpMethod.Patch, $"/api/v1/operator/security/incidents/{id}",
            new { status = "CLOSED", mfaCode = f.NextCode(f.OperatorSecret) }));
        await f.Panel.OkAsync(HttpMethod.Patch, $"/api/v1/operator/security/incidents/{id}", new { status = "CONTAINED", actions = "The address was blocked.", mfaCode = f.NextCode(f.OperatorSecret) });
        var closed = await f.Panel.OkAsync(HttpMethod.Patch, $"/api/v1/operator/security/incidents/{id}",
            new { status = "CLOSED", rootCause = "A password-guessing script.", mfaCode = f.NextCode(f.OperatorSecret) });
        Assert.Equal("CLOSED", closed.GetProperty("status").GetString());
        Assert.Equal((409, "V-SEC-INC-CLOSED"), await f.Panel.ProblemAsync(HttpMethod.Patch, $"/api/v1/operator/security/incidents/{id}",
            new { status = "OPEN", mfaCode = f.NextCode(f.OperatorSecret) }));

        var list = await f.Panel.GetJsonAsync("/api/v1/operator/security/incidents");
        var row = list.GetProperty("items").EnumerateArray().Single(i => i.GetProperty("incidentNo").GetString() == na);
        Assert.Equal("The address was blocked.", row.GetProperty("actions").GetString());
        Assert.Equal(PlatformFixture.OperatorEmail, row.GetProperty("closedBy").GetString());
        var events = (await f.Panel.GetJsonAsync("/api/v1/operator/security/overview")).GetProperty("events").EnumerateArray().Select(e => e.GetProperty("action").GetString()).ToList();
        Assert.Contains("INCIDENT_OPENED", events);
        Assert.Contains("INCIDENT_CHANGED", events);
    }
}

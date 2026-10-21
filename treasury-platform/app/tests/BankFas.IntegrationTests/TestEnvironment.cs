using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using BankFas.Core.Mail;
using BankFas.Core.Security;
using BankFas.Data;
using BankFas.Data.Jobs;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace BankFas.IntegrationTests;

/// <summary>A clock the tests move forward, so each TOTP code falls in a later step than the last one accepted.</summary>
public sealed class TestClock : TimeProvider
{
    public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;
    public override DateTimeOffset GetUtcNow() => Now;
    public void NextStep() => Now = Now.AddSeconds(Totp.StepSeconds);
}

/// <summary>
/// The application against a deployed BankFas database (tools/ci/app_ci.sh): the service logins' secrets in
/// BANKFAS_IT_SECRETS (provision_logins.sh), the server in BANKFAS_IT_SERVER, and the sa password in the file
/// BANKFAS_IT_SA_FILE for the one deployment step the tests stand in for: the first operator's invitation
/// (plat.usp_BootstrapOperator, DQ-F07-3). Without them the tests are skipped, unless BANKFAS_IT_REQUIRED=1 (CI).
/// </summary>
public sealed class TestEnvironment : WebApplicationFactory<Program>
{
    public const string Domain = "bankfas.test";
    public const string OperatorHost = "admin." + Domain;
    public TestClock Clock { get; } = new();
    public string MailDir { get; } = Path.Combine(Path.GetTempPath(), "bankfas-it-mail-" + Guid.NewGuid().ToString("N"));
    private readonly string _masterKey = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));

    public static string? DbServer => Environment.GetEnvironmentVariable("BANKFAS_IT_SERVER");
    public static string? Secrets => Environment.GetEnvironmentVariable("BANKFAS_IT_SECRETS");

    public static void SkipUnlessConfigured()
    {
        if (!string.IsNullOrEmpty(DbServer) && !string.IsNullOrEmpty(Secrets)) return;
        if (Environment.GetEnvironmentVariable("BANKFAS_IT_REQUIRED") == "1")
            Assert.Fail("BANKFAS_IT_SERVER and BANKFAS_IT_SECRETS are required (tools/ci/app_ci.sh).");
        Assert.Skip("No test database: set BANKFAS_IT_SERVER and BANKFAS_IT_SECRETS (tools/ci/app_ci.sh).");
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(Settings()));
        builder.ConfigureServices(s =>
        {
            s.AddSingleton<TimeProvider>(Clock);
            s.AddSingleton<IMailSender>(new FileDropMailSender(MailDir));
        });
    }

    public Dictionary<string, string?> Settings()
    {
        var d = new Dictionary<string, string?>
        {
            ["Database:Server"] = DbServer,
            ["Database:TrustServerCertificate"] = "true",
            ["Hosts:Operator"] = OperatorHost,
            ["Portal:Domain"] = Domain,
            ["Keys:Provider"] = "local",
            ["RateLimits:Scale"] = "100",
            ["Mail:DropDirectory"] = MailDir,
            ["Keys:Local:Current"] = "local:it/1",
            ["Keys:Local:Keys:0:Ref"] = "local:it/1",
            ["Keys:Local:Keys:0:Key"] = _masterKey,
        };
        foreach (var (login, name) in new[] { (DbLogin.App, "app"), (DbLogin.Jobs, "jobs"), (DbLogin.Platform, "platform"), (DbLogin.Support, "support") })
        {
            d[$"Database:Logins:{login}:User"] = $"bankfas_{name}_a";
            d[$"Database:Logins:{login}:SecretFile"] = Path.Combine(Secrets ?? "", $"bankfas_{name}_a.secret");
        }
        return d;
    }

    /// <summary>A browser on one host: cookies kept, the CSRF token fetched and echoed on every request.</summary>
    public async Task<HttpClient> BrowserAsync(string host)
    {
        var client = CreateClient(new WebApplicationFactoryClientOptions { BaseAddress = new Uri("https://" + host), HandleCookies = true });
        var csrf = await client.GetFromJsonAsync<JsonElement>("/api/v1/csrf");
        client.DefaultRequestHeaders.Add("X-CSRF-Token", csrf.GetProperty("token").GetString());
        return client;
    }

    /// <summary>The onboarding job as the worker runs it, with this application's keys and mail drop.</summary>
    public OnboardingJob OnboardingJob() =>
        new(Services.GetRequiredService<SqlConnectionFactory>(), Services.GetRequiredService<IKeyWrapper>(), new FileDropMailSender(MailDir),
            new PortalOptions { Domain = Domain });

    /// <summary>The newest mail to an address, and the token of its link.</summary>
    public string LinkTokenSentTo(string email)
    {
        var file = Directory.EnumerateFiles(MailDir, "*.eml").OrderByDescending(File.GetLastWriteTimeUtc).ThenByDescending(f => f)
            .First(f => File.ReadAllText(f).Contains("To: " + email, StringComparison.Ordinal));
        var match = System.Text.RegularExpressions.Regex.Match(File.ReadAllText(file), "#(?:token|reenrol)=([A-Za-z0-9_-]+)");
        Assert.True(match.Success, "No link in the mail to " + email);
        return match.Groups[1].Value;
    }

    /// <summary>Stands in for the deployment: the first operator administrator's invitation, once per database.</summary>
    public static async Task<string?> BootstrapOperatorAsync(string email)
    {
        var saFile = Environment.GetEnvironmentVariable("BANKFAS_IT_SA_FILE");
        if (string.IsNullOrEmpty(saFile)) return null;
        var cs = new SqlConnectionStringBuilder
        {
            DataSource = DbServer, InitialCatalog = "BankFas", UserID = "sa", Password = File.ReadAllText(saFile).Trim(),
            Encrypt = SqlConnectionEncryptOption.Mandatory, TrustServerCertificate = true,
        };
        await using var c = new SqlConnection(cs.ConnectionString);
        await c.OpenAsync();
        await using var cmd = new SqlCommand("plat.usp_BootstrapOperator", c) { CommandType = System.Data.CommandType.StoredProcedure };
        var token = SecureTokens.NewToken();
        cmd.Parameters.AddWithValue("@Email", email);
        cmd.Parameters.AddWithValue("@DisplayName", "Integration operator");
        cmd.Parameters.AddWithValue("@Token", token);
        try { await cmd.ExecuteNonQueryAsync(); }
        catch (SqlException ex) when (ex.Number == 50023) { return null; }   // operators exist: the database is not fresh
        return Base64Url.Encode(token);
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing && Directory.Exists(MailDir)) Directory.Delete(MailDir, recursive: true);
    }
}

public static class Http
{
    /// <summary>A request as the browser sends it: JSON body, an Idempotency-Key on POST, and If-Match when given.</summary>
    public static async Task<HttpResponseMessage> SendAsync(this HttpClient client, HttpMethod method, string path, object? body = null,
        string? ifMatch = null, string? idempotencyKey = null)
    {
        using var request = new HttpRequestMessage(method, path);
        if (body is not null) request.Content = JsonContent.Create(body);
        if (method == HttpMethod.Post) request.Headers.TryAddWithoutValidation("Idempotency-Key", idempotencyKey ?? Guid.NewGuid().ToString());
        if (ifMatch is not null) request.Headers.TryAddWithoutValidation("If-Match", ifMatch);
        return await client.SendAsync(request);
    }

    public static async Task<JsonElement> OkAsync(this HttpClient client, HttpMethod method, string path, object? body = null, string? ifMatch = null)
    {
        var response = await client.SendAsync(method, path, body, ifMatch);
        var text = await response.Content.ReadAsStringAsync();
        Assert.True(response.IsSuccessStatusCode, $"{method} {path}: {(int)response.StatusCode} {text}");
        return text.Length == 0 ? default : JsonDocument.Parse(text).RootElement.Clone();
    }

    public static async Task<(int Status, string Code)> ProblemAsync(this HttpClient client, HttpMethod method, string path, object? body = null, string? ifMatch = null)
    {
        var response = await client.SendAsync(method, path, body, ifMatch);
        var text = await response.Content.ReadAsStringAsync();
        var code = text.Length > 0 && JsonDocument.Parse(text).RootElement.TryGetProperty("code", out var c) ? c.GetString()! : "";
        return ((int)response.StatusCode, code);
    }

    public static Task<JsonElement> PostOkAsync(this HttpClient client, string path, object body) => client.OkAsync(HttpMethod.Post, path, body);

    public static Task<(int Status, string Code)> PostProblemAsync(this HttpClient client, string path, object body) => client.ProblemAsync(HttpMethod.Post, path, body);

    public static async Task<JsonElement> GetJsonAsync(this HttpClient client, string path) => await client.OkAsync(HttpMethod.Get, path);

    /// <summary>GET and the ETag of the answer.</summary>
    public static async Task<(JsonElement Body, string ETag)> GetWithETagAsync(this HttpClient client, string path)
    {
        var response = await client.GetAsync(path);
        var text = await response.Content.ReadAsStringAsync();
        Assert.True(response.IsSuccessStatusCode, $"GET {path}: {(int)response.StatusCode} {text}");
        return (JsonDocument.Parse(text).RootElement.Clone(), response.Headers.ETag?.ToString() ?? "");
    }
}

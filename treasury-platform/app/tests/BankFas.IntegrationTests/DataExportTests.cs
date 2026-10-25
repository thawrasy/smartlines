using System.IO.Compression;
using System.Net;
using System.Text.Json;
using BankFas.Core.Files;
using BankFas.Core.Security;
using BankFas.Data.Jobs;
using Microsoft.Extensions.DependencyInjection;

namespace BankFas.IntegrationTests;

/// <summary>
/// The tenant data export (FR-PLT-039): the administrator asks for an export without restricted data, which needs no
/// approval; a second one waits until the first is done; the job builds the package; only the requester downloads it,
/// with a fresh confirmation and a password of 12 characters or more, and the package opens with that password into a
/// zip that holds its manifest, the tables and the account's files. An export with restricted data asked by one who
/// cannot reveal identities waits for a holder of party.identity.reveal.
/// </summary>
[Collection("database")]
public sealed class DataExportTests(PlatformFixture f)
{
    [Fact]
    public async Task The_account_is_exported_sealed_and_only_its_requester_downloads_it()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var (tm, tmSecret, _) = await f.UserWithRoleAsync(t, "TM");
        await tm.PostOkAsync("/api/v1/companies", new { companyCode = "DX1", nameAr = "شركة التصدير", nameEn = "Export Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 });

        var asked = await p.PostOkAsync("/api/v1/data-exports", new { includesRestricted = false });
        Assert.Equal("APPROVED", asked.GetProperty("status").GetString());
        var id = asked.GetProperty("id").GetString();
        Assert.Equal((409, "EXPORT_IN_PROGRESS"), await p.PostProblemAsync("/api/v1/data-exports", new { includesRestricted = false }));

        await new DataExportJob(f.Env.Db, f.Env.Services.GetRequiredService<IKeyWrapper>(), f.Env.Services.GetRequiredService<FileStore>()).RunOnceAsync(ct);
        var row = (await p.GetJsonAsync("/api/v1/data-exports")).GetProperty("items").EnumerateArray().Single(x => x.GetProperty("id").GetString() == id);
        Assert.Equal("READY", row.GetProperty("status").GetString());

        Assert.Equal((422, "VALIDATION_FAILED"), await p.PostProblemAsync($"/api/v1/data-exports/{id}/download", new { password = "short", stepUpCode = f.NextCode(t.AdminSecret) }));
        const string password = "a long export password";
        var res = await p.SendAsync(HttpMethod.Post, $"/api/v1/data-exports/{id}/download", new { password, stepUpCode = f.NextCode(t.AdminSecret) });
        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        var sealedPackage = await res.Content.ReadAsByteArrayAsync(ct);
        Assert.Equal("Salted__", System.Text.Encoding.ASCII.GetString(sealedPackage, 0, 8));
        using (var zip = new ZipArchive(new MemoryStream(ExportSeal.Open(sealedPackage, password)), ZipArchiveMode.Read))
        {
            using var manifest = JsonDocument.Parse(zip.GetEntry("manifest.json")!.Open());
            Assert.Contains(manifest.RootElement.GetProperty("tables").EnumerateArray(), x => x.GetProperty("table").GetString() == "org.Company");
            var companies = zip.Entries.Single(e => e.FullName == "data/org.Company.json");
            using var reader = new StreamReader(companies.Open());
            Assert.Contains("Export Co", await reader.ReadToEndAsync(ct), StringComparison.Ordinal);
        }
        Assert.Equal(403, (await tm.PostProblemAsync($"/api/v1/data-exports/{id}/download", new { password, stepUpCode = f.NextCode(tmSecret) })).Status);

        // With restricted data: the treasury manager reveals identities, so theirs is approved; one by another waits.
        var (ta2, _, _) = await f.UserWithRoleAsync(t, "TA");
        var waiting = await ta2.PostOkAsync("/api/v1/data-exports", new { includesRestricted = true });
        Assert.Equal("REQUESTED", waiting.GetProperty("status").GetString());
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/data-exports/{waiting.GetProperty("id").GetString()}/approve");
        Assert.Equal((409, "INVALID_STATE"), await tm.ProblemAsync(HttpMethod.Post, $"/api/v1/data-exports/{waiting.GetProperty("id").GetString()}/approve"));
    }
}

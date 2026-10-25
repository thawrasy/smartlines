using System.Diagnostics;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// PDF from the platform's own printed pages (docs/31 row 52, ADR 0051): the proforma, the terms, a request and a report
/// are self-contained HTML (Arabic and English, right to left), and a headless Chromium prints them to PDF, which shapes
/// Arabic text correctly where the PDF libraries do not. Each print runs in a new empty profile under the temp folder,
/// with every host name unresolvable, so a page never reaches the network; two prints run at once at most, and one
/// that takes more than a minute is stopped. The binary is <c>Pdf:Chromium</c>, else the first of the usual places; the
/// API image carries Chromium and an Arabic font (DOC-S16).
/// </summary>
public sealed partial class PdfRenderer(IConfiguration config, ILogger<PdfRenderer> logger)
{
    private static readonly SemaphoreSlim Gate = new(2);

    private static readonly string[] Candidates =
    [
        "/opt/pw-browsers/chromium", "/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/google-chrome", "/usr/lib/chromium/chromium",
    ];

    /// <summary>The Chromium binary, or null when there is none (the PDF endpoints then answer 503).</summary>
    public string? Binary => config["Pdf:Chromium"] is { Length: > 0 } p ? p : Candidates.FirstOrDefault(File.Exists);

    public bool Available => Binary is not null;

    /// <summary>The PDF of a self-contained HTML page; throws <see cref="InvalidOperationException"/> when it cannot be made.</summary>
    public async Task<byte[]> RenderAsync(string html, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(html);
        var binary = Binary ?? throw new InvalidOperationException("No Chromium is installed for the PDF output (Pdf:Chromium).");
        var dir = Directory.CreateTempSubdirectory("bankfas-pdf-");
        await Gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var input = Path.Combine(dir.FullName, "page.html");
            var output = Path.Combine(dir.FullName, "page.pdf");
            await File.WriteAllTextAsync(input, html, System.Text.Encoding.UTF8, ct).ConfigureAwait(false);
            var start = new ProcessStartInfo(binary)
            {
                RedirectStandardError = true, RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true,
            };
            foreach (var a in new[]
                     {
                         "--headless", "--no-sandbox", "--disable-gpu", "--disable-extensions", "--disable-background-networking", "--disable-sync",
                         "--no-first-run", "--no-default-browser-check", "--mute-audio", "--no-pdf-header-footer",
                         "--host-resolver-rules=MAP * ~NOTFOUND", $"--user-data-dir={Path.Combine(dir.FullName, "profile")}",
                         $"--print-to-pdf={output}", new Uri(input).AbsoluteUri,
                     })
                start.ArgumentList.Add(a);
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Chromium did not start.");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromMinutes(1));
            var stderr = process.StandardError.ReadToEndAsync(timeout.Token);
            _ = process.StandardOutput.ReadToEndAsync(timeout.Token);
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                process.Kill(entireProcessTree: true);
                throw new InvalidOperationException("The PDF print took more than a minute.");
            }
            var pdf = File.Exists(output) ? await File.ReadAllBytesAsync(output, ct).ConfigureAwait(false) : [];
            if (pdf.Length < 5 || pdf[0] != '%' || pdf[1] != 'P' || pdf[2] != 'D' || pdf[3] != 'F')
            {
                LogFailed(logger, process.ExitCode, (await stderr.ConfigureAwait(false)).Length);
                throw new InvalidOperationException("Chromium gave no PDF.");
            }
            return pdf;
        }
        finally
        {
            Gate.Release();
            try { dir.Delete(recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    [LoggerMessage(Level = LogLevel.Warning, Message = "The PDF print failed: exit code {ExitCode}, {ErrorLength} characters of error output")]
    private static partial void LogFailed(ILogger logger, int exitCode, int errorLength);
}

/// <summary>The PDF answer of a printed page: <c>format=pdf</c> asks for it; without Chromium the answer is 503 PDF_UNAVAILABLE.</summary>
public static class Pdf
{
    public static bool Wanted(HttpRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return request.Query["format"].ToString() switch
        {
            "" or "html" => false,
            "pdf" => true,
            _ => throw ApiProblemException.Invalid("VALIDATION_FAILED", "The format is html or pdf."),
        };
    }

    public static async Task<IResult> FileAsync(PdfRenderer renderer, string html, string fileName, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(renderer);
        if (!renderer.Available) throw new ApiProblemException(503, "PDF_UNAVAILABLE", "The PDF output is not installed on this server; print the page from the browser.");
        try
        {
            return Results.File(await renderer.RenderAsync(html, ct), "application/pdf", fileName);
        }
        catch (InvalidOperationException)
        {
            throw new ApiProblemException(503, "PDF_UNAVAILABLE", "The PDF could not be made; try again or print the page from the browser.");
        }
    }
}

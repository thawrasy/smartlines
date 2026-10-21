// The BankFas web application: the tenant portal and the operator panel API (DOC-B04), on ASP.NET Core (ADR 0040).
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/health/live", () => Results.Ok(new { status = "live" }));

app.Run();

/// <summary>The entry point, visible to the integration tests (WebApplicationFactory).</summary>
public partial class Program;

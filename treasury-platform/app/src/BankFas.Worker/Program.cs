// The background job worker of BankFas (DOC-F17): runs the platform and tenant jobs of cfg.JobDefinition with the
// login bankfas_jobs_<set> (tp_jobs, ADR 0009), a separate process from the web server, which never holds that secret.
using BankFas.Core.Mail;
using BankFas.Core.Security;
using BankFas.Data;
using BankFas.Data.Jobs;
using BankFas.Worker;
using Microsoft.Extensions.Options;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.Configure<DatabaseOptions>(builder.Configuration.GetSection(DatabaseOptions.Section));
builder.Services.Configure<PortalOptions>(builder.Configuration.GetSection(PortalOptions.Section));
builder.Services.AddSingleton<SqlConnectionFactory>();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<IKeyWrapper>(_ => KeyWrapperFactory.Create(builder.Configuration, builder.Environment));
builder.Services.AddSingleton<IMailSender>(_ => new FileDropMailSender(builder.Configuration["Mail:DropDirectory"]
    ?? throw new InvalidOperationException("Mail:DropDirectory is not set; the SMTP relay comes with the hosting decision (docs/42).")));
builder.Services.AddSingleton(sp => sp.GetRequiredService<IOptions<PortalOptions>>().Value);
builder.Services.AddSingleton<OnboardingJob>();
builder.Services.AddHostedService<JobLoop>();
builder.Build().Run();

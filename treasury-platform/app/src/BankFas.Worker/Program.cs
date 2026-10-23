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
builder.Services.AddSingleton<BankFas.Core.Mail.IMailSender>(_ => BankFas.Core.Mail.MailSenders.Create(k => builder.Configuration[k],
    () => builder.Configuration.GetSection("Mail:Smtp").Get<BankFas.Core.Mail.SmtpOptions>() ?? new()));
builder.Services.AddSingleton(sp => sp.GetRequiredService<IOptions<PortalOptions>>().Value);
builder.Services.AddSingleton(new BankFas.Data.Seeding.SeedPacks(BankFas.Data.Seeding.TenantSeeder.PacksDirectory(builder.Configuration["Seed:PacksDirectory"])));
builder.Services.AddSingleton<OnboardingJob>();
builder.Services.AddSingleton<SeedUpgradeJob>();
builder.Services.AddSingleton<OutboxJob>();
builder.Services.AddSingleton<NotificationDispatchJob>();
builder.Services.AddSingleton<BankFas.Data.Facilities.FacilityValidityJob>();
builder.Services.AddSingleton<BankFas.Data.Facilities.ObligationCalendarJob>();
builder.Services.AddSingleton<BankFas.Data.Finance.FinanceEvaluationJob>();
builder.Services.AddSingleton<ExpiryAlertJob>();
builder.Services.AddSingleton<SignatoryExpiryJob>();
builder.Services.AddSingleton<GovernanceJob>();
builder.Services.AddSingleton<OutboxPurgeJob>();
builder.Services.AddSingleton<JobRunPurgeJob>();
builder.Services.AddSingleton<TrialReminderJob>();
builder.Services.AddHostedService<JobLoop>();
builder.Build().Run();

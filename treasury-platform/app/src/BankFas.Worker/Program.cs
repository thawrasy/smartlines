// The background job worker of BankFas (DOC-F17): runs the platform and tenant jobs of cfg.JobDefinition with the
// login bankfas_jobs_<set> (tp_jobs, ADR 0009). The jobs are registered in BankFas.Worker.Jobs (ADR 0040).
var builder = Host.CreateApplicationBuilder(args);
var host = builder.Build();
host.Run();

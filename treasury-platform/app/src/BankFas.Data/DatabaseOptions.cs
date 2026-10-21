namespace BankFas.Data;

/// <summary>The database login of a process (ADR 0009): each holds the secret of its own login only.</summary>
public enum DbLogin
{
    /// <summary>bankfas_app_*: the tenant portal (tp_app).</summary>
    App,
    /// <summary>bankfas_jobs_*: the job worker, a separate process (tp_jobs).</summary>
    Jobs,
    /// <summary>bankfas_platform_*: the operator panel (tp_platform).</summary>
    Platform,
    /// <summary>bankfas_support_*: the support connections inside the operator panel (tp_support).</summary>
    Support,
}

/// <summary>One login: its name and the file of its secret, which the process's secret store provides (DOC-S08 section 5).</summary>
public sealed class DbLoginOptions
{
    public string User { get; set; } = "";
    public string SecretFile { get; set; } = "";
}

/// <summary>Configuration section "Database".</summary>
public sealed class DatabaseOptions
{
    public const string Section = "Database";

    /// <summary>Server name as on its certificate, with an optional ",port".</summary>
    public string Server { get; set; } = "";
    public string Database { get; set; } = "BankFas";

    /// <summary>
    /// Development and CI only: accept a self-signed server certificate. The deployment never does (ADR 0013); the
    /// application refuses this setting outside the Development and Testing environments.
    /// </summary>
    public bool TrustServerCertificate { get; set; }

    public int CommandTimeoutSeconds { get; set; } = 30;
    public Dictionary<DbLogin, DbLoginOptions> Logins { get; set; } = [];
}

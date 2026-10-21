using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace BankFas.Data;

/// <summary>
/// Opens connections for one login. Pooling stays on: the driver resets each pooled connection, which clears the
/// session context, and the database refuses a second binding of one connection (50004). One request, one
/// connection, bound first (DOC-F04 section 5); no MARS, so one connection is one binding.
/// </summary>
public sealed class SqlConnectionFactory
{
    private readonly DatabaseOptions _options;
    private readonly Dictionary<DbLogin, string> _connectionStrings = [];

    public SqlConnectionFactory(IOptions<DatabaseOptions> options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _options = options.Value;
    }

    public int CommandTimeoutSeconds => _options.CommandTimeoutSeconds;

    public async Task<SqlConnection> OpenAsync(DbLogin login, CancellationToken cancellationToken = default)
    {
        var connection = new SqlConnection(ConnectionString(login));
        try
        {
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private string ConnectionString(DbLogin login)
    {
        lock (_connectionStrings)
        {
            if (_connectionStrings.TryGetValue(login, out var cached)) return cached;
            if (!_options.Logins.TryGetValue(login, out var l) || string.IsNullOrEmpty(l.User) || string.IsNullOrEmpty(l.SecretFile))
                throw new InvalidOperationException($"No database login is configured for {login}.");
            var secret = File.ReadAllText(l.SecretFile).Trim();
            var builder = new SqlConnectionStringBuilder
            {
                DataSource = _options.Server,
                InitialCatalog = _options.Database,
                UserID = l.User,
                Password = secret,
                Encrypt = SqlConnectionEncryptOption.Mandatory,
                TrustServerCertificate = _options.TrustServerCertificate,
                MultipleActiveResultSets = false,
                Pooling = true,
                ApplicationName = "BankFas-" + login,
                CommandTimeout = _options.CommandTimeoutSeconds,
            };
            return _connectionStrings[login] = builder.ConnectionString;
        }
    }
}

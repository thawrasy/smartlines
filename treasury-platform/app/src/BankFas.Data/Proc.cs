using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data;

/// <summary>Stored procedure calls with typed parameters; never SQL text built from values (DOC-S08 E10).</summary>
internal sealed class Proc
{
    private readonly DynamicParameters _p = new();
    private readonly string _name;

    private Proc(string name) => _name = name;

    public static Proc Named(string name) => new(name);

    public Proc In(string name, object? value, DbType type, int? size = null)
    {
        _p.Add(name, value, type, ParameterDirection.Input, size);
        return this;
    }

    public Proc Out(string name, DbType type, int? size = null)
    {
        _p.Add(name, null, type, ParameterDirection.Output, size);
        return this;
    }

    public T Get<T>(string name) => _p.Get<T>(name);

    public Task ExecAsync(SqlConnection connection, CancellationToken ct, SqlTransaction? transaction = null) =>
        connection.ExecuteAsync(new CommandDefinition(_name, _p, transaction, commandType: CommandType.StoredProcedure, cancellationToken: ct));

    public Task<IEnumerable<T>> QueryAsync<T>(SqlConnection connection, CancellationToken ct, SqlTransaction? transaction = null) =>
        connection.QueryAsync<T>(new CommandDefinition(_name, _p, transaction, commandType: CommandType.StoredProcedure, cancellationToken: ct));
}

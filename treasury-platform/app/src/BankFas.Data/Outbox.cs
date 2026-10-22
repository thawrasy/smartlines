using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data;

/// <summary>
/// An event of the tenant in the transaction of the change it reports (FR-PLT-042, DOC-F17 section 4): committed with
/// the change or not at all. Names are domain.event in lower case; the payload holds references and codes, never a
/// restricted value.
/// </summary>
public static class Outbox
{
    public static Task EmitAsync(SqlConnection c, SqlTransaction? tx, string eventName, string aggregateType, long aggregateId, object payload, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition(
            """
            INSERT cfg.OutboxEvent (TenantId, EventName, AggregateType, AggregateId, PayloadJson, CorrelationId, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @eventName, @aggregateType, @aggregateId, @payload,
                    CAST(SESSION_CONTEXT(N'CorrelationId') AS UNIQUEIDENTIFIER), CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new { eventName, aggregateType, aggregateId, payload = JsonSerializer.Serialize(payload) }, tx, cancellationToken: ct));
}

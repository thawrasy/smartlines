using System.Data;
using System.Security.Cryptography;
using System.Text.Json;
using BankFas.Core.Mail;
using BankFas.Core.Security;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Jobs;

/// <summary>Where the links in e-mails point: https://{code}.{PortalDomain}/... (FR-PLT-046).</summary>
public sealed class PortalOptions
{
    public const string Section = "Portal";
    public string Domain { get; set; } = "bankfas.com";
    public string Scheme { get; set; } = "https";

    /// <summary>A port for development, else null.</summary>
    public int? Port { get; set; }

    /// <summary>The URL of a page of the tenant's portal; a fragment (#...) stays a fragment, so a token in it never reaches a server.</summary>
    public Uri TenantUri(string tenantCode, string pathQueryAndFragment)
    {
        var builder = new UriBuilder(Scheme, tenantCode + "." + Domain, Port ?? -1);
        var rest = pathQueryAndFragment;
        var hash = rest.IndexOf('#', StringComparison.Ordinal);
        if (hash >= 0) { builder.Fragment = rest[(hash + 1)..]; rest = rest[..hash]; }
        var q = rest.IndexOf('?', StringComparison.Ordinal);
        if (q >= 0) { builder.Query = rest[(q + 1)..]; rest = rest[..q]; }
        builder.Path = rest;
        return builder.Uri;
    }
}

/// <summary>
/// JOB-PLT-ONBOARD (DOC-F05 4.3, ADR 0004): for each tenant.created event, bound as the tenant's service account,
/// (1) claims the event, (2) creates the tenant keys DATA, BLIND_INDEX and FILE (version 1, wrapped by the master key
/// outside the database), (3) seeds the system roles (sec.usp_SeedCoreRoles), (4) gives the first administrator every
/// company (DQ-F07-2) and the TA role with an invitation link (sec.usp_InviteFirstAdministrator), then (5) sends the
/// e-mail and records whether it went. Each step is safe to run again: keys that exist are kept, the seed inserts
/// only what is missing, and a new invitation replaces an unused one.
/// </summary>
public sealed class OnboardingJob(SqlConnectionFactory db, IKeyWrapper keys, IMailSender mail, PortalOptions portal)
{
    public const string JobKey = "JOB-PLT-ONBOARD";
    private static readonly string[] KeyPurposes = ["DATA", "BLIND_INDEX", "FILE"];
    private readonly string _workerId = "onboard-" + Environment.MachineName;

    /// <summary>Runs one pass over every tenant the job may bind to; returns the number of events delivered.</summary>
    public async Task<int> RunOnceAsync(CancellationToken ct)
    {
        IReadOnlyList<JobTenant> tenants;
        await using (var list = await db.OpenAsync(DbLogin.Jobs, ct).ConfigureAwait(false))
            tenants = await JobProcedures.ListTenantsAsync(list, JobKey, ct).ConfigureAwait(false);
        var delivered = 0;
        foreach (var t in tenants)
        {
            if (await OnboardTenantAsync(t.TenantId, ct).ConfigureAwait(false)) delivered++;
        }
        return delivered;
    }

    /// <summary>Handles the pending tenant.created event of one tenant, if any. True when one was delivered.</summary>
    public async Task<bool> OnboardTenantAsync(int tenantId, CancellationToken ct)
    {
        var correlation = Guid.NewGuid();
        await using var c = await db.OpenAsync(DbLogin.Jobs, ct).ConfigureAwait(false);
        await JobProcedures.BindAsync(c, tenantId, JobKey, correlation, ct).ConfigureAwait(false);

        var ev = await c.QuerySingleOrDefaultAsync<(long Id, string Payload, int Attempts)>(new CommandDefinition(
            """
            UPDATE TOP (1) e WITH (UPDLOCK, READPAST, ROWLOCK)
               SET Status = 'PROCESSING', LockedBy = @me, LockedUntil = DATEADD(MINUTE, 5, SYSUTCDATETIME()),
                   AttemptCount = AttemptCount + 1, CorrelationId = @corr
            OUTPUT inserted.OutboxEventId, inserted.PayloadJson, inserted.AttemptCount
              FROM cfg.OutboxEvent AS e
             WHERE e.EventName = 'tenant.created'
               AND (e.Status = 'PENDING' OR (e.Status = 'FAILED' AND e.NextAttemptAt <= SYSUTCDATETIME())
                    OR (e.Status = 'PROCESSING' AND e.LockedUntil < SYSUTCDATETIME()));
            """, new { me = _workerId, corr = correlation }, cancellationToken: ct)).ConfigureAwait(false);
        if (ev.Id == 0) return false;

        var runId = await c.ExecuteScalarAsync<long>(new CommandDefinition(
            "INSERT cfg.JobRun (TenantId, JobKey, TriggerKind, AttemptNo) OUTPUT inserted.JobRunId VALUES (@t, @k, @kind, @n);",
            new { t = tenantId, k = JobKey, kind = ev.Attempts > 1 ? "RETRY" : "SCHEDULED", n = ev.Attempts }, cancellationToken: ct)).ConfigureAwait(false);
        try
        {
            using var payload = JsonDocument.Parse(ev.Payload);
            var adminUserId = payload.RootElement.GetProperty("adminUserId").GetInt64();

            var created = await EnsureKeysAsync(c, tenantId, correlation, ct).ConfigureAwait(false);

            var token = SecureTokens.NewToken();
            string sentTo;
            int rolesCreated;
            await using (var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false))
            {
                (rolesCreated, _) = await JobProcedures.SeedCoreRolesAsync(c, tx, ct).ConfigureAwait(false);
                await c.ExecuteAsync(new CommandDefinition(
                    "UPDATE sec.AppUser SET CompanyScopeMode = 'ALL' WHERE AppUserId = @u AND CompanyScopeMode <> 'ALL';",
                    new { u = adminUserId }, tx, cancellationToken: ct)).ConfigureAwait(false);
                sentTo = await JobProcedures.InviteFirstAdministratorAsync(c, tx, adminUserId, token, ct).ConfigureAwait(false);
                await tx.CommitAsync(ct).ConfigureAwait(false);
            }

            var code = await c.ExecuteScalarAsync<string>(new CommandDefinition("SELECT Code FROM plat.v_CurrentTenant;", cancellationToken: ct)).ConfigureAwait(false);
            var sendStatus = "SENT";
            string? sendError = null;
            try
            {
                var link = portal.TenantUri(code!, "/invitation#token=" + Base64Url.Encode(token));
                await mail.SendAsync(new OutgoingMail(sentTo, "Your BankFas account",
                    $"You are the first administrator of your company's BankFas account.\r\nSet your password within 48 hours: {link}\r\n"), ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException or System.Net.Mail.SmtpException)
            {
                (sendStatus, sendError) = ("FAILED", TenantAuthProcedures.Truncate(ex.Message, 500));
            }
            await c.ExecuteAsync(new CommandDefinition(
                """
                UPDATE sec.UserToken SET SendStatus = @s, SendError = @err
                 WHERE UserId = @u AND Purpose = 'INVITATION' AND TokenHash = @h;
                UPDATE cfg.OutboxEvent SET Status = @evStatus, DeliveredAt = CASE WHEN @evStatus = 'DELIVERED' THEN SYSUTCDATETIME() END,
                       NextAttemptAt = CASE WHEN @evStatus = 'FAILED' THEN DATEADD(MINUTE, 5, SYSUTCDATETIME()) END,
                       LastError = @err, LockedBy = NULL, LockedUntil = NULL
                 WHERE OutboxEventId = @id AND Status = 'PROCESSING' AND LockedBy = @me;
                UPDATE cfg.JobRun SET Status = @runStatus, FinishedAt = SYSUTCDATETIME(),
                       DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()), ResultSummary = @summary, ErrorMessage = @err
                 WHERE JobRunId = @run;
                """,
                new
                {
                    s = sendStatus, err = sendError, u = adminUserId, h = SecureTokens.Sha256(token), id = ev.Id, me = _workerId, run = runId,
                    evStatus = sendStatus == "SENT" ? "DELIVERED" : "FAILED", runStatus = sendStatus == "SENT" ? "SUCCEEDED" : "FAILED",
                    summary = $"keys created {created}, roles created {rolesCreated}, invitation {sendStatus.ToLowerInvariant()}",
                }, cancellationToken: ct)).ConfigureAwait(false);
            return sendStatus == "SENT";
        }
        catch (Exception ex) when (ex is SqlException or CryptographicException or JsonException or KeyNotFoundException)
        {
            await c.ExecuteAsync(new CommandDefinition(
                """
                UPDATE cfg.OutboxEvent SET Status = CASE WHEN AttemptCount >= 5 THEN 'DEAD' ELSE 'FAILED' END,
                       NextAttemptAt = DATEADD(MINUTE, CASE AttemptCount WHEN 1 THEN 1 WHEN 2 THEN 5 WHEN 3 THEN 30 ELSE 120 END, SYSUTCDATETIME()),
                       LastError = @err, LockedBy = NULL, LockedUntil = NULL
                 WHERE OutboxEventId = @id AND Status = 'PROCESSING' AND LockedBy = @me;
                UPDATE cfg.JobRun SET Status = 'FAILED', FinishedAt = SYSUTCDATETIME(), DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()),
                       ErrorMessage = @err, NextRetryAt = DATEADD(MINUTE, 5, SYSUTCDATETIME())
                 WHERE JobRunId = @run;
                """, new { err = TenantAuthProcedures.Truncate(ex.Message, 1000), id = ev.Id, me = _workerId, run = runId },
                cancellationToken: ct)).ConfigureAwait(false);
            throw;
        }
    }

    /// <summary>Creates version 1 of each tenant key purpose that has no ACTIVE key; returns how many were created.</summary>
    private async Task<int> EnsureKeysAsync(SqlConnection c, int tenantId, Guid correlation, CancellationToken ct)
    {
        var active = (await c.QueryAsync<string>(new CommandDefinition(
            "SELECT Purpose FROM sec.TenantKey WHERE Status = 'ACTIVE';", cancellationToken: ct)).ConfigureAwait(false)).ToHashSet(StringComparer.Ordinal);
        var created = 0;
        foreach (var purpose in KeyPurposes.Where(p => !active.Contains(p)))
        {
            var version = await c.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT ISNULL(MAX(KeyVersion), 0) + 1 FROM sec.TenantKey WHERE Purpose = @p;", new { p = purpose }, cancellationToken: ct)).ConfigureAwait(false);
            var key = RandomNumberGenerator.GetBytes(Envelope.KeyBytes);
            byte[] wrapped;
            try { wrapped = keys.Wrap(keys.CurrentMasterKeyRef, key, EnvelopeAad.ForTenantKey(tenantId, purpose, version)); }
            finally { CryptographicOperations.ZeroMemory(key); }
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            await c.ExecuteAsync(new CommandDefinition(
                """
                DECLARE @k TABLE (Id BIGINT);
                INSERT sec.TenantKey (TenantId, Purpose, KeyVersion, Status, WrappedKey, MasterKeyRef)
                OUTPUT inserted.TenantKeyId INTO @k VALUES (@t, @p, @v, 'PENDING', @w, @ref);
                UPDATE sec.TenantKey SET Status = 'ACTIVE', ActivatedAt = SYSUTCDATETIME() WHERE TenantKeyId = (SELECT Id FROM @k);
                INSERT sec.KeyEvent (TenantId, TenantKeyId, EventType, ActorType, CorrelationId)
                SELECT @t, Id, e.EventType, 'JOB', @corr FROM @k CROSS JOIN (VALUES ('CREATED'), ('ACTIVATED')) AS e(EventType);
                """, new { t = tenantId, p = purpose, v = version, w = wrapped, @ref = keys.CurrentMasterKeyRef, corr = correlation },
                tx, cancellationToken: ct)).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
            created++;
        }
        return created;
    }
}

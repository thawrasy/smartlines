using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Workflow;

/// <summary>A delegation asked for (FR-WFL-020): from a user to another for a period, all tasks, approvals only or one request type.</summary>
public sealed record NewDelegation(long FromUserId, long ToUserId, DateOnly StartsOn, DateOnly EndsOn, string Scope, string? RequestTypeCode, string? Reason);

/// <summary>
/// Delegations (FR-WFL-020, BR-WFL-021, V-WFL-06; spec 13 section 8): the database holds the shape (not to oneself, the
/// dates in order, the type with its scope, the revocation with its time); this class holds the rest. A user delegates
/// their own work with req.delegate.own, or anyone's with req.delegate.manage; the period starts today or later and is
/// at most wfl.delegation.max_days; the delegator's periods do not overlap; there is no chain (the delegate has no
/// delegation of their own in the period, and the engine acts only on the delegator's own slots); the delegate is an
/// active user. Revoking is immediate. A delegation starting today is ACTIVE at once; JOB-WFL-DELEGATION moves the rest.
/// </summary>
public static class Delegations
{
    public static async Task<(long Id, Guid PublicId)> CreateAsync(SqlConnection c, SqlTransaction tx, Actor actor, NewDelegation d, DateOnly today, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        ArgumentNullException.ThrowIfNull(d);
        if (!(d.FromUserId == actor.UserId ? actor.Permissions.Contains("req.delegate.own") || actor.Permissions.Contains("req.delegate.manage")
                : actor.Permissions.Contains("req.delegate.manage")))
            throw WorkflowRefusalException.Forbidden("You may not delegate this user's work.");
        if (d.FromUserId == d.ToUserId) throw WorkflowRefusalException.Missing("V-WFL-06", "A user does not delegate to themselves.");
        if (d.StartsOn < today) throw WorkflowRefusalException.Missing("V-WFL-06", "A delegation starts today or later.");
        if (d.EndsOn < d.StartsOn) throw WorkflowRefusalException.Missing("V-WFL-06", "A delegation ends on or after its start.");
        var max = int.TryParse((await FacilityHooks.SettingsAsync(c, tx, ct, "wfl.delegation.max_days").ConfigureAwait(false)).GetValueOrDefault("wfl.delegation.max_days"), out var m) ? m : 90;
        if (d.EndsOn.DayNumber - d.StartsOn.DayNumber + 1 > max) throw WorkflowRefusalException.Missing("V-WFL-06", $"A delegation lasts at most {max} days.");
        if (d.Scope is not ("ALL" or "APPROVALS_ONLY" or "REQUEST_TYPE")) throw WorkflowRefusalException.Missing("V-WFL-06", "The scope is ALL, APPROVALS_ONLY or REQUEST_TYPE.");
        int? typeId = null;
        if (d.Scope == "REQUEST_TYPE")
            typeId = await c.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT RequestTypeId FROM wfl.RequestType WHERE Code = @code;", new { code = d.RequestTypeCode }, tx,
                cancellationToken: ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.Missing("V-WFL-06", "The request type of the delegation is not known.");
        var to = await c.QuerySingleOrDefaultAsync<(string Status, bool IsSystemUser)?>(new CommandDefinition(
            "SELECT Status, IsSystemUser FROM sec.AppUser WHERE AppUserId = @u AND ArchivedAt IS NULL;", new { u = d.ToUserId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (to is not { Status: "ACTIVE", IsSystemUser: false }) throw WorkflowRefusalException.Missing("V-WFL-06", "The delegate is an active user.");
        var clash = await c.QuerySingleAsync<(int Overlap, int Chain)>(new CommandDefinition(
            """
            SELECT (SELECT COUNT(*) FROM wfl.UserDelegation WITH (UPDLOCK, HOLDLOCK)
                     WHERE FromUserId = @f AND Status IN ('SCHEDULED', 'ACTIVE') AND StartsOn <= @e AND EndsOn >= @s),
                   (SELECT COUNT(*) FROM wfl.UserDelegation
                     WHERE ((FromUserId = @t) OR (ToUserId = @f)) AND Status IN ('SCHEDULED', 'ACTIVE') AND StartsOn <= @e AND EndsOn >= @s);
            """, new { f = d.FromUserId, t = d.ToUserId, s = d.StartsOn.ToDateTime(TimeOnly.MinValue), e = d.EndsOn.ToDateTime(TimeOnly.MinValue) }, tx, cancellationToken: ct))
            .ConfigureAwait(false);
        if (clash.Overlap > 0) throw WorkflowRefusalException.Missing("V-WFL-06", "The user already has a delegation in this period.");
        if (clash.Chain > 0) throw WorkflowRefusalException.Missing("V-WFL-06", "A delegation does not chain: the delegate is away, or the delegator acts for someone else, in this period.");
        var row = await c.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT wfl.UserDelegation (TenantId, FromUserId, ToUserId, StartsOn, EndsOn, Scope, RequestTypeId, Reason, Status, CreatedBy)
            OUTPUT inserted.UserDelegationId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @t, @s, @e, @scope, @type, @reason, @status, @actor);
            SELECT Id, PublicId FROM @o;
            """,
            new
            {
                f = d.FromUserId, t = d.ToUserId, s = d.StartsOn.ToDateTime(TimeOnly.MinValue), e = d.EndsOn.ToDateTime(TimeOnly.MinValue), scope = d.Scope, type = typeId,
                reason = d.Reason, status = d.StartsOn <= today ? "ACTIVE" : "SCHEDULED", actor = actor.UserId,
            }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await Notifier.RequestAsync(c, tx, new NotificationRequest("REQ.DELEGATION", "wfl.UserDelegation", row.Id, $"REQ.DELEGATION:{row.Id}:created", null,
            new Dictionary<string, object?> { ["startsOn"] = d.StartsOn.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture),
                ["endsOn"] = d.EndsOn.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture) },
            "/delegations", actor.UserId, [d.FromUserId, d.ToUserId]), ct).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "delegation.created", "wfl.UserDelegation", row.Id, new { delegationId = row.Id }, ct).ConfigureAwait(false);
        return row;
    }

    /// <summary>The revocation (BR-WFL-021): immediate, by the delegator or a holder of req.delegate.manage, of a delegation not yet ended.</summary>
    public static async Task RevokeAsync(SqlConnection c, SqlTransaction tx, Actor actor, Guid publicId, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        var d = await c.QuerySingleOrDefaultAsync<(long Id, long FromUserId, string Status)?>(new CommandDefinition(
            "SELECT UserDelegationId, FromUserId, Status FROM wfl.UserDelegation WITH (UPDLOCK) WHERE PublicId = @p;", new { p = publicId }, tx, cancellationToken: ct))
            .ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        if (d.FromUserId != actor.UserId && !actor.Permissions.Contains("req.delegate.manage")) throw WorkflowRefusalException.NotFound();
        if (d.Status is not ("SCHEDULED" or "ACTIVE")) throw WorkflowRefusalException.State("The delegation has already ended.");
        await c.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.UserDelegation SET Status = 'REVOKED', RevokedAt = SYSUTCDATETIME(), RevokedBy = @u, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE UserDelegationId = @id;",
            new { u = actor.UserId, id = d.Id }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "delegation.revoked", "wfl.UserDelegation", d.Id, new { delegationId = d.Id }, ct).ConfigureAwait(false);
    }

    /// <summary>The tenant's date at an instant, in its time zone (UTC when the zone is unknown).</summary>
    public static async Task<DateTime> TodayAsync(SqlConnection c, SqlTransaction? tx, DateTimeOffset now, CancellationToken ct)
    {
        var zone = await c.ExecuteScalarAsync<string>(new CommandDefinition("SELECT TimeZone FROM plat.v_CurrentTenant;", transaction: tx, cancellationToken: ct)).ConfigureAwait(false);
        return (zone is not null && TimeZoneInfo.TryFindSystemTimeZoneById(zone, out var z) ? TimeZoneInfo.ConvertTime(now, z) : now.ToUniversalTime()).Date;
    }

    /// <summary>FR-WFL-036: a delegate sees a request while a pending slot of their delegator's (their own or by a role of theirs) waits on it, in the period.</summary>
    public static async Task<bool> SeesAsync(SqlConnection c, SqlTransaction? tx, long requestId, int requestTypeId, long userId, DateTimeOffset now, CancellationToken ct)
    {
        var today = await TodayAsync(c, tx, now, ct).ConfigureAwait(false);
        return await c.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT CASE WHEN EXISTS (
                SELECT 1 FROM wfl.UserDelegation AS d JOIN wfl.RequestApproval AS a ON a.RequestId = @r AND a.Decision = 'PENDING'
                 WHERE d.ToUserId = @u AND d.Status IN ('SCHEDULED', 'ACTIVE') AND @today BETWEEN d.StartsOn AND d.EndsOn
                   AND (d.Scope <> 'REQUEST_TYPE' OR d.RequestTypeId = @type)
                   AND (a.AssignedUserId = d.FromUserId
                        OR (a.AssignedUserId IS NULL AND a.AssignedRoleId IN (SELECT ur.RoleId FROM sec.UserRole AS ur WHERE ur.UserId = d.FromUserId))))
                 THEN 1 ELSE 0 END;
            """, new { r = requestId, u = userId, today, type = requestTypeId }, tx, cancellationToken: ct)).ConfigureAwait(false) == 1;
    }

    /// <summary>JOB-WFL-DELEGATION: scheduled delegations whose day has come are ACTIVE, and the ones past their end ENDED, on the tenant's date.</summary>
    public static async Task<(int Started, int Ended)> AdvanceAsync(SqlConnection c, DateOnly today, CancellationToken ct)
    {
        var day = today.ToDateTime(TimeOnly.MinValue);
        var ended = await c.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.UserDelegation SET Status = 'ENDED', UpdatedAt = SYSUTCDATETIME() WHERE Status IN ('SCHEDULED', 'ACTIVE') AND EndsOn < @d;", new { d = day },
            cancellationToken: ct)).ConfigureAwait(false);
        var started = await c.ExecuteAsync(new CommandDefinition(
            "UPDATE wfl.UserDelegation SET Status = 'ACTIVE', UpdatedAt = SYSUTCDATETIME() WHERE Status = 'SCHEDULED' AND StartsOn <= @d;", new { d = day },
            cancellationToken: ct)).ConfigureAwait(false);
        return (started, ended);
    }
}

using System.Data;
using BankFas.Core.Facilities;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Facilities;

/// <summary>A reservation asked for a request (fac.reserve_limit, BR-FAC-015): the line (or the limit) by its root, the company and the exposure amount.</summary>
public sealed record ReserveCommand(long RequestId, long LimitRoot, long? LineRoot, long CompanyId, decimal ExposureAmount, int CurrencyId, decimal? RateToFacilityCcy,
    DateTime? ExpiresOn, long ActorUserId, bool OverrideRequested = false, string? OverrideReason = null);

/// <summary>The outcome: RESERVED (with the reservation) or one of the codes of BR-FAC-015, with the availability that decided it.</summary>
public sealed record ReserveResult(string Outcome, long? ReservationId, Availability? Availability, string? ValidityIndicator)
{
    public bool Reserved => Outcome == "RESERVED";
}

/// <summary>
/// The reservation core of SVC-FAC-04 in S2 (OQ-1; S2 brief section 2.11 and S2-GAP-5): one short transaction of the
/// caller at READ COMMITTED with explicit locks. The facility row is read first with UPDLOCK and HOLDLOCK, so the
/// reservations of one facility are serialised and two facilities lock in the order of their ids (DQ-F11-1); a lock
/// held longer than five seconds ends the call with CONCURRENT_RETRY (1222 and 1205, DQ-F11-2). Availability is
/// computed by the one formula (<see cref="LimitTree"/>) on the approved revision (OQ-13), without the request's own
/// reservation. A request has one ACTIVE reservation (upsert by RequestId); the same amount again changes nothing, a
/// new amount adjusts it, a request whose reservation was released gets a new one with a derived key (M13:295).
/// Every write has its LimitMovement in the same transaction. No override in S2 (OVERRIDE_NOT_ALLOWED until S3).
/// </summary>
public static class ReservationService
{
    private sealed class FacilityLock
    {
        public long FacilityId { get; init; }
        public string LifecycleStatus { get; init; } = "";
        public int ApprovedRevisionNo { get; init; }
        public decimal TotalAmount { get; init; }
        public int CurrencyId { get; init; }
        public DateTime EffectiveFrom { get; init; }
        public DateTime ExpiryDate { get; init; }
        public bool UsageBlockOnUnconfirmed { get; init; }
    }

    private sealed class Existing
    {
        public long LimitReservationId { get; init; }
        public decimal Amount { get; init; }
        public int CurrencyId { get; init; }
    }

    public static async Task<ReserveResult> ReserveAsync(SqlConnection c, SqlTransaction tx, ReserveCommand cmd, DateTime today, CancellationToken ct)
    {
        if (cmd.ExposureAmount <= 0) throw new ArgumentOutOfRangeException(nameof(cmd), "The exposure amount is above zero.");
        if (cmd.OverrideRequested) return new ReserveResult("OVERRIDE_NOT_ALLOWED", null, null, null);
        try
        {
            await c.ExecuteAsync(new CommandDefinition("SET LOCK_TIMEOUT 5000;", transaction: tx, cancellationToken: ct)).ConfigureAwait(false);
            var facilityId = await c.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT TOP (1) FacilityId FROM fac.Limit WHERE RootId = @root;", new { root = cmd.LimitRoot }, tx, cancellationToken: ct)).ConfigureAwait(false)
                ?? throw new InvalidOperationException("The limit does not exist.");
            var f = await c.QuerySingleAsync<FacilityLock>(new CommandDefinition(
                """
                SELECT FacilityId, LifecycleStatus, ApprovedRevisionNo, TotalAmount, CurrencyId, EffectiveFrom, ExpiryDate, UsageBlockOnUnconfirmed
                  FROM fac.Facility WITH (UPDLOCK, HOLDLOCK) WHERE FacilityId = @f;
                """, new { f = facilityId }, tx, cancellationToken: ct)).ConfigureAwait(false);
            var days = await FacilityValidity.ExpiringDaysAsync(c, tx, ct).ConfigureAwait(false);
            var validity = FacilityValidity.Indicator(f.LifecycleStatus, f.EffectiveFrom, f.ExpiryDate, today, days);
            if (f.LifecycleStatus != "ACTIVE" || validity == "SCHEDULED") return new ReserveResult("LIMIT_NOT_ACTIVE", null, null, validity);
            if (validity == "NOT_CONFIRMED" && f.UsageBlockOnUnconfirmed) return new ReserveResult("VALIDITY_UNCONFIRMED", null, null, validity);
            if (cmd.CurrencyId != f.CurrencyId && cmd.RateToFacilityCcy is null) return new ReserveResult("CURRENCY_NO_RATE", null, null, validity);

            var rows = await FacilityTreeStore.LoadAsync(c, tx, f.FacilityId, f.ApprovedRevisionNo, ct).ConfigureAwait(false);
            var limit = rows.Limits.FirstOrDefault(l => l.RootId == cmd.LimitRoot);
            var line = cmd.LineRoot is { } lr ? rows.Lines.FirstOrDefault(l => l.RootId == lr && l.LimitRootId == cmd.LimitRoot) : null;
            if (limit is null || (cmd.LineRoot is not null && (line is null || !line.IsActive))) return new ReserveResult("LIMIT_NOT_ACTIVE", null, null, validity);
            if (limit.StartDate > today || limit.EndDate < today) return new ReserveResult("LIMIT_NOT_ACTIVE", null, null, validity);
            if (line is { ConsumesCreditLimit: false }) return new ReserveResult("NOT_REQUIRED", null, null, validity);
            var tree = rows.Tree(f.TotalAmount, today);
            if (!tree.Eligible(cmd.LimitRoot, cmd.CompanyId)) return new ReserveResult("COMPANY_EXCLUDED", null, null, validity);

            var exposures = await FacilityTreeStore.ExposuresAsync(c, tx, f.FacilityId, ct).ConfigureAwait(false);
            var avail = tree.Available(cmd.LimitRoot, cmd.LineRoot, cmd.CompanyId, exposures, cmd.RequestId);
            var amount = LimitTree.Round(cmd.ExposureAmount * (cmd.RateToFacilityCcy ?? 1));
            var existing = await c.QuerySingleOrDefaultAsync<Existing>(new CommandDefinition(
                "SELECT LimitReservationId, Amount, CurrencyId FROM fac.LimitReservation WITH (UPDLOCK, HOLDLOCK) WHERE RequestId = @q AND Status = 'ACTIVE';",
                new { q = cmd.RequestId }, tx, cancellationToken: ct)).ConfigureAwait(false);
            if (existing is not null && existing.Amount == cmd.ExposureAmount && existing.CurrencyId == cmd.CurrencyId)
                return new ReserveResult("RESERVED", existing.LimitReservationId, avail, validity);
            if (amount > avail.Avail) return new ReserveResult("INSUFFICIENT_AVAILABLE", existing?.LimitReservationId, avail, validity);

            var limitRow = limit.LimitId;
            var lineRow = line?.LimitProductLineId;
            if (existing is not null)
            {
                await c.ExecuteAsync(new CommandDefinition(
                    "UPDATE fac.LimitReservation SET Amount = @a, CurrencyId = @cur, RateToFacilityCcy = @rate, ExpiresOn = @exp WHERE LimitReservationId = @id;",
                    new { a = cmd.ExposureAmount, cur = cmd.CurrencyId, rate = cmd.RateToFacilityCcy, exp = cmd.ExpiresOn, id = existing.LimitReservationId }, tx,
                    cancellationToken: ct)).ConfigureAwait(false);
                await MovementAsync(c, tx, f.FacilityId, existing.LimitReservationId, "ADJUST", cmd.CurrencyId, cmd.ExposureAmount - existing.Amount, existing.Amount,
                    cmd.ExposureAmount, null, $"res:{existing.LimitReservationId}:adjust:{Guid.NewGuid():N}", cmd.ActorUserId, ct).ConfigureAwait(false);
                await Outbox.EmitAsync(c, tx, "limit.availability.changed", "fac.Facility", f.FacilityId, new { limitRoot = cmd.LimitRoot }, ct).ConfigureAwait(false);
                return new ReserveResult("RESERVED", existing.LimitReservationId, avail, validity);
            }
            // The key of a request's reservation is the request; after a release, the n-th one gets its own (M13:295).
            var earlier = await c.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM fac.LimitReservation WHERE RequestId = @q;",
                new { q = cmd.RequestId }, tx, cancellationToken: ct)).ConfigureAwait(false);
            var key = earlier == 0 ? $"req:{cmd.RequestId}" : $"req:{cmd.RequestId}:{earlier + 1}";
            var id = await c.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT fac.LimitReservation (TenantId, FacilityId, LimitId, LimitProductLineId, CompanyId, RequestId, Amount, CurrencyId, RateToFacilityCcy, ExpiresOn,
                                             IdempotencyKey, CreatedBy)
                OUTPUT inserted.LimitReservationId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @l, @ln, @co, @q, @a, @cur, @rate, @exp, @key, @actor);
                SELECT Id FROM @o;
                """, new
                {
                    f = f.FacilityId, l = limitRow, ln = lineRow, co = cmd.CompanyId, q = cmd.RequestId, a = cmd.ExposureAmount, cur = cmd.CurrencyId,
                    rate = cmd.RateToFacilityCcy, exp = cmd.ExpiresOn, key, actor = cmd.ActorUserId,
                }, tx, cancellationToken: ct)).ConfigureAwait(false);
            await MovementAsync(c, tx, f.FacilityId, id, "CREATE", cmd.CurrencyId, cmd.ExposureAmount, 0, cmd.ExposureAmount, null, key + ":create", cmd.ActorUserId, ct)
                .ConfigureAwait(false);
            await Outbox.EmitAsync(c, tx, "reservation.created", "fac.LimitReservation", id, new { reservation = id, request = cmd.RequestId }, ct).ConfigureAwait(false);
            return new ReserveResult("RESERVED", id, avail, validity);
        }
        catch (SqlException ex) when (ex.Number is 1222 or 1205)
        {
            return new ReserveResult("CONCURRENT_RETRY", null, null, null);
        }
    }

    /// <summary>fac.release_reservation: an ACTIVE reservation becomes RELEASED with its reason; a second call changes nothing.</summary>
    public static async Task<bool> ReleaseAsync(SqlConnection c, SqlTransaction tx, long reservationId, string reason, long actor, DateTime today, CancellationToken ct)
    {
        if (reason is not ("REJECTED" or "CANCELLED" or "EXPIRED" or "SUPERSEDED" or "MANUAL")) throw new ArgumentOutOfRangeException(nameof(reason));
        var r = await c.QuerySingleOrDefaultAsync<(long FacilityId, decimal Amount, int CurrencyId)?>(new CommandDefinition(
            """
            DECLARE @o TABLE (FacilityId BIGINT, Amount DECIMAL(19,4), CurrencyId INT);
            UPDATE fac.LimitReservation SET Status = 'RELEASED', ReleasedOn = @d, ReleaseReason = @reason OUTPUT inserted.FacilityId, inserted.Amount, inserted.CurrencyId INTO @o
             WHERE LimitReservationId = @id AND Status = 'ACTIVE';
            SELECT FacilityId, Amount, CurrencyId FROM @o;
            """, new { id = reservationId, d = today, reason }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (r is null) return false;
        await MovementAsync(c, tx, r.Value.FacilityId, reservationId, "RELEASE", r.Value.CurrencyId, -r.Value.Amount, r.Value.Amount, 0, reason,
            $"res:{reservationId}:release", actor, ct).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "reservation.released", "fac.LimitReservation", reservationId, new { reservation = reservationId, reason }, ct).ConfigureAwait(false);
        return true;
    }

    internal static Task MovementAsync(SqlConnection c, SqlTransaction tx, long facility, long reservationId, string op, int currency, decimal delta, decimal before,
        decimal after, string? reason, string key, long actor, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition(
            """
            INSERT fac.LimitMovement (TenantId, FacilityId, TargetKind, LimitReservationId, OpKind, CurrencyId, RequestedDelta, AppliedDelta, AmountBefore, AmountAfter, Reason,
                                      IdempotencyKey, ActorUserId)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, 'RESERVATION', @r, @op, @cur, @d, @d, @b, @a, @reason, @key, @actor);
            """, new { f = facility, r = reservationId, op, cur = currency, d = delta, b = before, a = after, reason, key, actor }, tx, cancellationToken: ct));
}

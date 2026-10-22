using System.Globalization;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Jobs;

/// <summary>
/// JOB-ACC-EXPIRY (BR-ACC-009, FR-ACC-019; S1B-GAP-3), daily after JOB-NTF-EXPIRY: a pending signatory whose document is
/// clean and whose start has come becomes ACTIVE; an active or suspended signatory past its end becomes EXPIRED (final,
/// 043); then each active account whose relationship had signatories and has no active one is told to TM and FO once a
/// day (ACC.NO_SIGNATORY). The numbers of the accounts are never in the message: their mask is.
/// </summary>
public sealed class SignatoryExpiryJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-ACC-EXPIRY";

    private sealed class Bare
    {
        public long BankAccountId { get; init; }
        public long CompanyId { get; init; }
        public string? Mask { get; init; }
        public string? Nickname { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string? InstitutionNameAr { get; init; }
        public string? InstitutionNameEn { get; init; }
    }

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var activated = 0;
        foreach (var id in (await c.QueryAsync<long>(new CommandDefinition(
                     "SELECT SignatoryId FROM acc.Signatory WHERE Status = 'PENDING' AND AuthorizationDocumentId IS NOT NULL AND ValidFrom <= @d;", new { d = today },
                     cancellationToken: ct)).ConfigureAwait(false)).ToList())
        {
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            var done = await c.ExecuteScalarAsync<Guid?>(new CommandDefinition(
                """
                DECLARE @o TABLE (PublicId UNIQUEIDENTIFIER);
                UPDATE s SET Status = 'ACTIVE', UpdatedAt = SYSUTCDATETIME()
                OUTPUT inserted.PublicId INTO @o
                  FROM acc.Signatory AS s JOIN doc.Document AS d ON d.DocumentId = s.AuthorizationDocumentId AND d.Status = 'ACTIVE'
                  JOIN doc.DocumentVersion AS v ON v.DocumentVersionId = d.CurrentVersionId AND v.ScanStatus = 'CLEAN'
                 WHERE s.SignatoryId = @s AND s.Status = 'PENDING' AND (s.ValidTo IS NULL OR s.ValidTo >= @d);
                SELECT PublicId FROM @o;
                """, new { s = id, d = today }, tx, cancellationToken: ct)).ConfigureAwait(false);
            if (done is not null)
            {
                await Outbox.EmitAsync(c, tx, "signatory.activated", "acc.Signatory", id, new { signatory = done }, ct).ConfigureAwait(false);
                activated++;
            }
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        var expired = await c.ExecuteAsync(new CommandDefinition(
            "UPDATE acc.Signatory SET Status = 'EXPIRED', UpdatedAt = SYSUTCDATETIME() WHERE Status IN ('ACTIVE', 'SUSPENDED') AND ValidTo < @d;",
            new { d = today }, cancellationToken: ct)).ConfigureAwait(false);
        var bare = (await c.QueryAsync<Bare>(new CommandDefinition(
            """
            SELECT ba.BankAccountId, ba.CompanyId, ba.AccountNoMask AS Mask, ba.Nickname, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn,
                   i.NameAr AS InstitutionNameAr, i.NameEn AS InstitutionNameEn
              FROM acc.BankAccount AS ba JOIN org.Company AS co ON co.CompanyId = ba.CompanyId AND co.Status = 'ACTIVE'
              JOIN ins.Institution AS i ON i.InstitutionId = ba.InstitutionId
             WHERE ba.Status = 'ACTIVE'
               AND EXISTS (SELECT 1 FROM acc.Signatory AS s WHERE s.RelationshipId = ba.RelationshipId)
               AND NOT EXISTS (SELECT 1 FROM acc.Signatory AS s WHERE s.RelationshipId = ba.RelationshipId AND s.Status = 'ACTIVE');
            """, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        foreach (var a in bare)
        {
            var label = a.Nickname is { Length: > 0 } n ? $"{n} ({a.Mask})" : a.Mask;
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            await Notifier.RequestAsync(c, tx, new NotificationRequest("ACC.NO_SIGNATORY", "acc.BankAccount", a.BankAccountId,
                $"ACC.NO_SIGNATORY:{a.BankAccountId}:{today:yyyyMMdd}", a.CompanyId, new Dictionary<string, object?>
                {
                    ["companyName"] = ExpiryItemProviders.Text(a.CompanyNameAr, a.CompanyNameEn),
                    ["institutionName"] = ExpiryItemProviders.Text(a.InstitutionNameAr, a.InstitutionNameEn),
                    ["accountLabel"] = new Dictionary<string, string?> { ["ar"] = "الحساب " + label, ["en"] = "The account " + label },
                }), ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        return activated + expired + bare.Count == 0 ? null
            : string.Create(CultureInfo.InvariantCulture, $"activated {activated}, expired {expired}, accounts without a signatory {bare.Count}");
    }
}

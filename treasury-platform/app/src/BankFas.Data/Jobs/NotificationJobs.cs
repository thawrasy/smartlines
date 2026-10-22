using System.Globalization;
using BankFas.Core.Mail;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Jobs;

/// <summary>
/// JOB-NTF-DISPATCH (spec 13 section 9.3, BR-NTF-009): the e-mail deliveries that are due, in the recipient's language
/// from the event's EMAIL template. A failure waits 1 minute, then 5, 30, 2 hours and 12 hours; after the fifth the
/// delivery is DEAD and the account administrators hear once (NTF.DELIVERY_DEAD). The in-app notification is never
/// touched by an e-mail failure.
/// </summary>
public sealed class NotificationDispatchJob(SqlConnectionFactory db, IMailSender mail) : TenantJob(db)
{
    public override string JobKey => "JOB-NTF-DISPATCH";

    private sealed record Due(long NotificationDeliveryId, long NotificationId, int Attempts, string Email, string? PreferredLanguage, long UserId, string? UserName,
        string EventName);

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var due = (await c.QueryAsync<Due>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            UPDATE TOP (50) d SET Attempts = Attempts + 1, NextAttemptAt = DATEADD(MINUTE, 10, SYSUTCDATETIME()), Status = 'FAILED', UpdatedAt = SYSUTCDATETIME()
            OUTPUT inserted.NotificationDeliveryId INTO @o
              FROM ntf.NotificationDelivery AS d WITH (UPDLOCK, READPAST, ROWLOCK)
             WHERE d.Channel = 'EMAIL' AND d.Status IN ('PENDING', 'FAILED') AND d.NextAttemptAt <= SYSUTCDATETIME();
            SELECT d.NotificationDeliveryId, d.NotificationId, d.Attempts, u.Email,
                   ISNULL(u.PreferredLanguage, (SELECT DefaultLanguage FROM plat.v_CurrentTenant)) AS PreferredLanguage, u.AppUserId AS UserId,
                   ISNULL(u.DisplayNameAr, u.Email) AS UserName, ISNULL(e.NameEn, e.Code) AS EventName
              FROM @o AS o JOIN ntf.NotificationDelivery AS d ON d.NotificationDeliveryId = o.Id
              JOIN ntf.Notification AS n ON n.NotificationId = d.NotificationId JOIN sec.AppUser AS u ON u.AppUserId = n.UserId
              JOIN ntf.NotificationEventType AS e ON e.NotificationEventTypeId = n.EventTypeId;
            """, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        if (due.Count == 0) return null;
        int sent = 0, failed = 0, dead = 0;
        foreach (var d in due)
        {
            try
            {
                var (subject, body) = await Notifier.EmailAsync(c, d.NotificationId, d.PreferredLanguage == "en" ? "en" : "ar", ct).ConfigureAwait(false);
                await mail.SendAsync(new OutgoingMail(d.Email, subject, body), ct).ConfigureAwait(false);
                await c.ExecuteAsync(new CommandDefinition(
                    "UPDATE ntf.NotificationDelivery SET Status = 'SENT', SentAt = SYSUTCDATETIME(), NextAttemptAt = NULL, LastError = NULL WHERE NotificationDeliveryId = @id;",
                    new { id = d.NotificationDeliveryId }, cancellationToken: ct)).ConfigureAwait(false);
                sent++;
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException or System.Net.Mail.SmtpException)
            {
                var isDead = d.Attempts >= 5;
                // LastError without personal data: the kind of failure only.
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    UPDATE ntf.NotificationDelivery SET Status = CASE WHEN @dead = 1 THEN 'DEAD' ELSE 'FAILED' END, LastError = @err,
                           NextAttemptAt = CASE WHEN @dead = 1 THEN NULL ELSE DATEADD(MINUTE, @wait, SYSUTCDATETIME()) END
                     WHERE NotificationDeliveryId = @id;
                    """, new { dead = isDead, err = ex.GetType().Name, wait = Wait(d.Attempts), id = d.NotificationDeliveryId }, cancellationToken: ct)).ConfigureAwait(false);
                if (isDead)
                {
                    dead++;
                    await Notifier.RequestAsync(c, null, new NotificationRequest("NTF.DELIVERY_DEAD", "ntf.NotificationDelivery", d.NotificationDeliveryId,
                        $"NTF.DELIVERY_DEAD:{d.NotificationDeliveryId}", Values: new Dictionary<string, object?>
                        {
                            ["channel"] = new Dictionary<string, string> { ["ar"] = "البريد الإلكتروني", ["en"] = "e-mail" }, ["eventName"] = d.EventName, ["userName"] = d.UserName,
                        }), ct).ConfigureAwait(false);
                }
                else failed++;
            }
        }
        return $"sent {sent}, failed {failed}, dead {dead}";
    }

    /// <summary>BR-NTF-009: 1 minute after the first failure, 5 after the second, 30, 2 hours, 12 hours.</summary>
    private static int Wait(int attempts) => attempts switch { 1 => 1, 2 => 5, 3 => 30, 4 => 120, _ => 720 };
}

/// <summary>
/// JOB-NTF-EXPIRY (FR-PLT-038, BR-PLT-013, BR-NTF-002): daily, for each active expiry rule, every item with an expiry
/// date: when a lead threshold is crossed the nearest one is sent once (several crossed at the first look give one
/// alert, and the farther ones are recorded so they never come later); on and after the expiry date one EXPIRED alert,
/// then a reminder every ReminderAfterExpiryDays. Each alert is a row of cfg.ExpiryAlertLog keyed by the item's
/// expiry date, so a renewal (a new date) starts again. The recipients are the rule's roles and the event's rules,
/// within the company of the item. S1 has the company documents and the identity documents (OQ-3); the numbers of
/// identity documents are never in the message.
/// </summary>
public sealed class ExpiryAlertJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-NTF-EXPIRY";

    private sealed record Rule(long ExpiryAlertRuleId, string ItemType, string LeadDays, bool ScopeByCompany, int? ReminderAfterExpiryDays);

    private sealed class Item
    {
        public long Id { get; init; }
        public DateTime ExpiryDate { get; init; }
        public long? CompanyId { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string? TypeAr { get; init; }
        public string? TypeEn { get; init; }
        public string? Title { get; init; }
        public string? Kind { get; init; }
    }

    private static readonly Dictionary<string, (string Ar, string En)> DocKinds = new(StringComparer.Ordinal)
    {
        ["NATIONAL_ID"] = ("الهوية الوطنية", "national ID"), ["RESIDENCE"] = ("الإقامة", "residence permit"), ["PASSPORT"] = ("جواز السفر", "passport"),
        ["GCC_ID"] = ("هوية مجلس التعاون", "GCC ID"), ["COMMERCIAL_REG"] = ("السجل التجاري", "commercial registration"), ["OTHER_ORG"] = ("وثيقة الجهة", "organisation document"),
    };

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var rules = (await c.QueryAsync<Rule>(new CommandDefinition(
            "SELECT ExpiryAlertRuleId, ItemType, LeadDays, ScopeByCompany, ReminderAfterExpiryDays FROM cfg.ExpiryAlertRule WHERE IsActive = 1 AND ItemType IN ('COMPANY_DOCUMENT', 'IDENTITY_DOCUMENT');",
            cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var sent = 0;
        foreach (var rule in rules)
        {
            var lead = System.Text.Json.JsonSerializer.Deserialize<int[]>(rule.LeadDays) ?? [];
            var roles = (await c.QueryAsync<long>(new CommandDefinition("SELECT RoleId FROM cfg.ExpiryAlertRuleRole WHERE ExpiryAlertRuleId = @r;",
                new { r = rule.ExpiryAlertRuleId }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
            var horizon = today.AddDays(lead.DefaultIfEmpty(0).Max());
            var items = (await c.QueryAsync<Item>(new CommandDefinition(rule.ItemType == "COMPANY_DOCUMENT"
                ? """
                  SELECT d.DocumentId AS Id, d.ExpiryDate, d.OwnerCompanyId AS CompanyId, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn, t.NameAr AS TypeAr,
                         t.NameEn AS TypeEn, d.Title
                    FROM doc.Document AS d JOIN cat.DocumentType AS t ON t.DocumentTypeId = d.DocumentTypeId JOIN org.Company AS co ON co.CompanyId = d.OwnerCompanyId
                   WHERE d.Status = 'ACTIVE' AND d.SupersededByDocumentId IS NULL AND d.ExpiryDate IS NOT NULL AND d.ExpiryDate <= @horizon AND co.Status <> 'ARCHIVED';
                  """
                : """
                  SELECT i.IdentityDocumentId AS Id, i.ExpiryDate, co.CompanyId, p.NameAr AS CompanyNameAr, p.NameEn AS CompanyNameEn, i.DocKind AS Kind
                    FROM pty.IdentityDocument AS i JOIN pty.Party AS p ON p.PartyId = i.PartyId LEFT JOIN org.Company AS co ON co.PartyId = p.PartyId
                   WHERE i.IsSuperseded = 0 AND i.ExpiryDate IS NOT NULL AND i.ExpiryDate <= @horizon AND p.IsActive = 1;
                  """, new { horizon }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
            foreach (var item in items)
            {
                var days = (item.ExpiryDate.Date - today).Days;
                var logged = (await c.QueryAsync<(string Kind, int Threshold)>(new CommandDefinition(
                    "SELECT AlertKind, Threshold FROM cfg.ExpiryAlertLog WHERE ExpiryAlertRuleId = @r AND ItemId = @i AND ExpiryDate = @e;",
                    new { r = rule.ExpiryAlertRuleId, i = item.Id, e = item.ExpiryDate }, cancellationToken: ct)).ConfigureAwait(false)).ToHashSet();
                string kind;
                int threshold;
                int[] alsoRecord = [];
                if (days > 0)
                {
                    var crossed = lead.Where(l => days <= l).ToArray();
                    if (crossed.Length == 0) continue;
                    threshold = crossed.Min();
                    kind = "LEAD";
                    alsoRecord = [.. crossed.Where(l => l != threshold && !logged.Contains(("LEAD", l)))];
                }
                else if (!logged.Contains(("EXPIRED", 0)))
                {
                    kind = "EXPIRED";
                    threshold = 0;
                }
                else if (rule.ReminderAfterExpiryDays is { } every && -days / every >= 1)
                {
                    kind = "REMINDER";
                    threshold = -days / every;
                }
                else continue;
                if (logged.Contains((kind, threshold))) continue;

                await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
                foreach (var (k, th) in alsoRecord.Select(l => ("LEAD", l)).Append((kind, threshold)))
                    await c.ExecuteAsync(new CommandDefinition(
                        """
                        INSERT cfg.ExpiryAlertLog (TenantId, ExpiryAlertRuleId, ItemId, ExpiryDate, AlertKind, Threshold)
                        VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @e, @k, @t);
                        """, new { r = rule.ExpiryAlertRuleId, i = item.Id, e = item.ExpiryDate, k, t = th }, tx, cancellationToken: ct)).ConfigureAwait(false);
                await Notifier.RequestAsync(c, tx, Request(rule, item, kind, threshold, days, roles), ct).ConfigureAwait(false);
                await tx.CommitAsync(ct).ConfigureAwait(false);
                sent++;
            }
        }
        return sent == 0 ? null : $"alerts {sent}";
    }

    private static NotificationRequest Request(Rule rule, Item item, string kind, int threshold, int days, IReadOnlyList<long> roles)
    {
        var stage = kind switch
        {
            "LEAD" => new Dictionary<string, string> { ["ar"] = $"بقي {threshold} يومًا أو أقل", ["en"] = $"{threshold} days or fewer left" },
            "EXPIRED" => new Dictionary<string, string> { ["ar"] = "انتهى", ["en"] = "expired" },
            _ => new Dictionary<string, string> { ["ar"] = $"منتهٍ، التذكير {threshold}", ["en"] = $"expired, reminder {threshold}" },
        };
        var expiry = item.ExpiryDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var company = new Dictionary<string, string?> { ["ar"] = item.CompanyNameAr ?? item.CompanyNameEn, ["en"] = item.CompanyNameEn ?? item.CompanyNameAr };
        var isDoc = rule.ItemType == "COMPANY_DOCUMENT";
        var code = isDoc ? "DOC.EXPIRY" : "IDDOC.EXPIRY";
        var target = isDoc ? "doc.Document" : "pty.IdentityDocument";
        var values = new Dictionary<string, object?> { ["expiryDate"] = expiry, ["daysLeft"] = Math.Max(days, 0), ["stageLabel"] = stage };
        if (isDoc)
        {
            values["companyName"] = company;
            values["documentType"] = new Dictionary<string, string?> { ["ar"] = item.TypeAr ?? item.TypeEn, ["en"] = item.TypeEn ?? item.TypeAr };
            values["documentTitle"] = item.Title;
        }
        else
        {
            var label = DocKinds.TryGetValue(item.Kind ?? "", out var known) ? known : (Ar: item.Kind ?? "", En: item.Kind ?? "");
            values["partyName"] = company;
            values["docKindLabel"] = new Dictionary<string, string> { ["ar"] = label.Ar, ["en"] = label.En };
        }
        return new NotificationRequest(code, target, item.Id, $"{code}:{target}:{item.Id}:{kind}{threshold}:{item.ExpiryDate:yyyyMMdd}",
            rule.ScopeByCompany ? item.CompanyId : null, values, RecipientRoleIds: roles);
    }
}

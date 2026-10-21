using BankFas.Core.Mail;
using BankFas.Core.Security;
using BankFas.Data;
using BankFas.Data.Jobs;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// The e-mails with account links (FR-PLT-013). The token travels in the URL fragment, which the browser never sends
/// to a server, so it does not reach proxy logs (DOC-S03 section 3). After an administrator's link, the result goes
/// into sec.UserToken.SendStatus on the bound connection, and a failure is audited HIGH (AC-PLT-11).
/// </summary>
public sealed class AccountMail(IMailSender sender, IOptions<PortalOptions> portal, IOptions<HostOptions> hosts)
{
    public static string PathFor(string purpose) => purpose switch
    {
        "INVITATION" => "/invitation#token=",
        "PASSWORD_RESET" => "/reset-password#token=",
        "MFA_REENROLMENT" => "/mfa/enrol#reenrol=",
        _ => throw new ArgumentOutOfRangeException(nameof(purpose)),
    };

    private static (string Subject, string Text) Message(string purpose, Uri link) => purpose switch
    {
        "INVITATION" => ("Your BankFas account", $"You have been invited to your company's BankFas account.\r\nSet your password within 48 hours: {link}\r\n"),
        "PASSWORD_RESET" => ("Reset your BankFas password", $"Someone asked to reset your BankFas password. If it was you, open this link within 30 minutes: {link}\r\nIf it was not you, ignore this message; your password stays as it is.\r\n"),
        _ => ("Set up your authenticator again", $"Your administrator reset your two-step verification. Sign in, then open this link within 24 hours to set it up again: {link}\r\n"),
    };

    /// <summary>Sends the link; returns null when it went, else the reason.</summary>
    public async Task<string?> SendAsync(string tenantCode, string to, string purpose, byte[] token, CancellationToken ct)
    {
        var link = portal.Value.TenantUri(tenantCode, PathFor(purpose) + Base64Url.Encode(token));
        var (subject, text) = Message(purpose, link);
        try
        {
            await sender.SendAsync(new OutgoingMail(to, subject, text), ct);
            return null;
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or System.Net.Mail.SmtpException)
        {
            return ex.Message.Length > 500 ? ex.Message[..500] : ex.Message;
        }
    }

    /// <summary>An operator's set-up link (invitation or reset), on the panel's host; returns null when it went, else the reason.</summary>
    public async Task<string?> SendOperatorSetupAsync(string to, byte[] token, bool reset, CancellationToken ct)
    {
        var builder = new UriBuilder(portal.Value.Scheme, hosts.Value.Operator, portal.Value.Port ?? -1) { Path = "/setup", Fragment = "token=" + Base64Url.Encode(token) };
        var text = reset
            ? $"An administrator reset your BankFas operator account. Set your password and authenticator again within 24 hours: {builder.Uri}\r\n"
            : $"You have been invited to the BankFas operator panel. Set your password and authenticator within 48 hours: {builder.Uri}\r\n";
        try
        {
            await sender.SendAsync(new OutgoingMail(to, "Your BankFas operator account", text), ct);
            return null;
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or System.Net.Mail.SmtpException)
        {
            return ex.Message;
        }
    }

    /// <summary>Sends an administrator's link and records the result on the bound connection.</summary>
    public async Task<bool> SendAndRecordAsync(SqlConnection bound, string tenantCode, long userId, string to, string purpose, byte[] token, CancellationToken ct)
    {
        var error = await SendAsync(tenantCode, to, purpose, token, ct);
        await bound.ExecuteAsync(new CommandDefinition(
            "UPDATE sec.UserToken SET SendStatus = @s, SendError = @e WHERE UserId = @u AND Purpose = @p AND TokenHash = @h;",
            new { s = error is null ? "SENT" : "FAILED", e = error, u = userId, p = purpose, h = SecureTokens.Sha256(token) }, cancellationToken: ct));
        if (error is not null)
            await TenantAdminProcedures.WriteAuditAsync(bound, null, new AuditEntry(purpose + "_SEND_FAILED", "SECURITY", "sec.AppUser", userId,
                Severity: "HIGH", Result: "FAILED"), ct);
        return error is null;
    }
}

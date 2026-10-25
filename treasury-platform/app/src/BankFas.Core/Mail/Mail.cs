using System.Globalization;
using System.Text;

namespace BankFas.Core.Mail;

public sealed record OutgoingMail(string To, string Subject, string TextBody);

/// <summary>Sends the account e-mails: invitations, reset and re-enrolment links (FR-PLT-013). Production uses the SMTP relay.</summary>
public interface IMailSender
{
    Task SendAsync(OutgoingMail mail, CancellationToken cancellationToken);
}

/// <summary>
/// Development and tests: each message is written as a file in a directory instead of being sent, the way an SMTP
/// pickup directory works. The files hold live links, so the directory belongs to the developer alone.
/// </summary>
public sealed class FileDropMailSender(string directory) : IMailSender
{
    public async Task SendAsync(OutgoingMail mail, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(mail);
        Directory.CreateDirectory(directory);
        var name = string.Create(CultureInfo.InvariantCulture, $"{DateTime.UtcNow:yyyyMMddTHHmmssfff}-{Guid.NewGuid():N}.eml");
        var text = $"To: {mail.To}\r\nSubject: {mail.Subject}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n{mail.TextBody}\r\n";
        await File.WriteAllTextAsync(Path.Combine(directory, name), text, Encoding.UTF8, cancellationToken).ConfigureAwait(false);
    }
}

/// <summary>Configuration section "Mail:Smtp": the relay of the hosting provider (FR-PLT-013); the password from a file.</summary>
public sealed class SmtpOptions
{
    public string Host { get; set; } = "";
    public int Port { get; set; } = 587;
    public string From { get; set; } = "no-reply@bankfas.com";
    public string? Username { get; set; }
    public string? PasswordFile { get; set; }
}

/// <summary>Sends through an SMTP relay with STARTTLS required; no message is sent in clear text. Each message has the text and its HTML form.</summary>
public sealed class SmtpMailSender(SmtpOptions options) : IMailSender
{
    public async Task SendAsync(OutgoingMail mail, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(mail);
        using var client = new System.Net.Mail.SmtpClient(options.Host, options.Port) { EnableSsl = true, DeliveryMethod = System.Net.Mail.SmtpDeliveryMethod.Network };
        if (!string.IsNullOrEmpty(options.Username))
            client.Credentials = new System.Net.NetworkCredential(options.Username,
                options.PasswordFile is null ? "" : (await File.ReadAllTextAsync(options.PasswordFile, cancellationToken).ConfigureAwait(false)).Trim());
        using var message = new System.Net.Mail.MailMessage(options.From, mail.To, mail.Subject, mail.TextBody)
        {
            BodyEncoding = Encoding.UTF8, SubjectEncoding = Encoding.UTF8,
        };
        // The branded HTML part beside the text (ADR 0055); a client that shows only text keeps the text part.
        using var html = System.Net.Mail.AlternateView.CreateAlternateViewFromString(MailHtml.Render(mail.Subject, mail.TextBody), Encoding.UTF8, "text/html");
        message.AlternateViews.Add(html);
        await client.SendMailAsync(message, cancellationToken).ConfigureAwait(false);
    }
}

public static class MailSenders
{
    /// <summary>SMTP when "Mail:Smtp:Host" is set; otherwise the drop directory "Mail:DropDirectory" (development and tests).</summary>
    public static IMailSender Create(Func<string, string?> setting, Func<SmtpOptions> smtp)
    {
        ArgumentNullException.ThrowIfNull(setting);
        ArgumentNullException.ThrowIfNull(smtp);
        if (!string.IsNullOrEmpty(setting("Mail:Smtp:Host"))) return new SmtpMailSender(smtp());
        var drop = setting("Mail:DropDirectory");
        return string.IsNullOrEmpty(drop)
            ? throw new InvalidOperationException("Set Mail:Smtp:Host, or Mail:DropDirectory for development (docs/42).")
            : new FileDropMailSender(drop);
    }
}

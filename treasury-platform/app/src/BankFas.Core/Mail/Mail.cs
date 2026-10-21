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

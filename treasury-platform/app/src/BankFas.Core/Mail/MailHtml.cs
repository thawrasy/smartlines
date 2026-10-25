using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace BankFas.Core.Mail;

/// <summary>
/// The HTML part of an e-mail in the identity guide (ADR 0055): a vault-green band with the name (BANK in ivory, FAS in
/// mint, text and not an image, so a client that blocks images still shows it), the text on white in the platform's
/// ink, and the link of the message as a button. It is built from the text part alone, which stays in the message as
/// its plain alternative: every character is HTML-encoded, only http and https links become links, and the direction
/// follows the first strong letter, so an Arabic message reads right to left.
/// </summary>
public static partial class MailHtml
{
    [GeneratedRegex(@"https?://[^\s<>""]*[^\s<>"".,;:!?)]", RegexOptions.CultureInvariant)]
    private static partial Regex Url();

    [GeneratedRegex(@"[A-Za-z؀-ۿ]", RegexOptions.CultureInvariant)]
    private static partial Regex Strong();

    private const string Font = "'IBM Plex Sans','IBM Plex Sans Arabic',Tahoma,Arial,sans-serif";

    public static string Render(string subject, string text)
    {
        ArgumentNullException.ThrowIfNull(subject);
        ArgumentNullException.ThrowIfNull(text);
        var first = Strong().Match(text.Length > 0 ? text : subject);
        var rtl = first.Success && first.Value[0] >= '؀';
        var dir = rtl ? "rtl" : "ltr";
        var align = rtl ? "right" : "left";
        var b = new StringBuilder();
        b.Append("<!doctype html><html lang=\"").Append(rtl ? "ar" : "en").Append("\" dir=\"").Append(dir).Append("\"><head><meta charset=\"utf-8\">")
         .Append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>").Append(WebUtility.HtmlEncode(subject)).Append("</title></head>")
         .Append("<body style=\"margin:0;padding:0;background:#F4F7F5;\">")
         .Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:#F4F7F5;\"><tr><td align=\"center\" style=\"padding:24px 12px;\">")
         .Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:600px;background:#FFFFFF;border:1px solid #DCE5E1;border-radius:12px;\">")
         .Append("<tr><td dir=\"ltr\" style=\"background:#062A22;padding:20px 28px;border-radius:12px 12px 0 0;font-family:Arial,sans-serif;font-size:22px;font-weight:700;letter-spacing:1px;\">")
         .Append("<span style=\"color:#F4F7F5;\">BANK</span><span style=\"color:#37DDB1;\">FAS</span></td></tr>")
         .Append("<tr><td dir=\"").Append(dir).Append("\" style=\"padding:28px;text-align:").Append(align).Append(";font-family:").Append(Font)
         .Append(";font-size:15px;line-height:24px;color:#11211D;\">")
         .Append("<h1 style=\"margin:0 0 16px;font-size:20px;line-height:28px;color:#062A22;\">").Append(WebUtility.HtmlEncode(subject)).Append("</h1>");
        string? button = null;
        foreach (var para in text.Replace("\r\n", "\n", StringComparison.Ordinal).Split("\n\n", StringSplitOptions.RemoveEmptyEntries))
        {
            b.Append("<p style=\"margin:0 0 14px;\">");
            var lines = para.Split('\n');
            for (var i = 0; i < lines.Length; i++)
            {
                if (i > 0) b.Append("<br>");
                var line = lines[i];
                var at = 0;
                foreach (Match m in Url().Matches(line))
                {
                    b.Append(WebUtility.HtmlEncode(line[at..m.Index]));
                    var href = WebUtility.HtmlEncode(m.Value);
                    b.Append("<a dir=\"ltr\" href=\"").Append(href).Append("\" style=\"color:#007A5C;word-break:break-all;\">").Append(href).Append("</a>");
                    button ??= m.Value;
                    at = m.Index + m.Length;
                }
                b.Append(WebUtility.HtmlEncode(line[at..]));
            }
            b.Append("</p>");
        }
        if (button is not null)
            b.Append("<p style=\"margin:20px 0 4px;\"><a href=\"").Append(WebUtility.HtmlEncode(button))
             .Append("\" style=\"display:inline-block;background:#007A5C;color:#FFFFFF;text-decoration:none;font-weight:600;padding:10px 20px;border-radius:8px;\">")
             .Append(rtl ? "فتح الرابط" : "Open the link").Append("</a></p>");
        b.Append("</td></tr><tr><td dir=\"").Append(dir).Append("\" style=\"padding:16px 28px;border-top:2px solid #00A97F;text-align:").Append(align)
         .Append(";font-family:").Append(Font).Append(";font-size:12px;line-height:18px;color:#4E6660;\">")
         .Append(rtl ? "BankFas · منصة التسهيلات البنكية وتقييم القوائم المالية" : "BankFas · Bank facilities and financial statement assessment")
         .Append("</td></tr></table></td></tr></table></body></html>");
        return b.ToString();
    }
}

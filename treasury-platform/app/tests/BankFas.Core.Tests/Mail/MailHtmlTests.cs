using BankFas.Core.Mail;

namespace BankFas.Core.Tests.Mail;

// The HTML part of the e-mails (ADR 0055): built from the text alone, every character encoded.
public sealed class MailHtmlTests
{
    [Fact]
    public void An_arabic_message_reads_right_to_left_with_its_link_as_a_button()
    {
        var html = MailHtml.Render("دعوة إلى BankFas", "مرحبًا،\n\nافتح الرابط: https://demo.bankfas.com/invite#t=abc.\n");
        Assert.Contains("dir=\"rtl\"", html, StringComparison.Ordinal);
        Assert.Contains("href=\"https://demo.bankfas.com/invite#t=abc\"", html, StringComparison.Ordinal);
        Assert.Contains("فتح الرابط</a>", html, StringComparison.Ordinal);
    }

    [Fact]
    public void Markup_in_the_text_is_encoded_and_other_schemes_are_not_links()
    {
        var html = MailHtml.Render("Hello <b>", "Click <script>x</script> javascript:alert(1) and https://a.example/p?x=1&y=2");
        Assert.DoesNotContain("<script>", html, StringComparison.Ordinal);
        Assert.DoesNotContain("<b>", html, StringComparison.Ordinal);
        Assert.DoesNotContain("href=\"javascript", html, StringComparison.Ordinal);
        Assert.Contains("href=\"https://a.example/p?x=1&amp;y=2\"", html, StringComparison.Ordinal);
        Assert.Contains("dir=\"ltr\" style=\"padding:28px", html, StringComparison.Ordinal);
    }

    [Fact]
    public void A_message_without_a_link_has_no_button() =>
        Assert.DoesNotContain("Open the link", MailHtml.Render("Status", "Your account is active."), StringComparison.Ordinal);
}

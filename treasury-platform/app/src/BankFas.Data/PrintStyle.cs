namespace BankFas.Data;

/// <summary>
/// The identity guide on the printed pages (ADR 0055): the terms, the proforma, a request and a report. The fonts are
/// IBM Plex Sans Arabic, Sans and Mono: the API image installs them for Chromium's PDF (local()), and the browser
/// fetches them from the site's /fonts (font-src 'self'). Text in the platform's ink, headings in vault green over an
/// emerald rule, lines and table heads in the platform's greys, figures in mono. Each page adds its own sizes after it.
/// </summary>
public static class PrintStyle
{
    private const string Face = "@font-face{font-family:\"";

    public const string Fonts =
        Face + "IBM Plex Sans Arabic\";font-weight:400;src:local(\"IBM Plex Sans Arabic Regular\"),url(/fonts/plex-sans-arabic-400.woff2) format(\"woff2\")}" +
        Face + "IBM Plex Sans Arabic\";font-weight:600;src:local(\"IBM Plex Sans Arabic SemiBold\"),url(/fonts/plex-sans-arabic-600.woff2) format(\"woff2\")}" +
        Face + "IBM Plex Sans Arabic\";font-weight:700;src:local(\"IBM Plex Sans Arabic Bold\"),url(/fonts/plex-sans-arabic-700.woff2) format(\"woff2\")}" +
        Face + "IBM Plex Sans\";font-weight:400;src:local(\"IBM Plex Sans Regular\"),url(/fonts/plex-sans-400.woff2) format(\"woff2\")}" +
        Face + "IBM Plex Sans\";font-weight:600;src:local(\"IBM Plex Sans SemiBold\"),url(/fonts/plex-sans-600.woff2) format(\"woff2\")}" +
        Face + "IBM Plex Sans\";font-weight:700;src:local(\"IBM Plex Sans Bold\"),url(/fonts/plex-sans-700.woff2) format(\"woff2\")}" +
        Face + "IBM Plex Mono\";font-weight:400;src:local(\"IBM Plex Mono Regular\"),url(/fonts/plex-mono-400.woff2) format(\"woff2\")}";

    public const string Base = Fonts +
        "body{font-family:\"IBM Plex Sans\",\"IBM Plex Sans Arabic\",'Noto Naskh Arabic',system-ui,sans-serif;color:#11211D;line-height:1.5}" +
        "h1{color:#062A22;font-weight:700}h2{color:#062A22;font-weight:600;border-bottom:1px solid #00A97F;padding-bottom:2px}" +
        "table{border-collapse:collapse;width:100%}td,th{border:1px solid #DCE5E1;text-align:start;vertical-align:top}" +
        "th{background:#F3F5F5;color:#4E6660;font-weight:600}.num,td.n,code{font-family:\"IBM Plex Mono\",monospace}" +
        ".muted{color:#4E6660}.banner{color:#C2362B;font-weight:600}.foot{color:#4E6660;border-top:2px solid #00A97F;padding-top:6px}";

    /// <summary>The fonts of the printed pages, for their Content-Security-Policy.</summary>
    public const string FontSource = "font-src 'self'";
}

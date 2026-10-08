"""HTML of the landing pages: one light, server-rendered layout in the brand colours, right-to-left for Arabic.

No JavaScript is needed to read or navigate a page; the search form is a plain GET form that opens the booking app.
Every page carries its canonical address, the Arabic and English alternates (hreflang), Open Graph and Twitter cards,
and JSON-LD structured data.
"""
from __future__ import annotations

import json
import re
from datetime import date, datetime, timedelta
from html import escape
from typing import Iterable, Optional
from zoneinfo import ZoneInfo

from ...config import get_settings
from ..notify.render import messages

# the default market's time zone (1061), set when the catalog is read; trips carry their own departure zone
_DEFAULT_ZONE = ZoneInfo("UTC")


def set_default_zone(tz: str) -> None:
    global _DEFAULT_ZONE
    _DEFAULT_ZONE = ZoneInfo(tz)
LANGS = ("ar", "en")
LOGO = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="36" height="36" aria-hidden="true"><rect width="64" height="64" rx="16" '
        'fill="#0B1F3F"/><path d="M15.5 43.5 C20.5 32.5 24.5 22 32.5 22 C39.5 22 41.5 32.5 48.5 34.5" fill="none" stroke="#2F7BFF" '
        'stroke-width="6.5" stroke-linecap="round"/><circle cx="15.5" cy="43.5" r="5.5" fill="#7FB0FF"/><circle cx="48.5" cy="34.5" r="5.5" '
        'fill="#12A06A"/></svg>')

CSS = """
:root{--navy:#0B1F3F;--blue:#0A5BD3;--sky:#2F7BFF;--green:#12A06A;--ink:#1B2330;--muted:#4B5565;--line:#D5DBE3;--soft:#F5F7FA;--tint:#E8F0FE}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;font-family:"IBM Plex Sans Arabic","Segoe UI",Tahoma,Arial,sans-serif;color:var(--ink);background:#fff;line-height:1.7;font-size:16px}
h1,h2,h3{font-family:"Readex Pro","IBM Plex Sans Arabic","Segoe UI",sans-serif;color:var(--navy);line-height:1.35;margin:0 0 .5em}
h1{font-size:clamp(1.7rem,4vw,2.5rem)}h2{font-size:clamp(1.25rem,2.6vw,1.6rem);margin-top:1.6em}h3{font-size:1.1rem}
a{color:var(--blue)}p{margin:0 0 1em}
.wrap{max-width:1120px;margin:0 auto;padding:0 20px}
header.top{border-bottom:1px solid var(--line);background:#fff}
header.top .wrap{display:flex;align-items:center;gap:20px;min-height:64px;flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:1.25rem;color:var(--navy);text-decoration:none}
nav.main{display:flex;gap:18px;flex-wrap:wrap;margin-inline-start:auto;font-size:.95rem}
nav.main a{color:var(--ink);text-decoration:none}nav.main a:hover{color:var(--blue)}
.btn{display:inline-block;background:var(--blue);color:#fff;text-decoration:none;padding:12px 22px;border-radius:12px;font-weight:600;border:0;font:inherit;cursor:pointer}
.btn.ghost{background:var(--tint);color:var(--blue)}
.hero{background:var(--navy);color:#fff;padding:48px 0 40px}
.hero h1{color:#fff}.hero p.lead{color:#C9D6EA;font-size:1.1rem;max-width:760px}
form.search{background:#fff;border-radius:16px;padding:16px;display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin-top:20px;color:var(--ink)}
form.search label{display:flex;flex-direction:column;font-size:.85rem;color:var(--muted);gap:4px}
form.search select,form.search input{font:inherit;padding:10px 12px;border:1px solid var(--line);border-radius:10px;background:#fff;color:var(--ink)}
form.search .btn{align-self:end}
.crumbs{font-size:.9rem;color:var(--muted);padding:14px 0 0}.crumbs a{color:var(--muted)}
.facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:18px 0}
.fact{background:var(--soft);border:1px solid var(--line);border-radius:14px;padding:12px 14px}
.fact span{display:block;font-size:.85rem;color:var(--muted)}.fact b{font-size:1.15rem;color:var(--navy)}
table{width:100%;border-collapse:collapse;margin:10px 0 18px;font-size:.95rem}
th,td{padding:10px;border-bottom:1px solid var(--line);text-align:start}th{background:var(--soft);color:var(--navy)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:12px;margin:12px 0 8px}
.card{display:block;border:1px solid var(--line);border-radius:14px;padding:14px 16px;text-decoration:none;color:var(--ink);background:#fff}
.card:hover{border-color:var(--blue)}.card b{display:block;color:var(--navy)}.card small{color:var(--muted)}
ol.steps{padding-inline-start:1.3em}ol.steps li{margin-bottom:.4em}
details{border:1px solid var(--line);border-radius:12px;padding:12px 16px;margin:8px 0;background:#fff}
summary{cursor:pointer;font-weight:600;color:var(--navy)}
.note{background:var(--tint);border-radius:12px;padding:12px 16px;color:var(--navy)}
footer{background:var(--navy);color:#C9D6EA;margin-top:48px;padding:32px 0;font-size:.92rem}
footer a{color:#fff;text-decoration:none}footer .cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:20px}
footer h3{color:#fff;font-size:1rem}footer ul{list-style:none;padding:0;margin:0}footer li{margin:4px 0}
section{padding-bottom:8px}
@media(max-width:640px){nav.main{width:100%;margin:0;padding-bottom:10px;gap:12px}.hero{padding:32px 0}}
"""


def base() -> str:
    return get_settings().public_url.rstrip("/")


def words(lang: str) -> dict:
    return messages(lang)["seo"]


def city_name(lang: str, code: str, fallback: str = "") -> str:
    return messages(lang).get("cities", {}).get(code) or fallback or code


def station_name(lang: str, code: Optional[str], fallback: str) -> str:
    m = re.match(r"^SY-([A-Z]{3})-([A-Z])(\d{3})$", code or "")
    if not m:
        return fallback
    w = words(lang)["station"]
    city = city_name(lang, m.group(1))
    n = int(m.group(3))
    return w["central"].format(city=city) if m.group(2) == "C" and n == 1 else w["numbered"].format(city=city, n=n)


def fmt(template: str, **kw) -> str:
    return template.format(**kw)


def money(lang: str, minor: Optional[int]) -> str:
    if minor is None:
        return "—"
    return f"{round(minor / 100):,} {words(lang)['common']['currency']}"


def duration(lang: str, minutes: Optional[int]) -> str:
    if not minutes:
        return "—"
    h, m = divmod(int(minutes), 60)
    c = words(lang)["common"]
    return c["duration_h"].format(h=h) if m == 0 else c["duration"].format(h=h, m=m)


def distance(lang: str, km: Optional[int]) -> str:
    return words(lang)["common"]["km"].format(km=km) if km else "—"


def local(dt: datetime, zone: str) -> datetime:
    return dt.astimezone(ZoneInfo(zone))


def day_label(lang: str, dt: datetime, zone: str) -> str:
    d = local(dt, zone)
    if lang == "ar":
        return f"{d.day}/{d.month}/{d.year}"
    return d.strftime("%a %d %b %Y")


def tomorrow() -> str:
    return (datetime.now(_DEFAULT_ZONE).date() + timedelta(days=1)).isoformat()


def search_url(a: str, b: str, lang: str, on: Optional[str] = None) -> str:
    return f"/search?from={a}&to={b}&on={on or tomorrow()}&lang={lang}"


def page(*, lang: str, path: str, title: str, description: str, body: str, jsonld: Iterable[dict] = (), status_noindex: bool = False,
         alternates: bool = True, hero: str = "") -> str:
    """A full HTML document. `path` is the language-independent part after /ar or /en ('' for the home page)."""
    w = words(lang)
    other = "en" if lang == "ar" else "ar"
    url = f"{base()}/{lang}{path}"
    rtl = lang == "ar"
    s = get_settings()
    head = [
        '<meta charset="utf-8">', '<meta name="viewport" content="width=device-width, initial-scale=1">',
        f"<title>{escape(title)}</title>", f'<meta name="description" content="{escape(description)}">',
        f'<meta name="robots" content="{"noindex, follow" if status_noindex else "index, follow, max-image-preview:large, max-snippet:-1"}">',
        '<meta name="theme-color" content="#0B1F3F">', '<link rel="icon" type="image/svg+xml" href="/favicon.svg">',
        '<link rel="apple-touch-icon" href="/logo.png">',
    ]
    if not status_noindex:
        head.append(f'<link rel="canonical" href="{url}">')
        if alternates:
            head += [f'<link rel="alternate" hreflang="{lg}" href="{base()}/{lg}{path}">' for lg in LANGS]
            head.append(f'<link rel="alternate" hreflang="x-default" href="{base()}/ar{path}">')
    head += [
        '<meta property="og:type" content="website">', f'<meta property="og:site_name" content="{escape(w["brand"])}">',
        f'<meta property="og:title" content="{escape(title)}">', f'<meta property="og:description" content="{escape(description)}">',
        f'<meta property="og:url" content="{url}">', f'<meta property="og:image" content="{base()}/og-{lang}.png">',
        '<meta property="og:image:width" content="1200">', '<meta property="og:image:height" content="630">',
        f'<meta property="og:locale" content="{"ar_SY" if rtl else "en_US"}">',
        f'<meta property="og:locale:alternate" content="{"en_US" if rtl else "ar_SY"}">',
        '<meta name="twitter:card" content="summary_large_image">', f'<meta name="twitter:title" content="{escape(title)}">',
        f'<meta name="twitter:description" content="{escape(description)}">', f'<meta name="twitter:image" content="{base()}/og-{lang}.png">',
    ]
    if s.google_site_verification:
        head.append(f'<meta name="google-site-verification" content="{escape(s.google_site_verification)}">')
    if s.bing_site_verification:
        head.append(f'<meta name="msvalidate.01" content="{escape(s.bing_site_verification)}">')
    head += ['<link rel="preconnect" href="https://fonts.googleapis.com">', '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>',
             '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Arabic:wght@400;600&family=Readex+Pro:wght@600;700&display=swap">',
             f"<style>{CSS}</style>"]
    graph = [organization(lang), website(lang), *jsonld]
    head.append('<script type="application/ld+json">' + json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False)
                .replace("</", "<\\/") + "</script>")
    n = w["nav"]
    header = (f'<header class="top"><div class="wrap"><a class="brand" href="/{lang}">{LOGO}<span>{escape(w["brand"])}</span></a>'
              f'<nav class="main" aria-label="{escape(n["home"])}"><a href="/{lang}#routes">{escape(n["routes"])}</a>'
              f'<a href="/{lang}/international">{escape(n["international"])}</a><a href="/{lang}/services/shipping">{escape(n["services"])}</a>'
              f'<a href="/{lang}/faq">{escape(n["faq"])}</a><a href="/{other}{path}" hreflang="{other}" lang="{other}">{escape(words(other)["nav"]["lang_name"])}</a>'
              f'<a href="/login?lang={lang}">{escape(n["signin"])}</a></nav></div></header>')
    return (f'<!doctype html><html lang="{lang}" dir="{"rtl" if rtl else "ltr"}"><head>{"".join(head)}</head><body>{header}{hero}'
            f'<main class="wrap">{body}</main>{footer(lang)}</body></html>')


def footer(lang: str) -> str:
    from .data import _cache
    w = words(lang)
    popular = []
    if _cache:
        for slug, r in list(_cache.routes.items()):
            if r.a == "DAM" or r.b == "DAM":
                popular.append(f'<li><a href="/{lang}/bus/{slug}">{escape(city_name(lang, r.a))} – {escape(city_name(lang, r.b))}</a></li>')
            if len(popular) >= 8:
                break
    svc = w["services"]["items"]
    services = "".join(f'<li><a href="/{lang}/services/{k}">{escape(v["h1"])}</a></li>' for k, v in svc.items())
    n = w["nav"]
    return (f'<footer><div class="wrap cols"><div><h3>{escape(w["brand"])}</h3><p>{escape(w["footer"]["text"])}</p></div>'
            f'<div><h3>{escape(w["footer"]["popular"])}</h3><ul>{"".join(popular)}</ul></div>'
            f'<div><h3>{escape(n["services"])}</h3><ul>{services}</ul></div>'
            f'<div><h3>{escape(w["footer"]["company"])}</h3><ul><li><a href="/{lang}/about">{escape(n["about"])}</a></li>'
            f'<li><a href="/{lang}/faq">{escape(n["faq"])}</a></li><li><a href="/{lang}/international">{escape(n["international"])}</a></li>'
            f'<li><a href="/{lang}/business">{escape(n["business"])}</a></li><li><a href="/{lang}/contact">{escape(n["contact"])}</a></li>'
            f'<li><a href="/{lang}/terms">{escape(n["terms"])}</a></li><li><a href="/{lang}/privacy">{escape(n["privacy"])}</a></li></ul></div>'
            f'</div><div class="wrap"><p>{escape(w["footer"]["rights"].format(year=date.today().year))}</p></div></footer>')


def organization(lang: str) -> dict:
    w = words(lang)
    return {"@type": "Organization", "@id": f"{base()}/#organization", "name": "Masslak", "alternateName": words("ar")["brand"],
            "url": base(), "logo": f"{base()}/logo.png", "description": w["tagline"],
            "areaServed": [{"@type": "Country", "name": "Syria"}, {"@type": "Country", "name": "Lebanon"}, {"@type": "Country", "name": "Jordan"}]}


def website(lang: str) -> dict:
    return {"@type": "WebSite", "@id": f"{base()}/#website", "url": base(), "name": words(lang)["brand"],
            "inLanguage": ["ar", "en"], "publisher": {"@id": f"{base()}/#organization"}}


def breadcrumbs(lang: str, items: list[tuple[str, str]]) -> tuple[str, dict]:
    """[(name, path)] after the home page -> (HTML, JSON-LD)."""
    w = words(lang)
    trail = [(w["common"]["breadcrumb_home"], f"/{lang}")] + items
    html = '<nav class="crumbs" aria-label="breadcrumb">' + " › ".join(
        f'<a href="{p}">{escape(n)}</a>' if i < len(trail) - 1 else f"<span>{escape(n)}</span>" for i, (n, p) in enumerate(trail)) + "</nav>"
    ld = {"@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": i + 1, "name": n, "item": f"{base()}{p}"} for i, (n, p) in enumerate(trail)]}
    return html, ld


def faq(items: list[dict]) -> tuple[str, dict]:
    html = "".join(f"<details><summary>{escape(i['q'])}</summary><p>{escape(i['a'])}</p></details>" for i in items)
    ld = {"@type": "FAQPage", "mainEntity": [{"@type": "Question", "name": i["q"], "acceptedAnswer": {"@type": "Answer", "text": i["a"]}}
                                               for i in items]}
    return html, ld


def search_form(lang: str, cities: list[tuple[str, str]], a: str = "DAM", b: str = "ALP") -> str:
    f = words(lang)["form"]
    origin, dest, when = f["from"], f["to"], f["on"]

    def opts(sel: str) -> str:
        return "".join(f'<option value="{c}"{" selected" if c == sel else ""}>{escape(n)}</option>' for c, n in cities)
    return (f'<form class="search" action="/search" method="get"><input type="hidden" name="lang" value="{lang}">'
            f'<label>{escape(origin)}<select name="from">{opts(a)}</select></label>'
            f'<label>{escape(dest)}<select name="to">{opts(b)}</select></label>'
            f'<label>{escape(when)}<input type="date" name="on" value="{tomorrow()}" required></label>'
            f'<button class="btn" type="submit">{escape(words(lang)["common"]["search_cta"])}</button></form>')

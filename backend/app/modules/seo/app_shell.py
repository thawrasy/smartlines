"""The web app's index.html with search metadata: localised title and description, canonical, language alternates,
share cards, structured data, and a no-JavaScript fallback with links to the landing pages. Built once per process."""
from __future__ import annotations

import json
from functools import lru_cache
from html import escape
from pathlib import Path

from .render import base, organization, website, words

DEFAULT = "ar"


@lru_cache(maxsize=2)
def _shell(path: str, mtime: float) -> str:
    html = Path(path).read_text(encoding="utf-8")
    w = words(DEFAULT)
    title, desc = w["app"]["title"], w["app"]["description"]
    meta = [
        f'<meta name="description" content="{escape(desc)}">', f'<link rel="canonical" href="{base()}/">',
        f'<link rel="alternate" hreflang="ar" href="{base()}/ar">', f'<link rel="alternate" hreflang="en" href="{base()}/en">',
        f'<link rel="alternate" hreflang="x-default" href="{base()}/">',
        '<meta property="og:type" content="website">', f'<meta property="og:title" content="{escape(title)}">',
        f'<meta property="og:description" content="{escape(desc)}">', f'<meta property="og:url" content="{base()}/">',
        f'<meta property="og:image" content="{base()}/og-{DEFAULT}.png">', '<meta name="twitter:card" content="summary_large_image">',
        '<link rel="apple-touch-icon" href="/logo.png">',
        '<script type="application/ld+json">' + json.dumps({"@context": "https://schema.org", "@graph": [organization(DEFAULT), website(DEFAULT)]},
                                                         ensure_ascii=False).replace("</", "<\\/") + "</script>",
    ]
    html = html.replace('<html lang="en" dir="ltr">', f'<html lang="{DEFAULT}" dir="rtl">', 1)
    html = html.replace("<title>Masslak</title>", f"<title>{escape(title)}</title>" + "".join(meta), 1)
    n = w["nav"]
    links = " · ".join(f'<a href="/{lg}">{escape(words(lg)["home"]["h1"])}</a>' for lg in ("ar", "en"))
    noscript = (f'<noscript><h1>{escape(w["home"]["h1"])}</h1><p>{escape(w["home"]["lead"])}</p><p>{links} · '
                f'<a href="/ar/faq">{escape(n["faq"])}</a></p></noscript>')
    return html.replace('<div id="root"></div>', '<div id="root"></div>' + noscript, 1)


def shell(index: Path) -> str:
    return _shell(str(index), index.stat().st_mtime)
